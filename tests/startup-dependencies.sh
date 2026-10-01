#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
trap 'rm -rf "$fixture"' EXIT

# Simulate minimal systems without invoking a real package manager.
command() {
    if [[ "$1" == -v ]]; then
        case "$2" in
            curl|jq|openssl) [[ " $mock_missing " != *" $2 "* ]]; return ;;
            apk|apt-get|dnf|yum) [[ "$2" == "$manager" ]]; return ;;
        esac
    fi
    builtin command "$@"
}
_has_ca_bundle() { [[ "$ca_ready" == true ]]; }
fake_install() {
    printf '%s:%s\n' "$manager" "$*" >> "$fixture/install.log"
    [[ "$mode" != fail ]] || return 1
    [[ "$mode" != update_fail || "$1" != update ]] || return 1
    if [[ "$mode" != stale && "$1" != update ]]; then
        mock_missing=""
        ca_ready=true
    fi
    return 0
}
apk() { fake_install "$@"; }
apt-get() { fake_install "$@"; }
dnf() { fake_install "$@"; }
yum() { fake_install "$@"; }
reset_case() {
    manager="$1" mode=ok mock_missing=jq ca_ready=true
    : > "$fixture/install.log"
}

for manager_name in apk apt-get dnf yum; do
    reset_case "$manager_name"
    ensure_startup_dependencies
    [[ -z "$mock_missing" ]]
    case "$manager" in
        apk) expected='apk:add --no-cache jq' ;;
        apt-get) expected=$'apt-get:update\napt-get:install -y jq' ;;
        *) expected="$manager:install -y jq" ;;
    esac
    [[ "$(cat "$fixture/install.log")" == "$expected" ]]
done
echo 'PASS missing jq is installed and rechecked with each supported package manager'

reset_case apk
mock_missing=""
ensure_startup_dependencies
[[ ! -s "$fixture/install.log" ]]
echo 'PASS ready systems do not run a package manager'

reset_case apk
mock_missing='curl jq openssl' ca_ready=false
ensure_startup_dependencies
[[ "$(cat "$fixture/install.log")" == 'apk:add --no-cache curl jq openssl ca-certificates' ]]
echo 'PASS all missing startup dependencies, including CA certificates, are installed together'

for failure in fail stale update_fail unsupported; do
    reset_case apk
    mode="$failure"
    [[ "$failure" != update_fail ]] || manager=apt-get
    [[ "$failure" != unsupported ]] || manager=none
    if ensure_startup_dependencies >"$fixture/out" 2>&1; then
        echo "Unexpected success: $failure" >&2
        exit 1
    fi
    [[ -s "$fixture/out" && "$mock_missing" == jq ]]
    if [[ "$failure" == update_fail ]]; then
        [[ "$(cat "$fixture/install.log")" == 'apt-get:update' ]]
    fi
done
echo 'PASS failed installs, absent package managers and unsuccessful postchecks return failure'

# Database migration and background version jobs must never start after failure.
check_root() { :; }
init_log() { echo log >> "$fixture/order"; }
init_db() { echo db >> "$fixture/order"; return 1; }
db_migrate_to_multiuser() { echo migrate >> "$fixture/order"; }
_update_all_versions_async() { echo versions >> "$fixture/order"; }
reset_case apk
mode=fail
: > "$fixture/order"
if main_menu >"$fixture/out" 2>&1; then exit 1; fi
[[ "$(cat "$fixture/order")" == log ]]

reset_case apk
: > "$fixture/order"
if main_menu >"$fixture/out" 2>&1; then exit 1; fi
[[ -z "$mock_missing" && "$(cat "$fixture/order")" == $'log\ndb' ]]
echo 'PASS dependency checks precede the database and failed initialization stops startup'
