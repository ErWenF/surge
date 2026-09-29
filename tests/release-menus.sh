#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
eval "$(awk 'index($0,"_select_protocol_for_users() {")==1 {on=1} on {print} on && $0=="}" {exit}' "$repo/vless-server.sh")"
DB_FILE="$fixture/db.json"
db_count_users() { echo 1; }
get_protocol_name() { echo "$1"; }
_line() { :; }
_item() { echo "$*"; }
_err() { echo "$*"; }
jq -n '{xray:{snell:{},"snell-v5":{},"snell-v6":{}},singbox:{vless:{},anytls:{}}}' > "$DB_FILE"
_select_protocol_for_users snell > "$fixture/menu" <<< 3
[[ "$SELECTED_PROTO" == snell-v6 && "$SELECTED_CORE" == xray ]]
if grep -Eq 'vless|anytls' "$fixture/menu"; then exit 1; fi
_select_protocol_for_users > "$fixture/menu" <<< 5
[[ "$SELECTED_PROTO" == vless && "$SELECTED_CORE" == singbox ]]
jq -n '{xray:{},singbox:{vless:{}}}' > "$DB_FILE"
if _select_protocol_for_users snell > "$fixture/menu" <<< 1; then exit 1; fi
grep -q '没有已安装的 Snell' "$fixture/menu"
if grep -Eq '_item "f"|选择 f|协议运行内核切换.*预览' "$repo/vless-server.sh"; then exit 1; fi
grep -q '_select_protocol_for_users snell' "$repo/vless-server.sh"
echo 'PASS Snell-only selector, normal selector unchanged, empty Snell list, removed menu labels and stale f hints'
