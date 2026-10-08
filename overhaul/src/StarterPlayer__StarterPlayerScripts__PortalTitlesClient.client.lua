--[[
	PortalTitlesClient  (StarterPlayer.StarterPlayerScripts.PortalTitlesClient)
	Portal dressing, all on the client:
	  - the 1v1 / ARENA / 2v2 titles bob gently (looping tweens: the engine animates them, no script loop)
	  - a status pill under each title: JOIN QUEUE / 3 SEARCHING / IN QUEUE (public queue counts)
	  - soft sparkles drifting up through each doorway in the mode colour
	  - the portal you're queued for breathes its light, and flashes when you walk in
	Outlines only update when a title's on-screen size changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local portals = workspace:WaitForChild("Portals", 60)
if not portals then
	return
end
local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local Theme = require(UI:WaitForChild("Theme"))
local Config = require(UI:WaitForChild("QueueConfig"))
local C = Theme.C

local PHASE = { PortalTitle_1V1 = 0, PortalTitle_ARENA = 0.9, PortalTitle_2V2 = 1.8 } -- seconds, so they drift out of step
local TITLE_MODE = { PortalTitle_1V1 = "Duel", PortalTitle_2V2 = "Duos", PortalTitle_ARENA = "Arena" }
local BOB = TweenInfo.new(2.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local TITLE_H = 2.9 -- studs (the title's original height)
local PILL_H = 1.15
local BB_H = TITLE_H + PILL_H + 0.2
local BASE_Y = 0.55 -- lifts the whole sign so the pill clears the portal frame

---------------------------------------------------------------------------
-- portal models -> mode, doorway pane, light
---------------------------------------------------------------------------
local doors: { [string]: any } = {}
local function scanDoor(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local modeId = model:GetAttribute("QueueMode")
	if not modeId then
		for id, m in pairs(Config.Modes) do
			if m.Portal == model.Name then
				modeId = id
			end
		end
	end
	local have = modeId and doors[modeId]
	if not modeId or not Config.Modes[modeId] or (have and have.Pane.Parent) then
		return -- already dressed (and still streamed in)
	end
	local pane: BasePart? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency > 0.3 and (not pane or d.Size.Magnitude > (pane :: BasePart).Size.Magnitude) then
			pane = d
		end
	end
	if not pane then
		return
	end
	local light = pane:FindFirstChildOfClass("PointLight")
	local m = Config.Modes[modeId]
	local fx = Instance.new("ParticleEmitter")
	fx.Name = "QueueSparkles"
	fx.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	fx.Color = ColorSequence.new(Color3.new(1, 1, 1), m.Color)
	fx.LightEmission = 1
	fx.LightInfluence = 0
	fx.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 0.32),
		NumberSequenceKeypoint.new(1, 0),
	})
	fx.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	fx.Lifetime = NumberRange.new(1.6, 2.8)
	fx.Rate = 6
	fx.Speed = NumberRange.new(0.2, 0.8)
	fx.SpreadAngle = Vector2.new(180, 180)
	fx.Acceleration = Vector3.new(0, 1.2, 0)
	fx.Drag = 0.6
	fx.Rotation = NumberRange.new(0, 360)
	fx.RotSpeed = NumberRange.new(-60, 60)
	fx.Shape = Enum.ParticleEmitterShape.Box
	fx.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	fx.Parent = pane
	doors[modeId] = {
		Mode = modeId,
		Pane = pane,
		Light = light,
		Brightness = if light then light.Brightness else 5,
		Range = if light then light.Range else 8,
		Sparkles = fx,
		Pulse = nil,
	}
end
-- the place streams: portal parts can arrive (or come back) after this script starts
for _, child in ipairs(portals:GetChildren()) do
	scanDoor(child)
end
local rescanning = false
portals.DescendantAdded:Connect(function(d)
	if rescanning or not d:IsA("BasePart") then
		return
	end
	rescanning = true
	task.delay(0.3, function()
		rescanning = false
		for _, child in ipairs(portals:GetChildren()) do
			scanDoor(child)
		end
	end)
end)

---------------------------------------------------------------------------
-- signs: bob + status pill
---------------------------------------------------------------------------
local signs: { [string]: any } = {}

local function fitStroke(label: GuiObject, stroke: UIStroke?, k: number, lo: number, hi: number)
	if not stroke then
		return
	end
	local function fit()
		stroke.Thickness = math.clamp(label.AbsoluteSize.Y * k, lo, hi)
	end
	label:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
end

local function add(anchor: Instance)
	local bb = anchor:FindFirstChildOfClass("BillboardGui")
	local label = bb and bb:FindFirstChild("Title")
	if not (bb and label and label:IsA("TextLabel")) or bb:GetAttribute("Dressed") then
		return
	end
	bb:SetAttribute("Dressed", true)
	local modeId = TITLE_MODE[anchor.Name]
	local m = modeId and Config.Modes[modeId]

	-- grow the sign downward for the pill; the title keeps its size in studs
	bb.Size = UDim2.new(bb.Size.X.Scale, 0, BB_H, 0)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.fromScale(1, TITLE_H / BB_H)
	fitStroke(label, label:FindFirstChildOfClass("UIStroke"), 0.05, 1.5, 7)

	bb.StudsOffset = Vector3.new(0, BASE_Y - 0.4, 0)
	task.delay(PHASE[anchor.Name] or 0, function()
		TweenService:Create(bb, BOB, { StudsOffset = Vector3.new(0, BASE_Y + 0.4, 0) }):Play()
	end)

	if not m then
		return
	end
	local pill = Instance.new("Frame")
	pill.Name = "Status"
	pill.AnchorPoint = Vector2.new(0.5, 1)
	pill.Position = UDim2.fromScale(0.5, 1)
	pill.Size = UDim2.fromScale(0.5, PILL_H / BB_H)
	pill.BackgroundColor3 = Color3.new(1, 1, 1)
	pill.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = pill
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(m.Color:Lerp(Color3.new(1, 1, 1), 0.12), m.Deep)
	grad.Parent = pill
	local rim = Instance.new("UIStroke")
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Color = C.Ink
	rim.LineJoinMode = Enum.LineJoinMode.Round
	rim.Parent = pill
	fitStroke(pill, rim, 0.075, 1, 5)
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.52)
	text.Size = UDim2.fromScale(0.86, 0.62)
	text.FontFace = Theme.Font.Display
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = "JOIN QUEUE"
	text.Parent = pill
	local ts = Instance.new("UIStroke")
	ts.Color = C.Ink
	ts.LineJoinMode = Enum.LineJoinMode.Round
	ts.Parent = text
	fitStroke(pill, ts, 0.06, 1, 4)
	local scale = Instance.new("UIScale")
	scale.Parent = pill
	signs[modeId] = { Mode = modeId, Text = text, Grad = grad, Scale = scale, Pulse = nil, State = "" }
end

for _, child in ipairs(portals:GetChildren()) do
	if child.Name:sub(1, 12) == "PortalTitle_" then
		add(child)
	end
end
local refresh: () -> ()
portals.ChildAdded:Connect(function(child)
	if child.Name:sub(1, 12) == "PortalTitle_" then
		task.wait()
		add(child)
		refresh() -- a sign that streams in late shows the live count straight away
	end
end)

---------------------------------------------------------------------------
-- live state
---------------------------------------------------------------------------
function refresh()
	local mine = player:GetAttribute("OKQueue")
	for id, s in pairs(signs) do
		local m = Config.Modes[id]
		local n = UI:GetAttribute("Queue_" .. id) or 0
		local state = if mine == id then "mine" elseif n > 0 then "busy" else "idle"
		s.Text.Text = if state == "mine" then "IN QUEUE" elseif state == "busy" then ("%d SEARCHING"):format(n) else "JOIN QUEUE"
		if state ~= s.State then
			s.State = state
			if state == "mine" then
				s.Grad.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(m.Color, 0.25), m.Color)
				s.Text.TextColor3 = Color3.new(1, 1, 1)
				s.Pulse = TweenService:Create(s.Scale, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.1 })
				s.Pulse:Play()
			else
				if s.Pulse then
					s.Pulse:Cancel()
					s.Pulse = nil
				end
				s.Scale.Scale = 1
				s.Grad.Color = ColorSequence.new(m.Color:Lerp(Color3.new(1, 1, 1), 0.12), m.Deep)
			end
		end
	end
	-- the queued portal's light breathes; walking in flashes it
	for id, d in pairs(doors) do
		local light = d.Light
		if light then
			if mine == id and d.Pulse == nil then
				light.Brightness = d.Brightness * 3
				light.Range = d.Range * 1.6
				d.Sparkles:Emit(26)
				TweenService:Create(light, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Brightness = d.Brightness, Range = d.Range }):Play()
				task.delay(0.5, function()
					if d.Pulse == false and player:GetAttribute("OKQueue") == id then
						local tw = TweenService:Create(light, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Brightness = d.Brightness * 1.9, Range = d.Range * 1.35 })
						d.Pulse = tw
						tw:Play()
					end
				end)
				d.Pulse = false -- flashing, pulse starts after
			elseif mine ~= id and d.Pulse ~= nil then
				if d.Pulse then
					d.Pulse:Cancel()
				end
				d.Pulse = nil
				TweenService:Create(light, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Brightness = d.Brightness, Range = d.Range }):Play()
			end
		end
		d.Sparkles.Rate = if mine == id then 16 else 6
	end
end

UI.AttributeChanged:Connect(function(name: string)
	if string.sub(name, 1, 6) == "Queue_" then
		refresh()
	end
end)
player:GetAttributeChangedSignal("OKQueue"):Connect(refresh)
refresh()
