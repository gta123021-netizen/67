--[[
	Queue  (StarterPlayerScripts.OverkillHUD.Queue)
	Client side of the queue + party system. Talks to QueueServer, keeps the latest snapshot and
	hands the queue card, match screen and party window the pieces they share:
	round avatars, mode badges, chimes and themed toasts.

	ctx.Queue.State    latest private snapshot { Queue, Party, Invites, Match, Dodge, Bots, You, Time }
	ctx.Queue.Counts   players searching per mode (public)
	ctx.Queue.Waits    average wait per mode in seconds (public, may be nil)
	events: "QueueState"(new, old), "QueueCounts", "QueueCancelled"(info), "QueuePulse"(mode)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new = Kit.new

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local Config = require(UI:WaitForChild("QueueConfig"))
	local Remotes = UI:WaitForChild("Remotes")
	local Request = Remotes:WaitForChild("QueueRequest") :: RemoteFunction
	local Event = Remotes:WaitForChild("QueueEvent") :: RemoteEvent

	local Q: any = { Config = Config, State = { Invites = {} }, Counts = {}, Waits = {} }
	ctx.Queue = Q

	function Q.Now(): number
		return workspace:GetServerTimeNow()
	end
	Q.Clock = Config.Clock

	function Q.Mode(id: string?)
		return Config.Modes[id or ""]
	end

	---------------------------------------------------------------------------
	-- state
	---------------------------------------------------------------------------
	local function apply(s: any)
		if type(s) ~= "table" then
			return
		end
		local old = Q.State
		-- never let an older snapshot overwrite a newer one
		if old.Time and s.Time and s.Time < old.Time then
			return
		end
		s.Invites = s.Invites or {}
		Q.State = s
		ctx.Fire("QueueState", s, old)
	end

	function Q.Request(action: string, a: any?, b: any?)
		task.spawn(function()
			local ok, s = pcall(function()
				return Request:InvokeServer(action, a, b)
			end)
			if ok then
				apply(s)
			end
		end)
	end

	local function readCounts()
		for _, id in ipairs(Config.Order) do
			Q.Counts[id] = UI:GetAttribute("Queue_" .. id) or 0
			Q.Waits[id] = UI:GetAttribute("QueueWait_" .. id)
		end
		ctx.Fire("QueueCounts")
	end
	UI.AttributeChanged:Connect(function(name: string)
		if string.sub(name, 1, 5) == "Queue" then
			readCounts()
		end
	end)
	readCounts()

	---------------------------------------------------------------------------
	-- sound: short arpeggios on the built-in ping (goes through the SFX volume slider)
	---------------------------------------------------------------------------
	local NOTES = {
		found = { 1, 1.26, 1.5, 2 },
		invite = { 1.26, 1.68 },
		accept = { 1.5, 2 },
		ready = { 1, 1.26, 1.5, 1.26, 2 },
		tick = { 2.3 },
		go = { 2 },
		cancel = { 1.26, 0.94 },
		join = { 1.12, 1.5 },
	}
	local voices: { Sound } = {}
	function Q.Chime(kind: string)
		local notes = NOTES[kind]
		if not notes then
			return
		end
		for i, speed in ipairs(notes) do
			task.delay((i - 1) * 0.085, function()
				local s = voices[i]
				if not s then
					s = new("Sound", {
						Name = "QueueChime" .. i,
						SoundId = "rbxasset://sounds/electronicpingshort.wav",
						Volume = 0.34,
						SoundGroup = SoundService:FindFirstChild("SFX"),
						Parent = SoundService,
					})
					voices[i] = s
				end
				s.PlaybackSpeed = speed
				pcall(function()
					SoundService:PlayLocalSound(s)
				end)
			end)
		end
	end

	---------------------------------------------------------------------------
	-- shared pieces
	---------------------------------------------------------------------------
	-- round head picture with a coloured ring; practice bots get a letter disc.
	-- slot = { Side = "Left" | "Right" | "TopLeft", Gap, Band (paint) or Bands (layers), Width }:
	-- the avatar is built as rings on a slot that is that whole end of `parent` (Kit.endIcon), so
	-- its gap to the parent's edges is exactly the same on every side it touches. Without a slot
	-- it is a free-standing disc of `size`.
	function Q.Avatar(parent: Instance, view: any, size: number, ring: Color3, z: number, slot: any?)
		local ink = math.max(2.5, size * 0.045) * 1.35
		local inset = math.max(3, math.floor(size * 0.07))
		local ringPaint = { Kit.lighten(ring, 0.12), Kit.darken(ring, 0.3), 90 }
		local holder: GuiObject
		local ringGrad: UIGradient?
		local gap = if slot then slot.Gap else 0
		if slot then
			holder = Kit.slot({ Parent = parent :: GuiObject, Side = slot.Side, Width = slot.Width or (size + gap * 2), Height = slot.Height or (size + gap * 2), Name = "Avatar", ZIndex = z })
		else
			holder = new("Frame", { Name = "Avatar", Size = UDim2.fromOffset(size, size), ZIndex = z, Parent = parent })
		end
		holder.BackgroundTransparency = 0
		Kit.pill(holder)
		Kit.paint(holder, { C.Navy500, C.Night, 90 })
		-- the head (or letter) reaches in under the coloured ring, so its own edge never shows
		local head = new("Frame", {
			Name = "Inner",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size - inset * 2 + 3, size - inset * 2 + 3),
			ZIndex = z + 1,
			Parent = holder,
		})
		Kit.pill(head)
		if view.Bot or (view.UserId or 0) <= 0 then
			Kit.text({
				Name = "Letter",
				Text = string.upper(string.sub(view.DisplayName or "?", 1, 1)),
				TextSize = math.floor(size * 0.46),
				ZIndex = z + 4,
				Stroke = math.max(2, size * 0.04),
				Parent = holder,
			})
		else
			local img = Kit.image({
				Name = "Head",
				Image = Theme.Headshot(view.UserId),
				ScaleType = Enum.ScaleType.Crop,
				ZIndex = z + 1,
				Parent = head,
			})
			Kit.pill(img)
		end
		-- rings from the outside in: the gap (in the parent's colours), ink, the coloured ring
		local bands = {}
		if slot and gap - ink / 2 > 0 then
			table.insert(bands, { gap - ink / 2, "GAP" })
		end
		-- in a slot the whole outline is inside the slot; a free disc's outline is half outside
		-- its edge (its own border stroke below), so only the inner half is a ring here
		table.insert(bands, { if slot then ink else ink / 2, C.Ink })
		table.insert(bands, { inset - ink / 2, ringPaint })
		local list = {}
		local depth = 0
		for _, b in ipairs(bands) do
			depth += b[1]
		end
		-- innermost first; the gap goes on last, one stroke per background layer
		local d = depth
		for i = #bands, 1, -1 do
			if bands[i][2] ~= "GAP" then
				table.insert(list, { d, bands[i][2] })
			end
			d -= bands[i][1]
		end
		if slot and gap - ink / 2 > 0 then
			local layers = slot.Bands or { { Paint = slot.Band or C.Navy700 } }
			for _, layer in ipairs(layers) do
				table.insert(list, { gap - ink / 2, layer.Paint, layer.Transparency })
			end
			-- and the seam over the slot's edge (no trace of the rings beside the name)
			for _, spec in ipairs(Kit.seams(layers)) do
				table.insert(list, spec)
			end
		end
		local _, grads = Kit.edgeStrokes(holder, UDim.new(1, 0), list, z + 2)
		ringGrad = grads[1]
		if not slot then
			-- a free disc: the ink outline half outside its edge as well, like every other outline,
			-- over the rings (it covers their outer edge whole)
			Kit.stroke(holder, math.max(2.5, size * 0.045), C.Ink, 0, true)
			Kit.outlineOnTop(holder, z + 3)
		end
		local api = { Frame = holder }
		function api.SetRing(c: Color3)
			if ringGrad then
				ringGrad.Color = ColorSequence.new(Kit.lighten(c, 0.12), Kit.darken(c, 0.3))
			end
		end
		return api
	end

	-- rounded mode badge: "1V1", "2V2", "FFA" in the mode colour. slot: as for Q.Avatar (the
	-- badge as rings on that whole end of `parent`, the same gap on every side it touches).
	function Q.Badge(parent: Instance, modeId: string, size: number, z: number, slot: any?)
		local m = Config.Modes[modeId] or Config.Modes.Duel
		local r = math.floor(size * 0.3)
		local stroke = math.max(3, size * 0.055)
		local b: GuiObject
		local grad: UIGradient?
		if slot then
			local icon = Kit.endIcon({
				Parent = parent,
				Name = "ModeBadge",
				Side = slot.Side,
				Width = slot.Width or (size + slot.Gap * 2),
				Height = slot.Height or (size + slot.Gap * 2),
				Gap = slot.Gap,
				Stroke = stroke,
				Corner = r,
				Band = slot.Band,
				Bands = slot.Bands,
				Face = { Kit.lighten(m.Color, 0.12), m.Deep, 90 },
				ZIndex = z,
			})
			b, grad = icon.Frame, icon.Face
		else
			b = new("Frame", {
				Name = "ModeBadge",
				BackgroundColor3 = Color3.new(1, 1, 1),
				Size = UDim2.fromOffset(size, size),
				ZIndex = z,
				Parent = parent,
			})
			Kit.corner(b, r)
			Kit.stroke(b, stroke, C.Ink, 0, true)
			grad = Kit.gradient(b, Kit.lighten(m.Color, 0.12), m.Deep, 90)
		end
		local label = Kit.text({
			Name = "Text",
			Text = m.Badge,
			TextSize = math.floor(size * (if #m.Badge > 3 then 0.3 else 0.36)),
			ZIndex = z + 3,
			Stroke = math.max(2.4, size * 0.05),
			Parent = b,
		})
		local api = { Frame = b }
		function api.Set(id: string)
			local mm = Config.Modes[id]
			if mm then
				if grad then
					grad.Color = ColorSequence.new(Kit.lighten(mm.Color, 0.12), mm.Deep)
				end
				label.Text = mm.Badge
			end
		end
		return api
	end

	-- small rounded chip with outlined text (status tags)
	function Q.Chip(parent: Instance, text: string, color: Color3, deep: Color3, height: number, z: number)
		local chip = Kit.plate({
			Name = "Chip",
			Parent = parent,
			Size = UDim2.new(0, 0, 0, height),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = UDim.new(1, 0),
			Stroke = 2.6,
			ZIndex = z,
			Gradient = { Kit.lighten(color, 0.08), deep },
		})
		Kit.padding(chip, math.floor(height * 0.42), 0, math.floor(height * 0.42), 0)
		local t = Kit.text({
			Text = text,
			TextSize = math.floor(height * 0.56),
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = z + 1,
			Stroke = 2.2,
			Parent = chip,
		})
		local api = { Frame = chip, Label = t }
		function api.Set(txt: string, c: Color3?, d: Color3?)
			t.Text = txt
			if c and d then
				local g = chip:FindFirstChildOfClass("UIGradient")
				if g then
					g.Color = ColorSequence.new(Kit.lighten(c, 0.08), d)
				end
			end
		end
		return api
	end

	---------------------------------------------------------------------------
	-- server messages
	---------------------------------------------------------------------------
	local KIND = {
		error = { C.Red, C.RedDeep, "close" },
		party = { C.Teal, C.TealDeep, Theme.Icon.Party },
		good = { C.Green, C.GreenDeep, Theme.Icon.Check },
	}
	local function notice(n: any)
		if type(n) ~= "table" then
			return
		end
		local style = KIND[n.Kind]
		local color, deep, icon
		if style then
			color, deep, icon = style[1], style[2], style[3]
		else
			local m = Config.Modes[n.Mode or ""]
			color = if m then m.Color else C.Blue
			deep = if m then m.Deep else C.BlueDeep
			icon = Theme.Icon.Info
		end
		ctx.Toast({
			Title = tostring(n.Title or ""),
			Text = tostring(n.Text or ""),
			Icon = if icon ~= "close" then icon else nil,
			Glyph = if icon == "close" then "close" else nil,
			Color = color,
			Deep = deep,
			Time = 3.2,
		})
		if n.Kind == "error" then
			Kit.sfx("Error")
		elseif n.Kind == "party" then
			Q.Chime("invite")
		end
	end

	Event.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "State" then
			apply(data)
		elseif kind == "Notice" then
			notice(data)
		elseif kind == "Cancelled" then
			ctx.Fire("QueueCancelled", data)
		elseif kind == "Pulse" then
			ctx.Fire("QueuePulse", data)
		elseif kind == "Invited" then
			Q.Chime("invite")
		end
	end)

	Q.Request("state")

	-- a quest dialogue pauses your search so a match never pops up over it
	local player = ctx.Player
	local function syncBusy()
		Q.Request("busy", player:GetAttribute("QuestUIOpen") == true)
	end
	player:GetAttributeChangedSignal("QuestUIOpen"):Connect(syncBusy)
	if player:GetAttribute("QuestUIOpen") == true then
		syncBusy()
	end
end
