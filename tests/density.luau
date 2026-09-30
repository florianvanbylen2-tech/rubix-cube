local RandomState = require(TG.World.RandomState)
local Compiler = require(TG.Density.Compiler)

-- same deterministic sample points as tests/density_ref.py
local st = 987654321
local function rnd() st = (st * 1664525 + 1013904223) % 4294967296 return st / 4294967296.0 end
local pts = {}
for i = 0, 119 do
	local aligned = i % 2 == 0
	local x = math.floor(rnd() * 8000 - 4000) + 300
	local z = math.floor(rnd() * 8000 - 4000) - 300
	if aligned then x, z = x // 4 * 4, z // 4 * 4 end
	local y = math.floor(rnd() * 384) - 64
	table.insert(pts, { x, y, z })
end
local h, l = RandomState.seedFrom(12345)
local rs = RandomState.new(h, l)
local S = Compiler.compile(rs)
local names = { "temperature", "vegetation", "continents", "erosion", "depth", "ridges", "initial_density_without_jaggedness",
	"final_density", "barrier", "fluid_level_floodedness", "fluid_level_spread", "lava", "vein_toggle", "vein_ridged", "vein_gap" }
Compiler.direct(S, function()
	for _, name in names do
		local fn = S.fns[S.router[name]]
		local out = {}
		for _, p in pts do table.insert(out, string.format("%.17g", fn(p[1], p[2], p[3]))) end
		print("router", name, table.concat(out, " "))
	end
end)
