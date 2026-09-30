local ChunkGenerator = require(TG.World.ChunkGenerator)
local NoiseFill = require(TG.World.NoiseFill)
local Settings = require(TG.Data.Settings)
local H = Settings.height
local gen = ChunkGenerator.new(12345)
local total, diff = 0, 0
for _, c in { { 5, -3 }, { 0, 0 }, { 40, 40 }, { -30, 12 }, { 13, -11 }, { 9, -11 } } do
	local a = ChunkGenerator.newChunk(c[1], c[2], false)
	NoiseFill.fill(gen.fill, a)
	gen.fill.bruteForce = true
	local b = ChunkGenerator.newChunk(c[1], c[2], false)
	NoiseFill.fill(gen.fill, b)
	gen.fill.bruteForce = false
	local d = 0
	local ex = ""
	for i = 0, 256 * H - 1 do
		local x, y = buffer.readu8(a.blocks, i), buffer.readu8(b.blocks, i)
		if x ~= y then
			d += 1
			if d <= 3 then ex ..= string.format(" [idx %d shortcut=%d brute=%d y=%d]", i, x, y, i % H - 64) end
		end
	end
	total += 256 * H; diff += d
	print(string.format("chunk (%d,%d): %d differing voxels of %d %s", c[1], c[2], d, 256 * H, ex))
end
assert(diff == 0, "shortcut results differ from brute force")
print("shortcuts are exact")
