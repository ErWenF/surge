#!/usr/bin/env bash
set -e

repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
shell=$(command -v dash 2>/dev/null || command -v sh)
if [[ -n "$("$shell" -c 'printf %s "${BASH_VERSION:-}"')" ]]; then
    echo 'SKIP 缺 Bash 测试需要 dash 或其他非 Bash 的 /bin/sh'
    exit 0
fi
export BOOT_LOG="$fixture/log" FAKE_BIN="$fixture/bin" FAKE_BASH="$fixture/fake-bash"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BASH" <<'EOF'
#!/bin/sh
printf 'bash:%s:%s\n' "$1" "$2" >> "$BOOT_LOG"
EOF
chmod +x "$FAKE_BASH"

cat > "$FAKE_BIN/apk" <<'EOF'
#!/bin/sh
printf 'apk:%s\n' "$*" >> "$BOOT_LOG"
/bin/cp "$FAKE_BASH" "$FAKE_BIN/bash"
EOF
chmod +x "$FAKE_BIN/apk"

PATH="$FAKE_BIN" "$shell" "$repo/vless-server.sh" --help
grep -q '^apk:add --no-cache bash$' "$BOOT_LOG"
grep -Fq "bash:$repo/vless-server.sh:--help" "$BOOT_LOG"

rm -f "$FAKE_BIN/apk" "$FAKE_BIN/bash" "$BOOT_LOG"
cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/sh
printf 'apt:%s\n' "$*" >> "$BOOT_LOG"
if [ "$1" = install ]; then /bin/cp "$FAKE_BASH" "$FAKE_BIN/bash"; fi
EOF
chmod +x "$FAKE_BIN/apt-get"

PATH="$FAKE_BIN" "$shell" "$repo/vless-server.sh" --help
grep -q '^apt:update$' "$BOOT_LOG"
grep -q '^apt:install -y bash$' "$BOOT_LOG"
grep -Fq "bash:$repo/vless-server.sh:--help" "$BOOT_LOG"

rm -f "$FAKE_BIN/apt-get" "$FAKE_BIN/bash" "$BOOT_LOG"
if PATH="$FAKE_BIN" "$shell" "$repo/vless-server.sh" --help >"$fixture/out" 2>&1; then
    echo '缺少 Bash 和包管理器时应失败' >&2
    exit 1
fi
grep -q '未找到 Bash 或受支持的包管理器' "$fixture/out"

/bin/cp "$FAKE_BASH" "$FAKE_BIN/bash"
PATH="$FAKE_BIN" "$shell" "$repo/vless-server.sh" --help
grep -Fq "bash:$repo/vless-server.sh:--help" "$BOOT_LOG"

launcher=$(awk '/^```sh$/ {found=1; next} found && /^```$/ {exit} found {print}' "$repo/README.md")
[[ -n "$launcher" ]]
rm -f "$FAKE_BIN/bash" "$BOOT_LOG"
mkdir -p "$fixture/download"

cat > "$FAKE_BIN/sh" <<'EOF'
#!/bin/sh
exec /bin/sh "$@"
EOF
chmod +x "$FAKE_BIN/sh"
cat > "$fixture/fake-curl" <<'EOF'
#!/bin/sh
printf 'curl:%s\n' "$*" >> "$BOOT_LOG"
printf '%s\n' 'echo downloaded >> "$BOOT_LOG"' > vless-server.sh
EOF
chmod +x "$fixture/fake-curl"
cat > "$FAKE_BIN/apk" <<'EOF'
#!/bin/sh
printf 'apk:%s\n' "$*" >> "$BOOT_LOG"
/bin/cp "$FAKE_CURL" "$FAKE_BIN/curl"
EOF
chmod +x "$FAKE_BIN/apk"
export FAKE_CURL="$fixture/fake-curl"

(cd "$fixture/download" && PATH="$FAKE_BIN" "$shell" -c "$launcher")
grep -q '^apk:add --no-cache curl ca-certificates$' "$BOOT_LOG"
grep -q '^downloaded$' "$BOOT_LOG"
grep -q 'raw.githubusercontent.com/ErWenF/surge/main/vless-server.sh' "$BOOT_LOG"

rm -f "$FAKE_BIN/apk" "$FAKE_BIN/curl" "$BOOT_LOG"
cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/sh
printf 'apt:%s\n' "$*" >> "$BOOT_LOG"
if [ "$1" = install ]; then /bin/cp "$FAKE_CURL" "$FAKE_BIN/curl"; fi
EOF
chmod +x "$FAKE_BIN/apt-get"
mkdir -p "$fixture/download-debian"

(cd "$fixture/download-debian" && PATH="$FAKE_BIN" "$shell" -c "$launcher")
grep -q '^apt:update$' "$BOOT_LOG"
grep -q '^apt:install -y curl ca-certificates$' "$BOOT_LOG"
grep -q '^downloaded$' "$BOOT_LOG"

rm -f "$FAKE_BIN/apt-get" "$FAKE_BIN/curl" "$BOOT_LOG"
cat > "$FAKE_BIN/wget" <<'EOF'
#!/bin/sh
printf 'wget:%s\n' "$*" >> "$BOOT_LOG"
printf '%s\n' 'echo downloaded >> "$BOOT_LOG"' > vless-server.sh
EOF
chmod +x "$FAKE_BIN/wget"
mkdir -p "$fixture/download-wget"

(cd "$fixture/download-wget" && PATH="$FAKE_BIN" "$shell" -c "$launcher")
grep -q '^wget:-O vless-server.sh https://raw.githubusercontent.com/ErWenF/surge/main/vless-server.sh$' "$BOOT_LOG"
grep -q '^downloaded$' "$BOOT_LOG"

echo 'PASS Bash 引导与 Alpine、Debian/Ubuntu、现有 wget 的安装命令'
