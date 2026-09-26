--[[
	Ragdoll  (ReplicatedStorage.Combat.Ragdoll)
	R6 ragdoll that never breaks the character.

	Setup (server, once per character): for every limb joint (Neck, both Shoulders, both Hips) a
	BallSocketConstraint is built on the Motor6D's own pivot (attachments at C0/C1, so switching
	between motor and socket never jumps), with cone and twist limits; each arm and leg gets an
	invisible collider so the body rests on the floor instead of sinking through it. Everything is
	created once, disabled, and only switched on and off afterwards - nothing is created or
	destroyed per knockdown, so repeated ragdolls can't pile anything up.

	Enable (server): the five limb Motor6Ds are disabled (never destroyed), the sockets and
	colliders switch on, and the character gets Ragdolled = true plus the impulse attributes.
	The RootJoint stays on (the root rides along with the torso), Humanoid.RequiresNeck is off
	so a disabled Neck can't kill, and BreakJointsOnDeath is off.
	The physics owner applies the fall: the player's own client for players (ClientApply), the
	server for NPCs.

	Disable (server): motors back on, sockets and colliders off, Ragdolled = false. The owner then
	stands the root up where the torso lies (ClientApply / ServerStandUp).
]]

local Ragdoll = {}

local JOINTS = {
	-- motor name, part0, part1, cone angle, twist, attachment axis in each part (limb down / neck up)
	{ Name = "Neck", Part0 = "Torso", Part1 = "Head", Cone = 40, Twist = 50, Axis = Vector3.new(0, 1, 0) },
	{ Name = "Right Shoulder", Part0 = "Torso", Part1 = "Right Arm", Cone = 110, Twist = 70, Axis = Vector3.new(0, -1, 0) },
	{ Name = "Left Shoulder", Part0 = "Torso", Part1 = "Left Arm", Cone = 110, Twist = 70, Axis = Vector3.new(0, -1, 0) },
	{ Name = "Right Hip", Part0 = "Torso", Part1 = "Right Leg", Cone = 80, Twist = 30, Axis = Vector3.new(0, -1, 0) },
	{ Name = "Left Hip", Part0 = "Torso", Part1 = "Left Leg", Cone = 80, Twist = 30, Axis = Vector3.new(0, -1, 0) },
}
Ragdoll.Joints = JOINTS

local LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }

local function motorOf(char: Model, j: any): Motor6D?
	local p0 = char:FindFirstChild(j.Part0)
	local m = p0 and p0:FindFirstChild(j.Name)
	if m and m:IsA("Motor6D") then
		return m
	end
	-- some rigs keep a joint under the other part
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") and d.Name == j.Name then
			return d
		end
	end
	return nil
end

local function attach(part: BasePart, name: string, pos: Vector3, axis: Vector3): Attachment
	local a = part:FindFirstChild(name)
	if not (a and a:IsA("Attachment")) then
		a = Instance.new("Attachment")
		a.Name = name
		a.Parent = part
	end
	-- X axis = the socket's cone axis, Y axis = twist reference (forward)
	local ref = if math.abs(axis.Z) > 0.9 then Vector3.new(0, 1, 0) else Vector3.new(0, 0, -1)
	a.CFrame = CFrame.fromMatrix(pos, axis, ref:Cross(axis).Unit:Cross(axis).Unit * -1)
	return a
end

-- idempotent: builds (or finds) the ragdoll rig of a character. Server only.
function Ragdoll.Setup(char: Model): boolean
	local hum = char:FindFirstChildOfClass("Humanoid")
	local torso = char:FindFirstChild("Torso")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and torso and root) then
		return false
	end
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	local folder = char:FindFirstChild("RagdollRig")
	if folder and folder:GetAttribute("Built") then
		return true
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "RagdollRig"
		folder.Parent = char
	end
	for _, j in ipairs(JOINTS) do
		local m = motorOf(char, j)
		local p0 = char:FindFirstChild(j.Part0)
		local p1 = char:FindFirstChild(j.Part1)
		if m and p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
			local a0 = attach(p0, "RagdollA0_" .. j.Name, m.C0.Position, j.Axis)
			local a1 = attach(p1, "RagdollA1_" .. j.Name, m.C1.Position, j.Axis)
			local s = Instance.new("BallSocketConstraint")
			s.Name = "Socket_" .. j.Name
			s.Attachment0 = a0
			s.Attachment1 = a1
			s.LimitsEnabled = true
			s.UpperAngle = j.Cone
			s.TwistLimitsEnabled = true
			s.TwistLowerAngle = -j.Twist
			s.TwistUpperAngle = j.Twist
			s.Restitution = 0
			s.MaxFrictionTorque = 4 -- a little joint friction: limbs settle instead of flailing
			s.Enabled = false
			s.Parent = folder
		end
	end
	for _, limbName in ipairs(LIMBS) do
		local limb = char:FindFirstChild(limbName)
		if limb and limb:IsA("BasePart") then
			local c = Instance.new("Part")
			c.Name = "Collider_" .. limbName
			c.Size = Vector3.new(0.9, 1.7, 0.9)
			c.CFrame = limb.CFrame * CFrame.new(0, -0.12, 0)
			c.Transparency = 1
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.Massless = true
			c.Anchored = false
			c.CastShadow = false
			c.Parent = folder
			local w = Instance.new("WeldConstraint")
			w.Part0 = limb
			w.Part1 = c
			w.Parent = c
			for _, other in ipairs({ torso, root }) do
				local n = Instance.new("NoCollisionConstraint")
				n.Part0 = c
				n.Part1 = other
				n.Parent = c
			end
		end
	end
	local head = char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local n = Instance.new("NoCollisionConstraint")
		n.Name = "HeadTorso"
		n.Part0 = head
		n.Part1 = torso
		n.Parent = folder
	end
	folder:SetAttribute("Built", true)
	return true
end

local function setRig(char: Model, on: boolean)
	local folder = char:FindFirstChild("RagdollRig")
	if not folder then
		return
	end
	for _, j in ipairs(JOINTS) do
		local m = motorOf(char, j)
		if m then
			m.Enabled = not on
		end
		local s = folder:FindFirstChild("Socket_" .. j.Name)
		if s then
			s.Enabled = on
		end
	end
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") then
			-- (a lost limb - hidden by the gore, GoreHidden - never touches the ground)
			local limb = char:FindFirstChild(string.sub(c.Name, 10))
			local lost = string.sub(c.Name, 1, 9) == "Collider_" and limb ~= nil and limb:GetAttribute("GoreHidden") ~= nil
			c.CanCollide = on and not lost
		end
	end
end

-- server: knock a character down. legs/torso are world-space velocities, spin an angular speed.
function Ragdoll.Enable(char: Model, legs: Vector3?, torso: Vector3?, spin: Vector3?)
	if not Ragdoll.Setup(char) then
		return
	end
	setRig(char, true)
	char:SetAttribute("RagdollLegs", legs or Vector3.zero)
	char:SetAttribute("RagdollTorso", torso or Vector3.zero)
	char:SetAttribute("RagdollSpin", spin or Vector3.zero)
	local serial = char:GetAttribute("RagdollSerial")
	char:SetAttribute("RagdollSerial", (if type(serial) == "number" then serial else 0) + 1)
	char:SetAttribute("Ragdolled", true)
end

-- server: joints back. The owner stands the body up.
function Ragdoll.Disable(char: Model)
	setRig(char, false)
	char:SetAttribute("Ragdolled", false)
end

function Ragdoll.IsRagdolled(char: Model): boolean
	return char:GetAttribute("Ragdolled") == true
end

-- the physics owner: push the body over (called once when Ragdolled turns on)
function Ragdoll.ApplyFall(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	hum.AutoRotate = false
	hum:ChangeState(Enum.HumanoidStateType.Physics)
	local torso = char:FindFirstChild("Torso")
	local legsV = char:GetAttribute("RagdollLegs")
	local torsoV = char:GetAttribute("RagdollTorso")
	local spin = char:GetAttribute("RagdollSpin")
	for _, n in ipairs({ "Right Leg", "Left Leg" }) do
		local p = char:FindFirstChild(n)
		if p and p:IsA("BasePart") and typeof(legsV) == "Vector3" then
			p.AssemblyLinearVelocity = legsV
		end
	end
	if torso and torso:IsA("BasePart") then
		if typeof(torsoV) == "Vector3" then
			torso.AssemblyLinearVelocity = torsoV
		end
		if typeof(spin) == "Vector3" then
			torso.AssemblyAngularVelocity = spin
		end
	end
end

-- the physics owner: stand the root up where the torso lies, facing along the body
function Ragdoll.StandUp(char: Model, ignore: { Instance }?)
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not (hum and root and torso and root:IsA("BasePart") and torso:IsA("BasePart")) then
		return
	end
	local fwd = Vector3.new(torso.CFrame.LookVector.X, 0, torso.CFrame.LookVector.Z)
	if fwd.Magnitude < 0.3 then
		local up = torso.CFrame.UpVector
		fwd = Vector3.new(up.X, 0, up.Z)
	end
	if fwd.Magnitude < 0.05 then
		fwd = Vector3.new(0, 0, -1)
	end
	fwd = fwd.Unit
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ex = { char }
	if ignore then
		for _, i in ipairs(ignore) do
			table.insert(ex, i)
		end
	end
	params.FilterDescendantsInstances = ex
	local from = torso.Position + Vector3.new(0, 2, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -12, 0), params)
	local groundY = if hit then hit.Position.Y else torso.Position.Y - 1
	local pos = Vector3.new(torso.Position.X, groundY + 3 + hum.HipHeight, torso.Position.Z)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(pos, pos + fwd)
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
end

return Ragdoll
