#!/usr/bin/env bash
set -e
if [[ ${TG_BOT_NATIVE_TEST:-0} != 1 ]]; then
    echo 'SKIP TG native long polling/service test (TG_BOT_NATIVE_TEST unset)'
    exit 0
fi
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
python3 "$repo/tests/tg-bot-native.py" "$fixture/library.sh" "$fixture"
