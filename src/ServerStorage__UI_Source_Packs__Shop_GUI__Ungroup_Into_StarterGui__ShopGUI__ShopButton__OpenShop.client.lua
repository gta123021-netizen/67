--Made By @roary16
local TweenService = game:GetService("TweenService")
local frame = script.Parent
local screenGui = frame.Parent
local shopFrame = screenGui:WaitForChild("ShopFrame")

local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local originalSize = shopFrame.Size
local hiddenSize = UDim2.new(0, 0, 0, 0)

shopFrame.Size = hiddenSize
shopFrame.Visible = false

frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if not shopFrame.Visible then
			shopFrame.Size = hiddenSize
			shopFrame.Visible = true
			TweenService:Create(shopFrame, info, {Size = originalSize}):Play()
		else
			local closeTween = TweenService:Create(shopFrame, info, {Size = hiddenSize})
			closeTween:Play()
			closeTween.Completed:Connect(function()
				if shopFrame.Size == hiddenSize then
					shopFrame.Visible = false
				end
			end)
		end
	end
end)