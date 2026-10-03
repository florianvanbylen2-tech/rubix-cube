-- Time-sliced generation must give byte-identical chunks to the uninterrupted pipeline, and must actually yield.
local ChunkGenerator = require(TG.World.ChunkGenerator)
local gen = ChunkGenerator.new(12345)
local bad, yields = 0, 0
for _, c in { { 0, 0 }, { 7, -4 }, { -13, 9 } } do
	local plain = gen:generate(c[1], c[2])
	local n = 0
	local sliced = gen:generate(c[1], c[2], function() n += 1 end)
	yields += n
	if buffer.tostring(plain.blocks) ~= buffer.tostring(sliced.blocks) then bad += 1 end
	if plain.occ and buffer.tostring(plain.occ :: buffer) ~= buffer.tostring(sliced.occ :: buffer) then bad += 1 end
	if #plain.placements ~= #sliced.placements then bad += 1 end
end
print(string.format("sliced == plain: mismatches %d, yield calls %d (%.1f per chunk)", bad, yields, yields / 3))
assert(bad == 0 and yields >= 3 * 15, "sliced generation differs or does not yield")
print("sliced OK")
