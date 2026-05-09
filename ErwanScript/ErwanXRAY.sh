#!/bin/bash

set -euo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
XRAY_UUID_FILE="${XRAY_UUID_FILE:-/etc/xray/uuid}"
XRAY_SERVICE="${XRAY_SERVICE:-/etc/systemd/system/xray.service}"
DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
XRAY_DIRECT_TLS_PORT="${XRAY_DIRECT_TLS_PORT:-8443}"
XRAY_SS_DIRECT_PORT="${XRAY_SS_DIRECT_PORT:-8388}"
XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
DEFAULT_USER="${DEFAULT_USER:-default-user}"

mkdir -p /etc/xray /var/log/xray

if [ ! -x /usr/local/bin/xray ]; then
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    wget -O "$tmpdir/xray.zip" "$XRAY_DOWNLOAD_URL"
    unzip -q "$tmpdir/xray.zip" -d "$tmpdir/xray"
    install -m 0755 "$tmpdir/xray/xray" /usr/local/bin/xray
fi

if [ ! -f "$XRAY_UUID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid > "$XRAY_UUID_FILE"
fi

UUID_VALUE="$(cat "$XRAY_UUID_FILE")"
DOMAIN_NAME="$(cat "$DOMAIN_FILE" 2>/dev/null || echo "")"
CERT_FILE="/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem"
XRAY_CERT_FILE="/etc/xray/tls.crt"
XRAY_KEY_FILE="/etc/xray/tls.key"

touch /var/log/xray/access.log /var/log/xray/error.log
chown -R www-data:www-data /var/log/xray
chmod 0755 /var/log/xray
chmod 0644 /var/log/xray/access.log /var/log/xray/error.log

if [ -n "$DOMAIN_NAME" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    install -m 0644 "$CERT_FILE" "$XRAY_CERT_FILE"
    install -m 0640 "$KEY_FILE" "$XRAY_KEY_FILE"
    chown www-data:www-data "$XRAY_CERT_FILE" "$XRAY_KEY_FILE"
fi

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
    {
      "port": ${XRAY_DIRECT_TLS_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "name": "${DEFAULT_USER}", "email": "${DEFAULT_USER}", "id": "${UUID_VALUE}" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${XRAY_CERT_FILE}",
              "keyFile": "${XRAY_KEY_FILE}"
            }
          ]
        }
      }
    },
    {
      "port": ${XRAY_SS_DIRECT_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "clients": [
          {
            "method": "aes-128-gcm",
            "password": "${UUID_VALUE}",
            "email": "${DEFAULT_USER}"
          }
        ],
        "network": "tcp,udp"
      }
    },
    {
      "port": 14016,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "name": "${DEFAULT_USER}", "email": "${DEFAULT_USER}", "id": "${UUID_VALUE}" }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "port": 14017,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "name": "${DEFAULT_USER}", "email": "${DEFAULT_USER}", "id": "${UUID_VALUE}" }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": { "path": "/vless-hu" }
      }
    },
    {
      "port": 23456,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "name": "${DEFAULT_USER}", "email": "${DEFAULT_USER}", "id": "${UUID_VALUE}" }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess" }
      }
    },
    {
      "port": 23457,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "name": "${DEFAULT_USER}", "email": "${DEFAULT_USER}", "id": "${UUID_VALUE}" }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": { "path": "/vmess-hu" }
      }
    },
    {
      "port": 25432,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {
        "decryption": "none",
        "clients": [
          { "password": "${UUID_VALUE}", "email": "${DEFAULT_USER}" }
        ],
        "udp": true
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan-ws" }
      }
    },
    {
      "port": 25433,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {
        "decryption": "none",
        "clients": [
          { "password": "${UUID_VALUE}", "email": "${DEFAULT_USER}" }
        ],
        "udp": true
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": { "path": "/trojan-hu" }
      }
    },
    {
      "port": 30300,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [
          {
            "method": "aes-128-gcm",
            "password": "${UUID_VALUE}",
            "email": "${DEFAULT_USER}"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ss-ws" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "blackhole", "settings": {}, "tag": "blocked" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      }
    ]
  },
  "stats": {},
  "api": {
    "services": [
      "StatsService"
    ],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  }
}
EOF

cat > "$XRAY_SERVICE" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

echo "Xray config written to $XRAY_CONFIG using the live VPS shape"
echo "UUID saved to $XRAY_UUID_FILE"
echo "Direct VLESS TLS is enabled on :${XRAY_DIRECT_TLS_PORT}"
echo "Direct Shadowsocks is enabled on :${XRAY_SS_DIRECT_PORT}"
