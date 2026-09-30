local ChunkGenerator = require(TG.World.ChunkGenerator)
local Compiler = require(TG.Density.Compiler)
local gen = ChunkGenerator.new(12345)
local S = gen.sampler
local fill = gen.fill
local router = S.router
local id = router.final_density
for _, c in { { 5, -3 }, { -12, 40 }, { 0, 0 } } do
	local minX, minZ = c[1] * 16, c[2] * 16
	Compiler.setChunk(S, minX, minZ)
	Compiler.fillLattices(S, fill.interps)
	local f = S.fns[id]
	local worst, n = 0, 0
	-- corner voxels: lattice value must equal direct evaluation exactly
	for ix = 0, 4 do for iz = 0, 4 do for iy = 0, 48, 5 do
		local x, z, y = minX + ix * 4, minZ + iz * 4, -64 + iy * 8
		if x < minX + 16 and z < minZ + 16 and y < 320 then
			local lattice = f(x, y, z)
			local direct = Compiler.direct(S, function() return f(x, y, z) end)
			worst = math.max(worst, math.abs(lattice - direct)); n += 1
		end
	end end end
	-- trilinear property: the value at a cell's centre voxel lies between the min/max of the cell's corners
	local inside = true
	for _, p in { { 1, 2, 1 }, { 6, 37, 10 }, { 13, 100, 9 } } do
		local x, y, z = minX + p[1], -64 + p[2], minZ + p[3]
		local v = f(x, y, z)
		local cx, cz, cy = p[1] // 4, p[3] // 4, p[2] // 8
		local lo, hi = Compiler.cellInterval(S, id, cx, cz, cy)
		if v < lo - 1e-12 or v > hi + 1e-12 then inside = false end
	end
	print(string.format("chunk (%d,%d): %d corner checks, worst |lattice - direct| = %.3g; interior values within cell interval: %s", c[1], c[2], n, worst, tostring(inside)))
	assert(worst == 0 and inside)
end
print("lattice OK")
