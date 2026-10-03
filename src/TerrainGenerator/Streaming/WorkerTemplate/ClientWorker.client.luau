--!strict
-- Client worker stub: the logic lives in Streaming/WorkerMain (shared with the server worker).
local actor = script:GetActor()
if actor == nil then
	return -- the disabled template in the module tree
end
local modules = actor:FindFirstChild("Modules") :: ObjectValue
require((modules.Value :: any).Streaming.WorkerMain)(script)
