--!strict
-- >>> THE PLACEMENT HOOK <<<
--
-- Every tree, ore and structure the generator decides to put into the world ends up here, on the SERVER, as one
-- call per thing:
--
--     placeThing(thingType, location, info)
--         thingType   "Oak Tree", "Iron Ore", "Village", "Medieval Castle", ... (the names used in Config.Trees,
--                     Config.Ores and Config.Structures; custom things use the Name you registered)
--         location    Vector3 in studs: where the thing goes (trees/structures: the ground point, ores: the centre
--                     of the vein)
--         info        { Kind = "Tree" | "Ore" | "Structure", Biome, Chunk = Vector2, Seed, Rotation (degrees,
--                       structures), Size (ore vein blocks), Height (tree trunk height) }
--
-- NO placing logic is implemented on purpose: the function below only prints. Write your own code in
-- placeThing / removeThings (or install handlers with TerrainGenerator.SetPlacementHandler and
-- TerrainGenerator.SetRemovalHandler, so you do not have to edit this file).
--
-- removeThings(chunkX, chunkZ) is called when a chunk unloads on the server (nobody near it and it is not locked):
-- remove everything you placed for that chunk. A chunk that loads again places the same things again.

local Placement = {}

export type Info = {
	Kind: string,
	Biome: string,
	Chunk: Vector2,
	Seed: number,
	Rotation: number?,
	Size: number?,
	Height: number?,
}

-- printing is rate limited: a big world places thousands of things per second while it loads
local printEnabled = true
local maxPerSecond = 40
local windowStart = 0
local printedInWindow = 0
local suppressed = 0

local placeHandler: ((string, Vector3, Info) -> ())? = nil
local removeHandler: ((number, number) -> ())? = nil

function Placement.configure(print_: boolean, perSecond: number)
	printEnabled = print_
	maxPerSecond = perSecond
end

function Placement.setHandlers(onPlace: ((string, Vector3, Info) -> ())?, onRemove: ((number, number) -> ())?)
	placeHandler = onPlace or placeHandler
	removeHandler = onRemove or removeHandler
end

local function log(...: any)
	local t = os.clock()
	if t - windowStart >= 1 then
		if suppressed > 0 then
			print(string.format("[TerrainGenerator] (%d more placement calls in the last second were not printed; Config.Placement.Print = false silences them all)", suppressed))
		end
		windowStart, printedInWindow, suppressed = t, 0, 0
	end
	if printedInWindow < maxPerSecond then
		printedInWindow += 1
		print(...)
	else
		suppressed += 1
	end
end

-- Insert Placement Function Here
function Placement.placeThing(thingType: string, location: Vector3, info: Info)
	if placeHandler then
		placeHandler(thingType, location, info)
		return
	end
	if printEnabled then
		log(
			"Add Place Structure/Ore Code Here",
			string.format(
				'placeThing("%s", Vector3.new(%.1f, %.1f, %.1f))  -- %s in %s, chunk %d,%d',
				thingType, location.X, location.Y, location.Z, info.Kind, info.Biome, info.Chunk.X, info.Chunk.Y
			)
		)
	end
end

-- Insert Removal Function Here
function Placement.removeThings(chunkX: number, chunkZ: number)
	if removeHandler then
		removeHandler(chunkX, chunkZ)
		return
	end
	if printEnabled then
		log("Add Remove Structure/Ore Code Here", string.format("removeThings(%d, %d)  -- chunk unloaded", chunkX, chunkZ))
	end
end

return Placement
