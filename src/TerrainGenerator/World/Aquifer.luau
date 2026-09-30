--!strict
--!native
-- Port of NoiseBasedChunkGenerator's NoiseBasedAquifer: decides, for every non-solid voxel, whether it is
-- air, water or lava, using a jittered grid of "aquifer" cells (16 x 12 x 16 blocks), per-cell fluid levels
-- and a barrier noise that seals differing fluid levels off from each other.

local Blocks = require(script.Parent.Blocks)

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local AIR, WATER, LAVA = Blocks.AIR, Blocks.WATER, Blocks.LAVA

local WAY_BELOW_MIN_Y = -134217728 -- Integer.MIN_VALUE >> 4
local GRID_X, GRID_Y, GRID_Z = 16, 12, 16

-- {chunkX, chunkZ} offsets (in sections) sampled for the surface level around a cell
local SURFACE_OFFSETS = {
	{ 0, 0 }, { -2, -1 }, { -1, -1 }, { 0, -1 }, { 1, -1 }, { -3, 0 }, { -2, 0 }, { -1, 0 }, { 1, 0 }, { -2, 1 }, { -1, 1 }, { 0, 1 }, { 1, 1 },
}

type Status = { level: number, block: number }

export type Aquifer = {
	compute: (Aquifer, number, number, number, number) -> number?,
}

local Aquifer = {}
Aquifer.__index = Aquifer

-- ctx: {
--   seaLevel, minY, height,
--   aquiferRandom: PositionalFactory,
--   barrier, floodedness, spread, lava, erosion, depth: (x,y,z)->number,
--   prelim: (x, z) -> preliminary surface level,
-- }
function Aquifer.new(ctx: any): Aquifer
	local seaLevel = ctx.seaLevel
	local self = {
		ctx = ctx,
		seaLevel = seaLevel,
		waterStatus = { level = seaLevel, block = WATER } :: Status,
		lavaStatus = { level = -54, block = LAVA } :: Status,
		lavaBelow = min(-54, seaLevel),
		locX = {} :: { [number]: number },
		locY = {} :: { [number]: number },
		locZ = {} :: { [number]: number },
		status = {} :: { [number]: Status },
		skipY = math.huge, -- above this y everything non-solid is the global fluid (air)
	}
	return setmetatable(self, Aquifer) :: any
end

-- y above which the aquifer is guaranteed to yield the global fluid: max level + 5 (see derivation in
-- ChunkGenerator). `maxPrelim` is the highest preliminary surface level within 24 blocks of the chunk.
function Aquifer.setSkipY(self: Aquifer, maxPrelim: number)
	(self :: any).skipY = max((self :: any).seaLevel, maxPrelim) + 5
end

local function key(gx: number, gy: number, gz: number): number
	return ((gx + 1048576) * 2097152 + (gz + 1048576)) * 256 + (gy + 64)
end

function Aquifer.location(self: any, gx: number, gy: number, gz: number): (number, number, number)
	local k = key(gx, gy, gz)
	local x = self.locX[k]
	if x then
		return x, self.locY[k], self.locZ[k]
	end
	local r = self.ctx.aquiferRandom:at(gx, gy, gz)
	x = gx * GRID_X + r:nextInt(10)
	local y = gy * GRID_Y + r:nextInt(9)
	local z = gz * GRID_Z + r:nextInt(10)
	self.locX[k], self.locY[k], self.locZ[k] = x, y, z
	return x, y, z
end

-- FluidPicker for one position: lava below -54, otherwise the sea
local function global(self: any, y: number): Status
	if y < self.lavaBelow then
		return self.lavaStatus
	end
	return self.waterStatus
end

local function at(status: Status, y: number): number
	if y < status.level then
		return status.block
	end
	return AIR
end

-- NoiseBasedAquifer.computeFluid(x, y, z): the fluid level/type of the aquifer centred on (x, y, z)
local function computeFluid(self: any, x: number, y: number, z: number): Status
	local ctx = self.ctx
	local g = global(self, y)
	local minSurfaceLevel = math.huge
	local upper = y + 12
	local lower = y - 12
	local flag = false
	for i = 1, #SURFACE_OFFSETS do
		local off = SURFACE_OFFSETS[i]
		local sx = x + off[1] * 16
		local sz = z + off[2] * 16
		local surface = ctx.prelim(sx, sz)
		local k1 = surface + 8
		local isCentre = off[1] == 0 and off[2] == 0
		if isCentre and lower > k1 then
			return g
		end
		local above = upper > k1
		if above or isCentre then
			local fs = global(self, k1)
			if at(fs, k1) ~= AIR then
				if isCentre then
					flag = true
				end
				if above then
					return fs
				end
			end
		end
		minSurfaceLevel = min(minSurfaceLevel, surface)
	end

	-- computeSurfaceLevel
	local d0, d1
	local erosion, depth = ctx.erosion(x, y, z), ctx.depth(x, y, z)
	if erosion < -0.225 and depth > 0.9 then -- OverworldBiomeBuilder.isDeepDarkRegion
		d0, d1 = -1.0, -1.0
	else
		local i = minSurfaceLevel + 8 - y
		local d2 = 0.0
		if flag then
			local t = i / 64
			d2 = t < 0 and 1.0 or (t > 1 and 0.0 or 1.0 + t * (0.0 - 1.0))
		end
		local d3 = ctx.floodedness(x, y, z)
		d3 = d3 < -1 and -1 or (d3 > 1 and 1 or d3)
		local d4 = -0.3 + (1.0 - d2) * (0.8 - -0.3) -- map(d2, 1.0, 0.0, -0.3, 0.8)
		local d5 = -0.8 + (1.0 - d2) * (0.4 - -0.8) -- map(d2, 1.0, 0.0, -0.8, 0.4)
		d0 = d3 - d5
		d1 = d3 - d4
	end
	local level
	if d1 > 0 then
		level = g.level
	elseif d0 > 0 then
		-- computeRandomizedFluidSurfaceLevel
		local k = floor(x / 16)
		local l = floor(y / 40)
		local i1 = floor(z / 16)
		local j1 = l * 40 + 20
		local spread = ctx.spread(k, l, i1) * 10
		local q = floor(spread / 3) * 3 -- Mth.quantize(d0, 3)
		level = min(minSurfaceLevel, j1 + q)
	else
		level = WAY_BELOW_MIN_Y
	end

	-- computeFluidType
	local block = g.block
	if level <= -10 and level ~= WAY_BELOW_MIN_Y and g.block ~= LAVA then
		local lv = ctx.lava(floor(x / 64), floor(y / 40), floor(z / 64))
		if abs(lv) > 0.3 then
			block = LAVA
		end
	end
	return { level = level, block = block }
end

local function statusAt(self: any, cx: number, cy: number, cz: number): Status
	local k = key(floor(cx / 16), floor(cy / 12), floor(cz / 16))
	local s = self.status[k]
	if s then
		return s
	end
	s = computeFluid(self, cx, cy, cz)
	self.status[k] = s
	return s
end

local function similarity(a: number, b: number): number
	return 1.0 - abs(b - a) / 25.0
end

-- NoiseBasedAquifer.calculatePressure
local function pressure(self: any, x: number, y: number, z: number, barrierBox: { number }, s1: Status, s2: Status): number
	local b1, b2 = at(s1, y), at(s2, y)
	if (b1 ~= LAVA or b2 ~= WATER) and (b1 ~= WATER or b2 ~= LAVA) then
		local j = abs(s1.level - s2.level)
		if j == 0 then
			return 0.0
		end
		local d0 = 0.5 * (s1.level + s2.level)
		local d1 = y + 0.5 - d0
		local d2 = j / 2.0
		local d9 = d2 - abs(d1)
		local d10
		if d1 > 0.0 then
			local d11 = 0.0 + d9
			d10 = d11 > 0.0 and d11 / 1.5 or d11 / 2.5
		else
			local d12 = 3.0 + d9
			d10 = d12 > 0.0 and d12 / 3.0 or d12 / 10.0
		end
		local d14
		if not (d10 < -2.0) and not (d10 > 2.0) then
			local cached = barrierBox[1]
			if cached ~= cached then -- NaN: not computed yet
				cached = self.ctx.barrier(x, y, z)
				barrierBox[1] = cached
			end
			d14 = cached
		else
			d14 = 0.0
		end
		return 2.0 * (d14 + d10)
	end
	return 2.0
end

-- Returns the block (AIR/WATER/LAVA) for a non-solid voxel, or nil when the voxel should be solid.
function Aquifer.compute(self: Aquifer, x: number, y: number, z: number, density: number): number?
	if density > 0 then
		return nil
	end
	local s = self :: any
	if y > s.skipY then
		return AIR
	end
	if y < s.lavaBelow then
		return LAVA
	end

	local l = floor((x - 5) / 16)
	local i1 = floor((y + 1) / 12)
	local j1 = floor((z - 5) / 16)
	local k1, l1, i2, j2 = math.huge, math.huge, math.huge, math.huge
	local x1, y1, z1, x2, y2, z2, x3, y3, z3 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for a = 0, 1 do
		for b = -1, 1 do
			for c = 0, 1 do
				local px, py, pz = Aquifer.location(s, l + a, i1 + b, j1 + c)
				local dx, dy, dz = px - x, py - y, pz - z
				local dist = dx * dx + dy * dy + dz * dz
				if k1 >= dist then
					x3, y3, z3 = x2, y2, z2
					x2, y2, z2 = x1, y1, z1
					x1, y1, z1 = px, py, pz
					j2, i2, l1, k1 = i2, l1, k1, dist
				elseif l1 >= dist then
					x3, y3, z3 = x2, y2, z2
					x2, y2, z2 = px, py, pz
					j2, i2, l1 = i2, l1, dist
				elseif i2 >= dist then
					x3, y3, z3 = px, py, pz
					j2, i2 = i2, dist
				elseif j2 >= dist then
					j2 = dist
				end
			end
		end
	end
	-- NOTE: vanilla keeps the 4 closest; only the first three centres are used below.
	local statusA = statusAt(s, x1, y1, z1)
	local d1 = similarity(k1, l1)
	local blockA = at(statusA, y)
	if d1 <= 0.0 then
		return blockA
	end
	if blockA == WATER and at(global(s, y - 1), y - 1) == LAVA then
		return blockA
	end
	local barrier = { 0 / 0 }
	local statusB = statusAt(s, x2, y2, z2)
	local d2 = d1 * pressure(s, x, y, z, barrier, statusA, statusB)
	if density + d2 > 0.0 then
		return nil
	end
	local statusC = statusAt(s, x3, y3, z3)
	local d3 = similarity(k1, i2)
	if d3 > 0.0 then
		local d4 = d1 * d3 * pressure(s, x, y, z, barrier, statusA, statusC)
		if density + d4 > 0.0 then
			return nil
		end
	end
	local d5 = similarity(l1, i2)
	if d5 > 0.0 then
		local d6 = d1 * d5 * pressure(s, x, y, z, barrier, statusB, statusC)
		if density + d6 > 0.0 then
			return nil
		end
	end
	return blockA
end

return Aquifer
