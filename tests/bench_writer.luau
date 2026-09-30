--@include roblox_mock.luau
local ChunkGenerator = require(TG.World.ChunkGenerator)
local ChunkWriter = require(TG.Streaming.ChunkWriter)
local cfg = { bedrockLevel = 0, folderName = "GeneratedCollectables", collectables = true, partSize = Vector3.new(4, 4, 4), colorParts = false, applyColors = false, writeBudgetMs = math.huge }
local gen = ChunkGenerator.new(12345)
local writer = ChunkWriter.new(cfg)
ChunkWriter.setBiomeNames(writer, gen.registry.names)
-- stub the engine calls: we only want the Lua-side cost
local calls, voxels = 0, 0
MOCK.terrain._props.WriteVoxels = function(_, region, _, mats) calls += 1; voxels += #mats * #mats[1] * #mats[1][1] end
MOCK.terrain._props.FillBlock = function() calls += 1 end
for _, c in { { 5, -3 }, { 0, 0 }, { -30, 12 }, { 13, -11 } } do
	local chunk = gen:generate(c[1], c[2])
	local n = 8
	calls, voxels = 0, 0
	local t0 = os.clock()
	for _ = 1, n do writer:write(chunk) end
	local dt = (os.clock() - t0) / n * 1000
	print(string.format("chunk (%d,%d): %.1f ms per write (Lua side), %d engine calls, %d voxels per write", c[1], c[2], dt, calls / n, voxels / n))
end
