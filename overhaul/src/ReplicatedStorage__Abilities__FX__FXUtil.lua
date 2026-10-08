--[[
	FXUtil  (ReplicatedStorage.Abilities.FX.FXUtil)
	The small toolbox every ability's effects are built with (client-side, cosmetic only):

	  Holder()                     the workspace folder every ability's effects live in (one per screen)
	  Part(props)                  an anchored, untouchable, unqueryable, shadowless part
	  Clone(template, parent, cf, scale)   a copy of a pack's effect (an Attachment of emitters, a Beam,
	                               a MeshPart) sized by `scale`, its emitters switched off
	  Burst(att, scale?, count?)   fire every emitter of an effect once, the pack's own way: its
	                               EmitCount / EmitDelay attributes (an emitter with none: a few on its Rate)
	  Enable(att, on)              its emitters on / off (their own Rate)
	  Sound(id, parent, props)     a 3D sound in the SFX group (the Settings volume), cleaned with the cast
	  Ramp(a, b, t)                smoothstep from a to b
	  Noise(t, seed)               smooth -1..1 noise
	  Maid()                       everything a cast made, cleaned in one call (instances, connections,
	                               callbacks) - nothing an ability makes ever outlives it
]]

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local U = {}

local holder: Folder? = nil
function U.Holder(): Folder
	if holder and holder.Parent then
		return holder
	end
	local f = workspace:FindFirstChild("AbilityFX")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = "AbilityFX"
		f.Parent = workspace
	end
	holder = f :: Folder
	return holder :: Folder
end

function U.Part(props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.2
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Locked = true
	if props then
		for k, v in pairs(props) do
			(p :: any)[k] = v
		end
	end
	return p
end

-- a MeshPart (or any part) copy that never touches the world
function U.Solid(template: BasePart, props: { [string]: any }?): BasePart
	local p = template:Clone()
	for _, d in ipairs(p:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	if props then
		for k, v in pairs(props) do
			(p :: any)[k] = v
		end
	end
	return p
end

local seqCache: { [NumberSequence]: { [number]: NumberSequence } } = setmetatable({}, { __mode = "k" }) :: any
function U.ScaleSeq(seq: NumberSequence, k: number): NumberSequence
	if k == 1 then
		return seq
	end
	local byK = seqCache[seq]
	if not byK then
		byK = {}
		seqCache[seq] = byK
	end
	local key = math.floor(k * 1000 + 0.5)
	local hit = byK[key]
	if hit then
		return hit
	end
	local out = {}
	for _, kp in ipairs(seq.Keypoints) do
		table.insert(out, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	local made = NumberSequence.new(out)
	byK[key] = made
	return made
end

local function scaleRange(r: NumberRange, k: number): NumberRange
	return NumberRange.new(r.Min * k, r.Max * k)
end

-- an emitter sized by k (its particles' size, speed and pull: the same effect, bigger or smaller)
function U.ScaleEmitter(e: ParticleEmitter, k: number)
	if k == 1 then
		return
	end
	e.Size = U.ScaleSeq(e.Size, k)
	e.Speed = scaleRange(e.Speed, k)
	e.Acceleration *= k
end

-- a copy of an effect template (Attachment / Beam / BasePart), sized, its emitters off
function U.Clone(template: Instance, parent: Instance, cf: CFrame?, scale: number?): any
	local c = template:Clone()
	local k = scale or 1
	local list = c:GetDescendants()
	table.insert(list, c)
	for _, d in ipairs(list) do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			U.ScaleEmitter(d, k)
		elseif d:IsA("Beam") then
			d.Width0 *= k
			d.Width1 *= k
		elseif d:IsA("PointLight") then
			d.Enabled = false
		end
	end
	if cf then
		if c:IsA("Attachment") then
			c.CFrame = cf
		elseif c:IsA("BasePart") then
			c.CFrame = cf
		end
	end
	c.Parent = parent
	return c
end

local function emitters(root: Instance): { ParticleEmitter }
	local out = {}
	if root:IsA("ParticleEmitter") then
		table.insert(out, root)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			table.insert(out, d)
		end
	end
	return out
end
U.Emitters = emitters

-- fire an effect once, the pack's own way (EmitCount / EmitDelay), count x `count`
function U.Burst(root: Instance, count: number?)
	local m = count or 1
	for _, e in ipairs(emitters(root)) do
		local n = e:GetAttribute("EmitCount")
		local delay = e:GetAttribute("EmitDelay")
		local amount = if type(n) == "number" then n else math.clamp(math.floor(e.Rate * 0.12 + 0.5), 1, 12)
		amount = math.max(1, math.floor(amount * m + 0.5))
		if type(delay) == "number" and delay > 0 then
			task.delay(delay, function()
				if e.Parent then
					e:Emit(amount)
				end
			end)
		else
			e:Emit(amount)
		end
	end
end

function U.Enable(root: Instance, on: boolean)
	for _, e in ipairs(emitters(root)) do
		e.Enabled = on
	end
end

-- how long until everything an effect emitted is gone
function U.Life(root: Instance): number
	local m = 0
	for _, e in ipairs(emitters(root)) do
		local d = e:GetAttribute("EmitDelay")
		m = math.max(m, e.Lifetime.Max + (if type(d) == "number" then d else 0))
	end
	return m
end

-- remove `inst` once its particles have played out
function U.Expire(inst: Instance, after: number?)
	Debris:AddItem(inst, (after or U.Life(inst)) + 0.1)
end

function U.Sound(id: string | number, parent: Instance, props: { [string]: any }?): Sound
	local s = Instance.new("Sound")
	s.SoundId = if type(id) == "number" then "rbxassetid://" .. id else id
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 14
	s.RollOffMaxDistance = 260
	local g = SoundService:FindFirstChild("SFX")
	if g and g:IsA("SoundGroup") then
		s.SoundGroup = g
	end
	if props then
		for k, v in pairs(props) do
			(s :: any)[k] = v
		end
	end
	s.Parent = parent
	return s
end

function U.Ramp(a: number, b: number, t: number): number
	local x = math.clamp(t, 0, 1)
	return a + (b - a) * (x * x * (3 - 2 * x))
end

function U.EaseOut(t: number): number
	local x = math.clamp(t, 0, 1)
	return 1 - (1 - x) * (1 - x) * (1 - x)
end

function U.Clamp01(t: number): number
	return math.clamp(t, 0, 1)
end

function U.Noise(t: number, seed: number): number
	return math.clamp(math.noise(t, seed, seed * 0.37) * 2, -1, 1)
end

-- a frame at `pos` whose LookVector is `dir` (a beam, an emitter's Front)
function U.Look(pos: Vector3, dir: Vector3): CFrame
	local d = if dir.Magnitude > 1e-4 then dir.Unit else Vector3.new(0, 0, -1)
	local up = if math.abs(d.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(pos, pos + d, up)
end

-- a frame at `pos` whose UpVector is `up` (a ring lying on a surface)
function U.Up(pos: Vector3, up: Vector3): CFrame
	local u = if up.Magnitude > 1e-4 then up.Unit else Vector3.yAxis
	local right = u:Cross(Vector3.zAxis)
	if right.Magnitude < 1e-3 then
		right = u:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local back = right:Cross(u).Unit
	return CFrame.fromMatrix(pos, right, u, back)
end

-- everything a cast made, gone in one call
export type Maid = { Give: (any, any) -> any, Clean: (any) -> () }
function U.Maid(): any
	local m = { Items = {} }
	function m:Give(x: any): any
		table.insert(self.Items, x)
		return x
	end
	function m:Clean()
		local items = self.Items
		self.Items = {}
		for i = #items, 1, -1 do
			local x = items[i]
			local ty = typeof(x)
			if ty == "RBXScriptConnection" then
				x:Disconnect()
			elseif ty == "Instance" then
				pcall(function()
					x:Destroy()
				end)
			elseif ty == "function" then
				pcall(x)
			elseif ty == "table" and x.Clean then
				x:Clean()
			end
		end
	end
	return m
end

return U
