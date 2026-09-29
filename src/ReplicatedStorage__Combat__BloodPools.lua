--[[
	BloodPools  (ReplicatedStorage.Combat.BloodPools)
	The blood on the ground and on the walls - client-side and cosmetic (CombatBlood's drops land
	here). Blood that lands is a LIQUID that finds its own way over whatever it landed on:

	THE GROUND (floors, slopes, stairs, the world's Terrain - anything that faces up) is a height field:
	a grid of Config.Blood.Pool.Cell studs over the world's X / Z, and every cell of it that holds blood
	knows the real surface under it (sampled with a ray: its height, its tilt, its material). A drop
	pours its volume into the cells it lands and skids across, and from there the blood moves by its
	own LEVEL - the ground's height plus how deep the blood stands (Pool.Depth for a full cell):

	  * it runs from a higher level to a lower one: down a slope, down the side of a Terrain bump, off
	    a step, and it collects in dips and hollows, filling them before it spills over their rim
	  * on the flat it spreads out from the deep middle of a pool to its thin edge, in uneven lobes,
	    until the edge is a thin film (Pool.Retain of a cell: less on a slope, so a run down a slope
	    leaves only a thin trail)
	  * it never goes through a wall or up a step it can't fill up to; it goes round obstacles
	  * reaching an edge with nothing under it - a ledge, the gap between two parts, a crack in the floor,
	    a hole - it pours over and SEEPS THROUGH as drips that fall to whatever is below, and pools
	    there (a crack takes most of what crosses it and lets the rest over)
	  * a porous ground drinks it in (Pool.Materials: grass, sand, mud and snow a lot, wood and stone a
	    little, plastic, metal and glass not at all) and holds it back from spreading: a pool on grass
	    shrinks away from its edges while one on a metal floor stays
	  * a steep Terrain face (a cliff, a hillside past ~63 deg) doesn't hold it: it trickles down to
	    the ground below

	WALLS (the upright faces of parts) get a grid on their own plane: blood that lands there runs down
	in a thin trail and drips off at the wall's foot. Under a ceiling it gathers and drips back down.

	HOW IT LOOKS. Every cell with blood in it is one flat, opaque piece lying on the surface under it
	(tilted with it), at the centre of the blood poured into it while it holds a little, covering its
	whole cell once it is full. Pieces of neighbouring cells overlap, lie in the same layer and are the
	same colour, so a pool is one continuous surface however it grew: no stacking, no see-through
	overlap, no seams. Only the outside edge of the whole shape shows the thin, darker clotting rim. It
	is one constant dark red (Config.Blood.Color) from the moment it lands until it is gone - no shine,
	no drying. A pool lies there on one clock (the freshest blood in it) and at the end of its life
	(Pool.Life) soaks away from its thin edges inward. Blood never stays on water, a fighter, anything
	see-through or non-colliding, or anything loose (it would float away with it). Fast drops also
	fling specks of spray ahead of their splat.

	Cheap: every part is pooled and reused, a cell is redrawn only while it grows, runs, drinks in or
	soaks away, the flow runs at 10 Hz and only where blood is running, what lies around a running
	cell is sampled once and remembered, nothing is ever recoloured. Budgets (Pool.MaxCells,
	Pool.MaxSpecks) cap it: past them the oldest pool soaks away early.

	  Pools.Init(env)                     env = { Holder, Cast, Drip, InView, TimeScale, Budget }
	  Pools.Deposit(hit, size, vel, k?)   a drop of `size` met `hit` at `vel` (k: volume multiplier)
	  Pools.Pour(hit, area, spread?)      blood poured straight onto the surface a ray found (a limb
	                                      landing, a bleeding body hitting the floor)
	  Pools.Stats() / Pools.Debug()       counts / the cells themselves (tools/tests)
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Pools = {}

local P = Config.Blood.Pool
local CELL = P.Cell
local CAP = CELL * CELL -- a full cell's blood (studs² of cover)
local SPOT = P.Spot -- studs² a drop of size s covers: SPOT * s³
local GROW = 2.1 -- a cell's piece covers this much more than its area (full cells overlap: one surface)
local DEPTH = P.Depth -- how deep the blood of a full cell stands (its level over the ground)
local STEP = 0.7 -- a neighbour's ground this far up or down is the same surface (more: a wall / a drop)
local LIFE, FADE, QUICK = P.Life, P.Fade, 0.9
local PARK = CFrame.new(0, -5000, 0)
local SPLASH = 0.2 -- seconds a cell takes to spread out to its new size (with a little overshoot)
local MAX_CELLS, MAX_SPECKS = P.MaxCells, P.MaxSpecks -- (Init scales them to the device)

-- every piece of a kind in the same layer over its surface, whatever pool it belongs to (so bodies that
-- meet are one surface and a rim only shows round the outside), and thin enough that its top is flat
local RIM_H, SPECK_H, BODY_H = 0.012, 0.017, 0.024
local THICK = 0.006
-- one dark red for all of it, the clotting edge a shade darker (never changing)
local BODY_COLOR = Config.Blood.Color
local RIM_COLOR = P.Rim

local FLOOR_Y = 0.45 -- a surface facing up at least this much is ground (up to ~63 deg)
local WALL_SLOPE = 0.77 -- (a part's face steeper than ~50 deg holds a wall's thin run, not a pool)

-- how a ground takes blood: Absorb = the share of it drunk in each second, Spread = how freely it
-- runs over it (by the material's name; anything not listed is Default)
local MATS: { [string]: { Absorb: number, Spread: number } } = P.Materials
local function matOf(hit: RaycastResult): { Absorb: number, Spread: number }
	local ok, name = pcall(function()
		return hit.Material.Name
	end)
	return (ok and MATS[name]) or MATS.Default
end

---------------------------------------------------------------------------
-- the environment (CombatBlood hands it over: its folder, its ray, its drops)
---------------------------------------------------------------------------
local env: any = {
	Holder = function(): Instance
		return workspace
	end,
	Cast = function(_o: Vector3, _d: Vector3): RaycastResult?
		return nil
	end,
	Drip = function(_p: Vector3, _v: Vector3, _s: number) end,
	InView = function(_p: Vector3): boolean
		return true
	end,
	TimeScale = function(): number
		return 1
	end,
}
function Pools.Init(e: any)
	for k, v in pairs(e) do
		env[k] = v
	end
	local b = e.Budget or 1
	MAX_CELLS = math.floor(P.MaxCells * b)
	MAX_SPECKS = math.floor(P.MaxSpecks * b)
end

-- (a stable pseudo-random number 0..1 for a cell: the same cell always has the same shape)
local function hash(i: number, j: number, s: number): number
	local x = math.sin(i * 12.9898 + j * 78.233 + s * 37.719) * 43758.5453
	return x - math.floor(x)
end

local function rand(a: number, b: number): number
	return a + math.random() * (b - a)
end

-- a splash finding its rest: a touch past its size, then back
local function backOut(x: number): number
	local c1 = 1.2
	local y = x - 1
	return 1 + (c1 + 1) * y * y * y + c1 * y * y
end

-- may blood stay on what a ray found? (a real, still surface - not water, not something loose)
local function holds(hit: RaycastResult): boolean
	if hit.Material == Enum.Material.Water then
		return false
	end
	local inst = hit.Instance
	if inst:IsA("BasePart") and not inst:IsA("Terrain") then
		local root = inst.AssemblyRootPart
		if not (inst.Anchored or (root and root.Anchored)) then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------
-- parts (one kind for everything: a flattened sphere, pooled)
---------------------------------------------------------------------------
local free: { Part } = {}
local partCount = 0
local function takePart(): Part
	local p = table.remove(free)
	if p and p.Parent then
		return p
	end
	p = Instance.new("Part")
	p.Name = "BloodPool"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = 0
	p.Color = BODY_COLOR
	p.Size = Vector3.new(0.01, 0.01, 0.01)
	p.CFrame = PARK
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = env.Holder()
	partCount += 1
	return p
end

local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}
local function park(p: Part)
	table.insert(moveParts, p)
	table.insert(moveCfs, PARK)
	table.insert(free, p)
end

---------------------------------------------------------------------------
-- cells: the ground's (a height field over X / Z) and the walls' (a grid on each wall's plane)
---------------------------------------------------------------------------
type Cell = {
	Floor: boolean,
	Sheet: any, -- (a wall's; the ground's own for the ground)
	Id: number,
	I: number,
	J: number,
	Key: number,
	Area: number,
	Cu: number, -- the centre of everything poured in (the ground: world X, Z; a wall: its plane's u, v)
	Cv: number,
	Rot: number,
	Asp: number, -- 1 = round; > 1 stretched along Rot
	Fresh: number,
	Expire: number, -- when it starts to soak away
	FadeLen: number,
	GrowAt: number,
	From: number, -- the radius it grew from (GrowAt)
	R: number, -- radius drawn now
	DrawnR: number, -- (the radius it was last drawn at: a pool drinking in is redrawn only now and then)
	Scale: number, -- 1, less while soaking away
	Edge: boolean, -- at the pool's edge (has a rim)
	Nbs: number, -- how many of the 8 cells round it hold blood too
	Body: Part?,
	Rim: Part?,
	Cluster: any,
	Flowing: boolean,
	Solid: boolean, -- surface under the cell's middle (not: a cell at a ledge's edge - it stays small)
	-- the ground's cells
	Y: number, -- the ground's height at (GX, GZ), and its tilt there
	GX: number,
	GZ: number,
	N: Vector3,
	Absorb: number,
	Spread: number,
	Around: { any }, -- what lies round it, each way (sampled once, when blood first runs there)
	Spill: { number }, -- blood gathering at each edge before it drips over
}
local nextId = 0
local cellCount = 0
local active: { [Cell]: boolean } = {} -- cells being redrawn every frame (growing, soaking away)
local flowing: { [Cell]: boolean } = {}

local function keyOf(i: number, j: number): number
	return (i + 65536) * 262144 + (j + 65536)
end

-- THE GROUND: columns of cells (a column can hold a cell on the floor and another on a bridge above it)
local GROUND = { Floor = true, Cols = {} :: { [number]: { Cell } }, Count = 0, Dirty = false, Clusters = {} :: { any } }

-- the ground's cell in column (i, j) at (about) height y
local function groundCell(i: number, j: number, y: number): Cell?
	local col = GROUND.Cols[keyOf(i, j)]
	if not col then
		return nil
	end
	local best, bd = nil, STEP
	for _, c in ipairs(col) do
		local d = math.abs(c.Y - y)
		if d <= bd then
			best, bd = c, d
		end
	end
	return best
end

-- the ground under (x, z) near height y: the surface a ray finds within STEP of it, facing up and able
-- to hold blood (nil: nothing there - a gap, a drop, water, something loose)
local function groundAt(x: number, z: number, y: number): RaycastResult?
	local hit = env.Cast(Vector3.new(x, y + STEP, z), Vector3.new(0, -STEP * 2, 0))
	if hit and hit.Normal.Y >= FLOOR_Y and holds(hit) then
		return hit
	end
	return nil
end

-- the ground's height under (x, z) on this cell's own surface (its plane through its sample point)
local function planeY(c: Cell, x: number, z: number): number
	local n = c.N
	return c.Y - (n.X * (x - c.GX) + n.Z * (z - c.GZ)) / n.Y
end

-- WALLS: a grid on each wall's plane
local sheets: { any } = {}
local function sheetFor(n: Vector3, plane: number): any
	for _, s in ipairs(sheets) do
		if s.N:Dot(n) > 0.9995 and math.abs(s.Plane - plane) < 0.012 then
			return s
		end
	end
	local u: Vector3
	if math.abs(n.Y) > 0.985 then
		u = Vector3.xAxis - n * n.X
	else
		u = Vector3.yAxis:Cross(n)
	end
	u = u.Unit
	local v = n:Cross(u).Unit
	local g = Vector3.new(0, -1, 0)
	local gt = g - n * n:Dot(g)
	local du, dv = 0, 0
	if gt.Magnitude > 0.05 then
		local d = gt.Unit
		du, dv = d:Dot(u), d:Dot(v)
	end
	local s = { Floor = false, N = n, Plane = plane, U = u, V = v, Basis = CFrame.fromMatrix(n * plane, n, u, v), Du = du, Dv = dv, Cells = {}, Count = 0, Blocked = {}, Dirty = false, Clusters = {} }
	table.insert(sheets, s)
	return s
end
local function wallPoint(s: any, u: number, v: number, h: number): Vector3
	return s.Basis.Position + s.U * u + s.V * v + s.N * h
end
-- solid surface of this very wall plane under (u, v)? (never past the wall's edge)
local function wallSurface(s: any, u: number, v: number): boolean
	local p = wallPoint(s, u, v, 0)
	local hit = env.Cast(p + s.N * 0.3, s.N * -0.55)
	return hit ~= nil and hit.Normal:Dot(s.N) > 0.9 and math.abs(hit.Position:Dot(s.N) - s.Plane) < 0.05 and holds(hit)
end

-- (fresh: the clock of the blood it is made for - blood running on keeps its own: a cell made by it
-- is as old as that blood, never a fresh one that would keep the pool there for ever)
local function newCell(floor: boolean, sheet: any, i: number, j: number, key: number, cu: number, cv: number, solid: boolean, fresh: number?): Cell
	local now = fresh or os.clock()
	nextId += 1
	local c: Cell = {
		Floor = floor,
		Sheet = sheet,
		Id = nextId,
		I = i,
		J = j,
		Key = key,
		Area = 0,
		Cu = cu,
		Cv = cv,
		Rot = hash(i, j, 1) * math.pi * 2,
		Asp = 1 + hash(i, j, 2) * 0.35,
		Fresh = now,
		Expire = now + LIFE - FADE,
		FadeLen = FADE,
		GrowAt = os.clock(),
		From = 0,
		R = 0,
		DrawnR = 0,
		Scale = 1,
		Edge = true,
		Nbs = 0,
		Body = nil,
		Rim = nil,
		Cluster = nil,
		Flowing = false,
		Solid = solid,
		Y = 0,
		GX = 0,
		GZ = 0,
		N = Vector3.yAxis,
		Absorb = 0,
		Spread = 1,
		Around = {},
		Spill = {},
	}
	cellCount += 1
	return c
end

-- the ground's cell at (i, j) for blood arriving at (x, z) near height y: made if it may be (the budget,
-- ground there). `hit`: the surface already found there (a drop's own landing)
local function groundCellAt(i: number, j: number, x: number, z: number, y: number, hit: RaycastResult?, fresh: number?): Cell?
	local c = groundCell(i, j, y)
	if c then
		return c
	end
	if cellCount >= MAX_CELLS then
		return nil
	end
	local cx, cz = (i + 0.5) * CELL, (j + 0.5) * CELL
	-- the ground under the cell's middle (its own surface); failing that, where the blood came down
	-- (a cell at a ledge's edge: kept small, never pulled over the edge)
	local g = groundAt(cx, cz, y)
	local solid = g ~= nil
	if not g then
		g = hit or groundAt(x, z, y)
		if not g then
			return nil
		end
	end
	local nc = newCell(true, GROUND, i, j, keyOf(i, j), x, z, solid, fresh)
	nc.Y = g.Position.Y
	nc.GX, nc.GZ = g.Position.X, g.Position.Z
	nc.N = g.Normal
	local m = matOf(g)
	nc.Absorb, nc.Spread = m.Absorb, m.Spread
	local col = GROUND.Cols[nc.Key]
	if not col then
		col = {}
		GROUND.Cols[nc.Key] = col
	end
	table.insert(col, nc)
	GROUND.Count += 1
	GROUND.Dirty = true
	return nc
end

local function wallCellAt(s: any, i: number, j: number, pu: number, pv: number, flow: boolean?, fresh: number?): Cell?
	local key = keyOf(i, j)
	local c = s.Cells[key]
	if c then
		return c
	end
	if cellCount >= MAX_CELLS or (flow and s.Blocked[key]) then
		return nil
	end
	local solid = wallSurface(s, (i + 0.5) * CELL, (j + 0.5) * CELL)
	if flow and not solid then
		s.Blocked[key] = true
		return nil
	elseif not solid and not wallSurface(s, pu, pv) then
		return nil
	end
	local nc = newCell(false, s, i, j, key, pu, pv, solid, fresh)
	s.Cells[key] = nc
	s.Count += 1
	s.Dirty = true
	return nc
end

local function alive(c: Cell): boolean
	if c.Floor then
		local col = GROUND.Cols[c.Key]
		return col ~= nil and table.find(col, c) ~= nil
	end
	return c.Sheet.Cells[c.Key] == c
end

local function removeCell(c: Cell)
	if not alive(c) then
		return
	end
	if c.Floor then
		local col = GROUND.Cols[c.Key]
		table.remove(col, table.find(col, c) :: number)
		if #col == 0 then
			GROUND.Cols[c.Key] = nil
		end
		GROUND.Count -= 1
		GROUND.Dirty = true
	else
		c.Sheet.Cells[c.Key] = nil
		c.Sheet.Count -= 1
		c.Sheet.Dirty = true
	end
	cellCount -= 1
	active[c] = nil
	flowing[c] = nil
	if c.Body then
		park(c.Body)
		c.Body = nil
	end
	if c.Rim then
		park(c.Rim)
		c.Rim = nil
	end
end

-- the cell next to `c` one step (di, dj) along its grid, on the same surface
local function neighbour(c: Cell, di: number, dj: number): Cell?
	if c.Floor then
		local x, z = (c.I + di + 0.5) * CELL, (c.J + dj + 0.5) * CELL
		return groundCell(c.I + di, c.J + dj, planeY(c, x, z))
	end
	return c.Sheet.Cells[keyOf(c.I + di, c.J + dj)]
end

-- how full a cell is (0..1); how far it is inside a pool (0 at the edge .. 1 with blood all round it:
-- then it covers its whole square however thin the film - a pool is one continuous surface, never a
-- mesh of blobs); and the radius its piece is drawn at (at the edge: as much as its blood covers)
local R_FULL = math.sqrt(CAP * GROW / math.pi)
local function fullness(c: Cell): number
	return math.min(1, c.Area / CAP)
end
local function inside(c: Cell): number
	return if c.Solid then math.clamp((c.Nbs - 2) / 4, 0, 1) else 0
end
local function radiusOf(c: Cell): number
	local r = math.sqrt(math.min(c.Area, if c.Solid then CAP else CAP * 0.35) * GROW / math.pi)
	return r + (R_FULL - r) * inside(c)
end

-- the blood a cell keeps as a film however it runs (less on a slope: a run leaves a thin trail; a wall
-- keeps only its run's trail; at a ledge's edge a cell never grows past a small spot)
local function retainOf(c: Cell): number
	if not c.Solid then
		return CAP * 0.3
	end
	if not c.Floor then
		return CAP * P.WallFilm
	end
	local flat = math.clamp((c.N.Y - FLOOR_Y) / (1 - FLOOR_Y), 0, 1)
	return CAP * P.Retain * (0.25 + 0.75 * flat * flat) / math.max(c.Spread, 0.3)
end

-- the blood's level in a ground cell: the ground under it plus how deep it stands
local function levelOf(c: Cell): number
	return c.Y + DEPTH * c.Area / CAP
end

---------------------------------------------------------------------------
-- pouring blood in
---------------------------------------------------------------------------
-- `area` studs² into cell `c` at (u, v) (its own coordinates); the first pour into a cell shapes it (a
-- skid stretches it). fresh: the blood's own clock (blood running on keeps the clock it had)
local function fill(c: Cell, u: number, v: number, area: number, now: number, fresh: number?, skidRot: number?, asp: number?)
	local f = fresh or now
	local was = c.Area
	local total = was + area
	if was <= 1e-6 then
		c.Cu, c.Cv = u, v
		if skidRot and asp and asp > 1.03 then
			c.Rot = skidRot
			c.Asp = math.min(asp, 2)
		end
	else
		c.Cu = (c.Cu * was + u * area) / total
		c.Cv = (c.Cv * was + v * area) / total
	end
	c.Area = total
	c.From = c.R
	c.GrowAt = now
	c.Fresh = math.max(c.Fresh, f)
	if f + LIFE - FADE > c.Expire then
		c.Expire = f + LIFE - FADE
		c.FadeLen = FADE
	end
	active[c] = true
	if c.Floor then
		GROUND.Dirty = true
	else
		c.Sheet.Dirty = true
	end
	if total > retainOf(c) + 0.002 then
		c.Flowing = true
		flowing[c] = true
	end
end

local function pourGround(x: number, z: number, y: number, area: number, now: number, fresh: number?, hit: RaycastResult?, skidRot: number?, asp: number?): Cell?
	local c = groundCellAt(math.floor(x / CELL), math.floor(z / CELL), x, z, y, hit, fresh)
	if c then
		fill(c, x, z, area, now, fresh, skidRot, asp)
	end
	return c
end

local function pourWall(s: any, u: number, v: number, area: number, now: number, fresh: number?, flow: boolean?): Cell?
	local c = wallCellAt(s, math.floor(u / CELL), math.floor(v / CELL), u, v, flow, fresh)
	if c then
		fill(c, u, v, area, now, fresh)
	end
	return c
end

---------------------------------------------------------------------------
-- specks: the fine spray a fast splat flings ahead of itself (small, never part of a pool)
---------------------------------------------------------------------------
type Speck = { Part: Part, Born: number }
local specks: { Speck } = {}
local function speck(cf: CFrame, size: number, stretch: number, now: number)
	local sp: Speck
	if #specks >= MAX_SPECKS then
		sp = table.remove(specks, 1) :: Speck
	else
		sp = { Part = takePart(), Born = now }
	end
	sp.Born = now
	table.insert(specks, sp)
	local p = sp.Part
	p.Color = BODY_COLOR
	p.Size = Vector3.new(THICK, size * stretch, size)
	table.insert(moveParts, p)
	table.insert(moveCfs, cf)
end

---------------------------------------------------------------------------
-- where a piece of a cell lies
---------------------------------------------------------------------------
-- a piece at (u, v) of cell c, `h` over its surface, turned by rot, and how much bigger it has to be to
-- cover its cell on a slope (the ground's grid is laid out flat, the ground under it tilts)
local function pieceCF(c: Cell, u: number, v: number, h: number, rot: number): (CFrame, number)
	if not c.Floor then
		return c.Sheet.Basis * CFrame.new(h, u, v) * CFrame.Angles(rot, 0, 0), 1
	end
	local n = c.N
	local ux = Vector3.new(1, -n.X / n.Y, 0).Unit -- (the world's X, lying on the surface)
	local vz = n:Cross(ux)
	local p = Vector3.new(u, planeY(c, u, v), v) + n * h
	return CFrame.fromMatrix(p, n, ux, vz) * CFrame.Angles(rot, 0, 0), 1 / math.sqrt(math.max(n.Y, FLOOR_Y))
end

---------------------------------------------------------------------------
-- the stepper: growing cells, running blood, drinking in, soaking away
---------------------------------------------------------------------------
local stepConn: RBXScriptConnection? = nil
local step: (number) -> ()
local function wake()
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
end

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }

-- a cell is at the edge unless all 8 cells round it hold blood (then its rim is hidden anyway)
local function isEdge(c: Cell): boolean
	return c.Nbs < 8
end

-- where a cell's piece sits and its shape: at the centre of its blood while it holds a little, pulled to
-- the middle of its cell as it fills (a full cell covers its square); round when surrounded (no gap can
-- open inside a pool), its own ellipse at the edge - and on a wall stretched down its run
local function shapeOf(c: Cell): (number, number, number, number, number)
	local f = math.max(fullness(c), inside(c))
	local w = if c.Solid then f * f else 0
	local cu = (c.I + 0.5) * CELL
	local cv = (c.J + 0.5) * CELL
	local u = c.Cu + (cu - c.Cu) * w
	local v = c.Cv + (cv - c.Cv) * w
	local lim = CELL * 0.5
	u = math.clamp(u, cu - lim, cu + lim)
	v = math.clamp(v, cv - lim, cv + lim)
	local asp, rot = c.Asp, c.Rot
	if not c.Floor and (c.Sheet.Du ~= 0 or c.Sheet.Dv ~= 0) then
		rot = math.atan2(c.Sheet.Dv, c.Sheet.Du)
		asp = 1.8
	end
	if not c.Edge then
		asp = 1
	elseif f > 0.6 then
		asp = 1 + (asp - 1) * (1 - (f - 0.6) / 0.4 * 0.7)
	end
	return u, v, asp, rot, f
end

local function draw(c: Cell, now: number, slow: number)
	local target = radiusOf(c)
	local k = math.clamp((now - c.GrowAt) * slow / SPLASH, 0, 1)
	local r = c.From + (target - c.From) * (if k >= 1 then 1 else backOut(k))
	c.R = r
	if k >= 1 then
		active[c] = nil
	end
	local rr = r * c.Scale
	c.DrawnR = rr
	if rr < 0.004 then
		if c.Body then
			park(c.Body)
			c.Body = nil
		end
		if c.Rim then
			park(c.Rim)
			c.Rim = nil
		end
		return
	end
	local u, v, asp, rot, f = shapeOf(c)
	local body = c.Body
	if not body then
		body = takePart()
		body.Color = BODY_COLOR
		c.Body = body
	end
	local cf, k2 = pieceCF(c, u, v, BODY_H, rot)
	local a, b = 2 * rr * asp * k2, 2 * rr / asp * k2
	body.Size = Vector3.new(THICK, a, b)
	table.insert(moveParts, body)
	table.insert(moveCfs, cf)
	if c.Edge then
		-- the clotting edge: a little bigger, darker, under the body (only the outside of the whole shape)
		local rimW = 0.022 + 0.022 * f
		local rim = c.Rim
		if not rim then
			rim = takePart()
			rim.Color = RIM_COLOR
			c.Rim = rim
		end
		rim.Size = Vector3.new(THICK, a + rimW * 2, b + rimW * 2)
		table.insert(moveParts, rim)
		table.insert(moveCfs, (pieceCF(c, u, v, RIM_H, rot)))
	elseif c.Rim then
		park(c.Rim)
		c.Rim = nil
	end
end

-- the pools of a surface: cells joined edge to edge (or corner to corner) are one pool, with one clock
local function clusterAll(owner: any, cells: { Cell })
	owner.Dirty = false
	local seen: { [Cell]: boolean } = {}
	local list = {}
	for _, c in ipairs(cells) do
		if not seen[c] then
			local cl = { Cells = {}, Fresh = -math.huge, Expire = -math.huge, FadeLen = FADE, MaxArea = 0 }
			local queue = { c }
			seen[c] = true
			local qi = 1
			while queue[qi] do
				local x = queue[qi]
				qi += 1
				table.insert(cl.Cells, x)
				x.Cluster = cl
				cl.Fresh = math.max(cl.Fresh, x.Fresh)
				if x.Expire > cl.Expire then
					cl.Expire = x.Expire
					cl.FadeLen = x.FadeLen
				end
				cl.MaxArea = math.max(cl.MaxArea, x.Area)
				local nbs = 0
				for _, d in ipairs(DIRS) do
					local n = neighbour(x, d[1], d[2])
					if n then
						nbs += 1
						if not seen[n] then
							seen[n] = true
							table.insert(queue, n)
						end
					end
				end
				if nbs ~= x.Nbs then
					-- (surrounded now, or not any more: it grows to cover its square, or back to its blood)
					x.Nbs = nbs
					x.From = x.R
					x.GrowAt = os.clock()
					active[x] = true
				end
			end
			table.insert(list, cl)
		end
	end
	owner.Clusters = list
	-- (every cell of a pool on its clock at once; a cell's edge / interior looked at again - its rim hides
	-- once it is surrounded)
	local now = os.clock()
	for _, cl in ipairs(list) do
		for _, x in ipairs(cl.Cells) do
			x.Expire = cl.Expire
			x.FadeLen = cl.FadeLen
			if x.Scale < 1 and now < cl.Expire then
				-- (fresh blood poured into a pool that was soaking away: all of it is back)
				x.Scale = 1
				active[x] = true
			end
			local e = isEdge(x)
			if e ~= x.Edge then
				x.Edge = e
				active[x] = true
				if x.GrowAt + SPLASH < now then
					x.From = radiusOf(x)
					x.GrowAt = now - SPLASH
				end
			end
		end
	end
end
local function groundCells(): { Cell }
	local out = {}
	for _, col in pairs(GROUND.Cols) do
		for _, c in ipairs(col) do
			table.insert(out, c)
		end
	end
	return out
end
local function wallCells(s: any): { Cell }
	local out = {}
	for _, c in pairs(s.Cells) do
		table.insert(out, c)
	end
	return out
end

-- THE GROUND'S NEIGHBOURS, sampled once per cell and direction (the world round a pool doesn't move):
--   "Open"   ground within STEP, nothing in the way: blood can run there (Crack: with a crack or a
--            gap between the two - most of what crosses it drains in)
--   "Spill"  nothing under it within STEP (a ledge, a gap, a hole, water): blood reaching it pours over
--   "Wall"   something solid in the way (a wall, a step up, a bump in the ground it can't get past)
local function around(c: Cell, dir: number): any
	local a = c.Around[dir]
	if a then
		return a
	end
	local d = DIRS[dir]
	local x, z = (c.I + d[1] + 0.5) * CELL, (c.J + d[2] + 0.5) * CELL
	local fromX, fromZ = (c.I + 0.5) * CELL, (c.J + 0.5) * CELL
	local fromY = planeY(c, fromX, fromZ)
	local nearY = planeY(c, x, z)
	local hit = groundAt(x, z, nearY)
	local toY = if hit then hit.Position.Y else nearY
	-- in the way? (just over the surface, from this cell's middle to the other's)
	local from = Vector3.new(fromX, fromY + 0.12, fromZ)
	local to = Vector3.new(x, toY + 0.12, z)
	if env.Cast(from, to - from) then
		a = { Kind = "Wall" }
	elseif not hit then
		a = { Kind = "Spill", X = fromX + d[1] * CELL * 0.55, Z = fromZ + d[2] * CELL * 0.55, Y = fromY }
	else
		a = { Kind = "Open", X = x, Z = z, Y = hit.Position.Y, Hit = hit, Crack = false }
		-- a crack or a gap along the way between the two (a straight step only: the seam half way)
		if d[1] == 0 or d[2] == 0 then
			local mx, mz = (fromX + x) * 0.5, (fromZ + z) * 0.5
			if not groundAt(mx, mz, (fromY + hit.Position.Y) * 0.5) then
				a.Crack = true
				a.CX, a.CZ, a.CY = mx, mz, (fromY + hit.Position.Y) * 0.5
			end
		end
	end
	c.Around[dir] = a
	return a
end

-- blood gathering at an edge drips over it once there is a drop's worth (it falls to whatever is
-- below, and pools there)
local DRIP_SIZE = 0.09
local DRIP_AREA = SPOT * DRIP_SIZE ^ 3
local function spill(c: Cell, dir: number, area: number, x: number, z: number, y: number)
	local acc = (c.Spill[dir] or 0) + area
	local d = DIRS[dir]
	while acc >= DRIP_AREA do
		acc -= DRIP_AREA
		local out = Vector3.new(d[1], 0, d[2]).Unit
		env.Drip(Vector3.new(x + rand(-0.12, 0.12) * (1 - math.abs(d[1])), y - 0.06, z + rand(-0.12, 0.12) * (1 - math.abs(d[2]))), out * rand(0.3, 1.1) + Vector3.new(0, -rand(0.5, 1.5), 0), DRIP_SIZE * rand(0.85, 1.15))
	end
	c.Spill[dir] = acc
end

-- BLOOD RUNNING ON THE GROUND: a cell holding more than its film hands the rest on, each way by how
-- much lower the blood's level is there (the ground's height plus the blood on it) - downhill, into
-- dips, out from a pool's deep middle to its thin edge; unevenly (a stable share per cell and way), so
-- a pool grows in lobes. Over an edge it pours off; across a crack most of it drains in
local function flowGround(c: Cell, dt: number, now: number)
	local keep = retainOf(c)
	local avail = c.Area - keep
	if avail <= 0.002 or now >= c.Expire then
		c.Flowing = false
		flowing[c] = nil
		return
	end
	local L = levelOf(c)
	local ws, drops = {}, {}
	local total, steepest = 0, 0
	for dir, d in ipairs(DIRS) do
		local a = around(c, dir)
		local dist = if dir > 4 then CELL * 1.4142 else CELL
		local noise = 0.45 + 1.1 * hash(c.I * 3 + d[1], c.J * 3 + d[2], 7)
		local w, drop = 0, 0
		if a.Kind == "Spill" then
			drop = DEPTH * 3 + 0.25
			w = noise * drop / dist
		elseif a.Kind == "Open" then
			local nb = groundCell(c.I + d[1], c.J + d[2], a.Y)
			local nl = if nb then levelOf(nb) else a.Y
			drop = L - nl
			if drop > 0.002 then
				w = noise * drop / dist
			end
		end
		if dir > 4 then
			w *= 0.55
		end
		ws[dir] = w
		drops[dir] = drop
		total += w
		steepest = math.max(steepest, drop)
	end
	if total <= 1e-6 then
		-- (a hollow full to its brim with nowhere lower to go: it stays deep)
		c.Flowing = false
		flowing[c] = nil
		return
	end
	local rate = P.FlowRate * c.Spread * math.clamp(steepest / DEPTH, 0.2, 4)
	local q = avail * (1 - math.exp(-rate * dt))
	if q < 0.0006 then
		return
	end
	local moved = 0
	for dir, w in ipairs(ws) do
		if w > 0 then
			local share = q * w / total
			local a = c.Around[dir]
			if a.Kind == "Spill" then
				spill(c, dir, share, a.X, a.Z, a.Y)
				moved += share
			else
				-- (on the flat, never so much that the other side ends up higher than this one)
				local nb = groundCell(c.I + DIRS[dir][1], c.J + DIRS[dir][2], a.Y)
				if nb and drops[dir] < DEPTH * 4 then
					share = math.min(share, drops[dir] * CAP / DEPTH * 0.45)
				end
				if a.Crack then
					-- most of it drains into the crack; the rest gets across
					local down = share * 0.65
					spill(c, dir, down, a.CX, a.CZ, a.CY)
					moved += down
					share -= down
				end
				-- poured in at the shared edge, so the other cell grows out of this one's side
				local ex = (c.I + 0.5 + DIRS[dir][1] * 0.55) * CELL
				local ez = (c.J + 0.5 + DIRS[dir][2] * 0.55) * CELL
				local got = pourGround(ex, ez, a.Y, share, now, c.Fresh, a.Hit)
				if got then
					moved += share
				end
			end
		end
	end
	c.Area -= moved
	c.From = c.R
	c.GrowAt = now - SPLASH * 0.5
	active[c] = true
end

-- BLOOD RUNNING DOWN A WALL: straight down (now and then wandering a cell to one side), leaving a thin
-- trail; at the wall's foot it drips off
local function flowWall(c: Cell, dt: number, now: number)
	local s = c.Sheet
	local extra = c.Area - retainOf(c)
	if extra <= 0.002 or now >= c.Expire then
		c.Flowing = false
		flowing[c] = nil
		return
	end
	local move = extra * (1 - math.exp(-P.RunRate * dt))
	if move < 0.0008 then
		return
	end
	local ws, total = {}, 0
	for n, d in ipairs(DIRS) do
		local du, dv = d[1], d[2]
		local len = if n > 4 then 1.4142 else 1
		local down = (du * s.Du + dv * s.Dv) / len
		local w = 0
		if down > 0.9 then
			w = 1
		elseif down > 0.6 and hash(c.I * 5 + du, c.J * 5 + dv, 11) > 0.82 then
			w = 0.35
		end
		if w > 0 and s.Blocked[keyOf(c.I + du, c.J + dv)] then
			w = 0
		end
		ws[n] = w
		total += w
	end
	if total <= 1e-6 then
		c.Flowing = false
		flowing[c] = nil
		return
	end
	c.Area -= move
	local su, sv = c.Cu, c.Cv
	local fell = 0
	for n, d in ipairs(DIRS) do
		local w = ws[n]
		if w > 0 then
			local share = move * w / total
			local eu = (c.I + 0.5 + d[1] * 0.55) * CELL
			local ev = (c.J + 0.5 + d[2] * 0.55) * CELL
			local nb = pourWall(s, eu + (su - (c.I + 0.5) * CELL) * 0.3, ev + (sv - (c.J + 0.5) * CELL) * 0.3, share, now, c.Fresh, true)
			if nb then
				nb.Rot = math.atan2(s.Dv, s.Du) -- (a run's head is its own drop, stretched down the wall)
			else
				fell += share -- (the wall's foot, or its edge: it drips off)
			end
		end
	end
	if fell > 0 then
		c.Spill[1] = (c.Spill[1] or 0) + fell
		while c.Spill[1] >= DRIP_AREA do
			c.Spill[1] -= DRIP_AREA
			local p = wallPoint(s, c.Cu, c.Cv, 0.08)
			env.Drip(p + Vector3.new(0, -CELL * 0.4, 0), s.N * 0.3 + Vector3.new(0, -2, 0), DRIP_SIZE)
		end
	end
	c.From = c.R
	c.GrowAt = now - SPLASH * 0.5
	active[c] = true
end

local beatAt = 0
local flowAt = 0
local forcedUntil = 0
local function allOwners(): { any }
	local out = { GROUND }
	for _, s in ipairs(sheets) do
		table.insert(out, s)
	end
	return out
end

function step(_dt: number)
	local now = os.clock()
	local slow = env.TimeScale()
	-- blood running (10 Hz)
	if now >= flowAt and next(flowing) ~= nil then
		local h = math.min(now - (flowAt - 0.1), 0.2) * slow
		flowAt = now + 0.1
		local list = {}
		for c in pairs(flowing) do
			table.insert(list, c)
		end
		-- (the highest first: blood coming down a slope reaches the cells below it in the same step)
		table.sort(list, function(a, b)
			return (if a.Floor then a.Y else 0) > (if b.Floor then b.Y else 0)
		end)
		for _, c in ipairs(list) do
			if alive(c) then
				if c.Floor then
					flowGround(c, h, now)
				else
					flowWall(c, h, now)
				end
			else
				flowing[c] = nil
			end
		end
	end
	-- the pools: joined up again where they changed, a porous ground drinking in, and the oldest
	-- soaking away early when there is too much lying about (5 Hz)
	local beat = now >= beatAt
	if beat then
		local bh = math.min(now - (beatAt - 0.2), 0.5) * slow
		beatAt = now + 0.2
		if GROUND.Dirty then
			clusterAll(GROUND, groundCells())
		end
		for _, s in ipairs(sheets) do
			if s.Dirty then
				clusterAll(s, wallCells(s))
			end
		end
		for _, col in pairs(GROUND.Cols) do
			for _, c in ipairs(col) do
				if c.Absorb > 0 then
					c.Area *= math.exp(-c.Absorb * bh)
					local r = radiusOf(c) * c.Scale
					if c.Area < 0.004 then
						c.Expire, c.FadeLen = math.min(c.Expire, now), QUICK
					elseif math.abs(r - c.DrawnR) > c.DrawnR * 0.04 + 0.002 and not active[c] then
						c.From, c.GrowAt = r, now - SPLASH
						active[c] = true
					end
				end
			end
		end
		if cellCount > MAX_CELLS * 0.92 and now >= forcedUntil then
			local oldest: any = nil
			for _, o in ipairs(allOwners()) do
				for _, cl in ipairs(o.Clusters) do
					if cl.Expire > now and (oldest == nil or cl.Fresh < oldest.Fresh) then
						oldest = cl
					end
				end
			end
			if oldest then
				forcedUntil = now + QUICK
				oldest.Expire = now
				oldest.FadeLen = QUICK
				for _, c in ipairs(oldest.Cells) do
					c.Expire, c.FadeLen = now, QUICK
				end
			end
		end
	end
	-- soaking away: the thin edges go first, the thick middle last (a cell drunk dry goes at once)
	for _, o in ipairs(allOwners()) do
		for _, cl in ipairs(o.Clusters) do
			local any = false
			for _, c in ipairs(cl.Cells) do
				if now >= c.Expire and alive(c) then
					any = true
					local k = math.clamp((now - c.Expire) * slow / c.FadeLen, 0, 1)
					local q = 0.3 + 0.7 * math.sqrt(c.Area / math.max(cl.MaxArea, 1e-6))
					local sc = math.clamp((q - k) / 0.3, 0, 1)
					if sc <= 0 or c.Area < 0.004 and k >= 1 then
						removeCell(c)
					elseif math.abs(sc - c.Scale) > 0.01 then
						c.Scale = sc
						active[c] = true
					end
				end
			end
			if not any and now >= cl.Expire + cl.FadeLen then
				cl.Cells = {}
			end
		end
	end
	for si = #sheets, 1, -1 do
		if sheets[si].Count == 0 then
			table.remove(sheets, si)
		end
	end
	-- a speck soaks away with the blood round it (shrinking, then gone)
	for i = #specks, 1, -1 do
		local sp = specks[i]
		local life = (now - sp.Born) * slow
		if life > LIFE * 0.8 then
			local k = math.clamp((life - LIFE * 0.8) / 1.2, 0, 1)
			if k >= 1 then
				park(sp.Part)
				table.remove(specks, i)
			else
				local p = sp.Part
				p.Size = Vector3.new(THICK, math.max(p.Size.Y * 0.9, 0.001), math.max(p.Size.Z * 0.9, 0.001))
			end
		end
	end
	for c in pairs(active) do
		if alive(c) then
			draw(c, now, slow)
		else
			active[c] = nil
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCfs)
	end
	if cellCount == 0 and #specks == 0 and stepConn then
		stepConn:Disconnect()
		stepConn = nil
		table.clear(sheets)
		GROUND.Clusters = {}
		-- (the fight is over: only a reserve of spare pieces is kept)
		while #free > P.Spare do
			local p = table.remove(free) :: Part
			p:Destroy()
			partCount -= 1
		end
	end
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------
-- a drop of `size` hit `hit` flying at `vel` (k: how much blood it carried, 1 = its own volume)
function Pools.Deposit(hit: RaycastResult, size: number, vel: Vector3, k: number?): boolean
	if not holds(hit) or not env.InView(hit.Position) then
		return false
	end
	local n = hit.Normal
	local now = os.clock()
	local area = SPOT * size * size * size * (k or 1)
	if n.Y < -0.5 then
		-- under a ceiling: it gathers and falls again
		if math.random() < 0.55 then
			local p = hit.Position + n * 0.08
			task.delay(rand(0.25, 0.9), function()
				env.Drip(p, Vector3.new(0, -1, 0), math.max(0.05, size * 0.8))
			end)
		end
		return false
	end
	local along = vel - n * vel:Dot(n)
	local sk = along.Magnitude
	if n.Y < FLOOR_Y then
		if hit.Instance:IsA("Terrain") or n.Y >= 1 - WALL_SLOPE then
			-- a hillside too steep to hold it: it trickles on down the slope
			local g = Vector3.new(0, -1, 0)
			local down = g - n * n:Dot(g)
			down = if down.Magnitude > 1e-3 then down.Unit else g
			env.Drip(hit.Position + n * 0.1, down * rand(4, 7) + along * 0.3, math.max(0.05, size * 0.85))
			return true
		end
		-- a wall: its thin run down
		local s = sheetFor(n, hit.Position:Dot(n))
		local rel = hit.Position - s.Basis.Position
		local c = pourWall(s, rel:Dot(s.U), rel:Dot(s.V), area, now)
		if c then
			wake()
		end
		return c ~= nil
	end
	-- THE GROUND. A drop coming in at a slant leaves an ellipse (long / wide = 1 / sin of the angle it
	-- came in at, as real spatter does), and a fast one skids on and smears a tail the way it was going
	local x, z, y = hit.Position.X, hit.Position.Z, hit.Position.Y
	local rot, skid, asp = 0, 0, 1
	local dx, dz = 0, 0
	if sk > 1 then
		local d = along / sk
		local h = Vector3.new(d.X, 0, d.Z)
		if h.Magnitude > 1e-3 then
			h = h.Unit
			dx, dz = h.X, h.Z
		end
		rot = math.atan2(-dz, dx) -- (the piece's frame: its V runs the world's -Z)
		skid = math.clamp(sk / 30, 0, 1)
		asp = math.sqrt(math.clamp(vel.Magnitude / math.max(math.abs(vel:Dot(n)), 1e-3), 1, 4))
	end
	local len = math.clamp(sk * 0.028, 0, 1.1)
	local first = pourGround(x, z, y, area * (if len > 0.1 then 0.6 else 1), now, nil, hit, rot, asp)
	if not first then
		return false
	end
	if len > 0.1 then
		-- (the tail of the smear thins out, following the ground)
		local x1, z1 = x + dx * len * 0.5, z + dz * len * 0.5
		pourGround(x1, z1, planeY(first, x1, z1), area * 0.27, now, nil, nil, rot, 1 + (asp - 1) * 0.7)
		local x2, z2 = x + dx * len, z + dz * len
		pourGround(x2, z2, planeY(first, x2, z2), area * 0.13, now, nil, nil, rot, 1 + (asp - 1) * 0.5)
	end
	-- a fast one flings specks: thin spikes ahead of it, dots round it (each on the ground it lands on)
	local speed = vel.Magnitude
	if speed > 9 then
		local count = math.min(5, math.floor((speed - 7) / 6 + math.random() * 1.6))
		local r = math.sqrt(area * GROW / math.pi)
		local ahead = math.atan2(dz, dx)
		for _ = 1, count do
			local off = if sk > 1 then rand(-0.9, 0.9) * (1.1 - skid * 0.8) else rand(-math.pi, math.pi)
			local a = ahead + off
			local dist = r * rand(1.2, 2.3) + len * rand(0.3, 0.9)
			local sx, sz = x + math.cos(a) * dist, z + math.sin(a) * dist
			local g = groundAt(sx, sz, planeY(first, sx, sz))
			if g then
				local sz0 = size * rand(0.35, 0.8)
				local gn = g.Normal
				local ux = Vector3.new(1, -gn.X / gn.Y, 0).Unit
				speck(CFrame.fromMatrix(g.Position + gn * SPECK_H, gn, ux, gn:Cross(ux)) * CFrame.Angles(-a, 0, 0), sz0, 1 + skid * rand(0.5, 2.2), now)
			end
		end
	end
	wake()
	return true
end

-- blood poured straight onto the surface a ray found (a torn limb landing, a body falling in its own
-- blood): `area` studs² spread over a patch `spread` studs across
function Pools.Pour(hit: RaycastResult, area: number, spread: number?)
	if not holds(hit) or not env.InView(hit.Position) or hit.Normal.Y < FLOOR_Y then
		return
	end
	local now = os.clock()
	local p = hit.Position
	local w = spread or 0.4
	local parts = math.clamp(math.floor(area / 0.08) + 1, 1, 5)
	for i = 1, parts do
		local a = rand(0, math.pi * 2)
		local d = if i == 1 then 0 else w * math.sqrt(math.random())
		pourGround(p.X + math.cos(a) * d, p.Z + math.sin(a) * d, p.Y, area / parts, now, nil, if i == 1 then hit else nil)
	end
	wake()
end

-- (tests: the ground's cells and the walls)
function Pools.Debug(): any
	return { Ground = groundCells(), Walls = sheets, Clusters = #GROUND.Clusters }
end

-- (Studio / tests: how much is lying about)
function Pools.Stats(): { Cells: number, Walls: number, Specks: number, Parts: number }
	return { Cells = cellCount, Walls = #sheets, Specks = #specks, Parts = partCount }
end

return Pools
