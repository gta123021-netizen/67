local tornado = script.Parent

repeat
	wait()
	tornado.CFrame = tornado.CFrame * CFrame.fromEulerAnglesXYZ(0,0.1,0)
	
until
false
