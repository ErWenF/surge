#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
CFG="$fixture"
DB_FILE="$fixture/db.json"
xray_output_file="$fixture/config.json"
listen_addr=127.0.0.1

load_function() {
    eval "$(awk -v fn="$1" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {exit}' "$repo/vless-server.sh")"
}
for fn in gen_xray_ss2022_clients add_xray_inbound_v2; do load_function "$fn"; done

db_get() {
    local proto="$2" port=''
    if [[ "$proto" =~ ^ss2022_port_([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
        jq --arg port "$port" '[.xray.ss2022[] | select((.port | tostring) == $port)][0]' "$DB_FILE"
    else
        jq --arg proto "$proto" '.xray[$proto]' "$DB_FILE"
    fi
}
db_exists() {
    [[ "$2" == ss2022 || "$2" == ss2022_port_* ]]
}
db_ip_routing_enabled() { return 1; }
_err() { printf '%s\n' "$*" >&2; }

jq -n '{xray:{ss2022:[
    {port:24198,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg=="},
    {port:24199,method:"2022-blake3-aes-128-gcm",password:"YWJjZGVmZ2hpamtsbW5vcA==",multi_user:true,
     users:[{name:"default-24199",uuid:"MTIzNDU2Nzg5MGFiY2RlZg==",enabled:true},
            {name:"alice",uuid:"ZmVkY2JhMDk4NzY1NDMyMQ==",enabled:true},
            {name:"bob",uuid:"OTg3NjU0MzIxMGFiY2RlZg==",enabled:false}]}
]}}' > "$DB_FILE"
jq -n '{inbounds:[],outbounds:[{protocol:"freedom"}]}' > "$xray_output_file"
add_xray_inbound_v2 ss2022_port_24198
add_xray_inbound_v2 ss2022_port_24199
jq -e '
    (.inbounds | length) == 2 and
    (.inbounds[0].settings | has("clients") | not) and
    (.inbounds[1].settings.clients | map(.email) == ["default-24199@ss2022","alice@ss2022"]) and
    (.inbounds[0].tag == "ss2022-24198") and (.inbounds[1].tag == "ss2022-24199")
' "$xray_output_file" >/dev/null

"${XRAY_BIN:?set XRAY_BIN to the Xray executable}" run -test -c "$xray_output_file" >/dev/null
before=$(sha256sum "$xray_output_file" | awk '{print $1}')
jq '.xray.ss2022[1].users |= map(.enabled=false)' "$DB_FILE" > "$fixture/disabled.json"
mv "$fixture/disabled.json" "$DB_FILE"
rc=0
add_xray_inbound_v2 ss2022_port_24199 || rc=$?
[[ "$rc" == 2 ]]
after=$(sha256sum "$xray_output_file" | awk '{print $1}')
[[ "$before" == "$after" ]]
master256=$(printf '0123456789abcdef0123456789abcdef' | base64 | tr -d '\n')
default256=$(printf 'abcdef0123456789abcdef0123456789' | base64 | tr -d '\n')
jq -n --arg master "$master256" --arg default "$default256" '{xray:{ss2022:
    {port:24200,method:"2022-blake3-aes-256-gcm",password:$master,multi_user:true,
     users:[{name:"default-24200",uuid:$default,enabled:true}]}}}' > "$DB_FILE"
jq -n '{inbounds:[],outbounds:[{protocol:"freedom"}]}' > "$xray_output_file"
add_xray_inbound_v2 ss2022
jq -e '.inbounds[0].settings.clients[0].email == "default-24200@ss2022"' "$xray_output_file" >/dev/null
"$XRAY_BIN" run -test -c "$xray_output_file" >/dev/null
echo 'PASS SS2022 per-port Xray config and empty-client guard'
