#!/usr/bin/env bash
# Opt in only on a host supporting a separate network namespace.
set -e
if [[ "${NFT_NATIVE_TEST:-0}" != 1 ]]; then echo 'SKIP nft kernel transaction (NFT_NATIVE_TEST unset)'; exit 0; fi
if [[ "${1:-}" != namespace ]]; then exec unshare --net bash "$0" namespace; fi
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
CONF_FILE="$fixture/forward.conf"
TABLE_NAME=test_forward
for fn in write_conf_file _nft_config_batch reload_rules; do
    eval "$(awk -v fn="$fn" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {getline; print; if ($0 != "EOF") exit}' "$repo/nft.sh")"
done
err() { echo "$*" >&2; }
get_local_ip() { echo 192.0.2.1; }
command nft add table inet unrelated
command nft 'add chain inet unrelated sentinel { type filter hook input priority 0; policy accept; }'
command nft add rule inet unrelated sentinel tcp dport 31999 counter accept
command nft -s list table inet unrelated > "$fixture/sentinel"
RULES=('32001|192.0.2.2|443')
write_conf_file
reload_rules
cp "$CONF_FILE" "$fixture/before-conf"
command nft -s list table ip "$TABLE_NAME" > "$fixture/before-runtime"
RULES=('INVALID|192.0.2.3|443')
if write_conf_file; then exit 1; fi
cmp "$CONF_FILE" "$fixture/before-conf"
RULES=('32002|192.0.2.3|8443')
write_conf_file
# Reject the actual kernel batch after userspace validation. nft must roll back
# the delete/create commands which precede the invalid operation.
nft() {
    if [[ "$1" == -f ]]; then
        printf '\nadd rule ip %s missing_chain accept\n' "$TABLE_NAME" >> "$2"
    fi
    command nft "$@"
}
if reload_rules; then exit 1; fi
cmp "$CONF_FILE" "$fixture/before-conf"
command nft -s list table ip "$TABLE_NAME" > "$fixture/after-runtime"
cmp "$fixture/before-runtime" "$fixture/after-runtime"
unset -f nft
RULES=('32002|192.0.2.3|8443')
write_conf_file
reload_rules
command nft -s list table ip "$TABLE_NAME" > "$fixture/after-runtime"
grep -q 'tcp dport 32002 dnat to 192.0.2.3:8443' "$fixture/after-runtime"
if grep -q 'tcp dport 32001' "$fixture/after-runtime"; then exit 1; fi
command nft -s list table inet unrelated > "$fixture/sentinel-after"
cmp "$fixture/sentinel" "$fixture/sentinel-after"
echo 'PASS native nft atomic replacement, kernel-rejected batch rollback and unrelated-table preservation in isolated namespace'
