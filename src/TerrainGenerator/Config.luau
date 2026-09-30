--!strict
-- Terrain generator configuration. Edit the values here, or override them from a script BEFORE calling
-- TerrainGenerator.Start():
--
--     local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
--     TerrainGenerator.Config.Seed = "MyWorldName"
--     TerrainGenerator.Start()
--
-- Scale: one Minecraft block = one Terrain voxel = 4 studs, and the world is Minecraft 1.20.1's overworld:
-- 384 blocks tall (Minecraft y -64 .. 319), sea level at Minecraft y 63. With BedrockLevel = 0 that puts the
-- bottom of the world at Y = 0, sea level at Y = 508 and the height limit at Y = 1536 studs. (SeaLevel,
-- MaxHeight, HeightVariation, NoiseScale, ... from the previous generator no longer exist: terrain shape now
-- comes from Minecraft's own noise router.)

export type Config = {
	Seed: number | string,
	Width: number,
	Length: number,
	BedrockLevel: number,
	SmoothTerrain: boolean,
	ApplyMaterialColors: boolean,
	ClearBeforeGenerating: boolean,
	PrintProgress: boolean,

	Streaming: {
		UpdateInterval: number,
		UnloadMargin: number,
		MaxChunksInFlight: number,
		PlayerGraceSeconds: number,
		KeepInitialArea: boolean,
		WriteBudgetMs: number,
	},

	Workers: {
		Enabled: boolean,
		Count: number,
	},

	Collectables: {
		Enabled: boolean,
		FolderName: string,
		TreeDensity: number,
		OreDensity: number,
		OreTiers: { [string]: number },
		PartSize: Vector3,
		ColorParts: boolean,
	},

	Spawn: {
		AutoSpawn: boolean,
		ReadyRadiusChunks: number,
	},

	Decoration: boolean?,
}

local Config: Config = {
	-- A number, or any string (hashed like Minecraft does). The same seed gives the same biomes and terrain
	-- as Minecraft 1.20.1 Java at the same coordinates (Minecraft x,z = studs / 4).
	Seed = 12345,

	-- Size in studs of the terrain window kept loaded around every player, and of the area generated around
	-- (0, 0) at start-up. Rounded up to whole 64-stud chunks. Smaller = faster start and less memory.
	Width = 2048,
	Length = 2048,

	-- Workspace Y (studs) of the bottom of the world; rounded down to a multiple of 4.
	BedrockLevel = 0,

	-- Sub-voxel occupancy (smooth hills) instead of hard 4-stud cubes.
	SmoothTerrain = true,

	-- Recolour Terrain materials so they resemble Minecraft's blocks (see World/Blocks.luau).
	ApplyMaterialColors = true,

	ClearBeforeGenerating = true,
	PrintProgress = true,

	Streaming = {
		UpdateInterval = 0.25, -- seconds between player position checks
		UnloadMargin = 2, -- extra chunks kept around each window before unloading (prevents flicker)
		MaxChunksInFlight = 8, -- concurrent chunk jobs (should be >= Workers.Count)
		PlayerGraceSeconds = 30, -- a player without a character (respawning) keeps its window this long
		KeepInitialArea = false, -- true: never unload the initial Width x Length area around (0, 0)
		WriteBudgetMs = 4, -- terrain writes yield to the next frame after this many ms (smooths server hitches)
	},

	Workers = {
		-- Parallel Luau (Actors). Strongly recommended: one chunk costs ~0.1-0.4 s of CPU.
		-- With Enabled = false chunks are generated on the main thread, one at a time (causes frame hitches).
		Enabled = true,
		Count = 6,
	},

	Collectables = {
		Enabled = true,
		FolderName = "GeneratedCollectables", -- created in Workspace
		TreeDensity = 1.0, -- 1 = Minecraft's tree density; 0.5 = half as many trees
		OreDensity = 0.5, -- 1 = every Minecraft ore vein gets a part; lower thins them out
		-- Ore_N: N is the tier, 1 = most common ... 5 = rarest
		OreTiers = { coal = 1, copper = 2, iron = 2, redstone = 3, lapis = 3, gold = 4, diamond = 5, emerald = 5 },
		PartSize = Vector3.new(4, 4, 4),
		ColorParts = true,
	},

	Spawn = {
		AutoSpawn = true, -- hold characters until the area around (0,0) exists, then spawn them on dry land
		ReadyRadiusChunks = 4, -- chunks around (0,0) that must be loaded before spawning
	},

	Decoration = nil, -- true/false sets Terrain.Decoration (grass blades); nil leaves it unchanged
}

return Config
