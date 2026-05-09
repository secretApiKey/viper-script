#!/bin/bash

LOG_FILE="${USER_LIMIT_LOG:-/etc/ErwanScript/logs/useradd-limit.log}"
STATE_DIR="${USER_LIMIT_STATE_DIR:-/etc/ErwanScript/user-lock}"
MULTILOGIN_FILE="${USER_LIMIT_MULTILOGIN_FILE:-/etc/ErwanScript/multilogin.txt}"
MULTILOGIN_DEFAULT_FILE="${USER_LIMIT_MULTILOGIN_DEFAULT_FILE:-/etc/ErwanScript/multilogin-default.txt}"
OVPN_CHAIN_NAME="${USER_LIMIT_OVPN_CHAIN:-ERWANSCRIPT_OVPN_LOCK}"
OVPN_TCP_STATUS="${USER_LIMIT_OVPN_TCP_STATUS:-/etc/openvpn/tcp_stats.log}"
OVPN_UDP_STATUS="${USER_LIMIT_OVPN_UDP_STATUS:-/etc/openvpn/udp_stats.log}"
OVPN_PORTS="${USER_LIMIT_OVPN_PORTS:-1194,443}"
FREEZE_SECONDS="${USER_LIMIT_FREEZE_SECONDS:-3600}"

mkdir -p /etc/ErwanScript/logs "$STATE_DIR"
touch "$LOG_FILE" "$MULTILOGIN_FILE" "$MULTILOGIN_DEFAULT_FILE"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

normalize_ip() {
    echo "$1" | sed -E 's/^\[//; s/\]$//; s/^::ffff://'
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
    iptables -nL "$OVPN_CHAIN_NAME" >/dev/null 2>&1 || iptables -N "$OVPN_CHAIN_NAME"
    iptables -C INPUT -p tcp -m multiport --dports "$OVPN_PORTS" -j "$OVPN_CHAIN_NAME" >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp -m multiport --dports "$OVPN_PORTS" -j "$OVPN_CHAIN_NAME"
    iptables -C INPUT -p udp -m multiport --dports "$OVPN_PORTS" -j "$OVPN_CHAIN_NAME" >/dev/null 2>&1 || \
        iptables -I INPUT -p udp -m multiport --dports "$OVPN_PORTS" -j "$OVPN_CHAIN_NAME"
}

block_ip() {
    local ip="$1"
    iptables -C "$OVPN_CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1 || iptables -A "$OVPN_CHAIN_NAME" -s "$ip" -j REJECT
}

unblock_ip() {
    local ip="$1"
    while iptables -C "$OVPN_CHAIN_NAME" -s "$ip" -j REJECT >/dev/null 2>&1; do
        iptables -D "$OVPN_CHAIN_NAME" -s "$ip" -j REJECT
    done
}

is_account_locked() {
    local user="$1"
    passwd -S "$user" 2>/dev/null | awk '{print $2}' | grep -q '^L$'
}

freeze_shell_path() {
    if [ -x /usr/sbin/nologin ]; then
        printf '/usr/sbin/nologin'
    elif [ -x /sbin/nologin ]; then
        printf '/sbin/nologin'
    else
        printf '/bin/false'
    fi
}

current_user_shell() {
    local user="$1"
    getent passwd "$user" | awk -F: '{print $7}'
}

freeze_account_php_style() {
    local user="$1"
    local freeze_shell

    usermod -L "$user" >/dev/null 2>&1
    freeze_shell="$(freeze_shell_path)"
    usermod -s "$freeze_shell" "$user" >/dev/null 2>&1 || true
}

unfreeze_account_php_style() {
    local user="$1"
    local original_shell="${2:-}"

    usermod -U "$user" >/dev/null 2>&1
    if [ -n "$original_shell" ] && [ "$original_shell" != "$(freeze_shell_path)" ]; then
        usermod -s "$original_shell" "$user" >/dev/null 2>&1 || true
    fi
}

freeze_state_file() {
    local user="$1"
    echo "$STATE_DIR/freeze-$user"
}

kill_ssh_sessions_for_user() {
    local user="$1"

    pkill -KILL -u "$user" 2>/dev/null
    pkill -f -KILL "^sshd-session: $user$" 2>/dev/null
    pkill -f -KILL "sshd-session: $user" 2>/dev/null
    pkill -f -KILL "^sshd: ${user}@" 2>/dev/null
    pkill -f -KILL "sshd: ${user} " 2>/dev/null
}

record_ip_for_user() {
    local user="$1"
    local ip="$2"
    local state_file

    state_file=$(freeze_state_file "$user")
    [ -n "$ip" ] || return 0
    [ -f "$state_file" ] || return 0

    grep -qxF "$ip" "$state_file" 2>/dev/null || echo "$ip" >> "$state_file"
}

freeze_user() {
    local user="$1"
    local now="$2"
    local reason="$3"
    local state_file was_locked original_shell freeze_shell

    state_file=$(freeze_state_file "$user")
    if [ -f "$state_file" ]; then
        return 0
    fi

    original_shell="$(current_user_shell "$user")"
    freeze_shell="$(freeze_shell_path)"

    if is_account_locked "$user"; then
        was_locked=1
    else
        was_locked=0
        freeze_account_php_style "$user"
    fi

    {
        echo "FREEZE_UNTIL=$((now + FREEZE_SECONDS))"
        echo "WAS_LOCKED=$was_locked"
        echo "ORIGINAL_SHELL=$original_shell"
        echo "FREEZE_SHELL=$freeze_shell"
    } > "$state_file"

    kill_ssh_sessions_for_user "$user"
    log "Frozen account '$user' for $FREEZE_SECONDS seconds due to duplicate connection ($reason)"
}

thaw_user() {
    local user="$1"
    local state_file="$2"
    local was_locked="" ip="" original_shell="" freeze_shell=""

    [ -f "$state_file" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            WAS_LOCKED) was_locked="$value" ;;
            ORIGINAL_SHELL) original_shell="$value" ;;
            FREEZE_SHELL) freeze_shell="$value" ;;
        esac
    done < "$state_file"

    if [ "$was_locked" = "0" ]; then
        if [ -n "$original_shell" ] && [ "$original_shell" != "$freeze_shell" ]; then
            unfreeze_account_php_style "$user" "$original_shell"
        else
            unfreeze_account_php_style "$user"
        fi
    fi

    while IFS= read -r ip; do
        case "$ip" in
            ""|FREEZE_UNTIL=*|WAS_LOCKED=*) continue ;;
        esac
        unblock_ip "$ip"
    done < "$state_file"

    rm -f "$state_file"
    log "Unfroze account '$user' because the current session count is within the configured limit"
}

ssh_session_count() {
    local user="$1"
    ps -eo pid=,user=,cmd= | awk -v user="$user" '
        $2 == user && ($0 ~ /sshd-session/ || $0 ~ /sshd: .*@/) {
            count++
        }
        END { print count + 0 }
    '
}

openvpn_ip_count() {
    local user="$1"
    {
        collect_openvpn_entries "$OVPN_TCP_STATUS"
        collect_openvpn_entries "$OVPN_UDP_STATUS"
    } | awk -F'|' -v user="$user" '$1 == user { print $2 }' | awk 'NF' | sort -u | wc -l
}

reconcile_frozen_users() {
    local state_file user limit ssh_count ovpn_count

    for state_file in "$STATE_DIR"/freeze-*; do
        [ -f "$state_file" ] || continue
        user=${state_file##*/freeze-}
        limit=$(user_limit "$user")
        ssh_count=$(ssh_session_count "$user")
        ovpn_count=$(openvpn_ip_count "$user")
        if [ "$ssh_count" -le "$limit" ] && [ "$ovpn_count" -le "$limit" ]; then
            thaw_user "$user" "$state_file"
        fi
    done
}

unfreeze_expired_users() {
    local now state_file user freeze_until was_locked ip original_shell freeze_shell

    now=$(date +%s)

    for state_file in "$STATE_DIR"/freeze-*; do
        [ -f "$state_file" ] || continue

        user=${state_file##*/freeze-}
        freeze_until=""
        was_locked=""
        original_shell=""
        freeze_shell=""

        while IFS='=' read -r key value; do
            case "$key" in
                FREEZE_UNTIL) freeze_until="$value" ;;
                WAS_LOCKED) was_locked="$value" ;;
                ORIGINAL_SHELL) original_shell="$value" ;;
                FREEZE_SHELL) freeze_shell="$value" ;;
            esac
        done < "$state_file"

        [ -n "$freeze_until" ] || continue
        [ "$now" -lt "$freeze_until" ] && continue

        if [ "$was_locked" = "0" ]; then
            if [ -n "$original_shell" ] && [ "$original_shell" != "$freeze_shell" ]; then
                unfreeze_account_php_style "$user" "$original_shell"
            else
                unfreeze_account_php_style "$user"
            fi
        fi

        while IFS= read -r ip; do
            case "$ip" in
                ""|FREEZE_UNTIL=*|WAS_LOCKED=*) continue ;;
            esac
            unblock_ip "$ip"
        done < "$state_file"

        rm -f "$state_file"
        log "Unfroze account '$user' after freeze expiry"
    done
}

handle_frozen_users() {
    local now state_file user freeze_until ip

    now=$(date +%s)

    for state_file in "$STATE_DIR"/freeze-*; do
        [ -f "$state_file" ] || continue

        user=${state_file##*/freeze-}
        freeze_until=""

        while IFS='=' read -r key value; do
            case "$key" in
                FREEZE_UNTIL) freeze_until="$value" ;;
            esac
        done < "$state_file"

        [ -n "$freeze_until" ] || continue
        [ "$now" -ge "$freeze_until" ] && continue

        kill_ssh_sessions_for_user "$user"

        while IFS= read -r ip; do
            case "$ip" in
                ""|FREEZE_UNTIL=*|WAS_LOCKED=*) continue ;;
            esac
            block_ip "$ip"
        done < "$state_file"
    done
}

limit_ssh_sessions() {
    local now users user pids pid_count limit

    now=$(date +%s)
    users=$(ps -eo user=,cmd= | awk '
        (/sshd-session/ || /sshd: .*@/) && $1 != "root" {
            print $1
        }
    ' | sort -u)

    for user in $users; do
        pids=$(ps -eo pid=,user=,cmd= | awk -v user="$user" '
            $2 == user && ($0 ~ /sshd-session/ || $0 ~ /sshd: .*@/) {
                print $1
            }
        ')

        pid_count=$(printf '%s\n' "$pids" | sed '/^$/d' | wc -l)
        limit=$(user_limit "$user")
        if [ "$pid_count" -gt "$limit" ]; then
            freeze_user "$user" "$now" "SSH multi-login limit $limit"
        fi
    done
}

collect_openvpn_entries() {
    local file="$1"

    [ -f "$file" ] || return 0
    awk -F',' '
        $1 == "CLIENT_LIST" && $2 != "" && $3 != "" {
            print $2 "|" $3
        }
    ' "$file" | while IFS='|' read -r user real_address; do
        printf '%s|%s\n' "$user" "$(normalize_ip "${real_address%%:*}")"
    done
}

limit_openvpn_sessions() {
    local now tmpfile user limit freeze_file ip_count ip

    ensure_chain
    now=$(date +%s)
    tmpfile="$(mktemp)"

    collect_openvpn_entries "$OVPN_TCP_STATUS" >> "$tmpfile"
    collect_openvpn_entries "$OVPN_UDP_STATUS" >> "$tmpfile"

    while IFS= read -r user; do
        [ -n "$user" ] || continue
        limit=$(user_limit "$user")
        freeze_file=$(freeze_state_file "$user")
        ip_count=$(awk -F'|' -v user="$user" '$1 == user { print $2 }' "$tmpfile" | awk 'NF' | sort -u | wc -l)

        if [ -f "$freeze_file" ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                record_ip_for_user "$user" "$ip"
                block_ip "$ip"
            done < <(awk -F'|' -v user="$user" '$1 == user { print $2 }' "$tmpfile" | awk 'NF' | sort -u)
            continue
        fi

        if [ "$ip_count" -gt "$limit" ]; then
            freeze_user "$user" "$now" "OpenVPN multi-IP limit $limit"
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                record_ip_for_user "$user" "$ip"
                block_ip "$ip"
            done < <(awk -F'|' -v user="$user" '$1 == user { print $2 }' "$tmpfile" | awk 'NF' | sort -u)
        else
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                unblock_ip "$ip"
            done < <(awk -F'|' -v user="$user" '$1 == user { print $2 }' "$tmpfile" | awk 'NF' | sort -u)
        fi
    done < <(awk -F'|' '{ print $1 }' "$tmpfile" | awk 'NF' | sort -u)

    rm -f "$tmpfile"
}

reconcile_frozen_users
unfreeze_expired_users
handle_frozen_users
limit_ssh_sessions
limit_openvpn_sessions
