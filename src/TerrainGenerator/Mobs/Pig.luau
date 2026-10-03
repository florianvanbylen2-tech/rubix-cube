--!strict
-- A wandering pig at the spawn point. It is a client-side mob: every client animates the same pig, because its walk
-- is a pure function of the world seed and the server clock (no network traffic, no server cost), and it follows the
-- client's own terrain with a downward raycast.
--
-- The path: time is cut into PERIOD-second segments; segment n walks from point P(n) to P(n+1), where P(k) is a
-- seeded random spot within RADIUS studs of home. After arriving the pig rests until the segment ends.

local Xoroshiro = require(script.Parent.Parent.Core.Xoroshiro)
local Int64 = require(script.Parent.Parent.Core.Int64)

local Pig = {}

Pig.PERIOD = 10 -- seconds per segment
Pig.RADIUS = 22 -- studs around home
Pig.SPEED = 5 -- studs per second while walking

local function point(seed: number, k: number): (number, number)
	local r = Xoroshiro.new(Int64.fromNumber(seed * 1000 + (k % 1000003)))
	local angle = r:nextDouble() * math.pi * 2
	local radius = math.sqrt(r:nextDouble()) * Pig.RADIUS
	return math.cos(angle) * radius, math.sin(angle) * radius
end

-- Offset from home (studs), heading (radians, 0 = +Z) and walking flag at time `t` (seconds).
function Pig.pathAt(seed: number, t: number): (number, number, number, boolean)
	local n = math.floor(t / Pig.PERIOD)
	local x0, z0 = point(seed, n)
	local x1, z1 = point(seed, n + 1)
	if n == 0 then
		x0, z0 = 0, 0
	end
	local dx, dz = x1 - x0, z1 - z0
	local dist = math.sqrt(dx * dx + dz * dz)
	local walkTime = math.min(Pig.PERIOD - 1.5, dist / Pig.SPEED)
	local into = t - n * Pig.PERIOD
	local u = if walkTime > 0 then math.clamp(into / walkTime, 0, 1) else 1
	return x0 + dx * u, z0 + dz * u, math.atan2(dx, dz), u < 1 and dist > 0.5
end

local PINK = Color3.fromRGB(245, 160, 178)
local SNOUT = Color3.fromRGB(232, 120, 140)
local DARK = Color3.fromRGB(30, 30, 30)

local function makePart(model: Model, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Material = Enum.Material.SmoothPlastic
	p.Size = size
	p.Color = color
	p.Parent = model
	return p
end

-- opts: { seed: number, home: Vector3 (ground point), time: (() -> number)? }
function Pig.start(opts: any): any
	local RunService = game:GetService("RunService")
	local model = Instance.new("Model")
	model.Name = "Pig"
	local body = makePart(model, Vector3.new(4, 3, 6), PINK)
	local head = makePart(model, Vector3.new(3, 3, 3), PINK)
	local snout = makePart(model, Vector3.new(1.8, 1.2, 0.8), SNOUT)
	local eyeL = makePart(model, Vector3.new(0.5, 0.5, 0.2), DARK)
	local eyeR = makePart(model, Vector3.new(0.5, 0.5, 0.2), DARK)
	local legs = {}
	local legOffsets = { { -1.2, 2.2 }, { 1.2, 2.2 }, { -1.2, -2.2 }, { 1.2, -2.2 } }
	for i = 1, 4 do
		legs[i] = makePart(model, Vector3.new(1.2, 2, 1.2), PINK)
	end

	local clock = opts.time or function()
		return workspace:GetServerTimeNow()
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }

	local seed = opts.seed
	local home: Vector3 = opts.home
	local lastGround: number? = nil
	local lastX, lastZ = home.X, home.Z
	local stopped = false

	local function update()
		if stopped then
			return
		end
		local t = clock()
		local ox, oz, heading, walking = Pig.pathAt(seed, t)
		local x, z = home.X + ox, home.Z + oz
		local origin = Vector3.new(x, (lastGround or home.Y) + 400, z)
		local hit = workspace:Raycast(origin, Vector3.new(0, -900, 0), params)
		if hit and hit.Material == Enum.Material.Water then
			x, z = lastX, lastZ -- never walk into water: stand where we are
			hit = workspace:Raycast(Vector3.new(x, (lastGround or home.Y) + 400, z), Vector3.new(0, -900, 0), params)
		end
		if not hit then
			model.Parent = nil -- the terrain here is not loaded yet
			return
		end
		lastX, lastZ = x, z
		local ground = hit.Position.Y
		lastGround = if lastGround then lastGround + (ground - lastGround) * 0.4 else ground
		local cf = CFrame.new(x, lastGround :: number, z) * CFrame.Angles(0, heading, 0)
		local bodyCf = cf * CFrame.new(0, 3.2, 0)
		body.CFrame = bodyCf
		head.CFrame = bodyCf * CFrame.new(0, 0.6, 4.2)
		snout.CFrame = bodyCf * CFrame.new(0, 0.2, 5.9)
		eyeL.CFrame = bodyCf * CFrame.new(-0.9, 1.1, 5.75)
		eyeR.CFrame = bodyCf * CFrame.new(0.9, 1.1, 5.75)
		local swing = if walking then math.sin(t * 7) * 0.6 else 0
		for i, off in legOffsets do
			local s = if (i == 1 or i == 4) then swing else -swing
			legs[i].CFrame = bodyCf * CFrame.new(off[1], -1.5, off[2]) * CFrame.Angles(s, 0, 0) * CFrame.new(0, -1, 0)
		end
		if model.Parent == nil then
			model.Parent = workspace
		end
	end

	local connection = RunService.Heartbeat:Connect(update)
	update()
	return {
		model = model,
		update = update,
		stop = function()
			stopped = true
			connection:Disconnect()
			model:Destroy()
		end,
	}
end

return Pig
