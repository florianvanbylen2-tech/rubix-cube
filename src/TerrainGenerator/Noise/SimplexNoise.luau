--!strict
-- SimplexNoise + PerlinSimplexNoise (2D), used by Biome temperature (snow line, frozen oceans).
-- These noises are world-independent: vanilla seeds them with fixed constants (1234, 2345, 3456).

local JavaRandom = require(script.Parent.Parent.Core.JavaRandom)

local floor = math.floor

local GRAD = {
	{ 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 }, { 1, 0, 1 }, { -1, 0, 1 },
	{ 1, 0, -1 }, { -1, 0, -1 }, { 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
}
local SQRT_3 = math.sqrt(3.0)
local F2 = 0.5 * (SQRT_3 - 1.0)
local G2 = (3.0 - SQRT_3) / 6.0

export type SimplexNoise = { xo: number, yo: number, zo: number, p: { number }, getValue: (SimplexNoise, number, number) -> number }

local SimplexNoise = {}
SimplexNoise.__index = SimplexNoise

function SimplexNoise.new(random: any): SimplexNoise
	local xo = random:nextDouble() * 256
	local yo = random:nextDouble() * 256
	local zo = random:nextDouble() * 256
	local p = table.create(256, 0)
	for i = 0, 255 do
		p[i + 1] = i
	end
	for i = 0, 255 do
		local j = random:nextInt(256 - i)
		p[i + 1], p[j + i + 1] = p[j + i + 1], p[i + 1]
	end
	return setmetatable({ xo = xo, yo = yo, zo = zo, p = p }, SimplexNoise) :: any
end

local function corner(index: number, x: number, y: number, z: number): number
	local d1 = 0.5 - x * x - y * y - z * z
	if d1 < 0 then
		return 0
	end
	d1 *= d1
	local g = GRAD[index + 1]
	return d1 * d1 * (g[1] * x + g[2] * y + g[3] * z)
end

function SimplexNoise.getValue(self: SimplexNoise, x: number, y: number): number
	local p = self.p
	local d1 = (x + y) * F2
	local i, j = floor(x + d1), floor(y + d1)
	local d3 = (i + j) * G2
	local d4, d5 = i - d3, j - d3
	local d6, d7 = x - d4, y - d5
	local k, l
	if d6 > d7 then
		k, l = 1, 0
	else
		k, l = 0, 1
	end
	local d8, d9 = d6 - k + G2, d7 - l + G2
	local d10, d11 = d6 - 1.0 + 2.0 * G2, d7 - 1.0 + 2.0 * G2
	local i1, j1 = i % 256, j % 256
	local function P(n: number): number
		return p[n % 256 + 1]
	end
	local k1 = P(i1 + P(j1)) % 12
	local l1 = P(i1 + k + P(j1 + l)) % 12
	local i2 = P(i1 + 1 + P(j1 + 1)) % 12
	return 70.0 * (corner(k1, d6, d7, 0.0) + corner(l1, d8, d9, 0.0) + corner(i2, d10, d11, 0.0))
end

-- PerlinSimplexNoise over the given octave list (e.g. {0} or {-2, -1, 0}); seed as (hi, lo)
export type Perlin = { levels: { any }, freq: number, value: number, getValue: (Perlin, number, number, boolean) -> number }

local Perlin = {}
Perlin.__index = Perlin

function Perlin.new(seedH: number, seedL: number, octaves: { number }): Perlin
	local random = JavaRandom.new(seedH, seedL)
	local lowest, highest = math.huge, -math.huge
	local set: { [number]: boolean } = {}
	for _, o in octaves do
		lowest, highest = math.min(lowest, o), math.max(highest, o)
		set[o] = true
	end
	local i, j = -lowest, highest
	local k = i + j + 1
	local first = SimplexNoise.new(random)
	local levels: { any } = table.create(k, false)
	if j >= 0 and j < k and set[0] then
		levels[j + 1] = first
	end
	for l = j + 1, k - 1 do
		if set[j - l] then
			levels[l + 1] = SimplexNoise.new(random)
		else
			for _ = 1, 262 do
				random:nextInt()
			end
		end
	end
	assert(j <= 0, "PerlinSimplexNoise with positive octaves is not supported")
	return setmetatable({ levels = levels, freq = 2.0 ^ j, value = 1.0 / (2.0 ^ k - 1.0) }, Perlin) :: any
end

function Perlin.getValue(self: Perlin, x: number, y: number, useOffsets: boolean): number
	local total = 0
	local f, v = self.freq, self.value
	for _, s in self.levels do
		if s then
			total += s:getValue(x * f + (useOffsets and s.xo or 0), y * f + (useOffsets and s.yo or 0)) * v
		end
		f /= 2
		v *= 2
	end
	return total
end

return { SimplexNoise = SimplexNoise, Perlin = Perlin }
