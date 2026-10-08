--[[
	GameState  (ReplicatedStorage.GameState)
	ONE answer to "what may happen to this fighter here?", read by every system that cares (the
	fight's requests and damage, abilities, gore, the health / regen bars, the ability hotbar) -
	never a check scattered through each of them.

	States
	  LOBBY        the spawn island: a sanctuary. Walk, jump, run and move freely - no combat, no
	               abilities, no damage from anyone, no gore, no health / regen bars, no hotbar.
	               (The void still kills: falling off the world is not combat)
	  MATCH        a real fight (a match server: QueueServer's reserved servers)
	  DEV_TESTING  the dev testing range: everything a match has, against practice dummies

	Where a fighter's state comes from (the server sets it; everyone reads it):
	  a player   the player's "GameState" attribute (GameStateServer: the place's own state on
	             spawn, a portal's on the way through)
	  an NPC     its model's "GameState" attribute (set by whatever spawned it)
	  default    the place's own: workspace "PlaceState" (a match server: MATCH; this place: LOBBY)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GameState = {}

GameState.LOBBY = "LOBBY"
GameState.MATCH = "MATCH"
GameState.DEV_TESTING = "DEV_TESTING"

-- what each state allows
--   Combat     strikes, guard, dashes - and being hit
--   Abilities  casting the hero's abilities
--   Damage     taking damage from anyone (the void is not damage: it still kills)
--   Gore       limbs coming off, blood
--   Vitals     the health / regen bars (yours and over everyone's head)
--   Hotbar     the ability hotbar
GameState.Rules = {
	LOBBY = { Combat = true, Abilities = true, Damage = true, Gore = true, Vitals = true, Hotbar = true }, -- (sanctuary off)
	MATCH = { Combat = true, Abilities = true, Damage = true, Gore = true, Vitals = true, Hotbar = true },
	DEV_TESTING = { Combat = true, Abilities = true, Damage = true, Gore = true, Vitals = true, Hotbar = true },
}

local VALID = { LOBBY = true, MATCH = true, DEV_TESTING = true }

function GameState.Default(): string
	if RunService:IsStudio() and workspace:GetAttribute("StudioLobby") ~= true then
		return "DEV_TESTING"
	end
	local s = workspace:GetAttribute("PlaceState")
	return if type(s) == "string" and VALID[s] then s else "LOBBY"
end

-- the state of a player, a character or an NPC model
function GameState.Of(subject: Instance?): string
	if subject == nil then
		return GameState.Default()
	end
	local holder: Instance = subject
	if subject:IsA("Model") then
		local p = Players:GetPlayerFromCharacter(subject)
		if p then
			holder = p
		end
	end
	local s = holder:GetAttribute("GameState")
	return if type(s) == "string" and VALID[s] then s else GameState.Default()
end

function GameState.Allows(subject: Instance?, what: string): boolean
	local r = GameState.Rules[GameState.Of(subject)]
	return r ~= nil and r[what] == true
end

-- a change of a subject's state (fn(newState)); returns a disconnect
function GameState.Changed(subject: Instance, fn: (string) -> ()): RBXScriptConnection
	return subject:GetAttributeChangedSignal("GameState"):Connect(function()
		fn(GameState.Of(subject))
	end)
end

return GameState
