#!/bin/bash

set -euo pipefail

DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
ISSUE_NET="${ISSUE_NET:-/etc/issue.net}"
SERVER_BANNER_FILE="${SERVER_BANNER_FILE:-/etc/ErwanScript/banner}"
SYSTEM_SSH_CONFIG="${SYSTEM_SSH_CONFIG:-/etc/ssh/sshd_config}"
ERWANSSH_DIR="${ERWANSSH_DIR:-/etc/ErwanSSH}"
ERWANSSH_CONFIG="${ERWANSSH_CONFIG:-${ERWANSSH_DIR}/etc/sshd_config}"
ERWANSSH_BUNDLE_DIR="${ERWANSSH_BUNDLE_DIR:-/etc/ErwanScript/ErwanSSH}"
STUNNEL_CONF="${STUNNEL_CONF:-/etc/stunnel/stunnel.conf}"
STUNNEL_CERT="${STUNNEL_CERT:-/etc/stunnel/stunnel.crt}"
STUNNEL_KEY="${STUNNEL_KEY:-/etc/stunnel/stunnel.key}"
STUNNEL_UNIT="${STUNNEL_UNIT:-/etc/systemd/system/stunnel4.service}"
TCP_UNIT="${TCP_UNIT:-/lib/systemd/system/ErwanTCP.service}"
TLS_UNIT="${TLS_UNIT:-/lib/systemd/system/ErwanTLS.service}"
ERWANSSH_UNIT="${ERWANSSH_UNIT:-/etc/systemd/system/erwanssh.service}"
SYSTEM_SSH_OVERRIDE_DIR="${SYSTEM_SSH_OVERRIDE_DIR:-/etc/systemd/system/ssh.service.d}"
SYSTEM_SSH_OVERRIDE_FILE="${SYSTEM_SSH_OVERRIDE_FILE:-${SYSTEM_SSH_OVERRIDE_DIR}/override.conf}"
SSH_PORT="${SSH_PORT:-2222}"
ERWANSSH_PORT="${ERWANSSH_PORT:-22}"
SSH_VERSION_ADDENDUM="${SSH_VERSION_ADDENDUM:-none}"
SSHD_SERVICE_TYPE="${SSHD_SERVICE_TYPE:-simple}"
OPENSSH_PATCH_BRAND="${OPENSSH_PATCH_BRAND:-OpenSSH-ErwanScript}"
ERWANSSH_BUILD_ROOT="${ERWANSSH_BUILD_ROOT:-/usr/local/src/erwanssh-build}"
ERWANSSH_PORTABLE_VERSION="${ERWANSSH_PORTABLE_VERSION:-}"
ERWANSSH_PORTABLE_URL="${ERWANSSH_PORTABLE_URL:-}"
MUX_PORT="${MUX_PORT:-443}"
MUX_TLS_PORT="${MUX_TLS_PORT:-777}"
OPENVPN_TCP_PORT="${OPENVPN_TCP_PORT:-1194}"
INTERNAL_PLAIN_MUX_PORT="${INTERNAL_PLAIN_MUX_PORT:-4443}"
INTERNAL_TLS_SSL_PORT="${INTERNAL_TLS_SSL_PORT:-4454}"
CUSTOM_HTTP_METHODS="${CUSTOM_HTTP_METHODS:-}"
CUSTOM_HTTP_METHODS_FILE="${CUSTOM_HTTP_METHODS_FILE:-/etc/ErwanScript/custom-http-methods.txt}"
ERWANSSH_SFTP_SERVER="${ERWANSSH_SFTP_SERVER:-}"

detect_sftp_server_path() {
    local candidate

    if [ -n "$ERWANSSH_SFTP_SERVER" ] && [ -x "$ERWANSSH_SFTP_SERVER" ]; then
        printf '%s\n' "$ERWANSSH_SFTP_SERVER"
        return 0
    fi

    for candidate in \
        /usr/lib/openssh/sftp-server \
        /usr/libexec/openssh/sftp-server \
        /usr/libexec/sftp-server; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v sftp-server >/dev/null 2>&1; then
        command -v sftp-server
        return 0
    fi

    echo "Unable to locate sftp-server on this system." >&2
    return 1
}

repair_erwanssh_runtime_layout() {
    local nested_dir subdir

    nested_dir="${ERWANSSH_DIR}/ErwanSSH"
    [ -d "$nested_dir" ] || return 0

    for subdir in bin etc libexec sbin share var; do
        if [ -d "${nested_dir}/${subdir}" ] && [ ! -e "${ERWANSSH_DIR}/${subdir}" ]; then
            ln -s "${nested_dir}/${subdir}" "${ERWANSSH_DIR}/${subdir}"
        fi
    done
}

link_erwanssh_helpers() {
    local helper target

    mkdir -p "${ERWANSSH_DIR}/libexec"

    for helper in sshd-session sshd-auth; do
        if [ -x "${ERWANSSH_DIR}/libexec/${helper}" ]; then
            continue
        fi

        for target in \
            "${ERWANSSH_DIR}/ErwanSSH/libexec/${helper}" \
            "${ERWANSSH_DIR}/libexec/${helper}"; do
            if [ -x "$target" ]; then
                ln -sfn "$target" "${ERWANSSH_DIR}/libexec/${helper}"
                break
            fi
        done
    done
}

current_erwanssh_is_patched() {
    local binary

    for binary in \
        "${ERWANSSH_DIR}/sbin/sshd" \
        "${ERWANSSH_DIR}/libexec/sshd-session" \
        "${ERWANSSH_DIR}/libexec/sshd-auth"; do
        if [ ! -x "$binary" ]; then
            return 1
        fi
        if ! strings "$binary" 2>/dev/null | grep -Fq "$OPENSSH_PATCH_BRAND"; then
            return 1
        fi
    done

    return 0
}

detect_openssh_portable_version() {
    local version

    if [ -n "$ERWANSSH_PORTABLE_VERSION" ]; then
        printf '%s\n' "$ERWANSSH_PORTABLE_VERSION"
        return 0
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        version="$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null | sed -E 's/^[0-9]+://; s/-.*$//')"
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    if command -v sshd >/dev/null 2>&1; then
        version="$(sshd -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+\.[0-9]+p[0-9]+).*$/\1/p' | head -n 1)"
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    printf '%s\n' "10.0p1"
}

download_openssh_portable_source() {
    local version="$1"
    local archive="openssh-${version}.tar.gz"
    local url="${ERWANSSH_PORTABLE_URL:-https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${archive}}"

    mkdir -p "$ERWANSSH_BUILD_ROOT"
    rm -rf "${ERWANSSH_BUILD_ROOT}/openssh-${version}" "${ERWANSSH_BUILD_ROOT}/${archive}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "${ERWANSSH_BUILD_ROOT}/${archive}"
    else
        wget -qO "${ERWANSSH_BUILD_ROOT}/${archive}" "$url"
    fi

    tar -xzf "${ERWANSSH_BUILD_ROOT}/${archive}" -C "$ERWANSSH_BUILD_ROOT"
}

patch_openssh_version_header() {
    local source_dir="$1"

    python3 - "$source_dir/version.h" "$OPENSSH_PATCH_BRAND" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
brand = sys.argv[2]
q = chr(34)
content = "\n".join([
    "/* patched for ErwanSSH */",
    "",
    f"#define SSH_VERSION\t{q}{brand}{q}",
    "",
    f"#define SSH_PORTABLE\t{q}{q}",
    "#define SSH_RELEASE_MINIMUM\tSSH_VERSION SSH_PORTABLE",
    "#ifdef SSH_EXTRAVERSION",
    "#undef SSH_EXTRAVERSION",
    "#endif",
    f"#define SSH_RELEASE\t{q}{brand}{q}",
    "",
])
path.write_text(content, encoding="utf-8")
PY
}

ensure_erwanssh_build_requirements() {
    if command -v gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "apt-get is required to install ErwanSSH build dependencies." >&2
        return 1
    fi

    export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
    apt-get update
    apt-get install -y build-essential ca-certificates curl libpam0g-dev libssl-dev python3 zlib1g-dev
}

build_patched_erwanssh_runtime() {
    local version source_dir

    if current_erwanssh_is_patched; then
        echo "Patched ErwanSSH runtime already installed."
        return 0
    fi

    ensure_erwanssh_build_requirements
    version="$(detect_openssh_portable_version)"
    download_openssh_portable_source "$version"
    source_dir="${ERWANSSH_BUILD_ROOT}/openssh-${version}"

    patch_openssh_version_header "$source_dir"

    (
        cd "$source_dir"
        ./configure \
            --prefix="${ERWANSSH_DIR}" \
            --sbindir="${ERWANSSH_DIR}/sbin" \
            --bindir="${ERWANSSH_DIR}/bin" \
            --libexecdir="${ERWANSSH_DIR}/libexec" \
            --sysconfdir="${ERWANSSH_DIR}/etc" \
            --with-pam \
            --with-privsep-path="${ERWANSSH_DIR}/var/empty" \
            >/tmp/erwanssh-configure.log 2>&1
        make -j"$(nproc)" sshd sshd-session sshd-auth >/tmp/erwanssh-make.log 2>&1
    )

    mkdir -p "${ERWANSSH_DIR}/sbin" "${ERWANSSH_DIR}/libexec"
    rm -f "${ERWANSSH_DIR}/sbin/sshd" "${ERWANSSH_DIR}/libexec/sshd-session" "${ERWANSSH_DIR}/libexec/sshd-auth"
    install -m 0755 "${source_dir}/sshd" "${ERWANSSH_DIR}/sbin/sshd"
    install -m 0755 "${source_dir}/sshd-session" "${ERWANSSH_DIR}/libexec/sshd-session"
    install -m 0755 "${source_dir}/sshd-auth" "${ERWANSSH_DIR}/libexec/sshd-auth"
}

write_system_ssh_config() {
    local sftp_server

    sftp_server="$(detect_sftp_server_path)"
    mkdir -p "$(dirname "$SYSTEM_SSH_CONFIG")"
    cat > "$SYSTEM_SSH_CONFIG" <<EOF
# This is the sshd server system-wide configuration file.  See
# sshd_config(5) for more information.

Include /etc/ssh/sshd_config.d/*.conf

Port ${SSH_PORT}
ListenAddress 0.0.0.0
ListenAddress ::
Protocol 2
SyslogFacility AUTH
LogLevel INFO
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
PermitTunnel yes
TCPKeepAlive yes
UseDNS no
PubkeyAuthentication no
IgnoreRhosts yes
HostbasedAuthentication no
PermitEmptyPasswords no
AcceptEnv LANG LC_*
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha256,diffie-hellman-group-exchange-sha1
Ciphers aes128-ctr,aes192-ctr,aes256-ctr
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha1
LoginGraceTime 0
MaxStartups 100:5:1000
Subsystem sftp ${sftp_server}
ClientAliveInterval 120
ClientAliveCountMax 3
PermitRootLogin yes
PasswordAuthentication yes
VersionAddendum ${SSH_VERSION_ADDENDUM}
Banner /etc/issue.net
EOF
}

write_erwanssh_config() {
    local sftp_server

    sftp_server="$(detect_sftp_server_path)"
    mkdir -p "${ERWANSSH_DIR}/etc" "${ERWANSSH_DIR}/libexec" "${ERWANSSH_DIR}/sbin" "${ERWANSSH_DIR}/var/empty"
    for key_type in rsa ecdsa ed25519; do
        local hostkey="${ERWANSSH_DIR}/etc/ssh_host_${key_type}_key"
        if [ ! -f "$hostkey" ]; then
            ssh-keygen -q -N "" -t "$key_type" -f "$hostkey"
        fi
    done
    if [ ! -x "${ERWANSSH_DIR}/libexec/sftp-server" ]; then
        ln -sfn "$sftp_server" "${ERWANSSH_DIR}/libexec/sftp-server"
    fi
    cat > "$ERWANSSH_CONFIG" <<EOF
Port ${ERWANSSH_PORT}
ListenAddress ::
ListenAddress 0.0.0.0
Protocol 2
HostKey ${ERWANSSH_DIR}/etc/ssh_host_rsa_key
HostKey ${ERWANSSH_DIR}/etc/ssh_host_ecdsa_key
HostKey ${ERWANSSH_DIR}/etc/ssh_host_ed25519_key
SyslogFacility AUTH
LogLevel INFO
PermitRootLogin no
StrictModes yes
PubkeyAuthentication no
IgnoreRhosts yes
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication yes
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PermitTunnel yes
PrintLastLog yes
AcceptEnv LANG LC_*
Subsystem sftp ${ERWANSSH_DIR}/libexec/sftp-server
UsePAM yes
Banner /etc/banner
TCPKeepAlive yes
UseDNS no
ClientAliveInterval 120
ClientAliveCountMax 3
VersionAddendum ${SSH_VERSION_ADDENDUM}
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha256,diffie-hellman-group-exchange-sha1
Ciphers aes128-ctr,aes192-ctr,aes256-ctr
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha1
LoginGraceTime 0
MaxStartups 100:5:1000
EOF
}

prepare_erwanssh_bundle() {
    local sftp_server

    if [ -d "$ERWANSSH_BUNDLE_DIR" ]; then
        mkdir -p "$ERWANSSH_DIR"
        cp -a "${ERWANSSH_BUNDLE_DIR}/." "$ERWANSSH_DIR/"
    fi
    repair_erwanssh_runtime_layout
    mkdir -p "${ERWANSSH_DIR}/etc" "${ERWANSSH_DIR}/libexec" "${ERWANSSH_DIR}/sbin" "${ERWANSSH_DIR}/var/empty"
    rm -f "${ERWANSSH_DIR}/etc"/ssh_host_*_key "${ERWANSSH_DIR}/etc"/ssh_host_*.pub 2>/dev/null || true
    chmod 0755 "${ERWANSSH_DIR}/bin" "${ERWANSSH_DIR}/libexec" "${ERWANSSH_DIR}/sbin" "${ERWANSSH_DIR}/var" "${ERWANSSH_DIR}/var/empty" 2>/dev/null || true
    chmod 0755 "${ERWANSSH_DIR}/bin/"* "${ERWANSSH_DIR}/libexec/"* "${ERWANSSH_DIR}/sbin/"* 2>/dev/null || true
    chmod 0644 "${ERWANSSH_DIR}/etc/"* 2>/dev/null || true
    chmod 0600 "${ERWANSSH_DIR}/etc/ssh_host_"*_key 2>/dev/null || true
    chmod 0644 "${ERWANSSH_DIR}/etc/ssh_host_"*.pub 2>/dev/null || true
    if [ ! -x "${ERWANSSH_DIR}/sbin/sshd" ]; then
        ln -sf /usr/sbin/sshd "${ERWANSSH_DIR}/sbin/sshd"
    fi
    sftp_server="$(detect_sftp_server_path)"
    if [ ! -x "${ERWANSSH_DIR}/libexec/sftp-server" ]; then
        ln -sfn "$sftp_server" "${ERWANSSH_DIR}/libexec/sftp-server"
    fi
    link_erwanssh_helpers
    rm -f /etc/JuanSSH 2>/dev/null || true
}

write_erwanssh_unit() {
    cat > "$ERWANSSH_UNIT" <<EOF
[Unit]
Description=ErwanSSH Server
Documentation=man:sshd(8) man:sshd_config(5)
After=network.target auditd.service

[Service]
Environment="PATH=${ERWANSSH_DIR}/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-${ERWANSSH_DIR}/sbin/sshd
ExecStartPre=${ERWANSSH_DIR}/sbin/sshd -t -f ${ERWANSSH_CONFIG}
ExecStart=${ERWANSSH_DIR}/sbin/sshd -D -f ${ERWANSSH_CONFIG} \$SSHD_OPTS
ExecReload=${ERWANSSH_DIR}/sbin/sshd -t -f ${ERWANSSH_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=${SSHD_SERVICE_TYPE}
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
Alias=erwansshd.service
EOF
}

write_system_ssh_override() {
    mkdir -p "$SYSTEM_SSH_OVERRIDE_DIR"
    cat > "$SYSTEM_SSH_OVERRIDE_FILE" <<EOF
[Service]
Environment="PATH=${ERWANSSH_DIR}/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStartPre=
ExecStart=
ExecReload=
ExecStartPre=${ERWANSSH_DIR}/sbin/sshd -t -f ${SYSTEM_SSH_CONFIG}
ExecStart=${ERWANSSH_DIR}/sbin/sshd -D -f ${SYSTEM_SSH_CONFIG}
ExecReload=${ERWANSSH_DIR}/sbin/sshd -t -f ${SYSTEM_SSH_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
EOF
}

write_stunnel() {
    mkdir -p /etc/stunnel
    touch /var/log/stunnel-users.log
    cat > "$STUNNEL_CONF" <<EOF
foreground = yes
pid = /etc/stunnel/stunnel.pid
cert = $STUNNEL_CERT
key  = $STUNNEL_KEY
client = no
socket = a:SO_REUSEADDR=0
TIMEOUTclose = 0
output = /var/log/stunnel-users.log
debug = 7
[ssl-direct]
accept = 0.0.0.0:111
connect = 127.0.0.1:${MUX_PORT}
EOF
}

write_stunnel_unit() {
    cat > "$STUNNEL_UNIT" <<EOF
[Unit]
Description=Stunnel TLS tunnel service
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 ${STUNNEL_CONF}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

write_units() {
    cat > "$TCP_UNIT" <<'EOF'
[Unit]
Description=ErwanTCP
After=network.target

[Service]
User=root
ExecStart=/etc/ErwanScript/ErwanTCP
Restart=always
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    cat > "$TLS_UNIT" <<'EOF'
[Unit]
Description=ErwanTLS
After=network.target

[Service]
User=root
ExecStart=/etc/ErwanScript/ErwanTLS
Restart=always
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

legacy_html_banner_block_do_not_use() {
    cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Viper Panel Server</title>
<style>
body {
    background-color: #000;
    color: #fff;
    font-family: Arial, sans-serif;
}
.box {
    border: 2px solid #555;
    padding: 20px;
    width: 400px;
    margin: 50px auto;
    text-align: center;
}
.yellow { color: yellow; }
.lime { color: lime; }
.cyan { color: cyan; }
.red { color: red; }
</style>
</head>
<body>
<div class="box">
<p class="yellow"><b>VIPER PANEL SERVER</b></p>
<p class="lime"><b>Fast, stable, and secure connection service.</b></p>

<p class="cyan"><b>This server belongs to the Viper Panel app.</b></p>
<p>Download Viper Panel on Google Play Store:</p>
<a href="https://play.google.com/store/apps/details?id=com.viper.panel">
https://play.google.com/store/apps/details?id=com.viper.panel
</a>

<p class="red"><b>Note:</b></p>
<p class="red">⚠ No torrent</p>
<p class="red">⚠ No abuse</p>
<p class="red">⚠ No spam</p>
<p class="red">⚠ No illegal activity</p>
</div>
</body>
</html>
EOF
}

# Active SSH banner text used for /etc/banner and /etc/issue.net.
write_ssh_banner_text() {
    cat <<'EOF'
VIPER PANEL SERVER
Fast, stable, and secure connection service.

This server belongs to the Viper Panel app.
Download Viper Panel on Google Play Store:
https://play.google.com/store/apps/details?id=com.viper.panel

Note:
! No torrent
! No abuse
! No spam
! No illegal activity
EOF
}

install_mode() {
    local domain
    domain="$(cat "$DOMAIN_FILE" 2>/dev/null || echo "example.com")"
    write_system_ssh_config
    prepare_erwanssh_bundle
    build_patched_erwanssh_runtime
    write_erwanssh_config
    write_erwanssh_unit
    write_system_ssh_override
    write_stunnel
    write_stunnel_unit
    write_units
    if [ -f "$SERVER_BANNER_FILE" ]; then
        install -m 0644 "$SERVER_BANNER_FILE" /etc/banner
        install -m 0644 "$SERVER_BANNER_FILE" "$ISSUE_NET"
    else
        write_ssh_banner_text "$domain" > /etc/banner
        write_ssh_banner_text "$domain" > "$ISSUE_NET"
    fi
    systemctl daemon-reload
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl enable erwanssh >/dev/null 2>&1 || true
    systemctl enable stunnel4 >/dev/null 2>&1 || true
    systemctl enable ErwanTCP >/dev/null 2>&1 || true
    systemctl enable ErwanTLS >/dev/null 2>&1 || true
    systemctl disable --now juanmux >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/juanmux.service
    echo "ErwanTCP, SSH, and 443 multiplexer installed."
    echo "ErwanSSH compatibility listener uses ${ERWANSSH_PORT}; stock admin SSH stays on ${SSH_PORT}."
}

serve_tcp() {
    python3 - "$DOMAIN_FILE" "$MUX_PORT" "$MUX_TLS_PORT" "$SSH_PORT" "$ERWANSSH_PORT" "$OPENVPN_TCP_PORT" "$INTERNAL_PLAIN_MUX_PORT" "$INTERNAL_TLS_SSL_PORT" "$CUSTOM_HTTP_METHODS" "$CUSTOM_HTTP_METHODS_FILE" <<'PY'
import asyncio
import struct
import sys
from contextlib import suppress

domain_file = sys.argv[1]
public_mux_port = int(sys.argv[2])
tls_backend_port = int(sys.argv[3])
ssh_port = int(sys.argv[4])
erwanssh_port = int(sys.argv[5])
openvpn_port = int(sys.argv[6])
plain_mux_port = int(sys.argv[7])
tls_ssl_port = int(sys.argv[8])
custom_http_methods = sys.argv[9]
custom_http_methods_file = sys.argv[10]

try:
    with open(domain_file, "r", encoding="utf-8") as fh:
        domain_name = fh.read().strip().lower()
except OSError:
    domain_name = ""

def parse_custom_methods(raw: str) -> set[str]:
    methods = set()
    for method in raw.replace(",", " ").split():
        token = method.strip().upper()
        if token and token.isascii():
            methods.add(token)
    return methods

def load_custom_methods_file(path: str) -> set[str]:
    methods = set()
    if not path:
        return methods
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                methods |= parse_custom_methods(line)
    except OSError:
        pass
    return methods

BASE_HTTP_METHODS = ("GET", "POST", "HEAD", "PUT", "PATCH", "OPTIONS", "DELETE", "TRACE", "PRI", "CONNECT", "GET-RAY", "RAY", "VERSION-CONTROL")
CUSTOM_HTTP_METHOD_SET = parse_custom_methods(custom_http_methods) | load_custom_methods_file(custom_http_methods_file)
HTTP_METHODS = tuple(f"{method} ".encode("ascii") for method in tuple(BASE_HTTP_METHODS) + tuple(sorted(CUSTOM_HTTP_METHOD_SET)))
SSH_PREFIX = b"SSH-"
FALLBACK_TIMEOUT = 3.0
XRAY_HTTP_PATH_PORTS = {
    "/vless": 14016,
    "/vless-hu": 14017,
    "/vmess": 23456,
    "/vmess-hu": 23457,
    "/trojan-ws": 25432,
    "/trojan-hu": 25433,
    "/ss-ws": 30300,
}
HTTP_HEADER_PREFIXES = (
    b"host:",
    b"upgrade:",
    b"connection:",
    b"x-real-host:",
    b"x-online-host:",
    b"x-forward-host:",
    b"x-host:",
    b"x-port:",
    b"x-pass:",
    b"x-target-protocol:",
)

def is_tls_client_hello(data: bytes) -> bool:
    return len(data) >= 6 and data[0] == 0x16 and data[1] == 0x03 and data[5] == 0x01

def is_openvpn_tcp(data: bytes) -> bool:
    sample = data.lstrip(b"\r\n")
    if len(sample) < 3:
        return False
    frame_len = struct.unpack("!H", sample[:2])[0]
    if frame_len < 1 or frame_len > 8192:
        return False
    if len(sample) >= frame_len + 2:
        opcode = sample[2] >> 3
        return opcode in {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    opcode = sample[2] >> 3
    return opcode in {7, 8, 10}

def log_detected(message: str):
    print(message, flush=True)

def log_ssh_detected():
    log_detected("SSH-2.0-OpenSSH-ErwanScript")

def extract_http_path(data: bytes) -> str:
    try:
        line = data.split(b"\r\n", 1)[0].decode("ascii", "ignore")
        parts = line.split()
        if len(parts) >= 2:
            return parts[1]
    except Exception:
        return ""
    return ""

def is_payload_upgrade_request(data: bytes) -> bool:
    lowered = data.lower()
    if b"connection: upgrade" in lowered or b"upgrade: websocket" in lowered:
        return True
    if b"/cdn-cgi/trace" in lowered:
        return True
    if lowered.startswith(b"get-ray "):
        return True
    if lowered.startswith(b"version-control "):
        return True
    first_token = lowered.split(b" ", 1)[0].decode("ascii", "ignore").upper()
    if first_token and first_token in CUSTOM_HTTP_METHOD_SET:
        return True
    return False

def lookup_xray_http_backend(path: str):
    if not path:
        return None
    if path in XRAY_HTTP_PATH_PORTS:
        return XRAY_HTTP_PATH_PORTS[path]
    for prefix, port in XRAY_HTTP_PATH_PORTS.items():
        if path.startswith(prefix + "/"):
            return port
    return None

def client_hello_mentions_domain(data: bytes) -> bool:
    if not domain_name:
        return False
    try:
        return domain_name.encode("idna") in data.lower()
    except Exception:
        return False

def extract_sni(data: bytes) -> str:
    try:
        if not is_tls_client_hello(data):
            return ""
        record_len = struct.unpack("!H", data[3:5])[0]
        if len(data) < 5 + record_len:
            return ""
        body = memoryview(data)[5:5 + record_len]
        if body[0] != 0x01:
            return ""
        hs_len = int.from_bytes(body[1:4], "big")
        hello = body[4:4 + hs_len]
        idx = 2 + 32
        session_len = hello[idx]
        idx += 1 + session_len
        cipher_len = struct.unpack("!H", hello[idx:idx + 2])[0]
        idx += 2 + cipher_len
        comp_len = hello[idx]
        idx += 1 + comp_len
        ext_len = struct.unpack("!H", hello[idx:idx + 2])[0]
        idx += 2
        end = idx + ext_len
        while idx + 4 <= end:
            ext_type = struct.unpack("!H", hello[idx:idx + 2])[0]
            ext_size = struct.unpack("!H", hello[idx + 2:idx + 4])[0]
            idx += 4
            ext = hello[idx:idx + ext_size]
            idx += ext_size
            if ext_type != 0x0000 or len(ext) < 5:
                continue
            list_len = struct.unpack("!H", ext[0:2])[0]
            pos = 2
            while pos + 3 <= 2 + list_len:
                name_type = ext[pos]
                name_len = struct.unpack("!H", ext[pos + 1:pos + 3])[0]
                pos += 3
                if name_type == 0 and pos + name_len <= len(ext):
                    return bytes(ext[pos:pos + name_len]).decode("idna", "ignore").lower()
                pos += name_len
    except Exception:
        return ""
    return ""

def extract_alpn_protocols(data: bytes) -> tuple[str, ...]:
    try:
        if not is_tls_client_hello(data):
            return ()
        record_len = struct.unpack("!H", data[3:5])[0]
        if len(data) < 5 + record_len:
            return ()
        body = memoryview(data)[5:5 + record_len]
        if body[0] != 0x01:
            return ()
        hs_len = int.from_bytes(body[1:4], "big")
        hello = body[4:4 + hs_len]
        idx = 2 + 32
        session_len = hello[idx]
        idx += 1 + session_len
        cipher_len = struct.unpack("!H", hello[idx:idx + 2])[0]
        idx += 2 + cipher_len
        comp_len = hello[idx]
        idx += 1 + comp_len
        ext_len = struct.unpack("!H", hello[idx:idx + 2])[0]
        idx += 2
        end = idx + ext_len
        while idx + 4 <= end:
            ext_type = struct.unpack("!H", hello[idx:idx + 2])[0]
            ext_size = struct.unpack("!H", hello[idx + 2:idx + 4])[0]
            idx += 4
            ext = hello[idx:idx + ext_size]
            idx += ext_size
            if ext_type != 0x0010 or len(ext) < 2:
                continue
            list_len = struct.unpack("!H", ext[0:2])[0]
            pos = 2
            protocols = []
            while pos < 2 + list_len and pos < len(ext):
                name_len = ext[pos]
                pos += 1
                if pos + name_len > len(ext):
                    break
                protocols.append(bytes(ext[pos:pos + name_len]).decode("ascii", "ignore").lower())
                pos += name_len
            return tuple(protocols)
    except Exception:
        return ()
    return ()

async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        with suppress(Exception):
            if writer.can_write_eof():
                writer.write_eof()
                await writer.drain()

async def proxy_stream(client_reader, client_writer, host, port, initial=b""):
    try:
        server_reader, server_writer = await asyncio.open_connection(host, port)
    except Exception:
        client_writer.close()
        with suppress(Exception):
            await client_writer.wait_closed()
        return
    if port == openvpn_port and initial:
        initial = initial.lstrip(b"\r\n")
    if initial:
        server_writer.write(initial)
        await server_writer.drain()
    upstream = asyncio.create_task(pipe(client_reader, server_writer))
    downstream = asyncio.create_task(pipe(server_reader, client_writer))
    await asyncio.gather(upstream, downstream, return_exceptions=True)
    with suppress(Exception):
        server_writer.close()
        await server_writer.wait_closed()
    with suppress(Exception):
        client_writer.close()
        await client_writer.wait_closed()

def choose_plain_backend(initial: bytes):
    stripped = initial.lstrip()
    lowered = stripped.lower()
    if stripped.startswith(SSH_PREFIX):
        log_ssh_detected()
        return "127.0.0.1", erwanssh_port
    if stripped.startswith(HTTP_METHODS) or lowered.startswith(HTTP_HEADER_PREFIXES):
        path = extract_http_path(stripped)
        backend_port = lookup_xray_http_backend(path)
        if backend_port is not None:
            log_detected(f"Detected Xray HTTP path on plain mux ({path})")
            return "127.0.0.1", backend_port
        if is_payload_upgrade_request(stripped):
            return "127.0.0.1", 700
        return "127.0.0.1", 700
    if is_openvpn_tcp(stripped):
        log_detected(f"Detected OpenVPN (len={len(stripped)})")
        return "127.0.0.1", openvpn_port
    if is_tls_client_hello(stripped):
        log_detected("Detected Non V2RAY TLS")
        return "127.0.0.1", openvpn_port
    return "127.0.0.1", openvpn_port

def choose_public_backend(initial: bytes):
    stripped = initial.lstrip()
    lowered = stripped.lower()
    if stripped.startswith(SSH_PREFIX):
        log_ssh_detected()
        return "127.0.0.1", erwanssh_port
    if stripped.startswith(HTTP_METHODS) or lowered.startswith(HTTP_HEADER_PREFIXES):
        if is_payload_upgrade_request(stripped):
            return "127.0.0.1", 700
        return "127.0.0.1", 700
    if is_openvpn_tcp(stripped):
        log_detected(f"Detected OpenVPN (len={len(stripped)})")
        return "127.0.0.1", openvpn_port
    if is_tls_client_hello(stripped):
        sni = extract_sni(stripped)
        alpn_protocols = extract_alpn_protocols(stripped)
        wants_https_entrypoint = any(proto in ("http/1.1", "h2") for proto in alpn_protocols)
        if sni and sni == domain_name:
            if wants_https_entrypoint:
                log_detected(f"Detected V2RAY TLS ({','.join(alpn_protocols)})")
                return "127.0.0.1", tls_backend_port
            log_detected("Detected domain TLS without HTTP ALPN, using SSL fallback")
            return "127.0.0.1", tls_ssl_port
        if not sni and client_hello_mentions_domain(stripped):
            # Domain text without a real SNI is too weak a signal on shared 443.
            # The old mux appears to have preferred OpenVPN fallback when
            # classification was uncertain, so keep this on the SSL/plain mux.
            if wants_https_entrypoint:
                log_detected(f"Detected domain-marked TLS without SNI ({','.join(alpn_protocols)}), using SSL fallback")
                return "127.0.0.1", tls_ssl_port
            log_detected("Detected domain-marked TLS without HTTP ALPN, using SSL fallback")
            return "127.0.0.1", tls_ssl_port
        if sni:
            # Custom-SNI TLS is more likely to be SSL tunnel/payload traffic
            # than the nginx/Xray HTTPS entrypoint. Hand it to the TLS
            # fallback so the inner plaintext can still be classified by the
            # plain mux as SSH, OpenVPN, or HTTP payload.
            log_detected(f"Detected Non V2RAY TLS with custom SNI ({sni})")
            return "127.0.0.1", tls_ssl_port
        log_detected("Detected Non V2RAY TLS")
        return "127.0.0.1", tls_ssl_port
    return "127.0.0.1", openvpn_port

async def read_initial(reader: asyncio.StreamReader):
    try:
        data = await asyncio.wait_for(reader.read(4096), timeout=FALLBACK_TIMEOUT)
        if len(data) >= 5 and data[0] == 0x16 and data[1] == 0x03:
            record_len = struct.unpack("!H", data[3:5])[0]
            target_len = min(5 + record_len, 16384)
            while len(data) < target_len:
                chunk = await asyncio.wait_for(reader.read(target_len - len(data)), timeout=0.5)
                if not chunk:
                    break
                data += chunk
        return data
    except asyncio.TimeoutError:
        return b""

async def handle_public(reader, writer):
    initial = await read_initial(reader)
    if not initial:
        log_detected("3s timeout, forwarding to SSH")
        await proxy_stream(reader, writer, "127.0.0.1", erwanssh_port)
        return
    host, port = choose_public_backend(initial)
    await proxy_stream(reader, writer, host, port, initial)

async def handle_plain(reader, writer):
    initial = await read_initial(reader)
    if not initial:
        log_detected("3s timeout, forwarding to SSH")
        await proxy_stream(reader, writer, "127.0.0.1", erwanssh_port)
        return
    host, port = choose_plain_backend(initial)
    await proxy_stream(reader, writer, host, port, initial)

async def main():
    public_server = await asyncio.start_server(handle_public, host="0.0.0.0", port=public_mux_port, reuse_address=True)
    plain_server = await asyncio.start_server(handle_plain, host="127.0.0.1", port=plain_mux_port, reuse_address=True)
    await asyncio.gather(public_server.serve_forever(), plain_server.serve_forever())

asyncio.run(main())
PY
}

case "${1:-serve}" in
    --install) install_mode ;;
    --serve|serve) serve_tcp ;;
    *) echo "Usage: $0 [--install|--serve]"; exit 1 ;;
esac
