#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
export RULES="$fixture/rules" CALLS="$fixture/calls"
: > "$RULES"
: > "$CALLS"
cat > "$fixture/bin/ip" <<'EOF'
#!/bin/sh
[ "$1" = -4 ] && [ "$2" = rule ] || exit 1
shift 2
case "$1" in
    show) cat "$RULES" ;;
    add)
        [ "$*" = 'add pref 8999 to 192.0.2.5/32 ipproto udp sport 11398 lookup main' ] || exit 1
        printf '8999:\tfrom all to 192.0.2.5 ipproto udp sport 11398 lookup main\n' > "$RULES"
        echo add >> "$CALLS" ;;
    del)
        [ "$*" = 'del pref 8999 to 192.0.2.5/32 ipproto udp sport 11398 lookup main' ] || exit 1
        : > "$RULES"
        echo del >> "$CALLS" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/ip"
export PATH="$fixture/bin:$PATH"
script="$repo/scripts/ss2022-udp-return.sh"
sh "$script" up 192.0.2.5 11398 8999
sh "$script" up 192.0.2.5 11398 8999
sh "$script" status 192.0.2.5 11398 8999 >/dev/null
[[ $(grep -c '^add$' "$CALLS") == 1 ]]
sh "$script" down 192.0.2.5 11398 8999
sh "$script" down 192.0.2.5 11398 8999
[[ $(grep -c '^del$' "$CALLS") == 1 ]]
if sh "$script" status 192.0.2.5 11398 8999 >/dev/null; then exit 1; fi
if sh "$script" up 192.0.2.999 11398 8999 >/dev/null 2>&1; then exit 1; fi
if sh "$script" up 192.0.2.5 0 8999 >/dev/null 2>&1; then exit 1; fi
echo 'PASS scoped UDP reply route validation and idempotence'
