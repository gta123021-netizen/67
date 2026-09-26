--[[
	CombatFX  (ReplicatedStorage.Combat.CombatFX)
	Client-side, cosmetic only. Every client runs these for every hit it hears about, so they look
	the same for everyone and cost the server nothing. Every particle effect is one of the user's
	own VFX packs (ReplicatedStorage.Combat.VFX, played through CombatVFX):
	  Impact(pos, kind, dir)     the effect for a landed blow at the contact point, thrown the way
	                             the blow drove (dir). kind = Hit | Heavy | Finisher | Block |
	                             HeavyBlock | Ground
	  Sound(name, pos, pitch)    a layered, positional one-shot (Config.Sounds: each layer pitched,
	                             enveloped and EQ'd, a random variant each time) through the HUD's
	                             SFX volume group. Voices are pooled: nothing is created per hit
	  Give(char, angles, time)   the body giving with a blow, layered on top of whatever clip plays:
	                             the whole body pivots at the FEET (so the stance stays planted) through
	                             the RootJoint's C0, the head turns through the Neck's C0. Always
	                             returns exactly to the rest C0.
	  HitGive(char, def, dir)    Give for a clean hit (dir +1 = the blow drove the head to the
	                             victim's right)
	  BlockGive(char, class, dir)  Give for a blocked hit: the guard tilts toward the driven side,
	                             that shoulder turns back and the guard rocks back
	  GuardBreak(char, pos)      the shock-bubble flash on the body + the GUARD BREAK call-out
	  Dash(char, dir)            the burst a dash kicks off with (anime dust puffs, a wind ring and
	                             speed streaks), at the feet, thrown back against the dash
	  GroundDust(pos, scale)     a ring of dust rolling out along the ground (stomps, launches)
	  Shake(humanoid, power)     short camera shake through Humanoid.CameraOffset (on top of the
	                             shift-lock shoulder offset, SetCameraBase)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))

local FX = {}

local SOUNDS = Config.Sounds or {}

---------------------------------------------------------------------------
-- impacts (the user's packs; see CombatVFX)
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

-- where the ground is under a point (the shatter stands on it, not in the air or under the floor)
local function groundUnder(pos: Vector3): Vector3?
	local list: { Instance } = { holder() }
	for _, pl in ipairs(game:GetService("Players"):GetPlayers()) do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		table.insert(list, dummies)
	end
	groundParams.FilterDescendantsInstances = list
	local hit = workspace:Raycast(pos + Vector3.new(0, 2.5, 0), Vector3.new(0, -8, 0), groundParams)
	return if hit then hit.Position else nil
end

--[[ kind:  Hit        clean light hit       - blood
			Heavy      clean heavy hit        - the heavy blood burst + the ring impact
			Finisher   the combo's last blow  - the same, bigger
			Block      blocked light hit      - the ring spark on the guard
			HeavyBlock blocked heavy hit      - the same, bigger
			Ground     stomp touchdown        - the shattered ground (see FX.Stomp)
	dir: the way the blow drove (droplets fly that way) ]]
function FX.Impact(pos: Vector3, kind: string?, dir: Vector3?)
	local k = kind or "Hit"
	local d = dir or Vector3.yAxis
	if k == "Hit" then
		VFX.Play("Blood", VFX.Along(pos, d))
	elseif k == "Heavy" then
		VFX.Play("BloodHeavy", VFX.Along(pos, d))
		VFX.Play("Impact", VFX.Along(pos, d), { Scale = 0.9 })
	elseif k == "Finisher" then
		VFX.Play("BloodHeavy", VFX.Along(pos, d), { Scale = 1.15, Count = 1.25 })
		VFX.Play("Impact", VFX.Along(pos, d), { Scale = 1.1 })
	elseif k == "Block" then
		VFX.Play("Block", VFX.Along(pos, d))
	elseif k == "HeavyBlock" then
		VFX.Play("Block", VFX.Along(pos, d), { Scale = 1.3, Count = 1.4 })
	elseif k == "Ground" then
		FX.Stomp(pos, nil)
	end
end

-- the stomp's touchdown: the ground shatters under the foot (two rings of rock spikes whose rim is
-- the stomp's hit radius - CombatShatter) and the shock rolls out across it as a ring of dust
local Shatter: any = nil
function FX.Stomp(pos: Vector3, attacker: Model?)
	local g = groundUnder(pos)
	if not g then
		return
	end
	if not Shatter then
		local m = CombatFolder:FindFirstChild("CombatShatter")
		if m and m:IsA("ModuleScript") then
			local ok, mod = pcall(require, m)
			Shatter = if ok then mod else false
		end
	end
	if Shatter then
		Shatter.Play(g, attacker)
	end
	VFX.Play("GroundDust", VFX.Flat(g + Vector3.new(0, 0.5, 0)))
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

---------------------------------------------------------------------------
-- the body giving with a blow (joint C0 offsets, pivoting at the feet)
---------------------------------------------------------------------------
local rest: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local giving: { [Model]: { Serial: number } } = setmetatable({}, { __mode = "k" }) :: any
local FEET = Vector3.new(0, -3, 0) -- the floor under a standing R6 root, in root space

local function restC0(m: Motor6D): CFrame
	local r = rest[m]
	if not r then
		r = m.C0
		rest[m] = r
	end
	return r
end

--[[ angles (degrees, signed): Pitch (+ = lean back), Roll (+ = lean to the body's left),
	Yaw (+ = turn to the body's left), NeckYaw (+ = head turns left), NeckPitch (+ = head back).
	rise = seconds to full give, total = seconds until back at rest ]]
function FX.Give(char: Model, ang: any, rise: number?, total: number?)
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not (root and torso) then
		return
	end
	local rootJoint = root:FindFirstChild("RootJoint")
	local neck = torso:FindFirstChild("Neck")
	if not (rootJoint and rootJoint:IsA("Motor6D")) then
		rootJoint = nil
	end
	if not (neck and neck:IsA("Motor6D")) then
		neck = nil
	end
	local st = giving[char]
	if not st then
		st = { Serial = 0 }
		giving[char] = st
	end
	st.Serial += 1
	local serial = st.Serial
	local rootRest = rootJoint and restC0(rootJoint)
	local neckRest = neck and restC0(neck)
	local pitch = math.rad(ang.Pitch or 0)
	local roll = math.rad(ang.Roll or 0)
	local yaw = math.rad(ang.Yaw or 0)
	local nyaw = math.rad(ang.NeckYaw or 0)
	local npitch = math.rad(ang.NeckPitch or 0)
	local RISE, TOTAL = rise or 0.05, total or 0.36
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		local done = st.Serial ~= serial or t >= TOTAL or not char.Parent
		local k: number
		if t < RISE then
			k = math.sin(t / RISE * math.pi * 0.5) -- quick, eased snap into the give
		else
			k = (1 - (t - RISE) / (TOTAL - RISE)) ^ 2 -- settle back
		end
		if done then
			k = 0
		end
		if rootJoint and rootRest and rootJoint.Enabled and st.Serial == serial then
			local r = CFrame.Angles(pitch * k, yaw * k, roll * k)
			rootJoint.C0 = CFrame.new(FEET) * r * CFrame.new(-FEET) * rootRest
		end
		if neck and neckRest and neck.Enabled and st.Serial == serial then
			neck.C0 = CFrame.new(neckRest.Position) * CFrame.Angles(npitch * k, nyaw * k, 0) * (neckRest - neckRest.Position)
		end
		if done then
			if st.Serial == serial then
				if rootJoint and rootRest then
					rootJoint.C0 = rootRest
				end
				if neck and neckRest then
					neck.C0 = neckRest
				end
			end
			if conn then
				conn:Disconnect()
			end
		end
	end)
end

-- a clean hit: dir = +1 when the blow drove the victim's head to its right (HitRight)
function FX.HitGive(char: Model, def: any, dir: number, heavy: boolean?)
	local tilt = def and def.Tilt
	if not tilt then
		return
	end
	FX.Give(char, {
		Pitch = tilt.Pitch or 0,
		Roll = -dir * math.abs(tilt.Roll or 0),
		Yaw = 0,
		NeckYaw = -dir * math.abs(tilt.NeckYaw or 0),
		NeckPitch = tilt.NeckPitch or 0,
	}, if heavy then 0.06 else 0.05, if heavy then 0.46 else 0.34)
end

-- a blocked hit: the guard gives toward the driven side and rocks back
function FX.BlockGive(char: Model, class: any, dir: number, heavy: boolean?)
	local tilt = class and class.BlockTilt
	if not tilt then
		return
	end
	local total = Config.Guard.LeanTime * (if heavy then 1.25 else 1)
	FX.Give(char, {
		Pitch = tilt.Pitch or 0,
		Roll = -dir * (tilt.Roll or 0),
		Yaw = -dir * (tilt.Yaw or 0),
		NeckYaw = -dir * (tilt.Yaw or 0) * 0.5,
		NeckPitch = (tilt.Pitch or 0) * 0.5,
	}, if heavy then 0.055 else 0.045, total)
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
	-- the white hit flash (the pack's Hit-02: ring, white-hot core, two swipes), big, where the guard
	-- shattered; the fighter is thrown out of it
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
-- camera shake (local player only)
---------------------------------------------------------------------------
local shakeSerial = 0
local cameraBase = Vector3.zero -- shift lock's over-the-shoulder offset; the shake rides on top
local shaking = false
function FX.SetCameraBase(hum: Humanoid?, offset: Vector3)
	cameraBase = offset
	if hum and not shaking then
		hum.CameraOffset = offset
	end
end

function FX.Shake(hum: Humanoid, power: number, duration: number?)
	shakeSerial += 1
	local serial = shakeSerial
	local dur = duration or 0.14
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if serial ~= shakeSerial or t >= dur or not hum.Parent then
			if serial == shakeSerial then
				shaking = false
				if hum.Parent then
					hum.CameraOffset = cameraBase
				end
			end
			if conn then
				conn:Disconnect()
			end
			return
		end
		shaking = true
		local k = (1 - t / dur) * power
		hum.CameraOffset = cameraBase + Vector3.new((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
	end)
end

return FX
