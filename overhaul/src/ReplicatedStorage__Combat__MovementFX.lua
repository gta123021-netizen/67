--[[
	MovementFX  (ReplicatedStorage.Combat.MovementFX)
	What the movement looks like on EVERY screen - client-side and cosmetic, like CombatFX. The mover's
	own client plays its moves' effects on the frame they happen; everyone else plays the same ones from
	the server's word (the character's Parkour attribute for what a body is doing, CombatEvent "FX"
	Kind = "Parkour" for the moments: a double jump, a leap, a vault, a hard landing).

	The effects are the movement pack's own (copied into ReplicatedStorage.Combat.VFX: SlideSmoke,
	AirJump, AirBurst, AirSmoke, LeapBurst, LandDust, Puff) and the pack's limb trails - and they only ever come
	from limbs the body still has (BodyState): the air smoke of a double jump is at the feet it has, a
	trail is never drawn on an arm that was torn off, and one on a limb lost mid-air goes with it.

	THE BLOOD MOVES WITH THE BODY. Nothing here makes blood of its own - it asks the one blood system
	(CombatBlood) for it:
	  sliding / crawling / wall running   a bleeding body wipes its blood along the floor or the wall
	                                      where its wounds touch it (Blood.Drag -> BloodPools.Streak:
	                                      one streak merged into the pools, never a stamp per frame)
	  a hard landing                      the open wounds jolt (Blood.Jolt) and a bleeding body lands in
	                                      a splash of its own blood, both sized by the impact and by how
	                                      badly it is hurt - an unhurt body just raises dust
	  everything else                     the wounds already bleed with the wound's own motion (the
	                                      stump's velocity frame to frame: CombatBlood), so a vault, a
	                                      climb, a leap throws the blood the way the body really moves

	  MovementFX.Start()                       watch every body (CombatClient calls it once)
	  MovementFX.Event(char, kind, data?)      a moment: "DoubleJump" | "Leap" | "Vault" | "LedgeVault" |
	                                           "SlideCancel" | "WallRun" | "WallJump" | "Land" (data.K: 0..1)
	  MovementFX.SetLocal(char, state)         the local body's own state, straight from Parkour (its
	                                           attribute is the server's echo, a round trip late)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))
local Blood = require(CombatFolder:WaitForChild("CombatBlood"))
local FX = require(CombatFolder:WaitForChild("CombatFX"))
local BodyState = require(CombatFolder:WaitForChild("BodyState"))

local MovementFX = {}

local VIEW = 160 -- studs: nothing is built for a body farther than this from the camera

local function rootOf(char: Model): BasePart?
	local r = char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function inView(p: Vector3): boolean
	local cam = workspace.CurrentCamera
	return cam == nil or (cam.CFrame.Position - p).Magnitude <= VIEW
end

-- where the body's feet are: under the legs it still has (never under a leg that is gone)
local function feetOf(char: Model): Vector3?
	local s = BodyState.Get(char)
	local sum, n = Vector3.zero, 0
	for _, pair in ipairs({ { "Right Leg", s.HasRightLeg }, { "Left Leg", s.HasLeftLeg } }) do
		local leg = char:FindFirstChild(pair[1])
		if pair[2] and leg and leg:IsA("BasePart") then
			sum += leg.CFrame:PointToWorldSpace(Vector3.new(0, -leg.Size.Y * 0.5, 0))
			n += 1
		end
	end
	return if n > 0 then sum / n else nil
end

-- the floor under a point (the effects sit on it)
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true
local function floorUnder(p: Vector3, char: Model): RaycastResult?
	local list: { Instance } = { char }
	for _, name in ipairs({ "CombatBlood", "CombatGore", "CombatFX", "CombatShatter" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	groundParams.FilterDescendantsInstances = list
	return workspace:Raycast(p + Vector3.new(0, 1, 0), Vector3.new(0, -7, 0), groundParams)
end

---------------------------------------------------------------------------
-- the pack's limb trails (a streak off each limb through a leap, a double jump, a wall run) - only
-- on limbs the body has, and gone the frame one is lost
---------------------------------------------------------------------------
local LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }
local TRAIL_TAG = "OverkillMoveTrail"

local function trailTemplate(): Trail?
	local lib = CombatFolder:FindFirstChild("VFX")
	local t = lib and lib:FindFirstChild("LimbTrail")
	return if t and t:IsA("Trail") then t else nil
end

type TrailSet = { Parts: { [string]: { Trail: Trail, A0: Attachment, A1: Attachment } }, Watch: any, Char: Model }
local trailSets: { [Model]: TrailSet } = setmetatable({}, { __mode = "k" }) :: any

local function dropTrail(set: TrailSet, limb: string, fade: boolean)
	local t = set.Parts[limb]
	if not t then
		return
	end
	set.Parts[limb] = nil
	if fade then
		t.Trail.Enabled = false
		task.delay(t.Trail.Lifetime + 0.05, function()
			t.Trail:Destroy()
			t.A0:Destroy()
			t.A1:Destroy()
		end)
	else
		t.Trail:Destroy()
		t.A0:Destroy()
		t.A1:Destroy()
	end
end

local function stopTrails(char: Model)
	local set = trailSets[char]
	if not set then
		return
	end
	trailSets[char] = nil
	if set.Watch then
		set.Watch.Disconnect()
	end
	for limb in pairs(set.Parts) do
		dropTrail(set, limb, true)
	end
end

local function startTrails(char: Model, duration: number)
	local tpl = trailTemplate()
	local root = rootOf(char)
	if not tpl or not root or not inView(root.Position) then
		return
	end
	stopTrails(char)
	local set: TrailSet = { Parts = {}, Watch = nil, Char = char }
	trailSets[char] = set
	local s = BodyState.Get(char)
	local has = { ["Right Arm"] = s.HasRightArm, ["Left Arm"] = s.HasLeftArm, ["Right Leg"] = s.HasRightLeg, ["Left Leg"] = s.HasLeftLeg }
	for _, limb in ipairs(LIMBS) do
		local part = char:FindFirstChild(limb)
		if has[limb] and part and part:IsA("BasePart") then
			local a0 = Instance.new("Attachment")
			a0.Name = TRAIL_TAG
			a0.Position = Vector3.new(0, part.Size.Y * 0.1, 0)
			local a1 = Instance.new("Attachment")
			a1.Name = TRAIL_TAG
			a1.Position = Vector3.new(0, -part.Size.Y * 0.45, 0)
			a0.Parent, a1.Parent = part, part
			local tr = tpl:Clone()
			tr.Name = TRAIL_TAG
			tr.Attachment0, tr.Attachment1 = a0, a1
			tr.Enabled = true
			tr.Parent = part
			set.Parts[limb] = { Trail = tr, A0 = a0, A1 = a1 }
		end
	end
	-- a limb lost mid-air takes its trail with it at once (never a streak off an arm that isn't there)
	set.Watch = BodyState.Watch(char, function(new)
		if trailSets[char] ~= set then
			return
		end
		local keep = { ["Right Arm"] = new.HasRightArm, ["Left Arm"] = new.HasLeftArm, ["Right Leg"] = new.HasRightLeg, ["Left Leg"] = new.HasLeftLeg }
		for limb in pairs(set.Parts) do
			if not keep[limb] then
				dropTrail(set, limb, false)
			end
		end
		if new.Ragdolled or not new.Alive then
			stopTrails(char)
		end
	end)
	task.delay(duration, function()
		if trailSets[char] == set then
			stopTrails(char)
		end
	end)
end

---------------------------------------------------------------------------
-- what a body is doing (its Parkour attribute): the effects that run while it does it
---------------------------------------------------------------------------
type Watched = { Char: Model, State: string?, Smoke: any, Drag: any, Conns: { RBXScriptConnection } }
local watched: { [Model]: Watched } = setmetatable({}, { __mode = "k" }) :: any

local function stopRunning(w: Watched)
	if w.Smoke then
		w.Smoke.Stop()
		w.Smoke = nil
	end
	if w.Drag then
		w.Drag.Stop()
		w.Drag = nil
	end
end

-- the wall a wall-running body has beside it (its outward normal), looked up when the blood asks
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.RespectCanCollide = true
local function wallNormal(char: Model, side: number): () -> Vector3?
	return function(): Vector3?
		local root = rootOf(char)
		if not root then
			return nil
		end
		wallParams.FilterDescendantsInstances = { char }
		local hit = workspace:Raycast(root.Position, root.CFrame.RightVector * side * 3.2, wallParams)
		return if hit then hit.Normal else nil
	end
end

local localChar: Model? = nil
local localState: string? = nil
-- the blood a body wipes along the surface it moves on: on while it bleeds in a move that drags it
-- (looked at again when it starts bleeding mid-move - never restarting the move's other effects)
local DRAG = { Slide = 1.1, Crawl = 0.9, WallRunLeft = 0.8, WallRunRight = 0.8 }
local function refreshDrag(w: Watched)
	local st = w.State
	local strength = st and DRAG[st]
	local want = strength ~= nil and BodyState.Get(w.Char).Bleeding
	if want and not w.Drag then
		local wall = if st == "WallRunLeft" then wallNormal(w.Char, -1) elseif st == "WallRunRight" then wallNormal(w.Char, 1) else nil
		w.Drag = Blood.Drag(w.Char, { Strength = strength, Wall = wall, Contact = wall == nil })
	elseif not want and w.Drag then
		w.Drag.Stop()
		w.Drag = nil
	end
end

local function onState(w: Watched)
	local char = w.Char
	local st: any
	if char == localChar then
		st = localState
	else
		st = char:GetAttribute("Parkour")
		st = if type(st) == "string" then st else nil
	end
	if st == w.State then
		return
	end
	w.State = st
	stopRunning(w)
	local root = rootOf(char)
	if not st or not root then
		return
	end
	if st == "Slide" and inView(root.Position) then
		-- the pack's slide smoke off the feet, for as long as it slides
		w.Smoke = VFX.Attach("SlideSmoke", root, CFrame.new(0, -2.8, 0.4))
	end
	refreshDrag(w)
end

local function watch(char: Model)
	if watched[char] or not char:IsA("Model") then
		return
	end
	local w: Watched = { Char = char, State = nil, Smoke = nil, Drag = nil, Conns = {} }
	watched[char] = w
	table.insert(w.Conns, char:GetAttributeChangedSignal("Parkour"):Connect(function()
		onState(w)
	end))
	-- (a body that starts bleeding mid-slide starts wiping it: the drag is looked at again)
	for _, attr in ipairs({ "GoreStage", "Wounds" }) do
		table.insert(w.Conns, char:GetAttributeChangedSignal(attr):Connect(function()
			refreshDrag(w)
		end))
	end
	table.insert(w.Conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stopRunning(w)
			stopTrails(char)
			for _, c in ipairs(w.Conns) do
				c:Disconnect()
			end
			watched[char] = nil
		end
	end))
	onState(w)
end

-- the local body's state from Parkour itself (never its attribute: that is the server's echo of it,
-- a round trip behind - a slide already over here would light up again when the echo arrived)
function MovementFX.SetLocal(char: Model?, state: string?)
	if not char then
		return
	end
	localChar = char
	localState = state
	local w = watched[char]
	if not w then
		watch(char)
		w = watched[char]
	end
	if w then
		onState(w)
	end
end

---------------------------------------------------------------------------
-- the moments
---------------------------------------------------------------------------
function MovementFX.Event(char: Model?, kind: string, data: any?)
	if not (char and char.Parent) then
		return
	end
	local root = rootOf(char)
	if not root or not inView(root.Position) then
		return
	end
	local d = if type(data) == "table" then data else {}
	local cf = root.CFrame
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	if kind == "DoubleJump" then
		-- the pack's air jump: a ring kicked off under the feet, smoke where they pushed off
		local feet = feetOf(char)
		if feet then
			-- (the smoke's box sits round the legs, its floor at the feet; the ring lies flat under them)
			VFX.Play("AirSmoke", CFrame.lookAt(feet, feet + look) * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.rad(90), 0), {})
			VFX.Play("AirJump", CFrame.lookAt(feet, feet + look) * CFrame.Angles(0, math.rad(50), math.rad(90)), { Scale = 0.85 })
			VFX.Play("AirBurst", CFrame.new(feet), {})
		end
		startTrails(char, 0.45)
	elseif kind == "Leap" then
		VFX.Play("LeapBurst", CFrame.lookAt(root.Position, root.Position + look), {})
		local g = floorUnder(root.Position, char)
		if g then
			FX.GroundDust(g.Position, 0.55)
		end
		startTrails(char, 0.7)
	elseif kind == "SlideCancel" then
		local feet = feetOf(char)
		if feet then
			VFX.Play("Puff", CFrame.new(feet), { Scale = 0.4 })
		end
		startTrails(char, 0.45)
	elseif kind == "Vault" or kind == "LedgeVault" then
		-- a puff of dust where the planted hand meets the top (only the hand it has: the clip it plays
		-- is the one that plants that hand)
		local hand = if d.Hand == "Left" then "Left Arm" elseif d.Hand == "Right" then "Right Arm" else nil
		local arm = hand and char:FindFirstChild(hand)
		if arm and arm:IsA("BasePart") and BodyState.HasLimb(char, hand :: string) then
			local p = if typeof(d.P) == "Vector3" then d.P else arm.CFrame:PointToWorldSpace(Vector3.new(0, -arm.Size.Y * 0.5, 0))
			VFX.Play("Puff", CFrame.new(p), { Scale = 0.3 })
		end
	elseif kind == "WallJump" then
		-- the kick off the wall: a puff where the feet left it, and the limbs streak through the flight
		local feet = feetOf(char)
		if feet then
			local n = if typeof(d.N) == "Vector3" then d.N else Vector3.zero
			VFX.Play("Puff", CFrame.new(feet - n * 0.8), { Scale = 0.38 })
		end
		startTrails(char, 0.6)
	elseif kind == "WallRun" then
		local feet = feetOf(char)
		if feet then
			VFX.Play("Puff", CFrame.new(feet), { Scale = 0.35 })
		end
		startTrails(char, 1.3)
	elseif kind == "Land" then
		-- a hard landing: dust off the floor it hit, and a bleeding body's blood thrown out of it
		local k = math.clamp(type(d.K) == "number" and d.K or 0.5, 0, 1)
		local g = floorUnder(root.Position, char)
		if g then
			VFX.Play("LandDust", CFrame.new(g.Position + Vector3.new(0, 0.2, 0)), { Scale = 0.7 + 0.5 * k })
			FX.GroundDust(g.Position, 0.4 + 0.5 * k)
		end
		stopTrails(char)
		local s = BodyState.Get(char)
		if s.Bleeding then
			local hurt = math.clamp(#s.Lost * 0.35 + math.max(0, s.Wounds - Config.Gore.DripFrom), 0, 1)
			Blood.Jolt(char, k * (0.5 + 0.5 * hurt))
			if g and hurt > 0.2 then
				Blood.Splash(g.Position + Vector3.new(0, 0.3, 0), 0.25 + 0.6 * k * hurt)
			end
		end
	end
end

local started = false
function MovementFX.Start()
	if started then
		return
	end
	started = true
	local function hook(p: Player)
		if p.Character then
			watch(p.Character)
		end
		p.CharacterAdded:Connect(watch)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		hook(p)
	end
	Players.PlayerAdded:Connect(hook)
	-- (the server's word on a moment another body had arrives through CombatClient: CombatEvent "FX")
end

return MovementFX
