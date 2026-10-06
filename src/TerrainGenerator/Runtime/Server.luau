--!strict
-- Server runtime. In TerrainMode "Client" (default) the server writes no terrain at all: it publishes the world
-- settings and the lock list to the clients, and decides everything that is NOT terrain (trees, ores, structures):
-- it generates the chunks around players and locks in server-side workers and calls Placement.placeThing for what
-- they find. In TerrainMode "Server" it also writes the terrain, like a classic Roblox world.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ChunkManager = require(script.Parent.Parent.Streaming.ChunkManager)
local ChunkWriter = require(script.Parent.Parent.Streaming.ChunkWriter)
local LoadGovernor = require(script.Parent.Parent.Streaming.LoadGovernor)
local LockRegistry = require(script.Parent.Parent.Streaming.LockRegistry)
local WorkerPool = require(script.Parent.Parent.Streaming.WorkerPool)
local Placement = require(script.Parent.Parent.Placement)
local Queries = require(script.Parent.Parent.World.Queries)
local Blocks = require(script.Parent.Parent.World.Blocks)
local Settings = require(script.Parent.Parent.Data.Settings)
local Shared = require(script.Parent.Shared)
local SpawnHub = require(script.Parent.SpawnHub)

local MIN_Y = Settings.minY
local SEA_LEVEL = Settings.seaLevel
local VOXEL = 4
local CHUNK = 16 * VOXEL

local Server = {}

-- Finds dry land near (0, 0): returns block x, z and the y of the ground block, searching in growing square rings.
local function findSpawn(gen: any, flat: boolean): (number, number, number)
	local bestX, bestZ, bestY = 0, 0, -math.huge
	local evaluated = 0
	for ring = 0, 32 do
		local r = ring * 16
		local points: { { number } } = {}
		if ring == 0 then
			points = { { 0, 0 } }
		else
			for t = -r, r, 16 do
				table.insert(points, { t, -r })
				table.insert(points, { t, r })
				table.insert(points, { -r, t })
				table.insert(points, { r, t })
			end
		end
		for _, p in points do
			local y = Queries.surfaceY(gen, p[1], p[2])
			if y >= SEA_LEVEL + 2 then
				if not flat then
					return p[1], p[2], y
				end
				-- the hall needs level ground: its corners may differ by at most 3 blocks
				local lo, hi = y, y
				for _, c in { { -8, -8 }, { 8, -8 }, { -8, 8 }, { 8, 8 } } do
					local cy = Queries.surfaceY(gen, p[1] + c[1], p[2] + c[2])
					lo, hi = math.min(lo, cy), math.max(hi, cy)
				end
				if hi - lo <= 3 and lo >= SEA_LEVEL + 1 then
					return p[1], p[2], y
				end
			end
			if y > bestY then
				bestX, bestZ, bestY = p[1], p[2], y
			end
			evaluated += 1
			if evaluated % 8 == 0 then
				task.wait() -- never block the server for long
			end
		end
	end
	return bestX, bestZ, bestY
end

Server.findSpawn = findSpawn -- exposed for tests

-- env: { Config, module, customBiomes, getQueryGenerator, signals = { chunkLoaded, chunkUnloaded, initial, spawn } }
function Server.start(env: any): any
	assert(RunService:IsServer(), "TerrainGenerator server runtime must run on the server")
	local cfg = env.Config
	local clientMode = cfg.TerrainMode == "Client"
	local base = Shared.baseY(cfg)
	local signals = env.signals

	-- hold characters from the first moment: nobody may spawn before their client has terrain to stand on
	if cfg.Spawn.AutoSpawn then
		Players.CharacterAutoLoads = false
	end
	Placement.configure(cfg.Placement.Print, cfg.Placement.MaxPrintsPerSecond)
	local blocksSpec = Shared.blocksSpec(cfg)
	Blocks.configure(blocksSpec)

	local ctl: any = {}
	local manager: any = nil
	local pool: any = nil
	local writer: any = nil
	local heartbeat: RBXScriptConnection? = nil
	local connections: { RBXScriptConnection } = {}
	local state: Folder? = nil
	local container: Folder? = nil
	local tops: { [number]: number } = {} -- studs of terrain written per chunk (TerrainMode "Server")
	local placed: { [number]: boolean } = {} -- chunks whose things were handed to placeThing
	local clientReady: { [Player]: boolean } = {}
	local spawnAreaLoaded = false
	local initialLoaded = false
	local lockVersion = 0
	local locksDirty = false
	local stopped = false
	local tempOwnerCounter = 0

	-- ------------------------------------------------------------------------------------ locks
	local locks = env.locks -- created by init so locks can be set before Start()
	locks.onChange = function()
		locksDirty = true
	end
	ctl.locks = locks

	local function flushLocks()
		if not locksDirty then
			return
		end
		locksDirty = false
		local set = locks:union()
		if manager then
			manager:setLocked(set)
		end
		if state then
			lockVersion += 1
			Shared.publishLocks(state, LockRegistry.encode(set), lockVersion)
		end
	end

	-- ------------------------------------------------------------------------------------ things -> placeThing
	local function processPlacements(cx: number, cz: number, list: { any })
		local budget = math.max(0.001, cfg.Streaming.WriteBudgetMs / 1000)
		local t0 = os.clock()
		for _, rec in list do
			local pos: Vector3
			if rec.kind == "Ore" then
				pos = Vector3.new(rec.x * VOXEL, base + (rec.y - MIN_Y) * VOXEL, rec.z * VOXEL)
			else
				pos = Vector3.new((rec.x + 0.5) * VOXEL, base + (rec.y - MIN_Y) * VOXEL, (rec.z + 0.5) * VOXEL)
			end
			local info = {
				Kind = rec.kind,
				Biome = rec.biome,
				Chunk = Vector2.new(cx, cz),
				Seed = rec.seed,
				Rotation = rec.rot and rec.rot * 90 or nil,
				Size = rec.size,
				Height = rec.height,
			}
			local ok, err = pcall(Placement.placeThing, rec.name, pos, info)
			if not ok then
				warn(string.format("[TerrainGenerator] placeThing(%s) failed: %s", tostring(rec.name), tostring(err)))
			end
			if os.clock() - t0 > budget then
				task.wait()
				t0 = os.clock()
			end
		end
	end

	-- ------------------------------------------------------------------------------------ the world
	local rx = math.max(1, math.ceil((cfg.Server.Width or cfg.Width) / CHUNK / 2))
	local rz = math.max(1, math.ceil((cfg.Server.Length or cfg.Length) / CHUNK / 2))

	local function onPoolDone(jobId: number, cx: number, cz: number, ok: boolean, err: string?, placements: any, top: number?)
		task.spawn(function()
			if stopped then
				return
			end
			local k = LockRegistry.key(cx, cz)
			if ok then
				if top then
					tops[k] = top
				end
				if placements and #placements > 0 then
					placed[k] = true
					processPlacements(cx, cz, placements)
				end
			end
			manager:onDone(jobId, cx, cz, ok, err)
		end)
	end

	-- 1. generator for queries + spawn point (before anything is published)
	local queryGen = env.getQueryGenerator()
	local sbx, sbz, sby = findSpawn(queryGen, cfg.SpawnHub.Enabled)
	local spawnGround = Vector3.new((sbx + 0.5) * VOXEL, base + (sby - MIN_Y + 1) * VOXEL, (sbz + 0.5) * VOXEL)
	ctl.spawnPoint = spawnGround
	local spawnChunkX, spawnChunkZ = math.floor(sbx / 16), math.floor(sbz / 16)
	local readyR = math.max(1, cfg.Spawn.ReadyRadiusChunks)
	locks:lockArea(spawnChunkX - readyR, spawnChunkZ - readyR, spawnChunkX + readyR - 1, spawnChunkZ + readyR - 1, "spawn")

	-- 2. publish the world to clients
	local stateFolder = Instance.new("Folder")
	stateFolder.Name = "TerrainGeneratorState"
	local remote = Instance.new("RemoteEvent")
	remote.Name = "ClientReady"
	remote.Parent = stateFolder
	Shared.publishConfig(stateFolder, Shared.serialize(cfg, env.customBiomes))
	stateFolder:SetAttribute("Spawn", spawnGround)
	local strikeRemote = Instance.new("RemoteEvent")
	strikeRemote.Name = "KingStrike"
	strikeRemote.Parent = stateFolder
	if cfg.SpawnHub.Enabled then
		stateFolder:SetAttribute("Hub", spawnGround)
	end
	state = stateFolder
	locksDirty = true
	flushLocks()
	local old = ReplicatedStorage:FindFirstChild("TerrainGeneratorState")
	if old then
		old:Destroy()
	end
	stateFolder:SetAttribute("Ready", true)
	stateFolder.Parent = ReplicatedStorage
	table.insert(
		connections,
		remote.OnServerEvent:Connect(function(player: Player)
			clientReady[player] = true
		end)
	)
	env.deployClient()

	-- the spawn hall (server-side parts, so every client sees it): safe zone + King Jeffry's lightning
	if cfg.SpawnHub.Enabled then
		ctl.hub = SpawnHub.start({ Config = cfg, center = spawnGround, strikeRemote = strikeRemote })
	end

	-- 3. generation pool + manager
	writer = if clientMode then nil else ChunkWriter.new(Shared.writerConfig(cfg, cfg.Streaming.WriteBudgetMs))
	if not clientMode then
		if cfg.ClearBeforeGenerating then
			workspace.Terrain:Clear()
		end
		ChunkWriter.applyGlobals(Shared.writerConfig(cfg, cfg.Streaming.WriteBudgetMs))
	end
	local workerCount = if cfg.Workers.Enabled then math.max(1, cfg.Workers.Count) else 0
	local fold = Instance.new("Folder")
	fold.Name = "TerrainGeneratorWorkers"
	fold.Parent = ServerScriptService
	container = fold
	pool = WorkerPool.new({
		workers = workerCount,
		isClient = false,
		container = fold,
		root = env.module,
		template = env.module.Streaming.WorkerTemplate,
		init = {
			seed = cfg.Seed,
			generator = Shared.generatorOptions(cfg, "server", env.customBiomes),
			writer = if clientMode then nil else Shared.writerConfig(cfg, cfg.Streaming.WriteBudgetMs),
			sliceMs = cfg.Workers.SliceMs,
			blocks = blocksSpec,
		},
		onDone = onPoolDone,
	})
	pool:start()
	if cfg.PrintProgress then
		print(string.format("[TerrainGenerator] server ready (%s terrain, %d worker(s)); spawn point (%.0f, %.0f, %.0f)", cfg.TerrainMode, workerCount, spawnGround.X, spawnGround.Y, spawnGround.Z))
	end

	local jobCap = if workerCount > 0 then math.min(cfg.Streaming.MaxChunksInFlight, workerCount) else 1
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
			if writer then
				writer:unload(cx, cz, tops[k])
			end
			tops[k] = nil
			if placed[k] then
				placed[k] = nil
				local ok, err = pcall(Placement.removeThings, cx, cz)
				if not ok then
					warn("[TerrainGenerator] removeThings failed: " .. tostring(err))
				end
			end
			signals.chunkUnloaded:Fire(cx, cz)
		end,
		onLoaded = function(cx: number, cz: number)
			signals.chunkLoaded:Fire(cx, cz)
		end,
		onFailed = function(cx: number, cz: number, err: string)
			warn(string.format("[TerrainGenerator] chunk (%d, %d) failed: %s", cx, cz, err))
		end,
	})
	manager:setLocked(locks:union())
	if not clientMode then
		manager:setAnchor("initial", 0, 0, rx, rz)
	end

	-- ------------------------------------------------------------------------------------ players
	local function spawnCharacter(player: Player)
		if not cfg.Spawn.AutoSpawn then
			return
		end
		task.spawn(function()
			local t0 = os.clock()
			while player.Parent and not stopped and os.clock() - t0 < 90 do
				if clientMode then
					if clientReady[player] then
						break
					end
				elseif spawnAreaLoaded then
					break
				end
				task.wait(0.1)
			end
			if player.Parent and not stopped then
				player:LoadCharacter()
			end
		end)
	end

	local watched: { [Player]: boolean } = {}
	local function watchPlayer(player: Player)
		if watched[player] then
			return
		end
		watched[player] = true
		table.insert(
			connections,
			player.CharacterAdded:Connect(function(character: Model)
				if not cfg.Spawn.AutoSpawn then
					return
				end
				local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
				if humanoid then
					humanoid.Died:Connect(function()
						task.delay(Players.RespawnTime, function()
							if player.Parent and player.Character == character and not stopped then
								player:LoadCharacter()
							end
						end)
					end)
				end
			end)
		)
		spawnCharacter(player)
	end

	if cfg.Spawn.AutoSpawn then
		-- the spawn pad: characters are placed on it by LoadCharacter
		local pad = Instance.new("SpawnLocation")
		pad.Name = "TerrainSpawn"
		pad.Anchored = true
		pad.CanCollide = false
		pad.Transparency = 1
		pad.Size = if cfg.SpawnHub.Enabled then Vector3.new(14, 1, 14) else Vector3.new(6, 1, 6)
		pad.Neutral = true
		pad.Duration = 0
		pad.Position = spawnGround + (if cfg.SpawnHub.Enabled then Vector3.new(0, 0.5, 10) else Vector3.new(0, 0.5, 0))
		pad.Parent = workspace
		ctl.pad = pad
	end
	table.insert(
		connections,
		Players.PlayerAdded:Connect(function(player: Player)
			watchPlayer(player)
		end)
	)
	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			manager:removePlayer(tostring(player.UserId))
			clientReady[player] = nil
			watched[player] = nil
		end)
	)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	-- ------------------------------------------------------------------------------------ loop
	local accumulator = 0
	local governor = LoadGovernor.new(jobCap, cfg.Streaming.TargetFrameMs / 1000)
	local lastPercent = -1
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		governor:sample(dt)
		accumulator += dt
		if accumulator < cfg.Streaming.UpdateInterval then
			return
		end
		accumulator = 0
		manager.maxInFlight = if cfg.Streaming.AdaptiveLoad and spawnAreaLoaded then governor:step() else jobCap
		for _, player in Players:GetPlayers() do
			local id = tostring(player.UserId)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				manager:setPlayer(id, math.floor(root.Position.X / CHUNK), math.floor(root.Position.Z / CHUNK))
			else
				manager:touchPlayer(id)
			end
		end
		flushLocks()
		manager:update()

		if not spawnAreaLoaded then
			local n, total = manager:loadedInBox(spawnChunkX, spawnChunkZ, readyR)
			if n == total then
				spawnAreaLoaded = true
				signals.spawn:Fire()
			end
		end
		if clientMode then
			if not initialLoaded and spawnAreaLoaded then
				initialLoaded = true
				signals.initial:Fire()
			end
		elseif not initialLoaded then
			local loaded = 0
			for x = -rx, rx - 1 do
				for z = -rz, rz - 1 do
					if manager:isLoaded(x, z) then
						loaded += 1
					end
				end
			end
			local total = (2 * rx) * (2 * rz)
			local percent = math.floor(loaded / total * 100)
			if cfg.PrintProgress and percent >= lastPercent + 10 then
				lastPercent = percent - percent % 10
				print(string.format("[TerrainGenerator] initial area %d%% (%d/%d chunks)", percent, loaded, total))
			end
			if loaded == total then
				initialLoaded = true
				if not cfg.Streaming.KeepInitialArea then
					manager:removeAnchor("initial")
				end
				signals.initial:Fire()
			end
		end
	end)

	-- ------------------------------------------------------------------------------------ control surface
	function ctl.isLoaded(cx: number, cz: number): boolean
		return manager ~= nil and manager:isLoaded(cx, cz)
	end

	function ctl.stats(): { [string]: number }
		return manager:stats()
	end

	function ctl.initialLoaded(): boolean
		return initialLoaded
	end

	function ctl.lockArea(cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
		return locks:lockArea(cx0, cz0, cx1, cz1, owner)
	end

	function ctl.unlockArea(cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
		return locks:unlockArea(cx0, cz0, cx1, cz1, owner)
	end

	-- Loads a chunk wherever it is. Options: Lock (default true: keep it until unlocked), Owner (lock owner),
	-- HoldSeconds (Lock = false: keep it this long, default 10), Wait (default true: yield until loaded), Timeout.
	function ctl.loadChunk(cx: number, cz: number, options: any?): boolean
		local o = options or {}
		if o.Lock ~= false then
			locks:lockChunk(cx, cz, o.Owner or "LoadChunk")
		else
			tempOwnerCounter += 1
			local temp = "LoadChunk/temp/" .. tempOwnerCounter
			locks:lockChunk(cx, cz, temp)
			task.delay(o.HoldSeconds or 10, function()
				locks:unlockChunk(cx, cz, temp)
			end)
		end
		flushLocks()
		manager:update()
		if o.Wait == false then
			return true
		end
		local deadline = os.clock() + (o.Timeout or 60)
		while not manager:isLoaded(cx, cz) and os.clock() < deadline and not stopped do
			task.wait(0.1)
		end
		return manager:isLoaded(cx, cz)
	end

	function ctl.reportAttack(attacker: Player, victim: Player): boolean
		return ctl.hub ~= nil and ctl.hub.reportAttack(attacker, victim)
	end

	function ctl.isInSafeZone(subject: Player | Vector3): boolean
		if ctl.hub == nil then
			return false
		end
		if typeof(subject) == "Vector3" then
			return ctl.hub.contains(subject)
		end
		return ctl.hub.isInside(subject)
	end

	function ctl.stop()
		stopped = true
		if ctl.hub then
			ctl.hub.stop()
		end
		if heartbeat then
			heartbeat:Disconnect()
		end
		for _, c in connections do
			c:Disconnect()
		end
		if pool then
			pool:destroy()
		end
		if container then
			container:Destroy()
		end
		if state then
			state:Destroy()
		end
		if ctl.pad then
			ctl.pad:Destroy()
		end
	end

	return ctl
end

return Server
