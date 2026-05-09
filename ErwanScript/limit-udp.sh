#!/bin/bash

LOG_FILE="${UDP_LIMIT_LOG:-/etc/ErwanScript/logs/udp-limit.log}"
AUTH_LOG="${UDP_AUTH_LOG:-/etc/ErwanScript/udp-auth.log}"
STATE_DIR="${UDP_LIMIT_STATE_DIR:-/etc/ErwanScript/udp-ip-lock}"
BLOCK_DIR="${UDP_LIMIT_BLOCK_DIR:-/etc/ErwanScript/udp-ip-block}"
CURSOR_FILE="${UDP_LIMIT_CURSOR_FILE:-/etc/ErwanScript/udp-limit.cursor}"
CHAIN_NAME="${UDP_LIMIT_CHAIN:-ERWANSCRIPT_UDP_LOCK}"
LOCK_TTL_SECONDS="${UDP_LOCK_TTL_SECONDS:-300}"
MULTILOGIN_FILE="${UDP_LIMIT_MULTILOGIN_FILE:-/etc/ErwanScript/multilogin.txt}"
MULTILOGIN_DEFAULT_FILE="${UDP_LIMIT_MULTILOGIN_DEFAULT_FILE:-/etc/ErwanScript/multilogin-default.txt}"
HYSTERIA_PORTS="${UDP_LIMIT_PORTS:-36712,36713}"

mkdir -p /etc/ErwanScript/logs "$STATE_DIR" "$BLOCK_DIR"
touch "$LOG_FILE" "$MULTILOGIN_FILE" "$MULTILOGIN_DEFAULT_FILE"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

normalize_ip() {
    echo "$1" | sed -E 's#^(tcp|udp):##; s#^\[##; s#\]$##; s#^::ffff:##; s#:[0-9]+$##'
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

ensure_chain() {
    iptables -nL "$CHAIN_NAME" >/dev/null 2>&1 || iptables -N "$CHAIN_NAME"
    iptables -C INPUT -p udp -m multiport --dports "$HYSTERIA_PORTS" -j "$CHAIN_NAME" >/dev/null 2>&1 || \
        iptables -I INPUT -p udp -m multiport --dports "$HYSTERIA_PORTS" -j "$CHAIN_NAME"
}

block_ip() {
    local ip="$1"
    iptables -C "$CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1 || iptables -A "$CHAIN_NAME" -s "$ip" -j REJECT
}

unblock_ip() {
    local ip="$1"
    while iptables -C "$CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1; do
        iptables -D "$CHAIN_NAME" -s "$ip" -j REJECT
    done
}

terminate_ip_connections() {
    local ip="$1"
    local port
    local old_ifs="$IFS"

    command -v conntrack >/dev/null 2>&1 || return 0
    IFS=,
    for port in $HYSTERIA_PORTS; do
        conntrack -D -p udp --orig-src "$ip" --dport "$port" >/dev/null 2>&1 || true
    done
    IFS="$old_ifs"
}

state_file_for_user() {
    printf '%s/%s\n' "$STATE_DIR" "$1"
}

block_file_for_user() {
    printf '%s/%s\n' "$BLOCK_DIR" "$1"
}

prune_file() {
    local file="$1"
    local now="$2"
    local tmp_file

    [ -f "$file" ] || return 0
    tmp_file="$(mktemp "${file}.tmp.XXXXXX")"
    awk -v now="$now" -v ttl="$LOCK_TTL_SECONDS" 'NF >= 2 && (now - $2) <= ttl { print $1, $2 }' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
    [ -s "$file" ] || rm -f "$file"
}

touch_ip_state() {
    local file="$1"
    local ip="$2"
    local now="$3"
    local tmp_file

    [ -f "$file" ] || : > "$file"
    tmp_file="$(mktemp "${file}.tmp.XXXXXX")"
    awk -v ip="$ip" -v now="$now" '
        $1 == ip { print ip, now; updated=1; next }
        NF >= 2 { print }
        END { if (!updated) print ip, now }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
}

remove_ip_state() {
    local file="$1"
    local ip="$2"
    local tmp_file

    [ -f "$file" ] || return 0
    tmp_file="$(mktemp "${file}.tmp.XXXXXX")"
    awk -v ip="$ip" '$1 != ip { print }' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
    [ -s "$file" ] || rm -f "$file"
}

extract_field() {
    local key="$1"
    sed -nE "s/.* ${key}=([^ ]+).*/\\1/p"
}

read_new_auth_lines() {
    local current_inode current_size saved_inode saved_offset offset

    [ -f "$AUTH_LOG" ] || return 0
    current_inode="$(stat -c '%i' "$AUTH_LOG" 2>/dev/null || echo 0)"
    current_size="$(stat -c '%s' "$AUTH_LOG" 2>/dev/null || echo 0)"
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

    python3 - "$AUTH_LOG" "$offset" <<'PY'
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

find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r file; do
    prune_file "$file" "$now"
done
find "$BLOCK_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r file; do
    prune_file "$file" "$now"
done

while IFS= read -r line; do
    local_user="$(printf '%s\n' "$line" | extract_field user)"
    local_status="$(printf '%s\n' "$line" | extract_field status)"
    local_addr="$(printf '%s\n' "$line" | extract_field addr)"
    local_ip=""
    safe_user=""
    state_file=""
    block_file=""
    limit=1
    current_count=0

    [ "$local_status" = "accept" ] || continue
    [ -n "$local_user" ] || continue
    [ -n "$local_addr" ] || continue

    local_ip="$(normalize_ip "$local_addr")"
    [ -n "$local_ip" ] || continue

    safe_user="$(printf '%s' "$local_user" | tr -c 'A-Za-z0-9_.-' '_')"
    state_file="$(state_file_for_user "$safe_user")"
    block_file="$(block_file_for_user "$safe_user")"
    limit="$(user_limit "$local_user")"

    prune_file "$state_file" "$now"
    prune_file "$block_file" "$now"

    unblock_ip "$local_ip"
    remove_ip_state "$block_file" "$local_ip"

    if [ ! -f "$state_file" ]; then
        touch_ip_state "$state_file" "$local_ip" "$now"
        log "Locked UDP user '$local_user' to IP $local_ip (limit $limit)"
        continue
    fi

    if awk -v ip="$local_ip" '$1 == ip { found=1 } END { exit(found ? 0 : 1) }' "$state_file"; then
        touch_ip_state "$state_file" "$local_ip" "$now"
        continue
    fi

    current_count="$(awk 'NF >= 2 { count++ } END { print count + 0 }' "$state_file")"
    if [ "$current_count" -lt "$limit" ]; then
        touch_ip_state "$state_file" "$local_ip" "$now"
        log "Added UDP IP $local_ip for user '$local_user' ($((current_count + 1))/$limit slots)"
        continue
    fi

    touch_ip_state "$block_file" "$local_ip" "$now"
    block_ip "$local_ip"
    terminate_ip_connections "$local_ip"
    log "Blocked UDP IP $local_ip for user '$local_user'; active slot limit is $limit"
done < <(read_new_auth_lines)

