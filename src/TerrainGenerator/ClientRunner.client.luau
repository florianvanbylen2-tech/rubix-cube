--!strict
-- Starts the terrain generator on a client. TerrainGenerator.Start() on the server installs a copy of this script
-- into StarterPlayerScripts (and into the PlayerGui of players already in the game), so you never place it yourself.
-- This template is disabled and never runs in place.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if player:GetAttribute("TerrainGeneratorClientStarted") then
	return -- another copy of this runner is already running on this client
end
player:SetAttribute("TerrainGeneratorClientStarted", true)

local module = ReplicatedStorage:WaitForChild("TerrainGenerator", 120)
if module then
	require(module).StartClient()
else
	warn("[TerrainGenerator] the module never arrived in ReplicatedStorage")
end
