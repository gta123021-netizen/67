--[[
	CombatChoreo  (ReplicatedStorage.Combat.CombatChoreo)
	How the bodies move through a chain - the same pure functions for the attacking client, the
	server's NPC fighters and the headless tests, so all three move a fighter identically.

	NO LOCK, NO HOMING. Everything here moves a fighter STRAIGHT ALONG ITS OWN FACING (the way its
	strike travels). Nothing ever turns a fighter toward anybody or pulls it sideways. The only thing
	another body changes is HOW FAR along that line a step goes: a strike's step stops where the body
	in its lane will meet the limb on the impact frame instead of walking through it, exactly like a
	dash stops in front of a body instead of passing through it. Somebody off to the side is simply
	not in the lane.

	  Choreo.Ahead(origin, dir, bodies, maxAlong)   distance (root to root, along dir) to the nearest
	                                                body in the lane ahead, or nil
	  Choreo.NewStep(def, enter, dir, now)           a strike's step-in, planned at its start
	  Choreo.StepSpeed(step, now, dt, along)          ...its speed this frame (along the step's Dir)
	  Choreo.NextGap(chain)                          the closest the next strike may start from, and its
	                                                natural step
	  Choreo.NewCarry(def, dir, now, hitstop, chain) the momentum after a clean chain strike
	  Choreo.CarrySpeed(carry, now, dt, along)        ...its speed this frame
	  Choreo.Velocity(state, now, dt, along)          the two summed (one drive carries both, so a new
	                                                strike's step never cuts off the last one's carry)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Rules = require(CombatFolder:WaitForChild("ComboRules"))

local Choreo = {}

local H = Config.Hitbox
local STEP_TOP = 38 -- studs/s: the fastest a step ever moves (a lunge, never a teleport)
local EASE_IN = 0.05 -- seconds: a step pushes off, it doesn't jump
local KEEP_GAIN = 12 -- 1/s: how quickly the carry settles at the next strike's distance

-- the nearest body ahead in the strike's lane: along the facing, within Config.Hitbox.Lane of the
-- line and LaneHeight above or below. bodies = root positions (Vector3). Returns the distance along
-- the facing, root to root (nil: nobody in the lane)
function Choreo.Ahead(origin: Vector3, dir: Vector3, bodies: { Vector3 }, maxAlong: number?): number?
	local best: number? = nil
	local limit = maxAlong or 12
	for _, p in ipairs(bodies) do
		local rel = p - origin
		if math.abs(rel.Y) <= H.LaneHeight then
			local flat = Vector3.new(rel.X, 0, rel.Z)
			local along = flat:Dot(dir)
			if along > 0.3 and along < limit and (flat - dir * along).Magnitude <= H.Lane then
				if not best or along < best then
					best = along
				end
			end
		end
	end
	return best
end

export type Step = { Dir: Vector3, T0: number, Dur: number, Base: number, Max: number, Ideal: number, Travelled: number }

-- a strike's step-in (nil: the strike has none). enter = the clip time it entered at (the pair's
-- transition); dir = its facing (flat, unit); now = when the clip started
function Choreo.NewStep(def: any, enter: number, dir: Vector3, now: number): Step?
	local st = def.Step
	if not st or st.Max <= 0 then
		return nil
	end
	local from = math.max(0, st.From - enter) / def.Speed
	local to = math.max(0, st.To - enter) / def.Speed
	return {
		Dir = dir,
		T0 = now + from,
		Dur = math.max(0.05, to - from),
		Base = st.Base,
		Max = st.Max,
		Ideal = def.Ideal,
		Travelled = 0,
	}
end

-- the step's speed (studs/s along its Dir) this frame. along = distance to the body ahead in the
-- lane right now (nil: nobody). With a body there the step closes on its Ideal distance, re-judged
-- every frame (a victim still sliding is followed straight down the lane - never turned toward);
-- with nobody there it is the strike's short Base step. Eases in, arrives just before the hit
function Choreo.StepSpeed(s: Step?, now: number, dt: number, along: number?): number
	if not s then
		return 0
	end
	local t = now - s.T0
	if t < 0 or t >= s.Dur then
		return 0
	end
	local remaining: number
	if along then
		remaining = math.max(0, along - s.Ideal)
	else
		remaining = math.max(0, s.Base - s.Travelled)
	end
	remaining = math.min(remaining, math.max(0, s.Max - s.Travelled))
	if remaining < 0.01 then
		return 0
	end
	local left = math.max(s.Dur - t, 1 / 60)
	local speed = math.min(remaining / left * 1.25, STEP_TOP) * math.min(1, t / EASE_IN + 0.15)
	s.Travelled += speed * dt
	return speed
end

-- the next strike of this chain: the farthest Ideal among its possible follow-ups (the closest it
-- may start from without crowding any of them) and that strike's natural step
function Choreo.NextGap(chain: any): (number?, number)
	local gap, base = nil, 0
	for _, name in ipairs(Rules.Followups(chain)) do
		local d = Config.Attacks[name]
		if d and (not gap or d.Ideal > gap) then
			gap = d.Ideal
			base = if d.Step then d.Step.Base else 0
		end
	end
	return gap, base
end

export type Carry = { Dir: Vector3, T0: number, Dur: number, Speed: number, Gap: number? }

-- the attacker's momentum after a clean chain strike: along its facing, a share of the victim's
-- slide sized so the next strike starts about one natural step short of its own Ideal. It never
-- brings the attacker closer than that strike's Ideal to the body ahead (the lagged copy of a
-- victim that hasn't started sliding yet on this screen is never walked into)
function Choreo.NewCarry(def: any, dir: Vector3, now: number, hitstop: number, chain: any): Carry?
	local push = def.PushDistance or 0
	if push <= 0.05 or (def.KnockTime or 0) <= 0 then
		return nil
	end
	local gap, base = Choreo.NextGap(chain)
	local want = if gap then push + def.Ideal - (gap + base) else push * 0.6
	local share = math.clamp(want / push, Config.Carry.Min, Config.Carry.Max)
	local dur = def.KnockTime + 0.06
	return {
		Dir = dir,
		T0 = now + hitstop,
		Dur = dur,
		Speed = push * share / (dur * Config.PushShare),
		Gap = gap,
	}
end

function Choreo.CarrySpeed(c: Carry?, now: number, dt: number, along: number?): number
	if not c then
		return 0
	end
	local t = now - c.T0
	if t < 0 or t >= c.Dur then
		return 0
	end
	local k = 1 - t / c.Dur
	local speed = c.Speed * (0.35 + 0.65 * k * k)
	if along and c.Gap then
		local room = along - c.Gap
		speed = if room <= 0 then 0 else math.min(speed, room * KEEP_GAIN)
	end
	return speed
end

-- both at once: state = { Step = Step?, Carry = Carry? }. Each moves along its OWN direction (a new
-- strike may face a new way; the old momentum still bleeds out along the old one)
function Choreo.Velocity(state: any, now: number, dt: number, aheadOf: (Vector3) -> number?): Vector3
	local v = Vector3.zero
	local s = state.Step
	if s then
		v += s.Dir * Choreo.StepSpeed(s, now, dt, aheadOf(s.Dir))
	end
	local c = state.Carry
	if c then
		v += c.Dir * Choreo.CarrySpeed(c, now, dt, aheadOf(c.Dir))
	end
	return v
end

-- how long the pair (step, carry) still wants to drive (seconds from now)
function Choreo.Remaining(state: any, now: number): number
	local left = 0
	if state.Step then
		left = math.max(left, state.Step.T0 + state.Step.Dur - now)
	end
	if state.Carry then
		left = math.max(left, state.Carry.T0 + state.Carry.Dur - now)
	end
	return left
end

return Choreo
