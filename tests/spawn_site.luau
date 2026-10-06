--@include roblox_mock.luau
-- The spawn hall needs level dry ground: check the search finds it for many seeds, and how far from (0, 0).
local Server = require(TG.Runtime.Server)
local ChunkGenerator = require(TG.World.ChunkGenerator)
local Queries = require(TG.World.Queries)
local bad, far, worst = 0, 0, 0
local seeds = { 1, 2, 3, 12345, 777, 31337, "alpha", "beta", "gamma", "delta", "Minecraft", "roblox" }
for _, seed in seeds do
	local gen = ChunkGenerator.new(seed, { things = false })
	local x, z, y
	task.spawn(function() x, z, y = Server.findSpawn(gen, true) end)
	for _ = 1, 4000 do if x then break end MOCK.advance(0.05) end
	assert(x, "search did not finish for seed " .. tostring(seed))
	local lo, hi = y, y
	for _, c in { { -8, -8 }, { 8, -8 }, { -8, 8 }, { 8, 8 } } do
		local cy = Queries.surfaceY(gen, x + c[1], z + c[2])
		lo, hi = math.min(lo, cy), math.max(hi, cy)
	end
	local dist = math.sqrt(x * x + z * z) * 4
	worst = math.max(worst, dist)
	if y < 65 or hi - lo > 3 then bad += 1 end
	print(string.format("seed %-10s spawn block (%5d,%5d) %4d studs from origin, ground y %d, corner spread %d", tostring(seed), x, z, dist, y, hi - lo))
end
assert(bad == 0, bad .. " seeds ended without level dry ground")
print("spawn_site OK, farthest", math.floor(worst), "studs")
