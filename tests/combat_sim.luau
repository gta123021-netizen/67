--!nocheck
--[[
	Headless combat simulation: the REAL server modules from src/ (CombatService, HitDetect,
	ComboRules, CombatConfig, CombatStates, CombatPaths) driven frame by frame at 60 Hz on a flat
	ground (tests/sim/env.luau stands in for the engine). Every scenario asserts what the server
	decides: which strikes connect, on whom (free-form: no lock), where the blows drive the bodies,
	stuns and the stun budget, the Ground Smash rules, report validation and lag compensation.

	    lune run tests/combat_sim.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3, CF = Env.Vector3, Env.CFrame

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Rules = Env.load("ReplicatedStorage/Combat/ComboRules")
local Service = Env.load("ServerScriptService/Combat/CombatService")

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

local mark = 0
local function since()
	mark = #Env.events
	return mark
end
local function hits(att, vic, from)
	local out = {}
	for i = (from or 0) + 1, #Env.events do
		local ev = Env.events[i]
		if ev.Kind == "Hit" and (att == nil or ev.Data.A == att) and (vic == nil or ev.Data.V == vic) then
			table.insert(out, ev.Data)
		end
	end
	return out
end
local function eventsOf(kind, from)
	local out = {}
	for i = (from or 0) + 1, #Env.events do
		if Env.events[i].Kind == kind then
			table.insert(out, Env.events[i])
		end
	end
	return out
end

local nextX = 0
-- a fresh arena lane for every scenario (far apart: nothing leaks between them)
local function lane()
	nextX += 200
	return nextX
end

local function fighter(name, x, z, lookX, lookZ, player)
	local c = Env.character(name, V3.new(x, 3, z), V3.new(lookX or 0, 0, lookZ or -1))
	local p = nil
	if player then
		p = Env.player(name, player, c)
	end
	local e = Service.Register(c, p)
	return c, e
end

local function remove(c)
	c:Destroy()
	Env.step()
end

-- press until the server takes it (a strike is only answered on its chain point); returns ok, name.
-- hold(): called before every frame (to pin fighters in place)
local function press(att, kind, info, hold)
	info = info or {}
	for _ = 1, 90 do
		local ok, name, slot = Service.RequestAttack(att, { Kind = kind, Air = info.Air, Want = info.Want, Seq = info.Seq, H = info.H })
		if ok then
			return true, name, slot
		end
		if hold then
			hold()
		end
		Env.step()
	end
	return false
end

-- until the fighter is in `state`
local function waitState(c, state)
	local e = Service.Get(c)
	for _ = 1, 120 do
		if e.State == state then
			return true
		end
		Env.step()
	end
	return false
end

-- until the attacker's chain can no longer be continued (its window has closed)
local function waitChainOver(att)
	local e = Service.Get(att)
	for _ = 1, 120 do
		if not Rules.Live(e.Chain, Env.now()) then
			return
		end
		Env.step()
	end
end

-- run a whole chain of presses, each on its chain point, then let it play out
local function chain(att, kinds)
	local names = {}
	for _, k in ipairs(kinds) do
		local ok, name = press(att, k)
		table.insert(names, if ok then name else "REFUSED")
	end
	return names
end

local function stateOf(c)
	return Service.GetState(c)
end

---------------------------------------------------------------------------
section("1. Full light chain on a practice fighter: every strike lands, the victim is driven straight down the line")
do
	local x = lane()
	local A = fighter("A1", x, 0)
	local B = fighter("B1", x, -3.4, 0, 1)
	local eB = Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 999, 999
	-- the distance between the two roots on every impact
	local dists = {}
	Env.onEvent = function(ev)
		if ev.Kind == "Hit" and ev.Data.A == A then
			local d = B.HumanoidRootPart.Position - A.HumanoidRootPart.Position
			table.insert(dists, V3.new(d.X, 0, d.Z).Magnitude)
		end
	end
	local from = since()
	local names = chain(A, { "Light", "Light", "Light", "Light" })
	Env.run(1.5)
	Env.onEvent = nil
	check("chain runs Swing1 Swing2 Swing3 Sweep", table.concat(names, " ") == "Swing1 Swing2 Swing3 Sweep", table.concat(names, " "))
	local h = hits(A, B, from)
	check("all four strikes connect", #h == 4, #h)
	check("strikes 1-3 stun (true combo)", h[1] and h[1].S > 0 and h[2] and h[2].S > 0 and h[3] and h[3].S > 0)
	check("the sweep launches (finisher)", h[4] and h[4].RD == true)
	local lanes = true
	for i, d in ipairs(dists) do
		local def = Config.Attacks[h[i] and h[i].K or "Swing1"]
		lanes = lanes and d <= def.ReachMax + 0.12 and d >= def.Ideal - 0.9
	end
	check(("every impact within the strike's real reach (%s)"):format(table.concat((function()
		local t = {}
		for _, d in ipairs(dists) do
			table.insert(t, ("%.2f"):format(d))
		end
		return t
	end)(), " ")), lanes and #dists == 4)
	check("the blows drove the victim straight along the attacker's facing (no sideways drift)", math.abs(B.HumanoidRootPart.Position.X - x) < 0.05, B.HumanoidRootPart.Position.X - x)
	check("no hit event carries a lock", h[1] and h[1].LK == nil and h[2] and h[2].LK == nil)
	remove(A)
	remove(B)
end

---------------------------------------------------------------------------
section("2. Uppercut positions: M2 inserts once, the sweep still finishes")
for pos = 1, 4 do
	local x = lane()
	local A = fighter("A2", x, 0)
	local B = fighter("B2", x, -3.3, 0, 1)
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	local kinds = {}
	for i = 1, 5 do
		kinds[i] = if i == pos then "Heavy" else "Light"
	end
	local from = since()
	local names = chain(A, kinds)
	Env.run(1.5)
	local want = {}
	local lights = { "Swing1", "Swing2", "Swing3" }
	local li = 0
	for i = 1, 5 do
		if i == pos then
			want[i] = "Uppercut"
		elseif i == 5 then
			want[i] = "Sweep"
		else
			li += 1
			want[i] = lights[li]
		end
	end
	check(("uppercut at %d: %s"):format(pos, table.concat(names, " ")), table.concat(names, " ") == table.concat(want, " "), table.concat(want, " "))
	local h = hits(A, B, from)
	check(("uppercut at %d: all 5 connect"):format(pos), #h == 5, #h)
	local allStun = #h == 5
	for i = 1, 4 do
		allStun = allStun and h[i] ~= nil and h[i].S > 0 and not h[i].IM
	end
	check(("uppercut at %d: hits 1-4 all stun (the budget never cuts a real string)"):format(pos), allStun and h[5].RD == true)
	remove(A)
	remove(B)
end
do
	local x = lane()
	local A = fighter("A2b", x, 0)
	local B = fighter("B2b", x, -3.3, 0, 1)
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	press(A, "Heavy")
	local ok = false
	for _ = 1, 40 do
		ok = Service.RequestAttack(A, { Kind = "Heavy" })
		if ok then
			break
		end
		Env.step()
	end
	check("a second M2 in the same chain is refused", ok == false)
	remove(A)
	remove(B)
end

---------------------------------------------------------------------------
section("3. No lock: a third fighter stepping into the path takes the blow meant for the first")
do
	local x = lane()
	local A = fighter("A3", x, 0)
	local B = fighter("B3", x, -3.4, 0, 1)
	local C = fighter("C3", x + 30, 0) -- far away for now
	for _, c in ipairs({ B, C }) do
		Service.Get(c).Hum.MaxHealth, Service.Get(c).Hum.Health = 999, 999
	end
	local eA = Service.Get(A)
	local from = since()
	press(A, "Light")
	press(A, "Light")
	Env.run(0.45) -- past the second strike's hit frame
	check("two connects on B: nothing owns the chain", eA.Lock == nil and eA.Streak == nil and Service.CurrentLock == nil)
	-- C walks in right in front of A, between A and B
	local pa = A.HumanoidRootPart.Position
	local look = A.HumanoidRootPart.CFrame.LookVector
	local mid = pa + look * 2.4
	Env.place(C, mid.X + 0.3, mid.Z, 0, 1)
	local f3 = since()
	press(A, "Light")
	Env.run(0.6)
	check("the next strike lands on C, the body in its path", #hits(A, C, f3) == 1, #hits(A, C, f3))
	check("...and never through C onto B", #hits(A, B, f3) == 0, #hits(A, B, f3))
	remove(A)
	remove(B)
	remove(C)
end

---------------------------------------------------------------------------
section("4. Overlapping fighters, no lock yet: one strike, one body")
do
	local x = lane()
	local A = fighter("A4", x, 0)
	local B = fighter("B4", x - 0.6, -3.3, 0, 1)
	local C = fighter("C4", x + 0.7, -3.5, 0, 1)
	local from = since()
	press(A, "Light")
	Env.run(0.6)
	local total = #hits(A, nil, from)
	check("exactly one fighter hit by a single light", total == 1, total)
	remove(A)
	remove(B)
	remove(C)
end

---------------------------------------------------------------------------
section("5. Free-form: from every angle the chain connects, and every blow drives along the attacker's facing")
for _, case in ipairs({
	{ "facing the attacker", 0, 1 },
	{ "side-on", 1, 0 },
	{ "back turned", 0, -1 },
	{ "diagonal", 0.7, 0.7 },
}) do
	local x = lane()
	-- the attacker comes in at an angle across the world (not along an axis)
	local ang = math.rad(35)
	local dir = V3.new(math.sin(ang), 0, -math.cos(ang))
	local A = fighter("A5", x, 0, dir.X, dir.Z)
	local bp = V3.new(x, 3, 0) + dir * 3.9
	local B = fighter("B5", bp.X, bp.Z, case[2], case[3])
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	local from = since()
	local b0 = B.HumanoidRootPart.Position
	local names = chain(A, { "Light", "Light", "Light" })
	Env.run(0.9)
	local h = hits(A, B, from)
	check(("victim %s: all three lights connect (%s)"):format(case[1], table.concat(names, " ")), #h == 3, #h)
	local moved = B.HumanoidRootPart.Position - b0
	moved = V3.new(moved.X, 0, moved.Z)
	check(("victim %s: driven along the attacker's facing (dot %.3f)"):format(case[1], if moved.Magnitude > 0 then moved.Unit:Dot(dir) else 0), moved.Magnitude > 2 and moved.Unit:Dot(dir) > 0.995)
	local d0 = A.HumanoidRootPart.CFrame.LookVector
	check(("victim %s: the attacker never turned toward anybody"):format(case[1]), d0:Dot(dir) > 0.9999)
	remove(A)
	remove(B)
end
do
	-- the step-in never homes: a body off to the side is not stepped toward
	local x = lane()
	local A = fighter("A5s", x, 0)
	local off = V3.new(x, 3, 0) + V3.new(math.sin(math.rad(55)), 0, -math.cos(math.rad(55))) * 4.6
	local B = fighter("B5s", off.X, off.Z, 0, 1)
	local p0 = A.HumanoidRootPart.Position
	local from = since()
	press(A, "Light")
	Env.run(0.7)
	local moved = A.HumanoidRootPart.Position - p0
	check("a body 55 degrees off the facing: the step goes straight ahead, not toward it", math.abs(moved.X) < 1e-3 and moved.Z < 0, ("%.3f %.3f"):format(moved.X, moved.Z))
	check("...and the strike doesn't reach it", #hits(A, B, from) == 0)
	remove(A)
	remove(B)
	-- the step stops at the body in the lane (a lunge, never a walk-through), and is short with
	-- nobody there
	local x2 = lane()
	local A2 = fighter("A5t", x2, 0)
	local B2 = fighter("B5t", x2, -5.2, 0, 1)
	local f2 = since()
	press(A2, "Light")
	Env.run(0.32)
	local gap = (B2.HumanoidRootPart.Position - A2.HumanoidRootPart.Position).Magnitude
	check(("from 5.2 away the step closes to the strike's distance (%.2f at the impact)"):format(gap), gap > Config.Attacks.Swing1.Ideal - 0.25 and gap < Config.Attacks.Swing1.Reach)
	Env.run(0.5)
	check("...and the cross lands", #hits(A2, B2, f2) == 1)
	remove(A2)
	remove(B2)
	local x3 = lane()
	local A3 = fighter("A5u", x3, 0)
	press(A3, "Light")
	Env.run(0.6)
	local went = (A3.HumanoidRootPart.Position - V3.new(x3, 3, 0)).Magnitude
	check(("nobody ahead: a short weight-shift step (%.2f studs)"):format(went), went > 0.3 and went <= Config.Attacks.Swing1.Step.Base + 0.05)
	remove(A3)
end

---------------------------------------------------------------------------
section("6. Anti-stunlock, one attacker: no restart can re-stun a body the last chain still holds")
local function resetCase(label, between)
	local x = lane()
	local A = fighter("A6" .. label, x, 0)
	local B = fighter("B6" .. label, x, -3.4, 0, 1)
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	press(A, "Light")
	press(A, "Light")
	Env.run(0.45) -- the second strike has landed; the victim is reeling
	local from = since()
	between(A, B)
	Env.run(0.9)
	local h = hits(A, B, from)
	local stunned = 0
	for _, d in ipairs(h) do
		if d.S > 0 or d.RD then
			stunned += 1
		end
	end
	check(label .. ": the restarted blow lands but does not stun", #h >= 1 and stunned == 0, ("hits %d, stunning %d"):format(#h, stunned))
	remove(A)
	remove(B)
end
resetCase("wait out the window", function(A)
	waitChainOver(A) -- the chain's window closes while the victim is still reeling
	press(A, "Light")
end)
resetCase("uppercut re-open", function(A)
	waitChainOver(A)
	press(A, "Heavy")
end)
resetCase("block cancel", function(A)
	waitState(A, "ComboWindow")
	Service.RequestBlock(A, true)
	Env.step()
	Service.RequestBlock(A, false)
	press(A, "Light")
end)
resetCase("dash cancel into dash strike", function(A, B)
	waitState(A, "ComboWindow")
	local ok = Service.RequestDash(A, "Forward")
	Env.run(0.08)
	-- the dash carries in to the dash strike's own distance
	local pa = A.HumanoidRootPart.Position
	local dir = (B.HumanoidRootPart.Position - pa)
	dir = Vector3 and dir or dir
	local flat = V3.new(dir.X, 0, dir.Z).Unit
	local pb = pa + flat * Config.Attacks.DashAttack.Ideal
	Env.place(B, pb.X, pb.Z, -flat.X, -flat.Z)
	Env.face(A, B)
	local ok2 = press(A, "Light")
	check("  (dash " .. tostring(ok) .. ", dash strike " .. tostring(ok2) .. ")", ok and ok2)
end)

---------------------------------------------------------------------------
section("7. Anti-stunlock, three attackers taking turns: the victim always gets real windows")
do
	local x = lane()
	local V = fighter("V7", x, 0)
	local eV = Service.Get(V)
	eV.Hum.MaxHealth, eV.Hum.Health = 9999, 9999
	local atts = {}
	for i = 1, 3 do
		local ang = math.rad(i * 120)
		local ax, az = x + math.cos(ang) * 3.4, math.sin(ang) * 3.4
		local c = fighter("A7_" .. i, ax, az)
		Env.face(c, V)
		atts[i] = c
	end
	local stunned, free, longestStun, cur, windows, longestFree, curFree = 0, 0, 0, 0, 0, 0, 0
	local wasStunned = false
	local turn = 1
	local nextAt = 0
	for f = 1, 60 * 12 do
		local t = Env.now()
		-- keep everyone in place (knockback would carry the victim out of reach) and facing it
		if f % 6 == 0 then
			Env.place(V, x, 0)
			for i, c in ipairs(atts) do
				local ang = math.rad(i * 120)
				Env.place(c, x + math.cos(ang) * 3.4, math.sin(ang) * 3.4)
				Env.face(c, V)
			end
		end
		if t >= nextAt then
			Service.RequestAttack(atts[turn], { Kind = "Light" })
			turn = turn % 3 + 1
			nextAt = t + 0.28
		end
		Env.step()
		local s = eV.State == "Stunned" or eV.State == "GuardBroken"
		if s then
			stunned += 1
			cur += 1
			longestStun = math.max(longestStun, cur)
			if curFree > 0 then
				longestFree = math.max(longestFree, curFree)
			end
			curFree = 0
		else
			free += 1
			curFree += 1
			if wasStunned and cur > 0 then
				windows += 1
			end
			cur = 0
		end
		wasStunned = s
	end
	longestFree = math.max(longestFree, curFree)
	print(("     stunned %.1fs / free %.1fs, longest stun %.2fs, longest free window %.2fs, %d escape windows")
		:format(stunned / 60, free / 60, longestStun / 60, longestFree / 60, windows))
	check("no stun ever lasts longer than the budget + a hit", longestStun / 60 <= Config.StunBudget.Max + 0.35, longestStun / 60)
	check("the victim gets repeated real windows (>= 0.8 s)", longestFree / 60 >= 0.8 and windows >= 2, ("%.2f / %d"):format(longestFree / 60, windows))
	check("held no more than ~75% of the time", stunned / (stunned + free) < 0.75, stunned / (stunned + free))
	for _, c in ipairs(atts) do
		remove(c)
	end
	remove(V)
end

---------------------------------------------------------------------------
section("8. Ground Smash: standalone, verified, cooldown, area")
do
	local x = lane()
	local A = fighter("A8", x, 0)
	local B = fighter("B8", x, -3.4, 0, 1)
	local eA, eB = Service.Get(A), Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 999, 999
	-- mid-combo: refused
	press(A, "Light")
	Env.run(0.4)
	local okMid
	Env.task.spawn(function()
		okMid = Service.RequestAttack(A, { Kind = "Light", Air = true, H = 3 })
	end)
	Env.run(0.1)
	check("refused out of a live combo (ComboWindow)", okMid == false, tostring(okMid) .. " state " .. eA.State)
	Env.run(1.5)
	-- off the floor with no jump: refused
	local okFloor
	Env.task.spawn(function()
		okFloor = Service.RequestAttack(A, { Kind = "Light", Air = true })
	end)
	Env.run(0.6)
	check("refused standing on the floor (no real jump)", okFloor == false)
	-- a real jump: A in the air, B stunned by someone else, C standing in reach, D out of reach
	local C = fighter("C8", x + 5, -2, 0, 1)
	local D = fighter("D8", x + 9.5, 0, 0, 1)
	local E = fighter("E8", x, -7, 0, 1) -- B's attacker
	Env.face(E, B)
	Service.Get(C).Hum.MaxHealth, Service.Get(C).Hum.Health = 999, 999
	Service.RequestAttack(E, { Kind = "Light" })
	Env.run(0.35)
	check("(B is reeling from E's strike)", eB.State == "Stunned")
	Env.place(A, x, 0, 0, -1, 9)
	local from = since()
	local okAir, name
	Env.task.spawn(function()
		okAir, name = Service.RequestAttack(A, { Kind = "Light", Air = true, H = 6 })
	end)
	Env.run(0.05)
	check("accepted from a real jump", okAir == true and name == "Downslam", tostring(okAir) .. " " .. tostring(name))
	check("cooldown published for the HUD (server time)", type(A:GetAttribute("CombatCD_Downslam")) == "number")
	-- still airborne for a while: no impact yet
	Env.run(0.25)
	check("no impact while still in the air", #eventsOf("FX", from) == 0 or (function()
		for _, ev in ipairs(eventsOf("FX", from)) do
			if ev.Data.Kind == "Slam" then
				return false
			end
		end
		return true
	end)())
	-- touch down
	Env.place(A, x, 0, 0, -1)
	Env.run(0.3)
	local slams = {}
	for _, ev in ipairs(eventsOf("FX", from)) do
		if ev.Data.Kind == "Slam" then
			table.insert(slams, ev.Data)
		end
	end
	check("exactly one impact after the landing", #slams == 1, #slams)
	check("the impact is on the ground", slams[1] and math.abs(slams[1].P.Y - Env.groundY) < 0.01)
	local hb, hc, hd = hits(A, B, from), hits(A, C, from), hits(A, D, from)
	check("area: C in reach is hit and knocked down", #hc == 1 and hc[1].RD == true)
	check("area: D beyond the rim is not hit", #hd == 0)
	check("B (reeling from E's combo) is hit but NOT knocked down or re-stunned", #hb == 1 and hb[1].RD == false and hb[1].S == 0 and hb[1].IM == true)
	-- cooldown
	Env.run(0.6)
	Env.place(A, x, 0, 0, -1, 9)
	local okAgain
	Env.task.spawn(function()
		okAgain = Service.RequestAttack(A, { Kind = "Light", Air = true, H = 6 })
	end)
	Env.run(0.1)
	check("second smash inside the cooldown is refused", okAgain == false)
	-- never lands (over a void): no smash at all
	Env.place(A, x, 0, 0, -1)
	Env.run(2.5)
	local x2 = lane()
	local F = fighter("F8", x2, 0)
	table.insert(Env.voids, { Center = V3.new(x2, 0, 0), Radius = 6 })
	Env.place(F, x2, 0, 0, -1, 8)
	local f2 = since()
	local okV
	Env.task.spawn(function()
		okV = Service.RequestAttack(F, { Kind = "Light", Air = true, H = 5 })
	end)
	Env.run(0.05)
	-- falls through the void: keep it airborne until the deadline
	Env.run(2.0)
	local slam2 = 0
	for _, ev in ipairs(eventsOf("FX", f2)) do
		if ev.Data.Kind == "Slam" then
			slam2 += 1
		end
	end
	check("over the void: accepted, but it never smashes (no floating impact)", okV == true and slam2 == 0, ("ok %s, slams %d"):format(tostring(okV), slam2))
	for _, c in ipairs({ A, B, C, D, E, F }) do
		remove(c)
	end
end

---------------------------------------------------------------------------
section("9. Guard: 75% reduction, sweep breaks guards (no ragdoll), guard holds in the escape window")
do
	local x = lane()
	local A = fighter("A9", x, 0)
	local B = fighter("B9", x, -3.3, 0, 1)
	local eB = Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 999, 999
	local function hold()
		Env.place(A, x, 0)
		Env.place(B, x, -3.3, 0, 1)
	end
	Service.RequestBlock(B, true)
	Env.run(0.2)
	local from = since()
	press(A, "Light", nil, hold)
	press(A, "Light", nil, hold)
	press(A, "Light", nil, hold)
	press(A, "Light", nil, hold)
	for _ = 1, 90 do
		hold()
		Env.step()
	end
	local h = hits(A, B, from)
	check("four strikes into a guard all connect", #h == 4, #h)
	check("blocked light: 25% damage", h[1] and h[1].B == true and math.abs(h[1].D - Config.Attacks.Swing1.Damage * 0.25) < 1e-6, h[1] and h[1].D)
	local sweep = h[4]
	check("the sweep breaks the guard", sweep and sweep.K == "Sweep" and sweep.G == true, sweep and sweep.K)
	check("...and never ragdolls a guarding fighter", sweep and sweep.RD == false)
	check("guard broken state", eB.State == "GuardBroken" or eB.State == "Idle")
	-- in its escape window a guard holds even against a guard breaker
	Env.run(2.5)
	Service.RequestBlock(B, true)
	Env.run(0.2)
	local f2 = since()
	for i = 1, 4 do
		press(A, "Light", nil, hold)
		if i == 3 then
			eB.StunImmuneUntil = Env.now() + 2
		end
	end
	for _ = 1, 90 do
		hold()
		Env.step()
	end
	local h2 = hits(A, B, f2)
	local last = h2[#h2]
	check("escape window: the sweep is held off like a heavy blow (blocked, no break)", last and last.K == "Sweep" and last.B == true and last.G == false, last and last.K)
	remove(A)
	remove(B)
end

---------------------------------------------------------------------------
section("10. Networking: position reports can't extend reach; rewind is capped")
do
	local x = lane()
	local A, eA = fighter("A10", x, 0, 0, -1, 0.1) -- a player with 100 ms ping
	local B = fighter("B10", x, -5.4, 0, 1) -- out of reach of a standing cross, even with a full drift
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	local from = since()
	Service.RequestAttack(A, { Kind = "Light", Seq = 1, Want = 1 })
	-- a forged report 2 studs forward of where the server has a standing body
	local p = A.HumanoidRootPart.Position + V3.new(0, 0, -2)
	Service.ReportFrame(A, { Seq = 1, P = p, L = V3.new(0, 0, -1), V = V3.zero, Tau = 0.33 })
	local rep = eA.Job.Reports and eA.Job.Reports[1]
	check("a report far ahead of the server's copy is pulled back to the drift limit", rep ~= nil and (rep.P - A.HumanoidRootPart.Position).Magnitude <= Config.Hitbox.ReportDrift + 1e-3, rep and (rep.P - A.HumanoidRootPart.Position).Magnitude)
	Env.run(0.8)
	check("so the out-of-reach victim is still not hit", #hits(A, B, from) == 0)
	-- an honest report (a small lead) is accepted
	Env.run(1.2)
	Service.RequestAttack(A, { Kind = "Light", Seq = 2, Want = 1 })
	Service.ReportFrame(A, { Seq = 2, P = A.HumanoidRootPart.Position + V3.new(0, 0, -0.5), L = V3.new(0, 0, -1), V = V3.zero, Tau = 0.33 })
	check("a report within the drift allowance is accepted", eA.Job.Reports ~= nil and #eA.Job.Reports == 1)
	Env.run(1.2)
	-- rewind cap: B was right in front a moment ago but has since dashed 8 studs away
	Env.place(B, x, -3.4, 0, 1)
	Env.run(0.5)
	local f3 = since()
	Service.RequestAttack(A, { Kind = "Light", Seq = 3, Want = 1 })
	Env.run(0.05)
	Env.place(B, x, -11.4, 0, 1)
	Env.run(0.8)
	check("a victim who dashed 8 studs away 0.3 s ago can't be hit where it was", #hits(A, B, f3) == 0, #hits(A, B, f3))
	remove(A)
	remove(B)
end

---------------------------------------------------------------------------
section("11. Ground Smash landing report: must be ON the ground")
do
	local x = lane()
	local A, eA = fighter("A11", x, 0, 0, -1, 0.05)
	Env.place(A, x, 0, 0, -1, 9)
	local ok
	Env.task.spawn(function()
		ok = Service.RequestAttack(A, { Kind = "Light", Air = true, H = 6, Seq = 7 })
	end)
	Env.run(0.2)
	check("smash accepted", ok == true)
	-- a fake touchdown while still 6 studs up
	Service.ReportFrame(A, { Seq = 7, P = A.HumanoidRootPart.Position, L = V3.new(0, 0, -1), V = V3.zero, Tau = 0.35, Land = true })
	check("a touchdown report in mid-air is ignored", eA.Job.Landed ~= true)
	remove(A)
end

---------------------------------------------------------------------------
section("12. Spacing: the hitbox is the limb - every strike connects from its Ideal and exactly as far as its limb reaches")
local SEQ = { Swing1 = { "Light" }, Swing2 = { "Light", "Light" }, Swing3 = { "Light", "Light", "Light" }, Uppercut = { "Heavy" }, Sweep = { "Light", "Light", "Light", "Light" } }
local function strikeAt(name, dist)
	local x = lane()
	local A = fighter("A12", x, 0)
	local B = fighter("B12", x, -dist, 0, 1)
	Service.Get(B).Hum.MaxHealth, Service.Get(B).Hum.Health = 999, 999
	-- both pinned: no step-in, no knockback - the geometry at exactly this distance
	local function hold()
		Env.place(A, x, 0)
		Env.place(B, x, -dist, 0, 1)
	end
	local kinds = SEQ[name]
	local f2 = 0
	local ok, got
	for i = 1, #kinds do
		if i == #kinds then
			f2 = since()
		end
		ok, got = press(A, kinds[i], nil, hold)
	end
	for _ = 1, 70 do
		hold()
		Env.step()
	end
	local n = 0
	for _, d in ipairs(hits(A, B, f2)) do
		if d.K == name then
			n += 1
		end
	end
	remove(A)
	remove(B)
	return ok and got == name, n
end
for _, name in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep" }) do
	local def = Config.Attacks[name]
	local ok, n = strikeAt(name, def.Ideal)
	check(("%s at Ideal %.2f connects"):format(name, def.Ideal), ok and n == 1, n)
	local okT, nT = strikeAt(name, def.ReachMax - 0.12)
	check(("%s just inside its real limb's reach (%.2f) connects: a visible touch is a hit"):format(name, def.ReachMax - 0.12), okT and nT == 1, nT)
	local ok2, n2 = strikeAt(name, def.ReachMax + 0.25)
	check(("%s just past its real limb's reach (%.2f) misses: a visible miss is a miss"):format(name, def.ReachMax + 0.25), ok2 and n2 == 0, n2)
end

---------------------------------------------------------------------------
section("13. Walls: no blow through geometry")
do
	local x = lane()
	local A = fighter("A13", x, 0)
	local B = fighter("B13", x, -3.4, 0, 1)
	Env.addBox("Wall", V3.new(x - 4, 0, -2.2), V3.new(x + 4, 8, -2.0), true)
	local from = since()
	press(A, "Light")
	for _ = 1, 40 do
		Env.place(B, x, -3.4, 0, 1)
		Env.place(A, x, 0)
		Env.step()
	end
	check("a wall between them stops the strike", #hits(A, B, from) == 0, #hits(A, B, from))
	-- a bush (non-colliding) does not
	Env.boxes[#Env.boxes].CanCollide = false
	Env.run(1.2)
	local f2 = since()
	press(A, "Light")
	for _ = 1, 40 do
		Env.place(B, x, -3.4, 0, 1)
		Env.place(A, x, 0)
		Env.step()
	end
	check("a non-colliding decoration does not", #hits(A, B, f2) == 1, #hits(A, B, f2))
	table.remove(Env.boxes)
	remove(A)
	remove(B)
end

---------------------------------------------------------------------------
section("14. After a knockdown, a new string is a full true combo again")
do
	local x = lane()
	local A = fighter("A14", x, 0)
	local B = fighter("B14", x, -3.4, 0, 1)
	local eB = Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 9999, 9999
	local function hold()
		Env.place(A, x, 0)
		Env.place(B, x, -3.4, 0, 1)
	end
	for _ = 1, 4 do
		press(A, "Light", nil, hold)
	end
	-- down, up, and then straight into the next string the moment the fighter can be hit
	for _ = 1, 60 * 4 do
		hold()
		Env.step()
		if eB.State == "Idle" then
			break
		end
	end
	check("the fighter is back up", eB.State == "Idle", eB.State)
	local from = since()
	for _ = 1, 3 do
		press(A, "Light", nil, hold)
	end
	for _ = 1, 50 do
		hold()
		Env.step()
	end
	local h = hits(A, B, from)
	local all = #h == 3
	for _, d in ipairs(h) do
		all = all and d.S > 0
	end
	check("all three strikes of the new string stun", all, #h)
	remove(A)
	remove(B)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("combat simulation failed")
end
