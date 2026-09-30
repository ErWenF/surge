#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
for test in "$repo"/tests/*.sh; do
    case "${test##*/}" in
        run.sh|core-native-worker.sh|optional-native-worker.sh) continue ;;
        ss2022-config.sh) [[ -n "${XRAY_BIN:-}" ]] || { echo 'SKIP SS2022 native config (XRAY_BIN unset)'; continue; } ;;
        singbox-stats-live.sh) [[ -n "${SINGBOX_TEST_BIN:-}" && -n "${GRPCURL_TEST_BIN:-}" ]] || { echo 'SKIP Sing-box live stats (test binaries unset)'; continue; } ;;
    esac
    bash "$test"
    printf 'OK %s\n' "${test##*/}"
done
if command -v node >/dev/null 2>&1; then
    node "$repo/tests/po0-modules.js"
else
    echo 'SKIP Po0 JavaScript regressions (node unavailable)'
fi
if [[ -n "${XRAY_BIN:-}" && -n "${SINGBOX_BIN:-}" ]]; then
    python3 "$repo/tests/core-native.py" "$XRAY_BIN" "$SINGBOX_BIN"
    python3 "$repo/tests/ss2022-native.py" "$XRAY_BIN"
fi
if [[ -n "${REALM_TEST_BIN:-}" && -n "${SNELL_TEST_BIN:-}" && -n "${NGINX_TEST_BIN:-}" ]]; then
    python3 "$repo/tests/optional-native.py" "$REALM_TEST_BIN" "$SNELL_TEST_BIN" "$NGINX_TEST_BIN"
fi
