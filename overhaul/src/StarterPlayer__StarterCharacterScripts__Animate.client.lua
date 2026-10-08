--[[
	Animate  (StarterCharacterScripts.Animate)
	Locomotion is driven by StarterPlayerScripts.CombatClient (one owner for every animation on the
	character, so walk/run/idle never fight the combat clips). This script only keeps the standard
	Animate layout so tools that read "the avatar's idle" (the HUD's avatar previews) find the combat
	idle, and so Roblox doesn't insert its default Animate script.
]]
