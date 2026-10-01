#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT

backend=${FLOCK_TEST_BACKEND:-native}
if [[ "$backend" == busybox ]]; then
    mkdir -p "$fixture/bin"
    for applet in flock sleep mktemp; do
        ln -s "$(command -v busybox)" "$fixture/bin/$applet"
    done
    PATH="$fixture/bin:$PATH"
fi
ensure_flock
if [[ "$backend" == busybox ]]; then
    [[ "$_FLOCK_HAS_WAIT" == false ]]
else
    [[ "$_FLOCK_HAS_WAIT" == true ]]
fi
echo "PASS $backend capability detection"

# An uncontended acquisition and repeated probes must keep the real lock held.
exec {fd}>"$fixture/free.lock"
flock_wait 0 "$fd"
_FLOCK_CHECKED_BIN=""
ensure_flock
exec {other}>"$fixture/free.lock"
rc=0
flock_wait 0 "$other" || rc=$?
[[ "$rc" == 1 ]]
flock_unlock "$fd"
flock_wait 0 "$other"
flock_unlock "$other"
exec {fd}>&-
exec {other}>&-
echo 'PASS immediate acquisition, zero timeout, probe isolation and unlock'

hold_lock() {
    local name="$1" duration="$2" held
    exec {held}>"$fixture/$name.lock"
    flock_wait "" "$held"
    touch "$fixture/$name.ready"
    sleep "$duration"
}
wait_ready() {
    local i
    for ((i=0; i<200; i++)); do
        [[ ! -f "$fixture/$1.ready" ]] || return 0
        sleep 0.01
    done
    return 1
}

hold_lock released 0.6 & holder=$!
wait_ready released
exec {fd}>"$fixture/released.lock"
start=$SECONDS
flock_wait 3 "$fd"
(( SECONDS - start < 3 ))
wait "$holder"
flock_unlock "$fd"
exec {fd}>&-
echo 'PASS contended lock is acquired after its holder releases'

hold_lock timeout 4 & holder=$!
wait_ready timeout
exec {fd}>"$fixture/timeout.lock"
start=$SECONDS
rc=0
flock_wait 2 "$fd" 2>"$fixture/timeout.err" || rc=$?
elapsed=$((SECONDS - start))
[[ "$rc" == 1 && ! -s "$fixture/timeout.err" ]]
(( elapsed >= 1 && elapsed <= 3 ))
wait "$holder"
flock_wait 0 "$fd"
flock_unlock "$fd"
exec {fd}>&-
echo "PASS contention returns failure after bounded timeout (${elapsed}s) without option errors"

# Installation failure must leave the BusyBox backend usable and only try once.
apk() { printf '%s\n' "$*" >>"$fixture/apk.calls"; return 1; }
ensure_flock install
ensure_flock install
if [[ "$backend" == busybox ]]; then
    [[ $(wc -l <"$fixture/apk.calls") == 1 ]]
    grep -qx 'add --no-cache cmd:flock' "$fixture/apk.calls"
    [[ "$_FLOCK_HAS_WAIT" == false ]]
else
    [[ ! -f "$fixture/apk.calls" ]]
fi
unset -f apk
echo 'PASS optional provider installation failure preserves the lock backend'

init_db
_db_lock_acquire
_db_lock_acquire
[[ "$DB_LOCK_DEPTH" == 2 ]]
_db_lock_release
[[ "$DB_LOCK_DEPTH" == 1 ]]
_db_lock_release
[[ -z "$DB_LOCK_FD" ]]
echo 'PASS nested database locks retain their blocking and release semantics'

fail_body() { return 9; }
rc=0
_with_named_lock compat fail_body || rc=$?
[[ "$rc" == 9 ]]
_with_named_lock compat _with_named_lock compat true
echo 'PASS named locks preserve command status, release and reentrancy'

# Exercise the unchanged production timeout, rather than only a shorter unit case.
(
    exec {held}>"$CFG/.compat.lock"
    flock_wait "" "$held"
    touch "$fixture/named.ready"
    sleep 32
) & holder=$!
wait_ready named
start=$SECONDS
rc=0
_with_named_lock compat touch "$fixture/should-not-run" 2>"$fixture/named.err" || rc=$?
elapsed=$((SECONDS - start))
[[ "$rc" == 1 && ! -e "$fixture/should-not-run" ]]
(( elapsed >= 29 && elapsed <= 31 ))
grep -q '等待 compat 锁超时' "$fixture/named.err"
! grep -q 'unrecognized option' "$fixture/named.err"
wait "$holder"
_with_named_lock compat touch "$fixture/after-timeout"
[[ -f "$fixture/after-timeout" ]]
echo "PASS production named lock waits 30s, fails safely and is reusable (${elapsed}s)"
