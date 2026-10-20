#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'unset -f rm; rm -rf "$fixture"' EXIT
init_db
nginx_root="$fixture/nginx"
mkdir -p "$nginx_root"/{conf.d,sites-enabled,sites-available,http.d,custom}
printf 'server { listen 18081; return 200 "tenant"; }\n' > "$nginx_root/nginx.conf"
echo default-site > "$nginx_root/sites-enabled/default"
echo custom-site > "$nginx_root/custom/tenant.conf"
eval "$(declare -f do_uninstall | sed "s|/etc/nginx|$nginx_root|g")"
check_installed() { return 0; }
_snell_managed() { return 1; }
get_installed_protocols() { echo vless; }
stop_services() { :; }
db_get_warp_mode() { :; }
force_cleanup() { :; }
stop_tg_user_bot_service() { exit 0; }
command() {
    if [[ "$1" == -v && "$2" == nginx ]]; then return 0; fi
    builtin command "$@"
}
systemctl() { [[ "$1" != is-active ]]; }
nginx() { [[ "$failure" != validate ]]; }
svc() {
    echo "$*" >> "$fixture/services"
    case "$1" in status) [[ "$running" == true ]] ;; reload) [[ "$failure" != reload ]] ;; *) return 1 ;; esac
}
rm() {
    local path
    for path in "$@"; do
        [[ "$path" != -* ]] || continue
        [[ "$path" == "$nginx_root/"* ]] || { echo "unsafe test removal" >&2; return 1; }
        [[ "$failure" != remove ]] || return 1
        builtin command rm -f -- "$path" || return 1
    done
}
for running in true false; do
    for failure in none validate reload remove; do
        [[ "$running:$failure" != false:reload ]] || continue
        echo managed > "$nginx_root/sites-available/vless-owned"
        ln -sf ../sites-available/vless-owned "$nginx_root/sites-enabled/vless-owned"
        echo subscription > "$nginx_root/conf.d/vless-subscription.conf"
        : > "$fixture/services"
        rc=0; (do_uninstall <<< y) > "$fixture/output" 2>&1 || rc=$?
        ! grep -Eq '^(stop|disable|restart|start) ' "$fixture/services"
        [[ $(cat "$nginx_root/sites-enabled/default") == default-site ]]
        [[ $(cat "$nginx_root/custom/tenant.conf") == custom-site ]]
        grep -q tenant "$nginx_root/nginx.conf"
        if [[ "$failure" == none ]]; then
            [[ "$rc" == 0 && ! -e "$nginx_root/sites-available/vless-owned" && ! -L "$nginx_root/sites-enabled/vless-owned" ]]
            if [[ "$running" == true ]]; then grep -qx 'reload nginx' "$fixture/services"
            else ! grep -q '^reload ' "$fixture/services"; fi
        else
            [[ "$rc" == 1 && -L "$nginx_root/sites-enabled/vless-owned" ]]
            [[ $(cat "$nginx_root/sites-available/vless-owned") == managed ]]
            [[ $(cat "$nginx_root/conf.d/vless-subscription.conf") == subscription ]]
        fi
    done
done
echo 'PASS uninstall preserves inline/default/custom Nginx sites and stopped services; remove/validate/reload failures restore owned configs and links'
