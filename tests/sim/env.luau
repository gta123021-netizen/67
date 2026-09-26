--!nocheck
--[[
	A headless stand-in for the parts of the Roblox engine the combat SERVER uses, so the real
	CombatService / HitDetect / ComboRules / CombatConfig / CombatStates / CombatPaths modules can be
	loaded from src/ and driven frame by frame:
	  - a simulated clock (os.clock) and task scheduler (task.delay / spawn / defer / wait) and a
	    60 Hz Heartbeat (RunService.Heartbeat:Connect / :Wait)
	  - bodies: a Model / Humanoid / HumanoidRootPart per fighter (position, facing, health, Died,
	    attributes), a flat ground at y = 0 and optional solid boxes (walls) for the ray casts
	  - Motion (physics-lite: a drive moves the root by its velocity every frame), Ragdoll and
	    AnimController as stubs (no joints, no animation in a headless run)
	  - the CombatEvent remote records everything the server sends
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local CF = require("./cframe")
local V3 = roblox.Vector3

local Env = {}
Env.Vector3 = V3
Env.CFrame = CF

---------------------------------------------------------------------------
-- clock + scheduler
---------------------------------------------------------------------------
local clock = 0
local timers = {} -- { t, seq, fn, args }
local seqN = 0
local heartbeat = {} -- connections
local waiters = {} -- coroutines waiting for the next heartbeat

function Env.now()
	return clock
end

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
end

local function schedule(t, fn, ...)
	seqN += 1
	table.insert(timers, { t = t, seq = seqN, fn = fn, args = table.pack(...) })
end

local task = {}
function task.spawn(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	resume(co, ...)
	return co
end
function task.defer(fn, ...)
	schedule(clock, function(...)
		task.spawn(fn, ...)
	end, ...)
end
function task.delay(t, fn, ...)
	schedule(clock + math.max(0, t or 0), function(...)
		task.spawn(fn, ...)
	end, ...)
end
function task.wait(t)
	local co = coroutine.running()
	local start = clock
	schedule(clock + math.max(t or 0, 1 / 60), function()
		resume(co, clock - start)
	end)
	return coroutine.yield()
end
Env.task = task

---------------------------------------------------------------------------
-- signals
---------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ Conns = {} }, Signal)
end
function Signal:Connect(fn)
	local c = { Fn = fn, Connected = true }
	table.insert(self.Conns, c)
	function c.Disconnect()
		c.Connected = false
	end
	c.disconnect = c.Disconnect
	return setmetatable(c, { __index = { Disconnect = function(self2)
		self2.Connected = false
	end } })
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Fire(...)
	for _, c in ipairs(table.clone(self.Conns)) do
		if c.Connected then
			task.spawn(c.Fn, ...)
		end
	end
end
function Signal:Wait()
	local co = coroutine.running()
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		resume(co, ...)
	end)
	return coroutine.yield()
end
Env.Signal = Signal

local Heartbeat = {}
function Heartbeat:Connect(fn)
	local c = { Fn = fn, Connected = true }
	table.insert(heartbeat, c)
	return setmetatable(c, { __index = { Disconnect = function(self2)
		self2.Connected = false
	end } })
end
function Heartbeat:Wait()
	table.insert(waiters, coroutine.running())
	return coroutine.yield()
end

-- advance the world by one frame
function Env.step(dt)
	dt = dt or 1 / 60
	clock += dt
	-- timers due (in time order; ones added while running wait for their own time)
	while true do
		local best, bi = nil, nil
		for i, tm in ipairs(timers) do
			if tm.t <= clock + 1e-9 and (not best or tm.t < best.t or (tm.t == best.t and tm.seq < best.seq)) then
				best, bi = tm, i
			end
		end
		if not best then
			break
		end
		table.remove(timers, bi)
		best.fn(table.unpack(best.args, 1, best.args.n))
	end
	for _, c in ipairs(table.clone(heartbeat)) do
		if c.Connected then
			c.Fn(dt)
		end
	end
	local w = waiters
	waiters = {}
	for _, co in ipairs(w) do
		resume(co, dt)
	end
end

function Env.run(seconds)
	local frames = math.max(1, math.floor(seconds * 60 + 0.5))
	for _ = 1, frames do
		Env.step(1 / 60)
	end
end

---------------------------------------------------------------------------
-- world: ground + boxes, ray casts
---------------------------------------------------------------------------
local boxes = {} -- { Min, Max, CanCollide, Name }
Env.boxes = boxes
Env.groundY = 0
Env.voids = {} -- { Center, Radius }: holes in the ground (a ledge / the void)

function Env.addBox(name, min, max, canCollide)
	table.insert(boxes, { Name = name, Min = min, Max = max, CanCollide = canCollide ~= false })
end

local function rayBox(o, d, b)
	local tmin, tmax = 0, 1
	local n = nil
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local oa, da, lo, hi = o[axis], d[axis], b.Min[axis], b.Max[axis]
		if math.abs(da) < 1e-9 then
			if oa < lo or oa > hi then
				return nil
			end
		else
			local t1, t2 = (lo - oa) / da, (hi - oa) / da
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin = t1
				n = if axis == "X" then V3.new(s, 0, 0) elseif axis == "Y" then V3.new(0, s, 0) else V3.new(0, 0, s)
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin, n or V3.new(0, 1, 0)
end

local workspace = { Name = "Workspace", _attrs = {} }
function workspace:GetAttribute(k)
	return self._attrs[k]
end
function workspace:SetAttribute(k, v)
	self._attrs[k] = v
end
function workspace:GetServerTimeNow()
	return 1000 + clock
end
function workspace:Raycast(o, d, params)
	local best, bestN, bestInst = nil, nil, nil
	-- the ground plane (except over a void)
	if d.Y < 0 and o.Y >= Env.groundY then
		local t = (Env.groundY - o.Y) / d.Y
		if t <= 1 then
			local p = o + d * t
			local hole = false
			for _, v in ipairs(Env.voids) do
				if (V3.new(p.X, 0, p.Z) - V3.new(v.Center.X, 0, v.Center.Z)).Magnitude < v.Radius then
					hole = true
				end
			end
			if not hole then
				best, bestN, bestInst = t, V3.new(0, 1, 0), { Name = "Ground" }
			end
		end
	end
	for _, b in ipairs(boxes) do
		if b.CanCollide or not (params and params.RespectCanCollide) then
			local t, n = rayBox(o, d, b)
			if t and (not best or t < best) then
				best, bestN, bestInst = t, n, b
			end
		end
	end
	if not best then
		return nil
	end
	return { Position = o + d * best, Normal = bestN, Instance = bestInst, Material = roblox.Enum.Material.Plastic }
end
Env.workspace = workspace

---------------------------------------------------------------------------
-- fighters
---------------------------------------------------------------------------
local Players = { PlayerRemoving = Signal.new(), PlayerAdded = Signal.new(), _list = {} }
function Players:GetPlayers()
	return self._list
end
Env.Players = Players

local function isA(self, c)
	return self.ClassName == c or (c == "BasePart" and self.ClassName == "Part") or (c == "GuiButton" and false)
end

function Env.character(name, pos, look)
	local attrs = {}
	local char = { Name = name, ClassName = "Model", Parent = workspace, IsA = isA }
	char.AncestryChanged = Signal.new()
	char.DescendantAdded = Signal.new()
	char._attrs = attrs
	function char:SetAttribute(k, v)
		attrs[k] = v
	end
	function char:GetAttribute(k)
		return attrs[k]
	end
	function char:GetAttributeChangedSignal()
		return Signal.new()
	end
	local hum = { Name = "Humanoid", ClassName = "Humanoid", Health = 100, MaxHealth = 100, Parent = char, Died = Signal.new(), AutoRotate = true, IsA = isA }
	function hum:TakeDamage(d)
		if self.Health <= 0 then
			return
		end
		self.Health = math.max(0, self.Health - d)
		if self.Health <= 0 then
			self.Died:Fire()
		end
	end
	function hum:ChangeState() end
	local rootData = { CFrame = CF.lookAt(pos, pos + (look or V3.new(0, 0, -1))), AssemblyLinearVelocity = V3.zero }
	local root = setmetatable({ Name = "HumanoidRootPart", ClassName = "Part", Parent = char, IsA = isA, Anchored = false, CollisionGroup = "Default" }, {
		__index = function(_, k)
			if k == "Position" then
				return rootData.CFrame.Position
			end
			return rootData[k]
		end,
		__newindex = function(t, k, v)
			if k == "Position" then
				local cf = rootData.CFrame
				rootData.CFrame = cf + (v - cf.Position)
			elseif k == "CFrame" or k == "AssemblyLinearVelocity" then
				rootData[k] = v
			else
				rawset(t, k, v)
			end
		end,
	})
	function root:SetNetworkOwner() end
	char.Humanoid = hum
	char.HumanoidRootPart = root
	function char:FindFirstChildOfClass(c)
		return if c == "Humanoid" then hum else nil
	end
	function char:FindFirstChild(n)
		return if n == "HumanoidRootPart" then root elseif n == "Humanoid" then hum else nil
	end
	function char:GetDescendants()
		return { hum, root }
	end
	function char:Destroy()
		self.Parent = nil
		root.Parent = nil
		self.AncestryChanged:Fire(self, nil)
	end
	return char
end

function Env.player(name, ping, char)
	local p = { Name = name, ClassName = "Player", UserId = #Players._list + 1, Character = char, _ping = ping or 0.05, IsA = isA }
	function p:GetNetworkPing()
		return self._ping
	end
	table.insert(Players._list, p)
	return p
end

-- place a fighter: position (feet on the ground unless y given) and facing
function Env.place(char, x, z, lookX, lookZ, y)
	local pos = V3.new(x, y or (Env.groundY + 3), z)
	char.HumanoidRootPart.CFrame = CF.lookAt(pos, pos + V3.new(lookX or 0, 0, lookZ or -1))
end
function Env.face(char, target)
	local r = char.HumanoidRootPart
	local p = r.Position
	local t = (typeof(target) == "Vector3") and target or target.HumanoidRootPart.Position
	r.CFrame = CF.lookAt(p, V3.new(t.X, p.Y, t.Z))
end

---------------------------------------------------------------------------
-- engine-side stubs of the combat modules that need a real engine
---------------------------------------------------------------------------
local Motion = {}
local drives = {}
function Motion.Stop(root)
	local d = drives[root]
	if d then
		d.Serial += 1
		drives[root] = nil
	end
end
function Motion.Drive(root, duration, velocityAt, opts)
	Motion.Stop(root)
	local d = { Serial = 0, T0 = clock }
	drives[root] = d
	local serial = d.Serial
	local conn
	conn = Heartbeat:Connect(function(dt)
		if d.Serial ~= serial or root.Parent == nil then
			conn:Disconnect()
			return
		end
		local t = clock - d.T0
		if t >= duration then
			conn:Disconnect()
			if drives[root] == d then
				drives[root] = nil
			end
			return
		end
		local v = velocityAt(t)
		root.CFrame = root.CFrame + V3.new(v.X, 0, v.Z) * dt
	end)
	return serial
end
function Motion.Push(root, vec, duration)
	local flat = V3.new(vec.X, 0, vec.Z)
	if duration <= 0 or flat.Magnitude < 0.5 then
		return
	end
	Motion.Drive(root, duration, function(t)
		local k = 1 - t / duration
		return flat * (0.35 + 0.65 * k * k)
	end)
end

local Ragdoll = {}
function Ragdoll.Setup()
	return true
end
function Ragdoll.Enable(char)
	char:SetAttribute("Ragdolled", true)
end
function Ragdoll.Disable(char)
	char:SetAttribute("Ragdolled", false)
end
function Ragdoll.StandUp() end
function Ragdoll.ApplyFall() end

local track = { IsPlaying = true, Speed = 1 }
function track:AdjustSpeed(s)
	self.Speed = s
end
function track:Stop() end
local AnimController = {}
function AnimController.get()
	local ac = {}
	function ac:Play()
		return track
	end
	ac.PlayFresh = ac.Play
	ac.Track = ac.Play
	function ac:Stop() end
	function ac:StopMany() end
	function ac:IsPlaying()
		return false
	end
	function ac:Destroy() end
	return ac
end
function AnimController.Preload() end

---------------------------------------------------------------------------
-- remotes + the instance tree the modules walk
---------------------------------------------------------------------------
Env.events = {}
local function remote(name)
	local r = { Name = name, ClassName = "RemoteEvent" }
	function r:FireAllClients(kind, data)
		table.insert(Env.events, { To = "all", Kind = kind, Data = data, T = clock })
	end
	function r:FireClient(p, kind, data)
		table.insert(Env.events, { To = p, Kind = kind, Data = data, T = clock })
	end
	r.OnServerEvent = Signal.new()
	return r
end

local SRC = "src/"
local modules = {} -- path -> module value
local moduleFiles = {
	["ReplicatedStorage/Combat/CombatConfig"] = "ReplicatedStorage__Combat__CombatConfig.lua",
	["ReplicatedStorage/Combat/CombatStates"] = "ReplicatedStorage__Combat__CombatStates.lua",
	["ReplicatedStorage/Combat/ComboRules"] = "ReplicatedStorage__Combat__ComboRules.lua",
	["ReplicatedStorage/Combat/CombatPaths"] = "ReplicatedStorage__Combat__CombatPaths.lua",
	["ServerScriptService/Combat/HitDetect"] = "ServerScriptService__Combat__HitDetect.lua",
	["ServerScriptService/Combat/CombatService"] = "ServerScriptService__Combat__CombatService.lua",
	["ReplicatedStorage/OverkillUI/Theme"] = "ReplicatedStorage__OverkillUI__Theme.lua",
}
modules["ReplicatedStorage/Combat/Motion"] = Motion
modules["ReplicatedStorage/Combat/Ragdoll"] = Ragdoll
modules["ReplicatedStorage/Combat/AnimController"] = AnimController
Env.Motion = Motion

local function node(path, children)
	local n = { __path = path, Name = string.match(path, "[^/]+$"), _children = children or {} }
	function n:WaitForChild(name)
		local c = self._children[name]
		if c then
			return c
		end
		c = { __path = self.__path .. "/" .. name, Name = name }
		self._children[name] = c
		return c
	end
	n.FindFirstChild = function(self, name)
		return self._children[name]
	end
	return n
end
local combatFolder = node("ReplicatedStorage/Combat", {
	CombatEvent = remote("CombatEvent"),
	CombatRequest = remote("CombatRequest"),
})
local rs = node("ReplicatedStorage", { Combat = combatFolder })
local sssCombat = node("ServerScriptService/Combat")
local services = {
	ReplicatedStorage = rs,
	ServerScriptService = node("ServerScriptService", { Combat = sssCombat }),
	ServerStorage = { FindFirstChild = function()
		return nil
	end },
	Players = Players,
	RunService = {
		Heartbeat = Heartbeat,
		RenderStepped = Heartbeat,
		IsStudio = function()
			return true
		end,
		IsServer = function()
			return true
		end,
	},
	PhysicsService = {
		IsCollisionGroupRegistered = function()
			return true
		end,
		RegisterCollisionGroup = function() end,
		CollisionGroupSetCollidable = function() end,
	},
	Debris = { AddItem = function() end },
	ContentProvider = { PreloadAsync = function() end },
}
local game = {}
function game:GetService(name)
	return services[name] or error("no service " .. name)
end
Env.game = game

local RaycastParams = {}
function RaycastParams.new()
	return { FilterType = nil, FilterDescendantsInstances = {}, RespectCanCollide = false, IgnoreWater = false }
end

local Instance = {}
function Instance.new(class)
	return { ClassName = class, Name = class }
end

local loadModule
-- the REAL module file for a path the simulation normally stubs (Motion): for pure-function tests
function Env.loadReal(path, file)
	moduleFiles[path] = file
	local stub = modules[path]
	modules[path] = nil
	local real = loadModule(path)
	modules[path] = stub
	return real
end

function loadModule(path)
	if modules[path] ~= nil then
		return modules[path]
	end
	local file = moduleFiles[path]
	if not file then
		error("no module " .. path)
	end
	local parentPath = string.match(path, "^(.*)/[^/]+$")
	local parent = if parentPath == "ServerScriptService/Combat" then sssCombat else combatFolder
	local scriptObj = { Name = string.match(path, "[^/]+$"), Parent = parent }
	local env
	env = setmetatable({
		game = game,
		workspace = workspace,
		script = scriptObj,
		task = task,
		Vector3 = V3,
		Vector2 = roblox.Vector2,
		CFrame = CF,
		Color3 = roblox.Color3,
		Font = roblox.Font,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Instance = Instance,
		RaycastParams = RaycastParams,
		os = setmetatable({ clock = function()
			return clock
		end }, { __index = os }),
		require = function(inst)
			return loadModule(inst.__path)
		end,
		warn = function(...)
			print("[warn]", ...)
		end,
	}, { __index = _G })
	local src = fs.readFile(SRC .. file)
	local fn = luau.load(src, { debugName = path, environment = env })
	local value = fn()
	modules[path] = value
	return value
end
Env.load = loadModule

return Env
