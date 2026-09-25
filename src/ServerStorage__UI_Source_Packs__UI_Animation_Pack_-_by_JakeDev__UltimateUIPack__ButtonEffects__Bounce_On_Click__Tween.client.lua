--// This is a Bounce On Click effect, the button will bounce when clicked.

local btn = script.Parent
local TS = game:GetService("TweenService")

local origSize = btn.Size
local origPos = btn.Position
local hoverScl = 1.1
local bounceUp = -0.02
local bounceDown = 0.02
local tInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local isClicking = false

local function makeSizeTween(scl)
	local newSize = UDim2.new(
		origSize.X.Scale * scl,
		origSize.X.Offset * scl,
		origSize.Y.Scale * scl,
		origSize.Y.Offset * scl
	)
	return TS:Create(btn, tInfo, {Size = newSize})
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
		makeSizeTween(hoverScl):Play()
	end
end)

btn.MouseLeave:Connect(function()
	if not isClicking then
		makeSizeTween(1):Play()
	end
end)

btn.MouseButton1Click:Connect(function()
	isClicking = true
	local tweens = {
		makeSizeTween(1),
		makePosTween(bounceUp),
		makePosTween(bounceDown),
		makePosTween(0)
	}
	tweens[1]:Play()
	for i = 1, #tweens - 1 do
		tweens[i].Completed:Connect(function()
			tweens[i + 1]:Play()
		end)
	end
	tweens[#tweens].Completed:Connect(function()
		isClicking = false
	end)
end)