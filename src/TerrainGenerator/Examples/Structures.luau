--!strict
-- Example structures for TerrainGenerator.RegisterStructure:
--
--     for _, structure in require(TerrainGenerator.Examples.Structures) do
--         TerrainGenerator.RegisterStructure(structure)
--     end
--
-- A structure is a placement rule plus either a `Model` (any Model / Part you cloned from ServerStorage; it is
-- stood on the ground) or a `Build(ctx)` function that creates whatever you like and parents it to ctx.Parent.
-- Build runs on the server main thread for every placed structure, so keep it cheap (tens of parts, not thousands).
--
-- Using a model instead of code:
--     TerrainGenerator.RegisterStructure({
--         Name = "Hut", Model = game.ServerStorage.Hut, Spacing = 16, Biomes = { "plains", "forest" },
--     })
--
-- ctx fields: Name, Position (ground point, studs), CFrame (Position + rotation), Rotation (degrees), Seed,
-- Random (Random.new(Seed): same structure -> same variation every time), Biome, Chunk (Vector2), Parent, Terrain, Model.

local function part(parent: Instance, cf: CFrame, size: Vector3, material: Enum.Material, color: Color3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Material = material
	p.Color = color
	p.Parent = parent
	return p
end

return {
	{
		Name = "Watchtower",
		Spacing = 20, -- about one tower per 20x20 chunks (1280 studs square) ...
		Separation = 8, -- ... never closer than 8 chunks to another tower
		Chance = 0.8,
		Biomes = { "plains", "meadow", "forest", "taiga", "savanna", "sunflower_plains" },
		Placement = "Land",
		MaxSlope = 3,
		Build = function(ctx)
			local grey, wood = Color3.fromRGB(125, 125, 125), Color3.fromRGB(110, 80, 50)
			-- shaft (sunk 8 studs into the ground so it never floats on a slope), platform, four parapet posts
			part(ctx.Parent, ctx.CFrame * CFrame.new(0, 20, 0), Vector3.new(16, 56, 16), Enum.Material.Cobblestone, grey)
			part(ctx.Parent, ctx.CFrame * CFrame.new(0, 50, 0), Vector3.new(28, 4, 28), Enum.Material.WoodPlanks, wood)
			for _, corner in { { -12, -12 }, { 12, -12 }, { -12, 12 }, { 12, 12 } } do
				part(ctx.Parent, ctx.CFrame * CFrame.new(corner[1], 56, corner[2]), Vector3.new(4, 8, 4), Enum.Material.WoodPlanks, wood)
			end
		end,
	},
	{
		Name = "DesertRuins",
		Spacing = 12,
		Separation = 4,
		Chance = 0.6,
		Biomes = { "desert" },
		Placement = "Land",
		MaxSlope = 4,
		Build = function(ctx)
			local sand = Color3.fromRGB(216, 203, 152)
			-- a ring of broken pillars; ctx.Random makes every ruin different but always the same ruin per seed
			for i = 1, 6 do
				local angle = i / 6 * math.pi * 2
				local height = 8 + ctx.Random:NextNumber() * 20
				local offset = CFrame.new(math.cos(angle) * 18, height / 2 - 4, math.sin(angle) * 18)
				part(ctx.Parent, ctx.CFrame * offset, Vector3.new(6, height, 6), Enum.Material.Sandstone, sand)
			end
		end,
	},
}
