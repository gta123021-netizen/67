--[[
	SettingsWindow  (StarterPlayerScripts.OverkillHUD.SettingsWindow)
	Music + sound volume, UI size, and aura visibility. Saved per player by ShopServer.
	Music plays through SoundService.Music, UI sounds through SoundService.SFX
	(drop your own music ids into Theme.Music).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local ShopRequest = UI:WaitForChild("Remotes"):WaitForChild("ShopRequest") :: RemoteFunction

	local settings = Theme.CopySettings(Theme.DefaultSettings)

	local win = Kit.window({
		Name = "Settings",
		Size = Vector2.new(820, 716),
		Accent = Theme.Accent.Settings,
		Title = "SETTINGS",
		Icon = Theme.Icon.Gear,
		Parent = ctx.WindowLayer,
		OnClose = ctx.Close,
	})
	local content = win.Content

	-- GENERAL page (the KEYBINDS page sits in the same spot, the tabs switch between them)
	local list = new("Frame", { Name = "Rows", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 88), Size = UDim2.new(1, 0, 0, 466), ZIndex = 12, Parent = content })
	Kit.list(list, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center)

	local function row(order: number, title: string, sub: string, color: Color3, deep: Color3, glyph: string?, icon: string?, parent: Instance?): (Frame, TextLabel, UIStroke?)
		local r = Kit.plate({ Name = title, Parent = parent or list, Size = UDim2.new(1, 0, 0, 82), LayoutOrder = order, Radius = 24, Stroke = 4, ZIndex = 12, Gradient = { C.Navy600, C.Navy800 } })
		Kit.bevel(r, 20, 3, 12)
		-- the icon disc is the row's whole left end: its outline and the gap round it are strokes on
		-- it (in the row's colours), so the gap is the same at the left, the top and the bottom
		local disc = Kit.endIcon({
			Parent = r,
			Name = "Disc",
			Side = "Left",
			Width = 82,
			Gap = 13,
			Stroke = 3.5,
			Band = { C.Navy600, C.Navy800, 90 },
			Face = { Kit.lighten(color, 0.1), deep, 90 },
			ZIndex = 13,
		})
		local _, rowStroke = Kit.outlineOnTop(r, 16)
		if icon then
			Kit.image({ Image = icon, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(38, 38), ZIndex = disc.ContentZ, Parent = disc.Frame })
		else
			Kit.text({ Text = glyph or "", TextSize = 26, ZIndex = disc.ContentZ, Stroke = 3, Parent = disc.Frame })
		end
		Kit.text({ Text = title, TextSize = 25, Position = UDim2.fromOffset(84, 12), Size = UDim2.new(0.5, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13, Stroke = 3.2, Parent = r })
		local subLabel = Kit.text({
			Name = "Sub",
			Text = sub,
			TextSize = 15,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextDim,
			Position = UDim2.fromOffset(84, 44),
			Size = UDim2.new(0.5, 0, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 13,
			Stroke = 2,
			Parent = r,
		})
		return r, subLabel, rowStroke
	end

	-- "57%" (string.format's %d cuts 0.57 * 100 = 56.999... down to 56)
	local function pct(v: number): string
		return ("%d%%"):format(math.floor(v * 100 + 0.5))
	end

	local function valueLabel(parent: GuiObject): TextLabel
		return Kit.text({
			Text = "",
			TextSize = 24,
			TextColor3 = C.Gold,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -18, 0.5, 0),
			Size = UDim2.fromOffset(76, 34),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 14,
			Stroke = 3,
			Parent = parent,
		})
	end

	---------------------------------------------------------------------------
	-- saving (debounced) + applying
	---------------------------------------------------------------------------
	local saveToken = 0
	local function save()
		saveToken += 1
		local mine = saveToken
		task.delay(0.8, function()
			if mine ~= saveToken then
				return
			end
			pcall(function()
				ShopRequest:InvokeServer("settings", settings)
			end)
		end)
	end

	local function setOthersAuras(on: boolean)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player and p.Character then
				for _, d in ipairs(p.Character:GetDescendants()) do
					if d:GetAttribute("OverkillAura") then
						for _, fx in ipairs(if d:IsA("Attachment") then d:GetDescendants() else { d }) do
							if fx:IsA("ParticleEmitter") or fx:IsA("Beam") or fx:IsA("Light") or fx:IsA("Trail") then
								(fx :: any).Enabled = on
							end
						end
					end
				end
			end
		end
	end

	local function apply()
		local music = SoundService:FindFirstChild("Music")
		local sfx = SoundService:FindFirstChild("SFX")
		if music and music:IsA("SoundGroup") then
			music.Volume = settings.Music
		end
		if sfx and sfx:IsA("SoundGroup") then
			sfx.Volume = settings.Sfx
		end
		ctx.SetUserScale(settings.Ui)
		setOthersAuras(settings.OthersAuras)
		Theme.SetKeys(settings.Keys)
		ctx.Fire("KeysChanged")
	end

	-- keep hiding auras on characters that load later
	local function watchCharacter(char: Model, p: Player)
		char.DescendantAdded:Connect(function(d)
			if p ~= player and not settings.OthersAuras then
				task.defer(function()
					if d:GetAttribute("OverkillAura") or (d.Parent and d.Parent:GetAttribute("OverkillAura")) then
						if d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Light") or d:IsA("Trail") then
							(d :: any).Enabled = false
						end
					end
				end)
			end
		end)
	end
	local function watchPlayer(p: Player)
		if p.Character then
			watchCharacter(p.Character, p)
		end
		p.CharacterAdded:Connect(function(c)
			watchCharacter(c, p)
		end)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	---------------------------------------------------------------------------
	-- rows
	---------------------------------------------------------------------------
	local musicRow = row(1, "Music", "Background music volume", C.Pink, C.PinkDeep, "\u{266A}")
	local musicVal = valueLabel(musicRow)
	local musicSlider = Kit.slider({
		Parent = musicRow,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -108, 0.5, 0),
		Size = UDim2.fromOffset(250, 44),
		Color = C.Pink,
		Deep = C.PinkDeep,
		Value = settings.Music,
		OnChanged = function(v)
			settings.Music = math.floor(v * 100 + 0.5) / 100
			musicVal.Text = pct(settings.Music)
			apply()
		end,
		OnReleased = save,
	})

	local sfxRow = row(2, "Sound Effects", "Buttons, rewards and pop-ups", C.Blue, C.BlueDeep, "FX")
	local sfxVal = valueLabel(sfxRow)
	local sfxSlider = Kit.slider({
		Parent = sfxRow,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -108, 0.5, 0),
		Size = UDim2.fromOffset(250, 44),
		Color = C.Blue,
		Deep = C.BlueDeep,
		Value = settings.Sfx,
		OnChanged = function(v)
			settings.Sfx = math.floor(v * 100 + 0.5) / 100
			sfxVal.Text = pct(settings.Sfx)
			apply()
		end,
		OnReleased = function()
			Kit.sfx("Buy")
			save()
		end,
	})

	-- UI size: 80% .. 120%
	local uiRow = row(3, "UI Size", "Make the whole HUD bigger or smaller", C.Gold, C.GoldDeep, "Aa")
	local uiVal = valueLabel(uiRow)
	local uiSlider = Kit.slider({
		Parent = uiRow,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -108, 0.5, 0),
		Size = UDim2.fromOffset(250, 44),
		Color = C.Gold,
		Deep = C.GoldDeep,
		Value = (settings.Ui - 0.8) / 0.4,
		OnChanged = function(v)
			settings.Ui = math.floor((0.8 + v * 0.4) * 100 + 0.5) / 100
			uiVal.Text = pct(settings.Ui)
		end,
		OnReleased = function()
			apply()
			save()
		end,
	})

	local auraRow = row(4, "My Aura", "Show the aura you have equipped", Color3.fromRGB(255, 140, 60), Color3.fromRGB(214, 70, 30), nil, Theme.Icon.Flame)
	local auraToggle = Kit.toggle({
		Parent = auraRow,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -18, 0.5, 0),
		Value = settings.AuraOn,
		OnChanged = function(v)
			settings.AuraOn = v
			save()
		end,
	})

	local othersRow = row(5, "Other Players' Auras", "Turn off for smoother frames in busy servers", C.Green, C.GreenDeep, nil, Theme.Icon.Friends)
	local othersToggle = Kit.toggle({
		Parent = othersRow,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -18, 0.5, 0),
		Value = settings.OthersAuras,
		OnChanged = function(v)
			settings.OthersAuras = v
			apply()
			save()
		end,
	})


	---------------------------------------------------------------------------
	-- KEYBINDS page: click a key cap, press the new key. Taken keys swap, game keys are refused.
	---------------------------------------------------------------------------
	local keysPage = new("Frame", { Name = "Keybinds", BackgroundTransparency = 1, Position = list.Position, Size = list.Size, Visible = false, ZIndex = 12, Parent = content })
	Kit.list(keysPage, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center)

	local KEY_FACE, KEY_DEEP = Color3.fromRGB(240, 244, 252), Color3.fromRGB(172, 186, 214)
	local keyRows: { any } = {}
	local listening: any = nil
	local listenToken = 0

	local function keyName(id: string): string
		return (settings.Keys and settings.Keys[id]) or Theme.DefaultKeys[id]
	end

	local function paintCap(kr: any, active: boolean)
		if active then
			kr.Cap.SetColor(C.Purple, C.PurpleDeep)
			kr.Cap.Label.TextColor3 = C.Text
			kr.CapStroke.Enabled = true
		else
			kr.Cap.SetColor(KEY_FACE, KEY_DEEP)
			kr.Cap.Label.TextColor3 = C.Ink
			kr.CapStroke.Enabled = false
		end
	end

	local function refreshKeyRow(kr: any)
		local name = keyName(kr.Id)
		local def = Theme.DefaultKeys[kr.Id]
		kr.Cap.SetText(Theme.KeyText(name))
		kr.Sub.Text = if name ~= def then kr.Action.Sub .. "  ·  default " .. Theme.KeyText(def) else kr.Action.Sub
		kr.Sub.TextColor3 = C.TextDim
	end

	local function stopListening()
		local kr = listening
		if not kr then
			return
		end
		listening = nil
		-- let this key press finish before the hotkeys wake up again
		task.delay(0.15, function()
			if not listening then
				ctx.KeyCapture = false
			end
		end)
		if kr.Pulse then
			kr.Pulse:Cancel()
			kr.Pulse = nil
		end
		kr.CapStroke.Transparency = 0.2
		paintCap(kr, false)
		tween(kr.RowStroke, 0.2, { Color = C.Ink })
		refreshKeyRow(kr)
	end

	local function startListening(kr: any)
		if listening == kr then
			stopListening()
			return
		end
		stopListening()
		listening = kr
		ctx.KeyCapture = true
		paintCap(kr, true)
		kr.Cap.SetText("?")
		kr.Sub.Text = "Press any key  ·  click again to cancel"
		kr.Sub.TextColor3 = Kit.lighten(C.Purple, 0.35)
		tween(kr.RowStroke, 0.2, { Color = C.Purple })
		kr.Pulse = TweenService:Create(kr.CapStroke, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.85 })
		kr.Pulse:Play()
		listenToken += 1
		local token = listenToken
		task.delay(8, function()
			if listening == kr and listenToken == token then
				stopListening()
			end
		end)
	end

	for i, action in ipairs(Theme.KeyActions) do
		local accent = Theme.Accent[action.Id] or Theme.Accent.Settings
		local icon = (Theme.Icon :: any)[action.Id] or Theme.Icon.Gear
		local r, sub, rowStroke = row(i, action.Label, action.Sub, accent[1], accent[2], nil, icon, keysPage)
		local kr: any = { Id = action.Id, Action = action, Row = r, Sub = sub }
		kr.RowStroke = rowStroke
		kr.Cap = Kit.button({
			Name = "KeyCap",
			Parent = r,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -18, 0.5, 0),
			Size = UDim2.fromOffset(150, 56),
			Radius = 16,
			Depth = 0,
			Stroke = 3.5,
			Color = KEY_FACE,
			Deep = KEY_DEEP,
			Text = Theme.KeyText(keyName(action.Id)),
			TextSize = 28,
			TextStroke = false,
			ZIndex = 14,
			HoverScale = 1.05,
			OnClick = function()
				startListening(kr)
			end,
		})
		kr.Cap.Label.TextColor3 = C.Ink
		kr.CapScale = kr.Cap.Scale -- the button's own centred scale
		-- a soft purple ring while it's waiting for a key
		kr.CapStroke = Kit.stroke(kr.Cap.Face, 3, Kit.lighten(C.Purple, 0.4), 0.2, true)
		kr.CapStroke.Enabled = false
		table.insert(keyRows, kr)
		refreshKeyRow(kr)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject)
		local kr = listening
		if not kr or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.Escape then
			stopListening()
			return
		end
		local name = code.Name
		if not Theme.KeyAllowed(name) then
			Kit.sfx("Error")
			Kit.shake(kr.Cap.Button)
			kr.Sub.Text = Theme.KeyText(name) .. " is used by the game  ·  pick another key"
			kr.Sub.TextColor3 = Kit.lighten(C.Red, 0.3)
			return
		end
		local old = keyName(kr.Id)
		local swapped = nil
		for _, other in ipairs(keyRows) do
			if other ~= kr and keyName(other.Id) == name then
				settings.Keys[other.Id] = old -- the other action takes this one's old key
				swapped = other
			end
		end
		settings.Keys[kr.Id] = name
		stopListening()
		kr.CapScale.Scale = 1.18
		tween(kr.CapScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		Kit.sfx("Equip")
		if swapped then
			refreshKeyRow(swapped)
			local sw = swapped
			sw.CapScale.Scale = 1.18
			tween(sw.CapScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			sw.Sub.Text = "Swapped with " .. kr.Action.Label
			sw.Sub.TextColor3 = C.Gold
			task.delay(2.2, function()
				if listening ~= sw then
					refreshKeyRow(sw)
				end
			end)
		end
		apply()
		save()
	end)

	---------------------------------------------------------------------------
	-- GENERAL | KEYBINDS tabs (a sliding pill)
	---------------------------------------------------------------------------
	local page = "General"
	local generalRows = { musicRow, sfxRow, uiRow, auraRow, othersRow }
	local tabs = Kit.plate({
		Name = "Tabs",
		Parent = content,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(470, 62),
		Radius = UDim.new(1, 0),
		Stroke = 4,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	-- the purple thumb is half the track (plus 4 past the middle) and shares the track's edges on
	-- the side it sits at: the gap round it and its outline are strokes, 7 from the end, the top
	-- and the bottom
	local thumb = Kit.switchThumb({
		Parent = tabs,
		Gap = 7,
		Stroke = 3,
		Overhang = 4,
		Track = { C.Night, C.Navy900, 90 },
		Face = { Kit.lighten(C.Purple, 0.14), C.PurpleDeep, 90 },
		ZIndex = 13,
	})
	Kit.outlineOnTop(tabs, 14)
	local tabLabels: { [string]: TextLabel } = {}
	local setPage: (string, boolean?) -> () = function() end
	for i, def in ipairs({ { "General", "GENERAL" }, { "Keys", "KEYBINDS" } }) do
		local b = new("TextButton", {
			Name = def[1],
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale((i - 1) * 0.5, 0),
			Size = UDim2.fromScale(0.5, 1),
			ZIndex = 14,
			Parent = tabs,
		})
		tabLabels[def[1]] = Kit.text({ Text = def[2], TextSize = 24, TextColor3 = if i == 1 then C.Text else C.TextDim, ZIndex = 15, Stroke = 3, Parent = b })
		b.MouseEnter:Connect(function()
			if page ~= def[1] then
				tween(tabLabels[def[1]], 0.15, { TextColor3 = C.TextSoft })
			end
		end)
		b.MouseLeave:Connect(function()
			if page ~= def[1] then
				tween(tabLabels[def[1]], 0.15, { TextColor3 = C.TextDim })
			end
		end)
		b.Activated:Connect(function()
			setPage(def[1])
		end)
	end

	-- footer
	local footerText = Kit.text({
		Text = "Changes save automatically",
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -14),
		Size = UDim2.fromOffset(360, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 12,
		Stroke = 2.2,
		Parent = content,
	})

	local function showAll()
		musicSlider.Set(settings.Music, true)
		musicVal.Text = pct(settings.Music)
		sfxSlider.Set(settings.Sfx, true)
		sfxVal.Text = pct(settings.Sfx)
		uiSlider.Set((settings.Ui - 0.8) / 0.4, true)
		uiVal.Text = pct(settings.Ui)
		auraToggle.Set(settings.AuraOn, true)
		othersToggle.Set(settings.OthersAuras, true)
		for _, kr in ipairs(keyRows) do
			if kr ~= listening then
				refreshKeyRow(kr)
			end
		end
	end

	local resetBtn = Kit.button({
		Name = "Reset",
		Parent = content,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 1, -8),
		Size = UDim2.fromOffset(220, 58),
		Radius = 20,
		Color = C.Red,
		Deep = C.RedDeep,
		Text = "RESET",
		TextSize = 25,
		ZIndex = 13,
		Shine = true,
		OnClick = function()
			stopListening()
			if page == "Keys" then
				ctx.Confirm({
					Title = "RESET KEYBINDS?",
					Text = "Every hotkey goes back to its default key.",
					Icon = Theme.Icon.Gear,
					Confirm = "RESET",
					Color = C.Red,
					Deep = C.RedDeep,
					OnConfirm = function()
						settings.Keys = table.clone(Theme.DefaultKeys)
						showAll()
						apply()
						save()
					end,
				})
				return
			end
			ctx.Confirm({
				Title = "RESET SETTINGS?",
				Text = "Volume, UI size and aura options go back to default.",
				Icon = Theme.Icon.Gear,
				Confirm = "RESET",
				Color = C.Red,
				Deep = C.RedDeep,
				OnConfirm = function()
					local keys = settings.Keys -- keybinds have their own reset
					settings = Theme.CopySettings(Theme.DefaultSettings)
					settings.Keys = keys
					showAll()
					apply()
					save()
				end,
			})
		end,
	})

	-- loaded from the server with the shop state
	ctx.On("ShopState", function(state: any)
		if type(state) == "table" and type(state.Settings) == "table" then
			for k, v in pairs(state.Settings) do
				if settings[k] ~= nil and type(v) == type(settings[k]) then
					settings[k] = if type(v) == "table" then table.clone(v) else v
				end
			end
			showAll()
			apply()
		end
	end)

	showAll()
	apply()

	---------------------------------------------------------------------------
	-- music player (only runs if Theme.Music has ids)
	---------------------------------------------------------------------------
	if #Theme.Music > 0 then
		task.spawn(function()
			local group = SoundService:FindFirstChild("Music")
			local sound = new("Sound", { Name = "OverkillMusic", Volume = 0.6, SoundGroup = group, Parent = SoundService })
			local i = math.random(1, #Theme.Music)
			while true do
				local id = Theme.Music[i]
				sound.SoundId = if type(id) == "number" then "rbxassetid://" .. id else tostring(id)
				sound:Play()
				local t0 = os.clock()
				repeat
					task.wait(1)
				until not sound.IsPlaying and os.clock() - t0 > 3
				i = (i % #Theme.Music) + 1
			end
		end)
	end

	local function popRows(rows: { GuiObject })
		for idx, r in ipairs(rows) do
			local sc = Kit.fx(r)
			sc.Scale = 0.85
			tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, idx * 0.05)
		end
	end
	local keyRowFrames = {}
	for _, kr in ipairs(keyRows) do
		table.insert(keyRowFrames, kr.Row)
	end

	setPage = function(name: string, instant: boolean?)
		if page == name and not instant then
			return
		end
		stopListening()
		page = name
		local isKeys = name == "Keys"
		thumb.Set(if isKeys then 2 else 1, instant)
		if not instant then
			Kit.sfx("Click")
		end
		tabLabels.General.TextColor3 = if isKeys then C.TextDim else C.Text
		tabLabels.Keys.TextColor3 = if isKeys then C.Text else C.TextDim
		list.Visible = not isKeys
		keysPage.Visible = isKeys
		footerText.Text = if isKeys then "Click a key, then press the new one" else "Changes save automatically"
		resetBtn.SetText(if isKeys then "RESET KEYS" else "RESET")
		if not instant then
			popRows(if isKeys then keyRowFrames else generalRows)
		end
	end

	ctx.Register("Settings", {
		Window = win,
		OnOpen = function()
			showAll()
			popRows(if page == "Keys" then keyRowFrames else generalRows)
		end,
		OnClose = function()
			stopListening()
		end,
	})
end
