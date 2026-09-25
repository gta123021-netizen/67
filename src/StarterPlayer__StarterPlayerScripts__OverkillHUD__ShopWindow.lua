--[[
	ShopWindow  (StarterPlayerScripts.OverkillHUD.ShopWindow)
	Tabbed shop: Auras (coins), Passes (Robux game passes), Coins (Robux coin packs).
	Items come from ReplicatedStorage.OverkillUI.ShopConfig. Purchases are checked by ShopServer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local ShopConfig = require(UI:WaitForChild("ShopConfig"))
	local Remotes = UI:WaitForChild("Remotes")
	local ShopRequest = Remotes:WaitForChild("ShopRequest") :: RemoteFunction
	local ShopEvent = Remotes:WaitForChild("ShopEvent") :: RemoteEvent
	local AuraSprites = require(script.Parent:WaitForChild("AuraSprites"))
	local Auras = UI:WaitForChild("Auras")

	local accent, accentDeep = Theme.Accent.Shop[1], Theme.Accent.Shop[2]
	local state = { Owned = {}, Equipped = nil :: string?, Loaded = false }

	local W, H = 1250, 590 -- wide enough for 4 cards in a row, so no tab ever cuts a card in half
	local win = Kit.window({
		Name = "Shop",
		Size = Vector2.new(W, H),
		Accent = Theme.Accent.Shop,
		Title = "SHOP",
		Icon = Theme.Icon.Shop,
		Parent = ctx.WindowLayer,
		OnClose = ctx.Close,
	})
	local content = win.Content

	---------------------------------------------------------------------------
	-- sidebar: tabs + wallet
	---------------------------------------------------------------------------
	local side = new("Frame", { Name = "Side", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(0, 200, 1, -14), ZIndex = 12, Parent = content })
	local tabList = new("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 300), ZIndex = 12, Parent = side })
	Kit.list(tabList, Enum.FillDirection.Vertical, 16, Enum.HorizontalAlignment.Center)

	local wallet = Kit.plate({
		Name = "Wallet",
		Parent = side,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -6),
		Size = UDim2.new(1, 0, 0, 104),
		Radius = 22,
		Stroke = 4,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	Kit.text({
		Text = "YOUR COINS",
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = 13,
		Stroke = 2.4,
		Parent = wallet,
	})
	local walletRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 0, 48), ZIndex = 13, Parent = wallet })
	Kit.list(walletRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local walletCoin = Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(46, 46), ZIndex = 14, LayoutOrder = 1, Parent = walletRow })
	local walletText = Kit.text({
		Text = "0",
		TextSize = 34,
		TextColor3 = C.Gold,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 14,
		LayoutOrder = 2,
		Stroke = 4,
		Parent = walletRow,
	})
	local setWallet = Kit.counter(walletText, Theme.Comma, 0)

	---------------------------------------------------------------------------
	-- item grid
	---------------------------------------------------------------------------
	local scroller = new("ScrollingFrame", {
		Name = "Items",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(218, 0),
		Size = UDim2.new(1, -218, 1, -74),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.Rim,
		ScrollBarImageTransparency = 0.3,
		ZIndex = 12,
		Parent = content,
	})
	Kit.padding(scroller, 6, 14, 16, 18)
	new("UIGridLayout", {
		CellSize = UDim2.fromOffset(228, 350),
		CellPadding = UDim2.fromOffset(14, 16),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroller,
	})

	-- tip strip under the grid, changes with the tab
	local tipBar = Kit.plate({
		Name = "Tip",
		Parent = content,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 224, 1, -6),
		Size = UDim2.new(1, -228, 0, 58),
		Radius = UDim.new(1, 0),
		Stroke = 3.5,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	local tipIcon = Kit.image({ Image = Theme.Icon.Check, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(42, 42), ZIndex = 13, Parent = tipBar })
	Kit.snapEnd(tipIcon, 8) -- centred in the pill's round end: 8 from the left, top and bottom
	local tipText = Kit.text({
		Text = "",
		TextSize = 19,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		Position = UDim2.fromOffset(68, 0),
		Size = UDim2.new(1, -84, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 13,
		Stroke = 2.4,
		Parent = tipBar,
	})
	local TIPS = {
		Auras = { "Auras are yours forever - buy once, swap any time. They stay on after you respawn.", 18469571139 },
		Passes = { "Passes never expire and stack with each other. Boosts apply to every quest reward.", 18469531323 },
		Coins = { "Coins also pour in from daily, weekly and monthly quests - talk to Goki at the crater.", 5175224022 },
	}

	local cards: { any } = {}
	local tabs: { [string]: any } = {}
	local currentTab = ShopConfig.Tabs[1].Id

	local function rarityOf(item: any)
		return Theme.Rarity[item.Rarity or "Common"] or Theme.Rarity.Common
	end

	-- aura cards play the aura itself, animated, from its real particles and beams (drawn in 2D:
	-- a ViewportFrame can't show particles). It stands in the free part of the picture: below the
	-- rarity chip and above the bottom edge.
	local AURA_PPS = 22 -- pixels per stud in a card
	local function makeAuraArt(card: GuiObject, show: GuiObject, auraName: string, sheet: number?, focus: { number }?)
		local src = Auras:FindFirstChild(auraName)
		if not src and not sheet then
			return nil
		end
		local clip = new("Frame", {
			Name = "AuraClip",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = show.Position + UDim2.fromOffset(4, 4),
			Size = show.Size - UDim2.fromOffset(8, 8),
			ZIndex = 15,
			Parent = card,
		})
		-- the clip is 200 x 182
		if sheet then
			-- the real aura, captured from the game (exact colours and glow), looping. Its visual centre
			-- sits in the middle of the picture (a touch low, clear of the rarity chip), with room to
			-- spare on every side so nothing is ever cut off
			local SIZE = 140
			return AuraSprites.newSheet(clip, sheet, { Size = SIZE, Centre = AuraSprites.focusCentre(Vector2.new(100, 96), SIZE, focus), ZIndex = 15 })
		end
		return AuraSprites.new(clip, src, { PixelsPerStud = AURA_PPS, Feet = Vector2.new(100, 171), ZIndex = 15, Soft = Theme.Icon.Glow, Budget = 110 })
	end

	local function makeCard(item: any, index: number)
		local r = rarityOf(item)
		local cell = new("Frame", { Name = item.Id, BackgroundTransparency = 1, LayoutOrder = index, ZIndex = 12, Parent = scroller })
		local card = Kit.plate({
			Name = "Card",
			Parent = cell,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Radius = 24,
			Stroke = 4,
			ZIndex = 12,
			Gradient = { C.Navy600, C.Navy800 },
		})
		local cardScale = Kit.fx(card)
		Kit.bevel(card, 20, 4, 12)
		local fancy = (r.Order or 1) >= 4 -- legendary + mythic get a moving shine on the border
		local cardStroke = card:FindFirstChildOfClass("UIStroke") :: UIStroke
		local shimmer = nil
		if fancy then
			cardStroke.Color = Color3.new(1, 1, 1)
			cardStroke.Thickness = 4.5
			shimmer = Kit.shimmer(cardStroke, r.Color, r.Deep)
		end

		-- showcase window
		local show = new("CanvasGroup", {
			Name = "Showcase",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.new(1, -20, 0, 190),
			ZIndex = 13,
			Parent = card,
		})
		Kit.corner(show, 18)
		-- the gradient lives on a child: a UIGradient on the CanvasGroup itself would tint the art
		local backdrop = new("Frame", { Name = "Backdrop", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 13, Parent = show })
		Kit.gradient(backdrop, Kit.lighten(r.Color, 0.05), Kit.darken(r.Deep, 0.45), 90)
		local rays = Kit.rays(show, Color3.new(1, 1, 1), 380, 0.72, 13, false)
		local shade = new("Frame", { BackgroundColor3 = C.Night, Position = UDim2.fromScale(0, 0.55), Size = UDim2.fromScale(1, 0.45), ZIndex = 13, Parent = show })
		Kit.gradient(shade, C.Night, C.Night, 90, 1, 0.35)
		local preview = nil
		local art: GuiObject? = nil
		if item.Aura then
			preview = makeAuraArt(card, show, item.Aura, item.CardSheet, item.CardFocus)
		end
		-- the art never touches the rarity / deal chip (top) or the x2 badge (bottom right): it is
		-- fitted into the free part of the picture (picture-local pixels). Cards with a badge keep
		-- the art centred in the picture and a size smaller, so the badge sits in the corner beside it
		-- instead of pushing the art against the left edge
		local ART_X0, ART_X1 = 12, 196
		local ART_Y0, ART_Y1 = 44, 182
		if item.Badge then
			ART_X0, ART_X1 = 46, 162
			ART_Y0, ART_Y1 = 42, 158
		end
		if not preview and item.CoinArt then
			-- coin packs are the same coin in growing piles, so the whole tab reads as one family
			local bx0, bx1, by0, by1 = Kit.coinBounds(item.CoinArt)
			local S = math.min((ART_Y1 - ART_Y0) / (by1 - by0), (ART_X1 - ART_X0) / (bx1 - bx0), if item.CoinArt == 1 then 150 else 200)
			local pile = Kit.coinArt(show, item.CoinArt, S, 14)
			pile.Position = UDim2.fromOffset((ART_X0 + ART_X1) / 2 - ((bx0 + bx1) / 2 - 0.5) * S, (ART_Y0 + ART_Y1) / 2 - ((by0 + by1) / 2 - 0.5) * S)
			art = pile
		elseif not preview then
			local S = math.min(ART_Y1 - ART_Y0, ART_X1 - ART_X0, 136)
			art = Kit.image({
				Name = "Art",
				Image = Theme.decal(item.Icon or 5175224022),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset((ART_X0 + ART_X1) / 2, (ART_Y0 + ART_Y1) / 2),
				Size = UDim2.fromOffset(S, S),
				ZIndex = 14,
				Parent = show,
			})
		end
		if fancy then
			local sparkleHolder = new("Frame", { Name = "SparkleHolder", BackgroundTransparency = 1, Position = show.Position + UDim2.fromOffset(8, 8), Size = show.Size - UDim2.fromOffset(16, 16), ZIndex = 15, Parent = card })
			Kit.sparkles(sparkleHolder, r.Color, 6, 15, function()
				return win.Root.Visible and cell.Visible
			end)
		end
		local rim = new("Frame", { Name = "ShowRim", BackgroundTransparency = 1, Position = show.Position, Size = show.Size, ZIndex = 16, Parent = card })
		Kit.corner(rim, 18)
		Kit.stroke(rim, 3, C.Ink, 0, true)

		-- rarity tag
		local rtag = Kit.plate({
			Name = "Rarity",
			Parent = card,
			Position = UDim2.fromOffset(18, 18),
			Size = UDim2.new(0, 0, 0, 26),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = UDim.new(1, 0),
			Stroke = 2.5,
			ZIndex = 17,
			Gradient = { Kit.lighten(r.Color, 0.1), r.Deep },
		})
		Kit.padding(rtag, 10, 0, 10, 0)
		Kit.text({ Text = r.Name, TextSize = 14, FontFace = Theme.Font.Heavy, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 18, Stroke = 2.2, Parent = rtag })

		if item.Tag then
			-- a deal tag takes the rarity chip's place (same size and spot, inside the picture);
			-- the picture's colour still shows the rarity
			rtag.Visible = false
			local ribbon = Kit.plate({
				Name = "Ribbon",
				Parent = card,
				Position = UDim2.fromOffset(18, 18),
				Size = UDim2.new(0, 0, 0, 26),
				AutomaticSize = Enum.AutomaticSize.X,
				Radius = UDim.new(1, 0),
				Stroke = 2.5,
				ZIndex = 18,
				Gradient = { C.Red, C.RedDeep },
			})
			Kit.padding(ribbon, 10, 0, 10, 0)
			Kit.text({ Text = item.Tag, TextSize = 14, FontFace = Theme.Font.Heavy, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 19, Stroke = 2.2, Parent = ribbon })
		end
		if item.Badge then
			Kit.text({
				Name = "Badge",
				Text = item.Badge,
				TextSize = 48,
				TextColor3 = C.Gold,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -15, 0, 196), -- tucked into the picture's corner
				Size = UDim2.fromOffset(90, 56),
				Rotation = -10,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 17,
				Stroke = 5,
				Parent = card,
			})
		end
		local owned = Kit.image({
			Name = "Owned",
			Image = Theme.Icon.Check,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, -38, 0, 38), -- inside the picture, clear of its rim
			Size = UDim2.fromOffset(40, 40),
			Visible = false,
			ZIndex = 18,
			Parent = card,
		})

		-- name + line under it
		Kit.text({
			Name = "Title",
			Text = item.Name,
			TextSize = 27,
			Position = UDim2.fromOffset(8, 206),
			Size = UDim2.new(1, -16, 0, 32),
			ZIndex = 14,
			Stroke = 3.5,
			Parent = card,
		})
		if item.Amount then
			local row = new("Frame", { Name = "Amount", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 240), Size = UDim2.new(1, 0, 0, 34), ZIndex = 14, Parent = card })
			Kit.list(row, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(32, 32), ZIndex = 15, LayoutOrder = 1, Parent = row })
			Kit.text({ Text = Theme.Comma(item.Amount), TextSize = 26, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 15, LayoutOrder = 2, Stroke = 3.5, Parent = row })
		else
			Kit.text({
				Name = "Desc",
				Text = item.Desc or "",
				TextSize = 15,
				FontFace = Theme.Font.Bold,
				TextColor3 = C.TextSoft,
				TextWrapped = true,
				Position = UDim2.fromOffset(14, 240),
				Size = UDim2.new(1, -28, 0, 38),
				ZIndex = 14,
				Stroke = false,
				Parent = card,
			})
		end

		local c: any = { Item = item, Cell = cell, Card = card, Scale = cardScale, Show = show, Rays = rays, Preview = preview, Art = art, Owned = owned, Stroke = cardStroke, Shimmer = shimmer, Rarity = r }
		local tryOn = item.Aura ~= nil
		c.Compact = tryOn
		c.Action = Kit.button({
			Name = "Action",
			Parent = card,
			AnchorPoint = if tryOn then Vector2.new(0, 1) else Vector2.new(0.5, 1),
			Position = if tryOn then UDim2.new(0, 10, 1, -10) else UDim2.new(0.5, 0, 1, -10),
			Size = if tryOn then UDim2.new(1, -88, 0, 54) else UDim2.new(1, -20, 0, 54),
			Radius = 17,
			Depth = 6,
			Stroke = 3.5,
			Color = C.Green,
			Deep = C.GreenDeep,
			Icon = Theme.Icon.Coin,
			IconSize = if tryOn then 30 else 34,
			Text = "",
			TextSize = if tryOn then 24 else 26,
			ZIndex = 16,
			Shine = true,
			OnClick = function()
				ctx.Fire("ShopBuy", c)
			end,
		})
		if tryOn then
			local eye = Kit.button({
				Name = "TryOn",
				Parent = card,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -10, 1, -10),
				Size = UDim2.fromOffset(62, 54),
				Radius = 17,
				Depth = 6,
				Stroke = 3.5,
				Color = C.Navy500,
				Deep = C.Navy700,
				ZIndex = 16,
				OnClick = function()
					ctx.Fire("AuraPreview", item.Id)
				end,
			})
			Kit.eyeGlyph(eye.Content, 36, 19, item.Tint or r.Color)
			-- clicking the picture itself opens the try-on too
			local inspect = new("TextButton", {
				Name = "Inspect",
				AutoButtonColor = false,
				Text = "",
				BackgroundTransparency = 1,
				Position = show.Position,
				Size = show.Size,
				ZIndex = 16,
				Parent = card,
			})
			inspect.Activated:Connect(function()
				Kit.sfx("Click")
				ctx.Fire("AuraPreview", item.Id)
			end)
			c.TryOn = eye
		end
		card.MouseEnter:Connect(function()
			tween(cardScale, 0.25, { Scale = 1.03 }, Enum.EasingStyle.Back)
			if art then
				Kit.wiggle(art, 0.6)
			end
		end)
		card.MouseLeave:Connect(function()
			tween(cardScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		card.Active = false
		table.insert(cards, c)
		return c
	end

	for i, item in ipairs(ShopConfig.Items) do
		makeCard(item, i)
	end

	---------------------------------------------------------------------------
	-- live robux prices
	---------------------------------------------------------------------------
	local livePrice: { [string]: number } = {}
	task.spawn(function()
		for _, item in ipairs(ShopConfig.Items) do
			local id = item.GamePassId or item.ProductId
			if item.Currency == "Robux" and id and id ~= 0 then
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(id, if item.GamePassId then Enum.InfoType.GamePass else Enum.InfoType.Product)
				end)
				if ok and info and info.PriceInRobux then
					livePrice[item.Id] = info.PriceInRobux
				end
			end
		end
		ctx.Fire("ShopRefresh")
	end)

	---------------------------------------------------------------------------
	-- card state
	---------------------------------------------------------------------------
	local function setAction(c: any, text: string, icon: string?, color: Color3, deep: Color3)
		local a = c.Action
		a.SetText(text)
		a.SetColor(color, deep)
		if a.Icon then
			a.Icon.Visible = icon ~= nil
			if icon then
				a.Icon.Image = icon
			end
		end
	end

	local function refreshCard(c: any)
		local item = c.Item
		local owned = state.Owned[item.Id] == true
		c.Owned.Visible = owned and item.Tab ~= "Coins"
		if item.Currency == "Coins" then
			if owned then
				if state.Equipped == item.Id then
					setAction(c, "EQUIPPED", if c.Compact then nil else Theme.Icon.Check, C.Navy500, C.Navy700)
				else
					setAction(c, "EQUIP", nil, C.Blue, C.BlueDeep)
				end
			else
				setAction(c, Theme.Comma(item.Price or 0), Theme.Icon.Coin, C.Green, C.GreenDeep)
			end
		elseif item.GamePassId ~= nil then
			if owned then
				setAction(c, "OWNED", Theme.Icon.Check, C.Navy500, C.Navy700)
			else
				setAction(c, Theme.Comma(livePrice[item.Id] or item.PriceHint or 0), Theme.Icon.Robux, C.Green, C.GreenDeep)
			end
		else
			setAction(c, Theme.Comma(livePrice[item.Id] or item.PriceHint or 0), Theme.Icon.Robux, C.Green, C.GreenDeep)
		end
		local equipped = state.Equipped == item.Id
		if c.Shimmer then
			local a, b = if equipped then C.Gold else c.Rarity.Color, if equipped then C.GoldDeep else c.Rarity.Deep
			c.Shimmer.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, a),
				ColorSequenceKeypoint.new(0.45, a),
				ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
				ColorSequenceKeypoint.new(0.55, b),
				ColorSequenceKeypoint.new(1, b),
			})
		else
			c.Stroke.Color = if equipped then C.Gold else C.Ink
		end
	end

	local function affordable(): number
		local n = 0
		for _, item in ipairs(ShopConfig.Items) do
			if item.Currency == "Coins" and not state.Owned[item.Id] and (item.Price or 0) <= ctx.Stats.Coins then
				n += 1
			end
		end
		return n
	end

	local function refreshAll()
		for _, c in ipairs(cards) do
			refreshCard(c)
		end
		ctx.SetBadge("Shop", if state.Loaded then affordable() else 0)
	end
	ctx.On("ShopRefresh", refreshAll)

	local function applyState(s: any)
		if type(s) ~= "table" then
			return
		end
		state.Owned = if type(s.Owned) == "table" then s.Owned else {}
		state.Equipped = s.Equipped
		state.Loaded = true
		ctx.ShopState = state
		refreshAll()
		ctx.Fire("ShopState", state)
	end

	ctx.On("Coins", function(v: number)
		setWallet(v)
		if state.Loaded then
			ctx.SetBadge("Shop", affordable())
		end
	end)

	---------------------------------------------------------------------------
	-- tabs
	---------------------------------------------------------------------------
	local function selectTab(id: string, instant: boolean?)
		currentTab = id
		local tip = TIPS[id]
		if tip then
			tipText.Text = tip[1]
			tipIcon.Image = Theme.decal(tip[2])
			if not instant then
				Kit.wiggle(tipIcon, 0.7)
			end
		end
		for tid, t in pairs(tabs) do
			if tid == id then
				t.SetColor(accent, accentDeep)
			else
				t.SetColor(C.Navy600, C.Navy800)
			end
		end
		local i = 0
		for _, c in ipairs(cards) do
			local vis = c.Item.Tab == id
			c.Cell.Visible = vis
			if vis and not instant then
				i += 1
				c.Scale.Scale = 0.82
				tween(c.Scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, i * 0.05)
			end
		end
		scroller.CanvasPosition = Vector2.zero
	end

	for i, t in ipairs(ShopConfig.Tabs) do
		tabs[t.Id] = Kit.button({
			Name = t.Id,
			Parent = tabList,
			Size = UDim2.new(1, 0, 0, 78),
			LayoutOrder = i,
			Radius = 24,
			Depth = 7,
			Stroke = 4,
			Color = C.Navy600,
			Deep = C.Navy800,
			Icon = Theme.decal(t.Icon),
			IconSize = 50,
			Gap = 8,
			Text = t.Title,
			TextSize = 27,
			ZIndex = 13,
			WiggleIcon = true,
			OnClick = function()
				if currentTab ~= t.Id then
					selectTab(t.Id)
				end
			end,
		})
	end
	selectTab(currentTab, true)

	---------------------------------------------------------------------------
	-- buying
	---------------------------------------------------------------------------
	local busy = false
	local function celebrate(c: any, color: Color3)
		ctx.Burst(ctx.ToRoot(c.Show), color, 14)
		local flash = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.2, Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = c.Show })
		tween(flash, 0.5, { BackgroundTransparency = 1 }).Completed:Connect(function()
			flash:Destroy()
		end)
		c.Scale.Scale = 1.1
		tween(c.Scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end

	local function comingSoon()
		ctx.Toast({
			Title = "COMING SOON",
			Text = if RunService:IsStudio() then "Set the id in OverkillUI.ShopConfig" else "This one isn't on sale yet",
			Icon = Theme.Icon.Robux,
			Color = C.Blue,
			Deep = C.BlueDeep,
		})
	end

	ctx.On("ShopBuy", function(c: any)
		if busy then
			return
		end
		local item = c.Item
		if item.Currency == "Coins" then
			local owned = state.Owned[item.Id]
			if not owned and ctx.Stats.Coins < (item.Price or 0) then
				Kit.shake(c.Action.Button)
				Kit.sfx("Error")
				ctx.Toast({
					Title = "NOT ENOUGH COINS",
					Text = ("You need %s more - finish quests to earn them"):format(Theme.Comma((item.Price or 0) - ctx.Stats.Coins)),
					Icon = Theme.Icon.Coin,
					Color = C.Red,
					Deep = C.RedDeep,
				})
				return
			end
			local action = if not owned then "buy" elseif state.Equipped == item.Id then "unequip" else "equip"
			local function run()
				busy = true
				c.Action.SetText("...")
				local ok, res = pcall(function()
					return ShopRequest:InvokeServer(action, item.Id)
				end)
				busy = false
				if ok and type(res) == "table" and res.Ok then
					applyState(res.State)
					if action == "buy" then
						Kit.sfx("Buy")
						ctx.FlyCoins(walletCoin, c.Show, 10)
						task.delay(0.55, function()
							celebrate(c, rarityOf(item).Color)
						end)
						ctx.Toast({ Title = "UNLOCKED!", Text = item.Name .. " is yours - it's on now", Icon = Theme.Icon.Check, Color = C.Green, Deep = C.GreenDeep })
					elseif action == "equip" then
						Kit.sfx("Equip")
						celebrate(c, rarityOf(item).Color)
					end
				else
					refreshCard(c)
					local why = if ok and type(res) == "table" then res.Err else "Shop is busy"
					Kit.shake(c.Action.Button)
					Kit.sfx("Error")
					ctx.Toast({ Title = "HOLD ON", Text = tostring(why or "Try again in a moment"), Icon = Theme.Icon.Shop, Color = C.Red, Deep = C.RedDeep })
				end
			end
			if action == "buy" then
				ctx.Confirm({
					Title = "UNLOCK " .. string.upper(item.Name) .. "?",
					Text = "Yours forever - it equips right away.",
					Icon = Theme.Icon.Shop,
					Price = item.Price,
					Confirm = "BUY",
					Color = C.Green,
					Deep = C.GreenDeep,
					OnConfirm = run,
				})
			else
				run()
			end
		elseif item.GamePassId ~= nil then
			if state.Owned[item.Id] then
				return
			end
			if item.GamePassId == 0 then
				comingSoon()
				return
			end
			MarketplaceService:PromptGamePassPurchase(player, item.GamePassId)
		elseif item.ProductId ~= nil then
			if item.ProductId == 0 then
				comingSoon()
				return
			end
			MarketplaceService:PromptProductPurchase(player, item.ProductId)
		end
	end)

	-- the try-on screen buys / equips through the same path as the card buttons
	ctx.On("ShopBuyId", function(id: string)
		for _, c in ipairs(cards) do
			if c.Item.Id == id then
				ctx.Fire("ShopBuy", c)
				return
			end
		end
	end)

	-- server pushes (passes bought, coin packs granted, first load)
	ShopEvent.OnClientEvent:Connect(function(kind: any, payload: any, extra: any)
		if kind == "State" then
			applyState(payload)
		elseif kind == "Granted" then
			applyState(payload)
			local item = ShopConfig.ById[extra]
			if item then
				Kit.sfx("Buy")
				ctx.Toast({
					Title = if item.Amount then ("+%s COINS"):format(Theme.Comma(item.Amount)) else "THANK YOU!",
					Text = if item.Amount then "Added to your wallet" else item.Name .. " is now active",
					Icon = if item.Amount or item.CoinArt then Theme.Icon.Coin else Theme.decal(item.Icon or 5175224022),
					Color = C.Gold,
					Deep = C.GoldDeep,
				})
				for _, c in ipairs(cards) do
					if c.Item == item and c.Cell.Visible then
						celebrate(c, C.Gold)
					end
				end
			end
		end
	end)

	task.spawn(function()
		for _ = 1, 5 do
			local ok, res = pcall(function()
				return ShopRequest:InvokeServer("state")
			end)
			if ok and type(res) == "table" and res.Ok then
				applyState(res.State)
				return
			end
			task.wait(2)
		end
	end)
	refreshAll()

	---------------------------------------------------------------------------
	-- the aura cards animate only while you can see them
	---------------------------------------------------------------------------
	local function updateAuraArt()
		local on = win.Root.Visible
		for _, c in ipairs(cards) do
			if c.Preview then
				c.Preview.SetActive(on and c.Cell.Visible)
			end
		end
	end
	ctx.UpdateAuraArt = updateAuraArt
	win.Root:GetPropertyChangedSignal("Visible"):Connect(updateAuraArt)
	for _, c in ipairs(cards) do
		c.Cell:GetPropertyChangedSignal("Visible"):Connect(updateAuraArt)
	end

	ctx.Register("Shop", {
		Window = win,
		OnOpen = function(tab: any)
			if type(tab) == "string" and tabs[tab] then
				selectTab(tab)
			else
				selectTab(currentTab)
			end
		end,
	})
end
