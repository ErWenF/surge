#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_tg_config
tg_set_config user_bot_enabled true
tg_bot_api_request() { echo request >> "$fixture/requests"; echo '{"ok":true,"result":[]}'; }
lock="$CFG/tg-user-bot.lock"
mkdir "$lock"
# A fresh legacy process may still be writing its PID: do not steal its lock.
rc=0; tg_poll_user_bot || rc=$?; [[ "$rc" == 75 && ! -f "$fixture/requests" ]]
touch -d '10 seconds ago' "$lock"
tg_poll_user_bot
[[ ! -d "$lock" && $(wc -l < "$fixture/requests") == 1 ]]
mkdir "$lock"; echo invalid > "$lock/pid"; touch -d '10 seconds ago' "$lock"
tg_poll_user_bot
mkdir "$lock"; echo 2147483647 > "$lock/pid"
tg_poll_user_bot
mkdir "$lock"; echo "$BASHPID" > "$lock/pid"
rc=0; tg_poll_user_bot || rc=$?; [[ "$rc" == 75 ]]
rm "$lock/pid"; rmdir "$lock"
# A stale kernel-backed record cannot block on a recycled live PID.
mkdir "$lock"; echo "$BASHPID" > "$lock/pid"; touch "$lock/kernel"
tg_poll_user_bot
# Kill a kernel-lock owner without cleanup: the lock file remains but is reusable.
(
    exec {held}>"$CFG/.tg-user-bot.poll.lock"
    flock_wait 0 "$held"
    touch "$fixture/held"
    exec sleep 60
) & holder=$!
for attempt in {1..100}; do [[ ! -f "$fixture/held" ]] || break; sleep 0.02; done
[[ -f "$fixture/held" ]]
rc=0; tg_poll_user_bot || rc=$?; [[ "$rc" == 75 ]]
kill -KILL "$holder"; wait "$holder" 2>/dev/null || true
tg_poll_user_bot
[[ -f "$CFG/.tg-user-bot.poll.lock" && ! -d "$lock" ]]
[[ $(wc -l < "$fixture/requests") == 5 ]]
echo 'PASS Telegram empty/malformed/dead-owner lock recovery, legacy initialization grace, live contention and SIGKILL release'
