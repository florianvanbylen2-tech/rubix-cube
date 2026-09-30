local ChunkGenerator = require(TG.World.ChunkGenerator)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY
local gen = ChunkGenerator.new(12345)
local sameSum, sameN, borderSum, borderN, biggest = 0, 0, 0, 0, 0
local waterMismatch, waterN = 0, 0
for _, base in { { 5, -3 }, { 9, -11 }, { 30, 8 }, { -20, 14 } } do
	local a = gen:generateSurface(base[1], base[2])
	local b = gen:generateSurface(base[1] + 1, base[2])   -- east neighbour
	local c = gen:generateSurface(base[1], base[2] + 1)   -- south neighbour
	for z = 0, 15 do
		-- across the x border: a.x=15 vs b.x=0 ; inside a: x=14 vs x=15
		local ha, hb, hi = a.floorY[15 * 16 + z + 1], b.floorY[0 * 16 + z + 1], a.floorY[14 * 16 + z + 1]
		borderSum += math.abs(ha - hb); borderN += 1; biggest = math.max(biggest, math.abs(ha - hb))
		sameSum += math.abs(ha - hi); sameN += 1
		-- water surface presence agrees across the border
		local ta, tb = a.topY[15 * 16 + z + 1], b.topY[0 * 16 + z + 1]
		local wa = buffer.readu8(a.blocks, (15 * 16 + z) * H + (ta - MINY)) == Blocks.WATER
		local wb = buffer.readu8(b.blocks, (0 * 16 + z) * H + (tb - MINY)) == Blocks.WATER
		waterN += 1
		if wa ~= wb then waterMismatch += 1 end
	end
	for x = 0, 15 do
		local ha, hb, hi = a.floorY[x * 16 + 15 + 1], c.floorY[x * 16 + 0 + 1], a.floorY[x * 16 + 14 + 1]
		borderSum += math.abs(ha - hb); borderN += 1; biggest = math.max(biggest, math.abs(ha - hb))
		sameSum += math.abs(ha - hi); sameN += 1
	end
end
print(string.format("mean |height step| between adjacent columns: inside chunks %.3f, across chunk borders %.3f (max across border %d)", sameSum / sameN, borderSum / borderN, biggest))
print(string.format("water/land state agrees across %d of %d border columns", waterN - waterMismatch, waterN))
