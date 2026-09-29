--V@lue team, Felix

local TimeMoment = 0 --Moment of time, when we want to see body.
local ranage = -2 --Ranage FROM CENTER'S SURFACE.
local harm = 180 --Higher values decreses speed.

local Pe = 7

while script.Center.Value do --I want to be sure, here won't be an error.
	TimeMoment=TimeMoment+1
	if TimeMoment >= harm*2 then --Needed to reset TimeMoment value, if it'll grow to much.
		--print ('Reseting time...')
		TimeMoment = 0
	end
	wait(.036)
	script.Parent.CFrame = script.Center.Value.CFrame*CFrame.fromEulerAnglesXYZ(0,TimeMoment*(math.pi/harm),0)*CFrame.new(0,0,(script.Center.Value.Size.Y+ranage))
end

--[[
	Why do I have called Pi value? All simple, Pi rad. = 180 dag., so Pi/180 rad.  = 1 dag.
	What for have i called harm*2? Because 180 dag. is 1/2 of round, if you want to have jumpy part... so you can delete it.
--]]