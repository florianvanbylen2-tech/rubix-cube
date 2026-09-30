local Xoroshiro = require(TG.Core.Xoroshiro)
local NormalNoise = require(TG.Noise.NormalNoise)
local BlendedNoise = require(TG.Noise.BlendedNoise)
local NoiseParams = require(TG.Data.NoiseParams)

local function g17(x) return string.format("%.17g", x) end
local pts = { {0,0,0}, {13.5,64,-7.25}, {-1234.0,200.0,4321.0}, {100000.0,-30.0,100000.0}, {5.0,5.0,5.0}, {-0.5,320.0,0.5}, {1e7,10.0,-1e7}, {37.0,-64.0,91.0} }
local seeds = { {0, 12345}, {0, 0}, nil }
local sh, sl = require(TG.Core.Int64).parse("-4172144997902289642")
seeds[3] = { sh, sl }
local names = { "temperature", "continentalness", "jagged", "cave_cheese", "ore_veininess", "surface", "offset" }
for si, seed in seeds do
	local label = ({ "12345", "0", "-4172144997902289642" })[si]
	local root = Xoroshiro.new(seed[1], seed[2])
	local fac = root:forkPositional()
	for _, name in names do
		local p = NoiseParams[name]
		local amps = {}
		for i, a in p[2] do amps[i] = a + 0.0 end
		local nn = NormalNoise.create(fac:fromHashOf("minecraft:" .. name), p[1], amps)
		local out = {}
		for _, pt in pts do table.insert(out, g17(nn:getValue(pt[1], pt[2], pt[3]))) end
		print("normal", label, name, g17(nn.maxValue), table.concat(out, " "))
	end
	local bl = BlendedNoise.new(fac:fromHashOf("minecraft:terrain"), 0.25, 0.125, 80.0, 160.0, 8.0)
	local out = {}
	for _, pt in { {0,0,0}, {16,64,16}, {-100,100,200}, {1000,-64,-1000}, {7,300,7}, {123456,90,-654321} } do
		table.insert(out, g17(bl:compute(pt[1], pt[2], pt[3])))
	end
	print("blended", label, table.concat(out, " "))
end
