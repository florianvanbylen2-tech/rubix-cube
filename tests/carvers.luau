local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY

local gen = ChunkGenerator.new(12345)
local sym = {}
local function g(name, ch) sym[Blocks.ids[name]] = ch end
g("air", " ") g("stone", "#") g("water", "~") g("lava", "L") g("deepslate", "D") g("bedrock", "B") g("grass_block", "g") g("dirt", "d") g("sand", "s") g("gravel", "r") g("granite", "n") g("tuff", "u") g("sandstone", "S") g("snow_block", "W")

-- count carved (air) voxels below the surface with and without carvers, for a few chunks
local t0 = os.clock()
for _, c in { { 5, -3 }, { -30, 12 }, { 40, 40 } } do
	local base = gen:generateSurface(c[1], c[2])
	local t1 = os.clock()
	local carved = gen:generateCarved(c[1], c[2])
	local dt = os.clock() - t1
	local function count(chunk)
		local air = 0
		for col = 0, 255 do
			local top = chunk.topY[col + 1]
			for y = MINY, top - 3 do
				local b = buffer.readu8(chunk.blocks, col * H + (y - MINY))
				if b == Blocks.AIR then air += 1 end
			end
		end
		return air
	end
	print(string.format("chunk (%d,%d): underground air voxels: noise-only %d -> with carvers %d   (carver stage ~%.0f ms incl. regeneration)", c[1], c[2], count(base), count(carved), dt * 1000))
end

-- a vertical slice through a heavily carved region
local chunk = gen:generateCarved(5, -3)
for z = 0, 15, 5 do
	print("slice z=" .. z)
	for y = 90, 20, -2 do
		local line = {}
		for x = 0, 15 do
			table.insert(line, sym[buffer.readu8(chunk.blocks, (x * 16 + z) * H + (y - MINY))] or "?")
		end
		print(string.format("%4d %s", y, table.concat(line)))
	end
	break
end
