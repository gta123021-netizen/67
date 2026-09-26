--!nocheck
--[[
	The damage number the attacker's screen stamps on its impact frame is the one the server deals:
	the server judges the guard and the escape window AS THAT SCREEN SAW THEM (its state a round trip
	old), and the screen predicts with the same rules (the guard up long enough, the Escape
	attribute). Run on the REAL server (CombatService on the simulated world).

	    lune run tests/guard_sync_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3 = Env.Vector3
local process = require("@lune/process")

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
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

local PING = 0.2 -- the attacker's round trip (its screen shows the server's state 0.2 s old)
local nextX = 0
local function pair(tag)
	nextX += 200
	local x = nextX
	local A = Env.character("GA" .. tag, V3.new(x, 3, 0), V3.new(0, 0, -1))
	Service.Register(A, Env.player("GA" .. tag, PING, A))
	local B = Env.character("GB" .. tag, V3.new(x, 3, -3.4), V3.new(0, 0, 1))
	Service.Register(B, nil)
	local eB = Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	return A, B, x
end
-- A's opening strike on B; `before(dtToHit)` runs every frame with the time left to the server's
-- hit (measured on an identical dry run first). Returns the Hit
local hitAfter = nil
local function strike(A, B, x, before, kind)
	Env.place(A, x, 0, 0, -1)
	Env.place(B, x, -3.4, 0, 1)
	Env.run(0.5) -- (the bodies' recent history settles where they now stand: the server rewinds it)
	local from = #Env.events
	local t0 = Env.now()
	Service.RequestAttack(A, { Kind = kind or "Light" })
	for _ = 1, 120 do
		if before and hitAfter then
			before(hitAfter - (Env.now() - t0))
		end
		Env.step()
		for i = from + 1, #Env.events do
			local ev = Env.events[i]
			if ev.Kind == "Hit" and ev.Data.A == A and ev.Data.V == B then
				hitAfter = hitAfter or (Env.now() - t0)
				Env.run(1.2)
				return ev.Data
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------
section("1  the rule: the guard's history")
---------------------------------------------------------------------------
do
	local _, B = pair("h")
	local eB = Service.Get(B)
	local t0 = Env.now()
	Service.RequestBlock(B, true)
	Env.run(0.5)
	Service.RequestBlock(B, false)
	local t1 = Env.now()
	Env.run(0.3)
	local G = Config.Guard.StartDelay
	check("up (after its start delay) while it was held", Service._guardedAt(eB, t0 + G + 0.01) and Service._guardedAt(eB, t1 - 0.01))
	check("not before it was up long enough, nor after it dropped", not Service._guardedAt(eB, t0 + G * 0.5) and not Service._guardedAt(eB, t1 + 0.01) and not Service._guardedAt(eB, t0 - 0.1))
end

---------------------------------------------------------------------------
section("2  a guard raised at the last instant (after the attacker's screen saw the blow land)")
---------------------------------------------------------------------------
do
	local A, B, x = pair("r")
	local dry = strike(A, B, x)
	check(("(dry run: a clean hit, %.3f s after the press)"):format(hitAfter or -1), dry ~= nil and not dry.B)
	Env.run(1.5)
	local raised = false
	local h = strike(A, B, x, function(left)
		-- the guard goes up 0.08 s before the server's hit: after the attacker's screen (0.2 s behind)
		-- showed the blow landing
		if not raised and left <= 0.08 then
			raised = Service.RequestBlock(B, true)
		end
	end)
	check("the guard went up before the server's hit", raised)
	check("... too late for the blow the attacker saw: clean, full damage (what its screen stamped)", h ~= nil and not h.B and math.abs(h.D - Config.Attacks[h.K].Damage) < 1e-6, h and h.D)
	Service.RequestBlock(B, false)
end

---------------------------------------------------------------------------
section("3  a guard dropped at the last instant (the attacker's screen still showed it up)")
---------------------------------------------------------------------------
do
	local A, B, x = pair("d")
	Env.run(1.5)
	Service.RequestBlock(B, true)
	Env.run(0.6)
	local dropped = false
	local h = strike(A, B, x, function(left)
		if not dropped and left <= 0.08 then
			Service.RequestBlock(B, false)
			dropped = Service.Get(B).State ~= "Blocking"
		end
	end)
	check("the guard came down before the server's hit", dropped)
	check("... but the attacker's screen showed it up: blocked, the chip (what its screen stamped)", h ~= nil and h.B and math.abs(h.D - Config.Attacks[h.K].Damage * Config.Guard.DamageScale) < 1e-6, h and tostring(h.B) .. " " .. h.D)
end

---------------------------------------------------------------------------
section("4  the escape window: published, and judged at the same moment")
---------------------------------------------------------------------------
do
	local _, B = pair("e")
	local eB = Service.Get(B)
	check("not in it: the Escape attribute off", B:GetAttribute("Escape") == false and eB.Escape == false)
	local t0 = Env.now()
	eB.StunImmuneUntil = t0 + 0.5
	Env.step()
	check("in it: the Escape attribute on the character at once (every screen predicts with it)", B:GetAttribute("Escape") == true)
	Env.run(0.7)
	check("... and off when it ends", B:GetAttribute("Escape") == false)
	check("its history: in it during, not before or after", Service._escapeAt(eB, t0 + 0.25) and not Service._escapeAt(eB, t0 - 0.2) and not Service._escapeAt(eB, t0 + 0.65))
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
