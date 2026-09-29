#!/usr/bin/env python3
"""Exercise Xray SS2022 single-user and multi-user authentication locally."""

import base64
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def key(size):
    return base64.b64encode(os.urandom(size)).decode()


def config_file(directory, name, data):
    path = directory / (name + ".json")
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def start_xray(binary, config):
    checked = subprocess.run([binary, "run", "-test", "-c", str(config)], capture_output=True)
    if checked.returncode:
        raise RuntimeError("Xray rejected a test configuration")
    return subprocess.Popen([binary, "run", "-c", str(config)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def await_port(port):
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), 0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Xray listener did not start")


def socks_http(socks_port, web_port):
    try:
        with socket.create_connection(("127.0.0.1", socks_port), 2) as sock:
            sock.settimeout(2)
            sock.sendall(b"\x05\x01\x00")
            if sock.recv(2) != b"\x05\x00":
                return "socks-auth"
            sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + web_port.to_bytes(2, "big"))
            if sock.recv(2) != b"\x05\x00":
                return "socks-connect"
            sock.recv(8)
            sock.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
            return "ok" if b"200 OK" in sock.recv(512) else "http-response"
    except (OSError, TimeoutError):
        return "timeout"


def socks_udp(socks_port, echo_port):
    try:
        with socket.create_connection(("127.0.0.1", socks_port), 2) as control:
            control.settimeout(2)
            control.sendall(b"\x05\x01\x00")
            if control.recv(2) != b"\x05\x00":
                return False
            control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            reply = control.recv(10)
            if len(reply) != 10 or reply[:2] != b"\x05\x00":
                return False
            relay_port = int.from_bytes(reply[-2:], "big")
            payload = b"ss2022-udp-check"
            packet = b"\x00\x00\x00\x01\x7f\x00\x00\x01" + echo_port.to_bytes(2, "big") + payload
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.settimeout(3)
                udp.sendto(packet, ("127.0.0.1", relay_port))
                response, _ = udp.recvfrom(512)
                return response.endswith(payload)
    except (OSError, TimeoutError):
        return False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        pass


def udp_echo(sock):
    while True:
        try:
            payload, source = sock.recvfrom(512)
            sock.sendto(payload, source)
        except OSError:
            return


def main(binary):
    server_key, default_key, user_key = key(16), key(16), key(16)
    ss_port, socks_port, api_port = free_port(), free_port(), free_port()
    while len({ss_port, socks_port, api_port}) != 3:
        socks_port = free_port()
        api_port = free_port()
    web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    threading.Thread(target=web.serve_forever, daemon=True).start()
    threading.Thread(target=udp_echo, args=(udp,), daemon=True).start()
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        try:
            for mode in ("single", "multi", "disabled"):
                settings = {"method": "2022-blake3-aes-128-gcm", "password": server_key,
                            "network": "tcp,udp"}
                if mode != "single":
                    settings["clients"] = [{"password": default_key, "email": "default@ss2022"}]
                    if mode == "multi":
                        settings["clients"].append({"password": user_key, "email": "alice@ss2022"})
                server_cfg = config_file(directory, "server", {
                    "api": {"tag": "api", "services": ["StatsService"]},
                    "stats": {},
                    "policy": {"levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}}},
                    "inbounds": [{"listen": "127.0.0.1", "port": ss_port,
                                 "protocol": "shadowsocks", "settings": settings},
                                 {"listen": "127.0.0.1", "port": api_port, "tag": "api",
                                  "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
                    "outbounds": [{"protocol": "freedom"}, {"protocol": "blackhole", "tag": "api"}],
                    "routing": {"rules": [{"type": "field", "inboundTag": ["api"],
                                           "outboundTag": "api"}]}})
                server = start_xray(binary, server_cfg)
                try:
                    await_port(ss_port)
                    await_port(api_port)
                    for label, password, expected in (
                        ("legacy", server_key, mode == "single"),
                        ("default", server_key + ":" + default_key, mode != "single"),
                        ("named", server_key + ":" + user_key, mode == "multi"),
                    ):
                        client_cfg = config_file(directory, "client", {
                            "inbounds": [{"listen": "127.0.0.1", "port": socks_port,
                                         "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
                            "outbounds": [{"protocol": "shadowsocks", "settings": {"servers": [{
                                "address": "127.0.0.1", "port": ss_port,
                                "method": "2022-blake3-aes-128-gcm", "password": password}]}}]})
                        client = start_xray(binary, client_cfg)
                        try:
                            await_port(socks_port)
                            tcp_ok = socks_http(socks_port, web.server_port) == "ok"
                            udp_ok = socks_udp(socks_port, udp.getsockname()[1])
                            print(f"{mode} {label}: TCP={tcp_ok} UDP={udp_ok}")
                            if tcp_ok != expected or udp_ok != expected:
                                raise AssertionError("Unexpected SS2022 authentication result")
                            if expected and mode != "single":
                                time.sleep(0.3)
                                query = subprocess.run(
                                    [binary, "api", "statsquery", f"--server=127.0.0.1:{api_port}",
                                     "-pattern", "user>>>"],
                                    capture_output=True, timeout=5)
                                if query.returncode:
                                    raise AssertionError("Xray stats API query failed")
                                stats = {entry["name"]: int(entry["value"])
                                         for entry in json.loads(query.stdout).get("stat", [])}
                                user = "alice" if label == "named" else label
                                email = f"user>>>{user}@ss2022>>>traffic>>>"
                                up = stats.get(email + "uplink", 0)
                                down = stats.get(email + "downlink", 0)
                                print(f"{mode} {label}: uplink={up > 0} downlink={down > 0}")
                                if up <= 0 or down <= 0:
                                    raise AssertionError("SS2022 per-user traffic counters missing")
                        finally:
                            client.terminate()
                            client.wait(timeout=5)
                finally:
                    server.terminate()
                    server.wait(timeout=5)
        finally:
            udp.close()
            web.shutdown()


if __name__ == "__main__":
    main(sys.argv[1])
