#!/usr/bin/env python3
"""Downloads the exact Minecraft Java 1.20.1 worldgen JSON that the generator ports.

Source: https://github.com/misode/mcmeta (tag 1.20.1-data-json), which mirrors the
vanilla data pack.  Only files reachable from the overworld noise settings, the
overworld biomes and the features/carvers those biomes use are fetched.

    python tools/fetch_vanilla.py            # fills tools/.cache/vanilla
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE = "https://raw.githubusercontent.com/misode/mcmeta/1.20.1-data-json/data/minecraft/worldgen"
CACHE = Path(__file__).resolve().parent / ".cache" / "vanilla"

OVERWORLD_BIOMES = """
badlands bamboo_jungle beach birch_forest cherry_grove cold_ocean dark_forest deep_cold_ocean deep_dark
deep_frozen_ocean deep_lukewarm_ocean deep_ocean desert dripstone_caves eroded_badlands flower_forest forest
frozen_ocean frozen_peaks frozen_river grove ice_spikes jagged_peaks jungle lukewarm_ocean lush_caves
mangrove_swamp meadow mushroom_fields ocean old_growth_birch_forest old_growth_pine_taiga
old_growth_spruce_taiga plains river savanna savanna_plateau snowy_beach snowy_plains snowy_slopes snowy_taiga
sparse_jungle stony_peaks stony_shore sunflower_plains swamp taiga warm_ocean windswept_forest
windswept_gravelly_hills windswept_hills windswept_savanna wooded_badlands
""".split()

# Noises that the Java code references directly (not through JSON).
EXTRA_NOISES = """
surface surface_secondary clay_bands_offset badlands_surface badlands_pillar badlands_pillar_roof
iceberg_surface iceberg_pillar iceberg_pillar_roof ice packed_ice powder_snow calcite gravel
soul_sand_layer gravel_layer patch netherrack nether_state_selector swamp
aquifer_barrier aquifer_fluid_level_floodedness aquifer_fluid_level_spread aquifer_lava
ore_veininess ore_vein_a ore_vein_b ore_gap
""".split()

DENSITY_REF_KEYS = {
    "argument", "argument1", "argument2", "input", "when_in_range", "when_out_of_range",
    "shift_x", "shift_y", "shift_z", "coordinate",
}


def get(url: str, retries: int = 5) -> bytes | None:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "rubix-cube-tools"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(1 + attempt)
        except Exception:
            time.sleep(1 + attempt)
    raise RuntimeError(f"failed to fetch {url}")


def fetch(kind: str, name: str) -> dict | list | None:
    name = name.removeprefix("minecraft:")
    path = CACHE / kind / (name + ".json")
    if path.exists():
        return json.loads(path.read_text())
    data = get(f"{BASE}/{kind}/{name}.json")
    if data is None:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return json.loads(data)


def collect_density_refs(node, out: set[str], key: str | None = None) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "noise" and isinstance(v, str):
                out.add(("noise", v))
            else:
                collect_density_refs(v, out, k)
    elif isinstance(node, list):
        for v in node:
            collect_density_refs(v, out, key)
    elif isinstance(node, str) and node.startswith("minecraft:") and key in DENSITY_REF_KEYS:
        out.add(("density_function", node))


def collect_noise_refs(node, out: set) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "noise" and isinstance(v, str):
                out.add(("noise", v))
            collect_noise_refs(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_noise_refs(v, out)


def main() -> int:
    CACHE.mkdir(parents=True, exist_ok=True)

    ns = fetch("noise_settings", "overworld")
    assert ns, "noise_settings/overworld missing"

    # ---- density functions + noises -------------------------------------------------
    seen: set[tuple[str, str]] = set()
    todo: set[tuple[str, str]] = set()
    collect_density_refs(ns["noise_router"], todo)
    collect_noise_refs(ns["surface_rule"], todo)
    for n in EXTRA_NOISES:
        todo.add(("noise", "minecraft:" + n))
    for k, v in ns["noise_router"].items():
        if isinstance(v, str):
            todo.add(("density_function", v))

    def work(item):
        kind, name = item
        data = fetch(kind, name)
        if data is None and kind == "density_function":
            # e.g. shift_a/shift_b take a *noise* id in their "argument"
            data = fetch("noise", name)
        return item, data

    while todo:
        batch = sorted(todo - seen)
        todo = set()
        with ThreadPoolExecutor(8) as ex:
            for item, data in ex.map(work, batch):
                seen.add(item)
                if data is None:
                    print("  (missing)", item)
                    continue
                if item[0] == "density_function" and "type" in data:
                    collect_density_refs(data, todo)
    print(f"density functions + noises: {len(seen)}")

    # ---- biomes -------------------------------------------------------------------
    feature_refs: set[str] = set()
    carver_refs: set[str] = set()
    with ThreadPoolExecutor(8) as ex:
        biomes = list(ex.map(lambda b: (b, fetch("biome", b)), OVERWORLD_BIOMES))
    for name, b in biomes:
        if b is None:
            print("  (missing biome)", name)
            continue
        for step in b.get("features", []):
            for f in step:
                feature_refs.add(f)
        for _, lst in b.get("carvers", {}).items():
            for c in (lst if isinstance(lst, list) else [lst]):
                carver_refs.add(c)
    print(f"biomes: {len(biomes)}, placed features referenced: {len(feature_refs)}")

    with ThreadPoolExecutor(8) as ex:
        list(ex.map(lambda c: fetch("configured_carver", c), sorted(carver_refs)))

    # ---- placed/configured feature closure ----------------------------------------
    # Inline placed features look like {"feature": <configured ref>, "placement": [...]}; other
    # references are placed-feature names.  Over-fetch both registries for every name.
    def strings_under(node, keys):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in keys and isinstance(v, str):
                    yield v
                yield from strings_under(v, keys)
        elif isinstance(node, list):
            for v in node:
                yield from strings_under(v, keys)

    seen_names: set[str] = set()
    todo_names = set(feature_refs)
    placed = configured = 0
    while todo_names:
        batch = sorted(todo_names - seen_names)
        todo_names = set()
        with ThreadPoolExecutor(8) as ex:
            results = list(ex.map(lambda n: (n, fetch("placed_feature", n), fetch("configured_feature", n)), batch))
        for name, p, c in results:
            seen_names.add(name)
            if p is None and c is None:
                print("  (missing feature)", name)
            if p is not None:
                placed += 1
                todo_names.update(strings_under(p, {"feature", "default"}))
            if c is not None:
                configured += 1
                todo_names.update(strings_under(c, {"feature", "default"}))
    print(f"placed features: {placed}, configured features: {configured}")
    print("cache:", CACHE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
