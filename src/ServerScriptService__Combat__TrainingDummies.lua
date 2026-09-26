--[[
	TrainingDummies  (ServerScriptService.Combat.TrainingDummies)
	Studio play-tests only: two R6 practice fighters side by side on open ground near the spawn,
	facing it, run entirely through CombatService (the same rules, animations, hitboxes, guard and
	ragdoll as players). Neither of them ever attacks anybody.
	  Training Dummy    stands still - combo practice
	  Guard Dummy       keeps its guard up (and puts it back up after a guard break)
	They have Config.DummyHealth: one full string knocks one out on its finisher (the KO throw, the
	KO call-out), they heal back to full a moment after the last hit, and a knocked-out dummy is
	back on its own spot a few seconds later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Dummies = {}

local KINDS = {
	{ Kind = "Target", Name = "Training Dummy", Color = Color3.fromRGB(163, 162, 165) },
	{ Kind = "Guard", Name = "Guard Dummy", Color = Color3.fromRGB(90, 140, 210) },
}

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function spawnPoint(): Vector3
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("SpawnLocation") then
			return d.Position
		end
	end
	return Vector3.new(0, 5, 0)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude

local function ignoreList(extra: { Instance }): { Instance }
	local list = table.clone(extra)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

-- set pieces the dummies must keep clear of (queue portals, the crater stage, fountains)
local keepClear = OverlapParams.new()
keepClear.FilterType = Enum.RaycastFilterType.Include
local function setPieces(): { Instance }
	local list = {}
	for _, c in ipairs(workspace:GetChildren()) do
		local n = string.lower(c.Name)
		if n:find("portal") or n:find("crater") or n:find("queue") or n:find("arena") or n:find("fountain") or n:find("quest") then
			table.insert(list, c)
		end
	end
	return list
end

-- open, flat ground: something solid underneath, nothing standing in a fighter-sized box above it,
-- and no set piece (portal pads, stages, fountains) nearby
local function openGround(pos: Vector3, ignore: { Instance }, refY: number): Vector3?
	rayParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), rayParams)
	if not hit or hit.Normal.Y < 0.9 or hit.Material == Enum.Material.Water or math.abs(hit.Position.Y - refY) > 6 then
		return nil
	end
	overlap.FilterDescendantsInstances = ignore
	local box = CFrame.new(hit.Position + Vector3.new(0, 3.4, 0))
	for _, p in ipairs(workspace:GetPartBoundsInBox(box, Vector3.new(6, 5.2, 6), overlap)) do
		if p ~= hit.Instance and p:IsA("BasePart") and (p.CanCollide or p.Transparency < 0.9) and p.Size.Magnitude < 60 then
			return nil
		end
	end
	local pieces = setPieces()
	if #pieces > 0 then
		keepClear.FilterDescendantsInstances = pieces
		if #workspace:GetPartBoundsInRadius(hit.Position, 16, keepClear) > 0 then
			return nil
		end
	end
	return hit.Position
end

local function build(kind: any, pos: Vector3, facing: Vector3): Model?
	local desc = Instance.new("HumanoidDescription")
	for _, f in ipairs({ "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }) do
		(desc :: any)[f] = kind.Color
	end
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)
	end)
	if not ok or not model then
		warn("[Combat] couldn't build a dummy:", model)
		return nil
	end
	model.Name = kind.Name
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	hum.DisplayName = kind.Name
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	hum.NameDisplayDistance = 60
	hum.HealthDisplayDistance = 60
	hum.WalkSpeed = Config.WalkSpeed
	local hp = Config.DummyHealth or 100
	hum.MaxHealth = hp
	hum.Health = hp
	for _, s in ipairs(model:GetDescendants()) do
		if s:IsA("LocalScript") or s:IsA("Script") then
			s:Destroy()
		end
	end
	model:SetAttribute("PracticeDummy", kind.Kind)
	model:PivotTo(CFrame.lookAt(pos + Vector3.new(0, 3, 0), pos + Vector3.new(0, 3, 0) + facing))
	return model
end

function Dummies.Start(Service: any)
	local folder = Instance.new("Folder")
	folder.Name = "PracticeDummies"
	folder.Parent = workspace
	local sp = spawnPoint()

	-- one row of open spots near the spawn, side by side (GAP apart), all facing the spawn; kept for
	-- respawns
	local GAP = 8
	local rowFacing = Vector3.new(0, 0, -1)
	local function findRow(): { Vector3 }
		for _, radius in ipairs({ 22, 26, 18, 30, 34, 40 }) do
			for step = 0, 23 do
				local ang = math.rad(step * 15)
				local center = sp + Vector3.new(math.cos(ang) * radius, 0, math.sin(ang) * radius)
				local toSpawn = flat(sp - center)
				local side = toSpawn:Cross(Vector3.yAxis).Unit
				local spots: { Vector3 } = {}
				for i = 0, #KINDS - 1 do
					local g = openGround(center + side * (i * GAP), ignoreList({ folder }), sp.Y)
					if not g then
						break
					end
					table.insert(spots, g)
				end
				if #spots == #KINDS and math.abs(spots[1].Y - spots[#spots].Y) < 1.5 then
					rowFacing = toSpawn
					return spots
				end
			end
		end
		rowFacing = Vector3.new(-1, 0, 0)
		return { sp + Vector3.new(16, 0, -GAP / 2), sp + Vector3.new(16, 0, GAP / 2) }
	end
	local row = findRow()

	local function place(kind: any)
		kind.Spot = kind.Spot or row[kind.Index] or row[1]
		local ground = kind.Spot
		local facing = rowFacing
		local model = build(kind, ground, facing)
		if not model then
			return
		end
		model.Parent = folder
		local e = Service.Register(model, nil)
		if not e then
			return
		end
		e.Kind = kind.Kind
		e.Home = ground
		e.AC:Play("CombatIdle", { Fade = 0.2 })
		-- practice dummies heal back to full a moment after the last hit, and the standing ones go
		-- back to their spot (a combo carries a dummy across the ground - it shouldn't end up in a
		-- lake or off the island)
		local lastHurt = 0
		local hp = e.Hum.Health
		e.Hum.HealthChanged:Connect(function(h)
			if h < hp then
				lastHurt = os.clock()
			end
			hp = h
		end)
		local homeCf = CFrame.lookAt(ground + Vector3.new(0, 3, 0), ground + Vector3.new(0, 3, 0) + facing)
		task.spawn(function()
			while model.Parent do
				task.wait(0.5)
				if e.Hum.Health > 0 and os.clock() - lastHurt > 2.5 then
					if e.Hum.Health < e.Hum.MaxHealth then
						e.Hum.Health = e.Hum.MaxHealth
					end
					local settled = e.State == "Idle" or e.State == "Blocking"
					if settled and e.Root.Parent and (e.Root.Position - homeCf.Position).Magnitude > 2.5 then
						e.Root.AssemblyLinearVelocity = Vector3.zero
						model:PivotTo(homeCf)
					end
				end
			end
		end)
		-- back on its spot a few seconds after a knockout - once (a dead body's ragdoll fall can
		-- fire Died a second time)
		e.Hum.Died:Once(function()
			task.delay(3.5, function()
				model:Destroy()
				place(kind)
			end)
		end)
	end
	for i, k in ipairs(KINDS) do
		k.Index = i
		place(k)
	end

	-- the guard dummy's guard (10 Hz)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		for _, e in pairs(Service.Entities) do
			if e.Npc and e.Kind and Service.Alive(e) then
				Dummies._think(Service, e)
			end
		end
	end)
end

local function nearestPlayer(Service: any, e: any, range: number): any
	local best, bestD = nil, range
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		local o = c and Service.Get(c)
		if o and Service.Alive(o) then
			local d = (o.Root.Position - e.Root.Position).Magnitude
			if d < bestD then
				best, bestD = o, d
			end
		end
	end
	return best, bestD
end

local function face(e: any, pos: Vector3)
	local d = flat(pos - e.Root.Position)
	e.Root.CFrame = CFrame.lookAt(e.Root.Position, e.Root.Position + d)
end

-- practice dummies never walk or turn on their own (a still target stays where it was left)
function Dummies._think(Service: any, e: any)
	e.Hum.AutoRotate = false
	e.Hum.WalkSpeed = 0

	if e.Kind == "Guard" then
		local target = nearestPlayer(Service, e, 25)
		if e.State == "Idle" then
			Service.RequestBlock(e.Char, true)
		end
		if target and e.State == "Blocking" then
			face(e, target.Root.Position)
		end
	end
end

return Dummies
