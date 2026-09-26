--[[
	ComboCounter  (StarterPlayerScripts.CombatClient.ComboCounter)
	The fighting-game combo meter at the side of the screen, built from the HUD's own Kit so it
	reads as one more piece of the Overkill HUD (the same navy pill cards, accent icon discs, ink
	outlines, Fredoka lettering, shine sweeps, sunburst and star art as the dock and the toasts):

	          ★ BRUTAL! ★             rank stamp: slams in when the rank goes up (2 NICE, 3 GREAT,
	            X 4                   4 BRUTAL, 5+ SAVAGE; the finisher OVERKILL!, a break GUARD BREAK!)
	    ( ) COMBO  [=======   ]       the count, gold / pink (heavy) / red (finisher); the combo card:
	           14 DMG                 a pill card with the rank's icon disc, "COMBO" and the combo
	                                  window draining; the combo's damage in a pill under it

	ONE NUMBER PER THING: the count is a single label (no shadow copy, no ghost behind it), the damage
	is a single label. Each hit stamps them in and flashes their own faces - never a second number.

	It counts CONFIRMED hits of the current combo (the server's count), never button presses:
	  Counter.Hit(count, kind, info)  kind = "Light" | "Heavy" | "Finisher" | "Break";
	                                  info = { Damage = this hit's damage, Window = seconds left to
	                                  land the next one }. Shows from 2 hits.
	  Counter.Drop()                  the combo ended: the meter slides away
	  Counter.Shown()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

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

if not (Kit and Theme) then
	-- the HUD kit is missing: combat still runs, the meter just stays hidden
	local shown = false
	return {
		Hit = function() end,
		Drop = function() end,
		Shown = function()
			return shown
		end,
	}
end

local Counter = {}
local C = Theme.C
local new, tween = Kit.new, Kit.tween
local DISPLAY = Theme.Font.Display
local WHITE = Color3.new(1, 1, 1)

---------------------------------------------------------------------------
-- build (reference size 1920x1080, scaled like the HUD)
---------------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "ComboCounter",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 21,
	Parent = player:WaitForChild("PlayerGui"),
})
local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
local fit = new("UIScale", { Name = "Fit", Parent = root })

-- one centred column; everything shares its centre line
local W, H = 380, 350
local REST = UDim2.new(1, -26 - W / 2, 0.44, 0)
local OUT = UDim2.new(1, W / 2 + 80, 0.44, 0)
local Y_RANK, Y_COUNT, Y_CARD, Y_DMG = 44, 142, 252, 320

local col = new("Frame", {
	Name = "Counter",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = OUT,
	Size = UDim2.fromOffset(W, H),
	Visible = false,
	Parent = root,
})
local colScale = new("UIScale", { Parent = col })
-- everything rides in `body` (it shakes; the column itself only slides in and out)
local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = col })

-- the sunburst + glow behind the count (the pack's art)
local rays = Kit.rays(body, C.Gold, 300, 0.7, 1, true)
rays.Position = UDim2.fromOffset(W / 2, Y_COUNT)
local glow = Kit.image({
	Name = "Glow",
	Image = Theme.Icon.Glow,
	ImageColor3 = C.Gold,
	ImageTransparency = 0.6,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(W / 2, Y_COUNT),
	Size = UDim2.fromOffset(280, 210),
	ZIndex = 1,
	Parent = body,
})

-- lettering: one label with the HUD's ink outline and a gradient face; its shine is the same text
-- masked to a moving band, its flash the same text on the same spot (invisible until a hit)
local function shineGradient(parent: Instance): UIGradient
	return new("UIGradient", {
		Rotation = 20,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.47, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.1),
			NumberSequenceKeypoint.new(0.54, 0.6),
			NumberSequenceKeypoint.new(0.62, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1.3, 0),
		Parent = parent,
	})
end

local function lettering(parent: Instance, name: string, textSize: number, stroke: number, size: Vector2, z: number)
	local holder = new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size.X, size.Y),
		ZIndex = z,
		Parent = parent,
	})
	local scale = new("UIScale", { Parent = holder })
	local function layer(n: string, zz: number): TextLabel
		return new("TextLabel", {
			Name = n,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			FontFace = DISPLAY,
			RichText = true,
			Text = "",
			TextSize = textSize,
			TextColor3 = WHITE,
			ZIndex = zz,
			Parent = holder,
		})
	end
	local face = layer("Face", z)
	Kit.stroke(face, stroke)
	local grad = new("UIGradient", { Rotation = 90, Parent = face })
	local shine = layer("Shine", z + 1)
	local shineGrad = shineGradient(shine)
	local flash = layer("Flash", z + 2)
	flash.TextTransparency = 1
	local api = { Holder = holder, Scale = scale, Face = face, Grad = grad, Shine = shine, ShineGrad = shineGrad, Flash = flash }
	function api.Set(text: string)
		face.Text = text
		shine.Text = text
		flash.Text = text
	end
	function api.Sweep(delay: number?)
		task.delay(delay or 0, function()
			shineGrad.Offset = Vector2.new(-1.3, 0)
			tween(shineGrad, 0.45, { Offset = Vector2.new(1.3, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		end)
	end
	function api.Blink(strength: number)
		flash.TextTransparency = math.clamp(1 - strength, 0, 1)
		tween(flash, 0.18, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
	end
	function api.Paint(a: Color3, d: Color3)
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(a, 0.55)),
			ColorSequenceKeypoint.new(0.5, a),
			ColorSequenceKeypoint.new(1, d),
		})
	end
	return api
end

-- the rank stamp, flanked by two stars
local rank = lettering(body, "Rank", 40, 5, Vector2.new(W, 52), 6)
rank.Holder.Position = UDim2.fromOffset(W / 2, Y_RANK)
rank.Holder.Rotation = -5
local rankStars = {}
for i, side in ipairs({ -1, 1 }) do
	rankStars[i] = Kit.image({
		Name = "Star" .. i,
		Image = Theme.Icon.Star,
		ImageColor3 = C.Gold,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(W / 2 + side * 110, Y_RANK),
		Size = UDim2.fromOffset(26, 26),
		ImageTransparency = 1,
		ZIndex = 6,
		Parent = body,
	})
	rankStars[i]:SetAttribute("Side", side)
end

-- the count: "X" + the number (rich text, so the X sits on the digits' baseline)
local count = lettering(body, "Count", 124, 9, Vector2.new(W, 136), 4)
count.Holder.Position = UDim2.fromOffset(W / 2, Y_COUNT)
count.Holder.Rotation = -4

-- the combo card: a HUD pill card (navy gradient, ink outline), the icon disc in its left end,
-- "COMBO" and the combo window draining under it
local CARD_W, CARD_H = 300, 76
local card = Kit.plate({
	Name = "Card",
	Parent = body,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(W / 2, Y_CARD),
	Size = UDim2.fromOffset(CARD_W, CARD_H),
	Radius = UDim.new(1, 0),
	Stroke = 4.5,
	Gradient = { C.Navy700, C.Night },
	ZIndex = 10,
})
local cardFx = Kit.fx(card)
local disc = Kit.endIcon({
	Parent = card,
	Name = "Disc",
	Side = "Left",
	Width = CARD_H,
	Gap = 6,
	Stroke = 3.5,
	Band = { C.Navy700, C.Night, 90 },
	Face = { Kit.lighten(C.Gold, 0.15), C.GoldDeep, 90 },
	ZIndex = 11,
})
-- the disc's flame with its ink outline (the same line as the damage numbers' flame): the flame
-- art in ink laid behind it a line's width out in 16 directions, so the outline follows every edge
-- at one even width and never crosses the flame. This gui sorts siblings, so the ink and the flame
-- are siblings in one holder: the ink first, the flame over it.
do
	local FLAME = 40
	local inkW = FLAME * 0.072
	local holder = Instance.new("Frame")
	holder.Name = "Flame"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(FLAME, FLAME)
	holder.ZIndex = disc.ContentZ
	holder.Parent = disc.Frame
	for i = 1, 16 do
		local a = (i - 1) / 16 * math.pi * 2
		Kit.image({
			Name = "Ink",
			Image = Theme.Icon.Flame,
			ImageColor3 = C.Ink,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.cos(a) * inkW, 0.5, math.sin(a) * inkW),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = holder,
		})
	end
	Kit.image({
		Name = "Fire",
		Image = Theme.Icon.Flame,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = holder,
	})
end
local sheen = Kit.addShine(card, UDim.new(1, 0))
sheen.ZIndex = 16
Kit.outlineOnTop(card, 20)

local TEXT_X = CARD_H + 12
local title = Kit.text({
	Name = "Title",
	Text = "COMBO",
	TextSize = 30,
	TextColor3 = C.Gold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(TEXT_X, 7),
	Size = UDim2.fromOffset(CARD_W - TEXT_X - 24, 32),
	ZIndex = 13,
	Stroke = 3.5,
	Parent = card,
})
-- the combo window: a HUD bar (pill track, accent fill, the outline over the fill)
local BAR_W, BAR_H = CARD_W - TEXT_X - 26, 15
local track = new("Frame", {
	Name = "Window",
	BackgroundColor3 = C.Night,
	Position = UDim2.fromOffset(TEXT_X, 45),
	Size = UDim2.fromOffset(BAR_W, BAR_H),
	ZIndex = 13,
	Parent = card,
})
Kit.pill(track)
Kit.stroke(track, 2.4, C.Ink, 0, true)
local fill = new("Frame", {
	Name = "Fill",
	BackgroundColor3 = WHITE,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 13,
	Parent = track,
})
Kit.pill(fill)
local fillGrad = Kit.gradient(fill, C.Gold, C.GoldDeep, 90)
Kit.outlineOnTop(track, 14)

-- the combo's damage: a small pill under the card, "14 DMG"
local dmgPill = Kit.plate({
	Name = "Damage",
	Parent = body,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(W / 2, Y_DMG),
	Size = UDim2.fromOffset(0, 40),
	AutomaticSize = Enum.AutomaticSize.X,
	Radius = UDim.new(1, 0),
	Stroke = 3.5,
	Gradient = { C.Navy800, C.Night },
	ZIndex = 10,
})
local dmgFx = Kit.fx(dmgPill)
Kit.padding(dmgPill, 18, 0, 18, 0)
Kit.list(dmgPill, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
local dmgValue = Kit.text({
	Name = "Value",
	Text = "0",
	TextSize = 28,
	Size = UDim2.new(0, 0, 1, 0),
	AutomaticSize = Enum.AutomaticSize.X,
	LayoutOrder = 1,
	ZIndex = 11,
	Stroke = 3.2,
	Parent = dmgPill,
})
local dmgGrad = Kit.gradient(dmgValue, Kit.lighten(C.Gold, 0.45), C.GoldDeep, 90)
Kit.text({
	Name = "Unit",
	Text = "DMG",
	TextSize = 19,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextSoft,
	Size = UDim2.new(0, 0, 1, 2),
	AutomaticSize = Enum.AutomaticSize.X,
	LayoutOrder = 2,
	ZIndex = 11,
	Stroke = 2.6,
	Parent = dmgPill,
})
local dmgCount = new("NumberValue", { Name = "Count", Value = 0, Parent = dmgValue })
dmgCount.Changed:Connect(function(v)
	dmgValue.Text = tostring(math.floor(v + 0.5))
end)

local function rescale()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	if vp.X < 2 or vp.Y < 2 then
		return
	end
	local ref = Theme.Reference or Vector2.new(1920, 1080)
	local s = math.min(vp.X / ref.X, vp.Y / ref.Y)
	s = math.clamp(s, Theme.MinScale or 0.5, Theme.MaxScale or 1.35)
	fit.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
end
rescale()
local camConn: RBXScriptConnection? = nil
local function watchCamera()
	if camConn then
		camConn:Disconnect()
	end
	local cam = workspace.CurrentCamera
	if cam then
		camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
end
watchCamera()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	rescale()
	watchCamera()
end)

---------------------------------------------------------------------------
-- look + motion
---------------------------------------------------------------------------
local PAINT = {
	Light = { C.Gold, C.GoldDeep },
	Heavy = { C.Pink, C.PinkDeep },
	Finisher = { C.Red, C.RedDeep },
}
-- a guard break is painted in your hero's colours (OverkillUI.HeroConfig), like the hit tag
local function palette(kind: string): { Color3 }
	if kind == "Break" then
		local id = player.Character and player.Character:GetAttribute("Hero")
		local h = HeroConfig and HeroConfig.Heroes and type(id) == "string" and HeroConfig.Heroes[id]
		if h and h.Accent and typeof(h.Accent[1]) == "Color3" then
			return { h.Accent[1], h.Accent[2] or Kit.darken(h.Accent[1], 0.35) }
		end
		return { C.Red, C.RedDeep }
	end
	return PAINT[kind] or PAINT.Light
end

local RANKS = { [2] = "NICE!", [3] = "GREAT!", [4] = "BRUTAL!" }
local function rankFor(n: number, kind: string): (string, string)
	if kind == "Finisher" then
		return "OVERKILL!", "Finisher"
	elseif kind == "Break" then
		return "GUARD BREAK!", "Break"
	end
	if n >= 5 then
		return "SAVAGE!", "Heavy"
	end
	return RANKS[n] or "", if n >= 4 then "Heavy" else "Light"
end

-- rank words' widths, measured once up front (TextService yields; never during a hit)
local rankWidth: { [string]: number } = {}
task.spawn(function()
	for _, w in ipairs({ "NICE!", "GREAT!", "BRUTAL!", "SAVAGE!", "OVERKILL!", "GUARD BREAK!" }) do
		rankWidth[w] = Kit.textWidth(w, 40)
	end
end)

local function paint(kind: string)
	local c = palette(kind)
	count.Paint(c[1], c[2])
	fillGrad.Color = ColorSequence.new(c[1], c[2])
	if disc.Face then
		disc.Face.Color = ColorSequence.new(Kit.lighten(c[1], 0.15), c[2])
	end
	title.TextColor3 = c[1]
	dmgGrad.Color = ColorSequence.new(Kit.lighten(c[1], 0.45), c[2])
	rays.ImageColor3 = c[1]
	glow.ImageColor3 = c[1]
end

local shown = false
local serial = 0
local total = 0
local lastRank = ""
local drain: Tween? = nil

local function starBurst(color: Color3, n: number, reach: number)
	for i = 1, n do
		local a = (i / n) * math.pi * 2 + math.random() * 0.5
		local star = Kit.image({
			Name = "Star",
			Image = Theme.Icon.Star,
			ImageColor3 = if i % 2 == 0 then WHITE else color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(W / 2, Y_COUNT),
			Size = UDim2.fromOffset(22, 22),
			Rotation = math.random(0, 90),
			ZIndex = 2,
			Parent = body,
		})
		local r = reach * (0.75 + math.random() * 0.4)
		tween(star, 0.55, {
			Position = UDim2.fromOffset(W / 2 + math.cos(a) * r, Y_COUNT + math.sin(a) * r * 0.7),
			Rotation = star.Rotation + 180,
			Size = UDim2.fromOffset(8, 8),
			ImageTransparency = 1,
		}, Enum.EasingStyle.Quart)
		task.delay(0.6, function()
			star:Destroy()
		end)
	end
end

local function setWindow(seconds: number?)
	if drain then
		drain:Cancel()
		drain = nil
	end
	fill.Visible = true
	fill.Size = UDim2.fromScale(1, 1)
	if not seconds then
		return -- the finisher: the bar stays full, the combo is done
	end
	drain = TweenService:Create(fill, TweenInfo.new(math.max(0.05, seconds), Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })
	;(drain :: Tween).Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			fill.Visible = false
		end
	end)
	;(drain :: Tween):Play()
end

local function stampRank(word: string, kind: string)
	rank.Set(word)
	local c = palette(kind)
	rank.Paint(c[1], c[2])
	rank.Scale.Scale = 1.9
	rank.Holder.Rotation = -16
	tween(rank.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(rank.Holder, 0.32, { Rotation = -5 }, Enum.EasingStyle.Back)
	rank.Blink(1)
	rank.Sweep(0.18)
	local half = (rankWidth[word] or #word * 40 * 0.62) / 2
	for _, s in ipairs(rankStars) do
		local side = s:GetAttribute("Side") :: number
		s.ImageColor3 = Kit.lighten(c[1], 0.25)
		s.Position = UDim2.fromOffset(W / 2 + side * (half * 0.6), Y_RANK)
		s.Size = UDim2.fromOffset(10, 10)
		s.ImageTransparency = 0
		s.Rotation = 0
		tween(s, 0.32, { Position = UDim2.fromOffset(W / 2 + side * (half + 26), Y_RANK - 2), Size = UDim2.fromOffset(26, 26), Rotation = side * 90 }, Enum.EasingStyle.Back)
	end
end

function Counter.Hit(n: number, kindIn: string?, info: any?)
	local kind: string = kindIn or "Light"
	local dmg = if type(info) == "table" and type(info.Damage) == "number" then info.Damage else 0
	if n <= 1 or not shown then
		total = if n <= 1 then dmg else total + dmg
	else
		total += dmg
	end
	if n < 2 then
		return
	end
	serial += 1
	local my = serial

	-- in (from the right, popping up) or already up
	if not shown then
		shown = true
		col.Visible = true
		col.Position = OUT
		colScale.Scale = 0.7
		tween(col, 0.3, { Position = REST }, Enum.EasingStyle.Back)
		tween(colScale, 0.34, { Scale = 1 }, Enum.EasingStyle.Back)
		for _, s in ipairs(rankStars) do
			s.ImageTransparency = 1
		end
		lastRank = ""
	else
		tween(col, 0.12, { Position = REST }, Enum.EasingStyle.Quad)
		tween(colScale, 0.12, { Scale = 1 }, Enum.EasingStyle.Quad)
	end
	paint(kind)

	-- the count: stamped in, a heavier blow punches harder, twists and flashes
	count.Set(string.format('<font size="66">X</font>%d', n))
	local big = if kind == "Finisher" then 1.75 elseif kind == "Heavy" or kind == "Break" then 1.55 else 1.35
	count.Scale.Scale = big
	tween(count.Scale, if kind == "Light" then 0.2 else 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
	count.Holder.Rotation = if kind == "Light" then -9 else (if n % 2 == 0 then -14 else 5)
	tween(count.Holder, 0.26, { Rotation = -4 }, Enum.EasingStyle.Back)
	count.Blink(if kind == "Light" then 0.6 else 0.95)
	if kind ~= "Light" or n % 5 == 0 then
		count.Sweep(0.05)
	end

	-- the rank stamp when it goes up
	local word, wordKind = rankFor(n, kind)
	if word ~= lastRank then
		lastRank = word
		stampRank(word, wordKind)
	end

	-- the card: a bump, the icon disc wiggles, the shine sweeps, the window refills and drains
	cardFx.Scale = if kind == "Light" then 1.06 else 1.12
	tween(cardFx, 0.24, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.wiggle(disc.Frame, if kind == "Light" then 0.5 else 1)
	Kit.playShine(sheen)
	local window = if type(info) == "table" then info.Window else nil
	setWindow(if kind == "Finisher" then nil else window)

	-- the damage: counts up to the combo's total, the pill bumps
	tween(dmgCount, 0.35, { Value = total }, Enum.EasingStyle.Quart)
	dmgFx.Scale = 1.12
	tween(dmgFx, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)

	-- the sunburst flares, stars on the heavy blows, a shake on the finisher
	rays.Size = UDim2.fromOffset(210, 210)
	rays.ImageTransparency = 0.45
	tween(rays, 0.4, { Size = UDim2.fromOffset(if kind == "Light" then 300 else 370, if kind == "Light" then 300 else 370), ImageTransparency = 0.7 }, Enum.EasingStyle.Quart)
	glow.ImageTransparency = 0.35
	tween(glow, 0.4, { ImageTransparency = 0.6 }, Enum.EasingStyle.Quad)
	if kind ~= "Light" then
		starBurst(palette(kind)[1], if kind == "Finisher" then 14 else 8, if kind == "Finisher" then 190 else 140)
	elseif n % 5 == 0 then
		starBurst(palette("Heavy")[1], 10, 150)
	end
	if kind == "Finisher" or kind == "Break" then
		Kit.shake(body)
	end
	-- a heavy blow's colour flashes, then the meter settles back to its rank's colour
	if kind ~= "Light" and kind ~= "Finisher" then
		task.delay(0.35, function()
			if serial == my then
				paint(if n >= 4 then "Heavy" else "Light")
			end
		end)
	end
	if kind == "Finisher" then
		-- the combo is complete: hold the final count a beat, then go
		task.delay(1.3, function()
			if serial == my then
				Counter.Drop()
			end
		end)
	end
end

function Counter.Drop()
	if not shown then
		return
	end
	shown = false
	serial += 1
	local my = serial
	setWindow(0)
	tween(col, 0.26, { Position = OUT }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	tween(colScale, 0.26, { Scale = 0.75 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.28, function()
		if serial == my then
			col.Visible = false
			lastRank = ""
			rank.Set("")
			total = 0
			dmgCount.Value = 0
			paint("Light")
		end
	end)
end

function Counter.Shown(): boolean
	return shown
end

return Counter
