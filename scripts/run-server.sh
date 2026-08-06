#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HTTP_PORT="${HTTP_PORT:-3100}"
export TCP_PORT="${TCP_PORT:-7778}"
export WS_PORT="${WS_PORT:-7779}"
cd "$ROOT/backend"
exec npm run dev
