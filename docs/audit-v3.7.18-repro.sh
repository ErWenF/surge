#!/usr/bin/env bash
# Reproduce v3.7.18 audit findings in private fixtures; never contact Telegram or manage live services.
source "$(dirname "$0")/../tests/lib/core-fixture.sh" || exit 1
trap 'rm -rf "$fixture"' EXIT
init_db
_db_apply '.xray.vless={port:24400,uuid:"11111111-1111-4111-8111-111111111111",users:[{name:"alice",uuid:"11111111-1111-4111-8111-111111111111",quota:1073741824,used:120,enabled:true}]}'
_flush_core_traffic() { :; }
_user_change_begin() { echo "$fixture"; }
_user_change_apply() { :; }
ensure_expire_check_cron() { return "${mock_cron_result:-0}"; }
for value in 08 010; do
    db_set_user_quota xray vless alice "$value" > "$fixture/quota.stdout" 2> "$fixture/quota.stderr"
    rc=$?
    printf 'quota input=%s status=%s saved_bytes=%s stderr_bytes=%s\n' "$value" "$rc" "$(db_get_user_field xray vless alice quota)" "$(wc -c < "$fixture/quota.stderr")"
done
_db_apply '.xray.vless.users[0] |= (.quota=100 | .used=120 | .enabled=false | .disabled_reason="quota" | .last_alert_percent=95 | .quota_exceeded_notified=true)'
db_reset_user_traffic xray vless alice
printf 'manual reset: '; jq -c '.xray.vless.users[0] | {used,enabled,disabled_reason,last_alert_percent,quota_exceeded_notified}' "$DB_FILE"
for value in 2026-13-40 ''; do
    db_set_user_expire_date xray vless alice "$value" >/dev/null 2>&1
    rc=$?
    printf 'expiry input=<%s> status=%s saved=<%s>\n' "$value" "$rc" "$(db_get_user_expire_date xray vless alice)"
done
mock_cron_result=1
db_set_user_expire_date xray vless alice 2030-01-01 >/dev/null 2>&1
printf 'expiry with successful-new-cron return1: status=%s saved=<%s>\n' "$?" "$(db_get_user_expire_date xray vless alice)"
mock_cron_result=2
db_add_user xray vless newuser 22222222-2222-4222-8222-222222222222 1 2030-01-01 24400 >/dev/null 2>&1
printf 'add user with cron installation failed: status=%s user_count=%s\n' "$?" "$(jq '[.xray.vless.users[] | select(.name == "newuser")] | length' "$DB_FILE")"
init_tg_config
tg_set_config user_bot_enabled true
tg_bot_api_request() { echo request >> "$fixture/api-requests"; echo '{"ok":true,"result":[]}'; }
mkdir "$CFG/tg-user-bot.lock"
printf 'empty bot lock poll statuses:'
for iteration in 1 2 3; do tg_poll_user_bot 0; printf ' %s' "$?"; done
printf '; API requests=%s\n' "$(if [[ -f "$fixture/api-requests" ]]; then wc -l < "$fixture/api-requests"; else echo 0; fi)"

# Replace only private script paths and inject a failure in the system copy.
_header() { :; }; _line() { :; }; _info() { echo "$*"; }; _ok() { echo "$*"; }
_init_version_cache
readlink() { echo "$fixture/current-script"; }
eval "$(declare -f perform_script_update | sed "s|/usr/local/bin/vless-server.sh|$fixture/system-script|g")"
printf '#!/bin/bash\nreadonly VERSION="3.7.18"\n' > "$fixture/current-script"
cp "$fixture/current-script" "$fixture/system-script"
_fetch_script_tmp() {
    local candidate
    candidate=$(mktemp "$fixture/candidate.XXXXXX")
    printf '#!/bin/bash\nreadonly VERSION="3.7.19"\n' > "$candidate"
    echo "$candidate"
}
cp() { [[ "${@: -1}" != "$fixture/system-script" ]] || return 1; command cp "$@"; }
(perform_script_update <<< y) > "$fixture/update.stdout" 2>&1
printf 'failed system-script copy: status=%s current=%s system=%s claimed_sync=%s\n' "$?" "$(_extract_script_version "$fixture/current-script")" "$(_extract_script_version "$fixture/system-script")" "$(grep -c '已同步更新系统目录脚本' "$fixture/update.stdout")"