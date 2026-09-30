--!strict
--!native
-- Minecraft's ImprovedNoise (Perlin gradient noise with a shuffled permutation table).
-- The permutation is stored doubled (512 entries, 1-based) so no masking is needed in the hot path.

local floor = math.floor

-- SimplexNoise.GRADIENT, split per axis and indexed by (hash & 15) + 1
local GX = { 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0, 1, 0, -1, 0 }
local GY = { 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1, 1, -1, 1, -1 }
local GZ = { 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1, 0, 1, 0, -1 }

-- (double)1.0E-7F
local Y_FUDGE = 1.0000000116860974e-07

export type ImprovedNoise = {
	xo: number,
	yo: number,
	zo: number,
	p: { number }, -- permutation, doubled, 1-based
	pg: { number }, -- (permutation & 15) + 1, doubled, 1-based
	noise: (ImprovedNoise, number, number, number, number, number) -> number,
	sample: (ImprovedNoise, number, number, number) -> number,
}

local ImprovedNoise = {}
ImprovedNoise.__index = ImprovedNoise

-- `random` is any object with nextDouble() and nextInt(bound) (Xoroshiro or JavaRandom).
function ImprovedNoise.new(random: any): ImprovedNoise
	local xo = random:nextDouble() * 256
	local yo = random:nextDouble() * 256
	local zo = random:nextDouble() * 256
	local perm = table.create(256, 0)
	for i = 1, 256 do
		perm[i] = i - 1
	end
	for k = 0, 255 do
		local l = random:nextInt(256 - k)
		perm[k + 1], perm[k + l + 1] = perm[k + l + 1], perm[k + 1]
	end
	local p = table.create(512, 0)
	local pg = table.create(512, 0)
	for i = 1, 512 do
		local v = perm[(i - 1) % 256 + 1]
		p[i] = v
		pg[i] = bit32.band(v, 15) + 1
	end
	return setmetatable({ xo = xo, yo = yo, zo = zo, p = p, pg = pg }, ImprovedNoise) :: any
end

-- General form used by BlendedNoise (yScale/yMax implement the vertical "smear").
function ImprovedNoise.noise(self: ImprovedNoise, x: number, y: number, z: number, yScale: number, yMax: number): number
	local d0, d1, d2 = x + self.xo, y + self.yo, z + self.zo
	local i, j, k = floor(d0), floor(d1), floor(d2)
	local dx, dy, dz = d0 - i, d1 - j, d2 - k
	local wy = dy
	if yScale ~= 0 then
		local d7 = (yMax >= 0 and yMax < dy) and yMax or dy
		wy = dy - floor(d7 / yScale + Y_FUDGE) * yScale
	end

	local p, pg = self.p, self.pg
	local ix, iy, iz = i % 256 + 1, j % 256 + 1, k % 256 + 1
	local a, b = p[ix], p[ix + 1]
	local aa, ab = a + iy, a + iy + 1
	local ba, bb = b + iy, b + iy + 1
	local ka, kb, kc, kd = p[aa], p[ab], p[ba], p[bb]

	local x1, y1, z1 = dx - 1, wy - 1, dz - 1
	local g0 = pg[ka + iz]
	local g1 = pg[kc + iz]
	local g2 = pg[kb + iz]
	local g3 = pg[kd + iz]
	local g4 = pg[ka + iz + 1]
	local g5 = pg[kc + iz + 1]
	local g6 = pg[kb + iz + 1]
	local g7 = pg[kd + iz + 1]

	local d000 = GX[g0] * dx + GY[g0] * wy + GZ[g0] * dz
	local d100 = GX[g1] * x1 + GY[g1] * wy + GZ[g1] * dz
	local d010 = GX[g2] * dx + GY[g2] * y1 + GZ[g2] * dz
	local d110 = GX[g3] * x1 + GY[g3] * y1 + GZ[g3] * dz
	local d001 = GX[g4] * dx + GY[g4] * wy + GZ[g4] * z1
	local d101 = GX[g5] * x1 + GY[g5] * wy + GZ[g5] * z1
	local d011 = GX[g6] * dx + GY[g6] * y1 + GZ[g6] * z1
	local d111 = GX[g7] * x1 + GY[g7] * y1 + GZ[g7] * z1

	local u = dx * dx * dx * (dx * (dx * 6 - 15) + 10)
	local v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
	local w = dz * dz * dz * (dz * (dz * 6 - 15) + 10)

	local l00 = d000 + u * (d100 - d000)
	local l10 = d010 + u * (d110 - d010)
	local l01 = d001 + u * (d101 - d001)
	local l11 = d011 + u * (d111 - d011)
	local m0 = l00 + v * (l10 - l00)
	local m1 = l01 + v * (l11 - l01)
	return m0 + w * (m1 - m0)
end

-- noise(x, y, z, 0, 0) without the smear branch
function ImprovedNoise.sample(self: ImprovedNoise, x: number, y: number, z: number): number
	local d0, d1, d2 = x + self.xo, y + self.yo, z + self.zo
	local i, j, k = floor(d0), floor(d1), floor(d2)
	local dx, dy, dz = d0 - i, d1 - j, d2 - k

	local p, pg = self.p, self.pg
	local ix, iy, iz = i % 256 + 1, j % 256 + 1, k % 256 + 1
	local a, b = p[ix], p[ix + 1]
	local aa, ab = a + iy, a + iy + 1
	local ba, bb = b + iy, b + iy + 1
	local ka, kb, kc, kd = p[aa], p[ab], p[ba], p[bb]

	local x1, y1, z1 = dx - 1, dy - 1, dz - 1
	local g0 = pg[ka + iz]
	local g1 = pg[kc + iz]
	local g2 = pg[kb + iz]
	local g3 = pg[kd + iz]
	local g4 = pg[ka + iz + 1]
	local g5 = pg[kc + iz + 1]
	local g6 = pg[kb + iz + 1]
	local g7 = pg[kd + iz + 1]

	local d000 = GX[g0] * dx + GY[g0] * dy + GZ[g0] * dz
	local d100 = GX[g1] * x1 + GY[g1] * dy + GZ[g1] * dz
	local d010 = GX[g2] * dx + GY[g2] * y1 + GZ[g2] * dz
	local d110 = GX[g3] * x1 + GY[g3] * y1 + GZ[g3] * dz
	local d001 = GX[g4] * dx + GY[g4] * dy + GZ[g4] * z1
	local d101 = GX[g5] * x1 + GY[g5] * dy + GZ[g5] * z1
	local d011 = GX[g6] * dx + GY[g6] * y1 + GZ[g6] * z1
	local d111 = GX[g7] * x1 + GY[g7] * y1 + GZ[g7] * z1

	local u = dx * dx * dx * (dx * (dx * 6 - 15) + 10)
	local v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
	local w = dz * dz * dz * (dz * (dz * 6 - 15) + 10)

	local l00 = d000 + u * (d100 - d000)
	local l10 = d010 + u * (d110 - d010)
	local l01 = d001 + u * (d101 - d001)
	local l11 = d011 + u * (d111 - d011)
	local m0 = l00 + v * (l10 - l00)
	local m1 = l01 + v * (l11 - l01)
	return m0 + w * (m1 - m0)
end

return ImprovedNoise
