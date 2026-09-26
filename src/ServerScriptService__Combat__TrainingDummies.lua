--[[
	TrainingDummies  (ServerScriptService.Combat.TrainingDummies)
	Studio play-tests only: R6 practice fighters on open ground near the spawn, facing it, run
	entirely through CombatService (the same rules, animations, hitboxes, guard, limbs and ragdoll as
	players).
	  Training Dummy    stands still - combo practice                 } side by side
	  Guard Dummy       keeps its guard up (back up after a break)     }
	  Sparring Dummy    on its own spot, well away from the other two: it walks up to the nearest
	                    player and fights back - light chains with an uppercut mixed in, a rest
	                    after each finisher, its guard up now and then when you swing. Its limbs
	                    are a fighter's: with one arm it throws single left-hand strikes, with none
	                    it can only jump into Ground Smashes (CombatService decides, as for anyone).
	                    It never leaves its ground (Leash) and walks home when nobody is near.
	The still two have Config.DummyHealth (one full string knocks one out on its finisher); the
	Sparring Dummy has Config.SparringHealth, enough for a real fight (its arms come off on the way).
	None of them heal: the damage (and the gore it shows) stays until the dummy is knocked out, and
	only then is a fresh one back on its own spot a few seconds later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Dummies = {}

local KINDS = {
	{ Kind = "Target", Name = "Training Dummy", Color = Color3.fromRGB(163, 162, 165) },
	{ Kind = "Guard", Name = "Guard Dummy", Color = Color3.fromRGB(90, 140, 210) },
	{ Kind = "Sparring", Name = "Sparring Dummy", Color = Color3.fromRGB(210, 110, 90), Apart = true },
}
local ROW = 0 -- how many stand in the row (the rest get spots of their own)
for _, k in ipairs(KINDS) do
	if not k.Apart then
		ROW += 1
	end
end
local APART = 26 -- a dummy of its own stands at least this far from every other one
local LEASH = 40 -- the Sparring Dummy never chases anyone further than this from its spot
local SIGHT = 28 -- ...and notices a player this close

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
	local hp = if kind.Kind == "Sparring" then Config.SparringHealth or 60 else Config.DummyHealth or 100
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
				for i = 0, ROW - 1 do
					local g = openGround(center + side * (i * GAP), ignoreList({ folder }), sp.Y)
					if not g then
						break
					end
					table.insert(spots, g)
				end
				if #spots == ROW and math.abs(spots[1].Y - spots[#spots].Y) < 1.5 then
					rowFacing = toSpawn
					return spots
				end
			end
		end
		rowFacing = Vector3.new(-1, 0, 0)
		return { sp + Vector3.new(16, 0, -GAP / 2), sp + Vector3.new(16, 0, GAP / 2) }
	end
	local row = findRow()

	-- a spot of its own: open ground round the spawn, at least APART from every other dummy's spot,
	-- as near the spawn as that allows
	local taken: { Vector3 } = table.clone(row)
	local function findApart(): Vector3
		for _, radius in ipairs({ 30, 36, 42, 26, 48, 56 }) do
			for step = 0, 23 do
				local ang = math.rad(step * 15 + 7.5)
				local p = sp + Vector3.new(math.cos(ang) * radius, 0, math.sin(ang) * radius)
				local far = true
				for _, q in ipairs(taken) do
					if (Vector3.new(p.X, q.Y, p.Z) - q).Magnitude < APART then
						far = false
						break
					end
				end
				if far then
					local g = openGround(p, ignoreList({ folder }), sp.Y)
					if g then
						return g
					end
				end
			end
		end
		-- nowhere open: APART further along the row's line
		local a, b = row[1], row[#row]
		local along = if (b - a).Magnitude > 0.1 then flat(b - a) else rowFacing:Cross(Vector3.yAxis).Unit
		return b + along * APART
	end

	local function place(kind: any)
		if not kind.Spot then
			if kind.Apart then
				kind.Spot = findApart()
				table.insert(taken, kind.Spot)
			else
				kind.Spot = row[kind.Index] or row[1]
			end
		end
		local ground = kind.Spot
		local facing = if kind.Apart then flat(sp - ground) else rowFacing
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
		-- practice dummies never heal (they only come back whole by respawning after a knockout);
		-- a standing one goes back to its spot a moment after the last hit (a combo carries a dummy
		-- across the ground - it shouldn't end up in a lake or off the island)
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
					local settled = e.State == "Idle" or e.State == "Blocking"
					if kind.Kind ~= "Sparring" and settled and e.Root.Parent and (e.Root.Position - homeCf.Position).Magnitude > 2.5 then
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
	local rowIndex = 0
	for _, k in ipairs(KINDS) do
		if not k.Apart then
			rowIndex += 1
			k.Index = rowIndex
		end
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

-- the Sparring Dummy: walks up to the nearest player (never past its leash) and fights through
-- CombatService like anyone - so its lost arms limit it the same way (single left-hand strikes with
-- one, only the Ground Smash with none)
local FREE = { Idle = true, ComboWindow = true }
local function spar(Service: any, e: any)
	local t = os.clock()
	local free = FREE[e.State] == true
	local moving = e.Hum.MoveDirection.Magnitude > 0.1 and free
	if moving and not e.AC:IsPlaying("Walk") then
		e.AC:Play("Walk", { Fade = 0.15, Speed = e.Hum.WalkSpeed / Config.WalkNatural })
	elseif not moving and e.AC:IsPlaying("Walk") then
		e.AC:Stop("Walk", 0.2)
	end
	e.Hum.AutoRotate = free
	e.Hum.WalkSpeed = if free then Config.WalkSpeed else 0

	local function flatDist(a: Vector3, b: Vector3): number
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end
	local target, dist = nearestPlayer(Service, e, SIGHT)
	if target and e.Home and flatDist(target.Root.Position, e.Home) > LEASH then
		target = nil
	end
	if not target then
		e.Engaged = false
		if e.State == "Blocking" then
			Service.RequestBlock(e.Char, false)
		end
		if free and e.Home and flatDist(e.Root.Position, e.Home) > 3 then
			e.Hum:MoveTo(e.Home)
		end
		return
	end
	-- a beat to notice someone (it never jumps a player the instant they walk up)
	if not e.Engaged then
		e.Engaged = true
		e.RestUntil = math.max(e.RestUntil or 0, t + 0.6)
	end
	local arms = Config.ArmsAt(e.GoreStage or 0)
	-- its guard, now and then, when the player swings at it (a guard needs an arm)
	if arms > 0 and free and target.State == "Attacking" and dist < 7 and t > (e.NextGuardRoll or 0) then
		e.NextGuardRoll = t + 1.2
		if math.random() < 0.3 then
			face(e, target.Root.Position)
			Service.RequestBlock(e.Char, true)
			e.GuardUntil = t + 0.9
		end
	end
	if e.State == "Blocking" then
		face(e, target.Root.Position)
		if t > (e.GuardUntil or 0) then
			Service.RequestBlock(e.Char, false)
		end
		return
	end
	if dist > 4.4 then
		if free and t > (e.RestUntil or 0) then
			e.Hum:MoveTo(target.Root.Position - flat(target.Root.Position - e.Root.Position) * 3.3)
		end
		return
	end
	e.Hum:Move(Vector3.zero)
	if t < (e.RestUntil or 0) then
		return
	end
	if arms == 0 then
		-- no arms: the Ground Smash (a jump, then the stomp) is all it has left
		if e.State == "Idle" and t > (e.NextSmash or 0) then
			e.NextSmash = t + 2.5 + math.random()
			face(e, target.Root.Position)
			e.Hum.Jump = true
			task.delay(0.18, function()
				if Service.Alive(e) then
					Service.RequestAttack(e.Char, { Kind = "Light", Air = true })
				end
			end)
		end
		return
	end
	if e.State == "Idle" then
		face(e, target.Root.Position)
		e.PlanHeavyAt = math.random(1, 5) -- where this chain's uppercut goes (5 = none)
	end
	if free or e.State == "Attacking" then
		local slot = (e.Chain and e.Chain.Slot or 0) + 1
		local heavy = if arms == 2 then slot == e.PlanHeavyAt and not (e.Chain and e.Chain.Heavy) else math.random() < 0.3
		local ok, action = Service.RequestAttack(e.Char, { Kind = if heavy then "Heavy" else "Light" })
		if ok and action == Config.Combo.Finisher then
			e.RestUntil = t + 1.6 + math.random() * 0.8
		elseif ok and arms == 1 then
			e.RestUntil = t + 0.2 + math.random() * 0.6 -- (a beat between its single strikes)
		end
	end
end
Dummies._spar = spar

-- the still dummies never walk or turn on their own (a target stays where it was left)
function Dummies._think(Service: any, e: any)
	if e.Kind == "Sparring" then
		spar(Service, e)
		return
	end
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
