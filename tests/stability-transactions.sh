#!/usr/bin/env bash
# All state and service commands are isolated fixtures.
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
assert_db_same() { cmp <(jq 'del(.meta.updated)' "$DB_FILE") <(jq 'del(.meta.updated)' "$fixture/before"); }
DISTRO=debian
id=ca0000000000000000000001
other=ca0000000000000000000002
fixture_snell_id="$id"
service="vless-snellu-$id"
mkdir -p "$CFG/snell-users"
printf '[snell-server]\nlisten = 127.0.0.1:32001\npsk = oldpassword\n' > "$CFG/snell-users/$id.conf"
_db_apply --arg id "$id" --arg other "$other" '.xray["snell-v6"]=[
    {snell_id:$id,port:32001,psk:"oldpassword",users:[{name:"alice",used:20,quota:0,enabled:true}]},
    {snell_id:$other,port:32002,psk:"otherpassword",users:[{name:"bob",used:30,quota:0,enabled:true}]}] |
    .meta.snell_users["snell-v6"]=true'
_snell_nft_ready() { :; }
_snell_counter_prepare() { :; }
_snell_write_service() { :; }
fixture_up=100
nft() {
    [[ ! -f "$fixture/fail-stats" ]] || return 1
    jq -n --arg id "$fixture_snell_id" --arg other "$other" --argjson up "$fixture_up" '{nftables:[
        {counter:{name:("u_"+$id),bytes:$up,comment:"epoch"}}, {counter:{name:("d_"+$id),bytes:0}},
        {counter:{name:("u_"+$other),bytes:50,comment:"epoch"}}, {counter:{name:("d_"+$other),bytes:0}}]}'
}
svc() {
    printf '%s %s\n' "$1" "$2" >> "$fixture/events"
    case "$1" in
        status) [[ -f "$fixture/$2.running" ]] ;;
        is-enabled) [[ -f "$fixture/$2.enabled" ]] ;;
        stop)
            [[ ! -f "$fixture/fail-stop" ]] || return 1
            [[ -f "$fixture/lie-stop" ]] || rm -f "$fixture/$2.running" ;;
        disable)
            if [[ -f "$fixture/fail-disable" ]]; then rm "$fixture/fail-disable"; return 1; fi
            rm -f "$fixture/$2.enabled" ;;
        enable) touch "$fixture/$2.enabled" ;;
        start|restart)
            [[ ! -f "$fixture/fail-start" ]] || return 1
            touch "$fixture/$2.running" ;;
        *) return 1 ;;
    esac
}
touch "$fixture/$service.running" "$fixture/$service.enabled"
_snell_account_traffic snell-v6
cp "$DB_FILE" "$fixture/before"
cp "$CFG/snell-users/$id.conf" "$fixture/before-conf"
touch "$fixture/fail-stop"
if db_set_user_enabled xray snell-v6 alice false; then exit 1; fi
assert_db_same
cmp "$CFG/snell-users/$id.conf" "$fixture/before-conf"
[[ -f "$fixture/$service.running" && -f "$fixture/$service.enabled" ]]
rm "$fixture/fail-stop"
touch "$fixture/lie-stop"
if db_set_user_enabled xray snell-v6 alice false; then exit 1; fi
assert_db_same
rm "$fixture/lie-stop"
touch "$fixture/fail-disable"
if db_set_user_enabled xray snell-v6 alice false; then exit 1; fi
assert_db_same
[[ -f "$fixture/$service.running" && -f "$fixture/$service.enabled" ]]
db_set_user_enabled xray snell-v6 alice false
[[ ! -f "$fixture/$service.running" && ! -f "$fixture/$service.enabled" ]]
[[ $(db_get_user_field xray snell-v6 alice enabled) == false ]]
# A failed enable must return to stopped/disabled, including enable-before-start.
cp "$DB_FILE" "$fixture/before"
touch "$fixture/fail-start"
if db_set_user_enabled xray snell-v6 alice true; then exit 1; fi
assert_db_same
[[ ! -f "$fixture/$service.running" && ! -f "$fixture/$service.enabled" ]]
rm "$fixture/fail-start"
db_set_user_enabled xray snell-v6 alice true
[[ -f "$fixture/$service.running" && -f "$fixture/$service.enabled" ]]
echo 'PASS Snell stop failure, false success, disable/start failure rollback and stopped-state preservation'

: > "$fixture/events"
fixture_up=150
db_reset_user_traffic xray snell-v6 alice
[[ $(db_get_user_field xray snell-v6 alice used) == 0 ]]
[[ $(db_get_user_field xray snell-v6 bob used) == 80 ]]
[[ ! -s "$fixture/events" ]]
fixture_up=160
_snell_account_traffic snell-v6
[[ $(db_get_user_field xray snell-v6 alice used) == 10 ]]
cp "$DB_FILE" "$fixture/before"
touch "$fixture/fail-stats"
if db_reset_user_traffic xray snell-v6 alice; then exit 1; fi
assert_db_same
echo 'PASS Snell reset checkpoint boundary, other-user preservation and failed-read rollback'

# The actual Xray checkpoint path, with a fixture API, must have the same boundary.
_db_apply '.xray.vless={port:32003,users:[{name:"charlie",used:20,enabled:true}]}'
printf '%s\n' '{"api":{"services":["StatsService"]}}' > "$CFG/config.json"
touch "$fixture/vless-reality.running"
_core_traffic_epoch() { echo core-epoch; }
xray_api_query() {
    [[ "$2" == false ]] || return 1
    jq -n --argjson value "$fixture_up" '{stat:[{name:"user>>>charlie@vless>>>traffic>>>uplink",value:$value}]}'
}
fixture_up=100
_flush_core_traffic xray
fixture_up=150
db_reset_user_traffic xray vless charlie
fixture_up=160
_flush_core_traffic xray
[[ $(db_get_user_field xray vless charlie used) == 10 ]]
xray_api_query() { return 1; }
cp "$DB_FILE" "$fixture/before"
if db_reset_user_traffic xray vless charlie; then exit 1; fi
assert_db_same
echo 'PASS Xray reset excludes pre-reset traffic and preserves state on API failure'

get_sub_uuid() { echo fixture-subscription; }
gen_v2ray_sub() { echo new-base64; }
gen_clash_sub() { echo new-clash; }
gen_surge_sub() { echo new-surge; [[ ! -f "$fixture/fail-generator" ]]; }
sub_dir="$CFG/subscription/fixture-subscription"
mkdir -p "$sub_dir"
for file in base64 clash.yaml surge.conf; do echo "old-$file" > "$sub_dir/$file"; done
touch "$fixture/fail-generator"
if generate_sub_files; then exit 1; fi
for file in base64 clash.yaml surge.conf; do [[ $(cat "$sub_dir/$file") == "old-$file" ]]; done
rm "$fixture/fail-generator"
mv() {
    if [[ "$*" == *".generate."* && "${!#}" == "$sub_dir/clash.yaml" && ! -f "$fixture/move-failed" ]]; then
        touch "$fixture/move-failed"
        return 1
    fi
    command mv "$@"
}
if generate_sub_files; then exit 1; fi
for file in base64 clash.yaml surge.conf; do [[ $(cat "$sub_dir/$file") == "old-$file" ]]; done
unset -f mv
generate_sub_files
[[ $(cat "$sub_dir/base64") == new-base64 && $(cat "$sub_dir/clash.yaml") == new-clash && $(cat "$sub_dir/surge.conf") == new-surge ]]
[[ $(stat -c %a "$sub_dir/base64") == 644 ]]
[[ -z $(find "$CFG/subscription" -maxdepth 1 -name '.generate.*' -print -quit) ]]
echo 'PASS subscription generator failure, mid-publication rollback and complete successful update'
