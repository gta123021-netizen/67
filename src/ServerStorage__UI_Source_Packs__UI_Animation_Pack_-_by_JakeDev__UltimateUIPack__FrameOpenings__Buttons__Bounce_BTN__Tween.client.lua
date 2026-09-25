--// This is a Bounce Opening Effect, the frame will Popup bouncing and popout when button is clicked.

local btn = script.Parent
local frame = btn.Parent.Parent.Frames.Bounce_FRM
local X = frame.Close
local TS = game:GetService("TweenService")

local origSize = frame.Size
local tInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
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
	local tweens = {
		makeTween(1.2, 0),
		makeTween(0.8, 0),
		makeTween(1, 0)
	}
	tweens[1]:Play()
	for i = 1, #tweens - 1 do
		tweens[i].Completed:Connect(function()
			tweens[i + 1]:Play()
		end)
	end
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

X.MouseButton1Click:Connect(function()
	popOut()
end)