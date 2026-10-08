--[[
	AzureTideCannon  (ReplicatedStorage.Abilities.FX.AzureTideCannon)
	What Azure Tide Cannon looks and sounds like - on every screen, for every caster. One continuous
	event, every phase flowing into the next. Built only from the place's own effects (the packs in
	Abilities.Assets.AzureTideCannon and their textures) - nothing drawn from scratch.

	  GATHER    light wakes in the palms; energy is pulled in from all round (streaks, motes, wisps)
	  FORM      a seed of light between the hands becomes a sphere and grows: a white-hot core in an
	            azure body, plasma, a dark swirl giving it shape, crescents, a crisp rim, rays, a bloom,
	            the pack's charge flow, the v80 swirl and force-field shells, sparks orbiting it
	  SURGE     it becomes unstable: arcs crawl over it and snap off it, it pulses harder and faster
	  COMPRESS  everything is sucked in and the sphere crushes down to its brightest
	  THRUST    the hands drive it forward (a streak behind it)
	  RELEASE   the sphere swells straight into the beam's root: the beam pours out of it, its head (the
	            sphere hurled ahead) races to the end. The pack's release burst, the ground under the
	            caster blasts, a flash
	  BEAM      v80's beam, bigger: Beamy's layers, a white core, an azure body, two plasmas and wisps,
	            a solid core and body from any side - every piece rounded, flaring out of the sphere and
	            tapering into its end. It never sinks into the floor: it narrows only where the ground or
	            a wall is closer than its edge (its flat ribbons are measured the way they face you)
	  IMPACT    v80's: Beamy's impact, a glow, sparks, smoke; a burst on every hit
	  BLAST     it collapses into its end: the place's implode-explosion pack crushes in and detonates,
	            the FinalExplosion and the Explosion pack's smoke and dust round it, secondary bursts,
	            a white-hot fireball, light and a flash of the view
	Light and the screen are only ever borrowed: every light, tint and blur fades back to nothing.
	Nothing outlives the cast but its own short-lived effects; everything is cleaned in one call.

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
-- (the sphere's extra shades: from a near-black navy through royal to a glacier cyan)
local C_NAVY = rgb(8, 22, 92)
local C_ROYAL = rgb(28, 84, 240)
local C_AZURE = rgb(58, 168, 255)
local C_CYAN = rgb(104, 228, 255)

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

---------------------------------------------------------------------------
-- the packs' textures (every one is in the place's VFX packs). Beam textures run along the beam with
-- the image's vertical axis.
---------------------------------------------------------------------------
local BEAM_W = 1.6 -- (v80's beam, bigger by a good margin)
local T = {
	-- v80's own
	Needle = tex(13520691450),
	Needle2 = tex(18244509255),
	Glow = tex(12159555294),
	Glow2 = tex(243664672),
	Flare = tex(9761807363),
	Arc2 = tex(16009841559),
	Wisp = tex(79598379412341),
	Turbulent = tex(14962000553),
	Turbulent2 = tex(135482100082072),
	GlowBand = tex(5310883966),
	CoreBand = tex(12781828706),
	Smoke = tex(8527116276),
	Dots = tex(14582794847),
	-- the sphere (the layered ball)
	CoreGlow = tex(12189101933), -- Light Explosion Aura/E4: big soft glow
	SoftGlow = tex(251657030), -- soft round glow
	PlasmaBall = tex(8214516993), -- VFX PACK V3: turbulent energy ball
	Chaos = tex(17067057050), -- Big Impact1: chaotic electric sphere
	Rim = tex(1084991215), -- Yona CircleHit: a sphere's glowing rim
	RimRays = tex(11820076505), -- Ground Emit 1: rim of radial streaks
	Swirl = tex(9309993091), -- Explosion Implode "CHARGE PART": swirl
	Crescent = tex(16669803246), -- Big Windspin1: crescent
	ArcBall = tex(16334776490), -- lightning_ball_sorta (4x4)
	ArcRing = tex(12800314611), -- Lightning_Circular_01 (2x2)
	ArcBurst = tex(17087448166), -- Auras Bottom: electric burst
	Star = tex(1084970835), -- Light Explosion Core: four-point star
	Spark = tex(120067432715909), -- spark (2x2)
	BWisp = tex(79598379412341), -- beam1: soft streaks
	BBolt = tex(14961582521), -- NewBeams: electric waveform
	BLightning = tex(10517580193), -- AtLeft: branching lightning
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

local function beam(parent: Instance, a0: Attachment, a1: Attachment, p: { [string]: any }): Beam
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.FaceCamera = true
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Segments = 10
	b.TextureMode = Enum.TextureMode.Wrap
	b.Enabled = false
	for k, v in pairs(p) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	return b
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

---------------------------------------------------------------------------
-- one animator for every short-lived piece of every cast (lights, fireballs, the screen): a single
-- RenderStepped connection that exists only while something is animating
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

-- a light that flares and fades away at a point (it removes itself)
local function flashLight(at: Vector3, color: Color3, brightness: number, range: number, life: number, parent: Instance?)
	local p = U.Part({ CFrame = CFrame.new(at) })
	p.Parent = parent or U.Holder()
	local l = light(p, color)
	animate(0, life, function(k)
		l.Brightness = brightness * (1 - k) ^ 2
		l.Range = range * (1 - 0.3 * k)
	end, function()
		p:Destroy()
	end)
	Debris:AddItem(p, life + 1)
end

-- v80's fireball: a white-hot sphere in an azure one, swelling from d0 to d1 (diameters) and burning off.
-- On a floor (`floor`, `up`) it rests on it and rises as it swells - it never sinks into the ground
local function fireball(at: Vector3, d0: number, d1: number, life: number, parent: Instance?, floor: Vector3?, up: Vector3?)
	local tpl = asset("Meshes/SphereHD")
	if not (tpl and tpl:IsA("BasePart")) then
		return
	end
	local inner = U.Solid(tpl, { Material = Enum.Material.Neon, Color = C_WHITE, Transparency = 0 })
	local outer = U.Solid(tpl, { Material = Enum.Material.Neon, Color = C_MID, Transparency = 0.2 })
	local function place(d: number)
		local c = at
		if floor and up then
			local h = (at - floor):Dot(up)
			c = at + up * math.max(0, d * 0.5 + 0.1 - h)
		end
		inner.Size = Vector3.one * math.max(0.05, d * 0.72)
		outer.Size = Vector3.one * math.max(0.05, d)
		inner.CFrame = CFrame.new(c)
		outer.CFrame = CFrame.new(c)
	end
	place(d0)
	inner.Parent = parent or U.Holder()
	outer.Parent = parent or U.Holder()
	animate(0, life, function(t)
		local e = 1 - (1 - t) ^ 3
		place(d0 + (d1 - d0) * e)
		inner.Transparency = math.min(1, t * 1.6)
		outer.Transparency = 0.2 + 0.8 * t ^ 0.7
		outer.Color = C_MID:Lerp(C_LIGHT, t)
	end, function()
		inner:Destroy()
		outer:Destroy()
	end)
	Debris:AddItem(inner, life + 1)
	Debris:AddItem(outer, life + 1)
end

-- one of the place's effects, fired once at a frame (the pack's own counts and delays), gone when its
-- particles are: `name` is a template in Abilities.Assets.AzureTideCannon (an Attachment, a Part or a
-- Model), `scale` sizes it (its spawn volume too), `count` multiplies what it emits.
-- `surface`: cf's UpVector is the face of a floor or wall it stands on - then nothing it throws goes into
-- that surface (all of it flies up and out of it), nothing falls back through it, its flat (lying)
-- sprites are left out, and every sprite is drawn in front of the surface it would cut into, so no
-- particle ever shows a hard edge where it meets the ground
local function fire(name: string, cf: CFrame, scale: number, parent: Instance?, count: number?, tweak: ((ParticleEmitter) -> ())?, surface: boolean?): Instance?
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
	local list = U.Emitters(root)
	if surface then
		local cam = workspace.CurrentCamera
		local dist = if cam then (cam.CFrame.Position - cf.Position).Magnitude else 40
		local lift = math.clamp(dist - 4, 0, 4 + 16 * scale)
		for _, e in ipairs(list) do
			-- (flat ring sprites, the packs' dark-outline smoke - negative light emission - and giant
			-- constant discs are left out: the blast stays clean, fluid light and smoke)
			local least = math.huge
			for _, kp in ipairs(e.Size.Keypoints) do
				least = math.min(least, kp.Value)
			end
			if e.Orientation == Enum.ParticleOrientation.VelocityPerpendicular or e.LightEmission < 0 or least > 40 then
				e:Destroy()
			else
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
	local maid = U.Maid()
	local h: any = { Alive = true, Phase = "Charge" }
	local seed = math.random() * 1000

	local model = Instance.new("Folder")
	model.Name = "AzureTide_" .. caster.Name
	model.Parent = U.Holder()
	maid:Give(model)

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
		local room = if nearest < math.huge then math.clamp((nearest + push.Magnitude) / 1.45, math.min(0.3, r), r) else r
		return at + push, room
	end

	-------------------------------------------------------------------
	-- the sphere
	-------------------------------------------------------------------
	local ball = U.Part({ Name = "Sphere", Shape = Enum.PartType.Ball, Size = Vector3.one })
	ball.Parent = model
	local ballAtt = att(ball, "Center")
	local ballLight = light(ball, rgb(55, 150, 255))
	local meshes = asset("Meshes")
	local function mesh(name: string, props: { [string]: any }): BasePart?
		local tpl = meshes and meshes:FindFirstChild(name)
		if not (tpl and tpl:IsA("BasePart")) then
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

	-- the sphere's layers, inside out; each one sized by the sphere's radius every frame
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
	-- (a bright sky turns stacked additive light to white: only the heart and the electricity are fully
	-- emissive; the body's layers are blended, so it reads as an azure sphere, not a white smear. Layers
	-- are depth-ordered: the bloom at the back, a DARK swirl that gives the light its shape, then the
	-- rim, the electricity and the hot core in front)
	local sCore = sLayer(0.62, 0.72, 1, { Name = "Core", Texture = T.CoreGlow, Brightness = 0.7, Color = cs(C_HOT, C_CYAN), Transparency = ns(0, 0.55, 0.5, 0.65, 1, 1), Lifetime = nr(0.12, 0.16) })
	local sPlasma = sLayer(1.45, 1.6, 0.9, { Name = "Plasma", Brightness = 0.85, Texture = T.PlasmaBall, Color = cs(C_AZURE, C_ROYAL, C_DEEP), Transparency = ns(0, 0.8, 0.3, 0.45, 1, 1), Lifetime = nr(0.18, 0.26), Rotation = nr(0, 360), RotSpeed = nr(-240, 240) })
	local sChaos = sLayer(1.7, 1.9, 0.92, { Name = "Chaos", Texture = T.Chaos, Brightness = 0.6, Color = cs(C_CYAN, C_AZURE), Transparency = ns(0, 0.4, 1, 1), Lifetime = nr(0.08, 0.13), Rotation = nr(0, 360) })
	local sSwirlA = sLayer(1.7, 1.85, 0.7, { Name = "SwirlA", Texture = T.Swirl, Color = cs(rgb(22, 64, 200), rgb(12, 36, 150)), LightEmission = 0.1, Transparency = ns(0, 1, 0.2, 0.35, 1, 1), Lifetime = nr(0.22, 0.3), Rotation = nr(0, 360), RotSpeed = nr(420, 700) })
	local sSwirlB = sLayer(1.95, 1.75, 0.8, { Name = "SwirlB", LightEmission = 0.45, Texture = T.Swirl, Color = cs(C_AZURE, C_ROYAL, C_DEEP), Transparency = ns(0, 1, 0.25, 0.4, 1, 1), Lifetime = nr(0.25, 0.35), Rotation = nr(0, 360), RotSpeed = nr(-640, -380) })
	local sCrescent = sLayer(2.1, 2.45, 0.75, { Name = "Crescents", Brightness = 0.85, Texture = T.Crescent, Color = cs(C_CYAN, C_AZURE, C_MID), Transparency = ns(0, 1, 0.25, 0.35, 1, 1), Lifetime = nr(0.16, 0.24), Rotation = nr(0, 360), RotSpeed = nr(620, 950) })
	local sRim = sLayer(1.65, 1.65, 0.85, { Name = "Rim", Brightness = 0.85, Texture = T.Rim, Color = cs(C_ICE, C_AZURE), Transparency = ns(0, 0.35, 1, 0.9), Lifetime = nr(0.1, 0.14), Rotation = nr(0, 360) })
	local sRays = sLayer(2.0, 2.35, 0.65, { Name = "Rays", Brightness = 0.7, Texture = T.RimRays, Color = cs(C_CYAN, C_MID, C_DEEP), Transparency = ns(0, 0.5, 1, 1), Lifetime = nr(0.12, 0.18), Rotation = nr(0, 360) })
	local sBloom = sLayer(2.6, 2.9, 0.5, { Name = "Bloom", Texture = T.SoftGlow, Color = cs(C_ROYAL, C_DEEP), Transparency = ns(0, 0.8, 1, 1), Lifetime = nr(0.2) })
	local sArcs = sLayer(1.85, 2.05, 0.95, with(book("4x4"), { Name = "Arcs", Texture = T.ArcBall, Brightness = 0.85, Color = cs(C_ICE, C_CYAN), Transparency = ns(0, 0.05, 1, 0.5), Lifetime = nr(0.12, 0.18), Rotation = nr(0, 360) }))
	local sArcRing = sLayer(1.75, 1.95, 0.9, with(book("2x2"), { Name = "ArcRing", Texture = T.ArcRing, Color = cs(C_HOT, C_CYAN), Transparency = ns(0, 0.2, 1, 0.7), Lifetime = nr(0.1, 0.14), Rotation = nr(0, 360) }))
	local sArcBurst = sLayer(1.9, 2.3, 0.9, { Name = "ArcBurst", Texture = T.ArcBurst, Color = cs(C_HOT, C_LIGHT), Transparency = ns(0, 0.45, 1, 1), Lifetime = nr(0.08, 0.12), Rotation = nr(0, 360) })
	local sFlare = sLayer(1.6, 2.3, 1, { Name = "Flare", Texture = T.Star, Color = cs(C_WHITE, C_ICE), Transparency = ns(0, 0.35, 1, 1), Lifetime = nr(0.1, 0.14), Rotation = nr(0, 360) })
	-- the place's charge flow (v80's), sized with the sphere
	local charge: Instance? = nil
	local chargeTpl = asset("Charge")
	if chargeTpl then
		charge = U.Clone(chargeTpl, ball, CFrame.new(), 1)
		for _, e in ipairs(U.Emitters(charge :: Instance)) do
			e.LockedToPart = true
			-- (its sprites have black backgrounds: they stay fully emissive, the colour is kept deep)
			e.Color = if e.Name == "Core1" then cs(C_CYAN, C_AZURE) else cs(C_AZURE, C_ROYAL)
			e.LightEmission = 1
			if e.Name == "Core1" then
				e.Rate = 40
			end
		end
	end

	-- AT ITS LARGEST IT IS A BLUE BLACK HOLE: a void at its heart that swallows the light, the photon
	-- ring burning round its edge, a lensed glow, and an accretion disk of plasma spun flat round it
	-- (bright inner streams, dark lanes, a soft outer glow), tilted toward the view behind the caster -
	-- while everything round it spirals in. It collapses into white-hot light as it is crushed down
	local void = mesh("SphereHD", { Material = Enum.Material.Neon, Color = rgb(34, 110, 255) })
	local diskAtt = att(ball, "Disk")
	local onDisk = { Orientation = Enum.ParticleOrientation.VelocityPerpendicular, EmissionDirection = Enum.NormalId.Top, Speed = nr(0.01), Rotation = nr(0, 360) }
	local dGlow = layerOn(diskAtt, 3.9, 4.2, 0.45, with(onDisk, { Name = "DiskGlow", Texture = T.SoftGlow, Color = cs(C_ROYAL, C_DEEP), Transparency = ns(0, 1, 0.3, 0.5, 1, 1), Lifetime = nr(0.3) }))
	local dSwirl = layerOn(diskAtt, 2.7, 3.5, 0.75, with(onDisk, { Name = "DiskSwirl", Texture = T.Swirl, Color = cs(C_ICE, C_AZURE, C_ROYAL), Brightness = 0.85, Transparency = ns(0, 1, 0.2, 0.15, 0.7, 0.45, 1, 1), Lifetime = nr(0.32, 0.4), RotSpeed = nr(280, 420) }))
	local dStreak = layerOn(diskAtt, 2.3, 3.1, 0.8, with(onDisk, { Name = "DiskStreaks", Texture = T.Crescent, Brightness = 0.85, Color = cs(C_CYAN, C_ROYAL), Transparency = ns(0, 1, 0.25, 0.2, 1, 1), Lifetime = nr(0.18, 0.26), RotSpeed = nr(620, 900) }))
	local dDark = layerOn(diskAtt, 2.1, 2.7, 0.7, with(onDisk, { Name = "DiskLanes", Texture = T.Swirl, Color = cs(C_DEEP, rgb(12, 34, 150)), LightEmission = 0.15, Transparency = ns(0, 1, 0.3, 0.4, 1, 1), Lifetime = nr(0.3, 0.38), RotSpeed = nr(340, 480) }))
	local sPhoton = sLayer(1.02, 1.06, 1.2, { Name = "PhotonRing", Texture = T.Rim, Color = cs(C_HOT, C_CYAN), Brightness = 1.1, Transparency = ns(0, 0.1, 1, 0.6), Lifetime = nr(0.08, 0.12), Rotation = nr(0, 360) })
	-- (the void itself: a dark disc drawn over the bright heart, the photon ring burning on its edge)
	local sVoid = sLayer(0.92, 0.96, 1.15, { Name = "Void", Texture = T.Glow2, Color = cs(rgb(46, 132, 255), rgb(28, 92, 240)), LightEmission = 0.35, Transparency = ns(0, 0.12, 1, 0.25), Lifetime = nr(0.1, 0.12) })
	local sLens = sLayer(1.5, 2.6, 0.55, { Name = "Lensing", Texture = T.Rim, Color = cs(C_CYAN, C_ROYAL), Transparency = ns(0, 0.55, 1, 1), Lifetime = nr(0.3), Rotation = nr(0, 360) })

	-- the place's own ball and charge packs layered in, recoloured in the sphere's blues: Big Ball-01's
	-- flames (azure) and ash (navy - the dark that gives the light its shape) licking off its surface and
	-- its specks drawn into it, Yona's charge core, wind and motes at its heart
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
	packLayer("Charge", ballAtt, 0.6, 0, 30, "form", 1.05, { Name = "PackCharge", Color = cs(C_CYAN, C_AZURE), LightEmission = 1, LightInfluence = 0 })
	packLayer("Wind", ballAtt, 0.55, 0, 12, "gather", 0.5, { Name = "PackWind", Color = cs(C_AZURE, C_ROYAL), LightEmission = 1, LightInfluence = 0 })
	packLayer("Main-Core-02", ballAtt, 1.6, 0.9, 40, "form", 0.97, { Name = "PackMotes", Color = cs(C_HOT, C_CYAN), LightEmission = 1, LightInfluence = 0 })

	-- sparks riding round it (short comets, never a drawn circle)
	local orbiters = {}
	for i = 1, 2 do
		local a = att(ball, "Orbit" .. i)
		local e = emitter(a, { Name = "Orbit", Texture = T.Glow2, Color = cs(C_WHITE, C_ICE), Size = ns(0, 0.36, 1, 0), Transparency = ns(0, 0, 1, 0.5), Lifetime = nr(0.07), Rate = 60 })
		orbiters[i] = { Att = a, E = e, Tilt = CFrame.Angles(math.rad(70 * i + 15), math.rad(57 * i), 0), Speed = 10 + i * 2.3, Phase = i * 2.1 }
	end
	-- twinkles over its surface
	local twinkle = emitter(ball, with(book("2x2"), { Name = "Twinkle", Texture = T.Spark, Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, Color = cs(C_WHITE, C_ICE), Transparency = ns(0, 0.1, 1, 1), Lifetime = nr(0.12, 0.2), Rotation = nr(0, 360), LockedToPart = true, ZOffset = 1 }))
	-- the streak it leaves as the hands drive it forward
	local trailA = att(ball, "TrailA")
	local trailB = att(ball, "TrailB")
	local thrustTrail = Instance.new("Trail")
	thrustTrail.Attachment0 = trailA
	thrustTrail.Attachment1 = trailB
	thrustTrail.Texture = T.BWisp
	thrustTrail.Color = cs(C_WHITE, C_LIGHT)
	thrustTrail.LightEmission = 1
	thrustTrail.LightInfluence = 0
	thrustTrail.Transparency = ns(0, 0.1, 1, 1)
	thrustTrail.Lifetime = 0.14
	thrustTrail.FaceCamera = true
	thrustTrail.Enabled = false
	thrustTrail.Parent = ball

	-- energy drawn in: streaks and motes fall into it from a shell round it, wisps curl in
	local absorb = U.Part({ Name = "Absorb", Shape = Enum.PartType.Ball, Size = Vector3.one * 9 })
	absorb.Parent = model
	local inStreaks = emitter(absorb, { Name = "Streaks", Texture = T.Needle, Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward, Orientation = Enum.ParticleOrientation.VelocityParallel, Color = cs(C_HOT, C_LIGHT), Size = ns(0, 0.12, 0.3, 0.42, 1, 0.08), Squash = ns(0, 1.4, 1, 2.6), Transparency = ns(0, 1, 0.25, 0.05, 1, 0.3), Lifetime = nr(0.3), Speed = nr(15), LockedToPart = true })
	local inMotes = emitter(absorb, { Name = "Motes", Texture = T.Glow2, Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward, Color = cs(C_ICE, C_LIGHT), Size = ns(0, 0.28, 1, 0.06), Transparency = ns(0, 1, 0.3, 0.1, 1, 0.5), Lifetime = nr(0.42), Speed = nr(10.7), LockedToPart = true })

	-- the hands' own glow (v80's)
	local handFx: { ParticleEmitter } = {}
	for _, name in ipairs({ "Right Arm", "Left Arm" }) do
		local a = part(name)
		if a then
			local ha = Instance.new("Attachment")
			ha.Name = "AzureTideHand"
			ha.Position = Vector3.new(0, -1, 0)
			ha.Parent = a
			maid:Give(ha)
			table.insert(handFx, emitter(ha, { Name = "HandGlow", Texture = T.Glow, Color = cs(C_LIGHT), Size = ns(0, 0.9, 1, 1.3), Transparency = ns(0, 0.6, 1, 1), Lifetime = nr(0.15, 0.22), LockedToPart = true }))
			table.insert(handFx, emitter(ha, { Name = "HandSparks", Texture = T.Needle2, Color = cs(C_ICE), Size = ns(0, 0.12, 1, 0), Transparency = ns(0, 0, 1, 0.6), Lifetime = nr(0.15, 0.3), Speed = nr(3, 7), SpreadAngle = Vector2.new(180, 180), Orientation = Enum.ParticleOrientation.VelocityParallel, Drag = 6 }))
		end
	end

	-- the ground under the caster stirs (v80's dust and motes)
	local groundPart = U.Part({ Name = "Ground", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 9, 9) })
	groundPart.Parent = model
	local gDust = emitter(groundPart, { Name = "Dust", Texture = T.Smoke, Shape = Enum.ParticleEmitterShape.Disc, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface, ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward, EmissionDirection = Enum.NormalId.Right, Color = cs(C_DUST), LightEmission = 0, LightInfluence = 1, Size = ns(0, 1.2, 1, 2.8), Transparency = ns(0, 1, 0.3, 0.8, 1, 1), Lifetime = nr(0.8, 1.2), Speed = nr(2, 4), Rotation = nr(0, 360), RotSpeed = nr(-40, 40) })
	local gMotes = emitter(groundPart, { Name = "Motes", Texture = T.Dots, Shape = Enum.ParticleEmitterShape.Disc, ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume, EmissionDirection = Enum.NormalId.Right, Color = cs(rgb(150, 205, 255)), LightEmission = 0.6, Size = ns(0, 0.12, 1, 0.06), Transparency = ns(0, 0.2, 1, 1), Lifetime = nr(0.8, 1.3), Speed = nr(2, 5), Acceleration = Vector3.new(0, 2, 0), Drag = 1 })

	-------------------------------------------------------------------
	-- the beam (v80's, built now, switched on at the release)
	-------------------------------------------------------------------
	local origin = U.Part({ Name = "Origin" })
	origin.Parent = model
	local a0 = att(origin, "A0")
	local neckPart = U.Part({ Name = "Neck" })
	neckPart.Parent = model
	local aN = att(neckPart, "AN")
	local tipPart = U.Part({ Name = "Tip" })
	tipPart.Parent = model
	local aT = att(tipPart, "AT")
	local tail = U.Part({ Name = "End" })
	tail.Parent = model
	local a1 = att(tail, "A1")
	local surface = att(tail, "Surface")
	local endLight = light(tail, C_LIGHT)
	local muzzleLight = light(origin, C_ICE)

	-- AN ANIME BEAM: a white-hot core in smooth, symmetrical bands of light - cyan, azure, royal, a deep
	-- blue halo - every one a soft band (no streaks, no stray lines), round its solid 3D core. Every
	-- layer is three pieces: it flares out of the sphere (neck), runs (main) and tapers into its end
	-- (tip) - the bands are even along their length, so the joints never show. Edge: how much of a
	-- layer's width is visibly opaque
	type BLayer = { Neck: Beam, Main: Beam, Tip: Beam, W: number, Amp: number, Speed: number, Core: boolean, Edge: number, Z: number, Tr: number, Vis: number }
	local bLayers: { BLayer } = {}
	local function layer(name: string, texture: string, w: number, color: ColorSequence, le: number, tr: number, tl: number, ts: number, z: number, amp: number, speed: number, isCore: boolean, edge: number)
		local props = { Name = name, Texture = texture, Color = color, LightEmission = le, Transparency = ns(tr), TextureLength = tl, TextureSpeed = ts, ZOffset = z, Width0 = w, Width1 = w }
		local function make(x0: Attachment, x1: Attachment, suffix: string): Beam
			return beam(origin, x0, x1, with(props, { Name = name .. suffix, Segments = if suffix == "" then 20 else 10 }))
		end
		table.insert(bLayers, { Neck = make(a0, aN, "Neck"), Main = make(aN, aT, ""), Tip = make(aT, a1, "Tip"), W = w, Amp = amp, Speed = speed, Core = isCore, Edge = edge, Z = z, Tr = tr, Vis = -1 })
	end
	layer("Core", T.CoreBand, 1.7 * BEAM_W, cs(C_WHITE, C_HOT), 1, 0, 8, 3, 1, 0.02, 1, true, 0.9)
	layer("Inner", T.GlowBand, 4.2 * BEAM_W, cs(C_CYAN, C_AZURE), 0.6, 0, 10, 2.5, 0.75, 0.03, 1.2, false, 0.65)
	layer("Body", T.GlowBand, 7.4 * BEAM_W, cs(C_AZURE, C_ROYAL), 0.35, 0.05, 10, 2, 0.5, 0.04, 1.3, false, 0.6)
	layer("Halo", T.GlowBand, 11 * BEAM_W, cs(C_ROYAL, C_DEEP), 0.3, 0.45, 12, 1.5, 0.2, 0.05, 0.9, false, 0.35)

	-- THE BODY FROM ANY SIDE (v80's core and body rods): rounded at both ends (a rod and two balls)
	local function solid(name: string, color: Color3, shape: Enum.PartType): Part
		local p = U.Part({ Name = name, Shape = shape, Material = Enum.Material.Neon, Color = color, Transparency = 1 })
		p.Parent = model
		return p
	end
	local coreRod = solid("CoreRod", C_HOT, Enum.PartType.Cylinder)
	local midRod = solid("MidRod", C_MID, Enum.PartType.Cylinder)
	local midCaps = { solid("MidCapA", C_MID, Enum.PartType.Ball), solid("MidCapB", C_MID, Enum.PartType.Ball) }
	local bodyRod = solid("BodyRod", C_DEEP, Enum.PartType.Cylinder)
	local coreCaps = { solid("CoreCapA", C_HOT, Enum.PartType.Ball), solid("CoreCapB", C_HOT, Enum.PartType.Ball) }
	local bodyCaps = { solid("BodyCapA", C_DEEP, Enum.PartType.Ball), solid("BodyCapB", C_DEEP, Enum.PartType.Ball) }
	-- the energy streaming down its inside (v80's)
	local flow = emitter(a0, { Name = "Flow", Texture = T.Glow, EmissionDirection = Enum.NormalId.Front, Color = cs(C_MID, C_DEEP), Size = ns(0, 5.5 * BEAM_W, 1, 4.6 * BEAM_W), Transparency = ns(0, 0.45, 0.85, 0.5, 1, 1), Lifetime = nr(0.2), Speed = nr(170), Rotation = nr(0, 360), LockedToPart = true })
	local flowCore = emitter(a0, { Name = "FlowCore", Texture = T.Glow2, EmissionDirection = Enum.NormalId.Front, Color = cs(C_CYAN, C_AZURE), Size = ns(0, 2.6 * BEAM_W, 1, 2.2 * BEAM_W), Transparency = ns(0, 0.3, 0.85, 0.35, 1, 1), Lifetime = nr(0.2), Speed = nr(190), LockedToPart = true })

	-- the head: the sphere hurled out ahead of the beam until it lands (v80's stretched ball)
	local head = mesh("Sphere", { Material = Enum.Material.Neon, Color = C_ICE })

	-- the lights along it (they light the world it passes)
	local volume = U.Part({ Name = "Volume", Size = Vector3.new(4, 4, 1) })
	volume.Parent = model
	-- ITS VOLUME: big soft glows filling the beam along its whole length - they always face you, so it is
	-- a massive column from every side (even looking straight down it), in its shades of blue
	local fillPart = U.Part({ Name = "Fill", Size = Vector3.new(1, 1, 1) })
	fillPart.Parent = model
	local fillBox = { Shape = Enum.ParticleEmitterShape.Box, ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume, LockedToPart = true, EmissionDirection = Enum.NormalId.Front, Speed = nr(26, 34) }
	local fillGlow = emitter(fillPart, with(fillBox, { Name = "FillGlow", Texture = T.Glow, Color = cs(C_AZURE, C_ROYAL), Transparency = ns(0, 1, 0.3, 0.55, 1, 1), Lifetime = nr(0.22, 0.3), Rotation = nr(0, 360) }))
	local fillPlasma = emitter(fillPart, with(fillBox, { Name = "FillPlasma", Texture = T.PlasmaBall, Color = cs(C_MID, C_ROYAL, C_DEEP), Brightness = 0.8, Transparency = ns(0, 1, 0.3, 0.6, 1, 1), Lifetime = nr(0.2, 0.28), Rotation = nr(0, 360), RotSpeed = nr(-160, 160) }))
	local fillCore = emitter(fillPart, with(fillBox, { Name = "FillCore", Texture = T.Glow2, Color = cs(C_HOT, C_CYAN), Transparency = ns(0, 1, 0.3, 0.35, 1, 1), Lifetime = nr(0.16, 0.22) }))
	-- its energy sheath: a shimmering force field wrapped round the body - the beam is a solid column in
	-- the world from every side, rounded at both ends like the rest
	local sheath = U.Part({ Name = "Sheath", Shape = Enum.PartType.Cylinder, Material = Enum.Material.ForceField, Color = C_AZURE, Transparency = 1 })
	sheath.Parent = model
	local sheathCaps = {}
	for k = 1, 2 do
		local cap = U.Part({ Name = "SheathCap", Shape = Enum.PartType.Ball, Material = Enum.Material.ForceField, Color = C_AZURE, Transparency = 1 })
		cap.Parent = model
		sheathCaps[k] = cap
	end
	local volLights = {}
	for i = 1, 3 do
		local la = att(volume, "Light" .. i)
		volLights[i] = { Att = la, Light = light(la, C_MID) }
	end

	-- the release's star and its bloom (v80's)
	local releaseFlare = emitter(a0, { Name = "ReleaseFlare", Texture = T.Flare, Color = cs(C_WHITE, C_ICE), Size = ns(0, 2, 0.12, 19, 1, 0), Transparency = ns(0, 0, 0.6, 0.1, 1, 1), Lifetime = nr(0.34), Rotation = nr(0, 360), RotSpeed = nr(-60, 60), ZOffset = 3 })
	local releaseGlow = emitter(a0, { Name = "ReleaseGlow", Texture = T.Glow, Color = cs(C_ICE, C_LIGHT), Size = ns(0, 4, 0.2, 22, 1, 26), Transparency = ns(0, 0.1, 1, 1), Lifetime = nr(0.4), ZOffset = 2.5 })

	-- the muzzle (Beamy's start) and its forward streaks (v80's), sized with the beam
	local function lit(a: Instance?)
		if a then
			for _, e in ipairs(U.Emitters(a)) do
				e.LightEmission = math.max(e.LightEmission, 0.8)
			end
		end
	end
	local muzzleTpl, streamTpl, impactTpl = asset("Muzzle"), asset("MuzzleStream"), asset("Impact")
	local muzzle: Instance? = if muzzleTpl then U.Clone(muzzleTpl, origin, CFrame.new(), 0.34 * BEAM_W) else nil
	local muzzleStream: Instance? = if streamTpl then U.Clone(streamTpl, origin, CFrame.new(), 0.5 * BEAM_W) else nil
	lit(muzzle)
	lit(muzzleStream)

	-- the end (v80's): Beamy's impact, a glow and a flare, sparks and smoke off a surface, a splash back
	local impact: Instance? = if impactTpl then U.Clone(impactTpl, tail, CFrame.new(), 0.5 * BEAM_W) else nil
	lit(impact)
	-- (the end sits on a surface: its sprites are drawn in front of it, never cut off by the ground)
	if impact then
		for _, e in ipairs(U.Emitters(impact)) do
			e.ZOffset += 4
		end
	end
	local endGlow = emitter(a1, { Name = "EndGlow", Texture = T.Glow, Color = cs(C_LIGHT), Size = ns(0, 7 * BEAM_W, 1, 8 * BEAM_W), Transparency = ns(0, 0.35, 1, 1), Lifetime = nr(0.1, 0.14), ZOffset = 5 })
	local endFlare = emitter(a1, { Name = "EndFlare", Texture = T.Flare, Color = cs(C_WHITE, C_LIGHT), Size = ns(0, 5 * BEAM_W, 1, 7 * BEAM_W), Transparency = ns(0, 0.2, 1, 1), Lifetime = nr(0.08, 0.12), Rotation = nr(0, 360), ZOffset = 5.5 })
	local endSparks = emitter(surface, { Name = "SurfaceSparks", Texture = T.Needle, EmissionDirection = Enum.NormalId.Top, Orientation = Enum.ParticleOrientation.VelocityParallel, Color = cs(C_WHITE, C_LIGHT), Size = ns(0, 0.5, 1, 0.05), Squash = ns(2.5), Transparency = ns(0, 0, 1, 0.6), Lifetime = nr(0.15, 0.32), Speed = nr(40, 90), SpreadAngle = Vector2.new(70, 70), Drag = 2, ZOffset = 3 })
	local endSmoke = emitter(surface, { Name = "Smoke", Texture = T.Smoke, EmissionDirection = Enum.NormalId.Top, Color = cs(rgb(150, 175, 205)), LightEmission = 0.1, LightInfluence = 0.8, Size = ns(0, 2.5, 1, 7), Transparency = ns(0, 0.6, 1, 1), Lifetime = nr(0.7, 1.1), Speed = nr(6, 12), SpreadAngle = Vector2.new(50, 50), Rotation = nr(0, 360), RotSpeed = nr(-30, 30), ZOffset = 3 })
	local splash = emitter(a1, { Name = "Splash", Texture = T.Needle2, EmissionDirection = Enum.NormalId.Back, Orientation = Enum.ParticleOrientation.VelocityParallel, Color = cs(C_WHITE, C_LIGHT), Size = ns(0, 0.7, 1, 0.1), Squash = ns(2), Transparency = ns(0, 0, 1, 0.5), Lifetime = nr(0.12, 0.25), Speed = nr(35, 80), SpreadAngle = Vector2.new(70, 70), Drag = 3, ZOffset = 3.5 })

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
		}
	end

	-- DEBRIS: where it grinds into the floor the floor itself is torn out - chunks of that very floor (its
	-- material and colour, the place's own rock mesh in irregular sizes), thrown up and out under
	-- gravity, tumbling, bouncing and rolling to rest, then sinking smoothly away. They never touch a
	-- fighter (the Debris group) and there are never too many
	local rockTpl = meshes and meshes:FindFirstChild("Rock")
	local liveChunks = 0
	local MAX_CHUNKS = 40
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
		local body = U.Solid(rockTpl :: BasePart, {
			Anchored = anchored, CanCollide = not anchored, CastShadow = true, Transparency = 0,
			Material = if turf then Enum.Material.Ground else mat,
			Color = (if turf then SOIL else col):Lerp(Color3.new(0, 0, 0), shade),
		})
		body.Size = if spike then Vector3.new(size * (0.4 + math.random() * 0.35), size * (1.6 + math.random() * 1.1), size * (0.4 + math.random() * 0.35))
			else unit * size * Vector3.new(0.8 + math.random() * 0.5, 0.5 + math.random() * 0.35, 0.8 + math.random() * 0.5)
		body.CollisionGroup = "Debris"
		local parts = { body }
		if turf then
			-- (its grass, still growing on top of it)
			local top = U.Solid(rockTpl :: BasePart, { Anchored = false, CanCollide = false, Massless = true, CastShadow = true, Transparency = 0, Material = mat, Color = col:Lerp(Color3.new(0, 0, 0), shade * 0.5) })
			top.Size = Vector3.new(body.Size.X * 1.05, body.Size.Y * 0.34, body.Size.Z * 1.05)
			top.CollisionGroup = "Debris"
			top.CFrame = body.CFrame * CFrame.new(0, body.Size.Y * 0.36, 0)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = body
			weld.Part1 = top
			weld.Parent = top
			top.Parent = body
			table.insert(parts, top)
		end
		return body, parts
	end
	local function chunk(at: Vector3, n: Vector3, hit: RaycastResult?, power: number, away: Vector3?)
		if not (rockTpl and rockTpl:IsA("BasePart")) or liveChunks >= MAX_CHUNKS then
			return
		end
		local col, mat = floorLook(hit)
		local size = (0.25 + math.random() ^ 2.4 * 1.0) * power
		local rock, parts = piece(col, mat, size, false)
		rock.CFrame = CFrame.new(at + n * (size * 0.35)) * CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
		rock.Parent = U.Holder()
		liveChunks += 1
		-- thrown off the surface and out, the heavier ones lower and slower
		local t = n:Cross(Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5))
		t = if t.Magnitude > 1e-3 then t.Unit else n:Cross(Vector3.xAxis).Unit
		local heft = 1 / (0.6 + size / power)
		rock.AssemblyLinearVelocity = (n * (16 + math.random() * 24) + t * (5 + math.random() * 12) + (away or Vector3.zero) * (6 + math.random() * 10)) * power * heft
		rock.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 20
		-- it settles, then sinks away into the floor and is gone
		local life = 2.6 + math.random() * 1.4
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
	local fizzled = false
	local visLen = 0
	local roomN, roomT = 30, 30 -- (the room the flat layers have, the way they spread on this screen, at
	-- the neck and at the tip end of the main run)
	local roomAll = 30 -- (the room the solid core and body have, all round)
	local lastTau = 0
	local nextTendril, nextArc, nextShake, nextFlare, nextPulse = 0, 0, 0, 0, 0
	local tendrils: { any } = {}
	local bolts: { any } = {}
	local sphereR = 0
	local fireR = 0.9 -- (the sphere's radius the moment it fired: the beam grows out of exactly that)
	local lastSized = -1
	local landedOnce = false
	local lastHitPop = -1
	local tint: ColorCorrectionEffect? = nil -- (the caster's own view, tinted as the charge peaks)

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
		if not tint or tint.Parent ~= cam then
			if tint then
				tint:Destroy()
			end
			tint = Instance.new("ColorCorrectionEffect")
			tint.Name = "AzureTideCharge"
			tint.Parent = cam
		end
		local t = tint :: ColorCorrectionEffect
		t.TintColor = Color3.new(1, 1, 1):Lerp(rgb(214, 234, 255), k)
		t.Contrast = 0.1 * k
		t.Saturation = 0.08 * k
		t.Brightness = 0.025 * k
	end
	maid:Give(function()
		setTint(0)
	end)

	-- one wisp curling into the sphere
	local function tendril(strength: number)
		local a = Instance.new("Attachment")
		local dir = Vector3.new(math.random() - 0.5, math.random() * 0.8 - 0.2, math.random() - 0.5)
		dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.xAxis
		a.Position = dir * (3.4 + math.random() * 2.6)
		a.Parent = ball
		local b = beam(ball, a, ballAtt, {
			Texture = T.BWisp, Color = cs(C_HOT, C_LIGHT), Width0 = 0.05, Width1 = 0.05, Enabled = true,
			TextureLength = 3, TextureSpeed = 3.5, Transparency = ns(0, 1, 0.4, 0.2, 1, 0.05),
			CurveSize0 = (math.random() - 0.5) * 4, CurveSize1 = (math.random() - 0.5) * 3, Segments = 10,
		})
		table.insert(tendrils, { Att = a, Beam = b, Born = os.clock(), Life = 0.3 + math.random() * 0.15, W = 0.4 + 0.6 * strength })
	end
	-- a bolt snapping off the sphere
	local function bolt(r: number, big: boolean)
		local a = Instance.new("Attachment")
		local dir = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
		dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
		a.Position = dir * (r * (if big then 2 else 1.5) + 0.5 + math.random() * (if big then 2 else 1.2))
		a.Parent = ball
		local b = beam(ball, ballAtt, a, {
			Texture = if math.random() < 0.5 then T.BLightning else T.BBolt, Color = cs(C_WHITE, C_ICE), Enabled = true,
			Width0 = if big then 0.8 else 0.5, Width1 = 0.12, TextureLength = 3, TextureSpeed = 0,
			Transparency = ns(0, 0, 1, 0.3), Segments = 6, ZOffset = 1.2,
			CurveSize0 = (math.random() - 0.5) * 2.5, CurveSize1 = (math.random() - 0.5) * 2.5,
		})
		table.insert(bolts, { Att = a, Beam = b, Born = os.clock(), Life = 0.06 + math.random() * 0.06 })
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
		for _, e in ipairs({ inStreaks, inMotes, twinkle }) do
			e.Enabled = false
		end
		if charge then
			U.Enable(charge, false)
		end
		thrustTrail.Enabled = false
		if muzzle then
			U.Enable(muzzle, true)
		end
		if muzzleStream then
			U.Enable(muzzleStream, true)
		end
		-- the release's star and bloom start at the sphere's own size (v80's, bigger with the beam)
		local k = math.clamp(fireR / 0.9, 0.7, 1.4) * BEAM_W * 0.85
		releaseFlare.Size = ns(0, 2 * k, 0.12, 19 * k, 1, 0)
		releaseGlow.Size = ns(0, fireR * 2.5, 0.2, 22 * k, 1, 26 * k)
		releaseFlare:Emit(1)
		releaseGlow:Emit(1)
		local cf = U.Look(from, dir)
		local holder = U.Holder()
		-- the pack's release burst off the hands (Beam Release: smoke, streaks)
		fire("Release", cf, 0.2 * BEAM_W, holder, nil, function(e)
			if e.Name == "SmokeCirc" then
				e:Destroy()
			end
		end)
		-- the ground under the caster takes the blast
		if root then
			local g = o.World(root.Position, Vector3.new(0, -8, 0))
			if g then
				fire("GroundBlast", U.Up(g.Position + g.Normal * 0.2, g.Normal), 0.3 * BEAM_W, holder, nil, function(e)
					e.ZOffset += 3
				end)
			end
		end
		-- a white-hot pop that starts exactly the sphere's size, the light and the view
		fireball(from, fireR * 2, 9 * BEAM_W, 0.24, holder)
		flashLight(from, C_ICE, 6, 32, 0.4)
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

	-- THE BLAST: the beam's energy collapses into its end and detonates - the place's own explosions,
	-- layered and timed into one
	local blasted = false
	local function blastAt(at: Vector3, dir: Vector3, n: Vector3?)
		if blasted then
			return
		end
		blasted = true
		local holder = Instance.new("Folder")
		holder.Name = "AzureTideBlast"
		holder.Parent = U.Holder()
		Debris:AddItem(holder, 8)
		-- its heart stands off the surface it hit (never half inside a wall, a floor or a ceiling)
		local c = if n then at + n * 3.5 else at - dir * 1.5
		-- how much room it has: a blast in a corridor is a corridor's blast, not one through the walls
		local free, probes = 0, 0
		for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis, Vector3.new(1, 1, 1).Unit, Vector3.new(-1, 1, -1).Unit, Vector3.new(1, 1, -1).Unit, Vector3.new(-1, 1, 1).Unit }) do
			local hit = o.World(c, d * 22)
			free += if hit then (hit.Position - c).Magnitude else 22
			probes += 1
		end
		-- the blast's scale: as big as the beam has become (its final size), as much as the room allows
		local gEnd = if AbilityConfig.BeamGrow then AbilityConfig.BeamGrow(def, TL.Sustain) else 1
		local S = math.clamp((free / probes) / 14, 0.6, 1.3) * math.max(1, gEnd * 0.85)
		local g = o.World(c + Vector3.new(0, 1, 0), Vector3.new(0, -14 * S - 3, 0))
		local gUp = if g then g.Normal else Vector3.yAxis
		local gAt = if g then g.Position + g.Normal * 0.1 else c - Vector3.new(0, 2, 0)
		-- (its heart stands high enough off the ground that nothing of it starts below it)
		if g then
			local hc = (c - gAt):Dot(gUp)
			if hc < 3.5 * S then
				c += gUp * (3.5 * S - hc)
			end
		end
		local heart = U.Up(c, gUp)

		-- the place's implode-explosion: everything crushes into the end, then it detonates (the pack's
		-- own timing - the detonation is 0.2 s in; everything else lands with it)
		fire("Nova", heart, 0.5 * S, holder, nil, nil, true)
		oneShot("BlastCrack", c, { PlaybackSpeed = 0.9 })
		task.delay(0.2, function()
			if not holder.Parent then
				return
			end
			-- the FinalExplosion (azure) at its heart, the pack's small blast in it
			fire("EndBlast", heart, 0.7 * S, holder, nil, nil, true)
			fire("EndBlastSmall", heart, 1.1 * S, holder, nil, nil, true)
			-- the Explosion pack's smoke, dust and wind on the ground under it (v80's blast, bigger)
			fire("Blast", U.Up(gAt + gUp * 0.3, gUp) * CFrame.Angles(0, math.random() * math.pi * 2, 0), 0.75 * S, holder, 0.7, nil, true)
			-- the ground under it torn out and thrown (chunks of that very ground)
			if g and (gAt - c).Magnitude < 10 * S then
				for i = 1, math.floor(14 * S + 0.5) do
					local ang = (i / 14) * math.pi * 2 + math.random() * 0.5
					local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
					local q = o.World(gAt + out * math.random() * 4 * S + gUp * 3, -gUp * 6)
					chunk(if q then q.Position else gAt, gUp, q or g, 1.25 * S, out)
				end
			end
			-- a white-hot heart swelling out of the end
			fireball(c, 3 * S, 22 * S, 0.6, holder, if g then gAt else nil, if g then gUp else nil)
			-- and the energy dome round it, slower and bigger
			fireball(c, 6 * S, 34 * S, 1.25, holder, if g then gAt else nil, if g then gUp else nil)
			flashLight(c + gUp * 3, C_ICE, 14, 70 * S, 2.2, holder)
			flashFor(c, 0.9, 0.45)
			oneShot("End", c)
			oneShot("EndCrack", c)
			oneShot("Blast", c, { PlaybackSpeed = 0.72 })
			nearKick(c, 70, 1.2, "BeamBoomNear")
			if o.Mine then
				camera("BeamBoom", dir, 1)
			end
			-- secondary bursts round it, one after another (the pack's small blast)
			for i = 1, 4 do
				task.delay(0.05 + i * 0.08 + math.random() * 0.04, function()
					if not holder.Parent then
						return
					end
					local d = Vector3.new(math.random() - 0.5, math.random() * 0.8, math.random() - 0.5)
					d = if d.Magnitude > 1e-3 then d.Unit else Vector3.yAxis
					local at2 = c + d * (5 + math.random() * 5) * S
					local up2 = gUp
					local hit = o.World(c, at2 - c)
					if hit then
						at2 = hit.Position + hit.Normal * 1.5
						up2 = hit.Normal
					end
					-- (never under the ground)
					local floor2 = o.World(at2 + gUp * 2, -gUp * 4)
					if floor2 then
						at2 = floor2.Position + floor2.Normal * 1.5
						up2 = floor2.Normal
					end
					fire("EndBlastSmall", U.Up(at2, up2), 0.55 * S, holder, 0.7, nil, true)
				end)
			end
		end)
	end

	local function collapse(why: string)
		if endedAt then
			return
		end
		endedAt = os.clock()
		h.Phase = "Collapse"
		for _, e in ipairs({ splash, endSmoke, endSparks, fillGlow, fillPlasma, fillCore }) do
			e.Enabled = false
		end
		for _, a in pairs({ muzzle, muzzleStream, impact }) do
			U.Enable(a, false)
		end
		for _, L in ipairs(sLayers) do
			L.E.Enabled = false
		end
		for _, P in ipairs(pLayers) do
			P.E.Enabled = false
		end
		if why ~= "Interrupted" then
			local n = surface:GetAttribute("Normal")
			blastAt(tail.Position, aim, if typeof(n) == "Vector3" then n else nil)
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
		for _, e in ipairs({ inStreaks, inMotes, twinkle, gDust, gMotes }) do
			e.Enabled = false
		end
		for _, e in ipairs(handFx) do
			e.Enabled = false
		end
		for _, ob in ipairs(orbiters) do
			ob.E.Enabled = false
		end
		if charge then
			U.Enable(charge, false)
		end
		thrustTrail.Enabled = false
		if sphereR > 0.05 then
			-- the gathered energy bursts apart
			sPlasma:Emit(4)
			sArcs:Emit(3)
			sArcBurst:Emit(1)
			sFlare:Emit(1)
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
	local function hideBeam()
		for _, L in ipairs(bLayers) do
			L.Neck.Enabled = false
			L.Main.Enabled = false
			L.Tip.Enabled = false
		end
		for _, p in ipairs({ coreRod, midRod, bodyRod, coreCaps[1], coreCaps[2], midCaps[1], midCaps[2], bodyCaps[1], bodyCaps[2], sheath, sheathCaps[1], sheathCaps[2] }) do
			p.Transparency = 1
		end
		for _, p in pairs({ head, core, body, swirl, skin, void }) do
			p.Transparency = 1
		end
		flow.Enabled = false
		flowCore.Enabled = false
		endGlow.Enabled = false
		endFlare.Enabled = false
	end

	local function finish()
		if not h.Alive then
			return
		end
		h.Alive = false
		RunService:UnbindFromRenderStep(h.Bind)
		hideBeam()
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
		-- straight into the beam's root
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
		if firedAt then
			-- the beam's root: from exactly the size it fired at, it swells into the root the beam pours
			-- out of, and settles
			local bulb = 0.95 * BEAM_W
			local k = U.EaseOut(U.Clamp01(since0 / 0.16))
			r = (fireR + (bulb * 1.15 - fireR) * k) * (1 - 0.13 * U.Ramp(0, 1, (since0 - 0.16) / 0.4))
			r *= 1 + 0.06 * U.Noise(now * 11, seed + 3)
		end
		if fizzled then
			local k = U.Clamp01((now - (endedAt or now)) / 0.16)
			r = sphereR * (1 + 0.7 * k) * (1 - k)
		elseif endedAt and firedAt then
			local k = U.Clamp01((now - endedAt) / TL.Collapse)
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
			zRoom = math.clamp(least - 0.1, math.min(0.15, rv * 0.8), math.max(0.15, rv * 0.8))
		end
		local ballPos = target
		ball.CFrame = U.Look(ballPos, aim)
		ball.Size = Vector3.one * math.max(0.2, rv * 1.9)
		absorb.CFrame = ball.CFrame
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
			if charge then
				for _, e in ipairs(U.Emitters(charge)) do
					if e.Name ~= "Core1" then
						e.Size = ns(0, rv * 2.6, 1, rv * 1)
					else
						e.Size = ns(rv * 0.9)
					end
				end
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
		-- the disk's tilt: flat round the sphere, leaning toward the view behind the caster, precessing
		local dn = (Vector3.yAxis * 0.85 - aim * 0.5 + Vector3.new(math.sin(now * 0.9), 0, math.cos(now * 0.7)) * 0.08).Unit
		local dr = dn:Cross(aim)
		dr = if dr.Magnitude > 1e-3 then dr.Unit else Vector3.xAxis
		diskAtt.WorldCFrame = CFrame.fromMatrix(ballPos, dr, dn)
		setSolid(swirl, math.min(rv * 1.55, palmRoom * 2 + 0.2), ball.CFrame * spin:Inverse(), 1 - (0.38 + 0.12 * surge) * formed)
		setSolid(skin, math.min(rv * 1.9, palmRoom * 2 + 0.35), ball.CFrame * spin, 1 - 0.7 * formed)
		-- the streak behind it as the hands drive it out
		trailA.Position = Vector3.new(0, rv * 0.6, 0)
		trailB.Position = Vector3.new(0, -rv * 0.6, 0)
		thrustTrail.Enabled = drive > 0 and not firedAt and not fizzled
		for _, ob in ipairs(orbiters) do
			local ang = now * ob.Speed + ob.Phase
			ob.Att.Position = (ob.Tilt * CFrame.new(math.cos(ang) * rv * 1.4, 0, math.sin(ang) * rv * 1.4)).Position
		end

		---------------------------------------------------------------
		-- the charge (every layer comes in by its rate - nothing pops on)
		---------------------------------------------------------------
		local charging = not fizzled and not firedAt
		local alive = not fizzled and not endedAt
		local on = alive and r > 0.03
		if alive then
			local inten = if firedAt then 1 else math.clamp(0.25 + 0.45 * grow + 0.3 * surge + 0.3 * white, 0, 1.3)
			local formedRate = if firedAt then 1 else formed
			sCore.Enabled = on
			sCore.Rate = 6 + 8 * math.max(wake, formedRate)
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
			sRim.Enabled = on
			sRim.Rate = 2 + 8 * formedRate
			sRays.Enabled = on and (surge > 0 or firedAt ~= nil)
			sRays.Rate = 14 * surge + (if firedAt then 6 else 0)
			sBloom.Enabled = on
			sBloom.Rate = 2 + 3 * math.max(wake, formedRate)
			sArcs.Enabled = on and (surge > 0 or firedAt ~= nil)
			sArcs.Rate = 16 * surge + (if firedAt then 8 else 0)
			sArcRing.Enabled = on and surge > 0 and charging
			sArcRing.Rate = 8 * surge
			sArcBurst.Enabled = false
			sFlare.Enabled = false
			-- the black hole: the bright heart goes dark, the rims burn, the disk spins up
			sCore.Rate *= 1 - 0.9 * bh
			sPlasma.Rate *= 1 - 0.75 * bh
			sChaos.Rate *= 1 - 0.8 * bh
			sSwirlA.Rate += 10 * bh
			sRim.Rate += 10 * bh
			for _, e in ipairs({ dGlow, dSwirl, dStreak, dDark, sPhoton, sLens, sVoid }) do
				e.Enabled = on and bh > 0.01
			end
			sVoid.Rate = 45 * bh
			dGlow.Rate = 8 * bh
			dSwirl.Rate = 18 * bh
			dStreak.Rate = 22 * bh
			dDark.Rate = 10 * bh
			sPhoton.Rate = 30 * bh
			sLens.Rate = 8 * bh
			twinkle.Enabled = on and charging
			twinkle.Rate = (3 + 16 * surge) * formed
			if charge then
				U.Enable(charge, on and charging and tau >= TL.Sphere)
			end
			for _, ob in ipairs(orbiters) do
				ob.E.Enabled = on and charging and grow > 0.25
			end
			for _, P in ipairs(pLayers) do
				local m = if P.Phase == "grow" then (if firedAt then 1 else grow)
					elseif P.Phase == "surge" then (if firedAt then 0.4 else surge)
					elseif P.Phase == "gather" then (if firedAt then 0 else gather * (1 - crush))
					else formedRate
				P.E.Enabled = on and m > 0.01
				P.E.Rate = P.Rate * m
				P.E.ZOffset = zRoom * P.Z
			end
			-- its heartbeat: a soft swell of light, quicker and harder as it surges
			if charging and on and tau >= TL.Sphere and now >= nextPulse then
				nextPulse = now + U.Ramp(0.42, 0.12, surge)
				sBloom:Emit(1)
				sCore:Emit(1)
				if surge > 0.15 then
					sRays:Emit(1)
				end
			end
			-- flares and bursts snap off it in the last moments
			if charging and on and surge > 0.45 and now >= nextFlare then
				nextFlare = now + U.Ramp(0.45, 0.2, surge) * (0.7 + math.random() * 0.6)
				sFlare:Emit(1)
				if math.random() < 0.35 then
					sArcBurst:Emit(1)
				end
			end
		end
		-- the energy drawn in
		local drawing = charging and tau >= TL.Gather and tau < TL.Thrust
		inStreaks.Enabled = drawing
		inMotes.Enabled = drawing
		if drawing then
			inStreaks.Rate = 14 + 90 * gather
			inMotes.Rate = 8 + 36 * gather
			local R = 5 - 1.6 * gather
			absorb.Size = Vector3.one * R * 2
			inStreaks.Speed = nr(R / 0.3)
			inMotes.Speed = nr(R / 0.42)
			if tau >= TL.Compress - 0.05 and not played.Inhale then
				-- the last breath: everything round it is sucked in at once
				played.Inhale = true
				inStreaks:Emit(40)
				inMotes:Emit(16)
			end
			if now >= nextTendril then
				tendril(gather)
				nextTendril = now + U.Ramp(0.15, 0.035, gather)
			end
		end
		for i = #tendrils, 1, -1 do
			local w = tendrils[i]
			local k = (now - w.Born) / w.Life
			if k >= 1 or firedAt or fizzled then
				w.Beam:Destroy()
				w.Att:Destroy()
				table.remove(tendrils, i)
			else
				local width = w.W * math.sin(k * math.pi)
				w.Beam.Width0 = width
				w.Beam.Width1 = width * 0.4
				w.Att.Position *= 1 - dt * 2.4
			end
		end
		if charging and surge > 0 and now >= nextArc then
			bolt(rv, surge > 0.6 and math.random() < 0.4)
			nextArc = now + U.Ramp(0.18, 0.04, surge)
		end
		for i = #bolts, 1, -1 do
			local b = bolts[i]
			if now - b.Born >= b.Life or fizzled or firedAt then
				b.Beam:Destroy()
				b.Att:Destroy()
				table.remove(bolts, i)
			end
		end
		-- the hands
		for _, e in ipairs(handFx) do
			e.Enabled = alive and tau > 0.04
			e.Rate = if e.Name == "HandGlow" then 10 + 30 * wake else 4 + 20 * gather
		end
		-- the ground under the caster
		local power = if fizzled then 0 elseif firedAt then (if endedAt then 0 else 1) else surge
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
		-- light (kept low on the sphere: any brighter and it bleaches the arms holding it into a blur)
		local lb = if firedAt then 1.3 else (0.15 * wake + 0.55 * U.EaseOut(grow) + 0.45 * surge + 0.6 * white)
		if fizzled or endedAt then
			lb *= 1 - U.Clamp01((now - (endedAt :: number)) / 0.2)
		end
		ballLight.Brightness = lb
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
			return
		end

		---------------------------------------------------------------
		-- the beam
		---------------------------------------------------------------
		local since = since0
		if type(frozen) == "number" and frozen >= TL.Fire then
			since = math.min(frozen - TL.Fire, TL.Sustain - 0.01)
		end
		if not endedAt and since >= TL.Sustain + 0.05 then
			-- (the server's Stop ends it on time; this is the screen's own end if that word is late)
			collapse("Done")
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
		local g = if AbilityConfig.BeamGrow then AbilityConfig.BeamGrow(def, since) else 1
		local length, normal, stopper = BeamMath.Trace(from, aim, B.Range, B.HitRadius * g, B.StopRadius * math.sqrt(g), o.Bodies(), o.World)
		if blockedAt then
			length, normal, stopper = 0.3, blockedAt.Normal, nil
		end
		-- shorter: at once (the contact is exact); longer: the head races out to it
		if length < visLen then
			-- (shorter: it pulls back to the new end fast but smoothly - it never jumps)
			visLen = math.max(length, visLen + (length - visLen) * math.min(1, dt * 28))
		else
			visLen = math.min(length, visLen + dt * (420 + 1600 * math.min(since, 0.25)))
		end
		local reached = visLen >= length - 0.05
		local coll = if endedAt then U.Clamp01((now - endedAt) / TL.Collapse) else 0
		-- the tail leaves the sphere and chases the head as it dies
		local startAt = visLen * coll * coll
		local p0 = from + aim * startAt
		local p1 = from + aim * visLen
		local span = math.max(0.05, visLen - startAt)
		-- (it flares out of the sphere over a long neck: by the caster it is still the sphere's size -
		-- never past his head - and it is massive further out)
		local neckLen = math.min(math.max(6 * BEAM_W, 7.4 * BEAM_W * g * 1.5), span * 0.5)
		local tipLen = math.min(4 * BEAM_W * g, span * 0.25)
		local pN = p0 + aim * neckLen
		local pT = p1 - aim * tipLen
		origin.CFrame = U.Look(p0, aim)
		neckPart.CFrame = U.Look(pN, aim)
		tipPart.CFrame = U.Look(pT, aim)
		tail.CFrame = U.Look(p1, aim)
		muzzleLight.Brightness = 2.2 * (1 - coll)
		muzzleLight.Range = 16 * (1 - coll)

		-- THE ROOM ROUND IT. The flat layers face the camera: they spread across the beam the way this
		-- screen sees it - so that is the only way they need room (seen from behind, they spread level
		-- and a floor never touches them). The solid core and body need it all round. Each is measured
		-- where it counts (the neck, the tip end of the main run) and the widths follow it along the beam
		-- - it narrows only where a surface is closer than its edge, eased so it never pops. (Surfaces
		-- right at the end are where it lands: the impact is meant to meet them)
		local cam = workspace.CurrentCamera
		local spread = aim:Cross(if cam then cam.CFrame.LookVector else Vector3.yAxis)
		if spread.Magnitude < 0.2 then
			spread = aim:Cross(Vector3.yAxis)
		end
		spread = if spread.Magnitude > 1e-3 then spread.Unit else Vector3.xAxis
		local side = aim:Cross(Vector3.yAxis)
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
		local upV = side:Cross(aim).Unit
		local landing = normal ~= nil and reached
		local keepOut = if landing then 5 * BEAM_W else 0
		local function probe(q: Vector3, dirs: { Vector3 }, len: number): number
			local least = len
			for _, d in ipairs(dirs) do
				local hit = o.World(q, d * len)
				if hit and (keepOut <= 0 or (hit.Position - p1).Magnitude > keepOut) then
					least = math.min(least, (hit.Position - q).Magnitude)
				end
			end
			return least
		end
		local spreadDirs = { spread, -spread }
		local allDirs = { upV, -upV, side, -side }
		local wantN = probe(pN, spreadDirs, 30)
		local wantT = if span > neckLen + tipLen + 1 then probe(pT, spreadDirs, 30) else wantN
		local wantM = if span > neckLen + tipLen + 4 then probe((pN + pT) * 0.5, spreadDirs, 30) else math.min(wantN, wantT)
		-- (a bump between the two ends: both ends make room for it)
		if wantM < (wantN + wantT) * 0.5 - 0.5 then
			wantN = math.min(wantN, wantM)
			wantT = math.min(wantT, wantM)
		end
		local wantA = math.min(probe(p0 + aim * math.min(span * 0.5, neckLen * 0.5), allDirs, 14), probe((pN + pT) * 0.5, allDirs, 14))
		if span > neckLen + tipLen + 1 then
			wantA = math.min(wantA, probe(pT, allDirs, 14))
		end
		local function ease(cur: number, want: number): number
			return cur + (want - cur) * math.min(1, dt * (if want < cur then 25 else 5))
		end
		roomN = ease(roomN, wantN)
		roomT = ease(roomT, wantT)
		roomAll = ease(roomAll, wantA)

		-- the layers: they swell out of the sphere at the release, breathe while it lives, thin as it dies
		local swell = 1 + 0.35 * math.exp(-since * 9) * (1 - math.exp(-since * 60))
		local fade = (1 - coll) ^ 1.5
		local grow0 = 0.3 + 0.7 * U.EaseOut(since / 0.12)
		local show = span > 0.15
		-- (a flat band seen straight down its length folds edge-on and flickers: there it gives way
		-- smoothly to the beam's 3D core and its glows, which look the same from every side)
		local along = if cam then math.abs(cam.CFrame.LookVector:Dot(aim)) else 0
		local bandVis = 1 - U.Clamp01((along - 0.82) / 0.14)
		local rootW = rv * 2.2 -- (the sphere's own width: the neck starts exactly there)
		for i, L in ipairs(bLayers) do
			local nz = U.Noise(now * L.Speed * 3, seed + i * 7.1)
			local breathe = 1 + L.Amp * nz
			local thin = if L.Core then (1 - coll) else fade
			local w = L.W * g * breathe * swell * grow0 * thin
			-- (as it swells it is let into the ground it wrecks - drawn in front of it, so it never shows
			-- a cut edge - and torn-up rock rises along its edges; small, it keeps clear of it)
			local give = w * 0.42 * U.Clamp01((g - 0.7) / 0.9)
			local wN = math.min(w, 2 * (math.max(0.45, roomN - 0.1) + give) / L.Edge)
			local wT = math.min(w, 2 * (math.max(0.45, roomT - 0.1) + give) / L.Edge)
			local lift = w * L.Edge * 0.5
			L.Neck.ZOffset = L.Z
			L.Main.ZOffset = L.Z + lift
			L.Tip.ZOffset = L.Z + lift
			local vis = show and thin > 0.02
			L.Neck.Width0 = math.min(wN, rootW)
			L.Neck.Width1 = wN
			L.Main.Width0 = wN
			L.Main.Width1 = wT
			L.Tip.Width0 = wT
			L.Tip.Width1 = wT * 0.5
			L.Neck.Enabled = vis
			L.Main.Enabled = vis
			L.Tip.Enabled = vis
			if math.abs(bandVis - L.Vis) > 0.03 then
				L.Vis = bandVis
				local t = ns(L.Tr + (1 - L.Tr) * (1 - bandVis))
				L.Neck.Transparency = t
				L.Main.Transparency = t
				L.Tip.Transparency = t
			end
		end
		-- the solid core and body: capsules from the sphere to the end (the body grows out of the neck)
		local roomD = 2 * math.max(0.3, roomAll - 0.05)
		local live = span > 0.4
		local function capsule(rod: BasePart, caps: { BasePart }, s0: number, d: number, t: number)
			local a = p0 + aim * math.min(s0, span * 0.5)
			local len = math.max(0.05, (p1 - a).Magnitude - d)
			local c3 = (a + p1) * 0.5
			rod.Size = Vector3.new(len, d, d)
			rod.CFrame = CFrame.lookAt(c3, c3 + aim) * CFrame.Angles(0, math.rad(90), 0)
			rod.Transparency = if live and d > 0.03 then t else 1
			local ends = { a + aim * (d * 0.5), p1 - aim * (d * 0.5) }
			for k, cap in ipairs(caps) do
				cap.Size = Vector3.one * d
				cap.CFrame = CFrame.new(ends[k])
				cap.Transparency = if live and d > 0.03 then t else 1
			end
		end
		local wc = math.min(1.0 * BEAM_W * g * swell * grow0 * (1 - coll) + 0.02, roomD * 0.35, span)
		local wm = math.min(2.5 * BEAM_W * g * swell * grow0 * (1 - coll) + 0.03, roomD * 0.7, span)
		local wb = math.min(3.9 * BEAM_W * g * swell * grow0 * fade + 0.05, roomD, span)
		capsule(coreRod, coreCaps, 0, wc, 0.05 + 0.9 * coll)
		capsule(midRod, midCaps, neckLen * 0.25, wm, 0.35 + 0.6 * coll + 0.05 * U.Noise(now * 14, seed + 4))
		capsule(bodyRod, bodyCaps, neckLen * 0.5, wb, 0.5 + 0.48 * coll + 0.05 * U.Noise(now * 18, seed + 2))
		-- the shimmering sheath round the body (it breathes with the beam)
		local ws = math.min(5.2 * BEAM_W * g * swell * grow0 * fade * (1 + 0.04 * U.Noise(now * 6, seed + 5)), roomD, span)
		capsule(sheath, sheathCaps, neckLen * 0.8, ws, 0.15 + 0.85 * coll)
		-- (the energy streaming down the inside never runs past the end)
		flow.Lifetime = nr(math.max(0.02, span / 170))
		flowCore.Lifetime = nr(math.max(0.02, span / 190))
		-- (born small in the sphere, swelling as it streams out: nothing big ever sits by the caster)
		local fw = 5.5 * BEAM_W * g * 0.8
		flow.Size = ns(0, math.min(fw, rv * 1.6), 0.3, fw, 1, fw * 0.85)
		flowCore.Size = ns(0, math.min(fw * 0.47, rv), 0.3, fw * 0.47, 1, fw * 0.4)
		flow.ZOffset = fw * 0.45
		flowCore.ZOffset = fw * 0.45 + 0.4
		flow.Enabled = live and not endedAt
		flowCore.Enabled = live and not endedAt
		flow.Rate = 80
		flowCore.Rate = 60
		-- the head: the sphere hurled out ahead of the beam until it lands
		local traveling = not reached and not endedAt
		if head then
			if traveling then
				local hd = math.max(rv * 2.6, 1.5 * BEAM_W * g)
				local stretch = math.clamp(visLen * 0.4, hd, 9 * BEAM_W * g)
				head.Size = Vector3.new(hd, hd, stretch)
				head.CFrame = U.Look(p1 - aim * stretch * 0.35, aim)
				head.Transparency = 0.05
			else
				head.Transparency = 1
			end
		end
		-- the lights along it
		volume.Size = Vector3.new(1, 1, math.max(0.2, span))
		volume.CFrame = U.Look(p0 + aim * span * 0.5, aim)
		-- its volume: from the neck on, sized to the beam (drawn in front of any ground it reaches)
		do
			local fillLen = span - neckLen * 0.7
			local fv = 7.4 * BEAM_W * g * 0.62 * fade
			fillPart.Size = Vector3.new(0.5, 0.5, math.max(0.2, fillLen))
			fillPart.CFrame = U.Look(p0 + aim * (neckLen * 0.7 + math.max(0.2, fillLen) * 0.5), aim)
			local fillOn = not endedAt and fillLen > 2
			fillGlow.Enabled = fillOn
			fillPlasma.Enabled = fillOn
			fillCore.Enabled = fillOn
			if fillOn then
				fillGlow.Size = ns(0, fv * 0.85, 1, fv)
				fillPlasma.Size = ns(0, fv * 0.7, 1, fv * 0.85)
				fillCore.Size = ns(0, fv * 0.3, 1, fv * 0.36)
				fillGlow.ZOffset = fv * 0.5
				fillPlasma.ZOffset = fv * 0.5 + 0.2
				fillCore.ZOffset = fv * 0.5 + 0.5
				local density = math.clamp(fillLen / math.max(1, fv * 0.5), 2, 90)
				fillGlow.Rate = density * 4
				fillPlasma.Rate = density * 3
				fillCore.Rate = density * 4
			end
		end
		for i, vl in ipairs(volLights) do
			vl.Att.Position = Vector3.new(0, 0, span * (0.5 - i / 4))
			vl.Light.Brightness = (0.8 + 0.2 * U.Noise(now * 7, seed + i)) * fade
			vl.Light.Range = 18 * fade * g
		end
		-- the end
		local onBody = stopper ~= nil
		local hitWorld = normal ~= nil and not onBody
		local landed = reached and not endedAt and normal ~= nil
		surface:SetAttribute("Normal", if hitWorld then normal else nil)
		endLight.Brightness = (if landed then 2.6 else 1.2) * fade * (1 + 0.15 * U.Noise(now * 15, seed + 9))
		endLight.Range = 22 * fade
		if impact then
			U.Enable(impact, landed)
		end
		if math.abs(g - (h.LastG or 0)) > 0.02 then
			h.LastG = g
			endGlow.Size = ns(0, 7 * BEAM_W * g, 1, 8 * BEAM_W * g)
			endFlare.Size = ns(0, 5 * BEAM_W * g, 1, 7 * BEAM_W * g)
		end
		endGlow.Enabled = not endedAt
		endGlow.Rate = 30
		endFlare.Enabled = not endedAt
		endFlare.Rate = 12
		splash.Enabled = landed
		splash.Rate = 30
		endSparks.Enabled = landed and hitWorld
		endSparks.Rate = 45
		endSmoke.Enabled = landed and hitWorld
		endSmoke.Rate = 8
		if hitWorld then
			surface.WorldCFrame = U.Up(p1 + (normal :: Vector3) * 0.15, normal :: Vector3)
		else
			surface.WorldCFrame = U.Up(p1, -aim)
		end
		if landed and not landedOnce then
			landedOnce = true
			if o.Mine then
				camera("BeamHit", -aim, 1)
			end
			nearKick(p1, 40, 0.8)
		end
		-- each of the beam's hits (the server's ticks: Beam.Tick apart from the release) lands as a burst
		-- where it ends, in time with the damage (v80's)
		if landed then
			local k = math.floor(since / B.Tick)
			if k > lastHitPop and since < TL.Sustain then
				lastHitPop = k
				local n = (if hitWorld then normal else -aim) :: Vector3
				fire("EndBlastSmall", U.Up(p1 + n * 0.3, n), 0.32 * BEAM_W * g, nil, 0.7, nil, true)
				fire("BlastHit", U.Up(p1 + n * 0.2, n) * CFrame.Angles(0, math.random() * 6.28, 0), g, nil, 0.6, nil, true)
			end
		end
		-- the ground under its path, stirred wherever it is close
		local kick = not endedAt and span > 4
		for i, tp in ipairs(trailPts) do
			local onG = false
			if kick then
				local q = p0 + aim * (span * (i - 0.5) / TRAIL)
				local fl = o.World(q, Vector3.new(0, -8, 0))
				if fl then
					onG = true
					local closeness = 1 - (q.Y - fl.Position.Y) / 8
					tp.Att.WorldCFrame = U.Up(fl.Position + fl.Normal * 0.2, fl.Normal)
					tp.Dust.Rate = 10 * closeness
				end
			end
			tp.Dust.Enabled = onG
		end
		if endLoop then
			local want = if landed then (endLoop:GetAttribute("Base") :: number) else 0
			endLoop.Volume += (want - endLoop.Volume) * math.min(1, dt * 12)
		end
		if roar then
			local want = if endedAt then 0 else (roar:GetAttribute("Base") :: number)
			roar.Volume += (want - roar.Volume) * math.min(1, dt * (if endedAt then 14 else 20))
		end
		-- the beam hums under the caster's view while it lasts
		if o.Mine and not endedAt and now >= nextShake then
			nextShake = now + 0.24
			camera("BeamHold", nil, 1)
		end
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
