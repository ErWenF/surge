#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
transaction() {
    cp "$DB_FILE" "$fixture/before"
    _db_apply '.temporary=true'
    touch "$fixture/locked"
    sleep 0.4
    _restore_db_backup "$fixture/before"
}
run_concurrent_case() {
    rm -f "$fixture/locked"
    _with_db_lock transaction &
    local first=$!
    for ((i=0; i<100; i++)); do [[ ! -f "$fixture/locked" ]] || break; sleep 0.02; done
    [[ -f "$fixture/locked" ]]
    _db_apply '.concurrent=true' &
    local second=$!
    wait "$first"
    wait "$second"
    jq -e '.concurrent == true and .temporary == null' "$DB_FILE" >/dev/null
}
run_concurrent_case
echo 'PASS concurrent write waits for transaction rollback and remains in database'
command() {
    if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
    builtin command "$@"
}
run_concurrent_case
[[ ! -d "$CFG/.db.lock.d" ]]
echo 'PASS mkdir lock fallback releases after nested writes and rollback'
fail_transaction() { _db_apply '.after_failure=true'; return 9; }
rc=0
_with_db_lock fail_transaction || rc=$?
[[ "$rc" == 9 && ! -d "$CFG/.db.lock.d" ]]
_db_apply '.lock_reusable=true'
echo 'PASS failed transaction preserves exit status and leaves reusable lock'
