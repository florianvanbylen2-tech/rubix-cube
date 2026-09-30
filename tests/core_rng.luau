-- Prints deterministic values from the RNG/hash layer; tests/core_rng_ref.py prints the same from an
-- independent big-integer implementation and the two outputs must be identical.
local Int64 = require(TG.Core.Int64)
local Hash = require(TG.Core.Hash)
local Xoroshiro = require(TG.Core.Xoroshiro)
local JavaRandom = require(TG.Core.JavaRandom)

local function hex(h, l) return string.format("%08x%08x", h, l) end

for _, s in { "", "abc", "The quick brown fox jumps over the lazy dog", "minecraft:temperature", "octave_-10", string.rep("x", 200) } do
	print("md5", #s, Hash.md5Hex(s))
	print("sha256", #s, Hash.sha256Hex(s))
end

-- Int64 arithmetic on pseudo random operands (LCG on doubles, deterministic)
local st = 12345
local function rnd32() st = (st * 1664525 + 1013904223) % 4294967296; return st end
for i = 1, 40 do
	local ah, al, bh, bl = rnd32(), rnd32(), rnd32(), rnd32()
	local mh, ml = Int64.mul(ah, al, bh, bl)
	local sh, sl = Int64.add(ah, al, bh, bl)
	local dh, dl = Int64.sub(ah, al, bh, bl)
	local rh, rl = Int64.rotl(ah, al, (i * 7) % 64)
	local lh, ll = Int64.shl(ah, al, (i * 5) % 64)
	local uh, ul = Int64.shr(ah, al, (i * 3) % 64)
	local nh, nl = Int64.sar(ah, al, (i * 3) % 64)
	print("i64", hex(ah, al), hex(bh, bl), hex(mh, ml), hex(sh, sl), hex(dh, dl), hex(rh, rl), hex(lh, ll), hex(uh, ul), hex(nh, nl))
end

-- Java Random
for _, seed in { { 0, 0 }, { 0, 42 }, { 0xFFFFFFFF, 0xFFFFFFFF }, { 0x00007048, 0x86A1B2C3 }, { 0x9E3779B9, 0x7F4A7C15 } } do
	local r = JavaRandom.new(seed[1], seed[2])
	local out = {}
	for _ = 1, 4 do table.insert(out, r:nextInt()) end
	for _ = 1, 4 do table.insert(out, r:nextInt(100)) end
	for _ = 1, 3 do table.insert(out, r:nextInt(16)) end
	for _ = 1, 2 do local h, l = r:nextLong(); table.insert(out, hex(h, l)) end
	table.insert(out, string.format("%.17g", r:nextFloat()))
	table.insert(out, string.format("%.17g", r:nextDouble()))
	table.insert(out, tostring(r:nextBoolean()))
	print("java", hex(seed[1], seed[2]), table.concat(out, " "))
end
do
	local r = JavaRandom.new(0, 0)
	r:setLargeFeatureSeed(0, 12345, -7, 19)
	print("lfs", r:nextInt(), r:nextInt(1000))
	r:setLargeFeatureSeed(0xFFFFFFFF, 0xFFFFFF00, 100000, -100000)
	print("lfs", r:nextInt(), r:nextInt(1000))
end

-- Xoroshiro
for _, seed in { { 0, 0 }, { 0, 12345 }, { 0xFFFFFFFF, 0xFFFFFFFF }, { 0x12345678, 0x9ABCDEF0 } } do
	local r = Xoroshiro.new(seed[1], seed[2])
	local out = {}
	for _ = 1, 3 do local h, l = r:nextLong(); table.insert(out, hex(h, l)) end
	table.insert(out, r:nextInt())
	for _ = 1, 3 do table.insert(out, r:nextInt(256)) end
	table.insert(out, r:nextInt(1000003))
	table.insert(out, r:nextInt(3000000))
	table.insert(out, string.format("%.17g", r:nextDouble()))
	table.insert(out, string.format("%.17g", r:nextFloat()))
	table.insert(out, tostring(r:nextBoolean()))
	print("xoro", hex(seed[1], seed[2]), table.concat(out, " "))
	local f = r:forkPositional()
	print("fork", hex(f.lh, f.ll), hex(f.hh, f.hl))
	local a = f:at(-1234, 63, 987)
	local h, l = a:nextLong()
	print("at", hex(h, l))
	local b = f:fromHashOf("minecraft:continentalness")
	h, l = b:nextLong()
	print("hash", hex(h, l))
end
for _, c in { { 0, 0, 0 }, { 1, 2, 3 }, { -100, -64, 300 }, { 2147483, 319, -2147483 }, { 16, 0, -16 } } do
	local h, l = Xoroshiro.getSeed(c[1], c[2], c[3])
	print("getSeed", c[1], c[2], c[3], hex(h, l))
end
print("hash32", Int64.javaStringHash("MyWorldName"), Int64.javaStringHash(""), Int64.javaStringHash("a"), Int64.javaStringHash("Hello, Wörld"))
local h, l = Int64.parse("-4172144997902289642")
print("parse", hex(h, l))
h, l = Int64.parse("9223372036854775807")
print("parse", hex(h, l))
