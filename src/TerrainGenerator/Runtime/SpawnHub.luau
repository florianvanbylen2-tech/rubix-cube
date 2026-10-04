--!strict
-- The spawn hall: a stone building at the spawn point where everybody spawns. It is a SAFE ZONE, and King Jeffry
-- (the pig, drawn on every client by Mobs/Pig) punishes attackers with lightning.
--
-- Roblox has no built-in combat, so an "attack" is detected three ways:
--   1. TerrainGenerator.ReportAttack(attacker, victim): call it from your weapon scripts. (Most reliable.)
--   2. A player inside the zone loses health: the damage is undone and, if the humanoid carries the classic
--      `creator` ObjectValue tag, that player is the attacker.
--   3. A player activates a Tool while another player who is inside the zone stands within Strike.AttackRange
--      studs (melee swings: the damage is blocked by the force field anyway, the swing is what counts).
-- Everyone inside the zone gets an invisible ForceField (the engine ignores normal damage) and cannot die.
-- The attacker is struck by lightning: damage, knockback, a short stun and a decree above their head.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SpawnHub = {}

-- ---------------------------------------------------------------------------------------- building
local STONE = Color3.fromRGB(150, 150, 155)
local DARK = Color3.fromRGB(95, 95, 102)
local RED = Color3.fromRGB(170, 30, 40)
local GOLD = Color3.fromRGB(240, 190, 40)
local PURPLE = Color3.fromRGB(120, 50, 160)

local function part(parent: Instance, name: string, size: Vector3, center: Vector3, color: Color3, material: Enum.Material?, collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = center
	p.Color = color
	p.Material = material or Enum.Material.Cobblestone
	p.CanCollide = collide ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Builds the hall around `center` (the middle of the floor's TOP face). Returns the model and the floor top Y.
function SpawnHub.build(cfg: any, center: Vector3): (Model, number)
	local hub = cfg.SpawnHub
	local size = hub.Size
	local half = size / 2
	local wall = hub.WallHeight
	local floorY = center.Y
	local model = Instance.new("Model")
	model.Name = "SpawnHub"

	local function at(x: number, y: number, z: number): Vector3
		return Vector3.new(center.X + x, floorY + y, center.Z + z)
	end

	-- foundation reaches deep under the floor so the hall never floats on uneven ground
	part(model, "Foundation", Vector3.new(size + 8, 30, size + 8), at(0, -15 - 1, 0), DARK)
	part(model, "Floor", Vector3.new(size, 2, size), at(0, -1, 0), STONE, Enum.Material.Slate)
	part(model, "Carpet", Vector3.new(8, 0.3, size), at(0, 0.15, 0), RED, Enum.Material.Fabric, false)

	-- walls with a 14 stud gate in the middle of each side
	local gate, thick = 14, 3
	local seg = (size - gate) / 2
	for _, side in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local sx, sz = side[1], side[2]
		for _, s in { -1, 1 } do
			local along = s * (gate / 2 + seg / 2)
			local sizeV = if sx ~= 0 then Vector3.new(thick, wall, seg) else Vector3.new(seg, wall, thick)
			local pos = if sx ~= 0 then at(sx * (half - thick / 2), wall / 2, along) else at(along, wall / 2, sz * (half - thick / 2))
			part(model, "Wall", sizeV, pos, STONE)
		end
		-- lintel over the gate
		local lintel = if sx ~= 0 then Vector3.new(thick, wall - 12, gate) else Vector3.new(gate, wall - 12, thick)
		local lpos = if sx ~= 0 then at(sx * (half - thick / 2), 12 + (wall - 12) / 2, 0) else at(0, 12 + (wall - 12) / 2, sz * (half - thick / 2))
		part(model, "Lintel", lintel, lpos, DARK)
	end

	-- corner towers
	for _, cx in { -1, 1 } do
		for _, cz in { -1, 1 } do
			part(model, "Tower", Vector3.new(9, wall + 12, 9), at(cx * (half - 2), (wall + 12) / 2, cz * (half - 2)), DARK)
			part(model, "TowerTop", Vector3.new(11, 2, 11), at(cx * (half - 2), wall + 13, cz * (half - 2)), STONE)
		end
	end

	-- roof with a ring of battlements
	part(model, "Roof", Vector3.new(size, 2, size), at(0, wall + 1, 0), DARK)
	for i = -3, 3 do
		part(model, "Merlon", Vector3.new(4, 3, 2), at(i * 8, wall + 3.5, half - 1), STONE)
		part(model, "Merlon", Vector3.new(4, 3, 2), at(i * 8, wall + 3.5, -half + 1), STONE)
	end

	-- pillars along the carpet
	for _, z in { -16, -4, 8 } do
		for _, x in { -10, 10 } do
			part(model, "Pillar", Vector3.new(3, wall, 3), at(x, wall / 2, z), STONE, Enum.Material.Marble)
		end
	end

	-- the throne (north side, opposite the south gate): three steps, a seat and a tall back
	for step = 1, 3 do
		part(model, "ThroneStep", Vector3.new(18 - step * 3, 1.2, 12 - step * 2), at(0, step * 1.2 - 0.6, -half + 10), RED, Enum.Material.Fabric)
	end
	part(model, "ThroneSeat", Vector3.new(5, 2, 4), at(0, 3.6 + 1, -half + 8), GOLD, Enum.Material.Metal)
	part(model, "ThroneBack", Vector3.new(5, 9, 1.2), at(0, 3.6 + 4.5, -half + 6), GOLD, Enum.Material.Metal)
	part(model, "ThroneJewel", Vector3.new(2, 2, 0.6), at(0, 3.6 + 8, -half + 5.2), PURPLE, Enum.Material.Neon, false)

	-- lights
	for _, p in { { -12, -12 }, { 12, -12 }, { -12, 12 }, { 12, 12 }, { 0, 0 } } do
		local lamp = part(model, "Lamp", Vector3.new(2, 1, 2), at(p[1], wall - 0.5, p[2]), GOLD, Enum.Material.Neon, false)
		local light = Instance.new("PointLight")
		light.Range = 36
		light.Brightness = 1.2
		light.Parent = lamp
	end

	-- sign above the south gate
	local sign = part(model, "Sign", Vector3.new(26, 6, 1), at(0, wall + 6, half + 0.5), PURPLE, Enum.Material.Wood, false)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.format("SAFE ZONE - King %s's Hall", hub.KingName)
	label.TextScaled = true
	label.TextColor3 = GOLD
	label.Parent = gui

	model.Parent = workspace
	return model, floorY
end

-- ---------------------------------------------------------------------------------------- lightning
local function boltBetween(parent: Instance, a: Vector3, b: Vector3, width: number)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	local p = Instance.new("Part")
	p.Name = "Bolt"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(190, 220, 255)
	p.Size = Vector3.new(width, width, len)
	p.CFrame = CFrame.lookAt(mid, b)
	p.Parent = parent
end

-- A jagged bolt from the sky onto `target`, a flash and a decree above `head` (optional). Cleans itself up.
function SpawnHub.lightning(target: Vector3, decree: string?, head: BasePart?)
	local fx = Instance.new("Model")
	fx.Name = "KingsLightning"
	local random = Random.new(math.floor(target.X * 31 + target.Z * 17))
	local prev = target + Vector3.new(0, 260, 0)
	local segments = 9
	for i = 1, segments do
		local t = i / segments
		local base = target + Vector3.new(0, 260 * (1 - t), 0)
		local jitter = if i == segments then Vector3.zero else Vector3.new((random:NextNumber() - 0.5) * 22, 0, (random:NextNumber() - 0.5) * 22)
		local nextPoint = base + jitter
		boltBetween(fx, prev, nextPoint, 2.2)
		prev = nextPoint
	end
	local flash = Instance.new("Part")
	flash.Name = "Flash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Transparency = 1
	flash.Size = Vector3.new(1, 1, 1)
	flash.Position = target + Vector3.new(0, 4, 0)
	flash.Parent = fx
	local light = Instance.new("PointLight")
	light.Range = 90
	light.Brightness = 12
	light.Color = Color3.fromRGB(200, 225, 255)
	light.Parent = flash
	fx.Parent = workspace
	task.delay(0.45, function()
		fx:Destroy()
	end)

	if decree and head then
		local gui = Instance.new("BillboardGui")
		gui.Name = "KingsDecree"
		gui.Size = UDim2.fromOffset(300, 50)
		gui.StudsOffset = Vector3.new(0, 4, 0)
		gui.AlwaysOnTop = true
		gui.Adornee = head
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = decree
		text.TextScaled = true
		text.TextColor3 = Color3.fromRGB(255, 230, 90)
		text.TextStrokeTransparency = 0
		text.Parent = gui
		gui.Parent = head
		task.delay(3.5, function()
			gui:Destroy()
		end)
	end
end

-- ---------------------------------------------------------------------------------------- the safe zone
-- env: { Config, center = Vector3 (floor top), strikeRemote = RemoteEvent?, clock = (() -> number)? }
function SpawnHub.start(env: any): any
	local cfg = env.Config
	local hub = cfg.SpawnHub
	local strike = hub.Strike
	local center: Vector3 = env.center
	local model, floorY = SpawnHub.build(cfg, center)
	local limit = hub.Size / 2 + hub.SafeMargin

	local ctl: any = { model = model, floorY = floorY, center = center }
	local connections: { RBXScriptConnection } = {}
	local inside: { [Player]: boolean } = {}
	local lastHealth: { [Humanoid]: number } = {}
	local lastStrike: { [Player]: number } = {}
	local stopped = false
	local clock = env.clock or os.clock

	local function rootOf(player: Player): BasePart?
		local character = player.Character
		return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end

	local function humanoidOf(player: Player): Humanoid?
		local character = player.Character
		return character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	end

	function ctl.contains(position: Vector3): boolean
		return math.abs(position.X - center.X) <= limit and math.abs(position.Z - center.Z) <= limit
			and position.Y >= floorY - 12 and position.Y <= floorY + hub.WallHeight * 3
	end

	function ctl.isInside(player: Player): boolean
		return inside[player] == true
	end

	local function setProtected(player: Player, on: boolean)
		local character = player.Character
		if not character then
			return
		end
		local ff = character:FindFirstChild("SafeZoneForceField")
		if on and not ff then
			local f = Instance.new("ForceField")
			f.Name = "SafeZoneForceField"
			f.Visible = false
			f.Parent = character
		elseif not on and ff then
			ff:Destroy()
		end
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, not on)
			lastHealth[humanoid] = humanoid.Health
		end
	end

	local function refresh(player: Player)
		local root = rootOf(player)
		local now = root ~= nil and ctl.contains(root.Position)
		if now ~= (inside[player] == true) then
			inside[player] = now
			player:SetAttribute("InSafeZone", now)
			setProtected(player, now)
		end
	end

	-- the lightning
	local function punish(attacker: Player, _victim: Player)
		local t = clock()
		if stopped or attacker == victim or t - (lastStrike[attacker] or -1e9) < strike.Cooldown then
			return
		end
		lastStrike[attacker] = t
		local root = rootOf(attacker)
		local humanoid = humanoidOf(attacker)
		if not root or not humanoid then
			return
		end
		SpawnHub.lightning(root.Position - Vector3.new(0, 2.5, 0), string.format("King %s strikes down %s!", hub.KingName, attacker.Name), root)
		-- damage goes through Health directly: a force field does not stop that. A protected player keeps 1 HP.
		local newHealth = humanoid.Health - strike.Damage
		if inside[attacker] then
			newHealth = math.max(newHealth, 1)
		end
		lastHealth[humanoid] = newHealth
		humanoid.Health = newHealth
		local away = (root.Position - center) * Vector3.new(1, 0, 1)
		local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 0, 1)
		root.AssemblyLinearVelocity = Vector3.new(0, strike.Knockback * 0.8, 0) + dir * (strike.Knockback * 0.5)
		humanoid.PlatformStand = true
		task.delay(strike.StunSeconds, function()
			if humanoid.Parent then
				humanoid.PlatformStand = false
			end
		end)
		if env.strikeRemote then
			env.strikeRemote:FireAllClients(root.Position)
		end
	end

	-- 1. explicit reports from weapon scripts. Returns true when the attack was blocked by the safe zone.
	function ctl.reportAttack(attacker: Player, victim: Player): boolean
		refresh(victim)
		if attacker ~= victim and inside[victim] then
			punish(attacker, victim)
			return true
		end
		return false
	end

	-- 2. health loss inside the zone is undone; the creator tag names the attacker
	local function watchHumanoid(player: Player, humanoid: Humanoid)
		lastHealth[humanoid] = humanoid.Health
		table.insert(
			connections,
			humanoid.HealthChanged:Connect(function(health: number)
				local before = lastHealth[humanoid] or health
				if inside[player] and health < before - 0.01 then
					humanoid.Health = before -- undo
					local tag = humanoid:FindFirstChild("creator") :: ObjectValue?
					local attacker = tag and tag.Value
					if attacker and typeof(attacker) == "Instance" and attacker:IsA("Player") then
						punish(attacker, player)
					end
				else
					lastHealth[humanoid] = health
				end
			end)
		)
	end

	-- 3. a tool swing next to somebody who is in the zone
	local function watchTool(player: Player, tool: Instance)
		if not tool:IsA("Tool") then
			return
		end
		table.insert(
			connections,
			(tool :: any).Activated:Connect(function()
				local root = rootOf(player)
				if not root then
					return
				end
				for _, other in Players:GetPlayers() do
					local otherRoot = rootOf(other)
					if other ~= player and otherRoot and inside[other] and (otherRoot.Position - root.Position).Magnitude <= strike.AttackRange then
						punish(player, other)
						return
					end
				end
			end)
		)
	end

	local function watchPlayer(player: Player)
		local function onCharacter(character: Model)
			inside[player] = nil
			local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
			if humanoid then
				watchHumanoid(player, humanoid)
			end
			for _, child in character:GetChildren() do
				watchTool(player, child)
			end
			table.insert(
				connections,
				character.ChildAdded:Connect(function(child: Instance)
					watchTool(player, child)
				end)
			)
			local backpack = player:FindFirstChild("Backpack")
			if backpack then
				for _, child in backpack:GetChildren() do
					watchTool(player, child)
				end
				table.insert(
					connections,
					backpack.ChildAdded:Connect(function(child: Instance)
						watchTool(player, child)
					end)
				)
			end
		end
		table.insert(connections, player.CharacterAdded:Connect(onCharacter))
		if player.Character then
			onCharacter(player.Character)
		end
	end
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	table.insert(connections, Players.PlayerAdded:Connect(watchPlayer))
	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			inside[player] = nil
			lastStrike[player] = nil
		end)
	)

	local accumulator = 0
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt: number)
			accumulator += dt
			if accumulator < 0.2 then
				return
			end
			accumulator = 0
			for _, player in Players:GetPlayers() do
				refresh(player)
			end
		end)
	)

	function ctl.stop()
		stopped = true
		for _, c in connections do
			c:Disconnect()
		end
		model:Destroy()
	end

	return ctl
end

return SpawnHub
