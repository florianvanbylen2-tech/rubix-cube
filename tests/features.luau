local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local gen = ChunkGenerator.new(12345)
local totals = {}
local t0 = os.clock()
local N = 0
for cz = -2, 3 do
	for cx = -2, 3 do
		local c0 = os.clock()
		local chunk = gen:generate(cx * 4 + 5, cz * 4 - 3)
		N += 1
		local trees, ores, byTier, species = 0, 0, {}, {}
		for _, c in chunk.collectables do
			if c.kind == "Tree" then trees += 1; species[c.species] = (species[c.species] or 0) + 1
			else ores += 1; byTier[c.tier] = (byTier[c.tier] or 0) + 1 end
		end
		local sp = {}
		for k, v in species do table.insert(sp, k .. ":" .. v) end
		local tiers = {}
		for t = 1, 5 do table.insert(tiers, tostring(byTier[t] or 0)) end
		if N <= 12 then
			print(string.format("chunk (%d,%d) %3.0f ms  biome=%-22s trees=%-3d ores(t1..t5)=%s  %s", chunk.cx, chunk.cz, (os.clock() - c0) * 1000, gen.registry.names[chunk.biomeTop[1]], trees, table.concat(tiers, "/"), table.concat(sp, " ")))
		end
		totals.trees = (totals.trees or 0) + trees
		for t = 1, 5 do totals["ore" .. t] = (totals["ore" .. t] or 0) + (byTier[t] or 0) end
	end
end
print(string.format("36 chunks in %.1fs; trees/chunk %.1f; ore parts/chunk by tier: %.1f %.1f %.1f %.1f %.1f", os.clock() - t0, totals.trees / 36,
	totals.ore1 / 36, totals.ore2 / 36, totals.ore3 / 36, totals.ore4 / 36, totals.ore5 / 36))
