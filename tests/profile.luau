local ChunkGenerator = require(TG.World.ChunkGenerator)
local Carvers = require(TG.World.Carvers)
local NoiseFill = require(TG.World.NoiseFill)
local Features = require(TG.World.Features)
local gen = ChunkGenerator.new(12345)
-- warm up (lazy noise instantiation, caches)
for i = 1, 3 do gen:generate(200 + i, 200) end
local n = 12
local tn, ts, tc, tf, tt = 0, 0, 0, 0, 0
for i = 1, n do
	local cx, cz = 5 + i * 3, -11 + (i % 4) * 5
	local t0 = os.clock()
	local chunk = ChunkGenerator.newChunk(cx, cz)
	NoiseFill.fill(gen.fill, chunk)
	local t1 = os.clock()
	gen.surface:build(chunk)
	local t2 = os.clock()
	Carvers.carve(gen, chunk)
	Carvers.recomputeHeightmaps(chunk)
	local t3 = os.clock()
	Features.generate(gen.features, chunk)
	local t4 = os.clock()
	tn += t1 - t0; ts += t2 - t1; tc += t3 - t2; tf += t4 - t3; tt += t4 - t0
end
print(string.format("avg per chunk: noise %.0f ms | surface %.0f | carvers %.0f | features %.0f | total %.0f ms", tn / n * 1000, ts / n * 1000, tc / n * 1000, tf / n * 1000, tt / n * 1000))
