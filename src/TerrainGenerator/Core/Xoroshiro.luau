--!strict
--!native
-- Minecraft's XoroshiroRandomSource (xoroshiro128++), RandomSupport seed upgrade,
-- and the positional random factory used to seed every noise, aquifer and surface rule.

local Int64 = require(script.Parent.Int64)
local Hash = require(script.Parent.Hash)

local band, bxor, rshift = bit32.band, bit32.bxor, bit32.rshift
local rotl64, add64, mul64, shr64, shl64, xor64 = Int64.rotl, Int64.add, Int64.mul, Int64.shr, Int64.shl, Int64.xor

local TWO32 = 4294967296
local TWO53_INV = 1.1102230246251565e-16 -- 2^-53
local TWO24_INV = 5.9604644775390625e-8 -- 2^-24

local GOLDEN_H, GOLDEN_L = 0x9E3779B9, 0x7F4A7C15
local SILVER_H, SILVER_L = 0x6A09E667, 0xF3BCC909

export type Xoroshiro = {
	a: number, -- state lo, high word
	b: number, -- state lo, low word
	c: number, -- state hi, high word
	d: number, -- state hi, low word
	nextLong: (Xoroshiro) -> (number, number),
	nextInt: (Xoroshiro, number?) -> number,
	nextDouble: (Xoroshiro) -> number,
	nextFloat: (Xoroshiro) -> number,
	nextBoolean: (Xoroshiro) -> boolean,
	forkPositional: (Xoroshiro) -> PositionalFactory,
}

export type PositionalFactory = {
	lh: number,
	ll: number,
	hh: number,
	hl: number,
	at: (PositionalFactory, number, number, number) -> Xoroshiro,
	fromHashOf: (PositionalFactory, string) -> Xoroshiro,
}

local Xoroshiro = {}
Xoroshiro.__index = Xoroshiro

local Factory = {}
Factory.__index = Factory

-- mixStafford13 on a 64 bit value
local function mix13(h: number, l: number): (number, number)
	local sh, sl = shr64(h, l, 30)
	h, l = xor64(h, l, sh, sl)
	h, l = mul64(h, l, 0xBF58476D, 0x1CE4E5B9)
	sh, sl = shr64(h, l, 27)
	h, l = xor64(h, l, sh, sl)
	h, l = mul64(h, l, 0x94D049BB, 0x133111EB)
	sh, sl = shr64(h, l, 31)
	return xor64(h, l, sh, sl)
end

-- RandomSupport.upgradeSeedTo128bit: 64 bit seed -> (loH, loL, hiH, hiL)
local function upgradeSeed(sh: number, sl: number): (number, number, number, number)
	local ih, il = xor64(sh, sl, SILVER_H, SILVER_L)
	local jh, jl = add64(ih, il, GOLDEN_H, GOLDEN_L)
	local lh, ll = mix13(ih, il)
	local hh, hl = mix13(jh, jl)
	return lh, ll, hh, hl
end

-- Constructs from a raw 128 bit state (lo, hi).
function Xoroshiro.newRaw(lh: number, ll: number, hh: number, hl: number): Xoroshiro
	if lh == 0 and ll == 0 and hh == 0 and hl == 0 then
		lh, ll, hh, hl = GOLDEN_H, GOLDEN_L, SILVER_H, SILVER_L
	end
	return setmetatable({ a = lh, b = ll, c = hh, d = hl }, Xoroshiro) :: any
end

-- Constructs from a 64 bit seed given as (hi, lo).
function Xoroshiro.new(seedH: number, seedL: number): Xoroshiro
	return Xoroshiro.newRaw(upgradeSeed(seedH, seedL))
end

function Xoroshiro.setSeed(self: Xoroshiro, seedH: number, seedL: number)
	self.a, self.b, self.c, self.d = upgradeSeed(seedH, seedL)
end

function Xoroshiro.nextLong(self: Xoroshiro): (number, number)
	local ih, il, jh, jl = self.a, self.b, self.c, self.d
	-- k = rotl(i + j, 17) + i
	local sh, sl = add64(ih, il, jh, jl)
	sh, sl = rotl64(sh, sl, 17)
	local kh, kl = add64(sh, sl, ih, il)
	-- j ^= i
	jh, jl = bxor(jh, ih), bxor(jl, il)
	-- s0 = rotl(i, 49) ^ j ^ (j << 21)
	local rh, rl = rotl64(ih, il, 49)
	local th, tl = shl64(jh, jl, 21)
	self.a, self.b = bxor(rh, jh, th), bxor(rl, jl, tl)
	-- s1 = rotl(j, 28)
	self.c, self.d = rotl64(jh, jl, 28)
	return kh, kl
end

function Xoroshiro.nextInt(self: Xoroshiro, bound: number?): number
	if bound == nil then
		local _, l = self:nextLong()
		return Int64.wrap32(l)
	end
	assert(bound > 0, "bound must be positive")
	local _, i = self:nextLong() -- unsigned low 32 bits
	if bound < 2097152 then
		local j = i * bound
		local k = j % TWO32
		if k < bound then
			local threshold = (TWO32 - bound) % bound
			while k < threshold do
				_, i = self:nextLong()
				j = i * bound
				k = j % TWO32
			end
		end
		return (j - k) / TWO32
	end
	local jh, jl = mul64(0, i, 0, bound)
	local k = jl
	if k < bound then
		local threshold = (TWO32 - bound) % bound
		while k < threshold do
			_, i = self:nextLong()
			jh, jl = mul64(0, i, 0, bound)
			k = jl
		end
	end
	return jh
end

function Xoroshiro.nextIntBetweenInclusive(self: Xoroshiro, lo: number, hi: number): number
	return self:nextInt(hi - lo + 1) + lo
end

function Xoroshiro.nextDouble(self: Xoroshiro): number
	local h, l = self:nextLong()
	return (h * 2097152 + rshift(l, 11)) * TWO53_INV
end

function Xoroshiro.nextFloat(self: Xoroshiro): number
	local h = self:nextLong()
	return rshift(h, 8) * TWO24_INV
end

function Xoroshiro.nextBoolean(self: Xoroshiro): boolean
	local _, l = self:nextLong()
	return band(l, 1) ~= 0
end

function Xoroshiro.consume(self: Xoroshiro, n: number)
	for _ = 1, n do
		self:nextLong()
	end
end

function Xoroshiro.forkPositional(self: Xoroshiro): PositionalFactory
	local lh, ll = self:nextLong()
	local hh, hl = self:nextLong()
	return setmetatable({ lh = lh, ll = ll, hh = hh, hl = hl }, Factory) :: any
end

-- ------------------------------------------------------------------ Mth.getSeed
-- long i = (long)(x * 3129871) ^ (long)z * 116129781L ^ (long)y; i = i*i*42317861L + i*11L; return i >> 16;
local function getSeed(x: number, y: number, z: number): (number, number)
	local xh, xl = Int64.fromInt32(Int64.wrap32(x * 3129871))
	local zh, zl = Int64.fromInt32(z)
	zh, zl = mul64(zh, zl, 0, 116129781)
	local yh, yl = Int64.fromInt32(y)
	local ih, il = xor64(xh, xl, zh, zl)
	ih, il = xor64(ih, il, yh, yl)
	local sqh, sql = mul64(ih, il, ih, il)
	sqh, sql = mul64(sqh, sql, 0, 42317861)
	local eh, el = mul64(ih, il, 0, 11)
	ih, il = add64(sqh, sql, eh, el)
	return Int64.sar(ih, il, 16)
end

-- PositionalRandomFactory.at(x, y, z)
function Factory.at(self: PositionalFactory, x: number, y: number, z: number): Xoroshiro
	local sh, sl = getSeed(x, y, z)
	return Xoroshiro.newRaw(bxor(sh, self.lh), bxor(sl, self.ll), self.hh, self.hl)
end

-- PositionalRandomFactory.fromHashOf(name): md5(name) xor factory seed
function Factory.fromHashOf(self: PositionalFactory, name: string): Xoroshiro
	local lh, ll, hh, hl = Hash.md5Longs(name)
	return Xoroshiro.newRaw(bxor(lh, self.lh), bxor(ll, self.ll), bxor(hh, self.hh), bxor(hl, self.hl))
end

Xoroshiro.getSeed = getSeed
Xoroshiro.upgradeSeed = upgradeSeed

return Xoroshiro
