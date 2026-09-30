--!strict
--!native
-- NoiseBasedChunkGenerator.fillFromNoise: turns the interpolated final density into stone / air /
-- water / lava voxels for one 16x16 chunk column, applying aquifers and ore veins.
--
-- Cells (4x8x4 blocks) whose density interval is provably one-signed are bulk filled; only mixed cells
-- (the terrain surface, caves, water, veins) are evaluated voxel by voxel.

local Compiler = require(script.Parent.Parent.Density.Compiler)
local Settings = require(script.Parent.Parent.Data.Settings)
local Blocks = require(script.Parent.Blocks)
local Aquifer = require(script.Parent.Aquifer)
local OreVeins = require(script.Parent.OreVeins)

local floor, max, abs, sqrt = math.floor, math.max, math.abs, math.sqrt

local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local SEA = Settings.seaLevel
local CELL_W, CELL_H = Compiler.CELL_W, Compiler.CELL_H
local CELLS_XZ, CELLS_Y = Compiler.CELLS_XZ, Compiler.CELLS_Y
local AIR, STONE, WATER = Blocks.AIR, Blocks.STONE, Blocks.WATER

local NoiseFill = {}

export type Filler = {
	generator: any,
}

-- One NoiseFill per world (per worker); holds the per-world caches.
function NoiseFill.new(sampler: Compiler.Sampler, rs: any): any
	local fns, router = sampler.fns, sampler.router
	local finalDensity = fns[router.final_density]
	local initialDensity = fns[router.initial_density_without_jaggedness]

	local self = {
		sampler = sampler,
		rs = rs,
		finalDensity = finalDensity,
		interps = Compiler.blockInterpolators(sampler, { router.final_density, router.vein_toggle, router.vein_ridged }),
		prelimCache = {} :: { [number]: number },
		prelimCount = 0,
		veins = OreVeins.new(fns[router.vein_toggle], fns[router.vein_ridged], fns[router.vein_gap], rs.oreRandom),
	}

	-- NoiseChunk.preliminarySurfaceLevel: quart-snapped, cached per world
	local cache = self.prelimCache
	self.prelim = function(x: number, z: number): number
		local qx, qz = floor(x / 4), floor(z / 4)
		local key = (qx + 4194304) * 8388608 + (qz + 4194304)
		local v = cache[key]
		if v then
			return v
		end
		local bx, bz = qx * 4, qz * 4
		local level = 2147483647
		for l = MIN_Y + HEIGHT, MIN_Y, -CELL_H do
			if initialDensity(bx, l, bz) > 0.390625 then
				level = l
				break
			end
		end
		if self.prelimCount > 200000 then
			table.clear(cache)
			self.prelimCount = 0
		end
		cache[key] = level
		self.prelimCount += 1
		return level
	end

	local aquiferCtx = {
		seaLevel = SEA,
		minY = MIN_Y,
		height = HEIGHT,
		aquiferRandom = rs.aquiferRandom,
		barrier = fns[router.barrier],
		floodedness = fns[router.fluid_level_floodedness],
		spread = fns[router.fluid_level_spread],
		lava = fns[router.lava],
		erosion = fns[router.erosion],
		depth = fns[router.depth],
		prelim = self.prelim,
	}
	self.aquiferCtx = aquiferCtx
	return self
end

-- chunk: { cx, cz, blocks (buffer), topY, floorY, veinOres }
function NoiseFill.fill(self: any, chunk: any)
	local sampler: Compiler.Sampler = self.sampler
	local router = sampler.router
	local minX, minZ = chunk.cx * 16, chunk.cz * 16
	local blocks = chunk.blocks
	local occ = chunk.occ
	local smooth = occ ~= nil
	local topY, floorY = chunk.topY, chunk.floorY
	local finalDensity = self.finalDensity
	local veins = self.veins
	local veinOres = chunk.veinOres

	Compiler.setChunk(sampler, minX, minZ)
	Compiler.fillLattices(sampler, self.interps)

	-- highest preliminary surface within reach of any aquifer centre that can influence this chunk
	local maxPrelim = -math.huge
	for qx = floor((minX - 24) / 4), floor((minX + 16 + 23) / 4) do
		for qz = floor((minZ - 24) / 4), floor((minZ + 16 + 23) / 4) do
			local p = self.prelim(qx * 4, qz * 4)
			if p > maxPrelim then
				maxPrelim = p
			end
		end
	end
	local aquifer = Aquifer.new(self.aquiferCtx)
	chunk.aquifer = aquifer
	if maxPrelim < 2147483647 then
		Aquifer.setSkipY(aquifer, maxPrelim)
	end
	local skipY = (aquifer :: any).skipY

	for i = 1, 256 do
		topY[i] = MIN_Y - 1
		floorY[i] = MIN_Y - 1
	end

	local finalId, toggleId = router.final_density, router.vein_toggle
	local computeAquifer = aquifer.compute

	for cx = 0, CELLS_XZ - 1 do
		for cz = 0, CELLS_XZ - 1 do
			local x0, z0 = minX + cx * CELL_W, minZ + cz * CELL_W
			for cy = CELLS_Y - 1, 0, -1 do
				local y0 = MIN_Y + cy * CELL_H
				local y1 = y0 + CELL_H - 1
				local lo, hi = Compiler.cellInterval(sampler, finalId, cx, cz, cy)
				local veinPossible = false
				if y1 >= -60 and y0 < 51 then
					local tl, th = Compiler.cellInterval(sampler, toggleId, cx, cz, cy)
					veinPossible = max(abs(tl), abs(th)) >= 0.39
				end

				if lo > 0 and not veinPossible then
					-- solid cell
					for lx = 0, CELL_W - 1 do
						for lz = 0, CELL_W - 1 do
							local col = (cx * CELL_W + lx) * 16 + cz * CELL_W + lz
							buffer.fill(blocks, col * HEIGHT + (y0 - MIN_Y), STONE, CELL_H)
							if smooth then
								buffer.fill(occ, col * HEIGHT + (y0 - MIN_Y), 255, CELL_H)
							end
							if y1 > topY[col + 1] then
								topY[col + 1] = y1
							end
							if y1 > floorY[col + 1] then
								floorY[col + 1] = y1
							end
						end
					end
				elseif hi <= 0 and y0 > skipY then
					-- open air above everything the aquifer can reach: the buffer is already zero (air)
				else
					-- density gradient at the cell centre: turns the density into a sub-voxel surface position
					local gx, gy, gz, halfSum, invG = 0.0, 0.0, 0.0, 0.0, 0.0
					if smooth then
						local mx, my, mz = x0 + 2, y0 + 4, z0 + 2
						gx = (finalDensity(mx + 1.5, my, mz) - finalDensity(mx - 1.5, my, mz)) / 3
						gy = (finalDensity(mx, my + 3, mz) - finalDensity(mx, my - 3, mz)) / 6
						gz = (finalDensity(mx, my, mz + 1.5) - finalDensity(mx, my, mz - 1.5)) / 3
						halfSum = 0.5 * (gx + gy + gz)
						local g = sqrt(gx * gx + gy * gy + gz * gz)
						invG = g > 1e-6 and 1 / g or 1e6
					end
					for lx = 0, CELL_W - 1 do
						local x = x0 + lx
						for lz = 0, CELL_W - 1 do
							local z = z0 + lz
							local col = (cx * CELL_W + lx) * 16 + cz * CELL_W + lz
							local base = col * HEIGHT - MIN_Y
							for ly = 0, CELL_H - 1 do
								local y = y0 + ly
								local density = finalDensity(x, y, z)
								local b = computeAquifer(aquifer, x, y, z, density)
								local barrier = false
								if b == nil then
									b = STONE
									barrier = density <= 0
									if veinPossible and y >= -60 and y < 51 then
										local vb, ore, raw = veins(x, y, z)
										if vb then
											b = vb
											if ore then
												table.insert(veinOres, { x, y, z, ore, raw })
											end
										end
									end
								end
								if smooth then
									local o
									if barrier or b == WATER or b == Blocks.LAVA then
										o = 255
									else
										o = 0.5 + (density + halfSum) * invG
										o = o <= 0 and 0 or (o >= 1 and 255 or floor(o * 255 + 0.5))
									end
									if o > 0 then
										buffer.writeu8(occ, base + y, o)
									end
								end
								if b ~= AIR then
									buffer.writeu8(blocks, base + y, b)
									if y > topY[col + 1] then
										topY[col + 1] = y
									end
									if b ~= WATER and b ~= Blocks.LAVA and y > floorY[col + 1] then
										floorY[col + 1] = y
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

return NoiseFill
