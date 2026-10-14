#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_ensure_singbox_default_users() { :; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
_core_traffic_epoch() { echo test; }
_pgrep() { [[ "$1" == xray && "$core" == xray || "$1" == sing-box && "$core" == singbox ]]; }
xray() { echo '{"stat":[{"name":"user>>>alice@vless>>>traffic>>>uplink","value":1}]}'; }
singbox_stats_available() { return 0; }
singbox_api_query() { echo 'user>>>trojan-alice>>>traffic>>>uplink 1'; }
tg_get_config() { echo 80; }
tg_send_quota_alert() { echo alert >> "$fixture/deliveries"; [[ "$delivery" == ok ]]; }
tg_send_over_quota() { echo exceeded >> "$fixture/deliveries"; [[ "$delivery" == ok ]]; }
db_set_user_enabled() {
    echo disabled >> "$fixture/changes"
    _db_apply --arg c "$1" --arg p "$2" --arg n "$3" --arg reason "$5" '
        .[$c][$p].users |= map(if .name == $n then .enabled=false | .disabled_reason=$reason else . end)'
}

for core in xray singbox; do
    fixture_proto=vless; [[ "$core" != singbox ]] || fixture_proto=trojan
    _db_apply --arg c "$core" --arg p "$fixture_proto" '.xray={} | .singbox={} | .meta={} |
        .[$c][$p]={port:11111,users:[{name:"alice",uuid:"fixture",used:79,quota:100,enabled:true}]}'
    delivery=failed
    _sync_all_user_traffic_unlocked false
    [[ $(db_get_user_field "$core" "$fixture_proto" alice used) == 80 ]]
    [[ -z $(db_get_user_alert_state "$core" "$fixture_proto" alice last_alert_percent) ]]
    delivery=ok
    _sync_all_user_traffic_unlocked false
    [[ $(db_get_user_alert_state "$core" "$fixture_proto" alice last_alert_percent) == 80 ]]
    _db_apply --arg c "$core" --arg p "$fixture_proto" '.[$c][$p].users[0].used=100'
    delivery=failed
    _sync_all_user_traffic_unlocked false
    [[ $(db_get_user_field "$core" "$fixture_proto" alice enabled) == false ]]
    [[ $(db_get_user_alert_state "$core" "$fixture_proto" alice quota_exceeded_notified) != true ]]
    # API counters can disappear after disabling the last user. Retry from saved state.
    before=$(wc -l < "$fixture/changes")
    delivery=ok
    _tg_retry_quota_notices
    [[ $(db_get_user_alert_state "$core" "$fixture_proto" alice quota_exceeded_notified) == true ]]
    [[ $(wc -l < "$fixture/changes") == "$before" ]]
    before=$(wc -l < "$fixture/deliveries")
    _tg_retry_quota_notices
    [[ $(wc -l < "$fixture/deliveries") == "$before" ]]
done
echo 'PASS Xray/Sing-box alert delivery failures remain retryable; quota enforcement unchanged and no duplicate disabling'

_db_apply '.xray={"snell-v6":[{port:33333,users:[{name:"snell",used:100,quota:100,enabled:false,disabled_reason:"quota"}]}]} | .singbox={} '
delivery=failed
_tg_retry_quota_notices
[[ $(db_get_user_alert_state xray snell-v6 snell quota_exceeded_notified) != true ]]
delivery=ok
_tg_retry_quota_notices
[[ $(db_get_user_alert_state xray snell-v6 snell quota_exceeded_notified) == true ]]
_db_apply '.xray["snell-v6"][0].users[0] |= (.disabled_reason="manual" | del(.quota_exceeded_notified))'
before=$(wc -l < "$fixture/deliveries")
_tg_retry_quota_notices
[[ $(wc -l < "$fixture/deliveries") == "$before" ]]
echo 'PASS Snell pending notice retries from saved state and manual stops do not produce quota notices'
