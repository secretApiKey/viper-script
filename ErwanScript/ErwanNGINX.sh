#!/bin/bash

set -euo pipefail

DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/conf.d/$(cat "${DOMAIN_FILE}" 2>/dev/null || echo domain.invalid).conf}"
DOMAIN_NAME="$(cat "$DOMAIN_FILE" 2>/dev/null || echo "_")"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN_NAME}"

mkdir -p "$(dirname "$NGINX_SITE")"

if [ -z "$DOMAIN_NAME" ] || [ "$DOMAIN_NAME" = "_" ] || [ "$DOMAIN_NAME" = "domain.invalid" ]; then
    echo "A valid domain is required before writing nginx config." >&2
    exit 1
fi

if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    echo "TLS certificate files were not found for ${DOMAIN_NAME} in ${CERT_DIR}." >&2
    exit 1
fi

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    listen 777 ssl reuseport;
    listen [::]:777 ssl reuseport;    
    server_name ${DOMAIN_NAME};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
        try_files \$uri =404;
    }

    location ^~ /openvpn/ {
        try_files \$uri =404;
    }

    location = /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:14016;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /vless-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:14017;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:23456;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /vmess-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:23457;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /trojan-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:25432;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /trojan-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:25433;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location = /ss-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:30300;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:700;
        proxy_http_version 1.1;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
}
EOF

nginx -t
systemctl reload nginx

echo "Nginx site written to $NGINX_SITE"
echo "WebSocket/Xray TLS backend for the 443 multiplexer listens on :777."
