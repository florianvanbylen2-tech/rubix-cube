--!strict
-- Biome.getTemperature(pos): base temperature, the FROZEN modifier (frozen oceans), and the cooling above y=80
-- that puts snow on tall mountains. The three simplex noises are seeded with vanilla's fixed constants.

local Simplex = require(script.Parent.Parent.Noise.SimplexNoise)

local TEMPERATURE_NOISE = Simplex.Perlin.new(0, 1234, { 0 })
local FROZEN_TEMPERATURE_NOISE = Simplex.Perlin.new(0, 3456, { -2, -1, 0 })
local BIOME_INFO_NOISE = Simplex.Perlin.new(0, 2345, { 0 })

local BiomeTemperature = {}

-- biome: entry of Data.Biomes ({temperature, frozen, ...})
function BiomeTemperature.at(biome: any, x: number, y: number, z: number): number
	local t: number = biome.temperature
	if biome.frozen then
		local d0 = FROZEN_TEMPERATURE_NOISE:getValue(x * 0.05, z * 0.05, false) * 7.0
		local d1 = BIOME_INFO_NOISE:getValue(x * 0.2, z * 0.2, false)
		if d0 + d1 < 0.3 then
			local d3 = BIOME_INFO_NOISE:getValue(x * 0.09, z * 0.09, false)
			if d3 < 0.8 then
				t = 0.2
			end
		end
	end
	if y > 80 then
		local f1 = TEMPERATURE_NOISE:getValue(x / 8, z / 8, false) * 8.0
		return t - (f1 + y - 80.0) * 0.05 / 40.0
	end
	return t
end

function BiomeTemperature.coldEnoughToSnow(biome: any, x: number, y: number, z: number): boolean
	return BiomeTemperature.at(biome, x, y, z) < 0.15
end

return BiomeTemperature
