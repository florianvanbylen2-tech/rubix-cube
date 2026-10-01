-- Roblox Stone Golem (builds itself from Parts, no assets needed)
-- Setup: Roblox Studio > ServerScriptService > Insert > Script > paste this.
-- Optional: put a Part named "GolemSpawn" in Workspace to choose where it appears.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AGGRO_RANGE = 70
local ATTACK_RANGE = 9
local ATTACK_DAMAGE = 25
local ATTACK_COOLDOWN = 1.5
local WALK_SPEED = 10
local MAX_HEALTH = 400

local STONE = Color3.fromRGB(110, 112, 118)
local DARK_STONE = Color3.fromRGB(78, 80, 86)
local MOSS = Color3.fromRGB(76, 120, 60)
local GLOW = Color3.fromRGB(255, 170, 40)

local function newPart(model, name, size, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.Slate
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- Decoration glued to a body part (offset is relative to that part)
local function decorate(model, base, name, size, offset, color, material)
	local p = newPart(model, name, size, color, material)
	p.CanCollide = false
	p.Massless = true
	p.CFrame = base.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = base
	w.Part1 = p
	w.Parent = p
	return p
end

local function joint(name, part0, part1, c0, c1)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = c0
	m.C1 = c1
	m.Parent = part0
	return m
end

local function buildGolem(spawnCFrame)
	local model = Instance.new("Model")
	model.Name = "Golem"

	local root = newPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), STONE)
	root.Transparency = 1
	local torso = newPart(model, "Torso", Vector3.new(6, 6, 3.5), STONE)
	local head = newPart(model, "Head", Vector3.new(3.2, 3, 3), DARK_STONE)
	local lArm = newPart(model, "Left Arm", Vector3.new(2.6, 7, 2.6), DARK_STONE)
	local rArm = newPart(model, "Right Arm", Vector3.new(2.6, 7, 2.6), DARK_STONE)
	local lLeg = newPart(model, "Left Leg", Vector3.new(2.8, 5, 2.8), DARK_STONE)
	local rLeg = newPart(model, "Right Leg", Vector3.new(2.8, 5, 2.8), DARK_STONE)

	root.CFrame = spawnCFrame
	model.PrimaryPart = root

	joint("RootJoint", root, torso, CFrame.new(), CFrame.new())
	joint("Neck", torso, head, CFrame.new(0, 3, 0), CFrame.new(0, -1.5, 0))
	local lShoulder = joint("Left Shoulder", torso, lArm, CFrame.new(-4.3, 3, 0), CFrame.new(0, 3.5, 0))
	local rShoulder = joint("Right Shoulder", torso, rArm, CFrame.new(4.3, 3, 0), CFrame.new(0, 3.5, 0))
	local lHip = joint("Left Hip", torso, lLeg, CFrame.new(-1.6, -3, 0), CFrame.new(0, 2.5, 0))
	local rHip = joint("Right Hip", torso, rLeg, CFrame.new(1.6, -3, 0), CFrame.new(0, 2.5, 0))

	-- Glowing eyes (front of head is -Z)
	decorate(model, head, "EyeL", Vector3.new(0.7, 0.5, 0.2), CFrame.new(-0.8, 0.3, -1.5), GLOW, Enum.Material.Neon)
	decorate(model, head, "EyeR", Vector3.new(0.7, 0.5, 0.2), CFrame.new(0.8, 0.3, -1.5), GLOW, Enum.Material.Neon)
	-- Brow + jaw
	decorate(model, head, "Brow", Vector3.new(3.4, 0.5, 0.5), CFrame.new(0, 0.9, -1.5), STONE)
	-- Glowing core crystal on chest
	decorate(model, torso, "Core", Vector3.new(1.6, 1.6, 0.6), CFrame.new(0, 0.5, -1.9) * CFrame.Angles(0, 0, math.rad(45)), GLOW, Enum.Material.Neon)
	-- Shoulder boulders
	decorate(model, torso, "PauldronL", Vector3.new(3.4, 2, 3.4), CFrame.new(-4.3, 3.6, 0), STONE)
	decorate(model, torso, "PauldronR", Vector3.new(3.4, 2, 3.4), CFrame.new(4.3, 3.6, 0), STONE)
	-- Fists
	decorate(model, lArm, "FistL", Vector3.new(3.4, 2.4, 3.4), CFrame.new(0, -3.8, 0), STONE)
	decorate(model, rArm, "FistR", Vector3.new(3.4, 2.4, 3.4), CFrame.new(0, -3.8, 0), STONE)
	-- Feet
	decorate(model, lLeg, "FootL", Vector3.new(3.4, 1, 4), CFrame.new(0, -2.3, -0.4), STONE)
	decorate(model, rLeg, "FootR", Vector3.new(3.4, 1, 4), CFrame.new(0, -2.3, -0.4), STONE)
	-- Moss patches
	decorate(model, torso, "MossBack", Vector3.new(4, 0.6, 2), CFrame.new(0, 3.1, 0.8), MOSS, Enum.Material.Grass)
	decorate(model, head, "MossHead", Vector3.new(2, 0.5, 1.6), CFrame.new(0.5, 1.6, 0.2), MOSS, Enum.Material.Grass)
	decorate(model, rArm, "MossArm", Vector3.new(2.8, 0.6, 1.4), CFrame.new(0, 1, 0.6), MOSS, Enum.Material.Grass)
	decorate(model, lLeg, "MossLeg", Vector3.new(3, 0.6, 1.5), CFrame.new(0, 0.5, 0.6), MOSS, Enum.Material.Grass)

	local light = Instance.new("PointLight")
	light.Color = GLOW
	light.Range = 14
	light.Brightness = 1.5
	light.Parent = model.Core

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = MAX_HEALTH
	humanoid.Health = MAX_HEALTH
	humanoid.WalkSpeed = WALK_SPEED
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.Parent = model

	model.Parent = Workspace
	root:SetNetworkOwner(nil)

	return model, humanoid, root, {
		lShoulder = lShoulder, rShoulder = rShoulder, lHip = lHip, rHip = rHip,
		lShoulderC0 = lShoulder.C0, rShoulderC0 = rShoulder.C0,
		lHipC0 = lHip.C0, rHipC0 = rHip.C0,
	}
end

local function nearestPlayer(position)
	local best, bestDist = nil, AGGRO_RANGE
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hum and hrp and hum.Health > 0 then
			local d = (hrp.Position - position).Magnitude
			if d < bestDist then
				best, bestDist = hrp, d
			end
		end
	end
	return best, bestDist
end

local function spawnGolem(spawnCFrame)
	local model, humanoid, root, j = buildGolem(spawnCFrame)
	local lastAttack = 0
	local attackUntil = 0
	local t = 0

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not model.Parent or humanoid.Health <= 0 then
			conn:Disconnect()
			task.delay(4, function() model:Destroy() end)
			return
		end

		-- AI: chase nearest player, smash when close
		local target, dist = nearestPlayer(root.Position)
		if target then
			if dist > ATTACK_RANGE - 2 then
				humanoid:MoveTo(target.Position)
			else
				humanoid:MoveTo(root.Position)
			end
			if dist <= ATTACK_RANGE and os.clock() - lastAttack >= ATTACK_COOLDOWN then
				lastAttack = os.clock()
				attackUntil = os.clock() + 0.5
				local hum = target.Parent:FindFirstChildOfClass("Humanoid")
				if hum then hum:TakeDamage(ATTACK_DAMAGE) end
			end
		end

		-- Animation (procedural, no Animation assets needed)
		local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
		t += dt * math.clamp(speed, 0, 14) * 0.6
		local swing = math.sin(t) * math.clamp(speed / 12, 0, 1) * 0.7

		j.lHip.C0 = j.lHipC0 * CFrame.Angles(swing, 0, 0)
		j.rHip.C0 = j.rHipC0 * CFrame.Angles(-swing, 0, 0)

		if os.clock() < attackUntil then
			-- both arms slam forward/down
			local k = 1 - (attackUntil - os.clock()) / 0.5
			local a = math.pi * 0.9 * math.sin(k * math.pi)
			j.lShoulder.C0 = j.lShoulderC0 * CFrame.Angles(math.pi - a, 0, 0)
			j.rShoulder.C0 = j.rShoulderC0 * CFrame.Angles(math.pi - a, 0, 0)
		else
			j.lShoulder.C0 = j.lShoulderC0 * CFrame.Angles(-swing * 0.6, 0, 0)
			j.rShoulder.C0 = j.rShoulderC0 * CFrame.Angles(swing * 0.6, 0, 0)
		end
	end)

	return model
end

local spawnPart = Workspace:FindFirstChild("GolemSpawn")
local spawnCFrame = spawnPart and (spawnPart.CFrame + Vector3.new(0, 10, 0)) or CFrame.new(0, 12, 0)
spawnGolem(spawnCFrame)
