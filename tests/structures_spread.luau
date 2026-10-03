-- Prints Structures.potentialChunk for several seeds / rules; run_all diffs it against tests/structures_ref.py
local RandomState = require(TG.World.RandomState)
local Structures = require(TG.World.Structures)
local lines = {}
for _, seed in { 12345, -987654321, "-4172144997902289642" } do
	local sh, sl = RandomState.seedFrom(seed)
	local fake = { rs = RandomState.new(sh, sl), registry = { names = {} } }
	for _, d in { { "Village", 34, 8, 10387312, "linear" }, { "Tri", 32, 5, 1234567, "triangular" }, { "Tiny", 3, 1, 99, "linear" } } do
		local s = Structures.new(fake, { Structures.normalize(d[1], { Spacing = d[2], Separation = d[3], Salt = d[4], SpreadType = d[5] }) })
		for rx = -4, 4 do
			for rz = -4, 4 do
				local cx, cz = Structures.potentialChunk(s, s.defs[1], rx * d[2] + 1, rz * d[2])
				table.insert(lines, string.format("%s %s %d %d %d %d", tostring(seed), d[1], rx, rz, cx, cz))
			end
		end
	end
end
print(table.concat(lines, "\n"))
