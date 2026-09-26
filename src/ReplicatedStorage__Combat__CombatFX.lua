--[[
	CombatFX  (ReplicatedStorage.Combat.CombatFX)
	Client-side, cosmetic only. Every client runs these for every hit it hears about (the attacker
	from its own impact frame), so they look the same for everyone and cost the server nothing.

	  Connect(info)              THE IMPACT. One call puts everything a landed blow shows and sounds
	                             like on the same frame: the tiered effect at the contact point, the
	                             blood, the layered sound, the victim's body giving with the blow and
	                             the camera kick (for the fighters it concerns). info = { Kind (attack
	                             id), At (contact), Dir (the way the blow drives), Victim, Attacker,
	                             Blocked, Break, Launched, Immune, Me = "Attacker" | "Victim" | nil,
	                             DirSign (+1 = the blow drove the head to the victim's right) }
	  Impact(pos, tier, dir)     the effect alone. Tiers: Light, Hook, Heavy, Sweep, Dash, Finisher,
	                             Block, HeavyBlock, Break (the user's VFX packs, CombatVFX)
	  Sound(name, pos, pitch)    a layered, positional one-shot (Config.Sounds) through the HUD's SFX
	                             volume group. Voices are pooled: nothing is created per hit
	  Footstep(pos, material)    a recorded step for that floor (Config.Footsteps)
	  HitGive / BlockGive        the body giving with a blow, layered on top of whatever clip plays: a
	                             spring per body (pivoting at the FEET through the RootJoint's C0, the
	                             head through the Neck's C0). A new blow ADDS to the give already there -
	                             a flurry reads as one body taking every blow, never a reset
	  Camera(hum, profile, dir)  a short directional impulse (Config.Camera): the view knocked along the
	                             blow, a touch of roll, a quick push-in, an optional low rumble - never
	                             a continuous shake. SetCameraBase keeps the shift-lock shoulder offset
	  LimbTrail(char, limb, t)   a short trail following a limb (the sweep's leg, the uppercut's fist)
	  Stomp(pos, attacker)       the Ground Smash (CombatShatter)
	  Dash(char, dir) / GroundDust(pos, scale) / GuardBreak(char, pos) / Damage(...)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))
local Blood = require(CombatFolder:WaitForChild("CombatBlood"))

local FX = {}

local SOUNDS = Config.Sounds or {}

---------------------------------------------------------------------------
-- holders, ground
---------------------------------------------------------------------------
local fxHolder: Part? = nil
local function holder(): Part
	if fxHolder and fxHolder.Parent then
		return fxHolder
	end
	local p = Instance.new("Part")
	p.Name = "CombatFX"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.2
	p.Position = Vector3.zero
	p.Parent = workspace
	fxHolder = p
	return p
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

local function effectFilter(): { Instance }
	local list: { Instance } = { holder() }
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	for _, name in ipairs({ "PracticeDummies", "CombatShatter", "CombatBlood", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

-- the ground under a point (solid ground a fighter stands on: see-through parts are skipped)
local function groundHit(pos: Vector3, up: number?, depth: number?): RaycastResult?
	groundParams.FilterDescendantsInstances = effectFilter()
	local origin = pos + Vector3.new(0, up or 2.5, 0)
	local dir = Vector3.new(0, -(depth or 8), 0)
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, dir, groundParams)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		if not (inst:IsA("BasePart") and (inst.Transparency >= 0.9 or not inst.CanCollide) and inst.Material ~= Enum.Material.Water) then
			return hit
		end
		local down = origin.Y - hit.Position.Y + 0.05
		origin = Vector3.new(origin.X, hit.Position.Y - 0.05, origin.Z)
		dir = Vector3.new(0, -math.max(0.1, -dir.Y - down), 0)
	end
	return nil
end
FX.GroundHit = groundHit

local function groundUnder(pos: Vector3): Vector3?
	local hit = groundHit(pos)
	return if hit then hit.Position else nil
end

---------------------------------------------------------------------------
-- impacts (the user's packs; see CombatVFX)
---------------------------------------------------------------------------
--[[ tier    what it looks like
	Light     a small, quick white flash and a few speed lines where the fist met the body
	Hook      the same, wider and thrown sideways
	Heavy     a big flash, the ring and lines burst, a puff off the body (the uppercut: thrown upward)
	Sweep     a low burst at the shins, dust kicked off the ground along the sweep
	Dash      a big flash and a puff blown out behind the body
	Finisher  the heaviest: flash, ring, dust off the ground under the body
	Block / HeavyBlock   sparks and embers off the guard, the ring
	Break     the guard shattering: the shock bubble, sparks, a flash ]]
function FX.Impact(pos: Vector3, tier: string?, dir: Vector3?)
	local k = tier or "Light"
	local d = if dir and dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local cf = VFX.Along(pos, d)
	if k == "Light" then
		VFX.Play("HitFlash", cf, { Scale = 0.42 })
		VFX.Play("Impact", cf, { Scale = 0.42, Count = 0.6 })
	elseif k == "Hook" then
		VFX.Play("HitFlash", cf, { Scale = 0.52 })
		VFX.Play("Impact", cf, { Scale = 0.55, Count = 0.8 })
	elseif k == "Heavy" then
		VFX.Play("HitFlashHeavy", cf, { Scale = 0.62 })
		VFX.Play("Impact", cf, { Scale = 0.85 })
		VFX.Play("DustPuff", VFX.Along(pos, d), { Scale = 0.45, Count = 0.4 })
	elseif k == "Sweep" then
		VFX.Play("HitFlash", cf, { Scale = 0.55 })
		VFX.Play("Impact", cf, { Scale = 0.7 })
		local g = groundUnder(pos)
		if g then
			VFX.Play("DustPuff", CFrame.new(g + Vector3.new(0, 0.6, 0)), { Scale = 0.55, Count = 0.6 })
			VFX.Play("GroundDust", VFX.Flat(g + Vector3.new(0, 0.4, 0)), { Scale = 0.5, Count = 0.6 })
		end
	elseif k == "Dash" then
		VFX.Play("HitFlashHeavy", cf, { Scale = 0.6 })
		VFX.Play("Impact", cf, { Scale = 0.8 })
		VFX.Play("DustPuff", VFX.Along(pos + d * 1.2, d), { Scale = 0.5, Count = 0.5 })
	elseif k == "Finisher" then
		VFX.Play("HitFlashHeavy", cf, { Scale = 0.8 })
		VFX.Play("Impact", cf, { Scale = 1.05 })
		local g = groundUnder(pos)
		if g then
			VFX.Play("GroundDust", VFX.Flat(g + Vector3.new(0, 0.4, 0)), { Scale = 0.7 })
		end
	elseif k == "Block" then
		VFX.Play("BlockSparks", cf, { Scale = 0.55, Count = 0.7 })
		VFX.Play("Block", cf, { Scale = 0.8 })
	elseif k == "HeavyBlock" then
		VFX.Play("BlockSparks", cf, { Scale = 0.8 })
		VFX.Play("Block", cf, { Scale = 1.2, Count = 1.3 })
	elseif k == "Break" then
		VFX.Play("HitFlashHeavy", cf, { Scale = 0.7 })
		VFX.Play("BlockSparks", cf, { Scale = 1.1, Count = 1.3 })
	end
end

-- the Ground Smash: the whole sequence lives in CombatShatter
local Shatter: any = nil
local function shatter(): any
	if Shatter == nil then
		local m = CombatFolder:FindFirstChild("CombatShatter")
		if m and m:IsA("ModuleScript") then
			local ok, mod = pcall(require, m)
			Shatter = if ok then mod else false
			if not ok then
				warn("[Combat] shatter:", mod)
			end
		else
			Shatter = false
		end
	end
	return Shatter
end

-- the touchdown (everything after it: fracture, debris, shockwave, dust, settle, fade)
function FX.Stomp(pos: Vector3, attacker: Model?)
	local s = shatter()
	if s then
		s.Play(pos, attacker)
	end
end

-- the Ground Smash's drop: wind pressing up past the body, speed lines, a faint trail - on the
-- falling fighter until it lands (returns { Stop = fn })
function FX.Descent(char: Model, height: number?): any
	local s = shatter()
	if s and s.Descent then
		return s.Descent(char, height)
	end
	return { Stop = function() end }
end

-- a ring of dust rolling out along the ground under `pos`
function FX.GroundDust(pos: Vector3, scale: number?)
	local g = groundUnder(pos)
	if g then
		VFX.Play("GroundDust", VFX.Flat(g + Vector3.new(0, 0.5, 0)), { Scale = scale or 1 })
	end
end

-- a dash's kick-off: dust puffs and speed streaks thrown back from the feet, a wind ring the body
-- bursts through. dir = "Forward" | "Backward" | "Left" | "Right" (relative to the body's facing)
function FX.Dash(char: Model, dir: string?, scale: number?)
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local cf = root.CFrame
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	local right = look:Cross(Vector3.yAxis)
	local d = if dir == "Backward" then -look elseif dir == "Right" then right elseif dir == "Left" then -right else look
	local g = groundUnder(root.Position) or (root.Position - Vector3.new(0, 3, 0))
	local p = g + Vector3.new(0, 0.7, 0)
	VFX.Play("Dash", CFrame.lookAt(p, p + d), { Scale = scale or 1 })
end

---------------------------------------------------------------------------
-- sounds: layered one-shots from pooled voices
---------------------------------------------------------------------------
-- A voice is an Attachment (moved to where the sound happens) holding a Sound and the layer's
-- effects, made once and reused round-robin: POOL voices per layer, so up to POOL of the same sound
-- can overlap (a flurry of hits) and a new one takes the oldest voice. Each play gets a serial, so a
-- voice re-used before its old envelope finished is never cut by that old envelope.
local POOL = 5
type Voice = { A: Attachment, S: Sound, Serial: number }
local pools: { [string]: { Voices: { Voice }, Next: number } } = {}

local function sfxGroup(): SoundGroup?
	local g = SoundService:FindFirstChild("SFX")
	return if g and g:IsA("SoundGroup") then g else nil
end

local function newVoice(layer: any): Voice
	local a = Instance.new("Attachment")
	a.Name = "CombatVoice"
	a.Parent = holder()
	local snd = Instance.new("Sound")
	snd.SoundId = layer.Id
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMinDistance = 6
	snd.RollOffMaxDistance = layer.Reach or 100
	snd.SoundGroup = sfxGroup()
	if layer.Eq then
		local eq = Instance.new("EqualizerSoundEffect")
		eq.LowGain = layer.Eq[1] or 0
		eq.MidGain = layer.Eq[2] or 0
		eq.HighGain = layer.Eq[3] or 0
		eq.Parent = snd
	end
	if layer.Drive and layer.Drive > 0 then
		local d = Instance.new("DistortionSoundEffect")
		d.Level = math.clamp(layer.Drive, 0, 1)
		d.Priority = 1 -- after the EQ
		d.Parent = snd
	end
	snd.Parent = a
	return { A = a, S = snd, Serial = 0 }
end

local function voice(key: string, layer: any): Voice
	local pool = pools[key]
	if not pool then
		pool = { Voices = {}, Next = 0 }
		pools[key] = pool
	end
	pool.Next = pool.Next % POOL + 1
	local v = pool.Voices[pool.Next]
	if not v or not v.A.Parent then
		v = newVoice(layer)
		pool.Voices[pool.Next] = v
	end
	if v.S.SoundId ~= layer.Id then
		v.S.SoundId = layer.Id
	end
	return v
end

local function playLayer(key: string, layer: any, pos: Vector3, pitch: number)
	local v = voice(key, layer)
	v.Serial += 1
	local serial = v.Serial
	local snd = v.S
	v.A.WorldPosition = pos
	local spread = layer.Var or 0.05
	snd.PlaybackSpeed = (layer.Speed or 1) * pitch * (1 + (math.random() * 2 - 1) * spread)
	snd.Volume = layer.Volume or 0.6
	snd.TimePosition = layer.Start or 0
	snd:Play()
	if layer.Len then
		task.delay(layer.Len, function()
			if v.Serial ~= serial then
				return
			end
			local fade = layer.Fade or 0.06
			local tw = TweenService:Create(snd, TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Volume = 0 })
			tw:Play()
			task.delay(fade, function()
				if v.Serial == serial then
					snd:Stop()
				end
			end)
		end)
	end
end

-- pos: where it happens (nil = at the camera). pitch: an extra pitch factor on every layer
function FX.Sound(name: string, pos: Vector3?, pitch: number?)
	local def = SOUNDS[name]
	if not def then
		return
	end
	local at = pos
	if not at then
		local cam = workspace.CurrentCamera
		at = if cam then cam.CFrame.Position else Vector3.zero
	end
	local p = pitch or 1
	for i, layer in ipairs(def) do
		local key = name .. "#" .. i
		if layer.Delay and layer.Delay > 0 then
			task.delay(layer.Delay, playLayer, key, layer, at :: Vector3, p)
		else
			playLayer(key, layer, at :: Vector3, p)
		end
	end
end
Blood.SoundHook = function(name: string, pos: Vector3)
	FX.Sound(name, pos, 1)
end

-- a footfall on whatever the feet are on (terrain or part material)
function FX.Footstep(pos: Vector3, material: Enum.Material?, volume: number?)
	local mat = material
	if not mat then
		local hit = groundHit(pos, 1, 5)
		mat = if hit then hit.Material else nil
	end
	local id = (mat and Config.Footsteps[mat.Name]) or Config.Footsteps.Default
	playLayer("Foot#" .. id, { Id = id, Volume = volume or 0.45, Speed = 1, Var = 0.08, Len = 0.3, Fade = 0.1, Reach = 60 }, pos, 1)
end

---------------------------------------------------------------------------
-- the body giving with a blow: a spring per body (joint C0 offsets, pivoting at the feet)
---------------------------------------------------------------------------
local rest: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local FEET = Vector3.new(0, -3, 0) -- the floor under a standing R6 root, in root space
local AXES = { "Pitch", "Yaw", "Roll", "NeckPitch", "NeckYaw" }

type Reel = { X: { [string]: number }, V: { [string]: number }, Omega: number, Conn: RBXScriptConnection?, Root: Motor6D?, Neck: Motor6D?, Slow: number, SlowUntil: number }
local reels: { [Model]: Reel } = setmetatable({}, { __mode = "k" }) :: any

local function restC0(m: Motor6D): CFrame
	local r = rest[m]
	if not r then
		r = m.C0
		rest[m] = r
	end
	return r
end

local function joints(char: Model): (Motor6D?, Motor6D?)
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	local rj = root and root:FindFirstChild("RootJoint")
	local neck = torso and torso:FindFirstChild("Neck")
	return (if rj and rj:IsA("Motor6D") then rj else nil), (if neck and neck:IsA("Motor6D") then neck else nil)
end

local function reelStep(char: Model, r: Reel, dt: number)
	local w = r.Omega
	-- the hit-stop holds the body on its impact pose too: the spring runs slow until it ends
	local k = if os.clock() < r.SlowUntil then r.Slow else 1
	local h = math.min(dt, 1 / 30) * k
	local energy = 0
	for _, ax in ipairs(AXES) do
		local x, v = r.X[ax], r.V[ax]
		-- critically damped: x'' = -2 w x' - w^2 x (semi-implicit, stable at any frame rate)
		v += (-2 * w * v - w * w * x) * h
		x += v * h
		r.X[ax], r.V[ax] = x, v
		energy += math.abs(x) + math.abs(v) * 0.02
	end
	local rj, neck = r.Root, r.Neck
	local X = r.X
	if rj and rj.Parent and rj.Enabled then
		local rr = restC0(rj)
		rj.C0 = CFrame.new(FEET) * CFrame.Angles(math.rad(X.Pitch), math.rad(X.Yaw), math.rad(X.Roll)) * CFrame.new(-FEET) * rr
	end
	if neck and neck.Parent and neck.Enabled then
		local nr = restC0(neck)
		neck.C0 = CFrame.new(nr.Position) * CFrame.Angles(math.rad(X.NeckPitch), math.rad(X.NeckYaw), 0) * (nr - nr.Position)
	end
	if energy < 0.02 or not char.Parent then
		if rj and rest[rj] and rj.Parent then
			rj.C0 = rest[rj]
		end
		if neck and rest[neck] and neck.Parent then
			neck.C0 = rest[neck]
		end
		if r.Conn then
			r.Conn:Disconnect()
			r.Conn = nil
		end
		reels[char] = nil
	end
end

--[[ kick the body's spring: peak = { Pitch, Yaw, Roll, NeckPitch, NeckYaw } in degrees (the
	displacement a single blow reaches from rest), omega = spring speed (rad/s), hold = the impact's
	hit-stop (the spring creeps through it). A new kick adds to the motion already there. ]]
function FX.Give(char: Model, peak: any, omega: number?, hold: number?)
	local rj, neck = joints(char)
	if not (rj or neck) then
		return
	end
	local r = reels[char]
	if not r then
		r = { X = {}, V = {}, Omega = omega or 15, Conn = nil, Root = rj, Neck = neck, Slow = 0.15, SlowUntil = 0 }
		for _, ax in ipairs(AXES) do
			r.X[ax], r.V[ax] = 0, 0
		end
		reels[char] = r
	end
	r.Root, r.Neck = rj, neck
	-- heavier blows move slower and further; a mix of blows settles at the slower one's pace
	r.Omega = math.min(r.Omega, omega or 15) * 0.5 + (omega or 15) * 0.5
	-- critically damped from rest, x(t) = v0 t e^(-w t): peaks at v0 / (w e)
	local w = r.Omega
	for _, ax in ipairs(AXES) do
		local p = peak[ax] or 0
		if p ~= 0 then
			r.V[ax] += p * w * math.exp(1)
		end
	end
	r.SlowUntil = os.clock() + (hold or 0)
	if not r.Conn then
		r.Conn = RunService.RenderStepped:Connect(function(dt)
			local cur = reels[char]
			if cur then
				reelStep(char, cur, dt)
			end
		end)
	end
end

-- a clean hit: dir = +1 when the blow drove the victim's head to its right (HitRight)
function FX.HitGive(char: Model, def: any, dir: number, hold: number?)
	local reel = def and def.Reel
	if not reel then
		return
	end
	FX.Give(char, {
		Pitch = reel.Pitch or 0,
		Yaw = -dir * math.abs(reel.Yaw or 0),
		Roll = -dir * math.abs(reel.Roll or 0),
		NeckYaw = -dir * math.abs(reel.NeckYaw or 0),
		NeckPitch = reel.NeckPitch or 0,
	}, reel.Omega, hold)
end

-- a blocked hit: the guard gives toward the driven side and rocks back
function FX.BlockGive(char: Model, class: any, dir: number, heavy: boolean?, hold: number?)
	local tilt = class and class.BlockTilt
	if not tilt then
		return
	end
	FX.Give(char, {
		Pitch = tilt.Pitch or 0,
		Roll = -dir * (tilt.Roll or 0),
		Yaw = -dir * (tilt.Yaw or 0),
		NeckYaw = -dir * (tilt.Yaw or 0) * 0.5,
		NeckPitch = (tilt.Pitch or 0) * 0.5,
	}, if heavy then 12 else 15, hold)
end

---------------------------------------------------------------------------
-- limb trails (the sweep's leg arc, the uppercut's rising fist)
---------------------------------------------------------------------------
function FX.LimbTrail(char: Model, limbName: string, duration: number, style: string?)
	local limb = char:FindFirstChild(limbName)
	if not (limb and limb:IsA("BasePart")) then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "CombatTrail0"
	a0.Position = Vector3.new(0, -0.35, 0)
	local a1 = Instance.new("Attachment")
	a1.Name = "CombatTrail1"
	a1.Position = Vector3.new(0, -1.05, 0)
	a0.Parent = limb
	a1.Parent = limb
	local t = Instance.new("Trail")
	t.Attachment0 = a0
	t.Attachment1 = a1
	t.FaceCamera = true
	t.Lifetime = if style == "Low" then 0.22 else 0.16
	t.MinLength = 0.05
	t.WidthScale = NumberSequence.new(1, 0.2)
	t.LightEmission = 0.35
	t.LightInfluence = 0.6
	t.Color = if style == "Low" then ColorSequence.new(Color3.fromRGB(214, 206, 188)) else ColorSequence.new(Color3.fromRGB(235, 235, 240))
	t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	t.Parent = limb
	task.delay(duration, function()
		t.Enabled = false
		task.delay(t.Lifetime + 0.05, function()
			t:Destroy()
			a0:Destroy()
			a1:Destroy()
		end)
	end)
end

---------------------------------------------------------------------------
-- guard break: the white hit flash + the call-out  /  damage stamps
---------------------------------------------------------------------------
local Callout: any = nil
task.spawn(function()
	pcall(function()
		Callout = require(CombatFolder:WaitForChild("CombatCallout", 10))
	end)
end)

function FX.GuardBreak(char: Model, at: Vector3, attacker: Model?)
	-- centred on the broken fighter's chest, nudged toward the blow (not on the attacker's fist)
	local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
	if torso and torso:IsA("BasePart") then
		at = torso.Position:Lerp(at, 0.35)
	end
	VFX.Play("GuardBreak", CFrame.new(at))
	if Callout then
		Callout.GuardBreak(char, attacker)
	end
end

function FX.Damage(victim: Model, amount: number, kind: string, attacker: Model?)
	if not Callout then
		pcall(function()
			Callout = require(CombatFolder:WaitForChild("CombatCallout", 10))
		end)
	end
	if Callout and Callout.Damage then
		Callout.Damage(victim, amount, kind, attacker)
	end
end

---------------------------------------------------------------------------
-- camera: directional impulses (local player only)
---------------------------------------------------------------------------
-- Every impulse is a kick that peaks fast and settles (x(t) = (t/tp) e^(1 - t/tp)), applied AFTER
-- the camera scripts each frame: the view is moved along the blow, rolled a touch into it and pushed
-- in along its own look - none of which changes where the camera looks, so the player's aim never
-- drifts. A rumble is a faint low-frequency tremor. Nothing runs while no impulse is live.
type Impulse = { Dir: Vector3, Kick: number, Up: number, Roll: number, Push: number, T0: number, Time: number, Rumble: number, RumbleTime: number, Seed: number }
local impulses: { Impulse } = {}
local camBound = false

-- shift lock's over-the-shoulder offset (the impulses never touch it: they move the view itself)
function FX.SetCameraBase(hum: Humanoid?, offset: Vector3)
	if hum then
		hum.CameraOffset = offset
	end
end

local function kickCurve(t: number, tp: number): number
	if t <= 0 then
		return 0
	end
	local x = t / tp
	return x * math.exp(1 - x)
end

local function cameraStep()
	local cam = workspace.CurrentCamera
	local now = os.clock()
	if #impulses == 0 then
		if camBound then
			camBound = false
			RunService:UnbindFromRenderStep("OverkillCombatCamera")
		end
		return
	end
	if not cam or cam.CameraType == Enum.CameraType.Scriptable then
		table.clear(impulses)
		return
	end
	local move, roll, push = Vector3.zero, 0, 0
	for i = #impulses, 1, -1 do
		local im = impulses[i]
		local t = now - im.T0
		local total = math.max(im.Time, im.RumbleTime)
		if t >= total then
			table.remove(impulses, i)
		else
			local tp = im.Time * 0.22
			-- the kick settles to nothing by its Time (a smooth fade over the tail)
			local fade = math.clamp(1 - (t - im.Time * 0.6) / (im.Time * 0.4), 0, 1)
			local k = if t < im.Time then kickCurve(t, tp) * fade else 0
			move += (im.Dir * im.Kick + Vector3.new(0, im.Up * im.Kick, 0)) * k
			roll += im.Roll * k
			push += im.Push * k
			if im.Rumble > 0 and t < im.RumbleTime then
				local a = im.Rumble * (1 - t / im.RumbleTime)
				local s = im.Seed
				move += Vector3.new(math.noise(t * 11, s, 0), math.noise(0, t * 11, s), math.noise(s, 0, t * 11)) * a * 2
			end
		end
	end
	cam.CFrame = CFrame.new(move) * cam.CFrame * CFrame.Angles(0, 0, math.rad(roll)) * CFrame.new(0, 0, -push)
end

--[[ profile = a Config.Camera entry name; dir = the way the blow travels (world). The kick knocks
	the view along it (seen from the attacker: forward with the punch; from the victim: back with
	the hit); Fov becomes a short push-in along the view ]]
function FX.Camera(_hum: Humanoid?, profile: string, dir: Vector3?, scale: number?)
	local p = Config.Camera[profile]
	if not p then
		return
	end
	local s = scale or 1
	local d = if dir and dir.Magnitude > 1e-3 then Vector3.new(dir.X, 0, dir.Z) else Vector3.zero
	d = if d.Magnitude > 1e-3 then d.Unit else Vector3.zero
	local rumble = p.Rumble
	table.insert(impulses, {
		Dir = d,
		Kick = p.Kick * s,
		Up = p.Up or 0,
		Roll = (p.Roll or 0) * s * (if math.random() < 0.5 then -1 else 1),
		Push = (p.Fov or 0) * 0.12 * s,
		T0 = os.clock(),
		Time = p.Time or 0.16,
		Rumble = if rumble then rumble[1] * s else 0,
		RumbleTime = if rumble then rumble[2] else 0,
		Seed = math.random() * 100,
	})
	if #impulses > 6 then
		table.remove(impulses, 1)
	end
	if not camBound then
		camBound = true
		RunService:BindToRenderStep("OverkillCombatCamera", Enum.RenderPriority.Camera.Value + 2, cameraStep)
	end
end

-- (the old name: a short kick straight at the view)
function FX.Shake(hum: Humanoid, power: number, duration: number?)
	FX.Camera(hum, if power >= 0.4 then "Heavy" else "Light", nil, math.clamp(power / 0.3, 0.3, 2))
end

---------------------------------------------------------------------------
-- THE IMPACT: every part of a landed blow on one frame
---------------------------------------------------------------------------
local IMPACT_SOUND = { Swing1 = "Hit", Swing2 = "Hit", Swing3 = "Hook", Uppercut = "Uppercut", Sweep = "Sweep", DashAttack = "DashHit", Downslam = "HeavyHit" }

-- where on the victim the effect goes: the contact point mapped onto the body as THIS screen shows
-- it (its height and side on the body, just in front of the surface the blow met), so the burst
-- always sits on the fighter it came from
local function onBody(victim: Model?, at: Vector3, drive: Vector3, guarded: boolean): Vector3
	local vr = victim and victim:FindFirstChild("HumanoidRootPart")
	if not (vr and vr:IsA("BasePart")) then
		return at
	end
	local away = Vector3.new(drive.X, 0, drive.Z)
	away = if away.Magnitude > 1e-3 then away.Unit else Vector3.new(0, 0, -1)
	local right = away:Cross(Vector3.yAxis)
	right = if right.Magnitude > 1e-3 then right.Unit else Vector3.xAxis
	local rel = at - vr.Position
	local height = math.clamp(rel.Y, -2.7, 1.9)
	local side = math.clamp(rel:Dot(right), -1.0, 1.0)
	local front = if guarded then 1.25 else 0.8 -- blocked: on the guard, in front of the arms
	return vr.Position - away * front + right * side + Vector3.new(0, height, 0)
end

function FX.Connect(info: any)
	local def = Config.Attacks[info.Kind]
	if not def then
		return
	end
	local class = def.ClassDef
	local heavy = def.Rank >= 3
	local drive = if info.Dir and info.Dir.Magnitude > 1e-3 then info.Dir.Unit else Vector3.new(0, 0, -1)
	local guarded = info.Blocked or info.Break
	local at = onBody(info.Victim, info.At, drive, guarded == true)
	local rise = if def.Id == "Uppercut" then 1.1 elseif def.Id == "Sweep" then 0.12 elseif def.Id == "Downslam" then 0.7 else 0.3
	local side = Vector3.zero
	local vr = info.Victim and info.Victim:FindFirstChild("HumanoidRootPart")
	if vr and vr:IsA("BasePart") and def.ReactPush and def.ReactPush ~= 0 then
		side = Vector3.new(vr.CFrame.RightVector.X, 0, vr.CFrame.RightVector.Z) * (info.DirSign or 0) * 0.45
	end
	local throw = (drive + Vector3.new(0, rise, 0) + side).Unit
	local hs = if info.Break then Config.Guard.BreakHitstop elseif info.Blocked then class.BlockHitstop else class.Hitstop
	-- the effect
	if info.Break then
		FX.Impact(at, "Break", throw)
		FX.Sound("GuardBreak", at, 1)
		if info.Victim then
			FX.GuardBreak(info.Victim, at, info.Attacker)
		end
	elseif info.Blocked then
		FX.Impact(at, if heavy then "HeavyBlock" else "Block", throw)
		FX.Sound(if heavy then "HeavyBlock" else "Block", at, 1)
	else
		local tier = if info.Launched and def.Id ~= "Sweep" then "Finisher" else def.Impact or "Light"
		FX.Impact(at, tier, throw)
		FX.Sound(IMPACT_SOUND[def.Id] or (if heavy then "HeavyHit" else "Hit"), at, if info.Immune then 0.97 else 1)
		Blood.Spray(at, throw, def.Blood or "Light", info.Victim)
		if info.Launched then
			local p = at
			task.delay(hs + 0.35, function()
				FX.Sound("Knockdown", p, 1)
			end)
			if info.Victim then
				FX.GroundDust(at, 0.75)
				Blood.Pool(info.Victim)
			end
		end
	end
	-- the body giving with it (the launch gives the ragdoll instead)
	if info.Victim then
		if info.Blocked then
			FX.BlockGive(info.Victim, class, info.DirSign or 1, heavy, hs)
		elseif not info.Launched and not info.Break then
			FX.HitGive(info.Victim, def, info.DirSign or 1, hs)
		end
	end
	-- the camera, for the two fighters it concerns
	if info.Me == "Attacker" then
		local prof = if info.Break then "GuardBreak" elseif info.Blocked then "Block" elseif def.Id == "Swing3" then "Hook" else class.Camera
		FX.Camera(nil, prof, drive, if info.Blocked then 0.7 else 1)
	elseif info.Me == "Victim" then
		local prof = if info.Break then "GuardBreak" elseif info.Blocked then "Block" else class.VictimCamera
		FX.Camera(nil, prof, drive, if info.Immune then 0.6 else 1)
	end
end

return FX
