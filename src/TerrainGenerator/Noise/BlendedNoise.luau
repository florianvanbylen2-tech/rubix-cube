--!strict
--!native
-- BlendedNoise: the pre-1.18 "old" terrain noise, still the 3D detail term of overworld terrain.
-- Three legacy-initialised Perlin stacks: two limit noises (16 octaves) blended by a selector (8 octaves).

local PerlinNoise = require(script.Parent.PerlinNoise)

local floor = math.floor
local WRAP = 3.3554432e7

export type BlendedNoise = {
	lower: PerlinNoise.PerlinNoise,
	upper: PerlinNoise.PerlinNoise,
	main: PerlinNoise.PerlinNoise,
	xzMultiplier: number,
	yMultiplier: number,
	xzFactor: number,
	yFactor: number,
	smear: number,
	maxValue: number,
	compute: (BlendedNoise, number, number, number) -> number,
}

local BlendedNoise = {}
BlendedNoise.__index = BlendedNoise

local function ones(n: number): { number }
	local t = table.create(n, 1)
	return t
end

function BlendedNoise.new(random: any, xzScale: number, yScale: number, xzFactor: number, yFactor: number, smear: number): BlendedNoise
	local lower = PerlinNoise.createLegacy(random, -15, ones(16))
	local upper = PerlinNoise.createLegacy(random, -15, ones(16))
	local main = PerlinNoise.createLegacy(random, -7, ones(8))
	return setmetatable({
		lower = lower,
		upper = upper,
		main = main,
		xzMultiplier = 684.412 * xzScale,
		yMultiplier = 684.412 * yScale,
		xzFactor = xzFactor,
		yFactor = yFactor,
		smear = smear,
		-- |noise| <= 2 per octave (the bound vanilla uses), giving |result| <= 2 * (2^16 - 1) / 2^16 * ... < 2.1
		maxValue = 2.1,
	}, BlendedNoise) :: any
end

function BlendedNoise.compute(self: BlendedNoise, bx: number, by: number, bz: number): number
	local d0 = bx * self.xzMultiplier
	local d1 = by * self.yMultiplier
	local d2 = bz * self.xzMultiplier
	local d3 = d0 / self.xzFactor
	local d4 = d1 / self.yFactor
	local d5 = d2 / self.xzFactor
	local d6 = self.yMultiplier * self.smear
	local d7 = d6 / self.yFactor

	local main = self.main
	local mainLevels = main.levels
	local mainN = main.n
	local d10 = 0
	local d11 = 1
	for i = 0, 7 do
		local nz = mainLevels[mainN - i]
		if nz then
			local ax, ay, az = d3 * d11, d4 * d11, d5 * d11
			ax -= floor(ax / WRAP + 0.5) * WRAP
			ay -= floor(ay / WRAP + 0.5) * WRAP
			az -= floor(az / WRAP + 0.5) * WRAP
			d10 += (nz :: any):noise(ax, ay, az, d7 * d11, d4 * d11) / d11
		end
		d11 /= 2
	end
	local d16 = (d10 / 10 + 1) / 2
	local skipLower = d16 >= 1
	local skipUpper = d16 <= 0

	local lowerLevels, upperLevels = self.lower.levels, self.upper.levels
	local d8, d9 = 0, 0
	d11 = 1
	for j = 0, 15 do
		local d12 = d0 * d11
		local d13 = d1 * d11
		local d14 = d2 * d11
		d12 -= floor(d12 / WRAP + 0.5) * WRAP
		d13 -= floor(d13 / WRAP + 0.5) * WRAP
		d14 -= floor(d14 / WRAP + 0.5) * WRAP
		local d15 = d6 * d11
		if not skipLower then
			local nz = lowerLevels[16 - j]
			if nz then
				d8 += (nz :: any):noise(d12, d13, d14, d15, d1 * d11) / d11
			end
		end
		if not skipUpper then
			local nz = upperLevels[16 - j]
			if nz then
				d9 += (nz :: any):noise(d12, d13, d14, d15, d1 * d11) / d11
			end
		end
		d11 /= 2
	end
	local a, b = d8 / 512, d9 / 512
	local r
	if d16 < 0 then
		r = a
	elseif d16 > 1 then
		r = b
	else
		r = a + d16 * (b - a)
	end
	return r / 128
end

return BlendedNoise
