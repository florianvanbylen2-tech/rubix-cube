local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY

local t0 = os.clock()
local gen = ChunkGenerator.new(12345)
print(string.format("world init: %.1f ms", (os.clock() - t0) * 1000))

local glyph = { [Blocks.AIR] = " ", [Blocks.STONE] = "#", [Blocks.WATER] = "~", [Blocks.LAVA] = "L", [Blocks.DEEPSLATE] = "D" }
local function slice(chunk, z, y0, y1, step)
	for y = y1, y0, -step do
		local line = {}
		for x = 0, 15 do
			local b = buffer.readu8(chunk.blocks, (x * 16 + z) * H + (y - MINY))
			table.insert(line, glyph[b] or "?")
		end
		print(string.format("%4d %s", y, table.concat(line)))
	end
end

for _, c in { { 0, 0 }, { 5, -3 }, { 40, 40 } } do
	t0 = os.clock()
	local chunk = gen:generateNoise(c[1], c[2])
	local dt = os.clock() - t0
	local mn, mx = math.huge, -math.huge
	local water, air, solid = 0, 0, 0
	for i = 1, 256 do mn = math.min(mn, chunk.topY[i]); mx = math.max(mx, chunk.topY[i]) end
	print(string.format("chunk (%d,%d): %.0f ms   surface y %d..%d   veinOres=%d", c[1], c[2], dt * 1000, mn, mx, #chunk.veinOres))
end
local chunk = gen:generateNoise(0, 0)
print("slice x=0..15 at z=8, y from top of terrain down:")
local top = 0
for i = 1, 256 do top = math.max(top, chunk.topY[i]) end
slice(chunk, 8, math.max(MINY, top - 60), top + 4, 2)
