local tweenservice = game:GetService("TweenService")
local info1 = TweenInfo.new(
	5,
	Enum.EasingStyle.Linear,
	Enum.EasingDirection.Out,
	0,
	false,
	0
)

local tr1 = {
	Size = Vector3.new(0.001, 0.001, 0.001)
}
while true do
	
	local p1 = Instance.new("Part", workspace)
	
	local X1 = math.random(-300, 300)/100
	local X2 = math.random(800, 1300)/100 * -1
	
	p1.Anchored = true
	p1.CFrame = script.Parent.CFrame * CFrame.new(X1,0,X2) * CFrame.Angles(math.rad(-90),0,0)
	p1.FrontSurface = Enum.SurfaceType.Hinge
	p1.Transparency = 1
	p1.CanCollide = false
	p1.CanTouch = false
	p1.Size = Vector3.new(0.001, 0.001,0.001)
	
	local Raycast1 = workspace:Raycast(p1.Position, p1.CFrame.LookVector * 20)
	
	if Raycast1 then
		local D1 = Instance.new("Part", workspace)
		local X = math.random(100, 200)/100
		local Y = math.random(100, 200)/100
		local Z = math.random(100, 200)/100
		
		D1.Size = Vector3.new(X,Y,Z)
		D1.Position = Raycast1.Position
		D1.Color = Raycast1.Instance.Color
		D1.Material = Raycast1.Instance.Material
		D1.CanCollide = false
		D1.CanTouch = false
		
		local VX1 = math.random(-25, 25)
		local VY1 = math.random(60, 105)
		local VZ1 = math.random(-75, 75)
		
		local RX1 = math.random(0, 360)
		local RY1 = math.random(0, 360)
		local RZ1 = math.random(0, 360)
		
		D1.Orientation = Vector3.new(RX1, RY1, RZ1)
		
		D1.Velocity = script.Parent.CFrame.LookVector * -100
		D1.Velocity = D1.Velocity + Vector3.new(VX1,VY1,VZ1)
		spawn(function()
			tweenservice:Create(D1, info1, tr1):Play()
			wait(6)
			D1:Destroy()
		end)
	end
	p1:Destroy()
	task.wait(.05)
end
