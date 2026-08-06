#!/usr/bin/env python3
"""Static dev server for the browser build, with a WebSocket passthrough.

Three things a stock `python3 -m http.server` gets wrong for this build:

  * .wasm must be served as application/wasm, otherwise the browser refuses
    the streaming compile and love.js falls back or fails outright.
  * a --threads build needs cross-origin isolation (COOP/COEP) before the
    browser will hand out SharedArrayBuffer.
  * the page and the game's WebSocket have to share an origin as soon as the
    page is not on plain http://localhost. A page served over https cannot
    open a ws:// connection -- browsers block it as mixed content -- so a
    tunnel (ngrok), a phone on the LAN, or any real deployment needs the
    WebSocket reachable at wss://<same-host>/ws. This server forwards
    /ws upgrades to the game's WebSocket port to make that true in dev.

In production the same job belongs to whatever reverse proxy terminates TLS;
the only requirements are the wasm MIME type and a /ws route to the backend.
"""

import argparse
import functools
import http.server
import json
import os
import select
import socket
import socketserver

DIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dist")


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".data": "application/octet-stream",
    }

    # Bytes of a ROM to hand to the page automatically, or None. Deliberately
    # held in memory and served from a path that exists nowhere in web/dist:
    # a cart must never end up inside the build output, where it would be one
    # `git add` or one deploy away from being published.
    dev_rom = None
    dev_rom_name = None

    def __init__(self, *args, isolate=False, ws_port=7779, **kwargs):
        self.isolate = isolate
        self.ws_port = ws_port
        super().__init__(*args, **kwargs)

    def _serve_dev_rom(self) -> None:
        rom = type(self).dev_rom
        if not rom:
            self.send_error(404, "no ROM was passed to --rom")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(rom)))
        self.send_header("X-Rom-Name", type(self).dev_rom_name or "rom.gb")
        self.end_headers()
        self.wfile.write(rom)

    # ---- WebSocket passthrough -------------------------------------------
    #
    # A WebSocket handshake is an ordinary HTTP request followed by a byte
    # stream neither side interprets as HTTP any more. So the proxy replays
    # the handshake to the backend and then pumps raw bytes both ways --
    # no frame parsing, which means no chance of corrupting framing.

    def _is_websocket_upgrade(self) -> bool:
        return (self.headers.get("Upgrade", "").lower() == "websocket"
                and self.path.rstrip("/") in ("/ws", "/websocket"))

    def _proxy_websocket(self) -> None:
        try:
            upstream = socket.create_connection(("127.0.0.1", self.ws_port), timeout=5)
        except OSError as error:
            self.send_error(502, f"game WebSocket unreachable: {error}")
            return

        # The backend listens with a bare WebSocketServer, which accepts any
        # path, so the request line is normalised to "/" and only the
        # handshake headers are carried over.
        request = ["GET / HTTP/1.1"]
        for key, value in self.headers.items():
            if key.lower() in ("host", "connection", "proxy-connection"):
                continue
            request.append(f"{key}: {value}")
        request.append(f"Host: 127.0.0.1:{self.ws_port}")
        request.append("Connection: Upgrade")
        upstream.sendall(("\r\n".join(request) + "\r\n\r\n").encode("latin-1"))

        client = self.connection
        client.setblocking(False)
        upstream.setblocking(False)
        try:
            while True:
                readable, _, errored = select.select([client, upstream], [], [client, upstream], 60)
                if errored:
                    break
                if not readable:
                    continue  # idle; the game sends position updates rarely
                for source in readable:
                    target = upstream if source is client else client
                    try:
                        chunk = source.recv(65536)
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        return
                    if not chunk:
                        return
                    try:
                        target.sendall(chunk)
                    except OSError:
                        return
        finally:
            for sock in (upstream, client):
                try:
                    sock.close()
                except OSError:
                    pass
            self.close_connection = True

    def do_GET(self):
        if self._is_websocket_upgrade():
            return self._proxy_websocket()
        if self.path.split("?")[0] == "/dev-rom.gb":
            return self._serve_dev_rom()
        return super().do_GET()

    def do_HEAD(self):
        # The page probes for a served ROM before deciding whether to show its
        # file picker, and a HEAD keeps that probe from pulling a megabyte.
        if self.path.split("?")[0] == "/dev-rom.gb":
            rom = type(self).dev_rom
            if not rom:
                self.send_error(404, "no ROM was passed to --rom")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(rom)))
            self.send_header("X-Rom-Name", type(self).dev_rom_name or "rom.gb")
            self.end_headers()
            return
        return super().do_HEAD()

    # ---- static ----------------------------------------------------------

    def end_headers(self):
        if self.isolate:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # The wasm and .data files are rebuilt in place, and the launcher page
        # changes most often of all: never let a stale copy survive a rebuild.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        rendered = fmt % args
        if " 200 " not in rendered:
            super().log_message(fmt, *args)


class Server(socketserver.ThreadingTCPServer):
    # Threading is required, not a nicety: a proxied WebSocket occupies its
    # handler thread for the whole session, and a single-threaded server
    # would stop serving the page the moment one player connected.
    allow_reuse_address = True
    daemon_threads = True


def threaded_build() -> bool:
    try:
        with open(os.path.join(DIST, "build-info.json"), encoding="utf-8") as handle:
            return bool(json.load(handle).get("threads"))
    except (OSError, ValueError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="127.0.0.1",
                        help="use 0.0.0.0 to reach it from another device on the LAN")
    parser.add_argument("--ws-port", type=int, default=int(os.environ.get("WS_PORT", 7779)),
                        help="the game WebSocket port that /ws forwards to")
    parser.add_argument("--isolate", action="store_true",
                        help="force COOP/COEP headers (auto-detected for --threads builds)")
    parser.add_argument("--rom", metavar="PATH",
                        help="hand this ROM to the page automatically instead of asking the "
                             "player for one. Convenience for testing on a device the cart is "
                             "not on; ANYONE who can reach this server can download it.")
    args = parser.parse_args()

    if not os.path.isdir(DIST):
        print("No build found. Run web/build-web.sh first.")
        return 2

    if args.rom:
        try:
            with open(args.rom, "rb") as handle:
                Handler.dev_rom = handle.read()
        except OSError as error:
            print(f"Could not read --rom {args.rom}: {error}")
            return 2
        Handler.dev_rom_name = os.path.basename(args.rom)

    isolate = args.isolate or threaded_build()
    handler = functools.partial(Handler, directory=DIST, isolate=isolate, ws_port=args.ws_port)

    with Server((args.host, args.port), handler) as httpd:
        print(f"Serving {DIST} on http://{args.host}:{args.port}"
              + ("  (cross-origin isolated)" if isolate else ""))
        print(f"  /ws  ->  127.0.0.1:{args.ws_port}")
        if Handler.dev_rom:
            size = len(Handler.dev_rom)
            print(f"  /dev-rom.gb  ->  {Handler.dev_rom_name} ({size} bytes)")
            print("  WARNING: that ROM is downloadable by anyone who can reach this "
                  "server.\n           Do not leave it on a public tunnel you are "
                  "not watching.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
