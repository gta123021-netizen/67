--[[
	Motion  (ReplicatedStorage.Combat.Motion)
	Moving a character's root for combat: dashes, step-ins, knockback. Always run by the root's
	physics owner (the player's own client, or the server for NPCs).

	One LinearVelocity per character (created once, reused), constrained to the ground plane so
	gravity and jumping stay natural. A drive always ends by clearing the constraint and the
	horizontal velocity, so nothing keeps sliding after its animation has finished.
]]

local RunService = game:GetService("RunService")

local Motion = {}

local MAX_FORCE = 120000

local active: { [BasePart]: { Serial: number, Conn: RBXScriptConnection? } } = setmetatable({}, { __mode = "k" }) :: any

local function rig(root: BasePart): LinearVelocity
	local lv = root:FindFirstChild("CombatDrive")
	if lv and lv:IsA("LinearVelocity") then
		return lv
	end
	local a = root:FindFirstChild("CombatDriveAttachment")
	if not (a and a:IsA("Attachment")) then
		a = Instance.new("Attachment")
		a.Name = "CombatDriveAttachment"
		a.Parent = root
	end
	lv = Instance.new("LinearVelocity")
	lv.Name = "CombatDrive"
	lv.Attachment0 = a
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	lv.MaxForce = MAX_FORCE
	lv.PlaneVelocity = Vector2.zero
	lv.Enabled = false
	lv.Parent = root
	return lv
end

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude

-- stops whatever drive is running on this root
function Motion.Stop(root: BasePart, keepVelocity: boolean?)
	local st = active[root]
	if st then
		st.Serial += 1
		if st.Conn then
			st.Conn:Disconnect()
			st.Conn = nil
		end
	end
	local lv = root:FindFirstChild("CombatDrive")
	if lv and lv:IsA("LinearVelocity") then
		lv.Enabled = false
		lv.PlaneVelocity = Vector2.zero
	end
	if not keepVelocity and root.Parent then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
	end
end

--[[ drive the root along the ground for `duration` seconds.
	velocityAt(t) -> Vector3 (horizontal, world) for the elapsed time t.
	opts.StopAtWalls: end early when something solid is right ahead.
	opts.Ignore: instances the wall check ignores (characters).
	opts.Fighters: other fighters' root parts - the drive ends when one is in the path closer than
	               opts.Gap (root to root, default 3.2) within opts.Width (default 2.6) of the line
	opts.OnEnd(stoppedEarly)
	opts.KeepVelocity: leave the last velocity on the root instead of clearing it (knockback) ]]
function Motion.Drive(root: BasePart, duration: number, velocityAt: (number) -> Vector3, opts: any?): number
	opts = opts or {}
	local st = active[root]
	if not st then
		st = { Serial = 0, Conn = nil }
		active[root] = st
	end
	if st.Conn then
		st.Conn:Disconnect()
		st.Conn = nil
	end
	st.Serial += 1
	local serial = st.Serial
	local lv = rig(root)
	local t0 = os.clock()
	if opts.Ignore then
		wallParams.FilterDescendantsInstances = opts.Ignore
	end
	local function finish(early: boolean)
		if st.Serial ~= serial then
			return
		end
		if st.Conn then
			st.Conn:Disconnect()
			st.Conn = nil
		end
		lv.Enabled = false
		lv.PlaneVelocity = Vector2.zero
		if root.Parent then
			local v = root.AssemblyLinearVelocity
			if opts.KeepVelocity then
				local last = velocityAt(duration)
				root.AssemblyLinearVelocity = Vector3.new(last.X, v.Y, last.Z)
			else
				root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
			end
		end
		if opts.OnEnd then
			opts.OnEnd(early)
		end
	end
	local function step()
		if st.Serial ~= serial or not root.Parent then
			if st.Conn then
				st.Conn:Disconnect()
				st.Conn = nil
			end
			return
		end
		local t = os.clock() - t0
		if t >= duration then
			finish(false)
			return
		end
		local v = velocityAt(t)
		local fv = Vector3.new(v.X, 0, v.Z)
		if opts.Fighters and fv.Magnitude > 1 then
			local dir = fv.Unit
			local gap = (opts.Gap or 3.2) + fv.Magnitude / 60
			local width = opts.Width or 2.6
			local p = root.Position
			for _, other in ipairs(opts.Fighters) do
				if other.Parent and other ~= root then
					local rel = other.Position - p
					if math.abs(rel.Y) < 5 then
						local flatRel = Vector3.new(rel.X, 0, rel.Z)
						local along = flatRel:Dot(dir)
						if along > 0 and along < gap and (flatRel - dir * along).Magnitude < width then
							finish(true)
							return
						end
					end
				end
			end
		end
		if opts.StopAtWalls and fv.Magnitude > 1 then
			if opts.Ignore then
				wallParams.FilterDescendantsInstances = opts.Ignore
			end
			local hit = workspace:Raycast(root.Position, fv.Unit * (1.6 + fv.Magnitude / 30), wallParams)
			if hit and hit.Normal.Y < 0.6 then
				if root.Parent and root.Parent:GetAttribute("CombatEntity") and game:GetService("Players"):GetPlayerFromCharacter(root.Parent) and game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer:GetAttribute("CombatDebug") then
					print("[CombatDbg] drive stopped by", hit.Instance:GetFullName())
				end
				finish(true)
				return
			end
		end
		lv.PlaneVelocity = Vector2.new(v.X, v.Z)
		lv.Enabled = true
	end
	step()
	st.Conn = RunService.Heartbeat:Connect(step)
	return serial
end

-- knockback: a horizontal shove for `duration` (decaying) plus an instant vertical kick
function Motion.Push(root: BasePart, vec: Vector3, duration: number, ignore: { Instance }?)
	local flat = Vector3.new(vec.X, 0, vec.Z)
	if vec.Y ~= 0 then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, 0) + vec.Y, v.Z)
	end
	if duration <= 0 or flat.Magnitude < 0.5 then
		return
	end
	Motion.Drive(root, duration, function(t)
		local k = 1 - t / duration
		return flat * (0.35 + 0.65 * k * k)
	end, { StopAtWalls = true, Ignore = ignore })
end

return Motion
