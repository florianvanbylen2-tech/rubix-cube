--@include roblox_mock.luau
-- End-to-end: TerrainGenerator.Start() in single-thread mode with a small world and two moving players.
local ServerScriptService = MOCK.SSS
-- make `require(script.Parent...)`-style access to the TerrainGenerator module work like in Studio
local TerrainGenerator = require(TG)
local C = TerrainGenerator.Config
C.Seed = "MyWorldName"
C.Width, C.Length = 256, 256           -- 4x4 chunks
C.BedrockLevel = 0
C.Workers.Enabled = false
C.Streaming.UnloadMargin = 1
C.Spawn.ReadyRadiusChunks = 1
C.PrintProgress = true

TerrainGenerator.RegisterBiome({ id = "crystal_meadow", base = "meadow", climate = { temperature = { -1, 1 } }, region = { scale = 300, threshold = -2 }, surface = { top = "calcite", filler = "calcite" },
	trees = { { species = "crystal_tree", perChunk = 3 } }, ores = { { name = "mana", tier = 4, perChunk = 2, minY = -10, maxY = 50, size = 5 } } })

local builds, lastCtx = 0, nil
TerrainGenerator.RegisterStructure({
	Name = "Test", Spacing = 2, Separation = 0, Chance = 1, Placement = "Any", MaxSlope = 99,
	Build = function(ctx)
		builds += 1
		lastCtx = ctx
		local p = Instance.new("Part")
		p.Parent = ctx.Parent
	end,
})
assert(not pcall(TerrainGenerator.RegisterStructure, { Name = "Test", Build = function() end }), "duplicate structure name accepted")
assert(not pcall(TerrainGenerator.RegisterStructure, { Name = "Empty" }), "structure without Model/Build accepted")

local loaded, unloaded = 0, 0
TerrainGenerator.ChunkLoaded:Connect(function() loaded += 1 end)
TerrainGenerator.ChunkUnloaded:Connect(function() unloaded += 1 end)
local spawned = false
TerrainGenerator.SpawnAreaReady:Connect(function() spawned = true end)
local initial = false
TerrainGenerator.InitialAreaLoaded:Connect(function() initial = true end)

local p1 = MOCK.newPlayer(1, 10, 10)
TerrainGenerator.Start()
assert(MOCK.PlayersService.CharacterAutoLoads == false, "characters must be held until the spawn area exists")

local t = 0
local function run(seconds)
	for _ = 1, seconds * 4 do
		MOCK.heartbeat(0.25); MOCK.advance(0.25); t += 0.25
	end
end
run(60)
local st = TerrainGenerator.GetStats()
print("after 60 s: loaded", st.loaded, "queued", st.queued, "inflight", st.inflight, "| events: loaded", loaded, "unloaded", unloaded)
assert(initial and spawned, "initial area / spawn area should be ready")
assert(MOCK.PlayersService.CharacterAutoLoads == true, "autoload re-enabled after the spawn area is ready")
local sp = MOCK.SSS.Parent and nil
print("spawn location created:", workspace:FindFirstChild("TerrainSpawn") ~= nil)

-- player 1 walks far east while player 2 joins near the origin
local p2 = MOCK.newPlayer(2, 0, 0)
for step = 1, 8 do
	p1.root.Position = Vector3.new(10 + step * 128, 700, 10)
	run(20)
end
st = TerrainGenerator.GetStats()
print("after walk: loaded", st.loaded, "queued", st.queued, "inflight", st.inflight, "| unloaded events", unloaded)
-- both windows are loaded: each is 4x4 chunks => 32 chunks (+margin chunks that stayed loaded)
local ok1 = 0
for cx = 0, 40 do for cz = -3, 3 do end end
local px = math.floor(p1.root.Position.X / 64)
for x = px - 2, px + 1 do for z = -2, 1 do assert(TerrainGenerator.IsChunkLoaded(x, z), "chunk near player 1 missing " .. x .. "," .. z) end end
for x = -2, 1 do for z = -2, 1 do assert(TerrainGenerator.IsChunkLoaded(x, z), "chunk near player 2 missing " .. x .. "," .. z) end end
print("both players' windows are fully loaded")
-- player 2 leaves
for _, f in MOCK.PlayersService._removing do f(p2) end
table.remove(MOCK.players, 2)
run(30)
for x = -2, 1 do for z = -2, 1 do
	local near1 = math.abs(x - px) <= 4
	if not near1 then assert(not TerrainGenerator.IsChunkLoaded(x, z), "chunk near the origin should unload after the player left: " .. x .. "," .. z) end
end end
print("after player 2 left, their exclusive chunks unloaded; player 1's window intact")

-- queries
local name, info = TerrainGenerator.GetBiomeAt(Vector3.new(0, 600, 0))
print("GetBiomeAt(0,600,0):", name, info.DisplayName, info.IsCustom, string.format("temp %.2f", info.Climate.temperature))
local name2 = TerrainGenerator.GetBiomeAt(1234, -987)
print("GetBiomeAt(1234,-987):", name2, "height studs:", TerrainGenerator.GetHeightAt(1234, -987))
local cx, cz = TerrainGenerator.WorldToChunk(Vector3.new(-1, 0, 64))
print("WorldToChunk(-1,0,64):", cx, cz, "WorldToBlock:", TerrainGenerator.WorldToBlock(Vector3.new(7, 64, -5)))
local n = 0
for _, f in workspace:FindFirstChild("GeneratedCollectables"):GetChildren() do n += #f:GetChildren() end
print("collectable parts alive:", n)
-- structures: built for loaded origin chunks, removed with them
assert(builds > 0, "no structure was built")
assert(lastCtx.Name == "Test" and lastCtx.Position.Y > 0 and lastCtx.Rotation % 90 == 0 and lastCtx.Chunk.X ~= nil and lastCtx.Parent ~= nil and type(lastCtx.Seed) == "number" and lastCtx.Random ~= nil, "bad ctx")
local root = workspace:FindFirstChild("GeneratedStructures")
local alive = 0
for _, f in root:GetChildren() do
	local sx, sz = string.match(f.Name, "^Test_(-?%d+)_(-?%d+)$")
	assert(sx, "unexpected structure folder " .. f.Name)
	assert(TerrainGenerator.IsChunkLoaded(tonumber(sx), tonumber(sz)), "structure of an unloaded chunk is still alive: " .. f.Name)
	assert(#f:GetChildren() == 1, "structure content missing")
	alive += 1
end
assert(alive > 0)
print("structures built:", builds, "alive:", alive, "(all belong to loaded chunks)")
print("start_local OK")
