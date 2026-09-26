--!nocheck
--[[
	Pure-logic tests for what the attacking CLIENT decides and for the HUD column's layout math:
	  - the critically damped facing turn (Motion.Turn): no overshoot, never faster than its top
	    rate, the same at any frame rate
	  - the input buffer (ComboRules.BufferTake) with the chain's own timing (ComboRules.Decide)
	  - client and server picking the same strike for the same press at any latency
	  - the HUD column (Theme.Hud): equal gaps between every pair of groups, party frames never
	    meeting the portal card, at every screen / HUD size

	    lune run tests/logic_test.luau        (from the repository root)
]]
local Env = require("./sim/env")

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Rules = Env.load("ReplicatedStorage/Combat/ComboRules")
local Motion = Env.loadReal("ReplicatedStorage/Combat/Motion", "ReplicatedStorage__Combat__Motion.lua")
local Theme = Env.load("ReplicatedStorage/OverkillUI/Theme")

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

---------------------------------------------------------------------------
section("Facing turn (Motion.Turn)")
local L = Config.Lock.Turn
local function turn(offset, hz, omega, maxRate)
	local dt = 1 / hz
	local vel, t = 0, 0
	local sign = if offset > 0 then 1 else -1
	local overshoot = false
	local peak = 0
	while t < 2 do
		local step, v = Motion.Turn(offset, vel, omega, maxRate, dt)
		peak = math.max(peak, math.abs(step) / dt)
		offset += step
		vel = v
		t += dt
		if offset * sign < -1e-6 then
			overshoot = true
		end
		if math.abs(offset) < math.rad(1) then
			return t, overshoot, peak
		end
	end
	return math.huge, overshoot, peak
end
for _, hz in ipairs({ 30, 60, 144, 240 }) do
	local t, over, peak = turn(math.pi, hz, L.Omega, L.MaxRate)
	check(("180 deg at %d fps: within 1 deg in %.3f s, never faster than %.0f deg/s, no overshoot"):format(hz, t, math.deg(L.MaxRate)), t >= math.pi / L.MaxRate * 0.97 and t < 0.6 and not over and peak <= L.MaxRate + 1e-6, ("%.3f %s %.2f"):format(t, tostring(over), peak))
	local t2, over2 = turn(math.rad(12), hz, L.Omega, L.MaxRate)
	check(("12 deg correction at %d fps settles in %.3f s without overshoot"):format(hz, t2), t2 < 0.25 and not over2)
end

---------------------------------------------------------------------------
section("Input buffer + chain timing")
local ATTACKS = { Light = true, Heavy = true }
local DASH = { Dash = true }
local BUF = Config.Combo.Buffer
do
	local c = Rules.New()
	Rules.Commit(c, "Swing1", 1, false, 1, 0)
	local open = c.OpenAt
	-- slightly early: buffered, fires exactly once at the chain point
	local tPress = open - 0.18
	local v = Rules.Decide(c, "Light", tPress)
	check("a press 0.18 s before the chain point is 'early'", v == "early")
	check("...and within the buffer window, so it is kept", tPress >= open - BUF)
	local buf = Rules.BufferPress("Light", tPress, 1)
	local k, drop = Rules.BufferTake(buf, ATTACKS, open, 1, 0.15)
	check("at the chain point the buffered press fires", k == "Light" and drop == true)
	local v2, name = Rules.Decide(c, "Light", open)
	check("...as the next strike (Swing2)", v2 == "go" and name == "Swing2")
	-- extremely early: not kept
	local tooEarly = open - BUF - 0.05
	check("a press further back than the buffer window is not kept", Rules.Decide(c, "Light", tooEarly) == "early" and tooEarly < open - BUF)
	-- stale
	local stale = Rules.BufferPress("Light", 0, 1)
	local k2, d2 = Rules.BufferTake(stale, ATTACKS, BUF + 0.2, 1, 0.15)
	check("a stale press is dropped, never fired late", k2 == nil and d2 == true)
	-- another chain
	local old = Rules.BufferPress("Light", open - 0.1, 1)
	local k3, d3 = Rules.BufferTake(old, ATTACKS, open, 2, 0.15)
	check("a press meant for another chain is dropped", k3 == nil and d3 == true)
	-- kinds
	local dash = Rules.BufferPress("Dash", 1.0, 1)
	local k4, d4 = Rules.BufferTake(dash, ATTACKS, 1.05, nil, 0.15)
	check("a buffered dash is kept by a spot that only takes strikes", k4 == nil and d4 == false)
	local k5 = Rules.BufferTake(dash, DASH, 1.1, nil, 0.15)
	check("...and fires where dashes are taken", k5 == "Dash")
	local k6 = Rules.BufferTake(dash, DASH, 1.2, nil, 0.15)
	check("a dash press older than its own window is dropped", k6 == nil)
	-- late: a press after the window starts a new chain, never continues the old one
	local late = c.CloseAt + 0.05
	local v3, name3, slot3 = Rules.Decide(c, "Light", late)
	check("a late press starts a new chain (Swing1, slot 1)", v3 == "go" and name3 == "Swing1" and slot3 == 1)
end
do
	-- held M1 flows through the whole chain, the M2 goes in once
	local c = Rules.New()
	local t = 0
	local seq = {}
	local kinds = { "Light", "Heavy", "Light", "Heavy", "Light", "Light", "Light" }
	for _, kind in ipairs(kinds) do
		local v, name, slot, heavy, lights = Rules.Decide(c, kind, t)
		if v == "go" then
			Rules.Commit(c, name, slot, heavy, lights, t)
			table.insert(seq, name)
			t = c.OpenAt ~= 0 and c.OpenAt or t
			if name == "Sweep" then
				break
			end
		else
			table.insert(seq, "(" .. v .. ")")
		end
	end
	check("held M1 with M2 mashed: " .. table.concat(seq, " "), table.concat(seq, " ") == "Swing1 Uppercut Swing2 (no) Swing3 Sweep")
end

---------------------------------------------------------------------------
section("Client and server agree on the strike at every latency")
do
	local disagree, cases = 0, 0
	for _, lat in ipairs({ 0, 0.03, 0.06, 0.1, 0.15 }) do
		for _, kinds in ipairs({ { "Light", "Light", "Light", "Light" }, { "Heavy", "Light", "Light", "Light", "Light" }, { "Light", "Light", "Heavy", "Light", "Light" } }) do
			for _, jitter in ipairs({ -0.03, 0, 0.05, 0.2, 0.38 }) do
				local cc, sc = Rules.New(), Rules.New()
				local t = 0
				for i, kind in ipairs(kinds) do
					-- the client presses on (or a little around) its chain point
					local press = if i == 1 then 0 else math.max(cc.OpenAt, cc.OpenAt + jitter)
					local cv, cname, cslot, cheavy, clights = Rules.Decide(cc, kind, press)
					if cv ~= "go" then
						break
					end
					Rules.Commit(cc, cname, cslot, cheavy, clights, press)
					-- the server hears it `lat` later with its slack, told the slot the client plays
					local arrive = press + lat
					local sv, sname, sslot, sheavy, slights = Rules.Decide(sc, kind, arrive, Config.Combo.Slack, cslot)
					cases += 1
					if sv ~= "go" or sname ~= cname or sslot ~= cslot then
						disagree += 1
						break
					end
					Rules.Commit(sc, sname, sslot, sheavy, slights, arrive - lat)
					t = press
				end
			end
		end
	end
	check(("%d presses at 0-150 ms one-way latency: client and server pick the same strike"):format(cases), disagree == 0, disagree)
end

---------------------------------------------------------------------------
section("HUD column layout (Theme.Hud)")
do
	local H = Theme.Hud
	local ink = H.Outline * 1.35 -- the outline's width; half of it lies outside each frame
	local check1, overlaps, uneven = 0, 0, 0
	for _, scale in ipairs({ 0.5, 0.62, 0.8, 1, 1.13, 1.35 }) do
		for _, user in ipairs({ 0.8, 1, 1.2 }) do
			local s = scale * user
			for _, party in ipairs({ 0, 2, 3, 4 }) do
				for _, portal in ipairs({ false, true }) do
					-- the column, bottom up (desktop): level, coins, hero, dock, portal, party
					local groups = {
						{ "Level", H.PillHeight }, { "Coins", H.PillHeight }, { "Hero", H.PillHeight }, { "Dock", H.TileHeight },
					}
					if portal then
						table.insert(groups, { "Portal", H.CardHeight })
					end
					if party > 0 then
						table.insert(groups, { "Party", H.PartyHeaderHeight + party * H.PartyRowHeight + party * H.RowGap })
					end
					-- UIListLayout, bottom aligned: whole layout units, then scaled to the screen
					local y = 1080 / s - H.Bottom
					local rects = {}
					for _, g in ipairs(groups) do
						local bottom = y
						local top = y - g[2]
						table.insert(rects, { Name = g[1], Top = top * s - ink * s / 2, Bottom = bottom * s + ink * s / 2 })
						y = top - H.GroupGap
					end
					local first = nil
					for i = 2, #rects do
						local gap = rects[i - 1].Top - rects[i].Bottom
						first = first or gap
						check1 += 1
						if math.abs(gap - first) > 1e-6 then
							uneven += 1
						end
						if gap <= 0 then
							overlaps += 1
						end
					end
				end
			end
		end
	end
	check(("%d neighbour pairs across screen / HUD sizes, party 0-4, card on/off: every gap identical"):format(check1), uneven == 0, uneven)
	check("no two groups ever overlap (the party frames never meet the portal card)", overlaps == 0, overlaps)
	check(("the visible ink gap is %.3f layout units everywhere"):format(H.GroupGap - ink), H.GroupGap - ink > 5)
	check("the dock row is exactly the column's width (5 tiles, 4 gaps)", 5 * H.TileWidth + 4 * H.IconGap == H.ColumnWidth)
	check("HUD_GROUP_GAP is the shared constant", Theme.HUD_GROUP_GAP == H.GroupGap)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("logic tests failed")
end
