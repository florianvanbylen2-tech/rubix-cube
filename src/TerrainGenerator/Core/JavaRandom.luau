--!strict
--!native
-- java.util.Random / Minecraft's LegacyRandomSource: a 48 bit LCG kept in two 24 bit limbs so every
-- product stays exact in a double.  Used by the classic carvers (caves, canyons) and legacy noise.

local Int64 = require(script.Parent.Int64)

local TWO24 = 16777216
local TWO32 = 4294967296
local M0 = 0xECE66D -- low 24 bits of 0x5DEECE66D
local M1 = 0x5DE -- the rest
local TWO53_INV = 1.1102230246251565e-16
local DIV: { number } = {} -- DIV[bits] = 2^(48 - bits)
for bits = 1, 32 do
	DIV[bits] = 2 ^ (48 - bits)
end

export type JavaRandom = {
	s0: number, -- bits 0..23
	s1: number, -- bits 24..47
	setSeed: (JavaRandom, number, number) -> (),
	next: (JavaRandom, number) -> number,
	nextInt: (JavaRandom, number?) -> number,
	nextLong: (JavaRandom) -> (number, number),
	nextFloat: (JavaRandom) -> number,
	nextDouble: (JavaRandom) -> number,
	nextBoolean: (JavaRandom) -> boolean,
}

local JavaRandom = {}
JavaRandom.__index = JavaRandom

-- seed given as a signed 64 bit (hi, lo)
function JavaRandom.new(seedH: number, seedL: number): JavaRandom
	local self = setmetatable({ s0 = 0, s1 = 0 }, JavaRandom) :: any
	self:setSeed(seedH, seedL)
	return self
end

function JavaRandom.setSeed(self: JavaRandom, seedH: number, seedL: number)
	-- (seed ^ 0x5DEECE66D) & (2^48 - 1)
	local s0 = bit32.band(seedL, 0xFFFFFF)
	local s1 = bit32.band(bit32.bor(bit32.rshift(seedL, 24), bit32.lshift(bit32.band(seedH, 0xFFFF), 8)), 0xFFFFFF)
	self.s0 = bit32.bxor(s0, M0)
	self.s1 = bit32.bxor(s1, M1)
end

function JavaRandom.next(self: JavaRandom, bits: number): number
	local s0, s1 = self.s0, self.s1
	local t0 = s0 * M0 + 11
	local n0 = t0 % TWO24
	local carry = (t0 - n0) / TWO24
	local t1 = s1 * M0 + s0 * M1 + carry
	local n1 = t1 % TWO24
	self.s0, self.s1 = n0, n1
	local state = n1 * TWO24 + n0
	local v = math.floor(state / DIV[bits])
	if bits == 32 and v >= 2147483648 then
		v -= TWO32
	end
	return v
end

function JavaRandom.nextInt(self: JavaRandom, bound: number?): number
	if bound == nil then
		return self:next(32)
	end
	assert(bound > 0, "bound must be positive")
	if bit32.band(bound, bound - 1) == 0 then
		return math.floor(bound * self:next(31) / 2147483648)
	end
	while true do
		local bits = self:next(31)
		local val = bits % bound
		if bits - val + (bound - 1) < 2147483648 then
			return val
		end
	end
end

function JavaRandom.nextLong(self: JavaRandom): (number, number)
	local i = self:next(32)
	local j = self:next(32)
	local h = (i % TWO32 + (j < 0 and -1 or 0)) % TWO32
	return h, j % TWO32
end

function JavaRandom.nextFloat(self: JavaRandom): number
	return self:next(24) * 5.9604644775390625e-8
end

function JavaRandom.nextDouble(self: JavaRandom): number
	local a = self:next(26)
	local b = self:next(27)
	return (a * 134217728 + b) * TWO53_INV
end

function JavaRandom.nextBoolean(self: JavaRandom): boolean
	return self:next(1) ~= 0
end

-- WorldgenRandom.setLargeFeatureSeed(baseSeed, chunkX, chunkZ); the base seed is (hi, lo)
function JavaRandom.setLargeFeatureSeed(self: JavaRandom, baseH: number, baseL: number, chunkX: number, chunkZ: number)
	self:setSeed(baseH, baseL)
	local ih, il = self:nextLong()
	local jh, jl = self:nextLong()
	local xh, xl = Int64.fromInt32(chunkX)
	local zh, zl = Int64.fromInt32(chunkZ)
	xh, xl = Int64.mul(xh, xl, ih, il)
	zh, zl = Int64.mul(zh, zl, jh, jl)
	local kh, kl = Int64.xor(xh, xl, zh, zl)
	kh, kl = Int64.xor(kh, kl, baseH, baseL)
	self:setSeed(kh, kl)
end

return JavaRandom
