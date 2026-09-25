--[[
	AvatarRig  (StarterPlayerScripts.OverkillHUD.AvatarRig)
	Copies of the local player's avatar for previews (shop cards, the aura try-on stage):
	scripts, tools, sounds and effects stripped, every limb put back in its rest pose, root
	anchored and limbs left free so the Animator can play the avatar's own idle animation.
]]

local AvatarRig = {}

local STRIP = {
	Script = true, LocalScript = true, ModuleScript = true, Sound = true, ForceField = true, Tool = true,
	BillboardGui = true, SurfaceGui = true, Highlight = true, ProximityPrompt = true,
	ParticleEmitter = true, Beam = true, Trail = true, Fire = true, Smoke = true, Sparkles = true,
	PointLight = true, SpotLight = true, SurfaceLight = true, BodyMover = true, BodyPosition = true,
	BodyVelocity = true, BodyGyro = true, AlignPosition = true, AlignOrientation = true, LinearVelocity = true,
}
local DEFAULT_IDLE = { R15 = "rbxassetid://507766666", R6 = "rbxassetid://180435571" }

-- the idle from the avatar's own Animate script, so animation packs show too
function AvatarRig.idleId(char: Model): string
	local animate = char:FindFirstChild("Animate")
	local idle = animate and animate:FindFirstChild("idle")
	if idle then
		local a = idle:FindFirstChild("Animation1") or idle:FindFirstChildOfClass("Animation")
		if a and a:IsA("Animation") and a.AnimationId ~= "" then
			return a.AnimationId
		end
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return if hum and hum.RigType == Enum.HumanoidRigType.R6 then DEFAULT_IDLE.R6 else DEFAULT_IDLE.R15
end

-- put every limb back where its joint says it belongs (the live character may be mid-stride)
local function restPose(model: Model, root: BasePart)
	local edges = {}
	for _, j in ipairs(model:GetDescendants()) do
		if j:IsA("JointInstance") and j.Part0 and j.Part1 then
			table.insert(edges, { j.Part0, j.Part1, j.C0 * j.C1:Inverse() })
		elseif j:IsA("WeldConstraint") and j.Part0 and j.Part1 then
			table.insert(edges, { j.Part0, j.Part1, j.Part0.CFrame:ToObjectSpace(j.Part1.CFrame) })
		end
	end
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, select(2, root.CFrame:ToEulerAnglesYXZ()), 0)
	local solved = { [root] = true }
	local progress = true
	while progress do
		progress = false
		for _, e in ipairs(edges) do
			local p0, p1, rel = e[1], e[2], e[3]
			if solved[p0] and not solved[p1] then
				p1.CFrame = p0.CFrame * rel
				solved[p1] = true
				progress = true
			elseif solved[p1] and not solved[p0] then
				p0.CFrame = p1.CFrame * rel:Inverse()
				solved[p0] = true
				progress = true
			end
		end
	end
end

export type Rig = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid?,
	IdleId: string,
	Feet: number, -- how far the root sits above the soles
	Height: number, -- soles to the top of the head (hats included)
	Width: number, -- widest side-to-side extent
}

-- a still copy of a character; nil when the character isn't ready yet
function AvatarRig.clone(char: Model?): Rig?
	if not char or not char:FindFirstChild("HumanoidRootPart") then
		return nil
	end
	local idleId = AvatarRig.idleId(char)
	local was = char.Archivable
	char.Archivable = true
	local ok, copy = pcall(function()
		return char:Clone()
	end)
	char.Archivable = was
	if not ok or not copy then
		return nil
	end
	local model = copy :: Model
	model.Name = "AvatarPreview"
	for _, d in ipairs(model:GetDescendants()) do
		if (STRIP[d.ClassName] or d:GetAttribute("OverkillAura")) and d.Parent then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		model:Destroy()
		return nil
	end
	root.Anchored = true
	restPose(model, root)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.BreakJointsOnDeath = false
		pcall(function()
			hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			hum.EvaluateStateMachine = false -- a mannequin: no falling, climbing or dying
		end)
	end
	-- measure from the body only (a long cape or sword shouldn't move the feet)
	local soles = math.huge
	local top, left, right = -math.huge, math.huge, -math.huge
	local rootCf = root.CFrame
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= root then
			local isBody = p.Parent == model
			local cf, s = p.CFrame, p.Size
			for _, cx in ipairs({ -0.5, 0.5 }) do
				for _, cy in ipairs({ -0.5, 0.5 }) do
					for _, cz in ipairs({ -0.5, 0.5 }) do
						local w = rootCf:PointToObjectSpace((cf * CFrame.new(s.X * cx, s.Y * cy, s.Z * cz)).Position)
						if isBody then
							soles = math.min(soles, w.Y)
						end
						top = math.max(top, w.Y)
						left = math.min(left, w.X)
						right = math.max(right, w.X)
					end
				end
			end
		end
	end
	if soles == math.huge then
		soles = -3
	end
	-- R15 knows exactly how high it stands
	if hum and hum.RigType == Enum.HumanoidRigType.R15 and hum.HipHeight > 0 then
		soles = -(hum.HipHeight + root.Size.Y / 2)
	end
	return {
		Model = model,
		Root = root,
		Humanoid = hum,
		IdleId = idleId,
		Feet = -soles,
		Height = math.max(top - soles, 1),
		Width = math.max(right - left, 1),
	}
end

-- stand the rig with its soles on `floor`, facing `look`
function AvatarRig.place(rig: Rig, floor: Vector3, yaw: number)
	rig.Root.CFrame = CFrame.new(floor + Vector3.new(0, rig.Feet, 0)) * CFrame.Angles(0, yaw, 0)
end

-- loop the avatar's idle (the model must already be inside the workspace or a WorldModel)
function AvatarRig.playIdle(rig: Rig): AnimationTrack?
	local hum = rig.Humanoid
	if not hum then
		return nil
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = rig.IdleId
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		track:Play(0.1)
		return track
	end
	return nil
end

return AvatarRig
