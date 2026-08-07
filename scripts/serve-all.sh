#!/usr/bin/env bash
#
# Clonar y arrancar. Levanta el MMO completo detras de un unico tunel publico y
# sirve la ROM, de modo que abrir el enlace basta: la pagina carga la ROM sola
# y se conecta sola al servidor.
#
# Un solo tunel (cloudflared) apunta a web/serve.py, que a su vez:
#   - sirve el cliente en /
#   - sirve la ROM en /dev-rom.gb  (--rom)
#   - proxya /ws al WebSocket del backend
#
# Lo que NO sale a internet: ni el backend (3000/7778/7779) ni la ROM por otra
# ruta. Todo va por la URL del tunel.
#
#   scripts/serve-all.sh            todo, con tunel publico
#   scripts/serve-all.sh --local    sin tunel: solo LAN
#   scripts/serve-all.sh --rebuild  fuerza reconstruir el cliente web
#
# Ctrl-C lo cierra todo.

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
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcion desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

PIDS=()
TUNNEL_LOG="$(mktemp -t pokemon-mmo-tunnel)"
cleanup() {
  echo
  echo "==> cerrando"
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------- dependencias ----
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  case "$2" in
    brew)
      echo "Falta '$1'. Instalando con Homebrew..." >&2
      brew install "$1" || { echo "No se pudo instalar $1. Instalalo a mano." >&2; exit 2; }
      ;;
    *) echo "Falta '$1' ($2)." >&2; exit 2 ;;
  esac
}

need node "https://nodejs.org"
need python3 "https://www.python.org"
need zip "instala zip"
need rgbasm "macOS: brew install rgbds"
if [ "$LOCAL_ONLY" = 0 ]; then
  need cloudflared "macOS: brew install cloudflared  (o usa --local)"
fi

# ------------------------------------------------------------------ ROM ------
# pokered trae los graficos pre-convertidos (.2bpp) en el repo, asi que con
# rgbds basta; no hace falta Python. La .gbc esta en .gitignore (es un cartucho
# con copyright), por eso un clon fresco no la trae y hay que ensamblarla.
if [ ! -f "$ROM" ]; then
  echo "==> ensamblando la ROM local desde pokered (rgbds)"
  make -C "$ROOT/pokered" red
fi
[ -f "$ROM" ] || { echo "No se pudo construir $ROM" >&2; exit 1; }

# ------------------------------------------------------------------ mod ------
if [ ! -e "$MOD_LINK" ]; then
  echo "==> enlazando el mod de voxels"
  ln -s ../../DramaticShapeVoxelMod "$MOD_LINK"
fi

# --------------------------------------------------------------- backend -----
echo "==> instalando el backend"
(cd "$ROOT/backend" && npm install --silent)

echo "==> arrancando el backend (http=$HTTP_PORT ws=$WS_PORT tcp=$TCP_PORT)"
(cd "$ROOT/backend" && \
  HTTP_PORT="$HTTP_PORT" WS_PORT="$WS_PORT" TCP_PORT="$TCP_PORT" \
  npm run start:prod) &
PIDS+=($!)

echo -n "==> esperando al backend"
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
  echo "El backend no responde en http://127.0.0.1:$HTTP_PORT/health" >&2
  exit 1
}

# ----------------------------------------------------------------- web -------
# El cliente se construye SIN --server: la URL del tunel cambia en cada
# arranque, y la pagina lee ?server=... del enlace que imprimimos al final.
# Asi no hay que reconstruir el cliente cada vez que se abre un tunel nuevo.
NEED_BUILD=0
if [ "$REBUILD" = 1 ] || [ ! -d "$ROOT/web/dist" ]; then
  NEED_BUILD=1
elif ! grep -q '"withMods": true' "$ROOT/web/dist/build-info.json" 2>/dev/null; then
  NEED_BUILD=1
fi
if [ "$NEED_BUILD" = 1 ]; then
  echo "==> construyendo el cliente web (con el mod de voxels)"
  "$ROOT/web/build-web.sh" --with-mods
else
  echo "==> cliente web ya construido (usa --rebuild para forzarlo)"
fi

echo "==> arrancando el servidor web en el puerto $WEB_PORT (sirve ROM)"
python3 "$ROOT/web/serve.py" \
  --host 0.0.0.0 --port "$WEB_PORT" \
  --ws-port "$WS_PORT" \
  --rom "$ROM" &
PIDS+=($!)

# ----------------------------------------------------------------- tunel ----
if [ "$LOCAL_ONLY" = 1 ]; then
  LAN="$(ipconfig getifaddr en0 2>/dev/null || hostname)"
  PAGE="http://$LAN:$WEB_PORT/"
  WSS="ws://$LAN:$WEB_PORT/ws"
else
  echo "==> abriendo tunel con cloudflared"
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
    echo "No se abrio el tunel. Ultimas lineas:" >&2
    tail -20 "$TUNNEL_LOG" >&2
    exit 1
  fi
  PAGE="${PUBLIC}/"
  WSS="wss://${PUBLIC#https://}/ws"
fi

echo
echo "  ┌──────────────────────────────────────────────────────────────────"
echo "  │  Partida lista"
echo "  │"
echo "  │  Comparte este enlace (pagina + ROM + servidor, todo en uno):"
echo "  │  ${PAGE}?server=${WSS}"
echo "  │"
echo "  │  La ROM se sirve en ${PAGE}dev-rom.gb  (descargable por quien"
echo "  │  llegue al tunel: no lo dejes abierto sin vigilarlo)."
echo "  │  Ctrl-C cierra la partida para todos."
echo "  └──────────────────────────────────────────────────────────────────"
echo

# Mantener vivo hasta que algo se caiga.
while true; do
  for pid in "${PIDS[@]:-}"; do
    kill -0 "$pid" 2>/dev/null || { echo "Un proceso termino." >&2; exit 1; }
  done
  sleep 3
done
