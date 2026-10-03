-- Spawn rules: Enabled / Biomes / Rate / BiomeRate / Extra / global and per-biome rates, custom trees and ores.
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Config = require(TG.Config)
local Structures = require(TG.World.Structures)

local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end
local function deep(t) if type(t) ~= "table" then return t end local c = {} for k, v in t do c[k] = deep(v) end return c end

-- 16 chunks of varied biomes
local spots = {}
for i = 0, 15 do table.insert(spots, { 5 + i * 3, -11 + (i % 4) * 5 }) end

local function options(mut)
	local o = { things = true, spawning = deep(Config.Spawning), trees = deep(Config.Trees), ores = deep(Config.Ores), structures = Structures.normalizeAll(deep(Config.Structures)) }
	if mut then mut(o) end
	return o
end

local function tally(gen)
	local byName, byBiome = {}, {}
	for _, s in spots do
		local chunk = gen:generate(s[1], s[2])
		for _, p in chunk.placements do
			byName[p.name] = (byName[p.name] or 0) + 1
			byBiome[p.name .. "@" .. p.biome] = (byBiome[p.name .. "@" .. p.biome] or 0) + 1
		end
	end
	return byName, byBiome
end

local base, baseBiome = tally(ChunkGenerator.new(12345, options()))
check((base["Oak Tree"] or 0) + (base["Birch Tree"] or 0) + (base["Dark Oak Tree"] or 0) > 5, "default world should have trees")
check((base["Iron Ore"] or 0) > 20 and (base["Coal Ore"] or 0) > 20, "default world should have ores")
local again = tally(ChunkGenerator.new(12345, options()))
for k, v in base do check(again[k] == v, "not deterministic: " .. k) end
print("baseline: oak", base["Oak Tree"], "birch", base["Birch Tree"], "iron", base["Iron Ore"], "coal", base["Coal Ore"], "diamond", base["Diamond Ore"])

-- Enabled = false
local off = tally(ChunkGenerator.new(12345, options(function(o) o.trees["Oak Tree"].Enabled = false; o.ores["Iron Ore"].Enabled = false end)))
check(off["Oak Tree"] == nil and off["Iron Ore"] == nil, "disabled things still placed")
check(off["Coal Ore"] == base["Coal Ore"] and off["Birch Tree"] == base["Birch Tree"], "disabling one thing must not change the others")

-- Biomes restriction: oak only in plains
local oakBiomes = select(2, tally(ChunkGenerator.new(12345, options(function(o) o.trees["Oak Tree"].Biomes = { "plains" } end))))
for key, n in oakBiomes do
	if string.find(key, "^Oak Tree@") then check(key == "Oak Tree@plains", "oak outside plains: " .. key) end
end
local oakInPlains = baseBiome["Oak Tree@plains"] or 0
check((oakBiomes["Oak Tree@plains"] or 0) == oakInPlains, "plains oaks must be unchanged by the restriction")

-- Rate: 0 -> none, 0.5 -> about half, 3 -> about triple
local function rate(r) return tally(ChunkGenerator.new(12345, options(function(o) o.ores["Iron Ore"].Rate = r end)))["Iron Ore"] or 0 end
check(rate(0) == 0, "Rate 0")
local half, triple = rate(0.5), rate(3)
check(half > base["Iron Ore"] * 0.35 and half < base["Iron Ore"] * 0.65, "Rate 0.5 gave " .. half .. " of " .. base["Iron Ore"])
check(triple > base["Iron Ore"] * 2.0, "Rate 3 gave " .. triple .. " of " .. base["Iron Ore"])
print("rates: 0 ->", rate(0), " 0.5 ->", half, " 1 ->", base["Iron Ore"], " 3 ->", triple)

-- global and per-biome rates
local noTrees = tally(ChunkGenerator.new(12345, options(function(o) o.spawning.TreeRate = 0 end)))
for name in noTrees do check(not string.find(name, "Tree") and not string.find(name, "Mushroom") and not string.find(name, "Bush"), "TreeRate 0 still placed " .. name) end
check(noTrees["Iron Ore"] == base["Iron Ore"], "TreeRate must not touch ores")
local noForest = select(2, tally(ChunkGenerator.new(12345, options(function(o) o.spawning.BiomeOreRate.dark_forest = 0; o.spawning.BiomeTreeRate.dark_forest = 0 end))))
for key in noForest do check(not string.find(key, "@dark_forest$") or string.find(key, "Structure") ~= nil, "dark_forest still has " .. key) end
check(next(baseBiome) ~= nil, "baseline biome tally")

-- per-thing per-biome rate
local boosted = select(2, tally(ChunkGenerator.new(12345, options(function(o) o.trees["Dark Oak Tree"].BiomeRate = { dark_forest = 0 } end))))
check(boosted["Dark Oak Tree@dark_forest"] == nil and (baseBiome["Dark Oak Tree@dark_forest"] or 0) > 0, "BiomeRate 0 for dark oaks in dark forests")

-- Extra: spawn oaks in a biome where Minecraft has none (pick a land biome of the sample without oaks)
local landBiome
do
	local g = ChunkGenerator.new(12345, options())
	for _, sp in spots do
		local chunk = g:generate(sp[1], sp[2])
		for col = 1, 256, 7 do
			local b = g.registry.names[chunk.biomeTop[col]]
			if not string.find(b, "ocean") and not string.find(b, "river") and not baseBiome["Oak Tree@" .. b] and chunk.topY[col] == chunk.floorY[col] and chunk.floorY[col] > 63 then landBiome = b end
		end
	end
end
check(landBiome ~= nil, "no suitable land biome in the sample")
local extra = select(2, tally(ChunkGenerator.new(12345, options(function(o) o.trees["Oak Tree"].Extra = { [landBiome] = 6 } end))))
check((extra["Oak Tree@" .. landBiome] or 0) > 0, "Extra did not add oaks to " .. landBiome)
print("extra: oaks added in " .. landBiome .. ":", extra["Oak Tree@" .. landBiome])

-- custom things
local custom = options(function(o)
	o.trees["Crystal Tree"] = { Enabled = true, Custom = true, PerChunk = 3, Biomes = { "dark_forest", "grove" }, Rate = 1, BiomeRate = {}, Extra = {} }
	o.ores["Mythril Ore"] = { Enabled = true, Custom = true, PerChunk = 2, MinY = -40, MaxY = 30, Size = 5, Rate = 1, BiomeRate = {}, Extra = {} }
end)
local gen = ChunkGenerator.new(12345, custom)
local sawTree, sawOre, maxY, minY = 0, 0, -1e9, 1e9
for _, s in spots do
	local chunk = gen:generate(s[1], s[2])
	for _, p in chunk.placements do
		if p.name == "Crystal Tree" then sawTree += 1; check(p.biome == "dark_forest" or p.biome == "grove", "custom tree outside its biomes: " .. p.biome) end
		if p.name == "Mythril Ore" then sawOre += 1; maxY = math.max(maxY, p.y); minY = math.min(minY, p.y) end
	end
end
check(sawTree > 0 and sawOre > 0, "custom tree/ore never placed")
check(maxY <= 31 and minY >= -40, "custom ore outside its height range: " .. minY .. ".." .. maxY)
print("custom: tree", sawTree, "ore", sawOre, "ore heights", minY, maxY)

-- things = false (clients): no placements, and fewer records computed
local cheap = ChunkGenerator.new(12345, { things = false })
local c = cheap:generate(5, -11)
check(c.placements == nil and #c.collectables == 0, "clients must not compute things")
-- the terrain is identical with and without things
local full = ChunkGenerator.new(12345, options()):generate(5, -11)
check(buffer.tostring(c.blocks) == buffer.tostring(full.blocks), "terrain differs between server and client roles")
print("placements OK")
