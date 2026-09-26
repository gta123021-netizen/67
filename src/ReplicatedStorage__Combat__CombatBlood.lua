--[[
	CombatBlood  (ReplicatedStorage.Combat.CombatBlood)
	Blood for a clean blow - client-side and cosmetic (every client builds its own from the "Hit"
	it hears, or the attacker from its own impact frame).

	  Blood.Spray(pos, drive, tier, victim?, dirSign?)
	      pos = the contact point on the body, drive = the way the blow travels (flat), dirSign = the
	      way it drove the head (+1 = to the victim's right). What comes off the body:
	        droplets   small wet ellipsoids on true ballistic paths. Each one leaves the WOUND SURFACE
	                   in a splash crown (outward, at a shallow angle to the surface, all round the
	                   wound: Config.Blood Crown) carrying the struck part's own motion - back with a
	                   straight, sideways with a hook, up with an uppercut - so none ever flies back
	                   into the body it came from
	        mist, streaks, blobs   particle bursts along the same mean path. They are cut short so they
	                   fade out before they could reach the floor or a wall: particles never pass
	                   through anything; the landing is the droplets' job
	  Blood.Pool(char)   a knocked-out body bleeds a pool that spreads under it
	  Blood.Clear()      everything gone at once

	THE PHYSICS. A droplet obeys  dv/dt = -k v + g  (air drag k, the world's gravity g), integrated
	EXACTLY:
	  v(t) = g/k + (v0 - g/k) e^(-k t)      x(t) = x0 + (g/k) t + (v0 - g/k)(1 - e^(-k t)) / k
	in substeps of at most 1/120 s, each tested for contact by a ray along its chord (the arc bends
	less than a thousandth of a stud inside one), so the flight and the landing spot are the same at
	any frame rate and a fast drop can't skip through a thin wall. Where a drop meets something solid -
	floor, slope, step, wall, ceiling, terrain - it leaves a splatter flat on that surface, stretched
	the way it was travelling (a grazing drop smears, a straight-down one is round) and sized by the
	drop's size and speed; a fast one throws a couple of tiny satellite drops beside it. Water swallows
	it. See-through things (glass, triggers, force fields) and non-colliding decorations don't catch
	blood; fighters don't either (it falls past them).

	Splatters fit the ground they land on: their corners are probed first; one that would hang over a
	ledge or float over (or sink into) a bump shrinks until it fits, or isn't laid. They darken as they
	dry, then fade and are reused (Config.Blood.Splat: Hold, Fade, Cap - at the cap the oldest one is
	taken). Nothing here collides, catches a ray or touches anything: anchored, CanCollide / CanQuery /
	CanTouch off, all pooled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Blood = {}

local B = Config.Blood
local SPLAT_TEXTURE = "rbxassetid://10189639437" -- (blood kit: pooling blood, a flat spread of blood)
local MIST_TEXTURE = "rbxassetid://271522063" -- fine droplets
local STREAK_TEXTURE = "rbxassetid://4509687978" -- elongated streaks
local BLOB_TEXTURE = "rbxassetid://241576804" -- thick blobs
local MAX_DROPS = 72
local DROP_LIFE = 2.5 -- a drop that has met nothing by then (off a cliff) is gone
local SUBSTEP = 1 / 120
local LN2 = math.log(2)

local GRAVITY: number = B.Gravity or workspace.Gravity
local G = Vector3.new(0, -GRAVITY, 0)
local K = B.Drag
local TERMINAL = G / K -- the velocity drag and gravity balance at
Blood.Gravity = GRAVITY

Blood.Stats = { Drops = 0, Landed = 0, Splats = 0, Lost = 0, Water = 0, Satellites = 0 }

---------------------------------------------------------------------------
-- the exact flight: position and velocity after `h` seconds from (x, v)
---------------------------------------------------------------------------
local function advance(x: Vector3, v: Vector3, h: number): (Vector3, Vector3)
	local e = math.exp(-K * h)
	local rel = v - TERMINAL
	return x + TERMINAL * h + rel * ((1 - e) / K), TERMINAL + rel * e
end
Blood.Advance = advance

---------------------------------------------------------------------------
-- holders + filters
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
local function refreshFilter(force: boolean?)
	local t = os.clock()
	if not force and t - filterAt < 0.25 then
		return
	end
	filterAt = t
	local list: { Instance } = { holder() }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, name in ipairs({ "PracticeDummies", "CombatFX", "CombatShatter", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

-- a ray that only stops on something solid-looking (a see-through trigger, glass, a force field
-- never catches blood: the drop carries on through it)
local function castSolid(from: Vector3, delta: Vector3): RaycastResult?
	local origin = from
	local left = delta
	for _ = 1, 5 do
		local hit = workspace:Raycast(origin, left, rayParams)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		local see = inst:IsA("BasePart") and not inst:IsA("Terrain") and (inst.Transparency >= 0.85 or inst.Material == Enum.Material.ForceField)
		if not see then
			return hit
		end
		local travelled = (hit.Position - origin).Magnitude + 0.02
		if travelled >= left.Magnitude then
			return nil
		end
		origin = origin + left.Unit * travelled
		left = left.Unit * (left.Magnitude - travelled)
	end
	return nil
end
Blood.CastSolid = castSolid

---------------------------------------------------------------------------
-- the spray's particles: one set of emitters, aimed and burst per blow
---------------------------------------------------------------------------
local emitters: { [string]: ParticleEmitter } = {}
local sprayAtt: Attachment? = nil

local function seqN(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in ipairs(points) do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
	end
	return NumberSequence.new(kps)
end

-- the base lifetimes and speeds of each particle kind (cut per burst to what the space allows)
local KINDS = {
	Mist = { Life = { 0.25, 0.55 }, Speed = { 6, 15 } },
	Streaks = { Life = { 0.2, 0.42 }, Speed = { 9, 20 } },
	Blobs = { Life = { 0.3, 0.5 }, Speed = { 3, 7 } },
}

local function sprayRig(): Attachment
	if sprayAtt and sprayAtt.Parent then
		return sprayAtt
	end
	local a = Instance.new("Attachment")
	a.Name = "BloodSpray"
	a.Parent = workspace.Terrain
	local color = ColorSequence.new(B.Color, B.Dry)
	-- particles fall exactly like the droplets: the same gravity, the same drag (a ParticleEmitter's
	-- Drag is the rate at which it loses HALF its speed, so the same decay is k / ln 2)
	local drag = K / LN2
	local function emitter(name: string, props: any): ParticleEmitter
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Enabled = false
		e.Rate = 0
		e.LockedToPart = false
		e.EmissionDirection = Enum.NormalId.Top
		e.Color = color
		e.LightEmission = 0
		e.LightInfluence = 1
		e.Acceleration = G
		e.Drag = drag
		for k, v in pairs(props) do
			(e :: any)[k] = v
		end
		e.Parent = a
		emitters[name] = e
		return e
	end
	emitter("Mist", {
		Texture = MIST_TEXTURE, Orientation = Enum.ParticleOrientation.VelocityParallel,
		Size = seqN({ { 0, 0.09, 0.03 }, { 1, 0 } }), Squash = seqN({ { 0, 0 }, { 0.25, -0.5 }, { 1, 0 } }),
		Transparency = seqN({ { 0, 0.05 }, { 0.6, 0.25 }, { 1, 1 } }),
		Rotation = NumberRange.new(0, 0), ZOffset = 0.2,
		-- (a fine mist slows more in the air than a drop)
		Drag = K * 2.5 / LN2,
	})
	emitter("Streaks", {
		Texture = STREAK_TEXTURE, Orientation = Enum.ParticleOrientation.VelocityParallel,
		Size = seqN({ { 0, 0.14, 0.04 }, { 1, 0.3, 0.06 } }), Squash = seqN({ { 0, 0 }, { 1, -2.2 } }),
		Transparency = seqN({ { 0, 0 }, { 0.7, 0.2 }, { 1, 1 } }), ZOffset = 0.3,
	})
	emitter("Blobs", {
		Texture = BLOB_TEXTURE, Orientation = Enum.ParticleOrientation.FacingCamera,
		Size = seqN({ { 0, 0.2, 0.06 }, { 0.3, 0.5, 0.12 }, { 1, 0.7, 0.1 } }),
		Transparency = seqN({ { 0, 0.1 }, { 0.5, 0.3 }, { 1, 1 } }),
		Rotation = NumberRange.new(-180, 180), RotSpeed = NumberRange.new(-60, 60), ZOffset = 0.25,
	})
	sprayAtt = a
	return a
end

-- a frame at `pos` whose +Y is `dir` (the emitters throw along +Y)
local function along(pos: Vector3, dir: Vector3): CFrame
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	return CFrame.fromMatrix(pos, right, up, right:Cross(up).Unit)
end

--[[ how long a particle thrown from `pos` along a cone round `dir` (half-angle `spread` deg) at up
	to `speed` can live before ANY of them could meet a surface. The particles move exactly like the
	droplets (the same gravity and drag), so their real curved paths - down the cone's axis and all
	round its rim - are traced through the world in short chords; the soonest contact wins. ]]
function Blood.ParticleClearance(pos: Vector3, dir: Vector3, spread: number, speed: number): number
	refreshFilter()
	local LIFE = 0.6
	local STEP = 0.05
	local d = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = d:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local fwd = right:Cross(d).Unit
	local soonest = LIFE
	local a = math.rad(spread)
	local dirs = { d }
	for i = 0, 7 do
		local b = i / 8 * math.pi * 2
		table.insert(dirs, (d * math.cos(a) + (right * math.cos(b) + fwd * math.sin(b)) * math.sin(a)).Unit)
	end
	for _, u in ipairs(dirs) do
		local x, v = pos, u * speed
		local t = 0
		while t < soonest do
			local h = math.min(STEP, soonest - t)
			local x1, v1 = advance(x, v, h)
			local hit = castSolid(x, x1 - x)
			if hit then
				local f = (hit.Position - x).Magnitude / math.max((x1 - x).Magnitude, 1e-6)
				soonest = math.min(soonest, t + h * f)
				break
			end
			x, v, t = x1, v1, t + h
		end
	end
	return math.max(0.02, soonest * 0.85)
end

---------------------------------------------------------------------------
-- splatters (pooled flat parts with the blood decal on top)
---------------------------------------------------------------------------
type Splat = { Part: Part, Decal: Decal, Serial: number, Born: number, Busy: boolean }
local splats: { Splat } = {}
Blood.Splats = splats
local splatLayer = 0

local PARK = CFrame.new(0, -5000, 0)
local THICK = 0.02 -- a splat part's thickness: its decal (top face) sits THICK / 2 over its centre

local function newSplat(): Splat
	local p = Instance.new("Part")
	p.Name = "BloodSplat"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(1, THICK, 1)
	p.CFrame = PARK
	p.Parent = holder()
	local d = Instance.new("Decal")
	d.Face = Enum.NormalId.Top
	d.Texture = SPLAT_TEXTURE
	d.Color3 = B.Color
	d.Transparency = 1
	d.Parent = p
	local s = { Part = p, Decal = d, Serial = 0, Born = 0, Busy = false }
	table.insert(splats, s)
	return s
end

local function takeSplat(): Splat
	local oldest: Splat? = nil
	for _, s in ipairs(splats) do
		if not s.Busy then
			return s
		end
		if not oldest or s.Born < oldest.Born then
			oldest = s
		end
	end
	if #splats < B.Splat.Cap then
		return newSplat()
	end
	return oldest :: Splat -- at the cap the oldest is reused (a new drop never waits)
end

-- how far the surface under a spot is from the plane through `center` with normal `n` (nil: no
-- surface there - a ledge, a hole, the edge of a wall)
local function surfaceOffset(center: Vector3, n: Vector3, spot: Vector3): number?
	local hit = castSolid(spot + n * 0.5, -n * 1.0)
	if not hit then
		return nil
	end
	return (hit.Position - center):Dot(n)
end

local FIT_SPREAD = 0.06 -- the surface under one splat may rise and fall this much at most
local GRID = 4 -- probes: a (GRID + 1) x (GRID + 1) grid over the splat
--[[ the largest size (<= want) at which a splat lies flat on this surface, and how high above the
	contact its plane must sit to clear the highest point under it. The surface is probed on a grid
	over the whole splat (corners, edges, inside); a splat that would hang over an edge (no surface
	under a probe) or whose surface varies more than FIT_SPREAD (it would float over the low side)
	shrinks until it fits, or isn't laid ]]
local function fitSize(center: Vector3, n: Vector3, right: Vector3, fwd: Vector3, want: number, stretch: number): (number?, number)
	local size = want
	for _ = 1, 5 do
		local ok = true
		local hi, lo = 0, 0
		local hx, hz = size * 0.5, size * stretch * 0.5
		for i = 0, GRID do
			for j = 0, GRID do
				local off = surfaceOffset(center, n, center + right * ((i / GRID * 2 - 1) * hx) + fwd * ((j / GRID * 2 - 1) * hz))
				if not off then
					ok = false
					break
				end
				hi = math.max(hi, off)
				lo = math.min(lo, off)
				if hi - lo > FIT_SPREAD then
					ok = false
					break
				end
			end
			if not ok then
				break
			end
		end
		if ok then
			return size, hi
		end
		size *= 0.62
		if size < B.Splat.Min * 0.5 then
			return nil, 0
		end
	end
	return nil, 0
end
Blood.FitSize = fitSize

-- lay a splatter where a drop landed. travel = the drop's velocity at contact
local function laySplat(hit: RaycastResult, travel: Vector3, size: number, quiet: boolean?): Splat?
	if hit.Material == Enum.Material.Water then
		Blood.Stats.Water += 1
		return nil
	end
	local n = hit.Normal
	-- stretched along the travel projected on the surface (a drop landing at a shallow angle smears)
	local tang = travel - n * travel:Dot(n)
	local speed = travel.Magnitude
	local fwd: Vector3
	if tang.Magnitude > 0.5 then
		fwd = tang.Unit
	else
		local ref = if math.abs(n.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		fwd = n:Cross(ref).Unit
	end
	local right = fwd:Cross(n).Unit
	fwd = n:Cross(right).Unit
	-- the stain's shape (bloodstain analysis): width / length = sin(impact angle), so a drop coming
	-- straight down lands round and a grazing one smears long along its travel
	local sinA = if speed > 0.1 then math.abs(travel.Unit:Dot(n)) else 1
	local stretch = math.clamp(1 / math.max(sinA, 1e-3), 1, 3.5)
	if stretch < 1.25 then
		-- a round stain turns any way (its texture never repeats the same angle)
		local a = math.random() * math.pi * 2
		local r2 = right * math.cos(a) + fwd * math.sin(a)
		fwd = n:Cross(r2).Unit
		right = r2
	end
	local want = math.clamp(size, B.Splat.Min, B.Splat.Max)
	local fit, rise = fitSize(hit.Position, n, right, fwd, want, stretch)
	if not fit then
		return nil
	end
	local s = takeSplat()
	s.Serial += 1
	local serial = s.Serial
	s.Busy = true
	s.Born = os.clock()
	splatLayer = (splatLayer + 1) % 8
	-- the decal (the part's top face) clears the highest point under it by a hair; overlapping
	-- splats sit at slightly different heights so they never z-fight
	local lift = rise + 0.006 + splatLayer * 0.0012
	local cf = CFrame.fromMatrix(hit.Position + n * lift, right, n, -fwd)
	local p, d = s.Part, s.Decal
	local full = Vector3.new(fit, THICK, fit * stretch)
	p.Size = full * 0.45
	p.CFrame = cf
	d.Color3 = B.Color
	d.Transparency = 0.08
	Blood.Stats.Splats += 1
	-- the drop spreads as it lands, then dries darker, then fades
	TweenService:Create(p, TweenInfo.new(0.16 + fit * 0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = full }):Play()
	TweenService:Create(d, TweenInfo.new(B.Splat.Hold, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Color3 = B.Dry }):Play()
	if not quiet and math.random() < 0.3 then
		local sounds = Blood.SoundHook
		if sounds then
			sounds("Splat", hit.Position)
		end
	end
	task.delay(B.Splat.Hold, function()
		if s.Serial ~= serial then
			return
		end
		TweenService:Create(d, TweenInfo.new(B.Splat.Fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		task.delay(B.Splat.Fade + 0.05, function()
			if s.Serial == serial then
				s.Busy = false
				p.CFrame = PARK
			end
		end)
	end)
	return s
end
Blood.LaySplat = laySplat

---------------------------------------------------------------------------
-- droplets: pooled wet ellipsoids on exact ballistic paths, all moved in one heartbeat
---------------------------------------------------------------------------
type Drop = { Part: Part, Pos: Vector3, Vel: Vector3, Size: number, Age: number, Live: boolean, Satellite: boolean }
local drops: { Drop } = {}
Blood.Drops = drops
local stepConn: RBXScriptConnection? = nil

local function newDrop(): Drop
	local p = Instance.new("Part")
	p.Name = "BloodDrop"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = 0.12
	p.Color = B.Color
	p.Size = Vector3.new(0.14, 0.14, 0.2)
	p.CFrame = PARK
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = holder()
	local d = { Part = p, Pos = Vector3.zero, Vel = Vector3.zero, Size = 0.14, Age = 0, Live = false, Satellite = false }
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
	return nil
end

local launch: (Vector3, Vector3, number, boolean?) -> ()

-- a drop met a surface: its splat, and (fast ones) a couple of satellites thrown off along it
local function land(d: Drop, hit: RaycastResult, v: Vector3)
	Blood.Stats.Landed += 1
	local speed = v.Magnitude
	laySplat(hit, v, d.Size * (4.2 + math.min(speed, 30) * 0.035), d.Satellite)
	if not d.Satellite and speed > 16 and hit.Material ~= Enum.Material.Water then
		local n = hit.Normal
		local tang = v - n * v:Dot(n)
		if tang.Magnitude > 1 then
			for _ = 1, 2 do
				local side = n:Cross(tang.Unit) * (math.random() - 0.5) * 0.8
				local out = (tang.Unit + side).Unit * tang.Magnitude * 0.25 + n * (2 + math.random() * 2)
				Blood.Stats.Satellites += 1
				launch(hit.Position + n * 0.06, out, d.Size * 0.45, true)
			end
		end
	end
end

local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}

-- advance one drop by `dt`, in substeps; returns true while it is still flying
local function fly(d: Drop, dt: number): boolean
	local left = dt
	while left > 1e-6 do
		local h = math.min(SUBSTEP, left)
		left -= h
		local x1, v1 = advance(d.Pos, d.Vel, h)
		local delta = x1 - d.Pos
		local hit = if delta.Magnitude > 1e-5 then castSolid(d.Pos, delta) else nil
		if hit then
			-- the velocity at the moment of contact (the fraction of the chord it got through)
			local f = math.clamp((hit.Position - d.Pos).Magnitude / delta.Magnitude, 0, 1)
			local _, vHit = advance(d.Pos, d.Vel, h * f)
			d.Pos = hit.Position
			d.Live = false
			land(d, hit, vHit)
			return false
		end
		d.Pos, d.Vel = x1, v1
		d.Age += h
		if d.Age > DROP_LIFE then
			d.Live = false
			Blood.Stats.Lost += 1
			return false
		end
	end
	return true
end
Blood.Fly = fly

local function step(dt: number)
	dt = math.min(dt, 0.1) -- (a long hitch is caught up in substeps, up to a tenth of a second)
	table.clear(moveParts)
	table.clear(moveCfs)
	local any = false
	refreshFilter()
	for _, d in ipairs(drops) do
		if d.Live then
			any = true
			if fly(d, dt) then
				local v = d.Vel
				local len = 1 + math.min(v.Magnitude, 40) * 0.03
				d.Part.Size = Vector3.new(d.Size, d.Size, d.Size * len)
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, CFrame.lookAt(d.Pos, d.Pos + (if v.Magnitude > 0.1 then v else Vector3.yAxis)))
			else
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, PARK)
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
Blood.Step = step

launch = function(pos: Vector3, vel: Vector3, size: number, satellite: boolean?)
	local d = takeDrop()
	if not d then
		return
	end
	Blood.Stats.Drops += 1
	d.Live = true
	d.Age = 0
	d.Pos = pos
	d.Vel = vel
	d.Size = size
	d.Satellite = satellite == true
	d.Part.Color = B.Color
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
end
Blood.Launch = function(pos: Vector3, vel: Vector3, size: number)
	launch(pos, vel, size)
end

-- one drop's ejection off the wound: a random direction round the outward normal, between the
-- tier's Crown angles from it (a splash leaves at a shallow angle to the surface), at its Eject speed
function Blood.Crown(normal: Vector3, tier: any): Vector3
	local up = normal.Unit
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local fwd = right:Cross(up).Unit
	local a = math.rad(tier.Crown[1] + math.random() * (tier.Crown[2] - tier.Crown[1]))
	local b = math.random() * math.pi * 2
	local dir = up * math.cos(a) + (right * math.cos(b) + fwd * math.sin(b)) * math.sin(a)
	return dir * (tier.Eject[1] + math.random() * (tier.Eject[2] - tier.Eject[1]))
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

local function inView(pos: Vector3): boolean
	local cam = workspace.CurrentCamera
	return cam == nil or (cam.CFrame.Position - pos).Magnitude <= B.View
end

---------------------------------------------------------------------------
-- where the blood leaves the body, and how the struck part is moving
---------------------------------------------------------------------------
-- the outward normal of the body surface at `pos` (the head's for a blow above the shoulders, the
-- torso's lower down), and the struck part's velocity just after the blow
function Blood.Wound(pos: Vector3, drive: Vector3, tier: any, victim: Model?, dirSign: number?): (Vector3, Vector3)
	local d = Vector3.new(drive.X, 0, drive.Z)
	d = if d.Magnitude > 1e-3 then d.Unit else Vector3.new(0, 0, -1)
	local normal = -d
	local side = Vector3.zero
	local root = victim and victim:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local rp = root.Position
		local h = pos.Y - rp.Y
		local center = if h > 1.05 then rp + Vector3.new(0, 1.5, 0) else Vector3.new(rp.X, pos.Y, rp.Z)
		local out = pos - center
		if out.Magnitude > 0.1 then
			normal = out.Unit
		end
		local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z)
		side = if right.Magnitude > 1e-3 then right.Unit * (dirSign or 0) else Vector3.zero
	end
	local head = d * tier.Carry + side * tier.Side + Vector3.new(0, tier.Lift, 0)
	return normal, head
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------
Blood.SoundHook = nil :: ((string, Vector3) -> ())? -- CombatFX plugs its sound player in

function Blood.Spray(pos: Vector3, drive: Vector3, tierName: string?, victim: Model?, dirSign: number?)
	if not B.Enabled or not inView(pos) then
		return
	end
	refreshFilter(true)
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local normal, head = Blood.Wound(pos, drive, tier, victim, dirSign)
	-- the mean path: the struck part's motion plus the crown's mean push off the surface
	local ejectMean = (tier.Eject[1] + tier.Eject[2]) * 0.5 * math.cos(math.rad((tier.Crown[1] + tier.Crown[2]) * 0.5))
	local mean = head + normal * ejectMean
	local meanSpeed = mean.Magnitude
	local meanDir = if meanSpeed > 1e-3 then mean.Unit else normal
	-- the particles, cut short so none of them can reach a surface
	local a = sprayRig()
	a.CFrame = along(pos, meanDir)
	local clearance: { [number]: number } = {}
	for name, count in pairs({ Mist = tier.Mist, Streaks = tier.Streaks, Blobs = if tier.Splash then math.max(2, math.floor(tier.Streaks * 0.4)) else 0 }) do
		if count > 0 then
			local e = emitters[name]
			local kind = KINDS[name]
			local vmax = math.max(kind.Speed[2], meanSpeed)
			local spread = math.min(tier.Crown[2], 60)
			local cap = clearance[vmax] or Blood.ParticleClearance(pos, meanDir, spread, vmax)
			clearance[vmax] = cap
			e.Speed = NumberRange.new(math.min(kind.Speed[1], meanSpeed), vmax)
			e.Lifetime = NumberRange.new(math.min(kind.Life[1], cap * 0.6), math.min(kind.Life[2], cap))
			e.SpreadAngle = Vector2.new(spread, spread)
			e:Emit(count)
		end
	end
	-- the droplets that will land: a splash crown out of the wound (never back into the body),
	-- carried by the struck part's motion
	for _ = 1, tier.Drops do
		local v = head + Blood.Crown(normal, tier)
		launch(pos + normal * 0.05, v, (0.09 + math.random() * 0.08) * tier.Size)
	end
end

-- a knocked-out body: a pool spreads slowly out from under the torso
function Blood.Pool(char: Model)
	if not B.Enabled then
		return
	end
	task.delay(1.1, function()
		local torso = char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
		if not (torso and torso:IsA("BasePart") and torso.Parent) or not inView(torso.Position) then
			return
		end
		refreshFilter(true)
		local hit = castSolid(torso.Position + Vector3.new(0, 1, 0), Vector3.new(0, -5, 0))
		if hit and hit.Normal.Y > 0.7 then
			laySplat(hit, Vector3.zero, 2.6, true)
		end
	end)
end

function Blood.Clear()
	for _, s in ipairs(splats) do
		s.Serial += 1
		s.Busy = false
		s.Decal.Transparency = 1
		s.Part.CFrame = PARK
	end
	for _, d in ipairs(drops) do
		d.Live = false
		d.Part.CFrame = PARK
	end
end

return Blood
