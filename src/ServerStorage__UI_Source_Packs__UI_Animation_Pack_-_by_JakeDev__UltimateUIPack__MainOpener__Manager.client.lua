local TS = game:GetService("TweenService")

local main = script.Parent
local btneffects = main:WaitForChild("ButtonEffects")
local frameeffectsbtn = main:WaitForChild("FrameEffects")

local gui = main.Parent
local btneffectsframe = gui:WaitForChild("ButtonEffects")
local frameopen = gui:WaitForChild("FrameOpenings")

local function toggleFrame(frame)
	local isVisible = frame.Visible
	if not frame:FindFirstChild("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Parent = frame
	end

	local scale = frame:FindFirstChild("UIScale")
	scale.Scale = isVisible and 1 or 0

	if isVisible then
		local shrink = TS:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0})
		shrink:Play()
		shrink.Completed:Connect(function()
			frame.Visible = false
		end)
	else
		frame.Visible = true
		local popIn = TS:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
		popIn:Play()
	end
end

btneffects.MouseButton1Click:Connect(function()
	toggleFrame(btneffectsframe)
end)

frameeffectsbtn.MouseButton1Click:Connect(function()
	toggleFrame(frameopen)
end)