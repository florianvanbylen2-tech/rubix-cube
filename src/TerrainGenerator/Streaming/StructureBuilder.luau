--!strict
-- Builds registered structures on the main thread when the worker reports a chunk as written, and removes them
-- again when that chunk unloads. A structure belongs to its *origin* chunk: it lives while that chunk is loaded.
--
-- Everything a structure creates should be parented to ctx.Parent (a Folder under Workspace.GeneratedStructures)
-- so unloading can clean it up. Terrain edits are possible (ctx.Terrain) but neighbouring chunks that have not
-- been written yet will overwrite them, so prefer Parts / Models.

local Settings = require(script.Parent.Parent.Data.Settings)

local MIN_Y = Settings.minY
local VOXEL = 4

local StructureBuilder = {}
StructureBuilder.__index = StructureBuilder

-- defs: { [name]: full user definition (with Model / Build / Offset) }
function StructureBuilder.new(defs: { [string]: any }, folderName: string, bedrockLevel: number)
	local root = workspace:FindFirstChild(folderName)
	if not root then
		local f = Instance.new("Folder")
		f.Name = folderName
		f.Parent = workspace
		root = f
	end
	return setmetatable({ defs = defs, root = root, byChunk = {} :: { [string]: { Instance } }, bedrockLevel = bedrockLevel }, StructureBuilder)
end

-- Clones def.Model and stands its bounding box on the ground point of `cf`.
local function placeModel(model: Instance, cf: CFrame, parent: Instance): Instance
	local clone = model:Clone()
	if clone:IsA("Model") then
		local boxCf, boxSize = clone:GetBoundingBox()
		local pivotToBox = clone:GetPivot():ToObjectSpace(boxCf)
		clone:PivotTo(cf * CFrame.new(0, boxSize.Y / 2, 0) * pivotToBox:Inverse())
	elseif clone:IsA("BasePart") then
		clone.CFrame = cf * CFrame.new(0, clone.Size.Y / 2, 0)
	end
	clone.Parent = parent
	return clone
end

local unloadChunk: (any, number, number) -> ()

function StructureBuilder.build(self: any, cx: number, cz: number, placements: { any })
	unloadChunk(self, cx, cz) -- never leave a previous build of this chunk behind
	local made: { Instance } = {}
	for _, p in placements do
		local def = self.defs[p.name]
		if def then
			local folder = Instance.new("Folder")
			folder.Name = string.format("%s_%d_%d", p.name, cx, cz)
			-- ground point: centre of the origin block column, on top of the highest solid block
			local pos = Vector3.new((p.x + 0.5) * VOXEL, self.bedrockLevel + (p.y - MIN_Y + 1) * VOXEL, (p.z + 0.5) * VOXEL)
			if def.Offset then
				pos += def.Offset
			end
			local cf = CFrame.new(pos) * CFrame.Angles(0, p.rot * math.pi / 2, 0)
			local ctx = {
				Name = p.name,
				Position = pos, -- studs, ground level at the structure origin
				CFrame = cf, -- Position, rotated by Rotation
				Rotation = p.rot * 90, -- degrees around Y
				Seed = p.seed, -- stable per structure: feed it to Random.new for deterministic variation
				Random = Random.new(p.seed),
				Biome = p.biome,
				Chunk = Vector2.new(cx, cz),
				Parent = folder,
				Terrain = workspace.Terrain,
				Model = nil :: Instance?,
			}
			local ok, err = pcall(function()
				if def.Model then
					ctx.Model = placeModel(def.Model, cf, folder)
				end
				if def.Build then
					def.Build(ctx)
				end
			end)
			if not ok then
				warn(string.format("[TerrainGenerator] structure %s at chunk (%d, %d) failed: %s", p.name, cx, cz, tostring(err)))
			end
			folder.Parent = self.root
			table.insert(made, folder)
		end
	end
	if #made > 0 then
		self.byChunk[cx .. "," .. cz] = made
	end
end

function StructureBuilder.unload(self: any, cx: number, cz: number)
	local key = cx .. "," .. cz
	local made = self.byChunk[key]
	if made then
		self.byChunk[key] = nil
		for _, inst in made do
			inst:Destroy()
		end
	end
end

unloadChunk = StructureBuilder.unload

return StructureBuilder
