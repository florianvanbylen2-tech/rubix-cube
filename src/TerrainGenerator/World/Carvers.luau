--!strict
--!native
-- Port of the classic carvers (CaveWorldCarver, CanyonWorldCarver, WorldCarver.carveEllipsoid) and the
-- CarvingMask, driven by java.util.Random exactly as vanilla does: every chunk replays the carvers of the
-- 17 x 17 chunks around it.

local Int64 = require(script.Parent.Parent.Core.Int64)
local JavaRandom = require(script.Parent.Parent.Core.JavaRandom)
local CarverData = require(script.Parent.Parent.Data.Carvers)
local Settings = require(script.Parent.Parent.Data.Settings)
local Blocks = require(script.Parent.Blocks)
local Providers = require(script.Parent.Providers)

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local MAX_GEN_Y = MIN_Y + HEIGHT - 1
local PI = math.pi
local AIR, WATER, LAVA = Blocks.AIR, Blocks.WATER, Blocks.LAVA
local RANGE = 4

-- Mth.sin / Mth.cos: 65536-entry float table
local SIN = table.create(65536, 0)
do
	local buf = buffer.create(4)
	for i = 0, 65535 do
		buffer.writef32(buf, 0, math.sin(i * PI * 2.0 / 65536.0))
		SIN[i + 1] = buffer.readf32(buf, 0)
	end
end
local function trunc(v: number): number
	return v >= 0 and floor(v) or -floor(-v)
end
local function sin(v: number): number
	return SIN[trunc(v * 10430.378) % 65536 + 1]
end
local function cos(v: number): number
	return SIN[trunc(v * 10430.378 + 16384.0) % 65536 + 1]
end

-- overworld_carver_replaceables (blocks our registry can hold)
local REPLACEABLE = buffer.create(256)
for _, n in {
	"stone", "deepslate", "granite", "diorite", "andesite", "tuff", "dirt", "grass_block", "podzol", "coarse_dirt",
	"mycelium", "mud", "moss_block", "sand", "red_sand", "terracotta", "orange_terracotta", "yellow_terracotta",
	"brown_terracotta", "red_terracotta", "white_terracotta", "light_gray_terracotta", "water", "gravel",
	"sandstone", "red_sandstone", "calcite", "packed_ice",
} do
	buffer.writeu8(REPLACEABLE, Blocks.ids[n], 1)
end

local Carvers = {}

-- Runs all carvers for `chunk`. gen: ChunkGenerator; chunk.aquifer must be set by the noise stage.
function Carvers.carve(gen: any, chunk: any)
	local rs = gen.rs
	local aquifer = chunk.aquifer
	local blocks = chunk.blocks
	local cx0, cz0 = chunk.cx, chunk.cz
	local minX, minZ = cx0 * 16, cz0 * 16
	local mask = buffer.create(256 * HEIGHT)
	local occ = chunk.occ
	local carved: { number } = {}
	local random = JavaRandom.new(0, 0)

	-- all overworld biomes use the same carver list (verified against the data)
	local list = gen.registry.data[1].carvers

	local function carveBlock(lx: number, y: number, lz: number, lavaLevel: number, reached: { boolean }): boolean
		local idx = (lx * 16 + lz) * HEIGHT + (y - MIN_Y)
		local b = buffer.readu8(blocks, idx)
		if b == Blocks.ids.grass_block or b == Blocks.ids.mycelium then
			reached[1] = true
		end
		if buffer.readu8(REPLACEABLE, b) == 0 then
			return false
		end
		local newBlock: number?
		if y <= lavaLevel then
			newBlock = LAVA
		else
			newBlock = aquifer:compute(minX + lx, y, minZ + lz, 0.0)
		end
		if newBlock == nil then
			return false
		end
		buffer.writeu8(blocks, idx, newBlock)
		if occ then
			buffer.writeu8(occ, idx, newBlock == AIR and 0 or 255)
			carved[#carved + 1] = idx
		end
		if reached[1] and y > MIN_Y then
			local below = idx - 1
			if buffer.readu8(blocks, below) == Blocks.ids.dirt and newBlock == AIR then
				-- re-grass the exposed dirt (ctx.topMaterial in vanilla)
				buffer.writeu8(blocks, below, b)
			end
		end
		return true
	end

	-- carveEllipsoid; skip(relX, relY, relZ, y) -> boolean
	local function carveEllipsoid(x: number, y: number, z: number, hr: number, vr: number, lavaLevel: number, skip: (number, number, number, number) -> boolean)
		local d0, d1 = minX + 8, minZ + 8
		local d2 = 16.0 + hr * 2.0
		if abs(x - d0) > d2 or abs(z - d1) > d2 then
			return
		end
		local k = max(floor(x - hr) - minX - 1, 0)
		local l = min(floor(x + hr) - minX, 15)
		local i1 = max(floor(y - vr) - 1, MIN_Y + 1)
		local k1 = min(floor(y + vr) + 1, MAX_GEN_Y - 7)
		local l1 = max(floor(z - hr) - minZ - 1, 0)
		local i2 = min(floor(z + hr) - minZ, 15)
		for j2 = k, l do
			local d3 = ((minX + j2) + 0.5 - x) / hr
			for l2 = l1, i2 do
				local d4 = ((minZ + l2) + 0.5 - z) / hr
				if not (d3 * d3 + d4 * d4 >= 1.0) then
					local reached = { false }
					for j3 = k1, i1 + 1, -1 do
						local d5 = (j3 - 0.5 - y) / vr
						if not skip(d3, d5, d4, j3) then
							local mi = (j2 * 16 + l2) * HEIGHT + (j3 - MIN_Y)
							if buffer.readu8(mask, mi) == 0 then
								buffer.writeu8(mask, mi, 1)
								carveBlock(j2, j3, l2, lavaLevel, reached)
							end
						end
					end
				end
			end
		end
	end

	local function canReach(x: number, z: number, step: number, total: number, thickness: number): boolean
		local d2, d3 = x - (minX + 8), z - (minZ + 8)
		local d4 = total - step
		local d5 = thickness + 2.0 + 16.0
		return d2 * d2 + d3 * d3 - d4 * d4 <= d5 * d5
	end

	-- ------------------------------------------------------------ caves
	local function caveThickness(r: any): number
		local f = r:nextFloat() * 2.0 + r:nextFloat()
		if r:nextInt(10) == 0 then
			f *= r:nextFloat() * r:nextFloat() * 3.0 + 1.0
		end
		return f
	end

	local function createTunnel(cfg: any, seedH: number, seedL: number, x: number, y: number, z: number, hm: number, vm: number, thickness: number, yaw: number, pitch: number, step: number, distance: number, ratio: number, floorLevel: number, lavaLevel: number)
		local r = JavaRandom.new(seedH, seedL)
		local i = r:nextInt(distance // 2) + distance // 4
		local flag = r:nextInt(6) == 0
		local f, f1 = 0.0, 0.0
		local skip = function(rx: number, ry: number, rz: number, _y: number): boolean
			if ry <= floorLevel then
				return true
			end
			return rx * rx + ry * ry + rz * rz >= 1.0
		end
		for j = step, distance - 1 do
			local d0 = 1.5 + sin(PI * j / distance) * thickness
			local d1 = d0 * ratio
			local f2 = cos(pitch)
			x += cos(yaw) * f2
			y += sin(pitch)
			z += sin(yaw) * f2
			pitch *= flag and 0.92 or 0.7
			pitch += f1 * 0.1
			yaw += f * 0.1
			f1 *= 0.9
			f *= 0.75
			f1 += (r:nextFloat() - r:nextFloat()) * r:nextFloat() * 2.0
			f += (r:nextFloat() - r:nextFloat()) * r:nextFloat() * 4.0
			if j == i and thickness > 1.0 then
				local sh1, sl1 = r:nextLong()
				local t1 = r:nextFloat() * 0.5 + 0.5
				createTunnel(cfg, sh1, sl1, x, y, z, hm, vm, t1, yaw - PI / 2, pitch / 3.0, j, distance, 1.0, floorLevel, lavaLevel)
				local sh2, sl2 = r:nextLong()
				local t2 = r:nextFloat() * 0.5 + 0.5
				createTunnel(cfg, sh2, sl2, x, y, z, hm, vm, t2, yaw + PI / 2, pitch / 3.0, j, distance, 1.0, floorLevel, lavaLevel)
				return
			end
			if r:nextInt(4) ~= 0 then
				if not canReach(x, z, j, distance, thickness) then
					return
				end
				carveEllipsoid(x, y, z, d0 * hm, d1 * vm, lavaLevel, skip)
			end
		end
	end

	local function carveCave(cfg: any, ncx: number, ncz: number)
		local nminX, nminZ = ncx * 16, ncz * 16
		local i = (RANGE * 2 - 1) * 16
		local lavaLevel = Providers.anchor(cfg.lava_level)
		local j = random:nextInt(random:nextInt(random:nextInt(15) + 1) + 1)
		for _ = 1, j do
			local d0 = nminX + random:nextInt(16)
			local d1 = Providers.height(cfg.y, random)
			local d2 = nminZ + random:nextInt(16)
			local d3 = Providers.float(cfg.horizontal_radius_multiplier, random)
			local d4 = Providers.float(cfg.vertical_radius_multiplier, random)
			local d5 = Providers.float(cfg.floor_level, random)
			local l = 1
			if random:nextInt(4) == 0 then
				local d6 = Providers.float(cfg.yScale, random)
				local f1 = 1.0 + random:nextFloat() * 6.0
				-- createRoom
				local r0 = 1.5 + sin(PI / 2) * f1
				local skip = function(rx: number, ry: number, rz: number, _y: number): boolean
					if ry <= d5 then
						return true
					end
					return rx * rx + ry * ry + rz * rz >= 1.0
				end
				carveEllipsoid(d0 + 1.0, d1, d2, r0, r0 * d6, lavaLevel, skip)
				l += random:nextInt(4)
			end
			for _ = 1, l do
				local f = random:nextFloat() * (PI * 2)
				local f3 = (random:nextFloat() - 0.5) / 4.0
				local f2 = caveThickness(random)
				local i1 = i - random:nextInt(i // 4)
				local sh, sl = random:nextLong()
				createTunnel(cfg, sh, sl, d0, d1, d2, d3, d4, f2, f, f3, 0, i1, 1.0, d5, lavaLevel)
			end
		end
	end

	-- ------------------------------------------------------------ canyons
	local function carveCanyon(cfg: any, ncx: number, ncz: number)
		local nminX, nminZ = ncx * 16, ncz * 16
		local lavaLevel = Providers.anchor(cfg.lava_level)
		local i = (RANGE * 2 - 1) * 16
		local x = nminX + random:nextInt(16)
		local y = Providers.height(cfg.y, random)
		local z = nminZ + random:nextInt(16)
		local yaw = random:nextFloat() * (PI * 2)
		local pitch = Providers.float(cfg.vertical_rotation, random)
		local yScale = Providers.float(cfg.yScale, random)
		local thickness = Providers.float(cfg.shape.thickness, random)
		local distance = trunc(i * Providers.float(cfg.shape.distance_factor, random))
		local sh, sl = random:nextLong()

		local shape = cfg.shape
		local r = JavaRandom.new(sh, sl)
		-- initWidthFactors
		local widthFactors = table.create(HEIGHT, 1.0)
		do
			local f = 1.0
			for j = 0, HEIGHT - 1 do
				if j == 0 or r:nextInt(shape.width_smoothness) == 0 then
					f = 1.0 + r:nextFloat() * r:nextFloat()
				end
				widthFactors[j + 1] = f * f
			end
		end
		local skip = function(rx: number, ry: number, rz: number, yy: number): boolean
			local idx = yy - MIN_Y
			return (rx * rx + rz * rz) * widthFactors[idx] + ry * ry / 6.0 >= 1.0
		end
		local f, f1 = 0.0, 0.0
		for step = 0, distance - 1 do
			local d0 = 1.5 + sin(step * PI / distance) * thickness
			local d1 = d0 * yScale
			d0 *= Providers.float(shape.horizontal_radius_factor, r)
			-- updateVerticalRadius
			local fr = 1.0 - abs(0.5 - step / distance) * 2.0
			local f1v = shape.vertical_radius_default_factor + shape.vertical_radius_center_factor * fr
			d1 = f1v * d1 * (r:nextFloat() * 0.25 + 0.75)
			local f2 = cos(pitch)
			local f3 = sin(pitch)
			x += cos(yaw) * f2
			y += f3
			z += sin(yaw) * f2
			pitch *= 0.7
			pitch += f1 * 0.05
			yaw += f * 0.05
			f1 *= 0.8
			f *= 0.5
			f1 += (r:nextFloat() - r:nextFloat()) * r:nextFloat() * 2.0
			f += (r:nextFloat() - r:nextFloat()) * r:nextFloat() * 4.0
			if r:nextInt(4) ~= 0 then
				if not canReach(x, z, step, distance, thickness) then
					return
				end
				carveEllipsoid(x, y, z, d0, d1, lavaLevel, skip)
			end
		end
	end

	-- ------------------------------------------------------------ driver
	local sh, sl = rs.seedH, rs.seedL
	chunk.carvedList = carved
	for j = -RANGE * 2, RANGE * 2 do
		for k = -RANGE * 2, RANGE * 2 do
			local ncx, ncz = cx0 + j, cz0 + k
			for l, name in list do
				local carver = CarverData[name]
				local cfg = carver.config
				local bh, bl = Int64.add(sh, sl, 0, l - 1)
				random:setLargeFeatureSeed(bh, bl, ncx, ncz)
				if random:nextFloat() <= cfg.probability then
					if carver.type == "cave" then
						carveCave(cfg, ncx, ncz)
					else
						carveCanyon(cfg, ncx, ncz)
					end
				end
			end
		end
	end
end

-- Smooths occupancy around carved voxels: a 7-point box blur of the block solidity (neighbours outside
-- the chunk are assumed equal to the voxel itself, so chunk borders simply stay unsmoothed).
function Carvers.smoothCarved(chunk: any, carved: { number })
	local blocks, occ = chunk.blocks, chunk.occ
	local total = 256 * HEIGHT
	local marked = buffer.create(total)
	local todo: { number } = {}
	local function mark(i: number)
		if i >= 0 and i < total and buffer.readu8(marked, i) == 0 then
			buffer.writeu8(marked, i, 1)
			todo[#todo + 1] = i
		end
	end
	for _, i in carved do
		mark(i)
		mark(i - 1)
		mark(i + 1)
		mark(i - HEIGHT)
		mark(i + HEIGHT)
		mark(i - 16 * HEIGHT)
		mark(i + 16 * HEIGHT)
	end
	local function solid(i: number, fallback: number): number
		if i < 0 or i >= total then
			return fallback
		end
		local b = buffer.readu8(blocks, i)
		return (b ~= AIR and b ~= WATER and b ~= LAVA) and 1 or 0
	end
	for _, i in todo do
		local b = buffer.readu8(blocks, i)
		if b ~= WATER and b ~= LAVA then
			local col = i // HEIGHT
			local y = i - col * HEIGHT
			local x, z = col // 16, col % 16
			local self0 = (b ~= AIR) and 1 or 0
			local sum = 2 * self0
			sum += (y > 0) and solid(i - 1, self0) or self0
			sum += (y < HEIGHT - 1) and solid(i + 1, self0) or self0
			sum += (x > 0) and solid(i - HEIGHT * 16, self0) or self0
			sum += (x < 15) and solid(i + HEIGHT * 16, self0) or self0
			sum += (z > 0) and solid(i - HEIGHT, self0) or self0
			sum += (z < 15) and solid(i + HEIGHT, self0) or self0
			local v = floor(sum / 8 * 255 + 0.5)
			local cur = buffer.readu8(occ, i)
			if b == AIR then
				if v > cur then
					buffer.writeu8(occ, i, v)
				end
			elseif v < cur then
				buffer.writeu8(occ, i, v)
			end
		end
	end
end

-- Recomputes both heightmaps by scanning each column down from the highest possible block.
function Carvers.recomputeHeightmaps(chunk: any)
	local blocks = chunk.blocks
	local topY, floorY = chunk.topY, chunk.floorY
	local startY = MIN_Y
	for i = 1, 256 do
		if topY[i] > startY then
			startY = topY[i]
		end
	end
	for col = 0, 255 do
		local base = col * HEIGHT - MIN_Y
		local top, floor_ = MIN_Y - 1, MIN_Y - 1
		for y = startY, MIN_Y, -1 do
			local b = buffer.readu8(blocks, base + y)
			if b ~= AIR then
				if top < MIN_Y then
					top = y
				end
				if b ~= WATER and b ~= LAVA then
					floor_ = y
					break
				end
			end
		end
		topY[col + 1], floorY[col + 1] = top, floor_
	end
end

return Carvers
