--!strict
-- Runs chunk generation jobs for one runtime (the server, or one client): either in a pool of Actors (Parallel Luau)
-- or, when workers are disabled, one at a time on the calling thread. Jobs are handed to the least busy worker, and
-- every worker gets at most one job at a time.
--
-- opts:
--   workers    number of Actors (0 = generate on the calling thread)
--   isClient   use the LocalScript worker (clients) instead of the Script worker (server)
--   container  Instance the Actors are parented to
--   root       the TerrainGenerator module (workers require their code through it)
--   template   the Actor template (Streaming/WorkerTemplate)
--   init       { seed, generator = ChunkGenerator options, writer = WriterConfig?, sliceMs, blocks }
--   onDone     (jobId, cx, cz, ok, err, placements, topStuds)

local ChunkGenerator = require(script.Parent.Parent.World.ChunkGenerator)
local ChunkWriter = require(script.Parent.ChunkWriter)
local Blocks = require(script.Parent.Parent.World.Blocks)

local WorkerPool = {}
WorkerPool.__index = WorkerPool

function WorkerPool.new(opts: any)
	return setmetatable({
		opts = opts,
		actors = {} :: { Actor },
		load = {} :: { number },
		jobWorker = {} :: { [number]: number },
		generator = nil :: any,
		writer = nil :: any,
		queue = {} :: { { number } },
		busy = false,
		events = nil :: BindableEvent?,
		destroyed = false,
	}, WorkerPool)
end

local function finish(self: any, jobId: number, cx: number, cz: number, ok: boolean, err: string?, placements: any, top: number?)
	if self.destroyed then
		return
	end
	local w = self.jobWorker[jobId]
	if w then
		self.load[w] -= 1
		self.jobWorker[jobId] = nil
	end
	self.opts.onDone(jobId, cx, cz, ok, err, placements, top)
end

-- Yields until the workers are ready (a few seconds). Errors if they cannot start.
function WorkerPool.start(self: any)
	local opts = self.opts
	if (opts.workers or 0) <= 0 then
		Blocks.configure(opts.init.blocks)
		self.generator = ChunkGenerator.new(opts.init.seed, opts.init.generator)
		if opts.init.writer then
			self.writer = ChunkWriter.new(opts.init.writer)
			ChunkWriter.setBiomeNames(self.writer, self.generator.registry.names)
		end
		return
	end

	local events = Instance.new("BindableEvent")
	events.Name = "Events"
	events.Parent = opts.container
	self.events = events
	local count = opts.workers
	local bound, ready = 0, 0
	local failed: string? = nil
	events.Event:Connect(function(kind: string, ...)
		if kind == "bound" then
			bound += 1
		elseif kind == "ready" then
			local _, ok, err = ...
			if ok then
				ready += 1
			else
				failed = tostring(err)
			end
		elseif kind == "done" then
			local jobId, cx, cz, ok, err, placements, top = ...
			finish(self, jobId, cx, cz, ok, err, placements, top)
		end
	end)
	local scriptName = opts.isClient and "ClientWorker" or "Worker"
	for i = 1, count do
		local actor = opts.template:Clone()
		actor.Name = "Worker" .. i
		local modules = Instance.new("ObjectValue")
		modules.Name = "Modules"
		modules.Value = opts.root
		modules.Parent = actor
		local ev = Instance.new("ObjectValue")
		ev.Name = "Events"
		ev.Value = events
		ev.Parent = actor
		actor.Parent = opts.container
		;(actor:FindFirstChild(scriptName) :: any).Disabled = false
		self.actors[i] = actor
		self.load[i] = 0
	end
	local t0 = os.clock()
	while bound < count and os.clock() - t0 < 15 do
		task.wait(0.05)
	end
	assert(bound == count, "TerrainGenerator: workers failed to start (is the module inside ServerScriptService / ReplicatedStorage?)")
	for _, actor in self.actors do
		actor:SendMessage("Init", opts.init)
	end
	t0 = os.clock()
	while ready < count and not failed and os.clock() - t0 < 120 do
		task.wait(0.05)
	end
	assert(not failed, "TerrainGenerator worker failed to initialise: " .. tostring(failed))
	assert(ready == count, "TerrainGenerator: timed out waiting for workers")
end

local function runLocal(self: any, jobId: number, cx: number, cz: number)
	self.busy = true
	task.spawn(function()
		task.wait()
		local sliceStart = os.clock()
		local sliceSeconds = (self.opts.init.sliceMs or 6) / 1000
		local placements: any, top: number? = nil, nil
		local ok, err = pcall(function()
			local chunk = self.generator:generate(cx, cz, function()
				if os.clock() - sliceStart >= sliceSeconds then
					task.wait()
					sliceStart = os.clock()
				end
			end)
			placements = chunk.placements
			if self.writer then
				top = self.writer:write(chunk)
			end
		end)
		self.busy = false
		finish(self, jobId, cx, cz, ok, if err then tostring(err) else nil, if ok then placements else nil, top)
		local nextJob = table.remove(self.queue, 1)
		if nextJob and not self.destroyed then
			runLocal(self, nextJob[1], nextJob[2], nextJob[3])
		end
	end)
end

function WorkerPool.dispatch(self: any, cx: number, cz: number, jobId: number)
	if #self.actors == 0 then
		if self.busy then
			table.insert(self.queue, { jobId, cx, cz })
		else
			runLocal(self, jobId, cx, cz)
		end
		return
	end
	local best, bestLoad = 1, math.huge
	for i = 1, #self.actors do
		if self.load[i] < bestLoad then
			best, bestLoad = i, self.load[i]
		end
	end
	self.load[best] += 1
	self.jobWorker[jobId] = best
	self.actors[best]:SendMessage("Generate", jobId, cx, cz)
end

function WorkerPool.destroy(self: any)
	self.destroyed = true
	if self.opts.container and #self.actors > 0 then
		self.opts.container:Destroy()
	end
end

return WorkerPool
