--!nocheck
--[[
	The whole chain OVER A NETWORK: the attacking client, the server and the victim's client, each
	with its own copy of the world, run frame by frame.
	  attacker client  owns its body: presses on the chain points (held M1, M2 where the sequence
	                   says), the step-in and the carry (CombatChoreo, the same code the game runs),
	                   judges its own impact frame (HitDetect) and reports where it is; it sees the
	                   victim as the server had it one trip + Roblox's interpolation ago
	  server           the real CombatService: requests and reports arrive one trip late, it rewinds
	                   the victim to what the attacker saw, decides every hit
	  victim client    owns its body (a player): the knockback starts when the server's Hit reaches it
	                   (one trip) + the hit-stop; the server - and so the attacker - sees that later
	  (dummy victims are the server's own: no victim trip)
	Every legal 4- and 5-hit sequence, at 0 to 150 ms each way, on flat ground, up and down a slope,
	over bumps and up a step: every strike must connect on the server, and the attacker's screen must
	have shown every one of them on its own frame (no hit the server gave that this screen missed, and
	no impact shown that the server then refused).

	    lune run tests/chain_net.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3, CF = Env.Vector3, Env.CFrame

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Rules = Env.load("ReplicatedStorage/Combat/ComboRules")
local Service = Env.load("ServerScriptService/Combat/CombatService")
local HitDetect = Env.load("ReplicatedStorage/Combat/HitDetect")
local Choreo = Env.load("ReplicatedStorage/Combat/CombatChoreo")

local passed, failed = 0, 0
local failures = {}
local function check(name, cond, detail)
	if cond then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. (if detail then "  -- " .. tostring(detail) else ""))
	end
end

local INTERP = 0.1 -- Roblox's replication interpolation delay
local DT = 1 / 60

local function flat(v)
	local f = V3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else V3.new(0, 0, -1)
end

-- a value history: record(t, v), at(t) = the value at time t (holding the oldest / newest)
local function history()
	local h = { T = {}, V = {} }
	function h.record(t, v)
		table.insert(h.T, t)
		table.insert(h.V, v)
		if #h.T > 600 then
			table.remove(h.T, 1)
			table.remove(h.V, 1)
		end
	end
	function h.at(t)
		local n = #h.T
		if n == 0 then
			return nil
		end
		if t <= h.T[1] then
			return h.V[1]
		end
		for i = n, 1, -1 do
			if h.T[i] <= t then
				local j = math.min(i + 1, n)
				if j == i or h.T[j] == h.T[i] then
					return h.V[i]
				end
				local k = (t - h.T[i]) / (h.T[j] - h.T[i])
				return h.V[i]:Lerp(h.V[j], k)
			end
		end
		return h.V[n]
	end
	return h
end

local function onGround(p)
	return V3.new(p.X, Env.heightAt(p.X, p.Z) + 3, p.Z)
end

local laneX = 0
--[[ one networked chain. opts: Seq = { "Light" | "Heavy", ... }, La, Lv (one-way seconds),
	Npc (victim is a server dummy), Dist (start gap), Face (victim look, flat), Terrain (name) ]]
local function runChain(opts)
	laneX += 400
	local x0 = laneX
	local la, lv = opts.La, opts.Lv
	local dir = V3.new(0, 0, -1)
	-- the attacker (a player) and its victim
	local aPos = onGround(V3.new(x0, 0, 0))
	local vPos0 = onGround(V3.new(x0, 0, -opts.Dist))
	local aChar = Env.character("NA", aPos, dir)
	local aPlayer = Env.player("NA", la * 2, aChar)
	Service.Register(aChar, aPlayer)
	local vChar = Env.character("NV", vPos0, opts.Face or V3.new(0, 0, 1))
	local vPlayer = if opts.Npc then nil else Env.player("NV", lv * 2, vChar)
	Service.Register(vChar, vPlayer)
	local eV = Service.Get(vChar)
	-- limbs lost before the fight (the attacker's / the victim's): the wounds that tear them off
	local WOUND = { 0, 30, 55 }
	local eA = Service.Get(aChar)
	if (opts.AStage or 0) > 0 then
		eA.Hum:TakeDamage(WOUND[opts.AStage + 1])
	end
	if (opts.VStage or 0) > 0 then
		eV.Hum:TakeDamage(WOUND[opts.VStage + 1])
	end
	local aStage, vStage = eA.GoreStage or 0, eV.GoreStage or 0
	assert(aStage == (opts.AStage or 0) and vStage == (opts.VStage or 0), "stages not reached")
	eV.Hum.MaxHealth, eV.Hum.Health = 9999, 9999
	local vRoot = vChar.HumanoidRootPart
	local aRoot = aChar.HumanoidRootPart

	local aHist, vTrueHist, vServerHist = history(), history(), history()
	local vPos = vPos0
	local pushes = {} -- the victim client's knockback drives { T0, Vec, Dur }
	local outbox = {} -- { At, Fn }: messages in flight
	local function send(delay, fn)
		table.insert(outbox, { At = Env.now() + delay, Fn = fn })
	end

	-- the attacker client
	local chain = Rules.New()
	local seq = 0
	local cur = nil -- the strike on screen
	local move = {}
	local predicted = {}
	local shownImpacts, serverHits = {}, {}
	local strikes = {}
	local pressIndex = 1
	local nextPressAt = Env.now() + 0.05

	local function seenVictim()
		-- the server's copy one trip + the interpolation ago
		return vServerHist.at(Env.now() - la - INTERP) or vRoot.Position
	end
	local function aheadOf(d)
		return Choreo.Ahead(aPos, d, { seenVictim() })
	end

	local function hitStop(a, d)
		if a.Stopped or d <= 0 then
			return
		end
		a.Stopped = true
		a.T0 += d
		if a.Slot > 0 then
			Rules.Delay(chain, d)
		end
	end

	local function press(kind)
		local t = Env.now()
		local verdict, name, slot, heavy, lights = Rules.Decide(chain, kind, t, nil, nil, aStage)
		if verdict ~= "go" then
			return false
		end
		local prev = if slot > 1 then chain.Last else nil
		local _, enter = Config.Transition(prev, name)
		local def = Config.Attacks[name]
		Rules.Commit(chain, name, slot, heavy, lights, t - enter / def.Speed, aStage)
		seq += 1
		local a = { Name = name, Slot = slot, T0 = t - enter / def.Speed, Seq = seq, Def = def, Stopped = false, Enter = enter }
		cur = a
		table.insert(strikes, a)
		local step = Choreo.NewStep(def, enter, dir, t)
		if step then
			step.Serial = seq
			move.Step = step
		end
		local mySeq = seq
		send(la, function()
			local ok = Service.RequestAttack(aChar, { Kind = kind, Want = slot, Seq = mySeq })
			a.Accepted = ok
		end)
		-- reports as the active frames begin and midway
		local path = HitDetect.Paths[name]
		for _, frac in ipairs({ 0, 0.5 }) do
			local tau = path.From + (path.To - path.From) * frac
			a["Rep" .. frac] = tau
		end
		return true
	end

	-- the server's words, as they arrive at each client
	Env.onEvent = function(ev)
		if ev.Kind ~= "Hit" or ev.Data.A ~= aChar then
			return
		end
		local d = ev.Data
		table.insert(serverHits, d)
		-- the victim's client: its knockback starts when the Hit reaches it, after the hit-stop
		if not opts.Npc and d.V == vChar and d.KT and d.KT > 0 then
			local kb = V3.new(d.KB.X, 0, d.KB.Z)
			local hs = d.HS or 0
			send(lv, function()
				table.insert(pushes, { T0 = Env.now() + hs, Vec = kb, Dur = d.KT })
			end)
		end
		-- the attacker's client: an impact this screen missed plays when the word arrives
		send(la, function()
			local a = nil
			for _, s in ipairs(strikes) do
				if s.Seq == d.Seq then
					a = s
				end
			end
			if a and not predicted[d.Seq] then
				hitStop(a, d.HS or 0)
				if not d.B and not d.RD and (d.KT or 0) > 0.02 and a.Slot > 0 then
					move.Carry = Choreo.NewCarry(a.Def, dir, Env.now(), d.HS or 0, chain)
				end
			end
		end)
	end

	local seqKinds = opts.Seq
	local maxT = Env.now() + 5
	while Env.now() < maxT do
		local t = Env.now()
		-- messages due
		for i = #outbox, 1, -1 do
			if outbox[i].At <= t + 1e-9 then
				local m = table.remove(outbox, i)
				m.Fn()
			end
		end
		-- the attacker presses: the first at once, then each on its chain point (held M1 / M2)
		if pressIndex <= #seqKinds and t >= nextPressAt then
			local waitOpen = chain.Slot > 0 and t < chain.OpenAt
			if not waitOpen then
				if press(seqKinds[pressIndex]) then
					pressIndex += 1
				end
			end
			nextPressAt = if chain.Slot > 0 then chain.OpenAt else t + DT
		end
		-- the attacker's body: step-in + carry, straight along its facing
		local v = Choreo.Velocity(move, t, DT, aheadOf)
		aPos = onGround(aPos + v * DT)
		-- reports (as the clip reaches the active frames)
		if cur then
			local tau = (t - cur.T0) * cur.Def.Speed
			for _, frac in ipairs({ 0, 0.5 }) do
				local key = "Rep" .. frac
				if cur[key] and tau >= cur[key] then
					cur[key] = nil
					local p, s = aPos, cur.Seq
					send(la, function()
						Service.ReportFrame(aChar, { Seq = s, P = p, L = dir, V = v, Tau = tau })
					end)
				end
			end
			-- this screen's own impact frame
			local def = cur.Def
			local path = HitDetect.Paths[def.Id]
			if not cur.Impact and tau >= path.From and (cur.PrevTau or path.From) <= path.To then
				local from = cur.PrevTau or path.From
				local to = math.min(tau, path.To)
				cur.PrevTau = to
				if to >= from then
					local seen = seenVictim()
					local acf = CF.lookAt(aPos, aPos + dir)
					local vl = flat(vRoot.CFrame.LookVector)
					local vcf = CF.lookAt(seen, seen + vl)
					local hit = HitDetect.Sweep(def.Id, acf, vcf, from, to, HitDetect.Radius(def.Id), vStage, aStage)
					if hit then
						cur.Impact = true
						predicted[cur.Seq] = true
						local gap = V3.new(seen.X - aPos.X, 0, seen.Z - aPos.Z).Magnitude
						table.insert(shownImpacts, { Name = def.Id, Gap = gap })
						hitStop(cur, def.ClassDef.Hitstop)
						if cur.Slot > 0 and not def.Launch then
							move.Carry = Choreo.NewCarry(def, dir, t, def.ClassDef.Hitstop, chain)
						end
					end
				end
			end
		end
		-- the victim's own client (a player): its knockback
		if not opts.Npc then
			local pv = V3.zero
			for i = #pushes, 1, -1 do
				local p = pushes[i]
				local e = t - p.T0
				if e >= p.Dur then
					table.remove(pushes, i)
				elseif e >= 0 then
					-- a newer push replaces the one running (Motion.Push restarts the drive)
					if i == #pushes then
						local k = 1 - e / p.Dur
						pv = p.Vec * (0.35 + 0.65 * k * k)
					end
				end
			end
			vPos = onGround(vPos + pv * DT)
			vTrueHist.record(t, vPos)
			-- the server's copy of the victim: one trip behind its own client
			local sv = vTrueHist.at(t - lv) or vPos
			vRoot.CFrame = CF.lookAt(sv, sv + flat(vRoot.CFrame.LookVector))
		end
		-- the server's copy of the attacker: one trip behind
		aHist.record(t, aPos)
		local sa = aHist.at(t - la) or aPos
		aRoot.CFrame = CF.lookAt(sa, sa + dir)
		Env.step(DT)
		vServerHist.record(Env.now(), vRoot.Position)
		if pressIndex > #seqKinds and cur and t > cur.T0 + cur.Def.LengthReal + 0.6 then
			break
		end
	end
	Env.onEvent = nil
	-- what the server decided, strike by strike
	local names, got = {}, {}
	for _, s in ipairs(strikes) do
		table.insert(names, s.Name)
		local ok = false
		for _, d in ipairs(serverHits) do
			if d.Seq == s.Seq and d.V == vChar then
				ok = true
			end
		end
		got[#got + 1] = ok
	end
	aChar:Destroy()
	vChar:Destroy()
	Env.step()
	return names, got, strikes, shownImpacts, predicted
end

---------------------------------------------------------------------------
local SEQUENCES = {
	{ "Light", "Light", "Light", "Light" },
	{ "Heavy", "Light", "Light", "Light", "Light" },
	{ "Light", "Heavy", "Light", "Light", "Light" },
	{ "Light", "Light", "Heavy", "Light", "Light" },
	{ "Light", "Light", "Light", "Heavy", "Light" },
}
local TERRAINS = {
	Flat = nil,
	Uphill = function(_x, z)
		return -z * math.tan(math.rad(15)) -- rising the way the attacker faces (-Z)
	end,
	Downhill = function(_x, z)
		return z * math.tan(math.rad(15))
	end,
	Bumps = function(x, z)
		return 0.4 * math.sin(x * 1.3) * math.cos(z * 1.1)
	end,
	Step = function(_x, z)
		return if z < -5 then 0.5 else 0 -- a kerb the fight crosses
	end,
}
local LATENCY = { 0, 0.05, 0.1, 0.15 }

local total, worst = 0, {}
for _, terrain in ipairs({ "Flat", "Uphill", "Downhill", "Bumps", "Step" }) do
	Env.groundAt = TERRAINS[terrain]
	for _, npc in ipairs({ false, true }) do
		for _, la in ipairs(LATENCY) do
			for _, dist in ipairs({ 3.7, 5.0 }) do
				for _, seqKinds in ipairs(SEQUENCES) do
					total += 1
					local names, got, strikes, shown, predicted = runChain({ Seq = seqKinds, La = la, Lv = la, Npc = npc, Dist = dist, Terrain = terrain })
					local label = ("%s %s %dms start %.1f: %s"):format(terrain, if npc then "dummy" else "player", la * 1000, dist, table.concat(names, " "))
					local all = #names == #seqKinds
					local miss = {}
					for i, ok in ipairs(got) do
						if not ok then
							all = false
							table.insert(miss, names[i])
						end
					end
					check(label .. ": every strike connects", all, "missed " .. table.concat(miss, ","))
					-- the attacker's screen showed each one on its own frame, and nothing the server refused
					local ghost, unseen = {}, {}
					for i, s in ipairs(strikes) do
						if predicted[s.Seq] and not got[i] then
							table.insert(ghost, s.Name)
						end
						if got[i] and not predicted[s.Seq] then
							table.insert(unseen, s.Name)
						end
					end
					check(label .. ": the attacker's screen showed every impact on its frame", #unseen == 0, "server-only: " .. table.concat(unseen, ","))
					check(label .. ": no impact shown that the server refused", #ghost == 0, "ghost: " .. table.concat(ghost, ","))
					for _, im in ipairs(shown) do
						local def = Config.Attacks[im.Name]
						local w = worst[im.Name] or { Lo = math.huge, Hi = -math.huge }
						w.Lo = math.min(w.Lo, im.Gap)
						w.Hi = math.max(w.Hi, im.Gap)
						worst[im.Name] = w
						check(label .. (": %s landed within its limb's reach (%.2f)"):format(im.Name, im.Gap), im.Gap <= def.ReachMax + 0.15 and im.Gap >= def.Ideal - 1.0)
					end
				end
			end
		end
	end
end
-- one arm left: single strikes (M1 the left straight, M2 the left uppercut), at a whole victim and
-- at an armless one (its narrower body), on every ground, every latency, a player and a dummy
local SINGLES = { { "Light", "Light", "Light" }, { "Heavy", "Light", "Heavy" } }
for _, terrain in ipairs({ "Flat", "Uphill", "Downhill", "Bumps", "Step" }) do
	Env.groundAt = TERRAINS[terrain]
	for _, npc in ipairs({ false, true }) do
		for _, la in ipairs(LATENCY) do
			for _, vStage in ipairs({ 0, 2 }) do
				for _, seqKinds in ipairs(SINGLES) do
					total += 1
					local names, got, strikes, shown, predicted = runChain({ Seq = seqKinds, La = la, Lv = la, Npc = npc, Dist = 3.7, Terrain = terrain, AStage = 1, VStage = vStage })
					local label = ("ONE ARM %s %s%s %dms: %s"):format(terrain, if npc then "dummy" else "player", if vStage > 0 then " (armless)" else "", la * 1000, table.concat(names, " "))
					local all = #names == #seqKinds
					for i, ok in ipairs(got) do
						all = all and ok and (names[i] == Config.Gore.OneArm.Light or names[i] == Config.Gore.OneArm.Heavy)
					end
					check(label .. ": every single strike (the left hand's) connects", all, table.concat(names, ","))
					local ghost, unseen = 0, 0
					for i, s in ipairs(strikes) do
						if predicted[s.Seq] and not got[i] then
							ghost += 1
						end
						if got[i] and not predicted[s.Seq] then
							unseen += 1
						end
					end
					check(label .. ": the screen showed every impact on its frame, and none the server refused", ghost == 0 and unseen == 0, ("ghost %d unseen %d"):format(ghost, unseen))
					for _, im in ipairs(shown) do
						local def = Config.Attacks[im.Name]
						check(label .. (": %s landed within its limb's reach (%.2f)"):format(im.Name, im.Gap), im.Gap <= def.ReachMax + 0.15 and im.Gap >= def.Ideal - 1.0)
					end
				end
			end
		end
	end
end
Env.groundAt = nil

print(("%d chains run"):format(total))
for _, name in ipairs({ "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep" }) do
	local w = worst[name]
	if w then
		print(("  %-9s impacts on the attacker's screen at %.2f .. %.2f studs (Ideal %.2f, limb reach %.2f)"):format(name, w.Lo, w.Hi, Config.Attacks[name].Ideal, Config.Attacks[name].ReachMax))
	end
end
for i, f in ipairs(failures) do
	if i > 40 then
		print(("  ... and %d more"):format(#failures - 40))
		break
	end
	print("  FAIL  " .. f)
end
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("networked chain simulation failed")
end
