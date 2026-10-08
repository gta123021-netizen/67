--[[
	BeamMath  (ReplicatedStorage.Abilities.BeamMath)
	A beam's geometry, the same on the server (its hits) and on every screen (where it is drawn): its
	aim (yaw and pitch, turned at a capped rate), where it leaves the caster, and where it ends - the
	first wall on its line, or the first body its core meets. Bodies are upright capsules (an R6
	body from the feet to the top of the head, arms included).
]]

local BeamMath = {}

-- an R6 body in its root's frame: a capsule up the middle
BeamMath.BodyBottom = -2.55
BeamMath.BodyTop = 1.75
BeamMath.BodyRadius = 1.15

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.new(0, 0, -1)
end
BeamMath.Flat = flat

-- yaw (radians, 0 = -Z) and pitch (radians, + up) of a direction
function BeamMath.YawPitch(v: Vector3): (number, number)
	local u = if v.Magnitude > 1e-6 then v.Unit else Vector3.new(0, 0, -1)
	return math.atan2(-u.X, -u.Z), math.asin(math.clamp(u.Y, -1, 1))
end

function BeamMath.FromYawPitch(yaw: number, pitch: number): Vector3
	local c = math.cos(pitch)
	return Vector3.new(-math.sin(yaw) * c, math.sin(pitch), -math.cos(yaw) * c)
end

local function wrap(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end
BeamMath.Wrap = wrap

-- a direction held inside the ability's pitch limits (degrees)
function BeamMath.Clamp(v: Vector3, pitchMin: number, pitchMax: number): Vector3
	local yaw, pitch = BeamMath.YawPitch(v)
	return BeamMath.FromYawPitch(yaw, math.clamp(pitch, math.rad(pitchMin), math.rad(pitchMax)))
end

-- `cur` turned toward `want` by at most yawRate / pitchRate (degrees a second) over dt
function BeamMath.Step(cur: Vector3, want: Vector3, yawRate: number, pitchRate: number, dt: number): Vector3
	local cy, cp = BeamMath.YawPitch(cur)
	local wy, wp = BeamMath.YawPitch(want)
	local dy = wrap(wy - cy)
	local my = math.rad(yawRate) * dt
	local mp = math.rad(pitchRate) * dt
	return BeamMath.FromYawPitch(cy + math.clamp(dy, -my, my), cp + math.clamp(wp - cp, -mp, mp))
end

-- `cur` eased toward `want` (it closes `sharpness` of the gap a second, exponentially) but never
-- faster than yawRate / pitchRate: a turn that whips off and settles into its aim - never a linear
-- swing that stops dead, never faster than the server allows
function BeamMath.Ease(cur: Vector3, want: Vector3, yawRate: number, pitchRate: number, sharpness: number, dt: number): Vector3
	local cy, cp = BeamMath.YawPitch(cur)
	local wy, wp = BeamMath.YawPitch(want)
	local k = 1 - math.exp(-sharpness * dt)
	local dy = wrap(wy - cy) * k
	local dp = (wp - cp) * k
	local my = math.rad(yawRate) * dt
	local mp = math.rad(pitchRate) * dt
	return BeamMath.FromYawPitch(cy + math.clamp(dy, -my, my), cp + math.clamp(dp, -mp, mp))
end

-- where the beam leaves a body: the root's position, `offset` in the frame of the beam's yaw (the
-- caster faces its beam)
function BeamMath.Origin(rootPos: Vector3, aim: Vector3, offset: Vector3): Vector3
	local f = flat(aim)
	local frame = CFrame.lookAt(rootPos, rootPos + f)
	return frame:PointToWorldSpace(offset)
end

-- closest approach of the beam's line (from `o` along unit `d`, 0..len) and a body's axis (a to b):
-- (the distance between them, how far along the beam that is, the two closest points)
function BeamMath.LineToAxis(o: Vector3, d: Vector3, len: number, a: Vector3, b: Vector3): (number, number, Vector3, Vector3)
	-- (Ericson, closest points of two segments)
	local d1 = d * len
	local d2 = b - a
	local r = o - a
	local A = d1:Dot(d1)
	local E = d2:Dot(d2)
	local F = d2:Dot(r)
	local s, t
	if A <= 1e-8 then
		s = 0
		t = if E > 1e-8 then math.clamp(F / E, 0, 1) else 0
	else
		local C = d1:Dot(r)
		if E <= 1e-8 then
			t = 0
			s = math.clamp(-C / A, 0, 1)
		else
			local B = d1:Dot(d2)
			local den = A * E - B * B
			s = if den > 1e-8 then math.clamp((B * F - C * E) / den, 0, 1) else 0
			t = (B * s + F) / E
			if t < 0 then
				t = 0
				s = math.clamp(-C / A, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((B - C) / A, 0, 1)
			end
		end
	end
	local p = o + d1 * s
	local q = a + d2 * t
	return (p - q).Magnitude, s * len, p, q
end

-- a body's capsule axis (world) from its root frame
function BeamMath.Axis(cf: CFrame): (Vector3, Vector3)
	return cf:PointToWorldSpace(Vector3.new(0, BeamMath.BodyBottom, 0)), cf:PointToWorldSpace(Vector3.new(0, BeamMath.BodyTop, 0))
end

--[[ HOW WIDE THE BEAM IS DRAWN, and so how wide its hitbox is (the effects and the server share these):
	a factor (<= 1) of its full width. `shellD` is its full diameter now, `g` its Grow.
	  Room:  a floor or a wall closer than its edge narrows it - swollen, it is let into the ground it
	         tears up by a third of its radius at most
	  Short: a beam too short for its flare (a long teardrop out of the hands, never a disc) is thinner
	         in proportion ]]
function BeamMath.RoomFactor(shellD: number, g: number, room: number): number
	local give = 0.33 * math.clamp((g - 0.85) / 0.6, 0, 1)
	local capD = 2 * math.max(0.4, room - 0.05) / (1 - give)
	return math.min(1, capD / math.max(shellD, 1e-3))
end
function BeamMath.ShortFactor(shellD: number, total: number): number
	local nl = math.min(math.max(6, 2.2 * shellD), total * 0.45)
	if nl < 1.4 * shellD then
		return math.max(0, nl / (1.4 * shellD))
	end
	return 1
end
-- the room all round the beam's line (up, down and to both sides of it): measured where it flares, mid
-- run and near its end; surfaces within `keepOut` of its end are where it lands and don't count
function BeamMath.Room(origin: Vector3, d: Vector3, span: number, keepOut: number, world: (Vector3, Vector3) -> RaycastResult?, reach: number): number
	local side = d:Cross(Vector3.yAxis)
	side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
	local up = side:Cross(d).Unit
	local tip = origin + d * span
	local function probe(q: Vector3): number
		local least = reach
		for _, v in ipairs({ up, -up, side, -side }) do
			local hit = world(q, v * reach)
			if hit and (keepOut <= 0 or (hit.Position - tip).Magnitude > keepOut) then
				least = math.min(least, (hit.Position - q).Magnitude)
			end
		end
		return least
	end
	local room = probe(origin + d * math.min(span * 0.5, 4))
	if span > 6 then
		room = math.min(room, probe(origin + d * span * 0.5), probe(tip - d * math.min(span * 0.25, 6)))
	end
	return room
end

--[[ trace the beam. bodies = { { Key = any, Cf = CFrame } } (never the caster). world = the ray
	against the world (origin, vector) -> RaycastResult?. Returns
	  length   where it ends (studs from the origin)
	  normal   the surface it ends on (nil: open air at full range; a body: back along the beam)
	  stopper  the body it ends on (its Key), if a body
	  inBeam   { { Key, Along, Dist } } every body inside it up to its end, nearest first
	A body beside the beam (not on its core line) is in it only if no wall stands between the beam and
	it: the beam's body never reaches through a wall, a floor or a pillar. ]]
function BeamMath.Trace(origin: Vector3, dir: Vector3, range: number, hitRadius: number, stopRadius: number, bodies: { any }, world: (Vector3, Vector3) -> RaycastResult?): (number, Vector3?, any, { any }, RaycastResult?)
	local d = dir.Unit
	local length = range
	local normal: Vector3? = nil
	local wr = world(origin, d * range)
	if wr then
		length = (wr.Position - origin):Dot(d)
		normal = wr.Normal
	end
	local stopper = nil
	local cand = {}
	local R = BeamMath.BodyRadius
	for _, b in ipairs(bodies) do
		local a, top = BeamMath.Axis(b.Cf)
		local dist, along, _, onBody = BeamMath.LineToAxis(origin, d, length + R, a, top)
		local inside = dist <= R + hitRadius and along > 0
		if inside and dist > R * 0.5 then
			-- (from the beam's line - kept short of the wall it ends on - straight to the body)
			local from = origin + d * math.min(along, math.max(0, length - 0.3))
			if world(from, onBody - from) then
				inside = false
			end
		end
		if inside then
			table.insert(cand, { Key = b.Key, Along = along, Dist = dist })
			if dist <= R + stopRadius then
				-- its core meets this body: it ends on the body's near surface
				local stopAt = math.max(0.5, along - math.sqrt(math.max(0, (R + stopRadius) ^ 2 - dist * dist)) * 0.6)
				if stopAt < length then
					length = stopAt
					normal = -d
					stopper = b.Key
					wr = nil
				end
			end
		end
	end
	local inBeam = {}
	for _, c in ipairs(cand) do
		-- (the body it ends on is always in it: it ends ON that body's near surface, which is short of
		-- the body's own axis - the closest-approach point - so the reach test alone would drop the
		-- very body it is hitting. Any other body counts if its near side is before the end)
		if c.Key == stopper or c.Along - R <= length + 0.25 then
			table.insert(inBeam, c)
		end
	end
	table.sort(inBeam, function(x, y)
		return x.Along < y.Along
	end)
	return length, normal, stopper, inBeam, wr
end

return BeamMath
