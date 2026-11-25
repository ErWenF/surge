#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

# 检查真实菜单分派，模拟两条线路共用 IP、IPv6-only 和故障线路。
(
    _header() { :; }
    _line() { :; }
    _pause() { :; }
    _item() { :; }
    show_routing_status() { :; }
    warp_status() { echo not_configured; }
    db_get_chain_nodes() { echo '[{"name":"A","type":"socks"},{"name":"B","type":"socks"},{"name":"V6","type":"socks"},{"name":"坏节点","type":"socks"}]'; }
    _pick_latency_core() { echo xray; }
    _with_probe_proxy() { "$4" "$(jq -r .name <<< "$2")"; }
    _quality_http() {
        local port=$1 url=$2
        case "$url" in
            https://my.ippure.com/*)
                case "$port" in
                    '') echo '{"ip":"203.0.113.8","countryCode":"US","fraudScore":0}' ;;
                    A|B) echo '{"ip":"192.0.2.7","fraudScore":61,"isResidential":true}' ;;
                    V6) echo '<html>limited</html>' ;;
                    *) return 7 ;;
                esac ;;
            https://api6.ipify.org) [[ "$port" == V6 ]] && echo '2001:db8::7' ;;
            https://api.ipify.org|https://*.icanhazip.com) return 7 ;;
            https://ip99.com/*)
                [[ -z "$port" ]] || fail '数据库查分线路错误'
                echo "$url" >> "$fixture/requests"
                case "${url##*/}" in
                    192.0.2.7) echo '{"ip":"192.0.2.7","risk":{"score":27},"geo":{"country":"JP"}}' ;;
                    203.0.113.8) echo '{"ip":"198.51.100.7","risk":{"score":100}}' ;;
                    *) echo '{"ip":"2001:db8:0:0:0:0:0:7","risk":{"score":81}}' ;;
                esac ;;
            --config)
                local cfg
                read -r cfg
                [[ "$cfg" == *'/demo_key/json/'* ]] || fail 'Ping0 key or IP missing'
                echo paid >> "$fixture/requests"
                case "$cfg" in
                    *192.0.2.7*) echo '{"ip":"192.0.2.7","iprisk":"18%"}' ;;
                    *) return 22 ;;
                esac ;;
            *) fail '未知请求' ;;
        esac
    }
    report=$(VLESS_PING0_KEY=demo_key manage_routing <<<'10
0')
    for expected in 'IPPure | IP99 | Ping0' \
        '服务器直连 | 203.0.113.8 | US | 未知 | 0 | 未取得评分' \
        'A | 192.0.2.7 | JP | 住宅 | 61 | 27 | 18' \
        'B | 192.0.2.7 | JP | 住宅 | 61 | 27 | 18' \
        'V6 | 2001:db8::7 | 未知 | 未知 | 未取得评分 | 81' \
        '坏节点 | 未取得出口 IP'; do
        [[ "$report" == *"$expected"* ]] || fail "$expected"
    done
    [[ "$(wc -l < "$fixture/requests")" == 6 && "$report" != *demo_key* ]] || fail '重复查询或输出密钥'
    : > "$fixture/requests"
    report=$(VLESS_PING0_KEY='' show_egress_quality)
    [[ "$report" != *' | Ping0'* && "$(wc -l < "$fixture/requests")" == 3 ]] || fail '禁用付费查询'
)

(
    curl() { printf '<%s>' "$@"; }
    direct=$(_quality_http '' https://example.org)
    proxy=$(_quality_http 1080 https://example.org)
    [[ "$direct" == *'<--noproxy><*>'* && "$proxy" == *'<--noproxy><><--socks5-hostname><127.0.0.1:1080>'* ]] ||
        fail 'curl 的环境代理隔离'
)

(
    _quality_http() {
        case "${2}:${3:-}" in
            https://my.ippure.com/v1/info:-4) echo '{"ip":"192.0.2.12","fraudScore":13}' ;;
            https://my.ippure.com/v1/info:-6) echo '{"ip":"2001:db8::12"}' ;;
            https://my.ippure.com/v1/info:) return 22 ;;
            https://ipv4.icanhazip.com:) echo '192.0.2.13' ;;
            *) return 7 ;;
        esac
    }
    _quality_observe '' | jq -se 'length==2 and .[0].pure==13 and .[1].ip=="2001:db8::12" and .[1].pure==null' >/dev/null ||
        fail '双栈分数必须属于各自的实测 IP'
    _quality_observe 12345 | jq -se 'length==1 and .[0]=={ip:"192.0.2.13"}' >/dev/null ||
        fail '备用回显只能补充实测地址'
)

# 分流规则页保留配置顺序。双内核可以选中不同节点；相同 IP 不等于直连回落。
(
    cat > "$DB_FILE" <<'JSON'
{"chain_proxy":{"nodes":[{"name":"主","type":"socks"},{"name":"备","type":"socks"}]},
 "balancer_groups":[{"name":"FO","strategy":"failover","nodes":["主","备"]},{"name":"LB","strategy":"random","nodes":["主","备"]}],
 "routing_rules":[{"type":"custom","domains":"claude.ai","outbound":"balancer:FO"},
 {"type":"openai","outbound":"balancer:FO","ip_version":"ipv6_only"},
 {"type":"custom","domains":"example.com","outbound":"chain:备","ip_version":"ipv4_only"},
 {"type":"ads","outbound":"block"},{"type":"google","outbound":"balancer:LB"}]}
JSON
    printf '%s' '{"routing":{"balancers":[{"tag":"balancer-FO","selector":["chain-主-prefer-ipv4","chain-备-prefer-ipv4"]}]}}' > "$CFG/config.json"
    printf '%s' '{"outbounds":[{"type":"selector","tag":"balancer-FO","outbounds":["chain-主-prefer-ipv4","chain-备-prefer-ipv4","direct"]}]}' > "$CFG/singbox.json"
    _failover_xray_override() { echo Xray >> "$fixture/apis"; echo "${xray_now:-chain-备-prefer-ipv4}"; }
    _failover_singbox_now() { echo sing-box >> "$fixture/apis"; echo "${sb_now:-chain-主-prefer-ipv4}"; }
    _pick_latency_core() { echo xray; }
    _with_probe_proxy() { "$4" "$(jq -r .name <<< "$2")"; }
    _quality_lookup() { echo '意外查分' >> "$fixture/paid"; return 1; }
    _quality_observe() {
        echo "probe:${1:-direct}" >> "$fixture/probes"
        case "$1" in
            '') printf '%s\n' '{"ip":"192.0.2.1"}' '{"ip":"2001:db8::1"}' ;;
            主) printf '%s\n' '{"ip":"192.0.2.1"}' '{"ip":"2001:0db8:0:0:0:0:0:1"}' ;;
            备) printf '%s\n' '{"ip":"198.51.100.2"}' ;;
        esac
    }
    report=$(VLESS_PING0_KEY=demo_key test_routing)
    for expected in 'claude.ai → 组 FO → Xray → 备用节点 备 → 出口 IPv4 198.51.100.2（与直连不同）' \
        'claude.ai → 组 FO → sing-box → 主节点 主 → 出口 IPv4 192.0.2.1（与直连相同） / IPv6 2001:0db8:0:0:0:0:0:1（与直连相同）' \
        'example.com [仅 IPv4] → 备 → 出口 IPv4 198.51.100.2' \
        '广告屏蔽 → 拦截' '动态选路' '候选 备 → 出口 IPv4 198.51.100.2'; do
        [[ "$report" == *"$expected"* ]] || fail "$expected"
    done
    openai=${report#*'OpenAI/ChatGPT [仅 IPv6]'}; openai=${openai%%example.com*}
    [[ "$openai" == *'未取得对应地址族的出口 IP'* && "$openai" != *IPv4* ]] || fail '只匹配 IPv6'
    [[ $(wc -l < "$fixture/apis") == 2 && $(wc -l < "$fixture/probes") == 3 && ! -e "$fixture/paid" ]] || fail '重复探测或付费查询'
    report=$(xray_now=direct sb_now=unrecognized test_routing)
    [[ "$report" == *'Xray → 回落直连 → 出口 IPv4 192.0.2.1'* && "$report" == *'sing-box → 当前出口未确认，IP 未知'* ]] || fail '直连回落与未知状态'

    _header() { :; }
    _line() { :; }
    _item() { :; }
    warp_status() { echo not_configured; }
    : > "$fixture/probes"
    report=$(manage_routing <<<'8

7
0')
    expected='example.com [仅 IPv4] → 备 → 出口 IPv4 198.51.100.2'
    [[ $(grep -Fc "$expected" <<< "$report") == 3 && $(wc -l < "$fixture/probes") == 6 ]] ||
        fail '首页首次显示 IP、返回复用结果、选择 7 重新探测'
)

# 实际 SOCKS 落地收到指定域名后返回标记。测试不依赖公网或任何评分服务。
for native_path in "${XRAY_BIN:-}" "${SINGBOX_TEST_BIN:-}"; do
    [[ -x "$native_path" ]] || continue
    (
        core=xray
        [[ "$native_path" == "${SINGBOX_TEST_BIN:-}" ]] && core=singbox
        xray() { exec "$native_path" "$@"; }
        sing-box() { exec "$native_path" "$@"; }
        python3 -u - > "$fixture/port" <<'PY' &
import socket, struct
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    s.listen()
    print(s.getsockname()[1], flush=True)
    conn, _ = s.accept()
    with conn, conn.makefile("rb") as f:
        conn.settimeout(6)
        version, count = f.read(2)
        assert version == 5
        f.read(count)
        conn.sendall(b"\x05\x00")
        assert f.read(4) == b"\x05\x01\x00\x03"
        assert f.read(f.read(1)[0]) == b"measurement.invalid"
        assert struct.unpack("!H", f.read(2))[0] == 80
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        while f.readline() not in (b"\r\n", b""):
            pass
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nlanded")
PY
        upstream=$!
        trap 'kill "$upstream" 2>/dev/null || :; wait "$upstream" 2>/dev/null || :' EXIT
        for ((i=0;i<100;i++)); do [[ -s "$fixture/port" ]] && break; sleep .02; done
        node=$(jq -cn --argjson port "$(cat "$fixture/port")" '{type:"socks",server:"127.0.0.1",port:$port}')
        probe() { curl -qfsS --noproxy '' --socks5-hostname "127.0.0.1:$1" --max-time 5 http://measurement.invalid; }
        [[ "$(_with_probe_proxy "$core" "$node" as_is probe)" == landed ]] || fail "$core 代理探测"
        wait "$upstream" || fail "$core 落地握手"
        if _with_probe_proxy "$core" "$node" as_is probe >/dev/null 2>&1; then fail "$core 失效节点意外成功"; fi
        : > "$fixture/port"
    )
done
echo '出口 IP 评分、线路隔离与缓存测试通过'
