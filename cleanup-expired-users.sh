#!/bin/bash

set -euo pipefail

USER_EXPIRY_FILE="${USER_EXPIRY_FILE:-/etc/ErwanScript/user-expiry.txt}"
XRAY_EXPIRY_FILE="${XRAY_EXPIRY_FILE:-/etc/ErwanScript/xray-expiry.txt}"
XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
MULTILOGIN_FILE="${MULTILOGIN_FILE:-/etc/ErwanScript/multilogin.txt}"
STATE_DIR="${USER_LOCK_STATE_DIR:-/etc/ErwanScript/user-lock}"
LOG_FILE="${USER_CLEANUP_LOG:-/etc/ErwanScript/logs/cleanup-expired-users.log}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

delete_record_key() {
    local file="$1"
    local key="$2"

    [ -f "$file" ] || return 0
    awk -v target="$key" '$1 != target' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
}

expiry_for_user() {
    local username="$1"
    chage -l "$username" 2>/dev/null | awk -F': ' '/Account expires/ { print $2 }'
}

is_expired() {
    local expiry="$1"
    local expiry_ts now_ts

    case "$expiry" in
        ""|never|Never)
            return 1
            ;;
    esac

    expiry_ts="$(date -d "$expiry" +%s 2>/dev/null || true)"
    [ -n "$expiry_ts" ] || return 1
    now_ts="$(date +%s)"
    [ "$expiry_ts" -lt "$now_ts" ]
}

cleanup_user() {
    local username="$1"

    pkill -KILL -u "$username" 2>/dev/null || true
    userdel -f "$username" >/dev/null 2>&1 || true
    delete_record_key "$USER_EXPIRY_FILE" "$username"
    delete_record_key "$MULTILOGIN_FILE" "$username"
    rm -f "$STATE_DIR/freeze-$username"
    log "Deleted expired account '$username'"
}

cleanup_xray_user() {
    local username="$1"
    local tmpfile

    [ -f "$XRAY_CONFIG" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    tmpfile="$(mktemp)"
    if jq --arg user "$username" '
      (.inbounds[] | select(.protocol=="vless" or .protocol=="vmess" or .protocol=="trojan" or .protocol=="shadowsocks") | .settings.clients) |=
        map(select((.name // .email // "") != $user))
    ' "$XRAY_CONFIG" > "$tmpfile"; then
        chown --reference="$XRAY_CONFIG" "$tmpfile"
        chmod --reference="$XRAY_CONFIG" "$tmpfile"
        mv "$tmpfile" "$XRAY_CONFIG"
        chown root:root "$XRAY_CONFIG"
        chmod 0644 "$XRAY_CONFIG"
        log "Deleted expired Xray user '$username'"
    else
        rm -f "$tmpfile"
        log "Failed to update Xray config while deleting '$username'"
        return 1
    fi
}

restart_xray=0

if [ -f "$USER_EXPIRY_FILE" ]; then
    while IFS= read -r username; do
        [ -n "$username" ] || continue

        if ! id "$username" >/dev/null 2>&1; then
            delete_record_key "$USER_EXPIRY_FILE" "$username"
            delete_record_key "$MULTILOGIN_FILE" "$username"
            rm -f "$STATE_DIR/freeze-$username"
            log "Removed stale expiry record for missing account '$username'"
            continue
        fi

        expiry="$(expiry_for_user "$username")"
        if is_expired "$expiry"; then
            cleanup_user "$username"
            if [ -f "$XRAY_EXPIRY_FILE" ] && awk -v key="$username" '$1 == key { found=1 } END { exit(found ? 0 : 1) }' "$XRAY_EXPIRY_FILE"; then
                if cleanup_xray_user "$username"; then
                    delete_record_key "$XRAY_EXPIRY_FILE" "$username"
                    restart_xray=1
                fi
            fi
        fi
    done < <(awk 'NF { print $1 }' "$USER_EXPIRY_FILE")
fi

if [ -f "$XRAY_EXPIRY_FILE" ]; then
    today="$(date +"%Y-%m-%d")"
    while IFS= read -r username; do
        [ -n "$username" ] || continue
        if id "$username" >/dev/null 2>&1; then
            continue
        fi
        if cleanup_xray_user "$username"; then
            delete_record_key "$XRAY_EXPIRY_FILE" "$username"
            restart_xray=1
        fi
    done < <(awk -v d="$today" 'NF && $2 < d { print $1 }' "$XRAY_EXPIRY_FILE")
fi

if [ "$restart_xray" -eq 1 ]; then
    systemctl restart xray >/dev/null 2>&1 || true
    log "Restarted xray after expired account cleanup"
fi
