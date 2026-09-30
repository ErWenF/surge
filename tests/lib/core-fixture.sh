#!/usr/bin/env bash
# Load the full script without dispatching its CLI or touching live state.
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=${fixture:-$(mktemp -d)}
TEST_CFG="$fixture/cfg"
mkdir -p "$TEST_CFG"
awk '
    /^# 命令行参数处理$/ {exit}
    /^readonly CFG=/ {print "readonly CFG=\"${TEST_CFG:?}\""; next}
    /^readonly XRAY_API_PORT=/ {print "readonly XRAY_API_PORT=\"${TEST_XRAY_API_PORT:-10085}\""; next}
    {print}
' "$repo/vless-server.sh" > "$fixture/library.sh"
source "$fixture/library.sh"
_err() { printf '%s\n' "$*" >&2; }
_ok() { :; }
_info() { :; }
_warn() { printf '%s\n' "$*" >&2; }
USER_CHANGE_HEALTH_DELAY=0
CORE_UPDATE_HEALTH_DELAY=0
