--!strict
-- Starts the terrain generator when the server boots. Delete this script and call TerrainGenerator.Start()
-- from your own code if you want to change the Config first.

local ServerScriptService = game:GetService("ServerScriptService")
local TerrainGenerator = require(ServerScriptService:WaitForChild("TerrainGenerator"))

-- TerrainGenerator.Config.Seed = "MyWorldName"
-- TerrainGenerator.Config.Width = 1024
-- TerrainGenerator.Config.Length = 1024

-- Optional "magical" biomes (they overlay the vanilla map where their climate/noise conditions match):
-- for _, biome in require(TerrainGenerator.Examples.MagicalBiomes) do
--     TerrainGenerator.RegisterBiome(biome)
-- end

TerrainGenerator.Start()
