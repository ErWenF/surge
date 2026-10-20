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
readlink() { if [[ "$2" == "$0" ]]; then echo "$fixture/current-script"; else command readlink "$@"; fi; }
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
# The two targets can have different contents and permissions before an update.
printf '#!/bin/bash\nreadonly VERSION="3.7.7"\n' > "$fixture/system-script"
chmod 750 "$fixture/current-script"
chmod 700 "$fixture/system-script"
cp "$fixture/system-script" "$fixture/original-system"
printf 'previous-good\n' > "$CFG/script-backups-placeholder"
mkdir -p "$CFG/script-backups"
cp "$CFG/script-backups-placeholder" "$CFG/script-backups/previous"
cp() {
    local dest="${@: -1}" count=0
    if [[ "$dest" == */.vless-update-new.* ]]; then
        [[ ! -f "$fixture/copies" ]] || count=$(cat "$fixture/copies")
        count=$((count + 1)); echo "$count" > "$fixture/copies"
        [[ "$failure:$count" != stage-copy:2 ]] || return 1
    fi
    command cp "$@"
}
chmod() {
    local dest="${@: -1}" count=0
    if [[ "$dest" == */.vless-update-new.* ]]; then
        [[ ! -f "$fixture/modes" ]] || count=$(cat "$fixture/modes")
        count=$((count + 1)); echo "$count" > "$fixture/modes"
        [[ "$failure:$count" != stage-mode:2 ]] || return 1
    fi
    command chmod "$@"
}
mv() {
    local src="${@: -2:1}" dest="${@: -1}"
    [[ "$failure:$dest" != pointer:"$CFG/script-backups/previous" ]] || return 1
    if [[ "$src" == */.vless-update-new.* ]]; then
        [[ "$failure:$dest" != first-publish:"$fixture/current-script" &&
           "$failure:$dest" != second-publish:"$fixture/system-script" ]] || return 1
    fi
    command mv "$@"
}
for failure in stage-copy stage-mode first-publish second-publish pointer; do
    rm -f "$fixture/copies" "$fixture/modes"
    if (perform_script_update <<< y) > "$fixture/output" 2>&1; then exit 1; fi
    cmp "$fixture/current-script" "$fixture/original-script"
    cmp "$fixture/system-script" "$fixture/original-system"
    [[ $(stat -c %a "$fixture/current-script") == 750 && $(stat -c %a "$fixture/system-script") == 700 ]]
    cmp "$CFG/script-backups/previous" "$CFG/script-backups-placeholder"
    ! grep -Eq '更新成功|已同步更新系统目录脚本' "$fixture/output"
    ! find "$fixture" -maxdepth 1 -name '.vless-update-*' -print -quit | grep -q .
done
failure=''
unset -f cp chmod mv
cp "$fixture/current-script" "$fixture/system-script"
echo 'PASS second-target stage/copy/mode/publish and pointer failures preserve both original scripts, modes and rollback pointer'

requests_before=$(wc -l < "$fixture/requests")
(perform_script_update <<< y) > "$fixture/output"
[[ $(wc -l < "$fixture/requests") == $((requests_before + 1)) ]]
[[ $(_extract_script_version "$fixture/current-script") == "$next_version" ]]
cmp "$fixture/current-script" "$fixture/system-script"
cmp "$(cat "$CFG/script-backups/previous")" "$fixture/original-script"
cmp "$DB_FILE" "$fixture/original-db"
echo 'PASS confirmed update installs the same verified candidate with a valid old-script backup and unchanged node database'

# Follow an existing system-script symlink without replacing the link itself.
mv "$fixture/system-script" "$fixture/system-target"
ln -s "$fixture/system-target" "$fixture/system-script"
(perform_script_update <<< y) > "$fixture/output"
[[ -L "$fixture/system-script" ]]
cmp "$fixture/current-script" "$fixture/system-target"
echo 'PASS system destination symlink remains intact after update'
