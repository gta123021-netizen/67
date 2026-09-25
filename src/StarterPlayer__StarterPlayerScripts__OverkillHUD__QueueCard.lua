--[[
	QueueCard  (StarterPlayerScripts.OverkillHUD.QueueCard)
	The bottom-right stack: the "searching" card while you're in a queue, party invites you've
	received, and the queue-lock chip after a dodged ready check. Cards slide in from the right edge
	and the stack steps aside while a window or the quest dialogue is open.
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
	local isTouch = ctx.IsTouch

	local W = 440
	local OFF = W + 90 -- how far a card slides out to the right
	local LOOP = Enum.EasingDirection.InOut

	---------------------------------------------------------------------------
	-- the column (bottom-right on desktop, top-right on phones: clear of the jump button)
	---------------------------------------------------------------------------
	local function columnPos(hidden: boolean): UDim2
		local x = if hidden then OFF else -28
		if isTouch then
			return UDim2.new(1, x, 0, 84)
		end
		return UDim2.new(1, x, 1, -28)
	end
	local column = new("Frame", {
		Name = "QueueColumn",
		BackgroundTransparency = 1,
		AnchorPoint = if isTouch then Vector2.new(1, 0) else Vector2.new(1, 1),
		Position = columnPos(false),
		Size = UDim2.fromOffset(W, 780),
		ZIndex = 20,
		Parent = ctx.Hud,
	})
	Kit.list(column, Enum.FillDirection.Vertical, 14, Enum.HorizontalAlignment.Right, if isTouch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Bottom)

	-- on phones the stack reads top-down, so the queue card goes first
	local ORDER_QUEUE = if isTouch then 1 else 100
	local ORDER_LOCK = if isTouch then 2 else 99
	local ORDER_INVITE = if isTouch then 10 else 1

	local function slot(name: string, order: number, height: number)
		local holder = new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(W, height),
			LayoutOrder = order,
			Visible = false,
			ZIndex = 20,
			Parent = column,
		})
		local card = new("Frame", {
			Name = "Card",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, OFF, 0.5, 0),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 20,
			Parent = holder,
		})
		return holder, card
	end

	local function slideIn(holder: Frame, card: Frame, height: number)
		holder.Visible = true
		tween(holder, 0.2, { Size = UDim2.fromOffset(W, height) }, Enum.EasingStyle.Quad)
		if card.Position.X.Offset > W * 0.5 then
			card.Position = UDim2.new(0.5, OFF, 0.5, 0)
		end
		tween(card, 0.55, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05)
	end

	local function slideOut(holder: Frame, card: Frame, after: (() -> ())?)
		tween(card, 0.3, { Position = UDim2.new(0.5, OFF, 0.5, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed then
				return -- slid back in before it finished leaving
			end
			-- close the gap so the rest of the stack glides down
			tween(holder, 0.22, { Size = UDim2.fromOffset(W, 0) }, Enum.EasingStyle.Quad).Completed:Connect(function(s2)
				if s2 == Enum.PlaybackState.Completed then
					holder.Visible = false
					if after then
						after()
					end
				end
			end)
		end)
	end

	-- the shared card body: drop shadow, navy plate, clipped skin with stripes and a coloured band
	local function cardBody(card: Frame, height: number, color: Color3, deep: Color3, z: number)
		local shadow = new("Frame", {
			Name = "Shadow",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.5,
			Position = UDim2.fromOffset(0, 10),
			Size = UDim2.fromScale(1, 1),
			ZIndex = z,
			Parent = card,
		})
		Kit.corner(shadow, 30)
		local plate = Kit.plate({
			Name = "Plate",
			Parent = card,
			Size = UDim2.fromScale(1, 1),
			Radius = 30,
			Stroke = 7.5, -- the clipped skin covers the inner half
			ZIndex = z,
			Gradient = { C.Navy700, C.Navy900 },
		})
		local skin = new("CanvasGroup", {
			Name = "Skin",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = z,
			Parent = plate,
		})
		Kit.corner(skin, 30)
		Kit.stripes(skin, C.Rim, 0.955, z)
		local band = new("Frame", {
			Name = "Band",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, 0, 0, math.floor(height * 0.56)),
			ZIndex = z,
			Parent = skin,
		})
		local bandGrad = Kit.gradient(band, color, deep, 90, 0.66, 1)
		local stripeGroup = new("CanvasGroup", {
			Name = "BandStripes",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, math.floor(height * 0.56)),
			ZIndex = z,
			Parent = skin,
		})
		local bandStripes = Kit.stripes(stripeGroup, color, 0.82, z, 12, 24)
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
			Parent = stripeGroup,
		})
		local vignette = new("Frame", {
			Name = "Vignette",
			BackgroundColor3 = C.Night,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0.4, 0),
			ZIndex = z,
			Parent = skin,
		})
		Kit.gradient(vignette, C.Night, C.Night, 90, 1, 0.35)
		Kit.bevel(plate, 26, 4, z + 1)
		local sheen = Kit.addShine(plate, 30)
		local api = { Plate = plate, Skin = skin, Sheen = sheen }
		function api.SetColor(c: Color3, d: Color3)
			bandGrad.Color = ColorSequence.new(c, d)
			for _, f in ipairs(bandStripes:GetChildren()) do
				if f:IsA("Frame") then
					f.BackgroundColor3 = c
				end
			end
		end
		return api
	end

	-- looping engine tweens that only run while their card is on screen
	local function loops(list: { Tween }, on: boolean)
		for _, tw in ipairs(list) do
			if on then
				tw:Play()
			else
				tw:Pause()
			end
		end
	end

	---------------------------------------------------------------------------
	-- the searching card
	---------------------------------------------------------------------------
	local QH = 262
	local qHolder, qCard = slot("Searching", ORDER_QUEUE, QH)
	local qScale = Kit.fx(qCard)
	local mode0 = Config.Modes.Duel
	local body = cardBody(qCard, QH, mode0.Color, mode0.Deep, 20)
	local plate = body.Plate
	local qLoops: { Tween } = {}

	-- badge with a soft glow and a comet ring running around it
	local BADGE = 84
	local bc = Vector2.new(20 + BADGE / 2, 20 + BADGE / 2)
	local glow = Kit.image({
		Name = "BadgeGlow",
		Image = Theme.Icon.Glow,
		ImageColor3 = mode0.Color,
		ImageTransparency = 0.45,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(bc.X, bc.Y),
		Size = UDim2.fromOffset(176, 176),
		ZIndex = 21,
		Parent = plate,
	})
	table.insert(qLoops, TweenService:Create(glow, TweenInfo.new(1.1, Enum.EasingStyle.Sine, LOOP, -1, true), { ImageTransparency = 0.78, Size = UDim2.fromOffset(150, 150) }))
	local ring = new("Frame", {
		Name = "SearchRing",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(bc.X, bc.Y),
		Size = UDim2.fromOffset(BADGE + 16, BADGE + 16),
		ZIndex = 22,
		Parent = plate,
	})
	Kit.corner(ring, math.floor(BADGE * 0.3) + 8)
	local ringStroke = Kit.stroke(ring, 4, Color3.new(1, 1, 1), 0, true)
	local ringGrad = new("UIGradient", {
		Color = ColorSequence.new(Kit.lighten(mode0.Color, 0.45), mode0.Color),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.48, 1),
			NumberSequenceKeypoint.new(0.8, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = ringStroke,
	})
	table.insert(qLoops, TweenService:Create(ringGrad, TweenInfo.new(1.25, Enum.EasingStyle.Linear, LOOP, -1), { Rotation = 360 }))
	local badge = Q.Badge(plate, "Duel", BADGE, 23)
	badge.Frame.Position = UDim2.fromOffset(20, 20)

	local qTitle = Kit.text({
		Name = "Title",
		Text = mode0.Name,
		TextSize = 32,
		Position = UDim2.fromOffset(122, 16),
		Size = UDim2.new(1, -122 - 150, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 23,
		Stroke = 3.8,
		Parent = plate,
	})

	-- SEARCHING . . .  [PRIORITY]
	local statusRow = new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(122, 58),
		Size = UDim2.new(1, -140, 0, 28),
		ZIndex = 23,
		Parent = plate,
	})
	Kit.list(statusRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local dotHolder = new("Frame", { Name = "Live", BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), LayoutOrder = 1, ZIndex = 23, Parent = statusRow })
	local dotPing = new("Frame", {
		Name = "Ping",
		BackgroundColor3 = mode0.Color,
		BackgroundTransparency = 0.2,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		ZIndex = 23,
		Parent = dotHolder,
	})
	Kit.pill(dotPing)
	table.insert(qLoops, TweenService:Create(dotPing, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1), { Size = UDim2.fromOffset(30, 30), BackgroundTransparency = 1 }))
	local dot = new("Frame", {
		Name = "Dot",
		BackgroundColor3 = Kit.lighten(mode0.Color, 0.25),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		ZIndex = 24,
		Parent = dotHolder,
	})
	Kit.pill(dot)
	Kit.stroke(dot, 2.5, C.Ink, 0, true)
	local statusText = Kit.text({
		Name = "Text",
		Text = "SEARCHING",
		TextSize = 20,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		ZIndex = 23,
		Stroke = 2.6,
		Parent = statusRow,
	})
	local dotsText = Kit.text({
		Name = "Dots",
		Text = "",
		TextSize = 20,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		Size = UDim2.new(0, 22, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 3,
		ZIndex = 23,
		Stroke = 2.6,
		Parent = statusRow,
	})
	-- PRIORITY tag riding the top edge (you were put back in after someone dodged)
	local priority = Q.Chip(plate, "PRIORITY", C.Gold, C.GoldDeep, 32, 26)
	priority.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
	priority.Frame.Position = UDim2.fromOffset(W / 2 + 10, -4)
	priority.Frame.Rotation = -3
	priority.Frame.Visible = false

	-- elapsed time + estimate
	local timer = Kit.text({
		Name = "Timer",
		Text = "0:00",
		TextSize = 44,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -22, 0, 12),
		Size = UDim2.fromOffset(140, 48),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 23,
		Stroke = 4.5,
		Parent = plate,
	})
	local estimate = Kit.text({
		Name = "Estimate",
		Text = "",
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -24, 0, 62),
		Size = UDim2.fromOffset(200, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 23,
		Stroke = 2.2,
		Parent = plate,
	})

	local divider = new("Frame", {
		Name = "Divider",
		BackgroundColor3 = C.Rim,
		BackgroundTransparency = 0.72,
		Position = UDim2.fromOffset(22, 126),
		Size = UDim2.new(1, -44, 0, 3),
		ZIndex = 21,
		Parent = plate,
	})
	Kit.pill(divider)

	-- FIGHTERS FOUND  [segments]  2 / 6
	Kit.text({
		Name = "FoundLabel",
		Text = "FIGHTERS FOUND",
		TextSize = 16,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(24, 138),
		Size = UDim2.fromOffset(220, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 22,
		Stroke = 2.2,
		Parent = plate,
	})
	local foundCount = Kit.text({
		Name = "FoundCount",
		Text = "1 / 2",
		TextSize = 21,
		TextColor3 = Kit.lighten(mode0.Color, 0.3),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -24, 0, 136),
		Size = UDim2.fromOffset(120, 26),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 22,
		Stroke = 2.8,
		Parent = plate,
	})
	local segRow = new("Frame", {
		Name = "Segments",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 166),
		Size = UDim2.new(1, -44, 0, 18),
		ZIndex = 22,
		Parent = plate,
	})
	Kit.list(segRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local segs: { any } = {}
	local segLoops: { Tween } = {}

	local function buildSegments(n: number)
		for _, s in ipairs(segs) do
			s.Frame:Destroy()
		end
		for _, tw in ipairs(segLoops) do
			tw:Cancel()
		end
		table.clear(segs)
		table.clear(segLoops)
		for i = 1, n do
			local f = new("Frame", {
				Name = "Seg" .. i,
				BackgroundColor3 = Color3.new(1, 1, 1),
				Size = UDim2.new(1 / n, -math.ceil(6 * (n - 1) / n), 1, 0),
				LayoutOrder = i,
				ZIndex = 22,
				Parent = segRow,
			})
			Kit.pill(f)
			Kit.stroke(f, 2.5, C.Ink, 0, true)
			local g = Kit.gradient(f, C.Night, C.Night, 90)
			local gloss = new("Frame", { Name = "Gloss", BackgroundTransparency = 1, Visible = false, Parent = f })
			-- a glint that runs across the slots still waiting for a player
			local glint = new("Frame", {
				Name = "Glint",
				BackgroundColor3 = Color3.new(1, 1, 1),
				Size = UDim2.fromScale(1, 1),
				ZIndex = 22,
				Parent = f,
			})
			Kit.pill(glint)
			local gg = new("UIGradient", {
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.4, 1),
					NumberSequenceKeypoint.new(0.5, 0.72),
					NumberSequenceKeypoint.new(0.6, 1),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Offset = Vector2.new(-1, 0),
				Parent = glint,
			})
			local tw = TweenService:Create(gg, TweenInfo.new(1.3, Enum.EasingStyle.Sine, LOOP, -1, false, 1.1 + i * 0.12), { Offset = Vector2.new(1, 0) })
			table.insert(segLoops, tw)
			table.insert(segs, { Frame = f, Grad = g, Gloss = gloss, Glint = glint, State = "" })
		end
	end

	-- group heads + SOLO / PARTY OF 2
	local groupRow = new("Frame", {
		Name = "Group",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 206),
		Size = UDim2.fromOffset(250, 38),
		ZIndex = 22,
		Parent = plate,
	})
	Kit.list(groupRow, Enum.FillDirection.Horizontal, -10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local groupLabel = Kit.text({
		Name = "GroupLabel",
		Text = "SOLO",
		TextSize = 20,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 50,
		ZIndex = 23,
		Stroke = 2.8,
		Parent = groupRow,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 22), Parent = groupLabel })

	local leaving = false
	local leaveBtn = Kit.button({
		Name = "Leave",
		Parent = plate,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -16),
		Size = UDim2.fromOffset(132, 52),
		Radius = 19,
		Depth = 6,
		Stroke = 3.5,
		Color = C.Red,
		Deep = C.RedDeep,
		Text = "LEAVE",
		TextSize = 25,
		ZIndex = 24,
		OnClick = function(api)
			if leaving then
				return
			end
			leaving = true
			api.Enabled = false
			Q.Request("leave")
			task.delay(1.5, function()
				leaving = false
				api.Enabled = true
			end)
		end,
	})

	-- state
	local shownMode: string? = nil
	local queueShown = false
	local lastFound = -1
	local lastGroupKey = ""

	local function selfView()
		return { UserId = player.UserId, DisplayName = player.DisplayName, Name = player.Name }
	end

	local function groupViews(s: any): { any }
		if s.Queue and (s.Queue.Size or 1) > 1 and s.Party then
			return s.Party.Members
		end
		return { selfView() }
	end

	local function setGroup(s: any)
		local views = groupViews(s)
		local key = ""
		for _, v in ipairs(views) do
			key ..= tostring(v.UserId) .. ","
		end
		if key == lastGroupKey then
			return
		end
		lastGroupKey = key
		for _, c in ipairs(groupRow:GetChildren()) do
			if c.Name == "Avatar" then
				c:Destroy()
			end
		end
		local m = Q.Mode(shownMode) or mode0
		for i, v in ipairs(views) do
			local isLeader = s.Party and s.Party.Leader == v.UserId
			local a = Q.Avatar(groupRow, v, 38, if isLeader then C.Gold else m.Color, 23 + (#views - i) * 2)
			a.Frame.LayoutOrder = i
		end
		groupLabel.Text = if #views > 1 then ("PARTY OF %d"):format(#views) else "SOLO"
	end

	local function setFound(n: number, total: number, groupSize: number)
		n = math.clamp(n, 0, total)
		foundCount.Text = ("%d / %d"):format(n, total)
		local m = Q.Mode(shownMode) or mode0
		for i, s in ipairs(segs) do
			local st = if i <= math.min(groupSize, n) then "you" elseif i <= n then "found" else "empty"
			if st ~= s.State then
				local was = s.State
				s.State = st
				if st == "you" then
					s.Grad.Color = ColorSequence.new(Kit.lighten(m.Color, 0.55), Kit.lighten(m.Color, 0.1))
				elseif st == "found" then
					s.Grad.Color = ColorSequence.new(Kit.lighten(m.Color, 0.12), m.Deep)
				else
					s.Grad.Color = ColorSequence.new(C.Navy900, C.Night)
				end
				s.Gloss.Visible = st ~= "empty"
				s.Glint.Visible = st == "empty"
				if was ~= "" and st ~= "empty" then
					-- a new fighter: the slot pops
					local sc = Kit.fx(s.Frame)
					sc.Scale = 1.35
					tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
				end
			end
		end
		if lastFound >= 0 and n > lastFound then
			Kit.sfx("Equip")
		end
		lastFound = n
	end

	local function restyle(modeId: string)
		local m = Q.Mode(modeId) or mode0
		badge.Set(modeId)
		body.SetColor(m.Color, m.Deep)
		glow.ImageColor3 = m.Color
		ringGrad.Color = ColorSequence.new(Kit.lighten(m.Color, 0.45), m.Color)
		dotPing.BackgroundColor3 = m.Color
		dot.BackgroundColor3 = Kit.lighten(m.Color, 0.25)
		qTitle.Text = m.Name or m.Title
		foundCount.TextColor3 = Kit.lighten(m.Color, 0.3)
		buildSegments(m.Players)
		lastFound = -1
		lastGroupKey = ""
		if queueShown then
			loops(segLoops, true)
		end
	end

	local function refreshQueue()
		local s = Q.State
		local q = s.Queue
		if not q then
			return
		end
		local m = Q.Mode(q.Mode)
		if not m then
			return
		end
		local elapsed = Q.Now() - (q.JoinedAt or Q.Now())
		timer.Text = Q.Clock(elapsed)
		local count = math.max(Q.Counts[q.Mode] or 0, q.Size or 1)
		setFound(count, m.Players, q.Size or 1)
		-- estimate: arena early start beats the average wait
		local est = ""
		if m.MinPlayers and m.EarlyStart and count >= m.MinPlayers and count < m.Players then
			local left = (q.JoinedAt or 0) + m.EarlyStart - Q.Now()
			est = if left > 0 then "STARTS IN " .. Q.Clock(left) else "STARTING SOON"
		else
			local avg = Q.Waits[q.Mode]
			est = if avg and avg > 0 then "EST. " .. Q.Clock(avg) else "IN QUEUE"
		end
		if q.Paused then
			-- someone in the group is in a quest dialogue: the search waits for them
			est = if q.PausedBy and q.PausedBy ~= ctx.Player.DisplayName then string.upper(string.sub(q.PausedBy, 1, 10)) .. " IS BUSY" else "IN A DIALOGUE"
		end
		estimate.Text = est
		statusText.Text = if q.Paused then "PAUSED" else "SEARCHING"
		dot.BackgroundColor3 = if q.Paused then C.Gold else Kit.lighten(m.Color, 0.25)
		dotPing.Visible = not q.Paused
		local phase = math.floor(os.clock() * 2.4) % 4
		dotsText.Text = if q.Paused then "" else string.rep(".", phase)
	end

	local function showQueue(s: any, old: any)
		local q = s.Queue
		local fresh = not queueShown
		if shownMode ~= q.Mode then
			shownMode = q.Mode
			restyle(q.Mode)
		end
		setGroup(s)
		local pr = q.Priority == true
		if pr and not priority.Frame.Visible then
			priority.Frame.Visible = true
			local sc = Kit.fx(priority.Frame)
			sc.Scale = 0.3
			tween(sc, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		elseif not pr then
			priority.Frame.Visible = false
		end
		leaving = false
		leaveBtn.Enabled = true
		refreshQueue()
		if fresh then
			queueShown = true
			slideIn(qHolder, qCard, QH)
			loops(qLoops, true)
			loops(segLoops, true)
			task.delay(0.35, function()
				Kit.playShine(body.Sheen)
			end)
			if not (old and old.Match) then
				Q.Chime("join")
			end
		elseif old and old.Queue and old.Queue.Mode ~= q.Mode then
			-- switched portals: flip the card over to the new mode
			qScale.Scale = 0.92
			tween(qScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
			Kit.playShine(body.Sheen)
			Q.Chime("join")
		end
	end

	local function hideQueue()
		if not queueShown then
			return
		end
		queueShown = false
		slideOut(qHolder, qCard, function()
			if not queueShown then
				loops(qLoops, false)
				loops(segLoops, false)
			end
		end)
	end

	-- walked into the same portal again: the card bounces so you know you're already in
	ctx.On("QueuePulse", function(modeId: string)
		if not queueShown or modeId ~= shownMode then
			return
		end
		qScale.Scale = 1.07
		tween(qScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		Kit.wiggle(badge.Frame, 0.9)
		Kit.playShine(body.Sheen)
	end)

	---------------------------------------------------------------------------
	-- queue lock chip (after declining / missing a ready check)
	---------------------------------------------------------------------------
	local LH = 64
	local lockHolder, lockCard = slot("QueueLock", ORDER_LOCK, LH)
	local lockPlate = Kit.plate({
		Name = "Plate",
		Parent = lockCard,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 0, 58),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 4.5,
		ZIndex = 20,
		Gradient = { C.Navy700, C.Night },
	})
	Kit.padding(lockPlate, 66, 0, 24, 0)
	local lockDisc = Kit.plate({
		Name = "Disc",
		Parent = lockPlate,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -62, 0.5, 0),
		Size = UDim2.fromOffset(48, 48),
		Radius = UDim.new(1, 0),
		Stroke = 3.5,
		ZIndex = 21,
		Gradient = { C.Red, C.RedDeep },
	})
	Kit.bevel(lockDisc, UDim.new(1, 0), 3, 21)
	local lockIcon = Kit.image({ Image = Theme.Icon.Clock, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(32, 32), ZIndex = 22, Parent = lockDisc })
	local lockRow = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 21, Parent = lockPlate })
	Kit.list(lockRow, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.text({
		Name = "Title",
		Text = "QUEUE LOCKED",
		TextSize = 22,
		TextColor3 = Kit.lighten(C.Red, 0.3),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		ZIndex = 21,
		Stroke = 3,
		Parent = lockRow,
	})
	local lockTime = Kit.text({
		Name = "Time",
		Text = "0:20",
		TextSize = 22,
		TextColor3 = C.Text,
		Size = UDim2.new(0, 52, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		LayoutOrder = 2,
		ZIndex = 21,
		Stroke = 3,
		Parent = lockRow,
	})
	local lockShown = false

	local function refreshLock()
		local d = Q.State.Dodge
		local left = if d then d - Q.Now() else 0
		if left > 0 then
			lockTime.Text = Q.Clock(math.ceil(left))
			if not lockShown then
				lockShown = true
				slideIn(lockHolder, lockCard, LH)
				Kit.wiggle(lockIcon, 1)
			end
		elseif lockShown then
			lockShown = false
			slideOut(lockHolder, lockCard)
		end
	end

	---------------------------------------------------------------------------
	-- party invites
	---------------------------------------------------------------------------
	local IH = 202
	local invites: { [string]: any } = {}

	local function inviteCard(inv: any, order: number)
		local holder, card = slot("Invite", ORDER_INVITE + order, IH)
		local b = cardBody(card, IH, C.Teal, C.TealDeep, 20)
		local p = b.Plate
		local from = inv.From or {}
		-- inviter's head with a little party disc
		local av = Q.Avatar(p, from, 84, C.Teal, 22)
		av.Frame.Position = UDim2.fromOffset(20, 20)
		local disc = Kit.plate({
			Name = "PartyDisc",
			Parent = p,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(94, 92),
			Size = UDim2.fromOffset(36, 36),
			Radius = UDim.new(1, 0),
			Stroke = 3,
			ZIndex = 25,
			Gradient = { Kit.lighten(C.Teal, 0.1), C.TealDeep },
		})
		Kit.image({ Image = Theme.Icon.Party, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(24, 24), ZIndex = 26, Parent = disc })
		Kit.text({
			Name = "Title",
			Text = "PARTY INVITE",
			TextSize = 28,
			TextColor3 = Kit.lighten(C.Teal, 0.35),
			Position = UDim2.fromOffset(122, 18),
			Size = UDim2.new(1, -122 - 80, 0, 34),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 23,
			Stroke = 3.4,
			Parent = p,
		})
		local who = tostring(from.DisplayName or "Someone")
		if #who > 16 then
			who = string.sub(who, 1, 15) .. "…"
		end
		Kit.text({
			Name = "Body",
			Text = ('<font color="#FFFFFF">%s</font> wants you in their party'):format(who),
			RichText = true,
			TextSize = 18,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextSoft,
			Position = UDim2.fromOffset(122, 56),
			Size = UDim2.new(1, -140, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 23,
			Stroke = 2.4,
			Parent = p,
		})
		local timeText = Kit.text({
			Name = "Time",
			Text = "0:30",
			TextSize = 22,
			TextColor3 = C.TextSoft,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -24, 0, 22),
			Size = UDim2.fromOffset(70, 26),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 23,
			Stroke = 2.8,
			Parent = p,
		})
		-- who's already in that party
		local heads = new("Frame", {
			Name = "Members",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(122, 84),
			Size = UDim2.fromOffset(220, 28),
			ZIndex = 22,
			Parent = p,
		})
		Kit.list(heads, Enum.FillDirection.Horizontal, -8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local list = inv.Members or {}
		for i, v in ipairs(list) do
			local a = Q.Avatar(heads, v, 28, C.Teal, 23 + (#list - i) * 2)
			a.Frame.LayoutOrder = i
		end
		local sizeText = Kit.text({
			Name = "Size",
			Text = ("%d / %d"):format(#list, Config.MaxPartySize),
			TextSize = 18,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextDim,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 20,
			ZIndex = 23,
			Stroke = 2.2,
			Parent = heads,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 18), Parent = sizeText })

		local busy = false
		local function answer(yes: boolean)
			if busy then
				return
			end
			busy = true
			if yes then
				Q.Chime("accept")
			end
			Q.Request("respond", inv.PartyId, yes)
		end
		Kit.button({
			Name = "Decline",
			Parent = p,
			Position = UDim2.new(0, 20, 1, -84),
			Size = UDim2.fromOffset(160, 54),
			Radius = 18,
			Depth = 6,
			Stroke = 3.5,
			Color = C.Navy500,
			Deep = C.Navy700,
			Text = "DECLINE",
			TextSize = 21,
			ZIndex = 24,
			OnClick = function()
				answer(false)
			end,
		})
		Kit.button({
			Name = "Accept",
			Parent = p,
			Position = UDim2.new(0, 192, 1, -84),
			Size = UDim2.new(1, -212, 0, 54),
			Radius = 18,
			Depth = 6,
			Stroke = 3.5,
			Color = C.Green,
			Deep = C.GreenDeep,
			Text = "ACCEPT",
			TextSize = 24,
			ZIndex = 24,
			Shine = true,
			OnClick = function()
				answer(true)
			end,
		})
		-- time left, draining
		local track = new("Frame", {
			Name = "TimeBar",
			BackgroundColor3 = C.Night,
			Position = UDim2.new(0, 22, 1, -22),
			Size = UDim2.new(1, -44, 0, 10),
			ZIndex = 22,
			Parent = p,
		})
		Kit.pill(track)
		Kit.stroke(track, 2, C.Ink, 0, true)
		local fill = new("Frame", {
			Name = "Fill",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 22,
			Parent = track,
		})
		Kit.pill(fill)
		Kit.gradient(fill, Kit.lighten(C.Teal, 0.25), C.TealDeep, 90)
		local left = math.max(0, (inv.Expires or Q.Now()) - Q.Now())
		fill.Size = UDim2.fromScale(math.clamp(left / Config.InviteSeconds, 0, 1), 1)
		tween(fill, left, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Linear)

		slideIn(holder, card, IH)
		task.delay(0.4, function()
			Kit.playShine(b.Sheen)
			Kit.wiggle(disc, 1)
		end)
		return { Holder = holder, Card = card, Time = timeText, Expires = inv.Expires or 0 }
	end

	local function syncInvites(s: any)
		local seen = {}
		for i, inv in ipairs(s.Invites or {}) do
			if i > 3 then
				break -- three at a time is plenty
			end
			seen[inv.PartyId] = true
			local c = invites[inv.PartyId]
			if not c then
				invites[inv.PartyId] = inviteCard(inv, i)
			else
				c.Expires = inv.Expires or c.Expires
				c.Holder.LayoutOrder = ORDER_INVITE + i
			end
		end
		for id, c in pairs(invites) do
			if not seen[id] then
				invites[id] = nil
				slideOut(c.Holder, c.Card, function()
					c.Holder:Destroy()
				end)
			end
		end
	end

	---------------------------------------------------------------------------
	-- wiring
	---------------------------------------------------------------------------
	local function apply(s: any, old: any)
		if s.Queue and not s.Match then
			showQueue(s, old)
		else
			hideQueue()
		end
		syncInvites(s)
		refreshLock()
	end
	ctx.On("QueueState", apply)
	ctx.On("QueueCounts", function()
		if queueShown then
			refreshQueue()
		end
	end)

	-- step aside for windows, the quest dialogue and the match screen
	local hidden = false
	local function updateHidden()
		local h = ctx.Current() ~= nil or ctx.HudHidden() or Q.State.Match ~= nil
		if h ~= hidden then
			hidden = h
			tween(column, 0.4, { Position = columnPos(h) }, Enum.EasingStyle.Quint)
		end
	end
	ctx.On("WindowChanged", updateHidden)
	ctx.On("HudHidden", updateHidden)
	ctx.On("QueueState", updateHidden)

	-- clocks
	task.spawn(function()
		while column.Parent do
			if queueShown then
				refreshQueue()
			end
			if lockShown or Q.State.Dodge then
				refreshLock()
			end
			for _, c in pairs(invites) do
				c.Time.Text = Q.Clock(math.ceil(math.max(0, c.Expires - Q.Now())))
			end
			task.wait(0.2)
		end
	end)

	buildSegments(mode0.Players)
	apply(Q.State, {})
end
