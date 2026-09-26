--!nocheck
--[[
	The blood, run headless against the simulated world (sim/env + sim/client): the REAL CombatBlood
	module, frame by frame. What it proves:
	  1  the flight is exact: the closed-form integration matches a fine RK4 solution of
	     dv/dt = -k v + g, composes exactly, and lands a drop on the same spot at any frame rate
	  2  every drop that meets something leaves a splatter ON it: floor, 25 deg slope, bumps, a wall,
	     a ceiling - flat on the surface (its plane within a hair of it, facing out of it, corners
	     all on the surface: never floating over a dip, never cut into a bump)
	  3  never over an edge: drops landing at a step's edge or a ledge's rim never leave a splatter
	     hanging in the air
	  4  water swallows drops; glass, triggers and non-colliding decorations don't stop them; a thin
	     wall is never tunnelled through, even by fast drops at 20 fps
	  5  the spray leaves the body OUTWARD from the wound at every tier and every angle (relative to
	     the struck part's own motion), carried the way the blow drove it
	  6  the particle bursts can never reach the floor or a wall before they have faded, sprayed at
	     shin height, next to a wall, up against a ceiling
	  7  a grazing drop smears along its travel, a falling one lands round; fast drops throw
	     satellites; splatters dry darker, fade, return to the pool; the cap holds; nothing leaks

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

local function liveSplats()
	local out = {}
	for _, s in ipairs(Blood.Splats) do
		if s.Busy then
			table.insert(out, s)
		end
	end
	return out
end

-- fly one drop to the end with a given frame time (the module's own flight: substeps + rays)
local function flyDrop(pos, vel, dt)
	local d = { Pos = pos, Vel = vel, Size = 0.12, Age = 0, Live = true, Satellite = true, Part = Client.new("Part") }
	local t = 0
	while d.Live and t < 3 do
		Blood.Fly(d, dt)
		t += dt
	end
	return d
end

-- the decal (the splat part's top face, 0.025 above its centre) against the surface under it,
-- independently re-cast on a fine grid: it must be ABOVE the surface everywhere (never buried in a
-- bump) and never float more than `tol` over it (never hanging over a dip or an edge)
local function splatFits(s, tol)
	local p = s.Part
	local cf = p.CFrame
	local n = cf.UpVector
	local size = p.Size
	local worst = 0
	for i = 0, 6 do
		for j = 0, 6 do
			local spot = cf * V3.new(size.X * (i / 6 - 0.5), size.Y / 2, size.Z * (j / 6 - 0.5))
			local hit = Env.workspace:Raycast(spot + n * 0.5, -n * 1.0, nil)
			if not hit then
				return false, "no surface under the decal"
			end
			local gap = (spot - hit.Position):Dot(n)
			worst = math.max(worst, gap)
			if gap < 0.001 then
				return false, ("buried %.3f under the surface"):format(-gap)
			end
			if gap > tol then
				return false, ("floating %.3f over the surface"):format(gap)
			end
		end
	end
	return true, worst
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
-- a wound in a splash crown, carried with the struck part - with Config.Blood.Stains on, so the
-- splatter subsystem is tested too (sections 2-7). The default (Stains off) is section 8
B.Stains = true
local function launchDrops(pos, drive, tierName, victim)
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local normal, head = Blood.Wound(pos, drive, tier, victim, 1)
	for _ = 1, 8 do
		Blood.Launch(pos + normal * 0.05, head + Blood.Crown(normal, tier), 0.09 + math.random() * 0.08)
	end
end

---------------------------------------------------------------------------
section("2. Every splatter lies flat ON the surface it hit")
local function sprayAt(groundAt, boxes, pos, drive, tier, n)
	world(groundAt)
	for _, b in ipairs(boxes or {}) do
		Env.addBox(b[1], b[2], b[3], b[4] ~= false, b[5])
	end
	for _ = 1, n or 6 do
		launchDrops(pos, drive, tier)
	end
	Env.run(2.6)
	return liveSplats()
end
local function allFit(label, splats, wantNormal)
	local ok, worst, why = true, 0, nil
	for _, s in ipairs(splats) do
		local fit, w = splatFits(s, 0.1)
		if not fit then
			ok, why = false, w
			break
		end
		worst = math.max(worst, w)
		if wantNormal and s.Part.CFrame.UpVector:Dot(wantNormal) < 0.995 then
			ok, why = false, "facing the wrong way"
			break
		end
	end
	check(("%s: %d splatters, every one lying on the surface (highest float %.3f studs)"):format(label, #splats, worst), ok and #splats > 0, why)
end
allFit("flat floor", sprayAt(nil, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Heavy"), V3.new(0, 1, 0))
local slope = math.rad(25)
allFit("25 degree slope", sprayAt(function(_x, z)
	return -z * math.tan(slope)
end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher"), V3.new(0, math.cos(slope), math.sin(slope)))
allFit("bumpy ground", sprayAt(function(x, z)
	return 0.35 * math.sin(x * 1.1) * math.cos(z * 0.9)
end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher", 10))
do
	-- a wall right behind the victim: the spray carried back hits it
	-- (the victim's back is right against it: the wall face 1.1 behind the struck front)
	local splats = sprayAt(nil, { { "Wall", V3.new(-6, 0, -1.7), V3.new(6, 10, -1.1) } }, V3.new(0, 3.5, 0), V3.new(0, 0, -1), "Light", 3)
	local onWall = {}
	for _, s in ipairs(splats) do
		if s.Part.CFrame.UpVector:Dot(V3.new(0, 0, 1)) > 0.99 then
			table.insert(onWall, s)
		end
	end
	allFit("a wall behind the victim", onWall, V3.new(0, 0, 1))
	local inside = false
	for _, s in ipairs(onWall) do
		if s.Part.Position.Z < -1.1 + 0.005 then
			inside = true
		end
	end
	check("...on the wall's face, never inside it", #onWall > 0 and not inside)
end
do
	-- a ceiling low overhead (under a bridge, in a tunnel): an uppercut throws blood up into it
	local splats = sprayAt(nil, { { "Ceiling", V3.new(-6, 5.6, -6), V3.new(6, 7, 6) } }, V3.new(0, 4.6, 0), V3.new(0, 0, -1), "Heavy", 2)
	local up = {}
	for _, s in ipairs(splats) do
		if s.Part.CFrame.UpVector.Y < -0.99 then
			table.insert(up, s)
		end
	end
	allFit("a low ceiling", up, V3.new(0, -1, 0))
end

---------------------------------------------------------------------------
section("3. Never over an edge")
do
	-- a step up right where the drops come down, and a ledge (the ground ends)
	local splats = sprayAt(function(_x, z)
		return if z < -2.5 then 1.2 else 0
	end, nil, V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher", 12)
	allFit("a step's edge", splats)
	world(nil)
	table.insert(Env.voids, { Center = V3.new(0, 0, -30), Radius = 27.5 })
	for _ = 1, 12 do
		launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher")
	end
	Env.run(2.6)
	allFit("a ledge's rim", liveSplats())
	check("...and drops that fell off the ledge simply fall away (no splatter in mid-air)", Blood.Stats.Lost >= 0)
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
	check(("drops into water leave nothing (%d swallowed)"):format(Blood.Stats.Water), #liveSplats() == 0 and Blood.Stats.Water > 0)
end
do
	local splats = sprayAt(nil, { { "Glass", V3.new(-6, 0, -1.4), V3.new(6, 10, -1.3), true, { Transparency = 0.9 } }, { "Bush", V3.new(-6, 0, -3.2), V3.new(6, 10, -3.0), false } }, V3.new(0, 3.5, 0), V3.new(0, 0, -1), "Light", 10)
	local onThem = 0
	for _, s in ipairs(splats) do
		if math.abs(s.Part.CFrame.UpVector.Z) > 0.9 then
			onThem += 1
		end
	end
	check("glass and a non-colliding bush don't catch blood: it carries on through them", onThem == 0 and #splats > 0, onThem)
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
section("7. Shapes, satellites, drying, the pool, the cap")
do
	-- the stain's shape against bloodstain analysis: length / width = 1 / sin(impact angle), the
	-- impact angle worked out here from the analytic flight
	local function impactRatio(x0, v0)
		local lo, hi = 0, 3
		for _ = 1, 60 do
			local mid = (lo + hi) / 2
			if Blood.Advance(x0, v0, mid).Y > 0 then
				lo = mid
			else
				hi = mid
			end
		end
		local _, v = Blood.Advance(x0, v0, lo)
		return 1 / math.abs(v.Unit.Y)
	end
	for _, case in ipairs({ { "grazing", V3.new(0, 0.6, 0), V3.new(0, -3, -22) }, { "angled", V3.new(0, 2, 0), V3.new(0, 2, -9) }, { "falling straight down", V3.new(0, 5, 0), V3.new(0, -2, 0) } }) do
		world(nil)
		local d = flyDrop(case[2], case[3], 1 / 60)
		Env.run(0.4)
		local s = liveSplats()[1]
		local ratio = if s then s.Part.Size.Z / s.Part.Size.X else 0
		local want = math.clamp(impactRatio(case[2], case[3]), 1, 3.5)
		local aligned = s and (want < 1.25 or math.abs(s.Part.CFrame.LookVector.Z) > 0.99)
		check(("a %s drop: stain x%.2f long, bloodstain analysis says x%.2f"):format(case[1], ratio, want), d.Live == false and math.abs(ratio - want) / want < 0.02 and aligned, ratio)
	end
end
do
	world(nil)
	for _ = 1, 4 do
		launchDrops(V3.new(0, 4.6, 0), V3.new(0, 0, -1), "Finisher")
	end
	Env.run(2.5)
	check(("fast drops throw satellites (%d)"):format(Blood.Stats.Satellites), Blood.Stats.Satellites > 0)
	local splats = liveSplats()
	Env.run(B.Splat.Hold - 2.4)
	local dried = 0
	for _, s in ipairs(splats) do
		local c = s.Decal.Color3
		if math.abs(c.R - B.Dry.R) < 0.02 then
			dried += 1
		end
	end
	check(("splatters dry darker over their hold (%d of %d)"):format(dried, #splats), dried >= #splats * 0.9)
	Env.run(B.Splat.Fade + 0.4)
	local parked, busy = 0, 0
	for _, s in ipairs(Blood.Splats) do
		if s.Part.CFrame.Position.Y < -4000 then
			parked += 1
		end
		if s.Busy then
			busy += 1
		end
	end
	check(("after hold + fade every splatter is back in the pool (%d parked, %d busy)"):format(parked, busy), busy == 0 and parked == #Blood.Splats)
	local flying = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live then
			flying += 1
		end
	end
	check("no droplet is left flying", flying == 0)
end
do
	world(nil)
	for _ = 1, 40 do
		launchDrops(V3.new(math.random() * 20 - 10, 4.6, math.random() * 20 - 10), V3.new(0, 0, -1), "Finisher")
		Env.run(0.05)
	end
	Env.run(2.5)
	check(("40 heavy sprays: splatters never exceed the cap (%d pooled, cap %d)"):format(#Blood.Splats, B.Splat.Cap), #Blood.Splats <= B.Splat.Cap and #liveSplats() <= B.Splat.Cap)
	local parts = #Client.instances("Part")
	check(("...and the drop pool never grew past its size (%d drops)"):format(#Blood.Drops), #Blood.Drops <= 72)
	for _ = 1, 20 do
		launchDrops(V3.new(0, 4.6, 0), V3.new(0, 0, -1), "Finisher")
		Env.run(0.05)
	end
	Env.run(2.5)
	check("...more sprays reuse the pools (no new parts)", #Client.instances("Part") == parts, #Client.instances("Part") - parts)
end

---------------------------------------------------------------------------
section("8. The default: a hit bursts the place's own effects, nothing is left behind")
B.Stains = false
do
	local fs = require("@lune/fs")
	for _, file in ipairs({ "CombatBlood", "CombatGore" }) do
		local src = fs.readFile("src/ReplicatedStorage__Combat__" .. file .. ".lua")
		check(file .. " makes no particle emitter of its own", not string.find(src, 'Instance.new("ParticleEmitter")', 1, true))
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
	check("nothing is left on the floor or the wall (no splatter)", #liveSplats() == 0)
	-- the gore's droplets: they land and are simply gone
	local landed0, splats0 = Blood.Stats.Landed, Blood.Stats.Splats
	launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Finisher")
	launchDrops(V3.new(0, 4, 0), V3.new(0, 0, -1), "Heavy")
	Env.run(2.6)
	local flying = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live or d.Part.CFrame.Position.Y > -4000 then
			flying += 1
		end
	end
	check(("droplets land (%d) and are gone: no splatter, none left in the world"):format(Blood.Stats.Landed - landed0), Blood.Stats.Landed > landed0 and Blood.Stats.Splats == splats0 and flying == 0 and #liveSplats() == 0, flying)
	local body = Client.new("Model")
	local torso = Client.new("Part")
	torso.Name = "Torso"
	torso.CFrame = CF.new(0, 1, 0)
	torso.Parent = body
	Blood.Pool(body)
	Env.run(2)
	check("a knocked-out body leaves no pool", #liveSplats() == 0)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("blood test failed")
end
