--[[
	ComboRules  (ReplicatedStorage.Combat.ComboRules)
	The combo as a small state machine, shared word for word by the server (authority) and the
	attacking client (prediction), so both always pick the same strike for the same input.

	Chain state (one per fighter):
	  Slot       strikes landed in this chain so far (0 = no chain)
	  Heavy      the chain already holds its one heavy (M2)
	  Lights     lights used so far (they run Swing1, Swing2, Swing3 in order)
	  Last       the strike just started, and its kind ("Light" / "Heavy" / "Finisher")
	  OpenAt     the next strike may start from here (the current strike's chain point)
	  CloseAt    ...and must start by here, or the chain is over (OpenAt + Window)
	  CooldownUntil  after a finisher, no new chain until then

	Rules:
	  - M1 continues with the next light, or with the sweep when the next slot is the last one.
	  - M2 inserts the uppercut at any slot before the finisher and makes the chain 5 long; a second
	    M2 in the same chain is refused (the chain carries on with M1).
	  - Starting later than CloseAt starts a fresh chain; pressing before OpenAt is "early" (the
	    client keeps it in its buffer when it is within Config.Combo.Buffer of OpenAt).
	  - A fighter that has lost an arm (its gore stage, Config.Gore) never chains: M1 / M2 throw one
	    strike with the hand it has left (Config.Gore.OneArm), which ends the chain like a finisher.
	    The next may start once that strike's victim has had OneArm.Breathe of control back before
	    it could land (Rules.SingleGap): never a true combo. With no arms a press does nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local C = Config.Combo
local Rules = {}

export type Chain = {
	Slot: number,
	Heavy: boolean,
	Lights: number,
	Last: string?,
	LastKind: string?,
	OpenAt: number,
	CloseAt: number,
	CooldownUntil: number,
}

function Rules.New(): Chain
	return { Slot = 0, Heavy = false, Lights = 0, Last = nil, LastKind = nil, OpenAt = 0, CloseAt = 0, CooldownUntil = 0 }
end

function Rules.Reset(c: Chain)
	c.Slot = 0
	c.Heavy = false
	c.Lights = 0
	c.Last = nil
	c.LastKind = nil
	c.OpenAt = 0
	c.CloseAt = 0
end

function Rules.Length(heavy: boolean): number
	return if heavy then C.HeavyLength else C.LightLength
end

-- is a chain running at time t (could the next press continue it)?
function Rules.Live(c: Chain, t: number, slack: number?): boolean
	return c.Slot > 0 and t <= c.CloseAt + (slack or 0)
end

--[[ what a press of `kind` ("Light" / "Heavy") does at time t.
	Returns verdict, attack, slot, heavy, lights:
	  "go"     start `attack` as strike number `slot` (heavy/lights = the chain after it)
	  "early"  the chain point hasn't come yet (buffer it)
	  "no"     nothing (finisher cooldown, or a second heavy)
	slack widens every edge (server). want = the slot the client says it is playing: right at the
	reset edge it decides between "carry on" and "start over", never anything else. stage = the
	fighter's gore stage (lost arms: see the rules above). ]]
function Rules.Decide(c: Chain, kind: string, t: number, slack: number?, want: number?, stage: number?): (string, string?, number?, boolean?, number?)
	local s = slack or 0
	if t < c.CooldownUntil - s then
		return "no"
	end
	local arms = if Config.Gore.Enabled then Config.ArmsAt(stage) else 2
	if arms == 0 then
		return "no"
	elseif arms == 1 then
		if c.Slot > 0 and t <= c.CloseAt + s and t < c.OpenAt - s then
			return "early" -- (the arm went mid-chain: the strike that owns the body runs to its chain point)
		end
		local one = Config.Gore.OneArm
		return "go", if kind == "Heavy" then one.Heavy else one.Light, 1, false, 0
	end
	local live = c.Slot > 0 and t <= c.CloseAt + s
	if live and want == 1 and t >= c.CloseAt - s then
		live = false -- the client saw the chain run out
	end
	if live and want and want > 1 and want ~= c.Slot + 1 then
		-- the client is on a different count than we are: ours stands
		want = nil
	end
	local slot, heavy, lights = 1, false, 0
	if live then
		if t < c.OpenAt - s then
			return "early"
		end
		slot, heavy, lights = c.Slot + 1, c.Heavy, c.Lights
	elseif c.Slot > 0 and want and want > 1 and t <= c.CloseAt + s * 2 then
		-- a late packet for a strike the client started inside the window
		slot, heavy, lights = c.Slot + 1, c.Heavy, c.Lights
	end
	if kind == "Heavy" then
		if heavy then
			return "no" -- one heavy per combo
		end
		return "go", C.Heavy, slot, true, lights
	end
	if slot >= Rules.Length(heavy) then
		return "go", C.Finisher, slot, heavy, lights
	end
	return "go", C.Lights[math.clamp(lights + 1, 1, #C.Lights)], slot, heavy, lights + 1
end

-- a one-handed strike's own rhythm (seconds from its start to the next one's): past its chain point,
-- and long enough that its victim - hit clean, held the longest it can be (stun + hit-stop) - has
-- OneArm.Breathe of control back before the next one-handed strike could land. So no two of them
-- are ever a true combo, and they still come as fast as that allows
function Rules.SingleGap(def: any): number
	local one = Config.Gore.OneArm
	local soonest = math.huge
	for _, n in ipairs({ one.Light, one.Heavy }) do
		soonest = math.min(soonest, Config.Attacks[n].HitReal)
	end
	local held = def.HitReal + (def.Stun or 0) + (if def.ClassDef then def.ClassDef.Hitstop or 0 else 0)
	return math.max(def.ChainReal, held + one.Breathe - soonest)
end

-- record a strike that started at `start` (chain point / window from its own timing). stage = the
-- fighter's gore stage: a one-armed fighter's strike stands alone (the chain ends with it)
function Rules.Commit(c: Chain, attack: string, slot: number, heavy: boolean, lights: number, start: number, stage: number?)
	local def = Config.Attacks[attack]
	local single = Config.Gore.Enabled and Config.ArmsAt(stage) < 2
	if attack == C.Finisher or single then
		Rules.Reset(c)
		c.CooldownUntil = start + (if single then Rules.SingleGap(def) else def.LengthReal + C.FinisherCooldown)
		c.Last = attack
		c.LastKind = "Finisher"
		return
	end
	c.Slot = slot
	c.Heavy = heavy
	c.Lights = lights
	c.Last = attack
	c.LastKind = if attack == C.Heavy then "Heavy" else "Light"
	c.OpenAt = start + def.ChainReal
	c.CloseAt = c.OpenAt + C.Window
end

-- push the chain's timing back (hit-stop froze the strike for `dt`)
function Rules.Delay(c: Chain, dt: number)
	if c.Slot > 0 then
		c.OpenAt += dt
		c.CloseAt += dt
	end
end

-- the strikes that could follow the current one (for hitstun that guarantees the true combo)
function Rules.Followups(c: Chain): { string }
	if c.Slot == 0 then
		return {}
	end
	local list = {}
	local nextSlot = c.Slot + 1
	if nextSlot >= Rules.Length(c.Heavy) then
		table.insert(list, C.Finisher)
	elseif c.Lights < #C.Lights then
		table.insert(list, C.Lights[c.Lights + 1])
	end
	if not c.Heavy then
		table.insert(list, C.Heavy)
	end
	return list
end

-- hitstun a strike needs so every possible follow-up lands before the victim can act. The follow-up
-- starts at this strike's chain point and enters its own clip where the pair's transition says
-- (Config.Transitions), so its impact comes (Hit - Enter) / Speed after that
function Rules.CoverStun(c: Chain, def: any): number
	local best = 0
	for _, name in ipairs(Rules.Followups(c)) do
		local nd = Config.Attacks[name]
		local _, enter = Config.Transition(def.Id, name)
		local gap = (def.ChainReal - def.HitReal) + (nd.Hit - enter) / nd.Speed + (def.ClassDef.Hitstop or 0)
		best = math.max(best, gap)
	end
	if best == 0 then
		return 0
	end
	return best + C.StunMargin
end

-- THE BLOW'S VERDICT on the attacker's own screen, from what that screen showed of the victim when
-- the blow landed there. The server judges the very same facts as of that same moment
-- (CombatService: THE GUARD AND THE ESCAPE WINDOW), so the two always agree.
--   seen = { Blocking (its guard up on this screen), GuardFor (seconds it has been up here), Facing
--            (it faces the attacker), Escape (its Escape attribute), Restarted (a new chain of this
--            attacker on a body its last chain stunned, hardly back in control) }
-- Returns guarded, guard break, held (in its escape window or reset-locked: no stun, no launch)
function Rules.Verdict(def: any, seen: any): (boolean, boolean, boolean)
	local guarded = seen.Blocking == true and seen.Facing == true and (seen.GuardFor or 0) >= Config.Guard.StartDelay
	local held = seen.Escape == true or seen.Restarted == true
	return guarded, guarded and def.GuardBreak == true and not held, held
end

-- THE INPUT BUFFER (the attacking client): one press remembered at a time - the newest - with
-- when it was made and the chain it was meant for.
export type Buffered = { Kind: string, At: number, Chain: number }
function Rules.BufferPress(kind: string, t: number, chain: number): Buffered
	return { Kind = kind, At = t, Chain = chain }
end

--[[ may this spot use the buffered press? kinds = the presses it takes ({ Light = true, ... }),
	chain = the chain it must have been meant for (nil: any). A strike press is good for
	Config.Combo.Buffer + 0.1 s, a dash press for dashLimit. Returns (kind or nil, drop):
	drop = true means the press is spent or stale and must be forgotten; a press of a kind this spot
	doesn't take is kept for the one that does. ]]
function Rules.BufferTake(b: Buffered?, kinds: { [string]: boolean }, t: number, chain: number?, dashLimit: number): (string?, boolean)
	if not b or not kinds[b.Kind] then
		return nil, false
	end
	local limit = if b.Kind == "Dash" then dashLimit else C.Buffer + 0.1
	if t - b.At > limit or (chain ~= nil and b.Chain ~= chain) then
		return nil, true
	end
	return b.Kind, true
end

return Rules
