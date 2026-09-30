-- Dumps a heightmap + biome grid for an NxN chunk region as text: "cx cz topY floorY biomeId" per column sample.
local ChunkGenerator = require(TG.World.ChunkGenerator)
local N = 24
local gen = ChunkGenerator.new(12345)
local out = {}
local t0 = os.clock()
for cz = -N // 2, N // 2 - 1 do
	for cx = -N // 2, N // 2 - 1 do
		local chunk = gen:generateNoise(cx, cz)
		-- sample the 4 corners' quart cells (4x4 samples per chunk)
		for sz = 0, 3 do
			for sx = 0, 3 do
				local i = (sx * 4) * 16 + (sz * 4) + 1
				table.insert(out, string.format("%d %d %d %d", cx * 4 + sx, cz * 4 + sz, chunk.topY[i], chunk.floorY[i]))
			end
		end
	end
end
print(string.format("# %.1fs for %d chunks", os.clock() - t0, N * N))
print(table.concat(out, "\n"))
