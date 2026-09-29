--[[
	AuraSprites  (StarterPlayerScripts.OverkillHUD.AuraSprites)
	Plays an aura in 2D, inside any GuiObject, straight from its real ParticleEmitters and Beams
	(ReplicatedStorage.OverkillUI.Auras.<name>): same textures, colours, sizes, fades, speeds,
	spread, drag, spin, flipbooks and scrolling beams, laid out on an invisible body seen from the
	front. It's for places a ViewportFrame can't show particles (the shop cards).

	The real auras run hundreds of particles; a card gets a fixed sprite budget, shared between the
	emitters by how much each one shows, and each sprite is made stronger by the same factor so the
	aura keeps its density and colour.

	local s = AuraSprites.new(frame, auraFolder, { PixelsPerStud = 18, Feet = Vector2.new(104, 170), ZIndex = 15 })
	s.SetActive(true) -- animates only while active (the shop turns it off when hidden)
	s.Destroy()
]]

local RunService = game:GetService("RunService")

local AuraSprites = {}

-- an R6 body seen from the front, in studs: centre x, centre y (feet at 0), width, height.
-- The character faces the viewer, so its left arm is on the viewer's right.
local BODY = {
	Head = { 0, 4.5, 2, 1 },
	Torso = { 0, 3, 2, 2 },
	["Left Arm"] = { 1.5, 3, 1, 2 },
	["Right Arm"] = { -1.5, 3, 1, 2 },
	["Left Leg"] = { 0.5, 1, 1, 2 },
	["Right Leg"] = { -0.5, 1, 1, 2 },
}

-- NormalId -> direction in character space (x = character's right, y = up, z = back)
local NORMAL = {
	[Enum.NormalId.Right] = Vector3.new(1, 0, 0),
	[Enum.NormalId.Top] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Back] = Vector3.new(0, 0, 1),
	[Enum.NormalId.Left] = Vector3.new(-1, 0, 0),
	[Enum.NormalId.Bottom] = Vector3.new(0, -1, 0),
	[Enum.NormalId.Front] = Vector3.new(0, 0, -1),
}

local TICK = 1 / 30 -- simulation / redraw rate
local rng = Random.new()

local function evalNumber(seq: NumberSequence, t: number): number
	local kps = seq.Keypoints
	if t <= kps[1].Time then
		return kps[1].Value
	end
	for i = 2, #kps do
		local a, b = kps[i - 1], kps[i]
		if t <= b.Time then
			local span = b.Time - a.Time
			local k = if span > 0 then (t - a.Time) / span else 0
			return a.Value + (b.Value - a.Value) * k
		end
	end
	return kps[#kps].Value
end

local function evalColor(seq: ColorSequence, t: number): Color3
	local kps = seq.Keypoints
	if t <= kps[1].Time then
		return kps[1].Value
	end
	for i = 2, #kps do
		local a, b = kps[i - 1], kps[i]
		if t <= b.Time then
			local span = b.Time - a.Time
			local k = if span > 0 then (t - a.Time) / span else 0
			return a.Value:Lerp(b.Value, k)
		end
	end
	return kps[#kps].Value
end

local function range(r: NumberRange): number
	return r.Min + (r.Max - r.Min) * rng:NextNumber()
end

-- a unit direction inside the emitter's spread cone, flattened onto the screen
local function spreadDir(normal: Vector3, spread: Vector2): Vector2
	local d = normal
	local a1 = if math.abs(d.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	a1 = d:Cross(a1).Unit
	local a2 = d:Cross(a1).Unit
	local r1 = math.rad(rng:NextNumber(-spread.X, spread.X))
	local r2 = math.rad(rng:NextNumber(-spread.Y, spread.Y))
	d = CFrame.fromAxisAngle(a1, r1) * d
	d = CFrame.fromAxisAngle(a2, r2) * d
	return Vector2.new(-d.X, d.Y) -- screen: x = the viewer's right (= the character's left)
end

local function partPoint(box: { number }, local3: Vector3): Vector2
	return Vector2.new(box[1] - local3.X, box[2] + local3.Y)
end

local FLIP_GRID = { [1] = 2, [2] = 4, [3] = 8 }

-- textures made for additive (LightEmission) blending with a black background instead of alpha:
-- UI can't add light, so these would show as dark squares. They are drawn with a soft glow sprite
-- in the emitter's own colours instead (same size, motion and fade).
local BLACK_BACKED = {
	["9173527444"] = true,
	["11989899750"] = true,
	["12026515010"] = true,
}
local function assetId(content: string): string
	return content:match("(%d+)%s*$") or content
end

local active: { [any]: boolean } = {}
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < TICK then
		return
	end
	local step = math.min(acc, 0.1)
	acc = 0
	for inst in pairs(active) do
		inst.Step(step)
	end
end)

function AuraSprites.new(parent: GuiObject, aura: Instance, o: { [string]: any })
	local ppu = o.PixelsPerStud or 18
	local feet: Vector2 = o.Feet or Vector2.new(parent.AbsoluteSize.X / 2, parent.AbsoluteSize.Y - 10)
	local baseZ = o.ZIndex or parent.ZIndex
	local budget = o.Budget or 130
	local soft = o.Soft or "rbxasset://textures/particles/sparkles_main.dds"

	local layer = Instance.new("Frame")
	layer.Name = "AuraSprites"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = baseZ
	layer.Parent = parent

	local function toPx(p: Vector2): Vector2
		return Vector2.new(feet.X + p.X * ppu, feet.Y - p.Y * ppu)
	end

	---------------------------------------------------------------------------
	-- read the aura
	---------------------------------------------------------------------------
	local emitters = {}
	local beams = {}
	local zOffsets = {}
	for _, group in ipairs(aura:GetChildren()) do
		local box = BODY[group.Name]
		if box then
			for _, d in ipairs(group:GetDescendants()) do
				if d:IsA("ParticleEmitter") and d.Enabled then
					local origin, area
					if d.Parent and d.Parent:IsA("Attachment") then
						origin, area = partPoint(box, d.Parent.Position), Vector2.zero
					else
						origin, area = Vector2.new(box[1], box[2]), Vector2.new(box[3], box[4])
					end
					local life = (d.Lifetime.Min + d.Lifetime.Max) / 2
					local opac, sz = 0, 0
					for k = 0, 10 do
						local t = k / 10
						opac += (1 - math.clamp(evalNumber(d.Transparency, t), 0, 1)) / 11
						local s = evalNumber(d.Size, t)
						sz += s * s / 11
					end
					local black = BLACK_BACKED[assetId(d.Texture)] == true
					table.insert(emitters, {
						E = d,
						Texture = if black then soft else d.Texture,
						Origin = origin,
						Area = area,
						Life = math.max(life, 0.05),
						Alive = d.Rate * math.max(life, 0.05),
						Weight = d.Rate * math.max(life, 0.05) * opac * sz,
						Normal = NORMAL[d.EmissionDirection] or Vector3.yAxis,
						Grid = if black then 1 else (FLIP_GRID[d.FlipbookLayout.Value] or 1),
						Accel = Vector2.new(-d.Acceleration.X, d.Acceleration.Y),
						Budget = 0,
						Rate = 0,
						Boost = 1,
						Carry = rng:NextNumber(),
					})
					zOffsets[d.ZOffset] = true
				elseif d:IsA("Beam") and d.Enabled and d.Attachment0 and d.Attachment1 then
					local p0 = partPoint(box, d.Attachment0.Position)
					local p1 = partPoint(box, d.Attachment1.Position)
					table.insert(beams, { B = d, P0 = p0, P1 = p1 })
					zOffsets[d.ZOffset] = true
				end
			end
		end
	end
	-- draw order follows ZOffset (higher = in front)
	local zList = {}
	for z in pairs(zOffsets) do
		table.insert(zList, z)
	end
	table.sort(zList)
	local zRank = {}
	for i, z in ipairs(zList) do
		zRank[z] = i
	end

	-- share the sprite budget by what each emitter contributes to the picture
	local totalW = 0
	for _, e in ipairs(emitters) do
		totalW += e.Weight
	end
	for _, e in ipairs(emitters) do
		local share = if totalW > 0 then budget * e.Weight / totalW else 2
		e.Budget = math.clamp(share, math.min(e.Alive, 2), e.Alive)
		e.Rate = e.Budget / e.Life
		e.Boost = e.Alive / math.max(e.Budget, 0.01) -- fewer sprites -> each one stronger
	end

	---------------------------------------------------------------------------
	-- sprites (pooled)
	---------------------------------------------------------------------------
	local pool: { any } = {}
	local live: { any } = {}

	local function newSprite(e: any)
		local grid = e.Grid
		local s = table.remove(pool)
		if not s or s.Grid ~= grid then
			if s then
				s.Root:Destroy()
			end
			s = { Grid = grid }
			if grid > 1 then
				-- one cell of the flipbook sheet, cut out by a clipping frame (upright)
				local clip = Instance.new("Frame")
				clip.Name = "P"
				clip.BackgroundTransparency = 1
				clip.ClipsDescendants = true
				clip.AnchorPoint = Vector2.new(0.5, 0.5)
				local img = Instance.new("ImageLabel")
				img.BackgroundTransparency = 1
				img.Size = UDim2.fromScale(grid, grid)
				img.Parent = clip
				s.Root, s.Img = clip, img
			else
				local img = Instance.new("ImageLabel")
				img.Name = "P"
				img.BackgroundTransparency = 1
				img.AnchorPoint = Vector2.new(0.5, 0.5)
				s.Root, s.Img = img, img
			end
		end
		s.Img.Image = e.Texture
		s.Root.ZIndex = baseZ + (zRank[e.E.ZOffset] or 1)
		s.Img.ZIndex = s.Root.ZIndex
		s.Root.Visible = true
		s.Root.Parent = layer
		return s
	end

	local function spawn(e: any)
		local em: ParticleEmitter = e.E
		local s = newSprite(e)
		local pos = e.Origin + Vector2.new((rng:NextNumber() - 0.5) * e.Area.X, (rng:NextNumber() - 0.5) * e.Area.Y)
		s.Emitter = e
		s.Pos = pos
		s.Vel = spreadDir(e.Normal, em.SpreadAngle) * range(em.Speed)
		s.Age = 0
		s.Life = math.max(range(em.Lifetime), 0.05)
		s.Rot = range(em.Rotation)
		s.Spin = range(em.RotSpeed)
		s.Frame = if em.FlipbookMode == Enum.ParticleFlipbookMode.Random then rng:NextInteger(0, e.Grid * e.Grid - 1) else 0
		s.Rate = range(em.FlipbookFramerate)
		table.insert(live, s)
	end

	local function draw(s: any)
		local e = s.Emitter
		local em: ParticleEmitter = e.E
		local t = math.clamp(s.Age / s.Life, 0, 1)
		local size = evalNumber(em.Size, t) * ppu
		local alpha = 1 - math.clamp(evalNumber(em.Transparency, t), 0, 1)
		alpha = 1 - (1 - alpha) ^ e.Boost
		alpha = math.clamp(alpha, 0, 0.96)
		local squash = evalNumber(em.Squash, t)
		local w, h = size, size
		if squash > 0 then
			w, h = size / (1 + squash), size * (1 + squash)
		elseif squash < 0 then
			w, h = size * (1 - squash), size / (1 - squash)
		end
		local p = toPx(s.Pos)
		local root = s.Root
		root.Position = UDim2.fromOffset(p.X, p.Y)
		root.Size = UDim2.fromOffset(w, h)
		local img = s.Img
		img.ImageColor3 = evalColor(em.Color, t)
		img.ImageTransparency = 1 - alpha
		if s.Grid > 1 then
			local n = s.Grid
			local frames = n * n
			local f = s.Frame
			if em.FlipbookMode == Enum.ParticleFlipbookMode.OneShot then
				f = math.min(math.floor(t * frames), frames - 1)
			elseif em.FlipbookMode == Enum.ParticleFlipbookMode.PingPong then
				local k = math.floor(s.Age * s.Rate) % (frames * 2 - 2)
				f = if k < frames then k else frames * 2 - 2 - k
			elseif em.FlipbookMode ~= Enum.ParticleFlipbookMode.Random then
				f = math.floor(s.Age * s.Rate) % frames
			end
			img.Position = UDim2.fromScale(-(f % n), -math.floor(f / n))
		else
			local rot = s.Rot
			if em.Orientation == Enum.ParticleOrientation.VelocityParallel and s.Vel.Magnitude > 1e-4 then
				rot += math.deg(math.atan2(s.Vel.X, s.Vel.Y))
			end
			root.Rotation = rot
		end
	end

	local function recycle(i: number)
		local s = live[i]
		live[i] = live[#live]
		live[#live] = nil
		s.Root.Visible = false
		table.insert(pool, s)
	end

	---------------------------------------------------------------------------
	-- beams: a scrolling strip of the beam texture, faded along its length
	---------------------------------------------------------------------------
	local beamStrips = {}
	-- beams that share both ends are drawn in one group (one fade for all of them)
	local groups: { [string]: any } = {}
	for _, b in ipairs(beams) do
		local key = ("%.2f,%.2f,%.2f,%.2f"):format(b.P0.X, b.P0.Y, b.P1.X, b.P1.Y)
		local g = groups[key]
		if not g then
			local a, c = toPx(b.P0), toPx(b.P1)
			local mid = (a + c) / 2
			local len = math.max((c - a).Magnitude, 1)
			local cg = Instance.new("CanvasGroup")
			cg.Name = "Beam"
			cg.BackgroundTransparency = 1
			cg.AnchorPoint = Vector2.new(0.5, 0.5)
			cg.Position = UDim2.fromOffset(mid.X, mid.Y)
			cg.ZIndex = baseZ + (zRank[b.B.ZOffset] or 1)
			cg.Parent = layer
			-- rotate so the strip runs from Attachment0 (bottom of the strip) to Attachment1
			local dir = c - a
			cg.Rotation = math.deg(math.atan2(dir.X, -dir.Y))
			local fade = Instance.new("UIGradient")
			fade.Rotation = -90 -- 0 at Attachment0 (bottom) -> 1 at Attachment1 (top)
			fade.Transparency = b.B.Transparency
			fade.Parent = cg
			g = { CG = cg, Len = len, Width = 0, Strips = {} }
			groups[key] = g
		end
		local width = math.max(b.B.Width0, b.B.Width1) * ppu
		g.Width = math.max(g.Width, width)
		g.CG.Size = UDim2.fromOffset(g.Width, g.Len)
		local strip = Instance.new("ImageLabel")
		strip.BackgroundTransparency = 1
		strip.Image = b.B.Texture
		strip.ImageColor3 = evalColor(b.B.Color, 0.5)
		strip.ImageTransparency = 0.15
		strip.ScaleType = Enum.ScaleType.Tile
		strip.AnchorPoint = Vector2.new(0.5, 0)
		strip.Position = UDim2.new(0.5, 0, 0, -g.Len)
		strip.Size = UDim2.fromOffset(width, g.Len * 2)
		strip.TileSize = UDim2.fromOffset(width, g.Len)
		strip.ZIndex = g.CG.ZIndex
		strip.Parent = g.CG
		table.insert(g.Strips, { Img = strip, Speed = b.B.TextureSpeed, Offset = rng:NextNumber() })
		table.insert(beamStrips, g.Strips[#g.Strips])
	end

	---------------------------------------------------------------------------
	-- simulation
	---------------------------------------------------------------------------
	local api: any = { Layer = layer }

	function api.Step(dt: number)
		-- emit
		for _, e in ipairs(emitters) do
			e.Carry += e.Rate * dt
			while e.Carry >= 1 do
				e.Carry -= 1
				spawn(e)
			end
		end
		-- move, age, draw
		local i = 1
		while i <= #live do
			local s = live[i]
			s.Age += dt
			if s.Age >= s.Life then
				recycle(i)
			else
				local em: ParticleEmitter = s.Emitter.E
				s.Vel += s.Emitter.Accel * dt
				if em.Drag > 0 then
					s.Vel *= 0.5 ^ (em.Drag * dt)
				end
				s.Pos += s.Vel * dt
				s.Rot += s.Spin * dt
				draw(s)
				i += 1
			end
		end
		-- beams scroll along their length
		for _, g in pairs(groups) do
			for _, st in ipairs(g.Strips) do
				st.Offset = (st.Offset + st.Speed * dt) % 1
				st.Img.Position = UDim2.new(0.5, 0, 0, -g.Len + st.Offset * g.Len)
			end
		end
	end

	-- start with a full aura instead of an empty one filling up
	function api.Warm()
		for _ = 1, 60 do
			api.Step(TICK)
		end
	end

	function api.SetActive(on: boolean)
		if on then
			active[api] = true
		else
			active[api] = nil
		end
	end

	function api.Destroy()
		active[api] = nil
		layer:Destroy()
		table.clear(live)
		table.clear(pool)
	end

	api.Warm()
	return api
end

---------------------------------------------------------------------------
-- a captured aura: a sprite sheet of real in-game frames of the aura (taken in Studio on a black
-- stage, black turned into transparency), played as a slow crossfading loop. This is the exact
-- look of the aura, glow and all.
--   AuraSprites.newSheet(parent, imageId, { Size = 190, Centre = Vector2.new(100, 90), ZIndex = 15,
--       Frames = 10, Columns = 4, Cell = 256, Fps = 2.5 })
---------------------------------------------------------------------------
-- where to put a sheet cell's centre so the aura's own visual centre (focus, in cell pixels) lands
-- on target (the middle of the picture)
function AuraSprites.focusCentre(target: Vector2, size: number, focus: { number }?, cell: number?): Vector2
	local c = cell or 256
	if not focus then
		return target
	end
	local k = size / c
	return Vector2.new(target.X - (focus[1] - c / 2) * k, target.Y - (focus[2] - c / 2) * k)
end

function AuraSprites.newSheet(parent: GuiObject, imageId: number, o: { [string]: any })
	local frames = o.Frames or 10
	local cols = o.Columns or 4
	local cell = o.Cell or 256
	local fps = o.Fps or 2.5
	local size = o.Size or 180
	local centre: Vector2 = o.Centre or Vector2.new(parent.AbsoluteSize.X / 2, parent.AbsoluteSize.Y / 2)
	local imgs: { ImageLabel } = {}
	for k = 1, 2 do
		local im = Instance.new("ImageLabel")
		im.Name = "AuraFrame" .. k
		im.BackgroundTransparency = 1
		im.Image = "rbxassetid://" .. tostring(imageId)
		im.ImageRectSize = Vector2.new(cell, cell)
		im.AnchorPoint = Vector2.new(0.5, 0.5)
		im.Position = UDim2.fromOffset(centre.X, centre.Y)
		im.Size = UDim2.fromOffset(size, size)
		im.ZIndex = (o.ZIndex or parent.ZIndex) + k - 1
		if o.SoftEdges ~= false then
			-- the captures stop flat where the floor was: melt the top and bottom of the cell so the
			-- aura never looks cut off
			local g = Instance.new("UIGradient")
			g.Rotation = 90
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.1, 0),
				NumberSequenceKeypoint.new(0.8, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Parent = im
		end
		im.Parent = parent
		imgs[k] = im
	end
	local t = rng:NextNumber() * frames
	local function rect(f: number): Vector2
		return Vector2.new((f % cols) * cell, math.floor(f / cols) * cell)
	end
	local api: any = {}
	local function draw()
		local f = math.floor(t) % frames
		local frac = t - math.floor(t)
		-- the next frame fades in over the current one, then the current one fades out under it:
		-- the picture never dips in brightness between frames
		imgs[1].ImageRectOffset = rect(f)
		imgs[1].ImageTransparency = math.clamp((frac - 0.5) * 2, 0, 1)
		imgs[2].ImageRectOffset = rect((f + 1) % frames)
		imgs[2].ImageTransparency = math.clamp(1 - frac * 2, 0, 1)
	end
	function api.Step(dt: number)
		t = (t + dt * fps) % frames
		draw()
	end
	function api.SetActive(on: boolean)
		if on then
			active[api] = true
		else
			active[api] = nil
		end
	end
	function api.Destroy()
		active[api] = nil
		for _, im in ipairs(imgs) do
			im:Destroy()
		end
	end
	draw()
	return api
end

return AuraSprites
