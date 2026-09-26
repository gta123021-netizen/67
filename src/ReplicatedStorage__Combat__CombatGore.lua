--[[
	CombatGore  (ReplicatedStorage.Combat.CombatGore)
	Damage you can SEE on a fighter - NPCs and players alike (Config.Gore.Players): as its health
	falls through Config.Gore.Stages its body comes apart, in this order and never out of it -
	  1  the right arm is torn off at the shoulder (health <= 75%)
	  2  the left arm (<= 50%)
	  3  the killing blow bursts the head in a huge bloody mist (0)
	A blow that takes several stages at once plays each of them in turn (a beat apart), in order. A
	lost limb stays lost until the fighter respawns - and it matters: the server keeps the stage
	(the character's GoreStage attribute), hides the lost limb for everyone and makes a one-armed
	fighter easier to hurt and an armless one unable to block (Config.GoreDamage, CombatService).

	Here, on every client: the stage plays on the blow's own frame (the attacker from its own impact
	frame, everyone else from the server's Hit, which carries the stage), with the torn limb thrown,
	the wounds and the blood. A body that is already missing limbs when this client first sees it
	(joining late, streamed in) just has its wounds, nothing replayed. Fighters outside the combat
	(any other R6 NPC in the place) come apart by their own health the same way. Works for ANY R6
	body: everything is found by the R6 part names and fitted to its own part sizes and clothing.

	What each stage does
	  ARM   the real arm is hidden (locally) and a copy of it - its colour, its sleeve (the NPC's
	        Shirt) - is torn away with the blow: thrown along the way the blow drove, tumbling, a torn
	        wound on its top end (the gore kit's arm end) trailing blood and shedding drops; it hits
	        the ground, rolls and comes to rest (real physics on this client, colliding with the world,
	        never with a fighter). On the torso the shoulder is a raw stump (the kit's shoulder cap)
	        that pumps blood in pulses, slowing, and drips
	  HEAD  the head bursts: a thick red mist, a spray of droplets all round, chunks of flesh and
	        bits of skull thrown out on real arcs; what is left is the neck's torn stump with the base
	        of the skull, and a fountain of blood that dies down in pulses
	  (all the blood is the place's own blood effects - ReplicatedStorage.Combat.VFX Blood and
	  BloodHeavy - through CombatBlood; the droplets are gone where they land)
	  (the hole in the torso from the gore kit is never used)
	The pieces thrown off fade out and are gone after Config.Gore.GibLife.

	  Gore.Start()                      watch every body in the workspace (CombatClient calls it)
	  Gore.Hit(body, health, drive, stage?)  a blow just landed and left `health` (drive: the way it
	                                    travels; stage: the server's word): its stage plays on the blow
	  Gore.StageOf(body)                how far that body has come apart (0..3)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Blood = require(CombatFolder:WaitForChild("CombatBlood"))
local FX = require(CombatFolder:WaitForChild("CombatFX"))

local Gore = {}
local GC = Config.Gore

---------------------------------------------------------------------------
-- the gore kit's pieces, measured against a standard R6 torso (2 x 2 x 1): where each sits in the
-- torso's own frame (or the arm's / the head's), and its size there
---------------------------------------------------------------------------
local function rot(m: { number }): CFrame
	return CFrame.new(0, 0, 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
end
local KIT = {
	-- (in the torso's frame)
	RightStump = { Name = "right.shoulder", Pos = Vector3.new(0.735, 0.417, 0.002), Rot = rot({ 1, 0, 0, 0, 1, 0, 0, 0, 1 }), Size = Vector3.new(0.59, 1.23, 1.028) },
	LeftStump = { Name = "left.shoulder", Pos = Vector3.new(-0.714, 0.417, 0.002), Rot = rot({ -1, 0, 0, 0, 1, 0, 0, 0, -1 }), Size = Vector3.new(0.59, 1.23, 1.028) },
	NeckStump = { Name = "neck", Pos = Vector3.new(0.023, 0.754, 0.002), Rot = rot({ 0, 1, 0, 1, 0, 0, 0, 0, -1 }), Size = Vector3.new(0.555, 1.553, 1.023) },
	SkullBase = { Name = "head", Pos = Vector3.new(0.017, 1.176, 0.003), Rot = rot({ 1, 0, 0, 0, 1, 0, 0, 0, 1 }), Size = Vector3.new(1.153, 0.583, 1.14) },
	-- (in the arm's own frame: the torn top end of a severed arm)
	RightEnd = { Name = "right.arm", Pos = Vector3.new(0.029, 0.215, 0.041), Rot = rot({ -1, 0, 0, 0, 1, 0, 0, 0, -1 }), Size = Vector3.new(1.021, 1.626, 1.06) },
	LeftEnd = { Name = "left.arm", Pos = Vector3.new(-0.004, 0.214, 0.007), Rot = rot({ 1, 0, 0, 0, 1, 0, 0, 0, 1 }), Size = Vector3.new(1.021, 1.626, 1.06) },
	Chunk = { Name = "debry", Size = Vector3.new(1.041, 0.96, 1.06) },
}
Gore.Kit = KIT

-- the standard R6 sizes the kit was measured against
local STD = { Torso = Vector3.new(2, 2, 1), Arm = Vector3.new(1, 2, 1), Head = Vector3.new(2, 1, 1) }

local FLESH = Color3.fromRGB(120, 12, 14)
local BONE = Color3.fromRGB(232, 226, 210)
local BLOOD = Config.Blood.Color

---------------------------------------------------------------------------
-- templates (ReplicatedStorage.Combat.Gore: the gore kit)
---------------------------------------------------------------------------
local function templates(): Instance?
	local g = CombatFolder:FindFirstChild("Gore")
	return if g then g:FindFirstChild("GoreKit") else nil
end

-- a part the size (and colour) the kit piece should have on this body: the kit's own piece if the
-- place has it, else a block of flesh the same size
local function kitPiece(name: string, size: Vector3, color: Color3?): BasePart
	local kit = templates()
	local tpl = kit and kit:FindFirstChild(name)
	local p: BasePart
	if tpl and tpl:IsA("BasePart") then
		p = tpl:Clone() :: BasePart
	else
		p = Instance.new("Part")
		p.Name = name
		p.Color = color or FLESH
		p.Material = Enum.Material.Sand
	end
	for _, d in ipairs(p:GetChildren()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
	p.Size = size
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Transparency = 0
	return p
end

-- `size` (in the piece's own axes, rotated by `r` in a frame scaled by `k` per axis)
local function scaled(size: Vector3, r: CFrame, k: Vector3): Vector3
	local axes = { r.RightVector, r.UpVector, -r.LookVector }
	local out = {}
	for i, a in ipairs(axes) do
		local ax, ay, az = math.abs(a.X), math.abs(a.Y), math.abs(a.Z)
		local f = if ax >= ay and ax >= az then k.X elseif ay >= az then k.Y else k.Z
		out[i] = ({ size.X, size.Y, size.Z })[i] * f
	end
	return Vector3.new(out[1], out[2], out[3])
end

local function weldTo(part: BasePart, to: BasePart, cf: CFrame)
	part.CFrame = cf
	local w = Instance.new("Weld")
	w.Part0 = to
	w.Part1 = part
	w.C0 = to.CFrame:ToObjectSpace(cf)
	w.C1 = CFrame.identity
	w.Parent = part
end

-- a kit piece fitted onto `host` (torso / arm / head) at its measured place, scaled to the host
local function fit(entry: any, host: BasePart, std: Vector3, color: Color3?): BasePart
	local k = Vector3.new(host.Size.X / std.X, host.Size.Y / std.Y, host.Size.Z / std.Z)
	local part = kitPiece(entry.Name, scaled(entry.Size, entry.Rot, k), color)
	-- (a wound, not the body: a still copy of the fighter - the HUD's portraits - leaves it out)
	part:SetAttribute("OverkillGore", true)
	local pos = Vector3.new(entry.Pos.X * k.X, entry.Pos.Y * k.Y, entry.Pos.Z * k.Z)
	weldTo(part, host, host.CFrame * CFrame.new(pos) * entry.Rot)
	return part
end
Gore.Fit = fit

---------------------------------------------------------------------------
-- holders
---------------------------------------------------------------------------
local folder: Folder? = nil
local function holder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatGore"
	f.Parent = workspace
	folder = f
	return f
end

local function sound(name: string, pos: Vector3)
	FX.Sound(name, pos, 1)
end

-- the body jerks with the wound (the additive spring reel every blow uses)
local function give(char: Model, peak: any, omega: number)
	FX.Give(char, peak, omega, 0.04)
end

local function nseq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in ipairs(points) do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
	end
	return NumberSequence.new(kps)
end

-- a gib / chunk: fades out and is gone after its life
local function expire(inst: Instance, life: number)
	task.delay(life, function()
		if not inst.Parent then
			return
		end
		local parts = if inst:IsA("BasePart") then { inst } else {}
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		for _, p in ipairs(parts) do
			TweenService:Create(p, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		end
		task.delay(1.3, function()
			inst:Destroy()
		end)
	end)
end

-- pulsing arterial bleeding from a stump: a spurt of the place's own blood effect (VFX Blood) in
-- time with a slowing heartbeat, droplets thrown with it, a drip between beats; dies down over `dur`
local function bleed(att: Attachment, dir: () -> Vector3, dur: number, strength: number, body: Instance?)
	local t0 = os.clock()
	task.spawn(function()
		while att.Parent and os.clock() - t0 < dur do
			local k = 1 - (os.clock() - t0) / dur
			local p = att.WorldPosition
			local d = dir()
			Blood.Burst(p, d, "Blood", 0.42 * strength * (0.55 + 0.45 * k), 0.25 + 0.45 * k, body)
			for _ = 1, math.max(1, math.floor(3 * strength * k + 0.5)) do
				local v = (d + Vector3.new((math.random() - 0.5) * 0.4, math.random() * 0.3, (math.random() - 0.5) * 0.4)).Unit * ((6 + math.random() * 6) * strength * (0.4 + 0.6 * k))
				Blood.Launch(p, v, 0.1 + math.random() * 0.06)
			end
			-- the heart slows as it empties; the wound drips between beats
			local gap = 0.55 + (1 - k) * 0.45
			task.delay(gap * 0.5, function()
				if att.Parent then
					Blood.Launch(att.WorldPosition, Vector3.new(0, -1, 0), 0.07 + math.random() * 0.03)
				end
			end)
			task.wait(gap)
		end
	end)
end

---------------------------------------------------------------------------
-- the NPCs
---------------------------------------------------------------------------
type Body = {
	Model: Model, Hum: Humanoid, Torso: BasePart, Head: BasePart, Right: BasePart?, Left: BasePart?,
	Stage: number, Target: number, Gen: number, Busy: boolean, Hidden: { Instance }, Added: { Instance },
	Drive: Vector3, Conns: { RBXScriptConnection },
}
local bodies: { [Model]: Body } = {}
Gore.Bodies = bodies

-- an R6 body this covers: a model with a Humanoid and the R6 body parts (a player's character too,
-- unless Config.Gore.Players is off)
function Gore.Covers(model: Instance?): boolean
	if not (model and model:IsA("Model")) then
		return false
	end
	if not GC.Players and Players:GetPlayerFromCharacter(model) then
		return false
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	if hum.RigType ~= Enum.HumanoidRigType.R6 then
		return false
	end
	for _, n in ipairs({ "Torso", "Head", "Right Arm", "Left Arm" }) do
		local p = model:FindFirstChild(n)
		if not (p and p:IsA("BasePart")) then
			return false
		end
	end
	return true
end

-- an R6 NPC (a body not a player's)
function Gore.IsNpc(model: Instance?): boolean
	return Gore.Covers(model) and not Players:GetPlayerFromCharacter(model :: Model)
end

local function hide(b: Body, inst: Instance)
	if inst:IsA("BasePart") or inst:IsA("Decal") then
		(inst :: any).LocalTransparencyModifier = 1
		table.insert(b.Hidden, inst)
	end
end

-- everything hanging on a body part (clothing layers are the body part itself; accessories hang by
-- a weld to it, or - rigid accessories - by a constraint between an attachment on each)
local function heldBy(j: Instance, part: BasePart): boolean
	if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
		return (j :: any).Part0 == part or (j :: any).Part1 == part
	elseif j:IsA("Constraint") then
		local a0, a1 = (j :: any).Attachment0, (j :: any).Attachment1
		return (a0 ~= nil and a0.Parent == part) or (a1 ~= nil and a1.Parent == part)
	end
	return false
end
local function accessoriesOn(model: Model, part: BasePart): { BasePart }
	local out = {}
	for _, acc in ipairs(model:GetChildren()) do
		if acc:IsA("Accessory") then
			local handle = acc:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				for _, j in ipairs(handle:GetDescendants()) do
					if heldBy(j, part) then
						table.insert(out, handle)
						break
					end
				end
			end
		end
	end
	return out
end

-- a copy of an instance even when it is marked not to be copied (Archivable off)
local function copyOf<T>(inst: T & Instance): T
	local was = inst.Archivable
	inst.Archivable = true
	local c = inst:Clone()
	inst.Archivable = was
	return c :: any
end

---------------------------------------------------------------------------
-- the stages
---------------------------------------------------------------------------
local function tearArm(b: Body, side: string, quiet: boolean?)
	local arm = if side == "Right" then b.Right else b.Left
	if not (arm and arm.Parent) then
		return
	end
	local torso = b.Torso
	local drive = b.Drive
	local right = torso.CFrame.RightVector
	local out = if side == "Right" then right else -right
	if quiet then
		-- (lost before this client saw the body: the wound, nothing replayed)
		hide(b, arm)
		for _, h in ipairs(accessoriesOn(b.Model, arm)) do
			hide(b, h)
		end
		local stump = fit(if side == "Right" then KIT.RightStump else KIT.LeftStump, torso, STD.Torso)
		stump.Parent = b.Model
		table.insert(b.Added, stump)
		return
	end
	-- the torn-off arm: a copy of it (with its sleeve), thrown with the blow
	local gib = Instance.new("Model")
	gib.Name = "GoreArm"
	local gh = Instance.new("Humanoid") -- (so the NPC's shirt dresses the copy like the real arm)
	gh.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	gh.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	gh.RequiresNeck = false
	gh.BreakJointsOnDeath = false
	gh.EvaluateStateMachine = false
	gh.Parent = gib
	local shirt = b.Model:FindFirstChildOfClass("Shirt")
	if shirt then
		copyOf(shirt).Parent = gib
	end
	local copy = copyOf(arm)
	-- (no joint or constraint comes along: a ragdoll's socket would tie the copy to the live torso)
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
	copy.LocalTransparencyModifier = 0
	copy.Transparency = 0 -- (the server may already have hidden the real one)
	copy.Anchored = false
	copy.CanCollide = true
	copy.CanQuery = false
	copy.CanTouch = false
	copy.Massless = false
	copy.CollisionGroup = "Debris"
	copy.CFrame = arm.CFrame
	copy.Parent = gib
	-- its torn top end
	local wound = fit(if side == "Right" then KIT.RightEnd else KIT.LeftEnd, copy, STD.Arm)
	wound.CollisionGroup = "Debris"
	wound.Parent = gib
	gib.PrimaryPart = copy
	gib.Parent = holder()
	hide(b, arm)
	for _, h in ipairs(accessoriesOn(b.Model, arm)) do
		hide(b, h)
	end
	-- thrown: out from the shoulder and along the blow, up, tumbling. A blow that drives the arm into
	-- the body shears it off instead: what it can't push through the torso pops it up and out
	local into = math.min(0, drive:Dot(out))
	local along = drive - out * into
	local v = along * 13 + out * (7 + into * 4) + Vector3.new(0, 15 - into * 5, 0)
	copy.AssemblyLinearVelocity = v
	copy.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit * 14
	-- the torn end trails blood and sheds drops as it flies
	local tail = Instance.new("Attachment")
	tail.Position = Vector3.new(0, copy.Size.Y * 0.5, 0)
	tail.Parent = copy
	local tail2 = Instance.new("Attachment")
	tail2.Position = Vector3.new(0, copy.Size.Y * 0.32, 0)
	tail2.Parent = copy
	local trail = Instance.new("Trail")
	trail.Attachment0 = tail
	trail.Attachment1 = tail2
	trail.Color = ColorSequence.new(BLOOD, Config.Blood.Dry)
	trail.Transparency = nseq({ { 0, 0.1 }, { 1, 1 } })
	trail.Lifetime = 0.3
	trail.FaceCamera = true
	trail.WidthScale = nseq({ { 0, 1 }, { 1, 0.3 } })
	trail.Parent = copy
	task.delay(0.9, function()
		trail.Enabled = false
	end)
	bleed(tail, function()
		return copy.CFrame.UpVector
	end, 1.2, 0.55, gib)
	expire(gib, GC.GibLife)
	-- the stump on the shoulder, pumping blood
	local stump = fit(if side == "Right" then KIT.RightStump else KIT.LeftStump, torso, STD.Torso)
	stump.Parent = b.Model
	table.insert(b.Added, stump)
	local a = Instance.new("Attachment")
	a.Name = "GoreBleed"
	a.CFrame = CFrame.lookAt(Vector3.zero, if side == "Right" then Vector3.new(1, 0.4, 0) else Vector3.new(-1, 0.4, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
	a.Parent = stump
	bleed(a, function()
		return (out + Vector3.new(0, 0.5, 0)).Unit
	end, GC.BleedTime, 1, b.Model)
	-- the burst of the tear itself
	Blood.Spray(arm.Position + Vector3.new(0, arm.Size.Y * 0.4, 0), drive, "Finisher", b.Model, if side == "Right" then 1 else -1)
	sound("GoreTear", arm.Position)
	give(b.Model, { Roll = if side == "Right" then -14 else 14, Yaw = if side == "Right" then 10 else -10, NeckYaw = if side == "Right" then -18 else 18 }, 12)
end

local function burstHead(b: Body, quiet: boolean?)
	local head = b.Head
	local torso = b.Torso
	local s = head.Size.Y / STD.Head.Y
	local at = head.Position
	-- the head, its face and everything worn on it: gone
	hide(b, head)
	for _, d in ipairs(head:GetChildren()) do
		if d:IsA("Decal") then
			hide(b, d)
		end
	end
	for _, h in ipairs(accessoriesOn(b.Model, head)) do
		hide(b, h)
	end
	-- what is left: the neck's torn stump and the base of the skull
	local neck = fit(KIT.NeckStump, torso, STD.Torso)
	neck.Parent = b.Model
	table.insert(b.Added, neck)
	local skull = fit(KIT.SkullBase, torso, STD.Torso, BONE)
	skull.Parent = b.Model
	table.insert(b.Added, skull)
	if quiet then
		return -- (burst before this client saw the body: what is left, nothing replayed)
	end
	-- THE MIST: the place's own blood effects (VFX BloodHeavy, Blood) burst big: a thick red cloud
	-- blown up and out with the blow, a second one driven along it, the splash inside them
	local up = (Vector3.new(0, 1, 0) + b.Drive * 0.6).Unit
	Blood.Burst(at, up, "BloodHeavy", 1.9 * s, 1.8, b.Model)
	Blood.Burst(at, (b.Drive + Vector3.new(0, 0.35, 0)).Unit, "BloodHeavy", 1.5 * s, 1.2, b.Model)
	Blood.Burst(at, up, "Blood", 1.6 * s, 1.5, b.Model)
	-- droplets all round, thrown mostly with the blow and up
	for _ = 1, GC.BurstDrops do
		local dir = Blood.Cone((Vector3.new(0, 0.9, 0) + b.Drive * 0.7).Unit, 95)
		Blood.Launch(at + dir * 0.4 * s, dir * (10 + math.random() * 20) + b.Drive * 5, 0.1 + math.random() * 0.1)
	end
	-- chunks of flesh and bits of skull on real arcs
	for i = 1, GC.BurstChunks do
		local bone = i % 3 == 0
		local size = (0.18 + math.random() * 0.3) * s
		local c: BasePart
		if not bone then
			c = kitPiece(KIT.Chunk.Name, KIT.Chunk.Size * (size / 1.0), FLESH)
		else
			c = Instance.new("Part")
			c.Color = BONE
			c.Material = Enum.Material.SmoothPlastic
			c.Size = Vector3.new(size, size * 0.4, size * 0.8)
		end
		c.Name = if bone then "GoreBone" else "GoreChunk"
		c.Massless = false
		c.CanCollide = true
		c.CollisionGroup = "Debris"
		local dir = Blood.Cone((Vector3.new(0, 1, 0) + b.Drive * 0.8).Unit, 80)
		c.CFrame = CFrame.new(at + dir * 0.3 * s) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		c.Parent = holder()
		c.AssemblyLinearVelocity = dir * (14 + math.random() * 18) + b.Drive * 6
		c.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 30
		if not bone and i <= 4 then
			local a0 = Instance.new("Attachment")
			a0.Parent = c
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, size * 0.4, 0)
			a1.Parent = c
			local tr = Instance.new("Trail")
			tr.Attachment0 = a0
			tr.Attachment1 = a1
			tr.Color = ColorSequence.new(BLOOD)
			tr.Lifetime = 0.25
			tr.FaceCamera = true
			tr.Parent = c
			task.delay(0.6, function()
				tr.Enabled = false
			end)
		end
		expire(c, GC.GibLife)
	end
	-- the fountain from the neck, dying down
	local a = Instance.new("Attachment")
	a.Name = "GoreBleed"
	a:SetAttribute("OverkillGore", true)
	a.CFrame = CFrame.new(0, torso.Size.Y * 0.5, 0)
	a.Parent = torso
	table.insert(b.Added, a)
	bleed(a, function()
		return torso.CFrame.UpVector
	end, GC.BleedTime, 1.3, b.Model)
	sound("GoreBurst", at)
	-- close enough and the camera takes the blast
	local cam = workspace.CurrentCamera
	if cam then
		local d = (cam.CFrame.Position - at).Magnitude
		if d < 26 then
			FX.Camera(nil, "StompNear", cam.CFrame.Position - at, math.clamp(1 - d / 26, 0.2, 0.8))
		end
	end
end

local STAGE_FN: { (Body, boolean?) -> () } = {
	function(b: Body, quiet: boolean?)
		tearArm(b, "Right", quiet)
	end,
	function(b: Body, quiet: boolean?)
		tearArm(b, "Left", quiet)
	end,
	burstHead,
}

-- the stage this much health has earned (0..3; the same rule the server keeps)
Gore.StageFor = Config.GoreStageFor

local restore: (b: Body) -> ()

local function forget(b: Body)
	for _, c in ipairs(b.Conns) do
		c:Disconnect()
	end
	if bodies[b.Model] == b then
		bodies[b.Model] = nil
	end
end

-- (with Config.Gore.Players off: a player's model can reach this client before its
-- Player.Character does - checked again on every blow, never trusted from the first look)
local function isPlayers(b: Body): boolean
	if not GC.Players and Players:GetPlayerFromCharacter(b.Model) then
		if b.Stage > 0 then
			restore(b)
		end
		b.Gen += 1
		forget(b)
		return true
	end
	return false
end

-- play every stage up to `target`, each in turn, a beat apart (never out of order, never twice; a
-- body made whole again part-way through stops the rest). quiet: the body was already like this
-- when this client first saw it - its wounds at once, nothing replayed
local function advance(b: Body, target: number, quiet: boolean?)
	if target <= b.Stage or isPlayers(b) then
		return
	end
	b.Target = math.max(b.Target, math.min(target, #STAGE_FN))
	if quiet then
		while b.Stage < b.Target do
			b.Stage += 1
			local fn = STAGE_FN[b.Stage]
			local ok, err = pcall(function()
				fn(b, true)
			end)
			if not ok then
				warn("[Combat] gore:", err)
			end
		end
		return
	end
	if b.Busy then
		return
	end
	b.Busy = true
	local gen = b.Gen
	task.spawn(function()
		while b.Gen == gen and b.Stage < b.Target and b.Model.Parent and not isPlayers(b) do
			b.Stage += 1
			local fn = STAGE_FN[b.Stage]
			local ok, err = pcall(function()
				fn(b)
			end)
			if not ok then
				warn("[Combat] gore:", err)
			end
			if b.Stage < b.Target then
				task.wait(GC.Stagger)
			end
		end
		if b.Gen == gen then
			b.Busy = false
		end
	end)
end

-- whole again (the server made it whole: its stage went back)
function restore(b: Body)
	for _, inst in ipairs(b.Hidden) do
		if inst.Parent then
			(inst :: any).LocalTransparencyModifier = 0
		end
	end
	table.clear(b.Hidden)
	for _, inst in ipairs(b.Added) do
		inst:Destroy()
	end
	table.clear(b.Added)
	b.Stage = 0
	b.Target = 0
	b.Gen += 1
	b.Busy = false
end

local function track(model: Model)
	if bodies[model] or not Gore.Covers(model) then
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local b: Body = {
		Model = model, Hum = hum, Torso = model:FindFirstChild("Torso") :: BasePart, Head = model:FindFirstChild("Head") :: BasePart,
		Right = model:FindFirstChild("Right Arm") :: BasePart, Left = model:FindFirstChild("Left Arm") :: BasePart,
		Stage = 0, Target = 0, Gen = 0, Busy = false, Hidden = {}, Added = {}, Drive = Vector3.new(0, 0, -1), Conns = {},
	}
	bodies[model] = b
	Blood.Ignore(model)
	-- a fighter in the combat: the server's stage (it never goes back - a limb doesn't grow back
	-- - unless the server makes the body whole again)
	local function serverStage(): number?
		local st = model:GetAttribute("GoreStage")
		return if type(st) == "number" then st else nil
	end
	local st0 = serverStage()
	if GC.Enabled and st0 and st0 > 0 then
		advance(b, st0, true)
	end
	table.insert(b.Conns, model:GetAttributeChangedSignal("GoreStage"):Connect(function()
		-- (a beat later: the server sends the blow itself - its direction - right after the stage)
		task.defer(function()
			local st = serverStage()
			if not GC.Enabled or not st or bodies[model] ~= b then
				return
			end
			if st < b.Stage then
				restore(b)
			end
			advance(b, st)
		end)
	end))
	-- anything else comes apart by its own health (and stays that way)
	table.insert(b.Conns, hum.HealthChanged:Connect(function(h: number)
		if not GC.Enabled or serverStage() ~= nil then
			return
		end
		advance(b, Gore.StageFor(h, hum.MaxHealth))
	end))
	table.insert(b.Conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			forget(b)
		end
	end))
end

-- a blow just landed on `model` and left it `health` (the attacker's own impact frame, or the
-- server's Hit with its `stage`): the stage it earns plays now, on the blow, not a round trip later
function Gore.Hit(model: Instance?, health: number, drive: Vector3?, stage: number?)
	if not GC.Enabled or not (model and model:IsA("Model")) then
		return
	end
	track(model)
	local b = bodies[model]
	if not b then
		return
	end
	if drive and Vector3.new(drive.X, 0, drive.Z).Magnitude > 1e-3 then
		b.Drive = Vector3.new(drive.X, 0, drive.Z).Unit
	end
	advance(b, if type(stage) == "number" then stage else Gore.StageFor(math.max(0, health), b.Hum.MaxHealth))
end

function Gore.StageOf(model: Model): number
	local b = bodies[model]
	return if b then b.Stage else 0
end

local started = false
function Gore.Start()
	if started then
		return
	end
	started = true
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Humanoid") and d.Parent then
			track(d.Parent :: Model)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if d:IsA("Humanoid") then
			task.defer(function()
				if d.Parent then
					track(d.Parent :: Model)
				end
			end)
		end
	end)
end

return Gore
