local ChunkGenerator = require(TG.World.ChunkGenerator)
local gen = ChunkGenerator.new(12345)
local N, t0 = 0, os.clock()
local byName: { [string]: number } = {}
local kinds = { Tree = 0, Ore = 0, Structure = 0 }
for cz = -2, 3 do
	for cx = -2, 3 do
		local c0 = os.clock()
		local chunk = gen:generate(cx * 4 + 5, cz * 4 - 3)
		N += 1
		local names = {}
		for _, p in chunk.placements do
			kinds[p.kind] += 1
			byName[p.name] = (byName[p.name] or 0) + 1
			names[p.name] = (names[p.name] or 0) + 1
			assert(p.biome and p.x and p.y and p.z and p.seed, "incomplete placement record")
		end
		if N <= 6 then
			local list = {}
			for k, v in names do table.insert(list, k .. ":" .. v) end
			table.sort(list)
			print(string.format("chunk (%d,%d) %3.0f ms  biome=%-18s %s", chunk.cx, chunk.cz, (os.clock() - c0) * 1000, gen.registry.names[chunk.biomeTop[1]], table.concat(list, " ")))
		end
	end
end
local list = {}
for k, v in byName do table.insert(list, string.format("%s %.2f", k, v / N)) end
table.sort(list)
print(string.format("%d chunks in %.1fs; trees/chunk %.1f, ores/chunk %.1f, structures %d", N, os.clock() - t0, kinds.Tree / N, kinds.Ore / N, kinds.Structure))
print("per chunk:", table.concat(list, " | "))
