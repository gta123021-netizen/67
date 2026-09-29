--[[
	LimbStatus  (StarterPlayerScripts.OverkillHUD.LimbStatus)
	What a body has lost (Config.Gore - the server keeps it as the character's GoreStage; a lost limb
	never comes back until the fighter respawns), drawn with the HUD's own status pill
	(ctx.StatusPill: the hero / coins / level pills' capsule, dress, glow, outline, caption and value):

	  YOUR PILL, over the hotbar
	    badge  a card in the hero pill's portrait rings (the band in the state's colour) holding an
	           R6 body seen from the front - head, torso, arms, legs, white with an ink outline: a
	           lost arm is filled red
	    value  ONE ARM (gold) / NO ARMS (red)
	    caption  what it means: SINGLE STRIKES / CAN'T FIGHT
	    A press the body can't answer (a strike or a guard with no arms) shakes it (CombatClient
	    sets the player's LimbDenied attribute).
	  EVERY OTHER FIGHTER missing an arm: the same pill, smaller, over its head (the badge and its
	    word centred - no caption), gone when it is down.

	Nothing while whole, nothing once down. The HUD's hide toggle hides your pill.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player
	local HUD = Theme.Hud
	local M = ctx.PillMetrics or { Height = 60, BadgeX = 38, BadgeY = 30, TextX = 57, RightPad = 8 }
	if not (ctx.StatusPill and ctx.PillValue) then
		return
	end

	local STATES = {
		-- (short words: the pill is sized to its longest line - it sits as compact as the HUD's own
		-- pills, never a banner stretched across the hotbar)
		[1] = { Value = "ONE ARM", Caption = "SINGLE STRIKES", Accent = C.Gold, Deep = C.GoldDeep },
		[2] = { Value = "NO ARMS", Caption = "CAN'T FIGHT", Accent = C.Red, Deep = C.RedDeep },
	}
	local RIGHT = 14 -- clear air after the word, before the pill's right end
	local PILL_X = 30 -- (the status pills' left edge in their holder: room for the badge)

	---------------------------------------------------------------------------
	-- the fighter glyph with arms (the hero screen's figure: white, an ink outline, a soft shade)
	-- The figure faces you, so its RIGHT arm is on your left.
	---------------------------------------------------------------------------
	-- the figure's unit (one R6 stud, in pixels): the whole body with its outline is 4.7 x 5.8 of
	-- them, and it sits inside the badge's face (62 x 78, less its 10-wide rings on every side) with
	-- FIGURE_AIR of clear navy all round - it never touches the rings. One unit for every figure, so
	-- ONE ARM and NO ARMS (and every fighter's tag) are exactly the same size
	local BADGE_W, BADGE_H, RINGS_W = 62, 78, 10
	local FIGURE_AIR = 5
	local FIGURE_U = math.floor(math.min((BADGE_W - 2 * RINGS_W - 2 * FIGURE_AIR) / 4.7, (BADGE_H - 2 * RINGS_W - 2 * FIGURE_AIR) / 5.8) * 4) / 4
	local function figure(parent: GuiObject, z: number)
		-- an R6 body seen from the front, in R6's own proportions: head, torso, two arms, two legs.
		-- Each limb white with an ink outline (the HUD's icon art); a LOST arm filled red
		local u = FIGURE_U
		local holder = new("Frame", { Name = "Figure", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.floor(4.3 * u + 0.5), math.floor(5.4 * u + 0.5)), ZIndex = z, Parent = parent })
		local stroke = math.max(1.5, u * 0.2)
		local gap = u * 0.12
		local cx = 2.15 * u
		local WHITE = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242))
		local RED = ColorSequence.new(Kit.lighten(C.Red, 0.12), C.RedDeep)
		local function piece(name: string, x: number, y: number, pw: number, ph: number, radius: number, zz: number)
			local f = new("Frame", { Name = name, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5)), Size = UDim2.fromOffset(math.floor(pw + 0.5), math.floor(ph + 0.5)), ZIndex = zz, Parent = holder })
			new("UICorner", { CornerRadius = UDim.new(0, math.max(2, math.floor(radius + 0.5))), Parent = f })
			Kit.stroke(f, stroke, C.Ink, 0, true)
			local g = Kit.gradient(f, Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242), 90)
			return f, g
		end
		local limbW = 0.95 * u
		piece("Head", cx, 0, 1.25 * u, 1.05 * u, 0.36 * u, z + 1)
		piece("Torso", cx, 1.15 * u, 2 * u, 2 * u, 0.2 * u, z + 1)
		piece("RightLeg", cx - 0.5 * u - 0.03 * u, 3.25 * u, limbW, 2.05 * u, 0.2 * u, z)
		piece("LeftLeg", cx + 0.5 * u + 0.03 * u, 3.25 * u, limbW, 2.05 * u, 0.2 * u, z)
		local arms = {}
		for i, side in ipairs({ "Right", "Left" }) do
			local sx = if i == 1 then -1 else 1 -- (its right arm on your left)
			local _, g = piece(side .. "Arm", cx + sx * (1 * u + gap + limbW / 2), 1.15 * u, limbW, 2 * u, 0.2 * u, z + 1)
			arms[side] = g
		end
		local api = {}
		-- which arms it has: white, or red where one is lost
		function api.Set(right: boolean, left: boolean)
			arms.Right.Color = if right then WHITE else RED
			arms.Left.Color = if left then WHITE else RED
		end
		return api
	end

	---------------------------------------------------------------------------
	-- one limb pill (the HUD's status pill): the ringed badge with the figure, the value and the
	-- caption. Returns its api
	---------------------------------------------------------------------------
	local function limbPill(name: string, withCaption: boolean)
		local holder, pill, caption, glow = ctx.StatusPill(name, 0, "", C.Gold, nil)
		holder.Parent = nil -- (built by the status column's own builder; placed by the caller)
		-- the badge: a card in the hero pill's portrait rings - ink, a band in the state's colour,
		-- ink - standing on the pill's left cap like its coin and star, the body on its navy face (so
		-- a red lost arm always shows, whatever the state's colour)
		local CARD = UDim.new(0, 16)
		local disc = new("Frame", { Name = "Badge", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(M.BadgeX, M.BadgeY), Size = UDim2.fromOffset(BADGE_W, BADGE_H), ZIndex = 5, Parent = holder })
		new("UICorner", { CornerRadius = CARD, Parent = disc })
		local _, grads = Kit.rings(disc, CARD, { { 3, C.Ink }, { 4, { Kit.lighten(C.Gold, 0.25), C.GoldDeep, 90 } }, { 3, C.Ink } }, 8)
		Kit.edgeStrokes(disc, CARD, { { 2, C.Ink, nil, "Center" } }, 9)
		local bandGrad = grads[2]
		Kit.gradient(disc, Kit.lighten(C.Navy500, 0.1), C.Navy800, 90)
		local glyph = figure(disc, 7)
		local value = ctx.PillValue(pill, "", C.Gold, M.RightPad + RIGHT)
		if not withCaption then
			-- (a tag over a fighter: its word alone, centred in the pill)
			caption.Visible = false
			value.Position = UDim2.fromOffset(M.TextX, math.floor((M.Height - 32) / 2))
			value.TextXAlignment = Enum.TextXAlignment.Center
		end

		local api: any = { Holder = holder, Pill = pill, Value = value, Caption = caption, Glyph = glyph, Width = 0, OnFit = nil }
		function api.Paint(st: any)
			api.State = st
			glow.BackgroundColor3 = st.Accent
			bandGrad.Color = ColorSequence.new(Kit.lighten(st.Accent, 0.25), st.Deep)
			value.Text = st.Value
			value.TextColor3 = Kit.lighten(st.Accent, 0.3)
			caption.Text = if withCaption then st.Caption or "" else ""
		end
		-- the pill's width for its text
		function api.Fit(): number
			local textW = math.max(Kit.textWidth(value.Text, 28, Theme.Font.Display), if withCaption then Kit.textWidth(caption.Text, 14, Theme.Font.Heavy) else 0)
			local right = M.RightPad + RIGHT
			local w = PILL_X + M.TextX + math.ceil(textW) + right
			holder.Size = UDim2.fromOffset(w, M.Height)
			value.Size = UDim2.new(1, -M.TextX - right + (if withCaption then 12 else 4), 0, 32)
			api.Width = w
			if api.OnFit then
				api.OnFit(w)
			end
			return w
		end
		-- the arms the stage leaves it
		function api.Arms(stage: number)
			glyph.Set(stage < 1, stage < 2)
		end
		return api
	end

	---------------------------------------------------------------------------
	-- your pill, over the hotbar
	---------------------------------------------------------------------------
	-- over the hotbar's key caps (an equipped slot rises 10 and scales 1.08, its cap 16 over it: 178),
	-- and over the equipped item's name when one shows (Backpack EquippedName, 44 tall) - one column,
	-- nothing on top of anything
	local HOTBAR_TOP = 178
	local EQUIPPED_H = 44
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
	local homeY = HOTBAR_TOP + HUD.GroupGap
	local function placeHome()
		local eq = ctx.Root:FindFirstChild("EquippedName")
		local y = HOTBAR_TOP + HUD.GroupGap + (if eq and eq:IsA("GuiObject") and eq.Visible then EQUIPPED_H + HUD.GroupGap else 0)
		if y ~= homeY then
			homeY = y
			tween(home, 0.18, { Position = UDim2.new(0.5, 0, 1, -y) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end
	RunService.Heartbeat:Connect(placeHome)
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
			Kit.shake(mine.Holder) -- (home itself moves with the column: the pill inside it shakes)
		end
	end)

	local stageNow = 0
	local myChar: Model? = nil
	local conns: { RBXScriptConnection } = {}

	local function apply(stage: number, alive: boolean)
		local was = stageNow
		stageNow = stage
		if not alive or stage >= 3 then
			show(nil)
			return
		end
		if stage ~= was or shown == nil then
			show(STATES[stage])
			if STATES[stage] then
				mine.Arms(stage)
				if stage > was and was > 0 then
					Kit.shake(mine.Holder) -- (home itself moves with the column: the pill inside it shakes) -- (another arm gone)
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
			apply(read(), isAlive())
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
				mine.Arms(st)
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
	type Tag = { Char: Model, Gui: BillboardGui?, Pill: any, Stage: number, Conns: { RBXScriptConnection }, Lift: number? }
	local tags: { [Model]: Tag } = {}
	local TAG_SCALE = 0.62 -- (big enough that the body on its badge reads at a glance)
	-- where the tag rides: TAG_HOME studs over the head, and always over the fighter's name and bars
	-- (VitalBars: ctx.Vitals). While the fighter's hit tag is up (CombatCallout: the damage number,
	-- GUARD BREAK! over it) it rides above that too: the hit tag sits HIT_LINE studs up with its
	-- lettering a fixed HIT_TOP pixels over that line, so from far away (a stud is only a few pixels)
	-- the two would meet - there the tag climbs until its bottom clears the lettering by TAG_GAP
	-- pixels, gliding (never jumping), and settles back once the hit tag closes
	local TAG_HOME = 2.6
	local HIT_LINE = 1.3 -- (CombatCallout HOME.Y)
	local HIT_TOP = 112 -- px: the top of GUARD BREAK! (its slam and wave included) over that line
	local TAG_GAP = 8

	-- animate: it shrinks away first (the fighter died) - never blinks out
	local function dropGui(t: Tag, animate: boolean?)
		if t.Gui then
			local gui, pill = t.Gui, t.Pill
			t.Gui = nil
			t.Pill = nil
			t.Lift = nil
			if animate and pill and pill.Pop and gui.Parent then
				tween(pill.Pop, 0.18, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
				task.delay(0.2, function()
					gui:Destroy()
				end)
			else
				gui:Destroy()
			end
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
			-- (tall enough for the badge at the top of its pop: it stands taller than the pill)
			Size = UDim2.fromOffset(460 * TAG_SCALE, BADGE_H * 1.2 * TAG_SCALE + 4),
			ClipsDescendants = false,
			StudsOffset = Vector3.new(0, t.Lift or TAG_HOME, 0), -- (see TAG_HOME)
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
		if not alive or st >= 3 or st == 0 then
			dropGui(t, true)
			return
		end
		local p = tagGui(t)
		if not p then
			return
		end
		p.Paint(STATES[st])
		p.Arms(st)
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
		local t: Tag = { Char = char, Gui = nil, Pill = nil, Stage = 0, Conns = {} }
		tags[char] = t
		table.insert(t.Conns, char:GetAttributeChangedSignal("GoreStage"):Connect(function()
			refreshTag(t)
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

	-- the tags keep clear of the hit tags (see TAG_HOME): after the camera has moved, every frame
	local HALF = BADGE_H * TAG_SCALE * 0.5 * 1.15 -- (half the badge - it stands taller than the pill - its pop included)
	local vitalsTop = if ctx.Vitals then ctx.Vitals.Top else nil
	local GuiService = game:GetService("GuiService")
	-- (after the hit tags have placed themselves: CombatCallout's OverkillHitTags)
	RunService:BindToRenderStep("OverkillLimbTags", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local cf = cam.CFrame
		local k = cam.ViewportSize.Y / (2 * math.tan(math.rad(cam.FieldOfView) * 0.5)) -- px per stud at depth 1
		local ease = 1 - math.exp(-dt * 10)
		local rise = 1 - math.exp(-dt * 45)
		local inset = GuiService:GetGuiInset()
		-- every hit tag up on screen this frame (any fighter's): a limb tag also keeps clear of a
		-- NEIGHBOUR's number and GUARD BREAK!, not only its own fighter's
		local hitRects: { { X: number, Half: number, Top: number, Head: BasePart } } = {}
		if next(tags) ~= nil then
			local heads: { BasePart } = {}
			for _, pl in ipairs(Players:GetPlayers()) do
				local h = pl.Character and pl.Character:FindFirstChild("Head")
				if h and h:IsA("BasePart") then
					table.insert(heads, h)
				end
			end
			local dummies = workspace:FindFirstChild("PracticeDummies")
			if dummies then
				for _, m in ipairs(dummies:GetChildren()) do
					local h = m:FindFirstChild("Head")
					if h and h:IsA("BasePart") then
						table.insert(heads, h)
					end
				end
			end
			for _, h in ipairs(heads) do
				local hit = h:FindFirstChild("HitTag")
				if hit and hit:IsA("BillboardGui") and hit.Enabled then
					local p = cam:WorldToViewportPoint(h.Position)
					if p.Z > 0.5 then
						local fit = hit:GetAttribute("Fit") or 1
						local topPx = (hit:GetAttribute("TopPx") or HIT_TOP) * fit
						table.insert(hitRects, {
							X = p.X + hit.SizeOffset.X * hit.AbsoluteSize.X,
							Half = 165 * fit,
							Top = p.Y - (math.max(HIT_LINE, hit.StudsOffset.Y) + hit.StudsOffsetWorldSpace.Y) * k / p.Z - topPx,
							Head = h,
						})
					end
				end
			end
		end
		for _, t in pairs(tags) do
			local bb = t.Gui
			local head = bb and bb.Adornee
			if bb and head and head:IsA("BasePart") then
				local depth = (head.Position - cf.Position):Dot(cf.LookVector)
				local want = TAG_HOME
				if depth > 0.5 then
					local perPx = depth / k -- studs per pixel at the head
					-- over the fighter's name and bars: their bottom over the head, their height on screen
					if vitalsTop then
						local over, px = vitalsTop(t.Char)
						if px > 0 then
							want = math.max(want, over + (px + TAG_GAP + HALF) * perPx)
						end
					end
					local hit = head:FindFirstChild("HitTag")
					if hit and hit:IsA("BillboardGui") and hit.Enabled then
						-- (its line where it is right now: a closing tag glides up as it fades; its real
						-- top - the title risen over a punched number - at its real size on screen)
						local topPx = (hit:GetAttribute("TopPx") or HIT_TOP) * (hit:GetAttribute("Fit") or 1)
						want = math.max(want, math.max(HIT_LINE, hit.StudsOffset.Y) + hit.StudsOffsetWorldSpace.Y + (topPx + TAG_GAP + HALF) * perPx)
					end
					local sp = cam:WorldToViewportPoint(head.Position)
					-- a neighbour's hit tag in the way: over it
					local half = (if t.Pill and t.Pill.Width and t.Pill.Width > 0 then t.Pill.Width else 300) * TAG_SCALE * 0.5
					for _, r in ipairs(hitRects) do
						if r.Head ~= head and math.abs(r.X - sp.X) < r.Half + half then
							want = math.max(want, (sp.Y - (r.Top - TAG_GAP - HALF)) * perPx)
						end
					end
					-- never under the top bar or off the top of the screen (a fighter close to the camera)
					local room = (sp.Y - inset.Y - 6 - HALF) * perPx
					if room > TAG_HOME * 0.5 then
						want = math.min(want, room)
					end
				end
				local cur = t.Lift
				if not cur then
					-- (a new tag starts where it belongs)
					t.Lift = want
					bb.StudsOffset = Vector3.new(0, want, 0)
				elseif math.abs(want - cur) > 1e-3 then
					-- up at once (the hit tag's letters come in fast), down gently
					cur += (want - cur) * (if want > cur then rise else ease)
					t.Lift = cur
					bb.StudsOffset = Vector3.new(0, cur, 0)
				end
			end
		end
	end)
end
