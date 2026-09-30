local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY
local gen = ChunkGenerator.new(12345)
local chunk = gen:generate(5, -3) -- hilly dark forest
assert(chunk.occ, "occupancy missing")
print("column profile x=0..15 at z=8 : top solid block y, and sub-voxel surface y estimated from occupancy")
local out = {}
for x = 0, 15 do
	local col = x * 16 + 8
	local top = chunk.floorY[col + 1]
	-- surface position = first y (scanning down from top+2) where the accumulated occupancy reaches 0.5 crossing
	local est = nil
	for y = top + 3, top - 3, -1 do
		local o = buffer.readu8(chunk.occ, col * H + (y - MINY)) / 255
		local o2 = buffer.readu8(chunk.occ, col * H + (y - 1 - MINY)) / 255
		if o < 0.5 and o2 >= 0.5 then
			est = (y - 1) + 0.5 + (o2 - 0.5) / math.max(o2 - o, 1e-6) -- linear iso-surface between voxel centres
			break
		end
	end
	table.insert(out, string.format("%d:%.2f", top, est or -1))
end
print(table.concat(out, "  "))
-- distribution of occupancy values (partial voxels vs full/empty)
local hist = {0, 0, 0, 0}
local total = 0
for i = 0, 256 * H - 1 do
	local o = buffer.readu8(chunk.occ, i)
	local b = buffer.readu8(chunk.blocks, i)
	if o == 0 then hist[1] += 1 elseif o == 255 then hist[3] += 1 else hist[2] += 1 end
end
print(string.format("voxels: empty %d, partial %d, full %d", hist[1], hist[2], hist[3]))
-- ocean chunk: seabed voxel next to water
local oc = gen:generate(0, 0)
local col = 8 * 16 + 8
local top = oc.floorY[col + 1]
local line = {}
for y = top + 2, top - 2, -1 do
	local i = col * H + (y - MINY)
	table.insert(line, string.format("y=%d block=%s occ=%d", y, Blocks.names[buffer.readu8(oc.blocks, i)], buffer.readu8(oc.occ, i)))
end
print(table.concat(line, " | "))
