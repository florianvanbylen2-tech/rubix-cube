local RandomState = require(TG.World.RandomState)
local Compiler = require(TG.Density.Compiler)
local BiomeRegistry = require(TG.World.BiomeRegistry)
local BiomeSource = require(TG.World.BiomeSource)

local h, l = RandomState.seedFrom(12345)
local rs = RandomState.new(h, l)
local S = Compiler.compile(rs)
local reg = BiomeRegistry.new()
local bs = BiomeSource.new(S, reg, rs)

-- a biome map: 96 x 48 cells, 32 blocks each
local sym = {
	ocean = "~", deep_ocean = "≈", cold_ocean = "~", deep_cold_ocean = "≈", frozen_ocean = "=", deep_frozen_ocean = "=", warm_ocean = "w", lukewarm_ocean = "~", deep_lukewarm_ocean = "≈",
	plains = ".", sunflower_plains = ".", forest = "f", birch_forest = "b", dark_forest = "D", flower_forest = "F", taiga = "t", snowy_taiga = "T", snowy_plains = "s", ice_spikes = "i",
	desert = "d", savanna = "v", savanna_plateau = "V", windswept_savanna = "V", jungle = "J", sparse_jungle = "j", bamboo_jungle = "B", swamp = "S", mangrove_swamp = "M",
	beach = ",", snowy_beach = ",", stony_shore = "'", river = "r", frozen_river = "r", badlands = "A", eroded_badlands = "A", wooded_badlands = "A",
	meadow = "m", cherry_grove = "c", grove = "g", snowy_slopes = "^", jagged_peaks = "^", frozen_peaks = "^", stony_peaks = "^", windswept_hills = "h", windswept_gravelly_hills = "h", windswept_forest = "h",
	old_growth_birch_forest = "b", old_growth_pine_taiga = "t", old_growth_spruce_taiga = "t", mushroom_fields = "&", dripstone_caves = "?", lush_caves = "?", deep_dark = "?",
}
local counts = {}
local t0 = os.clock()
for row = 0, 47 do
	local line = {}
	for col = 0, 95 do
		local x, z = (col - 48) * 32, (row - 24) * 32
		local id = bs:getBiome(x, 64, z)
		local name = reg.names[id]
		counts[name] = (counts[name] or 0) + 1
		table.insert(line, sym[name] or "#")
	end
	print(table.concat(line))
end
print(string.format("%.1f ms for %d lookups", (os.clock() - t0) * 1000, 96 * 48))
local list = {}
for k, v in counts do table.insert(list, {k, v}) end
table.sort(list, function(a, b) return a[2] > b[2] end)
local parts = {}
for i = 1, math.min(#list, 14) do table.insert(parts, list[i][1] .. "=" .. list[i][2]) end
print(table.concat(parts, "  "))
print("origin biome:", reg.names[bs:getBiome(0, 64, 0)])
