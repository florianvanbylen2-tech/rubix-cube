--!strict
-- Adaptive load control: keeps generation from eating the frame. Fed with the server's frame time, it lowers the
-- number of concurrent chunk jobs when frames get slow and raises it again (up to `cap`) once they recover.
-- Pure logic so it can be tested without Roblox.

local LoadGovernor = {}
LoadGovernor.__index = LoadGovernor

-- cap: most jobs allowed in flight; targetSeconds: frame time above which we back off (e.g. 0.025 = 40 fps)
function LoadGovernor.new(cap: number, targetSeconds: number)
	return setmetatable({ cap = cap, target = targetSeconds, limit = cap, ema = 1 / 60, calm = 0 }, LoadGovernor)
end

-- dt: seconds of the last frame
function LoadGovernor.sample(self: any, dt: number)
	self.ema += (math.min(dt, 1) - self.ema) * 0.15
end

-- Call at a fixed interval; returns the current job limit.
function LoadGovernor.step(self: any): number
	if self.ema > self.target then
		self.limit = math.max(1, self.limit - 1)
		self.calm = 0
	elseif self.ema < self.target * 0.7 then
		self.calm += 1
		if self.calm >= 2 then -- two calm intervals in a row before ramping up again (avoids oscillation)
			self.limit = math.min(self.cap, self.limit + 1)
			self.calm = 0
		end
	end
	return self.limit
end

return LoadGovernor
