--[[
	QueueConfig  (ReplicatedStorage.OverkillUI.QueueConfig)
	Everything about the 1v1 / 2v2 / Arena queues and parties, shared by QueueServer and the HUD.

	TO GO LIVE: publish a separate place for each mode (in this same experience) and paste its
	PlaceId below. Matched players are sent together to a private (reserved) server of that place.
	The destination place receives this TeleportData on every player:
		{ Mode = "Duos", MatchId = "M12", Teams = { {userId, userId}, {userId, userId} }, Players = { userId, ... } }
	(Teams is nil for free-for-all.) Until a PlaceId is set - and always inside Studio - the whole
	flow still runs, it just ends with a "test match" screen instead of a teleport.
]]

local Config = {}

local rgb = Color3.fromRGB

Config.Order = { "Duel", "Duos", "Arena" }

Config.Modes = {
	Duel = {
		Id = "Duel",
		Title = "1V1 DUEL",
		Name = "1V1 DUEL", -- the queue card title
		Short = "1V1",
		Badge = "1V1",
		PlaceId = 0, -- paste the 1v1 match place id here
		Players = 2,
		Teams = 2,
		TeamSize = 1,
		MaxParty = 2, -- a party of two walking in gets a private duel against each other
		Portal = "Portal_Blue",
		Color = rgb(84, 156, 255),
		Deep = rgb(34, 84, 214),
		Blurb = "One on one. Best fighter wins.",
		PartyRule = "Solo - or duel your partner",
	},
	Duos = {
		Id = "Duos",
		Title = "2V2 DUOS",
		Name = "2V2 DUOS",
		Short = "2V2",
		Badge = "2V2",
		PlaceId = 0, -- paste the 2v2 match place id here
		Players = 4,
		Teams = 2,
		TeamSize = 2,
		MaxParty = 2,
		Portal = "Portal_Red",
		Color = rgb(255, 92, 102),
		Deep = rgb(200, 36, 60),
		Blurb = "Team up with a partner or get matched.",
		PartyRule = "Solo or with 1 partner",
	},
	Arena = {
		Id = "Arena",
		Title = "ARENA FREE-FOR-ALL",
		Name = "ARENA",
		Short = "ARENA",
		Badge = "FFA",
		PlaceId = 0, -- paste the arena match place id here
		Players = 6,
		MinPlayers = 4, -- after EarlyStart seconds a match can start with this many
		EarlyStart = 45,
		FreeForAll = true,
		MaxParty = 3,
		Portal = "Portal_Green",
		Color = rgb(88, 222, 110),
		Deep = rgb(30, 150, 70),
		Blurb = "Six fighters. One winner. No teams.",
		PartyRule = "Solo or party up to 3",
	},
}

Config.MaxPartySize = 3
Config.InviteSeconds = 30 -- how long a party invite stays open
Config.AcceptSeconds = 12 -- ready check length
Config.StartSeconds = 3 -- countdown after everyone accepts
Config.DodgeSeconds = 20 -- queue lock after declining / missing a ready check
Config.TeleportTimeout = 25 -- give up on a teleport that never happened and bring players back

-- Studio only: fill queues with practice bots so every flow can be tested alone
Config.StudioBots = true
Config.BotNames = {
	"Kaito", "Mira", "Zeke", "Rin", "Blaze", "Nova", "Taro", "Yumi", "Rex", "Sora", "Kira", "Dash",
	"Hiro", "Luna", "Axel", "Ivy", "Jin", "Nyx", "Orion", "Sage",
}
Config.LobbyBots = 4 -- practice bots listed in the party window (Studio only), they accept invites

-- loading-screen tips while the match server is being prepared
Config.Tips = {
	"Walk into a portal again while searching to see your queue card bounce.",
	"Party up with the PARTY button (G) - the leader walks in and the whole party queues.",
	"A party of two in the 1V1 portal gets a private duel against each other.",
	"Declining a ready check locks your queue for a few seconds.",
	"Arena starts early with 4 fighters if the lobby is quiet.",
	"If someone misses the ready check you go back in with PRIORITY.",
}

-- queue rules shown in the party window
function Config.PartyRules()
	local out = {}
	for _, id in ipairs(Config.Order) do
		local m = Config.Modes[id]
		table.insert(out, { Mode = id, Badge = m.Badge, Title = m.Title, Rule = m.PartyRule, Color = m.Color, Deep = m.Deep })
	end
	return out
end

-- which modes a party of this size may queue for (nil = allowed, string = why not)
function Config.PartyBlock(modeId: string, size: number): string?
	local m = Config.Modes[modeId]
	if not m then
		return "Unknown mode"
	end
	if size > m.MaxParty then
		return ("Your party is too big for %s (max %d)"):format(m.Short, m.MaxParty)
	end
	return nil
end

function Config.Clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

return Config
