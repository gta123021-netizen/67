--[[
	CombatService  (ServerScriptService.Combat.CombatService)
	The authority. Every fighter (player or NPC) is an entity with one state (CombatStates) and one
	combo chain (ComboRules). Clients only ASK ("Attack", "Dash", "Block"); this module decides which
	strike happens, runs the striking limb's measured path through its active frames (HitDetect),
	and applies what connects. Clients never tell the server what they hit.

	A connecting strike, all in the server frame the limb reaches the body:
	  1 validated: the victim is hittable (state, i-frames, Invulnerable), the limb's way to the
	    contact point is clear of geometry, this strike hasn't touched it yet, and - once the chain is
	    locked - it is the locked fighter
	  2 guard:     facing the attacker with the guard up -> blocked (25% damage, push, guard gives)
	               unless the strike breaks guards (finisher sweep, stomp) -> guard break
	  3 damage, then reaction side (which way the blow drove the head), then hitstun long enough for
	    the fastest follow-up of the attacker's chain (paid from the victim's stun budget), knockback /
	    launch
	  4 hit-stop: the attacker's chain timing is pushed back by the freeze its clip takes
	  5 one "Hit" broadcast: every client plays the spark, sound, give and (the victim) reaction

	COMBO TARGET LOCK. The second consecutive strike of a chain that connects with the same fighter
	locks the chain onto them (Config.Lock): every later strike of that chain (lights, the uppercut,
	the sweep) tests only that fighter's body. It belongs to the chain (its ChainId) and ends with it:
	the window running out, the sweep, a dash / block / Ground Smash, the attacker being hit, knocked
	down or killed, the victim dying or leaving. The attacker's client hears it on every Hit ("LK")
	and uses it to face and space the strikes.

	STUN BUDGET. Every fighter can only be held in hitstun for Config.StunBudget.Max seconds before it
	gets a real window to act (Config.StunImmunity): the budget refills only while the fighter has
	control. Together with "one chain per stun" (resetLocked) no restart - waiting out the window,
	block / dash / jump cancels, the uppercut re-opening, the Ground Smash, two or three attackers
	taking turns - can hold anyone forever, while a legitimate string always fits.

	Ability hooks (other server scripts):
	  local Combat = require(ServerScriptService.Combat.CombatService)
	  Combat.Lock(char, "M1" | "Dash" | "Block" | "Move" | "All", key, seconds?)  / Combat.Unlock(char, key)
	  Combat.Stun(char, seconds)            Combat.Knockdown(char, fromChar?, seconds?)
	  Combat.SetState(char, "UsingAbility", seconds?)  -- an ability owns the character
	  Combat.SetInvulnerable(char, seconds) -- nothing connects for a while
	  Combat.GetState(char)                 Combat.PlayAnimation(char, key, opts) (NPCs; players: client)
	  Combat.Interrupt(char)                cancels whatever the character was doing
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
local HitDetect = require(script.Parent:WaitForChild("HitDetect"))
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent

local Service = {}

export type Entity = {
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

local STUDIO = RunService:IsStudio()
local SB = Config.StunBudget

-- collision groups for the stomp's shattered ground (built on every client): its thrown chunks
-- (Debris) roll and bounce on the map and off the broken rock (ShatterRock), but never touch a
-- fighter; the broken rock stops chunks and nothing else
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
		group("ShatterRock")
		PhysicsService:CollisionGroupSetCollidable("Debris", "Fighters", false)
		PhysicsService:CollisionGroupSetCollidable("Debris", "Debris", false)
		PhysicsService:CollisionGroupSetCollidable("ShatterRock", "Fighters", false)
		PhysicsService:CollisionGroupSetCollidable("ShatterRock", "Default", false)
		PhysicsService:CollisionGroupSetCollidable("ShatterRock", "ShatterRock", false)
	end)
	if not ok then
		warn("[Combat] collision groups:", err)
	end
end

-- every part of a fighter's body (and anything added to it later: accessories, the ragdoll rig)
-- is a Fighter, so the shatter's chunks and rock pass through bodies
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
local EMPTY = table.freeze({})

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
local function setState(e: Entity, s: string, duration: number?, force: boolean?): boolean
	s = States.Resolve(s)
	if e.State == "Dead" and s ~= "Dead" then
		return false
	end
	if not force and e.State ~= s and not States.CanEnter(e.State, s) then
		return false
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
Service._setState = setState

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
		Lock = nil, -- { Target = Entity, ChainId = number }: the chain's locked fighter
		Streak = nil, -- { Target = Entity, ChainId = number, Slot = number }: the last strike's first body
		Attack = nil,
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
		InvulnerableUntil = 0,
		LastReactAt = -1,
		LastReactRank = 0,
		LastHitBy = nil,
		LastHitAt = 0,
		AirPending = false,
		Locks = {},
		Conns = {},
	}
	entities[char] = e
	rebuildCharList()
	Ragdoll.Setup(char)
	table.insert(e.Conns, fighterParts(char))
	char:SetAttribute("CombatState", "Idle")
	char:SetAttribute("CombatEntity", true)
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
	table.insert(e.Conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			Service.Unregister(char)
		end
	end))
	return e
end

local jobs: { any } = {}

-- nobody keeps a reference to a fighter that is gone (or dead): locks, streaks, stun owners, jobs
local function forget(gone: Entity, includeStunOwner: boolean)
	for _, o in pairs(entities) do
		if o.Lock and o.Lock.Target == gone then
			o.Lock = nil
		end
		if o.Streak and o.Streak.Target == gone then
			o.Streak = nil
		end
		if includeStunOwner and o.LastStunBy == gone then
			o.LastStunBy = nil
		end
	end
	for _, job in ipairs(jobs) do
		if job.Lock == gone then
			job.Lock = nil
			job.LockLost = true
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
	e.Lock = nil
	e.Streak = nil
	e.LastStunBy = nil
	forget(e, true)
end

local function alive(e: Entity?): boolean
	return e ~= nil and e.Char.Parent ~= nil and e.Root.Parent ~= nil and e.Hum.Health > 0 and e.State ~= "Dead"
end
Service.Alive = alive

---------------------------------------------------------------------------
-- ability locks
---------------------------------------------------------------------------
local LOCK_KINDS = { M1 = true, Dash = true, Block = true, Move = true, All = true }

function Service.Lock(char: Model, kind: string, key: string, seconds: number?)
	local e = entities[char]
	if not e or not LOCK_KINDS[kind] then
		return
	end
	e.Locks[key] = { Kind = kind, Until = if seconds then now() + seconds else math.huge }
	char:SetAttribute("CombatLock_" .. kind, true)
end

function Service.Unlock(char: Model, key: string)
	local e = entities[char]
	if not e then
		return
	end
	local l = e.Locks[key]
	e.Locks[key] = nil
	if l then
		local still = false
		for _, o in pairs(e.Locks) do
			if o.Kind == l.Kind and o.Until > now() then
				still = true
			end
		end
		if not still then
			char:SetAttribute("CombatLock_" .. l.Kind, nil)
		end
	end
end

local function locked(e: Entity, kind: string): boolean
	local t = now()
	for key, l in pairs(e.Locks) do
		if l.Until <= t then
			e.Locks[key] = nil
			e.Char:SetAttribute("CombatLock_" .. l.Kind, nil)
		elseif l.Kind == kind or l.Kind == "All" then
			return true
		end
	end
	return false
end

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

local function hittable(e: Entity): boolean
	return alive(e)
		and States.Allows(e.State, "Hittable")
		and now() >= e.InvulnerableUntil
		and e.Char:GetAttribute("Invulnerable") ~= true
end

-- a server-approved cooldown the owner's HUD shows (server time, so every clock agrees)
local function setCooldown(e: Entity, key: string, seconds: number)
	e.Char:SetAttribute("CombatCD_" .. key, workspace:GetServerTimeNow() + seconds)
	e.Char:SetAttribute("CombatCDLen_" .. key, seconds)
end

---------------------------------------------------------------------------
-- chains, target lock, cancelling
---------------------------------------------------------------------------
local function clearLock(e: Entity)
	e.Lock = nil
	e.Streak = nil
end

-- the chain is over: its count, its slot and its target lock go with it
local function endChain(e: Entity)
	Rules.Reset(e.Chain)
	e.ChainHits = 0
	clearLock(e)
end

-- the fighter this entity's live chain is locked onto (nil: none, or no longer valid)
local function currentLock(e: Entity): Entity?
	local l = e.Lock
	if not l then
		return nil
	end
	local target = l.Target
	if l.ChainId ~= e.ChainId or e.Chain.Slot == 0 or not alive(target) or entities[target.Char] ~= target then
		e.Lock = nil
		return nil
	end
	return target
end
Service.CurrentLock = currentLock

-- cancels the entity's current action (strike / dash / stomp) and its combo chain
local function interrupt(e: Entity)
	e.AttackSerial += 1
	e.CancelSerial += 1
	e.Attack = nil
	e.Step = nil
	e.Follow = nil
	endChain(e)
	if e.Npc and e.AC then
		e.AC:StopMany(ATTACK_ANIMS, 0.08)
		e.AC:StopMany(DASH_ANIMS, 0.08)
		e.AC:Stop("Block", 0.1)
		Motion.Stop(e.Root)
	end
end

Service.Interrupt = function(char: Model)
	local e = entities[char]
	if e then
		interrupt(e)
		if e.State ~= "Ragdolled" and e.State ~= "Dead" then
			setState(e, "Idle", nil, true)
		end
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

-- a clean hit's knockback (world, studs/s)
local function knockVector(att: Entity, vic: Entity, k: any): Vector3
	local acf = bodyFrame(att)
	local away = vic.Root.Position - att.Root.Position
	away = flat(if away.Magnitude > 0.2 then away else acf.LookVector)
	return away * (k.Back or 0) + Vector3.new(0, k.Up or 0, 0) + acf.RightVector * (k.Side or 0)
end

-- a blocked hit's slide: straight back from the attacker, angled toward the side the blow drove
local function blockPush(att: Entity, vic: Entity, class: any, dir: number): (Vector3, number)
	local dist = class.BlockPush or 0
	local time = class.BlockPushTime or 0
	if dist <= 0 or time <= 0 then
		return Vector3.zero, 0
	end
	local away = flat(vic.Root.Position - att.Root.Position)
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
local function launchVectors(vic: Entity, att: Entity?, launch: any): (Vector3, Vector3, Vector3)
	local legs, torso, spin = Vector3.new(0, 8, 0), Vector3.new(0, 6, 0), Vector3.zero
	if att and att.Root.Parent then
		local acf = bodyFrame(att)
		local away = flat(vic.Root.Position - att.Root.Position)
		local right = acf.RightVector
		local up = Vector3.yAxis
		torso = away * (launch.Back or 0) + up * (launch.Up or 0) + right * (launch.Side or 0)
		legs = away * (launch.Back or 0) * 0.55 + up * (launch.LegsUp or launch.Up or 0) + right * (launch.LegsSide or 0)
		spin = up:Cross(away).Unit * (launch.Tip or 0)
	end
	return legs, torso, spin
end

-- knock a fighter off its feet (after `delay`: the blow's hit-stop)
local function knockDown(vic: Entity, att: Entity?, launch: any, delay: number?)
	interrupt(vic)
	setState(vic, "Ragdolled", nil, true)
	vic.LastStunBy = nil -- the combo on them is over
	vic.StunChainStart = nil
	local serial = vic.StateSerial
	local legs, torso, spin = launchVectors(vic, att, launch)
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

function Service.Knockdown(char: Model, fromChar: Model?, seconds: number?)
	local vic = entities[char]
	if not alive(vic) or (vic :: Entity).State == "Ragdolled" then
		return
	end
	local att = if fromChar then entities[fromChar] else nil
	knockDown(vic :: Entity, att, { Back = 16, Up = 18, LegsUp = 10, Tip = 2.5, Time = seconds or 1.3 })
end

-- how long the fighter has been in control without a break (0 while it isn't)
local function controlFor(e: Entity, t: number): number
	return if e.ControlSince then t - e.ControlSince else 0
end

-- can a blow stun this fighter right now? (not in its escape window, budget left)
local function canStun(vic: Entity, t: number): boolean
	return t >= vic.StunImmuneUntil and vic.Budget >= SB.Min
end

-- spend stun budget; running dry opens the escape window after `endsAt`
local function spend(vic: Entity, seconds: number, endsAt: number)
	vic.Budget = math.max(0, vic.Budget - seconds)
	if vic.Budget < SB.Min then
		vic.StunImmuneUntil = math.max(vic.StunImmuneUntil, endsAt + Config.StunImmunity)
	end
end

-- stun bookkeeping shared by hits and Service.Stun. Returns the stun left (seconds).
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

function Service.Stun(char: Model, seconds: number)
	local vic = entities[char]
	if alive(vic) and States.Allows((vic :: Entity).State, "Reacts") and canStun(vic :: Entity, now()) then
		interrupt(vic :: Entity)
		stun(vic :: Entity, seconds)
	end
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
-- applying a connected strike
---------------------------------------------------------------------------
-- ONE CHAIN PER STUN. A victim still reeling from an attacker's chain (or with less than
-- Config.Combo.ResetGrace of control since) can't be locked again by a NEW chain from that same
-- attacker: waiting out the window, block / dash / jump cancelling, re-opening with the uppercut,
-- a dash strike or a Ground Smash would otherwise restart the string on a body that never got to
-- act. The blow still lands (damage, push, give) but doesn't stun or interrupt. Launchers still
-- knock down only as a chain's own finisher.
local function resetLocked(att: Entity, vic: Entity, t: number): boolean
	return vic.LastStunBy == att and vic.LastStunChain ~= att.ChainId and controlFor(vic, t) < Config.Combo.ResetGrace
end

local function applyHit(att: Entity, vic: Entity, def: any, contact: Vector3, job: any)
	local t = now()
	local class = def.ClassDef
	local reaction, dir = reactionFor(att, vic, def, contact)
	-- the strike's own lock (a finisher keeps the one its chain had), else the chain's
	local lockT = job.Lock or currentLock(att)
	local standalone = (job.Slot or 0) <= 0
	local data: any = {
		A = att.Char, V = vic.Char, K = def.Id, R = reaction, Dir = dir, P = contact, Rank = def.Rank,
		B = false, G = false, RD = false, IM = false, D = 0, S = 0, KB = Vector3.zero, KT = 0, RS = def.React,
		HS = class.Hitstop, CH = 0, Slot = job.Slot or 0,
		LK = if lockT == vic then vic.Char else nil,
	}
	-- no stun for this fighter now: its escape window, its budget spent, or a restarted chain
	local immune = not canStun(vic, t) or resetLocked(att, vic, t)
	-- guard: facing the attacker with the guard up (and up long enough)
	local toAtt = att.Root.Position - vic.Root.Position
	local facing = flat(vic.Root.CFrame.LookVector):Dot(flat(toAtt)) > Config.Guard.Arc
	local guarded = vic.State == "Blocking" and facing and t >= vic.BlockStartAt + Config.Guard.StartDelay
	if STUDIO and vic.State == "Blocking" and not guarded and workspace:GetAttribute("CombatDebugHits") then
		print(string.format("[HitDbg] guard missed: facing dot %.2f, up for %.2f", flat(vic.Root.CFrame.LookVector):Dot(flat(toAtt)), t - vic.BlockStartAt))
	end
	local dmg = 0
	if guarded and def.GuardBreak and not immune then
		-- guard break: shattered, not knocked down (they tried to block): the directional reaction,
		-- slowed, a controlled slide, then a moment before the guard can go up again
		dmg = def.GuardBreakDamage or def.Damage * 0.5
		data.G = true
		data.HS = Config.Guard.BreakHitstop
		guardBreak(vic)
		data.S = Config.Guard.BreakStun
		data.RS = Config.Guard.BreakReactSpeed
		data.KB = knockVector(att, vic, def.Knock)
		data.KB = Vector3.new(data.KB.X, 0, data.KB.Z)
		data.KT = def.KnockTime or 0.25
		questStat(vic.Player, "Blocks", 1)
	elseif guarded then
		-- blocked (a guard breaker against a fighter in its escape window is held off like a heavy blow)
		local bc = if def.GuardBreak then Config.Classes.Heavy else class
		dmg = def.Damage * Config.Guard.DamageScale
		data.B = true
		data.HS = bc.BlockHitstop
		data.KB, data.KT = blockPush(att, vic, bc, dir)
		vic.BlockStunUntil = math.max(vic.BlockStunUntil, t + (bc.BlockStun or 0) + data.HS)
		questStat(vic.Player, "Blocks", 1)
	else
		dmg = def.Damage
	end
	-- damage. The blow that knocks them out throws the body: the strike's own launch (the sweep,
	-- the stomp), or the KO throw straight back from the attacker for any other blow - after the
	-- hit-stop, so the knockout lands on the blow's frame
	data.D = dmg
	if vic.Hum.Health > 0 and dmg >= vic.Hum.Health then
		vic.KOLaunch = { Att = att, Launch = def.Launch or Config.KOLaunch, Delay = data.HS }
	end
	vic.Hum:TakeDamage(dmg)
	vic.LastHitBy = att.Player or att.Char
	vic.LastHitAt = t
	if att.Player and vic.Char ~= att.Char then
		questStat(att.Player, "Hits", 1)
		questStat(att.Player, "Damage", dmg)
	end
	local reacts = States.Allows(vic.State, "Reacts") and vic.Hum.Health > 0
	if not data.B and not data.G and reacts then
		local launch = def.Launch
		-- a standalone launcher (the Ground Smash) never takes down a fighter still reeling from a
		-- combo, and nothing takes down or stuns a fighter in its escape window: those get the give
		-- and a push, and keep control
		local reeling = vic.State == "Stunned" or vic.State == "GuardBroken"
		local held = immune or (launch ~= nil and standalone and reeling)
		if launch and not held then
			data.RD = true
			knockDown(vic, att, launch, data.HS)
		elseif not held then
			-- being hit breaks your own strike / dash / guard and your chain
			if vic.State ~= "Stunned" then
				interrupt(vic)
			else
				endChain(vic)
			end
			local need = math.max(def.Stun or 0, Rules.CoverStun(att.Chain, def))
			data.S = stun(vic, need + data.HS)
			vic.LastStunBy = att
			vic.LastStunChain = att.ChainId
			vic.LastStunEnd = t + data.S
			data.KB = knockVector(att, vic, def.Knock)
			data.KT = def.KnockTime or 0.12
		else
			data.IM = true
			local kb = knockVector(att, vic, def.Knock) * 0.5
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
			local tr = vic.AC:PlayFresh(reaction, { Fade = 0.05, Speed = 0 })
			task.delay(hs, function()
				if tr and tr.IsPlaying and vic.StateSerial == serial then
					tr:AdjustSpeed(data.RS)
				end
			end)
		elseif not data.B and restart and data.S > 0 then
			local tr = vic.AC:PlayFresh(reaction, { Fade = 0.05, Speed = 0 })
			task.delay(hs, function()
				if tr and tr.IsPlaying and vic.StateSerial == serial then
					tr:AdjustSpeed(data.RS)
				end
			end)
		end
		if data.KT > 0 then
			local kb, kt = data.KB, data.KT
			task.delay(hs, function()
				if vic.Root.Parent and vic.State ~= "Ragdolled" and vic.State ~= "Dead" then
					Motion.Push(vic.Root, kb, kt, characterList())
				end
			end)
		elseif data.KB.Y > 0 then
			Motion.Push(vic.Root, data.KB, 0)
		end
	end
	-- an NPC attacker is carried along with its victim's slide (players do this on their own client)
	if att.Npc and not data.B and not data.G and not data.RD and data.KT > 0.02 and def.Class ~= "Dash" then
		local f = { Vec = Vector3.new(data.KB.X, 0, data.KB.Z) * Config.Hitbox.Follow, T0 = now() + data.HS, Dur = data.KT }
		att.Follow = f
		task.delay(data.HS, function()
			if att.Follow == f and (att.State == "Attacking" or att.State == "ComboWindow") then
				driveNpc(att)
			end
		end)
	end
	if data.KT == 0 and data.KB.Y > 0 and not data.RD then
		data.KT = 0.01 -- vertical-only kick still goes to the owner
	end
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

-- who this strike may hit: a locked chain tests only its locked fighter (the fast path)
local function targetsFor(att: Entity, job: any): { Entity }
	if job.LockLost then
		return EMPTY
	end
	local lockT = job.Lock
	if not lockT and (job.Slot or 0) > 0 then
		local l = att.Lock
		if l and l.ChainId == job.ChainId then
			lockT = l.Target
			job.Lock = lockT
		end
	end
	if lockT then
		if job.Hit[lockT.Char] or entities[lockT.Char] ~= lockT or not hittable(lockT) then
			return EMPTY
		end
		job.One = job.One or {}
		job.One[1] = lockT
		return job.One
	end
	return candidates(att, job)
end

-- the limb's way to the contact point is clear of solid geometry (no blows through walls)
local function clearTo(from: Vector3, to: Vector3): boolean
	local d = to - from
	if d.Magnitude < 0.05 then
		return true
	end
	return workspace:Raycast(from, d, synced(losParams)) == nil
end

-- the second consecutive strike of the chain whose first contact is the same fighter locks the
-- chain onto that fighter (Config.Lock.Hits). Only chain strikes count; a strike that connects
-- with nobody breaks the run (the slots stop being consecutive).
local function noteContact(att: Entity, job: any, vic: Entity)
	if job.Primary then
		return
	end
	job.Primary = vic
	if (job.Slot or 0) <= 0 or currentLock(att) then
		return
	end
	local s = att.Streak
	if s and s.ChainId == job.ChainId and s.Target == vic and s.Slot == job.Slot - 1 then
		s.Count += 1
		s.Slot = job.Slot
		if s.Count >= Config.Lock.Hits then
			att.Lock = { Target = vic, ChainId = job.ChainId }
			job.Lock = vic
		end
	else
		att.Streak = { Target = vic, ChainId = job.ChainId, Slot = job.Slot, Count = 1 }
		if Config.Lock.Hits <= 1 then
			att.Lock = { Target = vic, ChainId = job.ChainId }
			job.Lock = vic
		end
	end
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
local function drawCapsules(key: string, acf: CFrame, vcf: CFrame, tau: number, radius: number, hit: boolean, at: Vector3?)
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
	local B = Config.Hitbox.Body
	part(vcf * CFrame.new(0, (B.Top + B.Bottom) / 2, 0), Vector3.new(B.HalfWidth * 2, B.Top - B.Bottom, B.HalfDepth * 2), Color3.fromRGB(255, 220, 90))
	if at then
		part(CFrame.new(at), Vector3.one * 0.5, Color3.new(1, 1, 1), Enum.PartType.Ball)
	end
end

local STEP_TAU = 0.02 -- the swept range is judged in slices this long (clip time)

local function finishJob(job: any)
	local e = job.E
	-- a chain strike that touched nobody breaks the run toward a lock
	if (job.Slot or 0) > 0 and not job.Primary and e.Streak and e.Streak.ChainId == job.ChainId then
		e.Streak = nil
	end
	if job.Dbg then
		local def = job.Def
		for c, d in pairs(job.Dbg) do
			print(string.format("[HitDbg] %s#%d -> %s  closest %.2f (r %.2f) at tau %.3f  seen (%.2f, %.2f) server (%.2f, %.2f) reports %d %s%s",
				def.Id, job.Slot or 0, c.Name, d.D, (def.Hitbox or 0.5) + Config.Hitbox.Pad, d.Tau, d.Rel.X, d.Rel.Z, d.Now.X, d.Now.Z, d.Rep,
				if job.Hit[c] then "HIT" else "miss", if job.Lock then "  [locked]" else ""))
		end
		job.Dbg = nil
	end
end

local function stepJob(job: any, t: number): boolean
	local e = job.E
	if e.CancelSerial ~= job.Cancel or not alive(e) then
		return false
	end
	-- a newer strike took over: this limb is already blending out and never lands late
	if job.Serial ~= e.AttackSerial then
		return false
	end
	local def = job.Def
	local path = HitDetect.Paths[def.Id]
	if not path then
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
	job.Prev = toTau
	if toTau >= fromTau and job.Count < job.Max then
		local radius = (def.Hitbox or 0.5) + Config.Hitbox.Pad
		local rewind = rewindFor(e)
		local debugHits = STUDIO and workspace:GetAttribute("CombatDebugHits")
		local slices = math.max(1, math.ceil((toTau - fromTau) / STEP_TAU - 1e-6))
		for i = 1, slices do
			local a = fromTau + (toTau - fromTau) * (i - 1) / slices
			local b = fromTau + (toTau - fromTau) * i / slices
			local mid = (a + b) * 0.5
			local acf = strikeFrame(job, mid)
			local seenAt = job.Start + mid / def.Speed - rewind
			for _, v in ipairs(targetsFor(e, job)) do
				if job.Count >= job.Max then
					break
				end
				local vcf = rewoundFrame(v, seenAt)
				local hit, at = HitDetect.Sweep(def.Id, acf, vcf, a, b, radius)
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
					drawCapsules(def.Id, acf, vcf, b, radius, hit, at)
				end
				if hit then
					local contact = at or acf:PointToWorldSpace(def.Contact)
					-- (a low blow is checked to the knee, so a bump in the floor never eats a sweep)
					local losTo = Vector3.new(contact.X, math.max(contact.Y, vcf.Position.Y - 1.2), contact.Z)
					if clearTo(acf.Position + Vector3.new(0, 1, 0), losTo) then
						job.Hit[v.Char] = true
						job.Count += 1
						noteContact(e, job, v)
						applyHit(e, v, def, contact, job)
					end
				end
			end
			if job.Count >= job.Max then
				break
			end
		end
	end
	if tau >= path.To then
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
-- NPC movers (players move on their own client): the same step-in + follow as the client's, one
-- drive carrying both so a new strike's step never cuts off the slide along with the last victim
local function npcFollowVel(e: Entity): Vector3
	local f = e.Follow
	if not f then
		return Vector3.zero
	end
	local t = now() - f.T0
	if t < 0 or t >= f.Dur then
		return Vector3.zero
	end
	local k = 1 - t / f.Dur
	return f.Vec * (0.35 + 0.65 * k * k)
end

local function npcStepVel(e: Entity, dt: number): Vector3
	local s = e.Step
	if not s or s.Serial ~= e.AttackSerial or e.State ~= "Attacking" then
		return Vector3.zero
	end
	local t = now() - s.T0
	if t < 0 or t >= s.Dur or not s.Target.Root.Parent then
		return Vector3.zero
	end
	local d = s.Target.Root.Position - e.Root.Position
	local fd = Vector3.new(d.X, 0, d.Z)
	if fd.Magnitude < 0.05 then
		return Vector3.zero
	end
	local want = math.min(math.max(0, fd.Magnitude - s.Ideal), s.Budget - s.Travelled)
	local speed = math.clamp(want / math.max(s.Dur - t, 1 / 60) * 1.15, 0, 42) * math.min(1, t / 0.04)
	s.Travelled += speed * dt
	return fd.Unit * speed
end

driveNpc = function(e: Entity)
	local t = now()
	local left = 0
	if e.Step and e.Step.Serial == e.AttackSerial then
		left = math.max(left, e.Step.T0 + e.Step.Dur - t)
	end
	if e.Follow then
		left = math.max(left, e.Follow.T0 + e.Follow.Dur - t)
	end
	if left <= 0.005 then
		return
	end
	local last = t
	Motion.Drive(e.Root, left, function()
		local n = now()
		local dt = math.max(0, n - last)
		last = n
		return npcStepVel(e, dt) + npcFollowVel(e)
	end, { StopAtWalls = true, Ignore = characterList() })
end

local function npcLunge(e: Entity, def: any, target: Entity?)
	if not target or def.MaxLunge <= 0 then
		return
	end
	local t0 = (def.LungeFrom or 0) / def.Speed
	local dur = math.max(0.05, ((def.LungeTo or 0.3) - (def.LungeFrom or 0)) / def.Speed)
	local serial = e.AttackSerial
	task.delay(t0, function()
		if e.AttackSerial ~= serial or e.State ~= "Attacking" then
			return
		end
		e.Step = { Serial = serial, T0 = now(), Dur = dur, Target = target, Ideal = def.Ideal, Budget = def.MaxLunge, Travelled = 0 }
		driveNpc(e)
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
	-- the smash lands on the floor under the stomping foot, or nowhere (a ledge, the void, a fall
	-- that never ended): never in the air, never under the map
	local foot = landCf:PointToWorldSpace(def.Contact)
	local center = if grounded then groundBelow(foot + Vector3.new(0, 2.5, 0), 6) else nil
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
	setState(e, "Attacking", math.max(0.05, (def.Length - def.StompAt) / def.Speed - def.StompDelay), true)
end

local function startAttack(e: Entity, name: string, slot: number, start: number, target: Entity?, seq: number?, lock: Entity?): any
	local def = Config.Attacks[name]
	e.AttackSerial += 1
	local serial = e.AttackSerial
	local prev = e.Attack and e.Attack.Name
	e.Attack = { Def = def, Name = name, Start = start, Serial = serial, Slot = slot }
	if slot <= 1 then
		e.ChainHits = 0 -- a fresh chain (or a standalone strike) starts a fresh count
		e.ChainId += 1 -- ...and is a new chain for the one-chain-per-stun rule and the target lock
	end
	setState(e, "Attacking", math.max(0.05, start + busyFor(def) - now()), true)
	if e.Npc and e.AC then
		for _, k in ipairs(ATTACK_ANIMS) do
			if k ~= def.Anim then
				e.AC:Stop(k, 0.07)
			end
		end
		e.AC:Play(def.Anim, { Fade = Config.BlendInto(prev, name), Speed = def.Speed, Restart = true })
		npcLunge(e, def, target)
	end
	local job: any = {
		E = e, Def = def, Start = start, Cancel = e.CancelSerial, Serial = serial, Hit = {}, Count = 0, Slot = slot,
		Anim = def.Anim, Seq = seq, ChainId = e.ChainId, Lock = lock,
		Max = if lock then 1 else (def.MaxTargets or Config.Hitbox.MaxTargets),
	}
	if e.Player and seq then
		job.WaitReport = math.min(Config.Hitbox.ReportWait, latency(e) * 2 + 0.1)
	end
	e.Job = job
	if name ~= "Downslam" then
		-- everyone else hears the limb cut the air (the attacker's own client already plays it)
		Event:FireAllClients("FX", { Kind = "Swing", A = e.Char, K = name })
	end
	if name == "Downslam" then
		-- the stomp lands when the body does (the owner's clip holds its raised-knee pose until then)
		task.spawn(runStomp, e, def, job, start, serial)
		return job
	end
	table.insert(jobs, job)
	return job
end

-- nearest valid target in front (NPC AI + step-in for NPCs)
function Service.FindTarget(e: Entity, range: number, angleDeg: number): Entity?
	local best, bestD = nil, range
	local look = flat(e.Root.CFrame.LookVector)
	local cosA = math.cos(math.rad(angleDeg))
	for c, o in pairs(entities) do
		if c ~= e.Char and alive(o) then
			local d = o.Root.Position - e.Root.Position
			local fd = Vector3.new(d.X, 0, d.Z)
			local dist = fd.Magnitude
			if dist < bestD and (dist < 0.5 or look:Dot(fd.Unit) >= cosA) then
				best, bestD = o, dist
			end
		end
	end
	return best
end

--[[ an attack request. info = { Kind = "Light" | "Heavy", Air = bool, Want = slot the client plays,
	Seq = the client's request number (its position reports name the strike by it),
	H = (Air) the client's height above the ground }
	Returns ok, attack, slot, chain snapshot { Slot, Heavy, Lights, Lock } ]]
function Service.RequestAttack(char: Model, info: any?): (boolean, string?, number?, any?)
	local e = entities[char]
	if not alive(e) then
		return false
	end
	local ent = e :: Entity
	local t = now()
	info = info or {}
	local kind = if info.Kind == "Heavy" then "Heavy" else "Light"
	if locked(ent, "M1") then
		return false
	end
	local start = t - latency(ent)
	-- players get a little slack for the network; NPCs are on the server's own clock
	local slack = if ent.Npc then 0 else Config.Combo.Slack
	-- forward dash + M1
	if ent.State == "Dashing" then
		local dash = Config.Dash[ent.DashDir or ""]
		local into = t - ent.DashStart
		if kind == "Light" and info.Air ~= true and ent.DashDir == "Forward" and dash and into >= dash.AttackFrom - 0.05 and into <= dash.AttackTo + slack and t >= ent.DashAttackUntil then
			ent.DashAttackUntil = t + Config.Attacks.DashAttack.LengthReal + Config.Attacks.DashAttack.Cooldown
			endChain(ent)
			startAttack(ent, "DashAttack", 0, start, nil, info.Seq)
			return true, "DashAttack", 0, nil
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
			return alive(ent) and kind == "Light" and ent.State == "Idle" and not Rules.Live(ent.Chain, now(), slack) and not locked(ent, "M1")
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
		-- starting it ends whatever chain (and target lock) was left
		endChain(ent)
		ent.DownslamUntil = t + def.LengthReal + def.Cooldown
		setCooldown(ent, "Downslam", def.LengthReal + def.Cooldown)
		startAttack(ent, "Downslam", 0, start, nil, info.Seq)
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
	local verdict, name, slot, heavy, lights = Rules.Decide(c, kind, at, slack, want)
	if verdict ~= "go" or not name then
		return false
	end
	if not ent.Npc and Rules.Live(c, at, slack) and start < c.OpenAt - Config.Combo.EarlyStart then
		-- never earlier than the chain point (a hair of jitter aside): the network slack widens when
		-- a press may arrive, never how fast the chain runs - a client that sends its presses early
		-- gets exactly the chain's own timing, no faster
		start = c.OpenAt - Config.Combo.EarlyStart
	end
	-- a strike that opens a new chain never inherits the old chain's lock
	local lock = if (slot :: number) > 1 then currentLock(ent) else nil
	if (slot :: number) <= 1 then
		clearLock(ent)
	end
	Rules.Commit(ent.Chain, name, slot :: number, heavy :: boolean, lights :: number, start)
	local target = if ent.Npc then (lock or Service.FindTarget(ent, Config.AssistRange, Config.AssistAngle)) else nil
	startAttack(ent, name, slot :: number, start, target, info.Seq, lock)
	if name == Config.Combo.Finisher then
		-- the sweep ends the chain (its own strike keeps the lock it started with)
		clearLock(ent)
	end
	return true, name, slot, { Slot = ent.Chain.Slot, Heavy = ent.Chain.Heavy, Lights = ent.Chain.Lights, Lock = if lock then lock.Char else nil }
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
	if Vector3.new(drift.X, 0, drift.Z).Magnitude > allow or math.abs(drift.Y) > (if land then H.ReportDriftLand else 8) then
		return
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
		if job.Landed or now() < job.Start + job.Def.Hang + 0.04 or not groundBelow(p, 3 + 1.3) then
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

-- old name (abilities / other scripts)
function Service.RequestM1(char: Model, info: any?): (boolean, string?, number?)
	local ok, name, slot = Service.RequestAttack(char, { Kind = "Light", Air = info and info.Air, Want = info and info.Step })
	return ok, name, slot
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
	if not States.Allows(ent.State, "Dash") or locked(ent, "Dash") or t < ent.DashCooldownUntil - 0.05 then
		return false
	end
	local start = t - latency(ent)
	endChain(ent)
	ent.DashDir = dir
	ent.DashStart = start
	setState(ent, "Dashing", math.max(0.05, start + def.Lock - t), true)
	ent.DashCooldownUntil = start + def.Lock + Config.Dash.Cooldown
	setCooldown(ent, "Dash", def.Lock + Config.Dash.Cooldown)
	if ent.Npc and ent.AC then
		ent.AC:Play(def.Anim, { Fade = 0.06, Speed = def.Speed, Restart = true })
	end
	-- everyone sees the kick-off burst (the dasher's own client already played it)
	Event:FireAllClients("FX", { Kind = "Dash", A = ent.Char, Dir = dir })
	return true
end

local function dropGuard(ent: Entity)
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
		if not States.Allows(ent.State, "Block") or locked(ent, "Block") or t < ent.ReblockAt then
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
-- ability-facing API
---------------------------------------------------------------------------
function Service.GetState(char: Model): string?
	local e = entities[char]
	return e and e.State
end

function Service.SetState(char: Model, s: string, seconds: number?)
	local e = entities[char]
	s = States.Resolve(s)
	if e and States.Rules[s] then
		interrupt(e)
		setState(e, s, seconds, true)
	end
end

function Service.SetInvulnerable(char: Model, seconds: number)
	local e = entities[char]
	if e then
		e.InvulnerableUntil = math.max(e.InvulnerableUntil, now() + seconds)
	end
end

function Service.PlayAnimation(char: Model, key: string, opts: any?)
	local e = entities[char]
	if e and e.AC then
		return e.AC:Play(key, opts)
	end
	if e and e.Player then
		Event:FireClient(e.Player, "Play", { Key = key, Opts = opts })
	end
	return nil
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
	-- nobody's chain stays locked onto a body that is down for good
	forget(e, false)
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
local TIMED = { Attacking = true, ComboWindow = true, Dashing = true, Stunned = true, GuardBroken = true, Recovering = true, UsingAbility = true }

-- Studio: the numbers the combat debug overlay shows (CombatClient), as character attributes
local debugAcc = 0
local function publishDebug(e: Entity, t: number)
	local lk = currentLock(e)
	local c = e.Char
	c:SetAttribute("Dbg_Chain", string.format("#%d slot %d%s", e.ChainId, e.Chain.Slot, if e.Chain.Heavy then " +heavy" else ""))
	c:SetAttribute("Dbg_Lock", if lk then lk.Char.Name else "")
	c:SetAttribute("Dbg_Streak", if e.Streak then string.format("%s x%d", e.Streak.Target.Char.Name, e.Streak.Count) else "")
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
		-- a chain whose window ran out is over, and its lock with it (kept a little past the edge
		-- for late packets)
		if e.Chain.Slot > 0 and t > e.Chain.CloseAt + Config.Combo.Slack * 2 and e.State ~= "Attacking" then
			endChain(e)
		elseif e.Lock then
			currentLock(e) -- drops a lock whose fighter died or left
		end
		-- the stun budget refills only with real control (and only after Grace of it)
		if e.Budget < SB.Max and e.ControlSince and t - e.ControlSince >= SB.Grace then
			e.Budget = math.min(SB.Max, e.Budget + dt * SB.Max / SB.Refill)
		end
		if publish then
			publishDebug(e, t)
		end
	end
end)

return Service
