#!/usr/bin/env bash
# systemd-cron 没有 cron 守护进程：必须识别为可用 cron，且不得尝试安装 cron 包（二者互相冲突）。
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
for fn in cron_service_is_active ensure_cron_service_running; do
    eval "$(awk -v fn="$fn" 'index($0,fn"() {")==1 {on=1} on {print} on && $0=="}" {exit}' "$repo/vless-server.sh")"
    declare -F "$fn" >/dev/null || { echo "FAIL: 未能提取 $fn"; exit 1; }
done
fail() { echo "FAIL: $*"; exit 1; }
DISTRO=debian
# 只模拟 systemctl：$active_units 中的单元视为运行中
systemctl() { [[ "$1" == is-active ]] || return 0; local unit="${*: -1}"; [[ " $active_units " == *" $unit "* ]]; }
apt-get() { echo "apt-get $*" >> "$fixture/pkg"; return 0; }
dnf() { echo "dnf $*" >> "$fixture/pkg"; return 0; }
yum() { echo "yum $*" >> "$fixture/pkg"; return 0; }
apk() { echo "apk $*" >> "$fixture/pkg"; return 0; }
rc-service() { return 1; }
rc-update() { return 1; }

active_units="cron-update.path cron.target"
cron_service_is_active || fail "systemd-cron 未被识别为可用 cron"
ensure_cron_service_running false || fail "systemd-cron 下 allow_install=false 不应失败"
ensure_cron_service_running || fail "systemd-cron 下默认调用不应失败"
[[ ! -s "$fixture/pkg" ]] || fail "systemd-cron 下不应安装任何软件包: $(cat "$fixture/pkg")"

active_units="cron"
cron_service_is_active || fail "传统 cron 服务未被识别"

# 没有任何 cron 实现：本机若真的运行着 cron 进程则跳过（函数会扫描 /proc）
if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
    echo '注意：本机运行着真实 cron 进程，跳过"无 cron"断言'
else
    active_units=""
    if cron_service_is_active; then fail "没有 cron 时不应判定为可用"; fi
    : > "$fixture/pkg"
    if command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1 || [[ -x /usr/sbin/cron ]]; then
        echo '注意：本机存在 cron 二进制，跳过"不安装"断言'
    else
        if ensure_cron_service_running false; then fail "allow_install=false 且无 cron 时应返回失败"; fi
        [[ ! -s "$fixture/pkg" ]] || fail "allow_install=false 时不应安装软件包"
    fi
fi
echo 'PASS systemd-cron is detected as a working cron and never triggers a cron package install'
