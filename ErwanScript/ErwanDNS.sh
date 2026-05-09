#!/bin/bash

set -euo pipefail

DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
NS_FILE="${NS_FILE:-/etc/ErwanScript/nameserver}"
SERVER_KEY="${SERVER_KEY:-/etc/ErwanScript/server.key}"
SERVER_PUB="${SERVER_PUB:-/etc/ErwanScript/server.pub}"
STATUS_LOG="${STATUS_LOG:-/etc/ErwanScript/status.log}"
DNSTT_BIN="${DNSTT_BIN:-/etc/ErwanScript/dnstt-server}"
DNS_UNIT="${DNS_UNIT:-/lib/systemd/system/ErwanDNS.service}"
DNSTT_UNIT="${DNSTT_UNIT:-/lib/systemd/system/ErwanDNSTT.service}"
DNS_RULES_SCRIPT="${DNS_RULES_SCRIPT:-/usr/local/bin/erwan-dns-forwarding}"
DNS_RULES_UNIT="${DNS_RULES_UNIT:-/etc/systemd/system/erwan-dns-forwarding.service}"
DNS_PUBLIC_PORT="${DNS_PUBLIC_PORT:-53}"
DNSTT_PORT="${DNSTT_PORT:-5300}"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

trim_file() {
    tr -d '\r\n' < "$1"
}

generate_dnstt_keypair() {
    local pem_file key_text private_key public_key

    pem_file="$(mktemp)"
    if ! command -v openssl >/dev/null 2>&1; then
        rm -f "$pem_file"
        echo "openssl is required to generate DNSTT keys; set SERVER_KEY and SERVER_PUB first." >&2
        return 1
    fi

    if ! openssl genpkey -algorithm X25519 -out "$pem_file" >/dev/null 2>&1; then
        rm -f "$pem_file"
        echo "Failed to generate DNSTT keypair." >&2
        return 1
    fi

    key_text="$(openssl pkey -in "$pem_file" -text -noout 2>/dev/null || true)"
    rm -f "$pem_file"

    private_key="$(printf '%s\n' "$key_text" | awk '
        /^priv:$/ {mode="priv"; next}
        /^pub:$/ {mode="pub"; next}
        mode=="priv" && /^[[:space:][:xdigit:]:]+$/ {gsub(/[^[:xdigit:]]/, ""); printf "%s", $0; next}
        mode=="priv" {mode=""}
        END {print ""}
    ')"
    public_key="$(printf '%s\n' "$key_text" | awk '
        /^pub:$/ {mode="pub"; next}
        mode=="pub" && /^[[:space:][:xdigit:]:]+$/ {gsub(/[^[:xdigit:]]/, ""); printf "%s", $0; next}
        mode=="pub" {mode=""}
        END {print ""}
    ')"

    if [ "${#private_key}" -ne 64 ] || [ "${#public_key}" -ne 64 ]; then
        echo "Failed to parse generated DNSTT keypair." >&2
        return 1
    fi

    printf '%s\n' "$private_key" > "$SERVER_KEY"
    printf '%s\n' "$public_key" > "$SERVER_PUB"
    chmod 0600 "$SERVER_KEY"
    chmod 0644 "$SERVER_PUB"
}

ensure_dnstt_keys() {
    if [ -f "$SERVER_KEY" ] && [ -f "$SERVER_PUB" ]; then
        return 0
    fi

    if [ -f "$SERVER_KEY" ] || [ -f "$SERVER_PUB" ]; then
        echo "Both $SERVER_KEY and $SERVER_PUB must exist together." >&2
        return 1
    fi

    generate_dnstt_keypair
}

validate_dns_settings() {
    local ns_value

    ns_value="$(trim_file "$NS_FILE")"
    if [ -z "$ns_value" ]; then
        echo "Nameserver file is empty: $NS_FILE" >&2
        return 1
    fi

    case "$DNS_PUBLIC_PORT" in
        ''|*[!0-9]*)
            echo "DNS_PUBLIC_PORT must be numeric." >&2
            return 1
            ;;
    esac

    case "$DNSTT_PORT" in
        ''|*[!0-9]*)
            echo "DNSTT_PORT must be numeric." >&2
            return 1
            ;;
    esac
}

ensure_dns_forwarding() {
    local iptables_bin="/usr/sbin/iptables"

    [ -x "$iptables_bin" ] || iptables_bin="$(command -v iptables 2>/dev/null || true)"
    [ -n "$iptables_bin" ] || return 0

    "$iptables_bin" -C INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT >/dev/null 2>&1 || \
        "$iptables_bin" -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
    "$iptables_bin" -C INPUT -p udp --dport "$DNS_PUBLIC_PORT" -j ACCEPT >/dev/null 2>&1 || \
        "$iptables_bin" -I INPUT -p udp --dport "$DNS_PUBLIC_PORT" -j ACCEPT
    "$iptables_bin" -t nat -C PREROUTING -p udp --dport "$DNS_PUBLIC_PORT" -j REDIRECT --to-ports "$DNSTT_PORT" >/dev/null 2>&1 || \
        "$iptables_bin" -t nat -I PREROUTING -p udp --dport "$DNS_PUBLIC_PORT" -j REDIRECT --to-ports "$DNSTT_PORT"
}

write_dns_forwarding_files() {
    cat > "$DNS_RULES_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

iptables_bin="/usr/sbin/iptables"
[ -x "\$iptables_bin" ] || iptables_bin="\$(command -v iptables 2>/dev/null || true)"
[ -n "\$iptables_bin" ] || exit 0

"\$iptables_bin" -C INPUT -p udp --dport "${DNSTT_PORT}" -j ACCEPT >/dev/null 2>&1 || \
    "\$iptables_bin" -I INPUT -p udp --dport "${DNSTT_PORT}" -j ACCEPT
"\$iptables_bin" -C INPUT -p udp --dport "${DNS_PUBLIC_PORT}" -j ACCEPT >/dev/null 2>&1 || \
    "\$iptables_bin" -I INPUT -p udp --dport "${DNS_PUBLIC_PORT}" -j ACCEPT
"\$iptables_bin" -t nat -C PREROUTING -p udp --dport "${DNS_PUBLIC_PORT}" -j REDIRECT --to-ports "${DNSTT_PORT}" >/dev/null 2>&1 || \
    "\$iptables_bin" -t nat -I PREROUTING -p udp --dport "${DNS_PUBLIC_PORT}" -j REDIRECT --to-ports "${DNSTT_PORT}"
EOF
    chmod 0755 "$DNS_RULES_SCRIPT"

    cat > "$DNS_RULES_UNIT" <<EOF
[Unit]
Description=Restore Erwan DNS forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${DNS_RULES_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_dns_units() {
    local state_dir ns_value

    state_dir="$(dirname "$SERVER_KEY")"
    ns_value="$(trim_file "$NS_FILE")"

    cat > "$DNS_UNIT" <<EOF
[Unit]
Description=ErwanDNS
After=network.target

[Service]
User=root
ExecStart=${SCRIPT_PATH} --watch
Restart=always
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    cat > "$DNSTT_UNIT" <<EOF
[Unit]
Description=DNSTT Server
After=network-online.target erwan-dns-forwarding.service ErwanWS.service ErwanTCP.service ErwanTLS.service stunnel4.service
Wants=network-online.target erwan-dns-forwarding.service ErwanWS.service ErwanTCP.service ErwanTLS.service stunnel4.service
Requires=ErwanDNS.service
After=ErwanDNS.service

[Service]
User=root
Type=simple
WorkingDirectory=${state_dir}
ExecStartPre=/bin/bash -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do ss -lnt | grep -q ":443 " && exit 0; sleep 1; done; echo "127.0.0.1:443 backend is not ready" >&2; exit 1'
ExecStart=${DNSTT_BIN} -mtu 512 -udp :${DNSTT_PORT} -privkey-file $(basename "$SERVER_KEY") ${ns_value} 127.0.0.1:443
Restart=always
RestartSec=5s
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
StandardOutput=file:${STATUS_LOG}
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

install_mode() {
    mkdir -p "$(dirname "$DOMAIN_FILE")" "$(dirname "$NS_FILE")" "$(dirname "$SERVER_KEY")" "$(dirname "$SERVER_PUB")" "$(dirname "$STATUS_LOG")"
    mkdir -p "$(dirname "$DNS_UNIT")" "$(dirname "$DNSTT_UNIT")" "$(dirname "$DNS_RULES_UNIT")" "$(dirname "$DNS_RULES_SCRIPT")"
    [ -f "$DOMAIN_FILE" ] || echo "example.com" > "$DOMAIN_FILE"
    [ -f "$NS_FILE" ] || echo "ns.example.com" > "$NS_FILE"
    ensure_dnstt_keys
    validate_dns_settings
    touch "$STATUS_LOG"
    ensure_dns_forwarding
    write_dns_forwarding_files
    write_dns_units
    systemctl daemon-reload
    systemctl enable --now erwan-dns-forwarding >/dev/null 2>&1 || true
    systemctl enable ErwanDNS >/dev/null 2>&1 || true
    systemctl enable ErwanDNSTT >/dev/null 2>&1 || true
    echo "ErwanDNS and DNSTT units installed."
}

watch_mode() {
    mkdir -p "$(dirname "$STATUS_LOG")"
    touch "$STATUS_LOG"
    while true; do
        {
            echo "[$(date '+%F %T')] Domain: $(cat "$DOMAIN_FILE" 2>/dev/null || echo 'unset')"
            echo "[$(date '+%F %T')] Nameserver: $(cat "$NS_FILE" 2>/dev/null || echo 'unset')"
        } >> "$STATUS_LOG"
        sleep 300
    done
}

case "${1:-watch}" in
    --install) install_mode ;;
    --watch|watch) watch_mode ;;
    *) echo "Usage: $0 [--install|--watch]"; exit 1 ;;
esac
