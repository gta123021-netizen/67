--[[
	HitDetect  (ReplicatedStorage.Combat.HitDetect)
	Geometry for the strikes' hitboxes - shared: the server judges every strike with it, and the
	attacking client runs the very same test on its own screen to put the impact (hit-stop, sound,
	effects, camera, the carry) on the exact frame the limb meets the body, without waiting a round
	trip for the server's word (which still decides damage, stun and knockback).

	A striking limb is a capsule (joint end -> tip) following its measured path through the attack's
	active frames (CombatPaths, from the pack's keyframes); a fighter's body is a box in its own
	space. Between two frames the tip's swept path is tested as well, so a limb that snaps a long way
	in one frame (the pack's punches do) can't skip a body.

	Lost arms (Config.Gore) count on both sides: a body missing an arm is only as wide as its torso
	on that side (Config.Hitbox.ArmlessHalfWidth), and a strike never lands with a limb its thrower
	has lost (that limb's capsule is skipped). The attacking client and the server pass the same
	gore stages, so they still agree.

	The capsule's rounded end sits on the limb's own end face: every measured segment is pulled in
	at the tip by Config.Hitbox.Shorten of the attack's radius, and the box and pad are sized so the
	whole thing reaches exactly as far as the real limb meets the real body (tools/contact.py: within
	~0.08 studs on every frame) - visible hit = hit, visible miss = miss.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Paths = require(CombatFolder:WaitForChild("CombatPaths"))

local HD = {}

-- every attack's path with its segments pulled in at the tip by a share of that attack's radius
local function shorten(a: Vector3, b: Vector3, r: number): Vector3
	local d = b - a
	local len = d.Magnitude
	if len < 1e-6 then
		return b
	end
	return a + d * (math.max(0, len - r) / len)
end
local shortened = {}
for key, path in pairs(Paths) do
	local def = Config.Attacks[key]
	local r = (if def then def.Hitbox or 0.5 else 0.5) * (if def and def.Shorten then def.Shorten else Config.Hitbox.Shorten or 1)
	local samples = {}
	for i, smp in ipairs(path.Samples) do
		local caps = {}
		for li, cap in ipairs(smp[2]) do
			caps[li] = { cap[1], shorten(cap[1], cap[2], r) }
		end
		samples[i] = { smp[1], caps }
	end
	shortened[key] = { From = path.From, To = path.To, Limbs = path.Limbs, Samples = samples }
end
HD.Paths = shortened
HD.RawPaths = Paths

local BODY = Config.Hitbox.Body

-- the body box's half widths to its left (-X) and right (+X) at a gore stage: a lost arm's side
-- ends at the torso (the right arm goes first, then the left)
export type Shape = { L: number, R: number }
local WHOLE: Shape = { L = BODY.HalfWidth, R = BODY.HalfWidth }
local SHAPES: { Shape } = {
	{ L = BODY.HalfWidth, R = Config.Hitbox.ArmlessHalfWidth or 1.1 },
	{ L = Config.Hitbox.ArmlessHalfWidth or 1.1, R = Config.Hitbox.ArmlessHalfWidth or 1.1 },
}
function HD.BodyFor(stage: number?): Shape
	if not Config.Gore.Enabled or not stage or stage < 1 then
		return WHOLE
	end
	return SHAPES[math.min(stage, 2)]
end

-- the limbs a thrower at a gore stage no longer has
local LOST = { {}, { ["Right Arm"] = true }, { ["Right Arm"] = true, ["Left Arm"] = true } }
function HD.LostLimbs(stage: number?): { [string]: boolean }
	if not Config.Gore.Enabled or not stage or stage < 1 then
		return LOST[1]
	end
	return LOST[math.min(stage, 2) + 1]
end

-- distance from a point (in the body's own space) to the body box
local function pointBox(p: Vector3, shape: Shape?): number
	local sh = shape or WHOLE
	local dx = if p.X >= 0 then math.max(p.X - sh.R, 0) else math.max(-p.X - sh.L, 0)
	local dy = math.max(BODY.Bottom - p.Y, p.Y - BODY.Top, 0)
	local dz = math.max(math.abs(p.Z) - BODY.HalfDepth, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- closest approach of a segment (body space) to the body box, and where along it
local function segmentBox(a: Vector3, b: Vector3, shape: Shape?): (number, Vector3)
	local len = (b - a).Magnitude
	local n = math.clamp(math.ceil(len / 0.3), 1, 24)
	local best, at = math.huge, a
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		local d = pointBox(p, shape)
		if d < best then
			best, at = d, p
		end
	end
	return best, at
end
HD.SegmentBox = segmentBox

-- the limb capsules at clip time tau (interpolated between the measured frames), attacker space
function HD.CapsulesAt(key: string, tau: number): { { Vector3 } }?
	local path = shortened[key]
	if not path then
		return nil
	end
	local s = path.Samples
	if tau <= s[1][1] then
		return s[1][2]
	end
	if tau >= s[#s][1] then
		return s[#s][2]
	end
	for i = 1, #s - 1 do
		local a, b = s[i], s[i + 1]
		if tau >= a[1] and tau <= b[1] then
			local k = (tau - a[1]) / math.max(b[1] - a[1], 1e-6)
			local out = {}
			for li, capA in ipairs(a[2]) do
				local capB = b[2][li]
				out[li] = { capA[1]:Lerp(capB[1], k), capA[2]:Lerp(capB[2], k) }
			end
			return out
		end
	end
	return s[#s][2]
end

-- the clip times to test between two moments: both ends plus every measured frame in between
function HD.TimesBetween(key: string, fromTau: number, toTau: number): { number }
	local path = shortened[key]
	local list = { fromTau }
	if path then
		for _, smp in ipairs(path.Samples) do
			if smp[1] > fromTau + 1e-4 and smp[1] < toTau - 1e-4 then
				table.insert(list, smp[1])
			end
		end
	end
	if toTau > fromTau + 1e-4 then
		table.insert(list, toTau)
	end
	return list
end

-- a low strike (the sweep) follows the ground: on a slope or a step its leg sweeps at the victim's
-- shin height, not at the height of the attacker's own feet. The limb's low points are lifted by
-- the difference between the two bodies' heights (roots stand the same height over their feet),
-- capped at MAX_LIFT; points above the waist are untouched.
local MAX_LIFT = 1.4
function HD.GroundLift(key: string, attackCf: CFrame, bodyCf: CFrame): number
	local def = Config.Attacks[key]
	if not (def and def.FollowGround) then
		return 0
	end
	return math.clamp(bodyCf.Position.Y - attackCf.Position.Y, -MAX_LIFT, MAX_LIFT)
end

local function lifted(caps: { { Vector3 } }, lift: number): { { Vector3 } }
	if lift == 0 then
		return caps
	end
	local out = {}
	for i, cap in ipairs(caps) do
		local function up(p: Vector3): Vector3
			local k = math.clamp((-p.Y - 1.0) / 1.2, 0, 1) -- 0 above the hips, 1 at the feet
			return p + Vector3.new(0, lift * k, 0)
		end
		out[i] = { up(cap[1]), up(cap[2]) }
	end
	return out
end

--[[ does the strike touch this body between clip times t0 and t1?
	attackCf: the attacker's frame (flat facing); bodyCf: the victim's root frame (flat facing)
	radius: the limb's radius (+ pad). victimStage / attackerStage: their gore stages (a lost arm's
	side of the body is narrower; a lost limb never lands). Returns hit?, contact point (world) ]]
function HD.Sweep(key: string, attackCf: CFrame, bodyCf: CFrame, t0: number, t1: number, radius: number, victimStage: number?, attackerStage: number?): (boolean, Vector3?)
	local shape = HD.BodyFor(victimStage)
	local lost = HD.LostLimbs(attackerStage)
	local limbs = shortened[key] and shortened[key].Limbs or {}
	local times = HD.TimesBetween(key, t0, t1)
	local toBody = bodyCf:Inverse() * attackCf -- attacker space -> body space
	local lift = HD.GroundLift(key, attackCf, bodyCf)
	local prev: { { Vector3 } }? = nil
	for _, tau in ipairs(times) do
		local raw = HD.CapsulesAt(key, tau)
		local caps = if raw then lifted(raw, lift) else nil
		if caps then
			for li, cap in ipairs(caps) do
				if not lost[limbs[li] or ""] then
					local a = toBody * cap[1]
					local b = toBody * cap[2]
					local d, at = segmentBox(a, b, shape)
					if d <= radius then
						return true, bodyCf * at
					end
					-- the tip's path since the previous frame (a fast snap sweeps through the body)
					if prev and prev[li] then
						local pa = toBody * prev[li][2]
						local d2, at2 = segmentBox(pa, b, shape)
						if d2 <= radius then
							return true, bodyCf * at2
						end
					end
				end
			end
			prev = caps
		end
	end
	return false, nil
end

-- the strike's radius (limb + pad)
function HD.Radius(key: string): number
	local def = Config.Attacks[key]
	return (if def then def.Hitbox or 0.5 else 0.5) + Config.Hitbox.Pad
end

-- the closest the strike gets to this body between two clip times (debugging / tuning)
function HD.Closest(key: string, attackCf: CFrame, bodyCf: CFrame, t0: number, t1: number): number
	local best = math.huge
	local toBody = bodyCf:Inverse() * attackCf
	local lift = HD.GroundLift(key, attackCf, bodyCf)
	local prev: { { Vector3 } }? = nil
	for _, tau in ipairs(HD.TimesBetween(key, t0, t1)) do
		local raw = HD.CapsulesAt(key, tau)
		local caps = if raw then lifted(raw, lift) else nil
		if caps then
			for li, cap in ipairs(caps) do
				best = math.min(best, (segmentBox(toBody * cap[1], toBody * cap[2])))
				if prev and prev[li] then
					best = math.min(best, (segmentBox(toBody * prev[li][2], toBody * cap[2])))
				end
			end
			prev = caps
		end
	end
	return best
end

return HD
