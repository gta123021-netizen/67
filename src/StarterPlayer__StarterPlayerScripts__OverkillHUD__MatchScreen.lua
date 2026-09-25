--[[
	MatchScreen  (StarterPlayerScripts.OverkillHUD.MatchScreen)
	The full-screen match flow, on its own ScreenGui above everything else:
	  MATCH FOUND ready check (roster cards, VS, ACCEPT / DECLINE, draining timer)
	  -> everyone ready: countdown
	  -> loading screen while the reserved match server is prepared (also handed to
	     TeleportService as the teleport screen)
	  -> Studio / no PlaceId yet: a TEST MATCH card instead of the teleport.
	It also explains a cancelled match (who dodged, back in queue with priority, or queue locked).
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local Q = ctx.Queue
	local Config = Q.Config
	local player = Players.LocalPlayer
	local IS_STUDIO = RunService:IsStudio()
	local isTouch = ctx.IsTouch
	local LOOP = Enum.EasingDirection.InOut

	local ALLY, ALLY_D = C.Blue, C.BlueDeep
	local ENEMY, ENEMY_D = C.Red, C.RedDeep

	---------------------------------------------------------------------------
	-- screen + scale (same 1920x1080 reference as the HUD)
	---------------------------------------------------------------------------
	local gui = new("ScreenGui", {
		Name = "OverkillMatch",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 60,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
	local rootScale = new("UIScale", { Name = "Fit", Parent = root })
	local function rescale(s: number)
		s = math.max(s or 1, 0.1)
		rootScale.Scale = s
		root.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	ctx.On("Scale", rescale)
	rescale(ctx.Scale)

	local blur = Lighting:FindFirstChild("OverkillMatchBlur") or new("BlurEffect", { Name = "OverkillMatchBlur", Size = 0, Parent = Lighting })

	-- swallows clicks so nothing behind the screen reacts
	local dim = new("TextButton", {
		Name = "Dim",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.Night,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = root,
	})
	local flash = new("Frame", {
		Name = "Flash",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 90,
		Parent = root,
	})

	local loops: { Tween } = {}
	local function loopTween(o: Instance, info: TweenInfo, goal: { [string]: any }): Tween
		local tw = TweenService:Create(o, info, goal)
		table.insert(loops, tw)
		return tw
	end
	local function runLoops(on: boolean)
		for _, tw in ipairs(loops) do
			if on then
				tw:Play()
			else
				tw:Pause()
			end
		end
	end

	-- a rounded badge ring with a comet running round it (search / loading spinner)
	local function spinner(parent: GuiObject, size: number, radius: number, color: Color3, z: number)
		local ring = new("Frame", {
			Name = "Spinner",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			ZIndex = z,
			Parent = parent,
		})
		Kit.corner(ring, radius)
		local st = Kit.stroke(ring, 5, Color3.new(1, 1, 1), 0, true)
		local g = new("UIGradient", {
			Color = ColorSequence.new(Kit.lighten(color, 0.5), color),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.45, 1),
				NumberSequenceKeypoint.new(0.8, 0.5),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Parent = st,
		})
		loopTween(g, TweenInfo.new(1.1, Enum.EasingStyle.Linear, LOOP, -1), { Rotation = 360 })
		return ring, g
	end

	---------------------------------------------------------------------------
	-- the stage: coloured band across the screen
	---------------------------------------------------------------------------
	local stage = new("Frame", { Name = "Stage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Visible = false, Parent = root })
	local BAND_H = 660
	local band = new("Frame", {
		Name = "Band",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, BAND_H),
		ZIndex = 2,
		Parent = stage,
	})
	local bandFill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = band })
	local bandGrad = new("UIGradient", {
		Rotation = 0,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.5, 0.04),
			NumberSequenceKeypoint.new(1, 0.3),
		}),
		Parent = bandFill,
	})
	local bandShade = new("Frame", { Name = "Shade", BackgroundColor3 = C.Night, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = band })
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.35, 1),
			NumberSequenceKeypoint.new(0.7, 0.75),
			NumberSequenceKeypoint.new(1, 0.25),
		}),
		Parent = bandShade,
	})
	local bandStripeGroup = new("CanvasGroup", { Name = "Stripes", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = band })
	local bandStripes = Kit.stripes(bandStripeGroup, Color3.new(1, 1, 1), 0.93, 2, 18, 34)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.22, 0.2),
			NumberSequenceKeypoint.new(0.78, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = bandStripeGroup,
	})
	local edgeGrads: { UIGradient } = {}
	for _, top in ipairs({ true, false }) do
		local ink = new("Frame", {
			Name = if top then "TopEdge" else "BottomEdge",
			BackgroundColor3 = C.Ink,
			AnchorPoint = Vector2.new(0, if top then 0 else 1),
			Position = UDim2.fromScale(0, if top then 0 else 1),
			Size = UDim2.new(1, 0, 0, 12),
			ZIndex = 3,
			Parent = band,
		})
		local lit = new("Frame", {
			Name = "Light",
			BackgroundColor3 = Color3.new(1, 1, 1),
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, 0, 0, 4),
			ZIndex = 3,
			Parent = ink,
		})
		table.insert(edgeGrads, new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.25, 0),
				NumberSequenceKeypoint.new(0.75, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = lit,
		}))
	end
	local bandSheen = Kit.addShine(bandFill, 0)

	-- title plate: MATCH FOUND (same build as a window title plate)
	local TITLE_Y = -BAND_H / 2
	local titleHolder = new("Frame", {
		Name = "TitleHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, TITLE_Y),
		Size = UDim2.fromOffset(600, 112),
		ZIndex = 10,
		Parent = stage,
	})
	local titlePlate = new("Frame", {
		Name = "TitlePlate",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 10,
		Parent = titleHolder,
	})
	Kit.corner(titlePlate, 30)
	Kit.stroke(titlePlate, 6, C.Ink, 0, true)
	local titleGrad = Kit.gradient(titlePlate, C.Blue, C.BlueDeep, 90)
	local titleInner = new("Frame", {
		Name = "Inner",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
		ZIndex = 10,
		Parent = titlePlate,
	})
	Kit.snapFill(titleInner, 8) -- the same rim width on all four sides
	Kit.corner(titleInner, 23)
	Kit.gradient(titleInner, C.Navy800, C.Night, 90)
	local titleSheen = Kit.addShine(titleInner, 23)
	local titleText = Kit.text({
		Name = "Title",
		Text = "MATCH FOUND",
		TextSize = 66,
		Position = UDim2.fromOffset(112, 0),
		Size = UDim2.new(1, -142, 1, 0),
		ZIndex = 12,
		Stroke = 6,
		Parent = titlePlate,
	})
	local titleScale = Kit.fx(titleHolder)
	local badgeHolder = new("Frame", {
		Name = "BadgeHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(56, 56),
		Size = UDim2.fromOffset(86, 86),
		ZIndex = 13,
		Parent = titlePlate,
	})
	-- the mode badge: the same whole number of pixels from the plate's left, top and bottom edges
	Kit.snapEnd(badgeHolder, 13)
	local titleBadge = Q.Badge(badgeHolder, "Duel", 86, 13)
	titleBadge.Frame.Size = UDim2.fromScale(1, 1)

	local modeChip = Q.Chip(stage, "1V1 DUEL", C.Blue, C.BlueDeep, 42, 9)
	modeChip.Frame.AnchorPoint = Vector2.new(0.5, 0)
	modeChip.Frame.Position = UDim2.new(0.5, 0, 0.5, TITLE_Y + 74)
	local modeChipScale = Kit.fx(modeChip.Frame)

	-- roster row
	local roster = new("Frame", {
		Name = "Roster",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -58),
		Size = UDim2.fromOffset(1600, 280),
		ZIndex = 4,
		Parent = stage,
	})
	Kit.list(roster, Enum.FillDirection.Horizontal, 18, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	---------------------------------------------------------------------------
	-- player card
	---------------------------------------------------------------------------
	local function playerCard(v: any, w: number, h: number, tint: Color3, deep: Color3, isYou: boolean, order: number)
		local holder = new("Frame", { Name = "Slot", BackgroundTransparency = 1, Size = UDim2.fromOffset(w, h), LayoutOrder = order, ZIndex = 5, Parent = roster })
		local card = new("Frame", {
			Name = "Card",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Parent = holder,
		})
		local sc = Kit.fx(card)
		local readyGlow = Kit.image({
			Name = "ReadyGlow",
			Image = Theme.Icon.Glow,
			ImageColor3 = C.Green,
			ImageTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(w * 1.7, h * 1.5),
			ZIndex = 5,
			Parent = card,
		})
		local shadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.45, Position = UDim2.fromOffset(0, 10), Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = card })
		Kit.corner(shadow, 28)
		local plate = Kit.plate({ Name = "Plate", Parent = card, Size = UDim2.fromScale(1, 1), Radius = 28, Stroke = 7.5, ZIndex = 5, Gradient = { C.Navy600, C.Navy900 } })
		local plateStroke = plate:FindFirstChildOfClass("UIStroke")
		local skin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = plate })
		Kit.corner(skin, 28)
		Kit.stripes(skin, C.Rim, 0.95, 5)
		local wash = new("Frame", { Name = "Wash", BackgroundColor3 = tint, Size = UDim2.new(1, 0, 0.62, 0), ZIndex = 5, Parent = skin })
		Kit.gradient(wash, tint, deep, 90, 0.45, 1)
		local vignette = new("Frame", { Name = "Vignette", BackgroundColor3 = C.Night, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.45, 0), ZIndex = 5, Parent = skin })
		Kit.gradient(vignette, C.Night, C.Night, 90, 1, 0.3)
		Kit.bevel(plate, 24, 4, 6)

		local AV = math.floor(w * 0.58)
		local avGlow = Kit.image({
			Name = "AvatarGlow",
			Image = Theme.Icon.Glow,
			ImageColor3 = tint,
			ImageTransparency = 0.4,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 18 + AV / 2),
			Size = UDim2.fromOffset(AV * 1.7, AV * 1.7),
			ZIndex = 6,
			Parent = plate,
		})
		local av = Q.Avatar(plate, v, AV, tint, 7)
		av.Frame.AnchorPoint = Vector2.new(0.5, 0)
		av.Frame.Position = UDim2.new(0.5, 0, 0, 18)

		Kit.text({
			Name = "PlayerName",
			Text = tostring(v.DisplayName or v.Name or "?"),
			TextSize = if w >= 210 then 25 else 23,
			Position = UDim2.fromOffset(10, AV + 24),
			Size = UDim2.new(1, -20, 0, 30),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 8,
			Stroke = 3.2,
			Parent = plate,
		})
		local lvRow = new("Frame", { Name = "Level", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, AV + 56), Size = UDim2.new(1, 0, 0, 26), ZIndex = 8, Parent = plate })
		Kit.list(lvRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		Kit.image({ Name = "Star", Image = Theme.Icon.Star, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, ZIndex = 8, Parent = lvRow })
		Kit.text({
			Name = "Text",
			Text = "LV " .. tostring(v.Level or 1),
			TextSize = 19,
			TextColor3 = C.Gold,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			ZIndex = 8,
			Stroke = 2.6,
			Parent = lvRow,
		})
		if v.Bot then
			-- practice bots are tagged next to their level (never over the portrait)
			local bot = Q.Chip(lvRow, "BOT", C.Grey, C.GreyDeep, 24, 8)
			bot.Frame.LayoutOrder = 3
		end

		local status = Kit.plate({
			Name = "Status",
			Parent = plate,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -12),
			Size = UDim2.new(1, -28, 0, 36),
			Radius = UDim.new(1, 0),
			Stroke = 3.5,
			ZIndex = 8,
			Gradient = { C.Navy500, C.Navy700 },
		})
		local statusGrad = status:FindFirstChildOfClass("UIGradient") :: UIGradient
		local statusRow = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 9, Parent = status })
		Kit.list(statusRow, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		local check = Kit.image({ Name = "Check", Image = Theme.Icon.Check, Size = UDim2.fromOffset(26, 26), LayoutOrder = 1, Visible = false, ZIndex = 9, Parent = statusRow })
		local statusText = Kit.text({
			Name = "Text",
			Text = "WAITING",
			TextSize = 19,
			TextColor3 = C.TextSoft,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			ZIndex = 9,
			Stroke = 2.6,
			Parent = statusRow,
		})

		if isYou then
			local you = Q.Chip(plate, "YOU", C.Gold, C.GoldDeep, 32, 12)
			you.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
			you.Frame.Position = UDim2.fromOffset(34, 6)
			you.Frame.Rotation = -8
		end

		local api = { Holder = holder, Card = card, Scale = sc, Ready = false, UserId = v.UserId, Glow = avGlow }
		function api.SetReady(on: boolean, animate: boolean)
			if on == api.Ready then
				return
			end
			api.Ready = on
			check.Visible = on
			statusText.Text = if on then "READY" else "WAITING"
			statusText.TextColor3 = if on then C.Text else C.TextSoft
			statusGrad.Color = if on then ColorSequence.new(Kit.lighten(C.Green, 0.08), C.GreenDeep) else ColorSequence.new(C.Navy500, C.Navy700)
			if on and animate then
				local cs = Kit.fx(check)
				cs.Scale = 0.2
				tween(cs, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
				sc.Scale = 1.08
				tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
				readyGlow.ImageTransparency = 0.2
				tween(readyGlow, 0.9, { ImageTransparency = 0.72 }, Enum.EasingStyle.Quad)
				if plateStroke then
					plateStroke.Color = C.Green
					tween(plateStroke, 0.7, { Color = C.Ink }, Enum.EasingStyle.Quad)
				end
			elseif on then
				readyGlow.ImageTransparency = 0.72
			else
				readyGlow.ImageTransparency = 1
			end
		end
		return api
	end

	-- VS emblem between the teams
	local function vsEmblem(h: number, order: number)
		-- the shine stays tight around the letters: nothing reaches the player cards either side
		local holder = new("Frame", { Name = "VS", BackgroundTransparency = 1, Size = UDim2.fromOffset(210, h), LayoutOrder = order, ZIndex = 3, Parent = roster })
		local rays = Kit.rays(holder, C.Gold, 210, 0.5, 3)
		local glow = Kit.image({
			Name = "Glow",
			Image = Theme.Icon.Glow,
			ImageColor3 = C.Gold,
			ImageTransparency = 0.25,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(190, 190),
			ZIndex = 3,
			Parent = holder,
		})
		local text = Kit.text({
			Name = "Text",
			Text = "VS",
			TextSize = 124,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(200, 150),
			Rotation = -6,
			ZIndex = 4,
			Stroke = 9,
			Parent = holder,
		})
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248, 196)),
				ColorSequenceKeypoint.new(0.5, C.Gold),
				ColorSequenceKeypoint.new(1, C.GoldDeep),
			}),
			Parent = text,
		})
		return { Holder = holder, Text = text, Scale = Kit.fx(text), Rays = rays, Glow = glow }
	end

	---------------------------------------------------------------------------
	-- actions: DECLINE  [ ACCEPT ]  READY 1/2   + draining timer
	---------------------------------------------------------------------------
	local ACT_Y = 156
	local actions = new("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, ACT_Y),
		Size = UDim2.fromOffset(960, 108),
		ZIndex = 20,
		Parent = stage,
	})
	local actScale = Kit.fx(actions)
	local acceptHolder = new("Frame", { Name = "AcceptHolder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(452, 108), ZIndex = 20, Parent = actions })
	local acceptScale = Kit.fx(acceptHolder)
	local onAccept: () -> () = function() end
	local onDecline: () -> () = function() end
	local acceptBtn = Kit.button({
		Name = "Accept",
		Parent = acceptHolder,
		Size = UDim2.fromScale(1, 1),
		Radius = 32,
		Depth = 10,
		Stroke = 5,
		Color = C.Green,
		Deep = C.GreenDeep,
		Text = "ACCEPT",
		TextSize = 52,
		TextStroke = 5,
		ZIndex = 21,
		Shine = true,
		HoverScale = 1.04,
		OnClick = function()
			onAccept()
		end,
	})
	local acceptGlow = Kit.image({
		Name = "Glow",
		Image = Theme.Icon.Glow,
		ImageColor3 = C.Green,
		ImageTransparency = 0.5,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 260),
		ZIndex = 20,
		Parent = acceptHolder,
	})
	loopTween(acceptGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine, LOOP, -1, true), { ImageTransparency = 0.8, Size = UDim2.fromOffset(560, 210) })
	if not isTouch then
		-- key cap inside the button (left of the label), so it never reaches the cards above
		local chip = Kit.plate({
			Name = "Key",
			Parent = acceptBtn.Content,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 22, 0.5, 0),
			Size = UDim2.fromOffset(0, 36),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = 10,
			Stroke = 3,
			Color = C.Text,
			ZIndex = 30,
			Gradient = { Color3.new(1, 1, 1), Color3.fromRGB(206, 216, 234) },
		})
		Kit.padding(chip, 10, 0, 10, 0)
		Kit.text({ Text = "ENTER", TextSize = 17, TextColor3 = C.Ink, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Stroke = false, ZIndex = 31, Parent = chip })
	end

	-- after you accept: a green "ACCEPTED" plate takes the button's place
	local acceptedPlate = Kit.plate({
		Name = "Accepted",
		Parent = actions,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(452, 96),
		Radius = 30,
		Stroke = 5,
		ZIndex = 21,
		Gradient = { Kit.lighten(C.Green, 0.08), C.GreenDeep },
	})
	acceptedPlate.Visible = false
	Kit.bevel(acceptedPlate, 26, 4, 21)
	local acceptedScale = Kit.fx(acceptedPlate)
	local acceptedRow = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 22, Parent = acceptedPlate })
	Kit.list(acceptedRow, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Kit.image({ Name = "Check", Image = Theme.Icon.Check, Size = UDim2.fromOffset(62, 62), LayoutOrder = 1, ZIndex = 22, Parent = acceptedRow })
	local acceptedCol = new("Frame", { Name = "Col", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 22, Parent = acceptedRow })
	Kit.list(acceptedCol, Enum.FillDirection.Vertical, -4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.text({ Name = "Title", Text = "ACCEPTED", TextSize = 38, Size = UDim2.new(0, 0, 0, 42), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 22, Stroke = 4.2, Parent = acceptedCol })
	local waitingText = Kit.text({
		Name = "Waiting",
		Text = "WAITING FOR 1 PLAYER",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = Color3.fromRGB(226, 255, 222),
		Size = UDim2.new(0, 0, 0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		ZIndex = 22,
		Stroke = 2.4,
		Parent = acceptedCol,
	})

	-- countdown plate once everyone is ready
	local countPlate = Kit.plate({
		Name = "Countdown",
		Parent = actions,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(452, 104),
		Radius = 32,
		Stroke = 5,
		ZIndex = 21,
		Gradient = { Kit.lighten(C.Gold, 0.1), C.GoldDeep },
	})
	countPlate.Visible = false
	Kit.bevel(countPlate, 28, 4, 21)
	local countScale = Kit.fx(countPlate)
	local countRow = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 22, Parent = countPlate })
	Kit.list(countRow, Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Kit.text({ Name = "Label", Text = "MATCH STARTS IN", TextSize = 32, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 22, Stroke = 4, Parent = countRow })
	local countNum = Kit.text({ Name = "Number", Text = "3", TextSize = 70, Size = UDim2.fromOffset(56, 96), LayoutOrder = 2, ZIndex = 23, Stroke = 6, Parent = countRow })
	local countNumScale = Kit.fx(countNum)

	-- side pieces
	local declineHolder = new("Frame", { Name = "DeclineHolder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0.5, -250, 0.5, 4), Size = UDim2.fromOffset(226, 84), ZIndex = 20, Parent = actions })
	local declineScale = Kit.fx(declineHolder)
	Kit.button({
		Name = "Decline",
		Parent = declineHolder,
		Size = UDim2.fromScale(1, 1),
		Radius = 26,
		Depth = 8,
		Stroke = 4.5,
		Color = C.Navy500,
		Deep = C.Navy700,
		Text = "DECLINE",
		TextSize = 32,
		ZIndex = 21,
		OnClick = function()
			onDecline()
		end,
	})
	local readyPlate = Kit.plate({
		Name = "ReadyCount",
		Parent = actions,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.5, 250, 0.5, 0),
		Size = UDim2.fromOffset(226, 84),
		Radius = 26,
		Stroke = 4.5,
		ZIndex = 20,
		Gradient = { C.Navy700, C.Night },
	})
	Kit.bevel(readyPlate, 22, 4, 20)
	local readyScale = Kit.fx(readyPlate)
	local readyNum = Kit.text({
		Name = "Count",
		Text = "0 / 2",
		TextSize = 40,
		TextColor3 = C.Text,
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 44),
		ZIndex = 21,
		Stroke = 4.2,
		Parent = readyPlate,
	})
	Kit.text({
		Name = "Label",
		Text = "READY",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = 21,
		Stroke = 2.4,
		Parent = readyPlate,
	})

	-- draining timer under the row
	local timerTrack = new("Frame", {
		Name = "Timer",
		BackgroundColor3 = C.Night,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, ACT_Y + 92),
		Size = UDim2.fromOffset(928, 22),
		ZIndex = 20,
		Parent = stage,
	})
	Kit.pill(timerTrack)
	Kit.stroke(timerTrack, 3.5, C.Ink, 0, true)
	local timerFill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = timerTrack })
	Kit.pill(timerFill)
	local timerGrad = Kit.gradient(timerFill, C.Green, C.GreenDeep, 90)
	local timerText = Kit.text({ Name = "Text", Text = "0:12", TextSize = 18, FontFace = Theme.Font.Heavy, ZIndex = 21, Stroke = 2.6, Parent = timerTrack })

	---------------------------------------------------------------------------
	-- loading screen (teleport) + test match card
	---------------------------------------------------------------------------
	local loading = new("Frame", { Name = "Loading", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 40, Visible = false, Parent = root })
	Kit.gradient(loading, C.Navy900, C.Night, 90)
	local loadStripes = new("CanvasGroup", { Name = "Stripes", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 40, Parent = loading })
	Kit.stripes(loadStripes, C.Rim, 0.955, 40, 14, 30)
	local loadGlow = Kit.image({
		Name = "Glow",
		Image = Theme.Icon.Glow,
		ImageColor3 = C.Blue,
		ImageTransparency = 0.62,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -130),
		Size = UDim2.fromOffset(1100, 1100),
		ZIndex = 40,
		Parent = loading,
	})
	loopTween(loadGlow, TweenInfo.new(2.2, Enum.EasingStyle.Sine, LOOP, -1, true), { ImageTransparency = 0.75, Size = UDim2.fromOffset(980, 980) })
	local loadBadgeHolder = new("Frame", {
		Name = "BadgeHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -170),
		Size = UDim2.fromOffset(156, 156),
		ZIndex = 41,
		Parent = loading,
	})
	local loadRing, loadSpin = spinner(loadBadgeHolder, 156 + 26, math.floor(156 * 0.3) + 13, C.Blue, 41)
	local loadBadge = Q.Badge(loadBadgeHolder, "Duel", 156, 42)
	local loadBadgeScale = Kit.fx(loadBadgeHolder)
	local loadTitle = Kit.text({
		Name = "Title",
		Text = "ENTERING 1V1 DUEL",
		TextSize = 64,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -10),
		Size = UDim2.new(1, -80, 0, 74),
		ZIndex = 42,
		Stroke = 6,
		Parent = loading,
	})
	local loadSub = Kit.text({
		Name = "Sub",
		Text = "",
		TextSize = 24,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 48),
		Size = UDim2.new(0, 900, 0, 60),
		TextWrapped = true,
		ZIndex = 42,
		Stroke = 2.8,
		Parent = loading,
	})
	local loadHeads = new("Frame", {
		Name = "Heads",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 134),
		Size = UDim2.fromOffset(900, 76),
		ZIndex = 42,
		Parent = loading,
	})
	Kit.list(loadHeads, Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	-- indeterminate sweep bar
	local sweepOuter = new("Frame", {
		Name = "Progress",
		BackgroundColor3 = C.Ink,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 222),
		Size = UDim2.fromOffset(600, 24),
		ZIndex = 42,
		Parent = loading,
	})
	Kit.pill(sweepOuter)
	Kit.stroke(sweepOuter, 3.5, C.Ink, 0, true)
	local sweepClip = new("CanvasGroup", { Name = "Clip", BackgroundColor3 = C.Night, Size = UDim2.fromScale(1, 1), ZIndex = 42, Parent = sweepOuter })
	Kit.pill(sweepClip)
	local sweep = new("Frame", {
		Name = "Sweep",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.new(-0.4, 0, 0, 0),
		Size = UDim2.fromScale(0.4, 1),
		ZIndex = 42,
		Parent = sweepClip,
	})
	Kit.pill(sweep)
	local sweepGrad = new("UIGradient", {
		Color = ColorSequence.new(C.Blue, C.BlueDeep),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.35, 0),
			NumberSequenceKeypoint.new(0.65, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = sweep,
	})
	loopTween(sweep, TweenInfo.new(1.25, Enum.EasingStyle.Sine, LOOP, -1), { Position = UDim2.new(1, 0, 0, 0) })
	local tipText = Kit.text({
		Name = "Tip",
		Text = "",
		TextSize = 22,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		RichText = true,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -56),
		Size = UDim2.new(0, 1100, 0, 30),
		ZIndex = 42,
		Stroke = 2.6,
		Parent = loading,
	})
	-- test match card pieces
	local backHolder = new("Frame", {
		Name = "BackHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 238),
		Size = UDim2.fromOffset(400, 92),
		Visible = false,
		ZIndex = 43,
		Parent = loading,
	})
	local backScale = Kit.fx(backHolder)
	local onBack: () -> () = function() end
	Kit.button({
		Name = "Back",
		Parent = backHolder,
		Size = UDim2.fromScale(1, 1),
		Radius = 30,
		Depth = 9,
		Stroke = 5,
		Color = C.Green,
		Deep = C.GreenDeep,
		Text = "BACK TO LOBBY",
		TextSize = 40,
		ZIndex = 44,
		Shine = true,
		OnClick = function()
			onBack()
		end,
	})
	local returnText = Kit.text({
		Name = "Return",
		Text = "",
		TextSize = 20,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 314),
		Size = UDim2.fromOffset(600, 26),
		Visible = false,
		ZIndex = 43,
		Stroke = 2.4,
		Parent = loading,
	})
	local testChip = Q.Chip(loading, if IS_STUDIO then "STUDIO TEST" else "TEST MODE", C.Purple, C.PurpleDeep, 38, 44)
	testChip.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
	testChip.Frame.Position = UDim2.new(0.5, 0, 0.5, -300)
	testChip.Frame.Rotation = -3
	testChip.Frame.Visible = false

	---------------------------------------------------------------------------
	-- cancelled banner
	---------------------------------------------------------------------------
	local cancel = new("Frame", {
		Name = "Cancelled",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(680, 330),
		Visible = false,
		ZIndex = 50,
		Parent = root,
	})
	local cancelScale = Kit.fx(cancel)
	local cancelShadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.45, Position = UDim2.fromOffset(0, 14), Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = cancel })
	Kit.corner(cancelShadow, 34)
	local cancelPlate = Kit.plate({ Name = "Plate", Parent = cancel, Size = UDim2.fromScale(1, 1), Radius = 34, Stroke = 9, ZIndex = 50, Gradient = { C.Navy700, C.Navy900 } })
	local cancelSkin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = cancelPlate })
	Kit.corner(cancelSkin, 34)
	Kit.stripes(cancelSkin, C.Rim, 0.955, 50)
	local cancelWash = new("Frame", { Name = "Wash", BackgroundColor3 = C.Red, Size = UDim2.new(1, 0, 0.6, 0), ZIndex = 50, Parent = cancelSkin })
	Kit.gradient(cancelWash, C.Red, C.RedDeep, 90, 0.72, 1)
	Kit.bevel(cancelPlate, 28, 7, 51)
	-- the shared close tile (not clickable here), with a tight burst behind it that stays clear of the text
	local cancelRays = Kit.rays(cancelPlate, C.Red, 156, 0.5, 51)
	cancelRays.Position = UDim2.new(0.5, 0, 0, 0)
	local cancelIcon = new("Frame", {
		Name = "Icon",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(100, 100),
		ZIndex = 53,
		Parent = cancelPlate,
	})
	Kit.corner(cancelIcon, 30)
	Kit.stroke(cancelIcon, 5, C.Ink, 0, true)
	Kit.gradient(cancelIcon, Color3.fromRGB(255, 104, 110), Color3.fromRGB(206, 40, 60), 90)
	local cancelGlyph = Kit.closeGlyph(cancelIcon, 50, 54)
	local cancelTitle = Kit.text({
		Name = "Title",
		Text = "MATCH CANCELLED",
		TextSize = 46,
		TextColor3 = Kit.lighten(C.Red, 0.3),
		Position = UDim2.fromOffset(20, 82),
		Size = UDim2.new(1, -40, 0, 52),
		ZIndex = 52,
		Stroke = 5,
		Parent = cancelPlate,
	})
	local cancelText = Kit.text({
		Name = "Body",
		Text = "",
		TextSize = 23,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		Position = UDim2.fromOffset(44, 140),
		Size = UDim2.new(1, -88, 0, 64),
		ZIndex = 52,
		Stroke = 2.6,
		Parent = cancelPlate,
	})
	local cancelChip = Q.Chip(cancelPlate, "", C.Gold, C.GoldDeep, 46, 52)
	cancelChip.Frame.AnchorPoint = Vector2.new(0.5, 1)
	cancelChip.Frame.Position = UDim2.new(0.5, 0, 1, -34)
	local cancelBar = new("Frame", { Name = "Life", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.6, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.new(1, -120, 0, 6), ZIndex = 52, Parent = cancelPlate })
	Kit.pill(cancelBar)

	---------------------------------------------------------------------------
	-- state machine
	---------------------------------------------------------------------------
	local cur: any = nil -- { Id, Mode, Stage, Cards = {userId -> card}, MeAccepted, VS, LastTick }
	local cancelUntil = 0
	local opened = false

	local function setBinding(on: boolean)
		if on then
			ContextActionService:BindActionAtPriority("OverkillAcceptMatch", function(_, state)
				if state == Enum.UserInputState.Begin then
					onAccept()
				end
				return Enum.ContextActionResult.Sink
			end, false, 3000, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonA)
		else
			ContextActionService:UnbindAction("OverkillAcceptMatch")
		end
	end

	local function openScreen()
		if opened then
			return
		end
		opened = true
		ctx.SetOverlay("Match") -- nothing else opens or pops up while this is on screen
		gui.Enabled = true
		dim.BackgroundTransparency = 1
		tween(dim, 0.35, { BackgroundTransparency = 0.25 })
		tween(blur, 0.4, { Size = 14 })
		runLoops(true)
	end

	local function closeScreen()
		if not opened then
			return
		end
		opened = false
		setBinding(false)
		ctx.SetOverlay(nil)
		tween(dim, 0.3, { BackgroundTransparency = 1 })
		tween(blur, 0.35, { Size = 0 })
		for _, g in ipairs({ stage, loading, cancel }) do
			if g.Visible then
				tween(Kit.fx(g), 0.22, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
		end
		task.delay(0.3, function()
			if opened then
				return -- reopened meanwhile
			end
			stage.Visible = false
			loading.Visible = false
			cancel.Visible = false
			Kit.fx(stage).Scale = 1
			Kit.fx(loading).Scale = 1
			gui.Enabled = false
			runLoops(false)
		end)
		cur = nil
	end

	local function mode(id: string?)
		return Q.Mode(id) or Config.Modes.Duel
	end

	local function recolor(m: any)
		local c, d = m.Color, m.Deep
		bandGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.darken(d, 0.55)),
			ColorSequenceKeypoint.new(0.5, Kit.darken(d, 0.1)),
			ColorSequenceKeypoint.new(1, Kit.darken(d, 0.55)),
		})
		for _, g in ipairs(edgeGrads) do
			g.Color = ColorSequence.new(Kit.lighten(c, 0.35))
		end
		titleGrad.Color = ColorSequence.new(Kit.lighten(c, 0.15), d)
		titleBadge.Set(m.Id)
		loadBadge.Set(m.Id)
		loadGlow.ImageColor3 = c
		loadSpin.Color = ColorSequence.new(Kit.lighten(c, 0.5), c)
		sweepGrad.Color = ColorSequence.new(Kit.lighten(c, 0.2), d)
		for _, f in ipairs(bandStripes:GetChildren()) do
			if f:IsA("Frame") then
				f.BackgroundColor3 = Kit.lighten(c, 0.5)
			end
		end
	end

	local function sizeTitle(text: string)
		titleText.Text = text
		local w = Kit.textWidth(text, 66) + 120 + 48
		titleHolder.Size = UDim2.fromOffset(w, 112)
	end

	-- lay out the roster: your team on the left, you first
	local function buildRoster(view: any)
		for _, c in ipairs(roster:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local m = mode(view.Mode)
		local me = view.You
		local myTeam = nil
		for _, p in ipairs(view.Players) do
			if p.UserId == me then
				myTeam = p.Team
			end
		end
		local left, right = {}, {}
		for _, p in ipairs(view.Players) do
			if p.UserId == me then
				table.insert(left, 1, p)
			elseif m.FreeForAll or p.Team == nil then
				table.insert(right, p)
			elseif p.Team == myTeam then
				table.insert(left, p)
			else
				table.insert(right, p)
			end
		end
		local ffa = m.FreeForAll == true
		local w, h = if ffa then 200 else 224, if ffa then 266 else 280
		local cards = {}
		local order = 0
		local entrances = {}
		local function add(p: any, ally: boolean, fromLeft: boolean)
			order += 1
			local card = playerCard(p, w, h, if ally then ALLY else ENEMY, if ally then ALLY_D else ENEMY_D, p.UserId == me, order)
			card.SetReady(p.Accepted == true, false)
			cards[p.UserId] = card
			card.Card.Position = UDim2.new(0.5, if fromLeft then -900 else 900, 0.5, 0)
			table.insert(entrances, card)
		end
		for _, p in ipairs(left) do
			add(p, true, true)
		end
		local vs = nil
		if not ffa then
			order += 1
			vs = vsEmblem(h, order)
			vs.Text.TextTransparency = 1
			local st = vs.Text:FindFirstChildOfClass("UIStroke")
			if st then
				st.Transparency = 1
			end
			vs.Rays.ImageTransparency = 1
			vs.Glow.ImageTransparency = 1
		end
		for _, p in ipairs(right) do
			add(p, false, false)
		end
		-- slide the cards in, staggered from the middle out
		for i, card in ipairs(entrances) do
			tween(card.Card, 0.55, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.12 + i * 0.07)
		end
		if vs then
			task.delay(0.12 + #entrances * 0.07 + 0.35, function()
				if not vs.Holder.Parent then
					return
				end
				vs.Scale.Scale = 3.2
				tween(vs.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				tween(vs.Text, 0.2, { TextTransparency = 0 })
				local st = vs.Text:FindFirstChildOfClass("UIStroke")
				if st then
					tween(st, 0.2, { Transparency = 0 })
				end
				task.wait(0.3)
				Kit.sfx("Buy")
				tween(vs.Rays, 0.4, { ImageTransparency = 0.5 })
				vs.Glow.ImageTransparency = 0
				tween(vs.Glow, 0.8, { ImageTransparency = 0.25 }, Enum.EasingStyle.Quad)
				Kit.shake(roster)
			end)
		end
		return cards
	end

	local function readyCounts(view: any): (number, number)
		local n, total = 0, 0
		for _, p in ipairs(view.Players) do
			total += 1
			if p.Accepted then
				n += 1
			end
		end
		return n, total
	end

	local function showAccepted(animate: boolean)
		if acceptedPlate.Visible then
			return
		end
		setBinding(false)
		acceptHolder.Visible = false
		acceptedPlate.Visible = true
		if animate then
			acceptedScale.Scale = 0.6
			tween(acceptedScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		tween(declineScale, 0.25, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	end

	local function setStageLayout(stageName: string)
		local ready = stageName == "ready"
		declineHolder.Visible = ready
		readyPlate.Visible = ready or stageName == "starting"
		timerTrack.Visible = ready
		countPlate.Visible = stageName == "starting"
		if not ready then
			acceptHolder.Visible = false
			acceptedPlate.Visible = false
			setBinding(false)
		end
	end

	local function openMatch(view: any)
		local m = mode(view.Mode)
		ctx.Close()
		openScreen()
		cancel.Visible = false
		loading.Visible = false
		stage.Visible = true
		Kit.fx(stage).Scale = 1
		recolor(m)
		sizeTitle("MATCH FOUND")
		modeChip.Set(if view.Private then "PRIVATE DUEL" else m.Title, if view.Private then C.Gold else m.Color, if view.Private then C.GoldDeep else m.Deep)

		cur = { Id = view.Id, Mode = view.Mode, Stage = "", MeAccepted = false, LastTick = -1, Count = -1 }
		cur.Cards = buildRoster(view)

		-- entrance: band opens, title drops, chip pops, buttons rise
		band.Size = UDim2.new(1, 0, 0, 0)
		tween(band, 0.45, { Size = UDim2.new(1, 0, 0, BAND_H) }, Enum.EasingStyle.Quint)
		task.delay(0.15, function()
			Kit.playShine(bandSheen)
		end)
		titleHolder.Position = UDim2.new(0.5, 0, 0.5, TITLE_Y - 260)
		titleScale.Scale = 1.3
		tween(titleHolder, 0.5, { Position = UDim2.new(0.5, 0, 0.5, TITLE_Y) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)
		tween(titleScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)
		task.delay(0.55, function()
			Kit.playShine(titleSheen)
			Kit.wiggle(badgeHolder, 1)
		end)
		modeChipScale.Scale = 0
		tween(modeChipScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.35)
		actions.Position = UDim2.new(0.5, 0, 0.5, ACT_Y + 160)
		actScale.Scale = 0.8
		tween(actions, 0.5, { Position = UDim2.new(0.5, 0, 0.5, ACT_Y) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.3)
		tween(actScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.3)
		acceptHolder.Visible = true
		acceptScale.Scale = 1
		acceptedPlate.Visible = false
		declineScale.Scale = 1
		readyScale.Scale = 1
		flash.BackgroundTransparency = 0.55
		tween(flash, 0.45, { BackgroundTransparency = 1 })
		Q.Chime("found")
		Kit.sfx("Open")
	end

	local function tipCycle(token: number)
		task.spawn(function()
			local tips = Config.Tips or {}
			local i = math.random(1, math.max(1, #tips))
			while cur and cur.TipToken == token and loading.Visible do
				if #tips > 0 then
					tipText.Text = '<font color="#FFD440">TIP</font>  ' .. tips[i]
					tipText.TextTransparency = 1
					tween(tipText, 0.4, { TextTransparency = 0 })
					i = i % #tips + 1
				end
				task.wait(4)
			end
		end)
	end

	local function showLoading(view: any, test: boolean)
		local m = mode(view.Mode)
		loading.Visible = true
		Kit.fx(loading).Scale = 1
		local fresh = cur.LoadingShown ~= true
		cur.LoadingShown = true
		loadTitle.Text = if test then "TEST MATCH READY" else "ENTERING " .. m.Title
		loadTitle.TextColor3 = if test then C.Gold else C.Text
		if test then
			local where = if IS_STUDIO then "Studio doesn't teleport, so this is where the match would begin." else "Add a PlaceId for this mode in QueueConfig to send players to a real match."
			loadSub.Text = "Matchmaking worked end to end. " .. where
		else
			loadSub.Text = "Preparing your match server..."
		end
		sweepOuter.Visible = not test
		backHolder.Visible = test
		returnText.Visible = test
		testChip.Frame.Visible = test
		loadRing.Visible = not test
		if fresh then
			for _, c in ipairs(loadHeads:GetChildren()) do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			for i, p in ipairs(view.Players) do
				local a = Q.Avatar(loadHeads, p, 72, if p.UserId == view.You then C.Gold else m.Color, 43)
				a.Frame.LayoutOrder = i
				local s = Kit.fx(a.Frame)
				s.Scale = 0
				tween(s, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.2 + i * 0.06)
			end
			loading.BackgroundTransparency = 1
			tween(loading, 0.35, { BackgroundTransparency = 0 })
			loadBadgeScale.Scale = 0.3
			tween(loadBadgeScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
			cur.TipToken = (cur.TipToken or 0) + 1
			tipCycle(cur.TipToken)
		end
		if test and backHolder.Visible then
			backScale.Scale = 0.5
			tween(backScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			local ts = Kit.fx(testChip.Frame)
			ts.Scale = 0
			tween(ts, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
			Q.Chime("ready")
		end
	end

	local function updateMatch(view: any)
		if not cur or cur.Id ~= view.Id then
			openMatch(view)
		end
		local me = view.You
		local n, total = readyCounts(view)
		for _, p in ipairs(view.Players) do
			local card = cur.Cards[p.UserId]
			if card and p.Accepted and not card.Ready then
				card.SetReady(true, true)
				if p.UserId ~= me then
					Kit.sfx("Equip")
				end
			end
			if p.UserId == me and p.Accepted then
				cur.MeAccepted = true
			end
		end
		readyNum.Text = ("%d / %d"):format(n, total)
		if cur.Count >= 0 and n > cur.Count then
			readyScale.Scale = 1.12
			tween(readyScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		cur.Count = n
		local waitingFor = total - n
		waitingText.Text = if waitingFor == 1 then "WAITING FOR 1 PLAYER" else ("WAITING FOR %d PLAYERS"):format(waitingFor)

		if view.Stage ~= cur.Stage then
			cur.Stage = view.Stage
			setStageLayout(view.Stage)
			if view.Stage == "ready" then
				if cur.MeAccepted then
					showAccepted(false)
				else
					setBinding(true)
				end
				-- drain the bar to the deadline
				local left = math.max(0, (view.Deadline or Q.Now()) - Q.Now())
				timerFill.Size = UDim2.fromScale(math.clamp(left / Config.AcceptSeconds, 0, 1), 1)
				tween(timerFill, left, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Linear)
			elseif view.Stage == "starting" then
				Q.Chime("ready")
				countScale.Scale = 0.5
				tween(countScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
				cur.LastTick = -1
			elseif view.Stage == "teleporting" then
				Q.Chime("go")
				flash.BackgroundTransparency = 0.3
				tween(flash, 0.5, { BackgroundTransparency = 1 })
				showLoading(view, false)
				if view.Live then
					-- hand Roblox a copy of the loading screen to show during the teleport
					pcall(function()
						local tg = gui:Clone()
						tg.Enabled = true
						local r = tg:FindFirstChild("Root")
						if r then
							for _, c in ipairs(r:GetChildren()) do
								if c:IsA("GuiObject") and c.Name ~= "Loading" then
									c.Visible = false
								end
							end
						end
						TeleportService:SetTeleportGui(tg)
					end)
				end
			elseif view.Stage == "test" then
				showLoading(view, true)
			end
		end
		if view.Stage == "ready" and cur.MeAccepted then
			showAccepted(true)
		end
		cur.View = view
	end

	onAccept = function()
		if not cur or cur.Stage ~= "ready" or cur.MeAccepted then
			return
		end
		cur.MeAccepted = true
		Q.Chime("accept")
		showAccepted(true)
		local card = cur.Cards[player.UserId]
		if card then
			card.SetReady(true, true)
		end
		Q.Request("accept")
	end
	onDecline = function()
		if not cur or cur.Stage ~= "ready" or cur.MeAccepted then
			return
		end
		setBinding(false)
		Q.Request("decline")
	end
	onBack = function()
		Q.Request("dismiss")
		closeScreen()
	end

	local function showCancelled(info: any)
		if type(info) ~= "table" then
			return
		end
		openScreen()
		setBinding(false)
		cancelUntil = os.clock() + 3.6
		-- the whole ready check (band, roster, ACCEPT / DECLINE, timer) leaves the screen:
		-- only the banner stays, over the dimmed world
		if stage.Visible then
			local stageScale = Kit.fx(stage)
			tween(stageScale, 0.18, { Scale = 0.88 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function()
				if cancel.Visible then
					stage.Visible = false
					stageScale.Scale = 1
				end
			end)
			tween(band, 0.18, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
		loading.Visible = false
		cancel.Visible = true
		cancelTitle.Text = tostring(info.Title or "MATCH CANCELLED")
		cancelText.Text = tostring(info.Text or "")
		if info.Requeued then
			cancelChip.Set("BACK IN QUEUE  ·  PRIORITY", C.Gold, C.GoldDeep)
			cancelChip.Frame.Visible = true
		elseif info.Lock then
			cancelChip.Set(("QUEUE LOCKED FOR %d SECONDS"):format(info.Lock), C.Red, C.RedDeep)
			cancelChip.Frame.Visible = true
		else
			cancelChip.Set("SEARCH ENDED", C.Grey, C.GreyDeep)
			cancelChip.Frame.Visible = true
		end
		cancelScale.Scale = 0.6
		tween(cancelScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		cancelGlyph.Rotation = -90
		tween(cancelGlyph, 0.5, { Rotation = 0 }, Enum.EasingStyle.Back)
		local iconScale = Kit.fx(cancelIcon)
		iconScale.Scale = 0.4
		tween(iconScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		cancelBar.Size = UDim2.new(1, -120, 0, 6)
		tween(cancelBar, 3.4, { Size = UDim2.new(0, 0, 0, 6) }, Enum.EasingStyle.Linear)
		Q.Chime("cancel")
		Kit.sfx("Error")
		local token = cancelUntil
		task.delay(3.6, function()
			if cancelUntil ~= token then
				return
			end
			if Q.State.Match then
				tween(cancelScale, 0.2, { Scale = 0.7 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
				cancel.Visible = false
			else
				closeScreen()
			end
		end)
	end
	ctx.On("QueueCancelled", showCancelled)

	ctx.On("QueueState", function(s: any)
		local view = s.Match
		if view and (view.Stage == "ready" or view.Stage == "starting" or view.Stage == "teleporting" or view.Stage == "test") then
			if cancel.Visible and (not cur or cur.Id ~= view.Id) then
				cancel.Visible = false
				cancelUntil = 0
			end
			updateMatch(view)
		elseif cur then
			if os.clock() < cancelUntil then
				-- banner is up; the roster stays shrunk under it until it closes
				setBinding(false)
				cur = nil
			else
				closeScreen()
			end
		end
	end)

	---------------------------------------------------------------------------
	-- clocks: ready timer, countdown numbers, test-match return timer
	---------------------------------------------------------------------------
	task.spawn(function()
		while gui.Parent do
			local view = cur and cur.View
			if view and opened then
				local now = Q.Now()
				if view.Stage == "ready" then
					local left = math.max(0, (view.Deadline or now) - now)
					timerText.Text = Q.Clock(math.ceil(left))
					local a = math.clamp(left / Config.AcceptSeconds, 0, 1)
					local c = if a > 0.5 then C.Green elseif a > 0.25 then C.Gold else C.Red
					local d = if a > 0.5 then C.GreenDeep elseif a > 0.25 then C.GoldDeep else C.RedDeep
					timerGrad.Color = ColorSequence.new(Kit.lighten(c, 0.1), d)
					local sec = math.ceil(left)
					if sec ~= cur.LastTick then
						cur.LastTick = sec
						if sec <= 5 and sec > 0 and not cur.MeAccepted then
							Q.Chime("tick")
							acceptScale.Scale = 1.05
							tween(acceptScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
						end
					end
				elseif view.Stage == "starting" then
					local left = math.max(0, (view.StartAt or now) - now)
					local sec = math.max(1, math.ceil(left))
					if sec ~= cur.LastTick then
						cur.LastTick = sec
						countNum.Text = tostring(sec)
						countNumScale.Scale = 1.8
						tween(countNumScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
						Q.Chime("tick")
					end
				elseif view.Stage == "test" then
					local left = math.max(0, (view.EndAt or now) - now)
					returnText.Text = "Back to the lobby in " .. Q.Clock(math.ceil(left))
				end
			end
			task.wait(0.1)
		end
	end)

	-- a match already running when the HUD loads (respawn, late state)
	if Q.State.Match then
		updateMatch(Q.State.Match)
	end
end
