local Climate = require(TG.World.Climate)
local Builder = require(TG.World.OverworldBiomeBuilder)
local Biomes = require(TG.Data.Biomes)

local t0 = os.clock()
local points = Builder.build()
print(string.format("points: %d (built in %.1f ms)", #points, (os.clock() - t0) * 1000))
t0 = os.clock()
local tree = Climate.buildTree(points)
print(string.format("tree built in %.1f ms", (os.clock() - t0) * 1000))

-- every biome name in the table must exist in the vanilla data, and every overworld biome should be reachable
local used = {}
for _, p in points do
	used[p.value] = (used[p.value] or 0) + 1
	assert(Biomes[p.value], "unknown biome " .. tostring(p.value))
end
local missing = {}
for name in Biomes do if not used[name] then table.insert(missing, name) end end
table.sort(missing)
print("biomes in data but not in the table:", #missing == 0 and "(none)" or table.concat(missing, ","))

-- coverage: sample the quantised parameter space; at depth 0 (surface) every sample must lie inside >=1 box
local holes, total = 0, 0
local ex = {}
local function q(v) return Climate.quantize(v) end
local step = 0.05
local i = -1.0
local cs = { -1.15, -1.08, -0.9, -0.5, -0.3, -0.2, -0.15, -0.1, -0.05, 0.0, 0.05, 0.2, 0.4, 0.55, 0.8, 1.0 }
for _, temp in { -0.9, -0.5, -0.3, 0.0, 0.3, 0.7, 0.99 } do
	for _, hum in { -0.9, -0.2, 0.0, 0.2, 0.6, 0.99 } do
		for _, cont in cs do
			for _, ero in { -0.95, -0.5, -0.3, -0.1, 0.2, 0.5, 0.8 } do
				for w = -1.0, 1.0, 0.0625 do
					total += 1
					local _, dist = Climate.search(tree, q(temp), q(hum), q(cont), q(ero), q(0.0), q(w))
					if dist > 0 then
						holes += 1
						if #ex < 8 then table.insert(ex, string.format("t=%.2f h=%.2f c=%.2f e=%.2f w=%.3f dist=%d", temp, hum, cont, ero, w, dist)) end
					end
				end
			end
		end
	end
end
print(string.format("coverage: %d samples, %d uncovered (%.3f%%)", total, holes, holes / total * 100))
for _, e in ex do print("  hole:", e) end

-- tree search == linear search (distance equality; the value may differ only on exact ties)
math.randomseed(7)
local mismatch, ties = 0, 0
local t1 = 0
for n = 1, 600 do
	local a = { q(math.random() * 2 - 1), q(math.random() * 2 - 1), q(math.random() * 2.2 - 1.2), q(math.random() * 2 - 1), q(math.random() * 2.2 - 0.1), q(math.random() * 2 - 1) }
	local v1 = Climate.search(tree, a[1], a[2], a[3], a[4], a[5], a[6])
	local v2, best = Climate.searchLinear(points, a[1], a[2], a[3], a[4], a[5], a[6])
	if v1 ~= v2 then
		-- check the tree's answer is also a minimum-distance point
		local found = false
		for _, p in points do
			if p.value == v1 and Climate.boxDistance(p.lo, p.hi, a[1], a[2], a[3], a[4], a[5], a[6]) == best then found = true break end
		end
		if found then ties += 1 else mismatch += 1 end
	end
end
print("tree vs linear: mismatches", mismatch, "equal-distance ties", ties)
t0 = os.clock()
for n = 1, 20000 do
	Climate.search(tree, q(math.random() * 2 - 1), q(math.random() * 2 - 1), q(math.random() * 2.2 - 1.2), q(math.random() * 2 - 1), q(0.0), q(math.random() * 2 - 1))
end
print(string.format("search: %.1f us/query", (os.clock() - t0) / 20000 * 1e6))
