#!/usr/bin/env bash
# sing-box 用户路由指向负载均衡组（含主备故障转移组）：
# - 没有全局分流规则时也生成组出站和节点出站，auth_user 规则指向组；
# - 有全局分流规则时复用已生成的组，不重复生成出站；
# - 故障转移组能被 vless-failover 监控识别；
# - 菜单可选负载均衡组；组不存在或路由类型不支持时给出提示，不静默忽略。
# 只在临时目录渲染，不启动任何服务；设置 SINGBOX_TEST_BIN 时用真实 sing-box check 校验。
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_listen_addr() { echo 127.0.0.1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
A=chain-A-prefer-ipv4 B=chain-B-prefer-ipv4 C=chain-C-prefer-ipv4
# 模拟带 Clash API 的内核版本信息（真实校验走 SINGBOX_TEST_BIN，不受此函数影响）
sing-box() { [[ "$1" == version ]] && printf 'sing-box version 1.14.0\n\nTags: with_v2ray_api,with_clash_api\n'; }

base_db() {  # $1 = 全局分流规则 JSON
    jq -n --argjson rules "$1" '
        {xray:{},
         singbox:{vless:{port:24400, uuid:"11111111-1111-1111-1111-111111111111",
             private_key:"Qbvgwlmt-5q-xmzsE6Bx7ZUttt1ZSkKL2NgebpcVSsM", short_id:"0123abcd",
             sni:"www.microsoft.com", security_mode:"reality",
             users:[{name:"default", uuid:"11111111-1111-1111-1111-111111111111", used:0, quota:0, enabled:true},
                    {name:"alice", uuid:"22222222-2222-2222-2222-222222222222", used:0, quota:0, enabled:true, routing:"balancer:FO"},
                    {name:"bob",   uuid:"33333333-3333-3333-3333-333333333333", used:0, quota:0, enabled:true, routing:"balancer:LP"},
                    {name:"carol", uuid:"44444444-4444-4444-4444-444444444444", used:0, quota:0, enabled:true, routing:"balancer:Gone"},
                    {name:"dave",  uuid:"55555555-5555-5555-5555-555555555555", used:0, quota:0, enabled:true, routing:"outbound:custom"}]}},
         chain_proxy:{nodes:[{name:"A", type:"socks", server:"127.0.0.1", port:1081},
                             {name:"B", type:"socks", server:"127.0.0.1", port:1082},
                             {name:"C", type:"socks", server:"127.0.0.1", port:1083}]},
         balancer_groups:[{name:"FO", strategy:"failover", nodes:["B", "A", "Missing"]},
                          {name:"LP", strategy:"leastPing", nodes:["A", "C"]}],
         routing_rules:$rules, meta:{}}' > "$DB_FILE"
}
render() {  # $1 = 输出文件名（不含路径）
    SINGBOX_CONFIG_OUTPUT="$fixture/$1.json" _render_singbox_config >/dev/null 2>"$fixture/$1.err" ||
        fail "sing-box 渲染失败（$1）: $(cat "$fixture/$1.err")"
}
# sing-box check 不校验出站引用（引用不存在的 tag 也返回 0，启动时才报错），这里单独校验
refs_check() {
    jq -e '[.outbounds[].tag, .endpoints[]?.tag] as $tags |
        [(.outbounds[] | (.outbounds // [])[], (.default // empty)), (.route.rules[]?.outbound // empty), (.route.final // empty)] |
        all(. as $t | $tags | index($t) != null)' "$fixture/$1.json" >/dev/null ||
        fail "存在引用了不存在出站的 tag（$1）: $(jq -c '{tags:[.outbounds[].tag], r:.route}' "$fixture/$1.json")"
}
native_check() {
    refs_check "$1"
    if [[ -z "${SINGBOX_TEST_BIN:-}" ]]; then
        echo "NOTE: 未设置 SINGBOX_TEST_BIN，未用真实 sing-box check 校验 $1"
        return 0
    fi
    jq 'del(.log)' "$fixture/$1.json" > "$fixture/$1-native.json"
    ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$SINGBOX_TEST_BIN" check -c "$fixture/$1-native.json" ||
        fail "sing-box 不接受生成的配置（$1）"
}

# ── 1. 没有全局分流规则：用户路由引用的组及其节点出站也要生成 ──
base_db '[]'
# erin 指向节点全部无效的 leastPing 组：候选为空会让 sing-box 拒绝整份配置，应提示并跳过该用户
jq '.balancer_groups += [{name:"Empty", strategy:"leastPing", nodes:["Missing"]}]
    | .singbox.vless.users += [{name:"erin", uuid:"66666666-6666-6666-6666-666666666666", used:0, quota:0, enabled:true, routing:"balancer:Empty"}]' \
    "$DB_FILE" > "$fixture/db" && mv "$fixture/db" "$DB_FILE"
render s1
secret=$(cat "$CFG/singbox-clash-api.secret" 2>/dev/null || true)  # 缺失时由下面的断言报告
jq -e --arg A "$A" --arg B "$B" --arg C "$C" --arg s "$secret" '
    .outbounds[0].tag == "direct" and
    (.outbounds[] | select(.tag == "balancer-FO")) == {type:"selector", tag:"balancer-FO", outbounds:[$B, $A, "direct"],
        default:$B, interrupt_exist_connections:true} and
    ((.outbounds[] | select(.tag == "balancer-LP")) | .type == "urltest" and .outbounds == [$A, $C]) and
    ([.outbounds[].tag] | sort) == (["direct", "balancer-FO", "balancer-LP", $A, $B, $C] | sort) and
    .route.final == "direct" and
    .route.rules == [{auth_user:["vless-alice"], outbound:"balancer-FO"}, {auth_user:["vless-bob"], outbound:"balancer-LP"}] and
    .experimental.clash_api == {external_controller:"127.0.0.1:10087", secret:$s}' "$fixture/s1.json" >/dev/null ||
    fail "无全局规则时用户路由的组出站/规则不符: $(jq -c '{o:[.outbounds[]|{tag,type,outbounds}], r:.route, e:.experimental.clash_api}' "$fixture/s1.json")"
grep -q 'carol.*不存在的负载均衡组 Gone' "$fixture/s1.err" || fail "组不存在时应提示: $(cat "$fixture/s1.err")"
grep -q 'dave.*outbound:custom 不受支持' "$fixture/s1.err" || fail "不支持的路由类型应提示: $(cat "$fixture/s1.err")"
grep -q 'Empty 没有可用节点.*erin' "$fixture/s1.err" || fail "组内没有可用节点时应提示: $(cat "$fixture/s1.err")"
native_check s1
echo 'PASS sing-box user routing without global rules: failover selector + leastPing urltest with node outbounds, auth_user rules, Clash API, warnings for missing group, empty group and unsupported type'

# ── 2. 有全局分流规则：复用分流规则路径生成的组，出站不重复，用户规则排在全局规则前 ──
base_db '[{"id":"custom_1","type":"custom","outbound":"chain:A","domains":"example.com"}]'
render s2
jq -e --arg A "$A" '
    ([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length) and
    ([.outbounds[] | select(.tag == "balancer-FO")] | length) == 1 and
    .route.rules[0] == {auth_user:["vless-alice"], outbound:"balancer-FO"} and
    .route.rules[1] == {auth_user:["vless-bob"], outbound:"balancer-LP"} and
    any(.route.rules[2:][]; .outbound == $A) and
    .experimental.clash_api != null' "$fixture/s2.json" >/dev/null ||
    fail "有全局规则时组出站重复或规则顺序不符: $(jq -c '{o:[.outbounds[].tag], r:.route.rules}' "$fixture/s2.json")"
native_check s2
echo 'PASS sing-box user routing with global rules: groups reused, no duplicate outbounds, user rules first'

# ── 3. 只被用户路由引用的故障转移组能被监控识别 ──
cp "$fixture/s1.json" "$CFG/singbox.json"
rm -f "$CFG/config.json" "$fixture/steps"
_failover_step() { echo "$1 $2 ${*:4}" >> "$fixture/steps"; printf '%s' "$3"; }
failover_check_once || fail "监控检查失败"
[[ "$(cat "$fixture/steps" 2>/dev/null)" == "singbox FO B A Missing" ]] ||
    fail "监控应识别 sing-box 故障转移组 FO（且只识别故障转移组）: $(cat "$fixture/steps" 2>/dev/null)"
unset -f _failover_step
echo 'PASS failover monitor recognizes a sing-box failover group referenced only by user routing'

# ── 4. 菜单：设置用户路由时能选到负载均衡组 ──
warp_status() { return 1; }
menu=$(_select_user_routing <<< "0" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') || true
idx=$(grep -E '^ *[0-9]+\) 负载→FO$' <<< "$menu" | grep -oE '[0-9]+' | head -1)
[[ -n "$idx" ]] || fail "用户路由菜单缺少负载均衡组: $menu"
_select_user_routing <<< "$idx" >/dev/null 2>&1 || fail "选择负载均衡组失败"
[[ "$SELECTED_ROUTING" == "balancer:FO" ]] || fail "选择结果应为 balancer:FO，实际 $SELECTED_ROUTING"
[[ "$(_format_user_routing "$SELECTED_ROUTING")" == "负载→FO" ]] || fail "路由显示不符"
echo 'PASS user routing menu offers balancer groups'
