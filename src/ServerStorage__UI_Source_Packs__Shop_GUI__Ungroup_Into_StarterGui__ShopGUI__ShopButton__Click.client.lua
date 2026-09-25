--Made By @roary16
local TweenService = game:GetService("TweenService")
local frame = script.Parent

frame.Active = true

local clickSound = Instance.new("Sound")
clickSound.Parent = frame
clickSound.SoundId = "rbxassetid://113457728400315"
clickSound.Volume = 0.5

local info = TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local defaultSize = frame.Size
local pressedSize = UDim2.new(defaultSize.X.Scale, defaultSize.X.Offset - 10, defaultSize.Y.Scale, defaultSize.Y.Offset - 10)

local pressTween = TweenService:Create(frame, info, {
	Size = pressedSize,
	Rotation = 2
})

local releaseTween = TweenService:Create(frame, info, {
	Size = defaultSize,
	Rotation = 0
})

frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		clickSound:Play()
		pressTween:Play()
	end
end)

frame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		releaseTween:Play()
	end
end)