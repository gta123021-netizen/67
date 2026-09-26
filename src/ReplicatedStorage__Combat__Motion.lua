--[[
	Motion  (ReplicatedStorage.Combat.Motion)
	Moving a character's root for combat: dashes, step-ins, knockback. Always run by the root's
	physics owner (the player's own client, or the server for NPCs).

	One LinearVelocity per character (created once, reused), constrained to the ground plane so
	gravity and jumping stay natural. A drive always ends by clearing the constraint and the
	horizontal velocity, so nothing keeps sliding after its animation has finished.

	Walls: a drive never pushes a body into solid geometry. Meeting a wall at an angle it slides
	along it (the part of the motion into the wall is taken out); meeting one head-on it ends. Parts
	that don't collide (bushes, flowers, effects) are ignored, like the humanoid walks through them.
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
wallParams.RespectCanCollide = true

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
	opts.StopAtWalls: never into something solid right ahead - slide along it at an angle, end
	                  the drive head-on
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
				local n = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
				n = if n.Magnitude > 1e-3 then n.Unit else -fv.Unit
				local into = fv:Dot(n)
				if into < 0 then
					local slide = fv - n * into
					if slide.Magnitude < fv.Magnitude * 0.35 then
						-- head-on: nothing left to slide along
						finish(true)
						return
					end
					v = slide
				end
			end
		end
		lv.PlaneVelocity = Vector2.new(v.X, v.Z)
		lv.Enabled = true
	end
	step()
	st.Conn = RunService.Heartbeat:Connect(step)
	return serial
end

--[[ one frame of a critically damped turn (pure: the caller writes the facing).
	offset = current yaw - wanted yaw (radians, wrapped to -pi..pi), vel = turn speed (rad/s).
	The offset and the speed decay together with no overshoot at natural frequency omega; the turn
	never goes faster than maxRate. Exact for any frame time. Returns (the yaw change to apply this
	frame, the new turn speed). ]]
function Motion.Turn(offset: number, vel: number, omega: number, maxRate: number, dt: number): (number, number)
	local e = math.exp(-omega * dt)
	local k = vel + omega * offset
	local nextOffset = (offset + k * dt) * e
	local nextVel = (vel - k * omega * dt) * e
	local step = math.clamp(nextOffset - offset, -maxRate * dt, maxRate * dt)
	return step, math.clamp(nextVel, -maxRate, maxRate)
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
