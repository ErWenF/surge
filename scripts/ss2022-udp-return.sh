#!/bin/sh
# Persist a narrowly scoped UDP reply route when a host's policy routing
# sends SS2022 replies through the wrong interface.
set -eu

usage() {
    echo "Usage: $0 {install|remove|status} CLIENT_IPV4 UDP_SOURCE_PORT PRIORITY" >&2
    exit 2
}

[ "$#" -eq 4 ] || usage
action=$1 client=$2 port=$3 priority=$4
case "$action" in install|remove|status|up|down) ;; *) usage ;; esac
case "$client" in *[!0-9.]*|''|.*|*..*|*.) usage ;; esac
old_ifs=$IFS; IFS=.; set -- $client; IFS=$old_ifs
[ "$#" -eq 4 ] || usage
for octet do
    [ -n "$octet" ] && [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || usage
done
case "$port:$priority" in *[!0-9:]*|:*|*:) usage ;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || usage
[ "$priority" -ge 1 ] && [ "$priority" -lt 32766 ] || usage
command -v ip >/dev/null 2>&1 || { echo "iproute2 is required" >&2; exit 1; }

name="vless-ss2022-return-$(printf '%s' "$client" | tr . -)-$port"
rule="to $client ipproto udp sport $port lookup main"
present() { ip -4 rule show | grep -E "^${priority}:" | grep -F "$rule" >/dev/null; }

case "$action" in
    up)
        present || ip -4 rule add pref "$priority" to "$client/32" ipproto udp sport "$port" lookup main
        exit $?
        ;;
    down)
        if present; then
            ip -4 rule del pref "$priority" to "$client/32" ipproto udp sport "$port" lookup main
        fi
        exit $?
        ;;
    status)
        if present; then echo "active: $name"; else echo "inactive: $name"; exit 1; fi
        exit 0
        ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "root is required" >&2; exit 1; }
installed=/usr/local/sbin/vless-ss2022-udp-return
if [ "$action" = install ]; then
    # Refuse priority collisions: a broad or differently scoped rule must not be displaced.
    if ip -4 rule show | grep -E "^${priority}:" | grep -vF "$rule" >/dev/null; then
        echo "priority $priority is already in use" >&2
        exit 1
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        unit="/etc/systemd/system/$name.service"
        [ ! -e "$unit" ] || { echo "unit already exists: $unit" >&2; exit 1; }
        if [ "$0" != "$installed" ]; then install -m 755 "$0" "$installed"; fi
        cat > "$unit" <<EOF
[Unit]
Description=Scoped SS2022 UDP reply route for $client:$port
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$installed up $client $port $priority
ExecStop=$installed down $client $port $priority

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        if ! systemctl enable --now "$name.service"; then
            systemctl disable --now "$name.service" >/dev/null 2>&1 || true
            rm -f "$unit"
            systemctl daemon-reload
            exit 1
        fi
    elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/local.d ]; then
        start="/etc/local.d/$name.start"
        [ ! -e "$start" ] || { echo "startup hook already exists: $start" >&2; exit 1; }
        if [ "$0" != "$installed" ]; then install -m 755 "$0" "$installed"; fi
        printf '#!/bin/sh\n%s up %s %s %s\n' "$installed" "$client" "$port" "$priority" > "$start"
        chmod 755 "$start"
        if ! rc-update add local default >/dev/null 2>&1 || ! "$installed" up "$client" "$port" "$priority"; then
            rm -f "$start"
            exit 1
        fi
    else
        echo "systemd or OpenRC local.d is required" >&2
        exit 1
    fi
    echo "installed: $name"
else
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        unit="/etc/systemd/system/$name.service"
        [ -f "$unit" ] || { echo "unit not found: $unit" >&2; exit 1; }
        systemctl disable --now "$name.service"
        rm -f "$unit"
        systemctl daemon-reload
    elif command -v rc-update >/dev/null 2>&1; then
        start="/etc/local.d/$name.start"
        [ -f "$start" ] || { echo "startup hook not found: $start" >&2; exit 1; }
        "$installed" down "$client" "$port" "$priority"
        rm -f "$start"
    else
        echo "systemd or OpenRC is required" >&2
        exit 1
    fi
    echo "removed: $name"
fi
