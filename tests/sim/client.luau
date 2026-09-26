--!nocheck
--[[
	The CLIENT side of the headless engine (on top of sim/env): enough of Roblox's instance tree,
	TweenService, BulkMoveTo, overlap queries, the camera and render-stepped bindings for the real
	client-only effect modules (CombatBlood, CombatShatter, CombatVFX) to run frame by frame against
	the simulated world (ground height field, boxes, water, voids).

	  local Client = require("./sim/client")(Env)
	  Client.instances(className?)  every live instance (of a class)
	  Client.emits                  every ParticleEmitter:Emit call { Emitter, Count, CFrame, Lifetime, Speed, Accel, T }
]]
local roblox = require("@lune/roblox")

return function(Env)
	local V3, CF = Env.Vector3, Env.CFrame
	local Client = {}

	---------------------------------------------------------------------------
	-- instances
	---------------------------------------------------------------------------
	local SUPER = {
		Part = "BasePart", MeshPart = "BasePart", Terrain = "BasePart", WedgePart = "BasePart", CornerWedgePart = "BasePart",
		BasePart = "PVInstance", Model = "PVInstance", PVInstance = "Instance",
		Attachment = "Instance", ParticleEmitter = "Instance", Decal = "Instance", Texture = "Decal", SpecialMesh = "Instance",
		Folder = "Instance", PointLight = "Instance", Trail = "Instance", Beam = "Instance", Sound = "Instance",
		EqualizerSoundEffect = "Instance", DistortionSoundEffect = "Instance", Camera = "Instance", Instance = nil,
		UnionOperation = "BasePart", Weld = "JointInstance", Motor6D = "JointInstance", JointInstance = "Instance",
		WeldConstraint = "Instance", BallSocketConstraint = "Instance", Humanoid = "Instance", Accessory = "Instance",
		Shirt = "Clothing", Pants = "Clothing", Clothing = "Instance", SurfaceAppearance = "Instance", Bone = "Attachment",
	}
	local DEFAULTS = {
		BasePart = { Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true, Transparency = 0, Reflectance = 0, Size = V3.new(4, 1, 2), Material = roblox.Enum.Material.Plastic, MaterialVariant = "", Color = roblox.Color3.new(0.64, 0.64, 0.64),
			LocalTransparencyModifier = 0, Massless = false, CollisionGroup = "Default", AssemblyLinearVelocity = V3.zero, AssemblyAngularVelocity = V3.zero },
		Decal = { Transparency = 0, Texture = "", Face = roblox.Enum.NormalId.Front, LocalTransparencyModifier = 0 },
		ParticleEmitter = { Enabled = true, Rate = 5, Lifetime = roblox.NumberRange.new(5, 10), Speed = roblox.NumberRange.new(5, 5), Acceleration = V3.zero, Drag = 0, SpreadAngle = roblox.Vector2.new(0, 0), EmitCount = 0 },
		Attachment = { },
		PointLight = { Brightness = 1, Range = 8 },
	}
	local all = {}
	Client.all = all
	local proto = {}
	proto.__index = function(self, k)
		local v = rawget(self, "_p")[k]
		if v ~= nil then
			return v
		end
		if k == "Position" then
			local cf = self._p.CFrame
			return if cf then cf.Position else nil
		elseif k == "WorldCFrame" or k == "WorldPosition" then
			local cf = self._p.CFrame or CF.identity
			local parent = self._p.Parent
			if parent and parent._p and parent._p.CFrame and parent.ClassName ~= "Terrain" then
				cf = parent._p.CFrame * cf
			end
			return if k == "WorldCFrame" then cf else cf.Position
		end
		return proto[k]
	end
	proto.__newindex = function(self, k, v)
		if k == "Parent" then
			local old = self._p.Parent
			if old and old._children then
				local list = old._children
				for i = #list, 1, -1 do
					if list[i] == self then
						table.remove(list, i)
					end
				end
			end
			self._p.Parent = v
			if v then
				v._children = v._children or {}
				table.insert(v._children, self)
			end
			return
		elseif k == "Position" then
			local cf = self._p.CFrame or CF.identity
			self._p.CFrame = cf + (v - cf.Position)
			return
		elseif k == "WorldPosition" then
			self._p.CFrame = CF.new(v)
			return
		end
		self._p[k] = v
	end
	function proto:IsA(c)
		local cls = self.ClassName
		while cls do
			if cls == c then
				return true
			end
			cls = SUPER[cls]
		end
		return false
	end
	function proto:FindFirstChild(name)
		for _, ch in ipairs(self._children or {}) do
			if ch.Name == name then
				return ch
			end
		end
		return nil
	end
	proto.WaitForChild = proto.FindFirstChild
	function proto:FindFirstChildOfClass(c)
		for _, ch in ipairs(self._children or {}) do
			if ch.ClassName == c then
				return ch
			end
		end
		return nil
	end
	function proto:FindFirstAncestorOfClass(c)
		local p = self._p.Parent
		while p do
			if p.ClassName == c then
				return p
			end
			p = if p._p then p._p.Parent else nil
		end
		return nil
	end
	function proto:GetChildren()
		return table.clone(self._children or {})
	end
	function proto:GetDescendants()
		local out = {}
		local function walk(n)
			for _, ch in ipairs(n._children or {}) do
				table.insert(out, ch)
				walk(ch)
			end
		end
		walk(self)
		return out
	end
	function proto:Destroy()
		self.Parent = nil
		self._p.Destroyed = true
		for _, ch in ipairs(table.clone(self._children or {})) do
			ch:Destroy()
		end
	end
	function proto:Clone()
		local c = Client.new(self.ClassName)
		for k, v in pairs(self._p) do
			if k ~= "Parent" then
				c._p[k] = v
			end
		end
		for _, ch in ipairs(self._children or {}) do
			ch:Clone().Parent = c
		end
		return c
	end
	function proto:GetAttribute(k)
		return (self._p.Attributes or {})[k]
	end
	function proto:SetAttribute(k, v)
		self._p.Attributes = self._p.Attributes or {}
		self._p.Attributes[k] = v
	end
	Client.emits = {}
	function proto:Emit(n)
		local parent = self._p.Parent
		local cf = if parent then parent.WorldCFrame else CF.identity
		table.insert(Client.emits, { Emitter = self, Count = n, CFrame = cf, Lifetime = self.Lifetime, Speed = self.Speed, Accel = self.Acceleration, Drag = self.Drag, Spread = self.SpreadAngle, T = Env.now() })
	end
	function proto:Play() end
	function proto:Stop() end
	function proto:AdjustSpeed() end

	function Client.new(className)
		local p = { ClassName = className, Name = className }
		local cls = className
		while cls do
			for k, v in pairs(DEFAULTS[cls] or {}) do
				if p[k] == nil then
					p[k] = v
				end
			end
			cls = SUPER[cls]
		end
		local inst = setmetatable({ _p = p, _children = {} }, proto)
		table.insert(all, inst)
		return inst
	end
	-- (the ClassName / Name reads go through _p)
	function Client.instances(className)
		local out = {}
		for _, i in ipairs(all) do
			if not i._p.Destroyed and (className == nil or i:IsA(className)) then
				table.insert(out, i)
			end
		end
		return out
	end

	---------------------------------------------------------------------------
	-- the workspace, the camera, render steps
	---------------------------------------------------------------------------
	local ws = Env.workspace
	ws._children = ws._children or {}
	ws._p = ws._p or {}
	ws.FindFirstChild = proto.FindFirstChild
	ws.GetChildren = proto.GetChildren
	local terrain = Client.new("Terrain")
	terrain.Name = "Terrain"
	terrain._p.CFrame = CF.identity
	ws.Terrain = terrain
	ws.CurrentCamera = { CFrame = CF.new(0, 20, 30), CameraType = roblox.Enum.CameraType.Custom, FieldOfView = 70 }
	function ws:BulkMoveTo(parts, cfs)
		for i, p in ipairs(parts) do
			p._p.CFrame = cfs[i]
		end
	end
	-- overlap: the part's box (its corners' bounding box) against the world's boxes
	function ws:GetPartsInPart(part, params)
		local cf, size = part._p.CFrame, part._p.Size
		local lo, hi = V3.new(math.huge, math.huge, math.huge), V3.new(-math.huge, -math.huge, -math.huge)
		for _, sx in ipairs({ -0.5, 0.5 }) do
			for _, sy in ipairs({ -0.5, 0.5 }) do
				for _, sz in ipairs({ -0.5, 0.5 }) do
					local c = cf * V3.new(size.X * sx, size.Y * sy, size.Z * sz)
					lo = V3.new(math.min(lo.X, c.X), math.min(lo.Y, c.Y), math.min(lo.Z, c.Z))
					hi = V3.new(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z))
				end
			end
		end
		local out = {}
		for _, b in ipairs(Env.boxes) do
			if (b.CanCollide or not (params and params.RespectCanCollide)) and lo.X < b.Max.X and hi.X > b.Min.X and lo.Y < b.Max.Y and hi.Y > b.Min.Y and lo.Z < b.Max.Z and hi.Z > b.Min.Z then
				table.insert(out, b)
			end
		end
		return out
	end
	local binds = {}
	Env.services.RunService.BindToRenderStep = function(_, name, _prio, fn)
		binds[name] = fn
	end
	Env.services.RunService.UnbindFromRenderStep = function(_, name)
		binds[name] = nil
	end
	Env.services.RunService.Heartbeat:Connect(function(dt)
		for _, fn in pairs(binds) do
			fn(dt)
		end
	end)

	---------------------------------------------------------------------------
	-- TweenService (linear in time; the tested thing is where values END and WHEN)
	---------------------------------------------------------------------------
	local TweenService = {}
	function TweenService:Create(obj, info, goals)
		local tw = {}
		function tw:Play()
			local from = {}
			for k in pairs(goals) do
				from[k] = obj[k]
			end
			local t0 = Env.now()
			local dur = math.max(info.Time or 0.001, 1e-4)
			local conn
			conn = Env.services.RunService.Heartbeat:Connect(function()
				local k = math.clamp((Env.now() - t0) / dur, 0, 1)
				for key, goal in pairs(goals) do
					local a = from[key]
					local v
					if type(goal) == "number" then
						v = a + (goal - a) * k
					elseif typeof(goal) == "Vector3" or typeof(goal) == "Color3" then
						v = a:Lerp(goal, k)
					elseif CF._is(goal) then
						v = a:Lerp(goal, k)
					else
						v = if k >= 1 then goal else a
					end
					obj[key] = v
				end
				if k >= 1 then
					conn:Disconnect()
				end
			end)
		end
		function tw:Cancel() end
		return tw
	end
	Env.services.TweenService = TweenService
	Env.services.SoundService = { FindFirstChild = function()
		return nil
	end }
	Env.extraGlobals.Instance = { new = Client.new }
	Env.extraGlobals.TweenInfo = { new = function(t)
		return { Time = t }
	end }
	Env.extraGlobals.Vector2 = roblox.Vector2
	Env.extraGlobals.typeof = typeof

	-- the workspace as the modules see it: anything parented to it is found by name
	local function parentToWorkspace(inst)
		inst._p.Parent = ws
		table.insert(ws._children, inst)
	end
	Client.parentToWorkspace = parentToWorkspace
	return Client
end
