--// This is a Stroke Scale on Hover Effect, the uistroke thickness will grow on hover.

local btn = script.Parent
local stroke = btn.UIStroke
local TS = game:GetService("TweenService")

local origThick = stroke.Thickness
local hoverThick = origThick + 2
local tInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function makeTween(thick)
	return TS:Create(stroke, tInfo, {Thickness = thick})
end

btn.MouseEnter:Connect(function()
	makeTween(hoverThick):Play()
end)

btn.MouseLeave:Connect(function()
	makeTween(origThick):Play()
end)