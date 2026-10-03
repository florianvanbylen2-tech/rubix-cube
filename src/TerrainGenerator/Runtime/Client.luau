--!strict
-- Client runtime. In TerrainMode "Client" every client generates and draws the terrain around its own player (plus
-- every locked chunk the server announces, including the ones that were locked before this player joined), using
-- Roblox Terrain writes that stay local to this client. In TerrainMode "Server" the client only runs the pig.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ChunkManager = require(script.Parent.Parent.Streaming.ChunkManager)
local ChunkWriter = require(script.Parent.Parent.Streaming.ChunkWriter)
local LoadGovernor = require(script.Parent.Parent.Streaming.LoadGovernor)
local LockRegistry = require(script.Parent.Parent.Streaming.LockRegistry)
local WorkerPool = require(script.Parent.Parent.Streaming.WorkerPool)
local Blocks = require(script.Parent.Parent.World.Blocks)
local RandomState = require(script.Parent.Parent.World.RandomState)
local Pig = require(script.Parent.Parent.Mobs.Pig)
local Shared = require(script.Parent.Shared)

local VOXEL = 4
local CHUNK = 16 * VOXEL

local Client = {}

-- env: { Config, module, setCustomBiomes, signals = { chunkLoaded, chunkUnloaded, spawn } }
function Client.start(env: any): any
	local cfg = env.Config
	local signals = env.signals
	local ctl: any = {}
	local connections: { RBXScriptConnection } = {}
	local stopped = false

	local state = ReplicatedStorage:WaitForChild("TerrainGeneratorState", 120) :: Folder
	assert(state, "TerrainGenerator: the server never published its world (is TerrainGenerator.Start() running on the server?)")
	while not state:GetAttribute("Ready") do
		task.wait(0.1)
	end
	local customBiomes = Shared.apply(cfg, state:GetAttribute("Config") :: string)
	env.setCustomBiomes(customBiomes)
	local blocksSpec = Shared.blocksSpec(cfg)
	Blocks.configure(blocksSpec)
	local spawnGround = state:GetAttribute("Spawn") :: Vector3
	ctl.spawnPoint = spawnGround

	local pig: any = nil
	local function startPig()
		if cfg.Mobs.Pig and not pig then
			local seedHigh, seedLow = RandomState.seedFrom(cfg.Seed)
			pig = Pig.start({ seed = (seedLow + seedHigh) % 1000003, home = spawnGround + Vector3.new(10, 0, 10) })
		end
	end

	if cfg.TerrainMode ~= "Client" then
		startPig()
		function ctl.stop()
			if pig then
				pig.stop()
			end
		end
		function ctl.isLoaded(): boolean
			return false
		end
		function ctl.stats(): { [string]: number }
			return { loaded = 0, queued = 0, inflight = 0, sources = 0, locked = 0 }
		end
		function ctl.isLocked(): boolean
			return false
		end
		return ctl
	end

	-- ------------------------------------------------------------------------------------ terrain pipeline
	local localPlayer = Players.LocalPlayer
	local writerConfig = Shared.writerConfig(cfg, cfg.Client.WriteBudgetMs)
	local writer = ChunkWriter.new(writerConfig)
	ChunkWriter.applyGlobals(writerConfig)
	if cfg.ClearBeforeGenerating then
		workspace.Terrain:Clear()
	end

	local width = cfg.Client.Width or cfg.Width
	local length = cfg.Client.Length or cfg.Length
	local rx = math.max(1, math.ceil(width / CHUNK / 2))
	local rz = math.max(1, math.ceil(length / CHUNK / 2))
	local tops: { [number]: number } = {}
	local manager: any = nil

	local workerCount = math.max(0, cfg.Client.Workers)
	local container: Instance? = nil
	if workerCount > 0 then
		local scripts = localPlayer:WaitForChild("PlayerScripts")
		local folder = Instance.new("Folder")
		folder.Name = "TerrainGeneratorWorkers"
		folder.Parent = scripts
		container = folder
	end
	local pool = WorkerPool.new({
		workers = workerCount,
		isClient = true,
		container = container,
		root = env.module,
		template = env.module.Streaming.WorkerTemplate,
		init = {
			seed = cfg.Seed,
			generator = Shared.generatorOptions(cfg, "client", customBiomes),
			writer = writerConfig,
			sliceMs = cfg.Client.SliceMs,
			blocks = blocksSpec,
		},
		onDone = function(jobId: number, cx: number, cz: number, ok: boolean, err: string?, _placements: any, top: number?)
			if stopped then
				return
			end
			if ok and top then
				tops[LockRegistry.key(cx, cz)] = top
			end
			manager:onDone(jobId, cx, cz, ok, err)
		end,
	})
	pool:start()

	local jobCap = if workerCount > 0 then math.min(cfg.Client.MaxChunksInFlight, workerCount) else 1
	manager = ChunkManager.new({
		radius = rx,
		radiusZ = rz,
		margin = cfg.Streaming.UnloadMargin,
		maxInFlight = jobCap,
		playerGrace = cfg.Streaming.PlayerGraceSeconds,
	}, {
		dispatch = function(cx: number, cz: number, jobId: number)
			pool:dispatch(cx, cz, jobId)
		end,
		unload = function(cx: number, cz: number)
			local k = LockRegistry.key(cx, cz)
			writer:unload(cx, cz, tops[k])
			tops[k] = nil
			signals.chunkUnloaded:Fire(cx, cz)
		end,
		onLoaded = function(cx: number, cz: number)
			signals.chunkLoaded:Fire(cx, cz)
		end,
		onFailed = function(cx: number, cz: number, err: string)
			warn(string.format("[TerrainGenerator] chunk (%d, %d) failed: %s", cx, cz, err))
		end,
	})

	-- the lock list the server announced (also the ones locked before we joined)
	local lockedSet: { [number]: boolean } = {}
	local function refreshLocks()
		local parts = Shared.readLocks(state)
		if parts == nil then
			return -- not completely replicated yet; the next attribute change retries
		end
		lockedSet = LockRegistry.decode(parts)
		manager:setLocked(lockedSet)
	end
	refreshLocks()
	table.insert(
		connections,
		state.AttributeChanged:Connect(function(name: string)
			if string.sub(name, 1, 5) == "Locks" then
				refreshLocks()
			end
		end)
	)

	-- ------------------------------------------------------------------------------------ loop
	local spawnChunkX, spawnChunkZ = math.floor(spawnGround.X / CHUNK), math.floor(spawnGround.Z / CHUNK)
	local readyR = math.max(1, cfg.Spawn.ReadyRadiusChunks)
	local reportedReady = false
	local accumulator = 0
	local governor = LoadGovernor.new(jobCap, cfg.Streaming.TargetFrameMs / 1000)
	local heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		governor:sample(dt)
		accumulator += dt
		if accumulator < cfg.Streaming.UpdateInterval then
			return
		end
		accumulator = 0
		local limit = if cfg.Streaming.AdaptiveLoad and reportedReady then governor:step() else jobCap
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local pcx, pcz = math.floor(root.Position.X / CHUNK), math.floor(root.Position.Z / CHUNK)
			manager:setPlayer("me", pcx, pcz)
			if limit == 0 and not manager:isLoaded(pcx, pcz) then
				limit = 1 -- never pause while the chunk under the player is missing
			end
		else
			manager:touchPlayer("me")
		end
		manager.maxInFlight = limit
		manager:update()

		if not reportedReady then
			local n, total = manager:loadedInBox(spawnChunkX, spawnChunkZ, readyR)
			if n == total then
				reportedReady = true
				signals.spawn:Fire()
				local remote = state:FindFirstChild("ClientReady") :: RemoteEvent?
				if remote then
					remote:FireServer()
				end
				if cfg.PrintProgress then
					print("[TerrainGenerator] terrain around the spawn point is ready")
				end
				startPig()
			end
		end
	end)
	table.insert(connections, heartbeat)

	-- ------------------------------------------------------------------------------------ control surface
	function ctl.isLoaded(cx: number, cz: number): boolean
		return manager:isLoaded(cx, cz)
	end

	function ctl.isLocked(cx: number, cz: number): boolean
		return lockedSet[LockRegistry.key(cx, cz)] == true
	end

	function ctl.stats(): { [string]: number }
		return manager:stats()
	end

	function ctl.stop()
		stopped = true
		for _, c in connections do
			c:Disconnect()
		end
		pool:destroy()
		if pig then
			pig.stop()
		end
	end

	return ctl
end

return Client
