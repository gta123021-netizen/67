local tweenservice = game:GetService("TweenService")

local info1 = TweenInfo.new(
	.5,
	Enum.EasingStyle.Quint,
	Enum.EasingDirection.Out,
	0,
	false,
	0
)

local info2 = TweenInfo.new(
	10,
	Enum.EasingStyle.Quint,
	Enum.EasingDirection.In,
	0,
	false,
	0
)

while true do
	local p1 = Instance.new("Part", script.Parent)
	p1.CFrame = script.Parent.CFrame * CFrame.new(-10, 3, 0) * CFrame.Angles(math.rad(-90), 0, 0)
	p1.Anchored = true
	p1.CanCollide = false
	p1.CanTouch = false
	p1.Transparency = 1
	p1.FrontSurface = Enum.SurfaceType.Hinge
	
	local p2 = Instance.new("Part", script.Parent)
	p2.CFrame = script.Parent.CFrame * CFrame.new(10, 3, 0) * CFrame.Angles(math.rad(-90), 0, 0)
	p2.Anchored = true
	p2.CanCollide = false
	p2.CanTouch = false
	p2.Transparency = 1
	p2.FrontSurface = Enum.SurfaceType.Hinge
	
	local ray1 = workspace:Raycast(p1.Position, p1.CFrame.LookVector * 20)
	local ray2 = workspace:Raycast(p2.Position, p2.CFrame.LookVector * 20)
	if ray1 then
		local d1 = Instance.new("Part", game.Workspace)
		d1.CanTouch = false
		d1.Anchored = true
		d1.Position = ray1.Position+ Vector3.new(0,-1,0)
		d1.Orientation = script.Parent.Orientation
		
		d1.Material = ray1.Instance.Material
		d1.Color = ray1.Instance.Color
		
		d1.Size = Vector3.new(0.01, 0.01, 0.01)
		
		d1.CFrame = d1.CFrame * CFrame.Angles(0, math.rad(-90),0)
		d1.CFrame = d1.CFrame * CFrame.Angles(math.rad(-12), 0,0)
		
		local R = math.random(0, 360)
		local R1 = math.random(-10, 10)
		local R2 = math.random(-10, 10)
		
		tweenservice:Create(d1, info1, {Size = Vector3.new(math.random(1200, 1500)/100,math.random(400, 500)/100, math.random(800, 1000)/100),
			CFrame = d1.CFrame * CFrame.Angles(math.rad(R1), math.rad(R), math.rad(R2))}):Play()
		spawn(function()
			wait(5)
			tweenservice:Create(d1, info2, {Position = ray1.Position + Vector3.new(0, -4, 0)}):Play()
			wait(10)
			d1:Destroy()
		end)
	end
	if ray2 then
		local d2 = Instance.new("Part", game.Workspace)
		d2.CanTouch = false
		d2.Anchored = true
		d2.Position = ray2.Position + Vector3.new(0,-1,0)
		d2.Orientation = script.Parent.Orientation

		d2.Material = ray2.Instance.Material
		d2.Color = ray2.Instance.Color

		d2.Size = Vector3.new(0.01, 0.01, 0.01)

		d2.CFrame = d2.CFrame * CFrame.Angles(0, math.rad(-90),0)
		d2.CFrame = d2.CFrame * CFrame.Angles(math.rad(12), 0,0)
		local R = math.random(0, 360)
		local R1 = math.random(-10,10)
		local R2 = math.random(-10,10)
		
		tweenservice:Create(d2, info1, {Size = Vector3.new(math.random(1300, 1700)/100,math.random(400, 500)/100, math.random(800, 1000)/100),CFrame = d2.CFrame * CFrame.Angles(math.rad(R1), math.rad(R), math.rad(R2))}):Play()
		spawn(function()
			wait(5)
			tweenservice:Create(d2, info2, {Position = ray2.Position + Vector3.new(0, -4, 0)}):Play()
			wait(10)
			d2:Destroy()
		end)
	end
	p1:Destroy()
	p2:Destroy()
	task.wait(.15)
end
