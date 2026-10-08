--[[
	Parkour  (StarterPlayerScripts.CombatClient.Parkour)
	The eleven movement moves (Config.Parkour), run for the local player's fighter as part of its own
	locomotion - CombatClient owns the character and drives this every frame; nothing here runs on its
	own clock or binds keys of its own.

	  crouch (C)  crawl (X)  slide (C while running)  slide cancel (jump while sliding)
	  double jump (jump in the air)  leap (R)  vault (jump at / run into something low)
	  ledge vault (reach a ledge: from a climb or a jump)  wall climb (jump at a wall, hold forward)
	  wall run (jump beside a wall while running)  wall jump (jump on a wall: off a run or a climb)
	  (gamepad: LB crouch/slide, RB leap, D-pad down crawl, A jump; touch: CROUCH / CRAWL / LEAP)

	ONE FIGHTER, ONE STATE. A move only starts from Idle (the combat state machine's free locomotion)
	and keeps the combat state Idle while it runs - so everything the fight does still applies to it:
	a stun, a guard break, a knockdown or death ends it on the spot (Interrupt), and an attack, a dash
	or a guard asks first (BeforeAction): a crouch stands up into it, a slide ends into it, a crawl
	stands up, and the moves that hang on a wall or on the vault's hand refuse it.

	THE BODY DECIDES (BodyState, Config.Parkour.Requires). Every press checks the limbs the move's clip
	really uses; a press the body can't answer shakes the HUD's limb pill, the way a strike without
	arms does. The body is watched while a move runs: a limb lost mid-move ends the move that needs it
	that same frame - the climber's hands let go and it falls, the wall runner peels off the wall, the
	slide stands up, the vault lets go of the top - keeping the momentum it had, never snapping. No
	input order gets round it: the slide cancel checks the legs again when it is pressed, the vault
	plays the clip whose planted hand the body still has, a crouch or crawl that the body can no longer
	hold stands up.

	THE WORLD IS SOLID. Every move is driven with collisions ON: a vault rises until the body's hitbox
	clears the top it measured, a ledge is only taken where there is room to stand, and a drive that
	meets something it didn't expect lets go instead of pushing through it.

	THE NETWORK. What this body is doing is sent to the server (CombatRequest "Parkour"), which checks it
	against its own record of the body and sets the character's Parkour attribute for everyone (the
	hitbox of a low body, the effects on every screen - MovementFX); a refusal ends it here too. The
	body's motion itself replicates like any other, so every screen sees the same move and the same end.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Motion = require(CombatFolder:WaitForChild("Motion"))
local FX = require(CombatFolder:WaitForChild("CombatFX"))
local BodyState = require(CombatFolder:WaitForChild("BodyState"))
local MovementFX = require(CombatFolder:WaitForChild("MovementFX"))

local P = Config.Parkour

local Parkour = {}

-- the moves that keep their own anims on the body (and the loops they run)
-- states that hold the body off the ground under their own drive (no walking, no humanoid jump,
-- no turning of their own, no strike)
local HANGING = { Vault = true, LedgeVault = true, Climb = true, WallRunLeft = true, WallRunRight = true }
-- postures (the body down low: its speed, its camera, its hitbox)
local LOW = { Crouch = true, Crawl = true, Slide = true }

local api: any = nil -- CombatClient's side (see Parkour.Init)
local ctx: any = nil -- the fighter (CombatClient's ctx)

-- this life's movement: what the body is doing and everything it needs to stop it cleanly
type Run = {
	State: string?,
	Since: number,
	Serial: number,
	Tracks: { string },
	Data: any,
	Watch: any,
	AirJumpUsed: boolean,
	ClimbLeft: number,
	LastGrounded: number,
	LastWallRun: { Wall: Instance?, At: number },
	LastClimbEnd: number,
	LeapUntil: number,
	SlideUntil: number,
	VaultUntil: number,
	PrevVy: number,
	RollGuard: { Box: Part, Parts: { BasePart }, Until: number }?, -- the landing roll's body (rollGuard)
	ImpactVy: number?, -- the speed a long fall really had before its touchdown was eased
	WasAir: boolean,
	JumpAt: number,
	Momentum: any,
	Cam: number,
	CamWant: number,
	Drive: LinearVelocity?,
	DriveAtt: Attachment?,
	CrouchHeld: boolean,
	SentState: string?,
	Queued: any,
	Pending: any,
	Replay: any,
}
local run: Run? = nil

local function now(): number
	return os.clock()
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zero
end

---------------------------------------------------------------------------
-- the world: what a move may climb, run on or vault (solid, still, not a fighter, not an effect)
---------------------------------------------------------------------------
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.RespectCanCollide = true
worldParams.IgnoreWater = true
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true
local filterAt = -math.huge
local function refreshFilter()
	local t = now()
	if t - filterAt < 0.25 then
		return
	end
	filterAt = t
	local list: { Instance } = {}
	for _, i in ipairs(api.CharList()) do
		table.insert(list, i)
	end
	for _, name in ipairs({ "CombatBlood", "CombatGore", "CombatFX", "CombatShatter", "CombatDebugLane", "CombatDebugIdeal" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	worldParams.FilterDescendantsInstances = list
	overlap.FilterDescendantsInstances = list
end

-- a surface the movement may use: solid, still, and not marked off (CollectionService "NoParkour")
local function usable(hit: RaycastResult?): boolean
	if not hit then
		return false
	end
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		return hit.Material ~= Enum.Material.Water
	end
	if not inst:IsA("BasePart") then
		return false
	end
	if CollectionService:HasTag(inst, "NoParkour") or inst.Transparency >= 0.95 then
		return false
	end
	local root = inst.AssemblyRootPart
	return inst.Anchored or (root ~= nil and root.Anchored)
end

local function cast(from: Vector3, dir: Vector3): RaycastResult?
	refreshFilter()
	local hit = workspace:Raycast(from, dir, worldParams)
	return if usable(hit) then hit else nil
end

-- is there room for a standing body with its root at `p` facing `look`? (nothing solid in its box)
local function roomAt(p: Vector3, look: Vector3): boolean
	refreshFilter()
	local cf = CFrame.lookAt(p + Vector3.new(0, 0.25, 0), p + Vector3.new(0, 0.25, 0) + look)
	local parts = workspace:GetPartBoundsInBox(cf, Vector3.new(1.9, 4.4, 1.1), overlap)
	return #parts == 0
end

-- the floor under the body (nil: in the air over nothing near)
local function floorBelow(p: Vector3, depth: number): RaycastResult?
	refreshFilter()
	return workspace:Raycast(p, Vector3.new(0, -depth, 0), worldParams)
end

---------------------------------------------------------------------------
-- the drive: one LinearVelocity of our own for the moves that carry the body off the ground (the
-- combat's CombatDrive stays the combat's: it is stopped first so the two never pull at once)
---------------------------------------------------------------------------
local function drive(): LinearVelocity?
	local r = run
	if not (r and ctx and ctx.Root.Parent) then
		return nil
	end
	if r.Drive and r.Drive.Parent then
		return r.Drive
	end
	local a = Instance.new("Attachment")
	a.Name = "ParkourDriveAttachment"
	a.Parent = ctx.Root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "ParkourDrive"
	lv.Attachment0 = a
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 90000
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = ctx.Root
	r.Drive, r.DriveAtt = lv, a
	return lv
end

local function driveTo(v: Vector3)
	local lv = drive()
	if not lv then
		return
	end
	if not lv.Enabled then
		Motion.Stop(ctx.Root, true)
	end
	lv.VectorVelocity = v
	lv.Enabled = true
end

-- the drive lets go: the body keeps the velocity it has (a move's momentum is never thrown away)
local function release(keep: boolean?)
	local r = run
	if r and r.Drive then
		r.Drive.Enabled = false
		r.Drive.VectorVelocity = Vector3.zero
	end
	if not keep and ctx and ctx.Root.Parent then
		local v = ctx.Root.AssemblyLinearVelocity
		ctx.Root.AssemblyLinearVelocity = Vector3.new(v.X * 0.5, math.min(v.Y, 0), v.Z * 0.5)
	end
end

-- the body faces `dir` (flat): written straight to the root while a move owns the facing
local function face(dir: Vector3)
	local d = flat(dir)
	if d.Magnitude < 0.5 or not ctx then
		return
	end
	local root = ctx.Root
	root.CFrame = CFrame.lookAt(root.Position, root.Position + d)
end

---------------------------------------------------------------------------
-- animations (the fighter's one AnimController)
---------------------------------------------------------------------------
-- how much of a stride (walk / run, held still under a move - enter) is still on the body
local function strideUnder(): number
	local w = 0
	for _, k in ipairs({ "Walk", "Run" }) do
		local tr = ctx.AC.Tracks[k]
		if tr then
			w = math.max(w, tr.WeightCurrent)
		end
	end
	return w
end

--[[ a move's clip coming in over a stride holds still while it fades in, on the frame it will be at
	when it is fully in (then plays on from there, on time): the stride under it is held still too
	(enter), so the hand-over is between two poses that keep still - the stride's arms are near a
	half turn from most moves' at the shoulder, and with either one moving through the fade the
	blend's short way round can change sides part way: one frame's flip of an arm ]]
local function play(key: string, opts: any?): AnimationTrack?
	local r = run
	if not r then
		return nil
	end
	local o = table.clone(opts or {})
	if o.Restart == nil then
		o.Restart = true
	end
	local hold = 0
	local speed = if o.Speed ~= nil then o.Speed else 1
	if o.Restart and (o.Fade or 0) > 0 and speed > 0 and strideUnder() > 0.3 then
		hold = o.Fade
		o.Time = (o.Time or 0) + hold * speed
		o.Speed = 0
	end
	local tr = ctx.AC:Play(key, o)
	if tr and not table.find(r.Tracks, key) then
		table.insert(r.Tracks, key)
	end
	if tr and hold > 0 then
		local serial = r.Serial
		task.delay(hold, function()
			if run == r and r.Serial == serial and tr.IsPlaying and tr.Speed == 0 then
				tr:AdjustSpeed(speed)
			end
		end)
	end
	return tr
end

local function stopTracks(fade: number, except: string?)
	local r = run
	if not r then
		return
	end
	for i = #r.Tracks, 1, -1 do
		local k = r.Tracks[i]
		if k ~= except then
			-- (a looping clip - a wall run's stride, a climb's reach - holds the pose it has while it
			-- fades: its limbs swinging on through what takes over would cross that the other way round
			-- part way, one frame's snap)
			local tr = ctx.AC.Tracks[k]
			if tr and tr.IsPlaying and tr.Looped then
				tr:AdjustSpeed(0)
			end
			ctx.AC:Stop(k, fade)
			table.remove(r.Tracks, i)
		end
	end
end

---------------------------------------------------------------------------
-- the state (local at once; the server hears it)
---------------------------------------------------------------------------
local function send(state: string?)
	local r = run
	if not r or r.SentState == state then
		return
	end
	r.SentState = state
	api.Request("Parkour", { S = state or false })
end

local function event(kind: string, data: any?)
	MovementFX.Event(ctx.Char, kind, data)
	api.Request("Parkour", { E = kind, D = data })
end

local stop: (reason: string, opts: any?) -> ()

local function enter(state: string, data: any?)
	local r = run :: Run
	if r.State then
		-- (a move straight out of another - a wall jump's flight into the next wall run: the last one
		-- ends properly first, its drive and clips with it)
		stop("done", { Keep = true, Fade = 0.08 })
	end
	r.State = state
	r.Since = now()
	r.Serial += 1
	r.Data = data or {}
	-- (the stride under the move's clip holds its pose from this frame on - the locomotion step would
	-- only see the move next frame, one more frame of arms swinging under the clip coming in)
	for _, k in ipairs({ "Walk", "Run" }) do
		local tr = ctx.AC.Tracks[k]
		if tr and tr.WeightCurrent > 0 and tr.Speed ~= 0 then
			tr:AdjustSpeed(0)
		end
	end
	MovementFX.SetLocal(ctx.Char, state)
	send(state)
end

-- the camera's height with the posture (eased every frame in Step)
local CAMERA = { Crouch = P.Crouch.Camera, Crawl = P.Crawl.Camera, Slide = P.Slide.Camera }

---------------------------------------------------------------------------
-- stopping: every way out goes through here (forces off, clips faded out, the camera back)
---------------------------------------------------------------------------
--[[ reason: "done" (it finished), "action" (a strike / dash / guard takes over: out at once),
	"hit" (a stun, a knockdown, death: out at once, the fight takes the body), "limb" (a limb it needs
	is gone: let go, momentum kept), "refused" (the server said no), "stand" (up out of a crouch/crawl),
	"input" (released / jumped off). opts.Keep: keep the body's velocity. opts.Fade: the clips' fade ]]
function stop(reason: string, opts: any?)
	local r = run
	if not r or not r.State then
		return
	end
	local o = opts or {}
	local was = r.State :: string
	if (was == "WallRunLeft" or was == "WallRunRight") and r.Data.Wall then
		-- (the wall just left can't be run again until the cooldown is up: never a re-grab the next frame)
		r.LastWallRun = { Wall = r.Data.Wall, At = now() }
	end
	r.State = nil
	r.Serial += 1
	r.Data = {}
	local quick = reason == "hit" or reason == "action"
	local fade = o.Fade or (if quick then 0.08 elseif reason == "limb" then 0.14 elseif LOW[was] then 0.28 else 0.18)
	if HANGING[was] then
		release(o.Keep ~= false)
		ctx.Hum.AutoRotate = api.TurnFree()
		FX.SetCameraLean(0)
	end
	if was == "Slide" then
		Motion.Stop(ctx.Root, o.Keep ~= false)
		ctx.Hum.AutoRotate = api.TurnFree()
	end
	if (was == "Leap" or was == "WallJump") and r.Momentum then
		r.Momentum = nil
		Motion.Stop(ctx.Root, true)
	end
	if was == "WallJump" then
		ctx.Hum.AutoRotate = api.TurnFree()
	end
	if was == "Climb" then
		r.LastClimbEnd = now()
	end
	-- let go of in the air: the fall goes on under the move's clip while that is still at full weight
	-- (unseen), and the clip fades out over it - straight from one to the other
	if ctx.Hum.FloorMaterial == Enum.Material.Air and ctx.Char:GetAttribute("Ragdolled") ~= true and not ctx.AC:IsPlaying("Fall") then
		ctx.AC:Play("Fall", { Fade = 0 })
	end
	stopTracks(fade)
	FX.SetCameraFov(0)
	MovementFX.SetLocal(ctx.Char, nil)
	send(nil)
	-- (a refusal from the server is the server's own word: nothing to tell it back)
	if reason == "refused" then
		r.SentState = nil
	end
end

---------------------------------------------------------------------------
-- the body changed under a move (BodyState): the move is looked at again, that frame
---------------------------------------------------------------------------
local NEEDS: { [string]: string } = {
	Crouch = "Crouch", Crawl = "Crawl", Slide = "Slide", Vault = "Vault", LedgeVault = "LedgeVault",
	Climb = "Climb", WallRunLeft = "WallRun", WallRunRight = "WallRun", Leap = "Leap", WallJump = "WallJump",
}
local function reevaluate(new: any)
	local r = run
	if not r or not r.State or not ctx then
		return
	end
	if new.Ragdolled or not new.Alive then
		stop("hit")
		return
	end
	local st = r.State :: string
	local move = NEEDS[st]
	if not move then
		return
	end
	-- the vault hangs on one hand: the hand its clip plants must still be there
	if (st == "Vault" or st == "LedgeVault") and r.Data.Hand then
		local has = if r.Data.Hand == "Left" then new.HasLeftArm else new.HasRightArm
		if not has or new.Legs < 2 then
			stop("limb")
		end
		return
	end
	local ok = BodyState.Can(ctx.Char, move)
	if not ok then
		stop("limb")
	elseif st == "Crawl" then
		-- one limb fewer: the crawl goes on, slower (the clip slows with it)
		local missing = 4 - (new.Arms + new.Legs)
		r.Data.Scale = P.Crawl.Missing ^ missing
	end
end

---------------------------------------------------------------------------
-- the moves
---------------------------------------------------------------------------
local function grounded(): boolean
	return ctx.Hum.FloorMaterial ~= Enum.Material.Air
end

local function heightAboveFloor(): number
	local hit = floorBelow(ctx.Root.Position, 40)
	return if hit then math.max(0, ctx.Root.Position.Y - hit.Position.Y - 3) else 40
end

local function horizontalSpeed(): number
	local v = ctx.Root.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

-- how fast the body is really going for a slide: out of a dash it still has the dash's pace (the dash
-- stops its own drive dead as it ends - a slide pressed through it carries on at a run)
local function runSpeed(): number
	local hv = horizontalSpeed()
	local d = ctx.DashStart
	if type(d) == "number" and now() - d < P.Slide.AfterDash then
		return math.max(hv, Config.RunSpeed)
	end
	return hv
end

-- the way the player is steering (flat; zero with no input)
local function steer(): Vector3
	local md = ctx.Hum.MoveDirection
	return if md.Magnitude > 0.1 then flat(md) else Vector3.zero
end

local function denied(move: string): boolean
	local ok = BodyState.Can(ctx.Char, move)
	if not ok then
		api.LimbDenied()
		return true
	end
	return false
end

local function free(): boolean
	return ctx ~= nil and ctx.Alive and ctx.State == "Idle" and not api.InputBlocked() and ctx.Hum.Health > 0 and ctx.Char:GetAttribute("Ragdolled") ~= true
end

---------------- crouch / crawl -------------------------------------------
local function startCrouch()
	stopTracks(0.2)
	enter("Crouch")
	play("Crouch", { Fade = 0.18 })
end

local function startCrawl()
	local s = BodyState.Get(ctx.Char)
	stopTracks(0.25)
	enter("Crawl", { Scale = P.Crawl.Missing ^ (4 - (s.Arms + s.Legs)) })
	play("CrawlIdle", { Fade = 0.28 })
end

-- the loops under a crouch / crawl: idle standing still, the walk cycle at the pace the body moves
local function lowStep(still: string, moving: string, natural: number)
	local speed = horizontalSpeed()
	local tr = ctx.AC:Track(moving)
	if speed > 0.6 then
		local w = play(moving, { Fade = 0.12, Restart = false })
		if w then
			-- (still while it comes in over a stride held under it: see play)
			w:AdjustSpeed(if w.WeightCurrent < 0.9 and strideUnder() > 0.05 then 0 else math.clamp(speed / natural, 0.35, 1.8))
		end
		ctx.AC:Stop(still, 0.15)
	else
		if tr and tr.IsPlaying then
			ctx.AC:Stop(moving, 0.15)
		end
		play(still, { Fade = 0.15, Restart = false })
	end
end

---------------- slide / slide cancel -------------------------------------
local function startSlide()
	local root = ctx.Root
	local v = root.AssemblyLinearVelocity
	local dir = flat(Vector3.new(v.X, 0, v.Z))
	if dir.Magnitude < 0.5 then
		dir = flat(root.CFrame.LookVector)
	end
	local S = P.Slide
	if horizontalSpeed() < S.MinSpeed then
		-- (out of a dash: along the way the player steers)
		dir = steer()
		if dir.Magnitude < 0.5 then
			dir = flat(root.CFrame.LookVector)
		end
	end
	local v0 = math.min(runSpeed() + S.Boost, S.Max)
	local r = run :: Run
	r.SlideUntil = now() + S.Time + S.Cooldown
	stopTracks(0.1)
	enter("Slide", { Dir = dir, V0 = v0, Speed = v0 })
	ctx.Hum.AutoRotate = false
	face(dir)
	play("SlideStart", { Fade = 0.08, Speed = 1.35 })
	local serial = r.Serial
	task.delay(0.33, function()
		if run == r and r.Serial == serial and r.State == "Slide" then
			play("SlideLoop", { Fade = 0.14 })
		end
	end)
	FX.SetCameraFov(S.Fov)
	-- the slide: a burst on top of the run bleeding off to a crouch's pace, along the ground (the
	-- combat's own ground mover: it slides along walls and brakes before a body in its way)
	Motion.Drive(root, S.Time, function(t)
		local k = math.clamp(t / S.Time, 0, 1)
		local speed = S.End + (v0 - S.End) * (1 - k) ^ 1.6
		if run == r and r.Serial == serial then
			r.Data.Speed = speed
		end
		return dir * speed
	end, {
		StopAtWalls = true, Ignore = api.CharList(), Fighters = api.Bodies, Gap = 3.0, Width = 2.2, KeepVelocity = true,
		OnEnd = function()
			if run == r and r.Serial == serial and r.State == "Slide" then
				-- out of the slide: into a crouch with the key still held, else straight back to the run
				local held = r.CrouchHeld
				stop("done", { Keep = true, Fade = 0.22 })
				if held and BodyState.Can(ctx.Char, "Crouch") then
					startCrouch()
				else
					ctx.MovingFor = math.max(ctx.MovingFor, Config.AutoRunAfter)
				end
			end
		end,
	})
end

-- the air momentum a spring out of the ground carries (a leap, a slide cancel): the humanoid's own
-- air steering would pull a fast body back to a walk in a few frames, so the flight is driven along
-- the ground plane - easing off toward the run's pace, a little steerable - until it lands
local function carryFlight(dir: Vector3, v0: number, serial: number, steerAfter: number?)
	local r = run :: Run
	local d = dir
	local last = 0
	local floor = math.max(Config.RunSpeed, v0 * 0.55)
	local m = { Serial = serial }
	r.Momentum = m
	Motion.Drive(ctx.Root, 2.5, function(t)
		if run ~= r or r.Momentum ~= m then
			return Vector3.zero
		end
		local dt = math.max(0, t - last)
		last = t
		local want = steer()
		-- (a kick off a wall flies where it was kicked until the body is clear of it: the forward held
		-- on the wall would otherwise bend the flight straight back into it)
		if want.Magnitude > 0.5 and t >= (steerAfter or 0) then
			local off = math.acos(math.clamp(d:Dot(want), -1, 1))
			local most = math.rad(110) * dt
			d = if off <= most then want else flat(d:Lerp(want, most / off))
		end
		local speed = floor + (v0 - floor) * math.exp(-t * 2.2)
		return d * speed
	end, { StopAtWalls = true, Ignore = api.CharList(), Fighters = api.Bodies, Gap = 3.0, Width = 2.2, KeepVelocity = true })
end

local function slideCancel()
	local r = run :: Run
	local S = P.Slide
	-- (checked again now: a body that lost a leg since the slide began can't spring out of it)
	if not BodyState.Can(ctx.Char, "SlideCancel") then
		api.LimbDenied()
		return
	end
	local dir = r.Data.Dir or flat(ctx.Root.CFrame.LookVector)
	local speed = math.min((r.Data.Speed or Config.RunSpeed) * S.CancelCarry, S.CancelMax)
	stop("done", { Keep = true, Fade = 0.1 })
	enter("Leap", { Cancel = true })
	local serial = r.Serial
	local root = ctx.Root
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, S.CancelUp, v.Z)
	ctx.LastJumpAt = now()
	r.JumpAt = now()
	play("SlideCancel", { Fade = 0.06, Speed = 1.15 })
	FX.SetCameraFov(S.Fov * 0.6)
	carryFlight(dir, speed, serial)
	event("SlideCancel")
end

---------------- double jump ----------------------------------------------
local function doubleJump()
	local r = run :: Run
	if denied("DoubleJump") then
		return
	end
	r.AirJumpUsed = true
	-- (out of a leap's or a wall jump's flight: its clip gives way to the double jump's - the flight's
	-- momentum goes on, two air clips never play over each other). The wall jump's spin and the double
	-- jump's are the same clip, key for key: pressed while the spin is still going, the double jump
	-- takes it up at the frame it is on - two copies of one spin half a turn apart would cross-fade
	-- through each other the short way round (the torso flips). Once the spin is through, its last
	-- frame gives way quickly, before the new spin is turned far enough from it to flip
	local join: number? = nil
	if r.State == "Leap" or r.State == "WallJump" then
		local spin = ctx.AC.Tracks.WallJump
		if r.State == "WallJump" and spin and spin.IsPlaying and spin.TimePosition < spin.Length - 0.02 then
			join = spin.TimePosition
		end
		stopTracks(if r.State == "WallJump" then 0.06 else 0.08)
	end
	local root = ctx.Root
	local v = root.AssemblyLinearVelocity
	local up = math.sqrt(2 * workspace.Gravity * P.DoubleJump.Height)
	-- (set, not added: a double jump at the top of a jump and one in a fall rise the same)
	root.AssemblyLinearVelocity = Vector3.new(v.X, up, v.Z)
	ctx.LastJumpAt = now()
	r.JumpAt = now()
	local tr = ctx.AC:Play("DoubleJump", { Fade = 0.05, Restart = true, Time = join })
	if tr and not table.find(r.Tracks, "DoubleJump") then
		table.insert(r.Tracks, "DoubleJump")
	end
	event("DoubleJump")
end

---------------- leap -----------------------------------------------------
local function leap()
	local r = run :: Run
	local L = P.Leap
	if now() < r.LeapUntil then
		return
	end
	if denied("Leap") then
		return
	end
	local root = ctx.Root
	local dir = steer()
	if dir.Magnitude < 0.5 then
		dir = flat(root.CFrame.LookVector)
	end
	r.LeapUntil = now() + L.Cooldown
	stopTracks(0.08)
	enter("Leap")
	local serial = r.Serial
	face(dir)
	-- (out of a stride: its arms are a half turn from the leap's at the shoulder, and a blend that
	-- wide turns fastest half way - at 0.06 s most of it went on one frame)
	play("Leap", { Fade = 0.14 })
	FX.SetCameraFov(L.Fov)
	-- the push comes on the clip's own push-off frame (its "Velocity" marker)
	task.delay(L.Delay, function()
		if run ~= r or r.Serial ~= serial or r.State ~= "Leap" then
			return
		end
		-- (the legs are looked at again at the push: one lost in the wind-up never pushes)
		if not BodyState.Can(ctx.Char, "Leap") then
			stop("limb")
			return
		end
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, L.Up, v.Z)
		ctx.LastJumpAt = now()
		r.JumpAt = now()
		carryFlight(dir, L.Forward, serial)
		event("Leap")
	end)
end

---------------- vault / ledge vault --------------------------------------
-- a path the drive follows (world points and when to reach them), the clip timed to it
-- V0: the velocity the body comes in with, Exit: the one it leaves with. The path is a smooth curve
-- through its points that starts at V0 and ends at Exit - the body never stalls at the start of a
-- vault (a run carries straight into it) and never lurches at its end
type Path = { Points: { Vector3 }, Times: { number }, Exit: Vector3, V0: Vector3?, Tangents: { Vector3 }? }

-- (a cubic Hermite through the points: the tangent at each inner point from its neighbours, the ends
-- from V0 / Exit - each end's capped so the curve never bows out past its first / last point)
local function tangents(p: Path): { Vector3 }
	local pts, ts = p.Points, p.Times
	local n = #pts
	local m = table.create(n, Vector3.zero)
	for i = 2, n - 1 do
		m[i] = (pts[i + 1] - pts[i - 1]) / math.max(ts[i + 1] - ts[i - 1], 1e-4)
	end
	local function capped(v: Vector3, chord: Vector3, h: number): Vector3
		local most = 1.6 * chord.Magnitude / math.max(h, 1e-4)
		return if v.Magnitude > most then v.Unit * most else v
	end
	m[1] = capped(p.V0 or Vector3.zero, pts[2] - pts[1], ts[2] - ts[1])
	m[n] = capped(p.Exit, pts[n] - pts[n - 1], ts[n] - ts[n - 1])
	return m
end

local function pathAt(p: Path, t: number): Vector3
	local pts, ts = p.Points, p.Times
	if t <= ts[1] then
		return pts[1]
	end
	local m = p.Tangents
	if not m then
		m = tangents(p)
		p.Tangents = m
	end
	for i = 1, #ts - 1 do
		if t <= ts[i + 1] then
			local h = math.max(ts[i + 1] - ts[i], 1e-4)
			local u = (t - ts[i]) / h
			local u2, u3 = u * u, u * u * u
			return pts[i] * (2 * u3 - 3 * u2 + 1) + m[i] * (h * (u3 - 2 * u2 + u)) + pts[i + 1] * (-2 * u3 + 3 * u2) + m[i + 1] * (h * (u3 - u2))
		end
	end
	return pts[#pts]
end

local function startPathMove(state: string, path: Path, hand: string, planted: Vector3)
	local r = run :: Run
	stopTracks(0.06)
	r.Queued = nil
	-- (the humanoid's own jump off the same press never goes: the path is the whole of the move)
	ctx.Hum.Jump = false
	ctx.Hum.JumpHeight = 0
	enter(state, { Path = path, Hand = hand, T0 = now(), Stuck = 0 })
	r.VaultUntil = now() + P.Vault.Cooldown + path.Times[#path.Times]
	ctx.Hum.AutoRotate = false
	local total = path.Times[#path.Times]
	-- the clip whose planted hand the body has, played so it spans the move (the pack's clip is 0.5 s)
	play(if hand == "Left" then "VaultLeft" else "VaultRight", { Fade = 0.06, Speed = math.clamp(0.5 / total, 0.7, 1.6) })
	event(state, { Hand = hand, P = planted })
end

local PATH_PULL = 14 -- 1/s: how hard the drive pulls a body that drifted back onto its path
local function pathStep(dt: number)
	local r = run :: Run
	local d = r.Data
	local path: Path = d.Path
	local t = now() - d.T0
	local total = path.Times[#path.Times]
	local root = ctx.Root
	if t >= total then
		-- over: the drive lets go with the move's own way on (a vault runs on; a ledge stands)
		release(true)
		root.AssemblyLinearVelocity = path.Exit
		local q = r.Queued
		r.Queued = nil
		if r.Pending then
			r.Pending.At = now() -- (a press made over the vault counts from its end)
		end
		stop("done", { Keep = true })
		-- (a strike or a dash pressed over the top goes the moment the feet are down)
		if q and now() - q.At <= P.Vault.Buffer then
			r.Replay = { Action = if q.Action == "Dash" then "Dash" else "Attack", Kind = q.Kind, Until = now() + 0.3 }
		end
		return
	end
	-- the path's own velocity here, plus a soft pull back onto it (never a one-frame snap at the error:
	-- a frame's jitter or the humanoid's own jump impulse is taken out over a few frames)
	local h = math.max(dt, 1 / 240)
	local here = pathAt(path, t)
	local ahead = pathAt(path, t + h)
	local off = (ahead - here) / h + (here - root.Position) * PATH_PULL
	-- (something it didn't expect is in the way: it lets go rather than push through)
	if (here - root.Position).Magnitude > 1.6 then
		d.Stuck += dt
		if d.Stuck > 0.08 then
			stop("done", { Keep = true })
			return
		end
	else
		d.Stuck = 0
	end
	local v = off
	if v.Magnitude > 80 then
		v = v.Unit * 80
	end
	driveTo(v)
	local look = flat(path.Points[#path.Points] - path.Points[1])
	if look.Magnitude > 0.5 then
		face(look)
	end
end

local VAULT_PROBES = { 1.0, 2.0, 3.0 }
local LEDGE_PROBES = { 0.5, -0.4, -1.2 }
-- how far ahead the ground moves look: further at a sprint (a press a few frames early still counts)
local function groundReach(): number
	return math.max(P.Vault.Reach, horizontalSpeed() * P.Vault.ReachTime)
end
-- the thing ahead of the body at its knees: something low enough to vault? Returns the path, the
-- hand, where the hand plants - or nil
local function vaultPath(look: Vector3): (Path?, string?, Vector3?)
	local V = P.Vault
	local root = ctx.Root
	local floorHit = floorBelow(root.Position, 4.5)
	if not floorHit then
		return nil
	end
	local floorY = floorHit.Position.Y
	-- its face: looked for at the knee, the hip and the waist (a railing has nothing at the knee)
	local front: RaycastResult? = nil
	for _, y in ipairs(VAULT_PROBES) do
		local hit = cast(Vector3.new(root.Position.X, floorY + y, root.Position.Z), look * groundReach())
		if hit then
			front = hit
			break
		end
	end
	if not front or math.abs(front.Normal.Y) > 0.3 or look:Dot(-flat(front.Normal)) < 0.6 then
		return nil
	end
	-- its top, just past the face (a thin wall, a railing: a little further would miss it)
	local probe = front.Position + look * 0.12
	local top = cast(Vector3.new(probe.X, floorY + V.MaxHeight + 1.6, probe.Z), Vector3.new(0, -(V.MaxHeight + 1.6), 0))
	if not top or top.Normal.Y < 0.7 then
		return nil
	end
	local topY = top.Position.Y
	local h = topY - floorY
	if h < V.MinHeight or h > V.MaxHeight then
		return nil
	end
	-- nothing above it the body would meet on the way over (a low gap, a wall behind a ledge)
	local over = cast(Vector3.new(root.Position.X, topY + 1.2, root.Position.Z), look * (front.Distance + 1.2))
	if over then
		return nil
	end
	-- how deep: along the top until it drops away
	local depth = 0.35
	local edge: Vector3? = nil
	while depth < V.MaxDepth + 0.5 do
		depth += 0.45
		local q = front.Position + look * depth
		local hit = cast(Vector3.new(q.X, topY + 0.6, q.Z), Vector3.new(0, -1.2, 0))
		if not hit or math.abs(hit.Position.Y - topY) > 0.45 then
			edge = front.Position + look * (depth - 0.225)
			break
		end
	end
	local hand = select(2, BodyState.Can(ctx.Char, "Vault")) or "Right"
	-- the root high enough that the body clears the top: the torso's lowest point in the vault clip is
	-- 1.6 under the root (the legs tuck and never collide)
	local rise = topY + 1.55 + V.Clear
	local start = root.Position
	local near = front.Position - look * 0.2
	local planted = Vector3.new(front.Position.X, topY, front.Position.Z) + look * 0.3
	-- the body comes in at the speed it has (along the way over), and the vault takes as long as that
	-- speed needs to cover it - a sprint vaults fast, a walk takes the clip's own time
	local vin = root.AssemblyLinearVelocity
	local along = math.max(Vector3.new(vin.X, 0, vin.Z):Dot(look), 0)
	local v0 = look * along
	local function span(dist: number): number
		return math.clamp(dist / math.max(along * 0.9, 1), V.MinTime, V.Time)
	end
	if not edge or depth > V.MaxDepth then
		-- deep: up onto it (a step-up vault) - land standing on the top
		local stand = Vector3.new(near.X, topY + 3, near.Z) + look * V.OnTop
		if not roomAt(stand, look) then
			return nil
		end
		local up = Vector3.new(near.X, rise, near.Z) - look * 0.15
		local over1 = Vector3.new(stand.X, rise, stand.Z)
		local T = span(Vector3.new(stand.X - start.X, 0, stand.Z - start.Z).Magnitude)
		local exit = look * math.max(Config.WalkSpeed, along * 0.75)
		return { Points = { start, up, over1, stand }, Times = { 0, T * 0.45, T * 0.78, T }, Exit = exit, V0 = v0 }, hand, planted
	end
	-- over it: across the top and down the far side
	local far = edge :: Vector3
	local land = far + look * 1.9
	local ground = cast(Vector3.new(land.X, topY + 1, land.Z), Vector3.new(0, -(h + 7), 0))
	if not ground or ground.Normal.Y < 0.6 then
		return nil
	end
	local stand = Vector3.new(land.X, ground.Position.Y + 3, land.Z)
	if not roomAt(stand, look) then
		return nil
	end
	local up = Vector3.new(near.X, rise, near.Z) - look * 0.15
	local across = Vector3.new(far.X, rise, far.Z) + look * 0.9
	local speed = math.max(along, Config.RunSpeed * 0.8)
	local T = span(Vector3.new(across.X - start.X, 0, across.Z - start.Z).Magnitude)
	return { Points = { start, up, across }, Times = { 0, T * 0.45, T }, Exit = look * speed + Vector3.new(0, -2, 0), V0 = v0 }, hand, planted
end

-- a ledge within reach above the body: up onto it
local function ledgePath(look: Vector3, reach: number?): (Path?, string?, Vector3?)
	local Lg = P.Ledge
	local root = ctx.Root
	local p = root.Position
	-- a wall ahead at the chest, the stomach or the hips (a body rising past a ledge fast - a jump, a
	-- low frame rate - has its chest over the top a frame early: its hips still find the wall)
	local wall: RaycastResult? = nil
	for _, y in ipairs(LEDGE_PROBES) do
		wall = cast(p + Vector3.new(0, y, 0), look * (reach or Lg.Reach))
		if wall then
			break
		end
	end
	if not wall or math.abs(wall.Normal.Y) > 0.35 then
		return nil
	end
	local inward = -flat(wall.Normal)
	if inward.Magnitude < 0.5 then
		return nil
	end
	-- ...whose top is within the hands' reach, with nothing above it
	local probe = wall.Position + inward * 0.5
	local top = cast(Vector3.new(probe.X, p.Y + Lg.MaxAbove + 1.2, probe.Z), Vector3.new(0, -(Lg.MaxAbove - Lg.MinAbove + 1.2), 0))
	if not top or top.Normal.Y < 0.7 then
		return nil
	end
	local topY = top.Position.Y
	local above = topY - p.Y
	if above < Lg.MinAbove or above > Lg.MaxAbove then
		return nil
	end
	if cast(Vector3.new(p.X, topY + 1.5, p.Z), inward * (wall.Distance + 1)) then
		return nil -- (the wall goes on up: it's no ledge)
	end
	-- somewhere to stand up there: the top goes on at least a body's depth (a lintel, a thin wall's top
	-- is no ledge to stand on - the climb goes over those instead), and the body stands on it, not
	-- hanging off its far edge
	local deep = 0
	while deep < 1.35 do
		local q = wall.Position + inward * (deep + 0.3)
		local under = cast(Vector3.new(q.X, topY + 0.5, q.Z), Vector3.new(0, -1, 0))
		if not under or math.abs(under.Position.Y - topY) > 0.4 then
			break
		end
		deep += 0.3
	end
	if deep < 0.9 then
		return nil
	end
	local stand = Vector3.new(wall.Position.X, topY + 3, wall.Position.Z) + inward * math.min(1.35, deep * 0.6 + 0.2)
	if not roomAt(stand, inward) then
		return nil
	end
	local hand = select(2, BodyState.Can(ctx.Char, "LedgeVault")) or "Right"
	local hang = wall.Position - inward * 0.55
	local up = Vector3.new(hang.X, topY + 1.55 + P.Vault.Clear, hang.Z)
	local T = Lg.Time
	local vin = root.AssemblyLinearVelocity
	-- (the body's own rise carries into the pull-up: never stopped dead in the air first)
	local v0 = Vector3.new(0, math.max(vin.Y, 0), 0) + inward * math.max(Vector3.new(vin.X, 0, vin.Z):Dot(inward), 0)
	return { Points = { p, up, stand }, Times = { 0, T * 0.55, T }, Exit = inward * 4, V0 = v0 }, hand, Vector3.new(wall.Position.X, topY, wall.Position.Z)
end

-- the top of a thin wall the hands have reached with no room to stand on it: up, across, and the
-- body drops down the far side (a fence, a garden wall)
local function overTopPath(look: Vector3): (Path?, string?, Vector3?)
	local root = ctx.Root
	local p = root.Position
	local wall = cast(p, look * (P.Climb.Reach + 0.6))
	if not wall then
		-- (the wall is below the chest now: look for it lower down)
		wall = cast(p - Vector3.new(0, 1.5, 0), look * (P.Climb.Reach + 0.6))
	end
	if not wall then
		return nil
	end
	local inward = -flat(wall.Normal)
	local probe = wall.Position + inward * 0.12
	local top = cast(Vector3.new(probe.X, p.Y + 3.5, probe.Z), Vector3.new(0, -5, 0))
	if not top or top.Normal.Y < 0.7 then
		return nil
	end
	local topY = top.Position.Y
	-- how thick: along the top until it drops away (a wall any thicker is stood on, not crossed)
	local edge: Vector3? = nil
	local depth = 0.12
	while depth < 1.6 do
		depth += 0.3
		local q = wall.Position + inward * depth
		local hit = cast(Vector3.new(q.X, topY + 0.6, q.Z), Vector3.new(0, -1.2, 0))
		if not hit then
			edge = wall.Position + inward * (depth - 0.15)
			break
		end
	end
	if not edge then
		return nil
	end
	local far = edge :: Vector3
	-- something to land on down there (and nothing in the way over the top)
	local land = far + inward * 1.6
	local ground = cast(Vector3.new(land.X, topY + 1, land.Z), Vector3.new(0, -24, 0))
	if not ground or ground.Normal.Y < 0.6 or cast(Vector3.new(p.X, topY + 1.4, p.Z), inward * (wall.Distance + 2.4)) then
		return nil
	end
	local hand = select(2, BodyState.Can(ctx.Char, "LedgeVault")) or "Right"
	local rise = topY + 1.55 + P.Vault.Clear
	local up = Vector3.new(wall.Position.X, rise, wall.Position.Z) - inward * 0.4
	local across = Vector3.new(far.X, rise - 0.2, far.Z) + inward * 1.1
	local T = P.Ledge.Time
	local vin = root.AssemblyLinearVelocity
	return { Points = { p, up, across }, Times = { 0, T * 0.55, T }, Exit = inward * 6 + Vector3.new(0, -4, 0), V0 = Vector3.new(0, math.max(vin.Y, 0), 0) }, hand, Vector3.new(wall.Position.X, topY, wall.Position.Z)
end

---------------- wall climb -----------------------------------------------
local function climbWall(look: Vector3): RaycastResult?
	local root = ctx.Root
	local hit = cast(root.Position, look * P.Climb.Reach)
	if not hit or math.abs(hit.Normal.Y) > 0.35 or look:Dot(-flat(hit.Normal)) < 0.65 then
		return nil
	end
	return hit
end

-- a wall a body can climb: as wide as the body (a pole, a post, a sign is not a wall) and there
-- under its feet as well as its chest (the lintel over a doorway is not a wall to climb)
local function climbable(wall: RaycastResult): boolean
	local root = ctx.Root
	local n = flat(wall.Normal)
	local side = n:Cross(Vector3.yAxis)
	local reach = P.Climb.Reach + 0.6
	for _, o in ipairs({ side * P.Climb.HalfWidth, -side * P.Climb.HalfWidth, Vector3.new(0, -1.8, 0) }) do
		local h = cast(root.Position + o, -n * reach)
		if not h or flat(h.Normal):Dot(n) < 0.8 then
			return false
		end
	end
	return true
end

local function startClimb(wall: RaycastResult)
	stopTracks(0.1)
	enter("Climb", { Normal = flat(wall.Normal) })
	ctx.Hum.AutoRotate = false
	play("WallClimb", { Fade = 0.12 })
	face(-wall.Normal)
end

local function climbStep(dt: number)
	local r = run :: Run
	local C = P.Climb
	local root = ctx.Root
	local n: Vector3 = r.Data.Normal
	local look = -n
	r.ClimbLeft -= dt
	local wall = climbWall(look)
	-- the hands reach the top: over it (a ledge vault), or - no room up there - let go
	if not wall or not cast(root.Position + Vector3.new(0, 2.3, 0), look * (C.Reach + 0.4)) then
		local path, hand, planted = ledgePath(look)
		if not path then
			-- no room to stand up there (a fence, a thin wall): over the top and down the far side
			path, hand, planted = overTopPath(look)
		end
		if path and BodyState.Can(ctx.Char, "LedgeVault") then
			stop("done", { Keep = true, Fade = 0.08 })
			startPathMove("LedgeVault", path, hand :: string, planted :: Vector3)
		else
			stop("done", { Keep = true })
		end
		return
	end
	n = flat(wall.Normal)
	r.Data.Normal = n
	-- let go of forward (or the stamina runs out): it drops away (a gap of a frame between two keys is
	-- not letting go)
	if ctx.Hum.MoveDirection:Dot(-n) > 0.3 then
		r.Data.OffFor = 0
	else
		r.Data.OffFor = (r.Data.OffFor or 0) + dt
	end
	local held = r.Data.OffFor <= P.InputGrace
	if not held or r.ClimbLeft <= 0 then
		release(true)
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(n.X * 3, math.min(v.Y, 2), n.Z * 3)
		stop("input", { Keep = true })
		return
	end
	-- up the wall, held against it; slower as the grip tires in its last third
	local tire = math.clamp(r.ClimbLeft / (C.Stamina * 0.33), 0.45, 1)
	local speed = C.Speed * tire
	driveTo(Vector3.new(0, speed, 0) - n * 2.5)
	face(-n)
	local tr = ctx.AC:Track("WallClimb")
	if tr then
		tr:AdjustSpeed(math.clamp(speed / C.Speed, 0.4, 1.3))
	end
end

---------------- wall run ---------------------------------------------------
local function wallBeside(side: number): RaycastResult?
	local root = ctx.Root
	local hit = cast(root.Position, root.CFrame.RightVector * side * P.WallRun.Reach)
	if not hit or math.abs(hit.Normal.Y) > 0.3 then
		return nil
	end
	return hit
end

-- the wall goes on along the way the body runs (a wall run needs somewhere to run: a stub of wall, a
-- pillar, a post is jumped past, not run on)
local function wallGoesOn(hit: RaycastResult, look: Vector3, side: number): boolean
	local n = flat(hit.Normal)
	local along = flat(look - n * look:Dot(n))
	if along.Magnitude < 0.5 then
		return false
	end
	local ahead = cast(ctx.Root.Position + along * P.WallRun.MinLength, -n * (hit.Distance + 1))
	return ahead ~= nil and flat(ahead.Normal):Dot(n) > 0.8
end

local function startWallRun(hit: RaycastResult, side: number)
	local r = run :: Run
	local W = P.WallRun
	local n = flat(hit.Normal)
	local look = flat(ctx.Root.CFrame.LookVector)
	local along = flat(look - n * look:Dot(n))
	if along.Magnitude < 0.5 then
		return
	end
	local speed = math.max(horizontalSpeed(), W.Speed)
	local state = if side < 0 then "WallRunLeft" else "WallRunRight"
	stopTracks(0.08)
	enter(state, { Normal = n, Along = along, Speed = speed, Side = side, Wall = hit.Instance })
	r.LastWallRun = { Wall = hit.Instance, At = now() }
	ctx.Hum.AutoRotate = false
	play(if side < 0 then "WallRunLeft" else "WallRunRight", { Fade = 0.1 })
	face(along)
	-- the camera leans away from the wall, a touch wider at the speed
	FX.SetCameraLean(W.Lean * side)
	FX.SetCameraFov(W.Fov)
	event("WallRun")
end

local function wallRunStep(dt: number)
	local r = run :: Run
	local W = P.WallRun
	local d = r.Data
	local t = now() - r.Since
	local root = ctx.Root
	local hit = wallBeside(d.Side)
	local md = ctx.Hum.MoveDirection
	-- (steered off the wall: only once it has lasted a moment - the frame between two keys, W let go
	-- a frame before A goes down, is no decision to leave)
	if md:Dot(d.Along) < 0.2 then
		d.OffFor = (d.OffFor or 0) + dt
	else
		d.OffFor = 0
	end
	local ended = t >= W.MaxTime or not hit or (t > 0.15 and grounded()) or d.OffFor > P.InputGrace
	if not ended and cast(root.Position, d.Along * 2.2) then
		ended = true -- (a wall across its way)
	end
	if ended then
		stop("done", { Keep = true })
		return
	end
	local n = flat((hit :: RaycastResult).Normal)
	local along = flat(n:Cross(Vector3.yAxis) * (if n:Cross(Vector3.yAxis):Dot(d.Along) >= 0 then 1 else -1))
	d.Normal, d.Along = n, along
	local k = t / W.MaxTime
	local vy = W.Lift - (W.Lift + W.Sink) * k ^ 1.3
	d.Speed = math.max(Config.RunSpeed, d.Speed - dt * 3)
	driveTo(along * d.Speed + Vector3.new(0, vy, 0) - n * 3)
	face(along)
	local tr = ctx.AC:Track(if d.Side < 0 then "WallRunLeft" else "WallRunRight")
	if tr then
		tr:AdjustSpeed(math.clamp(d.Speed / W.Speed, 0.8, 1.4))
	end
end

-- a jump on the wall: THE WALL JUMP (both legs kick off it - checked now, on the press). Off a wall
-- run: on along the wall and away from it, up; off a climb: a back-flip off the wall. The flight keeps
-- its speed until it lands - or reaches a wall to run along (the chain: autoStarts). A body without
-- the legs for it just lets go of the wall
local function wallJump()
	local r = run :: Run
	local d = r.Data
	local was = r.State
	local n: Vector3 = d.Normal or Vector3.zero
	local root = ctx.Root
	local v = root.AssemblyLinearVelocity
	local WJ = P.WallJump
	if not BodyState.Can(ctx.Char, "WallJump") then
		release(true)
		root.AssemblyLinearVelocity = Vector3.new(v.X, math.min(v.Y, 0), v.Z) + n * 4
		stop("input", { Keep = true })
		api.LimbDenied()
		return
	end
	local climb = was == "Climb"
	local along: Vector3 = if climb then Vector3.zero else (d.Along or flat(root.CFrame.LookVector))
	local forward = if climb then 0 else math.max(d.Speed or 0, WJ.Forward)
	-- the body keeps the facing it had on the wall - the clips are authored that way: off a run the
	-- body spins once round in the air still headed along the wall, off a climb it back-flips away
	-- from the wall it faces. Only once the clip is through does it turn (smoothly) to where it flies
	local spin = if climb then WJ.FlipTime else WJ.SpinTime
	stop("done", { Keep = true, Fade = 0.06 })
	enter("WallJump", { Normal = n, Spin = spin, TurnVel = 0 })
	local serial = r.Serial
	ctx.Hum.AutoRotate = false
	local out = along * forward + n * (if climb then WJ.Back else WJ.Side)
	root.AssemblyLinearVelocity = out + Vector3.new(0, if climb then WJ.BackUp else WJ.Up, 0)
	root.AssemblyAngularVelocity = Vector3.zero
	ctx.LastJumpAt = now()
	r.JumpAt = now()
	-- (the wall it left can't be run again at once; another one can)
	r.LastWallRun = { Wall = d.Wall, At = now() }
	if climb then
		play("WallJumpOff", { Fade = 0.05, Speed = 0.75 / spin })
	else
		play("WallJump", { Fade = 0.05, Speed = 0.3 / spin })
	end
	FX.SetCameraFov(P.WallRun.Fov * 0.7)
	carryFlight(flat(out), out.Magnitude, serial, spin)
	event("WallJump", { N = n })
end

-- the flight off a wall: once the clip's spin / flip is through, the body turns to where it is going
-- (where it is steered, else the way it flies) - a critically damped turn, never a snap
local function wallJumpTurn(dt: number)
	local r = run :: Run
	local d = r.Data
	if now() - r.Since < (d.Spin or 0) then
		return
	end
	local want = steer()
	if want.Magnitude < 0.5 then
		local v = ctx.Root.AssemblyLinearVelocity
		want = flat(Vector3.new(v.X, 0, v.Z))
	end
	if want.Magnitude < 0.5 then
		return
	end
	local root = ctx.Root
	local look = flat(root.CFrame.LookVector)
	local cur = math.atan2(-look.X, -look.Z)
	local goal = math.atan2(-want.X, -want.Z)
	local y = (cur - goal + math.pi) % (2 * math.pi) - math.pi
	if math.abs(y) < 0.01 and math.abs(d.TurnVel or 0) < 0.05 then
		return
	end
	local step, vel = Motion.Turn(y, d.TurnVel or 0, 16, 14, math.min(dt, 1 / 20))
	d.TurnVel = vel
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, cur + step, 0)
end
---------------------------------------------------------------------------
-- starting moves from the air / the run on their own (every frame, while free)
---------------------------------------------------------------------------
local function autoStarts()
	local r = run :: Run
	local t = now()
	local jumped = math.max(r.JumpAt, ctx.LastJumpAt or -10) -- (a jump of ours, or the humanoid's own)
	local root = ctx.Root
	local look = flat(root.CFrame.LookVector)
	local md = steer()
	local air = not grounded()
	if air then
		local rising = root.AssemblyLinearVelocity.Y
		-- a ledge within the hands' reach while moving at it: up onto it
		if md.Magnitude > 0.5 and md:Dot(look) > 0.6 and t >= r.VaultUntil then
			local path, hand, planted = ledgePath(look)
			if path and BodyState.Can(ctx.Char, "LedgeVault") then
				startPathMove("LedgeVault", path, hand :: string, planted :: Vector3)
				return
			end
		end
		-- jumped at a wall, holding into it: climb (the grip lasts Stamina seconds a time in the air)
		if md.Magnitude > 0.5 and md:Dot(look) > 0.6 and t - jumped < 0.9 and rising > -8 and r.ClimbLeft > 0.15 and t - r.LastClimbEnd > P.Climb.Regrab then
			local wall = climbWall(look)
			if wall and cast(root.Position + Vector3.new(0, 2.3, 0), look * (P.Climb.Reach + 0.4)) and climbable(wall) and BodyState.Can(ctx.Char, "Climb") then
				startClimb(wall)
				return
			end
		end
		-- jumped beside a wall at a run: along it
		local W = P.WallRun
		if md.Magnitude > 0.5 and md:Dot(look) > 0.5 and horizontalSpeed() >= W.MinSpeed and rising > -20 and t - jumped < 1.2 then
			for _, side in ipairs({ -1, 1 }) do
				local hit = wallBeside(side)
				if hit and math.abs(look:Dot(hit.Normal)) < 0.55 and cast(root.Position + Vector3.new(0, 2, 0), root.CFrame.RightVector * side * (W.Reach + 0.3)) and wallGoesOn(hit, look, side) then
					local lw = r.LastWallRun
					if not (lw.Wall == hit.Instance and t - lw.At < W.Cooldown) and heightAboveFloor() >= W.MinHeight and BodyState.Can(ctx.Char, "WallRun") then
						startWallRun(hit, side)
						return
					end
				end
			end
		end
	elseif md.Magnitude > 0.5 and md:Dot(look) > 0.6 and horizontalSpeed() >= P.Vault.AutoSpeed and t >= r.VaultUntil then
		-- running flat out into something low: over it without breaking stride
		local path, hand, planted = vaultPath(look)
		if path and BodyState.Can(ctx.Char, "Vault") then
			startPathMove("Vault", path, hand :: string, planted :: Vector3)
		end
	end
end

---------------------------------------------------------------------------
-- the landing roll's body
---------------------------------------------------------------------------
-- The roll takes the torso and the head (the only parts of this body that collide) down to the
-- floor: pressed into it on the touchdown, the physics threw the whole body up a stud for a few frames
-- and the view with it. While it rolls they collide with nothing; a box welded to the root where the
-- standing torso and head are keeps the body out of walls (nothing of it goes near the floor)
local ROLL_BOX = Vector3.new(2, 3, 1)
local function rollGuard(r: Run, on: boolean, untilT: number?)
	local g = r.RollGuard
	if on then
		if not g then
			local box = Instance.new("Part")
			box.Name = "ParkourRollBox"
			box.Size = ROLL_BOX
			box.Transparency = 1
			box.CanQuery = false
			box.CanTouch = false
			box.CastShadow = false
			box.Massless = true
			box.CFrame = ctx.Root.CFrame * CFrame.new(0, 0.5, 0)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = ctx.Root
			weld.Part1 = box
			weld.Parent = box
			local parts = {}
			for _, n in ipairs({ "Torso", "Head" }) do
				local part = ctx.Char:FindFirstChild(n)
				if part and part:IsA("BasePart") and part.CanCollide then
					part.CanCollide = false
					table.insert(parts, part)
				end
			end
			box.Parent = ctx.Char
			g = { Box = box, Parts = parts, Until = 0 }
			r.RollGuard = g
		end
		g.Until = untilT or (now() + 0.8)
	elseif g then
		r.RollGuard = nil
		g.Box:Destroy()
		for _, part in ipairs(g.Parts) do
			-- (a limb the gore took stays as it is; a ragdoll sets its own)
			if part.Parent and part:GetAttribute("GoreHidden") ~= true and ctx.Char:GetAttribute("Ragdolled") ~= true then
				part.CanCollide = true
			end
		end
	end
end

---------------------------------------------------------------------------
-- the API CombatClient drives
---------------------------------------------------------------------------
-- api = { Request(kind, payload), CharList() -> {Instance}, Bodies() -> {Vector3}, InputBlocked(),
--         LimbDenied(), TurnFree() -> boolean }
function Parkour.Init(a: any)
	api = a
end

function Parkour.Setup(c: any)
	Parkour.Teardown()
	ctx = c
	run = {
		State = nil, Since = 0, Serial = 0, Tracks = {}, Data = {}, Watch = nil, AirJumpUsed = false,
		ClimbLeft = P.Climb.Stamina, LastGrounded = now(), LastWallRun = { Wall = nil, At = 0 }, LastClimbEnd = 0,
		LeapUntil = 0, SlideUntil = 0, VaultUntil = 0, PrevVy = 0, WasAir = false, JumpAt = -10, Momentum = nil,
		Cam = 0, CamWant = 0, Drive = nil, DriveAtt = nil, CrouchHeld = false, SentState = nil,
	}
	local r = run :: Run
	-- the body is watched from the first frame: a limb lost mid-move is answered at once
	r.Watch = BodyState.Watch(c.Char, function(new)
		if run == r then
			reevaluate(new)
		end
	end)
	FX.ResetCameraFeel(c.Hum)
end

function Parkour.Teardown()
	local r = run
	if not r then
		return
	end
	if ctx and ctx.Char.Parent then
		stop("hit")
	end
	if r.Watch then
		r.Watch.Disconnect()
	end
	if ctx then
		rollGuard(r, false)
	end
	if r.Drive then
		r.Drive:Destroy()
	end
	if r.DriveAtt then
		r.DriveAtt:Destroy()
	end
	if ctx then
		MovementFX.SetLocal(ctx.Char, nil)
		FX.ResetCameraFeel(ctx.Hum)
	end
	run = nil
	ctx = nil
end

function Parkour.Active(): string?
	return run and run.State or nil
end

-- the moves own the legs' clips (no walk, run, jump or fall under them)
function Parkour.OwnsLocomotion(): boolean
	local r = run
	if not r then
		return false
	end
	if r.State ~= nil then
		return true
	end
	-- (the double jump's and the landing roll's clips play out over the fall clip)
	return ctx.AC:IsPlaying("DoubleJump") or ctx.AC:IsPlaying("LandRoll")
end

-- the moves that turn the body themselves (shift lock leaves it alone)
function Parkour.OwnsFacing(): boolean
	local s = run and run.State
	return s ~= nil and (HANGING[s] == true or s == "Slide" or s == "WallJump")
end

-- the walk speed the move wants (nil: the fight's own)
function Parkour.WalkSpeed(): number?
	local r = run
	local s = r and r.State
	if not s then
		return nil
	end
	if s == "Crouch" then
		return P.Crouch.Speed
	elseif s == "Crawl" then
		return P.Crawl.Speed * ((r :: Run).Data.Scale or 1)
	elseif HANGING[s] or s == "Slide" then
		return 0
	end
	return nil
end

-- the humanoid's own jump (nil: the fight's own): off in every move - the jump press is the move's
function Parkour.JumpHeight(): number?
	local r = run
	if not r then
		return nil
	end
	if r.State ~= nil then
		return 0
	end
	-- a low thing right ahead while moving at it: the jump press vaults it instead of jumping (or,
	-- chest to head high, pulls up onto it)
	if r.Data.VaultReady or r.Data.LedgeReady then
		return 0
	end
	return nil
end

-- a strike, a dash or a guard asks first. kind: "Attack" | "AirAttack" | "Dash" | "Block"
function Parkour.BeforeAction(kind: string, arg: string?): boolean
	local r = run
	if not r or not r.State then
		return true
	end
	local s = r.State :: string
	local blocking = kind == "Block"
	if (s == "Vault" or s == "LedgeVault") and not blocking then
		-- the hands are on the top: kept, and thrown the moment the vault is over (a press made over a
		-- vault is never lost, and never lands mid-vault)
		r.Queued = { Action = kind, Kind = arg, At = now() }
		return false
	end
	if (s == "WallRunLeft" or s == "WallRunRight") and kind == "AirAttack" then
		-- off the wall into the strike (in the air: the Ground Smash), keeping the run's momentum - the
		-- body leaves the wall like a jump (the smash is a jump's strike)
		stop("action", { Keep = true })
		ctx.LastJumpAt = now()
		return true
	end
	if s == "Crouch" then
		stop("action") -- up into it
		return true
	elseif s == "Crawl" then
		stop("stand") -- up off the floor first (the press is spent on getting up)
		return false
	elseif s == "Slide" then
		stop("action", { Keep = true }) -- the slide ends into it
		return true
	elseif s == "Leap" or s == "WallJump" then
		if kind == "AirAttack" then
			stop("action", { Keep = true })
			return true
		end
		return false
	end
	return false -- (on a wall, over a vault: the hands are taken)
end

-- the fight took the body (a strike, a dash, a guard, a stun, a knockdown, death: any state but Idle)
function Parkour.Interrupt(_why: string?)
	local r = run
	if r and r.Momentum then
		r.Momentum = nil
	end
	if r and r.State then
		stop("hit", { Keep = true })
	elseif r and #r.Tracks > 0 then
		-- (the clips a move leaves playing with no state of its own - a landing roll, a double jump's
		-- spin - give way to it too: a dash out of a roll's first frame never tumbles under the dash)
		stopTracks(0.08)
	end
end

-- the server refused a move (its record of the body says no): it ends here too
function Parkour.Refused(state: any)
	local r = run
	if r and r.State and (state == false or state == r.State) then
		stop("refused", { Keep = true })
	end
end

-- a key: Crouch (a slide out of a run), Crawl, Leap
function Parkour.Press(action: string, down: boolean, replayed: boolean?)
	local r = run
	if not r or not ctx then
		return
	end
	-- (the key's own state: a press kept and replayed later is not the key going down again)
	if action == "Crouch" and not replayed then
		r.CrouchHeld = down
	end
	if not down or not P.Enabled then
		return
	end
	local s = r.State
	-- pressed while the fight still has the body (a strike's last frames, a dash) or over a vault: kept
	-- a moment and done the instant it's free - movement straight out of a combo, never a dead press
	if (action == "Crouch" or action == "Leap") and ((s == nil and not free()) or s == "Vault" or s == "LedgeVault") then
		r.Pending = { Action = action, At = now(), Pressed = now() }
		return
	end
	r.Pending = nil
	if action == "Crouch" then
		if s == "Crouch" then
			stop("stand")
			return
		end
		if s == "Crawl" then
			if not denied("Crouch") then
				stop("stand", { Fade = 0.3 })
				startCrouch()
			end
			return
		end
		if s ~= nil or not free() then
			return
		end
		-- running on the ground: a slide (the body that can't slide just crouches)
		if grounded() and runSpeed() >= P.Slide.MinSpeed and steer().Magnitude > 0.5 and now() >= r.SlideUntil then
			if BodyState.Can(ctx.Char, "Slide") then
				startSlide()
				return
			end
		end
		if grounded() and not denied("Crouch") then
			startCrouch()
		end
	elseif action == "Crawl" then
		if s == "Crawl" then
			stop("stand")
			return
		end
		if s == "Crouch" then
			if not denied("Crawl") then
				stop("stand", { Fade = 0.3 })
				startCrawl()
			end
			return
		end
		if s ~= nil or not free() or not grounded() then
			return
		end
		if not denied("Crawl") then
			startCrawl()
		end
	elseif action == "Leap" then
		if s == "Crouch" then
			stop("stand", { Fade = 0.12 })
			s = nil
		end
		if s ~= nil or not free() then
			return
		end
		-- off the ground (or just off it)
		if grounded() or now() - r.LastGrounded <= P.Leap.Coyote then
			leap()
		end
	end
end

-- the jump press (keyboard, gamepad and the touch button alike: Humanoid jump requests, one per press)
function Parkour.Jump()
	local r = run
	if not r or not ctx or not P.Enabled then
		return
	end
	local s = r.State
	local t = now()
	if s == "Slide" then
		if t - r.Since >= P.Slide.CancelAfter then
			slideCancel()
		end
		return
	elseif s == "Climb" or s == "WallRunLeft" or s == "WallRunRight" then
		wallJump()
		return
	elseif s == "Crawl" then
		stop("stand")
		return
	elseif s == "Crouch" then
		-- up out of the crouch and straight into the jump
		stop("stand", { Fade = 0.1 })
		if grounded() then
			ctx.Hum.JumpHeight = Config.JumpHeight
			ctx.Hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		return
	elseif s ~= nil and s ~= "Leap" and s ~= "WallJump" then
		return
	end
	if not free() then
		return
	end
	if grounded() and s == nil then
		-- at something low: over it instead of a jump; at something chest to head high: up onto it.
		-- Looked at again on the press itself (the look ahead runs 15 times a second - a sprint covers
		-- a stud and a half between two looks, the press must never fall in that gap)
		if t >= r.VaultUntil and steer():Dot(flat(ctx.Root.CFrame.LookVector)) > 0.6 then
			local look = flat(ctx.Root.CFrame.LookVector)
			local path, hand, planted = vaultPath(look)
			if path and BodyState.Can(ctx.Char, "Vault") then
				startPathMove("Vault", path, hand :: string, planted :: Vector3)
				return
			end
			if not path then
				path, hand, planted = ledgePath(look, groundReach())
				if path and BodyState.Can(ctx.Char, "LedgeVault") then
					startPathMove("LedgeVault", path, hand :: string, planted :: Vector3)
					return
				end
			end
		end
		if r.Data.VaultReady or r.Data.LedgeReady then
			-- (nothing to go over after all - or no hand to plant: the press is an ordinary jump; the look
			-- rests a moment so it can't turn the jump back off before the humanoid takes it)
			r.Data.VaultReady = false
			r.Data.LedgeReady = false
			r.Data.VaultScanAt = t + 0.25
			ctx.Hum.JumpHeight = Config.JumpHeight
			ctx.Hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		return
	end
	-- in the air: a ledge in reach is taken, else the double jump (once per time off the ground)
	local look = flat(ctx.Root.CFrame.LookVector)
	if t >= r.VaultUntil then
		local path, hand, planted = ledgePath(look)
		if path and BodyState.Can(ctx.Char, "LedgeVault") then
			startPathMove("LedgeVault", path, hand :: string, planted :: Vector3)
			return
		end
	end
	if not r.AirJumpUsed and t - r.LastGrounded >= P.DoubleJump.After then
		doubleJump()
	end
end

-- every frame (CombatClient's locomotion step, before it sets the speeds)
function Parkour.Step(dt: number)
	local r = run
	if not r or not ctx or not ctx.Alive then
		return
	end
	local t = now()
	local hum, root = ctx.Hum, ctx.Root
	local onGround = grounded()
	local vy = root.AssemblyLinearVelocity.Y
	-- A LONG FALL MEETS THE FLOOR AT A SPEED THE LEGS CAN TAKE. Hitting it at ~100 studs/s the root sinks
	-- a stud and more into the floor for a frame and the humanoid springs it back out - the body and the
	-- view bob hard on the touchdown. The last frames before it the fall is eased to Landing.Touch (a
	-- stud or two of fall - nothing to see); how hard the landing was is still read from the real speed
	-- (the roll, the dip, the dust and the blood)
	local touch = P.Landing.Touch
	-- (a stomp's own dive, a knockback, a ragdoll: not a fall - they land the way they are driven)
	if not onGround and vy < -touch and ctx.State == "Idle" and hum:GetState() == Enum.HumanoidStateType.Freefall and ctx.Char:GetAttribute("Ragdolled") ~= true then
		local hit = floorBelow(root.Position, 3 + -vy * math.max(dt, 1 / 60) * 2.5)
		if hit then
			r.ImpactVy = math.min(r.ImpactVy or 0, vy)
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(v.X, -touch, v.Z)
			vy = -touch
		end
	end
	-- landing: the air is over (the double jump, the climb's grip and the momentum come back)
	if onGround then
		if r.WasAir then
			local fall = math.max(-r.PrevVy, -(r.ImpactVy or 0))
			if r.Momentum and t - r.JumpAt > 0.12 then
				r.Momentum = nil
				Motion.Stop(root, true)
			end
			if (r.State == "Leap" or r.State == "WallJump") and t - r.JumpAt > 0.12 then
				stop("done", { Keep = true, Fade = 0.2 })
			end
			local L = P.Landing
			if fall >= L.Hard and ctx.State == "Idle" then
				local k = math.clamp((fall - L.Hard) / (L.Roll * 1.4 - L.Hard), 0, 1)
				FX.Camera(hum, "Land", nil, 0.5 + 0.5 * k)
				if fall >= L.Roll and r.State == nil and BodyState.Can(ctx.Char, "LandRoll") then
					local tr = ctx.AC:Play("LandRoll", { Fade = 0.05, Restart = true, Speed = 1.1 })
					if tr then
						rollGuard(r, true, t + math.clamp(tr.Length / 1.1, 0.3, 1.2))
					end
					if tr and not table.find(r.Tracks, "LandRoll") then
						table.insert(r.Tracks, "LandRoll")
					end
				end
				event("Land", { K = k })
			end
		end
		r.LastGrounded = t
		r.ImpactVy = nil
		r.AirJumpUsed = false
		r.ClimbLeft = P.Climb.Stamina
	end
	r.WasAir = not onGround
	r.PrevVy = vy
	-- the roll over (or taken over: a ragdoll, another clip): the body collides as it always does again
	local rg = r.RollGuard
	if rg and (t >= rg.Until or not ctx.AC:IsPlaying("LandRoll") or ctx.Char:GetAttribute("Ragdolled") == true) then
		rollGuard(r, false)
	end
	-- a strike / dash kept over a vault: thrown once the feet are down (a strike in the last inch of air
	-- would be read as an air strike)
	local rp = r.Replay
	if rp and r.State == nil and (onGround or t >= rp.Until) then
		r.Replay = nil
		task.defer(api.Replay, rp.Action, rp.Kind)
	end
	-- a movement press kept while the fight had the body
	local pend = r.Pending
	if pend and r.State == nil then
		-- (the wait counts from the moment the body is free again - a press made early in a dash still
		-- goes when the dash ends - but a press is never kept longer than MaxHold in all)
		if not free() then
			pend.At = t
		end
		if t - pend.At > P.PressBuffer or t - pend.Pressed > P.PressHold then
			r.Pending = nil
		elseif free() and (pend.Action ~= "Crouch" or onGround) then
			-- (a crouch / slide waits for the feet to be down: out of a vault it lands first)
			r.Pending = nil
			Parkour.Press(pend.Action, true, true)
		end
	end

	local s = r.State
	if s == "WallJump" then
		wallJumpTurn(dt)
	end
	-- the move itself
	if s == "Crouch" then
		if not onGround and t - r.LastGrounded > 0.25 then
			stop("done") -- (walked off an edge: a crouch doesn't hang in the air)
		else
			lowStep("Crouch", "CrouchWalk", P.Crouch.AnimNatural)
		end
	elseif s == "Crawl" then
		if not onGround and t - r.LastGrounded > 0.25 then
			stop("done")
		else
			lowStep("CrawlIdle", "Crawl", P.Crawl.AnimNatural * (r.Data.Scale or 1))
		end
	elseif s == "Slide" then
		face(r.Data.Dir)
		if not onGround and t - r.LastGrounded > 0.3 then
			stop("done", { Keep = true }) -- (off a ledge: the slide becomes a fall)
		elseif t - r.Since > P.Slide.Time + 0.3 then
			stop("done", { Keep = true }) -- (its drive was taken over by something else: never stuck in it)
		end
	elseif (s == "Leap" or s == "WallJump") and onGround and t - math.max(r.JumpAt, r.Since) > 0.35 then
		-- (a flight that never got off the ground - straight into a wall - ends where it stands)
		stop("done", { Keep = true })
	elseif s == "Vault" or s == "LedgeVault" then
		pathStep(dt)
	elseif s == "Climb" then
		climbStep(dt)
	elseif s == "WallRunLeft" or s == "WallRunRight" then
		wallRunStep(dt)
	elseif (s == nil or ((s == "WallJump" or s == "Leap") and t - r.JumpAt > 0.15)) and free() and P.Enabled then
		-- (out of a wall jump or a leap the next wall - or a ledge - is taken in the flight: the chain)
		autoStarts()
	end

	-- the vault a jump press would take (looked for while moving on the ground at something; 15 times a
	-- second is plenty: the jump press itself measures again)
	if run == r and r.State == nil and t >= (r.Data.VaultScanAt or 0) then
		r.Data.VaultScanAt = t + 1 / 15
		local ready, ledge = false, false
		if onGround and steer().Magnitude > 0.5 and free() and t >= r.VaultUntil then
			local look = flat(root.CFrame.LookVector)
			if steer():Dot(look) > 0.6 then
				ready = vaultPath(look) ~= nil
				ledge = not ready and ledgePath(look, groundReach()) ~= nil
			end
		end
		r.Data.VaultReady = ready
		r.Data.LedgeReady = ledge
	end

	-- the camera sinks with the posture (eased; back up the same way)
	local want = CAMERA[r.State or ""] or 0
	r.Cam += (want - r.Cam) * (1 - math.exp(-dt * 10))
	if math.abs(r.Cam - want) < 0.01 then
		r.Cam = want
	end
	FX.SetCameraPosture(hum, Vector3.new(0, r.Cam, 0))
end

-- (the jump requests of one press: the first one, then nothing until the button is let go)
local lastJumpReq = -1
UserInputService.JumpRequest:Connect(function()
	local t = now()
	local fresh = t - lastJumpReq > 0.12
	lastJumpReq = t
	if fresh then
		Parkour.Jump()
	end
end)

return Parkour
