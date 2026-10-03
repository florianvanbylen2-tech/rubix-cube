local LoadGovernor = require(TG.Streaming.LoadGovernor)
local g = LoadGovernor.new(4, 0.025)
local function run(dt, n) local l for _ = 1, n do for _ = 1, 15 do g:sample(dt) end l = g:step() end return l end
assert(run(1 / 60, 10) == 4, "healthy frames keep the full limit")
assert(run(0.05, 8) == 1, "slow frames (2x the target) back off to 1 job, never pause")
assert(run(0.08, 6) <= 1, "very slow frames pause generation (0) or let one job through")
local zeros, ones = 0, 0
for _ = 1, 32 do local l = run(0.2, 1) if l == 0 then zeros += 1 elseif l == 1 then ones += 1 end end
assert(zeros >= 24 and ones >= 3, "paused generation must still make progress now and then (zeros " .. zeros .. ", ones " .. ones .. ")")
local up = run(1 / 60, 2)
assert(up <= 2, "recovery must be gradual")
assert(run(1 / 60, 14) == 4, "recovers fully once frames are fine")
-- borderline frame time must not oscillate between limits
local lo, hi = 99, 0
for _ = 1, 40 do local l = run(0.02, 1) lo, hi = math.min(lo, l), math.max(hi, l) end
assert(hi - lo <= 1, "oscillation at the threshold")
print("governor OK")
