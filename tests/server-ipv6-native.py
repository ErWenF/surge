import http.server
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time

library, fixture = map(Path, sys.argv[1:])
cert, key = fixture / 'ipv6-cert.pem', fixture / 'ipv6-key.pem'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:::1',
                '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
requests = []
mode = 'valid'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if mode == 'stall':
            time.sleep(8)
            return
        if mode == 'invalid':
            body = b'192.0.2.1' if 'ipify' in self.path else b'<html>not an address</html>'
        else:
            body = b'2606:4700::abcd\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
server = Server(('::1', 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    shell = f'''
set -e
source "$TEST_LIBRARY"
curl() {{
    local args=("$@") last=$(($# - 1))
    local endpoint="${{args[$last]#https://}}"
    args[$last]="https://[::1]:{server.server_port}/$endpoint"
    command curl "${{args[@]}}" --cacert "$TEST_CERT"
}}
_probe_server_ipv6_egress
'''
    env = dict(os.environ, TEST_LIBRARY=str(library), TEST_CERT=str(cert), TEST_CFG=str(fixture / 'cfg'))
    result = subprocess.run(['bash', '-c', shell], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stdout.strip() == '2606:4700::abcd', result
    assert len(requests) == 3, requests
    mode = 'invalid'
    result = subprocess.run(['bash', '-c', shell], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and not result.stdout, result
    mode = 'stall'
    started = time.monotonic()
    result = subprocess.run(['bash', '-c', shell], env=env, capture_output=True, text=True, timeout=10)
    elapsed = time.monotonic() - started
    assert result.returncode != 0 and not result.stdout, result
    assert 2.5 <= elapsed < 6, elapsed
    print(f'PASS real IPv6 HTTPS probes, NAT64/HTML rejection and parallel timeout ({elapsed:.2f}s)')
finally:
    server.shutdown()
    server.server_close()
