--!nocheck
--[[
	The blood, run headless against the simulated world (sim/env + sim/client): the REAL CombatBlood
	module, frame by frame. What it proves:
	  1  the flight is exact: the closed-form integration matches a fine RK4 solution of
	     dv/dt = -k v + g, composes exactly, and lands a drop on the same spot at any frame rate
	  2  every drop that meets something ends exactly ON it - floor, 25 deg slope, bumps, a wall, a
	     ceiling - never inside it, and is gone there
	  3  never over an edge: drops at a step's edge or a ledge's rim end on the ground or fall away
	  4  water swallows drops; glass, triggers and non-colliding decorations don't stop them; a thin
	     wall is never tunnelled through, even by fast drops at 20 fps
	  5  the spray leaves the body OUTWARD from the wound at every tier and every angle (relative to
	     the struck part's own motion), carried the way the blow drove it
	  6  the particle bursts can never reach the floor or a wall before they have faded, sprayed at
	     shin height, next to a wall, up against a ceiling
	  7  the drop pool holds its size, is reused, and nothing is left flying
	  8  a hit bursts the place's own effects; nothing is left behind (there is no splatter code)

	    lune run tests/blood_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local Client = require("./sim/client")(Env)
local TEMPLATES = require("./sim/vfx_templates")
Client.vfxFolder(TEMPLATES)
local V3, CF = Env.Vector3, Env.CFrame

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Blood = Env.load("ReplicatedStorage/Combat/CombatBlood")
local B = Config.Blood
local process = require("@lune/process")
math.randomseed(tonumber(process.env.SEED or "") or 7) -- (SEED=n runs another draw)

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

local K, g = B.Drag, Blood.Gravity
local GV = V3.new(0, -g, 0)

-- reset the world between cases
local function world(groundAt)
	Env.groundAt = groundAt
	table.clear(Env.boxes)
	table.clear(Env.voids)
	table.clear(Env.waters)
	Blood.Clear()
	for k in pairs(Blood.Stats) do
		Blood.Stats[k] = 0
	end
	Env.run(0.05)
end

-- where the drops of the last spray ended: every drop is marked first (a drop's Pos is where it met
-- something; one that met nothing by the end of its life is lost, not landed)
local UNUSED = V3.new(0, -9999, 0)
local function markDrops()
	for _, d in ipairs(Blood.Drops) do
		d.Pos = UNUSED
	end
end
local function landings()
	local out = {}
	for _, d in ipairs(Blood.Drops) do
		if not d.Live and d.Pos.Y > -9000 and d.Age <= 2.5 then
			table.insert(out, d.Pos)
		end
	end
	return out
end

-- how far `p` is from the nearest solid surface (ground or colliding box), and whether it is inside
-- one by more than a hair
local function surfaceGap(p)
	local best = math.huge
	local inside = false
	local void = false
	for _, v in ipairs(Env.voids) do
		if (V3.new(p.X, 0, p.Z) - V3.new(v.Center.X, 0, v.Center.Z)).Magnitude < v.Radius then
			void = true
		end
	end
	if not void then
		local gy = Env.heightAt(p.X, p.Z)
		best = math.abs(p.Y - gy)
		inside = p.Y < gy - 0.01
	end
	for _, b in ipairs(Env.boxes) do
		if b.CanCollide and b.Transparency < 0.5 then
			local dx = math.max(b.Min.X - p.X, 0, p.X - b.Max.X)
			local dy = math.max(b.Min.Y - p.Y, 0, p.Y - b.Max.Y)
			local dz = math.max(b.Min.Z - p.Z, 0, p.Z - b.Max.Z)
			local out = math.sqrt(dx * dx + dy * dy + dz * dz)
			if out == 0 then
				local depth = math.min(p.X - b.Min.X, b.Max.X - p.X, p.Y - b.Min.Y, b.Max.Y - p.Y, p.Z - b.Min.Z, b.Max.Z - p.Z)
				inside = inside or depth > 0.01
				best = math.min(best, depth)
			else
				best = math.min(best, out)
			end
		end
	end
	return best, inside
end

-- fly one drop to the end with a given frame time (the module's own flight: substeps + rays)
local function flyDrop(pos, vel, dt)
	local d = { Pos = pos, Vel = vel, Size = 0.12, Age = 0, Live = true, Part = Client.new("Part") }
	local t = 0
	while d.Live and t < 3 do
		Blood.Fly(d, dt)
		t += dt
	end
	return d
end

---------------------------------------------------------------------------
section("1. The flight is exact")
do
	-- against a fine RK4 solution
	local x0, v0 = V3.new(0, 10, 0), V3.new(14, 9, -3)
	local function f(v)
		return -v * K + GV
	end
	local x, v = x0, v0
	local h = 1 / 4000
	for _ = 1, 4000 do
		local k1v = f(v)
		local k1x = v
		local k2v = f(v + k1v * h / 2)
		local k2x = v + k1v * h / 2
		local k3v = f(v + k2v * h / 2)
		local k3x = v + k2v * h / 2
		local k4v = f(v + k3v * h)
		local k4x = v + k3v * h
		x += (k1x + k2x * 2 + k3x * 2 + k4x) * (h / 6)
		v += (k1v + k2v * 2 + k3v * 2 + k4v) * (h / 6)
	end
	local xe, ve = Blood.Advance(x0, v0, 1)
	-- (Vector3 is single precision: 4000 RK4 steps accumulate ~1e-5 of float rounding by themselves)
	check(("closed form matches RK4 after 1 s (position off by %.1e studs, velocity by %.1e)"):format((xe - x).Magnitude, (ve - v).Magnitude), (xe - x).Magnitude < 1e-3 and (ve - v).Magnitude < 1e-3)
	-- composition: two half steps are the same flight as one step
	local xa, va = Blood.Advance(x0, v0, 0.37)
	local xb, vb = Blood.Advance(xa, va, 0.63)
	check(("advancing 0.37 s then 0.63 s is advancing 1 s (off by %.1e)"):format((xb - xe).Magnitude), (xb - xe).Magnitude < 1e-4 and (vb - ve).Magnitude < 1e-4)
	-- terminal velocity
	local _, vt = Blood.Advance(x0, v0, 30)
	check(("falls at its terminal speed g/k = %.1f studs/s in the end"):format(g / K), math.abs(vt.Y + g / K) < 1e-3 and math.abs(vt.X) < 1e-3)
end
do
	world(nil)
	local spots = {}
	for _, fps in ipairs({ 20, 30, 60, 144, 240 }) do
		local d = flyDrop(V3.new(0, 4, 0), V3.new(11, 7, 3), 1 / fps)
		spots[fps] = d.Pos
	end
	local ref = spots[240]
	local worst = 0
	for _, p in pairs(spots) do
		worst = math.max(worst, (p - ref).Magnitude)
	end
	check(("the same drop lands on the same spot at 20, 30, 60, 144 and 240 fps (spread %.4f studs)"):format(worst), worst < 0.005, worst)
	-- where it lands is where the physics says: solve the analytic flight for the floor crossing
	local lo, hi = 0, 3
	for _ = 1, 60 do
		local mid = (lo + hi) / 2
		local p = Blood.Advance(V3.new(0, 4, 0), V3.new(11, 7, 3), mid)
		if p.Y > 0 then
			lo = mid
		else
			hi = mid
		end
	end
	local exact = Blood.Advance(V3.new(0, 4, 0), V3.new(11, 7, 3), lo)
	check(("...which is the analytic landing point (off by %.4f studs)"):format((ref - exact).Magnitude), (ref - exact).Magnitude < 0.005)
end

-- the droplets (the gore's bleeding; a hit's spray is the place's effects, section 8): thrown out of
-- a wound in a splash crown, carried with the struck part
local function launchDrops(pos, drive, tierName, victim)
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local normal, head = Blood.Wound(pos, drive, tier, victim, 1)
	for _ = 1, 8 do
		Blood.Launch(pos + normal * 0.05, head + Blood.Crown(normal, tier), 0.09 + math.random() * 0.08)
	end
end

---------------------------------------------------------------------------
section("2. Every drop ends ON the surface it hit, and is gone")
local function sprayAt(groundAt, boxes, pos, drive, tier, n)
	world(groundAt)
	for _, b in ipairs(boxes or {}) do
		Env.addBox(b[1], b[2], b[3], b[4] ~= false, b[5])
	end
	markDrops()
	for _ = 1, n or 6 do
		launchDrops(pos, drive, tier)
	end
	Env.run(2.6)
	return landings()
end
local function allOn(label, points, where)
	local ok, worst, why = true, 0, nil
	local counted = 0
	for _, p in ipairs(points) do
		if not where or where(p) then
			counted += 1
			local gap, inside = surfaceGap(p)
			if inside then
				ok, why = false, ("inside a surface at %s"):format(tostring(p))
				break
			end
			if gap > 0.02 then
				ok, why = false, ("%.3f off any surface at %s"):format(gap, tostring(p))
				break
			end
			worst = math.max(worst, gap)
		end
	end
	check(("%s: %d drops, every one ended on the surface (worst %.4f studs)"):format(label, counted, worst), ok and counted > 0, why)
	local flying, shown = 0, 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live then
			flying += 1
		end
		if d.Part.CFrame.Position.Y > -4000 then
			shown += 1
		end
	end
	check(label .. ": ...and nothing is left there (no drop flying or showing)", flying == 0 and shown == 0, flying + shown)
end
allOn("flat floor", sprayAt(nil, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Heavy"))
local slope = math.rad(25)
allOn("25 degree slope", sprayAt(function(_x, z)
	return -z * math.tan(slope)
end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher"))
allOn("bumpy ground", sprayAt(function(x, z)
	return 0.35 * math.sin(x * 1.1) * math.cos(z * 0.9)
end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher", 10))
do
	-- a wall right behind the victim: the spray carried back hits it
	-- (the victim's back is right against it: the wall face 1.1 behind the struck front)
	local pts = sprayAt(nil, { { "Wall", V3.new(-6, 0, -1.7), V3.new(6, 10, -1.1) } }, V3.new(0, 3.5, 0), V3.new(0, 0, -1), "Light", 3)
	local function onWall(p)
		return math.abs(p.Z - -1.1) < 0.02 and p.Y > 0.05
	end
	allOn("a wall behind the victim", pts, onWall)
	local inside = false
	for _, p in ipairs(pts) do
		if p.Z < -1.1 - 0.01 and p.Z > -1.7 and p.Y > 0.02 then
			inside = true
		end
	end
	check("...on the wall's face, never inside it", not inside)
end
do
	-- a ceiling low overhead (under a bridge, in a tunnel): an uppercut throws blood up into it
	local pts = sprayAt(nil, { { "Ceiling", V3.new(-6, 5.6, -6), V3.new(6, 7, 6) } }, V3.new(0, 4.6, 0), V3.new(0, 0, -1), "Heavy", 2)
	allOn("a low ceiling", pts, function(p)
		return math.abs(p.Y - 5.6) < 0.02
	end)
end

---------------------------------------------------------------------------
section("3. Never over an edge")
do
	-- a step up right where the drops come down, and a ledge (the ground ends)
	allOn("a step's edge", sprayAt(function(_x, z)
		return if z < -2.5 then 1.2 else 0
	end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher", 12))
	world(nil)
	table.insert(Env.voids, { Center = V3.new(0, 0, -30), Radius = 27.5 })
	markDrops()
	for _ = 1, 12 do
		launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher")
	end
	Env.run(2.6)
	allOn("a ledge's rim", landings())
	local st = Blood.Stats
	check(("...every drop either ended on the ground (%d) or fell away past the rim (%d): none hangs in the air"):format(st.Landed, st.Lost), st.Drops > 0 and st.Landed + st.Lost == st.Drops, st.Drops - st.Landed - st.Lost)
end

---------------------------------------------------------------------------
section("4. Water, glass, decorations, thin walls")
do
	world(nil)
	table.insert(Env.waters, { Center = V3.new(0, 0, 0), Radius = 50 })
	for _ = 1, 6 do
		launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Heavy")
	end
	Env.run(2.6)
	check(("drops into water are swallowed (%d)"):format(Blood.Stats.Water), Blood.Stats.Water > 0)
end
do
	local pts = sprayAt(nil, { { "Glass", V3.new(-6, 0, -1.4), V3.new(6, 10, -1.3), true, { Transparency = 0.9 } }, { "Bush", V3.new(-6, 0, -3.2), V3.new(6, 10, -3.0), false } }, V3.new(0, 3.5, 0), V3.new(0, 0, -1), "Light", 10)
	local onThem = 0
	for _, p in ipairs(pts) do
		if p.Y > 0.05 and ((p.Z <= -1.28 and p.Z >= -1.42) or (p.Z <= -2.98 and p.Z >= -3.22)) then
			onThem += 1
		end
	end
	check("glass and a non-colliding bush don't catch blood: it carries on through them", onThem == 0 and #pts > 0, onThem)
end
do
	world(nil)
	Env.addBox("Thin", V3.new(-10, 0, -3.05), V3.new(10, 20, -3.0), true)
	local through = 0
	math.randomseed(3)
	local function r(a, b)
		return a + math.random() * (b - a)
	end
	for _ = 1, 200 do
		local v = V3.new(r(-4, 4), r(-2, 8), -r(30, 70))
		local d = flyDrop(V3.new(r(-2, 2), 3, 0), v, 1 / 20)
		if d.Pos.Z < -3.06 then
			through += 1
		end
	end
	check("200 fast drops (30-70 studs/s) at a 0.05-stud wall at 20 fps: none tunnels through", through == 0, through)
end

---------------------------------------------------------------------------
section("5. The spray leaves the body outward, carried with the blow")
do
	-- a victim standing at the origin facing +Z (the attacker at +Z hits toward -Z)
	local vic = Client.new("Model")
	local root = Client.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = vic
	for _, tierName in ipairs({ "Light", "Hook", "Heavy", "Finisher", "Body" }) do
		local tier = B.Tiers[tierName]
		local worstOut, worstAlong = math.huge, math.huge
		for trial = 1, 60 do
			local yaw = trial * 0.37
			local rootPos = V3.new(0, 3, 0)
			root.CFrame = CF.new(rootPos) * CF.Angles(0, yaw, 0)
			-- the blow lands on the front of the head, the chest or the shins, from the attacker's side
			local drive = (root.CFrame.LookVector * -1)
			local heights = { 1.5, 0.6, -2.3 }
			local h = heights[(trial % 3) + 1]
			local center = if h > 1.05 then rootPos + V3.new(0, 1.5, 0) else V3.new(rootPos.X, rootPos.Y + h, rootPos.Z)
			local pos = center - drive * 0.55
			local normal, head = Blood.Wound(pos, drive, tier, vic, if trial % 2 == 0 then 1 else -1)
			for _ = 1, 30 do
				local rel = Blood.Crown(normal, tier) -- relative to the struck part's motion
				worstOut = math.min(worstOut, rel.Unit:Dot(normal))
				worstAlong = math.min(worstAlong, (head + rel):Dot(drive) + 1e-6)
			end
		end
		check(("%s: every drop leaves the wound outward relative to the struck part (min cos %.3f >= cos %d deg > 0)"):format(tierName, worstOut, tier.Crown[2]), worstOut >= math.cos(math.rad(tier.Crown[2])) - 1e-4 and worstOut > 0)
		-- and the hit's burst (the place's effects) is aimed out of the wound, never into the body
		local worstAim = math.huge
		for trial = 1, 24 do
			root.CFrame = CF.new(V3.new(0, 3, 0)) * CF.Angles(0, trial * 0.53, 0)
			local drive = root.CFrame.LookVector * -1
			local h = ({ 1.5, 0.6, -2.3 })[(trial % 3) + 1]
			local center = if h > 1.05 then V3.new(0, 4.5, 0) else V3.new(0, 3 + h, 0)
			local pos = center - drive * 0.55
			local normal = Blood.Wound(pos, drive, tier, vic, 1)
			table.clear(Client.emits)
			Blood.Spray(pos, drive, tierName, vic, if trial % 2 == 0 then 1 else -1)
			Env.step(1 / 60)
			for _, e in ipairs(Client.emits) do
				worstAim = math.min(worstAim, e.CFrame.UpVector:Dot(normal))
			end
		end
		check(("%s: the hit's blood burst is aimed out of the wound (min cos %.3f > 0)"):format(tierName, worstAim), worstAim > 0 and worstAim < math.huge)
	end
	-- the drive: the mean spray follows the head (a straight carries it along the blow, an uppercut
	-- lifts it, a hook throws it to the side the head went)
	root.CFrame = CF.new(V3.new(0, 3, 0))
	local drive = V3.new(0, 0, -1)
	local _, headL = Blood.Wound(V3.new(0, 4.5, 0.55), drive, B.Tiers.Light, vic, 1)
	local _, headU = Blood.Wound(V3.new(0, 4.5, 0.55), drive, B.Tiers.Heavy, vic, 1)
	local _, headH = Blood.Wound(V3.new(0, 4.5, 0.55), drive, B.Tiers.Hook, vic, 1)
	check("a straight carries the blood along the blow", headL:Dot(drive) > 5)
	check("an uppercut throws it up", headU.Y > 10)
	check("a hook throws it to the side the head went (the victim's right)", headH:Dot(root.CFrame.RightVector) > 6)
end

---------------------------------------------------------------------------
section("6. The particle bursts never reach a surface")
local function particleWorst(e, maxT)
	-- the emitter's own motion (Roblox: Drag halves the speed every 1/Drag s; acceleration added)
	-- Roblox turns each particle up to SpreadAngle.X about one axis and up to .Y about the other, at
	-- once: every combination on a 7 x 7 grid, the four corners (the widest paths) included
	local cf = e.CFrame
	local up = cf.UpVector
	local rx, rz = cf.RightVector, cf.LookVector
	local worstFloor, worstWall = math.huge, math.huge
	for i = 0, 48 do
		local ax = math.rad(e.Spread.X) * ((i % 7) / 3 - 1)
		local az = math.rad(e.Spread.Y) * ((i // 7) / 3 - 1)
		local d = CF.fromAxisAngle(rz, az) * (CF.fromAxisAngle(rx, ax) * up)
		local p, v = cf.Position, d * e.Speed.Max
		local t = 0
		while t < e.Lifetime.Max - 1e-9 do
			local h = math.min(1 / 240, e.Lifetime.Max - t) -- (never past the particle's own death)
			v = v * (0.5 ^ (h * e.Drag)) + e.Accel * h
			p += v * h
			t += h
			local ground = Env.heightAt(p.X, p.Z)
			worstFloor = math.min(worstFloor, p.Y - ground)
			for _, b in ipairs(Env.boxes) do
				if p.X > b.Min.X and p.X < b.Max.X and p.Y > b.Min.Y and p.Y < b.Max.Y and p.Z > b.Min.Z and p.Z < b.Max.Z then
					worstWall = -1
				end
			end
		end
	end
	return worstFloor, worstWall
end
for _, case in ipairs({
	{ "a sweep at shin height", V3.new(0, 0.55, 0), nil, "Finisher" },
	{ "a straight to the head", V3.new(0, 4.6, 0), nil, "Light" },
	{ "a hook against a wall", V3.new(0, 3.6, 0), { "Wall", V3.new(-5, 0, -1.6), V3.new(5, 9, -1.0) }, "Hook" },
	{ "an uppercut under a low ceiling", V3.new(0, 4.6, 0), { "Ceiling", V3.new(-5, 6.2, -5), V3.new(5, 7, 5) }, "Heavy" },
	{ "a blow on a steep slope", V3.new(0, 3.5, 0), nil, "Body", function(_x, z)
		return -z * math.tan(math.rad(30))
	end },
}) do
	world(case[5])
	if case[3] then
		Env.addBox(case[3][1], case[3][2], case[3][3], true)
	end
	table.clear(Client.emits)
	Blood.Spray(case[2], V3.new(0, 0, -1), case[4], nil, 1)
	Env.step(1 / 60) -- (the effects fire on the next resume)
	local ok, why = #Client.emits > 0, "no burst"
	for _, e in ipairs(Client.emits) do
		local fl, wl = particleWorst(e)
		if fl < 0 then
			ok, why = false, ("%s went %.2f under the floor"):format(e.Emitter.Name, -fl)
		elseif wl < 0 then
			ok, why = false, e.Emitter.Name .. " entered the wall"
		end
	end
	check(case[1] .. ": every particle of the place's blood effects fades before any surface", ok, why)
end

do
	-- a cramped room: close walls both sides and behind, a low ceiling, hits of every tier from every
	-- angle at every height - not one particle may reach a surface
	math.randomseed((tonumber(process.env.SEED or "") or 7) * 7919 + 13)
	world(nil)
	Env.addBox("WallL", V3.new(-2.6, 0, -10), V3.new(-2.2, 9, 10), true)
	Env.addBox("WallR", V3.new(2.2, 0, -10), V3.new(2.6, 9, 10), true)
	Env.addBox("Back", V3.new(-3, 0, -2.4), V3.new(3, 9, -2.0), true)
	Env.addBox("Ceiling", V3.new(-3, 6.0, -10), V3.new(3, 6.6, 10), true)
	local tiers = { "Light", "Hook", "Heavy", "Finisher", "Body" }
	local bad, worstWhy, particles = 0, nil, 0
	for i = 1, 60 do
		local pos = V3.new(math.random() * 3 - 1.5, 0.4 + math.random() * 4.8, math.random() * 3 - 1.2)
		local yaw = math.random() * math.pi * 2
		local drive = V3.new(math.cos(yaw), 0, math.sin(yaw))
		table.clear(Client.emits)
		Blood.Spray(pos, drive, tiers[(i % #tiers) + 1], nil, if i % 2 == 0 then 1 else -1)
		Env.step(1 / 60)
		for _, e in ipairs(Client.emits) do
			particles += e.Count
			local fl, wl = particleWorst(e)
			if fl < 0 or wl < 0 then
				bad += 1
				worstWhy = ("%s (%s) at %s"):format(e.Emitter.Name, tiers[(i % #tiers) + 1], tostring(pos))
			end
		end
	end
	check(("a cramped room, 60 hits of every tier (%d particles): none reaches a floor, wall or ceiling"):format(particles), bad == 0, worstWhy)
end

---------------------------------------------------------------------------
section("7. The drop pool")
do
	world(nil)
	for _ = 1, 40 do
		launchDrops(V3.new(math.random() * 20 - 10, 4.6, math.random() * 20 - 10), V3.new(0, 0, -1), "Finisher")
		Env.run(0.05)
	end
	Env.run(2.5)
	local parts = #Client.instances("Part")
	check(("...and the drop pool never grew past its size (%d drops)"):format(#Blood.Drops), #Blood.Drops <= 72)
	for _ = 1, 20 do
		launchDrops(V3.new(0, 4.6, 0), V3.new(0, 0, -1), "Finisher")
		Env.run(0.05)
	end
	Env.run(2.5)
	check("...more sprays reuse the pool (no new parts)", #Client.instances("Part") == parts, #Client.instances("Part") - parts)
	local flying = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live then
			flying += 1
		end
	end
	check("no droplet is left flying", flying == 0, flying)
end

---------------------------------------------------------------------------
section("8. A hit bursts the place's own effects, nothing is left behind")
do
	local fs = require("@lune/fs")
	for _, file in ipairs({ "CombatBlood", "CombatGore" }) do
		local src = fs.readFile("src/ReplicatedStorage__Combat__" .. file .. ".lua")
		check(file .. " makes no particle emitter of its own", not string.find(src, 'Instance.new("ParticleEmitter")', 1, true))
		check(file .. " has no splatter / pool code (no decal, no stain)", not string.find(src, 'Instance.new("Decal")', 1, true) and not string.find(src, "Splat", 1, true) and not string.find(src, "Stains", 1, true))
	end
	local known = {}
	for name, list in pairs(TEMPLATES) do
		for _, t in ipairs(list) do
			known[name .. "/" .. t.Name] = t.Texture
		end
	end
	world(nil)
	Env.addBox("Wall", V3.new(-6, 0, -2.2), V3.new(6, 9, -1.8), true)
	local drops0 = Blood.Stats.Drops
	table.clear(Client.emits)
	local tiers = { "Light", "Hook", "Heavy", "Finisher", "Body" }
	for i = 1, 40 do
		Blood.Spray(V3.new(math.random() * 6 - 3, 0.6 + math.random() * 4, 0), V3.new(0, 0, -1), tiers[(i % #tiers) + 1], nil, if i % 2 == 0 then 1 else -1)
		Env.run(0.05)
	end
	local foreign, total = 0, 0
	for _, e in ipairs(Client.emits) do
		total += e.Count
		if known[tostring(e.Effect) .. "/" .. e.Emitter.Name] ~= e.Emitter.Texture then
			foreign += 1
		end
	end
	check(("40 hits: %d particles, every one from the place's Blood / BloodHeavy effects"):format(total), total > 0 and foreign == 0, foreign)
	check("a hit's spray throws no droplet parts", Blood.Stats.Drops == drops0, Blood.Stats.Drops - drops0)
	local heavy, light = false, false
	for _, e in ipairs(Client.emits) do
		heavy = heavy or e.Effect == "BloodHeavy"
		light = light or e.Effect == "Blood"
	end
	check("light blows burst Blood, heavy ones BloodHeavy", heavy and light)
	Env.run(3)
	local left = 0
	for _, a in ipairs(Client.instances("Attachment")) do
		if a.Parent == Env.workspace.Terrain and (a.Name == "Blood" or a.Name == "BloodHeavy") then
			left += 1
		end
	end
	check("every burst is cleaned up once its particles are gone", left == 0, left)
	local stray = 0
	for _, part in ipairs(Client.instances("Part")) do
		if part.Name ~= "BloodDrop" and part.Parent and part.Parent.Name == "CombatBlood" then
			stray += 1
		end
	end
	check("nothing but pooled droplets is ever made (no splatter part)", stray == 0, stray)
	-- the gore's droplets: they land and are simply gone
	local landed0 = Blood.Stats.Landed
	launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher")
	launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Heavy")
	Env.run(2.6)
	local flying = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live or d.Part.CFrame.Position.Y > -4000 then
			flying += 1
		end
	end
	check(("droplets land (%d) and are gone: none left in the world"):format(Blood.Stats.Landed - landed0), Blood.Stats.Landed > landed0 and flying == 0, flying)
	check("the module has no pool / stain API left", Blood.Pool == nil and Blood.Splats == nil and Blood.LaySplat == nil and Blood.SoundHook == nil)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("blood test failed")
end
