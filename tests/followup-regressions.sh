#!/usr/bin/env bash
# Actual script functions with isolated storage and injected service/API failures.
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
DISTRO=debian
_listen_addr() { echo 127.0.0.1; }
get_connection_addresses() { echo '192.0.2.1|'; }
_snell_write_service() { [[ ! -f "$fixture/fail-unit" ]]; }
_snell_counter_prepare() { :; }
_snell_nft_ready() { :; }
nft() { :; }
_snell_update_counter_port() { echo "$2" > "$fixture/counter-port"; }
_snell_user_share() { :; }
is_internal_port_occupied() { :; }
svc() {
    printf '%s %s\n' "$1" "$2" >> "$fixture/events"
    case "$1" in
        status) [[ -f "$fixture/$2.running" ]] ;;
        is-enabled) [[ -f "$fixture/$2.enabled" ]] ;;
        start|restart)
            if [[ -f "$fixture/fail-start" ]]; then rm "$fixture/fail-start"; return 1; fi
            touch "$fixture/$2.running" ;;
        stop) rm -f "$fixture/$2.running" ;;
        enable) touch "$fixture/$2.enabled" ;;
        disable) rm -f "$fixture/$2.enabled" ;;
        *) return 1 ;;
    esac
}

# Neither candidate nor published sing-box config may expose passwords.
_db_apply '.singbox.trojan={port:32101,password:"synthetic-secret",users:[{name:"alice",uuid:"synthetic-secret",enabled:true}]}'
printf '#!/bin/bash\nexit 0\n' > "$fixture/check"
chmod +x "$fixture/check"
SINGBOX_BIN="$fixture/check"
generate_singbox_config >/dev/null
[[ $(stat -c %a "$CFG/singbox.json") == 600 ]]
backup=$(_user_change_begin singbox)
_user_change_apply singbox "$backup" false
[[ $(stat -c %a "$CFG/singbox.json") == 600 ]]
if [[ $EUID == 0 ]]; then
    chmod 711 "$fixture"
    python3 - "$CFG/singbox.json" <<'PY'
import os, pathlib, sys
os.setgroups([]); os.setgid(65534); os.setuid(65534)
try: pathlib.Path(sys.argv[1]).read_bytes()
except PermissionError: pass
else: raise AssertionError('unprivileged read of private config succeeded')
PY
fi
echo 'PASS private candidate/publication permissions and root-only credential access'

# Preserve all four combinations of manual runtime/autostart states on edit.
id=fa0000000000000000000001
service="vless-snellu-$id"
mkdir -p "$CFG/snell-users"
_snell_account_traffic() { _db_apply '.xray["snell-v6"][0].users[0].used += 10'; }
for runtime in stopped running; do
    for autostart in disabled enabled; do
        _db_apply --arg id "$id" '.xray["snell-v6"]=[{snell_id:$id,port:32102,psk:"oldpassword",mode:"default",users:[{name:"alice",used:20,quota:0,enabled:true}]}] | .meta.snell_users["snell-v6"]=true'
        printf '[snell-server]\nlisten = 127.0.0.1:32102\npsk = oldpassword\nmode = default\n' > "$CFG/snell-users/$id.conf"
        chmod 600 "$CFG/snell-users/$id.conf"
        rm -f "$fixture/$service.running" "$fixture/$service.enabled"
        [[ "$runtime" != running ]] || touch "$fixture/$service.running"
        [[ "$autostart" != enabled ]] || touch "$fixture/$service.enabled"
        row=$(_snell_rows snell-v6)
        _snell_edit_user_commit snell-v6 alice "$row" 32103 newpassword system unshaped
        [[ $(db_get_user_field xray snell-v6 alice used) == 30 ]]
        if [[ "$runtime" == running ]]; then [[ -f "$fixture/$service.running" ]]; else [[ ! -f "$fixture/$service.running" ]]; fi
        if [[ "$autostart" == enabled ]]; then [[ -f "$fixture/$service.enabled" ]]; else [[ ! -f "$fixture/$service.enabled" ]]; fi
        grep -q 'psk = newpassword' "$CFG/snell-users/$id.conf"
        row=$(_snell_rows snell-v6)
        cp "$CFG/snell-users/$id.conf" "$fixture/before-conf"
        touch "$fixture/fail-unit"
        if _snell_edit_user_commit snell-v6 alice "$row" 32104 brokenpassword '' ''; then exit 1; fi
        rm "$fixture/fail-unit"
        cmp "$CFG/snell-users/$id.conf" "$fixture/before-conf"
        [[ $(db_get_user_field xray snell-v6 alice used) == 40 ]]
        [[ $(cat "$fixture/counter-port") == 32103 ]]
        if [[ "$runtime" == running ]]; then [[ -f "$fixture/$service.running" ]]; else [[ ! -f "$fixture/$service.running" ]]; fi
        if [[ "$autostart" == enabled ]]; then [[ -f "$fixture/$service.enabled" ]]; else [[ ! -f "$fixture/$service.enabled" ]]; fi
    done
done
# Reject stale edits before accounting or touching services.
_db_apply '.xray["snell-v6"][0].port=32107'
if _snell_edit_user_commit snell-v6 alice "$row" 32105 stale '' ''; then exit 1; fi
echo 'PASS Snell edit runtime/autostart preservation, failed apply rollback and accounting retention'

# Wait at an actual input prompt; another process must still acquire the DB lock.
mkfifo "$fixture/input"
exec 8<>"$fixture/input"
_snell_add_user snell-v6 < "$fixture/input" > "$fixture/prompt-log" 2>&1 &
prompt_pid=$!
sleep 0.2
flock -n "$CFG/.db.lock" true
printf '\n' >&8
wait "$prompt_pid" && exit 1
exec 8>&-
echo 'PASS Snell input waits outside the DB lock'

# Subscription validation, load and startup failures restore every managed file.
SUBSCRIPTION_NGINX_ROOT="$fixture/nginx"
SUBSCRIPTION_WEB_ROOT="$fixture/web"
SUBSCRIPTION_HOSTS_FILE="$fixture/hosts"
mkdir -p "$SUBSCRIPTION_NGINX_ROOT/conf.d" "$SUBSCRIPTION_NGINX_ROOT/sites-enabled" "$SUBSCRIPTION_WEB_ROOT"
echo unrelated-site > "$SUBSCRIPTION_NGINX_ROOT/sites-enabled/customer"
echo fake-site > "$SUBSCRIPTION_NGINX_ROOT/conf.d/vless-fake.conf"
echo existing-web > "$SUBSCRIPTION_WEB_ROOT/index.html"
old_uuid=11111111-2222-4333-8444-555555555555
new_uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
printf '%s\n' "$old_uuid" > "$CFG/sub_uuid"
_write_sub_info "$old_uuid" 18443 old.example false
mkdir -p "$CFG/subscription/$old_uuid"
for file in base64 clash.yaml surge.conf; do echo "old-$file" > "$CFG/subscription/$old_uuid/$file"; done
echo old-conf > "$SUBSCRIPTION_NGINX_ROOT/conf.d/vless-sub.conf"
printf '127.0.0.1 localhost\n127.0.0.1 user.example # user\n' > "$SUBSCRIPTION_HOSTS_FILE"
cp "$CFG/sub.info" "$fixture/before-info"
cp "$SUBSCRIPTION_HOSTS_FILE" "$fixture/before-hosts"
gen_v2ray_sub() { echo new-base64; }
gen_clash_sub() { echo new-clash; }
gen_surge_sub() { echo new-surge; }
nginx() {
    if [[ -f "$fixture/fail-conflict" ]]; then echo 'conflicting server name "_" on 0.0.0.0:18444, ignored' >&2; fi
    [[ ! -f "$fixture/fail-validation" ]]
}
_subscription_probe() { [[ ! -f "$fixture/fail-probe" ]]; }
_subscription_reload_nginx() {
    echo reload >> "$fixture/nginx-events"
    if [[ -f "$fixture/fail-reload" ]]; then rm "$fixture/fail-reload"; return 1; fi
}
for failure in validation reload start probe conflict; do
    rm -f "$fixture/nginx.running" "$fixture/nginx.enabled"
    [[ "$failure" != reload ]] || touch "$fixture/nginx.running"
    touch "$fixture/fail-$failure"
    if _subscription_change publish "$new_uuid" 18444 new.example false true; then exit 1; fi
    rm -f "$fixture/fail-$failure"
    cmp "$CFG/sub.info" "$fixture/before-info"
    cmp "$SUBSCRIPTION_HOSTS_FILE" "$fixture/before-hosts"
    [[ $(cat "$CFG/sub_uuid") == "$old_uuid" && $(cat "$SUBSCRIPTION_NGINX_ROOT/conf.d/vless-sub.conf") == old-conf ]]
    [[ $(cat "$CFG/subscription/$old_uuid/base64") == old-base64 && ! -d "$CFG/subscription/$new_uuid" ]]
    [[ $(cat "$SUBSCRIPTION_NGINX_ROOT/sites-enabled/customer") == unrelated-site && $(cat "$SUBSCRIPTION_NGINX_ROOT/conf.d/vless-fake.conf") == fake-site ]]
    if [[ "$failure" == reload ]]; then [[ -f "$fixture/nginx.running" ]]; else [[ ! -f "$fixture/nginx.running" ]]; fi
    [[ ! -f "$fixture/nginx.enabled" ]]
done
touch "$fixture/nginx.running"
_subscription_change publish "$new_uuid" 18444 new.example false false
[[ ! -d "$CFG/subscription/$old_uuid" && $(cat "$CFG/sub_uuid") == "$new_uuid" ]]
[[ $(stat -c %a "$CFG/sub.info") == 600 ]]
cmp "$SUBSCRIPTION_HOSTS_FILE" "$fixture/before-hosts"
touch "$fixture/fail-reload"
if _subscription_change disable; then exit 1; fi
[[ -f "$CFG/sub.info" && -f "$CFG/subscription/$new_uuid/base64" ]]
_subscription_change disable
[[ ! -f "$CFG/sub.info" && ! -d "$CFG/subscription/$new_uuid" && -f "$fixture/nginx.running" ]]
[[ -f "$SUBSCRIPTION_NGINX_ROOT/sites-enabled/customer" && ! -f "$fixture/nginx.enabled" ]]
echo 'PASS subscription UUID/files/hosts rollback, failed disable and unrelated website preservation'

# Generation-time bytes are captured after validation; rollback retains them.
_db_apply '.xray.vless={port:32106,users:[{name:"charlie",used:0,enabled:true}]}'
printf '%s\n' '{"api":{"services":["StatsService"]},"inbounds":[]}' > "$CFG/config.json"
touch "$fixture/vless-reality.running"
_core_traffic_epoch() { echo fixture-core; }
xray_api_query() { printf '{"stat":[{"name":"user>>>charlie@vless>>>traffic>>>uplink","value":%s}]}\n' "$(cat "$fixture/live-bytes")"; }
echo 100 > "$fixture/live-bytes"
_flush_core_traffic xray
backup=$(_user_change_begin xray)
XRAY_BIN="$fixture/check"
generate_xray_config() {
    echo 150 > "$fixture/live-bytes"
    printf '%s\n' '{"api":{"services":["StatsService"]},"inbounds":[]}' > "$XRAY_CONFIG_OUTPUT"
}
_user_change_apply xray "$backup" true
[[ $(db_get_user_field xray vless charlie used) == 150 ]]
[[ $(jq '.xray.vless.users[0].used' "$backup/db.json") == 150 ]]
backup=$(_user_change_begin xray)
generate_xray_config() { echo 190 > "$fixture/live-bytes"; cp "$backup/active.json" "$XRAY_CONFIG_OUTPUT"; }
touch "$fixture/fail-start"
if _user_change_apply xray "$backup" true; then exit 1; fi
[[ $(db_get_user_field xray vless charlie used) == 190 ]]
echo 'PASS late traffic checkpoint includes validation-period bytes and survives restart rollback'

_db_apply '.xray={vless:{port:32106,users:[{name:"charlie",used:740,quota:1000,enabled:true}]}} | .singbox={}'
_ensure_singbox_default_users() { :; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
check_monthly_traffic_reset() { :; }
_pgrep() { [[ "$1" == xray ]]; }
xray() { echo '{"stat":[{"name":"user>>>charlie@vless>>>traffic>>>uplink","value":200}]}'; }
tg_get_config() { echo 70; }
tg_send_quota_alert() { echo "$*" >> "$fixture/core-alerts"; }
sync_all_user_traffic false
sync_all_user_traffic false
[[ $(db_get_user_field xray vless charlie used) == 750 ]]
[[ $(wc -l < "$fixture/core-alerts") == 1 ]]
[[ $(db_get_user_alert_state xray vless charlie last_alert_percent) == 70 ]]
echo 'PASS Xray configured quota alert triggers at 75 percent with a 70 percent threshold'
