#!/usr/bin/env bash
# Render private configurations only; no services, counters, or external endpoints.
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_listen_addr() { echo 127.0.0.1; }
mkdir() {
    # The production renderer prepares its log directory; keep that private too.
    if [[ "$*" == '-p /var/log/xray' ]]; then command mkdir -p "$fixture/log";
    else command mkdir "$@"; fi
}

for shape in object array; do
    for quota in 0 1073741824; do
        for cycle in false true; do
            for expiry in '' 2030-11-20; do
                jq -n --arg shape "$shape" --arg expiry "$expiry" --argjson quota "$quota" --argjson cycle "$cycle" '
                    {port:24199,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg==",multi_user:true,
                     users:[{name:"default-24199",uuid:"MTIzNDU2Nzg5MGFiY2RlZg==",used:11,quota:0,enabled:true},
                            {name:"alice",uuid:"ZmVkY2JhMDk4NzY1NDMyMQ==",used:1234,quota:$quota,enabled:true,
                             routing:"chain:exit",expire_date:$expiry,created:"2026-10-01",telegram_chat_id:"123"}]} as $port |
                    (if $cycle then $port | .users[1].traffic_reset={days:30,anchor:"2026-10-01",last_period:0} else $port end) as $managed |
                    {xray:{ss2022:(if $shape == "object" then $managed else [$managed,
                        {port:24200,method:"2022-blake3-aes-128-gcm",password:"YWJjZGVmZ2hpamtsbW5vcA==",multi_user:true,
                         users:[{name:"bob",uuid:"OTg3NjU0MzIxMGFiY2RlZg==",used:75,quota:0,enabled:true}]}] end)},
                     singbox:{},chain_proxy:{nodes:[{name:"exit",type:"socks",server:"127.0.0.1",port:1080}]},
                     routing_rules:[],meta:{}}' > "$DB_FILE"
                cp "$DB_FILE" "$fixture/before.json"
                rules=$(gen_xray_user_routing_rules)
                if ! jq -e 'length == 1 and .[0] == {type:"field",user:["alice@ss2022"],outboundTag:"chain-exit-prefer-ipv4"}' >/dev/null <<< "$rules"; then
                    printf 'FAIL user route: shape=%s quota=%s cycle=%s expiry=%s, rules=%s\n' "$shape" "$quota" "$cycle" "${expiry:-none}" "$rules" >&2
                    exit 1
                fi
                [[ $(gen_xray_user_routing_outbounds) == chain:exit ]]
                if ! XRAY_CONFIG_OUTPUT="$fixture/candidate.json" _render_xray_config >/dev/null; then
                    echo 'FAIL private Xray candidate generation' >&2
                    exit 1
                fi
                jq -e '
                    . as $cfg |
                    [.outbounds[].tag] as $tags |
                    any(.routing.rules[]; .user == ["alice@ss2022"] and .outboundTag == "chain-exit-prefer-ipv4") and
                    any(.outbounds[]; .tag == "chain-exit-prefer-ipv4" and .protocol == "socks" and .settings.servers[0].port == 1080) and
                    all(.routing.rules[] | select(.outboundTag != null); .outboundTag as $tag | $tags | index($tag) != null) and
                    ([.inbounds[] | select(.port == 24199) | .settings.clients[].email] | sort) == ["alice@ss2022","default-24199@ss2022"] and
                    (if ($cfg.inbounds | any(.port == 24200)) then
                        [.inbounds[] | select(.port == 24200) | .settings.clients[].email] == ["bob@ss2022"]
                     else true end)' "$fixture/candidate.json" >/dev/null
                cmp "$DB_FILE" "$fixture/before.json"
                if [[ -n "${XRAY_BIN:-}" ]]; then
                    # Native validation is optional; avoid writing live access/error logs.
                    jq '.log={loglevel:"none"}' "$fixture/candidate.json" > "$fixture/native.json"
                    "$XRAY_BIN" run -test -c "$fixture/native.json" >/dev/null 2>&1
                fi
            done
        done
    done
done
echo 'PASS SS2022 object/array routes across quota, 30-day cycle and expiry combinations; complete outbound references and unchanged database'

# The shared parser must also keep exact matches for direct/WARP and balancer names.
for route in direct warp chain:exit balancer:group; do
    _db_apply --arg route "$route" '.xray.ss2022[0].users[1].routing=$route'
    rules=$(gen_xray_user_routing_rules)
    case "$route" in
        direct) expected=direct ;;
        warp) expected=warp-prefer-ipv4 ;;
        chain:exit) expected=chain-exit-prefer-ipv4 ;;
        balancer:group) expected=balancer-group ;;
    esac
    jq -e --arg expected "$expected" 'length == 1 and ((.[0].outboundTag // .[0].balancerTag) == $expected)' >/dev/null <<< "$rules"
    case "$route" in direct) [[ -z $(gen_xray_user_routing_outbounds) ]] ;; *) [[ $(gen_xray_user_routing_outbounds) == "$route" ]] ;; esac
done
echo 'PASS expiry does not contaminate direct, WARP, chain or balancer routing fields'

# Exercise the other configuration branch: global rules plus a per-user exit,
# with both common node types. The explicit user route must take priority.
for node_type in socks shadowsocks; do
    _db_apply --arg type "$node_type" '
        .xray.ss2022[0].users[1].routing="chain:exit" |
        .routing_rules=[{type:"all",outbound:"direct",ip_version:"prefer_ipv4"}] |
        .chain_proxy.nodes[0] |= (.type=$type | .method="2022-blake3-aes-128-gcm" | .password="MTIzNDU2Nzg5MGFiY2RlZg==")'
    cp "$DB_FILE" "$fixture/before.json"
    if ! XRAY_CONFIG_OUTPUT="$fixture/global.json" _render_xray_config >/dev/null; then exit 1; fi
    jq -e --arg type "$node_type" '
        [.outbounds[].tag] as $tags |
        ([.routing.rules[] | select(.user != null)][0] | .user == ["alice@ss2022"] and .outboundTag == "chain-exit-prefer-ipv4") and
        any(.outbounds[]; .tag == "chain-exit-prefer-ipv4" and .protocol == $type) and
        all(.routing.rules[] | select(.outboundTag != null); .outboundTag as $tag | $tags | index($tag) != null)' "$fixture/global.json" >/dev/null
    cmp "$DB_FILE" "$fixture/before.json"
done
echo 'PASS global routing preserves the expiring SS2022 user override for SOCKS5 and Shadowsocks exits'
