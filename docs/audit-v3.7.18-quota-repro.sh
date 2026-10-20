#!/usr/bin/env bash
# Private counters and service mocks demonstrate the notification/enforcement coupling.
source "$(dirname "$0")/../tests/lib/core-fixture.sh" || exit 1
trap 'rm -rf "$fixture"' EXIT
init_db
init_tg_config
_db_apply '.xray.vless={port:24400,uuid:"11111111-1111-4111-8111-111111111111",users:[{name:"alice",uuid:"11111111-1111-4111-8111-111111111111",quota:100,used:120,enabled:false,disabled_reason:"quota",last_alert_percent:95,quota_exceeded_notified:true}]}'
_flush_core_traffic() { :; }
_user_change_begin() { echo "$fixture"; }
_user_change_apply() { echo apply >> "$fixture/applies"; }
_core_traffic_epoch() { echo test-epoch; }
_pgrep() { [[ "$1" == xray ]]; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
tg_send_over_quota() { :; }
xray() { echo '{"stat":[{"name":"user>>>alice@vless>>>traffic>>>uplink","value":120}]}'; }
db_reset_user_traffic xray vless alice
db_set_user_enabled xray vless alice true
sync_all_user_traffic false
printf 'after manual reset + enable + new traffic over quota: '
jq -c '.xray.vless.users[0] | {used,quota,enabled,disabled_reason,quota_exceeded_notified}' "$DB_FILE"
_db_apply '.xray.vless.users[0] |= del(.quota_exceeded_notified)'
sync_all_user_traffic false
printf 'control, same user after clearing only notification flag: '
jq -c '.xray.vless.users[0] | {used,quota,enabled,disabled_reason,quota_exceeded_notified}' "$DB_FILE"