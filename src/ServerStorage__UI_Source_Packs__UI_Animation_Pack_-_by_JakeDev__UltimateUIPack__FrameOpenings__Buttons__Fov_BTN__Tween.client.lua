--// This is a Fov Opening Effect, The player fov will increase and screen blurs when the frame is opened.


local btn = script.Parent
local frame = btn.Parent.Parent.Frames.Fov_FRM
local closeBtn = frame.Close
local TS = game:GetService("TweenService")
local cam = game.Workspace.CurrentCamera

local origSize = frame.Size
local origFov = cam.FieldOfView
local blur = Instance.new("BlurEffect")
blur.Size = 0
blur.Parent = game.Lighting
local tInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local isOpen = false

frame.Size = UDim2.new(0, 0, 0, 0)
frame.BackgroundTransparency = 1

local function makeFrameTween(scl, alpha)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(frame, tInfo, {Size = newSize, BackgroundTransparency = alpha})
end

local function makeCamTween(fov, blurSize)
	return TS:Create(cam, tInfo, {FieldOfView = fov}), TS:Create(blur, tInfo, {Size = blurSize})
end

local function popIn()
	frame.Visible = true
	local frameTween = makeFrameTween(1, 0)
	local camTween, blurTween = makeCamTween(origFov + 10, 20)
	frameTween:Play()
	camTween:Play()
	blurTween:Play()
	isOpen = true
end

local function popOut()
	local frameTween = makeFrameTween(0, 1)
	local camTween, blurTween = makeCamTween(origFov, 0)
	frameTween:Play()
	camTween:Play()
	blurTween:Play()
	frameTween.Completed:Connect(function()
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