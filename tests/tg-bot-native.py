"""Exercise resident Bash/curl against an isolated HTTP fixture, never Telegram."""
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

library, work = map(Path, sys.argv[1:])
cfg = work / 'cfg'
cfg.mkdir(exist_ok=True)
config = cfg / 'telegram.json'
config.write_text(json.dumps(dict(enabled=False, bot_token='100:admin_fixture',
                                 user_bot_token='200:user_fixture', user_bot_id='200',
                                 user_bot_enabled=True, user_bot_update_offset=0)))
(cfg / 'db.json').write_text(json.dumps(dict(xray=dict(ss2022=[
    dict(port=11111, users=[dict(name='alice', uuid='fixture-a', used=100, quota=1000,
                               enabled=True, telegram_chat_id='123', telegram_traffic_view='server_estimate')]),
    dict(port=22222, users=[dict(name='bob', uuid='fixture-b', used=200, quota=1000,
                               enabled=True, telegram_chat_id='456')])]), singbox={}, meta={})))
updates, replies, polls = [], [], []
condition = threading.Condition()
ready, failed_reply = threading.Event(), threading.Event()
fail_send = False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global fail_send
        params = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        method = self.path.rsplit('/', 1)[-1]
        assert self.path.startswith('/bot200:user_fixture/'), 'wrong bot used'
        if method == 'getUpdates':
            offset = int(params['offset'][0])
            timeout = int(params['timeout'][0])
            with condition:
                polls.append((offset, timeout))
                ready.set()
                pending = [u for u in updates if u['update_id'] >= offset]
                if not pending:
                    condition.wait(min(timeout, 4))
                    pending = [u for u in updates if u['update_id'] >= offset]
            response = dict(ok=True, result=pending)
        elif method == 'sendMessage':
            if fail_send:
                fail_send = False
                failed_reply.set()
                response = dict(ok=False, error_code=500)
            else:
                with condition:
                    replies.append((params['chat_id'][0], params['text'][0], time.monotonic()))
                    condition.notify_all()
                response = dict(ok=True)
        else:
            response = dict(ok=True, result={})
        body = json.dumps(response).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
driver = work / 'bot-worker.sh'
driver.write_text(f'''#!/bin/bash
export TEST_CFG='{cfg}'
source '{library}'
curl() {{
    local request
    [[ "$*" != *200:user_fixture* && "$*" != *100:admin_fixture* ]] || return 1
    request=$(cat)
    [[ "$request" == 'url = "https://api.telegram.org/bot200:user_fixture/'* ]] || return 1
    request="${{request/api.telegram.org/127.0.0.1:{server.server_port}}}"
    request="${{request/https:/http:}}"
    command curl "$@" <<< "$request"
}}
sync_all_user_traffic() {{ echo synced >> '{work}/sync'; sleep 0.2; }}
tg_run_user_bot
''')
driver.chmod(0o700)
log = work / 'bot.log'
process = None
service = None
unit_path = None


def wait_until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, 'timed out waiting for fixture'
        time.sleep(.05)


def enqueue(update_id, chat, command):
    with condition:
        updates.append(dict(update_id=update_id, message=dict(chat=dict(id=chat, type='private'), text=command)))
        condition.notify_all()


def assert_poll_lock_removed(label):
    lock = cfg / 'tg-user-bot.lock'
    if lock.exists():
        owner = (lock / 'pid').read_text().strip() if (lock / 'pid').exists() else 'missing'
        state = Path('/proc') / owner / 'stat'
        raise AssertionError(f'{label}: leaked lock owner={owner}, owner_alive={state.exists()}')


def exercise(label, main_pid):
    global fail_send
    assert ready.wait(8), 'worker never started long polling'
    owner = (cfg / 'tg-user-bot.lock' / 'pid').read_text().strip()
    parent = next(line.split()[1] for line in (Path('/proc') / owner / 'status').read_text().splitlines()
                  if line.startswith('PPid:'))
    assert int(parent) == main_pid, 'main process must wait for the actual poll lock owner'
    started = time.monotonic()
    enqueue(101, 123, '/help')
    wait_until(lambda: bool(replies))
    latency = replies[0][2] - started
    assert latency < 3, latency
    assert all(timeout == 20 for _, timeout in polls), polls
    with condition:
        updates.extend([
            dict(update_id=102, message=dict(chat=dict(id=123, type='private'), text='/traffic')),
            dict(update_id=103, message=dict(chat=dict(id=456, type='private'), text='/traffic')),
            dict(update_id=104, message=dict(chat=dict(id=999, type='private'), text='/traffic'))])
        condition.notify_all()
    wait_until(lambda: len(replies) >= 4)
    wait_until(lambda: json.loads(config.read_text())['user_bot_update_offset'] == 105)
    assert 'alice' in replies[1][1] and 'bob' not in replies[1][1], replies[1]
    assert 'bob' in replies[2][1] and 'alice' not in replies[2][1], replies[2]
    assert '总配额：1.95 KiB' in replies[1][1] and '剩余流量：1.76 KiB' in replies[1][1]
    assert '已使用：200 B' in replies[1][1] and '已使用：200 B' in replies[2][1]
    assert '总配额：1000 B' in replies[2][1] and '剩余流量：800 B' in replies[2][1]
    assert all('统计口径' not in text and '说明：' not in text and '估算不含' not in text for _, text, _ in replies)
    assert '尚未绑定' in replies[3][1]
    assert (work / 'sync').read_text().splitlines() == ['synced']
    fail_send = True
    failed_reply.clear()
    enqueue(105, 123, '/status')
    assert failed_reply.wait(8)
    assert json.loads(config.read_text())['user_bot_update_offset'] == 105, 'failed reply was acknowledged'
    wait_until(lambda: len(replies) >= 5)
    wait_until(lambda: json.loads(config.read_text())['user_bot_update_offset'] == 106)
    assert replies[4][1].startswith('账号状态\n') and '账号状态：正常' in replies[4][1]
    assert '到期时间：永不过期' in replies[4][1] and '已使用：' not in replies[4][1]
    assert (work / 'sync').read_text().splitlines() == ['synced'], 'status query triggered traffic sync'
    print(f'PASS {label}: long-poll reply {latency:.2f}s, isolated reports, one batch sync and transient-failure retry', flush=True)


try:
    with log.open('w') as output:
        process = subprocess.Popen(['bash', str(driver)], stdout=output, stderr=output, start_new_session=True)
        exercise('resident Bash/curl', process.pid)
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=8)
        process = None
    assert_poll_lock_removed('process group TERM')
    assert '200:user_fixture' not in log.read_text() and '100:admin_fixture' not in log.read_text()

    if os.environ.get('TG_BOT_SYSTEMD_TEST') == '1':
        assert shutil.which('systemctl') and Path('/run/systemd/system').exists()
        with condition:
            updates.clear()
            replies.clear()
            polls.clear()
        ready.clear()
        (work / 'sync').unlink()
        (cfg / '.tg-query-last-sync').unlink(missing_ok=True)
        data = json.loads(config.read_text())
        data['user_bot_update_offset'] = 0
        config.write_text(json.dumps(data))
        service = 'surge-tg-test-' + uuid.uuid4().hex[:12]
        unit_path = Path('/run/systemd/system') / (service + '.service')
        control = work / 'service-control.sh'
        control.write_text(f'''#!/bin/bash
set -e
export TEST_CFG='{cfg}'
source '{library}'
_tg_user_bot_manager() {{ echo systemd; }}
_tg_user_bot_service_file() {{ echo '{unit_path}'; }}
eval "$(declare -f _tg_write_user_bot_service | sed '1s/_tg_write_user_bot_service/_real_tg_write_user_bot_service/')"
_tg_write_user_bot_service() {{ _real_tg_write_user_bot_service "$1" "$2" '{driver}' /bin/bash; }}
tg_user_bot_service_action() {{
    case "$1" in
        active) systemctl is-active --quiet '{service}' ;;
        enabled) systemctl is-enabled --quiet '{service}' ;;
        enable|disable) systemctl "$1" --runtime '{service}' ;;
        reload) systemctl daemon-reload ;;
        *) systemctl "$1" '{service}' ;;
    esac
}}
remove_cron_entry() {{ echo migrated > '{work}/cron-migration'; }}
case "$1" in
    setup) setup_tg_user_bot_service true ;;
    stop) stop_tg_user_bot_service ;;
esac
''')
        subprocess.run(['bash', str(control), 'setup'], check=True, capture_output=True, timeout=20)
        assert (work / 'cron-migration').exists()
        subprocess.run(['systemd-analyze', 'verify', str(unit_path)], check=True, capture_output=True, timeout=10)
        main_pid = int(subprocess.check_output(['systemctl', 'show', '-p', 'MainPID', '--value', service]))
        exercise('isolated native systemd service', main_pid)
        for cycle in range(5):
            ready.clear()
            subprocess.run(['systemctl', 'restart', service], check=True, capture_output=True, timeout=20)
            subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True)
            # Stop during a live long poll, repeatedly exercising signal/cleanup ordering.
            assert ready.wait(8), 'restarted service did not resume polling'
            assert (cfg / 'tg-user-bot.lock').exists()
            subprocess.run(['bash', str(control), 'stop'], check=True, capture_output=True, timeout=20)
            assert subprocess.run(['systemctl', 'is-active', '--quiet', service]).returncode != 0
            assert subprocess.run(['systemctl', 'is-enabled', '--quiet', service]).returncode != 0
            assert_poll_lock_removed(f'systemd stop cycle {cycle + 1}')
        print('PASS native service setup/check, 5 restart/stop cycles, runtime-only autostart and cron migration hook', flush=True)
    else:
        print('SKIP native systemd bot lifecycle (TG_BOT_SYSTEMD_TEST unset)', flush=True)
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    if service is not None:
        subprocess.run(['systemctl', 'stop', service], capture_output=True, timeout=20)
        subprocess.run(['systemctl', 'disable', '--runtime', service], capture_output=True, timeout=10)
        unit_path.unlink(missing_ok=True)
        subprocess.run(['systemctl', 'daemon-reload'], capture_output=True, timeout=10)
        subprocess.run(['systemctl', 'reset-failed', service], capture_output=True, timeout=10)
    server.shutdown()
    server.server_close()
