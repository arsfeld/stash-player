#!/usr/bin/env python3
"""Loopback HTTP front end for a Stash server reachable only over SOCKS5.

Tailscale in userspace mode (`--tun=userspace-networking`) exposes the
tailnet through a SOCKS5 port and nothing else: there is no interface, so
a tailnet hostname does not resolve and its 100.x address does not route.
The released clients handle this themselves — `stash-player-proxy` fronts
media bytes and `reqwest` speaks `socks5h://` for the API — but the
Flutter client has no proxy support at any layer. `package:http` offers no
SOCKS, and its video path is libmpv, which does its own networking in C
and understands only `--http-proxy`.

So this hands the client a plain `http://127.0.0.1:<port>` origin and does
the SOCKS5 hop here, for API calls and media alike.

One wrinkle makes a plain tunnel insufficient. A Stash server configured
with an external URL returns absolute media URLs regardless of the Host
header it was asked under:

    "stream": "https://stash.example.ts.net/scene/1/stream?apikey=..."

A client following those goes straight back to the unroutable host. So
textual responses (JSON, HTML, JS) get that origin rewritten to this
bridge's own. Everything else streams through byte-for-byte, which keeps
`Range` requests answering `206` so seeking still works.

Usage:

    SOCKS_BRIDGE_UPSTREAM=https://stash.example.ts.net \
        python3 tools/socks-bridge/server.py

    # in another terminal
    cd apps/flutter
    STASH_URL=http://127.0.0.1:18999 STASH_API_KEY=<key> flutter run -d macos

This is a development aid for reaching a real server from a client that
cannot proxy. It is not part of any shipped app, and it is not a substitute
for the proxy support the released clients already have.

Overrides:
  SOCKS_BRIDGE_UPSTREAM  required; scheme + host (+ optional port) of the
                         real Stash server, e.g. https://stash.example.ts.net
  SOCKS_BRIDGE_PORT      port to listen on (default 18999; deliberately not
                         mock-stash's 9999 or the 19999 its README suggests,
                         so both can run at once)
  SOCKS_BRIDGE_HOST      address to listen on (default 127.0.0.1)
  SOCKS_BRIDGE_SOCKS     SOCKS5 proxy as host:port (default 127.0.0.1:1055,
                         Tailscale's default userspace SOCKS port)
  SOCKS_BRIDGE_VERBOSE   set to 1 to log one line per request; API keys are
                         redacted, but paths still name scene ids
"""

import http.client
import os
import re
import socket
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

UPSTREAM = os.environ.get("SOCKS_BRIDGE_UPSTREAM", "").rstrip("/")
LISTEN_HOST = os.environ.get("SOCKS_BRIDGE_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SOCKS_BRIDGE_PORT", "18999"))
VERBOSE = os.environ.get("SOCKS_BRIDGE_VERBOSE") == "1"

_socks = os.environ.get("SOCKS_BRIDGE_SOCKS", "127.0.0.1:1055")
SOCKS_HOST, _, _socks_port = _socks.partition(":")
SOCKS_PORT = int(_socks_port or "1080")

# Only textual payloads are rewritten; video and images pass through.
REWRITABLE = ("json", "text/html", "text/plain", "javascript")
CONNECT_TIMEOUT = 30
READ_TIMEOUT = 60

_APIKEY = re.compile(r"([?&]apikey=)[^&#\s]*", re.IGNORECASE)


def redact(text):
    """Strip API keys from anything headed for the log."""
    return _APIKEY.sub(r"\1***", text)


def socks5_connect(host, port):
    """Open a TCP connection to host:port through the SOCKS5 proxy.

    Hand-rolled because the standard library has no SOCKS client and this
    tool is deliberately dependency-free, like tools/mock-stash.
    """
    sock = socket.create_connection((SOCKS_HOST, SOCKS_PORT), timeout=CONNECT_TIMEOUT)
    try:
        sock.sendall(b"\x05\x01\x00")  # version 5, one method, no auth
        if sock.recv(2) != b"\x05\x00":
            raise OSError("SOCKS5 proxy rejected the no-auth handshake")

        name = host.encode("idna")
        sock.sendall(
            b"\x05\x01\x00\x03" + bytes([len(name)]) + name + port.to_bytes(2, "big")
        )
        reply = sock.recv(4)
        if len(reply) < 4:
            raise OSError("SOCKS5 proxy closed during CONNECT")
        if reply[1] != 0x00:
            raise OSError(f"SOCKS5 CONNECT failed with status {reply[1]:#04x}")

        # Drain the bound address so the stream starts at the payload.
        atyp = reply[3]
        if atyp == 0x01:
            sock.recv(4)
        elif atyp == 0x03:
            sock.recv(sock.recv(1)[0])
        elif atyp == 0x04:
            sock.recv(16)
        else:
            raise OSError(f"SOCKS5 proxy returned unknown address type {atyp}")
        sock.recv(2)  # bound port

        sock.settimeout(READ_TIMEOUT)
        return sock
    except Exception:
        sock.close()
        raise


class SocksHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socks5_connect(self.host, self.port)


class SocksHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        raw = socks5_connect(self.host, self.port)
        try:
            context = ssl.create_default_context()
            self.sock = context.wrap_socket(raw, server_hostname=self.host)
        except Exception:
            raw.close()
            raise


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stash-socks-bridge"

    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write(f"{self.address_string()} {redact(fmt % args)}\n")

    # Hop-by-hop headers, plus the encoding ones we take over ourselves.
    _DROP_REQUEST = frozenset({"host", "connection", "accept-encoding"})
    _DROP_RESPONSE = frozenset({"connection", "transfer-encoding", "content-encoding"})

    def _open_upstream(self, method):
        body = None
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))

        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in self._DROP_REQUEST
        }
        headers["Host"] = upstream_host_header
        # Identity encoding keeps the rewrite below working on plain bytes.
        headers["Accept-Encoding"] = "identity"

        connection = connection_class(
            upstream_host, upstream_port, timeout=READ_TIMEOUT
        )
        connection.request(method, self.path, body=body, headers=headers)
        return connection, connection.getresponse()

    def _send_headers(self, response, drop_extra=()):
        skip = self._DROP_RESPONSE | frozenset(drop_extra)
        for key, value in response.getheaders():
            if key.lower() in skip:
                continue
            self.send_header(key, value)

    def _relay(self, method):
        try:
            connection, response = self._open_upstream(method)
        except Exception as error:
            self.send_error(502, "bridge could not reach upstream", str(error))
            return

        try:
            content_type = response.getheader("Content-Type", "")
            if any(token in content_type for token in REWRITABLE):
                self._relay_rewritten(method, response)
            else:
                self._relay_stream(method, response)
        finally:
            connection.close()

    def _relay_rewritten(self, method, response):
        """Buffer a textual body so upstream's origin can be swapped out."""
        payload = response.read().replace(upstream_origin, local_origin)
        self.send_response(response.status)
        self._send_headers(response, drop_extra=("content-length",))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(payload)

    def _relay_stream(self, method, response):
        """Pass media through untouched so Range/206 keeps working."""
        # Without a Content-Length there is no framing for keep-alive, so
        # fall back to closing the connection to delimit the body.
        streaming = response.getheader("Content-Length") is None
        self.send_response(response.status)
        self._send_headers(response)
        if streaming:
            self.close_connection = True
            self.send_header("Connection", "close")
        self.end_headers()

        if method == "HEAD":
            return
        try:
            while chunk := response.read(65536):
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            # A client seeking or closing the player mid-stream is routine.
            self.close_connection = True

    def do_GET(self):
        self._relay("GET")

    def do_HEAD(self):
        self._relay("HEAD")

    def do_POST(self):
        self._relay("POST")


def main():
    global upstream_origin, upstream_host, upstream_port, upstream_host_header
    global connection_class, local_origin

    if not UPSTREAM:
        sys.exit(
            "SOCKS_BRIDGE_UPSTREAM is required, e.g.\n"
            "  SOCKS_BRIDGE_UPSTREAM=https://stash.example.ts.net "
            f"python3 {sys.argv[0]}"
        )

    parts = urlsplit(UPSTREAM)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        sys.exit(f"SOCKS_BRIDGE_UPSTREAM must be http(s)://host[:port], got {UPSTREAM!r}")

    secure = parts.scheme == "https"
    upstream_host = parts.hostname
    upstream_port = parts.port or (443 if secure else 80)
    # Preserve any explicit port so the server sees the origin it expects.
    upstream_host_header = parts.netloc
    upstream_origin = UPSTREAM.encode()
    connection_class = SocksHTTPSConnection if secure else SocksHTTPConnection

    local_origin = f"http://{LISTEN_HOST}:{LISTEN_PORT}".encode()

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True
    print(
        f"bridging {local_origin.decode()} -> {UPSTREAM} "
        f"via socks5://{SOCKS_HOST}:{SOCKS_PORT}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
