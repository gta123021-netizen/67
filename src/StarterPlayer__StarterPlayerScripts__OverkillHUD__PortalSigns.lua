--[[
	PortalSigns  (StarterPlayerScripts.OverkillHUD.PortalSigns)
	Walk up to a portal and a card rises above the hotbar: the mode, how it plays, how many players
	are searching, the expected wait, and whether you can walk in right now (party leader, party size,
	queue lock, private duel). It stays out of the way while you're already searching that mode,
	in a match, or while a window / the quest dialogue is open.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local Q = ctx.Queue
	local Config = Q.Config
	local player = Players.LocalPlayer

	local RANGE = 17 -- studs from the doorway
	local W, H = 720, 132

	---------------------------------------------------------------------------
	-- doorways
	---------------------------------------------------------------------------
	-- (the place streams: a portal's parts can arrive after the HUD, so scanning repeats until all are in)
	local doors: { any } = {}
	local found: { [string]: boolean } = {}
	local function scan(folder: Instance)
		for _, model in ipairs(folder:GetChildren()) do
			if model:IsA("Model") then
				local modeId = model:GetAttribute("QueueMode")
				if not modeId then
					for id, m in pairs(Config.Modes) do
						if m.Portal == model.Name then
							modeId = id
						end
					end
				end
				if modeId and Config.Modes[modeId] and not found[modeId] then
					local pane: BasePart? = nil
					for _, d in ipairs(model:GetDescendants()) do
						if d:IsA("BasePart") and d.Transparency > 0.3 and (not pane or d.Size.Magnitude > (pane :: BasePart).Size.Magnitude) then
							pane = d
						end
					end
					if pane then
						found[modeId] = true
						table.insert(doors, { Mode = modeId, Pos = pane.Position })
					end
				end
			end
		end
	end
	task.spawn(function()
		local folder = workspace:WaitForChild("Portals", 60)
		if not folder then
			return
		end
		scan(folder)
		local pending = false
		folder.DescendantAdded:Connect(function()
			if pending or #doors >= #Config.Order then
				return
			end
			pending = true
			task.delay(0.5, function()
				pending = false
				scan(folder)
			end)
		end)
	end)

	---------------------------------------------------------------------------
	-- the card
	---------------------------------------------------------------------------
	local holder = new("Frame", {
		Name = "PortalCard",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -238),
		Size = UDim2.fromOffset(W, H),
		Visible = false,
		ZIndex = 15,
		Parent = ctx.Hud,
	})
	local card = new("Frame", {
		Name = "Card",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 15,
		Parent = holder,
	})
	local cardScale = Kit.fx(card)
	local shadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.5, Position = UDim2.fromOffset(0, 10), Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = card })
	Kit.corner(shadow, 32)
	local plate = Kit.plate({ Name = "Plate", Parent = card, Size = UDim2.fromScale(1, 1), Radius = 32, Stroke = 7.5, ZIndex = 15, Gradient = { C.Navy700, C.Navy900 } })
	local skin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = plate })
	Kit.corner(skin, 32)
	Kit.stripes(skin, C.Rim, 0.955, 15)
	local wash = new("Frame", { Name = "Wash", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.new(0.7, 0, 1, 0), ZIndex = 15, Parent = skin })
	local washGrad = new("UIGradient", {
		Rotation = 0,
		Color = ColorSequence.new(C.Blue),
		Transparency = NumberSequence.new(0.62, 1),
		Parent = wash,
	})
	Kit.bevel(plate, 28, 4, 16)
	local sheen = Kit.addShine(plate, 32)

	local badgeGlow = Kit.image({
		Name = "Glow",
		Image = Theme.Icon.Glow,
		ImageColor3 = C.Blue,
		ImageTransparency = 0.45,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(20 + 46, 20 + 46),
		Size = UDim2.fromOffset(180, 180),
		ZIndex = 16,
		Parent = plate,
	})
	local glowLoop = TweenService:Create(badgeGlow, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { ImageTransparency = 0.75, Size = UDim2.fromOffset(150, 150) })
	local badge = Q.Badge(plate, "Duel", 92, 17)
	badge.Frame.Position = UDim2.fromOffset(20, 20)

	local RIGHT = 188
	local title = Kit.text({
		Name = "Title",
		Text = "1V1 DUEL",
		TextSize = 32,
		Position = UDim2.fromOffset(132, 14),
		Size = UDim2.new(1, -132 - RIGHT - 18, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 18,
		Stroke = 3.8,
		Parent = plate,
	})
	local blurb = Kit.text({
		Name = "Blurb",
		Text = "",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		Position = UDim2.fromOffset(133, 52),
		Size = UDim2.new(1, -133 - RIGHT - 18, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 18,
		Stroke = 2.4,
		Parent = plate,
	})
	local hintRow = new("Frame", { Name = "Hint", BackgroundTransparency = 1, Position = UDim2.fromOffset(130, 84), Size = UDim2.new(1, -130 - RIGHT - 18, 0, 32), ZIndex = 18, Parent = plate })
	Kit.list(hintRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local hint = Q.Chip(hintRow, "WALK IN TO QUEUE", C.Green, C.GreenDeep, 32, 18)
	local hintScale = Kit.fx(hint.Frame)
	-- a little arrow nudging you forward
	-- the » glyph sits on the text baseline, so it's lifted to line up with the chip's centre
	local arrowHolder = new("Frame", { Name = "ArrowHolder", BackgroundTransparency = 1, Size = UDim2.fromOffset(26, 32), LayoutOrder = 2, ZIndex = 18, Parent = hintRow })
	local arrow = Kit.text({
		Name = "Arrow",
		Text = "»",
		TextSize = 30,
		TextColor3 = C.Green,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -3),
		Size = UDim2.fromOffset(26, 32),
		ZIndex = 18,
		Stroke = 3,
		Parent = arrowHolder,
	})
	local arrowLoop = TweenService:Create(arrow, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { TextTransparency = 0.7 })

	-- right block: players searching + estimate
	local divider = new("Frame", {
		Name = "Divider",
		BackgroundColor3 = C.Rim,
		BackgroundTransparency = 0.72,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -RIGHT, 0.5, 0),
		Size = UDim2.fromOffset(3, H - 40),
		ZIndex = 17,
		Parent = plate,
	})
	Kit.pill(divider)
	local countText = Kit.text({
		Name = "Count",
		Text = "0",
		TextSize = 50,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(1, -RIGHT / 2, 0, 10),
		Size = UDim2.fromOffset(RIGHT - 20, 56),
		ZIndex = 18,
		Stroke = 5,
		Parent = plate,
	})
	local countScale = Kit.fx(countText)
	Kit.text({
		Name = "CountLabel",
		Text = "SEARCHING",
		TextSize = 16,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(1, -RIGHT / 2, 0, 64),
		Size = UDim2.fromOffset(RIGHT - 20, 20),
		ZIndex = 18,
		Stroke = 2.2,
		Parent = plate,
	})
	local estText = Kit.text({
		Name = "Estimate",
		Text = "",
		TextSize = 18,
		TextColor3 = C.TextSoft,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(1, -RIGHT / 2, 0, 92),
		Size = UDim2.fromOffset(RIGHT - 20, 24),
		ZIndex = 18,
		Stroke = 2.6,
		Parent = plate,
	})

	---------------------------------------------------------------------------
	-- state
	---------------------------------------------------------------------------
	local shownMode: string? = nil
	local visible = false
	local lastCount = -1
	local lastHint = ""

	local function restyle(modeId: string)
		local m = Q.Mode(modeId)
		if not m then
			return
		end
		badge.Set(modeId)
		washGrad.Color = ColorSequence.new(m.Color)
		badgeGlow.ImageColor3 = m.Color
		title.Text = m.Title
		blurb.Text = m.Blurb
		lastCount = -1
		lastHint = ""
	end

	local function hintFor(modeId: string): (string, Color3, Color3)
		local s = Q.State
		local m = Q.Mode(modeId)
		local party = s.Party
		local size = if party then #party.Members else 1
		if s.Dodge and s.Dodge > Q.Now() then
			return "QUEUE LOCKED  ·  " .. Q.Clock(math.ceil(s.Dodge - Q.Now())), C.Red, C.RedDeep
		end
		if party and party.Leader ~= player.UserId then
			return "YOUR PARTY LEADER QUEUES", C.Gold, C.GoldDeep
		end
		local block = Config.PartyBlock(modeId, size)
		if block and m then
			return ("PARTY TOO BIG  ·  MAX %d"):format(m.MaxParty), C.Red, C.RedDeep
		end
		if modeId == "Duel" and size == 2 then
			return "PRIVATE DUEL VS YOUR PARTNER", C.Purple, C.PurpleDeep
		end
		if s.Queue and s.Queue.Mode ~= modeId then
			return "WALK IN TO SWITCH QUEUE", C.Blue, C.BlueDeep
		end
		if size > 1 then
			return "WALK IN WITH YOUR PARTY", C.Green, C.GreenDeep
		end
		return "WALK IN TO QUEUE", C.Green, C.GreenDeep
	end

	local function fill(modeId: string)
		local n = Q.Counts[modeId] or 0
		countText.Text = tostring(n)
		if lastCount >= 0 and n ~= lastCount then
			countScale.Scale = 1.25
			tween(countScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		lastCount = n
		local m = Q.Mode(modeId)
		local avg = Q.Waits[modeId]
		if n == 0 then
			estText.Text = "BE THE FIRST"
		elseif m and m.MinPlayers and n >= m.MinPlayers then
			estText.Text = "STARTING SOON"
		elseif avg and avg > 0 then
			estText.Text = "EST. " .. Q.Clock(avg)
		else
			estText.Text = "FINDING..."
		end
		local text, c, d = hintFor(modeId)
		if text ~= lastHint then
			local first = lastHint == ""
			lastHint = text
			hint.Set(text, c, d)
			arrow.TextColor3 = c
			local ok = c == C.Green or c == C.Blue or c == C.Purple
			arrowHolder.Visible = ok
			if not first then
				hintScale.Scale = 0.85
				tween(hintScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end

	local function show(modeId: string)
		if shownMode ~= modeId then
			local switching = visible
			shownMode = modeId
			restyle(modeId)
			if switching then
				cardScale.Scale = 0.94
				tween(cardScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
				Kit.playShine(sheen)
			end
		end
		fill(modeId)
		if not visible then
			visible = true
			holder.Visible = true
			card.Position = UDim2.new(0.5, 0, 0.5, 90)
			cardScale.Scale = 0.85
			tween(card, 0.45, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back)
			tween(cardScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			task.delay(0.3, function()
				Kit.playShine(sheen)
			end)
			glowLoop:Play()
			arrowLoop:Play()
			Kit.sfx("Hover")
		end
	end

	local function hide()
		if not visible then
			return
		end
		visible = false
		tween(cardScale, 0.2, { Scale = 0.85 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(card, 0.2, { Position = UDim2.new(0.5, 0, 0.5, 70) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and not visible then
				holder.Visible = false
				glowLoop:Pause()
				arrowLoop:Pause()
			end
		end)
	end

	local function nearest(): string?
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return nil
		end
		local best, bestD = nil, RANGE
		for _, d in ipairs(doors) do
			local off = root.Position - d.Pos
			local flat = Vector3.new(off.X, 0, off.Z).Magnitude
			if flat < bestD and math.abs(off.Y) < 14 then
				best, bestD = d.Mode, flat
			end
		end
		return best
	end

	task.spawn(function()
		while holder.Parent do
			local s = Q.State
			local modeId = nearest()
			-- only ever one thing on screen: no portal card while searching, in a match / its
			-- banners, in a window or in the quest dialogue
			local blocked = modeId == nil
				or ctx.Current() ~= nil
				or ctx.HudHidden()
				or s.Match ~= nil
				or s.Queue ~= nil
			if blocked then
				hide()
			else
				show(modeId :: string)
			end
			task.wait(0.2)
		end
	end)
end
