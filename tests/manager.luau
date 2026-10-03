local ChunkManager = require(TG.Streaming.ChunkManager)
local LockRegistry = require(TG.Streaming.LockRegistry)

local function key(cx, cz) return cx .. "," .. cz end

-- Fake world + async workers: dispatched jobs complete after a random number of ticks.
local function newHarness(opts, seed)
	math.randomseed(seed or 1)
	opts.playerGrace = opts.playerGrace or math.huge -- the real layer refreshes positions every tick
	local H = { world = {}, pending = {}, tick = 0, dispatched = {}, unloads = 0, loads = 0, violations = {}, fakeNow = 0 }
	H.mgr = ChunkManager.new(opts, {
		dispatch = function(cx, cz, jobId)
			H.dispatched[key(cx, cz)] = (H.dispatched[key(cx, cz)] or 0) + 1
			table.insert(H.pending, { cx = cx, cz = cz, job = jobId, at = H.tick + math.random(1, opts.maxDelay or 4) })
		end,
		unload = function(cx, cz)
			H.unloads += 1
			if not H.world[key(cx, cz)] then table.insert(H.violations, "unload of a chunk that is not in the world " .. key(cx, cz)) end
			-- the multiplayer safety property: never unload a chunk a live source still wants
			for id, s in H.mgr.sources do
				local r, rz = s.radius, s.radiusZ
				if cx >= s.cx - r and cx <= s.cx + r - 1 and cz >= s.cz - rz and cz <= s.cz + rz - 1 then
					table.insert(H.violations, string.format("unloaded %s while source %s wants it", key(cx, cz), id))
				end
			end
			if H.mgr.locked[LockRegistry.key(cx, cz)] then
				table.insert(H.violations, string.format("unloaded %s while it is locked", key(cx, cz)))
			end
			H.world[key(cx, cz)] = nil
		end,
		onLoaded = function() H.loads += 1 end,
		now = function() return H.fakeNow end,
	})
	function H.step()
		H.tick += 1
		H.fakeNow += 0.25
		local still = {}
		table.sort(H.pending, function(a, b) return a.job < b.job end)
		local done = {}
		for _, p in H.pending do
			if p.at <= H.tick then table.insert(done, p) else table.insert(still, p) end
		end
		-- complete in random order
		for i = #done, 2, -1 do local j = math.random(i); done[i], done[j] = done[j], done[i] end
		H.pending = still
		for _, p in done do
			H.world[key(p.cx, p.cz)] = true -- worker wrote it
			H.mgr:onDone(p.job, p.cx, p.cz, true)
		end
		H.mgr:update()
	end
	function H.settle(maxTicks)
		for _ = 1, maxTicks or 400 do H.step() end
	end
	return H
end

local function loadedSet(H) local n = 0 for _ in H.world do n += 1 end return n end
local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end

-- 1. single player: full window loads, nearest first
do
	local H = newHarness({ radius = 4, margin = 1, maxInFlight = 6 })
	local order = {}
	local origDispatch = H.mgr.cb.dispatch
	H.mgr.cb.dispatch = function(cx, cz, job) table.insert(order, { cx, cz }) origDispatch(cx, cz, job) end
	H.mgr:setPlayer("a", 10, -5)
	H.mgr:update()
	H.settle(100)
	check(loadedSet(H) == 64, "8x8 window should load exactly 64 chunks, got " .. loadedSet(H))
	-- the first dispatched chunks are the nearest ones
	local d0 = (order[1][1] - 10) ^ 2 + (order[1][2] + 5) ^ 2
	check(d0 <= 2, "first dispatch should be adjacent to the player")
	check(#H.violations == 0, table.concat(H.violations, "; "))
	print("1. single player window: ok (64 chunks, nearest-first)")
end

-- 2. two overlapping players: leaving one does not unload shared chunks
do
	local H = newHarness({ radius = 4, margin = 0, maxInFlight = 6 })
	H.mgr:setPlayer("a", 0, 0); H.mgr:setPlayer("b", 3, 0)
	H.mgr:update(); H.settle(100)
	local before = loadedSet(H)
	H.mgr:removePlayer("b")
	H.settle(50)
	-- b's exclusive chunks are gone; everything within a's window remains
	for x = -4, 3 do for z = -4, 3 do check(H.world[key(x, z)], "chunk in remaining player's window was unloaded " .. key(x, z)) end end
	check(loadedSet(H) == 64, "only the 64 chunks of player a should remain, have " .. loadedSet(H))
	check(#H.violations == 0, table.concat(H.violations, "; "))
	print("2. overlapping players: ok (" .. before .. " -> 64 after one leaves)")
end

-- 3. teleport far away: old window unloads, no duplicate loads for retained chunks
do
	local H = newHarness({ radius = 3, margin = 1, maxInFlight = 4, maxDelay = 6 })
	H.mgr:setPlayer("a", 0, 0); H.mgr:update(); H.settle(12) -- part way loaded
	H.mgr:setPlayer("a", 1000, 1000)
	H.settle(200)
	check(loadedSet(H) == 36, "teleported window should have 36 chunks, has " .. loadedSet(H))
	for x = -3, 2 do for z = -3, 2 do check(not H.world[key(x, z)], "old chunk left behind " .. key(x, z)) end end
	check(#H.violations == 0, table.concat(H.violations, "; "))
	local st = H.mgr:stats()
	check(st.loaded == 36 and st.queued == 0 and st.inflight == 0, "stats inconsistent")
	print("3. teleport: ok (cancelled in-flight chunks cleaned up)")
end

-- 4. cancelled in-flight chunk that becomes wanted again is kept (no reload)
do
	local H = newHarness({ radius = 2, margin = 0, maxInFlight = 4, maxDelay = 8 })
	H.mgr:setPlayer("a", 0, 0); H.mgr:update()
	H.step()
	H.mgr:setPlayer("a", 50, 50); H.mgr:update() -- everything in flight gets cancelled
	H.mgr:setPlayer("a", 0, 0); H.mgr:update()   -- ...and is wanted again
	H.settle(100)
	check(loadedSet(H) == 16, "window should be complete, has " .. loadedSet(H))
	for k, n in H.dispatched do check(n <= 2, "chunk " .. k .. " dispatched " .. n .. " times") end
	check(#H.violations == 0, table.concat(H.violations, "; "))
	print("4. cancel then re-want: ok")
end

-- 5. player grace: missing position keeps the window, then expires
do
	local H = newHarness({ radius = 2, margin = 0, maxInFlight = 8, playerGrace = 5 })
	H.mgr:setPlayer("a", 0, 0); H.mgr:update()
	for _ = 1, 30 do H.step(); H.mgr:setPlayer("a", 0, 0) end
	check(loadedSet(H) == 16, "loaded")
	for _ = 1, 10 do H.step(); H.mgr:touchPlayer("a") end -- 2.5 s of respawning: still kept
	check(loadedSet(H) == 16, "window dropped during grace")
	for _ = 1, 40 do H.step() end -- 10 s without any sign of the player
	check(loadedSet(H) == 0, "window should expire after the grace period")
	print("5. grace period: ok")
end

-- 6. anchor: initial area stays until released
do
	local H = newHarness({ radius = 2, margin = 0, maxInFlight = 8 })
	H.mgr:setAnchor("initial", 0, 0, 5); H.mgr:update(); H.settle(80)
	check(loadedSet(H) == 100, "anchor area (10x10) should be loaded, has " .. loadedSet(H))
	H.mgr:setPlayer("p", 30, 30); H.settle(80)
	check(H.world[key(-5, -5)] and H.world[key(4, 4)], "anchor chunks must persist while the anchor exists")
	H.mgr:removeAnchor("initial"); H.settle(80)
	check(loadedSet(H) == 16, "after releasing the anchor only the player's window remains")
	check(#H.violations == 0, table.concat(H.violations, "; "))
	print("6. anchor lifecycle: ok")
end

-- 6b. rectangular window
do
	local H = newHarness({ radius = 4, radiusZ = 2, margin = 0, maxInFlight = 8 })
	H.mgr:setPlayer("a", 0, 0); H.mgr:update(); H.settle(60)
	check(loadedSet(H) == 8 * 4, "rectangular 8x4 window expected, has " .. loadedSet(H))
	print("6b. rectangular window: ok")
end

-- 7. fuzz: 6 players random-walking / teleporting / joining / leaving with random async completion
do
	for seed = 1, 30 do
		local H = newHarness({ radius = 3, margin = 1, maxInFlight = 5, maxDelay = 5, playerGrace = 3 }, seed)
		local ids = { "p1", "p2", "p3", "p4", "p5", "p6" }
		local pos = {}
		for step = 1, 250 do
			for _, id in ids do
				local r = math.random()
				if r < 0.03 then
					H.mgr:removePlayer(id); pos[id] = nil
				elseif pos[id] == nil then
					if r < 0.2 then pos[id] = { math.random(-6, 6), math.random(-6, 6) } end
				else
					if r < 0.07 then pos[id] = { math.random(-40, 40), math.random(-40, 40) } -- teleport
					else pos[id][1] += math.random(-1, 1); pos[id][2] += math.random(-1, 1) end
				end
				if pos[id] then H.mgr:setPlayer(id, pos[id][1], pos[id][2]) end
			end
			H.step()
			-- invariant: world contents == manager's loaded chunks (+ inflight already written by workers)
		end
		-- settle with a stable population
		H.settle(60)
		check(#H.violations == 0, "seed " .. seed .. ": " .. table.concat(H.violations, "; "))
		-- everything wanted by a live source is loaded; nothing outside every keep-window is loaded
		local wantedAll = {}
		for _, s in H.mgr.sources do
			for x = s.cx - s.radius, s.cx + s.radius - 1 do for z = s.cz - s.radiusZ, s.cz + s.radiusZ - 1 do wantedAll[key(x, z)] = true end end
		end
		for k in wantedAll do check(H.world[k], "seed " .. seed .. ": wanted chunk missing " .. k) end
		for k in H.world do
			local x, z = string.match(k, "(-?%d+),(-?%d+)")
			x, z = tonumber(x), tonumber(z)
			local inKeep = false
			for _, s in H.mgr.sources do
				local r, rz = s.radius + H.mgr.margin, s.radiusZ + H.mgr.margin
				if x >= s.cx - r and x <= s.cx + r - 1 and z >= s.cz - rz and z <= s.cz + rz - 1 then inKeep = true end
			end
			check(inKeep, "seed " .. seed .. ": orphaned chunk " .. k)
		end
		local st = H.mgr:stats()
		check(st.loaded == loadedSet(H), "seed " .. seed .. ": manager count " .. st.loaded .. " vs world " .. loadedSet(H))
		check(st.inflight == 0 and st.queued == 0, "seed " .. seed .. ": jobs left over")
	end
	print("7. fuzz (30 seeds x 6 players x 250 steps, join/leave/teleport/random completion order): ok, no violations")
end

-- 8. locks: far-away locked chunks load, survive every player leaving, and release on unlock
do
	local H = newHarness({ radius = 2, margin = 1, maxInFlight = 4, maxDelay = 4 })
	local locks = LockRegistry.new(function() H.mgr:setLocked(H.locks:union()) end)
	H.locks = locks
	H.mgr:setPlayer("a", 0, 0); H.mgr:update()
	locks:lockArea(500, 500, 502, 501)         -- 3x2 chunks nobody is near
	locks:lockChunk(-300, 20, "scriptB")
	H.settle(120)
	for x = 500, 502 do for z = 500, 501 do check(H.world[key(x, z)], "locked far chunk not loaded " .. key(x, z)) end end
	check(H.world[key(-300, 20)], "locked chunk of another owner not loaded")
	check(loadedSet(H) == 16 + 6 + 1, "window + locks expected (23), have " .. loadedSet(H))
	-- the player leaves: only locks remain
	H.mgr:removePlayer("a"); H.settle(60)
	check(loadedSet(H) == 7, "after the player left, only the 7 locked chunks remain, have " .. loadedSet(H))
	-- two owners on one chunk: it stays until BOTH release
	locks:lockChunk(-300, 20, "scriptC")
	locks:unlockChunk(-300, 20, "scriptB"); H.settle(30)
	check(H.world[key(-300, 20)], "chunk unloaded while a second owner still locks it")
	locks:unlockChunk(-300, 20, "scriptC"); H.settle(30)
	check(not H.world[key(-300, 20)], "chunk should unload when the last lock is gone")
	check(not locks:isLocked(-300, 20) and locks:isLocked(501, 500), "isLocked wrong")
	locks:unlockAll(); H.settle(40)
	check(loadedSet(H) == 0, "unlockAll should release the default owner's chunks")
	check(#H.violations == 0, table.concat(H.violations, "; "))
	print("8. locks: ok (far chunks load, survive player leaving, owners independent, unlock releases)")
end

-- 9. lock encode/decode round trip, including negative coordinates and multi-part splitting
do
	local set = {}
	local n = 0
	math.randomseed(7)
	for _ = 1, 3000 do
		local x, z = math.random(-300, 300), math.random(-40, 40)
		if not set[LockRegistry.key(x, z)] then set[LockRegistry.key(x, z)] = true; n += 1 end
	end
	for x = -50, 50 do for z = -3, 3 do if not set[LockRegistry.key(x, z)] then set[LockRegistry.key(x, z)] = true; n += 1 end end end
	local parts = LockRegistry.encode(set)
	local back = LockRegistry.decode(parts)
	local m = 0
	for k in back do check(set[k], "decoded a chunk that was not locked") m += 1 end
	check(m == n, "decoded count differs: " .. m .. " vs " .. n)
	check(#LockRegistry.encode({}) == 0 and next(LockRegistry.decode({})) == nil, "empty set")
	print("9. lock encoding: ok (" .. n .. " chunks in " .. #parts .. " part(s), " .. #table.concat(parts) .. " chars)")
end

-- 10. fuzz with locks: random lock / unlock while players wander
do
	for seed = 1, 20 do
		local H = newHarness({ radius = 3, margin = 1, maxInFlight = 5, maxDelay = 5, playerGrace = 3 }, 100 + seed)
		H.locks = LockRegistry.new(function() H.mgr:setLocked(H.locks:union()) end)
		local pos = { p1 = { 0, 0 }, p2 = { 10, 10 } }
		local owners = { "a", "b", "c" }
		for step = 1, 250 do
			for id, p in pos do
				if math.random() < 0.05 then pos[id] = { math.random(-40, 40), math.random(-40, 40) } else p[1] += math.random(-1, 1); p[2] += math.random(-1, 1) end
				H.mgr:setPlayer(id, pos[id][1], pos[id][2])
			end
			local r = math.random()
			local o = owners[math.random(#owners)]
			local ax, az = math.random(-60, 60), math.random(-60, 60)
			if r < 0.10 then H.locks:lockArea(ax, az, ax + math.random(0, 3), az + math.random(0, 3), o)
			elseif r < 0.20 then H.locks:unlockArea(ax, az, ax + math.random(0, 5), az + math.random(0, 5), o)
			elseif r < 0.23 then H.locks:unlockAll(o) end
			H.step()
		end
		H.settle(400)
		check(#H.violations == 0, "seed " .. seed .. ": " .. table.concat(H.violations, "; "))
		for k in H.locks:union() do local cx, cz = LockRegistry.unkey(k); check(H.world[key(cx, cz)], "seed " .. seed .. ": locked chunk missing") end
		local st = H.mgr:stats()
		check(st.loaded == loadedSet(H) and st.inflight == 0 and st.queued == 0, "seed " .. seed .. ": inconsistent")
	end
	print("10. lock fuzz (20 seeds, owners lock/unlock rectangles while 2 players move): ok")
end
