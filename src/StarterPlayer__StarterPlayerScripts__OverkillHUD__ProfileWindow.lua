--[[
	ProfileWindow  (StarterPlayerScripts.OverkillHUD.ProfileWindow)
	Your card: avatar, level + XP, lifetime stats (from QuestServer), and your collection.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local ShopConfig = require(UI:WaitForChild("ShopConfig"))
	local AuraSprites = require(script.Parent:WaitForChild("AuraSprites"))
	local shelfSprites: { any } = {} -- animated auras on the collection shelf

	local accent = Theme.Accent.Stats[1]
	local W, H = 1000, 640
	local win = Kit.window({
		Name = "Stats",
		Size = Vector2.new(W, H),
		Accent = Theme.Accent.Stats,
		Title = "PROFILE",
		Icon = Theme.Icon.Stats,
		Parent = ctx.WindowLayer,
		OnClose = ctx.Close,
	})
	local content = win.Content

	---------------------------------------------------------------------------
	-- left: avatar card
	---------------------------------------------------------------------------
	local left = new("Frame", { Name = "Left", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(0, 312, 1, -14), ZIndex = 12, Parent = content })
	local avatarCard = Kit.plate({
		Name = "Avatar",
		Parent = left,
		Size = UDim2.new(1, 0, 0, 344),
		Radius = 26,
		Stroke = 4.5,
		ZIndex = 12,
		Gradient = { C.Navy600, C.Navy900 },
	})
	-- the avatar stands on a lit podium: spotlight + light cone from above, window stripes,
	-- a glowing platform underfoot. Everything is tinted with your rank colour (tintStage).
	-- Static, so the CanvasGroup draws it once and caches it.
	local stage = new("CanvasGroup", { Name = "Stage", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), ZIndex = 13, Parent = avatarCard })
	Kit.corner(stage, 22)
	local back = new("Frame", { Name = "Back", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 13, Parent = stage })
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C.Navy600),
			ColorSequenceKeypoint.new(0.55, C.Navy800),
			ColorSequenceKeypoint.new(1, C.Night),
		}),
		Parent = back,
	})
	Kit.stripes(stage, C.Rim, 0.955, 13)
	-- soft light cone falling from the top of the card onto the avatar
	local cone = Kit.image({
		Name = "Cone",
		Image = Theme.Icon.Glow,
		ImageTransparency = 0.55,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -150),
		Size = UDim2.fromOffset(250, 520),
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = 13,
		Parent = stage,
	})
	-- spotlight glow behind the body
	local spot = Kit.image({
		Name = "Spotlight",
		Image = Theme.Icon.Glow,
		ImageTransparency = 0.3,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromOffset(330, 330),
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = 13,
		Parent = stage,
	})
	local floor = new("Frame", { Name = "Floor", BackgroundColor3 = C.Night, Position = UDim2.fromScale(0, 0.62), Size = UDim2.fromScale(1, 0.38), ZIndex = 14, Parent = stage })
	Kit.gradient(floor, C.Night, C.Night, 90, 1, 0.15)
	-- a pool of light on the floor where the spotlight lands
	local FEET_Y = -38 -- from the bottom of the stage
	local pool = Kit.image({
		Name = "LightPool",
		Image = Theme.Icon.Glow,
		ImageTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, FEET_Y),
		Size = UDim2.fromOffset(300, 92),
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = 14,
		Parent = stage,
	})
	local function tintStage(col: Color3)
		cone.ImageColor3 = Kit.lighten(col, 0.55)
		spot.ImageColor3 = Kit.lighten(col, 0.2)
		pool.ImageColor3 = Kit.lighten(col, 0.1)
	end
	tintStage(Theme.RankFor(1).Color)
	Kit.sparkles(avatarCard, accent, 7, 16, function()
		return win.Root.Visible
	end)
	-- fallback picture (only shown if the 3D render below can't be built)
	local avatar = Kit.image({
		Name = "Picture",
		Image = ("rbxthumb://type=Avatar&id=%d&w=420&h=420"):format(math.max(1, player.UserId)),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 6),
		Size = UDim2.fromOffset(330, 330),
		ZIndex = 15,
		Parent = stage,
	})

	-- your actual character in 3D, standing in the light pool. Rebuilt each time the window
	-- opens (outfit / aura changes show up), static in between so it costs nothing per frame.
	-- It sits outside the stage CanvasGroup so the cached stage never has to redraw.
	local FIT = 0.86 -- share of the view the avatar fills (leaves headroom under the level star)
	local VIEW_Y, VIEW_H = 10, 314 -- the feet land at VIEW_Y + VIEW_H * (0.5 + FIT / 2), on the light pool
	local avatarView = new("ViewportFrame", {
		Name = "Avatar3D",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, VIEW_Y),
		Size = UDim2.new(1, -8, 0, VIEW_H),
		Ambient = Color3.fromRGB(150, 150, 168),
		LightColor = Color3.fromRGB(255, 244, 228),
		LightDirection = Vector3.new(-0.4, -0.8, -1),
		Visible = false,
		ZIndex = 15,
		Parent = avatarCard,
	})
	local avatarWorld = new("WorldModel", { Parent = avatarView })
	local avatarCam = new("Camera", { FieldOfView = 30, Parent = avatarView })
	avatarView.CurrentCamera = avatarCam
	local STRIP = {
		Script = true, LocalScript = true, ModuleScript = true, Sound = true, ForceField = true, Tool = true,
		BillboardGui = true, SurfaceGui = true, Highlight = true, ProximityPrompt = true,
		ParticleEmitter = true, Beam = true, Trail = true, Fire = true, Smoke = true, Sparkles = true,
		PointLight = true, SpotLight = true, SurfaceLight = true,
	}
	-- the character plays its own idle animation (from its Animate script, so avatar animation
	-- packs show too). Joints stay live: root anchored, limbs driven by the Animator.
	local DEFAULT_IDLE = { R15 = "rbxassetid://507766666", R6 = "rbxassetid://180435571" }
	local function idleAnimationId(char: Model): string
		local animate = char:FindFirstChild("Animate")
		local idle = animate and animate:FindFirstChild("idle")
		if idle then
			local a = idle:FindFirstChild("Animation1") or idle:FindFirstChildOfClass("Animation")
			if a and a:IsA("Animation") and a.AnimationId ~= "" then
				return a.AnimationId
			end
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		return if hum and hum.RigType == Enum.HumanoidRigType.R6 then DEFAULT_IDLE.R6 else DEFAULT_IDLE.R15
	end

	local orbit = { Target = Vector3.zero, Dir = Vector3.new(0, 0, -1), Dist = 10, Yaw = 0 }
	local dolly = new("NumberValue", { Name = "Dolly", Value = 1 })
	local idleTrack: AnimationTrack? = nil
	local function placeCamera()
		local dir = CFrame.fromAxisAngle(Vector3.yAxis, orbit.Yaw) * orbit.Dir
		avatarCam.CFrame = CFrame.lookAt(orbit.Target + dir * orbit.Dist * dolly.Value, orbit.Target)
		local f = avatarCam.CFrame
		avatarView.LightDirection = (f.LookVector + f.RightVector * 0.9 - Vector3.yAxis * 0.7).Unit
	end
	dolly.Changed:Connect(placeCamera)

	local function stopAvatar()
		if idleTrack then
			idleTrack:Stop(0)
			idleTrack = nil
		end
		avatarWorld:ClearAllChildren()
	end

	local function buildAvatar(): boolean
		local char = player.Character
		local liveRoot = char and char:FindFirstChild("HumanoidRootPart")
		if not (char and liveRoot) then
			return false
		end
		local idleId = idleAnimationId(char)
		local was = char.Archivable
		char.Archivable = true
		local ok, clone = pcall(function()
			return char:Clone()
		end)
		char.Archivable = was
		if not ok or not clone then
			return false
		end
		for _, d in ipairs(clone:GetDescendants()) do
			-- (a limb the fight took is shown as it was: a portrait is the fighter whole)
			local lost = d:GetAttribute("GoreHidden")
			if type(lost) == "number" and (d:IsA("BasePart") or d:IsA("Decal")) then
				(d :: any).Transparency = lost
			end
			if (STRIP[d.ClassName] or d:GetAttribute("OverkillGore")) and d.Parent then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
				d.Anchored = false
				d.CanCollide = false
			end
		end
		local root = clone:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			clone:Destroy()
			return false
		end
		root.Anchored = true
		-- start from the rest pose (the live character may be mid-stride when the window opens)
		local edges = {}
		for _, j in ipairs(clone:GetDescendants()) do
			if j:IsA("JointInstance") and j.Part0 and j.Part1 then
				table.insert(edges, { j.Part0, j.Part1, j.C0 * j.C1:Inverse() })
			elseif j:IsA("WeldConstraint") and j.Part0 and j.Part1 then
				table.insert(edges, { j.Part0, j.Part1, j.Part0.CFrame:ToObjectSpace(j.Part1.CFrame) })
			end
		end
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, select(2, root.CFrame:ToEulerAnglesYXZ()), 0)
		local solved = { [root] = true }
		local progress = true
		while progress do
			progress = false
			for _, e in ipairs(edges) do
				local p0, p1, rel = e[1], e[2], e[3]
				if solved[p0] and not solved[p1] then
					p1.CFrame = p0.CFrame * rel
					solved[p1] = true
					progress = true
				elseif solved[p1] and not solved[p0] then
					p0.CFrame = p1.CFrame * rel:Inverse()
					solved[p0] = true
					progress = true
				end
			end
		end
		stopAvatar()
		clone.Parent = avatarWorld
		-- frame it: full body, feet on the bottom margin, a three-quarter turn toward the light
		local look = root.CFrame.LookVector
		look = Vector3.new(look.X, 0, look.Z)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
		local cf, size = clone:GetBoundingBox()
		local h = math.max(size.Y, 1)
		local w = math.max(size.X * 0.94 + size.Z * 0.34, 1) -- width seen at a 20 degree turn
		local half = math.max(h, w) / 2 / FIT -- half the visible height
		-- aim so the feet always sit on the bottom margin, however wide the avatar is
		local feetY = cf.Position.Y - h / 2
		orbit.Target = Vector3.new(cf.Position.X, feetY + half * FIT, cf.Position.Z)
		orbit.Dir = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(-20)) * look
		orbit.Dist = half / math.tan(math.rad(15))
		orbit.Yaw = 0
		dolly.Value = 1.12
		placeCamera()
		tween(dolly, 0.7, { Value = 1 }, Enum.EasingStyle.Quint)
		-- idle animation
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then
			local animator = hum:FindFirstChildOfClass("Animator") or new("Animator", { Parent = hum })
			local anim = new("Animation", { AnimationId = idleId })
			local okT, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			if okT and track then
				track.Looped = true
				track:Play(0.2)
				idleTrack = track
			end
		end
		return true
	end

	-- drag the stage to spin your character
	local UserInputService = game:GetService("UserInputService")
	local spinning, lastX = false, 0
	avatarView.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			spinning = true
			lastX = input.Position.X
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if spinning and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - lastX
			lastX = input.Position.X
			orbit.Yaw -= dx * 0.012
			placeCamera()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			spinning = false
		end
	end)

	local function showAvatar()
		local ok, built = pcall(buildAvatar)
		local good = ok and built == true
		avatarView.Visible = good
		avatar.Visible = not good
	end

	-- level badge overlapping the card corner
	local badge = Kit.image({
		Name = "LevelStar",
		Image = Theme.Icon.Star,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(20, 20),
		Size = UDim2.fromOffset(104, 104),
		Rotation = -10,
		ZIndex = 20,
		Parent = avatarCard,
	})
	local badgeNum = Kit.text({ Text = "1", TextSize = 34, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.56), Size = UDim2.fromScale(1, 0.5), ZIndex = 21, Stroke = 4, Parent = badge })

	local rankPill = Kit.plate({
		Name = "Rank",
		Parent = left,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(156, 344),
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 4,
		ZIndex = 22,
		Gradient = { C.Gold, C.GoldDeep },
	})
	Kit.padding(rankPill, 20, 0, 20, 0)
	local rankGrad = rankPill:FindFirstChildOfClass("UIGradient")
	local rankText = Kit.text({ Text = "ROOKIE", TextSize = 22, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 23, Stroke = 3, Parent = rankPill })

	local nameLbl = Kit.text({
		Name = "DisplayName",
		Text = player.DisplayName,
		TextSize = 34,
		Position = UDim2.fromOffset(0, 370),
		Size = UDim2.new(1, 0, 0, 40),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 12,
		Stroke = 4,
		Parent = left,
	})
	local _ = nameLbl
	Kit.text({
		Name = "UserName",
		Text = "@" .. player.Name,
		TextSize = 19,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 406),
		Size = UDim2.new(1, 0, 0, 24),
		ZIndex = 12,
		Stroke = 2.4,
		Parent = left,
	})
	local lvlRow = new("Frame", { Name = "LevelRow", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 438), Size = UDim2.new(1, 0, 0, 26), ZIndex = 12, Parent = left })
	local lvlText = Kit.text({ Text = "LEVEL 1", TextSize = 22, TextColor3 = C.Gold, Size = UDim2.fromScale(0.5, 1), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 3, Parent = lvlRow })
	local nextText = Kit.text({
		Text = "",
		TextSize = 16,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.5, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 12,
		Stroke = 2.2,
		Parent = lvlRow,
	})
	local xp = Kit.bar({
		Name = "XP",
		Parent = left,
		Position = UDim2.fromOffset(0, 468),
		Size = UDim2.new(1, 0, 0, 34),
		Color = Color3.fromRGB(110, 226, 255),
		Deep = Color3.fromRGB(44, 124, 240),
		TextSize = 18,
		ZIndex = 12,
	})
	local since = Kit.text({
		Name = "Since",
		Text = "",
		TextSize = 16,
		FontFace = Theme.Font.Bold,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 508),
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = 12,
		Stroke = false,
		Parent = left,
	})

	---------------------------------------------------------------------------
	-- right: stat tiles + collection
	---------------------------------------------------------------------------
	local right = new("Frame", { Name = "Right", BackgroundTransparency = 1, Position = UDim2.fromOffset(340, 14), Size = UDim2.new(1, -340, 1, -14), ZIndex = 12, Parent = content })
	Kit.heading({ Text = "STATS", Parent = right, Size = UDim2.new(1, 0, 0, 30), ZIndex = 12 })
	local grid = new("Frame", { Name = "Tiles", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 262), ZIndex = 12, Parent = right })
	-- three tiles to a row, each a whole number of units wide (a scale-sized cell is rounded tile by
	-- tile and the gaps between them come out a pixel apart): (948 content - 340 left - 2 gaps) / 3
	local TILE_W = math.floor((W - 52 - 340 - 16 * 2) / 3)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(TILE_W, 124), CellPadding = UDim2.fromOffset(16, 14), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })

	local tiles: { [string]: TextLabel } = {}
	local counters: { [string]: (number, boolean?) -> () } = {}
	local formats: { [string]: (number) -> string } = {
		Coins = Theme.Short,
		Playtime = function(m: number)
			return Theme.Duration(m * 60)
		end,
		Quests = Theme.Comma,
		Distance = Theme.Short,
		Streak = Theme.Comma,
		TotalXp = Theme.Short,
	}
	local function tile(key: string, label: string, icon: string, color: Color3, deep: Color3, order: number, glyph: boolean?)
		local t = Kit.plate({ Name = key, Parent = grid, LayoutOrder = order, Radius = 22, Stroke = 4, ZIndex = 12, Gradient = { C.Navy600, C.Navy800 } })
		Kit.bevel(t, 18, 3, 12)
		-- the disc is the tile's top-left corner: its gap (in the tile's colours, the top 78 of
		-- its 124 high gradient) and outline are rings on that corner, so it is exactly as far
		-- from the tile's left edge as from its top
		local disc = Kit.endIcon({
			Parent = t,
			Name = "Disc",
			Side = "TopLeft",
			Width = 78,
			Height = 78,
			Gap = 12,
			Stroke = 3.5,
			Band = ColorSequence.new(C.Navy600, C.Navy600:Lerp(C.Navy800, 78 / 124)),
			Face = { Kit.lighten(color, 0.1), deep, 90 },
			ZIndex = 13,
		})
		Kit.outlineOnTop(t, 17)
		Kit.image({
			Image = icon,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = if glyph then UDim2.fromOffset(30, 30) else UDim2.fromOffset(38, 38), -- stays inside the ring
			ZIndex = disc.ContentZ,
			Parent = disc.Frame,
		})
		Kit.text({
			Name = "Label",
			Text = label,
			TextSize = 15,
			FontFace = Theme.Font.Heavy,
			TextColor3 = Kit.lighten(color, 0.35),
			Position = UDim2.fromOffset(76, 12),
			Size = UDim2.new(1, -84, 0, 54),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			ZIndex = 13,
			Stroke = 2.4,
			Parent = t,
		})
		local value = Kit.text({
			Name = "Value",
			Text = "0",
			TextSize = 34,
			Position = UDim2.fromOffset(14, 70),
			Size = UDim2.new(1, -28, 0, 42),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 13,
			Stroke = 3.8,
			Parent = t,
		})
		tiles[key] = value
		counters[key] = Kit.counter(value, formats[key] or Theme.Comma, 0)
	end
	tile("Coins", "COINS", Theme.Icon.Coin, C.Gold, C.GoldDeep, 1)
	tile("Playtime", "TIME PLAYED", Theme.Icon.Clock, C.Blue, C.BlueDeep, 2, true)
	tile("Quests", "QUESTS DONE", Theme.Icon.Medal, C.Pink, C.PinkDeep, 3)
	tile("Distance", "STUDS TRAVELED", Theme.Icon.Boot, C.Green, C.GreenDeep, 4, true)
	tile("Streak", "DAY STREAK", Theme.Icon.Flame, Color3.fromRGB(255, 140, 60), Color3.fromRGB(214, 70, 30), 5, true)
	tile("TotalXp", "TOTAL XP", Theme.Icon.Star, C.Purple, C.PurpleDeep, 6)

	Kit.heading({ Text = "COLLECTION", Parent = right, Position = UDim2.fromOffset(0, 322), Size = UDim2.new(1, 0, 0, 30), ZIndex = 12 })
	local shelf = new("ScrollingFrame", {
		Name = "Shelf",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 362),
		Size = UDim2.new(1, 0, 1, -362),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.Rim,
		ZIndex = 12,
		Parent = right,
	})
	Kit.padding(shelf, 4, 6, 4, 12)
	Kit.list(shelf, Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local empty = new("Frame", { Name = "Empty", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 362), Size = UDim2.new(1, 0, 0, 120), ZIndex = 12, Visible = false, Parent = right })
	Kit.text({
		Text = "Nothing here yet - auras and passes you unlock show up here.",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 30),
		ZIndex = 12,
		Stroke = 2.2,
		Parent = empty,
	})
	Kit.button({
		Name = "GoShop",
		Parent = empty,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 44),
		Size = UDim2.fromOffset(240, 60),
		Radius = 20,
		Color = Theme.Accent.Shop[1],
		Deep = Theme.Accent.Shop[2],
		Icon = Theme.Icon.Shop,
		IconSize = 44,
		Text = "OPEN SHOP",
		TextSize = 25,
		ZIndex = 13,
		Shine = true,
		WiggleIcon = true,
		OnClick = function()
			ctx.Open("Shop")
		end,
	})

	local function chip(item: any, equipped: boolean, order: number)
		local r = Theme.Rarity[item.Rarity or "Common"] or Theme.Rarity.Common
		local card = Kit.plate({
			Name = item.Id,
			Parent = shelf,
			Size = UDim2.fromOffset(150, 172),
			LayoutOrder = order,
			Radius = 22,
			Stroke = 4,
			StrokeColor = if equipped then C.Gold else C.Ink,
			ZIndex = 13,
			Gradient = { Kit.darken(r.Color, 0.1), Kit.darken(r.Deep, 0.55) },
		})
		local art = new("CanvasGroup", { BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 112), ZIndex = 14, Parent = card })
		Kit.corner(art, 16)
		Kit.rays(art, Color3.new(1, 1, 1), 260, 0.82, 14, false)
		-- auras: the aura itself, animated (the same 2D aura art as the shop cards)
		local auraSrc = item.Aura and UI:FindFirstChild("Auras") and UI.Auras:FindFirstChild(item.Aura)
		if auraSrc or item.CardSheet then
			local clip = new("Frame", {
				Name = "AuraClip",
				BackgroundTransparency = 1,
				ClipsDescendants = true,
				Position = UDim2.fromOffset(10, 10),
				Size = UDim2.new(1, -20, 0, 104),
				ZIndex = 15,
				Parent = card,
			})
			local sprites = if item.CardSheet
				then AuraSprites.newSheet(clip, item.CardSheet, { Size = 98, Centre = AuraSprites.focusCentre(Vector2.new(65, 53), 98, item.CardFocus), ZIndex = 15 })
				else AuraSprites.new(clip, auraSrc, { PixelsPerStud = 15, Feet = Vector2.new(65, 98), ZIndex = 15, Soft = Theme.Icon.Glow, Budget = 70 })
			sprites.SetActive(win.Root.Visible)
			table.insert(shelfSprites, sprites)
		elseif item.CoinArt then
			Kit.coinArt(art, item.CoinArt, 104, 15)
		else
			Kit.image({ Image = Theme.decal(item.Icon or 5175224022), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(92, 92), ZIndex = 15, Parent = art })
		end
		Kit.text({ Text = item.Name, TextSize = 19, Position = UDim2.fromOffset(6, 122), Size = UDim2.new(1, -12, 0, 24), ZIndex = 14, Stroke = 2.8, Parent = card })
		Kit.text({
			Text = if equipped then "EQUIPPED" else r.Name,
			TextSize = 13,
			FontFace = Theme.Font.Heavy,
			TextColor3 = if equipped then C.Gold else Kit.lighten(r.Color, 0.3),
			Position = UDim2.fromOffset(6, 145),
			Size = UDim2.new(1, -12, 0, 18),
			ZIndex = 14,
			Stroke = 2,
			Parent = card,
		})
	end

	local function rebuildShelf()
		for _, sp in ipairs(shelfSprites) do
			sp.Destroy()
		end
		table.clear(shelfSprites)
		for _, c in ipairs(shelf:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local st = ctx.ShopState
		local n = 0
		if st and st.Owned then
			for _, item in ipairs(ShopConfig.Items) do
				if st.Owned[item.Id] and item.Tab ~= "Coins" then
					n += 1
					chip(item, st.Equipped == item.Id, n)
				end
			end
		end
		empty.Visible = n == 0
		shelf.Visible = n > 0
	end

	---------------------------------------------------------------------------
	-- data
	---------------------------------------------------------------------------
	local function stat(name: string): number
		return tonumber(player:GetAttribute("Stat_" .. name)) or 0
	end

	local function refresh(animate: boolean?)
		local s = ctx.Stats
		badgeNum.Text = tostring(s.Level or 1)
		lvlText.Text = ("LEVEL %d"):format(s.Level or 1)
		local need = s.XpNeed or Theme.XpForLevel(1)
		local inLevel = s.XpIn or 0
		nextText.Text = ("%s XP to go"):format(Theme.Comma(need - inLevel))
		xp.Label.Text = ("%s / %s XP"):format(Theme.Comma(inLevel), Theme.Comma(need))
		xp.Set(inLevel / need, not win.IsOpen)
		local values = {
			Coins = s.Coins or 0,
			Playtime = stat("PlayMinutes"),
			Quests = stat("ClaimsAny"),
			Distance = stat("Distance"),
			Streak = math.max(1, stat("LoginStreak")),
			TotalXp = s.XP or 0,
		}
		for k, v in pairs(values) do
			if animate then
				counters[k](0, true)
			end
			counters[k](v, not animate and not win.IsOpen)
		end
		local rank = Theme.RankFor(s.Level or 1)
		if rankText.Text ~= rank.Name then
			tintStage(rank.Color)
		end
		rankText.Text = rank.Name
		if rankGrad then
			rankGrad.Color = ColorSequence.new(Kit.lighten(rank.Color, 0.1), Kit.darken(rank.Color, 0.35))
		end
		local days = player.AccountAge
		since.Text = if days > 0 then ("Roblox member for %s days"):format(Theme.Comma(days)) else ""
	end

	-- (wrapped: these events pass the new value, which must not land in refresh's `animate`
	-- flag - a number is truthy, so every coin or XP change reset all six tiles to 0)
	ctx.On("Coins", function()
		refresh()
	end)
	ctx.On("Xp", function()
		refresh()
	end)
	ctx.On("ShopState", rebuildShelf)
	win.Root:GetPropertyChangedSignal("Visible"):Connect(function()
		for _, sp in ipairs(shelfSprites) do
			sp.SetActive(win.Root.Visible)
		end
	end)
	player.AttributeChanged:Connect(function(name)
		if name:sub(1, 5) == "Stat_" and win.IsOpen then
			refresh()
		end
	end)
	refresh()
	rebuildShelf()

	ctx.Register("Stats", {
		Window = win,
		OnOpen = function()
			refresh(true)
			local rs = Kit.fx(rankPill)
			rs.Scale = 0.3
			tween(rs, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.3)
			rebuildShelf()
			local sc = Kit.fx(badge)
			sc.Scale = 0.3
			tween(sc, 0.55, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.15)
			for i, t in ipairs(grid:GetChildren()) do
				if t:IsA("GuiObject") then
					local s = Kit.fx(t)
					s.Scale = 0.8
					tween(s, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05 * i)
				end
			end
			showAvatar()
			avatar.Position = UDim2.new(0.5, 0, 1, 40)
			tween(avatar, 0.5, { Position = UDim2.new(0.5, 0, 1, 6) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)
			avatarView.Position = UDim2.fromOffset(4, VIEW_Y + 34)
			tween(avatarView, 0.5, { Position = UDim2.fromOffset(4, VIEW_Y) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)
		end,
		OnClose = function()
			-- the animated viewport only runs while the window is open
			task.delay(0.25, function()
				if not win.IsOpen then
					stopAvatar()
				end
			end)
		end,
	})
end
