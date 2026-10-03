--!strict
-- Turns the generator's raw decoration records (every tree / ore vein the vanilla features produced, structure start
-- points, custom-biome extras) into the final list of "things to place" for one chunk, applying the spawn rules from
-- Config.Spawning / Config.Trees / Config.Ores / Config.Structures:
--
--   Enabled      false = never place this thing
--   Biomes       list of biome names; the thing only spawns in these (nil = wherever Minecraft spawns it)
--   Rate         multiplier on Minecraft's frequency (1 = vanilla, 0.5 = half as many, 2 = twice as many)
--   BiomeRate    { biome = multiplier } extra per-biome multiplier
--   Extra        { biome = perChunk } additional attempts per chunk in biomes where Minecraft would not spawn it
--   (custom things registered with RegisterTree / RegisterOre use Biomes + PerChunk instead, see init.luau)
--
-- Rate < 1 thins the vanilla placements, Rate > 1 adds copies a few blocks from the original. All decisions use a
-- seeded random per chunk, so the result is stable.

local Blocks = require(script.Parent.Blocks)
local Settings = require(script.Parent.Parent.Data.Settings)
local ThingNames = require(script.Parent.ThingNames)
local Structures = require(script.Parent.Structures)

local floor, min, max = math.floor, math.min, math.max
local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local SEA_LEVEL = Settings.seaLevel

export type Rule = {
	enabled: boolean,
	biomes: { [string]: boolean }?,
	rate: number,
	biomeRate: { [string]: number },
	extra: { [string]: number },
	custom: boolean,
	perChunk: number,
	minY: number,
	maxY: number,
	size: number,
	name: string,
}

local Placements = {}
Placements.__index = Placements

local function compileRules(map: { [string]: any }?): { [string]: Rule }
	local out: { [string]: Rule } = {}
	for name, r in map or {} do
		local biomes: { [string]: boolean }? = nil
		if r.Biomes then
			biomes = {}
			for _, b in r.Biomes do
				(biomes :: any)[(string.gsub(tostring(b), "^minecraft:", ""))] = true
			end
		end
		local extra: { [string]: number } = {}
		for b, v in r.Extra or {} do
			extra[(string.gsub(tostring(b), "^minecraft:", ""))] = v
		end
		local biomeRate: { [string]: number } = {}
		for b, v in r.BiomeRate or {} do
			biomeRate[(string.gsub(tostring(b), "^minecraft:", ""))] = v
		end
		out[name] = {
			enabled = r.Enabled ~= false,
			biomes = biomes,
			rate = r.Rate or 1,
			biomeRate = biomeRate,
			extra = extra,
			custom = r.Custom == true,
			perChunk = r.PerChunk or 1,
			minY = r.MinY or MIN_Y + 8,
			maxY = r.MaxY or 64,
			size = r.Size or 4,
			name = name,
		}
	end
	return out
end

-- options: { spawning = {...}, trees = {...}, ores = {...}, structures = {normalized rules} }
function Placements.new(gen: any, options: any): any
	local o = options or {}
	local sp = o.spawning or {}
	local names: { string } = {}
	for name in o.trees or {} do
		table.insert(names, name)
	end
	local self = setmetatable({
		gen = gen,
		treeRate = sp.TreeRate or 1,
		oreRate = sp.OreRate or 1,
		biomeTreeRate = sp.BiomeTreeRate or {},
		biomeOreRate = sp.BiomeOreRate or {},
		treeRules = compileRules(o.trees),
		oreRules = compileRules(o.ores),
		structures = (o.structures and #o.structures > 0) and Structures.new(gen, o.structures) or nil,
		factory = gen.rs.random:fromHashOf("terraingenerator:spawn"):forkPositional(),
	}, Placements)
	return self
end

local function recordSeed(x: number, y: number, z: number): number
	return bit32.bxor(floor(x) * 73856093, floor(y) * 19349663, floor(z) * 83492791) % 2147483647
end

local function biomeNameAt(chunk: any, names: { string }, lx: number, lz: number): string
	return names[chunk.biomeTop[lx * 16 + lz + 1]]
end

-- Number of copies for a (fractional) rate.
local function copies(rate: number, rng: any): number
	if rate <= 0 then
		return 0
	end
	local n = floor(rate)
	if rng:nextDouble() < rate - n then
		n += 1
	end
	return min(n, 16)
end

local function isRock(id: number): boolean
	return id == Blocks.STONE or id == Blocks.DEEPSLATE or (id >= Blocks.ids.granite and id <= Blocks.ids.tuff)
end

-- A copy of `rec` a few blocks away; nil when no valid spot was found. `inside` = a record kind check.
local function nearbyCopy(chunk: any, names: { string }, rec: any, rng: any): any?
	local minX, minZ = chunk.cx * 16, chunk.cz * 16
	for _ = 1, 4 do
		local dx, dz = rng:nextInt(7) - 3, rng:nextInt(7) - 3
		local lx, lz = floor(rec.x) - minX + dx, floor(rec.z) - minZ + dz
		if (dx ~= 0 or dz ~= 0) and lx >= 0 and lx <= 15 and lz >= 0 and lz <= 15 then
			local col = lx * 16 + lz + 1
			if rec.kind == "Tree" then
				local ground = chunk.floorY[col]
				if chunk.topY[col] == ground and ground >= SEA_LEVEL - 1 and biomeNameAt(chunk, names, lx, lz) == rec.biome then
					local c = table.clone(rec)
					c.x, c.z, c.y = minX + lx, minZ + lz, ground + 1
					c.seed = recordSeed(c.x, c.y, c.z)
					return c
				end
			else
				local y = floor(rec.y) + rng:nextInt(5) - 2
				if y >= MIN_Y and y < MIN_Y + HEIGHT and isRock(buffer.readu8(chunk.blocks, (lx * 16 + lz) * HEIGHT + (y - MIN_Y))) then
					local c = table.clone(rec)
					c.x, c.y, c.z = minX + lx + 0.5, y + 0.5, minZ + lz + 0.5
					c.seed = recordSeed(c.x, c.y, c.z)
					return c
				end
			end
		end
	end
	return nil
end

-- Applies a rule to one vanilla record. Returns the records to keep (0..n).
local function applyRule(self: any, chunk: any, rec: any, rule: Rule?, global: number, biomeGlobal: { [string]: number }, rng: any, out: { any })
	local biome = rec.biome
	if rule then
		if not rule.enabled then
			return
		end
		if rule.biomes and not rule.biomes[biome] then
			return
		end
	end
	local rate = global * (biomeGlobal[biome] or 1)
	if rule then
		rate *= rule.rate * (rule.biomeRate[biome] or 1)
	end
	if rate == 1 then
		table.insert(out, rec)
		return
	end
	local n = copies(rate, rng)
	if n >= 1 then
		table.insert(out, rec)
		for _ = 2, n do
			local c = nearbyCopy(chunk, self.gen.registry.names, rec, rng)
			if c then
				table.insert(out, c)
			end
		end
	end
end

-- Extra / custom spawns: `attempts` random columns of the chunk
local function extraSpawns(self: any, chunk: any, kind: string, rule: Rule, biome: string?, perChunk: number, rng: any, out: { any })
	local names = self.gen.registry.names
	local biomeGlobal = kind == "Tree" and self.biomeTreeRate or self.biomeOreRate
	local global = kind == "Tree" and self.treeRate or self.oreRate
	local minX, minZ = chunk.cx * 16, chunk.cz * 16
	local n = copies(perChunk * global * rule.rate, rng)
	for _ = 1, n do
		local lx, lz = rng:nextInt(16), rng:nextInt(16)
		local col = lx * 16 + lz + 1
		local here = biomeNameAt(chunk, names, lx, lz)
		if (biome == nil or here == biome) and (biomeGlobal[here] or 1) * (rule.biomeRate[here] or 1) > 0 and (rule.biomes == nil or rule.biomes[here]) then
			local ground = chunk.floorY[col]
			if kind == "Tree" then
				if chunk.topY[col] == ground and ground >= SEA_LEVEL - 1 then
					local x, y, z = minX + lx, ground + 1, minZ + lz
					table.insert(out, { kind = "Tree", name = rule.name, x = x, y = y, z = z, biome = here, seed = recordSeed(x, y, z), height = 5 })
				end
			else
				local hi = min(rule.maxY, ground - 2)
				if hi >= rule.minY then
					local y = rng:nextInt(hi - rule.minY + 1) + rule.minY
					if isRock(buffer.readu8(chunk.blocks, (lx * 16 + lz) * HEIGHT + (y - MIN_Y))) then
						local x, z = minX + lx + 0.5, minZ + lz + 0.5
						table.insert(out, { kind = "Ore", name = rule.name, x = x, y = y + 0.5, z = z, biome = here, seed = recordSeed(x, y, z), size = rule.size })
					end
				end
			end
		end
	end
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- chunk.collectables (raw records from Features) + structures -> chunk.placements
function Placements.build(self: any, chunk: any)
	local names = self.gen.registry.names
	local rng = self.factory:at(chunk.cx, 0, chunk.cz)
	local out: { any } = {}
	local minX, minZ = chunk.cx * 16, chunk.cz * 16

	for _, c in chunk.collectables do
		if c.kind == "Tree" then
			local name = ThingNames.tree(c.species)
			local rec = {
				kind = "Tree", name = name, x = c.x, y = c.y, z = c.z, biome = c.biome, seed = recordSeed(c.x, c.y, c.z), height = c.height,
			}
			applyRule(self, chunk, rec, self.treeRules[name], self.treeRate, self.biomeTreeRate, rng, out)
		else
			local name = ThingNames.ore(c.ore)
			local lx = max(0, min(15, floor(c.x) - minX))
			local lz = max(0, min(15, floor(c.z) - minZ))
			local id = self.gen.biomes:getBiome(floor(c.x), floor(c.y), floor(c.z))
			local rec = {
				kind = "Ore", name = name, x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, biome = names[id] or biomeNameAt(chunk, names, lx, lz),
				seed = recordSeed(c.x, c.y, c.z), size = c.count,
			}
			applyRule(self, chunk, rec, self.oreRules[name], self.oreRate, self.biomeOreRate, rng, out)
		end
	end

	-- Extra (non-vanilla) spawns and custom trees / ores, in a fixed order
	for _, name in sortedKeys(self.treeRules) do
		local rule = self.treeRules[name]
		if rule.enabled then
			if rule.custom then
				extraSpawns(self, chunk, "Tree", rule, nil, rule.perChunk, rng, out)
			end
			for _, biome in sortedKeys(rule.extra) do
				extraSpawns(self, chunk, "Tree", rule, biome, rule.extra[biome], rng, out)
			end
		end
	end
	for _, name in sortedKeys(self.oreRules) do
		local rule = self.oreRules[name]
		if rule.enabled then
			if rule.custom then
				extraSpawns(self, chunk, "Ore", rule, nil, rule.perChunk, rng, out)
			end
			for _, biome in sortedKeys(rule.extra) do
				extraSpawns(self, chunk, "Ore", rule, biome, rule.extra[biome], rng, out)
			end
		end
	end

	if self.structures then
		for _, s in Structures.place(self.structures, chunk) do
			table.insert(out, s)
		end
	end
	chunk.placements = out
end

return Placements
