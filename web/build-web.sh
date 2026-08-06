#!/usr/bin/env bash
#
# Package the gen1recomp client as a browser build.
#
# Two steps: stage the Lua game into a .love archive, then hand that archive to
# love.js, which is a prebuilt Emscripten port of LOVE 11.4 (no local emsdk
# needed -- the wasm ships in the npm package).
#
# What deliberately does NOT go into the archive is every ROM-derived artifact:
# data/generated/ and assets/generated/ are extracted from a copyrighted cart
# and are local artifacts, exactly as the repo README says. The browser build
# gets them the same way a fresh desktop install does -- the player supplies a
# ROM, and the in-engine importer extracts it at runtime, into the save
# directory (IndexedDB here). Nothing cart-derived is ever served.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web"
GAME="$ROOT/gen1recomp"
STAGE="$WEB/.stage"
DIST="$WEB/dist"

COMPAT=1          # love.js "compatibility" build: no SharedArrayBuffer, so it
                  # needs no COOP/COEP headers and hosts anywhere (Pages, S3).
MEMORY=268435456  # 256 MB initial heap. The wasm can still grow, but ROM
                  # extraction allocates hard and early; starting here avoids a
                  # storm of growth reallocations on the first import.
WITH_MODS=0       # mods/ holds a 26 MB voxel mod plus gameplay-altering
                  # examples; neither belongs in a page load by default.
TITLE="Pokemon MMO"
SERVER=""         # baked-in default game server. Empty means the page starts
                  # offline unless the link carries ?server=wss://...

usage() {
  cat <<'EOF'
Usage: web/build-web.sh [options]

  --with-mods     include gen1recomp/mods/ in the archive (adds ~26 MB)
  --threads       build the threaded (non-compatibility) love.js variant.
                  Needs cross-origin isolation: the host MUST send
                  Cross-Origin-Opener-Policy: same-origin and
                  Cross-Origin-Embedder-Policy: require-corp, or the page
                  will not boot. web/serve.py sends both.
  --memory BYTES  initial wasm heap (default 268435456)
  --title TEXT    page/window title
  --server URL    default game server for this build, e.g.
                  wss://mi-partida.trycloudflare.com/ws. Players can always
                  override it with ?server=... in the page URL or by typing
                  one in; without this flag the build starts offline.
  -h, --help      this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-mods) WITH_MODS=1 ;;
    --threads) COMPAT=0 ;;
    --memory) MEMORY="$2"; shift ;;
    --title) TITLE="$2"; shift ;;
    --server) SERVER="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Checked before the ten-minute part of the build, and checked strictly: this
# string is written into an HTML attribute, so a stray quote would break the
# page, and a wrong scheme would fail only much later, in a player's browser.
if [ -n "$SERVER" ]; then
  case "$SERVER" in
    ws://*|wss://*) ;;
    *) echo "--server must start with ws:// or wss:// (got: $SERVER)" >&2; exit 2 ;;
  esac
  case "$SERVER" in
    *[\"\'\<\>\&]*|*' '*) echo "--server contains characters that cannot go in an HTML attribute" >&2; exit 2 ;;
  esac
fi

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 2; }
command -v zip  >/dev/null 2>&1 || { echo "zip is required" >&2; exit 2; }

# love.js is pinned in web/package.json so a build is reproducible.
if [ ! -d "$WEB/node_modules/love.js" ]; then
  echo "==> installing love.js"
  (cd "$WEB" && npm install --silent)
fi

echo "==> staging game sources"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# -L dereferences symlinks: mods/ is dev-linked on desktop and PhysFS follows
# those, but a zip entry cannot.
copy() {
  local rel="$1"
  [ -e "$GAME/$rel" ] || return 0
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp -RL "$GAME/$rel" "$STAGE/$rel"
}

copy main.lua
copy conf.lua
copy src
copy libs
copy assets
copy data
[ "$WITH_MODS" = "1" ] && copy mods

# tools/ is mostly a build-time Python toolbox, but three files in it are read
# at RUNTIME and the build is broken without them:
#   * the per-version ROM manifests, which RomImporter.decodeManifest loads
#     before it will extract a cart (GameVersion.info(version).manifest)
#   * the save editor, which main.lua puts on the require path and the
#     launcher's Edit button opens
copy tools/rom_manifest.json
copy tools/rom_manifest_blue.json
copy tools/rom_manifest_yellow.json
copy tools/save-editor

# Cart-derived caches never ship. They are regenerated in the browser from the
# player's own upload; see RomImporter.
rm -rf "$STAGE/data/generated" "$STAGE/assets/generated"
# Platform payloads that cannot run in a browser and only add weight.
rm -rf "$STAGE/assets/switch" "$STAGE/assets/touch/.DS_Store"
find "$STAGE" -name '.DS_Store' -delete
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

if [ -d "$STAGE/data/generated" ] || [ -d "$STAGE/assets/generated" ]; then
  echo "refusing to build: ROM-derived data is still staged" >&2
  exit 1
fi
# A missing manifest does not fail the build -- it fails the player's first ROM
# import, minutes later, with a message about a file they have never heard of.
for required in main.lua conf.lua tools/rom_manifest.json src/core/Game.lua; do
  if [ ! -e "$STAGE/$required" ]; then
    echo "refusing to build: $required is missing from the archive" >&2
    exit 1
  fi
done

echo "==> building game.love"
rm -f "$WEB/.game.love"
(cd "$STAGE" && zip -qr9 "$WEB/.game.love" .)
LOVE_SIZE=$(du -h "$WEB/.game.love" | cut -f1)

echo "==> running love.js (compat=$COMPAT, memory=$MEMORY)"
rm -rf "$DIST"
COMPAT_FLAG=()
[ "$COMPAT" = "1" ] && COMPAT_FLAG=(-c)
(cd "$WEB" && npx --no-install love.js "${COMPAT_FLAG[@]}" \
  -t "$TITLE" -m "$MEMORY" "$WEB/.game.love" "$DIST" >/dev/null)

# love.js writes its own placeholder index.html; ours replaces it because the
# ROM upload and the server URL have to be collected before LOVE boots.
echo "==> installing the launcher page"
cp "$WEB/index.html" "$DIST/index.html"
# The launcher's pixel typefaces are self-hosted (web/fonts/, ~11 kB of woff2
# plus their OFL licences): the page is opened from phones on the LAN with no
# route to the internet, so a Google Fonts <link> would break it exactly where
# it is used most. Without this copy the page falls back to monospace.
cp -R "$WEB/fonts" "$DIST/fonts"
for font in press-start-2p-latin.woff2 silkscreen-latin-400.woff2 silkscreen-latin-700.woff2; do
  if [ ! -s "$DIST/fonts/$font" ]; then
    echo "refusing to build: web/fonts/$font is missing from the build" >&2
    exit 1
  fi
done
# The pre-made saves the launcher offers (web/saves/), so somebody can drop
# into the MMO and fight without playing through Kanto first. Plain Lua text,
# ~7 kB each, plus the options.lua that puts them in voxel mode. Copied like
# the typefaces and checked the same way: a launcher offering five teams and
# then failing to load any of them is worse than one that never offered.
cp -R "$WEB/saves" "$DIST/saves"
for preset in brasa psique marea tormenta bastion; do
  if [ ! -s "$DIST/saves/$preset.lua" ]; then
    echo "refusing to build: web/saves/$preset.lua is missing from the build" >&2
    exit 1
  fi
done
if [ ! -s "$DIST/saves/options.lua" ]; then
  echo "refusing to build: web/saves/options.lua is missing from the build" >&2
  exit 1
fi
# love.js's -m only sizes the index.html IT generates, and the line above just
# replaced that file. Carry the value into ours so --memory actually changes
# the heap the game boots with.
sed -i.bak "s#^<script>window.POKEMMO_MEMORY = [0-9]*;</script>\$#<script>window.POKEMMO_MEMORY = $MEMORY;</script>#" "$DIST/index.html"
rm -f "$DIST/index.html.bak"
if ! grep -q "window.POKEMMO_MEMORY = $MEMORY;" "$DIST/index.html"; then
  echo "refusing to build: could not apply --memory to the launcher page" >&2
  exit 1
fi
# Same treatment for --server: the launcher reads this meta tag as its default
# game server. A build without the flag keeps the placeholder, which the page
# recognises and treats as "no default".
if [ -n "$SERVER" ]; then
  sed -i.bak "s#<meta name=\"pokemon-mmo:server\" content=\"[^\"]*\">#<meta name=\"pokemon-mmo:server\" content=\"$SERVER\">#" "$DIST/index.html"
  rm -f "$DIST/index.html.bak"
  if ! grep -q "content=\"$SERVER\"" "$DIST/index.html"; then
    echo "refusing to build: could not apply --server to the launcher page" >&2
    exit 1
  fi
fi
# SDL's Emscripten backend registers its own beforeunload callback that pushes
# a quit event into LOVE, so a synthetic beforeunload dispatched to force an
# IDBFS sync kills the game silently ~10s after boot. Export FS.syncfs so the
# launcher page can sync saves directly without ever touching beforeunload.
sed -i.bak 's#Module\["FS_unlink"\]=FS.unlink;#Module["FS_unlink"]=FS.unlink;Module["FS_syncfs"]=function(populate,cb){FS.syncfs(populate,cb||function(){})};#g' "$DIST/love.js"
rm -f "$DIST/love.js.bak"
if ! grep -q 'FS_syncfs' "$DIST/love.js"; then
  echo "refusing to build: could not export FS_syncfs in love.js" >&2
  exit 1
fi
cat > "$DIST/build-info.json" <<EOF
{
  "title": $(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$TITLE"),
  "threads": $([ "$COMPAT" = "1" ] && echo false || echo true),
  "initialMemory": $MEMORY,
  "withMods": $([ "$WITH_MODS" = "1" ] && echo true || echo false),
  "server": $(node -e 'process.stdout.write(JSON.stringify(process.argv[1] || null))' "$SERVER")
}
EOF

rm -f "$WEB/.game.love"
rm -rf "$STAGE"

echo
echo "Built $DIST ($LOVE_SIZE of Lua/assets + $(du -h "$DIST/love.wasm" | cut -f1) wasm)"
echo "Serve it with:  web/serve.py"
if [ "$COMPAT" = "0" ]; then
  echo "NOTE: threaded build -- the host must send COOP/COEP headers."
fi
