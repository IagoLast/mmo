#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROM_PATH="${1:-}"
MOD_LINK="$ROOT/gen1recomp/mods/dramatic_shape"

if [ -z "$ROM_PATH" ]; then
  ROM_PATH="$ROOT/pokered/pokered.gbc"

  if [ ! -f "$ROM_PATH" ]; then
    if ! command -v rgbasm >/dev/null 2>&1; then
      echo "RGBDS is required to build pokered (macOS: brew install rgbds)." >&2
      exit 2
    fi

    echo "Building the local Red ROM from pret/pokered..."
    make -C "$ROOT/pokered" red
  fi
elif [ ! -f "$ROM_PATH" ]; then
  echo "ROM not found: $ROM_PATH" >&2
  exit 2
fi

if [ ! -e "$MOD_LINK" ]; then
  ln -s ../../DramaticShapeVoxelMod "$MOD_LINK"
fi

(cd "$ROOT/backend" && npm install)
(cd "$ROOT/gen1recomp" && scripts/setup.sh --rom "$ROM_PATH")

echo "MVP ready. Start the server with scripts/run-server.sh"
