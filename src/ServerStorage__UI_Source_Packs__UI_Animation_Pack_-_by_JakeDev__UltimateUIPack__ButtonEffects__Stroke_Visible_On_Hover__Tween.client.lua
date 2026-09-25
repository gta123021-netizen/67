--// This is a Stroke Visiblilty Toggle on Hover Effect, the uistroke will go visible on hover.

local btn = script.Parent
local stroke = btn.UIStroke
local TS = game:GetService("TweenService")

local tInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

stroke.Enabled = false
local function makeTween(alpha)
	return TS:Create(stroke, tInfo, {Transparency = alpha})
end

btn.MouseEnter:Connect(function()
	stroke.Enabled = true
	makeTween(0):Play()
end)

btn.MouseLeave:Connect(function()
	makeTween(1):Play()
	makeTween(1).Completed:Connect(function()
		stroke.Enabled = false
	end)
end)