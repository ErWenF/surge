#!/usr/bin/env bash
set -e
if [[ ${IPV6_NATIVE_TEST:-0} != 1 ]]; then
    echo 'SKIP IPv6 native interface test (IPV6_NATIVE_TEST unset)'
    exit 0
fi
source "$(dirname "$0")/lib/core-fixture.sh"
dev="vl6test$$"
trap 'command ip link del "$dev" 2>/dev/null || true; rm -rf "$fixture"' EXIT
ip link add "$dev" type dummy
ip link set "$dev" up
ip -6 addr add 2606:4700:ffff::123/128 dev "$dev" nodad
ip -6 addr add fd00:ffff::123/128 dev "$dev" nodad
ip -6 addr add 2606:4700:ffff::124/128 dev "$dev" nodad preferred_lft 0
rows=$(get_server_ipv6_addresses)
grep -Fq "2606:4700:ffff::123|$dev|stable|public" <<< "$rows"
grep -Fq "fd00:ffff::123|$dev|stable|local" <<< "$rows"
! grep -Fq '2606:4700:ffff::124' <<< "$rows"
# Kernel fallback exercised against real /proc, including IFA_F_DEPRECATED.
proc_rows=$(_parse_server_ipv6_proc < /proc/net/if_inet6)
grep -Fq "2606:4700:ffff:0:0:0:0:123|$dev|stable" <<< "$proc_rows"
! grep -Fq '2606:4700:ffff:0:0:0:0:124' <<< "$proc_rows"
ip() { return 1; }
fallback_rows=$(get_server_ipv6_addresses)
grep -Fq "2606:4700:ffff:0:0:0:0:123|$dev|stable|public" <<< "$fallback_rows"
ip() { return 0; }
fallback_rows=$(get_server_ipv6_addresses)
grep -Fq "2606:4700:ffff:0:0:0:0:123|$dev|stable|public" <<< "$fallback_rows"
unset -f ip
if command -v busybox >/dev/null 2>&1 && busybox ip -6 addr show > "$fixture/busybox-ip"; then
    _parse_server_ipv6_ip < "$fixture/busybox-ip" > "$fixture/busybox-rows"
    grep -Fq "2606:4700:ffff::123|$dev|stable" "$fixture/busybox-rows"
    ! grep -Fq '2606:4700:ffff::124' "$fixture/busybox-rows"
fi
ip link set "$dev" down
! get_server_ipv6_addresses | grep -Fq "|$dev|"
! _parse_server_ipv6_proc < /proc/net/if_inet6 | grep -Fq "|$dev|"
echo 'PASS real Linux interface discovery, BusyBox/iproute2 parsing, /proc fallback, deprecated and down state'

# Real curl over IPv6 HTTPS with a trusted fixture certificate; no public probes.
python3 "$repo/tests/server-ipv6-native.py" "$fixture/library.sh" "$fixture"
