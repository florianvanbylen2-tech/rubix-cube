--!strict
--!native
-- Chunk worker. This script lives in an Actor cloned by TerrainGenerator.Start(); the template stored in the
-- module tree is disabled so it never runs in place.
--
-- Protocol (main -> worker, via Actor messages):
--   "Init"     settings                    build the world generator (parallel), then acknowledge
--   "Generate" jobId, chunkX, chunkZ       generate the chunk in parallel, write it in the serial phase,
--                                          then report to the main thread through the Done event
-- worker -> main (BindableEvent "Events"):  ("bound") / ("ready", actorName) / ("done", jobId, cx, cz, ok, err)

local actor = script:GetActor()
if actor == nil then
	return -- not running inside an Actor (the disabled template): nothing to do
end

local modulesValue = actor:FindFirstChild("Modules") :: ObjectValue
local eventsValue = actor:FindFirstChild("Events") :: ObjectValue
local root = modulesValue.Value :: Instance
local events = eventsValue.Value :: BindableEvent

local ChunkGenerator = require((root :: any).World.ChunkGenerator)
local ChunkWriter = require((root :: any).Streaming.ChunkWriter)

local generator: any = nil
local writer: any = nil

-- Time slicing: a chunk costs 100-300 ms of CPU and a parallel task holds up its frame until it returns, so the
-- generator calls sliceYield() between its stages; once a slice has used up sliceSeconds we wait one frame.
local sliceSeconds = 0.006
local sliceStart = 0

local function sliceYield()
	if os.clock() - sliceStart >= sliceSeconds then
		task.wait()
		task.desynchronize()
		sliceStart = os.clock()
	end
end

-- The generator keeps per-chunk state, so only one job may generate at a time on this actor. (The main script
-- already hands each actor at most one job; this is a safety net, e.g. for Workers.Count changes.)
local busy = false
local waiting: { thread } = {}

local function acquire()
	if busy then
		table.insert(waiting, coroutine.running())
		coroutine.yield()
	else
		busy = true
	end
end

local function release()
	local nextJob = table.remove(waiting, 1)
	if nextJob then
		task.defer(nextJob) -- ownership passes on; busy stays true
	else
		busy = false
	end
end

actor:BindToMessageParallel("Init", function(settings: any)
	local ok, err = pcall(function()
		generator = ChunkGenerator.new(settings.seed, settings.generator)
	end)
	task.synchronize()
	if not ok then
		events:Fire("ready", actor.Name, false, tostring(err))
		return
	end
	if type(settings.sliceMs) == "number" then
		sliceSeconds = math.max(0.001, settings.sliceMs / 1000)
	end
	writer = ChunkWriter.new(settings.writer)
	ChunkWriter.setBiomeNames(writer, generator.registry.names)
	events:Fire("ready", actor.Name, true)
end)

actor:BindToMessageParallel("Generate", function(jobId: number, cx: number, cz: number)
	acquire()
	task.desynchronize()
	sliceStart = os.clock()
	local ok, result = pcall(function()
		return generator:generate(cx, cz, sliceYield)
	end)
	release()
	task.synchronize()
	local err: string? = nil
	if ok then
		local wok, werr = pcall(function()
			writer:write(result)
		end)
		if not wok then
			ok, err = false, tostring(werr)
		end
	else
		err = tostring(result)
	end
	events:Fire("done", jobId, cx, cz, ok, err)
end)

events:Fire("bound", actor.Name)
