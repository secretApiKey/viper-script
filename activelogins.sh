#!/bin/bash

set -euo pipefail

XRAY_IP_LOCK_DIR="${XRAY_IP_LOCK_DIR:-/etc/ErwanScript/xray-ip-lock}"
XRAY_BLOCK_DIR="${XRAY_BLOCK_DIR:-/etc/ErwanScript/xray-ip-block}"
XRAY_LOCK_TTL_SECONDS="${XRAY_LOCK_TTL_SECONDS:-60}"
OVPN_TCP_STATUS="${OVPN_TCP_STATUS:-/etc/openvpn/tcp_stats.log}"
OVPN_UDP_STATUS="${OVPN_UDP_STATUS:-/etc/openvpn/udp_stats.log}"
DNSTT_PORT="${DNSTT_PORT:-5300}"
HYSTERIA_V1_PORT="${HYSTERIA_V1_PORT:-36712}"
HYSTERIA_V2_PORT="${HYSTERIA_V2_PORT:-36713}"

now="$(date +%s)"

ssh_count="$(ps -eo user=,cmd= | awk '/sshd-session/ && $1 != "root" { count++ } END { print count + 0 }')"
ovpn_count="$(awk -F',' '$1=="CLIENT_LIST" && $2 != "" { count++ } END { print count + 0 }' "$OVPN_TCP_STATUS" "$OVPN_UDP_STATUS" 2>/dev/null)"

xray_allowed=0
if [ -d "$XRAY_IP_LOCK_DIR" ]; then
    xray_allowed="$(find "$XRAY_IP_LOCK_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r state_file; do
        awk -v now="$now" -v ttl="$XRAY_LOCK_TTL_SECONDS" '
            $1 != "127.0.0.1" && $1 != "::1" && NF >= 2 && (now - $2) <= ttl { count++ }
            END { print count + 0 }
        ' "$state_file"
    done | awk '{ total += $1 } END { print total + 0 }')"
fi

xray_blocked=0
if [ -d "$XRAY_BLOCK_DIR" ]; then
    xray_blocked="$(find "$XRAY_BLOCK_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r block_file; do
        awk -v now="$now" -v ttl="$XRAY_LOCK_TTL_SECONDS" '
            $1 != "127.0.0.1" && $1 != "::1" && NF >= 2 && (now - $2) <= ttl { count++ }
            END { print count + 0 }
        ' "$block_file"
    done | awk '{ total += $1 } END { print total + 0 }')"
fi

xray_count=$((xray_allowed + xray_blocked))

dnstt_count=0
udp_count=0

if command -v conntrack >/dev/null 2>&1; then
    dnstt_count="$(conntrack -L -p udp 2>/dev/null | awk -v port="$DNSTT_PORT" '
        $0 ~ ("dport=" port) {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) {
                    split($i, a, "=")
                    if (a[2] != "127.0.0.1" && a[2] != "::1") {
                        seen[a[2]] = 1
                    }
                }
            }
        }
        END {
            for (ip in seen) count++
            print count + 0
        }
    ')"

    udp_count="$(conntrack -L -p udp 2>/dev/null | awk -v port1="$HYSTERIA_V1_PORT" -v port2="$HYSTERIA_V2_PORT" '
        $0 ~ ("dport=" port1) || $0 ~ ("dport=" port2) {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) {
                    split($i, a, "=")
                    if (a[2] != "127.0.0.1" && a[2] != "::1") {
                        seen[a[2]] = 1
                    }
                }
            }
        }
        END {
            for (ip in seen) count++
            print count + 0
        }
    ')"
fi

total_count=$((ssh_count + ovpn_count + dnstt_count + udp_count + xray_count))
uptime_text="$(uptime -p 2>/dev/null | sed 's/^up //')"
[ -n "$uptime_text" ] || uptime_text="unavailable"
active_sockets="$(ss -tun state established 2>/dev/null | awk 'NR>1 { count++ } END { print count + 0 }')"

echo "TOTAL=$total_count | Uptime=$uptime_text | ActiveSocket=$active_sockets"
