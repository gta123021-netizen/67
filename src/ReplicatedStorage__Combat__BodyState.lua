--[[
	BodyState  (ReplicatedStorage.Combat.BodyState)
	What a fighter's body still has, and so what it can still do - read straight off the body, never
	kept anywhere else. The dismemberment's own record is the source: the gore stage the server keeps
	on the character (GoreStage: the right arm goes first, then the left - Config.ArmsAt), and the limb
	parts themselves (a limb whose part is gone, or hidden by the server as it tears it off -
	GoreHidden - is gone, whatever took it). The local client's first-person hiding
	(LocalTransparencyModifier) never counts.

	  BodyState.Of(char) -> Body          { HasLeftArm, HasRightArm, HasLeftLeg, HasRightLeg, Arms,
	                                        Legs, Dismembered, Stage, Wounds, Ragdolled, Dead }
	  BodyState.Can(body, move) -> (ok, variant?, why?)
	      move: a Config.Traversal.Needs key. variant: for a move done on one supporting hand (the
	      vaults) the hand it is done with - "Left" | "Right" (the clip for that hand is played)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local BodyState = {}

export type Body = {
	HasLeftArm: boolean,
	HasRightArm: boolean,
	HasLeftLeg: boolean,
	HasRightLeg: boolean,
	Arms: number,
	Legs: number,
	Dismembered: boolean,
	Stage: number,
	Wounds: number,
	Ragdolled: boolean,
	Dead: boolean,
}

local function present(char: Instance, name: string): boolean
	local p = char:FindFirstChild(name)
	return p ~= nil and p:IsA("BasePart") and p:GetAttribute("GoreHidden") == nil and p.Transparency < 0.99
end

function BodyState.Of(char: Instance): Body
	local stage = char:GetAttribute("GoreStage")
	stage = if type(stage) == "number" then stage else 0
	local arms = if Config.Gore.Enabled then Config.ArmsAt(stage) else 2
	local b: Body = {
		HasRightArm = arms >= 2 and present(char, "Right Arm"),
		HasLeftArm = arms >= 1 and present(char, "Left Arm"),
		HasRightLeg = present(char, "Right Leg"),
		HasLeftLeg = present(char, "Left Leg"),
		Arms = 0,
		Legs = 0,
		Dismembered = false,
		Stage = stage,
		Wounds = 0,
		Ragdolled = char:GetAttribute("Ragdolled") == true,
		Dead = false,
	}
	b.Arms = (if b.HasLeftArm then 1 else 0) + (if b.HasRightArm then 1 else 0)
	b.Legs = (if b.HasLeftLeg then 1 else 0) + (if b.HasRightLeg then 1 else 0)
	b.Dismembered = b.Arms < 2 or b.Legs < 2
	local w = char:GetAttribute("Wounds")
	b.Wounds = if type(w) == "number" then w else 0
	local hum = char:FindFirstChildOfClass("Humanoid")
	b.Dead = hum == nil or hum.Health <= 0 or char:GetAttribute("CombatState") == "Dead"
	return b
end

function BodyState.Can(b: Body, move: string): (boolean, string?, string?)
	local need = Config.Traversal.Needs[move]
	if not need then
		return false, nil, "unknown"
	end
	if b.Dead or b.Ragdolled then
		return false, nil, "down"
	end
	if need.Arms and b.Arms < need.Arms then
		return false, nil, "arms"
	end
	if need.Legs and b.Legs < need.Legs then
		return false, nil, "legs"
	end
	if need.Hand then
		if b.HasLeftArm and b.HasRightArm then
			return true, if math.random() < 0.5 then "Left" else "Right", nil
		elseif b.HasLeftArm then
			return true, "Left", nil
		elseif b.HasRightArm then
			return true, "Right", nil
		end
		return false, nil, "arms"
	end
	return true, nil, nil
end

return BodyState
