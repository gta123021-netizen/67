--[[
	FountainWater  (StarterPlayerScripts.FountainWater)
	The angel fountain's water jets, each switching on and off in its own rhythm - one light loop on
	each client drives all of them (it replaces the 33 server scripts that each looped forever and
	sent every on/off flip to every player). The jets stay in step on every screen: their rhythm runs
	on the server's clock.

	A jet is a part holding a ParticleEmitter named "liq", with a WaterRhythm attribute: its on / off
	durations in seconds, in order, starting on ("14,9,4,11" = on 14, off 9, on 4, off 11, repeat).
	Parts that stream in later join as they arrive.
]]

local RunService = game:GetService("RunService")

type Jet = { Emitter: ParticleEmitter, Steps: { number }, Period: number, On: boolean? }
local jets: { Jet } = {}
local known: { [ParticleEmitter]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function add(part: Instance?)
	if not part then
		return
	end
	local rhythm = part:GetAttribute("WaterRhythm")
	local e = part:FindFirstChild("liq")
	if type(rhythm) ~= "string" or not (e and e:IsA("ParticleEmitter")) or known[e] then
		return
	end
	local steps: { number } = {}
	local period = 0
	for n in string.gmatch(rhythm, "[%d%.]+") do
		local v = tonumber(n)
		if v and v > 0 then
			table.insert(steps, v)
			period += v
		end
	end
	if #steps == 0 then
		return
	end
	known[e] = true
	table.insert(jets, { Emitter = e, Steps = steps, Period = period, On = nil })
end

for _, d in ipairs(workspace:GetDescendants()) do
	if d.Name == "liq" then
		add(d.Parent)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if d.Name == "liq" then
		task.defer(add, d.Parent)
	end
end)

-- ten times a second is plenty for a jet that changes every few seconds
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.1 or #jets == 0 then
		return
	end
	acc = 0
	local t = workspace:GetServerTimeNow()
	for i = #jets, 1, -1 do
		local j = jets[i]
		if not j.Emitter.Parent then
			table.remove(jets, i)
		else
			local phase = t % j.Period
			local on = true
			for _, len in ipairs(j.Steps) do
				if phase < len then
					break
				end
				phase -= len
				on = not on
			end
			if on ~= j.On then
				j.On = on
				j.Emitter.Enabled = on
			end
		end
	end
end)
