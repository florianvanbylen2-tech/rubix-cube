--!strict
-- Assigns numeric ids to vanilla and custom ("magical") biomes and resolves what each one inherits.
--
-- A custom biome is plain data (so it can be sent to worker Actors):
--   {
--     id = "crystal_meadow",            -- unique, lowercase
--     displayName = "Crystal Meadow",   -- optional
--     base = "plains",                  -- vanilla biome whose surface rules / carvers / features it inherits
--     -- where it appears (all optional; ranges are in the -1..1 climate units vanilla uses):
--     climate = { temperature = {-0.15, 0.55}, humidity = {...}, continentalness = {...},
--                 erosion = {...}, weirdness = {...}, depth = {...} },
--     region = { scale = 600, threshold = 0.5 },   -- extra region noise (blocks); appears where noise > threshold
--     priority = 1,                     -- higher wins when several custom biomes match
--     surface = { top = "grass_block", filler = "dirt", fillerDepth = 3 },
--     trees = { { species = "crystal_tree", perChunk = 3 } },
--     ores = { { name = "mana", perChunk = 2, minY = -32, maxY = 64, size = 6 } },
--     temperature = 0.8,                -- optional overrides of the base biome's climate values
--   }

local Biomes = require(script.Parent.Parent.Data.Biomes)

export type Custom = {
	id: string,
	displayName: string?,
	base: string,
	climate: { [string]: { number } }?,
	region: { scale: number?, threshold: number?, octaves: number? }?,
	priority: number?,
	surface: { top: string?, filler: string?, fillerDepth: number? }?,
	trees: { { species: string, perChunk: number?, chance: number? } }?,
	ores: { { name: string, perChunk: number?, minY: number?, maxY: number?, size: number? } }?,
	temperature: number?,
	downfall: number?,
}

export type Registry = {
	names: { string }, -- id -> name
	ids: { [string]: number },
	base: { number }, -- id -> id of the vanilla biome it inherits from
	data: { any }, -- id -> biome data (temperature, carvers, features, ...)
	custom: { [number]: Custom }, -- id -> custom definition
	customList: { number }, -- custom ids sorted by descending priority
	vanillaCount: number,
}

local BiomeRegistry = {}

function BiomeRegistry.new(definitions: { Custom }?): Registry
	local vanilla: { string } = {}
	for name in Biomes do
		table.insert(vanilla, name)
	end
	table.sort(vanilla)

	local reg: Registry = {
		names = {},
		ids = {},
		base = {},
		data = {},
		custom = {},
		customList = {},
		vanillaCount = #vanilla,
	}
	for i, name in vanilla do
		reg.names[i] = name
		reg.ids[name] = i
		reg.base[i] = i
		reg.data[i] = Biomes[name]
	end
	for _, def in definitions or {} do
		assert(def.id and not reg.ids[def.id], "duplicate or missing custom biome id")
		local baseId = reg.ids[def.base]
		assert(baseId, "custom biome " .. def.id .. " has unknown base biome " .. tostring(def.base))
		local id = #reg.names + 1
		reg.names[id] = def.id
		reg.ids[def.id] = id
		reg.base[id] = baseId
		local data = table.clone(Biomes[def.base])
		if def.temperature then
			data.temperature = def.temperature
		end
		if def.downfall then
			data.downfall = def.downfall
		end
		reg.data[id] = data
		reg.custom[id] = def
		table.insert(reg.customList, id)
	end
	table.sort(reg.customList, function(a, b)
		local pa, pb = reg.custom[a].priority or 0, reg.custom[b].priority or 0
		if pa ~= pb then
			return pa > pb
		end
		return a < b
	end)
	return reg
end

return BiomeRegistry
