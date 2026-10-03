--!strict
--!native
-- Feature stage: interprets the vanilla placed-feature JSON (placement modifiers + feature programs) for
-- the features that matter to a Roblox world:
--   * ores      -> terrain blobs (granite, dirt, gravel, ...) or ore records (coal, iron, ...)
--   * trees     -> tree records (species chosen exactly like vanilla's selectors)
-- The records go to World/Placements, which applies the spawn rules and hands them to Placement.placeThing.
--   * disks     -> sand / clay / gravel patches on shallow sea floors
--   * freeze    -> snow on cold ground, ice on cold water
-- Features draw from a per-feature, per-chunk random (deterministic, independent of generation order).
-- Their density/rules follow vanilla; exact block positions do not (see README).

local FeatureData = require(script.Parent.Parent.Data.Features)
local Settings = require(script.Parent.Parent.Data.Settings)
local Blocks = require(script.Parent.Blocks)
local Providers = require(script.Parent.Providers)
local BiomeTemperature = require(script.Parent.BiomeTemperature)
local Simplex = require(script.Parent.Parent.Noise.SimplexNoise)

local floor, ceil, min, max, sin, cos = math.floor, math.ceil, math.min, math.max, math.sin, math.cos

local MIN_Y = Settings.minY
local HEIGHT = Settings.height
local MAX_Y = MIN_Y + HEIGHT
local AIR, WATER, LAVA = Blocks.AIR, Blocks.WATER, Blocks.LAVA
local PI = math.pi

local BIOME_INFO_NOISE = Simplex.Perlin.new(0, 2345, { 0 })

-- block id sets for target predicates
local function idSet(names: { string }): buffer
	local b = buffer.create(256)
	for _, n in names do
		buffer.writeu8(b, Blocks.ids[n], 1)
	end
	return b
end
local TAGS: { [string]: buffer } = {
	stone_ore_replaceables = idSet({ "stone", "granite", "diorite", "andesite" }),
	deepslate_ore_replaceables = idSet({ "deepslate" }),
	base_stone_overworld = idSet({ "stone", "granite", "diorite", "andesite", "tuff", "deepslate" }),
}
local SOIL = idSet({ "dirt", "grass_block", "podzol", "coarse_dirt", "mycelium", "mud", "moss_block" })
local PROPAGULE_SOIL = idSet({ "dirt", "grass_block", "podzol", "coarse_dirt", "mycelium", "mud", "moss_block", "clay" })

export type Options = {
	things: boolean?, -- false: skip tree / ore records entirely (clients only need the terrain)
}

local Features = {}
Features.__index = Features

function Features.new(gen: any, options: Options?)
	local o: Options = options or {}
	local self = setmetatable({
		gen = gen,
		things = o.things ~= false,
		factories = {} :: { [string]: any },
		setCache = {} :: { [number]: { { [string]: boolean } } },
		universal = {} :: { [string]: boolean },
	}, Features)
	-- features listed by every biome at their step behave identically everywhere: skip their biome checks
	local registry = gen.registry
	for step = 1, 11 do
		local counts: { [string]: number } = {}
		local total = 0
		for id = 1, #registry.names do
			total += 1
			for _, n in registry.data[id].features[step] or {} do
				counts[n] = (counts[n] or 0) + 1
			end
		end
		for n, c in counts do
			if c == total then
				self.universal[n .. "@" .. step] = true
			end
		end
	end
	return self
end

-- per-biome per-step membership sets
local function featureSet(self: any, biomeId: number): { { [string]: boolean } }
	local s = self.setCache[biomeId]
	if s then
		return s
	end
	s = {}
	local lists = self.gen.registry.data[biomeId].features
	for step = 1, 11 do
		local set: { [string]: boolean } = {}
		for _, n in lists[step] or {} do
			set[n] = true
		end
		s[step] = set
	end
	self.setCache[biomeId] = s
	return s
end

local function factoryFor(self: any, name: string)
	local f = self.factories[name]
	if not f then
		f = self.gen.rs.random:fromHashOf("minecraft:decoration/" .. name):forkPositional()
		self.factories[name] = f
	end
	return f
end

-- ------------------------------------------------------------------ chunk-local world access
type Env = {
	chunk: any,
	random: any,
	minX: number,
	minZ: number,
	name: string,
	step: number,
	self: any,
}

local function inChunk(env: Env, x: number, z: number): boolean
	return x >= env.minX and x < env.minX + 16 and z >= env.minZ and z < env.minZ + 16
end

local function getBlock(env: Env, x: number, y: number, z: number): number?
	if y < MIN_Y or y >= MAX_Y then
		return AIR
	end
	if not inChunk(env, x, z) then
		return nil
	end
	return buffer.readu8(env.chunk.blocks, ((x - env.minX) * 16 + (z - env.minZ)) * HEIGHT + (y - MIN_Y))
end

local function setBlock(env: Env, x: number, y: number, z: number, id: number)
	if y < MIN_Y or y >= MAX_Y or not inChunk(env, x, z) then
		return
	end
	buffer.writeu8(env.chunk.blocks, ((x - env.minX) * 16 + (z - env.minZ)) * HEIGHT + (y - MIN_Y), id)
end

-- Heightmap.getFirstAvailable: y of the first free block above the highest matching block
local function heightAt(env: Env, kind: string, x: number, z: number): number?
	if not inChunk(env, x, z) then
		return nil
	end
	local col = (x - env.minX) * 16 + (z - env.minZ) + 1
	if kind == "OCEAN_FLOOR" or kind == "OCEAN_FLOOR_WG" then
		return env.chunk.floorY[col] + 1
	end
	return env.chunk.topY[col] + 1
end

-- ------------------------------------------------------------------ block predicates
local function evalPredicate(env: Env, p: any, x: number, y: number, z: number): boolean
	local t = p.type
	local off = p.offset
	if off then
		x, y, z = x + off[1], y + off[2], z + off[3]
	end
	if t == "would_survive" then
		local n: string = p.state.Name
		local b = getBlock(env, x, y - 1, z)
		if b == nil then
			return false
		end
		local soil = (n == "mangrove_propagule") and PROPAGULE_SOIL or SOIL
		return buffer.readu8(soil, b) == 1
	elseif t == "matching_blocks" then
		local b = getBlock(env, x, y, z)
		local name = b and Blocks.names[b] or "air"
		local blocks = p.blocks
		if type(blocks) == "string" then
			return blocks == name
		end
		for _, n in blocks do
			if n == name then
				return true
			end
		end
		return false
	elseif t == "matching_fluids" then
		local b = getBlock(env, x, y, z)
		if b == nil then
			return false
		end
		local fluids = p.fluids
		local isWater, isLava = b == WATER, b == LAVA
		local function has(n: string): boolean
			return (n == "water" and isWater) or (n == "lava" and isLava) or (n == "empty" and not isWater and not isLava)
		end
		if type(fluids) == "string" then
			return has(fluids)
		end
		for _, n in fluids do
			if has(n) then
				return true
			end
		end
		return false
	elseif t == "solid" then
		local b = getBlock(env, x, y, z)
		return b ~= nil and Blocks.isSolid(b)
	elseif t == "not" then
		return not evalPredicate(env, p.predicate, x - (off and off[1] or 0), y - (off and off[2] or 0), z - (off and off[3] or 0))
	elseif t == "any_of" then
		for _, q in p.predicates do
			if evalPredicate(env, q, x - (off and off[1] or 0), y - (off and off[2] or 0), z - (off and off[3] or 0)) then
				return true
			end
		end
		return false
	elseif t == "all_of" then
		for _, q in p.predicates do
			if not evalPredicate(env, q, x - (off and off[1] or 0), y - (off and off[2] or 0), z - (off and off[3] or 0)) then
				return false
			end
		end
		return true
	elseif t == "true" then
		return true
	end
	return false
end

-- ------------------------------------------------------------------ placement modifiers
type Pos = { number }

-- Runs the modifier list (without `biome`) over one start position. Returns the resulting positions.
local function applyModifiers(env: Env, mods: { any }, start: Pos): { Pos }
	local positions: { Pos } = { start }
	local random = env.random
	for _, m in mods do
		local t = m.type
		if t ~= "biome" then
			local out: { Pos } = {}
			for _, p in positions do
				if t == "count" then
					local n = Providers.int(m.count, random)
					for _ = 1, n do
						table.insert(out, { p[1], p[2], p[3] })
					end
				elseif t == "in_square" then
					table.insert(out, { p[1] + random:nextInt(16), p[2], p[3] + random:nextInt(16) })
				elseif t == "height_range" then
					table.insert(out, { p[1], Providers.height(m.height, random), p[3] })
				elseif t == "heightmap" then
					local h = heightAt(env, m.heightmap, p[1], p[3])
					if h and h > MIN_Y then
						table.insert(out, { p[1], h, p[3] })
					end
				elseif t == "rarity_filter" then
					if random:nextFloat() < 1.0 / m.chance then
						table.insert(out, p)
					end
				elseif t == "surface_water_depth_filter" then
					local a, b = heightAt(env, "WORLD_SURFACE", p[1], p[3]), heightAt(env, "OCEAN_FLOOR", p[1], p[3])
					if a and b and a - b <= m.max_water_depth then
						table.insert(out, p)
					end
				elseif t == "block_predicate_filter" then
					if evalPredicate(env, m.predicate, p[1], p[2], p[3]) then
						table.insert(out, p)
					end
				elseif t == "random_offset" then
					table.insert(out, { p[1] + Providers.int(m.xz_spread, random), p[2] + Providers.int(m.y_spread, random), p[3] + Providers.int(m.xz_spread, random) })
				elseif t == "noise_based_count" then
					local d0 = BIOME_INFO_NOISE:getValue(p[1] / m.noise_factor, p[3] / m.noise_factor, false)
					local n = ceil((d0 + m.noise_offset) * m.noise_to_count_ratio)
					for _ = 1, n do
						table.insert(out, { p[1], p[2], p[3] })
					end
				else
					table.insert(out, p) -- unsupported modifiers are pass-through
				end
			end
			positions = out
			if #positions == 0 then
				return positions
			end
		end
	end
	return positions
end

-- ------------------------------------------------------------------ ore
local function oreType(stateName: string): string?
	local n = string.match(stateName, "^deepslate_(.+)_ore$") or string.match(stateName, "^(.+)_ore$")
	return n
end

-- OreFeature.place. `writeInto`: only positions inside env.chunk are written / counted.
local function placeOre(env: Env, p: Pos, prog: any, collect: boolean)
	if collect and not env.self.things then
		return
	end
	local random = env.random
	local size = prog.size
	local discard = prog.discard
	local f = random:nextFloat() * PI
	local f1 = size / 8.0
	local i = ceil((size / 16.0 * 2.0 + 1.0) / 2.0)
	local x0 = p[1] + sin(f) * f1
	local x1 = p[1] - sin(f) * f1
	local z0 = p[3] + cos(f) * f1
	local z1 = p[3] - cos(f) * f1
	local y0 = p[2] + random:nextInt(3) - 2
	local y1 = p[2] + random:nextInt(3) - 2
	local minX = p[1] - ceil(f1) - i
	local minY = p[2] - 2 - i
	local minZ = p[3] - ceil(f1) - i
	local width = 2 * (ceil(f1) + i)
	local height = 2 * (2 + i)

	-- Blocks are only ever written inside this chunk, and only into stone, which lies at or below the ocean floor:
	-- if no overlapped column of this chunk reaches up to the vein's bottom, nothing can be placed.
	local overlapX0, overlapX1 = max(minX, env.minX), min(minX + width, env.minX + 15)
	local overlapZ0, overlapZ1 = max(minZ, env.minZ), min(minZ + width, env.minZ + 15)
	if overlapX0 > overlapX1 or overlapZ0 > overlapZ1 or minY > env.chunk.maxFloor + 1 then
		return
	end
	local reach = false
	for cx = overlapX0, overlapX1 do
		for cz = overlapZ0, overlapZ1 do
			if minY <= heightAt(env, "OCEAN_FLOOR_WG", cx, cz) :: number then
				reach = true
				break
			end
		end
		if reach then
			break
		end
	end
	if not reach then
		return
	end

	local spheres = table.create(size * 4, 0)
	for k = 0, size - 1 do
		local t = k / size
		local d0 = x0 + t * (x1 - x0)
		local d1 = y0 + t * (y1 - y0)
		local d2 = z0 + t * (z1 - z0)
		local d3 = random:nextDouble() * size / 16.0
		local d4 = ((sin(PI * t) + 1.0) * d3 + 1.0) / 2.0
		spheres[k * 4 + 1], spheres[k * 4 + 2], spheres[k * 4 + 3], spheres[k * 4 + 4] = d0, d1, d2, d4
	end
	for a = 0, size - 2 do
		if spheres[a * 4 + 4] > 0 then
			for b = a + 1, size - 1 do
				if spheres[b * 4 + 4] > 0 then
					local dx = spheres[a * 4 + 1] - spheres[b * 4 + 1]
					local dy = spheres[a * 4 + 2] - spheres[b * 4 + 2]
					local dz = spheres[a * 4 + 3] - spheres[b * 4 + 3]
					local dr = spheres[a * 4 + 4] - spheres[b * 4 + 4]
					if dr * dr > dx * dx + dy * dy + dz * dz then
						if dr > 0 then
							spheres[b * 4 + 4] = -1.0
						else
							spheres[a * 4 + 4] = -1.0
						end
					end
				end
			end
		end
	end

	local placed = 0
	local seen: { [number]: boolean } = {}
	local chunk = env.chunk
	local cxMin, czMin = env.minX, env.minZ
	for k = 0, size - 1 do
		local d9 = spheres[k * 4 + 4]
		if d9 >= 0 then
			local dx, dy, dz = spheres[k * 4 + 1], spheres[k * 4 + 2], spheres[k * 4 + 3]
			local bx0 = max(floor(dx - d9), minX)
			local by0 = max(floor(dy - d9), minY)
			local bz0 = max(floor(dz - d9), minZ)
			local bx1 = max(floor(dx + d9), bx0)
			local by1 = max(floor(dy + d9), by0)
			local bz1 = max(floor(dz + d9), bz0)
			-- clip to this chunk: only its blocks are written
			bx0, bx1 = max(bx0, cxMin), min(bx1, cxMin + 15)
			bz0, bz1 = max(bz0, czMin), min(bz1, czMin + 15)
			for x = bx0, bx1 do
				local d5 = (x + 0.5 - dx) / d9
				if d5 * d5 < 1.0 then
					for y = by0, by1 do
						local d6 = (y + 0.5 - dy) / d9
						if d5 * d5 + d6 * d6 < 1.0 and y >= MIN_Y and y < MAX_Y then
							for z = bz0, bz1 do
								local d7 = (z + 0.5 - dz) / d9
								if d5 * d5 + d6 * d6 + d7 * d7 < 1.0 then
									local key = ((x - minX) + (y - minY) * (width + 1) + (z - minZ) * (width + 1) * (height + 1))
									if not seen[key] then
										seen[key] = true
										local idx = ((x - cxMin) * 16 + (z - czMin)) * HEIGHT + (y - MIN_Y)
										local b = buffer.readu8(chunk.blocks, idx)
										for _, target in prog.targets do
											local tag = target.target.tag
											local matches
											if target.target.predicate_type == "tag_match" then
												matches = buffer.readu8(TAGS[tag], b) == 1
											else
												matches = Blocks.names[b] == target.target.block
											end
											if matches then
												local ok
												if discard <= 0 then
													ok = true
												elseif discard >= 1 then
													ok = false
												else
													ok = random:nextFloat() >= discard
												end
												if not ok then
													-- adjacent to air?
													local exposed = false
													for _, o in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
														local nb = getBlock(env, x + o[1], y + o[2], z + o[3])
														if nb == AIR then
															exposed = true
															break
														end
													end
													ok = not exposed
												end
												if ok then
													if not collect then
														local id = Blocks.ids[target.state]
														if id then
															buffer.writeu8(chunk.blocks, idx, id)
														end
													end
													placed += 1
												end
												break
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	if collect and placed > 0 then
		local ore = oreType(prog.targets[1].state)
		if ore then
			table.insert(chunk.collectables, {
				kind = "Ore",
				ore = ore,
				x = (x0 + x1) / 2,
				y = (y0 + y1) / 2,
				z = (z0 + z1) / 2,
				count = placed,
			})
		end
	end
end

-- ------------------------------------------------------------------ disks
local function placeDisk(env: Env, p: Pos, prog: any)
	local random = env.random
	local halfHeight = prog.halfHeight
	local maxY = p[2] + halfHeight
	local minY = p[2] - halfHeight - 1
	local r = Providers.int(prog.radius, random)
	local targets: { [string]: boolean } = {}
	local tb = prog.target.blocks
	if type(tb) == "string" then
		targets[tb] = true
	else
		for _, n in tb do
			targets[n] = true
		end
	end
	for x = p[1] - r, p[1] + r do
		for z = p[3] - r, p[3] + r do
			local dx, dz = x - p[1], z - p[3]
			if dx * dx + dz * dz <= r * r and inChunk(env, x, z) then
				for y = maxY, minY + 1, -1 do
					local b = getBlock(env, x, y, z)
					if b and targets[Blocks.names[b]] then
						-- rule based state provider
						local state = prog.state
						local name = state.fallback.state.Name
						for _, rule in state.rules do
							if evalPredicate(env, rule.if_true, x, y, z) then
								name = rule["then"].state.Name
								break
							end
						end
						local id = Blocks.ids[name]
						if id then
							setBlock(env, x, y, z, id)
						end
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ trees
local function addTree(env: Env, p: Pos, prog: any)
	if not env.self.things then
		return
	end
	local below = getBlock(env, p[1], p[2] - 1, p[3])
	if below == nil then
		return
	end
	local species = prog.species
	local isMushroom = string.find(species, "mushroom") ~= nil
	if not isMushroom and buffer.readu8(SOIL, below) == 0 then
		return
	end
	local here = getBlock(env, p[1], p[2], p[3])
	if here ~= AIR then
		return
	end
	local h = prog.h
	local random = env.random
	local height = h[1] + random:nextInt(h[2] + 1) + random:nextInt((h[3] or 0) + 1)
	local biomeId = env.chunk.biomeTop[(p[1] - env.minX) * 16 + (p[3] - env.minZ) + 1]
	table.insert(env.chunk.collectables, {
		kind = "Tree",
		species = species,
		x = p[1],
		y = p[2],
		z = p[3],
		height = height,
		biome = env.self.gen.registry.names[biomeId],
	})
end

-- ------------------------------------------------------------------ program runner
local runPlaced: (Env, any, Pos) -> ()

local function runProgram(env: Env, prog: any, p: Pos)
	local k = prog.kind
	if k == "tree" then
		addTree(env, p, prog)
	elseif k == "ore" then
		local first = prog.targets[1].state
		local collect = Blocks.ids[first] == nil
		placeOre(env, p, prog, collect)
	elseif k == "disk" then
		placeDisk(env, p, prog)
	elseif k == "pick" then
		for _, o in prog.options do
			if env.random:nextFloat() < o.chance then
				runPlaced(env, o.feature, p)
				return
			end
		end
		runPlaced(env, prog.default, p)
	elseif k == "any" then
		local list = prog.features
		runPlaced(env, list[env.random:nextInt(#list) + 1], p)
	elseif k == "bool" then
		if env.random:nextBoolean() then
			runPlaced(env, prog.t, p)
		else
			runPlaced(env, prog.f, p)
		end
	end
end

-- a nested placed feature: {ref=name} | {placement, feature}
runPlaced = function(env: Env, placed: any, p: Pos)
	if placed == nil then
		return
	end
	if placed.ref then
		placed = FeatureData[placed.ref]
		if placed == nil then
			return
		end
	end
	local positions = applyModifiers(env, placed.placement, p)
	for _, q in positions do
		runProgram(env, placed.feature, q)
	end
end

-- ------------------------------------------------------------------ freeze_top_layer
local function freezeTopLayer(self: any, env: Env)
	local chunk = env.chunk
	local registry = self.gen.registry
	local blocks = chunk.blocks
	local iceId, snowId = Blocks.ids.ice, Blocks.ids.snow_block
	for x = 0, 15 do
		for z = 0, 15 do
			local col = x * 16 + z
			local top = chunk.topY[col + 1]
			if top >= MIN_Y then
				local wx, wz = env.minX + x, env.minZ + z
				local biomeId = chunk.biomeTop[col + 1]
				local data = registry.data[biomeId]
				if BiomeTemperature.at(data, wx, top + 1, wz) < 0.15 then
					local idx = col * HEIGHT + (top - MIN_Y)
					local b = buffer.readu8(blocks, idx)
					if b == WATER then
						buffer.writeu8(blocks, idx, iceId)
					elseif Blocks.isSolid(b) and b ~= iceId and b ~= Blocks.ids.packed_ice and b ~= Blocks.ids.blue_ice and b ~= snowId then
						buffer.writeu8(blocks, idx, snowId)
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ custom (magical) biome features
local function customFeatures(self: any, env: Env)
	local chunk = env.chunk
	local registry = self.gen.registry
	local present: { [number]: boolean } = {}
	for col = 1, 256 do
		local id = chunk.biomeTop[col]
		if registry.custom[id] then
			present[id] = true
		end
	end
	for id in present do
		local def = registry.custom[id]
		local factory = factoryFor(self, "custom/" .. def.id)
		local random = factory:at(chunk.cx, 0, chunk.cz)
		env.random = random
		for _, t in def.trees or {} do
			local n = floor(t.perChunk or 2) + ((random:nextFloat() < (t.perChunk or 2) % 1) and 1 or 0)
			for _ = 1, n do
				local x, z = env.minX + random:nextInt(16), env.minZ + random:nextInt(16)
				local col = (x - env.minX) * 16 + (z - env.minZ)
				if chunk.biomeTop[col + 1] == id then
					local y = chunk.floorY[col + 1] + 1
					if y > MIN_Y and chunk.topY[col + 1] == chunk.floorY[col + 1] then
						table.insert(chunk.collectables, {
							kind = "Tree", species = t.species, x = x, y = y, z = z, height = 5, biome = def.id,
						})
					end
				end
			end
		end
		for _, o in def.ores or {} do
			local n = floor(o.perChunk or 1) + ((random:nextFloat() < (o.perChunk or 1) % 1) and 1 or 0)
			for _ = 1, n do
				local x, z = env.minX + random:nextInt(16), env.minZ + random:nextInt(16)
				local col = (x - env.minX) * 16 + (z - env.minZ)
				if chunk.biomeTop[col + 1] == id then
					local lo, hi = o.minY or MIN_Y + 8, min(o.maxY or 64, chunk.floorY[col + 1] - 2)
					if hi >= lo then
						local y = random:nextInt(hi - lo + 1) + lo
						table.insert(chunk.collectables, {
							kind = "Ore", ore = o.name, x = x, y = y, z = z, count = o.size or 4,
						})
					end
				end
			end
		end
	end
end

-- Big copper/iron vein ore blocks (from the noise stage) -> one Ore record per 4x4x4 block region
local function clusterVeinOres(self: any, chunk: any)
	local groups: { [number]: { n: number, x: number, y: number, z: number, ore: string } } = {}
	for _, e in chunk.veinOres do
		local x, y, z, ore = e[1], e[2], e[3], e[4]
		local key = (floor(x / 4) * 65536 + floor(z / 4)) * 128 + floor((y - MIN_Y) / 4)
		local g = groups[key]
		if not g then
			g = { n = 0, x = 0, y = 0, z = 0, ore = ore }
			groups[key] = g
		end
		g.n += 1
		g.x += x
		g.y += y
		g.z += z
	end
	for _, g in groups do
		table.insert(chunk.collectables, {
			kind = "Ore", ore = g.ore, x = g.x / g.n, y = g.y / g.n, z = g.z / g.n, count = g.n,
		})
	end
end

-- ------------------------------------------------------------------ driver
function Features.generate(self: any, chunk: any)
	chunk.collectables = chunk.collectables or {}
	local maxFloor = MIN_Y
	for i = 1, 256 do
		if chunk.floorY[i] > maxFloor then
			maxFloor = chunk.floorY[i]
		end
	end
	chunk.maxFloor = maxFloor
	local gen = self.gen
	local registry = gen.registry
	local cx, cz = chunk.cx, chunk.cz

	-- candidate biomes = every biome at the surface of this chunk
	local candidates: { number } = {}
	local seen: { [number]: boolean } = {}
	for col = 1, 256 do
		local id = chunk.biomeTop[col]
		if not seen[id] then
			seen[id] = true
			table.insert(candidates, id)
		end
	end
	table.sort(candidates)

	local env: Env = {
		chunk = chunk, random = nil, minX = cx * 16, minZ = cz * 16, name = "", step = 0, self = self,
	}

	for step = 1, 11 do
		local order: { string } = {}
		local have: { [string]: boolean } = {}
		for _, id in candidates do
			for _, n in registry.data[registry.base[id]].features[step] or {} do
				if not have[n] and FeatureData[n] then
					have[n] = true
					table.insert(order, n)
				end
			end
		end
		for _, name in order do
			local placed = FeatureData[name]
			local prog = placed.feature
			env.name, env.step = name, step
			local factory = factoryFor(self, name)
			local isTerrainOre = prog.kind == "ore" and Blocks.ids[prog.targets[1].state] ~= nil

			if prog.kind == "freeze" then
				freezeTopLayer(self, env)
			else
				-- terrain-writing ores also simulate the 8 neighbouring chunks so veins cross chunk borders
				local range = isTerrainOre and 1 or 0
				for dx = -range, range do
					for dz = -range, range do
						local ncx, ncz = cx + dx, cz + dz
						env.random = factory:at(ncx, step, ncz)
						local origin: Pos = { ncx * 16, MIN_Y, ncz * 16 }
						local positions = applyModifiers(env, placed.placement, origin)
						local universal = self.universal[name .. "@" .. step]
						for _, p in positions do
							-- the biome modifier is last in every list: check membership at the placement position
							if universal then
								runProgram(env, prog, p)
							else
								local id = registry.base[gen.biomes:getBiome(p[1], p[2], p[3])]
								if featureSet(self, id)[step][name] then
									runProgram(env, prog, p)
								end
							end
						end
					end
				end
			end
		end
	end
	if self.things then
		clusterVeinOres(self, chunk)
		customFeatures(self, env)
	end
end

return Features
