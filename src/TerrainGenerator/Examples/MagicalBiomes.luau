--!strict
-- Example custom ("magical") biomes for TerrainGenerator.RegisterBiome. They are plain data.
--
-- How a custom biome is placed: at every 4x4x4-block cell the generator first checks the custom biomes (highest
-- priority first). A biome applies when the vanilla climate values at that cell fall inside its `climate` ranges
-- AND its optional `region` noise is above its threshold; otherwise the vanilla biome is used. `base` names the
-- vanilla biome it inherits surface rules, carvers and features from. `surface` re-skins the top soil layers,
-- `trees` / `ores` add extra things (placed through placeThing under their title-cased name).
--
-- Climate values are the -1..1 numbers Minecraft uses (temperature, humidity, continentalness, erosion,
-- weirdness, depth). GetClimateAt(position) shows the values at any spot, handy for tuning.

return {
	{
		id = "crystal_meadow",
		displayName = "Crystal Meadow",
		base = "meadow",
		climate = { temperature = { -0.3, 0.6 }, continentalness = { 0.03, 1.0 }, erosion = { -0.4, 0.5 } },
		region = { scale = 700, threshold = 0.45 },
		priority = 2,
		surface = { top = "calcite", filler = "calcite", fillerDepth = 2 },
		trees = { { species = "crystal_tree", perChunk = 2 } },
		ores = { { name = "mana_crystal", perChunk = 1.5, minY = -16, maxY = 60, size = 6 } },
	},
	{
		id = "enchanted_marsh",
		displayName = "Enchanted Marsh",
		base = "swamp",
		climate = { temperature = { 0.0, 0.8 }, humidity = { 0.2, 1.0 }, continentalness = { -0.1, 0.5 } },
		region = { scale = 600, threshold = 0.5 },
		priority = 1,
		surface = { top = "mycelium", filler = "mud", fillerDepth = 3 },
		trees = { { species = "glow_willow", perChunk = 3 } },
	},
	{
		id = "ashen_barrens",
		displayName = "Ashen Barrens",
		base = "desert",
		climate = { temperature = { 0.3, 1.0 }, humidity = { -1.0, 0.0 } },
		region = { scale = 900, threshold = 0.55 },
		priority = 1,
		surface = { top = "gravel", filler = "tuff", fillerDepth = 4 },
		ores = { { name = "ember_shard", perChunk = 0.7, minY = -32, maxY = 40, size = 4 } },
	},
}
