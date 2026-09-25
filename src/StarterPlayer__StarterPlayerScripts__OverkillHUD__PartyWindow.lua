--[[
	PartyWindow  (StarterPlayerScripts.OverkillHUD.PartyWindow)
	PARTY window (dock button / G): your party's three slots (leader crown, promote, kick, pending
	invites with their countdown), every player in the server with live status chips and an INVITE
	button (friends first, searchable), and each mode's party rules. Plus small party frames on the
	left edge of the screen while you're in a party, and the dock badge for invites you've received.
]]

local Players = game:GetService("Players")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local Q = ctx.Queue
	local Config = Q.Config
	local player = Players.LocalPlayer
	local isTouch = ctx.IsTouch
	local TEAL, TEAL_D = C.Teal, C.TealDeep

	local win = Kit.window({
		Name = "Party",
		Size = Vector2.new(1180, 660),
		Accent = Theme.Accent.Party,
		Title = "PARTY",
		Icon = Theme.Icon.Party,
		Parent = ctx.WindowLayer,
		OnClose = ctx.Close,
	})
	local content = win.Content -- 1128 x 570
	local LEFT_W = 480
	local RIGHT_X = 508

	---------------------------------------------------------------------------
	-- helpers
	---------------------------------------------------------------------------
	local function levelOf(p: Player): number
		local ls = p:FindFirstChild("leaderstats")
		local xp = ls and ls:FindFirstChild("XP")
		if xp and (xp:IsA("IntValue") or xp:IsA("NumberValue")) then
			return (Theme.LevelFromXp((xp :: any).Value))
		end
		return 1
	end

	local function viewOf(p: Player)
		return { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName, Level = levelOf(p), Bot = false, Player = p }
	end

	-- hover tip above an icon button
	local tipLabel = Kit.plate({
		Name = "Tip",
		Parent = win.Root,
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.new(0, 0, 0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 3,
		ZIndex = 60,
		Gradient = { C.Navy600, C.Night },
	})
	tipLabel.Visible = false
	Kit.padding(tipLabel, 16, 0, 16, 0)
	local tipText = Kit.text({ Text = "", TextSize = 18, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 61, Stroke = 2.4, Parent = tipLabel })
	local function tip(api: any, text: string)
		api.Button.MouseEnter:Connect(function()
			if isTouch then
				return
			end
			local b = api.Button
			local rel = b.AbsolutePosition - win.Root.AbsolutePosition
			local s = math.max(ctx.Scale * win.Scale.Scale, 0.01)
			tipText.Text = text
			tipLabel.Position = UDim2.fromOffset((rel.X + b.AbsoluteSize.X / 2) / s, rel.Y / s - 6)
			tipLabel.Visible = true
			local sc = Kit.fx(tipLabel)
			sc.Scale = 0.7
			tween(sc, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		api.Button.MouseLeave:Connect(function()
			tipLabel.Visible = false
		end)
	end

	local function levelRow(parent: Instance, level: number, pos: UDim2, z: number)
		local row = new("Frame", { Name = "Level", BackgroundTransparency = 1, Position = pos, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z, Parent = parent })
		Kit.list(row, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		Kit.image({ Name = "Star", Image = Theme.Icon.Star, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, ZIndex = z, Parent = row })
		local t = Kit.text({
			Name = "Text",
			Text = "LV " .. level,
			TextSize = 18,
			TextColor3 = C.Gold,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			ZIndex = z,
			Stroke = 2.4,
			Parent = row,
		})
		return row, t
	end

	---------------------------------------------------------------------------
	-- left: your party
	---------------------------------------------------------------------------
	Kit.heading({ Text = "YOUR PARTY", Parent = content, Position = UDim2.fromOffset(0, 8), Size = UDim2.fromOffset(LEFT_W - 96, 32), ZIndex = 12 })
	local countChip = Q.Chip(content, "1 / 3", TEAL, TEAL_D, 34, 13)
	countChip.Frame.AnchorPoint = Vector2.new(1, 0)
	countChip.Frame.Position = UDim2.fromOffset(LEFT_W, 7)

	local SLOT_H, SLOT_GAP, SLOT_Y = 112, 12, 52
	local slotFrames: { Frame } = {}
	for i = 1, Config.MaxPartySize do
		local f = new("Frame", {
			Name = "Slot" .. i,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, SLOT_Y + (i - 1) * (SLOT_H + SLOT_GAP)),
			Size = UDim2.fromOffset(LEFT_W, SLOT_H),
			ZIndex = 12,
			Parent = content,
		})
		slotFrames[i] = f
	end

	local searchBox: TextBox -- forward (the empty slot focuses it)

	local function clearSlot(f: Frame)
		for _, c in ipairs(f:GetChildren()) do
			c:Destroy()
		end
	end

	local function memberSlot(f: Frame, v: any, party: any, iAmLeader: boolean)
		local isLeader = party.Leader == v.UserId
		local isMe = v.UserId == player.UserId
		local p = Kit.plate({
			Name = "Member",
			Parent = f,
			Size = UDim2.fromScale(1, 1),
			Radius = 26,
			Stroke = 4,
			ZIndex = 12,
			Gradient = { C.Navy600, C.Navy800 },
		})
		Kit.bevel(p, 22, 3, 12)
		if isLeader then
			local wash = new("Frame", { Name = "Wash", BackgroundColor3 = C.Gold, Size = UDim2.new(0.6, 0, 1, 0), ZIndex = 12, Parent = p })
			Kit.corner(wash, 26)
			new("UIGradient", {
				Rotation = 0,
				Color = ColorSequence.new(C.Gold),
				Transparency = NumberSequence.new(0.78, 1),
				Parent = wash,
			})
		end
		local av = Q.Avatar(p, v, 80, if isLeader then C.Gold else TEAL, 13)
		av.Frame.Position = UDim2.fromOffset(16, 16)
		if isLeader then
			local crown = Kit.image({
				Name = "Crown",
				Image = Theme.Icon.Crown,
				AnchorPoint = Vector2.new(0.5, 0.5),
				-- sits on the rim of the head, tilted with it (35° round from the top)
				Position = UDim2.fromOffset(25, 12),
				Size = UDim2.fromOffset(46, 46),
				Rotation = -35,
				ZIndex = 16,
				Parent = p,
			})
			crown:SetAttribute("Crown", true)
		end
		local right = if iAmLeader and not isMe then 138 else 20
		Kit.text({
			Name = "PlayerName",
			Text = tostring(v.DisplayName),
			TextSize = 26,
			Position = UDim2.fromOffset(112, 12),
			Size = UDim2.new(1, -112 - right, 0, 32),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
			Stroke = 3.2,
			Parent = p,
		})
		Kit.text({
			Name = "UserName",
			Text = if v.Bot then "practice bot" else "@" .. tostring(v.Name),
			TextSize = 16,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextDim,
			Position = UDim2.fromOffset(113, 44),
			Size = UDim2.new(1, -113 - right, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
			Stroke = 2,
			Parent = p,
		})
		local tags = new("Frame", { Name = "Tags", BackgroundTransparency = 1, Position = UDim2.fromOffset(110, 68), Size = UDim2.new(1, -110 - right, 0, 30), ZIndex = 14, Parent = p })
		Kit.list(tags, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local lv = levelRow(tags, v.Level or 1, UDim2.new(), 14)
		lv.LayoutOrder = 1
		if isLeader then
			local c = Q.Chip(tags, "LEADER", C.Gold, C.GoldDeep, 26, 14)
			c.Frame.LayoutOrder = 2
		end
		if isMe then
			local c = Q.Chip(tags, "YOU", TEAL, TEAL_D, 26, 14)
			c.Frame.LayoutOrder = 3
		end
		if iAmLeader and not isMe then
			local kick = Kit.closeButton({
				Name = "Kick",
				Parent = p,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -16, 0.5, 0),
				Size = 52,
				ZIndex = 15,
				OnClick = function()
					ctx.Confirm({
						Title = "REMOVE PLAYER?",
						Text = ("%s will be removed from your party."):format(tostring(v.DisplayName)),
						Icon = Theme.Icon.Party,
						Confirm = "REMOVE",
						Color = C.Red,
						Deep = C.RedDeep,
						OnConfirm = function()
							Q.Request("kick", v.UserId)
						end,
					})
				end,
			})
			tip(kick, "Remove from party")
			local lead = Kit.button({
				Name = "Promote",
				Parent = p,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -80, 0.5, 0),
				Size = UDim2.fromOffset(52, 52),
				Radius = 16,
				Depth = 0,
				Stroke = 3,
				Color = C.Gold,
				Deep = C.GoldDeep,
				Icon = Theme.Icon.Crown,
				IconSize = 36,
				ZIndex = 15,
				HoverScale = 1.1,
				WiggleIcon = true,
				OnClick = function()
					Q.Request("promote", v.UserId)
				end,
			})
			tip(lead, "Make party leader")
		end
		return p
	end

	local function pendingSlot(f: Frame, v: any, iAmLeader: boolean)
		local p = Kit.plate({
			Name = "Pending",
			Parent = f,
			Size = UDim2.fromScale(1, 1),
			Radius = 26,
			Stroke = 4,
			ZIndex = 12,
			Gradient = { C.Navy700, C.Navy900 },
		})
		local st = p:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = Kit.darken(TEAL_D, 0.2)
		end
		local av = Q.Avatar(p, v, 80, C.Grey, 13)
		av.Frame.Position = UDim2.fromOffset(16, 16)
		local veil = new("Frame", { Name = "Veil", BackgroundColor3 = C.Night, BackgroundTransparency = 0.45, Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = av.Frame })
		Kit.pill(veil)
		local right = if iAmLeader then 150 else 20
		Kit.text({
			Name = "PlayerName",
			Text = tostring(v.DisplayName),
			TextSize = 26,
			TextColor3 = C.TextSoft,
			Position = UDim2.fromOffset(112, 14),
			Size = UDim2.new(1, -112 - right, 0, 32),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
			Stroke = 3.2,
			Parent = p,
		})
		local status = Kit.text({
			Name = "Status",
			Text = "INVITE SENT",
			TextSize = 18,
			FontFace = Theme.Font.Heavy,
			TextColor3 = Kit.lighten(TEAL, 0.25),
			Position = UDim2.fromOffset(113, 50),
			Size = UDim2.new(1, -113 - right, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 14,
			Stroke = 2.4,
			Parent = p,
		})
		local track = new("Frame", { Name = "Time", BackgroundColor3 = C.Night, Position = UDim2.fromOffset(113, 80), Size = UDim2.new(1, -113 - right, 0, 10), ZIndex = 14, Parent = p })
		Kit.pill(track)
		Kit.stroke(track, 2, C.Ink, 0, true)
		local fill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 14, Parent = track })
		Kit.pill(fill)
		Kit.gradient(fill, Kit.lighten(TEAL, 0.2), TEAL_D, 90)
		local left = math.max(0, (v.Expires or Q.Now()) - Q.Now())
		fill.Size = UDim2.fromScale(math.clamp(left / Config.InviteSeconds, 0, 1), 1)
		tween(fill, left, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Linear)
		if iAmLeader then
			Kit.button({
				Name = "Cancel",
				Parent = p,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, -2),
				Size = UDim2.fromOffset(124, 54),
				Radius = 18,
				Depth = 6,
				Stroke = 3.5,
				Color = C.Navy500,
				Deep = C.Navy700,
				Text = "CANCEL",
				TextSize = 22,
				ZIndex = 15,
				OnClick = function()
					Q.Request("cancelInvite", v.UserId)
				end,
			})
		end
		return p, status, v.Expires or 0
	end

	local function emptySlot(f: Frame, canInvite: boolean)
		local p = Kit.plate({
			Class = "TextButton",
			Name = "Empty",
			Parent = f,
			Size = UDim2.fromScale(1, 1),
			Radius = 26,
			Stroke = 3,
			ZIndex = 12,
			Color = C.Night,
			Transparency = 0.35,
		})
		local st = p:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = C.Navy500
		end
		local disc = new("Frame", {
			Name = "Plus",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0,
			Position = UDim2.fromOffset(16, 16),
			Size = UDim2.fromOffset(80, 80),
			ZIndex = 13,
			Parent = p,
		})
		Kit.pill(disc)
		Kit.gradient(disc, C.Navy600, C.Navy800, 90)
		local ds = Kit.stroke(disc, 3, C.Navy500, 0, true)
		local plus = Kit.text({ Text = "+", TextSize = 52, TextColor3 = C.TextDim, Position = UDim2.fromOffset(0, -3), ZIndex = 14, Stroke = 3.5, Parent = disc })
		Kit.text({
			Name = "Title",
			Text = "OPEN SLOT",
			TextSize = 24,
			TextColor3 = C.TextDim,
			Position = UDim2.fromOffset(112, 26),
			Size = UDim2.new(1, -130, 0, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 14,
			Stroke = 3,
			Parent = p,
		})
		Kit.text({
			Name = "Hint",
			Text = if canInvite then "Invite a player from the list" else "Only the leader can invite",
			TextSize = 17,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextDim,
			Position = UDim2.fromOffset(113, 60),
			Size = UDim2.new(1, -130, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 14,
			Stroke = 2,
			Parent = p,
		})
		if canInvite then
			local b = p :: TextButton
			b.MouseEnter:Connect(function()
				tween(ds, 0.2, { Color = TEAL })
				tween(plus, 0.2, { TextColor3 = TEAL })
				if st then
					tween(st, 0.2, { Color = TEAL_D })
				end
			end)
			b.MouseLeave:Connect(function()
				tween(ds, 0.2, { Color = C.Navy500 })
				tween(plus, 0.2, { TextColor3 = C.TextDim })
				if st then
					tween(st, 0.2, { Color = C.Navy500 })
				end
			end)
			b.Activated:Connect(function()
				Kit.sfx("Click")
				if searchBox then
					searchBox:CaptureFocus()
				end
			end)
		end
		return p
	end

	-- bottom-left: LEAVE PARTY, or how parties work when you're on your own
	local leaveHolder = new("Frame", { Name = "LeaveHolder", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, SLOT_Y + 3 * (SLOT_H + SLOT_GAP)), Size = UDim2.fromOffset(LEFT_W, 64), ZIndex = 12, Parent = content })
	local leaveBtn = Kit.button({
		Name = "LeaveParty",
		Parent = leaveHolder,
		Size = UDim2.fromScale(1, 1),
		Radius = 22,
		Depth = 7,
		Stroke = 4,
		Color = C.Red,
		Deep = C.RedDeep,
		Text = "LEAVE PARTY",
		TextSize = 28,
		ZIndex = 13,
		OnClick = function()
			Q.Request("leaveParty")
		end,
	})
	local infoPlate = Kit.plate({ Name = "HowTo", Parent = leaveHolder, Size = UDim2.fromScale(1, 1), Radius = 22, Stroke = 3, ZIndex = 12, Gradient = { C.Navy700, C.Navy900 } })
	Kit.image({ Image = Theme.Icon.Info, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(46, 46), ZIndex = 13, Parent = infoPlate })
	Kit.text({
		Text = "The leader walks into a portal and the whole party queues together.",
		TextSize = 16,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		Position = UDim2.fromOffset(66, 0),
		Size = UDim2.new(1, -80, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 13,
		Stroke = 2,
		Parent = infoPlate,
	})

	---------------------------------------------------------------------------
	-- right: players in this server
	---------------------------------------------------------------------------
	local RIGHT_W = 1128 - RIGHT_X
	local headingRight = Kit.heading({ Text = "PLAYERS", Parent = content, Position = UDim2.fromOffset(RIGHT_X, 8), Size = UDim2.fromOffset(RIGHT_W - 360, 32), ZIndex = 12 })
	local playersLabel = headingRight:FindFirstChildOfClass("TextLabel") :: TextLabel
	local search = Kit.plate({
		Name = "Search",
		Parent = content,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromOffset(1128, 0),
		Size = UDim2.fromOffset(340, 52),
		Radius = UDim.new(1, 0),
		Stroke = 4,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	local lens = new("Frame", { Name = "Lens", BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 13), Size = UDim2.fromOffset(20, 20), ZIndex = 13, Parent = search })
	Kit.pill(lens)
	Kit.stroke(lens, 3.5, C.TextSoft, 0, true)
	local handle = new("Frame", { Name = "Handle", BackgroundColor3 = C.TextSoft, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(38, 36), Size = UDim2.fromOffset(11, 4), Rotation = 45, ZIndex = 13, Parent = search })
	Kit.pill(handle)
	searchBox = new("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(52, 0),
		Size = UDim2.new(1, -66, 1, 0),
		FontFace = Theme.Font.Heavy,
		TextSize = 21,
		TextColor3 = C.Text,
		PlaceholderText = "Search players...",
		PlaceholderColor3 = C.TextDim,
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 13,
		Parent = search,
	})
	local searchStroke = search:FindFirstChildOfClass("UIStroke")
	searchBox.Focused:Connect(function()
		if searchStroke then
			tween(searchStroke, 0.2, { Color = TEAL })
		end
	end)
	searchBox.FocusLost:Connect(function()
		if searchStroke then
			tween(searchStroke, 0.2, { Color = C.Ink })
		end
	end)

	local listWell = Kit.plate({
		Name = "Well",
		Parent = content,
		Position = UDim2.fromOffset(RIGHT_X, 62),
		Size = UDim2.fromOffset(RIGHT_W, 422),
		Radius = 26,
		Stroke = 3,
		ZIndex = 12,
		Color = C.Night,
		Transparency = 0.45,
	})
	local listStroke = listWell:FindFirstChildOfClass("UIStroke")
	if listStroke then
		listStroke.Color = C.Navy600
	end
	local scroller = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- inset from the well's rounded outline so the scroll bar never touches it
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, -12, 1, -24),
		VerticalScrollBarInset = Enum.ScrollBarInset.Always,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.Rim,
		ScrollBarImageTransparency = 0.3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 13,
		Parent = listWell,
	})
	Kit.padding(scroller, 10, 2, 8, 2)
	Kit.list(scroller, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center)

	local emptyState = new("Frame", { Name = "Empty", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 13, Visible = false, Parent = listWell })
	local emptyIcon = Kit.image({ Image = Theme.Icon.Party, ImageTransparency = 0.25, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -60), Size = UDim2.fromOffset(130, 130), ZIndex = 13, Parent = emptyState })
	local emptyTitle = Kit.text({ Text = "NO ONE TO INVITE YET", TextSize = 28, TextColor3 = C.TextSoft, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 30), Size = UDim2.new(1, -40, 0, 34), ZIndex = 13, Stroke = 3.2, Parent = emptyState })
	local emptyText = Kit.text({
		Text = "Friends who join this server show up here.",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 68),
		Size = UDim2.new(1, -60, 0, 24),
		ZIndex = 13,
		Stroke = 2.2,
		Parent = emptyState,
	})

	-- friends are checked once per player (async)
	local friendCache: { [number]: boolean } = {}
	local function isFriend(uid: number): boolean
		if uid <= 0 then
			return false
		end
		local v = friendCache[uid]
		if v == nil then
			friendCache[uid] = false
			task.spawn(function()
				local ok, res = pcall(function()
					return player:IsFriendsWith(uid)
				end)
				if ok and res then
					friendCache[uid] = true
					ctx.Fire("PartyRefresh")
				end
			end)
			return false
		end
		return v
	end

	local rows: { [number]: any } = {}

	local function statusOf(v: any)
		-- what this player is up to, from their public attributes (bots: from the snapshot)
		if v.Bot then
			return { Queue = nil, Party = v.InParty == true, Match = false }
		end
		local p: Player = v.Player
		return { Queue = p:GetAttribute("OKQueue"), Party = p:GetAttribute("OKParty") ~= nil, PartyId = p:GetAttribute("OKParty"), Match = p:GetAttribute("OKMatch") == true }
	end

	local function makeRow(v: any)
		local r = Kit.plate({
			Name = "Row",
			Parent = scroller,
			Size = UDim2.new(1, 0, 0, 92),
			Radius = 24,
			Stroke = 3.5,
			ZIndex = 14,
			Gradient = { C.Navy600, C.Navy800 },
		})
		Kit.bevel(r, 20, 3, 14)
		local av = Q.Avatar(r, v, 68, TEAL, 15)
		av.Frame.Position = UDim2.fromOffset(12, 12)
		local name = Kit.text({
			Name = "PlayerName",
			Text = tostring(v.DisplayName),
			TextSize = 24,
			Position = UDim2.fromOffset(94, 12),
			Size = UDim2.new(1, -94 - 262, 0, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 15,
			Stroke = 3,
			Parent = r,
		})
		local sub = new("Frame", { Name = "Sub", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.fromOffset(94, 46), Size = UDim2.new(1, -94 - 172, 0, 32), ZIndex = 15, Parent = r })
		Kit.list(sub, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		Kit.text({
			Name = "UserName",
			Text = if v.Bot then "practice bot" else "@" .. tostring(v.Name),
			TextSize = 16,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextDim,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 1,
			ZIndex = 15,
			Stroke = 2,
			Parent = sub,
		})
		local chips = new("Frame", { Name = "Chips", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 15, Parent = sub })
		Kit.list(chips, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local _, lvText = levelRow(r, v.Level or 1, UDim2.new(1, -252, 0, 14), 15)
		local btnState = ""
		local sendingAt = 0
		local rowApi: any = { Frame = r, Name = name }
		local btn
		btn = Kit.button({
			Name = "Invite",
			Parent = r,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, -2),
			Size = UDim2.fromOffset(148, 56),
			Radius = 19,
			Depth = 6,
			Stroke = 3.5,
			Color = TEAL,
			Deep = TEAL_D,
			Text = "INVITE",
			TextSize = 24,
			ZIndex = 16,
			Shine = true,
			OnClick = function()
				if btnState ~= "invite" then
					Kit.sfx("Error")
					Kit.shake(btn.Button)
					return
				end
				btnState = "sending"
				sendingAt = os.clock()
				btn.SetText("SENDING")
				Q.Chime("invite")
				Q.Request("invite", v.UserId)
			end,
		})
		local chipKey = ""
		function rowApi.Update(view: any, party: any, iAmLeader: boolean, friend: boolean)
			rowApi.Last = { view, party, iAmLeader, friend }
			name.Text = tostring(view.DisplayName)
			lvText.Text = "LV " .. tostring(view.Level or 1)
			local st = statusOf(view)
			-- chips
			local want = {}
			local inMine = false
			local pending = nil
			if party then
				for _, x in ipairs(party.Members) do
					if x.UserId == view.UserId then
						inMine = true
					end
				end
				for _, x in ipairs(party.Pending or {}) do
					if x.UserId == view.UserId then
						pending = x
					end
				end
			end
			if st.Match then
				table.insert(want, { "IN MATCH", C.Red, C.RedDeep })
			elseif st.Queue then
				local m = Q.Mode(st.Queue)
				table.insert(want, { "SEARCHING " .. (if m then m.Short else ""), if m then m.Color else C.Blue, if m then m.Deep else C.BlueDeep })
			end
			if inMine then
				table.insert(want, { "YOUR PARTY", TEAL, TEAL_D })
			elseif st.Party then
				table.insert(want, { "IN A PARTY", C.Purple, C.PurpleDeep })
			end
			if friend then
				table.insert(want, { "FRIEND", C.Blue, C.BlueDeep })
			end
			if view.Bot then
				table.insert(want, { "BOT", C.Grey, C.GreyDeep })
			end
			while #want > 2 do
				table.remove(want)
			end
			local key = ""
			for _, w in ipairs(want) do
				key ..= w[1] .. "|"
			end
			if key ~= chipKey then
				chipKey = key
				for _, c in ipairs(chips:GetChildren()) do
					if c:IsA("GuiObject") then
						c:Destroy()
					end
				end
				for i, w in ipairs(want) do
					local c = Q.Chip(chips, w[1], w[2], w[3], 24, 16)
					c.Frame.LayoutOrder = i
				end
			end
			-- button
			local size = if party then #party.Members else 1
			local stateName, label
			if inMine then
				stateName, label = "member", "IN PARTY"
			elseif pending then
				stateName, label = "pending", "INVITED"
			elseif party and not iAmLeader then
				stateName, label = "locked", "LEADER ONLY"
			elseif st.Party or st.Match then
				stateName, label = "busy", "BUSY"
			elseif size >= Config.MaxPartySize then
				stateName, label = "full", "PARTY FULL"
			else
				stateName, label = "invite", "INVITE"
			end
			if btnState == "sending" and stateName == "invite" and os.clock() - sendingAt < 1.5 then
				return -- still waiting for the server
			end
			if stateName ~= btnState then
				btnState = stateName
				btn.SetText(label)
				btn.Enabled = stateName == "invite"
				if stateName == "invite" then
					btn.SetColor(TEAL, TEAL_D)
				elseif stateName == "member" then
					btn.SetColor(C.Navy500, C.Navy700)
				elseif stateName == "pending" then
					btn.SetColor(Kit.darken(TEAL, 0.35), Kit.darken(TEAL_D, 0.35))
				else
					btn.SetColor(C.Navy500, C.Navy700)
				end
				if btn.Label then
					btn.Label.TextSize = if #label > 8 then 19 else 24
					btn.Label.TextColor3 = if stateName == "invite" then C.Text else C.TextSoft
				end
			end
			rowApi.Pending = pending
		end
		function rowApi.Tick()
			if btnState == "sending" and os.clock() - sendingAt >= 1.5 and rowApi.Last then
				rowApi.Update(table.unpack(rowApi.Last)) -- the invite didn't go through: back to normal
			end
			if btnState == "pending" and rowApi.Pending then
				local left = math.ceil(math.max(0, (rowApi.Pending.Expires or 0) - Q.Now()))
				btn.SetText("INVITED " .. Q.Clock(left))
				if btn.Label then
					btn.Label.TextSize = 19
				end
			end
		end
		return rowApi
	end

	---------------------------------------------------------------------------
	-- bottom: party rules per mode (blocked modes turn red for big parties)
	---------------------------------------------------------------------------
	local rulesRow = new("Frame", { Name = "Rules", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 498), Size = UDim2.fromOffset(1128, 72), ZIndex = 12, Parent = content })
	Kit.list(rulesRow, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local ruleCards: { any } = {}
	for i, r in ipairs(Config.PartyRules()) do
		local p = Kit.plate({
			Name = "Rule" .. r.Mode,
			Parent = rulesRow,
			Size = UDim2.fromOffset(368, 72),
			LayoutOrder = i,
			Radius = 22,
			Stroke = 3.5,
			ZIndex = 12,
			Gradient = { C.Navy700, C.Navy900 },
		})
		local wash = new("Frame", { Name = "Wash", BackgroundColor3 = r.Color, Size = UDim2.new(0.55, 0, 1, 0), ZIndex = 12, Parent = p })
		Kit.corner(wash, 22)
		new("UIGradient", { Rotation = 0, Transparency = NumberSequence.new(0.72, 1), Parent = wash })
		local b = Q.Badge(p, r.Mode, 52, 13)
		b.Frame.Position = UDim2.fromOffset(10, 10)
		Kit.text({
			Name = "Title",
			Text = r.Title,
			TextSize = 20,
			Position = UDim2.fromOffset(74, 10),
			Size = UDim2.new(1, -84, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 13,
			Stroke = 2.6,
			Parent = p,
		})
		local rule = Kit.text({
			Name = "Rule",
			Text = r.Rule,
			TextSize = 16,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextSoft,
			Position = UDim2.fromOffset(75, 38),
			Size = UDim2.new(1, -86, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 13,
			Stroke = 2,
			Parent = p,
		})
		local blocked = Q.Chip(p, "TOO BIG", C.Red, C.RedDeep, 26, 14)
		blocked.Frame.AnchorPoint = Vector2.new(1, 0)
		blocked.Frame.Position = UDim2.new(1, -10, 0, 9)
		blocked.Frame.Visible = false
		table.insert(ruleCards, { Mode = r.Mode, Plate = p, Rule = rule, Blocked = blocked, Text = r.Rule })
	end

	---------------------------------------------------------------------------
	-- refresh
	---------------------------------------------------------------------------
	local pendingTimers: { any } = {}
	local lastPartyKey = "?"

	local function partyKey(s: any): string
		local p = s.Party
		if not p then
			return "none"
		end
		local k = p.Id .. ":" .. tostring(p.Leader) .. ":"
		for _, x in ipairs(p.Members) do
			k ..= x.UserId .. "/" .. tostring(x.Level) .. ","
		end
		k ..= "|"
		for _, x in ipairs(p.Pending or {}) do
			k ..= x.UserId .. "@" .. math.floor(x.Expires or 0) .. ","
		end
		return k
	end

	local function refreshParty(force: boolean?)
		local s = Q.State
		local key = partyKey(s)
		if key == lastPartyKey and not force then
			return
		end
		local fresh = lastPartyKey ~= "?" and key ~= lastPartyKey
		lastPartyKey = key
		table.clear(pendingTimers)
		local party = s.Party
		local iAmLeader = party == nil or party.Leader == player.UserId
		local members = if party then party.Members else { viewOf(player) }
		local fake = party or { Leader = 0, Members = members, Pending = {} }
		local i = 0
		for _, f in ipairs(slotFrames) do
			clearSlot(f)
		end
		for _, v in ipairs(members) do
			i += 1
			if i > #slotFrames then
				break
			end
			memberSlot(slotFrames[i], v, fake, iAmLeader and party ~= nil)
		end
		for _, v in ipairs(if party then party.Pending or {} else {}) do
			i += 1
			if i > #slotFrames then
				break
			end
			local _, status, exp = pendingSlot(slotFrames[i], v, iAmLeader)
			table.insert(pendingTimers, { Label = status, Expires = exp })
		end
		while i < #slotFrames do
			i += 1
			emptySlot(slotFrames[i], iAmLeader)
		end
		countChip.Set(("%d / %d"):format(#members, Config.MaxPartySize))
		leaveBtn.Button.Visible = party ~= nil
		infoPlate.Visible = party == nil
		-- rule cards
		for _, rc in ipairs(ruleCards) do
			local block = Config.PartyBlock(rc.Mode, #members)
			rc.Blocked.Frame.Visible = block ~= nil
			rc.Rule.TextColor3 = if block then Kit.lighten(C.Red, 0.35) else C.TextSoft
		end
		if fresh and win.IsOpen then
			for idx, f in ipairs(slotFrames) do
				local sc = Kit.fx(f)
				sc.Scale = 0.94
				tween(sc, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, idx * 0.04)
			end
		end
	end

	local function refreshList()
		local s = Q.State
		local party = s.Party
		local iAmLeader = party == nil or party.Leader == player.UserId
		local views = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player then
				table.insert(views, viewOf(p))
			end
		end
		for _, b in ipairs(s.Bots or {}) do
			table.insert(views, b)
		end
		local q = string.lower(searchBox.Text or "")
		local shown = {}
		for _, v in ipairs(views) do
			local hay = string.lower(tostring(v.DisplayName) .. " " .. tostring(v.Name))
			if q == "" or string.find(hay, q, 1, true) then
				table.insert(shown, v)
			end
		end
		table.sort(shown, function(a, b)
			local fa, fb = isFriend(a.UserId), isFriend(b.UserId)
			if fa ~= fb then
				return fa
			end
			if (a.Bot == true) ~= (b.Bot == true) then
				return not a.Bot
			end
			return string.lower(tostring(a.DisplayName)) < string.lower(tostring(b.DisplayName))
		end)
		local keep = {}
		for i, v in ipairs(shown) do
			keep[v.UserId] = true
			local r = rows[v.UserId]
			if not r then
				r = makeRow(v)
				rows[v.UserId] = r
			end
			r.Frame.LayoutOrder = i
			r.Update(v, party, iAmLeader, isFriend(v.UserId))
		end
		for uid, r in pairs(rows) do
			if not keep[uid] then
				r.Frame:Destroy()
				rows[uid] = nil
			end
		end
		local total = #views
		playersLabel.Text = if total > 0 then ("PLAYERS  ·  %d"):format(total) else "PLAYERS"
		emptyState.Visible = #shown == 0
		if #shown == 0 then
			local searching = q ~= ""
			emptyTitle.Text = if searching then "NO PLAYERS MATCH" else "NO ONE TO INVITE YET"
			emptyText.Text = if searching then "Try a different name." else "Friends who join this server show up here."
			emptyIcon.Visible = not searching
		end
	end

	local function refresh()
		refreshParty()
		if win.IsOpen then
			refreshList()
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if win.IsOpen then
			refreshList()
		end
	end)

	ctx.On("QueueState", refresh)
	ctx.On("PartyRefresh", refresh)

	local function watch(p: Player)
		p.AttributeChanged:Connect(function(name: string)
			if name == "OKQueue" or name == "OKParty" or name == "OKMatch" then
				if win.IsOpen then
					refreshList()
				end
			end
		end)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
	Players.PlayerAdded:Connect(function(p)
		watch(p)
		refresh()
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(refresh)
	end)

	---------------------------------------------------------------------------
	-- party frames on the left edge (while you're in a party)
	---------------------------------------------------------------------------
	local framesPos = function(hidden: boolean): UDim2
		return UDim2.new(0, if hidden then -330 else 24, 0.5, if isTouch then 40 else -60)
	end
	local frames = new("Frame", {
		Name = "PartyFrames",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = framesPos(true),
		Size = UDim2.fromOffset(290, 300),
		ZIndex = 18,
		Parent = ctx.Hud,
	})
	Kit.list(frames, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local framesHeader = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.fromOffset(290, 34), LayoutOrder = 0, ZIndex = 18, Parent = frames })
	Kit.list(framesHeader, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local headerChip = Q.Chip(framesHeader, "PARTY", TEAL, TEAL_D, 32, 19)
	headerChip.Frame.LayoutOrder = 1
	local searchChip = Q.Chip(framesHeader, "SEARCHING", C.Blue, C.BlueDeep, 28, 19)
	searchChip.Frame.LayoutOrder = 2
	searchChip.Frame.Visible = false
	local framesShown = false
	local framesKey = ""

	local function frameRow(v: any, party: any, order: number)
		local isLeader = party.Leader == v.UserId
		local b = Kit.plate({
			Class = "TextButton",
			Name = "Member",
			Parent = frames,
			Size = UDim2.fromOffset(270, 62),
			LayoutOrder = order,
			Radius = UDim.new(1, 0),
			Stroke = 4,
			ZIndex = 18,
			Gradient = { C.Navy700, C.Night },
		})
		local av = Q.Avatar(b, v, 52, if isLeader then C.Gold else TEAL, 19)
		av.Frame.AnchorPoint = Vector2.new(0, 0.5)
		av.Frame.Position = UDim2.new(0, 5, 0.5, 0)
		if isLeader then
			Kit.image({ Name = "Crown", Image = Theme.Icon.Crown, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(11, 3), Size = UDim2.fromOffset(32, 32), Rotation = -35, ZIndex = 22, Parent = b })
		end
		Kit.text({
			Name = "PlayerName",
			Text = tostring(v.DisplayName),
			TextSize = 21,
			Position = UDim2.fromOffset(66, 6),
			Size = UDim2.new(1, -84, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = if v.UserId == player.UserId then Kit.lighten(TEAL, 0.35) else C.Text,
			ZIndex = 19,
			Stroke = 2.8,
			Parent = b,
		})
		Kit.text({
			Name = "Sub",
			Text = (if isLeader then "LEADER  ·  " else "") .. "LV " .. tostring(v.Level or 1),
			TextSize = 15,
			FontFace = Theme.Font.Heavy,
			TextColor3 = if isLeader then C.Gold else C.TextDim,
			Position = UDim2.fromOffset(67, 34),
			Size = UDim2.new(1, -84, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 19,
			Stroke = 2,
			Parent = b,
		})
		local sc = Kit.fx(b)
		b.MouseEnter:Connect(function()
			tween(sc, 0.2, { Scale = 1.04 }, Enum.EasingStyle.Back)
		end)
		b.MouseLeave:Connect(function()
			tween(sc, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		;(b :: TextButton).Activated:Connect(function()
			Kit.sfx("Click")
			ctx.Open("Party")
		end)
		return b
	end

	local function refreshFrames()
		local s = Q.State
		local party = s.Party
		local show = party ~= nil and #party.Members >= 2
		local key = if party then partyKey(s) else ""
		if show and key ~= framesKey then
			framesKey = key
			for _, c in ipairs(frames:GetChildren()) do
				if c.Name == "Member" then
					c:Destroy()
				end
			end
			for i, v in ipairs(party.Members) do
				frameRow(v, party, i)
			end
		end
		local q = s.Queue
		if q then
			local m = Q.Mode(q.Mode)
			searchChip.Set("SEARCHING " .. (if m then m.Short else ""), if m then m.Color else C.Blue, if m then m.Deep else C.BlueDeep)
		end
		searchChip.Frame.Visible = q ~= nil
		local hidden = not show or ctx.Current() ~= nil or ctx.HudHidden() or s.Match ~= nil
		if framesShown ~= not hidden then
			framesShown = not hidden
			tween(frames, 0.45, { Position = framesPos(hidden) }, if hidden then Enum.EasingStyle.Quint else Enum.EasingStyle.Back)
		end
	end
	ctx.On("QueueState", refreshFrames)
	ctx.On("WindowChanged", refreshFrames)
	ctx.On("HudHidden", refreshFrames)

	-- invites you've received show on the dock button
	ctx.On("QueueState", function(s: any)
		ctx.SetBadge("Party", #(s.Invites or {}))
	end)

	---------------------------------------------------------------------------
	-- clocks for pending invites
	---------------------------------------------------------------------------
	task.spawn(function()
		while win.Root.Parent do
			if win.IsOpen then
				for _, t in ipairs(pendingTimers) do
					local left = math.ceil(math.max(0, t.Expires - Q.Now()))
					t.Label.Text = "INVITE SENT  ·  " .. Q.Clock(left)
				end
				for _, r in pairs(rows) do
					r.Tick()
				end
			end
			task.wait(0.25)
		end
	end)

	ctx.Register("Party", {
		Window = win,
		OnOpen = function()
			refreshParty(true)
			refreshList()
			for idx, f in ipairs(slotFrames) do
				local sc = Kit.fx(f)
				sc.Scale = 0.86
				tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, idx * 0.05)
			end
			for idx, rc in ipairs(ruleCards) do
				local sc = Kit.fx(rc.Plate)
				sc.Scale = 0.86
				tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.15 + idx * 0.05)
			end
		end,
		OnClose = function()
			tipLabel.Visible = false
			if searchBox:IsFocused() then
				searchBox:ReleaseFocus()
			end
		end,
	})

	refreshParty(true)
	refreshFrames()
end
