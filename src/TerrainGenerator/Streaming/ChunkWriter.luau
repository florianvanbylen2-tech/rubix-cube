--!strict
--!native
-- Turns generated chunk data into Roblox Terrain voxels, and removes them again.
-- Runs in the serial phase (Terrain writes are not parallel-safe). Where it runs (server or each client) is decided
-- by Config.TerrainMode.
--
-- Terrain: the chunk is written per 16-block section. Sections that are entirely one block (deep stone, open
-- sky, open water) become a single FillBlock / are skipped; mixed sections are written with WriteVoxels, merged
-- into vertical runs to keep the number of calls small.

local Blocks = require(script.Parent.Parent.World.Blocks)
local Settings = require(script.Parent.Parent.Data.Settings)

local HEIGHT = Settings.height
local SECTION = 16
local SECTIONS = HEIGHT // SECTION
local MAX_RUN = 4 -- sections per WriteVoxels call (bounds the time of one engine call and of building its tables)
local VOXEL = 4
local CHUNK_STUDS = 16 * VOXEL
local AIR = Blocks.AIR

export type WriterConfig = {
	bedrockLevel: number,
	applyColors: boolean,
	variants: { [string]: string }?, -- Terrain base material -> MaterialVariant name
	decoration: boolean?,
	writeBudgetMs: number?, -- yield (task.wait) between engine calls once a write has used this much time
}

-- biomes whose grass is a darker green (Minecraft tints grass per biome; Terrain only has two grass materials)
local LEAFY_BIOMES = {
	forest = true, birch_forest = true, old_growth_birch_forest = true, dark_forest = true, flower_forest = true,
	taiga = true, old_growth_pine_taiga = true, old_growth_spruce_taiga = true, snowy_taiga = true,
	jungle = true, sparse_jungle = true, bamboo_jungle = true, swamp = true, mangrove_swamp = true,
	windswept_forest = true, cherry_grove = true, grove = true,
}

local ChunkWriter = {}
ChunkWriter.__index = ChunkWriter

function ChunkWriter.new(config: WriterConfig)
	local terrain = workspace.Terrain
	local materialOf: { [number]: Enum.Material } = {}
	for id = 0, Blocks.count - 1 do
		local name = Blocks.materials[id]
		local material = (Enum.Material :: any)[name]
		assert(material ~= nil, string.format("block %s is mapped to unknown Terrain material %s", tostring(Blocks.names[id]), tostring(name)))
		materialOf[id] = material
	end

	local self = setmetatable({
		terrain = terrain,
		config = config,
		materialOf = materialOf,
		pool = {} :: { [number]: any }, -- reusable WriteVoxels tables, by run length in sections
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
	if config.variants and next(config.variants) ~= nil then
		-- MaterialVariants (custom textures) for Terrain base materials; needs the variants to exist in MaterialService
		local ok, MaterialService = pcall(function()
			return game:GetService("MaterialService")
		end)
		if ok then
			for matName, variant in config.variants do
				local mat = (Enum.Material :: any)[matName]
				local applied, err = pcall(function()
					(MaterialService :: any):SetBaseMaterialOverride(mat, variant)
				end)
				if not applied then
					warn("[TerrainGenerator] could not apply MaterialVariant " .. variant .. " to " .. matName .. ": " .. tostring(err))
				end
			end
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

	-- The 3-D material / occupancy tables WriteVoxels wants are large (16 x ny x 16 each); reuse them between calls
	-- instead of allocating ~4000 small tables per run. Every entry is overwritten below, so stale data is harmless.
	local pool = self.pool[n]
	if pool == nil then
		local pm: { any } = table.create(16)
		local po: { any } = table.create(16)
		for x = 1, 16 do
			local mx, ox = table.create(ny), table.create(ny)
			for y = 1, ny do
				mx[y] = table.create(16, airMat)
				ox[y] = table.create(16, 0)
			end
			pm[x], po[x] = mx, ox
		end
		pool = { mats = pm, occs = po }
		self.pool[n] = pool
	end
	local mats, occs = pool.mats, pool.occs

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
					else
						mx[y + 1][z + 1] = airMat
						ox[y + 1][z + 1] = 0
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

-- Writes a whole chunk. Serial phase only. Returns the height in studs (above the world floor) that now holds
-- terrain; pass it to unload so removing the chunk only clears that much.
function ChunkWriter.write(self: any, chunk: any): number
	local blocks: buffer, occ: buffer? = chunk.blocks, chunk.occ
	local terrain = self.terrain
	local baseY = self.config.bedrockLevel
	local x0 = chunk.cx * CHUNK_STUDS
	local z0 = chunk.cz * CHUNK_STUDS

	local kind = table.create(SECTIONS, -1)
	local topSection = -1
	for s = 0, SECTIONS - 1 do
		local k = sectionUniform(blocks, occ, s)
		kind[s + 1] = k
		if k ~= AIR then
			topSection = s
		end
	end

	local budget = (self.config.writeBudgetMs or math.huge) / 1000
	local sliceStart = os.clock()
	local function maybeYield()
		if os.clock() - sliceStart > budget then
			task.wait()
			sliceStart = os.clock()
		end
	end

	local s = 0
	while s < SECTIONS do
		maybeYield()
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
			while e + 1 < SECTIONS and kind[e + 2] == -1 and e - s + 1 < MAX_RUN do
				e += 1
			end
			writeRun(self, chunk, s, e - s + 1)
			s = e + 1
		end
	end
	return (topSection + 1) * SECTION * VOXEL
end

-- Removes a chunk's terrain column. `topStuds` = what write() returned (nil = clear the whole height). Main thread.
function ChunkWriter.unload(self: any, cx: number, cz: number, topStuds: number?)
	local height = topStuds or HEIGHT * VOXEL
	if height <= 0 then
		return
	end
	self.terrain:FillBlock(
		CFrame.new(cx * CHUNK_STUDS + CHUNK_STUDS / 2, self.config.bedrockLevel + height / 2, cz * CHUNK_STUDS + CHUNK_STUDS / 2),
		Vector3.new(CHUNK_STUDS, height, CHUNK_STUDS),
		Enum.Material.Air
	)
end

return ChunkWriter
