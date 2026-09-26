--!nocheck
--[[
	The practice dummies (the REAL TrainingDummies module on the simulated world): they never heal -
	the damage (and the gore it shows) stays - and only a knockout brings a fresh, whole one back on
	its spot, a few seconds later, exactly once.

	    lune run tests/dummy_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local Client = require("./sim/client")(Env)
local roblox = require("@lune/roblox")
local V3, CF = Env.Vector3, Env.CFrame
local process = require("@lune/process")

local passed, failed = 0, 0
local function check(name, cond, detail)
	if cond then
		passed += 1
		print("  PASS  " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. (if detail then "  -- " .. tostring(detail) else ""))
	end
end

-- the engine pieces the module uses
local ws = Env.workspace
function ws:GetDescendants()
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
function ws:GetPartBoundsInBox()
	return {}
end
function ws:GetPartBoundsInRadius()
	return {}
end
Env.extraGlobals.OverlapParams = { new = function()
	return { FilterDescendantsInstances = {} }
end }
local built = {}
function Env.Players:CreateHumanoidModelFromDescription(_desc, rigType)
	local m = Client.new("Model")
	local hum = Client.new("Humanoid")
	hum.Name = "Humanoid"
	hum.RigType = rigType
	hum.MaxHealth = 100
	hum.Health = 100
	hum._p.HealthChanged = Env.Signal.new()
	hum._p.Died = Env.Signal.new()
	hum.Parent = m
	local root = Client.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CF.new(0, 3, 0)
	root.Parent = m
	local regen = Client.new("Script")
	regen.Name = "Health" -- (a character's own regeneration script: the module must strip it)
	regen.Parent = m
	m._p.PivotTo = function(self, cf)
		root.CFrame = cf
	end
	table.insert(built, m)
	return m
end
local entities = {}
local Service = {
	Entities = entities,
	Register = function(model)
		local e = { Char = model, Hum = model:FindFirstChildOfClass("Humanoid"), Root = model:FindFirstChild("HumanoidRootPart"), AC = { Play = function() end }, State = "Idle", Npc = true }
		entities[model] = e
		return e
	end,
	Alive = function(e)
		return e.Hum.Health > 0
	end,
	RequestBlock = function() end,
}

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Dummies = Env.load("ServerScriptService/Combat/TrainingDummies")
Dummies.Start(Service)
Env.run(0.1)

local function dummy(name)
	local folder = ws:FindFirstChild("PracticeDummies")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		if m.Name == name and not m._p.Destroyed then
			return m, m:FindFirstChildOfClass("Humanoid")
		end
	end
	return nil
end
local function hurt(hum, h)
	hum.Health = h
	hum._p.HealthChanged:Fire(h)
end

print("\n== the practice dummies")
local target, th = dummy("Training Dummy")
local guard, gh = dummy("Guard Dummy")
check("both dummies stand (Training Dummy, Guard Dummy)", target ~= nil and guard ~= nil)
check(("at full health (Config.DummyHealth = %s)"):format(tostring(Config.DummyHealth)), th.Health == Config.DummyHealth and th.MaxHealth == Config.DummyHealth and gh.Health == Config.DummyHealth)
check("no script of their own (a regeneration script would heal them)", target:FindFirstChildOfClass("Script") == nil)

hurt(th, th.MaxHealth * 0.4)
hurt(gh, gh.MaxHealth * 0.7)
Env.run(12)
check("hurt and left alone for 12 s: the Training Dummy never heals", th.Health == th.MaxHealth * 0.4, th.Health)
check("... nor the Guard Dummy", gh.Health == gh.MaxHealth * 0.7, gh.Health)
check("... and neither is replaced", dummy("Training Dummy") == target and dummy("Guard Dummy") == guard)

hurt(th, 0)
th._p.Died:Fire()
Env.run(0.5)
th._p.Died:Fire() -- (the ragdoll's fall can fire Died a second time)
Env.run(2.8)
check("knocked out: the body stays a moment (3.5 s)", dummy("Training Dummy") == target)
Env.run(0.4)
local fresh, fh = dummy("Training Dummy")
check("... then a fresh Training Dummy stands on its spot", fresh ~= nil and fresh ~= target and target._p.Destroyed == true)
check("... whole: full health", fh and fh.Health == fh.MaxHealth, fh and fh.Health)
Env.run(5)
local count = 0
for _, m in ipairs(ws:FindFirstChild("PracticeDummies"):GetChildren()) do
	if m.Name == "Training Dummy" and not m._p.Destroyed then
		count += 1
	end
end
check("... exactly once (a second Died never spawns a second one)", count == 1, count)
check("the Guard Dummy is untouched by it (still hurt, never healed)", dummy("Guard Dummy") == guard and gh.Health == gh.MaxHealth * 0.7)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
