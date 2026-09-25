--Made By @roary16
local TweenService = game:GetService("TweenService")
local frame = script.Parent

local hoverSound = Instance.new("Sound")
hoverSound.Parent = frame
hoverSound.SoundId = "rbxassetid://139800881181209"
hoverSound.Volume = 0.5

local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local defaultSize = frame.Size
local hoveredSize = UDim2.new(defaultSize.X.Scale, defaultSize.X.Offset + 20, defaultSize.Y.Scale, defaultSize.Y.Offset + 20)

local defaultColor = frame.BackgroundColor3
local hoveredColor = Color3.fromRGB(200, 200, 200)

local enterTween = TweenService:Create(frame, info, {Size = hoveredSize, BackgroundColor3 = hoveredColor})
local leaveTween = TweenService:Create(frame, info, {Size = defaultSize, BackgroundColor3 = defaultColor})

frame.MouseEnter:Connect(function()
	hoverSound:Play()
	enterTween:Play()
end)

frame.MouseLeave:Connect(function()
	leaveTween:Play()
end)