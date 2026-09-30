--!strict
--!native
-- Port of SurfaceRules + SurfaceSystem: applies the vanilla surface rule JSON (grass/dirt/sand, bedrock and
-- deepslate gradients, badlands bands, snow, ...) to a chunk, plus the eroded-badlands pillars and
-- frozen-ocean icebergs.

local Blocks = require(script.Parent.Blocks)
local Settings = require(script.Parent.Parent.Data.Settings)
local Rules = require(script.Parent.Parent.Data.SurfaceRules)
local BiomeTemperature = require(script.Parent.BiomeTemperature)

local floor, ceil, abs, min, max = math.floor, math.ceil, math.abs, math.min, math.max

local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local MAX_GEN_Y = MIN_Y + HEIGHT - 1
local SEA = Settings.seaLevel
local AIR, STONE, WATER, LAVA = Blocks.AIR, Blocks.STONE, Blocks.WATER, Blocks.LAVA
local NO_WATER = -2147483648

local function trunc(v: number): number
	return v >= 0 and floor(v) or -floor(-v)
end

local function anchorY(a: any): number
	if a.absolute then
		return a.absolute
	elseif a.above_bottom then
		return MIN_Y + a.above_bottom
	end
	return MAX_GEN_Y - a.below_top
end

local SurfaceSystem = {}
SurfaceSystem.__index = SurfaceSystem

-- gen: ChunkGenerator (rs, biomes, registry, fill.prelim)
function SurfaceSystem.new(gen: any)
	local rs = gen.rs
	local registry = gen.registry
	local biomes = gen.biomes
	local prelim = gen.fill.prelim

	local system: any = setmetatable({ gen = gen }, SurfaceSystem)

	-- shared mutable context (one column / one block at a time)
	local ctx = {
		chunk = nil :: any,
		blockX = 0, blockY = 0, blockZ = 0,
		surfaceDepth = 0,
		stoneDepthAbove = 0, stoneDepthBelow = 0,
		waterHeight = NO_WATER,
		xzVersion = 0, yVersion = 0,
		secondaryV = -1, secondary = 0,
		steepV = -1, steep = false,
		minSurfaceV = -1, minSurface = 0,
		biomeV = -1, biomeId = 0,
	}
	system.ctx = ctx

	local surfaceNoise = rs:getNoise("surface")
	local secondaryNoise = rs:getNoise("surface_secondary")
	local clayBandsOffset = rs:getNoise("clay_bands_offset")
	local badlandsSurface = rs:getNoise("badlands_surface")
	local badlandsPillar = rs:getNoise("badlands_pillar")
	local badlandsPillarRoof = rs:getNoise("badlands_pillar_roof")
	local icebergSurface = rs:getNoise("iceberg_surface")
	local icebergPillar = rs:getNoise("iceberg_pillar")
	local icebergPillarRoof = rs:getNoise("iceberg_pillar_roof")

	-- ---------------------------------------------------------------- clay bands
	local bandRandom = rs.random:fromHashOf("minecraft:clay_bands")
	local TERRACOTTA = Blocks.ids.terracotta
	local bands = table.create(192, TERRACOTTA)
	do
		local k1 = 0
		while k1 < 192 do
			k1 += bandRandom:nextInt(5) + 1
			if k1 < 192 then
				bands[k1 + 1] = Blocks.ids.orange_terracotta
			end
			k1 += 1
		end
		local function makeBands(minSize: number, block: number)
			local n = bandRandom:nextIntBetweenInclusive(6, 15)
			for _ = 1, n do
				local k = minSize + bandRandom:nextInt(3)
				local l = bandRandom:nextInt(192)
				local i1 = 0
				while l + i1 < 192 and i1 < k do
					bands[l + i1 + 1] = block
					i1 += 1
				end
			end
		end
		makeBands(1, Blocks.ids.yellow_terracotta)
		makeBands(2, Blocks.ids.brown_terracotta)
		makeBands(1, Blocks.ids.red_terracotta)
		local i = bandRandom:nextIntBetweenInclusive(9, 15)
		local j, k = 0, 0
		while j < i and k < 192 do
			bands[k + 1] = Blocks.ids.white_terracotta
			if k - 1 > 0 then
				bands[k] = Blocks.ids.light_gray_terracotta
			end
			if k + 1 < 192 then
				bands[k + 2] = Blocks.ids.light_gray_terracotta
			end
			j += 1
			k += bandRandom:nextInt(16) + 4
		end
	end
	local function getBand(x: number, y: number, z: number): number
		local i = floor(clayBandsOffset:getValue(x, 0, z) * 4.0 + 0.5) -- Math.round
		return bands[(y + i + 192) % 192 + 1]
	end

	-- ---------------------------------------------------------------- lazies
	local function getSecondary(): number
		if ctx.secondaryV ~= ctx.xzVersion then
			ctx.secondaryV = ctx.xzVersion
			ctx.secondary = secondaryNoise:getValue(ctx.blockX, 0, ctx.blockZ)
		end
		return ctx.secondary
	end

	local function getSteep(): boolean
		if ctx.steepV ~= ctx.xzVersion then
			ctx.steepV = ctx.xzVersion
			local topY = ctx.chunk.topY
			local i, j = ctx.blockX % 16, ctx.blockZ % 16
			local k, l = max(j - 1, 0), min(j + 1, 15)
			local i1 = topY[i * 16 + l + 1]
			local j1 = topY[i * 16 + k + 1]
			if i1 >= j1 + 4 then
				ctx.steep = true
			else
				local k1, l1 = max(i - 1, 0), min(i + 1, 15)
				local i2 = topY[k1 * 16 + j + 1]
				local j2 = topY[l1 * 16 + j + 1]
				ctx.steep = i2 >= j2 + 4
			end
		end
		return ctx.steep
	end

	local function getMinSurfaceLevel(): number
		if ctx.minSurfaceV ~= ctx.xzVersion then
			ctx.minSurfaceV = ctx.xzVersion
			local bx, bz = ctx.blockX, ctx.blockZ
			local i, j = bx - bx % 16, bz - bz % 16
			local p00, p10 = prelim(i, j), prelim(i + 16, j)
			local p01, p11 = prelim(i, j + 16), prelim(i + 16, j + 16)
			local dx, dz = (bx % 16) / 16, (bz % 16) / 16
			local a = p00 + dx * (p10 - p00)
			local b = p01 + dx * (p11 - p01)
			ctx.minSurface = floor(a + dz * (b - a)) + ctx.surfaceDepth - 8
		end
		return ctx.minSurface
	end

	local function getBiome(): number
		if ctx.biomeV ~= ctx.yVersion then
			ctx.biomeV = ctx.yVersion
			ctx.biomeId = registry.base[biomes:getBiome(ctx.blockX, ctx.blockY, ctx.blockZ)]
		end
		return ctx.biomeId
	end

	-- ---------------------------------------------------------------- rule compiler
	local compileRule: (any) -> () -> number?
	local compileCond: (any) -> () -> boolean

	compileCond = function(c: any): () -> boolean
		local t = c.type
		if t == "not" then
			local inner = compileCond(c.invert)
			return function()
				return not inner()
			end
		elseif t == "above_preliminary_surface" then
			return function()
				return ctx.blockY >= getMinSurfaceLevel()
			end
		elseif t == "stone_depth" then
			local offset, addSurface, range = c.offset, c.add_surface_depth, c.secondary_depth_range
			local ceiling = c.surface_type == "ceiling"
			return function()
				local i = ceiling and ctx.stoneDepthBelow or ctx.stoneDepthAbove
				local j = addSurface and ctx.surfaceDepth or 0
				local k = 0
				if range ~= 0 then
					local v = getSecondary()
					k = trunc((v + 1) / 2 * range)
				end
				return i <= 1 + offset + j + k
			end
		elseif t == "water" then
			local offset, mult, addStone = c.offset, c.surface_depth_multiplier, c.add_stone_depth
			return function()
				local wh = ctx.waterHeight
				if wh == NO_WATER then
					return true
				end
				return ctx.blockY + (addStone and ctx.stoneDepthAbove or 0) >= wh + offset + trunc(ctx.surfaceDepth * mult)
			end
		elseif t == "y_above" then
			local y0, mult, addStone = anchorY(c.anchor), c.surface_depth_multiplier, c.add_stone_depth
			return function()
				return ctx.blockY + (addStone and ctx.stoneDepthAbove or 0) >= y0 + trunc(ctx.surfaceDepth * mult)
			end
		elseif t == "biome" then
			local set: { [number]: boolean } = {}
			for _, name in c.biome_is do
				local id = registry.ids[name]
				assert(id, "unknown biome in surface rule: " .. name)
				set[id] = true
			end
			return function()
				return set[getBiome()] == true
			end
		elseif t == "noise_threshold" then
			local nz = rs:getNoise(c.noise)
			local lo, hi = c.min_threshold, c.max_threshold
			return function()
				local v = nz:getValue(ctx.blockX, 0, ctx.blockZ)
				return v >= lo and v <= hi
			end
		elseif t == "vertical_gradient" then
			local factory = rs:getRandomFactory(c.random_name)
			local trueAt, falseAt = anchorY(c.true_at_and_below), anchorY(c.false_at_and_above)
			return function()
				local y = ctx.blockY
				if y <= trueAt then
					return true
				elseif y >= falseAt then
					return false
				end
				local d = 1.0 - (y - trueAt) / (falseAt - trueAt)
				return factory:at(ctx.blockX, y, ctx.blockZ):nextFloat() < d
			end
		elseif t == "steep" then
			return getSteep
		elseif t == "hole" then
			return function()
				return ctx.surfaceDepth <= 0
			end
		elseif t == "temperature" then
			return function()
				local id = getBiome()
				return BiomeTemperature.coldEnoughToSnow(registry.data[id], ctx.blockX, ctx.blockY, ctx.blockZ)
			end
		end
		error("unsupported surface condition: " .. tostring(t))
	end

	compileRule = function(r: any): () -> number?
		local t = r.type
		if t == "block" then
			local id = Blocks.ids[r.result_state]
			assert(id, "surface rule uses unregistered block: " .. tostring(r.result_state))
			return function()
				return id
			end
		elseif t == "sequence" then
			local list = {}
			for _, sub in r.sequence do
				table.insert(list, compileRule(sub))
			end
			local n = #list
			return function()
				for i = 1, n do
					local v = list[i]()
					if v then
						return v
					end
				end
				return nil
			end
		elseif t == "condition" then
			local cond, rule = compileCond(r.if_true), compileRule(r.then_run)
			return function()
				if cond() then
					return rule()
				end
				return nil
			end
		elseif t == "bandlands" then
			return function()
				return getBand(ctx.blockX, ctx.blockY, ctx.blockZ)
			end
		end
		error("unsupported surface rule: " .. tostring(t))
	end

	local rule = compileRule(Rules)

	-- ---------------------------------------------------------------- column helpers
	local noiseRandom = rs.random

	local function getSurfaceDepth(x: number, z: number): number
		local d0 = surfaceNoise:getValue(x, 0, z)
		return trunc(d0 * 2.75 + 3.0 + noiseRandom:at(x, 0, z):nextDouble() * 0.25)
	end

	local function erodedBadlandsExtension(chunk: any, x: number, z: number, height: number)
		local blocks = chunk.blocks
		local col = ((x % 16) * 16 + (z % 16))
		local base = col * HEIGHT - MIN_Y
		local d1 = min(abs(badlandsSurface:getValue(x, 0, z) * 8.25), badlandsPillar:getValue(x * 0.2, 0, z * 0.2) * 15.0)
		if d1 > 0 then
			local d4 = abs(badlandsPillarRoof:getValue(x * 0.75, 0, z * 0.75) * 1.5)
			local d5 = 64.0 + min(d1 * d1 * 2.5, ceil(d4 * 50.0) + 24.0)
			local i = floor(d5)
			if height <= i then
				for j = i, MIN_Y, -1 do
					local b = buffer.readu8(blocks, base + j)
					if b == STONE then
						break
					end
					if b == WATER then
						return
					end
				end
				local k = i
				while k >= MIN_Y and buffer.readu8(blocks, base + k) == AIR do
					buffer.writeu8(blocks, base + k, STONE)
					if chunk.occ then
						buffer.writeu8(chunk.occ, base + k, 255)
					end
					if k > chunk.topY[col + 1] then
						chunk.topY[col + 1] = k
					end
					k -= 1
				end
			end
		end
	end

	local function frozenOceanExtension(chunk: any, minSurfaceLevel: number, biomeData: any, x: number, z: number, height: number)
		local blocks = chunk.blocks
		local col = ((x % 16) * 16 + (z % 16))
		local base = col * HEIGHT - MIN_Y
		local d1 = min(abs(icebergSurface:getValue(x, 0, z) * 8.25), icebergPillar:getValue(x * 1.28, 0, z * 1.28) * 15.0)
		if d1 <= 1.8 then
			return
		end
		local d4 = abs(icebergPillarRoof:getValue(x * 1.17, 0, z * 1.17) * 1.5)
		local d5 = min(d1 * d1 * 1.2, ceil(d4 * 40.0) + 14.0)
		if BiomeTemperature.at(biomeData, x, 63, z) > 0.1 then
			d5 -= 2.0
		end
		local d6
		if d5 > 2.0 then
			d6 = SEA - d5 - 7.0
			d5 += SEA
		else
			d5 = 0.0
			d6 = 0.0
		end
		local d7 = d5
		local r = noiseRandom:at(x, 0, z)
		local i = 2 + r:nextInt(4)
		local j = SEA + 18 + r:nextInt(10)
		local k = 0
		for l = max(height, trunc(d5) + 1), minSurfaceLevel, -1 do
			local b = buffer.readu8(blocks, base + l)
			if (b == AIR and l < trunc(d7) and r:nextDouble() > 0.01) or (b == WATER and l > trunc(d6) and l < SEA and d6 ~= 0.0 and r:nextDouble() > 0.15) then
				if k <= i and l > j then
					buffer.writeu8(blocks, base + l, Blocks.ids.snow_block)
					k += 1
				else
					buffer.writeu8(blocks, base + l, Blocks.ids.packed_ice)
				end
				if chunk.occ then
					buffer.writeu8(chunk.occ, base + l, 255)
				end
				if l > chunk.topY[col + 1] then
					chunk.topY[col + 1] = l
				end
			end
		end
	end

	-- ---------------------------------------------------------------- public: build the surface of a chunk
	local overrideCache: { [number]: { top: number?, filler: number?, depth: number } } = {}
	for id, def in registry.custom do
		if def.surface then
			overrideCache[id] = {
				top = def.surface.top and Blocks.ids[def.surface.top],
				filler = def.surface.filler and Blocks.ids[def.surface.filler],
				depth = def.surface.fillerDepth or 3,
			}
		end
	end
	local softSoil: { [number]: boolean } = {}
	for _, n in { "grass_block", "dirt", "coarse_dirt", "podzol", "mycelium", "sand", "red_sand", "gravel", "mud", "snow_block" } do
		softSoil[Blocks.ids[n]] = true
	end

	function system.build(self: any, chunk: any)
		ctx.chunk = chunk
		local blocks = chunk.blocks
		local topY = chunk.topY
		local minX, minZ = chunk.cx * 16, chunk.cz * 16
		local biomeTop = chunk.biomeTop
		for x = 0, 15 do
			for z = 0, 15 do
				local col = x * 16 + z
				local bx, bz = minX + x, minZ + z
				local base = col * HEIGHT - MIN_Y
				local k1 = topY[col + 1] + 1
				local biomeId = biomes:getBiome(bx, k1, bz)
				local baseId = registry.base[biomeId]
				biomeTop[col + 1] = biomeId
				local biomeName = registry.names[baseId]
				if biomeName == "eroded_badlands" then
					erodedBadlandsExtension(chunk, bx, bz, k1)
				end
				local l1 = topY[col + 1] + 1

				ctx.xzVersion += 1
				ctx.yVersion += 1
				ctx.blockX, ctx.blockZ = bx, bz
				ctx.surfaceDepth = getSurfaceDepth(bx, bz)

				local i2, j2, k2 = 0, NO_WATER, math.huge
				local override = overrideCache[biomeId]
				for i3 = l1, MIN_Y, -1 do
					local b = buffer.readu8(blocks, base + i3)
					if b == AIR then
						i2, j2 = 0, NO_WATER
					elseif b == WATER or b == LAVA then
						if j2 == NO_WATER then
							j2 = i3 + 1
						end
					else
						if k2 >= i3 then
							k2 = -1e9
							for l3 = i3 - 1, MIN_Y - 1, -1 do
								local b1 = l3 < MIN_Y and AIR or buffer.readu8(blocks, base + l3)
								if b1 == AIR or b1 == WATER or b1 == LAVA then
									k2 = l3 + 1
									break
								end
							end
						end
						i2 += 1
						ctx.yVersion += 1
						ctx.blockY = i3
						ctx.stoneDepthAbove = i2
						ctx.stoneDepthBelow = i3 - k2 + 1
						ctx.waterHeight = j2
						if b == STONE then
							local r = rule()
							if r then
								if override and softSoil[r] then
									if i2 == 1 and override.top then
										r = override.top
									elseif i2 > 1 and i2 <= override.depth + 1 and override.filler then
										r = override.filler
									end
								end
								buffer.writeu8(blocks, base + i3, r)
							end
						end
					end
				end
				if biomeName == "frozen_ocean" or biomeName == "deep_frozen_ocean" then
					frozenOceanExtension(chunk, getMinSurfaceLevel(), registry.data[baseId], bx, bz, k1)
				end
			end
		end
	end

	return system
end

return SurfaceSystem
