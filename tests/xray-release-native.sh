#!/usr/bin/env bash
set -e
if [[ -z "${XRAY_RELEASE_TEST_ARCHIVE:-}" ]]; then
    echo 'SKIP native Xray release verification (XRAY_RELEASE_TEST_ARCHIVE unset)'
    exit 0
fi
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
CORE_BIN_DIR="$fixture/bin"
XRAY_ASSET_DIR="$fixture/assets"
version=${XRAY_RELEASE_TEST_VERSION:-26.3.27}
url="https://github.com/XTLS/Xray-core/releases/download/v$version/Xray-linux-64.zip"
cp "$XRAY_RELEASE_TEST_ARCHIVE" "$fixture/release.zip"

# Only the API is unavailable; DGST is fetched by real curl from Xray's release.
curl() {
    local argument output='' previous=''
    for argument in "$@"; do
        [[ "$previous" != -o ]] || output="$argument"
        previous="$argument"
        if [[ "$argument" == https://api.github.com/* ]]; then
            touch "$fixture/api-called"
            return 22
        fi
    done
    if [[ "${@: -1}" == "$url" ]]; then
        cp "$fixture/release.zip" "$output"
    else
        command curl "$@"
    fi
}
check_cmd() { return 1; }
_flush_core_traffic() { :; }
svc() { return 1; } # No live service is touched in this isolated installation.

web_version=$(_get_xray_latest_version_from_web)
[[ "$web_version" =~ ^[0-9][0-9A-Za-z._-]*$ && ! -e "$fixture/api-called" ]]
echo "PASS official latest redirect resolves stable version $web_version with API blocked"

_install_binary xray XTLS/Xray-core "$url" xray stable true "$version"
[[ -x "$CORE_BIN_DIR/xray" && ! -e "$fixture/api-called" ]]
"$CORE_BIN_DIR/xray" version
before=$(_sha256_file "$CORE_BIN_DIR/xray")
printf 'tampered\n' >> "$fixture/release.zip"
if _install_binary xray XTLS/Xray-core "$url" xray stable true "$version"; then
    echo 'tampered archive unexpectedly installed' >&2
    exit 1
fi
[[ "$(_sha256_file "$CORE_BIN_DIR/xray")" == "$before" && ! -e "$fixture/api-called" ]]
echo 'PASS native official ZIP installation with API blocked, executable core, and tampered update rejected'
