#!/usr/bin/env python3
"""Independent big-integer reference for tests/core_rng.luau (output must match line for line)."""
import hashlib, struct

M64 = (1 << 64) - 1
def s32(v): v &= 0xFFFFFFFF; return v - (1 << 32) if v >> 31 else v
def s64(v): v &= M64; return v - (1 << 64) if v >> 63 else v
def hx(v): return "%016x" % (v & M64)
def rotl(x, k): return ((x << k) | (x >> (64 - k))) & M64

def md5(s): return hashlib.md5(s).hexdigest()

# ---- Java Random
class JR:
    def __init__(s, seed): s.seed = (seed ^ 0x5DEECE66D) & ((1 << 48) - 1)
    def next(s, bits):
        s.seed = (s.seed * 0x5DEECE66D + 0xB) & ((1 << 48) - 1)
        return s32(s.seed >> (48 - bits))
    def nextInt(s, bound=None):
        if bound is None: return s.next(32)
        if bound & (bound - 1) == 0: return (bound * s.next(31)) >> 31
        while True:
            bits = s.next(31); val = bits % bound
            if bits - val + (bound - 1) < (1 << 31): return val
    def nextLong(s): a = s.next(32); b = s.next(32); return s64((a << 32) + b)
    def nextFloat(s): return s.next(24) / float(1 << 24)
    def nextDouble(s): return ((s.next(26) << 27) + s.next(27)) * (1.0 / (1 << 53))
    def nextBoolean(s): return s.next(1) != 0
    def setLFS(s, base, x, z):
        s.__init__(base); i = s.nextLong(); j = s.nextLong()
        k = s64(s64(x * i) ^ s64(z * j) ^ base); s.__init__(k)

# ---- Xoroshiro128++
GOLD = 0x9E3779B97F4A7C15; SILV = 0x6A09E667F3BCC909
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
        i = seed ^ SILV; j = (i + GOLD) & M64
        return XO(mix13(i), mix13(j))
    def nextLong(s):
        i, j = s.lo, s.hi
        k = (rotl((i + j) & M64, 17) + i) & M64
        j ^= i
        s.lo = rotl(i, 49) ^ j ^ ((j << 21) & M64)
        s.hi = rotl(j, 28)
        return k
    def nextInt(s, bound=None):
        if bound is None: return s32(s.nextLong())
        i = s.nextLong() & 0xFFFFFFFF
        j = i * bound; k = j & 0xFFFFFFFF
        if k < bound:
            l = ((1 << 32) - bound) % bound
            while k < l:
                i = s.nextLong() & 0xFFFFFFFF; j = i * bound; k = j & 0xFFFFFFFF
        return j >> 32
    def nextDouble(s): return (s.nextLong() >> 11) * (1.0 / (1 << 53))
    def nextFloat(s): return (s.nextLong() >> 40) * (1.0 / (1 << 24))
    def nextBoolean(s): return (s.nextLong() & 1) != 0
    def fork(s): return (s.nextLong(), s.nextLong())

def get_seed(x, y, z):
    i = s64(s32(x * 3129871)) ^ s64(z * 116129781) ^ s64(y)
    i = s64(i)
    i = s64(i * i * 42317861 + i * 11)
    return i >> 16

def g17(x): return "%.17g" % x

for s in [b"", b"abc", b"The quick brown fox jumps over the lazy dog", b"minecraft:temperature", b"octave_-10", b"x" * 200]:
    print("md5", len(s), md5(s)); print("sha256", len(s), hashlib.sha256(s).hexdigest())

st = 12345
def rnd32():
    global st
    st = (st * 1664525 + 1013904223) % 4294967296
    return st
for i in range(1, 41):
    ah, al, bh, bl = rnd32(), rnd32(), rnd32(), rnd32()
    a = (ah << 32) | al; b = (bh << 32) | bl
    sa = a - (1 << 64) if a >> 63 else a
    print("i64", hx(a), hx(b), hx(a * b), hx(a + b), hx(a - b), hx(rotl(a, (i * 7) % 64)), hx(a << ((i * 5) % 64)),
          hx(a >> ((i * 3) % 64)), hx(sa >> ((i * 3) % 64)))

for seed in [(0, 0), (0, 42), (0xFFFFFFFF, 0xFFFFFFFF), (0x7048, 0x86A1B2C3), (0x9E3779B9, 0x7F4A7C15)]:
    sd = s64((seed[0] << 32) | seed[1]); r = JR(sd); out = []
    for _ in range(4): out.append(str(r.nextInt()))
    for _ in range(4): out.append(str(r.nextInt(100)))
    for _ in range(3): out.append(str(r.nextInt(16)))
    for _ in range(2): out.append(hx(r.nextLong()))
    out.append(g17(r.nextFloat())); out.append(g17(r.nextDouble())); out.append("true" if r.nextBoolean() else "false")
    print("java", "%08x%08x" % seed, " ".join(out))
r = JR(0); r.setLFS(0, 12345, -7 + 0 * 1) if False else None
def lfs(base, x, z):
    r = JR(0); r.setLFS(base, z if False else x, z); return r
# NOTE: luau test calls setLargeFeatureSeed(baseH, baseL, chunkX, chunkZ) with (0,12345,-7,19)
r = JR(0); r.setLFS(12345, -7, 19); print("lfs", r.nextInt(), r.nextInt(1000))
base = s64((0xFFFFFFFF << 32) | 0xFFFFFF00)
r = JR(0); r.setLFS(base, 100000, -100000); print("lfs", r.nextInt(), r.nextInt(1000))

for seed in [(0, 0), (0, 12345), (0xFFFFFFFF, 0xFFFFFFFF), (0x12345678, 0x9ABCDEF0)]:
    r = XO.seeded((seed[0] << 32) | seed[1]); out = []
    for _ in range(3): out.append(hx(r.nextLong()))
    out.append(str(r.nextInt()))
    for _ in range(3): out.append(str(r.nextInt(256)))
    out.append(str(r.nextInt(1000003))); out.append(str(r.nextInt(3000000)))
    out.append(g17(r.nextDouble())); out.append(g17(r.nextFloat())); out.append("true" if r.nextBoolean() else "false")
    print("xoro", "%08x%08x" % seed, " ".join(out))
    lo, hi = r.fork()
    print("fork", hx(lo), hx(hi))
    at = XO((get_seed(-1234, 63, 987) ^ lo) & M64, hi); print("at", hx(at.nextLong()))
    m = hashlib.md5(b"minecraft:continentalness").digest()
    hlo = int.from_bytes(m[:8], "big"); hhi = int.from_bytes(m[8:], "big")
    b = XO(hlo ^ lo, hhi ^ hi); print("hash", hx(b.nextLong()))
for c in [(0, 0, 0), (1, 2, 3), (-100, -64, 300), (2147483, 319, -2147483), (16, 0, -16)]:
    print("getSeed", *c, hx(get_seed(*c)))

def jhash(s):
    h = 0
    for u in struct.unpack("<%dH" % (len(s.encode("utf-16-le")) // 2), s.encode("utf-16-le")):
        h = (31 * h + u) & 0xFFFFFFFF
    return s32(h)
print("hash32", jhash("MyWorldName"), jhash(""), jhash("a"), jhash("Hello, Wörld"))
print("parse", hx(s64(-4172144997902289642))); print("parse", hx(9223372036854775807))
