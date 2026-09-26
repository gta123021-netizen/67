--[[
	TouchControls  (StarterPlayerScripts.CombatClient.TouchControls)
	Phone/tablet buttons for the same actions the keyboard and mouse have: ATTACK (M1 - hold to keep
	the chain going), HEAVY (M2 - the uppercut, once per combo), BLOCK (hold) and DASH (direction
	from the thumbstick). They sit in an arc round Roblox's
	jump button, sized from it, in the HUD's own style, and only show while touch is the active input
	and nothing else owns the screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local Touch = {}

local function jumpFrame(screen: Vector2): (Vector2, number)
	-- Roblox's TouchJump layout
	local small = math.min(screen.X, screen.Y) <= 500
	local size = if small then 70 else 120
	local x = screen.X - (size * 1.5 - 10)
	local y = if small then screen.Y - size - 20 else screen.Y - size * 1.75
	return Vector2.new(x + size / 2, y + size / 2), size
end

function Touch.Start(api: any)
	local Theme, Kit
	local ok = pcall(function()
		local UI = ReplicatedStorage:WaitForChild("OverkillUI", 10)
		Theme = require(UI:WaitForChild("Theme"))
		Kit = require(UI:WaitForChild("Kit"))
	end)
	local C = if ok and Theme then Theme.C else nil

	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatTouch"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local buttons = {}
	-- onDown gets the touch that pressed the button (a held ATTACK is let go when THAT finger lifts,
	-- even off the button)
	local function makeButton(name: string, label: string, colors: { Color3 }, onDown: (InputObject?) -> (), onUp: (() -> ())?)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Text = ""
		b.AutoButtonColor = false
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.BackgroundColor3 = Color3.new(1, 1, 1)
		b.BackgroundTransparency = 0.05
		b.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = b
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = if C then C.Ink else Color3.new(0, 0, 0)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = b
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new(colors[1], colors[2])
		g.Rotation = 90
		g.Parent = b
		local scale = Instance.new("UIScale")
		scale.Parent = b
		local txt: TextLabel
		if Kit then
			txt = Kit.text({ Name = "Label", Text = label, TextSize = 16, TextScaled = false, ZIndex = 2, Parent = b })
		else
			txt = Instance.new("TextLabel")
			txt.BackgroundTransparency = 1
			txt.Size = UDim2.fromScale(1, 1)
			txt.Text = label
			txt.TextColor3 = Color3.new(1, 1, 1)
			txt.Parent = b
		end
		local down: InputObject? = nil
		local function lift()
			if down then
				down = nil
				TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1 }):Play()
				if onUp then
					onUp()
				end
			end
		end
		b.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				if down then
					return -- a second finger on the same button is not a second press
				end
				down = input
				TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.9 }):Play()
				onDown(input)
			end
		end)
		b.InputEnded:Connect(function(input)
			if input == down then
				lift()
			end
		end)
		-- the finger slid off the button before lifting: the button never hears the end, the screen does
		UserInputService.TouchEnded:Connect(function(input)
			if input == down then
				lift()
			end
		end)
		buttons[name] = { Button = b, Label = txt, Release = function()
			if down then
				down = nil
				scale.Scale = 1
				if onUp then
					onUp()
				end
			end
		end }
		return b
	end

	local red = if C then { C.Red, C.RedDeep } else { Color3.fromRGB(255, 86, 96), Color3.fromRGB(196, 36, 58) }
	local blue = if C then { C.Blue, C.BlueDeep } else { Color3.fromRGB(76, 188, 255), Color3.fromRGB(30, 116, 226) }
	local teal = if C then { C.Teal, C.TealDeep } else { Color3.fromRGB(64, 220, 200), Color3.fromRGB(20, 146, 156) }
	local gold = if C then { C.Gold, C.GoldDeep } else { Color3.fromRGB(255, 212, 64), Color3.fromRGB(236, 146, 20) }
	makeButton("Attack", "ATTACK", red, api.M1Down, api.M1Up)
	makeButton("Heavy", "HEAVY", gold, api.Heavy, nil)
	makeButton("Block", "BLOCK", blue, api.BlockDown, api.BlockUp)
	makeButton("Dash", "DASH", teal, api.Dash, nil)

	local function layout()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local screen = cam.ViewportSize
		local center, size = jumpFrame(screen)
		local a = size * 1.05
		local s = size * 0.78
		local place = {
			Attack = { center + Vector2.new(-size * 1.28, -size * 0.12), a, 0.2 },
			Block = { center + Vector2.new(-size * 1.02, -size * 1.22), s, 0.22 },
			Dash = { center + Vector2.new(size * 0.08, -size * 1.28), s, 0.22 },
			Heavy = { center + Vector2.new(-size * 2.26, -size * 0.5), s, 0.22 },
		}
		for name, p in pairs(place) do
			local b = buttons[name]
			b.Button.Position = UDim2.fromOffset(p[1].X, p[1].Y)
			b.Button.Size = UDim2.fromOffset(p[2], p[2])
			b.Label.TextSize = math.floor(p[2] * p[3])
		end
	end

	local function refresh()
		local show = UserInputService.TouchEnabled
			and UserInputService:GetLastInputType() == Enum.UserInputType.Touch
			and player:GetAttribute("QuestUIOpen") ~= true
			and player:GetAttribute("UIOverlay") == nil
			and player:GetAttribute("UIWindow") == nil
		if gui.Enabled and not show then
			for _, b in pairs(buttons) do
				b.Release()
			end
		end
		gui.Enabled = show
		if show then
			layout()
		end
	end

	UserInputService.LastInputTypeChanged:Connect(refresh)
	for _, attr in ipairs({ "QuestUIOpen", "UIOverlay", "UIWindow" }) do
		player:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	refresh()
end

return Touch
