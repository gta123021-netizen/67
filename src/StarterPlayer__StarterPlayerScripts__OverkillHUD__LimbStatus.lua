--[[
	LimbStatus  (StarterPlayerScripts.OverkillHUD.LimbStatus)
	What a body has lost (Config.Gore - the server keeps it as the character's GoreStage, with
	RegrowAt: when a player's next arm grows back), drawn with the HUD's own status pill (ctx.StatusPill:
	the hero / coins / level pills' capsule, dress, glow, outline, caption and value):

	  YOUR PILL, over the hotbar
	    badge  the hero pill's ringed disc in the state's colour, holding a fighter glyph (the hero
	           screen's white-and-ink figure) with its arms: a lost arm is gone from it, a growing
	           one grows back in green as the clock runs
	    value  ONE ARM (gold) / NO ARMS (red) / ARM RESTORED (green, for a moment)
	    caption  what it means: SINGLE STRIKES · WEAK GUARD / NO GUARD · NO ATTACKS
	    socket   the pill's right end (the coins +, the hero CHANGE): seconds until the next arm
	    A press the body can't answer (a strike or a guard with no arms) shakes it (CombatClient
	    sets the player's LimbDenied attribute).
	  EVERY OTHER FIGHTER missing an arm: the same pill, smaller, over its head (value, badge and
	    socket - no caption), gone when it is whole again or down.

	Nothing while whole, nothing once down. The HUD's hide toggle hides your pill.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player
	local HUD = Theme.Hud
	local M = ctx.PillMetrics or { Height = 60, BadgeX = 38, BadgeY = 30, TextX = 57, RightPad = 8 }
	if not (ctx.StatusPill and ctx.PillValue and ctx.PillAction) then
		return
	end

	local STATES = {
		[1] = { Value = "ONE ARM", Caption = "SINGLE STRIKES  ·  WEAK GUARD", Accent = C.Gold, Deep = C.GoldDeep },
		[2] = { Value = "NO ARMS", Caption = "NO GUARD  ·  NO ATTACKS", Accent = C.Red, Deep = C.RedDeep },
	}
	local RESTORED = { Value = "ARM RESTORED", Caption = "BACK IN THE FIGHT", Accent = C.Green, Deep = C.GreenDeep, Restored = true }
	local RESTORED_HOLD = 1.4
	local REGROW_TIME = Config.Gore.Regrow and Config.Gore.Regrow.Time or 10
	local SOCKET_W = 74 -- the countdown socket's own width (the pill's right end)
	local PILL_X = 30 -- (the status pills' left edge in their holder: room for the badge)

	---------------------------------------------------------------------------
	-- the fighter glyph with arms (the hero screen's figure: white, an ink outline, a soft shade)
	-- The figure faces you, so its RIGHT arm is on your left.
	---------------------------------------------------------------------------
	local function figure(parent: GuiObject, size: number, z: number)
		local s = size
		local stroke = math.max(2.5, s * 0.07)
		local holder = new("Frame", { Name = "Figure", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(s, s), ZIndex = z, Parent = parent })
		local function piece(name: string, w: number, h: number, pos: UDim2, anchor: Vector2, zz: number, round: boolean, host: Instance?)
			local f = new("Frame", { Name = name, BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = anchor, Position = pos, Size = UDim2.fromOffset(w, h), ZIndex = zz, Parent = host or holder })
			if round then
				Kit.pill(f)
			else
				new("UICorner", { CornerRadius = UDim.new(0, math.floor(s * 0.16)), Parent = f })
			end
			local st = Kit.stroke(f, stroke, C.Ink, 0, true)
			local g = Kit.gradient(f, Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242), 90)
			return f, st, g
		end
		-- arms first (under the torso's outline, so they hang from its shoulders): each on a pivot
		-- at its shoulder, turned a little outward
		local armW, armH = math.floor(s * 0.17), math.floor(s * 0.44)
		local arms = {}
		for i, side in ipairs({ "Right", "Left" }) do
			local sx = if i == 1 then -1 else 1 -- (its right arm on your left)
			local pivot = new("Frame", {
				Name = side .. "Shoulder",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, sx * math.floor(s * 0.27), 0, math.floor(s * 0.43)),
				Size = UDim2.fromOffset(armW, armH * 2),
				Rotation = sx * 14,
				ZIndex = z,
				Parent = holder,
			})
			local arm, st, g = piece(side .. "Arm", armW, armH, UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0), z, true, pivot)
			arms[side] = { Frame = arm, Stroke = st, Shade = g, Full = armH }
		end
		piece("Torso", math.floor(s * 0.46), math.floor(s * 0.46), UDim2.new(0.5, 0, 0, math.floor(s * 0.34)), Vector2.new(0.5, 0), z + 1, false)
		piece("Head", math.floor(s * 0.36), math.floor(s * 0.36), UDim2.new(0.5, 0, 0, math.floor(s * 0.01)), Vector2.new(0.5, 0), z + 2, true)
		local api = {}
		-- how much of each arm there is: 1 whole, 0 gone, in between growing back (in green)
		function api.Set(right: number, left: number)
			for side, amount in pairs({ Right = right, Left = left }) do
				local a = arms[side]
				a.Frame.Visible = amount > 0.02
				a.Frame.Size = UDim2.fromOffset(armW, math.max(armW, math.floor(a.Full * math.clamp(amount, 0, 1))))
				local growing = amount < 0.999
				a.Shade.Color = if growing then ColorSequence.new(Kit.lighten(C.Green, 0.2), C.GreenDeep) else ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242))
			end
		end
		return api
	end

	---------------------------------------------------------------------------
	-- one limb pill (the HUD's status pill): the ringed badge with the figure, the value, the
	-- caption and the countdown socket. Returns its api
	---------------------------------------------------------------------------
	local function limbPill(name: string, withCaption: boolean)
		local holder, pill, caption, glow = ctx.StatusPill(name, 0, "", C.Gold, nil)
		holder.Parent = nil -- (built by the status column's own builder; placed by the caller)
		-- the badge: the hero pill's portrait disc - ink, a band in the state's colour, ink - with
		-- the figure on its face
		local disc = new("Frame", { Name = "Badge", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(M.BadgeX, M.BadgeY), Size = UDim2.fromOffset(72, 72), ZIndex = 5, Parent = holder })
		Kit.pill(disc)
		local _, grads = Kit.rings(disc, UDim.new(1, 0), { { 3, C.Ink }, { 5, { Kit.lighten(C.Gold, 0.25), C.GoldDeep, 90 } }, { 3, C.Ink } }, 8)
		Kit.edgeStrokes(disc, UDim.new(1, 0), { { 2, C.Ink, nil, "Center" } }, 9)
		local bandGrad = grads[2]
		local faceGrad = Kit.gradient(disc, Kit.lighten(C.Gold, 0.1), Kit.darken(C.GoldDeep, 0.35), 90)
		local glyph = figure(disc, 44, 7)
		local value = ctx.PillValue(pill, "", C.Gold, M.RightPad + SOCKET_W + 12)
		if not withCaption then
			caption.Visible = false
			value.Position = UDim2.fromOffset(M.TextX, math.floor((M.Height - 32) / 2))
		end
		-- the socket: the pill's right end, like its actions (never pressed: it shows the clock)
		local socket = ctx.PillAction(pill, { Name = "Regrow", Width = SOCKET_W, Text = "", TextSize = 22, Color = C.Green, Deep = C.GreenDeep, HoverScale = 1 })
		socket.Enabled = false
		socket.Button.Active = false
		socket.Button.Visible = false

		local api: any = { Holder = holder, Pill = pill, Value = value, Caption = caption, Glyph = glyph, Socket = socket, Width = 0, OnFit = nil }
		function api.Paint(st: any)
			glow.BackgroundColor3 = st.Accent
			bandGrad.Color = ColorSequence.new(Kit.lighten(st.Accent, 0.25), st.Deep)
			faceGrad.Color = ColorSequence.new(Kit.lighten(st.Accent, 0.1), Kit.darken(st.Deep, 0.35))
			value.Text = st.Value
			value.TextColor3 = Kit.lighten(st.Accent, 0.3)
			caption.Text = if withCaption then st.Caption or "" else ""
		end
		-- the pill's width for its text (and the socket, when it shows)
		function api.Fit(): number
			local textW = math.max(Kit.textWidth(value.Text, 28, Theme.Font.Display), if withCaption then Kit.textWidth(caption.Text, 14, Theme.Font.Heavy) else 0)
			local right = if socket.Button.Visible then M.RightPad + SOCKET_W + 12 else M.RightPad + 14
			local w = PILL_X + M.TextX + math.ceil(textW) + right
			holder.Size = UDim2.fromOffset(w, M.Height)
			value.Size = UDim2.new(1, -M.TextX - right + 12, 0, 32)
			api.Width = w
			if api.OnFit then
				api.OnFit(w)
			end
			return w
		end
		-- the arms (stage) and the clock: seconds to the next arm, and how grown it is
		function api.Arms(stage: number, regrowAt: number?)
			local right = if stage >= 1 then 0 else 1
			local left = if stage >= 2 then 0 else 1
			local secs: number? = nil
			if regrowAt and stage >= 1 and stage <= 2 then
				local rem = math.max(0, regrowAt - workspace:GetServerTimeNow())
				secs = rem
				local grown = 1 - math.clamp(rem / REGROW_TIME, 0, 1)
				-- the last one lost grows back first: the left at stage 2, the right at stage 1
				if stage == 2 then
					left = grown
				else
					right = grown
				end
			end
			-- (only what changed: the figure a pixel at a time, the socket a second at a time)
			local rq, lq = math.floor(right * 64 + 0.5), math.floor(left * 64 + 0.5)
			if rq ~= api.LastR or lq ~= api.LastL then
				api.LastR, api.LastL = rq, lq
				glyph.Set(right, left)
			end
			local showSocket = secs ~= nil
			if socket.Button.Visible ~= showSocket then
				socket.Button.Visible = showSocket
				api.Fit()
			end
			if secs then
				local text = ("%ds"):format(math.ceil(secs - 1e-3))
				if text ~= api.LastText then
					api.LastText = text
					socket.SetText(text)
				end
			end
		end
		return api
	end

	---------------------------------------------------------------------------
	-- your pill, over the hotbar
	---------------------------------------------------------------------------
	local HOTBAR_TOP = 20 + 124 -- (Backpack: the hotbar sits 20 above the bottom, 124 tall)
	local home = new("Frame", {
		Name = "LimbStatus",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(HOTBAR_TOP + HUD.GroupGap)),
		Size = UDim2.fromOffset(300, M.Height),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 20,
		Parent = ctx.Root,
	})
	local scale = Kit.fx(home)
	local mine = limbPill("Limbs", true)
	mine.Holder.Parent = home
	mine.Holder.Position = UDim2.fromOffset(0, 0)
	mine.OnFit = function(w: number)
		home.Size = UDim2.fromOffset(w, M.Height) -- (centred over the hotbar at any width)
	end

	local hudHidden = false
	local shown: any = nil
	local serial = 0
	local function layout()
		mine.Fit()
	end

	local function show(st: any)
		serial += 1
		if not st then
			shown = nil
			if home.Visible then
				local s = serial
				tween(scale, 0.14, { Scale = 0.82 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(0.15, function()
					if serial == s then
						home.Visible = false
					end
				end)
			end
			return
		end
		local fresh = shown == nil or not home.Visible
		shown = st
		mine.Paint(st)
		layout()
		home.Visible = not hudHidden
		if fresh then
			scale.Scale = 0.7
			tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		else
			scale.Scale = 1.1
			tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end

	ctx.On("HudHidden", function(isHidden: boolean)
		hudHidden = isHidden
		home.Visible = shown ~= nil and not isHidden
	end)

	-- a press the body can't answer: the pill says why
	player:GetAttributeChangedSignal("LimbDenied"):Connect(function()
		if shown and home.Visible then
			Kit.shake(home)
			Kit.sfx("Error")
		end
	end)

	local stageNow = 0
	local myChar: Model? = nil
	local conns: { RBXScriptConnection } = {}

	local function regrowAtOf(char: Model): number?
		local r = char:GetAttribute("RegrowAt")
		return if type(r) == "number" then r else nil
	end

	local function apply(char: Model, stage: number, alive: boolean)
		local was = stageNow
		stageNow = stage
		if not alive or stage >= 3 then
			show(nil)
			return
		end
		if stage < was then
			-- an arm grew back: a green flash, then what is still missing (or nothing)
			show(RESTORED)
			mine.Arms(stage, nil)
			local s = serial
			task.delay(RESTORED_HOLD, function()
				if serial == s and myChar == char then
					show(STATES[stageNow])
					if STATES[stageNow] then
						mine.Arms(stageNow, regrowAtOf(char))
					end
				end
			end)
			return
		end
		if stage ~= was or shown == nil then
			show(STATES[stage])
			if STATES[stage] then
				mine.Arms(stage, regrowAtOf(char))
				if stage > was and was > 0 then
					Kit.shake(home) -- (another arm gone)
				end
			end
		end
	end

	local function bind(char: Model)
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
		myChar = char
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
			apply(char, read(), isAlive())
		end))
		table.insert(conns, char:GetAttributeChangedSignal("RegrowAt"):Connect(function()
			if STATES[stageNow] and shown and not shown.Restored then
				mine.Arms(stageNow, regrowAtOf(char))
			end
		end))
		task.spawn(function()
			local hum = char:WaitForChild("Humanoid", 10)
			if hum and hum:IsA("Humanoid") and myChar == char then
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
				mine.Arms(st, regrowAtOf(char))
			end
		end
	end

	if player.Character then
		bind(player.Character)
	end
	player.CharacterAdded:Connect(bind)

	---------------------------------------------------------------------------
	-- everyone else: the same pill, smaller, over the head of any fighter missing an arm
	---------------------------------------------------------------------------
	type Tag = { Char: Model, Gui: BillboardGui?, Pill: any, Stage: number, Serial: number, Conns: { RBXScriptConnection } }
	local tags: { [Model]: Tag } = {}
	local TAG_SCALE = 0.5

	local function dropGui(t: Tag)
		if t.Gui then
			t.Gui:Destroy()
			t.Gui = nil
			t.Pill = nil
		end
	end

	local function tagGui(t: Tag): any
		if t.Gui and t.Gui.Parent then
			return t.Pill
		end
		local head = t.Char:FindFirstChild("Head")
		if not (head and head:IsA("BasePart")) then
			return nil
		end
		local bb = new("BillboardGui", {
			Name = "LimbTag",
			Size = UDim2.fromOffset(460 * TAG_SCALE, M.Height * TAG_SCALE + 12),
			-- (high enough to clear the name and health bar Roblox draws over a head)
			StudsOffset = Vector3.new(0, 3.8, 0),
			AlwaysOnTop = true,
			LightInfluence = 0,
			MaxDistance = 90,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			Adornee = head,
			Parent = head,
		})
		local stage = new("Frame", { Name = "Stage", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(460, M.Height), Parent = bb })
		new("UIScale", { Scale = TAG_SCALE, Parent = stage })
		local p = limbPill("Tag", false)
		p.Holder.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Holder.Position = UDim2.fromScale(0.5, 0.5)
		p.Holder.Parent = stage
		p.Pop = Kit.fx(p.Holder)
		t.Gui = bb
		t.Pill = p
		return p
	end

	local function refreshTag(t: Tag)
		local char = t.Char
		local st = char:GetAttribute("GoreStage")
		st = if type(st) == "number" then st else 0
		local hum = char:FindFirstChildOfClass("Humanoid")
		local alive = hum ~= nil and hum.Health > 0
		local was = t.Stage
		t.Stage = st
		t.Serial += 1
		if not alive or st >= 3 or (st == 0 and was == 0) then
			dropGui(t)
			return
		end
		local p = tagGui(t)
		if not p then
			return
		end
		if st < was then
			-- an arm grew back: a green flash on it, then what is still missing (or nothing)
			p.Paint(RESTORED)
			p.Arms(st, nil)
			p.Fit()
			p.Pop.Scale = 1.15
			tween(p.Pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			local s = t.Serial
			task.delay(RESTORED_HOLD, function()
				if t.Serial == s and tags[char] == t then
					t.Serial += 1
					if t.Stage == 0 then
						dropGui(t)
					else
						p.Paint(STATES[t.Stage])
						p.Arms(t.Stage, regrowAtOf(char))
						p.Fit()
					end
				end
			end)
			return
		end
		p.Paint(STATES[st])
		p.Arms(st, regrowAtOf(char))
		p.Fit()
		if st ~= was then
			p.Pop.Scale = if was == 0 then 0.6 else 1.15
			tween(p.Pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end

	local function track(char: Model)
		if tags[char] or char == player.Character then
			return
		end
		local t: Tag = { Char = char, Gui = nil, Pill = nil, Stage = 0, Serial = 0, Conns = {} }
		tags[char] = t
		table.insert(t.Conns, char:GetAttributeChangedSignal("GoreStage"):Connect(function()
			refreshTag(t)
		end))
		table.insert(t.Conns, char:GetAttributeChangedSignal("RegrowAt"):Connect(function()
			if t.Pill and STATES[t.Stage] then
				t.Pill.Arms(t.Stage, regrowAtOf(char))
			end
		end))
		table.insert(t.Conns, char.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				for _, c in ipairs(t.Conns) do
					c:Disconnect()
				end
				dropGui(t)
				tags[char] = nil
			end
		end))
		-- (first seen already missing limbs: its tag at once)
		local st = char:GetAttribute("GoreStage")
		if type(st) == "number" and st > 0 then
			refreshTag(t)
		end
	end

	-- the fighters (the combat's own list: every player's character and the practice dummies)
	task.spawn(function()
		while true do
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				if p ~= player and c and c:GetAttribute("CombatEntity") then
					track(c)
				end
			end
			local dummies = workspace:FindFirstChild("PracticeDummies")
			if dummies then
				for _, m in ipairs(dummies:GetChildren()) do
					if m:IsA("Model") and m:GetAttribute("CombatEntity") then
						track(m)
					end
				end
			end
			-- a dead fighter's tag goes (its Humanoid died without a stage change)
			for _, t in pairs(tags) do
				if t.Gui then
					local hum = t.Char:FindFirstChildOfClass("Humanoid")
					if not hum or hum.Health <= 0 then
						dropGui(t)
					end
				end
			end
			task.wait(0.3)
		end
	end)

	---------------------------------------------------------------------------
	-- the clocks: the growing arms and the seconds, every frame something is growing
	---------------------------------------------------------------------------
	RunService.Heartbeat:Connect(function()
		if myChar and shown and not shown.Restored and STATES[stageNow] then
			local r = regrowAtOf(myChar)
			if r then
				mine.Arms(stageNow, r)
			end
		end
		for char, t in pairs(tags) do
			if t.Pill and STATES[t.Stage] then
				local r = regrowAtOf(char)
				if r then
					t.Pill.Arms(t.Stage, r)
				end
			end
		end
	end)
end
