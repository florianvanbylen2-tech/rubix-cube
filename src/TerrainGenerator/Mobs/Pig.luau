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

local function point(seed: number, k: number, maxRadius: number): (number, number)
	local r = Xoroshiro.new(Int64.fromNumber(seed * 1000 + (k % 1000003)))
	local angle = r:nextDouble() * math.pi * 2
	local radius = math.sqrt(r:nextDouble()) * maxRadius
	return math.cos(angle) * radius, math.sin(angle) * radius
end

-- Offset from home (studs), heading (radians, 0 = +Z) and walking flag at time `t` (seconds).
function Pig.pathAt(seed: number, t: number, radius: number?): (number, number, number, boolean)
	local n = math.floor(t / Pig.PERIOD)
	local r = radius or Pig.RADIUS
	local x0, z0 = point(seed, n, r)
	local x1, z1 = point(seed, n + 1, r)
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

-- opts: { seed: number, home: Vector3 (ground point), time: (() -> number)?,
--         name: string? (a crowned king with a name tag), ground: number? (fixed floor height: no raycast),
--         radius: number? (wander radius in studs) }
function Pig.start(opts: any): any
	local RunService = game:GetService("RunService")
	local model = Instance.new("Model")
	model.Name = "Pig"
	local body = makePart(model, Vector3.new(4, 3, 6), PINK)
	local head = makePart(model, Vector3.new(3, 3, 3), PINK)
	local snout = makePart(model, Vector3.new(1.8, 1.2, 0.8), SNOUT)
	local eyeL = makePart(model, Vector3.new(0.5, 0.5, 0.2), DARK)
	local eyeR = makePart(model, Vector3.new(0.5, 0.5, 0.2), DARK)
	local crown: { Part } = {}
	if opts.name then
		local gold = Color3.fromRGB(240, 190, 40)
		crown[1] = makePart(model, Vector3.new(2.2, 0.6, 2.2), gold)
		for i = 1, 3 do
			crown[i + 1] = makePart(model, Vector3.new(0.5, 1, 0.5), gold)
		end
		local tag = Instance.new("BillboardGui")
		tag.Name = "NameTag"
		tag.Size = UDim2.fromOffset(220, 40)
		tag.StudsOffset = Vector3.new(0, 4.2, 0)
		tag.AlwaysOnTop = false
		tag.MaxDistance = 140
		tag.Adornee = head
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "King " .. tostring(opts.name)
		label.TextScaled = true
		label.TextColor3 = gold
		label.TextStrokeTransparency = 0
		label.Parent = tag
		tag.Parent = head
	end
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
	local lookAt: Vector3? = nil
	local lookUntil = 0
	local radius: number? = opts.radius

	local function update()
		if stopped then
			return
		end
		local t = clock()
		local ox, oz, heading, walking = Pig.pathAt(seed, t, radius)
		if lookAt and t < lookUntil then
			heading = math.atan2(lookAt.X - (home.X + ox), lookAt.Z - (home.Z + oz)) -- facing the culprit
			walking = false
		end
		local x, z = home.X + ox, home.Z + oz
		local ground: number
		if opts.ground then
			ground = opts.ground -- standing on a built floor (the spawn hall)
			lastX, lastZ = x, z
		else
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
			ground = hit.Position.Y
		end
		lastGround = if lastGround then lastGround + (ground - lastGround) * 0.4 else ground
		local cf = CFrame.new(x, lastGround :: number, z) * CFrame.Angles(0, heading, 0)
		local bodyCf = cf * CFrame.new(0, 3.2, 0)
		body.CFrame = bodyCf
		head.CFrame = bodyCf * CFrame.new(0, 0.6, 4.2)
		snout.CFrame = bodyCf * CFrame.new(0, 0.2, 5.9)
		eyeL.CFrame = bodyCf * CFrame.new(-0.9, 1.1, 5.75)
		eyeR.CFrame = bodyCf * CFrame.new(0.9, 1.1, 5.75)
		if #crown > 0 then
			local headCf = bodyCf * CFrame.new(0, 0.6, 4.2)
			crown[1].CFrame = headCf * CFrame.new(0, 1.8, 0)
			for i = 1, 3 do
				crown[i + 1].CFrame = headCf * CFrame.new((i - 2) * 0.8, 2.6, 0)
			end
		end
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
		-- turn to face a position for a few seconds (Jeffry watching a lightning strike)
		look = function(position: Vector3)
			lookAt = position
			lookUntil = clock() + 2.5
		end,
		stop = function()
			stopped = true
			connection:Disconnect()
			model:Destroy()
		end,
	}
end

return Pig
