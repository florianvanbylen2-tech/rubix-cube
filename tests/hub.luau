--@include roblox_mock.luau
-- The spawn hall: building, safe zone (force field, no deaths, health undone), and King Jeffry's lightning for
-- attackers (explicit reports, creator-tagged damage, tool swings).
local SpawnHub = require(TG.Runtime.SpawnHub)
local Config = require(TG.Config)
local function check(cond, msg) if not cond then error("FAILED: " .. msg, 2) end end
local function run(seconds) for _ = 1, seconds * 5 do MOCK.heartbeat(0.2); MOCK.advance(0.2) end end

local center = Vector3.new(1000, 700, 1000)
local remote = Instance.new("RemoteEvent")
remote.Name = "KingStrike"
local hub = SpawnHub.start({ Config = Config, center = center, strikeRemote = remote, clock = MOCK.now })

-- ---------------------------------------------------------------- the building
local model = workspace:FindFirstChild("SpawnHub")
check(model ~= nil and #model:GetChildren() > 40, "hall not built")
local floor
for _, p in model:GetChildren() do if p.Name == "Floor" then floor = p end end
check(floor and floor.Position.Y + floor.Size.Y / 2 == center.Y, "the floor's top must be at the spawn height")
local names = {}
for _, p in model:GetChildren() do names[p.Name] = true end
check(names.Wall and names.Roof and names.Tower and names.ThroneSeat and names.Sign and names.Lintel, "hall parts missing")
print("hall: " .. #model:GetChildren() .. " parts, floor top at the spawn height")

-- ---------------------------------------------------------------- players
local function spawnPlayer(id, x, z)
	local p = MOCK.newPlayer(id, x, z)
	p:LoadCharacter()
	local root = p.Character:FindFirstChild("HumanoidRootPart")
	root.Position = Vector3.new(x, center.Y + 3, z)
	return p, root, p.Character:FindFirstChild("Humanoid")
end
local victim, vRoot, vHum = spawnPlayer(1, 1000, 1000)      -- inside the hall
local attacker, aRoot, aHum = spawnPlayer(2, 1060, 1000)    -- outside (the safe zone ends at 1000 + 28 + 8 = 1036)
local bystander, bRoot, bHum = spawnPlayer(3, 1200, 1200)   -- far away
run(1)
check(hub.isInside(victim) and not hub.isInside(attacker) and not hub.isInside(bystander), "zone membership")
check(victim:GetAttribute("InSafeZone") == true and attacker:GetAttribute("InSafeZone") ~= true, "InSafeZone attribute")
check(victim.Character:FindFirstChild("SafeZoneForceField") ~= nil and attacker.Character:FindFirstChild("SafeZoneForceField") == nil, "force field only for players inside")
check(vHum._states.Dead == false, "nobody can die inside the safe zone")
print("zone: inside player protected (force field, cannot die), outside players untouched")

-- ---------------------------------------------------------------- reported attack
check(hub.reportAttack(attacker, victim) == true, "an attack on a protected player must be blocked")
check(aHum.Health == 60, "lightning should do 40 damage, health is " .. aHum.Health)
check(vHum.Health == 100, "the victim must be unharmed")
check(workspace:FindFirstChild("KingsLightning") ~= nil, "lightning missing")
local decree
for _, d in aRoot._children do if d.Name == "KingsDecree" then decree = d end end
check(decree and decree._children[1].Text == "King Jeffry strikes down Player!", "decree text: " .. tostring(decree and decree._children[1].Text))
check(MOCK.fired and MOCK.fired[#MOCK.fired][1] == "KingStrike", "clients must be told so Jeffry can look")
check(aHum.PlatformStand == true and aRoot.AssemblyLinearVelocity.Y > 0, "stun and knockback")
-- cooldown
check(hub.reportAttack(attacker, victim) == true and aHum.Health == 60, "no second strike inside the cooldown")
run(4)
check(workspace:FindFirstChild("KingsLightning") == nil and aHum.PlatformStand == false, "lightning and stun clean up")
hub.reportAttack(attacker, victim)
check(aHum.Health == 20, "after the cooldown the next attack is struck again, health " .. aHum.Health)
-- attacks between players outside are none of the king's business
check(hub.reportAttack(attacker, bystander) == false, "attacks outside the zone are not blocked")
check(hub.reportAttack(victim, victim) == false, "self harm is not an attack")
print("reportAttack: blocked, attacker struck (damage, decree, stun, knockback), cooldown, outside = ignored")

-- ---------------------------------------------------------------- health loss inside the zone is undone
run(4)
aHum.Health = 100
local tag = Instance.new("ObjectValue")
tag.Name = "creator"
tag.Value = attacker
tag.Parent = vHum
vHum.Health = 30                       -- somebody's weapon damaged the victim directly
check(vHum.Health == 100, "damage inside the zone must be undone, health " .. vHum.Health)
check(aHum.Health == 60, "the creator of the damage is struck, health " .. aHum.Health)
bHum.Health = 50                       -- far away: ordinary damage
check(bHum.Health == 50, "damage outside the zone is normal")
print("health loss: undone for the protected, tagged attacker struck")

-- ---------------------------------------------------------------- tool swings
run(4)
aHum.Health = 100
local tool = Instance.new("Tool")
tool.Name = "Sword"
tool.Parent = attacker.Character
aRoot.Position = Vector3.new(1036, center.Y + 3, 1000)         -- 36 studs away: out of reach
tool._signals.Activated:Fire()
check(aHum.Health == 100, "a swing out of reach is harmless")
aRoot.Position = Vector3.new(1008, center.Y + 3, 1000)         -- 8 studs from the victim (inside the zone too)
run(1)
tool._signals.Activated:Fire()
check(aHum.Health == 60, "swinging a tool next to somebody in the safe zone is an attack, health " .. aHum.Health)
print("tool swing: struck when it is aimed at somebody in the hall")

-- ---------------------------------------------------------------- inside attackers keep 1 HP; leaving removes protection
run(4)
hub.reportAttack(attacker, victim)           -- 60 -> 20
run(4)
hub.reportAttack(attacker, victim)           -- would be -20
check(aHum.Health == 1, "a protected attacker is struck but not killed, health " .. aHum.Health)
vRoot.Position = Vector3.new(1300, center.Y + 3, 1300)
run(1)
check(not hub.isInside(victim) and victim.Character:FindFirstChild("SafeZoneForceField") == nil and vHum._states.Dead == true, "leaving the zone removes the protection")
print("hub OK")
hub.stop()
