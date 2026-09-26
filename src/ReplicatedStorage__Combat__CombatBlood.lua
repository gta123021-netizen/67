--[[
	CombatBlood  (ReplicatedStorage.Combat.CombatBlood)
	Blood for a clean blow - client-side and cosmetic (every client builds its own from the "Hit"
	it hears, or the attacker from its own impact frame).

	  Blood.Spray(pos, dir, tier, victim?)   at the contact point, thrown the way the blow drove:
	      a fine mist, streaks and (heavy blows) a few thick blobs - particle bursts - plus a handful
	      of real DROPLETS: small wet ellipsoids that fly on ballistic paths (gravity, air drag),
	      stretched along their motion. Where a droplet meets the world - the floor, a slope, a wall,
	      a step, terrain - it leaves a splatter lying flat on that surface, elongated the way the drop
	      was travelling and sized by how big and fast it was. Water swallows it.
	  Blood.Pool(char)                       a knocked-out body bleeds a pool that spreads under it
	  Blood.Clear()                          everything gone at once

	Splatters fit the ground they land on: before one is laid, its corners are probed; one that would
	hang over a ledge or float over (or sink into) a bump shrinks until it fits, or isn't laid. They
	darken as they dry, then fade out and are reused (Config.Blood.Splat: Hold, Fade, Cap - the oldest
	fades early when the cap is reached). Nothing here ever collides, casts a ray target or touches
	anything: droplets and splatters are anchored, CanCollide / CanQuery / CanTouch off, pooled.
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
local MAX_DROPS = 64
local DROP_LIFE = 1.6

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
local filterAt = -1
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
	for _, name in ipairs({ "PracticeDummies", "CombatFX", "CombatShatter", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

-- a ray that only stops on something that really looks solid (a see-through trigger, a force
-- field or an invisible collision box never catches blood)
local function castSolid(from: Vector3, delta: Vector3): RaycastResult?
	local origin = from
	local left = delta
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, left, rayParams)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		local see = inst:IsA("BasePart") and (inst.Transparency >= 0.85 or inst.Material == Enum.Material.ForceField)
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

local function sprayRig(): Attachment
	if sprayAtt and sprayAtt.Parent then
		return sprayAtt
	end
	local a = Instance.new("Attachment")
	a.Name = "BloodSpray"
	a.Parent = workspace.Terrain
	local color = ColorSequence.new(B.Color, B.Dry)
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
		Transparency = seqN({ { 0, 0.05 }, { 0.6, 0.2 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.25, 0.55), Speed = NumberRange.new(8, 19), Drag = 4,
		Acceleration = Vector3.new(0, -32, 0), SpreadAngle = Vector2.new(30, 30),
		Rotation = NumberRange.new(0, 0), ZOffset = 0.2,
	})
	emitter("Streaks", {
		Texture = STREAK_TEXTURE, Orientation = Enum.ParticleOrientation.VelocityParallel,
		Size = seqN({ { 0, 0.14, 0.04 }, { 1, 0.3, 0.06 } }), Squash = seqN({ { 0, 0 }, { 1, -2.2 } }),
		Transparency = seqN({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.2, 0.42), Speed = NumberRange.new(12, 26), Drag = 1.5,
		Acceleration = Vector3.new(0, -62, 0), SpreadAngle = Vector2.new(34, 34), ZOffset = 0.3,
	})
	emitter("Blobs", {
		Texture = BLOB_TEXTURE, Orientation = Enum.ParticleOrientation.FacingCamera,
		Size = seqN({ { 0, 0.2, 0.06 }, { 0.3, 0.5, 0.12 }, { 1, 0.7, 0.1 } }),
		Transparency = seqN({ { 0, 0.1 }, { 0.5, 0.25 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.3, 0.5), Speed = NumberRange.new(4, 9), Drag = 2,
		Acceleration = Vector3.new(0, -30, 0), SpreadAngle = Vector2.new(40, 40),
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

---------------------------------------------------------------------------
-- splatters (pooled flat parts with the blood decal on top)
---------------------------------------------------------------------------
type Splat = { Part: Part, Decal: Decal, Serial: number, Born: number, Busy: boolean }
local splats: { Splat } = {}
local splatLayer = 0

local function newSplat(): Splat
	local p = Instance.new("Part")
	p.Name = "BloodSplat"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 0.05, 1)
	p.CFrame = CFrame.new(0, -5000, 0)
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
	return oldest :: Splat -- the cap: the oldest one is reused (a new drop never waits)
end

-- how far the surface under a spot is from the plane through `center` with normal `n` (nil: no
-- surface there - a ledge, a hole)
local function surfaceOffset(center: Vector3, n: Vector3, spot: Vector3): number?
	local hit = castSolid(spot + n * 0.6, -n * 1.4)
	if not hit then
		return nil
	end
	return (hit.Position - center):Dot(n)
end

-- the largest size (<= want) at which a splat lies flat on this surface
local function fitSize(center: Vector3, n: Vector3, right: Vector3, fwd: Vector3, want: number, stretch: number): number?
	local size = want
	for _ = 1, 3 do
		local ok = true
		local hx, hz = size * 0.5, size * stretch * 0.5
		for _, c in ipairs({ { hx, hz }, { -hx, hz }, { hx, -hz }, { -hx, -hz } }) do
			local off = surfaceOffset(center, n, center + right * c[1] + fwd * c[2])
			if not off or math.abs(off) > 0.22 then
				ok = false
				break
			end
		end
		if ok then
			return size
		end
		size *= 0.6
		if size < B.Splat.Min * 0.6 then
			return nil
		end
	end
	return nil
end

-- lay a splatter where a drop landed. travel = the drop's velocity (the splat stretches along it)
local function laySplat(hit: RaycastResult, travel: Vector3, size: number, quiet: boolean?)
	if hit.Material == Enum.Material.Water then
		return
	end
	local n = hit.Normal
	-- stretched along the travel projected on the surface (a drop landing at a shallow angle smears)
	local tang = travel - n * travel:Dot(n)
	local speed = travel.Magnitude
	local fwd = if tang.Magnitude > 0.5 then tang.Unit else (n:Cross(Vector3.xAxis).Magnitude > 0.1 and n:Cross(Vector3.xAxis).Unit or n:Cross(Vector3.zAxis).Unit)
	local right = fwd:Cross(n).Unit
	fwd = n:Cross(right).Unit
	local grazing = if speed > 0.1 then 1 - math.abs(travel.Unit:Dot(n)) else 0
	local stretch = 1 + math.clamp(grazing * 1.6, 0, 1.4)
	local want = math.clamp(size, B.Splat.Min, B.Splat.Max)
	local fit = fitSize(hit.Position, n, right, fwd, want, stretch)
	if not fit then
		return
	end
	local s = takeSplat()
	s.Serial += 1
	local serial = s.Serial
	s.Busy = true
	s.Born = os.clock()
	splatLayer = (splatLayer + 1) % 12
	local lift = 0.03 + splatLayer * 0.002 -- overlapping splats never z-fight
	local spin = CFrame.Angles(0, math.random() * math.pi * 2 * (if grazing > 0.4 then 0.05 else 1), 0)
	local cf = CFrame.fromMatrix(hit.Position + n * lift, right, n, -fwd) * spin
	local p, d = s.Part, s.Decal
	local full = Vector3.new(fit, 0.05, fit * stretch)
	p.Size = full * 0.45
	p.CFrame = cf
	d.Color3 = B.Color
	d.Transparency = 0.08
	-- the drop spreads as it lands, then dries darker, then fades
	TweenService:Create(p, TweenInfo.new(0.16 + fit * 0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = full }):Play()
	TweenService:Create(d, TweenInfo.new(B.Splat.Hold, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Color3 = B.Dry }):Play()
	if not quiet and math.random() < 0.35 then
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
				p.CFrame = CFrame.new(0, -5000, 0)
			end
		end)
	end)
end

---------------------------------------------------------------------------
-- droplets: pooled wet ellipsoids on ballistic paths, all moved in one heartbeat
---------------------------------------------------------------------------
type Drop = { Part: Part, Pos: Vector3, Vel: Vector3, Size: number, Age: number, Live: boolean }
local drops: { Drop } = {}
local stepConn: RBXScriptConnection? = nil
local PARK = CFrame.new(0, -5000, 0)

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

local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}
local function step(dt: number)
	dt = math.min(dt, 1 / 20)
	table.clear(moveParts)
	table.clear(moveCfs)
	local any = false
	refreshFilter()
	for _, d in ipairs(drops) do
		if d.Live then
			any = true
			d.Age += dt
			local v = d.Vel * math.max(0, 1 - B.Drag * dt) - Vector3.new(0, B.Gravity * dt, 0)
			local delta = v * dt
			local hit = if delta.Magnitude > 1e-4 then castSolid(d.Pos, delta) else nil
			if hit then
				d.Live = false
				laySplat(hit, v, d.Size * (4.2 + math.min(v.Magnitude, 30) * 0.035))
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, PARK)
			elseif d.Age > DROP_LIFE then
				d.Live = false
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, PARK)
			else
				d.Pos += delta
				d.Vel = v
				local len = 1 + math.min(v.Magnitude, 40) * 0.03
				d.Part.Size = Vector3.new(d.Size, d.Size, d.Size * len)
				table.insert(moveParts, d.Part)
				table.insert(moveCfs, CFrame.lookAt(d.Pos, d.Pos + (if v.Magnitude > 0.1 then v else Vector3.yAxis)))
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

local function launch(pos: Vector3, vel: Vector3, size: number)
	local d = takeDrop()
	if not d then
		return
	end
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

local function inView(pos: Vector3): boolean
	local cam = workspace.CurrentCamera
	return cam == nil or (cam.CFrame.Position - pos).Magnitude <= B.View
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------
Blood.SoundHook = nil :: ((string, Vector3) -> ())? -- CombatFX plugs its sound player in

function Blood.Spray(pos: Vector3, dir: Vector3, tierName: string?, _victim: Model?)
	if not B.Enabled or not inView(pos) then
		return
	end
	local tier = B.Tiers[tierName or "Light"] or B.Tiers.Light
	local d = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	-- the particles: aimed along the blow, a little lift
	local a = sprayRig()
	a.CFrame = along(pos, (d + Vector3.new(0, 0.25, 0)).Unit)
	local mist = emitters.Mist
	mist.SpreadAngle = Vector2.new(tier.Spread, tier.Spread)
	mist:Emit(tier.Mist)
	local streaks = emitters.Streaks
	streaks.SpreadAngle = Vector2.new(tier.Spread * 0.9, tier.Spread * 0.9)
	streaks:Emit(tier.Streaks)
	if tier.Splash then
		emitters.Blobs:Emit(math.max(2, math.floor(tier.Streaks * 0.4)))
	end
	-- the droplets that will land
	for _ = 1, tier.Drops do
		local v = cone(d, tier.Spread) * (tier.Speed[1] + math.random() * (tier.Speed[2] - tier.Speed[1]))
		v += Vector3.new(0, tier.Up * (0.4 + math.random() * 0.8), 0)
		launch(pos + v.Unit * 0.15, v, (0.09 + math.random() * 0.08) * tier.Size)
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
		refreshFilter()
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
