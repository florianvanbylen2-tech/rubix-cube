--!strict
-- Pieces the server and the client runtimes have in common: what is published to clients, and how generator /
-- writer / worker settings are derived from the Config for each role.

local HttpService = game:GetService("HttpService")

local Structures = require(script.Parent.Parent.World.Structures)

local Shared = {}

local VOXEL = 4

function Shared.baseY(cfg: any): number
	return math.floor(cfg.BedrockLevel / VOXEL) * VOXEL
end

local function rgbOf(c: any): { number }
	if typeof(c) == "Color3" then
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end
	return { c[1], c[2], c[3] } -- already { r, g, b }
end

-- Material overrides in the plain form Blocks.configure and the workers understand.
function Shared.blocksSpec(cfg: any): any
	local colors: { [string]: { number } } = {}
	for material, c in cfg.Materials.Colors do
		colors[material] = rgbOf(c)
	end
	return { materials = cfg.Materials.Blocks, custom = cfg.Materials.Custom, colors = colors }
end

-- role: "server" (decides trees / ores / structures; writes terrain only in TerrainMode "Server"),
--       "client" (terrain only), "query" (biome / height lookups only)
function Shared.generatorOptions(cfg: any, role: string, customBiomes: { any }): any
	local o: any = {
		customBiomes = customBiomes,
		disabledBiomes = cfg.Biomes.Disabled,
		smooth = cfg.SmoothTerrain,
		things = false,
	}
	if role == "server" then
		o.things = true
		o.smooth = cfg.TerrainMode == "Server" and cfg.SmoothTerrain -- the occupancy buffer is only needed where terrain is written
		o.spawning = cfg.Spawning
		o.trees = cfg.Trees
		o.ores = cfg.Ores
		o.structures = Structures.normalizeAll(cfg.Structures)
	elseif role == "query" then
		o.smooth = false
	end
	return o
end

function Shared.writerConfig(cfg: any, writeBudgetMs: number): any
	return {
		bedrockLevel = Shared.baseY(cfg),
		applyColors = cfg.ApplyMaterialColors,
		variants = cfg.Materials.Variants,
		decoration = cfg.Decoration,
		writeBudgetMs = writeBudgetMs,
	}
end

-- ---------------------------------------------------------------------------------------- publishing
-- The part of the Config clients need (they generate the terrain), as a JSON string.
function Shared.serialize(cfg: any, customBiomes: { any }): string
	local colors: { [string]: { number } } = {}
	for material, c in cfg.Materials.Colors do
		colors[material] = rgbOf(c)
	end
	local data = {
		Seed = cfg.Seed,
		Width = cfg.Width,
		Length = cfg.Length,
		BedrockLevel = cfg.BedrockLevel,
		TerrainMode = cfg.TerrainMode,
		SmoothTerrain = cfg.SmoothTerrain,
		ApplyMaterialColors = cfg.ApplyMaterialColors,
		ClearBeforeGenerating = cfg.ClearBeforeGenerating,
		PrintProgress = cfg.PrintProgress,
		Decoration = cfg.Decoration,
		Streaming = cfg.Streaming,
		Client = cfg.Client,
		Biomes = cfg.Biomes,
		Materials = { Blocks = cfg.Materials.Blocks, Variants = cfg.Materials.Variants, Custom = cfg.Materials.Custom, Colors = colors },
		Mobs = cfg.Mobs,
		Spawn = cfg.Spawn,
		CustomBiomes = customBiomes,
	}
	return HttpService:JSONEncode(data)
end

-- Applies a serialize() string to a (client) Config. Returns the custom biome definitions.
function Shared.apply(cfg: any, json: string): { any }
	local data = HttpService:JSONDecode(json)
	for _, k in
		{ "Seed", "Width", "Length", "BedrockLevel", "TerrainMode", "SmoothTerrain", "ApplyMaterialColors", "ClearBeforeGenerating", "PrintProgress", "Decoration" }
	do
		cfg[k] = data[k]
	end
	for _, k in { "Streaming", "Client", "Biomes", "Mobs", "Spawn" } do
		if data[k] ~= nil then
			cfg[k] = data[k]
		end
	end
	local m = data.Materials or {}
	local colors: { [string]: Color3 } = {}
	for material, rgb in m.Colors or {} do
		colors[material] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	cfg.Materials = { Blocks = m.Blocks or {}, Variants = m.Variants or {}, Custom = m.Custom or {}, Colors = colors }
	return data.CustomBiomes or {}
end

-- The config JSON travels as attributes too; long strings are split ("Config" or "ConfigParts" + "Config_<i>").
local CONFIG_PART = 50000

function Shared.publishConfig(state: Instance, json: string)
	if #json <= CONFIG_PART then
		state:SetAttribute("Config", json)
		return
	end
	local n = math.ceil(#json / CONFIG_PART)
	for i = 1, n do
		state:SetAttribute("Config_" .. i, string.sub(json, (i - 1) * CONFIG_PART + 1, i * CONFIG_PART))
	end
	state:SetAttribute("ConfigParts", n)
end

function Shared.readConfig(state: Instance): string
	local n = state:GetAttribute("ConfigParts")
	if type(n) ~= "number" then
		return state:GetAttribute("Config") :: string
	end
	local parts: { string } = {}
	for i = 1, n do
		parts[i] = state:GetAttribute("Config_" .. i) :: string
	end
	return table.concat(parts)
end

-- Lock sets travel as attributes on the state folder: "LocksActive" = "<version>:<parts>" and "Locks_<version>_<i>".
function Shared.publishLocks(state: Instance, parts: { string }, version: number)
	local previous = state:GetAttribute("LocksActive")
	for i, part in parts do
		state:SetAttribute(string.format("Locks_%d_%d", version, i), part)
	end
	state:SetAttribute("LocksActive", string.format("%d:%d", version, #parts))
	if type(previous) == "string" then
		local v, n = string.match(previous, "^(%d+):(%d+)$")
		if v then
			for i = 1, tonumber(n) :: number do
				state:SetAttribute(string.format("Locks_%s_%d", v, i), nil)
			end
		end
	end
end

-- nil when the active lock set is not completely replicated yet.
function Shared.readLocks(state: Instance): { string }?
	local active = state:GetAttribute("LocksActive")
	if type(active) ~= "string" then
		return {}
	end
	local v, n = string.match(active, "^(%d+):(%d+)$")
	if not v then
		return {}
	end
	local parts: { string } = {}
	for i = 1, tonumber(n) :: number do
		local part = state:GetAttribute(string.format("Locks_%s_%d", v, i))
		if type(part) ~= "string" then
			return nil
		end
		parts[i] = part
	end
	return parts
end

return Shared
