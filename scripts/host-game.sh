#!/usr/bin/env bash
#
# Spins up a game and produces a public link you can paste into a chat.
#
#   scripts/host-game.sh
#
# It does three things: builds and starts the server in Docker, opens a public
# tunnel to it (cloudflared or ngrok, no account or card needed), and composes
# the final URL joining that tunnel with the client page. Ctrl-C shuts it all
# down.
#
# The server only coordinates positions and battles: neither the ROM nor the
# saves ever leave each player's browser.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8080}"
IMAGE="pokemon-mmo-server"
CONTAINER="pokemon-mmo-server-$$"
PAGE="${POKEMMO_PAGE:-}"
TUNNEL_PID=""
TUNNEL_LOG="$(mktemp -t pokemon-mmo-tunnel)"

usage() {
  cat <<'EOF'
Usage: scripts/host-game.sh [options]

  --page URL     client page the link should point at. Defaults to the one
                 inferred from the git remote (https://user.github.io/repo/).
  --port PORT    local server port (default 8080)
  --local        no tunnel: local server only, to play on the same network
  -h, --help     this help
EOF
}

LOCAL_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --page) PAGE="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --local) LOCAL_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cleanup() {
  echo
  echo "==> shutting down"
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || {
  echo "Docker is missing. Install it from https://docs.docker.com/get-docker/" >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  echo "Docker is installed but not running. Open Docker Desktop and try again." >&2
  exit 2
}

# ---------------------------------------------------------------- server
echo "==> building the server image"
docker build -q -t "$IMAGE" "$ROOT/backend" >/dev/null

echo "==> starting the server on port $PORT"
docker run -d --rm --name "$CONTAINER" \
  -p "$PORT:8080" -p 7778:7778 \
  -e PORT=8080 \
  "$IMAGE" >/dev/null

# The container can die on startup (busy port, broken image). Without this
# wait the script would announce a game that doesn't exist.
echo -n "==> waiting for it to respond"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  if ! docker ps -q --filter "name=$CONTAINER" | grep -q .; then
    echo
    echo "The server died right after starting:" >&2
    docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  echo -n "."
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || {
  echo
  echo "The server is not responding on http://127.0.0.1:$PORT/health" >&2
  exit 1
}

# ---------------------------------------------------------------- page
# With the repo on GitHub, the client page lives on Pages and its URL is
# inferred from the remote. It's an assumption, not a fact: --page overrides it.
if [ -z "$PAGE" ]; then
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ "$REMOTE" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    PAGE="https://${BASH_REMATCH[1]}.github.io/${BASH_REMATCH[2]}/"
  fi
fi

# ---------------------------------------------------------------- tunnel
if [ "$LOCAL_ONLY" = 1 ]; then
  echo
  echo "  Local server:  ws://$(ipconfig getifaddr en0 2>/dev/null || hostname):$PORT/ws"
  echo "  Paste it into the client's \"server\" field. Only works on your network."
  echo
  echo "Ctrl-C to stop."
  # `wait` with no background jobs returns immediately; this sleep is what
  # keeps the container alive until the user cuts it.
  while docker ps -q --filter "name=$CONTAINER" | grep -q .; do sleep 5; done
  exit 0
fi

PUBLIC=""
if command -v cloudflared >/dev/null 2>&1; then
  echo "==> opening a cloudflared tunnel"
  cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  for _ in $(seq 1 30); do
    PUBLIC="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
    [ -n "$PUBLIC" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 1
  done
elif command -v ngrok >/dev/null 2>&1; then
  echo "==> opening an ngrok tunnel"
  ngrok http "$PORT" --log stdout >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  # ngrok's local API is more reliable than scraping its log, which changes
  # format between versions.
  for _ in $(seq 1 30); do
    PUBLIC="$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
      | grep -Eo 'https://[a-z0-9.-]+\.ngrok[a-z.-]*\.(app|io)' | head -1 || true)"
    [ -n "$PUBLIC" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 1
  done
else
  cat >&2 <<EOF

No tunnel is installed. Either one of these is enough:

  macOS:  brew install cloudflared
  Linux:  https://github.com/cloudflare/cloudflared/releases

cloudflared needs no account or card. If you prefer ngrok, install it and this
script will use it just the same.

In the meantime you can play on your local network with:  scripts/host-game.sh --local
EOF
  exit 2
fi

if [ -z "$PUBLIC" ]; then
  echo "The tunnel could not be opened. Last lines:" >&2
  tail -20 "$TUNNEL_LOG" >&2
  exit 1
fi

WSS="wss://${PUBLIC#https://}/ws"

echo
echo "  ┌──────────────────────────────────────────────────────────────"
echo "  │  Game open"
echo "  │"
if [ -n "$PAGE" ]; then
  echo "  │  Share this link:"
  echo "  │  ${PAGE%/}/?server=$WSS"
else
  echo "  │  Server:  $WSS"
  echo "  │  Pass it to your friends with the client page:"
  echo "  │  <your-page>/?server=$WSS"
fi
echo "  │"
echo "  │  Each player needs their own ROM; nobody uploads it anywhere."
echo "  │  Ctrl-C here closes the game for everyone."
echo "  └──────────────────────────────────────────────────────────────"
echo

# If the tunnel or the container dies, the link is no longer valid: better to
# end and make it noticed than to keep announcing a dead game.
while kill -0 "$TUNNEL_PID" 2>/dev/null && docker ps -q --filter "name=$CONTAINER" | grep -q .; do
  sleep 5
done
echo "The game has closed (the tunnel or the server ended)." >&2
