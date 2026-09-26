--[[
	CombatShatter  (ReplicatedStorage.Combat.CombatShatter)
	The stomp's shattered ground. Client-side and cosmetic only (every client builds its own copy
	when it hears about a stomp).

	The ground breaks like a circular quake round the foot: two rings of breaks, evenly spaced (a
	tight inner ring of 8, then a wider outer ring of 12 whose rim is the stomp's own hit radius,
	Config.Attacks.Downslam.StompRadius), with the ground split radially between them. In every
	break a plate of the ground itself (the floor's own material and colour on top, packed earth
	under it) heaves up, its outer edge lifted like a crater's rim, and jagged spikes of rock punch
	up through it, leaning away from the foot. The rings are symmetrical but never uniform: the
	breaks alternate big and small round each ring, and every one has its own size, lean and turn.
	Chunks of turf and rock are torn out of the ground and thrown out over the rings - real physics
	on every client: each one tumbles, bounces off the ground and off the broken rock, rolls to a
	stop and sinks away. The spikes stand for a beat, then everything sinks back the way it came.

	  Shatter.Play(ground, attacker?)    ground = the point on the floor under the stomping foot
	  Shatter.Preview(ground, parent)    the finished shatter, standing still (Studio inspection)

	Nothing clips by accident:
	  - the breaks of a ring never touch each other (plate and spike widths are held under the
	    ring's spacing) and the two rings never touch each other;
	  - the only meetings are the ones that are meant: the spikes of a break bursting up through
	    the middle of their own plate (they rise together and sink together);
	  - a break only opens on open floor - never inside a wall, a tree, a fountain, a portal or off
	    a ledge (every break is checked against the map's collision shapes first);
	  - no break opens under or in the way of a fighter: around everyone standing on the shatter
	    (and along the way they will be thrown or slide, straight out from the foot) the ring
	    leaves a gap;
	  - a new stomp over an older shatter clears the old one first.
	Every piece is a plain part and never in the way of a ray; one heartbeat moves them all. The broken
rock is solid only to the thrown chunks (collision groups ShatterRock / Debris, which never touch a
Fighter - CombatService sets the groups up and puts every fighter's body in Fighters).
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))

local Shatter = {}

local STOMP = Config.Attacks and Config.Attacks.Downslam
local RADIUS: number = (STOMP and STOMP.StompRadius) or 7

-- the two rings. N = breaks (even: they alternate big and small all the way round), R = ring
-- radius (share of the hit radius), W/H = a spike's width and height, Tilt = how far the spikes
-- lean out from the foot, Heave = how far the plate's outer edge is lifted (degrees), At = when
-- the ring breaks (seconds after the stomp), Rise = how long it takes
type Ring = { N: number, R: number, W: { number }, H: { number }, Tilt: { number }, Heave: { number }, At: number, Rise: number }
local RINGS: { Ring } = {
	{ N = 8, R = 0.46, W = { 1.3, 1.6 }, H = { 2.7, 3.4 }, Tilt = { 17, 27 }, Heave = { 13, 22 }, At = 0, Rise = 0.13 },
	{ N = 12, R = 0.9, W = { 1.85, 2.3 }, H = { 3.8, 4.7 }, Tilt = { 29, 41 }, Heave = { 17, 28 }, At = 0.06, Rise = 0.16 },
}
local SMALL = 0.84 -- every other break of a ring is this much smaller
local PLATE = { Across = 1.35, Along = 1.45, Top = 0.24, Earth = 0.68, Room = 0.86 } -- Room: share of the ring's spacing a plate may use
local HOLD = 1.5 -- how long the break stands
local SINK_TIME = 0.4 -- how long it takes to sink back
local VIEW = 220 -- farther than this from the camera, nothing is built
local EARTH = Color3.fromRGB(98, 79, 62) -- the packed earth under the broken surface
local FIGHTER_GAP = 1.3 -- clear space kept round a fighter's body
-- ground that is itself rock: its plates are rock all the way down (no earth layer under it)
local STONY: { [Enum.Material]: boolean } = {
	[Enum.Material.Slate] = true,
	[Enum.Material.Rock] = true,
	[Enum.Material.Basalt] = true,
	[Enum.Material.Granite] = true,
	[Enum.Material.Marble] = true,
	[Enum.Material.Concrete] = true,
	[Enum.Material.Pavement] = true,
	[Enum.Material.Limestone] = true,
	[Enum.Material.Cobblestone] = true,
	[Enum.Material.Brick] = true,
	[Enum.Material.Sandstone] = true,
	[Enum.Material.CrackedLava] = true,
}

---------------------------------------------------------------------------
-- holders, probes, filters
---------------------------------------------------------------------------
local folder: Folder? = nil
local function holder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatShatter"
	f.Parent = workspace
	folder = f
	return f
end

local probe: Part? = nil
local function probePart(): Part
	if probe and probe.Parent then
		return probe
	end
	local p = Instance.new("Part")
	p.Name = "ShatterProbe"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(0, -5000, 0)
	p.Parent = holder()
	probe = p
	return p
end

-- every fighter's body (players and the practice dummies)
local function fighters(): { Model }
	local list = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		for _, m in ipairs(dummies:GetChildren()) do
			if m:IsA("Model") then
				table.insert(list, m)
			end
		end
	end
	return list
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true

local function setIgnore()
	local ignore: { Instance } = {}
	for _, m in ipairs(fighters()) do
		table.insert(ignore, m)
	end
	table.insert(ignore, holder())
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(ignore, fx)
	end
	rayParams.FilterDescendantsInstances = ignore
	overlap.FilterDescendantsInstances = ignore
end

-- the floor right under a spot, if it is floor (not a ledge, a wall top or water)
local function floorAt(p: Vector3, refY: number): RaycastResult?
	local hit = workspace:Raycast(Vector3.new(p.X, refY + 5, p.Z), Vector3.new(0, -9, 0), rayParams)
	if not hit or hit.Normal.Y < 0.8 or hit.Material == Enum.Material.Water or math.abs(hit.Position.Y - refY) > 1.6 then
		return nil
	end
	return hit
end

-- what the floor is made of there (its material, colour and material variant)
local function surfaceOf(hit: RaycastResult): (Enum.Material, Color3, string)
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		local ok, c = pcall(function()
			return (inst :: Terrain):GetMaterialColor(hit.Material)
		end)
		return hit.Material, if ok then c else Color3.fromRGB(110, 110, 110), ""
	elseif inst:IsA("BasePart") then
		return inst.Material, inst.Color, inst.MaterialVariant
	end
	return Enum.Material.Ground, EARTH, ""
end

-- nothing solid in the way of a piece standing along `up` from `base` (length `len`, width `w`)
local LIFT = 1 -- the floor's own bumps (loose tiles, a raised slab) are ignored below this height
local function openAir(base: Vector3, up: Vector3, len: number, w: number): boolean
	if len <= LIFT + 0.2 then
		return true
	end
	local pp = probePart()
	local right = up:Cross(Vector3.xAxis)
	if right.Magnitude < 1e-3 then
		right = up:Cross(Vector3.zAxis)
	end
	right = right.Unit
	local back = right:Cross(up).Unit
	pp.Size = Vector3.new(w, len - LIFT, w)
	pp.CFrame = CFrame.fromMatrix(base + up * ((len + LIFT) / 2), right, up, back)
	local hits = workspace:GetPartsInPart(pp, overlap)
	pp.CFrame = CFrame.new(0, -5000, 0)
	for _, h in ipairs(hits) do
		if h.Transparency < 0.95 then
			return false
		end
	end
	return true
end

-- the gaps the ring leaves for the fighters on it: their bodies and their way out from the foot
type Body = { P: Vector3, R: number, Dir: Vector3 }
local function bodiesAround(center: Vector3, attacker: Model?): { Body }
	local list: { Body } = {}
	for _, m in ipairs(fighters()) do
		if m ~= attacker then
			local root = m:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local off = root.Position - center
				local flat = Vector3.new(off.X, 0, off.Z)
				local r = flat.Magnitude
				if r < RADIUS + 3 and math.abs(off.Y) < 9 then
					table.insert(list, { P = Vector3.new(root.Position.X, center.Y, root.Position.Z), R = r, Dir = if r > 0.2 then flat.Unit else Vector3.new(1, 0, 0) })
				end
			end
		end
	end
	return list
end

local function blockedByBody(base: Vector3, reach: number, center: Vector3, bodies: { Body }): boolean
	for _, b in ipairs(bodies) do
		-- the body itself
		if (Vector3.new(base.X, 0, base.Z) - Vector3.new(b.P.X, 0, b.P.Z)).Magnitude < reach + FIGHTER_GAP then
			return true
		end
		-- the way out: straight on from the foot through the body, to past the outer ring
		local off = Vector3.new(base.X - center.X, 0, base.Z - center.Z)
		local along = off:Dot(b.Dir)
		if along > b.R - 0.5 then
			local side = (off - b.Dir * along).Magnitude
			if side < reach + FIGHTER_GAP then
				return true
			end
		end
	end
	return false
end

local function rockColor(rng: Random): Color3
	local g = rng:NextInteger(100, 120)
	return Color3.fromRGB(g, g - 4, g - 9)
end

-- the clod mesh (the crater's own rock, ReplicatedStorage.Combat.VFX.Rocks.Chunk): lumps of torn
-- earth and chips of rock. Without it the pieces fall back to plain blocks.
local function chunkTemplate(): MeshPart?
	local vfx = CombatFolder:FindFirstChild("VFX")
	local rocks = vfx and vfx:FindFirstChild("Rocks")
	local c = rocks and rocks:FindFirstChild("Chunk")
	return if c and c:IsA("MeshPart") then c else nil
end

local function newPiece(class: string, size: Vector3, material: Enum.Material, color: Color3, variant: string?): BasePart
	local tpl = if class == "Chunk" then chunkTemplate() else nil
	local p: BasePart = if tpl then tpl:Clone() elseif class == "Chunk" then Instance.new("Part") else Instance.new(class) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = material
	if variant and variant ~= "" then
		p.MaterialVariant = variant
	end
	p.Color = color
	p.Size = size
	return p
end

-- the collision groups CombatService sets up (checked each shatter: they replicate from the server)
local function groupsReady(): boolean
	local ok, yes = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered("Debris") and PhysicsService:IsCollisionGroupRegistered("ShatterRock")
	end)
	return ok and yes == true
end

-- the broken rock is solid to the thrown chunks only
local function solidToDebris(part: BasePart)
	part.CollisionGroup = "ShatterRock"
	part.CanCollide = true
end

-- a frame standing on `base`, leaning along `dir` by `tilt` (negative: back toward the foot)
local function leanFrame(base: Vector3, dir: Vector3, tilt: number): (CFrame, Vector3)
	local up = (Vector3.yAxis * math.cos(tilt) + dir * math.sin(tilt)).Unit
	local right = up:Cross(dir).Unit
	local back = right:Cross(up).Unit
	return CFrame.fromMatrix(base, right, up, back), up
end

---------------------------------------------------------------------------
-- motion: one heartbeat moves every piece of every live shatter
---------------------------------------------------------------------------
type Move = { Part: BasePart, From: CFrame, To: CFrame, T0: number, Dur: number, Back: boolean }
local moves: { Move } = {}
local moveConn: RBXScriptConnection? = nil

local BACK = 1.70158
local function easeBackOut(x: number): number
	local k = x - 1
	return 1 + (BACK + 1) * k * k * k + BACK * k * k
end

local function stepMoves()
	local now = os.clock()
	local parts: { BasePart } = {}
	local cfs: { CFrame } = {}
	for i = #moves, 1, -1 do
		local m = moves[i]
		if not m.Part.Parent then
			table.remove(moves, i)
		elseif now >= m.T0 then
			local x = math.clamp((now - m.T0) / m.Dur, 0, 1)
			local e = if m.Back then easeBackOut(x) else x * x
			table.insert(parts, m.Part)
			table.insert(cfs, m.From:Lerp(m.To, e))
			if x >= 1 then
				table.remove(moves, i)
			end
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if #moves == 0 and moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
end

local function move(part: BasePart, from: CFrame, to: CFrame, delay: number, dur: number, back: boolean)
	-- (a piece already moving is taken over from where it is)
	for i = #moves, 1, -1 do
		if moves[i].Part == part then
			table.remove(moves, i)
		end
	end
	table.insert(moves, { Part = part, From = from, To = to, T0 = os.clock() + delay, Dur = dur, Back = back })
	if not moveConn then
		moveConn = RunService.Heartbeat:Connect(stepMoves)
	end
end

---------------------------------------------------------------------------
-- building one shatter
---------------------------------------------------------------------------
-- one break: the plate of ground (surface + earth) and the spikes bursting through it
type Piece = { Part: BasePart, Final: CFrame, Buried: CFrame, Lag: number }
type Break = { Pieces: { Piece }, At: number, Rise: number, Base: Vector3, Dir: Vector3, Edge: number, Outer: boolean, Material: Enum.Material, Color: Color3 }

local function between(rng: Random, range: { number }): number
	return rng:NextNumber(range[1], range[2])
end

local function build(ground: Vector3, attacker: Model?, rng: Random): (Model?, { Break }, number)
	setIgnore()
	local solid = groupsReady()
	local model = Instance.new("Model")
	model.Name = "Shatter"
	local bodies = bodiesAround(ground, attacker)
	local spin0 = rng:NextNumber(0, math.pi * 2)
	local breaks: { Break } = {}

	for ri, ring in ipairs(RINGS) do
		local n = ring.N
		local r = ring.R * RADIUS
		local step = math.pi * 2 / n
		local spacing = 2 * r * math.sin(step / 2)
		-- the outer ring sits half a step round from the inner one: its breaks fall between
		local offset = spin0 + (if ri == 2 then step * 0.5 else 0)
		for i = 1, n do
			-- evenly round the ring (the quake's symmetry), each break a touch off its mark
			local a = offset + (i - 1) * step + rng:NextNumber(-0.035, 0.035) * step
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			-- big and small in turn round the ring, and no two alike
			local k = (if i % 2 == 0 then SMALL else 1) * rng:NextNumber(0.94, 1.04)
			local w = between(rng, ring.W) * k
			local h = between(rng, ring.H) * k
			local tilt = math.rad(between(rng, ring.Tilt))
			local across = math.min(w * PLATE.Across, spacing * PLATE.Room) * rng:NextNumber(0.93, 1)
			local along = w * PLATE.Along * rng:NextNumber(0.92, 1.05)
			local want = ground + dir * (r + rng:NextNumber(-0.1, 0.1))
			local hit = floorAt(want, ground.Y)
			if hit and not blockedByBody(want, along * 0.5, ground, bodies) then
				local base = hit.Position
				local spikeFrame, up = leanFrame(base, dir, tilt)
				if openAir(base, up, h * 0.75, w * 0.6) then
					local mat, col, variant = surfaceOf(hit)
					local stony = STONY[mat] == true
					local pieces: { Piece } = {}
					-- the plate: a slab of the ground itself (the floor's surface on packed earth),
					-- its outer edge heaved up (it faces the foot), its inner edge still under the
					-- ground, turned a little off the ring so no two lie the same way. The earth is
					-- the surface's own footprint and runs a hair up into it: no seam, no gap
					local heave = -math.rad(between(rng, ring.Heave))
					local plateFrame = leanFrame(base + dir * (w * 0.05), dir, heave) * CFrame.Angles(0, math.rad(rng:NextNumber(-9, 9)), 0)
					local top = newPiece("Part", Vector3.new(across, PLATE.Top, along), mat, col, variant)
					local topFinal = plateFrame * CFrame.new(0, 0.08, 0)
					table.insert(pieces, { Part = top, Final = topFinal, Buried = topFinal - Vector3.new(0, 1.05, 0), Lag = 0 })
					local earthCol = if stony then col:Lerp(Color3.new(), 0.28) else EARTH:Lerp(Color3.new(), rng:NextNumber(0, 0.12))
					local earth = newPiece("Part", Vector3.new(across * 0.995, PLATE.Earth, along * 0.995), if stony then mat else Enum.Material.Ground, earthCol, if stony then variant else nil)
					local earthFinal = plateFrame * CFrame.new(0, 0.08 - (PLATE.Top + PLATE.Earth) / 2 + 0.05, 0)
					table.insert(pieces, { Part = earth, Final = earthFinal, Buried = earthFinal - Vector3.new(0, 1.05, 0), Lag = 0 })
					-- the spikes: a big jagged one and a smaller one beside it, turned apart, both
					-- leaning out from the foot; a quarter of each stays under the ground
					local rc = rockColor(rng)
					local main = newPiece("CornerWedgePart", Vector3.new(w, h, w * 0.9), Enum.Material.Slate, rc)
					local mainFinal = spikeFrame * CFrame.Angles(0, math.rad(rng:NextNumber(-34, 34)), 0) * CFrame.new(0, h * 0.25, 0)
					table.insert(pieces, { Part = main, Final = mainFinal, Buried = mainFinal - up * (h * 0.75 + 0.3), Lag = 0.014 })
					local sideH = h * rng:NextNumber(0.55, 0.68)
					local side = newPiece("CornerWedgePart", Vector3.new(w * 0.7, sideH, w * 0.6), Enum.Material.Slate, rc:Lerp(Color3.new(), 0.06))
					local sideFinal = spikeFrame * CFrame.Angles(0, math.rad(90 + rng:NextNumber(-25, 25)), 0) * CFrame.new(w * 0.18, sideH * 0.5 - h * 0.2, 0)
					table.insert(pieces, { Part = side, Final = sideFinal, Buried = sideFinal - up * (sideH * 0.8 + 0.3), Lag = 0.03 })
					for _, p in ipairs(pieces) do
						p.Part.CFrame = p.Buried
						if solid then
							solidToDebris(p.Part)
						end
						p.Part.Parent = model
					end
					table.insert(breaks, {
						Pieces = pieces,
						At = ring.At + (i % 3) * 0.01 + rng:NextNumber(0, 0.012),
						Rise = ring.Rise,
						Base = base,
						Dir = dir,
						Edge = w * 0.05 + along * 0.5,
						Outer = ri == #RINGS,
						Material = mat,
						Color = col,
					})
				end
			end
		end
	end
	if #breaks == 0 then
		model:Destroy()
		return nil, breaks, spin0
	end
	return model, breaks, spin0
end

---------------------------------------------------------------------------
-- live shatters (a new one clears any old one it would overlap)
---------------------------------------------------------------------------
type Live = { Center: Vector3, Clear: () -> () }
local live: { Live } = {}

local function clearNear(center: Vector3)
	for i = #live, 1, -1 do
		local l = live[i]
		if (l.Center - center).Magnitude < RADIUS * 2.3 then
			table.remove(live, i)
			l.Clear()
		end
	end
end

---------------------------------------------------------------------------
-- debris: chunks of turf and rock torn out of the ground round the foot and thrown out over the
-- rings. Real physics (each client simulates its own): they tumble, hit the ground and the
-- broken rock, bounce and roll to a stop; then each one freezes where it lies and sinks into the
-- ground as it fades. They never touch a fighter (collision groups).
---------------------------------------------------------------------------
local DEBRIS = {
	Count = { 14, 18 },
	Turf = 0.55, -- share that are turf (the rest are rock)
	TurfSize = { 0.85, 1.35 },
	RockSize = { 0.65, 1.1 },
	Out = { 8, 24 }, -- studs/s, straight out from the foot (give or take)
	Up = { 30, 48 }, -- studs/s up
	Spin = 16, -- rad/s, any axis
	Life = { 1.5, 2.4 }, -- seconds of physics
	Sink = 0.5, -- then sinks away over this long
}

local function launchChunk(from: Vector3, dir: Vector3, turf: boolean, mat: Enum.Material, col: Color3, variant: string, rng: Random)
	local s = if turf then between(rng, DEBRIS.TurfSize) else between(rng, DEBRIS.RockSize)
	local size = Vector3.new(s * rng:NextNumber(1.05, 1.4), s * rng:NextNumber(0.65, 0.95), s * rng:NextNumber(0.9, 1.2))
	local part = if turf
		then newPiece("Chunk", size, mat, col:Lerp(Color3.new(), rng:NextNumber(0, 0.08)), variant)
		else newPiece("Chunk", size, Enum.Material.Slate, rockColor(rng))
	part.Name = "Debris"
	part.CollisionGroup = "Debris"
	part.CanCollide = true
	part.Anchored = false
	part.CustomPhysicalProperties = PhysicalProperties.new(if turf then 1.6 else 2.4, 0.75, 0.22, 1, 1)
	part.CFrame = CFrame.new(from + Vector3.new(0, size.Y * 0.5, 0)) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28))
	part.Parent = holder()
	-- thrown out and up, a little off straight, spinning every which way
	local side = dir:Cross(Vector3.yAxis)
	local out = (dir + side * rng:NextNumber(-0.35, 0.35)).Unit
	part.AssemblyLinearVelocity = out * between(rng, DEBRIS.Out) + Vector3.new(0, between(rng, DEBRIS.Up), 0)
	part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * DEBRIS.Spin
	task.delay(between(rng, DEBRIS.Life), function()
		if not part.Parent then
			return
		end
		-- freezes where it lies, then sinks into the ground as it fades
		part.Anchored = true
		part.CanCollide = false
		local cf = part.CFrame
		move(part, cf, cf - Vector3.new(0, size.Magnitude * 0.6, 0), 0, DEBRIS.Sink, false)
		TweenService:Create(part, TweenInfo.new(DEBRIS.Sink, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		task.delay(DEBRIS.Sink + 0.05, function()
			part:Destroy()
		end)
	end)
end

-- no chunk is thrown straight across a fighter
local function clearFlight(from: Vector3, dir: Vector3, roots: { Vector3 }): boolean
	local a = Vector3.new(from.X, 0, from.Z)
	local d = dir * 9
	for _, p in ipairs(roots) do
		local q = Vector3.new(p.X, 0, p.Z)
		local t = math.clamp((q - a):Dot(d) / d:Dot(d), 0, 1)
		if (a + d * t - q).Magnitude < 1.9 and math.abs(p.Y - from.Y) < 7 then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------
-- the shatter
---------------------------------------------------------------------------
function Shatter.Play(ground: Vector3, attacker: Model?)
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - ground).Magnitude > VIEW then
		return
	end
	clearNear(ground)
	local rng = Random.new()
	local model, breaks = build(ground, attacker, rng)
	if not model then
		return
	end
	model.Parent = holder()

	-- up it comes: each plate heaves up and its spikes burst through the middle of it, a hair past
	-- their rest (Back easing) - the inner ring first, the outer ring a beat later, the shock
	-- running outward
	for _, b in ipairs(breaks) do
		for _, p in ipairs(b.Pieces) do
			move(p.Part, p.Buried, p.Final, b.At + p.Lag, b.Rise * (if p.Lag > 0 then 1 else 0.8), true)
		end
	end

	-- the debris: torn out of the ground round the foot as the rings break, thrown out over them
	-- in every direction - random sizes, speeds, spins and timing, turf and rock mixed
	if groupsReady() then
		local roots: { Vector3 } = {}
		for _, m in ipairs(fighters()) do
			local root = m:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and m ~= attacker then
				table.insert(roots, root.Position)
			end
		end
		local innerEdge = RINGS[1].R * RADIUS - 1.1 -- inside the inner ring's plates
		local count = rng:NextInteger(DEBRIS.Count[1], DEBRIS.Count[2])
		for _ = 1, count do
			local a = rng:NextNumber(0, math.pi * 2)
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local hit = floorAt(ground + dir * rng:NextNumber(1.3, innerEdge), ground.Y)
			if hit and clearFlight(hit.Position, dir, roots) then
				local mat, col, variant = surfaceOf(hit)
				local turf = rng:NextNumber() < DEBRIS.Turf
				local from = hit.Position + Vector3.new(0, 0.08, 0)
				task.delay(rng:NextNumber(0, 0.12), function()
					launchChunk(from, dir, turf, mat, col, variant, rng)
				end)
			end
		end
	end

	-- then it all sinks back the way it came - the outer ring first, the ground closing back in on
	-- the foot - or is cleared at once when a new stomp lands on it
	local done = false
	local function finish(fast: boolean)
		if done then
			return
		end
		done = true
		local t = if fast then 0.12 else SINK_TIME
		local longest = 0
		for idx, b in ipairs(breaks) do
			local d = if fast then 0 else (if b.Outer then 0 else 0.12) + (idx % 4) * 0.025
			for _, p in ipairs(b.Pieces) do
				-- the spikes go down first, the plate settles after them
				local lag = if fast then 0 elseif p.Lag > 0 then 0 else 0.1
				move(p.Part, p.Part.CFrame, p.Buried, d + lag, t, false)
				longest = math.max(longest, d + lag + t)
			end
		end
		task.delay(longest + 0.08, function()
			model:Destroy()
		end)
	end
	local entry: Live = { Center = ground, Clear = function()
		finish(true)
	end }
	table.insert(live, entry)
	task.delay(0.22 + HOLD, function()
		local i = table.find(live, entry)
		if i then
			table.remove(live, i)
		end
		finish(false)
	end)
end

-- the finished shatter standing still, for looking at in Studio (no fighters, no animation)
function Shatter.Preview(ground: Vector3, parent: Instance, seed: number?): Model?
	local model, breaks = build(ground, nil, Random.new(seed or 1))
	if not model then
		return nil
	end
	for _, b in ipairs(breaks) do
		for _, p in ipairs(b.Pieces) do
			p.Part.CFrame = p.Final
		end
	end
	model.Parent = parent
	return model
end

return Shatter
