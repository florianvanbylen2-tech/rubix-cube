#!/usr/bin/env bash
# usage: tools/run_test.sh tests/foo.luau [luau flags...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${LUAU:-/tmp/claude-0/-home-user-rubix-cube/7c833cf8-5ec9-503a-863f-34b9b6986f42/scratchpad/luau/luau}"
t="$1"; shift
python3 "$ROOT/tools/bundle.py" "$ROOT/$t" "$ROOT/build/$(basename "$t" .luau).bundle.luau"
"$LUAU" "$@" "$ROOT/build/$(basename "$t" .luau).bundle.luau"
