--// This is a hover & click effect, i suggest you test this on pc. because it requires a mouse for hovering over the button.

local btn = script.Parent
local TS = game:GetService("TweenService")

local origSize = btn.Size
local hoverScl = 1.1
local clickScl = 0.9
local tInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function makeTween(scl)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(btn, tInfo, {Size = newSize})
end

btn.MouseEnter:Connect(function()
	makeTween(hoverScl):Play()
end)

btn.MouseLeave:Connect(function()
	makeTween(1):Play()
end)

btn.MouseButton1Click:Connect(function()
	local shrink = makeTween(clickScl)
	local reset = makeTween(1)
	shrink:Play()
	shrink.Completed:Connect(function()
		reset:Play()
	end)
end)