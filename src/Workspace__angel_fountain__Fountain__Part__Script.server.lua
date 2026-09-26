-- the fountain's water: on and off in its own rhythm
local liq = script.Parent:WaitForChild("liq", 10)
if not liq then
	return
end
while true do
	liq.Enabled = true
	task.wait(10)
	liq.Enabled = false
	task.wait(5)
	liq.Enabled = true
	task.wait(1)
	liq.Enabled = false
	task.wait(7)
end
