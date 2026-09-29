--[[
	CombatService  (ServerScriptService.Combat.CombatService)
	The authority. Every fighter (player or NPC) is an entity with one state (CombatStates) and one
	combo chain (ComboRules). Clients only ASK ("Attack", "Dash", "Block"); this module decides which
	strike happens, runs the striking limb's measured path through its active frames (HitDetect),
	and applies what connects.

	HIT REGISTRATION: THE ATTACKER'S SCREEN, VERIFIED. A player's strike is judged where it was
	thrown: its own client runs the very same geometry (HitDetect) against the bodies as that screen
	shows them and, on the frame its limb meets one, sends a claim ("Hit": the victim, the clip times,
	where both bodies stood on that screen) - or, if the active frames end without contact, a "Whiff".
	The server re-runs the exact test on those inputs after checking them against its own record:
	the attacker within a report's allowance of where the server has it, the victim on (or a hair
	off) the path its body really took over the rewind window, the frame inside the strike's active
	frames and one the attacker's clock has really reached, the way to the body clear of walls. So
	what the attacker saw land is what lands - no hit that flashes and is taken back, no hit that
	lands a moment later that screen never showed. The server's own sweep (rewound history + the
	attacker's position reports) still runs beside it and decides only when no word comes from the
	attacker's screen, or when a claim fails its checks. NPC strikes are the server's alone.

	A connecting strike, all in the server frame the limb reaches the body:
	  1 validated: the victim is hittable (its state: getting up is i-frames), the limb's way to the
	    contact point is clear of geometry, and this strike hasn't touched it yet (a punch stops on the
	    first body in its path: the nearest one its limb meets)
	  2 guard:     facing the attacker with the guard up -> blocked (25% damage, push, guard gives)
	               unless the strike breaks guards (the finisher sweep) -> guard break
	  3 damage, then reaction side (which way the blow drove the head), then hitstun long enough for
	    the slowest follow-up of the attacker's chain (paid from the victim's stun budget), knockback
	    straight along the ATTACKER'S FACING (the way the blow travels) / launch
	  4 hit-stop: the attacker's chain timing is pushed back by the freeze its clip takes
	  5 one "Hit" broadcast: every client plays the spark, sound, give and (the victim) reaction

	FREE-FORM. There is no target lock, no target ownership and no auto-facing: every strike tests
	every body its limb sweeps through, from wherever its attacker stands and faces. A chain holds
	together because its geometry does - the blow drives the victim straight along the attacker's
	facing, the attacker's momentum carries on along the same line (CombatChoreo), so the next strike
	finds the body where its limb lands.

	STUN BUDGET. Every fighter can only be held in hitstun for Config.StunBudget.Max seconds before it
	gets a real window to act (Config.StunImmunity): the budget refills only while the fighter has
	control. Together with "one chain per stun" (resetLocked) no restart - waiting out the window,
	block / dash / jump cancels, the uppercut re-opening, the Ground Smash, two or three attackers
	taking turns - can hold anyone forever, while a legitimate string always fits.

]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local States = require(CombatFolder:WaitForChild("CombatStates"))
local Rules = require(CombatFolder:WaitForChild("ComboRules"))
local Ragdoll = require(CombatFolder:WaitForChild("Ragdoll"))
local Motion = require(CombatFolder:WaitForChild("Motion"))
local AnimController = require(CombatFolder:WaitForChild("AnimController"))
local Choreo = require(CombatFolder:WaitForChild("CombatChoreo"))
local HitDetect = require(CombatFolder:WaitForChild("HitDetect"))
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent

local Service = {}

export type Entity = {
	DamageMul: number?, -- (blows it lands deal this many times their damage: the Brute Dummy)
	Char: Model,
	Hum: Humanoid,
	Root: BasePart,
	Player: Player?,
	Npc: boolean,
	State: string,
	StateSerial: number,
	StateUntil: number?,
	[string]: any,
}

local entities: { [Model]: Entity } = {}
Service.Entities = entities
local updateGore: (Entity) -> () -- (the limbs a fighter has lost: see below)
local stowTools: (Entity) -> ()

local STUDIO = RunService:IsStudio()
local SB = Config.StunBudget

-- collision groups: a torn-off arm (Debris, built on every client - CombatGore) rolls on the map but
-- never touches a fighter or another torn-off arm
do
	local PhysicsService = game:GetService("PhysicsService")
	local function group(name: string)
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	local ok, err = pcall(function()
		group("Fighters")
		group("Debris")
		PhysicsService:CollisionGroupSetCollidable("Debris", "Fighters", false)
		PhysicsService:CollisionGroupSetCollidable("Debris", "Debris", false)
	end)
	if not ok then
		warn("[Combat] collision groups:", err)
	end
end

-- every part of a fighter's body (and anything added to it later: accessories, the ragdoll rig)
-- is a Fighter, so a torn-off arm passes through bodies
local function fighterParts(char: Model): RBXScriptConnection
	local function set(p: Instance)
		if p:IsA("BasePart") then
			p.CollisionGroup = "Fighters"
		end
	end
	for _, d in ipairs(char:GetDescendants()) do
		set(d)
	end
	return char.DescendantAdded:Connect(set)
end

local ATTACK_ANIMS = { "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "Downslam", "DashAttack" }
local DASH_ANIMS = { "DashForward", "DashBackward", "DashLeft", "DashRight" }
local REACTIONS = { "HitLeft", "HitRight" }

local function now(): number
	return os.clock()
end

-- quest progress hook (QuestServer creates it)
local function questStat(player: Player?, stat: string, amount: number)
	if not player then
		return
	end
	local hook = ServerStorage:FindFirstChild("QuestProgress")
	if hook and hook:IsA("BindableEvent") then
		hook:Fire(player, stat, amount)
	end
end

---------------------------------------------------------------------------
-- every fighter's body, for the ray filters (rebuilt only when a fighter comes or goes)
---------------------------------------------------------------------------
local charList: { Instance } = {}
local charVersion = 0
local function rebuildCharList()
	table.clear(charList)
	for c in pairs(entities) do
		table.insert(charList, c)
	end
	charVersion += 1
end
local function characterList(): { Instance }
	return charList
end

-- every other standing fighter's root (a knocked-back NPC brakes into them: Motion.Push)
local function bodiesBut(e: Entity): () -> { Vector3 }
	local out: { Vector3 } = {}
	return function(): { Vector3 }
		table.clear(out)
		for _, o in pairs(entities) do
			if o ~= e and o.Root.Parent and o.Hum.Health > 0 then
				table.insert(out, o.Root.Position)
			end
		end
		return out
	end
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
-- decorations a limb goes straight through (bushes, flowers, effects) never block a blow
losParams.RespectCanCollide = true
local filterVersion = { [groundParams] = -1, [losParams] = -1 }
local function synced(params: RaycastParams): RaycastParams
	if filterVersion[params] ~= charVersion then
		filterVersion[params] = charVersion
		params.FilterDescendantsInstances = charList
	end
	return params
end

---------------------------------------------------------------------------
-- entities + state
---------------------------------------------------------------------------
-- THE GUARD AND THE ESCAPE WINDOW, AS THE ATTACKER SAW THEM. A blow is judged against the guard
-- (and the escape window) the attacker's own screen showed when its blow landed there - the
-- server's state a round trip ago - so the number that screen stamps on its impact frame is the
-- number dealt: a guard raised after that came too late, one dropped after that still stopped it.
-- A short history of each is kept here (the attacker's screen predicts with the same rules).
local HISTORY = 1.5 -- seconds of it kept (the longest rewind is far shorter)
local function guardLog(e: Entity, t: number, up: boolean)
	local spans = e.GuardSpans
	if up then
		table.insert(spans, { Up = t, Down = nil })
	else
		local last = spans[#spans]
		if last and not last.Down then
			last.Down = t
		end
	end
	while #spans > 1 and spans[1].Down and t - spans[1].Down > HISTORY do
		table.remove(spans, 1)
	end
end
-- was the guard up (and up long enough: Config.Guard.StartDelay) at time `tau`?
local function guardedAt(e: Entity, tau: number): boolean
	local spans = e.GuardSpans
	for i = #spans, 1, -1 do
		local sp = spans[i]
		if sp.Up + Config.Guard.StartDelay <= tau and (sp.Down == nil or tau < sp.Down) then
			return true
		end
	end
	return false
end

local function setState(e: Entity, s: string, duration: number?, force: boolean?): boolean
	local fromGuard, toGuard = e.State == "Blocking", s == "Blocking"
	if e.State == "Dead" and s ~= "Dead" then
		return false
	end
	if not force and e.State ~= s and not States.CanEnter(e.State, s) then
		return false
	end
	if e.GuardSpans then
		if toGuard and not fromGuard then
			guardLog(e, now(), true)
		elseif fromGuard and not toGuard then
			guardLog(e, now(), false)
		end
	end
	e.State = s
	e.StateSerial += 1
	e.StateUntil = if duration then now() + duration else nil
	-- control (what refills the stun budget) starts the moment the fighter is its own again
	if States.HasControl(s) then
		if not e.ControlSince then
			e.ControlSince = now()
		end
	else
		e.ControlSince = nil
	end
	e.Char:SetAttribute("CombatState", s)
	return true
end

-- in the fight (it took, dealt or blocked a blow): the regen reserve waits Config.Regen.Delay from now
local function fought(e: Entity)
	if e.Reserve > 0 then
		e.RegenAt = now() + Config.Regen.Delay
		e.RegenAcc = 0
		e.Char:SetAttribute("RegenAt", workspace:GetServerTimeNow() + Config.Regen.Delay)
	end
end

-- out of the fight long enough: health from the reserve at Config.Regen.Rate, a tenth of a second at
-- a time (what it heals gives back the wounds it covers: an arm it still has comes off at its own
-- line again - never one it has lost back)
local REGEN_STEP = 0.1
local function regen(e: Entity, dt: number)
	e.RegenAcc += dt
	if e.RegenAcc < REGEN_STEP then
		return
	end
	local hum = e.Hum
	local heal = math.min(Config.Regen.Rate * e.RegenAcc, e.Reserve, hum.MaxHealth - hum.Health)
	e.RegenAcc = 0
	if heal <= 1e-4 or hum.Health <= 0 or e.State == "Dead" then
		return
	end
	e.Reserve = math.max(0, e.Reserve - heal)
	hum.Health += heal
	local w = math.max(0, 1 - hum.Health / math.max(hum.MaxHealth, 1))
	if w < e.Wounds then
		e.Wounds = w
		e.Char:SetAttribute("Wounds", w)
	end
	e.Char:SetAttribute("Reserve", if e.Reserve < 0.05 then 0 else e.Reserve)
	if e.Reserve < 0.05 then
		e.Reserve = 0
	end
end

function Service.Get(char: Model?): Entity?
	return if char then entities[char] else nil
end

function Service.Register(char: Model, player: Player?): Entity?
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root and root:IsA("BasePart")) then
		return nil
	end
	local old = entities[char]
	if old then
		return old
	end
	local e: Entity = {
		Char = char,
		Hum = hum,
		Root = root,
		Player = player,
		Npc = player == nil,
		State = "Idle",
		StateSerial = 0,
		StateUntil = nil,
		Chain = Rules.New(),
		ChainHits = 0,
		ChainId = 0,
		Attack = nil,
		Move = nil, -- NPCs: { Step, Carry } (CombatChoreo) - players move on their own client
		AttackSerial = 0,
		CancelSerial = 0,
		BlockStartAt = 0,
		BlockStunUntil = 0,
		ReleaseQueued = false,
		ReblockAt = 0,
		StunChainStart = nil,
		StunImmuneUntil = 0,
		Budget = SB.Max,
		ControlSince = now(),
		LastStunBy = nil,
		LastStunChain = 0,
		LastStunEnd = 0,
		DashDir = nil,
		DashStart = 0,
		DashCooldownUntil = 0,
		DownslamUntil = 0,
		DashAttackUntil = 0,
		LastReactAt = -1,
		LastReactRank = 0,
		LastHitBy = nil,
		LastHitAt = 0,
		AirPending = false,
		GoreStage = 0,
		Wounds = 0, -- the share of its health lost, added up (only the regen reserve takes any back)
		LastHealth = hum.Health,
		Hp = hum.Health, -- (its health as last seen: a drop is a fight)
		-- (a player) the regen reserve left (Config.Regen) and when it may start healing from it
		Reserve = if player then Config.Regen.Reserve else 0,
		RegenAt = 0,
		RegenAcc = 0,
		GuardSpans = {}, -- the guard's recent history: { Up, Down? } (see guardedAt)
		StageLog = {}, -- the gore stage's recent changes: { At, Stage } (see stageAt)
		Escape = false, -- in the escape window (no stun can land) - the Escape attribute too
		EscapeLog = {}, -- its recent flips: { At, On }
		Conns = {},
	}
	entities[char] = e
	rebuildCharList()
	Ragdoll.Setup(char)
	table.insert(e.Conns, fighterParts(char))
	if player then
		-- (before CombatEntity: a screen that sees the fighter sees its reserve)
		char:SetAttribute("Reserve", e.Reserve)
		char:SetAttribute("RegenAt", 0)
	end
	char:SetAttribute("CombatState", "Idle")
	char:SetAttribute("CombatEntity", true)
	char:SetAttribute("GoreStage", 0)
	char:SetAttribute("Escape", false)
	char:SetAttribute("Wounds", 0)
	-- (the name and health over its head are the HUD's own: OverkillHUD VitalBars)
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	if e.Npc then
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") and not p.Anchored then
				pcall(function()
					p:SetNetworkOwner(nil)
				end)
			end
		end
		e.AC = AnimController.get(hum)
	end
	table.insert(e.Conns, hum.Died:Connect(function()
		Service._onDied(e)
	end))
	-- (damage from anything else - a fall, a script - takes limbs too, and is a fight)
	table.insert(e.Conns, hum.HealthChanged:Connect(function(h)
		if h < e.Hp then
			fought(e)
		end
		e.Hp = h
		updateGore(e)
	end))
	-- a tool equipped while the right arm is gone goes straight back
	table.insert(e.Conns, char.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and (e.GoreStage or 0) >= 1 then
			task.defer(function()
				if child.Parent == char then
					stowTools(e)
				end
			end)
		end
	end))
	table.insert(e.Conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			Service.Unregister(char)
		end
	end))
	return e
end

local jobs: { any } = {}

-- nobody keeps a reference to a fighter that is gone: stun owners
local function forget(gone: Entity)
	for _, o in pairs(entities) do
		if o.LastStunBy == gone then
			o.LastStunBy = nil
		end
	end
end

function Service.Unregister(char: Model)
	local e = entities[char]
	if not e then
		return
	end
	entities[char] = nil
	rebuildCharList()
	for _, c in ipairs(e.Conns) do
		c:Disconnect()
	end
	if e.AC then
		e.AC:Destroy()
	end
	for i = #jobs, 1, -1 do
		if jobs[i].E == e then
			table.remove(jobs, i)
		end
	end
	e.LastStunBy = nil
	forget(e)
end

local function alive(e: Entity?): boolean
	return e ~= nil and e.Char.Parent ~= nil and e.Root.Parent ~= nil and e.Hum.Health > 0 and e.State ~= "Dead"
end
Service.Alive = alive

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function airborne(e: Entity): boolean
	-- a standing root is 3 studs above the floor; a little more than that = the feet have left it
	local hit = workspace:Raycast(e.Root.Position, Vector3.new(0, -3.45, 0), synced(groundParams))
	return hit == nil
end

-- the floor under a point within `depth` studs (nil: nothing solid there - a ledge, the void)
local function groundBelow(p: Vector3, depth: number): Vector3?
	local hit = workspace:Raycast(p, Vector3.new(0, -depth, 0), synced(groundParams))
	return if hit then hit.Position else nil
end

-- the floor under a body's footprint (its centre may hang just past a ledge's edge while its feet
-- still stand on it): straight down first, then the footprint's width
local function footingBelow(p: Vector3, depth: number): Vector3?
	local at = groundBelow(p, depth)
	if at then
		return at
	end
	local hit = workspace:Spherecast(p, 0.9, Vector3.new(0, -(depth - 0.9), 0), synced(groundParams))
	return if hit then hit.Position else nil
end

local function latency(e: Entity): number
	if not e.Player then
		return 0
	end
	local ok, ping = pcall(function()
		return e.Player:GetNetworkPing()
	end)
	return math.clamp(if ok and type(ping) == "number" then ping * 0.5 else 0.05, 0, 0.15)
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

-- the fighter's frame with its facing flattened (the root can tilt a hair on slopes)
local function bodyFrame(e: Entity): CFrame
	local cf = e.Root.CFrame
	local look = flat(cf.LookVector)
	return CFrame.lookAt(cf.Position, cf.Position + look)
end

-- the attacker's frame for hit detection: a player's own screen is a touch ahead of what the
-- server has (their step-in already happened there), so the root is led along its velocity
local function attackFrame(e: Entity): CFrame
	local cf = bodyFrame(e)
	if e.Player then
		local v = e.Root.AssemblyLinearVelocity
		cf = cf + Vector3.new(v.X, 0, v.Z) * Config.Hitbox.LagLead
	end
	return cf
end

-- where every body was a moment ago (lag compensation: a player's strike is judged against the
-- victim where that player SAW it, not where the server has it now). A ring buffer per fighter:
-- nothing is allocated or shifted per frame.
local HIST_N = 48 -- ~0.8 s at 60 Hz
local function record(e: Entity, t: number)
	local h = e.Hist
	if not h then
		h = { T = table.create(HIST_N, -math.huge), C = table.create(HIST_N, CFrame.identity), I = 0, N = 0 }
		e.Hist = h
	end
	h.I = h.I % HIST_N + 1
	h.T[h.I] = t
	h.C[h.I] = bodyFrame(e)
	if h.N < HIST_N then
		h.N += 1
	end
end

local function bodyFrameAt(e: Entity, t: number): CFrame
	local h = e.Hist
	if not h or h.N == 0 or t >= h.T[h.I] then
		return bodyFrame(e)
	end
	local idx = h.I
	for _ = 1, h.N - 1 do
		local prev = (idx - 2) % HIST_N + 1
		local tp = h.T[prev]
		if tp <= t then
			local k = (t - tp) / math.max(h.T[idx] - tp, 1e-6)
			return h.C[prev]:Lerp(h.C[idx], k)
		end
		idx = prev
	end
	return h.C[idx]
end

-- the body as the attacker saw it: rewound, but never further than RewindReach from where it is now
local function rewoundFrame(v: Entity, seenAt: number): CFrame
	local old = bodyFrameAt(v, seenAt)
	local d = old.Position - v.Root.Position
	local m = d.Magnitude
	local cap = Config.Hitbox.RewindReach
	if m > cap then
		return old - d * (1 - cap / m)
	end
	return old
end

-- the point of the path a body really took between t0 and t1 (its recorded frames, and where it is
-- now) nearest to `p`: that point, the body's facing there, and how far `p` is from it
local function nearestOnPath(e: Entity, p: Vector3, t0: number, t1: number): (Vector3, Vector3, number)
	local bestP = e.Root.Position
	local bestL = flat(e.Root.CFrame.LookVector)
	local bestD = (p - bestP).Magnitude
	local h = e.Hist
	if not h or h.N == 0 then
		return bestP, bestL, bestD
	end
	-- newest first: each recorded frame and the stretch from it to the one after it
	local idx = h.I
	local nextP, nextL = e.Root.Position, flat(e.Root.CFrame.LookVector)
	for _ = 1, h.N do
		local tt = h.T[idx]
		if tt < t0 - 1 / 30 then
			break
		end
		if tt <= t1 then
			local cp = h.C[idx].Position
			local cl = h.C[idx].LookVector
			local seg = nextP - cp
			local len2 = seg:Dot(seg)
			local k = if len2 > 1e-8 then math.clamp((p - cp):Dot(seg) / len2, 0, 1) else 0
			local q = cp + seg * k
			local d = (p - q).Magnitude
			if d < bestD then
				bestP, bestD = q, d
				local l = cl:Lerp(nextL, k)
				bestL = if l.Magnitude > 1e-3 then flat(l) else flat(cl)
			end
			nextP, nextL = cp, cl
		end
		idx = (idx - 2) % HIST_N + 1
	end
	return bestP, bestL, bestD
end

-- the widest angle (degrees) between `look` and the body's recorded facings since t0
local function turnFrom(e: Entity, look: Vector3, t0: number): number
	local best = math.deg(math.acos(math.clamp(flat(e.Root.CFrame.LookVector):Dot(look), -1, 1)))
	local h = e.Hist
	if h then
		local idx = h.I
		for _ = 1, h.N do
			if h.T[idx] < t0 then
				break
			end
			best = math.min(best, math.deg(math.acos(math.clamp(flat(h.C[idx].LookVector):Dot(look), -1, 1))))
			idx = (idx - 2) % HIST_N + 1
		end
	end
	return best
end

-- how fast the body really moved over the last ~0.2 s (the server's own record)
local function recentSpeed(e: Entity): number
	local h = e.Hist
	local v = e.Root.AssemblyLinearVelocity
	local best = Vector3.new(v.X, 0, v.Z).Magnitude
	if h and h.N > 1 then
		local t = h.T[h.I]
		local from = bodyFrameAt(e, t - 0.2).Position
		local d = e.Root.Position - from
		best = math.max(best, Vector3.new(d.X, 0, d.Z).Magnitude / 0.2)
	end
	return best
end

-- has the body left the ground lately? (in the air now, or its height moved by a jump's worth over
-- the last half second of history)
local function wentUp(e: Entity): boolean
	if airborne(e) then
		return true
	end
	local h = e.Hist
	if not h or h.N < 2 then
		return false
	end
	local t = h.T[h.I]
	local lo, hi = math.huge, -math.huge
	for i = 1, h.N do
		if h.T[i] >= t - 0.5 then
			local y = h.C[i].Position.Y
			lo = math.min(lo, y)
			hi = math.max(hi, y)
		end
	end
	return hi - lo >= 1.2
end

local function rewindFor(att: Entity): number
	if not att.Player then
		return 0
	end
	return math.clamp(latency(att) * 2 + Config.Hitbox.Rewind, 0, Config.Hitbox.RewindMax)
end

-- how old the fighters' states on this attacker's screen are: a round trip (attributes aren't
-- interpolated like bodies)
local function stateAgeFor(att: Entity): number
	if not att.Player then
		return 0
	end
	return math.clamp(latency(att) * 2, 0, Config.Hitbox.RewindMax)
end

local function hittable(e: Entity): boolean
	return alive(e) and States.Allows(e.State, "Hittable")
end

-- a server-approved cooldown the owner's HUD shows (server time, so every clock agrees)
local function setCooldown(e: Entity, key: string, seconds: number)
	e.Char:SetAttribute("CombatCD_" .. key, workspace:GetServerTimeNow() + seconds)
	e.Char:SetAttribute("CombatCDLen_" .. key, seconds)
end

---------------------------------------------------------------------------
-- chains, cancelling
---------------------------------------------------------------------------
-- the chain is over: its count and its slot go with it
local function endChain(e: Entity)
	Rules.Reset(e.Chain)
	e.ChainHits = 0
end

-- cancels the entity's current action (strike / dash / stomp) and its combo chain
local function interrupt(e: Entity)
	e.AttackSerial += 1
	e.CancelSerial += 1
	e.CancelledAt = now() -- (a hit its own screen landed before this still counts: see judgeClaim)
	e.Attack = nil
	e.Move = nil
	e.Link = nil -- (hit out of it: no way in left)
	endChain(e)
	if e.Npc and e.AC then
		e.AC:StopMany(ATTACK_ANIMS, 0.08)
		e.AC:StopMany(DASH_ANIMS, 0.08)
		e.AC:Stop("Block", 0.1)
		Motion.Stop(e.Root)
	end
end

---------------------------------------------------------------------------
-- reactions, knockback, knockdown, stun, guard break
---------------------------------------------------------------------------
-- which reaction clip (and which way the blow drove the victim: +1 = to the victim's right).
-- HitRight (GettingHit1) turns the body to its right, HitLeft the mirror. A crossing blow
-- (ReactPush) turns the head the way the limb travels; a straight blow drives back the side it
-- lands on. Everything is turned into the victim's own frame, so any angle reads right.
local function reactionFor(att: Entity, vic: Entity, def: any, contact: Vector3?): (string, number)
	local acf = bodyFrame(att)
	local vcf = vic.Root.CFrame
	local push = def.ReactPush or 0
	local dir: number
	if push ~= 0 then
		local lateral = vcf:VectorToObjectSpace(acf.RightVector * push)
		dir = if lateral.X >= 0 then 1 else -1
	else
		local p = contact or acf:PointToWorldSpace(def.Contact)
		local r = vcf:PointToObjectSpace(p)
		if math.abs(r.X) < 0.15 then
			-- dead centre: the side the attacker stands on is driven back
			r = vcf:PointToObjectSpace(att.Root.Position)
		end
		-- a blow on the victim's left drives the left side back = the body turns left = HitLeft
		dir = if r.X < 0 then -1 else 1
	end
	return (if dir > 0 then "HitRight" else "HitLeft"), dir
end

local driveNpc: (e: Entity) -> ()
local SLIDE_BACK = 4 -- studs: the most a blow puts a sliding body back to where it landed (see applyHit)

-- which way a blow drives its victim: straight along the attacker's facing (the way the limb
-- travels) - so the victim slides down the attacker's line and the next strike of the chain finds
-- it there. The Ground Smash is an area blow: straight out from the smash.
local function driveDir(att: Entity, vic: Entity, def: any): Vector3
	if def.Id == "Downslam" then
		local away = vic.Root.Position - att.Root.Position
		return flat(if Vector3.new(away.X, 0, away.Z).Magnitude > 0.2 then away else bodyFrame(att).LookVector)
	end
	return flat(bodyFrame(att).LookVector)
end

-- a clean hit's knockback (world, studs/s)
local function knockVector(att: Entity, vic: Entity, def: any): Vector3
	local k = def.Knock
	return driveDir(att, vic, def) * (k.Back or 0) + Vector3.new(0, k.Up or 0, 0)
end

-- a blocked hit's slide: straight back from the attacker, angled toward the side the blow drove
local function blockPush(att: Entity, vic: Entity, def: any, class: any, dir: number): (Vector3, number)
	local dist = class.BlockPush or 0
	local time = class.BlockPushTime or 0
	if dist <= 0 or time <= 0 then
		return Vector3.zero, 0
	end
	local away = driveDir(att, vic, def)
	local vright = flat(vic.Root.CFrame.RightVector)
	local d = (away + vright * dir * 0.38).Unit
	-- Motion.Push decays (average ~0.57 of the start speed): start speed that covers `dist`
	return d * (dist / (time * 0.57)), time
end

local function recover(e: Entity, serial: number)
	if e.StateSerial ~= serial or e.State ~= "Ragdolled" or not alive(e) then
		return
	end
	Ragdoll.Disable(e.Char)
	local rc = Config.Recovery
	setState(e, "Recovering", rc.ActionsAt / rc.Speed, true)
	-- a knockdown is the end of a string, not a tiny gap: back on its feet (with its getting-up
	-- i-frames) the fighter starts over with a full stun budget
	e.Budget = SB.Max
	if e.Npc then
		Ragdoll.StandUp(e.Char)
		if e.AC then
			e.AC:Play("GroundRecovery", { Fade = 0.05, Speed = rc.Speed, Restart = true })
		end
		local recSerial = e.StateSerial
		task.delay(0.2, function()
			if e.Hum.Parent and e.StateSerial == recSerial then
				e.Hum:ChangeState(Enum.HumanoidStateType.Running)
				e.Hum.AutoRotate = true
			end
		end)
	end
end

-- the throw a launch gives a body (world velocities for the legs and the torso, and a tip).
-- launch = { Back, Up, Side, LegsUp, LegsSide, Tip, Time }: horizontal and vertical tuned
-- separately; the body tips backward (never an uncontrolled spin)
local function launchVectors(vic: Entity, att: Entity?, launch: any, def: any?): (Vector3, Vector3, Vector3)
	local legs, torso, spin = Vector3.new(0, 8, 0), Vector3.new(0, 6, 0), Vector3.zero
	if att and att.Root.Parent then
		local acf = bodyFrame(att)
		local away = if def then driveDir(att, vic, def) else flat(vic.Root.Position - att.Root.Position)
		local right = acf.RightVector
		local up = Vector3.yAxis
		torso = away * (launch.Back or 0) + up * (launch.Up or 0) + right * (launch.Side or 0)
		legs = away * (launch.Back or 0) * 0.55 + up * (launch.LegsUp or launch.Up or 0) + right * (launch.LegsSide or 0)
		spin = up:Cross(away).Unit * (launch.Tip or 0)
	end
	return legs, torso, spin
end

-- knock a fighter off its feet (after `delay`: the blow's hit-stop)
local function knockDown(vic: Entity, att: Entity?, launch: any, delay: number?, def: any?)
	interrupt(vic)
	setState(vic, "Ragdolled", nil, true)
	vic.LastStunBy = nil -- the combo on them is over
	vic.StunChainStart = nil
	local serial = vic.StateSerial
	local legs, torso, spin = launchVectors(vic, att, launch, def)
	local function go()
		if vic.StateSerial ~= serial or not vic.Char.Parent then
			return
		end
		Ragdoll.Enable(vic.Char, legs, torso, spin)
		if vic.Npc then
			Motion.Stop(vic.Root, true)
			Ragdoll.ApplyFall(vic.Char)
		end
	end
	if delay and delay > 0 then
		task.delay(delay, go)
	else
		go()
	end
	task.delay((launch.Time or 1.3) + (delay or 0), function()
		recover(vic, serial)
	end)
end

-- how long the fighter has been in control without a break (0 while it isn't)
local function controlFor(e: Entity, t: number): number
	return if e.ControlSince then t - e.ControlSince else 0
end

-- can a blow stun this fighter right now? (not in its escape window, budget left)
local function canStun(vic: Entity, t: number): boolean
	return t >= vic.StunImmuneUntil and vic.Budget >= SB.Min
end

-- the escape window's recent flips (logged every frame; see THE GUARD AND THE ESCAPE WINDOW)
local function escapeLog(e: Entity, t: number)
	local esc = not canStun(e, t)
	if esc == e.Escape then
		return
	end
	e.Escape = esc
	local log = e.EscapeLog
	table.insert(log, { At = t, On = esc })
	while #log > 2 and t - log[2].At > HISTORY do
		table.remove(log, 1)
	end
	e.Char:SetAttribute("Escape", esc)
end
-- was it in its escape window at time `tau`?
local function escapeAt(e: Entity, tau: number): boolean
	local log = e.EscapeLog
	for i = #log, 1, -1 do
		if log[i].At <= tau then
			return log[i].On
		end
	end
	return if #log > 0 then not log[1].On else e.Escape
end

-- spend stun budget; running dry opens the escape window after `endsAt`
local function spend(vic: Entity, seconds: number, endsAt: number)
	vic.Budget = math.max(0, vic.Budget - seconds)
	if vic.Budget < SB.Min then
		vic.StunImmuneUntil = math.max(vic.StunImmuneUntil, endsAt + Config.StunImmunity)
	end
end

-- stun bookkeeping for a hit. Returns the stun left (seconds).
local function stun(vic: Entity, seconds: number): number
	local t = now()
	local stunned = vic.State == "Stunned" and vic.StateUntil ~= nil
	local cur = if stunned then math.max(t, vic.StateUntil :: number) else t
	if not stunned or not vic.StunChainStart then
		vic.StunChainStart = t
	end
	-- what this stun ADDS to the one already running is paid from the budget...
	local add = math.max(0, t + seconds - cur)
	local last = false
	if add >= vic.Budget then
		add = vic.Budget
		last = true
	end
	local untilT = cur + add
	-- ...and continuous stun from any number of attackers is capped on top of that
	local cap = vic.StunChainStart + Config.StunCap
	if untilT > cap then
		untilT = math.max(cap, cur)
		last = true
	end
	untilT = math.max(untilT, t + 0.12) -- never shorter than a flinch
	spend(vic, math.max(0, untilT - cur), untilT)
	setState(vic, "Stunned", untilT - t, true)
	if last then
		vic.StunImmuneUntil = math.max(vic.StunImmuneUntil, untilT + Config.StunImmunity)
	end
	return untilT - t
end

local function guardBreak(vic: Entity)
	interrupt(vic)
	local g = Config.Guard
	setState(vic, "GuardBroken", g.BreakStun, true)
	vic.ReblockAt = now() + g.BreakStun + g.ReblockAfter
	vic.ReleaseQueued = false
	vic.BlockStunUntil = 0
	-- a broken guard is control lost too: it is paid from the budget like a stun
	spend(vic, math.min(vic.Budget, g.BreakStun), now() + g.BreakStun)
end

---------------------------------------------------------------------------
-- an NPC's body (the server drives it): the same reaction and clip hand-overs a player's own client
-- gives its body (CombatClient react / tailFade), so a dummy reels, sags and recovers as smoothly
---------------------------------------------------------------------------
-- the reaction clip, cross-fading from the pose the body is in (never from neutral): the same side as
-- the last blow blends quickly, the other side (the head whipping across) a touch longer. It holds
-- the impact pose through the hit-stop, plays at `speed`, sags part way back toward the stance once
-- past its peak (Config.React), and holds its last pose while the stun lasts
local reactGen: { [AnimationTrack]: number } = setmetatable({}, { __mode = "k" }) :: any
local function npcReact(vic: Entity, reaction: string, speed: number, hitstop: number, fade: number?)
	local ac = vic.AC
	if not ac then
		return
	end
	local R = Config.React
	local other = if reaction == "HitLeft" then "HitRight" else "HitLeft"
	local f = fade or (if ac:IsPlaying(other) then R.SwapBlend else R.Blend)
	local tr = ac:PlayFresh(reaction, { Fade = f, Speed = 0 })
	ac:Stop(other, f)
	if not tr then
		return
	end
	-- (this play of the clip, still reeling: a later blow that didn't restart it keeps it going - it
	-- never runs out and pops back to the stance mid-stun - and a copy started again drops what was
	-- scheduled for its last play)
	local gen = (reactGen[tr] or 0) + 1
	reactGen[tr] = gen
	local function reeling(): boolean
		return reactGen[tr] == gen and tr.IsPlaying and (vic.State == "Stunned" or vic.State == "GuardBroken")
	end
	task.delay(hitstop, function()
		if not reeling() or speed <= 0 then
			return
		end
		tr:AdjustSpeed(speed)
		local len = if tr.Length > 0 then tr.Length else 0.5
		task.delay(math.max(0.05, (len - tr.TimePosition) / speed - 0.05), function()
			if reeling() then
				tr:AdjustSpeed(0)
			end
		end)
		task.delay(math.max(0, (R.SettleAt - tr.TimePosition) / speed), function()
			if reeling() then
				tr:AdjustWeight(R.Settle, R.SettleTime)
			end
		end)
	end)
end

-- a strike clip that runs out with nothing after it drops its weight on one frame (a pop back to the
-- idle pose): it fades out over its last moment instead (a hit-stop's freeze is waited out)
local function npcTailFade(e: Entity, track: AnimationTrack?, def: any, serial: number)
	if not track then
		return
	end
	local window = math.min(0.2, def.LengthReal * 0.3)
	local function check()
		if not (e.AttackSerial == serial and track.IsPlaying) then
			return
		end
		local left = (def.Length - track.TimePosition) / math.max(def.Speed, 0.05)
		if track.Speed < 0.05 or left > window then
			task.delay(math.max(0.03, left - window * 0.8), check)
			return
		end
		track:Stop(math.max(0.05, left * 0.9))
	end
	task.delay(math.max(0, def.LengthReal - window), check)
end

---------------------------------------------------------------------------
-- applying a connected strike
---------------------------------------------------------------------------
-- ONE CHAIN PER STUN. A victim still reeling from an attacker's chain (or with less than
-- Config.Combo.ResetGrace of control since) can't be locked again by a NEW chain from that same
-- attacker: waiting out the window, block / dash / jump cancelling, re-opening with the uppercut,
-- a dash strike or a Ground Smash would otherwise restart the string on a body that never got to
-- act. The blow still lands (damage, push, give) but doesn't stun or interrupt. Launchers still
-- knock down only as a chain's own finisher.
-- (chainId: the chain the blow belongs to - its strike's own, which a claim verified a moment late
-- keeps even once the attacker has started a new one)
local function resetLocked(att: Entity, vic: Entity, t: number, chainId: number?): boolean
	return vic.LastStunBy == att and vic.LastStunChain ~= (chainId or att.ChainId) and controlFor(vic, t) < Config.Combo.ResetGrace
end
-- the same, as it stood at `tau` (the attacker's screen: control that came back after it hadn't yet)
local function resetLockedAt(att: Entity, vic: Entity, tau: number, chainId: number?): boolean
	if not (vic.LastStunBy == att and vic.LastStunChain ~= (chainId or att.ChainId)) then
		return false
	end
	local since = vic.ControlSince
	return since == nil or since > tau or tau - since < Config.Combo.ResetGrace
end

---------------------------------------------------------------------------
-- limbs (Config.Gore): how far a fighter's body has come apart - the right arm, the left arm, the
-- head - worked out from its health, and kept until it respawns: a lost limb never comes back. It is
-- hidden for everyone here; every client adds the torn wounds, the blood and the thrown limb itself
-- (CombatGore).
-- Fewer arms: more damage taken, a weaker guard, single strikes, then no guard and no strikes
---------------------------------------------------------------------------
local dropGuard: (Entity) -> ()
local LIMBS = { "Right Arm", "Left Arm", "Head" }

local function goreFor(e: Entity): boolean
	return Config.Gore.Enabled and (e.Npc or Config.Gore.Players == true)
end

-- its gore stage as it stood at `tau` (an attacker's screen shows it a round trip late: the damage
-- multiplier and the narrower body are judged as that screen had them, so its number is the one dealt)
local function stageAt(e: Entity, tau: number): number
	if not goreFor(e) then
		return 0
	end
	local log = e.StageLog
	if log then
		for i = #log, 1, -1 do
			if log[i].At <= tau then
				return log[i].Stage
			end
		end
		if #log > 0 then
			return log[1].Was
		end
	end
	return e.GoreStage or 0
end

-- an accessory hangs on `part`: by a weld to it, or (rigid accessories) a constraint to it
local function heldBy(j: Instance, part: BasePart): boolean
	if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
		return (j :: any).Part0 == part or (j :: any).Part1 == part
	elseif j:IsA("Constraint") then
		local a0, a1 = (j :: any).Attachment0, (j :: any).Attachment1
		return (a0 ~= nil and a0.Parent == part) or (a1 ~= nil and a1.Parent == part)
	end
	return false
end

-- worn on `part`: held by a weld / constraint to it, or attached where it attaches (its handle has
-- an attachment named like one of the part's own - HairAttachment, HatAttachment... on the head -
-- which still holds once a dying body's joints have broken: the hair goes the instant the head does)
local function wornOn(h: BasePart, part: BasePart): boolean
	for _, a in ipairs(h:GetChildren()) do
		if a:IsA("Attachment") then
			local mine = part:FindFirstChild(a.Name)
			if mine and mine:IsA("Attachment") then
				return true
			end
		end
	end
	for _, j in ipairs(h:GetDescendants()) do
		if heldBy(j, part) then
			return true
		end
	end
	return false
end

-- a lost limb is gone for everyone: the part, the face on it, whatever is worn on it. What each
-- looked like before is kept on it (GoreHidden): a still copy of the fighter - the HUD's portraits -
-- shows it whole
local function vanish(obj: any)
	if obj:GetAttribute("GoreHidden") == nil then
		obj:SetAttribute("GoreHidden", obj.Transparency)
	end
	obj.Transparency = 1
end
-- everything worn on `part`: accessories' handles, and a hero's own pieces (hair, a collar - loose
-- parts of the character welded to it: HeroServer), so a popped head takes its hair with it
local BODY_PART = { Head = true, Torso = true, HumanoidRootPart = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true }
local function wornParts(char: Model, part: BasePart): { BasePart }
	local out = {}
	for _, c in ipairs(char:GetChildren()) do
		local h = if c:IsA("Accessory") then c:FindFirstChild("Handle") elseif c:IsA("BasePart") and not BODY_PART[c.Name] then c else nil
		if h and h:IsA("BasePart") and wornOn(h, part) then
			table.insert(out, h)
		end
	end
	return out
end
local function hideLimb(char: Model, part: BasePart)
	vanish(part)
	for _, d in ipairs(part:GetChildren()) do
		if d:IsA("Decal") then
			vanish(d)
		end
	end
	for _, h in ipairs(wornParts(char, part)) do
		vanish(h)
	end
end

-- a tool is held in the right hand: with that arm gone it goes back in the backpack (never held
-- by a hand that isn't there)
function stowTools(e: Entity)
	local bag = e.Player and e.Player:FindFirstChildOfClass("Backpack")
	if not bag then
		return -- (nowhere to put it: never thrown away)
	end
	for _, t in ipairs(e.Char:GetChildren()) do
		if t:IsA("Tool") then
			t.Parent = bag
		end
	end
end

-- the body at gore stage `st` (it only ever goes up: a lost limb stays lost)
local function setGore(e: Entity, st: number)
	local was = e.GoreStage or 0
	if st == was then
		return
	end
	e.GoreStage = st
	local log = e.StageLog
	if log then
		table.insert(log, { At = now(), Stage = st, Was = was })
		if #log > 8 then
			table.remove(log, 1)
		end
	end
	e.Char:SetAttribute("GoreStage", st)
	for i = was + 1, st do
		local part = e.Char:FindFirstChild(LIMBS[i])
		if part and part:IsA("BasePart") then
			hideLimb(e.Char, part)
		end
	end
	-- no right arm, nothing held; no arms, no guard
	if st >= 1 then
		stowTools(e)
	end
	if Config.ArmsAt(st) == 0 and e.State == "Blocking" then
		dropGuard(e)
	end
end

-- the body catches up with the damage it has taken: every point of health lost adds to its wounds
-- (only the regen reserve takes any back), and the wounds decide the stage - which never goes back:
-- a limb that is gone stays gone until the fighter respawns
function updateGore(e: Entity)
	if not goreFor(e) or not e.Char.Parent then
		return
	end
	local hum = e.Hum
	local h = hum.Health
	local last = e.LastHealth or h
	if h < last then
		e.Wounds = math.min(1, (e.Wounds or 0) + (last - h) / math.max(hum.MaxHealth, 1))
		e.Char:SetAttribute("Wounds", e.Wounds)
	end
	e.LastHealth = h
	local was = e.GoreStage or 0
	local st = math.max(was, if h <= 0 then 3 else Config.GoreStageForWounds(e.Wounds or 0))
	if st ~= was then
		setGore(e, st)
	end
end

local function applyHit(att: Entity, vic: Entity, def: any, contact: Vector3, job: any)
	local t = now()
	local class = def.ClassDef
	local reaction, dir = reactionFor(att, vic, def, contact)
	-- Seq: the attacker's own request number (its client already showed this impact on its own
	-- frame and matches the event to it instead of playing it twice)
	local data: any = {
		A = att.Char, V = vic.Char, K = def.Id, R = reaction, Dir = dir, P = contact, Rank = def.Rank,
		B = false, G = false, RD = false, IM = false, D = 0, S = 0, KB = Vector3.zero, KT = 0, RS = def.React,
		HS = class.Hitstop, CH = 0, Slot = job.Slot or 0, Seq = job.Seq,
		DV = driveDir(att, vic, def), -- the way the blow drives (effects, the camera kick)
	}
	-- no stun for this fighter now: its escape window, its budget spent, or a restarted chain
	local immune = not canStun(vic, t) or resetLocked(att, vic, t, job.ChainId)
	-- guard: facing the attacker with the guard up (and up long enough) - as the attacker's screen
	-- had it when the blow landed there (a guard dropped since still stops it, one raised since came
	-- too late), and still able to take it now
	local tau = t - stateAgeFor(att)
	if att.Player and job.HitTau then
		-- (exactly: the moment the blow landed on the attacker's screen, less the time the victim's
		-- state takes to reach it)
		local landed = job.Start + job.HitTau / def.Speed
		tau = math.clamp(landed - latency(att), t - Config.Hitbox.RewindMax, t)
	end
	-- (facing: the two bodies where the attacker's screen had them when the blow landed there)
	local vFrame = if job.HitVcf then job.HitVcf else vic.Root.CFrame
	local toAtt = (if job.HitAcf then job.HitAcf.Position else att.Root.Position) - vFrame.Position
	local facing = flat(vFrame.LookVector):Dot(flat(toAtt)) > Config.Guard.Arc
	local guarded = facing and guardedAt(vic, tau) and (vic.State == "Blocking" or States.Allows(vic.State, "Block"))
	-- a guard breaker is held off by a fighter that was in its escape window (the same moment)
	local breakHeld = escapeAt(vic, tau) or resetLockedAt(att, vic, tau, job.ChainId)
	if STUDIO and vic.State == "Blocking" and not guarded and workspace:GetAttribute("CombatDebugHits") then
		print(string.format("[HitDbg] guard missed: facing dot %.2f, up for %.2f", flat(vic.Root.CFrame.LookVector):Dot(flat(toAtt)), t - vic.BlockStartAt))
	end
	local dmg = 0
	if guarded and def.GuardBreak and not breakHeld then
		-- guard break: shattered, not knocked down (they tried to block): the directional reaction,
		-- slowed, a controlled slide, then a moment before the guard can go up again
		dmg = def.GuardBreakDamage or def.Damage * 0.5
		data.G = true
		data.HS = Config.Guard.BreakHitstop
		guardBreak(vic)
		data.S = Config.Guard.BreakStun
		data.RS = Config.Guard.BreakReactSpeed
		data.KB = knockVector(att, vic, def)
		data.KB = Vector3.new(data.KB.X, 0, data.KB.Z)
		data.KT = def.KnockTime or 0.25
		questStat(vic.Player, "Blocks", 1)
	elseif guarded then
		-- blocked (a guard breaker against a fighter in its escape window is held off like a heavy blow)
		local bc = if def.GuardBreak then Config.Classes.Heavy else class
		dmg = def.Damage * Config.Guard.DamageScale
		data.B = true
		data.HS = bc.BlockHitstop
		data.KB, data.KT = blockPush(att, vic, def, bc, dir)
		vic.BlockStunUntil = math.max(vic.BlockStunUntil, t + (bc.BlockStun or 0) + data.HS)
		questStat(vic.Player, "Blocks", 1)
	else
		dmg = def.Damage
	end
	-- where the effects go: a clean blow's on the body's surface where it lands (the contact); a
	-- blocked one's or a guard break's where the guard met the striking limb
	if (data.B or data.G) and job.HitFist then
		data.P = job.HitFist
	end
	-- (a fighter that hits harder than its moves say: the Brute Dummy - TrainingDummies)
	dmg *= att.DamageMul or 1
	-- a body missing arms takes more, and a one-armed guard stops less (Config.GoreDamage: the
	-- attacker's screen predicts the same number on its own impact frame)
	if goreFor(vic) then
		dmg = Config.GoreDamage(dmg, stageAt(vic, tau), data.B)
		-- ...and a clean blow that leaves it at the head's line or under pops the head: the killing blow
		dmg = Config.HeadPopDamage(dmg, vic.Hum.Health, vic.Hum.MaxHealth, data.B)
	end
	-- damage. The blow that knocks them out throws the body: the strike's own launch (the sweep,
	-- the stomp), or the KO throw straight back from the attacker for any other blow - after the
	-- hit-stop, so the knockout lands on the blow's frame
	data.D = dmg
	if vic.Hum.Health > 0 and dmg >= vic.Hum.Health then
		vic.KOLaunch = { Att = att, Launch = def.Launch or Config.KOLaunch, Delay = data.HS }
	end
	vic.Hum:TakeDamage(dmg)
	updateGore(vic)
	fought(vic)
	fought(att)
	vic.LastHitBy = att.Player or att.Char
	vic.LastHitAt = t
	if att.Player and vic.Char ~= att.Char then
		questStat(att.Player, "Hits", 1)
		questStat(att.Player, "Damage", dmg)
	end
	local reacts = States.Allows(vic.State, "Reacts") and vic.Hum.Health > 0
	if not data.B and not data.G and reacts then
		local launch = def.Launch
		-- nothing takes down or stuns a fighter in its escape window (or reset-locked): those get the
		-- give and a push, and keep control
		if launch and not immune then
			data.RD = true
			knockDown(vic, att, launch, data.HS, def)
		elseif not immune then
			-- being hit breaks your own strike / dash / guard and your chain
			if vic.State ~= "Stunned" then
				interrupt(vic)
			else
				endChain(vic)
				-- a body still sliding from the last blow: this one landed where the attacker's screen had it
				-- (the claim came a moment later, the slide carried on here) - it goes back there, the slide
				-- stops, and its own push follows the hit-stop. A player's own screen does the same (VP)
				local at = job.HitVcf and job.HitVcf.Position
				local back = if at then Vector3.new(at.X - vic.Root.Position.X, 0, at.Z - vic.Root.Position.Z) else nil
				if at and back and back.Magnitude < SLIDE_BACK then
					data.VP = at
					if vic.Npc then
						vic.Root.CFrame += back
					end
				end
				if vic.Npc then
					Motion.Stop(vic.Root)
				end
			end
			-- (the hitstun covers this strike's own follow-ups: the chain as it stood when it started -
			-- a claim verified a moment late may land after the next strike has already begun)
			local chain = if att.Attack and att.Attack.Serial == job.Serial then att.Chain else (job.Chain or att.Chain)
			local need = math.max(def.Stun or 0, Rules.CoverStun(chain, def))
			data.S = stun(vic, need + data.HS)
			vic.LastStunBy = att
			vic.LastStunChain = job.ChainId or att.ChainId
			vic.LastStunEnd = t + data.S
			data.KB = knockVector(att, vic, def)
			data.KT = def.KnockTime or 0.12
		else
			data.IM = true
			local kb = knockVector(att, vic, def) * 0.5
			data.KB = Vector3.new(kb.X, math.min(kb.Y, 6), kb.Z)
			data.KT = def.KnockTime or 0.12
		end
	end
	-- the attacker's combo counter counts strikes that connected (a guard break counts, a block doesn't)
	if not data.B then
		if not job.Counted then
			job.Counted = true
			att.ChainHits += 1
		end
		data.CH = att.ChainHits
	end
	-- a smash that stuns opens the way in: a dash strike before the stun ends carries its chain on
	if def.Opens and data.S > 0 and not data.G then
		local untilT = t + data.S
		if not (att.Link and att.Link.ChainId == job.ChainId and att.Link.Until >= untilT) then
			att.Link = { Until = untilT, ChainId = job.ChainId, Hits = att.ChainHits }
		end
	end
	-- hit-stop: the attacker's clip freezes, so its chain timing moves back by the same amount
	if not job.Stopped then
		job.Stopped = true
		job.Start += data.HS
		if att.Attack and att.Attack.Serial == job.Serial then
			Rules.Delay(att.Chain, data.HS)
			if att.StateUntil and (att.State == "Attacking") then
				att.StateUntil += data.HS
			end
		end
		if att.Npc and att.AC and job.Anim then
			local tr = att.AC:Track(job.Anim)
			if tr and tr.IsPlaying then
				tr:AdjustSpeed(0.02)
				local serial = att.AttackSerial
				task.delay(data.HS, function()
					if tr.IsPlaying and att.AttackSerial == serial then
						tr:AdjustSpeed(def.Speed)
					end
				end)
			end
		end
	end
	-- reaction replacement: the clip restarts only after a short gap, or for a heavier hit
	local restart = (t - vic.LastReactAt) >= Config.ReactMinGap or def.Rank > vic.LastReactRank or data.B or data.G
	data.PR = restart
	if restart then
		vic.LastReactAt = t
		vic.LastReactRank = def.Rank
	end
	-- NPC victims: the server owns their body
	if vic.Npc and vic.AC and not data.RD then
		local hs = data.HS
		local serial = vic.StateSerial
		if data.G then
			vic.AC:Stop("Block", 0.08)
			npcReact(vic, reaction, data.RS, hs, 0.05)
		elseif not data.B and restart and data.S > 0 then
			npcReact(vic, reaction, data.RS, hs)
		end
		if data.KT > 0 then
			local kb, kt = data.KB, data.KT
			task.delay(hs, function()
				if vic.Root.Parent and vic.State ~= "Ragdolled" and vic.State ~= "Dead" then
					Motion.Push(vic.Root, kb, kt, characterList(), bodiesBut(vic))
				end
			end)
		elseif data.KB.Y > 0 then
			Motion.Push(vic.Root, data.KB, 0)
		end
	end
	-- an NPC attacker carries on along its facing with the blow (players do this on their own client,
	-- on their own impact frame): the same momentum a player's body gets (CombatChoreo) - blocked, it
	-- follows the guard's slide
	if att.Npc and not data.G and not data.RD and data.KT > 0.02 and (job.Slot or 0) > 0 and not job.Carried then
		job.Carried = true
		local carry = Choreo.NewCarry(def, flat(bodyFrame(att).LookVector), now(), data.HS, att.Chain, data.B == true)
		if carry then
			att.Move = att.Move or {}
			att.Move.Carry = carry
			task.delay(data.HS, function()
				if att.Move and att.Move.Carry == carry and (att.State == "Attacking" or att.State == "ComboWindow") then
					driveNpc(att)
				end
			end)
		end
	end
	if data.KT == 0 and data.KB.Y > 0 and not data.RD then
		data.KT = 0.01 -- vertical-only kick still goes to the owner
	end
	data.H = vic.Hum.Health -- (what the blow left)
	data.GS = vic.GoreStage or 0 -- (and how far the body has come apart: every client shows it on the blow)
	Event:FireAllClients("Hit", data)
	return data
end

---------------------------------------------------------------------------
-- strike jobs: the striking limb swept through its active frames, every server frame
---------------------------------------------------------------------------
-- every hittable fighter near the attacker, nearest first (a punch lands on the first body)
local function candidates(att: Entity, job: any, center: Vector3?, range: number?): { Entity }
	local list = {}
	local p = center or att.Root.Position
	local r = range or 14
	for c, o in pairs(entities) do
		if c ~= att.Char and not job.Hit[c] and hittable(o) then
			local d = (o.Root.Position - p).Magnitude
			if d < r then
				o._d = d
				table.insert(list, o)
			end
		end
	end
	if #list > 1 then
		table.sort(list, function(a, b)
			return a._d < b._d
		end)
	end
	return list
end

-- the limb's way to the contact point is clear of solid geometry (no blows through walls)
local function clearTo(from: Vector3, to: Vector3): boolean
	local d = to - from
	if d.Magnitude < 0.05 then
		return true
	end
	return workspace:Raycast(from, d, synced(losParams)) == nil
end

-- where the attacker is for a strike at clip time tau: its own client's reports if it sent any
-- (interpolated between them, carried a moment along the last one's velocity), else the server's copy
local function strikeFrame(job: any, tau: number): CFrame
	local r = job.Reports
	if not r or #r == 0 then
		return attackFrame(job.E)
	end
	if tau <= r[1].Tau then
		return CFrame.lookAt(r[1].P, r[1].P + r[1].L)
	end
	for i = 1, #r - 1 do
		local a, b = r[i], r[i + 1]
		if tau <= b.Tau then
			local k = (tau - a.Tau) / math.max(b.Tau - a.Tau, 1e-4)
			local p = a.P:Lerp(b.P, k)
			local l = a.L:Lerp(b.L, k)
			l = if l.Magnitude > 1e-3 then l.Unit else b.L
			return CFrame.lookAt(p, p + l)
		end
	end
	local z = r[#r]
	local p = z.P + z.V * math.clamp((tau - z.Tau) / job.Def.Speed, 0, Config.Hitbox.ReportLead)
	return CFrame.lookAt(p, p + z.L)
end

---------------------------------------------------------------------------
-- Studio-only: see the capsules, the body the strike was judged against and the contact point
-- (workspace attribute CombatDebugDraw = true). Never runs in a live server.
---------------------------------------------------------------------------
local drawFolder: Folder? = nil
local function drawCapsules(key: string, acf: CFrame, vcf: CFrame, tau: number, radius: number, hit: boolean, at: Vector3?, stage: number?)
	if not STUDIO or not workspace:GetAttribute("CombatDebugDraw") then
		return
	end
	if not (drawFolder and drawFolder.Parent) then
		local f = Instance.new("Folder")
		f.Name = "CombatDebugDraw"
		f.Parent = workspace
		drawFolder = f
	end
	local function part(cf: CFrame, size: Vector3, color: Color3, shape: Enum.PartType?)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.ForceField
		p.Color = color
		p.Transparency = 0.35
		p.Shape = shape or Enum.PartType.Block
		p.Size = size
		p.CFrame = cf
		p.Parent = drawFolder
		game:GetService("Debris"):AddItem(p, 0.45)
	end
	local color = if hit then Color3.fromRGB(255, 70, 70) else Color3.fromRGB(80, 200, 255)
	for _, cap in ipairs(HitDetect.CapsulesAt(key, tau) or {}) do
		local a, b = acf * cap[1], acf * cap[2]
		local len = (b - a).Magnitude
		if len > 1e-3 then
			part(CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(len, radius * 2, radius * 2), color, Enum.PartType.Cylinder)
		end
		part(CFrame.new(b), Vector3.one * radius * 2, color, Enum.PartType.Ball)
	end
	-- the body box as it was judged (a side whose arm is gone ends at the torso)
	local B = Config.Hitbox.Body
	local shape = HitDetect.BodyFor(stage)
	part(vcf * CFrame.new((shape.R - shape.L) / 2, (B.Top + B.Bottom) / 2, 0), Vector3.new(shape.L + shape.R, B.Top - B.Bottom, B.HalfDepth * 2), Color3.fromRGB(255, 220, 90))
	if at then
		part(CFrame.new(at), Vector3.one * 0.5, Color3.new(1, 1, 1), Enum.PartType.Ball)
	end
end

local STEP_TAU = 0.02 -- the swept range is judged in slices this long (clip time)

-- (the claim side, below: a claim the server can't take, and one held for the attacker's body)
local refuse: (ent: Entity, job: any, why: string, vm: Instance?) -> ()
local retryClaim: (job: any) -> ()

-- a hit found for a strike (by the server's own sweep or a verified claim): it lands
local function landFound(job: any, found: any)
	local v = found.V
	if job.Hit[v.Char] or job.Count >= job.Max or not hittable(v) then
		return
	end
	job.Hit[v.Char] = true
	job.Count += 1
	job.HitTau = found.Tau
	job.HitAcf, job.HitVcf = found.Acf, found.Vcf -- (the two bodies as the attacker's screen had them)
	job.HitFist = found.Fist -- (where a guard meets the blow)
	applyHit(job.E, v, job.Def, found.Contact, job)
end

-- how long past its active frames a player's strike waits for its screen's verdict (a round trip,
-- and a little: the verdict leaves that screen as its own active frames end)
local function verdictWait(e: Entity): number
	return math.clamp(latency(e) * 2 + 0.2, 0.2, 0.6)
end

-- Studio (workspace attribute CombatDebugHits): one line per strike's verdict
local function hitLog(job: any, what: string, v: Entity?, tau: number?, note: string?)
	if not (STUDIO and workspace:GetAttribute("CombatDebugHits")) then
		return
	end
	local own = job.Pending
	print(string.format("[HitReg] %s#%d %-8s %s%s%s", job.Def.Id, job.Slot or 0, what,
		if v then v.Char.Name else "-",
		if tau then string.format(" at tau %.3f", tau) else "",
		(if own and what ~= "FALLBACK" then string.format("  (server sweep: hit %s at %.3f)", own.V.Char.Name, own.Tau) elseif what ~= "FALLBACK" then "  (server sweep: no hit yet)" else "")
			.. (if note then "  - " .. note else "")))
end

local function finishJob(job: any)
	if job.Dbg then
		local def = job.Def
		for c, d in pairs(job.Dbg) do
			print(string.format("[HitDbg] %s#%d -> %s  closest %.2f (r %.2f) at tau %.3f  seen (%.2f, %.2f) server (%.2f, %.2f) reports %d %s",
				def.Id, job.Slot or 0, c.Name, d.D, HitDetect.Radius(def.Id), d.Tau, d.Rel.X, d.Rel.Z, d.Now.X, d.Now.Z, d.Rep,
				if job.Hit[c] then "HIT" else "miss"))
		end
		job.Dbg = nil
	end
end

local function stepJob(job: any, t: number): boolean
	local e = job.E
	if not alive(e) then
		if job.Held then
			local info = job.Held
			job.Held = nil
			refuse(e, job, "the attacker is down", info.V)
		end
		return false
	end
	-- a claim held for the attacker's body to catch up is still judged when the strike has been cut
	-- short or a newer strike has taken over since (its impact came first on the attacker's screen)
	if job.Held then
		retryClaim(job)
	end
	if e.CancelSerial ~= job.Cancel or job.Serial ~= e.AttackSerial then
		-- (cut short, or a newer strike took over: this limb is already blending out and never
		-- lands late - its own sweep stops here)
		return job.Held ~= nil
	end
	local def = job.Def
	local path = HitDetect.Paths[def.Id]
	if not path then
		return false
	end
	-- a punch thrown with a fist that has been torn off never lands (the strike still plays)
	if goreFor(e) and not Config.CanStrike(e.GoreStage, path.Limbs) then
		return false
	end
	local tau = (t - job.Start) * def.Speed
	if tau < path.From then
		return true
	end
	-- a player's strike waits (briefly) for that player's report of where it stands
	if job.WaitReport and not job.Reports then
		if t < job.Start + path.From / def.Speed + job.WaitReport then
			return true
		end
		job.WaitReport = nil
	end
	local fromTau = job.Prev or path.From
	local toTau = math.min(tau, path.To)
	local first = job.Prev == nil
	job.Prev = toTau
	-- (a player's strike already judged by its own screen - or one the server's own sweep has found
	-- a hit for, waiting for that screen's word - needs no more sweeping)
	local settled = job.Verdict ~= nil or job.Pending ~= nil
	if (toTau > fromTau or first) and job.Count < job.Max and not settled then
		local radius = HitDetect.Radius(def.Id)
		local rewind = rewindFor(e)
		local debugHits = STUDIO and workspace:GetAttribute("CombatDebugHits")
		local slices = math.max(1, math.ceil((toTau - fromTau) / STEP_TAU - 1e-6))
		local near = candidates(e, job)
		for i = 1, slices do
			local a = fromTau + (toTau - fromTau) * (i - 1) / slices
			local b = fromTau + (toTau - fromTau) * i / slices
			local mid = (a + b) * 0.5
			local acf = strikeFrame(job, mid)
			local seenAt = job.Start + mid / def.Speed - rewind
			for _, v in ipairs(near) do
				if job.Count >= job.Max or job.Pending then
					break
				end
				if job.Hit[v.Char] or not hittable(v) then
					continue
				end
				local vcf = rewoundFrame(v, seenAt)
				-- (a lost arm: that side of the body is narrower, and a limb gone never lands)
				local hit, at, fist = HitDetect.Sweep(def.Id, acf, vcf, a, b, radius, stageAt(v, seenAt), if goreFor(e) then e.GoreStage else 0)
				if debugHits then
					-- Studio tuning: remember how close each strike came to each body
					job.Dbg = job.Dbg or {}
					local dist = HitDetect.Closest(def.Id, acf, vcf, a, b)
					local cur = job.Dbg[v.Char]
					if not cur or dist < cur.D then
						local rel = acf:PointToObjectSpace(vcf.Position)
						local srv = attackFrame(e):PointToObjectSpace(v.Root.Position)
						job.Dbg[v.Char] = { D = dist, Tau = b, Rel = rel, Now = srv, Hit = hit, Rep = job.Reports and #job.Reports or 0 }
					end
				end
				if STUDIO then
					drawCapsules(def.Id, acf, vcf, b, radius, hit, at, stageAt(v, seenAt))
				end
				if hit then
					local contact = at or acf:PointToWorldSpace(def.Contact)
					-- (a low blow is checked to the knee, so a bump in the floor never eats a sweep)
					local losTo = Vector3.new(contact.X, math.max(contact.Y, vcf.Position.Y - 1.2), contact.Z)
					if clearTo(acf.Position + Vector3.new(0, 1, 0), losTo) then
						local found = { V = v, Contact = contact, Tau = b, Acf = acf, Vcf = vcf, Fist = fist }
						if job.Claim then
							-- a player's strike: its own screen decides (Service.ClaimHit); this is kept
							-- only in case no word comes from it
							job.Pending = found
						else
							landFound(job, found)
						end
					end
				end
			end
			if job.Count >= job.Max or job.Pending then
				break
			end
		end
	end
	if tau >= path.To then
		-- a player's strike waits (briefly) for its screen's verdict; none coming, the server's own
		-- sweep decides
		if job.Held or (job.Claim and job.Verdict == nil and t < job.Start + path.To / def.Speed + verdictWait(e)) then
			return true
		end
		if job.Claim and job.Verdict == nil and job.Pending then
			hitLog(job, "FALLBACK", job.Pending.V, job.Pending.Tau, "no word from the attacker's screen: the server's own sweep lands it")
			landFound(job, job.Pending)
		end
		job.Pending = nil
		job.Done = true
		finishJob(job)
		return false
	end
	return true
end

-- the stomp: when the feet touch down, everyone standing on the shattered ground round the stomping
-- foot is hit (an area move: every body in reach, up to MaxTargets)
local function stompHit(e: Entity, def: any, job: any, center: Vector3)
	local reach = def.StompRadius + (def.StompFoot or 0)
	local seenAt = now() - rewindFor(e)
	local eye = center + Vector3.new(0, 1.5, 0)
	for _, v in ipairs(candidates(e, job, center, reach + 4)) do
		if job.Count >= job.Max then
			break
		end
		local vcf = rewoundFrame(v, seenAt)
		local d = vcf.Position - center
		local horiz = Vector3.new(d.X, 0, d.Z).Magnitude
		local feetY = vcf.Position.Y - 3
		local inReach = horiz <= reach and feetY >= center.Y - def.StompLow and feetY <= center.Y + def.StompHeight
		if STUDIO and workspace:GetAttribute("CombatDebugHits") then
			print(string.format("[HitDbg] Stomp -> %s  horiz %.2f (reach %.2f)  feet %+.2f of ground  %s", v.Char.Name, horiz, reach, feetY - center.Y, if inReach then "IN" else "out"))
		end
		if inReach and clearTo(eye, vcf.Position) then
			job.Hit[v.Char] = true
			job.Count += 1
			local at = vcf.Position + Vector3.new(0, -2.2, 0) - flat(d) * 0.6
			applyHit(e, v, def, at, job)
		end
	end
end

RunService.Heartbeat:Connect(function()
	if #jobs == 0 then
		return
	end
	local t = now()
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		local ok, keep = pcall(stepJob, job, t)
		if not ok then
			warn("[Combat] strike job:", keep)
			keep = false
		end
		if not keep and jobs[i] == job then
			table.remove(jobs, i)
		end
	end
end)

---------------------------------------------------------------------------
-- strikes
---------------------------------------------------------------------------
-- NPC movers (players move on their own client): the same step-in and carry a player's body gets
-- (CombatChoreo) - straight along the NPC's own facing, never toward anybody - one drive carrying
-- both, so a new strike's step never cuts off the last one's carry
local function aheadFor(e: Entity): (Vector3) -> number?
	return function(dir: Vector3): number?
		local roots = {}
		for c, o in pairs(entities) do
			if c ~= e.Char and alive(o) and o.State ~= "Ragdolled" then
				table.insert(roots, o.Root.Position)
			end
		end
		return Choreo.Ahead(e.Root.Position, dir, roots)
	end
end

driveNpc = function(e: Entity)
	local mv = e.Move
	if not mv then
		return
	end
	local left = Choreo.Remaining(mv, now())
	if left <= 0.005 then
		return
	end
	local last = now()
	local ahead = aheadFor(e)
	Motion.Drive(e.Root, left, function()
		local n = now()
		local dt = math.max(0, n - last)
		last = n
		if e.Move ~= mv then
			return Vector3.zero
		end
		if mv.Step and (mv.Step.Serial ~= e.AttackSerial or e.State ~= "Attacking") then
			mv.Step = nil
		end
		return Choreo.Velocity(mv, n, dt, ahead)
	end, { StopAtWalls = true, Ignore = characterList() })
end

local function npcStep(e: Entity, def: any, enter: number, start: number, chained: boolean)
	local step: any = Choreo.NewStep(def, enter, flat(bodyFrame(e).LookVector), start, chained)
	if not step then
		return
	end
	step.Serial = e.AttackSerial
	e.Move = e.Move or {}
	e.Move.Step = step
	task.delay(math.max(0, step.T0 - now()), function()
		if e.Move and e.Move.Step == step and e.AttackSerial == step.Serial then
			driveNpc(e)
		end
	end)
end

-- how long the strike owns the character (then ComboWindow / Idle)
local function busyFor(def: any): number
	if def.Id == "Downslam" then
		return def.Hang + def.MaxFall + def.LengthReal -- cut short at touchdown
	end
	if def.Id == "Sweep" or def.Id == "DashAttack" then
		return def.LengthReal + (def.Hold or 0)
	end
	return def.ChainReal + 0.08
end

-- a strike the server won't finish (the Ground Smash that never really jumped or never landed):
-- the character is free again and its owner's client drops the clip
local function cancelStrike(e: Entity, job: any)
	if e.AttackSerial ~= job.Serial then
		return
	end
	e.AttackSerial += 1
	e.Attack = nil
	if e.State == "Attacking" then
		setState(e, "Idle", nil, true)
	end
	if e.Player then
		Event:FireClient(e.Player, "Cancel", { Seq = job.Seq, K = job.Def.Id })
	elseif e.AC then
		e.AC:StopMany(ATTACK_ANIMS, 0.12)
	end
end

local function runStomp(e: Entity, def: any, job: any, start: number, serial: number)
	task.wait(math.max(0, start + def.Hang - now()))
	local deadline = start + def.Hang + def.MaxFall
	local function still(): boolean
		return e.CancelSerial == job.Cancel and e.AttackSerial == serial and alive(e) and e.State == "Attacking"
	end
	-- the owner's claim that it jumped only stands if this server sees the jump too (its copy of
	-- the body trails by the replication delay: give it a moment to leave the ground). A stomp
	-- straight off the floor is never a stomp.
	local seen = wentUp(e)
	local seenBy = now() + 0.4
	while still() and not seen and now() < seenBy do
		RunService.Heartbeat:Wait()
		seen = wentUp(e)
	end
	if not still() then
		return
	end
	if not seen then
		cancelStrike(e, job)
		return
	end
	-- everyone else sees the drop's wind (the owner's client already shows it)
	Event:FireAllClients("FX", { Kind = "Descent", A = e.Char })
	-- the fall, until the feet are really down: the server's copy lands, or the owner reports a
	-- touchdown the server has checked (on solid ground under it, see ReportFrame)
	while still() and not job.Landed and airborne(e) and now() < deadline do
		RunService.Heartbeat:Wait()
	end
	if not still() then
		return
	end
	local landCf = if job.LandCf then job.LandCf else attackFrame(e)
	local grounded = job.Landed or not airborne(e)
	-- the smash lands on the floor under the stomping foot - that foot over a ledge's edge: the floor
	-- under the body - or nowhere (the void, a fall that never ended): never in the air, never under
	-- the map (the owner's screen picks the same point: CombatClient.stompPoint)
	local foot = landCf:PointToWorldSpace(def.Contact)
	local center = nil
	if grounded then
		center = groundBelow(foot + Vector3.new(0, 2.5, 0), 6) or footingBelow(landCf.Position, 3 + 1.3)
	end
	if not center then
		cancelStrike(e, job)
		return
	end
	task.wait(def.StompDelay)
	if not still() then
		return
	end
	Event:FireAllClients("FX", { Kind = "Slam", A = e.Char, P = center })
	stompHit(e, def, job, center)
	setState(e, "Attacking", math.max(0.05, def.RecoverReal - def.StompDelay), true)
end

-- start a strike. start = when it began (wall clock); prev = the chain strike it follows (nil: none)
-- - the pair's transition decides where its clip enters (Config.Transitions), and every clip time
-- of the strike (its hit, its chain point, its active frames) is counted from the clip's own zero.
-- link = a landed smash this strike carries on (Downslam.Opens): its chain and its count go on
local function startAttack(e: Entity, name: string, slot: number, start: number, seq: number?, prev: string?, link: any?): any
	local def = Config.Attacks[name]
	local blend, enter = Config.Transition(prev, name)
	local clipStart = start - enter / def.Speed
	e.AttackSerial += 1
	local serial = e.AttackSerial
	e.Attack = { Def = def, Name = name, Start = clipStart, Serial = serial, Slot = slot }
	if link then
		e.ChainHits = link.Hits
	elseif slot <= 1 then
		e.ChainHits = 0 -- a fresh chain (or a standalone strike) starts a fresh count
		e.ChainId += 1 -- ...and is a new chain for the one-chain-per-stun rule
	end
	setState(e, "Attacking", math.max(0.05, clipStart + busyFor(def) - now()), true)
	if e.Npc and e.AC then
		for _, k in ipairs(ATTACK_ANIMS) do
			if k ~= def.Anim then
				e.AC:Stop(k, blend)
			end
		end
		local track = e.AC:Play(def.Anim, { Fade = blend, Speed = def.Speed, Restart = true, Time = enter })
		if name ~= "Downslam" then
			npcTailFade(e, track, def, serial)
		end
		npcStep(e, def, enter, start, slot > 1)
	end
	local job: any = {
		E = e, Def = def, Start = clipStart, Cancel = e.CancelSerial, Serial = serial, Hit = {}, Count = 0, Slot = slot,
		Anim = def.Anim, Seq = seq, ChainId = e.ChainId,
		Max = def.MaxTargets or Config.Hitbox.MaxTargets,
		Chain = table.clone(e.Chain), -- (as it stood when this strike started)
	}
	if e.Player and seq then
		job.WaitReport = math.min(Config.Hitbox.ReportWait, latency(e) * 2 + 0.1)
		-- (a player's single-target strike is judged by its own screen, verified: Service.ClaimHit)
		job.Claim = Config.Hitbox.Claims ~= false and name ~= "Downslam" and job.Max == 1
	end
	e.Job = job
	if name == "Downslam" then
		-- the stomp lands when the body does (the owner's clip holds its raised-knee pose until then)
		task.spawn(runStomp, e, def, job, start, serial)
		return job
	end
	table.insert(jobs, job)
	return job
end

--[[ an attack request. info = { Kind = "Light" | "Heavy", Air = bool, Want = slot the client plays,
	Seq = the client's request number (its position reports name the strike by it),
	H = (Air) the client's height above the ground }
	Returns ok, attack, slot, chain snapshot { Slot, Heavy, Lights, Enter (where the clip entered),
	Stage (the gore stage it was decided at) } ]]
function Service.RequestAttack(char: Model, info: any?): (boolean, string?, number?, any?)
	local e = entities[char]
	if not alive(e) then
		return false
	end
	local ent = e :: Entity
	local t = now()
	info = info or {}
	local kind = if info.Kind == "Heavy" then "Heavy" else "Light"
	local start = t - latency(ent)
	-- players get a little slack for the network; NPCs are on the server's own clock
	local slack = if ent.Npc then 0 else Config.Combo.Slack
	-- lost arms: one left throws single strikes with that hand; none, no attack at all - not even
	-- the Ground Smash (Config.Gore, Config.CanUse)
	local stage = if goreFor(ent) then ent.GoreStage or 0 else 0
	if Config.ArmsAt(stage) == 0 then
		return false
	end
	-- forward dash + M1
	if ent.State == "Dashing" then
		local dash = Config.Dash[ent.DashDir or ""]
		local into = t - ent.DashStart
		if kind == "Light" and info.Air ~= true and ent.DashDir == "Forward" and dash and into >= dash.AttackFrom - 0.05 and into <= dash.AttackTo + slack and t >= ent.DashAttackUntil and Config.CanUse(stage, "DashAttack") then
			local def = Config.Attacks.DashAttack
			ent.DashAttackUntil = t + def.LengthReal + def.Cooldown
			-- (inside a landed smash's stun it carries that smash's chain on)
			local link = if ent.Link and t <= ent.Link.Until + slack and ent.Link.ChainId == ent.ChainId then ent.Link else nil
			ent.Link = nil
			endChain(ent)
			Rules.Commit(ent.Chain, "DashAttack", 1, false, 1, start, stage)
			startAttack(ent, "DashAttack", 1, start, info.Seq, nil, link)
			return true, "DashAttack", 1, { Slot = 1, Heavy = false, Lights = 1, Enter = 0, Stage = stage }
		end
		return false
	end
	if not States.Allows(ent.State, "Attack") then
		return false
	end
	-- jump + M1: GROUND SMASH, a standalone move. Never out of a live chain or its window (it can't
	-- be comboed into), never while a strike owns the body, never twice inside its cooldown - and
	-- only once the body is in the air. The body's position reaches the server a moment after the
	-- jump, so wait for it briefly.
	if info.Air == true then
		local def = Config.Attacks.Downslam
		local function allowed(): boolean
			return alive(ent) and kind == "Light" and ent.State == "Idle" and not Rules.Live(ent.Chain, now(), slack)
		end
		if not allowed() or t < ent.DownslamUntil - slack or ent.AirPending then
			return false
		end
		-- the owner's own height above the ground counts too (the server's copy of its body trails
		-- by the replication delay; the stomp itself still waits for the server to see the jump)
		local claimed = type(info.H) == "number" and info.H == info.H and info.H >= 0.8 and info.H < 80
		local waitUntil = t + 0.4
		ent.AirPending = true
		while not claimed and not airborne(ent) and ent.Root.AssemblyLinearVelocity.Y < 4 do
			if now() >= waitUntil then
				ent.AirPending = false
				return false
			end
			RunService.Heartbeat:Wait()
			if not allowed() then
				ent.AirPending = false
				return false
			end
		end
		ent.AirPending = false
		if not allowed() then
			return false
		end
		-- starting it ends whatever chain was left
		endChain(ent)
		ent.DownslamUntil = t + def.LengthReal + def.Cooldown
		setCooldown(ent, "Downslam", def.LengthReal + def.Cooldown)
		startAttack(ent, "Downslam", 0, start, info.Seq, nil)
		return true, "Downslam", 0, nil
	end
	-- the chain: while a strike still owns the character only its chain point may be answered
	local want = if type(info.Want) == "number" then info.Want else nil
	if ent.State == "Attacking" and not Rules.Live(ent.Chain, t, slack) then
		return false
	end
	-- a player's press that reaches us a little before the chain point (hit-stop and the network
	-- shift the two clocks by a few hundredths) is held to the chain point instead of refused: the
	-- strike starts exactly there, so the chain is never faster than its own timing
	local at = t
	local c = ent.Chain
	if not ent.Npc and Rules.Live(c, t, slack) and t < c.OpenAt - slack and t >= c.OpenAt - Config.Combo.Buffer then
		at = c.OpenAt
		start = c.OpenAt
	end
	local verdict, name, slot, heavy, lights = Rules.Decide(c, kind, at, slack, want, stage)
	if verdict ~= "go" or not name then
		return false
	end
	if not ent.Npc and Rules.Live(c, at, slack) and start < c.OpenAt - Config.Combo.EarlyStart then
		-- never earlier than the chain point (a hair of jitter aside): the network slack widens when
		-- a press may arrive, never how fast the chain runs - a client that sends its presses early
		-- gets exactly the chain's own timing, no faster
		start = c.OpenAt - Config.Combo.EarlyStart
	end
	-- the pair: the strike it follows in this chain decides how its clip enters (and so where its
	-- chain point falls) - the attacking client works it out the same way
	local prev = if (slot :: number) > 1 then c.Last else nil
	local _, enter = Config.Transition(prev, name :: string)
	Rules.Commit(ent.Chain, name :: string, slot :: number, heavy :: boolean, lights :: number, start - enter / Config.Attacks[name :: string].Speed, stage)
	startAttack(ent, name :: string, slot :: number, start, info.Seq, prev)
	return true, name, slot, { Slot = ent.Chain.Slot, Heavy = ent.Chain.Heavy, Lights = ent.Chain.Lights, Enter = enter, Stage = stage }
end

-- a player's report of where its own screen has its body during a strike (see Config.Hitbox)
local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

function Service.ReportFrame(char: Model, info: any)
	local e = entities[char]
	if not alive(e) or type(info) ~= "table" then
		return
	end
	local ent = e :: Entity
	local job = ent.Job
	if not job or job.Seq == nil or info.Seq ~= job.Seq or job.Cancel ~= ent.CancelSerial or job.Serial ~= ent.AttackSerial then
		return
	end
	local p, l, v, tau = info.P, info.L, info.V, info.Tau
	if typeof(p) ~= "Vector3" or typeof(l) ~= "Vector3" or typeof(v) ~= "Vector3" or type(tau) ~= "number" then
		return
	end
	if not (finite(p) and finite(l) and finite(v)) or tau ~= tau then
		return
	end
	local land = info.Land == true and job.Def.Id == "Downslam"
	-- the report may lead the server's copy by what the body's own speed covers in a round trip -
	-- never more (a report is where the body is, not a reach extension)
	local H = Config.Hitbox
	local rtt = latency(ent) * 2
	local allow = math.min(H.ReportDriftMax, H.ReportDrift + recentSpeed(ent) * (rtt + H.Rewind))
	local drift = p - ent.Root.Position
	if math.abs(drift.Y) > (if land then H.ReportDriftLand else 8) then
		return
	end
	local fd = Vector3.new(drift.X, 0, drift.Z)
	if fd.Magnitude > allow then
		if land then
			return
		end
		-- further ahead of this copy than the body can have got: pulled back to that limit (never
		-- a reach extension, and never thrown away for the copy that trails the real body)
		p = ent.Root.Position + fd.Unit * allow + Vector3.new(0, drift.Y, 0)
	end
	local look = Vector3.new(l.X, 0, l.Z)
	if look.Magnitude < 0.5 then
		return
	end
	local vel = Vector3.new(v.X, 0, v.Z)
	if vel.Magnitude > 60 then
		vel = vel.Unit * 60
	end
	if land then
		-- a touchdown only counts ON solid ground (a real floor right under the reported feet) and
		-- never sooner than the drop can take: no smash in mid-air, no fake early landing
		if job.Landed or now() < job.Start + job.Def.Hang + 0.04 or not footingBelow(p, 3 + 1.3) then
			return
		end
		job.Landed = true
		job.LandCf = CFrame.lookAt(p, p + look.Unit)
		return
	end
	local r = job.Reports or {}
	if #r >= 4 then
		return
	end
	local entry = { P = p, L = look.Unit, V = vel, Tau = math.clamp(tau, 0, job.Def.Length or 10) }
	local at = #r + 1
	for i, o in ipairs(r) do
		if entry.Tau < o.Tau then
			at = i
			break
		end
	end
	table.insert(r, at, entry)
	job.Reports = r
end

--[[ THE ATTACKER'S SCREEN, VERIFIED (see the header). info = { Seq, V (the victim's model), T0, T1
	(the clip times of the frame the limb met it), AP / AL (the attacker's root and facing on that
	screen), VP / VL (the victim's), VS (the victim's gore stage there) } ]]
local function num(x: any): boolean
	return type(x) == "number" and x == x and math.abs(x) < 1e6
end
local function vec(x: any): boolean
	return typeof(x) == "Vector3" and finite(x)
end

-- the claim can't be taken: the server's own judgment decides the strike from here on (a hit its
-- sweep already found lands now), and the attacker's screen hears it, so a number it stamped on a
-- body the strike never touched goes at once
refuse = function(ent: Entity, job: any, why: string, vm: Instance?)
	hitLog(job, "REFUSED", if vm and vm:IsA("Model") then entities[vm :: Model] else nil, nil, why)
	job.Claim = false
	local pend = job.Pending
	job.Pending = nil
	if pend then
		landFound(job, pend)
	end
	if ent.Player and not (pend and vm == pend.V.Char) then
		Event:FireClient(ent.Player, "Claim", { Seq = job.Seq, Ok = false })
	end
end

-- judge a claim. final = no more waiting: an attacker still off its own path is pulled back to a
-- report's allowance (as a position report is). Returns "wait" while the attacker's body on this
-- server hasn't yet reached where its screen had it (its copy here trails that screen by the
-- replication delay - a lunge covers a stud or two in that time)
local function judgeClaim(ent: Entity, job: any, info: any, final: boolean): string?
	local vm = info.V
	if job.Done then
		refuse(ent, job, "it came after the strike was over", vm)
		return nil
	end
	-- (cut short - the attacker hit, stunned or knocked down - before the frame it claims: the blow
	-- never landed. A newer strike taking over since is fine: the claim's frame came first)
	local claimAt = job.Start + math.clamp(info.T1, 0, 10) / job.Def.Speed
	if job.Cancel ~= ent.CancelSerial and (ent.CancelledAt or 0) < claimAt - latency(ent) then
		refuse(ent, job, "the strike was cut short before it landed", vm)
		return nil
	end
	local v = entities[vm :: Model]
	local def = job.Def
	local path = HitDetect.Paths[def.Id]
	if not v or v == ent or not path or job.Hit[vm] or job.Count >= job.Max or not hittable(v) then
		refuse(ent, job, "not a body this strike can land on", vm)
		return nil
	end
	local H = Config.Hitbox
	local t = now()
	local rtt = latency(ent) * 2
	local back = math.clamp(rtt + H.Rewind + 0.25, 0.3, 0.8)
	local since = job.ClaimedAt or t
	-- the attacker: on the path its own body has taken here (from a moment before the claim came
	-- until now), or - once waiting is over - a report's allowance from where this copy is
	local ap: Vector3 = info.AP
	local _, _, aoff = nearestOnPath(ent, ap, since - back, t)
	if aoff > H.ClaimSlack then
		-- ...or where this copy is heading: its own velocity carried over the delay it trails its
		-- screen by (a lunge in progress) - this copy's own motion, never the claim's
		local v = ent.Root.AssemblyLinearVelocity
		local lead = Vector3.new(v.X, 0, v.Z) * math.clamp(rtt * 0.5 + H.Rewind + 0.08, 0.15, 0.4)
		local p0 = ent.Root.Position
		local len2 = lead:Dot(lead)
		local k = if len2 > 1e-6 then math.clamp((ap - p0):Dot(lead) / len2, 0, 1) else 0
		aoff = math.min(aoff, (ap - (p0 + lead * k)).Magnitude)
	end
	local alook = Vector3.new(info.AL.X, 0, info.AL.Z).Unit
	local turned = turnFrom(ent, alook, since - back - 0.3) > H.ClaimTurn
	if aoff > H.ClaimSlack or turned then
		if not final then
			return "wait"
		end
		if turned then
			refuse(ent, job, "facing its body never had", vm)
			return nil
		end
		local drift = ap - ent.Root.Position
		local allow = math.min(H.ReportDriftMax, H.ReportDrift + recentSpeed(ent) * (rtt + H.Rewind))
		local fd = Vector3.new(drift.X, 0, drift.Z)
		if math.abs(drift.Y) > 8 then
			refuse(ent, job, "attacker far off its own body", vm)
			return nil
		end
		if fd.Magnitude > allow then
			ap = ent.Root.Position + fd.Unit * allow + Vector3.new(0, drift.Y, 0)
		end
	end
	local T0 = math.clamp(info.T0, path.From, path.To)
	local T1 = math.clamp(info.T1, path.From, path.To)
	-- the victim: on (or a hair off) the path its body really took over the rewind window
	local vp, vlook, off = nearestOnPath(v, info.VP, since - back, since)
	if off <= H.ClaimSlack then
		vp = info.VP
		local cl = Vector3.new(info.VL.X, 0, info.VL.Z)
		if cl.Magnitude > 0.5 and math.deg(math.acos(math.clamp(cl.Unit:Dot(vlook), -1, 1))) <= 60 then
			vlook = cl.Unit
		end
	end
	-- the gore stage it saw on the victim (the narrower side of a body missing an arm), if the body
	-- really was at that stage in the window
	local vs = stageAt(v, since)
	if num(info.VS) and (info.VS == vs or info.VS == stageAt(v, since - back)) then
		vs = info.VS
	end
	local acf = CFrame.lookAt(ap, ap + alook)
	local vcf = CFrame.lookAt(vp, vp + vlook)
	-- the very test that screen ran, on the very frames
	local hit, contact, fist = HitDetect.Sweep(def.Id, acf, vcf, T0, T1, HitDetect.Radius(def.Id) + H.ClaimPad, vs, if goreFor(ent) then ent.GoreStage else 0)
	if STUDIO then
		drawCapsules(def.Id, acf, vcf, T1, HitDetect.Radius(def.Id), hit, contact, vs)
	end
	if not hit or not contact then
		refuse(ent, job, string.format("the limb misses it there (closest %.2f, reach %.2f, attacker %.2f / victim %.2f off their paths)", HitDetect.Closest(def.Id, acf, vcf, T0, T1), HitDetect.Radius(def.Id), aoff, off), vm)
		return nil
	end
	local losTo = Vector3.new(contact.X, math.max(contact.Y, vcf.Position.Y - 1.2), contact.Z)
	if not clearTo(acf.Position + Vector3.new(0, 1, 0), losTo) then
		refuse(ent, job, "a wall between them", vm)
		return nil
	end
	job.Verdict = "Hit"
	job.Held = nil
	hitLog(job, "HIT", v, T1, string.format("verified %.0f ms after it came%s", (t - since) * 1000, if off > H.ClaimSlack then string.format(", victim judged back on its path (%.2f off)", off) else ""))
	job.Pending = nil
	landFound(job, { V = v, Contact = contact, Tau = T1, Acf = acf, Vcf = vcf, Fist = fist })
	return nil
end

-- a held claim, looked at again each frame until the attacker's body here catches up with it (or
-- the wait is over)
retryClaim = function(job: any)
	local info = job.Held
	if not info then
		return
	end
	local final = now() >= job.HeldUntil
	if judgeClaim(job.E, job, info, final) ~= "wait" then
		job.Held = nil
	end
end

function Service.ClaimHit(char: Model, info: any)
	local e = entities[char]
	if not alive(e) or type(info) ~= "table" then
		return
	end
	local ent = e :: Entity
	local job = ent.Job
	if not job or not job.Claim or job.Verdict ~= nil or job.Held or job.Seq == nil or info.Seq ~= job.Seq then
		return
	end
	local vm = info.V
	if not (typeof(vm) == "Instance" and vm:IsA("Model") and num(info.T0) and num(info.T1) and vec(info.AP) and vec(info.AL) and vec(info.VP) and vec(info.VL)) then
		return refuse(ent, job, "malformed", nil)
	end
	if Vector3.new(info.AL.X, 0, info.AL.Z).Magnitude < 0.5 then
		return refuse(ent, job, "no facing", vm)
	end
	local def = job.Def
	local path = HitDetect.Paths[def.Id]
	local H = Config.Hitbox
	local t = now()
	-- the frame: inside the active frames, a frame or two wide, and one the attacker's clock had
	-- really reached (its strike started at job.Start on this clock)
	if not path or info.T1 < info.T0 or info.T1 - info.T0 > H.ClaimSpan or info.T1 < path.From - 0.02 or info.T0 > path.To + 0.02 then
		return refuse(ent, job, string.format("clip times %.3f..%.3f", info.T0, info.T1), vm)
	end
	local at = job.Start + math.clamp(info.T1, path.From, path.To) / def.Speed
	if at > t + H.ClaimLead then
		return refuse(ent, job, string.format("a frame %.0f ms ahead of its strike's own clock", (at - t) * 1000), vm)
	end
	job.ClaimedAt = t
	if judgeClaim(ent, job, info, false) == "wait" then
		job.Held = info
		job.HeldUntil = t + math.clamp(latency(ent) * 2 + H.ClaimHold, H.ClaimHold, 0.8)
		if STUDIO and workspace:GetAttribute("CombatDebugHits") then
			print(string.format("[HitReg] %s#%d held: the attacker's body here hasn't reached where its screen had it yet", def.Id, job.Slot or 0))
		end
	end
end

-- the attacker's screen saw its strike's active frames end without touching anybody
function Service.Whiff(char: Model, info: any)
	local e = entities[char]
	if not e or type(info) ~= "table" then
		return
	end
	local job = e.Job
	if not job or not job.Claim or job.Verdict ~= nil or job.Seq == nil or info.Seq ~= job.Seq then
		-- (a strike the next one has already taken over from: nothing left to decide - the Studio
		-- hit log still hears it)
		if STUDIO and workspace:GetAttribute("CombatDebugHits") and type(info.Seq) == "number" and not (job and info.Seq == job.Seq) then
			print(string.format("[HitReg] strike %d WHIFF    - (heard after the next strike began)", info.Seq))
		end
		return
	end
	job.Verdict = "Whiff"
	hitLog(job, "WHIFF", nil, nil, if job.Pending then "the attacker's screen never touched it: dropped" else nil)
	job.Pending = nil
end

---------------------------------------------------------------------------
-- dash / block
---------------------------------------------------------------------------
function Service.RequestDash(char: Model, dir: string): boolean
	local e = entities[char]
	if not alive(e) then
		return false
	end
	local ent = e :: Entity
	local def = Config.Dash[dir]
	if not def or type(def) ~= "table" or not def.Distance then
		return false
	end
	local t = now()
	-- (a strike's recovery ends on its owner's screen half a round trip before it ends here: a dash
	-- sent the moment it ended there - the chase out of a smash - lands as it ends here)
	local ending = ent.State == "Attacking" and ent.StateUntil ~= nil and ent.StateUntil - t <= latency(ent) + 0.05
	if not (States.Allows(ent.State, "Dash") or ending) or t < ent.DashCooldownUntil - 0.05 then
		return false
	end
	if ending then
		ent.Attack = nil
	end
	local start = t - latency(ent)
	endChain(ent)
	ent.DashDir = dir
	ent.DashStart = start
	setState(ent, "Dashing", math.max(0.05, start + def.Lock - t), true)
	local cooldown = Config.DashCooldownFor(if goreFor(ent) then ent.GoreStage else 0)
	ent.DashCooldownUntil = start + def.Lock + cooldown
	setCooldown(ent, "Dash", def.Lock + cooldown)
	if ent.Npc and ent.AC then
		ent.AC:Play(def.Anim, { Fade = 0.06, Speed = def.Speed, Restart = true })
	end
	-- everyone sees the kick-off burst (the dasher's own client already played it)
	Event:FireAllClients("FX", { Kind = "Dash", A = ent.Char, Dir = dir })
	return true
end

function dropGuard(ent: Entity)
	ent.ReleaseQueued = false
	if ent.State == "Blocking" then
		setState(ent, "Idle", nil, true)
		if ent.Npc and ent.AC then
			ent.AC:Stop("Block", 0.12)
		end
	end
end

function Service.RequestBlock(char: Model, on: boolean): boolean
	local e = entities[char]
	if not alive(e) then
		return false
	end
	local ent = e :: Entity
	local t = now()
	if on then
		ent.ReleaseQueued = false
		if ent.State == "Blocking" then
			return true
		end
		if not States.Allows(ent.State, "Block") or t < ent.ReblockAt then
			return false
		end
		-- no arms, no guard
		if goreFor(ent) and Config.ArmsAt(ent.GoreStage) == 0 then
			return false
		end
		endChain(ent)
		ent.BlockStartAt = t
		setState(ent, "Blocking", nil, true)
		if ent.Npc and ent.AC then
			ent.AC:Play("Block", { Fade = 0.1 })
		end
		return true
	else
		if ent.State == "Blocking" and t < ent.BlockStunUntil then
			-- still absorbing a blow: the guard comes down when the block stun ends
			ent.ReleaseQueued = true
			return true
		end
		dropGuard(ent)
		return true
	end
end

---------------------------------------------------------------------------
-- death / kills
---------------------------------------------------------------------------
local streaks: { [Player]: number } = {}

function Service._onDied(e: Entity)
	-- once per body: a dead humanoid pushed into the Physics state (the ragdoll fall) drops back into
	-- Dead and fires Died again
	if e.DeathHandled then
		return
	end
	e.DeathHandled = true
	interrupt(e)
	setState(e, "Dead", nil, true)
	-- the body goes limp (joints stay intact, nothing is destroyed) - thrown by the knockout blow
	local ko = e.KOLaunch
	e.KOLaunch = nil
	local legs, torso, spin = Vector3.new(0, 2, 0), Vector3.new(0, 2, 0), Vector3.zero
	if ko and ko.Att then
		legs, torso, spin = launchVectors(e, ko.Att, ko.Launch)
	end
	local function limp()
		if not e.Char.Parent then
			return
		end
		Ragdoll.Enable(e.Char, legs, torso, spin)
		if e.Npc then
			Motion.Stop(e.Root, true)
			Ragdoll.ApplyFall(e.Char)
		end
	end
	if ko and ko.Delay and ko.Delay > 0 then
		task.delay(ko.Delay, limp)
	else
		limp()
	end
	if e.Player then
		streaks[e.Player] = 0
	end
	local killer = e.LastHitBy
	if killer and typeof(killer) == "Instance" and killer:IsA("Player") and now() - e.LastHitAt <= Config.KillCredit and killer ~= e.Player then
		questStat(killer, "Kills", 1)
		streaks[killer] = (streaks[killer] or 0) + 1
		questStat(killer, "KillStreak", streaks[killer])
	end
end

Players.PlayerRemoving:Connect(function(p)
	streaks[p] = nil
end)

---------------------------------------------------------------------------
-- timers: states that end by themselves, combo windows, queued guard drops, the stun budget
---------------------------------------------------------------------------
local TIMED = { Attacking = true, ComboWindow = true, Dashing = true, Stunned = true, GuardBroken = true, Recovering = true }

-- Studio: the numbers the combat debug overlay shows (CombatClient), as character attributes
local debugAcc = 0
local function publishDebug(e: Entity, t: number)
	local c = e.Char
	c:SetAttribute("Dbg_Chain", string.format("#%d slot %d%s", e.ChainId, e.Chain.Slot, if e.Chain.Heavy then " +heavy" else ""))
	c:SetAttribute("Dbg_Budget", math.floor(e.Budget * 100 + 0.5) / 100)
	c:SetAttribute("Dbg_Immune", math.max(0, math.floor((e.StunImmuneUntil - t) * 100 + 0.5) / 100))
	c:SetAttribute("Dbg_Control", math.floor(controlFor(e, t) * 100 + 0.5) / 100)
end

RunService.Heartbeat:Connect(function(dt: number)
	local t = now()
	debugAcc += dt
	local publish = STUDIO and debugAcc >= 0.1
	if publish then
		debugAcc = 0
		-- (only while somebody has the debug overlay open: CombatDebug on a player)
		publish = false
		for _, p in ipairs(Players:GetPlayers()) do
			if p:GetAttribute("CombatDebug") == true then
				publish = true
				break
			end
		end
	end
	for _, e in pairs(entities) do
		-- a body that lost its root (fell off the world) is finished
		if e.Root.Parent == nil and e.Hum.Health > 0 and e.Hum.Parent then
			e.Hum.Health = 0
		end
		record(e, t)
		local s = e.State
		if e.StateUntil and t >= e.StateUntil and TIMED[s] then
			e.StateUntil = nil
			if s == "Stunned" then
				e.StunChainStart = nil
			end
			if e.Npc and e.AC and (s == "Stunned" or s == "GuardBroken") then
				e.AC:StopMany(REACTIONS, 0.2)
			end
			if s == "Attacking" then
				e.Attack = nil
				-- a live chain keeps the character in its combo window until the window closes
				if Rules.Live(e.Chain, t) then
					setState(e, "ComboWindow", math.max(0.02, e.Chain.CloseAt - t), true)
				else
					setState(e, "Idle", nil, true)
				end
			else
				setState(e, "Idle", nil, true)
			end
		elseif e.StateUntil and t >= e.StateUntil then
			e.StateUntil = nil
		end
		if e.State == "Blocking" and e.ReleaseQueued and t >= e.BlockStunUntil then
			dropGuard(e)
		end
		-- a chain whose window ran out is over (kept a little past the edge for late packets)
		if e.Chain.Slot > 0 and t > e.Chain.CloseAt + Config.Combo.Slack * 2 and e.State ~= "Attacking" then
			endChain(e)
		end
		-- the stun budget refills only with real control (and only after Grace of it)
		if e.Budget < SB.Max and e.ControlSince and t - e.ControlSince >= SB.Grace then
			e.Budget = math.min(SB.Max, e.Budget + dt * SB.Max / SB.Refill)
		end
		escapeLog(e, t)
		if e.Reserve > 0 and t >= e.RegenAt then
			regen(e, dt)
		end
		if publish then
			publishDebug(e, t)
		end
	end
end)

return Service
