--!nocheck
--[[
	The limb pills (OverkillHUD.LimbStatus), run headless: the REAL module on stand-ins for the HUD's
	own pill builders (ctx.StatusPill / PillValue / PillAction - the hero, coin and level pills'),
	driven by the characters' GoreStage and RegrowAt attributes the way the server sets them.
	  - your pill over the hotbar: ONE ARM / NO ARMS / ARM RESTORED, what it means, the seconds to the
	    next arm and the figure's arm growing back; a refused press shakes it
	  - the same pill, smaller, over every other fighter missing an arm

	    lune run tests/limb_status_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local V3 = Env.Vector3

local passed, failed = 0, 0
local function check(name, cond, detail)
	if cond then
		passed += 1
		print("  PASS  " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. (if detail then "  -- " .. tostring(detail) else ""))
	end
end

-- stand-ins for the HUD kit and its pill builders: plain objects, tweens land at once
local made, shakes, sounds = {}, 0, {}
local function obj(class, props)
	local o = { ClassName = class, Visible = true, _kids = {} }
	function o:Destroy()
		self.Destroyed = true
		self.Parent = nil
	end
	for k, v in pairs(props or {}) do
		o[k] = v
	end
	table.insert(made, o)
	return o
end
local function noop() end
local Kit = {
	new = obj,
	fx = function(o)
		o.FX = o.FX or { Scale = 1 }
		return o.FX
	end,
	pill = noop,
	stroke = function()
		return obj("UIStroke")
	end,
	gradient = function(_, a, b)
		return obj("UIGradient", { Color = { a, b } })
	end,
	rings = function()
		return {}, { obj("UIGradient"), obj("UIGradient"), obj("UIGradient") }
	end,
	edgeStrokes = function()
		return {}, {}
	end,
	lighten = function(c)
		return c
	end,
	darken = function(c)
		return c
	end,
	textWidth = function(text, size)
		return #text * size * 0.55
	end,
	tween = function(o, _, props)
		for k, v in pairs(props) do
			o[k] = v
		end
		return {}
	end,
	shake = function()
		shakes += 1
	end,
	sfx = function(n)
		table.insert(sounds, n)
	end,
}
local Theme = Env.load("ReplicatedStorage/OverkillUI/Theme")
local C = Theme.C
local listeners = {}
local pills = {}
local ctx = {
	Kit = Kit, Theme = Theme, Root = obj("Frame", { Name = "Root" }),
	PillMetrics = { Height = 60, BadgeX = 38, BadgeY = 30, TextX = 57, RightPad = 8 },
	On = function(name, fn)
		listeners[name] = listeners[name] or {}
		table.insert(listeners[name], fn)
	end,
	StatusPill = function(name, _, caption, accent)
		local holder = obj("Frame", { Name = name })
		local pill = obj("Frame", { Name = "Pill", Parent = holder })
		local cap = obj("TextLabel", { Name = "Caption", Text = caption, Parent = pill })
		local glow = obj("Frame", { Name = "Glow", BackgroundColor3 = accent, Parent = pill })
		local rec = { Holder = holder, Caption = cap, Glow = glow }
		table.insert(pills, rec)
		return holder, pill, cap, glow
	end,
	PillValue = function(pill, text, color)
		local v = obj("TextLabel", { Name = "Value", Text = text, TextColor3 = color, Parent = pill })
		pills[#pills].Value = v
		return v
	end,
	PillAction = function(pill, o)
		local btn = obj("TextButton", { Name = o.Name, Parent = pill })
		local label = obj("TextLabel", { Text = o.Text or "" })
		local api = { Button = btn, Label = label, Enabled = true }
		function api.SetText(t)
			label.Text = t
		end
		pills[#pills].Socket = api
		return api
	end,
}

-- characters whose attribute signals fire (like Roblox's)
local function observable(char)
	local sigs = {}
	local set = char.SetAttribute
	char.SetAttribute = function(self, k, v)
		set(self, k, v)
		if sigs[k] then
			sigs[k]:Fire()
		end
	end
	char.GetAttributeChangedSignal = function(_, k)
		sigs[k] = sigs[k] or Env.Signal.new()
		return sigs[k]
	end
	char.WaitForChild = char.WaitForChild or function(self, n)
		return self:FindFirstChild(n)
	end
	return char
end
local nextX = 0
local function fighter(name, stage)
	nextX += 50
	local c = observable(Env.character(name, V3.new(nextX, 3, 0), V3.new(0, 0, -1)))
	c:SetAttribute("CombatEntity", true)
	c:SetAttribute("GoreStage", stage or 0)
	return c
end

local me = fighter("Me", 0)
local myHum = me:FindFirstChildOfClass("Humanoid")
local player = observable({ Name = "Me", Character = me, CharacterAdded = Env.Signal.new(), _attrs = {} })
player.SetAttribute = function(self, k, v)
	self._attrs[k] = v
end
player.GetAttribute = function(self, k)
	return self._attrs[k]
end
observable(player)
ctx.Player = player
-- the practice dummies' folder (the combat's own list of fighters besides the players)
local dummies = { Name = "PracticeDummies", _list = {} }
function dummies:GetChildren()
	return self._list
end
local wsFind = Env.workspace.FindFirstChild
Env.workspace.FindFirstChild = function(self, n)
	if n == "PracticeDummies" then
		return dummies
	end
	return if wsFind then wsFind(self, n) else nil
end

local LimbStatus = Env.loadReal("StarterPlayer/StarterPlayerScripts/OverkillHUD/LimbStatus", "StarterPlayer__StarterPlayerScripts__OverkillHUD__LimbStatus.lua")
LimbStatus(ctx)
Env.run(0.1)
local home
for _, o in ipairs(made) do
	if o.Name == "LimbStatus" then
		home = o
	end
end
local mine = pills[1]
local function armOf(rec, side)
	-- the figure's arm frames, found by name inside this pill's objects
	for i = #made, 1, -1 do
		local o = made[i]
		if o.Name == side .. "Arm" and o._owner == rec then
			return o
		end
	end
	return nil
end
-- (tag every figure piece with the pill it belongs to: the pieces made between two pills)
local function owners()
	local cur = nil
	for _, o in ipairs(made) do
		for _, rec in ipairs(pills) do
			if o == rec.Holder then
				cur = rec
			end
		end
		o._owner = o._owner or cur
	end
end
owners()

check("your pill is the HUD's own status pill (its builder), over the hotbar, hidden while whole", home ~= nil and mine ~= nil and mine.Holder.Parent == home and home.Parent == ctx.Root and home.Visible == false)

local function stage(n, regrowIn)
	me:SetAttribute("RegrowAt", if regrowIn then Env.workspace:GetServerTimeNow() + regrowIn else nil)
	me:SetAttribute("GoreStage", n)
	Env.run(0.3)
end
stage(1, 10)
local right = armOf(mine, "Right")
local left = armOf(mine, "Left")
check(("one arm: '%s' / '%s', gold like the coins pill's glow"):format(mine.Value.Text, mine.Caption.Text), home.Visible and mine.Value.Text == "ONE ARM" and string.find(mine.Caption.Text, "SINGLE STRIKES") ~= nil and mine.Glow.BackgroundColor3 == C.Gold)
check(("the socket counts to the next arm: '%s'"):format(mine.Socket.Label.Text), mine.Socket.Button.Visible and (mine.Socket.Label.Text == "10s" or mine.Socket.Label.Text == "9s"))
check("the badge's figure: its right arm (on your left) gone, its left there", right ~= nil and left ~= nil and left.Visible == true and (right.Visible == false or right.Size.Y.Offset < left.Size.Y.Offset * 0.5))
Env.run(5)
check(("5 s in: the right arm is half grown in the figure (%d of %d px), the socket says %s"):format(right.Size.Y.Offset, left.Size.Y.Offset, mine.Socket.Label.Text), right.Visible and math.abs(right.Size.Y.Offset / left.Size.Y.Offset - 0.5) < 0.12 and (mine.Socket.Label.Text == "5s" or mine.Socket.Label.Text == "4s"))
local shakes0, sounds0 = shakes, #sounds
player:SetAttribute("LimbDenied", os.clock())
check("a refused press shakes it, with the HUD's error sound", shakes == shakes0 + 1 and sounds[#sounds] == "Error" and #sounds == sounds0 + 1)
stage(2, 10)
check(("no arms: '%s' / '%s', red, and it shakes"):format(mine.Value.Text, mine.Caption.Text), home.Visible and mine.Value.Text == "NO ARMS" and string.find(mine.Caption.Text, "NO GUARD") ~= nil and string.find(mine.Caption.Text, "SMASH ONLY") ~= nil and mine.Glow.BackgroundColor3 == C.Red and shakes == shakes0 + 2)
for _, fn in ipairs(listeners.HudHidden or {}) do
	fn(true)
end
check("the HUD hidden: the pill with it", home.Visible == false)
for _, fn in ipairs(listeners.HudHidden or {}) do
	fn(false)
end
check("... and back", home.Visible == true)
stage(1, 10)
check("an arm grows back: ARM RESTORED in green", home.Visible and mine.Value.Text == "ARM RESTORED" and mine.Glow.BackgroundColor3 == C.Green)
Env.run(1.5)
check("... then what is still missing: ONE ARM, the clock running again", home.Visible and mine.Value.Text == "ONE ARM" and mine.Socket.Button.Visible)
stage(0, nil)
check("the last arm back: ARM RESTORED", home.Visible and mine.Value.Text == "ARM RESTORED")
Env.run(1.6)
check("... then nothing (whole)", home.Visible == false)
stage(1, 10)
myHum.Health = 0
stage(3, nil)
check("down (the killing blow): nothing", home.Visible == false)

-- everyone else: the pill over their heads
local dummy = fighter("Dummy", 0)
table.insert(dummies._list, dummy)
Env.run(0.5)
local function tagOn(char)
	local head = char:FindFirstChild("Head")
	for i = #made, 1, -1 do
		local o = made[i]
		if o.Name == "LimbTag" and o.Adornee == head then
			return o
		end
	end
	return nil
end
check("a whole fighter: no tag over it", tagOn(dummy) == nil)
local n0 = #pills
dummy:SetAttribute("GoreStage", 1)
Env.run(0.2)
local tag = tagOn(dummy)
local tp = pills[#pills]
check(("a fighter missing an arm: the same pill over its head, '%s', no caption"):format(tp and tp.Value and tp.Value.Text or "?"), tag ~= nil and #pills == n0 + 1 and tp.Value.Text == "ONE ARM" and tp.Caption.Visible == false and tag.AlwaysOnTop == true)
check("... an NPC never regrows: no clock on it", tp.Socket.Button.Visible == false)
dummy:SetAttribute("GoreStage", 2)
Env.run(0.2)
check("... NO ARMS when the other goes", tp.Value.Text == "NO ARMS" and tp.Glow.BackgroundColor3 == C.Red)
dummy:FindFirstChildOfClass("Humanoid").Health = 0
Env.run(0.5)
check("... gone once it is down", tag.Destroyed == true)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("limb status test failed")
end
