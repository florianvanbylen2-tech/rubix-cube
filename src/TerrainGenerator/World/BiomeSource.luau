--!strict
--!native
-- MultiNoiseBiomeSource + BiomeManager for the overworld.
--   getNoiseBiome(qx, qy, qz): the biome stored at a 4x4x4 block "quart" cell (what vanilla writes to chunk data)
--   getBiome(x, y, z):         BiomeManager.getBiome, the SHA-256-seeded fuzzy zoom used for block-level queries
-- Custom biomes registered in the BiomeRegistry overlay the vanilla result.

local Climate = require(script.Parent.Climate)
local OverworldBiomeBuilder = require(script.Parent.OverworldBiomeBuilder)
local Int64 = require(script.Parent.Parent.Core.Int64)
local Hash = require(script.Parent.Parent.Core.Hash)
local NormalNoise = require(script.Parent.Parent.Noise.NormalNoise)
local Compiler = require(script.Parent.Parent.Density.Compiler)

local quantize = Climate.quantize

local MEMO_LIMIT = 300000

export type BiomeSource = {
	getNoiseBiome: (BiomeSource, number, number, number) -> number,
	getBiome: (BiomeSource, number, number, number) -> number,
	sampleClimate: (BiomeSource, number, number, number) -> { [string]: number },
}

local BiomeSource = {}
BiomeSource.__index = BiomeSource

-- shared, immutable vanilla parameter tree (values are biome names)
local vanillaTree: Climate.Tree? = nil
local function getVanillaTree(): Climate.Tree
	if not vanillaTree then
		vanillaTree = Climate.buildTree(OverworldBiomeBuilder.build())
	end
	return vanillaTree :: Climate.Tree
end

-- LinearCongruentialGenerator.next(seed, increment) = seed * (seed * 6364136223846793005 + 1442695040888963407) + increment
local function lcgNext(sh: number, sl: number, ih: number, il: number): (number, number)
	local th, tl = Int64.mul(sh, sl, 0x5851F42D, 0x4C957F2D)
	th, tl = Int64.add(th, tl, 0x14057B7E, 0xF767814F)
	th, tl = Int64.mul(sh, sl, th, tl)
	return Int64.add(th, tl, ih, il)
end

local function fiddle(h: number, l: number): number
	local v = bit32.band(bit32.bor(bit32.rshift(l, 24), bit32.lshift(h, 8)), 1023)
	return (v / 1024 - 0.5) * 0.9
end

-- `sampler` is a compiled density Sampler; `registry` a BiomeRegistry
function BiomeSource.new(sampler: Compiler.Sampler, registry: any, rs: any): BiomeSource
	local router = sampler.router
	local fns = sampler.fns
	local self = setmetatable({}, BiomeSource) :: any

	self.registry = registry
	self.tree = getVanillaTree()
	self.tempFn = fns[router.temperature]
	self.humFn = fns[router.vegetation]
	self.contFn = fns[router.continents]
	self.eroFn = fns[router.erosion]
	self.depthFn = fns[router.depth]
	self.weirdFn = fns[router.ridges]
	self.noiseCache = {} :: { [number]: number }
	self.noiseCacheSize = 0
	self.fiddleCache = {} :: { [number]: { number } }
	self.fiddleCacheSize = 0
	self.rs = rs

	-- vanilla name -> id
	local ids = registry.ids
	local leaves: { [string]: number } = {}
	for name, id in ids do
		leaves[name] = id
	end
	self.idOf = leaves

	-- BiomeManager zoom seed = first 8 bytes (little endian) of SHA-256(long seed, little endian)
	local bytes = Hash.sha256Bytes(string.pack("<I4I4", rs.seedL, rs.seedH))
	self.zoomL = bytes[1] + bytes[2] * 256 + bytes[3] * 65536 + bytes[4] * 16777216
	self.zoomH = bytes[5] + bytes[6] * 256 + bytes[7] * 65536 + bytes[8] * 16777216

	-- region noises for custom biomes
	self.regionNoise = {} :: { [number]: NormalNoise.NormalNoise }
	for id, def in registry.custom do
		if def.region then
			local octaves = def.region.octaves or 3
			local amps = table.create(octaves, 1.0)
			self.regionNoise[id] = NormalNoise.create(rs.random:fromHashOf("magic:" .. def.id), 0, amps)
		end
	end
	return self
end

-- Returns the raw (unquantised) climate values at a block position.
function BiomeSource.sampleClimate(self: BiomeSource, x: number, y: number, z: number): { [string]: number }
	local s = self :: any
	return {
		temperature = s.tempFn(x, y, z),
		humidity = s.humFn(x, y, z),
		continentalness = s.contFn(x, y, z),
		erosion = s.eroFn(x, y, z),
		depth = s.depthFn(x, y, z),
		weirdness = s.weirdFn(x, y, z),
	}
end

local function inRange(r: { number }?, v: number): boolean
	return r == nil or (v >= r[1] and v <= r[2])
end

function BiomeSource.getNoiseBiome(self: BiomeSource, qx: number, qy: number, qz: number): number
	local s = self :: any
	local key = ((qx + 2097152) * 4194304 + (qz + 2097152)) * 128 + (qy + 32)
	local cached = s.noiseCache[key]
	if cached then
		return cached
	end
	local x, y, z = qx * 4, qy * 4, qz * 4
	local t, h, c, e, d, w = s.tempFn(x, y, z), s.humFn(x, y, z), s.contFn(x, y, z), s.eroFn(x, y, z), s.depthFn(x, y, z), s.weirdFn(x, y, z)

	local result: number? = nil
	local registry = s.registry
	for _, id in registry.customList do
		local def = registry.custom[id]
		local cl = def.climate
		if
			(cl == nil or (
				inRange(cl.temperature, t) and inRange(cl.humidity, h) and inRange(cl.continentalness, c)
				and inRange(cl.erosion, e) and inRange(cl.weirdness, w) and inRange(cl.depth, d)
			))
		then
			local ok = true
			local region = def.region
			if region then
				local scale = region.scale or 512
				local v = s.regionNoise[id]:getValue(x / scale, 0, z / scale)
				ok = v > (region.threshold or 0.5)
			end
			if ok then
				result = id
				break
			end
		end
	end
	if not result then
		local name = Climate.search(s.tree, quantize(t), quantize(h), quantize(c), quantize(e), quantize(d), quantize(w))
		result = s.idOf[name]
	end

	if s.noiseCacheSize > MEMO_LIMIT then
		table.clear(s.noiseCache)
		s.noiseCacheSize = 0
	end
	s.noiseCache[key] = result :: number
	s.noiseCacheSize += 1
	return result :: number
end

-- fiddle offsets for a quart cell (deterministic per world seed)
local function fiddles(s: any, x: number, y: number, z: number): { number }
	local key = ((x + 2097152) * 4194304 + (z + 2097152)) * 128 + (y + 32)
	local f = s.fiddleCache[key]
	if f then
		return f
	end
	local sh, sl = s.zoomH, s.zoomL
	local xh, xl = Int64.fromInt32(x)
	local yh, yl = Int64.fromInt32(y)
	local zh, zl = Int64.fromInt32(z)
	local ih, il = lcgNext(sh, sl, xh, xl)
	ih, il = lcgNext(ih, il, yh, yl)
	ih, il = lcgNext(ih, il, zh, zl)
	ih, il = lcgNext(ih, il, xh, xl)
	ih, il = lcgNext(ih, il, yh, yl)
	ih, il = lcgNext(ih, il, zh, zl)
	local d0 = fiddle(ih, il)
	ih, il = lcgNext(ih, il, sh, sl)
	local d1 = fiddle(ih, il)
	ih, il = lcgNext(ih, il, sh, sl)
	local d2 = fiddle(ih, il)
	f = { d0, d1, d2 }
	if s.fiddleCacheSize > MEMO_LIMIT then
		table.clear(s.fiddleCache)
		s.fiddleCacheSize = 0
	end
	s.fiddleCache[key] = f
	s.fiddleCacheSize += 1
	return f
end

-- BiomeManager.getBiome(BlockPos)
function BiomeSource.getBiome(self: BiomeSource, x: number, y: number, z: number): number
	local s = self :: any
	local i, j, k = x - 2, y - 2, z - 2
	local l, i1, j1 = i // 4, j // 4, k // 4
	local d0, d1, d2 = (i - l * 4) / 4, (j - i1 * 4) / 4, (k - j1 * 4) / 4
	local bestIdx, bestDist = 0, math.huge
	for idx = 0, 7 do
		local fx = idx < 4
		local fy = (idx // 2) % 2 == 0
		local fz = idx % 2 == 0
		local cx = fx and l or l + 1
		local cy = fy and i1 or i1 + 1
		local cz = fz and j1 or j1 + 1
		local f = fiddles(s, cx, cy, cz)
		local dx = (fx and d0 or d0 - 1) + f[1]
		local dy = (fy and d1 or d1 - 1) + f[2]
		local dz = (fz and d2 or d2 - 1) + f[3]
		local dist = dz * dz + dy * dy + dx * dx
		if bestDist > dist then
			bestIdx, bestDist = idx, dist
		end
	end
	local rx = bestIdx < 4 and l or l + 1
	local ry = (bestIdx // 2) % 2 == 0 and i1 or i1 + 1
	local rz = bestIdx % 2 == 0 and j1 or j1 + 1
	return self:getNoiseBiome(rx, ry, rz)
end

return BiomeSource
