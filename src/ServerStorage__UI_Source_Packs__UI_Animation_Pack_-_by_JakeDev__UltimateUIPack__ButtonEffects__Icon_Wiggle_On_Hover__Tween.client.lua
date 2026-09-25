--// This is a Stroke Visiblilty Toggle on Hover Effect, the uistroke will go visible on hover.

local btn = script.Parent
local icon = btn:WaitForChild("Icon")
local TS = game:GetService("TweenService")

local origSize = btn.Size
local origRot = icon.Rotation
local wiggleRot = 10
local shrinkScl = 0.9
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

local function makeRotTween(rot)
	return TS:Create(icon, tInfo, {Rotation = rot})
end

btn.MouseEnter:Connect(function()
	if not isClicking then
		local tweens = {
			makeRotTween(wiggleRot),
			makeRotTween(-wiggleRot),
			makeRotTween(wiggleRot),
			makeRotTween(origRot)
		}
		tweens[1]:Play()
		for i = 1, #tweens - 1 do
			tweens[i].Completed:Connect(function()
				tweens[i + 1]:Play()
			end)
		end
	end
end)

btn.MouseLeave:Connect(function()
	if not isClicking then
		makeRotTween(origRot):Play()
	end
end)

btn.MouseButton1Click:Connect(function()
	isClicking = true
	local shrink = makeSizeTween(shrinkScl)
	local reset = makeSizeTween(1)
	shrink:Play()
	shrink.Completed:Connect(function()
		reset:Play()
		reset.Completed:Connect(function()
			isClicking = false
		end)
	end)
end)