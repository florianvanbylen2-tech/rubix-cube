#!/usr/bin/env bash
# usage: tools/run_test.sh tests/foo.luau [luau flags...]   (needs the `luau` CLI on PATH or $LUAU)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${LUAU:-luau}"
t="$1"; shift
python3 "$ROOT/tools/bundle.py" "$ROOT/$t" "$ROOT/build/$(basename "$t" .luau).bundle.luau"
"$LUAU" "$@" "$ROOT/build/$(basename "$t" .luau).bundle.luau"
