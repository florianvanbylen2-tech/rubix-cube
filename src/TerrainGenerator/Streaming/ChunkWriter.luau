--!strict
--!native
-- Turns generated chunk data into Roblox Terrain voxels and collectable Parts, and removes them again.
-- Runs in the serial phase (Terrain writes and Instance creation are not parallel-safe).
--
-- Terrain: the chunk is written per 16-block section. Sections that are entirely one block (deep stone, open
-- sky, open water) become a single FillBlock / are skipped; mixed sections are written with WriteVoxels, merged
-- into vertical runs to keep the number of calls small.

local Blocks = require(script.Parent.Parent.World.Blocks)
local Settings = require(script.Parent.Parent.Data.Settings)

local HEIGHT = Settings.height
local MIN_Y = Settings.minY
local SECTION = 16
local SECTIONS = HEIGHT // SECTION
local VOXEL = 4
local CHUNK_STUDS = 16 * VOXEL
local AIR = Blocks.AIR

export type WriterConfig = {
	bedrockLevel: number,
	folderName: string,
	collectables: boolean,
	partSize: Vector3,
	colorParts: boolean,
	applyColors: boolean,
	decoration: boolean?,
}

-- biomes whose grass is a darker green (Minecraft tints grass per biome; Terrain only has two grass materials)
local LEAFY_BIOMES = {
	forest = true, birch_forest = true, old_growth_birch_forest = true, dark_forest = true, flower_forest = true,
	taiga = true, old_growth_pine_taiga = true, old_growth_spruce_taiga = true, snowy_taiga = true,
	jungle = true, sparse_jungle = true, bamboo_jungle = true, swamp = true, mangrove_swamp = true,
	windswept_forest = true, cherry_grove = true, grove = true,
}

local TREE_COLORS: { [string]: { number } } = {
	default = { 70, 140, 60 }, spruce = { 40, 90, 60 }, pine = { 40, 90, 60 }, mega_spruce = { 40, 90, 60 },
	mega_pine = { 40, 90, 60 }, birch = { 130, 170, 90 }, super_birch = { 130, 170, 90 }, jungle_tree = { 50, 150, 40 },
	mega_jungle_tree = { 50, 150, 40 }, jungle_bush = { 50, 150, 40 }, acacia = { 150, 160, 60 }, dark_oak = { 40, 90, 40 },
	mangrove = { 90, 110, 60 }, tall_mangrove = { 90, 110, 60 }, cherry = { 240, 170, 200 },
	huge_red_mushroom = { 200, 50, 50 }, huge_brown_mushroom = { 150, 110, 80 },
}
local ORE_COLORS: { [string]: { number } } = {
	coal = { 40, 40, 40 }, iron = { 216, 175, 147 }, copper = { 224, 130, 80 }, gold = { 250, 210, 60 },
	redstone = { 230, 40, 40 }, lapis = { 40, 80, 200 }, diamond = { 80, 230, 230 }, emerald = { 60, 200, 100 },
}

local ChunkWriter = {}
ChunkWriter.__index = ChunkWriter

function ChunkWriter.new(config: WriterConfig)
	local terrain = workspace.Terrain
	local root = workspace:FindFirstChild(config.folderName)
	if config.collectables and not root then
		local f = Instance.new("Folder")
		f.Name = config.folderName
		f.Parent = workspace
		root = f
	end

	local materialOf: { [number]: Enum.Material } = {}
	for id = 0, Blocks.count - 1 do
		local name = Blocks.materials[id]
		materialOf[id] = (Enum.Material :: any)[name]
	end

	local self = setmetatable({
		terrain = terrain,
		root = root,
		config = config,
		materialOf = materialOf,
		grass = Enum.Material.Grass,
		leafy = Enum.Material.LeafyGrass,
		grassId = Blocks.ids.grass_block,
		rock = Enum.Material.Rock,
		leafyBiome = nil :: { [number]: boolean }?,
	}, ChunkWriter)
	return self
end

-- Applies global Terrain settings (main thread, once).
function ChunkWriter.applyGlobals(config: WriterConfig)
	local terrain = workspace.Terrain
	if config.decoration ~= nil then
		terrain.Decoration = config.decoration
	end
	if config.applyColors then
		for matName, rgb in Blocks.colors do
			local mat = (Enum.Material :: any)[matName]
			terrain:SetMaterialColor(mat, Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
		end
	end
end

-- Registry-dependent: which biome ids get the darker grass. Called by the worker after it builds its generator.
function ChunkWriter.setBiomeNames(self: any, names: { string })
	local set: { [number]: boolean } = {}
	for id, name in names do
		if LEAFY_BIOMES[name] then
			set[id] = true
		end
	end
	self.leafyBiome = set
end

-- Returns the block id if every voxel of the 16-block section is that block (and fully occupied / empty), else -1.
local function sectionUniform(blocks: buffer, occ: buffer?, s: number): number
	local yi = s * SECTION
	local first = buffer.readu8(blocks, yi)
	local pat = first * 0x01010101
	local occPat = (first == AIR) and 0 or 0xFFFFFFFF
	for col = 0, 255 do
		local off = col * HEIGHT + yi
		if
			buffer.readu32(blocks, off) ~= pat
			or buffer.readu32(blocks, off + 4) ~= pat
			or buffer.readu32(blocks, off + 8) ~= pat
			or buffer.readu32(blocks, off + 12) ~= pat
		then
			return -1
		end
		if occ then
			if
				buffer.readu32(occ, off) ~= occPat
				or buffer.readu32(occ, off + 4) ~= occPat
				or buffer.readu32(occ, off + 8) ~= occPat
				or buffer.readu32(occ, off + 12) ~= occPat
			then
				return -1
			end
		end
	end
	return first
end

local function isSolidId(b: number): boolean
	return Blocks.isSolid(b)
end

-- Writes sections [s0, s0 + n) of the chunk with WriteVoxels.
local function writeRun(self: any, chunk: any, s0: number, n: number)
	local blocks: buffer, occ: buffer? = chunk.blocks, chunk.occ
	local biomeTop = chunk.biomeTop
	local materialOf = self.materialOf
	local leafyBiome = self.leafyBiome
	local grassId = self.grassId
	local airMat = Enum.Material.Air
	local ny = n * SECTION
	local yStart = s0 * SECTION

	local mats: { any } = table.create(16)
	local occs: { any } = table.create(16)
	for x = 1, 16 do
		local mx, ox = table.create(ny), table.create(ny)
		for y = 1, ny do
			mx[y] = table.create(16, airMat)
			ox[y] = table.create(16, 0)
		end
		mats[x], occs[x] = mx, ox
	end

	for x = 0, 15 do
		local mx, ox = mats[x + 1], occs[x + 1]
		for z = 0, 15 do
			local col = x * 16 + z
			local off = col * HEIGHT + yStart
			local grassMat = self.grass
			if leafyBiome and leafyBiome[biomeTop[col + 1]] then
				grassMat = self.leafy
			end
			for y = 0, ny - 1 do
				local b = buffer.readu8(blocks, off + y)
				local o = occ and buffer.readu8(occ, off + y) or (b == AIR and 0 or 255)
				if b == AIR then
					if o >= 6 then
						-- air voxel partly filled by the smoothed surface: take the material of the ground next to it
						local nb = (y > 0) and buffer.readu8(blocks, off + y - 1) or AIR
						if not isSolidId(nb) and (yStart + y < HEIGHT - 1) then
							nb = buffer.readu8(blocks, off + y + 1)
						end
						if not isSolidId(nb) and x > 0 then
							nb = buffer.readu8(blocks, off + y - 16 * HEIGHT)
						end
						if not isSolidId(nb) and x < 15 then
							nb = buffer.readu8(blocks, off + y + 16 * HEIGHT)
						end
						if not isSolidId(nb) and z > 0 then
							nb = buffer.readu8(blocks, off + y - HEIGHT)
						end
						if not isSolidId(nb) and z < 15 then
							nb = buffer.readu8(blocks, off + y + HEIGHT)
						end
						mx[y + 1][z + 1] = isSolidId(nb) and ((nb == grassId) and grassMat or materialOf[nb]) or self.rock
						ox[y + 1][z + 1] = o / 255
					end
				else
					local mat = materialOf[b]
					if b == grassId then
						mat = grassMat
					end
					mx[y + 1][z + 1] = mat
					ox[y + 1][z + 1] = o / 255
				end
			end
		end
	end

	local x0 = chunk.cx * CHUNK_STUDS
	local z0 = chunk.cz * CHUNK_STUDS
	local yMin = self.config.bedrockLevel + yStart * VOXEL
	local region = Region3.new(Vector3.new(x0, yMin, z0), Vector3.new(x0 + CHUNK_STUDS, yMin + ny * VOXEL, z0 + CHUNK_STUDS))
	self.terrain:WriteVoxels(region, VOXEL, mats, occs)
end

local function partColor(c: any): Color3
	local rgb
	if c.kind == "Tree" then
		rgb = TREE_COLORS[c.species] or TREE_COLORS.default
	else
		rgb = ORE_COLORS[c.ore] or { 200, 200, 200 }
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function makeCollectables(self: any, chunk: any)
	local list = chunk.collectables
	if not self.config.collectables or #list == 0 or not self.root then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = string.format("Chunk_%d_%d", chunk.cx, chunk.cz)
	local baseY = self.config.bedrockLevel
	local size = self.config.partSize
	local colorParts = self.config.colorParts
	for _, c in list do
		local part = Instance.new("Part")
		local px, py, pz
		if c.kind == "Tree" then
			-- x, z are block indices; y is the first air block above the ground: stand the part on the ground
			px, py, pz = (c.x + 0.5) * VOXEL, baseY + (c.y - MIN_Y + 0.5) * VOXEL, (c.z + 0.5) * VOXEL
			part.Name = "Tree"
			part:SetAttribute("Species", c.species)
			part:SetAttribute("Biome", c.biome)
			part:SetAttribute("Height", c.height)
		else
			px, py, pz = c.x * VOXEL, baseY + (c.y - MIN_Y) * VOXEL, c.z * VOXEL
			part.Name = "Ore_" .. tostring(c.tier)
			part:SetAttribute("OreType", c.ore)
			part:SetAttribute("Tier", c.tier)
			part:SetAttribute("Size", c.count)
		end
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.Locked = true
		part.Size = size
		part.Position = Vector3.new(px, py, pz)
		if colorParts then
			part.Color = partColor(c)
		end
		part.Parent = folder
	end
	folder.Parent = self.root
end

-- Writes a whole chunk. Serial phase only.
function ChunkWriter.write(self: any, chunk: any)
	local blocks: buffer, occ: buffer? = chunk.blocks, chunk.occ
	local terrain = self.terrain
	local baseY = self.config.bedrockLevel
	local x0 = chunk.cx * CHUNK_STUDS
	local z0 = chunk.cz * CHUNK_STUDS

	local kind = table.create(SECTIONS, -1)
	for s = 0, SECTIONS - 1 do
		kind[s + 1] = sectionUniform(blocks, occ, s)
	end

	local s = 0
	while s < SECTIONS do
		local k = kind[s + 1]
		if k == AIR then
			s += 1
		elseif k >= 0 then
			-- merge vertically adjacent identical uniform sections into one FillBlock
			local e = s
			while e + 1 < SECTIONS and kind[e + 2] == k do
				e += 1
			end
			local n = e - s + 1
			local height = n * SECTION * VOXEL
			local cf = CFrame.new(x0 + CHUNK_STUDS / 2, baseY + s * SECTION * VOXEL + height / 2, z0 + CHUNK_STUDS / 2)
			terrain:FillBlock(cf, Vector3.new(CHUNK_STUDS, height, CHUNK_STUDS), self.materialOf[k])
			s = e + 1
		else
			local e = s
			while e + 1 < SECTIONS and kind[e + 2] == -1 do
				e += 1
			end
			writeRun(self, chunk, s, e - s + 1)
			s = e + 1
		end
	end
	makeCollectables(self, chunk)
end

-- Removes a chunk's terrain column and collectables. Main thread.
function ChunkWriter.unload(self: any, cx: number, cz: number)
	local baseY = self.config.bedrockLevel
	local height = HEIGHT * VOXEL
	self.terrain:FillBlock(
		CFrame.new(cx * CHUNK_STUDS + CHUNK_STUDS / 2, baseY + height / 2, cz * CHUNK_STUDS + CHUNK_STUDS / 2),
		Vector3.new(CHUNK_STUDS, height, CHUNK_STUDS),
		Enum.Material.Air
	)
	if self.root then
		local f = self.root:FindFirstChild(string.format("Chunk_%d_%d", cx, cz))
		if f then
			f:Destroy()
		end
	end
end

return ChunkWriter
