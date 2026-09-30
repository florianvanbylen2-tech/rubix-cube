--!strict
-- TerrainGenerator: a port of Minecraft Java 1.20.1's overworld generation to Roblox Terrain.
--
--   local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
--   TerrainGenerator.Config.Seed = "MyWorldName"      -- optional, see Config.luau
--   TerrainGenerator.Start()
--   print(TerrainGenerator.GetBiomeAt(Vector3.new(0, 600, 0)))
--
-- See README.md for the architecture and the full API.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(script.Config)
local ChunkManager = require(script.Streaming.ChunkManager)
local ChunkWriter = require(script.Streaming.ChunkWriter)
local ChunkGenerator = require(script.World.ChunkGenerator)
local Queries = require(script.World.Queries)
local Settings = require(script.Data.Settings)

local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local VOXEL = 4
local CHUNK = 16 * VOXEL

local TerrainGenerator = {}
TerrainGenerator.Version = "1.0.0"
TerrainGenerator.Config = Config

local function newSignal(): (BindableEvent, RBXScriptSignal)
	local e = Instance.new("BindableEvent")
	return e, e.Event
end

local chunkLoadedEvent, chunkUnloadedEvent, initialEvent, spawnEvent
chunkLoadedEvent, TerrainGenerator.ChunkLoaded = newSignal() -- (chunkX, chunkZ)
chunkUnloadedEvent, TerrainGenerator.ChunkUnloaded = newSignal() -- (chunkX, chunkZ)
initialEvent, TerrainGenerator.InitialAreaLoaded = newSignal() -- () the Width x Length area around (0, 0) is complete
spawnEvent, TerrainGenerator.SpawnAreaReady = newSignal() -- () characters can spawn

local customBiomes: { any } = {}
local started = false
local initialLoaded = false
local spawnReady = false

-- runtime state (set by Start)
local manager: any = nil
local writer: any = nil
local heartbeat: RBXScriptConnection? = nil
local container: Folder? = nil
local queryGen: any = nil
local queryKey = ""

local function baseY(): number
	return math.floor(Config.BedrockLevel / VOXEL) * VOXEL
end

-- ---------------------------------------------------------------------------------------- helpers
local function generatorOptions(): any
	return {
		customBiomes = customBiomes,
		treeDensity = Config.Collectables.TreeDensity,
		oreDensity = Config.Collectables.OreDensity,
		oreTiers = Config.Collectables.OreTiers,
		smooth = Config.SmoothTerrain,
	}
end

local function writerConfig(): any
	return {
		bedrockLevel = baseY(),
		folderName = Config.Collectables.FolderName,
		collectables = Config.Collectables.Enabled,
		partSize = Config.Collectables.PartSize,
		colorParts = Config.Collectables.ColorParts,
		applyColors = Config.ApplyMaterialColors,
		decoration = Config.Decoration,
		writeBudgetMs = Config.Streaming.WriteBudgetMs,
	}
end

-- A generator instance on the calling thread, only for read-only queries (biome / height lookups).
local function getQueryGenerator(): any
	local key = tostring(Config.Seed) .. "|" .. #customBiomes
	if queryGen == nil or queryKey ~= key then
		queryGen = ChunkGenerator.new(Config.Seed, generatorOptions())
		queryKey = key
	end
	return queryGen
end

-- ---------------------------------------------------------------------------------------- coordinates
-- Studs <-> Minecraft blocks (1 block = 4 studs; block y = -64 sits at Config.BedrockLevel).
function TerrainGenerator.WorldToBlock(position: Vector3): (number, number, number)
	return math.floor(position.X / VOXEL), math.floor((position.Y - baseY()) / VOXEL) + MIN_Y, math.floor(position.Z / VOXEL)
end

function TerrainGenerator.BlockToWorld(bx: number, by: number, bz: number): Vector3
	return Vector3.new(bx * VOXEL, baseY() + (by - MIN_Y) * VOXEL, bz * VOXEL)
end

function TerrainGenerator.WorldToChunk(position: Vector3): (number, number)
	return math.floor(position.X / CHUNK), math.floor(position.Z / CHUNK)
end

-- ---------------------------------------------------------------------------------------- queries
-- Approximate surface height in studs (top of the highest solid block) at world position (x, z).
function TerrainGenerator.GetHeightAt(x: number, z: number): number
	local gen = getQueryGenerator()
	local by = Queries.surfaceY(gen, math.floor(x / VOXEL), math.floor(z / VOXEL))
	return baseY() + (by - MIN_Y + 1) * VOXEL
end

-- Biome at a world position. Accepts a Vector3 (uses its Y) or (x, z) (uses the surface height).
-- Returns the biome name ("plains", "jagged_peaks", or a custom biome id) and an info table:
--   { Id, DisplayName, IsCustom, Base, Block = Vector3, Climate = {temperature, humidity, ...} }
function TerrainGenerator.GetBiomeAt(a: Vector3 | number, z: number?): (string, { [string]: any })
	local gen = getQueryGenerator()
	local bx, by, bz
	if typeof(a) == "Vector3" then
		bx, by, bz = TerrainGenerator.WorldToBlock(a)
	else
		bx, bz = math.floor((a :: number) / VOXEL), math.floor((z :: number) / VOXEL)
		by = Queries.surfaceY(gen, bx, bz)
	end
	local id = gen.biomes:getBiome(bx, by, bz)
	local registry = gen.registry
	local name = registry.names[id]
	local custom = registry.custom[id]
	return name,
		{
			Id = name,
			DisplayName = custom and custom.displayName or name,
			IsCustom = custom ~= nil,
			Base = registry.names[registry.base[id]],
			Block = Vector3.new(bx, by, bz),
			Climate = Queries.climate(gen, bx, by, bz),
		}
end

-- Raw climate values (temperature, humidity, continentalness, erosion, depth, weirdness) at a position.
function TerrainGenerator.GetClimateAt(position: Vector3): { [string]: number }
	local bx, by, bz = TerrainGenerator.WorldToBlock(position)
	return Queries.climate(getQueryGenerator(), bx, by, bz)
end

-- ---------------------------------------------------------------------------------------- custom biomes
-- Registers a "magical" biome (plain data, see World/BiomeRegistry.luau). Call before Start().
function TerrainGenerator.RegisterBiome(definition: any)
	assert(not started, "RegisterBiome must be called before TerrainGenerator.Start()")
	assert(type(definition) == "table" and type(definition.id) == "string", "biome definition needs a string `id`")
	for _, existing in customBiomes do
		assert(existing.id ~= definition.id, "duplicate biome id " .. definition.id)
	end
	local def = table.clone(definition)
	def.base = def.base or "plains"
	table.insert(customBiomes, def)
end

-- ---------------------------------------------------------------------------------------- streaming state
function TerrainGenerator.IsChunkLoaded(cx: number, cz: number): boolean
	return manager ~= nil and manager:isLoaded(cx, cz)
end

function TerrainGenerator.GetStats(): { [string]: number }
	if not manager then
		return { loaded = 0, queued = 0, inflight = 0, sources = 0 }
	end
	return manager:stats()
end

-- Yields until the initial Width x Length area around (0, 0) has been generated.
function TerrainGenerator.WaitForInitialArea()
	while not initialLoaded do
		task.wait(0.1)
	end
end

-- ---------------------------------------------------------------------------------------- spawn
local function findSpawnPosition(): Vector3?
	local top = baseY() + HEIGHT * VOXEL + 8
	local params = RaycastParams.new()
	local fallback: Vector3? = nil
	local radius = Config.Spawn.ReadyRadiusChunks * CHUNK
	local step = 16
	local r = 0
	while r <= radius do
		-- points on the square ring at distance r
		local points: { Vector3 } = {}
		if r == 0 then
			table.insert(points, Vector3.new(0, top, 0))
		else
			for t = -r, r, step do
				table.insert(points, Vector3.new(t, top, -r))
				table.insert(points, Vector3.new(t, top, r))
				table.insert(points, Vector3.new(-r, top, t))
				table.insert(points, Vector3.new(r, top, t))
			end
		end
		for _, origin in points do
			local hit = workspace:Raycast(origin, Vector3.new(0, -(HEIGHT * VOXEL + 16), 0), params)
			if hit then
				if hit.Material ~= Enum.Material.Water then
					return hit.Position + Vector3.new(0, 6, 0)
				elseif not fallback then
					fallback = hit.Position + Vector3.new(0, 6, 0)
				end
			end
		end
		r += step
	end
	return fallback
end

local function releaseSpawn()
	if spawnReady then
		return
	end
	spawnReady = true
	if Config.Spawn.AutoSpawn then
		local pos = findSpawnPosition() or Vector3.new(0, baseY() + 508 + 20, 0)
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "TerrainSpawn"
		spawn.Anchored = true
		spawn.CanCollide = false
		spawn.Transparency = 1
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Neutral = true
		spawn.Duration = 0
		spawn.Position = pos
		spawn.Parent = workspace
		Players.CharacterAutoLoads = true
		for _, player in Players:GetPlayers() do
			if player.Character == nil then
				task.spawn(function()
					player:LoadCharacter()
				end)
			end
		end
	end
	spawnEvent:Fire()
end

-- ---------------------------------------------------------------------------------------- start / stop
local function startInner()
	local cfg = Config

	local rx = math.max(1, math.ceil(cfg.Width / CHUNK / 2))
	local rz = math.max(1, math.ceil(cfg.Length / CHUNK / 2))
	local terrain = workspace.Terrain
	if cfg.ClearBeforeGenerating then
		terrain:Clear()
	end
	ChunkWriter.applyGlobals(writerConfig())
	writer = ChunkWriter.new(writerConfig())
	if cfg.Spawn.AutoSpawn then
		Players.CharacterAutoLoads = false
	end

	local initialTotal = (2 * rx) * (2 * rz)
	local lastPercent = -1
	local jobWorker: { [number]: number } = {}
	local inflightBy: { number } = {}
	local actors: { Actor } = {}
	local localGenerator: any = nil
	local localWriter: any = nil

	local function report(kind: string, ...)
		if kind == "done" then
			local jobId, cx, cz, ok, err = ...
			local w = jobWorker[jobId]
			if w then
				inflightBy[w] -= 1
				jobWorker[jobId] = nil
			end
			manager:onDone(jobId, cx, cz, ok, err)
		end
	end

	manager = ChunkManager.new({
		radius = rx,
		radiusZ = rz,
		margin = cfg.Streaming.UnloadMargin,
		maxInFlight = cfg.Workers.Enabled and cfg.Streaming.MaxChunksInFlight or 1,
		playerGrace = cfg.Streaming.PlayerGraceSeconds,
	}, {
		dispatch = function(cx: number, cz: number, jobId: number)
			if cfg.Workers.Enabled then
				local best, bestLoad = 1, math.huge
				for i = 1, #actors do
					if inflightBy[i] < bestLoad then
						best, bestLoad = i, inflightBy[i]
					end
				end
				inflightBy[best] += 1
				jobWorker[jobId] = best
				actors[best]:SendMessage("Generate", jobId, cx, cz)
			else
				task.spawn(function()
					task.wait()
					local ok, err = pcall(function()
						local chunk = localGenerator:generate(cx, cz)
						localWriter:write(chunk)
					end)
					manager:onDone(jobId, cx, cz, ok, err and tostring(err) or nil)
				end)
			end
		end,
		unload = function(cx: number, cz: number)
			writer:unload(cx, cz)
			chunkUnloadedEvent:Fire(cx, cz)
		end,
		onLoaded = function(cx: number, cz: number)
			chunkLoadedEvent:Fire(cx, cz)
		end,
		onFailed = function(cx: number, cz: number, err: string)
			warn(string.format("[TerrainGenerator] chunk (%d, %d) failed: %s", cx, cz, err))
		end,
	})

	-- ------------------------------------------------------------------ workers
	if cfg.Workers.Enabled then
		local folder = Instance.new("Folder")
		folder.Name = "TerrainGeneratorWorkers"
		folder.Parent = ServerScriptService
		container = folder
		local events = Instance.new("BindableEvent")
		events.Name = "Events"
		events.Parent = folder

		local template = script.Streaming.WorkerTemplate :: Actor
		local count = math.max(1, cfg.Workers.Count)
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
			else
				report(kind, ...)
			end
		end)
		for i = 1, count do
			local actor = template:Clone()
			actor.Name = "Worker" .. i
			local modules = Instance.new("ObjectValue")
			modules.Name = "Modules"
			modules.Value = script
			modules.Parent = actor
			local ev = Instance.new("ObjectValue")
			ev.Name = "Events"
			ev.Value = events
			ev.Parent = actor
			actor.Parent = folder
			;(actor:FindFirstChild("Worker") :: Script).Disabled = false
			actors[i] = actor
			inflightBy[i] = 0
		end
		local t0 = os.clock()
		while bound < count and os.clock() - t0 < 15 do
			task.wait(0.05)
		end
		assert(bound == count, "TerrainGenerator: workers failed to start (is the module inside ServerScriptService?)")
		local init = { seed = cfg.Seed, generator = generatorOptions(), writer = writerConfig() }
		for _, actor in actors do
			actor:SendMessage("Init", init)
		end
		t0 = os.clock()
		while ready < count and not failed and os.clock() - t0 < 120 do
			task.wait(0.05)
		end
		assert(not failed, "TerrainGenerator worker failed to initialise: " .. tostring(failed))
		assert(ready == count, "TerrainGenerator: timed out waiting for workers")
		if cfg.PrintProgress then
			print(string.format("[TerrainGenerator] %d workers ready, generating %dx%d chunks around the origin", count, 2 * rx, 2 * rz))
		end
	else
		localGenerator = ChunkGenerator.new(cfg.Seed, generatorOptions())
		localWriter = ChunkWriter.new(writerConfig())
		ChunkWriter.setBiomeNames(localWriter, localGenerator.registry.names)
	end

	-- ------------------------------------------------------------------ streaming loop
	manager:setAnchor("initial", 0, 0, rx, rz)
	Players.PlayerRemoving:Connect(function(player)
		manager:removePlayer(tostring(player.UserId))
	end)

	local accumulator = 0
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < cfg.Streaming.UpdateInterval then
			return
		end
		accumulator = 0
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
		manager:update()

		if not spawnReady then
			local r = cfg.Spawn.ReadyRadiusChunks
			local n, total = manager:loadedInBox(0, 0, r)
			if n == total then
				releaseSpawn()
			end
		end
		if not initialLoaded then
			local loaded = 0
			for x = -rx, rx - 1 do
				for z = -rz, rz - 1 do
					if manager:isLoaded(x, z) then
						loaded += 1
					end
				end
			end
			local percent = math.floor(loaded / initialTotal * 100)
			if cfg.PrintProgress and percent >= lastPercent + 10 then
				lastPercent = percent - percent % 10
				print(string.format("[TerrainGenerator] initial area %d%% (%d/%d chunks)", percent, loaded, initialTotal))
			end
			if loaded == initialTotal then
				initialLoaded = true
				if not cfg.Streaming.KeepInitialArea then
					manager:removeAnchor("initial")
				end
				initialEvent:Fire()
			end
		end
	end)
end

-- Generates the initial area around (0, 0), then keeps a Width x Length window loaded around every player.
-- Yields until the workers are ready (a few seconds); terrain then streams in the background.
function TerrainGenerator.Start()
	assert(RunService:IsServer(), "TerrainGenerator.Start() must run on the server")
	if started then
		return
	end
	started = true
	local ok, err = pcall(startInner)
	if not ok then
		-- never leave players stuck without characters if start-up failed
		started = false
		Players.CharacterAutoLoads = true
		if heartbeat then
			heartbeat:Disconnect()
			heartbeat = nil
		end
		if container then
			container:Destroy()
			container = nil
		end
		error(err, 0)
	end
end

function TerrainGenerator.Stop()
	if not started then
		return
	end
	started = false
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	if container then
		container:Destroy()
		container = nil
	end
	manager = nil
	initialLoaded = false
	spawnReady = false
end

return TerrainGenerator
