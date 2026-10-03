--@include roblox_mock.luau
local ChunkGenerator = require(TG.World.ChunkGenerator)
local ChunkWriter = require(TG.Streaming.ChunkWriter)
local Blocks = require(TG.World.Blocks)
local Settings = require(TG.Data.Settings)
local H, MINY = Settings.height, Settings.minY

local BASE = 64 -- bedrock level (studs) other than 0 to test the offset handling
local cfg = { bedrockLevel = BASE, applyColors = true, writeBudgetMs = math.huge }
ChunkWriter.applyGlobals(cfg)
local writer = ChunkWriter.new(cfg)
local gen = ChunkGenerator.new(12345)
ChunkWriter.setBiomeNames(writer, gen.registry.names)

for _, c in { { 5, -3 }, { 0, 0 }, { -30, 12 } } do
	local chunk = gen:generate(c[1], c[2])
	local t0 = os.clock()
	local f0, w0 = MOCK.terrain.fills, MOCK.terrain.writes
	local topStuds = writer:write(chunk)
	local dt = (os.clock() - t0) * 1000
	local voxels = MOCK.terrain.voxels
	-- compare with expected
	local bad, checked, partial = 0, 0, 0
	for x = 0, 15 do for z = 0, 15 do
		local col = x * 16 + z
		for yi = 0, H - 1 do
			local b = buffer.readu8(chunk.blocks, col * H + yi)
			local o = buffer.readu8(chunk.occ, col * H + yi)
			local vx, vy, vz = c[1] * 16 + x, BASE / 4 + yi, c[2] * 16 + z
			local v = voxels[vx .. "," .. vy .. "," .. vz]
			checked += 1
			if b == Blocks.AIR then
				if o < 6 then
					if v ~= nil then bad += 1 end
				else
					if v == nil or math.abs(v[2] - o / 255) > 1e-9 then
						bad += 1
						if bad <= 5 then
							local below = yi > 0 and buffer.readu8(chunk.blocks, col * H + yi - 1) or -1
							local above = yi < H - 1 and buffer.readu8(chunk.blocks, col * H + yi + 1) or -1
							print("  air mismatch: y", yi + MINY, "occ", o, "below", Blocks.names[below] or below, "above", Blocks.names[above] or above, "voxel", v and v[1])
						end
					end
				end
			else
				if o == 0 then
					-- solid by sample point but empty by the smoothed density field: no voxel expected
					if v ~= nil then bad += 1 end
				elseif v == nil or math.abs(v[2] - o / 255) > 1e-9 then
					bad += 1
					if bad <= 8 then print("  solid mismatch: y", yi + MINY, "block", Blocks.names[b], "occ", o, "voxel", v and v[1], v and v[2]) end
				end
				if o < 255 then partial += 1 end
			end
		end
	end end
	print(string.format("chunk (%d,%d): %d voxels checked, %d mismatches, %d partial-occupancy voxels; FillBlock x%d, WriteVoxels x%d, %.0f ms; written height %d studs",
		c[1], c[2], checked, bad, partial, MOCK.terrain.fills - f0, MOCK.terrain.writes - w0, dt, topStuds))
	assert(bad == 0, "voxel mismatch")
	-- the reported height covers every voxel that was written (so unload clears everything)
	for k in MOCK.terrain.voxels do
		local x, y, z = string.match(k, "(-?%d+),(-?%d+),(-?%d+)")
		if tonumber(x) >= c[1] * 16 and tonumber(x) < c[1] * 16 + 16 and tonumber(z) >= c[2] * 16 and tonumber(z) < c[2] * 16 + 16 then
			assert((tonumber(y) :: number) * 4 - BASE < topStuds, "voxel above the reported height")
		end
	end
	-- unload
	writer:unload(c[1], c[2], topStuds)
	local left = 0
	for k in MOCK.terrain.voxels do
		local x, y, z = string.match(k, "(-?%d+),(-?%d+),(-?%d+)")
		x, z = tonumber(x), tonumber(z)
		if x >= c[1] * 16 and x < c[1] * 16 + 16 and z >= c[2] * 16 and z < c[2] * 16 + 16 then left += 1 end
	end
	assert(left == 0, "voxels left after unload: " .. left)
end
print("material colours applied:", (function() local n = 0 for _ in MOCK.terrain.colors do n += 1 end return n end)())
print("writer OK")
