--!strict
-- Multiplayer-safe chunk streaming state machine (pure logic, no Roblox APIs).
--
-- Every tracked "source" (a player, or a named anchor such as the initial world area) wants a square window of
-- chunks loaded around it. A chunk is *wanted* while it lies inside the window of ANY source, and is only
-- unloaded once it has left the windows of ALL sources (plus a hysteresis margin), so players sharing an area
-- never unload terrain out from under each other, and a player leaving only frees what nobody else needs.
--
-- Locked chunks (setLocked) behave like an extra source that never moves: they are wanted and kept whatever the
-- distance to every player, and are never unloaded until the lock set no longer contains them.
--
-- Chunk lifecycle:  (none) -> queued -> inflight -> loaded -> (none)
--   * queued chunks that stop being needed are simply dropped;
--   * inflight chunks that stop being needed are flagged `cancelled` and unloaded as soon as they complete
--     (the worker cannot be interrupted), unless somebody wants them again in the meantime;
--   * results for chunks whose job id no longer matches (stale) are ignored.

export type Callbacks = {
	dispatch: (cx: number, cz: number, jobId: number) -> (), -- start generating + writing a chunk
	unload: (cx: number, cz: number) -> (), -- remove a loaded chunk from the world
	onLoaded: ((cx: number, cz: number) -> ())?,
	onUnloaded: ((cx: number, cz: number) -> ())?,
	onFailed: ((cx: number, cz: number, err: string) -> ())?,
	now: (() -> number)?,
}

export type Options = {
	radius: number, -- window covers chunks [c - radius, c + radius - 1] on each axis
	radiusZ: number?, -- optional different half-size along z (rectangular worlds)
	margin: number?, -- extra chunks kept loaded around every window (hysteresis), default 2
	maxInFlight: number?, -- concurrent generation jobs, default 8
	playerGrace: number?, -- seconds a player without a known position keeps its last window, default 30
	maxRetries: number?, -- default 3
}

type Chunk = {
	cx: number,
	cz: number,
	state: string, -- "queued" | "inflight" | "loaded"
	jobId: number?,
	cancelled: boolean?,
	retries: number,
	priority: number,
}

type Source = { cx: number, cz: number, radius: number, radiusZ: number, lastSeen: number, isPlayer: boolean }

local ChunkManager = {}
ChunkManager.__index = ChunkManager

local LOCK_PRIORITY = 1e9 -- locked chunks outside every window load after all windowed ones

local function key(cx: number, cz: number): number
	return (cx + 2097152) * 4194304 + (cz + 2097152)
end

function ChunkManager.new(options: Options, callbacks: Callbacks)
	local self = setmetatable({
		radius = options.radius,
		radiusZ = options.radiusZ or options.radius,
		margin = options.margin or 2,
		maxInFlight = options.maxInFlight or 8,
		playerGrace = options.playerGrace or 30,
		maxRetries = options.maxRetries or 3,
		cb = callbacks,
		chunks = {} :: { [number]: Chunk },
		sources = {} :: { [string]: Source },
		queue = {} :: { Chunk },
		queueDirty = false,
		inflight = 0,
		nextJob = 1,
		loaded = 0,
		dirty = true,
		failures = {} :: { [number]: number },
		locked = {} :: { [number]: boolean },
	}, ChunkManager)
	return self
end

local function now(self: any): number
	local f = self.cb.now
	return f and f() or os.clock()
end

-- Replaces the set of locked chunks (keys from LockRegistry.key). The table is read, never modified.
function ChunkManager.setLocked(self: any, set: { [number]: boolean })
	self.locked = set
	self.dirty = true
end

function ChunkManager.isLocked(self: any, cx: number, cz: number): boolean
	return self.locked[key(cx, cz)] == true
end

-- Sets/moves a player's window centre (chunk coordinates). `id` is any unique string (e.g. UserId).
function ChunkManager.setPlayer(self: any, id: string, cx: number, cz: number)
	local s = self.sources[id]
	if s == nil then
		self.sources[id] = { cx = cx, cz = cz, radius = self.radius, radiusZ = self.radiusZ, lastSeen = now(self), isPlayer = true }
		self.dirty = true
	else
		s.lastSeen = now(self)
		if s.cx ~= cx or s.cz ~= cz then
			s.cx, s.cz = cx, cz
			self.dirty = true
		end
	end
end

-- The player is still present but their position is momentarily unknown (respawning): keep the last window.
function ChunkManager.touchPlayer(self: any, id: string)
	local s = self.sources[id]
	if s then
		s.lastSeen = now(self)
	end
end

function ChunkManager.removePlayer(self: any, id: string)
	if self.sources[id] then
		self.sources[id] = nil
		self.dirty = true
	end
end

-- A fixed window that stays until removed (e.g. the initial world area). Radius defaults to the player radius.
function ChunkManager.setAnchor(self: any, name: string, cx: number, cz: number, radius: number?, radiusZ: number?)
	self.sources["anchor:" .. name] = {
		cx = cx, cz = cz, radius = radius or self.radius, radiusZ = radiusZ or radius or self.radiusZ, lastSeen = math.huge, isPlayer = false,
	}
	self.dirty = true
end

function ChunkManager.removeAnchor(self: any, name: string)
	if self.sources["anchor:" .. name] then
		self.sources["anchor:" .. name] = nil
		self.dirty = true
	end
end

function ChunkManager.isLoaded(self: any, cx: number, cz: number): boolean
	local c = self.chunks[key(cx, cz)]
	return c ~= nil and c.state == "loaded" and not c.cancelled
end

-- Number of loaded chunks inside the square [cx - r, cx + r - 1] x [cz - r, cz + r - 1], and its total size.
function ChunkManager.loadedInBox(self: any, cx: number, cz: number, r: number): (number, number)
	local n = 0
	for x = cx - r, cx + r - 1 do
		for z = cz - r, cz + r - 1 do
			if ChunkManager.isLoaded(self, x, z) then
				n += 1
			end
		end
	end
	return n, (2 * r) * (2 * r)
end

-- Forgets recorded failures so failed chunks are retried on the next update.
function ChunkManager.retryFailed(self: any)
	self.failures = {}
	self.dirty = true
end

function ChunkManager.stats(self: any): { loaded: number, queued: number, inflight: number, sources: number, locked: number }
	local n = 0
	for _ in self.sources do
		n += 1
	end
	local l = 0
	for _ in self.locked do
		l += 1
	end
	return { loaded = self.loaded, queued = #self.queue, inflight = self.inflight, sources = n, locked = l }
end

local function unloadChunk(self: any, c: Chunk)
	self.chunks[key(c.cx, c.cz)] = nil
	self.loaded -= 1
	self.cb.unload(c.cx, c.cz)
	if self.cb.onUnloaded then
		self.cb.onUnloaded(c.cx, c.cz)
	end
end

-- Recomputes wanted/keep sets, queues loads, drops or unloads chunks nobody needs, dispatches jobs.
function ChunkManager.update(self: any)
	-- expire players that have not been seen for a while
	local t = now(self)
	for id, s in self.sources do
		if s.isPlayer and t - s.lastSeen > self.playerGrace then
			self.sources[id] = nil
			self.dirty = true
		end
	end

	if self.dirty then
		self.dirty = false
		local wanted: { [number]: number } = {} -- key -> priority (squared distance to nearest source)
		local keep: { [number]: boolean } = {}
		local margin = self.margin
		for _, s in self.sources do
			local r, rz = s.radius, s.radiusZ
			for x = s.cx - r - margin, s.cx + r - 1 + margin do
				local dx = x - s.cx
				for z = s.cz - rz - margin, s.cz + rz - 1 + margin do
					local k = key(x, z)
					keep[k] = true
					if x >= s.cx - r and x <= s.cx + r - 1 and z >= s.cz - rz and z <= s.cz + rz - 1 then
						local dz = z - s.cz
						local d = dx * dx + dz * dz
						local prev = wanted[k]
						if prev == nil or d < prev then
							wanted[k] = d
						end
					end
				end
			end
		end

		-- locked chunks: always kept; wanted too, after everything the windows want
		for k in self.locked do
			keep[k] = true
			if wanted[k] == nil then
				wanted[k] = LOCK_PRIORITY
			end
		end

		-- unload / cancel what nobody keeps
		local drop: { Chunk } = {}
		for k, c in self.chunks do
			if not keep[k] then
				if c.state == "loaded" then
					table.insert(drop, c)
				elseif c.state == "queued" then
					self.chunks[k] = nil
					self.queueDirty = true
				else
					c.cancelled = true
				end
			else
				c.cancelled = nil
			end
		end
		for _, c in drop do
			unloadChunk(self, c)
		end
		if self.queueDirty then
			local q: { Chunk } = {}
			for _, c in self.queue do
				if self.chunks[key(c.cx, c.cz)] == c then
					table.insert(q, c)
				end
			end
			self.queue = q
			self.queueDirty = false
		end

		-- queue new loads, refresh priorities
		for k, d in wanted do
			local c = self.chunks[k]
			if c == nil then
				if (self.failures[k] or 0) >= self.maxRetries then
					continue -- gave up on this chunk (see onFailed)
				end
				local cx = math.floor(k / 4194304) - 2097152
				local cz = k % 4194304 - 2097152
				c = { cx = cx, cz = cz, state = "queued", retries = self.failures[k] or 0, priority = d }
				self.chunks[k] = c
				table.insert(self.queue, c)
			else
				c.priority = d
			end
		end
		table.sort(self.queue, function(a, b)
			if a.priority ~= b.priority then
				return a.priority < b.priority
			end
			if a.cx ~= b.cx then
				return a.cx < b.cx
			end
			return a.cz < b.cz
		end)
	end

	-- dispatch nearest-first while there is capacity
	local q = self.queue
	local head = 1
	while self.inflight < self.maxInFlight and head <= #q do
		local c = q[head]
		head += 1
		c.state = "inflight"
		c.jobId = self.nextJob
		self.nextJob += 1
		self.inflight += 1
		self.cb.dispatch(c.cx, c.cz, c.jobId :: number)
	end
	if head > 1 then
		local rest: { Chunk } = {}
		for i = head, #q do
			table.insert(rest, q[i])
		end
		self.queue = rest
	end
end

-- A worker finished a job. Stale results (job id mismatch) are ignored.
function ChunkManager.onDone(self: any, jobId: number, cx: number, cz: number, ok: boolean, err: string?)
	local k = key(cx, cz)
	local c = self.chunks[k]
	if c == nil or c.jobId ~= jobId or c.state ~= "inflight" then
		return
	end
	self.inflight -= 1
	if ok then
		c.state = "loaded"
		c.jobId = nil
		self.loaded += 1
		self.failures[k] = nil
		if c.cancelled and not self.dirty then
			unloadChunk(self, c)
		else
			-- if source positions changed since the chunk was flagged, the flag may be stale: leave the decision
			-- to the next update(), which recomputes what is needed and unloads the chunk if nobody wants it
			c.cancelled = nil
			if self.cb.onLoaded then
				self.cb.onLoaded(cx, cz)
			end
		end
	else
		self.chunks[k] = nil
		local n = (self.failures[k] or 0) + 1
		self.failures[k] = n
		if self.cb.onFailed then
			self.cb.onFailed(cx, cz, err or "unknown error")
		end
		if n < self.maxRetries and not c.cancelled then
			self.dirty = true -- next update re-queues it if it is still wanted
		end
	end
end

return ChunkManager
