#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
for port in 1 443 65535 01080; do _is_valid_port "$port"; done
for port in '' 0 65536 18446744073709552059 -1 '1;true'; do
    if _is_valid_port "$port"; then echo "Accepted invalid port: $port"; exit 1; fi
done
for address in 0.0.0.0 255.255.255.255 192.0.2.1; do _is_valid_ipv4_literal "$address"; done
for address in 192.0.2.256 18446744073709551617.2.3.4 1.2.3 ''; do
    if _is_valid_ipv4_literal "$address"; then exit 1; fi
done
for address in :: ::1 2001:db8::1 2001:db8:: 1:2:3:4:5:6:7:8; do
    _is_valid_ipv6_literal "$address"
    _is_valid_domain_or_ip "$address"
done
for address in 1:2:3 2001::1: :2001::1 2001:::1 1::2::3 1:2:3:4:5:6:7:8:9; do
    if _is_valid_ipv6_literal "$address" || _is_valid_domain_or_ip "$address"; then echo "Accepted invalid IPv6: $address"; exit 1; fi
done
_is_valid_domain_or_ip localhost
_is_valid_domain_or_ip node.example
eval "$(awk '/^validate_port\(\) {/ {on=1} on {print} on && $0 == "}" {exit}' "$repo/nft.sh")"
validate_port 65535
if validate_port 18446744073709552059 || validate_port 01080; then exit 1; fi
echo 'PASS bounded numeric validation and strict IPv4/IPv6 without changing leading-zero policies'

uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
_write_sub_info "$uuid" 8443 '' true
[[ $(stat -c %a "$CFG/sub.info") == 600 ]]
sub_uuid=old-uuid sub_port=old-port sub_domain=old-domain sub_https=old-https
_load_sub_info
[[ "$sub_uuid" == "$uuid" && "$sub_port" == 8443 && "$sub_domain" == '' && "$sub_https" == true ]]
assert_unchanged() { [[ "$sub_uuid" == old-uuid && "$sub_port" == old-port && "$sub_domain" == old-domain && "$sub_https" == old-https ]]; }
sub_uuid=old-uuid sub_port=old-port sub_domain=old-domain sub_https=old-https
printf 'sub_uuid=%s\nsub_port=443\nsub_domain=node.example\nsub_https=INVALID\n' "$uuid" > "$fixture/invalid.info"
if _load_sub_info "$fixture/invalid.info"; then exit 1; fi
assert_unchanged
printf 'sub_uuid=%s\nsub_https=true\n' "$uuid" > "$fixture/invalid.info"
if _load_sub_info "$fixture/invalid.info"; then exit 1; fi
assert_unchanged
cp "$CFG/sub.info" "$fixture/invalid.info"
echo sub_port=443 >> "$fixture/invalid.info"
if _load_sub_info "$fixture/invalid.info"; then exit 1; fi
assert_unchanged
cp "$CFG/sub.info" "$fixture/before.info"
mv() {
    [[ "${!#}" != "$CFG/sub.info" ]] || return 1
    command mv "$@"
}
if _write_sub_info "$uuid" 443 node.example false; then exit 1; fi
cmp "$CFG/sub.info" "$fixture/before.info"
unset -f mv
_write_sub_info "$uuid" 443 node.example false
_load_sub_info
[[ "$sub_port" == 443 && "$sub_domain" == node.example && "$sub_https" == false ]]
echo 'PASS complete metadata validation, invalid/missing/duplicate fields preserve caller state, atomic file write failure'

curl() { printf '%s' "$fixture_content"; }
plain_link="vless://${uuid}@node.example:443?security=tls&type=ws&sni=node.example&path=%2Fws&host=node.example#fixture"
fixture_content="$plain_link"
parse_subscription https://fixture.example/sub > "$fixture/plain.json"
fixture_content=$(printf '%s' "$plain_link" | base64 -w 0)
parse_subscription https://fixture.example/sub > "$fixture/base64.json"
cmp "$fixture/plain.json" "$fixture/base64.json"
fixture_content="$plain_link"$'\nunsupported://redacted\nnot-a-link\n'
parse_subscription https://fixture.example/sub > "$fixture/mixed.json" 2> "$fixture/import-status"
cmp "$fixture/plain.json" "$fixture/mixed.json"
grep -q '跳过 2 行' "$fixture/import-status"
grep -q '分享链接 1 行.*非分享链接内容 1 行' "$fixture/import-status"
# Partially decodable input must not be accepted as a complete Base64 payload.
fixture_content=$(printf '%s' "$plain_link" | base64 -w 0)
fixture_content+='%'
if fetch_subscription https://fixture.example/sub > "$fixture/bad-decode"; then exit 1; fi
echo 'PASS plain/Base64 subscription parity and rejection of partial decoding'

fixture_content=$(cat <<'YAML'
proxies:
  - name: first
    type: vless
    server: node.example
    port: 443
    uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    tls: true
    network: ws
    servername: first.example
    ws-opts:
      path: /first?key=value&x=1
      headers:
        Host: first.example
  - name: last
    type: vless
    server: 2001:db8::1
    port: 8443
    uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    tls: true
    network: ws
    servername: last.example
    ws-opts:
      path: /last
      headers:
        Host: last.example
YAML
)
fetch_subscription https://fixture.example/sub > "$fixture/links"
[[ $(grep -c '^vless://' "$fixture/links") == 2 ]]
while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    parse_share_link "$link" >> "$fixture/nodes.jsonl"
done < "$fixture/links"
jq -se 'length == 2 and all(.security == "tls" and .transport == "ws") and
    .[0].path == "/first?key=value&x=1" and .[0].host == "first.example" and
    .[1].path == "/last" and .[1].host == "last.example" and .[1].server == "2001:db8::1"' "$fixture/nodes.jsonl" >/dev/null
reality=$(_clash_vless_share_link reality "$uuid" node.example 443 tcp true node.example xtls-rprx-vision '' '' public-key abcd)
[[ "$reality" == *'security=reality'* && "$reality" == *'pbk=public-key'* && "$reality" == *'sid=abcd'* ]]
none=$(_clash_vless_share_link plain "$uuid" node.example 443 tcp false '' '' '' '' '' '')
[[ "$none" == *'security=none'* ]]
if [[ -n "${XRAY_BIN:-}" ]]; then
    while IFS= read -r node; do
        gen_xray_chain_outbound "$node" fixture as_is | jq '{inbounds:[],outbounds:[.]}' > "$fixture/outbound.json"
        "$XRAY_BIN" run -test -c "$fixture/outbound.json" >/dev/null
    done < "$fixture/nodes.jsonl"
fi
echo 'PASS intermediate/final Clash TLS+WS, escaped path, IPv6, Reality and non-TLS conversion'
