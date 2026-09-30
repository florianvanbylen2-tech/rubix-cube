local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY

local t0 = os.clock()
local gen = ChunkGenerator.new(12345)
print(string.format("world init %.0f ms", (os.clock() - t0) * 1000))
local sym = {}
local function g(name, ch) sym[Blocks.ids[name]] = ch end
g("air", " ") g("stone", "#") g("water", "~") g("lava", "L") g("deepslate", "D") g("bedrock", "B") g("grass_block", "g") g("dirt", "d")
g("sand", "s") g("sandstone", "S") g("gravel", "r") g("snow_block", "W") g("ice", "i") g("packed_ice", "I") g("terracotta", "t")
g("orange_terracotta", "o") g("red_sand", "R") g("red_sandstone", "Q") g("mud", "m") g("clay", "c") g("podzol", "p") g("coarse_dirt", "e")
g("granite", "n") g("tuff", "u") g("mycelium", "y") g("powder_snow", "w") g("calcite", "k") g("white_terracotta", "T") g("yellow_terracotta", "Y") g("brown_terracotta", "b") g("red_terracotta", "e") g("light_gray_terracotta", "l") g("andesite", "a") g("diorite", "f")

local function slice(chunk, z, y0, y1, step)
	for y = y1, y0, -step do
		local line = {}
		for x = 0, 15 do
			local b = buffer.readu8(chunk.blocks, (x * 16 + z) * H + (y - MINY))
			table.insert(line, sym[b] or "?")
		end
		print(string.format("%4d %s", y, table.concat(line)))
	end
end

local counts = {}
for _, c in { { 5, -3 }, { 40, 40 }, { -30, 12 }, { 0, 0 } } do
	t0 = os.clock()
	local chunk = gen:generateSurface(c[1], c[2])
	local dt = os.clock() - t0
	local top = -1e9
	for i = 1, 256 do top = math.max(top, chunk.topY[i]) end
	local biome = gen.registry.names[chunk.biomeTop[1]]
	print(string.format("chunk (%d,%d) %.0f ms, biome %s, top y %d", c[1], c[2], dt * 1000, biome, top))
	slice(chunk, 8, top - 8, top + 1, 1)
end
-- bottom layers
local chunk = gen:generateSurface(5, -3)
print("bottom / deepslate transition:")
slice(chunk, 3, MINY, MINY + 9, 1)
slice(chunk, 3, -2, 10, 1)
