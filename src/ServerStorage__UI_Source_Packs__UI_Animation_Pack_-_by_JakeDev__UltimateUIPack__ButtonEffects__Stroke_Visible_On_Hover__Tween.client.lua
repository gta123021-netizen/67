--// This is a Shine Effect, a shiny line will appear randomly.

-- CREDITS TO RILEYBYTES (roblox.com/users/3890364928/profile) for making this


local TS = game:GetService("TweenService")

local button = script.Parent
local shine = button:WaitForChild("Frame"):WaitForChild("Shine")
local info = TweenInfo.new(1, Enum.EasingStyle.Circular, Enum.EasingDirection.In, -1, false)

shine.Position = UDim2.fromScale(-0.5, 0.5)
TS:Create(shine, info, {Position = UDim2.fromScale(1.5, 0.5)}):Play()