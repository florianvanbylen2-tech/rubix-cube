--!strict
-- Chunk locks (pure logic). A locked chunk is kept loaded no matter how far away every player is, until it is
-- unlocked. Locks are held by named owners ("default" unless you pass one), so two scripts cannot unlock each
-- other's chunks: a chunk stays locked while ANY owner holds it.
--
-- The union of all locks can be encoded into compact strings (rows of chunk ranges) to replicate to clients.

local LockRegistry = {}
LockRegistry.__index = LockRegistry

local DEFAULT_OWNER = "default"
local MAX_PART = 50000 -- characters per encoded part (kept well below the attribute size limit)

function LockRegistry.key(cx: number, cz: number): number
	return (cx + 2097152) * 4194304 + (cz + 2097152)
end

function LockRegistry.unkey(k: number): (number, number)
	return math.floor(k / 4194304) - 2097152, k % 4194304 - 2097152
end

local key = LockRegistry.key

function LockRegistry.new(onChange: (() -> ())?)
	return setmetatable({
		owners = {} :: { [string]: { [number]: boolean } },
		counts = {} :: { [number]: number },
		total = 0,
		version = 0,
		onChange = onChange,
	}, LockRegistry)
end

local function changed(self: any)
	self.version += 1
	if self.onChange then
		self.onChange()
	end
end

local function add(self: any, owner: string, k: number): boolean
	local set = self.owners[owner]
	if not set then
		set = {}
		self.owners[owner] = set
	end
	if set[k] then
		return false
	end
	set[k] = true
	local n = self.counts[k]
	if n == nil then
		self.counts[k] = 1
		self.total += 1
	else
		self.counts[k] = n + 1
	end
	return true
end

local function remove(self: any, owner: string, k: number): boolean
	local set = self.owners[owner]
	if not set or not set[k] then
		return false
	end
	set[k] = nil
	local n = self.counts[k] - 1
	if n <= 0 then
		self.counts[k] = nil
		self.total -= 1
	else
		self.counts[k] = n
	end
	return true
end

-- Locks the inclusive chunk rectangle. Returns how many chunks became newly locked for this owner.
function LockRegistry.lockArea(self: any, cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
	local o = owner or DEFAULT_OWNER
	local n = 0
	for x = math.min(cx0, cx1), math.max(cx0, cx1) do
		for z = math.min(cz0, cz1), math.max(cz0, cz1) do
			if add(self, o, key(x, z)) then
				n += 1
			end
		end
	end
	if n > 0 then
		changed(self)
	end
	return n
end

function LockRegistry.lockChunk(self: any, cx: number, cz: number, owner: string?): boolean
	return LockRegistry.lockArea(self, cx, cz, cx, cz, owner) > 0
end

function LockRegistry.unlockArea(self: any, cx0: number, cz0: number, cx1: number, cz1: number, owner: string?): number
	local o = owner or DEFAULT_OWNER
	local n = 0
	for x = math.min(cx0, cx1), math.max(cx0, cx1) do
		for z = math.min(cz0, cz1), math.max(cz0, cz1) do
			if remove(self, o, key(x, z)) then
				n += 1
			end
		end
	end
	if n > 0 then
		changed(self)
	end
	return n
end

function LockRegistry.unlockChunk(self: any, cx: number, cz: number, owner: string?): boolean
	return LockRegistry.unlockArea(self, cx, cz, cx, cz, owner) > 0
end

-- Releases every lock of one owner (owner nil = the default owner). Returns how many it held.
function LockRegistry.unlockAll(self: any, owner: string?): number
	local o = owner or DEFAULT_OWNER
	local set = self.owners[o]
	if not set then
		return 0
	end
	local n = 0
	for k in table.clone(set) do
		if remove(self, o, k) then
			n += 1
		end
	end
	self.owners[o] = nil
	if n > 0 then
		changed(self)
	end
	return n
end

-- Is the chunk locked (by `owner`, or by anybody when owner is nil)?
function LockRegistry.isLocked(self: any, cx: number, cz: number, owner: string?): boolean
	local k = key(cx, cz)
	if owner then
		local set = self.owners[owner]
		return set ~= nil and set[k] == true
	end
	return self.counts[k] ~= nil
end

function LockRegistry.count(self: any): number
	return self.total
end

-- The union of all locks as a set keyed by LockRegistry.key. Do not modify the result.
function LockRegistry.union(self: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for k in self.counts do
		out[k] = true
	end
	return out
end

-- List of { cx, cz } for one owner or everybody (sorted), for listing locks in user code.
function LockRegistry.list(self: any, owner: string?): { { number } }
	local keys: { number } = {}
	if owner then
		for k in self.owners[owner] or {} do
			table.insert(keys, k)
		end
	else
		for k in self.counts do
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		local x, z = LockRegistry.unkey(k)
		table.insert(out, { x, z })
	end
	return out
end

-- ---------------------------------------------------------------------------------------- replication format
-- Rows of ranges: "z,x0,x1;z,x0,x1;..." (z ascending, x ascending), split into parts of at most MAX_PART characters.
function LockRegistry.encode(set: { [number]: boolean }): { string }
	local rows: { [number]: { number } } = {}
	local zs: { number } = {}
	for k in set do
		local x, z = LockRegistry.unkey(k)
		local row = rows[z]
		if not row then
			row = {}
			rows[z] = row
			table.insert(zs, z)
		end
		table.insert(row, x)
	end
	table.sort(zs)
	local parts: { string } = {}
	local buf: { string } = {}
	local size = 0
	for _, z in zs do
		local xs = rows[z]
		table.sort(xs)
		local start, prev = xs[1], xs[1]
		local function flush(last: boolean)
			local entry = string.format("%d,%d,%d;", z, start, prev)
			if size + #entry > MAX_PART then
				table.insert(parts, table.concat(buf))
				buf, size = {}, 0
			end
			table.insert(buf, entry)
			size += #entry
		end
		for i = 2, #xs do
			if xs[i] == prev + 1 then
				prev = xs[i]
			else
				flush(false)
				start, prev = xs[i], xs[i]
			end
		end
		flush(true)
	end
	if #buf > 0 then
		table.insert(parts, table.concat(buf))
	end
	return parts
end

function LockRegistry.decode(parts: { string }): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for _, part in parts do
		for z, x0, x1 in string.gmatch(part, "(-?%d+),(-?%d+),(-?%d+);") do
			local zn, a, b = tonumber(z) :: number, tonumber(x0) :: number, tonumber(x1) :: number
			for x = a, b do
				out[key(x, zn)] = true
			end
		end
	end
	return out
end

return LockRegistry
