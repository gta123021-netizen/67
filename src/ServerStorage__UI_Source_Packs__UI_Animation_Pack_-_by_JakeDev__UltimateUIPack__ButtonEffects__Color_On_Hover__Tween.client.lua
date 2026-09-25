--// This is a Color Switch On Hover effect, the button will switch colors when hovered on.

local btn = script.Parent
local TS = game:GetService("TweenService")

local origSize = btn.Size
local origPos = btn.Position
local origColor = btn.BackgroundColor3
local hoverScl = 1.1
local hoverColor = Color3.fromRGB(0, 170, 255) -- this is the hover color, change it to whatever you want
local bounceUp = -0.02
local bounceDown = 0.02
local tInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local isClicking = false

local function makeSizeTween(scl, color)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(btn, tInfo, {Size = newSize, BackgroundColor3 = color})
end

local function makePosTween(offset)
	local newPos = UDim2.new(
		origPos.X.Scale,
		origPos.X.Offset,
		origPos.Y.Scale + offset,
		origPos.Y.Offset
	)
	return TS:Create(btn, tInfo, {Position = newPos})
end

btn.MouseEnter:Connect(function()
	if not isClicking then
		makeSizeTween(hoverScl, hoverColor):Play()
	end
end)

btn.MouseLeave:Connect(function()
	if not isClicking then
		makeSizeTween(1, origColor):Play()
	end
end)

btn.MouseButton1Click:Connect(function()
	isClicking = true
	local shrink = makeSizeTween(0.9, origColor)
	local reset = makeSizeTween(1, origColor)
	shrink:Play()
	shrink.Completed:Connect(function()
		reset:Play()
		reset.Completed:Connect(function()
			isClicking = false
		end)
	end)
end)