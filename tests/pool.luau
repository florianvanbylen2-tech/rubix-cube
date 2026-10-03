--@include roblox_mock.luau
-- WorkerPool with emulated Actors: job dispatch, one job per worker, results identical to direct generation,
-- server-style (placements) and client-style (terrain writes) workers.
local WorkerPool = require(TG.Streaming.WorkerPool)
local WorkerMain = require(TG.Streaming.WorkerMain)
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Shared = require(TG.Runtime.Shared)
local Config = require(TG.Config)

local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end
local function run(seconds) for _ = 1, seconds * 4 do MOCK.heartbeat(0.25); MOCK.advance(0.25) end end

-- what the Worker / ClientWorker stub scripts do once enabled
MOCK.onScriptEnabled = function(scriptInst) WorkerMain(scriptInst) end

local function template()
	local a = Instance.new("Actor")
	for _, name in { "Worker", "ClientWorker" } do
		local s = Instance.new(name == "Worker" and "Script" or "LocalScript")
		s.Name = name
		s.Disabled = true
		s.Parent = a
	end
	return a
end

local function makePool(isClient, results)
	local container = Instance.new("Folder")
	local o = Shared.generatorOptions(Config, isClient and "client" or "server", {})
	local pool = WorkerPool.new({
		workers = 2, isClient = isClient, container = container, root = TG, template = template(),
		init = { seed = 12345, generator = o, writer = isClient and Shared.writerConfig(Config, math.huge) or nil, sliceMs = 5, blocks = Shared.blocksSpec(Config) },
		onDone = function(jobId, cx, cz, ok, err, placements, top) table.insert(results, { jobId, cx, cz, ok, err, placements, top }) end,
	})
	return pool, container
end

-- server-style: returns placements, writes nothing
do
	local results = {}
	local pool, container = makePool(false, results)
	local started = false
	task.spawn(function() pool:start() started = true end)
	run(5)
	check(started, "pool did not start")
	check(#container:GetChildren() == 3, "expected the events object and 2 actors")
	for i = 1, 4 do pool:dispatch(10 + i, -3, i) end
	check(pool.load[1] + pool.load[2] == 4 and pool.load[1] == 2 and pool.load[2] == 2, "jobs should spread over the workers")
	run(60)
	check(#results == 4, "expected 4 results, got " .. #results)
	local direct = ChunkGenerator.new(12345, Shared.generatorOptions(Config, "server", {}))
	for _, r in results do
		check(r[4] == true and r[7] == nil, "server worker must not write terrain")
		local d = direct:generate(r[2], r[3])
		check(#r[6] == #d.placements, string.format("chunk %d,%d: placements differ (%d vs %d)", r[2], r[3], #r[6], #d.placements))
	end
	check(pool.load[1] == 0 and pool.load[2] == 0, "load accounting")
	check(next(MOCK.terrain.voxels) == nil, "server-style workers wrote terrain")
	print("server-style pool: 4 jobs over 2 workers, placements identical to direct generation")
	pool:destroy()
end

-- client-style: writes terrain, returns the written height, no placements
do
	local results = {}
	local pool = makePool(true, results)
	task.spawn(function() pool:start() end)
	run(5)
	for i = 1, 3 do pool:dispatch(30 + i, 4, i) end
	run(60)
	check(#results == 3, "expected 3 results, got " .. #results)
	for _, r in results do
		check(r[4] == true and r[6] == nil and type(r[7]) == "number" and r[7] > 0, "client worker must write terrain and report its height")
		local n = 0
		for k in MOCK.terrain.voxels do
			local x, _, z = string.match(k, "(-?%d+),(-?%d+),(-?%d+)")
			if tonumber(x) >= r[2] * 16 and tonumber(x) < r[2] * 16 + 16 and tonumber(z) >= r[3] * 16 and tonumber(z) < r[3] * 16 + 16 then n += 1 end
		end
		check(n > 1000, "no terrain written for chunk " .. r[2] .. "," .. r[3])
	end
	print("client-style pool: terrain written by the workers, heights reported")
end
print("pool OK")
