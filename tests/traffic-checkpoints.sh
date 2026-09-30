#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_core_traffic_epoch() { echo "$epoch"; }
epoch=one
_db_apply '.xray.vless=[{port:11111,users:[{name:"alice",used:5}]},{port:22222,users:[{name:"bob",used:9}]}] |
    .singbox.trojan={users:[{name:"alice",used:2}]}'
raw=$'user>>>alice@vless>>>traffic>>>uplink 100\nuser>>>alice@vless>>>traffic>>>downlink 200\nuser>>>bob@vless>>>traffic>>>downlink 50'
_traffic_snapshot xray "$raw" > "$fixture/snapshot"
_commit_traffic_snapshots "$fixture/snapshot"
jq -e '.xray.vless[0].users[0].used == 305 and .xray.vless[1].users[0].used == 59' "$DB_FILE" >/dev/null
_traffic_snapshot xray "$raw" > "$fixture/snapshot"
_commit_traffic_snapshots "$fixture/snapshot"
jq -e '.xray.vless[0].users[0].used == 305' "$DB_FILE" >/dev/null
cp "$DB_FILE" "$fixture/before"
raw=$'user>>>alice@vless>>>traffic>>>uplink 120\nuser>>>alice@vless>>>traffic>>>downlink 230'
_traffic_snapshot xray "$raw" > "$fixture/snapshot"
eval "$(declare -f _db_apply | sed '1s/_db_apply/_real_db_apply/')"
_db_apply() { return 1; }
if _commit_traffic_snapshots "$fixture/snapshot"; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
_db_apply() { _real_db_apply "$@"; }
_traffic_snapshot xray "$raw" > "$fixture/snapshot"
_commit_traffic_snapshots "$fixture/snapshot"
jq -e '.xray.vless[0].users[0].used == 355' "$DB_FILE" >/dev/null
epoch=two
_traffic_snapshot xray 'user>>>alice@vless>>>traffic>>>downlink 8' > "$fixture/snapshot"
_commit_traffic_snapshots "$fixture/snapshot"
jq -e '.xray.vless[0].users[0].used == 363' "$DB_FILE" >/dev/null
_traffic_snapshot singbox 'user>>>trojan-alice>>>traffic>>>uplink 17' > "$fixture/snapshot"
_commit_traffic_snapshots "$fixture/snapshot"
jq -e '.singbox.trojan.users[0].used == 19' "$DB_FILE" >/dev/null
if _traffic_snapshot xray 'bad negative' >/dev/null 2>&1; then exit 1; fi
if _traffic_snapshot xray 'user>>>alice@vless>>>traffic>>>downlink 8' stale >/dev/null 2>&1; then exit 1; fi
if _xray_traffic_counters <<< '{"stat":[{"value":8}]}' >/dev/null 2>&1; then exit 1; fi
echo 'PASS cumulative uplink/downlink, per-port isolation, idempotence, write failure retry and core restart'

# Production sync must read without reset and propagate write failures.
_ensure_singbox_default_users() { :; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
check_monthly_traffic_reset() { :; }
_pgrep() { [[ "$1" == xray ]]; }
xray() {
    [[ "$*" != *reset* ]] || return 1
    echo '{"stat":[{"name":"user>>>alice@vless>>>traffic>>>downlink","value":20}]}'
}
tg_get_config() { echo 80; }
mark_traffic_sync_result() { echo "$1" > "$fixture/result"; }
cp "$DB_FILE" "$fixture/before"
_db_apply() { return 1; }
if sync_all_user_traffic true; then exit 1; fi
[[ $(cat "$fixture/result") == db_write_error ]]
cmp "$DB_FILE" "$fixture/before"
_db_apply() { _real_db_apply "$@"; }
sync_all_user_traffic true
sync_all_user_traffic true
jq -e '.xray.vless[0].users[0].used == 375' "$DB_FILE" >/dev/null
echo 'PASS sync write failure is retryable and repeated polling does not double-charge'
