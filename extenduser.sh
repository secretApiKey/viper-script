#!/bin/bash

set -euo pipefail

USER_EXPIRY_FILE="${USER_EXPIRY_FILE:-/etc/ErwanScript/user-expiry.txt}"
XRAY_EXPIRY_FILE="${XRAY_EXPIRY_FILE:-/etc/ErwanScript/xray-expiry.txt}"

username="${1:-}"
days="${2:-1}"

if [ -z "$username" ]; then
    echo "Usage: extenduser <username> [days]"
    exit 1
fi

if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -le 0 ]; then
    echo "Days must be a positive number."
    exit 1
fi

updated=0
linux_found=0
xray_found=0
linux_new_expiry="N/A"
xray_new_expiry="N/A"
final_expiry="N/A"

if id "$username" >/dev/null 2>&1; then
    linux_found=1
    current="$(chage -l "$username" 2>/dev/null | awk -F': ' '/Account expires/ { print $2 }')"
    if [ -z "$current" ] || [ "$current" = "never" ] || [ "$current" = "Never" ]; then
        expiry_ts="$(date +%s)"
        new_expiry="$(date -d "+$((days + 1)) days" +%Y-%m-%d)"
    else
        expiry_ts="$(date -d "$current" +%s)"
        new_expiry="$(date -d "@$((expiry_ts + days * 86400))" +%Y-%m-%d)"
    fi
    chage -E "$new_expiry" "$username"
    if [ -f "$USER_EXPIRY_FILE" ]; then
        awk -v key="$username" -v line="$username $new_expiry" '
            $1 == key { if (!done) { print line; done=1 } next }
            { print }
            END { if (!done) print line }
        ' "$USER_EXPIRY_FILE" > "${USER_EXPIRY_FILE}.tmp"
        mv "${USER_EXPIRY_FILE}.tmp" "$USER_EXPIRY_FILE"
    fi
    linux_new_expiry="$new_expiry"
    updated=1
fi

if [ -f "$XRAY_EXPIRY_FILE" ] && awk -v key="$username" '$1 == key { found=1 } END { exit(found ? 0 : 1) }' "$XRAY_EXPIRY_FILE"; then
    xray_found=1
    current="$(awk -v key="$username" '$1 == key { print $2; exit }' "$XRAY_EXPIRY_FILE")"
    if [ -z "$current" ]; then
        expiry_ts="$(date +%s)"
    else
        expiry_ts="$(date -d "$current" +%s)"
    fi
    new_expiry="$(date -d "@$((expiry_ts + days * 86400))" +%Y-%m-%d)"
    awk -v key="$username" -v line="$username $new_expiry" '
        $1 == key { if (!done) { print line; done=1 } next }
        { print }
        END { if (!done) print line }
    ' "$XRAY_EXPIRY_FILE" > "${XRAY_EXPIRY_FILE}.tmp"
    mv "${XRAY_EXPIRY_FILE}.tmp" "$XRAY_EXPIRY_FILE"
    xray_new_expiry="$new_expiry"
    updated=1
fi

if [ "$updated" -eq 0 ]; then
    echo "User=$username | status=not-found"
    exit 1
fi

if [ "$linux_found" -eq 1 ]; then
    final_expiry="$linux_new_expiry"
else
    final_expiry="$xray_new_expiry"
fi

echo "User=$username | expiry=$final_expiry"
