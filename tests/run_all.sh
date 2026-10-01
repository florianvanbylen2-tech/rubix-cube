#!/usr/bin/env bash
# Runs the whole verification suite. Needs: the `luau` CLI (https://github.com/luau-lang/luau/releases) on PATH
# (or $LUAU), python3, and -- for the vanilla-data cross-checks -- `python3 tools/fetch_vanilla.py` run once.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
run() { tools/run_test.sh "$@"; }
pass() { echo "  PASS  $1"; }

echo "core: RNG / hashes / 64-bit maths vs independent Python implementation"
run tests/core_rng.luau | tr '\t' ' ' | diff -q - <(python3 tests/core_rng_ref.py) >/dev/null && pass "83 lines identical"
echo "noise: Improved/Perlin/Normal/Blended noise vs independent Python implementation"
run tests/noise.luau | tr '\t' ' ' | diff -q - <(python3 tests/noise_ref.py) >/dev/null && pass "24 lines identical"
echo "density: compiled density functions vs naive interpreter of the original vanilla JSON"
python3 tests/density_ref.py 12345 120 2>/dev/null | grep '^router' > build/density_ref.txt
run tests/density.luau | tr '\t' ' ' | diff -q - build/density_ref.txt >/dev/null && pass "1800 samples bit-identical"
echo "lattice: cell-corner interpolation indexing"
run tests/lattice.luau | tail -1 | grep -q "lattice OK" && pass "lattice OK"
echo "biome table: coverage of the climate space, tree search == linear search"
run tests/biomes_table.luau | grep -E "coverage|tree vs linear"
echo "chunk manager: multiplayer streaming invariants (incl. randomised fuzz)"
run tests/manager.luau | tail -1
echo "noise fill shortcuts == brute force (slow)"
run tests/shortcuts.luau --codegen | tail -1
echo "time-sliced generation == uninterrupted generation"
run tests/sliced.luau --codegen | tail -1
echo "structures: random_spread placement, determinism, filters"
run tests/structures.luau | tail -1
echo "chunk writer against a mocked Terrain"
run tests/writer.luau --codegen | tail -1
echo "Start() end-to-end against mocked Roblox services"
run tests/start_local.luau --codegen | tail -1
echo "load governor"
run tests/governor.luau | tail -1
echo "all done"
