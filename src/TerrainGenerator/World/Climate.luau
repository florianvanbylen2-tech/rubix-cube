--!strict
--!native
-- Climate.ParameterPoint + the nearest-parameter search used by MultiNoiseBiomeSource.
-- Vanilla stores the points in an R-tree; we use a bounding-volume tree over the same 7 dimensions
-- with the same fitness (sum of squared per-dimension interval distances), so the winner is the same
-- everywhere except on exact ties.

local floor = math.floor

local BUF = buffer.create(4)
local function f32(x: number): number
	buffer.writef32(BUF, 0, x)
	return buffer.readf32(BUF, 0)
end

-- Climate.quantizeCoord: (long)(coord * 10000.0F) with float32 arithmetic
local function quantize(v: number): number
	local p = f32(f32(v) * 10000)
	if p >= 0 then
		return floor(p)
	end
	return -floor(-p)
end

local DIMS = 7 -- temperature, humidity, continentalness, erosion, depth, weirdness, offset

export type Point = {
	lo: { number }, -- 7 quantised minima
	hi: { number }, -- 7 quantised maxima
	value: any,
}

type Node = {
	lo: { number },
	hi: { number },
	children: { Node }?,
	points: { Point }?,
}

local Climate = {}
Climate.f32 = f32
Climate.quantize = quantize

-- A quantised [min, max] parameter range.
export type Param = { number }

function Climate.span(a: number | Param, b: number | Param?): Param
	local lo: number
	local hi: number
	if type(a) == "table" then
		lo = a[1]
		hi = (b :: Param)[2]
	else
		lo = quantize(a)
		hi = quantize((b :: number) :: number)
	end
	return { lo, hi }
end

function Climate.point(v: number): Param
	local q = quantize(v)
	return { q, q }
end

-- ranges: 6 Params (temperature, humidity, continentalness, erosion, depth, weirdness), offset already quantised
function Climate.newPoint(ranges: { Param }, offset: number, value: any): Point
	local lo, hi = table.create(DIMS, 0), table.create(DIMS, 0)
	for i = 1, 6 do
		lo[i], hi[i] = ranges[i][1], ranges[i][2]
	end
	local q = quantize(offset)
	lo[7], hi[7] = q, q
	return { lo = lo, hi = hi, value = value }
end

local LEAF_SIZE = 6

local function bounds(points: { Point }): ({ number }, { number })
	local lo, hi = table.create(DIMS, math.huge), table.create(DIMS, -math.huge)
	for _, p in points do
		for d = 1, DIMS do
			if p.lo[d] < lo[d] then
				lo[d] = p.lo[d]
			end
			if p.hi[d] > hi[d] then
				hi[d] = p.hi[d]
			end
		end
	end
	return lo, hi
end

local function build(points: { Point }): Node
	local lo, hi = bounds(points)
	if #points <= LEAF_SIZE then
		return { lo = lo, hi = hi, points = points }
	end
	-- split along the dimension where the point centres are most spread out
	local bestDim, bestSpread = 1, -1
	for d = 1, DIMS do
		local cmin, cmax = math.huge, -math.huge
		for _, p in points do
			local c = (p.lo[d] + p.hi[d]) * 0.5
			if c < cmin then
				cmin = c
			end
			if c > cmax then
				cmax = c
			end
		end
		if cmax - cmin > bestSpread then
			bestSpread, bestDim = cmax - cmin, d
		end
	end
	local sorted = table.clone(points)
	table.sort(sorted, function(a, b)
		local ca, cb = a.lo[bestDim] + a.hi[bestDim], b.lo[bestDim] + b.hi[bestDim]
		if ca ~= cb then
			return ca < cb
		end
		return a.lo[1] + a.lo[2] + a.lo[3] < b.lo[1] + b.lo[2] + b.lo[3]
	end)
	local mid = #sorted // 2
	local left, right = {}, {}
	for i = 1, #sorted do
		table.insert(i <= mid and left or right, sorted[i])
	end
	return { lo = lo, hi = hi, children = { build(left), build(right) } }
end

export type Tree = { root: Node, count: number }

function Climate.buildTree(points: { Point }): Tree
	return { root = build(points), count = #points }
end

-- squared distance from target to a [lo, hi] box in all 7 dims (target offset is always 0)
local function boxDistance(lo: { number }, hi: { number }, t1: number, t2: number, t3: number, t4: number, t5: number, t6: number): number
	local total = 0
	local d
	d = t1 > hi[1] and t1 - hi[1] or (t1 < lo[1] and lo[1] - t1 or 0)
	total += d * d
	d = t2 > hi[2] and t2 - hi[2] or (t2 < lo[2] and lo[2] - t2 or 0)
	total += d * d
	d = t3 > hi[3] and t3 - hi[3] or (t3 < lo[3] and lo[3] - t3 or 0)
	total += d * d
	d = t4 > hi[4] and t4 - hi[4] or (t4 < lo[4] and lo[4] - t4 or 0)
	total += d * d
	d = t5 > hi[5] and t5 - hi[5] or (t5 < lo[5] and lo[5] - t5 or 0)
	total += d * d
	d = t6 > hi[6] and t6 - hi[6] or (t6 < lo[6] and lo[6] - t6 or 0)
	total += d * d
	d = 0 > hi[7] and -hi[7] or (0 < lo[7] and lo[7] or 0)
	return total + d * d
end

-- Finds the point with the smallest fitness for a quantised target. Returns its value and the fitness.
function Climate.search(tree: Tree, t1: number, t2: number, t3: number, t4: number, t5: number, t6: number): (any, number)
	local best = math.huge
	local bestPoint: Point? = nil
	local function visit(node: Node)
		local points = node.points
		if points then
			for i = 1, #points do
				local p = points[i]
				local dist = boxDistance(p.lo, p.hi, t1, t2, t3, t4, t5, t6)
				if dist < best then
					best, bestPoint = dist, p
				end
			end
			return
		end
		local kids = node.children :: { Node }
		local a, b = kids[1], kids[2]
		local da = boxDistance(a.lo, a.hi, t1, t2, t3, t4, t5, t6)
		local db = boxDistance(b.lo, b.hi, t1, t2, t3, t4, t5, t6)
		if da <= db then
			if da < best then
				visit(a)
			end
			if db < best then
				visit(b)
			end
		else
			if db < best then
				visit(b)
			end
			if da < best then
				visit(a)
			end
		end
	end
	visit(tree.root)
	return (bestPoint :: Point).value, best
end

-- Reference implementation used by tests: linear scan.
function Climate.searchLinear(points: { Point }, t1: number, t2: number, t3: number, t4: number, t5: number, t6: number): (any, number)
	local best, bv = math.huge, nil
	for _, p in points do
		local dist = boxDistance(p.lo, p.hi, t1, t2, t3, t4, t5, t6)
		if dist < best then
			best, bv = dist, p.value
		end
	end
	return bv, best
end

Climate.boxDistance = boxDistance

return Climate
