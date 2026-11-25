#!/usr/bin/env bash
# sing-box 负载均衡组：
# - random / roundRobin 渲染为 urltest（按最低延迟选择可用节点）。sing-box 只有 selector / urltest 两种分组出站，
#   没有随机/轮询（上游不计划支持）。原先渲染成 selector 且 default 为第一个节点：实际永远走第一个节点，
#   既不随机也不轮询，节点不可用时也不会切走。
# - 分流规则引用组时 outbound 必须是组出站的 tag "balancer-组名"。原先原样写入 "balancer:组名"：
#   sing-box check 不校验规则引用的出站，运行时命中规则的连接报 outbound not found 而失败。
# - 菜单如实说明 sing-box 下的行为。
# 第 1、3 部分只在临时目录渲染；第 2 部分在设置了 SINGBOX_TEST_BIN 时只在本机回环地址上启动真实 sing-box。
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
pids=()
cleanup() {
    (( ${#pids[@]} )) && kill "${pids[@]}" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$fixture"
}
trap cleanup EXIT
init_db
_listen_addr() { echo 127.0.0.1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
A=chain-A-prefer-ipv4 B=chain-B-prefer-ipv4 C=chain-C-prefer-ipv4
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
if command -v python3 >/dev/null; then
    PA=$(free_port) PB=$(free_port) PC=$(free_port)
else
    PA=1081 PB=1082 PC=1083
fi

# 节点 A 在第 2 部分有真实 SOCKS 服务；B、C 的端口无人监听（不可用）。组内 B / C 排在 A 前面。
jq -n --argjson pa "$PA" --argjson pb "$PB" --argjson pc "$PC" '
    {xray:{}, singbox:{ss2022:{port:24300,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg=="}},
     chain_proxy:{nodes:[{name:"A",type:"socks",server:"127.0.0.1",port:$pa},
                         {name:"B",type:"socks",server:"127.0.0.1",port:$pb},
                         {name:"C",type:"socks",server:"127.0.0.1",port:$pc}]},
     balancer_groups:[{name:"RND",strategy:"random",nodes:["B","A","Missing"]},
                      {name:"RR",strategy:"roundRobin",nodes:["C","A"]},
                      {name:"LP",strategy:"leastPing",nodes:["A","C"]}],
     routing_rules:[{id:"custom_1",type:"custom",outbound:"balancer:RND",domains:"127.0.0.1/32"},
                    {id:"custom_2",type:"custom",outbound:"balancer:RR",domains:"rr.example"},
                    {id:"custom_3",type:"custom",outbound:"balancer:LP",domains:"lp.example"}],
     meta:{}}' > "$DB_FILE"

# ── 1. 渲染：三种策略都是 urltest，保持组内节点顺序、跳过不存在的节点；规则引用组的 tag；不需要 Clash API ──
# 内核带 with_clash_api 也不应写入：Clash API 只给故障转移组的监控服务用
sing-box() { [[ "$1" == version ]] && printf 'sing-box version 1.14.0\n\nTags: with_v2ray_api,with_clash_api\n'; }
SINGBOX_CONFIG_OUTPUT="$fixture/s.json" _render_singbox_config >/dev/null 2>"$fixture/s.err" ||
    fail "sing-box 渲染失败: $(cat "$fixture/s.err")"
unset -f sing-box
jq -e --arg A "$A" --arg B "$B" --arg C "$C" '
    def urltest($t; $o): {type:"urltest", tag:$t, outbounds:$o, url:"https://www.gstatic.com/generate_204",
                          interval:"10s", tolerance:50, idle_timeout:"30m"};
    def group($t): [.outbounds[] | select(.tag == $t)];
    group("balancer-RND") == [urltest("balancer-RND"; [$B, $A])] and
    group("balancer-RR") == [urltest("balancer-RR"; [$C, $A])] and
    group("balancer-LP") == [urltest("balancer-LP"; [$A, $C])] and
    ([.outbounds[] | select(.type == "selector")] | length) == 0 and
    .experimental.clash_api == null and
    any(.route.rules[]; .ip_cidr == ["127.0.0.1/32"] and .outbound == "balancer-RND") and
    any(.route.rules[]; .domain_suffix == ["rr.example"] and .outbound == "balancer-RR") and
    any(.route.rules[]; .domain_suffix == ["lp.example"] and .outbound == "balancer-LP")' "$fixture/s.json" >/dev/null ||
    fail "random/roundRobin 组应渲染为 urltest、规则应引用组 tag: $(jq -c '{o:[.outbounds[]|select(.tag|startswith("balancer-"))],
        e:.experimental.clash_api, r:.route.rules}' "$fixture/s.json")"
# 引用完整性：sing-box check 不校验，必须单独断言规则、分组、final 引用的出站都存在
jq -e '
    ([.outbounds[]?.tag] + [.endpoints[]?.tag]) as $tags |
    def known: . as $x | $x == null or ($tags | index($x) != null);
    all(.route.rules[]?; .outbound | known) and
    all(.outbounds[]? | select(.type == "selector" or .type == "urltest") | .outbounds[]; known) and
    (.route.final | known)' "$fixture/s.json" >/dev/null ||
    fail "存在引用不存在出站的规则或分组: $(jq -c '{tags:[.outbounds[]?.tag], r:[.route.rules[]?.outbound], f:.route.final}' "$fixture/s.json")"
if [[ -n "${SINGBOX_TEST_BIN:-}" ]]; then
    jq 'del(.log)' "$fixture/s.json" > "$fixture/s-native.json"
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$SINGBOX_TEST_BIN" check -c "$fixture/s-native.json" ||
        fail "sing-box 不接受生成的 urltest 组配置"
fi
echo 'PASS sing-box render: random/roundRobin as urltest (order kept, missing nodes skipped), rules reference balancer-<group>, no Clash API'

# ── 2. 真实运行：命中分流规则的连接进入组；第一个节点不可用时经下一个可用节点送达 ──
# 用生成配置的出站与路由，只把入站换成本机 mixed、检测网址换成本机 HTTP 服务（不依赖外网）。
# 修复前：规则出站 "balancer:RND" 不存在 → outbound not found；组为 selector 时固定走不可用的 B → 失败。
if [[ -z "${SINGBOX_TEST_BIN:-}" ]] || ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
    echo 'NOTE 未设置 SINGBOX_TEST_BIN 或缺少 python3/curl，未做真实运行验证' >&2
else
    PH=$(free_port) PM=$(free_port)
    mkdir -p "$fixture/www"
    printf 'via-node-A\n' > "$fixture/www/ok.txt"
    python3 -I -m http.server --bind 127.0.0.1 --directory "$fixture/www" "$PH" </dev/null >"$fixture/http.log" 2>&1 &
    pids+=($!)
    jq -n --argjson p "$PA" '{log:{level:"warn"}, inbounds:[{type:"socks", tag:"in", listen:"127.0.0.1", listen_port:$p}],
        outbounds:[{type:"direct", tag:"direct"}]}' > "$fixture/node-a.json"
    "$SINGBOX_TEST_BIN" run -c "$fixture/node-a.json" </dev/null >"$fixture/node-a.log" 2>&1 &
    pids+=($!)
    retry() { local n=$1 i; shift; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.2; done; return 1; }
    clean_log() { sed 's/\x1b\[[0-9;]*m//g' "$fixture/run.log" > "$fixture/run.clean"; }
    show_log() { clean_log; tail -n 30 "$fixture/run.clean"; }
    # HTTP 服务与节点 A 就绪后再启动主实例：组在启动时做首轮检测，此时 A 必须已可用，否则要等下一轮（10 秒）
    retry 50 curl -fsS --max-time 1 -o /dev/null -x "socks5h://127.0.0.1:$PA" "http://127.0.0.1:$PH/ok.txt" </dev/null 2>/dev/null ||
        fail "本机 HTTP 服务或节点 A 未就绪: $(cat "$fixture/http.log" "$fixture/node-a.log")"
    jq --argjson p "$PM" --arg url "http://127.0.0.1:$PH/ok.txt" '
        del(.log, .experimental) | .log = {level:"debug", timestamp:false} |
        .inbounds = [{type:"mixed", tag:"test-in", listen:"127.0.0.1", listen_port:$p}] |
        (.outbounds[] | select(.type == "urltest") | .url) = $url' "$fixture/s.json" > "$fixture/run.json"
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$SINGBOX_TEST_BIN" run -c "$fixture/run.json" \
        </dev/null >"$fixture/run.log" 2>&1 &
    pids+=($!)
    retry 50 grep -q 'sing-box started' "$fixture/run.log" || fail "sing-box 未能启动: $(show_log)"
    # 等首轮检测判定 A 可用；没有这条日志（如组不是 urltest）时最多等 5 秒，照常发请求，由请求结果判定
    retry 25 grep -q "balancer-RND\].*outbound $A available" "$fixture/run.log" || true
    body=$(curl -fsS --max-time 8 -x "socks5h://127.0.0.1:$PM" "http://127.0.0.1:$PH/ok.txt" </dev/null 2>&1) ||
        fail "经 random 组访问失败（规则未进入组或固定走了不可用节点）: $body | $(show_log)"
    [[ "$body" == via-node-A ]] || fail "响应内容不符: $body"
    sleep 0.3
    clean_log
    ! grep -q 'outbound not found' "$fixture/run.clean" || fail "运行时出现 outbound not found: $(show_log)"
    # 按连接 ID 核对这一个请求的路径（组检测自身也会经节点 A 访问同一服务，不能只看出站日志）：
    # 命中规则 → 进入 balancer-RND → 经节点 A 的 SOCKS 出站送达。最终出口不是 direct，排除"没进组也能通"的假通过。
    cid=$(grep -oE "\[[0-9]+ [^]]*\] inbound/mixed\[test-in\]: inbound connection to 127\.0\.0\.1:$PH" "$fixture/run.clean" |
        head -n 1 | grep -oE '^\[[0-9]+' | tr -d '[') || true
    [[ -n "$cid" ]] || fail "日志中找不到测试请求的连接: $(show_log)"
    grep -qE "\[$cid [^]]*\] router: match\[[0-9]+\] .*=> route\(balancer-RND\)" "$fixture/run.clean" ||
        fail "测试请求未命中 balancer-RND: $(show_log)"
    grep -qE "\[$cid [^]]*\] outbound/socks\[$A\]: outbound connection to 127\.0\.0\.1:$PH" "$fixture/run.clean" ||
        fail "测试请求未经节点 A 送达: $(show_log)"
    ! grep -qE "\[$cid [^]]*\] outbound/direct" "$fixture/run.clean" || fail "测试请求走了直连: $(show_log)"
    echo 'PASS sing-box run: routing rule reaches the random group, dead first node skipped, request served via node A'
fi

# ── 3. 菜单：创建时与查看时如实说明 sing-box 下按最低延迟 ──
_header() { :; }
_pause() { :; }
_line() { :; }
_item() { echo "$1. $2"; }
out=$(create_load_balance_group <<< $'2\n0\n' 2>&1) || fail "创建菜单异常退出: $out"
grep -q 'random .*随机选择；sing-box 协议按最低延迟' <<< "$out" || fail "策略列表 random 未说明 sing-box 行为: $out"
grep -q 'roundRobin .*轮询 - 流量均衡；sing-box 协议按最低延迟' <<< "$out" || fail "策略列表 roundRobin 未说明 sing-box 行为: $out"
grep -q 'sing-box 不支持随机选择：sing-box 协议使用该组时按最低延迟选择可用节点' <<< "$out" ||
    fail "选择 random 后未提示 sing-box 行为: $out"
out=$(create_load_balance_group <<< $'1\n0\n' 2>&1) || fail "创建菜单异常退出: $out"
if grep -q 'sing-box 不支持' <<< "$out"; then fail "选择 leastPing 不应提示 sing-box 不支持: $out"; fi
for fn in _create_alice_balancer_inline _create_akile_balancer_inline; do
    body=$(declare -f "$fn")
    grep -q '轮询 - 流量均衡；sing-box 协议按最低延迟' <<< "$body" &&
        grep -q 'sing-box 不支持随机/轮询' <<< "$body" || fail "$fn 未说明 sing-box 行为"
done
out=$(manage_chain_proxy <<< $'8\n0\n' 2>&1) || fail "链式代理菜单异常退出: $out"
grep -q 'sing-box 协议: 不支持随机选择，按最低延迟选择可用节点' <<< "$out" || fail "查看界面未标注 random 组: $out"
grep -q 'sing-box 协议: 不支持轮询，按最低延迟选择可用节点' <<< "$out" || fail "查看界面未标注 roundRobin 组: $out"
[[ $(grep -c 'sing-box 协议: 不支持' <<< "$out") -eq 2 ]] || fail "只有 random/roundRobin 组应标注: $out"
echo 'PASS menus: strategy list, random choice and group view describe sing-box latency-based behavior'
