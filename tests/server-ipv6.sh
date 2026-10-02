#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
G= D= NC=

[[ $(_server_ipv6_key '2606:4700::ABCD') == 2606470000000000000000000000abcd ]]
[[ $(_server_ipv6_key '2606:4700:0:0:0:0:0:abcd') == $(_server_ipv6_key '2606:4700::abcd') ]]
for value in '2606:::1' '2001::2::3' '127.0.0.1' '[2606::1]' '2606::1%eth0' 'bad'; do
    if _server_ipv6_key "$value"; then exit 1; fi
done
for value in '::' '::1' 'fe80::1' 'ff02::1' '2001:db8::1' '2001:2::1' '3fff::1'; do
    if _server_ipv6_scope "$(_server_ipv6_key "$value")"; then exit 1; fi
done
[[ $(_server_ipv6_scope "$(_server_ipv6_key 'fd00::1')") == local ]]
[[ $(_server_ipv6_scope "$(_server_ipv6_key '2001:2:abcd::1')") == public ]]
echo 'PASS canonical IPv6 deduplication and non-node address classification'

cat > "$fixture/ip" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN
    inet6 ::1/128 scope host
2: eth0@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
    inet6 2606:4700::5/64 scope global temporary dynamic
    inet6 2606:4700::2/64 scope global dynamic mngtmpaddr
    inet6 2606:4700:0:0:0:0:0:2/64 scope global
    inet6 fd00::2/64 scope global
    inet6 fe80::2/64 scope link
    inet6 2606:4700::6/64 scope global tentative
    inet6 2606:4700::7/64 scope global dadfailed
    inet6 2606:4700::8/64 scope global deprecated
3: eth1: <BROADCAST,MULTICAST> mtu 1500 state DOWN
    inet6 2606:4700::9/64 scope global
EOF
ip() { [[ "$*" == '-6 addr show' ]]; cat "$fixture/ip"; }
expected=$'2606:4700::2|eth0|stable|public\n2606:4700::5|eth0|temporary|public\nfd00::2|eth0|stable|local'
[[ $(get_server_ipv6_addresses) == "$expected" ]]
curl() { echo 'unexpected network access' >&2; return 99; }
show_server_ipv6 details > "$fixture/display"
grep -q '本机 IPv6: 2606:4700::2' "$fixture/display"
grep -q '临时地址' "$fixture/display"
grep -q '仅内网可用' "$fixture/display"
grep -q '服务器地址' "$fixture/display"
grep -q '\[IPv6\]:端口' "$fixture/display"
! grep -q '2606:4700::[6789]' "$fixture/display"
echo 'PASS interface-first display without Internet; stable/temporary/ULA, DAD and down-interface filtering'
cat >> "$fixture/ip" <<'EOF'
4: wgcf: <UP> mtu 1280
    inet6 2606:4700::1/128 scope global
EOF
[[ $(get_server_ipv6_addresses | head -n 1) == '2606:4700::2|eth0|stable|public' ]]
show_server_ipv6 details > "$fixture/display"
grep -q 'WARP IPv6: 2606:4700::1' "$fixture/display"
grep -q '不推荐用于直连节点' "$fixture/display"
! grep -q '本机 IPv6: 2606:4700::1 ' "$fixture/display"
echo 'PASS assigned WARP tunnel addresses are separated from ordinary server addresses'

# Kernel fallback retains exact address-state flags without ip/hostname dependencies.
_server_ipv6_interface_up() { [[ "$1" == eth0 ]]; }
proc_rows=$(_parse_server_ipv6_proc <<'EOF'
26064700000000000000000000000002 02 40 00 80 eth0
26064700000000000000000000000005 02 40 00 01 eth0
26064700000000000000000000000006 02 40 00 c0 eth0
26064700000000000000000000000007 02 40 00 88 eth0
26064700000000000000000000000008 02 40 00 a0 eth0
26064700000000000000000000000009 03 40 00 80 eth1
EOF
)
[[ "$proc_rows" == $'2606:4700:0:0:0:0:0:2|eth0|stable\n2606:4700:0:0:0:0:0:5|eth0|temporary' ]]
echo 'PASS /proc fallback rejects tentative/deprecated/DAD-failed/down addresses'

# No local GUA: reject NAT64 IPv4, HTML and private data; direct IPv6 and strict HTTPS.
: > "$fixture/ip"
curl() {
    printf '%s\n' "$*" >> "$fixture/curl-log"
    [[ "$1" == -q && "$*" == *"-6 --noproxy *"* && "$*" == *'--max-time 3'* && "$*" != *' -k '* ]] || return 1
    case "${@: -1}" in
        https://api6.ipify.org) printf '%s\n' "${probe_first_response:-192.0.2.1}" ;;
        https://ifconfig.co/ip) echo '<html>bad response</html>' ;;
        *) printf '2606:4700::123\r\n' ;;
    esac
}
_SERVER_IPV6_PROBED_AT=-60
show_server_ipv6 > "$fixture/display"
grep -q '未检测到可用于节点的地址' "$fixture/display"
grep -q 'IPv6 出口: 2606:4700::123' "$fixture/display"
grep -q '不能直接用于节点' "$fixture/display"
[[ $(wc -l < "$fixture/curl-log") == 3 ]]
show_server_ipv6 >/dev/null
[[ $(wc -l < "$fixture/curl-log") == 3 ]]
echo 'PASS bounded multi-provider direct IPv6 probes distinguish egress from local addresses and cache results'
for probe_first_response in $'2606:4700::1\n2' '2606: 4700::1' 'fd00::1'; do
    [[ $(_probe_server_ipv6_egress) == 2606:4700::123 ]]
done
unset probe_first_response
echo 'PASS malformed whitespace/multiline/private responses cannot become a node address'

# Failed probes are cached too; a local-interface change bypasses the old cache.
curl() { echo attempted >> "$fixture/fail-log"; return 1; }
_SERVER_IPV6_PROBED_AT=-60
show_server_ipv6 >/dev/null
show_server_ipv6 >/dev/null
[[ $(wc -l < "$fixture/fail-log") == 3 ]]
_SERVER_IPV6_PROBED_AT=$((SECONDS - 60))
show_server_ipv6 >/dev/null
[[ $(wc -l < "$fixture/fail-log") == 6 ]]
cat > "$fixture/ip" <<'EOF'
2: eth0: <UP> mtu 1500
    inet6 2606:4700::42/64 scope global
EOF
show_server_ipv6 > "$fixture/display"
grep -q '本机 IPv6: 2606:4700::42' "$fixture/display"
! grep -q 'IPv6 出口' "$fixture/display"
[[ $(wc -l < "$fixture/fail-log") == 6 ]]
echo 'PASS negative-cache expiry and immediate refresh when interfaces change'

# Run the real configuration renderer with an IPv4-only saved node, no mutations.
init_db
_db_apply '.xray["vless"]={ipv4:"192.0.2.10",port:443,uuid:"test-uuid",sni:"example.com",public_key:"test-key",short_id:"abcd"}'
cp "$DB_FILE" "$fixture/before-db"
get_ip_country() { echo US; }
gen_qr() { :; }
# Existing renderer ends with an optional UI condition; production has no errexit.
show_single_protocol_info vless false > "$fixture/node" || true
grep -q '本机 IPv6: 2606:4700::42' "$fixture/node"
grep -q '服务器地址' "$fixture/node"
grep -q '192.0.2.10' "$fixture/node"
cmp "$DB_FILE" "$fixture/before-db"
echo 'PASS post-install configuration display uses current interfaces even for saved IPv4-only nodes and preserves node data'

# Real main menu, startup/network mutations mocked; enter 0 to exit normally.
for fn in check_root init_log ensure_startup_dependencies db_migrate_to_multiuser ensure_singbox_runtime_consistency _auto_update_system_script repair_scheduled_jobs _init_version_cache _update_all_versions_async _check_script_update_async _check_version_updates_async _sync_tunnel_config _header; do
    eval "$fn() { :; }"
done
_get_core_version_with_status() { echo unavailable; }
_get_core_version() { echo unavailable; }
_has_script_update() { return 1; }
show_status() { _INSTALLED_CACHE=''; echo status; }
DISTRO=alpine
(main_menu <<< 0) > "$fixture/menu" 2>&1
grep -q '本机 IPv6: 2606:4700::42' "$fixture/menu"
grep -q '安装协议' "$fixture/menu"
cmp "$DB_FILE" "$fixture/before-db"
echo 'PASS main-menu visibility and unchanged menu/configuration behavior'
