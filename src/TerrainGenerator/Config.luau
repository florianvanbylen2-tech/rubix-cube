--!strict
-- Terrain generator configuration. Edit the values here, or override them from a SERVER script BEFORE calling
-- TerrainGenerator.Start():
--
--     local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
--     TerrainGenerator.Config.Seed = "MyWorldName"
--     TerrainGenerator.Config.Trees["Oak Tree"].Biomes = { "plains", "forest" }
--     TerrainGenerator.Start()
--
-- Whatever the server's Config holds at Start() is copied to every client, so clients generate the same world.
--
-- Scale: one Minecraft block = one Terrain voxel = 4 studs, and the world is Minecraft 1.20.1's overworld:
-- 384 blocks tall (Minecraft y -64 .. 319), sea level at Minecraft y 63. With BedrockLevel = 0 that puts the
-- bottom of the world at Y = 0, sea level at Y = 508 and the height limit at Y = 1536 studs.

local Biomes = require(script.Parent.Data.Biomes)
local ThingNames = require(script.Parent.World.ThingNames)

export type Config = {
	Seed: number | string,
	Width: number,
	Length: number,
	BedrockLevel: number,
	TerrainMode: string,
	SmoothTerrain: boolean,
	ApplyMaterialColors: boolean,
	ClearBeforeGenerating: boolean,
	PrintProgress: boolean,
	Decoration: boolean?,

	Streaming: {
		UpdateInterval: number,
		UnloadMargin: number,
		MaxChunksInFlight: number,
		PlayerGraceSeconds: number,
		KeepInitialArea: boolean,
		WriteBudgetMs: number,
		AdaptiveLoad: boolean,
		TargetFrameMs: number,
	},
	Server: { Width: number?, Length: number? },
	Workers: { Enabled: boolean, Count: number, SliceMs: number },
	Client: { Workers: number, SliceMs: number, WriteBudgetMs: number, MaxChunksInFlight: number, Width: number?, Length: number? },

	Placement: { Print: boolean, MaxPrintsPerSecond: number },
	Spawning: { TreeRate: number, OreRate: number, BiomeTreeRate: { [string]: number }, BiomeOreRate: { [string]: number } },
	Trees: { [string]: any },
	Ores: { [string]: any },
	Structures: { [string]: any },

	Biomes: { Disabled: { string } },
	Materials: { Blocks: { [string]: string }, Colors: { [string]: Color3 }, Variants: { [string]: string }, Custom: { any } },

	Mobs: { Pig: boolean },
	Spawn: { AutoSpawn: boolean, ReadyRadiusChunks: number },
}

-- ---------------------------------------------------------------------------------------- defaults for the tables
-- One entry per vanilla biome, 1 = Minecraft's own frequency
local function perBiome(): { [string]: number }
	local t: { [string]: number } = {}
	for name in Biomes do
		t[name] = 1
	end
	return t
end

-- A rule for every default tree / ore, so you can see and edit them all.
--   Enabled    false = never spawns
--   Biomes     nil = wherever Minecraft spawns it, or a list like { "plains", "forest" } to restrict it to those
--   Rate       multiplier on Minecraft's frequency (1 = vanilla)
--   BiomeRate  { desert = 0 } extra per-biome multipliers on top of Rate
--   Extra      { desert = 2 } also spawn ~2 per chunk in biomes where Minecraft would not
local function defaultRules(names: { string }): { [string]: any }
	local t: { [string]: any } = {}
	for _, name in names do
		t[name] = { Enabled = true, Biomes = nil, Rate = 1, BiomeRate = {}, Extra = {} }
	end
	return t
end

local Config: Config = {
	-- A number, or any string (hashed like Minecraft does). The same seed gives the same biomes and terrain
	-- as Minecraft 1.20.1 Java at the same coordinates (Minecraft x,z = studs / 4).
	Seed = 12345,

	-- Size in studs of the terrain window kept loaded around every player. Rounded up to whole 64-stud chunks.
	-- Smaller = faster and lighter. (Client.Width / Client.Length can override it for what clients render.)
	Width = 1024,
	Length = 1024,

	-- Workspace Y (studs) of the bottom of the world; rounded down to a multiple of 4.
	BedrockLevel = 0,

	-- "Client": every player's own client generates and draws the terrain around them (no terrain network traffic,
	--           no server cost; the SERVER has no terrain, so server-side physics/raycasts see an empty world).
	--           Trees, ores and structures are still decided by the server.
	-- "Server": the server writes the terrain like a normal Roblox world (replicated to everybody).
	TerrainMode = "Client",

	-- Sub-voxel occupancy (smooth hills) instead of hard 4-stud cubes.
	SmoothTerrain = true,

	-- Recolour Terrain materials so they resemble Minecraft's blocks (see Materials below and World/Blocks.luau).
	ApplyMaterialColors = true,

	ClearBeforeGenerating = true,
	PrintProgress = true,

	-- false turns off Terrain grass blades (a big client FPS saver); true = on; nil = leave unchanged
	Decoration = false,

	Streaming = {
		UpdateInterval = 0.25, -- seconds between player position checks
		UnloadMargin = 2, -- extra chunks kept around each window before unloading (prevents flicker)
		MaxChunksInFlight = 4, -- concurrent chunk jobs on the server (capped at Workers.Count)
		PlayerGraceSeconds = 30, -- a player without a character (respawning) keeps its window this long
		KeepInitialArea = false, -- TerrainMode "Server" only: never unload the start-up area around (0, 0)
		WriteBudgetMs = 3, -- TerrainMode "Server": terrain writes yield to the next frame after this many ms
		AdaptiveLoad = true, -- fewer concurrent chunk jobs (or a pause) while frames are slow
		TargetFrameMs = 25, -- ... i.e. when frames take longer than this (25 ms = 40 fps)
	},

	-- How far around every player the SERVER places trees, ores and structures (nil = Width / Length above).
	-- Smaller = less server CPU; things beyond this distance do not exist yet when a client already draws the terrain.
	Server = {
		Width = nil,
		Length = nil,
	},

	-- Server-side generation workers (Parallel Luau Actors). They compute where trees, ores and structures go.
	Workers = {
		Enabled = true, -- false = generate on the main thread (causes hitches)
		Count = 3,
		SliceMs = 6, -- a worker hands the frame back after this many ms of work, so chunks never hitch a frame
	},

	-- What each player's client does in TerrainMode "Client".
	Client = {
		Workers = 2, -- parallel workers per client (more = faster terrain, more CPU on the player's device)
		SliceMs = 4, -- ms of generation per frame per worker
		WriteBudgetMs = 2, -- ms of Terrain writes per frame
		MaxChunksInFlight = 2,
		Width = nil, -- nil = use Width / Length above
		Length = nil,
	},

	-- Where the placeThing calls go: Placement.luau (printing only). Printing is rate limited.
	Placement = {
		Print = true,
		MaxPrintsPerSecond = 40,
	},

	-- Spawn rates. 1 = Minecraft's own density. Rates multiply: global x per-biome x per-thing x per-thing-per-biome.
	Spawning = {
		TreeRate = 1, -- all trees
		OreRate = 1, -- all ores
		BiomeTreeRate = perBiome(), -- e.g. BiomeTreeRate.forest = 2 doubles every tree in forests
		BiomeOreRate = perBiome(),
	},

	-- Rules for every default tree and ore; see defaultRules above. RegisterTree / RegisterOre add your own.
	Trees = defaultRules(ThingNames.treeList),
	Ores = defaultRules(ThingNames.oreList),

	-- Structures. Spacing / Separation / Salt are Minecraft's `random_spread` numbers (Village uses vanilla's own, so
	-- villages start in the same chunks as in Minecraft); one structure per Spacing x Spacing chunk region, at least
	-- Separation chunks from the next. 1 chunk = 64 studs.
	--   Biomes     where it may start (biome names, custom biome ids work too)
	--   Placement  "Land" | "Water" (sea floor) | "Any"        MaxSlope  max ground height difference (blocks)
	--   Chance     0..1 per region       Rotate  random 90 degree turns       Enabled  false = never
	-- RegisterStructure adds your own.
	Structures = {
		Village = {
			Enabled = true, Spacing = 34, Separation = 8, Salt = 10387312,
			Biomes = { "plains", "sunflower_plains", "meadow", "forest", "flower_forest", "birch_forest" },
			Placement = "Land", MaxSlope = 6,
		},
		["Medieval Castle"] = {
			Enabled = true, Spacing = 48, Separation = 20, Salt = 8154021, Chance = 0.8,
			Biomes = { "snowy_slopes", "jagged_peaks", "frozen_peaks", "grove", "snowy_plains", "snowy_taiga" },
			Placement = "Land", MaxSlope = 14,
		},
		Watchtower = {
			Enabled = true, Spacing = 20, Separation = 8, Salt = 5100401, Chance = 0.8,
			Biomes = { "plains", "meadow", "forest", "taiga", "savanna", "sunflower_plains", "birch_forest" },
			Placement = "Land", MaxSlope = 4,
		},
		Well = {
			Enabled = true, Spacing = 11, Separation = 4, Salt = 5100402, Chance = 0.6,
			Biomes = { "plains", "sunflower_plains", "meadow", "desert", "savanna" },
			Placement = "Land", MaxSlope = 3,
		},
		Campsite = {
			Enabled = true, Spacing = 14, Separation = 5, Salt = 5100403, Chance = 0.7,
			Biomes = { "forest", "birch_forest", "taiga", "plains", "flower_forest", "snowy_taiga" },
			Placement = "Land", MaxSlope = 3,
		},
		["Lone Cabin"] = {
			Enabled = true, Spacing = 26, Separation = 10, Salt = 5100404, Chance = 0.7,
			Biomes = { "forest", "dark_forest", "taiga", "snowy_taiga", "old_growth_pine_taiga", "birch_forest" },
			Placement = "Land", MaxSlope = 4,
		},
		["Ruined Tower"] = {
			Enabled = true, Spacing = 24, Separation = 9, Salt = 5100405, Chance = 0.6,
			Biomes = { "plains", "forest", "swamp", "taiga", "savanna", "badlands", "windswept_hills" },
			Placement = "Land", MaxSlope = 5,
		},
		["Stone Circle"] = {
			Enabled = true, Spacing = 22, Separation = 8, Salt = 5100406, Chance = 0.6,
			Biomes = { "plains", "meadow", "sunflower_plains", "windswept_hills", "snowy_plains" },
			Placement = "Land", MaxSlope = 3,
		},
		["Mountain Shrine"] = {
			Enabled = true, Spacing = 22, Separation = 8, Salt = 5100407, Chance = 0.6,
			Biomes = { "windswept_hills", "stony_peaks", "jagged_peaks", "snowy_slopes", "frozen_peaks", "grove" },
			Placement = "Land", MaxSlope = 10,
		},
	},

	-- Remove biomes from the world: their climate range is taken over by the nearest remaining biome.
	-- e.g. Disabled = { "desert", "badlands" }. Add biomes with TerrainGenerator.RegisterBiome.
	Biomes = {
		Disabled = {},
	},

	-- Terrain materials. Roblox Terrain has only ~22 materials, so several Minecraft blocks share one.
	--   Blocks    { grass_block = "LeafyGrass" }: show a block with another Enum.Material (name)
	--   Colors    { Grass = Color3.fromRGB(...) }: recolour a Terrain material (needs ApplyMaterialColors)
	--   Variants  { Grass = "MyGrassVariant" }: apply a MaterialVariant (from MaterialService) to a base material,
	--             giving it custom textures
	--   Custom    new blocks for custom biome surfaces: { { name = "crystal_stone", material = "Glacier" } }
	--             (RegisterBlock adds one)
	Materials = {
		Blocks = {},
		Colors = {},
		Variants = {},
		Custom = {},
	},

	Mobs = {
		Pig = true, -- one wandering pig at the spawn point (drawn on each client)
	},

	Spawn = {
		AutoSpawn = true, -- hold characters until the area around the spawn point exists on their client
		ReadyRadiusChunks = 2, -- this many chunks around the spawn point are locked and loaded for everybody
	},
}

return Config
