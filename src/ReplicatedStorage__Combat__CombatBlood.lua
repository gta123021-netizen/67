--[[
	CombatBlood  (ReplicatedStorage.Combat.CombatBlood)
	All the blood - client-side and cosmetic. Every client builds its own from the "Hit" it hears (the
	attacker from its own impact frame) and from the gore it sees. One system, three parts that work
	together:

	  THE AIR     droplets on real arcs (dv/dt = -k v + g, integrated exactly; one ray per frame's
	              chord, so nothing skips through a wall), each with its own size and drag - fine
	              spray, ordinary drops and heavy blobs - plus the place's own blood effects
	              (ReplicatedStorage.Combat.VFX: the blood packs copied out of the Workspace)
	  THE GROUND  where a drop lands it pours into the surface's liquid (BloodPools): pools that
	              build up where blood keeps landing, merge into one, run downhill and down walls,
	              dry and soak away
	  THE WOUNDS  a torn limb's stump (and the torn limb itself, and a neck) bleeds on its own: a
	              strong first gush and a couple of weaker ones, then a heartbeat - intermittent
	              spurts, short squirts between them, a steady dribble - that weakens as the body
	              empties, then an ooze. The jet comes out of the wound the way the wound faces
	              (every frame: a turning, falling, ragdolled body turns its jet with it), whips a
	              little from beat to beat and sags as the pressure drops

	MOMENTUM. Every drop and every effect from a body leaves with that body's own velocity (the wound
	point's, spin included) - blood from a running fighter streaks back behind it, blood from a
	flung body flies with it and rains down along its path. A body sliding back from a blow, or
	thrown by a launcher, sheds a trail of drops as it goes.

	NOTHING IS THE SAME TWICE. Each blow has a profile (Config.Blood.Profiles: Light, Hook, Heavy,
	Dash, Stomp, Finisher, KO, Tear, Head) with ranges, not numbers: which of the place's effects it
	uses (a core effect picked by weight, maybe an extra one), how big and how dense, how many drops
	and of what sizes, how wide, how fast, how far the struck part's motion carries them, whether a
	late squirt follows from the wound or blood is spat from the mouth, and the knockback trail. It
	all scales with the damage and with how hurt the fighter already is. The aim of every spray is
	jittered a little, every heartbeat is a little early or late.

	  Blood.Spray(pos, drive, profile, victim?, dirSign?, opts?)  a clean blow's blood (CombatFX)
	      opts = { Damage, Health (share left), Push = { Time, Delay }, Launched }
	  Blood.Wound(att, opts) -> { Stop }   a wound that bleeds on its own (CombatGore); opts =
	      { Strength, Pump (seconds of spurting), Ooze (seconds of oozing after), Delay (first beat),
	        Gushes (the first gushes, 0..3), Dir (() -> world direction; default: the attachment's
	        UpVector), Body (the model it bleeds from) }
	  Blood.Trail(part, delay, time, strength)   drops shed from a moving part (a slide, a launch)
	  Blood.Splash(pos, strength, normal?)       blood hitting a surface all at once (a limb landing)
	  Blood.Effect(name, pos, dir, opts?)        one of the place's effects (CombatVFX.Play options)
	  Blood.Burst(pos, dir, name, scale?, count?)   the same, the old way
	  Blood.Launch(pos, vel, size, kind?)        one droplet ("Fine" | "Drop" | "Blob")
	  Blood.Cone(dir, deg) / Blood.Ignore(body)

	Built to be cheap: droplets and pool pieces are pooled (never created or destroyed while the fight
	runs), one Heartbeat steps everything and stops when nothing is left, effects copies are reused
	(CombatVFX), nothing is built out of the camera's reach (Config.Blood.View), and every budget is
	capped (MaxDrops; the pools' own caps).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))
local Pools = require(CombatFolder:WaitForChild("BloodPools"))

local Blood = {}

local B = Config.Blood
local W = B.Wound

-- THE DEVICE'S SHARE. A player who set the graphics low (or a phone) gets smaller budgets - fewer
-- droplets in the air, fewer pool pieces on the ground - never less blood per blow
local function budget(): number
	local k = 1
	pcall(function()
		local q = UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
		if q >= 1 and q <= 3 then
			k = 0.5
		elseif q >= 4 and q <= 6 then
			k = 0.75
		end
	end)
	pcall(function()
		local UIS = game:GetService("UserInputService")
		if UIS.TouchEnabled and not UIS.KeyboardEnabled then
			k = math.min(k, 0.7)
		end
	end)
	return k
end
local BUDGET = budget()
local MAX_DROPS = math.floor(B.MaxDrops * BUDGET)
local DROP_LIFE = 2.4 -- a drop that has met nothing by then (off a cliff) is gone
local SUBSTEP = 1 / 30 -- (the longest chord one ray covers)
local G = Vector3.new(0, -workspace.Gravity, 0)
local PARK = CFrame.new(0, -5000, 0)
local WET = B.Color

local function rand(a: number, b: number): number
	return a + math.random() * (b - a)
end
local function range(r: { number }?, default: number): number
	if not r then
		return default
	end
	return r[1] + math.random() * (r[2] - r[1])
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

-- the velocity of a point on a (maybe spinning) part: what blood leaving it there carries
local function pointVelocity(part: Instance?, at: Vector3): Vector3
	if part and part:IsA("BasePart") then
		local ok, v = pcall(part.GetVelocityAtPosition, part, at)
		if ok and typeof(v) == "Vector3" and v == v then
			-- (a teleport or a glitching physics frame never flings blood across the map)
			return if v.Magnitude > 120 then v.Unit * 120 else v
		end
	end
	return Vector3.zero
end

---------------------------------------------------------------------------
-- droplets (a bead + its streak)
---------------------------------------------------------------------------
type Drop = {
	Part: Part,
	Trail: Trail,
	A0: Attachment,
	A1: Attachment,
	Pos: Vector3,
	Vel: Vector3,
	Size: number,
	K: number, -- its air drag (1/s): big drops fall, fine spray hangs
	Term: Vector3, -- (the velocity drag and gravity balance at)
	Weight: number, -- how much blood it pours where it lands (x its own volume)
	Age: number,
	Live: boolean,
}
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
	tr.Color = ColorSequence.new(WET, B.Pool.Fresh)
	tr.Transparency = STREAK_T
	tr.WidthScale = STREAK_W
	tr.LightInfluence = 1
	tr.Enabled = false
	tr.Parent = p
	p.Parent = holder()
	local d = { Part = p, Trail = tr, A0 = a0, A1 = a1, Pos = Vector3.zero, Vel = Vector3.zero, Size = 0.12, K = B.Drag, Term = G / B.Drag, Weight = 1, Age = 0, Live = false }
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

-- the exact flight: position and velocity after `h` seconds
local function advance(d: Drop, h: number): (Vector3, Vector3)
	local k = d.K
	local e = math.exp(-k * h)
	local rel = d.Vel - d.Term
	return d.Pos + d.Term * h + rel * ((1 - e) / k), d.Term + rel * e
end

local function fly(d: Drop, dt: number): RaycastResult?
	local left = dt
	while left > 1e-6 do
		local h = math.min(SUBSTEP, left)
		left -= h
		local x1, v1 = advance(d, h)
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

-- (a heavy drop smacking down fast throws the packs' flat splash where it lands - a few a second)
local splashAt = 0
local splashBudget = 0
local function landingSplash(hit: RaycastResult, d: Drop)
	local speed = d.Vel.Magnitude
	if d.Size < 0.12 or speed < 13 or hit.Normal.Y < 0.6 then
		return
	end
	local now = os.clock()
	splashBudget = math.min(4, splashBudget + (now - splashAt) * 5)
	splashAt = now
	if splashBudget < 1 or math.random() > 0.45 then
		return
	end
	splashBudget -= 1
	local sc = math.clamp(d.Size * 1.6 + speed * 0.008, 0.18, 0.42)
	VFX.Play("BloodSplash", VFX.Along(hit.Position + hit.Normal * 0.06, hit.Normal), { Scale = sc, Life = rand(0.7, 1) })
end

---------------------------------------------------------------------------
-- wounds, trails and the late squirts: everything that keeps bleeding, stepped with the drops
---------------------------------------------------------------------------
type Wound = {
	Att: Attachment,
	Body: Instance?,
	Str: number,
	T0: number,
	Delay: number,
	Pump: number,
	Ooze: number,
	Dir: (() -> Vector3)?,
	NextBeat: number,
	Gushes: { { At: number, K: number } },
	Pulse: { T0: number, Len: number, K: number, Peak: number, Total: number, Out: number, Dir: Vector3 }?,
	Squirt: number?,
	WobX: number,
	WobY: number,
	DripAcc: number,
	ShedAcc: number,
	Done: boolean,
}
type TrailTask = { Part: BasePart, T0: number, Delay: number, Time: number, Str: number, Acc: number }
type Late = { At: number, Fn: () -> () }
local wounds: { Wound } = {}
local trails: { TrailTask } = {}
local lates: { Late } = {}

local stepConn: RBXScriptConnection? = nil
local step: (number) -> ()
local function wake()
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
end

-- one droplet. kind: "Fine" (a speck of spray: small, fast, hangs in the air a moment), "Drop",
-- "Blob" (a heavy one: falls straight through the air, pours a lot where it lands)
function Blood.Launch(pos: Vector3, vel: Vector3, size: number, kind: string?)
	if not B.Enabled or not inView(pos) then
		return
	end
	local d = takeDrop()
	if not d then
		return
	end
	refreshFilter()
	local k = B.Drag * (0.11 / math.clamp(size, 0.03, 0.3)) ^ 0.6
	local weight = 1
	if kind == "Fine" then
		k *= 1.6
		weight = 1.4 -- (a mist of them adds up)
	elseif kind == "Blob" then
		k *= 0.6
		weight = 1.5
	end
	d.Live = true
	d.Age = 0
	d.Pos = pos
	d.Vel = vel
	d.Size = size
	d.K = k
	d.Term = G / k
	d.Weight = weight
	d.A0.Position = Vector3.new(size * 0.5, 0, 0)
	d.A1.Position = Vector3.new(-size * 0.5, 0, 0)
	d.Part.Size = Vector3.new(size, size, size)
	d.Part.CFrame = CFrame.lookAt(pos, pos + (if vel.Magnitude > 0.1 then vel else Vector3.yAxis))
	-- (a speck of spray is just a bead: no streak behind it)
	d.Trail.Lifetime = if size > 0.13 then 0.12 else 0.09
	d.Trail:Clear()
	d.Trail.Enabled = size >= 0.055
	wake()
end
local launch = Blood.Launch

-- one of the place's blood effects at `pos`, thrown along `dir` (CombatVFX.Play options)
function Blood.Effect(name: string, pos: Vector3, dir: Vector3, opts: any?): Attachment?
	if not B.Enabled then
		return nil
	end
	local o = opts or {}
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local cf = VFX.Along(pos, up)
	if o.Parent and o.Parent:IsA("BasePart") then
		cf = (o.Parent :: BasePart).CFrame:ToObjectSpace(cf)
	end
	if not inView(pos) then
		return nil
	end
	return VFX.Play(name, cf, o)
end
local effect = Blood.Effect

function Blood.Burst(pos: Vector3, dir: Vector3, name: string, scale: number?, count: number?)
	effect(name, pos, dir, { Scale = scale or 1, Count = count or 1 })
end

-- the wound's way out right now: the way it faces, the whip of the artery, sagging as it empties
local function woundDir(w: Wound, pressure: number): Vector3
	local base = if w.Dir then w.Dir() else w.Att.WorldCFrame.UpVector
	if base.Magnitude < 1e-3 then
		base = Vector3.yAxis
	end
	base = base.Unit
	local right = base:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local up = right:Cross(base).Unit
	local d = (base + right * math.tan(w.WobX) + up * math.tan(w.WobY)).Unit
	-- (as the pressure goes the jet can't hold its line: it bows down)
	local sag = (1 - pressure) * 0.55
	return (d + Vector3.new(0, -sag, 0)).Unit
end

local function woundPart(w: Wound): BasePart?
	local p = w.Att.Parent
	return if p and p:IsA("BasePart") then p else nil
end

-- a gush: a big wet throw out of the wound (the first moments of a tear)
local function gush(w: Wound, k: number)
	local pos = w.Att.WorldPosition
	local part = woundPart(w)
	local dir = woundDir(w, 1)
	local carry = pointVelocity(part, pos) * W.Inherit
	local s = w.Str * k
	effect(if math.random() < 0.6 then "BloodGush" else "BloodStream", pos, dir, {
		Parent = part, Inherit = W.Inherit, Scale = 0.45 + 0.4 * s, Count = 0.35 + 0.5 * s, Speed = rand(0.8, 1.15), Spread = rand(0.6, 1),
	})
	for _ = 1, math.floor(3 + 7 * s + math.random() * 2) do
		local dd = cone(dir, rand(12, 30))
		local big = math.random() < 0.3
		launch(pos + dd * 0.12, dd * rand(11, 21) * math.sqrt(s) + carry, if big then rand(0.14, 0.2) else rand(0.07, 0.13), if big then "Blob" else "Drop")
	end
end

-- a heartbeat's spurt: the jet rises and falls over the beat (the drops it throws go further, then
-- shorter), with the packs' jet or stream along it and now and then long thin strands
local function spurt(w: Wound, pressure: number, now: number)
	local k = pressure * w.Str * rand(0.72, 1.15)
	if k < 0.05 then
		return
	end
	local dir = woundDir(w, pressure)
	w.Pulse = { T0 = now, Len = 0.1 + 0.12 * math.min(k, 1.2), K = k, Peak = (6 + 16 * math.sqrt(pressure)) * math.sqrt(w.Str) * rand(0.85, 1.12), Total = math.floor(2 + 8 * k + math.random() * 2), Out = 0, Dir = dir }
	local pos = w.Att.WorldPosition
	local part = woundPart(w)
	if not inView(pos) then
		return
	end
	effect(if math.random() < 0.55 then "BloodJet" else "BloodStream", pos, dir, {
		Parent = part, Inherit = W.Inherit, Scale = 0.35 + 0.35 * math.min(k, 1.3), Count = 0.25 + 0.55 * math.min(k, 1.3),
		Speed = 0.55 + 0.6 * math.sqrt(pressure), Spread = rand(0.5, 1.1), Gravity = rand(0.85, 1.2),
	})
	if math.random() < 0.35 * pressure + 0.1 then
		effect("BloodStrand", pos, dir, { Parent = part, Inherit = W.Inherit, Scale = rand(0.6, 1), Count = rand(0.3, 0.7), Speed = 0.6 + 0.5 * pressure, Spread = 0.6 })
	end
end

-- the drops of a spurt in progress: spread over its beat, fastest at its peak
local function pulseStep(w: Wound, now: number)
	local p = w.Pulse
	if not p then
		return
	end
	local u = math.min((now - p.T0) / p.Len, 1)
	-- (how many of its drops should be out by now: slow at the start and the end, most at the peak)
	local want = math.floor((1 - math.cos(math.pi * u)) * 0.5 * p.Total + 0.5) - p.Out
	if u >= 1 or p.Out >= p.Total then
		w.Pulse = nil
	end
	if want <= 0 then
		return
	end
	local pos = w.Att.WorldPosition
	local carry = pointVelocity(woundPart(w), pos) * W.Inherit
	local env = math.sin(math.pi * math.clamp(u, 0, 1))
	for _ = 1, math.min(want, 4) do
		p.Out += 1
		local dd = cone(p.Dir, rand(4, 11) + (1 - env) * 10)
		local speed = p.Peak * (0.5 + 0.5 * env) * rand(0.88, 1.08)
		local big = math.random() < 0.18
		launch(pos + dd * 0.1, dd * speed + carry, if big then rand(0.13, 0.18) else rand(0.06, 0.12), if big then "Blob" else "Drop")
	end
end

local function woundStep(w: Wound, dt: number, now: number, slow: number): boolean
	local att = w.Att
	if w.Done or not att:IsDescendantOf(workspace) or (w.Body and not w.Body.Parent) then
		return false
	end
	local age = (now - w.T0) * slow
	local pumpEnd = w.Delay + w.Pump
	if age > pumpEnd + w.Ooze then
		return false
	end
	local pos = att.WorldPosition
	local seen = inView(pos)
	-- the first gushes
	for i = #w.Gushes, 1, -1 do
		local g = w.Gushes[i]
		if age >= g.At then
			table.remove(w.Gushes, i)
			if seen then
				gush(w, g.K)
			end
		end
	end
	-- the heartbeat
	local pressure = 0
	if age >= w.Delay and age < pumpEnd then
		pressure = math.exp(-3.1 * (age - w.Delay) / math.max(w.Pump, 0.01))
		if now >= w.NextBeat then
			local bpm = W.BpmLow + (W.BpmHigh - W.BpmLow) * pressure
			local gap = 60 / bpm * rand(0.86, 1.14)
			w.NextBeat = now + gap / slow
			-- the artery whips a little from beat to beat
			w.WobX = math.clamp(w.WobX * 0.7 + rand(-0.2, 0.2), -0.45, 0.45)
			w.WobY = math.clamp(w.WobY * 0.7 + rand(-0.2, 0.2), -0.45, 0.45)
			if seen then
				spurt(w, pressure, now)
			end
			-- a short squirt between beats, now and then
			w.Squirt = if math.random() < 0.2 + 0.3 * pressure then now + gap * rand(0.35, 0.65) / slow else nil
		end
		if w.Squirt and now >= w.Squirt then
			w.Squirt = nil
			if seen then
				local dir = woundDir(w, pressure * 0.7)
				local carry = pointVelocity(woundPart(w), pos) * W.Inherit
				for _ = 1, math.random(1, 3) do
					local dd = cone(dir, rand(5, 14))
					launch(pos + dd * 0.08, dd * rand(5, 11) * (0.5 + pressure) + carry, rand(0.05, 0.09), "Drop")
				end
				if math.random() < 0.4 then
					effect("BloodStrand", pos, dir, { Parent = woundPart(w), Inherit = W.Inherit, Scale = rand(0.4, 0.7), Count = 0.25, Speed = 0.45 + 0.4 * pressure, Spread = 0.5 })
				end
			end
		end
	end
	if seen then
		pulseStep(w, now)
		local part = woundPart(w)
		local carry = pointVelocity(part, pos)
		-- the dribble: blood running out of the wound and falling from it - pooling under a body that
		-- stands still, a trail of drips behind one that moves
		local rate
		if age < pumpEnd then
			rate = (W.Dribble[1] + (W.Dribble[2] - W.Dribble[1]) * pressure) * w.Str
		else
			local u = (age - pumpEnd) / math.max(w.Ooze, 0.01)
			rate = W.OozeRate * (1 - u) ^ 1.5 * math.max(w.Str, 0.6)
		end
		w.DripAcc += rate * dt * slow
		while w.DripAcc >= 1 do
			w.DripAcc -= 1
			local out = woundDir(w, 0.2) * rand(0.3, 1.5)
			launch(pos + out * 0.05, out + carry * W.Inherit + Vector3.new(rand(-0.3, 0.3), -rand(0.2, 1), rand(-0.3, 0.3)), rand(0.05, 0.09) * (if age < pumpEnd then 1.15 else 0.9), "Drop")
		end
		-- moving fast, the air strips blood off the wound: a streak of fine drops behind it
		local fast = carry.Magnitude
		if fast > W.ShedSpeed then
			w.ShedAcc += (fast - W.ShedSpeed) * W.ShedRate * math.max(pressure, 0.25) * dt * slow
			while w.ShedAcc >= 1 do
				w.ShedAcc -= 1
				launch(pos, carry * rand(0.75, 0.92) + Vector3.new(rand(-1, 1), rand(-1, 0.5), rand(-1, 1)), rand(0.04, 0.07), "Fine")
			end
		end
	end
	return true
end

local function trailStep(t: TrailTask, dt: number, now: number, slow: number): boolean
	local part = t.Part
	if not part.Parent then
		return false
	end
	local age = (now - t.T0) * slow - t.Delay
	if age < 0 then
		return true
	end
	if age > t.Time then
		return false
	end
	local u = age / t.Time
	t.Acc += t.Str * B.TrailRate * (1 - u) ^ 1.4 * dt * slow
	if t.Acc < 1 then
		return true
	end
	if not inView(part.Position) then
		t.Acc = 0
		return true
	end
	local cf = part.CFrame
	local half = part.Size * 0.5
	while t.Acc >= 1 do
		t.Acc -= 1
		local p = cf:PointToWorldSpace(Vector3.new(rand(-half.X, half.X), rand(-half.Y, half.Y * 0.5), rand(-half.Z, half.Z)))
		local v = pointVelocity(part, p)
		launch(p, v * rand(0.8, 0.95) + Vector3.new(rand(-1.2, 1.2), -rand(0.5, 2), rand(-1.2, 1.2)), rand(0.05, 0.1), if math.random() < 0.25 then "Fine" else "Drop")
	end
	return true
end

local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}
function step(dt: number)
	local slow = VFX.TimeScale() -- (Studio inspection can slow it down with the effects)
	dt = math.min(dt, 0.1)
	local h = dt * slow
	local now = os.clock()
	table.clear(moveParts)
	table.clear(moveCfs)
	local any = false
	refreshFilter()
	-- (the late ones first: a squirt a moment after the blow, a spit of blood)
	for i = #lates, 1, -1 do
		local l = lates[i]
		if now >= l.At then
			table.remove(lates, i)
			local ok, err = pcall(l.Fn)
			if not ok then
				warn("[Combat] blood:", err)
			end
		end
	end
	for i = #wounds, 1, -1 do
		local ok, keep = pcall(woundStep, wounds[i], dt, now, slow)
		if not ok then
			warn("[Combat] wound:", keep)
		end
		if not (ok and keep) then
			wounds[i].Done = true
			table.remove(wounds, i)
		end
	end
	for i = #trails, 1, -1 do
		local ok, keep = pcall(trailStep, trails[i], dt, now, slow)
		if not (ok and keep) then
			table.remove(trails, i)
		end
	end
	for _, d in ipairs(drops) do
		if d.Live then
			any = true
			local hit = fly(d, h)
			if hit or d.Age > DROP_LIFE then
				d.Live = false
				d.Trail.Enabled = false
				if hit then
					if Pools.Deposit(hit, d.Size, d.Vel, d.Weight) then
						landingSplash(hit, d)
					end
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
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if not any and #wounds == 0 and #trails == 0 and #lates == 0 and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function later(delay: number, fn: () -> ())
	table.insert(lates, { At = os.clock() + delay / VFX.TimeScale(), Fn = fn })
	wake()
end

Pools.Init({
	Holder = holder,
	Cast = function(o: Vector3, d: Vector3): RaycastResult?
		refreshFilter()
		return castSolid(o, d)
	end,
	-- a pool that runs off an edge, blood gathering under a ceiling: it falls again
	Drip = function(p: Vector3, v: Vector3, s: number)
		launch(p, v, s, "Drop")
	end,
	InView = inView,
	TimeScale = VFX.TimeScale,
	Budget = BUDGET,
})

---------------------------------------------------------------------------
-- API: wounds, trails, splashes
---------------------------------------------------------------------------
function Blood.Wound(att: Attachment, opts: any?): { Stop: () -> () }
	local o = opts or {}
	local now = os.clock()
	local w: Wound = {
		Att = att,
		Body = o.Body,
		Str = o.Strength or 1,
		T0 = now,
		Delay = o.Delay or 0,
		Pump = o.Pump or 0,
		Ooze = o.Ooze or 0,
		Dir = o.Dir,
		NextBeat = now + (o.Delay or 0) / VFX.TimeScale(),
		Gushes = {},
		Pulse = nil,
		Squirt = nil,
		WobX = rand(-0.15, 0.15),
		WobY = rand(-0.15, 0.15),
		DripAcc = 0,
		ShedAcc = 0,
		Done = false,
	}
	-- the tear's own gushes after its first burst: each weaker, each a touch late or early
	local n = o.Gushes or 0
	local at = 0
	for i = 1, n do
		at += rand(0.07, 0.13) * (1 + (i - 1) * 0.35)
		table.insert(w.Gushes, { At = at, K = 0.8 * (0.68 ^ (i - 1)) * rand(0.85, 1.1) })
	end
	if not B.Enabled then
		w.Done = true
	else
		table.insert(wounds, w)
		wake()
	end
	return {
		Stop = function()
			w.Done = true
		end,
	}
end

function Blood.Trail(part: BasePart?, delay: number, time: number, strength: number)
	if not (B.Enabled and part and part:IsA("BasePart")) or time <= 0 or strength <= 0 then
		return
	end
	table.insert(trails, { Part = part, T0 = os.clock(), Delay = delay, Time = time, Str = strength, Acc = 0 })
	wake()
end

-- blood hitting a surface all at once under / at `pos` (a torn limb slapping down, a bleeding body
-- falling): the packs' flat splash on the surface, a wet patch poured into the pool there, a few
-- drops thrown up out of it
function Blood.Splash(pos: Vector3, strength: number, normal: Vector3?)
	if not B.Enabled or not inView(pos) then
		return
	end
	refreshFilter()
	local n = normal or Vector3.yAxis
	local hit = castSolid(pos + n * 1.2, n * -3.2)
	if not hit then
		return
	end
	local s = math.clamp(strength, 0.1, 2)
	VFX.Play("BloodSplash", VFX.Along(hit.Position + hit.Normal * 0.06, hit.Normal), { Scale = 0.3 + 0.3 * s, Life = rand(0.8, 1.1) })
	if math.random() < 0.7 then
		effect("BloodSplatter", hit.Position + hit.Normal * 0.1, hit.Normal, { Scale = 0.25 + 0.2 * s, Count = 0.25 + 0.25 * s, Speed = 0.6, Life = 0.8 })
	end
	Pools.Pour(hit, 0.12 * s + 0.05, 0.25 + 0.25 * s)
	for _ = 1, math.floor(2 + 3 * s) do
		local d = cone(hit.Normal, 55)
		launch(hit.Position + hit.Normal * 0.1, d * rand(4, 9) * math.sqrt(s), rand(0.05, 0.1), "Drop")
	end
end

---------------------------------------------------------------------------
-- a clean blow's blood (CombatFX): the profile's effects, the drops, and what follows
---------------------------------------------------------------------------
-- (the attacks' old tier names)
local ALIAS = { Body = "Dash" }

-- the outward normal of the body surface at `pos` (the head's for a blow above the shoulders, the
-- torso's lower down), and the struck part's motion just after the blow - each hit's own mix
local function wound(pos: Vector3, drive: Vector3, pr: any, victim: Model?, dirSign: number?): (Vector3, Vector3)
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
	return normal, d * pr.Carry * rand(0.75, 1.25) + side * pr.Side * rand(0.7, 1.3) + Vector3.new(0, pr.Lift * rand(0.75, 1.2), 0)
end

-- one effect off a weighted list (Name, W, Scale, Count), sized by the blow
local function pick(list: { any }): any
	local total = 0
	for _, e in ipairs(list) do
		total += e.W or 1
	end
	local r = math.random() * total
	for _, e in ipairs(list) do
		r -= e.W or 1
		if r <= 0 then
			return e
		end
	end
	return list[#list]
end

local function playPick(e: any, pos: Vector3, dir: Vector3, sev: number, delay: number)
	effect(e.Name, pos, dir, {
		Scale = range(e.Scale, 1) * sev ^ 0.25,
		Count = range(e.Count, 1) * sev ^ 0.5,
		Speed = rand(0.85, 1.15),
		Spread = rand(0.8, 1.15),
		Gravity = rand(0.85, 1.2),
		Face = e.Face,
		Delay = delay,
	})
end

-- the body part a blow landed on, and the point on it (for what follows the blow as the body moves)
local function struckPart(victim: Model?, pos: Vector3): BasePart?
	if not victim then
		return nil
	end
	local head = victim:FindFirstChild("Head")
	local torso = victim:FindFirstChild("Torso") or victim:FindFirstChild("UpperTorso") or victim:FindFirstChild("HumanoidRootPart")
	if head and head:IsA("BasePart") and head.Transparency < 1 and pos.Y > head.Position.Y - head.Size.Y * 0.6 then
		return head
	end
	return if torso and torso:IsA("BasePart") then torso else nil
end

function Blood.Spray(pos: Vector3, drive: Vector3, profile: string?, victim: Model?, dirSign: number?, opts: any?)
	if not B.Enabled or not inView(pos) then
		return
	end
	local name = profile or "Light"
	local pr = B.Profiles[name] or B.Profiles[ALIAS[name] or ""] or B.Profiles.Light
	local o = opts or {}
	-- how hard: the blow's damage against the profile's own, and how hurt the fighter already is
	local sev = math.clamp((o.Damage or pr.Ref) / pr.Ref, 0.7, 1.7) ^ 0.6
	if type(o.Health) == "number" then
		sev *= 1 + 0.45 * (1 - math.clamp(o.Health, 0, 1))
	end
	sev *= rand(0.88, 1.12)
	local normal, head = wound(pos, drive, pr, victim, dirSign)
	-- aimed out of the wound, thrown the way the struck part goes - sideways with a hook, up with an
	-- uppercut - but never into the body (the part of that motion running back into it is the body's)
	local carried = head - normal * math.min(0, head:Dot(normal))
	local eject = pr.Eject
	local mean = normal * (eject[1] + eject[2]) * 0.3 + carried * 0.6
	local aim = cone(if mean.Magnitude > 1e-3 then mean.Unit else normal, rand(4, 12))
	-- the place's effects: one core effect, maybe one more
	playPick(pick(pr.Core), pos, aim, sev, 0)
	if pr.Extra and math.random() < pr.Extra.Chance * math.min(1.35, sev) then
		playPick(pick(pr.Extra.List), pos, cone(aim, 18), sev, rand(0, 0.05))
	end
	-- the liquid: drops flung out of the wound on their own arcs, the struck part's motion in them
	local spread = range(pr.Spread, 30)
	local nDrops = math.floor(range(pr.Drops, 3) * sev + math.random())
	for _ = 1, nDrops do
		local dir = cone(aim, spread)
		local speed = rand(eject[1], eject[2]) * sev ^ 0.35
		if math.random() < (pr.Blob or 0) then
			launch(pos + dir * 0.15, dir * speed * 0.75 + carried * 0.3, range(pr.Size, 0.1) * rand(1.4, 1.8), "Blob")
		else
			launch(pos + dir * 0.15, dir * speed + carried * 0.35, range(pr.Size, 0.1), "Drop")
		end
	end
	-- a fine spray with it: a lot of small, fast specks in a tighter cone
	local nFine = math.floor(range(pr.Fine, 0) * sev + math.random())
	for _ = 1, nFine do
		local dir = cone(aim, spread * 0.7)
		launch(pos + dir * 0.1, dir * rand(eject[1], eject[2]) * rand(1.1, 1.4) + carried * 0.25, rand(0.035, 0.055), "Fine")
	end
	local part = struckPart(victim, pos)
	-- a late squirt out of the same wound, wherever the body has got to by then
	local sq = pr.Squirt
	if part and sq and math.random() < sq.Chance * math.min(1.4, sev) then
		local rel = part.CFrame:PointToObjectSpace(pos)
		local relDir = part.CFrame:VectorToObjectSpace(normal)
		later(range(sq.Delay, 0.1), function()
			if not part.Parent then
				return
			end
			local p = part.CFrame:PointToWorldSpace(rel)
			local d = cone(part.CFrame:VectorToWorldSpace(relDir) + Vector3.new(0, 0.25, 0), 10)
			local carry = pointVelocity(part, p)
			effect(if math.random() < 0.6 then "BloodStrand" else "BloodJet", p, d, { Parent = part, Inherit = W.Inherit, Scale = rand(0.35, 0.6), Count = rand(0.3, 0.55), Speed = rand(0.6, 0.95), Spread = 0.6 })
			for _ = 1, math.floor(range(sq.Drops, 2) + math.random()) do
				local dd = cone(d, 9)
				launch(p + dd * 0.1, dd * rand(7, 13) + carry * W.Inherit, rand(0.05, 0.1), "Drop")
			end
		end)
	end
	-- blood spat or coughed out of the mouth (a blow to the chin, the gut)
	local sp = pr.Spit
	local headPart = victim and victim:FindFirstChild("Head")
	if sp and headPart and headPart:IsA("BasePart") and headPart.Transparency < 1 and math.random() < sp.Chance then
		later(range(sp.Delay, 0.05), function()
			if not headPart.Parent then
				return
			end
			local cf = headPart.CFrame
			local mouth = cf:PointToWorldSpace(Vector3.new(0, -headPart.Size.Y * 0.2, -headPart.Size.Z * 0.5))
			local d = (cf.LookVector * (1 - sp.Up) + Vector3.new(0, sp.Up, 0) + drive * 0.3).Unit
			local carry = pointVelocity(headPart, mouth)
			effect("BloodDrip", mouth, d, { Scale = rand(0.35, 0.55), Count = rand(0.5, 0.9), Speed = rand(0.7, 1.1), Spread = 0.5, Inherit = W.Inherit, Parent = headPart })
			for _ = 1, math.random(3, 6) do
				local dd = cone(d, 16)
				launch(mouth + dd * 0.05, dd * rand(4, 9) + carry * W.Inherit, rand(0.04, 0.08), if math.random() < 0.4 then "Fine" else "Drop")
			end
		end)
	end
	-- the body goes: it sheds a trail of drops along its slide, or along its flight
	local body = victim and (victim:FindFirstChild("Torso") or victim:FindFirstChild("UpperTorso") or victim:FindFirstChild("HumanoidRootPart"))
	if body and body:IsA("BasePart") then
		if o.Launched then
			Blood.Trail(body, (o.Push and o.Push.Delay) or 0.05, 0.9, ((pr.Trail or 0) + 0.45) * sev)
		elseif o.Push and (o.Push.Time or 0) > 0.05 and (pr.Trail or 0) > 0 then
			Blood.Trail(body, o.Push.Delay or 0, o.Push.Time, pr.Trail * sev)
		end
	end
end

return Blood
