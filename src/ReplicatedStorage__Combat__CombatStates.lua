--[[
	CombatStates  (ReplicatedStorage.Combat.CombatStates)
	The one state machine every fighter runs (players and NPCs, server and owning client).
	A fighter is always in exactly one state; what it may do comes from that state, never from a
	pile of booleans. The server's copy is the authority; the owning client runs the same rules so
	it can act on input at once, and follows the server whenever they disagree.

	Idle          standing / walking / running / in the air (locomotion is a client concern)
	Attacking     a strike owns the character (start-up, impact, until its chain point)
	ComboWindow   between strikes of a live combo: free to act, the next strike continues the chain
	Blocking      guard up
	GuardBroken   guard shattered: no control, then a short wait before it can go up again
	Stunned       reacting to a hit
	Ragdolled     knocked down, limbs physical
	Recovering    getting up (movement returns partway, actions at the end; can't be hit)
	Dashing       a directional dash
	UsingAbility  an ability owns the character (CombatService.SetState / Lock)
	Dead
]]

local States = {}

for _, s in ipairs({ "Idle", "Attacking", "ComboWindow", "Blocking", "GuardBroken", "Stunned", "Ragdolled", "Recovering", "Dashing", "UsingAbility", "Dead" }) do
	States[s] = s
end
-- old names other scripts may still pass in
States.Alias = { Neutral = "Idle", Hitstunned = "Stunned", Locked = "UsingAbility" }

-- what each state allows. Attack = start/continue a strike (the chain rules decide which),
-- Move = walk/run, Jump, Turn = free facing (AutoRotate), Hittable = hitboxes find it,
-- Reacts = a hit plays a reaction/knockback (false: nothing lands at all while not Hittable).
local R = {}
local function rule(state, t)
	R[state] = t
end
rule("Idle", { Attack = true, Dash = true, Block = true, Move = true, Jump = true, Turn = true, Hittable = true, Reacts = true })
rule("Attacking", { Attack = true, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = true, Reacts = true })
rule("ComboWindow", { Attack = true, Dash = true, Block = true, Move = true, Jump = true, Turn = true, Hittable = true, Reacts = true })
rule("Blocking", { Attack = false, Dash = false, Block = true, Move = true, Jump = false, Turn = false, Hittable = true, Reacts = true }) -- the guard keeps facing while you shuffle
rule("GuardBroken", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = true, Reacts = true })
rule("Stunned", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = true, Reacts = true })
rule("Ragdolled", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = false, Reacts = false })
rule("Recovering", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = false, Reacts = false }) -- getting-up i-frames
rule("Dashing", { Attack = true, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = true, Reacts = true })
rule("UsingAbility", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = true, Reacts = true })
rule("Dead", { Attack = false, Dash = false, Block = false, Move = false, Jump = false, Turn = false, Hittable = false, Reacts = false })
States.Rules = R

-- the states in which the fighter is in control of itself (free, striking, guarding, dashing). Time
-- spent in them is what refills the stun budget (CombatService): stun, guard break, knockdown,
-- getting up and abilities that own the body are not control.
local CONTROL = { Idle = true, Attacking = true, ComboWindow = true, Blocking = true, Dashing = true }
States.Control = CONTROL
function States.HasControl(state: string): boolean
	return CONTROL[state] == true
end

-- legal transitions (from -> set of to). Anything not listed is refused (unless forced by the
-- server's own bookkeeping, e.g. death).
local T = {
	Idle = { "Attacking", "Dashing", "Blocking", "Stunned", "GuardBroken", "Ragdolled", "UsingAbility", "Dead" },
	Attacking = { "Idle", "Attacking", "ComboWindow", "Stunned", "GuardBroken", "Ragdolled", "UsingAbility", "Dead" },
	ComboWindow = { "Idle", "Attacking", "Dashing", "Blocking", "Stunned", "GuardBroken", "Ragdolled", "UsingAbility", "Dead" },
	Blocking = { "Idle", "Stunned", "GuardBroken", "Ragdolled", "UsingAbility", "Dead" },
	GuardBroken = { "Idle", "Stunned", "Ragdolled", "UsingAbility", "Dead" },
	Stunned = { "Idle", "Stunned", "Ragdolled", "GuardBroken", "UsingAbility", "Dead" },
	Ragdolled = { "Recovering", "Idle", "Dead" },
	Recovering = { "Idle", "Stunned", "UsingAbility", "Dead" },
	Dashing = { "Idle", "Attacking", "Stunned", "Ragdolled", "UsingAbility", "Dead" },
	UsingAbility = { "Idle", "Stunned", "Ragdolled", "UsingAbility", "Dead" },
	Dead = {},
}
local legal = {}
for from, list in pairs(T) do
	legal[from] = {}
	for _, to in ipairs(list) do
		legal[from][to] = true
	end
end

function States.Resolve(name: string): string
	return States.Alias[name] or name
end

function States.CanEnter(from: string, to: string): boolean
	local l = legal[from]
	return l ~= nil and l[to] == true
end

function States.Allows(state: string, what: string): boolean
	local r = R[state]
	return r ~= nil and r[what] == true
end

return States
