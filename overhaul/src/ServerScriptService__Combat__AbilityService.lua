--[[
	AbilityService  (ServerScriptService.Combat.AbilityService)
	The server side of every ability (ReplicatedStorage.Abilities.AbilityConfig). A client only ever
	ASKS: "cast the ability on my slot N, aiming this way" (CombatServer: "Ability"), and while it casts
	"I'm aiming this way now" ("AbilityAim"). Everything else is decided here:

	  who      a living fighter whose hero has that ability on that slot, in a state the ability may
	           start from (the fight's own state machine: CombatStates), allowed to fight where it
	           stands (Service.CombatAllowed: the lobby is a sanctuary), with its cooldown run out, its
	           hands free (not on a wall or over a vault) and an arm to cast with
	  what     the cast is the CASTING state: rooted, no strikes / dashes / guard; anything that takes
	           control (a stun, a guard break, a knockdown, death, the character going) ends it here and
	           everywhere at once - the cast is interrupted (a charge that never went off costs only
	           FizzleCooldown)
	  when     its timeline (AbilityConfig Timeline) runs on the server's own clock from the moment the
	           press was made (the caster's latency taken off), so its release lands when the caster's
	           own screen showed it
	  where    the aim the caster reports is only a wish: the server turns its own aim toward it at the
	           ability's capped rates and pitch limits, and publishes it (the AbilityAim attribute:
	           every screen draws the beam along it)
	  hits     the server's own (a Runner per kind of ability: "Beam" traces its beam every tick against
	           the bodies as the caster saw them), applied through the fight's one damage path
	           (CombatService applyHit: guard, stun budget, knockback, gore, kills, the hit broadcast)

	Events to every client (CombatEvent "Ability"):
	  { K = "Start", A = caster, Id, Seq, T0 (server time the cast began), Aim }
	  { K = "Stop", A = caster, Id, Seq, Why = "Interrupted" | "Done", Fired = bool }
	The caster gets an Ack for its request (Kind = "Ability"): Ok, Action = the ability id, Why.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Rules = require(CombatFolder:WaitForChild("ComboRules"))
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent
local AbilitiesFolder = ReplicatedStorage:WaitForChild("Abilities")
local AbilityConfig = require(AbilitiesFolder:WaitForChild("AbilityConfig"))
local BeamMath = require(AbilitiesFolder:WaitForChild("BeamMath"))

local AbilityService = {}

local Service: any = nil -- CombatService
local A: any = nil -- its ability API (CombatService._ability)

-- the casts running now (one per fighter at most)
local casts: { [any]: any } = {}

local AIM_PUBLISH = 1 / 20 -- the published aim changes at most this often
local TURN_SLACK = 1.15 -- the server's aim turns this much faster than the caster's own (jitter)

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function finiteUnit(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z or v.Magnitude < 0.5 or v.Magnitude > 2 then
		return nil
	end
	return v.Unit
end

local function combatAllowed(e: any): boolean
	return Service.CombatAllowed == nil or Service.CombatAllowed(e)
end

local function heroOf(e: any): string?
	if e.Player then
		local h = e.Player:GetAttribute("Hero")
		return if type(h) == "string" and h ~= "" then h else nil
	end
	local h = e.Char:GetAttribute("Hero")
	return if type(h) == "string" and h ~= "" then h else nil
end

local function cooldownLeft(e: any, id: string): number
	local cd = e.AbilityCD
	return if cd and cd[id] then math.max(0, cd[id] - A.now()) else 0
end

local function setCooldown(e: any, id: string, seconds: number)
	e.AbilityCD = e.AbilityCD or {}
	e.AbilityCD[id] = A.now() + seconds
	A.setCooldown(e, AbilityConfig.CooldownKey(id), seconds)
end

local function publishAim(cast: any, force: boolean?)
	local t = A.now()
	if not force and t - (cast.AimAt or -1) < AIM_PUBLISH then
		return
	end
	local last = cast.Published
	if not force and last and last:Dot(cast.Aim) > math.cos(math.rad(0.4)) then
		return
	end
	cast.AimAt = t
	cast.Published = cast.Aim
	cast.E.Char:SetAttribute("AbilityAim", cast.Aim)
end

local function clearCaster(e: any)
	e.Casting = nil
	e.BeamDir = nil
	e.BeamBlast = nil
	if e.Char.Parent then
		e.Char:SetAttribute("AbilityAim", nil)
		e.Char:SetAttribute("Casting", nil)
	end
end

-- the cast is over: Why = "Done" (it ran its course) or "Interrupted"
local function finish(cast: any, why: string)
	if cast.Over then
		return
	end
	cast.Over = true
	local e = cast.E
	if RunService:IsStudio() then
		print(string.format("[AbilityService] %s %s %s at %.2f (state %s, alive %s)", e.Char.Name, cast.Def.Id, why, A.now() - cast.Start, tostring(e.State), tostring(A.alive(e))))
	end
	if casts[e] == cast then
		casts[e] = nil
	end
	if e.Casting == cast then
		clearCaster(e)
	end
	if why ~= "Done" and not cast.Fired then
		-- the charge was lost before it went off: only a short cooldown
		local left = cooldownLeft(e, cast.Def.Id)
		local fizzle = cast.Def.FizzleCooldown or 0
		if left > fizzle then
			setCooldown(e, cast.Def.Id, fizzle)
		end
	end
	if e.Npc and e.AC then
		e.AC:Stop(cast.Def.Anim, if why == "Done" then 0.3 else 0.12)
	end
	Event:FireAllClients("Ability", { K = "Stop", A = e.Char, Id = cast.Def.Id, Seq = cast.Seq, Why = why, Fired = cast.Fired == true })
end

---------------------------------------------------------------------------
-- runners: one per kind of ability
---------------------------------------------------------------------------
local Runners = {}
AbilityService.Runners = Runners

-- a body may be hit by this caster: alive, hittable, allowed to fight where it is, not the caster
local function targets(e: any): { any }
	local list = {}
	for _, v in pairs(Service.Entities) do
		if v ~= e and A.hittable(v) and combatAllowed(v) then
			table.insert(list, { Key = v, Cf = A.seenFrame(e, v) })
		end
	end
	return list
end

-- BEAM: from Fire, a beam along the server's aim for Sustain seconds; a tick every Beam.Tick hits
-- every body in it (the TickAttack), the last moment bursts at its end (the BlastAttack)
Runners.Beam = {}
function Runners.Beam.Trace(cast: any): (Vector3, number, any, { any }, { any })
	local e, B = cast.E, cast.Def.Beam
	local origin = BeamMath.Origin(e.Root.Position, cast.Aim, B.Origin)
	-- (never the far side of a wall the caster stands against: it starts at the wall's face)
	local reach = origin - e.Root.Position
	if reach.Magnitude > 0.05 then
		local wall = A.worldRay(e.Root.Position, reach)
		if wall then
			origin = wall.Position - reach.Unit * 0.3
		end
	end
	local bodies = targets(e)
	local grow = AbilityConfig.BeamGrow(cast.Def, A.now() - cast.Start - cast.Def.Timeline.Fire)
	local len, _normal, _stopper, inBeam = BeamMath.Trace(origin, cast.Aim, B.Range, B.HitRadius * grow, B.StopRadius * math.sqrt(grow), bodies, A.worldRay)
	return origin, len, _stopper, inBeam, bodies
end

function Runners.Beam.Hit(cast: any, final: boolean)
	local e, B = cast.E, cast.Def.Beam
	local origin, len, _, inBeam, bodies = Runners.Beam.Trace(cast)
	local endPos = origin + cast.Aim * len
	local attack = Config.Attacks[if final then B.BlastAttack else B.TickAttack]
	if not attack then
		return
	end
	local victims: { [any]: Vector3 } = {}
	local order = {}
	for _, c in ipairs(inBeam) do
		local v = c.Key
		if not victims[v] then
			-- where it lands: on the body's surface facing the beam
			local onLine = origin + cast.Aim * math.min(c.Along, len)
			local toBody = v.Root.Position - onLine
			local side = Vector3.new(toBody.X, 0, toBody.Z)
			local contact = onLine + (if side.Magnitude > 0.05 then side.Unit * math.min(side.Magnitude, 0.6) else Vector3.zero)
			victims[v] = contact
			table.insert(order, v)
		end
	end
	if final then
		-- the burst at its end reaches everyone round it (never through a wall)
		for _, b in ipairs(bodies) do
			local v = b.Key
			if not victims[v] then
				local p = b.Cf.Position
				if (p - endPos).Magnitude <= B.BlastRadius * AbilityConfig.BeamGrow(cast.Def, cast.Def.Timeline.Sustain) + BeamMath.BodyRadius then
					local from = endPos - cast.Aim * 0.6
					local hit = A.worldRay(from, p - from)
					if not hit then
						victims[v] = p:Lerp(endPos, 0.35)
						table.insert(order, v)
					end
				end
			end
		end
		e.BeamBlast = endPos
	end
	e.BeamDir = cast.Aim
	local landed = false
	local dbg = if RunService:IsStudio() then {} else nil
	for _, v in ipairs(order) do
		local before = v.Hum.Health
		if A.hittable(v) then
			cast.HitSerial += 1
			local job = {
				Slot = 0, Seq = nil, ChainId = cast.ChainId, Chain = Rules.New(), Start = A.now(),
				Serial = -cast.HitSerial, Stopped = true, Counted = false, Ability = cast.Def.Id,
			}
			A.applyHit(e, v, attack, victims[v], job)
			landed = true
		end
		if dbg then
			table.insert(dbg, string.format("%s %.0f->%.0f%s", v.Char.Name, before, v.Hum.Health, if A.hittable(v) then "" else " (unhittable)"))
		end
	end
	if dbg then
		cast.TickN = (cast.TickN or 0) + 1
		local line = string.format("[AbilityService] %s %d at %.2f: len %.1f, %d bodies, in beam %d | %s", if final then "BLAST" else "tick", cast.TickN, A.now() - cast.Start, len, #bodies, #inBeam, table.concat(dbg, ", "))
		print(line)
		-- (the last few, on the workspace: a Studio overlay can show them without the Output window)
		local prev = workspace:GetAttribute("AbilityDbg")
		local lines = string.split(if type(prev) == "string" then prev else "", "\n")
		table.insert(lines, line)
		while #lines > 8 do
			table.remove(lines, 1)
		end
		workspace:SetAttribute("AbilityDbg", table.concat(lines, "\n"))
	end
	if landed then
		A.fought(e)
	end
	e.BeamBlast = nil
end

function Runners.Beam.Step(cast: any, tau: number)
	local T, B = cast.Def.Timeline, cast.Def.Beam
	if tau < T.Fire then
		return
	end
	if not cast.Fired then
		cast.Fired = true
		cast.NextTick = T.Fire
	end
	local stop = T.Fire + T.Sustain
	while cast.NextTick and cast.NextTick <= tau and cast.NextTick < stop - 1e-3 do
		Runners.Beam.Hit(cast, false)
		cast.NextTick += B.Tick
	end
	if tau >= stop and not cast.Blasted then
		cast.Blasted = true
		cast.NextTick = nil
		Runners.Beam.Hit(cast, true)
	end
end

function Runners.Beam.Length(def: any): number
	local T = def.Timeline
	return T.Fire + T.Sustain + T.Recover
end

---------------------------------------------------------------------------
-- casting
---------------------------------------------------------------------------
local function refuse(e: any, seq: number, id: string?, why: string): (boolean, string)
	if RunService:IsStudio() then
		print("[AbilityService] refused", e and e.Char.Name, id, why, e and e.State)
	end
	if e and e.Player then
		Event:FireClient(e.Player, "Ack", { Seq = seq, Kind = "Ability", Ok = false, Action = id, Why = why })
	end
	return false, why
end

--[[ cast the ability on a slot (or an ability id, for NPCs and tests). aim = where the caster wants
	it to go (a unit vector: its own camera's aim); seq = its request number. Returns ok, why ]]
function AbilityService.Cast(e: any, slotOrId: string, aim: Vector3?, seqIn: number?): (boolean, string?)
	local seq: number = seqIn or 0
	if not (e and A.alive(e)) then
		return false, "Dead"
	end
	local def = AbilityConfig.Abilities[slotOrId]
	if not def then
		def = AbilityConfig.For(heroOf(e), slotOrId)
	elseif e.Player and AbilityConfig.SlotOf(heroOf(e), slotOrId) == nil then
		def = nil -- (a player casts only what its hero has)
	end
	if not def then
		return refuse(e, seq, nil, "Locked")
	end
	local runner = Runners[def.Runner]
	if not runner then
		return refuse(e, seq, def.Id, "Locked")
	end
	if not combatAllowed(e) then
		return refuse(e, seq, def.Id, "Sanctuary")
	end
	if casts[e] or e.State == "Casting" then
		return refuse(e, seq, def.Id, "Busy")
	end
	if not def.From[e.State] then
		return refuse(e, seq, def.Id, "Busy")
	end
	if A.parkourHands(e) then
		return refuse(e, seq, def.Id, "Busy")
	end
	if Config.ArmsAt(A.goreStage(e)) < 1 then
		return refuse(e, seq, def.Id, "NoArms")
	end
	-- (a little early is fine: the caster's clock ran the cooldown out a round trip ago)
	if cooldownLeft(e, def.Id) > 0.12 then
		return refuse(e, seq, def.Id, "Cooldown")
	end
	if def.Grounded and A.airborne(e) then
		-- the server's copy of a player's body trails its screen: one that has just landed there may
		-- still be a hair above the ground here
		local v = e.Root.AssemblyLinearVelocity
		local hit = A.worldRay(e.Root.Position, Vector3.new(0, -7, 0))
		if not hit or math.abs(v.Y) > 30 then
			return refuse(e, seq, def.Id, "Air")
		end
	end
	local P = def.Aim
	local want = finiteUnit(aim) or BeamMath.Flat(e.Root.CFrame.LookVector)
	want = BeamMath.Clamp(want, P.PitchMin, P.PitchMax)
	-- the cast starts where the caster pressed (its latency off the server's clock)
	local lat = A.latency(e)
	local t0 = A.now() - lat
	-- the combo it may end: cast in a live chain's window, it carries the chain on (its count, and the
	-- one-chain-per-stun rule's chain); otherwise it is a chain of its own
	local hits = e.ChainHits
	local carry = e.State == "ComboWindow"
	A.endChain(e)
	if carry then
		e.ChainHits = hits
	else
		e.ChainId += 1
	end
	local cast = {
		E = e,
		Def = def,
		Runner = runner,
		Seq = seq,
		Start = t0,
		Aim = want,
		Want = want,
		ChainId = e.ChainId,
		HitSerial = 0,
		Fired = false,
	}
	casts[e] = cast
	e.Casting = cast
	e.BeamDir = want
	A.setState(e, "Casting", nil, true)
	e.Char:SetAttribute("Casting", def.Id)
	setCooldown(e, def.Id, def.Cooldown)
	publishAim(cast, true)
	if e.Npc and e.AC then
		cast.Track = e.AC:Play(def.Anim, { Fade = def.Timeline.FadeIn, Restart = true })
	end
	Event:FireAllClients("Ability", { K = "Start", A = e.Char, Id = def.Id, Seq = seq, T0 = serverNow() - lat, Aim = want })
	if e.Player then
		Event:FireClient(e.Player, "Ack", { Seq = seq, Kind = "Ability", Ok = true, Action = def.Id })
	end
	return true, nil
end

-- a player's request (CombatServer: "Ability" { Seq, Slot, Aim })
function AbilityService.Request(player: Player, payload: any)
	local char = player.Character
	local e = char and Service.Get(char)
	if not e or type(payload) ~= "table" then
		return
	end
	local seq = if type(payload.Seq) == "number" and payload.Seq == payload.Seq and math.abs(payload.Seq) < 2 ^ 31 then payload.Seq else 0
	local slot = payload.Slot
	if type(slot) ~= "string" or not table.find(AbilityConfig.Slots, slot) then
		refuse(e, seq, nil, "Locked")
		return
	end
	AbilityService.Cast(e, slot, payload.Aim, seq)
end

-- where the caster aims now (CombatServer: "AbilityAim" { Seq, Aim }) - a wish the server's aim turns toward
function AbilityService.Aim(player: Player, payload: any)
	local char = player.Character
	local e = char and Service.Get(char)
	local cast = e and casts[e]
	if not cast or type(payload) ~= "table" or payload.Seq ~= cast.Seq then
		return
	end
	local v = finiteUnit(payload.Aim)
	if v then
		cast.Want = BeamMath.Clamp(v, cast.Def.Aim.PitchMin, cast.Def.Aim.PitchMax)
	end
end

-- the cast in progress (nil: none)
function AbilityService.Casting(e: any): any
	return casts[e]
end

-- end a fighter's cast now (the fight took it: CombatService calls this from anything that ends Casting)
function AbilityService.Interrupt(e: any)
	local cast = casts[e]
	if cast then
		finish(cast, "Interrupted")
	end
end

local lastStep = os.clock()
local function step()
	local t = A.now()
	local dt = math.min(t - lastStep, 0.1)
	lastStep = t
	for e, cast in pairs(casts) do
		if cast.Over then
			casts[e] = nil
			continue
		end
		-- anything that took the body ends the cast: a stun, a guard break, a knockdown, death, the
		-- character gone - or a fight no longer allowed where it stands
		if not A.alive(e) or e.State ~= "Casting" or e.Casting ~= cast or not combatAllowed(e) then
			finish(cast, "Interrupted")
			if e.State == "Casting" and A.alive(e) then
				A.setState(e, "Idle", nil, true)
			end
			continue
		end
		local def = cast.Def
		local T, P = def.Timeline, def.Aim
		local tau = t - cast.Start
		local ntr = cast.Track
		if typeof(ntr) == "Instance" and ntr:IsA("AnimationTrack") and ntr.IsPlaying and ntr.TimePosition < T.Hold then
			ntr:AdjustSpeed(AbilityConfig.ClipSpeed(T, tau, ntr.TimePosition))
		end
		-- the aim: turned toward the caster's wish at the ability's rates (fast while gathering, slow
		-- once it has gone off)
		local yawRate = (if tau < (P.SnapTurn or 0) + 0.15 then 2000 elseif tau < T.Fire then P.ChargeTurn else P.BeamTurn) * TURN_SLACK
		-- (eased the way the caster's own screen eases it, so the hits follow the beam it sees)
		local sharp = if tau < (P.SnapTurn or 0) + 0.15 then 45 elseif tau < T.Fire then 22 else 7
		cast.Aim = BeamMath.Ease(cast.Aim, cast.Want, yawRate, P.PitchRate * TURN_SLACK, sharp, dt)
		e.BeamDir = cast.Aim
		publishAim(cast)
		cast.Runner.Step(cast, tau)
		if tau >= cast.Runner.Length(def) then
			-- (finished first: the state going back to Idle then finds no cast to interrupt)
			finish(cast, "Done")
			A.setState(e, "Idle", nil, true)
		end
	end
end

function AbilityService.Init(service: any)
	Service = service
	A = service._ability
	-- the fight ends a cast the moment it takes the body (setState away from Casting)
	service.OnCastEnd = function(e: any)
		AbilityService.Interrupt(e)
	end
	RunService.Heartbeat:Connect(step)
	if RunService:IsStudio() then
		-- (Studio testing: ServerStorage.AbilityDebugCast:Fire(model, id?, aim?) casts as that fighter -
		-- a dummy's cast is seen down the other-screens path)
		local ev = Instance.new("BindableEvent")
		ev.Name = "AbilityDebugCast"
		ev.Event:Connect(function(model: any, id: string?, aim: Vector3?)
			local v = Service.Entities[model]
			if v then
				print("[AbilityService] debug cast", model.Name, AbilityService.Cast(v, id or "AzureTideCannon", aim))
			end
		end)
		ev.Parent = game:GetService("ServerStorage")
	end
	Players.PlayerRemoving:Connect(function(p)
		for e, cast in pairs(casts) do
			if e.Player == p then
				finish(cast, "Interrupted")
			end
		end
	end)
end

return AbilityService
