--[[
	CombatGore  (ReplicatedStorage.Combat.CombatGore)
	Damage you can SEE on a fighter - NPCs and players alike (Config.Gore.Players): as its health
	falls through Config.Gore.Stages its body comes apart, in this order and never out of it -
	  1  the right arm is torn off at the shoulder (Stages[1] of its health left)
	  2  the left arm (Stages[2])
	  3  the killing blow bursts the head in a huge bloody mist (at Stages[3] or under)
	A blow that takes several stages at once plays each of them in turn (a beat apart), in order. A
	lost limb stays lost - NPC or player - until the fighter respawns. It matters: the server keeps the stage (the
	character's GoreStage attribute), hides the lost limb for everyone and makes a one-armed fighter
	easier to hurt and single-handed, an armless one unable to block or strike (CombatService).

	Here, on every client: the stage plays on the blow's own frame (the attacker from its own impact
	frame, everyone else from the server's Hit, which carries the stage), with the torn limb thrown,
	the wounds and the blood. A body that is already missing limbs when this client first sees it
	(joining late, streamed in) just has its wounds, nothing replayed. Fighters outside the combat
	(any other R6 NPC in the place) come apart by their own health the same way. Works for ANY R6
	body: everything is found by the R6 part names and fitted to its own part sizes and clothing.

	What each stage does
	  ARM   the whole arm is ripped off at the shoulder. The real arm is hidden (with everything worn
	        on it) and a copy of it - its colour, its sleeve - is thrown along the way the blow drove,
	        tumbling, the gore kit's torn end on top bleeding as it flies (its blood flies with it and
	        rains off it along the way); it slaps down in a splash of blood, rolls and comes to rest
	        (real physics on this client, colliding with the world, never with a fighter). The shoulder
	        is a raw stump (the kit's shoulder cap): the tear bursts out of it, then two or three
	        weaker gushes, then it pumps with a slowing heartbeat - spurts out of the socket the way
	        the socket faces, short squirts between them, a dribble down the body
	        (Config.Gore.BleedTime), then it oozes (DripTime)
	  HEAD  the head bursts in a thick red cloud blown up and out with the blow; what is left is the
	        neck's torn stump with the base of the skull, and a fountain of blood that gushes, then
	        dies down in pulses
	  (all the blood goes through CombatBlood: the place's own blood effects - the blood packs,
	  ReplicatedStorage.Combat.VFX - its droplets, and the liquid they pool into. A wound bleeds
	  with the body's own motion: a fighter running with a stump streaks blood behind it, a
	  ragdolled one throws it along its fall)
	  (the hole in the torso from the gore kit is never used)
	A body badly hurt (its Wounds, Config.Gore) drips from its wounds as it moves, and a bleeding body
	thrown to the ground lands in a splash of its own blood.
	A torn-off arm is a real body on this client: it thuds down, rolls to a stop and lies there
	Config.Gore.GibRest seconds, then sinks into the ground as it fades (see addGib).

	  Gore.Start()                      watch every body in the workspace (CombatClient calls it)
	  Gore.Hit(body, health, drive, stage?)  a blow just landed and left `health` (drive: the way it
	                                    travels; stage: the server's word): its stage plays on the blow
	  Gore.StageOf(body)                how far that body has come apart (0..3)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
}
Gore.Kit = KIT

-- the standard R6 sizes the kit was measured against
local STD = { Torso = Vector3.new(2, 2, 1), Arm = Vector3.new(1, 2, 1), Head = Vector3.new(2, 1, 1) }

local CORPSE_FADE = 0.8 -- seconds a dead body takes to fade out before it is removed
local FLESH = Color3.fromRGB(120, 12, 14)
local BONE = Color3.fromRGB(232, 226, 210)

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

-- the body jerks with the wound (the additive spring reel every blow uses)
local function give(char: Model, peak: any, omega: number)
	FX.Give(char, peak, omega, 0.04)
end

---------------------------------------------------------------------------
-- the pieces thrown off (a torn-off arm): real bodies on this client. Each is watched in one shared step: its FIRST touchdown thuds (an arm splashes a little
-- blood where it lands), it rolls to a stop, and once it has lain still it is pinned there (no
-- physics jitter, nothing to simulate) for Config.Gore.GibRest seconds - then it sinks into the
-- ground as it fades out, and is gone. A piece that never settles goes after GibLife; past MaxGibs
-- the oldest one sinks early.
---------------------------------------------------------------------------
type Gib = {
	Inst: Instance, Part: BasePart, Born: number, LastV: Vector3, Landed: boolean, LastThud: number,
	StillSince: number?, RestAt: number?, Going: boolean,
}
local gibs: { Gib } = {}
local gibConn: RBXScriptConnection? = nil

local function gibParts(inst: Instance): { BasePart }
	local parts = if inst:IsA("BasePart") then { inst } else {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

-- down into the ground and out: the piece is pinned, then slides its own depth under the floor while
-- it fades (quick: it was pushed out by a newer one)
local function sinkGib(g: Gib, quick: boolean?)
	if g.Going then
		return
	end
	g.Going = true
	local p = g.Part
	local inst = g.Inst
	if not (p.Parent and inst.Parent) then
		inst:Destroy()
		return
	end
	local time = if quick then 0.45 else GC.GibSink
	p.AssemblyLinearVelocity = Vector3.zero
	p.AssemblyAngularVelocity = Vector3.zero
	p.Anchored = true
	local depth = math.min(p.Size.X, p.Size.Y, p.Size.Z) * 0.5 + 0.35
	TweenService:Create(p, TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
		CFrame = p.CFrame - Vector3.new(0, depth, 0),
	}):Play()
	for _, part in ipairs(gibParts(inst)) do
		TweenService:Create(part, TweenInfo.new(time * 0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, time * 0.15), {
			Transparency = 1,
		}):Play()
	end
	task.delay(time + 0.05, function()
		inst:Destroy()
	end)
end

local function gibStep()
	local now = os.clock()
	local live = 0
	for i = #gibs, 1, -1 do
		local g = gibs[i]
		local p = g.Part
		if g.Going or not (p.Parent and g.Inst.Parent) then
			table.remove(gibs, i)
			if not g.Going then
				g.Inst:Destroy()
			end
			continue
		end
		live += 1
		local age = now - g.Born
		if p.Position.Y < workspace.FallenPartsDestroyHeight + 30 then
			g.Inst:Destroy() -- (off the edge of the world)
			table.remove(gibs, i)
			continue
		end
		if not g.RestAt then
			local v = p.AssemblyLinearVelocity
			-- a touchdown: a fall stopped short (the speed down gone in one step)
			if g.LastV.Y < -12 and v.Y - g.LastV.Y > 10 and now - g.LastThud > 0.25 then
				g.LastThud = now
				local hard = math.clamp(-g.LastV.Y / 40, 0.35, 1)
				if not g.Landed then
					g.Landed = true
					-- (the torn end slaps down wet: a splash of blood on the floor where it lands)
					Blood.Splash(p.Position - Vector3.new(0, p.Size.Y * 0.25, 0), 0.5 + 0.6 * hard)
				elseif hard > 0.5 then
					Blood.Splash(p.Position, 0.3 * hard)
				end
			end
			g.LastV = v
			local still = v.Magnitude < 0.7 and p.AssemblyAngularVelocity.Magnitude < 1.5
			if still then
				g.StillSince = g.StillSince or now
				if now - g.StillSince > 0.35 then
					-- at rest: pinned where it lies (nothing left to simulate, no creeping on a slope)
					g.RestAt = now
					p.AssemblyLinearVelocity = Vector3.zero
					p.AssemblyAngularVelocity = Vector3.zero
					p.Anchored = true
				end
			else
				g.StillSince = nil
			end
		end
		if (g.RestAt and now - g.RestAt >= GC.GibRest) or age >= GC.GibLife then
			sinkGib(g)
		end
	end
	-- too many lying about: the oldest go first
	local over = live - GC.MaxGibs
	for _, g in ipairs(gibs) do
		if over <= 0 then
			break
		end
		if not g.Going then
			sinkGib(g, true)
			over -= 1
		end
	end
	if #gibs == 0 and gibConn then
		gibConn:Disconnect()
		gibConn = nil
	end
end

-- dead flesh: heavy, grippy, no rubber bounce (Config.Gore.Flesh)
local function flesh(p: BasePart)
	local f = GC.Flesh
	p.CustomPhysicalProperties = PhysicalProperties.new(
		f.Density,
		f.Friction,
		f.Elasticity,
		1,
		100 -- (the floor's own bounce never wins over the flesh's)
	)
end

-- a piece thrown off: watched until it has lain still its while, then sunk away
local function addGib(inst: Instance, part: BasePart)
	table.insert(gibs, {
		Inst = inst, Part = part, Born = os.clock(), LastV = part.AssemblyLinearVelocity, Landed = false, LastThud = -1,
		StillSince = nil, RestAt = nil, Going = false,
	})
	if not gibConn then
		gibConn = RunService.Heartbeat:Connect(gibStep)
	end
end

-- a wound that bleeds on its own (CombatBlood.Wound): its gushes, its heartbeat and its ooze
local function bleed(att: Attachment, dir: () -> Vector3, pump: number, strength: number, body: Instance?, ooze: number?, delay: number?, gushes: number?): any
	return Blood.Wound(att, { Dir = dir, Pump = pump, Strength = strength, Body = body, Ooze = ooze or 0, Delay = delay or 0, Gushes = gushes or 0 })
end

---------------------------------------------------------------------------
-- the NPCs
---------------------------------------------------------------------------
type Body = {
	Model: Model, Hum: Humanoid, Torso: BasePart, Head: BasePart, Right: BasePart?, Left: BasePart?,
	Stage: number, Target: number, Gen: number, Busy: boolean, Hidden: { Instance }, Added: { Instance }, DripAcc: number?,
	Marks: { [number]: { H: number, A: number } }, -- where each stage's hidden / added things start
	Drive: Vector3, Conns: { RBXScriptConnection },
}
local bodies: { [Model]: Body } = {}

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
-- (worn by where it attaches: an accessory's handle carries an attachment named like the body
-- part's own - HairAttachment, HatAttachment, FaceFrontAttachment... on the head - so it counts even
-- once its weld is gone, as a dying body's joints break)
local function wornOn(handle: BasePart, part: BasePart): boolean
	for _, a in ipairs(handle:GetChildren()) do
		if a:IsA("Attachment") then
			local mine = part:FindFirstChild(a.Name)
			if mine and mine:IsA("Attachment") then
				return true
			end
		end
	end
	return false
end
local BODY_PART = { Head = true, Torso = true, HumanoidRootPart = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true }
local function accessoriesOn(model: Model, part: BasePart): { BasePart }
	local out = {}
	for _, acc in ipairs(model:GetChildren()) do
		-- (a hero's own hair / collar is a loose part of the character welded to it - HeroServer -
		-- not an Accessory: it goes with the part it is worn on too)
		if acc:IsA("BasePart") and not BODY_PART[acc.Name] and acc:GetAttribute("OverkillGore") == nil then
			local held = false
			for _, j in ipairs(acc:GetDescendants()) do
				if heldBy(j, part) then
					held = true
					break
				end
			end
			if held then
				table.insert(out, acc)
			end
		elseif acc:IsA("Accessory") then
			local handle = acc:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				local held = wornOn(handle, part)
				if not held then
					for _, j in ipairs(handle:GetDescendants()) do
						if heldBy(j, part) then
							held = true
							break
						end
					end
				end
				if held then
					table.insert(out, handle)
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
-- a copy of a limb that wears the body's own clothes: a model with a Humanoid and the body's Shirt
-- round the copy (named like the limb, so the sleeve dresses it), with no joint of its own
local function dressedCopy(b: Body, limb: BasePart, name: string): (Model, BasePart)
	local m = Instance.new("Model")
	m.Name = name
	m:SetAttribute("OverkillGore", true)
	local gh = Instance.new("Humanoid")
	gh.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	gh.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	gh.RequiresNeck = false
	gh.BreakJointsOnDeath = false
	gh.EvaluateStateMachine = false
	gh.Parent = m
	local shirt = b.Model:FindFirstChildOfClass("Shirt")
	if shirt then
		copyOf(shirt).Parent = m
	end
	local copy = copyOf(limb)
	-- (no joint or constraint comes along: a ragdoll's socket would tie the copy to the live torso)
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
	copy.LocalTransparencyModifier = 0
	copy.Transparency = 0 -- (the server may already have hidden the real one)
	copy.Anchored = false
	copy.CanQuery = false
	copy.CanTouch = false
	copy:SetAttribute("OverkillGore", true)
	copy.Parent = m
	m.PrimaryPart = copy
	return m, copy
end

-- the shoulder a torn-off arm leaves: the gore kit's raw stump on the torso (inside the body, so
-- it goes and comes with it - first person hides it with the rest of you), and the attachment the
-- blood pumps from: on the stump's open face, pointing out of the shoulder and a little up (worked
-- out in the torso's own space: the kit's left cap is the right one turned round)
local function shoulderStump(b: Body, side: string): (BasePart, Attachment)
	local stump = fit(if side == "Right" then KIT.RightStump else KIT.LeftStump, b.Torso, STD.Torso)
	stump.Parent = b.Model
	local torso = b.Torso.CFrame
	local out = stump.CFrame:VectorToObjectSpace(if side == "Right" then torso.RightVector else -torso.RightVector)
	local up = stump.CFrame:VectorToObjectSpace(torso.UpVector)
	local face = math.abs(out.X) * stump.Size.X * 0.5 + math.abs(out.Y) * stump.Size.Y * 0.5 + math.abs(out.Z) * stump.Size.Z * 0.5
	local a = Instance.new("Attachment")
	a.Name = "GoreBleed"
	a.CFrame = CFrame.lookAt(out * face, out * face + (out + up * 0.4).Unit) * CFrame.Angles(-math.pi / 2, 0, 0)
	a.Parent = stump
	return stump, a
end

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
		local stump, att = shoulderStump(b, side)
		table.insert(b.Added, stump)
		bleed(att, function()
			return att.WorldCFrame.UpVector
		end, 0, 0.8, b.Model, GC.DripTime)
		return
	end
	-- the whole arm, ripped off at the shoulder: a copy of it (with its sleeve), thrown with the blow
	local gib, copy = dressedCopy(b, arm, "GoreArm")
	copy.CanCollide = true
	copy.Massless = false
	copy.CollisionGroup = "Debris"
	flesh(copy)
	copy.CFrame = arm.CFrame
	Blood.Carry(arm, copy) -- (the blood on the arm goes with it)
	-- its torn top end
	local wound = fit(if side == "Right" then KIT.RightEnd else KIT.LeftEnd, copy, STD.Arm)
	wound.CollisionGroup = "Debris"
	wound.Parent = gib
	gib.Parent = holder()
	hide(b, arm)
	for _, h in ipairs(accessoriesOn(b.Model, arm)) do
		hide(b, h)
	end
	-- thrown: out from the shoulder and along the blow, up, tumbling end over end about the axis
	-- across its flight (a thrown limb turns like a thrown club, not a random spin). A blow that drives
	-- the arm into the body shears it off instead: what it can't push through the torso pops it up and out
	local into = math.min(0, drive:Dot(out))
	local along = drive - out * into
	-- (and it carries the body's own motion: a fighter knocked back or running loses the arm on the move)
	local bodyV = b.Torso.AssemblyLinearVelocity
	local v = along * 13 + out * (7 + into * 4) + Vector3.new(0, 15 - into * 5, 0) + Vector3.new(bodyV.X, math.max(bodyV.Y, 0), bodyV.Z) * 0.6
	copy.AssemblyLinearVelocity = v
	local flatV = Vector3.new(v.X, 0, v.Z)
	local tumble = if flatV.Magnitude > 0.5 then flatV.Unit:Cross(Vector3.yAxis) else torso.CFrame.LookVector
	local wobble = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 3
	copy.AssemblyAngularVelocity = tumble * -(9 + math.random() * 6) + wobble
	-- the torn end bleeds and sheds drops as it flies, then oozes onto the floor where it lies
	local tail = Instance.new("Attachment")
	tail.Position = Vector3.new(0, copy.Size.Y * 0.5, 0)
	tail.Parent = copy
	bleed(tail, function()
		return copy.CFrame.UpVector
	end, 1.6, 0.6, gib, 6, 0.06, 1)
	addGib(gib, copy)
	-- the stump on the shoulder: the raw socket, where it all comes out
	local stump, a = shoulderStump(b, side)
	table.insert(b.Added, stump)
	local socket = a.WorldPosition
	local outUp = (out + Vector3.new(0, 0.5, 0)).Unit
	-- THE TEAR, on the blow: the socket bursts (a thick spray thrown out of it and after the arm),
	-- a stream of blood strung out behind the departing limb, then a second gush a beat later as the
	-- artery empties - and then the heart takes over (the pulses below)
	Blood.Spray(socket, (drive + out * 0.8).Unit, "Tear", b.Model, if side == "Right" then 1 else -1)
	-- the torso round the socket, soaked, and running down its side, front and back
	local tc, th = torso.CFrame, torso.Size * 0.5
	local sx = if side == "Right" then 1 else -1
	Blood.Stain(torso, tc:PointToWorldSpace(Vector3.new(sx * (th.X + 0.1), th.Y * 0.7, 0)), 0.55, 1)
	Blood.Stain(torso, tc:PointToWorldSpace(Vector3.new(sx * th.X * 0.7, th.Y * 0.75, -th.Z - 0.1)), 0.35, 1)
	Blood.Stain(torso, tc:PointToWorldSpace(Vector3.new(sx * th.X * 0.7, th.Y * 0.75, th.Z + 0.1)), 0.3, 0.8)
	Blood.Effect("BloodGush", socket, outUp, { Parent = b.Torso, Inherit = 0.85, Scale = 0.8 + math.random() * 0.25, Count = 0.8 })
	local vUnit = if v.Magnitude > 0.1 then v.Unit else outUp
	local n = 10 + math.random(0, 5)
	for i = 1, n do
		-- (the string of it trailing the limb: the first drops nearly keep up, the last fall away)
		local share = 0.85 - (i / n) * 0.55
		local dir = Blood.Cone(vUnit, 10 + i)
		Blood.Launch(socket + dir * 0.2, dir * v.Magnitude * share + Vector3.new(0, -2 * i / n, 0), 0.08 + math.random() * 0.09, if i <= 3 then "Blob" else "Drop")
	end
	-- the socket: two or three weaker gushes as the artery empties, then the heartbeat - out of the
	-- socket the way it faces (the body turning, falling or flung turns the jet with it)
	bleed(a, function()
		return a.WorldCFrame.UpVector
	end, GC.BleedTime, 1.25, b.Model, GC.DripTime, 0.42, math.random(2, 3))
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
	-- THE BURST: the place's own blood effects blown up and out with the blow - the blood explosion
	-- (VFX BloodBurst) and the wound's spray, a heavy spray driven along the blow, drops everywhere
	local up = (Vector3.new(0, 1, 0) + b.Drive * 0.6).Unit
	Blood.Spray(at, b.Drive, "Head", b.Model, 0, { Damage = 5 * s })
	Blood.Effect("BloodHeavy", at, (b.Drive + Vector3.new(0, 0.35, 0)).Unit, { Scale = 1.4 * s, Count = 1.1, Speed = 1.1 })
	Blood.Effect("Blood", at, up, { Scale = 1.5 * s, Count = 1.3 })
	-- the fountain from the neck, dying down
	local a = Instance.new("Attachment")
	a.Name = "GoreBleed"
	a:SetAttribute("OverkillGore", true)
	a.CFrame = CFrame.new(0, torso.Size.Y * 0.5, 0)
	a.Parent = torso
	table.insert(b.Added, a)
	bleed(a, function()
		return torso.CFrame.UpVector
	end, GC.BleedTime, 1.35, b.Model, GC.DripTime * 0.5, 0.3, 3)
	-- the chest and the back under the neck, soaked and running
	local tc, th = torso.CFrame, torso.Size * 0.5
	for _, z in ipairs({ -1, -1, 1 }) do
		Blood.Stain(torso, tc:PointToWorldSpace(Vector3.new((math.random() - 0.5) * th.X, th.Y * 0.8, z * (th.Z + 0.1))), 0.3 + math.random() * 0.25, 1)
	end
	-- close enough and the camera takes the blast
	local cam = workspace.CurrentCamera
	if cam then
		local d = (cam.CFrame.Position - at).Magnitude
		if d < 26 then
			FX.Camera(nil, "StompNear", cam.CFrame.Position - at, math.clamp(1 - d / 26, 0.2, 0.8))
		end
	end
end

local bleeding: (b: Body) -> number

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

-- how badly a body is bleeding (0: not at all .. ~1.5): a limb gone, or its wounds past DripFrom
-- (the server's Wounds - the health it has lost, added up - or, for any other body, its health)
function bleeding(b: Body): number
	local w = b.Model:GetAttribute("Wounds")
	local wounds = if type(w) == "number" then w else 1 - math.clamp(b.Hum.Health / math.max(b.Hum.MaxHealth, 1), 0, 1)
	local k = math.clamp((wounds - GC.DripFrom) / (1 - GC.DripFrom), 0, 1)
	return k + (if b.Stage > 0 then 0.5 else 0)
end

-- A BADLY HURT BODY DRIPS. Past Config.Gore.DripFrom of its health lost, a drop now and then falls from
-- where it has been hit (low on the torso), faster the worse it is and carried with the body - a
-- trail of drips behind a fighter that runs, a pool growing under one that stands (DripRate: drops a
-- second at the worst). Healed back under the line (the regen reserve), it stops.
local dripConn: RBXScriptConnection? = nil
local lastDrip = 0
local function dripStep()
	local now = os.clock()
	if now - lastDrip < 0.1 then
		return
	end
	local dt = math.min(now - lastDrip, 0.3)
	lastDrip = now
	local cam = workspace.CurrentCamera
	for model, b in pairs(bodies) do
		local torso = b.Torso
		if b.Hum.Health > 0 and torso.Parent and model.Parent and (not cam or (cam.CFrame.Position - torso.Position).Magnitude < 90) then
			local w = model:GetAttribute("Wounds")
			local wounds = if type(w) == "number" then w else 1 - math.clamp(b.Hum.Health / math.max(b.Hum.MaxHealth, 1), 0, 1)
			local k = math.clamp((wounds - GC.DripFrom) / (1 - GC.DripFrom), 0, 1)
			if k > 0 then
				b.DripAcc = (b.DripAcc or math.random()) + dt * GC.DripRate * k * (0.6 + 0.8 * math.random())
				while b.DripAcc >= 1 do
					b.DripAcc -= 1
					local cf = torso.CFrame
					local half = torso.Size * 0.5
					local p = cf:PointToWorldSpace(Vector3.new((math.random() - 0.5) * half.X * 1.6, -half.Y * (0.2 + 0.7 * math.random()), (math.random() - 0.5) * half.Z * 1.6))
					local v = torso.AssemblyLinearVelocity
					if v.Magnitude > 60 then
						v = v.Unit * 60
					end
					Blood.Launch(p, v * 0.85 + Vector3.new((math.random() - 0.5) * 0.6, -0.5, (math.random() - 0.5) * 0.6), 0.05 + math.random() * 0.05, "Drop")
				end
			end
		end
	end
end

local restore: (b: Body) -> ()

local function forget(b: Body)
	for _, c in ipairs(b.Conns) do
		c:Disconnect()
	end
	-- (anything it added that lives outside the body, in the gore folder, goes with it)
	for _, inst in ipairs(b.Added) do
		if inst.Parent and inst.Parent == folder then
			inst:Destroy()
		end
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
local function advance(b: Body, target: number, quiet: boolean?, after: number?)
	if target <= b.Stage or isPlayers(b) then
		return
	end
	b.Target = math.max(b.Target, math.min(target, #STAGE_FN))
	if quiet then
		while b.Stage < b.Target do
			b.Stage += 1
			b.Marks[b.Stage] = { H = #b.Hidden, A = #b.Added }
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
		-- (the blow lands, the hit-stop holds it - and the limb goes as the freeze lets go: the tear
		-- reads as what the blow did, not as something that happened with it)
		if after and after > 0 then
			task.wait(after)
		end
		while b.Gen == gen and b.Stage < b.Target and b.Model.Parent and not isPlayers(b) do
			b.Stage += 1
			b.Marks[b.Stage] = { H = #b.Hidden, A = #b.Added }
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
	table.clear(b.Marks)
	b.Stage = 0
	b.Target = 0
	b.Gen += 1
	b.Busy = false
end

-- a stage this screen played ahead of the server that the server never gave (a blow it predicted
-- landing that the server judged otherwise): undone, quietly - the limb and what it wears shown
-- again, its stump gone. Newest stage first. (A limb the server took never comes back.)
local function rollback(b: Body, target: number)
	b.Gen += 1 -- (a stage still playing out stops)
	b.Busy = false
	while b.Stage > math.max(target, 0) do
		local m = b.Marks[b.Stage] or { H = 0, A = 0 }
		for i = #b.Hidden, m.H + 1, -1 do
			local inst = b.Hidden[i]
			if inst.Parent then
				(inst :: any).LocalTransparencyModifier = 0
			end
			b.Hidden[i] = nil
		end
		for i = #b.Added, m.A + 1, -1 do
			b.Added[i]:Destroy()
			b.Added[i] = nil
		end
		b.Marks[b.Stage] = nil
		b.Stage -= 1
	end
	b.Target = b.Stage
end
Gore.Rollback = function(model: Model, target: number)
	local b = bodies[model]
	if b and target < b.Stage then
		rollback(b, target)
	end
end

local function track(model: Model)
	if bodies[model] or not Gore.Covers(model) then
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local b: Body = {
		Model = model, Hum = hum, Torso = model:FindFirstChild("Torso") :: BasePart, Head = model:FindFirstChild("Head") :: BasePart,
		Right = model:FindFirstChild("Right Arm") :: BasePart, Left = model:FindFirstChild("Left Arm") :: BasePart,
		Stage = 0, Target = 0, Gen = 0, Busy = false, Hidden = {}, Added = {}, Marks = {}, Drive = Vector3.new(0, 0, -1), Conns = {},
	}
	bodies[model] = b
	Blood.Ignore(model)
	-- a fighter in the combat: the server's stage (it never goes back)
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
				rollback(b, st) -- (this screen ran ahead of the server)
			else
				advance(b, st)
			end
		end)
	end))
	-- anything else comes apart by its own health (and stays that way)
	table.insert(b.Conns, hum.HealthChanged:Connect(function(h: number)
		if not GC.Enabled or serverStage() ~= nil then
			return
		end
		advance(b, Gore.StageFor(h, hum.MaxHealth))
	end))
	-- a body knocked down HITS the ground: dust bursts up where it lands (its first touchdown, and
	-- a smaller puff if it bounces once) - the ragdoll lands with weight instead of just stopping.
	-- A body that is bleeding (a limb gone, or badly hurt) lands in a splash of its own blood
	local watching = false
	table.insert(b.Conns, model:GetAttributeChangedSignal("Ragdolled"):Connect(function()
		if model:GetAttribute("Ragdolled") ~= true or watching then
			return
		end
		watching = true
		local torso = b.Torso
		local lastV = torso.AssemblyLinearVelocity
		local t0 = os.clock()
		local thuds = 0
		local conn: RBXScriptConnection? = nil
		conn = RunService.Heartbeat:Connect(function()
			local v = torso.AssemblyLinearVelocity
			if lastV.Y < -14 and v.Y - lastV.Y > 12 then
				thuds += 1
				local hard = math.clamp(-lastV.Y / 60, 0.45, 0.9)
				FX.GroundDust(torso.Position, if thuds == 1 then hard else 0.35)
				local hurt = bleeding(b)
				if hurt > 0 then
					Blood.Splash(torso.Position, (if thuds == 1 then hard else 0.4) * (0.5 + hurt))
				end
			end
			lastV = v
			if thuds >= 2 or os.clock() - t0 > 2.5 or not torso.Parent then
				watching = false
				if conn then
					conn:Disconnect()
					-- (a body knocked down again and again never piles up dead connections)
					local i = table.find(b.Conns, conn)
					if i then
						table.remove(b.Conns, i)
					end
				end
			end
		end)
		table.insert(b.Conns, conn :: RBXScriptConnection)
	end))
	-- a body that died fades out over its last moment before it is removed (a practice dummy's
	-- DespawnAt, a player's respawn) - it never just blinks out of the world
	local fading = false
	table.insert(b.Conns, hum.Died:Connect(function()
		if fading then
			return
		end
		fading = true
		task.delay(0.2, function()
			if not model.Parent then
				return
			end
			local at = model:GetAttribute("DespawnAt")
			local left: number? = nil
			if type(at) == "number" then
				left = at - workspace:GetServerTimeNow()
			elseif Players:GetPlayerFromCharacter(model) and Players.CharacterAutoLoads then
				left = Players.RespawnTime - 0.2
			end
			if not left or left < 1 then
				return
			end
			task.delay(left - CORPSE_FADE - 0.05, function()
				if not model.Parent then
					return
				end
				local info = TweenInfo.new(CORPSE_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				for _, d in ipairs(model:GetDescendants()) do
					if (d:IsA("BasePart") or d:IsA("Decal")) and (d :: any).LocalTransparencyModifier < 1 then
						TweenService:Create(d, info, { LocalTransparencyModifier = 1 }):Play()
					end
				end
			end)
		end)
	end))
	table.insert(b.Conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			forget(b)
		end
	end))
end

-- a blow just landed on `model` and left it `health` (the attacker's own impact frame, or the
-- server's Hit with its `stage`): the stage it earns plays now, on the blow, not a round trip later
function Gore.Hit(model: Instance?, health: number, drive: Vector3?, stage: number?, after: number?)
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
	advance(b, if type(stage) == "number" then stage else Gore.StageFor(math.max(0, health), b.Hum.MaxHealth), nil, after)
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
	if not dripConn then
		dripConn = RunService.Heartbeat:Connect(dripStep)
	end
end

return Gore
