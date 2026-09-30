#!/usr/bin/env bash
set -e
if [[ -z "${SNELL_TEST_BIN:-}" ]]; then echo 'SKIP native Snell edit (SNELL_TEST_BIN unset)'; exit 0; fi
if [[ "${1:-}" != namespace ]]; then exec unshare --net bash "$0" namespace; fi
ip link set lo up
source "$(dirname "$0")/lib/core-fixture.sh"
id=fc0000000000000000000001
service="vless-snellu-$id"
trap 'if [[ -f "$fixture/pid" ]]; then kill "$(cat "$fixture/pid")" 2>/dev/null || true; fi; rm -rf "$fixture"' EXIT
init_db
DISTRO=debian
USER_CHANGE_HEALTH_DELAY=0.2
_listen_addr() { echo 127.0.0.1; }
_snell_write_service() { [[ ! -f "$fixture/fail-unit" ]]; }
_snell_user_share() { :; }
_snell_binary() { echo "$SNELL_TEST_BIN"; }
svc() {
    local pid
    case "$1" in
        status) [[ -f "$fixture/pid" ]] && kill -0 "$(cat "$fixture/pid")" 2>/dev/null ;;
        is-enabled) [[ -f "$fixture/enabled" ]] ;;
        enable) touch "$fixture/enabled" ;;
        disable) rm -f "$fixture/enabled" ;;
        start)
            [[ ! -f "$fixture/fail-cycle-start" ]] || return 1
            "$SNELL_TEST_BIN" -c "$CFG/snell-users/$id.conf" > "$fixture/snell.log" 2>&1 &
            printf '%s\n' "$!" > "$fixture/pid"
            ;;
        stop)
            if [[ -f "$fixture/pid" ]]; then
                pid=$(cat "$fixture/pid")
                kill "$pid" 2>/dev/null || true
                for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
                wait "$pid" 2>/dev/null || true
                if kill -0 "$pid" 2>/dev/null; then return 1; fi
                rm -f "$fixture/pid"
            fi
            ;;
        *) return 1 ;;
    esac
}
mkdir -p "$CFG/snell-users"
_snell_nft_ready
_snell_counter_prepare "$id" 32151
for runtime in stopped running; do
    _db_apply --arg id "$id" '.xray["snell-v5"]=[{snell_id:$id,port:32151,psk:"oldpassword",users:[{name:"alice",used:0,quota:0,enabled:true}]}] | .meta.snell_users["snell-v5"]=true'
    printf '[snell-server]\nlisten = 127.0.0.1:32151\npsk = oldpassword\nipv6 = true\n' > "$CFG/snell-users/$id.conf"
    [[ "$runtime" != running ]] || { svc start "$service"; sleep .3; svc status "$service"; }
    row=$(_snell_rows snell-v5)
    _snell_edit_user_commit snell-v5 alice "$row" 32152 newpassword system ''
    if [[ "$runtime" == running ]]; then
        svc status "$service"
        ss -H -lnt '( sport = :32152 )' | grep -q .
        ! ss -H -lnt '( sport = :32151 )' | grep -q .
    else
        ! svc status "$service"
        ! ss -H -lnt '( sport = :32152 )' | grep -q .
    fi
    ! svc is-enabled "$service"
    row=$(_snell_rows snell-v5)
    touch "$fixture/fail-unit"
    if _snell_edit_user_commit snell-v5 alice "$row" 32153 brokenpassword '' ''; then exit 1; fi
    rm "$fixture/fail-unit"
    [[ $(jq -r '.xray["snell-v5"][0].port' "$DB_FILE") == 32152 ]]
    if [[ "$runtime" == running ]]; then svc status "$service"; ss -H -lnt '( sport = :32152 )' | grep -q .
    else ! svc status "$service"; fi
    nft -j list chain inet vless_snell_users input | jq -e --arg id "$id" \
        'any(.nftables[].rule?; .comment == $id and any(.expr[]?.match?; .right == 32152))' >/dev/null
    svc stop "$service"
done
echo 'PASS native Snell edit preserves stopped/running state and restores port/process/nft rules after failure in isolated namespace'

# Actual Snell process/nft checkpoint recovery at a user's independent boundary.
anchor=$(date -d '-30 days' +%F)
_db_apply --arg anchor "$anchor" '.xray["snell-v5"][0].users[0] |=
    (.used=101 | .quota=100 | .enabled=false | .disabled_reason="quota" |
     .traffic_reset={days:30,anchor:$anchor,last_period:0})'
cp "$CFG/snell-users/$id.conf" "$fixture/cycle-before.conf"
touch "$fixture/fail-cycle-start"
if check_user_traffic_cycles; then exit 1; fi
! svc status "$service"
! svc is-enabled "$service"
jq -e '.xray["snell-v5"][0].users[0] | .enabled == false and .traffic_reset.last_period == 0' "$DB_FILE" >/dev/null
cmp "$CFG/snell-users/$id.conf" "$fixture/cycle-before.conf"
rm "$fixture/fail-cycle-start"
check_user_traffic_cycles
svc status "$service"
svc is-enabled "$service"
ss -H -lnt '( sport = :32152 )' | grep -q .
jq -e '.xray["snell-v5"][0].users[0] | .enabled == true and .used == 0 and .traffic_reset.last_period == 1' "$DB_FILE" >/dev/null
cp "$DB_FILE" "$fixture/cycle-after.json"
check_user_traffic_cycles
cmp "$DB_FILE" "$fixture/cycle-after.json"
svc stop "$service"
echo 'PASS native Snell 30-day cycle restores quota user, retries failed start without advancing period and preserves configuration'
