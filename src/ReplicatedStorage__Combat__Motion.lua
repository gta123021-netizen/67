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
local BRAKE = 900 -- studs/s^2: how hard a drive brakes into a body in its path (100 studs/s stops in 5.6)
-- a knocked-back body stops this far (root to root) short of another body in its lane (this wide
-- either side of its line) - never shoved through or into it. The same rule everywhere a slide is
-- worked out: the server (NPCs), the victim's own client, every other screen (CombatFX's lead)
Motion.BODY_GAP = 2.4
Motion.BODY_WIDTH = 2.2

-- the nearest body along `dir` from `p` in a lane `width` either side (nil: the lane is clear)
function Motion.Ahead(p: Vector3, dir: Vector3, bodies: { Vector3 }, width: number): number?
	local near: number? = nil
	for _, other in ipairs(bodies) do
		local rel = other - p
		if math.abs(rel.Y) < 5 then
			local flatRel = Vector3.new(rel.X, 0, rel.Z)
			local along = flatRel:Dot(dir)
			if along > 0 and (near == nil or along < near) and (flatRel - dir * along).Magnitude < width then
				near = along
			end
		end
	end
	return near
end

-- the fastest a body can still go and stop `room` studs on (the braking into a body ahead)
function Motion.BrakeCap(room: number): number
	return math.sqrt(2 * BRAKE * math.max(0, room))
end

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
	opts.Fighters: () -> { Vector3 } - other fighters' roots (where this screen has them); a body in
	               the path (within opts.Width, default 2.6, of the line) is braked into: the drive
	               slows at BRAKE to stop opts.Gap (root to root, default 3.2) short of it, then ends
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
	-- (one filter per drive, set once: not re-copied every frame, and two drives - the server runs
	-- one per NPC - never overwrite each other's list)
	local params = wallParams
	if opts.Ignore then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.RespectCanCollide = true
		params.FilterDescendantsInstances = opts.Ignore
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
			local near = Motion.Ahead(root.Position, fv.Unit, opts.Fighters(), opts.Width or 2.6)
			if near then
				-- (the speed it can still stop from in the room left)
				local cap = Motion.BrakeCap(near - (opts.Gap or 3.2))
				if cap < 1 then
					finish(true)
					return
				end
				if fv.Magnitude > cap then
					v *= cap / fv.Magnitude
					fv = Vector3.new(v.X, 0, v.Z)
				end
			end
		end
		if opts.StopAtWalls and fv.Magnitude > 1 then
			local hit = workspace:Raycast(root.Position, fv.Unit * (1.6 + fv.Magnitude / 30), params)
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

--[[ the shape of every knockback slide: its speed at k (1 when the blow lands .. 0 when it ends), as a
	share of the push's nominal speed. k^1.5, scaled so its average stays Config.PushShare (0.5667):
	every push still covers exactly the same distance, but it snaps back hardest on the first frame
	after the impact (1.42x) and glides into its stop with no last-frame brake (the old 1.4k - 0.4k^2
	braked hardest at the very end - a visible clunk). The attacker's follow-up carry
	(CombatChoreo.CarrySpeed) rides the same curve, so the gap between them holds. ]]
local PUSH_PEAK = (1.4 / 2 - 0.4 / 3) * 2.5
function Motion.PushCurve(k: number): number
	if k <= 0 then
		return 0
	end
	return PUSH_PEAK * k * math.sqrt(k)
end

-- knockback: a horizontal shove for `duration` (decaying) plus an instant vertical kick. bodies: the
-- other fighters (where this screen has them): the slide brakes to stop BODY_GAP short of one
function Motion.Push(root: BasePart, vec: Vector3, duration: number, ignore: { Instance }?, bodies: (() -> { Vector3 })?)
	local flat = Vector3.new(vec.X, 0, vec.Z)
	if vec.Y ~= 0 then
		-- the lift is SET, never added: a blow that catches a jump pops the body the same small
		-- amount as one on the ground (adding it to a rising jump flung victims ~8 studs up)
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, vec.Y, v.Z)
	end
	if duration <= 0 or flat.Magnitude < 0.5 then
		return
	end
	-- (PushCurve: the same distance as ever, a sharp snap back and a soft glide into the stop)
	Motion.Drive(root, duration, function(t)
		return flat * Motion.PushCurve(1 - t / duration)
	end, { StopAtWalls = true, Ignore = ignore, Fighters = bodies, Gap = Motion.BODY_GAP, Width = Motion.BODY_WIDTH })
end

return Motion
