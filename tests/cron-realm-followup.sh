#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
crontab() {
    if [[ "$1" == -l ]]; then
        if [[ -f "$fixture/fail-read" ]]; then echo 'spool inaccessible' >&2; return 1; fi
        if [[ ! -f "$fixture/cron" ]]; then echo "no crontab for $(id -un)" >&2; return 1; fi
        cat "$fixture/cron"
        sleep 0.1
    else
        cat > "$fixture/cron"
    fi
}
install_cron_entry first '* * * * * echo first # first'
printf '%s\n' '* * * * * echo second-in-a-command # user-backup' >> "$fixture/cron"
install_cron_entry second '* * * * * echo second # second' &
p1=$!
install_cron_entry third '* * * * * echo third # third' &
p2=$!
wait "$p1"
wait "$p2"
grep -q '# first$' "$fixture/cron"
grep -q '# second$' "$fixture/cron"
grep -q '# third$' "$fixture/cron"
remove_cron_entry second
! grep -q '# second$' "$fixture/cron"
grep -q '# user-backup$' "$fixture/cron"
cp "$fixture/cron" "$fixture/before"
touch "$fixture/fail-read"
if install_cron_entry fourth '* * * * * true # fourth'; then exit 1; fi
if remove_cron_entry first; then exit 1; fi
cmp "$fixture/cron" "$fixture/before"
echo 'PASS cron concurrent updates, exact tag deletion and failed-read preservation'

rm "$fixture/fail-read"
command() {
    [[ "$1" != -v || "$2" != flock ]] || return 1
    builtin command "$@"
}
install_cron_entry fallback '* * * * * true # fallback'
remove_cron_entry fallback
[[ ! -d "$CFG/.cron.lock.d" ]]
grep -q '# user-backup$' "$fixture/cron"
unset -f command
echo 'PASS cron mkdir-lock fallback releases after install and removal'

notify=70
tg_get_config() { echo "$notify"; }
[[ $(_quota_alert_thresholds) == $'70\n90\n95' ]]
notify=90
[[ $(_quota_alert_thresholds) == $'90\n95' ]]
notify=99
[[ $(_quota_alert_thresholds) == 99 ]]
notify=bad
[[ $(_quota_alert_thresholds) == $'80\n90\n95' ]]
notify=08
[[ $(_quota_alert_thresholds) == $'8\n90\n95' ]]
echo 'PASS custom quota thresholds, upper bound, invalid values and decimal normalization'

notify=70
_snell_account_traffic() { :; }
tg_send_quota_alert() { printf '%s\n' "$*" >> "$fixture/alerts"; }
id=fb0000000000000000000001
_db_apply --arg id "$id" '.xray["snell-v6"]=[{snell_id:$id,port:32130,users:[{name:"alice",used:750,quota:1000,enabled:true}]}] | .meta.snell_users["snell-v6"]=true'
_snell_sync_traffic
_snell_sync_traffic
[[ $(wc -l < "$fixture/alerts") == 1 ]]
[[ $(db_get_user_alert_state xray snell-v6 alice last_alert_percent) == 70 ]]
notify=90
_db_apply '.xray["snell-v6"][0].users[0].used=850 | .xray["snell-v6"][0].users[0].last_alert_percent=0'
_snell_sync_traffic
[[ $(wc -l < "$fixture/alerts") == 1 ]]
echo 'PASS Snell honors 70/90 percent settings and suppresses duplicate notifications'

ensure_realm_dir
cat > "$REALM_RULES_FILE" <<'JSON'
[
 {"listen_host":"127.0.0.1","listen_port":32111,"remote_host":"127.0.0.1","remote_port":32121,"transport":"tcp"},
 {"listen_host":"127.0.0.1","listen_port":32112,"remote_host":"127.0.0.1","remote_port":32122,"transport":"udp"},
 {"listen_host":"::1","listen_port":32113,"remote_host":"::1","remote_port":32123,"transport":"tcp+udp","remark":"line\nbreak"},
 {"listen_host":"127.0.0.1","listen_port":32114,"remote_host":"127.0.0.1","remote_port":32124,"enabled":false}
]
JSON
realm_generate_config
python3 - "$REALM_CONFIG_FILE" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as f: endpoints = tomllib.load(f)['endpoints']
assert len(endpoints) == 3
assert endpoints[0]['network'] == {'no_tcp':False, 'use_udp':False}
assert endpoints[1]['network'] == {'no_tcp':True, 'use_udp':True}
assert endpoints[2]['network'] == {'no_tcp':False, 'use_udp':True}
assert endpoints[2]['listen'] == '[::1]:32113'
assert endpoints[2]['remote'] == '[::1]:32123'
PY
iptables() {
    printf '%s\n' '1 100 ACCEPT tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:443' \
      '2 200 ACCEPT tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:4430' \
      '3 400 ACCEPT udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:443'
}
[[ $(realm_get_traffic_bytes 443 tcp) == 100 ]]
[[ $(realm_get_traffic_bytes 443 udp) == 400 ]]
[[ $(realm_get_traffic_bytes 4430 tcp) == 200 ]]
echo 'PASS Realm TOML network flags, IPv6 formatting, disabled endpoints and exact traffic ports'

# Real group dispatch and per-user stop, with systemd calls isolated.
DISTRO=debian
id=fb0000000000000000000001
_db_apply --arg id "$id" '.xray["snell-v6"]=[{snell_id:$id,port:32130,users:[{name:"default",enabled:true}]}] | .meta.snell_users["snell-v6"]=true'
touch "$fixture/vless-snellu-$id.running"
systemctl() {
    case "$1" in
        is-active) if [[ -f "$fixture/$2.running" ]]; then echo active; else echo inactive; return 3; fi ;;
        stop)
            [[ ! -f "$fixture/false-stop" ]] || return 0
            rm -f "$fixture/$2.running" ;;
        *) return 1 ;;
    esac
}
cleanup_hy2_nat_rules() { :; }
stop_services >/dev/null
[[ ! -f "$fixture/vless-snellu-$id.running" ]]
touch "$fixture/vless-snellu-$id.running" "$fixture/false-stop"
if stop_services >/dev/null; then exit 1; fi
[[ -f "$fixture/vless-snellu-$id.running" ]]
echo 'PASS stop-all dispatch covers Snell instances and refuses false-success stops'

rm "$fixture/false-stop"
DISTRO=alpine
other=fb0000000000000000000002
_db_apply --arg id "$other" '.xray["snell-v6"] += [{snell_id:$id,port:32131,users:[{name:"stopped",enabled:true}]}]'
rc-service() {
    case "$2" in
        status) [[ -f "$fixture/$1.running" ]] ;;
        stop) [[ -f "$fixture/$1.running" ]] || return 1; rm "$fixture/$1.running" ;;
        *) return 1 ;;
    esac
}
_snell_group_service stop snell-v6
[[ ! -f "$fixture/vless-snellu-$id.running" ]]
echo 'PASS OpenRC group stop skips already stopped instances (mocked rc-service)'
