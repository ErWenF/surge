#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
printf '%s\n' '{"enabled":true,"bot_token":"100:admin_fixture","chat_id":"123","user_bot_enabled":true,"user_bot_update_offset":7}' > "$TG_CONFIG_FILE"
init_tg_config
[[ $(tg_get_user_bot_token) == 100:admin_fixture ]]
[[ $(tg_get_config user_bot_update_offset) == 7 ]]
[[ $(tg_get_config user_bot_traffic_view) == net && $(tg_get_config user_bot_traffic_view_version) == 1 ]]
[[ $(stat -c %a "$TG_CONFIG_FILE") == 600 ]]
_tg_config_lock_acquire
[[ $(cat "$TG_CONFIG_LOCK_DIR/pid") == "$BASHPID" ]]
tg_set_config server_name fixture
[[ -d "$TG_CONFIG_LOCK_DIR" ]]
_tg_config_lock_release
[[ ! -d "$TG_CONFIG_LOCK_DIR" ]]
tg_set_config field_one 1 & p1=$!
tg_set_config field_two 2 & p2=$!
wait "$p1"; wait "$p2"
[[ $(tg_get_config field_one) == 1 && $(tg_get_config field_two) == 2 ]]

api_mode=ok
webhook=''
curl() {
    [[ "$*" != *admin_fixture* && "$*" != *user_fixture* && "$*" != *rotated_fixture* ]]
    local request
    request="$* $(cat)"
    printf '%s\n' "$request" >> "$fixture/api-requests"
    case "$request" in
        *getMe*) printf '{"ok":true,"result":{"id":100,"username":"fixture_bot"}}' ;;
        *getWebhookInfo*) printf '{"ok":true,"result":{"url":"%s"}}' "$webhook" ;;
        *sendMessage*)
            if [[ "$api_mode" == admin_failure && "$request" == *bot100:admin_fixture/* ]]; then
                printf '{"ok":false,"error_code":500}'
                return 0
            fi
            case "$api_mode" in
                ok|admin_failure) printf '{"ok":true}' ;;
                blocked) printf '{"ok":false,"error_code":403}' ;;
                failure) return 28 ;;
                invalid) printf '{"ok":false,"error_code":401}' ;;
            esac ;;
        *) printf '{"ok":true,"result":[]}' ;;
    esac
}
tg_send_message $'name_&\nhello=world'
grep -q 'bot100:admin_fixture/sendMessage' "$fixture/api-requests"
grep -q -- '--data-urlencode text=' "$fixture/api-requests"
grep -q -- '--max-time 25' "$fixture/api-requests"
api_mode=invalid
if tg_send_message hello; then exit 1; fi
api_mode=failure
if tg_send_message hello; then exit 1; fi
api_mode=ok
tg_save_user_bot_identity '' 100
[[ $(tg_get_config user_bot_update_offset) == 7 ]]
tg_save_user_bot_identity 200:user_fixture 200
[[ $(tg_get_config user_bot_update_offset) == 0 ]]
tg_set_config user_bot_update_offset 9
tg_save_user_bot_identity 200:rotated_fixture 200
[[ $(tg_get_config user_bot_update_offset) == 9 ]]
tg_send_chat_message 123 hello
tail -n 1 "$fixture/api-requests" | grep -q 'bot200:rotated_fixture/sendMessage'
tg_send_message hello
tail -n 1 "$fixture/api-requests" | grep -q 'bot100:admin_fixture/sendMessage'
before=$(wc -l < "$fixture/api-requests")
tg_send_message "$(printf '%04500d' 0)"
[[ $(wc -l < "$fixture/api-requests") == $((before + 3)) ]]
before=$(wc -l < "$fixture/api-requests")
tg_send_chat_message 123 "$(printf '%04500d' 0)"
[[ $(wc -l < "$fixture/api-requests") == $((before + 3)) ]]
before=$(wc -l < "$fixture/api-requests")
LC_ALL=C tg_send_chat_message 123 "$(jq -nr '"\u4e2d\ud83d\ude80" * 2100')"
[[ $(wc -l < "$fixture/api-requests") == $((before + 3)) ]]
tg_set_config chat_id -123
tg_send_message group
tail -n 1 "$fixture/api-requests" | grep -q 'chat_id=-123'
tg_set_config chat_id 123
mv "$TG_CONFIG_FILE" "$fixture/tg-config-backup"
db_set_tg_config bot_token 100:admin_fixture
db_set_tg_config chat_id 123
send_tg_message $'legacy&name\nline'
api_mode=invalid
if send_tg_message hello; then exit 1; fi
api_mode=ok
mv "$fixture/tg-config-backup" "$TG_CONFIG_FILE"
! grep -q parse_mode "$fixture/api-requests"
[[ $(tg_validate_user_bot 200:user_fixture) == 100 ]]
webhook=https://example.test/keep
if tg_validate_user_bot 200:user_fixture; then exit 1; fi
! grep -q deleteWebhook "$fixture/api-requests"
webhook=''
if tg_change_user_bot_token 200:user_fixture; then exit 1; fi
echo 'PASS independent tokens, legacy offset migration, same-bot rotation, API failure and webhook preservation'

_db_apply '.xray.ss2022=[
    {port:11111,users:[{name:"alice",uuid:"fixture-a",used:100,quota:1000,enabled:true}]},
    {port:22222,users:[{name:"bob",uuid:"fixture-b",used:200,quota:1000,enabled:true}]}]'
hash=$(tg_hash_bind_token AABBCCDDEEFF)
db_set_user_tg_bind_token xray ss2022 alice "$hash" "$(( $(date +%s) + 100 ))"
db_set_user_tg_binding xray ss2022 alice 123 alice now "$hash"
[[ $(db_find_user_by_tg_chat 123) == 'xray|ss2022|alice' ]]
cp "$DB_FILE" "$fixture/before-bind"
if db_set_user_tg_binding xray ss2022 alice 456 other now "$hash"; then exit 1; fi
if db_set_user_tg_binding xray ss2022 bob 123 bob now; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-bind"
db_set_user_tg_bind_token xray ss2022 bob "$hash" "$(( $(date +%s) - 1 ))"
if db_set_user_tg_binding xray ss2022 bob 456 bob now "$hash"; then exit 1; fi
_db_apply '.xray.ss2022[1].users[0].telegram_chat_id="123"'
[[ -z $(db_find_user_by_tg_chat 123) ]]
_db_apply 'del(.xray.ss2022[1].users[0].telegram_chat_id) | .xray.ss2022[1].users += [.xray.ss2022[1].users[0]]'
if db_set_user_tg_bind_token xray ss2022 bob "$hash" 9999999999; then exit 1; fi
if db_set_user_tg_traffic_view xray ss2022 bob net; then exit 1; fi
_db_apply '.xray.ss2022[1].users |= [.[0]]'
_db_apply '.xray.ss2022[1].users += [(.xray.ss2022[0].users[0] | del(.telegram_chat_id))]'
[[ -z $(db_find_user_by_tg_chat 123) ]]
_db_apply '.xray.ss2022[1].users |= [.[0]]'
echo 'PASS binding code consumption/expiry checked atomically; duplicate chats and ambiguous users rejected'

get_tg_server_display() { echo fixture; }
db_get_expiring_users() { echo 'xray|ss2022|alice|2026-10-17|3'; }
api_mode=admin_failure
if send_tg_expire_warning alice ss2022 2026-10-17 3 xray; then exit 1; fi
if send_tg_expired_notice alice ss2022 2026-10-17 xray; then exit 1; fi
[[ $(send_expire_warnings 3) == 0 ]]
[[ -z $(db_get_user_alert_state xray ss2022 alice last_expire_warn_day) ]]
api_mode=ok
[[ $(send_expire_warnings 3) == 1 ]]
[[ $(db_get_user_alert_state xray ss2022 alice last_expire_warn_day) == 3 ]]
[[ $(send_expire_warnings 3) == 0 ]]
echo 'PASS legacy delivery API status/encoding and failed admin expiry warnings remain retryable'

db_set_user_tg_traffic_view xray ss2022 bob server_estimate
cp "$DB_FILE" "$fixture/before-default-migration"
jq 'del(.user_bot_traffic_view_version) | .user_bot_traffic_view="server_estimate"' "$TG_CONFIG_FILE" > "$fixture/old-default-config"
cp "$fixture/old-default-config" "$TG_CONFIG_FILE"
init_tg_config
[[ $(tg_get_config user_bot_traffic_view) == net && $(tg_get_config user_bot_update_offset) == 9 ]]
jq 'del(.user_bot_traffic_view, .user_bot_traffic_view_version)' "$fixture/old-default-config" > "$fixture/expected-settings"
jq 'del(.user_bot_traffic_view, .user_bot_traffic_view_version)' "$TG_CONFIG_FILE" > "$fixture/actual-settings"
cmp "$fixture/expected-settings" "$fixture/actual-settings"
cmp "$DB_FILE" "$fixture/before-default-migration"
cp "$TG_CONFIG_FILE" "$fixture/migrated-settings"
init_tg_config
cmp "$TG_CONFIG_FILE" "$fixture/migrated-settings"
tg_get_user_report_by_chat 123 | grep -q '已使用：100 B'
[[ $(db_get_user_field xray ss2022 bob telegram_traffic_view) == server_estimate ]]
mv "$TG_CONFIG_FILE" "$fixture/saved-settings"
init_tg_config
[[ $(tg_get_config user_bot_traffic_view) == net ]]
mv "$fixture/saved-settings" "$TG_CONFIG_FILE"
echo 'PASS fresh/legacy defaults are net, migration is idempotent and tokens/offset/bindings/per-user choices remain unchanged'

sync_all_user_traffic() { echo synced >> "$fixture/sync"; [[ ! -f "$fixture/sync-fail" ]]; }
tg_user_bot_handle_update '{"message":{"chat":{"id":999,"type":"private"},"text":"/traffic"}}'
[[ ! -e "$fixture/sync" ]]
tg_set_config user_bot_traffic_view server_estimate
tg_get_user_report_by_chat 123 > "$fixture/report"
grep -q alice "$fixture/report"
! grep -q bob "$fixture/report"
! grep -q '统计口径' "$fixture/report"
grep -q '已使用：200 B' "$fixture/report"
grep -q '总配额：1.95 KiB' "$fixture/report"
grep -q '剩余流量：1.76 KiB' "$fixture/report"
grep -q '使用率：10%' "$fixture/report"
! grep -Eq '说明：|估算不含|官网账单|账号状态：|到期时间：' "$fixture/report"
cp "$DB_FILE" "$fixture/before-display-change"
tg_set_config user_bot_traffic_view net
tg_get_user_report_by_chat 123 > "$fixture/net-report"
! grep -q '统计口径' "$fixture/net-report"
grep -q '已使用：100 B' "$fixture/net-report"
grep -q '总配额：1000 B' "$fixture/net-report"
grep -q '剩余流量：900 B' "$fixture/net-report"
grep -q '使用率：10%' "$fixture/net-report"
cmp "$DB_FILE" "$fixture/before-display-change"
tg_set_config user_bot_traffic_view server_estimate
echo 'PASS server estimate doubles used/quota/remaining together, correct binary units and unchanged database/enforcement values'
db_set_user_tg_binding xray ss2022 bob 456 bob now
accounting_before=$(jq -c '[.xray.ss2022[].users[] | {name,used,quota,enabled}]' "$DB_FILE")
db_set_user_tg_traffic_view xray ss2022 alice net
db_set_user_tg_traffic_view xray ss2022 bob server_estimate
tg_get_user_report_by_chat 123 > "$fixture/per-user-a"
tg_get_user_report_by_chat 456 > "$fixture/per-user-b"
grep -q '已使用：100 B' "$fixture/per-user-a"
grep -q '已使用：400 B' "$fixture/per-user-b"
[[ $(jq -c '[.xray.ss2022[].users[] | {name,used,quota,enabled}]' "$DB_FILE") == "$accounting_before" ]]
cp "$DB_FILE" "$fixture/before-invalid-view"
if db_set_user_tg_traffic_view xray ss2022 alice invalid; then exit 1; fi
if db_set_user_tg_traffic_view xray ss2022 missing net; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-invalid-view"
db_set_user_tg_traffic_view xray ss2022 alice default
[[ -z $(db_get_user_field xray ss2022 alice telegram_traffic_view) ]]
tg_get_user_report_by_chat 123 | grep -q '已使用：200 B'
_db_apply '.singbox.trojan={port:33333,users:[{name:"carol",uuid:"fixture-c",used:50,quota:100,enabled:true}]}'
db_set_user_tg_binding singbox trojan carol 789 carol now
db_set_user_tg_traffic_view singbox trojan carol net
tg_get_user_report_by_chat 789 | grep -q '已使用：50 B'
_db_apply '.singbox={}'
echo 'PASS independent per-user display flags, default inheritance, single/multiple ports and invalid/ambiguous-user rejection'
cp "$DB_FILE" "$fixture/before-user-command"
tg_user_bot_handle_update '{"message":{"chat":{"id":123,"type":"private"},"text":"/setview net"}}'
cmp "$DB_FILE" "$fixture/before-user-command"
tg_get_user_report_by_chat 123 | grep -q '已使用：200 B'
echo 'PASS user bot cannot change an administrator-selected traffic display policy'

cp "$DB_FILE" "$fixture/before-status-report"
tg_get_user_report_by_chat 123 status > "$fixture/status-report"
grep -q '^账号状态$' "$fixture/status-report"
grep -q '账号状态：正常' "$fixture/status-report"
grep -q '到期时间：永不过期' "$fixture/status-report"
! grep -Eq '已使用：|总配额：|剩余流量：|使用率：|流量周期：|最后同步：|统计口径：|说明：|估算不含' "$fixture/status-report"
for reason in manual quota expired other; do
    case "$reason" in manual) expected_status=管理员停用 ;; quota) expected_status=流量超额停用 ;; expired) expected_status=已过期 ;; other) expected_status=已禁用 ;; esac
    _db_apply --arg reason "$reason" '.xray.ss2022[0].users[0] |= (.enabled=false | .disabled_reason=$reason)'
    tg_get_user_report_by_chat 123 status | grep -q "账号状态：$expected_status"
done
_db_apply '.xray.ss2022[0].users[0] |= (.enabled=true | .expire_date="2000-01-01")'
tg_get_user_report_by_chat 123 status > "$fixture/expired-status"
grep -q '账号状态：已过期' "$fixture/expired-status"
grep -q '到期时间：2000-01-01' "$fixture/expired-status"
if tg_get_user_report_by_chat 999 status; then exit 1; fi
if tg_get_user_report_by_chat 123 invalid; then exit 1; fi
cp "$fixture/before-status-report" "$DB_FILE"
[[ ! -e "$fixture/sync" ]]
echo 'PASS distinct traffic/status reports, correct disabled/expired states, concise replies and no status-triggered synchronization'
original_api=$(declare -f tg_bot_api_request)
tg_bot_api_request() {
    if [[ "$1" == getUpdates ]]; then
        printf '%s\n' "$*" >> "$fixture/poll-args"
        cat "$fixture/updates"
    elif [[ "$1" == sendMessage ]]; then
        printf '%s\n' "$*" >> "$fixture/replies"
        if [[ "$api_mode" == failure ]]; then return 28; fi
        if [[ "$api_mode" == blocked && "$*" == *chat_id=456* ]]; then printf '{"ok":false,"error_code":403}'
        else printf '{"ok":true}'; fi
    fi
}
printf '%s\n' '{"ok":true,"result":[{"update_id":10,"message":{"chat":{"id":123,"type":"private"},"text":"/traffic"}},{"update_id":11,"message":{"chat":{"id":123,"type":"private"},"text":"/traffic"}},{"update_id":12,"message":{"chat":{"id":123,"type":"group"},"text":"/traffic"}}]}' > "$fixture/updates"
test_clock=$(command date +%s)
date() { if [[ "$1" == +%s ]]; then echo "$test_clock"; else command date "$@"; fi; }
tg_poll_user_bot 20
[[ $(wc -l < "$fixture/sync") == 1 ]]
tg_refresh_query_traffic
[[ $(wc -l < "$fixture/sync") == 1 ]]
test_clock=$((test_clock + 5))
tg_refresh_query_traffic
[[ $(wc -l < "$fixture/sync") == 2 ]]
unset -f date
[[ $(tg_get_config user_bot_update_offset) == 13 ]]
grep -q timeout=20 "$fixture/poll-args"
[[ ! -d "$CFG/tg-user-bot.lock" ]]
api_mode=failure
if tg_poll_user_bot; then exit 1; fi
[[ $(tg_get_config user_bot_update_offset) == 13 && ! -d "$CFG/tg-user-bot.lock" ]]
sync_before_status=$(wc -l < "$fixture/sync")
api_mode=blocked
printf '%s\n' '{"ok":true,"result":[{"update_id":13,"message":{"chat":{"id":456,"type":"private"},"text":"/help"}},{"update_id":14,"message":{"chat":{"id":123,"type":"private"},"text":"/status"}}]}' > "$fixture/updates"
tg_poll_user_bot
[[ $(tg_get_config user_bot_update_offset) == 15 ]]
grep -q '账号状态：正常' "$fixture/replies"
[[ $(wc -l < "$fixture/sync") == "$sync_before_status" ]]
api_mode=ok
rm -f "$CFG/.tg-query-last-sync"
touch "$fixture/sync-fail"
printf '%s\n' '{"ok":true,"result":[{"update_id":15,"message":{"chat":{"id":123,"type":"private"},"text":"/traffic"}}]}' > "$fixture/updates"
tg_poll_user_bot
grep -q '本次统计同步失败' "$fixture/replies"
rm "$fixture/sync-fail"
tg_bot_api_request() {
    touch "$fixture/poll-ready"
    for attempt in {1..200}; do
        if [[ -f "$fixture/poll-release" ]]; then printf '{"ok":true,"result":[]}'; return 0; fi
        sleep 0.05
    done
    return 1
}
_tg_poll_user_bot 20 & poll_worker=$!
for attempt in {1..200}; do
    [[ -f "$fixture/poll-ready" ]] && break
    sleep 0.05
done
poll_owner=$(cat "$CFG/tg-user-bot.lock/pid")
touch "$fixture/poll-release"
wait "$poll_worker"
[[ "$poll_owner" == "$poll_worker" && ! -d "$CFG/tg-user-bot.lock" ]]
eval "$original_api"
echo 'PASS private reports, unbound-query rejection, batch sync, reply retry, blocked-chat progress and actual poll-owner wait'

# Both menu renders must keep configured tokens private.
_header() { :; }; _line() { :; }; _dline() { :; }; _item() { echo "$*"; }
tg_user_bot_service_action() { return 1; }
crontab() { return 1; }
_configure_tg_user_bot <<< 0 > "$fixture/user-menu"
_configure_tg_notify <<< 0 > "$fixture/admin-menu"
! grep -Eq '100:admin_fixture|200:rotated_fixture' "$fixture/user-menu" "$fixture/admin-menu"
grep -q '设置用户查询 Bot Token（本服务器用户共用）' "$fixture/user-menu"
! grep -Eq '不占用入站端口|设置独立用户' "$fixture/user-menu"
echo 'PASS admin and user menus do not display tokens'

# Isolated service-state model; no live init files or services are touched.
_tg_user_bot_manager() { echo systemd; }
_tg_user_bot_service_file() { echo "$fixture/bot.service"; }
readlink() { echo "$fixture/worker"; }
printf '#!/bin/bash\nexit 0\n' > "$fixture/worker"
chmod +x "$fixture/worker"
get_bash_interpreter() { echo /bin/bash; }
remove_cron_entry() { [[ ! -f "$fixture/cron-fail" ]] && { rm -f "$fixture/old-cron"; return 0; }; return 1; }
tg_user_bot_service_action() {
    echo "$1" >> "$fixture/service-actions"
    case "$1" in
        active) [[ -f "$fixture/running" && ! -f "$fixture/health-fail" ]] ;;
        enabled) [[ -f "$fixture/enabled" ]] ;;
        start|restart) [[ ! -f "$fixture/start-fail" ]] && touch "$fixture/running" ;;
        stop) [[ ! -f "$fixture/stop-fail" ]] && rm -f "$fixture/running" ;;
        enable) touch "$fixture/enabled" ;;
        disable) [[ ! -f "$fixture/disable-fail" ]] && rm -f "$fixture/enabled" ;;
        reload) return 0 ;;
    esac
}
touch "$fixture/old-cron"
setup_tg_user_bot_service true
[[ -f "$fixture/running" && -f "$fixture/enabled" && ! -f "$fixture/old-cron" ]]
grep -q -- '--tg-bot-run' "$fixture/bot.service"
! grep -Eq '100:admin_fixture|200:rotated_fixture' "$fixture/bot.service"
cp "$fixture/bot.service" "$fixture/old-service"
touch "$fixture/cron-fail" "$fixture/old-cron"
if setup_tg_user_bot_service true; then exit 1; fi
cmp "$fixture/bot.service" "$fixture/old-service"
[[ -f "$fixture/running" && -f "$fixture/enabled" && -f "$fixture/old-cron" ]]
rm "$fixture/cron-fail"
for failure in stop-fail disable-fail cron-fail; do
    touch "$fixture/$failure"
    cp "$TG_CONFIG_FILE" "$fixture/before-disable"
    if tg_set_user_bot_enabled false; then exit 1; fi
    cmp "$TG_CONFIG_FILE" "$fixture/before-disable"
    [[ -f "$fixture/running" && -f "$fixture/enabled" && -f "$fixture/old-cron" ]]
    rm "$fixture/$failure"
done
stop_tg_user_bot_service
[[ ! -f "$fixture/running" && ! -f "$fixture/enabled" && ! -f "$fixture/old-cron" ]]
printf 'old service\n' > "$fixture/bot.service"
cp "$fixture/bot.service" "$fixture/old-service"
touch "$fixture/start-fail" "$fixture/old-cron"
if setup_tg_user_bot_service true; then exit 1; fi
cmp "$fixture/bot.service" "$fixture/old-service"
[[ ! -f "$fixture/running" && ! -f "$fixture/enabled" && -f "$fixture/old-cron" ]]
rm "$fixture/start-fail"
touch "$fixture/health-fail"
if setup_tg_user_bot_service true; then exit 1; fi
cmp "$fixture/bot.service" "$fixture/old-service"
[[ ! -f "$fixture/running" && ! -f "$fixture/enabled" && -f "$fixture/old-cron" ]]
rm "$fixture/health-fail"
touch "$fixture/start-fail"
tg_set_config user_bot_enabled false
cp "$TG_CONFIG_FILE" "$fixture/before-enable"
if tg_set_user_bot_enabled true; then exit 1; fi
cmp "$TG_CONFIG_FILE" "$fixture/before-enable"
rm "$fixture/start-fail"
_tg_write_user_bot_service openrc "$fixture/bot-openrc" /usr/local/bin/vless-server.sh /bin/bash
sh -n "$fixture/bot-openrc"
grep -q 'supervisor="supervise-daemon"' "$fixture/bot-openrc"
echo 'PASS service migration/stop, start/health/stop/disable/cron failure rollback, no half-enabled config and OpenRC service syntax'

tg_set_config enabled true
tg_set_config notify_daily true
tg_set_config daily_report_hour 9
tg_set_config daily_report_minute 58
date() { case "$1" in +%H) echo 10 ;; +%M) echo 03 ;; +%Y-%m-%d) echo 2026-10-14 ;; *) command date "$@" ;; esac; }
tg_send_daily_report() { return 1; }
check_daily_report
[[ -z $(tg_get_config last_report_date) ]]
tg_send_daily_report() { return 0; }
check_daily_report
[[ $(tg_get_config last_report_date) == 2026-10-14 ]]
echo 'PASS long messages split safely; failed or delayed daily report retries across the hour'
