--!nocheck
--[[
	The NPC gore, run headless against the simulated client (sim/env + sim/client): the REAL
	CombatGore and CombatBlood modules, frame by frame, on R6 rigs of every shape. What it proves:
	  1  the stages are earned by health share, in order (right arm 75%, left arm 50%, jaw 25%, head
	     on the killing blow only) at any MaxHealth
	  2  only R6 NPCs: never a player's character, never an R15 rig, never a model missing a limb
	  3  each stage plays exactly once, in order, a beat apart when one blow earns several; a
	     prediction and the server's word for the same blow never play it twice; a body made whole
	     (healed to full) stops mid-sequence, is restored, and comes apart again from the start
	  4  ARM: the real arm (and whatever hangs on it) is hidden on this client only; a dressed copy
	     is thrown out on that side, along the blow and up, spinning, on real physics that never
	     touches a fighter; its torn end and the shoulder stump are the gore kit's own pieces,
	     at their measured places, welded on
	  5  JAW: the smashed head in the NPC's own skin tone replaces the head (face hidden), welded
	     to it, teeth thrown, flesh hanging on ball sockets
	  6  HEAD: head, face, hat and jaw gone; neck stump and skull base on the torso; the mist, the
	     droplets (real flights that land and splat), the chunks, the fountain; the camera kick
	     only when close
	  7  the kit fits ANY R6 body: scaled rigs, stretched parts, any pose and heading (every piece
	     sits where the kit puts it relative to its host); no templates at all still works
	  8  the hole in the torso is never used; the legs are never touched; nothing is left behind:
	     gibs fade and are gone after GibLife, bleeding stops, a removed NPC is forgotten

	    lune run tests/gore_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local Client = require("./sim/client")(Env)
local roblox = require("@lune/roblox")
local V3, CF = Env.Vector3, Env.CFrame
local Enum = roblox.Enum
local Color3 = roblox.Color3
local process = require("@lune/process")
math.randomseed(tonumber(process.env.SEED or "") or 11)

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
local function section(name)
	print("\n== " .. name)
end
local function near(a, b, tol)
	return (a - b).Magnitude <= (tol or 1e-3)
end

---------------------------------------------------------------------------
-- the world the module sees: players, the workspace tree, CombatFX (recorded)
---------------------------------------------------------------------------
local ws = Env.workspace
ws.DescendantAdded = Env.Signal.new()
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
function Env.Players:GetPlayerFromCharacter(m)
	for _, p in ipairs(self._list) do
		if p.Character == m then
			return p
		end
	end
	return nil
end

local fxLog = { Sound = {}, Give = {}, Camera = {} }
Env.modules["ReplicatedStorage/Combat/CombatFX"] = {
	Sound = function(name, pos, pitch)
		table.insert(fxLog.Sound, { Name = name, Pos = pos, T = Env.now() })
	end,
	Give = function(char, peak, omega, hold)
		table.insert(fxLog.Give, { Char = char, Peak = peak, Omega = omega })
	end,
	Camera = function(hum, profile, dir, scale)
		table.insert(fxLog.Camera, { Profile = profile, Dir = dir, Scale = scale })
	end,
}
local warns = {}
Env.extraGlobals.warn = function(...)
	table.insert(warns, table.concat(table.pack(...), " "))
	print("[warn]", ...)
end

-- the gore kit and the smashed-jaw head, as the build puts them in ReplicatedStorage.Combat.Gore
local KIT_NAMES = { "torso", "left.leg", "left.hip", "debry", "right.arm", "right.shoulder", "right.hip", "left.arm", "right.leg", "head", "left.shoulder", "neck" }
local function makeTemplates()
	local g = Client.new("Folder")
	g.Name = "Gore"
	local kit = Client.new("Model")
	kit.Name = "GoreKit"
	kit.Parent = g
	for _, n in ipairs(KIT_NAMES) do
		local p = Client.new(if n == "torso" then "Part" else "UnionOperation")
		p.Name = n
		p.Anchored = true
		p.Color = if n == "head" then Color3.fromRGB(237, 234, 234) else Color3.fromRGB(151, 0, 0)
		p.Transparency = if n == "torso" then 1 else 0
		p.Parent = kit
		local w = Client.new("Weld") -- (the kit's own joints must never come along)
		w.Parent = p
	end
	local jaw = Client.new("MeshPart")
	jaw.Name = "JawHead"
	jaw.Color = Color3.fromRGB(234, 184, 146)
	jaw.Size = V3.new(1.2105, 1.3682, 1.2155)
	jaw.Parent = g
	local sa = Client.new("SurfaceAppearance")
	sa.Parent = jaw
	local eyes = Client.new("Decal")
	eyes.Name = "Eyes"
	eyes.Parent = jaw
	return g
end
local templatesFolder = makeTemplates()
Env.combatFolder._children.Gore = templatesFolder

local Config = Env.load("ReplicatedStorage/Combat/CombatConfig")
local Blood = Env.load("ReplicatedStorage/Combat/CombatBlood")
local Gore = Env.load("ReplicatedStorage/Combat/CombatGore")
local GC = Config.Gore
local KIT = Gore.Kit

---------------------------------------------------------------------------
-- rigs
---------------------------------------------------------------------------
local SKIN = Color3.fromRGB(124, 92, 70)
-- an R6 rig: opts.Scale (uniform), opts.Stretch (per-axis Vector3), opts.CFrame (torso), Health,
-- Max, RigType, Shirt, Hat (on the head), Watch (on the right arm), Face, Missing (a part name)
local function rig(name, opts)
	opts = opts or {}
	local s = opts.Stretch or V3.new(1, 1, 1) * (opts.Scale or 1)
	local m = Client.new("Model")
	m.Name = name
	m._p.AncestryChanged = Env.Signal.new()
	local hum = Client.new("Humanoid")
	hum.Name = "Humanoid"
	hum.MaxHealth = opts.Max or 100
	hum.Health = opts.Health or hum.MaxHealth
	hum.RigType = opts.RigType or Enum.HumanoidRigType.R6
	hum._p.HealthChanged = Env.Signal.new()
	hum.Parent = m
	local base = opts.CFrame or CF.new(0, 3, 0)
	local parts = {}
	local function part(n, size, off)
		if opts.Missing == n then
			return nil
		end
		local p = Client.new("Part")
		p.Name = n
		p.Size = V3.new(size.X * s.X, size.Y * s.Y, size.Z * s.Z)
		p.CFrame = base * CF.new(off.X * s.X, off.Y * s.Y, off.Z * s.Z)
		p.Color = opts.Skin or SKIN
		p.Parent = m
		parts[n] = p
		return p
	end
	part("HumanoidRootPart", V3.new(2, 2, 1), V3.zero).Transparency = 1
	part("Torso", V3.new(2, 2, 1), V3.zero)
	local head = part("Head", V3.new(2, 1, 1), V3.new(0, 1.5, 0))
	part("Right Arm", V3.new(1, 2, 1), V3.new(1.5, 0, 0))
	part("Left Arm", V3.new(1, 2, 1), V3.new(-1.5, 0, 0))
	part("Right Leg", V3.new(1, 2, 1), V3.new(0.5, -2, 0))
	part("Left Leg", V3.new(1, 2, 1), V3.new(-0.5, -2, 0))
	if head and opts.Face ~= false then
		local face = Client.new("Decal")
		face.Name = "face"
		face.Parent = head
	end
	if opts.Shirt then
		local sh = Client.new("Shirt")
		sh.Name = "Shirt"
		sh.Parent = m
	end
	local function accessory(n, on)
		local acc = Client.new("Accessory")
		acc.Name = n
		local h = Client.new("Part")
		h.Name = "Handle"
		h.CFrame = on.CFrame
		h.Parent = acc
		local w = Client.new("Weld")
		w.Name = "AccessoryWeld"
		w.Part0 = h
		w.Part1 = on
		w.Parent = h
		acc.Parent = m
		return h
	end
	if opts.Hat and head then
		parts.Hat = accessory("Hat", head)
	end
	if opts.Watch and parts["Right Arm"] then
		parts.Watch = accessory("Watch", parts["Right Arm"])
	end
	m.Parent = ws
	-- (the engine: everything that enters the workspace fires DescendantAdded)
	ws.DescendantAdded:Fire(m)
	for _, d in ipairs(m:GetDescendants()) do
		ws.DescendantAdded:Fire(d)
	end
	Env.step(1 / 60)
	return m, hum, parts
end

local function setHealth(hum, h)
	hum.Health = h
	hum._p.HealthChanged:Fire(h)
end
local function remove(m)
	m.Parent = nil
	if m._p.AncestryChanged then
		m._p.AncestryChanged:Fire(m, nil)
	end
end
local function holder()
	return ws:FindFirstChild("CombatGore")
end
local function gibs(className, name)
	local out = {}
	local h = holder()
	for _, c in ipairs(if h then h:GetChildren() else {}) do
		if (not className or c.ClassName == className) and (not name or c.Name == name) and not c._p.Destroyed then
			table.insert(out, c)
		end
	end
	return out
end
local function childNamed(m, n)
	local out = {}
	for _, c in ipairs(m:GetChildren()) do
		if c.Name == n and not c._p.Destroyed then
			table.insert(out, c)
		end
	end
	return out
end
local function soundNames()
	local out = {}
	for _, s in ipairs(fxLog.Sound) do
		table.insert(out, s.Name)
	end
	return table.concat(out, ",")
end
local function resetLogs()
	table.clear(fxLog.Sound)
	table.clear(fxLog.Give)
	table.clear(fxLog.Camera)
	table.clear(warns)
end
-- what the kit says a piece's world frame is on a host (torso / arm / head), scaled per axis
local function expected(entry, host, std)
	local k = V3.new(host.Size.X / std.X, host.Size.Y / std.Y, host.Size.Z / std.Z)
	return host.CFrame * CF.new(entry.Pos.X * k.X, entry.Pos.Y * k.Y, entry.Pos.Z * k.Z) * entry.Rot, k
end
local function sameFrame(a, b, tol)
	tol = tol or 1e-3
	return near(a.Position, b.Position, tol) and near(a.RightVector, b.RightVector, tol) and near(a.UpVector, b.UpVector, tol) and near(a.LookVector, b.LookVector, tol)
end
local STD = { Torso = V3.new(2, 2, 1), Arm = V3.new(1, 2, 1), Head = V3.new(2, 1, 1) }

Gore.Start()

---------------------------------------------------------------------------
section("1  thresholds: the stage each health share earns")
---------------------------------------------------------------------------
do
	local cases = {
		{ 100, 100, 0 }, { 76, 100, 0 }, { 75.01, 100, 0 }, { 75, 100, 1 }, { 60, 100, 1 }, { 50.5, 100, 1 }, { 50, 100, 2 },
		{ 26, 100, 2 }, { 25, 100, 3 }, { 1, 100, 3 }, { 0.001, 100, 3 }, { 0, 100, 4 }, { -5, 100, 4 },
		{ 187.5, 250, 1 }, { 125, 250, 2 }, { 62.5, 250, 3 }, { 62.6, 250, 2 }, { 0, 250, 4 }, { 10, 0, 0 },
	}
	local bad = {}
	for _, c in ipairs(cases) do
		local got = Gore.StageFor(c[1], c[2])
		if got ~= c[3] then
			table.insert(bad, string.format("%g/%g -> %d (want %d)", c[1], c[2], got, c[3]))
		end
	end
	check("health share -> stage at every boundary, any MaxHealth (" .. #cases .. " cases)", #bad == 0, table.concat(bad, "; "))
	check("the head only on the killing blow: 0.001 health is still stage 3", Gore.StageFor(0.001, 100) == 3)
	local mono = true
	local last = 0
	for h = 100, 0, -0.25 do
		local st = Gore.StageFor(h, 100)
		if st < last then
			mono = false
		end
		last = st
	end
	check("monotonic: less health never earns an earlier stage", mono)
	check("config: 4 stages, descending, the last at 0", #GC.Stages == 4 and GC.Stages[1] > GC.Stages[2] and GC.Stages[2] > GC.Stages[3] and GC.Stages[4] == 0)
end

---------------------------------------------------------------------------
section("2  only R6 NPCs")
---------------------------------------------------------------------------
do
	local npc = rig("NPC")
	check("an R6 NPC qualifies", Gore.IsNpc(npc))
	local pc = rig("PlayerChar")
	Env.player("Someone", 0.05, pc)
	check("a player's character never does", not Gore.IsNpc(pc))
	resetLogs()
	Gore.Hit(pc, 0, V3.new(0, 0, -1))
	setHealth(pc:FindFirstChildOfClass("Humanoid"), 0)
	Env.run(0.5)
	check("... and a player's character takes a killing blow with no gore at all", Gore.StageOf(pc) == 0 and #fxLog.Sound == 0 and Gore.Bodies[pc] == nil and pc:FindFirstChild("Head").LocalTransparencyModifier == 0)
	local r15 = rig("R15", { RigType = Enum.HumanoidRigType.R15 })
	check("an R15 rig does not", not Gore.IsNpc(r15))
	local noArm = rig("NoArm", { Missing = "Left Arm" })
	check("a model missing a limb does not", not Gore.IsNpc(noArm))
	local noHead = rig("NoHead", { Missing = "Head" })
	check("a model missing its head does not", not Gore.IsNpc(noHead))
	local plain = Client.new("Model")
	plain.Parent = ws
	check("a model without a Humanoid does not", not Gore.IsNpc(plain))
	check("nil / a part does not", not Gore.IsNpc(nil) and not Gore.IsNpc(Client.new("Part")))
	Gore.Hit(r15, 0, V3.new(0, 0, -1))
	Gore.Hit(noArm, 0, V3.new(0, 0, -1))
	check("hits on the others do nothing", Gore.StageOf(r15) == 0 and Gore.StageOf(noArm) == 0 and #fxLog.Sound == 0)
	for _, m in ipairs({ npc, pc, r15, noArm, noHead, plain }) do
		remove(m)
	end
	check("removed NPCs are forgotten", Gore.Bodies[npc] == nil)
end

---------------------------------------------------------------------------
section("3  order: one stage per threshold, in order, exactly once")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("Walker", { Shirt = true })
	local drive = V3.new(1, 0, 0)
	local steps = { { 90, 0, "" }, { 80, 0, "" }, { 70, 1, "GoreTear" }, { 60, 1, "GoreTear" }, { 45, 2, "GoreTear,GoreTear" }, { 30, 2, "GoreTear,GoreTear" }, { 20, 3, "GoreTear,GoreTear,GoreSnap" }, { 5, 3, "GoreTear,GoreTear,GoreSnap" }, { 0, 4, "GoreTear,GoreTear,GoreSnap,GoreBurst" } }
	for _, st in ipairs(steps) do
		Gore.Hit(m, st[1], drive)
		setHealth(hum, st[1]) -- (the server's word for the same blow)
		Env.run(0.3)
		check(string.format("health %d -> stage %d, sounds [%s]", st[1], st[2], st[3]), Gore.StageOf(m) == st[2] and soundNames() == st[3], "stage " .. Gore.StageOf(m) .. " sounds " .. soundNames())
	end
	check("stage 1 took the RIGHT arm", P["Right Arm"].LocalTransparencyModifier == 1)
	check("no warnings from any stage", #warns == 0, table.concat(warns, " | "))
	-- the same blow again, and the server repeating itself: nothing replays
	local n = #fxLog.Sound
	Gore.Hit(m, 0, drive)
	setHealth(hum, 0)
	Env.run(0.5)
	check("a repeated killing blow never replays anything", #fxLog.Sound == n and Gore.StageOf(m) == 4)
	remove(m)
end

do
	resetLogs()
	local m, hum = rig("OneShot")
	Gore.Hit(m, 10, V3.new(0, 0, -1))
	Env.step(1 / 60)
	check("one blow to 10%: the right arm plays on the blow itself", Gore.StageOf(m) == 1 and #fxLog.Sound == 1)
	Env.run(0.6)
	local t = {}
	for _, s in ipairs(fxLog.Sound) do
		table.insert(t, s.T)
	end
	check("... then the left arm and the jaw, in order", soundNames() == "GoreTear,GoreTear,GoreSnap", soundNames())
	check("... each a beat (Config.Gore.Stagger) apart", #t == 3 and math.abs((t[2] - t[1]) - GC.Stagger) < 1 / 30 and math.abs((t[3] - t[2]) - GC.Stagger) < 1 / 30, string.format("%.3f %.3f", (t[2] or 0) - (t[1] or 0), (t[3] or 0) - (t[2] or 0)))
	setHealth(hum, 10)
	Env.run(0.3)
	check("the server's word for the same blow adds nothing", #fxLog.Sound == 3)
	remove(m)

	resetLogs()
	local k, khum = rig("Obliterated")
	Gore.Hit(k, -40, V3.new(0, 0, 1))
	setHealth(khum, 0)
	Env.run(1)
	check("a single killing blow from full plays all four, in order, once each", soundNames() == "GoreTear,GoreTear,GoreSnap,GoreBurst" and Gore.StageOf(k) == 4, soundNames())
	remove(k)
end

do
	-- a prediction the server never confirmed (the blow was blocked): the server's health rules
	-- from then on (it can only carry the body further, never undo it)
	resetLogs()
	local m, hum = rig("Mispredicted")
	Gore.Hit(m, 70, V3.new(0, 0, -1))
	Env.run(0.2)
	setHealth(hum, 95) -- (the chip damage of a blocked blow)
	Env.run(0.2)
	check("a blow predicted but blocked: stage 1 stays, nothing more", Gore.StageOf(m) == 1 and #fxLog.Sound == 1)
	setHealth(hum, 72)
	Env.run(0.2)
	check("... and later health above the next threshold earns nothing new", Gore.StageOf(m) == 1)
	setHealth(hum, 48)
	Env.run(0.2)
	check("... the next threshold still plays the next stage", Gore.StageOf(m) == 2 and #fxLog.Sound == 2)
	remove(m)
end

---------------------------------------------------------------------------
section("4  healed to full: whole again, and it comes apart again")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("Dummy", { Hat = true, Watch = true })
	setHealth(hum, 20)
	Env.run(0.6)
	check("down to 20%: arms and jaw gone", Gore.StageOf(m) == 3 and P["Right Arm"].LocalTransparencyModifier == 1 and P["Left Arm"].LocalTransparencyModifier == 1 and P.Head.LocalTransparencyModifier == 1)
	check("the watch on the torn arm went with it", P.Watch.LocalTransparencyModifier == 1)
	setHealth(hum, 100)
	Env.run(0.1)
	local shown = true
	for _, n in ipairs({ "Right Arm", "Left Arm", "Head", "Watch", "Hat" }) do
		if P[n].LocalTransparencyModifier ~= 0 then
			shown = false
		end
	end
	check("healed to full: every hidden part shown again", shown)
	check("... the face too", P.Head:FindFirstChild("face").LocalTransparencyModifier == 0)
	local leftovers = 0
	for _, c in ipairs(m:GetDescendants()) do
		if not c._p.Destroyed and (string.match(c.Name, "^Gore") or table.find(KIT_NAMES, c.Name)) then
			leftovers += 1
		end
	end
	check("... every stump, jaw and strand removed from the body", leftovers == 0, leftovers)
	check("... stage 0", Gore.StageOf(m) == 0)
	resetLogs()
	setHealth(hum, 70)
	Env.run(0.3)
	check("... and it comes apart again from the start", Gore.StageOf(m) == 1 and soundNames() == "GoreTear")

	-- healed to full in the middle of a staggered sequence: the rest never plays
	resetLogs()
	setHealth(hum, 100)
	Env.run(0.05)
	setHealth(hum, 5)
	Env.step(1 / 60)
	setHealth(hum, 100) -- (before the second stage's beat)
	Env.run(0.8)
	check("healed mid-sequence: the sequence stops, the body is whole", Gore.StageOf(m) == 0 and P["Left Arm"].LocalTransparencyModifier == 0 and P["Right Arm"].LocalTransparencyModifier == 0, "stage " .. Gore.StageOf(m) .. " sounds " .. soundNames())
	resetLogs()
	setHealth(hum, 49)
	Env.run(0.5)
	check("... and the next beating plays from the first stage again", soundNames() == "GoreTear,GoreTear" and Gore.StageOf(m) == 2, soundNames())
	remove(m)
end

---------------------------------------------------------------------------
section("5  ARM: torn off, thrown, the stump on the shoulder")
---------------------------------------------------------------------------
local function armCase(label, opts, drive, side)
	resetLogs()
	local m, hum, P = rig(label, opts)
	local before = #gibs("Model", "GoreArm")
	local torso = P.Torso
	local arm = if side == "Right" then P["Right Arm"] else P["Left Arm"]
	local armCf = arm.CFrame
	Gore.Hit(m, if side == "Right" then 74 else 49, drive)
	Env.step(1 / 60)
	if side == "Left" then
		Env.run(0.3)
	end
	local list = gibs("Model", "GoreArm")
	local gib = list[#list]
	check(label .. ": a severed arm is thrown (one per stage)", #list == before + (if side == "Left" then 2 else 1))
	if not gib then
		remove(m)
		return
	end
	local copy = gib:FindFirstChild(arm.Name)
	check(label .. ": ... it is a copy of THAT arm (its name, colour, size), visible", copy ~= nil and copy.Color == arm.Color and near(copy.Size, arm.Size) and copy.LocalTransparencyModifier == 0)
	check(label .. ": ... the real arm hidden on this client only (Transparency untouched)", arm.LocalTransparencyModifier == 1 and arm.Transparency == 0)
	check(label .. ": ... starts exactly where the arm was", copy and sameFrame(copy.CFrame, armCf))
	check(label .. ": ... on real physics that never touches a fighter", copy and not copy.Anchored and copy.CanCollide and copy.CollisionGroup == "Debris" and not copy.CanQuery and not copy.CanTouch and not copy.Massless)
	check(label .. ": ... no joint came along", copy and copy:FindFirstChildOfClass("Weld") == nil and copy:FindFirstChildOfClass("Motor6D") == nil)
	local ghum = gib:FindFirstChildOfClass("Humanoid")
	check(label .. ": ... dressed like the NPC (a Humanoid to wear the sleeve, which never thinks, never shows a bar)", ghum ~= nil and ghum.EvaluateStateMachine == false and ghum.RequiresNeck == false and ghum.BreakJointsOnDeath == false and ghum.HealthDisplayType == Enum.HumanoidHealthDisplayType.AlwaysOff)
	check(label .. ": ... the NPC's shirt (when it has one)", (gib:FindFirstChildOfClass("Shirt") ~= nil) == (opts.Shirt == true))
	local v = copy.AssemblyLinearVelocity
	local out = if side == "Right" then torso.CFrame.RightVector else -torso.CFrame.RightVector
	local flatDrive = V3.new(drive.X, 0, drive.Z).Unit
	-- (the part of the blow that does not drive the arm into the body carries it; never through the torso)
	local tangential = flatDrive - out * math.min(0, flatDrive:Dot(out))
	local carried = tangential.Magnitude < 0.2 or v:Dot(tangential.Unit) > 5
	check(label .. ": ... thrown with the blow, out to its own side (never through the body) and up", carried and v:Dot(out) > 2 and v.Y > 8, tostring(v))
	check(label .. ": ... tumbling", copy.AssemblyAngularVelocity.Magnitude > 5)
	local wound = nil
	for _, c in ipairs(gib:GetChildren()) do
		if c.Name == (if side == "Right" then "right.arm" else "left.arm") then
			wound = c
		end
	end
	check(label .. ": ... its torn end is the kit's " .. (if side == "Right" then "right.arm" else "left.arm") .. " piece", wound ~= nil and wound.ClassName == "UnionOperation")
	if wound then
		local want = expected(if side == "Right" then KIT.RightEnd else KIT.LeftEnd, copy, STD.Arm)
		check(label .. ": ... at the arm's top, where the kit puts it", sameFrame(wound.CFrame, want))
		local w = wound:FindFirstChildOfClass("Weld")
		check(label .. ": ... welded to the arm copy, the weld holding exactly that place", w and w.Part0 == copy and w.Part1 == wound and sameFrame(copy.CFrame * w.C0, wound.CFrame))
		check(label .. ": ... never collides, never blocks a hit, weighs nothing", not wound.CanCollide and not wound.CanQuery and wound.Massless and not wound.Anchored)
	end
	local stump = nil
	for _, c in ipairs(m:GetChildren()) do
		if c.Name == (if side == "Right" then "right.shoulder" else "left.shoulder") and not c._p.Destroyed then
			stump = c
		end
	end
	check(label .. ": ... the shoulder stump is the kit's piece, on the body", stump ~= nil and stump.ClassName == "UnionOperation")
	if stump then
		local want, k = expected(if side == "Right" then KIT.RightStump else KIT.LeftStump, torso, STD.Torso)
		check(label .. ": ... exactly where the kit puts it on this torso (scaled " .. string.format("%.2f,%.2f,%.2f", k.X, k.Y, k.Z) .. ")", sameFrame(stump.CFrame, want), tostring(stump.CFrame) .. " vs " .. tostring(want))
		local local_ = torso.CFrame:PointToObjectSpace(stump.CFrame.Position)
		check(label .. ": ... on the correct shoulder", (side == "Right" and local_.X > 0) or (side == "Left" and local_.X < 0))
		local w = stump:FindFirstChildOfClass("Weld")
		check(label .. ": ... welded to the torso (follows every pose)", w and w.Part0 == torso and sameFrame(torso.CFrame * w.C0, stump.CFrame))
		check(label .. ": ... sized for this body", near(stump.Size, V3.new(KIT.RightStump.Size.X * k.X, KIT.RightStump.Size.Y * k.Y, KIT.RightStump.Size.Z * k.Z), 1e-3))
		check(label .. ": ... the kit's own joint never came along", stump:FindFirstChildOfClass("Weld") == w and #childNamed(stump, "Weld") == 1)
		local att = stump:FindFirstChild("GoreBleed")
		check(label .. ": ... and it bleeds (spurts and a drip on the stump)", att ~= nil and att:FindFirstChildOfClass("ParticleEmitter") ~= nil)
	end
	local give = fxLog.Give[#fxLog.Give]
	check(label .. ": ... the body jerks with it", give and give.Char == m)
	check(label .. ": ... the legs are never touched", P["Right Leg"].LocalTransparencyModifier == 0 and P["Left Leg"].LocalTransparencyModifier == 0)
	remove(m)
end

armCase("standard", { Shirt = true }, V3.new(0, 0, -1), "Right")
armCase("turned+tilted", { CFrame = CF.new(12, 4, -7) * CF.Angles(0.25, 2.1, -0.15) }, V3.new(0.6, 0, 0.8), "Right")
armCase("left arm", { Shirt = true, CFrame = CF.new(-3, 3, 5) * CF.Angles(0, -0.9, 0) }, V3.new(-1, 0, 0.2), "Left")
armCase("giant x1.8", { Scale = 1.8, CFrame = CF.new(0, 5.4, 0) }, V3.new(0, 0, 1), "Right")
armCase("tiny x0.5", { Scale = 0.5, CFrame = CF.new(0, 1.5, 0) }, V3.new(1, 0, 0), "Left")
armCase("stretched", { Stretch = V3.new(1.3, 0.8, 1.6) }, V3.new(0.3, 0, -1), "Right")

---------------------------------------------------------------------------
section("6  JAW: the smashed head in the NPC's own skin")
---------------------------------------------------------------------------
local function jawCase(label, opts)
	resetLogs()
	local m, hum, P = rig(label, opts)
	local head = P.Head
	setHealth(hum, 20)
	Env.run(0.6)
	local jaw = m:FindFirstChild("GoreJaw")
	check(label .. ": the jaw stage played third", Gore.StageOf(m) == 3 and soundNames() == "GoreTear,GoreTear,GoreSnap", soundNames())
	check(label .. ": the smashed head replaces the head (the head and its face hidden)", jaw ~= nil and head.LocalTransparencyModifier == 1 and (head:FindFirstChild("face") == nil or head:FindFirstChild("face").LocalTransparencyModifier == 1))
	if not jaw then
		remove(m)
		return
	end
	check(label .. ": ... it is the JawHead mesh (its surface map and eyes come with it)", jaw.ClassName == "MeshPart" and jaw:FindFirstChildOfClass("SurfaceAppearance") ~= nil and jaw:FindFirstChild("Eyes") ~= nil)
	check(label .. ": ... coloured with THIS NPC's skin", jaw.Color == head.Color, tostring(jaw.Color))
	local s = head.Size.Y / STD.Head.Y
	local want = head.CFrame * CF.new(KIT.Jaw.Pos * s) * KIT.Jaw.Rot
	check(label .. ": ... sized for this head and seated where the kit's head sat", near(jaw.Size, KIT.Jaw.Size * s, 1e-3) and sameFrame(jaw.CFrame, want))
	local w = jaw:FindFirstChildOfClass("Weld")
	check(label .. ": ... welded to the head (moves with every reaction)", w and w.Part0 == head and sameFrame(head.CFrame * w.C0, jaw.CFrame))
	check(label .. ": ... never collides or blocks a hit", not jaw.CanCollide and not jaw.CanQuery and jaw.Massless)
	local strands = childNamed(m, "GoreFlesh")
	local swinging = #strands == 3
	for _, st in ipairs(strands) do
		local ball = st:FindFirstChildOfClass("BallSocketConstraint")
		if not (ball and ball.LimitsEnabled and ball.Attachment0 and ball.Attachment1 and ball.Attachment1.Parent == st) then
			swinging = false
		end
	end
	check(label .. ": ... three strands of flesh hang and swing on ball sockets", swinging)
	local teeth = gibs("Part", "GoreTooth")
	local flying = #teeth >= 5
	for _, t in ipairs(teeth) do
		if t.Anchored or t.CollisionGroup ~= "Debris" or t.AssemblyLinearVelocity.Magnitude < 8 then
			flying = false
		end
	end
	check(label .. ": ... teeth fly out (unanchored, Debris group, fast)", flying, #teeth)
	local give = fxLog.Give[#fxLog.Give]
	check(label .. ": ... the head snaps back", give and give.Peak.NeckPitch and give.Peak.NeckPitch > 20)
	remove(m)
end
jawCase("pale", { Skin = Color3.fromRGB(245, 205, 178) })
jawCase("dark", { Skin = Color3.fromRGB(86, 58, 40), CFrame = CF.new(4, 3, 2) * CF.Angles(0, 0.7, 0) })
jawCase("green goblin x1.4", { Skin = Color3.fromRGB(90, 150, 60), Scale = 1.4, CFrame = CF.new(0, 4.2, 0) })
jawCase("faceless", { Face = false })

---------------------------------------------------------------------------
section("7  HEAD: the final blow bursts it")
---------------------------------------------------------------------------
local function burstCase(label, opts, camDist)
	resetLogs()
	local m, hum, P = rig(label, opts)
	local head, torso = P.Head, P.Torso
	ws.CurrentCamera.CFrame = CF.new(head.Position + V3.new(0, 2, camDist))
	setHealth(hum, 20)
	Env.run(0.6)
	local emitsBefore = #Client.emits
	local drops0 = Blood.Stats.Drops
	local chunks0 = #gibs("UnionOperation", "GoreChunk") + #gibs("Part", "GoreChunk")
	Gore.Hit(m, -10, V3.new(0, 0, -1))
	setHealth(hum, 0)
	Env.step(1 / 60)
	check(label .. ": the killing blow bursts the head (stage 4)", Gore.StageOf(m) == 4 and fxLog.Sound[#fxLog.Sound].Name == "GoreBurst")
	check(label .. ": ... the head and its face gone", head.LocalTransparencyModifier == 1 and (head:FindFirstChild("face") == nil or head:FindFirstChild("face").LocalTransparencyModifier == 1))
	check(label .. ": ... the hat with it", not P.Hat or P.Hat.LocalTransparencyModifier == 1)
	check(label .. ": ... the smashed jaw and its flesh gone", #childNamed(m, "GoreJaw") == 0 and #childNamed(m, "GoreFlesh") == 0)
	local neck = nil
	local skull = nil
	for _, c in ipairs(m:GetChildren()) do
		if not c._p.Destroyed then
			local w = c:FindFirstChildOfClass("Weld")
			if c.Name == "neck" and w and w.Part0 == torso then
				neck = c
			elseif c.Name == "head" and w and w.Part0 == torso then
				skull = c
			end
		end
	end
	check(label .. ": ... what is left: the neck's torn stump, on the torso where the kit puts it", neck ~= nil and sameFrame(neck.CFrame, (expected(KIT.NeckStump, torso, STD.Torso))))
	check(label .. ": ... and the base of the skull", skull ~= nil and sameFrame(skull.CFrame, (expected(KIT.SkullBase, torso, STD.Torso))))
	local mist, core = 0, 0
	for i = emitsBefore + 1, #Client.emits do
		local e = Client.emits[i]
		if e.Emitter.Name == "Mist" then
			mist += e.Count
		elseif e.Emitter.Name == "Core" then
			core += e.Count
		end
	end
	check(label .. ": ... a huge red mist (" .. mist .. " clouds, " .. core .. " dense core)", mist >= 30 and core >= 12)
	local mistAt = nil
	for i = emitsBefore + 1, #Client.emits do
		if Client.emits[i].Emitter.Name == "Mist" then
			mistAt = Client.emits[i].CFrame.Position
		end
	end
	check(label .. ": ... bursting from where the head was", mistAt and near(mistAt, head.Position, 1e-3))
	check(label .. ": ... droplets thrown all round (real flights)", Blood.Stats.Drops - drops0 >= GC.BurstDrops, Blood.Stats.Drops - drops0)
	local chunks = #gibs("UnionOperation", "GoreChunk") + #gibs("Part", "GoreChunk") - chunks0
	local bones = #gibs("Part", "GoreBone")
	check(label .. ": ... chunks of flesh and bits of skull on real arcs", chunks + bones >= GC.BurstChunks and chunks > 0 and bones > 0, chunks .. "+" .. bones)
	local up = true
	for _, c in ipairs(gibs(nil, "GoreChunk")) do
		if c.Anchored or c.CollisionGroup ~= "Debris" then
			up = false
		end
	end
	check(label .. ": ... all on physics that never touches a fighter", up)
	check(label .. ": ... the neck pumps a fountain", torso:FindFirstChild("GoreBleed") ~= nil)
	if camDist < 26 then
		check(label .. ": ... close: the camera takes the blast", #fxLog.Camera == 1 and fxLog.Camera[1].Profile == "StompNear" and fxLog.Camera[1].Scale >= 0.2 and fxLog.Camera[1].Scale <= 0.8)
	else
		check(label .. ": ... far away: the camera is left alone", #fxLog.Camera == 0)
	end
	Env.run(3)
	check(label .. ": ... droplets landed and splatted on the ground", Blood.Stats.Landed > 0 and #Blood.Splats > 0)
	remove(m)
end
burstCase("close", { Hat = true }, 8)
burstCase("far", { Hat = true, CFrame = CF.new(30, 3, 0) }, 60)
burstCase("scaled x2", { Scale = 2, CFrame = CF.new(0, 6, 0) }, 12)

---------------------------------------------------------------------------
section("8  any R6 body: no templates at all, odd builds, death without Hit")
---------------------------------------------------------------------------
do
	Env.combatFolder._children.Gore = nil
	resetLogs()
	local m, hum = rig("Bare")
	setHealth(hum, 0)
	Env.run(1)
	check("no gore kit in the place: every stage still plays (plain flesh stand-ins), no errors", Gore.StageOf(m) == 4 and soundNames() == "GoreTear,GoreTear,GoreSnap,GoreBurst" and #warns == 0, table.concat(warns, " | "))
	local stand = false
	for _, c in ipairs(m:GetChildren()) do
		if c.Name == "right.shoulder" and c.ClassName == "Part" then
			stand = true
		end
	end
	check("... the stand-in stump is there", stand)
	remove(m)
	Env.combatFolder._children.Gore = templatesFolder
end
do
	resetLogs()
	local m, hum, P = rig("NoFace", { Face = false, Max = 350, Health = 350 })
	setHealth(hum, 262.5)
	Env.run(0.2)
	check("MaxHealth 350: 75% (262.5) takes the right arm", Gore.StageOf(m) == 1)
	setHealth(hum, 0)
	Env.run(1)
	check("dying without a Hit (a fall, the void, a script) still ends in the burst", Gore.StageOf(m) == 4 and #warns == 0)
	remove(m)
end
do
	-- an NPC that turns up later (spawned in) is watched by itself
	resetLogs()
	local m, hum = rig("Spawned")
	ws.DescendantAdded:Fire(hum)
	Env.run(0.05)
	check("an NPC added later is watched", Gore.Bodies[m] ~= nil)
	setHealth(hum, 70)
	Env.run(0.2)
	check("... and comes apart on its own health", Gore.StageOf(m) == 1)
	remove(m)
	Env.run(0.1)
	setHealth(hum, 10)
	Env.run(0.5)
	check("removed mid-fight: forgotten, nothing plays on a body that's gone", Gore.Bodies[m] == nil and #fxLog.Sound == 1)
end
do
	resetLogs()
	GC.Enabled = false
	local m, hum = rig("Disabled")
	setHealth(hum, 0)
	Gore.Hit(m, 0, V3.new(0, 0, -1))
	Env.run(0.5)
	check("Config.Gore.Enabled = false: nothing at all", Gore.StageOf(m) == 0 and #fxLog.Sound == 0)
	GC.Enabled = true
	remove(m)
end
do
	-- a stage whose body part is already gone (a script removed an arm): skipped, the order holds
	resetLogs()
	local m, hum, P = rig("Armless")
	P["Right Arm"].Parent = nil
	setHealth(hum, 20)
	Env.run(0.6)
	check("a body part removed by something else: that stage passes quietly, the rest in order", Gore.StageOf(m) == 3 and soundNames() == "GoreTear,GoreSnap" and #warns == 0, soundNames())
	remove(m)
end

---------------------------------------------------------------------------
section("9  never the torso hole; nothing left behind")
---------------------------------------------------------------------------
do
	local used = {}
	for _, inst in ipairs(Client.all) do
		if table.find(KIT_NAMES, inst.Name) and inst.Parent ~= nil and inst.Parent.Name ~= "GoreKit" then
			used[inst.Name] = true
		end
	end
	check("the kit's torso piece (the hole) was never used anywhere", used.torso == nil)
	check("... nor the leg / hip pieces", used["left.leg"] == nil and used["right.leg"] == nil and used["left.hip"] == nil and used["right.hip"] == nil)
	local names = {}
	for n in pairs(used) do
		table.insert(names, n)
	end
	table.sort(names)
	check("... the pieces used: shoulders, arm ends, neck, skull base, chunks", used["right.shoulder"] and used["left.shoulder"] and used["right.arm"] and used["left.arm"] and used.neck and used.head, table.concat(names, ","))
	local kitChunks = 0
	for _, inst in ipairs(Client.all) do
		if inst.Name == "GoreChunk" and inst.ClassName == "UnionOperation" then
			kitChunks += 1
		end
	end
	check("... the flesh chunks are the kit's 'debry' piece", kitChunks > 0)
	check("the templates themselves are untouched (still 12 kit pieces and the jaw head)", #templatesFolder:FindFirstChild("GoreKit"):GetChildren() == 12 and templatesFolder:FindFirstChild("JawHead") ~= nil)

	Env.run(GC.GibLife + 2)
	local left = {}
	for _, c in ipairs(gibs()) do
		table.insert(left, c.Name)
	end
	check("after GibLife: every severed arm, tooth, chunk and bone has faded and is gone", #left == 0, table.concat(left, ","))
	Env.run(GC.BleedTime + 2)
	local bleeding = 0
	for _, e in ipairs(Client.instances("ParticleEmitter")) do
		local p = e.Parent
		if p and p.Name == "GoreBleed" and not e._p.Destroyed then
			bleeding += 1
		end
	end
	local mistLeft = 0
	for _, a in ipairs(Client.instances("Attachment")) do
		if a.Name == "GoreMist" and a.Parent then
			mistLeft += 1
		end
	end
	check("the bleeding stops and its emitters are cleaned up", bleeding == 0, bleeding)
	check("the mist is cleaned up", mistLeft == 0, mistLeft)
	local live = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live then
			live += 1
		end
	end
	check("every droplet has landed (none left flying)", live == 0, live)
	check("no body is still tracked", next(Gore.Bodies) == nil)
end

---------------------------------------------------------------------------
section("10  the sounds and camera profiles the stages use exist")
---------------------------------------------------------------------------
do
	for _, n in ipairs({ "GoreTear", "GoreSnap", "GoreBurst" }) do
		local def = Config.Sounds[n]
		local ok = def ~= nil and #def > 0
		for _, l in ipairs(def or {}) do
			if type(l.Id) ~= "string" or l.Id == "" or (l.Volume or 0) <= 0 then
				ok = false
			end
		end
		check("Config.Sounds." .. n .. " is a stack of real layers", ok)
	end
	check("Config.Camera.StompNear exists", Config.Camera.StompNear ~= nil)
	local function det(r)
		local x, y, z = r.RightVector, r.UpVector, -r.LookVector
		return x:Cross(y):Dot(z)
	end
	local okRot = true
	for name, e in pairs(KIT) do
		if e.Rot then
			local x, y, z = e.Rot.RightVector, e.Rot.UpVector, -e.Rot.LookVector
			if math.abs(det(e.Rot) - 1) > 1e-6 or math.abs(x:Dot(y)) > 1e-6 or math.abs(y:Dot(z)) > 1e-6 then
				okRot = false
				print("   bad rotation", name)
			end
		end
	end
	check("every kit rotation is a proper rotation (no mirrored piece)", okRot)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
