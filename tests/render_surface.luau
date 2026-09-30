-- Dumps top block / floor block / biome per 2x2 columns for an NxN chunk region (for tools/render_surface.py)
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY
local N, OX, OZ = 24, 0, 0
local gen = ChunkGenerator.new(12345)
local out = {}
local t0 = os.clock()
for cz = OZ - N // 2, OZ + N // 2 - 1 do
	for cx = OX - N // 2, OX + N // 2 - 1 do
		local chunk = gen:generate(cx, cz)
		for x = 0, 15, 2 do
			for z = 0, 15, 2 do
				local col = x * 16 + z
				local top = chunk.topY[col + 1]
				local floor = chunk.floorY[col + 1]
				local b = buffer.readu8(chunk.blocks, col * H + (top - MINY))
				local fb = buffer.readu8(chunk.blocks, col * H + (floor - MINY))
				table.insert(out, string.format("%d %d %d %d %d %d %s", cx * 16 + x, cz * 16 + z, top, floor, b, fb, gen.registry.names[chunk.biomeTop[col + 1]]))
			end
		end
	end
end
print(string.format("# %.1fs", os.clock() - t0))
print(table.concat(out, "\n"))
