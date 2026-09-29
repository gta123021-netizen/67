--[[
	server_test.lua - CombatService (the server) against rbxmock: two NPC fighters, one throwing a full
	string at the other (lights, the uppercut, the sweep), then the other hitting back - so applyHit,
	the stun, the knockback, the gore stages, the NPC reactions and the strike clips' hand-overs all
	run. Checks it runs clean and the victim takes the damage.
	  luaurun tools/tests/server_test.lua <repo root>
]]
local ROOT = ARGS[2] or "."
local M = loadchunk(readfile(ROOT .. "/tools/tests/rbxmock.lua"), "rbxmock")()
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local combat = M.folder(RS, "Combat")
for _, n in ipairs({ "CombatConfig", "CombatStates", "ComboRules", "Ragdoll", "Motion", "AnimController", "CombatChoreo", "CombatPaths", "HitDetect" }) do
	M.module(combat, n, ROOT .. "/src/ReplicatedStorage__Combat__" .. n .. ".lua")
end
local ev = Instance.new("RemoteEvent")
ev.Name = "CombatEvent"
ev.Parent = combat
local sc = M.folder(SSS, "Combat")
M.module(sc, "CombatService", ROOT .. "/src/ServerScriptService__Combat__CombatService.lua")
local Config = require(combat.CombatConfig)
local Service = require(sc.CombatService)

local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	else
		print("ok   " .. msg)
	end
end

local folder = M.folder(workspace, "PracticeDummies")
local a, ha = M.r6("Attacker", Vector3.new(0, 3, 0), folder)
local v, hv = M.r6("Victim", Vector3.new(0, 3, -3.4), folder)
-- facing each other
a.HumanoidRootPart.CFrame = CFrame.lookAt(Vector3.new(0, 3, 0), Vector3.new(0, 3, -5))
a.Torso.CFrame = a.HumanoidRootPart.CFrame
v.HumanoidRootPart.CFrame = CFrame.lookAt(Vector3.new(0, 3, -3.4), Vector3.new(0, 3, 5))
v.Torso.CFrame = v.HumanoidRootPart.CFrame
hv.MaxHealth = 60
hv.Health = 60
local ea = Service.Register(a, nil)
local evn = Service.Register(v, nil)
check(ea ~= nil and evn ~= nil, "both registered")

-- the string: press at every chain point
local hits0 = #ev.Fired
local presses = { "Light", "Light", "Heavy", "Light", "Light" }
for i, k in ipairs(presses) do
	local ok, action = Service.RequestAttack(a, { Kind = k })
	print(string.format("   press %d %-5s -> %s %s  (victim %s, %.1f hp)", i, k, tostring(ok), tostring(action), evn.State, hv.Health))
	-- wait for the chain point (the strike's own timing, hit-stop included)
	for _ = 1, 120 do
		M.step(1 / 60)
		if ea.Chain.Slot > 0 and M.now() >= ea.Chain.OpenAt then
			break
		end
		if ea.State ~= "Attacking" and ea.State ~= "ComboWindow" then
			break
		end
	end
end
M.run(3)
local hits = 0
for _, f in ipairs(ev.Fired) do
	if f[1] == "Hit" then
		hits += 1
	end
end
print(string.format("   hits %d  victim %.1f hp  state %s  gore %s", hits, hv.Health, evn.State, tostring(v:GetAttribute("GoreStage"))))
check(hits >= 3, "the string connected")
check(hv.Health < 60, "the victim took damage")
-- the victim hits back
v.HumanoidRootPart.CFrame = CFrame.lookAt(v.HumanoidRootPart.Position, a.HumanoidRootPart.Position)
M.run(1)
for _ = 1, 3 do
	Service.RequestAttack(v, { Kind = "Light" })
	M.run(0.5)
end
M.run(3)
check((M.Warnings or 0) == 0, "no warnings")
print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
if failures > 0 then
	error("server test failed")
end
