--!strict
-- Examples of everything you can add or change. Copy what you need into a server Script that runs BEFORE
-- TerrainGenerator.Start(); this module only shows the calls (call it with the TerrainGenerator module):
--
--     require(TerrainGenerator.Examples.CustomThings)(TerrainGenerator)

return function(TerrainGenerator: any)
	local Config = TerrainGenerator.Config

	-- ---- where the default things spawn (1 = Minecraft's own density) ----
	Config.Trees["Oak Tree"].Biomes = { "plains", "forest", "meadow" } -- oaks only in these biomes
	Config.Trees["Birch Tree"].Rate = 0.5 -- half as many birches
	Config.Trees["Dark Oak Tree"].BiomeRate = { dark_forest = 2 } -- twice as many in dark forests
	Config.Trees["Cherry Tree"].Extra = { plains = 0.3 } -- also ~0.3 per chunk in plains, where Minecraft has none
	Config.Ores["Diamond Ore"].Rate = 0.5
	Config.Ores["Coal Ore"].BiomeRate = { desert = 0 } -- no coal under deserts
	Config.Spawning.BiomeTreeRate.forest = 1.5 -- every tree in forests
	Config.Spawning.BiomeOreRate.mushroom_fields = 0 -- no ores under mushroom islands
	Config.Structures.Village.Biomes = { "plains", "forest" } -- villages in plains or forests
	Config.Structures["Medieval Castle"].Chance = 1 -- a castle in every region that has snowy mountains
	Config.Structures.Well.Enabled = false

	-- ---- new things ----
	TerrainGenerator.RegisterTree({ Name = "Crystal Tree", Biomes = { "meadow", "cherry_grove" }, PerChunk = 3 })
	TerrainGenerator.RegisterOre({ Name = "Mythril Ore", PerChunk = 1.5, MinY = -60, MaxY = 0, Size = 6 })
	TerrainGenerator.RegisterStructure({
		Name = "Desert Pyramid",
		Spacing = 32, Separation = 8, Salt = 14357617, -- Minecraft's own numbers for pyramids
		Biomes = { "desert" },
		MaxSlope = 4,
	})

	-- ---- biomes: add, remove ----
	TerrainGenerator.RegisterBiome({
		id = "crystal_meadow", displayName = "Crystal Meadow", base = "meadow",
		climate = { temperature = { -0.3, 0.6 }, continentalness = { 0.03, 1.0 } },
		region = { scale = 700, threshold = 0.45 }, priority = 2,
		surface = { top = "crystal_stone", filler = "crystal_stone", fillerDepth = 2 },
	})
	TerrainGenerator.RemoveBiome("badlands") -- its territory goes to the nearest other biome
	TerrainGenerator.RemoveBiome("eroded_badlands")

	-- ---- Terrain materials ----
	TerrainGenerator.RegisterBlock({ Name = "crystal_stone", Material = "Glacier", Color = Color3.fromRGB(120, 200, 255) })
	Config.Materials.Blocks.grass_block = "LeafyGrass" -- show grass blocks with the darker grass everywhere
	Config.Materials.Colors.Sand = Color3.fromRGB(230, 215, 150)
	-- textures: put MaterialVariants in MaterialService, then name them here
	-- Config.Materials.Variants.Grass = "MyGrassVariant"

	-- ---- what happens with the things: your code goes here (or edit Placement.luau) ----
	TerrainGenerator.SetPlacementHandler(function(thingType: string, location: Vector3, info: any)
		-- thingType: "Oak Tree", "Iron Ore", "Village", ...; info.Kind is "Tree", "Ore" or "Structure"
		-- build it at `location` (studs; trees / structures: ground point, ores: centre of the vein)
		if info.Kind == "Structure" then
			print("place", thingType, "at", location, "rotation", info.Rotation, "seed", info.Seed)
		end
	end)
	TerrainGenerator.SetRemovalHandler(function(chunkX: number, chunkZ: number)
		-- the chunk unloaded: remove what you placed for it (it will be placed again if the chunk loads again)
	end)
end
