--!nocheck
--[[
	The NPC gore, run headless against the simulated client (sim/env + sim/client): the REAL
	CombatGore and CombatBlood modules, frame by frame, on R6 rigs of every shape. What it proves:
	  1  the stages are earned by health share, in order (right arm 75%, left arm 50%, the head on
	     the killing blow only) at any MaxHealth; there is no jaw stage
	  2  only R6 NPCs: never a player's character, never an R15 rig, never a model missing a limb
	  3  each stage plays exactly once, in order, a beat apart when one blow earns several; a
	     prediction and the server's word for the same blow never play it twice; a body made whole
	     (healed to full) stops mid-sequence, is restored, and comes apart again from the start
	  4  ARM: the real arm (and whatever hangs on it) is hidden on this client only; a dressed copy
	     is thrown out on that side, along the blow and up, spinning, on real physics that never
	     touches a fighter; its torn end and the shoulder stump are the gore kit's own pieces,
	     at their measured places, welded on
	  5  no jaw: the head stays whole (face and all) until the killing blow; no jaw piece, tooth or
	     strand ever appears
	  6  HEAD: head, face and hat gone; neck stump and skull base on the torso; the mist (the
	     place's own blood effects, burst big), the droplets, the chunks, the fountain; the camera
	     kick only when close; all the blood is the place's own effects, never a made emitter
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
	return g
end
local templatesFolder = makeTemplates()
Env.combatFolder._children.Gore = templatesFolder
Client.vfxFolder(require("./sim/vfx_templates"))

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
	for k, v in pairs(opts.Attrs or {}) do
		m:SetAttribute(k, v)
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
-- the nubs hanging on a body's arms (in the gore folder, welded to the hidden real arm)
local function nubsOf(P)
	local r, l = nil, nil
	for _, n in ipairs(gibs("Model", "GoreNub")) do
		local part = n.PrimaryPart
		local w = part and part:FindFirstChildOfClass("Weld")
		if w and w.Part0 == P["Right Arm"] then
			r = n
		elseif w and w.Part0 == P["Left Arm"] then
			l = n
		end
	end
	return r, l
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
		{ 26, 100, 2 }, { 25, 100, 2 }, { 1, 100, 2 }, { 0.001, 100, 2 }, { 0, 100, 3 }, { -5, 100, 3 },
		{ 187.5, 250, 1 }, { 125, 250, 2 }, { 62.5, 250, 2 }, { 0, 250, 3 }, { 10, 0, 0 },
	}
	local bad = {}
	for _, c in ipairs(cases) do
		local got = Gore.StageFor(c[1], c[2])
		if got ~= c[3] then
			table.insert(bad, string.format("%g/%g -> %d (want %d)", c[1], c[2], got, c[3]))
		end
	end
	check("health share -> stage at every boundary, any MaxHealth (" .. #cases .. " cases)", #bad == 0, table.concat(bad, "; "))
	check("the head only on the killing blow: 0.001 health is still stage 2", Gore.StageFor(0.001, 100) == 2)
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
	check("config: 3 stages (no jaw), descending, the last at 0", #GC.Stages == 3 and GC.Stages[1] > GC.Stages[2] and GC.Stages[3] == 0)
end

---------------------------------------------------------------------------
section("2  who comes apart: any R6 body - NPCs and players")
---------------------------------------------------------------------------
do
	local npc = rig("NPC")
	check("an R6 NPC is covered (and is an NPC)", Gore.Covers(npc) and Gore.IsNpc(npc))
	local pc = rig("PlayerChar")
	Env.player("Someone", 0.05, pc)
	check("a player's character is covered too (Config.Gore.Players), not as an NPC", Gore.Covers(pc) and not Gore.IsNpc(pc))
	resetLogs()
	Gore.Hit(pc, 60, V3.new(0, 0, -1))
	Env.run(0.3)
	check("... a player loses an arm like anyone", Gore.StageOf(pc) == 1 and soundNames() == "GoreTear", soundNames())
	-- with Config.Gore.Players off, players keep their limbs (even one first seen as an NPC)
	GC.Players = false
	local pc2 = rig("PlayerChar2")
	Env.player("Other", 0.05, pc2)
	resetLogs()
	Gore.Hit(pc2, 0, V3.new(0, 0, -1))
	Env.run(0.5)
	check("Players off: a player's character takes a killing blow with no gore at all", Gore.StageOf(pc2) == 0 and #fxLog.Sound == 0 and Gore.Bodies[pc2] == nil and pc2:FindFirstChild("Head").LocalTransparencyModifier == 0)
	GC.Players = true
	local r15 = rig("R15", { RigType = Enum.HumanoidRigType.R15 })
	check("an R15 rig is not", not Gore.Covers(r15))
	local noArm = rig("NoArm", { Missing = "Left Arm" })
	check("a model missing a limb is not", not Gore.Covers(noArm))
	local noHead = rig("NoHead", { Missing = "Head" })
	check("a model missing its head is not", not Gore.Covers(noHead))
	local plain = Client.new("Model")
	plain.Parent = ws
	check("a model without a Humanoid is not", not Gore.Covers(plain))
	check("nil / a part is not", not Gore.Covers(nil) and not Gore.Covers(Client.new("Part")))
	resetLogs()
	Gore.Hit(r15, 0, V3.new(0, 0, -1))
	Gore.Hit(noArm, 0, V3.new(0, 0, -1))
	check("hits on the others do nothing", Gore.StageOf(r15) == 0 and Gore.StageOf(noArm) == 0 and #fxLog.Sound == 0)
	for _, m in ipairs({ npc, pc, pc2, r15, noArm, noHead, plain }) do
		remove(m)
	end
	check("removed bodies are forgotten", Gore.Bodies[npc] == nil and Gore.Bodies[pc] == nil)
end

---------------------------------------------------------------------------
section("3  order: one stage per threshold, in order, exactly once")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("Walker", { Shirt = true })
	local drive = V3.new(1, 0, 0)
	local steps = { { 90, 0, "" }, { 80, 0, "" }, { 70, 1, "GoreTear" }, { 60, 1, "GoreTear" }, { 45, 2, "GoreTear,GoreTear" }, { 30, 2, "GoreTear,GoreTear" }, { 20, 2, "GoreTear,GoreTear" }, { 5, 2, "GoreTear,GoreTear" }, { 0, 3, "GoreTear,GoreTear,GoreBurst" } }
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
	check("a repeated killing blow never replays anything", #fxLog.Sound == n and Gore.StageOf(m) == 3)
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
	check("... then the left arm, and nothing more (no jaw)", soundNames() == "GoreTear,GoreTear", soundNames())
	check("... a beat (Config.Gore.Stagger) apart", #t == 2 and math.abs((t[2] - t[1]) - GC.Stagger) < 1 / 30, string.format("%.3f", (t[2] or 0) - (t[1] or 0)))
	setHealth(hum, 10)
	Env.run(0.3)
	check("the server's word for the same blow adds nothing", #fxLog.Sound == 2)
	remove(m)

	resetLogs()
	local k, khum = rig("Obliterated")
	Gore.Hit(k, -40, V3.new(0, 0, 1))
	setHealth(khum, 0)
	Env.run(1)
	check("a single killing blow from full plays all three, in order, once each", soundNames() == "GoreTear,GoreTear,GoreBurst" and Gore.StageOf(k) == 3, soundNames())
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
section("4  the server's stage rules the combat's fighters (a player's arms grow back)")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("Dummy", { Hat = true, Watch = true })
	setHealth(hum, 20)
	Env.run(0.6)
	check("down to 20%: both arms gone, the head whole", Gore.StageOf(m) == 2 and P["Right Arm"].LocalTransparencyModifier == 1 and P["Left Arm"].LocalTransparencyModifier == 1 and P.Head.LocalTransparencyModifier == 0)
	check("the watch on the torn arm went with it", P.Watch.LocalTransparencyModifier == 1)
	setHealth(hum, 100)
	Env.run(0.3)
	check("healed back to full: the arms never grow back", Gore.StageOf(m) == 2 and P["Right Arm"].LocalTransparencyModifier == 1 and P["Left Arm"].LocalTransparencyModifier == 1)
	remove(m)
end
do
	-- a fighter in the combat: the server's stage (the GoreStage attribute), whatever its health says
	resetLogs()
	local m, hum, P = rig("Fighter")
	m:SetAttribute("CombatEntity", true)
	m:SetAttribute("GoreStage", 0)
	setHealth(hum, 40) -- (its own health alone never moves a fighter the server keeps)
	Env.run(0.3)
	check("a combat fighter follows the server's stage, not its own health", Gore.StageOf(m) == 0 and #fxLog.Sound == 0)
	m:SetAttribute("GoreStage", 1)
	Env.run(0.3)
	check("the server's stage 1: the right arm, animated", Gore.StageOf(m) == 1 and soundNames() == "GoreTear" and #gibs("Model", "GoreArm") >= 1)
	Gore.Hit(m, 10, V3.new(1, 0, 0), 2)
	Env.run(0.4)
	check("the server's Hit carries stage 2: the left arm", Gore.StageOf(m) == 2 and soundNames() == "GoreTear,GoreTear")
	m:SetAttribute("GoreStage", 2)
	Env.run(0.3)
	check("... and the attribute arriving after it replays nothing", #fxLog.Sound == 2)
	-- a player's arms growing back (the server's stage steps back): newest first, each with the
	-- place's heal burst on the new arm and its sound
	local function stumps()
		local r, l = nubsOf(P)
		return if r then 1 else 0, if l then 1 else 0
	end
	local function regrowOn(arm, from)
		local n, on = 0, true
		for i = from + 1, #Client.emits do
			local e = Client.emits[i]
			if e.Effect == "Regrow" then
				n += 1
				on = on and e.Emitter._p.Parent ~= nil and e.Emitter._p.Parent._p.Parent == arm
			end
		end
		return n > 0 and on, n
	end
	Env.run(GC.BleedTime + 0.5) -- (the stumps done bleeding: anything after this is the regrowth's)
	local e1 = #Client.emits
	table.clear(fxLog.Sound)
	local g0 = #gibs("Model", "GoreArm")
	m:SetAttribute("GoreStage", 1)
	Env.run(0.3)
	local r1, l1 = stumps()
	check("stage 2 -> 1: the LEFT arm grows back (the right stays gone), its nub gone", Gore.StageOf(m) == 1 and P["Left Arm"].LocalTransparencyModifier == 0 and P["Right Arm"].LocalTransparencyModifier == 1 and l1 == 0 and r1 == 1, ("%d %d"):format(r1, l1))
	local ok1, n1 = regrowOn(P["Left Arm"], e1)
	check(("... with the place's heal burst on the new arm (%d emitters of Regrow) and the flesh knitting"):format(n1), ok1 and soundNames() == "GoreRegrow")
	local blood = 0
	for i = e1 + 1, #Client.emits do
		local e = Client.emits[i]
		if e.Effect == "Blood" or e.Effect == "BloodHeavy" then
			blood += 1
		end
	end
	check("... and no arm thrown, no blood", #gibs("Model", "GoreArm") == g0 and blood == 0, blood)
	Env.run(0.6) -- (the left arm's burst has its delayed part too)
	local e0 = #Client.emits
	table.clear(fxLog.Sound)
	m:SetAttribute("GoreStage", 0)
	Env.run(0.3)
	local leftovers = 0
	for _, c in ipairs(m:GetDescendants()) do
		if not c._p.Destroyed and (string.match(c.Name, "^Gore") or table.find(KIT_NAMES, c.Name)) then
			leftovers += 1
		end
	end
	local ok0 = regrowOn(P["Right Arm"], e0)
	local rn, ln = stumps()
	check("stage 1 -> 0: the right arm too - whole again, every nub gone", Gore.StageOf(m) == 0 and P["Right Arm"].LocalTransparencyModifier == 0 and P["Left Arm"].LocalTransparencyModifier == 0 and leftovers == 0 and rn == 0 and ln == 0, leftovers)
	check("... its own heal burst and sound", ok0 and soundNames() == "GoreRegrow", tostring(ok0) .. " " .. soundNames())
	m:SetAttribute("GoreStage", 1)
	Env.run(0.4)
	check("hurt again after regrowing: it comes apart again", Gore.StageOf(m) == 1 and P["Right Arm"].LocalTransparencyModifier == 1 and soundNames() == "GoreRegrow,GoreTear")
	remove(m)
end
do
	-- first seen already missing limbs (a late join, streamed in): its wounds at once, nothing replayed
	resetLogs()
	local gibs0 = {}
	for _, g in ipairs(gibs("Model", "GoreArm")) do
		gibs0[g] = true
	end
	-- (a body this client has never seen, arriving with the stage already set)
	local late, _, LP = rig("LateJoin", { Attrs = { CombatEntity = true, GoreStage = 2 } })
	Env.run(0.3)
	local rn, ln = nubsOf(LP)
	local stumps = (if rn then 1 else 0) + (if ln then 1 else 0)
	check("a body first seen at stage 2: both arms hidden, both nubs on", Gore.StageOf(late) == 2 and LP["Right Arm"].LocalTransparencyModifier == 1 and LP["Left Arm"].LocalTransparencyModifier == 1 and stumps == 2, stumps)
	local thrown = 0
	for _, g in ipairs(gibs("Model", "GoreArm")) do
		if not gibs0[g] then
			thrown += 1
		end
	end
	check("... nothing replayed: no arm thrown, no sound, no blood", thrown == 0 and #fxLog.Sound == 0, thrown .. " " .. soundNames())
	remove(late)
end

---------------------------------------------------------------------------
section("5  ARM: torn at its middle - the forearm thrown, the nub left on the shoulder")
---------------------------------------------------------------------------
local function armCase(label, opts, drive, side)
	resetLogs()
	local m, hum, P = rig(label, opts)
	local before = {}
	for _, g in ipairs(gibs("Model", "GoreArm")) do
		before[g] = true
	end
	local torso = P.Torso
	local arm = if side == "Right" then P["Right Arm"] else P["Left Arm"]
	local armCf = arm.CFrame
	Gore.Hit(m, if side == "Right" then 74 else 49, drive)
	Env.step(1 / 60)
	if side == "Left" then
		Env.run(0.3)
	end
	local list = {}
	for _, g in ipairs(gibs("Model", "GoreArm")) do
		if not before[g] then
			table.insert(list, g) -- (only this body's: an earlier one may fade out meanwhile)
		end
	end
	local gib = list[#list]
	check(label .. ": a severed arm is thrown (one per stage)", #list == (if side == "Left" then 2 else 1))
	if not gib then
		remove(m)
		return
	end
	local copy = gib:FindFirstChild(arm.Name)
	local half = V3.new(arm.Size.X, arm.Size.Y * 0.5, arm.Size.Z)
	check(label .. ": ... it is a copy of THAT arm's lower half (its name, colour, half its length), visible", copy ~= nil and copy.Color == arm.Color and near(copy.Size, half) and copy.LocalTransparencyModifier == 0)
	check(label .. ": ... the real arm hidden on this client only (Transparency untouched)", arm.LocalTransparencyModifier == 1 and arm.Transparency == 0)
	check(label .. ": ... starts exactly where the forearm was", copy and sameFrame(copy.CFrame, armCf * CF.new(0, -arm.Size.Y * 0.25, 0)))
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
	-- the nub: the upper half, on the shoulder, torn open at its end
	local rn, ln = nubsOf(P)
	local nubModel = if side == "Right" then rn else ln
	local nub = nubModel and nubModel:FindFirstChild(arm.Name)
	check(label .. ": ... the upper half stays on the shoulder (a nub: that arm's colour, half its length)", nub ~= nil and nub.Color == arm.Color and near(nub.Size, half) and nub.LocalTransparencyModifier == 0 and nub.Transparency == 0)
	if nub then
		local w = nub:FindFirstChildOfClass("Weld")
		check(label .. ": ... exactly where the upper arm was, welded to the arm (it swings with the shoulder)", sameFrame(nub.CFrame, arm.CFrame * CF.new(0, arm.Size.Y * 0.25, 0)) and w and w.Part0 == arm and sameFrame(arm.CFrame * w.C0, nub.CFrame))
		check(label .. ": ... dressed like the NPC, never collides, weighs nothing, tagged as a wound", nubModel:FindFirstChildOfClass("Humanoid") ~= nil and (nubModel:FindFirstChildOfClass("Shirt") ~= nil) == (opts.Shirt == true) and not nub.CanCollide and nub.Massless and nubModel:GetAttribute("OverkillGore") == true)
		local torn = nil
		for _, c in ipairs(nubModel:GetChildren()) do
			if c.Name == (if side == "Right" then "right.arm" else "left.arm") then
				torn = c
			end
		end
		local lt = torn and nub.CFrame:PointToObjectSpace(torn.CFrame.Position)
		check(label .. ": ... its torn end is the kit's arm end (flesh and bone), turned to face down at the nub's bottom", torn ~= nil and torn.ClassName == "UnionOperation" and lt.Y < 0 and torn.CFrame.UpVector:Dot(nub.CFrame.UpVector) < -0.99, lt)
		local att = nub:FindFirstChild("GoreBleed")
		local spurts = 0
		for _, e in ipairs(Client.emits) do
			if e.Effect == "Blood" and att and near(e.CFrame.Position, att.WorldPosition, 1e-3) then
				spurts += 1
			end
		end
		check(label .. ": ... and it bleeds from there (the place's Blood effect spurting from the torn end)", att ~= nil and spurts > 0 and att.WorldCFrame.UpVector:Dot(nub.CFrame.UpVector) < -0.99, spurts)
		-- EVERY POSE: the nub and its torn end ride on the (hidden) arm through their welds, so wherever
		-- the arm goes - any swing, any ragdoll twist - they fill only the space the real arm filled
		-- there (never poking out of it, never cutting into the torso further than the arm did), and
		-- the torn end always covers the cut
		if torn then
			local wn = nub:FindFirstChildOfClass("Weld")
			local wt = torn:FindFirstChildOfClass("Weld")
			local function corners(cf, size)
				local out = {}
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz in ipairs({ -1, 1 }) do
							table.insert(out, cf * V3.new(size.X / 2 * sx, size.Y / 2 * sy, size.Z / 2 * sz))
						end
					end
				end
				return out
			end
			local worst, poses, uncovered = 0, 0, 0
			local function rnd(a, b)
				return a + math.random() * (b - a)
			end
			for _ = 1, 60 do
				poses += 1
				-- a pose: the arm anywhere, turned any way (what the shoulder's animation / a ragdoll does)
				local pose = CF.new(rnd(-20, 20), rnd(0, 10), rnd(-20, 20)) * CF.Angles(rnd(-3.1, 3.1), rnd(-3.1, 3.1), rnd(-3.1, 3.1))
				local nubCf = pose * wn.C0
				local tornCf = nubCf * wt.C0
				for _, c in ipairs(corners(nubCf, nub.Size)) do
					local l = pose:PointToObjectSpace(c)
					worst = math.max(worst, math.abs(l.X) - arm.Size.X / 2, math.abs(l.Y) - arm.Size.Y / 2, math.abs(l.Z) - arm.Size.Z / 2)
				end
				local lowest = math.huge
				for _, c in ipairs(corners(tornCf, torn.Size)) do
					local l = pose:PointToObjectSpace(c)
					-- (the kit's piece is a hair wider than an arm: 1.02 x 1.06 - it wraps the arm's skin)
					worst = math.max(worst, math.abs(l.X) - arm.Size.X / 2 * 1.035, math.abs(l.Y) - arm.Size.Y / 2, math.abs(l.Z) - arm.Size.Z / 2 * 1.035)
					lowest = math.min(lowest, nubCf:PointToObjectSpace(c).Y)
				end
				if lowest > -nub.Size.Y / 2 + 0.02 then
					uncovered += 1
				end
			end
			check(label .. (": ... in %d random poses the nub and its torn end never leave the space the arm filled (worst %.4f studs out)"):format(poses, worst), worst <= 1e-3, worst)
			check(label .. ": ... and the torn end always covers the cut (never a hollow arm end)", uncovered == 0, uncovered)
		end
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

do
	-- a ragdolled NPC (a ball socket from its arm to its torso), an arm marked not to be copied, and a
	-- rigid accessory (held by a constraint, not a weld) on that arm
	resetLogs()
	local m, hum, P = rig("Ragdolled")
	local arm, torso = P["Right Arm"], P.Torso
	local a0 = Client.new("Attachment")
	a0.Parent = arm
	local a1 = Client.new("Attachment")
	a1.Parent = torso
	local sock = Client.new("BallSocketConstraint")
	sock.Attachment0 = a0
	sock.Attachment1 = a1
	sock.Parent = arm
	arm.Archivable = false
	local acc = Client.new("Accessory")
	local handle = Client.new("Part")
	handle.Name = "Handle"
	handle.Parent = acc
	local ha = Client.new("Attachment")
	ha.Parent = handle
	local rigid = Client.new("RigidConstraint")
	rigid.Attachment0 = ha
	rigid.Attachment1 = a0
	rigid.Parent = handle
	acc.Parent = m
	setHealth(hum, 70)
	Env.run(0.2)
	local list = gibs("Model", "GoreArm")
	local gib = list[#list]
	local copy = gib and gib:FindFirstChild("Right Arm")
	check("an arm marked not to be copied is still torn off (a copy is made anyway)", copy ~= nil and #warns == 0, table.concat(warns, " | "))
	local tied = 0
	for _, d in ipairs(copy and copy:GetDescendants() or {}) do
		if d:IsA("Constraint") or d:IsA("JointInstance") then
			tied += 1
		end
	end
	check("... no ragdoll socket comes along to tie the torn arm to the live torso", copy ~= nil and tied == 0, tied)
	check("... the original keeps its own Archivable setting", arm.Archivable == false)
	check("a rigid accessory (held by a constraint) goes with the arm", handle.LocalTransparencyModifier == 1)
	remove(m)
end

---------------------------------------------------------------------------
section("6  no jaw: the head stays whole until the killing blow")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("WholeHead", { Hat = true })
	for _, h in ipairs({ 60, 30, 10, 1 }) do
		setHealth(hum, h)
		Env.run(0.4)
	end
	check("down to 1%: both arms gone, stage 2", Gore.StageOf(m) == 2 and soundNames() == "GoreTear,GoreTear", soundNames())
	check("... the head, its face and its hat all still there", P.Head.LocalTransparencyModifier == 0 and P.Head:FindFirstChild("face").LocalTransparencyModifier == 0 and P.Hat.LocalTransparencyModifier == 0)
	check("... no jaw, teeth or flesh on it", m:FindFirstChild("GoreJaw") == nil and #childNamed(m, "GoreFlesh") == 0 and #gibs("Part", "GoreTooth") == 0)
	remove(m)
end

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
	check(label .. ": the killing blow bursts the head (stage 3)", Gore.StageOf(m) == 3 and fxLog.Sound[#fxLog.Sound].Name == "GoreBurst")
	check(label .. ": ... the head and its face gone", head.LocalTransparencyModifier == 1 and (head:FindFirstChild("face") == nil or head:FindFirstChild("face").LocalTransparencyModifier == 1))
	check(label .. ": ... the hat with it", not P.Hat or P.Hat.LocalTransparencyModifier == 1)
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
	local heavy, plain, particles, allAtHead = 0, 0, 0, true
	for i = emitsBefore + 1, #Client.emits do
		local e = Client.emits[i]
		if near(e.CFrame.Position, head.Position, 1e-3) then
			particles += e.Count
			if e.Emitter.Name == "Blood-01" then
				heavy += 1
			elseif e.Emitter.Name == "Blood1" then
				plain += 1
			end
		end
	end
	check(label .. ": ... a huge red mist: the place's BloodHeavy burst twice and Blood once, big (" .. particles .. " particles)", heavy >= 2 and plain >= 1 and particles >= 60, heavy .. "/" .. plain .. "/" .. particles)
	for i = emitsBefore + 1, #Client.emits do
		local e = Client.emits[i]
		if e.Effect == "BloodHeavy" and not near(e.CFrame.Position, head.Position, 1e-3) then
			allAtHead = false
		end
	end
	check(label .. ": ... bursting from where the head was", allAtHead)
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
	Env.run(GC.BleedTime + GC.DripTime + 3) -- (the last drops of every wound too)
	local flying = 0
	for _, d in ipairs(Blood.Drops) do
		if d.Live then
			flying += 1
		end
	end
	check(label .. ": ... droplets landed and are gone: nothing left on the ground", Blood.Stats.Landed > 0 and flying == 0, flying)
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
	local m, hum, PB = rig("Bare")
	setHealth(hum, 0)
	Env.run(1)
	check("no gore kit in the place: every stage still plays (plain flesh stand-ins), no errors", Gore.StageOf(m) == 3 and soundNames() == "GoreTear,GoreTear,GoreBurst" and #warns == 0, table.concat(warns, " | "))
	local stand = false
	local rn = nubsOf(PB)
	for _, c in ipairs(rn and rn:GetChildren() or {}) do
		if c.Name == "right.arm" and c.ClassName == "Part" then
			stand = true
		end
	end
	check("... the stand-in torn end is on the nub", stand)
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
	check("dying without a Hit (a fall, the void, a script) still ends in the burst", Gore.StageOf(m) == 3 and #warns == 0)
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
	check("a body part removed by something else: that stage passes quietly, the rest in order", Gore.StageOf(m) == 2 and soundNames() == "GoreTear" and #warns == 0, soundNames())
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
	check("... the pieces used: arm ends (on the nubs and the forearms), neck, skull base, chunks", used["right.arm"] and used["left.arm"] and used.neck and used.head, table.concat(names, ","))
	local kitChunks = 0
	for _, inst in ipairs(Client.all) do
		if inst.Name == "GoreChunk" and inst.ClassName == "UnionOperation" then
			kitChunks += 1
		end
	end
	check("... the flesh chunks are the kit's 'debry' piece", kitChunks > 0)
	check("the templates themselves are untouched (still 12 kit pieces)", #templatesFolder:FindFirstChild("GoreKit"):GetChildren() == 12)
	local jawBits = 0
	for _, inst in ipairs(Client.all) do
		if inst.Name == "GoreJaw" or inst.Name == "GoreTooth" or inst.Name == "GoreFlesh" then
			jawBits += 1
		end
	end
	check("no jaw piece, tooth or flesh strand was ever made", jawBits == 0, jawBits)
	local foreign, bursts = 0, 0
	for _, e in ipairs(Client.emits) do
		if e.Effect ~= "Regrow" then -- (a player's arm growing back: the place's heal effect, not blood)
			bursts += 1
			if e.Effect ~= "Blood" and e.Effect ~= "BloodHeavy" then
				foreign += 1
			end
		end
	end
	check(("all the gore's blood (%d bursts) is the place's own Blood / BloodHeavy effects"):format(bursts), bursts > 0 and foreign == 0, foreign)

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
	check("the jaw's sound is gone from the config", Config.Sounds.GoreSnap == nil)
	for _, n in ipairs({ "GoreTear", "GoreBurst", "GoreRegrow" }) do
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

---------------------------------------------------------------------------
section("11  both nubs at once: every shoulder pose, any height or heading; first person; what's worn")
---------------------------------------------------------------------------
do
	resetLogs()
	local m, hum, P = rig("Double", { Shirt = true, Watch = true })
	-- a pad worn on the right shoulder (the nub keeps the shoulder: it stays), and the watch on the
	-- wrist (it goes with the forearm)
	local ra = P["Right Arm"]
	local sa = Client.new("Attachment")
	sa.Name = "RightShoulderAttachment"
	sa.CFrame = CF.new(0, 1, 0)
	sa.Parent = ra
	local acc = Client.new("Accessory")
	acc.Name = "Pad"
	local pad = Client.new("Part")
	pad.Name = "Handle"
	pad.CFrame = ra.CFrame * CF.new(0, 1, 0)
	pad.Parent = acc
	local pa = Client.new("Attachment")
	pa.Name = "RightShoulderAttachment"
	pa.Parent = pad
	local pw = Client.new("Weld")
	pw.Name = "AccessoryWeld"
	pw.Part0 = pad
	pw.Part1 = ra
	pw.Parent = pad
	acc.Parent = m
	setHealth(hum, 5)
	Env.run(0.8)
	local rn, ln = nubsOf(P)
	check("both arms gone: two nubs, one on each shoulder", Gore.StageOf(m) == 2 and rn ~= nil and ln ~= nil)
	check("the shoulder pad stays on (the nub is still there to wear it); the watch went with the forearm", pad.LocalTransparencyModifier == 0 and P.Watch.LocalTransparencyModifier == 1, pad.LocalTransparencyModifier)
	local function parts(nubModel, arm)
		local nub = nubModel:FindFirstChild(arm.Name)
		local torn
		for _, c in ipairs(nubModel:GetChildren()) do
			if c:IsA("UnionOperation") then
				torn = c
			end
		end
		return nub, nub:FindFirstChildOfClass("Weld"), torn, torn and torn:FindFirstChildOfClass("Weld")
	end
	local R = { parts(rn, P["Right Arm"]) }
	local L = { parts(ln, P["Left Arm"]) }
	check("... each a nub with its torn end, each welded (they ride their arms)", R[1] and R[2] and R[3] and R[4] and L[1] and L[2] and L[3] and L[4])
	local function corners(cf, size)
		local out = {}
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					table.insert(out, cf * V3.new(size.X / 2 * sx, size.Y / 2 * sy, size.Z / 2 * sz))
				end
			end
		end
		return out
	end
	local function rnd(a, b)
		return a + math.random() * (b - a)
	end
	-- out of the arm's own box (the torn end wraps the skin: 3.5% round)
	local function outOf(armCf, armSize, cf, size, skin)
		local worst = -math.huge
		for _, c in ipairs(corners(cf, size)) do
			local l = armCf:PointToObjectSpace(c)
			worst = math.max(worst, math.abs(l.X) - armSize.X / 2 * skin, math.abs(l.Y) - armSize.Y / 2, math.abs(l.Z) - armSize.Z / 2 * skin)
		end
		return worst
	end
	-- the R6 shoulders (Motor6D C0 / C1), any rotation of each arm on its own, the body anywhere: low
	-- ground, high towers, far out on the map, any heading, tilted (a dash, a fall, a ragdoll)
	local SH = {
		Right = { CF.new(1, 0.5, 0) * CF.Angles(0, math.pi / 2, 0), CF.new(-0.5, 0.5, 0) * CF.Angles(0, math.pi / 2, 0) },
		Left = { CF.new(-1, 0.5, 0) * CF.Angles(0, -math.pi / 2, 0), CF.new(0.5, 0.5, 0) * CF.Angles(0, -math.pi / 2, 0) },
	}
	local HEIGHTS = { -450, -40, 0, 3, 60, 900, 4000 }
	local worst, poses, uncovered, apart = -math.huge, 0, 0, 0
	for i = 1, 700 do
		local y = HEIGHTS[(i % #HEIGHTS) + 1]
		local torso = CF.new(rnd(-3000, 3000), y, rnd(-3000, 3000)) * CF.Angles(rnd(-0.6, 0.6), rnd(-math.pi, math.pi), rnd(-0.6, 0.6))
		local frames = {}
		for side, M in pairs(SH) do
			local arm = P[side .. " Arm"]
			local armCf = torso * M[1] * CF.Angles(rnd(-math.pi, math.pi), rnd(-math.pi, math.pi), rnd(-math.pi, math.pi)) * M[2]:Inverse()
			local S = if side == "Right" then R else L
			local nubCf = armCf * S[2].C0
			local tornCf = nubCf * S[4].C0
			worst = math.max(worst, outOf(armCf, arm.Size, nubCf, S[1].Size, 1), outOf(armCf, arm.Size, tornCf, S[3].Size, 1.035))
			local lowest = math.huge
			for _, c in ipairs(corners(tornCf, S[3].Size)) do
				lowest = math.min(lowest, nubCf:PointToObjectSpace(c).Y)
			end
			if lowest > -S[1].Size.Y / 2 + 0.02 then
				uncovered += 1
			end
			frames[side] = nubCf
		end
		-- the two nubs stay on their own shoulders: their centres never nearer than their shoulders allow
		if (frames.Right.Position - frames.Left.Position).Magnitude < 0.99 then
			apart += 1
		end
		poses += 1
	end
	check(("%d poses x 2 nubs (heights %d..%d studs, 3000 studs out): nub and torn end never leave their arm's space (worst %.4f studs out)"):format(poses, HEIGHTS[1], HEIGHTS[#HEIGHTS], worst), worst <= 2e-3, worst)
	check("... the torn end always covers the cut, on both", uncovered == 0, uncovered)
	check("... and the two never meet (each stays on its own shoulder)", apart == 0, apart)
	check("... never collide, never block a hit or a ray, weigh nothing (a dash or a fall never feels them)", not R[1].CanCollide and not R[1].CanQuery and not R[1].CanTouch and R[1].Massless and not L[1].CanCollide and not L[1].CanQuery and not L[1].CanTouch and L[1].Massless and not R[3].CanCollide and not L[3].CanCollide)
	-- the arm taken away (streamed out, removed by something else): its nub goes too, never left falling
	local larm = P["Left Arm"]
	larm.Parent = nil
	larm._p.AncestryChanged:Fire(larm, nil)
	check("the left arm taken away: its nub goes with it (never left behind)", ln.Parent == nil and rn.Parent ~= nil)
	remove(m)
	check("the body gone: the other nub goes too", rn.Parent == nil)
end
do
	-- your own body, both nubs, in first person: the camera hides your body (the head's
	-- LocalTransparencyModifier) and the nubs with it; zooming back out shows them again
	resetLogs()
	local m, hum, P = rig("Me")
	local was = Env.Players.LocalPlayer
	Env.Players.LocalPlayer = { Name = "Me", Character = m }
	setHealth(hum, 5)
	Env.run(0.8)
	local rn, ln = nubsOf(P)
	local rp, lp = rn and rn:FindFirstChild("Right Arm"), ln and ln:FindFirstChild("Left Arm")
	check("your own two nubs, seen from outside", rp and lp and rp.LocalTransparencyModifier == 0 and lp.LocalTransparencyModifier == 0)
	P.Head.LocalTransparencyModifier = 1
	local tornHidden = true
	for _, c in ipairs(rn:GetChildren()) do
		if c:IsA("BasePart") and c.LocalTransparencyModifier ~= 1 then
			tornHidden = false
		end
	end
	check("first person: both nubs and their torn ends hide with your body (never floating in view)", rp.LocalTransparencyModifier == 1 and lp.LocalTransparencyModifier == 1 and tornHidden)
	P.Head.LocalTransparencyModifier = 0.4
	check("... fading with it as the camera zooms", rp.LocalTransparencyModifier == 0.4 and lp.LocalTransparencyModifier == 0.4)
	P.Head.LocalTransparencyModifier = 0
	check("... and back when you zoom out", rp.LocalTransparencyModifier == 0 and lp.LocalTransparencyModifier == 0)
	Env.Players.LocalPlayer = was
	remove(m)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
