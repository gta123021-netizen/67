--[[
	rbxmock.lua - a small stand-in for the Roblox engine, enough to RUN the combat's client modules
	outside Studio (tools/tests): Vector3 / CFrame / Color3 / sequences, Instances with properties,
	children, attributes and signals, a workspace with a tiny scene to raycast against (a floor, a
	wall, a ledge, a ceiling), RunService.Heartbeat, task.* on a virtual clock, and require() of the
	src/ files. It checks that the code runs (no nil index, no bad call) - not what it looks like.

	  local M = dofile-ish: loadchunk(readfile("tools/tests/rbxmock.lua"), "rbxmock")()
	  M.step(dt)          advance the virtual clock one frame (Heartbeat, due tasks)
	  M.run(seconds, dt)  many frames
]]

local M = {}

---------------------------------------------------------------------------
-- typeof (tables with a __type metafield)
---------------------------------------------------------------------------
local rawtypeof = typeof
function typeof(x)
	if type(x) == "table" then
		local mt = getmetatable(x)
		if type(mt) == "table" and rawget(mt, "__type") then
			return rawget(mt, "__type")
		end
	end
	return rawtypeof(x)
end

---------------------------------------------------------------------------
-- Vector3 / Vector2
---------------------------------------------------------------------------
local V3 = { __type = "Vector3" }
V3.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return Vector3.new(0 / 0, 0 / 0, 0 / 0)
		end
		return Vector3.new(v.X / m, v.Y / m, v.Z / m)
	end
	local f = rawget(V3, k)
	if f then
		return f
	end
	error("Vector3 has no member " .. tostring(k), 2)
end
local function isV3(x)
	return type(x) == "table" and getmetatable(x) == V3
end
Vector3 = {}
function Vector3.new(x, y, z)
	x, y, z = x or 0, y or 0, z or 0
	assert(type(x) == "number" and type(y) == "number" and type(z) == "number", "Vector3.new needs numbers")
	return setmetatable({ X = x, Y = y, Z = z }, V3)
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)
V3.__add = function(a, b)
	assert(isV3(a) and isV3(b), "Vector3 + non-Vector3")
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	assert(isV3(a) and isV3(b), "Vector3 - non-Vector3")
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	if type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	assert(isV3(b), "Vector3 * bad")
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return Vector3.new(a.X / b, a.Y / b, a.Z / b)
	end
	return Vector3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__unm = function(a)
	return Vector3.new(-a.X, -a.Y, -a.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3.__tostring = function(v)
	return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z)
end
function V3.Dot(a, b)
	assert(isV3(b), "Dot with non-Vector3")
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3.Cross(a, b)
	assert(isV3(b), "Cross with non-Vector3")
	return Vector3.new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V3.Lerp(a, b, t)
	return a + (b - a) * t
end
function V3.Abs(a)
	return Vector3.new(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
end
function V3.FuzzyEq(a, b, e)
	return (a - b).Magnitude <= (e or 1e-5)
end
function V3.Max(a, b)
	return Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end
function V3.Min(a, b)
	return Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end

local V2 = { __type = "Vector2" }
V2.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y)
		return Vector2.new(v.X / m, v.Y / m)
	end
	return rawget(V2, k)
end
Vector2 = {}
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
Vector2.zero = Vector2.new(0, 0)
V2.__add = function(a, b)
	return Vector2.new(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	return Vector2.new(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	if type(b) == "number" then
		return Vector2.new(a.X * b, a.Y * b)
	end
	return Vector2.new(a.X * b.X, a.Y * b.Y)
end

---------------------------------------------------------------------------
-- CFrame (rotation columns R, U, B: right, up, back = -look)
---------------------------------------------------------------------------
local CF = { __type = "CFrame" }
local function mkcf(p, r, u, b)
	return setmetatable({ P = p, R = r, U = u, B = b }, CF)
end
CF.__index = function(c, k)
	if k == "Position" or k == "p" then
		return c.P
	elseif k == "X" then
		return c.P.X
	elseif k == "Y" then
		return c.P.Y
	elseif k == "Z" then
		return c.P.Z
	elseif k == "RightVector" or k == "XVector" then
		return c.R
	elseif k == "UpVector" or k == "YVector" then
		return c.U
	elseif k == "LookVector" then
		return -c.B
	elseif k == "ZVector" then
		return c.B
	end
	local f = rawget(CF, k)
	if f then
		return f
	end
	error("CFrame has no member " .. tostring(k), 2)
end
local function isCF(x)
	return type(x) == "table" and getmetatable(x) == CF
end
local function rot(c, v) -- rotate a vector
	return c.R * v.X + c.U * v.Y + c.B * v.Z
end
local function irot(c, v)
	return Vector3.new(c.R:Dot(v), c.U:Dot(v), c.B:Dot(v))
end
CFrame = {}
function CFrame.new(a, b, c, ...)
	local extra = { ... }
	if a == nil then
		return mkcf(Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
	end
	if isV3(a) then
		if isV3(b) then
			return CFrame.lookAt(a, b)
		end
		return mkcf(a, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
	end
	if #extra == 9 then
		local r00, r01, r02, r10, r11, r12, r20, r21, r22 = table.unpack(extra)
		return mkcf(Vector3.new(a, b, c), Vector3.new(r00, r10, r20), Vector3.new(r01, r11, r21), Vector3.new(r02, r12, r22))
	end
	return mkcf(Vector3.new(a, b or 0, c or 0), Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
end
CFrame.identity = CFrame.new()
function CFrame.fromMatrix(p, vx, vy, vz)
	vz = vz or vx:Cross(vy).Unit
	return mkcf(p, vx, vy, vz)
end
function CFrame.lookAt(p, target, up)
	up = up or Vector3.yAxis
	local look = (target - p)
	if look.Magnitude < 1e-9 then
		return mkcf(p, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
	end
	look = look.Unit
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then
		right = look:Cross(Vector3.zAxis)
		if right.Magnitude < 1e-6 then
			right = look:Cross(Vector3.xAxis)
		end
	end
	right = right.Unit
	local u = right:Cross(look).Unit
	return mkcf(p, right, u, -look)
end
local function axisAngle(axis, a)
	axis = axis.Unit
	local c, s = math.cos(a), math.sin(a)
	local function r(v)
		return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
	end
	return mkcf(Vector3.zero, r(Vector3.xAxis), r(Vector3.yAxis), r(Vector3.zAxis))
end
CFrame.fromAxisAngle = axisAngle
function CFrame.Angles(rx, ry, rz)
	return axisAngle(Vector3.xAxis, rx) * axisAngle(Vector3.yAxis, ry) * axisAngle(Vector3.zAxis, rz)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.fromOrientation(rx, ry, rz)
	return axisAngle(Vector3.yAxis, ry) * axisAngle(Vector3.xAxis, rx) * axisAngle(Vector3.zAxis, rz)
end
CF.__mul = function(a, b)
	if isCF(b) then
		return mkcf(a.P + rot(a, b.P), rot(a, b.R), rot(a, b.U), rot(a, b.B))
	end
	assert(isV3(b), "CFrame * bad operand")
	return a.P + rot(a, b)
end
CF.__add = function(a, b)
	assert(isV3(b), "CFrame + non-Vector3")
	return mkcf(a.P + b, a.R, a.U, a.B)
end
CF.__sub = function(a, b)
	assert(isV3(b), "CFrame - non-Vector3")
	return mkcf(a.P - b, a.R, a.U, a.B)
end
CF.__eq = function(a, b)
	return a.P == b.P and a.R == b.R and a.U == b.U and a.B == b.B
end
function CF.Inverse(c)
	-- transpose
	local R = Vector3.new(c.R.X, c.U.X, c.B.X)
	local U = Vector3.new(c.R.Y, c.U.Y, c.B.Y)
	local B = Vector3.new(c.R.Z, c.U.Z, c.B.Z)
	local inv = mkcf(Vector3.zero, R, U, B)
	return mkcf(-rot(inv, c.P), R, U, B)
end
function CF.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function CF.ToWorldSpace(a, b)
	return a * b
end
function CF.PointToObjectSpace(c, v)
	return irot(c, v - c.P)
end
function CF.PointToWorldSpace(c, v)
	return c.P + rot(c, v)
end
function CF.VectorToObjectSpace(c, v)
	return irot(c, v)
end
function CF.VectorToWorldSpace(c, v)
	return rot(c, v)
end
function CF.Lerp(a, b, t)
	local r = if t < 0.5 then a else b
	return mkcf(a.P:Lerp(b.P, t), r.R, r.U, r.B)
end
function CF.GetComponents(c)
	return c.P.X, c.P.Y, c.P.Z, c.R.X, c.U.X, c.B.X, c.R.Y, c.U.Y, c.B.Y, c.R.Z, c.U.Z, c.B.Z
end
function CF.ToEulerAnglesXYZ(_c)
	return 0, 0, 0
end
function CF.ToOrientation(_c)
	return 0, 0, 0
end

---------------------------------------------------------------------------
-- colours, sequences, ranges, UDim
---------------------------------------------------------------------------
local C3 = { __type = "Color3" }
C3.__index = C3
Color3 = {}
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h, s, v)
	return Color3.new(v, v, v)
end
function C3.Lerp(a, b, t)
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
function C3.ToHSV(c)
	return 0, 0, math.max(c.R, c.G, c.B)
end
C3.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end

local function simple(name, fields)
	local mt = { __type = name }
	mt.__index = mt
	local T = {}
	function T.new(...)
		local o = setmetatable({}, mt)
		local args = { ... }
		for i, f in ipairs(fields) do
			o[f] = args[i]
		end
		return o
	end
	return T, mt
end
local NR_mt
NumberRange, NR_mt = simple("NumberRange", { "Min", "Max" })
local nrnew = NumberRange.new
NumberRange.new = function(a, b)
	return nrnew(a, b or a)
end
NumberSequenceKeypoint = simple("NumberSequenceKeypoint", { "Time", "Value", "Envelope" })
local nskp = NumberSequenceKeypoint.new
NumberSequenceKeypoint.new = function(t, v, e)
	return nskp(t, v, e or 0)
end
ColorSequenceKeypoint = simple("ColorSequenceKeypoint", { "Time", "Value" })
local NS_mt = { __type = "NumberSequence" }
NS_mt.__index = NS_mt
NumberSequence = {}
function NumberSequence.new(a, b)
	local kps
	if type(a) == "number" then
		kps = { NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b or a) }
	else
		kps = a
	end
	return setmetatable({ Keypoints = kps }, NS_mt)
end
local CS_mt = { __type = "ColorSequence" }
CS_mt.__index = CS_mt
ColorSequence = {}
function ColorSequence.new(a, b)
	local kps
	if typeof(a) == "Color3" then
		kps = { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b or a) }
	else
		kps = a
	end
	return setmetatable({ Keypoints = kps }, CS_mt)
end
UDim = simple("UDim", { "Scale", "Offset" })
local UD2mt
UDim2, UD2mt = simple("UDim2", { "XS", "XO", "YS", "YO" })
function UDim2.fromScale(x, y)
	return UDim2.new(x, 0, y, 0)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end
UD2mt.__add = function(a, b)
	return UDim2.new(a.XS + b.XS, a.XO + b.XO, a.YS + b.YS, a.YO + b.YO)
end
UD2mt.__sub = function(a, b)
	return UDim2.new(a.XS - b.XS, a.XO - b.XO, a.YS - b.YS, a.YO - b.YO)
end
PhysicalProperties = simple("PhysicalProperties", { "Density", "Friction", "Elasticity", "FrictionWeight", "ElasticityWeight" })
TweenInfo = simple("TweenInfo", { "Time", "EasingStyle", "EasingDirection", "RepeatCount", "Reverses", "DelayTime" })
Random = {}
function Random.new()
	return {
		NextNumber = function(_, a, b)
			a, b = a or 0, b or 1
			return a + math.random() * (b - a)
		end,
		NextInteger = function(_, a, b)
			return math.random(a, b)
		end,
	}
end

---------------------------------------------------------------------------
-- Enum: Enum.X.Y is one object per name (compared by identity)
---------------------------------------------------------------------------
local enumCache = {}
local EI = { __type = "EnumItem" }
EI.__index = EI
EI.__tostring = function(e)
	return "Enum." .. e.EnumType .. "." .. e.Name
end
Enum = setmetatable({}, {
	__index = function(_, typ)
		local t = enumCache[typ]
		if not t then
			local n = 0
			t = setmetatable({}, {
				__index = function(tt, name)
					n += 1
					local item = setmetatable({ Name = name, EnumType = typ, Value = n }, EI)
					rawset(tt, name, item)
					return item
				end,
			})
			t.GetEnumItems = function()
				return {}
			end
			enumCache[typ] = t
		end
		return t
	end,
})

---------------------------------------------------------------------------
-- the virtual clock and task
---------------------------------------------------------------------------
local clock = 1000
os.clock = function()
	return clock
end
tick = os.clock
local tasks = {}
local function schedule(at, fn, ...)
	table.insert(tasks, { At = at, Fn = fn, Args = table.pack(...) })
end
task = {}
function task.delay(t, fn, ...)
	schedule(clock + math.max(t or 0, 0), fn, ...)
end
function task.defer(fn, ...)
	schedule(clock, fn, ...)
end
function task.spawn(fn, ...)
	if type(fn) == "thread" then
		coroutine.resume(fn, ...)
		return fn
	end
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(err, 0)
	end
	return co
end
function task.wait(t)
	local co = coroutine.running()
	schedule(clock + (t or 0), function()
		local ok, err = coroutine.resume(co)
		if not ok then
			error(err, 0)
		end
	end)
	coroutine.yield()
	return t or 0
end
wait = task.wait
spawn = task.spawn
delay = task.delay
function warn(...)
	local parts = {}
	for _, v in ipairs({ ... }) do
		table.insert(parts, tostring(v))
	end
	M.Warnings = (M.Warnings or 0) + 1
	print("WARN: " .. table.concat(parts, " "))
end

---------------------------------------------------------------------------
-- signals
---------------------------------------------------------------------------
local function Signal()
	local s = { Conns = {} }
	function s:Connect(fn)
		local c = { Connected = true, Fn = fn }
		function c:Disconnect()
			c.Connected = false
		end
		table.insert(s.Conns, c)
		return c
	end
	s.Once = function(self, fn)
		local c
		c = self:Connect(function(...)
			c:Disconnect()
			fn(...)
		end)
		return c
	end
	function s:Fire(...)
		local list = table.clone(s.Conns)
		for _, c in ipairs(list) do
			if c.Connected then
				c.Fn(...)
			end
		end
		-- (drop the disconnected)
		for i = #s.Conns, 1, -1 do
			if not s.Conns[i].Connected then
				table.remove(s.Conns, i)
			end
		end
	end
	function s:Wait()
		local co = coroutine.running()
		local c
		c = s:Connect(function(...)
			c:Disconnect()
			coroutine.resume(co, ...)
		end)
		return coroutine.yield()
	end
	function s:Count()
		local n = 0
		for _, c in ipairs(s.Conns) do
			if c.Connected then
				n += 1
			end
		end
		return n
	end
	return s
end
M.Signal = Signal

---------------------------------------------------------------------------
-- Instances
---------------------------------------------------------------------------
local ISA = {
	Part = { "BasePart", "PVInstance" },
	MeshPart = { "BasePart", "PVInstance" },
	UnionOperation = { "BasePart", "PVInstance" },
	Terrain = { "BasePart", "PVInstance" },
	Model = { "PVInstance" },
	Workspace = { "Model", "PVInstance" },
	Weld = { "JointInstance" },
	Motor6D = { "JointInstance" },
	BallSocketConstraint = { "Constraint" },
	LinearVelocity = { "Constraint" },
	Script = { "LuaSourceContainer" },
	LocalScript = { "Script", "LuaSourceContainer" },
	ModuleScript = { "LuaSourceContainer" },
	ScreenGui = { "LayerCollector", "GuiBase" },
	Frame = { "GuiObject" },
	TextLabel = { "GuiObject" },
	ImageLabel = { "GuiObject" },
}
local DEFAULTS = {
	BasePart = { Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, Transparency = 0, LocalTransparencyModifier = 0, Size = Vector3.new(4, 1, 2), CFrame = CFrame.new(), AssemblyLinearVelocity = Vector3.zero, AssemblyAngularVelocity = Vector3.zero, Massless = false, Color = Color3.new(0.6, 0.6, 0.6), Reflectance = 0, CastShadow = true, AssemblyMass = 1 },
	Attachment = { CFrame = CFrame.new() },
	ParticleEmitter = { Enabled = true, Size = NumberSequence.new(1), Speed = NumberRange.new(5), Lifetime = NumberRange.new(1, 2), SpreadAngle = Vector2.new(0, 0), Acceleration = Vector3.zero, VelocityInheritance = 0, ZOffset = 0, TimeScale = 1, Rate = 10 },
	Trail = { Enabled = true, Lifetime = 1 },
	Motor6D = { C0 = CFrame.new(), C1 = CFrame.new(), Enabled = true },
	Weld = { C0 = CFrame.new(), C1 = CFrame.new(), Enabled = true },
	Humanoid = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpHeight = 7.2, HipHeight = 0, AutoRotate = true, MoveDirection = Vector3.zero, RigType = "R6" },
}
local Instance_mt = { __type = "Instance" }
local allInstances = setmetatable({}, { __mode = "k" })
M.Created = 0
M.Destroyed = 0

local function isA(obj, cls)
	local c = rawget(obj, "_class")
	if c == cls or cls == "Instance" then
		return true
	end
	for _, s in ipairs(ISA[c] or {}) do
		if s == cls then
			return true
		end
	end
	return false
end

local function worldCF(obj)
	local c = rawget(obj, "_class")
	if c == "Attachment" then
		local p = rawget(obj, "_parent")
		local base = if p and isA(p, "BasePart") then p.CFrame else CFrame.new()
		return base * obj.CFrame
	end
	return obj.CFrame
end

Instance_mt.__index = function(obj, k)
	local props = rawget(obj, "_props")
	if k == "Parent" then
		return rawget(obj, "_parent")
	elseif k == "Name" then
		return rawget(obj, "_name")
	elseif k == "ClassName" then
		return rawget(obj, "_class")
	elseif k == "WorldPosition" then
		return worldCF(obj).Position
	elseif k == "WorldCFrame" then
		return worldCF(obj)
	elseif k == "Position" and (isA(obj, "BasePart") or rawget(obj, "_class") == "Attachment") then
		return (props.CFrame or CFrame.new()).Position
	elseif k == "Orientation" then
		return Vector3.zero
	elseif k == "AssemblyRootPart" and isA(obj, "BasePart") then
		return obj
	end
	local m = rawget(Instance_mt, k)
	if m then
		return m
	end
	if props[k] ~= nil then
		return props[k]
	end
	local c = rawget(obj, "_class")
	local d = DEFAULTS[c] or (isA(obj, "BasePart") and DEFAULTS.BasePart) or nil
	if d and d[k] ~= nil then
		return d[k]
	end
	-- a child by name (obj.Child)
	for _, ch in ipairs(rawget(obj, "_children")) do
		if rawget(ch, "_name") == k then
			return ch
		end
	end
	local extra = rawget(obj, "_extra")
	if extra and extra[k] ~= nil then
		return extra[k]
	end
	return nil
end
local function setParent(obj, p)
	local old = rawget(obj, "_parent")
	if old == p then
		return
	end
	if rawget(obj, "_destroyed") then
		error("The Parent property of " .. tostring(rawget(obj, "_name")) .. " is locked", 3)
	end
	if old then
		local ch = rawget(old, "_children")
		for i, c in ipairs(ch) do
			if c == obj then
				table.remove(ch, i)
				break
			end
		end
	end
	rawset(obj, "_parent", p)
	if old then
		rawget(old, "_extra").ChildRemoved:Fire(obj)
	end
	if p then
		table.insert(rawget(p, "_children"), obj)
		rawget(p, "_extra").ChildAdded:Fire(obj)
	end
	local sig = rawget(obj, "_ancestry")
	if sig then
		sig:Fire(obj, p)
	end
	if p then
		-- DescendantAdded up the chain, for the instance and everything under it
		local added = { obj }
		for _, d in ipairs(obj:GetDescendants()) do
			table.insert(added, d)
		end
		local a = p
		while a do
			local da = rawget(a, "_descAdded")
			if da then
				for _, x in ipairs(added) do
					da:Fire(x)
				end
			end
			a = rawget(a, "_parent")
		end
	end
end
Instance_mt.__newindex = function(obj, k, v)
	if k == "Parent" then
		setParent(obj, v)
		return
	elseif k == "Name" then
		rawset(obj, "_name", v)
		return
	elseif k == "Position" and (isA(obj, "BasePart") or rawget(obj, "_class") == "Attachment") then
		local cf = obj.CFrame
		rawget(obj, "_props").CFrame = cf + (v - cf.Position)
		return
	elseif k == "WorldPosition" then
		return
	end
	if k == "Size" and isA(obj, "BasePart") then
		assert(isV3(v), "Size must be a Vector3")
		assert(v.X == v.X and v.Y == v.Y and v.Z == v.Z, "Size is NaN")
	end
	if k == "CFrame" then
		assert(isCF(v), "CFrame must be a CFrame, got " .. typeof(v))
		assert(v.P.X == v.P.X and v.P.Y == v.P.Y and v.P.Z == v.P.Z, "CFrame is NaN")
	end
	rawget(obj, "_props")[k] = v
	local sigs = rawget(obj, "_propSigs")
	if sigs and sigs[k] then
		sigs[k]:Fire()
	end
end
Instance_mt.__tostring = function(obj)
	return rawget(obj, "_name")
end

function Instance_mt.IsA(obj, cls)
	return isA(obj, cls)
end
function Instance_mt.FindFirstChild(obj, name, recursive)
	for _, c in ipairs(rawget(obj, "_children")) do
		if rawget(c, "_name") == name then
			return c
		end
	end
	if recursive then
		for _, c in ipairs(rawget(obj, "_children")) do
			local f = c:FindFirstChild(name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
Instance_mt.WaitForChild = function(obj, name)
	local c = obj:FindFirstChild(name)
	if not c then
		error("WaitForChild: no " .. tostring(name) .. " in " .. tostring(rawget(obj, "_name")), 2)
	end
	return c
end
function Instance_mt.FindFirstChildOfClass(obj, cls)
	for _, c in ipairs(rawget(obj, "_children")) do
		if rawget(c, "_class") == cls then
			return c
		end
	end
	return nil
end
function Instance_mt.FindFirstChildWhichIsA(obj, cls)
	for _, c in ipairs(rawget(obj, "_children")) do
		if isA(c, cls) then
			return c
		end
	end
	return nil
end
function Instance_mt.FindFirstAncestorOfClass(obj, cls)
	local p = rawget(obj, "_parent")
	while p do
		if rawget(p, "_class") == cls then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end
function Instance_mt.GetChildren(obj)
	return table.clone(rawget(obj, "_children"))
end
function Instance_mt.GetDescendants(obj)
	local out = {}
	local function walk(o)
		for _, c in ipairs(rawget(o, "_children")) do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(obj)
	return out
end
function Instance_mt.IsDescendantOf(obj, anc)
	local p = rawget(obj, "_parent")
	while p do
		if p == anc then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end
function Instance_mt.Destroy(obj)
	if rawget(obj, "_destroyed") then
		return
	end
	for _, c in ipairs(table.clone(rawget(obj, "_children"))) do
		c:Destroy()
	end
	setParent(obj, nil)
	rawset(obj, "_destroyed", true)
	M.Destroyed += 1
end
function Instance_mt.ClearAllChildren(obj)
	for _, c in ipairs(table.clone(rawget(obj, "_children"))) do
		c:Destroy()
	end
end
function Instance_mt.Clone(obj)
	local c = Instance.new(rawget(obj, "_class"))
	rawset(c, "_name", rawget(obj, "_name"))
	for k, v in pairs(rawget(obj, "_props")) do
		rawget(c, "_props")[k] = v
	end
	for k, v in pairs(rawget(obj, "_attrs")) do
		rawget(c, "_attrs")[k] = v
	end
	rawset(c, "_path", rawget(obj, "_path"))
	for _, ch in ipairs(rawget(obj, "_children")) do
		ch:Clone().Parent = c
	end
	return c
end
function Instance_mt.GetAttribute(obj, k)
	return rawget(obj, "_attrs")[k]
end
function Instance_mt.GetAttributes(obj)
	return table.clone(rawget(obj, "_attrs"))
end
function Instance_mt.SetAttribute(obj, k, v)
	local attrs = rawget(obj, "_attrs")
	if attrs[k] == v then
		return
	end
	attrs[k] = v
	local sigs = rawget(obj, "_attrSigs")
	if sigs and sigs[k] then
		sigs[k]:Fire()
	end
end
function Instance_mt.GetAttributeChangedSignal(obj, k)
	local sigs = rawget(obj, "_attrSigs")
	if not sigs[k] then
		sigs[k] = Signal()
	end
	return sigs[k]
end
function Instance_mt.GetPropertyChangedSignal(obj, k)
	local sigs = rawget(obj, "_propSigs")
	if not sigs[k] then
		sigs[k] = Signal()
	end
	return sigs[k]
end
function Instance_mt.GetMass(_obj)
	return 1
end
function Instance_mt.GetVelocityAtPosition(obj, _p)
	return obj.AssemblyLinearVelocity
end
function Instance_mt.Emit(obj, n)
	assert(type(n) == "number" and n >= 0, "Emit count")
	M.Emitted = (M.Emitted or 0) + n
	M.EmitsBy = M.EmitsBy or {}
	local key = (rawget(obj, "_parent") and rawget(rawget(obj, "_parent"), "_name") or "?") .. "/" .. rawget(obj, "_name")
	M.EmitsBy[key] = (M.EmitsBy[key] or 0) + n
end
function Instance_mt.Clear(_obj) end
function Instance_mt.SetNetworkOwner(_obj) end
function Instance_mt.GetNetworkOwner(_obj)
	return nil
end
function Instance_mt.BreakJoints(_obj) end
function Instance_mt.PivotTo(obj, cf)
	obj._props.CFrame = cf
end
function Instance_mt.GetPivot(obj)
	return obj._props.CFrame or CFrame.new()
end
function Instance_mt.TakeDamage(obj, d)
	obj.Health = math.max(0, obj.Health - d)
end
function Instance_mt.ChangeState(_obj) end
function Instance_mt.GetState(_obj)
	return Enum.HumanoidStateType.Running
end
function Instance_mt.LoadAnimation(_obj, anim)
	return M.Track(anim)
end
function Instance_mt.Play(_obj) end
function Instance_mt.Stop(_obj) end
function Instance_mt.Fire(obj, ...)
	obj.Event:Fire(...)
end

Instance = {}
function Instance.new(cls, parent)
	local obj = setmetatable({ _class = cls, _name = cls, _props = {}, _attrs = {}, _attrSigs = {}, _propSigs = {}, _children = {}, _parent = nil, _extra = {} }, Instance_mt)
	M.Created += 1
	rawget(obj, "_extra").AncestryChanged = setmetatable({}, {
		__index = function(_, k)
			local s = rawget(obj, "_ancestry")
			if not s then
				s = Signal()
				rawset(obj, "_ancestry", s)
			end
			return s[k]
		end,
	})
	rawget(obj, "_extra").DescendantAdded = setmetatable({}, {
		__index = function(_, k)
			local s = rawget(obj, "_descAdded")
			if not s then
				s = Signal()
				rawset(obj, "_descAdded", s)
			end
			return s[k]
		end,
	})
	local ex = rawget(obj, "_extra")
	ex.ChildAdded = Signal()
	ex.ChildRemoved = Signal()
	ex.Changed = Signal()
	ex.Destroying = Signal()
	if cls == "Humanoid" then
		local e = rawget(obj, "_extra")
		e.HealthChanged = Signal()
		e.Died = Signal()
		e.StateChanged = Signal()
	elseif cls == "BindableEvent" or cls == "RemoteEvent" then
		local e = rawget(obj, "_extra")
		e.Event = Signal()
		e.OnClientEvent = Signal()
		e.OnServerEvent = Signal()
		e.Fired = {}
		e.FireAllClients = function(_, ...)
			table.insert(e.Fired, table.pack(...))
			e.OnClientEvent:Fire(...)
		end
		e.FireClient = function(_, _p, ...)
			table.insert(e.Fired, table.pack(...))
		end
		e.FireServer = function(_, ...)
			e.OnServerEvent:Fire(nil, ...)
		end
	elseif cls == "Trail" then
		rawget(obj, "_extra").Clear = function() end
	end
	if parent then
		obj.Parent = parent
	end
	allInstances[obj] = true
	return obj
end
M.Instances = allInstances

-- (an AnimationTrack stand-in: it runs on the clock - M.ClipLength[AnimationId] long, 1 s if not
-- given - wrapping if looped, stopping at its end if not)
M.ClipLength = {}
local liveTracks = setmetatable({}, { __mode = "k" })
function M.Track(anim)
	local len = anim and M.ClipLength[anim.AnimationId] or 1
	local t = { IsPlaying = false, Speed = 1, TimePosition = 0, Length = len, WeightCurrent = 0, Priority = nil, Looped = false, Animation = anim }
	function t:Play(_f, _w, s)
		t.IsPlaying = true
		t.Speed = s or 1
		t.TimePosition = 0
		liveTracks[t] = true
	end
	function t:Stop()
		if t.IsPlaying then
			t.IsPlaying = false
			t.Stopped:Fire()
		end
	end
	function t:AdjustSpeed(s)
		t.Speed = s
	end
	function t:AdjustWeight() end
	function t:Destroy() end
	t.Stopped = Signal()
	t.Ended = Signal()
	function t:GetMarkerReachedSignal()
		return Signal()
	end
	return t
end

---------------------------------------------------------------------------
-- the scene: a floor (y = 0, |x|,|z| < 30), a wall (x = 10 face, y 0..8), a raised step (y = 1.0,
-- x -20..-12), a ceiling over (x 20..26, y 6)
---------------------------------------------------------------------------
local game_ = Instance.new("DataModel")
rawset(game_, "_name", "Game")
local ws = Instance.new("Workspace")
rawset(ws, "_name", "Workspace")
ws.Parent = game_
ws.Gravity = 196.2
ws.FallenPartsDestroyHeight = -500
local terrain = Instance.new("Terrain")
rawset(terrain, "_name", "Terrain")
terrain.Parent = ws
terrain.Anchored = true
local camera = Instance.new("Camera")
camera.CFrame = CFrame.lookAt(Vector3.new(0, 8, 24), Vector3.new(0, 2, 0))
camera.FieldOfView = 70
camera.ViewportSize = Vector2.new(1920, 1080)
camera.Parent = ws
ws.CurrentCamera = camera
local floorPart = Instance.new("Part")
floorPart.Name = "Floor"
floorPart.Anchored = true
floorPart.Size = Vector3.new(60, 1, 60)
floorPart.CFrame = CFrame.new(0, -0.5, 0)
floorPart.Parent = ws
local wallPart = Instance.new("Part")
wallPart.Name = "Wall"
wallPart.Anchored = true
wallPart.Size = Vector3.new(1, 8, 20)
wallPart.CFrame = CFrame.new(10.5, 4, 0)
wallPart.Parent = ws
local stepPart = Instance.new("Part")
stepPart.Name = "Step"
stepPart.Anchored = true
stepPart.Size = Vector3.new(8, 1, 8)
stepPart.CFrame = CFrame.new(-16, 0.5, 0)
stepPart.Parent = ws
local ceilPart = Instance.new("Part")
ceilPart.Name = "Ceiling"
ceilPart.Anchored = true
ceilPart.Size = Vector3.new(6, 1, 6)
ceilPart.CFrame = CFrame.new(23, 6.5, 0)
ceilPart.Parent = ws
-- two raised platforms with a thin crack between them (x 39.9 .. 40.1) over a lower floor, and the far
-- platform's open edge (x = 50)
local function box(name, cx, cy, cz, sx, sy, sz, mat)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = Vector3.new(sx, sy, sz)
	p.CFrame = CFrame.new(cx, cy, cz)
	p.Material = mat or Enum.Material.Concrete
	p.Parent = ws
	return p
end
local lower = box("LowerFloor", 42, -0.5, 0, 24, 1, 16)
local platA = box("PlatformA", 34.95, 1.75, 0, 9.9, 0.5, 10, Enum.Material.SmoothPlastic)
local platB = box("PlatformB", 45.05, 1.75, 0, 9.9, 0.5, 10, Enum.Material.SmoothPlastic)
M.Scene = { Floor = floorPart, Wall = wallPart, Step = stepPart, Ceiling = ceilPart, Lower = lower, PlatA = platA, PlatB = platB }
M.Rays = 0
M.Boxes = { floorPart, wallPart, stepPart, ceilPart, lower, platA, platB }

-- TERRAIN (x -70 .. -30, z -15 .. 15): rolling grass with a hollow at (-45, 0) and a steep cliff
-- rising at x < -62; and a pond (water, x -10 .. -4, z 12 .. 20, surface at y 0.2)
local function terrainH(x, z)
	local h = 0.25 + 0.18 * math.sin(x * 1.3) * math.cos(z * 0.9) - 0.9 * math.exp(-((x + 45) ^ 2 + z ^ 2) / 14)
	-- a gentle rise toward the cliff, then the cliff itself
	if x < -52 then
		h += (-52 - x) * 0.25
	end
	if x < -62 then
		h += (-62 - x) * 3
	end
	return h
end
M.TerrainH = terrainH
local function inTerrain(x, z)
	return x >= -70 and x <= -30 and z >= -15 and z <= 15
end
terrain.Material = Enum.Material.Grass

local function hitResult(pos, normal, inst)
	return setmetatable({ Position = pos, Normal = normal, Instance = inst, Material = inst.Material or Enum.Material.Plastic, Distance = 0 }, { __type = "RaycastResult" })
end
-- boxes: { part, min, max } axis aligned
local function boxes()
	local out = {}
	for _, p in ipairs(M.Boxes) do
		if p.Parent then
			local c, s = p.CFrame.Position, p.Size * 0.5
			table.insert(out, { p, c - s, c + s })
		end
	end
	return out
end
local function rayBox(o, d, mn, mx)
	local tmin, tmax = 0, 1
	local n = nil
	for _, ax in ipairs({ "X", "Y", "Z" }) do
		local oo, dd, a, b = o[ax], d[ax], mn[ax], mx[ax]
		if math.abs(dd) < 1e-12 then
			if oo < a or oo > b then
				return nil
			end
		else
			local t1, t2 = (a - oo) / dd, (b - oo) / dd
			local sgn = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				sgn = 1
			end
			if t1 > tmin then
				tmin = t1
				n = Vector3.new(ax == "X" and sgn or 0, ax == "Y" and sgn or 0, ax == "Z" and sgn or 0)
				if dd < 0 then
					n = Vector3.new(ax == "X" and 1 or 0, ax == "Y" and 1 or 0, ax == "Z" and 1 or 0)
				else
					n = Vector3.new(ax == "X" and -1 or 0, ax == "Y" and -1 or 0, ax == "Z" and -1 or 0)
				end
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	if not n then
		return nil -- (starts inside)
	end
	return tmin, n
end
local function raycast(_self, o, d, params)
	assert(isV3(o) and isV3(d), "Raycast needs Vector3s")
	M.Rays += 1
	local best, bt, bn = nil, math.huge, nil
	for _, b in ipairs(boxes()) do
		local ex = false
		if params and params.FilterType == Enum.RaycastFilterType.Exclude then
			for _, f in ipairs(params.FilterDescendantsInstances or {}) do
				if b[1] == f or b[1]:IsDescendantOf(f) then
					ex = true
				end
			end
		end
		if not ex then
			local t, n = rayBox(o, d, b[2], b[3])
			if t and t < bt then
				best, bt, bn = b[1], t, n
			end
		end
	end
	-- the terrain: march along the ray, then close in on the surface
	local tExcluded = false
	if params and params.FilterType == Enum.RaycastFilterType.Exclude then
		for _, f in ipairs(params.FilterDescendantsInstances or {}) do
			if f == terrain then
				tExcluded = true
			end
		end
	end
	if not tExcluded then
		local len = d.Magnitude
		local n = math.max(2, math.ceil(len / 0.05))
		local prevT, prevAbove = 0, nil
		for k = 0, n do
			local t = k / n
			if t >= bt then
				break
			end
			local p = o + d * t
			if inTerrain(p.X, p.Z) then
				local above = p.Y > terrainH(p.X, p.Z)
				if prevAbove == true and not above then
					local lo, hi = prevT, t
					for _ = 1, 30 do
						local m = (lo + hi) / 2
						local q = o + d * m
						if q.Y > terrainH(q.X, q.Z) then
							lo = m
						else
							hi = m
						end
					end
					local q = o + d * hi
					local e = 0.01
					local nx = -(terrainH(q.X + e, q.Z) - terrainH(q.X - e, q.Z)) / (2 * e)
					local nz = -(terrainH(q.X, q.Z + e) - terrainH(q.X, q.Z - e)) / (2 * e)
					local nrm = Vector3.new(nx, 1, nz).Unit
					best, bt, bn = terrain, hi, nrm
					break
				end
				prevAbove = above
			else
				prevAbove = nil
			end
			prevT = t
		end
	end
	-- the pond's surface
	local wy = 0.2
	if d.Y < 0 and o.Y >= wy then
		local t = (wy - o.Y) / d.Y
		if t >= 0 and t <= 1 and t < bt then
			local p = o + d * t
			if p.X >= -10 and p.X <= -4 and p.Z >= 12 and p.Z <= 20 then
				local r = hitResult(p, Vector3.yAxis, terrain)
				r.Material = Enum.Material.Water
				r.Distance = t * d.Magnitude
				return r
			end
		end
	end
	if best then
		local r = hitResult(o + d * bt, bn, best)
		r.Distance = bt * d.Magnitude
		if best == terrain then
			r.Material = Enum.Material.Grass
		end
		return r
	end
	return nil
end
rawget(ws, "_extra").Raycast = raycast
rawget(ws, "_extra").Spherecast = function(self, o, _r, d, params)
	return raycast(self, o, d, params)
end
rawget(ws, "_extra").Blockcast = function(self, cf, _s, d, params)
	return raycast(self, cf.Position, d, params)
end
rawget(ws, "_extra").BulkMoveTo = function(_self, parts, cfs)
	assert(#parts == #cfs, "BulkMoveTo sizes")
	for i, p in ipairs(parts) do
		p.CFrame = cfs[i]
	end
	M.Moved = (M.Moved or 0) + #parts
end
rawget(ws, "_extra").GetServerTimeNow = function()
	return clock
end
rawget(ws, "_extra").GetPartBoundsInRadius = function()
	return {}
end
rawget(ws, "_extra").GetPartBoundsInBox = function()
	return {}
end
workspace = ws
Workspace = ws

RaycastParams = {}
function RaycastParams.new()
	return setmetatable({ FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, IgnoreWater = false, RespectCanCollide = false, CollisionGroup = "Default" }, { __type = "RaycastParams" })
end
OverlapParams = RaycastParams

---------------------------------------------------------------------------
-- services
---------------------------------------------------------------------------
local services = {}
local function service(name)
	local s = services[name]
	if s then
		return s
	end
	s = Instance.new(name)
	rawset(s, "_name", name)
	s.Parent = game_
	services[name] = s
	return s
end
local hb, rs, ps = Signal(), Signal(), Signal()
local RunService = service("RunService")
local rsx = rawget(RunService, "_extra")
rsx.Heartbeat = hb
rsx.RenderStepped = rs
rsx.PreSimulation = ps
rsx.Stepped = ps
rsx.PostSimulation = hb
rsx.IsStudio = function()
	return M.Studio == true
end
rsx.IsClient = function()
	return true
end
rsx.IsServer = function()
	return false
end
local bound = {}
rsx.BindToRenderStep = function(_, name, _prio, fn)
	bound[name] = fn
end
rsx.UnbindFromRenderStep = function(_, name)
	bound[name] = nil
end
local Players = service("Players")
local lp = Instance.new("Player")
lp.Name = "Tester"
lp.Parent = Players
rawget(Players, "_extra").LocalPlayer = lp
rawget(Players, "_extra").GetPlayers = function()
	return { lp }
end
rawget(Players, "_extra").GetPlayerFromCharacter = function(_, c)
	if c and lp.Character == c then
		return lp
	end
	return nil
end
rawget(Players, "_extra").PlayerRemoving = Signal()
rawget(Players, "_extra").PlayerAdded = Signal()
rawget(lp, "_extra").CharacterAdded = Signal()
rawget(lp, "_extra").CharacterRemoving = Signal()
rawget(lp, "_extra").GetNetworkPing = function()
	return 0.05
end
local TweenService = service("TweenService")
rawget(TweenService, "_extra").Create = function(_, inst, info, goal)
	local tw = { Completed = Signal() }
	function tw:Play()
		task.delay(info.Time or 0, function()
			for k, v in pairs(goal) do
				pcall(function()
					inst[k] = v
				end)
			end
			tw.Completed:Fire(Enum.PlaybackState.Completed)
		end)
	end
	function tw:Cancel() end
	return tw
end
local CP = service("ContentProvider")
rawget(CP, "_extra").PreloadAsync = function() end
local UIS = service("UserInputService")
rawget(UIS, "_extra").InputBegan = Signal()
rawget(UIS, "_extra").InputEnded = Signal()
rawget(UIS, "_extra").InputChanged = Signal()
rawget(UIS, "_extra").GetFocusedTextBox = function()
	return nil
end
rawget(UIS, "_extra").IsKeyDown = function()
	return false
end
rawget(UIS, "_extra").IsMouseButtonPressed = function()
	return false
end
service("ReplicatedStorage")
service("ServerStorage")
service("ServerScriptService")
service("Lighting")
service("SoundService")
service("Debris")
rawget(service("Debris"), "_extra").AddItem = function(_, inst, t)
	task.delay(t or 10, function()
		inst:Destroy()
	end)
end
local PhysicsService = service("PhysicsService")
rawget(PhysicsService, "_extra").IsCollisionGroupRegistered = function()
	return true
end
rawget(PhysicsService, "_extra").RegisterCollisionGroup = function() end
rawget(PhysicsService, "_extra").CollisionGroupSetCollidable = function() end

rawget(game_, "_extra").GetService = function(_, name)
	return service(name)
end
rawget(game_, "_extra").Workspace = ws
game = game_

---------------------------------------------------------------------------
-- require: ModuleScripts point at src/ files
---------------------------------------------------------------------------
local loaded = {}
local rawrequire = require
function require(x)
	if type(x) == "table" and rawget(x, "_path") then
		local key = rawget(x, "_path")
		if loaded[key] == nil then
			local f = loadchunk(readfile(key), key)
			local env = setmetatable({ script = x }, { __index = _G })
			setfenv(f, env)
			loaded[key] = f()
		end
		return loaded[key]
	end
	return rawrequire(x)
end
-- a ModuleScript instance under `parent` running src file `path`
function M.module(parent, name, path)
	local m = Instance.new("ModuleScript")
	m.Name = name
	rawset(m, "_path", path)
	m.Parent = parent
	return m
end
function M.folder(parent, name)
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

---------------------------------------------------------------------------
-- stepping
---------------------------------------------------------------------------
function M.step(dt)
	dt = dt or 1 / 60
	clock += dt
	-- due tasks (in time order; new ones due now also run)
	for _ = 1, 50 do
		local due = {}
		for i = #tasks, 1, -1 do
			if tasks[i].At <= clock then
				table.insert(due, table.remove(tasks, i))
			end
		end
		if #due == 0 then
			break
		end
		table.sort(due, function(a, b)
			return a.At < b.At
		end)
		for _, t in ipairs(due) do
			t.Fn(table.unpack(t.Args, 1, t.Args.n))
		end
	end
	ps:Fire(dt)
	for t in pairs(liveTracks) do
		if t.IsPlaying then
			t.TimePosition += dt * (t.Speed or 1)
			if t.TimePosition >= t.Length then
				if t.Looped then
					t.TimePosition %= math.max(t.Length, 1e-3)
				else
					t.TimePosition = t.Length
					t.IsPlaying = false
					t.Stopped:Fire()
					t.Ended:Fire()
				end
			end
		else
			liveTracks[t] = nil
		end
	end
	for _, fn in pairs(bound) do
		fn(dt)
	end
	rs:Fire(dt)
	hb:Fire(dt)
end
function M.run(seconds, dt)
	dt = dt or 1 / 60
	local n = math.floor(seconds / dt + 0.5)
	for _ = 1, n do
		M.step(dt)
	end
end
function M.now()
	return clock
end
function M.heartbeatConns()
	return hb:Count()
end
function M.pendingTasks()
	return #tasks
end

-- an R6 body (a practice dummy), standing at `pos`
function M.r6(name, pos, parent)
	local m = Instance.new("Model")
	m.Name = name
	local function part(n, size, off)
		local p = Instance.new("Part")
		p.Name = n
		p.Size = size
		p.CFrame = CFrame.new(pos + off)
		p.Parent = m
		return p
	end
	local root = part("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.zero)
	root.Transparency = 1
	local torso = part("Torso", Vector3.new(2, 2, 1), Vector3.zero)
	local head = part("Head", Vector3.new(2, 1, 1), Vector3.new(0, 1.5, 0))
	part("Right Arm", Vector3.new(1, 2, 1), Vector3.new(1.5, 0, 0))
	part("Left Arm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 0, 0))
	part("Right Leg", Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0))
	part("Left Leg", Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0))
	local function motor(name, p0, p1, c0, c1)
		local mo = Instance.new("Motor6D")
		mo.Name = name
		mo.Part0 = p0
		mo.Part1 = p1
		mo.C0 = c0
		mo.C1 = c1
		mo.Parent = p0
		return mo
	end
	motor("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.5, 0))
	motor("Right Shoulder", torso, m["Right Arm"], CFrame.new(1, 0.5, 0), CFrame.new(-0.5, 0.5, 0))
	motor("Left Shoulder", torso, m["Left Arm"], CFrame.new(-1, 0.5, 0), CFrame.new(0.5, 0.5, 0))
	motor("Right Hip", torso, m["Right Leg"], CFrame.new(1, -1, 0), CFrame.new(0.5, 1, 0))
	motor("Left Hip", torso, m["Left Leg"], CFrame.new(-1, -1, 0), CFrame.new(-0.5, 1, 0))
	motor("RootJoint", root, torso, CFrame.new(), CFrame.new())
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R6
	hum.Parent = m
	local an = Instance.new("Animator")
	an.Parent = hum
	m.PrimaryPart = root
	m.Parent = parent or ws
	return m, hum
end

return M
