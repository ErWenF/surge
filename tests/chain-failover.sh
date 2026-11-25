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
probe_secret=$(cat "$CFG/failover-probe.secret")
[[ "$probe_secret" =~ ^[0-9a-f]{32}$ && "$(stat -c %a "$CFG/failover-probe.secret")" == 600 ]] || fail "探测密钥格式或权限不符"
# 探测入口：只为故障转移组的节点（B、A）生成，只监听本机、带密码，端口避开协议端口；路由紧跟 api 规则
jq -e --arg A "$A" --arg B "$B" --arg s "$probe_secret" '
    [.inbounds[] | select(.tag | startswith("fo-probe-"))] as $p |
    ($p | map(.tag)) == ["fo-probe-" + $B, "fo-probe-" + $A] and
    all($p[]; .listen == "127.0.0.1" and .protocol == "socks" and .settings.auth == "password"
              and .settings.accounts == [{user:"probe", pass:$s}] and .port >= 61800 and .port != 24199) and
    ($p | map(.port) | unique | length) == 2 and
    .routing.rules[0].inboundTag == ["api"] and
    .routing.rules[1] == {type:"field", inboundTag:["fo-probe-" + $B], outboundTag:$B} and
    .routing.rules[2] == {type:"field", inboundTag:["fo-probe-" + $A], outboundTag:$A} and
    .burstObservatory.pingConfig.destination == "https://www.gstatic.com/generate_204"' "$fixture/x1.json" >/dev/null ||
    fail "故障转移探测入口不符: $(jq -c '{p:[.inbounds[]|select(.tag|startswith("fo-probe-"))], r:.routing.rules[0:3]}' "$fixture/x1.json")"
# 引用完整性：规则指向的出站/均衡器、均衡器的节点与 fallbackTag 都必须存在
jq -e '[.outbounds[].tag] as $o | [.routing.balancers[]?.tag] as $b |
    all(.routing.rules[]; ((.outboundTag // null) as $t | $t == null or ($o | index($t) != null)) and
                          ((.balancerTag // null) as $t | $t == null or ($b | index($t) != null))) and
    all(.routing.balancers[]; all(.selector[]; . as $s | $o | index($s) != null) and
                              ((.fallbackTag // null) as $f | $f == null or ($o | index($f) != null)))' "$fixture/x1.json" >/dev/null ||
    fail "Xray 规则或均衡器引用了不存在的对象"
native_xray "$fixture/x1.json"
# 探测端口避开其他进程正在监听的端口；Xray 自己占用的（上一版探测入口）可以复用
ss() {
    printf '%s\n' 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0      4096   0.0.0.0:61800      0.0.0.0:*         users:(("nginx",pid=11,fd=6))' \
        'LISTEN 0      4096   127.0.0.1:61801    0.0.0.0:*         users:(("xray",pid=12,fd=9))' \
        'LISTEN 0      4096   [::]:61802         [::]:*            users:(("sshd",pid=13,fd=4))'
}
XRAY_CONFIG_OUTPUT="$fixture/x1-ports.json" _render_xray_config >/dev/null || fail "Xray 渲染失败（端口占用）"
unset -f ss
[[ "$(jq -c '[.inbounds[] | select(.tag | startswith("fo-probe-")) | .port]' "$fixture/x1-ports.json")" == '[61801,61803]' ]] ||
    fail "探测端口应避开其他进程监听的端口: $(jq -c '[.inbounds[] | select(.tag | startswith("fo-probe-")) | .port]' "$fixture/x1-ports.json")"
echo 'PASS Xray global routing: failover balancer keeps priority order, skips missing nodes, loopback probe inbounds per node, exact health checks, avoids ports held by other processes'

# ── 2. Xray：只有用户路由（原先该路径完全不生成健康检查）──
base_db '[]' "balancer:LP"
XRAY_CONFIG_OUTPUT="$fixture/x2.json" _render_xray_config >/dev/null || fail "Xray 渲染失败（用户路由）"
jq -e --arg A "$A" --arg C "$C" '
    ((.routing.balancers[] | select(.tag == "balancer-LP")) | .selector == [$A, $C]) and
    .burstObservatory.subjectSelector == [$A, $C] and
    (.api.services | index("RoutingService") == null) and
    ([.inbounds[] | select(.tag | startswith("fo-probe-"))] | length) == 0 and
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
    any(.outbounds[]; .tag == "direct") and
    any(.route.rules[]; .domain_suffix == ["example.com"] and .outbound == "balancer-FO")' "$fixture/s1.json" >/dev/null ||
    fail "sing-box 故障转移 selector / Clash API / 规则引用不符: $(jq -c '{o:[.outbounds[]|select(.tag=="balancer-FO")], e:.experimental.clash_api, r:.route.rules}' "$fixture/s1.json")"
# 引用完整性：sing-box check 不校验规则和分组引用的出站，引用不存在的 tag 要到运行时才报 outbound not found
jq -e '[.outbounds[].tag] as $t |
    all((.route.rules[]? | .outbound | strings), (.outbounds[] | .outbounds[]?), (.route.final // empty);
        . as $o | $t | index($o) != null)' "$fixture/s1.json" >/dev/null ||
    fail "sing-box 规则或分组引用了不存在的出站: $(jq -c '[.outbounds[].tag] as $t | [(.route.rules[]?.outbound | strings), (.outbounds[] | .outbounds[]?)] | map(select(. as $o | $t | index($o) == null))' "$fixture/s1.json")"
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

# ── 5. 监控服务（Xray）：经探测入口用全部检测网址判断，bo 按优先级指定 ──
base_db '[{"id":"custom_1","type":"custom","outbound":"balancer:FO","domains":"example.com"}]' ""
cp "$fixture/x1.json" "$CFG/config.json"
tg_send_message() { printf '%s\n---\n' "$1" >> "$fixture/tg"; }
# 模拟内核的"当前指定"存文件：_failover_step 在命令替换的子 shell 中运行，变量改动带不回来
: > "$fixture/bi_override"
bo_fail=false probe_ok="" probe_half="" probe_infra_down=false
xray() {
    [[ "$1 $2" == "api bi" ]] && { printf '  - Selecting Override:\n    1   %s\n  - Selects:\n' "$(cat "$fixture/bi_override")"; return 0; }
    if [[ "$1 $2" == "api bo" ]]; then
        echo "bo ${*: -1}" >> "$fixture/xray-calls"
        [[ "$bo_fail" == true ]] && return 1
        if [[ "${*: -1}" == -r ]]; then : > "$fixture/bi_override"; else printf '%s' "${*: -1}" > "$fixture/bi_override"; fi
        return 0
    fi
    return 1
}
# 探测：按探测端口找到节点；probe_ok 全部网址可用，probe_half 只有 gstatic 可用（半故障节点）
curl() {
    local stdin port tag url="${*: -1}"
    stdin=$(cat)
    [[ "$*" != *"$probe_secret"* ]] || fail "探测密码出现在 curl 参数中"
    [[ "$probe_infra_down" == true ]] && { echo -n 000; return 7; }
    [[ "$stdin" == *"proxy-user = \"probe:$probe_secret\""* ]] || { echo -n 000; return 97; }
    port=$(grep -o '127.0.0.1:[0-9]*' <<< "$stdin" | cut -d: -f2)
    tag=$(jq -r --argjson p "$port" '.inbounds[] | select(.port == $p) | .tag' "$CFG/config.json")
    [[ -n "$tag" ]] || { echo -n 000; return 7; }
    tag="${tag#fo-probe-}"
    echo "$tag $url" >> "$fixture/probes"
    if [[ " $probe_ok " == *" $tag "* ]] || { [[ " $probe_half " == *" $tag "* ]] && [[ "$url" == *gstatic* ]]; }; then
        echo -n 204; return 0
    fi
    echo -n 000; return 28
}
cycle() { probe_ok="$1" probe_half="${2:-}"; : > "$fixture/xray-calls"; : > "$fixture/probes"; failover_check_once || fail "检查失败"; }
# 状态文件存在但为空（jq 1.6 对空输入配合 -e 返回 0，曾导致状态被写成空文件、每轮都当作首次）
: > "$CFG/failover-state.json"
target() { jq -r '."xray|FO".target' "$CFG/failover-state.json"; }
cycle "$A $B";  [[ $(target) == "$B" && $(cat "$fixture/xray-calls") == "bo $B" && ! -s "$fixture/tg" ]] || fail "首轮应指定最高优先级 B 且不通知"
[[ $(grep -c gstatic "$fixture/probes") == 2 && $(grep -c cloudflare "$fixture/probes") == 2 ]] || fail "每个节点都应探测全部检测网址: $(cat "$fixture/probes")"
cycle "$A" "$B"; [[ $(target) == "$A" && $(cat "$fixture/xray-calls") == "bo $A" ]] || fail "B 只能访问 gstatic（半故障）时应判为不可用并切到 A"
grep -q 'B 不可用，已切换到 A' "$fixture/tg" || fail "缺少故障转移通知"
cycle "";       [[ $(target) == direct && $(cat "$fixture/xray-calls") == "bo direct" ]] || fail "全部不可用应显式指定 direct"
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
probe_infra_down=true
cycle "";       [[ $(target) == "$A" && ! -s "$fixture/xray-calls" ]] || fail "探测入口未就绪（如 Xray 重启中）时不应判为全部不可用"
grep -q '探测入口未就绪' "$CFG/failover.log" || fail "未就绪应记录日志"
cycle ""; cycle ""
[[ $(grep -c '探测入口未就绪' "$CFG/failover.log") == 1 ]] || fail "同一异常持续时只应记录一次日志"
grep -q '最近异常: 探测入口未就绪' <<< "$(failover_print_status)" || fail "状态页应显示最近异常"
probe_infra_down=false
cycle "$A"
grep -q 'FO/xray: 检测恢复正常' "$CFG/failover.log" || fail "异常恢复后应记录日志"
[[ $(jq -r '."xray|FO".note // empty' "$CFG/failover-state.json") == "" ]] || fail "恢复后应清除 note"
status_out=$(failover_print_status)
grep -q 'FO（Xray）当前出口: A' <<< "$status_out" && grep -q 'cp.cloudflare.com/generate_204' <<< "$status_out" ||
    fail "状态展示不符: $status_out"
# 上轮出口已不在组内（如节点改名）：静默重新选择，不发"不可用"通知；
# 不再出现在配置中的组（如 singbox|FO、已删除的组）不保留状态
notices=$(grep -c '^---$' "$fixture/tg")
jq '."xray|FO".target = "chain-Renamed-prefer-ipv4" | ."singbox|FO" = {target: "x"} | ."xray|Gone" = {target: "y"}' \
    "$CFG/failover-state.json" > "$fixture/st" && cat "$fixture/st" > "$CFG/failover-state.json"
cycle "$A"; [[ $(target) == "$A" ]] || fail "原出口不在组内时应重新选择"
[[ $(grep -c '^---$' "$fixture/tg") == "$notices" ]] || fail "原出口不在组内时不应发送通知"
grep -q 'Renamed 已不在组内' "$CFG/failover.log" || fail "原出口不在组内应记录日志"
[[ $(jq -c 'keys' "$CFG/failover-state.json") == '["xray|FO"]' ]] || fail "应清除未处理组的状态: $(jq -c keys "$CFG/failover-state.json")"
# 数据库先于配置更新（节点改名后、配置重建前）：节点与优先级以配置中的均衡器为准，不能误切到低优先级节点（真机发现）
cycle "$B $A"; cycle "$B $A"; cycle "$B $A"; [[ $(target) == "$B" ]] || fail "前置：应已切回 B"
cp "$DB_FILE" "$fixture/db.bak"
jq '(.balancer_groups[] | select(.name == "FO") | .nodes) = ["B-renamed", "A"]' "$fixture/db.bak" > "$DB_FILE"
notices=$(grep -c '^---$' "$fixture/tg")
cycle "$B $A"; [[ $(target) == "$B" && ! -s "$fixture/xray-calls" ]] || fail "配置未重建前应继续按配置使用 B: $(target)"
[[ $(grep -c '^---$' "$fixture/tg") == "$notices" ]] || fail "数据库与配置不一致时不应通知"
cp "$fixture/db.bak" "$DB_FILE"
unset -f curl
echo 'PASS Xray monitor: all test URLs per node via probe inbounds, half-broken node rejected, explicit direct, stable recovery, re-apply after restart, retry, not-ready skip, log dedup, rename re-init, stale state cleanup'

# ── 6. 监控服务（sing-box）：Clash API 对每个网址测速，密钥只经 stdin ──
rm -f "$CFG/failover-state.json" "$CFG/config.json" "$fixture/tg"
cp "$fixture/s1.json" "$CFG/singbox.json"
printf '%s' "$B" > "$fixture/sb_now"   # 同样存文件，跨子 shell 保留 selector 当前选择
sb_ok="" sb_half="" sb_api_down=false
curl() {
    local stdin; stdin=$(cat)
    [[ "$*" != *"$secret"* ]] || fail "Clash API 密钥出现在 curl 参数中"
    [[ "$sb_api_down" == true ]] && return 7
    [[ "$stdin" == *"Bearer $secret"* ]] || return 22
    local url="${*: -1}" method=GET i
    for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { i=$((i + 1)); method="${!i}"; }; done
    case "$method $url" in
        "GET "*"/proxies/balancer-FO") printf '{"now":"%s"}' "$(cat "$fixture/sb_now")" ;;
        "PUT "*"/proxies/balancer-FO")
            grep -o '"name":"[^"]*"' <<< "$*" | cut -d'"' -f4 | tr -d '\n' > "$fixture/sb_now"
            echo "put $(cat "$fixture/sb_now")" >> "$fixture/sb-calls" ;;
        "GET "*"/delay?"*)
            local tag="${url#*/proxies/}"; tag="${tag%%/delay*}"
            if [[ " $sb_ok " == *" $tag "* ]] || { [[ " $sb_half " == *" $tag "* ]] && [[ "$url" == *gstatic* ]]; }; then
                echo '{"delay":120}'
            else
                echo '{"message":"An error occurred in the delay test"}'; return 22
            fi ;;
        *) return 22 ;;
    esac
}
sb_cycle() { sb_ok="$1" sb_half="${2:-}"; : > "$fixture/sb-calls"; failover_check_once || fail "检查失败"; }
sb_target() { jq -r '."singbox|FO".target' "$CFG/failover-state.json"; }
sb_cycle "$A $B";   [[ $(sb_target) == "$B" && ! -s "$fixture/sb-calls" ]] || fail "sing-box 首轮已是 B，不应重复切换"
sb_cycle "$A" "$B"; [[ $(sb_target) == "$A" && $(cat "$fixture/sb-calls") == "put $A" ]] || fail "sing-box B 半故障应切到 A"
sb_cycle "";        [[ $(sb_target) == direct && $(cat "$fixture/sb-calls") == "put direct" ]] || fail "sing-box 全部不可用应切到 direct"
grep -q 'Sing-box' "$fixture/tg" || fail "sing-box 切换应通知"
sb_api_down=true
sb_cycle "$A $B";   [[ $(sb_target) == direct && ! -s "$fixture/sb-calls" ]] || fail "Clash API 不可用时应保持原状态"
sb_api_down=false
unset -f curl
echo 'PASS sing-box monitor: delay test for every URL, half-broken node rejected, selector to direct, API-down skip, secret only via stdin'

# ── 7. 服务定义 ──
_failover_write_service systemd "$fixture/unit" /usr/local/bin/vless-server.sh /usr/bin/bash || fail "systemd 服务生成失败"
grep -qx 'ExecStart=/usr/bin/bash /usr/local/bin/vless-server.sh --failover-run' "$fixture/unit" && grep -qx 'Restart=always' "$fixture/unit" ||
    fail "systemd 服务内容不符"
_failover_write_service openrc "$fixture/rc" /usr/local/bin/vless-server.sh /bin/bash || fail "OpenRC 服务生成失败"
grep -q 'command_args="/usr/local/bin/vless-server.sh --failover-run"' "$fixture/rc" || fail "OpenRC 服务内容不符"
if _failover_write_service systemd "$fixture/bad" '/usr/local/bin/x;rm' /usr/bin/bash; then fail "应拒绝带特殊字符的路径"; fi
echo 'PASS service definitions for systemd/OpenRC reject unsafe paths'

# ── 8. 检测网址设置与校验 ──
for u in "https://www.gstatic.com/generate_204" "http://cp.cloudflare.com/generate_204" "https://example.com:8443/a/b?x=1&y=2"; do
    _failover_valid_url "$u" || fail "应接受合法网址: $u"
done
for u in "ftp://example.com" "https://exa mple.com" 'https://example.com/"x' 'https://example.com/\x' "https://"; do
    if _failover_valid_url "$u"; then fail "应拒绝网址: $u"; fi
done
db_set_failover_test_urls "https://a.example/1" "https://b.example/2" "https://a.example/1" || fail "设置检测网址失败"
[[ "$(_failover_test_urls | paste -sd ' ' -)" == "https://a.example/1 https://b.example/2" ]] || fail "检测网址应去重并保持顺序"
if db_set_failover_test_urls "https://a.example/bad url" 2>/dev/null; then fail "非法网址应拒绝"; fi
if db_set_failover_test_urls https://e.example/{1..6} 2>/dev/null; then fail "超过 5 个应拒绝"; fi
db_set_failover_test_urls || fail "恢复默认失败"
[[ "$(_failover_test_urls | paste -sd ' ' -)" == "${FAILOVER_DEFAULT_TEST_URLS[*]}" ]] || fail "恢复默认后应为默认网址"
jq -e 'has("failover_test_urls") | not' "$DB_FILE" >/dev/null || fail "恢复默认应删除自定义字段"
echo 'PASS test URL validation, dedupe, limit of 5 and reset to defaults'

# ── 9. 删除故障转移组后，配置事务不应因探测入口消失而拒绝应用（真机发现的回归）──
svc() { return 1; }
printf '#!/bin/sh\nexit 0\n' > "$fixture/xray-ok"; chmod +x "$fixture/xray-ok"
base_db '[{"id":"custom_1","type":"custom","outbound":"balancer:FO","domains":"example.com"}]' ""
cp "$fixture/x1.json" "$CFG/config.json"   # 运行中的配置带有探测入口
jq '.balancer_groups = [] | .routing_rules = []' "$DB_FILE" > "$fixture/db" && mv "$fixture/db" "$DB_FILE"
bk=$(_user_change_begin xray) || fail "无法创建事务备份"
XRAY_BIN="$fixture/xray-ok" _user_change_apply xray "$bk" validate ||
    fail "删除故障转移组后候选配置被拒绝：探测入口不应计入必须保留的入站"
jq -e '[.inbounds[] | select(.tag | startswith("fo-probe-"))] | length == 0' "$bk/candidate.json" >/dev/null ||
    fail "删除组后候选配置不应再有探测入口"
# 对照：普通入站缺失仍应被拒绝（原有保护不变）
jq '.inbounds += [{tag:"keep-me", port:30999, protocol:"socks", listen:"127.0.0.1"}]' "$fixture/x1.json" > "$CFG/config.json"
bk=$(_user_change_begin xray) || fail "无法创建事务备份"
if XRAY_BIN="$fixture/xray-ok" _user_change_apply xray "$bk" validate 2>/dev/null; then fail "普通入站缺失时仍应拒绝"; fi
echo 'PASS removing failover groups drops probe inbounds through the transaction; other missing inbounds still rejected'
