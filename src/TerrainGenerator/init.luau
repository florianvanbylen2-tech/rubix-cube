--!strict
-- TerrainGenerator: a port of Minecraft Java 1.20.1's overworld generation to Roblox Terrain.
--
--   local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
--   TerrainGenerator.Config.Seed = "MyWorldName"      -- optional, see Config.luau
--   TerrainGenerator.Start()                          -- server; clients start themselves
--   print(TerrainGenerator.GetBiomeAt(Vector3.new(0, 600, 0)))
--
-- By default (Config.TerrainMode = "Client") every client draws its own terrain and the server only decides where
-- trees, ores and structures go, calling Placement.placeThing for each. See README.md for the full API.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(script.Config)
local Placement = require(script.Placement)
local Queries = require(script.World.Queries)
local ChunkGenerator = require(script.World.ChunkGenerator)
local Structures = require(script.World.Structures)
local Settings = require(script.Data.Settings)
local LockRegistry = require(script.Streaming.LockRegistry)
local Shared = require(script.Runtime.Shared)
local Server = require(script.Runtime.Server)
local Client = require(script.Runtime.Client)
local Biomes = require(script.Data.Biomes)

local MIN_Y = Settings.minY
local VOXEL = 4
local CHUNK = 16 * VOXEL

local TerrainGenerator = {}
TerrainGenerator.Version = "2.0.0"
TerrainGenerator.Config = Config

local function newSignal(): (BindableEvent, RBXScriptSignal)
	local e = Instance.new("BindableEvent")
	return e, e.Event
end

local signals: any = {}
signals.chunkLoaded, TerrainGenerator.ChunkLoaded = newSignal() -- (chunkX, chunkZ) loaded on this side (server: things; client: terrain)
signals.chunkUnloaded, TerrainGenerator.ChunkUnloaded = newSignal() -- (chunkX, chunkZ)
signals.initial, TerrainGenerator.InitialAreaLoaded = newSignal() -- () server: the area around the spawn point is generated
signals.spawn, TerrainGenerator.SpawnAreaReady = newSignal() -- () the spawn area is ready (server side / this client)

local customBiomes: { any } = {}
local locks = LockRegistry.new()
local serverCtl: any = nil
local clientCtl: any = nil
local queryGen: any = nil
local queryKey = ""

local function baseY(): number
	return Shared.baseY(Config)
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
-- A generator instance on the calling thread, only for read-only queries (biome / height lookups).
local function getQueryGenerator(): any
	local key = tostring(Config.Seed) .. "|" .. #customBiomes .. "|" .. table.concat(Config.Biomes.Disabled, ",")
	if queryGen == nil or queryKey ~= key then
		queryGen = ChunkGenerator.new(Config.Seed, Shared.generatorOptions(Config, "query", customBiomes))
		queryKey = key
	end
	return queryGen
end

-- Approximate surface height in studs (top of the highest solid block) at world position (x, z).
function TerrainGenerator.GetHeightAt(x: number, z: number): number
	local by = Queries.surfaceY(getQueryGenerator(), math.floor(x / VOXEL), math.floor(z / VOXEL))
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

-- Every biome name (vanilla + registered custom ones), sorted.
function TerrainGenerator.GetBiomeNames(): { string }
	local names = {}
	for name in Biomes do
		table.insert(names, name)
	end
	for _, def in customBiomes do
		table.insert(names, def.id)
	end
	table.sort(names)
	return names
end

-- The names of all things that can be placed: { Trees = {...}, Ores = {...}, Structures = {...} } (sorted).
function TerrainGenerator.GetThingNames(): { [string]: { string } }
	local function keys(map: { [string]: any }): { string }
		local out = {}
		for k in map do
			table.insert(out, k)
		end
		table.sort(out)
		return out
	end
	return { Trees = keys(Config.Trees), Ores = keys(Config.Ores), Structures = keys(Config.Structures) }
end

-- ---------------------------------------------------------------------------------------- registering things
local function assertNotStarted(what: string)
	assert(serverCtl == nil and clientCtl == nil, what .. " must be called before TerrainGenerator.Start()")
end

-- Registers a "magical" biome (plain data, see World/BiomeRegistry.luau). Call before Start().
function TerrainGenerator.RegisterBiome(definition: any)
	assertNotStarted("RegisterBiome")
	assert(type(definition) == "table" and type(definition.id) == "string", "biome definition needs a string `id`")
	for _, existing in customBiomes do
		assert(existing.id ~= definition.id, "duplicate biome id " .. definition.id)
	end
	local def = table.clone(definition)
	def.base = def.base or "plains"
	table.insert(customBiomes, def)
end

-- Removes a biome from the world: a registered custom biome is dropped, a vanilla one is disabled (its climate
-- range goes to the nearest remaining biome). Call before Start().
function TerrainGenerator.RemoveBiome(name: string)
	assertNotStarted("RemoveBiome")
	for i, def in customBiomes do
		if def.id == name then
			table.remove(customBiomes, i)
			return
		end
	end
	assert(Biomes[name] ~= nil, "unknown biome " .. tostring(name))
	if not table.find(Config.Biomes.Disabled, name) then
		table.insert(Config.Biomes.Disabled, name)
	end
end

-- Undoes RemoveBiome for a vanilla biome. Call before Start().
function TerrainGenerator.RestoreBiome(name: string)
	assertNotStarted("RestoreBiome")
	local i = table.find(Config.Biomes.Disabled, name)
	if i then
		table.remove(Config.Biomes.Disabled, i)
	end
end

-- Adds a tree type that spawns in the listed biomes (nil = everywhere):
--   RegisterTree({ Name = "Crystal Tree", Biomes = { "plains", "meadow" }, PerChunk = 2 })
-- Rate / BiomeRate work like for the default trees. It reaches placeThing under its Name.
function TerrainGenerator.RegisterTree(def: any)
	assertNotStarted("RegisterTree")
	assert(type(def) == "table" and type(def.Name) == "string" and def.Name ~= "", "tree needs a string `Name`")
	assert(Config.Trees[def.Name] == nil, def.Name .. " already exists: edit Config.Trees[\"" .. def.Name .. "\"] instead")
	Config.Trees[def.Name] = {
		Enabled = def.Enabled ~= false, Custom = true, Biomes = def.Biomes, PerChunk = def.PerChunk or 1,
		Rate = def.Rate or 1, BiomeRate = def.BiomeRate or {}, Extra = {},
	}
end

-- Adds an ore: RegisterOre({ Name = "Mythril Ore", Biomes = nil, PerChunk = 1.5, MinY = -60, MaxY = 0, Size = 6 })
-- MinY / MaxY are Minecraft block heights (-64 .. 319, sea level 63). One placeThing call per vein.
function TerrainGenerator.RegisterOre(def: any)
	assertNotStarted("RegisterOre")
	assert(type(def) == "table" and type(def.Name) == "string" and def.Name ~= "", "ore needs a string `Name`")
	assert(Config.Ores[def.Name] == nil, def.Name .. " already exists: edit Config.Ores[\"" .. def.Name .. "\"] instead")
	Config.Ores[def.Name] = {
		Enabled = def.Enabled ~= false, Custom = true, Biomes = def.Biomes, PerChunk = def.PerChunk or 1,
		MinY = def.MinY or -60, MaxY = def.MaxY or 60, Size = def.Size or 4,
		Rate = def.Rate or 1, BiomeRate = def.BiomeRate or {}, Extra = {},
	}
end

-- Adds a structure; same fields as the entries of Config.Structures (see Config.luau):
--   RegisterStructure({ Name = "Pyramid", Spacing = 30, Separation = 10, Biomes = { "desert" } })
function TerrainGenerator.RegisterStructure(def: any)
	assertNotStarted("RegisterStructure")
	assert(type(def) == "table" and type(def.Name) == "string", "structure needs a string `Name`")
	assert(Config.Structures[def.Name] == nil, def.Name .. " already exists: edit Config.Structures[\"" .. def.Name .. "\"] instead")
	local rule = table.clone(def)
	Structures.normalize(def.Name, rule) -- validate now, with a readable error
	Config.Structures[def.Name] = rule
end

-- Adds a block for custom biome surfaces (`surface = { top = "crystal_stone" }`):
--   RegisterBlock({ Name = "crystal_stone", Material = "Glacier", Color = Color3.fromRGB(120, 200, 255) })
-- Roblox Terrain has ~22 materials, so Material must be the name of one of Enum.Material's terrain materials; the
-- Color recolours that material for every block that uses it.
function TerrainGenerator.RegisterBlock(def: any)
	assertNotStarted("RegisterBlock")
	assert(type(def) == "table" and type(def.Name) == "string" and type(def.Material) == "string", "block needs a Name and a Material (name of an Enum.Material)")
	assert((Enum.Material :: any)[def.Material] ~= nil, "unknown Terrain material " .. def.Material)
	table.insert(Config.Materials.Custom, { name = def.Name, material = def.Material, kind = def.Kind or "solid" })
	if def.Color then
		Config.Materials.Colors[def.Material] = def.Color
	end
end

-- ---------------------------------------------------------------------------------------- placement hooks
-- Instead of editing Placement.luau you can install handlers (server). onPlace(thingType, location, info) replaces
-- the print; onRemove(chunkX, chunkZ) is called when a chunk unloads and its things should go.
function TerrainGenerator.SetPlacementHandler(onPlace: (string, Vector3, any) -> ())
	Placement.setHandlers(onPlace, nil)
end

function TerrainGenerator.SetRemovalHandler(onRemove: (number, number) -> ())
	Placement.setHandlers(nil, onRemove)
end

-- ---------------------------------------------------------------------------------------- chunk locks and loading
-- A locked chunk stays loaded for everyone (every client draws it, the server keeps its things) until it is unlocked,
-- however far away all players are. Locks have owners (default "default"): a chunk stays locked while any owner holds
-- it, so scripts cannot unlock each other's chunks. Server only; they work before Start() too.
local function serverOnly(what: string)
	assert(RunService:IsServer(), what .. " can only be used on the server")
end

function TerrainGenerator.LockChunk(cx: number, cz: number, owner: string?)
	serverOnly("LockChunk")
	locks:lockChunk(cx, cz, owner)
end

-- Inclusive chunk rectangle. Returns how many chunks were newly locked.
function TerrainGenerator.LockArea(cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
	serverOnly("LockArea")
	return locks:lockArea(cx0, cz0, cx1, cz1, owner)
end

function TerrainGenerator.UnlockChunk(cx: number, cz: number, owner: string?)
	serverOnly("UnlockChunk")
	locks:unlockChunk(cx, cz, owner)
end

function TerrainGenerator.UnlockArea(cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
	serverOnly("UnlockArea")
	return locks:unlockArea(cx0, cz0, cx1, cz1, owner)
end

-- Releases everything one owner locked (default owner when nil).
function TerrainGenerator.UnlockAll(owner: string?): number
	serverOnly("UnlockAll")
	return locks:unlockAll(owner)
end

-- Locked by `owner`, or by anybody when owner is nil. Works on clients too (reads the replicated lock list).
function TerrainGenerator.IsChunkLocked(cx: number, cz: number, owner: string?): boolean
	if clientCtl and not RunService:IsServer() then
		return clientCtl.isLocked(cx, cz)
	end
	return locks:isLocked(cx, cz, owner)
end

function TerrainGenerator.GetLockedChunks(owner: string?): { { number } }
	serverOnly("GetLockedChunks")
	return locks:list(owner)
end

-- Loads the chunk (generates it and places its things) even if no player is anywhere near, and, by default, locks
-- it so it stays. Yields until it is loaded on the server. Server only; call after Start().
--   options.Lock          true (default): keep it loaded until UnlockChunk. false: keep it HoldSeconds (10) only
--   options.Owner         lock owner (default "LoadChunk")
--   options.Wait          false: do not yield
--   options.Timeout       seconds to wait (default 60)
-- A locked chunk is also loaded and drawn by every client, including players who join later.
-- Returns true when the chunk is loaded.
function TerrainGenerator.LoadChunk(cx: number, cz: number, options: any?): boolean
	serverOnly("LoadChunk")
	assert(serverCtl, "LoadChunk needs TerrainGenerator.Start() to have been called")
	return serverCtl.loadChunk(cx, cz, options)
end

-- ---------------------------------------------------------------------------------------- spawn hall / safe zone
-- Call this from your weapon scripts when `attacker` hurts (or tries to hurt) `victim`. When the victim stands in the
-- spawn hall's safe zone the attack is blocked and King Jeffry strikes the attacker with lightning. Returns true when
-- the attack was blocked (so you can skip your own damage). Server only; needs Config.SpawnHub.Enabled.
function TerrainGenerator.ReportAttack(attacker: Player, victim: Player): boolean
	serverOnly("ReportAttack")
	return serverCtl ~= nil and serverCtl.reportAttack(attacker, victim)
end

-- Is the player (or the world position, in studs) inside the spawn hall's safe zone? Players also carry the
-- attribute "InSafeZone" (true/false) for your UI.
function TerrainGenerator.IsInSafeZone(subject: Player | Vector3): boolean
	return serverCtl ~= nil and serverCtl.isInSafeZone(subject)
end

-- ---------------------------------------------------------------------------------------- streaming state
-- Server: the chunk's things have been placed. Client: its terrain is drawn.
function TerrainGenerator.IsChunkLoaded(cx: number, cz: number): boolean
	if serverCtl then
		return serverCtl.isLoaded(cx, cz)
	end
	return clientCtl ~= nil and clientCtl.isLoaded(cx, cz)
end

function TerrainGenerator.GetStats(): { [string]: number }
	if serverCtl then
		return serverCtl.stats()
	elseif clientCtl then
		return clientCtl.stats()
	end
	return { loaded = 0, queued = 0, inflight = 0, sources = 0, locked = 0 }
end

-- Server: yields until the area around the spawn point has been generated.
function TerrainGenerator.WaitForInitialArea()
	while serverCtl == nil or not serverCtl.initialLoaded() do
		task.wait(0.1)
	end
end

-- The point where players spawn (studs, on the ground); nil before Start().
function TerrainGenerator.GetSpawnPoint(): Vector3?
	if serverCtl then
		return serverCtl.spawnPoint
	elseif clientCtl then
		return clientCtl.spawnPoint
	end
	return nil
end

-- ---------------------------------------------------------------------------------------- start / stop
-- Copies the module into ReplicatedStorage (clients need its code) and installs the client runner.
local function deployClient()
	if not script:IsDescendantOf(ReplicatedStorage) then
		local existing = ReplicatedStorage:FindFirstChild("TerrainGenerator")
		if existing then
			existing:Destroy()
		end
		local copy = script:Clone()
		copy.Name = "TerrainGenerator"
		copy.Parent = ReplicatedStorage
	end
	local template = script:FindFirstChild("ClientRunner") :: LocalScript?
	if template then
		local function install(parent: Instance?)
			if parent and not parent:FindFirstChild("TerrainGeneratorClient") then
				local runner = template:Clone()
				runner.Name = "TerrainGeneratorClient"
				runner.Disabled = false
				runner.Parent = parent
			end
		end
		install(StarterPlayer:FindFirstChild("StarterPlayerScripts"))
		for _, player in Players:GetPlayers() do
			install(player:FindFirstChild("PlayerGui"))
		end
	end
end

-- Server: publishes the world to the clients and starts generating. Yields until the workers are ready.
function TerrainGenerator.StartServer()
	assert(RunService:IsServer(), "TerrainGenerator.StartServer() must run on the server")
	if serverCtl then
		return
	end
	local ok, result = pcall(Server.start, {
		Config = Config,
		module = script,
		customBiomes = customBiomes,
		locks = locks,
		getQueryGenerator = getQueryGenerator,
		deployClient = deployClient,
		signals = signals,
	})
	if not ok then
		-- never leave players stuck without characters if start-up failed
		Players.CharacterAutoLoads = true
		local state = ReplicatedStorage:FindFirstChild("TerrainGeneratorState")
		if state then
			state:Destroy()
		end
		local workers = game:GetService("ServerScriptService"):FindFirstChild("TerrainGeneratorWorkers")
		if workers then
			workers:Destroy()
		end
		error(result, 0)
	end
	serverCtl = result
end

-- Client: waits for the server's world, then draws the terrain around this player. Called by the client runner.
function TerrainGenerator.StartClient()
	if clientCtl then
		return
	end
	clientCtl = Client.start({
		Config = Config,
		module = script,
		signals = signals,
		setCustomBiomes = function(list: { any })
			customBiomes = list
			queryGen = nil
		end,
	})
end

-- Start the generator: on the server this runs StartServer, on a client StartClient.
function TerrainGenerator.Start()
	if RunService:IsServer() then
		TerrainGenerator.StartServer()
	else
		TerrainGenerator.StartClient()
	end
end

function TerrainGenerator.Stop()
	if serverCtl then
		serverCtl.stop()
		serverCtl = nil
	end
	if clientCtl then
		clientCtl.stop()
		clientCtl = nil
	end
end

return TerrainGenerator
