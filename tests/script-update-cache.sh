#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_init_version_cache
_header() { :; }
_line() { :; }
_info() { printf '%s\n' "$*"; }
_ok() { printf '%s\n' "$*"; }
# Both script destinations are private files; never replace the test or live script.
eval "$(declare -f perform_script_update | sed "s|/usr/local/bin/vless-server.sh|$fixture/system-script|g")"
readlink() { echo "$fixture/current-script"; }
printf '#!/bin/bash\nreadonly VERSION="3.7.6"\n' > "$fixture/current-script"
cp "$fixture/current-script" "$fixture/system-script"
cp "$fixture/current-script" "$fixture/original-script"
cp "$DB_FILE" "$fixture/original-db"
next_version="${VERSION%.*}.$((10#${VERSION##*.} + 1))"
later_version="${VERSION%.*}.$((10#${VERSION##*.} + 2))"
remote="$next_version"
failure=''
_fetch_script_tmp() {
    printf '%s\n' "$*" >> "$fixture/requests"
    [[ "$failure" != network && "$failure" != blob ]] || return 1
    local candidate
    candidate=$(mktemp "$fixture/download.XXXXXX")
    printf '#!/bin/bash\nreadonly VERSION="%s"\n' "$remote" > "$candidate"
    echo "$candidate"
}
_get_latest_script_version() { echo 'STALE_HELPER_MUST_NOT_BE_USED'; }
printf '%s\n' 3.7.6 > "$SCRIPT_VERSION_CACHE_FILE"
perform_script_update <<< n > "$fixture/output"
grep -q "最新版本:.*$next_version" "$fixture/output"
[[ $(cat "$SCRIPT_VERSION_CACHE_FILE") == "$next_version" ]]
[[ $(cat "$fixture/requests") == '10 60' ]]
cmp "$fixture/current-script" "$fixture/original-script"
! find "$fixture" -name 'download.*' -print -quit | grep -q .
remote="$later_version"
perform_script_update <<< n > "$fixture/output"
grep -q "最新版本:.*$later_version" "$fixture/output"
[[ $(cat "$SCRIPT_VERSION_CACHE_FILE") == "$later_version" ]]
remote="$VERSION"
perform_script_update > "$fixture/output"
grep -q '已是最新版本' "$fixture/output"
! find "$fixture" -name 'download.*' -print -quit | grep -q .
for failure in network blob; do
    if perform_script_update > "$fixture/output" 2>&1; then exit 1; fi
    ! grep -q '已是最新版本' "$fixture/output"
    cmp "$fixture/current-script" "$fixture/original-script"
done
failure=''
remote='not-a-version'
if perform_script_update > "$fixture/output" 2>&1; then exit 1; fi
cmp "$fixture/current-script" "$fixture/original-script"
! find "$fixture" -name 'download.*' -print -quit | grep -q .
echo 'PASS explicit update bypasses fresh/stale cache, refreshes each time and retains scripts on cancellation/network/blob/version errors'

remote="$next_version"
requests_before=$(wc -l < "$fixture/requests")
(perform_script_update <<< y) > "$fixture/output"
[[ $(wc -l < "$fixture/requests") == $((requests_before + 1)) ]]
[[ $(_extract_script_version "$fixture/current-script") == "$next_version" ]]
cmp "$fixture/current-script" "$fixture/system-script"
cmp "$(cat "$CFG/script-backups/previous")" "$fixture/original-script"
cmp "$DB_FILE" "$fixture/original-db"
echo 'PASS confirmed update installs the same verified candidate with a valid old-script backup and unchanged node database'
