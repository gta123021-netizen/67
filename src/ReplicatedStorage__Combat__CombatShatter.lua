--[[
	CombatShatter  (ReplicatedStorage.Combat.CombatShatter)
	The Ground Smash, start to finish. Client-side and cosmetic only: every client builds its own
	copy when it hears about a smash (the smasher from its own touchdown frame).

	  Shatter.Descent(char, height)   the drop: air rushing up past the falling body, speed lines, a
	                                  faint trail - nothing on the ground yet. Returns { Stop }.
	  Shatter.Play(ground, attacker)  the touchdown and everything it sets off
	  Shatter.Preview(ground, parent) the finished fracture standing still (Studio inspection)

	THE SEQUENCE (seconds after touchdown)
	  0.00  IMPACT      a flash of light, the air under the foot squeezed out in a ring of dust hugging
	                    the ground, the first cracks flashing out from the foot, the boom and its bass
	  0.00  FRACTURE    fissures run outward from the foot - 6 to 9 main ones, each wandering and
	        -0.30       tapering, forking now and then, some reaching the rim and some stopping short
	                    (never symmetric) - progressively, at the speed of the break. They follow the
	                    ground (slopes, steps, terrain) and stop at a ledge, a wall or water. Their
	                    reach IS the smash's gameplay radius (Config.Attacks.Downslam.StompRadius)
	  0.02  DEBRIS      the ground between the fissures heaves up in fractured slabs (the floor's own
	        BURST       surface on packed earth, outer edges lifted: a raised rim round a sunken,
	                    darkened centre); medium rocks are thrown in heavy arcs, small ones faster and
	                    further, and a spray of grit - all in the ground's own material and colour
	  0.05  SHOCKWAVE   a ring runs across the ground and ends exactly on the radius
	  0.05  DUST        dust rolls out along the ground and a cloud rises from the centre, tinted
	        -2.0        like the ground, expanding as it fades
	  0.40  ROCK SETTLE the thrown rocks land, bounce once, roll to rest on the surface they hit; the
	        -1.2        slabs sag back a little as they settle
	  ...   HOLD        the crater and its fissures stay
	  2.60  FADE        the rocks sink, the slabs sink back into the ground the way they came, the
	        -3.60       fissures close from the rim inward - then everything is back in its pool

	Nothing is physics: every piece moves on its own tweened or integrated path in one heartbeat
	(BulkMoveTo), is anchored, never collides, never catches a ray and never touches a fighter. All
	pieces come from pools (a smash builds nothing new once the pools exist), so any number of
	fighters can smash at once; a new smash on top of an old one clears the old one first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))

local Shatter = {}

local STOMP = Config.Attacks.Downslam
local R: number = STOMP.StompRadius -- the gameplay radius: fissures and shockwave end here
local CRACK_SPEED = 26 -- studs/s: how fast the break runs out from the foot
local HOLD = 2.6 -- seconds after touchdown the fade begins
local VIEW = 220 -- farther than this from the camera, nothing is built
local EARTH = Color3.fromRGB(98, 79, 62) -- packed earth under a broken surface
local GRAVITY = 150 -- the thrown rocks (studs/s^2)
local FIGHTER_GAP = 1.2 -- no slab heaves up through a fighter's body

-- ground that is itself rock: its slabs are rock all the way down (no earth under them)
local STONY: { [Enum.Material]: boolean } = {
	[Enum.Material.Slate] = true, [Enum.Material.Rock] = true, [Enum.Material.Basalt] = true,
	[Enum.Material.Granite] = true, [Enum.Material.Marble] = true, [Enum.Material.Concrete] = true,
	[Enum.Material.Pavement] = true, [Enum.Material.Limestone] = true, [Enum.Material.Cobblestone] = true,
	[Enum.Material.Brick] = true, [Enum.Material.Sandstone] = true, [Enum.Material.CrackedLava] = true,
	[Enum.Material.Asphalt] = true, [Enum.Material.Salt] = true,
}

---------------------------------------------------------------------------
-- holders, filters, the ground
---------------------------------------------------------------------------
local folder: Folder? = nil
local function holder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatShatter"
	f.Parent = workspace
	folder = f
	return f
end

-- every body the smash must not treat as ground: the players, the practice dummies, and any other
-- character (an NPC anywhere in the map) standing near the smash
local function fighters(center: Vector3?): { Model }
	local list = {}
	local seen: { [Model]: boolean } = {}
	local function add(m: Model)
		if not seen[m] then
			seen[m] = true
			table.insert(list, m)
		end
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			add(pl.Character)
		end
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		for _, m in ipairs(dummies:GetChildren()) do
			if m:IsA("Model") then
				add(m)
			end
		end
	end
	if center then
		local ok, parts = pcall(function()
			return workspace:GetPartBoundsInRadius(center, R + 6)
		end)
		if ok and parts then
			for _, p in ipairs(parts) do
				local m = p:FindFirstAncestorOfClass("Model")
				while m and not m:FindFirstChildOfClass("Humanoid") do
					m = m:FindFirstAncestorOfClass("Model")
				end
				if m then
					add(m)
				end
			end
		end
	end
	return list
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
rayParams.RespectCanCollide = true -- bushes, flowers and effects are not ground
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true

local function setIgnore(center: Vector3?)
	local ignore: { Instance } = { holder() }
	for _, m in ipairs(fighters(center)) do
		table.insert(ignore, m)
	end
	for _, name in ipairs({ "CombatFX", "CombatBlood", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(ignore, f)
		end
	end
	rayParams.FilterDescendantsInstances = ignore
	overlap.FilterDescendantsInstances = ignore
end

-- the floor right under a spot, if it is floor near `refY` (not a ledge far below, not the top of
-- a wall, not a steep face)
local function floorAt(p: Vector3, refY: number, tol: number?): RaycastResult?
	local t = tol or 1.2
	local hit = workspace:Raycast(Vector3.new(p.X, refY + t + 1.5, p.Z), Vector3.new(0, -(t * 2 + 3), 0), rayParams)
	if not hit or hit.Normal.Y < 0.55 or math.abs(hit.Position.Y - refY) > t then
		return nil
	end
	return hit
end

-- what the floor is made of there (its material, colour and material variant)
local function surfaceOf(hit: RaycastResult): (Enum.Material, Color3, string)
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		local ok, c = pcall(function()
			return (inst :: Terrain):GetMaterialColor(hit.Material)
		end)
		return hit.Material, if ok then c else Color3.fromRGB(110, 110, 110), ""
	elseif inst:IsA("BasePart") then
		return inst.Material, inst.Color, inst.MaterialVariant
	end
	return Enum.Material.Ground, EARTH, ""
end

-- nothing solid in a box standing on the ground (a slab heaving up never cuts into a wall, a tree,
-- a fountain, a step)
local probe: Part? = nil
local function openBox(cf: CFrame, size: Vector3): boolean
	local pp = probe
	if not (pp and pp.Parent) then
		local p = Instance.new("Part")
		p.Name = "ShatterProbe"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 1
		p.Parent = holder()
		probe = p
		pp = p
	end
	local part = pp :: Part
	part.Size = size
	part.CFrame = cf
	local hits = workspace:GetPartsInPart(part, overlap)
	part.CFrame = CFrame.new(0, -5000, 0)
	for _, h in ipairs(hits) do
		-- (terrain is the ground itself; a see-through part is nothing)
		if not h:IsA("Terrain") and h.Transparency < 0.95 then
			return false
		end
	end
	return true
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.new(1, 0, 0)
end

local function rotY(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

---------------------------------------------------------------------------
-- pools
---------------------------------------------------------------------------
local PARK = CFrame.new(0, -5000, 0)
local pools: { [string]: { BasePart } } = { Fissure = {}, Slab = {}, Rock = {}, Disc = {} }
local CAPS = { Fissure = 260, Slab = 40, Rock = 90, Disc = 6 }
local counts = { Fissure = 0, Slab = 0, Rock = 0, Disc = 0 }

local function chunkTemplate(): MeshPart?
	local vfx = CombatFolder:FindFirstChild("VFX")
	local rocks = vfx and vfx:FindFirstChild("Rocks")
	local c = rocks and rocks:FindFirstChild("Chunk")
	return if c and c:IsA("MeshPart") then c else nil
end

local function makePart(kind: string): BasePart?
	if counts[kind] >= CAPS[kind] then
		return nil
	end
	counts[kind] += 1
	local p: BasePart
	if kind == "Rock" then
		local tpl = chunkTemplate()
		p = if tpl then tpl:Clone() else Instance.new("Part")
	elseif kind == "Disc" then
		local c = Instance.new("Part")
		c.Shape = Enum.PartType.Cylinder
		p = c
	else
		p = Instance.new("Part")
	end
	p.Name = "Shatter" .. kind
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = kind ~= "Fissure" and kind ~= "Disc"
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = holder()
	return p
end

local function take(kind: string): BasePart?
	local pool = pools[kind]
	local p = table.remove(pool)
	return p or makePart(kind)
end

local function give(kind: string, p: BasePart)
	p.CFrame = PARK
	table.insert(pools[kind], p)
end

---------------------------------------------------------------------------
-- motion: one heartbeat moves every piece of every live smash
---------------------------------------------------------------------------
-- a tween: from -> to over [t0, t0 + dur] with an easing ("out", "back", "in", "inout")
type Tween = { Part: BasePart, From: CFrame, To: CFrame, T0: number, Dur: number, Ease: string, Done: (() -> ())? }
-- a thrown rock: integrated flight with ground/wall contact
type Flight = { Part: BasePart, Pos: Vector3, Vel: Vector3, Spin: Vector3, Rot: CFrame, Bounces: number, Size: number, T0: number, Age: number, Done: (() -> ())? }
local tweens: { Tween } = {}
local flights: { Flight } = {}
local conn: RBXScriptConnection? = nil
local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}

local BACK = 1.4
local function ease(kind: string, x: number): number
	if kind == "back" then
		local k = x - 1
		return 1 + (BACK + 1) * k * k * k + BACK * k * k
	elseif kind == "in" then
		return x * x * x
	elseif kind == "inout" then
		return if x < 0.5 then 4 * x * x * x else 1 - (-2 * x + 2) ^ 3 / 2
	end
	return 1 - (1 - x) ^ 3 -- out
end

local function landRest(f: Flight, hit: RaycastResult)
	-- at rest on the surface it came down on: lying on its broad side, a little sunk in
	local n = hit.Normal
	local right = n:Cross(Vector3.new(0.3, 0, 1)).Unit
	local fwd = right:Cross(n).Unit
	local yaw = CFrame.Angles(0, math.random() * math.pi * 2, 0)
	f.Part.CFrame = CFrame.fromMatrix(hit.Position + n * (f.Size * 0.32), right, n, -fwd) * yaw
end

local function step(dt: number)
	dt = math.min(dt, 1 / 20)
	local now = os.clock()
	table.clear(moveParts)
	table.clear(moveCfs)
	for i = #tweens, 1, -1 do
		local tw = tweens[i]
		if not tw.Part.Parent then
			table.remove(tweens, i)
		elseif now >= tw.T0 then
			local x = math.clamp((now - tw.T0) / tw.Dur, 0, 1)
			table.insert(moveParts, tw.Part)
			table.insert(moveCfs, tw.From:Lerp(tw.To, ease(tw.Ease, x)))
			if x >= 1 then
				table.remove(tweens, i)
				if tw.Done then
					task.defer(tw.Done)
				end
			end
		end
	end
	for i = #flights, 1, -1 do
		local f = flights[i]
		if now >= f.T0 then
			f.Age += dt
			local v = f.Vel - Vector3.new(0, GRAVITY * dt, 0)
			local delta = v * dt
			local hit = workspace:Raycast(f.Pos, delta + delta.Unit * f.Size * 0.4, rayParams)
			if hit and hit.Material == Enum.Material.Water then
				-- into water: gone under
				table.remove(flights, i)
				f.Part.CFrame = PARK
				if f.Done then
					task.defer(f.Done)
				end
				continue
			elseif hit and hit.Normal.Y > 0.55 then
				if f.Bounces < 1 and v.Magnitude > 9 then
					-- one heavy bounce: most of the energy goes into the ground
					f.Bounces += 1
					local n = hit.Normal
					local vn = n * v:Dot(n)
					v = (v - vn) * 0.45 - vn * 0.28
					f.Pos = hit.Position + n * (f.Size * 0.5)
					f.Spin *= 0.5
				else
					table.remove(flights, i)
					landRest(f, hit)
					if f.Done then
						task.defer(f.Done)
					end
					continue
				end
			elseif hit then
				-- a wall: knocked back off it, falling on
				local n = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
				n = if n.Magnitude > 1e-3 then n.Unit else -flat(v)
				v = v - n * v:Dot(n) * 1.35
				f.Pos = hit.Position + n * (f.Size * 0.6)
			else
				f.Pos += delta
			end
			f.Vel = v
			f.Rot = f.Rot * CFrame.Angles(f.Spin.X * dt, f.Spin.Y * dt, f.Spin.Z * dt)
			if f.Age > 2.2 then
				-- never landed (off a ledge): gone
				table.remove(flights, i)
				f.Part.CFrame = PARK
				if f.Done then
					task.defer(f.Done)
				end
				continue
			end
			table.insert(moveParts, f.Part)
			table.insert(moveCfs, CFrame.new(f.Pos) * f.Rot)
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if #tweens == 0 and #flights == 0 and conn then
		conn:Disconnect()
		conn = nil
	end
end

local function run()
	if not conn then
		conn = RunService.Heartbeat:Connect(step)
	end
end

local function tween(part: BasePart, from: CFrame, to: CFrame, delay: number, dur: number, easeKind: string, done: (() -> ())?)
	for i = #tweens, 1, -1 do
		if tweens[i].Part == part then
			table.remove(tweens, i) -- a piece already moving is taken over from where it is
		end
	end
	table.insert(tweens, { Part = part, From = from, To = to, T0 = os.clock() + delay, Dur = math.max(dur, 1 / 60), Ease = easeKind, Done = done })
	run()
end

---------------------------------------------------------------------------
-- particles (made once; aimed and burst per smash)
---------------------------------------------------------------------------
local rig: Attachment? = nil
local E: { [string]: ParticleEmitter } = {}
local light: PointLight? = nil

local function nseq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in ipairs(points) do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
	end
	return NumberSequence.new(kps)
end

local function particles(): Attachment
	if rig and rig.Parent then
		return rig
	end
	local a = Instance.new("Attachment")
	a.Name = "ShatterParticles"
	a.Parent = workspace.Terrain
	local function em(name: string, props: any)
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Enabled = false
		e.Rate = 0
		e.LockedToPart = false
		e.EmissionDirection = Enum.NormalId.Top
		e.LightInfluence = 1
		for k, v in pairs(props) do
			(e :: any)[k] = v
		end
		e.Parent = a
		E[name] = e
	end
	-- the air squeezed out from under the foot: fast, low, stopping short
	em("Compress", {
		Texture = "rbxassetid://16669188960", FlipbookLayout = Enum.ParticleFlipbookLayout.Grid4x4,
		FlipbookMode = Enum.ParticleFlipbookMode.OneShot,
		Size = nseq({ { 0, 0.9 }, { 0.4, 2.2 }, { 1, 2.8 } }), Transparency = nseq({ { 0, 0.25 }, { 0.6, 0.5 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.35, 0.6), Speed = NumberRange.new(26, 34), Drag = 6,
		SpreadAngle = Vector2.new(6, 6), RotSpeed = NumberRange.new(-60, 60), Rotation = NumberRange.new(-180, 180),
	})
	-- dust rolling out along the ground behind the shockwave
	em("DustRing", {
		Texture = "rbxassetid://16669188960", FlipbookLayout = Enum.ParticleFlipbookLayout.Grid4x4,
		FlipbookMode = Enum.ParticleFlipbookMode.OneShot,
		Size = nseq({ { 0, 1.6 }, { 0.35, 3.6 }, { 1, 5 } }), Transparency = nseq({ { 0, 0.3 }, { 0.5, 0.55 }, { 1, 1 } }),
		Lifetime = NumberRange.new(1.0, 1.6), Speed = NumberRange.new(14, 22), Drag = 2.6,
		Acceleration = Vector3.new(0, 1.8, 0), SpreadAngle = Vector2.new(10, 10), RotSpeed = NumberRange.new(-35, 35),
		Rotation = NumberRange.new(-180, 180),
	})
	-- the cloud rising from the centre
	em("Column", {
		Texture = "rbxassetid://9171262291",
		Size = nseq({ { 0, 2.5 }, { 0.4, 6 }, { 1, 8 } }), Transparency = nseq({ { 0, 0.35 }, { 0.5, 0.6 }, { 1, 1 } }),
		Lifetime = NumberRange.new(1.4, 2.2), Speed = NumberRange.new(3, 7), Drag = 1.5,
		Acceleration = Vector3.new(0, 1.2, 0), SpreadAngle = Vector2.new(35, 35), RotSpeed = NumberRange.new(-20, 20),
		Rotation = NumberRange.new(-180, 180),
	})
	-- grit: the micro debris
	em("Grit", {
		Texture = "rbxassetid://6760190948",
		Size = nseq({ { 0, 0.22 }, { 1, 0.16 } }), Transparency = nseq({ { 0, 0 }, { 0.85, 0 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(18, 52), Drag = 0.6,
		Acceleration = Vector3.new(0, -120, 0), SpreadAngle = Vector2.new(38, 38), RotSpeed = NumberRange.new(-400, 400),
		Rotation = NumberRange.new(-180, 180),
	})
	-- the shockwave: a flat ring whose edge ends exactly on the radius
	em("Shock", {
		Texture = "rbxassetid://16950679789", Orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		Size = nseq({ { 0, 1.2 }, { 0.7, R * 2 }, { 1, R * 2.06 } }), Transparency = nseq({ { 0, 0.1 }, { 0.6, 0.35 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.34, 0.34), Speed = NumberRange.new(0.01, 0.01), LightEmission = 0.2,
		Rotation = NumberRange.new(-180, 180),
	})
	-- the first cracks, flashing out from the foot on the touchdown frame
	em("FirstCrack", {
		Texture = "rbxassetid://16937229477", Orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		Size = nseq({ { 0, 1.2 }, { 1, R * 1.1 } }), Transparency = nseq({ { 0, 0 }, { 0.7, 0.3 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.32, 0.32), Speed = NumberRange.new(0.01, 0.01), Rotation = NumberRange.new(-180, 180),
		Color = ColorSequence.new(Color3.new(0, 0, 0)),
	})
	local l = Instance.new("PointLight")
	l.Brightness = 0
	l.Range = 16
	l.Color = Color3.fromRGB(255, 238, 208)
	l.Shadows = false
	l.Parent = a
	light = l
	rig = a
	return a
end

local function frameAlong(pos: Vector3, dir: Vector3): CFrame
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	return CFrame.fromMatrix(pos, right, up, right:Cross(up).Unit)
end

local function tint(color: Color3, lighten: number): ColorSequence
	local c = color:Lerp(Color3.fromRGB(205, 196, 180), lighten)
	return ColorSequence.new(c, c:Lerp(Color3.fromRGB(170, 164, 152), 0.3))
end

---------------------------------------------------------------------------
-- sounds (CombatFX's layered voices, loaded lazily: CombatFX requires this module)
---------------------------------------------------------------------------
local function sound(name: string, pos: Vector3)
	local fx = CombatFolder:FindFirstChild("CombatFX")
	if fx and fx:IsA("ModuleScript") then
		local ok, mod = pcall(require, fx)
		if ok and mod and mod.Sound then
			mod.Sound(name, pos, 1)
		end
	end
end

---------------------------------------------------------------------------
-- the fracture
---------------------------------------------------------------------------
type Seg = { A: Vector3, B: Vector3, W: number, N: Vector3, T: number, Dist: number }

-- one fissure: a wandering, tapering line from `from` outward, forking now and then. Every point
-- sits on the ground under it; a ledge, a step, a wall or water ends it. Never past the radius.
local function grow(center: Vector3, from: Vector3, heading: Vector3, len: number, width: number, depth: number, rng: Random, out: { Seg })
	local pos = from
	local dir = heading
	local walked = 0
	while walked < len do
		local seg = rng:NextNumber(0.55, 1.0)
		dir = rotY(dir, rng:NextNumber(-0.45, 0.45))
		local radial = flat(pos - center)
		if (pos - center).Magnitude > 0.5 then
			dir = (dir * 0.72 + radial * 0.28).Unit -- a break runs outward
		end
		local nextXZ = pos + dir * seg
		local r = Vector3.new(nextXZ.X - center.X, 0, nextXZ.Z - center.Z).Magnitude
		if r > R then
			-- ends on the rim (the fissure's tip lands on the radius exactly)
			local k = math.max(0, R - Vector3.new(pos.X - center.X, 0, pos.Z - center.Z).Magnitude)
			if k < 0.15 then
				break
			end
			nextXZ = pos + dir * k
		end
		local hit = floorAt(nextXZ, pos.Y, 0.7)
		if not hit or hit.Material == Enum.Material.Water then
			break
		end
		local b = hit.Position
		if math.abs(b.Y - pos.Y) > 0.6 then
			break -- a step or a kerb between: the break stops at it
		end
		local w = width * (1 - walked / len * 0.78)
		local dist = Vector3.new(b.X - center.X, 0, b.Z - center.Z).Magnitude
		table.insert(out, { A = pos, B = b, W = w, N = hit.Normal, T = dist / CRACK_SPEED, Dist = dist })
		pos = b
		walked += seg
		if dist >= R - 0.05 then
			break
		end
		if depth < 2 and walked < len * 0.8 and rng:NextNumber() < 0.26 then
			local side = if rng:NextNumber() < 0.5 then -1 else 1
			grow(center, pos, rotY(dir, side * rng:NextNumber(0.45, 0.95)), (len - walked) * rng:NextNumber(0.35, 0.65), w * 0.62, depth + 1, rng, out)
		end
	end
end

type Slab = { Parts: { BasePart }, Final: { CFrame }, Buried: { CFrame }, Settled: { CFrame }, At: number }

local function build(ground: RaycastResult, attacker: Model?, rng: Random)
	local center = ground.Position
	local mat, col, variant = surfaceOf(ground)
	local stony = STONY[mat] == true
	local dark = col:Lerp(Color3.new(0, 0, 0), 0.82)
	local earth = if stony then col:Lerp(Color3.new(0, 0, 0), 0.3) else EARTH:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.12))

	-- the fissures: main breaks round the foot, unevenly spaced and of uneven reach
	local segs: { Seg } = {}
	local n = rng:NextInteger(6, 9)
	local spin0 = rng:NextNumber(0, math.pi * 2)
	local mains: { number } = {}
	for i = 1, n do
		local a = spin0 + (i - 1) / n * math.pi * 2 + rng:NextNumber(-0.35, 0.35) * (math.pi * 2 / n)
		table.insert(mains, a)
		local reach = if rng:NextNumber() < 0.62 then R * rng:NextNumber(0.9, 1.0) else R * rng:NextNumber(0.42, 0.75)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		-- (it starts on the ground beside the foot, wherever the ground is there)
		local start = floorAt(center + dir * 0.25, center.Y, 0.7)
		if start and start.Material ~= Enum.Material.Water then
			grow(center, start.Position, dir, reach, rng:NextNumber(0.3, 0.44), 0, rng, segs)
		end
	end
	table.sort(mains)

	-- the slabs: heaved between the main breaks, a raised rim round the sunken centre
	local slabs: { Slab } = {}
	local bodies: { Vector3 } = {}
	for _, m in ipairs(fighters(center)) do
		local root = m:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and m ~= attacker then
			table.insert(bodies, root.Position)
		end
	end
	for i = 1, #mains do
		local a0 = mains[i]
		local a1 = if i < #mains then mains[i + 1] else mains[1] + math.pi * 2
		local gap = a1 - a0
		if gap > 0.5 and rng:NextNumber() < 0.9 then
			local a = a0 + gap * rng:NextNumber(0.4, 0.6)
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local r = R * rng:NextNumber(0.28, 0.5)
			local base = floorAt(center + dir * r, center.Y, 0.8)
			if base and base.Material ~= Enum.Material.Water then
				local across = math.min(2 * r * math.sin(gap * 0.5) * 0.62, 2.8) * rng:NextNumber(0.85, 1)
				local along = rng:NextNumber(1.3, 2.1)
				local thick = rng:NextNumber(0.45, 0.7)
				local heave = math.rad(rng:NextNumber(14, 30))
				local blocked = across < 0.8
				for _, b in ipairs(bodies) do
					if (Vector3.new(b.X, 0, b.Z) - Vector3.new(base.Position.X, 0, base.Position.Z)).Magnitude < along * 0.5 + FIGHTER_GAP then
						blocked = true
					end
				end
				local nrm = base.Normal
				-- a frame on the surface facing out from the foot, its outer edge lifted
				local out = (dir - nrm * dir:Dot(nrm)).Unit
				local right = out:Cross(nrm).Unit
				local surf = CFrame.fromMatrix(base.Position, right, nrm, -out)
				local tilted = surf * CFrame.Angles(-heave, math.rad(rng:NextNumber(-10, 10)), 0)
				if not blocked and openBox(tilted * CFrame.new(0, 0.9, 0), Vector3.new(across, 1.2, along)) then
					local top = take("Slab")
					local under = take("Slab")
					if top and under then
						top.Material = mat
						top.MaterialVariant = variant
						top.Color = col
						top.Size = Vector3.new(across, 0.22, along)
						under.Material = if stony then mat else Enum.Material.Ground
						under.MaterialVariant = if stony then variant else ""
						under.Color = earth
						under.Size = Vector3.new(across * 0.99, thick, along * 0.99)
						local lift = math.sin(heave) * along * 0.5 * 0.55
						local topF = tilted * CFrame.new(0, lift + 0.02, 0)
						local underF = topF * CFrame.new(0, -(0.22 + thick) * 0.5 + 0.03, 0)
						local sink = nrm * (thick + lift + 0.35)
						local settledTop = surf * CFrame.Angles(-heave * 0.8, 0, 0) * CFrame.new(0, lift * 0.85 + 0.02, 0)
						table.insert(slabs, {
							Parts = { top, under },
							Final = { topF, underF },
							Buried = { topF - sink, underF - sink },
							Settled = { settledTop, settledTop * CFrame.new(0, -(0.22 + thick) * 0.5 + 0.03, 0) },
							At = 0.02 + r / CRACK_SPEED,
						})
					else
						if top then
							give("Slab", top)
						end
						if under then
							give("Slab", under)
						end
					end
				end
			end
		end
	end
	return segs, slabs, mat, col, variant, dark, stony, earth
end

---------------------------------------------------------------------------
-- live smashes (a new one clears any old one it would overlap)
---------------------------------------------------------------------------
type Live = { Center: Vector3, Clear: (boolean) -> () }
local live: { Live } = {}

local function clearNear(center: Vector3)
	for i = #live, 1, -1 do
		local l = live[i]
		if (l.Center - center).Magnitude < R * 2.2 then
			table.remove(live, i)
			l.Clear(true)
		end
	end
end

---------------------------------------------------------------------------
-- the touchdown
---------------------------------------------------------------------------
function Shatter.Play(pos: Vector3, attacker: Model?)
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - pos).Magnitude > VIEW then
		return
	end
	setIgnore(pos)
	local ground = floorAt(pos, pos.Y, 3)
	sound("Slam", pos)
	sound("SlamSub", pos)
	if not ground then
		return
	end
	clearNear(ground.Position)
	local rng = Random.new()
	local center = ground.Position
	local nrm = ground.Normal
	local water = ground.Material == Enum.Material.Water
	local _, col = surfaceOf(ground)
	local a = particles()
	local groundFrame = frameAlong(center + nrm * 0.15, nrm)

	-- IMPACT: the flash, the air squeezed out, the first cracks
	a.CFrame = frameAlong(center + nrm * 1.4, nrm)
	local l = light :: PointLight
	l.Brightness = 3.2
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 0.2 do
			l.Brightness = 3.2 * (1 - (os.clock() - t0) / 0.2)
			RunService.Heartbeat:Wait()
		end
		l.Brightness = 0
	end)
	E.Compress.Color = tint(col, if water then 0.8 else 0.45)
	for i = 1, 14 do
		local d = rotY(Vector3.new(1, 0, 0), i / 14 * math.pi * 2 + rng:NextNumber(-0.1, 0.1))
		local out = (d + nrm * 0.12).Unit
		a.CFrame = frameAlong(center + nrm * 0.45 + d * 0.5, out)
		E.Compress:Emit(1)
	end
	if not water then
		a.CFrame = groundFrame
		E.FirstCrack:Emit(2)
	end
	if water then
		-- (water can't break: just the burst of spray and the shock across it)
		task.delay(0.05, function()
			a.CFrame = groundFrame
			E.Shock:Emit(1)
			E.DustRing.Color = tint(Color3.fromRGB(220, 235, 245), 0.2)
			for i = 1, 12 do
				local d = rotY(Vector3.new(1, 0, 0), i / 12 * math.pi * 2)
				a.CFrame = frameAlong(center + d * 0.8 + nrm * 0.4, (d + nrm * 0.3).Unit)
				E.DustRing:Emit(1)
			end
		end)
		return
	end

	local segs, slabs, mat, colr, variant, dark, stony, earth = build(ground, attacker, rng)
	local placed: { { Part: BasePart, Final: CFrame, Sunk: CFrame, Dist: number } } = {}

	-- FRACTURE: every segment appears when the break reaches it
	for _, sg in ipairs(segs) do
		local p = take("Fissure")
		if not p then
			break
		end
		local len = (sg.B - sg.A).Magnitude
		if len > 0.05 then
			p.Material = Enum.Material.SmoothPlastic
			p.Color = dark
			p.Size = Vector3.new(sg.W, 0.05, len + sg.W * 0.6)
			local mid = (sg.A + sg.B) * 0.5 + sg.N * 0.018
			local cf = CFrame.lookAt(mid, mid + (sg.B - sg.A).Unit, sg.N)
			local sunk = cf - sg.N * 0.2
			p.CFrame = PARK
			tween(p, sunk, cf, sg.T, 0.05, "out")
			table.insert(placed, { Part = p, Final = cf, Sunk = sunk, Dist = sg.Dist })
		else
			give("Fissure", p)
		end
	end
	-- the crushed centre under the foot
	local disc = take("Disc")
	if disc then
		disc.Material = Enum.Material.SmoothPlastic
		disc.Color = dark:Lerp(colr, 0.25)
		disc.Transparency = 0.25
		disc.Size = Vector3.new(0.04, 2.6, 2.6)
		local dcf = CFrame.fromMatrix(center + nrm * 0.016, nrm, nrm:Cross(Vector3.new(0.2, 0, 1)).Unit)
		disc.CFrame = dcf
	end
	sound("SlamCrack", center)

	-- DEBRIS BURST: slabs heave, rocks fly, grit sprays
	for _, s in ipairs(slabs) do
		for k, p in ipairs(s.Parts) do
			p.CFrame = s.Buried[k]
			tween(p, s.Buried[k], s.Final[k], s.At + (k - 1) * 0.01, 0.13, "back", function()
				-- ROCK SETTLE: the slab sags back a little as it settles
				tween(p, s.Final[k], s.Settled[k], 0.08, 0.9, "inout")
			end)
		end
	end
	local rocks: { BasePart } = {}
	local roots: { Vector3 } = {}
	for _, m in ipairs(fighters(center)) do
		local root = m:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and m ~= attacker then
			table.insert(roots, root.Position)
		end
	end
	local function clearFlight(from: Vector3, dir: Vector3): boolean
		for _, q in ipairs(roots) do
			local rel = Vector3.new(q.X - from.X, 0, q.Z - from.Z)
			local along = rel:Dot(dir)
			if along > 0 and along < R * 1.6 and (rel - dir * along).Magnitude < 1.6 and math.abs(q.Y - from.Y) < 7 then
				return false
			end
		end
		return true
	end
	local function throw(size: number, out: { number }, up: { number }, turf: boolean)
		local p = take("Rock")
		if not p then
			return
		end
		local a0 = rng:NextNumber(0, math.pi * 2)
		local dir = Vector3.new(math.cos(a0), 0, math.sin(a0))
		if not clearFlight(center, dir) then
			give("Rock", p)
			return
		end
		p.Size = Vector3.new(size * rng:NextNumber(1.0, 1.35), size * rng:NextNumber(0.6, 0.85), size * rng:NextNumber(0.85, 1.15))
		if turf then
			p.Material = mat
			p.MaterialVariant = variant
			p.Color = colr:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.12))
		else
			p.Material = if stony then mat else Enum.Material.Slate
			p.MaterialVariant = if stony then variant else ""
			p.Color = if stony then colr:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0.05, 0.2)) else earth:Lerp(Color3.fromRGB(112, 108, 102), 0.55)
		end
		local from = center + dir * rng:NextNumber(0.5, 1.6) + nrm * (size * 0.6)
		table.insert(rocks, p)
		table.insert(flights, {
			Part = p,
			Pos = from,
			Vel = dir * rng:NextNumber(out[1], out[2]) + Vector3.new(0, rng:NextNumber(up[1], up[2]), 0),
			Spin = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * (18 / size),
			Rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)),
			Bounces = 0,
			Size = size,
			T0 = os.clock() + rng:NextNumber(0.02, 0.1),
			Age = 0,
		})
	end
	for _ = 1, rng:NextInteger(6, 9) do
		throw(rng:NextNumber(0.6, 1.05), { 5, 12 }, { 16, 26 }, rng:NextNumber() < 0.5) -- medium: heavy arcs
	end
	for _ = 1, rng:NextInteger(10, 15) do
		throw(rng:NextNumber(0.25, 0.48), { 9, 19 }, { 18, 32 }, rng:NextNumber() < 0.4) -- small: faster, further
	end
	run()
	E.Grit.Color = ColorSequence.new(colr:Lerp(Color3.new(0, 0, 0), 0.25))
	a.CFrame = frameAlong(center + nrm * 0.4, nrm)
	E.Grit:Emit(26)
	sound("SlamDebris", center)

	-- SHOCKWAVE + DUST: the ring runs out to the radius, the dust rolls out behind it and rises
	task.delay(0.05, function()
		a.CFrame = groundFrame
		E.Shock:Emit(1)
		E.DustRing.Color = tint(colr, 0.55)
		for i = 1, 16 do
			local d = rotY(Vector3.new(1, 0, 0), i / 16 * math.pi * 2 + rng:NextNumber(-0.12, 0.12))
			a.CFrame = frameAlong(center + d * 0.9 + nrm * 0.5, (d + nrm * 0.18).Unit)
			E.DustRing:Emit(1)
		end
		E.Column.Color = tint(colr, 0.6)
		a.CFrame = frameAlong(center + nrm * 1, nrm)
		E.Column:Emit(5)
	end)
	task.delay(0.55, function()
		sound("SlamSettle", center)
	end)

	-- HOLD, then the SMOOTH FADE (or all at once when a new smash lands on it)
	local done = false
	local function finish(fast: boolean)
		if done then
			return
		end
		done = true
		local speed = if fast then 0.25 else 1
		-- rocks sink first
		for _, p in ipairs(rocks) do
			for i = #flights, 1, -1 do
				if flights[i].Part == p then
					table.remove(flights, i)
				end
			end
			local cf = p.CFrame
			if cf.Position.Y < -4000 then
				give("Rock", p)
			else
				tween(p, cf, cf - Vector3.new(0, p.Size.Y * 1.2, 0), rng:NextNumber(0, 0.25) * speed, 0.55 * speed, "in", function()
					give("Rock", p)
				end)
			end
		end
		-- the slabs sink back the way they came
		for _, s in ipairs(slabs) do
			for k, p in ipairs(s.Parts) do
				tween(p, p.CFrame, s.Buried[k], (0.2 + rng:NextNumber(0, 0.15)) * speed, 0.75 * speed, "inout", function()
					give("Slab", p)
				end)
			end
		end
		-- the fissures close from the rim inward
		for _, f in ipairs(placed) do
			tween(f.Part, f.Final, f.Sunk, (0.35 + (1 - f.Dist / R) * 0.35) * speed, 0.3 * speed, "in", function()
				give("Fissure", f.Part)
			end)
		end
		if disc then
			tween(disc, disc.CFrame, disc.CFrame - nrm * 0.1, 0.7 * speed, 0.3 * speed, "in", function()
				give("Disc", disc)
			end)
		end
	end
	local entry: Live = { Center = center, Clear = finish }
	table.insert(live, entry)
	task.delay(HOLD, function()
		local i = table.find(live, entry)
		if i then
			table.remove(live, i)
		end
		finish(false)
	end)
end

---------------------------------------------------------------------------
-- the drop
---------------------------------------------------------------------------
function Shatter.Descent(char: Model, _height: number?): any
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso") or root
	if not (root and root:IsA("BasePart") and torso and torso:IsA("BasePart")) then
		return { Stop = function() end }
	end
	local made: { Instance } = {}
	local a = Instance.new("Attachment")
	a.Name = "SmashDescent"
	a.Parent = root
	table.insert(made, a)
	-- speed lines streaming up past the body
	local lines = Instance.new("ParticleEmitter")
	lines.Texture = "rbxassetid://7216979807"
	lines.Orientation = Enum.ParticleOrientation.VelocityParallel
	lines.EmissionDirection = Enum.NormalId.Top
	lines.Rate = 55
	lines.Lifetime = NumberRange.new(0.08, 0.14)
	lines.Speed = NumberRange.new(55, 85)
	lines.SpreadAngle = Vector2.new(6, 6)
	lines.Size = nseq({ { 0, 0 }, { 0.3, 2.6 }, { 1, 0 } })
	lines.Transparency = nseq({ { 0, 0.55 }, { 1, 1 } })
	lines.LightEmission = 0.3
	lines.LockedToPart = false
	lines.Parent = a
	-- the air pressing up under the feet (grows as the ground comes up)
	local feet = Instance.new("Attachment")
	feet.Name = "SmashDescentFeet"
	feet.Position = Vector3.new(0, -3.2, 0)
	feet.Parent = root
	table.insert(made, feet)
	local cushion = Instance.new("ParticleEmitter")
	cushion.Texture = "rbxassetid://10337713824"
	cushion.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
	cushion.EmissionDirection = Enum.NormalId.Top
	cushion.Rate = 16
	cushion.Lifetime = NumberRange.new(0.12, 0.18)
	cushion.Speed = NumberRange.new(0.5, 1)
	cushion.Size = nseq({ { 0, 1 }, { 1, 3.4 } })
	cushion.Transparency = nseq({ { 0, 0.72 }, { 1, 1 } })
	cushion.LockedToPart = true
	cushion.RotSpeed = NumberRange.new(-200, 200)
	cushion.Rotation = NumberRange.new(-180, 180)
	cushion.Parent = feet
	-- a faint trail down the body
	local t0 = Instance.new("Attachment")
	t0.Position = Vector3.new(0, 0.9, 0)
	t0.Parent = torso
	local t1 = Instance.new("Attachment")
	t1.Position = Vector3.new(0, -0.9, 0)
	t1.Parent = torso
	table.insert(made, t0)
	table.insert(made, t1)
	local trail = Instance.new("Trail")
	trail.Attachment0 = t0
	trail.Attachment1 = t1
	trail.Lifetime = 0.14
	trail.FaceCamera = true
	trail.LightEmission = 0.25
	trail.Transparency = nseq({ { 0, 0.75 }, { 1, 1 } })
	trail.Color = ColorSequence.new(Color3.fromRGB(235, 235, 240))
	trail.Parent = torso
	table.insert(made, trail)
	sound("SlamDescent", root.Position)
	local stopped = false
	local function stop()
		if stopped then
			return
		end
		stopped = true
		lines.Enabled = false
		cushion.Enabled = false
		trail.Enabled = false
		task.delay(0.3, function()
			for _, inst in ipairs(made) do
				inst:Destroy()
			end
		end)
	end
	task.delay(2, stop) -- never outlives a fall
	return { Stop = stop }
end

-- the finished fracture standing still, for looking at in Studio (no fighters, no animation)
function Shatter.Preview(ground: Vector3, _parent: Instance?, seed: number?): number
	setIgnore(ground)
	local hit = floorAt(ground, ground.Y, 3)
	if not hit then
		return 0
	end
	local segs, slabs = build(hit, nil, Random.new(seed or 1))
	for _, sg in ipairs(segs) do
		local p = take("Fissure")
		if p then
			local len = (sg.B - sg.A).Magnitude
			p.Color = Color3.new(0.1, 0.08, 0.06)
			p.Size = Vector3.new(sg.W, 0.05, len + sg.W * 0.6)
			local mid = (sg.A + sg.B) * 0.5 + sg.N * 0.018
			p.CFrame = CFrame.lookAt(mid, mid + (sg.B - sg.A).Unit, sg.N)
		end
	end
	for _, s in ipairs(slabs) do
		for k, p in ipairs(s.Parts) do
			p.CFrame = s.Final[k]
		end
	end
	return #segs
end

return Shatter
