#!/usr/bin/env bash
# Operate only processes and files owned by the native test fixture.
set -e
: "${fixture:?}" "${XRAY_BIN:?}" "${TEST_XRAY_API_PORT:?}"
source "$(dirname "$0")/lib/core-fixture.sh"
_listen_addr() { echo 127.0.0.1; }
xray() { "$XRAY_BIN" "$@"; }
_pgrep() {
    case "$1" in
        xray) svc status vless-reality ;;
        sing-box) svc status vless-singbox ;;
        *) return 1 ;;
    esac
}
SINGBOX_V2RAY_API_PORT=${TEST_SINGBOX_API_PORT:-10086}
_core_traffic_epoch() {
    local pid service=vless-reality
    [[ "$1" != singbox ]] || service=vless-singbox
    pid=$(cat "$fixture/$service.pid") || return 1
    printf '%s:%s\n' "$pid" "$(awk '{print $22}' "/proc/$pid/stat")"
}
svc() {
    local action="$1" service="$2" pid binary config
    case "$service" in
        vless-reality) binary="$XRAY_BIN"; config="$CFG/config.json" ;;
        vless-singbox) binary="${SINGBOX_BIN:?}"; config="$CFG/singbox.json" ;;
        *) return 1 ;;
    esac
    pid=$(cat "$fixture/$service.pid" 2>/dev/null) || pid=''
    case "$action" in
        status) [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null ;;
        is-enabled) [[ -f "$fixture/$service.enabled" ]] ;;
        enable) touch "$fixture/$service.enabled" ;;
        disable) rm -f "$fixture/$service.enabled" ;;
        stop)
            [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
            rm -f "$fixture/$service.pid"; sleep 0.15 ;;
        start|restart)
            [[ -z "$pid" ]] || svc stop "$service"
            ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$binary" run -c "$config" >/dev/null 2>&1 &
            echo "$!" > "$fixture/$service.pid"
            sleep 0.4
            svc status "$service" ;;
    esac
}
generate_xray_config() {
    if [[ -z "${XRAY_CONFIG_OUTPUT:-}" ]]; then _rebuild_core_config xray false; return $?; fi
    _render_xray_config || return 1
    jq --argjson api "$XRAY_API_PORT" '.log={loglevel:"none"} |
        (.inbounds[] | select(.tag=="api")).port=$api' "$XRAY_CONFIG_OUTPUT" > "$fixture/patched"
    mv "$fixture/patched" "$XRAY_CONFIG_OUTPUT"
}
check_daily_report() { :; }
get_traffic_monthly_reset_enabled() { echo false; }
tg_get_config() { [[ "$1" != notify_quota_percent ]] || echo 80; return 0; }
case "${1:-}" in
    start) _start_core_service vless-reality xray ss2022 generate_xray_config ;;
    disable) db_set_user_enabled xray ss2022 "$2" false ;;
    enable) db_set_user_enabled xray ss2022 "$2" true ;;
    sync) sync_all_user_traffic true ;;
    cycles) check_user_traffic_cycles ;;
    cycle-disable) db_set_user_enabled "$2" "$3" "$4" false quota ;;
    flush) _with_db_lock _flush_core_traffic xray ;;
    route) apply_port_routing_change xray ss2022 "$2" "$3" ;;
    singbox-check) generate_singbox_config ;;
    singbox-start) _start_core_service vless-singbox sing-box "$(get_singbox_protocols)" generate_singbox_config ;;
    singbox-disable) db_set_user_enabled singbox trojan "$2" false ;;
    singbox-enable) db_set_user_enabled singbox trojan "$2" true ;;
    singbox-route) apply_port_routing_change singbox trojan "$2" "$3" ;;
    singbox-stats) singbox_api_query 'user>>>' false ;;
    *) exit 2 ;;
esac
