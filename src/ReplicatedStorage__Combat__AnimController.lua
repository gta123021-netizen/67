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
]]

local ContentProvider = game:GetService("ContentProvider")
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

-- "HitLeft#2" is the second copy of "HitLeft" (the same clip, its own track)
local function baseKey(key: string): string
	return string.match(key, "^(.-)#%d+$") or key
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
	a = Instance.new("Animation")
	a.Name = key
	a.AnimationId = def.Id
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
	local weight = if opts.Weight ~= nil then opts.Weight else 1
	local speed = if opts.Speed ~= nil then opts.Speed else 1
	if t.IsPlaying and opts.Restart ~= true then
		t:AdjustWeight(weight, fade)
		t:AdjustSpeed(speed)
	else
		t:Play(fade, weight, speed)
	end
	if opts.Time then
		t.TimePosition = opts.Time
	end
	return t
end

-- a clean restart of a clip that may already be playing (hit reactions landing back to back): the
-- clip's other copy starts from the top and fades in while the copy on screen fades out from the
-- pose it is in - no one-frame snap back to the first frame. opts as Play (Restart is implied).
function AnimController:PlayFresh(key: string, opts: any?): AnimationTrack?
	local copy = key .. "#2"
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
		cur:Stop(fade)
		self.Fresh[key] = nextKey
	end
	return tr
end

function AnimController:Stop(key: string, fade: number?)
	local f = if fade ~= nil then fade else 0.15
	local t = self.Tracks[key]
	if t and t.IsPlaying then
		t:Stop(f)
	end
	local c = self.Tracks[key .. "#2"]
	if c and c.IsPlaying then
		c:Stop(f)
	end
end

function AnimController:StopMany(keys: { string }, fade: number?)
	for _, k in ipairs(keys) do
		self:Stop(k, fade)
	end
end

function AnimController:IsPlaying(key: string): boolean
	local t = self.Tracks[key]
	if t ~= nil and t.IsPlaying then
		return true
	end
	local c = self.Tracks[key .. "#2"]
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
		pcall(function()
			t:Stop(0)
			t:Destroy()
		end)
	end
	table.clear(self.Tracks)
	table.clear(self.Fresh)
	controllers[self.Humanoid] = nil
end

return AnimController
