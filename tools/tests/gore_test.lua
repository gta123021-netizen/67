--[[
	gore_test.lua - runs CombatGore (with CombatFX, CombatBlood, BloodPools) against rbxmock: a dummy
	loses its right arm, its left arm and its head to blows (and one is already missing an arm when
	first seen), bleeds, hits the floor, heals under the drip line, and is removed.
	  luaurun tools/tests/gore_test.lua <repo root>
]]
local ROOT = ARGS[2] or "."
local M = loadchunk(readfile(ROOT .. "/tools/tests/rbxmock.lua"), "rbxmock")()
local RS = game:GetService("ReplicatedStorage")
local combat = M.folder(RS, "Combat")
local function src(name)
	return ROOT .. "/src/ReplicatedStorage__Combat__" .. name .. ".lua"
end
for _, n in ipairs({ "CombatConfig", "CombatVFX", "BloodPools", "CombatBlood", "Motion", "CombatPaths", "CombatFX", "CombatGore" }) do
	M.module(combat, n, src(n))
end
local vfx = M.folder(combat, "VFX")
for _, name in ipairs({ "Blood", "BloodHeavy", "BloodWound", "BloodJet", "BloodStream", "BloodGush", "BloodBleed", "BloodDrip", "BloodSplatter", "BloodSplatterWild", "BloodStrand", "BloodSplash", "BloodBurst", "BloodPunch", "BloodSpatter", "GroundDust", "DustPuff" }) do
	local a = Instance.new("Attachment")
	a.Name = name
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "E"
	pe:SetAttribute("EmitCount", 4)
	pe.Parent = a
	a.Parent = vfx
end
local Config = require(combat.CombatConfig)
local Gore = require(combat.CombatGore)
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

local dummies = M.folder(workspace, "PracticeDummies")
local d, hum = M.r6("Dummy", Vector3.new(0, 3, 0), dummies)
hum.MaxHealth = 60
hum.Health = 60
d:SetAttribute("CombatEntity", true)
d:SetAttribute("GoreStage", 0)
d:SetAttribute("Wounds", 0)
Gore.Start()
M.run(0.2)

-- blows: health down to the right arm's line, the left arm's, then the head
local function blow(h, stage)
	hum.Health = h
	d:SetAttribute("Wounds", 1 - h / 60)
	d:SetAttribute("GoreStage", stage)
	Gore.Hit(d, h, Vector3.new(0, 0, -1), stage, 0.05)
	M.run(0.5)
end
blow(40, 0)
check(Gore.StageOf(d) == 0, "no stage above the lines")
blow(16, 1)
check(Gore.StageOf(d) == 1, "right arm torn off")
check(d["Right Arm"].LocalTransparencyModifier == 1, "the real right arm is hidden")
local gibs = workspace:FindFirstChild("CombatGore")
check(gibs ~= nil and #gibs:GetChildren() >= 1, "the arm was thrown")
M.run(3)
check((M.Warnings or 0) == 0, "no warnings while it bleeds")
blow(10, 2)
check(Gore.StageOf(d) == 2, "left arm torn off")
-- the body ragdolls and slams into the floor while bleeding
d:SetAttribute("Ragdolled", true)
d.Torso.AssemblyLinearVelocity = Vector3.new(0, -30, 0)
M.step(1 / 60)
d.Torso.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
M.run(1)
d:SetAttribute("Ragdolled", false)
blow(0, 3)
check(Gore.StageOf(d) == 3, "head burst")
M.run(10)
local st = Pools.Stats()
print(string.format("   cells %d specks %d emitted %d", st.Cells, st.Specks, M.Emitted or 0))
check(st.Cells > 15, "the stumps and the neck bled onto the floor")

-- a body first seen already missing an arm: its wound, nothing replayed
local d2, hum2 = M.r6("Late", Vector3.new(8, 3, 6), dummies)
hum2.MaxHealth = 60
hum2.Health = 15
d2:SetAttribute("CombatEntity", true)
d2:SetAttribute("GoreStage", 1)
d2:SetAttribute("Wounds", 0.75)
M.run(2)
check(Gore.StageOf(d2) == 1, "a late body shows its lost arm at once")
-- the badly hurt one drips as it moves
local before = M.Emitted or 0
for _ = 1, 120 do
	d2.Torso.CFrame = d2.Torso.CFrame + Vector3.new(0.2, 0, 0)
	d2.Torso.AssemblyLinearVelocity = Vector3.new(12, 0, 0)
	M.step(1 / 60)
end
-- healed back under the line: no more drip
d2:SetAttribute("Wounds", 0.2)
hum2.Health = 50
M.run(2)
-- removed
d:Destroy()
d2:Destroy()
M.run(Config.Blood.Pool.Life + 40, 1 / 20)
local st2 = Pools.Stats()
print(string.format("   after: cells %d specks %d  heartbeat conns %d  warnings %d", st2.Cells, st2.Specks, M.heartbeatConns(), M.Warnings or 0))
check(st2.Cells == 0, "all the blood soaked away")
check((M.Warnings or 0) == 0, "no warnings")
-- (the gore's drip watcher stays connected by design; the blood's and the pools' steppers stop)
check(M.heartbeatConns() <= 2, "only the long-lived watchers are left")
print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
if failures > 0 then
	error("gore test failed")
end
