#!/usr/bin/env bash
# 链式代理故障转移组：配置渲染（Xray 两条路径、sing-box）、决策逻辑、监控服务切换与通知。
# 只在临时目录渲染和模拟内核 API，不启动任何服务。
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_listen_addr() { echo 127.0.0.1; }
mkdir() {
    if [[ "$*" == '-p /var/log/xray' ]]; then command mkdir -p "$fixture/log"; else command mkdir "$@"; fi
}
fail() { echo "FAIL: $*" >&2; exit 1; }
A=chain-A-prefer-ipv4 B=chain-B-prefer-ipv4 C=chain-C-prefer-ipv4

base_db() {  # $1 = 全局分流规则 JSON，$2 = alice 的用户路由
    jq -n --argjson rules "$1" --arg route "$2" '
        {xray:{ss2022:{port:24199,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg==",multi_user:true,
            users:[{name:"default-24199",uuid:"MTIzNDU2Nzg5MGFiY2RlZg==",used:0,quota:0,enabled:true},
                   {name:"alice",uuid:"ZmVkY2JhMDk4NzY1NDMyMQ==",used:0,quota:0,enabled:true,routing:$route}]}},
         singbox:{},
         chain_proxy:{nodes:[{name:"A",type:"socks",server:"127.0.0.1",port:1081},
                             {name:"B",type:"socks",server:"127.0.0.1",port:1082},
                             {name:"C",type:"socks",server:"127.0.0.1",port:1083}]},
         balancer_groups:[{name:"FO",strategy:"failover",nodes:["B","A","Missing"]},
                          {name:"LP",strategy:"leastPing",nodes:["A","C"]}],
         routing_rules:$rules, meta:{}}' > "$DB_FILE"
}
native_xray() {
    [[ -n "${XRAY_BIN:-}" ]] || return 0
    jq '.log={loglevel:"none"}' "$1" > "$fixture/native.json"
    "$XRAY_BIN" run -test -c "$fixture/native.json" >/dev/null 2>&1 || fail "Xray 不接受生成的配置"
}

# ── 1. Xray：全局分流规则引用故障转移组 ──
base_db '[{"id":"custom_1","type":"custom","outbound":"balancer:FO","domains":"example.com"}]' ""
XRAY_CONFIG_OUTPUT="$fixture/x1.json" _render_xray_config >/dev/null || fail "Xray 渲染失败（全局分流）"
jq -e --arg A "$A" --arg B "$B" --arg C "$C" '
    (.routing.balancers[] | select(.tag == "balancer-FO")) as $fo |
    $fo.selector == [$B, $A] and $fo.fallbackTag == "direct" and
    $fo.strategy == {type:"leastLoad", settings:{expected:2, tolerance:0.4}} and
    ((.routing.balancers[] | select(.tag == "balancer-LP")) | .selector == [$A, $C] and .strategy.type == "leastPing") and
    .burstObservatory.subjectSelector == ([$A, $B, $C] | sort) and
    (.api.services | index("RoutingService") != null and index("StatsService") != null) and
    any(.routing.rules[]; .balancerTag == "balancer-FO") and
    any(.outbounds[]; .tag == "direct")' "$fixture/x1.json" >/dev/null ||
    fail "全局分流路径的均衡器/健康检查不符: $(jq -c '{b:.routing.balancers, o:.burstObservatory, api:.api}' "$fixture/x1.json")"
native_xray "$fixture/x1.json"
echo 'PASS Xray global routing: failover balancer keeps priority order, skips missing nodes, falls back to direct, exact health checks'

# ── 2. Xray：只有用户路由（原先该路径完全不生成健康检查）──
base_db '[]' "balancer:LP"
XRAY_CONFIG_OUTPUT="$fixture/x2.json" _render_xray_config >/dev/null || fail "Xray 渲染失败（用户路由）"
jq -e --arg A "$A" --arg C "$C" '
    ((.routing.balancers[] | select(.tag == "balancer-LP")) | .selector == [$A, $C]) and
    .burstObservatory.subjectSelector == [$A, $C] and
    (.api.services | index("RoutingService") == null) and
    any(.routing.rules[]; .user == ["alice@ss2022"] and .balancerTag == "balancer-LP")' "$fixture/x2.json" >/dev/null ||
    fail "用户路由路径缺少健康检查或误开 RoutingService: $(jq -c '{b:.routing.balancers, o:.burstObservatory, api:.api}' "$fixture/x2.json")"
native_xray "$fixture/x2.json"
echo 'PASS Xray user routing: leastPing balancer now gets exact health checks; RoutingService only for failover groups'

# ── 3. sing-box：selector [节点..., direct] + Clash API ──
jq '.xray = {} | .singbox = {ss2022:{port:24300,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg=="}}
    | .routing_rules = [{id:"custom_1",type:"custom",outbound:"balancer:FO",domains:"example.com"}]' "$DB_FILE" > "$fixture/db" && mv "$fixture/db" "$DB_FILE"
sing_box_tags="with_v2ray_api,with_clash_api"
sing-box() { [[ "$1" == version ]] && printf 'sing-box version 1.14.0\n\nTags: %s\n' "$sing_box_tags"; }
SINGBOX_CONFIG_OUTPUT="$fixture/s1.json" _render_singbox_config >/dev/null 2>"$fixture/s1.err" || fail "sing-box 渲染失败: $(cat "$fixture/s1.err")"
secret=$(cat "$CFG/singbox-clash-api.secret")
[[ "$secret" =~ ^[0-9a-f]{32}$ ]] || fail "Clash API 密钥格式错误"
[[ "$(stat -c %a "$CFG/singbox-clash-api.secret")" == 600 ]] || fail "Clash API 密钥文件权限应为 600"
jq -e --arg A "$A" --arg B "$B" --arg s "$secret" '
    (.outbounds[] | select(.tag == "balancer-FO")) == {type:"selector", tag:"balancer-FO", outbounds:[$B, $A, "direct"],
        default:$B, interrupt_exist_connections:true} and
    .experimental.clash_api == {external_controller:"127.0.0.1:10087", secret:$s} and
    any(.outbounds[]; .tag == "direct")' "$fixture/s1.json" >/dev/null ||
    fail "sing-box 故障转移 selector / Clash API 不符: $(jq -c '{o:[.outbounds[]|select(.tag=="balancer-FO")], e:.experimental.clash_api}' "$fixture/s1.json")"
if [[ -n "${SINGBOX_TEST_BIN:-}" ]]; then
    jq 'del(.log)' "$fixture/s1.json" > "$fixture/s1-native.json"
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$SINGBOX_TEST_BIN" check -c "$fixture/s1-native.json" ||
        fail "sing-box 不接受生成的故障转移配置"
fi
sing_box_tags="with_v2ray_api"
SINGBOX_CONFIG_OUTPUT="$fixture/s2.json" _render_singbox_config >/dev/null 2>"$fixture/s2.err" || fail "无 Clash API 内核时渲染失败"
jq -e '.experimental.clash_api == null' "$fixture/s2.json" >/dev/null || fail "内核未编入 Clash API 时不应写入 clash_api"
grep -q 'Clash API' "$fixture/s2.err" || fail "内核未编入 Clash API 时应提示"
unset -f sing-box
echo 'PASS sing-box: failover selector ends with direct, Clash API on loopback with private secret, omitted without with_clash_api'

# ── 4. 决策：优先级、立即故障转移、稳定后切回 ──
FAILOVER_RECOVER_CHECKS=3
# 决策输出为 4 行（目标/候选/计数/原因），拼成 Tab 分隔便于断言
decide() { _failover_decide "$1" "$2" "$3" "$4" "$B" "$A" | paste -sd '\t' -; }
expect() { [[ "$1" == "$2" ]] || fail "决策不符: 期望 [$2] 实际 [$1]（$3）"; }
expect "$(decide '' '' 0 "$A"$'\n'"$B")" "$B"$'\t\t0\tinit' "首次按优先级"
expect "$(decide "$B" '' 0 "$A"$'\n'"$B")" "$B"$'\t\t0\thold' "当前最优且可用"
expect "$(decide "$B" '' 0 "$A")" "$A"$'\t\t0\tfailover' "当前节点不可用立即切换"
expect "$(decide "$A" '' 0 '')" $'direct\t\t0\tfailover' "全部不可用走直连"
expect "$(decide direct '' 0 '')" $'direct\t\t0\thold' "仍全部不可用"
expect "$(decide direct '' 0 "$A")" $'direct\t'"$A"$'\t1\thold' "恢复需连续可用 1/3"
expect "$(decide direct "$A" 1 "$A")" $'direct\t'"$A"$'\t2\thold' "恢复需连续可用 2/3"
expect "$(decide direct "$A" 2 "$A")" "$A"$'\t\t0\trecover' "连续 3 次可用后切换"
expect "$(decide "$A" '' 0 "$A"$'\n'"$B")" "$A"$'\t'"$B"$'\t1\thold' "高优先级恢复先等待"
expect "$(decide "$A" "$B" 1 "$A")" "$A"$'\t\t0\thold' "高优先级再次不可用时清零"
expect "$(decide "$A" '' 0 "$A"$'\n'"$B")" "$A"$'\t'"$B"$'\t1\thold' "重新计数"
expect "$(decide "$A" "$B" 2 "$A"$'\n'"$B")" "$B"$'\t\t0\trecover' "稳定后切回最高优先级"
expect "$(decide chain-Gone-prefer-ipv4 '' 0 "$A")" "$A"$'\t\t0\tfailover' "当前出口已不在组内"
echo 'PASS decision: priority order, immediate failover, direct when all down, recovery needs consecutive checks'

# ── 5. 监控服务（Xray）：bi / bo 驱动切换、内核重启后补指定、通知 ──
base_db '[{"id":"custom_1","type":"custom","outbound":"balancer:FO","domains":"example.com"}]' ""
cp "$fixture/x1.json" "$CFG/config.json"
_failover_proc_uptime() { echo 100; }
tg_send_message() { printf '%s\n---\n' "$1" >> "$fixture/tg"; }
bi_selects="" bo_fail=false
# 模拟内核的"当前指定"存文件：_failover_step 在命令替换的子 shell 中运行，变量改动带不回来
: > "$fixture/bi_override"
xray() {
    [[ "$1 $2" == "api bi" ]] && { printf '  - Selecting Override:\n    1   %s\n  - Selects:\n' "$(cat "$fixture/bi_override")"
        local i=1 t; for t in $bi_selects; do printf '    %d   %s\n' "$i" "$t"; i=$((i + 1)); done; return 0; }
    if [[ "$1 $2" == "api bo" ]]; then
        echo "bo ${*: -1}" >> "$fixture/xray-calls"
        [[ "$bo_fail" == true ]] && return 1
        if [[ "${*: -1}" == -r ]]; then : > "$fixture/bi_override"; else printf '%s' "${*: -1}" > "$fixture/bi_override"; fi
        return 0
    fi
    return 1
}
cycle() { bi_selects="$1"; : > "$fixture/xray-calls"; failover_check_once || fail "检查失败"; }
# 状态文件存在但为空（jq 1.6 对空输入配合 -e 返回 0，曾导致状态被写成空文件、每轮都当作首次）
: > "$CFG/failover-state.json"
target() { jq -r '."xray|FO".target' "$CFG/failover-state.json"; }
cycle "$A $B";  [[ $(target) == "$B" && $(cat "$fixture/xray-calls") == "bo $B" && ! -s "$fixture/tg" ]] || fail "首轮应指定最高优先级 B 且不通知"
cycle "$A";     [[ $(target) == "$A" && $(cat "$fixture/xray-calls") == "bo $A" ]] || fail "B 不可用应切到 A"
grep -q 'B 不可用，已切换到 A' "$fixture/tg" || fail "缺少故障转移通知"
cycle "";       [[ $(target) == direct && $(cat "$fixture/xray-calls") == "bo -r" ]] || fail "全部不可用应撤销指定走直连"
grep -q '所有节点均不可用，已改为直连' "$fixture/tg" || fail "缺少直连通知"
cycle "$B $A";  [[ $(target) == direct && ! -s "$fixture/xray-calls" ]] || fail "恢复第 1 次不应切换"
cycle "$B $A";  [[ $(target) == direct ]] || fail "恢复第 2 次不应切换"
cycle "$B $A";  [[ $(target) == "$B" && $(cat "$fixture/xray-calls") == "bo $B" ]] || fail "连续 3 次可用后应切回 B"
grep -q 'B 已稳定可用' "$fixture/tg" || fail "缺少切回通知"
notices=$(grep -c '^---$' "$fixture/tg")
: > "$fixture/bi_override"  # 模拟 Xray 重启丢失指定
cycle "$B $A";  [[ $(target) == "$B" && $(cat "$fixture/xray-calls") == "bo $B" ]] || fail "内核重启后应静默补上指定"
[[ $(grep -c '^---$' "$fixture/tg") == "$notices" ]] || fail "补指定不应发送通知"
bo_fail=true
cycle "$A";     [[ $(target) == "$B" ]] || fail "切换失败时应保留原状态以便重试"
[[ $(grep -c '^---$' "$fixture/tg") == "$notices" ]] || fail "切换失败时不应通知"
bo_fail=false
cycle "$A";     [[ $(target) == "$A" ]] || fail "下一轮应重试成功"
_failover_proc_uptime() { echo 5; }
cycle "";       [[ $(target) == "$A" && ! -s "$fixture/xray-calls" ]] || fail "Xray 刚启动时应等待首轮健康检查"
_failover_proc_uptime() { echo 100; }
failover_print_status | grep -q 'FO（Xray）当前出口: A' || fail "状态展示不符: $(failover_print_status)"
echo 'PASS Xray monitor: bi/bo switching, direct fallback, stable recovery, silent re-apply after restart, retry on failure, startup grace'

# ── 6. 监控服务（sing-box）：Clash API 测速与切换，密钥不出现在 curl 参数中 ──
rm -f "$CFG/failover-state.json" "$CFG/config.json" "$fixture/tg"
cp "$fixture/s1.json" "$CFG/singbox.json"
sb_alive=""
printf '%s' "$B" > "$fixture/sb_now"   # 同样存文件，跨子 shell 保留 selector 当前选择
curl() {
    local stdin; stdin=$(cat)
    [[ "$*" != *"$secret"* ]] || fail "Clash API 密钥出现在 curl 参数中"
    [[ "$stdin" == *"Bearer $secret"* ]] || return 22
    local url="${*: -1}" method=GET i
    for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { i=$((i + 1)); method="${!i}"; }; done
    case "$method $url" in
        "GET "*"/proxies/balancer-FO") printf '{"now":"%s"}' "$(cat "$fixture/sb_now")" ;;
        "PUT "*"/proxies/balancer-FO")
            grep -o '"name":"[^"]*"' <<< "$*" | cut -d'"' -f4 | tr -d '\n' > "$fixture/sb_now"
            echo "put $(cat "$fixture/sb_now")" >> "$fixture/sb-calls" ;;
        "GET "*"/delay?"*)
            local tag; tag=$(jq -rn --arg u "${url#*/proxies/}" '$u | split("/delay")[0] | @text "\(.)" ')
            [[ " $sb_alive " == *" $tag "* ]] && echo '{"delay":120}' || { echo '{"message":"An error occurred in the delay test"}'; return 22; } ;;
        *) return 22 ;;
    esac
}
_failover_proc_uptime() { echo 100; }
sb_cycle() { sb_alive="$1"; : > "$fixture/sb-calls"; failover_check_once || fail "检查失败"; }
sb_target() { jq -r '."singbox|FO".target' "$CFG/failover-state.json"; }
sb_cycle "$A $B"; [[ $(sb_target) == "$B" && ! -s "$fixture/sb-calls" ]] || fail "sing-box 首轮已是 B，不应重复切换"
sb_cycle "$A";    [[ $(sb_target) == "$A" && $(cat "$fixture/sb-calls") == "put $A" ]] || fail "sing-box B 不可用应切到 A"
sb_cycle "";      [[ $(sb_target) == direct && $(cat "$fixture/sb-calls") == "put direct" ]] || fail "sing-box 全部不可用应切到 direct"
grep -q 'Sing-box' "$fixture/tg" || fail "sing-box 切换应通知"
unset -f curl
echo 'PASS sing-box monitor: Clash API delay tests, selector switching to direct, secret passed only via stdin'

# ── 7. 服务定义 ──
_failover_write_service systemd "$fixture/unit" /usr/local/bin/vless-server.sh /usr/bin/bash || fail "systemd 服务生成失败"
grep -qx 'ExecStart=/usr/bin/bash /usr/local/bin/vless-server.sh --failover-run' "$fixture/unit" && grep -qx 'Restart=always' "$fixture/unit" ||
    fail "systemd 服务内容不符"
_failover_write_service openrc "$fixture/rc" /usr/local/bin/vless-server.sh /bin/bash || fail "OpenRC 服务生成失败"
grep -q 'command_args="/usr/local/bin/vless-server.sh --failover-run"' "$fixture/rc" || fail "OpenRC 服务内容不符"
if _failover_write_service systemd "$fixture/bad" '/usr/local/bin/x;rm' /usr/bin/bash; then fail "应拒绝带特殊字符的路径"; fi
echo 'PASS service definitions for systemd/OpenRC reject unsafe paths'
