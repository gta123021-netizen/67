--[[
	pool_shape_test.lua - draws the liquid a bleeding wound and a few blows leave on the floor as
	text (one character per cell: . a little, o half, O full, # full and inside the pool), so the
	shape can be looked at: one joined puddle, an uneven edge, no stacking.
	  luaurun tools/tests/pool_shape_test.lua <repo root>
]]
local ROOT = ARGS[2] or "."
local M = loadchunk(readfile(ROOT .. "/tools/tests/rbxmock.lua"), "rbxmock")()
local RS = game:GetService("ReplicatedStorage")
local combat = M.folder(RS, "Combat")
local function src(name)
	return ROOT .. "/src/ReplicatedStorage__Combat__" .. name .. ".lua"
end
M.module(combat, "CombatConfig", src("CombatConfig"))
M.module(combat, "CombatVFX", src("CombatVFX"))
M.module(combat, "BloodPools", src("BloodPools"))
M.module(combat, "CombatBlood", src("CombatBlood"))
M.folder(combat, "VFX")
local Blood = require(combat.CombatBlood)
local Pools = require(combat.BloodPools)
math.randomseed(tonumber(ARGS[3]) or 7)

local CELL = require(combat.CombatConfig).Blood.Pool.Cell
local CAP = CELL * CELL
local function grid(cells, title, key)
	local mi, ma, mj, mb = math.huge, -math.huge, math.huge, -math.huge
	local at = {}
	for _, c in ipairs(cells) do
		mi, ma = math.min(mi, c.I), math.max(ma, c.I)
		mj, mb = math.min(mj, c.J), math.max(mb, c.J)
		at[c.I .. "," .. c.J] = c
	end
	print(string.format("%s: %d cells  i %d..%d j %d..%d", title, #cells, mi, ma, mj, mb))
	if #cells == 0 or ma - mi > 100 then
		return
	end
	for j = mj, mb do
		local row = {}
		for i = mi, ma do
			local c = at[i .. "," .. j]
			local ch = " "
			if c then
				local f = math.min(1, c.Area / CAP)
				ch = if f < 0.2 then "." elseif f < 0.6 then "o" elseif not c.Edge then "#" else "O"
			end
			table.insert(row, ch)
		end
		print("  |" .. table.concat(row) .. "|")
	end
end
local function dump(title)
	print("== " .. title)
	local d = Pools.Debug()
	grid(d.Ground, "ground", nil)
	for _, s in ipairs(d.Walls) do
		local cells = {}
		for _, c in pairs(s.Cells) do
			table.insert(cells, c)
		end
		grid(cells, "wall N=" .. tostring(s.N))
	end
end

-- a stump bleeding over one spot for 8 s (the body standing still)
local part = Instance.new("Part")
part.Anchored = true
part.Size = Vector3.new(1, 1, 1)
part.CFrame = CFrame.new(0, 4, 0)
part.Parent = workspace
local att = Instance.new("Attachment")
att.CFrame = CFrame.Angles(0, 0, -math.pi / 2)
att.Parent = part
Blood.Wound(att, { Strength = 1.25, Pump = 8, Ooze = 4, Delay = 0.4, Gushes = 3 })
M.run(4)
dump("a stump, 4 s in")
M.run(8)
dump("a stump, 12 s in")
-- a few blows a couple of studs away: separate spatters that grow into the pool
for i = 1, 8 do
	Blood.Spray(Vector3.new(4, 3, 1), Vector3.new(-1, 0, 0), if i % 2 == 0 then "Heavy" else "Light", nil, 1, { Damage = 5 })
	M.run(0.4)
end
M.run(3)
dump("with blows beside it")
-- blood down the wall
for _ = 1, 12 do
	Blood.Launch(Vector3.new(8, 5, math.random() - 0.5), Vector3.new(20, 2, 0), 0.14, "Blob")
end
M.run(3)
dump("and on the wall")
