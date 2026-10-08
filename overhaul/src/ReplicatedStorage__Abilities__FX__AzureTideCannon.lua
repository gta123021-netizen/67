--[[
	AzureTideCannon  (ReplicatedStorage.Abilities.FX.AzureTideCannon)
	What Azure Tide Cannon looks and sounds like - on every screen, for every caster. One continuous
	event, every phase flowing into the next, ELECTRIC from the first spark to the last crackle. Built
	only from the place's own effects: the packs in Abilities.Assets.AzureTideCannon (their meshes,
	emitters, textures and sounds - the lightning meshes are the VFX library's Lightning, Thunder and
	ElectricShockwave packs) and plain Neon / ForceField geometry. Nothing from outside the place.

	  GATHER    light wakes in the palms; lightning is drawn in from all round the hands - 3D arcs
	            reaching in and snapping into the palms
	  FORM      a seed of light between the hands becomes a sphere: a white-hot core in an azure body, a
	            dark swirl giving it shape, a force-field skin, plasma and crescents inside it, the
	            pack's azure flames licking off it, arcs jumping from both palms into it
	  SURGE     it becomes unstable: lightning snaps off it, a crackling lightning cage closes round it,
	            and at its largest it is a blue black hole with electric rings spinning round it
	  COMPRESS  everything is sucked in and the sphere crushes down to its brightest
	  THRUST    the hands drive it forward
	  RELEASE   the sphere swells into the beam's root and its head - the END BALL - is hurled out ahead
	            of the beam; two electric shockwave rings burst off the hands (a mirrored pair), the
	            ground under the caster blasts, a white-hot pop, a flash
	  BEAM      fully 3D and continuous: a white-hot core inside cyan, azure and force-field sleeves,
	            each one flaring smoothly out of the sphere and running whole into the end ball - no
	            ribbons, no sprites along it, no seams. Lightning crawls all over it (the Lightning
	            pack's mesh spun and flickered the way its pack drives it, and 3D arcs leaping along its
	            skin), a surge rushes down it into the end ball with every hit, it grinds and tears the
	            ground it passes over. It reaches Beam.Range and no further
	  END BALL  the beam's head: a 3D ball of the same layers in a crackling lightning cage. It races out
	            stretched like a comet, lands with a squash, pulses with every hit, and discharges
	            lightning into whatever it touches - the floor, a wall, a body - throwing chips of that
	            very surface
	  BLAST     its last moments drain the beam into the end ball (a force-field shell crushes in on it,
	            lightning pours in) and it detonates: a compact, symmetric blast exactly BlastRadius
	            round (its hitbox) - a white-hot core, an energy dome and its skin, a ring of electric
	            shockwaves (one level, a mirrored tilted pair), rays of 3D lightning evenly round along
	            the ground and rising, a ring of rock spikes torn up round a crater, chunks thrown
	            evenly all round that tumble, bounce and settle trailing dust, smoke and dust, and
	            lightning crackling over the crater while its light cools from white to deep blue
	There is no 2D line, ray or ribbon anywhere in it, and no stack of glow discs: every pack burst is
	kept to its smoke, dust, flames and shards (packKeeps). Light and the screen are only ever borrowed:
	every light, tint and blur fades back to nothing. Nothing outlives the cast but its own short-lived
	effects; everything is cleaned in one call.

	FX.Start(o) -> handle. o = {
	  Caster   Model
	  Def      AbilityConfig entry
	  Started  os.clock() of the cast's clip time 0 on this screen
	  Mine     the local player's own cast
	  Aim      () -> Vector3: where the beam points now
	  Bodies   () -> { { Key, Cf } } every hittable body but the caster
	  World    (origin, vector) -> RaycastResult?
	  Camera   (profile, dir?, scale?) -> ()  (the local player's view, CombatFX.Camera)
	  Fov      (extra) -> ()                  (CombatFX.SetCameraFov)
	  Track    () -> AnimationTrack?          (the cast's clip on the caster, if this screen sees it)
	}
	handle.Stop(why) ends it (why = "Interrupted": a charge fizzles, a beam collapses at once, no blast)
	handle.Destroy() gone at once (the character left)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Abilities = ReplicatedStorage:WaitForChild("Abilities")
local U = require(script.Parent:WaitForChild("FXUtil"))
local BeamMath = require(Abilities:WaitForChild("BeamMath"))
local AbilityConfig = require(Abilities:WaitForChild("AbilityConfig"))

local FX = {}
local STUDIO = RunService:IsStudio()

local ASSETS: Instance? = nil
local function assets(): Instance
	if ASSETS and ASSETS.Parent then
		return ASSETS
	end
	ASSETS = Abilities:WaitForChild("Assets"):WaitForChild("AzureTideCannon")
	return ASSETS :: Instance
end
local function asset(path: string): Instance?
	local node: Instance? = assets()
	for name in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(name)
	end
	return node
end
-- a mesh of the pack (Assets.AzureTideCannon.Meshes): SphereHD, Swirl, Rock, and the lightning -
-- Sleeve (Lightning, a crackling bolt along its X), Strike (a lightning cluster), Spark (ThunderSpark),
-- Thunder (a bolt up its Y), Shock (ElectricShockwave, a ring round its Y)
local function template(name: string): BasePart?
	local t = asset("Meshes/" .. name)
	return if t and t:IsA("BasePart") then t else nil
end

---------------------------------------------------------------------------
-- palette
---------------------------------------------------------------------------
local rgb = Color3.fromRGB
local C_WHITE = rgb(244, 252, 255)
local C_HOT = rgb(196, 242, 255)
local C_ICE = rgb(150, 224, 255)
local C_LIGHT = rgb(90, 194, 255)
local C_MID = rgb(36, 136, 255)
local C_DEEP = rgb(16, 62, 214)
local C_DUST = rgb(176, 194, 218)
-- (the sphere's extra shades: royal through a glacier cyan)
local C_ROYAL = rgb(28, 84, 240)
local C_AZURE = rgb(58, 168, 255)
local C_CYAN = rgb(104, 228, 255)
-- lightning: white with a breath of cyan
local C_ARC = rgb(226, 248, 255)

local function cs(a: Color3, b: Color3?, c: Color3?): ColorSequence
	if c then
		return ColorSequence.new({ ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(0.5, b :: Color3), ColorSequenceKeypoint.new(1, c) })
	end
	return if b then ColorSequence.new(a, b) else ColorSequence.new(a)
end
local function ns(...: number): NumberSequence
	local v = { ... }
	if #v == 1 then
		return NumberSequence.new(v[1])
	end
	local kps = {}
	for i = 1, #v, 2 do
		table.insert(kps, NumberSequenceKeypoint.new(v[i], v[i + 1]))
	end
	return NumberSequence.new(kps)
end
local function nr(a: number, b: number?): NumberRange
	return NumberRange.new(a, b or a)
end
local function tex(id: number): string
	return "rbxassetid://" .. id
end
-- (math.clamp, but never an error when the room left is smaller than the least it may have)
local function within(x: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, x))
end

---------------------------------------------------------------------------
-- the packs' textures (every one is in the place's VFX packs)
---------------------------------------------------------------------------
local T = {
	Smoke = tex(8527116276), -- the Explosion pack's smoke
	Dots = tex(14582794847), -- motes
	PlasmaBall = tex(8214516993), -- VFX PACK V3: turbulent energy ball
	Chaos = tex(17067057050), -- Big Impact1: chaotic electric sphere
	Swirl = tex(9309993091), -- Explosion Implode "CHARGE PART": swirl
	Crescent = tex(16669803246), -- Big Windspin1: crescent
	ArcBall = tex(16334776490), -- lightning_ball_sorta (4x4)
	ArcBurst = tex(17087448166), -- Auras Bottom: electric burst
	Spark = tex(120067432715909), -- spark (2x2)
	Crackle = tex(11515478646), -- "A - ELECTRICITY 01" (4x4): a crackle of electricity
}

---------------------------------------------------------------------------
-- builders
---------------------------------------------------------------------------
local function emitter(parent: Instance, p: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Rate = 0
	e.Speed = nr(0)
	for k, v in pairs(p) do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function att(parent: Instance, name: string): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Parent = parent
	return a
end

local function light(parent: Instance, color: Color3): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = 0
	l.Range = 0
	l.Shadows = false
	l.Parent = parent
	return l
end

local GRID = {
	["2x2"] = Enum.ParticleFlipbookLayout.Grid2x2,
	["4x4"] = Enum.ParticleFlipbookLayout.Grid4x4,
}
local function book(layout: string): { [string]: any }
	return { FlipbookLayout = GRID[layout], FlipbookMode = Enum.ParticleFlipbookMode.OneShot }
end
local function with(a: { [string]: any }, b: { [string]: any }): { [string]: any }
	local out = table.clone(a)
	for k, v in pairs(b) do
		out[k] = v
	end
	return out
end

-- a part's X axis along a frame's look (a Cylinder's length runs along its X)
local ALONG = CFrame.Angles(0, math.rad(90), 0)
local TAU = math.pi * 2

-- two unit vectors square to `f` and to each other
local function basis(f: Vector3): (Vector3, Vector3)
	local u = f:Cross(if math.abs(f.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis).Unit
	return u, f:Cross(u).Unit
end

local function randomUnit(): Vector3
	for _ = 1, 8 do
		local v = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
		local m = v.Magnitude
		if m > 0.05 and m <= 1 then
			return v / m
		end
	end
	return Vector3.yAxis
end

---------------------------------------------------------------------------
-- one animator for every short-lived piece of every cast (lights, fireballs, rings, the blast, the
-- screen): a single RenderStepped connection that exists only while something is animating
---------------------------------------------------------------------------
type Anim = { T0: number, Dur: number, Step: (number, number) -> (), Done: (() -> ())? }
local live: { Anim } = {}
local animConn: RBXScriptConnection? = nil
local function animate(delay: number, dur: number, step: (number, number) -> (), done: (() -> ())?)
	table.insert(live, { T0 = os.clock() + delay, Dur = math.max(dur, 1e-3), Step = step, Done = done })
	if animConn then
		return
	end
	animConn = RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		for i = #live, 1, -1 do
			local a = live[i]
			local k = (now - a.T0) / a.Dur
			if k >= 0 then
				local ok = pcall(a.Step, math.min(k, 1), dt)
				if k >= 1 or not ok then
					table.remove(live, i)
					if a.Done then
						pcall(a.Done)
					end
				end
			end
		end
		if #live == 0 and animConn then
			animConn:Disconnect()
			animConn = nil
		end
	end)
end

-- a flash of the whole view (an anime impact frame): white-blue on the first frames, bled back out
local function screenFlash(strength: number, length: number)
	local cam = workspace.CurrentCamera
	if not cam or strength <= 0.04 then
		return
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "AzureTideFlash"
	cc.TintColor = rgb(214, 236, 255)
	cc.Parent = cam
	local blur = Instance.new("BlurEffect")
	blur.Name = "AzureTideFlash"
	blur.Size = 0
	blur.Parent = cam
	animate(0, length, function(k)
		local e = (1 - k) ^ 2.4
		cc.Brightness = 0.32 * strength * e
		cc.Contrast = 0.42 * strength * e
		cc.Saturation = 0.3 * strength * e
		blur.Size = 9 * strength * (1 - k) ^ 3
	end, function()
		cc:Destroy()
		blur:Destroy()
	end)
	Debris:AddItem(cc, length + 1)
	Debris:AddItem(blur, length + 1)
end

-- a light that flares and fades away at a point (it removes itself); `cool`: the colour it cools to
local function flashLight(at: Vector3, color: Color3, brightness: number, range: number, life: number, parent: Instance?, cool: Color3?)
	local p = U.Part({ CFrame = CFrame.new(at) })
	p.Parent = parent or U.Holder()
	local l = light(p, color)
	animate(0, life, function(k)
		l.Brightness = brightness * (1 - k) ^ 2
		l.Range = range * (1 - 0.3 * k)
		if cool then
			l.Color = color:Lerp(cool, math.min(1, k * 1.6))
		end
	end, function()
		p:Destroy()
	end)
	Debris:AddItem(p, life + 1)
end

-- a 3D ball of light swelling from d0 to d1 (diameters) and burning off, its colour running c0 -> c1
-- (white-hot cooling to blue): the place's SphereHD in Neon or ForceField. On a floor (`floor`, `up`)
-- it rests on it and rises as it swells - it never sinks into the ground
local function glowBall(at: Vector3, d0: number, d1: number, life: number, parent: Instance?, mat: Enum.Material, c0: Color3, c1: Color3, t0: number, floor: Vector3?, up: Vector3?)
	local tpl = template("SphereHD")
	if not tpl then
		return
	end
	local p = U.Solid(tpl, { Material = mat, Color = c0, Transparency = t0 })
	local function place(d: number)
		local c = at
		if floor and up then
			local h = (at - floor):Dot(up)
			c = at + up * math.max(0, d * 0.5 + 0.1 - h)
		end
		p.Size = Vector3.one * math.max(0.05, d)
		p.CFrame = CFrame.new(c)
	end
	place(d0)
	p.Parent = parent or U.Holder()
	animate(0, life, function(k)
		place(d0 + (d1 - d0) * (1 - (1 - k) ^ 3))
		p.Transparency = t0 + (1 - t0) * k ^ 1.4
		p.Color = c0:Lerp(c1, math.min(1, k * 1.5))
	end, function()
		p:Destroy()
	end)
	Debris:AddItem(p, life + 1)
end

-- v80's fireball: a white-hot sphere in an azure one, swelling from d0 to d1 (diameters), burning off
local function fireball(at: Vector3, d0: number, d1: number, life: number, parent: Instance?, floor: Vector3?, up: Vector3?)
	glowBall(at, d0 * 0.72, d1 * 0.72, life * 0.8, parent, Enum.Material.Neon, C_WHITE, C_HOT, 0, floor, up)
	glowBall(at, d0, d1, life, parent, Enum.Material.Neon, C_MID, C_LIGHT, 0.2, floor, up)
end

-- an electric shockwave ring (the ElectricShockwave pack's mesh) lying across `up`: it swells from d0
-- to d1 (across) and burns off, spun and flickered the way its own pack drives it
local function shockRing(at: Vector3, up: Vector3, d0: number, d1: number, life: number, color: Color3, parent: Instance?, thick: number?)
	local tpl = template("Shock")
	if not tpl then
		return
	end
	local p = U.Solid(tpl, { Material = Enum.Material.Neon, Color = color, Transparency = 1 })
	p.Size = Vector3.one * 0.05
	p.Parent = parent or U.Holder()
	local base = U.Up(at, up)
	local th = thick or 0.3
	animate(0, life, function(k)
		local d = d0 + (d1 - d0) * (1 - (1 - k) ^ 3)
		p.Size = Vector3.new(d, math.max(0.05, d * th * (1 - 0.55 * k)), d)
		p.CFrame = base * CFrame.Angles(0, math.random() * TAU, 0)
		p.Transparency = math.min(1, k ^ 1.6 + (if math.random() < 0.16 then 0.4 else 0))
		p.Color = color:Lerp(C_DEEP, k * 0.55)
	end, function()
		p:Destroy()
	end)
	Debris:AddItem(p, life + 1)
end

---------------------------------------------------------------------------
-- 3D LIGHTNING: every arc is a jagged filament of thin Neon rods laid joint to joint (pooled, never
-- re-made), re-struck several times a second while it lives and thinning as it dies. There is nothing
-- flat in it: it reads as lightning from every side
---------------------------------------------------------------------------
type ArcSys = {
	Add: (gen: (number) -> { Vector3 }, life: number, width: number, color: Color3?, restrike: number?) -> (),
	Step: (now: number) -> (),
	Count: () -> number,
	Clear: () -> (),
}
local function arcSystem(parent: Instance, maxRods: number): ArcSys
	local rods: { BasePart } = {}
	local shown = 0
	local list: { any } = {}
	local function rod(i: number): BasePart
		local p = rods[i]
		if not p then
			p = U.Part({ Name = "Arc", Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon, Color = C_ARC, Transparency = 1 })
			p.Parent = parent
			rods[i] = p
		end
		return p
	end
	local sys = {}
	-- gen(k) -> its joints (k: 0..1 through its life); re-struck every `restrike` seconds
	function sys.Add(gen: (number) -> { Vector3 }, life: number, width: number, color: Color3?, restrike: number?)
		local ok, pts = pcall(gen, 0)
		if not (ok and type(pts) == "table" and #pts >= 2) then
			return
		end
		local t = os.clock()
		local re = restrike or 0.04
		table.insert(list, { Gen = gen, Pts = pts, Born = t, Life = math.max(life, 0.02), W = width, Color = color or C_ARC, Re = re, Next = t + re })
	end
	function sys.Step(now: number)
		local parts: { BasePart } = {}
		local cfs: { CFrame } = {}
		local n = 0
		for i = #list, 1, -1 do
			local a = list[i]
			local k = (now - a.Born) / a.Life
			if k >= 1 then
				table.remove(list, i)
			else
				if now >= a.Next then
					a.Next = now + a.Re
					local ok, pts = pcall(a.Gen, k)
					if ok and type(pts) == "table" and #pts >= 2 then
						a.Pts = pts
					end
				end
				local w = a.W * (1 - 0.7 * k * k)
				local tr = if k > 0.7 then (k - 0.7) * 3 else 0
				local pts = a.Pts
				for j = 1, #pts - 1 do
					if n >= maxRods then
						break
					end
					local p0, p1 = pts[j], pts[j + 1]
					local d = p1 - p0
					local len = d.Magnitude
					if len > 1e-3 then
						n += 1
						local r = rod(n)
						-- (a little longer than its stroke: the joints never show a gap)
						r.Size = Vector3.new(len + w * 0.9, w, w)
						r.Color = a.Color
						r.Transparency = tr
						parts[n] = r
						cfs[n] = U.Look((p0 + p1) * 0.5, d) * ALONG
					end
				end
			end
		end
		if n > 0 then
			workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
		end
		for j = n + 1, shown do
			rods[j].Transparency = 1
		end
		shown = n
	end
	function sys.Count(): number
		return #list
	end
	function sys.Clear()
		table.clear(list)
		for j = 1, shown do
			rods[j].Transparency = 1
		end
		shown = 0
	end
	return sys :: any
end

-- a jagged 3D path from a to b in n strokes: every joint thrown off the line (most in the middle);
-- `bow` bends the whole stroke that way
local function jagged(a: Vector3, b: Vector3, n: number, jag: number, bow: Vector3?): { Vector3 }
	local d = b - a
	local len = d.Magnitude
	if len < 1e-3 then
		return { a, b + Vector3.new(0, 1e-2, 0) }
	end
	local u, v = basis(d / len)
	local pts = { a }
	for i = 1, n - 1 do
		local t = i / n
		local env = math.sin(t * math.pi)
		local j = jag * len * (0.35 + 0.65 * env)
		local p = a + d * t + (u * (math.random() * 2 - 1) + v * (math.random() * 2 - 1)) * j
		if bow then
			p += bow * env
		end
		pts[i + 1] = p
	end
	pts[n + 1] = b
	return pts
end

---------------------------------------------------------------------------
-- what of a pack's burst this ability keeps: its smoke, dust, flames and shards. Never a flat ring or
-- disc, never a streak or line, never a bare glow disc (its 3D light is drawn in 3D), never anything
-- wider than `maxSize`
---------------------------------------------------------------------------
local DROP_NAMES = { "glow", "flash", "flare", "ring", "circ", "line", "spike", "dash", "crack" }
local FLASH_TEX = { "11037538087" } -- (the Explosion pack's "Impact3": a flash disc)
local function packKeeps(e: ParticleEmitter, maxSize: number): boolean
	if e.Orientation == Enum.ParticleOrientation.VelocityPerpendicular then
		return false
	end
	if e.Orientation == Enum.ParticleOrientation.VelocityParallel and e.FlipbookLayout == Enum.ParticleFlipbookLayout.None then
		return false
	end
	local nm = string.lower(e.Name)
	for _, w in ipairs(DROP_NAMES) do
		if string.find(nm, w, 1, true) then
			return false
		end
	end
	for _, id in ipairs(FLASH_TEX) do
		if string.find(e.Texture, id, 1, true) then
			return false
		end
	end
	local most = 0
	for _, kp in ipairs(e.Size.Keypoints) do
		most = math.max(most, kp.Value)
	end
	return most <= maxSize
end

-- one of the place's effects, fired once at a frame (the pack's own counts and delays), gone when its
-- particles are: `name` is a template in Abilities.Assets.AzureTideCannon (an Attachment, a Part or a
-- Model), `scale` sizes it (its spawn volume too), `count` multiplies what it emits, `maxSize` caps how
-- wide any of its sprites may be (packKeeps).
-- `surface`: cf's UpVector is the face of a floor or wall it stands on - then nothing it throws goes into
-- that surface (all of it flies up and out of it), nothing falls back through it, the packs' dark
-- outline smoke is left out, and every sprite is drawn in front of the surface it would cut into, so no
-- particle ever shows a hard edge where it meets the ground
local function fire(name: string, cf: CFrame, scale: number, parent: Instance?, count: number?, tweak: ((ParticleEmitter) -> ())?, surface: boolean?, maxSize: number?): Instance?
	local tpl = asset(name)
	if not tpl then
		return nil
	end
	local holder = parent or U.Holder()
	local root: Instance
	local function quiet(d: BasePart)
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.Transparency = 1
		-- (its spawn volume is sized with it: a scaled effect never spawns outside its own size)
		d.Size = d.Size * scale
		for _, a in ipairs(d:GetChildren()) do
			if a:IsA("Attachment") then
				a.Position *= scale
			end
		end
	end
	if tpl:IsA("Attachment") then
		local p = U.Part({ CFrame = cf })
		p.Parent = holder
		U.Clone(tpl, p, nil, scale)
		root = p
	elseif tpl:IsA("BasePart") then
		local p = U.Clone(tpl, holder, cf, scale) :: BasePart
		quiet(p)
		p.CFrame = cf
		root = p
	elseif tpl:IsA("Model") then
		local m = U.Clone(tpl, holder, nil, scale) :: Model
		local pivot = m:GetPivot()
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				local rel = pivot:ToObjectSpace(d.CFrame)
				quiet(d)
				d.CFrame = pivot * (rel - rel.Position + rel.Position * scale)
			end
		end
		m:PivotTo(cf)
		root = m
	else
		return nil
	end
	local cap = maxSize or math.huge
	local list = U.Emitters(root)
	for _, e in ipairs(list) do
		if not packKeeps(e, cap) or (surface and e.LightEmission < 0) then
			e:Destroy()
		end
	end
	if surface then
		local cam = workspace.CurrentCamera
		local dist = if cam then (cam.CFrame.Position - cf.Position).Magnitude else 40
		local lift = math.clamp(dist - 4, 0, 4 + 16 * scale)
		for _, e in ipairs(U.Emitters(root)) do
			e.ZOffset += lift
			if e.Speed.Max > 0.5 then
				e.EmissionDirection = Enum.NormalId.Top
				local sx, sy = math.abs(e.SpreadAngle.X), math.abs(e.SpreadAngle.Y)
				e.SpreadAngle = Vector2.new(math.min(if sx > 0 then sx else 75, 75), math.min(if sy > 0 then sy else 75, 75))
			end
			local acc = e.Acceleration
			if acc.Y < 0 then
				e.Acceleration = Vector3.new(acc.X, 0, acc.Z)
			end
		end
	end
	if tweak then
		for _, e in ipairs(U.Emitters(root)) do
			tweak(e)
		end
	end
	U.Burst(root, count)
	U.Expire(root, U.Life(root) + 0.3)
	return root
end

---------------------------------------------------------------------------
-- the cast
---------------------------------------------------------------------------
function FX.Start(o: any): any
	local caster: Model = o.Caster
	local def = o.Def
	local TL = def.Timeline
	local B = def.Beam
	local BW = B.Width or 1.6
	local DRAIN = TL.Drain or 0.24
	local maid = U.Maid()
	local h: any = { Alive = true, Phase = "Charge" }
	local seed = math.random() * 1000

	local model = Instance.new("Folder")
	model.Name = "AzureTide_" .. caster.Name
	model.Parent = U.Holder()
	maid:Give(model)

	-- every arc of this cast (the charge's, the beam's, its end ball's)
	local arcs = arcSystem(model, 150)

	local root = caster:FindFirstChild("HumanoidRootPart") :: BasePart?
	local function part(name: string): BasePart?
		local p = caster:FindFirstChild(name)
		return if p and p:IsA("BasePart") and p.Transparency < 0.9 then p else nil
	end

	-- the hands: each palm's point (an R6 right palm faces -X, a left one +X), and the way the arms
	-- point (shoulder to hand) - the sphere is held just past the cupped palms, never inside an arm
	local function palm(a: BasePart?, side: number): Vector3?
		if not a then
			return nil
		end
		local half = a.Size.Y * 0.5
		return a.CFrame:PointToWorldSpace(Vector3.new(side * a.Size.X * 0.15, -(half + 0.05), 0))
	end
	local function hands(): (Vector3?, Vector3?, Vector3)
		local ra, la = part("Right Arm"), part("Left Arm")
		local r = palm(ra, -1)
		local l = palm(la, 1)
		local dir = Vector3.zero
		if ra then
			dir -= ra.CFrame.UpVector
		end
		if la then
			dir -= la.CFrame.UpVector
		end
		dir = if dir.Magnitude > 1e-3 then dir.Unit else (if root then root.CFrame.LookVector else Vector3.zAxis)
		return r or l, l or r, dir
	end

	-- the body the sphere must never sink into (the arms hold it: they may touch it)
	local function boxSigned(p: BasePart, at: Vector3): (number, Vector3)
		local cf = p.CFrame
		local q = cf:PointToObjectSpace(at)
		local hs = p.Size * 0.5
		local out = Vector3.new(q.X - math.clamp(q.X, -hs.X, hs.X), q.Y - math.clamp(q.Y, -hs.Y, hs.Y), q.Z - math.clamp(q.Z, -hs.Z, hs.Z))
		if out.Magnitude > 1e-4 then
			return out.Magnitude, cf:VectorToWorldSpace(out.Unit)
		end
		local px, py, pz = hs.X - math.abs(q.X), hs.Y - math.abs(q.Y), hs.Z - math.abs(q.Z)
		if px <= py and px <= pz then
			return -px, cf:VectorToWorldSpace(Vector3.new(if q.X >= 0 then 1 else -1, 0, 0))
		elseif py <= pz then
			return -py, cf:VectorToWorldSpace(Vector3.new(0, if q.Y >= 0 then 1 else -1, 0))
		end
		return -pz, cf:VectorToWorldSpace(Vector3.new(0, 0, if q.Z >= 0 then 1 else -1))
	end
	local BODY = { "Torso", "Head", "Left Leg", "Right Leg", "UpperTorso", "LowerTorso" }
	-- push a point out until it is `need` clear of the body; returns it and how clear it ended up
	local function clearOfBody(at: Vector3, need: number): (Vector3, number)
		local p = at
		for _ = 1, 2 do
			for _, name in ipairs(BODY) do
				local bp = part(name)
				if bp then
					local d, n = boxSigned(bp, p)
					if d < need then
						p += n * (need - d)
					end
				end
			end
		end
		local least = math.huge
		for _, name in ipairs(BODY) do
			local bp = part(name)
			if bp then
				least = math.min(least, (boxSigned(bp, p)))
			end
		end
		return p, least
	end
	-- the world round a point: pushed off any surface closer than r, and the room it really has
	local PROBES = { Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }
	local function roomFor(at: Vector3, r: number): (Vector3, number)
		local push = Vector3.zero
		local nearest = math.huge
		for _, d in ipairs(PROBES) do
			local hit = o.World(at, d * r * 1.6)
			if hit then
				local dist = (hit.Position - at).Magnitude
				nearest = math.min(nearest, dist)
				push -= d * math.max(0, r * 1.2 - dist) * 0.6
			end
		end
		if push.Magnitude > 0.7 then
			push = push.Unit * 0.7
		end
		local room = if nearest < math.huge then within((nearest + push.Magnitude) / 1.45, math.min(0.3, r), r) else r
		return at + push, room
	end

	-------------------------------------------------------------------
	-- the sphere
	-------------------------------------------------------------------
	local ball = U.Part({ Name = "Sphere", Shape = Enum.PartType.Ball, Size = Vector3.one })
	ball.Parent = model
	local ballAtt = att(ball, "Center")
	local ballLight = light(ball, rgb(55, 150, 255))
	local function mesh(name: string, props: { [string]: any }): BasePart?
		local tpl = template(name)
		if not tpl then
			return nil
		end
		local p = U.Solid(tpl, props)
		p.Size = Vector3.one * 0.05
		p.Transparency = 1
		p.Parent = model
		return p
	end
	-- a solid heart (a white-hot core in an azure body), v80's swirl round it and its force field skin
	-- - the sphere has depth from every side
	local core = mesh("SphereHD", { Material = Enum.Material.Neon, Color = C_HOT })
	local body = mesh("SphereHD", { Material = Enum.Material.Neon, Color = C_ROYAL })
	local swirl = mesh("Swirl", { Material = Enum.Material.Neon, Color = C_DEEP })
	local skin = mesh("SphereHD", { Material = Enum.Material.ForceField, Color = C_AZURE })
	-- its crackling lightning cage (the Lightning pack's strike cluster, spun and flickered)
	local cage = mesh("Strike", { Material = Enum.Material.Neon, Color = C_ICE })

	-- the sphere's textured layers, inside out; each one sized by the sphere's radius every frame. Every
	-- one sits INSIDE the 3D sphere (no halo past its skin: nothing reads as a stack of circles)
	type SLayer = { E: ParticleEmitter, K0: number, K1: number, Z: number }
	local sLayers: { SLayer } = {}
	local function layerOn(parent: Attachment, k0: number, k1: number, z: number, p: { [string]: any }): ParticleEmitter
		local e = emitter(parent, p)
		e.LockedToPart = true
		table.insert(sLayers, { E = e, K0 = k0, K1 = k1, Z = z })
		return e
	end
	local function sLayer(k0: number, k1: number, z: number, p: { [string]: any }): ParticleEmitter
		return layerOn(ballAtt, k0, k1, z, p)
	end
	-- (a bright sky turns stacked additive light to white: only the electricity is fully emissive; the
	-- body's layers are blended, so it reads as an azure sphere, not a white smear)
	local sPlasma = sLayer(1.2, 1.35, 0.9, { Name = "Plasma", Brightness = 0.85, Texture = T.PlasmaBall, Color = cs(C_AZURE, C_ROYAL, C_DEEP), Transparency = ns(0, 0.8, 0.3, 0.45, 1, 1), Lifetime = nr(0.18, 0.26), Rotation = nr(0, 360), RotSpeed = nr(-240, 240) })
	local sChaos = sLayer(1.3, 1.45, 0.92, { Name = "Chaos", Texture = T.Chaos, Brightness = 0.6, Color = cs(C_CYAN, C_AZURE), Transparency = ns(0, 0.4, 1, 1), Lifetime = nr(0.08, 0.13), Rotation = nr(0, 360) })
	local sSwirlA = sLayer(1.35, 1.45, 0.7, { Name = "SwirlA", Texture = T.Swirl, Color = cs(rgb(22, 64, 200), rgb(12, 36, 150)), LightEmission = 0.1, Transparency = ns(0, 1, 0.2, 0.35, 1, 1), Lifetime = nr(0.22, 0.3), Rotation = nr(0, 360), RotSpeed = nr(420, 700) })
	local sSwirlB = sLayer(1.5, 1.4, 0.8, { Name = "SwirlB", LightEmission = 0.45, Texture = T.Swirl, Color = cs(C_AZURE, C_ROYAL, C_DEEP), Transparency = ns(0, 1, 0.25, 0.4, 1, 1), Lifetime = nr(0.25, 0.35), Rotation = nr(0, 360), RotSpeed = nr(-640, -380) })
	local sCrescent = sLayer(1.55, 1.8, 0.75, { Name = "Crescents", Brightness = 0.85, Texture = T.Crescent, Color = cs(C_CYAN, C_AZURE, C_MID), Transparency = ns(0, 1, 0.25, 0.35, 1, 1), Lifetime = nr(0.16, 0.24), Rotation = nr(0, 360), RotSpeed = nr(620, 950) })
	local sArcs = sLayer(1.55, 1.75, 0.95, with(book("4x4"), { Name = "Arcs", Texture = T.ArcBall, Brightness = 0.85, Color = cs(C_ICE, C_CYAN), Transparency = ns(0, 0.05, 1, 0.5), Lifetime = nr(0.12, 0.18), Rotation = nr(0, 360) }))
	local sArcBurst = sLayer(1.6, 1.95, 0.9, { Name = "ArcBurst", Texture = T.ArcBurst, Color = cs(C_HOT, C_LIGHT), Transparency = ns(0, 0.45, 1, 1), Lifetime = nr(0.08, 0.12), Rotation = nr(0, 360) })

	-- AT ITS LARGEST IT IS A BLUE BLACK HOLE: a void at its heart that swallows the light, and the
	-- ElectricShockwave pack's rings spun flat round it - a crackling accretion ring, tilted toward the
	-- view behind the caster - while lightning spirals into it. It collapses into white-hot light as it
	-- is crushed down
	local void = mesh("SphereHD", { Material = Enum.Material.Neon, Color = rgb(34, 110, 255) })
	local ringA = mesh("Shock", { Material = Enum.Material.Neon, Color = C_CYAN })
	local ringB = mesh("Shock", { Material = Enum.Material.Neon, Color = C_AZURE })

	-- the place's own ball pack layered in, recoloured in the sphere's blues: Big Ball-01's flames
	-- (azure) and ash (navy - the dark that gives the light its shape) licking off its surface, its
	-- specks drawn into it, motes at its heart
	type PLayer = { E: ParticleEmitter, Size: NumberSequence, K: number, Speed: number, Rate: number, Phase: string, Z: number }
	local pLayers: { PLayer } = {}
	local ballPack = asset("BallPack")
	local function packLayer(name: string, parent: Instance, k: number, speed: number, rate: number, phase: string, z: number, props: { [string]: any })
		local tpl = ballPack and ballPack:FindFirstChild(name)
		if not (tpl and tpl:IsA("ParticleEmitter")) then
			return
		end
		local e = tpl:Clone()
		e.Enabled = false
		e.Rate = 0
		e.LockedToPart = true
		e.Acceleration = Vector3.zero
		for key, v in pairs(props) do
			(e :: any)[key] = v
		end
		e.Parent = parent
		table.insert(pLayers, { E = e, Size = e.Size, K = k, Speed = speed, Rate = rate, Phase = phase, Z = z })
	end
	local onSphere = { Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward, SpreadAngle = Vector2.new(25, 25) }
	packLayer("Fire1", ball, 0.42, 1.6, 55, "grow", 0.88, with(onSphere, { Name = "PackFlames", Color = cs(C_AZURE, C_ROYAL, C_DEEP), LightEmission = 0.35, LightInfluence = 0, Drag = 2, Lifetime = nr(0.35, 0.5), Rotation = nr(0, 360), RotSpeed = nr(-120, 120) }))
	packLayer("Ash1", ball, 0.4, 1.2, 26, "grow", 0.6, with(onSphere, { Name = "PackAsh", Color = cs(rgb(18, 54, 190), rgb(10, 30, 130)), LightEmission = 0.1, LightInfluence = 0, Transparency = ns(0, 0.15, 1, 1), Drag = 2, Lifetime = nr(0.35, 0.5), Rotation = nr(0, 360) }))
	packLayer("FireSpecs1", ball, 0.32, -2.2, 50, "surge", 0.96, with(onSphere, { Name = "PackSpecks", Color = cs(C_HOT, C_CYAN), LightEmission = 0.8, LightInfluence = 0, Lifetime = nr(0.35, 0.45), SpreadAngle = Vector2.new(0, 0) }))
	packLayer("Main-Core-02", ballAtt, 1.6, 0.9, 40, "form", 0.97, { Name = "PackMotes", Color = cs(C_HOT, C_CYAN), LightEmission = 1, LightInfluence = 0 })

	-- twinkles over its surface (sparks, not discs)
	local twinkle = emitter(ball, with(book("2x2"), { Name = "Twinkle", Texture = T.Spark, Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, Color = cs(C_WHITE, C_ICE), Transparency = ns(0, 0.1, 1, 1), Lifetime = nr(0.12, 0.2), Rotation = nr(0, 360), LockedToPart = true, ZOffset = 1 }))

	-- the hands crackle (the Electricity pack's crackle, small, in each palm)
	local handFx: { ParticleEmitter } = {}
	for _, name in ipairs({ "Right Arm", "Left Arm" }) do
		local a = part(name)
		if a then
			local ha = Instance.new("Attachment")
			ha.Name = "AzureTideHand"
			ha.Position = Vector3.new(0, -1, 0)
			ha.Parent = a
			maid:Give(ha)
			table.insert(handFx, emitter(ha, with(book("4x4"), { Name = "HandCrackle", Texture = T.Crackle, Color = cs(C_ICE, C_CYAN), Brightness = 2, Size = ns(0, 0.9, 1, 1.25), Transparency = ns(0, 0.6, 0.3, 0.05, 1, 1), Lifetime = nr(0.2, 0.25), Rotation = nr(0, 360), LockedToPart = true, ZOffset = 0.4 })))
		end
	end

	-- the ground under the caster stirs (v80's dust and motes)
	local groundPart = U.Part({ Name = "Ground", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 9, 9) })
	groundPart.Parent = model
	local gDust = emitter(groundPart, { Name = "Dust", Texture = T.Smoke, Shape = Enum.ParticleEmitterShape.Disc, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward, EmissionDirection = Enum.NormalId.Right, Color = cs(C_DUST), LightEmission = 0, LightInfluence = 1, Size = ns(0, 1.2, 1, 2.8), Transparency = ns(0, 1, 0.3, 0.8, 1, 1), Lifetime = nr(0.8, 1.2), Speed = nr(2, 4), Rotation = nr(0, 360), RotSpeed = nr(-40, 40) })
	local gMotes = emitter(groundPart, { Name = "Motes", Texture = T.Dots, Shape = Enum.ParticleEmitterShape.Disc, ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume, EmissionDirection = Enum.NormalId.Right, Color = cs(rgb(150, 205, 255)), LightEmission = 0.6, Size = ns(0, 0.12, 1, 0.06), Transparency = ns(0, 0.2, 1, 1), Lifetime = nr(0.8, 1.3), Speed = nr(2, 5), Acceleration = Vector3.new(0, 2, 0), Drag = 1 })

	-------------------------------------------------------------------
	-- the beam (built now, switched on at the release): FULLY 3D AND CONTINUOUS. Four nested layers
	-- - a white-hot core, a cyan layer, the azure body and a force-field shell - each one a single rod
	-- from its flare to the end ball, and a flare (a stretched sphere: a smooth teardrop) where it pours
	-- out of the sphere. Each layer flares a little further out than the one inside it, so the beam
	-- blooms out of the hands into its full width. Diameters x Width x its size now (Beam.Width)
	-------------------------------------------------------------------
	local origin = U.Part({ Name = "Origin" })
	origin.Parent = model
	local tail = U.Part({ Name = "End" })
	tail.Parent = model
	local surface = att(tail, "Surface")
	local endLight = light(tail, C_LIGHT)
	local muzzleLight = light(origin, C_ICE)

	type BLayer = { Cyl: BasePart, Neck: BasePart?, K: number, Off: number, Tr: number, Color: Color3 }
	local bLayers: { BLayer } = {}
	local function layer(name: string, k: number, off: number, tr: number, color: Color3, mat: Enum.Material)
		local cyl = U.Part({ Name = name, Shape = Enum.PartType.Cylinder, Material = mat, Color = color, Transparency = 1 })
		cyl.Parent = model
		local neck = mesh("SphereHD", { Name = name .. "Flare", Material = mat, Color = color })
		table.insert(bLayers, { Cyl = cyl, Neck = neck, K = k, Off = off, Tr = tr, Color = color })
	end
	layer("Core", 1.0, 0, 0, C_WHITE, Enum.Material.Neon)
	layer("Inner", 1.9, 0.1, 0.25, C_CYAN, Enum.Material.Neon)
	layer("Body", 2.9, 0.24, 0.55, C_AZURE, Enum.Material.Neon)
	layer("Shell", 3.6, 0.4, 0.05, C_LIGHT, Enum.Material.ForceField)
	local SHELL = B.Shell or 3.6

	-- its lightning: the Lightning pack's bolt (Sleeve) laid along it in lengths, each spun about the
	-- beam and flickered every few frames the way its own pack drives it - lightning wrapped all round
	-- it, from every side
	local MAX_SLEEVES = 8
	local sleeves: { BasePart } = {}
	for i = 1, MAX_SLEEVES do
		local s = mesh("Sleeve", { Name = "Lightning" .. i, Material = Enum.Material.Neon, Color = C_ICE })
		if s then
			sleeves[i] = s
		end
	end
	local sleeveState: { { Spin: number, Tr: number, Color: Color3 } } = {}
	for i = 1, MAX_SLEEVES do
		sleeveState[i] = { Spin = math.random() * TAU, Tr = 1, Color = C_ICE }
	end
	local nextSleeve = 0

	-- the surge that rushes down it into the end ball with every hit
	local pulse = mesh("SphereHD", { Name = "Surge", Material = Enum.Material.Neon, Color = C_ICE })

	-- the lights along it (they light the world it passes)
	local volume = U.Part({ Name = "Volume", Size = Vector3.new(4, 4, 1) })
	volume.Parent = model
	local volLights = {}
	for i = 1, 3 do
		local la = att(volume, "Light" .. i)
		volLights[i] = { Att = la, Light = light(la, C_MID) }
	end

	-------------------------------------------------------------------
	-- THE END BALL: the beam's head - the same layers as a ball, in a crackling lightning cage, with
	-- three bolts of the Thunder pack discharging out of it (evenly round, slowly turning)
	-------------------------------------------------------------------
	local eCore = mesh("SphereHD", { Name = "EndCore", Material = Enum.Material.Neon, Color = C_WHITE })
	local eBody = mesh("SphereHD", { Name = "EndBody", Material = Enum.Material.Neon, Color = C_AZURE })
	local eSwirl = mesh("Swirl", { Name = "EndSwirl", Material = Enum.Material.Neon, Color = C_ROYAL })
	local eSkin = mesh("SphereHD", { Name = "EndSkin", Material = Enum.Material.ForceField, Color = C_CYAN })
	local eCageA = mesh("Strike", { Name = "EndCage", Material = Enum.Material.Neon, Color = C_ICE })
	local eCageB = mesh("Spark", { Name = "EndSparks", Material = Enum.Material.Neon, Color = C_ARC })
	-- (the drain: a force-field shell crushing in on it)
	local eImplode = mesh("SphereHD", { Name = "Implode", Material = Enum.Material.ForceField, Color = C_ICE })
	local thunders: { BasePart } = {}
	for i = 1, 3 do
		local t = mesh("Thunder", { Name = "Discharge" .. i, Material = Enum.Material.Neon, Color = C_ARC })
		if t then
			table.insert(thunders, t)
		end
	end
	local endAtt = att(tail, "Ball")
	local eCrackle = emitter(endAtt, with(book("4x4"), { Name = "EndCrackle", Texture = T.Crackle, Color = cs(C_ARC, C_CYAN), Brightness = 3, Transparency = ns(0, 0.5, 0.25, 0, 1, 1), Lifetime = nr(0.2, 0.25), Rotation = nr(0, 360), Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface }))
	-- its smoke off the surface it grinds into (the Explosion pack's smoke)
	local endSmoke = emitter(surface, { Name = "Smoke", Texture = T.Smoke, EmissionDirection = Enum.NormalId.Top, Color = cs(rgb(150, 175, 205)), LightEmission = 0.1, LightInfluence = 0.8, Size = ns(0, 2.5, 1, 7), Transparency = ns(0, 0.6, 1, 1), Lifetime = nr(0.7, 1.1), Speed = nr(6, 12), SpreadAngle = Vector2.new(50, 50), Rotation = nr(0, 360), RotSpeed = nr(-30, 30), ZOffset = 3 })
	local endSparkle = emitter(surface, with(book("2x2"), { Name = "Sparkle", Texture = T.Spark, EmissionDirection = Enum.NormalId.Top, Color = cs(C_WHITE, C_ICE), Size = ns(0, 0.9, 1, 0.3), Transparency = ns(0, 0, 1, 0.6), Lifetime = nr(0.15, 0.3), Speed = nr(18, 34), SpreadAngle = Vector2.new(70, 70), Drag = 4, Rotation = nr(0, 360), ZOffset = 3 }))

	-- the ground under its path, stirred wherever it is close (v80's dust)
	local TRAIL = 8
	local trailPart = U.Part({ Name = "Trail" })
	trailPart.Parent = model
	local trailPts = {}
	for i = 1, TRAIL do
		local ta = att(trailPart, "T" .. i)
		trailPts[i] = {
			Att = ta,
			Dust = emitter(ta, { Name = "TrailDust", Texture = T.Smoke, EmissionDirection = Enum.NormalId.Top, Color = cs(C_DUST), LightEmission = 0.05, LightInfluence = 0.9, Size = ns(0, 1.6, 1, 5.5), Transparency = ns(0, 0.55, 1, 1), Lifetime = nr(0.6, 1.1), Speed = nr(5, 12), SpreadAngle = Vector2.new(40, 40), Rotation = nr(0, 360), RotSpeed = nr(-40, 40), Drag = 1.5 }),
			NextChunk = 0,
		}
	end

	-- DEBRIS: where it grinds into the floor the floor itself is torn out - chunks of that very floor (its
	-- material and colour, the place's own rock mesh in irregular sizes), thrown up and out under
	-- gravity, tumbling (a trail of dust behind each), bouncing and rolling to rest, then sinking smoothly
	-- away. They never touch a fighter (the Debris group) and there are never too many
	local meshes = asset("Meshes")
	local rockTpl = meshes and meshes:FindFirstChild("Rock")
	local liveChunks = 0
	local MAX_CHUNKS = 48
	local function floorLook(hit: RaycastResult?): (Color3, Enum.Material)
		local inst = hit and hit.Instance
		if inst and inst:IsA("Terrain") then
			local m = (hit :: RaycastResult).Material
			local ok, col = pcall(function()
				return (inst :: Terrain):GetMaterialColor(m)
			end)
			return if ok then col else rgb(112, 108, 102), m
		elseif inst and inst:IsA("BasePart") then
			return inst.Color, inst.Material
		end
		return rgb(112, 108, 102), Enum.Material.Slate
	end
	-- a piece of the ground itself: rock, stone, concrete - or, torn out of turf, a clod of soil with its
	-- grass still on top
	local GRASSY = { [Enum.Material.Grass] = true, [Enum.Material.LeafyGrass] = true }
	local SOIL = rgb(92, 70, 50)
	local function piece(col: Color3, mat: Enum.Material, size: number, anchored: boolean, spike: boolean?): (BasePart, { BasePart })
		local base = (rockTpl :: BasePart).Size
		local unit = base / math.max(base.X, base.Y, base.Z)
		local shade = 0.04 + math.random() * 0.14
		local turf = GRASSY[mat] == true
		local bodyP = U.Solid(rockTpl :: BasePart, {
			Anchored = anchored, CanCollide = not anchored, CastShadow = true, Transparency = 0,
			Material = if turf then Enum.Material.Ground else mat,
			Color = (if turf then SOIL else col):Lerp(Color3.new(0, 0, 0), shade),
		})
		bodyP.Size = if spike then Vector3.new(size * 0.55, size * 1.9, size * 0.55)
			else unit * size * Vector3.new(0.8 + math.random() * 0.5, 0.5 + math.random() * 0.35, 0.8 + math.random() * 0.5)
		bodyP.CollisionGroup = "Debris"
		local parts = { bodyP }
		if turf then
			-- (its grass, still growing on top of it)
			local top = U.Solid(rockTpl :: BasePart, { Anchored = anchored, CanCollide = false, Massless = true, CastShadow = true, Transparency = 0, Material = mat, Color = col:Lerp(Color3.new(0, 0, 0), shade * 0.5) })
			top.Size = Vector3.new(bodyP.Size.X * 1.05, bodyP.Size.Y * (if spike then 0.18 else 0.34), bodyP.Size.Z * 1.05)
			top.CollisionGroup = "Debris"
			top.CFrame = bodyP.CFrame * CFrame.new(0, bodyP.Size.Y * (if spike then 0.42 else 0.36), 0)
			if not anchored then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = bodyP
				weld.Part1 = top
				weld.Parent = top
			end
			top.Parent = bodyP
			table.insert(parts, top)
		end
		return bodyP, parts
	end
	-- a chunk of the ground at `at` (face `n`) thrown with `power`, `away` along the surface
	-- (`reserve`: chunks kept free for what comes after - the beam's grinding leaves room for the blast)
	local function chunk(at: Vector3, n: Vector3, hit: RaycastResult?, power: number, away: Vector3?, up: number?, reserve: number?)
		if not (rockTpl and rockTpl:IsA("BasePart")) or liveChunks >= MAX_CHUNKS - (reserve or 0) then
			return
		end
		local col, mat = floorLook(hit)
		local size = (0.3 + math.random() ^ 2.4 * 0.9) * power
		local rock, parts = piece(col, mat, size, false)
		rock.CFrame = CFrame.new(at + n * (size * 0.35)) * CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
		rock.Parent = U.Holder()
		liveChunks += 1
		-- thrown off the surface and out, the heavier ones lower and slower
		local out = away or (n:Cross(randomUnit()))
		out = if out.Magnitude > 1e-3 then out.Unit else basis(n)
		local heft = 1 / (0.6 + size / power)
		rock.AssemblyLinearVelocity = (n * (up or (16 + math.random() * 14)) + out * (9 + math.random() * 8)) * power * heft
		rock.AssemblyAngularVelocity = randomUnit() * (8 + math.random() * 12)
		-- a trail of dust while it flies
		local dust = emitter(rock, { Name = "DebrisDust", Texture = T.Smoke, Color = cs(col:Lerp(C_DUST, 0.5)), LightEmission = 0, LightInfluence = 1, Size = ns(0, size * 0.7, 1, size * 2.2), Transparency = ns(0, 0.55, 1, 1), Lifetime = nr(0.35, 0.55), Rate = 18, Rotation = nr(0, 360), RotSpeed = nr(-60, 60), Speed = nr(0.5) })
		dust.Enabled = true
		task.delay(0.8 + math.random() * 0.3, function()
			dust.Enabled = false
		end)
		-- it settles, then sinks away into the floor and is gone
		local life = 2.4 + math.random() * 1.2
		local rest: CFrame? = nil
		animate(life, 0.7, function(k)
			if not rest then
				rock.Anchored = true
				rock.CanCollide = false
				rest = rock.CFrame
			end
			rock.CFrame = (rest :: CFrame) - Vector3.new(0, k * rock.Size.Y * 0.9, 0)
			for _, p in ipairs(parts) do
				p.Transparency = k ^ 2
			end
		end, function()
			rock:Destroy()
			liveChunks -= 1
		end)
		Debris:AddItem(rock, life + 2)
	end
	-- a rock spike torn up out of the ground at `at` (face `up`), leaning out along `out`: it bursts up
	-- out of the floor, holds, and sinks back into it
	local function spike(at: Vector3, up: Vector3, out: Vector3, height: number, hit: RaycastResult?, delay: number, holder: Instance)
		if not (rockTpl and rockTpl:IsA("BasePart")) then
			return
		end
		local col, mat = floorLook(hit)
		local rock, parts = piece(col, mat, height / 1.9, true, true)
		local lean = CFrame.fromAxisAngle(up:Cross(out).Magnitude > 1e-3 and up:Cross(out).Unit or Vector3.xAxis, math.rad(28 + math.random() * 8))
		local frame = U.Up(at, up) * CFrame.Angles(0, math.random() * TAU, 0)
		local tilt = (lean * (frame - frame.Position)) + at
		local hidden = tilt * CFrame.new(0, -rock.Size.Y * 0.62, 0)
		local shown = tilt * CFrame.new(0, rock.Size.Y * 0.22, 0)
		rock.CFrame = hidden
		for _, p in ipairs(parts) do
			p.Transparency = 1
		end
		rock.Parent = holder
		local top = parts[2]
		local topRel = CFrame.new(0, rock.Size.Y * 0.42, 0)
		local HOLD = 1.5
		animate(delay, 0.14 + HOLD + 0.6, function(k)
			local t = k * (0.14 + HOLD + 0.6)
			local cf
			if t < 0.14 then
				-- (bursting up: it overshoots and settles)
				local e = t / 0.14
				cf = hidden:Lerp(shown, 1 - (1 - e) ^ 3 + 0.12 * math.sin(e * math.pi))
				for _, p in ipairs(parts) do
					p.Transparency = 0
				end
			elseif t < 0.14 + HOLD then
				cf = shown
			else
				local e = (t - 0.14 - HOLD) / 0.6
				cf = shown:Lerp(hidden, e * e)
			end
			rock.CFrame = cf
			if top then
				top.CFrame = cf * topRel
			end
		end, function()
			rock:Destroy()
		end)
		Debris:AddItem(rock, delay + HOLD + 2)
	end

	-------------------------------------------------------------------
	-- sound
	-------------------------------------------------------------------
	local sounds = asset("Sounds")
	local function sfx(name: string, parent: Instance, props: any?): Sound?
		local tpl = sounds and sounds:FindFirstChild(name)
		if not (tpl and tpl:IsA("Sound")) then
			return nil
		end
		local s = U.Sound(tpl.SoundId, parent, { Volume = tpl.Volume, PlaybackSpeed = tpl.PlaybackSpeed, Looped = tpl.Looped })
		-- (its full level is the template's: a sound that starts silent fades up to it)
		s:SetAttribute("Base", tpl.Volume)
		if props then
			for k, v in pairs(props) do
				(s :: any)[k] = v
			end
		end
		return s
	end
	local hum = sfx("Hum", ball, { Volume = 0 })
	local crackle = sfx("Crackle", ball, { Volume = 0 })
	local rise = sfx("Rise", ball)
	local roar = sfx("Roar", origin, { Volume = 0 })
	local endLoop = sfx("ImpactLoop", tail, { Volume = 0 })
	if hum then
		hum:Play()
	end
	local played: { [string]: boolean } = {}
	local function once(name: string, parent: Instance, props: any?)
		if played[name] then
			return
		end
		played[name] = true
		local s = sfx(name, parent, props)
		if s then
			s:Play()
			s.Ended:Once(function()
				s:Destroy()
			end)
			maid:Give(s)
		end
	end
	local function oneShot(name: string, at: Vector3, props: any?)
		local sp = U.Part({ CFrame = CFrame.new(at) })
		sp.Parent = U.Holder()
		Debris:AddItem(sp, 7)
		local s = sfx(name, sp, props)
		if s then
			s:Play()
		end
	end

	-------------------------------------------------------------------
	-- state
	-------------------------------------------------------------------
	local aim = o.Aim()
	local firedAt: number? = nil
	local endedAt: number? = nil
	local cut = false -- (the beam was cut short: it dies away, no blast)
	local fizzled = false
	local visLen = 0
	local roomAll = 30 -- (the room the beam has all round its line, eased)
	local lift = 0 -- (how far the end ball is lifted off a floor it would sink into, eased)
	local lastTau = 0
	local nextInflow, nextSnap, nextPalm, nextShake, nextPulse, nextSkin, nextDischarge, nextFeed = 0, 0, 0, 0, 0, 0, 0, 0
	local palmSide = 1
	local sphereR = 0
	local fireR = 0.9 -- (the sphere's radius the moment it fired: the beam grows out of exactly that)
	local lastSized = -1
	local lastHitPop = -1
	local pulseFor = -1
	local pulseBorn = 0
	local thumpAt = -1 -- (os.clock of the last hit at its end: the end ball thumps)
	local landAt = -1 -- (...of its landing: it squashes)
	local landedOnce = false
	local stretch = 1 -- (the end ball stretched like a comet while it races out)
	local ballBase = 0 -- (the end ball's size, following the beam's)
	local tint: ColorCorrectionEffect? = nil -- (the caster's own view, tinted as the charge peaks)
	-- the beam as it is this frame (its arcs are re-struck against it)
	local bs = { P0 = Vector3.zero, Dir = Vector3.zAxis, From = 0, Len = 0, R = 1, G = 1, Side = Vector3.xAxis, Up = Vector3.yAxis, Ball = Vector3.zero, BallR = 1, Live = false }

	local function camera(profile: string, dir: Vector3?, scale: number?)
		if o.Camera then
			o.Camera(profile, dir, scale)
		end
	end
	-- a body near a moment feels it (never the caster: its own kicks are its own)
	local function nearKick(at: Vector3, radius: number, scale: number, profile: string?)
		if o.Mine then
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local d = (cam.Focus.Position - at).Magnitude
		if d < radius then
			camera(profile or "BeamNear", cam.Focus.Position - at, scale * math.clamp(1.2 - d / radius, 0.15, 1))
		end
	end
	local function flashFor(at: Vector3, strength: number, length: number)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local d = (cam.CFrame.Position - at).Magnitude
		screenFlash(strength * (if o.Mine then 1 else math.clamp(1.3 - d / 90, 0, 1)), length)
	end
	local function setTint(k: number)
		if not o.Mine then
			return
		end
		if k <= 0.001 then
			if tint then
				tint:Destroy()
				tint = nil
			end
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local t = tint
		if not t or t.Parent ~= cam then
			if t then
				t:Destroy()
			end
			t = Instance.new("ColorCorrectionEffect")
			t.Name = "AzureTideCharge"
			t.Parent = cam
			tint = t
		end
		local cc = t :: ColorCorrectionEffect
		cc.TintColor = Color3.new(1, 1, 1):Lerp(rgb(214, 234, 255), k)
		cc.Contrast = 0.1 * k
		cc.Saturation = 0.08 * k
		cc.Brightness = 0.025 * k
	end
	maid:Give(function()
		setTint(0)
	end)

	-------------------------------------------------------------------
	-- lightning of the charge
	-------------------------------------------------------------------
	-- drawn in: a bolt reaching in from round the hands and snapping into the sphere (it is pulled in
	-- as it lives)
	local function inflow(strength: number)
		local d = randomUnit()
		if d.Y < -0.4 then
			d = Vector3.new(d.X, -d.Y * 0.5, d.Z).Unit
		end
		local far = 3.6 + math.random() * 2.4
		arcs.Add(function(k: number)
			local c = ball.Position
			local r = math.max(0.1, sphereR)
			return jagged(c + d * (far * (1 - 0.55 * k) + r), c + d * r * 0.8, 6, 0.2)
		end, 0.14 + math.random() * 0.08, 0.05 + 0.07 * strength, if math.random() < 0.5 then C_ARC else C_ICE, 0.035)
	end
	-- off it: a bolt snapping off the unstable sphere (big ones fork)
	local function snap(r: number, big: boolean)
		local d = randomUnit()
		local reach = r * (if big then 2.4 else 1.7) + 0.6 + math.random() * (if big then 2 else 1.1)
		local bend = randomUnit() * reach * 0.25
		arcs.Add(function(_k: number)
			local c = ball.Position
			return jagged(c + d * sphereR * 0.85, c + d * reach, 5, 0.26, bend)
		end, 0.07 + math.random() * 0.07, if big then 0.13 else 0.08, C_ARC, 0.03)
		if big then
			local d2 = (d + randomUnit() * 0.8).Unit
			arcs.Add(function(_k: number)
				local c = ball.Position
				return jagged(c + d * reach * 0.55, c + d2 * reach * 0.95, 4, 0.3)
			end, 0.06 + math.random() * 0.05, 0.06, C_ICE, 0.03)
		end
	end
	-- a palm feeding it: an arc from one hand into the sphere (the hands take turns - left, right)
	local function palmArc(from: Vector3)
		arcs.Add(function(_k: number)
			local c = ball.Position
			local toward = from - c
			local d = if toward.Magnitude > 1e-3 then toward.Unit else Vector3.yAxis
			return jagged(from, c + d * sphereR * 0.8, 4, 0.22)
		end, 0.08 + math.random() * 0.05, 0.06, C_ARC, 0.03)
	end

	-------------------------------------------------------------------
	-- the moments
	-------------------------------------------------------------------
	local function release(from: Vector3, dir: Vector3)
		h.Phase = "Beam"
		firedAt = os.clock()
		-- (the beam's root is at the sphere from the very first frame: what is emitted there now starts there)
		origin.CFrame = U.Look(from, dir)
		fireR = math.max(sphereR, 0.4)
		visLen = 0
		setTint(0)
		twinkle.Enabled = false
		local cf = U.Look(from, dir)
		local holder = U.Holder()
		-- the pack's release burst off the hands (Beam Release: its smoke, flames and ash)
		fire("Release", cf, 0.2 * BW, holder, nil, nil, nil, 20)
		-- a mirrored pair of electric shockwave rings bursting off the hands, round the beam
		local s1, s2 = basis(dir)
		local tilt = math.rad(18)
		shockRing(from + dir * 0.6, (dir * math.cos(tilt) + s1 * math.sin(tilt)).Unit, fireR * 2, 9 * BW, 0.34, C_ICE, holder, 0.28)
		shockRing(from + dir * 0.6, (dir * math.cos(tilt) - s1 * math.sin(tilt)).Unit, fireR * 2, 9 * BW, 0.34, C_CYAN, holder, 0.28)
		-- lightning bursting off the hands all round the beam, evenly
		for i = 0, 5 do
			local ang = i * TAU / 6
			local out = (s1 * math.cos(ang) + s2 * math.sin(ang))
			local tip = (dir * 0.55 + out).Unit
			arcs.Add(function(_k: number)
				return jagged(from + out * fireR, from + tip * (3.4 + fireR * 2), 5, 0.24)
			end, 0.16, 0.12, C_ARC, 0.035)
		end
		-- the ground under the caster takes the blast
		if root then
			local g = o.World(root.Position, Vector3.new(0, -8, 0))
			if g then
				fire("GroundBlast", U.Up(g.Position + g.Normal * 0.2, g.Normal), 0.3 * BW, holder, nil, function(e)
					e.ZOffset += 3
				end)
			end
		end
		-- a white-hot pop that starts exactly the sphere's size, the light and the view
		fireball(from, fireR * 2, 5 * BW, 0.22, holder)
		flashLight(from, C_ICE, 6, 32, 0.4, nil, C_MID)
		flashFor(from, 0.7, 0.3)
		once("Blast", origin)
		once("BlastCrack", origin)
		once("BeamStart", origin)
		if roar then
			roar.Volume = roar:GetAttribute("Base") :: number
			roar:Play()
		end
		if endLoop then
			endLoop:Play()
		end
		if rise then
			rise:Stop()
		end
		if o.Mine then
			camera("BeamFire", -dir, 1)
			if o.Fov then
				o.Fov(6)
			end
		else
			nearKick(from, 45, 1)
		end
	end

	-- THE BLAST: the end ball detonates - compact (exactly BlastRadius round: its hitbox), symmetric
	-- (everything round it evenly spaced, one random turn for the whole pattern), electric, and its
	-- aftermath settles: chunks land, spikes sink, the smoke drifts, the crackle and the light die down
	local blasted = false
	local function detonate(at: Vector3, dir: Vector3, n: Vector3?, ballD: number)
		if blasted then
			return
		end
		blasted = true
		local holder = Instance.new("Folder")
		holder.Name = "AzureTideBlast"
		holder.Parent = U.Holder()
		Debris:AddItem(holder, 8)
		-- its heart stands off the surface it hit (never half inside a wall, a floor or a ceiling)
		local c = if n then at + n * 1.2 else at
		-- how much room it has: a blast in a corridor is a corridor's blast, not one through the walls
		local free, probes = 0, 0
		for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis, Vector3.new(1, 1, 1).Unit, Vector3.new(-1, 1, -1).Unit, Vector3.new(1, 1, -1).Unit, Vector3.new(-1, 1, 1).Unit }) do
			local hit = o.World(c, d * 16)
			free += if hit then (hit.Position - c).Magnitude else 16
			probes += 1
		end
		local S = math.clamp((free / probes) / 12, 0.7, 1)
		local R = B.BlastRadius * S
		local g = o.World(c + Vector3.new(0, 1, 0), Vector3.new(0, -(R + 4), 0))
		local gUp = if g then g.Normal else Vector3.yAxis
		local gAt = if g then g.Position + g.Normal * 0.1 else c - Vector3.new(0, R * 0.4, 0)
		-- (its heart stands a little off the ground: the dome rises out of it)
		if g then
			local hc = (c - gAt):Dot(gUp)
			if hc < 0.3 * R then
				c += gUp * (0.3 * R - hc)
			end
		end
		local heart = U.Up(c, gUp)
		local t1, t2 = basis(gUp)
		local turn = math.random() * TAU
		local function round(i: number, count: number): Vector3
			local a = turn + i * TAU / count
			return t1 * math.cos(a) + t2 * math.sin(a)
		end
		local near = g ~= nil and (gAt - c).Magnitude < R

		-- the white-hot core: from the end ball's own size to most of the dome, cooling white -> cyan
		glowBall(c, ballD * 0.8, R * 1.15, 0.3, holder, Enum.Material.Neon, C_WHITE, C_CYAN, 0)
		-- the energy dome and its force-field skin, cooling to deep blue as they burn off
		glowBall(c, ballD, R * 2, 0.55, holder, Enum.Material.Neon, C_LIGHT, C_DEEP, 0.35)
		glowBall(c, ballD * 1.1, R * 2.1, 0.5, holder, Enum.Material.ForceField, C_ICE, C_ROYAL, 0)
		-- the electric shockwaves: one level with the ground, and a pair tilted mirror-wise across the
		-- beam's line
		shockRing(if near then gAt + gUp * 0.4 else c, gUp, R * 0.5, R * 2.5, 0.5, C_ICE, holder, 0.26)
		local flat = dir - gUp * dir:Dot(gUp)
		flat = if flat.Magnitude > 1e-3 then flat.Unit else t1
		for _, sgn in ipairs({ 1, -1 }) do
			local up2 = CFrame.fromAxisAngle(flat, sgn * math.rad(52)):VectorToWorldSpace(gUp)
			shockRing(c, up2, R * 0.4, R * 2.1, 0.42, C_CYAN, holder, 0.24)
		end
		-- 3D lightning: eight rays evenly round along the ground, four rising between them - re-struck
		-- as they live, then crackling over the crater while it cools
		local zap = arcSystem(holder, 140)
		local function groundAt(p: Vector3): Vector3
			local q = o.World(p + gUp * 3, -gUp * 8)
			return if q then q.Position + q.Normal * 0.15 else p
		end
		for i = 0, 7 do
			local out = round(i, 8)
			local tip = groundAt(gAt + out * R * (0.92 + 0.08 * (i % 2)))
			zap.Add(function(_k: number)
				return jagged(c + out * R * 0.15, tip, 7, 0.12)
			end, 0.34, 0.24 * S, C_ARC, 0.04)
		end
		for i = 0, 3 do
			local out = round(i + 0.5, 4)
			local d = (out * math.cos(math.rad(48)) + gUp * math.sin(math.rad(48))).Unit
			zap.Add(function(_k: number)
				return jagged(c + d * R * 0.15, c + d * R * 0.95, 6, 0.14)
			end, 0.26, 0.18 * S, C_ICE, 0.04)
		end
		-- the Thunder pack's bolts, six evenly round, thrown out of the heart
		local thunderTpl = template("Thunder")
		if thunderTpl then
			for i = 0, 5 do
				local out = round(i + 0.25, 6)
				local d = (out * math.cos(math.rad(20)) + gUp * math.sin(math.rad(20))).Unit
				local tb = U.Solid(thunderTpl, { Material = Enum.Material.Neon, Color = C_ARC, Transparency = 1 })
				tb.Parent = holder
				local len = R * 0.95
				animate(0.02 * (i % 2), 0.3, function(k)
					local l = len * (0.5 + 0.5 * (1 - (1 - k) ^ 3))
					tb.Size = Vector3.new(l * 0.17, l, l * 0.2)
					tb.CFrame = U.Up(c + d * (R * 0.12 + l * 0.5), d) * CFrame.Angles(0, math.random() * TAU, 0)
					tb.Transparency = math.min(1, k ^ 2 + (if math.random() < 0.2 then 0.5 else 0))
				end, function()
					tb:Destroy()
				end)
			end
		end
		-- the packs' smoke and dust (the Explosion pack's, the FinalExplosion's small blast) - kept to
		-- the dome's size
		fire("EndBlastSmall", heart, 0.8 * S, holder, 0.8, nil, true, R * 1.6)
		if g then
			fire("Blast", U.Up(gAt + gUp * 0.3, gUp) * CFrame.Angles(0, turn, 0), 0.5 * S, holder, 0.7, nil, true, R * 1.8)
		end
		-- the ground torn up: a ring of rock spikes round the crater (tall and short in turn), and chunks
		-- of that very ground thrown evenly all round, steep and low in turn
		if g and near then
			for i = 0, 9 do
				local out = round(i, 10)
				local p = gAt + out * R * (if i % 2 == 0 then 0.62 else 0.54)
				local q = o.World(p + gUp * 3, -gUp * 7)
				if q then
					spike(q.Position, q.Normal, out, R * (if i % 2 == 0 then 0.42 else 0.3), q, 0.02 * (i % 2), holder)
				end
			end
			for i = 0, 11 do
				local out = round(i + 0.5, 12)
				local q = o.World(gAt + out * R * 0.3 + gUp * 3, -gUp * 6)
				chunk(if q then q.Position else gAt + out * R * 0.3, gUp, q or g, 1.3 * S, out, if i % 2 == 0 then 30 else 18)
			end
		end
		-- the light: white-hot, cooling through cyan to a deep blue as it dies
		flashLight(c + gUp * 2, C_WHITE, 14, R * 3.4, 1.9, holder, C_ROYAL)
		flashFor(c, 0.9, 0.45)
		oneShot("End", c)
		oneShot("EndCrack", c)
		oneShot("Blast", c, { PlaybackSpeed = 0.72 })
		nearKick(c, 70, 1.2, "BeamBoomNear")
		if o.Mine then
			camera("BeamBoom", dir, 1)
		end
		-- the aftermath: lightning hopping over the crater floor, ever less often, while it cools
		local nextHop = 0.25
		local AFTER = 1.7
		local t0 = os.clock()
		animate(0, AFTER, function(k)
			local now = os.clock()
			zap.Step(now)
			local t = now - t0
			if t >= nextHop and k < 0.85 then
				nextHop = t + 0.07 + 0.25 * k
				local a = groundAt(gAt + round(math.random() * 12, 12) * R * (0.2 + math.random() * 0.6))
				local v = randomUnit()
				local b = groundAt(a + (v - gUp * v:Dot(gUp)) * R * 0.35)
				local col = C_ARC:Lerp(C_LIGHT, k)
				zap.Add(function(_k: number)
					return jagged(a + gUp * 0.2, b + gUp * 0.2, 5, 0.22, gUp * R * 0.08)
				end, 0.1 + math.random() * 0.06, 0.1 * (1 - 0.5 * k) * S + 0.04, col, 0.035)
			end
		end, function()
			zap.Clear()
		end)
	end

	local function collapse(why: string)
		if endedAt then
			return
		end
		endedAt = os.clock()
		h.Phase = "Collapse"
		cut = why == "Interrupted"
		for _, e in ipairs({ endSmoke, endSparkle, eCrackle }) do
			e.Enabled = false
		end
		for _, L in ipairs(sLayers) do
			L.E.Enabled = false
		end
		for _, P in ipairs(pLayers) do
			P.E.Enabled = false
		end
		if not cut then
			-- (the end ball, as it is this frame, detonates)
			-- (an effect never holds the fight up: whatever ends the cast carries on if the blast fails)
			local n = surface:GetAttribute("Normal")
			local ok, err = pcall(function()
				if bs.Live then
					detonate(bs.Ball, aim, if typeof(n) == "Vector3" then n else nil, bs.BallR * 2)
				else
					detonate(origin.Position + aim * math.max(visLen, 1), aim, nil, 2 * BW)
				end
			end)
			if not ok then
				warn("[AzureTide] blast:", err)
			end
			arcs.Clear()
		end
		once("Falloff", origin)
		if o.Mine and o.Fov then
			o.Fov(0)
		end
	end

	local function fizzle()
		if fizzled then
			return
		end
		fizzled = true
		h.Phase = "Fizzle"
		endedAt = os.clock()
		setTint(0)
		for _, L in ipairs(sLayers) do
			L.E.Enabled = false
		end
		for _, P in ipairs(pLayers) do
			P.E.Enabled = false
		end
		for _, e in ipairs({ twinkle, gDust, gMotes }) do
			e.Enabled = false
		end
		for _, e in ipairs(handFx) do
			e.Enabled = false
		end
		if sphereR > 0.05 then
			-- the gathered energy bursts apart: a pop and its lightning scattering, evenly round
			local c = ball.Position
			fireball(c, sphereR * 2, sphereR * 4.5, 0.18)
			for i = 0, 5 do
				local d = Vector3.new(math.cos(i * TAU / 6), (i % 2 == 0) and 0.5 or -0.3, math.sin(i * TAU / 6)).Unit
				local r = sphereR
				arcs.Add(function(_k: number)
					return jagged(c + d * r * 0.8, c + d * (r * 2.4 + 1.2), 5, 0.28)
				end, 0.14, 0.09, C_ARC, 0.03)
			end
			sPlasma:Emit(3)
			sArcs:Emit(3)
			once("Fizzle", ball)
		end
		if rise then
			rise:Stop()
		end
		if o.Mine and o.Fov then
			o.Fov(0)
		end
	end

	-------------------------------------------------------------------
	-- every frame
	-------------------------------------------------------------------
	local function setSolid(p: BasePart?, size: number, cf: CFrame, transparency: number)
		if not p then
			return
		end
		if size <= 0.02 or transparency >= 0.995 then
			p.Transparency = 1
			return
		end
		p.Size = Vector3.one * size
		p.CFrame = cf
		p.Transparency = transparency
	end
	local function setShape(p: BasePart?, size: Vector3, cf: CFrame, transparency: number)
		if not p then
			return
		end
		if size.X <= 0.02 or size.Y <= 0.02 or size.Z <= 0.02 or transparency >= 0.995 then
			p.Transparency = 1
			return
		end
		p.Size = size
		p.CFrame = cf
		p.Transparency = transparency
	end
	local function hideBeam()
		for _, L in ipairs(bLayers) do
			L.Cyl.Transparency = 1
			if L.Neck then
				L.Neck.Transparency = 1
			end
		end
		for _, s in pairs(sleeves) do
			s.Transparency = 1
		end
		for _, p in pairs({ eCore, eBody, eSwirl, eSkin, eCageA, eCageB, eImplode, pulse }) do
			p.Transparency = 1
		end
		for _, t in ipairs(thunders) do
			t.Transparency = 1
		end
		bs.Live = false
	end

	local function finish()
		if not h.Alive then
			return
		end
		h.Alive = false
		RunService:UnbindFromRenderStep(h.Bind)
		hideBeam()
		arcs.Clear()
		for _, p in pairs({ core, body, swirl, skin, void, cage, ringA, ringB }) do
			p.Transparency = 1
		end
		setTint(0)
		-- (nothing keeps glowing or emitting where it last was: what was emitted plays out)
		for _, e in ipairs(U.Emitters(model)) do
			e.Enabled = false
		end
		for _, e in ipairs(handFx) do
			e.Enabled = false
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("PointLight") then
				d.Enabled = false
			end
		end
		for _, s in pairs({ hum, crackle, rise, roar, endLoop }) do
			s:Stop()
		end
		if o.Mine and o.Fov then
			o.Fov(0)
		end
		-- what was emitted plays out; then nothing is left
		task.delay(1.4, function()
			maid:Clean()
		end)
	end

	local function frame(dt: number)
		if not caster.Parent then
			finish()
			return
		end
		local now = os.clock()
		local tau = now - o.Started
		-- (Studio inspection: workspace AbilityFXTime holds the timeline at that clip time)
		local frozen = if STUDIO then workspace:GetAttribute("AbilityFXTime") else nil
		if type(frozen) == "number" then
			tau = frozen
		end
		-- this screen's view of the clip leads the timeline while it gathers (the hands and the energy
		-- never part, however late the clip reached this screen)
		local track = o.Track and o.Track()
		if track and track.IsPlaying and not firedAt and track.TimePosition > 0 and track.TimePosition < TL.Hold and type(frozen) ~= "number" then
			-- (the clip runs on its own clock where the timeline slows it: back to the cast's)
			tau = if AbilityConfig.CastTime then AbilityConfig.CastTime(TL, track.TimePosition) else track.TimePosition
		end
		lastTau = tau
		aim = o.Aim()
		local hr, hl, armDir = hands()
		if (not hr or not hl) and not fizzled and not firedAt then
			-- no hands to cast with: the energy has nowhere to be
			fizzle()
		end
		local mid = if hr and hl then (hr + hl) * 0.5 else (if root then root.Position else ball.Position)

		---------------------------------------------------------------
		-- the sphere's size: a seed, born, grown, unstable, crushed, driven out - then it swells
		-- straight into the beam's root, and it empties into the beam as the beam drains away
		---------------------------------------------------------------
		local wake = U.Clamp01((tau - 0.04) / 0.25)
		local gather = U.Clamp01((tau - TL.Gather) / (TL.Compress - TL.Gather))
		local grow = U.Clamp01((tau - TL.Sphere) / (TL.Surge - TL.Sphere))
		local surge = U.Clamp01((tau - TL.Surge) / (TL.Compress - TL.Surge))
		local crush = if tau >= TL.Compress and not firedAt then U.Clamp01((tau - TL.Compress) / (TL.Thrust - TL.Compress)) else 0
		local drive = if tau >= TL.Thrust and not firedAt then U.Clamp01((tau - TL.Thrust) / (TL.Fire - TL.Thrust)) else 0
		local r = 0
		if not fizzled then
			if tau >= TL.Gather and tau < TL.Sphere then
				-- a seed of light in the palms, smoothly becoming the sphere
				r = 0.05 + 0.11 * U.Ramp(0, 1, (tau - TL.Gather) / (TL.Sphere - TL.Gather))
			elseif tau >= TL.Sphere then
				r = 0.16 + 0.56 * U.EaseOut(grow) + 0.42 * surge * surge
				-- unstable: it pulses harder and faster as it surges
				local freq = 14 + 46 * surge
				r *= 1 + (0.025 + 0.07 * surge) * math.sin(tau * freq) + (0.02 + 0.05 * surge) * U.Noise(tau * 9, seed)
				if crush > 0 then
					r *= U.Ramp(1, 0.55, crush)
				end
				if drive > 0 then
					-- (crushed to 0.55 by now: it swells back as the hands drive it out)
					r *= U.Ramp(1, 0.9 / 0.55, drive)
				end
			end
		end
		local since0 = if firedAt then now - firedAt else 0
		local since = since0
		if type(frozen) == "number" and frozen >= TL.Fire then
			since = math.min(frozen - TL.Fire, TL.Sustain - 0.01)
		end
		-- the beam's last moments: it drains into its end ball
		local drain = if firedAt and not cut then U.Clamp01((since - (TL.Sustain - DRAIN)) / DRAIN) else 0
		if firedAt then
			-- the beam's root: from exactly the size it fired at, it swells into the root the beam pours
			-- out of, and settles
			local bulb = 0.95 * BW
			local k = U.EaseOut(U.Clamp01(since / 0.16))
			r = (fireR + (bulb * 1.15 - fireR) * k) * (1 - 0.13 * U.Ramp(0, 1, (since - 0.16) / 0.4))
			r *= 1 + 0.06 * U.Noise(now * 11, seed + 3)
			r *= 1 - drain
		end
		if fizzled then
			local k = U.Clamp01((now - (endedAt or now)) / 0.16)
			r = sphereR * (1 + 0.7 * k) * (1 - k)
		elseif endedAt and firedAt then
			local k = U.Clamp01((now - endedAt) / (TL.Collapse * 0.6))
			r *= (1 - k) ^ 2
		end
		sphereR = r

		-- where it sits: just past the cupped palms (the arms point at it), clear of the body and of the
		-- world, and how far its light may come forward before it would show through the body
		local target = mid + armDir * (r * 0.62)
		local zRoom = 1
		local rv = r
		if firedAt then
			target = mid + aim * math.max(0.45, r * 0.35)
			zRoom = 1.4
		elseif r > 0.02 then
			local cleared, least = clearOfBody(target, r * 0.5 + 0.1)
			target = cleared
			local base = if part("Torso") then (part("Torso") :: BasePart).Position elseif root then root.Position else target
			local v = target - base
			if v.Magnitude > 0.05 then
				local hit = o.World(base, v + v.Unit * r * 0.5)
				if hit then
					local maxAt = math.max(0, (hit.Position - base).Magnitude - r * 0.5)
					if v.Magnitude > maxAt then
						target = base + v.Unit * maxAt
					end
				end
			end
			target, rv = roomFor(target, r)
			zRoom = within(least - 0.1, math.min(0.15, rv * 0.8), math.max(0.15, rv * 0.8))
		end
		local ballPos = target
		ball.CFrame = U.Look(ballPos, aim)
		ball.Size = Vector3.one * math.max(0.2, rv * 1.9)
		-- the layers follow its size
		if math.abs(rv - lastSized) > math.max(0.002, rv * 0.004) then
			lastSized = rv
			for _, L in ipairs(sLayers) do
				L.E.Size = ns(0, rv * L.K0, 1, rv * L.K1)
			end
			twinkle.Size = ns(0, rv * 0.5, 1, rv * 0.25)
			for _, P in ipairs(pLayers) do
				local kps = {}
				for _, kp in ipairs(P.Size.Keypoints) do
					table.insert(kps, NumberSequenceKeypoint.new(kp.Time, kp.Value * rv * P.K, kp.Envelope * rv * P.K))
				end
				P.E.Size = NumberSequence.new(kps)
				P.E.Speed = nr(P.Speed * rv)
			end
		end
		for _, L in ipairs(sLayers) do
			L.E.ZOffset = zRoom * L.Z
		end
		local spin = CFrame.Angles(tau * 7.3, tau * 11.1, tau * 5.2)
		local white = math.max(crush, drive)
		-- (the solid heart never sinks into a palm: it is only as big as the room between them allows)
		local palmRoom = math.huge
		if hr and hl and not firedAt then
			palmRoom = math.max(0.02, math.min((ballPos - hr).Magnitude, (ballPos - hl).Magnitude) - 0.08)
		end
		local formed = U.Clamp01((tau - TL.Sphere) / 0.2) * (if r > 0.05 then 1 else 0)
		-- (the black hole: it opens as the sphere surges to its largest and collapses as it is crushed)
		local bh = if firedAt or fizzled then 0 else U.Ramp(0, 1, (surge - 0.25) / 0.6) * (1 - U.Clamp01(crush * 1.6))
		setSolid(core, math.min(rv * (0.6 + 0.35 * white) * (1 - 0.92 * bh), palmRoom * 2), ball.CFrame * spin, if r > 0.04 then 0.02 else 1)
		setSolid(body, math.min(rv * 1.4, palmRoom * 2), ball.CFrame * spin:Inverse(), if r > 0.04 then 0.22 - 0.12 * white + 0.5 * bh else 1)
		setSolid(void, math.min(rv * 0.95 * bh, palmRoom * 2), ball.CFrame, if bh > 0.02 then 0 else 1)
		setSolid(swirl, math.min(rv * 1.55, palmRoom * 2 + 0.2), ball.CFrame * spin:Inverse(), 1 - (0.38 + 0.12 * surge) * formed)
		setSolid(skin, math.min(rv * 1.9, palmRoom * 2 + 0.35), ball.CFrame * spin, 1 - 0.7 * formed)
		-- its lightning cage: closing round it as it surges (and crackling round the beam's root)
		local caged = if firedAt then (if endedAt then 0 else 0.7 * (1 - drain)) elseif fizzled then 0 else U.Clamp01((surge - 0.15) / 0.5)
		if cage then
			local on = caged > 0.02 and r > 0.05 and math.random() > 0.15
			setSolid(cage, rv * (2.1 + 0.25 * math.random()), CFrame.new(ballPos) * CFrame.Angles(math.random() * TAU, math.random() * TAU, math.random() * TAU), if on then 1 - caged * (0.55 + 0.45 * math.random()) else 1)
		end
		-- the black hole's accretion rings: flat round it, leaning toward the view behind the caster,
		-- precessing - spun and flickered like their pack
		local dn = (Vector3.yAxis * 0.85 - aim * 0.5 + Vector3.new(math.sin(now * 0.9), 0, math.cos(now * 0.7)) * 0.08).Unit
		local ringCf = U.Up(ballPos, dn)
		for i, ring in ipairs({ ringA, ringB }) do
			if ring then
				local d = rv * (if i == 1 then 4.2 else 3.3) * (0.85 + 0.15 * bh)
				local on = bh > 0.03 and math.random() > 0.12
				setShape(ring, Vector3.new(d, d * 0.24, d), ringCf * CFrame.Angles(0, math.random() * TAU, 0), if on then 1 - bh * (0.6 + 0.4 * math.random()) else 1)
			end
		end

		---------------------------------------------------------------
		-- the charge (every layer comes in by its rate - nothing pops on)
		---------------------------------------------------------------
		local charging = not fizzled and not firedAt
		local alive = not fizzled and not endedAt
		local on = alive and r > 0.03
		if alive then
			local inten = if firedAt then 1 else math.clamp(0.25 + 0.45 * grow + 0.3 * surge + 0.3 * white, 0, 1.3)
			local formedRate = if firedAt then 1 - drain else formed
			sPlasma.Enabled = on
			sPlasma.Rate = 2 + 14 * formedRate * (0.5 + 0.5 * inten)
			sChaos.Enabled = on and (surge > 0 or firedAt ~= nil)
			sChaos.Rate = 12 * surge + (if firedAt then 6 else 0)
			sSwirlA.Enabled = on
			sSwirlA.Rate = (5 + 5 * inten) * formedRate
			sSwirlB.Enabled = on
			sSwirlB.Rate = (3 + 4 * inten) * formedRate
			sCrescent.Enabled = on and grow > 0
			sCrescent.Rate = 10 * grow * (0.4 + 0.6 * surge) * (if firedAt then 0.5 else 1)
			sArcs.Enabled = on and (surge > 0 or firedAt ~= nil)
			sArcs.Rate = 16 * surge + (if firedAt then 8 else 0)
			sArcBurst.Enabled = false
			-- the black hole: the bright heart goes dark, the swirl spins up
			sPlasma.Rate *= 1 - 0.75 * bh
			sChaos.Rate *= 1 - 0.8 * bh
			sSwirlA.Rate += 10 * bh
			twinkle.Enabled = on and charging
			twinkle.Rate = (3 + 16 * surge) * formed
			for _, P in ipairs(pLayers) do
				local m = if P.Phase == "grow" then (if firedAt then 1 - drain else grow)
					elseif P.Phase == "surge" then (if firedAt then 0.4 * (1 - drain) else surge)
					elseif P.Phase == "gather" then (if firedAt then 0 else gather * (1 - crush))
					else formedRate
				P.E.Enabled = on and m > 0.01
				P.E.Rate = P.Rate * m
				P.E.ZOffset = zRoom * P.Z
			end
			-- bursts snap off it in the last moments
			if charging and on and surge > 0.45 and now >= nextPulse then
				nextPulse = now + U.Ramp(0.45, 0.2, surge) * (0.7 + math.random() * 0.6)
				sArcBurst:Emit(1)
			end
		end
		-- lightning drawn in from all round the hands, ever faster, all of it at once at the last breath
		local drawing = charging and tau >= TL.Gather and tau < TL.Thrust
		if drawing then
			if now >= nextInflow then
				inflow(gather)
				nextInflow = now + U.Ramp(0.11, 0.028, gather)
			end
			if tau >= TL.Compress - 0.05 and not played.Inhale then
				played.Inhale = true
				for _ = 1, 8 do
					inflow(1)
				end
			end
		end
		-- the palms feed it, in turn
		if charging and formed > 0.3 and hr and hl and now >= nextPalm then
			nextPalm = now + U.Ramp(0.16, 0.06, gather)
			palmSide = -palmSide
			palmArc(if palmSide > 0 then hr else hl)
		end
		-- unstable, it throws lightning off
		if charging and surge > 0 and now >= nextSnap then
			snap(rv, surge > 0.6 and math.random() < 0.4)
			nextSnap = now + U.Ramp(0.16, 0.035, surge)
		end
		-- the hands crackle
		for _, e in ipairs(handFx) do
			e.Enabled = alive and tau > 0.04 and (not firedAt or since < 0.6)
			e.Rate = 6 + 18 * math.max(wake * 0.4, gather)
		end
		-- the ground under the caster
		local power = if fizzled then 0 elseif firedAt then (if endedAt then 0 else 1 - drain) else surge
		local gr = root and power > 0.05 and o.World(root.Position, Vector3.new(0, -8, 0))
		if gr then
			groundPart.CFrame = U.Up(gr.Position + gr.Normal * 0.12, gr.Normal) * CFrame.Angles(0, 0, math.rad(90))
			gDust.Enabled = true
			gDust.Rate = 6 + 18 * power
			gMotes.Enabled = true
			gMotes.Rate = 4 + 16 * power
		else
			gDust.Enabled = false
			gMotes.Enabled = false
		end
		-- light (kept low on the sphere: any brighter and it bleaches the arms holding it into a blur);
		-- it flickers with the lightning on it
		local flick = 1 + 0.25 * (math.random() - 0.5) * math.max(surge, if firedAt then 1 else 0)
		local lb = if firedAt then 1.3 * (1 - drain) else (0.15 * wake + 0.55 * U.EaseOut(grow) + 0.45 * surge + 0.6 * white)
		if fizzled or endedAt then
			lb *= 1 - U.Clamp01((now - (endedAt :: number)) / 0.2)
		end
		ballLight.Brightness = lb * flick
		ballLight.Color = rgb(55, 150, 255):Lerp(C_ICE, white)
		ballLight.Range = 6 + 10 * grow + 5 * surge + (if firedAt then 8 else 0)
		-- the view: a faint cold tint creeps in as it peaks (the caster's own), gone at the release
		if charging then
			setTint(0.6 * surge + 0.4 * white)
		end
		-- sound follows the charge
		if hum then
			local want = if fizzled or endedAt then 0 else (hum:GetAttribute("Base") :: number) * U.Ramp(0.25, 1, wake + gather)
			hum.Volume += (want - hum.Volume) * math.min(1, dt * 8)
			hum.PlaybackSpeed = 0.85 + 0.35 * gather + 0.15 * surge + (if firedAt then 0.1 else 0)
		end
		if crackle then
			local want = if fizzled or endedAt then 0 else (crackle:GetAttribute("Base") :: number) * U.Clamp01(gather * 1.3 + (if firedAt then 0.6 else 0))
			crackle.Volume += (want - crackle.Volume) * math.min(1, dt * 10)
			if want > 0 and not crackle.IsPlaying then
				crackle:Play()
			end
		end
		if rise and tau >= TL.Sphere and not played.Rise and charging then
			played.Rise = true
			rise:Play()
		end
		if tau >= TL.Compress and charging then
			once("Peak", ball)
		end
		-- the view trembles as it builds (the caster's own), harder at the end; one kick as it crushes
		if o.Mine and charging and surge > 0 and now >= nextShake then
			nextShake = now + 0.26
			camera("BeamCharge", nil, 0.35 + 1.1 * surge)
		end
		if o.Mine and charging and crush > 0 and not played.PeakKick then
			played.PeakKick = true
			camera("BeamPeak", -aim, 1)
		end

		---------------------------------------------------------------
		-- the release
		---------------------------------------------------------------
		if charging and tau >= TL.Fire then
			release(ballPos, aim)
		end
		if not firedAt then
			arcs.Step(now)
			return
		end

		---------------------------------------------------------------
		-- the beam
		---------------------------------------------------------------
		if not endedAt and since >= TL.Sustain then
			-- (its last moment: the end ball detonates with the server's blast. The server's Stop ends
			-- it on time too; this is the screen's own end if that word is late)
			collapse("Done")
		end
		if endedAt and not cut then
			-- (the blast has taken over: the beam and its end ball are gone into it)
			hideBeam()
			arcs.Step(now)
			if now - (endedAt :: number) >= TL.Collapse then
				finish()
			end
			return
		end
		-- where it starts: in the sphere - but never on the far side of a wall the caster stands against
		local from = ballPos
		local blockedAt: RaycastResult? = nil
		if root then
			local v = from - root.Position
			if v.Magnitude > 0.05 then
				local hit = o.World(root.Position, v)
				if hit then
					blockedAt = hit
					from = hit.Position - v.Unit * 0.3
				end
			end
		end
		-- it starts small and swells to massive over its life (its hitbox swells with it, on the server too)
		local g = AbilityConfig.BeamGrow(def, since)
		local bodies = o.Bodies()
		local length, normal, stopper, _, endHit = BeamMath.Trace(from, aim, B.Range, B.HitRadius * g, B.StopRadius * math.sqrt(g), bodies, o.World)
		if blockedAt then
			length, normal, stopper, endHit = 0.3, blockedAt.Normal, nil, blockedAt
		end
		-- its head races out (BeamReach: exactly where the server's hits reach), and pulls back to a
		-- nearer end fast but smoothly - it never jumps
		local want = math.min(length, math.max(0.3, AbilityConfig.BeamReach(def, since)))
		if want < visLen then
			visLen = math.max(want, visLen + (want - visLen) * math.min(1, dt * 28))
		else
			visLen = math.min(want, visLen + dt * 900)
		end
		local reached = visLen >= length - 0.05
		local coll = if endedAt then U.Clamp01((now - endedAt) / TL.Collapse) else 0
		-- the tail: it drains into the end ball over the beam's last moments (cut short, it chases the
		-- head as it dies)
		local feed = if cut then coll * coll else drain ^ 1.6
		local startAt = visLen * feed
		local p0 = from + aim * startAt
		local p1 = from + aim * visLen
		muzzleLight.Brightness = 2.2 * (1 - coll) * (1 - drain)
		muzzleLight.Range = 16 * (1 - coll)
		origin.CFrame = U.Look(p0, aim)

		-- its size: it swells out of the sphere at the release, breathes, flashes on every hit, thins as
		-- it drains or dies
		local hitN = AbilityConfig.BeamTick(def, since)
		local hitNow = false
		if hitN > lastHitPop and since < TL.Sustain and not endedAt then
			lastHitPop = hitN
			thumpAt = now
			hitNow = true
		end
		local tk = if thumpAt > 0 then now - thumpAt else math.huge
		local flash = math.exp(-tk * 9)
		local swell = 1 + 0.3 * math.exp(-since * 9) * (1 - math.exp(-since * 60))
		local grow0 = 0.3 + 0.7 * U.EaseOut(since / 0.12)
		local thin = if cut then 1 - coll else 1 - 0.3 * drain
		local unit = BW * g * swell * grow0 * thin * (1 + 0.06 * flash)
		-- THE ROOM ROUND IT: it is 3D, so every side counts - measured where it flares, mid-run and
		-- near its end. Swollen, it is let into the ground it tears up by a third of its radius at most;
		-- small, it keeps clear of it (surfaces right at its end are where it lands: they are meant to be met)
		local span = math.max(0.05, visLen - startAt)
		local side = aim:Cross(Vector3.yAxis)
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
		local landing = normal ~= nil and reached
		local wantRoom = BeamMath.Room(p0, aim, span, if landing then SHELL * unit * 0.7 + 2 else 0, o.World, 16)
		if drain <= 0 or wantRoom < roomAll then
			roomAll = roomAll + (wantRoom - roomAll) * math.min(1, dt * (if wantRoom < roomAll then 25 else 5))
		end
		unit *= BeamMath.RoomFactor(SHELL * unit, g, roomAll)
		local shellD = SHELL * unit

		-- THE END BALL: where it sits - at the head while it races out, on what it lands on (a little off
		-- a surface, its front pressed into it; against a body; at the end of its reach in open air) -
		-- and never more than a third sunk into a floor under it
		local onBody = stopper ~= nil
		local hitWorld = normal ~= nil and not onBody
		local landed = reached and normal ~= nil
		if landed and not landedOnce then
			landedOnce = true
			landAt = now
			if o.Mine then
				camera("BeamHit", -aim, 1)
			end
			nearKick(p1, 40, 0.8)
		end
		stretch += ((if reached then 1 else 1.7) - stretch) * math.min(1, dt * (if reached then 14 else 30))
		local breathe = 1 + 0.045 * math.sin(now * 9.5) + 0.03 * U.Noise(now * 6, seed + 11)
		local thump = if tk < 1 then 0.3 * math.exp(-tk * 9) * math.cos(tk * 28) else 0
		local lk = if landAt > 0 then now - landAt else math.huge
		local squash = if lk < 1 then 0.3 * math.exp(-lk * 10) * math.cos(lk * 24) else 0
		local ballWant = math.max(shellD * 1.25, 1.2)
		ballBase = if ballBase <= 0 then ballWant else ballBase + (ballWant - ballBase) * math.min(1, dt * 8)
		local ballD = ballBase * breathe * (1 + thump) * (1 + 0.25 * drain) * (if cut then 1 - coll else 1)
		local Rb = ballD * 0.5
		local bc = p1
		if landed and hitWorld then
			bc = p1 + (normal :: Vector3) * (Rb * 0.55)
		elseif landed and onBody then
			bc = p1 - aim * (Rb * 0.25)
		end
		local fl = o.World(bc + Vector3.new(0, Rb, 0), Vector3.new(0, -Rb * 2, 0))
		local wantLift = 0
		if fl then
			local hgt = (bc - fl.Position):Dot(fl.Normal)
			wantLift = math.max(0, Rb * 0.67 - hgt)
		end
		lift += (wantLift - lift) * math.min(1, dt * 18)
		bc += Vector3.yAxis * lift
		local axis = if landed and hitWorld then (normal :: Vector3) else aim
		local axial = 1 + 0.6 * (stretch - 1) - squash
		local lateral = 1 - 0.12 * (stretch - 1) + 0.35 * squash
		local bcf = U.Look(bc, axis)

		-- the beam's line: from its root into the end ball's heart
		local runV = bc - p0
		local total = runV.Magnitude
		local dir = if total > 1e-3 then runV / total else aim
		-- (its flare is a long teardrop, never a disc: a beam too short for it - just out of the hands,
		-- or draining away - is thinner in proportion)
		local short = BeamMath.ShortFactor(shellD, total)
		unit *= short
		shellD *= short
		local NL = math.min(math.max(6, 2.2 * shellD), total * 0.45)
		local show = total > 0.3 and thin > 0.02
		local zz = U.Noise(now * 17, seed + 5)
		for i, L in ipairs(bLayers) do
			local d = L.K * unit
			local off = L.Off * NL
			local a = NL * 0.5
			local eq = off + a
			-- (the hot layers flash white with every hit; the lightning on it flickers the cyan layer)
			local tr = L.Tr
			local col = L.Color
			if i == 2 then
				col = C_CYAN:Lerp(C_ICE, 0.35 * flash + 0.2 * math.max(0, zz))
				tr = L.Tr - 0.12 * flash
			elseif i == 3 then
				col = C_AZURE:Lerp(C_CYAN, 0.5 * flash)
				tr = L.Tr - 0.15 * flash + 0.05 * U.Noise(now * 14, seed + 4)
			elseif i == 4 then
				col = C_LIGHT:Lerp(C_ICE, flash)
			end
			tr = math.clamp(tr + (1 - tr) * (if cut then coll else 0), 0, 1)
			if show and d > 0.03 then
				if L.Neck then
					L.Neck.Color = col
				end
				L.Cyl.Color = col
				setShape(L.Neck, Vector3.new(d, d, 2 * a), U.Look(p0 + dir * eq, dir), tr)
				local len = total - eq
				if len > 0.05 then
					setShape(L.Cyl, Vector3.new(len, d, d), U.Look(p0 + dir * (eq + len * 0.5), dir) * ALONG, tr)
				else
					L.Cyl.Transparency = 1
				end
			else
				L.Cyl.Transparency = 1
				if L.Neck then
					L.Neck.Transparency = 1
				end
			end
		end
		-- where its lightning runs: from the cyan layer's flare into the end ball
		local runFrom = bLayers[2].Off * NL + NL * 0.5
		bs.P0, bs.Dir, bs.From, bs.Len, bs.R, bs.G = p0, dir, runFrom, math.max(0, total - runFrom), shellD * 0.5, g
		bs.Side, bs.Up = basis(dir)
		bs.Ball, bs.BallR, bs.Live = bc, Rb, show

		-- the Lightning pack's bolt wrapped round it, in lengths, re-struck every few frames
		local runLen = math.max(0, total - runFrom)
		local nS = if #sleeves > 0 and show and runLen > 1 then math.clamp(math.ceil(runLen / (2.2 * shellD + 4)), 1, #sleeves) else 0
		if now >= nextSleeve then
			nextSleeve = now + 1 / 30
			for i = 1, MAX_SLEEVES do
				local st = sleeveState[i]
				st.Spin = math.random() * TAU
				local roll = math.random()
				st.Tr = if roll < 0.18 then 1 elseif roll < 0.5 then 0 elseif roll < 0.8 then 0.2 else 0.45
				st.Color = if math.random() < 0.6 then C_ICE else C_ARC
			end
		end
		for i = 1, MAX_SLEEVES do
			local s = sleeves[i]
			if s then
				if i <= nS then
					local st = sleeveState[i]
					local seg = runLen / nS
					local c = p0 + dir * (runFrom + seg * (i - 0.5))
					local across = shellD * (1.22 + 0.3 * flash)
					s.Color = st.Color
					setShape(s, Vector3.new(seg * 1.25, across * 0.47, across), U.Look(c, dir) * ALONG * CFrame.Angles(st.Spin, 0, 0), math.max(st.Tr, if cut then coll else 0))
				else
					s.Transparency = 1
				end
			end
		end
		-- and 3D arcs leaping along its skin
		if show and not endedAt and now >= nextSkin and bs.Len > 2 then
			nextSkin = now + U.Ramp(0.08, 0.035, (g - 0.6) / 1.4)
			local sf = math.random()
			local lenF = 4 + math.random() * 7
			local th0 = math.random() * TAU
			local dth = (math.random() - 0.5) * 2.4
			local hop = 0.2 + math.random() * 0.4
			arcs.Add(function(_k: number)
				local L = math.min(lenF * math.max(1, bs.G), bs.Len * 0.6)
				local s0 = bs.From + sf * math.max(0, bs.Len - L)
				local pts = {}
				for j = 0, 6 do
					local t = j / 6
					local th = th0 + dth * t + (math.random() - 0.5) * 0.5
					local rr = bs.R * (0.96 + hop * math.sin(t * math.pi) + (math.random() - 0.5) * 0.16)
					pts[j + 1] = bs.P0 + bs.Dir * (s0 + L * t) + (bs.Side * math.cos(th) + bs.Up * math.sin(th)) * rr
				end
				return pts
			end, 0.09 + math.random() * 0.08, 0.1 + 0.06 * g, if math.random() < 0.5 then C_ARC else C_ICE, 0.035)
		end
		-- the surge: a swell of light rushing down it, landing in the end ball exactly on each hit
		local PULSE_T = 0.13
		local nextTick = lastHitPop + 1
		local tNext = (B.FirstTick or 0) + nextTick * B.Tick
		if not endedAt and tNext < TL.Sustain and since >= tNext - PULSE_T and pulseFor < nextTick then
			pulseFor = nextTick
			pulseBorn = since
		end
		if pulse then
			local s = (since - pulseBorn) / PULSE_T
			if pulseFor >= 0 and s >= 0 and s < 1.15 and show then
				local e = 1 - (1 - math.min(s, 1)) ^ 2
				local pd = 2.9 * unit * 1.22
				local pl = math.min(3 * pd, total * 0.5)
				setShape(pulse, Vector3.new(pd, pd, math.max(0.1, pl)), U.Look(p0 + dir * (total * e), dir), 0.3 + 0.7 * math.max(0, s - 0.8) / 0.35)
			else
				pulse.Transparency = 1
			end
		end

		-- the end ball's layers (its swirl spins; its core goes white with every hit and as it drains)
		local hot = math.max(flash, drain)
		local ballCf = bcf
		local bshape = function(k: number): Vector3
			return Vector3.new(ballD * k * lateral, ballD * k * lateral, ballD * k * axial)
		end
		local bt = if cut then coll else 0
		if eCore then
			eCore.Color = C_HOT:Lerp(C_WHITE, 0.4 + 0.6 * hot)
		end
		if eBody then
			eBody.Color = C_AZURE:Lerp(C_CYAN, 0.6 * hot)
		end
		if eSkin then
			eSkin.Color = C_CYAN:Lerp(C_ICE, hot)
		end
		setShape(eCore, bshape(0.5 + 0.12 * hot), ballCf, bt)
		setShape(eBody, bshape(0.82), ballCf, math.min(1, 0.22 - 0.12 * hot + bt))
		setShape(eSwirl, bshape(0.9), ballCf * CFrame.Angles(now * 6.1, now * 8.3, now * 4.7), math.min(1, 0.45 + bt))
		setShape(eSkin, bshape(1.0), ballCf * CFrame.Angles(0, 0, now * 3), bt)
		-- its lightning cage, re-struck every frame (the Lightning pack's way)
		local cageOn = math.random() > 0.15
		setSolid(eCageA, ballD * (1.12 + 0.12 * math.random()), CFrame.new(bc) * CFrame.Angles(math.random() * TAU, math.random() * TAU, math.random() * TAU), if cageOn then math.max(bt, 0.1 + 0.4 * math.random()) else 1)
		setSolid(eCageB, ballD * (1.0 + 0.15 * math.random()), CFrame.new(bc) * CFrame.Angles(math.random() * TAU, math.random() * TAU, math.random() * TAU), if math.random() > 0.3 then math.max(bt, 0.15 + 0.4 * math.random()) else 1)
		-- three Thunder bolts discharging out of it, evenly round its axis and slowly turning: splayed
		-- into the surface it lands on, flared ahead of it in open air
		do
			local fwd = if landed and hitWorld then -(normal :: Vector3) else aim
			local u1, u2 = basis(fwd)
			local splay = math.rad(if landed then 58 else 40)
			for i, tb in ipairs(thunders) do
				local ang = now * 2.2 + (i - 1) * TAU / 3
				local d = (fwd * math.cos(splay) + (u1 * math.cos(ang) + u2 * math.sin(ang)) * math.sin(splay)).Unit
				local len = Rb * (1.5 + 0.5 * flash)
				local lit = math.random() > 0.25 and not cut
				setShape(tb, Vector3.new(len * 0.17, len, len * 0.2), U.Up(bc + d * (Rb * 0.7 + len * 0.5), d) * CFrame.Angles(0, math.random() * TAU, 0), if lit then 0.1 + 0.35 * math.random() else 1)
			end
		end
		-- the drain: a force-field shell crushing in on it while lightning pours in along the last of the beam
		if eImplode then
			if drain > 0 and not cut then
				setSolid(eImplode, ballD * (2.8 - 1.8 * drain), CFrame.new(bc), 0.75 - 0.6 * drain)
			else
				eImplode.Transparency = 1
			end
		end
		if drain > 0 and not cut and now >= nextFeed then
			nextFeed = now + 0.03
			local d = randomUnit()
			local far = 2.8 - 1.2 * drain
			arcs.Add(function(k: number)
				return jagged(bs.Ball + d * bs.BallR * far * (1 - 0.4 * k), bs.Ball + d * bs.BallR * 0.6, 5, 0.22)
			end, 0.1, 0.1 + 0.05 * g, C_ARC, 0.03)
		end
		-- the end ball discharges into whatever it touches: the surface round it, the body it is on, or the
		-- open air ahead of it
		if not endedAt and now >= nextDischarge then
			nextDischarge = now + U.Ramp(0.12, 0.05, (g - 0.6) / 1.4)
			local d: Vector3
			local tip: Vector3? = nil
			if landed and hitWorld then
				d = ((-(normal :: Vector3)) * 0.55 + randomUnit()).Unit
				local hit = o.World(bc, d * Rb * 2.8)
				if hit then
					tip = hit.Position
				end
			elseif landed and onBody then
				for _, b in ipairs(bodies) do
					if b.Key == stopper then
						tip = b.Cf.Position + Vector3.new((math.random() - 0.5) * 1.6, (math.random() - 0.4) * 3.2, (math.random() - 0.5) * 1.6)
						break
					end
				end
				d = if tip then ((tip :: Vector3) - bc).Unit else randomUnit()
			else
				d = (aim * 0.6 + randomUnit()).Unit
			end
			local reachOut = if tip then nil else Rb * (1.5 + math.random() * 0.8)
			local fixed = tip
			arcs.Add(function(_k: number)
				local c = bs.Ball
				local to = fixed or (c + d * (reachOut :: number))
				return jagged(c + d * bs.BallR * 0.85, to, 6, 0.24)
			end, 0.08 + math.random() * 0.07, 0.11 + 0.06 * g, if math.random() < 0.5 then C_ARC else C_ICE, 0.03)
		end
		-- the end ball's crackle, smoke and sparks (placed on its part once that part has moved)
		tail.CFrame = U.Look(p1, aim)
		endAtt.WorldPosition = bc
		eCrackle.Enabled = not endedAt
		eCrackle.Rate = 14 + 10 * flash
		eCrackle.Size = ns(0, Rb * 0.8, 1, Rb * 1.1)
		eCrackle.ZOffset = Rb * 0.6
		surface:SetAttribute("Normal", if hitWorld then normal else nil)
		if hitWorld then
			surface.WorldCFrame = U.Up(p1 + (normal :: Vector3) * 0.15, normal :: Vector3)
		else
			surface.WorldCFrame = U.Up(p1, -aim)
		end
		endSmoke.Enabled = landed and hitWorld and not endedAt
		endSmoke.Rate = 8
		endSparkle.Enabled = landed and not endedAt
		endSparkle.Rate = 20 + 30 * flash
		endLight.Color = C_LIGHT:Lerp(C_ICE, flash)
		endLight.Brightness = ((if landed then 2.6 else 1.4) + 3 * flash) * (1 - coll) * (1 + 0.2 * (math.random() - 0.5))
		endLight.Range = (18 + 6 * g) * (1 - coll)
		-- a hit lands at its end: the end ball thumps, an electric ring bursts off it, chips of the
		-- surface fly (two by two, mirrored), smoke and dust kick up
		if hitNow then
			local n = (if hitWorld then normal else -aim) :: Vector3
			shockRing(bc, n, ballD * 0.9, ballD * 2.3, 0.3, C_ICE, nil, 0.26)
			flashLight(bc, C_ICE, 4, 20 + 6 * g, 0.25, nil, C_MID)
			if landed and hitWorld then
				local s1, s2 = basis(n)
				local a0 = math.random() * TAU
				for j = 0, 3 do
					local a = a0 + j * TAU / 4
					local out = s1 * math.cos(a) + s2 * math.sin(a)
					chunk(p1 + n * 0.2, n, endHit, 0.55 + 0.25 * g, out, 20, 16)
				end
				fire("BlastHit", U.Up(p1 + n * 0.2, n) * CFrame.Angles(0, a0, 0), 0.55 * g, nil, 0.6, nil, true, Rb * 3)
			end
		end

		-- the lights along it (they flicker with its lightning, flash with every hit)
		volume.Size = Vector3.new(1, 1, math.max(0.2, total))
		volume.CFrame = U.Look(p0 + dir * total * 0.5, dir)
		for i, vl in ipairs(volLights) do
			vl.Att.Position = Vector3.new(0, 0, total * (0.5 - i / 4))
			vl.Light.Brightness = (0.8 + 0.25 * U.Noise(now * 19, seed + i) + 1.4 * flash) * (1 - coll) * (1 - 0.6 * drain)
			vl.Light.Color = C_MID:Lerp(C_ICE, flash)
			vl.Light.Range = 14 * g * (1 - coll)
		end
		-- the ground under its path: stirred wherever it is close, torn up (chunks thrown out to both
		-- sides, mirrored) wherever the beam grinds into it
		local kick = not endedAt and span > 4
		for i, tp in ipairs(trailPts) do
			local onG = false
			if kick then
				local q = p0 + dir * (total * (i - 0.5) / TRAIL)
				local flq = o.World(q, Vector3.new(0, -8, 0))
				if flq then
					onG = true
					local gap = q.Y - flq.Position.Y
					local closeness = 1 - gap / 8
					tp.Att.WorldCFrame = U.Up(flq.Position + flq.Normal * 0.2, flq.Normal)
					tp.Dust.Rate = 10 * closeness + (if gap < shellD * 0.5 then 12 else 0)
					if gap < shellD * 0.5 and now >= tp.NextChunk then
						tp.NextChunk = now + 0.5 + math.random() * 0.4
						for _, sgn in ipairs({ 1, -1 }) do
							chunk(flq.Position + side * sgn * shellD * 0.35, flq.Normal, flq, 0.5 + 0.2 * g, side * sgn, 14, 16)
						end
					end
				end
			end
			tp.Dust.Enabled = onG
		end
		if endLoop then
			local wantV = if landed and not endedAt then (endLoop:GetAttribute("Base") :: number) else 0
			endLoop.Volume += (wantV - endLoop.Volume) * math.min(1, dt * 12)
		end
		if roar then
			local wantV = if endedAt then 0 else (roar:GetAttribute("Base") :: number) * (1 - 0.5 * drain)
			roar.Volume += (wantV - roar.Volume) * math.min(1, dt * (if endedAt then 14 else 20))
		end
		-- the beam hums under the caster's view while it lasts
		if o.Mine and not endedAt and now >= nextShake then
			nextShake = now + 0.24
			camera("BeamHold", nil, 1)
		end
		arcs.Step(now)
		if endedAt and coll >= 1 then
			finish()
		end
	end

	h.Bind = "AzureTide" .. tostring(h):gsub("table: ", "")
	RunService:BindToRenderStep(h.Bind, Enum.RenderPriority.Camera.Value + 6, function(dt: number)
		local ok, err = pcall(frame, math.min(dt, 0.1))
		if not ok then
			warn("[AzureTide] fx:", err)
			finish()
		end
	end)

	-- end it: a charge fizzles, a beam collapses (Interrupted: at once, no blast at its end)
	function h.Stop(why: string?)
		if not h.Alive then
			return
		end
		if firedAt then
			local was = endedAt
			collapse(why or "Done")
			if why == "Interrupted" and not was then
				-- (cut short: it dies faster)
				endedAt = os.clock() - TL.Collapse * 0.45
			end
		else
			fizzle()
			task.delay(0.2, finish)
		end
	end
	-- gone at once (the character left the game)
	function h.Destroy()
		if h.Alive then
			h.Alive = false
			pcall(function()
				RunService:UnbindFromRenderStep(h.Bind)
			end)
		end
		setTint(0)
		if o.Mine and o.Fov then
			o.Fov(0)
		end
		maid:Clean()
	end
	function h.Fired(): boolean
		return firedAt ~= nil
	end
	function h.Tau(): number
		return lastTau
	end
	return h
end

return FX
