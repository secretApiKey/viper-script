#!/bin/bash

set -euo pipefail

XRAY_EXPIRY_FILE="${XRAY_EXPIRY_FILE:-/etc/ErwanScript/xray-expiry.txt}"

username="${1:-}"

if [ -z "$username" ]; then
    echo "Usage: checkuser <username>"
    exit 1
fi

linux_exists="no"
linux_expiry="N/A"
xray_exists="no"
xray_expiry="N/A"

if id "$username" >/dev/null 2>&1; then
    linux_exists="yes"
    linux_expiry="$(chage -l "$username" 2>/dev/null | awk -F': ' '/Account expires/ { print $2 }')"
    [ -n "$linux_expiry" ] || linux_expiry="N/A"
fi

if [ -f "$XRAY_EXPIRY_FILE" ] && awk -v key="$username" '$1 == key { found=1 } END { exit(found ? 0 : 1) }' "$XRAY_EXPIRY_FILE"; then
    xray_exists="yes"
    xray_expiry="$(awk -v key="$username" '$1 == key { print $2; exit }' "$XRAY_EXPIRY_FILE")"
    [ -n "$xray_expiry" ] || xray_expiry="N/A"
fi

if [ "$linux_exists" = "yes" ] && [ "$xray_exists" = "yes" ]; then
    expiry="$linux_expiry"
elif [ "$linux_exists" = "yes" ]; then
    expiry="$linux_expiry"
elif [ "$xray_exists" = "yes" ]; then
    expiry="$xray_expiry"
else
    echo "User=$username | status=not-found"
    exit 1
fi

echo "User=$username | expiry=$expiry"
