#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
CONF_FILE="$fixture/forward.conf"
TABLE_NAME=test_forward
for fn in write_conf_file _nft_config_batch reload_rules do_clear_all; do
    eval "$(awk -v fn="$fn" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {getline; print; if ($0 != "EOF") exit}' "$repo/nft.sh")"
done
err() { echo "$*" >&2; }
info() { :; }
warn() { :; }
log_action() { :; }
get_local_ip() { echo 192.0.2.1; }
backup_conf() { :; }
nft() {
    case "$*" in
        'list table ip test_forward') [[ -f "$fixture/runtime" ]] ;;
        '-c -f '*) ! grep -q 'INVALID' "${@: -1}" ;;
        '-f '*)
            [[ ! -f "$fixture/fail-apply" ]] || return 1
            cp "${@: -1}" "$fixture/runtime" ;;
        *) echo "Unexpected nft operation: $*" >&2; return 1 ;;
    esac
}
RULES=('32001|192.0.2.2|443')
write_conf_file
reload_rules
cp "$CONF_FILE" "$fixture/before-conf"
cp "$fixture/runtime" "$fixture/before-runtime"
RULES=('32002|192.0.2.3|443')
write_conf_file
touch "$fixture/fail-apply"
if reload_rules; then exit 1; fi
cmp "$CONF_FILE" "$fixture/before-conf"
cmp "$fixture/runtime" "$fixture/before-runtime"
RULES=('INVALID|192.0.2.3|443')
if write_conf_file; then exit 1; fi
cmp "$CONF_FILE" "$fixture/before-conf"
load_rules() { RULES=('32001|192.0.2.2|443'); }
firewall_close_port() { echo "$*" >> "$fixture/closed"; }
do_clear_all <<< y
[[ ! -f "$fixture/closed" ]]
cmp "$CONF_FILE" "$fixture/before-conf"
cmp "$fixture/runtime" "$fixture/before-runtime"
rm "$fixture/fail-apply"
do_clear_all <<< y
[[ $(wc -l < "$fixture/closed") == 1 ]]
[[ -z "${NFT_CONF_BACKUP:-}" ]]
echo 'PASS nft validation/application failure preserves runtime and persistent config; clear closes firewall only after commit'
