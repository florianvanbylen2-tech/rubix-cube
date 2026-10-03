--!strict
-- Display names of the things the generator can place ("Oak Tree", "Iron Ore", ...). These are the strings passed
-- to placeThing and the keys of Config.Trees / Config.Ores.

local ThingNames = {}

ThingNames.trees = {
	oak = "Oak Tree",
	fancy_oak = "Fancy Oak Tree",
	fancy_oak_bees = "Fancy Oak Tree",
	swamp_oak = "Swamp Oak Tree",
	birch = "Birch Tree",
	super_birch = "Tall Birch Tree",
	super_birch_bees = "Tall Birch Tree",
	spruce = "Spruce Tree",
	pine = "Pine Tree",
	mega_spruce = "Giant Spruce Tree",
	mega_pine = "Giant Pine Tree",
	jungle_tree = "Jungle Tree",
	mega_jungle_tree = "Giant Jungle Tree",
	jungle_bush = "Jungle Bush",
	acacia = "Acacia Tree",
	dark_oak = "Dark Oak Tree",
	mangrove = "Mangrove Tree",
	tall_mangrove = "Tall Mangrove Tree",
	cherry = "Cherry Tree",
	huge_red_mushroom = "Huge Red Mushroom",
	huge_brown_mushroom = "Huge Brown Mushroom",
} :: { [string]: string }

ThingNames.ores = {
	coal = "Coal Ore",
	iron = "Iron Ore",
	copper = "Copper Ore",
	gold = "Gold Ore",
	redstone = "Redstone Ore",
	lapis = "Lapis Lazuli Ore",
	diamond = "Diamond Ore",
	emerald = "Emerald Ore",
} :: { [string]: string }

-- "crystal_tree" -> "Crystal Tree"
function ThingNames.title(id: string): string
	local words = {}
	for w in string.gmatch(id, "[^_%s]+") do
		table.insert(words, (string.gsub(w, "^%l", string.upper)))
	end
	return table.concat(words, " ")
end

function ThingNames.tree(species: string): string
	return ThingNames.trees[species] or ThingNames.title(species)
end

function ThingNames.ore(ore: string): string
	return ThingNames.ores[ore] or ThingNames.title(ore)
end

local function sortedUnique(map: { [string]: string }): { string }
	local seen, out = {}, {}
	for _, name in map do
		if not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

ThingNames.treeList = sortedUnique(ThingNames.trees)
ThingNames.oreList = sortedUnique(ThingNames.ores)

return ThingNames
