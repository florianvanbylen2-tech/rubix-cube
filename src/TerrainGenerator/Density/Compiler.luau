--!strict
--!native
-- Compiles the vanilla noise-router density-function graph (Data/DensityFunctions) into Luau closures.
--
-- Faithful to vanilla where it changes results:
--   * `interpolated` nodes are evaluated on the cell-corner lattice (4x8x4 blocks) and trilinearly
--     interpolated (y, then x, then z, like NoiseChunk.NoiseInterpolator);
--   * `flat_cache` quantises to 4x4 block columns inside the active chunk window and falls back to a
--     direct evaluation outside it;
--   * min/max short-circuit on static value bounds (pure optimisation, never changes a result).
-- `cache_2d` / `cache_once` are memo tables, `blend_*` were folded away at build time (no blending).

local Data = require(script.Parent.Parent.Data.DensityFunctions)
local Settings = require(script.Parent.Parent.Data.Settings)

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

export type Fn = (number, number, number) -> number

export type State = {
	minX: number, -- block coordinates of the active chunk's minimum corner
	minZ: number,
	minY: number,
	qx0: number, -- first quart (4 block) column of the chunk
	qz0: number,
	inCorner: boolean, -- true while filling lattices: `interpolated` becomes transparent
}

export type Sampler = {
	fns: { Fn },
	lo: { number },
	hi: { number },
	kinds: { string },
	nodes: { { any } },
	router: { [string]: number },
	lattices: { [number]: { number } }, -- interpolated node id -> corner values
	state: State,
	rs: any,
}

local Compiler = {}

local CELL_W = 4 * Settings.sizeHorizontal
local CELL_H = 4 * Settings.sizeVertical
local CELLS_XZ = 16 // CELL_W
local CELLS_Y = Settings.height // CELL_H
local NX = CELLS_XZ + 1 -- lattice corners per horizontal axis
local NY = CELLS_Y + 1
local STRIDE_X = NX * NY
local STRIDE_Z = NY
Compiler.CELL_W, Compiler.CELL_H, Compiler.CELLS_XZ, Compiler.CELLS_Y, Compiler.NX, Compiler.NY = CELL_W, CELL_H, CELLS_XZ, CELLS_Y, NX, NY

local MEMO_LIMIT = 400000
local HEIGHT = Settings.height

local function rarity3D(v: number): number
	if v < -0.5 then
		return 0.75
	elseif v < 0 then
		return 1.0
	elseif v < 0.5 then
		return 1.5
	end
	return 2.0
end

local function rarity2D(v: number): number
	if v < -0.75 then
		return 0.5
	elseif v < -0.5 then
		return 0.75
	elseif v < 0.5 then
		return 1.0
	elseif v < 0.75 then
		return 2.0
	end
	return 3.0
end

local function sq(v: number): number
	return v * v
end

-- Direct children of a node (used for reachability analysis).
local function childrenOf(node: { any }, splines: { { any } }): { number }
	local t = node[1]
	if t == "add" or t == "mul" or t == "min" or t == "max" then
		return { node[2], node[3] }
	elseif t == "abs" or t == "square" or t == "cube" or t == "half_negative" or t == "quarter_negative" or t == "squeeze"
		or t == "interpolated" or t == "flat_cache" or t == "cache_2d" or t == "cache_once" or t == "cache_all_in_cell"
		or t == "clamp" then
		return { node[2] }
	elseif t == "shifted_noise" then
		return { node[5], node[6], node[7] }
	elseif t == "weird_scaled_sampler" then
		return { node[2] }
	elseif t == "range_choice" then
		return { node[2], node[5], node[6] }
	elseif t == "spline" then
		local out = {}
		local function walk(id: number)
			local sp = splines[id]
			table.insert(out, sp[1])
			for _, v in sp[3] do
				if type(v) == "table" then
					walk(v[1])
				end
			end
		end
		walk(node[2])
		return out
	end
	return {}
end

-- `rs` is a RandomState. Returns a Sampler whose closures are bound to the world seed.
function Compiler.compile(rs: any): Sampler
	local nodes, splines = Data.nodes :: { { any } }, Data.splines :: { { any } }
	local count = #nodes
	local state: State = { minX = 0, minZ = 0, minY = Settings.minY, qx0 = 0, qz0 = 0, inCorner = false }
	local fns: { Fn } = table.create(count)
	local lo: { number } = table.create(count, 0)
	local hi: { number } = table.create(count, 0)
	local kinds: { string } = table.create(count, "")
	local consts: { [number]: number } = {}
	local lattices: { [number]: { number } } = {}

	local buildSpline: (number) -> (Fn, number, number)

	buildSpline = function(id: number): (Fn, number, number)
		local sp = splines[id]
		local coord = fns[sp[1]]
		local locs: { number }, vals: { any }, ders: { number } = sp[2], sp[3], sp[4]
		local m = #locs
		local cv: { any } = table.create(m, false)
		local fv: { any } = table.create(m, false)
		local vLo: { number }, vHi: { number } = table.create(m, 0), table.create(m, 0)
		for k = 1, m do
			local v = vals[k]
			if type(v) == "number" then
				cv[k], vLo[k], vHi[k] = v, v, v
			else
				local f, l, h = buildSpline(v[1])
				fv[k], vLo[k], vHi[k] = f, l, h
			end
		end

		local fn: Fn = function(x, y, z)
			local f = coord(x, y, z)
			local a, b = 1, m + 1
			while a < b do
				local mid = (a + b) // 2
				if f < locs[mid] then
					b = mid
				else
					a = mid + 1
				end
			end
			local i = a - 1 -- index of the last location <= f (0 if none)
			if i == 0 then
				local v = cv[1] or fv[1](x, y, z)
				local d = ders[1]
				if d == 0 then
					return v
				end
				return v + d * (f - locs[1])
			elseif i == m then
				local v = cv[m] or fv[m](x, y, z)
				local d = ders[m]
				if d == 0 then
					return v
				end
				return v + d * (f - locs[m])
			end
			local f1, f2 = locs[i], locs[i + 1]
			local t = (f - f1) / (f2 - f1)
			local v0 = cv[i] or fv[i](x, y, z)
			local v1 = cv[i + 1] or fv[i + 1](x, y, z)
			local w = f2 - f1
			local dv = v1 - v0
			local f8 = ders[i] * w - dv
			local f9 = -ders[i + 1] * w + dv
			return (v0 + t * (v1 - v0)) + t * (1 - t) * (f8 + t * (f9 - f8))
		end

		-- conservative value bounds
		local mn, mx = math.huge, -math.huge
		local cLo, cHi = lo[sp[1]], hi[sp[1]]
		for i = 1, m - 1 do
			local a0, b0, a1, b1 = vLo[i], vHi[i], vLo[i + 1], vHi[i + 1]
			local w = locs[i + 1] - locs[i]
			local s = max(b0, b1) - min(a0, a1)
			local ov = 0.25 * (max(abs(ders[i]), abs(ders[i + 1])) * w + s)
			mn = min(mn, min(a0, a1) - ov)
			mx = max(mx, max(b0, b1) + ov)
		end
		if m >= 1 then
			mn, mx = min(mn, vLo[1]), max(mx, vHi[1])
			mn, mx = min(mn, vLo[m]), max(mx, vHi[m])
			if cLo < locs[1] then
				local e = ders[1] * (cLo - locs[1])
				mn, mx = min(mn, vLo[1] + min(0, e)), max(mx, vHi[1] + max(0, e))
			end
			if cHi > locs[m] then
				local e = ders[m] * (cHi - locs[m])
				mn, mx = min(mn, vLo[m] + min(0, e)), max(mx, vHi[m] + max(0, e))
			end
		end
		return fn, mn, mx
	end

	for i = 1, count do
		local node = nodes[i]
		local t: string = node[1]
		kinds[i] = t
		local fn: Fn
		local l, h = -math.huge, math.huge

		if t == "const" then
			local v: number = node[2]
			consts[i] = v
			fn = function()
				return v
			end
			l, h = v, v
		elseif t == "add" then
			local na, nb = node[2], node[3]
			local a, b = fns[na], fns[nb]
			local cb = consts[nb]
			if cb then
				fn = function(x, y, z)
					return a(x, y, z) + cb
				end
			else
				fn = function(x, y, z)
					return a(x, y, z) + b(x, y, z)
				end
			end
			l, h = lo[na] + lo[nb], hi[na] + hi[nb]
		elseif t == "mul" then
			local na, nb = node[2], node[3]
			local a, b = fns[na], fns[nb]
			local cb = consts[nb]
			if cb then
				fn = function(x, y, z)
					return a(x, y, z) * cb
				end
				local p, q = lo[na] * cb, hi[na] * cb
				l, h = min(p, q), max(p, q)
			else
				fn = function(x, y, z)
					local d = a(x, y, z)
					if d == 0 then
						return 0
					end
					return d * b(x, y, z)
				end
				local p1, p2, p3, p4 = lo[na] * lo[nb], lo[na] * hi[nb], hi[na] * lo[nb], hi[na] * hi[nb]
				l, h = min(p1, p2, p3, p4), max(p1, p2, p3, p4)
			end
		elseif t == "min" then
			local na, nb = node[2], node[3]
			local a, b = fns[na], fns[nb]
			local threshold = lo[nb]
			local cb = consts[nb]
			if cb then
				fn = function(x, y, z)
					local d = a(x, y, z)
					return d < cb and d or cb
				end
			else
				fn = function(x, y, z)
					local d = a(x, y, z)
					if d < threshold then
						return d
					end
					local e = b(x, y, z)
					return d < e and d or e
				end
			end
			l, h = min(lo[na], lo[nb]), min(hi[na], hi[nb])
		elseif t == "max" then
			local na, nb = node[2], node[3]
			local a, b = fns[na], fns[nb]
			local threshold = hi[nb]
			local cb = consts[nb]
			if cb then
				fn = function(x, y, z)
					local d = a(x, y, z)
					return d > cb and d or cb
				end
			else
				fn = function(x, y, z)
					local d = a(x, y, z)
					if d > threshold then
						return d
					end
					local e = b(x, y, z)
					return d > e and d or e
				end
			end
			l, h = max(lo[na], lo[nb]), max(hi[na], hi[nb])
		elseif t == "abs" then
			local na = node[2]
			local a = fns[na]
			fn = function(x, y, z)
				local v = a(x, y, z)
				return v < 0 and -v or v
			end
			if lo[na] >= 0 then
				l, h = lo[na], hi[na]
			elseif hi[na] <= 0 then
				l, h = -hi[na], -lo[na]
			else
				l, h = 0, max(-lo[na], hi[na])
			end
		elseif t == "square" then
			local na = node[2]
			local a = fns[na]
			fn = function(x, y, z)
				local v = a(x, y, z)
				return v * v
			end
			if lo[na] >= 0 then
				l, h = sq(lo[na]), sq(hi[na])
			elseif hi[na] <= 0 then
				l, h = sq(hi[na]), sq(lo[na])
			else
				l, h = 0, max(sq(lo[na]), sq(hi[na]))
			end
		elseif t == "cube" then
			local na = node[2]
			local a = fns[na]
			fn = function(x, y, z)
				local v = a(x, y, z)
				return v * v * v
			end
			l, h = lo[na] ^ 3, hi[na] ^ 3
			if lo[na] < 0 then
				l = -((-lo[na]) ^ 3)
			end
			if hi[na] < 0 then
				h = -((-hi[na]) ^ 3)
			end
		elseif t == "half_negative" or t == "quarter_negative" then
			local na = node[2]
			local a = fns[na]
			local k = (t == "half_negative") and 0.5 or 0.25
			fn = function(x, y, z)
				local v = a(x, y, z)
				return v > 0 and v or v * k
			end
			l = lo[na] > 0 and lo[na] or lo[na] * k
			h = hi[na] > 0 and hi[na] or hi[na] * k
		elseif t == "squeeze" then
			local na = node[2]
			local a = fns[na]
			fn = function(x, y, z)
				local v = a(x, y, z)
				local c = v < -1 and -1 or (v > 1 and 1 or v)
				return c / 2 - c * c * c / 24
			end
			local function f(v: number): number
				local c = v < -1 and -1 or (v > 1 and 1 or v)
				return c / 2 - c * c * c / 24
			end
			l, h = f(lo[na]), f(hi[na])
		elseif t == "clamp" then
			local na, mn, mx = node[2], node[3], node[4]
			local a = fns[na]
			fn = function(x, y, z)
				local v = a(x, y, z)
				if v < mn then
					return mn
				end
				return v < mx and v or mx
			end
			l, h = max(mn, min(mx, lo[na])), max(mn, min(mx, hi[na]))
		elseif t == "y_clamped_gradient" then
			local fromY, toY, fromV, toV = node[2], node[3], node[4], node[5]
			local span = toY - fromY
			fn = function(_, y)
				local tt = (y - fromY) / span
				if tt < 0 then
					return fromV
				elseif tt > 1 then
					return toV
				end
				return fromV + tt * (toV - fromV)
			end
			l, h = min(fromV, toV), max(fromV, toV)
		elseif t == "noise" then
			local nz = rs:getNoise(node[2])
			local xz, ys = node[3], node[4]
			if ys == 0 then
				fn = function(x, _, z)
					return nz:getValue(x * xz, 0, z * xz)
				end
			else
				fn = function(x, y, z)
					return nz:getValue(x * xz, y * ys, z * xz)
				end
			end
			l, h = -nz.maxValue, nz.maxValue
		elseif t == "shifted_noise" then
			local nz = rs:getNoise(node[2])
			local xz, ys = node[3], node[4]
			local sx, sy, sz = fns[node[5]], fns[node[6]], fns[node[7]]
			fn = function(x, y, z)
				return nz:getValue(x * xz + sx(x, y, z), y * ys + sy(x, y, z), z * xz + sz(x, y, z))
			end
			l, h = -nz.maxValue, nz.maxValue
		elseif t == "shift_a" then
			local nz = rs:getNoise(node[2])
			fn = function(x, _, z)
				return nz:getValue(x * 0.25, 0, z * 0.25) * 4
			end
			l, h = -nz.maxValue * 4, nz.maxValue * 4
		elseif t == "shift_b" then
			local nz = rs:getNoise(node[2])
			fn = function(x, _, z)
				return nz:getValue(z * 0.25, x * 0.25, 0) * 4
			end
			l, h = -nz.maxValue * 4, nz.maxValue * 4
		elseif t == "shift" then
			local nz = rs:getNoise(node[2])
			fn = function(x, y, z)
				return nz:getValue(x * 0.25, y * 0.25, z * 0.25) * 4
			end
			l, h = -nz.maxValue * 4, nz.maxValue * 4
		elseif t == "weird_scaled_sampler" then
			local a = fns[node[2]]
			local nz = rs:getNoise(node[3])
			local mapper = node[4] == "type_1" and rarity3D or rarity2D
			fn = function(x, y, z)
				local r = mapper(a(x, y, z))
				return r * abs(nz:getValue(x / r, y / r, z / r))
			end
			l, h = 0, (node[4] == "type_1" and 2.0 or 3.0) * nz.maxValue
		elseif t == "old_blended_noise" then
			local bn = rs:getBlended(node[2], node[3], node[4], node[5], node[6])
			fn = function(x, y, z)
				return bn:compute(x, y, z)
			end
			l, h = -bn.maxValue, bn.maxValue
		elseif t == "range_choice" then
			local na, mn, mx, nin, nout = node[2], node[3], node[4], node[5], node[6]
			local a, fin, fout = fns[na], fns[nin], fns[nout]
			fn = function(x, y, z)
				local d = a(x, y, z)
				if d >= mn and d < mx then
					return fin(x, y, z)
				end
				return fout(x, y, z)
			end
			l, h = min(lo[nin], lo[nout]), max(hi[nin], hi[nout])
		elseif t == "spline" then
			local f, sl, sh = buildSpline(node[2])
			fn, l, h = f, sl, sh
		elseif t == "cache_all_in_cell" then
			local na = node[2]
			fn = fns[na]
			l, h = lo[na], hi[na]
		elseif t == "cache_2d" then
			local na = node[2]
			local a = fns[na]
			local lastX, lastZ, lastV = math.huge, math.huge, 0
			fn = function(x, y, z)
				if x == lastX and z == lastZ then
					return lastV
				end
				local v = a(x, y, z)
				lastX, lastZ, lastV = x, z, v
				return v
			end
			l, h = lo[na], hi[na]
		elseif t == "cache_once" then
			local na = node[2]
			local a = fns[na]
			local lx, ly, lz, lc, lv = math.huge, 0, 0, false, 0
			fn = function(x, y, z)
				local c = state.inCorner
				if x == lx and y == ly and z == lz and c == lc then
					return lv
				end
				local v = a(x, y, z)
				lx, ly, lz, lc, lv = x, y, z, c, v
				return v
			end
			l, h = lo[na], hi[na]
		elseif t == "flat_cache" then
			local na = node[2]
			local a = fns[na]
			local memo: { [number]: number } = {}
			local size = 0
			fn = function(x, y, z)
				local qx, qz = floor(x * 0.25), floor(z * 0.25)
				local ix, iz = qx - state.qx0, qz - state.qz0
				if ix >= 0 and ix <= CELLS_XZ and iz >= 0 and iz <= CELLS_XZ then
					local key = (qx + 4194304) * 8388608 + (qz + 4194304)
					local v = memo[key]
					if v == nil then
						v = a(qx * 4, 0, qz * 4)
						if size > MEMO_LIMIT then
							table.clear(memo)
							size = 0
						end
						memo[key] = v
						size += 1
					end
					return v :: number
				end
				return a(x, y, z)
			end
			l, h = lo[na], hi[na]
		elseif t == "interpolated" then
			local na = node[2]
			local a = fns[na]
			local lat = table.create(NX * NX * NY, 0)
			lattices[i] = lat
			fn = function(x, y, z)
				if state.inCorner then
					return a(x, y, z)
				end
				local lx, lz, ly = x - state.minX, z - state.minZ, y - state.minY
				if lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or ly < 0 or ly >= HEIGHT then
					return a(x, y, z)
				end
				local cx, cz, cy = lx // CELL_W, lz // CELL_W, ly // CELL_H
				local fx = (lx - cx * CELL_W) / CELL_W
				local fz = (lz - cz * CELL_W) / CELL_W
				local fy = (ly - cy * CELL_H) / CELL_H
				local base = cx * STRIDE_X + cz * STRIDE_Z + cy + 1
				local n000, n010 = lat[base], lat[base + 1]
				local n001, n011 = lat[base + STRIDE_Z], lat[base + STRIDE_Z + 1]
				local n100, n110 = lat[base + STRIDE_X], lat[base + STRIDE_X + 1]
				local n101, n111 = lat[base + STRIDE_X + STRIDE_Z], lat[base + STRIDE_X + STRIDE_Z + 1]
				local v00 = n000 + fy * (n010 - n000)
				local v10 = n100 + fy * (n110 - n100)
				local v01 = n001 + fy * (n011 - n001)
				local v11 = n101 + fy * (n111 - n101)
				local z0 = v00 + fx * (v10 - v00)
				local z1 = v01 + fx * (v11 - v01)
				return z0 + fz * (z1 - z0)
			end
			l, h = lo[na], hi[na]
		else
			error("unsupported density function node: " .. tostring(t))
		end

		fns[i], lo[i], hi[i] = fn, l, h
	end

	return {
		fns = fns,
		lo = lo,
		hi = hi,
		kinds = kinds,
		nodes = nodes,
		router = Data.router :: { [string]: number },
		lattices = lattices,
		state = state,
		rs = rs,
	}
end

-- Interpolated nodes reachable from `rootId` at block level (not through another `interpolated`).
function Compiler.blockInterpolators(sampler: Sampler, rootIds: { number }): { number }
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	local function visit(id: number)
		if seen[id] then
			return
		end
		seen[id] = true
		local node = sampler.nodes[id]
		if node[1] == "interpolated" then
			table.insert(out, id)
			return
		end
		for _, c in childrenOf(node, Data.splines :: any) do
			visit(c)
		end
	end
	for _, r in rootIds do
		visit(r)
	end
	table.sort(out)
	return out
end

-- Points the sampler at a chunk (block coordinates of its minimum corner).
function Compiler.setChunk(sampler: Sampler, minX: number, minZ: number)
	local s = sampler.state
	s.minX, s.minZ = minX, minZ
	s.qx0, s.qz0 = minX // 4, minZ // 4
end

-- Evaluates every listed interpolated node at all cell corners of the active chunk.
function Compiler.fillLattices(sampler: Sampler, ids: { number })
	local s = sampler.state
	s.inCorner = true
	for _, id in ids do
		local wrapped = sampler.fns[sampler.nodes[id][2]]
		local lat = sampler.lattices[id]
		for ix = 0, NX - 1 do
			local x = s.minX + ix * CELL_W
			for iz = 0, NX - 1 do
				local z = s.minZ + iz * CELL_W
				local base = ix * STRIDE_X + iz * STRIDE_Z
				for iy = 0, NY - 1 do
					lat[base + iy + 1] = wrapped(x, s.minY + iy * CELL_H, z)
				end
			end
		end
	end
	s.inCorner = false
end

-- Runs `f` with `interpolated` nodes evaluated directly (no lattice); for queries outside chunk generation.
function Compiler.direct<T>(sampler: Sampler, f: () -> T): T
	local s = sampler.state
	local prev = s.inCorner
	s.inCorner = true
	local r = f()
	s.inCorner = prev
	return r
end

-- Conservative [lo, hi] of node `id` over every block of lattice cell (cx, cz, cy) of the active chunk.
function Compiler.cellInterval(sampler: Sampler, id: number, cx: number, cz: number, cy: number): (number, number)
	local node = sampler.nodes[id]
	local t = node[1]
	local lo, hi = sampler.lo, sampler.hi
	if t == "interpolated" then
		local lat = sampler.lattices[id]
		local base = cx * STRIDE_X + cz * STRIDE_Z + cy + 1
		local a, b, c, d = lat[base], lat[base + 1], lat[base + STRIDE_Z], lat[base + STRIDE_Z + 1]
		local e, f, g, h = lat[base + STRIDE_X], lat[base + STRIDE_X + 1], lat[base + STRIDE_X + STRIDE_Z], lat[base + STRIDE_X + STRIDE_Z + 1]
		return min(a, b, c, d, e, f, g, h), max(a, b, c, d, e, f, g, h)
	elseif t == "const" then
		return node[2], node[2]
	elseif t == "add" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local l2, h2 = Compiler.cellInterval(sampler, node[3], cx, cz, cy)
		return l1 + l2, h1 + h2
	elseif t == "mul" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local l2, h2 = Compiler.cellInterval(sampler, node[3], cx, cz, cy)
		local p1, p2, p3, p4 = l1 * l2, l1 * h2, h1 * l2, h1 * h2
		return min(p1, p2, p3, p4), max(p1, p2, p3, p4)
	elseif t == "min" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local l2, h2 = Compiler.cellInterval(sampler, node[3], cx, cz, cy)
		return min(l1, l2), min(h1, h2)
	elseif t == "max" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local l2, h2 = Compiler.cellInterval(sampler, node[3], cx, cz, cy)
		return max(l1, l2), max(h1, h2)
	elseif t == "squeeze" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local function f(v: number): number
			local c = v < -1 and -1 or (v > 1 and 1 or v)
			return c / 2 - c * c * c / 24
		end
		return f(l1), f(h1)
	elseif t == "abs" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		if l1 >= 0 then
			return l1, h1
		elseif h1 <= 0 then
			return -h1, -l1
		end
		return 0, max(-l1, h1)
	elseif t == "clamp" then
		local l1, h1 = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		return max(node[3], min(node[4], l1)), max(node[3], min(node[4], h1))
	elseif t == "y_clamped_gradient" then
		local y0 = sampler.state.minY + cy * CELL_H
		local y1 = y0 + CELL_H - 1
		local fromY, toY, fromV, toV = node[2], node[3], node[4], node[5]
		local function f(y: number): number
			local tt = (y - fromY) / (toY - fromY)
			if tt < 0 then
				return fromV
			elseif tt > 1 then
				return toV
			end
			return fromV + tt * (toV - fromV)
		end
		local a, b = f(y0), f(y1)
		return min(a, b), max(a, b)
	elseif t == "range_choice" then
		local il, ih = Compiler.cellInterval(sampler, node[2], cx, cz, cy)
		local mn, mx = node[3], node[4]
		if il >= mn and ih < mx then
			return Compiler.cellInterval(sampler, node[5], cx, cz, cy)
		elseif ih < mn or il >= mx then
			return Compiler.cellInterval(sampler, node[6], cx, cz, cy)
		end
		local l1, h1 = Compiler.cellInterval(sampler, node[5], cx, cz, cy)
		local l2, h2 = Compiler.cellInterval(sampler, node[6], cx, cz, cy)
		return min(l1, l2), max(h1, h2)
	end
	return lo[id], hi[id]
end

return Compiler
