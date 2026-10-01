--!strict
-- Custom structure placement: pure data in, plain placement records out (the building itself happens on the main
-- thread, see Streaming/StructureBuilder, because it runs user code and creates Instances).
--
-- Modelled on Minecraft's `random_spread` placement: the world is cut into Spacing x Spacing chunk cells and every
-- cell may hold one structure, whose origin chunk is a seeded random offset inside the cell (leaving a margin of
-- Separation chunks). So two structures of one kind are always >= Separation chunks apart, and the layout depends
-- only on the world seed and the structure name: regenerating a chunk gives the same structure again.

local Settings = require(script.Parent.Parent.Data.Settings)

local floor, abs = math.floor, math.abs
local SEA_LEVEL = Settings.seaLevel

export type Def = {
	Name: string,
	Spacing: number, -- chunks between structure cells (16 blocks = 64 studs per chunk)
	Separation: number, -- minimum chunks between two structures of this kind (< Spacing)
	Chance: number, -- 0..1, probability that a cell holds a structure
	Salt: number, -- changes the layout of this kind without renaming it
	Biomes: { [string]: boolean }?, -- allowed biome names (nil = any biome)
	Placement: string, -- "Land" | "Water" | "Any"
	MaxSlope: number, -- max ground height difference (blocks) across the footprint
	Rotate: boolean, -- random 90 degree rotation
}

local Structures = {}
Structures.__index = Structures

local function biomeSet(list: any): { [string]: boolean }?
	if list == nil then
		return nil
	end
	assert(type(list) == "table", "Biomes must be a list of biome names")
	local set: { [string]: boolean } = {}
	for _, name in list do
		set[(string.gsub(tostring(name), "^minecraft:", ""))] = true
	end
	return set
end

-- Validates a user definition and returns the placement part (plain data, safe to send to a worker).
function Structures.normalize(def: any): any
	assert(type(def) == "table", "structure definition must be a table")
	assert(type(def.Name) == "string" and def.Name ~= "", "structure needs a string `Name`")
	local spacing = def.Spacing or 24
	local separation = def.Separation or math.floor(spacing / 3)
	assert(type(spacing) == "number" and spacing >= 2 and spacing % 1 == 0, def.Name .. ": Spacing must be a whole number >= 2")
	assert(type(separation) == "number" and separation >= 0 and separation < spacing and separation % 1 == 0, def.Name .. ": Separation must be a whole number below Spacing")
	local placement = def.Placement or "Land"
	assert(placement == "Land" or placement == "Water" or placement == "Any", def.Name .. ": Placement must be Land, Water or Any")
	return {
		Name = def.Name,
		Spacing = spacing,
		Separation = separation,
		Chance = math.clamp(def.Chance or 1, 0, 1),
		Salt = def.Salt or 0,
		Biomes = def.Biomes and table.clone(def.Biomes) or nil, -- list form; converted when a generator is built
		Placement = placement,
		MaxSlope = def.MaxSlope or 4,
		Rotate = def.Rotate ~= false,
	}
end

-- defs: list of Structures.normalize() results.
function Structures.new(gen: any, defs: { any }): any
	local list = {}
	for _, d in defs do
		local def = table.clone(d)
		def.Biomes = biomeSet(d.Biomes)
		def.factory = gen.rs.random:fromHashOf("terraingenerator:structure/" .. d.Name):forkPositional()
		table.insert(list, def)
	end
	return setmetatable({ defs = list, names = gen.registry.names }, Structures)
end

-- Placement records for the structures whose origin chunk is `chunk`:
--   { name, x, y, z (block coordinates; y = top ground block), rot (0..3), seed, biome }
function Structures.place(self: any, chunk: any): { any }
	local out = {}
	local cx, cz = chunk.cx, chunk.cz
	for _, d in self.defs do
		local spacing = d.Spacing
		local rx, rz = floor(cx / spacing), floor(cz / spacing)
		local rnd = d.factory:at(rx, d.Salt, rz)
		local span = spacing - d.Separation
		local ox, oz = rx * spacing + rnd:nextInt(span), rz * spacing + rnd:nextInt(span)
		if ox == cx and oz == cz and rnd:nextDouble() < d.Chance then
			local lx, lz = 4 + rnd:nextInt(8), 4 + rnd:nextInt(8)
			local rot = d.Rotate and rnd:nextInt(4) or 0
			local seed = rnd:nextInt(2147483647)
			local col = lx * 16 + lz + 1
			local floorY, topY = chunk.floorY[col], chunk.topY[col]
			local underwater = topY > floorY
			local okPlacement = (d.Placement == "Any")
				or (d.Placement == "Land" and not underwater and floorY >= SEA_LEVEL)
				or (d.Placement == "Water" and underwater)
			local biome = self.names[chunk.biomeTop[col]]
			if okPlacement and (d.Biomes == nil or d.Biomes[biome]) then
				-- ground must be reasonably flat around the origin (5 samples, 3 blocks out, inside the chunk)
				local lo, hi = floorY, floorY
				for _, off in { { -3, 0 }, { 3, 0 }, { 0, -3 }, { 0, 3 } } do
					local x, z = math.clamp(lx + off[1], 0, 15), math.clamp(lz + off[2], 0, 15)
					local y = chunk.floorY[x * 16 + z + 1]
					lo, hi = math.min(lo, y), math.max(hi, y)
				end
				if abs(hi - lo) <= d.MaxSlope then
					table.insert(out, { name = d.Name, x = cx * 16 + lx, y = floorY, z = cz * 16 + lz, rot = rot, seed = seed, biome = biome })
				end
			end
		end
	end
	return out
end

return Structures
