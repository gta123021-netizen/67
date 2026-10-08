--[[
	BodyState  (ReplicatedStorage.Combat.BodyState)
	What a body has left to move with - read, never kept twice. The dismemberment is the one source
	of truth: the server's gore stage (the GoreStage attribute: the right arm, then the left) and the
	limbs it has hidden (each lost part carries GoreHidden), plus the body itself (a limb part or its
	joint that is gone). This module only reads them, caches the answer per body and says the moment
	it changes - so the movement asks "can this body do this now?" and never tracks limbs of its own.

	  BodyState.Get(char) -> Snapshot      (cached; rebuilt only when something changed)
	    { HasLeftArm, HasRightArm, HasLeftLeg, HasRightLeg, Arms, Legs, Stage, Dismembered,
	      Lost = { "Right Arm", ... }, Wounds (share of health lost), Bleeding, Ragdolled, Alive }
	  BodyState.Can(char, move) -> ok, hand?, reason?   Config.Parkour.Requires[move]: hand is the hand a
	                                        one-handed clip should plant ("Left" / "Right") when it matters
	  BodyState.Watch(char, fn) -> { Disconnect }   fn(new, old) the frame a limb comes or goes, the body
	                                        is knocked down or gets up, or it dies
	  BodyState.HasLimb(char, name)         one limb ("Right Arm", "Left Leg", ...)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))

local BodyState = {}

local LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }
local JOINT = { ["Right Arm"] = "Right Shoulder", ["Left Arm"] = "Left Shoulder", ["Right Leg"] = "Right Hip", ["Left Leg"] = "Left Hip" }
-- the arms a gore stage has taken (CombatService: the right arm at 1, the left at 2)
local STAGE_LOST = { ["Right Arm"] = 1, ["Left Arm"] = 2 }

export type Snapshot = {
	HasLeftArm: boolean,
	HasRightArm: boolean,
	HasLeftLeg: boolean,
	HasRightLeg: boolean,
	Arms: number,
	Legs: number,
	Stage: number,
	Dismembered: boolean,
	Lost: { string },
	Wounds: number,
	Bleeding: boolean,
	Ragdolled: boolean,
	Alive: boolean,
}

type Entry = {
	Model: Model,
	Snap: Snapshot?,
	Watchers: { (Snapshot, Snapshot?) -> () },
	Conns: { RBXScriptConnection },
	Limbs: { [string]: RBXScriptConnection },
}
local entries: { [Model]: Entry } = setmetatable({}, { __mode = "k" }) :: any

local function stageOf(char: Model): number
	local st = char:GetAttribute("GoreStage")
	return if type(st) == "number" then st else 0
end

-- the limb is on the body: its part is there, not hidden by the gore, still jointed to the torso (a
-- ragdoll only switches a joint off - it is still there), and its gore stage hasn't taken it
local function present(char: Model, name: string, stage: number): boolean
	local lostAt = STAGE_LOST[name]
	if lostAt and Config.Gore.Enabled and stage >= lostAt then
		return false
	end
	local part = char:FindFirstChild(name)
	if not (part and part:IsA("BasePart")) then
		return false
	end
	if part:GetAttribute("GoreHidden") ~= nil then
		return false
	end
	local torso = char:FindFirstChild("Torso")
	if torso then
		local j = torso:FindFirstChild(JOINT[name])
		if not (j and j:IsA("Motor6D") and j.Part1 == part) then
			-- (some rigs keep the joint on the other side)
			local other = part:FindFirstChild(JOINT[name])
			if not (other and other:IsA("Motor6D")) then
				return false
			end
		end
	end
	return true
end

local function build(char: Model): Snapshot
	local stage = stageOf(char)
	local has = {}
	local lost = {}
	for _, n in ipairs(LIMBS) do
		has[n] = present(char, n, stage)
		if not has[n] then
			table.insert(lost, n)
		end
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local w = char:GetAttribute("Wounds")
	local wounds = if type(w) == "number" then w elseif hum and hum.MaxHealth > 0 then 1 - math.clamp(hum.Health / hum.MaxHealth, 0, 1) else 0
	local arms = (if has["Left Arm"] then 1 else 0) + (if has["Right Arm"] then 1 else 0)
	local legs = (if has["Left Leg"] then 1 else 0) + (if has["Right Leg"] then 1 else 0)
	return {
		HasLeftArm = has["Left Arm"],
		HasRightArm = has["Right Arm"],
		HasLeftLeg = has["Left Leg"],
		HasRightLeg = has["Right Leg"],
		Arms = arms,
		Legs = legs,
		Stage = stage,
		Dismembered = #lost > 0,
		Lost = lost,
		Wounds = wounds,
		Bleeding = #lost > 0 or wounds >= Config.Gore.DripFrom,
		Ragdolled = char:GetAttribute("Ragdolled") == true,
		Alive = hum ~= nil and hum.Health > 0,
	}
end

local function same(a: Snapshot, b: Snapshot): boolean
	return a.HasLeftArm == b.HasLeftArm and a.HasRightArm == b.HasRightArm and a.HasLeftLeg == b.HasLeftLeg
		and a.HasRightLeg == b.HasRightLeg and a.Ragdolled == b.Ragdolled and a.Alive == b.Alive and a.Bleeding == b.Bleeding
end

local entryFor: (Model) -> Entry

-- something on the body changed: the answer is rebuilt, and the watchers hear it if it matters
local function dirty(e: Entry)
	local old = e.Snap
	e.Snap = nil
	if #e.Watchers == 0 then
		return
	end
	local new = build(e.Model)
	e.Snap = new
	if old and same(old, new) then
		return
	end
	for _, fn in ipairs(table.clone(e.Watchers)) do
		local ok, err = pcall(fn, new, old)
		if not ok then
			warn("[BodyState]", err)
		end
	end
end

-- a limb part's own signals (its GoreHidden mark, the part leaving the body)
local function watchLimb(e: Entry, part: Instance)
	if not (part:IsA("BasePart") and JOINT[part.Name]) or e.Limbs[part.Name] then
		return
	end
	e.Limbs[part.Name] = part:GetAttributeChangedSignal("GoreHidden"):Connect(function()
		dirty(e)
	end)
end

function entryFor(char: Model): Entry
	local e = entries[char]
	if e then
		return e
	end
	e = { Model = char, Snap = nil, Watchers = {}, Conns = {}, Limbs = {} }
	entries[char] = e
	local function d()
		dirty(e :: Entry)
	end
	for _, attr in ipairs({ "GoreStage", "Ragdolled", "Wounds" }) do
		table.insert(e.Conns, char:GetAttributeChangedSignal(attr):Connect(d))
	end
	for _, n in ipairs(LIMBS) do
		local p = char:FindFirstChild(n)
		if p then
			watchLimb(e, p)
		end
	end
	table.insert(e.Conns, char.ChildAdded:Connect(function(c)
		watchLimb(e :: Entry, c)
		if JOINT[c.Name] then
			d()
		end
	end))
	table.insert(e.Conns, char.ChildRemoved:Connect(function(c)
		if JOINT[c.Name] then
			local conn = (e :: Entry).Limbs[c.Name]
			if conn then
				conn:Disconnect()
				;(e :: Entry).Limbs[c.Name] = nil
			end
			d()
		end
	end))
	-- (a joint torn out of the torso)
	local torso = char:FindFirstChild("Torso")
	if torso then
		table.insert(e.Conns, torso.ChildRemoved:Connect(function(c)
			if c:IsA("Motor6D") then
				d()
			end
		end))
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		table.insert(e.Conns, hum.Died:Connect(d))
	end
	table.insert(e.Conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			BodyState.Forget(char)
		end
	end))
	return e
end

function BodyState.Get(char: Model): Snapshot
	local e = entryFor(char)
	local s = e.Snap
	if not s then
		s = build(char)
		e.Snap = s
	end
	return s
end

function BodyState.HasLimb(char: Model, name: string): boolean
	local s = BodyState.Get(char)
	if name == "Right Arm" then
		return s.HasRightArm
	elseif name == "Left Arm" then
		return s.HasLeftArm
	elseif name == "Right Leg" then
		return s.HasRightLeg
	elseif name == "Left Leg" then
		return s.HasLeftLeg
	end
	return char:FindFirstChild(name) ~= nil
end

-- may this body do `move` (Config.Parkour.Requires) right now? The hand a one-handed clip plants
-- comes back with it when the move has a choice (AnyHand: the right when both are there, picked
-- at random - both clips are the same vault mirrored)
function BodyState.Can(char: Model, move: string): (boolean, string?, string?)
	local req = Config.Parkour.Requires[move]
	if not req then
		return false, nil, "unknown move"
	end
	local s = BodyState.Get(char)
	if not s.Alive then
		return false, nil, "dead"
	end
	if s.Ragdolled then
		return false, nil, "knocked down"
	end
	if req.Legs and s.Legs < req.Legs then
		return false, nil, "legs"
	end
	if req.Arms and s.Arms < req.Arms then
		return false, nil, "arms"
	end
	if req.Limbs and s.Arms + s.Legs < req.Limbs then
		return false, nil, "limbs"
	end
	if req.Hands then
		for _, h in ipairs(req.Hands) do
			if (h == "Right" and not s.HasRightArm) or (h == "Left" and not s.HasLeftArm) then
				return false, nil, "arms"
			end
		end
	end
	if req.AnyHand then
		if s.HasLeftArm and s.HasRightArm then
			return true, if math.random() < 0.5 then "Left" else "Right", nil
		elseif s.HasLeftArm then
			return true, "Left", nil
		elseif s.HasRightArm then
			return true, "Right", nil
		end
		return false, nil, "arms"
	end
	return true, nil, nil
end

function BodyState.Watch(char: Model, fn: (Snapshot, Snapshot?) -> ()): { Disconnect: () -> () }
	local e = entryFor(char)
	table.insert(e.Watchers, fn)
	if not e.Snap then
		e.Snap = build(char)
	end
	return {
		Disconnect = function()
			local i = table.find(e.Watchers, fn)
			if i then
				table.remove(e.Watchers, i)
			end
		end,
	}
end

function BodyState.Forget(char: Model)
	local e = entries[char]
	if not e then
		return
	end
	entries[char] = nil
	for _, c in ipairs(e.Conns) do
		c:Disconnect()
	end
	for _, c in pairs(e.Limbs) do
		c:Disconnect()
	end
	table.clear(e.Watchers)
end

return BodyState
