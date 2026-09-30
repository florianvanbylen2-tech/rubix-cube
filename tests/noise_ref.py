#!/usr/bin/env python3
"""Independent Python transcription of the noise stack; output must match tests/noise.luau exactly."""
import hashlib, json, math, sys
from pathlib import Path

M64 = (1 << 64) - 1
GOLD = 0x9E3779B97F4A7C15; SILV = 0x6A09E667F3BCC909
def rotl(x, k): return ((x << k) | (x >> (64 - k))) & M64
def mix13(v):
    v = ((v ^ (v >> 30)) * 0xBF58476D1CE4E5B9) & M64
    v = ((v ^ (v >> 27)) * 0x94D049BB133111EB) & M64
    return v ^ (v >> 31)
class XO:
    def __init__(s, lo, hi):
        if lo == 0 and hi == 0: lo, hi = GOLD, SILV
        s.lo, s.hi = lo, hi
    @staticmethod
    def seeded(seed):
        i = (seed & M64) ^ SILV; j = (i + GOLD) & M64
        return XO(mix13(i), mix13(j))
    def nextLong(s):
        i, j = s.lo, s.hi
        k = (rotl((i + j) & M64, 17) + i) & M64
        j ^= i
        s.lo = rotl(i, 49) ^ j ^ ((j << 21) & M64)
        s.hi = rotl(j, 28)
        return k
    def nextInt(s, bound):
        i = s.nextLong() & 0xFFFFFFFF
        j = i * bound; k = j & 0xFFFFFFFF
        if k < bound:
            l = ((1 << 32) - bound) % bound
            while k < l:
                i = s.nextLong() & 0xFFFFFFFF; j = i * bound; k = j & 0xFFFFFFFF
        return j >> 32
    def nextDouble(s): return (s.nextLong() >> 11) * (1.0 / (1 << 53))
    def fork(s): return Fac(s.nextLong(), s.nextLong())
class Fac:
    def __init__(s, lo, hi): s.lo, s.hi = lo, hi
    def from_hash(s, name):
        m = hashlib.md5(name.encode()).digest()
        return XO(int.from_bytes(m[:8], "big") ^ s.lo, int.from_bytes(m[8:], "big") ^ s.hi)

GRAD = [(1,1,0),(-1,1,0),(1,-1,0),(-1,-1,0),(1,0,1),(-1,0,1),(1,0,-1),(-1,0,-1),(0,1,1),(0,-1,1),(0,1,-1),(0,-1,-1),(1,1,0),(0,-1,1),(-1,1,0),(0,-1,-1)]
def lerp(t, a, b): return a + t * (b - a)
def smooth(x): return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
FUDGE = 1.0000000116860974e-07

class IN:
    def __init__(s, r):
        s.xo = r.nextDouble() * 256.0; s.yo = r.nextDouble() * 256.0; s.zo = r.nextDouble() * 256.0
        s.p = list(range(256))
        for k in range(256):
            l = r.nextInt(256 - k)
            s.p[k], s.p[k + l] = s.p[k + l], s.p[k]
    def P(s, i): return s.p[i & 255]
    def noise(s, x, y, z, ys=0.0, ym=0.0):
        d0, d1, d2 = x + s.xo, y + s.yo, z + s.zo
        i, j, k = math.floor(d0), math.floor(d1), math.floor(d2)
        d3, d4, d5 = d0 - i, d1 - j, d2 - k
        if ys != 0.0:
            d7 = ym if (ym >= 0.0 and ym < d4) else d4
            d6 = math.floor(d7 / ys + FUDGE) * ys
        else: d6 = 0.0
        return s.lerp_(i, j, k, d3, d4 - d6, d5, d4)
    def lerp_(s, gx, gy, gz, dx, wy, dz, dy):
        P = s.P
        i = P(gx); j = P(gx + 1); k = P(i + gy); l = P(i + gy + 1); i1 = P(j + gy); j1 = P(j + gy + 1)
        def gd(h, x, y, z):
            g = GRAD[h & 15]; return g[0] * x + g[1] * y + g[2] * z
        d0 = gd(P(k + gz), dx, wy, dz); d1 = gd(P(i1 + gz), dx - 1.0, wy, dz)
        d2 = gd(P(l + gz), dx, wy - 1.0, dz); d3 = gd(P(j1 + gz), dx - 1.0, wy - 1.0, dz)
        d4 = gd(P(k + gz + 1), dx, wy, dz - 1.0); d5 = gd(P(i1 + gz + 1), dx - 1.0, wy, dz - 1.0)
        d6 = gd(P(l + gz + 1), dx, wy - 1.0, dz - 1.0); d7 = gd(P(j1 + gz + 1), dx - 1.0, wy - 1.0, dz - 1.0)
        u, v, w = smooth(dx), smooth(dy), smooth(dz)
        def lerp2(a, b, v00, v10, v01, v11): return lerp(b, lerp(a, v00, v10), lerp(a, v01, v11))
        return lerp(w, lerp2(u, v, d0, d1, d2, d3), lerp2(u, v, d4, d5, d6, d7))

def wrap(d): return d - math.floor(d / 3.3554432e7 + 0.5) * 3.3554432e7

class Perlin:
    def __init__(s, r, first, amps, legacy=False):
        s.first, s.amps = first, amps; n = len(amps); j = -first
        s.levels = [None] * n
        if not legacy:
            f = r.fork()
            for k in range(n):
                if amps[k] != 0.0: s.levels[k] = IN(f.from_hash("octave_%d" % (first + k)))
        else:
            imp = IN(r)
            if 0 <= j < n and amps[j] != 0.0: s.levels[j] = imp
            for k in range(j - 1, -1, -1):
                if k < n:
                    if amps[k] != 0.0: s.levels[k] = IN(r)
                    else: [r.nextLong() for _ in range(262)]
                else: [r.nextLong() for _ in range(262)]
        s.lin = 2.0 ** (-j); s.lvf = 2.0 ** (n - 1) / (2.0 ** n - 1.0)
        s.maxv = s.edge(2.0)
    def edge(s, d):
        t = 0.0; v = s.lvf
        for i in range(len(s.levels)):
            if s.levels[i] is not None: t += s.amps[i] * d * v
            v /= 2.0
        return t
    def get(s, x, y, z):
        t = 0.0; f = s.lin; v = s.lvf
        for i, n in enumerate(s.levels):
            if n is not None:
                t += s.amps[i] * n.noise(wrap(x * f), wrap(y * f), wrap(z * f), 0.0, 0.0) * v
            f *= 2.0; v /= 2.0
        return t
    def octave(s, o): return s.levels[len(s.levels) - 1 - o]

class Normal:
    def __init__(s, r, first, amps):
        s.a = Perlin(r, first, amps); s.b = Perlin(r, first, amps)
        idx = [i for i, a in enumerate(amps) if a != 0.0]
        s.vf = 0.16666666666666666 / (0.1 * (1.0 + 1.0 / (max(idx) - min(idx) + 1)))
        s.maxv = (s.a.maxv + s.b.maxv) * s.vf
    def get(s, x, y, z):
        return (s.a.get(x, y, z) + s.b.get(x * 1.0181268882175227, y * 1.0181268882175227, z * 1.0181268882175227)) * s.vf

class Blended:
    def __init__(s, r, xzs, ys, xzf, yf, sm):
        s.lo = Perlin(r, -15, [1.0] * 16, True); s.up = Perlin(r, -15, [1.0] * 16, True); s.mn = Perlin(r, -7, [1.0] * 8, True)
        s.xzm = 684.412 * xzs; s.ym = 684.412 * ys; s.xzf = xzf; s.yf = yf; s.sm = sm
    def get(s, bx, by, bz):
        d0 = bx * s.xzm; d1 = by * s.ym; d2 = bz * s.xzm
        d3 = d0 / s.xzf; d4 = d1 / s.yf; d5 = d2 / s.xzf
        d6 = s.ym * s.sm; d7 = d6 / s.yf
        d8 = d9 = d10 = 0.0; d11 = 1.0
        for i in range(8):
            n = s.mn.octave(i)
            if n is not None: d10 += n.noise(wrap(d3 * d11), wrap(d4 * d11), wrap(d5 * d11), d7 * d11, d4 * d11) / d11
            d11 /= 2.0
        d16 = (d10 / 10.0 + 1.0) / 2.0
        f1 = d16 >= 1.0; f2 = d16 <= 0.0; d11 = 1.0
        for j in range(16):
            d12 = wrap(d0 * d11); d13 = wrap(d1 * d11); d14 = wrap(d2 * d11); d15 = d6 * d11
            if not f1:
                n = s.lo.octave(j)
                if n is not None: d8 += n.noise(d12, d13, d14, d15, d1 * d11) / d11
            if not f2:
                n = s.up.octave(j)
                if n is not None: d9 += n.noise(d12, d13, d14, d15, d1 * d11) / d11
            d11 /= 2.0
        a, b = d8 / 512.0, d9 / 512.0
        r = a if d16 < 0.0 else (b if d16 > 1.0 else lerp(d16, a, b))
        return r / 128.0

def g17(x): return "%.17g" % x
root = Path(__file__).resolve().parent.parent / "tools/.cache/vanilla/noise"
pts = [(0, 0, 0), (13.5, 64, -7.25), (-1234.0, 200.0, 4321.0), (100000.0, -30.0, 100000.0), (5.0, 5.0, 5.0), (-0.5, 320.0, 0.5),
       (1e7, 10.0, -1e7), (37.0, -64.0, 91.0)]
for seed in [12345, 0, -4172144997902289642]:
    fac = XO.seeded(seed).fork()
    for name in ["temperature", "continentalness", "jagged", "cave_cheese", "ore_veininess", "surface", "offset"]:
        d = json.loads((root / (name + ".json")).read_text())
        nn = Normal(fac.from_hash("minecraft:" + name), d["firstOctave"], [float(a) for a in d["amplitudes"]])
        print("normal", seed, name, g17(nn.maxv), *[g17(nn.get(*p)) for p in pts])
    bl = Blended(fac.from_hash("minecraft:terrain"), 0.25, 0.125, 80.0, 160.0, 8.0)
    print("blended", seed, *[g17(bl.get(*p)) for p in [(0, 0, 0), (16, 64, 16), (-100, 100, 200), (1000, -64, -1000), (7, 300, 7), (123456, 90, -654321)]])
