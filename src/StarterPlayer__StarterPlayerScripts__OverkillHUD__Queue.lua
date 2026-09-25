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
	-- round head picture with a coloured ring; practice bots get a letter disc
	function Q.Avatar(parent: Instance, view: any, size: number, ring: Color3, z: number)
		local holder = new("Frame", {
			Name = "Avatar",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.fromOffset(size, size),
			ZIndex = z,
			Parent = parent,
		})
		Kit.pill(holder)
		Kit.stroke(holder, math.max(2.5, size * 0.045), C.Ink, 0, true)
		local ringGrad = Kit.gradient(holder, Kit.lighten(ring, 0.12), Kit.darken(ring, 0.3), 90)
		local inset = math.max(3, math.floor(size * 0.07))
		local inner = new("Frame", {
			Name = "Inner",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Position = UDim2.fromOffset(inset, inset),
			Size = UDim2.new(1, -inset * 2, 1, -inset * 2),
			ZIndex = z,
			Parent = holder,
		})
		Kit.pill(inner)
		Kit.gradient(inner, C.Navy500, C.Night, 90)
		if view.Bot or (view.UserId or 0) <= 0 then
			Kit.text({
				Name = "Letter",
				Text = string.upper(string.sub(view.DisplayName or "?", 1, 1)),
				TextSize = math.floor(size * 0.46),
				ZIndex = z + 1,
				Stroke = math.max(2, size * 0.04),
				Parent = inner,
			})
		else
			local img = Kit.image({
				Name = "Head",
				Image = Theme.Headshot(view.UserId),
				ScaleType = Enum.ScaleType.Crop,
				ZIndex = z + 1,
				Parent = inner,
			})
			Kit.pill(img)
		end
		local api = { Frame = holder }
		function api.SetRing(c: Color3)
			ringGrad.Color = ColorSequence.new(Kit.lighten(c, 0.12), Kit.darken(c, 0.3))
		end
		return api
	end

	-- rounded mode badge: "1V1", "2V2", "FFA" in the mode colour
	function Q.Badge(parent: Instance, modeId: string, size: number, z: number)
		local m = Config.Modes[modeId] or Config.Modes.Duel
		local r = math.floor(size * 0.3)
		local b = new("Frame", {
			Name = "ModeBadge",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.fromOffset(size, size),
			ZIndex = z,
			Parent = parent,
		})
		Kit.corner(b, r)
		Kit.stroke(b, math.max(3, size * 0.055), C.Ink, 0, true)
		local grad = Kit.gradient(b, Kit.lighten(m.Color, 0.12), m.Deep, 90)
		Kit.bevel(b, math.max(4, r - 3), 3, z)
		local label = Kit.text({
			Name = "Text",
			Text = m.Badge,
			TextSize = math.floor(size * (if #m.Badge > 3 then 0.3 else 0.36)),
			ZIndex = z + 2,
			Stroke = math.max(2.4, size * 0.05),
			Parent = b,
		})
		local api = { Frame = b }
		function api.Set(id: string)
			local mm = Config.Modes[id]
			if mm then
				grad.Color = ColorSequence.new(Kit.lighten(mm.Color, 0.12), mm.Deep)
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
