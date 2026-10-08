--[[
	AuraPreview  (StarterPlayerScripts.OverkillHUD.AuraPreview)
	Full-screen aura viewer. ViewportFrames can't draw particles, beams or lights, so the aura plays
	for real: your own avatar (a copy, in its idle animation) wears it exactly the way ShopServer puts
	it on in game, standing on a cobblestone pad on a little floating island made from the spawn
	island's own pieces (OverkillUI.AuraStage), up in the same sky.
	Screen: AURA PREVIEW title plate, aura list (left), details + buy (right), hint bar (bottom).
	The camera fits the avatar and its aura into the space between the panels on any screen shape.
	Opened from the shop with ctx.Fire("AuraPreview", itemId).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = Players.LocalPlayer
	local isTouch = ctx.IsTouch

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local ShopConfig = require(UI:WaitForChild("ShopConfig"))
	local Auras = UI:WaitForChild("Auras")
	local AvatarRig = require(script.Parent:WaitForChild("AvatarRig"))

	local ACCENT, ACCENT_DEEP = Theme.Accent.Shop[1], Theme.Accent.Shop[2]

	local ITEMS: { any } = {}
	for _, item in ipairs(ShopConfig.Items) do
		if item.Aura then
			table.insert(ITEMS, item)
		end
	end

	local function rarityOf(item: any)
		return Theme.Rarity[item.Rarity or "Common"] or Theme.Rarity.Common
	end
	local function tintOf(item: any): Color3
		return item.Tint or rarityOf(item).Color
	end

	-- what's inside an aura (for the details panel)
	local function auraStats(item: any)
		local src = Auras:FindFirstChild(item.Aura or "")
		local out = { Particles = 0, Beams = 0, Zones = 0 }
		if src then
			for _, g in ipairs(src:GetChildren()) do
				out.Zones += 1
				for _, d in ipairs(g:GetDescendants()) do
					if d:IsA("ParticleEmitter") then
						out.Particles += 1
					elseif d:IsA("Beam") then
						out.Beams += 1
					end
				end
			end
		end
		return out
	end

	---------------------------------------------------------------------------
	-- the stage: a little floating island built from the spawn island's own pieces
	-- (OverkillUI.AuraStage: scaled island + cobblestone pad + lamp, bushes, flowers, trees).
	-- It is moved high into the sky while the viewer is open, so only the sky is behind it.
	---------------------------------------------------------------------------
	local ORIGIN = Vector3.new(0, 1600, 0) -- the middle of the pad, at grass level
	local stageSrc = UI:WaitForChild("AuraStage", 10)
	local feetValue = stageSrc and stageSrc:FindFirstChild("FeetY")
	local FEET = if feetValue and feetValue:IsA("NumberValue") then feetValue.Value else 0.7
	local stage: Model? = nil

	local function getStage(): Model?
		if not stage and stageSrc then
			local m = stageSrc:Clone() :: Model
			m.Name = "OverkillAuraStage"
			m:PivotTo(CFrame.new(ORIGIN))
			-- a few petals drifting through the air, for a bit of life around the pad
			local air = Instance.new("Part")
			air.Name = "Petals"
			air.Anchored = true
			air.CanCollide = false
			air.CanQuery = false
			air.CanTouch = false
			air.Transparency = 1
			air.Size = Vector3.new(22, 1, 16)
			air.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 9, -2))
			air.Parent = m
			local petals = Instance.new("ParticleEmitter")
			petals.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			petals.Color = ColorSequence.new(Color3.fromRGB(255, 236, 244), Color3.fromRGB(255, 196, 222))
			petals.LightEmission = 0.2
			petals.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(1, 0.12) })
			petals.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.25), NumberSequenceKeypoint.new(0.85, 0.3), NumberSequenceKeypoint.new(1, 1) })
			petals.Lifetime = NumberRange.new(7, 10)
			petals.Rate = 4
			petals.Speed = NumberRange.new(0.3, 0.7)
			petals.SpreadAngle = Vector2.new(180, 180)
			petals.Acceleration = Vector3.new(0.15, -0.5, 0)
			petals.Drag = 0.4
			petals.RotSpeed = NumberRange.new(-60, 60)
			petals.Rotation = NumberRange.new(0, 360)
			petals.EmissionDirection = Enum.NormalId.Bottom
			petals.Parent = air
			stage = m
		end
		return stage
	end

	---------------------------------------------------------------------------
	-- your avatar + the aura (the same steps ShopServer uses on the real character)
	---------------------------------------------------------------------------
	local R15_MAP = {
		Head = { "Head" },
		Torso = { "UpperTorso", "LowerTorso" },
		["Left Arm"] = { "LeftUpperArm", "LeftLowerArm" },
		["Right Arm"] = { "RightUpperArm", "RightLowerArm" },
		["Left Leg"] = { "LeftUpperLeg", "LeftLowerLeg" },
		["Right Leg"] = { "RightUpperLeg", "RightLowerLeg" },
	}
	local rig: any = nil
	local idleTrack: AnimationTrack? = nil

	local function wearAura(item: any)
		if not rig then
			return
		end
		local model = rig.Model
		for _, d in ipairs(model:GetDescendants()) do
			if d:GetAttribute("OverkillAura") then
				d:Destroy()
			end
		end
		local src = item and item.Aura and Auras:FindFirstChild(item.Aura)
		if not src then
			return
		end
		local isR6 = model:FindFirstChild("Torso") ~= nil
		for _, group in ipairs(src:GetChildren()) do
			local targets = if isR6 then { group.Name } else (R15_MAP[group.Name] or {})
			for i, targetName in ipairs(targets) do
				local p = model:FindFirstChild(targetName)
				if p and p:IsA("BasePart") then
					local copy = group:Clone()
					for _, fx in ipairs(copy:GetChildren()) do
						if i == 1 or fx:IsA("ParticleEmitter") then
							if fx:IsA("ParticleEmitter") and #targets > 1 then
								fx.Rate /= #targets
							end
							fx:SetAttribute("OverkillAura", true)
							fx.Parent = p
						end
					end
					copy:Destroy()
				end
			end
		end
	end

	local function dropAvatar()
		if idleTrack then
			idleTrack:Stop(0)
			idleTrack = nil
		end
		if rig then
			rig.Model:Destroy()
			rig = nil
		end
	end

	---------------------------------------------------------------------------
	-- screen
	---------------------------------------------------------------------------
	local gui = new("ScreenGui", {
		Name = "OverkillAuraPreview",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 58,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
	local rootScale = new("UIScale", { Name = "Fit", Parent = root })

	-- layout (reference pixels, 1920 x 1080 and wider/taller)
	local SIDE = 40 -- screen edge to panel
	local LIST_W, INFO_W = 430, 440
	local ROW_H, ROW_GAP = 112, 14
	local LIST_H = 86 + #ITEMS * (ROW_H + ROW_GAP) + 12
	local INFO_H = 646
	local HEAD_Y = 58 -- title plate centre below the top bar
	local HINT_H = 58

	local function topInset(): number -- Roblox's top bar, in screen pixels
		local inset = 0
		pcall(function()
			inset = GuiService.TopbarInset.Height
		end)
		if inset <= 0 then
			inset = GuiService:GetGuiInset().Y
		end
		return inset
	end

	-- the whole screen is the spin handle (and swallows clicks, frees a locked mouse)
	local grab = new("TextButton", {
		Name = "Grab",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Modal = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = root,
	})
	-- the curtain lives on its own layer (above the preview and the windows) so the preview's panels
	-- can be switched off while the screen is dark, and the shop can open underneath it
	local fadeGui = new("ScreenGui", {
		Name = "OverkillAuraPreviewFade",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 59,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local fade = new("Frame", { Name = "Fade", BackgroundColor3 = C.Night, BorderSizePixel = 0, BackgroundTransparency = 1, Visible = false, Size = UDim2.fromScale(1, 1), Parent = fadeGui })
	local fadeSerial = 0
	local function fadeTo(alpha: number, t: number): Tween
		fadeSerial += 1
		local me = fadeSerial
		fade.Visible = true
		local tw = tween(fade, t, { BackgroundTransparency = alpha }, Enum.EasingStyle.Quad)
		if alpha >= 1 then
			tw.Completed:Connect(function()
				if me == fadeSerial then
					fade.Visible = false
				end
			end)
		end
		return tw
	end

	-- a panel in the same dress as the windows: ink outline, navy body, stripes, accent header band
	local function panel(name: string, w: number, h: number, title: string, icon: (Frame) -> ())
		local holder = new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromOffset(w, h), ZIndex = 10, Parent = root })
		local scale = Kit.fx(holder)
		local shadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.45, Position = UDim2.fromOffset(0, 12), Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = holder })
		Kit.corner(shadow, 32)
		local body = new("Frame", { Name = "Body", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = holder })
		Kit.corner(body, 32)
		Kit.stroke(body, 8, C.Ink, 0, true)
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, C.Navy700),
				ColorSequenceKeypoint.new(0.45, C.Navy800),
				ColorSequenceKeypoint.new(1, C.Navy900),
			}),
			Parent = body,
		})
		local skin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = body })
		Kit.corner(skin, 32)
		Kit.stripes(skin, C.Rim, 0.955, 10)
		local band = new("Frame", { Name = "Band", BackgroundColor3 = ACCENT, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 96), ZIndex = 10, Parent = skin })
		Kit.gradient(band, ACCENT, ACCENT_DEEP, 90, 0.74, 1)
		local vignette = new("Frame", { Name = "Vignette", BackgroundColor3 = C.Night, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.4, 0), ZIndex = 10, Parent = skin })
		Kit.gradient(vignette, C.Night, C.Night, 90, 1, 0.3)
		-- heading: icon + title + a hairline
		-- heading icon: as far in from the panel's left edge as from its top edge
		local iconHolder = new("Frame", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(22, 42), Size = UDim2.fromOffset(40, 40), ZIndex = 12, Parent = holder })
		icon(iconHolder)
		Kit.text({ Name = "Title", Text = title, TextSize = 30, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(72, 42), Size = UDim2.new(1, -94, 0, 36), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 3.5, Parent = holder })
		local line = new("Frame", { Name = "Line", BackgroundColor3 = C.Rim, BackgroundTransparency = 0.72, BorderSizePixel = 0, Position = UDim2.fromOffset(22, 76), Size = UDim2.new(1, -44, 0, 3), ZIndex = 11, Parent = holder })
		Kit.pill(line)
		local content = new("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 86), Size = UDim2.new(1, 0, 1, -86), ZIndex = 11, Parent = holder })
		return { Root = holder, Scale = scale, Content = content }
	end

	-- a small flat pill (rarity, tags)
	local function chip(parent: Instance, text: string, a: Color3, b: Color3, h: number, size: number, z: number)
		local p = Kit.plate({
			Name = "Chip",
			Parent = parent,
			Size = UDim2.new(0, 0, 0, h),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = UDim.new(1, 0),
			Stroke = 2.5,
			ZIndex = z,
			Gradient = { a, b },
		})
		Kit.padding(p, 11, 0, 11, 0)
		local label = Kit.text({ Text = text, TextSize = size, FontFace = Theme.Font.Heavy, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z + 1, Stroke = 2.2, Parent = p })
		return p, label
	end

	-- white key chip, same look as the dock's key labels
	local function keycap(parent: Instance, text: string, w: number, z: number): Frame
		local k = new("Frame", { Name = "Key", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(w, 32), ZIndex = z, Parent = parent })
		Kit.corner(k, 9)
		Kit.stroke(k, 3, C.Ink, 0, true)
		Kit.gradient(k, Color3.new(1, 1, 1), Color3.fromRGB(222, 230, 244), 90)
		Kit.text({ Text = text, TextSize = 17, FontFace = Theme.Font.Heavy, TextColor3 = C.Ink, Size = UDim2.fromScale(1, 1), ZIndex = z + 1, Stroke = false, Parent = k })
		return k
	end

	---------------------------------------------------------------------------
	-- title plate (the windows' plate, with an eye badge for the icon)
	---------------------------------------------------------------------------
	local TITLE = "AURA PREVIEW"
	-- the shared title plate (the windows' plate): the eye tile evenly inset on three sides
	local headPlate = Kit.titlePlate({
		Parent = root,
		Title = TITLE,
		TextSize = 44,
		Height = 82,
		Accent = ACCENT,
		Deep = ACCENT_DEEP,
		Position = UDim2.new(0.5, 0, 0, HEAD_Y),
		ZIndex = 20,
		Glyph = function(tile: Frame, z: number)
			Kit.eyeGlyph(tile, 42, z, C.Pink)
		end,
	})
	local head = headPlate.Plate
	local headScale = Kit.fx(head)
	local headSheen = headPlate.Sheen

	local closeApi = Kit.closeButton({ Name = "Back", Parent = root, Position = UDim2.new(1, -62, 0, HEAD_Y), Size = 68, ZIndex = 30 })

	---------------------------------------------------------------------------
	-- left: the auras
	---------------------------------------------------------------------------
	local list = panel("Auras", LIST_W, LIST_H, "AURAS", function(holder)
		local orb = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 34), ZIndex = 12, Parent = holder })
		Kit.pill(orb)
		Kit.stroke(orb, 3.5, C.Ink, 0, true)
		Kit.gradient(orb, Kit.lighten(C.Pink, 0.3), C.PinkDeep, 90)
		local core = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.5, 0.5), ZIndex = 13, Parent = orb })
		Kit.pill(core)
		Kit.stroke(core, 2.5, Color3.new(1, 1, 1), 0.2)
	end)
	-- "1 / 3" counter on the heading, like the party size chip
	local countChip, countLabel = chip(list.Root, ("1 / %d"):format(#ITEMS), C.Navy500, C.Navy700, 30, 15, 12)
	countChip.AnchorPoint = Vector2.new(1, 0.5)
	countChip.Position = UDim2.new(1, -22, 0, 42) -- as far in as the heading icon on the left

	local rows: { any } = {}
	for i, item in ipairs(ITEMS) do
		local r = rarityOf(item)
		local tint = tintOf(item)
		local btn = new("TextButton", {
			Name = item.Id,
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(20, 6 + (i - 1) * (ROW_H + ROW_GAP)),
			Size = UDim2.new(1, -40, 0, ROW_H),
			ZIndex = 12,
			Parent = list.Content,
		})
		local face = new("Frame", { Name = "Face", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 12, Parent = btn })
		Kit.corner(face, 26)
		local faceStroke = Kit.stroke(face, 4, C.Ink, 0, true)
		local grad = Kit.gradient(face, C.Navy600, C.Navy800, 90)
		local sc = Kit.fx(face)
		-- the aura's colour as a glowing orb with a rarity ring. The whole icon is rings on the
		-- row's left end (Kit.edgeStrokes), from the outside in: the gap in the row's colours, the
		-- rarity ring, the row's colour again, the orb's ink outline, the orb, and the white ring
		-- round its core. Every ring is exactly as wide all the way round, and the gap to the row's
		-- left, top and bottom edges is the same.
		local ring = Kit.slot({ Parent = face, Side = "Left", Width = ROW_H, Name = "Ring", ZIndex = 13 })
		ring.BackgroundTransparency = 0
		Kit.pill(ring)
		-- the orb's shading spans the orb (y 24..88 of the 112 end), flat beyond it
		local o0, o1 = (ROW_H / 2 - 32) / ROW_H, (ROW_H / 2 + 32) / ROW_H
		local orbSeq = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(tint, 0.35)),
			ColorSequenceKeypoint.new(o0, Kit.lighten(tint, 0.35)),
			ColorSequenceKeypoint.new(o1, Kit.darken(tint, 0.3)),
			ColorSequenceKeypoint.new(1, Kit.darken(tint, 0.3)),
		})
		Kit.paint(ring, orbSeq)
		local g, ink = 16, 4 * 1.35
		local orbEdge = g + 8 -- the orb (64) inside the rarity ring (80)
		local coreR = 32 * 0.54 -- the white ring round the orb's core
		local _, ringGrads = Kit.edgeStrokes(ring, UDim.new(1, 0), {
			{ ROW_H / 2 - coreR, Color3.new(1, 1, 1), 0.25 },
			{ ROW_H / 2 - coreR - 3, orbSeq },
			{ orbEdge + ink / 2, C.Ink },
			{ orbEdge - ink / 2, { C.Navy600, C.Navy800, 90 } },
			{ g, r.Color },
			{ g - 3, { C.Navy600, C.Navy800, 90 } },
			Kit.seams({ { Paint = { C.Navy600, C.Navy800, 90 } } })[1], -- no trace of the rings beside the name
		}, 14)
		local gapGrads = { ringGrads[4], ringGrads[6], ringGrads[7] }
		Kit.outlineOnTop(face, 17)
		-- name + rarity + status
		Kit.text({ Name = "Name", Text = item.Name, TextSize = 27, Position = UDim2.fromOffset(110, 16), Size = UDim2.new(1, -170, 0, 32), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13, Stroke = 3.2, Parent = face })
		local sub = new("Frame", { Name = "Sub", BackgroundTransparency = 1, Position = UDim2.fromOffset(110, 58), Size = UDim2.new(1, -170, 0, 30), ZIndex = 13, Parent = face })
		Kit.list(sub, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local rc = chip(sub, r.Name, Kit.lighten(r.Color, 0.1), r.Deep, 22, 11, 14)
		rc.LayoutOrder = 1
		local status = new("Frame", { Name = "Status", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 14, Parent = sub })
		Kit.list(status, Enum.FillDirection.Horizontal, 5, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local statusIcon = Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, ZIndex = 15, Parent = status })
		local statusText = Kit.text({ Text = "", TextSize = 17, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 15, Stroke = 2.6, Parent = status })
		-- number key (1, 2, 3...) on the right
		if not isTouch and i <= 9 then
			local k = keycap(face, tostring(i), 34, 14)
			k.AnchorPoint = Vector2.new(1, 0.5)
			k.Position = UDim2.new(1, -18, 0.5, 0)
		end
		local row = { Item = item, Button = btn, Face = face, Grad = grad, GapGrads = gapGrads, Stroke = faceStroke, Scale = sc, StatusIcon = statusIcon, StatusText = statusText, Hover = false }
		btn.MouseEnter:Connect(function()
			row.Hover = true
			tween(sc, 0.2, { Scale = 1.03 }, Enum.EasingStyle.Back)
		end)
		btn.MouseLeave:Connect(function()
			row.Hover = false
			tween(sc, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		btn.Activated:Connect(function()
			ctx.Fire("AuraPreviewPick", i)
		end)
		rows[i] = row
	end

	---------------------------------------------------------------------------
	-- right: details + buy
	---------------------------------------------------------------------------
	local info = panel("Details", INFO_W, INFO_H, "DETAILS", function(holder)
		local e = Kit.eyeGlyph(holder, 38, 12, C.Pink)
		e.Rotation = -6
	end)
	local ic = info.Content
	local PADX = 26
	local infoTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 150), ZIndex = 11, Parent = ic })
	local topScale = Kit.fx(infoTop)
	local rarityHolder = new("Frame", { Name = "RarityHolder", BackgroundTransparency = 1, Position = UDim2.fromOffset(PADX, 4), Size = UDim2.fromOffset(300, 30), ZIndex = 12, Parent = infoTop })
	local rarityChip, rarityLabel = chip(rarityHolder, "EPIC", C.Purple, C.PurpleDeep, 28, 14, 13)
	local rarityGrad = rarityChip:FindFirstChildOfClass("UIGradient")
	local nameText = Kit.text({ Name = "AuraName", Text = "", TextSize = 44, Position = UDim2.fromOffset(PADX, 40), Size = UDim2.new(1, -PADX * 2, 0, 52), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 5, Parent = infoTop })
	local descText = Kit.text({
		Name = "Desc",
		Text = "",
		TextSize = 19,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(PADX, 98),
		Size = UDim2.new(1, -PADX * 2, 0, 50),
		ZIndex = 12,
		Stroke = 2.2,
		Parent = infoTop,
	})
	local function divider(y: number)
		local d = new("Frame", { Name = "Divider", BackgroundColor3 = C.Rim, BackgroundTransparency = 0.72, BorderSizePixel = 0, Position = UDim2.fromOffset(PADX, y), Size = UDim2.new(1, -PADX * 2, 0, 3), ZIndex = 11, Parent = ic })
		Kit.pill(d)
	end
	local function label(text: string, y: number): TextLabel
		return Kit.text({ Name = "Label", Text = text, TextSize = 15, FontFace = Theme.Font.Heavy, TextColor3 = C.TextDim, Position = UDim2.fromOffset(PADX, y), Size = UDim2.new(1, -PADX * 2, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 2, Parent = ic })
	end
	divider(160)
	label("INSIDE THIS AURA", 176)
	-- three stat tiles
	local tileRow = new("Frame", { Name = "Tiles", BackgroundTransparency = 1, Position = UDim2.fromOffset(PADX, 204), Size = UDim2.new(1, -PADX * 2, 0, 98), ZIndex = 11, Parent = ic })
	Kit.list(tileRow, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local tiles = {}
	local TILE_W = math.floor((INFO_W - PADX * 2 - 20) / 3)
	for i, t in ipairs({ { "Particles", "PARTICLE FX" }, { "Beams", "ENERGY BEAMS" }, { "Zones", "BODY ZONES" } }) do
		local tile = Kit.plate({ Name = t[1], Parent = tileRow, Size = UDim2.fromOffset(TILE_W, 98), LayoutOrder = i, Radius = 20, Stroke = 3.5, ZIndex = 12, Gradient = { C.Navy600, C.Navy800 } })
		local num = Kit.text({ Name = "Value", Text = "0", TextSize = 36, Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 42), ZIndex = 13, Stroke = 4, Parent = tile })
		Kit.text({ Name = "Caption", Text = t[2], TextSize = 13, FontFace = Theme.Font.Heavy, TextColor3 = C.TextDim, Position = UDim2.fromOffset(6, 58), Size = UDim2.new(1, -12, 0, 30), TextWrapped = true, ZIndex = 13, Stroke = 1.8, Parent = tile })
		tiles[t[1]] = { Tile = tile, Value = num, Scale = Kit.fx(tile) }
	end
	divider(318)
	local priceLabel = label("PRICE", 334)
	local valueRow = new("Frame", { Name = "Value", BackgroundTransparency = 1, Position = UDim2.fromOffset(PADX - 2, 358), Size = UDim2.new(1, -PADX * 2, 0, 50), ZIndex = 12, Parent = ic })
	Kit.list(valueRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local valueIcon = Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(46, 46), LayoutOrder = 1, ZIndex = 13, Parent = valueRow })
	local valueText = Kit.text({ Text = "", TextSize = 40, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 13, Stroke = 4, Parent = valueRow })
	local subText = Kit.text({ Name = "Sub", Text = "", TextSize = 16, FontFace = Theme.Font.Heavy, TextColor3 = C.TextSoft, Position = UDim2.fromOffset(PADX, 412), Size = UDim2.new(1, -PADX * 2, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 2, Parent = ic })
	local action = Kit.button({
		Name = "Action",
		Parent = ic,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.new(1, -PADX * 2, 0, 82),
		Radius = 26,
		Depth = 6,
		Stroke = 4,
		Color = C.Green,
		Deep = C.GreenDeep,
		Text = "BUY",
		TextSize = 34,
		ZIndex = 14,
		Shine = true,
		OnClick = function()
			ctx.Fire("AuraPreviewAct")
		end,
	})

	---------------------------------------------------------------------------
	-- bottom: how to use it
	---------------------------------------------------------------------------
	local hint = Kit.plate({
		Name = "Hint",
		Parent = root,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -34),
		Size = UDim2.new(0, 0, 0, HINT_H),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 4.5,
		ZIndex = 12,
		Gradient = { C.Navy700, C.Navy900 },
	})
	local hintScale = Kit.fx(hint)
	Kit.padding(hint, 22, 0, 22, 0)
	Kit.list(hint, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local function hintText(t: string, order: number)
		Kit.text({ Text = t, TextSize = 18, FontFace = Theme.Font.Heavy, TextColor3 = C.TextSoft, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, ZIndex = 13, Stroke = 2.2, Parent = hint })
	end
	local function hintDot(order: number)
		local d = new("Frame", { BackgroundColor3 = C.Rim, BackgroundTransparency = 0.4, Size = UDim2.fromOffset(6, 6), LayoutOrder = order, ZIndex = 13, Parent = hint })
		Kit.pill(d)
	end
	hintText("DRAG TO SPIN", 1)
	if not isTouch then
		hintDot(2)
		keycap(hint, "A", 32, 13).LayoutOrder = 3
		keycap(hint, "D", 32, 13).LayoutOrder = 4
		hintText("SWITCH", 5)
		hintDot(6)
		keycap(hint, "BACKSPACE", 104, 13).LayoutOrder = 7
		hintText("BACK", 8)
	end

	-- positions (the top pieces sit under Roblox's top bar)
	local function layout()
		local s = math.max(rootScale.Scale, 0.1)
		local vp = workspace.CurrentCamera.ViewportSize
		local refH = math.max(vp.Y / s, 600)
		local inset = topInset() / s
		local top, bottom = inset + HEAD_Y + 44, refH - HINT_H - 34
		local midY = (top + bottom) / 2
		head.Position = UDim2.new(0.5, 0, 0, inset + HEAD_Y)
		closeApi.Button.Position = UDim2.new(1, -62, 0, inset + HEAD_Y)
		list.Root.AnchorPoint = Vector2.new(0, 0.5)
		list.Root.Position = UDim2.new(0, SIDE, 0, midY)
		info.Root.AnchorPoint = Vector2.new(1, 0.5)
		info.Root.Position = UDim2.new(1, -SIDE, 0, midY)
	end
	local function rescale(sc: number)
		sc = math.max(sc or 1, 0.1)
		rootScale.Scale = sc
		root.Size = UDim2.fromScale(1 / sc, 1 / sc)
		layout()
	end
	ctx.On("Scale", rescale)
	rescale(ctx.Scale)

	---------------------------------------------------------------------------
	-- state
	---------------------------------------------------------------------------
	local open = false
	local busyUntil = 0
	local index = 1
	local yaw, spinVel, lastTouch = -0.45, 0, 0
	local dragging, lastX = false, 0
	local saved: any = nil
	local controls: any = nil

	local function current(): any
		return ITEMS[index]
	end

	local function refreshRows()
		local st = ctx.ShopState
		for i, row in ipairs(rows) do
			local item = row.Item
			local owned = st and st.Owned and st.Owned[item.Id] == true
			local equipped = st and st.Equipped == item.Id
			if equipped then
				row.StatusIcon.Image = Theme.Icon.Check
				row.StatusText.Text = "EQUIPPED"
				row.StatusText.TextColor3 = C.Gold
			elseif owned then
				row.StatusIcon.Image = Theme.Icon.Check
				row.StatusText.Text = "OWNED"
				row.StatusText.TextColor3 = C.Text
			else
				row.StatusIcon.Image = Theme.Icon.Coin
				row.StatusText.Text = Theme.Comma(item.Price or 0)
				row.StatusText.TextColor3 = C.Gold
			end
			local on = i == index
			row.Grad.Color = if on then ColorSequence.new(Kit.lighten(ACCENT, 0.08), ACCENT_DEEP) else ColorSequence.new(C.Navy600, C.Navy800)
			for _, gg in ipairs(row.GapGrads or {}) do
				gg.Color = row.Grad.Color -- the gaps in the orb icon are the row's own colour
			end
			row.Stroke.Color = if on then Color3.new(1, 1, 1) else C.Ink
		end
	end

	local function refreshInfo()
		local item = current()
		if not item then
			return
		end
		local st = ctx.ShopState
		local owned = st and st.Owned and st.Owned[item.Id] == true
		local equipped = st and st.Equipped == item.Id
		local coins = ctx.Stats.Coins or 0
		if equipped then
			priceLabel.Text = "STATUS"
			valueIcon.Image = Theme.Icon.Check
			valueText.Text = "EQUIPPED"
			valueText.TextColor3 = C.Gold
			subText.Text = "You're wearing it right now."
			subText.TextColor3 = C.TextSoft
			action.SetText("UNEQUIP")
			action.SetColor(C.Navy500, C.Navy700)
		elseif owned then
			priceLabel.Text = "STATUS"
			valueIcon.Image = Theme.Icon.Check
			valueText.Text = "OWNED"
			valueText.TextColor3 = C.Text
			subText.Text = "Yours forever - put it on any time."
			subText.TextColor3 = C.TextSoft
			action.SetText("EQUIP")
			action.SetColor(C.Blue, C.BlueDeep)
		else
			local price = item.Price or 0
			local short = price - coins
			priceLabel.Text = "PRICE"
			valueIcon.Image = Theme.Icon.Coin
			valueText.Text = Theme.Comma(price)
			valueText.TextColor3 = if short > 0 then Color3.fromRGB(255, 132, 140) else C.Gold
			if short > 0 then
				subText.Text = ("You have %s  -  %s more to go"):format(Theme.Comma(coins), Theme.Comma(short))
				subText.TextColor3 = Color3.fromRGB(255, 160, 166)
			else
				subText.Text = ("You have %s coins"):format(Theme.Comma(coins))
				subText.TextColor3 = C.TextSoft
			end
			action.SetText("BUY")
			action.SetColor(C.Green, C.GreenDeep)
		end
		refreshRows()
	end

	local function showItem(i: number, instant: boolean?)
		index = ((i - 1) % #ITEMS) + 1
		local item = current()
		local r = rarityOf(item)
		local tint = tintOf(item)
		rarityLabel.Text = r.Name
		if rarityGrad then
			rarityGrad.Color = ColorSequence.new(Kit.lighten(r.Color, 0.1), r.Deep)
		end
		local name = string.upper(item.Name)
		nameText.Text = name
		nameText.TextSize = math.min(44, math.floor(44 * (INFO_W - PADX * 2) / math.max(Kit.textWidth(name, 44), 1)))
		nameText.TextColor3 = Kit.lighten(tint, 0.55)
		descText.Text = item.Desc or ""
		countLabel.Text = ("%d / %d"):format(index, #ITEMS)
		local stats = auraStats(item)
		for key, t in pairs(tiles) do
			t.Value.Text = tostring(stats[key] or 0)
			t.Value.TextColor3 = Kit.lighten(tint, 0.45)
			if not instant then
				t.Scale.Scale = 0.86
				tween(t.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
		wearAura(item)
		refreshInfo()
		if not instant then
			topScale.Scale = 0.94
			tween(topScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			local row = rows[index]
			if row then
				row.Scale.Scale = 0.95
				tween(row.Scale, 0.3, { Scale = if row.Hover then 1.03 else 1 }, Enum.EasingStyle.Back)
			end
			Kit.sfx("Equip")
		end
	end

	---------------------------------------------------------------------------
	-- camera: fits the aura + pad into the open space between the panels
	---------------------------------------------------------------------------
	local FOV = 30
	local PITCH = math.rad(14)
	local camOn = false
	local camDolly = new("NumberValue", { Value = 1 })
	local function frameCamera()
		if not rig or not camOn then
			return
		end
		local cam = workspace.CurrentCamera
		local vp = cam.ViewportSize
		if vp.X < 2 or vp.Y < 2 then
			return
		end
		local s = math.max(rootScale.Scale, 0.1)
		local refW, refH = vp.X / s, vp.Y / s
		local inset = topInset() / s
		-- the free space, as fractions of the screen
		local L = (SIDE + LIST_W + 40) / refW
		local R = 1 - (SIDE + INFO_W + 40) / refW
		local T = (inset + HEAD_Y + 44 + 26) / refH
		local B = 1 - (34 + HINT_H + 26) / refH
		local sx, sy = (L + R) / 2, (T + B) / 2
		local fw, fh = math.max(R - L, 0.1), math.max(B - T, 0.1)
		-- what has to fit: the aura (a bit above the head) down to the glow line in front of the pad
		local h = rig.Height
		local top = ORIGIN.Y + FEET + h * 1.2 -- flames and sparks above the head stay in
		local bottom = ORIGIN.Y + FEET - 1.2 -- the front of the cobble circle under the feet
		local boxH = top - bottom
		local boxW = rig.Width + 3.2
		local tanV = math.tan(math.rad(FOV / 2))
		local aspect = vp.X / vp.Y
		-- the avatar fills ~70% of the open space: room for the pad and a little island around it
		local d = math.max(boxH / (2 * tanV * fh * 0.68), boxW / (2 * tanV * aspect * fw * 0.8)) * camDolly.Value
		local look = Vector3.new(0, -math.sin(PITCH), -math.cos(PITCH))
		local up = Vector3.new(0, math.cos(PITCH), -math.sin(PITCH))
		local right = Vector3.new(1, 0, 0)
		local dx = (sx - 0.5) * 2 * d * tanV * aspect
		local dy = (0.5 - sy) * 2 * d * tanV
		local centre = Vector3.new(ORIGIN.X, (top + bottom) / 2, ORIGIN.Z)
		local pos = centre - look * d - right * dx - up * dy
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = FOV
		cam.CFrame = CFrame.lookAt(pos, pos + look)
	end
	camDolly.Changed:Connect(frameCamera)

	local function step(dt: number)
		if not rig then
			return
		end
		if not dragging then
			if os.clock() - lastTouch > 1.6 then
				spinVel += (0.3 - spinVel) * math.min(dt * 1.5, 1) -- ease back into the slow turntable
			else
				spinVel *= math.max(0, 1 - dt * 3) -- a flick keeps spinning, then settles
			end
			yaw += spinVel * dt
		end
		AvatarRig.place(rig, ORIGIN + Vector3.new(0, FEET, 0), math.pi + yaw)
		if camOn and workspace.CurrentCamera.CameraType ~= Enum.CameraType.Scriptable then
			frameCamera()
		end
	end

	grab.InputBegan:Connect(function(input)
		if not open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
			spinVel = 0
			lastTouch = os.clock()
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - lastX
			lastX = input.Position.X
			local dt = math.max(os.clock() - lastTouch, 1 / 240)
			lastTouch = os.clock()
			yaw += dx * 0.011
			spinVel = math.clamp(dx * 0.011 / dt, -6, 6)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				lastTouch = os.clock()
			end
		end
	end)

	---------------------------------------------------------------------------
	-- open / close
	---------------------------------------------------------------------------
	local function setControls(on: boolean)
		if not controls then
			pcall(function()
				local ps = player:FindFirstChild("PlayerScripts")
				local pm = ps and ps:FindFirstChild("PlayerModule")
				if pm then
					controls = require(pm :: ModuleScript):GetControls()
				end
			end)
		end
		if controls then
			pcall(function()
				if on then
					controls:Enable()
				else
					controls:Disable()
				end
			end)
		end
	end

	local NUMBER_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine }
	local function bindKeys(on: boolean)
		if on then
			ContextActionService:BindActionAtPriority("OverkillAuraPreviewNav", function(_, st, input)
				if st == Enum.UserInputState.Begin then
					local k = input.KeyCode
					local back = k == Enum.KeyCode.A or k == Enum.KeyCode.W or k == Enum.KeyCode.Left or k == Enum.KeyCode.Up or k == Enum.KeyCode.ButtonL1
					ctx.Fire("AuraPreviewStep", if back then -1 else 1)
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
			local keys = {}
			for i = 1, math.min(#ITEMS, 9) do
				keys[i] = NUMBER_KEYS[i]
			end
			ContextActionService:BindActionAtPriority("OverkillAuraPreviewPick", function(_, st, input)
				if st == Enum.UserInputState.Begin then
					for i, k in ipairs(keys) do
						if input.KeyCode == k then
							ctx.Fire("AuraPreviewPick", i)
						end
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, table.unpack(keys))
			ContextActionService:BindActionAtPriority("OverkillAuraPreviewBack", function(_, st)
				if st == Enum.UserInputState.Begin then
					ctx.Fire("AuraPreviewClose")
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
		else
			ContextActionService:UnbindAction("OverkillAuraPreviewNav")
			ContextActionService:UnbindAction("OverkillAuraPreviewPick")
			ContextActionService:UnbindAction("OverkillAuraPreviewBack")
		end
	end

	local CORE = { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Chat }
	local coreWas: { [any]: boolean } = {}
	local function setCore(hide: boolean)
		for _, t in ipairs(CORE) do
			pcall(function()
				if hide then
					coreWas[t] = StarterGui:GetCoreGuiEnabled(t)
					StarterGui:SetCoreGuiEnabled(t, false)
				elseif coreWas[t] ~= nil then
					StarterGui:SetCoreGuiEnabled(t, coreWas[t])
					coreWas[t] = nil
				end
			end)
		end
	end

	-- put the world camera, controls and lighting back exactly as they were
	local function restoreWorld()
		RunService:UnbindFromRenderStep("OverkillAuraPreview")
		bindKeys(false)
		camOn = false
		dropAvatar()
		if stage then
			stage.Parent = nil
		end
		local cam = workspace.CurrentCamera
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		cam.CameraType = if saved then saved.Type else Enum.CameraType.Custom
		if hum then
			cam.CameraSubject = hum
		end
		if saved then
			cam.FieldOfView = saved.Fov
			if saved.Type == Enum.CameraType.Custom and saved.CFrame then
				cam.CFrame = saved.CFrame
			end
			for fx, was in pairs(saved.Effects) do
				if fx.Parent then
					fx.Enabled = was
				end
			end
		end
		saved = nil
		setControls(true)
		setCore(false)
	end

	local function close(reason: string?)
		if not open then
			return
		end
		open = false
		dragging = false
		local item = current()
		if reason == "overlay" then
			-- something more important (a match) took the screen: step aside at once
			restoreWorld()
			gui.Enabled = false
			fadeSerial += 1
			fade.BackgroundTransparency = 1
			fade.Visible = false
			return
		end
		fadeTo(0, 0.16).Completed:Wait()
		-- everything swaps while the screen is dark: the preview's panels go, the world camera comes
		-- back, and the shop opens in the same frame the overlay clears, so the dock / hotbar / menus
		-- never flash back in between
		restoreWorld()
		gui.Enabled = false
		local back = reason ~= "quiet"
		if ctx.Overlay == "AuraPreview" then
			ctx.SetOverlay(nil, if back then "Shop" else nil, "Auras")
		elseif back then
			ctx.Open("Shop", "Auras")
		end
		if back then
			-- back on the aura shelf (and straight into the purchase, if that's why we left)
			if reason == "buy" and item then
				task.delay(0.3, function()
					ctx.Fire("ShopBuyId", item.Id)
				end)
			end
		end
		task.wait(0.08)
		fadeTo(1, 0.26)
	end

	local function openPreview(id: string?)
		if open or #ITEMS == 0 or os.clock() < busyUntil then
			return
		end
		if ctx.Overlay ~= nil or player:GetAttribute("QuestUIOpen") then
			return
		end
		local start = 1
		for i, item in ipairs(ITEMS) do
			if item.Id == id then
				start = i
			end
		end
		busyUntil = os.clock() + 1
		open = true
		fade.BackgroundTransparency = 1
		fadeTo(0, 0.28)
		task.delay(0.28, function()
			-- the panels appear only once the screen is dark (never over the shop)
			if open then
				gui.Enabled = true
			end
		end)
		ctx.Close()
		ctx.SetOverlay("AuraPreview")
		task.wait(0.42) -- the shop's camera easing finishes under the fade
		if not open then
			return
		end
		local cam = workspace.CurrentCamera
		saved = { Type = cam.CameraType, Fov = cam.FieldOfView, CFrame = cam.CFrame, Effects = {} }
		for _, fx in ipairs(Lighting:GetChildren()) do
			if fx:IsA("DepthOfFieldEffect") or fx:IsA("BlurEffect") then
				saved.Effects[fx] = fx.Enabled
				fx.Enabled = false
			end
		end
		for _, fx in ipairs(cam:GetChildren()) do
			if fx:IsA("DepthOfFieldEffect") or fx:IsA("BlurEffect") then
				saved.Effects[fx] = fx.Enabled
				fx.Enabled = false
			end
		end
		setControls(false)
		setCore(true)
		layout()
		local studio = getStage()
		if not studio then
			open = true
			close("back")
			return
		end
		studio.Parent = workspace
		dropAvatar()
		rig = AvatarRig.clone(player.Character)
		if not rig then
			-- no character yet (respawning): nothing to dress up, go back quietly
			open = true
			close("back")
			return
		end
		rig.Model.Parent = studio
		yaw, spinVel, lastTouch = -0.45, 0, os.clock()
		AvatarRig.place(rig, ORIGIN + Vector3.new(0, FEET, 0), math.pi + yaw)
		idleTrack = AvatarRig.playIdle(rig)
		showItem(start, true)
		camOn = true
		camDolly.Value = 1.12
		frameCamera()
		RunService:BindToRenderStep("OverkillAuraPreview", Enum.RenderPriority.Camera.Value + 1, step)
		bindKeys(true)
		-- reveal: dolly in, panels slide in from their sides, the plate drops in
		tween(camDolly, 0.9, { Value = 1 }, Enum.EasingStyle.Quint)
		gui.Enabled = true
		fadeTo(1, 0.5)
		for k, p in ipairs({ list, info }) do
			p.Scale.Scale = 0.86
			tween(p.Scale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05 * k)
		end
		headScale.Scale = 0.7
		tween(headScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		hintScale.Scale = 0.8
		tween(hintScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.12)
		task.delay(0.6, function()
			Kit.playShine(headSheen)
		end)
		Kit.sfx("Open")
	end

	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		if open then
			layout()
			frameCamera()
		end
	end)
	ctx.On("Scale", function()
		if open then
			frameCamera()
		end
	end)

	ctx.On("AuraPreview", function(id: string?)
		openPreview(id)
	end)
	ctx.On("AuraPreviewStep", function(dir: number)
		if open and rig then
			showItem(index + dir)
		end
	end)
	ctx.On("AuraPreviewPick", function(i: number)
		if open and rig and i ~= index and ITEMS[i] then
			showItem(i)
		end
	end)
	ctx.On("AuraPreviewClose", function()
		close("back")
	end)
	closeApi.Button.Activated:Connect(function()
		close("back")
	end)
	ctx.On("AuraPreviewAct", function()
		if not open then
			return
		end
		local item = current()
		local st = ctx.ShopState
		local owned = st and st.Owned and st.Owned[item.Id] == true
		if owned then
			-- equip / unequip right here; the shop's ShopState push refreshes the panel
			action.SetText("...")
			ctx.Fire("ShopBuyId", item.Id)
		else
			close("buy") -- buying goes through the shop's confirm dialog
		end
	end)
	ctx.On("ShopState", function()
		if open then
			refreshInfo()
		end
	end)
	ctx.On("Coins", function()
		if open then
			refreshInfo()
		end
	end)
	ctx.On("OverlayChanged", function(name: string?)
		if open and name ~= "AuraPreview" and name ~= nil then
			close("overlay")
		end
	end)
	player.CharacterRemoving:Connect(function()
		if open then
			close("quiet")
		end
	end)
end
