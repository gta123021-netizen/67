--!nocheck
-- Runs ReplicatedStorage.Abilities.FX.AzureTideCannon (and the modules it needs) inside Lune against the
-- real place's assets, with a simulated clock, render loop, scheduler and world, frame by frame through
-- a whole cast. Every property it sets is type-checked by Lune's Roblox reflection; every error the
-- effects swallow (their pcalls, their warn) is reported.
--   lune run tools/lune/azure_tide_fx.luau <place.rbxl> <src dir> <scenario>
--   scenarios: floor air body wall up interrupt fizzle destroy others (PROBE=1 prints the beam and blast)
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local process = require("@lune/process")

local placePath, srcDir, scenario = process.args[1], process.args[2], process.args[3] or "floor"
local game = roblox.deserializePlace(fs.readFile(placePath))
local Instance = roblox.Instance
local Vector3, Enum = roblox.Vector3, roblox.Enum
-- (Lune's CFrame.lookAt mirrors Z; Roblox's: LookVector = (target - pos).Unit)
local RCF = roblox.CFrame
local function lookAt(pos, target, up)
	local look = (target - pos).Unit
	local u = up or Vector3.yAxis
	local right = look:Cross(u)
	if right.Magnitude < 1e-6 then
		right = look:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local upv = right:Cross(look).Unit
	return RCF.fromMatrix(pos, right, upv, -look)
end
local CFrame = setmetatable({ lookAt = lookAt }, { __index = RCF })
do
	local c = lookAt(Vector3.zero, Vector3.new(0.3, 0.4, -1))
	assert((c.LookVector - Vector3.new(0.3, 0.4, -1).Unit).Magnitude < 1e-5, "lookAt fix")
end
local workspace = game:GetService("Workspace")

---------------------------------------------------------------------------
-- simulated time, scheduler, render loop
---------------------------------------------------------------------------
local simT = 1000
local timers = {}
local function schedule(t, fn, ...)
	table.insert(timers, { T = simT + (t or 0), Fn = fn, Args = table.pack(...) })
end
local problems = {}
local function problem(msg)
	table.insert(problems, string.format("[t=%.2f] %s", simT - 1000, msg))
end

local function signal()
	local conns = {}
	local s = {}
	function s:Connect(fn)
		local c = { Fn = fn, Connected = true }
		function c:Disconnect()
			c.Connected = false
		end
		table.insert(conns, c)
		return c
	end
	function s:Once(fn)
		local c
		c = s:Connect(function(...)
			c:Disconnect()
			fn(...)
		end)
		return c
	end
	function s:Fire(...)
		for _, c in ipairs(table.clone(conns)) do
			if c.Connected then
				local ok, err = pcall(c.Fn, ...)
				if not ok then
					problem("signal handler: " .. tostring(err))
				end
			end
		end
		for i = #conns, 1, -1 do
			if not conns[i].Connected then
				table.remove(conns, i)
			end
		end
	end
	return s
end

local bound = {}
local RenderStepped = signal()
local Heartbeat = signal()
local RunService = {
	RenderStepped = RenderStepped,
	Heartbeat = Heartbeat,
}
function RunService:IsStudio()
	return true
end
function RunService:BindToRenderStep(name, _prio, fn)
	bound[name] = fn
end
function RunService:UnbindFromRenderStep(name)
	bound[name] = nil
end
local DebrisSvc = {}
function DebrisSvc:AddItem(inst, t)
	schedule(t, function()
		pcall(function()
			inst:Destroy()
		end)
	end)
end

local fakeGame = setmetatable({}, {
	__index = function(_, k)
		if k == "GetService" then
			return function(_, name)
				if name == "RunService" then
					return RunService
				elseif name == "Debris" then
					return DebrisSvc
				end
				return game:GetService(name)
			end
		end
		return game[k]
	end,
})

---------------------------------------------------------------------------
-- the parts of the Roblox API Lune leaves out
---------------------------------------------------------------------------
roblox.implementMethod("Instance", "WaitForChild", function(self, name)
	local c = self:FindFirstChild(name)
	if not c then
		problem("WaitForChild would hang: " .. self:GetFullName() .. "." .. name)
	end
	return c
end)
local emitted = 0
roblox.implementMethod("ParticleEmitter", "Emit", function(_, n)
	emitted += (n or 1)
end)
local soundIds = setmetatable({}, { __mode = "k" })
roblox.implementProperty("Sound", "SoundId", function(snd)
	if soundIds[snd] then
		return soundIds[snd]
	end
	local ok, c = pcall(function()
		return snd.AudioContent
	end)
	return if ok and c then tostring(c) else "rbxassetid://0"
end, function(snd, v)
	assert(type(v) == "string", "SoundId wants a string")
	soundIds[snd] = v
end)
roblox.implementMethod("Sound", "Play", function() end)
roblox.implementMethod("Sound", "Stop", function() end)
roblox.implementProperty("Sound", "IsPlaying", function()
	return false
end)
roblox.implementProperty("Sound", "Ended", function()
	return signal()
end)
local function pivotOf(m)
	local pp = m.PrimaryPart
	if pp then
		return pp.CFrame
	end
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			return d.CFrame
		end
	end
	return CFrame.new()
end
roblox.implementMethod("Model", "GetPivot", pivotOf)
roblox.implementMethod("Model", "PivotTo", function(m, cf)
	local p0 = pivotOf(m)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = cf * p0:ToObjectSpace(d.CFrame)
		end
	end
end)
roblox.implementProperty("BasePart", "Position", function(p)
	return p.CFrame.Position
end, function(p, v)
	p.CFrame = CFrame.new(v) * (p.CFrame - p.CFrame.Position)
end)
local vel = setmetatable({}, { __mode = "k" })
roblox.implementProperty("BasePart", "AssemblyLinearVelocity", function(p)
	return vel[p] or Vector3.zero
end, function(p, v)
	assert(typeof(v) == "Vector3", "AssemblyLinearVelocity wants a Vector3")
	vel[p] = v
end)
roblox.implementProperty("BasePart", "AssemblyAngularVelocity", function()
	return Vector3.zero
end, function(_, v)
	assert(typeof(v) == "Vector3", "AssemblyAngularVelocity wants a Vector3")
end)
local function parentCf(a)
	local p = a.Parent
	if p and p:IsA("BasePart") then
		return p.CFrame
	end
	return CFrame.new()
end
roblox.implementProperty("Attachment", "WorldCFrame", function(a)
	return parentCf(a) * a.CFrame
end, function(a, cf)
	a.CFrame = parentCf(a):ToObjectSpace(cf)
end)
roblox.implementProperty("Attachment", "WorldPosition", function(a)
	return (parentCf(a) * a.CFrame).Position
end, function(a, v)
	a.CFrame = CFrame.new(parentCf(a):PointToObjectSpace(v)) * (a.CFrame - a.CFrame.Position)
end)
local camera = Instance.new("Camera")
camera.CFrame = CFrame.lookAt(Vector3.new(6, 9, 14), Vector3.new(0, 3, -10))
camera.Focus = CFrame.new(0, 3, 0)
camera.Parent = workspace
roblox.implementProperty("Workspace", "CurrentCamera", function()
	return camera
end)
local moved = 0
roblox.implementMethod("Workspace", "BulkMoveTo", function(_, parts, cfs, _mode)
	assert(#parts == #cfs, "BulkMoveTo: parts and frames differ")
	for i, p in ipairs(parts) do
		assert(typeof(cfs[i]) == "CFrame", "BulkMoveTo: not a CFrame")
		p.CFrame = cfs[i]
		moved += 1
	end
end)
roblox.implementMethod("Workspace", "GetServerTimeNow", function()
	return simT
end)
roblox.implementMethod("Terrain", "GetMaterialColor", function()
	return roblox.Color3.new(0.4, 0.5, 0.3)
end)

---------------------------------------------------------------------------
-- the world: a floor (y = 0) and, in some scenarios, a wall
---------------------------------------------------------------------------
local floorPart = Instance.new("Part")
floorPart.Name = "Floor"
floorPart.Color = roblox.Color3.fromRGB(90, 140, 60)
floorPart.Material = Enum.Material.Grass
floorPart.Parent = workspace
local WALL_Z = if scenario == "wall" then -25 else nil
local function world(o, v)
	assert(typeof(o) == "Vector3" and typeof(v) == "Vector3", "World wants (Vector3, Vector3)")
	assert(o.X == o.X and v.X == v.X, "World given NaN")
	local best, bt = nil, math.huge
	if o.Y >= 0 and o.Y + v.Y < 0 then
		local t = o.Y / -v.Y
		if t < bt then
			bt, best = t, { Position = o + v * t, Normal = Vector3.yAxis, Instance = floorPart, Material = Enum.Material.Grass, Distance = (v * t).Magnitude }
		end
	end
	if WALL_Z and o.Z >= WALL_Z and o.Z + v.Z < WALL_Z then
		local t = (o.Z - WALL_Z) / -v.Z
		if t < bt then
			bt, best = t, { Position = o + v * t, Normal = Vector3.zAxis, Instance = floorPart, Material = Enum.Material.Concrete, Distance = (v * t).Magnitude }
		end
	end
	return best
end
roblox.implementMethod("Workspace", "Raycast", function(_, o, v)
	return world(o, v)
end)

---------------------------------------------------------------------------
-- the modules, loaded from the edited sources in an environment of their own
---------------------------------------------------------------------------
local base = getfenv()
local function fileFor(inst)
	local path = inst:GetFullName():gsub("%.", "/")
	local name = path:gsub("/", "__"):gsub(" ", "_")
	local ext = if inst.ClassName == "ModuleScript" then ".lua" elseif inst.ClassName == "LocalScript" then ".client.lua" else ".server.lua"
	return srcDir .. "/" .. name .. ext
end
local cache = {}
local pcallFails = {}
local env
local function req(mod)
	if cache[mod] then
		return cache[mod]
	end
	local file = fileFor(mod)
	local src = if fs.isFile(file) then fs.readFile(file) else mod.Source
	-- (Lune keeps a part's CFrame but not its derived Position: read it through the CFrame)
	src = src:gsub("%f[%w_](ball)%.Position", "%1.CFrame.Position")
	src = src:gsub("%f[%w_](origin)%.Position", "%1.CFrame.Position")
	src = src:gsub("%f[%w_](root)%.Position", "%1.CFrame.Position")
	src = src:gsub("%f[%w_](Root)%.Position", "%1.CFrame.Position")
	src = src:gsub("BasePart%)%.Position", "BasePart).CFrame.Position")
	src = src:gsub("crackle%.IsPlaying", "false")
	src = src:gsub("a%.Position %*= scale", "a.CFrame = a.CFrame + a.CFrame.Position * (scale - 1)")
	local menv = table.clone(env)
	menv.script = mod
	local fn = luau.load(src, { debugName = mod.Name, environment = menv, injectGlobals = false })
	local result = fn()
	cache[mod] = result
	return result
end
env = {
	game = fakeGame,
	workspace = workspace,
	require = req,
	warn = function(...)
		local t = {}
		for i = 1, select("#", ...) do
			t[i] = tostring(select(i, ...))
		end
		problem("warn: " .. table.concat(t, " "))
	end,
	pcall = function(fn, ...)
		local r = table.pack(pcall(fn, ...))
		if not r[1] then
			table.insert(pcallFails, string.format("[t=%.2f] %s", simT - 1000, tostring(r[2])))
		end
		return table.unpack(r, 1, r.n)
	end,
	os = setmetatable({ clock = function()
		return simT
	end }, { __index = os }),
	task = {
		delay = function(t, fn, ...)
			schedule(t, fn, ...)
		end,
		spawn = function(fn, ...)
			fn(...)
		end,
		defer = function(fn, ...)
			schedule(0, fn, ...)
		end,
		wait = function()
			return 0
		end,
	},
	tick = function()
		return simT
	end,
}
for k, v in roblox do
	if type(k) == "string" and k:sub(1, 1):match("%u") then
		env[k] = v
	end
end
env.CFrame = CFrame
for _, k in ipairs({ "math", "string", "table", "typeof", "type", "pairs", "ipairs", "select", "tostring", "tonumber", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "next", "error", "assert", "print", "unpack", "utf8", "bit32", "buffer", "coroutine", "debug", "newproxy", "gcinfo", "xpcall" }) do
	if env[k] == nil then
		env[k] = base[k]
	end
end

local RS = game:GetService("ReplicatedStorage")
local Abilities = RS.Abilities
-- (Lune can't read a sound's id out of the place's newer AudioContent: give the pack's sounds one)
for _, d in ipairs(Abilities:GetDescendants()) do
	if d:IsA("Sound") then
		d.SoundId = "rbxassetid://1"
	end
end
local AbilityConfig = req(Abilities.AbilityConfig)
local BeamMath = req(Abilities.BeamMath)
local FX = req(Abilities.FX.AzureTideCannon)
local def = AbilityConfig.Abilities.AzureTideCannon
local TL = def.Timeline

---------------------------------------------------------------------------
-- the caster (an R6 rig holding its hands out) and a target
---------------------------------------------------------------------------
local function rig(name, at)
	local m = Instance.new("Model")
	m.Name = name
	local function limb(n, size, cf)
		local p = Instance.new("Part")
		p.Name = n
		p.Size = size
		p.CFrame = cf
		p.Parent = m
		return p
	end
	local r = CFrame.new(at)
	limb("HumanoidRootPart", Vector3.new(2, 2, 1), r).Transparency = 1
	limb("Torso", Vector3.new(2, 2, 1), r)
	limb("Head", Vector3.new(2, 1, 1), r * CFrame.new(0, 1.5, 0))
	limb("Right Arm", Vector3.new(1, 2, 1), r * CFrame.new(0.8, 0.4, -1.1) * CFrame.Angles(math.rad(90), 0, 0))
	limb("Left Arm", Vector3.new(1, 2, 1), r * CFrame.new(-0.8, 0.4, -1.1) * CFrame.Angles(math.rad(90), 0, 0))
	limb("Right Leg", Vector3.new(1, 2, 1), r * CFrame.new(0.5, -2, 0))
	limb("Left Leg", Vector3.new(1, 2, 1), r * CFrame.new(-0.5, -2, 0))
	m.PrimaryPart = m.HumanoidRootPart
	m.Parent = workspace
	return m
end
local caster = rig("Goki", Vector3.new(0, 3, 0))
local dummy = rig("Dummy", Vector3.new(0.6, 3, -30))
local aimDir = if scenario == "floor" then Vector3.new(0, -0.16, -1).Unit
	elseif scenario == "up" then Vector3.new(0.3, 0.4, -1).Unit
	else Vector3.new(0, 0, -1)
local o = {
	Caster = caster,
	Def = def,
	Started = simT,
	Mine = scenario ~= "others",
	Aim = function()
		-- (a slow sweep, as a caster turning)
		local a = math.sin((simT - 1000) * 0.6) * 0.15
		return (CFrame.Angles(0, a, 0) * CFrame.lookAt(Vector3.zero, aimDir)).LookVector
	end,
	Bodies = function()
		if scenario == "body" or scenario == "others" then
			return { { Key = dummy, Cf = dummy.HumanoidRootPart.CFrame } }
		end
		return {}
	end,
	World = world,
	Camera = function(profile, dir, scale)
		assert(type(profile) == "string", "Camera profile")
		assert(dir == nil or typeof(dir) == "Vector3", "Camera dir")
		assert(scale == nil or type(scale) == "number", "Camera scale")
	end,
	Fov = function(x)
		assert(type(x) == "number", "Fov")
	end,
	Track = function()
		return nil
	end,
}

---------------------------------------------------------------------------
-- run it
---------------------------------------------------------------------------
local h = FX.Start(o)
local DT = 1 / 60
local stopAt = if scenario == "interrupt" then TL.Fire + 1.2 elseif scenario == "fizzle" then 1.5 else TL.Fire + TL.Sustain
local stopWhy = if scenario == "interrupt" or scenario == "fizzle" then "Interrupted" else "Done"
local stopped = false
local destroyAt = if scenario == "destroy" then TL.Fire + 0.8 else nil
local peak = 0
local holder = workspace:FindFirstChild("AbilityFX")
local samples = {}
local END = TL.Fire + TL.Sustain + 14
local t = 0
while t < END do
	simT += DT
	t = simT - o.Started
	-- timers due
	table.sort(timers, function(a, b)
		return a.T < b.T
	end)
	while timers[1] and timers[1].T <= simT do
		local tm = table.remove(timers, 1)
		local ok, err = pcall(tm.Fn, table.unpack(tm.Args, 1, tm.Args.n))
		if not ok then
			problem("timer: " .. tostring(err))
		end
	end
	if not stopped and t >= stopAt then
		stopped = true
		h.Stop(stopWhy)
	end
	if destroyAt and t >= destroyAt then
		destroyAt = nil
		h.Destroy()
	end
	for name, fn in pairs(table.clone(bound)) do
		local ok, err = pcall(fn, DT)
		if not ok then
			problem("render " .. name .. ": " .. tostring(err))
		end
	end
	RenderStepped:Fire(DT)
	Heartbeat:Fire(DT)
	holder = workspace:FindFirstChild("AbilityFX")
	local fxm = holder and holder:FindFirstChild("AzureTide_Goki")
	if fxm and math.abs((t * 4) - math.floor(t * 4 + 0.5)) < 0.01 and t > TL.Fire - 0.1 and process.env.PROBE then
		local function sz(n)
			local p = fxm:FindFirstChild(n)
			if not p then
				return "-"
			end
			if p.Transparency >= 1 then
				return "hid"
			end
			return string.format("(%.1f,%.1f,%.1f)@(%.1f,%.1f,%.1f) tr%.2f", p.Size.X, p.Size.Y, p.Size.Z, p.CFrame.Position.X, p.CFrame.Position.Y, p.CFrame.Position.Z, p.Transparency)
		end
		print(string.format("t=%.2f core %s | shell %s | shellFlare %s | ball %s | skin %s", t, sz("Core"), sz("Shell"), sz("ShellFlare"), sz("EndBody"), sz("EndSkin")))
	end
	local blast = holder and holder:FindFirstChild("AzureTideBlast")
	if blast and process.env.PROBE and math.abs((t * 10) - math.floor(t * 10 + 0.5)) < 0.01 then
		local counts, big = {}, 0
		local bigName = ""
		for _, d in ipairs(blast:GetDescendants()) do
			counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
			if d:IsA("BasePart") and d.Transparency < 1 then
				local m = math.max(d.Size.X, d.Size.Y, d.Size.Z)
				if m > big then
					big, bigName = m, d.Name .. "/" .. d.Material.Name
				end
			end
		end
		local cl = {}
		for k, v in pairs(counts) do
			table.insert(cl, k .. "=" .. v)
		end
		table.sort(cl)
		print(string.format("blast t=%.1f biggest %.1f (%s) | %s", t, big, bigName, table.concat(cl, " ")))
	end
	if holder then
		local n = #holder:GetDescendants()
		peak = math.max(peak, n)
		local sec = math.floor(t * 4) / 4
		if not samples[sec] then
			samples[sec] = n
		end
	end
end
-- the end ball and the beam, as last drawn: a check on their shapes
local out = {}
table.insert(out, string.format("scenario %s: phase %s alive %s, peak %d instances, %d emitted, %d rods moved", scenario, tostring(h.Phase), tostring(h.Alive), peak, emitted, moved))
local keys = {}
for k in pairs(samples) do
	table.insert(keys, k)
end
table.sort(keys)
local line = {}
for _, k in ipairs(keys) do
	if math.abs(k - math.floor(k)) < 1e-6 then
		table.insert(line, string.format("%gs:%d", k, samples[k]))
	end
end
table.insert(out, "instances in AbilityFX: " .. table.concat(line, " "))
holder = workspace:FindFirstChild("AbilityFX")
table.insert(out, "left at the end: " .. (if holder then #holder:GetChildren() else 0) .. " (pending timers " .. #timers .. ")")
if holder then
	for _, c in ipairs(holder:GetChildren()) do
		table.insert(out, "  left: " .. c.ClassName .. " " .. c.Name .. " (" .. #c:GetDescendants() .. ")")
	end
end
local hit0 = 0
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("ColorCorrectionEffect") or d:IsA("BlurEffect") then
		hit0 += 1
	end
end
table.insert(out, "screen effects left on the camera: " .. hit0)
for _, l in ipairs(out) do
	print(l)
end
for _, p in ipairs(problems) do
	print("PROBLEM", p)
end
local seen = {}
for _, p in ipairs(pcallFails) do
	local key = p:gsub("^%[t=[%d%.%-]+%] ", "")
	if not seen[key] then
		seen[key] = true
		print("PCALL-FAIL", p)
	end
end
if #problems > 0 then
	process.exit(1)
end
