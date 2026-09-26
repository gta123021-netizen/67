--!nocheck
--[[
	The limb-state pill over the hotbar (OverkillHUD.LimbStatus), run headless: the REAL module on a
	stand-in HUD kit, driven by the character's GoreStage attribute the way the server sets it.

	    lune run tests/limb_status_test.luau        (from the repository root)
]]
local Env = require("./sim/env")
local Client = require("./sim/client")(Env)

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

-- a stand-in HUD kit: plain objects, tweens land at once
local made, shakes = {}, 0
local function obj(class, props)
	local o = { ClassName = class, Visible = true }
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
	plate = function(p)
		return obj("Frame", p)
	end,
	text = function(p)
		return obj("TextLabel", p)
	end,
	padding = noop,
	list = noop,
	gradient = noop,
	tween = function(o, _, props)
		for k, v in pairs(props) do
			o[k] = v
		end
		return {}
	end,
	shake = function()
		shakes += 1
	end,
	darken = function(c)
		return c
	end,
}
local Theme = Env.load("ReplicatedStorage/OverkillUI/Theme")
local listeners = {}
local function character(stage)
	local char = Client.new("Model")
	char.Name = "Me"
	local hum = Client.new("Humanoid")
	hum.Name = "Humanoid"
	hum.Health = 100
	hum.Died = Env.Signal.new()
	hum.Parent = char
	if stage then
		char:SetAttribute("GoreStage", stage)
	end
	return char, hum
end
local char, hum = character(0)
local player = { Character = char, CharacterAdded = Env.Signal.new() }
local ctx = {
	Kit = Kit, Theme = Theme, Root = obj("Frame", { Name = "Root" }), Player = player,
	On = function(name, fn)
		listeners[name] = listeners[name] or {}
		table.insert(listeners[name], fn)
	end,
}
local LimbStatus = Env.loadReal("StarterPlayer/StarterPlayerScripts/OverkillHUD/LimbStatus", "StarterPlayer__StarterPlayerScripts__OverkillHUD__LimbStatus.lua")
LimbStatus(ctx)
Env.run(0.1)
local function find(name)
	for _, o in ipairs(made) do
		if o.Name == name then
			return o
		end
	end
	return nil
end
local holder, tag, note = find("LimbStatus"), find("Text"), find("Note")
check("the pill is built over the hotbar, hidden while whole", holder ~= nil and tag ~= nil and note ~= nil and holder.Parent == ctx.Root and holder.Visible == false)

local function stage(n)
	char:SetAttribute("GoreStage", n)
	Env.run(0.3)
end
stage(1)
check(("one arm: '%s  %s', gold"):format(tag.Text, note.Text), holder.Visible and tag.Text == "ONE ARM" and string.find(note.Text, "VULNERABLE") ~= nil and string.find(note.Text, "SINGLE STRIKES") ~= nil and find("Tag").BackgroundColor3 == Theme.C.Gold)
stage(2)
check(("no arms: '%s  %s', red, and it shakes"):format(tag.Text, note.Text), holder.Visible and tag.Text == "NO ARMS" and string.find(note.Text, "NO GUARD") ~= nil and string.find(note.Text, "NO ATTACKS") ~= nil and find("Tag").BackgroundColor3 == Theme.C.Red and shakes == 1)
for _, fn in ipairs(listeners.HudHidden or {}) do
	fn(true)
end
check("the HUD hidden: the pill with it", holder.Visible == false)
for _, fn in ipairs(listeners.HudHidden or {}) do
	fn(false)
end
check("... and back", holder.Visible == true)
stage(1)
check("an arm grows back: a green ARM RESTORED", holder.Visible and tag.Text == "ARM RESTORED" and find("Tag").BackgroundColor3 == Theme.C.Green and note.Visible == false)
Env.run(1.5)
check("... then what is still missing: ONE ARM", holder.Visible and tag.Text == "ONE ARM" and note.Visible == true)
stage(0)
check("the last arm back: ARM RESTORED", holder.Visible and tag.Text == "ARM RESTORED")
Env.run(1.6)
check("... then nothing (whole)", holder.Visible == false)
stage(1)
hum.Health = 0
stage(3)
check("down (the killing blow): nothing", holder.Visible == false)
-- a new character that arrives already missing both arms: shown as it is, no flash, no shake
local shakes0 = shakes
local char2 = character(2)
player.Character = char2
player.CharacterAdded:Fire(char2)
Env.run(0.3)
check("a character that arrives with no arms: NO ARMS at once, no shake", holder.Visible and tag.Text == "NO ARMS" and shakes == shakes0)
char:SetAttribute("GoreStage", 0)
Env.run(0.3)
check("the old character is let go (its changes show nothing)", holder.Visible and tag.Text == "NO ARMS")

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("limb status test failed")
end
