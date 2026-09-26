--!nocheck
--[[
	The attacker's screen and the server give every blow the same verdict - and so the same damage
	number. Hundreds of random blows on the REAL server (CombatService on the simulated world): the
	victim raises and drops its guard at random moments around the blow, falls into and out of its
	escape window, faces the attacker or not; the attacker has a random ping; half the blows are
	guard breakers. For each, the verdict the attacker's screen reaches (Rules.Verdict - the very
	function CombatClient calls) from what that screen had seen of the victim (its CombatState and
	Escape attributes as they had arrived by then) is compared with the server's own Hit.

	    lune run tests/verdict_sync_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3 = Env.Vector3
local process = require("@lune/process")

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Rules = Env.load("ReplicatedStorage/Combat/ComboRules")
local Service = Env.load("ServerScriptService/Combat/CombatService")
math.randomseed(tonumber(process.env.SEED or "") or 11)

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

-- every attribute the server sets on a character, with when it set it
local function logged(char)
	local log = {}
	local set = char.SetAttribute
	char.SetAttribute = function(self, k, v)
		table.insert(log, { T = Env.now(), K = k, V = v })
		return set(self, k, v)
	end
	return log
end
-- what the attacker's screen had of the victim at `tau`: the attributes that had arrived by then
local function seenAt(log, tau)
	local state, esc, since = "Idle", false, -math.huge
	for _, e in ipairs(log) do
		if e.T <= tau + 1e-9 then
			if e.K == "CombatState" then
				if e.V == "Blocking" and state ~= "Blocking" then
					since = e.T
				end
				state = e.V
			elseif e.K == "Escape" then
				esc = e.V == true
			end
		end
	end
	return state, since, esc
end

local def = Config.Attacks.Swing1
local breaker0, breakDmg0 = def.GuardBreak, def.GuardBreakDamage
local trials, hits, agree, numbers = 220, 0, 0, 0
local kinds = { clean = 0, blocked = 0, broken = 0 }
local firstBad = nil
for i = 1, trials do
	local x = i * 300
	local A = Env.character("VA" .. i, V3.new(x, 3, 0), V3.new(0, 0, -1))
	local ping = math.random() * 0.3
	Service.Register(A, Env.player("VA" .. i, ping, A))
	local facing = math.random() < 0.8
	local B = Env.character("VB" .. i, V3.new(x, 3, -3.4), V3.new(0, 0, if facing then 1 else -1))
	local log = logged(B)
	Service.Register(B, nil)
	local eB = Service.Get(B)
	eB.Hum.MaxHealth, eB.Hum.Health = 5000, 5000
	Env.run(0.4)
	-- this blow: a guard breaker or not
	def.GuardBreak = math.random() < 0.5
	def.GuardBreakDamage = if def.GuardBreak then 2.2 else nil
	-- the victim's guard goes up / comes down at random moments round the blow (0.2 s is about
	-- where it lands), and it may fall into its escape window
	local upAt = math.random() * 0.6 - 0.25
	local downAt = if math.random() < 0.4 then upAt + math.random() * 0.5 else math.huge
	if math.random() < 0.3 then
		eB.StunImmuneUntil = Env.now() + math.random() * 0.5
	end
	local t0 = Env.now()
	local from = #Env.events
	Service.RequestAttack(A, { Kind = "Light" })
	local up, down = false, false
	local hit = nil
	for _ = 1, 90 do
		local el = Env.now() - t0
		if not up and el >= upAt then
			up = true
			Service.RequestBlock(B, true)
		end
		if up and not down and el >= downAt then
			down = true
			Service.RequestBlock(B, false)
		end
		Env.step()
		for k = from + 1, #Env.events do
			local ev = Env.events[k]
			if ev.Kind == "Hit" and ev.Data.A == A and ev.Data.V == B then
				hit = ev.Data
			end
		end
		if hit then
			break
		end
	end
	if hit then
		hits += 1
		local tau = Service._lastTau
		local state, since, esc = seenAt(log, tau)
		local guarded, brk = Rules.Verdict(def, {
			Blocking = state == "Blocking",
			GuardFor = tau - since,
			Facing = facing,
			Escape = esc,
			Restarted = false,
		})
		local blocked = guarded and not brk
		local predicted = if brk then def.GuardBreakDamage elseif blocked then def.Damage * Config.Guard.DamageScale else def.Damage
		local same = hit.G == brk and hit.B == blocked
		if same then
			agree += 1
		elseif not firstBad then
			firstBad = ("blow %d: screen %s/%s, server B=%s G=%s (tau %.3f, state %s up %.3f, escape %s)"):format(i, tostring(guarded), tostring(brk), tostring(hit.B), tostring(hit.G), tau, tostring(state), tau - since, tostring(esc))
		end
		if math.abs(predicted - hit.D) < 1e-6 then
			numbers += 1
		end
		kinds[if brk then "broken" elseif blocked then "blocked" else "clean"] += 1
	end
	A:Destroy()
	B:Destroy()
	Env.step()
end
def.GuardBreak, def.GuardBreakDamage = breaker0, breakDmg0

print(("  (%d blows landed: %d clean, %d blocked, %d guard breaks)"):format(hits, kinds.clean, kinds.blocked, kinds.broken))
check("every kind of verdict came up (clean, blocked, broken)", kinds.clean > 20 and kinds.blocked > 20 and kinds.broken > 10)
check(("the attacker's screen and the server agree on every blow (%d / %d)"):format(agree, hits), hits > trials * 0.9 and agree == hits, firstBad)
check(("...so the number stamped on the impact frame is the one dealt (%d / %d)"):format(numbers, hits), numbers == hits)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
