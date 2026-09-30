#!/usr/bin/env python3
"""Loopback-only native Realm transport, Snell config and Nginx subscription probes."""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

worker = str(Path(__file__).with_name('optional-native-worker.sh'))

def free_port(family=socket.AF_INET):
    with socket.socket(family) as s:
        s.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        return s.getsockname()[1]

def wait_port(port, family=socket.AF_INET):
    for _ in range(60):
        try:
            with socket.socket(family) as s:
                s.settimeout(.1)
                s.connect(('::1' if family == socket.AF_INET6 else '127.0.0.1', port))
            return
        except OSError:
            time.sleep(.05)
    raise AssertionError('native TCP listener unavailable')

def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=3)

def realm_probe(binary):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        ports = [free_port() for _ in range(3)]
        ipv6 = free_port(socket.AF_INET6)
        rules = [dict(listen_host='127.0.0.1', listen_port=p, remote_host='127.0.0.1', remote_port=9, transport=t)
                 for p,t in zip(ports, ['tcp','udp','tcp+udp'])]
        rules.append(dict(listen_host='::1', listen_port=ipv6, remote_host='::1', remote_port=9, transport='tcp'))
        (root/'rules.json').write_text(json.dumps(rules))
        result = subprocess.run(['bash', worker, 'realm', str(root/'rules.json')],
                                env=dict(os.environ, fixture=tmp), capture_output=True, check=True, timeout=15)
        (root/'config.toml').write_bytes(result.stdout)
        with open(root/'realm.log','wb') as log:
            process = subprocess.Popen([binary,'-c',str(root/'config.toml')],stdout=log,stderr=log)
            try:
                wait_port(ports[0]); wait_port(ports[2]); wait_port(ipv6,socket.AF_INET6)
                time.sleep(.15)
                assert process.poll() is None
                # Inspect both kernel tables and ensure TCP/UDP exclusions hold.
                output = subprocess.check_output(['ss','-H','-lntu']).decode()
                for p,t in zip(ports,['tcp','udp','tcp+udp']):
                    rows = [row.split()[0] for row in output.splitlines() if row.split()[4].endswith(':'+str(p))]
                    assert ('tcp' in rows) == (t != 'udp'), (p,t,rows)
                    assert ('udp' in rows) == (t != 'tcp'), (p,t,rows)
            finally: stop(process)
    print('PASS native Realm TCP-only/UDP-only/both and IPv6 listeners')

def snell_probe(binary):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        port = free_port()
        config = root/'snell.conf'
        config.write_text(f'[snell-server]\nlisten = 127.0.0.1:{port}\npsk = syntheticpassword\nipv6 = true\n')
        with open(root/'snell.log','wb') as log:
            process = subprocess.Popen([binary,'-c',str(config)],stdout=log,stderr=log)
            try:
                wait_port(port)
                assert process.poll() is None
            finally: stop(process)
    print('PASS native Snell v5 accepts user config and listens on loopback (no Surge handshake)')

def nginx_probe(binary):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        root.chmod(0o755)
        port = free_port()
        uuid = '11111111-2222-4333-8444-555555555555'
        cfg = root/'cfg'
        sub = cfg/'subscription'/uuid
        sub.mkdir(parents=True)
        for directory in [cfg,cfg/'subscription',sub]: directory.chmod(0o755)
        for file in ['base64','clash.yaml','surge.conf']:
            (sub/file).write_text('synthetic-'+file)
            (sub/file).chmod(0o644)
        result = subprocess.run(['bash',worker,'nginx',uuid,str(port)],env=dict(os.environ,fixture=tmp),capture_output=True,check=True,timeout=15)
        # Another server in sites-enabled must survive subscription replacement.
        other_port=free_port()
        sentinel=root/'sentinel'; sentinel.write_text('other-site')
        sentinel.chmod(0o644)
        conf=root/'nginx.conf'
        server=result.stdout.decode()
        def write(include):
            temp_paths = '\n'.join(f'{kind}_temp_path {root}/{kind};' for kind in ['client_body','proxy','fastcgi','uwsgi','scgi'])
            conf.write_text(f'pid {root}/nginx.pid;\nerror_log {root}/error.log;\nevents {{}}\nhttp {{ access_log off; {temp_paths}\n{include}\nserver {{ listen 127.0.0.1:{other_port}; location / {{ root {root}; }} }} }}\n')
        def fetch(p,uri):
            with urllib.request.urlopen(f'http://127.0.0.1:{p}{uri}',timeout=2) as r: return r.read().decode()
        write(server)
        subprocess.run([binary,'-p',str(root)+'/', '-c',str(conf),'-t'],capture_output=True,check=True,timeout=5)
        process=subprocess.Popen([binary,'-p',str(root)+'/', '-c',str(conf),'-g','daemon off;'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            wait_port(port); wait_port(other_port)
            assert fetch(port,f'/sub/{uuid}/surge') == 'synthetic-surge.conf'
            assert fetch(port,f'/sub/{uuid}/clash') == 'synthetic-clash.yaml'
            assert fetch(port,f'/sub/{uuid}/v2ray') == 'synthetic-base64'
            subprocess.run(['bash',worker,'nginx-probe',uuid,str(port)],env=dict(os.environ,fixture=tmp),capture_output=True,check=True,timeout=20)
            try: fetch(port,'/sub/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/surge')
            except urllib.error.HTTPError as e: assert e.code==404
            else: raise AssertionError('unknown UUID is accessible')
            before=process.pid
            assert fetch(other_port,'/sentinel') == 'other-site'
            write('')
            subprocess.run([binary,'-p',str(root)+'/', '-c',str(conf),'-t'],capture_output=True,check=True,timeout=5)
            process.send_signal(1)
            time.sleep(.3)
            assert process.pid==before and process.poll() is None
            assert fetch(other_port,'/sentinel') == 'other-site'
            probe=subprocess.run(['bash',worker,'nginx-probe',uuid,str(port)],env=dict(os.environ,fixture=tmp),capture_output=True,timeout=20)
            assert probe.returncode != 0
        finally: stop(process)
    print('PASS native Nginx subscription endpoints, unknown UUID rejection and other-site reload continuity')

if __name__=='__main__':
    if os.environ.get('SURGE_NATIVE_NETNS') != '1':
        # The generated Nginx listener includes wildcard addresses; keep every
        # optional native probe in its own network namespace, including repeats.
        os.execvp('unshare', ['unshare','--net','bash','-c',
                  'ip link set lo up && export SURGE_NATIVE_NETNS=1 && exec python3 "$@"',
                  'native-probe',str(Path(__file__).resolve()),*sys.argv[1:]])
    realm_probe(sys.argv[1])
    snell_probe(sys.argv[2])
    nginx_probe(sys.argv[3])
