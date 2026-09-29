#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
CFG="$fixture/cfg"
DB_FILE="$CFG/db.json"
TRAFFIC_MONTHLY_RESET_LAST_FILE="$CFG/monthly-last"
mkdir -p "$CFG"

load_function() {
    eval "$(awk -v fn="$1" 'index($0, fn "() {") == 1 {on=1} on {print} on && $0 == "}" {exit}' "$repo/vless-server.sh")"
}
for fn in _user_management_supported _user_change_begin _user_change_apply db_add_user db_del_user \
    db_set_user_enabled db_get_user db_get_user_field db_get_users_stats db_list_users \
    gen_xray_vless_clients gen_xray_vmess_clients gen_xray_trojan_clients \
    reset_monthly_user_traffic check_monthly_traffic_reset \
    _sync_all_user_traffic_unlocked; do
    load_function "$fn"
done

_db_apply() { jq "$@" "$DB_FILE" > "$fixture/new.json" && mv "$fixture/new.json" "$DB_FILE"; }
db_exists() { jq -e --arg c "$1" --arg p "$2" '.[$c][$p] != null' "$DB_FILE" >/dev/null; }
db_get() { jq --arg c "$1" --arg p "$2" '.[$c][$p]' "$DB_FILE"; }
is_standalone_protocol() { return 1; }
_snell_managed() { return 1; }
_err() { printf '%s\n' "$*" >&2; }
_ok() { :; }
svc() {
    case "$1" in
        status) [[ -f "$fixture/$2.running" ]] ;;
        restart) printf '%s\n' "$2" >> "$fixture/restarts"; if [[ -f "$fixture/fail-restart" ]]; then rm "$fixture/fail-restart"; return 1; fi ;;
        start) printf '%s\n' "$2" >> "$fixture/starts" ;;
    esac
}
generate_xray_config() {
    jq '{inbounds:[.xray.trojan[] | {tag:("trojan-in-" + (.port | tostring)),settings:{clients:.users}}],outbounds:[]}' "$DB_FILE" > "$XRAY_CONFIG_OUTPUT"
    if [[ -f "$fixture/drop-inbound" ]]; then
        jq '.inbounds |= .[1:]' "$XRAY_CONFIG_OUTPUT" > "$fixture/dropped.json"
        mv "$fixture/dropped.json" "$XRAY_CONFIG_OUTPUT"
    fi
}
generate_singbox_config() { jq '{inbounds:[.singbox.hy2[] | {tag:("hy2-in-" + (.port | tostring)),users:.users}],outbounds:[]}' "$DB_FILE" > "$SINGBOX_CONFIG_OUTPUT"; }
_snell_apply_users() {
    printf '%s|%s\n' "$1" "$2" >> "$fixture/snell-applies"
    if [[ -f "$fixture/fail-snell" ]]; then rm "$fixture/fail-snell"; return 1; fi
}
printf '#!/usr/bin/env bash\n[[ ! -f "$FAIL_CHECK_FILE" ]] && jq empty "${@: -1}"\n' > "$fixture/check.sh"
chmod +x "$fixture/check.sh"
XRAY_BIN="$fixture/check.sh"
SINGBOX_BIN="$fixture/check.sh"
FAIL_CHECK_FILE="$fixture/fail-check"
export FAIL_CHECK_FILE
USER_CHANGE_HEALTH_DELAY=0

jq -n '{xray:{trojan:[{port:22222,password:"old-b",users:[]},{port:11111,password:"old-a",users:[]}],ss2022:{port:33333,password:"old-ss"}},singbox:{hy2:[{port:44444,password:"old-c",users:[]},{port:55555,password:"old-d",users:[]}]}}' > "$DB_FILE"
printf '%s\n' '{"old":true}' > "$CFG/config.json"
printf '%s\n' '{"old":true}' > "$CFG/singbox.json"
touch "$fixture/vless-reality.running"

if db_add_user xray ss2022 phantom secret 0 '' 33333; then exit 1; fi
jq -e '.xray.ss2022.users == null' "$DB_FILE" >/dev/null
if db_add_user xray trojan missing secret 0 ''; then exit 1; fi
db_add_user xray trojan alice alice-pass 1 '' 11111
jq -e '(.xray.trojan[0].users | map(.name) == ["default-22222"]) and (.xray.trojan[1].users | any(.name == "alice"))' "$DB_FILE" >/dev/null
[[ $(jq -r '.xray.trojan[1].users[0].name' "$DB_FILE") == default-11111 ]]
[[ $(gen_xray_trojan_clients trojan 11111 | jq '[.[] | select(.email == "alice@trojan")] | length') == 1 ]]
[[ $(gen_xray_trojan_clients trojan 22222 | jq '[.[] | select(.email == "alice@trojan")] | length') == 0 ]]
db_set_user_enabled xray trojan alice false
[[ $(gen_xray_trojan_clients trojan 11111 | jq 'length') == 1 ]]
db_set_user_enabled xray trojan alice true
_db_apply '.xray.vless=[{port:10001,uuid:"vless-a",users:[{name:"vless-a",uuid:"vless-a",enabled:true}]},{port:10002,uuid:"vless-b",users:[{name:"vless-b",uuid:"vless-b",enabled:true}]}] | .xray["vmess-ws"]=[{port:20001,uuid:"vmess-a",users:[{name:"vmess-a",uuid:"vmess-a",enabled:true}]},{port:20002,uuid:"vmess-b",users:[{name:"vmess-b",uuid:"vmess-b",enabled:true}]}]'
[[ $(gen_xray_vless_clients vless '' 10001 | jq '.[].email') == '"vless-a@vless"' ]]
[[ $(gen_xray_vmess_clients vmess-ws 20002 | jq '.[].email') == '"vmess-b@vmess-ws"' ]]
[[ $(wc -l < "$fixture/restarts") == 3 ]]

cp "$DB_FILE" "$fixture/before-fail-db"
cp "$CFG/config.json" "$fixture/before-fail-config"
touch "$fixture/fail-check"
if db_add_user xray trojan rejected rejected-pass 0 '' 22222; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-fail-db"
cmp "$CFG/config.json" "$fixture/before-fail-config"
rm "$fixture/fail-check"
touch "$fixture/drop-inbound"
if db_add_user xray trojan rejected rejected-pass 0 '' 22222; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-fail-db"
cmp "$CFG/config.json" "$fixture/before-fail-config"
rm "$fixture/drop-inbound"
touch "$fixture/fail-restart"
if db_add_user xray trojan rejected rejected-pass 0 '' 22222; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-fail-db"
cmp "$CFG/config.json" "$fixture/before-fail-config"

db_add_user singbox hy2 bob bob-pass 0 '' 55555
[[ ! -f "$fixture/starts" ]]
[[ $(jq -r '.singbox.hy2[1].users[1].name' "$DB_FILE") == bob ]]
[[ $(jq -r '.singbox.hy2[0].users[0].name' "$DB_FILE") == default-44444 ]]
db_set_user_enabled singbox hy2 bob false
jq -e '.singbox.hy2[1].users[1].enabled == false and .singbox.hy2[1].users[1].disabled_reason == "manual"' "$DB_FILE" >/dev/null
db_set_user_enabled singbox hy2 bob true
[[ ! -f "$fixture/starts" ]]

_db_apply '.xray.trojan[1].users += [{name:"manual",uuid:"manual-pass",quota:0,used:31,enabled:false,disabled_reason:"manual"},{name:"quota",uuid:"quota-pass",quota:20,used:35,enabled:false,disabled_reason:"quota"},{name:"expired",uuid:"expired-pass",quota:20,used:35,enabled:false,disabled_reason:"quota",expire_date:"2000-01-01"},{name:"legacy",uuid:"legacy-pass",quota:20,used:35,enabled:false,quota_exceeded_notified:true}] | .xray.trojan[1].users[1].used=12 | .xray.ss2022.users=[{name:"old-phantom",quota:20,used:35,enabled:false,disabled_reason:"quota"}] | .xray["snell-v6"]=[{snell_id:"aaaaaaaaaaaaaaaaaaaaaaaa",users:[{name:"snell-quota",quota:20,used:35,enabled:false,disabled_reason:"quota"}]},{snell_id:"bbbbbbbbbbbbbbbbbbbbbbbb",users:[{name:"snell-manual",quota:20,used:35,enabled:false,disabled_reason:"manual"}]}]'
reset_monthly_user_traffic
jq -e '.xray.trojan[1].users | (map(select(.name == "manual"))[0] | .enabled == false and .used == 0) and (map(select(.name == "quota"))[0] | .enabled == true and .used == 0) and (map(select(.name == "expired"))[0] | .enabled == false and .used == 0) and (map(select(.name == "legacy"))[0] | .enabled == false and .used == 0)' "$DB_FILE" >/dev/null
jq -e '.xray["snell-v6"] | .[0].users[0].enabled == true and .[0].users[0].used == 0 and .[1].users[0].enabled == false' "$DB_FILE" >/dev/null
jq -e '.xray.ss2022.users[0] | .enabled == false and .used == 0' "$DB_FILE" >/dev/null
[[ $(cat "$fixture/snell-applies") == 'snell-v6|snell-quota' ]]
[[ $(cat "$TRAFFIC_MONTHLY_RESET_LAST_FILE") == $(date +%Y-%m) ]]
[[ ! -f "$fixture/starts" ]]

_db_apply '.xray.trojan[1].users |= map(if .name == "quota" then .enabled=false | .disabled_reason="quota" | .used=35 else . end) | .xray["snell-v6"][0].users[0] |= (.enabled=false | .disabled_reason="quota" | .used=35)'
cp "$DB_FILE" "$fixture/before-reset-fail-db"
cp "$CFG/config.json" "$fixture/before-reset-fail-config"
rm -f "$TRAFFIC_MONTHLY_RESET_LAST_FILE"
touch "$fixture/fail-snell"
if reset_monthly_user_traffic; then exit 1; fi
cmp "$DB_FILE" "$fixture/before-reset-fail-db"
cmp "$CFG/config.json" "$fixture/before-reset-fail-config"
[[ ! -f "$TRAFFIC_MONTHLY_RESET_LAST_FILE" ]]

_ensure_singbox_default_users() { :; }
_snell_sync_traffic() { :; }
check_daily_report() { :; }
_snell_any_managed() { return 1; }
_pgrep() { [[ "$1" == xray ]]; }
xray() { printf '%s\n' '{"stat":[{"name":"user>>>alice@trojan>>>traffic>>>uplink","value":7}]}'; }
db_list_protocols() { [[ "$1" != xray ]] || printf '%s\n' trojan; }
db_update_user_traffic() { _db_apply --arg p "$2" --arg n "$3" --argjson bytes "$4" '.xray[$p] |= map(.users |= map(if .name == $n then .used += $bytes else . end))'; }
tg_get_config() { echo 80; }
mark_traffic_sync_result() { :; }
get_traffic_monthly_reset_enabled() { echo true; }
get_traffic_monthly_reset_day() { echo 1; }
rm -f "$TRAFFIC_MONTHLY_RESET_LAST_FILE"
_sync_all_user_traffic_unlocked true
[[ $(jq -r '.xray.trojan[1].users[] | select(.name == "alice") | .used' "$DB_FILE") == 0 ]]
[[ $(cat "$TRAFFIC_MONTHLY_RESET_LAST_FILE") == $(date +%Y-%m) ]]

echo 'PASS port-scoped users, SS rejection, rollback, stopped-core state, monthly reset'
