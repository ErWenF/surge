#!/usr/bin/env bash
# 发布包校验区分"校验值不一致"(1) 与"取不到发布方校验值"(2)，
# 安装入口只在取不到时提示 ALLOW_UNVERIFIED_DOWNLOADS，不一致时警告可能被篡改。
# 场景参考上游 mozisen/surge e498279 的 github-asset-verify.sh，按本 Fork 的函数结构改写。
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
for fn in _sha256_file _pinned_github_asset_sha256 _xray_release_asset_sha256 _verify_github_release_asset _install_binary; do
    eval "$(awk -v fn="$fn" 'index($0,fn"() {")==1 {on=1} on {print} on && $0=="}" {exit}' "$repo/vless-server.sh")"
    declare -F "$fn" >/dev/null || { echo "FAIL: 未能提取 $fn"; exit 1; }
done
asset_name=sing-box-1.14.0-linux-amd64.tar.gz
asset="https://github.com/SagerNet/sing-box/releases/download/v1.14.0/$asset_name"
printf 'fixture sing-box\n' > "$fixture/pkg"
good=$(_sha256_file "$fixture/pkg")
bad=$(printf '%064d' 0)
# api: ok（带正确 digest）/ baddigest / nodigest（无 digest 且无 checksum 资产）/ fail（限流）
curl() {
    local url='' dest=''
    while [[ $# -gt 0 ]]; do
        case "$1" in -o) shift; dest="$1" ;; https://*) url="$1" ;; esac
        shift
    done
    case "$url" in
        https://api.github.com/*)
            case "$api" in
                ok) jq -n --arg n "$asset_name" --arg d "sha256:$good" '{assets:[{name:$n,digest:$d}]}' ;;
                baddigest) jq -n --arg n "$asset_name" --arg d "sha256:$bad" '{assets:[{name:$n,digest:$d}]}' ;;
                nodigest) jq -n --arg n "$asset_name" '{assets:[{name:$n}]}' ;;
                *) return 22 ;;
            esac ;;
        *) cp "$fixture/pkg" "$dest" ;;
    esac
}
fail() { echo "FAIL: $*"; exit 1; }
verify() { local rc=0; _verify_github_release_asset SagerNet/sing-box 1.14.0 "$asset" "$fixture/pkg" || rc=$?; echo "$rc"; }

api=ok;        [[ "$(verify)" == 0 ]] || fail "digest 正确应通过"
api=baddigest; [[ "$(verify)" == 1 ]] || fail "digest 不一致应返回 1"
api=nodigest;  [[ "$(verify)" == 2 ]] || fail "无 digest 且无 checksum 资产应返回 2"
api=fail;      [[ "$(verify)" == 2 ]] || fail "API 失败应返回 2"

# 安装入口：两类失败都拒绝安装，提示不同。
_info() { :; }
_ok() { :; }
_err() { echo "err:$*" >> "$fixture/msgs"; }
_warn() { echo "warn:$*" >> "$fixture/msgs"; }
check_cmd() { return 1; }
install_like() {
    _install_binary sing-box SagerNet/sing-box \
        'https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-${version}-linux-amd64.tar.gz' \
        sing-box stable false 1.14.0
}

api=fail; : > "$fixture/msgs"
if install_like; then fail "取不到校验值时不应安装"; fi
grep -q 'API 请求失败' "$fixture/msgs" || fail "缺少 API 失败原因"
grep -q '限流' "$fixture/msgs" || fail "缺少限流提示"
grep -q 'ALLOW_UNVERIFIED_DOWNLOADS' "$fixture/msgs" || fail "取不到校验值时应说明显式跳过方式"

api=baddigest; : > "$fixture/msgs"
if install_like; then fail "校验值不一致时不应安装"; fi
grep -q '不匹配' "$fixture/msgs" || fail "缺少不一致原因"
grep -q '不要跳过校验' "$fixture/msgs" || fail "缺少可能被篡改的警告"
if grep -q 'ALLOW_UNVERIFIED_DOWNLOADS' "$fixture/msgs"; then fail "校验值不一致时不应引导跳过校验"; fi

echo 'PASS release verification separates mismatch (1) from unavailable checksum (2); bypass hint only when unavailable'
