--[[
	OverkillHUD  (StarterPlayerScripts.OverkillHUD)
	The whole on-screen HUD: coins + level, the side dock (Shop / Stats / Bag / Menu / Party),
	the hotbar, windows, toasts, and the 1v1 / 2v2 / Arena queue + party system.
	Each window lives in its own ModuleScript under this script.

	Look + numbers: ReplicatedStorage.OverkillUI.Theme
	Building blocks: ReplicatedStorage.OverkillUI.Kit
	What the shop sells: ReplicatedStorage.OverkillUI.ShopConfig
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local Theme = require(UI:WaitForChild("Theme"))
local Kit = require(UI:WaitForChild("Kit"))
local C = Theme.C
local new, tween = Kit.new, Kit.tween

---------------------------------------------------------------------------
-- default backpack off (we draw our own hotbar)
---------------------------------------------------------------------------
task.spawn(function()
	for _ = 1, 30 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
		if ok then
			break
		end
		task.wait(0.5)
	end
end)

---------------------------------------------------------------------------
-- screens, scale, layers
---------------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "OverkillHUD",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 20,
	Parent = playerGui,
})
local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
local rootScale = new("UIScale", { Name = "Fit", Parent = root })
local dragGui = new("ScreenGui", {
	Name = "OverkillDrag",
	ResetOnSpawn = false,
	IgnoreGuiInset = false, -- drag ghost uses AbsolutePosition space
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 36,
	Parent = playerGui,
})

local hudLayer = new("Frame", { Name = "HUD", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = root })
local dim = new("TextButton", {
	Name = "Dim",
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = C.Night,
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	Visible = false,
	ZIndex = 5,
	Parent = root,
})
local windowLayer = new("Frame", { Name = "Windows", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = root })
-- toasts, floats and flying coins get their own ScreenGui above the quest UI (DisplayOrder 40),
-- so a LEVEL UP never hides behind the quest board. Same scale + origin as the HUD root.
local toastGui = new("ScreenGui", {
	Name = "OverkillToasts",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 45,
	Parent = playerGui,
})
local toastRoot = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = toastGui })
local toastScale = new("UIScale", { Name = "Fit", Parent = toastRoot })
local toastLayer = new("Frame", { Name = "Toasts", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = toastRoot })

local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local ctx: any = {
	Kit = Kit,
	Theme = Theme,
	Player = player,
	Gui = gui,
	Root = root,
	Hud = hudLayer,
	WindowLayer = windowLayer,
	DragGui = dragGui,
	Scale = 1,
	IsTouch = isTouch,
	Windows = {},
	Stats = { Coins = 0, XP = 0, Level = 1 },
}

-- tiny signal hub so the modules can talk
local listeners: { [string]: { (...any) -> () } } = {}
function ctx.On(name: string, fn: (...any) -> ())
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ctx.Fire(name: string, ...: any)
	for _, fn in ipairs(listeners[name] or {}) do
		task.spawn(fn, ...)
	end
end

local function rescale()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	if vp.X < 2 or vp.Y < 2 then
		return
	end
	local s = math.min(vp.X / Theme.Reference.X, vp.Y / Theme.Reference.Y)
	if isTouch then
		s *= Theme.TouchBoost
	end
	s = math.clamp(s, Theme.MinScale, Theme.MaxScale) * (ctx.UserScale or 1)
	ctx.Scale = s
	rootScale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	toastScale.Scale = s
	toastRoot.Size = root.Size
	ctx.Fire("Scale", s)
end
function ctx.SetUserScale(v: number)
	v = math.clamp(tonumber(v) or 1, 0.8, 1.2)
	if ctx.UserScale ~= v then
		ctx.UserScale = v
		player:SetAttribute("OverkillUserScale", v) -- the quest UI follows the same size
		rescale()
	end
end
local camConn: RBXScriptConnection? = nil
local function hookCamera()
	if camConn then
		camConn:Disconnect()
	end
	local cam = workspace.CurrentCamera
	if cam then
		camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	rescale()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
hookCamera()

---------------------------------------------------------------------------
-- toasts
---------------------------------------------------------------------------
local toastStack = new("Frame", {
	Name = "Stack",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 86),
	Size = UDim2.fromOffset(620, 400),
	Parent = toastLayer,
})
Kit.list(toastStack, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center)

-- o = { Title, Text, Icon, Color, Deep, Time }
-- While a full-screen overlay (the match screen) is up nothing may pop up behind it:
-- toasts wait in line and play once it closes.
local heldToasts: { any } = {}
function ctx.Toast(o: { [string]: any })
	if ctx.Overlay ~= nil then
		table.insert(heldToasts, o)
		while #heldToasts > 3 do
			table.remove(heldToasts, 1)
		end
		return
	end
	local color = o.Color or C.Blue
	local deep = o.Deep or Kit.darken(color, 0.35)
	local holder = new("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 84),
		LayoutOrder = -math.floor(os.clock() * 100),
		Parent = toastStack,
	})
	local card = Kit.plate({
		Name = "Card",
		Parent = holder,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -40),
		Size = UDim2.new(0, 0, 0, 76),
		AutomaticSize = Enum.AutomaticSize.X,
		Color = C.Navy800,
		Radius = UDim.new(1, 0),
		Stroke = 4.5,
	})
	Kit.gradient(card, C.Navy700, C.Night, 90)
	card.BackgroundColor3 = Color3.new(1, 1, 1)
	local sc = Kit.fx(card)
	sc.Scale = 0.7
	Kit.padding(card, 86, 0, 30, 0)
	-- the icon disc is the card's whole round left end: its outline and the gap round it are
	-- strokes on it, so the gap is the same at the left, the top and the bottom
	local stripeIcon = Kit.endIcon({
		Parent = card,
		Name = "Stripe",
		Side = "Left",
		Width = 76,
		Gap = 6,
		Stroke = 3.5,
		Band = { C.Navy700, C.Night, 90 },
		Face = { Kit.lighten(color, 0.15), deep, 90 },
		ZIndex = 2,
	})
	local stripe = stripeIcon.Frame
	Kit.outlineOnTop(card, 6)
	if o.Glyph == "close" then
		Kit.closeGlyph(stripe, 30, stripeIcon.ContentZ)
	elseif o.Icon then
		Kit.image({ Image = o.Icon, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(46, 46), ZIndex = stripeIcon.ContentZ, Parent = stripe })
	end
	local col = new("Frame", { Name = "Text", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 2, Parent = card })
	Kit.list(col, Enum.FillDirection.Vertical, -2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.text({
		Name = "Title",
		Text = o.Title or "",
		TextSize = 30,
		TextColor3 = color,
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
		LayoutOrder = 1,
		Stroke = 3.5,
		Parent = col,
	})
	if o.Text and o.Text ~= "" then
		Kit.text({
			Name = "Body",
			Text = o.Text,
			TextSize = 19,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextSoft,
			Size = UDim2.new(0, 0, 0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 3,
			LayoutOrder = 2,
			Stroke = 2.4,
			Parent = col,
		})
	end
	tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(card, 0.4, { Position = UDim2.new(0.5, 0, 0.5, 0) }, Enum.EasingStyle.Back)
	Kit.wiggle(stripe, 0.8)
	task.delay(o.Time or 2.6, function()
		tween(sc, 0.22, { Scale = 0.6 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(card, 0.22, { Position = UDim2.new(0.5, 0, 0.5, -30) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
		holder:Destroy()
	end)
	-- keep at most 3 on screen
	local list = {}
	for _, t in ipairs(toastStack:GetChildren()) do
		if t:IsA("Frame") then
			table.insert(list, t)
		end
	end
	table.sort(list, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 4, #list do
		list[i]:Destroy()
	end
end

---------------------------------------------------------------------------
-- confirm pop-up (above windows, below toasts)
---------------------------------------------------------------------------
local modalLayer = new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 40, Visible = false, Parent = root })
local modalDim = new("TextButton", {
	Name = "Dim",
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = C.Night,
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 40,
	Parent = modalLayer,
})
local closeModal: () -> () = function() end

-- o = { Title, Text, Icon, Confirm, Color, Deep, Price, OnConfirm, OnCancel }
function ctx.Confirm(o: { [string]: any })
	closeModal()
	for _, c in ipairs(modalLayer:GetChildren()) do
		if c.Name == "Dialog" then
			c:Destroy()
		end
	end
	local color, deep = o.Color or C.Green, o.Deep or C.GreenDeep
	modalLayer.Visible = true
	tween(modalDim, 0.2, { BackgroundTransparency = 0.35 })
	local dialog = Kit.plate({
		Name = "Dialog",
		Parent = modalLayer,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(620, 340),
		Radius = 34,
		Stroke = 6,
		ZIndex = 41,
		Gradient = { C.Navy700, C.Navy900 },
	})
	Kit.bevel(dialog, 28, 7, 41)
	local sc = Kit.fx(dialog)
	sc.Scale = 0.6
	tween(sc, 0.38, { Scale = 1 }, Enum.EasingStyle.Back)
	local rays = Kit.rays(dialog, color, 330, 0.55, 41)
	rays.Position = UDim2.new(0.5, 0, 0, 2)
	local disc = Kit.plate({
		Name = "Disc",
		Parent = dialog,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(116, 116),
		Radius = UDim.new(1, 0),
		Stroke = 5,
		ZIndex = 43,
		Gradient = { Kit.lighten(color, 0.12), deep },
	})
	Kit.bevel(disc, UDim.new(1, 0), 5, 43)
	if o.Icon then
		local ic = Kit.image({ Image = o.Icon, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(82, 82), ZIndex = 44, Parent = disc })
		Kit.wiggle(ic)
	end
	Kit.text({ Text = o.Title or "", TextSize = 40, Position = UDim2.fromOffset(20, 70), Size = UDim2.new(1, -40, 0, 46), ZIndex = 42, Stroke = 4.5, Parent = dialog })
	Kit.text({
		Text = o.Text or "",
		TextSize = 21,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		Position = UDim2.fromOffset(40, 120),
		Size = UDim2.new(1, -80, 0, if o.Price then 52 else 90),
		ZIndex = 42,
		Stroke = 2.4,
		Parent = dialog,
	})
	if o.Price then
		local row = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 176), Size = UDim2.new(1, 0, 0, 44), ZIndex = 42, Parent = dialog })
		Kit.list(row, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(44, 44), ZIndex = 43, LayoutOrder = 1, Parent = row })
		Kit.text({ Text = Theme.Comma(o.Price), TextSize = 36, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 43, LayoutOrder = 2, Stroke = 4, Parent = row })
	end
	local done = false
	local function finish(ok: boolean)
		if done then
			return
		end
		done = true
		closeModal()
		if ok and o.OnConfirm then
			o.OnConfirm()
		elseif not ok and o.OnCancel then
			o.OnCancel()
		end
	end
	closeModal = function()
		closeModal = function() end
		tween(modalDim, 0.18, { BackgroundTransparency = 1 })
		tween(sc, 0.16, { Scale = 0.7 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function()
			dialog:Destroy()
			if not modalLayer:FindFirstChild("Dialog") then
				modalLayer.Visible = false
			end
		end)
	end
	Kit.button({
		Name = "Cancel",
		Parent = dialog,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 34, 1, -26),
		Size = UDim2.fromOffset(250, 72),
		Radius = 24,
		Depth = 7,
		Color = C.Navy500,
		Deep = C.Navy700,
		Text = "CANCEL",
		TextSize = 28,
		ZIndex = 42,
		OnClick = function()
			finish(false)
		end,
	})
	Kit.button({
		Name = "Confirm",
		Parent = dialog,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -34, 1, -26),
		Size = UDim2.fromOffset(250, 72),
		Radius = 24,
		Depth = 7,
		Color = color,
		Deep = deep,
		Text = o.Confirm or "CONFIRM",
		TextSize = 28,
		ZIndex = 42,
		Shine = true,
		OnClick = function()
			finish(true)
		end,
	})
	modalDim.Activated:Once(function()
		finish(false)
	end)
	Kit.sfx("Open")
end

-- coins leaving one gui and landing on another (root space)
function ctx.FlyCoins(fromGui: GuiObject, toGui: GuiObject, n: number?)
	local a, b = ctx.ToRoot(fromGui), ctx.ToRoot(toGui)
	for i = 1, n or 8 do
		local c = Kit.image({ Image = Theme.Icon.Coin, AnchorPoint = Vector2.new(0.5, 0.5), Position = a, Size = UDim2.fromOffset(46, 46), ZIndex = 8, Parent = toastLayer })
		local mid = UDim2.fromOffset((a.X.Offset + b.X.Offset) / 2 + math.random(-140, 140), math.min(a.Y.Offset, b.Y.Offset) - math.random(60, 170))
		task.delay(i * 0.045, function()
			tween(c, 0.3, { Position = mid, Rotation = math.random(-120, 120) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out).Completed:Wait()
			tween(c, 0.32, { Position = b, Size = UDim2.fromOffset(24, 24) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
			c:Destroy()
		end)
	end
end

-- floating "+120" style text from a screen point (root space)
function ctx.Float(at: UDim2, text: string, color: Color3)
	local l = Kit.text({
		Text = text,
		TextSize = 34,
		TextColor3 = color,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = at,
		Size = UDim2.fromOffset(200, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 5,
		Stroke = 4,
		Parent = toastLayer,
	})
	local sc = Kit.fx(l)
	sc.Scale = 0.4
	tween(sc, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(l, 1.1, { Position = at + UDim2.fromOffset(0, -54) }, Enum.EasingStyle.Quint)
	task.delay(0.7, function()
		tween(l, 0.4, { TextTransparency = 1 })
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			tween(st, 0.4, { Transparency = 1 })
		end
		task.wait(0.45)
		l:Destroy()
	end)
end

-- little star burst (root space)
function ctx.Burst(at: UDim2, color: Color3, count: number?)
	for i = 1, count or 10 do
		local star = Kit.image({
			Image = Theme.Icon.Star,
			ImageColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at,
			Size = UDim2.fromOffset(30, 30),
			ZIndex = 6,
			Parent = toastLayer,
		})
		local ang = (i / (count or 10)) * math.pi * 2 + math.random() * 0.5
		local dist = 70 + math.random() * 60
		tween(star, 0.75, {
			Position = at + UDim2.fromOffset(math.cos(ang) * dist, math.sin(ang) * dist),
			Rotation = math.random(-200, 200),
			Size = UDim2.fromOffset(10, 10),
			ImageTransparency = 1,
		}, Enum.EasingStyle.Quint)
		task.delay(0.8, function()
			star:Destroy()
		end)
	end
end

-- converts a gui's on-screen centre into root space (for floats / bursts)
function ctx.ToRoot(g: GuiObject): UDim2
	local p = g.AbsolutePosition + g.AbsoluteSize / 2 - root.AbsolutePosition
	return UDim2.fromOffset(p.X / ctx.Scale, p.Y / ctx.Scale)
end

-- other client scripts (the quest system) can pop toasts through OverkillUI.Notify
task.spawn(function()
	local notify = UI:WaitForChild("Notify", 30)
	if notify and notify:IsA("BindableEvent") then
		notify.Event:Connect(function(o)
			if type(o) == "table" then
				ctx.Toast(o)
				if o.Sound then
					Kit.sfx(o.Sound)
				end
			end
		end)
	end
end)

---------------------------------------------------------------------------
-- window manager (one at a time, dim + blur + a small FOV push)
---------------------------------------------------------------------------
local blur = Lighting:FindFirstChild("OverkillUIBlur") or new("BlurEffect", { Name = "OverkillUIBlur", Size = 0, Parent = Lighting })
local current: string? = nil
local fovBase: number? = nil

local function questOpen(): boolean
	return player:GetAttribute("QuestUIOpen") == true
end

local function setBackdrop(on: boolean)
	if on then
		dim.Visible = true
		tween(dim, 0.3, { BackgroundTransparency = 0.45 })
		tween(blur, 0.35, { Size = 14 })
		local cam = workspace.CurrentCamera
		if cam and cam.CameraType == Enum.CameraType.Custom and not questOpen() then
			fovBase = fovBase or cam.FieldOfView
			tween(cam, 0.45, { FieldOfView = (fovBase :: number) + 6 }, Enum.EasingStyle.Quart)
		end
	else
		tween(dim, 0.25, { BackgroundTransparency = 1 }).Completed:Connect(function()
			if not current then
				dim.Visible = false
			end
		end)
		tween(blur, 0.3, { Size = 0 })
		local cam = workspace.CurrentCamera
		if cam and fovBase then
			tween(cam, 0.35, { FieldOfView = fovBase }, Enum.EasingStyle.Quart)
			fovBase = nil
		end
	end
end

function ctx.Register(name: string, win: any)
	ctx.Windows[name] = win
end

function ctx.Open(name: string, arg: any?)
	-- one thing on screen at a time: no windows over the quest dialogue or the match screen
	if questOpen() or ctx.Overlay ~= nil then
		return
	end
	local win = ctx.Windows[name]
	if not win then
		return
	end
	if current == name then
		if win.OnOpen then
			win.OnOpen(arg)
		end
		return
	end
	if current and ctx.Windows[current] then
		ctx.Windows[current].Window.Close()
		if ctx.Windows[current].OnClose then
			ctx.Windows[current].OnClose()
		end
	else
		setBackdrop(true)
	end
	current = name
	win.Window.Open()
	if win.OnOpen then
		win.OnOpen(arg)
	end
	ctx.Fire("WindowChanged", name)
end

function ctx.Close()
	closeModal() -- a confirm pop-up never outlives its window
	if not current then
		return
	end
	local win = ctx.Windows[current]
	current = nil
	if win then
		win.Window.Close()
		if win.OnClose then
			win.OnClose()
		end
	end
	setBackdrop(false)
	ctx.Fire("WindowChanged", nil)
end

function ctx.Toggle(name: string, arg: any?)
	if current == name then
		ctx.Close()
	else
		ctx.Open(name, arg)
	end
end

function ctx.Current(): string?
	return current
end

dim.Activated:Connect(function()
	ctx.Close()
end)

---------------------------------------------------------------------------
-- the HUD column: party frames, the portal card, the dock buttons and the hero / coin / level
-- pills, one stack. Bottom-left on desktop (clear of the chat window), top-left on phones (clear
-- of the thumbstick; the party frames stand beside it there).
-- EVERY group in it has the HUD's one outline (Theme.Hud.Outline) centred on its own frame's edge,
-- and every frame is exactly as tall as the shape it draws (no spare rows, no drop shadows), so
-- one UIListLayout with Theme.Hud.GroupGap makes the ink-to-ink gap between any two neighbours the
-- same number, to the pixel: level-coins, coins-hero, hero-dock, dock-portal card, card-party.
---------------------------------------------------------------------------
local HUD = Theme.Hud
local GAP = HUD.GroupGap
local CORNER_W = HUD.ColumnWidth -- five dock buttons (5 x 100 + 4 x 12)
local function cornerPos(off: boolean): UDim2
	local x = if off then -CORNER_W - HUD.Margin else HUD.Margin
	if isTouch then
		return UDim2.fromOffset(x, HUD.TouchTop)
	end
	return UDim2.new(0, x, 1, -HUD.Bottom)
end
local corner = new("Frame", {
	Name = "Corner",
	BackgroundTransparency = 1,
	AnchorPoint = if isTouch then Vector2.new(0, 0) else Vector2.new(0, 1),
	Position = cornerPos(false),
	Size = UDim2.fromOffset(CORNER_W, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = hudLayer,
})
Kit.list(corner, Enum.FillDirection.Vertical, GAP, Enum.HorizontalAlignment.Left, if isTouch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Bottom)
-- where each group goes in the column (top to bottom): the party frames and the portal card come
-- from their own modules (PartyWindow, PortalSigns) through ctx.Column / ctx.ColumnOrder
ctx.Column = corner
ctx.ColumnOrder = if isTouch then { Status = 1, Dock = 2, Portal = 3, Party = 4 } else { Party = 1, Portal = 2, Dock = 3, Status = 4 }
local status = new("Frame", {
	Name = "Status",
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(CORNER_W, 0), -- three pills: hero (HeroSelect adds it), coins, level
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = ctx.ColumnOrder.Status,
	Parent = corner,
})
Kit.list(status, Enum.FillDirection.Vertical, GAP)

-- the status pills: one shape for all three. A badge (portrait / coin / star) sits on the left
-- cap, a small caption over the value, an action on the right. Every badge centre, caption,
-- value and right edge lines up from pill to pill. A pill's row is exactly the pill's height (the
-- badges may overhang it; the pills' own outlines are what the column spaces).
local PILL_H = HUD.PillHeight
local HOLDER_H = PILL_H
local BADGE_X = 38 -- badge centre, holder space
local PILL_X = 30 -- pill left edge, holder space
local TEXT_X = 57 -- captions and values, pill space (clear of the badge)
local RIGHT_PAD = 8 -- actions and the xp bar end here, pill space
ctx.PillMetrics = { Height = PILL_H, BadgeX = BADGE_X, BadgeY = HOLDER_H / 2, TextX = TEXT_X, RightPad = RIGHT_PAD }
-- where the dock's tiles are (cards that stand on the column line up with them): Left / Width of
-- the column; desktop: TileTop = the tiles' top edge above the screen's bottom; phones: TileFoot =
-- the tiles' bottom edge below the top; Gap = the space between neighbours in the column
ctx.DockMetrics = {
	Left = HUD.Margin,
	Width = CORNER_W,
	TileTop = HUD.Bottom + (PILL_H * 3 + GAP * 2) + GAP + HUD.TileHeight,
	TileFoot = HUD.TouchTop + (PILL_H * 3 + GAP * 2) + GAP + HUD.TileHeight,
	Gap = GAP,
	Stroke = HUD.Outline,
}

-- the pills' background textures: little silhouettes (shurikens, coins or stars) scattered at
-- random angles and sizes, never closer than a set gap, all fully inside the capsule. They are
-- drawn opaque inside one CanvasGroup that is faded as a whole, so overlapping pieces of a shape
-- never show darker seams, and the texture stays a quiet tone of the pill's own rim colour.
local PATTERN_SEED = { Shuriken = 7, Coins = 11, Stars = 5 }
local function patternShape(kind: string, parent: Instance, x: number, y: number, r: number, rot: number, z: number)
	local holder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(r * 2, r * 2), Rotation = rot, ZIndex = z, Parent = parent })
	if kind == "Shuriken" then
		-- four blades: a cross with tapered ends around a diamond heart, and a hole in the middle
		for i = 0, 1 do
			local bar = new("Frame", {
				BackgroundColor3 = C.Rim,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = if i == 0 then UDim2.fromScale(1, 0.24) else UDim2.fromScale(0.24, 1),
				ZIndex = z,
				Parent = holder,
			})
			new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = bar })
		end
		local heart = new("Frame", { BackgroundColor3 = C.Rim, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.52, 0.52), Rotation = 45, ZIndex = z, Parent = holder })
		new("UICorner", { CornerRadius = UDim.new(0.18, 0), Parent = heart })
		local hole = new("Frame", { BackgroundColor3 = C.Night, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.2, 0.2), ZIndex = z + 1, Parent = holder })
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = hole })
	elseif kind == "Coins" then
		-- a coin: a disc with a milled inner rim
		local disc = new("Frame", { BackgroundColor3 = C.Rim, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = holder })
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = disc })
		local rim = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.66, 0.66), ZIndex = z + 1, Parent = holder })
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = rim })
		new("UIStroke", { Color = C.Night, Thickness = math.max(1, r * 0.16), Parent = rim })
	else
		-- the glyph fills less of its line than the other shapes: drawn a size up
		Kit.text({
			Text = "\u{2605}",
			TextScaled = true,
			TextColor3 = C.Rim,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.3, 1.3),
			ZIndex = z,
			Stroke = false,
			Parent = holder,
		})
	end
end

local function pillPattern(skin: Instance, kind: string, z: number)
	local group = new("CanvasGroup", { Name = "Pattern", BackgroundTransparency = 1, GroupTransparency = 0.9, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = skin })
	local W, H, MARGIN = CORNER_W - PILL_X, PILL_H, 5
	local rng = Random.new(PATTERN_SEED[kind] or 1)
	local placed: { { number } } = {}
	local rMin, rMax = if kind == "Coins" then 4.5 else 5.5, if kind == "Coins" then 6 else 7.5
	-- a star glyph covers far less of its box than a shuriken or a coin, so the star pill packs
	-- them closer to read as the same density as the other two
	local gap = if kind == "Stars" then 9 else 15
	for _ = 1, 1400 do
		local r = rng:NextNumber(rMin, rMax)
		local x, y = rng:NextNumber(0, W), rng:NextNumber(0, H)
		-- fully inside the capsule (rounded ends), with a margin
		local cx = math.clamp(x, H / 2, W - H / 2)
		if math.sqrt((x - cx) ^ 2 + (y - H / 2) ^ 2) <= H / 2 - MARGIN - r then
			local ok = true
			for _, q in ipairs(placed) do
				if math.sqrt((x - q[1]) ^ 2 + (y - q[2]) ^ 2) < gap + r + q[3] then
					ok = false
					break
				end
			end
			if ok then
				table.insert(placed, { x, y, r })
				patternShape(kind, group, x, y, r, rng:NextNumber(0, 360), z)
			end
		end
	end
	return group
end

local function statusPill(name: string, order: number, caption: string?, accent: Color3?, pattern: string?)
	local holder = new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromOffset(CORNER_W, HOLDER_H), LayoutOrder = order, Parent = status })
	local pill = Kit.plate({
		Name = "Pill",
		Parent = holder,
		Position = UDim2.fromOffset(PILL_X, (HOLDER_H - PILL_H) / 2),
		Size = UDim2.new(1, -PILL_X, 0, PILL_H),
		Radius = UDim.new(1, 0),
		Stroke = false, -- drawn by the Outline layer on top (below)
	})
	pill.Size = UDim2.new(1, -PILL_X, 1, 0) -- the pill IS its row
	Kit.gradient(pill, C.Navy700, C.Night, 90)
	pill.BackgroundColor3 = Color3.new(1, 1, 1)
	-- the ink outline is its own layer above the pill's texture and the action socket (children
	-- draw over their parent's stroke), same rect as the pill so it lines up to the pixel
	local outline = new("Frame", { Name = "Outline", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = pill.ZIndex + 2, Parent = pill })
	Kit.pill(outline)
	Kit.stroke(outline, HUD.Outline, C.Ink, 0, true)
	-- the windows' dress: faint stripes and the pill's own colour glowing in from the left
	local skin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = pill.ZIndex, Parent = pill })
	Kit.pill(skin)
	-- a faint texture made for this pill (shurikens / coins / stars), clipped to the capsule
	if pattern then
		pillPattern(skin, pattern, pill.ZIndex)
	else
		Kit.stripes(skin, C.Rim, 0.955, pill.ZIndex, 8, 18)
	end
	local glow = new("Frame", { Name = "Glow", BackgroundColor3 = accent or C.Blue, BorderSizePixel = 0, Size = UDim2.fromScale(0.62, 1), ZIndex = pill.ZIndex, Parent = skin })
	local glowGrad = Kit.gradient(glow, Color3.new(1, 1, 1), Color3.new(1, 1, 1), 0, 0.8, 1)
	local cap = Kit.text({
		Name = "Caption",
		Text = caption or "",
		TextSize = 14,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(TEXT_X, 7),
		Size = UDim2.new(1, -TEXT_X - RIGHT_PAD, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = pill.ZIndex + 2,
		Stroke = 2,
		Parent = pill,
	})
	return holder, pill, cap, glow, glowGrad
end
ctx.StatusPill = statusPill

-- a value under the caption (same place in every pill)
local function pillValue(pill: GuiObject, text: string, color: Color3, rightSpace: number): TextLabel
	return Kit.text({
		Name = "Value",
		Text = text,
		TextSize = 28,
		TextColor3 = color,
		Position = UDim2.fromOffset(TEXT_X, 23),
		Size = UDim2.new(1, -TEXT_X - rightSpace, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = pill.ZIndex + 2,
		Stroke = 3.5,
		Parent = pill,
	})
end
ctx.PillValue = pillValue

-- an action button in a pill's right end (the coins +, the hero pill's CHANGE). The button is the
-- pill's whole right end (the same top, right and bottom edges as the pill) and sits flush in
-- it: one black band runs all the way round its face - the pill's own outline and the button's
-- outline together, no gap and no second colour between them. The band is a stroke inward from
-- the button's edge with, over it, the pill's outline stroke centred on the button's edge (on
-- the top, right and bottom it lies exactly on the pill's own outline; on the left it gives the
-- side facing into the pill the same weight and covers that edge whole, so no trace of the face
-- shows through it), so it is exactly as thick on every side at any screen size.
--   o = { Width (the button's own width; nil = round), Text, TextSize, Glyph (function(content, z)),
--         Color, Deep, OnClick, HoverScale }
local ACTION_H = PILL_H - RIGHT_PAD * 2 -- 44
local function faceSeq(c: Color3, d: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Kit.lighten(c, 0.14)),
		ColorSequenceKeypoint.new(0.55, c),
		ColorSequenceKeypoint.new(1, Kit.lighten(d, 0.1)),
	})
end
local PILL_LINE = HUD.Outline * 1.35 -- the pill's outline (Kit.stroke border width)
local ACTION_LINE = 3 * 1.35 -- a button's own outline
local function pillAction(pill: GuiObject, o: { [string]: any })
	local w = o.Width or ACTION_H
	local color, deep = o.Color or C.Blue, o.Deep or C.BlueDeep
	local btn = Kit.slot({ Parent = pill, Class = "TextButton", Name = o.Name or "Action", Side = "Right", Width = w + RIGHT_PAD * 2, ZIndex = pill.ZIndex + 1 }) :: TextButton
	btn.BackgroundTransparency = 0
	Kit.pill(btn)
	local faceGrad = Kit.paint(btn, faceSeq(color, deep))
	Kit.edgeStrokes(btn, UDim.new(1, 0), { { PILL_LINE / 2 + ACTION_LINE, C.Ink }, { PILL_LINE, C.Ink, nil, "Center" } }, pill.ZIndex + 1)
	local icon = { Face = faceGrad, ContentZ = pill.ZIndex + 2 }

	-- the label or glyph pops on hover; the button's shape stays put in the pill's end
	local content = new("Frame", { Name = "Content", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = icon.ContentZ, Parent = btn })
	local pop = Kit.fx(content)
	local label: TextLabel? = nil
	if o.Text then
		label = Kit.text({ Text = o.Text, TextSize = o.TextSize or 21, ZIndex = icon.ContentZ, Parent = content })
	end
	if o.Glyph then
		o.Glyph(content, icon.ContentZ)
	end
	local api = { Button = btn, Label = label, Enabled = true }
	local base = { color, deep }
	function api.SetText(t: string)
		if label then
			label.Text = t
		end
	end
	function api.SetColor(c: Color3, d: Color3?)
		base = { c, d or Kit.darken(c, 0.35) }
		if icon.Face then
			icon.Face.Color = faceSeq(base[1], base[2])
		end
	end
	local hovering = false
	btn.MouseEnter:Connect(function()
		hovering = true
		tween(pop, 0.22, { Scale = o.HoverScale or 1.1 }, Enum.EasingStyle.Back)
		if icon.Face then
			icon.Face.Color = faceSeq(Kit.lighten(base[1], 0.1), Kit.lighten(base[2], 0.08))
		end
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		tween(pop, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
		if icon.Face then
			icon.Face.Color = faceSeq(base[1], base[2])
		end
	end)
	btn.MouseButton1Down:Connect(function()
		tween(pop, 0.08, { Scale = 0.92 }, Enum.EasingStyle.Quad)
	end)
	btn.MouseButton1Up:Connect(function()
		tween(pop, 0.18, { Scale = if hovering then o.HoverScale or 1.1 else 1 }, Enum.EasingStyle.Back)
	end)
	btn.Activated:Connect(function()
		if not api.Enabled then
			return
		end
		Kit.sfx("Click")
		if o.OnClick then
			o.OnClick()
		end
	end)
	return api
end
ctx.PillAction = pillAction

-- coins
local coinHolder, coinPill = statusPill("Coins", 1, "COINS", C.Gold, "Coins")
local coinIcon = Kit.image({
	Name = "CoinIcon",
	Image = Theme.Icon.Coin,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(BADGE_X, HOLDER_H / 2),
	Size = UDim2.fromOffset(76, 76),
	ZIndex = 5,
	Parent = coinHolder,
})
local coinText = pillValue(coinPill, "0", C.Gold, RIGHT_PAD + ACTION_H + 12)
local setCoins = Kit.counter(coinText, Theme.Comma, 0)
pillAction(coinPill, {
	Name = "Plus",
	Color = C.Green,
	Deep = C.GreenDeep,
	HoverScale = 1.12,
	Glyph = function(content: GuiObject, z: number)
		Kit.plusGlyph(content, 16, z)
	end,
	OnClick = function()
		ctx.Open("Shop", "Coins")
	end,
})

-- level: star badge with the level, caption row "LEVEL n ... xp / need XP", the bar under it
local levelHolder, levelPill, levelCaption = statusPill("Level", 2, "LEVEL 1", C.Blue, "Stars")
local star = Kit.image({
	Name = "Star",
	Image = Theme.Icon.Star,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(BADGE_X, HOLDER_H / 2 - 1),
	Size = UDim2.fromOffset(80, 80),
	ZIndex = 5,
	Parent = levelHolder,
})
local levelNum = Kit.text({
	Name = "Level",
	Text = "1",
	TextSize = 26,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.56),
	Size = UDim2.fromScale(1, 0.5),
	ZIndex = 6,
	Stroke = 3.5,
	Parent = star,
})
local xpText = Kit.text({
	Name = "XpText",
	Text = "",
	TextSize = 14,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextSoft,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -RIGHT_PAD - 6, 0, 7),
	Size = UDim2.fromOffset(220, 18),
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = levelPill.ZIndex + 2,
	Stroke = 2,
	Parent = levelPill,
})
local xpBar = Kit.bar({
	Name = "XP",
	Parent = levelPill,
	Position = UDim2.fromOffset(TEXT_X, 29),
	Size = UDim2.new(1, -TEXT_X - RIGHT_PAD - 6, 0, 20),
	Color = Color3.fromRGB(110, 226, 255),
	Deep = Color3.fromRGB(44, 124, 240),
	Stroke = 3,
	ZIndex = levelPill.ZIndex + 2,
})

---------------------------------------------------------------------------
-- dock: SHOP / STATS / BAG / MENU / PARTY
---------------------------------------------------------------------------
local dock = new("Frame", {
	Name = "Dock",
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(CORNER_W, HUD.TileHeight), -- exactly the tiles' height
	LayoutOrder = ctx.ColumnOrder.Dock,
	Parent = corner,
})
-- five tiles, HUD.IconGap apart (every tile the same width and outline: every gap the same)
Kit.list(dock, Enum.FillDirection.Horizontal, HUD.IconGap, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)

ctx.Dock = {}
local function dockButton(o: { [string]: any })
	local accent = o.Accent[1]
	local holder = new("Frame", { Name = o.Name, BackgroundTransparency = 1, Size = UDim2.fromOffset(HUD.TileWidth, HUD.TileHeight), LayoutOrder = o.Order, Parent = dock })
	local api: any
	api = Kit.button({
		Name = "Button",
		Parent = holder,
		Size = UDim2.fromOffset(HUD.TileWidth, HUD.TileHeight),
		Color = C.Navy600,
		Deep = C.Navy800,
		Radius = HUD.CardRadius,
		Depth = 0, -- flat tile, no 3D lip
		Stroke = HUD.Outline,
		HoverScale = 1.08,
		OnClick = o.OnClick,
		OnHover = function(on: boolean)
			if on then
				Kit.wiggle(api.Extra.Icon, 1)
			end
		end,
	})
	local z = api.Face.ZIndex
	-- flat and 2D: one solid colour on the face (no shading, no glow rising from the bottom)
	local faceGrad = api.Face:FindFirstChildOfClass("UIGradient")
	if faceGrad then
		faceGrad.Color = ColorSequence.new(C.Navy600)
	end
	-- the accent ring 6 in from the tile's edge: strokes on the face's own rect (the ring, then
	-- the face over its outer side), so it is exactly as far in on every side; the tile's
	-- outline goes over them, so their outer edge leaves no trace in it
	local ringW = 2.5 * 1.35
	Kit.edgeStrokes(api.Face, UDim.new(0, 28), {
		{ 6 + ringW / 2, accent },
		{ 6 - ringW / 2, C.Navy600 },
	}, z + 1)
	Kit.outlineOnTop(api.Face, z + 5)
	-- the icon between the accent ring (inner edge 7.7 down) and the name tag (ink top 79.6): about
	-- 3 clear above and below it, the same on every tile
	local icon = Kit.image({
		Name = "Icon",
		Image = o.Icon,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 44),
		Size = UDim2.fromOffset(66, 66),
		ZIndex = z + 3,
		Parent = api.Face,
	})
	-- name tag on the bottom edge: its foot sits on the tile's own bottom edge, so the tag never
	-- hangs below the tile's outline (the tile's outline is the dock's edge in the column)
	local tag = Kit.plate({
		Name = "Tag",
		Parent = api.Body,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = HUD.ThinOutline,
		ZIndex = z + 6,
		Color = accent, -- flat, like the tile
	})
	Kit.padding(tag, 14, 0, 14, 0)
	Kit.text({
		Text = o.Label,
		TextSize = 21,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = z + 7,
		Stroke = 3.2,
		Parent = tag,
	})
	-- (no key caps on the tiles: the dock reads as clean icon tiles; the keys still work, and
	-- Settings lists them)
	local keyLabel: TextLabel? = nil
	-- notification badge
	local badge = Kit.plate({
		Name = "Badge",
		Parent = api.Body,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(34, 34),
		Radius = UDim.new(1, 0),
		Stroke = 3,
		ZIndex = z + 8,
		Gradient = { C.Red, C.RedDeep },
	})
	badge.Visible = false
	local badgeText = Kit.text({ Text = "!", TextSize = 20, ZIndex = z + 9, Stroke = 2.5, Parent = badge })
	api.Extra = { Icon = icon, Tag = tag, Badge = badge, BadgeText = badgeText, Holder = holder, KeyLabel = keyLabel }
	ctx.Dock[o.Name] = api

	-- the notification badge rocks gently (engine tween, no script loop)
	badge.Rotation = -8
	game:GetService("TweenService"):Create(badge, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Rotation = 8 }):Play()
	return api
end

function ctx.SetBadge(name: string, count: number?)
	local d = ctx.Dock[name]
	if not d then
		return
	end
	local b = d.Extra.Badge
	local show = count ~= nil and count > 0
	if show and not b.Visible then
		local sc = Kit.fx(b)
		sc.Scale = 0.2
		tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	b.Visible = show
	if show then
		d.Extra.BadgeText.Text = if (count :: number) > 9 then "9+" else tostring(count)
	end
end

dockButton({ Name = "Shop", Label = "SHOP", Icon = Theme.Icon.Shop, Accent = Theme.Accent.Shop, Key = Theme.Keys.Shop, Order = 1, OnClick = function()
	ctx.Toggle("Shop")
end })
dockButton({ Name = "Stats", Label = "STATS", Icon = Theme.Icon.Stats, Accent = Theme.Accent.Stats, Key = Theme.Keys.Stats, Order = 2, OnClick = function()
	ctx.Toggle("Stats")
end })
dockButton({ Name = "Bag", Label = "BAG", Icon = Theme.Icon.Bag, Accent = Theme.Accent.Bag, Key = Theme.Keys.Bag, Order = 3, OnClick = function()
	ctx.Toggle("Bag")
end })
dockButton({ Name = "Settings", Label = "MENU", Icon = Theme.Icon.Gear, Accent = Theme.Accent.Settings, Key = Theme.Keys.Settings, Order = 5, OnClick = function()
	ctx.Toggle("Settings")
end })
dockButton({ Name = "Party", Label = "PARTY", Icon = Theme.Icon.Party, Accent = Theme.Accent.Party, Key = Theme.Keys.Party, Order = 4, OnClick = function()
	ctx.Toggle("Party")
end })

-- keybinds changed in Settings: the key caps on the dock follow
ctx.On("KeysChanged", function()
	for name, d in pairs(ctx.Dock) do
		local lbl = d.Extra.KeyLabel
		local k = Theme.Keys[name]
		if lbl and k then
			lbl.Text = Theme.KeyText(k)
		end
	end
end)

---------------------------------------------------------------------------
-- coins / xp from leaderstats (QuestServer makes these)
---------------------------------------------------------------------------
local lastLevel: number? = nil
local function setXp(xp: number, instant: boolean?)
	ctx.Stats.XP = xp
	local level, inLevel, need = Theme.LevelFromXp(xp)
	ctx.Stats.Level = level
	ctx.Stats.XpIn = inLevel
	ctx.Stats.XpNeed = need
	levelNum.Text = tostring(level)
	levelNum.TextSize = if level >= 100 then 20 elseif level >= 10 then 24 else 26
	levelCaption.Text = ("LEVEL %d"):format(level)
	xpBar.Set(inLevel / need, instant)
	xpText.Text = ("%s / %s XP"):format(Theme.Comma(inLevel), Theme.Comma(need))
	if lastLevel and level > lastLevel then
		ctx.Toast({ Title = "LEVEL UP!", Text = ("You reached level %d"):format(level), Icon = Theme.Icon.Star, Color = C.Gold, Deep = C.GoldDeep })
		Kit.sfx("Buy")
		tween(star, 0.6, { Rotation = 360 }, Enum.EasingStyle.Back).Completed:Connect(function()
			star.Rotation = 0
		end)
		ctx.Burst(ctx.ToRoot(star), C.Gold, 12)
	end
	lastLevel = level
	ctx.Fire("Xp", xp)
end

local function setCoinValue(v: number, instant: boolean?)
	local before = ctx.Stats.Coins
	ctx.Stats.Coins = v
	setCoins(v, instant)
	if not instant and v > before then
		ctx.Float(ctx.ToRoot(coinPill) + UDim2.fromOffset(20, -10), "+" .. Theme.Comma(v - before), C.Gold)
		local sc = Kit.fx(coinIcon)
		sc.Scale = 1.3
		tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		Kit.wiggle(coinIcon)
	end
	ctx.Fire("Coins", v)
end

local function hookValue(ls: Instance, name: string, apply: (number, boolean?) -> ())
	local function bind(v: Instance)
		if v:IsA("IntValue") or v:IsA("NumberValue") then
			local val: any = v
			apply(val.Value, true)
			val.Changed:Connect(function(n)
				apply(n, false)
			end)
		end
	end
	local v = ls:FindFirstChild(name)
	if v then
		bind(v)
	end
	ls.ChildAdded:Connect(function(c)
		if c.Name == name then
			bind(c)
		end
	end)
end

task.spawn(function()
	local ls = player:WaitForChild("leaderstats", 60)
	if ls then
		hookValue(ls, "Coins", setCoinValue)
		hookValue(ls, "XP", setXp)
	end
end)
setXp(0, true)

---------------------------------------------------------------------------
-- windows
---------------------------------------------------------------------------
local function load(name: string)
	local ok, err = pcall(function()
		require(script:WaitForChild(name))(ctx)
	end)
	if not ok then
		warn("[OverkillHUD] " .. name .. " failed to load:", err)
	end
end
load("ShopWindow")
load("AuraPreview") -- the 3D try-on the shop opens
load("HeroSelect") -- the character select screen (+ the HERO pill)
load("ProfileWindow")
load("Backpack")
load("LimbStatus") -- what your body has lost (over the hotbar)
load("SettingsWindow")
-- queue + party: the hub first (the others read ctx.Queue), off the main thread so a slow
-- remote never holds up the rest of the HUD
task.spawn(function()
	load("Queue")
	if ctx.Queue then
		load("QueueCard")
		load("MatchScreen")
		load("PartyWindow")
		load("PortalSigns")
	end
end)

---------------------------------------------------------------------------
-- keys
---------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
	-- ctx.KeyCapture: the keybinds page is listening for a new key, so hotkeys stay quiet
	if processed or UserInputService:GetFocusedTextBox() or ctx.KeyCapture then
		return
	end
	if input.KeyCode == Theme.Keys.Shop then
		ctx.Toggle("Shop")
	elseif input.KeyCode == Theme.Keys.Stats then
		ctx.Toggle("Stats")
	elseif input.KeyCode == Theme.Keys.Bag then
		ctx.Toggle("Bag")
	elseif input.KeyCode == Theme.Keys.Settings then
		ctx.Toggle("Settings")
	elseif input.KeyCode == Theme.Keys.Party then
		ctx.Toggle("Party")
	end
end)

---------------------------------------------------------------------------
-- step aside while the quest dialogue is on screen
---------------------------------------------------------------------------
-- HudHidden = the quest dialogue or a full-screen overlay owns the screen: the dock, hotbar,
-- queue cards, party frames and portal cards all step aside.
local function hudHidden(): boolean
	return questOpen() or ctx.Overlay ~= nil
end
ctx.HudHidden = hudHidden

local function applyQuestState()
	local open = questOpen()
	if open or ctx.Overlay ~= nil then
		ctx.Close()
	end
	tween(corner, 0.45, { Position = cornerPos(hudHidden() or ctx.Current() ~= nil) }, Enum.EasingStyle.Quint)
	-- keep toasts clear of the quest board's title plate
	tween(toastStack, 0.35, { Position = UDim2.new(0.5, 0, 0, if open then 12 else 86) }, Enum.EasingStyle.Quint)
	ctx.Fire("HudHidden", hudHidden())
end
player:GetAttributeChangedSignal("QuestUIOpen"):Connect(applyQuestState)

-- full-screen overlays (the match screen): nothing else may open or pop up while one is up,
-- and world prompts (quest givers) switch off so a dialogue can't start underneath it
-- thenOpen: clearing an overlay can hand the screen straight to a window (the aura preview goes
-- back to the shop) - the window opens first, so the dock and cards never slide in between
function ctx.SetOverlay(name: string?, thenOpen: string?, openArg: any?)
	if ctx.Overlay == name then
		return
	end
	ctx.Overlay = name
	player:SetAttribute("UIOverlay", name) -- combat input steps aside while an overlay is up
	pcall(function()
		game:GetService("ProximityPromptService").Enabled = name == nil
	end)
	if name == nil and thenOpen then
		ctx.Open(thenOpen, openArg)
	end
	applyQuestState()
	ctx.Fire("OverlayChanged", name)
	if name == nil and #heldToasts > 0 then
		local list = heldToasts
		heldToasts = {}
		for i, o in ipairs(list) do
			task.delay(0.35 + (i - 1) * 0.5, function()
				ctx.Toast(o)
			end)
		end
	end
end

-- the dock + coins + level slide away while a window (shop, stats, bag, settings) is open
ctx.On("WindowChanged", function(name: string?)
	player:SetAttribute("UIWindow", name) -- combat keys stay quiet while a window is open
	tween(corner, 0.4, { Position = cornerPos(name ~= nil or hudHidden()) }, Enum.EasingStyle.Quint)
end)

---------------------------------------------------------------------------
-- VIP chat tag (set by ShopServer through the ChatTag attribute)
---------------------------------------------------------------------------
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	pcall(function()
		TextChatService.OnIncomingMessage = function(message: TextChatMessage)
			local props = Instance.new("TextChatMessageProperties")
			local src = message.TextSource
			if src then
				local p = Players:GetPlayerByUserId(src.UserId)
				local tag = p and p:GetAttribute("ChatTag")
				if tag then
					props.PrefixText = ('<font color="#FFD440"><b>[%s]</b></font> '):format(tostring(tag)) .. message.PrefixText
				end
			end
			return props
		end
	end)
end

-- intro: slide the HUD in once
corner.Position = cornerPos(true)
task.delay(0.6, applyQuestState)

---------------------------------------------------------------------------
-- Studio: measure the column on screen (AbsolutePosition / AbsoluteSize) and print every gap,
-- ink edge to ink edge, in screen pixels - they must all be the same. Runs whenever the column
-- changes (a group shows or hides, the party changes, the screen or HUD size changes).
---------------------------------------------------------------------------
if game:GetService("RunService"):IsStudio() then
	local pending = false
	local lastReport = ""
	local function measure()
		pending = false
		local ink = HUD.Outline * 1.35 * ctx.Scale / 2 -- the outline's reach past a frame's edge
		local rows: { { Name: string, Top: number, Bottom: number } } = {}
		local function add(name: string, g: GuiObject)
			if g.Visible and g.AbsoluteSize.Y > 0.5 then
				table.insert(rows, { Name = name, Top = g.AbsolutePosition.Y - ink, Bottom = g.AbsolutePosition.Y + g.AbsoluteSize.Y + ink })
			end
		end
		for _, g in ipairs(corner:GetChildren()) do
			if g:IsA("GuiObject") and g.Visible then
				if g == status then
					for _, pillRow in ipairs(status:GetChildren()) do
						if pillRow:IsA("GuiObject") then
							add(pillRow.Name, pillRow)
						end
					end
				else
					add(g.Name, g)
				end
			end
		end
		table.sort(rows, function(a, b)
			return a.Top < b.Top
		end)
		local parts, gaps = {}, {}
		for i = 2, #rows do
			local gap = rows[i].Top - rows[i - 1].Bottom
			table.insert(gaps, gap)
			table.insert(parts, string.format("%s|%s %.3fpx", rows[i - 1].Name, rows[i].Name, gap))
		end
		local even = true
		for _, gp in ipairs(gaps) do
			if math.abs(gp - gaps[1]) > 0.01 then
				even = false
			end
		end
		-- the dock's tiles, left to right
		local tiles = {}
		for _, t in ipairs(dock:GetChildren()) do
			if t:IsA("GuiObject") then
				table.insert(tiles, t)
			end
		end
		table.sort(tiles, function(a, b)
			return a.AbsolutePosition.X < b.AbsolutePosition.X
		end)
		local tileGaps = {}
		for i = 2, #tiles do
			table.insert(tileGaps, string.format("%.3f", tiles[i].AbsolutePosition.X - (tiles[i - 1].AbsolutePosition.X + tiles[i - 1].AbsoluteSize.X)))
		end
		local report = string.format("[HUD] column gaps (ink to ink, screen px, scale %.3f): %s  -> %s | dock tile gaps: %s",
			ctx.Scale, table.concat(parts, ", "), if even then "EVEN" else "UNEVEN", table.concat(tileGaps, " "))
		if report ~= lastReport then
			lastReport = report
			if even then
				print(report)
			else
				warn(report)
			end
		end
	end
	local function soon()
		if not pending then
			pending = true
			task.delay(0.8, measure)
		end
	end
	corner:GetPropertyChangedSignal("AbsoluteSize"):Connect(soon)
	corner.ChildAdded:Connect(soon)
	ctx.On("Scale", soon)
	ctx.MeasureHud = measure
	soon()
end
