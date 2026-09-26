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
	hum._p.MoveDirection = V3.zero
	hum._p.MoveTo = function(self, p)
		self._p.MovedTo = p
	end
	hum._p.Move = function() end
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
local fighters = {} -- players' bodies (Service.Get)
local attacks = {} -- every RequestAttack: { Char, Info }
local Service = {
	Entities = entities,
	Register = function(model)
		local e = { Char = model, Hum = model:FindFirstChildOfClass("Humanoid"), Root = model:FindFirstChild("HumanoidRootPart"), AC = { Play = function() end, Stop = function() end, IsPlaying = function()
			return false
		end }, State = "Idle", Npc = true, GoreStage = 0 }
		entities[model] = e
		return e
	end,
	Get = function(c)
		return fighters[c] or entities[c]
	end,
	Alive = function(e)
		return e.Hum.Health > 0
	end,
	RequestBlock = function() end,
	RequestAttack = function(char, info)
		table.insert(attacks, { Char = char, Info = info })
		return true, if info.Air then "Downslam" else "Swing1", 1
	end,
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

print("\n== the Sparring Dummy")
local spar, sh = dummy("Sparring Dummy")
check("a third dummy, the Sparring Dummy, stands", spar ~= nil)
local sroot = spar and spar:FindFirstChild("HumanoidRootPart")
local function far(m)
	local r = m and m:FindFirstChild("HumanoidRootPart")
	return r and (V3.new(r.CFrame.Position.X, 0, r.CFrame.Position.Z) - V3.new(sroot.CFrame.Position.X, 0, sroot.CFrame.Position.Z)).Magnitude or 0
end
local tNow, gNow = dummy("Training Dummy"), dummy("Guard Dummy")
check(("on its own spot, well away from the other two (%.0f and %.0f studs)"):format(far(tNow), far(gNow)), far(tNow) >= 26 and far(gNow) >= 26)
check(("a real fight's health (Config.SparringHealth = %s)"):format(tostring(Config.SparringHealth)), sh.MaxHealth == Config.SparringHealth and sh.Health == Config.SparringHealth)
-- a player walks up
local es = entities[spar]
local home = sroot.CFrame.Position
local pChar = Client.new("Model")
local pHum = Client.new("Humanoid")
pHum.Health = 100
pHum.Parent = pChar
local pRoot = Client.new("Part")
pRoot.Name = "HumanoidRootPart"
pRoot.Parent = pChar
local pEnt = { Char = pChar, Hum = pHum, Root = pRoot, State = "Idle" }
fighters[pChar] = pEnt
Env.player("Sparrer", 0.05, pChar)
local function stand(dist)
	local look = sroot.CFrame.LookVector
	pRoot.CFrame = CF.new(sroot.CFrame.Position + V3.new(look.X, 0, look.Z).Unit * dist)
end
local function attacksBy(from)
	local n, heavy, air = 0, 0, 0
	for i = from + 1, #attacks do
		if attacks[i].Char == spar then
			n += 1
			if attacks[i].Info.Kind == "Heavy" then
				heavy += 1
			end
			if attacks[i].Info.Air then
				air += 1
			end
		end
	end
	return n, heavy, air
end
stand(15)
Env.run(1.2)
local moved = sh._p.MovedTo
check("a player 15 studs away: it walks up to them", moved ~= nil and (moved - pRoot.CFrame.Position).Magnitude < 5)
-- (out of sight, then suddenly right in front of it)
stand(40)
Env.run(0.5)
stand(3.2)
local a0 = #attacks
Env.run(0.4)
check("someone suddenly in reach: a beat to notice first (no ambush the instant they appear)", attacksBy(a0) == 0)
Env.run(3)
local n, heavy = attacksBy(a0)
check(("then it fights back: %d strikes asked for (lights, the odd uppercut)"):format(n), n >= 3)
-- no arms: no attack of any kind (not even the Ground Smash)
es.GoreStage = 2
local a1 = #attacks
Env.run(3)
local n2 = attacksBy(a1)
check(("no arms: it asks for no attack at all (%d), and never jumps into a smash"):format(n2), n2 == 0 and sh.Jump ~= true)
es.GoreStage = 0
-- a player beyond its leash: it doesn't follow; it walks home
pRoot.CFrame = CF.new(home + V3.new(60, 0, 0))
sroot.CFrame = CF.new(home + V3.new(8, 0, 0))
local a2 = #attacks
Env.run(1.2)
local mt = sh._p.MovedTo
check("a player far past its ground: never chased, it walks back home", attacksBy(a2) == 0 and mt ~= nil and V3.new(mt.X - home.X, 0, mt.Z - home.Z).Magnitude < 0.5)
-- standing at home with nobody about: it stays put (never walking on the spot)
sroot.CFrame = CF.new(home)
sh._p.MovedTo = nil
Env.run(1)
check("at home with nobody near: it stands still", sh._p.MovedTo == nil)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
