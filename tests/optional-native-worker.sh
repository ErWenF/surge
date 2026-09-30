#!/usr/bin/env bash
set -e
source "$(dirname "$0")/lib/core-fixture.sh"
case "$1" in
    realm)
        ensure_realm_dir
        cp "$2" "$REALM_RULES_FILE"
        realm_generate_config
        cat "$REALM_CONFIG_FILE"
        ;;
    nginx)
        _subscription_render_nginx "$2" "$3" example.test false '' '' "$fixture/web"
        ;;
    nginx-probe)
        _subscription_probe "$2" "$3" false example.test "$fixture/probe"
        ;;
    *) exit 1 ;;
esac
