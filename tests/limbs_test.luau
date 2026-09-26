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
	watchHandle.GetChildren = function() return {} end
	watchHandle.GetDescendants = function()
		return { weld }
	end
	local watch = { Name = "Watch", ClassName = "Accessory", IsA = function(_, c)
		return c == "Accessory"
	end, FindFirstChild = function(_, n)
		return if n == "Handle" then watchHandle else nil
	end }
	table.insert(B.Accessories, watch)
	-- a pad worn at the shoulder (its attachment matches the arm's RightShoulderAttachment, and a weld)
	local function attachment(name)
		return { Name = name, ClassName = "Attachment", IsA = function(_, c)
			return c == "Attachment"
		end }
	end
	local armShoulder = attachment("RightShoulderAttachment")
	arm.FindFirstChild = function(_, n)
		return if n == armShoulder.Name then armShoulder else nil
	end
	local padAtt = attachment("RightShoulderAttachment")
	local padWeld = { ClassName = "Weld", Part0 = nil, Part1 = arm, IsA = weld.IsA }
	local padHandle = Env.withAttributes(part("Handle"))
	padHandle.FindFirstChild = function() return nil end
	padHandle.GetChildren = function() return { padAtt } end
	padHandle.GetDescendants = function()
		return { padAtt, padWeld }
	end
	table.insert(B.Accessories, { Name = "Pad", ClassName = "Accessory", IsA = watch.IsA, FindFirstChild = function(_, n)
		return if n == "Handle" then padHandle else nil
	end })
	eB.Hum:TakeDamage(30)
	check("an accessory held on the lost arm is hidden with it", watchHandle.Transparency == 1)
	check("... and one worn on its shoulder too (the whole arm is gone, shoulder and all)", padHandle.Transparency == 1 and padHandle:GetAttribute("GoreHidden") == 0)
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
section("1b  a player's arms grow back, 10 s each (never an NPC's); healing never does")
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
	watchHandle.GetChildren = function() return {} end
	watchHandle.GetDescendants = function()
		return { weld }
	end
	table.insert(P.Accessories, { Name = "Watch", ClassName = "Accessory", IsA = function(_, c)
		return c == "Accessory"
	end, FindFirstChild = function(_, n)
		return if n == "Handle" then watchHandle else nil
	end })
	local T = G.Regrow.Time
	hum:TakeDamage(55)
	local t0 = Env.now()
	check("(a player down to 45%: both arms gone, the watch on the left with them)", P:GetAttribute("GoreStage") == 2 and P.Limbs["Left Arm"].Transparency == 1 and watchHandle.Transparency == 1)
	check(("its wounds are published (%.2f) and when the next arm grows back (RegrowAt)"):format(P:GetAttribute("Wounds") or -1), math.abs((P:GetAttribute("Wounds") or 0) - 0.55) < 1e-6 and type(P:GetAttribute("RegrowAt")) == "number")
	-- healed all the way: nothing grows back from health
	hum.Health = hum.MaxHealth
	hum.HealthChanged:Fire(hum.Health)
	Env.run(T - 0.3)
	check(("healed to full: still no arms after %.1f s (health never regrows them)"):format(Env.now() - t0), P:GetAttribute("GoreStage") == 2)
	Env.run(0.4)
	check(("%.1f s: the LEFT arm (the last one lost) grows back, as it was, its watch with it"):format(Env.now() - t0), P:GetAttribute("GoreStage") == 1 and P.Limbs["Left Arm"].Transparency == 0 and P.Limbs["Left Arm"]:GetAttribute("GoreHidden") == nil and watchHandle.Transparency == 0 and P.Limbs["Right Arm"].Transparency == 1)
	check("... one arm again: the guard goes back up", Service.RequestBlock(P, true) and eP.State == "Blocking")
	Service.RequestBlock(P, false)
	Env.run(T - 0.5)
	check("the right arm not yet", P:GetAttribute("GoreStage") == 1)
	Env.run(0.6)
	check(("%.1f s (%d s each, %d for both): the right arm too - whole again"):format(Env.now() - t0, T, T * 2), P:GetAttribute("GoreStage") == 0 and P.Limbs["Right Arm"].Transparency == 0 and P:GetAttribute("RegrowAt") == nil)
	check("... and its wounds healed with it", (P:GetAttribute("Wounds") or 1) == 0)
	hum:TakeDamage(20)
	check("a regrown arm takes the same share of damage again to lose (20% lost: still whole)", P:GetAttribute("GoreStage") == 0)
	hum:TakeDamage(6)
	check("... 26%: the right arm goes again", P:GetAttribute("GoreStage") == 1 and P.Limbs["Right Arm"].Transparency == 1)
	-- losing another arm restarts the clock (the newest loss grows back first, 10 s after it)
	Env.run(T * 0.6)
	hum:TakeDamage(30)
	local t1 = Env.now()
	Env.run(T - 0.2)
	check("a second arm lost part-way: the clock restarts from that loss", P:GetAttribute("GoreStage") == 2)
	Env.run(0.4)
	check(("... %.1f s after it: the left back"):format(Env.now() - t1), P:GetAttribute("GoreStage") == 1)
	hum:TakeDamage(1000)
	Env.run(T * 2 + 1)
	check("dead: nothing grows back (the respawn makes it whole)", P:GetAttribute("GoreStage") == 3 and P:GetAttribute("RegrowAt") == nil)
	-- an NPC: never
	local B, eB = fighter("LR2", x + 30, -3.4, 1)
	eB.Hum:TakeDamage(55)
	Env.run(T * 2 + 1)
	check("an NPC never grows an arm back", B:GetAttribute("GoreStage") == 2 and B.Limbs["Right Arm"].Transparency == 1 and B.Limbs["Left Arm"].Transparency == 1 and B:GetAttribute("RegrowAt") == nil)
	check("the rules: wounds 25% -> no right arm, 50% -> none; a regrowth leaves just what the missing arms need", Config.GoreStageForWounds(0.24) == 0 and Config.GoreStageForWounds(0.25) == 1 and Config.GoreStageForWounds(0.5) == 2 and Config.GoreStageForWounds(0.99) == 2 and Config.WoundsAfterRegrow(1) == 0.25 and Config.WoundsAfterRegrow(0) == 0)
	P:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- a tool in the right hand: stowed with the arm, back in the hand when the arm grows back
	local x = lane()
	local P, eP = fighter("LR3", x, -3.4, 1, true)
	local bag = { Name = "Backpack", ClassName = "Backpack" }
	eP.Player.FindFirstChildOfClass = function(_, c)
		return if c == "Backpack" then bag else nil
	end
	local sword = { Name = "Sword", ClassName = "Tool", Parent = P, IsA = function(_, c)
		return c == "Tool"
	end }
	P.Tools = { sword }
	eP.Hum:TakeDamage(30)
	check("the right arm lost: the sword goes back in the backpack", sword.Parent == bag)
	Env.run(G.Regrow.Time + 0.3)
	check("the right arm grown back: the sword is back in its hand", sword.Parent == P and P:GetAttribute("GoreStage") == 0)
	P:Destroy()
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
	local vOk, nOk, sOk = Rules.Decide(c, "Light", 10 + Rules.SingleGap(Config.Attacks[n1]) + 0.01, 0, nil, 1)
	check("... then it is a new single strike, never the chain's next", vOk == "go" and nOk == G.OneArm.Light and sOk == 1)
	check("no arms: no strike of any kind", Rules.Decide(Rules.New(), "Light", 10, 0, nil, 2) == "no" and Rules.Decide(Rules.New(), "Heavy", 10, 0, nil, 2) == "no")
	check("the moves left: one arm keeps its hand's strikes and the Ground Smash, not the dash strike (the right hand's); none keeps nothing, not even the Ground Smash",
		Config.CanUse(1, "Swing2") and Config.CanUse(1, "Uppercut") and Config.CanUse(1, "Downslam") and not Config.CanUse(1, "Swing1") and not Config.CanUse(1, "Swing3") and not Config.CanUse(1, "Sweep") and not Config.CanUse(1, "DashAttack")
			and not Config.CanUse(2, "Swing2") and not Config.CanUse(2, "Uppercut") and not Config.CanUse(2, "DashAttack") and not Config.CanUse(2, "Downslam") and Config.CanUse(0, "Swing1"))
	-- never a true combo: after every one-handed strike, whatever comes next, its victim has had
	-- control back for a moment (even with the server's network slack) before the next can land
	local slack = Config.Combo.Slack
	local worst, pair = math.huge, ""
	for _, a in ipairs({ G.OneArm.Light, G.OneArm.Heavy }) do
		for _, b in ipairs({ G.OneArm.Light, G.OneArm.Heavy }) do
			local da, db = Config.Attacks[a], Config.Attacks[b]
			local free = da.HitReal + da.Stun + da.ClassDef.Hitstop
			local nextLands = Rules.SingleGap(da) - slack + db.HitReal
			if nextLands - free < worst then
				worst, pair = nextLands - free, a .. " > " .. b
			end
		end
	end
	check(("no true combo: the victim always has %.2f s of control before the next one-handed strike can land (worst: %s)"):format(worst, pair), worst >= 0.05, worst)
	local gapL, gapH = Rules.SingleGap(Config.Attacks[G.OneArm.Light]), Rules.SingleGap(Config.Attacks[G.OneArm.Heavy])
	check(("...and they still come as fast as that allows: a jab every %.2f s, an uppercut every %.2f s"):format(gapL, gapH), gapL < 0.9 and gapH < 1.4)
	-- the hitboxes: a lost arm's side of the body is narrower; a lost fist never lands
	local HD = Env.load("ReplicatedStorage/Combat/HitDetect")
	local whole, one, none = HD.BodyFor(0), HD.BodyFor(1), HD.BodyFor(2)
	check("a body missing its right arm is narrower on its right only; with none, on both sides", whole.L == whole.R and one.R < whole.R and one.L == whole.L and none.L < whole.L and none.R < whole.R)
	local CF, V3 = Env.CFrame, Env.Vector3
	local acf = CF.new(0, 3, 0)
	local vcf = CF.lookAt(V3.new(0, 3, -3.2), V3.new(0, 3, 0))
	local path = HD.Paths.Swing1
	local r = HD.Radius("Swing1")
	check("a right straight lands with the right arm, and never once it is gone", HD.Sweep("Swing1", acf, vcf, path.From, path.To, r, 0, 0) and not HD.Sweep("Swing1", acf, vcf, path.From, path.To, r, 0, 1))
	local p3 = HD.Paths.Swing3
	check("a two-handed hook still lands with the hand that is left", HD.Sweep("Swing3", acf, vcf, p3.From, p3.To, HD.Radius("Swing3"), 0, 1) and not HD.Sweep("Swing3", acf, vcf, p3.From, p3.To, HD.Radius("Swing3"), 0, 2))
	-- where a blow lands: its contact on the body's surface (blood, a clean hit's impact), the fist's
	-- own point just in front of it (a guard's sparks)
	do
		local ok, onSurface, fistOut = true, 0, 0
		for dz = 2.4, 3.6, 0.2 do
			for _, key in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut" }) do
				local v2 = CF.lookAt(V3.new(0, 3, -dz), V3.new(0, 3, 0))
				local p = HD.Paths[key]
				local hit, at, fist = HD.Sweep(key, acf, v2, p.From, p.To, HD.Radius(key), 0, 0)
				if hit then
					local ls, lf = v2:PointToObjectSpace(at), v2:PointToObjectSpace(fist)
					local B = Config.Hitbox.Body
					local onFace = math.abs(math.abs(ls.X) - B.HalfWidth) < 1e-3 or math.abs(math.abs(ls.Z) - B.HalfDepth) < 1e-3 or math.abs(ls.Y - B.Top) < 1e-3
					local inside = math.abs(ls.X) <= B.HalfWidth + 1e-3 and math.abs(ls.Z) <= B.HalfDepth + 1e-3 and ls.Y <= B.Top + 1e-3 and ls.Y >= B.Bottom - 1e-3
					if onFace and inside then
						onSurface += 1
					else
						ok = false
					end
					if (lf - ls).Magnitude <= HD.Radius(key) + 1e-3 then
						fistOut += 1
					end
				end
			end
		end
		check(("every blow's contact lies on the body's surface (%d), its fist within the limb's reach of it (%d)"):format(onSurface, fistOut), ok and onSurface > 10 and fistOut == onSurface)
	end
	-- ...at every limb stage, every step up or down, every heading, anywhere on the map: the contact
	-- always on what is there of the body - never in the air where a lost arm was, never inside it -
	-- and the fist's own point always within its reach
	do
		local B, THIN = Config.Hitbox.Body, Config.Hitbox.ArmlessHalfWidth
		local function boxes(stage)
			local L = if stage >= 2 then THIN else B.HalfWidth
			local R = if stage >= 1 then THIN else B.HalfWidth
			return { { -L, R, B.Bottom, B.Top } }
		end
		local function onBody(l, bx)
			local on, deep, e = false, false, 2e-3
			for _, b in ipairs(bx) do
				if l.X >= b[1] - e and l.X <= b[2] + e and l.Y >= b[3] - e and l.Y <= b[4] + e and math.abs(l.Z) <= B.HalfDepth + e then
					on = true
				end
				if l.X > b[1] + e and l.X < b[2] - e and l.Y > b[3] + e and l.Y < b[4] - e and math.abs(l.Z) < B.HalfDepth - e then
					deep = true
				end
			end
			return on and not deep
		end
		local function inside(l, bx)
			for _, b in ipairs(bx) do
				if l.X > b[1] + 2e-3 and l.X < b[2] - 2e-3 and l.Y > b[3] + 2e-3 and l.Y < b[4] - 2e-3 and math.abs(l.Z) < B.HalfDepth - 2e-3 then
					return true
				end
			end
			return false
		end
		local total, bad, far, perStage = 0, 0, 0, { 0, 0, 0 }
		for _, base in ipairs({ CF.new(0, 0, 0), CF.new(1234, 4000, -777), CF.new(-2900, -300, 2900) }) do
			for stage = 0, 2 do
				for _, key in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "DashAttack", "Downslam" }) do
					local p = HD.Paths[key]
					for _, rise in ipairs({ -1.6, -0.8, 0, 0.8, 1.6 }) do
						for _, turn in ipairs({ 0, 0.6, 1.57, 3.14, -2.2 }) do
							for dz = 2.2, 3.8, 0.4 do
								for dx = -1.5, 1.5, 0.75 do
									local a = base * acf
									local v = base * CF.new(dx, 3 + rise, -dz) * CF.Angles(0, turn, 0)
									local hit, at, fist = HD.Sweep(key, a, v, p.From, p.To, HD.Radius(key), stage, 0)
									if hit then
										total += 1
										perStage[stage + 1] += 1
										local l = v:PointToObjectSpace(at)
										if not onBody(l, boxes(stage)) then
											bad += 1
										end
										local lf = v:PointToObjectSpace(fist)
										-- (within reach, and never sunk inside the body where a guard's sparks would hide)
										if (lf - l).Magnitude > HD.Radius(key) + 2e-3 or inside(lf, boxes(stage)) then
											far += 1
										end
									end
								end
							end
						end
					end
				end
			end
		end
		check(("%d blows (%d whole / %d one arm / %d none; steps of +-1.6, any heading, 4000 studs up): every contact on what is left of the body (%d off), every fist within reach and outside it (%d)"):format(total, perStage[1], perStage[2], perStage[3], bad, far), total > 1000 and bad == 0 and far == 0)
	end
	-- across a body: a blow that would only have touched an arm that is gone now misses - at any height
	local function across(key, stage)
		local hits = 0
		for dx = -2.6, 2.6, 0.05 do
			local v2 = CF.lookAt(V3.new(dx, 3, -3.2), V3.new(dx, 3, 0))
			if HD.Sweep(key, acf, v2, HD.Paths[key].From, HD.Paths[key].To, HD.Radius(key), stage, 0) then
				hits += 1
			end
		end
		return hits
	end
	for _, key in ipairs({ "Swing2", "Uppercut", "DashAttack" }) do
		local k0, k1, k2 = across(key, 0), across(key, 1), across(key, 2)
		check(("%s swept across a body: %d offsets land whole, %d with one arm gone, %d with none - what only an arm took now misses"):format(key, k0, k1, k2), k0 > k1 and k1 > k2 and k2 > 0)
	end
	-- EVERY move x every stage x offsets across and along x steps up / down x headings: nothing ever
	-- lands where a lost arm was. A hit on a narrower body is always a hit on a wider one (never a
	-- blow landing only because an arm is gone), its contact is on the torso's side (never out in
	-- the arm's space), and the blows lost are exactly those whose contact was on the missing arm
	do
		local B, THIN = Config.Hitbox.Body, Config.Hitbox.ArmlessHalfWidth
		local total, inArm, extra, lostOk, lost, byStage = 0, 0, 0, true, 0, { 0, 0, 0 }
		for _, key in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "DashAttack", "Downslam" }) do
			local p = HD.Paths[key]
			for _, rise in ipairs({ -1.4, -0.7, 0, 0.7, 1.4 }) do
				for _, turn in ipairs({ 0, 0.8, 1.57, 2.4, 3.14, -0.8, -1.57, -2.4 }) do
					for dz = 2.0, 4.2, 0.3 do
						for dx = -2.4, 2.4, 0.3 do
							local v = CF.new(dx, 3 + rise, -dz) * CF.Angles(0, turn, 0)
							local was = { HD.Sweep(key, acf, v, p.From, p.To, HD.Radius(key), 0, 0) }
							for stage = 0, 2 do
								local hit, at = HD.Sweep(key, acf, v, p.From, p.To, HD.Radius(key), stage, 0)
								if hit then
									total += 1
									byStage[stage + 1] += 1
									local l = v:PointToObjectSpace(at)
									local R = if stage >= 1 then THIN else B.HalfWidth
									local L = if stage >= 2 then THIN else B.HalfWidth
									if l.X > R + 2e-3 or l.X < -L - 2e-3 then
										inArm += 1
									end
									if not was[1] then
										extra += 1
									end
								elseif stage > 0 and was[1] then
									-- lost: the whole body's contact was out where the arm was
									lost += 1
									local l0 = v:PointToObjectSpace(was[2])
									if math.abs(l0.X) <= THIN - 0.05 then
										lostOk = false
									end
								end
							end
						end
					end
				end
			end
		end
		check(("%d blows (%d whole, %d one arm, %d none; every move, steps of +-1.4, 8 headings): none ever lands in a lost arm's space (%d)"):format(total, byStage[1], byStage[2], byStage[3], inArm), total > 5000 and inArm == 0, inArm)
		check(("... a missing arm never makes a blow land that wouldn't have (%d)"):format(extra), extra == 0, extra)
		check(("... and the %d blows lost to missing arms are all ones that touched only the arm's side"):format(lost), lost > 0 and lostOk)
	end
	-- the thrower's lost hand never strikes: every move, every offset - a right-hand move with no right
	-- arm never lands, an arm move with no arms never lands; the left hand's moves land just as before
	do
		local rightMiss, armsMiss, leftSame, n = true, true, true, 0
		for _, key in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "DashAttack" }) do
			local p = HD.Paths[key]
			for dx = -2.4, 2.4, 0.2 do
				for dz = 2.0, 4.2, 0.2 do
					local v = CF.lookAt(V3.new(dx, 3, -dz), V3.new(dx, 3, 0))
					local h0 = HD.Sweep(key, acf, v, p.From, p.To, HD.Radius(key), 0, 0)
					local h1 = HD.Sweep(key, acf, v, p.From, p.To, HD.Radius(key), 0, 1)
					local h2 = HD.Sweep(key, acf, v, p.From, p.To, HD.Radius(key), 0, 2)
					n += 1
					if (key == "Swing1" or key == "DashAttack") and h1 then
						rightMiss = false
					end
					if h2 then
						armsMiss = false
					end
					if (key == "Swing2" or key == "Uppercut") and h0 ~= h1 then
						leftSame = false
					end
				end
			end
		end
		check(("the thrower's lost hand never lands (%d placements x 5 moves): no right straight or dash strike without the right arm"):format(n // 5), rightMiss)
		check("... no arm strike at all without arms", armsMiss)
		check("... and the left hand's straight and uppercut land exactly as they did with both", leftSame)
	end
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
	check(("mashing M1 for 2.5 s: %d strikes, every one a single left (slot 1), none chained"):format(#started), allOne and #started >= 3 and #started <= 4, table.concat(started, ","))
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
	local any = Service.RequestAttack(A, { Kind = "Light" }) or Service.RequestAttack(A, { Kind = "Heavy" })
	check("no arms: M1 and M2 are refused (no strike of any kind)", any == false and eA.State ~= "Attacking")
	Env.place(A, x, 0, 0, -1)
	local smash = Service.RequestAttack(A, { Kind = "Light", Air = true, H = 5 })
	check("... nor the Ground Smash (jump + M1)", smash == false and eA.State ~= "Attacking")
	Env.run(0.5)
	check("... but it can still move (a dash)", Service.RequestDash(A, "Back") or Service.RequestDash(A, "Forward"))
	A:Destroy()
	B:Destroy()
	Env.step()
end

---------------------------------------------------------------------------
section("3c  an NPC fighting back (the Sparring Dummy's way: CombatService, like anyone)")
---------------------------------------------------------------------------
do
	local x = lane()
	local N, eN = fighter("LN1", x, 0, -1) -- (an NPC)
	local P, eP = fighter("LP1", x, -3.4, 1, true)
	eP.Hum.MaxHealth, eP.Hum.Health = 1000, 1000
	local from = #Env.events
	local names = {}
	for _ = 1, 240 do
		local ok, name = Service.RequestAttack(N, { Kind = "Light" })
		if ok then
			table.insert(names, name)
		end
		Env.place(N, x, 0, 0, -1)
		Env.place(P, x, -3.4, 0, 1)
		Env.step()
	end
	local hits = 0
	for i = from + 1, #Env.events do
		local ev = Env.events[i]
		if ev.Kind == "Hit" and ev.Data.A == N and ev.Data.V == P then
			hits += 1
		end
	end
	check(("an NPC's chain lands on a player: %d strikes (%s), %d hits"):format(#names, table.concat(names, ","), hits), #names >= 4 and hits >= 4 and eP.Hum.Health < 1000)
	-- one arm: the NPC is held to single left-hand strikes too
	eN.Hum:TakeDamage(eN.Hum.MaxHealth * 0.3)
	Env.run(2)
	local singles = {}
	for _ = 1, 150 do
		local ok, name, slot = Service.RequestAttack(N, { Kind = "Light" })
		if ok then
			table.insert(singles, name .. "/" .. tostring(slot))
		end
		Env.place(N, x, 0, 0, -1)
		Env.place(P, x, -3.4, 0, 1)
		Env.step()
	end
	local allSingle = #singles > 0
	for _, s in ipairs(singles) do
		allSingle = allSingle and s == G.OneArm.Light .. "/1"
	end
	check(("... and with one arm, its strikes are single lefts too (%s)"):format(table.concat(singles, ",")), allSingle)
	N:Destroy()
	P:Destroy()
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

---------------------------------------------------------------------------
section("7  one arm and no arms: every input mashed, every matchup")
---------------------------------------------------------------------------
-- the Hits one fighter dealt another since event `from`
local function hitsBy(A, B, from)
	local out = {}
	for i = from + 1, #Env.events do
		local ev = Env.events[i]
		if ev.Kind == "Hit" and ev.Data.A == A and (B == nil or ev.Data.V == B) then
			table.insert(out, ev.Data)
		end
	end
	return out
end
-- a fighter at a stage (0 whole, 1 one arm, 2 none): the wounds that take its arms
local function atStage(e, stage)
	if stage >= 1 then
		e.Hum:TakeDamage(if stage == 1 then 30 else 55)
	end
	return e.GoreStage == stage
end
-- mash every input for `secs`: M1, M2, jump + M1, the guard, and a dash every so often. Returns
-- what started (names), the guard ever up, the dashes taken and the gaps between them
local function mash(A, secs, withBlock)
	local e = Service.Get(A)
	local started, blocked, dashes, gaps, lastDash = {}, false, 0, {}, nil
	local t0 = Env.now()
	local flip = false
	while Env.now() - t0 < secs do
		for _, info in ipairs({ { Kind = "Light" }, { Kind = "Heavy" }, { Kind = "Light", Air = true, H = 5 } }) do
			local ok, name, slot = Service.RequestAttack(A, info)
			if ok then
				table.insert(started, { Name = name, Slot = slot })
			end
		end
		if withBlock then
			Service.RequestBlock(A, true)
			if e.State == "Blocking" then
				blocked = true
			end
			Service.RequestBlock(A, false)
		end
		flip = not flip
		if Service.RequestDash(A, if flip then "Forward" else "Left") then
			dashes += 1
			if lastDash then
				table.insert(gaps, Env.now() - lastDash)
			end
			lastDash = Env.now()
			-- (and at once M1: a dash strike, if it has the hand for it)
			local ok, name, slot = Service.RequestAttack(A, { Kind = "Light" })
			if ok then
				table.insert(started, { Name = name, Slot = slot })
			end
		end
		Env.step()
	end
	return started, blocked, dashes, gaps
end
local function minOf(t)
	local m = math.huge
	for _, v in ipairs(t) do
		m = math.min(m, v)
	end
	return m
end
do
	-- no arms, next to a whole fighter, mashing everything for 5 s
	local x = lane()
	local A, eA = fighter("M0a", x, 0, -1)
	local B, eB = fighter("M0b", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	check("(no arms)", atStage(eA, 2))
	local from, hp = #Env.events, eB.Hum.Health
	local started, blocked, dashes, gaps = mash(A, 5, true)
	check(("no arms, every input mashed for 5 s: nothing starts (%d), no blow dealt, no guard ever up"):format(#started), #started == 0 and #hitsBy(A, nil, from) == 0 and eB.Hum.Health == hp and not blocked)
	-- (a forward dash, then a side one: each waits out the last one's lock and the cooldown)
	local want = math.min(Config.Dash.Forward.Lock, Config.Dash.Left.Lock) + Config.Dash.Cooldown * Config.Gore.NoArms.DashCooldown
	check(("... it still dashes (%d), every %.2f s at the soonest (lock + cooldown x%.1f = %.2f)"):format(dashes, minOf(gaps), Config.Gore.NoArms.DashCooldown, want), dashes >= 4 and math.abs(minOf(gaps) - want) < 0.05, minOf(gaps))
	check("... and ends able to act (never stuck in a state)", eA.State == "Idle" or eA.State == "Dashing")
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- a whole fighter's dashes, for comparison: the armless one's come sooner
	local x = lane()
	local A = fighter("M1a", x, 0, -1)
	local gaps, last, flip = {}, nil, false
	local t0 = Env.now()
	while Env.now() - t0 < 5 do
		flip = not flip
		if Service.RequestDash(A, if flip then "Forward" else "Left") then
			if last then
				table.insert(gaps, Env.now() - last)
			end
			last = Env.now()
		end
		Env.step()
	end
	local whole = minOf(gaps)
	check(("a whole fighter dashes every %.2f s at the soonest: the armless one's come %.2f s sooner"):format(whole, Config.Dash.Cooldown * (1 - Config.Gore.NoArms.DashCooldown)), math.abs(whole - (math.min(Config.Dash.Forward.Lock, Config.Dash.Left.Lock) + Config.Dash.Cooldown)) < 0.05, whole)
	A:Destroy()
	Env.step()
end
do
	-- one arm, mashing everything: only the left hand's single strikes and the Ground Smash
	local x = lane()
	local A, eA = fighter("M2a", x, 0, -1)
	local B, eB = fighter("M2b", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	check("(one arm)", atStage(eA, 1))
	local from = #Env.events
	local started = mash(A, 6, false)
	local names, allowed, singles = {}, true, true
	for _, s in ipairs(started) do
		names[s.Name] = (names[s.Name] or 0) + 1
		if s.Name ~= G.OneArm.Light and s.Name ~= G.OneArm.Heavy and s.Name ~= "Downslam" then
			allowed = false
		end
		if s.Slot ~= 1 and s.Name ~= "Downslam" then
			singles = false
		end
	end
	local list = {}
	for n, c in pairs(names) do
		table.insert(list, n .. " x" .. c)
	end
	table.sort(list)
	check(("one arm, every input mashed for 6 s: only the left hand's strikes and the smash (%s)"):format(table.concat(list, ", ")), #started >= 3 and allowed, table.concat(list, ","))
	check("... never the right straight, the hook, the sweep or the dash strike; every strike a single (slot 1)", singles and not names.Swing1 and not names.Swing3 and not names.Sweep and not names.DashAttack)
	local hits = hitsBy(A, B, from)
	local handOk = #hits > 0
	for _, h in ipairs(hits) do
		if h.K ~= G.OneArm.Light and h.K ~= G.OneArm.Heavy and h.K ~= "Downslam" then
			handOk = false
		end
	end
	check(("... and every blow that landed (%d) was one of those"):format(#hits), handOk)
	Env.run(1.5)
	check("... it can still raise its guard", Service.RequestBlock(A, true) and eA.State == "Blocking")
	Service.RequestBlock(A, false)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- an armless victim takes a whole fighter's full chain: every strike lands (it can't block),
	-- each for x1.25 of what a whole victim takes
	local x = lane()
	local A = fighter("M3a", x, 0, -1)
	local W, eW = fighter("M3w", x, -3.4, 1)
	eW.Hum.MaxHealth, eW.Hum.Health = 5000, 5000
	local first = strike(A, W, x)
	W:Destroy()
	Env.step()
	local V, eV = fighter("M3v", x, -3.4, 1)
	check("(no arms)", atStage(eV, 2))
	eV.Hum.MaxHealth, eV.Hum.Health = 5000, 5000
	local h = strike(A, V, x)
	check(("an armless victim: a clean blow does x%.2f (%.1f vs %.1f)"):format(Config.Gore.NoArms.DamageTaken, h and h.D or 0, first and first.D or 0), h and first and math.abs(h.D - first.D * Config.Gore.NoArms.DamageTaken) < 0.01)
	-- a whole chain, the victim trying to block the whole time
	Env.run(1.5)
	Env.place(A, x, 0, 0, -1)
	Env.place(V, x, -3.4, 0, 1)
	local from = #Env.events
	local presses, guard = 0, false
	for _ = 1, 300 do
		Service.RequestBlock(V, true)
		if eV.State == "Blocking" then
			guard = true
		end
		-- (one whole chain: its four strikes, then the finisher throws the victim clear)
		if presses < 4 and Service.RequestAttack(A, { Kind = "Light" }) then
			presses += 1
		end
		Env.step()
	end
	local got, blockedAny = hitsBy(A, V, from), false
	for _, d in ipairs(got) do
		if d.B or d.G then
			blockedAny = true
		end
	end
	check(("... a full chain on it while it holds block: %d strikes, %d land, none blocked, its guard never up"):format(presses, #got), presses == 4 and #got == 4 and not blockedAny and not guard, ("%d/%d"):format(#got, presses))
	A:Destroy()
	V:Destroy()
	Env.step()
end
do
	-- one arm against one arm, both mashing M1: both land single lefts on each other
	local x = lane()
	local A, eA = fighter("M4a", x, 0, -1)
	local B, eB = fighter("M4b", x, -3.4, 1)
	check("(both one-armed)", atStage(eA, 1) and atStage(eB, 1))
	eA.Hum.MaxHealth, eA.Hum.Health = 5000, 5000
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	local from = #Env.events
	for _ = 1, 240 do
		Service.RequestAttack(A, { Kind = "Light" })
		Service.RequestAttack(B, { Kind = "Light" })
		Env.step()
	end
	local ab, ba = hitsBy(A, B, from), hitsBy(B, A, from)
	local ok = #ab > 0 and #ba > 0
	for _, h in ipairs(ab) do
		ok = ok and h.K == G.OneArm.Light
	end
	for _, h in ipairs(ba) do
		ok = ok and h.K == G.OneArm.Light
	end
	check(("one arm vs one arm, both mashing M1 for 4 s: %d and %d blows, every one a left straight"):format(#ab, #ba), ok)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- no arms against no arms: nothing either can do to the other
	local x = lane()
	local A, eA = fighter("M5a", x, 0, -1)
	local B, eB = fighter("M5b", x, -3.4, 1)
	check("(both armless)", atStage(eA, 2) and atStage(eB, 2))
	local ha, hb, from = eA.Hum.Health, eB.Hum.Health, #Env.events
	for _ = 1, 180 do
		Service.RequestAttack(A, { Kind = "Light" })
		Service.RequestAttack(B, { Kind = "Heavy" })
		Service.RequestAttack(A, { Kind = "Light", Air = true, H = 5 })
		Env.step()
	end
	check("no arms vs no arms, mashing for 3 s: not a blow either way", #hitsBy(A, nil, from) == 0 and #hitsBy(B, nil, from) == 0 and eA.Hum.Health == ha and eB.Hum.Health == hb)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- the right arm torn off in the middle of a chain: the next press is a single left, never the
	-- chain's next strike; and a right straight already thrown when the arm goes never lands
	local x = lane()
	local A, eA = fighter("M6a", x, 0, -1)
	local B, eB = fighter("M6b", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	local h = strike(A, B, x)
	check("(a whole fighter's opener lands)", h ~= nil and h.K == "Swing1")
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	local ok0, n0 = Service.RequestAttack(A, { Kind = "Light" })
	check("(a right straight starts)", ok0 and n0 == "Swing1", n0)
	local from = #Env.events
	eA.Hum:TakeDamage(30) -- (its right arm is torn off before the straight connects)
	check("(the right arm goes mid-swing)", eA.GoreStage == 1)
	Env.run(1)
	local landed = false
	for _, d in ipairs(hitsBy(A, B, from)) do
		if d.K == "Swing1" then
			landed = true
		end
	end
	check("a right straight already thrown when its arm is torn off never lands (no hand to land it)", not landed)
	Env.run(1)
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	local ok, name, slot = Service.RequestAttack(A, { Kind = "Light" })
	check(("... and its next press is a single left (%s, slot %s), never the chain's next"):format(tostring(name), tostring(slot)), ok and name == G.OneArm.Light and slot == 1)
	A:Destroy()
	B:Destroy()
	Env.step()
end
do
	-- a player's right arm grows back mid-fight: M1 is the right straight again, and it chains
	local x = lane()
	local A, eA = fighter("M7a", x, 0, -1, true)
	local B, eB = fighter("M7b", x, -3.4, 1)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	check("(a player with one arm)", atStage(eA, 1))
	Env.run(Config.Gore.Regrow.Time + 0.5)
	check("(its arm grown back)", eA.GoreStage == 0)
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	local started = {}
	for _ = 1, 120 do
		local ok, name, slot = Service.RequestAttack(A, { Kind = "Light" })
		if ok then
			table.insert(started, name .. ":" .. slot)
		end
		Env.step()
	end
	check(("arm grown back: M1 is the right straight again and chains (%s)"):format(table.concat(started, " ")), started[1] == "Swing1:1" and started[2] ~= nil and string.sub(started[2], -1) == "2")
	A:Destroy()
	B:Destroy()
	Env.step()
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
