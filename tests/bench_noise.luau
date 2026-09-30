local Xoroshiro = require(TG.Core.Xoroshiro)
local NormalNoise = require(TG.Noise.NormalNoise)
local BlendedNoise = require(TG.Noise.BlendedNoise)
local NoiseParams = require(TG.Data.NoiseParams)
local fac = Xoroshiro.new(0, 12345):forkPositional()
local t0 = os.clock()
local p = NoiseParams.temperature
local nn
for i = 1, 20 do nn = NormalNoise.create(fac:fromHashOf("minecraft:temperature" .. i), p[1], p[2]) end
print(string.format("NormalNoise.create: %.2f ms each (%d octaves x2)", (os.clock() - t0) / 20 * 1000, #p[2]))
t0 = os.clock()
local bl
for i = 1, 3 do bl = BlendedNoise.new(fac:fromHashOf("minecraft:terrain" .. i), 0.25, 0.125, 80.0, 160.0, 8.0) end
print(string.format("BlendedNoise.new: %.2f ms each", (os.clock() - t0) / 3 * 1000))
local N = 200000
t0 = os.clock()
local s = 0
for i = 1, N do s += nn:getValue(i * 0.37, i * 0.11, i * 0.53) end
local dt = os.clock() - t0
print(string.format("NormalNoise.getValue (%d octaves): %.2f us", #p[2], dt / N * 1e6))
N = 20000
t0 = os.clock()
for i = 1, N do s += bl:compute(i * 4, (i % 96) * 4 - 64, i * 3) end
dt = os.clock() - t0
print(string.format("BlendedNoise.compute: %.2f us", dt / N * 1e6))
