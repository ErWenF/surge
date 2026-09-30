#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_flush_core_traffic() { :; }
svc() {
    local action="$1" service="$2"
    echo "$action $service" >> "$fixture/events"
    case "$action" in
        status) [[ -f "$fixture/$service.running" ]] ;;
        is-enabled) [[ -f "$fixture/$service.enabled" ]] ;;
        start|restart)
            if [[ -f "$fixture/fail-start" ]]; then rm "$fixture/fail-start"; return 1; fi
            touch "$fixture/$service.running" ;;
        stop) rm -f "$fixture/$service.running" ;;
        enable) touch "$fixture/$service.enabled" ;;
        disable) rm -f "$fixture/$service.enabled" ;;
    esac
}
printf '#!/usr/bin/env bash\n[[ ! -f "$FAIL_CHECK_FILE" ]] && jq empty "${@: -1}"\n' > "$fixture/check"
chmod 755 "$fixture/check"
export FAIL_CHECK_FILE="$fixture/fail-check"
XRAY_BIN="$fixture/check" SINGBOX_BIN="$fixture/check"
_listen_addr() { echo 127.0.0.1; }
db_ip_routing_enabled() { return 1; }
_db_apply '.xray.ss2022=[{port:24191,method:"2022-blake3-aes-128-gcm",password:"MDEyMzQ1Njc4OWFiY2RlZg==",multi_user:true,
    users:[{name:"default-24191",uuid:"YWJjZGVmZ2hpamtsbW5vcA==",enabled:true,quota:0,used:0}]},
    {port:24192,method:"2022-blake3-aes-128-gcm",password:"MTIzNDU2Nzg5MGFiY2RlZg=="}]'
generate_xray_config
cp "$CFG/config.json" "$fixture/good"
touch "$fixture/vless-reality.running"
cp "$DB_FILE" "$fixture/db-good"
_db_apply '.xray.ss2022[1].port=null'
if generate_xray_config; then exit 1; fi
cmp "$CFG/config.json" "$fixture/good"
_restore_db_backup "$fixture/db-good"
touch "$fixture/fail-check"
if db_set_user_enabled xray ss2022 default-24191 false; then exit 1; fi
cmp "$DB_FILE" "$fixture/db-good"
cmp "$CFG/config.json" "$fixture/good"
rm "$fixture/fail-check"
touch "$fixture/fail-start"
if db_set_user_enabled xray ss2022 default-24191 false; then exit 1; fi
cmp "$DB_FILE" "$fixture/db-good"
cmp "$CFG/config.json" "$fixture/good"
[[ -f "$fixture/vless-reality.running" ]]
db_set_user_enabled xray ss2022 default-24191 false
jq -e 'any(.inbounds[]; .port == 24192) and all(.inbounds[]; .port != 24191)' "$CFG/config.json" >/dev/null
db_set_user_enabled xray ss2022 default-24191 true
jq -e 'any(.inbounds[]; .port == 24191)' "$CFG/config.json" >/dev/null
echo 'PASS complete candidate validation, restart rollback and last SS2022 user closes only its own port'
rm "$fixture/vless-reality.running"
: > "$fixture/events"
_rebuild_core_config xray
! grep -Eq '^(start|restart) ' "$fixture/events"
touch "$fixture/fail-start"
if _start_core_service vless-reality xray ss2022 generate_xray_config; then exit 1; fi
[[ ! -f "$fixture/vless-reality.running" ]]
echo 'PASS rebuild keeps inactive core stopped; explicit start failure restores stopped state'

CORE_BIN_DIR="$fixture/bin"
mkdir -p "$CORE_BIN_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CORE_BIN_DIR/xray"
printf '#!/usr/bin/env bash\n# candidate\nexit 0\n' > "$fixture/candidate"
chmod 755 "$CORE_BIN_DIR/xray" "$fixture/candidate"
cp "$CORE_BIN_DIR/xray" "$fixture/binary-good"
touch "$fixture/vless-reality.running" "$fixture/fail-start"
if _replace_core_binary xray "$fixture/candidate"; then exit 1; fi
cmp "$CORE_BIN_DIR/xray" "$fixture/binary-good"
[[ -f "$fixture/vless-reality.running" ]]
rm "$fixture/vless-reality.running"
: > "$fixture/events"
_replace_core_binary xray "$fixture/candidate"
! grep -Eq '^(start|restart|stop) ' "$fixture/events"
echo 'PASS failed core update rolls back binary and service; inactive update never starts core'

_db_apply '.xray={} | .singbox.hy2=[{port:25191,password:"test"},{port:25192,password:"test"}] | .singbox.tuic={port:25193}'
mkdir -p "$CFG/certs/hy2"
touch "$CFG/certs/hy2/cert.pem"
generate_singbox_config() { jq '{inbounds:[.singbox.hy2 | (if type == "array" then .[] else . end) | {tag:("hy2-in-"+(.port|tostring)),listen_port:.port}]}' "$DB_FILE" > "$SINGBOX_CONFIG_OUTPUT"; }
echo '{"inbounds":[{"tag":"hy2-in-25191","listen_port":25191},{"tag":"hy2-in-25192","listen_port":25192}]}' > "$CFG/singbox.json"
iptables() { echo "$*" >> "$fixture/nat-events"; }
ip6tables() { iptables "$@"; }
_uninstall_core_port singbox hy2 25191
[[ -f "$CFG/certs/hy2/cert.pem" ]]
jq -e '.singbox.hy2 | (if type == "array" then .[0] else . end) | .port == 25192' "$DB_FILE" >/dev/null
! grep -Eq 'vless-tuic-hop|to-ports 25192|to-ports 25193' "$fixture/nat-events"
echo 'PASS uninstall retains sibling certificate and limits NAT cleanup to selected port'

before=$(sha256sum /etc/resolv.conf 2>/dev/null || true)
configure_dns64
[[ $(sha256sum /etc/resolv.conf 2>/dev/null || true) == "$before" ]]
echo 'PASS DNS remains untouched by default'

_db_apply '.xray.ss2022={port:24191,multi_user:true,users:[{name:"expired",enabled:true,expire_date:"2000-01-01"}]}'
db_set_user_enabled() { return 1; }
send_tg_expired_notice() { touch "$fixture/notified"; }
if check_and_disable_expired_users --notify > "$fixture/expired-count"; then exit 1; fi
[[ $(cat "$fixture/expired-count") == 0 && ! -f "$fixture/notified" ]]
echo 'PASS expiry failure propagates and does not send false success notification'
