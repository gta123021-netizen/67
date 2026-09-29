--[[
	blood_test.lua - runs CombatBlood + BloodPools (+ CombatVFX, CombatConfig) against rbxmock:
	every blood profile, wounds on still / running / flung parts, blood on a wall, under a ceiling
	and at a ledge, the budgets, and that it all cleans itself up.

	  luaurun tools/tests/blood_test.lua <repo root>
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
-- the effects the blood plays (as the place has them: an Attachment of emitters with EmitCount)
local vfx = M.folder(combat, "VFX")
local EFFECTS = {
	Blood = { "Blood1", "Blood2", "Blood3" }, BloodHeavy = { "Blood-01", "Blood-02" },
	BloodWound = { "Drops", "Mist", "Splat" }, BloodJet = { "Drops", "Puffs" }, BloodStream = { "Drops", "Stream" },
	BloodGush = { "Drops", "Puffs" }, BloodBleed = { "Drops" }, BloodDrip = { "Drops" },
	BloodSplatter = { "Puffs", "Drops" }, BloodSplatterWild = { "Puffs", "Drops" }, BloodStrand = { "Strands" },
	BloodSplash = { "Splash" }, BloodBurst = { "Cloud", "Drops", "Haze" }, BloodPunch = { "Splat", "SplatBig" },
	BloodSpatter = { "Flat", "Drops" }, BloodDisperse = { "Bloom", "Cloud" },
}
for name, emitters in pairs(EFFECTS) do
	local a = Instance.new("Attachment")
	a.Name = name
	for _, e in ipairs(emitters) do
		local pe = Instance.new("ParticleEmitter")
		pe.Name = e
		pe.Enabled = false
		pe:SetAttribute("EmitCount", 5)
		pe.Lifetime = NumberRange.new(0.3, 0.8)
		pe.Parent = a
	end
	a.Parent = vfx
end

local Config = require(combat.CombatConfig)
local Blood = require(combat.CombatBlood)
local Pools = require(combat.BloodPools)

local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	else
		print("ok   " .. msg)
	end
end

-- a victim
local dummy, hum = M.r6("Dummy", Vector3.new(0, 3, 0))
Blood.Ignore(dummy)
local torso = dummy.Torso

---------------------------------------------------------------------------
print("-- every profile, many times")
for name in pairs(Config.Blood.Profiles) do
	for i = 1, 6 do
		local drive = Vector3.new(math.random() - 0.5, 0, -1).Unit
		Blood.Spray(torso.Position + Vector3.new(0, 0.6, 0.6), drive, name, dummy, if i % 2 == 0 then 1 else -1, {
			Damage = 2 + i, Health = 1 - i / 7, Push = { Time = 0.3, Delay = 0.05 }, Launched = i == 6,
		})
		M.run(0.05)
	end
end
-- the old tier name still works
Blood.Spray(torso.Position, Vector3.new(0, 0, -1), "Body", dummy, 1)
Blood.Spray(torso.Position, Vector3.new(0, 0, -1), "NoSuchProfile", nil, nil)
M.run(3)
local st = Pools.Stats()
print(string.format("   cells %d walls %d specks %d parts %d  emitted %d  rays %d", st.Cells, st.Walls, st.Specks, st.Parts, M.Emitted or 0, M.Rays))
check(st.Cells > 20, "blood pooled on the floor")
check(st.Cells <= Config.Blood.Pool.MaxCells, "within the cell budget")
check((M.Emitted or 0) > 0, "the place's effects played")
check((M.Warnings or 0) == 0, "no warnings")

---------------------------------------------------------------------------
print("-- stains: on the struck part and the fist that struck, welded on, within budget")
local function stainsOn(model)
	local n, per, bad = 0, {}, 0
	for _, x in ipairs(model:GetDescendants()) do
		if x.Name == "BloodStain" then
			n += 1
			per[x.Parent] = (per[x.Parent] or 0) + 1
			local w = x:FindFirstChildOfClass("Weld")
			if not (w and w.Part0 == x.Parent and w.Part1 == x) or x.Anchored or x.CanCollide or x.CanQuery or x.CanTouch or x.Archivable ~= false then
				bad += 1
			end
			-- (on its host's surface: its centre within the host's box grown by a hair)
			local rel = x.Parent.CFrame:PointToObjectSpace(x.Parent.CFrame * w.C0.Position)
			local h = x.Parent.Size * 0.5 + Vector3.new(0.02, 0.02, 0.02)
			if math.abs(rel.X) > h.X or math.abs(rel.Y) > h.Y or math.abs(rel.Z) > h.Z then
				bad += 1
			end
		end
	end
	local most = 0
	for _, c in pairs(per) do
		most = math.max(most, c)
	end
	return n, most, bad
end
local fighter = M.r6("Fighter", Vector3.new(0, 3, 2.2))
Blood.Ignore(fighter)
for i = 1, 30 do
	-- (the fist at the contact point)
	fighter["Right Arm"].CFrame = CFrame.new(torso.Position + Vector3.new(0.3, 0.2, 1.4))
	Blood.Spray(torso.Position + Vector3.new(0, 0.2, 0.55), Vector3.new(0, 0, -1), if i % 3 == 0 then "Heavy" else "Light", dummy, 1, {
		Damage = 5, Health = 0.4, Striker = fighter, Limbs = { "Right Arm" },
	})
	M.run(0.1)
end
M.run(2)
local sn, smost, sbad = stainsOn(dummy)
local fn = stainsOn(fighter)
print(string.format("   on the victim %d (most on one part %d), on the fighter %d, bad %d", sn, smost, fn, sbad))
check(sn > 3, "the struck body is stained")
check(fn > 0, "the fist that struck is stained")
check(smost <= Config.Blood.StainsPerPart, "within StainsPerPart")
check(sbad == 0, "every stain welded on, inert, not copied, on its part")
-- hidden with its part
dummy.Head.LocalTransparencyModifier = 1
local hiddenOk = true
for _, x in ipairs(dummy.Head:GetChildren()) do
	if x.Name == "BloodStain" and x.LocalTransparencyModifier < 1 then
		hiddenOk = false
	end
end
dummy.Head.LocalTransparencyModifier = 0
check(hiddenOk, "a hidden part hides its stains")
-- carried over to a copy
local copyArm = Instance.new("Part")
copyArm.Size = fighter["Right Arm"].Size
copyArm.CFrame = fighter["Right Arm"].CFrame
copyArm.Parent = workspace
Blood.Carry(fighter["Right Arm"], copyArm)
local moved = 0
for _, x in ipairs(copyArm:GetChildren()) do
	if x.Name == "BloodStain" and x:FindFirstChildOfClass("Weld").Part0 == copyArm then
		moved += 1
	end
end
check(moved > 0, "Blood.Carry moved the arm's stains to its copy (" .. moved .. ")")
copyArm:Destroy()

---------------------------------------------------------------------------
print("-- blood into the pond clouds in the water; fast drops throw off tiny ones")
local disp0 = (M.EmitsBy or {})["BloodDisperse/Cloud"] or 0
for _ = 1, 12 do
	Blood.Launch(Vector3.new(-7, 3, 16), Vector3.new(0, -8, 0), 0.12, "Blob")
	M.run(0.4)
end
check(((M.EmitsBy or {})["BloodDisperse/Cloud"] or 0) > disp0, "the water took the blood in (BloodDisperse)")
for _ = 1, 20 do
	Blood.Launch(Vector3.new(4, 2, -4), Vector3.new(18, -14, 0), 0.13, "Drop")
end
M.run(2)
check((M.Warnings or 0) == 0, "no warnings")

---------------------------------------------------------------------------
print("-- a wound on a still body: gushes, heartbeat, ooze")
local stumpPart = Instance.new("Part")
stumpPart.Name = "Stump"
stumpPart.Anchored = true
stumpPart.Size = Vector3.new(1, 1, 1)
stumpPart.CFrame = CFrame.new(3, 4, 3)
stumpPart.Parent = dummy
local att = Instance.new("Attachment")
att.CFrame = CFrame.Angles(0, 0, -math.pi / 2) -- pointing out sideways
att.Parent = stumpPart
local before = M.Emitted or 0
local h = Blood.Wound(att, { Strength = 1.25, Pump = 8, Ooze = 6, Delay = 0.4, Gushes = 3, Body = dummy })
M.run(9)
check((M.Emitted or 0) > before, "the wound played the jet / stream / gush effects")
local st2 = Pools.Stats()
check(st2.Cells > st.Cells or st2.Cells > 20, "the wound's blood pooled")
print("   emits by effect:")
local keys = {}
for k in pairs(M.EmitsBy or {}) do
	table.insert(keys, k)
end
table.sort(keys)
for _, k in ipairs(keys) do
	print(string.format("     %-28s %d", k, M.EmitsBy[k]))
end

---------------------------------------------------------------------------
print("-- a wound on a body running at 22 studs/s, then flung up")
local runner = Instance.new("Part")
runner.Name = "Runner"
runner.Anchored = true
runner.Size = Vector3.new(2, 2, 1)
runner.CFrame = CFrame.new(-5, 3, -5)
runner.AssemblyLinearVelocity = Vector3.new(22, 0, 0)
runner.Parent = workspace
local ra = Instance.new("Attachment")
ra.Parent = runner
Blood.Wound(ra, { Strength = 1, Pump = 3, Ooze = 1, Delay = 0.1, Gushes = 2 })
for i = 1, 90 do
	runner.CFrame = runner.CFrame + Vector3.new(22 / 60, 0, 0)
	if i == 45 then
		runner.AssemblyLinearVelocity = Vector3.new(10, 40, 0)
	end
	M.step(1 / 60)
end
runner:Destroy()
M.run(2)
check((M.Warnings or 0) == 0, "no warnings with a moving wound")

---------------------------------------------------------------------------
print("-- drops onto the wall, under the ceiling, at the step's edge")
for _ = 1, 30 do
	Blood.Launch(Vector3.new(7, 4, math.random() * 4 - 2), Vector3.new(25, math.random() * 6, 0), 0.12, "Drop")
end
for _ = 1, 10 do
	Blood.Launch(Vector3.new(23, 3, 0), Vector3.new(0, 30, 0), 0.1, "Drop")
end
for _ = 1, 20 do
	Blood.Launch(Vector3.new(-12.2, 3, math.random() * 2), Vector3.new(0.5, -5, 0), 0.14, "Blob")
end
M.run(4)
check((M.Warnings or 0) == 0, "no warnings on walls / ceilings / edges")

---------------------------------------------------------------------------
print("-- splashes")
Blood.Splash(Vector3.new(2, 0.5, 6), 1)
Blood.Splash(Vector3.new(-16, 1.5, 0), 0.5)
Blood.Splash(Vector3.new(100, 50, 100), 1) -- (nothing under it)
M.run(1)

---------------------------------------------------------------------------
print("-- the budget: a flood of blood")
for _ = 1, 40 do
	Blood.Spray(Vector3.new(math.random(-20, 20), 2, math.random(-20, 20)), Vector3.new(0, 0, -1), "Finisher", nil, 0, { Damage = 9 })
	M.run(0.1)
end
M.run(3)
local st3 = Pools.Stats()
print(string.format("   cells %d walls %d specks %d parts %d", st3.Cells, st3.Walls, st3.Specks, st3.Parts))
check(st3.Cells <= Config.Blood.Pool.MaxCells, "cells stay within MaxCells")
check(st3.Specks <= Config.Blood.Pool.MaxSpecks, "specks stay within MaxSpecks")
local drops = 0
for _, c in ipairs(workspace.CombatBlood:GetChildren()) do
	if c.Name == "BloodDrop" then
		drops += 1
	end
end
check(drops <= Config.Blood.MaxDrops, "droplets within MaxDrops (" .. drops .. ")")

---------------------------------------------------------------------------
print("-- one colour: every drop and pool piece in view is Config.Blood.Color (the edge Config.Blood.Pool.Rim)")
local off = 0
for _, c in ipairs(workspace.CombatBlood:GetChildren()) do
	if c:IsA("BasePart") and c.CFrame.Position.Y > -1000 then
		local col = c.Color
		if not (col == Config.Blood.Color or col == Config.Blood.Pool.Rim) then
			off += 1
		end
		if c.Reflectance ~= 0 then
			off += 1
		end
	end
end
check(off == 0, "no other shade, no shine (" .. off .. " off)")
print("-- everything soaks away and the steppers stop")
h.Stop()
M.run(Config.Blood.Pool.Life + Config.Blood.Pool.Fade + 30, 1 / 20)
local st4 = Pools.Stats()
print(string.format("   cells %d walls %d specks %d  heartbeat conns %d  pending tasks %d", st4.Cells, st4.Walls, st4.Specks, M.heartbeatConns(), M.pendingTasks()))
check(st4.Cells == 0, "every pool soaked away")
check(st4.Specks == 0, "every speck gone")
check(M.heartbeatConns() == 0, "no Heartbeat connection left running")
check((M.Warnings or 0) == 0, "no warnings at all")
local parts = #workspace.CombatBlood:GetChildren()
print("   parts kept for reuse: " .. parts)

print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
if failures > 0 then
	error("blood test failed")
end
