#!/usr/bin/env python3
"""Verify generated SS2022 configurations, live accounting and port routing."""
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

spec = importlib.util.spec_from_file_location("ss_helpers", Path(__file__).with_name("ss2022-native.py"))
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)


def stats(binary, port, pattern):
    result = subprocess.run([binary, "api", "statsquery", f"--server=127.0.0.1:{port}",
                             "-pattern", pattern], capture_output=True, timeout=5, check=True)
    return {row["name"]: int(row["value"]) for row in json.loads(result.stdout).get("stat", [])}


def main(binary, singbox):
    used_ports = set()

    def port():
        value = ss.free_port()
        while value in used_ports:
            value = ss.free_port()
        used_ports.add(value)
        return value

    web = ss.http.server.ThreadingHTTPServer(("127.0.0.1", 0), ss.Handler)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    threading.Thread(target=web.serve_forever, daemon=True).start()
    threading.Thread(target=ss.udp_echo, args=(udp,), daemon=True).start()
    processes = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        cfg = root / "cfg"
        cfg.mkdir()
        a, b, api, relay_port, relay_api, singbox_api = [port() for _ in range(6)]
        master, user_a, user_b, relay_key = [ss.key(16) for _ in range(4)]
        env = dict(os.environ, fixture=tmp, XRAY_BIN=binary, SINGBOX_BIN=singbox,
                   TEST_XRAY_API_PORT=str(api), TEST_SINGBOX_API_PORT=str(singbox_api))
        worker = str(Path(__file__).with_name("core-native-worker.sh"))

        def operation(*args, success=True):
            result = subprocess.run(["bash", worker, *map(str, args)], env=env,
                                    capture_output=True, timeout=25)
            if (result.returncode == 0) != success:
                reason = result.stderr.decode(errors="replace").strip().splitlines()[-1:]
                raise AssertionError(f"Native operation {args[0]} returned an unexpected status: {reason}")
            return result.stdout

        def database():
            return json.loads((cfg / "db.json").read_text())

        data = {"xray": {"ss2022": [
            {"port": a, "password": master, "method": "2022-blake3-aes-128-gcm", "multi_user": True,
             "users": [{"name": "default-a", "uuid": user_a, "enabled": True, "used": 0, "quota": 0}]},
            {"port": b, "password": master, "method": "2022-blake3-aes-128-gcm", "multi_user": True,
             "users": [{"name": "default-b", "uuid": user_b, "enabled": True, "used": 0, "quota": 0}]}]},
            "singbox": {}, "chain_proxy": {"nodes": [{"name": "test-relay", "type": "shadowsocks",
                "server": "127.0.0.1", "port": relay_port, "method": "2022-blake3-aes-128-gcm",
                "password": relay_key}]}, "meta": {}}
        (cfg / "db.json").write_text(json.dumps(data))
        relay_cfg = ss.config_file(root, "relay", {
            "api": {"tag": "api", "services": ["StatsService"]}, "stats": {},
            "policy": {"system": {"statsInboundUplink": True, "statsInboundDownlink": True}},
            "inbounds": [{"listen": "127.0.0.1", "port": relay_port, "tag": "relay", "protocol": "shadowsocks",
                          "settings": {"method": "2022-blake3-aes-128-gcm", "password": relay_key, "network": "tcp,udp"}},
                         {"listen": "127.0.0.1", "port": relay_api, "tag": "api", "protocol": "dokodemo-door",
                          "settings": {"address": "127.0.0.1"}}],
            "outbounds": [{"protocol": "freedom"}, {"tag": "api", "protocol": "blackhole"}],
            "routing": {"rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]}})
        try:
            relay = ss.start_xray(binary, relay_cfg)
            processes.append(relay)
            ss.await_port(relay_port)
            operation("start")
            ss.await_port(a)
            ss.await_port(b)

            def traffic(target, credential, expected=True, protocol="shadowsocks"):
                socks = port()
                if protocol == "shadowsocks":
                    outbound = {"protocol": protocol, "settings": {"servers": [{
                        "address": "127.0.0.1", "port": target, "method": "2022-blake3-aes-128-gcm",
                        "password": master + ":" + credential}]}}
                else:
                    outbound = {"protocol": "trojan", "settings": {"servers": [{
                        "address": "127.0.0.1", "port": target, "password": credential}]},
                        "streamSettings": {"security": "tls", "tlsSettings": {"serverName": "localhost",
                            "disableSystemRoot": True, "certificates": [{"certificateFile": str(root / "cfg/certs/server.crt"), "usage": "verify"}]}}}
                client_cfg = ss.config_file(root, "client", {
                    "inbounds": [{"listen": "127.0.0.1", "port": socks, "protocol": "socks",
                                  "settings": {"auth": "noauth", "udp": True}}],
                    "outbounds": [outbound]})
                client = ss.start_xray(binary, client_cfg)
                try:
                    ss.await_port(socks)
                    tcp = ss.socks_http(socks, web.server_port) == "ok"
                    udp_ok = ss.socks_udp(socks, udp.getsockname()[1])
                    if tcp != expected or udp_ok != expected:
                        raise AssertionError("TCP or UDP violated per-port authentication/routing")
                finally:
                    client.terminate()
                    client.wait(timeout=5)

            traffic(a, user_a)
            counters = stats(binary, api, "user>>>")
            assert counters["user>>>default-a@ss2022>>>traffic>>>uplink"] > 0
            assert counters["user>>>default-a@ss2022>>>traffic>>>downlink"] > 0
            operation("sync")
            first = database()["xray"]["ss2022"][0]["users"][0]["used"]
            assert first == sum(counters.values()) and first > 0
            operation("sync")
            assert database()["xray"]["ss2022"][0]["users"][0]["used"] == first
            assert database()["xray"]["ss2022"][1]["users"][0]["used"] == 0
            print("PASS generated SS2022: TCP/UDP, positive uplink/downlink, exact sum, repeated sync and port isolation")

            operation("disable", "default-a")
            traffic(a, user_a, False)
            traffic(b, user_b)
            operation("enable", "default-a")
            traffic(a, user_a)
            operation("sync")
            assert database()["xray"]["ss2022"][0]["users"][0]["used"] > first
            print("PASS last user disable closes its port, sibling remains usable, re-enable and restart accounting")

            operation("route", a, "chain:test-relay")
            traffic(a, user_a)
            routed = sum(stats(binary, relay_api, "inbound>>>relay").values())
            assert routed > 0
            traffic(b, user_b)
            assert sum(stats(binary, relay_api, "inbound>>>relay").values()) == routed
            relay.terminate()
            relay.wait(timeout=5)
            traffic(a, user_a, False)
            traffic(b, user_b)
            operation("route", a, "default")
            traffic(a, user_a)
            print("PASS TCP/UDP use assigned relay; sibling bypasses relay; unavailable UDP never falls back; clear restores direct")

            certs = cfg / "certs"
            certs.mkdir()
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(certs / "server.key"),
                            "-out", str(certs / "server.crt"), "-days", "1", "-subj", "/CN=localhost",
                            "-addext", "subjectAltName=DNS:localhost"],
                           capture_output=True, check=True)
            (certs / "hy2").mkdir()
            for name in ("server.crt", "server.key"):
                (certs / "hy2" / name).write_bytes((certs / name).read_bytes())
            state = database()
            state["singbox"] = {"trojan": [{"port": port(), "password": "native-a"}, {"port": port(), "password": "native-b"}],
                                "anytls": {"port": port(), "password": "native-anytls"},
                                "hy2": {"port": port(), "password": "native-hy2"},
                                "tuic": {"port": port(), "uuid": "3b57c991-27ae-4ccc-a94f-043536883301", "password": "native-tuic"}}
            (cfg / "db.json").write_text(json.dumps(state))
            operation("singbox-check")
            assert not (root / "vless-singbox.pid").exists()
            print("PASS native Sing-box check: multi-port Trojan, AnyTLS, HY2 and TUIC; inactive core stays stopped")
            operation("singbox-start")
            trojan_a, trojan_b = [row["port"] for row in database()["singbox"]["trojan"]]
            traffic(trojan_a, "native-a", protocol="trojan")
            traffic(trojan_b, "native-b", protocol="trojan")
            version = subprocess.run([singbox, "version"], capture_output=True, check=True).stdout
            if b"with_v2ray_api" in version:
                counters = dict(line.split() for line in operation("singbox-stats").decode().splitlines())
                prefix = f"user>>>trojan-default-{trojan_a}>>>traffic>>>"
                up, down = [int(counters[prefix + direction]) for direction in ("uplink", "downlink")]
                assert up > 0 and down > 0
                operation("sync")
                used = database()["singbox"]["trojan"][0]["users"][0]["used"]
                assert used == up + down
                operation("sync")
                assert database()["singbox"]["trojan"][0]["users"][0]["used"] == used
                print("PASS real Sing-box gRPC: positive uplink/downlink, exact per-port sum and idempotent cumulative sync")
            operation("singbox-disable", f"default-{trojan_a}")
            traffic(trojan_a, "native-a", False, protocol="trojan")
            traffic(trojan_b, "native-b", protocol="trojan")
            operation("singbox-enable", f"default-{trojan_a}")
            traffic(trojan_a, "native-a", protocol="trojan")
            operation("singbox-route", trojan_a, "chain:test-relay")
            traffic(trojan_a, "native-a", False, protocol="trojan")
            traffic(trojan_b, "native-b", protocol="trojan")
            operation("singbox-route", trojan_a, "default")
            traffic(trojan_a, "native-a", protocol="trojan")
            print("PASS real Sing-box Trojan TCP/UDP, per-port disable/re-enable, unavailable relay fails closed and sibling remains usable")
        finally:
            for service in ("vless-reality", "vless-singbox"):
                pidfile = root / f"{service}.pid"
                if pidfile.exists():
                    try:
                        os.kill(int(pidfile.read_text()), 15)
                    except ProcessLookupError:
                        pass
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            udp.close()
            web.shutdown()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
