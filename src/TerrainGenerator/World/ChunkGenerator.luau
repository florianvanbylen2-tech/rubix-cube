--!strict
-- Assembles the per-world generation pipeline and produces chunk data (pure Luau, no Roblox APIs).

local RandomState = require(script.Parent.RandomState)
local Compiler = require(script.Parent.Parent.Density.Compiler)
local Settings = require(script.Parent.Parent.Data.Settings)
local NoiseFill = require(script.Parent.NoiseFill)
local BiomeRegistry = require(script.Parent.BiomeRegistry)
local BiomeSource = require(script.Parent.BiomeSource)
local SurfaceSystem = require(script.Parent.SurfaceSystem)
local Carvers = require(script.Parent.Carvers)
local Features = require(script.Parent.Features)
local Placements = require(script.Parent.Placements)

local HEIGHT = Settings.height

export type Chunk = {
	cx: number,
	cz: number,
	blocks: buffer, -- index ((x*16 + z) * HEIGHT + (y - minY)), u8 block ids
	occ: buffer?, -- same layout: u8 occupancy (0..255) for smooth terrain
	topY: { number }, -- WORLD_SURFACE_WG: highest non-air block per column (index x*16+z+1)
	floorY: { number }, -- OCEAN_FLOOR_WG: highest solid block per column
	veinOres: { { any } },
	biomeTop: { number }, -- biome id at the surface of each column
	aquifer: any?,
	carvedList: { number }?,
	collectables: { any },
	placements: { any }?, -- things to place (trees, ores, structures) after the spawn rules, see World/Placements
}

local ChunkGenerator = {}
ChunkGenerator.__index = ChunkGenerator

-- seed: number or string; options.customBiomes: { BiomeRegistry.Custom }
export type Options = {
	customBiomes: { any }?, -- RegisterBiome definitions
	disabledBiomes: { string }?, -- vanilla biomes removed from the world
	smooth: boolean?, -- sub-voxel occupancy (only needed where terrain is written)
	things: boolean?, -- compute trees / ores / structures (false on clients: they only need terrain)
	spawning: any?, -- Config.Spawning
	trees: any?, -- Config.Trees
	ores: any?, -- Config.Ores
	structures: { any }?, -- normalized structure rules (World/Structures.normalizeAll)
}

function ChunkGenerator.new(seed: number | string, options: Options?)
	local sh, sl = RandomState.seedFrom(seed)
	local rs = RandomState.new(sh, sl)
	local sampler = Compiler.compile(rs)
	local registry = BiomeRegistry.new(options and options.customBiomes)
	for _, name in (options and options.disabledBiomes) or {} do
		assert(registry.ids[(string.gsub(name, "^minecraft:", ""))] ~= nil, "Config.Biomes.Disabled: unknown biome " .. name)
	end
	local self = {
		rs = rs,
		sampler = sampler,
		registry = registry,
		biomes = BiomeSource.new(sampler, registry, rs, options and options.disabledBiomes),
		fill = NoiseFill.new(sampler, rs),
		smooth = not options or options.smooth ~= false,
	}
	setmetatable(self, ChunkGenerator)
	self.surface = SurfaceSystem.new(self)
	self.features = Features.new(self, options)
	if not options or options.things ~= false then
		self.placements = Placements.new(self, options)
	end
	return self
end

function ChunkGenerator.newChunk(cx: number, cz: number, smooth: boolean?): Chunk
	local blocks = buffer.create(256 * HEIGHT)
	return {
		cx = cx,
		cz = cz,
		blocks = blocks,
		occ = smooth and buffer.create(256 * HEIGHT) or nil,
		topY = table.create(256, 0),
		floorY = table.create(256, 0),
		veinOres = {},
		biomeTop = table.create(256, 0),
		collectables = {},
	}
end

-- Stage 1 only (noise fill)
function ChunkGenerator.generateNoise(self: any, cx: number, cz: number): Chunk
	local chunk = ChunkGenerator.newChunk(cx, cz, self.smooth)
	NoiseFill.fill(self.fill, chunk)
	return chunk
end

-- Stages 1-2: noise fill + surface rules
function ChunkGenerator.generateSurface(self: any, cx: number, cz: number): Chunk
	local chunk = ChunkGenerator.generateNoise(self, cx, cz)
	self.surface:build(chunk)
	return chunk
end

-- Stages 1-3: noise fill + surface rules + carvers
function ChunkGenerator.generateCarved(self: any, cx: number, cz: number): Chunk
	local chunk = ChunkGenerator.generateSurface(self, cx, cz)
	Carvers.carve(self, chunk)
	if chunk.occ and chunk.carvedList then
		Carvers.smoothCarved(chunk, chunk.carvedList)
	end
	chunk.carvedList = nil
	Carvers.recomputeHeightmaps(chunk)
	return chunk
end

-- The full pipeline: noise -> surface -> carvers -> features.
-- yieldFn (optional) is called between stages and between noise-fill slabs so a caller running in a Roblox
-- Actor can hand the frame back instead of holding it for the whole ~100-300 ms a chunk takes. The generator
-- is not re-entrant: never run two generate() calls on one generator at the same time.
function ChunkGenerator.generate(self: any, cx: number, cz: number, yieldFn: (() -> ())?): Chunk
	self.fill.yieldFn = yieldFn
	local chunk = ChunkGenerator.generateNoise(self, cx, cz)
	self.fill.yieldFn = nil
	if yieldFn then
		yieldFn()
	end
	self.surface:build(chunk)
	if yieldFn then
		yieldFn()
	end
	Carvers.carve(self, chunk)
	if chunk.occ and chunk.carvedList then
		Carvers.smoothCarved(chunk, chunk.carvedList)
	end
	chunk.carvedList = nil
	Carvers.recomputeHeightmaps(chunk)
	if yieldFn then
		yieldFn()
	end
	Features.generate(self.features, chunk)
	if self.placements then
		Placements.build(self.placements, chunk)
	end
	chunk.aquifer = nil
	return chunk
end

return ChunkGenerator
