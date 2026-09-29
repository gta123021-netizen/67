--[[
	traversal_test.lua - the ten traversal moves (Traversal) on a course in the stand-in world, with a
	small character physics of its own (gravity, the ground, walls, the humanoid's walk, the drives):
	every move in every body state (whole, an arm gone, both arms gone, a leg gone, both legs gone, an
	arm and a leg gone), limbs lost in the middle of moves, the fight taking the body mid-move, inputs
	that try to get round a lost limb, the server's refusal, the blood a crawling body drags, and that
	it all cleans up.
	  luaurun tools/tests/traversal_test.lua <repo root>
]]
local ROOT = ARGS[2] or "."
local M = loadchunk(readfile(ROOT .. "/tools/tests/rbxmock.lua"), "rbxmock")()
local RS = game:GetService("ReplicatedStorage")
local combat = M.folder(RS, "Combat")
for _, n in ipairs({ "CombatConfig", "Motion", "BodyState", "Traversal", "AnimController", "CombatVFX", "BloodPools", "CombatBlood" }) do
	M.module(combat, n, ROOT .. "/src/ReplicatedStorage__Combat__" .. n .. ".lua")
end
M.folder(combat, "VFX")
local Config = require(combat.CombatConfig)
local BodyState = require(combat.BodyState)
local Traversal = require(combat.Traversal)
local AnimController = require(combat.AnimController)
local TC = Config.Traversal
-- the clips' real lengths (the pack's keyframes)
for key, len in pairs({ SlideStart = 0.667, SlideLoop = 1, SlideCancel = 0.817, VaultLeftHand = 0.5, VaultRightHand = 0.5, DoubleJump = 0.3, Leap = 0.983, WallRunLeft = 0.667, WallRunRight = 0.667, WallClimb = 0.867, CrouchIdle = 3, CrouchWalk = 1, CrawlIdle = 1, Crawl = 1.25 }) do
	M.ClipLength[Config.Anim[key].Id] = len
end

local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	else
		print("ok   " .. msg)
	end
end

---------------------------------------------------------------------------
-- the course (on the stand-in's floor, y = 0)
---------------------------------------------------------------------------
local function box(name, cx, cy, cz, sx, sy, sz)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = Vector3.new(sx, sy, sz)
	p.CFrame = CFrame.new(cx, cy, cz)
	p.Parent = workspace
	table.insert(M.Boxes, p)
	return p
end
-- (the stand-in's floor is x, z -30 .. 30; its own wall stands at x 10..11, its ceiling over x 20..26)
-- lanes run along -Z; each obstacle sits across its own lane
box("Crate", -5, 1.25, 12, 6, 2.5, 1.2) -- lane x -5: a low crate (vault over it), top 2.5
box("Tower", 3, 5, 10, 6, 10, 6) -- lane x 3: a tall block (climb, then the ledge onto its top at y 10), near face z 13
box("RunWall", 29.5, 6, 0, 1, 12, 56) -- lane x 26.8: a long wall to run along (its face x = 29)
box("Low", -19, 4.5, 20, 6, 1, 6) -- lane x -19: a low ceiling at y 4 over z 17 .. 23 (no standing up under it)
box("Block", -25, 1.5, 5, 6, 3, 10) -- a low deep block (vault onto it): top 3

---------------------------------------------------------------------------
-- the fighter and its physics
---------------------------------------------------------------------------
local hero, hum = M.r6("Hero", Vector3.new(0, 3, 0))
local root = hero.HumanoidRootPart
local G = workspace.Gravity
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = { hero }
local wantJump = false

local function place(p: Vector3, face: Vector3?)
	local d = face or root.CFrame.LookVector
	local delta = p - root.Position
	for _, part in ipairs(hero:GetChildren()) do
		if part:IsA("BasePart") then
			part.CFrame = part.CFrame + delta
		end
	end
	root.CFrame = CFrame.lookAt(p, p + Vector3.new(d.X, 0, d.Z))
end

-- one physics step: the drives (the traversal's own, the fight's ground mover), the humanoid's walk and
-- jump, gravity; the body stops on walls (at the feet+0.6, the middle and the head) and stands on
-- the ground (3 studs under the root)
local function simulate(dt: number)
	local v = root.AssemblyLinearVelocity
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local tv = root:FindFirstChild("TraversalDrive")
	local cd = root:FindFirstChild("CombatDrive")
	if tv and tv.Enabled then
		v = tv.VectorVelocity
	else
		local hv
		if cd and cd.Enabled then
			hv = Vector3.new(cd.PlaneVelocity.X, 0, cd.PlaneVelocity.Y)
		elseif grounded then
			hv = hum.MoveDirection * hum.WalkSpeed
		else
			hv = Vector3.new(v.X, 0, v.Z)
		end
		local vy = v.Y
		if grounded and vy <= 0 then
			vy = 0
		else
			vy -= G * dt
		end
		if wantJump and grounded and hum.JumpHeight > 0 then
			vy = math.sqrt(2 * G * hum.JumpHeight)
			wantJump = false
		end
		v = hv + Vector3.new(0, vy, 0)
	end
	local p = root.Position
	local h = Vector3.new(v.X, 0, v.Z) * dt
	if h.Magnitude > 1e-6 then
		for _, up in ipairs({ -2.4, 0, 1.8 }) do
			local hit = workspace:Raycast(p + Vector3.new(0, up, 0), h + h.Unit * 0.5, params)
			if hit and math.abs(hit.Normal.Y) < 0.5 then
				local n = hit.Normal
				v = v - n * math.min(0, v:Dot(n))
				h = Vector3.new(v.X, 0, v.Z) * dt
			end
		end
	end
	local np = p + h + Vector3.new(0, v.Y * dt, 0)
	local g = workspace:Raycast(np + Vector3.new(0, 1, 0), Vector3.new(0, -4.05, 0), params)
	if g and g.Normal.Y > 0.6 and v.Y <= 0.01 and np.Y - 3 <= g.Position.Y + 0.05 then
		np = Vector3.new(np.X, g.Position.Y + 3, np.Z)
		v = Vector3.new(v.X, 0, v.Z)
		hum.FloorMaterial = Enum.Material.Plastic
	else
		hum.FloorMaterial = Enum.Material.Air
	end
	-- (the head never goes through a ceiling)
	if v.Y > 0 then
		local c = workspace:Raycast(p + Vector3.new(0, 1.9, 0), Vector3.new(0, v.Y * dt + 0.1, 0), params)
		if c then
			np = Vector3.new(np.X, math.min(np.Y, c.Position.Y - 2.05), np.Z)
			v = Vector3.new(v.X, 0, v.Z)
		end
	end
	root.AssemblyLinearVelocity = v
	place(np)
end
game:GetService("RunService").PreSimulation:Connect(simulate)

---------------------------------------------------------------------------
-- the traversal, with a stand-in for the fight
---------------------------------------------------------------------------
local ac = AnimController.get(hum)
local fight = { Act = true, Run = true, Crouch = false, LastJump = -10, Sent = {}, Fx = {}, Smear = 0, Bleed = 0 }
local T = Traversal.new({ Char = hero, Hum = hum, Root = root, AC = ac }, {
	CanAct = function()
		return fight.Act
	end,
	Running = function()
		return fight.Run
	end,
	CrouchHeld = function()
		return fight.Crouch
	end,
	Ignore = function()
		return { hero }
	end,
	Fighters = function()
		return {}
	end,
	Jumped = function()
		fight.LastJump = os.clock()
	end,
	LastJump = function()
		return fight.LastJump
	end,
	Sent = function(kind)
		table.insert(fight.Sent, kind)
	end,
	Fx = function(kind)
		table.insert(fight.Fx, kind)
	end,
	Smear = function(dt, s)
		fight.Smear += dt * s * fight.Bleed
	end,
})
local conn = game:GetService("RunService").Heartbeat:Connect(function(dt)
	T:Step(dt)
end)

-- a body state: which limbs are gone (the arms through the gore stage the server keeps - right first
-- - and anything else through the part itself, as the server hides it)
local STATES = {
	{ Name = "whole" },
	{ Name = "no right arm", Stage = 1 },
	{ Name = "no arms", Stage = 2 },
	{ Name = "no left arm", Hide = { "Left Arm" } },
	{ Name = "no left leg", Hide = { "Left Leg" } },
	{ Name = "no right leg", Hide = { "Right Leg" } },
	{ Name = "no legs", Hide = { "Left Leg", "Right Leg" } },
	{ Name = "no right arm + left leg", Stage = 1, Hide = { "Left Leg" } },
}
local function setBody(st)
	hero:SetAttribute("GoreStage", st.Stage or 0)
	for _, n in ipairs({ "Left Arm", "Right Arm", "Left Leg", "Right Leg" }) do
		local p = hero[n]
		local gone = false
		for _, h in ipairs(st.Hide or {}) do
			if h == n then
				gone = true
			end
		end
		p.Transparency = if gone then 1 else 0
		p:SetAttribute("GoreHidden", if gone then 0 else nil)
	end
end
local function lose(name)
	local p = hero[name]
	p.Transparency = 1
	p:SetAttribute("GoreHidden", 0)
end

-- a clean start: standing at `pos` facing `face`, nothing going on
local function reset(pos: Vector3, face: Vector3?, st)
	T:Cancel("reset")
	fight.Act, fight.Run, fight.Crouch = true, true, false
	hum.MoveDirection = Vector3.zero
	wantJump = false
	setBody(st or STATES[1])
	root.AssemblyLinearVelocity = Vector3.zero
	place(pos, face)
	hum.FloorMaterial = Enum.Material.Plastic
	M.run(0.4)
	T.NextSlide, T.NextLeap, T.NextVault, T.NextClimb, T.NextWallRun = 0, 0, 0, 0, 0
	table.clear(fight.Sent)
	table.clear(fight.Fx)
end
local function expect(need, body)
	local ok = BodyState.Can(body, need)
	return ok
end
local function run(dir: Vector3, seconds: number, watch: (() -> ())?)
	hum.MoveDirection = dir.Unit
	local n = math.floor(seconds * 60 + 0.5)
	for _ = 1, n do
		M.step(1 / 60)
		if watch then
			watch()
		end
	end
end
local FWD = Vector3.new(0, 0, -1)

---------------------------------------------------------------------------
print("-- every move, every body")
local matrix = {}
for _, st in ipairs(STATES) do
	local row = {}
	setBody(st)
	local body = BodyState.Of(hero)
	-- CROUCH (standing still)
	reset(Vector3.new(0, 3, -10), FWD, st)
	T:Press("Crouch")
	M.run(0.2)
	row.Crouch = T.Posture == "Crouch"
	check(row.Crouch == expect("Crouch", body), st.Name .. ": crouch only with both legs")
	T:Press("Crouch")
	M.run(0.3)
	-- CRAWL
	reset(Vector3.new(0, 3, -10), FWD, st)
	T:Press("Crawl")
	M.run(0.2)
	row.Crawl = T.Posture == "Crawl"
	check(row.Crawl == expect("Crawl", body), st.Name .. ": crawl only with both arms")
	if row.Crawl then
		-- (the clips are the crawl's, and none of the walk's)
		run(FWD, 0.5)
		check(ac:IsPlaying("Crawl") and not ac:IsPlaying("CrouchWalk"), st.Name .. ": the crawl clip plays as it moves")
	end
	T:Press("Crawl")
	-- SLIDE (running)
	reset(Vector3.new(16, 3, 25), FWD, st)
	hum.WalkSpeed = Config.RunSpeed
	run(FWD, 0.4)
	T:Press("Crouch")
	M.step(1 / 60)
	row.Slide = T.Mode == "Slide"
	check(row.Slide == expect("Slide", body), st.Name .. ": slide only with both legs")
	check(T.Posture == nil, st.Name .. ": a refused slide isn't a crouch instead (running)")
	-- SLIDE CANCEL
	if row.Slide then
		M.run(0.25)
		local ok = T:Press("Jump")
		M.step(1 / 60)
		row.SlideCancel = ok and root.AssemblyLinearVelocity.Y > 20 and Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude >= TC.CancelSpeed * 0.9
		check(row.SlideCancel, st.Name .. ": the slide cancel hops out with the slide's speed")
		M.run(1.2)
	end
	-- DOUBLE JUMP
	reset(Vector3.new(16, 3, 0), FWD, st)
	wantJump = true
	fight.LastJump = os.clock()
	M.run(0.3)
	local before = root.AssemblyLinearVelocity.Y
	local dj = T:Press("Jump")
	M.step(1 / 60)
	row.DoubleJump = dj and root.AssemblyLinearVelocity.Y > before + 10
	check(row.DoubleJump == expect("DoubleJump", body), st.Name .. ": double jump only with both legs")
	check(not T:Press("Jump") or not row.DoubleJump, st.Name .. ": one air jump each time off the ground")
	M.run(1.5)
	-- LEAP
	reset(Vector3.new(16, 3, 10), FWD, st)
	local z0 = root.Position.Z
	T:Press("Leap")
	M.run(0.2)
	row.Leap = root.Position.Z < z0 - 2 and hum.FloorMaterial == Enum.Material.Air
	check(row.Leap == expect("Leap", body), st.Name .. ": leap only with both legs")
	M.run(1.5)
	-- VAULT (running at the crate)
	reset(Vector3.new(-5, 3, 18), FWD, st)
	hum.WalkSpeed = Config.RunSpeed
	local vaulted, clip = false, nil
	run(FWD, 1.4, function()
		if T.Mode == "Vault" then
			vaulted = true
			clip = T.M.Clip
		end
	end)
	row.Vault = vaulted and root.Position.Z < 10
	local vok, hand = BodyState.Can(body, "Vault")
	check(row.Vault == (vok == true), st.Name .. ": vault only with a hand to put on it and both legs")
	if row.Vault and not (body.HasLeftArm and body.HasRightArm) then
		check(clip == (if hand == "Left" then "VaultLeftHand" else "VaultRightHand") and ((clip == "VaultLeftHand") == body.HasLeftArm), st.Name .. ": the vault is done on the hand the body still has (" .. tostring(clip) .. ")")
	end
	if not row.Vault then
		check(root.Position.Z > 13, st.Name .. ": no vault - the crate stops the body")
	end
	-- CLIMB + LEDGE VAULT (jumping at the tower holding forward)
	reset(Vector3.new(3, 3, 16), FWD, st)
	hum.MoveDirection = FWD
	M.run(0.1)
	wantJump = true
	fight.LastJump = os.clock()
	local climbed, ledged, top = false, false, false
	run(FWD, 2.6, function()
		if T.Mode == "Climb" then
			climbed = true
		elseif T.Mode == "LedgeVault" then
			ledged = true
		elseif ledged and hum.FloorMaterial ~= Enum.Material.Air and root.Position.Y > 12.5 then
			top = true -- (standing on the tower's top after the pull-up)
		end
	end)
	row.Climb = climbed
	row.Ledge = ledged and top
	check(row.Climb == expect("Climb", body), st.Name .. ": wall climb only with both arms and both legs")
	if row.Climb then
		check(row.Ledge, st.Name .. ": up the wall, over its top edge and standing on it")
	end
	-- WALL RUN (a jump along the run wall, fast)
	reset(Vector3.new(26.8, 3, 25), FWD, st)
	hum.WalkSpeed = Config.RunSpeed
	run(FWD, 0.2)
	wantJump = true
	fight.LastJump = os.clock()
	local ran = false
	run(FWD, 0.9, function()
		if T.Mode == "WallRun" then
			ran = true
		end
	end)
	row.WallRun = ran
	check(row.WallRun == expect("WallRun", body), st.Name .. ": wall run only with both legs")
	M.run(1.5)
	matrix[st.Name] = row
end
print("   body state                  crouch crawl slide cancel dbljump leap vault climb ledge wallrun")
for _, st in ipairs(STATES) do
	local r = matrix[st.Name]
	local function b(x)
		return if x then "  yes " else "   -  "
	end
	print(string.format("   %-26s %s%s%s%s%s%s%s%s%s%s", st.Name, b(r.Crouch), b(r.Crawl), b(r.Slide), b(r.SlideCancel), b(r.DoubleJump), b(r.Leap), b(r.Vault), b(r.Climb), b(r.Ledge), b(r.WallRun)))
end

---------------------------------------------------------------------------
print("-- a limb lost in the middle of a move ends it there and then")
-- climbing: an arm goes
reset(Vector3.new(3, 3, 16), FWD)
hum.MoveDirection = FWD
M.run(0.1)
wantJump = true
fight.LastJump = os.clock()
local waited = 0
while T.Mode ~= "Climb" and waited < 90 do
	M.step(1 / 60)
	waited += 1
end
M.run(0.2)
local vyBefore = root.AssemblyLinearVelocity.Y
hero:SetAttribute("GoreStage", 1)
T:Step(0) -- (CombatClient re-reads the body the moment GoreStage changes)
check(T.Mode == nil, "climbing: the arm goes - the climb is over at once")
check(not root.TraversalDrive.Enabled, "...its drive lets go (nothing holds the body to the wall)")
check(math.abs(root.AssemblyLinearVelocity.Y - vyBefore) < 2, "...and the body keeps the speed it had")
check(not ac:IsPlaying("WallClimb"), "...and the climb clip is off it")
M.run(1.5)
check(root.Position.Y < 3.2, "...it falls to the ground")

-- wall running: a leg goes
reset(Vector3.new(26.8, 3, 25), FWD)
hum.WalkSpeed = Config.RunSpeed
run(FWD, 0.2)
wantJump = true
fight.LastJump = os.clock()
waited = 0
while T.Mode ~= "WallRun" and waited < 60 do
	M.step(1 / 60)
	waited += 1
end
M.run(0.15)
local speedBefore = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
lose("Left Leg")
M.step(1 / 60)
check(T.Mode == nil, "wall running: a leg goes - off the wall at once")
check(Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude > speedBefore * 0.7, "...carried on by its speed (not stopped dead, not stuck to the wall)")
check(not ac:IsPlaying("WallRunLeft") and not ac:IsPlaying("WallRunRight"), "...and the wall run clip is off it")
M.run(1.5)

-- vaulting: the supporting hand goes
reset(Vector3.new(-5, 3, 18), FWD, STATES[2]) -- (no right arm: the left-hand vault)
hum.WalkSpeed = Config.RunSpeed
waited = 0
hum.MoveDirection = FWD
while T.Mode ~= "Vault" and waited < 90 do
	M.step(1 / 60)
	waited += 1
end
check(T.Mode == "Vault" and T.M.Hand == "Left", "one-armed: the vault goes on the left hand")
hero:SetAttribute("GoreStage", 2)
T:Step(0)
check(T.Mode == nil and not root.TraversalDrive.Enabled, "...the left arm goes mid-vault: it lets go and falls, held up by nothing")
M.run(1.5)

-- sliding: a leg goes
reset(Vector3.new(16, 3, 25), FWD)
hum.WalkSpeed = Config.RunSpeed
run(FWD, 0.4)
T:Press("Crouch")
M.run(0.15)
lose("Right Leg")
M.step(1 / 60)
check(T.Mode == nil, "sliding: a leg goes - the slide is over")
check(not T:Press("Jump"), "...and no slide cancel out of it")
M.run(1)

-- crawling: an arm goes
reset(Vector3.new(0, 3, -10), FWD)
T:Press("Crawl")
run(FWD, 0.3)
hero:SetAttribute("GoreStage", 1)
M.step(1 / 60)
check(T.Posture == nil and not ac:IsPlaying("Crawl") and not ac:IsPlaying("CrawlIdle"), "crawling: an arm goes - the crawl is over, its clips off the body")

-- the leap's wind-up: the legs go before the push
reset(Vector3.new(16, 3, 10), FWD)
local zl = root.Position.Z
T:Press("Leap")
lose("Left Leg")
M.run(0.5)
check(math.abs(root.Position.Z - zl) < 0.5 and hum.FloorMaterial ~= Enum.Material.Air, "leaping: a leg goes in the wind-up - there is no push")

---------------------------------------------------------------------------
print("-- the fight takes the body")
reset(Vector3.new(26.8, 3, 25), FWD)
hum.WalkSpeed = Config.RunSpeed
run(FWD, 0.2)
wantJump = true
fight.LastJump = os.clock()
waited = 0
while T.Mode ~= "WallRun" and waited < 60 do
	M.step(1 / 60)
	waited += 1
end
fight.Act = false -- (struck: stunned)
T:Cancel("Stunned")
M.step(1 / 60)
check(T.Mode == nil and not root.TraversalDrive.Enabled, "struck on the wall: off it, the blow has the body")
M.run(1.2)
fight.Act = true
reset(Vector3.new(0, 3, -10), FWD)
T:Press("Crouch")
M.run(0.1)
T:Yield("Attack")
check(T.Posture == nil, "a strike out of a crouch stands the body up first")
reset(Vector3.new(3, 3, 16), FWD)
hum.MoveDirection = FWD
wantJump = true
fight.LastJump = os.clock()
waited = 0
while T.Mode ~= "Climb" and waited < 90 do
	M.step(1 / 60)
	waited += 1
end
check(not T:Allows("Attack") and not T:Allows("Dash") and not T:Allows("Block"), "hands on the wall: no strike, dash or guard")
T:Press("Jump")
check(T.Mode == nil, "...jump lets go of it")
M.run(1.5)
reset(Vector3.new(0, 3, -10), FWD)
fight.Act = false
check(not T:Press("Crouch") and not T:Press("Leap") and not T:Press("Crawl"), "stunned: no traversal key does anything")
fight.Act = true

---------------------------------------------------------------------------
print("-- no way round a lost limb")
reset(Vector3.new(16, 3, 25), FWD, STATES[7]) -- (no legs)
hum.WalkSpeed = Config.RunSpeed
run(FWD, 0.4)
check(not T:Press("Crouch") and T.Mode == nil and T.Posture == nil, "no legs, running: the crouch key is neither a slide nor a crouch")
wantJump = true
M.run(0.2)
check(not T:Press("Jump"), "no legs, in the air: no double jump")
check(not T:Press("Leap"), "no legs: no leap")
M.run(1)
reset(Vector3.new(0, 3, -10), FWD, STATES[3]) -- (no arms)
T:Press("Crouch")
M.run(0.1)
check(not T:Press("Crawl") and T.Posture ~= "Crawl", "no arms: crouch -> crawl doesn't crawl")
reset(Vector3.new(0, 3, -10), FWD)
T:Press("Crouch")
M.run(0.1)
T:Press("Jump") -- (standing up with the jump)
check(T.Posture == nil, "jump stands a crouch up")
T:Denied("Slide")
check(T.Mode == nil and T.Posture == nil, "the server refusing a move ends it")

---------------------------------------------------------------------------
print("-- no standing up into a ceiling")
-- (the collision box stays a standing body's - crouching or crawling never lets a body into a gap it
-- couldn't stand in - so this is the check itself: a body put under the low ceiling can't stand)
reset(Vector3.new(-19, 3, 27), FWD)
T:Press("Crawl")
M.run(0.1)
place(Vector3.new(-19, 3, 20))
T:Press("Crawl")
M.step(1 / 60)
check(T.Posture == "Crawl", "under a ceiling the crawl stays (no room to stand)")
T:Press("Jump")
check(T.Posture == "Crawl", "...jump doesn't stand it up either")
place(Vector3.new(-19, 3, 27))
T:Press("Crawl")
check(T.Posture == nil, "out from under it, it stands")
T:Cancel("done")

---------------------------------------------------------------------------
print("-- the blood a bleeding body drags")
reset(Vector3.new(0, 3, -10), FWD)
fight.Bleed = 1
T:Press("Crawl")
run(FWD, 2)
check(fight.Smear > 0, "crawling on a wound drags blood along")
fight.Bleed = 0
T:Cancel("done")
-- the real thing: Blood.Drag along a line pours one continuous streak, not a row of stamps
local Blood = require(combat.CombatBlood)
local Pools = require(combat.BloodPools)
Blood.Ignore(hero)
reset(Vector3.new(-2, 1.2, 0), FWD)
root.Anchored = true
for _ = 1, 150 do
	place(root.Position + Vector3.new(0, 0, -0.04))
	-- (the crawl clip lays the torso along the ground: the stand-in doesn't animate, so it is put there)
	hero.Torso.CFrame = CFrame.new(root.Position.X, 0.55, root.Position.Z) * CFrame.Angles(-math.pi / 2, 0, 0)
	hero.Torso.AssemblyLinearVelocity = Vector3.new(0, 0, -2.4)
	Blood.Drag(hero, 1 / 60, 1)
	M.step(1 / 60)
end
M.run(0.5)
local dbg = Pools.Debug()
print(string.format("   the streak: %d cells, %d pool(s)", #dbg.Ground, dbg.Clusters))
check(#dbg.Ground >= 5 and dbg.Clusters == 1, "a drag is one continuous streak")
root.Anchored = false

---------------------------------------------------------------------------
print("-- it all goes with the character")
T:Destroy()
conn:Disconnect()
check(root:FindFirstChild("TraversalDrive") == nil and root:FindFirstChild("TraversalAttachment") == nil, "its drive and attachment are gone")
check((M.Warnings or 0) == 0, "no warnings")
print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
if failures > 0 then
	error("traversal test failed")
end
