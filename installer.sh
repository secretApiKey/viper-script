#!/bin/bash

set -euo pipefail

DOMAIN_WAS_SET="${DOMAIN+x}"
NAMESERVER_WAS_SET="${NAMESERVER+x}"
BASE_DOMAIN_WAS_SET="${BASE_DOMAIN+x}"
GENERATE_CF_WAS_SET="${GENERATE_CLOUDFLARE_RECORDS+x}"
CF_EMAIL_WAS_SET="${CF_AUTH_EMAIL+x}"
CF_KEY_WAS_SET="${CF_AUTH_KEY+x}"
CF_ZONE_WAS_SET="${CF_ZONE_ID+x}"
CF_ENDPOINT_WAS_SET="${CF_API_ENDPOINT+x}"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${TARGET_DIR:-/etc/ErwanScript}"
DOMAIN="${DOMAIN:-example.com}"
NAMESERVER="${NAMESERVER:-ns.${DOMAIN}}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
OBFS="${OBFS:-viperpanel}"
LOG_FILE="${LOG_FILE:-/var/log/newscript-install.log}"
HYSTERIA_V1_VERSION="${HYSTERIA_V1_VERSION:-v1.3.5}"
HYSTERIA_V2_VERSION="${HYSTERIA_V2_VERSION:-app/v2.8.1}"
HYSTERIA_V1_PORT="${HYSTERIA_V1_PORT:-36712}"
HYSTERIA_V2_PORT="${HYSTERIA_V2_PORT:-36713}"
XRAY_VERSION="${XRAY_VERSION:-v24.12.31}"
GENERATE_CLOUDFLARE_RECORDS="${GENERATE_CLOUDFLARE_RECORDS:-0}"
CF_API_ENDPOINT="${CF_API_ENDPOINT:-https://api.cloudflare.com/client/v4/zones}"
CF_AUTH_EMAIL="${CF_AUTH_EMAIL:-}"
CF_AUTH_KEY="${CF_AUTH_KEY:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
BUILD_ERWANSSH_RUNTIME="${BUILD_ERWANSSH_RUNTIME:-auto}"
IP_DISCOVERY_URL="${IP_DISCOVERY_URL:-http://ipinfo.io/ip}"
DNSTT_SERVER_KEY="${DNSTT_SERVER_KEY:-}"
DNSTT_SERVER_PUB="${DNSTT_SERVER_PUB:-}"

exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

load_cloudflare_env() {
    local env_file

    for env_file in \
        "${CF_ENV_FILE:-}" \
        "$SCRIPT_DIR/cloudflare.env" \
        "$TARGET_DIR/cloudflare.env"; do
        [ -n "$env_file" ] || continue
        if [ -f "$env_file" ]; then
            # shellcheck disable=SC1090
            . "$env_file"
            export DOMAIN NAMESERVER BASE_DOMAIN GENERATE_CLOUDFLARE_RECORDS \
                CF_API_ENDPOINT CF_AUTH_EMAIL CF_AUTH_KEY CF_ZONE_ID
            echo "Loaded Cloudflare install settings from $env_file"
            return 0
        fi
    done

    return 0
}

extract_original_value() {
    local file="$1"
    local key="$2"

    [ -f "$file" ] || return 1
    sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$file" | head -n 1
}

load_original_cloudflare_defaults() {
    local original_installer defaults_file value

    original_installer="${SCRIPT_DIR}/../installer.sh"
    defaults_file="${SCRIPT_DIR}/cloudflare.defaults"

    if [ "$GENERATE_CF_WAS_SET" = "x" ] || [ "$DOMAIN_WAS_SET" = "x" ] || [ "$BASE_DOMAIN_WAS_SET" = "x" ]; then
        return 0
    fi

    if [ -f "$defaults_file" ]; then
        if [ "$GENERATE_CF_WAS_SET" != "x" ]; then
            # shellcheck disable=SC1090
            . "$defaults_file"
        fi
        [ "$GENERATE_CF_WAS_SET" = "x" ] || GENERATE_CLOUDFLARE_RECORDS="${GENERATE_CLOUDFLARE_RECORDS:-0}"
        [ "$BASE_DOMAIN_WAS_SET" = "x" ] || BASE_DOMAIN="${BASE_DOMAIN:-}"
        [ "$CF_EMAIL_WAS_SET" = "x" ] || CF_AUTH_EMAIL="${CF_AUTH_EMAIL:-}"
        [ "$CF_KEY_WAS_SET" = "x" ] || CF_AUTH_KEY="${CF_AUTH_KEY:-}"
        [ "$CF_ZONE_WAS_SET" = "x" ] || CF_ZONE_ID="${CF_ZONE_ID:-}"
        [ "$CF_ENDPOINT_WAS_SET" = "x" ] || CF_API_ENDPOINT="${CF_API_ENDPOINT:-https://api.cloudflare.com/client/v4/zones}"
        return 0
    fi

    [ -f "$original_installer" ] || return 0

    if [ "$GENERATE_CLOUDFLARE_RECORDS" != "1" ]; then
        value="$(extract_original_value "$original_installer" "DOMAIN_NAME" || true)"
        if [ -n "$value" ]; then
            GENERATE_CLOUDFLARE_RECORDS=1
            BASE_DOMAIN="${BASE_DOMAIN:-$value}"
        fi
    fi

    [ -n "$BASE_DOMAIN" ] || BASE_DOMAIN="$(extract_original_value "$original_installer" "DOMAIN_NAME" || true)"
    [ -n "$CF_AUTH_EMAIL" ] || CF_AUTH_EMAIL="$(extract_original_value "$original_installer" "AUTH_EMAIL" || true)"
    [ -n "$CF_AUTH_KEY" ] || CF_AUTH_KEY="$(extract_original_value "$original_installer" "AUTH_KEY" || true)"
    [ -n "$CF_ZONE_ID" ] || CF_ZONE_ID="$(extract_original_value "$original_installer" "ZONE_ID" || true)"
    [ -n "$CF_API_ENDPOINT" ] || CF_API_ENDPOINT="$(extract_original_value "$original_installer" "API_ENDPOINT" || true)"

    export GENERATE_CLOUDFLARE_RECORDS BASE_DOMAIN CF_AUTH_EMAIL CF_AUTH_KEY CF_ZONE_ID CF_API_ENDPOINT
}

install_packages() {
    apt-get update
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        autoconf automake build-essential certbot cmake conntrack cron curl dnsutils dos2unix git golang jq libpam0g-dev \
        libssl-dev libtool nginx openvpn openssl pkg-config python3 python3-pam python3-pip \
        iptables \
        screenfetch squid sslh stunnel4 unzip wget zlib1g-dev expect
}

generate_dnstt_keypair() {
    local pem_file key_text

    pem_file="$(mktemp)"
    if ! openssl genpkey -algorithm X25519 -out "$pem_file" >/dev/null 2>&1; then
        rm -f "$pem_file"
        echo "Failed to generate DNSTT keypair."
        exit 1
    fi

    key_text="$(openssl pkey -in "$pem_file" -text -noout 2>/dev/null || true)"
    rm -f "$pem_file"

    DNSTT_SERVER_KEY="$(printf '%s\n' "$key_text" | awk '
        /^priv:$/ {mode="priv"; next}
        /^pub:$/ {mode="pub"; next}
        mode=="priv" && /^[[:space:][:xdigit:]:]+$/ {gsub(/[^[:xdigit:]]/, ""); printf "%s", $0; next}
        mode=="priv" {mode=""}
        END {print ""}
    ')"
    DNSTT_SERVER_PUB="$(printf '%s\n' "$key_text" | awk '
        /^pub:$/ {mode="pub"; next}
        mode=="pub" && /^[[:space:][:xdigit:]:]+$/ {gsub(/[^[:xdigit:]]/, ""); printf "%s", $0; next}
        mode=="pub" {mode=""}
        END {print ""}
    ')"

    if [ "${#DNSTT_SERVER_KEY}" -ne 64 ] || [ "${#DNSTT_SERVER_PUB}" -ne 64 ]; then
        echo "Failed to parse generated DNSTT keypair."
        exit 1
    fi

    export DNSTT_SERVER_KEY DNSTT_SERVER_PUB
}

ensure_dnstt_key_material() {
    if [ -n "$DNSTT_SERVER_KEY" ] || [ -n "$DNSTT_SERVER_PUB" ]; then
        if [ -z "$DNSTT_SERVER_KEY" ] || [ -z "$DNSTT_SERVER_PUB" ]; then
            echo "DNSTT_SERVER_KEY and DNSTT_SERVER_PUB must be provided together."
            exit 1
        fi
    fi

    if [ -z "$DNSTT_SERVER_KEY" ] || [ -z "$DNSTT_SERVER_PUB" ]; then
        generate_dnstt_keypair
    fi
}

validate_domain_inputs() {
    if [ "$GENERATE_CLOUDFLARE_RECORDS" = "1" ]; then
        return 0
    fi

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "example.com" ] || [[ "$DOMAIN" != *.* ]]; then
        echo "A real domain is required before install."
        echo "Set DOMAIN to a valid hostname or enable GENERATE_CLOUDFLARE_RECORDS=1."
        exit 1
    fi

    if [ -z "$NAMESERVER" ] || [ "$NAMESERVER" = "ns.example.com" ]; then
        NAMESERVER="ns.${DOMAIN}"
    fi
}

generate_cloudflare_records() {
    local zone_domain subdomain ip_address a_record a_response a_success ns_record ns_response ns_success

    if [ "$GENERATE_CLOUDFLARE_RECORDS" != "1" ]; then
        return 0
    fi

    zone_domain="${BASE_DOMAIN:-$DOMAIN}"
    if [ -z "$zone_domain" ] || [ -z "$CF_AUTH_EMAIL" ] || [ -z "$CF_AUTH_KEY" ] || [ -z "$CF_ZONE_ID" ]; then
        echo "Cloudflare record generation requested, but BASE_DOMAIN/CF_AUTH_EMAIL/CF_AUTH_KEY/CF_ZONE_ID is incomplete."
        exit 1
    fi

    ip_address="$(wget -4qO- "$IP_DISCOVERY_URL")"
    subdomain="$(openssl rand -hex 8 | tr '0-9' 'a-j' | cut -c1-5)"
    DOMAIN="${subdomain}.${zone_domain}"
    NAMESERVER="ns.${subdomain}.${zone_domain}"

    a_record=$(cat <<EOF
{
  "type": "A",
  "name": "${DOMAIN}",
  "content": "${ip_address}",
  "ttl": 1,
  "proxied": false
}
EOF
)

    a_response="$(curl -fsS -X POST "${CF_API_ENDPOINT}/${CF_ZONE_ID}/dns_records" \
        -H "X-Auth-Email: ${CF_AUTH_EMAIL}" \
        -H "X-Auth-Key: ${CF_AUTH_KEY}" \
        -H "Content-Type: application/json" \
        --data "${a_record}")"
    a_success="$(echo "$a_response" | jq -r '.success')"

    if [ "$a_success" != "true" ]; then
        echo "Failed to create Cloudflare A record for ${DOMAIN}"
        echo "$a_response"
        exit 1
    fi

    ns_record=$(cat <<EOF
{
  "type": "NS",
  "name": "${NAMESERVER}",
  "content": "${DOMAIN}",
  "ttl": 1,
  "proxied": false
}
EOF
)

    ns_response="$(curl -fsS -X POST "${CF_API_ENDPOINT}/${CF_ZONE_ID}/dns_records" \
        -H "X-Auth-Email: ${CF_AUTH_EMAIL}" \
        -H "X-Auth-Key: ${CF_AUTH_KEY}" \
        -H "Content-Type: application/json" \
        --data "${ns_record}")"
    ns_success="$(echo "$ns_response" | jq -r '.success')"

    if [ "$ns_success" != "true" ]; then
        echo "Failed to create Cloudflare NS record for ${NAMESERVER}"
        echo "$ns_response"
        exit 1
    fi

    echo "Created Cloudflare records:"
    echo "A  -> ${DOMAIN} => ${ip_address}"
    echo "NS -> ${NAMESERVER} => ${DOMAIN}"
}

write_domain_state() {
    ensure_dnstt_key_material
    mkdir -p "$TARGET_DIR"
    echo "$DOMAIN" > "$TARGET_DIR/domain"
    echo "$NAMESERVER" > "$TARGET_DIR/nameserver"
    echo "$DNSTT_SERVER_KEY" > "$TARGET_DIR/server.key"
    echo "$DNSTT_SERVER_PUB" > "$TARGET_DIR/server.pub"
    printf '%s\n' "<b><font color='red'>VIPER</font> <font color='green'>Panel</font></b>" > "$TARGET_DIR/ws-response.txt"
    if [ -f "$SCRIPT_DIR/banner" ]; then
        install -m 0644 "$SCRIPT_DIR/banner" "$TARGET_DIR/banner"
    fi
    touch "$TARGET_DIR/status.log" "$TARGET_DIR/xray-expiry.txt" "$TARGET_DIR/user-expiry.txt" "$TARGET_DIR/multilogin.txt" "$TARGET_DIR/multilogin-default.txt"
    mkdir -p "$TARGET_DIR/xray-ip-lock" "$TARGET_DIR/logs"
}

write_server_metadata() {
    local ip_host
    ip_host="$(wget -4qO- "$IP_DISCOVERY_URL" 2>/dev/null || true)"
    if [ -z "$ip_host" ]; then
        ip_host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi

    cat > "$TARGET_DIR/server-info.json" <<EOF
{
  "tcp_port": "1194",
  "udp_port": "110",
  "udp_hysteria_port": "${HYSTERIA_V1_PORT}",
  "udp_hysteria_obfs": "${OBFS}",
  "udp_hysteria_v1_port": "${HYSTERIA_V1_PORT}",
  "udp_hysteria_v1_obfs": "${OBFS}",
  "udp_hysteria_v2_port": "${HYSTERIA_V2_PORT}",
  "udp_hysteria_v2_obfs": "${OBFS}",
  "ssh_port": "22",
  "ssl_port": "111 (recommended), 443 (shared mux)",
  "ws_port": "700,8880,8888,8010,2052,2082,2086,2095",
  "sdns_port": "5300",
  "xray_port": "443,8443,8388",
  "squid_port": "8000,8080",
  "ip_host": "${ip_host}",
  "domain": "${DOMAIN}",
  "name_server": "${NAMESERVER}",
  "public_key": "${DNSTT_SERVER_PUB}",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    chmod 0644 "$TARGET_DIR/server-info.json"
}

ensure_tls_material() {
    mkdir -p "/etc/letsencrypt/live/${DOMAIN}" /etc/stunnel
    if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
        local openssl_config
        openssl_config="$(mktemp)"
        cat > "$openssl_config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${DOMAIN}

[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
EOF
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
            -out "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
            -days 365 \
            -config "$openssl_config" \
            -extensions v3_req
        rm -f "$openssl_config"
    fi
    cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/stunnel/stunnel.crt
    cp -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/stunnel/stunnel.key
}

ensure_real_tls_material() {
    local live_dir archive_dir renewal_file issuer subject backup_dir

    if ! command -v certbot >/dev/null 2>&1; then
        echo "certbot not found; keeping current TLS material."
        return 0
    fi

    live_dir="/etc/letsencrypt/live/${DOMAIN}"
    archive_dir="/etc/letsencrypt/archive/${DOMAIN}"
    renewal_file="/etc/letsencrypt/renewal/${DOMAIN}.conf"

    mkdir -p /var/www/html/.well-known/acme-challenge
    printf 'acme-ok' > /var/www/html/.well-known/acme-challenge/newscript-check

    issuer=""
    subject=""
    if [ -f "${live_dir}/fullchain.pem" ]; then
        issuer="$(openssl x509 -in "${live_dir}/fullchain.pem" -noout -issuer 2>/dev/null || true)"
        subject="$(openssl x509 -in "${live_dir}/fullchain.pem" -noout -subject 2>/dev/null || true)"
        issuer="${issuer#issuer=}"
        subject="${subject#subject=}"
    fi

    if [ -f "$renewal_file" ] && [ ! -s "$renewal_file" ]; then
        rm -f "$renewal_file"
    fi

    if [ -d "$live_dir" ] && [ -n "$issuer" ] && [ "$issuer" = "$subject" ]; then
        backup_dir="${live_dir}.selfsigned-$(date +%Y%m%d-%H%M%S)"
        mv "$live_dir" "$backup_dir"
        echo "Backed up self-signed TLS material to $backup_dir"

        if [ -d "$archive_dir" ]; then
            mv "$archive_dir" "${archive_dir}.selfsigned-$(date +%Y%m%d-%H%M%S)"
        fi

        rm -f "$renewal_file"
    fi

    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --force-renewal; then
        cp -f "${live_dir}/fullchain.pem" /etc/stunnel/stunnel.crt
        cp -f "${live_dir}/privkey.pem" /etc/stunnel/stunnel.key

        echo "Using Let's Encrypt certificate for ${DOMAIN}"
    else
        echo "Let's Encrypt issuance failed; keeping current TLS material."
    fi
}

ensure_xray_binary() {
    local version_no_v="${XRAY_VERSION#v}"
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
    if [ ! -x /usr/local/bin/xray ]; then
        rm -rf /tmp/newscript-xray
        mkdir -p /tmp/newscript-xray
        wget -qO /tmp/newscript-xray/xray.zip "$url"
        unzip -qo /tmp/newscript-xray/xray.zip -d /tmp/newscript-xray
        install -m 0755 /tmp/newscript-xray/xray /usr/local/bin/xray
        rm -rf /tmp/newscript-xray
    fi
}

ensure_hysteria_binaries() {
    local url_v1="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_V1_VERSION}/hysteria-linux-amd64"
    local url_v2="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_V2_VERSION}/hysteria-linux-amd64"
    local current_v1=""
    local current_v2=""
    mkdir -p /etc/udp
    if [ -x /etc/udp/hysteria-v1 ]; then
        current_v1="$(/etc/udp/hysteria-v1 version 2>/dev/null | awk -F'\t' '/^Version:/ {print $2; exit}' || true)"
        if [[ "$current_v1" == app/v2* ]] || [ -z "$current_v1" ]; then
            rm -f /etc/udp/hysteria-v1
        fi
    fi
    if [ ! -x /etc/udp/hysteria-v1 ]; then
        wget -qO /etc/udp/hysteria-v1 "$url_v1"
        chmod 0755 /etc/udp/hysteria-v1
    fi
    if [ -x /etc/udp/hysteria-v2 ]; then
        current_v2="$(/etc/udp/hysteria-v2 version 2>/dev/null | awk -F'\t' '/^Version:/ {print $2; exit}' || true)"
        if [[ "$current_v2" != app/v2* ]]; then
            rm -f /etc/udp/hysteria-v2
        fi
    fi
    if [ ! -x /etc/udp/hysteria-v2 ]; then
        wget -qO /etc/udp/hysteria-v2 "$url_v2"
        chmod 0755 /etc/udp/hysteria-v2
    fi
}

ensure_dnstt_binary() {
    if [ ! -x "${TARGET_DIR}/dnstt-server" ]; then
        rm -rf /tmp/newscript-dnstt
        git clone https://www.bamsoftware.com/git/dnstt.git /tmp/newscript-dnstt
        (cd /tmp/newscript-dnstt/dnstt-server && go build -o "${TARGET_DIR}/dnstt-server")
        chmod 0755 "${TARGET_DIR}/dnstt-server"
        rm -rf /tmp/newscript-dnstt
    fi
}

ensure_badvpn_binary() {
    if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
        rm -rf /tmp/newscript-badvpn
        git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/newscript-badvpn
        mkdir -p /tmp/newscript-badvpn/build
        (
            cd /tmp/newscript-badvpn/build
            cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
            make -j"$(nproc)"
            install -m 0755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
        )
        rm -rf /tmp/newscript-badvpn
    fi
}

configure_openvpn_forwarding() {
    local outbound_if
    outbound_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -z "$outbound_if" ]; then
        outbound_if="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    fi
    if [ -z "$outbound_if" ]; then
        echo "Unable to detect outbound interface for OpenVPN NAT."
        return 0
    fi

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-erwanscript-forwarding.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl -q -p /etc/sysctl.d/99-erwanscript-forwarding.conf || true

    iptables -C FORWARD -s 10.8.0.0/20 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.8.0.0/20 -j ACCEPT
    iptables -C FORWARD -d 10.8.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -d 10.8.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -s 10.9.0.0/20 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.9.0.0/20 -j ACCEPT
    iptables -C FORWARD -d 10.9.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -d 10.9.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -s 10.8.0.0/20 -o "$outbound_if" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 10.8.0.0/20 -o "$outbound_if" -j MASQUERADE
    iptables -t nat -C POSTROUTING -s 10.9.0.0/20 -o "$outbound_if" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 10.9.0.0/20 -o "$outbound_if" -j MASQUERADE

    cat > /usr/local/bin/erwan-openvpn-nat <<EOF
#!/bin/bash
set -euo pipefail

outbound_if="\$(ip route show default 2>/dev/null | awk '/default/ {print \$5; exit}')"
if [ -z "\$outbound_if" ]; then
    outbound_if="\$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i == "dev") {print \$(i+1); exit}}')"
fi

[ -n "\$outbound_if" ] || exit 0

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

iptables -C FORWARD -s 10.8.0.0/20 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.8.0.0/20 -j ACCEPT
iptables -C FORWARD -d 10.8.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d 10.8.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -s 10.9.0.0/20 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.9.0.0/20 -j ACCEPT
iptables -C FORWARD -d 10.9.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d 10.9.0.0/20 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.8.0.0/20 -o "\$outbound_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.8.0.0/20 -o "\$outbound_if" -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/20 -o "\$outbound_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.9.0.0/20 -o "\$outbound_if" -j MASQUERADE
EOF
    sed -i 's/\r$//' /usr/local/bin/erwan-openvpn-nat
    chmod 0755 /usr/local/bin/erwan-openvpn-nat

    cat > /etc/systemd/system/erwan-openvpn-nat.service <<'EOF'
[Unit]
Description=Restore ErwanScript OpenVPN NAT rules
After=network-online.target openvpn-server@tcp.service openvpn-server@udp.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/erwan-openvpn-nat
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sed -i 's/\r$//' /etc/systemd/system/erwan-openvpn-nat.service

    systemctl daemon-reload
    systemctl enable --now erwan-openvpn-nat.service >/dev/null 2>&1 || true
}

build_erwanssh_runtime() {
    local mode="$BUILD_ERWANSSH_RUNTIME"
    local bundled_runtime_zip="${SCRIPT_DIR}/ErwanSSH.zip"

    if [ "$mode" = "0" ] || [ "$mode" = "false" ] || [ "$mode" = "no" ]; then
        echo "Skipping ErwanSSH runtime build; using bundled runtime only."
        return 0
    fi

    if [ "$mode" = "auto" ] && [ -f "$bundled_runtime_zip" ]; then
        echo "Bundled ErwanSSH runtime found; skipping rebuild."
        return 0
    fi

    echo "ErwanSSH runtime rebuild helpers are not bundled in this installer copy."
    echo "Use the SafeFolder dev tools if you need to rebuild the SSH runtime."
}

write_nginx_base() {
    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    multi_accept on;
    worker_connections 65535;
    use epoll;
}

http {
    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain application/javascript application/json text/xml text/css image/svg+xml font/woff2;
    autoindex on;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300;
    types_hash_max_size 4096;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    client_max_body_size 100M;
    client_body_timeout 12s;
    client_header_timeout 12s;
    client_header_buffer_size 16k;
    large_client_header_buffers 8 16k;
    fastcgi_buffer_size 16k;
    fastcgi_buffers 8 16k;
    fastcgi_busy_buffers_size 32k;
    fastcgi_temp_file_write_size 32k;
    fastcgi_read_timeout 300;
    proxy_buffer_size 16k;
    proxy_buffers 4 16k;
    proxy_busy_buffers_size 32k;
    proxy_temp_file_write_size 32k;
    proxy_connect_timeout 60s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    set_real_ip_from 204.93.240.0/24;
    set_real_ip_from 204.93.177.0/24;
    set_real_ip_from 199.27.128.0/21;
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    real_ip_header CF-Connecting-IP;
    server_names_hash_bucket_size 128;
    map_hash_bucket_size 128;
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

write_squid_files() {
    mkdir -p /etc/squid/pages/en
    cat > /etc/squid/squid.conf <<EOF
acl localnet src 0.0.0.1-0.255.255.255
acl ipv6 src fd00:abcd:1236::/64
acl SSL_ports port 443
acl SSL_ports port 111
acl SSL_ports port 22
acl SSL_ports port 1194
acl SSL_ports port 700
acl Safe_ports port 0-65535
acl CONNECT method CONNECT
acl VPN dst $(wget -4qO- http://ipinfo.io/ip)/32
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access allow VPN
http_access allow ipv6
http_access allow localhost
http_access deny all
dns_nameservers 1.1.1.1 1.0.0.1
http_port 8080
http_port 8000
refresh_pattern ^ftp: 1440 20% 10080
refresh_pattern ^gopher: 1440 0% 1440
refresh_pattern -i (/cgi-bin/|\?) 0 0% 0
refresh_pattern . 0 20% 4320
visible_hostname localhost
coredump_dir /var/spool/squid
max_filedescriptors 4096
workers 4
cache_dir ufs /var/spool/squid 10000 16 256
forwarded_for delete
error_directory /etc/squid/pages/en
EOF

    cat > /etc/squid/pages/en/ERR_INVALID_URL <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ErwanScript</title>
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@300;500;700&display=swap" rel="stylesheet">
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Poppins', sans-serif; }
    body {
        height: 100vh; display: flex; justify-content: center; align-items: center;
        background: linear-gradient(135deg, #0f2027, #203a43, #2c5364); color: white;
    }
    .card {
        background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(12px);
        border-radius: 20px; padding: 40px 60px; text-align: center;
        box-shadow: 0 10px 30px rgba(0,0,0,0.4); border: 1px solid rgba(255,255,255,0.1);
    }
    .small-text { font-size: 14px; opacity: 0.7; margin-bottom: 10px; letter-spacing: 2px; }
    .big-text {
        font-size: 60px; font-weight: 700;
        background: linear-gradient(90deg, #ff6ec4, #7873f5, #4ade80);
        -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 30px;
    }
    .buttons { display: flex; gap: 15px; justify-content: center; flex-wrap: wrap; }
    .button {
        padding: 12px 26px; border-radius: 999px; text-decoration: none; font-size: 16px; font-weight: 500;
        transition: all 0.3s ease; border: 1px solid rgba(255,255,255,0.2);
        background: rgba(255,255,255,0.08); color: white;
    }
    .button:hover { transform: translateY(-3px) scale(1.05); background: rgba(255,255,255,0.2); }
    .facebook:hover { background: #1877f2; }
    .telegram:hover { background: #0088cc; }
</style>
</head>
<body>
<div class="card">
    <div class="small-text">MOD BY</div>
    <div class="big-text">ERWAN</div>
    <div class="buttons">
        <a href="https://www.facebook.com/joe.kingsley.kaldag" target="_blank" class="button facebook">Facebook</a>
        <a href="/" class="button telegram">Home</a>
    </div>
</div>
</body>
</html>
EOF
}

write_udp_config() {
    mkdir -p /etc/udp
    cat > /etc/udp/config.json <<EOF
{
  "server": "${DOMAIN}",
  "listen": ":${HYSTERIA_V1_PORT}",
  "protocol": "udp",
  "cert": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
  "key": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem",
  "up": "1000 Mbps",
  "up_mbps": 1000,
  "down": "1000 Mbps",
  "down_mbps": 1000,
  "disable_udp": false,
  "insecure": false,
  "obfs": "${OBFS}",
  "auth": {
    "mode": "external",
    "config": { "cmd": "/etc/ErwanScript/ErwanUDP-auth" }
  }
}
EOF

    cat > /etc/udp/config-v2.yaml <<EOF
listen: :${HYSTERIA_V2_PORT}

tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem

auth:
  type: command
  command: /etc/ErwanScript/ErwanUDP-auth

obfs:
  type: salamander
  salamander:
    password: "${OBFS}"

speedTest: false
disableUDP: false
EOF

    cat > /etc/systemd/system/udp.service <<'EOF'
[Unit]
Description=Erwan Hysteria v1 UDP
After=network.target

[Service]
User=root
WorkingDirectory=/etc/udp
ExecStartPre=/bin/rm -f /etc/ErwanScript/udp.log
ExecStart=/etc/udp/hysteria-v1 server --config /etc/udp/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/udp2.service <<'EOF'
[Unit]
Description=Erwan Hysteria v2 UDP
After=network.target

[Service]
User=root
WorkingDirectory=/etc/udp
ExecStartPre=/bin/rm -f /etc/ErwanScript/udp2.log
ExecStart=/etc/udp/hysteria-v2 server --config /etc/udp/config-v2.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

write_openvpn_configs() {
    mkdir -p /etc/openvpn/server /etc/openvpn/configs /etc/openvpn/certificates
    if [ -f "/etc/ssl/certs/ISRG_Root_X1.pem" ]; then
        cp -f "/etc/ssl/certs/ISRG_Root_X1.pem" /etc/openvpn/certificates/ca.crt
    elif [ -f "/usr/share/ca-certificates/mozilla/ISRG_Root_X1.crt" ]; then
        cp -f "/usr/share/ca-certificates/mozilla/ISRG_Root_X1.crt" /etc/openvpn/certificates/ca.crt
    elif [ -f "/etc/letsencrypt/live/${DOMAIN}/chain.pem" ]; then
        cp -f "/etc/letsencrypt/live/${DOMAIN}/chain.pem" /etc/openvpn/certificates/ca.crt
    else
        cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/openvpn/certificates/ca.crt
    fi
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/openvpn/certificates/Erwan.crt
    elif [ -f "/etc/letsencrypt/live/${DOMAIN}/cert.pem" ]; then
        cp -f "/etc/letsencrypt/live/${DOMAIN}/cert.pem" /etc/openvpn/certificates/Erwan.crt
    else
        cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/openvpn/certificates/Erwan.crt
    fi
    cp -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/openvpn/certificates/Erwan.key
cat > /etc/openvpn/server/tcp.conf <<'EOF'
port 1194
dev tun
proto tcp
ca /etc/openvpn/certificates/ca.crt
cert /etc/openvpn/certificates/Erwan.crt
key /etc/openvpn/certificates/Erwan.key
dh none
plugin /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so /etc/pam.d/login
verify-client-cert none
username-as-common-name
duplicate-cn
max-clients 4096
topology subnet
script-security 3
server 10.8.0.0 255.255.240.0
keepalive 5 30
status /etc/openvpn/tcp_stats.log
log /etc/openvpn/tcp.log
verb 3
persist-key
persist-tun
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.0.0.1"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.4.4"
push "dhcp-option DNS 8.8.8.8"
EOF

    cat > /etc/openvpn/server/udp.conf <<'EOF'
port 110
dev tun
proto udp
topology subnet
ca /etc/openvpn/certificates/ca.crt
cert /etc/openvpn/certificates/Erwan.crt
key /etc/openvpn/certificates/Erwan.key
dh none
plugin /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so /etc/pam.d/login
verify-client-cert none
username-as-common-name
max-clients 4096
script-security 3
duplicate-cn
server 10.9.0.0 255.255.240.0
keepalive 5 30
status /etc/openvpn/udp_stats.log
log /etc/openvpn/udp.log
verb 3
persist-key
persist-tun
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.0.0.1"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.4.4"
push "dhcp-option DNS 8.8.8.8"
EOF

    cat > /etc/openvpn/configs/tcp.ovpn <<EOF
client
dev tun
proto tcp-client
remote ${DOMAIN} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
auth-nocache
remote-cert-tls server
verify-x509-name ${DOMAIN} name
verb 3
<ca>
$(cat /etc/openvpn/certificates/ca.crt)
</ca>
EOF

    cat > /etc/openvpn/configs/udp.ovpn <<EOF
client
dev tun
proto udp
remote ${DOMAIN} 110
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
auth-nocache
remote-cert-tls server
verify-x509-name ${DOMAIN} name
verb 3
<ca>
$(cat /etc/openvpn/certificates/ca.crt)
</ca>
EOF
}

publish_openvpn_downloads() {
    mkdir -p /var/www/html/openvpn
    install -m 0644 /etc/openvpn/configs/tcp.ovpn /var/www/html/openvpn/tcp.ovpn
    install -m 0644 /etc/openvpn/configs/udp.ovpn /var/www/html/openvpn/udp.ovpn
    install -m 0644 /etc/openvpn/certificates/ca.crt /var/www/html/openvpn/ca.crt
}

write_badvpn_unit() {
    cat > /lib/systemd/system/badvpn-udpgw.service <<'EOF'
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 4096
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

write_ddos_unit() {
    cat > /etc/systemd/system/ddos.service <<'EOF'
[Unit]
Description=(D)Dos Deflate
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'while true; do sleep 300; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

write_profile_banner() {
    cat > /etc/profile.d/erwan.sh <<'EOF'
#!/bin/bash
render_vps_info() {
    local hostname_line os_line kernel_line uptime_line pkg_line shell_line disk_line cpu_line ram_line ping_line
    local used total pct mem_used mem_total

    hostname_line="$(hostname 2>/dev/null || echo unknown-host)"
    os_line="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Unknown Linux}")"
    kernel_line="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null)"
    uptime_line="$(uptime -p 2>/dev/null | sed 's/^up //')"
    if command -v dpkg-query >/dev/null 2>&1; then
        pkg_line="$(dpkg-query -f '.' -W 2>/dev/null | wc -c)"
    else
        pkg_line="N/A"
    fi
    shell_line="${SHELL:-bash}"
    read -r used total pct <<EOFSTAT
$(df -h / 2>/dev/null | awk 'NR==2 {print $3, $2, $5}')
EOFSTAT
    disk_line="${used:-N/A} / ${total:-N/A} (${pct:-N/A})"
    cpu_line="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    read -r mem_used mem_total <<EOFMEM
$(free -m 2>/dev/null | awk '/^Mem:/ {print $3 "MiB", $2 "MiB"}')
EOFMEM
    ram_line="${mem_used:-N/A} / ${mem_total:-N/A}"
    ping_line="$(ping -c 1 -W 1 1.1.1.1 2>/dev/null | awk -F'time=' 'NF>1 {print $2}' | awk '{print $1 " ms"; exit}')"
    [ -n "$ping_line" ] || ping_line="unavailable"

    echo "------------------------------------------------------------"
    printf "Host           %s\n" "$hostname_line"
    printf "OS             %s\n" "$os_line"
    printf "Kernel         %s\n" "$kernel_line"
    printf "Uptime         %s\n" "${uptime_line:-N/A}"
    printf "Packages       %s\n" "$pkg_line"
    printf "Shell          %s\n" "$shell_line"
    printf "Disk           %s\n" "$disk_line"
    printf "CPU            %s\n" "${cpu_line:-N/A}"
    printf "RAM            %s\n" "$ram_line"
    printf "Live Ping      %s\n" "$ping_line"
    echo "------------------------------------------------------------"
}

render_server_details() {
    local domain nameserver ip_host created_at tcp_port udp_port ssh_port ssl_port xray_port squid_port
    local hysteria_v1_port hysteria_v2_port sdns_port ws_port public_key

    if [ -f /etc/ErwanScript/server-info.json ] && command -v jq >/dev/null 2>&1; then
        domain="$(jq -r '.domain // "not-set"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        nameserver="$(jq -r '.name_server // "not-set"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        ip_host="$(jq -r '.ip_host // "not-set"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        created_at="$(jq -r '.created_at // "not-set"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        tcp_port="$(jq -r '.tcp_port // "1194"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        udp_port="$(jq -r '.udp_port // "110"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        ssh_port="$(jq -r '.ssh_port // "22"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        ssl_port="$(jq -r '.ssl_port // "111 (recommended), 443 (shared mux)"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        xray_port="$(jq -r '.xray_port // "443"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        squid_port="$(jq -r '.squid_port // "8000,8080"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        hysteria_v1_port="$(jq -r '.udp_hysteria_v1_port // .udp_hysteria_port // "36712"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        hysteria_v2_port="$(jq -r '.udp_hysteria_v2_port // "36713"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        sdns_port="$(jq -r '.sdns_port // "5300"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        ws_port="$(jq -r '.ws_port // "700,8880,8888,8010,2052,2082,2086,2095"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        public_key="$(jq -r '.public_key // "not-set"' /etc/ErwanScript/server-info.json 2>/dev/null)"
        echo "------------------------------------------------------------"
        printf "Domain         %s\n" "$domain"
        printf "Nameserver     %s\n" "$nameserver"
        printf "IP Host        %s\n" "$ip_host"
        printf "Created        %s\n" "$created_at"
        printf "TCP Port       %s\n" "$tcp_port"
        printf "UDP Port       %s\n" "$udp_port"
        printf "SSH Port       %s\n" "$ssh_port"
        printf "SSL Port       %s\n" "$ssl_port"
        printf "Xray Port      %s\n" "$xray_port"
        printf "Squid Port     %s\n" "$squid_port"
        printf "Hysteria v1    UDP %s\n" "$hysteria_v1_port"
        printf "Hysteria v2    UDP %s\n" "$hysteria_v2_port"
        printf "SDNS Port      %s\n" "$sdns_port"
        printf "WS Port        %s\n" "$ws_port"
        printf "Public Key     %s\n" "$public_key"
        echo "------------------------------------------------------------"
    fi
}

show_erwan_banner() {
    render_vps_info
    render_server_details
    echo "| Command : menu                                        |"
    echo "------------------------------------------------------------"
}

show_erwan_banner
EOF
    chmod +x /etc/profile.d/erwan.sh
}

write_cron() {
    cat > /etc/cron.d/reboot_at_midnight_utc <<'EOF'
CRON_TZ=UTC
0 0 * * * root /sbin/reboot
EOF

    echo "*/30 * * * * root /bin/bash /etc/ErwanScript/cleanup-expired-users.sh" > /etc/cron.d/account-expiry
    echo "* * * * * root /bin/bash /etc/ErwanScript/limit-xray.sh" > /etc/cron.d/xray-limit
    echo "* * * * * root /bin/bash /etc/ErwanScript/limit-useradd.sh" > /etc/cron.d/useradd-limit
    echo "* * * * * root /bin/bash /etc/ErwanScript/limit-udp.sh" > /etc/cron.d/udp-limit

    cat > /etc/cron.d/erwan-restart <<'EOF'
CRON_TZ=UTC
0 12 * * * root systemctl restart ssh erwanssh xray nginx squid stunnel4 ErwanTCP ErwanTLS ErwanWS ErwanDNS ErwanDNSTT udp udp2 badvpn-udpgw ddos openvpn-server@tcp openvpn-server@udp
EOF

    chmod 644 \
        /etc/cron.d/reboot_at_midnight_utc \
        /etc/cron.d/account-expiry \
        /etc/cron.d/xray-limit \
        /etc/cron.d/useradd-limit \
        /etc/cron.d/udp-limit \
        /etc/cron.d/erwan-restart
}

write_fix_letsencrypt_helper() {
    cat > /usr/local/bin/fix-letsencrypt <<'EOF'
#!/bin/bash
set -e

DOMAIN="$(cat /etc/ErwanScript/domain)"
IP_HOST="$(wget -4qO- http://ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}')"

echo "Checking DNS for $DOMAIN..."
echo "Expected IP: $IP_HOST"
echo "Cloudflare/Google DNS:"
dig +short A "$DOMAIN" @1.1.1.1 || true
dig +short A "$DOMAIN" @8.8.8.8 || true

mkdir -p /var/www/html/.well-known/acme-challenge
echo ok > /var/www/html/.well-known/acme-challenge/test

nginx -t
systemctl restart nginx

certbot certonly --webroot \
  -w /var/www/html \
  -d "$DOMAIN" \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --force-renewal

cp -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/stunnel/stunnel.crt
cp -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/stunnel/stunnel.key

systemctl restart nginx stunnel4 xray udp udp2

echo "Let's Encrypt fixed for $DOMAIN"
EOF

    chmod +x /usr/local/bin/fix-letsencrypt
}

enable_services() {
    systemctl daemon-reload
    systemctl disable --now sslh >/dev/null 2>&1 || true
    systemctl disable --now juanmux >/dev/null 2>&1 || true
    for service in cron nginx xray squid stunnel4 ErwanTCP ErwanTLS ErwanWS ErwanDNS ErwanDNSTT udp udp2 badvpn-udpgw ddos erwanssh erwan-dns-forwarding; do
        systemctl enable "$service" >/dev/null
    done
    systemctl enable openvpn-server@tcp openvpn-server@udp >/dev/null
}

run_component_setups() {
    DOMAIN_FILE="${TARGET_DIR}/domain" \
    NS_FILE="${TARGET_DIR}/nameserver" \
    SERVER_KEY="${TARGET_DIR}/server.key" \
    SERVER_PUB="${TARGET_DIR}/server.pub" \
    STATUS_LOG="${TARGET_DIR}/status.log" \
    DNSTT_BIN="${TARGET_DIR}/dnstt-server" \
    "$TARGET_DIR/ErwanDNS" --install
    DOMAIN_FILE="${TARGET_DIR}/domain" "$TARGET_DIR/ErwanWS" --install
    DOMAIN_FILE="${TARGET_DIR}/domain" "$TARGET_DIR/ErwanTCP" --install
    DEFAULT_USER="${DEFAULT_USER:-default-user}" "$TARGET_DIR/ErwanXRAY"
    DOMAIN_FILE="${TARGET_DIR}/domain" "$TARGET_DIR/ErwanNGINX"
}

start_services() {
    for service in cron ssh erwanssh xray nginx squid stunnel4 ErwanTCP ErwanTLS ErwanWS ErwanDNS ErwanDNSTT udp udp2 badvpn-udpgw ddos erwan-dns-forwarding openvpn-server@tcp openvpn-server@udp; do
        systemctl restart "$service" >/dev/null
    done
}

verify_install_artifacts() {
    local missing=0
    local required_paths=(
        "$TARGET_DIR/ErwanMenu"
        "$TARGET_DIR/ErwanTCP"
        "$TARGET_DIR/ErwanWS"
        "$TARGET_DIR/ErwanDNS"
        "$TARGET_DIR/ErwanXRAY"
        "/etc/systemd/system/xray.service"
        "/etc/systemd/system/erwanssh.service"
        "/etc/systemd/system/erwan-dns-forwarding.service"
        "/etc/systemd/system/udp.service"
        "/etc/systemd/system/udp2.service"
        "/lib/systemd/system/badvpn-udpgw.service"
        "/lib/systemd/system/ErwanWS.service"
        "/lib/systemd/system/ErwanDNS.service"
        "/lib/systemd/system/ErwanDNSTT.service"
        "/usr/bin/menu"
    )

    for path in "${required_paths[@]}"; do
        if [ ! -e "$path" ]; then
            echo "Missing required install artifact: $path"
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo "Installer stopped because one or more required files or units were not created."
        exit 1
    fi
}

ensure_swap() {
    local swapfile="${SWAPFILE:-/swapfile}"
    local swapsize="${SWAP_SIZE:-2G}"
    local swapmb

    swapmb="$(numfmt --from=iec "$swapsize" | awk '{print int($1/1024/1024)}')"

    if [ ! -f "$swapfile" ]; then
        echo "Creating swap file: $swapfile ($swapsize)"
        fallocate -l "$swapsize" "$swapfile" 2>/dev/null || \
        dd if=/dev/zero of="$swapfile" bs=1M count="$swapmb" status=progress
        chmod 600 "$swapfile"
        mkswap "$swapfile"
    fi

    swapon "$swapfile" 2>/dev/null || true

    grep -qE '^[^#]*\s+/swapfile\s+none\s+swap\s' /etc/fstab || \
        echo '/swapfile none swap sw 0 0' >> /etc/fstab

    cat > /etc/sysctl.d/99-swap-tuning.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl -p /etc/sysctl.d/99-swap-tuning.conf >/dev/null
    free -m
}

main() {
    load_cloudflare_env
    load_original_cloudflare_defaults
    install_packages
    ensure_swap
    validate_domain_inputs
    generate_cloudflare_records
    write_domain_state
    write_server_metadata
    TARGET_DIR="$TARGET_DIR" bash "$SCRIPT_DIR/install-components.sh"
    build_erwanssh_runtime
    write_nginx_base
    ensure_tls_material
    ensure_xray_binary
    ensure_hysteria_binaries
    ensure_dnstt_binary
    ensure_badvpn_binary
    write_squid_files
    run_component_setups
    ensure_real_tls_material
    write_udp_config
    write_openvpn_configs
    publish_openvpn_downloads
    configure_openvpn_forwarding
    write_badvpn_unit
    write_ddos_unit
    write_profile_banner
    write_cron
    write_fix_letsencrypt_helper
    verify_install_artifacts
    enable_services
    start_services
    echo "VIPER PANEL installer completed."
    echo "Domain      : ${DOMAIN}"
    echo "Nameserver  : ${NAMESERVER}"
    echo "SSH         : ${DOMAIN}:22"
    echo "Multiplexer : ${DOMAIN}:443"
    echo "OpenVPN TCP : ${DOMAIN}:1194"
    echo "OpenVPN UDP : ${DOMAIN}:110"
    echo "TCP OVPN    : http://${DOMAIN}/openvpn/tcp.ovpn"
    echo "UDP OVPN    : http://${DOMAIN}/openvpn/udp.ovpn"
    echo "CA Cert     : http://${DOMAIN}/openvpn/ca.crt"
    echo "Xray WS     : ${DOMAIN}:443"
    echo "Hysteria v1 : ${DOMAIN}:${HYSTERIA_V1_PORT}"
    echo "Hysteria v2 : ${DOMAIN}:${HYSTERIA_V2_PORT}"
    echo "SSH Direct  : ${DOMAIN}:22"
    echo "SSH SSL     : ${DOMAIN}:111 (recommended) / ${DOMAIN}:443 (shared mux)"
    echo "Admin SSH   : ${DOMAIN}:2222"
    echo "Menu command: menu"
}

main "$@"

TARGET_DIR="/etc/ErwanScript"
IP_HOST=$(wget -4qO- http://ipinfo.io/ip 2>/dev/null || echo "0.0.0.0")
DOMAIN=$(cat "$TARGET_DIR/domain" 2>/dev/null || echo "N/A")
NS=$(cat "$TARGET_DIR/nameserver" 2>/dev/null || echo "N/A")
PUB_KEY=$(cat "$TARGET_DIR/server.pub" 2>/dev/null | tr -d '\n')

TCP_PORT="1194"
UDP_PORT="110"
SSH_PORT="22"
SSL_PORT="111 (recommended), 443 (shared mux)"
WS_PORT="700,8880,8888,8010,2052,2082,2086,2095"
SDNS_PORT="5300"
XRAY_PORT="443,8443,8388"
SQUID_PORT="8000,8080"
HYSTERIA_V1_META_PORT="$(jq -r '.udp_hysteria_v1_port // .udp_hysteria_port // empty' "$TARGET_DIR/server-info.json" 2>/dev/null || true)"
HYSTERIA_V2_META_PORT="$(jq -r '.udp_hysteria_v2_port // empty' "$TARGET_DIR/server-info.json" 2>/dev/null || true)"
HYSTERIA_V1_OBFS="$(jq -r '.udp_hysteria_v1_obfs // .udp_hysteria_obfs // "viperpanel"' "$TARGET_DIR/server-info.json" 2>/dev/null || echo "viperpanel")"
HYSTERIA_V2_OBFS="$(jq -r '.udp_hysteria_v2_obfs // "viperpanel"' "$TARGET_DIR/server-info.json" 2>/dev/null || echo "viperpanel")"
[ -n "$HYSTERIA_V1_META_PORT" ] || HYSTERIA_V1_META_PORT="$HYSTERIA_V1_PORT"
[ -n "$HYSTERIA_V2_META_PORT" ] || HYSTERIA_V2_META_PORT="$HYSTERIA_V2_PORT"

SERVER_JSON=$(cat <<EOF
{
  "tcp_port": "$TCP_PORT",
  "udp_port": "$UDP_PORT",
  "ssh_port": "$SSH_PORT",
  "ssl_port": "$SSL_PORT",
  "ws_port": "$WS_PORT",
  "sdns_port": "$SDNS_PORT",
  "xray_port": "$XRAY_PORT",
  "squid_port": "$SQUID_PORT",
  "hysteria_port": "$HYSTERIA_V1_META_PORT",
  "hysteria_obfs": "$HYSTERIA_V1_OBFS",
  "hysteria_v1_port": "$HYSTERIA_V1_META_PORT",
  "hysteria_v1_obfs": "$HYSTERIA_V1_OBFS",
  "hysteria_v2_port": "$HYSTERIA_V2_META_PORT",
  "hysteria_v2_obfs": "$HYSTERIA_V2_OBFS",
  "ip_host": "$IP_HOST",
  "domain": "$DOMAIN",
  "name_server": "$NS",
  "public_key": "$PUB_KEY",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

FIREBASE_URL="https://viperpanel-cd232-default-rtdb.firebaseio.com/info.json?auth=QPVJxKzGoNO7GrgK9xZQMTuKLWudQV7s5mYJmQ84"
curl -X POST -H "Content-Type: application/json" -d "$SERVER_JSON" "$FIREBASE_URL"

echo "Installation Completed"

reboot
