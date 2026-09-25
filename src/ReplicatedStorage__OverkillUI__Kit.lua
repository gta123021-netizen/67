--[[
	Kit  (ReplicatedStorage.OverkillUI.Kit)
	The building blocks every Overkill window is made from: chunky 3D buttons, windows,
	pills, outlined text, and the motion (hover, press, shine, wiggle, pop, count-up).
	Motion ideas come from JakeDev's UI Animation Pack; everything is rebuilt to share one style.
]]

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local C = Theme.C

local Kit = {}
Kit.Theme = Theme

---------------------------------------------------------------------------
-- basics
---------------------------------------------------------------------------
local CUSTOM = {
	Stroke = true,
	StrokeColor = true,
	StrokeTransparency = true,
	Children = true,
}

function Kit.new(class: string, props: { [string]: any }?, children: { Instance }?): any
	local o = Instance.new(class)
	local parent = nil
	if props then
		for k, v in pairs(props) do
			if k == "Parent" then
				parent = v
			elseif not CUSTOM[k] then
				(o :: any)[k] = v
			end
		end
	end
	if children then
		for _, c in ipairs(children) do
			c.Parent = o
		end
	end
	if parent then
		o.Parent = parent
	end
	return o
end
local new = Kit.new

function Kit.corner(parent: Instance, r: any): UICorner
	return new("UICorner", {
		CornerRadius = if typeof(r) == "UDim" then r else UDim.new(0, r or 12),
		Parent = parent,
	})
end

function Kit.pill(parent: Instance): UICorner
	return Kit.corner(parent, UDim.new(1, 0))
end

-- Border strokes sit centred on the edge (half inside, half outside), so the outline always
-- covers the anti-aliased rim of the fill and of any child clipped to the same shape: no slivers
-- of the world peeking through between a rounded panel and its outline.
function Kit.stroke(parent: Instance, thickness: number, color: Color3?, transparency: number?, border: boolean?): UIStroke
	local st = new("UIStroke", {
		Thickness = if border then thickness * 1.35 else thickness,
		Color = color or C.Ink,
		Transparency = transparency or 0,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
	if border then
		pcall(function()
			(st :: any).BorderStrokePosition = (Enum :: any).BorderStrokePosition.Center
		end)
	end
	st.Parent = parent
	return st
end

function Kit.gradient(parent: Instance, c1: Color3, c2: Color3?, rotation: number?, t1: number?, t2: number?): UIGradient
	return new("UIGradient", {
		Color = ColorSequence.new(c1, c2 or c1),
		Rotation = rotation or 90,
		Transparency = NumberSequence.new(t1 or 0, t2 or t1 or 0),
		Parent = parent,
	})
end

function Kit.padding(parent: Instance, l: number, t: number?, r: number?, b: number?): UIPadding
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l),
		PaddingTop = UDim.new(0, t or l),
		PaddingRight = UDim.new(0, r or l),
		PaddingBottom = UDim.new(0, b or t or l),
		Parent = parent,
	})
end

function Kit.list(parent: Instance, dir: Enum.FillDirection, pad: number, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?): UIListLayout
	return new("UIListLayout", {
		FillDirection = dir,
		Padding = UDim.new(0, pad),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
end

function Kit.darken(c: Color3, a: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), a)
end

function Kit.lighten(c: Color3, a: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), a)
end

-- outlined display text. Stroke = false turns the outline off.
function Kit.text(props: { [string]: any }): TextLabel
	local size = props.TextSize or 24
	local base = {
		Name = "Label",
		BackgroundTransparency = 1,
		FontFace = Theme.Font.Display,
		TextColor3 = C.Text,
		TextSize = size,
		Text = "",
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
	}
	for k, v in pairs(props) do
		base[k] = v
	end
	local lbl = new(props.Class or "TextLabel", base)
	if props.Stroke ~= false then
		Kit.stroke(lbl, props.Stroke or math.max(1.6, size * 0.11), props.StrokeColor or C.Ink, props.StrokeTransparency or 0)
	end
	return lbl
end
CUSTOM.Class = true

function Kit.image(props: { [string]: any }): ImageLabel
	local base = {
		Name = "Icon",
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromScale(1, 1),
	}
	for k, v in pairs(props) do
		base[k] = v
	end
	return new(props.Class or "ImageLabel", base)
end

-- exact width of a line of display text (unaffected by UIScale)
local widthCache: { [string]: number } = {}
function Kit.textWidth(text: string, size: number, font: Font?): number
	local key = text .. "|" .. size .. "|" .. (if font then font.Family .. tostring(font.Weight) else "d")
	if widthCache[key] then
		return widthCache[key]
	end
	local ok, v = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = font or Theme.Font.Display
		params.Size = size
		params.Width = 4000
		return game:GetService("TextService"):GetTextBoundsAsync(params)
	end)
	if ok and typeof(v) == "Vector2" then
		widthCache[key] = math.ceil(v.X)
		return widthCache[key]
	end
	return math.ceil(#text * size * 0.64)
end

-- height of wrapped text in a box of the given width (reference pixels)
function Kit.textHeight(text: string, size: number, width: number, font: Font?): number
	local ok, v = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = font or Theme.Font.Display
		params.Size = size
		params.Width = width
		return game:GetService("TextService"):GetTextBoundsAsync(params)
	end)
	if ok and typeof(v) == "Vector2" then
		return math.ceil(v.Y)
	end
	return size * 1.25 * math.max(1, math.ceil(#text * size * 0.55 / math.max(1, width)))
end

---------------------------------------------------------------------------
-- motion
---------------------------------------------------------------------------
function Kit.tween(o: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?, delay: number?): Tween
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out, 0, false, delay or 0), props)
	tw:Play()
	return tw
end
local tween = Kit.tween

function Kit.fx(o: Instance): UIScale
	local s = o:FindFirstChild("FX")
	if not s then
		s = new("UIScale", { Name = "FX", Parent = o })
	end
	return s :: UIScale
end

local sounds: { [string]: Sound } = {}
function Kit.sfx(name: string)
	local def = Theme.Sound[name]
	if not def or (def.Volume or 0) <= 0 then
		return
	end
	local s = sounds[name]
	if not s then
		s = new("Sound", {
			Name = "OverkillUI_" .. name,
			SoundId = def.Id,
			Volume = def.Volume or 0.5,
			PlaybackSpeed = def.Speed or 1,
			SoundGroup = SoundService:FindFirstChild("SFX"),
			Parent = SoundService,
		})
		sounds[name] = s
	end
	pcall(function()
		SoundService:PlayLocalSound(s)
	end)
end

-- a quick side-to-side shake (wrong input, not enough coins...)
function Kit.shake(o: GuiObject)
	local home = o:GetAttribute("ShakeHome")
	if not home then
		o:SetAttribute("ShakeHome", o.Position)
		home = o.Position
	end
	task.spawn(function()
		for i, dx in ipairs({ 10, -9, 7, -5, 3, 0 }) do
			o.Position = home + UDim2.fromOffset(dx, 0)
			task.wait(0.035)
		end
		o.Position = home
	end)
end

-- icon wiggle (Icon Wiggle On Hover)
function Kit.wiggle(o: GuiObject, strength: number?)
	local s = strength or 1
	if o:GetAttribute("Wiggling") then
		return
	end
	o:SetAttribute("Wiggling", true)
	task.spawn(function()
		for _, r in ipairs({ -13, 11, -7, 4, 0 }) do
			tween(o, 0.08, { Rotation = r * s }, Enum.EasingStyle.Sine).Completed:Wait()
		end
		o:SetAttribute("Wiggling", nil)
	end)
end

-- glossy sweep across a rounded frame (Shine Effect)
function Kit.addShine(face: GuiObject, corner: any): Frame
	local sheen = new("Frame", {
		Name = "Shine",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = face.ZIndex + 5,
		Parent = face,
	})
	Kit.corner(sheen, corner)
	new("UIGradient", {
		Rotation = 18,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.38, 1),
			NumberSequenceKeypoint.new(0.47, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(0.56, 0.7),
			NumberSequenceKeypoint.new(0.62, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1.2, 0),
		Parent = sheen,
	})
	return sheen
end

function Kit.playShine(sheen: Frame?)
	if not sheen then
		return
	end
	local g = sheen:FindFirstChildOfClass("UIGradient")
	if not g then
		return
	end
	g.Offset = Vector2.new(-1.2, 0)
	tween(g, 0.55, { Offset = Vector2.new(1.2, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
end

-- number that rolls up / down to its new value
function Kit.counter(label: TextLabel, format: (number) -> string, start: number?)
	local value = new("NumberValue", { Name = "Count", Value = start or 0, Parent = label })
	local function show()
		label.Text = format(value.Value)
	end
	value.Changed:Connect(show)
	show()
	return function(target: number, instant: boolean?)
		if instant then
			value.Value = target
			return
		end
		local dist = math.abs(target - value.Value)
		local t = math.clamp(0.25 + dist / 4000, 0.25, 1.1)
		tween(value, t, { Value = target }, Enum.EasingStyle.Quart)
	end
end

---------------------------------------------------------------------------
-- 3D button
--   o = { Size, Position, AnchorPoint, Color, Deep, Radius, Depth, Stroke, Text, TextSize,
--         Icon, IconSize, IconFirst, Parent, Name, ZIndex, LayoutOrder, OnClick, Shine, Hover, Sound }
---------------------------------------------------------------------------
function Kit.button(o: { [string]: any })
	local depth = o.Depth or 6
	local r = o.Radius or 16
	local st = o.Stroke or 3.5
	local z = o.ZIndex or 1
	local color = o.Color or C.Navy600
	local deep = o.Deep or Kit.darken(color, 0.35)

	local btn = new("TextButton", {
		Name = o.Name or "Button",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = o.Size or UDim2.fromOffset(180, 60),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = z,
		Parent = o.Parent,
	})
	local body = new("Frame", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = z,
		Parent = btn,
	})
	local scale = Kit.fx(body)
	local lip = new("Frame", {
		Name = "Lip",
		BackgroundColor3 = Kit.darken(deep, 0.18),
		Position = UDim2.fromOffset(0, depth),
		Size = UDim2.new(1, 0, 1, -depth),
		ZIndex = z,
		Parent = body,
	})
	Kit.corner(lip, r)
	Kit.stroke(lip, st, C.Ink, 0, true)
	lip.Visible = depth > 0
	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, 0, 1, -depth),
		ZIndex = z,
		Parent = body,
	})
	Kit.corner(face, r)
	local faceStroke = Kit.stroke(face, st, C.Ink, 0, true)
	local grad = Kit.gradient(face, Kit.lighten(color, 0.12), deep, 90)
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Kit.lighten(color, 0.14)),
		ColorSequenceKeypoint.new(0.55, color),
		ColorSequenceKeypoint.new(1, Kit.lighten(deep, 0.1)),
	})
	if o.Gloss == true then
		local gloss = new("Frame", {
			Name = "Gloss",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Position = UDim2.new(0, 5, 0, 4),
			Size = UDim2.new(1, -10, 0.44, 0),
			ZIndex = z + 1,
			Parent = face,
		})
		Kit.corner(gloss, if typeof(r) == "UDim" then r else math.max(4, r - 5))
		Kit.gradient(gloss, Color3.new(1, 1, 1), Color3.new(1, 1, 1), 90, 0.7, 0.97)
	end
	Kit.bevel(face, if typeof(r) == "UDim" then r else math.max(4, r - 3), 3, z + 1)
	local content = new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = z + 2,
		Parent = face,
	})

	local label, icon
	if o.Icon then
		icon = Kit.image({
			Image = o.Icon,
			Size = UDim2.fromOffset(o.IconSize or 30, o.IconSize or 30),
			ZIndex = z + 3,
			LayoutOrder = if o.IconFirst == false then 2 else 0,
		})
	end
	if o.Text then
		label = Kit.text({
			Text = o.Text,
			TextSize = o.TextSize or 24,
			FontFace = o.Font or Theme.Font.Display,
			Size = if icon then UDim2.new(0, 0, 1, 0) else UDim2.fromScale(1, 1),
			AutomaticSize = if icon then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
			ZIndex = z + 3,
			LayoutOrder = 1,
			Stroke = o.TextStroke,
		})
	end
	if icon and label then
		local row = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z + 2, Parent = content })
		Kit.list(row, Enum.FillDirection.Horizontal, o.Gap or 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		icon.Parent = row
		label.Parent = row
	elseif icon then
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Parent = content
	elseif label then
		label.Parent = content
	end

	local sheen = if o.Shine then Kit.addShine(face, r) else nil

	local api = {
		Button = btn,
		Body = body,
		Face = face,
		Lip = lip,
		Content = content,
		Label = label,
		Icon = icon,
		Scale = scale,
		Stroke = faceStroke,
		Enabled = true,
	}

	function api.SetColor(c: Color3, d: Color3?)
		local dd = d or Kit.darken(c, 0.35)
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(c, 0.14)),
			ColorSequenceKeypoint.new(0.55, c),
			ColorSequenceKeypoint.new(1, Kit.lighten(dd, 0.1)),
		})
		lip.BackgroundColor3 = Kit.darken(dd, 0.18)
	end
	function api.SetText(t: string)
		if label then
			label.Text = t
		end
	end

	local hovering, pressed = false, false
	local hoverScale = o.HoverScale or 1.05
	local function refresh()
		local target = if pressed then 0.96 elseif hovering then hoverScale else 1
		tween(scale, if pressed then 0.08 else 0.22, { Scale = target }, if pressed then Enum.EasingStyle.Quad else Enum.EasingStyle.Back)
		tween(face, if pressed then 0.06 else 0.2, { Position = UDim2.fromOffset(0, if pressed then math.max(depth - 1, 0) else 0) }, if pressed then Enum.EasingStyle.Quad else Enum.EasingStyle.Back)
	end
	if o.Hover ~= false then
		btn.MouseEnter:Connect(function()
			if not api.Enabled then
				return
			end
			hovering = true
			refresh()
			Kit.playShine(sheen)
			if o.WiggleIcon and icon then
				Kit.wiggle(icon)
			end
			if o.OnHover then
				o.OnHover(true)
			end
		end)
		btn.MouseLeave:Connect(function()
			hovering = false
			pressed = false
			refresh()
			if o.OnHover then
				o.OnHover(false)
			end
		end)
	end
	btn.InputBegan:Connect(function(input)
		if not api.Enabled then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = true
			refresh()
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = false
			refresh()
		end
	end)
	btn.Activated:Connect(function()
		if not api.Enabled then
			return
		end
		if o.Sound ~= false then
			Kit.sfx("Click")
		end
		if o.OnClick then
			o.OnClick(api)
		end
	end)
	return api
end

---------------------------------------------------------------------------
-- the X: two crossed rounded bars with one clean outline (the outline is its own layer
-- underneath, so no ink line ever runs through the middle of the cross)
---------------------------------------------------------------------------
function Kit.closeGlyph(parent: Instance, size: number, z: number, color: Color3?): Frame
	local holder = new("Frame", {
		Name = "CloseGlyph",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		ZIndex = z,
		Parent = parent,
	})
	local len, thick = size, math.max(4, size * 0.24)
	local edge = math.max(2, size * 0.075)
	for layer = 1, 2 do
		for _, rot in ipairs({ 45, -45 }) do
			local bar = new("Frame", {
				Name = if layer == 1 then "Outline" else "Bar",
				BackgroundColor3 = if layer == 1 then C.Ink else (color or Color3.new(1, 1, 1)),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = if layer == 1 then UDim2.fromOffset(len + edge * 2, thick + edge * 2) else UDim2.fromOffset(len, thick),
				Rotation = rot,
				ZIndex = z + layer - 1,
				Parent = holder,
			})
			Kit.pill(bar)
		end
	end
	return holder
end

---------------------------------------------------------------------------
-- chevron (< or >): two rounded bars meeting at the tip, drawn like the X (outline layer
-- underneath). Both bars are centred on the holder, so the arrow sits dead centre in its bubble.
--   dir: -1 = points left, 1 = points right
---------------------------------------------------------------------------
function Kit.chevron(parent: Instance, size: number, z: number, dir: number, color: Color3?): Frame
	local holder = new("Frame", {
		Name = "Chevron",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		ZIndex = z,
		Parent = parent,
	})
	local len, thick = size * 0.66, math.max(4, size * 0.24)
	local edge = math.max(2, size * 0.075)
	local d = (len - thick) / 2 * math.sqrt(0.5)
	for layer = 1, 2 do
		for _, side in ipairs({ -1, 1 }) do -- upper bar, lower bar
			local bar = new("Frame", {
				Name = if layer == 1 then "Outline" else "Bar",
				BackgroundColor3 = if layer == 1 then C.Ink else (color or Color3.new(1, 1, 1)),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, side * d),
				Size = if layer == 1 then UDim2.fromOffset(len + edge * 2, thick + edge * 2) else UDim2.fromOffset(len, thick),
				Rotation = -45 * side * dir, -- clockwise is positive: "/" on top of "<", "\\" below it
				ZIndex = z + layer - 1,
				Parent = holder,
			})
			Kit.pill(bar)
		end
	end
	return holder
end

---------------------------------------------------------------------------
-- eye (preview / try on): almond, iris, pupil, glint
---------------------------------------------------------------------------
function Kit.eyeGlyph(parent: Instance, size: number, z: number, iris: Color3?): Frame
	local edge = math.max(2, size * 0.07)
	local holder = new("Frame", {
		Name = "Eye",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, math.floor(size * 0.62)),
		ZIndex = z,
		Parent = parent,
	})
	Kit.pill(holder)
	Kit.stroke(holder, edge, C.Ink, 0, true)
	local irisSize = math.floor(size * 0.46)
	local ball = new("Frame", {
		Name = "Iris",
		BackgroundColor3 = iris or C.Blue,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(irisSize, irisSize),
		ZIndex = z + 1,
		Parent = holder,
	})
	Kit.pill(ball)
	Kit.stroke(ball, math.max(1.5, edge * 0.8), C.Ink, 0, true)
	local pupil = new("Frame", {
		Name = "Pupil",
		BackgroundColor3 = C.Ink,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.44, 0.44),
		ZIndex = z + 2,
		Parent = ball,
	})
	Kit.pill(pupil)
	local glint = new("Frame", {
		Name = "Glint",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.7, 0.3),
		Size = UDim2.fromScale(0.24, 0.24),
		ZIndex = z + 3,
		Parent = ball,
	})
	Kit.pill(glint)
	return holder
end

---------------------------------------------------------------------------
-- close button: one flat red tile with the X, used by every menu, card and dialog
--   o = { Parent, Size (px), Position, AnchorPoint, ZIndex, OnClick, Name }
---------------------------------------------------------------------------
function Kit.closeButton(o: { [string]: any })
	local size = o.Size or 64
	local z = o.ZIndex or 30
	local btn = new("TextButton", {
		Name = o.Name or "Close",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		AnchorPoint = o.AnchorPoint or Vector2.new(0.5, 0.5),
		Position = o.Position or UDim2.new(),
		Size = UDim2.fromOffset(size, size),
		ZIndex = z,
		Parent = o.Parent,
	})
	local tile = new("Frame", {
		Name = "Tile",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = z,
		Parent = btn,
	})
	Kit.corner(tile, math.floor(size * 0.3))
	Kit.stroke(tile, math.max(3, size * 0.055), C.Ink, 0, true)
	local grad = Kit.gradient(tile, Color3.fromRGB(255, 104, 110), Color3.fromRGB(206, 40, 60), 90)
	local glyph = Kit.closeGlyph(tile, math.floor(size * 0.5), z + 1)
	local scale = Kit.fx(tile)
	local api = { Button = btn, Tile = tile, Glyph = glyph, Scale = scale }
	btn.MouseEnter:Connect(function()
		tween(scale, 0.22, { Scale = 1.08 }, Enum.EasingStyle.Back)
		tween(glyph, 0.3, { Rotation = 90 }, Enum.EasingStyle.Back)
		grad.Color = ColorSequence.new(Color3.fromRGB(255, 126, 132), Color3.fromRGB(222, 52, 72))
	end)
	btn.MouseLeave:Connect(function()
		tween(scale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(glyph, 0.3, { Rotation = 0 }, Enum.EasingStyle.Back)
		grad.Color = ColorSequence.new(Color3.fromRGB(255, 104, 110), Color3.fromRGB(206, 40, 60))
	end)
	btn.MouseButton1Down:Connect(function()
		tween(scale, 0.08, { Scale = 0.92 }, Enum.EasingStyle.Quad)
	end)
	btn.MouseButton1Up:Connect(function()
		tween(scale, 0.18, { Scale = 1.08 }, Enum.EasingStyle.Back)
	end)
	btn.Activated:Connect(function()
		Kit.sfx("Click")
		if o.OnClick then
			o.OnClick()
		end
	end)
	return api
end

---------------------------------------------------------------------------
-- coins: every coin picture in the game is built from the same coin art, so a pouch, a stack,
-- a tower and a mountain are one family (same shading, outline, angle), just more of them.
--   count: 1 (pouch) / 3 (stack) / 6 (tower) / 10 (mountain)
---------------------------------------------------------------------------
local COIN_LAYOUT = {
	[1] = { { 0.5, 0.5, 0.84, 0 } },
	[3] = { { 0.33, 0.42, 0.56, -12 }, { 0.67, 0.42, 0.56, 12 }, { 0.5, 0.6, 0.62, 0 } },
	[6] = {
		{ 0.24, 0.36, 0.42, -14 }, { 0.5, 0.3, 0.42, 4 }, { 0.76, 0.36, 0.42, 14 },
		{ 0.37, 0.53, 0.46, -8 }, { 0.63, 0.53, 0.46, 8 },
		{ 0.5, 0.69, 0.5, 0 },
	},
	[10] = {
		{ 0.17, 0.33, 0.33, -16 }, { 0.39, 0.28, 0.33, -4 }, { 0.61, 0.28, 0.33, 4 }, { 0.83, 0.33, 0.33, 16 },
		{ 0.28, 0.46, 0.37, -10 }, { 0.5, 0.42, 0.37, 0 }, { 0.72, 0.46, 0.37, 10 },
		{ 0.38, 0.6, 0.41, -6 }, { 0.62, 0.6, 0.41, 6 },
		{ 0.5, 0.74, 0.45, 0 },
	},
}
-- where the coins actually are inside the art square (fractions): minX, maxX, minY, maxY
function Kit.coinBounds(count: number): (number, number, number, number)
	local layout = COIN_LAYOUT[count] or COIN_LAYOUT[1]
	local x0, x1, y0, y1 = 1, 0, 1, 0
	for _, c in ipairs(layout) do
		x0 = math.min(x0, c[1] - c[3] / 2)
		x1 = math.max(x1, c[1] + c[3] / 2)
		y0 = math.min(y0, c[2] - c[3] / 2)
		y1 = math.max(y1, c[2] + c[3] / 2)
	end
	return x0, x1, y0, y1
end

function Kit.coinArt(parent: Instance, count: number, size: number, z: number, shadow: boolean?): Frame
	local holder = new("Frame", {
		Name = "CoinArt",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		ZIndex = z,
		Parent = parent,
	})
	local layout = COIN_LAYOUT[count] or COIN_LAYOUT[1]
	if shadow == true and count > 1 then -- off by default: the coins read cleaner on their own
		local sh = new("Frame", {
			Name = "Shadow",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.55,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.9),
			Size = UDim2.fromScale(0.7, 0.12),
			ZIndex = z,
			Parent = holder,
		})
		Kit.pill(sh)
	end
	for i, c in ipairs(layout) do
		Kit.image({
			Name = "Coin" .. i,
			Image = Theme.Icon.Coin,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(c[1], c[2]),
			Size = UDim2.fromScale(c[3], c[3]),
			Rotation = c[4],
			ZIndex = z + i,
			Parent = holder,
		})
	end
	return holder
end

---------------------------------------------------------------------------
-- plate: a flat rounded surface with the ink outline (cards, tiles, pills)
---------------------------------------------------------------------------
function Kit.plate(o: { [string]: any }): Frame
	local f = new(o.Class or "Frame", {
		Name = o.Name or "Plate",
		BackgroundColor3 = o.Color or C.Navy700,
		BackgroundTransparency = o.Transparency or 0,
		Size = o.Size or UDim2.fromOffset(100, 100),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		AutomaticSize = o.AutomaticSize or Enum.AutomaticSize.None,
		Parent = o.Parent,
	})
	if f:IsA("GuiButton") then
		f.AutoButtonColor = false
		if f:IsA("TextButton") then
			f.Text = ""
		end
	end
	Kit.corner(f, o.Radius or 18)
	if o.Stroke ~= false then
		Kit.stroke(f, o.Stroke or 3, o.StrokeColor or C.Ink, o.StrokeTransparency or 0, true)
	end
	if o.Gradient then
		Kit.gradient(f, o.Gradient[1], o.Gradient[2], o.GradientRotation or 90)
		f.BackgroundColor3 = Color3.new(1, 1, 1)
	end
	return f
end

---------------------------------------------------------------------------
-- window: the big rounded panel every menu lives in
--   o = { Name, Size (Vector2), Accent {light, deep}, Title, Icon, Parent, OnClose, Tilt }
--   Tilt: add a small rotation to the open/close pop. Off by default: any rotated ancestor
--   switches off ScrollingFrame clipping (and ViewportFrames can't rotate), so content would
--   spill past the window edge while it opens.
---------------------------------------------------------------------------
function Kit.window(o: { [string]: any })
	local W, H = o.Size.X, o.Size.Y
	local R = 34
	local accent, accentDeep = o.Accent[1], o.Accent[2]

	local root = new("Frame", {
		Name = o.Name or "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 18),
		Size = UDim2.fromOffset(W, H),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 10,
		Parent = o.Parent,
	})
	local scale = Kit.fx(root)

	-- drop shadow
	local shadow = new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.45,
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = root,
	})
	Kit.corner(shadow, R)

	local body = new("Frame", {
		Name = "Body",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = root,
	})
	Kit.corner(body, R)
	Kit.stroke(body, 9, C.Ink, 0, true) -- the skin covers the inner half
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C.Navy700),
			ColorSequenceKeypoint.new(0.45, C.Navy800),
			ColorSequenceKeypoint.new(1, C.Navy900),
		}),
		Parent = body,
	})

	-- accent wash + stud texture, clipped to the rounded body
	local skin = new("CanvasGroup", {
		Name = "Skin",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = body,
	})
	Kit.corner(skin, R)
	-- slow diagonal stripes scrolling behind everything
	Kit.stripes(skin, C.Rim, 0.955, 10)
	-- patterned header band in the window colour
	local band = new("Frame", {
		Name = "HeaderBand",
		BackgroundColor3 = accent,
		Size = UDim2.new(1, 0, 0, 132),
		ZIndex = 10,
		Parent = skin,
	})
	local bandGrad = Kit.gradient(band, accent, accentDeep, 90, 0.72, 1)
	local bandStripes = new("CanvasGroup", { Name = "BandStripes", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 132), GroupTransparency = 0, ZIndex = 10, Parent = skin })
	local bandStripeHolder = Kit.stripes(bandStripes, accent, 0.8, 10, 14, 26)
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		Parent = bandStripes,
	})
	local wash = new("Frame", {
		Name = "Wash",
		BackgroundColor3 = accent,
		Size = UDim2.new(1, 0, 0, 240),
		ZIndex = 10,
		Parent = skin,
	})
	local washGrad = Kit.gradient(wash, accent, accent, 90, 0.86, 1)
	-- vignette at the bottom
	local vignette = new("Frame", { Name = "Vignette", BackgroundColor3 = C.Night, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.45, 0), ZIndex = 10, Parent = skin })
	Kit.gradient(vignette, C.Night, C.Night, 90, 1, 0.25)

	local content = new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 66),
		Size = UDim2.new(1, -52, 1, -90),
		ZIndex = 11,
		Parent = root,
	})

	-- title plate on the top edge
	local plate = new("Frame", {
		Name = "TitlePlate",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(Kit.textWidth(o.Title, 46) + 90 + 32, 84),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 20,
		Parent = root,
	})
	Kit.corner(plate, 24)
	Kit.stroke(plate, 5, C.Ink, 0, true)
	local plateGrad = Kit.gradient(plate, Kit.lighten(accent, 0.15), accentDeep, 90)
	local plateInner = new("Frame", {
		Name = "Inner",
		BackgroundColor3 = C.Night,
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 1, -12),
		ZIndex = 20,
		Parent = plate,
	})
	Kit.corner(plateInner, 19)
	Kit.gradient(plateInner, C.Navy800, C.Night, 90)
	local plateSheen = Kit.addShine(plateInner, 19)
	local plateRow = new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 21,
		Parent = plate,
	})
	Kit.padding(plateRow, 90, 0, 32, 0)
	Kit.list(plateRow, Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local title = Kit.text({
		Name = "Title",
		Text = o.Title,
		TextSize = 46,
		Size = UDim2.new(0, 0, 1, -6),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 22,
		Stroke = 4.5,
		Parent = plateRow,
	})
	-- the icon sits in a rounded-square tile inside the plate's left end, level with it (the
	-- same tile as the hero select title): equal 4px gaps to the plate's rim on three sides
	local iconTile = new("Frame", {
		Name = "IconTile",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(42, 42),
		Size = UDim2.fromOffset(64, 64),
		ZIndex = 23,
		Parent = plate,
	})
	Kit.corner(iconTile, 16)
	Kit.stroke(iconTile, 3.5, C.Ink, 0, true)
	Kit.gradient(iconTile, Kit.lighten(accent, 0.2), accentDeep, 90)
	local titleIcon = Kit.image({
		Name = "TitleIcon",
		Image = o.Icon,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(54, 54),
		ZIndex = 24,
		Parent = iconTile,
	})

	-- close button: the shared flat red tile with the X, on the top-right corner
	local closeApi = Kit.closeButton({
		Parent = root,
		Position = UDim2.new(1, -16, 0, 16),
		Size = 66,
		ZIndex = 30,
		OnClick = function()
			if o.OnClose then
				o.OnClose()
			end
		end,
	})
	local close = closeApi.Button

	local sparkleLayer = Kit.sparkles(body, accent, 8, 10, function()
		return root.Visible
	end)

	-- the title icon stays still and straight
	-- a sheen across the title every few seconds
	task.spawn(function()
		while root.Parent do
			task.wait(3.4)
			if root.Visible then
				Kit.playShine(plateSheen)
			end
		end
	end)

	local api = {
		Root = root,
		Body = body,
		Content = content,
		Plate = plate,
		Title = title,
		TitleIcon = titleIcon,
		Close = close,
		Scale = scale,
		IsOpen = false,
	}

	function api.SetTitle(t: string)
		title.Text = t
		plate.Size = UDim2.fromOffset(Kit.textWidth(t, 46) + 92 + 38, 84)
	end

	-- recolour the whole window (quest board switches colour per hero)
	function api.SetAccent(a: Color3, d: Color3)
		plateGrad.Color = ColorSequence.new(Kit.lighten(a, 0.15), d)
		bandGrad.Color = ColorSequence.new(a, d)
		washGrad.Color = ColorSequence.new(a, a)
		for _, f in ipairs(bandStripeHolder:GetChildren()) do
			if f:IsA("Frame") then
				f.BackgroundColor3 = a
			end
		end
		for _, st in ipairs(sparkleLayer:GetChildren()) do
			if st:IsA("ImageLabel") then
				st.ImageColor3 = Kit.lighten(a, 0.45)
			end
		end
	end

	function api.Open()
		if api.IsOpen then
			return
		end
		api.IsOpen = true
		root.Visible = true
		scale.Scale = 0.62
		root.Rotation = if o.Tilt then -5 else 0
		root.Position = UDim2.new(0.5, 0, 0.5, 60)
		tween(scale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(root, 0.45, { Rotation = 0, Position = UDim2.new(0.5, 0, 0.5, 18) }, Enum.EasingStyle.Back)
		Kit.sfx("Open")
	end
	function api.Close()
		if not api.IsOpen then
			return
		end
		api.IsOpen = false
		tween(scale, 0.18, { Scale = 0.7 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local tw = tween(root, 0.18, { Rotation = if o.Tilt then 3 else 0, Position = UDim2.new(0.5, 0, 0.5, 50) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tw.Completed:Connect(function()
			if not api.IsOpen then
				root.Visible = false
			end
		end)
	end
	return api
end

---------------------------------------------------------------------------
-- section heading: small caps label with a line
---------------------------------------------------------------------------
function Kit.heading(o: { [string]: any }): Frame
	local f = new("Frame", {
		Name = o.Name or "Heading",
		BackgroundTransparency = 1,
		Size = o.Size or UDim2.new(1, 0, 0, 30),
		Position = o.Position or UDim2.new(),
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 12,
		Parent = o.Parent,
	})
	Kit.list(f, Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.text({
		Text = o.Text,
		TextSize = o.TextSize or 22,
		TextColor3 = o.Color or C.TextSoft,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = f.ZIndex,
		LayoutOrder = 1,
		Stroke = 3,
		Parent = f,
	})
	local line = new("Frame", {
		Name = "Line",
		BackgroundColor3 = C.Rim,
		BackgroundTransparency = 0.7,
		Size = UDim2.new(0, 10, 0, 3),
		LayoutOrder = 2,
		ZIndex = f.ZIndex,
		Parent = f,
	})
	new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = line })
	Kit.pill(line)
	return f
end

---------------------------------------------------------------------------
-- progress bar
---------------------------------------------------------------------------
function Kit.bar(o: { [string]: any })
	local track = new("Frame", {
		Name = o.Name or "Bar",
		BackgroundColor3 = o.Track or C.Night,
		Size = o.Size or UDim2.fromOffset(200, 22),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 12,
		Parent = o.Parent,
	})
	Kit.pill(track)
	Kit.stroke(track, o.Stroke or 3, C.Ink, 0, true)
	local fill = new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0, 1),
		ZIndex = track.ZIndex,
		Parent = track,
	})
	Kit.pill(fill)
	Kit.gradient(fill, o.Color or C.Blue, o.Deep or C.BlueDeep, 90)
	-- a short fill is still a whole capsule, never a squashed dot
	local barH = (o.Size or UDim2.fromOffset(200, 22)).Y.Offset
	new("UISizeConstraint", { MinSize = Vector2.new(barH, 0), Parent = fill })
	-- the numbers: plain white with a heavy ink outline, straight on the bar (no capsule behind)
	local textSize = o.TextSize or 16
	local chip = new("Frame", {
		Name = "TextChip",
		BackgroundColor3 = C.Night,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, math.max(barH - 8, textSize + 2)),
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = false,
		ZIndex = track.ZIndex + 1,
		Parent = track,
	})
	Kit.pill(chip)
	Kit.padding(chip, 10, 0, 10, 0)
	local label = Kit.text({
		Name = "Text",
		Text = "",
		TextSize = textSize,
		FontFace = Theme.Font.Heavy,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = track.ZIndex + 2,
		Stroke = 2.8,
		Parent = chip,
	})
	label:GetPropertyChangedSignal("Text"):Connect(function()
		chip.Visible = label.Text ~= ""
	end)
	local api = { Track = track, Fill = fill, Label = label, Chip = chip }
	function api.Set(alpha: number, instant: boolean?)
		alpha = math.clamp(alpha, 0, 1)
		local vis = if alpha <= 0 then 0 else alpha
		if instant then
			fill.Size = UDim2.fromScale(vis, 1)
		else
			tween(fill, 0.45, { Size = UDim2.fromScale(vis, 1) }, Enum.EasingStyle.Quart)
		end
		fill.Visible = alpha > 0
	end
	return api
end

---------------------------------------------------------------------------
-- a soft spinning sunburst behind something special
---------------------------------------------------------------------------
function Kit.rays(parent: GuiObject, color: Color3, size: number, transparency: number?, zIndex: number?, spin: boolean?): ImageLabel
	local rays = Kit.image({
		Name = "Rays",
		Image = Theme.Icon.Rays,
		ImageColor3 = color,
		ImageTransparency = transparency or 0.55,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		ZIndex = zIndex or parent.ZIndex,
		Parent = parent,
	})
	-- spinning is done by TweenService (runs every frame on the engine side, no Lua loop).
	-- Keep spin off for rays inside a CanvasGroup so the group can stay cached.
	if spin ~= false then
		rays.Rotation = math.random(0, 359)
		TweenService:Create(rays, TweenInfo.new(26, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = rays.Rotation + 360 }):Play()
	end
	return rays
end

---------------------------------------------------------------------------
-- bevel: a thin light edge on the top of a rounded surface
---------------------------------------------------------------------------
function Kit.bevel(parent: GuiObject, radius: any, inset: number?, z: number?): Frame
	-- surfaces are flat: no inner highlight line (it read as a silver sliver on rounded corners)
	return new("Frame", { Name = "Bevel", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z or parent.ZIndex, Parent = parent })
end

---------------------------------------------------------------------------
-- diagonal stripes that scroll slowly. Put them inside a CanvasGroup so they clip.
---------------------------------------------------------------------------
function Kit.stripes(parent: GuiObject, color: Color3, transparency: number, z: number?, width: number?, gap: number?): Frame
	local w, g = width or 10, gap or 22
	local period = w + g
	local holder = new("Frame", {
		Name = "Stripes",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(2600, 2600),
		Rotation = 32,
		ZIndex = z or parent.ZIndex,
		Parent = parent,
	})
	local count = math.floor(2600 / period) + 2
	for i = 0, count do
		new("Frame", {
			BackgroundColor3 = color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(i * period, 0),
			Size = UDim2.new(0, w, 1, 0),
			ZIndex = z or parent.ZIndex,
			Parent = holder,
		})
	end
	return holder
end

---------------------------------------------------------------------------
-- little stars drifting upward (for windows and showcases)
---------------------------------------------------------------------------
function Kit.sparkles(parent: GuiObject, color: Color3, count: number, z: number?, active: (() -> boolean)?)
	local layer = new("Frame", { Name = "Sparkles", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z or parent.ZIndex, Parent = parent })
	for i = 1, count do
		local star = Kit.image({
			Image = Theme.Icon.Star,
			ImageColor3 = Kit.lighten(color, 0.45),
			ImageTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(14, 14),
			ZIndex = z or parent.ZIndex,
			Parent = layer,
		})
		task.spawn(function()
			task.wait(i * 0.45)
			while layer.Parent do
				if active and not active() then
					task.wait(0.5)
					continue
				end
				local x = math.random(5, 95) / 100
				local size = math.random(8, 18)
				star.Size = UDim2.fromOffset(size, size)
				star.Position = UDim2.fromScale(x, 0.96)
				star.ImageTransparency = 1
				star.Rotation = math.random(0, 90)
				local life = math.random(40, 70) / 10
				Kit.tween(star, life, { Position = UDim2.fromScale(x + math.random(-8, 8) / 100, math.random(10, 45) / 100), Rotation = star.Rotation + 180 }, Enum.EasingStyle.Sine)
				Kit.tween(star, life * 0.3, { ImageTransparency = 0.35 }, Enum.EasingStyle.Sine)
				task.wait(life * 0.6)
				Kit.tween(star, life * 0.4, { ImageTransparency = 1 }, Enum.EasingStyle.Sine)
				task.wait(life * 0.4 + math.random() * 1.5)
			end
		end)
	end
	return layer
end

---------------------------------------------------------------------------
-- a moving shine along a UIStroke (rare items, equipped slots)
---------------------------------------------------------------------------
function Kit.shimmer(stroke: UIStroke, a: Color3, b: Color3): UIGradient
	local g = new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, a),
			ColorSequenceKeypoint.new(0.45, a),
			ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.55, b),
			ColorSequenceKeypoint.new(1, b),
		}),
		Parent = stroke,
	})
	TweenService:Create(g, TweenInfo.new(4, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 }):Play()
	return g
end

---------------------------------------------------------------------------
-- slider (0..1). o = { Parent, Position, Size, Color, Deep, Value, OnChanged, ZIndex }
---------------------------------------------------------------------------
function Kit.slider(o: { [string]: any })
	local UserInputService = game:GetService("UserInputService")
	local z = o.ZIndex or 14
	local holder = new("TextButton", {
		Name = "Slider",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		Position = o.Position or UDim2.new(),
		Size = o.Size or UDim2.fromOffset(300, 40),
		ZIndex = z,
		Parent = o.Parent,
	})
	local track = new("Frame", { Name = "Track", BackgroundColor3 = C.Night, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 18), ZIndex = z, Parent = holder })
	Kit.pill(track)
	Kit.stroke(track, 3, C.Ink, 0, true)
	local fill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(0.5, 1), ZIndex = z, Parent = track })
	Kit.pill(fill)
	Kit.gradient(fill, Kit.lighten(o.Color or C.Blue, 0.15), o.Deep or C.BlueDeep, 90)
	local knob = new("Frame", { Name = "Knob", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 34), ZIndex = z + 1, Parent = track })
	Kit.pill(knob)
	Kit.stroke(knob, 3.5, C.Ink, 0, true)
	Kit.gradient(knob, Color3.new(1, 1, 1), Color3.fromRGB(196, 208, 230), 90)
	local knobScale = Kit.fx(knob)
	local value = math.clamp(o.Value or 0.5, 0, 1)
	local api = {}
	local function show(v: number)
		fill.Size = UDim2.fromScale(math.max(v, 0.001), 1)
		fill.Visible = v > 0.005
		knob.Position = UDim2.fromScale(v, 0.5)
	end
	function api.Set(v: number, silent: boolean?)
		value = math.clamp(v, 0, 1)
		show(value)
		if not silent and o.OnChanged then
			o.OnChanged(value)
		end
	end
	function api.Get(): number
		return value
	end
	local dragging = false
	local function fromX(x: number)
		local a, w = track.AbsolutePosition.X, track.AbsoluteSize.X
		if w > 0 then
			api.Set((x - a) / w)
		end
	end
	holder.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Kit.tween(knobScale, 0.15, { Scale = 1.2 }, Enum.EasingStyle.Back)
			fromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			Kit.tween(knobScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
			Kit.sfx("Click")
			if o.OnReleased then
				o.OnReleased(value)
			end
		end
	end)
	show(value)
	api.Holder = holder
	return api
end

---------------------------------------------------------------------------
-- on/off switch. o = { Parent, Position, AnchorPoint, Value, OnChanged, Color, Deep, ZIndex }
---------------------------------------------------------------------------
function Kit.toggle(o: { [string]: any })
	local z = o.ZIndex or 14
	local btn = new("TextButton", {
		Name = "Toggle",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		Position = o.Position or UDim2.new(),
		Size = UDim2.fromOffset(104, 48),
		ZIndex = z,
		Parent = o.Parent,
	})
	Kit.pill(btn)
	Kit.stroke(btn, 3.5, C.Ink, 0, true)
	local grad = Kit.gradient(btn, C.Navy600, C.Navy800, 90)
	local label = Kit.text({ Text = "OFF", TextSize = 18, Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.fromScale(0.4, 0), ZIndex = z + 1, Stroke = 2.4, Parent = btn })
	local knob = new("Frame", { Name = "Knob", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.24, 0.5), Size = UDim2.fromOffset(38, 38), ZIndex = z + 2, Parent = btn })
	Kit.pill(knob)
	Kit.stroke(knob, 3, C.Ink, 0, true)
	Kit.gradient(knob, Color3.new(1, 1, 1), Color3.fromRGB(196, 208, 230), 90)
	local value = o.Value == true
	local api = {}
	local function show(instant: boolean?)
		local t = if instant then 0 else 0.22
		local on = value
		Kit.tween(knob, t, { Position = UDim2.fromScale(if on then 0.76 else 0.24, 0.5) }, Enum.EasingStyle.Back)
		label.Text = if on then "ON" else "OFF"
		label.Position = if on then UDim2.fromScale(0, 0) else UDim2.fromScale(0.4, 0)
		local c, d = o.Color or C.Green, o.Deep or C.GreenDeep
		grad.Color = if on then ColorSequence.new(Kit.lighten(c, 0.1), d) else ColorSequence.new(C.Navy600, C.Navy800)
	end
	function api.Set(v: boolean, silent: boolean?)
		value = v == true
		show()
		if not silent and o.OnChanged then
			o.OnChanged(value)
		end
	end
	function api.Get(): boolean
		return value
	end
	btn.Activated:Connect(function()
		Kit.sfx("Click")
		api.Set(not value)
	end)
	show(true)
	api.Button = btn
	return api
end

return Kit
