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
	  VFX.Along(pos, dir)             a CFrame at pos whose UpVector is dir
	  VFX.Flat(pos)                   a CFrame at pos lying on the ground (UpVector = world up)

	Effects in the folder (see extract_vfx.py for where each one comes from):
	  Blood       clean light hit          BloodHeavy  heavy hit / finisher / stomp
	  Block       blocked hit              GuardBreak  guard shattered
	  Impact      the white ring that goes with a heavy clean hit
	  Dash        a dash's kick-off (Anime Smoke-01 puffs, Anime Wind-01 ring + gust, Hit-04 streaks)
	  GroundDust  dust rolling out along the ground (Anime Smoke-01): stomps and launches
	(The stomp's shattered ground is built from parts, not particles: see CombatShatter.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VFX = {}

local folder: Instance? = nil
local function templates(): Instance?
	if folder and folder.Parent then
		return folder
	end
	local combat = ReplicatedStorage:FindFirstChild("Combat")
	folder = combat and combat:FindFirstChild("VFX")
	return folder
end

local function scaleSeq(seq: NumberSequence, k: number): NumberSequence
	local out = {}
	for _, kp in ipairs(seq.Keypoints) do
		table.insert(out, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	return NumberSequence.new(out)
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

function VFX.Play(name: string, cf: CFrame, opts: any?): Attachment?
	local lib = templates()
	local tpl = lib and lib:FindFirstChild(name)
	if not (tpl and tpl:IsA("Attachment")) then
		return nil
	end
	local o = opts or {}
	local scale = o.Scale or 1
	local countK = o.Count or 1
	-- Studio inspection only: workspace attribute VFXTimeScale (e.g. 0.2) plays every effect in slow motion
	local ts = workspace:GetAttribute("VFXTimeScale")
	ts = if type(ts) == "number" and ts > 0.01 and ts < 1 then ts else 1
	local a = tpl:Clone()
	-- world effects live on Terrain (at the origin, so the CFrame is the world frame); opts.Parent
	-- pins the effect to a part instead (cf is then relative to that part) so it rides with it
	a.CFrame = cf
	a.Parent = if o.Parent and o.Parent:IsA("BasePart") then o.Parent else workspace.Terrain
	local longest = 0
	for _, e in ipairs(a:GetChildren()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
			if ts ~= 1 then
				e.TimeScale = ts
			end
			if scale ~= 1 then
				e.Size = scaleSeq(e.Size, scale)
				e.Speed = NumberRange.new(e.Speed.Min * scale, e.Speed.Max * scale)
			end
			local count = math.max(1, math.floor((e:GetAttribute("EmitCount") or 1) * countK + 0.5))
			local delay = (e:GetAttribute("EmitDelay") or 0) / ts
			-- never Emit() in the same frame the clone was parented: the engine can drop that burst
			-- (the guard-break bubble never showed), so fire on the next resume at the earliest
			local function fire()
				if e.Parent then
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
		a:Destroy()
	end)
	return a
end

return VFX
