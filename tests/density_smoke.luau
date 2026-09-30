local RandomState = require(TG.World.RandomState)
local Compiler = require(TG.Density.Compiler)
local Settings = require(TG.Data.Settings)

local t0 = os.clock()
local h, l = RandomState.seedFrom(12345)
local rs = RandomState.new(h, l)
local S = Compiler.compile(rs)
print(string.format("compile: %.1f ms, nodes=%d", (os.clock() - t0) * 1000, #S.nodes))
local R = S.router
local names = { "temperature", "vegetation", "continents", "erosion", "depth", "ridges" }
local function ev(name, x, y, z) return S.fns[R[name]](x, y, z) end

-- climate at a grid of quart-aligned points
local mins, maxs = {}, {}
for _, n in names do mins[n], maxs[n] = math.huge, -math.huge end
local N = 0
for x = -4000, 4000, 200 do
	for z = -4000, 4000, 200 do
		for _, n in names do
			local v = ev(n, x, 64, z)
			mins[n] = math.min(mins[n], v); maxs[n] = math.max(maxs[n], v)
		end
		N += 1
	end
end
for _, n in names do print(string.format("%-12s min %.3f max %.3f  static [%.2f, %.2f]", n, mins[n], maxs[n], S.lo[R[n]], S.hi[R[n]])) end

-- preliminary surface along a transect
local id = R.initial_density_without_jaggedness
local line = {}
for x = -1000, 1000, 100 do
	local surf = "-"
	for y = 320, -64, -8 do
		if S.fns[id](x, y, 0) > 0.390625 then surf = tostring(y) break end
	end
	table.insert(line, surf)
end
print("prelim surface z=0, x=-1000..1000 step 100:", table.concat(line, " "))
print("bounds final_density", S.lo[R.final_density], S.hi[R.final_density])
local roots = { R.final_density, R.vein_toggle, R.vein_ridged }
local ip = Compiler.blockInterpolators(S, roots)
print("block-level interpolators:", table.concat(ip, ","))
