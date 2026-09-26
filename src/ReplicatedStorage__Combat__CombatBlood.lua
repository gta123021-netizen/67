--[[
	CombatBlood  (ReplicatedStorage.Combat.CombatBlood)
	Blood for a clean blow - client-side and cosmetic (every client builds its own from the "Hit"
	it hears, or the attacker from its own impact frame).

	  Blood.Spray(pos, drive, tier, victim?, dirSign?)
	      pos = the contact point on the body, drive = the way the blow travels (flat), dirSign = the
	      way it drove the head (+1 = to the victim's right). The place's own blood effects
	      (ReplicatedStorage.Combat.VFX: Blood, BloodHeavy - Config.Blood.Tiers picks which, how big,
	      how many) burst out of the WOUND SURFACE: aimed outward from it and carried by the struck
	      part's own motion - back with a straight, sideways with a hook, up with an uppercut - so
	      none of it flies back into the body. Every particle that moves is cut short so it fades out
	      before it could reach a floor, a wall or a ceiling: nothing passes through anything,
	      nothing lands, nothing is left behind
	  Blood.Burst(pos, dir, name, scale?, count?)   one of those effects, the same way (the gore)
	  Blood.Launch(pos, vel, size)   one droplet (the gore's bleeding): see below
	  Blood.Clear()      everything gone at once

	THE PHYSICS. A droplet obeys  dv/dt = -k v + g  (air drag k, the world's gravity g), integrated
	EXACTLY:
	  v(t) = g/k + (v0 - g/k) e^(-k t)      x(t) = x0 + (g/k) t + (v0 - g/k)(1 - e^(-k t)) / k
	in substeps of at most 1/120 s, each tested for contact by a ray along its chord (the arc bends
	less than a thousandth of a stud inside one), so the flight and the landing spot are the same at
	any frame rate and a fast drop can't skip through a thin wall. Where a drop meets something solid -
	floor, slope, step, wall, ceiling, terrain, water - it is gone: nothing stays behind.
	See-through things (glass, triggers, force fields) and non-colliding decorations don't catch
	blood; fighters don't either (it falls past them). Nothing here collides, catches a ray or
	touches anything: anchored, CanCollide / CanQuery / CanTouch off, all pooled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))
local VFX = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatVFX"))

local Blood = {}

local B = Config.Blood
local MAX_DROPS = 72
local DROP_LIFE = 2.5 -- a drop that has met nothing by then (off a cliff) is gone
local SUBSTEP = 1 / 120

local GRAVITY: number = B.Gravity or workspace.Gravity
local G = Vector3.new(0, -GRAVITY, 0)
local K = B.Drag
local TERMINAL = G / K -- the velocity drag and gravity balance at
Blood.Gravity = GRAVITY

Blood.Stats = { Drops = 0, Landed = 0, Lost = 0, Water = 0, Bursts = 0 }

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
-- bodies blood never lands on besides the players and the practice dummies (the gore's NPCs: their
-- own stumps bleed from inside them); weak, so a removed body is simply dropped
local ignored: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function Blood.Ignore(body: Instance)
	ignored[body] = true
	filterAt = -math.huge
end
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
	for _, name in ipairs({ "PracticeDummies", "CombatFX", "CombatShatter", "CombatGore", "CombatDebugDraw" }) do
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
-- the spray: the place's own blood effects (ReplicatedStorage.Combat.VFX), aimed and cut short
---------------------------------------------------------------------------
--[[ how long a particle thrown from `pos` along a cone round `dir` at up to `speed` can live before
	ANY of them could meet a surface. `spread` / `spreadY` are the emitter's SpreadAngle: a particle
	is turned up to that far about each of two axes at once, so the cone that holds them all is the
	one through its corners (cos = cos X * cos Y: 50 x 50 degrees reaches 66 degrees). Their real curved paths - down the
	cone's axis and all round its rim - are traced through the world in short chords; the soonest
	contact wins. `accel` / `drag` are the emitter's own (a ParticleEmitter's Drag halves the speed
	every 1/Drag seconds); without them the particles move like the droplets. `life` is the longest
	they would live anyway. ]]
function Blood.ParticleClearance(pos: Vector3, dir: Vector3, spread: number, speed: number, accel: Vector3?, drag: number?, life: number?, spreadY: number?): number
	refreshFilter()
	local LIFE = life or 0.6
	local STEP = 0.05 -- (each chord is ray-cast whole: gravity bends it by a hair)
	local function move(x: Vector3, v: Vector3, h: number): (Vector3, Vector3)
		if not accel then
			return advance(x, v, h)
		end
		-- (a ParticleEmitter: its acceleration, then its drag, over the step)
		local v1 = (v + accel * h) * (2 ^ (-(drag or 0) * h))
		return x + (v + v1) * 0.5 * h, v1
	end
	local d = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = d:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local fwd = right:Cross(d).Unit
	local soonest = LIFE
	local sx, sy = math.abs(spread), math.abs(spreadY or spread)
	local a = if sx >= 90 or sy >= 90
		then math.rad(179)
		else math.acos(math.clamp(math.cos(math.rad(sx)) * math.cos(math.rad(sy)), -1, 1))
	local dirs = { d }
	-- the rim all round, a ring half way out, and the steepest paths up and down the cone can take
	-- (a floor or a ceiling is met first along those, wherever the cone is tilted)
	for i = 0, 7 do
		local b = i / 8 * math.pi * 2
		table.insert(dirs, (d * math.cos(a) + (right * math.cos(b) + fwd * math.sin(b)) * math.sin(a)).Unit)
		if i % 2 == 0 then
			table.insert(dirs, (d * math.cos(a * 0.5) + (right * math.cos(b + 0.4) + fwd * math.sin(b + 0.4)) * math.sin(a * 0.5)).Unit)
		end
	end
	-- the path within the cone aimed most directly at `w`: `w` itself if the cone holds it, else the
	-- rim direction nearest to it (the axis turned toward it by the spread)
	local function toward(w: Vector3)
		local off = math.acos(math.clamp(d:Dot(w), -1, 1))
		if off <= a then
			table.insert(dirs, w)
		else
			local perp = w - d * d:Dot(w)
			if perp.Magnitude > 1e-4 then
				table.insert(dirs, (d * math.cos(a) + perp.Unit * math.sin(a)).Unit)
			end
		end
	end
	toward(Vector3.yAxis)
	toward(-Vector3.yAxis)
	-- every surface near enough to matter (felt for in the six directions): the path aimed most
	-- straight at it, so a wall is never met between two samples
	local reach = speed * LIFE + 1
	for _, w in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis, Vector3.yAxis, -Vector3.yAxis }) do
		local hit = castSolid(pos, w * reach)
		if hit then
			toward(-hit.Normal)
		end
	end
	for _, u in ipairs(dirs) do
		local x, v = pos, u * speed
		local t = 0
		while t < soonest do
			local h = math.min(STEP, soonest - t)
			local x1, v1 = move(x, v, h)
			local hit = castSolid(x, x1 - x)
			if hit then
				local f = (hit.Position - x).Magnitude / math.max((x1 - x).Magnitude, 1e-6)
				soonest = math.min(soonest, t + h * f)
				break
			end
			x, v, t = x1, v1, t + h
		end
	end
	return math.max(0.01, soonest * 0.85)
end

local PARK = CFrame.new(0, -5000, 0)


---------------------------------------------------------------------------
-- droplets: pooled wet ellipsoids on exact ballistic paths, all moved in one heartbeat
---------------------------------------------------------------------------
type Drop = { Part: Part, Pos: Vector3, Vel: Vector3, Size: number, Age: number, Live: boolean }
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
	local d = { Part = p, Pos = Vector3.zero, Vel = Vector3.zero, Size = 0.14, Age = 0, Live = false }
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

-- a drop met a surface: it is simply gone where it lands (nothing is left behind)
local function land(hit: RaycastResult)
	Blood.Stats.Landed += 1
	if hit.Material == Enum.Material.Water then
		Blood.Stats.Water += 1
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
			d.Pos = hit.Position
			d.Live = false
			land(hit)
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

function Blood.Launch(pos: Vector3, vel: Vector3, size: number)
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
	d.Part.Color = B.Color
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
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
function Blood.Spray(pos: Vector3, drive: Vector3, tierName: string?, victim: Model?, dirSign: number?)
	if not B.Enabled or not inView(pos) then
		return
	end
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local normal, head = Blood.Wound(pos, drive, tier, victim, dirSign)
	-- aimed out of the wound, thrown the way the struck part goes - sideways with a hook, up with an
	-- uppercut - but never into the body: the part of that motion that runs back into the body
	-- (a straight drives the head away from the wound) is the body's, not the blood's
	local ejectMean = (tier.Eject[1] + tier.Eject[2]) * 0.5 * math.cos(math.rad((tier.Crown[1] + tier.Crown[2]) * 0.5))
	local carried = head - normal * math.min(0, head:Dot(normal))
	local mean = normal * ejectMean + carried * 0.6
	local aim = if mean.Magnitude > 1e-3 then mean.Unit else normal
	for _, fx in ipairs(tier.Effects) do
		Blood.Burst(pos, aim, fx.Name, fx.Scale, fx.Count, victim)
	end
end

-- one of the place's blood effects (ReplicatedStorage.Combat.VFX) burst at `pos`, thrown along
-- `dir`. Every particle that moves fades before it could reach a floor, a wall or a ceiling: its
-- own path (its emitter's speed, spread, gravity and drag) is traced through the world first.
-- `body`: the body it comes out of (never a surface its own blood could reach)
function Blood.Burst(pos: Vector3, dir: Vector3, name: string, scale: number?, count: number?, body: Instance?)
	if not B.Enabled or not inView(pos) then
		return
	end
	refreshFilter(true)
	if body then
		local list = rayParams.FilterDescendantsInstances
		table.insert(list, body)
		rayParams.FilterDescendantsInstances = list
	end
	local aim = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	VFX.Play(name, VFX.Along(pos, aim), {
		Scale = scale or 1,
		Count = count or 1,
		MaxLife = function(e: ParticleEmitter, speed: number): number?
			if speed < 1 then
				return nil -- (a splash that stays where it burst)
			end
			return Blood.ParticleClearance(pos, aim, e.SpreadAngle.X, speed, e.Acceleration, e.Drag, e.Lifetime.Max, e.SpreadAngle.Y)
		end,
	})
	Blood.Stats.Bursts += 1
end

function Blood.Clear()
	for _, d in ipairs(drops) do
		d.Live = false
		d.Part.CFrame = PARK
	end
end

return Blood
