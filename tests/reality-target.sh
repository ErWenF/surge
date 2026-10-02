#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT

expect_failure() {
    local rc=0 output
    output=$("$@" 2>"$fixture/error") || rc=$?
    [[ "$rc" != 0 && -z "$output" && -s "$fixture/error" ]]
}
for host in 'bad..name' '-option.example' 'example.com/evil' '127.0.0.1' ''; do
    expect_failure probe_reality_target "$host"
done
expect_failure probe_reality_target example.com 0
expect_failure probe_reality_target example.com 65536
expect_failure probe_reality_target example.com 443 0
expect_failure probe_reality_target example.com 443 5 4
echo 'PASS invalid domains and probe budgets fail without a result'

# Missing TLS flags and curve selection must fail closed, without networking.
openssl() { printf '%s\n' "$mock_help"; }
mock_help='-alpn -verify_hostname -verify_return_error -groups'
expect_failure probe_reality_target example.com
mock_help='-tls1_3 -alpn -verify_hostname -verify_return_error'
expect_failure probe_reality_target example.com
unset -f openssl
echo 'PASS insufficient OpenSSL capabilities fail closed'

# Existing selection and certificate paths must not invoke the network probe.
gen_sni() { echo random.example; }
probe_reality_target() {
    printf '%s\n' "$1" >> "$fixture/probes"
    case "$1" in
        slow.example) printf 'slow.example\t90\n' ;;
        fast.example) printf 'fast.example\t20\n' ;;
        bad.example) return 1 ;;
        malformed.example) printf 'other.example\t1\n' ;;
        *) return 2 ;;
    esac
}
result=$(ask_sni_config default.example '' <<< '')
[[ "$result" == default.example && ! -e "$fixture/probes" ]]
result=$(ask_sni_config default.example '' <<< $'2\ncustom.example')
[[ "$result" == custom.example && ! -e "$fixture/probes" ]]
REALITY_SNI_CONFIRMED=cert.example
result=$(ask_sni_config default.example '' reality </dev/null)
[[ "$result" == cert.example && ! -e "$fixture/probes" ]]
unset REALITY_SNI_CONFIRMED
mkdir -p "$CFG/certs"
touch "$CFG/certs/server.crt"
openssl() { echo "issuer=Let's Encrypt"; }
result=$(ask_sni_config default.example cert.example reality </dev/null)
[[ "$result" == cert.example && ! -e "$fixture/probes" ]]
unset -f openssl
rm "$CFG/certs/server.crt"
echo 'PASS legacy/default/custom/real-certificate selections do not probe'

result=$(ask_sni_config default.example '' reality <<< $'3\nslow.example,fast.example bad.example FAST.EXAMPLE malformed.example')
[[ "$result" == fast.example ]]
[[ "$(cat "$fixture/probes")" == $'slow.example\nfast.example\nbad.example\nmalformed.example' ]]
echo 'PASS measured selection filters failures and malformed results, deduplicates, and ranks'

: > "$fixture/probes"
result=$(ask_sni_config default.example '' reality <<< $'3\nbad.example\n2\nmanual.example')
[[ "$result" == manual.example && "$(cat "$fixture/probes")" == bad.example ]]
result=$(ask_sni_config default.example '' <<< $'3\n1' 2>"$fixture/menu")
[[ "$result" == default.example ]]
! grep -q '检测并优选' "$fixture/menu"
if ask_sni_config default.example '' reality <<< $'3\nbad.example' >"$fixture/output" 2>/dev/null; then
    echo 'Unexpected success on exhausted input' >&2
    exit 1
fi
[[ ! -s "$fixture/output" ]]
: > "$fixture/probes"
expect_failure select_reality_sni default.example <<< 'a.example b.example c.example d.example e.example f.example'
[[ ! -s "$fixture/probes" ]]
echo 'PASS failed/oversized scans do not choose a target; other protocols do not offer scanning'

# Only the two external Reality installation paths opt in.
[[ "$(grep -c 'ask_sni_config.*cert_domain.* reality)' "$repo/vless-server.sh")" == 2 ]]
echo 'PASS opt-in hooks are limited to VLESS Reality and Reality XHTTP'

export TEST_CFG
python3 "$repo/tests/reality-target-native.py" "$fixture/library.sh" "$fixture"
