--!strict
-- Samplers for vanilla's value providers (IntProvider / FloatProvider / HeightProvider) as they appear in the
-- worldgen JSON. `random` is any object with nextInt(bound), nextFloat().

local Settings = require(script.Parent.Parent.Data.Settings)

local MIN_Y = Settings.minY
local MAX_GEN_Y = MIN_Y + Settings.height - 1

local Providers = {}

function Providers.anchor(a: any): number
	if a.absolute then
		return a.absolute
	elseif a.above_bottom then
		return MIN_Y + a.above_bottom
	end
	return MAX_GEN_Y - a.below_top
end

local function between(random: any, lo: number, hi: number): number
	return random:nextInt(hi - lo + 1) + lo
end
Providers.between = between

-- Int provider: number | {type=constant|uniform|weighted_list|biased_to_bottom|clamped, ...}
function Providers.int(spec: any, random: any): number
	if type(spec) == "number" then
		return spec
	end
	local t = spec.type
	if t == "constant" then
		return spec.value
	elseif t == "uniform" then
		return between(random, spec.value.min_inclusive, spec.value.max_inclusive)
	elseif t == "biased_to_bottom" then
		local lo, hi = spec.value.min_inclusive, spec.value.max_inclusive
		return lo + random:nextInt(random:nextInt(hi - lo + 1) + 1)
	elseif t == "clamped" then
		local c = spec.value
		return math.clamp(Providers.int(c.source, random), c.min_inclusive, c.max_inclusive)
	elseif t == "weighted_list" then
		local total = 0
		for _, e in spec.distribution do
			total += e.weight
		end
		local r = random:nextInt(total)
		for _, e in spec.distribution do
			r -= e.weight
			if r < 0 then
				return Providers.int(e.data, random)
			end
		end
	end
	error("unsupported int provider: " .. tostring(t))
end

-- Float provider: number | {type=constant|uniform|trapezoid, ...}
function Providers.float(spec: any, random: any): number
	if type(spec) == "number" then
		return spec
	end
	local t = spec.type
	if t == "constant" then
		return spec.value
	elseif t == "uniform" then
		local lo, hi = spec.value.min_inclusive, spec.value.max_exclusive
		return random:nextFloat() * (hi - lo) + lo
	elseif t == "trapezoid" then
		local lo, hi, plateau = spec.value.min, spec.value.max, spec.value.plateau
		local f = hi - lo
		local f1 = (f - plateau) / 2
		local f2 = f - f1
		return lo + random:nextFloat() * f2 + random:nextFloat() * f1
	end
	error("unsupported float provider: " .. tostring(t))
end

-- Height provider: {type=uniform|trapezoid|biased_to_bottom|very_biased_to_bottom|constant, ...}
function Providers.height(spec: any, random: any): number
	local t = spec.type
	if t == "constant" then
		return Providers.anchor(spec.value)
	end
	local lo, hi = Providers.anchor(spec.min_inclusive), Providers.anchor(spec.max_inclusive)
	if t == "uniform" then
		if lo > hi then
			return lo
		end
		return between(random, lo, hi)
	elseif t == "trapezoid" then
		if lo > hi then
			return lo
		end
		local plateau = spec.plateau or 0
		local k = hi - lo
		if plateau >= k then
			return between(random, lo, hi)
		end
		local l = (k - plateau) // 2
		local i1 = k - l
		return lo + between(random, 0, i1) + between(random, 0, l)
	elseif t == "biased_to_bottom" then
		local inner = spec.inner or 1
		if hi - lo - inner + 1 <= 0 then
			return lo
		end
		local k = random:nextInt(hi - lo - inner + 1)
		return random:nextInt(k + inner) + lo
	elseif t == "very_biased_to_bottom" then
		local inner = spec.inner or 1
		if hi - lo - inner + 1 <= 0 then
			return lo
		end
		local k = between(random, lo + inner, hi)
		local l = between(random, lo, k - 1)
		return between(random, lo, l - 1 + inner)
	end
	error("unsupported height provider: " .. tostring(t))
end

return Providers
