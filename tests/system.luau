--@include roblox_mock.luau
-- End to end against the mocked Roblox API: the SERVER decides trees / ores / structures and publishes the world, the
-- CLIENT draws the terrain; chunk locks, LoadChunk, late joiners, spawn flow and the pig.
local TerrainGenerator = require(TG)
local Client = require(TG.Runtime.Client)
local C = TerrainGenerator.Config

local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end
local function run(seconds) for _ = 1, seconds * 4 do MOCK.heartbeat(0.25); MOCK.advance(0.25) end end
local function chunkVoxels(cx, cz)
	local n = 0
	for k in MOCK.terrain.voxels do
		local x, _, z = string.match(k, "(-?%d+),(-?%d+),(-?%d+)")
		x, z = tonumber(x), tonumber(z)
		if x >= cx * 16 and x < cx * 16 + 16 and z >= cz * 16 and z < cz * 16 + 16 then n += 1 end
	end
	return n
end
local function count(t) local n = 0 for _ in t do n += 1 end return n end

C.Seed = "SystemTest"
C.Width, C.Length = 256, 256            -- 4x4 chunks around each player
C.Workers.Enabled = false               -- generate on the calling thread (the mock has no Actors)
C.Client.Workers = 0
C.Streaming.UnloadMargin = 1
C.Spawn.ReadyRadiusChunks = 1
C.PrintProgress = false
C.Placement.Print = false
C.Mobs.Pig = true

TerrainGenerator.RegisterTree({ Name = "Crystal Tree", PerChunk = 4 })
TerrainGenerator.RegisterOre({ Name = "Mythril Ore", PerChunk = 3, MinY = -40, MaxY = 40, Size = 5 })
TerrainGenerator.RegisterStructure({ Name = "Test Hut", Spacing = 2, Separation = 0, Placement = "Any", MaxSlope = 99, Salt = 77 })
check(not pcall(TerrainGenerator.RegisterTree, { Name = "Oak Tree" }), "duplicate default tree accepted")
check(not pcall(TerrainGenerator.RegisterStructure, { Name = "Bad", Spacing = 3, Separation = 3 }), "invalid structure accepted")
local names = TerrainGenerator.GetThingNames()
check(table.find(names.Trees, "Crystal Tree") and table.find(names.Ores, "Mythril Ore") and table.find(names.Structures, "Village") and table.find(names.Structures, "Medieval Castle"), "thing names")

local placed, removed = {}, {}
TerrainGenerator.SetPlacementHandler(function(name, pos, info) table.insert(placed, { name, pos, info }) end)
TerrainGenerator.SetRemovalHandler(function(cx, cz) table.insert(removed, { cx, cz }) end)

local p1 = MOCK.newPlayer(1, nil, nil, true) -- the local player (also what the server sees)
local locksSeen = 0
TerrainGenerator.SpawnAreaReady:Connect(function() locksSeen += 1 end)

-- ---------------------------------------------------------------- server start: no terrain, things only
local serverUp = false
task.spawn(function() TerrainGenerator.StartServer(); serverUp = true end)
check(MOCK.PlayersService.CharacterAutoLoads == false, "characters must be held from the first moment")
run(40)
check(serverUp, "server did not finish starting")
local state = MOCK.RS:FindFirstChild("TerrainGeneratorState")
check(state and state:GetAttribute("Ready") and state:GetAttribute("Spawn") and state:GetAttribute("Config"), "state not published")
check(MOCK.RS:FindFirstChild("TerrainGenerator") ~= nil, "module copy for clients missing")
check(workspace:FindFirstChild("TerrainSpawn") ~= nil, "spawn pad missing")
local st = TerrainGenerator.GetStats()
check(st.loaded >= 4, "spawn lock area should be loaded on the server, loaded=" .. st.loaded)
check(count(MOCK.terrain.voxels) == 0, "the server must not write any terrain in TerrainMode Client")
check(#placed > 0, "no placeThing calls")
local kinds, byName = {}, {}
for _, rec in placed do
	local name, pos, info = rec[1], rec[2], rec[3]
	kinds[info.Kind] = true
	byName[name] = (byName[name] or 0) + 1
	check(type(name) == "string" and typeof(pos) == "Vector3" and info.Biome and info.Chunk and info.Seed, "bad placeThing arguments")
end
check(kinds.Tree and kinds.Ore and kinds.Structure, "expected trees, ores and structures")
check(byName["Crystal Tree"] and byName["Mythril Ore"] and byName["Test Hut"], "custom things were not placed")
check(p1.loads == nil, "character spawned before the client had terrain")
print(string.format("server: %d chunks loaded, %d placeThing calls (%s), no terrain written", st.loaded, #placed,
	(function() local l = {} for k, v in byName do table.insert(l, k .. "=" .. v) end table.sort(l) return table.concat(l, " ", 1, math.min(#l, 6)) end)()))

-- ---------------------------------------------------------------- the client: draws terrain, then the character spawns
local clientUp = false
task.spawn(function() TerrainGenerator.StartClient(); clientUp = true end)
run(60)
check(clientUp, "client did not finish starting")
check(count(MOCK.terrain.voxels) > 0, "client wrote no terrain")
check(p1.loads == 1, "character should spawn exactly once after the client reported ready, loads=" .. tostring(p1.loads))
local spawn = TerrainGenerator.GetSpawnPoint()
check(spawn ~= nil, "spawn point")
local pig = workspace:FindFirstChild("Pig")
check(pig ~= nil, "pig missing")
local body = pig:FindFirstChild("Body") or pig._children[1]
local pos0 = body.CFrame.Position
run(30)
local pos1 = body.CFrame.Position
check(pos0.X ~= pos1.X or pos0.Z ~= pos1.Z, "the pig should move")
local spawnCx, spawnCz = TerrainGenerator.WorldToChunk(spawn)
check(chunkVoxels(spawnCx, spawnCz) > 0, "no terrain at the spawn point")
print("client: terrain drawn around spawn chunk", spawnCx, spawnCz, "- character spawned, pig walking")

-- ---------------------------------------------------------------- the player walks far away; spawn stays (it is locked)
local before = chunkVoxels(spawnCx, spawnCz)
MOCK.setPosition(p1, 64 * 60, 64 * 40)
run(60)
check(chunkVoxels(spawnCx, spawnCz) > 0 and TerrainGenerator.IsChunkLocked(spawnCx, spawnCz), "locked spawn chunk unloaded when the player left")
check(chunkVoxels(60, 40) > 0, "terrain around the player missing")
check(#removed > 0, "removeThings was never called for unloaded chunks")
print("walk: spawn area stayed (locked), terrain followed the player, removeThings called", #removed, "times")

-- ---------------------------------------------------------------- locks and LoadChunk
check(chunkVoxels(150, 150) == 0, "precondition")
check(TerrainGenerator.LockArea(150, 150, 151, 150, "test") == 2, "LockArea count")
run(40)
check(TerrainGenerator.IsChunkLoaded(150, 150) and chunkVoxels(150, 150) > 0 and chunkVoxels(151, 150) > 0, "locked far chunks must load on server and client")
check(TerrainGenerator.IsChunkLocked(150, 150, "test") and not TerrainGenerator.IsChunkLocked(150, 150, "other"), "owner-specific lock query")
TerrainGenerator.LockChunk(150, 150, "other")
TerrainGenerator.UnlockArea(150, 150, 151, 150, "test")
run(20)
check(chunkVoxels(150, 150) > 0 and chunkVoxels(151, 150) == 0, "chunk with a second owner must stay, the other must unload")
TerrainGenerator.UnlockChunk(150, 150, "other")
run(20)
check(chunkVoxels(150, 150) == 0, "unlocked chunk should unload")

local loaded: boolean? = nil
task.spawn(function() loaded = TerrainGenerator.LoadChunk(-120, 90) end)
run(30)
check(loaded == true, "LoadChunk should return true once the chunk is loaded")
check(TerrainGenerator.IsChunkLocked(-120, 90) and chunkVoxels(-120, 90) > 0, "LoadChunk locks by default and the client draws it")
local temp: boolean? = nil
task.spawn(function() temp = TerrainGenerator.LoadChunk(-130, 90, { Lock = false, HoldSeconds = 4 }) end)
run(10)
check(temp == true, "temporary LoadChunk")
run(30)
check(chunkVoxels(-130, 90) == 0 and not TerrainGenerator.IsChunkLoaded(-130, 90), "temporary chunk must unload after HoldSeconds")
check(TerrainGenerator.IsChunkLoaded(-120, 90), "locked chunk must stay")
print("locks: LockArea / owners / UnlockArea / LoadChunk (locked and temporary) behave")

-- ---------------------------------------------------------------- a player who joins late gets every lock
TerrainGenerator.LockArea(-200, -200, -199, -199, "late")
run(30)
local lateSignals = { chunkLoaded = { Fire = function() end }, chunkUnloaded = { Fire = function() end }, spawn = { Fire = function() end } }
local late
task.spawn(function() late = Client.start({ Config = C, module = TG, signals = lateSignals, setCustomBiomes = function() end }) end)
run(240) -- one chunk at a time, each yielding to the next frame every few ms of work
check(late ~= nil, "late client did not start")
local ls = late.stats()
check(ls.locked >= 4 + 1 + 4, "late client should know all locks, knows " .. ls.locked)
for x = -200, -199 do for z = -200, -199 do check(late.isLoaded(x, z), "late client did not load locked chunk " .. x .. "," .. z) end end
check(late.isLoaded(-120, 90), "late client did not load the LoadChunk chunk")
late.stop()
print("late join: a second client loaded all", ls.locked, "locked chunks")

-- ---------------------------------------------------------------- respawn goes through the same gate
local loads0 = p1.loads
local hum = p1.Character:FindFirstChild("Humanoid")
hum._signals.Died:Fire()
run(8)
check(p1.loads == loads0 + 1, "player should respawn after RespawnTime")

-- ---------------------------------------------------------------- stop
TerrainGenerator.Stop()
check(MOCK.RS:FindFirstChild("TerrainGeneratorState") == nil, "state folder should be removed on stop")
print("system OK")
