--!strict
-- Structure placement: decides WHERE structures (Village, Medieval Castle, ...) start. Pure data in, plain placement
-- records out; what a structure looks like is not implemented here (see Placement.luau).
--
-- Chunk selection is Minecraft's `random_spread` placement, bit for bit: the world is cut into Spacing x Spacing
-- chunk regions; each region gets one potential structure chunk computed with java.util.Random seeded by
--     regionX * 341873128712 + regionZ * 132897987541 + worldSeed + salt
-- (RandomSpreadStructurePlacement.getPotentialStructureChunk). With vanilla's own numbers (Village: spacing 34,
-- separation 8, salt 10387312) the structure chunks are the same as in Minecraft 1.20.1 for the same seed. The
-- biome / land / slope conditions are applied on top and are NOT vanilla's.

local Int64 = require(script.Parent.Parent.Core.Int64)
local JavaRandom = require(script.Parent.Parent.Core.JavaRandom)
local Settings = require(script.Parent.Parent.Data.Settings)

local floor, abs = math.floor, math.abs
local SEA_LEVEL = Settings.seaLevel

local Structures = {}
Structures.__index = Structures

local function biomeList(list: any, what: string): { string }?
	if list == nil then
		return nil
	end
	assert(type(list) == "table", what .. ": Biomes must be a list of biome names")
	local out = {}
	for _, name in list do
		table.insert(out, (string.gsub(tostring(name), "^minecraft:", "")))
	end
	return out
end

-- Validates one rule and returns its plain-data form (safe to send to worker Actors), or nil if it is disabled.
function Structures.normalize(name: string, rule: any): any?
	assert(type(name) == "string" and name ~= "", "structure needs a name")
	assert(type(rule) == "table", name .. ": rule must be a table")
	if rule.Enabled == false then
		return nil
	end
	local spacing = rule.Spacing or 24
	local separation = rule.Separation or floor(spacing / 4)
	assert(type(spacing) == "number" and spacing >= 2 and spacing % 1 == 0, name .. ": Spacing must be a whole number >= 2")
	assert(type(separation) == "number" and separation >= 0 and separation < spacing and separation % 1 == 0, name .. ": Separation must be a whole number below Spacing")
	local placement = rule.Placement or "Land"
	assert(placement == "Land" or placement == "Water" or placement == "Any", name .. ": Placement must be Land, Water or Any")
	local spread = rule.SpreadType or "linear"
	assert(spread == "linear" or spread == "triangular", name .. ": SpreadType must be linear or triangular")
	local salt = rule.Salt
	if salt == nil then
		salt = abs(Int64.javaStringHash(name))
	end
	return {
		Name = name,
		Spacing = spacing,
		Separation = separation,
		Salt = salt,
		SpreadType = spread,
		Chance = math.clamp(rule.Chance or 1, 0, 1),
		Biomes = biomeList(rule.Biomes, name),
		Placement = placement,
		MaxSlope = rule.MaxSlope or 4,
		Rotate = rule.Rotate ~= false,
	}
end

-- Config.Structures (name -> rule) -> sorted list of normalized plain rules.
function Structures.normalizeAll(map: { [string]: any }?): { any }
	local names = {}
	for name in map or {} do
		table.insert(names, name)
	end
	table.sort(names)
	local out = {}
	for _, name in names do
		local d = Structures.normalize(name, (map :: any)[name])
		if d then
			table.insert(out, d)
		end
	end
	return out
end

function Structures.new(gen: any, defs: { any }): any
	local list = {}
	for _, d in defs do
		local def = table.clone(d)
		if d.Biomes then
			local set = {}
			for _, b in d.Biomes do
				set[b] = true
			end
			def.biomeSet = set
		end
		def.factory = gen.rs.random:fromHashOf("terraingenerator:structure/" .. d.Name):forkPositional()
		table.insert(list, def)
	end
	return setmetatable({ defs = list, names = gen.registry.names, seedH = gen.rs.seedH, seedL = gen.rs.seedL, rnd = JavaRandom.new(0, 0) }, Structures)
end

-- RandomSpreadStructurePlacement.getPotentialStructureChunk(seed, chunkX, chunkZ)
function Structures.potentialChunk(self: any, d: any, cx: number, cz: number): (number, number, number, number)
	local spacing = d.Spacing
	local rx, rz = cx // spacing, cz // spacing
	local xh, xl = Int64.fromInt32(rx)
	xh, xl = Int64.mul(xh, xl, 0x4F, 0x9939F508)
	local zh, zl = Int64.fromInt32(rz)
	zh, zl = Int64.mul(zh, zl, 0x1E, 0xF1565BD5)
	local sh, sl = Int64.add(xh, xl, zh, zl)
	sh, sl = Int64.add(sh, sl, self.seedH, self.seedL)
	local th, tl = Int64.fromNumber(d.Salt)
	sh, sl = Int64.add(sh, sl, th, tl)
	local rnd = self.rnd
	rnd:setSeed(sh, sl)
	local bound = spacing - d.Separation
	local a, b
	if d.SpreadType == "triangular" then
		a = (rnd:nextInt(bound) + rnd:nextInt(bound)) // 2
		b = (rnd:nextInt(bound) + rnd:nextInt(bound)) // 2
	else
		a = rnd:nextInt(bound)
		b = rnd:nextInt(bound)
	end
	return rx * spacing + a, rz * spacing + b, rx, rz
end

-- Placement records for the structures whose start chunk is `chunk`:
--   { kind = "Structure", name, x, y, z (block coordinates, y = first free block above the ground), rot (0..3), seed, biome }
function Structures.place(self: any, chunk: any): { any }
	local out = {}
	local cx, cz = chunk.cx, chunk.cz
	for _, d in self.defs do
		local ox, oz, rx, rz = Structures.potentialChunk(self, d, cx, cz)
		if ox == cx and oz == cz then
			local rnd = d.factory:at(rx, 0, rz)
			if rnd:nextDouble() < d.Chance then
				local rot = d.Rotate and rnd:nextInt(4) or 0
				local seed = rnd:nextInt(2147483647)
				local lx, lz = 8, 8 -- the middle of the start chunk
				local col = lx * 16 + lz + 1
				local floorY, topY = chunk.floorY[col], chunk.topY[col]
				local underwater = topY > floorY
				local okPlacement = (d.Placement == "Any")
					or (d.Placement == "Land" and not underwater and floorY >= SEA_LEVEL)
					or (d.Placement == "Water" and underwater)
				local biome = self.names[chunk.biomeTop[col]]
				if okPlacement and (d.biomeSet == nil or d.biomeSet[biome]) then
					-- the ground must be reasonably flat around the origin (4 samples, 3 blocks out)
					local lo, hi = floorY, floorY
					for _, off in { { -3, 0 }, { 3, 0 }, { 0, -3 }, { 0, 3 } } do
						local y = chunk.floorY[(lx + off[1]) * 16 + lz + off[2] + 1]
						lo, hi = math.min(lo, y), math.max(hi, y)
					end
					if hi - lo <= d.MaxSlope then
						table.insert(out, {
							kind = "Structure", name = d.Name, x = cx * 16 + lx, y = floorY + 1, z = cz * 16 + lz,
							rot = rot, seed = seed, biome = biome,
						})
					end
				end
			end
		end
	end
	return out
end

return Structures
