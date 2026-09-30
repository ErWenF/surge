#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
CFG="$fixture"
TRAFFIC_INTERVAL_FILE="$fixture/interval"
DISTRO=debian

load_function() {
    eval "$(awk -v fn="$1" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {exit}' "$repo/vless-server.sh")"
}
for fn in ensure_cron_service_running setup_traffic_cron setup_tg_user_bot_cron install_expire_check_cron; do load_function "$fn"; done

cron_service_is_active() { [[ -f "$fixture/active" ]]; }
cron() { touch "$fixture/active"; }
rc-service() { return 1; }
rc-update() { return 1; }
systemctl() { return 1; }
service() { return 1; }
crond() { return 1; }
_err() { :; }
_ok() { :; }
get_bash_interpreter() { echo /bin/bash; }
build_cron_command() { echo '*/5 * * * * /bin/bash script --sync-traffic # sync-traffic'; }
install_cron_entry() { echo "$2" > "$fixture/entry"; }
set_traffic_interval() { echo "$1" > "$TRAFFIC_INTERVAL_FILE"; }
printf '#!/usr/bin/env bash\n' > "$fixture/script"
chmod +x "$fixture/script"
readlink() { echo "$fixture/script"; }

ensure_cron_service_running
[[ -f "$fixture/active" ]]
rm "$fixture/active"
cron() { return 1; }
if setup_traffic_cron 5 true; then exit 1; fi
[[ ! -f "$fixture/entry" ]]
[[ ! -f "$TRAFFIC_INTERVAL_FILE" ]]
cron() { touch "$fixture/active"; }
setup_traffic_cron 5 true
[[ -f "$fixture/entry" ]]
[[ $(cat "$TRAFFIC_INTERVAL_FILE") == 5 ]]
rm "$fixture/entry" "$fixture/active"
cron() { return 1; }
if setup_tg_user_bot_cron true; then exit 1; fi
[[ ! -f "$fixture/entry" ]]
cron() { touch "$fixture/active"; }
setup_tg_user_bot_cron true
[[ -f "$fixture/entry" ]]
echo 'PASS direct cron fallback and no half-enabled scheduled jobs'

install_cron_entry() { return 1; }
if install_expire_check_cron; then echo 'FAIL expire cron masked installation failure'; exit 1; fi
install_cron_entry() { :; }
install_expire_check_cron
echo 'PASS expire cron installation propagates failure'
printf 'check_root() { :; }\ninit_db() { :; }\ninstall_expire_check_cron() { return 1; }\n' > "$fixture/cli.sh"
awk '/^# 命令行参数处理$/ {on=1} on {print}' "$repo/vless-server.sh" >> "$fixture/cli.sh"
if bash "$fixture/cli.sh" --setup-expire-cron; then exit 1; fi
echo 'PASS expire cron CLI exits nonzero on installation failure'
