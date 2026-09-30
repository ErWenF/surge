#!/usr/bin/env bash
# Date simulation and service mocks operate only on a private database fixture.
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
fixture_date=2026-01-15
date() {
    case "$1" in
        +%F|+%Y-%m-%d) echo "$fixture_date" ;;
        +%Y-%m) echo "${fixture_date:0:7}" ;;
        +%d) echo "${fixture_date:8:2}" ;;
        *) command date "$@" ;;
    esac
}
_flush_core_traffic() { [[ ! -f "$fixture/fail-stats" ]]; }
traffic_cron_entry_exists() { [[ -f "$fixture/cron" ]]; }
cron_service_is_active() { [[ -f "$fixture/cron-active" ]]; }
setup_traffic_cron() {
    [[ ! -f "$fixture/fail-cron" ]] || return 1
    printf '%s\n' "$1" >> "$fixture/cron-changes"
    touch "$fixture/cron" "$fixture/cron-active"
}
is_standalone_protocol() { return 1; }
generate_xray_config() { jq '{inbounds:[.xray.trojan[] | {tag:("trojan-in-" + (.port | tostring)),settings:{clients:.users}}],outbounds:[]}' "$DB_FILE" > "$XRAY_CONFIG_OUTPUT"; }
generate_singbox_config() { jq '{inbounds:[.singbox.hy2 | {tag:("hy2-in-" + (.port | tostring)),users:.users}],outbounds:[]}' "$DB_FILE" > "$SINGBOX_CONFIG_OUTPUT"; }
printf '#!/usr/bin/env bash\n[[ ! -f "$FAIL_CHECK_FILE" ]] && jq empty "${@: -1}"\n' > "$fixture/check.sh"
chmod +x "$fixture/check.sh"
XRAY_BIN="$fixture/check.sh"
SINGBOX_BIN="$fixture/check.sh"
FAIL_CHECK_FILE="$fixture/fail-check"
export FAIL_CHECK_FILE
svc() {
    echo "$1 $2" >> "$fixture/events"
    case "$1" in
        status) [[ -f "$fixture/$2.running" ]] ;;
        is-enabled) [[ -f "$fixture/$2.enabled" ]] ;;
        enable) touch "$fixture/$2.enabled" ;;
        disable) rm -f "$fixture/$2.enabled" ;;
        stop) rm -f "$fixture/$2.running" ;;
        start|restart)
            if [[ -f "$fixture/fail-restart" ]]; then rm "$fixture/fail-restart"; return 1; fi
            touch "$fixture/$2.running" ;;
        *) return 1 ;;
    esac
}
_db_apply '.xray.trojan=[
    {port:11111,password:"master",routing:"port-route",users:[
        {name:"alice",uuid:"alice-pass",used:123,quota:500,enabled:true,created:"2026-01-01",routing:"user-route",telegram_chat_id:"123",custom:"keep"},
        {name:"old",uuid:"old-pass",used:45,quota:70,enabled:true,created:"2025-01-01"}]},
    {port:22222,password:"other",users:[{name:"bob",uuid:"bob-pass",used:678,quota:900,enabled:true,created:"2026-01-15"}]}] |
    .singbox.hy2={port:33333,password:"hy2",users:[{name:"carol",uuid:"carol-pass",used:82,quota:99,enabled:true,created:"2026-01-02"}]} |
    .custom={keep:true}'
cp "$DB_FILE" "$fixture/original"
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/original"
[[ ! -f "$fixture/events" && ! -f "$fixture/cron-changes" ]]
touch "$fixture/fail-cron"
if db_set_user_traffic_cycle xray trojan alice 30; then exit 1; fi
cmp "$DB_FILE" "$fixture/original"
rm "$fixture/fail-cron"
db_set_user_traffic_cycle xray trojan alice 30
[[ $(wc -l < "$fixture/cron-changes") == 1 ]]
cmp <(jq 'del(.meta.updated,.xray.trojan[0].users[0].traffic_reset)' "$DB_FILE") <(jq 'del(.meta.updated)' "$fixture/original")
db_set_user_traffic_cycle xray trojan bob 30
db_set_user_traffic_cycle singbox hy2 carol 30
[[ $(wc -l < "$fixture/cron-changes") == 1 ]]
[[ ! -f "$fixture/events" ]]
echo 'PASS opt-in preserves legacy database, traffic, credentials, routing, bindings, quota and existing cron interval'

# Invalid and missing opening dates fail without changing the database or cron.
for bad in '' 2026-02-30 2026-01-32 2026-02-01 garbage 2026-1-1; do
    cp "$DB_FILE" "$fixture/before"
    if db_set_user_traffic_cycle xray trojan old 30 "$bad" && [[ -n "$bad" ]]; then exit 1; fi
    # Empty anchor intentionally falls back to old.created; undo only that enrollment.
    if [[ -z "$bad" ]]; then db_set_user_traffic_cycle xray trojan old 0; else
        cmp "$DB_FILE" "$fixture/before"
    fi
done
_db_apply '.xray.trojan[0].users[1] |= del(.created)'
cp "$DB_FILE" "$fixture/before"
if db_set_user_traffic_cycle xray trojan old 30; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
db_set_user_traffic_cycle xray trojan old 30 2025-01-01
jq -e '.xray.trojan[0].users[1] | .used == 45 and .traffic_reset.last_period == 12' "$DB_FILE" >/dev/null
db_set_user_traffic_cycle xray trojan old 0

[[ $(_traffic_cycle_period 2024-02-01 2024-03-01) == 0 ]]
[[ $(_traffic_cycle_period 2024-02-01 2024-03-02) == 1 ]]
[[ $(_traffic_cycle_period 2025-12-15 2026-01-14) == 1 ]]
[[ $(_traffic_cycle_period 2026-01-01 2026-03-02) == 2 ]]
echo 'PASS strict dates, missing-date enrollment, leap day, year boundary and 30-day arithmetic'

fixture_date=2026-01-30
cp "$DB_FILE" "$fixture/before"
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/before"
fixture_date=2026-01-31
check_user_traffic_cycles
jq -e '.xray.trojan[0].users[0] | .used == 0 and .traffic_reset.last_period == 1' "$DB_FILE" >/dev/null
jq -e '.xray.trojan[1].users[0].used == 678 and .singbox.hy2.users[0].used == 82 and .xray.trojan[0].users[1].used == 45' "$DB_FILE" >/dev/null
[[ ! -f "$fixture/events" && ! -f "$TRAFFIC_MONTHLY_RESET_LAST_FILE" ]]
_db_apply '.xray.trojan[0].users[0].used=7'
cp "$DB_FILE" "$fixture/before"
db_set_user_traffic_cycle xray trojan alice 30
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/before"
fixture_date=2026-02-01
check_user_traffic_cycles
jq -e '.singbox.hy2.users[0].used == 0 and .xray.trojan[0].users[0].used == 7 and .xray.trojan[1].users[0].used == 678' "$DB_FILE" >/dev/null
fixture_date=2026-04-05
check_user_traffic_cycles
jq -e '.xray.trojan[0].users[0].traffic_reset.last_period == 3 and .xray.trojan[1].users[0].traffic_reset.last_period == 2' "$DB_FILE" >/dev/null
_db_apply '.xray.trojan[0].users[0].used=19 | .singbox.hy2.users[0].used=23'
cp "$DB_FILE" "$fixture/before"
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/before"
[[ $(_traffic_cycle_display "$(db_get_user xray trojan alice)") == '30天 / 下次 2026-05-01' ]]
reset_monthly_user_traffic
jq -e '.xray.trojan[0].users[0].used == 19 and .singbox.hy2.users[0].used == 23 and .xray.trojan[0].users[1].used == 0' "$DB_FILE" >/dev/null
echo 'PASS independent users, exact boundary, repeat polling, missed cycles, next-date display and monthly exclusion'

# Due quota users resume; manual/expired users remain disabled. Stopped cores stay stopped.
_db_apply '.xray.trojan[0].users += [
    {name:"manual",uuid:"manual",quota:100,used:110,enabled:false,disabled_reason:"manual",traffic_reset:{days:30,anchor:"2026-01-01",last_period:0}},
    {name:"expired",uuid:"expired",quota:100,used:110,enabled:false,disabled_reason:"quota",expire_date:"2026-03-01",traffic_reset:{days:30,anchor:"2026-01-01",last_period:0}}] |
    .xray.trojan[0].users[0] |= (.enabled=false | .disabled_reason="quota" | .used=600 | .traffic_reset.last_period=0 | .last_alert_percent=95 | .quota_exceeded_notified=true) |
    .singbox.hy2.users[0] |= (.enabled=false | .disabled_reason="quota" | .traffic_reset.last_period=0)'
printf '%s\n' '{"inbounds":[],"old":true}' > "$CFG/config.json"
printf '%s\n' '{"inbounds":[],"old":true}' > "$CFG/singbox.json"
touch "$fixture/vless-reality.running"
cp "$DB_FILE" "$fixture/before"
cp "$CFG/config.json" "$fixture/before-xray"
cp "$CFG/singbox.json" "$fixture/before-singbox"
touch "$fixture/fail-stats"
if check_user_traffic_cycles; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
rm "$fixture/fail-stats"
touch "$fixture/fail-check"
if check_user_traffic_cycles; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
cmp "$CFG/config.json" "$fixture/before-xray"
cmp "$CFG/singbox.json" "$fixture/before-singbox"
rm "$fixture/fail-check"
touch "$fixture/fail-restart"
if check_user_traffic_cycles; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
cmp "$CFG/config.json" "$fixture/before-xray"
check_user_traffic_cycles
jq -e '.xray.trojan[0].users[0] | .enabled == true and .used == 0 and .last_alert_percent == null and .quota_exceeded_notified == null' "$DB_FILE" >/dev/null
jq -e '.xray.trojan[0].users | all(.[] | select(.name == "manual" or .name == "expired"); .enabled == false and .used == 0)' "$DB_FILE" >/dev/null
jq -e '.singbox.hy2.users[0] | .enabled == true and .used == 0' "$DB_FILE" >/dev/null
[[ ! -f "$fixture/vless-singbox.running" ]]
echo 'PASS quota-only resume, manual/expiry preservation, stopped-core preservation and failed stats/config/restart rollback'

# The second core fails after Xray has applied. Preserve sibling bytes captured
# during candidate validation in the shared rollback database as well.
_db_apply '.xray.trojan[0].users[0] |= (.enabled=false | .disabled_reason="quota" | .used=600 | .traffic_reset.last_period=0) |
    .singbox.hy2.users[0] |= (.enabled=false | .disabled_reason="quota" | .traffic_reset.last_period=0)'
cp "$DB_FILE" "$fixture/before"
cp "$CFG/config.json" "$fixture/before-xray"
cp "$CFG/singbox.json" "$fixture/before-singbox"
_flush_core_traffic() {
    local core="$1" target staged
    [[ "$core" == xray && $# -gt 2 ]] || return 0
    shift 2
    for target in "$@" "$DB_FILE"; do
        staged=$(mktemp "$target.late.XXXXXX")
        jq '.xray.trojan[0].users[1].used += 11' "$target" > "$staged"
        mv "$staged" "$target"
    done
}
eval "$(declare -f generate_singbox_config | sed '1s/generate_singbox_config/_real_generate_singbox_config/')"
generate_singbox_config() { return 1; }
if check_user_traffic_cycles; then exit 1; fi
cmp <(jq 'del(.meta.updated)' "$DB_FILE") <(jq 'del(.meta.updated) | .xray.trojan[0].users[1].used += 11' "$fixture/before")
cmp "$CFG/config.json" "$fixture/before-xray"
cmp "$CFG/singbox.json" "$fixture/before-singbox"
_flush_core_traffic() { :; }
generate_singbox_config() { _real_generate_singbox_config; }
check_user_traffic_cycles
echo 'PASS second-core failure restores both configs and cycle markers without dropping late sibling traffic'

# Invalid cycle records never clear usage or fall back to monthly reset.
_db_apply '.xray.trojan[0].users += [
    {name:"bad-date",used:90,traffic_reset:{days:30,anchor:"2026-02-30",last_period:0}},
    {name:"bad-marker",used:91,traffic_reset:{days:30,anchor:"2026-01-01",last_period:-1}},
    {name:"missing-date",used:92,traffic_reset:{days:30,last_period:0}}]'
cp "$DB_FILE" "$fixture/before"
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/before"
reset_monthly_user_traffic
jq -e '.xray.trojan[0].users | all(.[] | select(.name == "bad-date" or .name == "bad-marker" or .name == "missing-date"); .used >= 90)' "$DB_FILE" >/dev/null
db_reset_user_traffic xray trojan alice
jq -e '.xray.trojan[0].users[0].traffic_reset | .anchor == "2026-01-01" and .last_period == 3' "$DB_FILE" >/dev/null
echo 'PASS invalid records retain traffic and manual reset retains the opening-date schedule'

# Existing API calls retain their default; opt-in metadata belongs only to the new user.
db_add_user xray trojan new-old new-pass 1 '' 11111
db_add_user xray trojan new-cycle cycle-pass 1 '' 11111 '' false 30
jq -e '.xray.trojan[0].users | any(.name == "new-old" and .traffic_reset == null) and any(.name == "new-cycle" and .traffic_reset.anchor == "2026-04-05" and .traffic_reset.last_period == 0)' "$DB_FILE" >/dev/null
cp "$DB_FILE" "$fixture/before"
touch "$fixture/fail-check"
if db_add_user xray trojan failed-cycle failed-pass 1 '' 11111 '' false 30; then exit 1; fi
cmp "$DB_FILE" "$fixture/before"
rm "$fixture/fail-check"
echo 'PASS new-user opt-in, backward-compatible API default and failed creation rollback'
