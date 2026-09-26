--[[
	CombatClient  (StarterPlayerScripts.CombatClient)
	The local player's fighter: input, the predicted state machine and combo chain (the same
	ComboRules the server runs), every animation on your own character (combat + locomotion, one
	owner so nothing fights), dashes and step-ins, and the cosmetic side of every hit anyone lands.

	Controls (keyboard keys follow Settings > Keybinds):
	  Light (M1)  Left click / gamepad RT or X / touch ATTACK   hold to keep the chain going
	  Heavy (M2)  Right click / gamepad Y / touch HEAVY          the uppercut, once per combo
	  Block       F (hold) / gamepad LT / touch BLOCK
	  Dash        Q / gamepad B / touch DASH    direction = movement input (W/A/S/D, stick)
	  Sprint      Shift (hold) / gamepad L3 (toggle)              also: keep moving and you break into a run
	  Shift lock  Left Ctrl (toggle)   camera over the shoulder, you face where you aim
	  Forward dash + M1 = dash strike, jump + M1 = Ground Smash (never out of a live combo)

	Timing comes from CombatConfig (measured from the animation pack); the server repeats the same
	timing and has the final word (Ack corrections, Hit events, the CombatState attribute).

	FREE-FORM. No target lock, no auto-facing, no homing. A strike turns you to your AIM (quickly,
	smoothly), steps you straight along it (stopping where the body in its lane meets the limb) and,
	when it lands, carries you on along it with the blow (CombatChoreo). The victim is driven down the
	same line, so the chain holds together from any angle while you stay free to move and turn.

	THE IMPACT FRAME. Your own strike is judged on your screen too, with the server's own geometry
	(HitDetect): the frame your limb meets a body, the hit-stop, sound, effect, blood, the body's give,
	the camera and your carry all happen at once - no round trip. The server still decides damage,
	stun and knockback; its "Hit" is matched to the strike that already showed it (Seq), so nothing
	plays twice, and one your screen missed still plays when it arrives.

	PAIRS. Every chained pair has its own transition (Config.Transitions): where the next clip enters
	and how long it cross-fades out of the last one's follow-through.

	INPUT BUFFER. One press is remembered at a time (the newest): what it was, when, and which chain
	it was meant for. A strike pressed a little before its chain point fires exactly on it; a press
	(strike or dash) made a little before control comes back - the end of a stun, a dash, getting up -
	fires the moment it does. A press is used once, only for the chain it was meant for, and never
	after it has gone stale; anything that ends the chain or cancels the action drops it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local States = require(CombatFolder:WaitForChild("CombatStates"))
local Rules = require(CombatFolder:WaitForChild("ComboRules"))
local AnimController = require(CombatFolder:WaitForChild("AnimController"))
local Motion = require(CombatFolder:WaitForChild("Motion"))
local Ragdoll = require(CombatFolder:WaitForChild("Ragdoll"))
local FX = require(CombatFolder:WaitForChild("CombatFX"))
local Paths = require(CombatFolder:WaitForChild("CombatPaths"))
local Choreo = require(CombatFolder:WaitForChild("CombatChoreo"))
local HitDetect = require(CombatFolder:WaitForChild("HitDetect"))
local Request = CombatFolder:WaitForChild("CombatRequest") :: RemoteEvent
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent

local Counter: any = nil
pcall(function()
	Counter = require(script:WaitForChild("ComboCounter", 10))
end)
if not Counter then
	Counter = { Hit = function() end, Drop = function() end, Shown = function()
		return false
	end }
end

local Theme: any = nil
pcall(function()
	Theme = require(ReplicatedStorage:WaitForChild("OverkillUI", 10):WaitForChild("Theme", 10))
end)

AnimController.Preload()

local STUDIO = RunService:IsStudio()
local ATTACK_ANIMS = { "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "Downslam", "DashAttack" }
local DASH_ANIMS = { "DashForward", "DashBackward", "DashLeft", "DashRight" }
local REACTIONS = { "HitLeft", "HitRight" }
local COMBO = Config.Combo
local FACE = Config.Facing

-- the air each strike cuts (Config.Sounds)
local SWING_SOUND = { Swing1 = "Swing", Swing2 = "Swing", Swing3 = "HookSwing", Uppercut = "HeavySwing", Sweep = "SweepSwing", DashAttack = "HeavySwing" }

local DEFAULT_KEYS = { Dash = Enum.KeyCode.Q, Block = Enum.KeyCode.F, Sprint = Enum.KeyCode.LeftShift, ShiftLock = Enum.KeyCode.LeftControl }
local function keyFor(action: string): Enum.KeyCode
	local k = Theme and Theme.Keys and Theme.Keys[action]
	return if typeof(k) == "EnumItem" then k else DEFAULT_KEYS[action]
end

local function now(): number
	return os.clock()
end

-- Studio tuning: player:SetAttribute("CombatDebug", true) prints the client's combat decisions
local function dbg(...: any)
	if STUDIO and player:GetAttribute("CombatDebug") == true then
		print("[CombatDbg]", string.format("%.3f", os.clock() % 1000), ...)
	end
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

---------------------------------------------------------------------------
-- the current character
---------------------------------------------------------------------------
local ctx: any = nil

local function charList(): { Instance }
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		table.insert(list, dummies)
	end
	return list
end

-- a fighter that can still be struck (alive, on its feet)
local function standing(model: Instance?): BasePart?
	if not (model and model:IsA("Model") and model.Parent) then
		return nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local r = model:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and r and r:IsA("BasePart") and model:GetAttribute("Ragdolled") ~= true then
		return r
	end
	return nil
end

-- every other fighter's root (dashes stop in front of them instead of passing through)
local function fighterRoots(): { BasePart }
	local list = {}
	for _, m in ipairs(charList()) do
		local models = if m:IsA("Folder") then m:GetChildren() else { m }
		for _, c in ipairs(models) do
			if c ~= ctx.Char then
				local r = standing(c)
				if r then
					table.insert(list, r)
				end
			end
		end
	end
	return list
end

-- another system owns the screen or the character: combat input and movement writes pause
local function externallyLocked(): boolean
	if player:GetAttribute("QuestUIOpen") == true or player:GetAttribute("UIOverlay") ~= nil then
		return true
	end
	local cam = workspace.CurrentCamera
	return cam ~= nil and cam.CameraType == Enum.CameraType.Scriptable
end

local function inputBlocked(): boolean
	if not ctx or not ctx.Alive or ctx.Hum.Health <= 0 then
		return true
	end
	if externallyLocked() or player:GetAttribute("UIWindow") ~= nil then
		return true
	end
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function airborne(): boolean
	if not ctx then
		return false
	end
	local st = ctx.Hum:GetState()
	return st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping
end

-- free turning (AutoRotate) follows the state; the value it had is restored, so shift lock keeps working
local function updateTurn()
	local turn = States.Allows(ctx.State, "Turn")
	if turn == ctx.TurnFree or externallyLocked() then
		return
	end
	ctx.TurnFree = turn
	if turn then
		ctx.Hum.AutoRotate = ctx.SavedAutoRotate
	else
		ctx.SavedAutoRotate = ctx.Hum.AutoRotate or ctx.SavedAutoRotate
		ctx.Hum.AutoRotate = false
	end
end

---------------------------------------------------------------------------
-- the input buffer (one press, used once, only for the chain it was meant for)
---------------------------------------------------------------------------
local BUFFER_DASH = 0.15 -- a dash pressed this long before control returns still goes

local function bufferPress(kind: string)
	ctx.Buffer = Rules.BufferPress(kind, now(), ctx.ChainNo)
end

-- the buffered press, if it is still good (then it is spent). kinds: which presses this spot may use
local function takeBuffer(kinds: { [string]: boolean }, sameChain: boolean): string?
	local kind, drop = Rules.BufferTake(ctx.Buffer, kinds, now(), if sameChain then ctx.ChainNo else nil, BUFFER_DASH)
	if drop then
		ctx.Buffer = nil
	end
	return kind
end

local ATTACKS = { Light = true, Heavy = true }
local ANY_PRESS = { Light = true, Heavy = true, Dash = true }
local DASH_ONLY = { Dash = true }

local tryAttack: (string) -> ()
local tryDash: () -> ()

local function setLocal(s: string, duration: number?)
	if not ctx then
		return
	end
	local was = ctx.State
	ctx.State = s
	ctx.StateSerial += 1
	ctx.StateUntil = if duration then now() + duration else nil
	local leftReaction = (was == "Stunned" or was == "GuardBroken") and s ~= was
	if leftReaction then
		ctx.AC:StopMany(REACTIONS, 0.2)
	end
	if was == "Recovering" and s ~= "Recovering" then
		ctx.AC:Stop("GroundRecovery", 0.25)
	end
	updateTurn()
	-- control is back: a press made just before it goes off now (once)
	if (s == "Idle" or s == "ComboWindow") and ctx.Buffer then
		local kinds = if was == "Attacking" then DASH_ONLY else ANY_PRESS
		local k = takeBuffer(kinds, false)
		if k then
			local c = ctx
			task.defer(function()
				if ctx ~= c then
					return
				end
				if k == "Dash" then
					tryDash()
				else
					tryAttack(k)
				end
			end)
		end
	end
end

local function cancelActions(keepBlock: boolean?)
	if not ctx then
		return
	end
	ctx.AttackSerial += 1
	ctx.Attack = nil
	ctx.Buffer = nil
	ctx.Move = nil
	ctx.Align = nil
	ctx.DashSerial += 1
	ctx.ChainTick += 1
	ctx.AC:StopMany(ATTACK_ANIMS, 0.08)
	ctx.AC:StopMany(DASH_ANIMS, 0.08)
	if not keepBlock then
		ctx.AC:Stop("Block", 0.1)
	end
	Motion.Stop(ctx.Root)
end

local function endChain()
	Rules.Reset(ctx.Chain)
	ctx.ChainTick += 1
	ctx.ChainNo += 1 -- a new chain: presses buffered for the old one are gone
	ctx.Buffer = nil
	if os.clock() >= ctx.CounterHoldUntil then
		Counter.Drop()
	end
end

---------------------------------------------------------------------------
-- aim, facing, the attack mover
---------------------------------------------------------------------------
-- where the player aims: the camera in shift lock, else the movement input, else the facing
local function aimDirection(): Vector3
	local cam = workspace.CurrentCamera
	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter and cam then
		return flat(cam.CFrame.LookVector)
	end
	local md = ctx.Hum.MoveDirection
	if md.Magnitude > 0.1 then
		return flat(md)
	end
	return flat(ctx.Root.CFrame.LookVector)
end

-- the ONE facing controller: a critically damped turn to a direction (the aim, a dash's frame),
-- with a top turn rate - smooth, never an instant flip, and never toward a body. Runs every frame
-- while ctx.Align is set; the strike (or dash) that set it owns it (Serial), so a cancelled action
-- never turns the body again.
--   align = { Dir, Serial, Owner = "Attack" | "Dash", Until, Omega, MaxRate }
local function alignTo(dir: Vector3, owner: string, untilT: number, omega: number?, maxRate: number?)
	ctx.Align = {
		Dir = flat(dir),
		Owner = owner,
		Serial = if owner == "Dash" then ctx.DashSerial else ctx.AttackSerial,
		Until = untilT,
		Omega = omega or FACE.Omega,
		MaxRate = maxRate or FACE.MaxRate,
	}
end

local function yawOf(v: Vector3): number
	return math.atan2(-v.X, -v.Z)
end

local function alignStep(dt: number)
	local a = ctx.Align
	if not a then
		return
	end
	local serial = if a.Owner == "Dash" then ctx.DashSerial else ctx.AttackSerial
	if a.Serial ~= serial or now() > a.Until or ctx.State == "Ragdolled" or ctx.State == "Dead" then
		ctx.Align = nil
		ctx.YawVel = 0
		return
	end
	local root = ctx.Root
	-- a critically damped turn (Motion.Turn): no overshoot, never faster than MaxRate
	local cur = yawOf(flat(root.CFrame.LookVector))
	local y = (cur - yawOf(a.Dir) + math.pi) % (2 * math.pi) - math.pi
	local step, vel = Motion.Turn(y, ctx.YawVel, a.Omega, a.MaxRate, dt)
	ctx.YawVel = vel
	if math.abs(step) < 1e-5 and math.abs(y) < 1e-3 then
		return
	end
	local pos = root.Position
	root.CFrame = CFrame.new(pos) * CFrame.Angles(0, cur + step, 0)
end

-- every other fighter this screen shows standing (their roots), refreshed once a frame
local seenRoots: { Vector3 } = {}
local seenFrame = -1
local function bodiesSeen(): { Vector3 }
	local t = now()
	if t ~= seenFrame then
		seenFrame = t
		table.clear(seenRoots)
		for _, r in ipairs(fighterRoots()) do
			table.insert(seenRoots, r.Position)
		end
	end
	return seenRoots
end

-- distance along `dir` to the body in the lane ahead (nil: nobody there)
local function aheadOf(dir: Vector3): number?
	return Choreo.Ahead(ctx.Root.Position, dir, bodiesSeen())
end

-- The attack mover: ONE drive on the root carrying the strike's step-in and the last connect's
-- carry (CombatChoreo) - each straight along its own facing. Whichever starts, the drive is
-- (re)started with both, so neither cuts the other off. Walls: slides along, never through.
local function driveAttack()
	local c = ctx
	local mv = c.Move
	if not mv then
		return
	end
	local left = Choreo.Remaining(mv, now())
	if left <= 0.005 then
		return
	end
	local last = now()
	Motion.Drive(c.Root, left, function()
		if ctx ~= c or c.Move ~= mv then
			return Vector3.zero
		end
		local n = now()
		local dt = math.max(0, n - last)
		last = n
		if mv.Step and mv.Step.Serial ~= c.AttackSerial then
			mv.Step = nil
		end
		return Choreo.Velocity(mv, n, dt, aheadOf)
	end, { StopAtWalls = true, Ignore = charList() })
end

-- the strike's step-in, straight along its facing (see CombatChoreo); the foot plants on whatever
-- the ground is made of
local function stepIn(def: any, enter: number, dir: Vector3, t: number, serial: number)
	local step: any = Choreo.NewStep(def, enter, dir, t)
	if not step then
		return
	end
	step.Serial = serial
	ctx.Move = ctx.Move or {}
	ctx.Move.Step = step
	local c = ctx
	task.delay(math.max(0, step.T0 - now()), function()
		if ctx == c and c.Move and c.Move.Step == step and c.AttackSerial == serial then
			dbg("step", def.Id, aheadOf(step.Dir))
			driveAttack()
			task.delay(step.Dur, function()
				if ctx == c and step.Travelled > 0.35 and c.Root.Parent then
					FX.Footstep(c.Root.Position - Vector3.new(0, 2.9, 0), c.Hum.FloorMaterial, 0.35)
				end
			end)
		end
	end)
end

-- after a clean chain strike: the attacker carries on along its facing with the blow
local function startCarry(a: any, hitstop: number)
	local carry = Choreo.NewCarry(a.Def, flat(ctx.Root.CFrame.LookVector), now(), hitstop, ctx.Chain)
	if not carry then
		return
	end
	ctx.Move = ctx.Move or {}
	ctx.Move.Carry = carry
	local c = ctx
	dbg("carry", a.Name, carry.Speed, carry.Gap)
	task.delay(hitstop, function()
		if ctx == c and c.Move and c.Move.Carry == carry and (c.State == "Attacking" or c.State == "ComboWindow") then
			driveAttack()
		end
	end)
end

---------------------------------------------------------------------------
-- strikes
---------------------------------------------------------------------------
-- how long the strike owns the character (then the combo window / idle)
local function busyTime(def: any): number
	if def.Id == "Downslam" then
		return def.Hang + def.MaxFall + def.LengthReal -- cut short at touchdown
	end
	if def.Id == "Sweep" or def.Id == "DashAttack" then
		return def.LengthReal + (def.Hold or 0)
	end
	return def.ChainReal + 0.08
end

-- is the light attack input still physically held? (a lost release never leaves the chain running)
local function m1StillHeld(): boolean
	if not ctx or not ctx.M1Held then
		return false
	end
	local src = ctx.M1Source
	if src == "Mouse" then
		return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
	elseif src == "Gamepad" then
		return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2)
			or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonX)
	elseif src == "Touch" then
		-- the finger that pressed ATTACK: slid off the button and lifted still counts as let go
		local input = ctx.M1Input
		if input then
			local st = input.UserInputState
			if st == Enum.UserInputState.End or st == Enum.UserInputState.Cancel then
				ctx.M1Held = false
				return false
			end
		end
	end
	return true
end

-- fire the buffered (or held) next strike exactly at the chain point
local function scheduleChain()
	if not ctx then
		return
	end
	ctx.ChainTick += 1
	local my = ctx.ChainTick
	local c = ctx
	local function tick()
		if ctx ~= c or c.ChainTick ~= my or c.Chain.Slot == 0 then
			return
		end
		local wait = c.Chain.OpenAt - now()
		if wait > 0.003 then
			task.delay(wait, tick)
			return
		end
		if c.State ~= "Attacking" and c.State ~= "ComboWindow" then
			return
		end
		local k = takeBuffer(ATTACKS, true)
		dbg("tick", c.State, k, m1StillHeld())
		if k then
			tryAttack(k)
		elseif m1StillHeld() then
			tryAttack("Light")
		end
	end
	task.delay(math.max(0, c.Chain.OpenAt - now()), tick)
end

-- where this screen has the body during strike `seq`: the server judges the strike from here (its
-- own copy of the body trails a moment behind - see Config.Hitbox)
local function reportFrame(seq: number, land: boolean?)
	if not ctx then
		return
	end
	local root = ctx.Root
	local v = root.AssemblyLinearVelocity
	local track = ctx.AttackTrack
	Request:FireServer("Pos", {
		Seq = seq,
		P = root.Position,
		L = flat(root.CFrame.LookVector),
		V = Vector3.new(v.X, 0, v.Z),
		Tau = if track and track.IsPlaying then track.TimePosition else 0,
		Land = land,
	})
end

-- a non-looping clip ending by itself drops its weight to nothing on one frame (a pop back to the
-- idle pose): a strike whose clip runs out with nothing after it fades out over its last moment
local function tailFade(track: AnimationTrack?, def: any, serial: number)
	if not track then
		return
	end
	local length = def.Length
	local function check()
		if not ctx or ctx.AttackSerial ~= serial or not track.IsPlaying then
			return
		end
		local left = (length - track.TimePosition) / math.max(def.Speed, 0.05)
		if track.Speed < 0.05 or left > 0.2 then
			-- frozen (hit-stop, the stomp's hang) or not there yet: look again
			task.delay(math.max(0.03, left - 0.16), check)
			return
		end
		-- faded out just as the clip reaches its last frame
		track:Stop(math.max(0.05, left * 0.9))
	end
	task.delay(math.max(0, def.LengthReal - 0.2), check)
end

---------------------------------------------------------------------------
-- the impact frame, on this screen
---------------------------------------------------------------------------
-- which way the blow drives the victim's head (+1 = to the victim's right: HitRight) - the same
-- rule the server uses (CombatService reactionFor)
local function reactionSign(attCf: CFrame, vicCf: CFrame, def: any, contact: Vector3): number
	local push = def.ReactPush or 0
	if push ~= 0 then
		local lateral = vicCf:VectorToObjectSpace(attCf.RightVector * push)
		return if lateral.X >= 0 then 1 else -1
	end
	local r = vicCf:PointToObjectSpace(contact)
	if math.abs(r.X) < 0.15 then
		r = vicCf:PointToObjectSpace(attCf.Position)
	end
	return if r.X < 0 then -1 else 1
end

-- the bodies a strike of mine could land on, as this screen shows them
type Body = { Model: Model, Root: BasePart }
local function strikeCandidates(): { Body }
	local list: { Body } = {}
	for _, m in ipairs(charList()) do
		local models = if m:IsA("Folder") then m:GetChildren() else { m }
		for _, c in ipairs(models) do
			if c ~= ctx.Char and c:IsA("Model") and c:GetAttribute("CombatEntity") then
				local r = standing(c)
				local st = c:GetAttribute("CombatState")
				if r and st ~= "Recovering" and st ~= "Dead" and c:GetAttribute("Invulnerable") ~= true then
					table.insert(list, { Model = c, Root = r })
				end
			end
		end
	end
	return list
end

-- the limb's way to the contact point is clear of solid geometry (the server's own rule: a low blow
-- is checked to the knee, so a bump in the floor never eats a sweep)
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.RespectCanCollide = true
local function clearTo(from: Vector3, contact: Vector3, bodyY: number): boolean
	local to = Vector3.new(contact.X, math.max(contact.Y, bodyY - 1.2), contact.Z)
	local d = to - from
	if d.Magnitude < 0.05 then
		return true
	end
	losParams.FilterDescendantsInstances = charList()
	return workspace:Raycast(from, d, losParams) == nil
end

-- the attacker's side of the hit-stop: the clip freezes on contact, the chain waits for it
local function hitStop(a: any, d: number)
	if a.Stopped or d <= 0 or not (ctx.Attack and ctx.Attack.Serial == a.Serial) then
		return
	end
	a.Stopped = true
	a.T0 += d
	if a.Slot > 0 then
		Rules.Delay(ctx.Chain, d)
		scheduleChain()
	end
	if ctx.State == "Attacking" and ctx.StateUntil then
		ctx.StateUntil += d
	end
	if ctx.Align and ctx.Align.Serial == a.Serial then
		ctx.Align.Until += d
	end
	local track = ctx.AttackTrack
	if track and track.IsPlaying then
		local serial = a.Serial
		track:AdjustSpeed(0.02)
		task.delay(d, function()
			if ctx and ctx.AttackSerial == serial and track.IsPlaying then
				track:AdjustSpeed(a.Def.Speed)
			end
		end)
	end
end

-- my limb met a body on this frame: everything a landed blow is happens now
local function localImpact(a: any, victim: Model, vr: BasePart, at: Vector3)
	local def = a.Def
	local class = def.ClassDef
	local root = ctx.Root
	local acf = CFrame.lookAt(root.Position, root.Position + flat(root.CFrame.LookVector))
	local vcf = CFrame.lookAt(vr.Position, vr.Position + flat(vr.CFrame.LookVector))
	local toMe = flat(root.Position - vr.Position)
	local guarded = victim:GetAttribute("CombatState") == "Blocking" and flat(vr.CFrame.LookVector):Dot(toMe) > Config.Guard.Arc
	local brk = guarded and def.GuardBreak == true
	local blocked = guarded and not brk
	-- (a launcher inside a chain takes them down; the server may still hold it back - an escape
	-- window - and then its own word shows the rest)
	local launched = not guarded and def.Launch ~= nil and a.Slot > 0
	local hs = if brk then Config.Guard.BreakHitstop elseif blocked then class.BlockHitstop else class.Hitstop
	local drive = flat(acf.LookVector)
	a.Impact = { Victim = victim, At = at, Blocked = blocked, Break = brk, T = now() }
	ctx.Predicted[a.Seq] = a.Impact
	dbg("impact", def.Id, victim.Name, if blocked then "blocked" elseif brk then "break" else "clean")
	FX.Connect({
		Kind = def.Id, At = at, Dir = drive, Victim = victim, Attacker = ctx.Char,
		Blocked = blocked, Break = brk, Launched = launched, DirSign = reactionSign(acf, vcf, def, at), Me = "Attacker",
	})
	hitStop(a, hs)
	if not guarded and not launched and a.Slot > 0 and def.Class ~= "Dash" then
		startCarry(a, hs)
	end
end

-- judge my own strike on my own screen, every frame of its active window (the server's geometry)
local function predictImpact(a: any)
	local def = a.Def
	local path = HitDetect.Paths[def.Id]
	if not path or def.Id == "Downslam" then
		return
	end
	local c = ctx
	local radius = HitDetect.Radius(def.Id)
	local prevTau: number? = nil
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if ctx ~= c or c.AttackSerial ~= a.Serial or a.Impact then
			(conn :: RBXScriptConnection):Disconnect()
			return
		end
		local tr = c.AttackTrack
		local tau = if tr and tr.IsPlaying then tr.TimePosition else (now() - a.T0) * def.Speed
		if tau < path.From then
			return
		end
		local from = prevTau or path.From
		local to = math.min(tau, path.To)
		prevTau = to
		if to >= from then
			local root = c.Root
			local acf = CFrame.lookAt(root.Position, root.Position + flat(root.CFrame.LookVector))
			local best: Body? = nil
			local bestD, bestAt = math.huge, nil
			for _, body in ipairs(strikeCandidates()) do
				local vr = body.Root
				local dist = (vr.Position - root.Position).Magnitude
				if dist < 12 and dist < bestD then
					local vcf = CFrame.lookAt(vr.Position, vr.Position + flat(vr.CFrame.LookVector))
					local hit, at = HitDetect.Sweep(def.Id, acf, vcf, from, to, radius)
					if hit and at and clearTo(acf.Position + Vector3.new(0, 1, 0), at, vr.Position.Y) then
						best, bestD, bestAt = body, dist, at
					end
				end
			end
			if best and bestAt then
				localImpact(a, best.Model, best.Root, bestAt)
				;(conn :: RBXScriptConnection):Disconnect()
				return
			end
		end
		if tau >= path.To then
			(conn :: RBXScriptConnection):Disconnect()
		end
	end)
	table.insert(c.Conns, conn :: RBXScriptConnection)
end

-- replaySeq: re-showing a strike the server already started (no new request). prev = the chain
-- strike it follows (the pair's transition: how its clip enters, how long the two cross-fade);
-- enterOverride: the server's own entry for a replay
local function playAttack(name: string, slot: number, replaySeq: number?, prev: string?, enterOverride: number?)
	local def = Config.Attacks[name]
	local t = now()
	local seq: number
	if replaySeq then
		seq = replaySeq
	else
		ctx.Seq += 1
		seq = ctx.Seq
	end
	local blend, enter = Config.Transition(prev, name)
	if enterOverride then
		enter = enterOverride
	end
	-- a cross-fade only means something while the last strike's clip is still on screen
	if not (ctx.AttackTrack and ctx.AttackTrack.IsPlaying) then
		blend = Config.EntryBlend[name] or blend
	end
	ctx.AttackSerial += 1
	local serial = ctx.AttackSerial
	local t0 = t - enter / def.Speed -- the clip's own zero (it enters at `enter`)
	local a = { Name = name, Slot = slot, T0 = t0, Serial = serial, Seq = seq, Def = def, Stopped = false, SentAt = workspace:GetServerTimeNow(), Enter = enter }
	ctx.Attack = a
	ctx.Buffer = if ctx.Buffer and ctx.Buffer.Kind == "Dash" then ctx.Buffer else nil
	setLocal("Attacking", math.max(0.05, t0 + busyTime(def) - t))
	ctx.IdleTime = 0
	for _, k in ipairs(ATTACK_ANIMS) do
		if k ~= def.Anim then
			ctx.AC:Stop(k, blend)
		end
	end
	ctx.AC:StopMany(DASH_ANIMS, math.max(blend, 0.06))
	ctx.AC:StopMany(REACTIONS, 0.08)
	ctx.AC:StopMany({ "Jump", "Fall" }, 0.1)
	ctx.AttackTrack = ctx.AC:Play(def.Anim, { Fade = blend, Speed = def.Speed, Restart = true, Time = enter })
	tailFade(ctx.AttackTrack, def, serial)
	-- the whoosh lands with the snap of the limb, not the start of the wind-up
	task.delay(math.max(0, t0 + def.HitReal - 0.07 - t), function()
		if ctx and ctx.AttackSerial == serial then
			FX.Sound(SWING_SOUND[name] or "Swing", ctx.Root.Position, 1)
		end
	end)
	-- the sweep's leg and the uppercut's fist leave a short trail through their arc
	if name == "Sweep" or name == "Uppercut" then
		local lead = if name == "Sweep" then 0.2 else 0.12
		task.delay(math.max(0, t0 + (def.Hit - lead) / def.Speed - t), function()
			if ctx and ctx.AttackSerial == serial then
				FX.LimbTrail(ctx.Char, if name == "Sweep" then "Right Leg" else "Left Arm", lead / def.Speed + 0.08, if name == "Sweep" then "Low" else nil)
			end
		end)
	end
	-- face the aim, step straight along it (never toward anybody)
	if name ~= "Downslam" then
		local dir = aimDirection()
		ctx.AimDir = dir
		local untilT = t0 + def.HitReal + 0.1
		if name == "DashAttack" then
			alignTo(dir, "Attack", untilT, 44, 32)
		else
			alignTo(dir, "Attack", untilT)
			stepIn(def, enter, dir, t, serial)
		end
	end
	if not replaySeq then
		Request:FireServer("Attack", {
			Seq = seq,
			Kind = if name == COMBO.Heavy then "Heavy" else "Light",
			Air = name == "Downslam",
			Want = slot,
			H = if name == "Downslam" then ctx.AirHeight else nil,
		})
	end
	-- report where this screen has the body as the active frames begin and midway through them
	local path = Paths[name]
	if path and name ~= "Downslam" then
		for _, frac in ipairs({ 0, 0.5 }) do
			local tau = path.From + (path.To - path.From) * frac
			task.delay(math.max(0, t0 + tau / def.Speed - 0.012 - t), function()
				if ctx and ctx.AttackSerial == serial then
					reportFrame(seq)
				end
			end)
		end
	end
	predictImpact(a)
	if slot > 0 then
		scheduleChain()
	end
end

-- jump + M1: hang at the top, drop, and stomp the moment the feet touch the ground. The clip's
-- raised-knee pose holds until touchdown, then the stomp plays from StompAt - so the pack's stomp
-- frame is always the landing frame, whatever the jump height.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local function heightAboveGround(root: BasePart): number
	groundParams.FilterDescendantsInstances = charList()
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -60, 0), groundParams)
	return if hit then math.max(0, root.Position.Y - hit.Position.Y - 3) else 20
end

local function startDownslam()
	local def = Config.Attacks.Downslam
	ctx.DownslamBefore = ctx.DownslamUntil
	ctx.DownslamUntil = now() + def.LengthReal + def.Cooldown
	endChain()
	Motion.Stop(ctx.Root)
	ctx.AirHeight = heightAboveGround(ctx.Root)
	playAttack("Downslam", 0)
	local serial = ctx.AttackSerial
	local c = ctx
	local root = ctx.Root
	local track = ctx.AttackTrack
	local t0 = now()
	-- hang for a beat at the top
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X * 0.2, math.max(v.Y, 0) * 0.15, v.Z * 0.2)
	local fallSpeed = 0
	local conn: RBXScriptConnection? = nil
	local descent: any = nil -- the drop's wind and speed lines (CombatShatter.Descent)
	local function done()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if descent then
			descent.Stop()
			descent = nil
		end
	end
	conn = RunService.Heartbeat:Connect(function()
		if ctx ~= c or c.AttackSerial ~= serial or not root.Parent then
			done()
			if track and track.IsPlaying and track.Speed == 0 then
				track:AdjustSpeed(def.Speed)
			end
			return
		end
		local e = now() - t0
		if e < def.Hang then
			root.AssemblyLinearVelocity = Vector3.zero
			return
		end
		if fallSpeed == 0 then
			-- fall fast enough that touchdown comes about when the clip reaches its stomp
			local h = heightAboveGround(root)
			local left = math.max(0.06, def.StompAt / def.Speed - e)
			fallSpeed = math.clamp(h / left, def.FallSpeed[1], def.FallSpeed[2])
			descent = FX.Descent(c.Char, h)
		end
		local grounded = c.Hum.FloorMaterial ~= Enum.Material.Air or heightAboveGround(root) < 0.25
		if grounded or e > def.Hang + def.MaxFall then
			done()
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(root.AssemblyLinearVelocity.Y, 0), 0)
			if not grounded then
				-- the fall never ended (off a ledge, into the void): no smash - the server agrees
				if c.Attack and c.Attack.Serial == serial then
					cancelActions(true)
					setLocal("Idle")
				end
				return
			end
			if c.Attack and c.Attack.Serial == serial then
				reportFrame(c.Attack.Seq, true)
			end
			if track and track.IsPlaying then
				if track.TimePosition < def.StompAt then
					track.TimePosition = def.StompAt
				end
				track:AdjustSpeed(def.Speed)
			end
			-- the attacker's own smash lands on its own screen at once (everyone else: the server's FX)
			task.delay(def.StompDelay, function()
				if ctx == c and c.AttackSerial == serial then
					local p = root.CFrame:PointToWorldSpace(def.Contact)
					FX.Stomp(p, c.Char)
					FX.Camera(c.Hum, "Stomp", nil)
				end
			end)
			c.StateUntil = now() + math.max(0.05, (def.Length - def.StompAt) / def.Speed)
			return
		end
		-- hold the raised-knee pose until the ground is reached
		if track and track.IsPlaying and track.TimePosition >= def.StompAt - 0.02 and track.Speed ~= 0 then
			track:AdjustSpeed(0)
		end
		root.AssemblyLinearVelocity = Vector3.new(0, -fallSpeed, 0)
	end)
	table.insert(c.Conns, conn :: RBXScriptConnection)
end

local function startDashAttack()
	local def = Config.Attacks.DashAttack
	ctx.DashAttackUntil = now() + def.LengthReal + def.Cooldown
	ctx.DashSerial += 1
	endChain()
	local v = ctx.Root.AssemblyLinearVelocity
	local speed = math.max(Vector3.new(v.X, 0, v.Z).Magnitude, Config.Dash.Forward.TopSpeed * 0.6)
	local dir = flat(ctx.Root.CFrame.LookVector)
	playAttack("DashAttack", 0)
	FX.Sound("Step", ctx.Root.Position, 1)
	-- momentum carries straight into the strike, then bleeds off - stopping where the extended arm
	-- meets a body (its Ideal), never through it
	local dur = 0.24
	Motion.Drive(ctx.Root, dur, function(t)
		return dir * speed * (1 - t / dur) ^ 1.3
	end, { StopAtWalls = true, Ignore = charList(), Fighters = fighterRoots(), Gap = def.Ideal - 0.6, Width = Config.Dash.StopWidth })
end

-- a strike on the way in: M1 / M2 pressed (or fired from the buffer)
function tryAttack(kind: string)
	if inputBlocked() then
		dbg("try blocked", kind)
		return
	end
	if ctx.Char:FindFirstChildOfClass("Tool") then
		return
	end
	local t = now()
	local s = ctx.State
	if s == "Dashing" then
		if kind == "Light" then
			local d = Config.Dash.Forward
			local into = t - ctx.DashStart
			if ctx.DashDir == "Forward" and into >= d.AttackFrom and into <= d.AttackTo and t >= ctx.DashAttackUntil then
				startDashAttack()
				return
			end
		end
		if ctx.StateUntil and ctx.StateUntil - t <= COMBO.Buffer then
			bufferPress(kind)
		end
		return
	end
	if s == "Stunned" or s == "GuardBroken" or s == "Recovering" then
		if ctx.StateUntil and ctx.StateUntil - t <= COMBO.Buffer then
			bufferPress(kind)
		end
		return
	end
	if s ~= "Idle" and s ~= "ComboWindow" and s ~= "Attacking" then
		dbg("try state", kind, s)
		return
	end
	local live = Rules.Live(ctx.Chain, t)
	-- jump + M1 is the Ground Smash - a standalone move: only from a real jump, only while no combo
	-- is live (a body that leaves the ground for a moment mid-string - the slide along with a
	-- knocked-back victim over a kerb - keeps its ground combo: a mashed M1 never vanishes there)
	if s == "Idle" and not live and airborne() and t - ctx.LastJumpAt < 1.6 then
		dbg("try air", kind, s)
		if kind == "Light" and t >= ctx.DownslamUntil then
			startDownslam()
		end
		return
	end
	if s == "Attacking" and not live then
		return -- a finisher / dash strike / stomp owns the character to its end
	end
	local verdict, name, slot, heavy, lights = Rules.Decide(ctx.Chain, kind, t)
	dbg("try", kind, s, verdict, name, slot, t - ctx.Chain.OpenAt)
	if verdict == "early" then
		-- pressed before the chain point: kept if close enough, fired exactly on it (once)
		if t >= ctx.Chain.OpenAt - COMBO.Buffer then
			bufferPress(kind)
			scheduleChain()
		end
		return
	end
	if verdict ~= "go" or not name then
		return
	end
	if (slot :: number) <= 1 then
		-- a strike that opens a new chain: nothing of the last one (its presses) carries over
		ctx.ChainNo += 1
	end
	-- the pair decides where the clip enters, so where its chain point falls (the server agrees)
	local prev = if (slot :: number) > 1 then ctx.Chain.Last else nil
	local _, enter = Config.Transition(prev, name :: string)
	Rules.Commit(ctx.Chain, name :: string, slot :: number, heavy :: boolean, lights :: number, t - enter / Config.Attacks[name :: string].Speed)
	playAttack(name :: string, slot :: number, nil, prev)
end

---------------------------------------------------------------------------
-- dash
---------------------------------------------------------------------------
-- the movement input right now (the humanoid's MoveDirection trails a key pressed this same frame)
local controls: any = nil
local function moveInput(F: Vector3, R: Vector3): (number, number)
	local md = ctx.Hum.MoveDirection
	if md.Magnitude >= 0.1 then
		return md:Dot(F), md:Dot(R)
	end
	if controls == nil then
		controls = false
		pcall(function()
			local pm = player:WaitForChild("PlayerScripts"):FindFirstChild("PlayerModule")
			controls = if pm then require(pm :: ModuleScript):GetControls() else false
		end)
	end
	if controls then
		local ok, mv = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(mv) == "Vector3" and mv.Magnitude > 0.1 then
			return -mv.Z, mv.X
		end
	end
	local f, r = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		f += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		f -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		r += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		r -= 1
	end
	return f, r
end

local function resolveDash(): (string, Vector3, Vector3)
	local cam = workspace.CurrentCamera
	local F = flat(if cam then cam.CFrame.LookVector else ctx.Root.CFrame.LookVector)
	local R = Vector3.new(-F.Z, 0, F.X)
	local f, r = moveInput(F, R)
	local forced = ctx.ForceDash
	if forced == "Forward" then
		f, r = 1, 0
	elseif forced == "Backward" then
		f, r = -1, 0
	elseif forced == "Right" then
		f, r = 0, 1
	elseif forced == "Left" then
		f, r = 0, -1
	end
	if math.abs(f) < 0.1 and math.abs(r) < 0.1 then
		return "Forward", F, F
	end
	if math.abs(f) >= math.abs(r) * 0.9 then
		if f >= 0 then
			return "Forward", F, F
		end
		return "Backward", -F, F
	end
	if r > 0 then
		return "Right", R, F
	end
	return "Left", -R, F
end

function tryDash()
	if inputBlocked() then
		return
	end
	local t = now()
	if not States.Allows(ctx.State, "Dash") then
		-- a dash pressed just before control comes back goes off the moment it does
		if ctx.StateUntil and ctx.StateUntil - t <= BUFFER_DASH and ctx.State ~= "Blocking" then
			bufferPress("Dash")
		end
		return
	end
	if t < ctx.DashCooldownUntil or airborne() then
		return
	end
	local dirName, dir, face = resolveDash()
	local def = Config.Dash[dirName]
	ctx.Seq += 1
	ctx.DashSeq = ctx.Seq
	ctx.DashSerial += 1
	local serial = ctx.DashSerial
	ctx.DashDir = dirName
	ctx.DashStart = t
	ctx.DashCooldownUntil = t + def.Lock + Config.Dash.Cooldown
	endChain()
	ctx.IdleTime = 0
	setLocal("Dashing", def.Lock)
	-- turn to face the dash's frame fast but smoothly (never a one-frame flip)
	alignTo(face, "Dash", t + def.Lock, 30, 24)
	ctx.AC:StopMany(ATTACK_ANIMS, 0.05)
	ctx.AC:StopMany({ "Jump", "Fall" }, 0.08)
	ctx.AC:Play(def.Anim, { Fade = 0.05, Speed = def.Speed, Restart = true })
	FX.Sound("Dash", ctx.Root.Position, 1)
	local delay = def.Delay or 0
	-- the kick-off burst (everyone else sees it from the server's "FX" Dash)
	local dashChar = ctx.Char
	task.delay(delay, function()
		if ctx and ctx.DashSerial == serial and ctx.Char == dashChar then
			FX.Dash(dashChar, dirName)
		end
	end)
	Motion.Drive(ctx.Root, def.Duration + delay, function(tt)
		if tt < delay then
			return Vector3.zero
		end
		return dir * def.TopSpeed * Config.DashProfile(tt - delay, def.Duration)
	end, { StopAtWalls = true, Ignore = charList(), Fighters = fighterRoots(), Gap = Config.Dash.StopGap, Width = Config.Dash.StopWidth })
	Request:FireServer("Dash", { Seq = ctx.Seq, Dir = dirName })
	if def.TailAt and def.TailSpeed then
		task.delay(def.TailAt, function()
			if ctx and ctx.DashSerial == serial then
				local tr = ctx.AC:Track(def.Anim)
				if tr and tr.IsPlaying then
					tr:AdjustSpeed(def.TailSpeed)
				end
			end
		end)
	end
	task.delay(def.FadeAt, function()
		if ctx and ctx.DashSerial == serial then
			ctx.AC:Stop(def.Anim, 0.22)
		end
	end)
end

---------------------------------------------------------------------------
-- block
---------------------------------------------------------------------------
local function tryBlock()
	if inputBlocked() or (ctx.State ~= "Idle" and ctx.State ~= "ComboWindow") or now() < ctx.BlockRetryAt or now() < ctx.ReblockAt then
		return
	end
	ctx.Seq += 1
	ctx.BlockSeq = ctx.Seq
	ctx.IdleTime = 0
	ctx.ReleaseQueued = false
	endChain()
	ctx.Align = nil
	ctx.AC:StopMany(ATTACK_ANIMS, 0.1)
	setLocal("Blocking")
	ctx.AC:Play("Block", { Fade = 0.1 })
	Request:FireServer("Block", { Seq = ctx.Seq, On = true })
end

local function releaseBlock()
	if not ctx or ctx.State ~= "Blocking" then
		return
	end
	if now() < ctx.BlockLockUntil then
		-- still absorbing a blow: the guard comes down when the block stun ends
		ctx.ReleaseQueued = true
		return
	end
	ctx.ReleaseQueued = false
	setLocal("Idle")
	ctx.AC:Stop("Block", 0.14)
	ctx.Seq += 1
	Request:FireServer("Block", { Seq = ctx.Seq, On = false })
end

---------------------------------------------------------------------------
-- being hit
---------------------------------------------------------------------------
-- a non-looping reaction clip freezes on its last pose while the stun lasts
local function holdReaction(track: AnimationTrack?, speed: number, stunSerial: number)
	if not track or speed <= 0 then
		return
	end
	local len = if track.Length > 0 then track.Length else 0.5
	local left = math.max(0.05, (len - track.TimePosition) / speed - 0.05)
	task.delay(left, function()
		if ctx and ctx.StateSerial == stunSerial and track.IsPlaying then
			track:AdjustSpeed(0)
		end
	end)
end

--[[ the reaction clip, cross-fading from the pose the body is in right now (PlayFresh: never from
	neutral): a blow on the same side as the last one blends quickly, one from the other side (the
	head whipping across) a touch longer. It holds its impact pose through the hit-stop, plays at
	`speed`, and once past its peak sags part way back toward the stance while the stun lasts
	(Config.React) - so the next blow always has somewhere to drive the body. ]]
local function react(key: string, speed: number, hitstop: number, fade: number?): AnimationTrack?
	local R = Config.React
	local other = if key == "HitLeft" then "HitRight" else "HitLeft"
	local swap = ctx.AC:IsPlaying(other)
	local f = fade or (if swap then R.SwapBlend else R.Blend)
	local tr = ctx.AC:PlayFresh(key, { Fade = f, Speed = 0 })
	ctx.AC:Stop(other, f)
	local serial = ctx.StateSerial
	local c = ctx
	task.delay(hitstop, function()
		if ctx == c and tr and tr.IsPlaying and c.StateSerial == serial then
			tr:AdjustSpeed(speed)
			holdReaction(tr, speed, serial)
			if speed > 0 then
				task.delay(math.max(0, (R.SettleAt - tr.TimePosition) / speed), function()
					if ctx == c and tr.IsPlaying and c.StateSerial == serial then
						tr:AdjustWeight(R.Settle, R.SettleTime)
					end
				end)
			end
		end
	end)
	return tr
end

-- a blow on MY body (the server's word): the state, the reaction, the push
local function onHitMe(data: any, def: any)
	local root = ctx.Root
	local hs = data.HS or 0
	if data.RD then
		-- launched: the impact pose through the hit-stop, then the body goes (Ragdolled attribute)
		cancelActions()
		endChain()
		setLocal("Ragdolled")
		react(data.R, 0, hs + 1)
		return
	end
	if data.G then
		-- guard broken: the directional reaction slowed down, a controlled slide back, no guard for a bit
		cancelActions()
		endChain()
		setLocal("GuardBroken", data.S)
		ctx.ReblockAt = now() + data.S + Config.Guard.ReblockAfter
		ctx.ReleaseQueued = false
		react(data.R, data.RS, hs, 0.05)
		if data.KT > 0 then
			local kb, kt = data.KB, data.KT
			local serial = ctx.StateSerial
			task.delay(hs, function()
				if ctx and ctx.State == "GuardBroken" and ctx.StateSerial == serial then
					Motion.Push(root, kb, kt, charList())
				end
			end)
		end
		return
	end
	if data.B then
		-- absorbed: the guard can't drop for a beat, the stance slides back (the give plays for everyone)
		ctx.BlockLockUntil = math.max(ctx.BlockLockUntil, now() + (def.ClassDef.BlockStun or 0) + hs)
		if data.KT > 0 then
			local kb, kt = data.KB, data.KT
			task.delay(hs, function()
				if ctx and ctx.State == "Blocking" then
					Motion.Push(root, kb, kt, charList())
				end
			end)
		end
		return
	end
	if data.S > 0 then
		local wasStunned = ctx.State == "Stunned"
		if not wasStunned then
			cancelActions()
		else
			Motion.Stop(root)
		end
		endChain()
		setLocal("Stunned", data.S)
		if data.PR or not wasStunned then
			react(data.R, data.RS, hs)
		end
	end
	-- (data.IM: in the escape window the blow still pushes, but the body keeps control)
	if data.KT > 0 then
		local kb, kt = data.KB, data.KT
		task.delay(hs, function()
			if ctx and ctx.Root == root and ctx.State ~= "Ragdolled" and ctx.State ~= "Dead" then
				Motion.Push(root, kb, kt, charList())
			end
		end)
	elseif data.KB.Y > 0 then
		Motion.Push(root, data.KB, 0)
	end
end

-- another fighter's strike: the air it cuts and the trail of the sweep / uppercut (their own client
-- already played it for them)
local function otherSwing(model: Model, key: string)
	local def = Config.Attacks[key]
	if not def then
		return
	end
	task.delay(math.max(0, def.HitReal - 0.07), function()
		local r = model.Parent and model:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") then
			FX.Sound(SWING_SOUND[key] or "Swing", r.Position, 1)
		end
	end)
	if key == "Sweep" or key == "Uppercut" then
		local lead = if key == "Sweep" then 0.2 else 0.12
		task.delay(math.max(0, (def.Hit - lead) / def.Speed), function()
			if model.Parent then
				FX.LimbTrail(model, if key == "Sweep" then "Right Leg" else "Left Arm", lead / def.Speed + 0.08, if key == "Sweep" then "Low" else nil)
			end
		end)
	end
end

local debugHit: (data: any) -> () = function() end
local debugAck: (data: any) -> () = function() end
-- other fighters' Ground Smash drops in progress (their wind stops when their smash lands)
local ctxDescents: { [Model]: any } = setmetatable({}, { __mode = "k" }) :: any

Event.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "Hit" then
		if type(data) ~= "table" then
			return
		end
		local def = Config.Attacks[data.K]
		if not def then
			return
		end
		local victim = data.V
		local heavy = def.Rank >= 3
		local mine = ctx ~= nil and data.A == ctx.Char
		local me = if mine then "Attacker" elseif ctx ~= nil and victim == ctx.Char then "Victim" else nil
		-- my own strike already showed this impact on its own frame: only the server's numbers are new
		local shown = mine and ctx.Predicted[data.Seq] ~= nil and ctx.Predicted[data.Seq].Victim == victim
		if not shown then
			local drive = if typeof(data.DV) == "Vector3" then data.DV else Vector3.new(data.KB.X, 0, data.KB.Z)
			FX.Connect({
				Kind = data.K, At = data.P, Dir = drive, Victim = victim, Attacker = data.A,
				Blocked = data.B, Break = data.G, Launched = data.RD, Immune = data.IM, DirSign = data.Dir, Me = me,
			})
		elseif data.G and not ctx.Predicted[data.Seq].Break then
			-- (the one thing this screen can get wrong: the guard went up just before the blow)
			FX.Sound("GuardBreak", data.P, 1)
		end
		if not ctx then
			return
		end
		if mine then
			debugHit(data)
			local a = ctx.Attack
			if not shown and a and a.Seq == data.Seq then
				-- this screen missed it (lag, a body the server had elsewhere): the freeze and the carry now
				hitStop(a, data.HS or 0)
				if not data.B and not data.G and not data.RD and (data.KT or 0) > 0.02 and a.Slot > 0 and def.Class ~= "Dash" then
					startCarry(a, data.HS or 0)
				end
			end
			-- your damage, stamped beside the victim's head (one per victim, re-stamped each hit)
			if victim and (data.D or 0) > 0 then
				local dk = if data.G then "Break"
					elseif data.B then "Block"
					elseif data.RD or def.Class == "Finisher" then "Finisher"
					elseif heavy then "Heavy"
					else "Light"
				FX.Damage(victim, data.D, dk, ctx.Char)
			end
			if not data.B and (data.CH or 0) >= 1 then
				local ui = if def.Class == "Finisher" then "Finisher" elseif data.G then "Break" elseif heavy then "Heavy" else "Light"
				if ui == "Finisher" then
					ctx.CounterHoldUntil = now() + 1.4
				end
				local chain = ctx.Chain
				local window = if chain.Slot > 0 and chain.CloseAt > now() then chain.CloseAt - now() else nil
				Counter.Hit(data.CH, ui, { Damage = data.D or 0, Window = window })
			end
		end
		if victim == ctx.Char then
			onHitMe(data, def)
		end
	elseif kind == "FX" then
		if type(data) ~= "table" then
			return
		end
		local mine = ctx ~= nil and data.A == ctx.Char
		local model = if typeof(data.A) == "Instance" and data.A:IsA("Model") then data.A else nil
		if data.Kind == "Dash" and model and not mine then
			FX.Dash(model, data.Dir)
			local r = model:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				FX.Sound("Dash", r.Position, 1)
			end
		elseif data.Kind == "Swing" and model and not mine and type(data.K) == "string" then
			otherSwing(model, data.K)
		elseif data.Kind == "Descent" and model and not mine then
			local d = FX.Descent(model, type(data.H) == "number" and data.H or nil)
			task.delay(1.6, d.Stop)
			ctxDescents[model] = d
		elseif data.Kind == "Slam" and not mine and typeof(data.P) == "Vector3" then
			-- (the shatter plays its own layered sound, phase by phase)
			if model and ctxDescents[model] then
				ctxDescents[model].Stop()
				ctxDescents[model] = nil
			end
			FX.Stomp(data.P, model)
			if ctx then
				local d = (data.P - ctx.Root.Position).Magnitude
				if d < 30 then
					FX.Camera(ctx.Hum, "StompNear", ctx.Root.Position - data.P, math.clamp(1.2 - d / 30, 0.2, 1))
				end
			end
		end
	elseif kind == "Ack" then
		if not ctx or type(data) ~= "table" then
			return
		end
		if data.Kind == "Attack" then
			local a = ctx.Attack
			if not (a and a.Seq == data.Seq) then
				return
			end
			debugAck(data)
			if data.Ok then
				-- the server's count stands (it only differs right at a window edge)
				if type(data.Chain) == "table" then
					ctx.Chain.Slot = data.Chain.Slot
					ctx.Chain.Heavy = data.Chain.Heavy
					ctx.Chain.Lights = data.Chain.Lights
				end
				if data.Action and data.Action ~= a.Name then
					-- the server started a different strike: show that one instead, entering its clip
					-- where the server did (its pair's transition)
					local name, slot = data.Action, data.Slot or 0
					local startedAt = a.T0 + (a.Enter or 0) / a.Def.Speed
					local elapsed = now() - startedAt
					local def = Config.Attacks[name]
					local enter = if type(data.Chain) == "table" and type(data.Chain.Enter) == "number" then data.Chain.Enter else 0
					cancelActions(true)
					if def and slot > 0 then
						Rules.Commit(ctx.Chain, name, slot, ctx.Chain.Heavy, ctx.Chain.Lights, startedAt - enter / def.Speed)
						if type(data.Chain) == "table" then
							ctx.Chain.Slot = data.Chain.Slot
							ctx.Chain.Heavy = data.Chain.Heavy
							ctx.Chain.Lights = data.Chain.Lights
						end
					end
					playAttack(name, slot, data.Seq, nil, enter)
					if ctx.AttackTrack and def then
						ctx.AttackTrack.TimePosition = math.min(enter + elapsed * def.Speed, def.Hit * 0.6)
					end
				end
			else
				-- refused: roll back to where the server has us
				dbg("refused", a.Name, a.Slot)
				if a.Name == "Downslam" and ctx.DownslamBefore then
					ctx.DownslamUntil = ctx.DownslamBefore -- the server spent no cooldown
				end
				cancelActions(true)
				endChain()
				if ctx.State == "Attacking" then
					setLocal("Idle")
				end
			end
		elseif data.Ok then
			return
		elseif data.Kind == "Dash" and ctx.DashSeq == data.Seq and ctx.State == "Dashing" then
			cancelActions(true)
			setLocal("Idle")
		elseif data.Kind == "Block" and data.Action == "On" and ctx.BlockSeq == data.Seq and ctx.State == "Blocking" then
			ctx.AC:Stop("Block", 0.1)
			setLocal("Idle")
			ctx.BlockRetryAt = now() + 0.1
		end
	elseif kind == "Cancel" then
		-- the server dropped a strike it had started (a Ground Smash with no real jump or no landing)
		if ctx and type(data) == "table" and ctx.Attack and ctx.Attack.Seq == data.Seq then
			dbg("cancelled", ctx.Attack.Name)
			cancelActions(true)
			if ctx.State == "Attacking" then
				setLocal("Idle")
			end
		end
	elseif kind == "Play" then
		if ctx and type(data) == "table" and type(data.Key) == "string" then
			ctx.AC:Play(data.Key, data.Opts)
		end
	end
end)

---------------------------------------------------------------------------
-- locomotion + movement (every frame)
---------------------------------------------------------------------------
local LOCO = { "Walk", "Run" }

local function updateLocomotion(dt: number)
	local hum, root, ac = ctx.Hum, ctx.Root, ctx.AC
	local t = now()
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local hs = hum:GetState()
	local air = hs == Enum.HumanoidStateType.Freefall or hs == Enum.HumanoidStateType.Jumping
	local climbing = hs == Enum.HumanoidStateType.Climbing
	local s = ctx.State
	local wantsMove = hum.MoveDirection.Magnitude > 0.05
	local moving = speed > 0.8 and wantsMove and not air and not climbing

	-- timed local states run out on their own (the server confirms with the attribute)
	if ctx.StateUntil and t >= ctx.StateUntil then
		if s == "Attacking" then
			ctx.Attack = if ctx.Attack and ctx.AttackTrack and ctx.AttackTrack.IsPlaying then ctx.Attack else nil
			if Rules.Live(ctx.Chain, t) then
				setLocal("ComboWindow", math.max(0.02, ctx.Chain.CloseAt - t))
			else
				setLocal("Idle")
			end
		elseif s == "ComboWindow" or s == "Dashing" or s == "Stunned" or s == "GuardBroken" or s == "Recovering" then
			setLocal("Idle")
		else
			ctx.StateUntil = nil
		end
		s = ctx.State
	end

	-- a combo whose window closed is over (the counter and the lock go with it)
	if ctx.Chain.Slot > 0 and not Rules.Live(ctx.Chain, t) and s ~= "Attacking" then
		endChain()
	end
	if Counter.Shown() and ctx.Chain.Slot == 0 and s ~= "Attacking" and t >= ctx.CounterHoldUntil then
		Counter.Drop()
	end
	if ctx.Buffer and t - ctx.Buffer.At > 0.5 then
		ctx.Buffer = nil -- a stale press never fires late
	end

	alignStep(dt)
	-- predictions the server never confirmed are forgotten
	if next(ctx.Predicted) ~= nil then
		for seq, p in pairs(ctx.Predicted) do
			if t - p.T > 2 then
				ctx.Predicted[seq] = nil
			end
		end
	end

	-- a strike's tail never plays under walking legs
	if (s == "Idle" or s == "ComboWindow") and wantsMove and ctx.AttackTrack and ctx.AttackTrack.IsPlaying then
		ctx.AttackTrack:Stop(0.15)
		ctx.AttackTrack = nil
	end

	-- guard: up again as soon as the character is free while the key is held; down when the block stun lets go
	if ctx.BlockHeld and (s == "Idle" or s == "ComboWindow") then
		tryBlock()
		s = ctx.State
	end
	if s == "Blocking" and ctx.ReleaseQueued and not ctx.BlockHeld and t >= ctx.BlockLockUntil then
		releaseBlock()
		s = ctx.State
	end

	-- idle: neutral stance first, the combat idle after standing still a while
	if s == "Idle" and not moving and not air and not climbing and speed < 0.8 then
		ctx.IdleTime += dt
	else
		ctx.IdleTime = 0
	end
	if not ac:IsPlaying("NeutralIdle") then
		ac:Play("NeutralIdle", { Fade = 0.3 })
	end
	if ctx.IdleTime >= Config.IdleDelay then
		if not ac:IsPlaying("CombatIdle") then
			ac:Play("CombatIdle", { Fade = 0.6 })
			local ni = ac:Track("NeutralIdle")
			if ni then
				ni:AdjustWeight(0.001, 0.6)
			end
		end
	elseif ac:IsPlaying("CombatIdle") then
		ac:Stop("CombatIdle", 0.25)
		local ni = ac:Track("NeutralIdle")
		if ni then
			ni:AdjustWeight(1, 0.25)
		end
	end

	-- walk <-> run blend by real ground speed; playback matches the stride
	if moving then
		local band = Config.RunBlend
		local r = math.clamp((speed - band[1]) / (band[2] - band[1]), 0, 1)
		local walk = ac:Track("Walk")
		local run = ac:Track("Run")
		if walk then
			if not walk.IsPlaying then
				walk:Play(0.15, math.max(1 - r, 0.001), 1)
			else
				walk:AdjustWeight(math.max(1 - r, 0.001), 0.1)
			end
			walk:AdjustSpeed(math.clamp(speed / Config.WalkNatural, 0.4, 2.6))
		end
		if run then
			if not run.IsPlaying then
				run:Play(0.2, math.max(r, 0.001), 1)
			else
				run:AdjustWeight(math.max(r, 0.001), 0.1)
			end
			run:AdjustSpeed(math.clamp(speed / Config.RunNatural, 0.6, 2.2))
		end
	else
		ac:StopMany(LOCO, 0.2)
	end

	-- air and ladders
	if climbing then
		local tr = ac:Play("Climb", { Fade = 0.1 })
		if tr then
			tr:AdjustSpeed(math.clamp(v.Y / 8, -1.5, 1.5))
		end
	elseif ac:IsPlaying("Climb") then
		ac:Stop("Climb", 0.15)
	end
	local stomping = s == "Attacking" and ctx.Attack ~= nil and ctx.Attack.Name == "Downslam"
	if hs == Enum.HumanoidStateType.Freefall and t - ctx.FreefallAt > 0.2 and not stomping and s ~= "Attacking" then
		if not ac:IsPlaying("Fall") then
			ac:Play("Fall", { Fade = 0.2 })
		end
	elseif not air and (ac:IsPlaying("Fall") or ac:IsPlaying("Jump")) then
		ac:StopMany({ "Fall", "Jump" }, 0.12)
	end
	if stomping then
		ac:StopMany({ "Fall", "Jump" }, 0.05)
	end

	-- movement: speed, jump and free turning follow the state
	if externallyLocked() then
		return
	end
	local canMove = s == "Idle" or s == "ComboWindow" or s == "Blocking" or (s == "Recovering" and t >= ctx.ControlAt)
	local run = s == "Idle" and wantsMove and (ctx.SprintHeld or ctx.SprintToggle or ctx.MovingFor >= Config.AutoRunAfter)
	if canMove and wantsMove and not air then
		ctx.MovingFor += dt
	elseif not wantsMove then
		ctx.MovingFor = 0
		ctx.SprintToggle = false
	end
	local target = if not canMove then 0
		elseif s == "Blocking" then Config.BlockWalkSpeed
		elseif s == "ComboWindow" then Config.ComboWalkSpeed
		elseif run then Config.RunSpeed
		else Config.WalkSpeed
	if not canMove then
		ctx.Speed = 0
	elseif target > ctx.Speed and run then
		ctx.Speed = math.min(target, math.max(ctx.Speed, Config.WalkSpeed) + (Config.RunSpeed - Config.WalkSpeed) / Config.RunRamp * dt)
	else
		ctx.Speed = target
	end
	if hum.WalkSpeed ~= ctx.Speed then
		hum.WalkSpeed = ctx.Speed
	end
	-- no jumping out of a live combo: the chain's window is for its next strike (a jump there was the
	-- way to reset a string into a Ground Smash)
	local jump = if s == "Idle" then Config.JumpHeight else 0
	if hum.JumpHeight ~= jump then
		hum.JumpHeight = jump
	end
	updateTurn()
end

---------------------------------------------------------------------------
-- character lifecycle
---------------------------------------------------------------------------
local debugCharacter: (c: any) -> () = function() end

local function teardown()
	if not ctx then
		return
	end
	ctx.Alive = false
	for _, c in ipairs(ctx.Conns) do
		c:Disconnect()
	end
	pcall(function()
		Motion.Stop(ctx.Root)
	end)
	ctx.AC:Destroy()
	ctx = nil
	Counter.Drop()
end

local function setup(char: Model)
	teardown()
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid
	local root = char:WaitForChild("HumanoidRootPart", 10) :: BasePart
	if not (hum and root) or char.Parent == nil then
		return
	end
	local c: any = {
		Char = char,
		Hum = hum,
		Root = root,
		AC = AnimController.get(hum),
		Alive = true,
		Conns = {},
		State = "Idle",
		StateSerial = 0,
		StateUntil = nil,
		Chain = Rules.New(),
		ChainTick = 0,
		ChainNo = 0,
		Align = nil,
		YawVel = 0,
		Attack = nil,
		AttackTrack = nil,
		AttackSerial = 0,
		AirHeight = 0,
		Move = nil, -- the step-in + carry (CombatChoreo)
		AimDir = nil,
		Predicted = {}, -- [strike Seq] = the impact this screen already showed
		Seq = 0,
		DashSeq = 0,
		BlockSeq = 0,
		Buffer = nil,
		M1Held = false,
		M1Source = nil,
		M1Input = nil,
		BlockHeld = false,
		BlockRetryAt = 0,
		BlockLockUntil = 0,
		ReleaseQueued = false,
		ReblockAt = 0,
		SprintHeld = false,
		SprintToggle = false,
		MovingFor = 0,
		Speed = Config.WalkSpeed,
		DashDir = nil,
		DashStart = 0,
		DashSerial = 0,
		DashCooldownUntil = 0,
		DashAttackUntil = 0,
		DownslamUntil = 0,
		DownslamBefore = nil,
		IdleTime = 0,
		LastJumpAt = -10,
		FreefallAt = 0,
		ControlAt = 0,
		CounterHoldUntil = 0,
		TurnFree = true,
		SavedAutoRotate = true,
	}
	ctx = c
	hum.WalkSpeed = Config.WalkSpeed
	hum.UseJumpPower = false
	hum.JumpHeight = Config.JumpHeight
	c.AC:Play("NeutralIdle", { Fade = 0 })

	table.insert(c.Conns, hum.StateChanged:Connect(function(old, new)
		if new == Enum.HumanoidStateType.Jumping then
			c.LastJumpAt = now()
			c.IdleTime = 0
			if c.State == "Idle" then
				c.AC:Play("Jump", { Fade = 0.08, Restart = true })
			end
		elseif new == Enum.HumanoidStateType.Freefall then
			c.FreefallAt = now()
		elseif new == Enum.HumanoidStateType.Landed and old == Enum.HumanoidStateType.Freefall and c.State ~= "Attacking" and now() - c.FreefallAt > 0.35 then
			-- feet back down after a real fall (a smash has its own landing)
			FX.Sound("Land", root.Position - Vector3.new(0, 2.8, 0), 1)
		end
	end))

	-- the server's word on the state (stuns, abilities, death start or end here)
	table.insert(c.Conns, char:GetAttributeChangedSignal("CombatState"):Connect(function()
		local s = char:GetAttribute("CombatState")
		if ctx ~= c or type(s) ~= "string" then
			return
		end
		if s == "UsingAbility" or s == "Dead" then
			cancelActions()
			endChain()
			setLocal(s)
		elseif s == "Idle" and (c.State == "Stunned" or c.State == "GuardBroken" or c.State == "UsingAbility" or c.State == "Recovering") then
			setLocal("Idle")
		elseif (s == "Stunned" or s == "GuardBroken") and c.State ~= s and c.State ~= "Ragdolled" then
			cancelActions()
			endChain()
			setLocal(s, 2)
		end
	end))

	-- knockdown / getting up (the server switches the joints; this client owns the body)
	table.insert(c.Conns, char:GetAttributeChangedSignal("Ragdolled"):Connect(function()
		if ctx ~= c then
			return
		end
		if char:GetAttribute("Ragdolled") == true then
			cancelActions()
			endChain()
			c.AC:StopMany(REACTIONS, 0.05)
			setLocal("Ragdolled")
			if hum.Health > 0 then
				Ragdoll.ApplyFall(char)
			end
		elseif hum.Health > 0 then
			Ragdoll.StandUp(char, charList())
			local rc = Config.Recovery
			c.ControlAt = now() + rc.ControlAt / rc.Speed
			setLocal("Recovering", rc.ActionsAt / rc.Speed)
			c.AC:Play("GroundRecovery", { Fade = 0.05, Speed = rc.Speed, Restart = true })
			task.delay(0.3, function()
				if ctx == c and hum.Parent and hum:GetState() == Enum.HumanoidStateType.GettingUp then
					hum:ChangeState(Enum.HumanoidStateType.Running)
				end
			end)
		end
	end))

	table.insert(c.Conns, hum.Died:Connect(function()
		if ctx == c then
			cancelActions()
			endChain()
			setLocal("Dead")
		end
	end))

	table.insert(c.Conns, RunService.Heartbeat:Connect(function(dt)
		if ctx == c and c.Alive and hum.Parent then
			updateLocomotion(dt)
		end
	end))
	debugCharacter(c)
end

player.CharacterAdded:Connect(setup)
player.CharacterRemoving:Connect(function(char)
	if ctx and ctx.Char == char then
		teardown()
	end
end)
if player.Character then
	task.spawn(setup, player.Character)
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- shift lock: Overkill's own (a rebindable key, default Left Ctrl; Roblox's Shift toggle is off so
-- Shift can sprint). The mouse locks to the centre, the camera sits over the right shoulder and the
-- fighter faces where the camera looks whenever its state lets it turn (never mid-strike, never
-- while guarding - the guard keeps its facing - and never between the strikes of a locked chain:
-- the lock keeps the body on its fighter while the camera stays free).
---------------------------------------------------------------------------
local shiftLock = false
local lockApplied = false
local LOCK_OFFSET = Vector3.new(1.75, 0, 0)
local LOCK_ICON = "rbxasset://textures/MouseLockedCursor.png"

local function toggleShiftLock()
	shiftLock = not shiftLock
end

local function lockActive(): boolean
	return shiftLock
		and ctx ~= nil
		and ctx.Alive
		and UserInputService.MouseEnabled
		and not externallyLocked()
		and player:GetAttribute("UIWindow") == nil
		and ctx.State ~= "Ragdolled"
		and ctx.State ~= "Dead"
end

RunService:BindToRenderStep("OverkillShiftLock", Enum.RenderPriority.Camera.Value + 1, function()
	if lockActive() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		if not lockApplied then
			lockApplied = true
			UserInputService.MouseIcon = LOCK_ICON
			FX.SetCameraBase(ctx.Hum, LOCK_OFFSET)
		end
		if States.Allows(ctx.State, "Turn") and not ctx.Align then
			ctx.Hum.AutoRotate = false
			local cam = workspace.CurrentCamera
			local root = ctx.Root
			if cam and root.Parent then
				root.CFrame = CFrame.lookAt(root.Position, root.Position + flat(cam.CFrame.LookVector))
			end
		end
	elseif lockApplied then
		lockApplied = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIcon = ""
		if ctx then
			FX.SetCameraBase(ctx.Hum, Vector3.zero)
			-- turning goes back to the state (and to the humanoid's own auto-rotate)
			ctx.SavedAutoRotate = true
			ctx.TurnFree = States.Allows(ctx.State, "Turn")
			ctx.Hum.AutoRotate = ctx.TurnFree
		end
	end
end)

local function m1Down(source: string?, input: InputObject?)
	if not ctx then
		return
	end
	ctx.M1Held = true
	ctx.M1Source = source or "Touch"
	ctx.M1Input = input
	tryAttack("Light")
end
local function m1Up()
	if ctx then
		ctx.M1Held = false
		ctx.M1Input = nil
	end
end
local function heavyPress()
	if ctx then
		tryAttack("Heavy")
	end
end
local function blockDown()
	if not ctx then
		return
	end
	ctx.BlockHeld = true
	tryBlock()
end
local function blockUp()
	if not ctx then
		return
	end
	ctx.BlockHeld = false
	releaseBlock()
end

-- M2 is a click, not a camera drag: it fires on release unless the mouse travelled (shift lock:
-- the camera never drags, so it fires on press). One press is one heavy, whichever way it fires.
local m2 = { Down = false, At = 0, Travel = 0, Fired = false }

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not ctx then
		return
	end
	local kc = input.KeyCode
	local ut = input.UserInputType
	if ut == Enum.UserInputType.Keyboard then
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if kc == keyFor("Block") then
			blockDown()
		elseif kc == keyFor("Dash") then
			tryDash()
		elseif kc == keyFor("Sprint") then
			ctx.SprintHeld = true
		elseif kc == keyFor("ShiftLock") then
			toggleShiftLock()
		end
	elseif ut == Enum.UserInputType.MouseButton1 then
		if not processed then
			m1Down("Mouse")
		end
	elseif ut == Enum.UserInputType.MouseButton2 then
		m2.Down = not processed
		m2.At = now()
		m2.Travel = 0
		m2.Fired = false
		if m2.Down and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			m2.Fired = true
			heavyPress()
		end
	elseif ut == Enum.UserInputType.Gamepad1 then
		if kc == Enum.KeyCode.ButtonR2 or kc == Enum.KeyCode.ButtonX then
			if not processed or kc == Enum.KeyCode.ButtonR2 then
				m1Down("Gamepad")
			end
		elseif kc == Enum.KeyCode.ButtonY then
			if not processed then
				heavyPress()
			end
		elseif kc == Enum.KeyCode.ButtonL2 then
			blockDown()
		elseif kc == Enum.KeyCode.ButtonB and not processed then
			tryDash()
		elseif kc == Enum.KeyCode.ButtonL3 then
			ctx.SprintToggle = not ctx.SprintToggle
		end
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject)
	if m2.Down and input.UserInputType == Enum.UserInputType.MouseMovement then
		m2.Travel += input.Delta.Magnitude
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if not ctx then
		return
	end
	local kc = input.KeyCode
	local ut = input.UserInputType
	if ut == Enum.UserInputType.Keyboard then
		if kc == keyFor("Block") then
			blockUp()
		elseif kc == keyFor("Sprint") then
			ctx.SprintHeld = false
		end
	elseif ut == Enum.UserInputType.MouseButton1 then
		m1Up()
	elseif ut == Enum.UserInputType.MouseButton2 then
		if m2.Down and not m2.Fired and now() - m2.At <= 0.35 and m2.Travel <= 8 then
			m2.Fired = true
			heavyPress()
		end
		m2.Down = false
	elseif ut == Enum.UserInputType.Gamepad1 then
		if kc == Enum.KeyCode.ButtonR2 or kc == Enum.KeyCode.ButtonX then
			m1Up()
		elseif kc == Enum.KeyCode.ButtonL2 then
			blockUp()
		end
	elseif ut == Enum.UserInputType.Touch then
		-- the finger holding ATTACK lifted somewhere off the button
		if ctx.M1Input == input then
			m1Up()
		end
	end
end)

-- a window/overlay opening mid-guard drops the guard (the release would never arrive)
player:GetAttributeChangedSignal("UIWindow"):Connect(function()
	if ctx and player:GetAttribute("UIWindow") ~= nil then
		ctx.M1Held = false
		ctx.Buffer = nil
		blockUp()
	end
end)
player:GetAttributeChangedSignal("UIOverlay"):Connect(function()
	if ctx and player:GetAttribute("UIOverlay") ~= nil then
		ctx.M1Held = false
		ctx.Buffer = nil
		blockUp()
	end
end)

-- Studio play-tests: a BindableEvent that presses the same buttons with exact timing
-- (game.Players.LocalPlayer.CombatDebug:Fire("Light" | "HoldLight" | "ReleaseLight" | "Heavy" |
--  "BlockOn" | "BlockOff" | "Dash", dir?))
if STUDIO then
	local hook = Instance.new("BindableEvent")
	hook.Name = "CombatDebug"
	hook.Event:Connect(function(cmd: string, arg: any)
		if not ctx then
			return
		end
		if cmd == "Light" then
			m1Down("Test")
			m1Up()
		elseif cmd == "HoldLight" then
			m1Down("Test")
		elseif cmd == "ReleaseLight" then
			m1Up()
		elseif cmd == "Heavy" then
			heavyPress()
		elseif cmd == "BlockOn" then
			blockDown()
		elseif cmd == "BlockOff" then
			blockUp()
		elseif cmd == "Dash" then
			if type(arg) == "string" then
				ctx.ForceDash = arg
			end
			tryDash()
			ctx.ForceDash = nil
		end
	end)
	hook.Parent = player
end

-- touch buttons (phones/tablets)
local touch = script:FindFirstChild("TouchControls")
if touch then
	task.spawn(function()
		require(touch).Start({
			M1Down = function(input: InputObject?)
				m1Down("Touch", input)
			end,
			M1Up = m1Up,
			Heavy = heavyPress,
			BlockDown = blockDown,
			BlockUp = blockUp,
			Dash = function()
				if ctx then
					tryDash()
				end
			end,
		})
	end)
end

---------------------------------------------------------------------------
-- STUDIO ONLY: the combat debug overlay (F7, or player attribute CombatDebug = true)
-- Everything the fight is deciding, live: the local and the server state, the chain, the stun
-- budget and the escape window, cooldowns, the body in the strike's lane and its distance vs the
-- strike's Ideal, the step / carry, the network timing, the last impact (predicted on this screen,
-- confirmed or not by the server). In the world: the strike's lane along the aim, a marker at the
-- Ideal distance on it, and each contact point. Server-side capsules:
-- workspace:SetAttribute("CombatDebugDraw", true) from the server's command bar. None of this
-- exists in a live game.
---------------------------------------------------------------------------
if STUDIO then
	local shown = false
	local gui: ScreenGui? = nil
	local label: TextLabel? = nil
	local lane: Part? = nil
	local mark: Part? = nil
	local lastAck = { Delta = 0, Rtt = 0, Ok = true, Action = "" }
	local lastHit = ""

	debugAck = function(data: any)
		local a = ctx and ctx.Attack
		if a and a.SentAt and type(data.At) == "number" then
			lastAck.Delta = data.At - a.SentAt
			lastAck.Rtt = now() - (a.T0 + (a.Enter or 0) / a.Def.Speed)
		end
		lastAck.Ok = data.Ok == true
		lastAck.Action = tostring(data.Action or "-")
	end
	debugHit = function(data: any)
		if not shown then
			return
		end
		local p = ctx and ctx.Predicted[data.Seq]
		lastHit = string.format("%s #%d -> %s  %s dmg %.1f  stun %.2f  hs %.3f  %s%s", tostring(data.K), data.Slot or 0,
			if typeof(data.V) == "Instance" then data.V.Name else "?", if data.B then "BLOCK" elseif data.G then "BREAK" elseif data.RD then "LAUNCH" elseif data.IM then "IMMUNE" else "CLEAN",
			data.D or 0, data.S or 0, data.HS or 0, if p then string.format("shown %.0f ms before the server", (now() - p.T) * 1000) else "NOT predicted",
			if data.PR then "" else "  (no restart)")
		-- the contact point, for half a second
		if typeof(data.P) == "Vector3" then
			local part = Instance.new("Part")
			part.Name = "CombatDebugContact"
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.one * 0.45
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Material = Enum.Material.Neon
			part.Color = if data.B then Color3.fromRGB(90, 170, 255) elseif data.IM then Color3.fromRGB(255, 220, 90) else Color3.fromRGB(255, 70, 70)
			part.CFrame = CFrame.new(data.P)
			part.Parent = workspace
			game:GetService("Debris"):AddItem(part, 0.5)
		end
	end
	debugCharacter = function(_c: any) end

	local function marker(name: string, color: Color3): Part
		local r = Instance.new("Part")
		r.Name = name
		r.Anchored = true
		r.CanCollide = false
		r.CanQuery = false
		r.CanTouch = false
		r.CastShadow = false
		r.Material = Enum.Material.ForceField
		r.Color = color
		r.Transparency = 0.2
		return r
	end

	local function build()
		local g = Instance.new("ScreenGui")
		g.Name = "CombatDebugOverlay"
		g.ResetOnSpawn = false
		g.DisplayOrder = 100
		g.Parent = player:WaitForChild("PlayerGui")
		local l = Instance.new("TextLabel")
		l.BackgroundColor3 = Color3.new(0, 0, 0)
		l.BackgroundTransparency = 0.35
		l.TextColor3 = Color3.new(1, 1, 1)
		l.Font = Enum.Font.Code
		l.TextSize = 14
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.Position = UDim2.new(1, -520, 0, 60)
		l.Size = UDim2.fromOffset(510, 300)
		l.Parent = g
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.PaddingTop = UDim.new(0, 6)
		pad.Parent = l
		gui, label = g, l
		lane = marker("CombatDebugLane", Color3.fromRGB(120, 200, 255))
		mark = marker("CombatDebugIdeal", Color3.fromRGB(120, 255, 140))
	end

	local function attr(model: Instance?, name: string): any
		return if model then model:GetAttribute(name) else nil
	end
	local function cd(key: string): string
		local c = ctx and ctx.Char
		local untilT = attr(c, "CombatCD_" .. key)
		if type(untilT) ~= "number" then
			return "ready"
		end
		local left = untilT - workspace:GetServerTimeNow()
		return if left > 0 then string.format("%.2fs", left) else "ready"
	end

	local function refresh()
		if not (shown and ctx and label) then
			return
		end
		local char = ctx.Char
		local root = ctx.Root
		local dir = ctx.AimDir or flat(root.CFrame.LookVector)
		local along = aheadOf(dir)
		local a = ctx.Attack
		local def = a and a.Def
		local mv = ctx.Move
		local lines = {
			"COMBAT DEBUG (Studio only)  [F7]",
			string.format("state      local %-11s server %s", ctx.State, tostring(attr(char, "CombatState"))),
			string.format("chain      local slot %d heavy %s  #%d   server %s", ctx.Chain.Slot, tostring(ctx.Chain.Heavy), ctx.ChainNo, tostring(attr(char, "Dbg_Chain") or "-")),
			string.format("strike     %s  entered %.2f  hit %s", if a then a.Name else "-", if a then a.Enter or 0 else 0, if a and a.Impact then "SHOWN" else "-"),
			string.format("stun       budget %s  immune %ss  control %ss", tostring(attr(char, "Dbg_Budget") or "?"), tostring(attr(char, "Dbg_Immune") or "?"), tostring(attr(char, "Dbg_Control") or "?")),
			string.format("cooldown   dash %s   ground smash %s", cd("Dash"), cd("Downslam")),
			string.format("lane       body ahead %s   ideal %s", if along then string.format("%.2f", along) else "none", if def then string.format("%.2f", def.Ideal) else "-"),
			string.format("mover      step %s  carry %s", if mv and mv.Step then string.format("%.2f/%.2f", mv.Step.Travelled, mv.Step.Max) else "-", if mv and mv.Carry then string.format("gap %s", tostring(mv.Carry.Gap)) else "-"),
			string.format("network    ack %s %s  rtt %.0f ms  server-client %.0f ms", lastAck.Action, if lastAck.Ok then "ok" else "REFUSED", lastAck.Rtt * 1000, lastAck.Delta * 1000),
			string.format("buffer     %s", if ctx.Buffer then string.format("%s (%.2fs ago)", ctx.Buffer.Kind, now() - ctx.Buffer.At) else "-"),
			"last hit   " .. lastHit,
		}
		label.Text = table.concat(lines, "\n")
		-- the strike's lane along the aim, and its Ideal distance on it
		if lane and mark then
			local L = Config.Hitbox.Lane
			local base = root.Position - Vector3.new(0, 2.95, 0)
			lane.Size = Vector3.new(L * 2, 0.05, 10)
			lane.CFrame = CFrame.lookAt(base + dir * 5, base + dir * 10)
			lane.Transparency = 0.75
			lane.Parent = workspace
			local ideal = if def then def.Ideal else Config.Attacks.Swing1.Ideal
			mark.Size = Vector3.new(L * 2, 0.08, 0.12)
			mark.CFrame = CFrame.lookAt(base + dir * ideal, base + dir * (ideal + 1))
			mark.Parent = workspace
		end
	end

	local function setShown(on: boolean)
		shown = on
		if on and not gui then
			build()
		end
		if gui then
			gui.Enabled = on
		end
		if not on then
			if lane then
				lane.Parent = nil
			end
			if mark then
				mark.Parent = nil
			end
		end
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.F7 then
			setShown(not shown)
		end
	end)
	player:GetAttributeChangedSignal("CombatDebug"):Connect(function()
		setShown(player:GetAttribute("CombatDebug") == true)
	end)
	if player:GetAttribute("CombatDebug") == true then
		setShown(true)
	end
	RunService.Heartbeat:Connect(function()
		if shown then
			refresh()
		end
	end)
end
