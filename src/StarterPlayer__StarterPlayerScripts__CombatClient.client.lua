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
	  Forward dash + M1 = dash strike, jump + M1 = stomp

	Timing comes from CombatConfig (measured from the animation pack); the server repeats the same
	timing and has the final word (Ack corrections, Hit events, the CombatState attribute).
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

local ATTACK_ANIMS = { "Swing1", "Swing2", "Swing3", "Uppercut", "Sweep", "Downslam", "DashAttack" }
local DASH_ANIMS = { "DashForward", "DashBackward", "DashLeft", "DashRight" }
local REACTIONS = { "HitLeft", "HitRight" }
local COMBO = Config.Combo

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
	if player:GetAttribute("CombatDebug") == true then
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

-- every other fighter's root (dashes stop in front of them instead of passing through)
local function fighterRoots(): { BasePart }
	local list = {}
	for _, m in ipairs(charList()) do
		local models = if m:IsA("Folder") then m:GetChildren() else { m }
		for _, c in ipairs(models) do
			if c ~= ctx.Char and c:IsA("Model") and c:GetAttribute("Ragdolled") ~= true then
				local hum = c:FindFirstChildOfClass("Humanoid")
				local r = c:FindFirstChild("HumanoidRootPart")
				if hum and hum.Health > 0 and r and r:IsA("BasePart") then
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

local tryAttack: (string) -> ()

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
	-- a press made just before control came back goes off now
	if (s == "Idle" or s == "ComboWindow") and ctx.Queued and now() - ctx.QueuedAt <= COMBO.Buffer + 0.1 and was ~= "Attacking" then
		local k = ctx.Queued
		ctx.Queued = nil
		task.defer(function()
			if ctx then
				tryAttack(k)
			end
		end)
	end
end

local function cancelActions(keepBlock: boolean?)
	if not ctx then
		return
	end
	ctx.AttackSerial += 1
	ctx.Attack = nil
	ctx.Queued = nil
	ctx.Step = nil
	ctx.Follow = nil
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
	ctx.Queued = nil
	if os.clock() >= ctx.CounterHoldUntil then
		Counter.Drop()
	end
end

---------------------------------------------------------------------------
-- aim, facing, step-in
---------------------------------------------------------------------------
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

-- nearest fighter in front of the aim, for facing and the step-in
local function findTarget(aim: Vector3): BasePart?
	local best, bestD = nil, Config.AssistRange
	local cosA = math.cos(math.rad(Config.AssistAngle))
	for _, m in ipairs(charList()) do
		local models = if m:IsA("Folder") then m:GetChildren() else { m }
		for _, c in ipairs(models) do
			if c ~= ctx.Char and c:IsA("Model") and c:GetAttribute("CombatEntity") and c:GetAttribute("Ragdolled") ~= true then
				local hum = c:FindFirstChildOfClass("Humanoid")
				local r = c:FindFirstChild("HumanoidRootPart")
				if hum and hum.Health > 0 and r and r:IsA("BasePart") then
					local d = r.Position - ctx.Root.Position
					local fd = Vector3.new(d.X, 0, d.Z)
					local dist = fd.Magnitude
					if dist < bestD and math.abs(d.Y) < 6 and (dist < 1 or aim:Dot(fd.Unit) >= cosA) then
						best, bestD = r, dist
					end
				end
			end
		end
	end
	return best
end

local function faceTo(dir: Vector3, duration: number)
	local root = ctx.Root
	local target = flat(dir)
	ctx.FaceSerial += 1
	local serial = ctx.FaceSerial
	if duration <= 0 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + target)
		return
	end
	local start = flat(root.CFrame.LookVector)
	local t0 = now()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local k = math.min(1, (now() - t0) / duration)
		if not ctx or ctx.FaceSerial ~= serial or not root.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local d = start:Lerp(target, 1 - (1 - k) ^ 2)
		if d.Magnitude > 1e-3 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + d.Unit)
		end
		if k >= 1 and conn then
			conn:Disconnect()
		end
	end)
end

-- The attack mover: one drive on the root carrying two parts that add up -
--   the step-in: close in on the target during the strike's load-up so the limb lands on the body.
--     It follows the target while it happens and eases out as the gap reaches the strike's Ideal
--     distance; it never travels more than MaxLunge.
--   the follow: after a clean chain hit, slide along with the victim's knockback (a share of it),
--     so the next strike of the chain is still in reach. A new strike never cancels it.
-- Whichever starts, the drive is (re)started with both parts, so neither cuts the other off.
local function followVelocity(): Vector3
	local f = ctx.Follow
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

local function stepVelocity(dt: number): Vector3
	local s = ctx.Step
	if not s or ctx.AttackSerial ~= s.Serial then
		return Vector3.zero
	end
	local t = now() - s.T0
	if t < 0 or t >= s.Dur then
		return Vector3.zero
	end
	local root = ctx.Root
	local target = s.Target
	local dir, want = s.Fallback, s.Budget - s.Travelled
	if target and target.Parent then
		local d = target.Position - root.Position
		local fd = Vector3.new(d.X, 0, d.Z)
		if fd.Magnitude > 0.05 then
			dir = fd.Unit
			-- keep facing the body being stepped into
			local look = flat(root.CFrame.LookVector):Lerp(dir, 0.35)
			if look.Magnitude > 1e-3 then
				root.CFrame = CFrame.lookAt(root.Position, root.Position + look.Unit)
			end
		end
		want = math.max(0, fd.Magnitude - s.Ideal)
	end
	want = math.min(want, s.Budget - s.Travelled)
	local remaining = math.max(s.Dur - t, 1 / 60)
	local ease = math.min(1, t / 0.04) -- a quick push-off, not an instant jump
	local speed = math.clamp(want / remaining * 1.15, 0, 42) * ease
	s.Travelled += speed * dt
	return dir * speed
end

local function driveAttack()
	local c = ctx
	local t = now()
	local left = 0
	if c.Step and c.Step.Serial == c.AttackSerial then
		left = math.max(left, c.Step.T0 + c.Step.Dur - t)
	end
	if c.Follow then
		left = math.max(left, c.Follow.T0 + c.Follow.Dur - t)
	end
	if left <= 0.005 then
		return
	end
	local last = t
	Motion.Drive(c.Root, left, function()
		if ctx ~= c then
			return Vector3.zero
		end
		local n = now()
		local dt = math.max(0, n - last)
		last = n
		return stepVelocity(dt) + followVelocity()
	end, { StopAtWalls = true, Ignore = charList() })
end

local function stepIn(def: any, target: BasePart?, serial: number)
	if def.MaxLunge <= 0 then
		return
	end
	local t0 = def.LungeFrom / def.Speed
	local dur = math.max(0.05, (def.LungeTo - def.LungeFrom) / def.Speed)
	task.delay(t0, function()
		if not ctx or ctx.AttackSerial ~= serial then
			return
		end
		local root = ctx.Root
		dbg("step-in", def.Id, target and target.Parent and target.Parent.Name, target and (target.Position - root.Position).Magnitude)
		ctx.Step = {
			Serial = serial,
			T0 = now(),
			Dur = dur,
			Target = target,
			Ideal = def.Ideal,
			Budget = if target then def.MaxLunge else 0.5, -- no target: just a small weight shift
			Travelled = 0,
			Fallback = flat(root.CFrame.LookVector),
		}
		driveAttack()
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
		dbg("tick", c.State, c.Queued, m1StillHeld())
		if c.State ~= "Attacking" and c.State ~= "ComboWindow" then
			return
		end
		if c.Queued then
			local k = c.Queued
			c.Queued = nil
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

-- replaySeq: re-showing a strike the server already started (no new request)
local function playAttack(name: string, slot: number, replaySeq: number?)
	local def = Config.Attacks[name]
	local t = now()
	local seq: number
	if replaySeq then
		seq = replaySeq
	else
		ctx.Seq += 1
		seq = ctx.Seq
	end
	-- the strike before it (if its clip is still on screen) decides the cross-fade
	local prev = ctx.Attack
	local prevName = if prev and ctx.AttackTrack and ctx.AttackTrack.IsPlaying then prev.Name else nil
	ctx.AttackSerial += 1
	local serial = ctx.AttackSerial
	ctx.Attack = { Name = name, Slot = slot, T0 = t, Serial = serial, Seq = seq, Def = def, Stopped = false }
	ctx.Queued = nil
	setLocal("Attacking", busyTime(def))
	ctx.IdleTime = 0
	local fade = Config.BlendInto(prevName, name)
	for _, k in ipairs(ATTACK_ANIMS) do
		if k ~= def.Anim then
			ctx.AC:Stop(k, fade)
		end
	end
	ctx.AC:StopMany(DASH_ANIMS, 0.06)
	ctx.AC:StopMany(REACTIONS, 0.08)
	ctx.AttackTrack = ctx.AC:Play(def.Anim, { Fade = fade, Speed = def.Speed, Restart = true })
	-- the whoosh lands with the snap of the limb, not the start of the wind-up
	local heavy = def.Rank >= 3
	task.delay(math.max(0, def.HitReal - 0.07), function()
		if ctx and ctx.AttackSerial == serial then
			FX.Sound(if heavy then "HeavySwing" else "Swing", ctx.Root.Position, 1)
		end
	end)
	-- face the target (or the aim) and step in
	if name ~= "Downslam" then
		local aim = aimDirection()
		local target = findTarget(aim)
		local faceDir = if target then (target.Position - ctx.Root.Position) else aim
		faceTo(faceDir, if name == "DashAttack" then 0 elseif heavy then 0.1 else 0.07)
		if name ~= "DashAttack" then
			stepIn(def, target, serial)
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
	-- report as the active frames begin and midway through them
	local path = Paths[name]
	if path and name ~= "Downslam" then
		for _, frac in ipairs({ 0, 0.5 }) do
			local tau = path.From + (path.To - path.From) * frac
			task.delay(math.max(0, tau / def.Speed - 0.012), function()
				if ctx and ctx.AttackSerial == serial then
					reportFrame(seq)
				end
			end)
		end
	end
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
	ctx.DownslamUntil = now() + def.LengthReal + def.Cooldown
	Rules.Reset(ctx.Chain)
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
	local function done()
		if conn then
			conn:Disconnect()
			conn = nil
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
		end
		local grounded = c.Hum.FloorMaterial ~= Enum.Material.Air or heightAboveGround(root) < 0.25
		if grounded or e > def.Hang + def.MaxFall then
			done()
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(root.AssemblyLinearVelocity.Y, 0), 0)
			if c.Attack and c.Attack.Serial == serial then
				reportFrame(c.Attack.Seq, true)
			end
			if track and track.IsPlaying then
				if track.TimePosition < def.StompAt then
					track.TimePosition = def.StompAt
				end
				track:AdjustSpeed(def.Speed)
			end
			-- the attacker's own stomp lands on its own screen at once (everyone else: the server's FX)
			task.delay(def.StompDelay, function()
				if ctx == c and c.AttackSerial == serial then
					local p = root.CFrame:PointToWorldSpace(Vector3.new(-0.5, -2.9, -1.1))
					FX.Stomp(p, c.Char)
					FX.Sound("Slam", p, 1)
					FX.Shake(c.Hum, 0.5, 0.18)
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
	Rules.Reset(ctx.Chain)
	local v = ctx.Root.AssemblyLinearVelocity
	local speed = math.max(Vector3.new(v.X, 0, v.Z).Magnitude, Config.Dash.Forward.TopSpeed * 0.6)
	local dir = flat(ctx.Root.CFrame.LookVector)
	playAttack("DashAttack", 0)
	-- momentum carries straight into the strike, then bleeds off (stopping short of a body)
	local dur = 0.24
	Motion.Drive(ctx.Root, dur, function(t)
		return dir * speed * (1 - t / dur) ^ 1.3
	end, { StopAtWalls = true, Ignore = charList(), Fighters = fighterRoots(), Gap = Config.Dash.StopGap - 0.2, Width = Config.Dash.StopWidth })
end

local function queue(kind: string)
	ctx.Queued = kind
	ctx.QueuedAt = now()
end

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
			queue(kind)
		end
		return
	end
	if s == "Stunned" or s == "GuardBroken" or s == "Recovering" then
		if ctx.StateUntil and ctx.StateUntil - t <= COMBO.Buffer then
			queue(kind)
		end
		return
	end
	if s ~= "Idle" and s ~= "ComboWindow" and s ~= "Attacking" then
		dbg("try state", kind, s)
		return
	end
	-- jump + M1 is the stomp. Only a real jump counts: a body that leaves the ground for a moment
	-- (the slide along with a knocked-back victim running over a bump or off a kerb) keeps its
	-- ground combo - a mashed M1 must never vanish there
	if s ~= "Attacking" and airborne() and t - ctx.LastJumpAt < 1.6 then
		dbg("try air", kind, s)
		if kind == "Light" and t >= ctx.DownslamUntil then
			startDownslam()
		end
		return
	end
	if s == "Attacking" and not Rules.Live(ctx.Chain, t) then
		return -- a finisher / dash strike / stomp owns the character to its end
	end
	local verdict, name, slot, heavy, lights = Rules.Decide(ctx.Chain, kind, t)
	dbg("try", kind, s, verdict, name, slot, t - ctx.Chain.OpenAt)
	if verdict == "early" then
		-- pressed before the chain point: kept if close enough, fired exactly on it
		if t >= ctx.Chain.OpenAt - COMBO.Buffer then
			queue(kind)
			scheduleChain()
		end
		return
	end
	if verdict ~= "go" or not name then
		return
	end
	Rules.Commit(ctx.Chain, name, slot :: number, heavy :: boolean, lights :: number, t)
	playAttack(name, slot :: number)
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

local function tryDash()
	if inputBlocked() then
		return
	end
	local t = now()
	if not States.Allows(ctx.State, "Dash") or t < ctx.DashCooldownUntil or airborne() then
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
	faceTo(face, 0)
	ctx.AC:StopMany(ATTACK_ANIMS, 0.05)
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

-- the reaction clip, held on its impact frame through the hit-stop, then played at `speed`
local function react(key: string, speed: number, hitstop: number, fade: number?): AnimationTrack?
	local tr = ctx.AC:Play(key, { Fade = fade or 0.04, Speed = 0, Restart = true })
	local serial = ctx.StateSerial
	local c = ctx
	task.delay(hitstop, function()
		if ctx == c and tr and tr.IsPlaying and c.StateSerial == serial then
			tr:AdjustSpeed(speed)
			holdReaction(tr, speed, serial)
		end
	end)
	return tr
end

local function onHitMe(data: any, def: any)
	local hum, root = ctx.Hum, ctx.Root
	local class = def.ClassDef
	local hs = data.HS or 0
	if data.RD then
		-- launched: the impact pose through the hit-stop, then the body goes (Ragdolled attribute)
		cancelActions()
		endChain()
		setLocal("Ragdolled")
		react(data.R, 0, hs + 1)
		FX.Shake(hum, class.VictimShake, 0.26)
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
			task.delay(hs, function()
				if ctx and ctx.State == "GuardBroken" then
					Motion.Push(root, kb, kt, charList())
				end
			end)
		end
		FX.Shake(hum, class.VictimShake, 0.24)
		return
	end
	if data.B then
		-- absorbed: the guard can't drop for a beat, the stance slides back (the tilt plays for everyone)
		ctx.BlockLockUntil = math.max(ctx.BlockLockUntil, now() + (class.BlockStun or 0) + hs)
		if data.KT > 0 then
			local kb, kt = data.KB, data.KT
			task.delay(hs, function()
				if ctx and ctx.State == "Blocking" then
					Motion.Push(root, kb, kt, charList())
				end
			end)
		end
		FX.Shake(hum, if def.Rank >= 3 then 0.3 else 0.14, 0.1)
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
	FX.Shake(hum, class.VictimShake, if def.Rank >= 3 then 0.18 else 0.12)
end

-- the attacker's side of the hit-stop: the clip freezes on contact, the chain waits for it
-- where a landed blow's effect goes and which way it is thrown. The server's contact point is
-- mapped onto the body as THIS screen shows it (its height and side on the body, just in front of
-- the surface the attacker hit), so the burst always sits on the fighter it came from; it is thrown
-- away from the attacker, rising for the uppercut, low and wide for the sweep, toward the side the
-- head was driven for the hooks.
local function impactOn(data: any, def: any): (Vector3, Vector3)
	local p: Vector3 = data.P
	local vic = data.V
	local att = data.A
	local vr = vic and vic:FindFirstChild("HumanoidRootPart")
	local ar = att and att:FindFirstChild("HumanoidRootPart")
	if not (vr and vr:IsA("BasePart")) then
		return p, Vector3.yAxis
	end
	local away = if ar and ar:IsA("BasePart") then flat(vr.Position - ar.Position) else flat(vr.Position - p)
	local right = away:Cross(Vector3.yAxis)
	right = if right.Magnitude > 1e-3 then right.Unit else Vector3.xAxis
	local rel = p - vr.Position
	local height = math.clamp(rel.Y, -2.7, 1.9)
	local side = math.clamp(rel:Dot(right), -1.0, 1.0)
	local front = if data.B or data.G then 1.25 else 0.8 -- blocked: on the guard, in front of the arms
	local at = vr.Position - away * front + right * side + Vector3.new(0, height, 0)
	local rise = if def.Id == "Uppercut" then 1.1 elseif def.Id == "Sweep" then 0.15 elseif def.Id == "Downslam" then 0.7 else 0.35
	local vright = flat(vr.CFrame.RightVector)
	local dir = away + Vector3.new(0, rise, 0) + vright * ((data.Dir or 0) * (if def.ReactPush and def.ReactPush ~= 0 then 0.45 else 0.15))
	return at, dir.Unit
end

local function hitStop(data: any, def: any)
	local a = ctx.Attack
	local track = ctx.AttackTrack
	if not (a and a.Name == data.K and a.Slot == (data.Slot or 0) and not a.Stopped) then
		return
	end
	a.Stopped = true
	local d = data.HS or 0
	if d <= 0 then
		return
	end
	if a.Slot > 0 then
		Rules.Delay(ctx.Chain, d)
		scheduleChain()
	end
	if ctx.State == "Attacking" and ctx.StateUntil then
		ctx.StateUntil += d
	end
	if track and track.IsPlaying then
		local serial = a.Serial
		track:AdjustSpeed(0.02)
		task.delay(d, function()
			if ctx and ctx.AttackSerial == serial and track.IsPlaying then
				track:AdjustSpeed(def.Speed)
			end
		end)
	end
end

Event.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "Hit" then
		local def = Config.Attacks[data.K]
		if not def then
			return
		end
		local class = def.ClassDef
		local victim = data.V
		local heavy = def.Rank >= 3
		-- everyone: the effect on the body where the blow landed, the sound, the body giving
		if not data.G then
			local fxKind = if data.B then (if heavy then "HeavyBlock" else "Block")
				elseif data.RD or def.Class == "Finisher" then "Finisher"
				elseif heavy then "Heavy"
				else "Hit"
			local at, dir = impactOn(data, def)
			FX.Impact(at, fxKind, dir)
			if data.RD and victim then
				-- launched: the ground under them takes the blow too
				local vr = victim:FindFirstChild("HumanoidRootPart")
				if vr and vr:IsA("BasePart") then
					FX.GroundDust(vr.Position, 0.75)
				end
			end
		end
		if data.G then
			FX.Sound("GuardBreak", data.P, 1)
			FX.Sound("GuardBreakThud", data.P, 1)
			if victim then
				local at = impactOn(data, def)
				FX.GuardBreak(victim, at, data.A)
			end
		elseif data.B then
			FX.Sound(if heavy then "HeavyBlock" else "Block", data.P, 1)
		elseif data.RD then
			FX.Sound("HeavyHit", data.P, 0.9)
			FX.Sound("Knockdown", data.P, 1)
		else
			FX.Sound(if heavy then "HeavyHit" else "Hit", data.P, 1)
		end
		if victim then
			if data.B then
				FX.BlockGive(victim, class, data.Dir or 1, heavy)
			elseif not data.RD and not data.G and def.Tilt and data.PR then
				FX.HitGive(victim, def, data.Dir or 1, heavy)
			end
		end
		if not ctx then
			return
		end
		if data.A == ctx.Char then
			hitStop(data, def)
			-- a clean chain strike carries the attacker along with the victim's slide
			if not data.B and not data.G and not data.RD and (data.KT or 0) > 0.02 and def.Class ~= "Dash" then
				local f = {
					Vec = Vector3.new(data.KB.X, 0, data.KB.Z) * Config.Hitbox.Follow,
					T0 = now() + (data.HS or 0),
					Dur = data.KT,
				}
				ctx.Follow = f
				dbg("follow", data.K, f.Vec.Magnitude, f.Dur)
				local c = ctx
				task.delay(data.HS or 0, function()
					if ctx == c and c.Follow == f and (c.State == "Attacking" or c.State == "ComboWindow") then
						driveAttack()
					end
				end)
			end
			FX.Shake(ctx.Hum, class.Shake * (if data.B then 0.5 else 1), if heavy then 0.14 else 0.1)
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
		if data.Kind == "Dash" and typeof(data.A) == "Instance" and data.A:IsA("Model") and not (ctx and data.A == ctx.Char) then
			FX.Dash(data.A, data.Dir)
		end
		if data.Kind == "Slam" and not (ctx and data.A == ctx.Char) and typeof(data.P) == "Vector3" then
			FX.Stomp(data.P, if typeof(data.A) == "Instance" and data.A:IsA("Model") then data.A else nil)
			FX.Sound("Slam", data.P, 1)
			if ctx and (data.P - ctx.Root.Position).Magnitude < 20 then
				FX.Shake(ctx.Hum, 0.5, 0.18)
			end
		end
	elseif kind == "Ack" then
		if not ctx then
			return
		end
		if data.Kind == "Attack" then
			local a = ctx.Attack
			if not (a and a.Seq == data.Seq) then
				return
			end
			if data.Ok then
				-- the server's count stands (it only differs right at a window edge)
				if type(data.Chain) == "table" then
					ctx.Chain.Slot = data.Chain.Slot
					ctx.Chain.Heavy = data.Chain.Heavy
					ctx.Chain.Lights = data.Chain.Lights
				end
				if data.Action and data.Action ~= a.Name then
					-- the server started a different strike: show that one instead
					local name, slot = data.Action, data.Slot or 0
					local elapsed = now() - a.T0
					local def = Config.Attacks[name]
					cancelActions(true)
					if def and slot > 0 then
						Rules.Commit(ctx.Chain, name, slot, ctx.Chain.Heavy, ctx.Chain.Lights, a.T0)
						if type(data.Chain) == "table" then
							ctx.Chain.Slot = data.Chain.Slot
							ctx.Chain.Heavy = data.Chain.Heavy
							ctx.Chain.Lights = data.Chain.Lights
						end
					end
					playAttack(name, slot, data.Seq)
					if ctx.AttackTrack and def then
						ctx.AttackTrack.TimePosition = math.min(elapsed * def.Speed, def.Hit * 0.6)
					end
				end
			else
				-- refused: roll back to where the server has us
				dbg("refused", a.Name, a.Slot)
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

	-- a combo whose window closed is over (the counter goes with it)
	if ctx.Chain.Slot > 0 and not Rules.Live(ctx.Chain, t) and s ~= "Attacking" then
		endChain()
	end
	if Counter.Shown() and ctx.Chain.Slot == 0 and s ~= "Attacking" and t >= ctx.CounterHoldUntil then
		Counter.Drop()
	end
	if ctx.Queued and t - ctx.QueuedAt > 0.6 then
		ctx.Queued = nil -- a stale press never fires late
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
	if hs == Enum.HumanoidStateType.Freefall and t - ctx.FreefallAt > 0.2 and not stomping then
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
	local jump = if s == "Idle" or s == "ComboWindow" then Config.JumpHeight else 0
	if hum.JumpHeight ~= jump then
		hum.JumpHeight = jump
	end
	updateTurn()
end

---------------------------------------------------------------------------
-- character lifecycle
---------------------------------------------------------------------------
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
		Attack = nil,
		AttackTrack = nil,
		AttackSerial = 0,
		AirHeight = 0,
		Step = nil,
		Follow = nil,
		Seq = 0,
		DashSeq = 0,
		BlockSeq = 0,
		Queued = nil,
		QueuedAt = 0,
		M1Held = false,
		M1Source = nil,
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
		FaceSerial = 0,
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

	table.insert(c.Conns, hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			c.LastJumpAt = now()
			c.IdleTime = 0
			if c.State == "Idle" or c.State == "ComboWindow" then
				c.AC:Play("Jump", { Fade = 0.08, Restart = true })
			end
		elseif new == Enum.HumanoidStateType.Freefall then
			c.FreefallAt = now()
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
-- while guarding - the guard keeps its facing).
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
		if States.Allows(ctx.State, "Turn") then
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

local function m1Down(source: string?)
	if not ctx then
		return
	end
	ctx.M1Held = true
	ctx.M1Source = source or "Touch"
	tryAttack("Light")
end
local function m1Up()
	if ctx then
		ctx.M1Held = false
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
-- the camera never drags, so it fires on press)
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
			heavyPress()
		end
		m2.Down = false
	elseif ut == Enum.UserInputType.Gamepad1 then
		if kc == Enum.KeyCode.ButtonR2 or kc == Enum.KeyCode.ButtonX then
			m1Up()
		elseif kc == Enum.KeyCode.ButtonL2 then
			blockUp()
		end
	end
end)

-- a window/overlay opening mid-guard drops the guard (the release would never arrive)
player:GetAttributeChangedSignal("UIWindow"):Connect(function()
	if ctx and player:GetAttribute("UIWindow") ~= nil then
		ctx.M1Held = false
		blockUp()
	end
end)
player:GetAttributeChangedSignal("UIOverlay"):Connect(function()
	if ctx and player:GetAttribute("UIOverlay") ~= nil then
		ctx.M1Held = false
		blockUp()
	end
end)

-- Studio play-tests: a BindableEvent that presses the same buttons with exact timing
-- (game.Players.LocalPlayer.CombatDebug:Fire("Light" | "Heavy" | "BlockOn" | "BlockOff" | "Dash", dir?))
if RunService:IsStudio() then
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
			M1Down = function()
				m1Down("Touch")
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
