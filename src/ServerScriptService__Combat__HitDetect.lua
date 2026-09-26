--[[
	HitDetect  (ServerScriptService.Combat.HitDetect)
	Geometry for the strikes' hitboxes. A striking limb is a capsule (joint end -> tip) following
	its measured path through the attack's active frames (CombatPaths, from the pack's keyframes);
	a fighter's body is a box in its own space. Between two frames the tip's swept path is tested
	as well, so a limb that snaps a long way in one frame (the pack's punches do) can't skip a body.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Paths = require(CombatFolder:WaitForChild("CombatPaths"))

local HD = {}
HD.Paths = Paths

local BODY = Config.Hitbox.Body

-- distance from a point (in the body's own space) to the body box
local function pointBox(p: Vector3): number
	local dx = math.max(math.abs(p.X) - BODY.HalfWidth, 0)
	local dy = math.max(BODY.Bottom - p.Y, p.Y - BODY.Top, 0)
	local dz = math.max(math.abs(p.Z) - BODY.HalfDepth, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- closest approach of a segment (body space) to the body box, and where along it
local function segmentBox(a: Vector3, b: Vector3): (number, Vector3)
	local len = (b - a).Magnitude
	local n = math.clamp(math.ceil(len / 0.3), 1, 24)
	local best, at = math.huge, a
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		local d = pointBox(p)
		if d < best then
			best, at = d, p
		end
	end
	return best, at
end
HD.SegmentBox = segmentBox

-- the limb capsules at clip time tau (interpolated between the measured frames), attacker space
function HD.CapsulesAt(key: string, tau: number): { { Vector3 } }?
	local path = Paths[key]
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
	local path = Paths[key]
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

--[[ does the strike touch this body between clip times t0 and t1?
	attackCf: the attacker's frame (flat facing); bodyCf: the victim's root frame (flat facing)
	radius: the limb's radius (+ pad). Returns hit?, contact point (world) ]]
function HD.Sweep(key: string, attackCf: CFrame, bodyCf: CFrame, t0: number, t1: number, radius: number): (boolean, Vector3?)
	local times = HD.TimesBetween(key, t0, t1)
	local toBody = bodyCf:Inverse() * attackCf -- attacker space -> body space
	local prev: { { Vector3 } }? = nil
	for _, tau in ipairs(times) do
		local caps = HD.CapsulesAt(key, tau)
		if caps then
			for li, cap in ipairs(caps) do
				local a = toBody * cap[1]
				local b = toBody * cap[2]
				local d, at = segmentBox(a, b)
				if d <= radius then
					return true, bodyCf * at
				end
				-- the tip's path since the previous frame (a fast snap sweeps through the body)
				if prev and prev[li] then
					local pa = toBody * prev[li][2]
					local d2, at2 = segmentBox(pa, b)
					if d2 <= radius then
						return true, bodyCf * at2
					end
				end
			end
			prev = caps
		end
	end
	return false, nil
end

-- the closest the strike gets to this body between two clip times (debugging / tuning)
function HD.Closest(key: string, attackCf: CFrame, bodyCf: CFrame, t0: number, t1: number): number
	local best = math.huge
	local toBody = bodyCf:Inverse() * attackCf
	local prev: { { Vector3 } }? = nil
	for _, tau in ipairs(HD.TimesBetween(key, t0, t1)) do
		local caps = HD.CapsulesAt(key, tau)
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
