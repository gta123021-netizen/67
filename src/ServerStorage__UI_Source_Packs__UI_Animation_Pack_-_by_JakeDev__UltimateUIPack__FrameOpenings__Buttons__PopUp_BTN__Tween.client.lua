--// This is a PopUp Opening Effect, the frame will popup and popout when button is clicked.

local btn = script.Parent
local frame = btn.Parent.Parent.Frames.PopUp_FRM
local closeBtn = frame.Close
local TS = game:GetService("TweenService")

local origSize = frame.Size
local tInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local isOpen = false

frame.Size = UDim2.new(0, 0, 0, 0)
frame.BackgroundTransparency = 1

local function makeTween(scl, alpha)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(frame, tInfo, {Size = newSize, BackgroundTransparency = alpha})
end

local function popIn()
	frame.Visible = true
	makeTween(1, 0):Play()
	isOpen = true
end

local function popOut()
	local tween = makeTween(0, 1)
	tween:Play()
	tween.Completed:Connect(function()
		frame.Visible = false
		isOpen = false
	end)
end

btn.MouseButton1Click:Connect(function()
	if isOpen then
		popOut()
	else
		popIn()
	end
end)

closeBtn.MouseButton1Click:Connect(function()
	popOut()
end)