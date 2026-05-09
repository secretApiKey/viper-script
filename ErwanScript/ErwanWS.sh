#!/bin/bash

set -euo pipefail

ISSUE_NET="${ISSUE_NET:-/etc/issue.net}"
UNIT_FILE="${UNIT_FILE:-/lib/systemd/system/ErwanWS.service}"
BRAND_TOP="${BRAND_TOP:-ErwanScript}"
BRAND_BOTTOM="${BRAND_BOTTOM:-ErwanScript}"
PORTS="${JUANWS_PORTS:-700 8880 8888 8010 2052 2082 2086 2095}"
SSH_BACKEND_HOST="${SSH_BACKEND_HOST:-127.0.0.1}"
SSH_BACKEND_PORT="${SSH_BACKEND_PORT:-22}"
OPENVPN_BACKEND_HOST="${OPENVPN_BACKEND_HOST:-127.0.0.1}"
OPENVPN_BACKEND_PORT="${OPENVPN_BACKEND_PORT:-1194}"
TLS_BACKEND_HOST="${TLS_BACKEND_HOST:-127.0.0.1}"
TLS_BACKEND_PORT="${TLS_BACKEND_PORT:-777}"
PAYLOAD_BACKEND_HOST="${PAYLOAD_BACKEND_HOST:-127.0.0.1}"
PAYLOAD_BACKEND_PORT="${PAYLOAD_BACKEND_PORT:-4443}"
DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
WS_RESPONSE_FILE="${WS_RESPONSE_FILE:-/etc/ErwanScript/ws-response.txt}"
CUSTOM_HTTP_METHODS="${CUSTOM_HTTP_METHODS:-}"
CUSTOM_HTTP_METHODS_FILE="${CUSTOM_HTTP_METHODS_FILE:-/etc/ErwanScript/custom-http-methods.txt}"
DEFAULT_WS_RESPONSE="<b><font color='red'>VIPER</font> <font color='green'>Panel</font></b>"

load_ws_response() {
    if [ -f "$WS_RESPONSE_FILE" ] && [ -s "$WS_RESPONSE_FILE" ]; then
        cat "$WS_RESPONSE_FILE"
    else
        printf '%s' "$DEFAULT_WS_RESPONSE"
    fi
}

write_banner() {
    cat > "$ISSUE_NET" <<EOF
<h6 style="text-align:center">
<br>
********************************<br>
<br>
${BRAND_TOP} <br>
${BRAND_BOTTOM}<br>
<br>
********************************<br>
</h6>
<br>
EOF
}

write_unit() {
    cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=ErwanWS
After=network.target

[Service]
User=root
ExecStart=/etc/ErwanScript/ErwanWS
Restart=always
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

serve_all() {
    write_banner
    local ws_response_html
    ws_response_html="$(load_ws_response)"
    python3 - "$PORTS" "$BRAND_TOP" "$BRAND_BOTTOM" "$SSH_BACKEND_HOST" "$SSH_BACKEND_PORT" "$OPENVPN_BACKEND_HOST" "$OPENVPN_BACKEND_PORT" "$TLS_BACKEND_HOST" "$TLS_BACKEND_PORT" "$PAYLOAD_BACKEND_HOST" "$PAYLOAD_BACKEND_PORT" "$DOMAIN_FILE" "$ws_response_html" "$CUSTOM_HTTP_METHODS" "$CUSTOM_HTTP_METHODS_FILE" <<'PY'
import asyncio
import html
import socket
import sys
from contextlib import suppress

ports = [int(p) for p in sys.argv[1].split()]
brand_top = html.escape(sys.argv[2])
brand_bottom = html.escape(sys.argv[3])
ssh_host = sys.argv[4]
ssh_port = int(sys.argv[5])
ovpn_host = sys.argv[6]
ovpn_port = int(sys.argv[7])
tls_host = sys.argv[8]
tls_port = int(sys.argv[9])
payload_host = sys.argv[10]
payload_port = int(sys.argv[11])
domain_file = sys.argv[12]
ws_response_html = sys.argv[13]
custom_http_methods = sys.argv[14]
custom_http_methods_file = sys.argv[15]
if ws_response_html:
    ws_status_line = f"HTTP/1.1 101 {ws_response_html}\r\n".encode("utf-8")
else:
    ws_status_line = b"HTTP/1.1 101\r\n"

try:
    with open(domain_file, "r", encoding="utf-8") as fh:
        domain_name = fh.read().strip().lower()
except OSError:
    domain_name = ""

play_store_url = "https://play.google.com/store/apps/details?id=com.viper.panel&pcampaignid=web_share"
body = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{brand_top}</title>
<style>
    * {{
        box-sizing: border-box;
    }}
    body {{
        margin: 0;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
        font-family: Arial, sans-serif;
        background: linear-gradient(135deg, #0f2d14 0%, #16381b 45%, #1e4f24 100%);
        color: #ecfff0;
    }}
    .card {{
        width: min(100%, 460px);
        background: rgba(9, 20, 11, 0.78);
        border: 1px solid rgba(148, 255, 173, 0.18);
        border-radius: 20px;
        padding: 32px 28px;
        text-align: center;
        box-shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
    }}
    .eyebrow {{
        margin: 0 0 10px;
        font-size: 12px;
        letter-spacing: 0.28em;
        text-transform: uppercase;
        color: #8fe19d;
    }}
    h1 {{
        margin: 0;
        font-size: 32px;
        line-height: 1.1;
        color: #ffffff;
    }}
    p {{
        margin: 14px 0 0;
        font-size: 15px;
        line-height: 1.6;
        color: #d5f7db;
    }}
    .actions {{
        margin-top: 26px;
        display: flex;
        justify-content: center;
    }}
    .button {{
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 14px 22px;
        border-radius: 999px;
        text-decoration: none;
        font-weight: 700;
        font-size: 15px;
        color: #103517;
        background: linear-gradient(90deg, #8cf59e 0%, #55da6f 100%);
        box-shadow: 0 14px 30px rgba(85, 218, 111, 0.28);
    }}
    .meta {{
        margin-top: 18px;
        font-size: 13px;
        color: #9ed7a8;
    }}
</style>
</head>
<body>
<div class="card">
    <div class="eyebrow">Erwan Viper Panel</div>
    <h1>VIPER PANEL</h1>
    <p>Download the Android app to create a solo accounts.</p>
    <div class="actions">
        <a class="button" href="{play_store_url}" target="_blank" rel="noopener noreferrer">Download on Google Play</a>
    </div>
    <div class="meta">{domain_name or "Server landing page"}</div>
</div>
</body>
</html>
"""

allowed_hosts = {
    "",
    "127.0.0.1",
    "localhost",
    "0.0.0.0",
    "::1",
    domain_name,
    socket.gethostname().lower(),
    socket.getfqdn().lower(),
}

def parse_custom_methods(raw: str) -> set[str]:
    methods = set()
    for method in raw.replace(",", " ").split():
        token = method.strip().upper()
        if token and token.isascii():
            methods.add(token)
    return methods

def log_event(message: str) -> None:
    print(message, flush=True)

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

BASE_METHODS = ("GET", "POST", "HEAD", "PUT", "PATCH", "OPTIONS", "DELETE", "TRACE", "PRI", "CONNECT", "GET-RAY", "RAY", "VERSION-CONTROL")
CUSTOM_METHODS = parse_custom_methods(custom_http_methods) | load_custom_methods_file(custom_http_methods_file)
PAYLOAD_METHODS = {"GET-RAY", "RAY", "VERSION-CONTROL"} | CUSTOM_METHODS
METHODS = tuple(f"{method} ".encode("ascii") for method in tuple(BASE_METHODS) + tuple(sorted(CUSTOM_METHODS)))

def parse_target(value: str):
    raw = value.strip()
    if not raw:
        return None
    if "://" in raw:
        raw = raw.split("://", 1)[1]
    raw = raw.split("/", 1)[0].strip()
    if not raw:
        return None
    if raw.startswith("[") and "]" in raw:
        host, _, rest = raw[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    elif raw.count(":") >= 2 and not raw.startswith("127.0.0.1:"):
        host = raw
        port = ""
    else:
        if ":" in raw:
            host, port = raw.rsplit(":", 1)
        else:
            host, port = raw, ""
    host = host.strip().lower()
    port = port.strip()
    if port and not port.isdigit():
        port = ""
    return host, int(port) if port else None

def has_placeholder(value: str) -> bool:
    lowered = value.strip().lower()
    return any(token in lowered for token in ("[host]", "[port]", "[ua]", "[crlf]", "[split]"))

def choose_backend(method: str, target_hint: str, headers: dict[str, str]):
    x_host = headers.get("x-host", "")
    x_port = headers.get("x-port", "")
    if x_host and x_port.isdigit() and ":" not in x_host:
        x_host = f"{x_host}:{x_port}"

    candidates = [
        headers.get("x-real-host", ""),
        headers.get("x-online-host", ""),
        headers.get("x-forward-host", ""),
        headers.get("x-host", ""),
        x_host,
        headers.get("real-host", ""),
        headers.get("host", ""),
        target_hint,
    ]
    wants_ovpn = False
    wants_tls = False
    parsed = None
    for candidate in candidates:
        if not candidate:
            continue
        if has_placeholder(candidate):
            continue
        lowered = candidate.lower()
        if any(token in lowered for token in ("openvpn", "ovpn", "1194")):
            wants_ovpn = True
        if any(token in lowered for token in ("vless", "vmess", "trojan", "ss-ws", "websocket", "wss")):
            wants_tls = True
        parsed = parse_target(candidate)
        if parsed:
            host, port = parsed
            if port == ovpn_port:
                return ovpn_host, ovpn_port
            if port == tls_port:
                return tls_host, tls_port
            if port == ssh_port:
                return ssh_host, ssh_port
            if host in allowed_hosts and port == 443:
                return payload_host, payload_port
            if port == 443:
                wants_tls = True
            if host in allowed_hosts and port in (None, 80):
                continue
            if host in allowed_hosts and port:
                return host, port
            if host in ("openvpn", "ovpn"):
                return ovpn_host, ovpn_port
            if host in ("ssh", "direct", "proxy"):
                return ssh_host, ssh_port
    forced_protocol = headers.get("x-target-protocol", "").lower()
    if forced_protocol == "ssh":
        return ssh_host, ssh_port
    if wants_ovpn or forced_protocol == "openvpn":
        return ovpn_host, ovpn_port
    if wants_tls or forced_protocol == "tls":
        return tls_host, tls_port
    lowered_target = (target_hint or "").lower()
    host_header = headers.get("host", "").lower()
    if lowered_target.startswith("/cdn-cgi/trace") or lowered_target == "/":
        if "upgrade" in headers.get("connection", "").lower() or headers.get("upgrade", "").lower() == "websocket":
            return payload_host, payload_port
        if "cloudflare" in host_header or "/cdn-cgi/trace" in lowered_target:
            return payload_host, payload_port
    if method in PAYLOAD_METHODS:
        return payload_host, payload_port
    if method == "CONNECT" and parsed and parsed[1] == 443:
        return tls_host, tls_port
    # Generic websocket/payload requests without an explicit target should
    # enter the plain mux so the next bytes after the 101 upgrade can still
    # be classified as SSH or OpenVPN.
    return payload_host, payload_port

async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except Exception:
        pass
    finally:
        with suppress(Exception):
            if writer.can_write_eof():
                writer.write_eof()
                await writer.drain()

async def respond_banner(writer: asyncio.StreamWriter):
    payload = body.encode("utf-8")
    writer.write(
        b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n"
        + f"Content-Length: {len(payload)}\r\n".encode("ascii")
        + b"Connection: close\r\n\r\n"
        + payload
    )
    await writer.drain()
    writer.close()
    with suppress(Exception):
        await writer.wait_closed()

async def tunnel(client_reader, client_writer, backend_host, backend_port, mode, initial_data=b""):
    try:
        server_reader, server_writer = await asyncio.open_connection(backend_host, backend_port)
    except Exception:
        client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        with suppress(Exception):
            await client_writer.wait_closed()
        return

    if mode == "connect":
        client_writer.write(
            b"HTTP/1.1 200 Connection established\r\n"
            b"Server: ErwanScript\r\n\r\n"
        )
    else:
        client_writer.write(
            (
                ws_status_line
                + b"Server: ErwanScript\r\n"
                + b"X-WS-Message: "
                + ws_response_html.encode("utf-8")
                + b"\r\n"
                + b"Connection: Upgrade\r\n"
                + b"Upgrade: websocket\r\n\r\n"
            )
        )
    await client_writer.drain()
    if backend_port == ovpn_port and initial_data:
        initial_data = initial_data.lstrip(b"\r\n")

    if initial_data:
        server_writer.write(initial_data)
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

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        initial = await reader.read(8192)
        if not initial:
            writer.close()
            return
        if not initial.startswith(METHODS):
            log_event("SSH-2.0-OpenSSH-ErwanScript")
            await tunnel(reader, writer, ssh_host, ssh_port, "raw", initial)
            return
        while b"\r\n\r\n" not in initial and len(initial) < 65536:
            chunk = await reader.read(8192)
            if not chunk:
                break
            initial += chunk
        head, _, rest = initial.partition(b"\r\n\r\n")
        lines = head.decode("iso-8859-1", "replace").split("\r\n")
        if not lines:
            await respond_banner(writer)
            return
        request_line = lines[0]
        parts = request_line.split()
        if len(parts) < 2:
            await respond_banner(writer)
            return
        method = parts[0].upper()
        target = parts[1]
        headers = {}
        for line in lines[1:]:
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
        path_hint = ""
        if target.startswith("http://") or target.startswith("https://"):
            with suppress(Exception):
                target = target.split("://", 1)[1]
        if "/" in target:
            authority, path_hint = target.split("/", 1)
            target = authority
            path_hint = "/" + path_hint

        if path_hint:
            lowered_path = path_hint.lower()
            if lowered_path in ("/ssh", "/ws-ssh") or lowered_path.startswith("/ssh/"):
                headers.setdefault("x-target-protocol", "ssh")
            if any(token in lowered_path for token in ("vless", "vmess", "trojan", "ss-ws")):
                headers.setdefault("x-target-protocol", "tls")
            if "openvpn" in lowered_path or "ovpn" in lowered_path:
                headers.setdefault("x-target-protocol", "openvpn")

        host_header = headers.get("host", "").strip().lower()
        if path_hint in ("", "/") and host_header and host_header not in allowed_hosts and not has_placeholder(host_header):
            headers.setdefault("x-target-protocol", "ssh")

        connection_header = headers.get("connection", "").lower()
        upgrade_header = headers.get("upgrade", "").lower()
        has_payload_header = any(
            k in headers
            for k in (
                "x-real-host",
                "x-online-host",
                "x-forward-host",
                "x-host",
                "x-port",
                "real-host",
                "x-target-protocol",
                "x-pass",
            )
        )
        if "upgrade" in connection_header or upgrade_header == "websocket":
            has_payload_header = True
        if method == "CONNECT":
            backend_host, backend_port = choose_backend(method, target, headers)
            await tunnel(reader, writer, backend_host, backend_port, "connect", rest)
            return
        if method in PAYLOAD_METHODS:
            backend_host, backend_port = choose_backend(method, target, headers)
            await tunnel(reader, writer, backend_host, backend_port, "payload", rest)
            return
        if has_payload_header:
            backend_host, backend_port = choose_backend(method, target, headers)
            await tunnel(reader, writer, backend_host, backend_port, "payload", rest)
            return
        await respond_banner(writer)
    except Exception:
        with suppress(Exception):
            writer.close()
            await writer.wait_closed()

async def main():
    servers = []
    for port in ports:
        server = await asyncio.start_server(handle_client, host="0.0.0.0", port=port, reuse_address=True)
        servers.append(server)
    await asyncio.gather(*(server.serve_forever() for server in servers))

asyncio.run(main())
PY
}

install_mode() {
    write_banner
    write_unit
    systemctl daemon-reload
    systemctl enable ErwanWS >/dev/null 2>&1 || true
    echo "ErwanWS unit installed with ports: $PORTS"
}

case "${1:-serve}" in
    --install) install_mode ;;
    --serve|serve) serve_all ;;
    *) echo "Usage: $0 [--install|--serve]"; exit 1 ;;
esac
