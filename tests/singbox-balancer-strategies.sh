#!/usr/bin/env bash
# sing-box 负载均衡组：
# - random / roundRobin 渲染为 urltest（按最低延迟选择可用节点）。sing-box 只有 selector / urltest 两种分组出站，
#   没有随机/轮询（上游不计划支持）。原先渲染成 selector 且 default 为第一个节点：实际永远走第一个节点，
#   既不随机也不轮询，节点不可用时也不会切走。
# - 菜单如实说明 sing-box 下的行为。
# 只在临时目录渲染，不启动任何服务。
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_listen_addr() { echo 127.0.0.1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
A=chain-A-prefer-ipv4 B=chain-B-prefer-ipv4 C=chain-C-prefer-ipv4

jq -n '{xray:{}, singbox:{ss2022:{port:24300,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg=="}},
    chain_proxy:{nodes:[{name:"A",type:"socks",server:"127.0.0.1",port:1081},
                        {name:"B",type:"socks",server:"127.0.0.1",port:1082},
                        {name:"C",type:"socks",server:"127.0.0.1",port:1083}]},
    balancer_groups:[{name:"RND",strategy:"random",nodes:["B","A","Missing"]},
                     {name:"RR",strategy:"roundRobin",nodes:["C","A"]},
                     {name:"LP",strategy:"leastPing",nodes:["A","C"]}],
    routing_rules:[{id:"custom_1",type:"custom",outbound:"balancer:RND",domains:"127.0.0.1/32"},
                   {id:"custom_2",type:"custom",outbound:"balancer:RR",domains:"rr.example"},
                   {id:"custom_3",type:"custom",outbound:"balancer:LP",domains:"lp.example"}],
    meta:{}}' > "$DB_FILE"

# ── 1. 渲染：三种策略都是 urltest，保持组内节点顺序、跳过不存在的节点；不需要 Clash API ──
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
    .experimental.clash_api == null' "$fixture/s.json" >/dev/null ||
    fail "random/roundRobin 组应渲染为 urltest: $(jq -c '{o:[.outbounds[]|select(.tag|startswith("balancer-"))],
        e:.experimental.clash_api}' "$fixture/s.json")"
if [[ -n "${SINGBOX_TEST_BIN:-}" ]]; then
    jq 'del(.log)' "$fixture/s.json" > "$fixture/s-native.json"
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$SINGBOX_TEST_BIN" check -c "$fixture/s-native.json" ||
        fail "sing-box 不接受生成的 urltest 组配置"
fi
echo 'PASS sing-box render: random/roundRobin as urltest (order kept, missing nodes skipped), no Clash API'

# ── 2. 菜单：创建时与查看时如实说明 sing-box 下按最低延迟 ──
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
