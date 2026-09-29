--[[
	Traversal  (ReplicatedStorage.Combat.Traversal)
	The local fighter's traversal: the ten moves taken from the Advanced Movement System, rebuilt
	inside the fight's own body - CombatClient drives it every frame, its animation controller plays
	its clips, the fight's mover (Motion) and its state decide when it may move at all. Nothing else
	of the pack is here.

	  postures   CROUCH (the crouch key standing or walking) and CRAWL (the crawl key): the walk and
	             idle give way to the crouch / crawl clips, slower, the camera sinks with the head;
	             standing up needs the room to stand
	  slide      the crouch key while running: feet first along the run, losing speed to friction,
	             then up (or into a crouch with the key held). SLIDE CANCEL: jump out of it - a hop
	             that keeps the slide's speed
	  vault      running at something a hip-to-chest high: over it (or onto it, if it is deep),
	             one hand on it - the clip for the hand the body still has
	  wall climb jump at a wall (or run into it) taller than a vault, facing it, holding forward:
	             up it for a moment; at its top, the LEDGE VAULT pulls the body over the edge
	  wall run   in the air after a jump, going fast along a wall beside you: along it for a moment
	  double jump  jump again in the air, once each time off the ground
	  leap       the leap key on the ground: a long low dive forward

	THE BODY DECIDES (BodyState, Config.Traversal.Needs): a move the body can't do with the limbs it
	has isn't started, and a limb lost mid-move ends it on the spot - the body keeps its momentum and
	falls, or stands, never holds on with a hand it no longer has. Checked every frame, one read of the
	body (the gore stage and the limb parts), for every move and posture in progress and every one about
	to start - so no key, button or chain of moves (slide -> cancel, crouch -> slide, wall run -> jump)
	gets round it.

	THE FIGHT DECIDES (api.CanAct): a move starts only while the fighter is free (the combat state
	Idle, nothing owning the screen). Any blow, stun, guard break, knockdown or death ends every move at
	once (Cancel) and the fight takes the body; a strike, dash or guard from a posture or a slide stands
	the body up / lets the slide go first (Yield) and goes on from there.

	Built on what's there: one LinearVelocity of its own for the moves that carry the whole body
	(vault, climb, ledge, wall run), the fight's own ground mover (Motion) for the slide and the leap,
	one ray set per frame, clips cross-faded so no pose ever snaps. Everyone else sees it all through the
	body's own replicated motion and clips; the effects go to them through the server (api.Sent).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local BodyState = require(CombatFolder:WaitForChild("BodyState"))
local Motion = require(CombatFolder:WaitForChild("Motion"))

local TC = Config.Traversal
local ROOT_UP = 3 -- an R6 root's centre over its feet
local HEAD_UP = 2 -- ...and the top of its head over the centre

local Traversal = {}
Traversal.__index = Traversal

local function now(): number
	return os.clock()
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zero
end

local function yawOf(v: Vector3): number
	return math.atan2(-v.X, -v.Z)
end

-- the moves the body's hands or feet are fixed in: no strike, dash or guard out of them
local LOCKED = { Vault = true, LedgeVault = true, Climb = true }

--[[ c = { Char, Hum, Root, AC }. api:
	CanAct() -> bool         the fight lets the body move on its own
	Running() -> bool        the run is on (sprint held / toggled / broken into)
	CrouchHeld() -> bool     the crouch key is still down
	Ignore() -> { Instance } what rays pass through (the fighters)
	Fighters() -> { Vector3 } other fighters' roots (a slide or leap brakes before them)
	Jumped()                 an air move went off (the jump + M1 smash window opens with it)
	LastJump() -> number     when the body last really jumped
	Sent(kind, info?)        a move started: to the server (and through it to everyone's effects)
	Fx(kind, info?)          play a move's effect on this screen (CombatFX.Move)
	Smear(dt, strength)      blood dragged along the ground under the body (CombatBlood) ]]
function Traversal.new(c: any, api: any): any
	local self = setmetatable({
		Char = c.Char,
		Hum = c.Hum,
		Root = c.Root,
		AC = c.AC,
		Api = api,
		Mode = nil :: string?, -- Slide | Vault | LedgeVault | Climb | WallRun
		M = nil :: any, -- the move in progress
		Posture = nil :: string?, -- Crouch | Crawl
		Flourish = nil :: any, -- { Key, Track, Until } a clip over a jump (leap, double jump, the cancel hop)
		Body = nil :: any,
		Grounded = true,
		GroundAt = 0,
		LeftGroundAt = 0,
		AirJumped = false,
		AirMove = nil :: string?, -- the last move that sent the body into the air
		FallSpeed = 0, -- (the last airborne frame's speed down: what the landing is judged by)
		CameraDrop = 0,
		NextSlide = 0,
		NextLeap = 0,
		NextVault = 0,
		NextClimb = 0,
		NextWallRun = 0,
		LastWall = nil :: Instance?,
		ForwardFor = 0, -- (how long the body has pushed into the wall in front of it on the ground)
		Params = RaycastParams.new(),
		Alive = true,
	}, Traversal)
	self.Params.FilterType = Enum.RaycastFilterType.Exclude
	self.Params.RespectCanCollide = true
	self.Params.IgnoreWater = true
	return self
end

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
function Traversal:ray(from: Vector3, delta: Vector3): RaycastResult?
	return workspace:Raycast(from, delta, self.Params)
end

-- a surface that can be stood on / run along / climbed (not a body, not something loose and light)
local function solid(hit: RaycastResult?): boolean
	if not hit then
		return false
	end
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		return true
	end
	return inst:IsA("BasePart") and (inst.Anchored or inst.AssemblyMass > 200)
end

function Traversal:drive(): LinearVelocity
	local root = self.Root
	local lv = root:FindFirstChild("TraversalDrive")
	if lv and lv:IsA("LinearVelocity") then
		return lv
	end
	local a = root:FindFirstChild("TraversalAttachment")
	if not (a and a:IsA("Attachment")) then
		a = Instance.new("Attachment")
		a.Name = "TraversalAttachment"
		a.Parent = root
	end
	lv = Instance.new("LinearVelocity")
	lv.Name = "TraversalDrive"
	lv.Attachment0 = a
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 400000
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = root
	return lv
end

function Traversal:push(v: Vector3)
	local lv = self:drive()
	lv.VectorVelocity = v
	lv.Enabled = true
end

-- the whole-body drive lets go; the body keeps the velocity it was last given (or `v`)
function Traversal:letGo(v: Vector3?)
	local lv = self.Root:FindFirstChild("TraversalDrive")
	local last = if lv and lv:IsA("LinearVelocity") and lv.Enabled then lv.VectorVelocity else nil
	if lv and lv:IsA("LinearVelocity") then
		lv.Enabled = false
		lv.VectorVelocity = Vector3.zero
	end
	local keep = v or last
	if keep and self.Root.Parent then
		self.Root.AssemblyLinearVelocity = keep
	end
end

-- turn the body toward `dir` (level), quickly but never in one frame
function Traversal:face(dir: Vector3, dt: number, rate: number?)
	local d = flat(dir)
	if d.Magnitude < 0.5 then
		return
	end
	local root = self.Root
	local cur = yawOf(flat(root.CFrame.LookVector))
	local want = yawOf(d)
	local diff = (want - cur + math.pi) % (2 * math.pi) - math.pi
	local k = math.clamp(dt * (rate or 16), 0, 1)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, cur + diff * k, 0)
end

-- a clip, cross-faded in; `speed` its playback
function Traversal:play(key: string, fade: number?, speed: number?): AnimationTrack?
	return self.AC:Play(key, { Fade = fade or 0.1, Speed = speed or 1, Restart = true })
end

-- clear room over the feet to stand in (a crouch or crawl never stands up into a ceiling)
function Traversal:roomToStand(): boolean
	local root = self.Root
	local feet = root.Position - Vector3.new(0, ROOT_UP, 0)
	local up = TC.StandRoom - 0.4
	for _, off in ipairs({ Vector3.zero, root.CFrame.LookVector * 0.6, -root.CFrame.LookVector * 0.6 }) do
		if self:ray(feet + off + Vector3.new(0, 0.4, 0), Vector3.new(0, up, 0)) then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------
-- the state the fight reads
---------------------------------------------------------------------------
-- the traversal owns the legs and the body's pose right now (the walk, run, jump and fall clips stay off)
function Traversal:OwnsPose(): boolean
	return self.Mode ~= nil or self.Flourish ~= nil
end

-- the body's facing is the move's (no free turning, no shift-lock turning)
function Traversal:HoldsFacing(): boolean
	return self.Mode ~= nil
end

-- the walk speed a posture wants (nil: the fight's own)
function Traversal:WalkSpeed(): number?
	if self.Mode then
		return 0
	end
	if self.Posture == "Crouch" then
		return TC.CrouchSpeed
	elseif self.Posture == "Crawl" then
		return TC.CrawlSpeed
	end
	return nil
end

-- the jump height it wants (nil: the fight's own)
function Traversal:JumpHeight(): number?
	if self.Mode or self.Posture == "Crawl" then
		return 0
	end
	return nil
end

-- may the fight start `action` ("Attack" | "Dash" | "Block") now?
function Traversal:Allows(action: string): boolean
	if self.Mode and LOCKED[self.Mode] then
		return false
	end
	if self.Mode == "WallRun" then
		return action == "Attack" -- (off the wall into the Ground Smash; no dash or guard on a wall)
	end
	return true
end

-- the fight is about to act: postures stand, a slide lets go (keeping its speed), a wall run lets go
function Traversal:Yield(_action: string)
	if self.Mode == "Slide" then
		self:endSlide(true, true)
	elseif self.Mode == "WallRun" then
		self:endWallRun(true)
	end
	if self.Posture then
		self:setPosture(nil, 0.08, true)
	end
end

-- everything ends at once (a blow, a stun, a knockdown, death, the character going): the body keeps
-- whatever momentum it has, every clip fades out fast
function Traversal:Cancel(_reason: string?)
	local m = self.Mode
	if m == "Slide" then
		self:endSlide(true, true)
	elseif m == "WallRun" then
		self:endWallRun(true)
	elseif m == "Climb" then
		self:endClimb(nil)
	elseif m == "Vault" or m == "LedgeVault" then
		self:endVault(true)
	end
	self.Mode, self.M = nil, nil
	if self.Posture then
		self:setPosture(nil, 0.1, true)
	end
	if self.Flourish then
		if self.Flourish.Conn then
			self.Flourish.Conn:Disconnect()
		end
		self.AC:Stop(self.Flourish.Key, 0.1)
		self.Flourish = nil
	end
	self:letGo()
end

function Traversal:Destroy()
	if not self.Alive then
		return
	end
	self:Cancel("Gone")
	self.Alive = false
	self.CameraDrop = 0
	local lv = self.Root:FindFirstChild("TraversalDrive")
	if lv then
		lv:Destroy()
	end
	local a = self.Root:FindFirstChild("TraversalAttachment")
	if a then
		a:Destroy()
	end
end

---------------------------------------------------------------------------
-- postures: crouch, crawl
---------------------------------------------------------------------------
local POSTURE_CLIPS = { Crouch = { "CrouchIdle", "CrouchWalk" }, Crawl = { "CrawlIdle", "Crawl" } }

function Traversal:setPosture(p: string?, fade: number?, quick: boolean?)
	if self.Posture == p then
		return
	end
	local was = self.Posture
	if was then
		self.AC:StopMany(POSTURE_CLIPS[was], if quick then 0.08 else (fade or 0.22))
	end
	self.Posture = p
	self.PostureMoving = nil
	if p then
		local clips = POSTURE_CLIPS[p]
		self.AC:Play(clips[1], { Fade = fade or 0.2 })
	end
end

function Traversal:stepPosture(dt: number, body: any, grounded: boolean)
	local p = self.Posture
	if not p then
		return
	end
	-- the body can't hold it any more (a limb gone), or has left the ground (walked off a ledge):
	-- it stands / falls from wherever it is
	local ok = BodyState.Can(body, p)
	if not ok or not grounded then
		self:setPosture(nil, 0.2)
		return
	end
	local v = self.Root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local moving = speed > 0.6 and self.Hum.MoveDirection.Magnitude > 0.05
	local clips = POSTURE_CLIPS[p]
	if moving ~= self.PostureMoving then
		self.PostureMoving = moving
		if moving then
			self.AC:Play(clips[2], { Fade = 0.15 })
			self.AC:Stop(clips[1], 0.15)
		else
			self.AC:Play(clips[1], { Fade = 0.15 })
			self.AC:Stop(clips[2], 0.15)
		end
	end
	if moving then
		local tr = self.AC:Track(clips[2])
		if tr then
			local natural = if p == "Crouch" then TC.CrouchWalkNatural else TC.CrawlNatural
			tr:AdjustSpeed(math.clamp(speed / natural, 0.5, 2.2))
		end
	end
	-- crawling on a wound: the blood is dragged along under the body
	if p == "Crawl" and moving then
		self.Api.Smear(dt, 1)
	end
end

---------------------------------------------------------------------------
-- slide, slide cancel
---------------------------------------------------------------------------
function Traversal:startSlide(t: number, body: any): boolean
	if not BodyState.Can(body, "Slide") or t < self.NextSlide then
		return false
	end
	local root = self.Root
	local v = root.AssemblyLinearVelocity
	local hv = Vector3.new(v.X, 0, v.Z)
	local dir = if hv.Magnitude > 1 then hv.Unit else flat(root.CFrame.LookVector)
	local start = math.max(hv.Magnitude * TC.SlideBoost, TC.SlideSpeed)
	self:setPosture(nil, 0.06, true)
	Motion.Stop(root, true)
	self.Mode = "Slide"
	self.M = { T0 = t, Dir = dir, Start = start, Speed = start, Loop = false }
	self:play("SlideStart", 0.07)
	local serial
	serial = Motion.Drive(root, TC.SlideTime, function(e: number): Vector3
		local u = math.clamp(e / TC.SlideTime, 0, 1)
		local s = TC.SlideEnd + (start - TC.SlideEnd) * (1 - u) ^ 1.5
		if self.M and self.Mode == "Slide" then
			self.M.Speed = s
		end
		return dir * s
	end, {
		StopAtWalls = true,
		Ignore = self.Api.Ignore(),
		Fighters = self.Api.Fighters,
		KeepVelocity = true,
		OnEnd = function()
			if self.Mode == "Slide" and self.M and self.M.Serial == serial then
				self:endSlide(false, false)
			end
		end,
	})
	self.M.Serial = serial
	self.AirMove = nil
	self.Api.Sent("Slide", { D = dir, T = TC.SlideTime })
	self.Api.Fx("Slide", { D = dir, T = TC.SlideTime })
	return true
end

-- the slide is over: the body rises (or stays crouched with the key held); `keep`: the speed it has
-- stays on it (let go into a strike, a hop or a blow)
function Traversal:endSlide(keep: boolean, quick: boolean)
	if self.Mode ~= "Slide" then
		return
	end
	self.Mode, self.M = nil, nil
	self.NextSlide = now() + TC.SlideCooldown
	Motion.Stop(self.Root, keep)
	local fade = if quick then 0.1 else 0.25
	self.AC:StopMany({ "SlideStart", "SlideLoop" }, fade)
	if not quick and self.Api.CrouchHeld() and BodyState.Can(self.Body or BodyState.Of(self.Char), "Crouch") then
		self:setPosture("Crouch", 0.25)
	end
end

function Traversal:stepSlide(dt: number, t: number, body: any)
	local m = self.M
	if not BodyState.Can(body, "Slide") then
		self:endSlide(true, true)
		return
	end
	self:face(m.Dir, dt, 20)
	if not m.Loop then
		local st = self.AC:Track("SlideStart")
		if not st or not st.IsPlaying or st.TimePosition >= st.Length - 0.12 then
			m.Loop = true
			self:play("SlideLoop", 0.12)
		end
	end
	-- a bleeding body drags its blood along the floor as it slides
	self.Api.Smear(dt, 0.8)
	if self.Hum.FloorMaterial == Enum.Material.Air and t - m.T0 > 0.15 then
		-- (slid off an edge: it falls with its speed)
		self:endSlide(true, true)
	end
end

-- jump out of a slide: a hop that keeps the slide's speed
function Traversal:slideCancel(t: number, body: any): boolean
	if self.Mode ~= "Slide" then
		return false
	end
	if not BodyState.Can(body, "SlideCancel") then
		return false
	end
	local m = self.M
	local speed = math.max(m.Speed or 0, TC.CancelSpeed)
	local dir = m.Dir
	self:endSlide(true, true)
	Motion.Stop(self.Root, true)
	self.Root.AssemblyLinearVelocity = dir * speed + Vector3.new(0, TC.CancelUp, 0)
	self.Hum:ChangeState(Enum.HumanoidStateType.Freefall)
	self:flourish("SlideCancel", t)
	self.AirMove = "SlideCancel"
	self.LeftGroundAt = t
	self.Api.Jumped()
	self.Api.Sent("SlideCancel", { D = dir })
	self.Api.Fx("SlideCancel", { D = dir })
	return true
end

---------------------------------------------------------------------------
-- flourishes: a clip over a jump (it fades out as it ends, or on landing)
---------------------------------------------------------------------------
function Traversal:flourish(key: string, t: number, speed: number?)
	if self.Flourish and self.Flourish.Key ~= key then
		self.AC:Stop(self.Flourish.Key, 0.08)
	end
	local tr = self:play(key, 0.06, speed)
	self.Flourish = { Key = key, Track = tr, T0 = t }
end

function Traversal:stepFlourish()
	local f = self.Flourish
	if not f then
		return
	end
	local tr = f.Track
	if not tr or not tr.IsPlaying or (tr.Length > 0 and tr.TimePosition >= tr.Length - 0.14) then
		if f.Conn and f.Key ~= "Leap" then
			f.Conn:Disconnect()
		end
		self.AC:Stop(f.Key, 0.18)
		self.Flourish = nil
	end
end

---------------------------------------------------------------------------
-- double jump
---------------------------------------------------------------------------
function Traversal:doubleJump(t: number, body: any): boolean
	if self.Grounded or self.AirJumped or self.Mode then
		return false
	end
	if t - self.LeftGroundAt < TC.AirJumpAfter or not BodyState.Can(body, "DoubleJump") then
		return false
	end
	local root = self.Root
	local v = root.AssemblyLinearVelocity
	local hv = Vector3.new(v.X, 0, v.Z)
	local stick = flat(self.Hum.MoveDirection)
	if stick.Magnitude > 0.5 then
		-- (the air jump turns the drift toward the stick - a push off nothing but the body's own swing)
		local keep = math.max(hv.Magnitude, Config.RunSpeed * 0.8)
		hv = hv:Lerp(stick * keep, TC.DoubleJumpSteer)
	end
	Motion.Stop(root, true)
	root.AssemblyLinearVelocity = hv + Vector3.new(0, TC.DoubleJumpUp, 0)
	self.AirJumped = true
	self.AirMove = "DoubleJump"
	self:flourish("DoubleJump", t)
	self.Api.Jumped()
	self.Api.Sent("DoubleJump", {})
	self.Api.Fx("DoubleJump", {})
	return true
end

---------------------------------------------------------------------------
-- leap
---------------------------------------------------------------------------
function Traversal:leap(t: number, body: any): boolean
	if not self.Grounded or self.Mode or t < self.NextLeap or not BodyState.Can(body, "Leap") then
		return false
	end
	local root = self.Root
	local stick = flat(self.Hum.MoveDirection)
	local dir = if stick.Magnitude > 0.5 then stick else flat(root.CFrame.LookVector)
	self:setPosture(nil, 0.06, true)
	self.NextLeap = t + TC.LeapCooldown
	root.CFrame = CFrame.lookAt(root.Position, root.Position + dir)
	self:flourish("Leap", t)
	local mine = self.Flourish
	local pushed = false
	local function push()
		-- (only this leap's own wind-up pushes: a leap cut short - struck, a strike thrown out of it -
		-- never goes off late)
		if pushed or not self.Alive or not root.Parent or self.Flourish ~= mine then
			return
		end
		pushed = true
		-- (the body might have been struck or lost its legs in the wind-up: the push needs both)
		if not BodyState.Can(BodyState.Of(self.Char), "Leap") or not self.Api.CanAct() then
			if self.Flourish and self.Flourish.Key == "Leap" then
				self.AC:Stop("Leap", 0.12)
				self.Flourish = nil
			end
			return
		end
		local run = math.max(Config.RunSpeed, Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude)
		root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, TC.LeapUp, root.AssemblyLinearVelocity.Z)
		self.Hum:ChangeState(Enum.HumanoidStateType.Freefall)
		Motion.Drive(root, TC.LeapPush, function(e: number): Vector3
			local u = math.clamp(e / TC.LeapPush, 0, 1)
			return dir * (run + (TC.LeapSpeed - run) * (1 - u * u))
		end, { StopAtWalls = true, Ignore = self.Api.Ignore(), Fighters = self.Api.Fighters, KeepVelocity = true })
		self.AirMove = "Leap"
		self.LeftGroundAt = now()
		self.Api.Jumped()
		self.Api.Sent("Leap", { D = dir })
		self.Api.Fx("Leap", { D = dir })
	end
	-- the push lands on the clip's own push-off frame (its "Velocity" marker)
	local tr = self.Flourish and self.Flourish.Track
	if tr then
		local conn
		conn = tr:GetMarkerReachedSignal("Velocity"):Connect(function()
			conn:Disconnect()
			push()
		end)
		self.Flourish.Conn = conn
	end
	task.delay(0.09, push) -- (a marker that never fires still pushes, a hair later)
	return true
end

---------------------------------------------------------------------------
-- vault (running over / onto something hip to chest high)
---------------------------------------------------------------------------
local function bezier(a: Vector3, b: Vector3, c: Vector3, u: number): Vector3
	local v = 1 - u
	return a * (v * v) + b * (2 * v * u) + c * (u * u)
end

-- is the body's column (feet to head) clear along a..b? (feet offset `fl` over the path's own feet)
function Traversal:clearPath(a: Vector3, b: Vector3, skipFeet: boolean?): boolean
	local d = b - a
	if d.Magnitude < 1e-3 then
		return true
	end
	for _, h in ipairs({ HEAD_UP - 0.2, 0.2 }) do
		if self:ray(a + Vector3.new(0, h, 0), d) then
			return false
		end
	end
	if not skipFeet and self:ray(a - Vector3.new(0, ROOT_UP - 0.35, 0), d) then
		return false
	end
	return true
end

function Traversal:tryVault(t: number, body: any): boolean
	if self.Posture or t < self.NextVault then
		return false
	end
	local hum, root = self.Hum, self.Root
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local look = flat(root.CFrame.LookVector)
	local stick = flat(hum.MoveDirection)
	if speed < Config.WalkSpeed * 0.75 or stick.Magnitude < 0.5 or stick:Dot(look) < 0.7 then
		return false
	end
	local feet = root.Position.Y - ROOT_UP
	-- something in front at knee height, standing up like a wall
	local knee = Vector3.new(root.Position.X, feet + 1.1, root.Position.Z)
	local front = self:ray(knee, look * TC.VaultReach)
	if not (front and solid(front) and math.abs(front.Normal.Y) < 0.3) then
		return false
	end
	-- its top: between VaultLow and VaultHigh over the feet
	local probe = front.Position + look * 0.45
	local top = self:ray(Vector3.new(probe.X, feet + TC.VaultHigh + 0.6, probe.Z), Vector3.new(0, -(TC.VaultHigh + 0.6 - 0.5), 0))
	if not (top and top.Normal.Y > 0.6) then
		return false
	end
	local h = top.Position.Y - feet
	if h < TC.VaultLow or h > TC.VaultHigh then
		return false
	end
	-- nothing standing on top of it at the height the body goes over (a wall taller than a vault is
	-- the climb's)
	local over = top.Position.Y + TC.VaultClear
	if self:ray(Vector3.new(root.Position.X, over + ROOT_UP - 0.2, root.Position.Z), look * (front.Distance + 1.2)) then
		return false
	end
	local ok, hand = BodyState.Can(body, "Vault")
	if not ok then
		return false
	end
	-- how deep: find its far edge (over it) or land on it (onto it)
	local depth = nil
	for d = 0.9, TC.VaultDepth + 0.5, 0.45 do
		local p = front.Position + look * d
		local down = self:ray(Vector3.new(p.X, over + 0.3, p.Z), Vector3.new(0, -1.2, 0))
		if not (down and math.abs(down.Position.Y - top.Position.Y) < 0.6) then
			depth = d
			break
		end
	end
	local start = root.Position
	local land: Vector3
	if depth and depth <= TC.VaultDepth then
		-- over: the far side's ground (it may be lower - the body drops the rest)
		local p = front.Position + look * (depth + 1.6)
		local g = self:ray(Vector3.new(p.X, over + 1, p.Z), Vector3.new(0, -(over + 1 - feet + 8), 0))
		if not (g and g.Normal.Y > 0.6) then
			return false
		end
		land = Vector3.new(p.X, math.max(g.Position.Y, feet - 6) + ROOT_UP, p.Z)
	else
		-- onto: a step up onto its top
		local p = front.Position + look * 1.4
		land = Vector3.new(p.X, top.Position.Y + ROOT_UP, p.Z)
	end
	-- the arc: up to clear the top, over, down to the landing - clear all the way (never through anything)
	local peak = Vector3.new((start.X + land.X) * 0.5, over + ROOT_UP + 0.4, (start.Z + land.Z) * 0.5)
	local ctrl = peak * 2 - (start + land) * 0.5
	local last = start
	for i = 1, 6 do
		local p = bezier(start, ctrl, land, i / 6)
		if not self:clearPath(last, p, i <= 3) then
			return false
		end
		last = p
	end
	-- room to stand where it lands
	if self:ray(land - Vector3.new(0, ROOT_UP - 0.3, 0), Vector3.new(0, TC.StandRoom - 0.5, 0)) then
		return false
	end
	Motion.Stop(root, true)
	self.Mode = "Vault"
	local clip = if hand == "Left" then "VaultLeftHand" else "VaultRightHand"
	self.M = { T0 = t, From = start, Ctrl = ctrl, To = land, Dur = TC.VaultTime * math.clamp((land - start).Magnitude / 7, 0.8, 1.25), Hand = hand, Clip = clip, Dir = look, Exit = flat(land - start) * math.max(speed, Config.WalkSpeed) }
	self:play(clip, 0.06, 0.5 / self.M.Dur)
	self.NextVault = t + TC.VaultCooldown
	self.Api.Sent("Vault", { D = look, H = hand })
	self.Api.Fx("Vault", { D = look })
	return true
end

function Traversal:stepVault(dt: number, t: number, body: any)
	local m = self.M
	-- the hand it is done on is gone: it lets go right there and falls (never held up by nothing)
	local handOk = if m.Hand == "Left" then body.HasLeftArm else body.HasRightArm
	if not handOk or body.Legs < 2 then
		self:endVault(true)
		return
	end
	local u = math.clamp((t - m.T0) / m.Dur, 0, 1)
	local root = self.Root
	if u >= 1 then
		self:endVault(false)
		return
	end
	local ahead = math.min(1, u + math.max(dt, 1 / 60) / m.Dur)
	local target = bezier(m.From, m.Ctrl, m.To, ahead)
	local vel = (target - root.Position) / math.max(dt, 1 / 60)
	if vel.Magnitude > 90 then
		vel = vel.Unit * 90
	end
	self:push(vel)
	self:face(m.Dir, dt, 18)
	-- (stuck on something the rays missed: let go rather than grind into it)
	if (target - root.Position).Magnitude > 3 and t - m.T0 > 0.08 then
		self:endVault(true)
	end
end

function Traversal:endVault(broke: boolean)
	local m = self.M
	local mode = self.Mode
	if mode ~= "Vault" and mode ~= "LedgeVault" then
		return
	end
	self.Mode, self.M = nil, nil
	if m then
		self.AC:Stop(m.Clip, if broke then 0.1 else 0.2)
	end
	if broke then
		self:letGo()
	else
		self:letGo(if m and m.Exit then m.Exit + Vector3.new(0, -2, 0) else nil)
	end
end

---------------------------------------------------------------------------
-- wall climb, ledge vault
---------------------------------------------------------------------------
function Traversal:wallAhead(): RaycastResult?
	local root = self.Root
	local look = flat(root.CFrame.LookVector)
	local hit = self:ray(root.Position, look * TC.ClimbReach)
	if hit and solid(hit) and math.abs(hit.Normal.Y) < 0.25 and look:Dot(-hit.Normal) > 0.75 then
		return hit
	end
	return nil
end

function Traversal:tryClimb(t: number, dt: number, body: any, grounded: boolean): boolean
	if self.Posture or t < self.NextClimb then
		return false
	end
	local hum, root = self.Hum, self.Root
	local stick = flat(hum.MoveDirection)
	local wall = self:wallAhead()
	if not wall or stick:Dot(-wall.Normal) < 0.7 then
		self.ForwardFor = 0
		return false
	end
	-- taller than a vault: the wall still stands at the top of a vault's reach
	local feet = root.Position.Y - ROOT_UP
	local high = self:ray(Vector3.new(root.Position.X, feet + TC.VaultHigh + 0.8, root.Position.Z), -wall.Normal * (TC.ClimbReach + 0.4))
	if not (high and solid(high)) then
		return false
	end
	-- on the ground a body has to be running into it a moment (walking up to a wall in a fight never
	-- starts a climb); in the air, jumping at it is enough
	if grounded then
		if not self.Api.Running() then
			self.ForwardFor = 0
			return false
		end
		self.ForwardFor += dt
		if self.ForwardFor < 0.12 then
			return false
		end
	elseif root.AssemblyLinearVelocity.Y < -22 then
		return false -- (falling fast past it: no grab)
	end
	if not BodyState.Can(body, "Climb") then
		return false
	end
	self.ForwardFor = 0
	Motion.Stop(root, true)
	self.Mode = "Climb"
	self.M = { T0 = t, Normal = wall.Normal, Wall = wall.Instance }
	self:setPosture(nil, 0.06, true)
	self.AC:StopMany({ "Fall", "Jump" }, 0.1)
	self:play("WallClimb", 0.12)
	self.Api.Sent("Climb", {})
	return true
end

-- let go of the wall: `v` the velocity it leaves with (default: what it has)
function Traversal:endClimb(v: Vector3?)
	if self.Mode ~= "Climb" then
		return
	end
	self.Mode, self.M = nil, nil
	self.NextClimb = now() + 0.45
	self.AC:Stop("WallClimb", 0.15)
	self:letGo(v)
end

function Traversal:stepClimb(dt: number, t: number, body: any)
	local m = self.M
	local root = self.Root
	-- an arm or leg lost on the wall: the grip is gone - it falls with the speed it had
	if not BodyState.Can(body, "Climb") then
		self:endClimb(nil)
		return
	end
	local wall = self:wallAhead()
	local stick = flat(self.Hum.MoveDirection)
	local n = if wall then wall.Normal else m.Normal
	-- the top: the wall ends below the head - pull up over the ledge (or let go if there's no room)
	local headWall = self:ray(root.Position + Vector3.new(0, HEAD_UP - 0.3, 0), -n * (TC.ClimbReach + 0.3))
	if not headWall then
		if not self:ledge(t, body, n) then
			self:endClimb(-n * 6 + Vector3.new(0, 10, 0))
		end
		return
	end
	-- the grip gives (held too long), the stick lets go of the wall, or a ceiling: it slides off
	local ceiling = self:ray(root.Position + Vector3.new(0, HEAD_UP - 0.4, 0), Vector3.new(0, 1.2, 0))
	if t - m.T0 > TC.ClimbTime or stick:Dot(-n) < 0.35 or ceiling or not wall then
		self:endClimb(n * 3 + Vector3.new(0, -4, 0))
		return
	end
	m.Normal = n
	-- up the wall, pressed to it (the last stretch of the grip slows)
	local grip = 1 - math.clamp((t - m.T0 - (TC.ClimbTime - 0.35)) / 0.35, 0, 1) * 0.6
	local gap = wall.Distance - 1.05
	self:push(Vector3.new(0, TC.ClimbSpeed * grip, 0) - n * math.clamp(gap * 10, -6, 6))
	self:face(-n, dt, 22)
	local tr = self.AC:Track("WallClimb")
	if tr then
		tr:AdjustSpeed(math.clamp(TC.ClimbSpeed * grip / 8, 0.6, 2))
	end
end

-- the ledge vault: over the top edge onto whatever it holds up
function Traversal:ledge(t: number, body: any, n: Vector3): boolean
	local ok, hand = BodyState.Can(body, "LedgeVault")
	if not ok then
		return false
	end
	local root = self.Root
	local into = -n
	local probe = root.Position + into * 1.4 + Vector3.new(0, HEAD_UP + 1.6, 0)
	local top = self:ray(probe, Vector3.new(0, -(HEAD_UP + 3.4), 0))
	if not (top and top.Normal.Y > 0.6) then
		return false
	end
	local land = Vector3.new(top.Position.X, top.Position.Y + ROOT_UP, top.Position.Z) + into * 0.6
	if land.Y - root.Position.Y > 5.5 then
		return false
	end
	-- room to stand up there, and the way over the edge clear
	if self:ray(land - Vector3.new(0, ROOT_UP - 0.3, 0), Vector3.new(0, TC.StandRoom - 0.5, 0)) then
		return false
	end
	local up = Vector3.new(root.Position.X, land.Y + 0.4, root.Position.Z)
	if self:ray(root.Position + Vector3.new(0, HEAD_UP - 0.2, 0), up - root.Position) or not self:clearPath(up, land, true) then
		return false
	end
	self.AC:Stop("WallClimb", 0.1)
	self.Mode = "LedgeVault"
	local clip = if hand == "Left" then "VaultLeftHand" else "VaultRightHand"
	local ctrl = Vector3.new(root.Position.X, land.Y + 0.9, root.Position.Z)
	self.M = { T0 = t, From = root.Position, Ctrl = ctrl, To = land, Dur = TC.LedgeTime, Hand = hand, Clip = clip, Dir = into, Exit = into * 6 }
	self:play(clip, 0.06, 0.5 / TC.LedgeTime * 0.8)
	self.Api.Sent("LedgeVault", { D = into, H = hand })
	return true
end

function Traversal:stepLedgeVault(dt: number, t: number, body: any)
	self:stepVault(dt, t, body)
end

---------------------------------------------------------------------------
-- wall run
---------------------------------------------------------------------------
function Traversal:sideWall(side: number): RaycastResult?
	local root = self.Root
	local right = flat(root.CFrame.RightVector)
	local hit = self:ray(root.Position, right * side * TC.WallRunReach)
	if hit and solid(hit) and math.abs(hit.Normal.Y) < 0.25 then
		return hit
	end
	return nil
end

function Traversal:tryWallRun(t: number, body: any): boolean
	if self.Posture or t < self.NextWallRun or self.Grounded then
		return false
	end
	local root = self.Root
	local v = root.AssemblyLinearVelocity
	local hv = Vector3.new(v.X, 0, v.Z)
	local stick = flat(self.Hum.MoveDirection)
	-- only out of a real jump (not a fall off an edge), going fast, pushing on
	if hv.Magnitude < TC.WallRunFrom or stick:Dot(hv.Unit) < 0.5 or t - self.Api.LastJump() > 1.4 then
		return false
	end
	if v.Y < -30 then
		return false
	end
	local best, side = nil, 0
	for _, s in ipairs({ -1, 1 }) do
		local h = self:sideWall(s)
		if h and (not best or h.Distance < best.Distance) then
			best, side = h, s
		end
	end
	if not best then
		return false
	end
	local n = best.Normal
	if math.abs(hv.Unit:Dot(n)) > 0.55 then
		return false -- (running into it, not along it)
	end
	-- tall enough to run on: it still stands beside the head
	if not self:ray(root.Position + Vector3.new(0, HEAD_UP - 0.2, 0), -n * (TC.WallRunReach + 0.3)) then
		return false
	end
	if best.Instance == self.LastWall and t < self.NextWallRun + 0.3 then
		return false
	end
	if not BodyState.Can(body, "WallRun") then
		return false
	end
	local along = hv - n * hv:Dot(n)
	if along.Magnitude < 1 then
		return false
	end
	Motion.Stop(root, true)
	self.Mode = "WallRun"
	local key = if side < 0 then "WallRunLeft" else "WallRunRight"
	self.M = { T0 = t, Normal = n, Dir = along.Unit, Speed = math.max(along.Magnitude, TC.WallRunSpeed), Vy = TC.WallRunLift, Key = key, Wall = best.Instance, Side = side }
	self.AC:StopMany({ "Fall", "Jump" }, 0.1)
	if self.Flourish then
		self.AC:Stop(self.Flourish.Key, 0.1)
		self.Flourish = nil
	end
	self:play(key, 0.12)
	self.AirJumped = false -- (the wall gives the legs something to push off again)
	self.Api.Sent("WallRun", { D = self.M.Dir, S = side })
	return true
end

-- off the wall: `keep` the speed it has; it doesn't stick to the same wall straight away
function Traversal:endWallRun(_keep: boolean)
	if self.Mode ~= "WallRun" then
		return
	end
	local m = self.M
	self.Mode, self.M = nil, nil
	self.NextWallRun = now() + 0.35
	self.LastWall = m and m.Wall
	self.AC:Stop(m and m.Key or "WallRunLeft", 0.18)
	local v = if m then m.Dir * m.Speed + Vector3.new(0, m.Vy, 0) + m.Normal * 4 else nil
	self:letGo(v)
	self.AirMove = "WallRun"
	self.LeftGroundAt = now() - TC.AirJumpAfter -- (the air jump is there at once off a wall)
	self.Api.Jumped()
end

function Traversal:stepWallRun(dt: number, t: number, body: any)
	local m = self.M
	local root = self.Root
	-- a leg lost on the wall: it can't run on - off it with the speed it had
	if not BodyState.Can(body, "WallRun") then
		self:endWallRun(true)
		return
	end
	local wall = self:sideWall(m.Side)
	local stick = flat(self.Hum.MoveDirection)
	local ahead = self:ray(root.Position, m.Dir * 2.2)
	if not wall or ahead or self.Grounded or t - m.T0 > TC.WallRunTime or stick.Magnitude < 0.2 or stick:Dot(m.Normal) > 0.55 then
		self:endWallRun(true)
		return
	end
	local n = wall.Normal
	m.Normal = n
	local d = m.Dir - n * m.Dir:Dot(n)
	if d.Magnitude > 0.1 then
		m.Dir = d.Unit
	end
	m.Vy -= workspace.Gravity * TC.WallRunSag * dt
	m.Speed = math.max(TC.WallRunFrom, m.Speed - 4 * dt)
	local gap = wall.Distance - TC.WallRunGap
	self:push(m.Dir * m.Speed + Vector3.new(0, m.Vy, 0) - n * math.clamp(gap * 8, -8, 8))
	self:face(m.Dir, dt, 18)
end

---------------------------------------------------------------------------
-- landing
---------------------------------------------------------------------------
function Traversal:landed(t: number)
	local fell = self.FallSpeed
	local from = self.AirMove
	self.AirMove = nil
	-- (the clip over the jump ends as the feet touch - a leap still winding up on the ground is its own)
	local f = self.Flourish
	if f and (f.Key ~= "Leap" or t - f.T0 > 0.25) then
		if f.Conn then
			f.Conn:Disconnect()
		end
		self.AC:Stop(f.Key, 0.16)
		self.Flourish = nil
	end
	if from and fell >= 22 then
		self.Api.Fx("Land", { Speed = fell, Hard = fell >= TC.HardLanding })
		self.Api.Sent("Land", { S = math.floor(fell) })
	end
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------
-- action: "Crouch" | "Crawl" | "Leap" | "Jump". Every press asks the fight and the body first.
function Traversal:Press(action: string): boolean
	if not self.Alive then
		return false
	end
	local t = now()
	local body = BodyState.Of(self.Char)
	self.Body = body
	if action == "Jump" then
		if self.Mode == "Slide" then
			return self:slideCancel(t, body)
		elseif self.Mode == "Climb" then
			local n = self.M.Normal
			self:endClimb(n * 5 + Vector3.new(0, 2, 0)) -- (let go: just off the wall, no kick off it)
			return true
		elseif self.Mode == "WallRun" then
			self:endWallRun(true)
			if self.Api.CanAct() then
				self:doubleJump(t, body)
			end
			return true
		elseif self.Posture == "Crawl" then
			if self:roomToStand() then
				self:setPosture(nil, 0.2)
			end
			return true
		elseif self.Posture == "Crouch" then
			if self:roomToStand() then
				self:setPosture(nil, 0.12) -- (the jump itself is the humanoid's)
			end
			return false
		end
		if not self.Grounded and self.Api.CanAct() then
			return self:doubleJump(t, body)
		end
		return false
	end
	if not self.Api.CanAct() or self.Mode then
		return false
	end
	if action == "Crouch" then
		if self.Posture == "Crouch" then
			if self:roomToStand() then
				self:setPosture(nil, 0.2)
			end
			return true
		end
		-- running: the crouch key is the slide
		local v = self.Root.AssemblyLinearVelocity
		local speed = Vector3.new(v.X, 0, v.Z).Magnitude
		if self.Grounded and speed >= TC.SlideFrom and self.Hum.MoveDirection.Magnitude > 0.3 and self.Posture == nil then
			return self:startSlide(t, body)
		end
		if self.Grounded and BodyState.Can(body, "Crouch") then
			self:setPosture("Crouch", if self.Posture == "Crawl" then 0.3 else 0.2)
			return true
		end
		return false
	elseif action == "Crawl" then
		if self.Posture == "Crawl" then
			if self:roomToStand() then
				self:setPosture(nil, 0.3)
			end
			return true
		end
		if self.Grounded and BodyState.Can(body, "Crawl") then
			self:setPosture("Crawl", 0.3)
			return true
		end
		return false
	elseif action == "Leap" then
		return self:leap(t, body)
	end
	return false
end

-- the server refused a move this screen started (it never matched the body the server knows):
-- whatever is running ends
function Traversal:Denied(_kind: string?)
	self:Cancel("Denied")
end

---------------------------------------------------------------------------
-- every frame
---------------------------------------------------------------------------
function Traversal:Step(dt: number)
	if not self.Alive then
		return
	end
	local hum, root = self.Hum, self.Root
	if not root.Parent or hum.Health <= 0 then
		self:Cancel("Dead")
		self:easeCamera(dt)
		return
	end
	local t = now()
	self.Params.FilterDescendantsInstances = self.Api.Ignore()
	local body = BodyState.Of(self.Char)
	self.Body = body
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	if grounded and not self.Grounded then
		self:landed(t)
	elseif not grounded and self.Grounded then
		self.LeftGroundAt = t
	end
	if grounded then
		self.AirJumped = false
		self.GroundAt = t
		self.FallSpeed = 0
	else
		self.FallSpeed = math.max(0, -root.AssemblyLinearVelocity.Y)
	end
	self.Grounded = grounded

	-- the fight took the body (a blow, a stun, a knockdown): nothing of the traversal survives it
	local free = self.Api.CanAct()
	if not free and (self.Mode or self.Posture) then
		self:Cancel("Fight")
	end

	local mode = self.Mode
	if mode == "Slide" then
		self:stepSlide(dt, t, body)
	elseif mode == "Vault" then
		self:stepVault(dt, t, body)
	elseif mode == "LedgeVault" then
		self:stepLedgeVault(dt, t, body)
	elseif mode == "Climb" then
		self:stepClimb(dt, t, body)
	elseif mode == "WallRun" then
		self:stepWallRun(dt, t, body)
	end
	if self.Posture then
		self:stepPosture(dt, body, grounded)
	end
	self:stepFlourish()

	-- the moves that start by themselves
	if free and not self.Mode then
		if grounded then
			if not self:tryVault(t, body) then
				self:tryClimb(t, dt, body, true)
			end
		else
			if not self:tryWallRun(t, body) then
				self:tryClimb(t, dt, body, false)
			end
		end
	end

	self:easeCamera(dt)
end

-- the camera sinks with the head in a posture and comes back up out of it (eased: never a jump cut,
-- never left down - a body that dies or is knocked down in a crouch brings it back up too)
function Traversal:easeCamera(dt: number)
	local want = if self.Posture == "Crouch" then TC.CrouchCamera elseif self.Posture == "Crawl" then TC.CrawlCamera else 0
	self.CameraDrop += (want - self.CameraDrop) * math.clamp(dt * 9, 0, 1)
	if math.abs(self.CameraDrop - want) < 0.01 then
		self.CameraDrop = want
	end
end

return Traversal
