--[[
	CombatCallout  (ReplicatedStorage.Combat.CombatCallout)
	The hit tag: one piece of HUD lettering that rides beside a fighter's head and tells the story of
	a combo on them, in the game's own UI style (the display font, the ink outline, a gradient in the
	hero's colours, the shine sweep, the star / rays / flame art - like the combo meter).

	ONE NUMBER, ALWAYS. The tag shows exactly one number per fighter - the running damage of your
	string - and nothing else that looks like a number: no ghost copy behind it, no drop-shadow copy
	under it, no "+N" chips. Every hit stamps the new total straight in (a quick count-up), punches it,
	tips it the other way and flashes its own face white for a blink.

	  damage   your hits keep one running total per victim. The number HEATS UP as the string grows:
	           it rests a little bigger each hit, trembles harder and runs whiter at the top, the
	           sunburst comes up behind it from the 3rd hit and the flame lights beside it (centred on
	           the digits, just left of them) from the 5th. From the flame on - and on a guard break -
	           the number burns RED. Every 5th hit is a milestone (stars, shake, shine). Blocked hits
	           turn it silver with a BLOCKED pill.
	  guard    grows out of the same tag: the pill spins away and GUARD BREAK! drops in letter by
	  break    letter above the number (each letter slams, flashes white and settles, then the word
	           rides a gentle wave), the number slams in red, stars burst, the tag shakes. Everyone
	           sees GUARD BREAK!; only the attacker sees the number. The two fighters get a white
	           screen flash; the broken one gets GUARD BROKEN across their screen.

	  Callout.Damage(victim, amount, kind, attacker)   kind = "Light" | "Heavy" | "Finisher" | "Break" | "Block"
	  Callout.GuardBreak(victim, attacker)
	  Callout.Banner(text, accent, deep)                the lettering across the top of your own screen
	  Callout.Flash(strength)                           white flash over your own screen (0..1)
	  Callout.ColorsFor(attacker)                       the attacker's hero colours (HeroConfig Accent),
	                                                    else yours, else silver
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

local Callout = {}

local Kit: any = nil
local Theme: any = nil
local HeroConfig: any = nil
pcall(function()
	local ui = ReplicatedStorage:WaitForChild("OverkillUI", 10)
	Kit = require(ui:WaitForChild("Kit", 10))
	Theme = Kit.Theme
	local hc = ui:FindFirstChild("HeroConfig")
	if hc then
		HeroConfig = require(hc)
	end
end)

local rgb = Color3.fromRGB
local INK = rgb(9, 14, 28)
local WHITE = Color3.new(1, 1, 1)
local SILVER = { rgb(236, 241, 248), rgb(118, 130, 156) }
-- the burning number (flame tier / guard break): a clean fighting-game red, white-hot at the top
local RED = { rgb(255, 58, 52), rgb(168, 12, 24) }
-- the flame beside it: yellow tip down to orange-red
local FIRE = { rgb(255, 232, 110), rgb(255, 150, 40), rgb(236, 52, 24) }
local FLAME_AT = 5 -- the flame lights (and the number burns red) from this hit of a string

local function tween(o: Instance, t: number, props: any, style: Enum.EasingStyle?, dir: Enum.EasingDirection?, delay: number?): Tween
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out, 0, false, delay or 0), props)
	tw:Play()
	return tw
end

local function lighten(c: Color3, a: number): Color3
	return c:Lerp(WHITE, a)
end

local function displayFont(): Font
	return if Theme and Theme.Font and Theme.Font.Display then Theme.Font.Display else Font.new("rbxasset://fonts/families/FredokaOne.json")
end

---------------------------------------------------------------------------
-- hero colours
---------------------------------------------------------------------------
local function heroColors(char: Instance?): (Color3?, Color3?)
	local id = char and char:GetAttribute("Hero")
	local heroes = HeroConfig and HeroConfig.Heroes
	local h = heroes and type(id) == "string" and heroes[id]
	if h and h.Accent and typeof(h.Accent[1]) == "Color3" then
		return h.Accent[1], h.Accent[2] or h.Accent[1]:Lerp(Color3.new(), 0.35)
	end
	return nil, nil
end

function Callout.ColorsFor(attacker: Instance?): (Color3, Color3)
	local a, d = heroColors(attacker)
	if a and d then
		return a, d
	end
	local me = Players.LocalPlayer
	a, d = heroColors(me and me.Character)
	if a and d then
		return a, d
	end
	return SILVER[1], SILVER[2]
end

---------------------------------------------------------------------------
-- lettering pieces (HUD style): ink outline, gradient face, shine, white flash
---------------------------------------------------------------------------
local function label(parent: GuiObject, name: string, size: number, z: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromScale(1, 1)
	l.FontFace = displayFont()
	l.TextSize = size
	l.TextColor3 = WHITE
	l.ZIndex = z
	l.Parent = parent
	return l
end

local function ink(l: TextLabel, thick: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thick
	s.Color = INK
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = l
end

local function frame(parent: GuiObject, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = z
	f.Parent = parent
	return f
end

local function shineGradient(parent: Instance): UIGradient
	local sg = Instance.new("UIGradient")
	sg.Rotation = 20
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 1),
		NumberSequenceKeypoint.new(0.47, 0.55),
		NumberSequenceKeypoint.new(0.5, 0.12),
		NumberSequenceKeypoint.new(0.54, 0.6),
		NumberSequenceKeypoint.new(0.62, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sg.Offset = Vector2.new(-1.3, 0)
	sg.Parent = parent
	return sg
end

-- the combo meter's paint: a light top, the colour through the body, a deeper base. `heat` (0..1)
-- runs the top and body whiter as a string builds.
local function paintGrad(g: UIGradient, accent: Color3, deep: Color3, heat: number?)
	local h = heat or 0
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, lighten(accent, 0.62 + 0.33 * h)),
		ColorSequenceKeypoint.new(0.45, lighten(accent, 0.22 * h)),
		ColorSequenceKeypoint.new(1, deep),
	})
end

local function fadeLabels(labels: { TextLabel }, a: number, t: number, delay: number?)
	for _, l in ipairs(labels) do
		tween(l, t, { TextTransparency = a }, Enum.EasingStyle.Quad, nil, delay)
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then
			tween(s, t, { Transparency = a }, Enum.EasingStyle.Quad, nil, delay)
		end
	end
end

local function sweepGrad(sg: UIGradient, delay: number?)
	task.delay(delay or 0, function()
		sg.Offset = Vector2.new(-1.3, 0)
		tween(sg, 0.45, { Offset = Vector2.new(1.3, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	end)
end

---------------------------------------------------------------------------
-- digit widths (measured once, never on a hit: TextService yields)
---------------------------------------------------------------------------
local REF = 100
local charW: { [string]: number } = {}
task.spawn(function()
	for _, ch in ipairs(string.split("0123456789", "")) do
		local ok, v = pcall(function()
			local p = Instance.new("GetTextBoundsParams")
			p.Text = ch
			p.Font = displayFont()
			p.Size = REF
			p.Width = 4000
			return TextService:GetTextBoundsAsync(p)
		end)
		if ok and typeof(v) == "Vector2" then
			charW[ch] = v.X
		end
	end
end)

local function digitsWidth(text: string, size: number): number
	local w = 0
	for i = 1, #text do
		w += charW[text:sub(i, i)] or REF * 0.62
	end
	return w * size / REF
end

---------------------------------------------------------------------------
-- the number: Root (layout, punch scale, kick) > Body (tremble) > the face, its shine and its flash,
-- with the flame riding in the body just left of the digits and the rays behind
---------------------------------------------------------------------------
type Num = {
	Root: Frame,
	Scale: UIScale,
	Body: Frame,
	Labels: { TextLabel },
	Grad: UIGradient,
	Shine: UIGradient,
	Flash: TextLabel,
	Rays: ImageLabel?,
	Flame: ImageLabel?,
	FlameScale: UIScale?,
	Size: number,
	Stroke: number,
	Ink: number,
	Home: UDim2,
}

-- the flame's centre sits on the digits' own centre line (the display font's digits sit a hair
-- above the middle of the text box)
local FLAME_DY = -0.02
-- the flame's ink outline: as thick as this share of the number's size (a bold line that pops,
-- about two thirds of the digits' own outline), in 16 directions
local FLAME_INK = 0.072
local FLAME_INK_DIRS = 16
local FLAME_FLICKER = 0.22 -- the flame's flicker: its scale swings this far either way

local function newNum(parent: GuiObject, size: number, w: number, h: number, home: UDim2, z: number): Num
	local root = frame(parent, "Num", z)
	root.Size = UDim2.fromOffset(w, h)
	root.Position = home
	local sc = Instance.new("UIScale")
	sc.Parent = root
	local stroke = math.max(3, size * 0.12)

	-- the sunburst behind (the HUD's own rays), off until the string heats up
	local rays: ImageLabel? = nil
	if Kit then
		rays = Kit.rays(root, WHITE, size * 1.6, 1, z - 2, true)
	end

	local body = frame(root, "Body", z)
	-- the one number: face (gradient + ink outline). The shine and the flash are the same text on
	-- the same spot, masked (shine) or invisible until a hit (flash) - never a second number
	local face = label(body, "Face", size, z + 1)
	ink(face, stroke)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Parent = face
	local shine = label(body, "Shine", size, z + 2)
	local sg = shineGradient(shine)
	local flash = label(body, "Flash", size, z + 3)
	flash.TextTransparency = 1

	-- the flame (the HUD's flame art, painted fire) centred on the digits' line, left of them
	local flame: ImageLabel? = nil
	local fs: UIScale? = nil
	if Kit and Theme and Theme.Icon.Flame then
		flame = Kit.image({
			Name = "Flame",
			Image = Theme.Icon.Flame,
			ImageColor3 = WHITE,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(0.5, -size * 0.6, 0.5, size * FLAME_DY),
			Size = UDim2.fromOffset(size * 0.74, size * 0.74),
			ImageTransparency = 1,
			ZIndex = z,
			Parent = body,
		})
		local fg = Instance.new("UIGradient")
		fg.Rotation = 90
		fg.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, FIRE[1]),
			ColorSequenceKeypoint.new(0.5, FIRE[2]),
			ColorSequenceKeypoint.new(1, FIRE[3]),
		})
		fg.Parent = flame
		local fsc = Instance.new("UIScale")
		fsc.Parent = flame
		fs = fsc
		-- its ink outline: the same flame art in ink, laid behind it a line's width out in 16
		-- directions, so the outline follows every edge of the flame at one even width and never
		-- crosses it. The tag sorts its layers globally: the ink sits one layer under the flame and
		-- over the rays. As the flame's own children the ink rides its size, pop and flicker, and
		-- it fades with it.
		local f = flame :: ImageLabel
		local r = math.max(2.5, size * FLAME_INK)
		local inks: { ImageLabel } = {}
		for i = 1, FLAME_INK_DIRS do
			local a = (i - 1) / FLAME_INK_DIRS * math.pi * 2
			local o = Instance.new("ImageLabel")
			o.Name = "Ink"
			o.BackgroundTransparency = 1
			o.Image = Theme.Icon.Flame
			o.ImageColor3 = INK
			o.ImageTransparency = f.ImageTransparency
			o.ScaleType = Enum.ScaleType.Fit
			o.AnchorPoint = Vector2.new(0.5, 0.5)
			o.Position = UDim2.new(0.5, math.cos(a) * r, 0.5, math.sin(a) * r)
			o.Size = UDim2.fromScale(1, 1)
			o.ZIndex = z - 1
			o.Parent = f
			table.insert(inks, o)
		end
		f:GetPropertyChangedSignal("ImageTransparency"):Connect(function()
			local t = f.ImageTransparency
			for _, o in ipairs(inks) do
				o.ImageTransparency = t
			end
		end)
	end

	return {
		Root = root,
		Scale = sc,
		Body = body,
		Labels = { face, shine },
		Grad = g,
		Shine = sg,
		Flash = flash,
		Rays = rays,
		Flame = flame,
		FlameScale = fs,
		Size = size,
		Stroke = stroke,
		Ink = math.max(2.5, size * FLAME_INK),
		Home = home,
	}
end

local function numText(n: Num, text: string)
	for _, l in ipairs(n.Labels) do
		l.Text = text
	end
	n.Flash.Text = text
	-- the flame sits just left of the digits (measured), centred on them, however many there are.
	-- Its right edge (it scales and flickers from there) keeps clear of the digits by their own ink
	-- outline, its ink outline at the flicker's widest, and a hair of air - the two outlines never
	-- touch, the flame never cuts into a digit
	if n.Flame then
		local half = digitsWidth(text, n.Size) / 2
		local clear = n.Stroke + n.Ink * (1 + FLAME_FLICKER) + n.Size * 0.02
		n.Flame.Position = UDim2.new(0.5, -half - clear, 0.5, n.Size * FLAME_DY)
	end
end

-- the face blinks white for a moment (the flash sits exactly on the digits: no second number)
local function flashFace(n: Num, strength: number)
	n.Flash.TextTransparency = math.clamp(1 - strength, 0, 1)
	tween(n.Flash, 0.16 + 0.08 * strength, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
end

---------------------------------------------------------------------------
-- letters (for GUARD BREAK! / GUARD BROKEN): every letter its own piece so the word can drop in
-- one letter at a time, flash, and ride a wave
---------------------------------------------------------------------------
type Letter = { Frame: Frame, Scale: UIScale, Labels: { TextLabel }, Flash: TextLabel, Shine: UIGradient, X: number }
type Word = { Root: Frame, Letters: { Letter }, Width: number, Born: number }

local widthCache: { [string]: number } = {}
local function textWidth(text: string, size: number): number
	local key = text .. "|" .. size
	local c = widthCache[key]
	if c then
		return c
	end
	local ok, v = pcall(function()
		local p = Instance.new("GetTextBoundsParams")
		p.Text = text
		p.Font = displayFont()
		p.Size = size
		p.Width = 4000
		return TextService:GetTextBoundsAsync(p)
	end)
	local w = if ok and typeof(v) == "Vector2" then v.X else #text * size * 0.62
	widthCache[key] = w
	return w
end

-- warm the widths the call-outs use so the first guard break never waits on them
task.spawn(function()
	for _, spec in ipairs({ { "GUARD BREAK!", 42 }, { "GUARD BROKEN", 66 } }) do
		local text, size = spec[1], spec[2]
		for i = 1, #text do
			textWidth(text:sub(1, i), size)
			textWidth(text:sub(i, i), size)
		end
	end
end)

local function newWord(parent: GuiObject, text: string, size: number, accent: Color3, deep: Color3, z: number): Word
	local root = frame(parent, "Word", z)
	local stroke = math.max(3, size * 0.11)
	-- the letters sit as close as normal text (just a hair apart). Each letter is its own piece, so
	-- to keep a neighbour's outline from ever cutting into a letter, the layers are drawn in bands
	-- across the whole word (the gui uses global z-order): every shadow first, then every ink
	-- outline, then every letter face on top - the outlines merge like one line of text and no
	-- letter is ever drawn over another, even mid-wave
	local gap = math.max(1, stroke * 0.3)
	local total = textWidth(text, size) + gap * (#text - 1)
	local letters = {}
	local prev = 0
	for i = 1, #text do
		local ch = text:sub(i, i)
		local upto = textWidth(text:sub(1, i), size)
		local cx = (prev + upto) / 2 + gap * (i - 1) - total / 2
		prev = upto
		if ch ~= " " then
			local f = frame(root, "L" .. i, z)
			f.Size = UDim2.fromOffset(size * 1.1, size * 1.5)
			f.Position = UDim2.new(0.5, cx, 0.5, 0)
			local sc = Instance.new("UIScale")
			sc.Parent = f
			local shadow = label(f, "Shadow", size, z)
			shadow.Text = ch
			shadow.TextColor3 = INK
			shadow.Position = UDim2.new(0.5, 0, 0.5, math.max(3, size * 0.085))
			ink(shadow, stroke)
			local outline = label(f, "Outline", size, z + 1)
			outline.Text = ch
			outline.TextColor3 = INK
			ink(outline, stroke)
			local face = label(f, "Face", size, z + 2)
			face.Text = ch
			local g = Instance.new("UIGradient")
			g.Rotation = 90
			g.Parent = face
			paintGrad(g, accent, deep, 0)
			local shine = label(f, "Shine", size, z + 3)
			shine.Text = ch
			local sg = shineGradient(shine)
			local flash = label(f, "Flash", size, z + 4)
			flash.Text = ch
			flash.TextTransparency = 1
			for _, l in ipairs({ shadow, outline, face, shine }) do
				l.TextTransparency = 1
				local s = l:FindFirstChildOfClass("UIStroke")
				if s then
					s.Transparency = 1
				end
			end
			table.insert(letters, { Frame = f, Scale = sc, Labels = { shadow, outline, face, shine }, Flash = flash, Shine = sg, X = cx })
		end
	end
	return { Root = root, Letters = letters, Width = total, Born = os.clock() }
end

-- the drop-in: each letter drops from above with a small twist, lands with a bounce and a white
-- flash (kept small enough that a letter never swings into its neighbour)
local function wordIn(w: Word, stagger: number)
	for i, L in ipairs(w.Letters) do
		local d = (i - 1) * stagger
		L.Scale.Scale = 1.3
		L.Frame.Rotation = if i % 2 == 0 then 10 else -10
		L.Frame.Position = UDim2.new(0.5, L.X, 0.5, -30)
		tween(L.Scale, 0.26, { Scale = 1 }, Enum.EasingStyle.Back, nil, d)
		tween(L.Frame, 0.3, { Rotation = 0, Position = UDim2.new(0.5, L.X, 0.5, 0) }, Enum.EasingStyle.Back, nil, d)
		fadeLabels(L.Labels, 0, 0.06, d)
		task.delay(d + 0.1, function()
			L.Flash.TextTransparency = 0
			tween(L.Flash, 0.22, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
		end)
	end
	w.Born = os.clock() + #w.Letters * stagger + 0.3
end

-- one shine running across the whole word (each letter's band starts when the sweep reaches it)
local function wordShine(w: Word, delay: number)
	for _, L in ipairs(w.Letters) do
		local d = delay + (L.X + w.Width / 2) / math.max(w.Width, 1) * 0.35
		sweepGrad(L.Shine, d)
	end
end

-- while it holds: a gentle travelling wave through the letters
local function wordWave(w: Word, now: number)
	if now < w.Born then
		return
	end
	local t = now - w.Born
	local amp = math.min(t * 6, 1) * 2.6
	for i, L in ipairs(w.Letters) do
		L.Frame.Position = UDim2.new(0.5, L.X, 0.5, math.sin(t * 7 - i * 0.6) * amp)
	end
end

-- the exit: letters lift away one after another and fade
local function wordOut(w: Word, stagger: number)
	w.Born = math.huge
	for i, L in ipairs(w.Letters) do
		local d = (i - 1) * stagger
		tween(L.Frame, 0.24, { Position = UDim2.new(0.5, L.X, 0.5, -26), Rotation = if i % 2 == 0 then 6 else -6 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, d)
		tween(L.Scale, 0.24, { Scale = 0.75 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, d)
		fadeLabels(L.Labels, 1, 0.2, d + 0.04)
	end
end

-- the pack's star art bursting out and fading
local function stars(parent: GuiObject, color: Color3, count: number, reach: number, z: number, center: UDim2?)
	if not (Kit and Theme) then
		return
	end
	local c = center or UDim2.fromScale(0.5, 0.5)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.5
		local star = Kit.image({
			Name = "Star",
			Image = Theme.Icon.Star,
			ImageColor3 = if i % 2 == 0 then WHITE else color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = c,
			Size = UDim2.fromOffset(18, 18),
			Rotation = math.random(0, 90),
			ZIndex = z,
			Parent = parent,
		})
		local r = reach * (0.7 + math.random() * 0.4)
		tween(star, 0.55, {
			Position = c + UDim2.fromOffset(math.cos(a) * r, math.sin(a) * r * 0.6),
			Rotation = star.Rotation + 150,
			Size = UDim2.fromOffset(6, 6),
			ImageTransparency = 1,
		}, Enum.EasingStyle.Quart)
		task.delay(0.6, function()
			star:Destroy()
		end)
	end
end

---------------------------------------------------------------------------
-- the hit tag (one per fighter)
---------------------------------------------------------------------------
type Tag = {
	Gui: BillboardGui,
	Stage: Frame,
	Pop: UIScale,
	Num: Num,
	Pill: Frame,
	PillScale: UIScale,
	Title: Word?,
	TitleHolder: Frame,
	Total: number,
	Shown: number,
	Hits: number,
	Heat: number,
	Last: number,
	Serial: number,
	Seed: number,
	Accent: Color3,
	Deep: Color3,
	Active: boolean,
	Closing: boolean,
	HasNum: boolean,
	Blocked: boolean,
	Red: boolean,
	Flip: boolean,
	Beat: RBXScriptConnection?,
}

local tags: { [Model]: Tag } = setmetatable({}, { __mode = "k" }) :: any
local HOME = Vector3.new(2.4, 1.3, 0) -- camera-relative: right of the head, a little up
local RESET = 1.6 -- a new string of hits starts the total from zero after this long
local NUM_HOME = UDim2.new(0.5, 0, 0.5, 14)

local function fmt(v: number): string
	return tostring(math.max(1, math.floor(v + 0.5)))
end

local function tagFor(victim: Model): Tag?
	local head = victim:FindFirstChild("Head")
	if not (Kit and head and head:IsA("BasePart")) then
		return nil
	end
	local t = tags[victim]
	if t and t.Gui.Parent == head then
		return t
	end
	if t then
		t.Gui:Destroy()
	end
	-- never two tags on one head (a tag left over from an earlier copy of this fighter)
	for _, old in ipairs(head:GetChildren()) do
		if old.Name == "HitTag" and old:IsA("BillboardGui") then
			old:Destroy()
		end
	end
	local C = Theme.C

	local bb = Instance.new("BillboardGui")
	bb.Name = "HitTag"
	bb.Size = UDim2.fromOffset(540, 300)
	bb.StudsOffset = HOME
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 130
	bb.ZIndexBehavior = Enum.ZIndexBehavior.Global -- (the title's shadow / outline / face bands)
	bb.Enabled = false
	bb.Adornee = head
	bb.Parent = head

	local stage = frame(bb, "Stage", 1)
	local pop = Instance.new("UIScale")
	pop.Parent = stage

	local titleHolder = frame(stage, "TitleHolder", 8)
	titleHolder.Size = UDim2.fromOffset(520, 70)
	titleHolder.Position = UDim2.new(0.5, 0, 0.5, -52)
	titleHolder.Rotation = -4

	local num = newNum(stage, 56, 260, 84, NUM_HOME, 4)
	for _, l in ipairs(num.Labels) do
		l.TextTransparency = 1
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = 1
		end
	end

	-- the BLOCKED pill: a small HUD plate under the number
	local pill = Kit.plate({
		Name = "Pill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 64),
		Size = UDim2.fromOffset(122, 30),
		Radius = 15,
		Gradient = { C.Navy700, C.Night },
		Stroke = 2.5,
		ZIndex = 2,
		Parent = stage,
	})
	Kit.text({ Name = "Text", Text = "BLOCKED", TextSize = 19, Stroke = 2, TextColor3 = C.TextSoft, ZIndex = 3, Parent = pill })
	local ps = Instance.new("UIScale")
	ps.Scale = 0
	ps.Parent = pill

	t = {
		Gui = bb,
		Stage = stage,
		Pop = pop,
		Num = num,
		Pill = pill,
		PillScale = ps,
		Title = nil,
		TitleHolder = titleHolder,
		Total = 0,
		Shown = 0,
		Hits = 0,
		Heat = 0,
		Last = 0,
		Serial = 0,
		Seed = math.random() * 100,
		Accent = SILVER[1],
		Deep = SILVER[2],
		Active = false,
		Closing = false,
		HasNum = false,
		Blocked = false,
		Red = false,
		Flip = false,
		Beat = nil,
	}
	tags[victim] = t
	return t
end

-- one heartbeat per live tag: the count-up, the tremble, the flame flicker, the title's wave
local function beat(t: Tag)
	if t.Beat then
		return
	end
	t.Beat = RunService.Heartbeat:Connect(function(dt)
		if not t.Gui.Parent or not t.Active then
			if t.Beat then
				t.Beat:Disconnect()
				t.Beat = nil
			end
			return
		end
		local now = os.clock()
		-- a quick count up to the running total (one label: the number only ever changes value)
		local d = t.Total - t.Shown
		if math.abs(d) > 0.3 then
			t.Shown += d * (1 - math.exp(-dt * 26))
			numText(t.Num, fmt(t.Shown))
		elseif t.Shown ~= t.Total then
			t.Shown = t.Total
			numText(t.Num, fmt(t.Total))
		end
		-- heat cools once the hits stop
		if now - t.Last > 0.55 then
			t.Heat *= math.exp(-dt * 3)
		end
		-- tremble: harder the hotter the string (smooth noise, not jitter)
		local h = t.Heat
		local tt = now * 16
		local ax = math.noise(tt, t.Seed) * 2
		local ay = math.noise(t.Seed, tt) * 2
		local ar = math.noise(tt * 0.7, t.Seed + 7)
		t.Num.Body.Position = UDim2.new(0.5, ax * (0.3 + 4 * h), 0.5, ay * (0.3 + 3 * h))
		t.Num.Body.Rotation = ar * 5 * h
		-- the flame flickers (it keeps its right edge and its centre line: always beside the digits)
		if t.Num.FlameScale then
			t.Num.FlameScale.Scale = 1 + math.clamp(math.noise(now * 9, t.Seed + 3), -1, 1) * FLAME_FLICKER
		end
		-- the title rides its wave
		if t.Title then
			wordWave(t.Title, now)
		end
	end)
end

local function pillShow(t: Tag, on: boolean)
	if on == t.Blocked then
		return
	end
	t.Blocked = on
	if on then
		t.Pill.Rotation = -8
		tween(t.PillScale, 0.26, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(t.Pill, 0.3, { Rotation = 0 }, Enum.EasingStyle.Back)
	else
		tween(t.PillScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		tween(t.Pill, 0.2, { Rotation = 70 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
end

-- the tag comes up (or is already up, or is caught while it was leaving)
local function open(t: Tag)
	t.Serial += 1
	if t.Active and not t.Closing then
		return
	end
	if t.Active and t.Closing then
		-- caught on the way out: glide straight back, everything that was showing comes back
		t.Closing = false
		tween(t.Gui, 0.14, { StudsOffset = HOME }, Enum.EasingStyle.Quad)
		tween(t.Pop, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		if t.HasNum then
			fadeLabels(t.Num.Labels, 0, 0.08)
			if t.Num.Flame and t.Red then
				tween(t.Num.Flame, 0.1, { ImageTransparency = 0 }, Enum.EasingStyle.Quad)
			end
		end
		return
	end
	t.Active = true
	t.Closing = false
	t.Gui.Enabled = true
	t.Gui.StudsOffset = HOME
	tween(t.Gui, 0.01, { StudsOffset = HOME }) -- cancels a leave still gliding
	t.Pop.Scale = 0.35
	tween(t.Pop, 0.32, { Scale = 1 }, Enum.EasingStyle.Back)
	t.Stage.Rotation = -7
	tween(t.Stage, 0.36, { Rotation = 0 }, Enum.EasingStyle.Back)
	beat(t)
end

-- back to an empty tag (nothing left on it that could show under the next number)
local function clear(t: Tag)
	t.HasNum = false
	t.Red = false
	t.Total, t.Shown, t.Hits, t.Heat = 0, 0, 0, 0
	local n = t.Num
	for _, l in ipairs(n.Labels) do
		l.TextTransparency = 1
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = 1
		end
	end
	n.Flash.TextTransparency = 1
	n.Scale.Scale = 1
	if n.Rays then
		n.Rays.ImageTransparency = 1
	end
	if n.Flame then
		n.Flame.ImageTransparency = 1
	end
end

-- nothing new for a while: one last pop, then the tag lifts away and fades, then resets
local function closeAfter(t: Tag, hold: number)
	local serial = t.Serial
	task.delay(hold, function()
		if t.Serial ~= serial or not t.Gui.Parent then
			return
		end
		t.Closing = true
		local n = t.Num
		tween(n.Scale, 0.12, { Scale = n.Scale.Scale * 1.1 }, Enum.EasingStyle.Quad)
		sweepGrad(n.Shine, 0)
		task.delay(0.12, function()
			if t.Serial ~= serial then
				return
			end
			tween(t.Gui, 0.34, { StudsOffset = HOME + Vector3.new(0, 0.9, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(t.Pop, 0.34, { Scale = 0.85 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			fadeLabels(n.Labels, 1, 0.24)
			if n.Rays then
				tween(n.Rays, 0.24, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
			end
			if n.Flame then
				tween(n.Flame, 0.2, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
			end
			if t.Title then
				wordOut(t.Title, 0.02)
			end
			pillShow(t, false)
		end)
		task.delay(0.52, function()
			if t.Serial ~= serial then
				return
			end
			t.Active = false
			t.Closing = false
			t.Gui.Enabled = false
			clear(t)
			if t.Title then
				t.Title.Root:Destroy()
				t.Title = nil
			end
		end)
	end)
end

---------------------------------------------------------------------------
-- damage (your own hits)
---------------------------------------------------------------------------
local PUNCH = {
	-- kick scale, tilt, stars, shine, heat added, flash strength
	Light = { 1.22, 5, 0, false, 0.16, 0.55 },
	Heavy = { 1.36, 8, 6, true, 0.3, 0.8 },
	Finisher = { 1.48, 10, 12, true, 0.5, 1 },
	Break = { 1.52, 9, 0, true, 0.35, 1 }, -- (the break itself brings the stars)
	Block = { 1.1, 3, 0, false, 0.04, 0.3 },
}

local function paintNum(t: Tag, k: string)
	local n = t.Num
	if k == "Block" then
		paintGrad(n.Grad, SILVER[1], SILVER[2], 0)
	elseif t.Red then
		paintGrad(n.Grad, RED[1], RED[2], math.min(1, t.Heat * 0.8))
	else
		paintGrad(n.Grad, t.Accent, t.Deep, t.Heat)
	end
end

function Callout.Damage(victim: Model, amount: number, kind: string?, attacker: Model?)
	if not (victim and amount and amount > 0) then
		return
	end
	local t = tagFor(victim)
	if not t then
		return
	end
	local k = kind or "Light"
	local p = PUNCH[k] or PUNCH.Light
	local now = os.clock()
	if not t.Active or not t.HasNum or now - t.Last > RESET then
		clear(t)
	end
	t.Last = now
	open(t)
	local n = t.Num

	t.Hits += 1
	t.Heat = math.min(1, t.Heat + p[5])
	local accent, deep = Callout.ColorsFor(attacker)
	t.Accent, t.Deep = accent, deep
	-- the number burns red on a guard break and from the flame on
	if k == "Break" or (k ~= "Block" and t.Hits >= FLAME_AT) then
		t.Red = true
	end
	paintNum(t, k)
	pillShow(t, k == "Block")

	-- the new total goes straight in: one label, a quick count-up from where it stood
	local first = not t.HasNum
	t.Total += amount
	if first then
		t.HasNum = true
		t.Shown = t.Total
		numText(n, fmt(t.Total))
		fadeLabels(n.Labels, 0, 0.05)
	end

	-- it rests a little bigger every hit of the string
	local base = 1 + 0.05 * math.min(t.Hits - 1, 6)
	-- the punch: a kick in size, a sideways jolt, tipped the other way each hit, settling on a bounce
	t.Flip = not t.Flip
	n.Scale.Scale = base * p[1]
	tween(n.Scale, 0.3, { Scale = base }, Enum.EasingStyle.Back)
	n.Root.Rotation = if t.Flip then -p[2] else p[2]
	tween(n.Root, 0.34, { Rotation = 0 }, Enum.EasingStyle.Back)
	n.Root.Position = NUM_HOME + UDim2.fromOffset(if t.Flip then -12 else 12, -7)
	tween(n.Root, 0.3, { Position = NUM_HOME }, Enum.EasingStyle.Back)
	flashFace(n, p[6])

	-- the sunburst comes up behind from the 3rd hit (tight round the digits), the flame lights with
	-- the red from the 5th
	if n.Rays then
		n.Rays.ImageColor3 = if t.Red then lighten(RED[1], 0.45) else lighten(accent, 0.35)
		local on = if k ~= "Block" and t.Hits >= 3 then math.clamp((t.Hits - 2) / 4, 0.3, 1) else 0
		if k == "Break" then
			on = 1
		end
		tween(n.Rays, 0.25, { ImageTransparency = 1 - 0.5 * on, Size = UDim2.fromOffset(84 + 20 * on, 84 + 20 * on) }, Enum.EasingStyle.Quad)
	end
	if n.Flame and n.FlameScale then
		if t.Red and k ~= "Block" then
			if n.Flame.ImageTransparency > 0.5 then
				-- lights with a pop: from a spark to full size
				local full = n.Size * 0.74
				n.Flame.Size = UDim2.fromOffset(full * 0.35, full * 0.35)
				tween(n.Flame, 0.28, { Size = UDim2.fromOffset(full, full) }, Enum.EasingStyle.Back)
				tween(n.Flame, 0.12, { ImageTransparency = 0 }, Enum.EasingStyle.Quad)
			end
		elseif not t.Red then
			tween(n.Flame, 0.15, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
		end
	end

	-- shine, stars, milestones, finisher
	if p[4] then
		sweepGrad(n.Shine, 0.06)
	end
	if p[3] > 0 then
		stars(t.Stage, if t.Red then RED[1] else accent, p[3], 70 + 10 * p[3], 2, NUM_HOME)
	end
	if t.Hits >= 5 and t.Hits % 5 == 0 and k ~= "Block" then
		stars(t.Stage, if t.Red then RED[1] else accent, 10, 150, 2, NUM_HOME)
		sweepGrad(n.Shine, 0.1)
		Kit.shake(t.Stage)
	end
	if k == "Finisher" then
		-- white-hot for a beat, then back to the hot colours; a hard shake
		paintGrad(n.Grad, WHITE, if t.Red then RED[1] else lighten(accent, 0.4), 1)
		task.delay(0.12, function()
			if t.HasNum then
				paintNum(t, k)
			end
		end)
		Kit.shake(t.Stage)
	end
	closeAfter(t, if k == "Finisher" or k == "Break" or t.Title then 1.6 else 1.1)
end

-- the server's number for a blow already stamped (predicted on the attacker's own impact frame):
-- the total moves by the difference and counts to it - no punch, no new hit in the string
function Callout.Correct(victim: Model, delta: number)
	local t = tags[victim]
	if not (t and t.HasNum and t.Gui.Parent) or math.abs(delta) < 1e-3 then
		return
	end
	t.Total = math.max(0, t.Total + delta)
end

---------------------------------------------------------------------------
-- guard break (everyone): the same tag; GUARD BREAK! drops in letter by letter above the number.
-- The number itself is the attacker's Damage("Break") for the same blow (it lands right after):
-- nothing here touches it, so the break shows one number, stamped once.
---------------------------------------------------------------------------
function Callout.GuardBreak(char: Model, attacker: Model?)
	local t = tagFor(char)
	if not t then
		return
	end
	local accent, deep = Callout.ColorsFor(attacker)
	open(t)
	pillShow(t, false)
	if t.Title then
		t.Title.Root:Destroy()
	end
	local w = newWord(t.TitleHolder, "GUARD BREAK!", 42, accent, deep, 8)
	t.Title = w
	wordIn(w, 0.028)
	wordShine(w, 0.45)
	wordShine(w, 1.1)
	task.delay(0.1, function()
		if t.Gui.Parent then
			stars(t.Stage, accent, 12, 210, 2, UDim2.new(0.5, 0, 0.5, -52))
			Kit.shake(t.Stage)
		end
	end)
	closeAfter(t, 1.6)

	-- the two fighters involved: a white flash; the one whose guard broke: the banner too
	local me = Players.LocalPlayer
	local mine = me and me.Character
	if mine and mine == char then
		Callout.Flash(0.6)
		Callout.Banner("GUARD BROKEN", accent, deep)
	elseif mine and mine == attacker then
		Callout.Flash(0.35)
	end
end

---------------------------------------------------------------------------
-- white flash over your own screen
---------------------------------------------------------------------------
function Callout.Flash(strength: number)
	local me = Players.LocalPlayer
	local pg = me and me:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatFlash"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.Parent = pg
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = WHITE
	f.BackgroundTransparency = 1 - math.clamp(strength, 0, 1)
	f.BorderSizePixel = 0
	f.Parent = gui
	tween(f, 0.24, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
	task.delay(0.3, function()
		gui:Destroy()
	end)
end

---------------------------------------------------------------------------
-- the lettering across the top of your own screen
---------------------------------------------------------------------------
local bannerGui: ScreenGui? = nil
function Callout.Banner(text: string, accent: Color3, deep: Color3)
	if not Kit then
		return
	end
	local me = Players.LocalPlayer
	local pg = me and me:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	if bannerGui then
		bannerGui:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatBanner"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global -- (the letters' shadow / outline / face bands)
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 22
	gui.Parent = pg
	bannerGui = gui

	-- scaled like the HUD
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local s = math.clamp(math.min(vp.X / 1920, vp.Y / 1080), Theme.MinScale or 0.5, Theme.MaxScale or 1.35)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0, 170 * s)
	holder.Size = UDim2.fromOffset(720, 140)
	holder.Rotation = -3
	holder.Parent = gui
	local fit = Instance.new("UIScale")
	fit.Scale = s
	fit.Parent = holder
	local w = newWord(holder, text, 66, accent, deep, 4)
	wordIn(w, 0.03)
	wordShine(w, 0.5)
	task.delay(0.12, function()
		if holder.Parent then
			stars(holder, accent, 12, 320, 1)
			Kit.shake(holder)
		end
	end)
	local conn = RunService.Heartbeat:Connect(function()
		wordWave(w, os.clock())
	end)
	task.delay(1.25, function()
		if gui.Parent then
			wordOut(w, 0.025)
		end
	end)
	task.delay(1.75, function()
		conn:Disconnect()
		if bannerGui == gui then
			bannerGui = nil
		end
		gui:Destroy()
	end)
end

return Callout
