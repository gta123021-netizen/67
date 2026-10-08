--[[
	AbilityBar  (StarterPlayerScripts.OverkillHUD.AbilityBar)
	The ability hotbar: bottom centre, four tiles that never move - Ability 1, 2, 3 and the Ultimate
	(AbilityConfig.Slots). Built EXACTLY the way the HUD's own dock tiles are (OverkillHUD dockButton):
	the same 100 x 116 tile, flat navy face, the HUD's one ink outline, the accent ring 6 in from the
	edge, the icon in the middle and the name tag sitting on the bottom edge - so the hotbar reads as
	part of the same HUD as SHOP / STATS / BAG, sitting on the same baseline.

	  ready      the accent ring, the art in full colour, the ring breathing softly
	  hover      the tile lifts (the HUD's own hover), the shine runs over it, the tooltip opens
	  press      it gives under the finger / key
	  casting    it rises, its ring goes white-hot and the shine keeps running while the cast lasts
	  cooldown   the art greys, a dark sweep runs round clockwise and the seconds count down; as it
	             comes back it pops, flashes, shines and chimes once
	  refused    it shakes with a red flash (cooldown, nothing to cast with) or the lock wiggles
	  locked     a lock and a grey "SOON" tag (the Ultimate keeps its gold "ULT" tag)
	Shown only where your state allows it (GameState "Hotbar": never in the lobby), sliding in and out.
	Click / tap a tile to cast it; keys 1 2 3 4, the D-pad and R3 do the same.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Abilities = ReplicatedStorage:WaitForChild("Abilities")
local AbilityConfig = require(Abilities:WaitForChild("AbilityConfig"))
local Bus = require(Abilities:WaitForChild("AbilityBus"))
local GameState = require(ReplicatedStorage:WaitForChild("GameState"))

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local HUD = Theme.Hud
	local new, tween = Kit.new, Kit.tween
	local player: Player = ctx.Player

	local W, H = HUD.TileWidth, HUD.TileHeight -- the dock's own tiles
	local GAP = 14
	local LIFT = 12 -- headroom over the tiles (the casting rise, the key caps)
	local HIDDEN_Y = 240
	local RADIUS = UDim.new(0, HUD.CardRadius)
	local RING_IN = 6 -- the accent ring's distance in from the tile's edge (the dock's)
	local RING_W = 2.5 * 1.35
	local ULT = { C.Gold, C.GoldDeep }
	local LOCKED = { C.Navy500, C.Navy700 }

	local bar = new("Frame", {
		Name = "AbilityBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, HIDDEN_Y),
		Size = UDim2.fromOffset(W * 4 + GAP * 3, H + LIFT),
		BackgroundTransparency = 1,
		ZIndex = 12,
		Visible = false,
		Parent = ctx.Root,
	})
	Kit.list(bar, Enum.FillDirection.Horizontal, GAP, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
	local barScale = Kit.fx(bar)

	---------------------------------------------------------------------------
	-- the cooldown sweep: two halves of a disc, each a gradient with a hard edge turned round the
	-- tile's centre (a clockwise sweep from 12 o'clock that uncovers the tile as it goes), clipped
	-- to the tile's own rounded face
	---------------------------------------------------------------------------
	local HARD = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.4999, 0),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	local function sweep(face: GuiObject, z: number)
		local group = new("CanvasGroup", {
			Name = "Cooldown",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			GroupTransparency = 0.28,
			ZIndex = z,
			Visible = false,
			Parent = face,
		})
		Kit.corner(group, RADIUS)
		local halves = {}
		for i, side in ipairs({ "Right", "Left" }) do
			local clip = new("Frame", {
				Name = side,
				BackgroundTransparency = 1,
				ClipsDescendants = true,
				Position = UDim2.fromScale(if side == "Right" then 0.5 else 0, 0),
				Size = UDim2.fromScale(0.5, 1),
				ZIndex = z,
				Parent = group,
			})
			local fill = new("Frame", {
				Name = "Fill",
				BackgroundColor3 = C.Night,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(if side == "Right" then 0 else 1, 0.5),
				Size = UDim2.fromScale(3, 1.5),
				ZIndex = z,
				Parent = clip,
			})
			local g = new("UIGradient", { Transparency = HARD, Parent = fill })
			halves[i] = { Fill = fill, Grad = g }
		end
		-- p = the share of the cooldown still left (1 = just started, 0 = ready)
		local function set(p: number)
			if p <= 0 then
				group.Visible = false
				return
			end
			group.Visible = true
			local a = 360 * p
			local right, left = halves[1], halves[2]
			if a >= 180 then
				right.Grad.Rotation = 180
				left.Grad.Rotation = 180 + (360 - a) - 180
				left.Fill.Visible = true
			else
				right.Grad.Rotation = 180 + (180 - a)
				left.Fill.Visible = false
			end
			right.Fill.Visible = true
		end
		return { Group = group, Set = set }
	end

	---------------------------------------------------------------------------
	-- a lock, drawn (a slot with nothing on it yet)
	---------------------------------------------------------------------------
	local function lockGlyph(parent: GuiObject, s: number, z: number): GuiObject
		local holder = new("Frame", { Name = "Lock", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 44), Size = UDim2.fromOffset(s, s), ZIndex = z, Parent = parent })
		local shackle = new("Frame", { Name = "Shackle", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.02), Size = UDim2.fromScale(0.56, 0.62), ZIndex = z, Parent = holder })
		Kit.corner(shackle, UDim.new(0.5, 0))
		Kit.stroke(shackle, s * 0.12, C.TextDim, 0, true)
		local body = new("Frame", { Name = "Body", BackgroundColor3 = C.TextDim, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(0.86, 0.6), ZIndex = z + 1, Parent = holder })
		Kit.corner(body, s * 0.12)
		Kit.stroke(body, 3, C.Ink, 0, true)
		local hole = new("Frame", { Name = "Hole", BackgroundColor3 = C.Navy800, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.48), Size = UDim2.fromScale(0.16, 0.34), ZIndex = z + 2, Parent = body })
		Kit.corner(hole, UDim.new(0.5, 0))
		return holder
	end

	-- a tag's text, shrunk until it fits the tile (the dock's tags all fit; ability names vary)
	local TAG_MAX = W - 10
	local function fitTag(label: TextLabel, text: string)
		local size = 21
		while size > 13 and Kit.textWidth(text, size, label.FontFace) + 28 > TAG_MAX do
			size -= 1
		end
		label.TextSize = size
		label.Text = text
	end

	---------------------------------------------------------------------------
	-- the tooltip (declared before the tiles: hovering a tile opens it)
	---------------------------------------------------------------------------
	local tip = Kit.plate({
		Name = "AbilityTip",
		Parent = ctx.Root,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(H + HUD.Bottom + 30)),
		Size = UDim2.fromOffset(400, 160),
		Radius = 24,
		Stroke = HUD.Outline,
		ZIndex = 40,
		Color = C.Navy700,
	})
	tip.Visible = false
	local tipRing = Kit.edgeStrokes(tip, UDim.new(0, 24), {
		{ 6 + RING_W / 2, C.Blue },
		{ 6 - RING_W / 2, C.Navy700 },
	}, 41)
	-- (the content in a frame of its own: the ring's frames on the plate stay out of its layout)
	local tipBody = new("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 42, Parent = tip })
	Kit.padding(tipBody, 24, 18, 24, 20)
	Kit.list(tipBody, Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left)
	local tipScale = Kit.fx(tip)
	-- (the plate's height follows its content by hand: an automatically sized plate with the ring's
	-- full-size frames inside it grows without end)
	local function fitTip()
		local k = tip.AbsoluteSize.X / 400
		if k > 0 then
			tip.Size = UDim2.fromOffset(400, math.ceil(tipBody.AbsoluteSize.Y / k))
		end
	end
	tipBody:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTip)
	local tipHead = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1, ZIndex = 42, Parent = tipBody })
	local tipName = Kit.text({ Text = "", TextSize = 28, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -100, 1, 0), ZIndex = 42, Stroke = 3.2, Parent = tipHead })
	local tipType = Kit.plate({ Name = "Type", Parent = tipHead, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, Radius = UDim.new(1, 0), Stroke = HUD.ThinOutline, ZIndex = 42, Color = C.Blue })
	Kit.padding(tipType, 14, 0, 14, 0)
	local tipTypeText = Kit.text({ Text = "", TextSize = 17, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 43, Stroke = 2.4, Parent = tipType })
	local tipDesc = Kit.text({ Text = "", FontFace = Theme.Font.Body, TextSize = 19, TextColor3 = C.TextSoft, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, ZIndex = 42, Stroke = 1.8, Parent = tipBody })
	-- chips along the foot: the key, the cooldown
	local tipFoot = new("Frame", { Name = "Foot", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3, ZIndex = 42, Parent = tipBody })
	Kit.list(tipFoot, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local function chip(order: number): TextLabel
		local c = Kit.plate({ Name = "Chip", Parent = tipFoot, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, Radius = UDim.new(1, 0), Stroke = HUD.ThinOutline, ZIndex = 42, Color = C.Navy900, LayoutOrder = order })
		Kit.padding(c, 12, 0, 12, 0)
		return Kit.text({ Text = "", FontFace = Theme.Font.Heavy, TextSize = 16, TextColor3 = C.TextSoft, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 43, Stroke = 2, Parent = c })
	end
	local tipKey = chip(1)
	local tipCd = chip(2)
	local tipOwner: any = nil

	local function showTip(s: any)
		tipOwner = s
		local def = s.Def
		local accent = if def then def.Accent[1] else (if s.Ult then ULT[1] else C.Navy500)
		tipRing[1].Color = accent
		if def then
			tipName.Text = def.Name
			tipTypeText.Text = def.Type or ""
			tipType.Visible = def.Type ~= nil
			tipType.BackgroundColor3 = accent
			tipDesc.Text = def.Desc or ""
			tipCd.Text = ("%ds COOLDOWN"):format(def.Cooldown)
			tipCd.Parent.Visible = true
		else
			tipName.Text = if s.Ult then "ULTIMATE" else "LOCKED"
			tipType.Visible = false
			tipDesc.Text = if s.Ult then "Your hero's ultimate is coming soon." else "A new ability for this slot is coming soon."
			tipCd.Parent.Visible = false
		end
		tipKey.Text = ("KEY  %s"):format(AbilityConfig.KeyText[s.Id] or "?")
		-- (over the tile it describes)
		local x = s.Holder.AbsolutePosition.X + s.Holder.AbsoluteSize.X / 2 - ctx.Root.AbsolutePosition.X
		tip.Position = UDim2.new(0, x / math.max(ctx.Scale, 0.01), 1, -(H + HUD.Bottom + 30))
		task.defer(fitTip)
		if not tip.Visible then
			tip.Visible = true
			tipScale.Scale = 0.86
			tween(tipScale, 0.24, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end
	local function hideTip(s: any?)
		if s == nil or tipOwner == s then
			tipOwner = nil
			tip.Visible = false
		end
	end

	---------------------------------------------------------------------------
	-- the tiles
	---------------------------------------------------------------------------
	local slots: { [string]: any } = {}
	local order = AbilityConfig.Slots
	for i, slotId in ipairs(order) do
		local ult = slotId == "Ultimate"
		local s: any = { Id = slotId, Ult = ult, Def = nil, Hover = false, Ready = true, Casting = false, Locked = true }
		local holder = new("Frame", { Name = slotId, BackgroundTransparency = 1, Size = UDim2.fromOffset(W, H + LIFT), LayoutOrder = i, ZIndex = 12, Parent = bar })
		local api = Kit.button({
			Name = "Button",
			Parent = holder,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.fromOffset(W, H),
			Color = C.Navy600,
			Deep = C.Navy800,
			Radius = RADIUS,
			Depth = 0,
			Stroke = HUD.Outline,
			HoverScale = 1.08,
			Shine = true,
			Sound = false,
			ZIndex = 12,
			OnClick = function()
				Bus.Press(slotId)
			end,
			OnHover = function(on: boolean)
				s.Hover = on
				if on then
					Kit.sfx("Hover")
					Kit.wiggle(if s.Locked then s.Lock else s.Art, 0.8)
					showTip(s)
				else
					hideTip(s)
				end
			end,
		})
		local face = api.Face
		local z = face.ZIndex
		-- flat and 2D, like the dock: one solid colour on the face
		local faceGrad = face:FindFirstChildOfClass("UIGradient")
		if faceGrad then
			faceGrad.Color = ColorSequence.new(C.Navy600)
		end
		local bevel = face:FindFirstChild("Bevel")
		if bevel then
			bevel:Destroy()
		end
		-- the accent ring (the dock's: strokes on the face's own rect, the ring then the face over
		-- its outer side, so it is exactly as far in on every side)
		local ring = Kit.edgeStrokes(face, RADIUS, {
			{ RING_IN + RING_W / 2, C.Blue },
			{ RING_IN - RING_W / 2, C.Navy600 },
		}, z + 1)
		Kit.outlineOnTop(face, z + 7)
		-- the art, where the dock's icons sit
		local art = Kit.image({
			Name = "Art",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 44),
			Size = UDim2.fromOffset(68, 68),
			ZIndex = z + 3,
			Visible = false,
			Parent = face,
		})
		local artScale = Kit.fx(art)
		local artGrad = new("UIGradient", { Rotation = 90, Parent = art })
		local lock = lockGlyph(face, if ult then 40 else 36, z + 3)
		local cd = sweep(face, z + 4)
		local seconds = Kit.text({
			Name = "Seconds",
			Text = "",
			TextSize = 40,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 44),
			Size = UDim2.fromOffset(W, 46),
			ZIndex = z + 6,
			Stroke = 4,
			Visible = false,
			Parent = face,
		})
		local secondsScale = Kit.fx(seconds)
		local flash = new("Frame", { Name = "Flash", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z + 6, Parent = face })
		Kit.corner(flash, RADIUS)
		local sheen = face:FindFirstChild("Shine") :: Frame?
		-- the name tag on the bottom edge (the dock's)
		local tag = Kit.plate({
			Name = "Tag",
			Parent = api.Body,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, 32),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = UDim.new(1, 0),
			Stroke = HUD.ThinOutline,
			ZIndex = z + 8,
			Color = C.Navy500,
		})
		Kit.padding(tag, 14, 0, 14, 0)
		local tagText = Kit.text({ Text = "", TextSize = 21, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z + 9, Stroke = 3.2, Parent = tag })
		-- the key cap: the tile's top-left corner, where the dock keeps its notification badge's twin
		local cap = Kit.plate({
			Name = "Key",
			Parent = api.Body,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.fromOffset(34, 34),
			Radius = UDim.new(1, 0),
			Stroke = HUD.ThinOutline,
			ZIndex = z + 9,
			Color = C.Navy800,
		})
		local capText = Kit.text({ Text = AbilityConfig.KeyText[slotId] or "", TextSize = 20, ZIndex = z + 10, Stroke = 2.6, Parent = cap })

		s.Holder, s.Api, s.Body, s.Scale, s.Face = holder, api, api.Body, api.Scale, face
		s.Ring, s.Art, s.ArtScale, s.ArtGrad, s.Lock = ring[1], art, artScale, artGrad, lock
		s.Cd, s.Seconds, s.SecondsScale, s.Flash, s.Sheen = cd, seconds, secondsScale, flash, sheen
		s.Tag, s.TagText, s.Cap, s.CapText = tag, tagText, cap, capText
		slots[slotId] = s
	end

	---------------------------------------------------------------------------
	-- painting
	---------------------------------------------------------------------------
	local character: Model? = nil
	local function cooldown(def: any): (number, number)
		local p = Bus.Predicted[def.Id]
		if p then
			return math.max(0, p.Until - workspace:GetServerTimeNow()), p.Len
		end
		local char = character
		if not char then
			return 0, def.Cooldown
		end
		local key = AbilityConfig.CooldownKey(def.Id)
		local untilT = char:GetAttribute("CombatCD_" .. key)
		local len = char:GetAttribute("CombatCDLen_" .. key)
		if type(untilT) ~= "number" then
			return 0, def.Cooldown
		end
		return math.max(0, untilT - workspace:GetServerTimeNow()), if type(len) == "number" and len > 0 then len else def.Cooldown
	end

	local function accentOf(s: any): (Color3, Color3)
		if s.Def then
			return s.Def.Accent[1], s.Def.Accent[2]
		elseif s.Ult then
			return ULT[1], ULT[2]
		end
		return LOCKED[1], LOCKED[2]
	end

	local function paintSlot(s: any)
		local def = AbilityConfig.For(player:GetAttribute("Hero") :: any, s.Id)
		s.Def = def
		s.Locked = def == nil
		local accent, deep = accentOf(s)
		s.Lock.Visible = s.Locked
		s.Art.Visible = not s.Locked and def.Icon ~= nil and def.Icon ~= ""
		s.Ring.Color = if s.Locked and not s.Ult then C.Navy500 else accent
		s.Ring.Transparency = if s.Locked then 0.35 else 0
		s.CapText.TextColor3 = if s.Locked then C.TextDim else C.Text
		-- the tag: the ability's name in its colour; a locked slot "SOON" (the Ultimate "ULT" in gold)
		if s.Locked then
			s.Tag.BackgroundColor3 = if s.Ult then ULT[1] else C.Navy500
			fitTag(s.TagText, if s.Ult then "ULT" else "SOON")
			s.TagText.TextColor3 = if s.Ult then C.Text else C.TextSoft
			s.Cd.Set(0)
			s.Seconds.Visible = false
			return
		end
		s.Tag.BackgroundColor3 = deep:Lerp(accent, 0.45)
		s.TagText.TextColor3 = C.Text
		fitTag(s.TagText, def.Short or def.Name)
		if s.Art.Visible then
			s.Art.Image = def.Icon
			-- white on clear art, tinted: white-hot at the top into the ability's colours
			s.ArtGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
				ColorSequenceKeypoint.new(0.5, accent),
				ColorSequenceKeypoint.new(1, deep),
			})
		end
	end

	local function paintAll()
		for _, id in ipairs(order) do
			paintSlot(slots[id])
		end
	end

	-- the moment a cooldown ends: a pop, a flash, the shine, a chime
	local function readyPop(s: any)
		s.Scale.Scale = 1.18
		tween(s.Scale, 0.45, { Scale = if s.Hover then 1.08 else 1 }, Enum.EasingStyle.Back)
		s.ArtScale.Scale = 1.3
		tween(s.ArtScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
		s.Flash.BackgroundColor3 = Color3.new(1, 1, 1)
		s.Flash.BackgroundTransparency = 0.2
		tween(s.Flash, 0.5, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		Kit.playShine(s.Sheen)
		Kit.sfx("Equip")
	end

	local function setCasting(s: any, on: boolean)
		if s.Casting == on then
			return
		end
		s.Casting = on
		local accent = accentOf(s)
		-- (white-hot while it lasts; after it, the frame loop paints the cooldown's colour)
		s.Ring.Color = if on then Color3.new(1, 1, 1) else accent
		s.Cap.BackgroundColor3 = if on then accent else C.Navy800
		tween(s.Body, 0.28, { Position = UDim2.new(0.5, 0, 0.5, if on then -10 else 0) }, Enum.EasingStyle.Back)
		tween(s.Scale, 0.28, { Scale = if on then 1.1 else (if s.Hover then 1.08 else 1) }, Enum.EasingStyle.Back)
		if on then
			s.Flash.BackgroundColor3 = accent
			s.Flash.BackgroundTransparency = 0.35
			tween(s.Flash, 0.4, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
			Kit.playShine(s.Sheen)
			s.NextShine = os.clock() + 0.55
		end
	end

	---------------------------------------------------------------------------
	-- the fight's word
	---------------------------------------------------------------------------
	-- a press from the keys gives the tile the same press feel
	Bus.On("Pressed", function(id: string)
		local s = slots[id]
		if s and not s.Casting then
			s.Scale.Scale = 0.9
			tween(s.Scale, 0.3, { Scale = if s.Hover then 1.08 else 1 }, Enum.EasingStyle.Back)
		end
	end)
	Bus.On("Cast", function(id: string)
		if slots[id] then
			Kit.sfx("Click")
		end
	end)
	Bus.On("Refused", function(id: string, why: string?)
		local s = slots[id]
		if not s then
			return
		end
		if why == "Locked" then
			Kit.wiggle(s.Lock, 1.3)
		else
			Kit.shake(s.Body)
			s.Flash.BackgroundColor3 = C.Red
			s.Flash.BackgroundTransparency = 0.4
			tween(s.Flash, 0.38, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
			if s.Seconds.Visible then
				s.SecondsScale.Scale = 1.3
				tween(s.SecondsScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
		Kit.sfx("Error")
	end)
	Bus.On("Changed", function()
		paintAll()
	end)
	player:GetAttributeChangedSignal("Hero"):Connect(paintAll)

	---------------------------------------------------------------------------
	-- shown only where it belongs, sliding in and out (on the HUD's own baseline)
	---------------------------------------------------------------------------
	local shown = false
	local function wanted(): boolean
		if ctx.HudHidden and ctx.HudHidden() then
			return false
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (hum and hum.Health > 0) then
			return false
		end
		return GameState.Allows(player, "Hotbar")
	end
	local function apply()
		local want = wanted()
		if want == shown then
			return
		end
		shown = want
		ctx.AbilityBarShown = want
		ctx.Fire("AbilityBar", want)
		if want then
			bar.Visible = true
			barScale.Scale = 0.9
			tween(bar, 0.5, { Position = UDim2.new(0.5, 0, 1, -HUD.Bottom) }, Enum.EasingStyle.Back)
			tween(barScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
			-- the tiles land one after another
			for i, id in ipairs(order) do
				local s = slots[id]
				s.Scale.Scale = 0.6
				tween(s.Scale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05 * i)
			end
		else
			hideTip()
			tween(bar, 0.35, { Position = UDim2.new(0.5, 0, 1, HIDDEN_Y) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In).Completed:Once(function()
				if not shown then
					bar.Visible = false
				end
			end)
		end
	end
	ctx.On("HudHidden", function()
		apply()
	end)
	GameState.Changed(player, function()
		apply()
	end)
	workspace:GetAttributeChangedSignal("PlaceState"):Connect(apply)
	local function onCharacter(char: Model)
		character = char
		paintAll()
		local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
		if hum then
			hum.Died:Connect(function()
				task.delay(0.6, apply)
			end)
		end
		apply()
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	---------------------------------------------------------------------------
	-- every frame: cooldowns, the ready breath, the cast's glow
	---------------------------------------------------------------------------
	local GREY = Color3.fromRGB(120, 134, 160)
	RunService.RenderStepped:Connect(function()
		if not shown then
			return
		end
		local t = os.clock()
		for _, id in ipairs(order) do
			local s = slots[id]
			local def = s.Def
			if def then
				local left, len = cooldown(def)
				local casting = Bus.Casting == def.Id
				setCasting(s, casting)
				if left > 0.02 and not casting then
					s.Cd.Set(math.clamp(left / len, 0, 1))
					s.Seconds.Visible = true
					s.Seconds.Text = if left < 3 then ("%.1f"):format(left) else tostring(math.ceil(left))
					s.Art.ImageColor3 = GREY
					s.Art.ImageTransparency = 0.45
					s.Ring.Color = C.Navy500
					s.Ring.Transparency = 0
					s.Ready = false
				else
					s.Cd.Set(0)
					s.Seconds.Visible = false
					s.Art.ImageColor3 = Color3.new(1, 1, 1)
					s.Art.ImageTransparency = 0
					if not s.Ready then
						s.Ready = true
						if not casting then
							s.Ring.Color = def.Accent[1]
							readyPop(s)
						end
					end
					if casting then
						-- the shine keeps running over it while the cast lasts
						if t >= (s.NextShine or 0) then
							s.NextShine = t + 0.7
							Kit.playShine(s.Sheen)
						end
						s.ArtScale.Scale = 1 + 0.06 * math.sin(t * 14)
					else
						-- ready: the ring breathes
						s.Ring.Transparency = 0.22 * (0.5 + 0.5 * math.sin(t * 2.8))
					end
				end
			end
		end
	end)
end
