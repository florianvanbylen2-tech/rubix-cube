--!strict
-- Port of net.minecraft.world.level.biome.OverworldBiomeBuilder (1.20.x): the table that maps climate
-- parameter boxes (temperature, humidity, continentalness, erosion, depth, weirdness) to biomes.

local Climate = require(script.Parent.Climate)

local span, point = Climate.span, Climate.point

type Param = Climate.Param
type Emit = (Param, Param, Param, Param, Param, Param, string) -> ()

local Builder = {}

-- 1-based tables use `false` for the null entries of the Java arrays.
local OCEANS = {
	{ "deep_frozen_ocean", "deep_cold_ocean", "deep_ocean", "deep_lukewarm_ocean", "warm_ocean" },
	{ "frozen_ocean", "cold_ocean", "ocean", "lukewarm_ocean", "warm_ocean" },
}
local MIDDLE = {
	{ "snowy_plains", "snowy_plains", "snowy_plains", "snowy_taiga", "taiga" },
	{ "plains", "plains", "forest", "taiga", "old_growth_spruce_taiga" },
	{ "flower_forest", "plains", "forest", "birch_forest", "dark_forest" },
	{ "savanna", "savanna", "forest", "jungle", "jungle" },
	{ "desert", "desert", "desert", "desert", "desert" },
}
local MIDDLE_VARIANT = {
	{ "ice_spikes", false, "snowy_taiga", false, false },
	{ false, false, false, false, "old_growth_pine_taiga" },
	{ "sunflower_plains", false, false, "old_growth_birch_forest", false },
	{ false, false, "plains", "sparse_jungle", "bamboo_jungle" },
	{ false, false, false, false, false },
}
local PLATEAU = {
	{ "snowy_plains", "snowy_plains", "snowy_plains", "snowy_taiga", "snowy_taiga" },
	{ "meadow", "meadow", "forest", "taiga", "old_growth_spruce_taiga" },
	{ "meadow", "meadow", "meadow", "meadow", "dark_forest" },
	{ "savanna_plateau", "savanna_plateau", "forest", "forest", "jungle" },
	{ "badlands", "badlands", "badlands", "wooded_badlands", "wooded_badlands" },
}
local PLATEAU_VARIANT = {
	{ "ice_spikes", false, false, false, false },
	{ "cherry_grove", false, "meadow", "meadow", "old_growth_pine_taiga" },
	{ "cherry_grove", "cherry_grove", "forest", "birch_forest", false },
	{ false, false, false, false, false },
	{ "eroded_badlands", "eroded_badlands", false, false, false },
}
local SHATTERED = {
	{ "windswept_gravelly_hills", "windswept_gravelly_hills", "windswept_hills", "windswept_forest", "windswept_forest" },
	{ "windswept_gravelly_hills", "windswept_gravelly_hills", "windswept_hills", "windswept_forest", "windswept_forest" },
	{ "windswept_hills", "windswept_hills", "windswept_hills", "windswept_forest", "windswept_forest" },
	{ false, false, false, false, false },
	{ false, false, false, false, false },
}

-- Builds the full list of parameter points. Returns { Climate.Point } with the biome name as value.
function Builder.build(): { Climate.Point }
	local points: { Climate.Point } = {}

	local FULL = span(-1.0, 1.0)
	local temps = { span(-1.0, -0.45), span(-0.45, -0.15), span(-0.15, 0.2), span(0.2, 0.55), span(0.55, 1.0) }
	local hums = { span(-1.0, -0.35), span(-0.35, -0.1), span(-0.1, 0.1), span(0.1, 0.3), span(0.3, 1.0) }
	local eros = {
		span(-1.0, -0.78), span(-0.78, -0.375), span(-0.375, -0.2225), span(-0.2225, 0.05),
		span(0.05, 0.45), span(0.45, 0.55), span(0.55, 1.0),
	}
	local FROZEN = temps[1]
	local UNFROZEN = span(temps[2], temps[5])
	local mushroomC = span(-1.2, -1.05)
	local deepOceanC = span(-1.05, -0.455)
	local oceanC = span(-0.455, -0.19)
	local coastC = span(-0.19, -0.11)
	local nearC = span(-0.11, 0.03)
	local midC = span(0.03, 0.3)
	local farC = span(0.3, 1.0)

	local function surface(t: Param, h: Param, c: Param, e: Param, w: Param, biome: string)
		table.insert(points, Climate.newPoint({ t, h, c, e, point(0.0), w }, 0.0, biome))
		table.insert(points, Climate.newPoint({ t, h, c, e, point(1.0), w }, 0.0, biome))
	end
	local function underground(t: Param, h: Param, c: Param, e: Param, w: Param, biome: string)
		table.insert(points, Climate.newPoint({ t, h, c, e, span(0.2, 0.9), w }, 0.0, biome))
	end
	local function bottom(t: Param, h: Param, c: Param, e: Param, w: Param, biome: string)
		table.insert(points, Climate.newPoint({ t, h, c, e, point(1.1), w }, 0.0, biome))
	end

	local function wNeg(w: Param): boolean
		return w[2] < 0
	end

	-- ------------------------------------------------------------------ pickers
	local function pickMiddle(t: number, h: number, w: Param): string
		if wNeg(w) then
			return MIDDLE[t + 1][h + 1]
		end
		local v = MIDDLE_VARIANT[t + 1][h + 1]
		return v or MIDDLE[t + 1][h + 1]
	end
	local function pickBadlands(h: number, w: Param): string
		if h < 2 then
			return wNeg(w) and "badlands" or "eroded_badlands"
		end
		return h < 3 and "badlands" or "wooded_badlands"
	end
	local function pickMiddleOrBadlandsIfHot(t: number, h: number, w: Param): string
		if t == 4 then
			return pickBadlands(h, w)
		end
		return pickMiddle(t, h, w)
	end
	local function pickPlateau(t: number, h: number, w: Param): string
		if wNeg(w) then
			return PLATEAU[t + 1][h + 1]
		end
		local v = PLATEAU_VARIANT[t + 1][h + 1]
		return v or PLATEAU[t + 1][h + 1]
	end
	local function pickSlope(t: number, h: number, w: Param): string
		if t >= 3 then
			return pickPlateau(t, h, w)
		end
		return h <= 1 and "snowy_slopes" or "grove"
	end
	local function pickMiddleOrBadlandsIfHotOrSlopeIfCold(t: number, h: number, w: Param): string
		if t == 0 then
			return pickSlope(t, h, w)
		end
		return pickMiddleOrBadlandsIfHot(t, h, w)
	end
	local function pickShattered(t: number, h: number, w: Param): string
		local b = SHATTERED[t + 1][h + 1]
		return b or pickMiddle(t, h, w)
	end
	local function maybeWindsweptSavanna(t: number, h: number, w: Param, fallback: string): string
		if t > 1 and h < 4 and w[2] >= 0 then
			return "windswept_savanna"
		end
		return fallback
	end
	local function pickBeach(t: number, _h: number): string
		if t == 0 then
			return "snowy_beach"
		end
		return t == 4 and "desert" or "beach"
	end
	local function pickShatteredCoast(t: number, h: number, w: Param): string
		local b = w[2] >= 0 and pickMiddle(t, h, w) or pickBeach(t, h)
		return maybeWindsweptSavanna(t, h, w, b)
	end
	local function pickPeak(t: number, h: number, w: Param): string
		if t <= 2 then
			return wNeg(w) and "jagged_peaks" or "frozen_peaks"
		end
		return t == 3 and "stony_peaks" or pickBadlands(h, w)
	end

	-- ------------------------------------------------------------------ slices
	local function addOffCoast()
		surface(FULL, FULL, mushroomC, FULL, FULL, "mushroom_fields")
		for i = 1, 5 do
			surface(temps[i], FULL, deepOceanC, FULL, FULL, OCEANS[1][i])
			surface(temps[i], FULL, oceanC, FULL, FULL, OCEANS[2][i])
		end
	end

	local function addMidSlice(w: Param)
		surface(FULL, FULL, coastC, span(eros[1], eros[3]), w, "stony_shore")
		surface(span(temps[2], temps[3]), FULL, span(nearC, farC), eros[7], w, "swamp")
		surface(span(temps[4], temps[5]), FULL, span(nearC, farC), eros[7], w, "mangrove_swamp")
		for i = 0, 4 do
			local t = temps[i + 1]
			for j = 0, 4 do
				local h = hums[j + 1]
				local middle = pickMiddle(i, j, w)
				local middleOrBadlands = pickMiddleOrBadlandsIfHot(i, j, w)
				local middleOrBadlandsOrSlope = pickMiddleOrBadlandsIfHotOrSlopeIfCold(i, j, w)
				local shattered = pickShattered(i, j, w)
				local plateau = pickPlateau(i, j, w)
				local beach = pickBeach(i, j)
				local shatteredOrWindswept = maybeWindsweptSavanna(i, j, w, shattered)
				local shatteredCoast = pickShatteredCoast(i, j, w)
				local slope = pickSlope(i, j, w)
				surface(t, h, span(nearC, farC), eros[1], w, slope)
				surface(t, h, span(nearC, midC), eros[2], w, middleOrBadlandsOrSlope)
				surface(t, h, farC, eros[2], w, i == 0 and slope or plateau)
				surface(t, h, nearC, eros[3], w, middle)
				surface(t, h, midC, eros[3], w, middleOrBadlands)
				surface(t, h, farC, eros[3], w, plateau)
				surface(t, h, span(coastC, nearC), eros[4], w, middle)
				surface(t, h, span(midC, farC), eros[4], w, middleOrBadlands)
				if wNeg(w) then
					surface(t, h, coastC, eros[5], w, beach)
					surface(t, h, span(nearC, farC), eros[5], w, middle)
				else
					surface(t, h, span(coastC, farC), eros[5], w, middle)
				end
				surface(t, h, coastC, eros[6], w, shatteredCoast)
				surface(t, h, nearC, eros[6], w, shatteredOrWindswept)
				surface(t, h, span(midC, farC), eros[6], w, shattered)
				if wNeg(w) then
					surface(t, h, coastC, eros[7], w, beach)
				else
					surface(t, h, coastC, eros[7], w, middle)
				end
				if i == 0 then
					surface(t, h, span(nearC, farC), eros[7], w, middle)
				end
			end
		end
	end

	local function addLowSlice(w: Param)
		surface(FULL, FULL, coastC, span(eros[1], eros[3]), w, "stony_shore")
		surface(span(temps[2], temps[3]), FULL, span(nearC, farC), eros[7], w, "swamp")
		surface(span(temps[4], temps[5]), FULL, span(nearC, farC), eros[7], w, "mangrove_swamp")
		for i = 0, 4 do
			local t = temps[i + 1]
			for j = 0, 4 do
				local h = hums[j + 1]
				local middle = pickMiddle(i, j, w)
				local middleOrBadlands = pickMiddleOrBadlandsIfHot(i, j, w)
				local middleOrBadlandsOrSlope = pickMiddleOrBadlandsIfHotOrSlopeIfCold(i, j, w)
				local beach = pickBeach(i, j)
				local windswept = maybeWindsweptSavanna(i, j, w, middle)
				local shatteredCoast = pickShatteredCoast(i, j, w)
				surface(t, h, nearC, span(eros[1], eros[2]), w, middleOrBadlands)
				surface(t, h, span(midC, farC), span(eros[1], eros[2]), w, middleOrBadlandsOrSlope)
				surface(t, h, nearC, span(eros[3], eros[4]), w, middle)
				surface(t, h, span(midC, farC), span(eros[3], eros[4]), w, middleOrBadlands)
				surface(t, h, coastC, span(eros[4], eros[5]), w, beach)
				surface(t, h, span(nearC, farC), eros[5], w, middle)
				surface(t, h, coastC, eros[6], w, shatteredCoast)
				surface(t, h, nearC, eros[6], w, windswept)
				surface(t, h, span(midC, farC), eros[6], w, middle)
				surface(t, h, coastC, eros[7], w, beach)
				if i == 0 then
					surface(t, h, span(nearC, farC), eros[7], w, middle)
				end
			end
		end
	end

	local function addHighSlice(w: Param)
		for i = 0, 4 do
			local t = temps[i + 1]
			for j = 0, 4 do
				local h = hums[j + 1]
				local middle = pickMiddle(i, j, w)
				local middleOrBadlands = pickMiddleOrBadlandsIfHot(i, j, w)
				local middleOrBadlandsOrSlope = pickMiddleOrBadlandsIfHotOrSlopeIfCold(i, j, w)
				local plateau = pickPlateau(i, j, w)
				local shattered = pickShattered(i, j, w)
				local shatteredOrWindswept = maybeWindsweptSavanna(i, j, w, shattered)
				local slope = pickSlope(i, j, w)
				local peak = pickPeak(i, j, w)
				surface(t, h, coastC, span(eros[1], eros[2]), w, middle)
				surface(t, h, nearC, eros[1], w, slope)
				surface(t, h, span(midC, farC), eros[1], w, peak)
				surface(t, h, nearC, eros[2], w, middleOrBadlandsOrSlope)
				surface(t, h, span(midC, farC), eros[2], w, slope)
				surface(t, h, span(coastC, nearC), span(eros[3], eros[4]), w, middle)
				surface(t, h, span(midC, farC), eros[3], w, plateau)
				surface(t, h, midC, eros[4], w, middleOrBadlands)
				surface(t, h, farC, eros[4], w, plateau)
				surface(t, h, span(coastC, farC), eros[5], w, middle)
				surface(t, h, span(coastC, nearC), eros[6], w, shatteredOrWindswept)
				surface(t, h, span(midC, farC), eros[6], w, shattered)
				surface(t, h, span(coastC, farC), eros[7], w, middle)
			end
		end
	end

	local function addPeaks(w: Param)
		for i = 0, 4 do
			local t = temps[i + 1]
			for j = 0, 4 do
				local h = hums[j + 1]
				local middle = pickMiddle(i, j, w)
				local middleOrBadlands = pickMiddleOrBadlandsIfHot(i, j, w)
				local middleOrBadlandsOrSlope = pickMiddleOrBadlandsIfHotOrSlopeIfCold(i, j, w)
				local plateau = pickPlateau(i, j, w)
				local shattered = pickShattered(i, j, w)
				local shatteredOrWindswept = maybeWindsweptSavanna(i, j, w, shattered)
				local peak = pickPeak(i, j, w)
				surface(t, h, span(coastC, farC), eros[1], w, peak)
				surface(t, h, span(coastC, nearC), eros[2], w, middleOrBadlandsOrSlope)
				surface(t, h, span(midC, farC), eros[2], w, peak)
				surface(t, h, span(coastC, nearC), span(eros[3], eros[4]), w, middle)
				surface(t, h, span(midC, farC), eros[3], w, plateau)
				surface(t, h, midC, eros[4], w, middleOrBadlands)
				surface(t, h, farC, eros[4], w, plateau)
				surface(t, h, span(coastC, farC), eros[5], w, middle)
				surface(t, h, span(coastC, nearC), eros[6], w, shatteredOrWindswept)
				surface(t, h, span(midC, farC), eros[6], w, shattered)
				surface(t, h, span(coastC, farC), eros[7], w, middle)
			end
		end
	end

	local function addValleys(w: Param)
		local neg = wNeg(w)
		local e01 = span(eros[1], eros[2])
		local e25 = span(eros[3], eros[6])
		surface(FROZEN, FULL, coastC, e01, w, neg and "stony_shore" or "frozen_river")
		surface(UNFROZEN, FULL, coastC, e01, w, neg and "stony_shore" or "river")
		surface(FROZEN, FULL, nearC, e01, w, "frozen_river")
		surface(UNFROZEN, FULL, nearC, e01, w, "river")
		surface(FROZEN, FULL, span(coastC, farC), e25, w, "frozen_river")
		surface(UNFROZEN, FULL, span(coastC, farC), e25, w, "river")
		surface(FROZEN, FULL, coastC, eros[7], w, "frozen_river")
		surface(UNFROZEN, FULL, coastC, eros[7], w, "river")
		surface(span(temps[2], temps[3]), FULL, span(nearC, farC), eros[7], w, "swamp")
		surface(span(temps[4], temps[5]), FULL, span(nearC, farC), eros[7], w, "mangrove_swamp")
		surface(FROZEN, FULL, span(nearC, farC), eros[7], w, "frozen_river")
		for i = 0, 4 do
			for j = 0, 4 do
				local middleOrBadlands = pickMiddleOrBadlandsIfHot(i, j, w)
				surface(temps[i + 1], hums[j + 1], span(midC, farC), e01, w, middleOrBadlands)
			end
		end
	end

	local function addInland()
		addMidSlice(span(-1.0, -0.93333334))
		addHighSlice(span(-0.93333334, -0.7666667))
		addPeaks(span(-0.7666667, -0.56666666))
		addHighSlice(span(-0.56666666, -0.4))
		addMidSlice(span(-0.4, -0.26666668))
		addLowSlice(span(-0.26666668, -0.05))
		addValleys(span(-0.05, 0.05))
		addLowSlice(span(0.05, 0.26666668))
		addMidSlice(span(0.26666668, 0.4))
		addHighSlice(span(0.4, 0.56666666))
		addPeaks(span(0.56666666, 0.7666667))
		addHighSlice(span(0.7666667, 0.93333334))
		addMidSlice(span(0.93333334, 1.0))
	end

	local function addUnderground()
		underground(FULL, FULL, span(0.8, 1.0), FULL, FULL, "dripstone_caves")
		underground(FULL, span(0.7, 1.0), FULL, FULL, FULL, "lush_caves")
		bottom(FULL, FULL, FULL, span(eros[1], eros[2]), FULL, "deep_dark")
	end

	addOffCoast()
	addInland()
	addUnderground()
	return points
end

return Builder
