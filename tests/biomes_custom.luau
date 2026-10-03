-- Biome removal (Config.Biomes.Disabled) and the custom block palette.
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end

local plain = ChunkGenerator.new(12345, { things = false })
-- find a desert and a plains column in the default world
local desertAt, plainsAt
for x = -4000, 4000, 100 do
	for z = -4000, 4000, 100 do
		local id = plain.biomes:getNoiseBiome(x // 4, 16, z // 4)
		local name = plain.registry.names[id]
		if name == "desert" and not desertAt then desertAt = { x, z } end
		if name == "plains" and not plainsAt then plainsAt = { x, z } end
	end
end
check(desertAt and plainsAt, "scan found no desert / plains")

local noDesert = ChunkGenerator.new(12345, { things = false, disabledBiomes = { "desert", "minecraft:badlands" } })
local counts, total = {}, 0
for x = -4000, 4000, 100 do
	for z = -4000, 4000, 100 do
		local name = noDesert.registry.names[noDesert.biomes:getNoiseBiome(x // 4, 16, z // 4)]
		counts[name] = (counts[name] or 0) + 1
		total += 1
	end
end
check(counts.desert == nil and counts.badlands == nil, "disabled biomes still generated")
check(noDesert.registry.names[noDesert.biomes:getNoiseBiome(desertAt[1] // 4, 16, desertAt[2] // 4)] ~= "desert", "desert location not reassigned")
check(noDesert.registry.names[noDesert.biomes:getNoiseBiome(plainsAt[1] // 4, 16, plainsAt[2] // 4)] == "plains", "other biomes must be unchanged")
print("biome removal: desert/badlands gone, nearest biomes took over (" .. total .. " samples); desert spot is now",
	noDesert.registry.names[noDesert.biomes:getNoiseBiome(desertAt[1] // 4, 16, desertAt[2] // 4)])
check(not pcall(ChunkGenerator.new, 12345, { things = false, disabledBiomes = { "not_a_biome" } }), "unknown disabled biome accepted")

-- the terrain shape itself does not depend on the biome list
local a = plain:generateNoise(4, 4)
local b = noDesert:generateNoise(4, 4)
check(buffer.tostring(a.blocks) == buffer.tostring(b.blocks), "noise-stage terrain must not depend on disabled biomes")

-- custom blocks and material remapping
Blocks.configure({
	materials = { grass_block = "LeafyGrass", stone = "Slate" },
	custom = { { name = "crystal_stone", material = "Glacier", kind = "solid" } },
	colors = { Glacier = { 120, 200, 255 } },
})
local id = Blocks.id("crystal_stone")
check(id >= 37 and Blocks.materials[id] == "Glacier" and Blocks.isSolid(id) and not Blocks.isFluid(id), "custom block registration")
check(Blocks.materials[Blocks.ids.grass_block] == "LeafyGrass" and Blocks.materials[Blocks.STONE] == "Slate", "material remap")
check(Blocks.colors.Glacier[3] == 255, "colour override")
Blocks.configure({ custom = { { name = "crystal_stone", material = "Glacier" } } }) -- idempotent
check(Blocks.id("crystal_stone") == id, "re-registering must keep the id")
check(not pcall(Blocks.configure, { materials = { nope = "Rock" } }), "unknown block remap accepted")

-- a custom biome can use the new block in its surface
local magic = ChunkGenerator.new(12345, { things = false, customBiomes = { { id = "crystal_land", base = "plains", climate = { temperature = { -1, 1 } }, region = { scale = 300, threshold = -2 }, surface = { top = "crystal_stone", filler = "crystal_stone", fillerDepth = 2 } } } })
local chunk = magic:generateSurface(5, 5)
local seen = false
for i = 0, buffer.len(chunk.blocks) - 1 do if buffer.readu8(chunk.blocks, i) == id then seen = true break end end
check(seen, "custom block never appeared in a custom biome surface")
print("custom blocks: registered, remapped, and used by a custom biome surface")
print("biomes_custom OK")
