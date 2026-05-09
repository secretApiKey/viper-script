#!/bin/bash

LOG_FILE="/etc/ErwanScript/logs/xray-limit.log"
ACCESS_LOG="${XRAY_ACCESS_LOG:-/var/log/xray/access.log}"
STATE_DIR="${XRAY_LIMIT_STATE_DIR:-/etc/ErwanScript/xray-ip-lock}"
BLOCK_DIR="${XRAY_LIMIT_BLOCK_DIR:-/etc/ErwanScript/xray-ip-block}"
DISABLED_DIR="${XRAY_LIMIT_DISABLED_DIR:-/etc/ErwanScript/xray-disabled}"
CURSOR_FILE="${XRAY_LIMIT_CURSOR_FILE:-/etc/ErwanScript/xray-limit.cursor}"
CHAIN_NAME="${XRAY_LIMIT_CHAIN:-XRAY_UUID_LOCK}"
LOCK_TTL_SECONDS="${XRAY_LOCK_TTL_SECONDS:-60}"
XRAY_PORTS="${XRAY_LIMIT_PORTS:-80,443,8443,8388}"
ENFORCE_BLOCKS="${XRAY_LIMIT_ENFORCE_BLOCKS:-1}"
MULTILOGIN_FILE="${XRAY_LIMIT_MULTILOGIN_FILE:-/etc/ErwanScript/multilogin.txt}"
MULTILOGIN_DEFAULT_FILE="${XRAY_LIMIT_MULTILOGIN_DEFAULT_FILE:-/etc/ErwanScript/multilogin-default.txt}"
XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"

mkdir -p /etc/ErwanScript/logs "$STATE_DIR" "$BLOCK_DIR" "$DISABLED_DIR"
touch "$MULTILOGIN_FILE" "$MULTILOGIN_DEFAULT_FILE"

if [ ! -f "$ACCESS_LOG" ]; then
    echo "$(date) ERROR: Access log not found: $ACCESS_LOG" >> "$LOG_FILE"
    exit 1
fi

ensure_chain() {
    iptables -nL "$CHAIN_NAME" >/dev/null 2>&1 || iptables -N "$CHAIN_NAME"
    iptables -C INPUT -p tcp -m multiport --dports "$XRAY_PORTS" -j "$CHAIN_NAME" >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp -m multiport --dports "$XRAY_PORTS" -j "$CHAIN_NAME"
}

block_ip() {
    local ip="$1"
    if [ "$ENFORCE_BLOCKS" != "1" ]; then
        echo "$(date) Violation detected for IP $ip, but firewall blocking is disabled (XRAY_LIMIT_ENFORCE_BLOCKS=$ENFORCE_BLOCKS)" >> "$LOG_FILE"
        return 0
    fi
    iptables -C "$CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1 || iptables -A "$CHAIN_NAME" -s "$ip" -j REJECT
    terminate_ip_connections "$ip"
}

unblock_ip() {
    local ip="$1"
    if [ "$ENFORCE_BLOCKS" != "1" ]; then
        return 0
    fi
    while iptables -C "$CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1; do
        iptables -D "$CHAIN_NAME" -s "$ip" -j REJECT
    done
}

normalize_ip() {
    echo "$1" | sed -E 's/^\[//; s/\]$//; s/^::ffff://'
}

is_ignored_ip() {
    case "$1" in
        127.0.0.1|::1|localhost)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

user_limit() {
    local user="$1"
    local limit

    limit="$(awk -v key="$user" '$1 == key { print $2; exit }' "$MULTILOGIN_FILE" 2>/dev/null)"
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -le 0 ]; then
        limit="$(head -n 1 "$MULTILOGIN_DEFAULT_FILE" 2>/dev/null)"
    fi
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -le 0 ]; then
        limit=1
    fi
    echo "$limit"
}

terminate_ip_connections() {
    local ip="$1"
    local port

    command -v conntrack >/dev/null 2>&1 || return 0

    OLD_IFS="$IFS"
    IFS=,
    for port in $XRAY_PORTS; do
        conntrack -D -p tcp --orig-src "$ip" --dport "$port" >/dev/null 2>&1 || true
        conntrack -D -p udp --orig-src "$ip" --dport "$port" >/dev/null 2>&1 || true
    done
    IFS="$OLD_IFS"
}

block_file_for_user() {
    printf '%s/%s\n' "$BLOCK_DIR" "$1"
}

disabled_file_for_user() {
    printf '%s/%s.json\n' "$DISABLED_DIR" "$1"
}

prune_state_file() {
    local state_file="$1"
    local now="$2"
    local tmp_file

    [ -f "$state_file" ] || return 0
    tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
    awk -v now="$now" -v ttl="$LOCK_TTL_SECONDS" '
        NF >= 2 && (now - $2) <= ttl { print $1, $2 }
    ' "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"
    if ! [ -s "$state_file" ]; then
        rm -f "$state_file"
    fi
}

prune_block_file() {
    local block_file="$1"
    local now="$2"
    local tmp_file

    [ -f "$block_file" ] || return 0
    tmp_file="$(mktemp "${block_file}.tmp.XXXXXX")"
    awk -v now="$now" -v ttl="$LOCK_TTL_SECONDS" '
        NF >= 2 && (now - $2) <= ttl { print $1, $2 }
    ' "$block_file" > "$tmp_file"
    mv "$tmp_file" "$block_file"
    if ! [ -s "$block_file" ]; then
        rm -f "$block_file"
    fi
}

touch_ip_state() {
    local state_file="$1"
    local ip="$2"
    local now="$3"
    local tmp_file

    [ -f "$state_file" ] || : > "$state_file"
    tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

    awk -v ip="$ip" -v now="$now" '
        $1 == ip { print ip, now; updated=1; next }
        NF >= 2 { print }
        END { if (!updated) print ip, now }
    ' "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"
}

touch_block_state() {
    local block_file="$1"
    local ip="$2"
    local now="$3"
    local tmp_file

    [ -f "$block_file" ] || : > "$block_file"
    tmp_file="$(mktemp "${block_file}.tmp.XXXXXX")"

    awk -v ip="$ip" -v now="$now" '
        $1 == ip { print ip, now; updated=1; next }
        NF >= 2 { print }
        END { if (!updated) print ip, now }
    ' "$block_file" > "$tmp_file"
    mv "$tmp_file" "$block_file"
}

remove_block_state_ip() {
    local block_file="$1"
    local ip="$2"
    local tmp_file

    [ -f "$block_file" ] || return 0
    tmp_file="$(mktemp "${block_file}.tmp.XXXXXX")"
    awk -v ip="$ip" '$1 != ip { print }' "$block_file" > "$tmp_file"
    mv "$tmp_file" "$block_file"
    if ! [ -s "$block_file" ]; then
        rm -f "$block_file"
    fi
}

clear_block_state() {
    local block_file="$1"
    local ip

    [ -f "$block_file" ] || return 0
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        unblock_ip "$ip"
    done < <(awk 'NF >= 2 { print $1 }' "$block_file")
    rm -f "$block_file"
}

clear_user_runtime_state() {
    local safe_user="$1"
    clear_block_state "$(block_file_for_user "$safe_user")"
    rm -f "$STATE_DIR/$safe_user"
}

extract_ip() {
    echo "$1" | sed -nE 's/.*from ([^ ]+) accepted.*/\1/p' | sed -E 's#^(tcp|udp):##; s/:[0-9]+$//'
}

extract_user() {
    echo "$1" | sed -nE 's/.*email: ([^ ]+).*/\1/p'
}

disable_xray_user() {
    local user="$1"
    local safe_user="$2"
    local observed_slots="$3"
    local disabled_file

    [ -f "$XRAY_CONFIG" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    disabled_file="$(disabled_file_for_user "$safe_user")"
    if [ -f "$disabled_file" ]; then
        return 0
    fi

    if ! python3 - "$XRAY_CONFIG" "$disabled_file" "$user" "$observed_slots" <<'PY'
import json, os, sys, tempfile

config_path, disabled_path, user, observed_slots = sys.argv[1:5]
observed_slots = int(observed_slots)

with open(config_path, 'r', encoding='utf-8') as handle:
    config = json.load(handle)

removed = {"user": user, "observed_slots": observed_slots, "vless": [], "vmess": [], "trojan": [], "shadowsocks": []}

for inbound in config.get("inbounds", []):
    protocol = inbound.get("protocol")
    settings = inbound.get("settings") or {}
    clients = settings.get("clients")
    if not isinstance(clients, list):
        continue

    kept = []
    deleted = []
    for client in clients:
        if protocol in ("trojan", "shadowsocks"):
            key = client.get("email", "")
        else:
            key = client.get("name") or client.get("email") or ""
        if key == user:
            deleted.append(client)
        else:
            kept.append(client)

    if deleted and protocol in removed:
        removed[protocol].extend(deleted)
        settings["clients"] = kept

if not any(removed[p] for p in ("vless", "vmess", "trojan", "shadowsocks")):
    sys.exit(2)

fd_cfg, tmp_cfg = tempfile.mkstemp(prefix='xray-config.', suffix='.json', dir=os.path.dirname(config_path))
fd_dis, tmp_dis = tempfile.mkstemp(prefix='xray-disabled.', suffix='.json', dir=os.path.dirname(disabled_path))
try:
    with os.fdopen(fd_cfg, 'w', encoding='utf-8') as handle:
        json.dump(config, handle, indent=2)
        handle.write('\n')
    with os.fdopen(fd_dis, 'w', encoding='utf-8') as handle:
        json.dump(removed, handle, indent=2)
        handle.write('\n')
    os.replace(tmp_cfg, config_path)
    os.replace(tmp_dis, disabled_path)
    os.chmod(config_path, 0o644)
    os.chmod(disabled_path, 0o644)
finally:
    for path in (tmp_cfg, tmp_dis):
        if os.path.exists(path):
            os.unlink(path)
PY
    then
        echo "$(date) ERROR: Failed to disable Xray user $user in config" >> "$LOG_FILE"
        return 1
    fi
    clear_user_runtime_state "$safe_user"
    systemctl restart xray >/dev/null 2>&1 || true
    echo "$(date) Disabled Xray user $user after exceeding active slot limit ($observed_slots slots observed)" >> "$LOG_FILE"
}

restore_xray_user() {
    local safe_user="$1"
    local disabled_file user

    [ -f "$XRAY_CONFIG" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    disabled_file="$(disabled_file_for_user "$safe_user")"
    [ -f "$disabled_file" ] || return 0

    user="$(python3 - "$disabled_file" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
print(data.get('user', ''))
PY
)"
    [ -n "$user" ] || return 0

if ! python3 - "$XRAY_CONFIG" "$disabled_file" <<'PY'
import json, os, sys, tempfile

config_path, disabled_path = sys.argv[1:3]

with open(config_path, 'r', encoding='utf-8') as handle:
    config = json.load(handle)
with open(disabled_path, 'r', encoding='utf-8') as handle:
    disabled = json.load(handle)

for inbound in config.get("inbounds", []):
    protocol = inbound.get("protocol")
    settings = inbound.get("settings") or {}
    clients = settings.get("clients")
    if not isinstance(clients, list):
        continue
    existing_keys = set()
    for client in clients:
        if protocol in ("trojan", "shadowsocks"):
            key = client.get("email", "")
        else:
            key = client.get("name") or client.get("email") or ""
        if key:
            existing_keys.add(key)

    for client in disabled.get(protocol, []):
        if protocol in ("trojan", "shadowsocks"):
            key = client.get("email", "")
        else:
            key = client.get("name") or client.get("email") or ""
        if key and key in existing_keys:
            continue
        clients.append(client)
        if key:
            existing_keys.add(key)

fd_cfg, tmp_cfg = tempfile.mkstemp(prefix='xray-config.', suffix='.json', dir=os.path.dirname(config_path))
try:
    with os.fdopen(fd_cfg, 'w', encoding='utf-8') as handle:
        json.dump(config, handle, indent=2)
        handle.write('\n')
    os.replace(tmp_cfg, config_path)
    os.chmod(config_path, 0o644)
finally:
    if os.path.exists(tmp_cfg):
        os.unlink(tmp_cfg)
PY
    then
        echo "$(date) ERROR: Failed to restore Xray user $user in config" >> "$LOG_FILE"
        return 1
    fi
    rm -f "$disabled_file"
    clear_user_runtime_state "$safe_user"
    systemctl restart xray >/dev/null 2>&1 || true
    echo "$(date) Restored Xray user $user after multilogin limit was increased" >> "$LOG_FILE"
}

prune_all_state_files() {
    local now="$1"
    local state_file

    [ -d "$STATE_DIR" ] || return 0
    find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r state_file; do
        prune_state_file "$state_file" "$now"
    done
}

reconcile_chain() {
    local active_ips desired_ips ip

    if [ "$ENFORCE_BLOCKS" != "1" ]; then
        return 0
    fi

    desired_ips="$(
        find "$BLOCK_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r state_file; do
            awk 'NF >= 2 { print $1 }' "$state_file"
        done | sort -u
    )"

    active_ips="$(iptables -S "$CHAIN_NAME" 2>/dev/null | awk '/-A/ && /-s/ && /-j REJECT/ { for (i = 1; i <= NF; i++) if ($i == "-s") { print $(i+1); break } }')"

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if ! printf '%s\n' "$desired_ips" | grep -Fxq "$ip"; then
            unblock_ip "$ip"
        fi
    done <<< "$active_ips"

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        block_ip "$ip"
    done <<< "$desired_ips"
}

reconcile_existing_limits() {
    local state_file user limit tmp_file dropped_ips ip block_file state_count

    [ -d "$STATE_DIR" ] || return 0

    find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r state_file; do
        user="$(basename "$state_file")"
        limit="$(user_limit "$user")"
        block_file="$(block_file_for_user "$user")"
        state_count="$(awk 'NF >= 2 { count++ } END { print count + 0 }' "$state_file")"

        if [ "$state_count" -lt "$limit" ]; then
            clear_block_state "$block_file"
        fi

        tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

        awk -v limit="$limit" '
            NF >= 2 {
                entries[++n] = $0
                ips[n] = $1
                ts[n] = $2
            }
            END {
                for (i = 1; i <= n; i++) {
                    for (j = i + 1; j <= n; j++) {
                        if (ts[j] > ts[i]) {
                            tmp = entries[i]; entries[i] = entries[j]; entries[j] = tmp
                            tmp = ips[i]; ips[i] = ips[j]; ips[j] = tmp
                            tmp = ts[i]; ts[i] = ts[j]; ts[j] = tmp
                        }
                    }
                }
                keep = (limit < n ? limit : n)
                for (i = 1; i <= keep; i++) {
                    print entries[i]
                }
                for (i = keep + 1; i <= n; i++) {
                    print ips[i] > "/dev/stderr"
                }
            }
        ' "$state_file" > "$tmp_file" 2> "${tmp_file}.drop"

        mv "$tmp_file" "$state_file"
        if ! [ -s "$state_file" ]; then
            rm -f "$state_file"
        fi

        if [ -f "${tmp_file}.drop" ]; then
            dropped_ips="$(cat "${tmp_file}.drop")"
            rm -f "${tmp_file}.drop"
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                if ! is_ignored_ip "$ip"; then
                    touch_block_state "$block_file" "$ip" "$now"
                    block_ip "$ip"
                    echo "$(date) Reconciled user $user to limit $limit by blocking IP $ip" >> "$LOG_FILE"
                fi
            done <<< "$dropped_ips"
        fi
    done
}

reconcile_disabled_users() {
    local disabled_file safe_user user limit observed_slots

    [ -d "$DISABLED_DIR" ] || return 0
    find "$DISABLED_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | while IFS= read -r disabled_file; do
        safe_user="$(basename "$disabled_file" .json)"
        user="$(jq -r '.user // empty' "$disabled_file" 2>/dev/null)"
        observed_slots="$(jq -r '.observed_slots // 0' "$disabled_file" 2>/dev/null)"
        [ -n "$user" ] || continue
        limit="$(user_limit "$user")"
        if [[ "$observed_slots" =~ ^[0-9]+$ ]] && [ "$observed_slots" -le "$limit" ]; then
            restore_xray_user "$safe_user"
        fi
    done
}

read_new_access_lines() {
    local current_inode current_size saved_inode saved_offset offset

    current_inode="$(stat -c '%i' "$ACCESS_LOG" 2>/dev/null || echo 0)"
    current_size="$(stat -c '%s' "$ACCESS_LOG" 2>/dev/null || echo 0)"
    saved_inode=0
    saved_offset=0

    if [ -f "$CURSOR_FILE" ]; then
        read -r saved_inode saved_offset < "$CURSOR_FILE" || true
    fi

    if ! [[ "$saved_offset" =~ ^[0-9]+$ ]]; then
        saved_offset=0
    fi

    if [ "$saved_inode" != "$current_inode" ] || [ "$saved_offset" -gt "$current_size" ]; then
        offset=0
    else
        offset="$saved_offset"
    fi

    python3 - "$ACCESS_LOG" "$offset" <<'PY'
import sys
path = sys.argv[1]
offset = int(sys.argv[2])
with open(path, 'r', encoding='utf-8', errors='replace') as handle:
    handle.seek(offset)
    data = handle.read()
    print(data, end='')
PY

    printf '%s %s\n' "$current_inode" "$current_size" > "$CURSOR_FILE"
}

ensure_chain
now=$(date +%s)
prune_all_state_files "$now"
find "$BLOCK_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r block_file; do
    prune_block_file "$block_file" "$now"
done
reconcile_disabled_users
reconcile_existing_limits

while IFS= read -r line; do
    user=$(extract_user "$line")
    ip=$(extract_ip "$line")
    limit=""
    safe_user=""
    state_file=""
    block_file=""
    current_count=0

    if [ -z "$user" ] || [ -z "$ip" ]; then
        continue
    fi

    ip=$(normalize_ip "$ip")
    if is_ignored_ip "$ip"; then
        continue
    fi
    safe_user=$(printf '%s' "$user" | tr -c 'A-Za-z0-9_.-' '_')
    state_file="$STATE_DIR/$safe_user"
    block_file="$(block_file_for_user "$safe_user")"
    limit=$(user_limit "$user")
    prune_state_file "$state_file" "$now"
    prune_block_file "$block_file" "$now"
    unblock_ip "$ip"
    remove_block_state_ip "$block_file" "$ip"

    if [ ! -f "$state_file" ]; then
        touch_ip_state "$state_file" "$ip" "$now"
        echo "$(date) Locked user $user to IP $ip (limit $limit)" >> "$LOG_FILE"
        continue
    fi

    if awk -v ip="$ip" '$1 == ip { found=1 } END { exit(found ? 0 : 1) }' "$state_file"; then
        touch_ip_state "$state_file" "$ip" "$now"
        continue
    fi

    current_count=$(awk 'NF >= 2 { count++ } END { print count + 0 }' "$state_file")
    if [ "$current_count" -lt "$limit" ]; then
        touch_ip_state "$state_file" "$ip" "$now"
        echo "$(date) Added IP $ip for user $user ($((current_count + 1))/$limit active slots)" >> "$LOG_FILE"
        continue
    fi

    touch_block_state "$block_file" "$ip" "$now"
    block_ip "$ip"
    disable_xray_user "$user" "$safe_user" "$((current_count + 1))"
    if [ "$ENFORCE_BLOCKS" = "1" ]; then
        echo "$(date) Blocked IP $ip for user $user; active slot limit is $limit" >> "$LOG_FILE"
    else
        echo "$(date) Detected excess IP $ip for user $user; active slot limit is $limit and blocking is disabled" >> "$LOG_FILE"
    fi
done < <(read_new_access_lines)

reconcile_chain
