#!/usr/bin/env bash
# Private nginx paths and mocked service/removal commands; exit before actual uninstall cleanup.
source "$(dirname "$0")/../tests/lib/core-fixture.sh" || exit 1
trap 'rm -rf "$fixture"' EXIT
init_db
nginx_root="$fixture/nginx"
mkdir -p "$nginx_root/conf.d" "$nginx_root/sites-enabled" "$nginx_root/sites-available" "$nginx_root/http.d"
printf 'server { listen 18081; return 200 "tenant"; }\n' > "$nginx_root/nginx.conf"
printf '# managed subscription\n' > "$nginx_root/conf.d/vless-subscription.conf"
eval "$(declare -f do_uninstall | sed "s|/etc/nginx|$nginx_root|g")"
check_installed() { return 0; }
_snell_managed() { return 1; }
get_installed_protocols() { echo vless; }
stop_services() { :; }
db_get_warp_mode() { :; }
force_cleanup() { :; }
# Stop the test before the later service/config deletion stage.
stop_tg_user_bot_service() { exit 0; }
command() {
    if [[ "$1" == -v && "$2" == nginx ]]; then return 0; fi
    builtin command "$@"
}
systemctl() {
    printf '%s\n' "$*" >> "$fixture/system-events"
    [[ "$1" != is-active ]]
}
nginx() { return 0; }
svc() { printf '%s\n' "$*" >> "$fixture/service-events"; }
# The only removal actually performed is our own fixture subscription file.
rm() {
    local path
    for path in "$@"; do
        [[ "$path" == -* ]] && continue
        if [[ "$path" == "$nginx_root/"* ]]; then builtin command rm -f -- "$path"; fi
    done
}
(do_uninstall <<< y) > "$fixture/uninstall-output" 2>&1
printf 'uninstall status=%s; other server block still exists=%s; nginx service actions=' "$?" "$(test -s "$nginx_root/nginx.conf" && echo yes || echo no)"
tr '\n' ',' < "$fixture/service-events"
printf '\n'
unset -f rm