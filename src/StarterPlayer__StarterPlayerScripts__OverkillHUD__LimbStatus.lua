--[[
	LimbStatus  (StarterPlayerScripts.OverkillHUD.LimbStatus)
	What your body has lost, in a pill over the hotbar (Config.Gore - the server keeps it as your
	character's GoreStage attribute):
	  ONE ARM   VULNERABLE · SINGLE STRIKES   (gold)  more damage taken, a weaker guard, no combos
	  NO ARMS   NO GUARD · NO ATTACKS         (red)   it can only move
	and a green ARM RESTORED as an arm grows back with your health. Nothing while you are whole,
	nothing once you are down. Losing another arm shakes it; the HUD's hide toggle hides it too.
]]

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player

	local STATES = {
		[1] = { Tag = "ONE ARM", Note = "VULNERABLE  ·  SINGLE STRIKES", Accent = C.Gold, Deep = C.GoldDeep },
		[2] = { Tag = "NO ARMS", Note = "NO GUARD  ·  NO ATTACKS", Accent = C.Red, Deep = C.RedDeep },
	}
	local RESTORED = { Tag = "ARM RESTORED", Accent = C.Green, Deep = C.GreenDeep }
	local RESTORED_HOLD = 1.4

	---------------------------------------------------------------------------
	-- the pill
	---------------------------------------------------------------------------
	local holder = new("Frame", {
		Name = "LimbStatus",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -156), -- (just over the hotbar: 20 below it, 124 tall)
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 20,
		Parent = ctx.Root,
	})
	local scale = Kit.fx(holder)
	local plate = Kit.plate({
		Parent = holder,
		Name = "Plate",
		Color = C.Navy900,
		Transparency = 0.06,
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = 20,
		Stroke = 3,
		ZIndex = 20,
	})
	Kit.padding(plate, 6, 0, 16, 0)
	Kit.list(plate, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local chip = Kit.plate({
		Parent = plate,
		Name = "Tag",
		Color = C.Gold,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = 14,
		Stroke = 2,
		ZIndex = 21,
		LayoutOrder = 1,
	})
	Kit.padding(chip, 12, 0, 12, 0)
	Kit.gradient(chip, Color3.new(1, 1, 1), Color3.new(0.8, 0.8, 0.8), 90) -- (shaded: the accent, darker below)
	local tag = Kit.text({
		Parent = chip,
		Name = "Text",
		Text = "",
		TextSize = 18,
		FontFace = Theme.Font.Heavy,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 22,
		Stroke = 1.8,
	})
	local note = Kit.text({
		Parent = plate,
		Name = "Note",
		Text = "",
		TextSize = 15,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		ZIndex = 21,
		Stroke = 1.6,
	})

	local hudHidden = false
	local shown: any = nil
	local serial = 0

	local function paint(st: any)
		chip.BackgroundColor3 = st.Accent
		tag.Text = st.Tag
		note.Text = st.Note or ""
		note.Visible = st.Note ~= nil
	end

	local function show(st: any, shake: boolean?)
		serial += 1
		if not st then
			shown = nil
			if holder.Visible then
				local s = serial
				tween(scale, 0.14, { Scale = 0.82 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(0.15, function()
					if serial == s then
						holder.Visible = false
					end
				end)
			end
			return
		end
		local fresh = shown == nil or not holder.Visible
		shown = st
		paint(st)
		holder.Visible = not hudHidden
		if fresh then
			scale.Scale = 0.7
			tween(scale, 0.24, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		else
			scale.Scale = 1.12
			tween(scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
		if shake then
			Kit.shake(holder)
		end
	end

	ctx.On("HudHidden", function(isHidden: boolean)
		hudHidden = isHidden
		holder.Visible = shown ~= nil and not isHidden
	end)

	---------------------------------------------------------------------------
	-- your character's stage
	---------------------------------------------------------------------------
	local stageNow = 0
	local conns: { RBXScriptConnection } = {}

	local function apply(stage: number, alive: boolean)
		local was = stageNow
		stageNow = stage
		if not alive or stage >= 3 then
			show(nil)
			return
		end
		if stage < was then
			-- an arm grew back: a green flash, then what is still missing (or nothing)
			show(RESTORED)
			local s = serial
			task.delay(RESTORED_HOLD, function()
				if serial == s then
					show(STATES[stageNow])
				end
			end)
			return
		end
		if stage ~= was or shown == nil then
			show(STATES[stage], stage > was and was > 0)
		end
	end

	local function bind(char: Model)
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
		stageNow = 0
		show(nil)
		local function read(): number
			local st = char:GetAttribute("GoreStage")
			return if type(st) == "number" then st else 0
		end
		local function isAlive(): boolean
			local hum = char:FindFirstChildOfClass("Humanoid")
			return hum == nil or hum.Health > 0
		end
		table.insert(conns, char:GetAttributeChangedSignal("GoreStage"):Connect(function()
			apply(read(), isAlive())
		end))
		task.spawn(function()
			local hum = char:WaitForChild("Humanoid", 10)
			if hum and hum:IsA("Humanoid") and player.Character == char then
				table.insert(conns, hum.Died:Connect(function()
					show(nil)
				end))
			end
		end)
		-- (already missing limbs when this runs: shown as it is, no flash)
		local st = read()
		if st > 0 then
			stageNow = st
			if st < 3 and isAlive() then
				show(STATES[st])
			end
		end
	end

	if player.Character then
		bind(player.Character)
	end
	player.CharacterAdded:Connect(bind)
end
