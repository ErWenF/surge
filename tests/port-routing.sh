#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
DB_FILE="$fixture/db.json"
CFG="$fixture/cfg"
mkdir -p "$CFG"

load_function() {
    eval "$(awk -v fn="$1" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {exit}' "$repo/vless-server.sh")"
}
for fn in ensure_flock _flock_ticks flock_wait flock_unlock \
    _db_lock_acquire _db_lock_release _with_db_lock _restore_db_backup \
    db_get_port_config db_set_port_routing db_update_port db_remove_port db_del db_chain_node_exists db_get_chain_node \
    db_del_chain_node db_rename_chain_node gen_xray_chain_outbound gen_singbox_chain_outbound \
    _apply_port_routing_config apply_port_routing_change; do
    load_function "$fn"
done
_db_apply() { jq "$@" "$DB_FILE" > "$fixture/new.json" && mv "$fixture/new.json" "$DB_FILE"; }
_err() { echo "$*" >&2; }
_flush_core_traffic() { :; }

jq -n '{
    xray:{socks:[{port:21001},{port:21002}]},
    singbox:{vless:{port:22001}},
    chain_proxy:{nodes:[{name:"Global-Home",type:"shadowsocks",server:"167.104.96.167",port:11398,
        method:"2022-blake3-aes-128-gcm",password:"test-secret"}]}
}' > "$DB_FILE"

db_set_port_routing xray socks 21001 chain:Global-Home
db_set_port_routing singbox vless 22001 direct
[[ $(jq '.port_routing | length' "$DB_FILE") == 2 ]]
if db_set_port_routing xray socks 21003 direct; then exit 1; fi
if db_set_port_routing xray socks 21002 chain:missing; then exit 1; fi

jq -n '{inbounds:[{tag:"api",port:10085},{tag:"socks-21001",port:21001},
    {tag:"socks-21002",port:21002},{tag:"ip-in-192-0-2-1-21001",port:21001}],
    outbounds:[{protocol:"freedom",tag:"direct"}],
    routing:{rules:[{type:"field",inboundTag:["api"],outboundTag:"api"},
        {type:"field",inboundTag:["socks-21001"],outboundTag:"user"},
        {type:"field",inboundTag:["socks-21002"],outboundTag:"other"}]}}' > "$CFG/config.json"
_apply_port_routing_config xray "$CFG/config.json"
jq -e '
    .routing.rules[0].outboundTag == "api" and
    .routing.rules[1].outboundTag == "port-route-xray-socks-21001" and
    (.routing.rules[1].inboundTag | sort) == ["ip-in-192-0-2-1-21001","socks-21001"] and
    .routing.rules[1].network == null and
    .routing.rules[2].outboundTag == "user" and
    .routing.rules[3].outboundTag == "other" and
    ([.outbounds[] | select(.tag == "port-route-xray-socks-21001" and
        .protocol == "shadowsocks" and .settings.domainStrategy == null)] | length) == 1
' "$CFG/config.json" >/dev/null

jq -n '{inbounds:[{tag:"vless-in-22001",listen_port:22001}],
    outbounds:[{type:"direct",tag:"direct"}]}' > "$CFG/singbox.json"
_apply_port_routing_config singbox "$CFG/singbox.json"
jq -e '.route.rules[0] == {inbound:["vless-in-22001"],outbound:"direct"} and
    .route.final == "direct"' "$CFG/singbox.json" >/dev/null

db_set_port_routing singbox vless 22001 chain:Global-Home
jq -n '{inbounds:[{tag:"vless-in-22001",listen_port:22001}],
    outbounds:[{type:"direct",tag:"direct"}]}' > "$CFG/singbox.json"
_apply_port_routing_config singbox "$CFG/singbox.json"
jq -e '.route.rules[0].outbound == "port-route-singbox-vless-22001" and
    ([.outbounds[] | select(.tag == "port-route-singbox-vless-22001" and
        .type == "shadowsocks" and .domain_strategy == null)] | length) == 1
' "$CFG/singbox.json" >/dev/null

db_rename_chain_node Global-Home Renamed
jq -e '.port_routing[0].outbound == "chain:Renamed"' "$DB_FILE" >/dev/null
db_del_chain_node Renamed
jq -e '[.port_routing[] | select(.core == "xray")] | length == 0' "$DB_FILE" >/dev/null
db_set_port_routing xray socks 21001 direct
db_update_port xray socks 21001 '{"port":21003}'
jq -e '[.port_routing[] | select(.core == "xray")] | length == 0' "$DB_FILE" >/dev/null
db_set_port_routing xray socks 21003 direct
db_remove_port xray socks 21003
jq -e '[.port_routing[] | select(.core == "xray")] | length == 0' "$DB_FILE" >/dev/null
db_del singbox vless
jq -e '.port_routing == []' "$DB_FILE" >/dev/null

printf 'original config\n' > "$CFG/config.json"
cp "$DB_FILE" "$fixture/db-before.json"
cp "$CFG/config.json" "$fixture/config-before.json"
cp "$CFG/singbox.json" "$fixture/singbox-before.json"
svc() {
    printf '%s %s\n' "$1" "$2" >> "$fixture/service-events"
    [[ "$1" != status ]]
}
if apply_port_routing_change xray socks 21001 direct; then exit 1; fi
if apply_port_routing_change singbox vless 22001 direct; then exit 1; fi
cmp "$DB_FILE" "$fixture/db-before.json"
cmp "$CFG/config.json" "$fixture/config-before.json"
cmp "$CFG/singbox.json" "$fixture/singbox-before.json"
[[ ! -d "$CFG/backups" ]]
[[ $(cat "$fixture/service-events") == $'status vless-reality\nstatus vless-singbox' ]]
echo 'PASS port routing precedence, inbound tags, both cores, node lifecycle and port cleanup'
