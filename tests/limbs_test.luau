--!nocheck
--[[
	The limb rules, on the REAL server (CombatService on the simulated world): a fighter - NPC or
	player - loses its right arm at 75% health, its left at 50%, its head on the killing blow; the
	server keeps that stage (the GoreStage attribute, and on every Hit), hides the lost limb for
	everyone, and it never comes back until a respawn. With one arm a fighter takes more from every
	blow and a block stops much less, and it fights with the hand it has left, one strike at a time
	(no combos, no dash strike); with none it cannot block at all (a guard already up drops) and
	cannot attack at all.
	The numbers are Config.GoreDamage - the very rule the attacker's screen predicts with.

	    lune run tests/limbs_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3 = Env.Vector3
local process = require("@lune/process")

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Service = Env.load("ServerScriptService/Combat/CombatService")
local G = Config.Gore

local passed, failed = 0, 0
local function check(name, cond, detail)
	if cond then
		passed += 1
		print("  PASS  " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. (if detail then "  -- " .. tostring(detail) else ""))
	end
end
local function section(name)
	print("\n== " .. name)
end
local function near(a, b)
	return math.abs(a - b) < 1e-6
end

local nextX = 0
local function lane()
	nextX += 200
	return nextX
end
local function fighter(name, x, z, lookZ, player)
	local c = Env.character(name, V3.new(x, 3, z), V3.new(0, 0, lookZ or -1))
	local p = if player then Env.player(name, 0.05, c) else nil
	Service.Register(c, p)
	return c, Service.Get(c)
end
-- one strike from A that lands on B: its Hit (B put back in front of A first, the chain over)
local function strike(A, B, x, kind)
	local eA = Service.Get(A)
	for _ = 1, 120 do
		if eA.State == "Idle" then
			break
		end
		Env.step()
	end
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	local from = #Env.events
	for _ = 1, 90 do
		if Service.RequestAttack(A, { Kind = kind or "Light" }) then
			break
		end
		Env.step()
	end
	for _ = 1, 90 do
		Env.step()
		for i = from + 1, #Env.events do
			local ev = Env.events[i]
			if ev.Kind == "Hit" and ev.Data.A == A and ev.Data.V == B then
				Env.run(1.2)
				return ev.Data
			end
		end
	end
	return nil
end
local function arms(c)
	return Config.ArmsAt(c:GetAttribute("GoreStage"))
end

---------------------------------------------------------------------------
section("1  the stages, kept by the server")
---------------------------------------------------------------------------
do
	local x = lane()
	local A = fighter("LA1", x, 0, -1, true)
	local B, eB = fighter("LB1", x, -3.4, 1)
	check("a fresh fighter: stage 0 (whole), both arms", B:GetAttribute("GoreStage") == 0 and arms(B) == 2)
	eB.Hum:TakeDamage(26)
	check("down to 74%: stage 1 - the right arm is gone, hidden for everyone", B:GetAttribute("GoreStage") == 1 and B.Limbs["Right Arm"].Transparency == 1 and B.Limbs["Left Arm"].Transparency == 0 and arms(B) == 1)
	eB.Hum:TakeDamage(25)
	check("down to 49%: stage 2 - the left arm too", B:GetAttribute("GoreStage") == 2 and B.Limbs["Left Arm"].Transparency == 1 and arms(B) == 0)
	eB.Hum.Health = eB.Hum.MaxHealth
	eB.Hum.HealthChanged:Fire(eB.Hum.Health)
	check("healed back to full: the arms never come back", B:GetAttribute("GoreStage") == 2 and B.Limbs["Right Arm"].Transparency == 1)
	check("the head stays until the killing blow", B.Limbs.Head.Transparency == 0)
	eB.Hum:TakeDamage(1000)
	check("the killing blow: stage 3, the head (and its face) gone", B:GetAttribute("GoreStage") == 3 and B.Limbs.Head.Transparency == 1 and B.Limbs.Head._kids[1].Transparency == 1)
	check("the legs are never touched", B.Limbs["Right Leg"].Transparency == 0 and B.Limbs["Left Leg"].Transparency == 0)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- an accessory on the torn arm goes with it (a weld, or a rigid accessory's constraint)
	local x = lane()
	local B, eB = fighter("LB1b", x, -3.4, 1)
	local arm = B.Limbs["Right Arm"]
	local function part(name)
		return { Name = name, ClassName = "Part", Transparency = 0, IsA = function(_, c)
			return c == "BasePart" or c == "Part"
		end }
	end
	local weld = { ClassName = "Weld", Part0 = nil, Part1 = arm, IsA = function(_, c)
		return c == "Weld" or c == "JointInstance"
	end }
	local watchHandle = Env.withAttributes(part("Handle"))
	watchHandle.FindFirstChild = function() return nil end
	watchHandle.GetDescendants = function()
		return { weld }
	end
	local watch = { Name = "Watch", ClassName = "Accessory", IsA = function(_, c)
		return c == "Accessory"
	end, FindFirstChild = function(_, n)
		return if n == "Handle" then watchHandle else nil
	end }
	table.insert(B.Accessories, watch)
	eB.Hum:TakeDamage(30)
	check("an accessory held on the lost arm is hidden with it", watchHandle.Transparency == 1)
	check("... and what each looked like before is kept on it (the HUD's portraits show the fighter whole)", arm:GetAttribute("GoreHidden") == 0 and watchHandle:GetAttribute("GoreHidden") == 0)
	B:Destroy()
	Env.step()
end

do
	-- a tool is held in the right hand: with that arm gone it goes back in the backpack, and one
	-- equipped later goes straight back too
	local x = lane()
	local P, eP = fighter("LT1", x, -3.4, 1, true)
	local player = eP.Player
	local bag = { Name = "Backpack", ClassName = "Backpack" }
	player.FindFirstChildOfClass = function(_, c)
		return if c == "Backpack" then bag else nil
	end
	local function tool(name)
		return { Name = name, ClassName = "Tool", Parent = P, IsA = function(_, c)
			return c == "Tool"
		end }
	end
	local sword = tool("Sword")
	P.Tools = { sword }
	eP.Hum:TakeDamage(30)
	check("the right arm lost: the tool in that hand goes back in the backpack", sword.Parent == bag)
	local lamp = tool("Lamp")
	table.insert(P.Tools, lamp)
	P.ChildAdded:Fire(lamp)
	Env.step()
	check("... and a tool equipped afterwards goes straight back", lamp.Parent == bag)
	P:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("1b  a player's arms grow back with its health (never an NPC's)")
---------------------------------------------------------------------------
do
	local x = lane()
	local P, eP = fighter("LR1", x, -3.4, 1, true)
	local hum = eP.Hum
	local watchHandle = Env.withAttributes({ Name = "Handle", ClassName = "Part", Transparency = 0, IsA = function(_, c)
		return c == "BasePart" or c == "Part"
	end })
	local weld = { ClassName = "Weld", Part1 = P.Limbs["Left Arm"], IsA = function(_, c)
		return c == "Weld" or c == "JointInstance"
	end }
	watchHandle.FindFirstChild = function() return nil end
	watchHandle.GetDescendants = function()
		return { weld }
	end
	table.insert(P.Accessories, { Name = "Watch", ClassName = "Accessory", IsA = function(_, c)
		return c == "Accessory"
	end, FindFirstChild = function(_, n)
		return if n == "Handle" then watchHandle else nil
	end })
	hum:TakeDamage(55)
	check("(a player down to 45%: both arms gone, the watch on the left with them)", P:GetAttribute("GoreStage") == 2 and P.Limbs["Left Arm"].Transparency == 1 and watchHandle.Transparency == 1)
	local function heal(frac)
		hum.Health = hum.MaxHealth * frac
		hum.HealthChanged:Fire(hum.Health)
		Env.step()
	end
	local M = G.Regrow.Margin
	heal(G.Stages[2] + M * 0.5)
	check(("back to %.0f%% - inside the margin over 50%%: still no arms (no flicker at the line)"):format((G.Stages[2] + M * 0.5) * 100), P:GetAttribute("GoreStage") == 2 and P.Limbs["Left Arm"].Transparency == 1)
	heal(G.Stages[2] + M + 0.01)
	check("past the margin: the left arm grows back, as it was, and its watch with it", P:GetAttribute("GoreStage") == 1 and P.Limbs["Left Arm"].Transparency == 0 and P.Limbs["Left Arm"]:GetAttribute("GoreHidden") == nil and watchHandle.Transparency == 0 and P.Limbs["Right Arm"].Transparency == 1)
	check("... one arm again: the guard goes back up", Service.RequestBlock(P, true) and eP.State == "Blocking")
	Service.RequestBlock(P, false)
	heal(G.Stages[1] + M * 0.5)
	check("inside the margin over 75%: the right arm not yet", P:GetAttribute("GoreStage") == 1)
	heal(G.Stages[1] + M + 0.01)
	check("past it: the right arm grows back too - whole again", P:GetAttribute("GoreStage") == 0 and P.Limbs["Right Arm"].Transparency == 0 and P.Limbs["Right Arm"]:GetAttribute("GoreHidden") == nil)
	hum:TakeDamage(hum.Health - hum.MaxHealth * 0.7)
	check("hurt again: it comes apart again", P:GetAttribute("GoreStage") == 1 and P.Limbs["Right Arm"].Transparency == 1)
	hum:TakeDamage(1000)
	heal(1)
	check("dead: nothing grows back (the respawn makes it whole)", P:GetAttribute("GoreStage") == 3)
	-- an NPC healed all the way: never
	local B, eB = fighter("LR2", x + 30, -3.4, 1)
	eB.Hum:TakeDamage(55)
	eB.Hum.Health = eB.Hum.MaxHealth
	eB.Hum.HealthChanged:Fire(eB.Hum.Health)
	Env.step()
	check("an NPC healed to full never grows an arm back", B:GetAttribute("GoreStage") == 2 and B.Limbs["Right Arm"].Transparency == 1 and B.Limbs["Left Arm"].Transparency == 1)
	check("the rule: never below what the health earns, never the head", Config.RegrowStage(40, 100, 2) == 2 and Config.RegrowStage(100, 100, 3) == 3 and Config.RegrowStage(100, 100, 2) == 0 and Config.RegrowStage(0, 100, 2) == 2)
	P:Destroy()
	B:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("2  one arm: every blow hurts more, a block stops less")
---------------------------------------------------------------------------
do
	local x = lane()
	local A = fighter("LA2", x, 0, -1, true)
	local B, eB = fighter("LB2", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 1000, 1000
	local h = strike(A, B, x)
	local def = h and Config.Attacks[h.K]
	check("two arms: a clean blow does its own damage", h and near(h.D, def.Damage) and h.GS == 0, h and h.D)
	eB.Hum:TakeDamage(1000 - 700)
	check("(down to 70%: one arm)", arms(B) == 1)
	h = strike(A, B, x)
	def = h and Config.Attacks[h.K]
	check(("one arm: a clean blow does x%.2f"):format(G.OneArm.DamageTaken), h and not h.B and near(h.D, def.Damage * G.OneArm.DamageTaken) and h.GS == 1, h and h.D)
	check("... and the attacker's screen predicts exactly the same number", h and near(Config.GoreDamage(def.Damage, 1, false), h.D))
	-- blocking with one arm: the guard goes up, but stops much less
	local ok = Service.RequestBlock(B, true)
	Env.run(0.4)
	h = strike(A, B, x)
	def = h and Config.Attacks[h.K]
	local want = def and def.Damage * Config.Guard.DamageScale * G.OneArm.DamageTaken * G.OneArm.GuardChip
	check(("one arm can still block (x%d chip)"):format(G.OneArm.GuardChip), ok and h and h.B and near(h.D, want), h and ("%s %s / %s"):format(tostring(h.B), tostring(h.D), tostring(want)))
	check("... predicted the same way", h and near(Config.GoreDamage(def.Damage * Config.Guard.DamageScale, 1, true), h.D))
	A:Destroy()
	B:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("3  no arms: no guard at all")
---------------------------------------------------------------------------
do
	local x = lane()
	local A = fighter("LA3", x, 0, -1, true)
	local B, eB = fighter("LB3", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 1000, 1000
	check("with arms the guard goes up", Service.RequestBlock(B, true) and eB.State == "Blocking")
	eB.Hum:TakeDamage(520)
	check("losing the last arm while blocking drops the guard at once", arms(B) == 0 and eB.State ~= "Blocking", eB.State)
	Env.run(0.5)
	check("no arms: the guard can't go up", Service.RequestBlock(B, true) == false and eB.State ~= "Blocking")
	local h = strike(A, B, x)
	local def = h and Config.Attacks[h.K]
	check(("... every blow lands clean, at x%.2f"):format(G.NoArms.DamageTaken), h and not h.B and near(h.D, def.Damage * G.NoArms.DamageTaken) and h.GS == 2, h and h.D)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- the guard dummy's own guard: refused once armless (it keeps trying; the server keeps refusing)
	local x = lane()
	local B, eB = fighter("LB3b", x, -3.4, 1)
	eB.Hum:TakeDamage(60)
	local up = 0
	for _ = 1, 10 do
		if Service.RequestBlock(B, true) then
			up += 1
		end
		Env.step()
	end
	check("an armless NPC asking again and again never gets a guard", up == 0 and eB.State ~= "Blocking")
	B:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("3b  one arm: the hand it has left, one strike at a time - never a combo")
---------------------------------------------------------------------------
do
	local Rules = Env.load("ReplicatedStorage/Combat/ComboRules")
	local c = Rules.New()
	local v1, n1, s1 = Rules.Decide(c, "Light", 10, 0, nil, 1)
	local v2, n2, s2 = Rules.Decide(c, "Heavy", 10, 0, nil, 1)
	check(("the rule (client and server alike): M1 = %s, M2 = %s, both a strike of their own (slot 1)"):format(tostring(n1), tostring(n2)), v1 == "go" and n1 == G.OneArm.Light and s1 == 1 and v2 == "go" and n2 == G.OneArm.Heavy and s2 == 1)
	local P = Env.load("ReplicatedStorage/Combat/CombatPaths")
	check("... both thrown with the left hand (the one that is left)", Config.CanStrike(1, P[n1].Limbs) and Config.CanStrike(1, P[n2].Limbs) and P[n1].Limbs[1] == "Left Arm" and P[n2].Limbs[1] == "Left Arm")
	Rules.Commit(c, n1, 1, false, 0, 10, 1)
	check("committing it ends the chain (nothing can follow it)", c.Slot == 0 and #Rules.Followups(c) == 0)
	local vNo = Rules.Decide(c, "Light", 10 + Config.Attacks[n1].ChainReal + 0.01, 0, nil, 1)
	check("... and the next press waits out the whole strike and its recovery", vNo == "no")
	local vOk, nOk, sOk = Rules.Decide(c, "Light", 10 + Config.Attacks[n1].LengthReal + G.OneArm.Recover + 0.01, 0, nil, 1)
	check("... then it is a new single strike, never the chain's next", vOk == "go" and nOk == G.OneArm.Light and sOk == 1)
	check("no arms: no strike of any kind", Rules.Decide(Rules.New(), "Light", 10, 0, nil, 2) == "no" and Rules.Decide(Rules.New(), "Heavy", 10, 0, nil, 2) == "no")
	check("the moves left: one arm keeps its hand's strikes and the Ground Smash, not the dash strike (the right hand's); none keeps nothing",
		Config.CanUse(1, "Swing2") and Config.CanUse(1, "Uppercut") and Config.CanUse(1, "Downslam") and not Config.CanUse(1, "Swing1") and not Config.CanUse(1, "Swing3") and not Config.CanUse(1, "Sweep") and not Config.CanUse(1, "DashAttack")
			and not Config.CanUse(2, "Swing2") and not Config.CanUse(2, "Downslam") and Config.CanUse(0, "Swing1"))
end
do
	local x = lane()
	local A, eA = fighter("LA5", x, 0, -1, true)
	local B, eB = fighter("LB5", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	local h = strike(A, B, x)
	check("whole: the opening right straight lands", h ~= nil and h.K == "Swing1")
	eA.Hum:TakeDamage(30)
	local hp = eB.Hum.Health
	h = strike(A, B, x)
	check(("right arm torn off: M1 throws the left instead (%s) - and it lands"):format(h and h.K or "nothing"), h ~= nil and h.K == G.OneArm.Light and eB.Hum.Health < hp)
	-- mash M1 through it: never a second strike of a chain
	for _ = 1, 60 do
		if eA.State == "Idle" then
			break
		end
		Env.step()
	end
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	local started, slots = {}, {}
	for _ = 1, 150 do
		local ok, name, slot = Service.RequestAttack(A, { Kind = "Light" })
		if ok then
			table.insert(started, name)
			table.insert(slots, slot)
		end
		Env.step()
	end
	local allOne = #slots > 0
	for i, sl in ipairs(slots) do
		allOne = allOne and sl == 1 and started[i] == G.OneArm.Light
	end
	check(("mashing M1 for 2.5 s: %d strikes, every one a single left (slot 1), none chained"):format(#started), allOne and #started >= 2 and #started <= 4, table.concat(started, ","))
	Env.run(1.5)
	local ok, name = Service.RequestAttack(A, { Kind = "Heavy" })
	check("M2: the left uppercut, on its own", ok and name == G.OneArm.Heavy, name)
	Env.run(1.5)
	-- the dash strike is the right hand's: a forward dash + M1 only dashes
	Env.place(A, x, 0, 0, -1)
	check("(a forward dash)", Service.RequestDash(A, "Forward"))
	Env.run(0.12)
	check("forward dash + M1: no dash strike without the right arm", Service.RequestAttack(A, { Kind = "Light" }) == false and eA.State ~= "Attacking")
	Env.run(1)
	-- no arms: nothing but moving
	eA.Hum:TakeDamage(25)
	check("(down to under 50%: no arms)", arms(A) == 0)
	Env.run(0.5)
	local any = Service.RequestAttack(A, { Kind = "Light" }) or Service.RequestAttack(A, { Kind = "Heavy" }) or Service.RequestAttack(A, { Kind = "Light", Air = true, H = 5 })
	check("no arms: M1, M2 and the Ground Smash are all refused", any == false and eA.State ~= "Attacking")
	check("... but it can still move (a dash)", Service.RequestDash(A, "Back") or Service.RequestDash(A, "Forward"))
	A:Destroy()
	B:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("4  players too")
---------------------------------------------------------------------------
do
	local x = lane()
	local A = fighter("LA4", x, 0, -1, true)
	local P, eP = fighter("LP4", x, -3.4, 1, true)
	eP.Hum:TakeDamage(30)
	check("a player's character loses its arm like anyone's (Config.Gore.Players)", P:GetAttribute("GoreStage") == 1 and P.Limbs["Right Arm"].Transparency == 1)
	G.Players = false
	local Q, eQ = fighter("LQ4", x + 30, -3.4, 1, true)
	eQ.Hum:TakeDamage(60)
	check("Players off: a player keeps its arms", Q:GetAttribute("GoreStage") == 0 and Q.Limbs["Right Arm"].Transparency == 0)
	eQ.Hum.Health = 1000
	eQ.Hum.MaxHealth = 1000
	local h = strike(A, Q, x + 30)
	check("... and takes plain damage", h ~= nil and near(h.D, Config.Attacks[h.K].Damage) and h.GS == 0, h and h.D)
	G.Players = true
	A:Destroy()
	P:Destroy()
	Q:Destroy()
	Env.step()
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
