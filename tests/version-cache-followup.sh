#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
curl() {
    echo lookup >> "$fixture/requests"
    sleep .15
    [[ ! -f "$fixture/fail-fetch" ]] || return 1
    printf '%s\n' '[{"tag_name":"v2.0.0-beta","prerelease":true},{"tag_name":"v1.9.0","prerelease":false}]' 200
}
_update_version_cache_async example/project
_update_prerelease_cache_async example/project
_update_all_versions_async example/project
wait
[[ $(wc -l < "$fixture/requests") == 1 ]]
[[ $(cat "$VERSION_CACHE_DIR/example_project") == 1.9.0 ]]
[[ $(cat "$VERSION_CACHE_DIR/example_project_prerelease") == 2.0.0-beta ]]
rm "$VERSION_CACHE_DIR/example_project_checked" "$VERSION_CACHE_DIR/example_project_prerelease"
touch "$fixture/fail-fetch"
if _refresh_version_caches example/project; then exit 1; fi
[[ $(cat "$VERSION_CACHE_DIR/example_project") == 1.9.0 ]]
! find "$VERSION_CACHE_DIR" -name '*.new.*' -print -quit | grep -q .
echo 'PASS asynchronous version request deduplication, atomic publication and failed-fetch retention'
