#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
for test in "$repo"/tests/*.sh; do
    case "${test##*/}" in
        run.sh|core-native-worker.sh) continue ;;
        ss2022-config.sh) [[ -n "${XRAY_BIN:-}" ]] || { echo 'SKIP SS2022 native config (XRAY_BIN unset)'; continue; } ;;
        singbox-stats-live.sh) [[ -n "${SINGBOX_TEST_BIN:-}" && -n "${GRPCURL_TEST_BIN:-}" ]] || { echo 'SKIP Sing-box live stats (test binaries unset)'; continue; } ;;
    esac
    bash "$test"
    printf 'OK %s\n' "${test##*/}"
done
if [[ -n "${XRAY_BIN:-}" && -n "${SINGBOX_BIN:-}" ]]; then
    python3 "$repo/tests/core-native.py" "$XRAY_BIN" "$SINGBOX_BIN"
    python3 "$repo/tests/ss2022-native.py" "$XRAY_BIN"
fi
