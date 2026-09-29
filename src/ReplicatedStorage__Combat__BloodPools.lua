--[[
	BloodPools  (ReplicatedStorage.Combat.BloodPools)
	The blood on the ground and on the walls - client-side and cosmetic (CombatBlood's drops land
	here). Blood on a surface is ONE LIQUID, not a pile of stains: every flat surface the blood
	reaches gets a SHEET - a fine grid (Config.Blood.Pool.Cell studs) laid on that plane - and every
	drop that lands pours its volume into the cells it lands and skids across. What is drawn is the
	liquid in those cells:

	  * a cell with a little blood in it is a small spot exactly where the drops fell (the cell keeps
	    the centre of everything poured into it), shaped by how the first drop skidded
	  * a cell that fills up runs over into its neighbours - on the flat a little each way (an uneven
	    share, so the edge grows in lobes, never a circle), on a slope mostly downhill, and on a wall
	    straight down: a run that leaves a thin trail and, at the wall's foot, drips off
	  * cells side by side are drawn as one surface: every body piece of every cell lies in the same
	    layer over its plane and is opaque, so where two meet there is no seam, no darker overlap and
	    nothing stacked - a pool that reaches another one simply becomes one bigger pool. Only the
	    outer edge of the whole shape shows the thin, darker clotting rim (a rim is drawn only on a
	    cell at the edge, under the bodies)
	  * a pool deep enough in the middle gets a wet sheen there, which dulls as it dries
	  * everything joined together dries on ONE clock (the freshest blood in it): fresh blood poured
	    into an old stain wets the whole of it again. It darkens, loses its sheen, and at the end of its
	    life soaks away from its thin edges inward (the thick middle goes last)

	Blood never lands on water, a fighter, anything see-through or non-colliding, or anything that
	moves (a loose part would carry a floating stain away). Under a ceiling it gathers into a drop
	that falls. A cell is only ever laid where there is real surface under it (never hanging over a
	ledge, never through a wall). Fast drops also fling specks ahead of their splat.

	Cheap: the parts are pooled and reused, a cell is redrawn only while it grows, runs or soaks
	away, drying recolours at 5 Hz and only when the shade really changes, the flow runs at 10 Hz and
	only where blood is running. Budgets (Config.Blood.Pool: MaxCells, MaxSpecks, MaxGloss) cap it:
	past them the oldest pool soaks away early.

	  Pools.Init(env)                     env = { Holder, Cast, Drip, InView, TimeScale } (CombatBlood)
	  Pools.Deposit(hit, size, vel, k?)   a drop of `size` met `hit` at `vel` (k: volume multiplier)
	  Pools.Pour(hit, area, spread?)      blood poured straight onto the surface a ray found (a limb
	                                      landing, a bleeding body hitting the floor)
	  Pools.Clear()                       everything gone at once
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Pools = {}

local P = Config.Blood.Pool
local CELL = P.Cell
local CAP = CELL * CELL -- the area a cell holds before it runs over
local SPOT = P.Spot -- studs² a drop of size s covers: SPOT * s³
local GROW = 2.1 -- a cell's piece covers this much more than its area (full cells overlap: one surface)
local LIFE, FADE, QUICK = P.Life, P.Fade, 0.9
local PARK = CFrame.new(0, -5000, 0)
local SPLASH = 0.2 -- seconds a cell takes to spread out to its new size (with a little overshoot)
-- the budgets (Init scales them to the device: CombatBlood)
local MAX_CELLS, MAX_SPECKS, MAX_GLOSS = P.MaxCells, P.MaxSpecks, P.MaxGloss

-- every piece of a kind in the same layer over its plane, whatever pool it belongs to (so bodies that
-- meet are one surface and a rim only shows round the outside), and thin enough that its top is flat
local RIM_H, SPECK_H, BODY_H, GLOSS_H = 0.010, 0.014, 0.020, 0.026
local THICK = 0.006
local GLOSS_SHINE = 0.07

-- a floor (up to ~26 deg), a slope, a wall (from ~50 deg), a ceiling (facing down)
local FLOOR_SLOPE, WALL_SLOPE = 0.45, 0.77

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
	MAX_GLOSS = math.floor(P.MaxGloss * b)
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
	p.Reflectance = 0
	table.insert(moveParts, p)
	table.insert(moveCfs, PARK)
	table.insert(free, p)
end

---------------------------------------------------------------------------
-- sheets and cells
---------------------------------------------------------------------------
type Cell = {
	Sheet: any,
	I: number,
	J: number,
	Key: number,
	Area: number,
	Cu: number, -- the centre of everything poured in (sheet studs)
	Cv: number,
	Rot: number,
	Asp: number, -- 1 = round; >1 stretched along Rot
	Fresh: number,
	Expire: number, -- when it starts to soak away
	FadeLen: number,
	GrowAt: number,
	From: number, -- the radius it grew from (GrowAt)
	R: number, -- radius drawn now
	Scale: number, -- 1, less while soaking away
	Edge: boolean, -- at the pool's edge (has a rim)
	Body: Part?,
	Rim: Part?,
	Gloss: Part?,
	Cluster: any,
	Flowing: boolean,
	Solid: boolean, -- surface under the cell's middle (not: a cell at a ledge's edge - it stays small)
	Drawn: boolean,
}
type Sheet = {
	N: Vector3,
	Plane: number,
	U: Vector3,
	V: Vector3,
	Basis: CFrame,
	Slope: number,
	Du: number, -- downhill, in the sheet (unit, or 0 on the flat)
	Dv: number,
	Wall: boolean,
	Cells: { [number]: Cell },
	Count: number,
	Blocked: { [number]: boolean }, -- cells with no surface under them (a ledge, a gap)
	Dirty: boolean,
	Clusters: { any },
}
local sheets: { Sheet } = {}
local cellCount = 0
local active: { [Cell]: boolean } = {} -- cells being redrawn every frame (growing)
local flowing: { [Cell]: boolean } = {}

local function keyOf(i: number, j: number): number
	return (i + 65536) * 262144 + (j + 65536)
end

local function sheetFor(n: Vector3, plane: number): Sheet
	for _, s in ipairs(sheets) do
		if s.N:Dot(n) > 0.9995 and math.abs(s.Plane - plane) < 0.012 then
			return s
		end
	end
	-- a floor's grid is the world's own (X, Z), so every floor at one height shares one grid
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
	local slope = gt.Magnitude
	local du, dv = 0, 0
	if slope > 0.05 then
		local d = gt.Unit
		du, dv = d:Dot(u), d:Dot(v)
	end
	local s: Sheet = {
		N = n,
		Plane = plane,
		U = u,
		V = v,
		Basis = CFrame.fromMatrix(n * plane, n, u, v),
		Slope = slope,
		Du = du,
		Dv = dv,
		Wall = slope >= WALL_SLOPE,
		Cells = {},
		Count = 0,
		Blocked = {},
		Dirty = false,
		Clusters = {},
	}
	table.insert(sheets, s)
	return s
end

local function coords(s: Sheet, p: Vector3): (number, number)
	local rel = p - s.Basis.Position
	return rel:Dot(s.U), rel:Dot(s.V)
end

local function worldAt(s: Sheet, u: number, v: number, h: number): Vector3
	return s.Basis.Position + s.U * u + s.V * v + s.N * h
end

-- solid surface of this very plane under (u, v)? (never over a ledge, never inside a wall)
local function surfaceAt(s: Sheet, u: number, v: number): boolean
	local p = worldAt(s, u, v, 0)
	local hit = env.Cast(p + s.N * 0.3, s.N * -0.55)
	if not hit then
		return false
	end
	if hit.Normal:Dot(s.N) < 0.9 or math.abs(hit.Position:Dot(s.N) - s.Plane) > 0.05 then
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

-- the cell at (i, j), made if it may be: the budget, and surface where the blood goes in (pu, pv).
-- A cell with no surface under its middle (at a ledge's edge) is kept small and never pulled over the
-- edge; blood running over from a neighbour (flow) only goes where there is surface under the middle
local function cellAt(s: Sheet, i: number, j: number, make: boolean, pu: number?, pv: number?, flow: boolean?): Cell?
	local key = keyOf(i, j)
	local c = s.Cells[key]
	if c or not make then
		return c
	end
	if cellCount >= MAX_CELLS or (flow and s.Blocked[key]) then
		return nil
	end
	local cu, cv = (i + 0.5) * CELL, (j + 0.5) * CELL
	local solid = surfaceAt(s, cu, cv)
	if flow and not solid then
		s.Blocked[key] = true
		return nil
	elseif not solid and not (pu and pv and surfaceAt(s, pu, pv)) then
		return nil
	end
	local now = os.clock()
	local nc: Cell = {
		Sheet = s,
		I = i,
		J = j,
		Key = key,
		Area = 0,
		Cu = pu or cu,
		Cv = pv or cv,
		Rot = hash(i, j, 1) * math.pi * 2,
		Asp = 1 + hash(i, j, 2) * 0.35,
		Fresh = now,
		Expire = now + LIFE - FADE,
		FadeLen = FADE,
		GrowAt = now,
		From = 0,
		R = 0,
		Scale = 1,
		Edge = true,
		Body = nil,
		Rim = nil,
		Gloss = nil,
		Cluster = nil,
		Flowing = false,
		Solid = solid,
		Drawn = false,
	}
	s.Cells[key] = nc
	s.Count += 1
	s.Dirty = true
	cellCount += 1
	return nc
end

local function removeCell(c: Cell)
	local s = c.Sheet
	if s.Cells[c.Key] ~= c then
		return
	end
	s.Cells[c.Key] = nil
	s.Count -= 1
	s.Dirty = true
	cellCount -= 1
	active[c] = nil
	flowing[c] = nil
	for _, k in ipairs({ "Body", "Rim", "Gloss" }) do
		local p = (c :: any)[k]
		if p then
			park(p)
			;(c :: any)[k] = nil
		end
	end
end

-- how full a cell is (0..1) and the radius its piece is drawn at
local function fullness(c: Cell): number
	return math.min(1, c.Area / CAP)
end
local function radiusOf(c: Cell): number
	return math.sqrt(math.min(c.Area, if c.Solid then CAP else CAP * 0.35) * GROW / math.pi)
end

-- the room a cell has before it runs over: a full cell on the flat, less on a slope, a thin film on
-- a wall (what a run leaves behind it)
local function capOf(s: Sheet, c: Cell?): number
	if c and not c.Solid then
		return CAP * 0.35
	end
	if s.Wall then
		return CAP * P.WallFilm
	end
	return CAP * (1 - 0.7 * math.clamp((s.Slope - FLOOR_SLOPE * 0.4) / (WALL_SLOPE - FLOOR_SLOPE * 0.4), 0, 1))
end

---------------------------------------------------------------------------
-- pouring blood into a sheet
---------------------------------------------------------------------------
-- `area` studs² into the cell under (u, v); the first pour into a cell shapes it (a skid stretches it).
-- fresh: the blood's own clock (blood running over from a neighbour keeps that neighbour's); flow: it
-- ran over from a neighbour (only onto surface)
local function pour(s: Sheet, u: number, v: number, area: number, now: number, fresh: number?, skidRot: number?, skid: number?, flow: boolean?): Cell?
	local i, j = math.floor(u / CELL), math.floor(v / CELL)
	local c = cellAt(s, i, j, true, u, v, flow)
	if not c then
		return nil
	end
	local f = fresh or now
	local was = c.Area
	local total = was + area
	if was <= 1e-6 then
		c.Cu, c.Cv = u, v
		if skidRot and skid and skid > 0.05 then
			c.Rot = skidRot
			c.Asp = 1 + math.min(skid, 1) * 0.9
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
	s.Dirty = true
	if total > capOf(s, c) then
		c.Flowing = true
		flowing[c] = true
	end
	return c
end

---------------------------------------------------------------------------
-- specks: the fine spray a fast splat flings ahead of itself (small, never part of a pool)
---------------------------------------------------------------------------
type Speck = { Part: Part, Born: number }
local specks: { Speck } = {}
local function speck(s: Sheet, u: number, v: number, size: number, rot: number, stretch: number, now: number)
	if not surfaceAt(s, u, v) then
		return
	end
	local sp: Speck
	if #specks >= MAX_SPECKS then
		sp = table.remove(specks, 1) :: Speck
	else
		sp = { Part = takePart(), Born = now }
	end
	sp.Born = now
	table.insert(specks, sp)
	local p = sp.Part
	p.Color = P.Fresh
	p.Size = Vector3.new(THICK, size * stretch, size)
	table.insert(moveParts, p)
	table.insert(moveCfs, s.Basis * CFrame.new(SPECK_H, u, v) * CFrame.Angles(rot, 0, 0))
end

---------------------------------------------------------------------------
-- the stepper: growing cells, running blood, drying, soaking away
---------------------------------------------------------------------------
local stepConn: RBXScriptConnection? = nil
local step: (number) -> ()
local function wake()
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(step)
	end
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }

-- a cell is at the edge unless all 8 cells round it are nearly full (then its rim is hidden anyway)
local function isEdge(c: Cell): boolean
	local s = c.Sheet
	if fullness(c) < 0.85 then
		return true
	end
	for _, d in ipairs(NEIGHBOURS) do
		local n = s.Cells[keyOf(c.I + d[1], c.J + d[2])]
		if not n or fullness(n) < 0.7 then
			return true
		end
	end
	return false
end

-- where a cell's piece sits and its shape: at the centre of its blood while it holds a little, pulled to
-- the middle of its cell as it fills (a full cell covers its square); round when surrounded (no gap can
-- open inside a pool), its own ellipse at the edge - and on a wall stretched down its run
local function shapeOf(c: Cell): (number, number, number, number, number)
	local s = c.Sheet
	local f = fullness(c)
	local w = if c.Solid then f * f else 0
	local cu = (c.I + 0.5) * CELL
	local cv = (c.J + 0.5) * CELL
	local u = c.Cu + (cu - c.Cu) * w
	local v = c.Cv + (cv - c.Cv) * w
	local lim = CELL * 0.5
	u = math.clamp(u, cu - lim, cu + lim)
	v = math.clamp(v, cv - lim, cv + lim)
	local asp, rot = c.Asp, c.Rot
	if s.Wall and (s.Du ~= 0 or s.Dv ~= 0) then
		rot = math.atan2(s.Dv, s.Du)
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
	local s = c.Sheet
	local target = radiusOf(c)
	local k = math.clamp((now - c.GrowAt) * slow / SPLASH, 0, 1)
	local r = c.From + (target - c.From) * (if k >= 1 then 1 else backOut(k))
	c.R = r
	if k >= 1 then
		active[c] = nil
	end
	local sc = c.Scale
	local u, v, asp, rot, f = shapeOf(c)
	local rr = r * sc
	if rr < 0.004 then
		if c.Body then
			park(c.Body)
			c.Body = nil
		end
		if c.Rim then
			park(c.Rim)
			c.Rim = nil
		end
		if c.Gloss then
			park(c.Gloss)
			c.Gloss = nil
		end
		return
	end
	local a, b = 2 * rr * asp, 2 * rr / asp
	local cl = c.Cluster
	if not c.Body then
		c.Body = takePart()
		c.Body.Color = if cl then cl.BodyColor else P.Fresh
	end
	local body = c.Body :: Part
	body.Size = Vector3.new(THICK, a, b)
	local cf = s.Basis * CFrame.new(BODY_H, u, v) * CFrame.Angles(rot, 0, 0)
	table.insert(moveParts, body)
	table.insert(moveCfs, cf)
	if c.Edge then
		-- the clotting edge: a little bigger, darker, under the body (only the outside of the whole shape)
		local rimW = 0.022 + 0.022 * f
		if not c.Rim then
			c.Rim = takePart()
			c.Rim.Color = if cl then cl.RimColor else P.Rim
		end
		local rim = c.Rim :: Part
		rim.Size = Vector3.new(THICK, a + rimW * 2, b + rimW * 2)
		table.insert(moveParts, rim)
		table.insert(moveCfs, s.Basis * CFrame.new(RIM_H, u, v) * CFrame.Angles(rot, 0, 0))
	elseif c.Rim then
		park(c.Rim)
		c.Rim = nil
	end
	if c.Gloss then
		local g = c.Gloss :: Part
		-- (every interior cell's sheen joins its neighbours': one wet middle, inset from the edge)
		g.Size = Vector3.new(THICK, a * 0.92, b * 0.92)
		table.insert(moveParts, g)
		table.insert(moveCfs, s.Basis * CFrame.new(GLOSS_H, u, v) * CFrame.Angles(rot, 0, 0))
	end
	c.Drawn = true
end

-- the pools of a sheet: cells joined edge to edge (or corner to corner) are one pool, with one clock
local function clusterSheet(s: Sheet)
	s.Dirty = false
	local seen: { [Cell]: boolean } = {}
	local list = {}
	for _, c in pairs(s.Cells) do
		if not seen[c] then
			local cl = { Cells = {}, Fresh = -math.huge, Expire = -math.huge, FadeLen = FADE, MaxArea = 0, Total = 0, Level = -1, Sheet = s, BodyColor = P.Fresh, RimColor = P.Rim, Dry = 0 }
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
				cl.Total += x.Area
				for _, d in ipairs(NEIGHBOURS) do
					local n = s.Cells[keyOf(x.I + d[1], x.J + d[2])]
					if n and not seen[n] then
						seen[n] = true
						table.insert(queue, n)
					end
				end
			end
			table.insert(list, cl)
		end
	end
	s.Clusters = list
	-- (every cell of a pool on its clock at once: a freshly joined pool is one colour, and a cell's edge
	-- / interior is looked at again - its rim hides once it is surrounded)
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

-- the pool dries: one shade for all of it (and its sheen melts in), written only when the shade moves
local glossCount = 0
local function dryCluster(cl: any, now: number, slow: number)
	local life = (now - cl.Fresh) * slow
	local k = math.clamp((life - 1.2) / (LIFE * 0.6), 0, 1)
	k = k * (2 - k)
	local level = math.floor(k * 40 + 0.5)
	cl.Dry = k
	if level == cl.Level then
		return
	end
	cl.Level = level
	local q = level / 40
	cl.BodyColor = P.Fresh:Lerp(P.Dried, q)
	cl.RimColor = P.Rim:Lerp(P.RimDried, q)
	local gloss = P.Gloss:Lerp(cl.BodyColor, q)
	for _, c in ipairs(cl.Cells) do
		if c.Body then
			c.Body.Color = cl.BodyColor
		end
		if c.Rim then
			c.Rim.Color = cl.RimColor
		end
		if c.Gloss then
			c.Gloss.Color = gloss
			c.Gloss.Reflectance = GLOSS_SHINE * (1 - q)
		end
	end
end

-- the wet sheen over the thick middle of a fresh pool on the floor (a pool's interior cells, while
-- it is wet; the budget goes to the freshest pools first)
local function glossPass(now: number)
	local want: { any } = {}
	for _, s in ipairs(sheets) do
		if s.Slope < FLOOR_SLOPE then
			for _, cl in ipairs(s.Clusters) do
				if cl.Dry < 0.75 and #cl.Cells >= 5 and now < cl.Expire then
					table.insert(want, cl)
				end
			end
		end
	end
	table.sort(want, function(a, b)
		return a.Fresh > b.Fresh
	end)
	local budget = MAX_GLOSS
	local keep: { [Cell]: boolean } = {}
	for _, cl in ipairs(want) do
		for _, c in ipairs(cl.Cells) do
			if budget <= 0 then
				break
			end
			if not c.Edge and c.Body then
				keep[c] = true
				budget -= 1
			end
		end
	end
	glossCount = 0
	for _, s in ipairs(sheets) do
		for _, c in pairs(s.Cells) do
			if keep[c] then
				glossCount += 1
				if not c.Gloss then
					local g = takePart()
					local cl = c.Cluster
					local q = if cl then cl.Level / 40 else 0
					g.Color = P.Gloss:Lerp(if cl then cl.BodyColor else P.Fresh, q)
					g.Reflectance = GLOSS_SHINE * (1 - q)
					c.Gloss = g
					active[c] = true
				end
			elseif c.Gloss then
				park(c.Gloss)
				c.Gloss = nil
			end
		end
	end
end

-- blood running: a cell over its room hands the rest on, a share per neighbour - uneven on the flat
-- (lobes), downhill on a slope, straight down a wall. With nowhere to go (a ledge's edge) a wall run
-- drips off; a floor pool just stays as it is
local function flowCell(c: Cell, dt: number, now: number)
	local s = c.Sheet
	local cap = capOf(s, c)
	local extra = c.Area - cap
	if extra <= 0.002 then
		c.Flowing = false
		flowing[c] = nil
		return
	end
	local rate = if s.Wall then P.RunRate elseif s.Slope > FLOOR_SLOPE then P.RunRate * 0.6 else P.SpreadRate
	local move = extra * (1 - math.exp(-rate * dt))
	if move < 0.0008 then
		return
	end
	local ws, total = {}, 0
	for n, d in ipairs(NEIGHBOURS) do
		local du, dv = d[1], d[2]
		local diag = n > 4
		local len = if diag then 1.4142 else 1
		local down = (du * s.Du + dv * s.Dv) / len
		local w
		if s.Wall then
			-- (straight down; now and then a run wanders a cell to one side, never fans out)
			if down > 0.9 then
				w = 1
			elseif down > 0.6 and hash(c.I * 5 + du, c.J * 5 + dv, 11) > 0.82 then
				w = 0.35
			else
				w = 0
			end
		else
			w = (0.35 + 1.3 * hash(c.I * 3 + du, c.J * 3 + dv, 7)) * (if diag then 0.45 else 1)
			w *= math.max(0.05, 1 + s.Slope * 6 * down)
		end
		if w > 0 then
			local key = keyOf(c.I + du, c.J + dv)
			local nb = s.Cells[key]
			-- (a neighbour already fuller than this one takes nothing on the flat: blood spreads out, it
			-- doesn't pile up)
			if nb and not s.Wall and s.Slope < FLOOR_SLOPE and nb.Area >= c.Area then
				w = 0
			elseif s.Blocked[key] then
				w = 0
			end
		end
		ws[n] = w
		total += w
	end
	if total <= 1e-6 then
		-- nowhere to go: a wall run drips off at its foot; a pool at a ledge stays put
		c.Flowing = false
		flowing[c] = nil
		if s.Wall and extra > 0.004 then
			c.Area -= extra
			local p = worldAt(s, c.Cu, c.Cv, 0.05) + s.N * 0.05
			env.Drip(p, Vector3.new(0, -2, 0), math.clamp((extra / SPOT) ^ (1 / 3), 0.05, 0.16))
			c.GrowAt, c.From = now, c.R
			active[c] = true
		end
		return
	end
	c.Area -= move
	local su, sv = c.Cu, c.Cv
	for n, d in ipairs(NEIGHBOURS) do
		local w = ws[n]
		if w > 0 then
			local share = move * w / total
			-- poured in at the shared edge, so the neighbour grows out of this cell's side
			local eu = (c.I + 0.5 + d[1] * 0.55) * CELL
			local ev = (c.J + 0.5 + d[2] * 0.55) * CELL
			local nb = pour(s, eu + (su - (c.I + 0.5) * CELL) * 0.3, ev + (sv - (c.J + 0.5) * CELL) * 0.3, share, now, c.Fresh, nil, nil, true)
			if not nb then
				c.Area += share -- (it could not go there after all)
			else
				if s.Wall then
					-- a run's head is its own drop, stretched down the wall
					nb.Rot = math.atan2(s.Dv, s.Du)
				end
			end
		end
	end
	c.From = c.R
	c.GrowAt = now - SPLASH * 0.5
	active[c] = true
end

local beatAt = 0
local flowAt = 0
local forcedUntil = 0
function step(dt: number)
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
		for _, c in ipairs(list) do
			if c.Sheet.Cells[c.Key] == c then
				flowCell(c, h, now)
			else
				flowing[c] = nil
			end
		end
	end
	-- the pools: joined up again where they changed, dried, and the old ones soaking away (5 Hz)
	local beat = now >= beatAt
	if beat then
		beatAt = now + 0.2
		for _, s in ipairs(sheets) do
			if s.Dirty then
				clusterSheet(s)
			end
		end
		-- over budget: the oldest pool soaks away now (one at a time)
		if cellCount > MAX_CELLS * 0.92 and now >= forcedUntil then
			local oldest: any = nil
			for _, s in ipairs(sheets) do
				for _, cl in ipairs(s.Clusters) do
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
		for _, s in ipairs(sheets) do
			for _, cl in ipairs(s.Clusters) do
				dryCluster(cl, now, slow)
			end
		end
		glossPass(now)
	end
	-- soaking away: the thin edges go first, the thick middle last
	for si = #sheets, 1, -1 do
		local s = sheets[si]
		for _, cl in ipairs(s.Clusters) do
			if now >= cl.Expire then
				local k = math.clamp((now - cl.Expire) * slow / cl.FadeLen, 0, 1)
				local done = true
				for _, c in ipairs(cl.Cells) do
					if s.Cells[c.Key] == c then
						local q = 0.3 + 0.7 * math.sqrt(c.Area / math.max(cl.MaxArea, 1e-6))
						local sc = math.clamp((q - k) / 0.3, 0, 1)
						if sc <= 0 then
							removeCell(c)
						else
							done = false
							if math.abs(sc - c.Scale) > 0.01 then
								c.Scale = sc
								active[c] = true
							end
						end
					end
				end
				if done then
					cl.Cells = {}
				end
			end
		end
		if s.Count == 0 then
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
		elseif beat then
			local q = math.clamp((life - 1.2) / (LIFE * 0.6), 0, 1)
			sp.Part.Color = P.Fresh:Lerp(P.Dried, q * (2 - q))
		end
	end
	for c in pairs(active) do
		if c.Sheet.Cells[c.Key] == c then
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
-- may blood stay on what `hit` found? (a real, still surface - not water, not something loose)
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

-- a drop of `size` hit `hit` flying at `vel` (k: how much blood it carried, 1 = its own volume)
function Pools.Deposit(hit: RaycastResult, size: number, vel: Vector3, k: number?): boolean
	if not holds(hit) or not env.InView(hit.Position) then
		return false
	end
	local n = hit.Normal
	local now = os.clock()
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
	local s = sheetFor(n, hit.Position:Dot(n))
	local area = SPOT * size * size * size * (k or 1)
	local u, v = coords(s, hit.Position)
	-- the skid: a fast drop smears along the surface the way it was going
	local along = vel - n * vel:Dot(n)
	local speed = vel.Magnitude
	local sk = along.Magnitude
	local rot, skid = 0, 0
	local du, dv = 0, 0
	if sk > 1 then
		local d = along / sk
		du, dv = d:Dot(s.U), d:Dot(s.V)
		rot = math.atan2(dv, du)
		skid = math.clamp(sk / 30, 0, 1)
	end
	local len = math.clamp(sk * 0.028, 0, 1.1)
	local first = pour(s, u, v, area * (if len > 0.1 then 0.6 else 1), now, nil, rot, skid)
	if not first then
		return false
	end
	if len > 0.1 then
		-- (the tail of the smear thins out)
		pour(s, u + du * len * 0.5, v + dv * len * 0.5, area * 0.27, now, nil, rot, skid)
		pour(s, u + du * len, v + dv * len, area * 0.13, now, nil, rot, skid)
	end
	-- a fast one flings specks: thin spikes ahead of it, dots round it
	if not s.Wall and speed > 9 then
		local count = math.min(5, math.floor((speed - 7) / 6 + math.random() * 1.6))
		local r = math.sqrt(area * GROW / math.pi)
		for _ = 1, count do
			local ahead = if sk > 1 then rand(-0.9, 0.9) * (1.1 - skid * 0.8) else rand(-math.pi, math.pi)
			local a = rot + ahead
			local dist = r * rand(1.2, 2.3) + len * rand(0.3, 0.9)
			local sz = size * rand(0.35, 0.8)
			speck(s, u + math.cos(a) * dist, v + math.sin(a) * dist, sz, a, 1 + skid * rand(0.5, 2.2), now)
		end
	end
	wake()
	return true
end

-- blood poured straight onto the surface under `pos` (a torn limb landing, a body falling in its own
-- blood): `area` studs² spread over a patch `spread` studs across
function Pools.Pour(hit: RaycastResult, area: number, spread: number?)
	if not holds(hit) or not env.InView(hit.Position) or hit.Normal.Y < 0.3 then
		return
	end
	local n = hit.Normal
	local s = sheetFor(n, hit.Position:Dot(n))
	local u, v = coords(s, hit.Position)
	local now = os.clock()
	local w = spread or 0.4
	local parts = math.clamp(math.floor(area / 0.08) + 1, 1, 5)
	for i = 1, parts do
		local a = rand(0, math.pi * 2)
		local d = if i == 1 then 0 else w * math.sqrt(math.random())
		pour(s, u + math.cos(a) * d, v + math.sin(a) * d, area / parts, now)
	end
	wake()
end

function Pools.Clear()
	for _, s in ipairs(sheets) do
		local list = {}
		for _, c in pairs(s.Cells) do
			table.insert(list, c)
		end
		for _, c in ipairs(list) do
			removeCell(c)
		end
	end
	table.clear(sheets)
	for _, sp in ipairs(specks) do
		park(sp.Part)
	end
	table.clear(specks)
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCfs)
	end
end

-- (tests: the sheets themselves)
function Pools.Debug(): { any }
	return sheets
end

-- (Studio / tests: how much is lying about)
function Pools.Stats(): { Cells: number, Sheets: number, Specks: number, Parts: number, Gloss: number }
	return { Cells = cellCount, Sheets = #sheets, Specks = #specks, Parts = partCount, Gloss = glossCount }
end

return Pools
