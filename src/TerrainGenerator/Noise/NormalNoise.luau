--!strict
--!native
-- NormalNoise: two offset Perlin stacks averaged and normalised (what noise_router "noise" nodes sample).

local PerlinNoise = require(script.Parent.PerlinNoise)

local INPUT_FACTOR = 1.0181268882175227

export type NormalNoise = {
	first: PerlinNoise.PerlinNoise,
	second: PerlinNoise.PerlinNoise,
	valueFactor: number,
	maxValue: number,
	getValue: (NormalNoise, number, number, number) -> number,
}

local NormalNoise = {}
NormalNoise.__index = NormalNoise

function NormalNoise.create(random: any, firstOctave: number, amplitudes: { number }): NormalNoise
	local first = PerlinNoise.create(random, firstOctave, amplitudes)
	local second = PerlinNoise.create(random, firstOctave, amplitudes)
	local lo, hi = math.huge, -math.huge
	for i, a in amplitudes do
		if a ~= 0 then
			lo = math.min(lo, i - 1)
			hi = math.max(hi, i - 1)
		end
	end
	local expectedDeviation = 0.1 * (1 + 1 / ((hi - lo) + 1))
	local valueFactor = 0.16666666666666666 / expectedDeviation
	return setmetatable({
		first = first,
		second = second,
		valueFactor = valueFactor,
		maxValue = (first.maxValue + second.maxValue) * valueFactor,
	}, NormalNoise) :: any
end

function NormalNoise.getValue(self: NormalNoise, x: number, y: number, z: number): number
	return (self.first:getValue(x, y, z) + self.second:getValue(x * INPUT_FACTOR, y * INPUT_FACTOR, z * INPUT_FACTOR))
		* self.valueFactor
end

return NormalNoise
