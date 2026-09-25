--// This is a Rotate on hover effect, similar to some simulator games.

local btn = script.Parent
local TS = game:GetService("TweenService")

local origSize = btn.Size
local hoverScl = 1.1
local clickScl = 0.9
local hoverRot = 10
local tInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function makeTween(scl, rot)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(btn, tInfo, {Size = newSize, Rotation = rot})
end

btn.MouseEnter:Connect(function()
	makeTween(hoverScl, hoverRot):Play()
end)

btn.MouseLeave:Connect(function()
	makeTween(1, 0):Play()
end)

btn.MouseButton1Click:Connect(function()
	local shrink = makeTween(clickScl, 0)
	local reset = makeTween(1, 0)
	shrink:Play()
	shrink.Completed:Connect(function()
		reset:Play()
	end)
end)