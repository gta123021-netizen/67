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
	                             DirSign (+1 = the blow drove the head to the victim's right), Dmg (the
	                             damage), Hp (the share of health it left: the blood's size) }
	  Impact(pos, tier, dir)     the effect alone. Tiers: Light, Hook, Heavy, Sweep, Dash, Finisher,
	                             Block, HeavyBlock, Break (the user's VFX packs, CombatVFX)
	  (the combat makes no sound: effects, reactions and the camera carry every blow)
	  HitGive / BlockGive        the body giving with a blow, layered on top of whatever clip plays: a
	                             spring per body (pivoting at the FEET through the RootJoint's C0, the
	                             head through the Neck's C0). A new blow ADDS to the give already there -
	                             a flurry reads as one body taking every blow, never a reset
	  Camera(hum, profile, dir)  a short directional impulse (Config.Camera): the view knocked along the
	                             blow, a touch of roll, a quick push-in, an optional low rumble - never
	                             a continuous shake. SetCameraBase keeps the shift-lock shoulder offset
	  Stomp(pos, attacker)       the Ground Smash (CombatShatter)
	  Dash(char, dir) / GroundDust(pos, scale) / GuardBreak(char, pos) / Damage(...)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))
local Blood = require(CombatFolder:WaitForChild("CombatBlood"))
local Paths = require(CombatFolder:WaitForChild("CombatPaths"))
local Motion = require(CombatFolder:WaitForChild("Motion"))

local FX = {}


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

-- (rebuilt at most every quarter second: a flurry of hits never re-lists the world per effect)
local filterList: { Instance } = {}
local filterAt = -math.huge
local function effectFilter(): { Instance }
	local t = os.clock()
	if t - filterAt < 0.25 and #filterList > 0 and filterList[1].Parent then
		return filterList
	end
	filterAt = t
	local list: { Instance } = { holder() }
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	for _, name in ipairs({ "PracticeDummies", "CombatShatter", "CombatBlood", "CombatGore", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	filterList = list
	groundParams.FilterDescendantsInstances = list
	return list
end

-- the ground under a point (solid ground a fighter stands on: see-through parts are skipped)
local function groundHit(pos: Vector3, up: number?, depth: number?): RaycastResult?
	effectFilter() -- (sets groundParams' filter when it is rebuilt)
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
	-- (a "Stomp": the smash is its crack and its dust on the floor - no flash on the bodies it catches)
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
-- the body giving with a blow: a spring per body (joint C0 offsets, pivoting at the feet)
---------------------------------------------------------------------------
local rest: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local FEET = Vector3.new(0, -3, 0) -- the floor under a standing R6 root, in root space
local AXES = { "Pitch", "Yaw", "Roll", "NeckPitch", "NeckYaw" }

--[[ THE SLIDE, SHOWN AT ONCE. Other fighters' bodies reach this screen through replication, a quarter
	second or more behind (a slide starts late, then sprints to catch up). A blow's push is known the
	moment it lands, so the body is drawn where its slide has it: where it was drawn at the blow, plus
	the push so far - the root joint carries the gap to where replication has it (the lead), so the
	lead is gone once replication catches up. Released gently if replication never gets there (a wall,
	a push cut short). The slide brakes into a body in its lane exactly as the push itself does
	(Motion.Push: the same gap, the same braking), so it ends where replication will bring the body.
	The same drawn place is where this screen's strikes look for it (FX.Seen) ]]
type Lead = { Dir: Vector3, Dist: number, T0: number, Dur: number, From: Vector3, Max: number, Cur: number, Curve: number, At: number }
type Reel = { X: { [string]: number }, V: { [string]: number }, Omega: number, Conn: RBXScriptConnection?, Root: Motor6D?, Neck: Motor6D?, Slow: number, SlowUntil: number, Lead: Lead?, Body: BasePart? }
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

-- every other standing fighter's body, where this screen draws it (a slide brakes into them)
local seenBodies: { Vector3 } = {}
local function bodiesBut(char: Model): { Vector3 }
	table.clear(seenBodies)
	local function add(c: Instance?)
		local root = c and c ~= char and c:FindFirstChild("HumanoidRootPart")
		local hum = root and (c :: Instance):FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and hum and hum.Health > 0 then
			table.insert(seenBodies, FX.Seen(root))
		end
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		add(pl.Character)
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		for _, c in ipairs(dummies:GetChildren()) do
			add(c)
		end
	end
	return seenBodies
end

-- the slide run on to `t` (once a frame): along its curve (Motion.PushCurve, integrated), braking
-- into a body in its lane - the distance a brake takes off is gone, as on the pushed body itself
local function advance(char: Model, l: Lead, t: number)
	local dt = t - l.At
	l.At = t
	local u = math.clamp((t - l.T0) / l.Dur, 0, 1)
	local curve = l.Dist * (1 - (1 - u) ^ 2.5)
	local step = curve - l.Curve
	l.Curve = curve
	if step <= 0 then
		return
	end
	local near = Motion.Ahead(l.From + l.Dir * l.Cur, l.Dir, bodiesBut(char), Motion.BODY_WIDTH)
	if near then
		local room = near - Motion.BODY_GAP
		step = math.max(0, math.min(step, Motion.BrakeCap(room) * dt, room))
	end
	l.Cur += step
end

-- the lead now (world, flat): where the slide has the body less where replication has it
local LEAD_HOLD = 0.35 -- seconds past the push's end it is kept whole (replication still arriving)
local function leadNow(r: Reel, t: number): Vector3
	local l, body = r.Lead, r.Body
	if not (l and body and body.Parent) then
		return Vector3.zero
	end
	local want = l.From + l.Dir * l.Cur
	local gap = want - body.Position
	gap = Vector3.new(gap.X, 0, gap.Z)
	if gap.Magnitude > l.Max then
		gap = gap.Unit * l.Max
	end
	local late = t - (l.T0 + l.Dur) - LEAD_HOLD
	if late > 0 then
		gap *= math.exp(-late * 6)
		if late > 0.8 or gap.Magnitude < 0.02 then
			r.Lead = nil
		end
	end
	return gap
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
	local now = os.clock()
	if r.Lead then
		advance(char, r.Lead, now)
	end
	local lead = leadNow(r, now)
	if rj and rj.Parent and rj.Enabled then
		local rr = restC0(rj)
		local off = if r.Body then r.Body.CFrame:VectorToObjectSpace(lead) else Vector3.zero
		rj.C0 = CFrame.new(off) * CFrame.new(FEET) * CFrame.Angles(math.rad(X.Pitch), math.rad(X.Yaw), math.rad(X.Roll)) * CFrame.new(-FEET) * rr
	end
	if neck and neck.Parent and neck.Enabled then
		local nr = restC0(neck)
		neck.C0 = CFrame.new(nr.Position) * CFrame.Angles(math.rad(X.NeckPitch), math.rad(X.NeckYaw), 0) * (nr - nr.Position)
	end
	if (energy < 0.02 and not r.Lead) or not char.Parent then
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
-- the body's spring (and lead), stepped every frame while it moves
local function reelFor(char: Model): Reel?
	local rj, neck = joints(char)
	if not (rj or neck) then
		return nil
	end
	local r = reels[char]
	if not r then
		r = { X = {}, V = {}, Omega = 0, Conn = nil, Root = rj, Neck = neck, Slow = 0.15, SlowUntil = 0 }
		for _, ax in ipairs(AXES) do
			r.X[ax], r.V[ax] = 0, 0
		end
		reels[char] = r
	end
	r.Root, r.Neck = rj, neck
	if not r.Conn then
		r.Conn = RunService.RenderStepped:Connect(function(dt)
			local cur = reels[char]
			if cur then
				reelStep(char, cur, dt)
			end
		end)
	end
	return r
end

function FX.Give(char: Model, peak: any, omega: number?, hold: number?)
	local r = reelFor(char)
	if not r then
		return
	end
	-- heavier blows move slower and further; a mix of blows settles at the slower one's pace
	local o = omega or 15
	r.Omega = if r.Omega > 0 then math.min(r.Omega, o) * 0.5 + o * 0.5 else o
	-- critically damped from rest, x(t) = v0 t e^(-w t): peaks at v0 / (w e)
	local w = r.Omega
	for _, ax in ipairs(AXES) do
		local p = peak[ax] or 0
		if p ~= 0 then
			r.V[ax] += p * w * math.exp(1)
		end
	end
	r.SlowUntil = os.clock() + (hold or 0)
end

-- a push on a body this screen sees through replication: `dist` studs along `dir` over `dur` seconds
-- (Motion.Push's curve), starting after `delay` (the hit-stop)
local leadParams = RaycastParams.new()
leadParams.FilterType = Enum.RaycastFilterType.Exclude
leadParams.RespectCanCollide = true
function FX.Lead(char: Model, dir: Vector3, dist: number, dur: number, delay: number)
	local body = char:FindFirstChild("HumanoidRootPart")
	local d = Vector3.new(dir.X, 0, dir.Z)
	if not (body and body:IsA("BasePart")) or dist < 0.3 or dur <= 0 or d.Magnitude < 1e-3 then
		return
	end
	local r = reelFor(char)
	if not r then
		return
	end
	d = d.Unit
	local t = os.clock()
	local from = body.Position + leadNow(r, t) -- (where it is drawn now)
	-- (the server's push stops short of a wall: so does the slide drawn here)
	leadParams.FilterDescendantsInstances = effectFilter()
	local hit = workspace:Raycast(from, d * (dist + 1.6), leadParams)
	if hit and hit.Normal.Y < 0.6 then
		dist = math.max(0, (hit.Position - from):Dot(d) - 1.6)
	end
	r.Body = body
	-- (the cap: the gap it already carries - a blow landing while replication still trails the last
	-- slide - plus this push, and some room: never a cap that pulls the body back into the stale spot)
	local carried = Vector3.new(from.X - body.Position.X, 0, from.Z - body.Position.Z).Magnitude
	r.Lead = { Dir = d, Dist = dist, T0 = t + delay, Dur = dur, From = from, Max = carried + dist + 2, Cur = 0, Curve = 0, At = t }
end

-- where this screen draws a body (its root, plus the slide replication hasn't brought yet)
function FX.Seen(root: BasePart): Vector3
	local r = reels[root.Parent :: any]
	return if r and r.Lead then root.Position + leadNow(r, os.clock()) else root.Position
end

-- the spring let go at once, the joints back at rest (a launched body: its ragdoll moves it now,
-- never a spring still writing its joints from the blow before)
function FX.StopGive(char: Model)
	local r = reels[char]
	if not r then
		return
	end
	if r.Conn then
		r.Conn:Disconnect()
		r.Conn = nil
	end
	local rj, neck = r.Root, r.Neck
	if rj and rest[rj] and rj.Parent then
		rj.C0 = rest[rj]
	end
	if neck and rest[neck] and neck.Parent then
		neck.C0 = rest[neck]
	end
	reels[char] = nil
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

local function callout(): any
	if not Callout then
		pcall(function()
			Callout = require(CombatFolder:WaitForChild("CombatCallout", 10))
		end)
	end
	return Callout
end

function FX.Damage(victim: Model, amount: number, kind: string, attacker: Model?)
	local c = callout()
	if c and c.Damage then
		c.Damage(victim, amount, kind, attacker)
	end
end

-- the server's number for a blow this screen already stamped on its own frame: only the difference
-- (the total counts to it; no second punch)
function FX.DamageCorrect(victim: Model?, delta: number)
	local c = callout()
	if victim and c and c.Correct then
		c.Correct(victim, delta)
	end
end

---------------------------------------------------------------------------
-- camera: directional impulses (local player only)
---------------------------------------------------------------------------
-- Every impulse is a kick that peaks fast and settles (x(t) = (t/tp) e^(1 - t/tp)), applied AFTER
-- the camera scripts each frame: the view is moved along the blow, rolled a touch into it and pushed
-- in along its own look - none of which changes where the camera looks, so the player's aim never
-- drifts. A rumble is a faint low-frequency tremor. Nothing runs while no impulse is live.
type Impulse = { Profile: string, Dir: Vector3, Kick: number, Up: number, Roll: number, Push: number, T0: number, Time: number, Rumble: number, RumbleTime: number, Seed: number }
-- (a kick never takes the view through the floor or a wall; and however many stack, never further
-- than this: a smash on five bodies used to push a low camera 2 studs into the ground)
local camParams = RaycastParams.new()
camParams.FilterType = Enum.RaycastFilterType.Exclude
camParams.RespectCanCollide = true
local MAX_MOVE, MAX_ROLL, MAX_PUSH = 0.6, 2.5, 0.6
local impulses: { Impulse } = {}
local camBound = false
-- the view the camera scripts left this frame, and what the kick made of it: a camera the scripts
-- don't rewrite every frame (a Fixed one) gets its own view back, so kicks never add up
local camBase: CFrame? = nil
local camSet: CFrame? = nil

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
		if cam and camSet and camBase and cam.CFrame == camSet then
			cam.CFrame = camBase
		end
		camBase, camSet = nil, nil
		return
	end
	if not cam or cam.CameraType == Enum.CameraType.Scriptable then
		table.clear(impulses)
		camBase, camSet = nil, nil
		return
	end
	-- (untouched since our last kick: the scripts didn't rewrite it - start from their view again)
	local base = if camSet and camBase and cam.CFrame == camSet then camBase else cam.CFrame
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
	if move.Magnitude > MAX_MOVE then
		move = move.Unit * MAX_MOVE
	end
	roll = math.clamp(roll, -MAX_ROLL, MAX_ROLL)
	push = math.clamp(push, -MAX_PUSH, MAX_PUSH)
	local kicked = CFrame.new(move) * base * CFrame.Angles(0, 0, math.rad(roll)) * CFrame.new(0, 0, -push)
	local off = kicked.Position - base.Position
	if off.Magnitude > 1e-3 then
		local hit = workspace:Raycast(base.Position, off + off.Unit * 0.3, camParams)
		if hit then
			kicked = base:Lerp(kicked, math.clamp(((hit.Position - base.Position).Magnitude - 0.3) / off.Magnitude, 0, 1))
		end
	end
	cam.CFrame = kicked
	camBase, camSet = base, kicked
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
	local t = os.clock()
	-- one blow on several bodies kicks the view once
	for _, im in ipairs(impulses) do
		if im.Profile == profile and t - im.T0 < 0.12 then
			return
		end
	end
	camParams.FilterDescendantsInstances = effectFilter() -- (once per kick, not per frame)
	-- the roll leans INTO the blow (the side it came from on screen), random only for a blow head-on
	local sign = if math.random() < 0.5 then -1 else 1
	local cam = workspace.CurrentCamera
	if cam and d.Magnitude > 0 then
		local sideways = cam.CFrame.RightVector:Dot(d)
		if math.abs(sideways) > 0.2 then
			sign = -math.sign(sideways)
		end
	end
	table.insert(impulses, {
		Profile = profile,
		Dir = d,
		Kick = p.Kick * s,
		Up = p.Up or 0,
		Roll = (p.Roll or 0) * s * sign,
		Push = (p.Fov or 0) * 0.12 * s,
		T0 = t,
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

---------------------------------------------------------------------------
-- THE IMPACT: every part of a landed blow on one frame
---------------------------------------------------------------------------

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
		if info.Victim then
			FX.GuardBreak(info.Victim, at, info.Attacker)
		end
	elseif info.Blocked then
		FX.Impact(at, if heavy then "HeavyBlock" else "Block", throw)
	else
		local tier = if def.Id == "Downslam" then "Stomp"
			elseif info.Launched and def.Id ~= "Sweep" then "Finisher"
			else def.Impact or "Light"
		FX.Impact(at, tier, throw)
		-- the blood: the strike's own profile, sized by the damage and by how hurt the body already is,
		-- shedding a trail as the body slides back (or flies: a launcher, a knockout)
		local push = if info.Launched then { Delay = hs } else { Time = if info.Immune then (def.KnockTime or 0) * 0.5 else (def.KnockTime or 0), Delay = hs }
		local path = Paths[def.Id]
		Blood.Spray(at, drive, def.Blood or "Light", info.Victim, info.DirSign, {
			Damage = info.Dmg, Health = info.Hp, Push = push, Launched = info.Launched,
			Striker = info.Attacker, Limbs = path and path.Limbs,
		})
		if type(info.Hp) == "number" and info.Hp <= 0 then
			-- the knockout: the body bursts, and rains blood along its flight
			Blood.Spray(at, drive, "KO", info.Victim, info.DirSign, { Damage = info.Dmg, Push = { Delay = hs }, Launched = true })
		end
	end
	-- the push, drawn at once on a body this screen sees through replication (FX.Lead; never my own,
	-- nor one in its escape window - it keeps control and half the push)
	if info.Victim and info.Me ~= "Victim" and not info.Launched and not info.Immune then
		if info.Blocked then
			local vr = info.Victim:FindFirstChild("HumanoidRootPart")
			local right = if vr and vr:IsA("BasePart") then vr.CFrame.RightVector else Vector3.zero
			local d = drive + Vector3.new(right.X, 0, right.Z) * (info.DirSign or 1) * 0.38 -- (CombatService blockPush)
			local bc = if def.GuardBreak then Config.Classes.Heavy else class
			FX.Lead(info.Victim, d, bc.BlockPush or 0, bc.BlockPushTime or 0, hs)
		else
			FX.Lead(info.Victim, drive, def.PushDistance or 0, def.KnockTime or 0, hs)
		end
	end
	-- a long slide back drags the feet: dust kicked up at them as it starts, and a trail of it along
	-- the way (one puff per ~0.3 s of slide), smaller as it slows
	if info.Victim and not info.Launched then
		local dist = if info.Blocked then (class.BlockPush or 0)
			else (def.Knock and def.Knock.Back or 0) * (def.KnockTime or 0) * Config.PushShare
		local time = if info.Blocked then class.BlockPushTime or 0 else def.KnockTime or 0
		if dist >= 4 and time > 0 then
			local victim = info.Victim
			local function feet(): Vector3?
				local r = victim:FindFirstChild("HumanoidRootPart")
				return if r and r:IsA("BasePart") then FX.Seen(r) - Vector3.new(0, 2.6, 0) else nil -- (where it is drawn)
			end
			local size = math.clamp(dist / 11, 0.35, 0.8)
			task.delay(hs, function()
				local p = feet()
				if p then
					FX.GroundDust(p, size * 0.55)
				end
			end)
			local n = math.clamp(math.floor(time / 0.3), 1, 4)
			for i = 1, n do
				local f = 0.05 + 0.9 * (i - 0.5) / n
				task.delay(hs + time * f, function()
					local p = feet()
					local g = p and groundUnder(p)
					if g then
						VFX.Play("DustPuff", CFrame.new(g + Vector3.new(0, 0.5, 0)), { Scale = size * 0.6 * (1.2 - f * 0.6), Count = 0.2 })
					end
				end)
			end
		end
	end
	-- the body giving with it (the launch gives the ragdoll instead)
	if info.Victim then
		if info.Blocked then
			FX.BlockGive(info.Victim, class, info.DirSign or 1, heavy, hs)
		elseif info.Launched then
			FX.StopGive(info.Victim)
		elseif not info.Break then
			FX.HitGive(info.Victim, def, info.DirSign or 1, hs)
		end
	end
	-- the camera, for the two fighters it concerns
	-- (the smash kicked its smasher on its own touchdown frame, and every body near it with StompNear:
	-- never once more per body it hits, a round trip late)
	if info.Me == "Attacker" and def.Id ~= "Downslam" then
		local prof = if info.Break then "GuardBreak" elseif info.Blocked then "Block" elseif def.Id == "Swing3" then "Hook" else class.Camera
		FX.Camera(nil, prof, drive, if info.Blocked then 0.7 else 1)
	elseif info.Me == "Victim" then
		local prof = if info.Break then "GuardBreak" elseif info.Blocked then "Block" else class.VictimCamera
		FX.Camera(nil, prof, drive, (if info.Immune then 0.6 else 1) * (if def.Id == "Downslam" then 0.6 else 1))
	end
end

return FX
