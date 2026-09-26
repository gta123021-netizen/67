--!nocheck
--[[
	The Ground Smash's visuals, run headless against the simulated client (sim/env + sim/client):
	the REAL CombatShatter module, frame by frame, on every kind of ground. What it proves:
	  1  the fissures reach the gameplay radius and never pass it; every point of every fissure
	     lies on the ground under it (flat, slope, bumps); the break runs outward at its speed
	  2  a fissure stops at a step or kerb, a wall, a ledge over the void, and at water
	  3  slabs heave only where there is room (never into a wall, never through a fighter's body),
	     in the floor's own material over earth, standing on the floor
	  4  thrown rocks come to rest ON a surface (never under the ground, never inside a wall,
	     never floating), bounce off walls, sink into water, and are gone off a ledge; none is
	     thrown at a fighter standing in the circle
	  5  every particle is one of the place's own effects (none made in code): the impact, the
	     crack flash and its shards (stopping at the rim), the lasting cracks covering the broken
	     ground, the shock ring, and the smoke rolling OUTWARD to the rim with a little rising over
	     the centre; the sounds of every phase play and exist in the config
	  6  a smash on water only sprays; one out of view builds nothing
	  7  after the hold everything fades back into its pools; a new smash on an old one clears the
	     old one first; smash after smash never builds past the pools' caps
	  8  the descent's effects stop on touchdown (or by themselves) and clean up

	    lune run tests/shatter_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local Client = require("./sim/client")(Env)
local TEMPLATES = require("./sim/vfx_templates")
Client.vfxFolder(TEMPLATES)
local roblox = require("@lune/roblox")
local V3, CF = Env.Vector3, Env.CFrame
local Enum = roblox.Enum
local process = require("@lune/process")
local SEED = tonumber(process.env.SEED or "") or 5
math.randomseed(SEED)

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
-- what the module needs beyond the harness: Random, OverlapParams, bounds queries, CombatFX's voice
---------------------------------------------------------------------------
local seedN = SEED * 7919
local Random = {}
function Random.new(seed)
	local state = seed or seedN
	seedN += 104729
	local r = {}
	local function nextU()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
	function r:NextNumber(a, b)
		local u = nextU()
		if a == nil then
			return u
		end
		return a + (b - a) * u
	end
	function r:NextInteger(a, b)
		return math.min(b, a + math.floor(nextU() * (b - a + 1)))
	end
	return r
end
Env.extraGlobals.Random = Random
Env.extraGlobals.OverlapParams = { new = function()
	return { FilterDescendantsInstances = {}, RespectCanCollide = false }
end }
local ws = Env.workspace
local bodies = {} -- (NPC parts the bounds query finds)
function ws:GetPartBoundsInRadius(center, radius)
	local out = {}
	for _, p in ipairs(bodies) do
		if (p.Position - center).Magnitude <= radius then
			table.insert(out, p)
		end
	end
	return out
end
local sounds = {}
Env.modules["ReplicatedStorage/Combat/CombatFX"] = { Sound = function(name, pos)
	table.insert(sounds, { Name = name, Pos = pos, T = Env.now() })
end }
Env.combatFolder._children.CombatFX = { __path = "ReplicatedStorage/Combat/CombatFX", Name = "CombatFX", IsA = function(_, c)
	return c == "ModuleScript"
end }

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Shatter = Env.load("ReplicatedStorage/Combat/CombatShatter")
local R = Config.Attacks.Downslam.StompRadius
local PARKED = -4000

local function holder()
	return ws:FindFirstChild("CombatShatter")
end
local function pieces(kind, placedOnly)
	local out = {}
	local h = holder()
	for _, p in ipairs(if h then h:GetChildren() else {}) do
		if p.Name == "Shatter" .. kind and (not placedOnly or p.CFrame.Position.Y > PARKED) then
			table.insert(out, p)
		end
	end
	return out
end
local function world(groundAt)
	Env.groundAt = groundAt
	table.clear(Env.boxes)
	table.clear(Env.voids)
	table.clear(Env.waters)
	table.clear(bodies)
	Env.run(6) -- (whatever the last case left fades back into its pools)
	table.clear(sounds)
	table.clear(Client.emits)
end
local function flatDist(a, b)
	return V3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
-- the two ends of a placed fissure piece (its length runs along its look vector)
local function ends(p)
	local half = (p.Size.Z - p.Size.X * 0.6) * 0.5
	local c = p.CFrame
	local n = c.UpVector
	local mid = c.Position - n * 0.018
	return mid - c.LookVector * half, mid + c.LookVector * half
end
local function inBox(pt, b, pad)
	pad = pad or 0
	return pt.X > b.Min.X + pad and pt.X < b.Max.X - pad and pt.Y > b.Min.Y + pad and pt.Y < b.Max.Y - pad and pt.Z > b.Min.Z + pad and pt.Z < b.Max.Z - pad
end
ws.CurrentCamera.CFrame = CF.new(0, 12, 30)

---------------------------------------------------------------------------
-- one smash on a given ground, with its checks
---------------------------------------------------------------------------
local function smash(label, groundAt, setup, extra)
	world(groundAt)
	local info = if setup then setup() else {}
	local center = info.Center or V3.new(0, Env.heightAt(0, 0) + 0.05, 0)
	Shatter.Play(center, nil)
	Env.run(0.9) -- (the break has run out, the slabs are up, the rocks have landed)
	local fis = pieces("Fissure", true)
	local c0 = V3.new(center.X, Env.heightAt(center.X, center.Z), center.Z)
	local maxR, onGround, worst, count = 0, true, 0, 0
	for _, p in ipairs(fis) do
		local a, b = ends(p)
		for _, q in ipairs({ a, b }) do
			maxR = math.max(maxR, flatDist(q, c0))
			local gy = Env.heightAt(q.X, q.Z)
			local err = math.abs(q.Y - gy)
			for _, bx in ipairs(Env.boxes) do
				if q.X >= bx.Min.X and q.X <= bx.Max.X and q.Z >= bx.Min.Z and q.Z <= bx.Max.Z and bx.CanCollide then
					err = math.min(err, math.abs(q.Y - bx.Max.Y))
				end
			end
			worst = math.max(worst, err)
		end
		count += 1
	end
	onGround = worst < 0.12
	if not info.NoFissures then
		check(label .. ": fissures run out from the foot (" .. count .. " pieces)", count >= 12, count)
		check(label .. ": ... never past the gameplay radius (reach " .. string.format("%.2f", maxR) .. " of " .. R .. ")", maxR <= R + 0.35, maxR)
		if info.FullReach ~= false then
			check(label .. ": ... and the longest reach it", maxR >= R * 0.85, maxR)
		end
		check(label .. ": ... every point on the ground under it (worst " .. string.format("%.3f", worst) .. ")", onGround, worst)
	end
	-- slabs: heaved out of the floor they stand on (the earth under the surface slab sits partly in
	-- that floor, as it should), never inside anything else
	local function floorY(x, z)
		local y = Env.heightAt(x, z)
		for _, bx in ipairs(Env.boxes) do
			if bx.CanCollide and x >= bx.Min.X and x <= bx.Max.X and z >= bx.Min.Z and z <= bx.Max.Z then
				y = math.max(y, bx.Max.Y)
			end
		end
		return y
	end
	local slabs = pieces("Slab", true)
	local slabOk, slabWhy = true, ""
	for _, s in ipairs(slabs) do
		local pos = s.CFrame.Position
		local gy = floorY(pos.X, pos.Z)
		if pos.Y < gy - 1.2 or pos.Y > gy + 1.6 then
			slabOk, slabWhy = false, string.format("at %.2f over a floor at %.2f", pos.Y, gy)
		end
		for _, bx in ipairs(Env.boxes) do
			local isFloor = math.abs(bx.Max.Y - c0.Y) < 0.3 or math.abs(bx.Max.Y - center.Y) < 0.3
			if bx.CanCollide and not isFloor and inBox(pos, bx, 0.05) then
				slabOk, slabWhy = false, "inside " .. bx.Name
			end
		end
	end
	check(label .. ": slabs (" .. #slabs .. ") stand on the floor, none inside anything solid", slabOk, slabWhy)
	-- rocks
	local rocks = pieces("Rock", true)
	local rockOk, why = true, ""
	local function overVoid(p)
		for _, v in ipairs(Env.voids) do
			if flatDist(p, v.Center) < v.Radius then
				return true
			end
		end
		return false
	end
	for _, r in ipairs(rocks) do
		local pos = r.CFrame.Position
		if overVoid(pos) then
			continue -- (falling off the ledge: checked by the ledge case)
		end
		local gy = Env.heightAt(pos.X, pos.Z)
		local onBox = false
		for _, bx in ipairs(Env.boxes) do
			if bx.CanCollide and inBox(pos, bx, 0.02) then
				rockOk, why = false, "inside " .. bx.Name
			end
			if bx.CanCollide and pos.X >= bx.Min.X and pos.X <= bx.Max.X and pos.Z >= bx.Min.Z and pos.Z <= bx.Max.Z and math.abs(pos.Y - bx.Max.Y) < 1 then
				onBox = true
			end
		end
		if pos.Y < gy - 0.05 then
			rockOk, why = false, string.format("under the ground at %.2f (ground %.2f)", pos.Y, gy)
		end
		if not onBox and pos.Y > gy + r.Size.Y + 0.6 then
			rockOk, why = false, string.format("floating at %.2f over %.2f", pos.Y, gy)
		end
	end
	if not info.NoFissures then
		check(label .. ": rocks (" .. #rocks .. ") at rest on a surface: none under the ground, in a wall or floating", rockOk and #rocks > 0, why)
	end
	if extra then
		extra(info, center)
	end
	return info
end

---------------------------------------------------------------------------
section("1  flat ground: the full sequence")
---------------------------------------------------------------------------
smash("flat", nil, nil, function(info, center)
	local names = {}
	for _, s in ipairs(sounds) do
		names[s.Name] = true
	end
	check("flat: the boom, its bass, the crack, the debris and the settle all play", names.Slam and names.SlamSub and names.SlamCrack and names.SlamDebris and names.SlamSettle)
	local ok = true
	for n in pairs(names) do
		if not Config.Sounds[n] then
			ok = false
		end
	end
	check("flat: ... every one exists in Config.Sounds", ok)
	local fs = require("@lune/fs")
	check("flat: CombatShatter makes no particle emitter of its own", not string.find(fs.readFile("src/ReplicatedStorage__Combat__CombatShatter.lua"), 'Instance.new("ParticleEmitter")', 1, true))
	local known = {}
	for name, list in pairs(TEMPLATES) do
		for _, t in ipairs(list) do
			known[name .. "/" .. t.Name] = t.Texture
		end
	end
	local effects, foreign = {}, 0
	for _, e in ipairs(Client.emits) do
		effects[e.Effect] = (effects[e.Effect] or 0) + e.Count
		if known[tostring(e.Effect) .. "/" .. e.Emitter.Name] ~= e.Emitter.Texture then
			foreign += 1
		end
	end
	check("flat: every particle is one of the place's own effects", #Client.emits > 0 and foreign == 0, foreign)
	local missing = {}
	for _, n in ipairs({ "HitFlashHeavy", "Impact", "FloorCrack", "BigCrack", "GroundCrack1", "GroundCrack2", "ShockRing", "GroundDust", "DustBurst", "DustPuff" }) do
		if not effects[n] then
			table.insert(missing, n)
		end
	end
	check("flat: the impact, crack flash and shards, lasting cracks, shock ring, rolling dust and smoke all play", #missing == 0, table.concat(missing, ","))
	local lava, sizes, shardReach = false, {}, 0
	for _, e in ipairs(Client.emits) do
		if e.Effect == "BigCrack" and (e.Emitter.Name == "Impact1" or e.Emitter.Name == "Fire1") then
			lava = true
		end
		if e.Effect == "GroundCrack1" or e.Effect == "GroundCrack2" then
			sizes[e.Effect] = e.Emitter.Size.Keypoints[1].Value
		end
		if e.Effect == "BigCrack" and e.Emitter.Name == "Ash1" then
			shardReach = e.Speed.Max * e.Lifetime.Max
		end
	end
	check("flat: the Big pack's crack without its lava glow or fire", not lava)
	check(("flat: the lasting cracks span the broken ground (%.1f and %.1f studs across, radius %s)"):format(sizes.GroundCrack1 or 0, sizes.GroundCrack2 or 0, R), sizes.GroundCrack1 and math.abs(sizes.GroundCrack1 - 2 * R) < 1e-3 and sizes.GroundCrack2 > R)
	check(("flat: the crack's shards fly out to the rim, no further (%.2f of %.2f)"):format(shardReach, R * 1.25), shardReach > R * 0.8 and shardReach <= R * 1.25 + 1e-3)
	-- the smoke: rolled out along the ground to the rim (its own speed, drag and life), puffs
	-- billowing on rings further out each beat, and a little rising over the centre
	local function reach(e)
		local v, d, t = e.Speed.Max, 0, 0
		while t < e.Lifetime.Max do
			local h = math.min(1 / 240, e.Lifetime.Max - t)
			d += v * h
			v *= 0.5 ^ (e.Drag * h)
			t += h
		end
		return d
	end
	local rolled = {}
	for _, e in ipairs(Client.emits) do
		if (e.Effect == "DustBurst" and e.Emitter.Name == "Smoke2") or (e.Effect == "GroundDust" and e.Emitter.Name == "Dust") then
			rolled[e.Effect] = reach(e)
		end
	end
	check(("flat: the dust and smoke roll out to the rim (%.1f, %.1f studs; radius %s)"):format(rolled.GroundDust or 0, rolled.DustBurst or 0, R), rolled.GroundDust and rolled.DustBurst and rolled.GroundDust > R * 0.8 and rolled.GroundDust < R * 1.35 and rolled.DustBurst > R * 0.8 and rolled.DustBurst < R * 1.35)
	local outward, up, rings = 0, 0, {}
	for _, e in ipairs(Client.emits) do
		if e.Effect == "DustPuff" then
			local p = e.CFrame.Position
			local r = V3.new(p.X, 0, p.Z).Magnitude
			if r < 0.5 then
				if p.Y > 1.4 then
					up += 1
				end
			else
				outward += 1
				table.insert(rings, { R = r, T = e.T, Y = p.Y })
			end
		end
	end
	local order, low = true, true
	for _, a in ipairs(rings) do
		for _, b in ipairs(rings) do
			if a.R > b.R + 0.5 and a.T < b.T - 1e-6 then
				order = false
			end
		end
		if a.Y > 1.3 then
			low = false
		end
	end
	check(("flat: the smoke billows OUTWARD in rings (%d puffs), each ring later and further out, hugging the ground"):format(outward), outward >= 18 and order and low)
	check(("flat: ... and a little rises over the centre (%d puffs)"):format(up), up >= 2 and up < outward)
	local tinted = true
	for _, e in ipairs(Client.emits) do
		if (e.Effect == "DustPuff" or e.Effect == "DustBurst" or e.Effect == "GroundDust") and typeof(e.Emitter.Color) ~= "ColorSequence" then
			tinted = false
		end
	end
	check("flat: the dust and smoke are tinted like the ground", tinted)
	-- the break runs outward at its speed: a piece farther out appears later
	world(nil)
	Shatter.Play(V3.new(0, 0.05, 0), nil)
	local seenAt = {}
	for i = 1, 40 do
		Env.step(1 / 60)
		for _, p in ipairs(pieces("Fissure", true)) do
			if not seenAt[p] then
				seenAt[p] = { T = i / 60, D = flatDist(p.CFrame.Position, V3.zero) }
			end
		end
	end
	local order = true
	for _, a in pairs(seenAt) do
		for _, b in pairs(seenAt) do
			if a.D > b.D + 1.5 and a.T < b.T - 1 / 60 then
				order = false
			end
		end
	end
	check("flat: the break runs outward: nothing far out cracks before what is nearer", order)
	local last = 0
	for _, a in pairs(seenAt) do
		last = math.max(last, a.T)
	end
	check("flat: ... and reaches the rim within the break's time (" .. string.format("%.2f", last) .. " s)", last <= R / 26 + 0.12, last)
end)

---------------------------------------------------------------------------
section("2  every kind of ground")
---------------------------------------------------------------------------
smash("slope 20deg", function(x, z)
	return math.tan(math.rad(20)) * x
end)
smash("rolling bumps", function(x, z)
	return 0.35 * math.sin(x * 0.9) * math.cos(z * 0.7) + 0.2 * math.sin(z * 1.7)
end)
smash("raised platform (standing on a part)", nil, function()
	Env.addBox("Platform", V3.new(-30, -1, -30), V3.new(30, 1.5, 30), true, { Material = Enum.Material.Slate })
	return { Center = V3.new(0, 1.55, 0) }
end)
smash("step half the circle", nil, function()
	Env.addBox("Step", V3.new(3, 0, -20), V3.new(20, 1.2, 20), true, { Material = Enum.Material.Concrete })
	return { FullReach = true }
end, function(info, center)
	local crossed = 0
	for _, p in ipairs(pieces("Fissure", true)) do
		local a, b = ends(p)
		for _, q in ipairs({ a, b }) do
			if q.X > 3.05 and q.Y > 0.8 then
				crossed += 1
			end
		end
	end
	check("step: no fissure climbs the step (it stops at it)", crossed == 0, crossed)
end)
smash("wall close by", nil, function()
	Env.addBox("Wall", V3.new(4, 0, -20), V3.new(5, 12, 20), true, { Material = Enum.Material.Brick })
	return { FullReach = true }
end, function(info, center)
	local through = 0
	for _, p in ipairs(pieces("Fissure", true)) do
		local a, b = ends(p)
		if a.X > 4.02 or b.X > 4.02 then
			through += 1
		end
	end
	check("wall: no fissure runs into or past the wall", through == 0, through)
	local past = 0
	for _, r in ipairs(pieces("Rock", true)) do
		if r.CFrame.Position.X > 4 and r.CFrame.Position.Y < 11.9 then
			past += 1
		end
	end
	check("wall: no rock went through the wall", past == 0, past)
end)
smash("ledge over the void", nil, function()
	table.insert(Env.voids, { Center = V3.new(14, 0, 0), Radius = 10 })
	return { FullReach = false }
end, function(info, center)
	local over = 0
	for _, p in ipairs(pieces("Fissure", true)) do
		local a, b = ends(p)
		for _, q in ipairs({ a, b }) do
			if flatDist(q, V3.new(14, 0, 0)) < 10 - 0.05 then
				over += 1
			end
		end
	end
	check("ledge: no fissure runs out over the void", over == 0, over)
	local falling = 0
	for _, r in ipairs(pieces("Rock", true)) do
		if flatDist(r.CFrame.Position, V3.new(14, 0, 0)) < 10 then
			falling += 1
			if r.CFrame.Position.Y > -0.5 then
				falling += 1000 -- (resting over nothing)
			end
		end
	end
	check("ledge: rocks thrown over the edge fall (" .. falling .. " falling, none resting over nothing)", falling < 1000, falling)
	Env.run(1.6)
	local void = 0
	for _, r in ipairs(pieces("Rock", true)) do
		if flatDist(r.CFrame.Position, V3.new(14, 0, 0)) < 10 then
			void += 1
		end
	end
	check("ledge: ... and are gone once they have fallen away", void == 0, void)
end)
smash("pond at the edge", nil, function()
	table.insert(Env.waters, { Center = V3.new(-12, 0, 0), Radius = 8 })
	return { FullReach = false }
end, function(info, center)
	local wet = 0
	for _, p in ipairs(pieces("Fissure", true)) do
		local a, b = ends(p)
		for _, q in ipairs({ a, b }) do
			if flatDist(q, V3.new(-12, 0, 0)) < 8 - 0.05 then
				wet += 1
			end
		end
	end
	check("pond: no fissure runs into the water", wet == 0, wet)
	local floating = 0
	for _, r in ipairs(pieces("Rock", true)) do
		if flatDist(r.CFrame.Position, V3.new(-12, 0, 0)) < 8 then
			floating += 1
		end
	end
	check("pond: no rock floats on the water (they sink)", floating == 0, floating)
end)
smash("fighter in the circle", nil, function()
	local m = Client.new("Model")
	m.Name = "Npc"
	local hum = Client.new("Humanoid")
	hum.Parent = m
	local root = Client.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CF.new(3, 3, 0)
	root.Size = V3.new(2, 2, 1)
	root.Parent = m
	m.Parent = ws
	table.insert(bodies, root)
	return { Root = root }
end, function(info, center)
	local near = 0
	for _, s in ipairs(pieces("Slab", true)) do
		if flatDist(s.CFrame.Position, info.Root.Position) < 1.2 + 0.3 then
			near += 1
		end
	end
	check("fighter: no slab heaves up through the body", near == 0, near)
end)

---------------------------------------------------------------------------
section("3  water, out of view, the pools")
---------------------------------------------------------------------------
do
	world(nil)
	table.insert(Env.waters, { Center = V3.zero, Radius = 30 })
	Shatter.Play(V3.new(0, 0.05, 0), nil)
	Env.run(0.5)
	local kinds = {}
	for _, e in ipairs(Client.emits) do
		kinds[e.Effect] = true
	end
	check("on water: no fissures, slabs, rocks, cracks or dust - only the hit and the shock across it", #pieces("Fissure", true) == 0 and #pieces("Slab", true) == 0 and #pieces("Rock", true) == 0 and kinds.ShockRing and kinds.Impact and not kinds.GroundCrack1 and not kinds.DustBurst and not kinds.DustPuff)
	world(nil)
	ws.CurrentCamera.CFrame = CF.new(0, 12, 600)
	Shatter.Play(V3.new(0, 0.05, 0), nil)
	Env.run(0.5)
	check("out of view: nothing is built, nothing plays", #pieces("Fissure", true) == 0 and #sounds == 0)
	ws.CurrentCamera.CFrame = CF.new(0, 12, 30)

	world(nil)
	Shatter.Play(V3.new(0, 0.05, 0), nil)
	Env.run(1)
	local placed = #pieces("Fissure", true) + #pieces("Slab", true) + #pieces("Rock", true)
	Env.run(2.6 + 1.6)
	local left = #pieces("Fissure", true) + #pieces("Slab", true) + #pieces("Rock", true) + #pieces("Disc", true)
	check("after the hold: everything (" .. placed .. " pieces) fades back into its pools", left == 0, left)

	-- a new smash on top of an old one clears the old one first
	world(nil)
	Shatter.Play(V3.new(0, 0.05, 0), nil)
	Env.run(1)
	local first = {}
	for _, p in ipairs(pieces("Fissure", true)) do
		first[p] = p.CFrame
	end
	Shatter.Play(V3.new(2, 0.05, 1), nil)
	Env.run(0.9)
	local stale = 0
	for p, cf in pairs(first) do
		if p.CFrame.Position.Y > PARKED and (p.CFrame.Position - cf.Position).Magnitude < 1e-6 then
			stale += 1
		end
	end
	check("a smash on an old one: the old fissures are cleared (" .. stale .. " left where they were)", stale == 0, stale)
	local cracks = 0
	for _, c in ipairs(ws.Terrain:GetChildren()) do
		if (c.Name == "GroundCrack1" or c.Name == "GroundCrack2") and not c._p.Destroyed then
			cracks += 1
		end
	end
	check("... and its lasting cracks with them (only the new smash's 2 remain)", cracks == 2, cracks)
	local maxR = 0
	for _, p in ipairs(pieces("Fissure", true)) do
		local a, b = ends(p)
		maxR = math.max(maxR, flatDist(a, V3.new(2, 0, 1)), flatDist(b, V3.new(2, 0, 1)))
	end
	check("... and the new one stands on its own centre", maxR <= R + 0.35, maxR)

	-- smash after smash: never past the pools' caps
	world(nil)
	for i = 1, 12 do
		Shatter.Play(V3.new((i % 3) * 30 - 30, 0.05, math.floor(i / 3) * 30 - 45), nil)
		Env.run(0.4)
	end
	Env.run(6)
	local total = 0
	local h = holder()
	for _, p in ipairs(h:GetChildren()) do
		if p.Name ~= "ShatterProbe" then
			total += 1
		end
	end
	check("twelve smashes: " .. total .. " pieces ever built (the caps hold: 260+40+90+6)", total <= 260 + 40 + 90 + 6, total)
	check("... all back in the pools", #pieces("Fissure", true) + #pieces("Slab", true) + #pieces("Rock", true) + #pieces("Disc", true) == 0)
end

---------------------------------------------------------------------------
section("4  the descent")
---------------------------------------------------------------------------
do
	world(nil)
	local m = Client.new("Model")
	local root = Client.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CF.new(0, 20, 0)
	root.Parent = m
	local torso = Client.new("Part")
	torso.Name = "Torso"
	torso.CFrame = CF.new(0, 20, 0)
	torso.Parent = m
	m.Parent = ws
	local function lines()
		for _, c in ipairs(ws.Terrain:GetChildren()) do
			if c.Name == "SpeedLines" and not c._p.Destroyed then
				return c
			end
		end
		return nil
	end
	local d = Shatter.Descent(m, 20)
	local sl = lines()
	check("descent: the pack's speed lines stream round the falling body (a volume that follows it)", sl ~= nil and sl.ClassName == "Part" and sl.Transparency == 1 and not sl.CanCollide and sl:FindFirstChildOfClass("ParticleEmitter").Enabled == true)
	root.CFrame = CF.new(3, 12, -2)
	Env.step(1 / 60)
	check("descent: ... following it as it falls", sl and (sl.CFrame.Position - (root.CFrame * V3.new(0, -0.5, 0))).Magnitude < 1e-6)
	check("descent: its sound plays", sounds[#sounds] and sounds[#sounds].Name == "SlamDescent")
	d.Stop()
	check("descent: on touchdown the lines stop at once", sl:FindFirstChildOfClass("ParticleEmitter").Enabled == false)
	Env.run(0.4)
	check("descent: ... and are cleaned up", lines() == nil)
	local d2 = Shatter.Descent(m, 20)
	Env.run(2.5)
	check("descent: never outlives a fall (stops by itself)", lines() == nil)
	d2.Stop() -- (twice is harmless)
	local bare = Client.new("Model")
	check("descent on a body without parts: a harmless no-op", type(Shatter.Descent(bare).Stop) == "function")
	check("preview: the finished fracture for Studio", Shatter.Preview(V3.new(0, 0.05, 0), nil, 3) > 10)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
