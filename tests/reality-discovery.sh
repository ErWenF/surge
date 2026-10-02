#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT

for ip in '' 10.0.0.1 127.0.0.1 0.0.0.0 169.254.1.2 172.16.1.2 192.168.1.1 100.64.1.2 198.18.1.1 192.0.2.1 198.51.100.1 203.0.113.1 192.88.99.1 224.0.0.1 255.255.255.255 008.20.158.164 '8.8.8.8;true' ::1; do
    ! _reality_public_ipv4_valid "$ip"
done
for ip in 8.20.158.164 1.1.1.1 100.128.0.1 172.32.0.1; do
    _reality_public_ipv4_valid "$ip"
done
ips=$(_reality_neighbor_ips 8.20.158.164 1024)
[[ "$(wc -l <<< "$ips")" == 1024 ]]
[[ "$(head -n 4 <<< "$ips")" == $'8.20.158.163\n8.20.158.165\n8.20.158.162\n8.20.158.166' ]]
! grep -q '^8\.20\.158\.164$' <<< "$ips"
[[ "$(sort -u <<< "$ips" | wc -l)" == 1024 ]]
grep -q '^8\.20\.159\.0$' <<< "$ips"
grep -q '^8\.20\.157\.255$' <<< "$ips"
[[ "$(_reality_neighbor_ips 8.20.255.255 2)" == $'8.20.255.254\n8.21.0.0' ]]
[[ "$(_reality_neighbor_ips 8.20.0.0 2)" == $'8.19.255.255\n8.20.0.1' ]]
[[ "$(_reality_neighbor_ips 8.20.158.164 8 9 | head -n 1)" == 8.20.158.159 ]]
! _reality_neighbor_ips 8.20.158.164 10000
! _reality_neighbor_ips 8.20.158.164 8 8589934591
edge=$(_reality_neighbor_ips 1.0.0.1 8 33554430)
! grep -qE '^(0\.|255\.)' <<< "$edge"
echo 'PASS public-only symmetric expansion crosses /24 and /16, excludes self, has no IPv4 wraparound'

# Public-IP lookup bypasses proxy/curlrc and fails closed on reserved or absent IPs.
saved_timeout=$(declare -f _reality_run_timeout)
_reality_run_timeout() { shift; "$@"; }
curl() {
    printf '%s\n' "$*" >> "$fixture/curl-args"
    if [[ "$*" == *ip.sb* ]]; then echo 10.0.0.1; else echo 8.20.158.164; fi
}
[[ "$(_reality_public_ipv4)" == 8.20.158.164 ]]
[[ "$(wc -l < "$fixture/curl-args")" == 2 ]]
grep -q -- '-q -4 --noproxy \* --proto =https' "$fixture/curl-args"
curl() { echo 127.0.0.1; }
if _reality_public_ipv4 >"$fixture/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$fixture/result" ]]
unset -f curl
eval "$saved_timeout"
echo 'PASS public-IP detection uses direct IPv4 HTTPS and rejects private/proxy-style results'

# Controlled workers measure actual concurrency, preserve address order and enforce budget.
eval "$(declare -f _reality_neighbor_ips | sed '1s/_reality_neighbor_ips/_real_neighbor_ips/')"
_reality_neighbor_ips() {
    (( ${3:-1} <= 64 )) || return 3
    _real_neighbor_ips "$@"
}
_reality_scan_ip() {
    local marker="$fixture/worker-$BASHPID" active
    touch "$marker"
    active=$(find "$fixture" -name 'worker-*' | wc -l)
    echo "$active" >> "$fixture/concurrency"
    sleep .05
    printf '%s\t%s.example\n' "$1" "host-${1##*.}"
    rm "$marker"
}
_reality_tls_group_flag() { echo -groups; }
rows=$(_reality_discover_candidates 8.20.158.164)
[[ "$(wc -l <<< "$rows")" == 64 ]]
[[ "$(head -n 1 <<< "$rows")" == $'8.20.158.163\thost-163.example' ]]
[[ "$(sort -nr "$fixture/concurrency" | head -n 1)" -le 8 ]]
[[ "$(find "$fixture" -name 'worker-*' | wc -l)" == 0 ]]
_reality_scan_ip() { echo "$1" >> "$fixture/budget-ips"; sleep 2; return 1; }
start=$SECONDS
_reality_discover_candidates 8.20.158.164 443 1 >"$fixture/result"
(( SECONDS - start < 5 ))
[[ "$(wc -l < "$fixture/budget-ips")" == 8 && ! -s "$fixture/result" ]]
echo 'PASS eight-worker bound, deterministic candidates, finite scan budget and worker reaping'

_reality_scan_ip() { echo "$BASHPID" >> "$fixture/cancel-pids"; sleep 1; }
_reality_discover_candidates 8.20.158.164 >"$fixture/cancel-result" 2>/dev/null &
supervisor=$!
for ((i=0; i<50; i++)); do
    [[ -f "$fixture/cancel-pids" && "$(wc -l < "$fixture/cancel-pids")" == 8 ]] && break
    sleep .05
done
kill -TERM "$supervisor"
rc=0
wait "$supervisor" || rc=$?
[[ "$rc" == 143 && ! -s "$fixture/cancel-result" ]]
while read -r pid; do ! kill -0 "$pid" 2>/dev/null; done <"$fixture/cancel-pids"
echo 'PASS cancelled discovery waits for bounded workers and returns no recommendation'

probe_reality_target() {
    printf '%s\n' "$*" >> "$fixture/verified"
    case "$1" in
        slow.example) printf 'slow.example\t50\n' ;;
        fast.example) printf 'fast.example\t10\n' ;;
        malformed.example) printf 'other.example\t1\n' ;;
        false-success.example) printf 'false-success.example\t1\n'; return 1 ;;
        *) return 1 ;;
    esac
}
[[ "$(_reality_verify_discovered $'8.20.158.163\tslow.example\n8.20.158.165\tfast.example\n8.20.158.167\tfast.example\n8.20.158.162\tmalformed.example\n8.20.158.166\tfail.example\n8.20.158.168\tfalse-success.example')" == fast.example ]]
grep -q '^fast.example 443 5 3 8.20.158.165,8.20.158.167$' "$fixture/verified"
[[ "$(grep -c '^fast.example ' "$fixture/verified")" == 1 ]]
if _reality_verify_discovered $'8.20.158.166\tfail.example' >"$fixture/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$fixture/result" ]]
if _reality_verify_discovered $'8.20.158.165\tfast.example' 1 >"$fixture/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$fixture/result" ]]
: > "$fixture/verified"
rows=""
for ((i=1; i<=20; i++)); do rows+="8.20.158.163"$'\t'"fail-$i.example"$'\n'; done
if _reality_verify_discovered "$rows" >/dev/null 2>&1; then exit 1; fi
[[ "$(wc -l < "$fixture/verified")" == 20 ]]
echo 'PASS IP-set verification, domain deduplication, failure exit status, malformed-output filtering and time budget'

_reality_public_ipv4() { echo 8.20.158.164; }
_reality_discover_candidates() { echo "$1" >> "$fixture/discovery"; printf '8.20.158.165\tfast.example\n'; }
[[ "$(ask_sni_config default.example '' reality <<< $'3\n')" == fast.example ]]
[[ "$(cat "$fixture/discovery")" == 8.20.158.164 ]]
_reality_discover_candidates() { return 1; }
[[ "$(ask_sni_config default.example '' reality <<< $'3\n1\n2\nmanual.example')" == manual.example ]]
_reality_public_ipv4() { return 1; }
[[ "$(ask_sni_config default.example '' reality <<< $'3\n1\n2\nmanual.example')" == manual.example ]]
echo 'PASS automatic discovery is the default under opt-in option 3; failures return to original menu'
