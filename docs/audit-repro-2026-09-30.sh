#!/usr/bin/env bash
# Audit evidence: assertions confirm known defects, not successful fixes.
# Only synthetic fixtures and mocked service/network commands are used.
# Usage: AUDIT_REPO=/absolute/repo AUDIT_CASE=singbox-mode bash this-file singbox-mode
set -e
fixture=$(mktemp -d /tmp/surge-followup.XXXXXX)
AUDIT_CASE=${AUDIT_CASE:-${1:-}}
source "${AUDIT_REPO:?}/tests/lib/core-fixture.sh"
init_db
_header() { :; }; _line() { :; }; _pause() { :; }; show_sub_links() { :; }
_ok() { printf 'OK: %s\n' "$*"; }
case "$1" in
singbox-mode)
  umask 022
  _db_apply '.singbox.trojan={port:32101,password:"synthetic-secret",users:[{name:"alice",uuid:"synthetic-secret",enabled:true}]}'
  _listen_addr() { echo 127.0.0.1; }
  sing-box() { return 1; }
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/singbox-check"
  chmod +x "$fixture/singbox-check"
  SINGBOX_BIN="$fixture/singbox-check"
  generate_singbox_config || exit 1
  mode=$(stat -c '%a' "$CFG/singbox.json")
  jq -e '.inbounds[0].users[0].password == "synthetic-secret"' "$CFG/singbox.json" >/dev/null
  [[ "$mode" == 644 ]]
  echo "CONFIRMED singbox config=$mode cfg=$(stat -c '%a' "$CFG")"
  if [[ $EUID == 0 ]]; then
    chmod 711 "$fixture"
    python3 - "$CFG" <<'PY'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1])
os.setgroups([]); os.setgid(65534); os.setuid(65534)
assert 'synthetic-secret' in (root/'singbox.json').read_text()
try: (root/'db.json').read_text()
except PermissionError: pass
else: raise AssertionError('private database unexpectedly readable')
print('CONFIRMED unprivileged uid 65534 reads synthetic singbox secret; db inaccessible')
PY
  fi
  ;;
stop-snell)
  DISTRO=debian
  STANDALONE_PROTOCOLS=snell-v6
  touch "$fixture/instance.running"
  systemctl() { [[ "$1" == is-active && "${*: -1}" == vless-snellu-* ]]; }
  svc() { echo "$*" >> "$fixture/service-calls"; [[ "$1" != stop ]] || : > "$fixture/stopped"; }
  cleanup_hy2_nat_rules() { :; }
  stop_services > "$fixture/result" || exit 1
  [[ ! -f "$fixture/stopped" && -f "$fixture/instance.running" ]]
  grep '没有运行中的服务' "$fixture/result"
  echo 'CONFIRMED stop all missed managed Snell'
  ;;
nginx-rollback|nginx-restart|nginx-disable)
  DISTRO=debian
  mkdir -p "$fixture/root/etc/nginx/conf.d" "$fixture/root/etc/nginx/sites-enabled" "$fixture/root/var/www/html"
  printf 'old nginx config\n' > "$fixture/root/etc/nginx/conf.d/vless-sub.conf"
  if [[ "$1" != nginx-disable ]]; then printf 'old fake site\n' > "$fixture/root/etc/nginx/conf.d/vless-fake.conf"; fi
  printf 'existing unrelated site\n' > "$fixture/root/etc/nginx/sites-enabled/customer-site"
  printf '127.0.0.1 localhost\n' > "$fixture/root/etc/hosts"
  fixture_uuid=11111111-2222-4333-8444-555555555555
  printf '%s\n' "$fixture_uuid" > "$CFG/sub_uuid"
  _write_sub_info "$fixture_uuid" 18443 old.example false
  cp "$CFG/sub.info" "$fixture/sub.info.before"
  check_cmd() { return 0; }; is_internal_port_occupied() { :; }
  ss() { :; }; netstat() { :; }
  get_connection_addresses() { echo '192.0.2.1|'; }
  generate_sub_files() { mkdir -p "$CFG/subscription/$fixture_uuid"; }
  systemctl() { echo "$*" >> "$fixture/systemctl.calls"; return 1; }
  nginx() { [[ "$1" != -t || "$AUDIT_CASE" != nginx-rollback ]]; }
  fn=$(declare -f setup_subscription_interactive)
  fn=${fn//\/etc\//$fixture/root/etc/}; fn=${fn//\/var\/www\//$fixture/root/var/www/}
  eval "$fn"
  fn=$(declare -f manage_subscription)
  fn=${fn//\/etc\//$fixture/root/etc/}
  eval "$fn"
  if [[ "$1" == nginx-disable ]]; then
    manage_subscription <<< $'5\n0' > "$fixture/result" || :
    grep -q '^stop nginx$' "$fixture/systemctl.calls"
    [[ -f "$fixture/root/etc/nginx/sites-enabled/customer-site" ]]
    echo 'CONFIRMED disabling subscription stopped nginx with other enabled site'
  else
    setup_subscription_interactive <<< $'n\n19234\naudit.example\nn' > "$fixture/result" || exit 1
    if [[ "$1" == nginx-rollback ]]; then
      [[ ! -f "$fixture/root/etc/nginx/conf.d/vless-sub.conf" && ! -f "$fixture/root/etc/nginx/conf.d/vless-fake.conf" ]]
      ! cmp -s "$CFG/sub.info" "$fixture/sub.info.before"
      grep -q 'audit.example' "$fixture/root/etc/hosts"
      echo 'CONFIRMED failed nginx validation lost old configs and changed metadata/hosts'
    else
      grep -q '订阅服务已配置' "$fixture/result"
      grep -q '^restart nginx$' "$fixture/systemctl.calls"
      echo 'CONFIRMED failed restart reported configured successfully'
    fi
  fi
  ;;
snell-edit)
  DISTRO=debian
  fixture_id=111111111111111111111111
  mkdir -p "$CFG/snell-users"
  printf 'listen = 127.0.0.1:32102\npsk = syntheticpsk\n' > "$CFG/snell-users/$fixture_id.conf"
  _db_apply --arg id "$fixture_id" '.xray["snell-v5"]=[{snell_id:$id,port:32102,psk:"syntheticpsk",users:[{name:"alice",uuid:"syntheticpsk",enabled:true}]}] | .meta.snell_users["snell-v5"]=true'
  _show_users_list() { :; }; sync_all_user_traffic() { :; }; _listen_addr() { echo 127.0.0.1; }
  _snell_update_counter_port() { :; }; _snell_write_service() { :; }; _snell_prepare_user() { return 0; }; _snell_user_share() { :; }
  svc() {
    case "$1" in
      status) [[ -f "$fixture/instance.running" ]] ;;
      enable|is-enabled) return 0 ;;
      start|restart) touch "$fixture/instance.running"; echo "$1" >> "$fixture/service-calls" ;;
      stop) rm -f "$fixture/instance.running" ;;
      *) return 1 ;;
    esac
  }
  [[ ! -f "$fixture/instance.running" ]]
  _snell_edit_user snell-v5 <<< $'alice\nn\nn\n\ny' || exit 1
  [[ -f "$fixture/instance.running" ]]
  echo 'CONFIRMED edit started previously stopped enabled Snell instance'
  ;;
snell-prompt-lock)
  nft() { :; }; _snell_nft_ready() { :; }
  read() { touch "$fixture/prompt"; while [[ ! -f "$fixture/release" ]]; do sleep 0.05; done; return 1; }
  (_snell_add_user snell-v5 > "$fixture/add.log" 2>&1 || :) & worker=$!
  for ((n=0;n<100;n++)); do [[ -f "$fixture/prompt" ]] && break; sleep 0.02; done
  [[ -f "$fixture/prompt" ]]
  exec {audit_fd}> "$DB_LOCK_FILE"
  if flock -n "$audit_fd"; then echo 'unexpected unlocked prompt'; exit 1; fi
  touch "$fixture/release"; wait "$worker"
  flock -n "$audit_fd"
  echo 'CONFIRMED database lock held while waiting for interactive input'
  ;;
traffic-gap)
  _db_apply '.xray.vless={port:32103,users:[{name:"alice",uuid:"synthetic",used:0,enabled:true}]}'
  printf '{"inbounds":[],"api":{"services":["StatsService"]}}\n' > "$CFG/config.json"
  printf '100\n' > "$fixture/counter"; echo old > "$fixture/epoch"
  _core_traffic_epoch() { cat "$fixture/epoch"; }
  xray_api_query() { jq -n --argjson n "$(cat "$fixture/counter")" '{stat:[{name:"user>>>alice@vless>>>traffic>>>uplink",value:$n}]}'; }
  generate_xray_config() { cp "$CFG/config.json" "$XRAY_CONFIG_OUTPUT"; }
  cat > "$fixture/validator" <<'EOF'
#!/usr/bin/env bash
# Audit evidence: assertions confirm known defects, not successful fixes.
# Only synthetic fixtures and mocked service/network commands are used.
# Usage: AUDIT_REPO=/absolute/repo AUDIT_CASE=singbox-mode bash this-file singbox-mode
echo 150 > "$COUNTER_FILE"
EOF
  chmod +x "$fixture/validator"
  XRAY_BIN="$fixture/validator"; export COUNTER_FILE="$fixture/counter"
  svc() { case "$1" in status) return 0 ;; is-enabled) return 1 ;; restart) echo new > "$fixture/epoch"; echo 0 > "$fixture/counter" ;; *) return 1 ;; esac; }
  _rebuild_core_config xray true || exit 1
  echo 10 > "$fixture/counter"
  _flush_core_traffic xray
  used=$(jq -r '.xray.vless.users[0].used' "$DB_FILE")
  [[ "$used" == 110 ]]
  echo "CONFIRMED restart accounting=$used expected=160 discarded=50 bytes"
  ;;
snell-alert)
  _db_apply '.meta.snell_users["snell-v5"]=true | .xray["snell-v5"]=[{snell_id:"111111111111111111111111",port:32102,psk:"syntheticpsk",users:[{name:"alice",uuid:"syntheticpsk",used:85,quota:100,enabled:true}]}]'
  _snell_account_traffic() { :; }
  tg_get_config() { echo 90; }
  tg_send_quota_alert() { echo "$*" >> "$fixture/alert"; }
  _snell_sync_traffic || exit 1
  [[ -s "$fixture/alert" ]]
  echo 'CONFIRMED Snell alerted at 85 percent despite configured threshold 90'
  ;;
xray-alert)
  _db_apply '.xray.vless={port:32103,users:[{name:"alice",uuid:"synthetic",used:75,quota:100,enabled:true}]}'
  _snell_sync_traffic() { :; }; check_daily_report() { :; }
  _pgrep() { [[ "$1" == xray ]]; }
  _core_traffic_epoch() { echo synthetic; }
  xray() { echo '{"stat":[{"name":"user>>>alice@vless>>>traffic>>>uplink","value":0}]}'; }
  tg_get_config() { echo 70; }
  tg_send_quota_alert() { echo "$*" >> "$fixture/alert"; }
  sync_all_user_traffic false || exit 1
  [[ ! -f "$fixture/alert" ]]
  echo 'CONFIRMED Xray omitted 75 percent alert despite configured threshold 70'
  ;;
realm-config)
  ensure_realm_dir() { mkdir -p "$fixture/realm"; }
  fn=$(declare -f realm_generate_config)
  fn=${fn//\/etc\/vless-reality\/realm\//$fixture/realm/}
  eval "$fn"
  ensure_realm_dir
  echo '[{"transport":"udp","listen_host":"::1","listen_port":32104,"remote_host":"127.0.0.1","remote_port":32105},{"transport":"tcp","listen_host":"127.0.0.1","listen_port":32106,"remote_host":"127.0.0.1","remote_port":32107}]' > "$fixture/realm/rules.json"
  realm_generate_config || exit 1
  python3 - "$fixture/realm/config.toml" <<'PY'
import pathlib, sys, tomllib
data=tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert data['network']=={'no_tcp':False,'use_udp':True}
assert data['endpoints'][0]['no_tcp'] is True
assert 'network' not in data['endpoints'][0]
assert 'network' not in data['endpoints'][1]
assert data['endpoints'][0]['listen']=='::1:32104'
print('CONFIRMED Realm transport flags outside endpoint.network; IPv6 host lacks brackets')
PY
  ;;
realm-counter)
  iptables() {
    printf '1 100 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:443\n1 200 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:4430\n'
  }
  measured=$(realm_get_traffic_bytes 443 tcp)
  [[ "$measured" == 300 ]]
  echo "CONFIRMED Realm port 443 counted 4430 too: measured=$measured expected=100"
  ;;
cron-race)
  echo '0 0 * * * existing-backup' > "$fixture/crontab"
  crontab() {
    if [[ "$1" == -l ]]; then
      local snapshot
      snapshot=$(cat "$fixture/crontab")
      touch "$fixture/read.$BASHPID"
      while [[ $(find "$fixture" -maxdepth 1 -name 'read.*' | wc -l) -lt 2 ]]; do sleep 0.02; done
      printf '%s\n' "$snapshot"
    else
      local replacement
      replacement=$(cat)
      if [[ "$replacement" == *job-A* ]]; then
        while [[ ! -f "$fixture/written-B" ]]; do sleep 0.02; done
        printf '%s\n' "$replacement" > "$fixture/crontab"
      else
        printf '%s\n' "$replacement" > "$fixture/crontab"
        touch "$fixture/written-B"
      fi
    fi
  }
  install_cron_entry tag-A '* * * * * job-A # tag-A' & worker_a=$!
  install_cron_entry tag-B '* * * * * job-B # tag-B' & worker_b=$!
  wait "$worker_a"; wait "$worker_b"
  grep -q existing-backup "$fixture/crontab"
  grep -q job-A "$fixture/crontab"
  ! grep -q job-B "$fixture/crontab"
  echo 'CONFIRMED concurrent crontab writers lost one newly installed job'
  ;;
cron-read-failure)
  echo '0 0 * * * existing-backup' > "$fixture/crontab"
  crontab() { if [[ "$1" == -l ]]; then return 1; else cat > "$fixture/crontab"; fi; }
  install_cron_entry sync-traffic '* * * * * new-sync # sync-traffic'
  ! grep -q existing-backup "$fixture/crontab"
  echo 'CONFIRMED crontab read failure overwrote existing jobs'
  ;;
*) exit 2 ;;
esac
printf 'FIXTURE %s\n' "$fixture"
