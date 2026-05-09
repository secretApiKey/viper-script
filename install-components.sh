#!/bin/bash

set -euo pipefail

TARGET_DIR="${TARGET_DIR:-/etc/ErwanScript}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

extract_erwanssh_zip() {
    local zip_file="$1"
    local dest_dir="$2"
    local unzip_rc=0

    unzip -oq "$zip_file" -d "$dest_dir" || unzip_rc=$?
    if [ "$unzip_rc" -gt 1 ]; then
        echo "Failed to unpack $zip_file"
        return "$unzip_rc"
    fi
}

mkdir -p "$TARGET_DIR"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanMenu.sh" "$TARGET_DIR/ErwanMenu"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanNGINX.sh" "$TARGET_DIR/ErwanNGINX"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanXRAY.sh" "$TARGET_DIR/ErwanXRAY"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanWS.sh" "$TARGET_DIR/ErwanWS"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanTCP.sh" "$TARGET_DIR/ErwanTCP"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanTLS.sh" "$TARGET_DIR/ErwanTLS"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanDNS.sh" "$TARGET_DIR/ErwanDNS"
install -m 0755 "$SCRIPT_DIR/ErwanScript/ErwanUDP-auth.sh" "$TARGET_DIR/ErwanUDP-auth"
if [ -f "$SCRIPT_DIR/ErwanScript/limit-udp.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/ErwanScript/limit-udp.sh" "$TARGET_DIR/limit-udp.sh"
fi
install -m 0755 "$SCRIPT_DIR/cleanup-expired-users.sh" "$TARGET_DIR/cleanup-expired-users.sh"
install -m 0755 "$SCRIPT_DIR/extenduser.sh" "$TARGET_DIR/extenduser.sh"
install -m 0755 "$SCRIPT_DIR/checkuser.sh" "$TARGET_DIR/checkuser.sh"
install -m 0755 "$SCRIPT_DIR/activelogins.sh" "$TARGET_DIR/activelogins.sh"
if [ -f "$SCRIPT_DIR/uninstall.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$TARGET_DIR/uninstall.sh"
fi
if [ -f "$SCRIPT_DIR/uninstall-hard.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/uninstall-hard.sh" "$TARGET_DIR/uninstall-hard.sh"
fi
if [ -f "$SCRIPT_DIR/banner" ]; then
    install -m 0644 "$SCRIPT_DIR/banner" "$TARGET_DIR/banner"
fi
if [ -f "$SCRIPT_DIR/custom-http-methods.txt" ] && [ ! -f "$TARGET_DIR/custom-http-methods.txt" ]; then
    install -m 0644 "$SCRIPT_DIR/custom-http-methods.txt" "$TARGET_DIR/custom-http-methods.txt"
fi
if [ -f "$SCRIPT_DIR/limit-useradd.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/limit-useradd.sh" "$TARGET_DIR/limit-useradd.sh"
fi
if [ -f "$SCRIPT_DIR/ErwanSSH.zip" ]; then
    rm -rf "$TARGET_DIR/ErwanSSH"
    mkdir -p "$TARGET_DIR/ErwanSSH"
    extract_erwanssh_zip "$SCRIPT_DIR/ErwanSSH.zip" "$TARGET_DIR/ErwanSSH"
    find "$TARGET_DIR/ErwanSSH" -type d -exec chmod 0755 {} \;
    find "$TARGET_DIR/ErwanSSH" -type f -exec chmod 0644 {} \;
    find "$TARGET_DIR/ErwanSSH/bin" "$TARGET_DIR/ErwanSSH/libexec" "$TARGET_DIR/ErwanSSH/sbin" -type f -exec chmod 0755 {} \; 2>/dev/null || true
    find "$TARGET_DIR/ErwanSSH/etc" -maxdepth 1 -type f -name 'ssh_host_*_key' -exec chmod 0600 {} \; 2>/dev/null || true
    find "$TARGET_DIR/ErwanSSH/etc" -maxdepth 1 -type f -name 'ssh_host_*.pub' -exec chmod 0644 {} \; 2>/dev/null || true
else
    echo "WARNING: ErwanSSH.zip not found in $SCRIPT_DIR; skipping bundled ErwanSSH runtime install." >&2
fi

if [ -x "$TARGET_DIR/ErwanDNS" ]; then
    DOMAIN_FILE="$TARGET_DIR/domain" \
    NS_FILE="$TARGET_DIR/nameserver" \
    SERVER_KEY="$TARGET_DIR/server.key" \
    SERVER_PUB="$TARGET_DIR/server.pub" \
    STATUS_LOG="$TARGET_DIR/status.log" \
    DNSTT_BIN="$TARGET_DIR/dnstt-server" \
    "$TARGET_DIR/ErwanDNS" --install
fi

if [ -f "$SCRIPT_DIR/ErwanScript/limit-xray.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/ErwanScript/limit-xray.sh" "$TARGET_DIR/limit-xray.sh"
fi

if [ -f "$SCRIPT_DIR/cloudflare.defaults" ]; then
    install -m 0600 "$SCRIPT_DIR/cloudflare.defaults" "$TARGET_DIR/cloudflare.defaults"
fi

if [ -f "$SCRIPT_DIR/cloudflare.env" ]; then
    install -m 0600 "$SCRIPT_DIR/cloudflare.env" "$TARGET_DIR/cloudflare.env"
fi

dos2unix "$TARGET_DIR"/* >/dev/null 2>&1 || true
ln -sf "$TARGET_DIR/ErwanMenu" /usr/bin/menu
ln -sf "$TARGET_DIR/extenduser.sh" /usr/bin/extenduser
ln -sf "$TARGET_DIR/checkuser.sh" /usr/bin/checkuser
ln -sf "$TARGET_DIR/activelogins.sh" /usr/bin/activelogins
ln -sf "$TARGET_DIR/ErwanMenu" /usr/bin/xray-menu

echo "Installed VIPER PANEL stack into $TARGET_DIR"
echo "Main menu: /usr/bin/menu"
