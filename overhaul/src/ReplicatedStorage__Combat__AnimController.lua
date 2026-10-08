--[[
	AnimController  (ReplicatedStorage.Combat.AnimController)
	One animation owner per character. Tracks are loaded once from CombatConfig.Anim and cached,
	played with their configured priority, and cleaned up with the character. Every combat and
	locomotion clip on a character goes through here, so nothing loads duplicate tracks or leaves
	stale ones behind.

	Player characters: the owning client drives its own controller (the Animator replicates the
	tracks to everyone). NPCs: the server drives theirs.

	  local ac = AnimController.get(humanoid)
	  ac:Play("Swing1", { Fade = 0.08, Speed = 1.1 })
	  ac:PlayFresh("HitLeft", { Fade = 0.06 })   -- restart a clip that is already playing without a
	                                             -- snap: a second copy fades in from the current pose
	  ac:Stop("Swing1", 0.15)

	RETIMED CLIPS (Config.Anim[key].Retime): a clip whose own keys pop somewhere is played on its
	retimed timeline - its speed is steered every frame so its clip time follows Config.ClipTau of
	the time it has played (at the speed it was started with), through the part that is slowed down
	and the part that pays for it. A clip somebody else froze (a hit-stop, a hang: speed under 0.05)
	is left alone until it runs again; past the retimed part it plays at its own speed as always.
]]

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local AnimController = {}
AnimController.__index = AnimController

local PRIORITY = {
	Idle = Enum.AnimationPriority.Idle,
	Movement = Enum.AnimationPriority.Movement,
	Action = Enum.AnimationPriority.Action,
	Action2 = Enum.AnimationPriority.Action2,
	Action3 = Enum.AnimationPriority.Action3,
	Action4 = Enum.AnimationPriority.Action4,
	Core = Enum.AnimationPriority.Core,
}

-- "HitLeft#2" is the second copy of "HitLeft" (the same clip, its own track); its key made once
local COPY: { [string]: string } = setmetatable({}, {
	__index = function(t: any, k: string): string
		local v = k .. "#2"
		rawset(t, k, v)
		return v
	end,
}) :: any

local function baseKey(key: string): string
	return string.match(key, "^(.-)#%d+$") or key
end

-- a clip not yet published (Config.Anim[key].Id = ""): in a Studio play-test the KeyframeSequence it
-- comes from (ReplicatedStorage.Abilities.Assets.Animations[Source]) is registered on the spot - a
-- temporary id this Studio session alone can play. A live server can't: it needs the published Id
local registered: { [string]: string } = {}
local function sourceId(source: string): string?
	if registered[source] then
		return registered[source]
	end
	if not RunService:IsStudio() then
		warn("[Combat] animation " .. source .. " has no published Id (CombatConfig.Anim)")
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild("Abilities")
	folder = folder and folder:FindFirstChild("Assets")
	folder = folder and folder:FindFirstChild("Animations")
	local ks = folder and folder:FindFirstChild(source)
	if not (ks and ks:IsA("KeyframeSequence")) then
		return nil
	end
	local ok, id = pcall(function()
		return game:GetService("KeyframeSequenceProvider"):RegisterKeyframeSequence(ks)
	end)
	if ok and type(id) == "string" then
		registered[source] = id
		return id
	end
	warn("[Combat] could not register", source, id)
	return nil
end

-- shared Animation objects (one per clip for the whole place)
local animations: { [string]: Animation } = {}
local function animationFor(key: string): Animation?
	key = baseKey(key)
	local a = animations[key]
	if a then
		return a
	end
	local def = Config.Anim[key]
	if not def then
		return nil
	end
	local idStr = def.Id
	if (idStr == nil or idStr == "") and def.Source then
		idStr = sourceId(def.Source)
	end
	if idStr == nil or idStr == "" then
		return nil
	end
	a = Instance.new("Animation")
	a.Name = key
	a.AnimationId = idStr
	animations[key] = a
	return a
end

-- load every clip once so the first punch/dash never hitches
local preloaded = false
function AnimController.Preload()
	if preloaded then
		return
	end
	preloaded = true
	local list = {}
	for key in pairs(Config.Anim) do
		local a = animationFor(key)
		if a then
			table.insert(list, a)
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

local controllers: { [Humanoid]: any } = setmetatable({}, { __mode = "k" }) :: any

-- the retimed tracks being steered right now
type Drive = { Key: string, Nominal: number, To: number }
local driven: { [AnimationTrack]: Drive } = {}
local driveConn: RBXScriptConnection? = nil
local lastDt = 1 / 60
local function driveStep(dt: number)
	-- (the step coming is about as long as the one just gone)
	local step = math.clamp(lastDt, 1 / 240, 0.1)
	lastDt = dt
	for track, d in pairs(driven) do
		if not track.IsPlaying then
			driven[track] = nil
			continue
		end
		local sp = track.Speed
		if sp < 0.05 then
			continue -- (frozen by the fight: a hit-stop)
		end
		local tp = track.TimePosition
		if tp >= d.To then
			if math.abs(sp - d.Nominal) > 1e-3 then
				track:AdjustSpeed(d.Nominal)
			end
			driven[track] = nil
			continue
		end
		-- where the clip should be one step from now, and the speed that takes it there
		local target = Config.ClipTau(d.Key, Config.ClipU(d.Key, tp) + d.Nominal * step)
		local want = math.max((target - tp) / step, d.Nominal * 0.1)
		if math.abs(want - sp) > d.Nominal * 0.01 then
			track:AdjustSpeed(want)
		end
	end
	if next(driven) == nil and driveConn then
		driveConn:Disconnect()
		driveConn = nil
	end
end
-- the speed that takes a retimed clip from tp to where its timeline wants it one step from now (a
-- clip let go of a hit-stop inside its slowed snap goes on from that very frame at the snap's pace -
-- the rate at tp alone would carry it a whole step on at the rate of the frame before)
function AnimController.ServoSpeed(key: string, tp: number, nominal: number): number
	local _, to = Config.RetimeSpan(key)
	if not to or tp >= to or nominal <= 0 then
		return nominal
	end
	local step = math.clamp(lastDt, 1 / 240, 0.1)
	local target = Config.ClipTau(key, Config.ClipU(key, tp) + nominal * step)
	return math.max((target - tp) / step, nominal * 0.1)
end

-- a hit-stop on a strike's clip (def: its Config.Attacks entry): it holds on its Hit pose for `hold`
-- seconds, then goes on at its own pace. A clip still short of that pose when the blow lands (the
-- retime servo's frame, a hit counted a frame early: part way through its snap) plays on to it first
-- and holds for what is left - frozen mid-snap, the rest of the snap came out alone on the resume
-- frame, one frame's jolt between two still ones
function AnimController.HitStop(track: AnimationTrack, def: any, hold: number, alive: () -> boolean)
	local lag = Config.ClipReal(def, def.Hit) - Config.ClipReal(def, track.TimePosition)
	local function freeze()
		if alive() and track.IsPlaying then
			track:AdjustSpeed(0.02)
		end
	end
	if lag > 1 / 240 and lag < 0.06 then
		-- (a stop shorter than the way to the Hit pose: the clip just plays on through it, unfrozen)
		if hold - lag > 1 / 60 then
			task.delay(lag, freeze)
		else
			return
		end
	else
		freeze()
	end
	task.delay(hold, function()
		if alive() and track.IsPlaying then
			track:AdjustSpeed(AnimController.ServoSpeed(def.Anim, track.TimePosition, def.Speed))
		end
	end)
end

local function drive(track: AnimationTrack, key: string, speed: number)
	local from, to = Config.RetimeSpan(key)
	if not (from and to) or speed <= 0 then
		driven[track] = nil
		return
	end
	driven[track] = { Key = key, Nominal = speed, To = to }
	if not driveConn then
		lastDt = 1 / 60
		driveConn = RunService.Heartbeat:Connect(driveStep)
	end
end

-- how long Roblox fades a clip that ran off its own end (from full weight)
local NATURAL_TAIL = 0.3

-- a clip out over the time asked. A clip already on its way out - one that ran off its end (Roblox
-- then holds its last frame and fades it over its own ~0.3s) or one stopped before with a longer
-- fade - ignores a second Stop: it is taken back at the weight and the frame it has and faded out
-- again from there, so whatever takes over (a double jump's spin over a wall jump's) never has to
-- share the body with it for longer than asked. Never lengthens a fade already quicker.
local function fadeOut(self: any, t: AnimationTrack, f: number)
	local clock = os.clock()
	if t.IsPlaying then
		t:Stop(f)
		self.TailEnd[t] = clock + f
		return
	end
	local w = t.WeightCurrent
	if w < 0.01 then
		return
	end
	local ends = self.TailEnd[t] or (clock + w * NATURAL_TAIL)
	if clock + f >= ends - 0.01 then
		return
	end
	-- (a clip that ran off its end holds its last frame: it is held there, still)
	local ended = not t.Looped and t.Length > 0 and t.TimePosition >= t.Length - 0.002
	local at = if ended then math.max(t.Length - 0.001, 0) else t.TimePosition
	local speed = if ended then 0 else t.Speed
	driven[t] = nil
	t:Play(0, w, speed)
	t.TimePosition = at
	t:Stop(f)
	self.TailEnd[t] = clock + f
end

function AnimController.get(humanoid: Humanoid): any
	local c = controllers[humanoid]
	if c and c.Alive then
		return c
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	c = setmetatable({
		Humanoid = humanoid,
		Animator = animator,
		Tracks = {} :: { [string]: AnimationTrack },
		Fresh = {} :: { [string]: string }, -- which copy of a clip PlayFresh last started
		TailEnd = {} :: { [AnimationTrack]: number }, -- when a clip being faded out is gone
		Alive = true,
		Conn = nil :: RBXScriptConnection?,
	}, AnimController)
	controllers[humanoid] = c
	c.Conn = humanoid.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			c:Destroy()
		end
	end)
	return c
end

function AnimController:Track(key: string): AnimationTrack?
	if not self.Alive then
		return nil
	end
	local t = self.Tracks[key]
	if t then
		return t
	end
	local anim = animationFor(key)
	if not anim then
		warn("[Combat] unknown animation", key)
		return nil
	end
	local ok, track = pcall(function()
		return self.Animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		return nil
	end
	local def = Config.Anim[baseKey(key)]
	track.Priority = PRIORITY[def.Priority] or Enum.AnimationPriority.Action
	track.Looped = def.Looped == true
	self.Tracks[key] = track
	return track
end

-- opts: Fade, Speed, Weight, Time (start position), Priority (override name)
function AnimController:Play(key: string, opts: any?): AnimationTrack?
	local t = self:Track(key)
	if not t then
		return nil
	end
	opts = opts or {}
	if opts.Priority then
		t.Priority = PRIORITY[opts.Priority] or t.Priority
	end
	local fade = if opts.Fade ~= nil then opts.Fade else 0.1
	self.TailEnd[t] = nil
	local weight = if opts.Weight ~= nil then opts.Weight else 1
	local speed = if opts.Speed ~= nil then opts.Speed else 1
	if t.IsPlaying and opts.Restart ~= true then
		t:AdjustWeight(weight, fade)
		t:AdjustSpeed(speed)
	else
		-- a looped clip asked back while it is still fading out (a walk stopped for a strike's frame
		-- and wanted again the next): it picks up where it is - Play alone starts it over from its
		-- first frame at the weight it still has, a pop of the legs (or the stance) mid-stride
		local resume = t.Looped and opts.Restart ~= true and opts.Time == nil and t.WeightCurrent > 0.01
		local at = t.TimePosition
		t:Play(fade, weight, speed)
		if resume then
			t.TimePosition = at
		end
	end
	if opts.Time then
		t.TimePosition = opts.Time
	end
	if Config.Anim[baseKey(key)].Retime then
		drive(t, baseKey(key), speed)
	end
	return t
end

-- a clean restart of a clip that may already be playing (hit reactions landing back to back): the
-- clip's other copy starts from the top and fades in while the copy on screen fades out from the
-- pose it is in - no one-frame snap back to the first frame. opts as Play (Restart is implied).
function AnimController:PlayFresh(key: string, opts: any?): AnimationTrack?
	local copy = COPY[key]
	local active = self.Fresh[key] or key
	local cur = self:Track(active)
	if not cur then
		return nil
	end
	local o = table.clone(opts or {})
	o.Restart = true
	if not cur.IsPlaying then
		return self:Play(active, o)
	end
	local nextKey = if active == key then copy else key
	local fade = if o.Fade ~= nil then o.Fade else 0.1
	local tr = self:Play(nextKey, o)
	if tr then
		fadeOut(self, cur, fade)
		self.Fresh[key] = nextKey
	end
	return tr
end

function AnimController:Stop(key: string, fade: number?)
	local f = if fade ~= nil then fade else 0.15
	local t = self.Tracks[key]
	if t then
		fadeOut(self, t, f)
	end
	local c = self.Tracks[COPY[key]]
	if c then
		fadeOut(self, c, f)
	end
end

-- a track taken straight from :Track() faded out the same way (every fade-out goes through fadeOut,
-- so it always knows when a clip on its way out is gone)
function AnimController:FadeTrack(track: AnimationTrack, fade: number)
	fadeOut(self, track, fade)
end

function AnimController:StopMany(keys: { string }, fade: number?)
	for _, k in ipairs(keys) do
		self:Stop(k, fade)
	end
end

-- is a clip at or above `priority` still fading in? (what lies under it is still showing through: a
-- clip under it that stops now drains while the cover fills, and the idle beneath both shows between
-- them - three poses mixed at once. Callers let the cover finish first)
function AnimController:FadingIn(priority: Enum.AnimationPriority): boolean
	for _, t in pairs(self.Tracks) do
		if t.IsPlaying and t.Priority.Value >= priority.Value and t.WeightCurrent < t.WeightTarget - 0.02 then
			return true
		end
	end
	return false
end

function AnimController:IsPlaying(key: string): boolean
	local t = self.Tracks[key]
	if t ~= nil and t.IsPlaying then
		return true
	end
	local c = self.Tracks[COPY[key]]
	return c ~= nil and c.IsPlaying
end

function AnimController:Destroy()
	if not self.Alive then
		return
	end
	self.Alive = false
	if self.Conn then
		self.Conn:Disconnect()
		self.Conn = nil
	end
	for _, t in pairs(self.Tracks) do
		driven[t] = nil
		pcall(function()
			t:Stop(0)
			t:Destroy()
		end)
	end
	table.clear(self.Tracks)
	table.clear(self.Fresh)
	table.clear(self.TailEnd)
	controllers[self.Humanoid] = nil
end

return AnimController
