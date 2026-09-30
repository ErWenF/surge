#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_flush_core_traffic() { :; }
install_xray() { :; }
install_singbox() { :; }
create_service() { :; }
create_singbox_service() { :; }
svc() {
    echo "$*" >> "$fixture/events"
    case "$1" in
        status|is-enabled) [[ -f "$fixture/$2.$1" ]] ;;
        start|restart)
            if [[ -f "$fixture/fail-start" ]]; then rm "$fixture/fail-start"; return 1; fi
            touch "$fixture/$2.status" ;;
        stop) rm -f "$fixture/$2.status" ;;
        enable) touch "$fixture/$2.is-enabled" ;;
        disable) rm -f "$fixture/$2.is-enabled" ;;
    esac
}
printf '#!/usr/bin/env bash\njq empty "${@: -1}"\n' > "$fixture/check"
chmod 755 "$fixture/check"
XRAY_BIN="$fixture/check" SINGBOX_BIN="$fixture/check"
generate_xray_config() {
    jq '{inbounds:[.xray | to_entries[] | .key as $p | .value | (if type=="array" then .[] else . end) |
        {port:.port,tag:($p+"-"+(.port|tostring))}]}' "$DB_FILE" > "$XRAY_CONFIG_OUTPUT"
}
generate_singbox_config() {
    jq '{inbounds:[.singbox | to_entries[] | .key as $p | .value | (if type=="array" then .[] else . end) |
        {listen_port:.port,tag:($p+"-in-"+(.port|tostring))}]}' "$DB_FILE" > "$SINGBOX_CONFIG_OUTPUT"
}
_db_apply '.xray={trojan:{port:24191,password:"test"},socks:{port:24192}} | .singbox={hy2:{port:24193}} |
    .port_routing=[{core:"xray",protocol:"trojan",port:24191,outbound:"direct"}]'
XRAY_CONFIG_OUTPUT="$CFG/config.json" generate_xray_config
SINGBOX_CONFIG_OUTPUT="$CFG/singbox.json" generate_singbox_config
touch "$fixture/vless-reality.status" "$fixture/vless-reality.is-enabled"
cp "$DB_FILE" "$fixture/before"
cp "$CFG/config.json" "$fixture/old-xray"
cp "$CFG/singbox.json" "$fixture/old-singbox"
touch "$fixture/fail-start"
if switch_protocol_core trojan singbox; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
cmp "$CFG/config.json" "$fixture/old-xray"
cmp "$CFG/singbox.json" "$fixture/old-singbox"
[[ -f "$fixture/vless-reality.status" && ! -f "$fixture/vless-singbox.status" ]]
switch_protocol_core trojan singbox
jq -e '.singbox.trojan.port==24191 and .xray.trojan==null and .port_routing[0].core=="singbox"' "$DB_FILE" >/dev/null
[[ -f "$fixture/vless-reality.status" && -f "$fixture/vless-singbox.status" ]]
! grep -Eq 'vless-(snell|naive|anytls)' "$fixture/events"
echo 'PASS core switch preserves unrelated services and restores both configurations and original service states on failure'

# A disabled SS2022 port must still reject a missing or invalid outbound.
_db_apply '.xray.ss2022={port:24194,multi_user:true,users:[{enabled:false}]} |
    .port_routing=[{core:"xray",protocol:"ss2022",port:24194,outbound:"chain:missing"}]'
echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$fixture/closed"
if _apply_port_routing_config xray "$fixture/closed"; then exit 1; fi
_db_apply '.chain_proxy.nodes=[{name:"standby",type:"shadowsocks",server:"127.0.0.1",port:24195,
    method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg=="}] |
    .port_routing[0].outbound="chain:standby"'
_apply_port_routing_config xray "$fixture/closed"
jq -e '.routing.rules==[] and any(.outbounds[]; .tag=="port-route-xray-ss2022-24194")' "$fixture/closed" >/dev/null
echo 'PASS disabled port validates standby outbound without installing an empty match rule'

_db_apply '.singbox.hy2=[{port:25191,hop_enable:1,hop_start:26001,hop_end:26010},
    {port:25192,hop_enable:1,hop_start:26011,hop_end:26020}] | .singbox.tuic={port:25193,hop_enable:1,hop_start:26021,hop_end:26030}'
create_server_scripts
iptables() { echo "$*" >> "$fixture/nat"; [[ "$*" != *" -C "* ]]; }
ip6tables() { iptables "$@"; }
export -f iptables ip6tables
export fixture
for proto in hy2 tuic; do
    sed "s#^CFG=/etc/vless-reality#CFG=$CFG#" "$CFG/$proto-nat.sh" > "$fixture/run-nat"
    bash "$fixture/run-nat"
done
for port in 25191 25192 25193; do grep -q "to-ports $port" "$fixture/nat"; done
grep -q 'vless-hy2-hop' "$fixture/nat"
grep -q 'vless-tuic-hop' "$fixture/nat"
echo 'PASS generated NAT scripts support both single and multiple ports without touching live firewall'
