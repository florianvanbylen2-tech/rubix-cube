-- Structure placement: random_spread layout, determinism, filters. Uses synthetic chunks (no terrain needed).
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Structures = require(TG.World.Structures)

local function fakeChunk(cx, cz, biomeId, floor, top, rough)
	local floorY, topY, biomeTop = {}, {}, {}
	for i = 1, 256 do
		floorY[i] = floor + (rough and (i % 7) * 3 or 0)
		topY[i] = top or floor
		biomeTop[i] = biomeId
	end
	return { cx = cx, cz = cz, floorY = floorY, topY = topY, biomeTop = biomeTop }
end

local function layout(gen, def, biomeId, floor, top, rough, size)
	local s = Structures.new(gen, { Structures.normalize(def) })
	local out = {}
	for cx = 0, size - 1 do
		for cz = 0, size - 1 do
			for _, p in Structures.place(s, fakeChunk(cx, cz, biomeId, floor, top, rough)) do
				table.insert(out, { cx = cx, cz = cz, p = p })
			end
		end
	end
	return out
end

local gen = ChunkGenerator.new(12345)
local names = gen.registry.names
local function idOf(name) for id, n in names do if n == name then return id end end error("no biome " .. name) end
local plains, desert = idOf("plains"), idOf("desert")
local SIZE, SPACING, SEP = 60, 6, 2
local base = { Name = "Tower", Spacing = SPACING, Separation = SEP, Chance = 1, Placement = "Any", MaxSlope = 99 }

-- 1. exactly one structure per cell, inside its allowed offset range, at least Separation chunks from the others
local a = layout(gen, base, plains, 70, 70, false, SIZE)
assert(#a == (SIZE / SPACING) ^ 2, "expected one structure per cell, got " .. #a)
for _, e in a do
	local rx, rz = e.cx // SPACING, e.cz // SPACING
	assert(e.cx - rx * SPACING < SPACING - SEP and e.cz - rz * SPACING < SPACING - SEP, "origin outside its cell margin")
end
for i = 1, #a do for j = i + 1, #a do
	local d = math.max(math.abs(a[i].cx - a[j].cx), math.abs(a[i].cz - a[j].cz))
	assert(d >= SEP, "two structures closer than Separation")
end end
print("1. one structure per " .. SPACING .. "x" .. SPACING .. " cell, spacing/separation respected:", #a)

-- 2. deterministic, seed dependent, name dependent
local b = layout(gen, base, plains, 70, 70, false, SIZE)
for i = 1, #a do assert(a[i].cx == b[i].cx and a[i].p.x == b[i].p.x and a[i].p.seed == b[i].p.seed and a[i].p.rot == b[i].p.rot) end
local c = layout(ChunkGenerator.new(999), base, plains, 70, 70, false, SIZE)
local d = layout(gen, { Name = "Other", Spacing = SPACING, Separation = SEP, Placement = "Any", MaxSlope = 99 }, plains, 70, 70, false, SIZE)
local same1, same2 = 0, 0
for i = 1, #a do
	if a[i].cx == c[i].cx and a[i].cz == c[i].cz then same1 += 1 end
	if a[i].cx == d[i].cx and a[i].cz == d[i].cz then same2 += 1 end
end
assert(same1 < #a * 0.6 and same2 < #a * 0.6, "layout should change with seed and name")
print("2. deterministic; different seed / name -> different layout (", same1, same2, "of", #a, "coincide)")

-- 3. Chance
local half = layout(gen, { Name = "Tower", Spacing = 6, Separation = 2, Chance = 0.5, Placement = "Any", MaxSlope = 99 }, plains, 70, 70, false, 180)
local frac = #half / (30 * 30)
assert(frac > 0.42 and frac < 0.58, "Chance 0.5 gave " .. frac)
print(string.format("3. Chance 0.5 -> %.3f of cells", frac))

-- 4. biome filter
local onlyDesert = { Name = "Ruin", Spacing = 6, Separation = 2, Placement = "Any", MaxSlope = 99, Biomes = { "minecraft:desert" } }
assert(#layout(gen, onlyDesert, plains, 70, 70, false, SIZE) == 0, "biome filter let plains through")
assert(#layout(gen, onlyDesert, desert, 70, 70, false, SIZE) == 100, "biome filter blocked desert")
print("4. biome filter ok")

-- 5. placement kinds, sea level, slope
local land = { Name = "L", Spacing = 6, Separation = 2, Placement = "Land", MaxSlope = 99 }
assert(#layout(gen, land, plains, 70, 70, false, SIZE) == 100, "land on dry ground")
assert(#layout(gen, land, plains, 50, 63, false, SIZE) == 0, "land below sea level / underwater must not place")
assert(#layout(gen, { Name = "W", Spacing = 6, Separation = 2, Placement = "Water", MaxSlope = 99 }, plains, 50, 63, false, SIZE) == 100, "water placement")
assert(#layout(gen, { Name = "W", Spacing = 6, Separation = 2, Placement = "Water", MaxSlope = 99 }, plains, 70, 70, false, SIZE) == 0, "water placement on land")
assert(#layout(gen, { Name = "S", Spacing = 6, Separation = 2, Placement = "Any", MaxSlope = 2 }, plains, 70, 70, true, SIZE) == 0, "MaxSlope must reject rough ground")
print("5. Land / Water / Any and MaxSlope ok")

-- 6. validation
for _, bad in { {}, { Name = "" }, { Name = "x", Spacing = 5, Separation = 5 }, { Name = "x", Placement = "Sky" }, { Name = "x", Spacing = 1 } } do
	assert(not pcall(Structures.normalize, bad), "invalid definition accepted")
end
print("6. invalid definitions rejected")
print("structures OK")
