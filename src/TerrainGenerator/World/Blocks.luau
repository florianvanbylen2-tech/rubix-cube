--!strict
-- Block registry: compact ids for the generator's u8 block buffers and the Minecraft block ->
-- Roblox Terrain material palette.
--
-- Roblox Terrain has no per-voxel colour and only 22 materials, so several Minecraft blocks share one
-- material (and therefore one colour).  Edit the palette below to taste; `Colors` is applied with
-- Terrain:SetMaterialColor when Config.ApplyMaterialColors is true.

export type Block = {
	name: string,
	material: string, -- Enum.Material name
	kind: string, -- "air" | "solid" | "fluid"
}

local LIST: { { any } } = {
	-- fixed low ids: hot loops compare against these directly
	{ "air", "Air", "air" },
	{ "stone", "Rock", "solid" },
	{ "water", "Water", "fluid" },
	{ "lava", "CrackedLava", "fluid" },
	{ "deepslate", "Slate", "solid" },
	{ "bedrock", "Basalt", "solid" },
	-- ----
	{ "granite", "Salt", "solid" },
	{ "diorite", "Limestone", "solid" },
	{ "andesite", "Cobblestone", "solid" },
	{ "tuff", "Asphalt", "solid" },
	{ "calcite", "Limestone", "solid" },
	{ "dirt", "Ground", "solid" },
	{ "coarse_dirt", "Ground", "solid" },
	{ "podzol", "Ground", "solid" },
	{ "grass_block", "Grass", "solid" },
	{ "mycelium", "Mud", "solid" },
	{ "mud", "Mud", "solid" },
	{ "sand", "Sand", "solid" },
	{ "red_sand", "Brick", "solid" },
	{ "sandstone", "Sandstone", "solid" },
	{ "red_sandstone", "Brick", "solid" },
	{ "gravel", "Pavement", "solid" },
	{ "clay", "Concrete", "solid" },
	{ "terracotta", "Brick", "solid" },
	{ "orange_terracotta", "Brick", "solid" },
	{ "yellow_terracotta", "Sand", "solid" },
	{ "brown_terracotta", "Mud", "solid" },
	{ "red_terracotta", "Brick", "solid" },
	{ "white_terracotta", "Salt", "solid" },
	{ "light_gray_terracotta", "Salt", "solid" },
	{ "snow_block", "Snow", "solid" },
	{ "powder_snow", "Snow", "solid" },
	{ "ice", "Ice", "solid" },
	{ "packed_ice", "Glacier", "solid" },
	{ "blue_ice", "Glacier", "solid" },
	{ "moss_block", "LeafyGrass", "solid" },
	{ "magma_block", "CrackedLava", "solid" },
}

-- Material colours (MC-like). Applied globally, so every block sharing a material shares its colour.
local COLORS: { [string]: { number } } = {
	Rock = { 125, 125, 125 },
	Slate = { 72, 72, 76 },
	Basalt = { 28, 28, 32 },
	Salt = { 168, 120, 100 },
	Limestone = { 200, 198, 188 },
	Cobblestone = { 134, 134, 136 },
	Asphalt = { 105, 108, 100 },
	Ground = { 132, 96, 66 },
	Grass = { 96, 156, 58 },
	LeafyGrass = { 70, 128, 48 },
	Mud = { 66, 54, 48 },
	Sand = { 218, 206, 160 },
	Sandstone = { 216, 203, 152 },
	Brick = { 176, 96, 54 },
	Pavement = { 132, 128, 126 },
	Concrete = { 160, 166, 178 },
	Snow = { 244, 248, 250 },
	Ice = { 150, 186, 250 },
	Glacier = { 130, 170, 240 },
	CrackedLava = { 232, 120, 30 },
}

local Blocks = {}

Blocks.AIR = 0
Blocks.STONE = 1
Blocks.WATER = 2
Blocks.LAVA = 3
Blocks.DEEPSLATE = 4
Blocks.BEDROCK = 5

Blocks.names = {} :: { [number]: string } -- id -> name (0-based ids)
Blocks.ids = {} :: { [string]: number } -- name -> id
Blocks.materials = {} :: { [number]: string }
Blocks.count = #LIST
Blocks.colors = COLORS

for i, entry in LIST do
	local id = i - 1
	Blocks.names[id] = entry[1]
	Blocks.ids[entry[1]] = id
	Blocks.materials[id] = entry[2]
end

-- Solid and fluid flags as u8 lookup tables (1 = true)
local solidBuf = buffer.create(256)
local fluidBuf = buffer.create(256)
for i, entry in LIST do
	buffer.writeu8(solidBuf, i - 1, entry[3] == "solid" and 1 or 0)
	buffer.writeu8(fluidBuf, i - 1, entry[3] == "fluid" and 1 or 0)
end
Blocks.solidBuf = solidBuf
Blocks.fluidBuf = fluidBuf

-- Applies user customisation (call once per Lua VM, before any generator / writer is created):
--   spec.materials = { grass_block = "LeafyGrass", stone = "Slate" }     remap a block to another Terrain material
--   spec.custom    = { { name = "crystal_stone", material = "Glacier", kind = "solid" } }   add new blocks
--   spec.colors    = { Grass = { 96, 156, 58 } }                         recolour a Terrain material
-- Roblox Terrain only has ~22 materials: several blocks share one material and therefore one colour.
function Blocks.configure(spec: any)
	if type(spec) ~= "table" then
		return
	end
	for _, def in spec.custom or {} do
		local id = Blocks.ids[def.name]
		if id == nil then
			id = Blocks.count
			assert(id < 255, "too many blocks (max 255)")
			Blocks.count += 1
			Blocks.ids[def.name] = id
			Blocks.names[id] = def.name
		end
		Blocks.materials[id] = def.material or "Rock"
		local kind = def.kind or "solid"
		buffer.writeu8(solidBuf, id, kind == "solid" and 1 or 0)
		buffer.writeu8(fluidBuf, id, kind == "fluid" and 1 or 0)
	end
	for name, material in spec.materials or {} do
		local id = Blocks.ids[name]
		assert(id ~= nil, "Config.Materials.Blocks: unknown block " .. tostring(name))
		Blocks.materials[id] = material
	end
	for material, rgb in spec.colors or {} do
		Blocks.colors[material] = { rgb[1], rgb[2], rgb[3] }
	end
end

function Blocks.id(name: string): number
	local id = Blocks.ids[name]
	if id == nil then
		error("unknown block: " .. tostring(name))
	end
	return id
end

function Blocks.isSolid(id: number): boolean
	return buffer.readu8(solidBuf, id) == 1
end

function Blocks.isFluid(id: number): boolean
	return buffer.readu8(fluidBuf, id) == 1
end

-- Ore blocks and saplings etc. that appear in data but are not terrain: map to their host rock.
function Blocks.terrainIdFor(name: string, y: number): number
	if string.find(name, "_ore$") or string.find(name, "^raw_") then
		return (string.find(name, "^deepslate_") or y < 0) and Blocks.DEEPSLATE or Blocks.STONE
	end
	local id = Blocks.ids[name]
	if id == nil then
		return Blocks.STONE
	end
	return id
end

return Blocks
