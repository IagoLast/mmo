#!/usr/bin/env bash
#
# Levanta una partida y saca un enlace público que puedes pegar en un chat.
#
#   scripts/host-game.sh
#
# Hace tres cosas: construye y arranca el servidor en Docker, abre un túnel
# público hacia él (cloudflared o ngrok, sin cuenta ni tarjeta), y compone la
# URL final juntando ese túnel con la página del cliente. Ctrl-C lo cierra
# todo.
#
# El servidor solo coordina posiciones y combates: ni la ROM ni las partidas
# salen del navegador de cada jugador.

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
Uso: scripts/host-game.sh [opciones]

  --page URL     página del cliente a la que apuntar el enlace. Por defecto se
                 deduce del remote de git (https://usuario.github.io/repo/).
  --port PUERTO  puerto local del servidor (por defecto 8080)
  --local        sin túnel: solo servidor local, para jugar en la misma red
  -h, --help     esta ayuda
EOF
}

LOCAL_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --page) PAGE="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --local) LOCAL_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "opción desconocida: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cleanup() {
  echo
  echo "==> cerrando"
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || {
  echo "Falta Docker. Instálalo desde https://docs.docker.com/get-docker/" >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  echo "Docker está instalado pero no arrancado. Abre Docker Desktop y repite." >&2
  exit 2
}

# ---------------------------------------------------------------- servidor
echo "==> construyendo la imagen del servidor"
docker build -q -t "$IMAGE" "$ROOT/backend" >/dev/null

echo "==> arrancando el servidor en el puerto $PORT"
docker run -d --rm --name "$CONTAINER" \
  -p "$PORT:8080" -p 7778:7778 \
  -e PORT=8080 \
  "$IMAGE" >/dev/null

# El contenedor puede morir al arrancar (puerto ocupado, imagen rota). Sin esta
# espera el script anunciaría una partida que no existe.
echo -n "==> esperando a que responda"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  if ! docker ps -q --filter "name=$CONTAINER" | grep -q .; then
    echo
    echo "El servidor se ha caído nada más arrancar:" >&2
    docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  echo -n "."
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || {
  echo
  echo "El servidor no responde en http://127.0.0.1:$PORT/health" >&2
  exit 1
}

# ---------------------------------------------------------------- página
# Con el repo en GitHub, la página del cliente está en Pages y su URL se
# deduce del remote. Es una suposición, no un hecho: --page la sobreescribe.
if [ -z "$PAGE" ]; then
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ "$REMOTE" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    PAGE="https://${BASH_REMATCH[1]}.github.io/${BASH_REMATCH[2]}/"
  fi
fi

# ---------------------------------------------------------------- túnel
if [ "$LOCAL_ONLY" = "1" ]; then
  echo
  echo "  Servidor local:  ws://$(ipconfig getifaddr en0 2>/dev/null || hostname):$PORT/ws"
  echo "  Pégalo en el campo \"servidor\" del cliente. Solo funciona en tu red."
  echo
  echo "Ctrl-C para parar."
  # `wait` sin trabajos en segundo plano vuelve de inmediato; este sleep es lo
  # que mantiene vivo el contenedor hasta que el usuario corte.
  while docker ps -q --filter "name=$CONTAINER" | grep -q .; do sleep 5; done
  exit 0
fi

PUBLIC=""
if command -v cloudflared >/dev/null 2>&1; then
  echo "==> abriendo túnel con cloudflared"
  cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  for _ in $(seq 1 30); do
    PUBLIC="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
    [ -n "$PUBLIC" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 1
  done
elif command -v ngrok >/dev/null 2>&1; then
  echo "==> abriendo túnel con ngrok"
  ngrok http "$PORT" --log stdout >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  # La API local de ngrok es más fiable que rascar su log, que cambia de
  # formato entre versiones.
  for _ in $(seq 1 30); do
    PUBLIC="$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
      | grep -Eo 'https://[a-z0-9.-]+\.ngrok[a-z.-]*\.(app|io)' | head -1 || true)"
    [ -n "$PUBLIC" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 1
  done
else
  cat >&2 <<EOF

No hay ningún túnel instalado. Con uno de los dos basta:

  macOS:  brew install cloudflared
  Linux:  https://github.com/cloudflare/cloudflared/releases

cloudflared no pide cuenta ni tarjeta. Si prefieres ngrok, instálalo y este
script lo usará igual.

Mientras tanto puedes jugar en tu red local con:  scripts/host-game.sh --local
EOF
  exit 2
fi

if [ -z "$PUBLIC" ]; then
  echo "No se pudo abrir el túnel. Últimas líneas:" >&2
  tail -20 "$TUNNEL_LOG" >&2
  exit 1
fi

WSS="wss://${PUBLIC#https://}/ws"

echo
echo "  ┌──────────────────────────────────────────────────────────────"
echo "  │  Partida abierta"
echo "  │"
if [ -n "$PAGE" ]; then
  echo "  │  Comparte este enlace:"
  echo "  │  ${PAGE%/}/?server=$WSS"
else
  echo "  │  Servidor:  $WSS"
  echo "  │  Pásalo a tus amigos con la página del cliente:"
  echo "  │  <tu-pagina>/?server=$WSS"
fi
echo "  │"
echo "  │  Cada jugador necesita su propia ROM; nadie la sube a ningún"
echo "  │  sitio. Ctrl-C aquí cierra la partida para todos."
echo "  └──────────────────────────────────────────────────────────────"
echo

# Si el túnel o el contenedor se caen, el enlace ya no vale: mejor terminar y
# que se note, que quedarse anunciando una partida muerta.
while kill -0 "$TUNNEL_PID" 2>/dev/null && docker ps -q --filter "name=$CONTAINER" | grep -q .; do
  sleep 5
done
echo "La partida se ha cerrado (el túnel o el servidor han terminado)." >&2
