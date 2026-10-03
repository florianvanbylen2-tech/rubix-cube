-- Per-chunk generation cost for the server role (decides things) and the client role (terrain only).
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Config = require(TG.Config)
local Structures = require(TG.World.Structures)
local function bench(label, opts)
	local gen = ChunkGenerator.new(12345, opts)
	for i = 1, 3 do gen:generate(200 + i, 200) end -- warm caches
	local n, t0 = 12, os.clock()
	for i = 1, n do gen:generate(5 + i * 3, -11 + (i % 4) * 5) end
	print(string.format("%-8s %.0f ms per chunk", label, (os.clock() - t0) / n * 1000))
end
bench("server", { things = true, smooth = false, spawning = Config.Spawning, trees = Config.Trees, ores = Config.Ores, structures = Structures.normalizeAll(Config.Structures) })
bench("client", { things = false, smooth = true })
