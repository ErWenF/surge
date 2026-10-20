#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
original_ensure=$(declare -f ensure_expire_check_cron)
_flush_core_traffic() { echo flush >> "$fixture/actions"; }
_user_change_begin() { echo "$fixture"; }
_user_change_apply() { echo apply >> "$fixture/actions"; }
ensure_expire_check_cron() { echo cron >> "$fixture/actions"; return "${cron_result:-0}"; }
assert_same() { cmp "$DB_FILE" "$fixture/before"; }
for core in xray singbox; do
    for shape in object array; do
        _db_apply --arg c "$core" --arg shape "$shape" '
            {port:24400,uuid:"master",users:[{name:"alice",uuid:"alice-key",used:120,quota:100,
                enabled:false,disabled_reason:"manual",expire_date:"2030-01-01",routing:"chain:exit",
                last_alert_percent:95,quota_exceeded_notified:true,telegram_chat_id:"123",
                traffic_reset:{days:30,anchor:"2026-10-01",last_period:0}}]} as $p |
            .[$c].trojan = (if $shape == "array" then [$p] else $p end)'
        for value in 08 010 000 8388607; do
            db_set_user_quota "$core" trojan alice "$value"
            [[ $(db_get_user_field "$core" trojan alice quota) == "$((10#$value * 1073741824))" ]]
        done
        for value in -1 +1 1.5 NaN 8388608 999999999999999999999999999 ''; do
            cp "$DB_FILE" "$fixture/before"
            if db_set_user_quota "$core" trojan alice "$value" 2>/dev/null; then exit 1; fi
            assert_same
        done
        for value in 2026-13-40 2026-02-29 2024-02-30 2026-04-31 0000-01-01 2030-1-01 garbage; do
            cp "$DB_FILE" "$fixture/before"
            if db_set_user_expire_date "$core" trojan alice "$value" 2>/dev/null; then exit 1; fi
            assert_same
        done
        for cron_result in 0 1; do
            db_set_user_expire_date "$core" trojan alice 2028-02-29
            [[ $(db_get_user_expire_date "$core" trojan alice) == 2028-02-29 ]]
        done
        cron_result=2
        cp "$DB_FILE" "$fixture/before"
        if db_set_user_expire_date "$core" trojan alice 2030-01-02 2>/dev/null; then exit 1; fi
        assert_same
        : > "$fixture/actions"
        for value in '' never; do
            db_set_user_expire_date "$core" trojan alice "$value"
            [[ -z $(db_get_user_expire_date "$core" trojan alice) ]]
        done
        [[ ! -s "$fixture/actions" ]]
        for failure in quota date cron; do
            quota=08 expiry=2030-01-01 cron_result=0
            case "$failure" in quota) quota=8388608 ;; date) expiry=2026-02-29 ;; cron) cron_result=2 ;; esac
            cp "$DB_FILE" "$fixture/before"
            : > "$fixture/actions"
            if db_add_user "$core" trojan rejected key "$quota" "$expiry" 24400 2>/dev/null; then exit 1; fi
            assert_same
            ! grep -Eq 'flush|apply' "$fixture/actions"
        done
        cron_result=1
        db_add_user "$core" trojan bob bob-key 010 2030-01-01 24400
        [[ $(db_get_user_field "$core" trojan bob quota) == 10737418240 ]]
        [[ $(db_get_user_expire_date "$core" trojan bob) == 2030-01-01 ]]
        db_reset_user_traffic "$core" trojan alice
        jq -e --arg c "$core" '.[$c].trojan | (if type == "array" then .[0] else . end).users[] |
            select(.name == "alice") | .used == 0 and .enabled == false and .disabled_reason == "manual" and
            .routing == "chain:exit" and .telegram_chat_id == "123" and .traffic_reset.anchor == "2026-10-01" and
            (has("last_alert_percent") | not) and (has("quota_exceeded_notified") | not)' "$DB_FILE" >/dev/null
    done
done
for value in 2028-02-29 2030-01-01; do [[ $(_parse_expire_input "$value") == "$value" ]]; done
[[ $(_parse_expire_input 030) == "$(date -d '+30 days' +%F)" ]]
for value in 2026-02-29 99999999999999999 invalid; do
    if _parse_expire_input "$value"; then exit 1; fi
done
date() { return 1; }
if _parse_expire_input 30; then exit 1; fi
unset -f date
echo 'PASS decimal quota bounds, real calendar dates, expiry prepare failures, cancellation and reset metadata preservation (both cores/object/array)'

eval "$original_ensure"
get_bash_interpreter() { echo /bin/bash; }
build_cron_command() { echo '0 3 * * * fixture --check-expire --notify # check-expire'; }
ensure_cron_service_running() { [[ ! -f "$fixture/cron-stopped" ]]; }
crontab() { [[ -f "$fixture/existing-cron" ]] && cat "$fixture/existing-cron"; }
install_cron_entry() { [[ ! -f "$fixture/cron-write-fail" ]] && printf '%s\n' "$2" > "$fixture/existing-cron"; }
rc=0; ensure_expire_check_cron >/dev/null || rc=$?; [[ "$rc" == 1 ]]
ensure_expire_check_cron >/dev/null
touch "$fixture/cron-stopped"
rc=0; ensure_expire_check_cron >/dev/null 2>&1 || rc=$?; [[ "$rc" == 2 ]]
rm "$fixture/cron-stopped" "$fixture/existing-cron"
touch "$fixture/cron-write-fail"
rc=0; ensure_expire_check_cron >/dev/null || rc=$?; [[ "$rc" == 2 ]]
echo 'PASS expiry scheduler preserves legacy result contract and rejects inactive daemon / failed installation'
