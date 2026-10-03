-- Mock of the Roblox API surface the generator's Roblox layer uses, so it can run under the Luau CLI.
-- Server and client code run in ONE Lua VM here; MOCK.* exposes the pieces tests drive.
-- Terrain voxels are recorded in a dictionary so tests can compare them with the generator's output.

-- ------------------------------------------------------------------ math types
local V3 = {}
V3.__index = V3
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b) if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z) end
V3.__div = function(a, b) return vec(a.X / b, a.Y / b, a.Z / b) end
V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector2 = { new = function(x, y) return { X = x, Y = y } end }

local CF = {}
CF.__index = CF
CF.__mul = function(a, b)
	if getmetatable(b) == CF then return setmetatable({ Position = a.Position + b.Position, Yaw = (a.Yaw or 0) + (b.Yaw or 0) }, CF) end
	return a.Position + b
end
CFrame = {
	new = function(x, y, z)
		if type(x) == "table" then return setmetatable({ Position = x }, CF) end
		return setmetatable({ Position = vec(x, y, z) }, CF)
	end,
	Angles = function(_, yaw, _) return setmetatable({ Position = vec(0, 0, 0), Yaw = yaw }, CF) end,
}
Region3 = { new = function(a, b) return { Min = a, Max = b } end }
local C3 = {}
Color3 = { fromRGB = function(r, g, b) return setmetatable({ R = r / 255, G = g / 255, B = b / 255 }, C3) end }
RaycastParams = { new = function() return { IgnoreWater = false } end }
Enum = {
	Material = setmetatable({}, { __index = function(_, k) return "M." .. k end }),
	RaycastFilterType = { Exclude = "Exclude", Include = "Include" },
}
typeof = function(v)
	if type(v) == "table" then
		local m = getmetatable(v)
		if m == V3 then return "Vector3" elseif m == CF then return "CFrame" elseif m == C3 then return "Color3" end
	end
	return type(v)
end
Random = { new = function(seed) local s = seed return { NextNumber = function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end } end }
warn = warn or print

-- ------------------------------------------------------------------ signals and the scheduler (virtual time)
local Signal = {}
Signal.__index = Signal
local function newSignal() return setmetatable({ handlers = {} }, Signal) end
function Signal:Connect(f)
	local h = { f = f }
	table.insert(self.handlers, h)
	return { Disconnect = function() h.dead = true for i, x in self.handlers do if x == h then table.remove(self.handlers, i) break end end end }
end
function Signal:Fire(...) for _, h in table.clone(self.handlers) do if not h.dead then task.spawn(h.f, ...) end end end

local now = 0
local sleepers = {}
local function resume(co, ...)
	local ok, wake = coroutine.resume(co, ...)
	if not ok then error(wake, 0) end
	if coroutine.status(co) == "suspended" then table.insert(sleepers, { co = co, at = wake or now }) end
end
task = {
	spawn = function(f, ...)
		local co = type(f) == "thread" and f or coroutine.create(f)
		resume(co, ...)
		return co
	end,
	defer = function(f, ...) local co = type(f) == "thread" and f or coroutine.create(f) resume(co, ...) return co end,
	delay = function(t, f, ...)
		local args = table.pack(...)
		local co = coroutine.create(function() task.wait(t) f(table.unpack(args, 1, args.n)) end)
		resume(co)
		return co
	end,
	wait = function(t) return coroutine.yield(now + (t or 0)) end,
	synchronize = function() end, desynchronize = function() end,
}

-- ------------------------------------------------------------------ instances
local Instance_ = {}
Instance_.__index = function(t, k)
	if k == "Parent" then return rawget(t, "_parent") end
	local m = rawget(Instance_, k)
	if m ~= nil then return m end
	local props = rawget(t, "_props")
	if props and props[k] ~= nil then return props[k] end
	local sigs = rawget(t, "_signals")
	if sigs[k] then return sigs[k] end
	for _, c in rawget(t, "_children") do if c.Name == k then return c end end
	return nil
end
Instance_.__newindex = function(t, k, v)
	if k == "Parent" then
		local old = rawget(t, "_parent")
		if old then for i, c in old._children do if c == t then table.remove(old._children, i) break end end end
		rawset(t, "_parent", v)
		if v then table.insert(v._children, t) end
	else
		t._props[k] = v
	end
end
function Instance_.FindFirstChild(self, name) for _, c in self._children do if c.Name == name then return c end end return nil end
function Instance_.WaitForChild(self, name, timeout)
	local waited = 0
	while true do
		local c = self:FindFirstChild(name)
		if c then return c end
		if timeout and waited >= timeout then return nil end
		task.wait(0.05)
		waited += 0.05
	end
end
function Instance_.Destroy(self) self.Parent = nil self._destroyed = true end
function Instance_.IsDescendantOf(self, other) local p = self.Parent while p do if p == other then return true end p = p.Parent end return false end
function Instance_.IsA(self, class) return self.ClassName == class end
function Instance_.SetAttribute(self, k, v)
	local old = self._attrs[k]
	self._attrs[k] = v
	if old ~= v then self._signals.AttributeChanged:Fire(k) end
end
function Instance_.GetAttribute(self, k) return self._attrs[k] end
function Instance_.GetChildren(self) return table.clone(self._children) end
function Instance_.Clone(self)
	local c = Instance.new(self.ClassName)
	c.Name = self.Name
	for k, v in self._props do c._props[k] = v end
	for k, v in self._attrs do c._attrs[k] = v end
	for _, ch in self._children do local cc = ch:Clone() cc.Parent = c end
	return c
end
Instance = { new = function(class)
	local o = setmetatable({ _children = {}, _props = { Name = class }, _attrs = {}, _signals = { AttributeChanged = newSignal() }, ClassName = class }, Instance_)
	rawset(o, "ClassName", class)
	if class == "BindableEvent" then
		local sig = newSignal()
		o._props.Event = sig
		o._props.Fire = function(_, ...) sig:Fire(...) end
	elseif class == "RemoteEvent" then
		o._signals.OnServerEvent = newSignal()
		o._props.FireServer = function(self, ...) self._signals.OnServerEvent:Fire(MOCK.localPlayer, ...) end
	end
	return o
end }

-- ------------------------------------------------------------------ Terrain
local Terrain = Instance.new("Terrain")
Terrain.voxels = {}
Terrain.fills, Terrain.writes = 0, 0
local function vkey(x, y, z) return x .. "," .. y .. "," .. z end
Terrain._props.FillBlock = function(self, cf, size, material)
	self.fills += 1
	local p = cf.Position
	local x0, y0, z0 = (p.X - size.X / 2) / 4, (p.Y - size.Y / 2) / 4, (p.Z - size.Z / 2) / 4
	assert(x0 == math.floor(x0) and y0 == math.floor(y0) and z0 == math.floor(z0), "FillBlock not voxel aligned")
	for x = x0, x0 + size.X / 4 - 1 do for y = y0, y0 + size.Y / 4 - 1 do for z = z0, z0 + size.Z / 4 - 1 do
		if material == "M.Air" then self.voxels[vkey(x, y, z)] = nil else self.voxels[vkey(x, y, z)] = { material, 1 } end
	end end end
end
Terrain._props.WriteVoxels = function(self, region, res, mats, occs)
	self.writes += 1
	assert(res == 4)
	local x0, y0, z0 = region.Min.X / 4, region.Min.Y / 4, region.Min.Z / 4
	local nx, ny, nz = (region.Max.X - region.Min.X) / 4, (region.Max.Y - region.Min.Y) / 4, (region.Max.Z - region.Min.Z) / 4
	assert(#mats == nx and #mats[1] == ny and #mats[1][1] == nz, "material array shape does not match the region")
	for x = 1, nx do for y = 1, ny do for z = 1, nz do
		local m, o = mats[x][y][z], occs[x][y][z]
		assert(m ~= nil and o ~= nil)
		local k = vkey(x0 + x - 1, y0 + y - 1, z0 + z - 1)
		if m == "M.Air" or o <= 0 then self.voxels[k] = nil else self.voxels[k] = { m, o } end
	end end end
end
Terrain._props.Clear = function(self) self.voxels = {} end
Terrain._props.SetMaterialColor = function(self, m, c) self.colors = self.colors or {} self.colors[m] = c end

workspace = Instance.new("Workspace")
Terrain.Parent = workspace
Terrain.Name = "Terrain"
workspace._props.Terrain = Terrain
-- flat fake ground at y = 2100 (water for x < -100), unless MOCK.noGround is set
workspace._props.Raycast = function(self, origin, dir, params)
	if MOCK.noGround then return nil end
	return { Position = vec(origin.X, 2100, origin.Z), Material = origin.X < -100 and "M.Water" or "M.Grass" }
end
workspace._props.GetServerTimeNow = function() return 1000 + now end

-- ------------------------------------------------------------------ services
local function newService(class) return Instance.new(class) end
local PlayersService = newService("Players")
PlayersService.CharacterAutoLoads = true
PlayersService.RespawnTime = 5
PlayersService._signals.PlayerAdded = newSignal()
PlayersService._signals.PlayerRemoving = newSignal()
local playersList = {}
PlayersService._props.GetPlayers = function() return playersList end

local RunServiceMock = Instance.new("RunService")
local heartbeat = newSignal()
RunServiceMock._signals.Heartbeat = heartbeat
RunServiceMock._props.IsServer = function() return true end
RunServiceMock._props.IsClient = function() return false end

local SSS = newService("ServerScriptService")
local RS = newService("ReplicatedStorage")
local StarterPlayer = newService("StarterPlayer")
local sps = Instance.new("StarterPlayerScripts")
sps.Parent = StarterPlayer

-- minimal JSON (objects, arrays, strings, numbers, booleans)
local function isArray(t)
	local n = 0
	for _ in t do n += 1 end
	for i = 1, n do if t[i] == nil then return false end end
	return true
end
local function encode(v)
	local t = type(v)
	if t == "table" then
		if next(v) == nil then return "[]" end
		if isArray(v) then
			local out = {}
			for i, x in v do out[i] = encode(x) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in v do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local out = {}
		for _, k in keys do table.insert(out, encode(tostring(k)) .. ":" .. encode(v[k])) end
		return "{" .. table.concat(out, ",") .. "}"
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
	elseif t == "number" then
		return string.format("%.17g", v)
	elseif t == "boolean" then
		return tostring(v)
	end
	error("cannot JSON-encode " .. t)
end
local function decode(s)
	local i = 1
	local function ws() i = s:find("%S", i) or #s + 1 end
	local value
	local function str()
		local j = i + 1
		local out = {}
		while true do
			local c = s:sub(j, j)
			if c == '"' then i = j + 1 return table.concat(out) end
			if c == "\\" then
				local n = s:sub(j + 1, j + 1)
				if n == "u" then table.insert(out, string.char(tonumber(s:sub(j + 2, j + 5), 16))) j += 6
				else table.insert(out, ({ n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })[n] or n) j += 2 end
			else table.insert(out, c) j += 1 end
		end
	end
	function value()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			i += 1
			local out = {}
			ws()
			if s:sub(i, i) == "}" then i += 1 return out end
			while true do
				ws()
				local k = str()
				ws() i += 1 -- ':'
				out[k] = value()
				ws()
				local d = s:sub(i, i) i += 1
				if d == "}" then return out end
			end
		elseif c == "[" then
			i += 1
			local out = {}
			ws()
			if s:sub(i, i) == "]" then i += 1 return out end
			while true do
				table.insert(out, value())
				ws()
				local d = s:sub(i, i) i += 1
				if d == "]" then return out end
			end
		elseif c == '"' then return str()
		elseif s:sub(i, i + 3) == "true" then i += 4 return true
		elseif s:sub(i, i + 4) == "false" then i += 5 return false
		elseif s:sub(i, i + 3) == "null" then i += 4 return nil
		else
			local num = s:match("^-?[%d%.eE+-]+", i)
			i += #num
			return tonumber(num)
		end
	end
	return value()
end
local HttpService = { JSONEncode = function(_, v) return encode(v) end, JSONDecode = function(_, s) return decode(s) end }
local MaterialService = Instance.new("MaterialService")
MaterialService._props.SetBaseMaterialOverride = function(self, material, name) self.overrides = self.overrides or {} self.overrides[material] = name end

local services = {
	Players = PlayersService, RunService = RunServiceMock, ServerScriptService = SSS, ReplicatedStorage = RS,
	StarterPlayer = StarterPlayer, HttpService = HttpService, MaterialService = MaterialService,
}
game = { GetService = function(_, n) return services[n] end }

-- ------------------------------------------------------------------ players
local function newPlayer(id, x, z, local_)
	local p = Instance.new("Player")
	p.UserId = id
	p.spawnX, p.spawnZ = x, z
	p._signals.CharacterAdded = newSignal()
	local gui = Instance.new("PlayerGui") gui.Parent = p
	local scripts = Instance.new("PlayerScripts") scripts.Parent = p
	rawset(p, "_parent", PlayersService)
	p._props.LoadCharacter = function(self)
		local char = Instance.new("Model")
		char.Name = "Character"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		local pad = workspace:FindFirstChild("TerrainSpawn")
		root.Position = pad and pad.Position or vec(self.spawnX or 0, 700, self.spawnZ or 0)
		root.Parent = char
		local hum = Instance.new("Humanoid")
		hum._signals.Died = newSignal()
		hum.Parent = char
		self.Character = char
		self.loads = (self.loads or 0) + 1
		self._signals.CharacterAdded:Fire(char)
	end
	table.insert(playersList, p)
	if local_ then MOCK.localPlayer = p PlayersService._props.LocalPlayer = p end
	PlayersService._signals.PlayerAdded:Fire(p)
	return p
end

MOCK = {
	terrain = Terrain, players = playersList, PlayersService = PlayersService, SSS = SSS, RS = RS, StarterPlayer = StarterPlayer,
	localPlayer = nil, noGround = false,
	heartbeat = function(dt) heartbeat:Fire(dt) end,
	newPlayer = newPlayer,
	setPosition = function(p, x, z)
		p.spawnX, p.spawnZ = x, z
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root then root.Position = vec(x, root.Position.Y, z) end
	end,
	removePlayer = function(p)
		for i, q in playersList do if q == p then table.remove(playersList, i) break end end
		PlayersService._signals.PlayerRemoving:Fire(p)
		rawset(p, "_parent", nil)
	end,
	now = function() return now end,
}
MOCK.advance = function(dt)
	now += dt
	local due, rest = {}, {}
	for _, s in sleepers do if s.at <= now then table.insert(due, s) else table.insert(rest, s) end end
	sleepers = rest
	for _, s in due do resume(s.co, now) end
end
os_clock_real = os.clock
