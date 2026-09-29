#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

load_function() {
    eval "$(awk -v fn="$1" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {exit}' "$repo/vless-server.sh")"
}
for fn in _version_gt _get_latest_script_version _get_previous_stable_script_release; do
    load_function "$fn"
done

grep -q '^readonly VERSION="3.7.3"$' "$repo/vless-server.sh"
grep -q '^readonly SCRIPT_REPO="ErWenF/surge"$' "$repo/vless-server.sh"
grep -q '^readonly SCRIPT_SOURCE_REPO="ErWenF/surge"$' "$repo/vless-server.sh"
SCRIPT_REPO=ErWenF/surge
SCRIPT_VERSION_CACHE_FILE="$fixture/cache"
_init_version_cache() { :; }
_is_cache_fresh() { return 1; }
_get_latest_script_version_from_raw() { echo 3.7.3; }
_get_latest_version() { echo 3.7.2; }
_get_latest_tag_version() { echo 3.7.1; }
[[ $(_get_latest_script_version false true) == 3.7.3 ]]

_get_latest_script_version_from_raw() { return 1; }
[[ $(_get_latest_script_version false true) == 3.7.2 ]]

curl() {
    case "$*" in
        *'/releases?'*) printf '%s\n' '[]' ;;
        *'/tags?'*) printf '%s\n' '[{"name":"v3.7.0-preview.1"},{"name":"v3.7.2"},{"name":"v3.7.1"}]' ;;
        *) return 1 ;;
    esac
}
[[ $(_get_previous_stable_script_release 3.7.3) == '3.7.2|v3.7.2' ]]
echo 'PASS fork update source, main version priority, and tag rollback fallback'
