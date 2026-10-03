--!strict
-- Starts the terrain generator when the server boots. Clients start themselves: Start() copies the module to
-- ReplicatedStorage and installs the client runner. Delete this script and call TerrainGenerator.Start() from your
-- own code if you want to change the Config first (always BEFORE Start()).

local ServerScriptService = game:GetService("ServerScriptService")
local TerrainGenerator = require(ServerScriptService:WaitForChild("TerrainGenerator"))

-- TerrainGenerator.Config.Seed = "MyWorldName"
-- TerrainGenerator.Config.Width = 1024      -- studs of terrain each player sees
-- TerrainGenerator.Config.Length = 1024

-- Optional "magical" biomes (they overlay the vanilla map where their climate/noise conditions match):
-- for _, biome in require(TerrainGenerator.Examples.MagicalBiomes) do
--     TerrainGenerator.RegisterBiome(biome)
-- end

-- Every way to add / remove / configure trees, ores, structures, biomes and materials, with examples:
-- require(TerrainGenerator.Examples.CustomThings)(TerrainGenerator)

-- Trees, ores and structures are announced through TerrainGenerator/Placement.luau (it only prints for now).
-- Write your own code there, or install handlers:
-- TerrainGenerator.SetPlacementHandler(function(thingType, location, info) ... end)

TerrainGenerator.Start()
