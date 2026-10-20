#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
init_tg_config
_flush_core_traffic() { :; }
_user_change_begin() { echo "$fixture"; }
_user_change_apply() { echo apply >> "$fixture/applies"; }
_core_traffic_epoch() { echo test-epoch; }
_pgrep() { [[ "$1" == "$active_core" || "$active_core:$1" == singbox:sing-box ]]; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
tg_send_over_quota() { echo notice >> "$fixture/notices"; [[ "$notice_ok" == true ]]; }
xray() { printf '{"stat":[{"name":"user>>>alice@trojan>>>traffic>>>uplink","value":%s}]}' "$counter"; }
singbox_stats_available() { :; }
singbox_api_query() { printf 'user>>>trojan-alice>>>traffic>>>uplink %s\n' "$counter"; }
for active_core in xray singbox; do
    _db_apply --arg c "$active_core" '.xray={} | .singbox={} |
        .meta.traffic_checkpoints={} |
        .[$c].trojan={port:24400,uuid:"master",users:[{name:"alice",uuid:"key",quota:100,used:120,
        enabled:false,disabled_reason:"quota",last_alert_percent:95,quota_exceeded_notified:true}]}'
    db_reset_user_traffic "$active_core" trojan alice
    [[ $(db_get_user_alert_state "$active_core" trojan alice quota_exceeded_notified) != true ]]
    db_set_user_enabled "$active_core" trojan alice true
    # Even an old/stale true marker cannot exempt an enabled user from quota.
    _db_apply --arg c "$active_core" '.[$c].trojan.users[0].quota_exceeded_notified=true'
    counter=120 notice_ok=true
    : > "$fixture/notices"
    sync_all_user_traffic false
    [[ $(db_get_user_field "$active_core" trojan alice enabled) == false ]]
    [[ $(db_get_user_field "$active_core" trojan alice disabled_reason) == quota ]]
    [[ ! -s "$fixture/notices" ]]
    # New accounting cycle: one failed notice, one successful retry, no repeat apply/send.
    db_reset_user_traffic "$active_core" trojan alice
    db_set_user_enabled "$active_core" trojan alice true
    counter=240 notice_ok=false
    sync_all_user_traffic false
    [[ $(db_get_user_field "$active_core" trojan alice enabled) == false ]]
    [[ $(db_get_user_alert_state "$active_core" trojan alice quota_exceeded_notified) != true ]]
    count_before=$(wc -l < "$fixture/applies")
    notice_ok=true
    sync_all_user_traffic false
    sync_all_user_traffic false
    [[ $(wc -l < "$fixture/applies") == "$count_before" ]]
    [[ $(wc -l < "$fixture/notices") == 2 ]]
    [[ $(db_get_user_alert_state "$active_core" trojan alice quota_exceeded_notified) == true ]]
done
echo 'PASS Xray/Sing-box enforce quota with stale notification flags and retry delivery without repeated core changes'
