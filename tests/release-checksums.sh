#!/usr/bin/env bash
# Exercise the generic release verifier, including Alpine's checksum fallback.
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
if [[ "${RELEASE_CHECKSUM_TEST_BACKEND:-native}" == busybox ]]; then
    awk() { busybox awk "$@"; }
fi

asset=sing-box-1.14.0-linux-amd64.tar.gz
printf 'release archive\n' > "$fixture/archive"
hash=$(_sha256_file "$fixture/archive")
other_hash=$(printf 'different archive\n' | sha256sum | cut -d' ' -f1)
download="$fixture/archive"
curl() {
    if [[ "$*" == *api.github.com* ]]; then
        printf '%s\n' '{"assets":[{"name":"checksums.txt","browser_download_url":"https://example.test/checksums.txt"}]}'
    else
        local output
        while (( $# )); do
            if [[ "$1" == -o ]]; then output="$2"; break; fi
            shift
        done
        if [[ "$*" == *checksums.txt* ]]; then cp "$fixture/checksums" "$output"
        else cp "$download" "$output"; fi
    fi
}
verify() {
    _verify_github_release_asset SagerNet/sing-box 1.14.0 "https://example.test/$asset" "$fixture/archive"
}
reject() { if verify; then echo 'unexpected checksum acceptance' >&2; exit 1; fi; }

for prefix in '' '*' './' '*./'; do
    printf '%s  %s%s\r\n' "${hash^^}" "$prefix" "$asset" > "$fixture/checksums"
    verify
done
printf 'SHA256 (%s) = %s\n' "$asset" "$hash" > "$fixture/checksums"
verify
printf 'SHA2-256 (%s) = %s\n' "$asset" "$hash" > "$fixture/checksums"
verify
echo 'PASS exact checksum names, text/binary markers, relative paths, BSD labels, uppercase and CRLF'

# A hash belonging to a similarly named asset must never verify this archive.
printf '%s  %s.sig\n' "$hash" "$asset" > "$fixture/checksums"
reject
printf '%s  prefix-%s\n' "$hash" "$asset" > "$fixture/checksums"
reject
printf '%s  %s.sig\n%s  %s\n' "$other_hash" "$asset" "$hash" "$asset" > "$fixture/checksums"
verify
echo 'PASS neighboring filenames do not match or shadow the requested asset'

printf '%s  %s\n%s  %s\n' "$hash" "$asset" "$other_hash" "$asset" > "$fixture/checksums"
reject
printf '%s  %s\n%s  %s\n' "$hash" "$asset" "$hash" "$asset" > "$fixture/checksums"
reject
for value in abc "${hash:1}Z"; do
    printf '%s  %s\n' "$value" "$asset" > "$fixture/checksums"
    reject
done
printf '%s  %s\n' "$other_hash" "$asset" > "$fixture/checksums"
reject
[[ "$_GITHUB_ASSET_VERIFY_ERROR" == *不匹配* ]]
printf 'SHA512 (%s) = %s\n' "$asset" "$hash" > "$fixture/checksums"
reject
echo 'PASS duplicates, malformed hashes, unsupported digest labels and tampered archives fail closed'

# The install entry must reject an unverified archive before replacement.
printf '%s  %s\n' "$hash" "$asset" > "$fixture/checksums"
printf 'tampered archive\n' > "$fixture/tampered"
download="$fixture/tampered"
check_cmd() { return 1; }
_replace_core_binary() { touch "$fixture/replaced"; }
if _install_binary sing-box SagerNet/sing-box "https://example.test/$asset" singbox stable true 1.14.0; then exit 1; fi
[[ ! -e "$fixture/replaced" && "$_GITHUB_ASSET_VERIFY_ERROR" == *不匹配* ]]
echo 'PASS generic core installation rejects bad checksums before replacing any binary'
