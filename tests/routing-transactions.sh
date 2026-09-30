#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
init_db
_db_apply '.xray.vless={port:32001,users:[{name:"alice",used:27,enabled:true}]} |
    .singbox.trojan={port:32002,users:[{name:"bob",used:41,enabled:true}]} |
    .routing_rules=[{id:"existing",type:"custom",outbound:"direct",domains:"old.example"}]'
get_xray_protocols() { echo vless; }
get_singbox_protocols() { echo trojan; }
_flush_core_traffic() { :; }
generate_xray_config() { jq '{inbounds:[{tag:"xray-in"}],routing:{rules:.routing_rules}}' "$DB_FILE" > "$XRAY_CONFIG_OUTPUT"; }
generate_singbox_config() { jq '{inbounds:[{tag:"singbox-in"}],route:{rules:.routing_rules}}' "$DB_FILE" > "$SINGBOX_CONFIG_OUTPUT"; }
printf '#!/usr/bin/env bash\n[[ ! -f "$FAIL_CHECK_FILE" ]] && jq empty "${@: -1}"\n' > "$fixture/check.sh"
chmod +x "$fixture/check.sh"
XRAY_BIN="$fixture/check.sh"
printf '#!/usr/bin/env bash\n[[ ! -f "$FAIL_SECOND_CHECK" ]] && jq empty "${@: -1}"\n' > "$fixture/second-check.sh"
chmod +x "$fixture/second-check.sh"
SINGBOX_BIN="$fixture/second-check.sh"
export FAIL_CHECK_FILE="$fixture/fail-check" FAIL_SECOND_CHECK="$fixture/fail-second-check"
generate_xray_config_with_output() { XRAY_CONFIG_OUTPUT="$CFG/config.json" generate_xray_config; }
generate_xray_config_with_output
SINGBOX_CONFIG_OUTPUT="$CFG/singbox.json" generate_singbox_config
for file in db.json config.json singbox.json; do cp "$CFG/$file" "$fixture/$file.before"; done
svc() {
    case "$1" in
        status) [[ -f "$fixture/$2.running" ]] ;;
        is-enabled) return 1 ;;
        restart)
            printf '%s\n' "$2" >> "$fixture/restarts"
            if [[ "$2" == vless-singbox && -f "$fixture/fail-second-restart" ]]; then rm "$fixture/fail-second-restart"; return 1; fi
            touch "$fixture/$2.running" ;;
        *) echo "Unexpected service operation: $*" >&2; return 1 ;;
    esac
}
touch "$fixture/vless-reality.running" "$fixture/vless-singbox.running" "$FAIL_SECOND_CHECK"
if _apply_routing_change db_clear_routing_rules; then exit 1; fi
for file in db.json config.json singbox.json; do cmp "$CFG/$file" "$fixture/$file.before"; done
[[ ! -f "$fixture/restarts" ]]
rm "$FAIL_SECOND_CHECK"
touch "$fixture/fail-second-restart"
if _apply_routing_change db_clear_routing_rules; then exit 1; fi
for file in db.json config.json singbox.json; do cmp "$CFG/$file" "$fixture/$file.before"; done
[[ $(wc -l < "$fixture/restarts") == 4 ]]
[[ -f "$fixture/vless-reality.running" && -f "$fixture/vless-singbox.running" ]]
echo 'PASS second-core validation failure and second restart failure restore both configs and database'

rm "$fixture/vless-singbox.running" "$fixture/restarts"
_apply_routing_change db_add_routing_rule custom direct new.example prefer_ipv4
jq -e '.routing_rules | any(.domains == "new.example")' "$DB_FILE" >/dev/null
jq -e '.route.rules | any(.domains == "new.example")' "$CFG/singbox.json" >/dev/null
[[ $(cat "$fixture/restarts") == vless-reality ]]
[[ ! -f "$fixture/vless-singbox.running" ]]
jq -e '.xray.vless.users[0].used == 27 and .singbox.trojan.users[0].used == 41' "$DB_FILE" >/dev/null
rule_id=$(jq -r '.routing_rules[] | select(.domains == "new.example") | .id' "$DB_FILE")
_apply_routing_change db_del_routing_rule "$rule_id"
jq -e '.routing_rules | all(.domains != "new.example")' "$DB_FILE" >/dev/null
_apply_routing_change db_clear_routing_rules
jq -e '.routing_rules == []' "$DB_FILE" >/dev/null
echo 'PASS add/delete/clear apply consistently and keep inactive core stopped and user traffic intact'
