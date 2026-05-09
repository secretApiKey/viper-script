#!/bin/bash

set -euo pipefail

DOMAIN_FILE="${DOMAIN_FILE:-/etc/ErwanScript/domain}"
TLS_LISTEN_HOST="${TLS_LISTEN_HOST:-127.0.0.1}"
TLS_LISTEN_PORT="${TLS_LISTEN_PORT:-4454}"
PLAIN_MUX_PORT="${PLAIN_MUX_PORT:-4443}"
LOG_FILE="${LOG_FILE:-/var/log/erwantls.log}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

python3 - "$DOMAIN_FILE" "$TLS_LISTEN_HOST" "$TLS_LISTEN_PORT" "$PLAIN_MUX_PORT" "$LOG_FILE" <<'PY'
import asyncio
import ssl
import sys
from contextlib import suppress

domain_file, listen_host, listen_port, plain_mux_port, log_file = sys.argv[1:]
listen_port = int(listen_port)
plain_mux_port = int(plain_mux_port)

with open(domain_file, "r", encoding="utf-8") as fh:
    domain = fh.read().strip()

cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
key = f"/etc/letsencrypt/live/{domain}/privkey.pem"

ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ssl_ctx.load_cert_chain(certfile=cert, keyfile=key)

def log(message: str) -> None:
    with open(log_file, "a", encoding="utf-8") as fh:
        fh.write(message + "\n")

async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
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

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", plain_mux_port)
    except Exception as exc:
        log(f"connect plain mux failed from {peer}: {exc}")
        writer.close()
        with suppress(Exception):
            await writer.wait_closed()
        return

    upstream = asyncio.create_task(pipe(reader, upstream_writer))
    downstream = asyncio.create_task(pipe(upstream_reader, writer))
    await asyncio.gather(upstream, downstream, return_exceptions=True)
    with suppress(Exception):
        upstream_writer.close()
        await upstream_writer.wait_closed()
    with suppress(Exception):
        writer.close()
        await writer.wait_closed()

async def main() -> None:
    server = await asyncio.start_server(handle_client, listen_host, listen_port, ssl=ssl_ctx, reuse_address=True)
    addrs = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    log(f"ErwanTLS listening on {addrs} -> 127.0.0.1:{plain_mux_port}")
    async with server:
        await server.serve_forever()

asyncio.run(main())
PY
