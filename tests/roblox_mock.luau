-- Minimal mock of the Roblox API surface the generator's Roblox layer uses, so it can run under the Luau CLI.
-- Terrain voxels are recorded in a dictionary so tests can compare them with the generator's output.

local V3 = {}
V3.__index = V3
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b) if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z) end
V3.__div = function(a, b) return vec(a.X / b, a.Y / b, a.Z / b) end
V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
CFrame = { new = function(x, y, z)
	if type(x) == "table" then return { Position = x } end
	return { Position = vec(x, y, z) }
end }
Region3 = { new = function(a, b) return { Min = a, Max = b } end }
Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end }
RaycastParams = { new = function() return { IgnoreWater = false } end }
Enum = { Material = setmetatable({}, { __index = function(_, k) return "M." .. k end }), RaycastFilterType = { Exclude = "Exclude" } }
typeof = function(v) if type(v) == "table" and getmetatable(v) == V3 then return "Vector3" end return type(v) end

local Instance_ = {}
Instance_.__index = function(t, k)
	if k == "Parent" then return rawget(t, "_parent") end
	local m = rawget(Instance_, k)
	if m ~= nil then return m end
	local props = rawget(t, "_props")
	if props and props[k] ~= nil then return props[k] end
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
function Instance_.Destroy(self) self.Parent = nil self._destroyed = true end
function Instance_.SetAttribute(self, k, v) self._attrs[k] = v end
function Instance_.GetAttribute(self, k) return self._attrs[k] end
function Instance_.GetChildren(self) return table.clone(self._children) end
function Instance_.Clone(self) local c = Instance.new(self.ClassName) c.Name = self.Name for k, v in self._props do c._props[k] = v end for _, ch in self._children do local cc = ch:Clone() cc.Parent = c end return c end
Instance = { new = function(class)
	local o = setmetatable({ _children = {}, _props = { Name = class }, _attrs = {}, ClassName = class }, Instance_)
	rawset(o, "ClassName", class)
	if class == "BindableEvent" then
		local handlers = {}
		o._props.Event = { Connect = function(_, f) table.insert(handlers, f) return { Disconnect = function() end } end }
		o._props.Fire = function(_, ...) for _, h in handlers do task.spawn(h, ...) end end
	end
	return o
end }

-- Terrain
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
workspace._props.Raycast = function(self, origin, dir, params)
	-- flat fake world: ground at y = 2100, water above x < 0
	local surfaceY = 2100
	return { Position = vec(origin.X, surfaceY, origin.Z), Material = origin.X < -100 and "M.Water" or "M.Grass" }
end

-- Services
local heartbeatHandlers = {}
local playersList = {}
local PlayersService = { CharacterAutoLoads = true, _removing = {} }
function PlayersService:GetPlayers() return playersList end
PlayersService.PlayerRemoving = { Connect = function(_, f) table.insert(PlayersService._removing, f) return { Disconnect = function() end } end }
local RunServiceMock = { Heartbeat = { Connect = function(_, f) table.insert(heartbeatHandlers, f) return { Disconnect = function() for i, h in heartbeatHandlers do if h == f then table.remove(heartbeatHandlers, i) break end end end } end } }
function RunServiceMock:IsServer() return true end
local SSS = Instance.new("ServerScriptService")
function SSS.WaitForChild(self, n) return self:FindFirstChild(n) end
local services = { Players = PlayersService, RunService = RunServiceMock, ServerScriptService = SSS }
game = { GetService = function(_, n) return services[n] end }
MOCK = {
	terrain = Terrain, players = playersList, PlayersService = PlayersService, SSS = SSS,
	heartbeat = function(dt) for _, h in table.clone(heartbeatHandlers) do h(dt) end end,
	newPlayer = function(id, x, z)
		local root = { Position = vec(x, 700, z) }
		local p = { UserId = id, Character = { FindFirstChild = function(_, n) if n == "HumanoidRootPart" then return root end end }, root = root }
		function p:LoadCharacter() end
		table.insert(playersList, p)
		return p
	end,
}

-- task scheduler (virtual time)
local now = 0
local sleepers = {}
local function resume(co, ...)
	local ok, wake = coroutine.resume(co, ...)
	if not ok then error(wake, 0) end
	if coroutine.status(co) == "suspended" then table.insert(sleepers, { co = co, at = wake or now }) end
end
task = {
	spawn = function(f, ...) local co = coroutine.create(f) resume(co, ...) return co end,
	defer = function(f, ...) local co = coroutine.create(f) resume(co, ...) return co end,
	wait = function(t) return coroutine.yield(now + (t or 0)) end,
	synchronize = function() end, desynchronize = function() end,
}
MOCK.advance = function(dt)
	now += dt
	local due, rest = {}, {}
	for _, s in sleepers do if s.at <= now then table.insert(due, s) else table.insert(rest, s) end end
	sleepers = rest
	for _, s in due do resume(s.co, now) end
end
os_clock_real = os.clock
