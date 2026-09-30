#!/usr/bin/env python3
"""Naive recursive interpreter for the ORIGINAL vanilla density-function JSON (no dedupe, no folding, no
short-circuits), used to cross-check the compiled Luau closures. Uses the independent noise transcription from
noise_ref.py. Prints values with %.17g; tests/density.luau must print identical lines."""
import json, math, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import noise_ref as N  # also prints its own reference output; silence it below

ROOT = Path(__file__).resolve().parent.parent / "tools/.cache/vanilla"
def strip(s): return s[10:] if s.startswith("minecraft:") else s

class World:
    def __init__(self, seed):
        self.fac = N.XO.seeded(seed).fork()
        self.noises = {}
        self.blended = None
        self.ns = json.loads((ROOT / "noise_settings/overworld.json").read_text())
    def noise(self, name):
        if name not in self.noises:
            d = json.loads((ROOT / "noise" / (name + ".json")).read_text())
            self.noises[name] = N.Normal(self.fac.from_hash("minecraft:" + name), d["firstOctave"], [float(a) for a in d["amplitudes"]])
        return self.noises[name]
    def blend(self, d):
        if self.blended is None:
            self.blended = N.Blended(self.fac.from_hash("minecraft:terrain"), d["xz_scale"], d["y_scale"], d["xz_factor"], d["y_factor"], d["smear_scale_multiplier"])
        return self.blended

def clamped_map(v, a, b, c, d):
    t = (v - a) / (b - a)
    return c if t < 0 else (d if t > 1 else c + t * (d - c))

def rarity3(v): return 0.75 if v < -0.5 else (1.0 if v < 0 else (1.5 if v < 0.5 else 2.0))
def rarity2(v): return 0.5 if v < -0.75 else (0.75 if v < -0.5 else (1.0 if v < 0.5 else (2.0 if v < 0.75 else 3.0)))

def spline(w, s, x, y, z):
    f = ev(w, s["coordinate"], x, y, z)
    pts = s["points"]
    locs = [p["location"] for p in pts]
    i = -1
    for k, l in enumerate(locs):
        if f >= l: i = k
    def val(k):
        v = pts[k]["value"]
        return v if isinstance(v, (int, float)) else spline(w, v, x, y, z)
    m = len(pts)
    if i < 0:
        d = pts[0]["derivative"]; v = val(0)
        return v if d == 0 else v + d * (f - locs[0])
    if i == m - 1:
        d = pts[-1]["derivative"]; v = val(m - 1)
        return v if d == 0 else v + d * (f - locs[-1])
    f1, f2 = locs[i], locs[i + 1]
    t = (f - f1) / (f2 - f1)
    v0, v1 = val(i), val(i + 1)
    d0, d1 = pts[i]["derivative"], pts[i + 1]["derivative"]
    f8 = d0 * (f2 - f1) - (v1 - v0)
    f9 = -d1 * (f2 - f1) + (v1 - v0)
    return (v0 + t * (v1 - v0)) + t * (1 - t) * (f8 + t * (f9 - f8))

def ev(w, n, x, y, z):
    if isinstance(n, (int, float)): return float(n)
    if isinstance(n, str):
        return ev(w, json.loads((ROOT / "density_function" / (strip(n) + ".json")).read_text()), x, y, z)
    t = strip(n["type"])
    A = lambda k: ev(w, n[k], x, y, z)
    if t == "add": return A("argument1") + A("argument2")
    if t == "mul": return A("argument1") * A("argument2")
    if t == "min": return min(A("argument1"), A("argument2"))
    if t == "max": return max(A("argument1"), A("argument2"))
    if t == "abs": return abs(A("argument"))
    if t == "square": v = A("argument"); return v * v
    if t == "cube": v = A("argument"); return v * v * v
    if t == "half_negative": v = A("argument"); return v if v > 0 else v * 0.5
    if t == "quarter_negative": v = A("argument"); return v if v > 0 else v * 0.25
    if t == "squeeze": v = max(-1.0, min(1.0, A("argument"))); return v / 2.0 - v * v * v / 24.0
    if t == "clamp": v = A("input"); return n["min"] if v < n["min"] else min(v, n["max"])
    if t == "y_clamped_gradient": return clamped_map(y, n["from_y"], n["to_y"], n["from_value"], n["to_value"])
    if t == "noise": return w.noise(strip(n["noise"])).get(x * n["xz_scale"], y * n["y_scale"], z * n["xz_scale"])
    if t == "shifted_noise":
        return w.noise(strip(n["noise"])).get(x * n["xz_scale"] + A("shift_x"), y * n["y_scale"] + A("shift_y"), z * n["xz_scale"] + A("shift_z"))
    if t == "shift_a": return w.noise(strip(n["argument"])).get(x * 0.25, 0.0, z * 0.25) * 4.0
    if t == "shift_b": return w.noise(strip(n["argument"])).get(z * 0.25, x * 0.25, 0.0) * 4.0
    if t == "weird_scaled_sampler":
        r = (rarity3 if strip(n["rarity_value_mapper"]) == "type_1" else rarity2)(A("input"))
        return r * abs(w.noise(strip(n["noise"])).get(x / r, y / r, z / r))
    if t == "old_blended_noise": return w.blend(n).get(x, y, z)
    if t == "range_choice":
        v = A("input")
        return A("when_in_range") if (v >= n["min_inclusive"] and v < n["max_exclusive"]) else A("when_out_of_range")
    if t == "spline": return spline(w, n["spline"], x, y, z)
    if t in ("interpolated", "flat_cache", "cache_2d", "cache_once", "cache_all_in_cell"): return A("argument")
    if t == "blend_alpha": return 1.0
    if t == "blend_offset": return 0.0
    if t == "blend_density": return A("argument")
    raise NotImplementedError(t)

if __name__ == "__main__":
    import io, contextlib
    seed = int(sys.argv[1])
    w = World(seed)
    router = w.ns["noise_router"]
    # deterministic sample points, far from the origin so the Luau flat-cache window is never used
    pts = []
    st = 987654321
    def rnd():
        global st
        st = (st * 1664525 + 1013904223) % 4294967296
        return st / 4294967296.0
    for i in range(int(sys.argv[2])):
        aligned = (i % 2 == 0)
        x = math.floor(rnd() * 8000 - 4000) + 300
        z = math.floor(rnd() * 8000 - 4000) - 300
        if aligned: x, z = x // 4 * 4, z // 4 * 4
        y = math.floor(rnd() * 384) - 64
        pts.append((x, y, z))
    names = ["temperature", "vegetation", "continents", "erosion", "depth", "ridges", "initial_density_without_jaggedness",
             "final_density", "barrier", "fluid_level_floodedness", "fluid_level_spread", "lava", "vein_toggle", "vein_ridged", "vein_gap"]
    for name in names:
        vals = [ev(w, router[name], *p) for p in pts]
        print("router", name, *["%.17g" % v for v in vals])
