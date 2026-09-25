--Made By @roary16
local label = script.Parent
local TweenService = game:GetService("TweenService")

label.Active = true

local clickSound = Instance.new("Sound")
clickSound.Parent = label
clickSound.SoundId = "rbxassetid://90284284772342"
clickSound.Volume = 0.5

local info = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local pressTween = TweenService:Create(label, info, {Rotation = 3})
local releaseTween = TweenService:Create(label, info, {Rotation = 0})

label.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		clickSound:Play()
		pressTween:Play()
	end
end)

label.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		releaseTween:Play()
	end
end)