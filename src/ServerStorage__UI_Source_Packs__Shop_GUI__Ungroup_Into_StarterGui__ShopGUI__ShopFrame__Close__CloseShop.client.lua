--Made By @roary16
local TweenService = game:GetService("TweenService")
local closeButton = script.Parent
local shopFrame = closeButton.Parent

local clickSound = Instance.new("Sound")
clickSound.Parent = closeButton
clickSound.SoundId = "rbxassetid://113457728400315"
clickSound.Volume = 0.5

local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local hiddenSize = UDim2.new(0, 0, 0, 0)

closeButton.MouseButton1Click:Connect(function()
	clickSound:Play()

	local closeTween = TweenService:Create(shopFrame, info, {Size = hiddenSize})
	closeTween:Play()

	closeTween.Completed:Connect(function()
		shopFrame.Visible = false
	end)
end)