--!strict
-- Read-only world queries that need no chunk to be loaded (used by TerrainGenerator.GetBiomeAt / GetHeightAt).

local Compiler = require(script.Parent.Parent.Density.Compiler)
local Settings = require(script.Parent.Parent.Data.Settings)

local MIN_Y = Settings.minY
local HEIGHT = Settings.height

local Queries = {}

-- Approximate surface height (highest block with positive density, in Minecraft block y) at block column (bx, bz).
-- Ignores carvers / features / aquifer water, so it can differ from the generated chunk by about one block.
function Queries.surfaceY(gen: any, bx: number, bz: number): number
	local sampler = gen.sampler
	local density = sampler.fns[sampler.router.final_density]
	return Compiler.direct(sampler, function()
		local top = MIN_Y + HEIGHT - 1
		local y = top
		-- coarse scan (the density is smooth on the cell scale), then refine block by block
		while y > MIN_Y and density(bx, y, bz) <= 0 do
			y -= 4
		end
		y = math.min(y + 4, top)
		while y > MIN_Y and density(bx, y, bz) <= 0 do
			y -= 1
		end
		return y
	end)
end

-- Climate values at a block position (raw, un-quantised).
function Queries.climate(gen: any, bx: number, by: number, bz: number): { [string]: number }
	return gen.biomes:sampleClimate(bx, by, bz)
end

return Queries
