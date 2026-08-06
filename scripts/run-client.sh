#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_ID="${1:-player}"

export POKEPORT_MMO_ADDR="${POKEPORT_MMO_ADDR:-127.0.0.1:7778}"
export POKEPORT_IDENTITY="pokemon-mmo-$CLIENT_ID"
export POKEPORT_MMO_DEFAULTS="${POKEPORT_MMO_DEFAULTS:-1}"

cd "$ROOT/gen1recomp"
exec scripts/run.sh
