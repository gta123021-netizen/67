--[[
	CombatVFX  (ReplicatedStorage.Combat.CombatVFX)
	Plays the effects kept in ReplicatedStorage.Combat.VFX - the user's own VFX packs, one
	Attachment per effect holding the pack's ParticleEmitters (switched off; each carries its
	EmitCount / EmitDelay attributes). Client-side and cosmetic only.

	  VFX.Play(name, cframe, opts?)   burst an effect at a world CFrame. The effect's +Y is the way
	                                  it throws its particles (droplets, sparks), so pass a frame
	                                  whose UpVector points where the blow drove.
	      opts.Scale   size multiplier (and droplet speed)
	      opts.Count   emit-count multiplier
	      opts.Parent  a BasePart to pin the effect to (cframe relative to it)
	      opts.Only    { [emitter name] = true }: fire only these emitters of the effect
	      opts.Counts  { [emitter name] = n }: how many to emit (for an emitter the pack runs on
	                   its Rate rather than a burst count)
	      opts.Color   a ColorSequence every fired emitter takes (dust tinted like the ground)
	      opts.Speed   speed multiplier on top of Scale (a weak spurt, a hard gush)
	      opts.Spread  spread-angle multiplier (a tight squirt, a wide splash)
	      opts.Life    lifetime multiplier (a longer arc, a shorter puff)
	      opts.Gravity acceleration multiplier (heavier or lighter liquid)
	      opts.Inherit the share of the parent part's velocity each particle leaves with (a wound on a
	                   running, flung or ragdolled body: the blood goes with it, trailing a little)
	      opts.Face    sprites face the camera (a splat seen from any side)
	      opts.Delay   seconds before it fires
	    Returns the effect's Attachment (destroy it to cut the effect short).
	  VFX.Attach(name, part, offset?)  run an effect continuously on a moving part (its emitters on
	                                  their own Rate) until handle.Stop(); a Part template (an
	                                  effect that emits from a volume) follows the part every frame
	  VFX.Along(pos, dir)             a CFrame at pos whose UpVector is dir
	  VFX.Flat(pos)                   a CFrame at pos lying on the ground (UpVector = world up)

	Effects in the folder (see extract_vfx.py for where each one comes from):
	  Blood       clean light hit          BloodHeavy  heavy hit / finisher / stomp
	  (the blood - CombatBlood - also plays the blood packs' own effects, copied here from the
	  place's Workspace: BloodWound (A - SUDDEN WOUND), BloodJet (I - Veinless), BloodStream
	  (B - HEMORRHAGE), BloodGush (E - Gushing), BloodBleed (D - Bleeding), BloodDrip (B - Puddle),
	  BloodSplatter / BloodSplatterWild (G - Splatter / H - Wild Splatter), BloodSpatter
	  (C - BLOOD SPLATTER), BloodStrand (Anime Blood-02), BloodSplash (Anime Blood-01, lies flat on a
	  surface), BloodPunch (Blood-Punch-01), BloodBurst (the blood explosion))
	  Block       blocked hit              GuardBreak  guard shattered
	  Impact      the white ring that goes with a heavy clean hit
	  Dash        a dash's kick-off (Anime Smoke-01 puffs, Anime Wind-01 ring + gust, Hit-04 streaks)
	  GroundDust  dust rolling out along the ground (Anime Smoke-01): stomps and launches
	(The stomp's shattered ground is built from parts, not particles: see CombatShatter.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VFX = {}
local STUDIO = RunService:IsStudio()
local VIEW = 200 -- studs: farther than this from the camera no effect is built (opts.View overrides)

-- Studio inspection only (the workspace attribute VFXTimeScale, e.g. 0.2): never in a live game - an
-- attribute saved with the place would slow every effect for every player
function VFX.TimeScale(): number
	local ts = if STUDIO then workspace:GetAttribute("VFXTimeScale") else nil
	return if type(ts) == "number" and ts > 0.01 and ts < 1 then ts else 1
end

local folder: Instance? = nil
local function templates(): Instance?
	if folder and folder.Parent then
		return folder
	end
	local combat = ReplicatedStorage:FindFirstChild("Combat")
	folder = combat and combat:FindFirstChild("VFX")
	return folder
end

-- (scaled sizes are cached per template emitter and scale: the same few effects play all fight long)
local seqCache: { [string]: NumberSequence } = {}
local function scaleSeq(seq: NumberSequence, k: number, id: string): NumberSequence
	local key = id .. "@" .. math.floor(k * 100 + 0.5) -- (to 1%: a bounded cache)
	local hit = seqCache[key]
	if hit then
		return hit
	end
	local out = {}
	for _, kp in ipairs(seq.Keypoints) do
		table.insert(out, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	local made = NumberSequence.new(out)
	seqCache[key] = made
	return made
end

function VFX.Along(pos: Vector3, dir: Vector3): CFrame
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local back = right:Cross(up).Unit
	return CFrame.fromMatrix(pos, right, up, back)
end

function VFX.Flat(pos: Vector3): CFrame
	return CFrame.new(pos)
end

-- a copy of each effect is kept for the next time it plays (a fight plays the same few effects all
-- the time: nothing is cloned or destroyed per hit once they have all played). Every property a play
-- changes is put back from the template before the copy is used again.
local spare: { [string]: { Attachment } } = {}
local SPARE_MAX = 6
local TOUCHED = { "Size", "Speed", "Color", "ZOffset", "TimeScale", "SpreadAngle", "Lifetime", "Acceleration", "VelocityInheritance", "Orientation" }
local function takeCopy(name: string, tpl: Attachment): Attachment
	local list = spare[name]
	local a = list and table.remove(list)
	if a then
		for _, e in ipairs(a:GetChildren()) do
			local t = tpl:FindFirstChild(e.Name)
			if e:IsA("ParticleEmitter") and t and t:IsA("ParticleEmitter") then
				for _, prop in ipairs(TOUCHED) do
					(e :: any)[prop] = (t :: any)[prop]
				end
			end
		end
		return a
	end
	return tpl:Clone() :: Attachment
end
local function giveBack(name: string, a: Attachment, trimmed: boolean)
	local list = spare[name]
	if not list then
		list = {}
		spare[name] = list
	end
	if trimmed or #list >= SPARE_MAX then
		a:Destroy()
		return
	end
	a.Parent = nil
	table.insert(list, a)
end

function VFX.Play(name: string, cf: CFrame, opts: any?): Attachment?
	local lib = templates()
	local tpl = lib and lib:FindFirstChild(name)
	if not (tpl and tpl:IsA("Attachment")) then
		return nil
	end
	local o = opts or {}
	-- (out of sight is out of mind: every client hears every hit in the server - nothing is built for
	-- one far across the map)
	local cam = workspace.CurrentCamera
	if cam then
		local world = if o.Parent and o.Parent:IsA("BasePart") then (o.Parent :: BasePart).CFrame * cf else cf
		if (cam.CFrame.Position - world.Position).Magnitude > (o.View or VIEW) then
			return nil
		end
	end
	local scale = o.Scale or 1
	local countK = o.Count or 1
	local speedK = (o.Speed or 1) * scale
	local ts = VFX.TimeScale()
	-- (a play that keeps only some of the emitters makes a copy of its own: never handed back trimmed)
	local trimmed = o.Only ~= nil
	local a = if trimmed then tpl:Clone() :: Attachment else takeCopy(name, tpl)
	if o.Only then
		for _, e in ipairs(a:GetChildren()) do
			if e:IsA("ParticleEmitter") and not o.Only[e.Name] then
				e:Destroy()
			end
		end
	end
	-- world effects live on Terrain (at the origin, so the CFrame is the world frame); opts.Parent
	-- pins the effect to a part instead (cf is then relative to that part) so it rides with it
	a.CFrame = cf
	a.Parent = if o.Parent and o.Parent:IsA("BasePart") then o.Parent else workspace.Terrain
	local longest = 0
	local lead = o.Delay or 0
	for _, e in ipairs(a:GetChildren()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
			if ts ~= 1 then
				e.TimeScale = ts
			end
			if scale ~= 1 then
				e.Size = scaleSeq(e.Size, scale, name .. "/" .. e.Name)
			end
			if speedK ~= 1 then
				e.Speed = NumberRange.new(e.Speed.Min * speedK, e.Speed.Max * speedK)
			end
			if o.Spread and o.Spread ~= 1 then
				e.SpreadAngle = e.SpreadAngle * o.Spread
			end
			if o.Life and o.Life ~= 1 then
				e.Lifetime = NumberRange.new(e.Lifetime.Min * o.Life, e.Lifetime.Max * o.Life)
			end
			if o.Gravity and o.Gravity ~= 1 then
				e.Acceleration = e.Acceleration * o.Gravity
			end
			if o.Inherit then
				e.VelocityInheritance = o.Inherit
			end
			if o.Face then
				e.Orientation = Enum.ParticleOrientation.FacingCamera
			end
			if o.Color then
				e.Color = o.Color
			end
			if o.ZOffset ~= nil then
				e.ZOffset = o.ZOffset -- (a ground layer that must not draw over what lies in it)
			end
			local base = if o.Counts and o.Counts[e.Name] then o.Counts[e.Name] else (e:GetAttribute("EmitCount") or 1)
			local count = math.max(1, math.floor(base * countK + 0.5))
			local delay = ((e:GetAttribute("EmitDelay") or 0) + lead) / ts
			-- never Emit() in the same frame the clone was parented: the engine can drop that burst
			-- (the guard-break bubble never showed), so fire on the next resume at the earliest
			local function fire()
				if e.Parent and a.Parent then
					e:Emit(count)
				end
			end
			if delay > 0 then
				task.delay(delay, fire)
			else
				task.defer(fire)
			end
			longest = math.max(longest, delay + e.Lifetime.Max / ts)
		end
	end
	task.delay(longest + 0.25, function()
		if a.Parent == nil then
			return -- (cut short by whoever played it)
		end
		giveBack(name, a, trimmed)
	end)
	return a
end

-- an effect running on a moving part (the Ground Smash's descent): its emitters on their own Rate
-- until Stop(), then gone once their last particles have faded
function VFX.Attach(name: string, part: BasePart, offset: CFrame?): { Stop: () -> () }
	local lib = templates()
	local tpl = lib and lib:FindFirstChild(name)
	local none = { Stop = function() end }
	if not tpl then
		return none
	end
	local inst = tpl:Clone()
	local off = offset or CFrame.identity
	local conn: RBXScriptConnection? = nil
	if inst:IsA("BasePart") then
		-- (it emits from its own volume round the body: an invisible part that follows it)
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CanTouch = false
		inst.Transparency = 1
		inst.CFrame = part.CFrame * off
		inst.Parent = workspace.Terrain
		local RunService = game:GetService("RunService")
		conn = RunService.Heartbeat:Connect(function()
			if part.Parent then
				inst.CFrame = part.CFrame * off
			end
		end)
	elseif inst:IsA("Attachment") then
		inst.CFrame = off
		inst.Parent = part
	else
		inst:Destroy()
		return none
	end
	local longest = 0
	for _, e in ipairs(inst:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = true
			longest = math.max(longest, e.Lifetime.Max)
		end
	end
	local stopped = false
	return {
		Stop = function()
			if stopped then
				return
			end
			stopped = true
			for _, e in ipairs(inst:GetDescendants()) do
				if e:IsA("ParticleEmitter") then
					e.Enabled = false
				end
			end
			task.delay(longest + 0.1, function()
				if conn then
					conn:Disconnect()
				end
				inst:Destroy()
			end)
		end,
	}
end

return VFX
