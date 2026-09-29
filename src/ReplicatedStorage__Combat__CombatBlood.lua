--[[
	CombatBlood  (ReplicatedStorage.Combat.CombatBlood)
	Blood for a clean blow - client-side and cosmetic (every client builds its own from the "Hit"
	it hears, or the attacker from its own impact frame). Built to be cheap: nothing is created or
	destroyed while the fight runs (every droplet and splat is pooled), a droplet costs one ray a
	frame, and nothing is built out of the camera's reach (Config.Blood.View).

	  Blood.Spray(pos, drive, tier, victim?, dirSign?)
	      pos = the contact point on the body, drive = the way the blow travels (flat), dirSign = the
	      way it drove the head (+1 = to the victim's right). The wound bursts: the place's own blood
	      effects (ReplicatedStorage.Combat.VFX: Blood, BloodHeavy - Config.Blood.Tiers picks which,
	      how big, how many), aimed OUT of the wound surface and carried by the struck part's own
	      motion - back with a straight, sideways with a hook, up with an uppercut - never into the
	      body; and with them the tier's Drops: liquid droplets flung out on real arcs
	  Blood.Burst(pos, dir, name, scale?, count?)   one of those effects, thrown along `dir` (the gore)
	  Blood.Launch(pos, vel, size)                  one droplet (the gore's bleeding)
	  Blood.Cone(dir, deg)                          a random direction within `deg` of `dir`
	  Blood.Ignore(body)                            a body blood falls past (the gore's NPCs)

	A DROPLET is liquid: a glossy bead stretched along its flight with a short tapering streak behind
	it (a Trail), on the exact arc of  dv/dt = -k v + g  (air drag k, gravity g), integrated exactly
	(no step error at any frame rate), one ray along each frame's chord (a long frame in 1/30 s
	pieces: nothing skips through a wall). Where it meets something solid - floor, wall or slope - it
	lands as a POOL (Config.Blood.Pool): an organic body of wavy-edged lobes stretched the way the
	drop skidded, a thin darker clotting edge, a wet highlight, spikes and droplets thrown out ahead
	of it, and on a wall a drip that runs down as far as the wall goes. It splashes out with a little
	overshoot, creeps out a touch further, darkens and loses its shine as it dries, then soaks away.
	Blood is ONE liquid: a drop landing in a pool swells it where it landed, and pools that run into
	each other flow together through a neck of blood into one puddle - one surface (every pool's
	pieces lie in the same layers, so no edge ever shows inside it), one colour and one clock. Nothing
	is see-through, nothing hangs over an edge, and water, fighters, see-through and non-colliding
	things never catch blood. A pool costs nothing lying still - only while it splashes, creeps,
	drips or soaks away (and a colour change five times a second as it dries).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))
local VFX = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatVFX"))

local Blood = {}

local B = Config.Blood
local MAX_DROPS = B.MaxDrops
local P = B.Pool
local DROP_LIFE = 2.2 -- a drop that has met nothing by then (off a cliff) is gone
local SUBSTEP = 1 / 30 -- (the longest chord one ray covers)

local G = Vector3.new(0, -workspace.Gravity, 0)
local K = B.Drag
local TERMINAL = G / K -- the velocity drag and gravity balance at
local PARK = CFrame.new(0, -5000, 0)
local WET = B.Color

-- the exact flight: position and velocity after `h` seconds from (x, v)
local function advance(x: Vector3, v: Vector3, h: number): (Vector3, Vector3)
	local e = math.exp(-K * h)
	local rel = v - TERMINAL
	return x + TERMINAL * h + rel * ((1 - e) / K), TERMINAL + rel * e
end

---------------------------------------------------------------------------
-- holder + what blood never lands on
---------------------------------------------------------------------------
local folder: Folder? = nil
local function holder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatBlood"
	f.Parent = workspace
	folder = f
	return f
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
rayParams.RespectCanCollide = true -- bushes, flowers and effects aren't surfaces blood lands on
local filterAt = -math.huge
-- bodies blood falls past besides the players and the practice dummies (weak: a removed body is dropped)
local ignored: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function Blood.Ignore(body: Instance)
	ignored[body] = true
	filterAt = -math.huge
end
local function refreshFilter()
	local t = os.clock()
	if t - filterAt < 0.5 then
		return
	end
	filterAt = t
	local list: { Instance } = { holder() }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, name in ipairs({ "PracticeDummies", "CombatFX", "CombatShatter", "CombatGore" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	for body in pairs(ignored) do
		if body.Parent then
			table.insert(list, body)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

-- a ray that only stops on something solid-looking (glass, a trigger, a force field: straight through)
local function castSolid(from: Vector3, delta: Vector3): RaycastResult?
	local origin, left = from, delta
	for _ = 1, 3 do
		local hit = workspace:Raycast(origin, left, rayParams)
		if not hit then
			return nil
		end
		local inst = hit.Instance :: BasePart
		if inst:IsA("Terrain") or (inst.Transparency < 0.85 and inst.Material ~= Enum.Material.ForceField) then
			return hit
		end
		local travelled = (hit.Position - origin).Magnitude + 0.02
		if travelled >= left.Magnitude then
			return nil
		end
		origin += left.Unit * travelled
		left = left.Unit * (left.Magnitude - travelled)
	end
	return nil
end

local function inView(pos: Vector3): boolean
	local cam = workspace.CurrentCamera
	return cam == nil or (cam.CFrame.Position - pos).Magnitude <= B.View
end

---------------------------------------------------------------------------
-- droplets (a bead + its streak)
---------------------------------------------------------------------------
type Drop = { Part: Part, Trail: Trail, A0: Attachment, A1: Attachment, Pos: Vector3, Vel: Vector3, Size: number, Age: number, Live: boolean }
local drops: { Drop } = {}

local STREAK_T = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.6, 0.35), NumberSequenceKeypoint.new(1, 1) })
local STREAK_W = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.1) })

local function newDrop(): Drop
	local p = Instance.new("Part")
	p.Name = "BloodDrop"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = 0.15 -- (a wet shine)
	p.Color = WET
	p.Size = Vector3.new(0.12, 0.12, 0.2)
	p.CFrame = PARK
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Parent, a1.Parent = p, p
	local tr = Instance.new("Trail")
	tr.Attachment0, tr.Attachment1 = a0, a1
	tr.FaceCamera = true
	tr.Lifetime = 0.09
	tr.MinLength = 0.02
	tr.Color = ColorSequence.new(WET, P.Fresh)
	tr.Transparency = STREAK_T
	tr.WidthScale = STREAK_W
	tr.LightInfluence = 1
	tr.Enabled = false
	tr.Parent = p
	p.Parent = holder()
	local d = { Part = p, Trail = tr, A0 = a0, A1 = a1, Pos = Vector3.zero, Vel = Vector3.zero, Size = 0.12, Age = 0, Live = false }
	table.insert(drops, d)
	return d
end

local function takeDrop(): Drop?
	for _, d in ipairs(drops) do
		if not d.Live then
			return d
		end
	end
	if #drops < MAX_DROPS then
		return newDrop()
	end
	-- (all in the air: the oldest gives way)
	local oldest: Drop? = nil
	for _, d in ipairs(drops) do
		if not oldest or d.Age > oldest.Age then
			oldest = d
		end
	end
	if oldest then
		oldest.Trail.Enabled = false
		oldest.Live = false
	end
	return oldest
end

---------------------------------------------------------------------------
-- pools
---------------------------------------------------------------------------
-- Every pool is the same fixed set of flat pieces (opaque flattened-ellipsoid parts): the LOBES that
-- make its body, each over a slightly bigger darker RIM (the clotting edge), a wet highlight, the
-- satellites (spikes and droplets thrown out of the splash), a drip and its bead on a wall, and the
-- BRIDGES - the necks of liquid that join it to pools it runs into.
-- Every piece of a kind lies at the SAME height above its surface in EVERY pool (LAYER), so wherever
-- two pools meet their bodies are one continuous surface: a rim only ever shows round the outside of
-- the whole joined shape, never across it, nothing is see-through to stack up, and pools that have
-- joined dry and soak away as one (they share one clock). A pool keeps spreading for a couple of
-- seconds after its splash (liquid creeping out), and when it reaches another the two flow together.
local RIM, BODY, GLOSS, SAT, DRIP, BEAD = 1, 2, 3, 4, 5, 6
local LOBES, SATS, BRIDGES = 5, 5, 2
-- per kind: the centre plane's height off the surface, and the thickness (the layers 0.01 apart - rims,
-- then satellites and drips, then the bodies, the highlight on top - and each thin enough that its
-- top is flat: overlapping lobes melt into one surface without seams)
local LAYER = { 0.01, 0.03, 0.04, 0.02, 0.02, 0.02 }
local THICK = { 0.008, 0.008, 0.006, 0.006, 0.006, 0.006 }
-- (only the sheen reflects: on a flattened ellipsoid a reflectance mirrors the sky across the whole
-- top - which washes a body out pink, and in a touch is exactly the wet look the sheen is for)
local GLOSS_SHINE = 0.08
local SPLASH = 0.26 -- seconds a lobe takes to spread out
local DRIP_START, DRIP_TIME = 0.3, 1.9
local CREEP_START, CREEP_TIME = 0.2, 2.6 -- the slow spread after the splash
local SLOW_HZ = 20 -- how often a creeping / dripping pool is redrawn (fast phases: every frame)

type Piece = {
	Part: Part,
	Kind: number,
	Used: boolean,
	U: number, -- centre, and diameters A (along its own axis) x B, in the pool's radius (studs for a neck)
	V: number,
	A: number,
	B: number,
	Rot: number,
	Delay: number,
	Dur: number,
	Neck: boolean, -- (a bridge: laid out in studs, and it fattens instead of spreading)
}
type Pool = {
	Pieces: { Piece },
	Rims: { Piece },
	Bodies: { Piece },
	Gloss: Piece,
	Sats: { Piece },
	Drip: Piece,
	Bead: Piece,
	Live: boolean,
	Basis: CFrame, -- (X the surface normal, Y the way the drop skidded)
	Normal: Vector3,
	Plane: number,
	Pos: Vector3,
	Born: number, -- the splash: the spread, the creep and the drip run from here
	Fresh: number, -- drying and soaking away run from here (shared by every pool it has joined)
	R0: number,
	R: number,
	RAt: number,
	Creep: number,
	GrowEnd: number,
	NextDraw: number,
	Dripping: boolean,
	DripLen: number,
	Links: { [any]: boolean },
}
local pools: { Pool } = {}

local function piecePart(kind: number): Part
	local p = Instance.new("Part")
	p.Name = "BloodPool"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = if kind == GLOSS then GLOSS_SHINE else 0
	p.Color = if kind == RIM then P.Rim elseif kind == GLOSS then P.Gloss else P.Fresh
	p.Size = Vector3.new(0.01, 0.01, 0.01)
	p.CFrame = PARK
	-- (a sphere mesh fills the part's box: squashed flat, an ellipse with a soft edge that stretches into
	-- a streak, a spike or a neck)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = holder()
	return p
end

local function newPool(): Pool
	local all: { Piece } = {}
	local function add(kind: number): Piece
		local pc = { Part = piecePart(kind), Kind = kind, Used = false, U = 0, V = 0, A = 0, B = 0, Rot = 0, Delay = 0, Dur = 1, Neck = false }
		table.insert(all, pc)
		return pc
	end
	local rims, bodies, sats = {}, {}, {}
	for i = 1, LOBES + BRIDGES do
		rims[i] = add(RIM)
	end
	for i = 1, LOBES + BRIDGES do
		bodies[i] = add(BODY)
	end
	for i = 1, SATS do
		sats[i] = add(SAT)
	end
	local pool = {
		Pieces = all, Rims = rims, Bodies = bodies, Gloss = add(GLOSS), Sats = sats, Drip = add(DRIP), Bead = add(BEAD),
		Live = false, Basis = CFrame.identity, Normal = Vector3.yAxis, Plane = 0, Pos = Vector3.zero,
		Born = 0, Fresh = 0, R0 = 0, R = 0, RAt = 0, Creep = 1, GrowEnd = 0, NextDraw = 0,
		Dripping = false, DripLen = 0, Links = {},
	}
	table.insert(pools, pool)
	return pool
end

local stepConn: RBXScriptConnection? = nil
local step: (number) -> ()
local function wake()
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
end

local function rand(a: number, b: number): number
	return a + math.random() * (b - a)
end

-- a splash that overshoots its edge a little and settles back (a liquid finding its rest)
local function backOut(x: number): number
	local c1 = 1.25
	local y = x - 1
	return 1 + (c1 + 1) * y * y * y + c1 * y * y
end

local function set(pc: Piece, u: number, v: number, a: number, b: number, rot: number, delay: number, dur: number)
	pc.Used = true
	pc.Neck = false
	pc.U, pc.V, pc.A, pc.B, pc.Rot, pc.Delay, pc.Dur = u, v, a, b, rot, delay, dur
end

-- lobe (or bridge) slot `i`, with its rim under it: an ellipse a x b at (u, v)
local function lobe(pool: Pool, i: number, u: number, v: number, a: number, b: number, rot: number, delay: number, dur: number, rimW: number)
	set(pool.Bodies[i], u, v, a, b, rot, delay, dur)
	set(pool.Rims[i], u, v, a + rimW * 2, b + rimW * 2, rot, delay, dur)
	pool.GrowEnd = math.max(pool.GrowEnd, delay + dur)
end

-- the pool's radius now (a drop landing in it spreads it; after the splash it creeps out a little)
local function radius(pool: Pool, now: number, slow: number): (number, number)
	local mk = math.clamp((now - pool.RAt) * slow / 0.22, 0, 1)
	local base = pool.R0 + (pool.R - pool.R0) * (1 - (1 - mk) ^ 3)
	local c = math.clamp(((now - pool.Born) * slow - CREEP_START) / CREEP_TIME, 0, 1)
	return base * (1 + (pool.Creep - 1) * (1 - (1 - c) ^ 2)), mk
end

-- is there surface under (u, v) (studs, in the pool's frame) - the same surface, not a ledge's drop
-- or a step up?
local function supported(pool: Pool, u: number, v: number): boolean
	local n = pool.Normal
	local p = pool.Basis * Vector3.new(0, u, v)
	local hit = castSolid(p + n * 0.35, n * -0.6)
	return hit ~= nil and hit.Normal:Dot(n) > 0.9 and math.abs(hit.Position:Dot(n) - pool.Plane) < 0.06
end

-- the whole shape of a new pool, in its radius: `f` 0..1 how fast the drop skidded along the surface
-- (a fast one stretches the pool ahead of it and flings its splash forward, a drip straight down lands
-- round with its splash all round). Pieces with nothing under them (past an edge) are left out.
local function shape(pool: Pool, f: number, speed: number, r: number)
	for _, pc in ipairs(pool.Pieces) do
		pc.Used = false
	end
	pool.GrowEnd = 0
	local reach = r * pool.Creep -- (the most it spreads to)
	local rimW = 0.012 / r + 0.018
	-- the main body, stretched along the skid (smaller if it would hang over an edge)
	local main = 1
	for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		if not supported(pool, d[1] * reach * 0.85, d[2] * reach * 0.85) then
			main = 0.65
			pool.Creep = 1
			break
		end
	end
	lobe(pool, 1, 0.1 * f, 0, 2 * (0.85 + 0.35 * f) * main * rand(0.95, 1.05), 2 * main * rand(0.7, 0.88), rand(-0.2, 0.2) * (1 - f), 0, SPLASH, rimW)
	-- swells in its edge, spread round it (leaning forward on a skid): long and low, pushed out only a
	-- little past the main body - a wavy edge, not a bunch of bubbles (the last slot waits for a drop
	-- landing in it)
	local lobes = if r < 0.2 then math.random(1, 2) else math.random(3, LOBES - 1)
	local spin = rand(0, math.pi * 2)
	for i = 2, lobes do
		local ang = spin + (i - 2) / (lobes - 1) * math.pi * 2 + rand(-0.5, 0.5)
		ang = math.atan2(math.sin(ang), math.cos(ang)) * (1 - 0.5 * f)
		local half = rand(0.35, 0.6) * main
		local dist = 0.82 * main - half * rand(0.45, 0.85)
		local c, s = math.cos(ang), math.sin(ang)
		if supported(pool, c * (dist + half) * reach, s * (dist + half) * reach) then
			lobe(pool, i, c * dist, s * dist, 2 * half * rand(1.1, 1.5), 2 * half * rand(0.55, 0.75), ang + math.pi * 0.5 + rand(-0.35, 0.35), (i - 1) * 0.035, SPLASH, rimW)
		end
	end
	-- the wet sheen: a broad, barely lighter patch over the thick middle of a real pool (it melts into
	-- the body as it dries)
	if r >= 0.28 then
		set(pool.Gloss, rand(-0.2, 0) * main, rand(0.05, 0.2) * main, rand(0.9, 1.1) * main, rand(0.45, 0.6) * main, rand(-0.5, 0.5), 0.1, 0.35)
	end
	-- the splash: spikes - thin tapering fingers shot out of the edge - and droplets beyond them, the
	-- fast ones drawn out into streaks pointing away, all thrown ahead of the skid
	local sats = math.clamp(math.floor((speed - 4) / 5 + math.random() * 1.6), 0, SATS)
	for i = 1, sats do
		local ang = (if math.random() < 0.5 then -1 else 1) * math.random() ^ 1.3 * math.pi * (0.3 + 0.7 * (1 - f))
		local c, s = math.cos(ang), math.sin(ang)
		local u, v, a, b, delay, dur
		if math.random() < 0.25 + 0.5 * f then
			a = 2 * rand(0.3, 0.6) * (1 + 0.8 * f)
			b = 2 * rand(0.06, 0.11)
			local dist = rand(0.75, 0.95) * main + a * 0.35
			u, v, delay, dur = c * dist, s * dist, rand(0, 0.04), 0.14
		else
			local dist = rand(1.15, 2.0) + 0.35 * f
			b = 2 * rand(0.07, 0.18)
			a = b * (1 + f * rand(0.4, 2.6))
			u, v, delay, dur = c * dist, s * dist, rand(0.01, 0.07), 0.12
		end
		if supported(pool, u * r, v * r) then
			set(pool.Sats[i], u, v, a, b, ang, delay, dur)
		end
	end
	-- on a wall it runs down, as far as the wall goes
	if pool.Dripping then
		local n = pool.Normal
		local down = Vector3.new(0, -1, 0) + n * n.Y
		local rot = math.atan2(down:Dot(pool.Basis.ZVector), down:Dot(pool.Basis.YVector))
		local c, s = math.cos(rot), math.sin(rot)
		local len = rand(1.2, 2.8)
		if not supported(pool, c * (0.55 + len) * r, s * (0.55 + len) * r) then
			len *= 0.4
		end
		pool.DripLen = len
		set(pool.Drip, 0, 0, 0, 0, rot, DRIP_START, DRIP_TIME)
		set(pool.Bead, 0, 0, 0, 0, rot, DRIP_START, DRIP_TIME)
	end
	for _, pc in ipairs(pool.Pieces) do
		if pc.Used and pc.Kind ~= DRIP and pc.Kind ~= BEAD then
			pool.GrowEnd = math.max(pool.GrowEnd, pc.Delay + pc.Dur)
		end
	end
end

-- where every piece of `pool` is `age` seconds in, at radius `r`, `shrink` 1 -> 0 as it soaks away
local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}
local function place(pool: Pool, age: number, r: number, shrink: number)
	local off = 0.55 + 0.45 * shrink
	for _, pc in ipairs(pool.Pieces) do
		local kind = pc.Kind
		if not pc.Used then
			continue
		end
		local k = math.clamp((age - pc.Delay) / pc.Dur, 0, 1)
		local u, v, a, b
		if pc.Neck then
			-- a bridge: already full length, it fattens as the two pools flow together
			local e = 1 - (1 - k) ^ 3
			u, v = pc.U * off, pc.V * off
			a, b = pc.A * (0.3 + 0.7 * e) * shrink, pc.B * e * shrink
		elseif kind == DRIP or kind == BEAD then
			-- runs fast, then slows as it thins out (a bead gathering at its tip)
			local e = 1 - (1 - k) ^ 2
			local len = pool.DripLen * r * e
			local w = r * 0.26 * (1 - 0.35 * e) * shrink
			local along
			if kind == DRIP then
				a, b = len * shrink + w, w
				along = r * 0.55 + len * 0.5
			else
				a = w * (1.2 + 0.3 * e)
				b = a
				along = r * 0.55 + len
			end
			u, v = math.cos(pc.Rot) * along * off, math.sin(pc.Rot) * along * off
		else
			local g = if k <= 0 then 0 else backOut(k)
			local out = if kind == SAT then 0.6 + 0.4 * g else 0.45 + 0.55 * g
			u, v = pc.U * r * out * off, pc.V * r * out * off
			local sz = r * g * shrink
			a, b = pc.A * sz, pc.B * sz
		end
		local part = pc.Part
		part.Size = Vector3.new(THICK[kind], math.max(a, 0.001), math.max(b, 0.001))
		table.insert(moveParts, part)
		table.insert(moveCfs, pool.Basis * CFrame.new(LAYER[kind], u, v) * CFrame.Angles(pc.Rot, 0, 0))
	end
end

-- drying: the blood darkens and its sheen melts into it (one colour for every pool with the same
-- clock, so pools that joined never show a line between them)
local function dry(pool: Pool, life: number)
	local k = math.clamp((life - 0.8) / (P.Life * 0.55), 0, 1)
	k = k * (2 - k)
	local body, rim = P.Fresh:Lerp(P.Dried, k), P.Rim:Lerp(P.RimDried, k)
	for _, pc in ipairs(pool.Pieces) do
		if pc.Used then
			if pc.Kind == RIM then
				pc.Part.Color = rim
			elseif pc.Kind == GLOSS then
				pc.Part.Color = P.Gloss:Lerp(body, k)
				pc.Part.Reflectance = GLOSS_SHINE * (1 - k)
			else
				pc.Part.Color = body
			end
		end
	end
end

local function unlink(pool: Pool)
	for other in pairs(pool.Links) do
		other.Links[pool] = nil
	end
	table.clear(pool.Links)
end

local function park(pool: Pool)
	pool.Live = false
	unlink(pool)
	for _, pc in ipairs(pool.Pieces) do
		pc.Used = false
		table.insert(moveParts, pc.Part)
		table.insert(moveCfs, PARK)
	end
end

-- a live pool on the same surface (a floor with a pool on it, not the step beside it) that is still
-- lying there, not soaking away
local function open(a: Pool, n: Vector3, plane: number, now: number, slow: number): boolean
	return a.Live and a.Normal:Dot(n) > 0.95 and math.abs(a.Plane - plane) < 0.05 and (now - a.Fresh) * slow < P.Life - P.Fade
end

-- every pool joined to `pool` (itself included) takes the freshest clock of them all - and its colour
-- at once, so the joined puddle is one colour
local function shareClock(pool: Pool, now: number, slow: number)
	local seen, list, fresh = { [pool] = true }, { pool }, pool.Fresh
	local i = 1
	while list[i] do
		local p = list[i]
		fresh = math.max(fresh, p.Fresh)
		for other in pairs(p.Links) do
			if not seen[other] then
				seen[other] = true
				table.insert(list, other)
			end
		end
		i += 1
	end
	for _, p in ipairs(list) do
		p.Fresh = fresh
		dry(p, (now - fresh) * slow)
	end
end

-- two pools that have run into each other flow together: a neck of blood fattens between them, and from
-- then on they are one pool (one clock: they dry and soak away together)
local function join(a: Pool, b: Pool, now: number, slow: number)
	a.Links[b], b.Links[a] = true, true
	local owner, other = a, b
	local slot = nil
	for s = LOBES + 1, LOBES + BRIDGES do
		if not a.Bodies[s].Used then
			slot = s
			break
		end
	end
	if not slot then
		owner, other = b, a
		for s = LOBES + 1, LOBES + BRIDGES do
			if not b.Bodies[s].Used then
				slot = s
				break
			end
		end
	end
	if slot then
		local rel = other.Pos - owner.Pos
		local u, v = rel:Dot(owner.Basis.YVector), rel:Dot(owner.Basis.ZVector)
		local d = math.sqrt(u * u + v * v)
		local ro, rx = radius(owner, now, slow), radius(other, now, slow)
		local w = math.min(ro, rx) * rand(1.0, 1.3)
		local age = (now - owner.Born) * slow
		lobe(owner, slot, u * 0.5, v * 0.5, d + w * 0.5, w, math.atan2(v, u), age, 0.45, 0.03)
		owner.Bodies[slot].Neck, owner.Rims[slot].Neck = true, true
	end
	shareClock(a, now, slow)
end

-- any pool on the same surface that `pool` now touches joins it
local function touch(pool: Pool, now: number, slow: number)
	local r = radius(pool, now, slow)
	for _, other in ipairs(pools) do
		if other ~= pool and not pool.Links[other] and open(other, pool.Normal, pool.Plane, now, slow) then
			local ro = radius(other, now, slow)
			if (other.Pos - pool.Pos).Magnitude < (r + ro) * 0.92 then
				join(pool, other, now, slow)
			end
		end
	end
end

-- a drop met `hit` at velocity `vel`: a pool splashes out there, or the pool it lands in takes it in
local function splat(hit: RaycastResult, size: number, vel: Vector3)
	if hit.Material == Enum.Material.Water or not inView(hit.Position) then
		return
	end
	local now = os.clock()
	local slow = VFX.TimeScale()
	local n = hit.Normal
	local plane = hit.Position:Dot(n)
	local speed = vel.Magnitude
	local r = size * (2.3 + math.min(speed, 30) * 0.05)
	-- landing in a pool: it swells out where the drop landed (a new lobe while it has one to spare, else
	-- it spreads a little all round), and stays wet longer
	for _, pool in ipairs(pools) do
		if not open(pool, n, plane, now, slow) then
			continue
		end
		local cur, mk = radius(pool, now, slow)
		local rel = hit.Position - pool.Pos
		if rel.Magnitude < cur * 0.9 then
			pool.R0 = pool.R0 + (pool.R - pool.R0) * (1 - (1 - mk) ^ 3)
			local u, v = rel:Dot(pool.Basis.YVector) / cur, rel:Dot(pool.Basis.ZVector) / cur
			local dist = math.sqrt(u * u + v * v)
			local free = nil
			for i = 2, LOBES do
				if not pool.Bodies[i].Used then
					free = i
					break
				end
			end
			if free and dist > 0.3 then
				local a = 2 * math.clamp(r / cur * 1.2, 0.4, 0.75)
				local ang = math.atan2(v, u)
				lobe(pool, free, u, v, a * rand(1.1, 1.4), a * rand(0.6, 0.8), ang + math.pi * 0.5 + rand(-0.4, 0.4), (now - pool.Born) * slow, SPLASH, 0.012 / cur + 0.018)
				pool.R = math.min(math.sqrt(pool.R * pool.R + r * r * 0.25), P.MaxRadius)
			else
				pool.R = math.min(math.sqrt(pool.R * pool.R + r * r * 0.6), P.MaxRadius)
			end
			pool.RAt = now
			pool.Fresh = math.max(pool.Fresh, now - P.Life * 0.2)
			shareClock(pool, now, slow)
			wake()
			return
		end
	end
	local pool: Pool? = nil
	for _, p in ipairs(pools) do
		if not p.Live then
			pool = p
			break
		end
	end
	if not pool then
		if #pools < P.Max then
			pool = newPool()
		else
			-- (all lying there: the oldest makes way)
			for _, p in ipairs(pools) do
				if not pool or p.Fresh < pool.Fresh then
					pool = p
				end
			end
			assert(pool)
			unlink(pool)
		end
	end
	assert(pool)
	-- Y: the way the drop skidded along the surface (any way at all for one that fell straight in)
	local along = vel - n * vel:Dot(n)
	local side: Vector3
	if along.Magnitude > 0.5 then
		side = along.Unit
	else
		local ref = if math.abs(n.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		side = CFrame.fromAxisAngle(n, math.random() * math.pi * 2):VectorToWorldSpace(n:Cross(ref).Unit)
	end
	pool.Basis = CFrame.fromMatrix(hit.Position, n, side, n:Cross(side))
	pool.Normal = n
	pool.Plane = plane
	pool.Pos = hit.Position
	pool.Born, pool.Fresh, pool.RAt, pool.NextDraw = now, now, now, 0
	pool.R0, pool.R = r, r
	pool.Creep = 1 + rand(0.12, 0.28)
	pool.Dripping = math.abs(n.Y) < 0.7
	shape(pool, math.clamp(along.Magnitude / 22, 0, 1), speed, r)
	local body = P.Fresh
	for _, pc in ipairs(pool.Pieces) do
		local part = pc.Part
		if pc.Kind == RIM then
			part.Color = P.Rim
		elseif pc.Kind == GLOSS then
			part.Color = P.Gloss
			part.Reflectance = GLOSS_SHINE
		else
			part.Color = body
		end
		if not pc.Used then
			table.insert(moveParts, part)
			table.insert(moveCfs, PARK)
		end
	end
	pool.Live = true
	place(pool, 0, r, 1)
	touch(pool, now, slow)
	wake()
end

---------------------------------------------------------------------------
-- one step for everything live: drops fly, pools splash / drip / dry / soak away (one BulkMoveTo)
---------------------------------------------------------------------------
local function fly(d: Drop, dt: number): RaycastResult?
	local left = dt
	while left > 1e-6 do
		local h = math.min(SUBSTEP, left)
		left -= h
		local x1, v1 = advance(d.Pos, d.Vel, h)
		local hit = castSolid(d.Pos, x1 - d.Pos)
		if hit then
			d.Pos = hit.Position
			return hit
		end
		d.Pos, d.Vel = x1, v1
		d.Age += h
	end
	return nil
end

local nextBeat = 0
function step(dt: number)
	dt = math.min(dt, 0.1) * VFX.TimeScale() -- (Studio inspection can slow it down with the effects)
	table.clear(moveParts)
	table.clear(moveCfs)
	local any = false
	refreshFilter()
	for _, d in ipairs(drops) do
		if d.Live then
			any = true
			local hit = fly(d, dt)
			if hit or d.Age > DROP_LIFE then
				d.Live = false
				d.Trail.Enabled = false
				if hit then
					splat(hit, d.Size, d.Vel)
				end
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, PARK)
			else
				-- a bead stretched along its flight (a fast one is a long thin streak)
				local v = d.Vel
				local speed = v.Magnitude
				local len = 1 + math.min(speed, 45) * 0.045
				d.Part.Size = Vector3.new(d.Size, d.Size, d.Size * len)
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, CFrame.lookAt(d.Pos, d.Pos + (if speed > 0.1 then v else Vector3.yAxis)))
			end
		end
	end
	local now = os.clock()
	local slow = VFX.TimeScale()
	-- (drying and the creeping pools' contacts on one shared 5 Hz beat: pools with one clock get one
	-- colour in the same frame)
	local beat = now >= nextBeat
	if beat then
		nextBeat = now + 0.2
	end
	for _, pool in ipairs(pools) do
		if not pool.Live then
			continue
		end
		any = true
		-- (Studio's slow motion stretches a pool's clock too)
		local age = (now - pool.Born) * slow
		local life = (now - pool.Fresh) * slow
		if life >= P.Life then
			park(pool)
			continue
		end
		local fade = math.clamp((life - (P.Life - P.Fade)) / P.Fade, 0, 1)
		local r, mk = radius(pool, now, slow)
		local fast = age < pool.GrowEnd or mk < 1 or fade > 0
		local slowly = age < CREEP_START + CREEP_TIME or (pool.Dripping and age < DRIP_START + DRIP_TIME)
		if fast then
			place(pool, age, r, 1 - fade * fade)
		elseif slowly and now >= pool.NextDraw then
			pool.NextDraw = now + 1 / SLOW_HZ
			place(pool, age, r, 1)
		end
		if beat then
			dry(pool, life)
			if age < CREEP_START + CREEP_TIME + 0.3 then
				touch(pool, now, slow)
			end
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if not any and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------
function Blood.Launch(pos: Vector3, vel: Vector3, size: number)
	if not B.Enabled or not inView(pos) then
		return
	end
	local d = takeDrop()
	if not d then
		return
	end
	refreshFilter()
	d.Live = true
	d.Age = 0
	d.Pos = pos
	d.Vel = vel
	d.Size = size
	d.A0.Position = Vector3.new(size * 0.5, 0, 0)
	d.A1.Position = Vector3.new(-size * 0.5, 0, 0)
	d.Part.Size = Vector3.new(size, size, size)
	d.Part.CFrame = CFrame.lookAt(pos, pos + (if vel.Magnitude > 0.1 then vel else Vector3.yAxis))
	d.Trail:Clear()
	d.Trail.Enabled = true
	wake()
end

-- a random unit vector within `deg` degrees of `dir`
local function cone(dir: Vector3, deg: number): Vector3
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local a = math.rad(deg) * math.sqrt(math.random())
	local b = math.random() * math.pi * 2
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local fwd = right:Cross(up).Unit
	return (up * math.cos(a) + (right * math.cos(b) + fwd * math.sin(b)) * math.sin(a)).Unit
end
Blood.Cone = cone

-- one of the place's blood effects (ReplicatedStorage.Combat.VFX) burst at `pos`, thrown along `dir`
function Blood.Burst(pos: Vector3, dir: Vector3, name: string, scale: number?, count: number?)
	if not B.Enabled or not inView(pos) then
		return
	end
	VFX.Play(name, VFX.Along(pos, if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis), { Scale = scale or 1, Count = count or 1 })
end

-- the outward normal of the body surface at `pos` (the head's for a blow above the shoulders, the
-- torso's lower down), and the struck part's motion just after the blow
local function wound(pos: Vector3, drive: Vector3, tier: any, victim: Model?, dirSign: number?): (Vector3, Vector3)
	local d = Vector3.new(drive.X, 0, drive.Z)
	d = if d.Magnitude > 1e-3 then d.Unit else Vector3.new(0, 0, -1)
	local normal = -d
	local side = Vector3.zero
	local root = victim and victim:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local rp = root.Position
		local center = if pos.Y - rp.Y > 1.05 then rp + Vector3.new(0, 1.5, 0) else Vector3.new(rp.X, pos.Y, rp.Z)
		local out = pos - center
		if out.Magnitude > 0.1 then
			normal = out.Unit
		end
		local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z)
		side = if right.Magnitude > 1e-3 then right.Unit * (dirSign or 0) else Vector3.zero
	end
	return normal, d * tier.Carry + side * tier.Side + Vector3.new(0, tier.Lift, 0)
end

function Blood.Spray(pos: Vector3, drive: Vector3, tierName: string?, victim: Model?, dirSign: number?)
	if not B.Enabled or not inView(pos) then
		return
	end
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local normal, head = wound(pos, drive, tier, victim, dirSign)
	-- aimed out of the wound, thrown the way the struck part goes - sideways with a hook, up with an
	-- uppercut - but never into the body (the part of that motion running back into it is the body's)
	local carried = head - normal * math.min(0, head:Dot(normal))
	local speed = (tier.Eject[1] + tier.Eject[2]) * 0.5
	local mean = normal * speed * 0.6 + carried * 0.6
	local aim = if mean.Magnitude > 1e-3 then mean.Unit else normal
	for _, fx in ipairs(tier.Effects) do
		Blood.Burst(pos, aim, fx.Name, fx.Scale, fx.Count)
	end
	-- the liquid: drops flung out of the wound on their own arcs, the struck part's motion in them
	for _ = 1, tier.Drops do
		local dir = cone(aim, tier.Spread)
		local v = dir * (tier.Eject[1] + math.random() * (tier.Eject[2] - tier.Eject[1])) + carried * 0.35
		Blood.Launch(pos + dir * 0.15, v, 0.08 + math.random() * 0.07)
	end
end

return Blood
