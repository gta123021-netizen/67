--[[
	Backpack  (StarterPlayerScripts.OverkillHUD.Backpack)
	Hotbar (1-5) + the BAG window. Rebuilt from the Custom Inventory pack you added:
	same features (hotbar keys, backpack grid, search, drag to swap / store, tool tips,
	"amount" attribute, disabled tools) in the Overkill style.

	Tool attributes you can set:
	  amount  (number)  -> shows "x3" on the slot

	(The Ground Smash - jump + M1 - is part of the basic moveset: it has no slot of its own.)
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player
	local SLOTS = Theme.HotbarSlots

	local hot: { [number]: Tool? } = {}
	local bagList: { Tool } = {}
	local memory: { [string]: number } = {} -- tool name -> hotbar slot (-1 = keep in bag)
	local tracked: { [Tool]: { RBXScriptConnection } } = {}
	local character: Model? = nil
	local humanoid: Humanoid? = nil
	local backpack: Instance? = nil
	local bagOpen = false
	local hidden = false
	local render: () -> ()

	---------------------------------------------------------------------------
	-- slot widget
	---------------------------------------------------------------------------
	local function makeSlot(parent: Instance, size: number, order: number)
		local btn = new("TextButton", {
			Name = "Slot",
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(size, size + 12),
			LayoutOrder = order,
			ZIndex = 12,
			Parent = parent,
		})
		local body = new("Frame", {
			Name = "Body",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			ZIndex = 12,
			Parent = btn,
		})
		local sc = Kit.fx(body)
		local glow = new("Frame", {
			Name = "Glow",
			BackgroundColor3 = C.Gold,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 18, 1, 18),
			Visible = false,
			ZIndex = 11,
			Parent = body,
		})
		Kit.corner(glow, 30)
		Kit.gradient(glow, C.Gold, C.GoldDeep, 90, 0.45, 0.7)
		local plate = Kit.plate({
			Name = "Plate",
			Parent = body,
			Size = UDim2.fromScale(1, 1),
			Radius = 22,
			Stroke = 4,
			ZIndex = 12,
			Gradient = { C.Navy600, C.Navy800 },
		})
		local grad = plate:FindFirstChildOfClass("UIGradient")
		local stroke = plate:FindFirstChildOfClass("UIStroke") :: UIStroke
		local shimmer = Kit.shimmer(stroke, C.Gold, C.GoldDeep)
		shimmer.Enabled = false
		Kit.bevel(plate, 18, 3, 13)
		local rim = new("Frame", { Name = "Rim", BackgroundTransparency = 1, Position = UDim2.fromOffset(5, 5), Size = UDim2.new(1, -10, 1, -10), ZIndex = 12, Parent = plate })
		Kit.corner(rim, 17)
		local rimStroke = Kit.stroke(rim, 2, C.Rim, 0.6, true)
		rimStroke.Enabled = false -- flat slots: no inner line
		local icon = Kit.image({
			Name = "ToolIcon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.66, 0.66), -- clear of the key number on the corner
			ZIndex = 14,
			Parent = plate,
		})
		local nameLbl = Kit.text({
			Name = "ToolName",
			Text = "",
			TextSize = if size > 90 then 18 else 16,
			TextWrapped = true,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.56),
			Size = UDim2.new(1, -16, 1, -34),
			ZIndex = 14,
			Stroke = 2.8,
			Parent = plate,
		})
		local num = Kit.plate({
			Name = "Number",
			Parent = body,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, -8), -- centred on the top edge: clear of the icon and the next slot
			Size = if size > 100 then UDim2.fromOffset(32, 32) else UDim2.fromOffset(28, 28),
			Radius = UDim.new(1, 0),
			Stroke = 3,
			ZIndex = 16,
			Gradient = { C.Navy700, C.Night },
		})
		local numGrad = num:FindFirstChildOfClass("UIGradient")
		local numText = Kit.text({ Text = "", TextSize = if size > 100 then 22 else 18, ZIndex = 17, Stroke = 2.5, Parent = num })
		local amount = Kit.text({
			Name = "Amount",
			Text = "",
			TextSize = 20,
			TextColor3 = C.Gold,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -8, 1, -4),
			Size = UDim2.fromOffset(60, 24),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 16,
			Stroke = 3,
			Parent = plate,
		})
		return {
			Button = btn,
			Body = body,
			Scale = sc,
			Glow = glow,
			Plate = plate,
			Grad = grad,
			Stroke = stroke,
			Shimmer = shimmer,
			RimStroke = rimStroke,
			Icon = icon,
			Name = nameLbl,
			Num = num,
			NumGrad = numGrad,
			NumText = numText,
			Amount = amount,
			Tool = nil :: Tool?,
			Equipped = false,
			Size = size,
		}
	end

	local function paint(s: any, tool: Tool?, index: number?)
		local equipped = tool ~= nil and character ~= nil and tool.Parent == character
		s.Tool = tool
		s.Num.Visible = index ~= nil
		if index then
			s.NumText.Text = tostring(index)
		end
		if tool then
			local tex = tool.TextureId
			s.Icon.Image = tex
			s.Icon.Visible = tex ~= ""
			s.Name.Text = tool.Name
			s.Name.Visible = tex == ""
			local amt = tonumber(tool:GetAttribute("amount")) or 1
			s.Amount.Text = if amt > 1 then "x" .. Theme.Comma(amt) else ""
			local enabled = tool.Enabled
			s.Icon.ImageTransparency = if enabled then 0 else 0.55
			s.Name.TextTransparency = if enabled then 0 else 0.5
			s.Plate.BackgroundTransparency = 0
			s.RimStroke.Transparency = 0.6
		else
			s.Icon.Visible = false
			s.Name.Text = ""
			s.Amount.Text = ""
			s.Plate.BackgroundTransparency = 0.2
			s.RimStroke.Transparency = 0.85
		end
		if equipped ~= s.Equipped then
			s.Equipped = equipped
			s.Glow.Visible = equipped
			s.Stroke.Color = if equipped then Color3.new(1, 1, 1) else C.Ink
			s.Shimmer.Enabled = equipped
			s.Stroke.Thickness = if equipped then 5 else 4
			s.Grad.Color = if equipped
				then ColorSequence.new(C.Navy500, C.Navy700)
				else ColorSequence.new(C.Navy600, C.Navy800)
			s.NumGrad.Color = if equipped then ColorSequence.new(C.Gold, C.GoldDeep) else ColorSequence.new(C.Navy700, C.Night)
			tween(s.Body, 0.3, { Position = UDim2.new(0.5, 0, 1, if equipped then -10 else 0) }, Enum.EasingStyle.Back)
			if equipped then
				s.Scale.Scale = 1.2
				tween(s.Scale, 0.35, { Scale = 1.08 }, Enum.EasingStyle.Back)
				Kit.wiggle(s.Icon.Visible and s.Icon or s.Name, 0.8)
			else
				tween(s.Scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end

	---------------------------------------------------------------------------
	-- hotbar
	---------------------------------------------------------------------------
	local hotbar = new("Frame", {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(0, 124),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = ctx.Root,
	})
	Kit.list(hotbar, Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
	local hotSlots = {}
	for i = 1, SLOTS do
		hotSlots[i] = makeSlot(hotbar, 106, i)
		hotSlots[i].Button.Name = "Slot" .. i
	end

	-- name of the equipped item, floating above the hotbar
	local equippedTag = Kit.plate({
		Name = "EquippedName",
		Parent = ctx.Root,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -164),
		Size = UDim2.fromOffset(0, 44),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 3.5,
		ZIndex = 12,
		Gradient = { C.Navy700, C.Night },
	})
	equippedTag.Visible = false
	Kit.padding(equippedTag, 22, 0, 22, 0)
	local equippedText = Kit.text({ Text = "", TextSize = 24, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 13, Stroke = 3.2, Parent = equippedTag })
	local equippedScale = Kit.fx(equippedTag)
	local lastEquipped: Tool? = nil
	local function showEquipped(tool: Tool?)
		if tool == lastEquipped then
			return
		end
		lastEquipped = tool
		if tool then
			equippedText.Text = tool.Name
			equippedTag.Visible = true
			equippedScale.Scale = 0.6
			tween(equippedScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			local token = tool
			task.delay(2.2, function()
				if lastEquipped == token then
					tween(equippedScale, 0.2, { Scale = 0.6 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
					if lastEquipped == token then
						equippedTag.Visible = false
					end
				end
			end)
		else
			equippedTag.Visible = false
		end
	end

	---------------------------------------------------------------------------
	-- bag window
	---------------------------------------------------------------------------
	local win = Kit.window({
		Name = "Bag",
		Size = Vector2.new(920, 560),
		Accent = Theme.Accent.Bag,
		Title = "BACKPACK",
		Icon = Theme.Icon.Bag,
		Parent = ctx.WindowLayer,
		OnClose = ctx.Close,
	})
	local content = win.Content
	win.Root.Position = UDim2.new(0.5, 0, 0.5, -30)

	local countLbl = Kit.text({
		Name = "Count",
		Text = "0 ITEMS",
		TextSize = 24,
		TextColor3 = C.TextSoft,
		Position = UDim2.fromOffset(6, 18),
		Size = UDim2.fromOffset(300, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 12,
		Stroke = 3,
		Parent = content,
	})
	local search = Kit.plate({
		Name = "Search",
		Parent = content,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 12),
		Size = UDim2.fromOffset(330, 52),
		Radius = UDim.new(1, 0),
		Stroke = 4,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	-- magnifier drawn from shapes, as far in from the left as from the top and bottom
	local lens = new("Frame", { Name = "Lens", BackgroundTransparency = 1, Position = UDim2.fromOffset(13, 13), Size = UDim2.fromOffset(20, 20), ZIndex = 13, Parent = search })
	Kit.pill(lens)
	Kit.stroke(lens, 3.5, C.TextSoft, 0, true)
	local handle = new("Frame", { Name = "Handle", BackgroundColor3 = C.TextSoft, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(35, 36), Size = UDim2.fromOffset(11, 4), Rotation = 45, ZIndex = 13, Parent = search })
	Kit.pill(handle)
	local box = new("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(49, 0),
		Size = UDim2.new(1, -63, 1, 0),
		FontFace = Theme.Font.Heavy,
		TextSize = 21,
		TextColor3 = C.Text,
		PlaceholderText = "Search items...",
		PlaceholderColor3 = C.TextDim,
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 13,
		Parent = search,
	})
	local searchStroke = search:FindFirstChildOfClass("UIStroke")
	box.Focused:Connect(function()
		if searchStroke then
			tween(searchStroke, 0.2, { Color = Theme.Accent.Bag[1] })
		end
	end)
	box.FocusLost:Connect(function()
		if searchStroke then
			tween(searchStroke, 0.2, { Color = C.Ink })
		end
	end)

	local well = Kit.plate({
		Name = "Well",
		Parent = content,
		Position = UDim2.fromOffset(0, 78),
		Size = UDim2.new(1, 0, 1, -122),
		Radius = 24,
		Stroke = 4,
		ZIndex = 12,
		Gradient = { C.Night, C.Navy900 },
	})
	well.BackgroundTransparency = 0.15
	local grid = new("ScrollingFrame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- inset from the well's rounded outline so the scroll bar never touches it
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, -12, 1, -24),
		VerticalScrollBarInset = Enum.ScrollBarInset.Always,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.Rim,
		ScrollBarImageTransparency = 0.3,
		ZIndex = 13,
		Parent = well,
	})
	Kit.padding(grid, 16, 4, 8, 4)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(98, 110), CellPadding = UDim2.fromOffset(12, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local emptyLbl = new("Frame", { Name = "Empty", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 13, Parent = well })
	Kit.image({ Image = Theme.Icon.Bag, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.5, 6), Size = UDim2.fromOffset(110, 110), ImageTransparency = 0.35, ZIndex = 13, Parent = emptyLbl })
	Kit.text({ Text = "Nothing stored yet", TextSize = 28, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 18), Size = UDim2.fromOffset(500, 34), ZIndex = 13, Stroke = 3.5, Parent = emptyLbl })
	Kit.text({
		Text = "Drag a hotbar item in here to store it",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 54),
		Size = UDim2.fromOffset(500, 24),
		ZIndex = 13,
		Stroke = 2.2,
		Parent = emptyLbl,
	})
	Kit.text({
		Name = "Hint",
		Text = if ctx.IsTouch then "Drag items between the bag and your hotbar  |  Tap a slot to equip" else "Drag items between the bag and your hotbar  |  Press 1-5 to equip",
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 4),
		Size = UDim2.new(1, 0, 0, 30),
		ZIndex = 12,
		Stroke = 2.2,
		Parent = content,
	})

	local bagSlots: { any } = {}
	local function bagSlot(k: number)
		if not bagSlots[k] then
			bagSlots[k] = makeSlot(grid, 98, k)
		end
		return bagSlots[k]
	end

	---------------------------------------------------------------------------
	-- tooltip
	---------------------------------------------------------------------------
	local tip = Kit.plate({
		Name = "ToolTip",
		Parent = ctx.Root,
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Radius = 16,
		Stroke = 3.5,
		ZIndex = 60,
		Gradient = { C.Navy700, C.Night },
	})
	tip.Visible = false
	Kit.padding(tip, 14, 8, 14, 10)
	Kit.list(tip, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center)
	local tipTitle = Kit.text({ Text = "", TextSize = 22, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 61, LayoutOrder = 1, Stroke = 3, Parent = tip })
	local tipBody = Kit.text({
		Text = "",
		TextSize = 16,
		FontFace = Theme.Font.Bold,
		TextColor3 = C.TextSoft,
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.XY,
		TextWrapped = false,
		ZIndex = 61,
		LayoutOrder = 2,
		Stroke = false,
		Parent = tip,
	})
	local tipOwner: any = nil
	local function showTip(s: any)
		local tool = s.Tool
		if not tool then
			return
		end
		tipOwner = s
		tipTitle.Text = tool.Name
		tipBody.Text = tool.ToolTip
		tipBody.Visible = tool.ToolTip ~= ""
		tip.Position = ctx.ToRoot(s.Body) - UDim2.fromOffset(0, s.Size * 0.5 + 30)
		tip.Visible = true
		local sc = Kit.fx(tip)
		sc.Scale = 0.7
		tween(sc, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	local function hideTip(s: any?)
		if s == nil or tipOwner == s then
			tip.Visible = false
			tipOwner = nil
		end
	end

	---------------------------------------------------------------------------
	-- equipping
	---------------------------------------------------------------------------
	local function toggleTool(tool: Tool?)
		if not tool or not humanoid or humanoid.Health <= 0 then
			return
		end
		if tool.Parent == character then
			humanoid:UnequipTools()
		elseif tool.Enabled then
			humanoid:EquipTool(tool)
		end
	end

	---------------------------------------------------------------------------
	-- dragging (only while the bag is open, like the original pack)
	---------------------------------------------------------------------------
	local pending: any = nil
	local drag: any = nil

	-- same space as AbsolutePosition (below the top bar), for mouse and touch alike
	local function pointer(input: InputObject?): Vector2
		if input then
			return Vector2.new(input.Position.X, input.Position.Y)
		end
		local inset = GuiService:GetGuiInset()
		return UserInputService:GetMouseLocation() - inset
	end

	local function inside(g: GuiObject, p: Vector2): boolean
		local a, s = g.AbsolutePosition, g.AbsoluteSize
		return p.X >= a.X and p.Y >= a.Y and p.X <= a.X + s.X and p.Y <= a.Y + s.Y
	end

	local function endDrag()
		if drag and drag.Ghost then
			drag.Ghost:Destroy()
		end
		if drag and drag.Slot then
			drag.Slot.Body.Visible = true
		end
		drag = nil
	end

	local function startDrag(p: Vector2)
		local s = pending.Slot
		local abs = s.Body.AbsoluteSize
		local ghost = new("Frame", {
			Name = "DragGhost",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(p.X, p.Y),
			Size = UDim2.fromOffset(abs.X, abs.Y),
			Rotation = -6,
			Parent = ctx.DragGui,
		})
		local plate = Kit.plate({ Parent = ghost, Size = UDim2.fromScale(1, 1), Radius = 22 * ctx.Scale, Stroke = 4 * ctx.Scale, StrokeColor = C.Gold, Gradient = { C.Navy500, C.Navy700 } })
		local tool = pending.Tool
		if tool.TextureId ~= "" then
			Kit.image({ Image = tool.TextureId, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.72, 0.72), Parent = plate })
		else
			Kit.text({ Text = tool.Name, TextSize = 16 * ctx.Scale, TextWrapped = true, Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), Stroke = 2.5 * ctx.Scale, Parent = plate })
		end
		local sc = Kit.fx(ghost)
		sc.Scale = 1
		tween(sc, 0.2, { Scale = 1.12 }, Enum.EasingStyle.Back)
		s.Body.Visible = false
		drag = { Tool = tool, From = pending.From, Index = pending.Index, Ghost = ghost, Slot = s }
		hideTip()
		Kit.sfx("Hover")
	end

	local function removeFromBag(tool: Tool)
		local k = table.find(bagList, tool)
		if k then
			table.remove(bagList, k)
		end
	end

	local function drop(p: Vector2)
		local d = drag
		if not d then
			return
		end
		local tool = d.Tool
		local target: number? = nil
		for i = 1, SLOTS do
			if hotSlots[i].Button.Visible and inside(hotSlots[i].Button, p) then
				target = i
				break
			end
		end
		if target then
			if d.From == "hot" then
				if target ~= d.Index then
					local other = hot[target]
					hot[target] = tool
					hot[d.Index] = other
					memory[tool.Name] = target
					if other then
						memory[other.Name] = d.Index
					end
				end
			else
				local other = hot[target]
				removeFromBag(tool)
				hot[target] = tool
				memory[tool.Name] = target
				if other then
					table.insert(bagList, 1, other)
					memory[other.Name] = -1
				end
			end
			Kit.sfx("Equip")
			local s = hotSlots[target]
			s.Scale.Scale = 1.25
			tween(s.Scale, 0.35, { Scale = if s.Equipped then 1.08 else 1 }, Enum.EasingStyle.Back)
		elseif win.IsOpen and inside(well, p) and d.From == "hot" then
			hot[d.Index] = nil
			table.insert(bagList, 1, tool)
			memory[tool.Name] = -1
			Kit.sfx("Equip")
		end
		endDrag()
		render()
	end

	local function hookSlot(s: any, from: string, getIndex: () -> number?)
		s.Button.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if not s.Tool then
				return
			end
			pending = { Slot = s, Tool = s.Tool, From = from, Index = getIndex(), Start = pointer(input), Input = input }
		end)
		s.Button.MouseEnter:Connect(function()
			if drag or not s.Tool then
				return
			end
			tween(s.Scale, 0.2, { Scale = if s.Equipped then 1.12 else 1.06 }, Enum.EasingStyle.Back)
			showTip(s)
		end)
		s.Button.MouseLeave:Connect(function()
			tween(s.Scale, 0.2, { Scale = if s.Equipped then 1.08 else 1 }, Enum.EasingStyle.Back)
			hideTip(s)
		end)
	end
	for i = 1, SLOTS do
		hookSlot(hotSlots[i], "hot", function()
			return i
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if pending and pending.Input.UserInputType == Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local p = pointer(input)
		if drag then
			drag.Ghost.Position = UDim2.fromOffset(p.X, p.Y)
		elseif pending and bagOpen and (p - pending.Start).Magnitude > 10 then
			startDrag(p)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if drag then
			drop(pointer(input))
		elseif pending then
			local s = pending.Slot
			local p = pointer(input)
			if inside(s.Button, p) then
				Kit.sfx("Click")
				toggleTool(pending.Tool)
			end
		end
		pending = nil
	end)

	---------------------------------------------------------------------------
	-- render
	---------------------------------------------------------------------------
	render = function()
		for i = 1, SLOTS do
			local s = hotSlots[i]
			local tool = hot[i]
			paint(s, tool, i)
			local vis = tool ~= nil or bagOpen
			if vis and not s.Button.Visible then
				s.Button.Visible = true
				s.Scale.Scale = 0.5
				tween(s.Scale, 0.35, { Scale = if s.Equipped then 1.08 else 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, i * 0.02)
			else
				s.Button.Visible = vis
			end
		end
		local query = box.Text:lower()
		local shown = 0
		for k, tool in ipairs(bagList) do
			local s = bagSlot(k)
			paint(s, tool, nil)
			local match = query == "" or tool.Name:lower():find(query, 1, true) ~= nil
			s.Button.Visible = match
			if match then
				shown += 1
			end
		end
		for k = #bagList + 1, #bagSlots do
			bagSlots[k].Button.Visible = false
			bagSlots[k].Tool = nil
		end
		countLbl.Text = if #bagList == 1 then "1 ITEM" else ("%d ITEMS"):format(#bagList)
		showEquipped(if character then character:FindFirstChildOfClass("Tool") else nil)
		emptyLbl.Visible = #bagList == 0
		if tipOwner and not tipOwner.Tool then
			hideTip()
		end
		local _ = shown
	end

	-- bag slots are pooled; hook each as it is made
	local hookedBag: { [any]: boolean } = {}
	local baseRender = render
	render = function()
		baseRender()
		for k, s in ipairs(bagSlots) do
			if not hookedBag[s] then
				hookedBag[s] = true
				hookSlot(s, "bag", function()
					return k
				end)
			end
		end
	end
	box:GetPropertyChangedSignal("Text"):Connect(function()
		render()
	end)

	---------------------------------------------------------------------------
	-- tool tracking
	---------------------------------------------------------------------------
	local function isMine(tool: Tool): boolean
		return (backpack ~= nil and tool.Parent == backpack) or (character ~= nil and tool.Parent == character)
	end

	local function untrack(tool: Tool)
		for _, c in ipairs(tracked[tool] or {}) do
			c:Disconnect()
		end
		tracked[tool] = nil
		for i = 1, SLOTS do
			if hot[i] == tool then
				hot[i] = nil
			end
		end
		removeFromBag(tool)
		if drag and drag.Tool == tool then
			endDrag()
		end
		render()
	end

	local function track(tool: Instance)
		if not tool:IsA("Tool") or tracked[tool] then
			return
		end
		local t = tool :: Tool
		tracked[t] = {
			t.AncestryChanged:Connect(function()
				task.defer(function()
					if not isMine(t) then
						untrack(t)
					else
						render()
					end
				end)
			end),
			t:GetPropertyChangedSignal("TextureId"):Connect(render),
			t:GetPropertyChangedSignal("Name"):Connect(render),
			t:GetPropertyChangedSignal("Enabled"):Connect(render),
			t:GetAttributeChangedSignal("amount"):Connect(render),
		}
		local want = memory[t.Name]
		if want == -1 then
			table.insert(bagList, t)
		elseif want and hot[want] == nil then
			hot[want] = t
		else
			local free: number? = nil
			for i = 1, SLOTS do
				if hot[i] == nil then
					free = i
					break
				end
			end
			if free then
				hot[free] = t
				memory[t.Name] = memory[t.Name] or free
			else
				table.insert(bagList, t)
			end
		end
		render()
	end

	local charConns: { RBXScriptConnection } = {}
	local function onCharacter(char: Model)
		for _, c in ipairs(charConns) do
			c:Disconnect()
		end
		table.clear(charConns)
		character = char
		humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
		backpack = player:WaitForChild("Backpack", 10)
		if backpack then
			for _, t in ipairs(backpack:GetChildren()) do
				track(t)
			end
			table.insert(charConns, backpack.ChildAdded:Connect(track))
		end
		for _, t in ipairs(char:GetChildren()) do
			track(t)
		end
		table.insert(charConns, char.ChildAdded:Connect(track))
		render()
	end
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)

	---------------------------------------------------------------------------
	-- keys 1-9
	---------------------------------------------------------------------------
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() or hidden or ctx.KeyCapture then
			return
		end
		local i = KEYS[input.KeyCode]
		if i and i <= SLOTS then
			toggleTool(hot[i])
		end
	end)

	ctx.On("HudHidden", function(isHidden: boolean)
		hidden = isHidden
		tween(hotbar, 0.35, { Position = UDim2.new(0.5, 0, 1, if isHidden then 180 else -20) }, Enum.EasingStyle.Quint)
		if isHidden then
			equippedTag.Visible = false
		end
	end)

	ctx.Register("Bag", {
		Window = win,
		OnOpen = function()
			bagOpen = true
			render()
		end,
		OnClose = function()
			bagOpen = false
			pending = nil
			endDrag()
			hideTip()
			box:ReleaseFocus()
			render()
		end,
	})
	render()
end
