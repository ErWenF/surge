"""Controlled TLS endpoints; no external domains, scans, or host config changes."""
import datetime
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time

library, fixture = map(Path, sys.argv[1:])
work = fixture / 'native-reality'
work.mkdir()
real_curl = subprocess.check_output(['bash', '-c', 'command -v curl'], text=True).strip()


def openssl(*args):
    subprocess.run(['openssl', *args], cwd=work, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3',
        '-keyout', 'ca.key', '-out', 'ca.pem', '-subj', '/CN=Reality test CA',
        '-addext', 'basicConstraints=critical,CA:TRUE')
openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'leaf.key',
        '-out', 'leaf.csr', '-subj', '/CN=probe.reality.test')
(work / 'issued').mkdir()
(work / 'index').touch()
(work / 'serial').write_text('01\n')
(work / 'ca.conf').write_text('''[ca]
default_ca=local
[local]
database=index
serial=serial
new_certs_dir=issued
certificate=ca.pem
private_key=ca.key
default_md=sha256
default_days=2
unique_subject=no
policy=policy
x509_extensions=leaf
[policy]
commonName=supplied
[leaf]
subjectAltName=DNS:*.reality.test
extendedKeyUsage=serverAuth
basicConstraints=critical,CA:FALSE
[mismatch]
subjectAltName=DNS:other.example
extendedKeyUsage=serverAuth
basicConstraints=critical,CA:FALSE
''')
now = datetime.datetime.now(datetime.timezone.utc)
for name, start, end, ext in [
        ('valid', now-datetime.timedelta(days=1), now+datetime.timedelta(days=2), 'leaf'),
        ('short', now-datetime.timedelta(hours=1), now+datetime.timedelta(hours=12), 'leaf'),
        ('expired', now-datetime.timedelta(days=2), now-datetime.timedelta(hours=1), 'leaf'),
        ('mismatch', now-datetime.timedelta(days=1), now+datetime.timedelta(days=2), 'mismatch')]:
    openssl('ca', '-batch', '-notext', '-config', 'ca.conf', '-in', 'leaf.csr',
            '-out', name+'.pem', '-extensions', ext,
            '-startdate', start.strftime('%Y%m%d%H%M%SZ'),
            '-enddate', end.strftime('%Y%m%d%H%M%SZ'))

bin_dir = work / 'bin'
bin_dir.mkdir()
wrapper = bin_dir / 'curl'
wrapper.write_text('''#!/bin/sh
exec "$REALITY_REAL_CURL" "$@" --resolve "probe.reality.test:$REALITY_TEST_PORT:$REALITY_TEST_ADDRESS"
''')
wrapper.chmod(0o755)
environment = os.environ.copy()
environment.update(PATH=str(bin_dir)+os.pathsep+environment['PATH'],
                   REALITY_REAL_CURL=real_curl, CURL_CA_BUNDLE=str(work/'ca.pem'),
                   SSL_CERT_FILE=str(work/'ca.pem'), HTTPS_PROXY='http://127.0.0.1:9',
                   ALL_PROXY='http://127.0.0.1:9')


class Endpoint:
    def __init__(self, mode='ok', cert='valid', ipv6=False):
        self.mode = mode
        self.ipv6 = ipv6
        self.stop = threading.Event()
        self.connections = 0
        self.sni = []
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(work/(cert+'.pem'), work/'leaf.key')
        self.context.set_alpn_protocols(['http/1.1'] if mode == 'no_h2' else ['h2', 'http/1.1'])
        if mode == 'tls12':
            self.context.maximum_version = ssl.TLSVersion.TLSv1_2
        if mode == 'no_x25519':
            self.context.set_ecdh_curve('prime256v1')
        self.context.set_servername_callback(lambda sock, name, ctx: self.sni.append(name))
        self.listener = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET)
        self.listener.bind(('::1' if ipv6 else '127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.2)
        self.clients = []
        self.workers = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                raw, _ = self.listener.accept()
            except (TimeoutError, OSError):
                continue
            self.connections += 1
            count = self.connections
            self.clients.append(raw)
            worker = threading.Thread(target=self.handle, args=(raw, count), daemon=True)
            self.workers.append(worker)
            worker.start()

    def handle(self, raw, count):
        try:
            if self.mode == 'http_stall' or (self.mode == 'tls_stall' and count > 1):
                self.stop.wait(8)
                return
            raw.settimeout(3)
            with self.context.wrap_socket(raw, server_side=True) as conn:
                if conn.selected_alpn_protocol() == 'h2':
                    # Probe is handshake-only: consume EOF, not an HTTP/2 implementation.
                    conn.recv(1)
                    conn.unwrap()  # Complete TLS close_notify rather than a truncated stream.
                    return
                request = conn.recv(4096)
                if not request:
                    return
                code = b'403 Forbidden' if self.mode == 'http403' else b'200 OK'
                redirect = b''
                if self.mode.startswith('redirect'):
                    code = b'302 Found'
                    target = {
                        'redirect_cross': 'https://other.example/',
                        'redirect_relative': '/next',
                        'redirect_same': f'https://probe.reality.test:{self.port}/next',
                        'redirect_port': 'https://probe.reality.test:1/next',
                        'redirect_scheme': 'http://probe.reality.test/next',
                        'redirect_protocol_relative': '//other.example/next',
                    }[self.mode]
                    redirect = ('Location: '+target+'\r\n').encode()
                conn.sendall(b'HTTP/1.1 '+code+b'\r\n'+redirect+
                             b'Content-Length: 2\r\nConnection: close\r\n\r\nok')
        except (OSError, ssl.SSLError):
            pass
        finally:
            raw.close()

    def close(self):
        self.stop.set()
        self.listener.close()
        for client in self.clients:
            client.close()
        self.thread.join(2)
        for worker in self.workers:
            worker.join(2)


def probe(endpoint, expected, *, trust=True):
    env = environment.copy()
    env['REALITY_TEST_PORT'] = str(endpoint.port)
    env['REALITY_TEST_ADDRESS'] = '[::1]' if endpoint.ipv6 else '127.0.0.1'
    if not trust:
        env.pop('CURL_CA_BUNDLE')
        env.pop('SSL_CERT_FILE')
    start = time.monotonic()
    result = subprocess.run(['bash', '-c',
        'source "$1"; probe_reality_target probe.reality.test "$2" 1 3',
        'test', str(library), str(endpoint.port)], env=env,
        text=True, capture_output=True, timeout=10)
    elapsed = time.monotonic()-start
    if expected:
        fields = result.stdout.strip().split('\t')
        assert result.returncode == 0 and len(fields) == 2, (endpoint.mode, result.stderr)
        assert fields[0] == 'probe.reality.test' and fields[1].isdigit(), result.stdout
        assert endpoint.connections == 4, (endpoint.mode, endpoint.connections)
        assert endpoint.sni == ['probe.reality.test'] * 4, endpoint.sni
    else:
        assert result.returncode != 0 and not result.stdout and result.stderr, (endpoint.mode, result)
    assert elapsed < 7, (endpoint.mode, elapsed)
    print(f'PASS native {endpoint.mode}/{trust=} rc={result.returncode} elapsed={elapsed:.2f}s', flush=True)


for mode, cert, expected in [
    ('ok', 'valid', True), ('ok', 'short', True), ('http403', 'valid', True),
    ('redirect_relative', 'valid', True), ('redirect_same', 'valid', True),
    ('redirect_cross', 'valid', False), ('redirect_port', 'valid', False),
    ('redirect_scheme', 'valid', False), ('redirect_protocol_relative', 'valid', False),
    ('no_h2', 'valid', False), ('no_x25519', 'valid', False), ('tls12', 'valid', False),
    ('ok', 'expired', False), ('ok', 'mismatch', False),
    ('http_stall', 'valid', False), ('tls_stall', 'valid', False),
]:
    endpoint = Endpoint(mode, cert)
    try:
        probe(endpoint, expected)
    finally:
        endpoint.close()
endpoint = Endpoint()
try:
    probe(endpoint, False, trust=False)
finally:
    endpoint.close()

endpoint = Endpoint(ipv6=True)
try:
    probe(endpoint, True)
    print('PASS IPv6 HTTPS IP is reused with bracketed OpenSSL address', flush=True)
finally:
    endpoint.close()

# Both external timeout and the Bash fallback must terminate TERM-resistant commands.
for backend in ('native', 'missing', 'unsupported'):
    command = '''source "$1"
if [[ "$2" == missing ]]; then
    command() { if [[ "$1" == -v && "$2" == timeout ]]; then return 1; fi; builtin command "$@"; }
elif [[ "$2" == unsupported ]]; then
    command() { if [[ "$1" == timeout ]]; then return 64; fi; builtin command "$@"; }
fi
_reality_run_timeout 1 bash -c 'echo "$BASHPID" > "$REALITY_TIMEOUT_PID"; trap "" TERM; while :; do :; done'
'''
    environment['REALITY_TIMEOUT_PID'] = str(work/'timeout.pid')
    start = time.monotonic()
    result = subprocess.run(['bash', '-c', command, 'test', str(library), backend],
                            env=environment, capture_output=True, text=True, timeout=7)
    elapsed = time.monotonic()-start
    assert result.returncode != 0 and 1 <= elapsed < 5, (backend, elapsed, result)
    pid = int((work/'timeout.pid').read_text())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f'timed out process still alive: {pid}')
    print(f'PASS TERM-resistant timeout {backend=} rc={result.returncode} elapsed={elapsed:.2f}s; child reaped', flush=True)

result = subprocess.run(['bash', '-c', 'source "$1"; _reality_run_timeout 2 bash -c "exit 7"',
                         'test', str(library)], env=environment, capture_output=True, timeout=5)
assert result.returncode == 7, result
print('PASS timeout runner preserves a completed command exit status', flush=True)
