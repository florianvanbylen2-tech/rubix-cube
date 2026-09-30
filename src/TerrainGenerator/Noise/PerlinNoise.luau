--!strict
--!native
-- Multi-octave Perlin noise (Minecraft's PerlinNoise), both the modern "octave_N" hashed
-- initialisation and the legacy sequential one that BlendedNoise still uses.

local ImprovedNoise = require(script.Parent.ImprovedNoise)

local floor = math.floor

local WRAP = 3.3554432e7

export type PerlinNoise = {
	levels: { ImprovedNoise.ImprovedNoise | boolean }, -- false where the amplitude is 0
	amps: { number },
	n: number,
	firstOctave: number,
	lowestFreqInputFactor: number,
	lowestFreqValueFactor: number,
	maxValue: number,
	getValue: (PerlinNoise, number, number, number) -> number,
	getOctaveNoise: (PerlinNoise, number) -> ImprovedNoise.ImprovedNoise?,
}

local PerlinNoise = {}
PerlinNoise.__index = PerlinNoise

local function finish(self: PerlinNoise)
	local n = self.n
	self.lowestFreqInputFactor = 2 ^ (-(-self.firstOctave))
	self.lowestFreqValueFactor = 2 ^ (n - 1) / (2 ^ n - 1)
	self.maxValue = PerlinNoise.edgeValue(self, 2.0)
end

-- amplitudes: array of numbers (index 1 = octave `firstOctave`)
function PerlinNoise.create(random: any, firstOctave: number, amplitudes: { number }): PerlinNoise
	local n = #amplitudes
	local levels: { any } = table.create(n, false)
	local factory = random:forkPositional()
	for k = 1, n do
		if amplitudes[k] ~= 0 then
			levels[k] = ImprovedNoise.new(factory:fromHashOf("octave_" .. tostring(firstOctave + k - 1)))
		end
	end
	local self = setmetatable({ levels = levels, amps = amplitudes, n = n, firstOctave = firstOctave }, PerlinNoise) :: any
	finish(self)
	return self
end

-- Legacy initialisation: the octaves are created highest frequency first from one shared random.
function PerlinNoise.createLegacy(random: any, firstOctave: number, amplitudes: { number }): PerlinNoise
	local n = #amplitudes
	local j = -firstOctave -- 0-based index of octave 0
	local levels: { any } = table.create(n, false)
	local first = ImprovedNoise.new(random)
	if j >= 0 and j < n and amplitudes[j + 1] ~= 0 then
		levels[j + 1] = first
	end
	for k = j - 1, 0, -1 do
		if k < n then
			if amplitudes[k + 1] ~= 0 then
				levels[k + 1] = ImprovedNoise.new(random)
			else
				random:consume(262)
			end
		else
			random:consume(262)
		end
	end
	local self = setmetatable({ levels = levels, amps = amplitudes, n = n, firstOctave = firstOctave }, PerlinNoise) :: any
	finish(self)
	return self
end

function PerlinNoise.getValue(self: PerlinNoise, x: number, y: number, z: number): number
	local levels, amps = self.levels, self.amps
	local total = 0
	local f = self.lowestFreqInputFactor
	local v = self.lowestFreqValueFactor
	for i = 1, self.n do
		local nz = levels[i]
		if nz then
			local ax, ay, az = x * f, y * f, z * f
			ax -= floor(ax / WRAP + 0.5) * WRAP
			ay -= floor(ay / WRAP + 0.5) * WRAP
			az -= floor(az / WRAP + 0.5) * WRAP
			total += amps[i] * (nz :: any):sample(ax, ay, az) * v
		end
		f *= 2
		v /= 2
	end
	return total
end

function PerlinNoise.edgeValue(self: PerlinNoise, d: number): number
	local total = 0
	local v = self.lowestFreqValueFactor
	for i = 1, self.n do
		if self.levels[i] then
			total += self.amps[i] * d * v
		end
		v /= 2
	end
	return total
end

-- octave 0 is the highest-frequency level (last in the array)
function PerlinNoise.getOctaveNoise(self: PerlinNoise, octave: number): ImprovedNoise.ImprovedNoise?
	local l = self.levels[self.n - octave]
	if l then
		return l :: any
	end
	return nil
end

function PerlinNoise.wrap(d: number): number
	return d - floor(d / WRAP + 0.5) * WRAP
end

return PerlinNoise
