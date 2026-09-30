--!strict
-- Mirrors net.minecraft.world.level.levelgen.RandomState: one root positional random per world seed,
-- from which every named noise / random factory is derived by hashing its resource name.

local Xoroshiro = require(script.Parent.Parent.Core.Xoroshiro)
local Int64 = require(script.Parent.Parent.Core.Int64)
local NormalNoise = require(script.Parent.Parent.Noise.NormalNoise)
local BlendedNoise = require(script.Parent.Parent.Noise.BlendedNoise)
local NoiseParams = require(script.Parent.Parent.Data.NoiseParams)

export type RandomState = {
	seedH: number,
	seedL: number,
	random: Xoroshiro.PositionalFactory,
	aquiferRandom: Xoroshiro.PositionalFactory,
	oreRandom: Xoroshiro.PositionalFactory,
	getNoise: (RandomState, string) -> NormalNoise.NormalNoise,
	getRandomFactory: (RandomState, string) -> Xoroshiro.PositionalFactory,
	getBlended: (RandomState, number, number, number, number, number) -> BlendedNoise.BlendedNoise,
}

local RandomState = {}
RandomState.__index = RandomState

-- Accepts a number, a numeric string (parsed as a 64 bit long) or any other string (Java hashCode),
-- exactly like Minecraft's level-seed field.
function RandomState.seedFrom(seed: number | string): (number, number)
	if type(seed) == "number" then
		if seed == math.floor(seed) then
			return Int64.fromNumber(seed)
		end
		return Int64.fromNumber(math.floor(seed))
	end
	local h, l = Int64.parse(seed)
	if h then
		return h, l :: number
	end
	return Int64.fromInt32(Int64.javaStringHash(seed))
end

function RandomState.new(seedH: number, seedL: number): RandomState
	local random = Xoroshiro.new(seedH, seedL):forkPositional()
	local self = {
		seedH = seedH,
		seedL = seedL,
		random = random,
		aquiferRandom = random:fromHashOf("minecraft:aquifer"):forkPositional(),
		oreRandom = random:fromHashOf("minecraft:ore"):forkPositional(),
		noises = {} :: { [string]: NormalNoise.NormalNoise },
		factories = {} :: { [string]: Xoroshiro.PositionalFactory },
		blended = nil :: BlendedNoise.BlendedNoise?,
	}
	return setmetatable(self, RandomState) :: any
end

-- name without namespace, e.g. "temperature"
function RandomState.getNoise(self: RandomState, name: string): NormalNoise.NormalNoise
	local s = self :: any
	local n = s.noises[name]
	if n then
		return n
	end
	local p = NoiseParams[name]
	assert(p, "unknown noise " .. name)
	local amps = table.create(#p[2], 0)
	for i, a in p[2] do
		amps[i] = a
	end
	n = NormalNoise.create(self.random:fromHashOf("minecraft:" .. name), p[1], amps)
	s.noises[name] = n
	return n
end

-- PositionalRandomFactory for a named random (surface rule gradients, clay bands, ...)
function RandomState.getRandomFactory(self: RandomState, name: string): Xoroshiro.PositionalFactory
	local s = self :: any
	local f = s.factories[name]
	if not f then
		f = self.random:fromHashOf("minecraft:" .. name):forkPositional()
		s.factories[name] = f
	end
	return f
end

function RandomState.getBlended(self: RandomState, xzScale: number, yScale: number, xzFactor: number, yFactor: number, smear: number): BlendedNoise.BlendedNoise
	local s = self :: any
	if not s.blended then
		s.blended = BlendedNoise.new(self.random:fromHashOf("minecraft:terrain"), xzScale, yScale, xzFactor, yFactor, smear)
	end
	return s.blended
end

return RandomState
