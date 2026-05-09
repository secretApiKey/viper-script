#!/bin/bash

set -euo pipefail

LOG_FILE="${LOG_FILE:-/etc/ErwanScript/udp-auth.log}"

username=""
password=""
auth_payload="${AUTH_PAYLOAD:-}"
client_addr="${CLIENT_ADDR:-}"

log_auth() {
    local status="$1"
    local detail="${2:-}"
    local ts

    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
    {
        printf '%s status=%s' "$ts" "$status"
        [ -n "$client_addr" ] && printf ' addr=%s' "$client_addr"
        [ -n "$username" ] && printf ' user=%s' "$username"
        [ -n "$detail" ] && printf ' detail=%s' "$detail"
        printf '\n'
    } >> "$LOG_FILE" 2>/dev/null || true
}

if [ $# -ge 2 ] && [[ "$1" == *:* ]]; then
    client_addr="${1:-}"
    auth_payload="${2:-}"
elif [ $# -ge 2 ]; then
    username="${1:-}"
    password="${2:-}"
fi

if [ -n "$auth_payload" ]; then
    if [[ "$auth_payload" == *:* ]]; then
        username="${auth_payload%%:*}"
        password="${auth_payload#*:}"
    elif [[ "$auth_payload" == *" "* ]]; then
        username="${auth_payload%% *}"
        password="${auth_payload#* }"
    fi
fi

username="${username:-${USERNAME:-}}"
password="${password:-${PASSWORD:-}}"

if [ -z "$username" ] && [ -z "$password" ] && ! [ -t 0 ]; then
    stdin_payload="$(cat 2>/dev/null || true)"
    if [[ "$stdin_payload" == *:* ]]; then
        username="${stdin_payload%%:*}"
        password="${stdin_payload#*:}"
    elif [[ "$stdin_payload" == *" "* ]]; then
        username="${stdin_payload%% *}"
        password="${stdin_payload#* }"
    fi
fi

if [ -z "$username" ]; then
    read -r username || username=""
fi

if [ -z "$password" ]; then
    read -r password || password=""
fi

if [ -z "$username" ] || [ -z "$password" ]; then
    log_auth "reject" "missing-credentials"
    echo "missing credentials" >&2
    exit 1
fi

if ! id "$username" >/dev/null 2>&1; then
    log_auth "reject" "unknown-user"
    echo "authentication failed" >&2
    exit 1
fi

if python3 - "$username" "$password" <<'PY'
import sys

username = sys.argv[1]
password = sys.argv[2]

try:
    import pam  # type: ignore

    auth = pam.pam()
    ok = auth.authenticate(username, password, service="login")
except Exception:
    try:
        import PAM  # type: ignore

        auth = PAM.pam()
        auth.start("login")
        auth.set_item(PAM.PAM_USER, username)
        auth.set_item(PAM.PAM_CONV, lambda auth_ref, query_list, user_data: [(password, 0) for _query, _type in query_list])
        auth.authenticate()
        auth.acct_mgmt()
        ok = True
    except Exception:
        sys.exit(1)

if ok:
    print(username)
sys.exit(0 if ok else 1)
PY
then
    log_auth "accept"
else
    log_auth "reject" "pam-auth-failed"
    exit 1
fi
