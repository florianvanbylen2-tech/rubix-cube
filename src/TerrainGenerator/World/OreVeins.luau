--!strict
--!native
-- Port of OreVeinifier: the huge copper (y 0..50) and iron (y -60..-8) veins carved into stone by the
-- vein_toggle / vein_ridged / vein_gap density functions.

local Blocks = require(script.Parent.Blocks)

local abs, min = math.abs, math.min

-- float literals from the Java source, widened to double
local THRESHOLD = 0.4000000059604645 -- 0.4F
local CHANCE = 0.699999988079071 -- 0.7F
local GAP = -0.30000001192092896 -- -0.3F
local RAW_CHANCE = 0.019999999552965164 -- 0.02F

export type Result = { block: number?, ore: string?, raw: boolean? }

local OreVeins = {}

-- toggle / ridged / gap: density functions (x,y,z) -> number; oreRandom: PositionalFactory
function OreVeins.new(toggle: (number, number, number) -> number, ridged: (number, number, number) -> number, gap: (number, number, number) -> number, oreRandom: any)
	local COPPER = { minY = 0, maxY = 50, filler = Blocks.ids.granite, ore = "copper" }
	local IRON = { minY = -60, maxY = -8, filler = Blocks.ids.tuff, ore = "iron" }

	-- Returns (blockId, oreName, isRawBlock): blockId is the terrain block to place (a filler or the host
	-- rock for ore blocks); oreName is set when the position holds an ore (or raw ore) block.
	-- Returns nil when the position is not part of a vein.
	return function(x: number, y: number, z: number): (number?, string?, boolean?)
		local d0 = toggle(x, y, z)
		local vein = d0 > 0 and COPPER or IRON
		local d1 = abs(d0)
		local top = vein.maxY - y
		local bottom = y - vein.minY
		if bottom >= 0 and top >= 0 then
			local edge = min(top, bottom)
			-- Mth.clampedMap(edge, 0, 20, -0.2, 0.0)
			local t = edge / 20
			local d2 = t < 0 and -0.2 or (t > 1 and 0.0 or -0.2 + t * 0.2)
			if d1 + d2 >= THRESHOLD then
				local r = oreRandom:at(x, y, z)
				if r:nextFloat() <= CHANCE and ridged(x, y, z) < 0.0 then
					-- Mth.clampedMap(d1, 0.4F, 0.6F, 0.1F, 0.3F)
					local tt = (d1 - 0.4000000059604645) / (0.6000000238418579 - 0.4000000059604645)
					local d3 = tt < 0 and 0.10000000149011612 or (tt > 1 and 0.30000001192092896 or 0.10000000149011612 + tt * (0.30000001192092896 - 0.10000000149011612))
					if r:nextFloat() < d3 and gap(x, y, z) > GAP then
						local raw = r:nextFloat() < RAW_CHANCE
						return (y < 0) and Blocks.DEEPSLATE or Blocks.STONE, vein.ore, raw
					end
					return vein.filler, nil, nil
				end
			end
		end
		return nil, nil, nil
	end
end

return OreVeins
