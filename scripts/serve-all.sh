#!/usr/bin/env bash
#
# Clone and run. Brings up the whole MMO behind a single public tunnel and
# serves the ROM, so opening the link is enough: the page loads the ROM on its
# own and connects to the server on its own.
#
# A single tunnel (cloudflared) points at web/serve.py, which in turn:
#   - serves the client at /
#   - serves the ROM at /dev-rom.gb  (--rom)
#   - proxies /ws to the backend's WebSocket
#
# What does NOT go to the internet: neither the backend (3000/7778/7779) nor
# the ROM by any other route. Everything goes through the tunnel URL.
#
#   scripts/serve-all.sh            everything, with a public tunnel
#   scripts/serve-all.sh --local    no tunnel: LAN only
#   scripts/serve-all.sh --rebuild  force-rebuild the web client
#
# Ctrl-C shuts it all down.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROM="$ROOT/pokered/pokered.gbc"
WEB_PORT="${WEB_PORT:-8088}"
HTTP_PORT="${HTTP_PORT:-3000}"
WS_PORT="${WS_PORT:-7779}"
TCP_PORT="${TCP_PORT:-7778}"
MOD_LINK="$ROOT/gen1recomp/mods/dramatic_shape"

LOCAL_ONLY=0
REBUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL_ONLY=1 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PIDS=()
TUNNEL_LOG="$(mktemp -t pokemon-mmo-tunnel)"
cleanup() {
  echo
  echo "==> shutting down"
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------- dependencies ----
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  case "$2" in
    brew)
      echo "Missing '$1'. Installing via Homebrew..." >&2
      brew install "$1" || { echo "Could not install $1. Install it manually." >&2; exit 2; }
      ;;
    *) echo "Missing '$1' ($2)." >&2; exit 2 ;;
  esac
}

need node "https://nodejs.org"
need python3 "https://www.python.org"
need zip "install zip"
need rgbasm "macOS: brew install rgbds"
if [ "$LOCAL_ONLY" = 0 ]; then
  need cloudflared "macOS: brew install cloudflared  (or use --local)"
fi

# ------------------------------------------------------------------ ROM ------
# pokered ships its graphics pre-converted (.2bpp) in the repo, so rgbds alone
# is enough; no Python needed. The .gbc is in .gitignore (it's a copyrighted
# cart), so a fresh clone doesn't have it and it must be assembled.
if [ ! -f "$ROM" ]; then
  echo "==> assembling the local ROM from pokered (rgbds)"
  make -C "$ROOT/pokered" red
fi
[ -f "$ROM" ] || { echo "Could not build $ROM" >&2; exit 1; }

# ------------------------------------------------------------------ mod ------
if [ ! -e "$MOD_LINK" ]; then
  echo "==> linking the voxel mod"
  ln -s ../../DramaticShapeVoxelMod "$MOD_LINK"
fi

# --------------------------------------------------------------- backend -----
echo "==> installing backend deps"
(cd "$ROOT/backend" && npm install --silent)

echo "==> starting the backend (http=$HTTP_PORT ws=$WS_PORT tcp=$TCP_PORT)"
(cd "$ROOT/backend" && \
  HTTP_PORT="$HTTP_PORT" WS_PORT="$WS_PORT" TCP_PORT="$TCP_PORT" \
  npm run start:prod) &
PIDS+=($!)

echo -n "==> waiting for the backend"
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 1
done
curl -fsS "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1 || {
  echo
  echo "The backend is not responding on http://127.0.0.1:$HTTP_PORT/health" >&2
  exit 1
}

# ----------------------------------------------------------------- web -------
# The client is built WITHOUT --server: the tunnel URL changes on every run,
# and the page reads ?server=... from the link we print at the end. That way
# the client never needs rebuilding when a new tunnel is opened.
NEED_BUILD=0
if [ "$REBUILD" = 1 ] || [ ! -d "$ROOT/web/dist" ]; then
  NEED_BUILD=1
elif ! grep -q '"withMods": true' "$ROOT/web/dist/build-info.json" 2>/dev/null; then
  NEED_BUILD=1
fi
if [ "$NEED_BUILD" = 1 ]; then
  echo "==> building the web client (with the voxel mod)"
  "$ROOT/web/build-web.sh" --with-mods
else
  echo "==> web client already built (use --rebuild to force)"
fi

echo "==> starting the web server on port $WEB_PORT (serves the ROM)"
python3 "$ROOT/web/serve.py" \
  --host 0.0.0.0 --port "$WEB_PORT" \
  --ws-port "$WS_PORT" \
  --rom "$ROM" &
PIDS+=($!)

# ----------------------------------------------------------------- tunnel ----
if [ "$LOCAL_ONLY" = 1 ]; then
  LAN="$(ipconfig getifaddr en0 2>/dev/null || hostname)"
  PAGE="http://$LAN:$WEB_PORT/"
  WSS="ws://$LAN:$WEB_PORT/ws"
else
  echo "==> opening a cloudflared tunnel"
  cloudflared tunnel --url "http://127.0.0.1:$WEB_PORT" --no-autoupdate \
    >"$TUNNEL_LOG" 2>&1 &
  PIDS+=($!)
  PUBLIC=""
  for _ in $(seq 1 40); do
    PUBLIC="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
    [ -n "$PUBLIC" ] && break
    sleep 1
  done
  if [ -z "$PUBLIC" ]; then
    echo "The tunnel did not open. Last lines:" >&2
    tail -20 "$TUNNEL_LOG" >&2
    exit 1
  fi
  PAGE="${PUBLIC}/"
  WSS="wss://${PUBLIC#https://}/ws"
fi

echo
echo "  ┌──────────────────────────────────────────────────────────────────"
echo "  │  Game ready"
echo "  │"
echo "  │  Share this link (page + ROM + server, all in one):"
echo "  │  ${PAGE}?server=${WSS}"
echo "  │"
echo "  │  The ROM is served at ${PAGE}dev-rom.gb  (downloadable by anyone"
echo "  │  who reaches the tunnel: don't leave it open unattended)."
echo "  │  Ctrl-C closes the game for everyone."
echo "  └──────────────────────────────────────────────────────────────────"
echo

# Keep alive until something dies.
while true; do
  for pid in "${PIDS[@]:-}"; do
    kill -0 "$pid" 2>/dev/null || { echo "A process has exited." >&2; exit 1; }
  done
  sleep 3
done
