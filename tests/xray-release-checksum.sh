#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
if [[ "${XRAY_CHECKSUM_TEST_BACKEND:-native}" == busybox ]]; then
    awk() { busybox awk "$@"; }
fi

printf 'known release archive\n' > "$fixture/archive"
release_hash=$(_sha256_file "$fixture/archive")
asset=Xray-linux-64.zip
url="https://github.com/XTLS/Xray-core/releases/download/v26.3.27/$asset"
api_mode=blocked
dgst_mode=available
release_redirect='https://github.com/XTLS/Xray-core/releases/tag/v26.3.27'
printf 'SHA2-256= %s\n' "$release_hash" > "$fixture/official.dgst"

# Model GitHub's public Release endpoints separately from its rate-limited API.
curl() {
    local output='' target=''
    while (( $# )); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            --connect-timeout|--max-time|--max-filesize) shift 2 ;;
            -*) shift ;;
            *) target="$1"; shift ;;
        esac
    done
    printf '%s\n' "$target" >> "$fixture/requests"
    case "$target" in
        "$url.dgst")
            [[ "$dgst_mode" == available ]] || return 22
            cp "$fixture/official.dgst" "$output"
            ;;
        "$url") cp "$fixture/archive" "$output" ;;
        https://github.com/XTLS/Xray-core/releases/latest) printf '%s' "$release_redirect" ;;
        https://api.github.com/*)
            [[ "$api_mode" != blocked ]] || return 22
            if [[ "$api_mode" == checksum ]]; then
                printf '{"assets":[{"name":"checksums.txt","browser_download_url":"https://github.com/test/checksums.txt"}]}'
            else
                printf '{"assets":[{"name":"%s","digest":"sha256:%s"}]}' "$asset" "$release_hash"
            fi
            ;;
        https://github.com/test/checksums.txt)
            printf '%s  %s\n' "$release_hash" "$asset" > "$output"
            ;;
        *) return 22 ;;
    esac
}
reject() {
    if "$@"; then echo 'unexpected verification success' >&2; exit 1; fi
}

_verify_github_release_asset XTLS/Xray-core 26.3.27 "$url" "$fixture/archive"
[[ "$(wc -l < "$fixture/requests")" == 1 ]]
[[ -z "$_GITHUB_ASSET_VERIFY_ERROR" ]]
echo 'PASS official DGST verification without GitHub API access'

printf 'MD5= deadbeef\nSHA1= deadbeef\r\n SHA256 = %s\r\nSHA2-512= deadbeef\n' "${release_hash^^}" > "$fixture/official.dgst"
[[ "$(_xray_release_asset_sha256 26.3.27 "$asset")" == "$release_hash" ]]
echo 'PASS OpenSSL SHA256/SHA2-256 labels, case, CRLF and BusyBox-compatible parsing'

for bad in missing short invalid duplicate ambiguous; do
    case "$bad" in
        missing) printf 'MD5= %s\nSHA2-512= %s\n' "$release_hash" "$release_hash" ;;
        short) printf 'SHA2-256= abc\n' ;;
        invalid) printf 'SHA2-256= %sZ\n' "${release_hash:1}" ;;
        duplicate) printf 'SHA2-256= %s\nSHA256= %s\n' "$release_hash" "$release_hash" ;;
        ambiguous) printf 'SHA2-256= %s= extra\n' "$release_hash" ;;
    esac > "$fixture/official.dgst"
    reject _verify_github_release_asset XTLS/Xray-core 26.3.27 "$url" "$fixture/archive"
done
echo 'PASS missing, invalid and ambiguous SHA-256 rejected while API is unavailable'

printf 'SHA2-256= %s\n' "$release_hash" > "$fixture/official.dgst"
printf 'tampered\n' > "$fixture/tampered"
api_mode=digest
: > "$fixture/requests"
reject _verify_github_release_asset XTLS/Xray-core 26.3.27 "$url" "$fixture/tampered"
[[ "$_GITHUB_ASSET_VERIFY_ERROR" == *不匹配* ]]
[[ "$(wc -l < "$fixture/requests")" == 1 ]]
echo 'PASS hash mismatch rejected without falling through to a different checksum'

dgst_mode=missing
_verify_github_release_asset XTLS/Xray-core 26.3.27 "$url" "$fixture/archive"
echo 'PASS missing DGST can still use GitHub asset digest'
_verify_github_release_asset test/project 26.3.27 "$url" "$fixture/archive"
api_mode=checksum
_verify_github_release_asset test/project 26.3.27 "$url" "$fixture/archive"
echo 'PASS other projects retain digest and checksum-file verification'

api_mode=blocked
reject _verify_github_release_asset XTLS/Xray-core 26.3.27 "$url" "$fixture/archive"
[[ "$_GITHUB_ASSET_VERIFY_ERROR" == *GitHub\ API* ]]
echo 'PASS no official checksum fails closed with a distinct fetch error'

# A failed verification must not replace an existing core, even when updating it.
dgst_mode=available
printf 'SHA2-256= %064d\n' 0 > "$fixture/official.dgst"
check_cmd() { return 1; }
_replace_core_binary() { touch "$fixture/replaced"; }
printf 'existing core\n' > "$fixture/existing"
existing_hash=$(_sha256_file "$fixture/existing")
reject _install_binary xray XTLS/Xray-core "$url" xray stable true 26.3.27
[[ ! -e "$fixture/replaced" && "$(_sha256_file "$fixture/existing")" == "$existing_hash" ]]
echo 'PASS failed installation leaves the existing core intact'

requests=$(wc -l < "$fixture/requests")
reject _xray_release_asset_sha256 '../invalid' "$asset"
reject _xray_release_asset_sha256 26.3.27 '../Xray-linux-64.zip'
[[ "$(wc -l < "$fixture/requests")" == "$requests" ]]
echo 'PASS unsafe release paths rejected before network access'

[[ "$(_get_xray_latest_version_from_web)" == 26.3.27 ]]
for release_redirect in 'https://github.com/another/project/releases/tag/v26.3.27' 'https://github.com/XTLS/Xray-core/releases/tag/invalid' 'https://github.com/XTLS/Xray-core/releases/tag/v26.3.27/extra'; do
    reject _get_xray_latest_version_from_web
done
echo 'PASS stable version redirect parsing and wrong repository/tag/path rejected'

release_redirect='https://github.com/XTLS/Xray-core/releases/tag/v26.3.27'
_get_latest_version() { return 1; }
_force_get_cached_version() { return 1; }
_save_version_cache() { printf '%s\n' "$2" > "$fixture/saved-version"; }
reject _install_binary xray XTLS/Xray-core "$url" xray stable true
[[ "$(cat "$fixture/saved-version")" == 26.3.27 && "$_GITHUB_ASSET_VERIFY_ERROR" == *不匹配* ]]
echo 'PASS fresh stable install resolves version without API/cache and still verifies the archive'
