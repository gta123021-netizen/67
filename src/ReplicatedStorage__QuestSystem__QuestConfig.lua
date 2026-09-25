--[[
	QuestConfig  (ReplicatedStorage.QuestSystem.QuestConfig)
	Shared by the server (QuestServer) and the client (QuestClient).
	Everything you would want to tweak lives here: look, dialogue, quests, rewards.
]]

local Config = {}

---------------------------------------------------------------------------
-- WORLD
---------------------------------------------------------------------------
Config.HeroesPath = { "ImpactCrater", "CraterHeroes" } -- workspace path to the 3 statues
Config.QuestGiver = "Goki"                               -- who you talk to
Config.PromptDistance = 20                               -- studs, from the podium centre
Config.TitleHeight = 12                                  -- studs above the podium for the QUESTS sign
Config.TitleSize = Vector2.new(17, 5)                    -- quieter QUESTS sign above the podium
Config.CombatEnabled = false -- flip to true once your combat system reports combat stats (see QuestServer)

-- Places that count for "visit" / "spend time at" quests.
-- Path = workspace path to a model; Folder = every child of that folder is its own spot.
Config.Zones = {
	Fountain = { Path = { "angel fountain" }, Radius = 22 },
	Crater = { Path = { "ImpactCrater" }, Radius = 21 },
	Portal = { Folder = { "Portals" }, Radius = 9 },
}
Config.ZoneVisitCooldown = 45 -- seconds before re-entering the same spot counts as a new visit

---------------------------------------------------------------------------
-- LOOK  (restrained graphite and ivory, with a little depth)
---------------------------------------------------------------------------
Config.Style = {
	Font = Enum.Font.FredokaOne,
	SmallFont = Enum.Font.FredokaOne,
	Text = Color3.fromRGB(255, 255, 255),
	TextStroke = Color3.fromRGB(3, 5, 8),
	Highlight = Color3.fromRGB(226, 231, 237),
	Base = Color3.fromRGB(10, 13, 17),
	Panel = Color3.fromRGB(13, 17, 22),
	Edge = Color3.fromRGB(112, 123, 132),
	Row = Color3.fromRGB(24, 29, 35),
	RowHover = Color3.fromRGB(46, 53, 60),
	Track = Color3.fromRGB(9, 12, 15),
	Muted = Color3.fromRGB(135, 145, 154),
	Good = Color3.fromRGB(203, 224, 214),
	GoodLight = Color3.fromRGB(229, 239, 232),
	Locked = Color3.fromRGB(47, 53, 60),
	Danger = Color3.fromRGB(168, 81, 81),
	Gold = Color3.fromRGB(207, 189, 150),
	Xp = Color3.fromRGB(165, 192, 210),
	Accent = Color3.fromRGB(235, 239, 242),
}

Config.Speakers = {
	Goki = { Display = "GOKI", Role = "Daily training", Accent = Color3.fromRGB(238, 239, 233) },
	Naroto = { Display = "NAROTO", Role = "Weekly missions", Accent = Color3.fromRGB(214, 224, 232) },
	Gojen = { Display = "GOJEN", Role = "Monthly challenges", Accent = Color3.fromRGB(222, 216, 237) },
}

Config.Sounds = {
	Blip = "rbxasset://sounds/electronicpingshort.wav",
	Select = "rbxasset://sounds/clickfast.wav",
	Hover = "rbxasset://sounds/clickfast.wav",
	Claim = "rbxasset://sounds/electronicpingshort.wav",
}

---------------------------------------------------------------------------
-- DIALOGUE
-- {player} is replaced with the player's display name.
---------------------------------------------------------------------------
local HERO_OPTIONS = {
	{ Text = "Train with Goki", Next = "Daily" },
	{ Text = "Talk to Naroto", Next = "Weekly" },
	{ Text = "Visit Gojen", Next = "Monthly" },
	{ Text = "Maybe later", Leave = true },
}

local HERO_OPTIONS = {
	{ Text = "Train with Goki", Next = "Daily" },
	{ Text = "Talk to Naroto", Next = "Weekly" },
	{ Text = "Visit Gojen", Next = "Monthly" },
	{ Text = "Maybe later", Leave = true },
}

Config.Dialogue = {
	Start = {
		Speaker = "Goki",
		Lines = {
			"Hey {player}! You look like you've got some fight in you.",
			"Naroto, Gojen and I all hand out quests. Finish them for coins and XP! Who do you want to train with?",
		},
		Options = HERO_OPTIONS,
	},
	Welcome = {
		Speaker = "Goki",
		Lines = { "Back already, {player}?", "Who are we training with this time?" },
		Options = HERO_OPTIONS,
	},
	Ask = {
		Speaker = "Goki",
		Lines = { "Want to check in with someone else?" },
		Options = HERO_OPTIONS,
	},
	Daily = {
		Speaker = "Goki",
		Lines = { "Alright! Here's today's training. Let's see what you've got!" },
		Board = "Daily",
	},
	Weekly = {
		Speaker = "Naroto",
		Lines = { "Believe it! These missions last all week, so don't slack off!" },
		Board = "Weekly",
	},
	Monthly = {
		Speaker = "Gojen",
		Lines = { "Big goals for the whole month. Try to keep up, okay?" },
		Board = "Monthly",
	},
}

---------------------------------------------------------------------------
-- QUESTS
-- Every period each player gets Count quests picked from the tier's pool
-- (different stats where possible), so the list rotates daily / weekly / monthly.
--
-- Stats the server tracks by itself:
--   PlayMinutes, SocialMinutes (minutes played with 2+ people in the server), Distance (studs),
--   Jumps, ChatMessages, LoginDays, LoginStreak (days in a row), TalkToGoki,
--   ClaimsDaily, ClaimsWeekly, ClaimsMonthly, ClaimsAny,
--   Visit_Fountain, Visit_Crater, Visit_Portal (arrivals), Time_Fountain, Time_Crater (seconds)
-- Combat stats (hidden until CombatEnabled = true, your combat scripts report them):
--   Kills, Hits, Damage, Blocks, Ultimates, KillStreak
---------------------------------------------------------------------------
Config.MaxStats = { LoginStreak = true, KillStreak = true } -- progress = best value reached, not a running total

Config.Tiers = {
	Daily = { Order = 1, Title = "GOKI'S DAILY TRAINING", Short = "Daily", Count = 4, Seed = 11, Speaker = "Goki", Blurb = "Four focused goals from Goki. A fresh set each day." },
	Weekly = { Order = 2, Title = "NAROTO'S WEEKLY MISSIONS", Short = "Weekly", Count = 4, Seed = 23, Speaker = "Naroto", Blurb = "Longer missions. A fresh set every Monday." },
	Monthly = { Order = 3, Title = "GOJEN'S MONTHLY CHALLENGES", Short = "Monthly", Count = 3, Seed = 37, Speaker = "Gojen", Blurb = "Bigger goals. A fresh set on the first." },
}
Config.TierOrder = { "Daily", "Weekly", "Monthly" }

Config.Quests = {
	Daily = {
		{ Id = "d_play", Title = "Warm-Up Session", Desc = "Play for 15 minutes.", Stat = "PlayMinutes", Goal = 15, Reward = { Coins = 150, XP = 60 } },
		{ Id = "d_play2", Title = "Stay Sharp", Desc = "Play for 30 minutes.", Stat = "PlayMinutes", Goal = 30, Reward = { Coins = 250, XP = 100 } },
		{ Id = "d_play3", Title = "Long Haul", Desc = "Play for 60 minutes.", Stat = "PlayMinutes", Goal = 60, Reward = { Coins = 400, XP = 160 } },
		{ Id = "d_jump", Title = "Leg Day", Desc = "Jump 75 times.", Stat = "Jumps", Goal = 75, Reward = { Coins = 120, XP = 50 } },
		{ Id = "d_jump2", Title = "Bunny Hop", Desc = "Jump 200 times.", Stat = "Jumps", Goal = 200, Reward = { Coins = 220, XP = 90 } },
		{ Id = "d_run", Title = "Scout the Island", Desc = "Travel 1,500 studs.", Stat = "Distance", Goal = 1500, Reward = { Coins = 140, XP = 55 } },
		{ Id = "d_run2", Title = "Endurance Run", Desc = "Travel 4,000 studs.", Stat = "Distance", Goal = 4000, Reward = { Coins = 260, XP = 110 } },
		{ Id = "d_chat", Title = "Squad Up", Desc = "Send 5 chat messages.", Stat = "ChatMessages", Goal = 5, Reward = { Coins = 100, XP = 40 } },
		{ Id = "d_chat2", Title = "Hype Man", Desc = "Send 15 chat messages.", Stat = "ChatMessages", Goal = 15, Reward = { Coins = 180, XP = 70 } },
		{ Id = "d_talk", Title = "Report In", Desc = "Talk to Goki at the crater.", Stat = "TalkToGoki", Goal = 1, Reward = { Coins = 80, XP = 30 } },
		{ Id = "d_login", Title = "Clock In", Desc = "Log in today.", Stat = "LoginDays", Goal = 1, Reward = { Coins = 60, XP = 25 } },
		{ Id = "d_fountain", Title = "Make a Wish", Desc = "Visit the angel fountain.", Stat = "Visit_Fountain", Goal = 1, Reward = { Coins = 90, XP = 35 } },
		{ Id = "d_fountaint", Title = "Take a Breather", Desc = "Spend 3 minutes by the fountain.", Stat = "Time_Fountain", Goal = 180, Reward = { Coins = 150, XP = 60 } },
		{ Id = "d_crater", Title = "Ground Zero", Desc = "Visit the impact crater.", Stat = "Visit_Crater", Goal = 1, Reward = { Coins = 90, XP = 35 } },
		{ Id = "d_cratert", Title = "Feel the Aura", Desc = "Spend 2 minutes at the crater.", Stat = "Time_Crater", Goal = 120, Reward = { Coins = 150, XP = 60 } },
		{ Id = "d_portal", Title = "Portal Check", Desc = "Walk up to a portal.", Stat = "Visit_Portal", Goal = 1, Reward = { Coins = 90, XP = 35 } },
		{ Id = "d_portal3", Title = "Portal Patrol", Desc = "Visit the portals 3 times.", Stat = "Visit_Portal", Goal = 3, Reward = { Coins = 170, XP = 70 } },
		{ Id = "d_social", Title = "Strength in Numbers", Desc = "Play 10 minutes with others in the server.", Stat = "SocialMinutes", Goal = 10, Reward = { Coins = 160, XP = 65 } },
		{ Id = "d_claims", Title = "Busy Day", Desc = "Claim 2 other daily quests.", Stat = "ClaimsDaily", Goal = 2, Reward = { Coins = 200, XP = 80 } },
		{ Id = "d_kills", Title = "Sparring Partner", Desc = "Defeat 5 players.", Stat = "Kills", Goal = 5, Reward = { Coins = 260, XP = 120 }, Combat = true },
		{ Id = "d_hits", Title = "Combo Drills", Desc = "Land 60 hits.", Stat = "Hits", Goal = 60, Reward = { Coins = 200, XP = 90 }, Combat = true },
		{ Id = "d_dmg", Title = "Heavy Hitter", Desc = "Deal 2,500 damage.", Stat = "Damage", Goal = 2500, Reward = { Coins = 240, XP = 100 }, Combat = true },
		{ Id = "d_ult", Title = "Unleash It", Desc = "Use your ultimate 3 times.", Stat = "Ultimates", Goal = 3, Reward = { Coins = 220, XP = 95 }, Combat = true },
		{ Id = "d_block", Title = "Iron Guard", Desc = "Block 25 attacks.", Stat = "Blocks", Goal = 25, Reward = { Coins = 200, XP = 85 }, Combat = true },
		{ Id = "d_streak", Title = "On a Roll", Desc = "Get a 3 kill streak.", Stat = "KillStreak", Goal = 3, Reward = { Coins = 280, XP = 120 }, Combat = true },
	},
	Weekly = {
		{ Id = "w_play", Title = "Dedicated Fighter", Desc = "Play for 3 hours.", Stat = "PlayMinutes", Goal = 180, Reward = { Coins = 1500, XP = 600 } },
		{ Id = "w_play2", Title = "Marathon", Desc = "Play for 6 hours.", Stat = "PlayMinutes", Goal = 360, Reward = { Coins = 2600, XP = 1050 } },
		{ Id = "w_login", Title = "Show Up", Desc = "Log in on 4 different days.", Stat = "LoginDays", Goal = 4, Reward = { Coins = 1200, XP = 500 } },
		{ Id = "w_streak", Title = "Consistency", Desc = "Log in 3 days in a row.", Stat = "LoginStreak", Goal = 3, Reward = { Coins = 1400, XP = 560 } },
		{ Id = "w_daily", Title = "Daily Grinder", Desc = "Claim 12 daily quests.", Stat = "ClaimsDaily", Goal = 12, Reward = { Coins = 2000, XP = 800 } },
		{ Id = "w_any", Title = "Taskmaster", Desc = "Claim 20 quests of any kind.", Stat = "ClaimsAny", Goal = 20, Reward = { Coins = 2200, XP = 880 } },
		{ Id = "w_run", Title = "World Traveler", Desc = "Travel 15,000 studs.", Stat = "Distance", Goal = 15000, Reward = { Coins = 1300, XP = 550 } },
		{ Id = "w_run2", Title = "Globetrotter", Desc = "Travel 40,000 studs.", Stat = "Distance", Goal = 40000, Reward = { Coins = 2400, XP = 950 } },
		{ Id = "w_jump", Title = "Sky Walker", Desc = "Jump 800 times.", Stat = "Jumps", Goal = 800, Reward = { Coins = 1100, XP = 450 } },
		{ Id = "w_jump2", Title = "Skyward", Desc = "Jump 2,000 times.", Stat = "Jumps", Goal = 2000, Reward = { Coins = 2000, XP = 800 } },
		{ Id = "w_chat", Title = "Rally the Village", Desc = "Send 40 chat messages.", Stat = "ChatMessages", Goal = 40, Reward = { Coins = 900, XP = 400 } },
		{ Id = "w_chat2", Title = "Voice of the Island", Desc = "Send 120 chat messages.", Stat = "ChatMessages", Goal = 120, Reward = { Coins = 1700, XP = 700 } },
		{ Id = "w_talk", Title = "Check-Ins", Desc = "Talk to Goki 5 times.", Stat = "TalkToGoki", Goal = 5, Reward = { Coins = 1000, XP = 420 } },
		{ Id = "w_fountain", Title = "Regular", Desc = "Visit the fountain 5 times.", Stat = "Visit_Fountain", Goal = 5, Reward = { Coins = 1000, XP = 420 } },
		{ Id = "w_fountaint", Title = "Hangout Spot", Desc = "Spend 20 minutes by the fountain.", Stat = "Time_Fountain", Goal = 1200, Reward = { Coins = 1500, XP = 620 } },
		{ Id = "w_cratert", Title = "Aura Soak", Desc = "Spend 15 minutes at the crater.", Stat = "Time_Crater", Goal = 900, Reward = { Coins = 1400, XP = 580 } },
		{ Id = "w_portal", Title = "Gatekeeper", Desc = "Visit the portals 20 times.", Stat = "Visit_Portal", Goal = 20, Reward = { Coins = 1600, XP = 650 } },
		{ Id = "w_social", Title = "Squad Goals", Desc = "Play 90 minutes with others in the server.", Stat = "SocialMinutes", Goal = 90, Reward = { Coins = 1800, XP = 720 } },
		{ Id = "w_kills", Title = "Spiral Barrage", Desc = "Defeat 40 players.", Stat = "Kills", Goal = 40, Reward = { Coins = 2400, XP = 1000 }, Combat = true },
		{ Id = "w_hits", Title = "Flurry", Desc = "Land 800 hits.", Stat = "Hits", Goal = 800, Reward = { Coins = 2100, XP = 850 }, Combat = true },
		{ Id = "w_dmg", Title = "Wrecking Ball", Desc = "Deal 40,000 damage.", Stat = "Damage", Goal = 40000, Reward = { Coins = 2300, XP = 950 }, Combat = true },
		{ Id = "w_ult", Title = "Limit Breaker", Desc = "Use your ultimate 30 times.", Stat = "Ultimates", Goal = 30, Reward = { Coins = 2200, XP = 900 }, Combat = true },
		{ Id = "w_block", Title = "Stonewall", Desc = "Block 300 attacks.", Stat = "Blocks", Goal = 300, Reward = { Coins = 2000, XP = 820 }, Combat = true },
		{ Id = "w_streak2", Title = "Unstoppable", Desc = "Get a 5 kill streak.", Stat = "KillStreak", Goal = 5, Reward = { Coins = 2600, XP = 1100 }, Combat = true },
	},
	Monthly = {
		{ Id = "m_play", Title = "Living Legend", Desc = "Play for 15 hours.", Stat = "PlayMinutes", Goal = 900, Reward = { Coins = 9000, XP = 3500 } },
		{ Id = "m_play2", Title = "Eternal", Desc = "Play for 30 hours.", Stat = "PlayMinutes", Goal = 1800, Reward = { Coins = 15000, XP = 6000 } },
		{ Id = "m_login", Title = "No Days Off", Desc = "Log in on 15 different days.", Stat = "LoginDays", Goal = 15, Reward = { Coins = 8000, XP = 3000 } },
		{ Id = "m_streak", Title = "Unbreakable", Desc = "Log in 7 days in a row.", Stat = "LoginStreak", Goal = 7, Reward = { Coins = 10000, XP = 4000 } },
		{ Id = "m_weekly", Title = "Weekly Warrior", Desc = "Claim 10 weekly quests.", Stat = "ClaimsWeekly", Goal = 10, Reward = { Coins = 10000, XP = 4000 } },
		{ Id = "m_daily", Title = "Hundred Tasks", Desc = "Claim 60 daily quests.", Stat = "ClaimsDaily", Goal = 60, Reward = { Coins = 12000, XP = 5000 } },
		{ Id = "m_any", Title = "Quest Addict", Desc = "Claim 100 quests of any kind.", Stat = "ClaimsAny", Goal = 100, Reward = { Coins = 13000, XP = 5200 } },
		{ Id = "m_run", Title = "Across the Worlds", Desc = "Travel 100,000 studs.", Stat = "Distance", Goal = 100000, Reward = { Coins = 7000, XP = 2800 } },
		{ Id = "m_jump", Title = "Moon Jumper", Desc = "Jump 10,000 times.", Stat = "Jumps", Goal = 10000, Reward = { Coins = 7500, XP = 3000 } },
		{ Id = "m_chat", Title = "Legendary Talker", Desc = "Send 600 chat messages.", Stat = "ChatMessages", Goal = 600, Reward = { Coins = 7000, XP = 2800 } },
		{ Id = "m_talk", Title = "Goki's Favorite", Desc = "Talk to Goki 25 times.", Stat = "TalkToGoki", Goal = 25, Reward = { Coins = 6500, XP = 2600 } },
		{ Id = "m_portal", Title = "Dimension Walker", Desc = "Visit the portals 100 times.", Stat = "Visit_Portal", Goal = 100, Reward = { Coins = 8500, XP = 3400 } },
		{ Id = "m_cratert", Title = "Crater Legend", Desc = "Spend 60 minutes at the crater.", Stat = "Time_Crater", Goal = 3600, Reward = { Coins = 8000, XP = 3200 } },
		{ Id = "m_fountaint", Title = "Fountain Keeper", Desc = "Spend 90 minutes by the fountain.", Stat = "Time_Fountain", Goal = 5400, Reward = { Coins = 8000, XP = 3200 } },
		{ Id = "m_social", Title = "Village Favorite", Desc = "Play 10 hours with others in the server.", Stat = "SocialMinutes", Goal = 600, Reward = { Coins = 11000, XP = 4400 } },
		{ Id = "m_kills", Title = "Limitless", Desc = "Defeat 300 players.", Stat = "Kills", Goal = 300, Reward = { Coins = 15000, XP = 6000 }, Combat = true },
		{ Id = "m_hits", Title = "Thousand Fists", Desc = "Land 10,000 hits.", Stat = "Hits", Goal = 10000, Reward = { Coins = 13000, XP = 5200 }, Combat = true },
		{ Id = "m_dmg", Title = "World Ender", Desc = "Deal 500,000 damage.", Stat = "Damage", Goal = 500000, Reward = { Coins = 14000, XP = 5600 }, Combat = true },
		{ Id = "m_ult", Title = "Beyond Limits", Desc = "Use your ultimate 250 times.", Stat = "Ultimates", Goal = 250, Reward = { Coins = 12000, XP = 4800 }, Combat = true },
		{ Id = "m_streak2", Title = "Godlike", Desc = "Get a 10 kill streak.", Stat = "KillStreak", Goal = 10, Reward = { Coins = 16000, XP = 6500 }, Combat = true },
	},
}

-- lookup: Config.QuestById.Daily.d_play -> definition
Config.QuestById = {}
for tierName, list in pairs(Config.Quests) do
	Config.QuestById[tierName] = {}
	for _, q in ipairs(list) do
		Config.QuestById[tierName][q.Id] = q
	end
end

function Config.GetPool(tierName: string)
	local out = {}
	for _, q in ipairs(Config.Quests[tierName]) do
		if Config.CombatEnabled or not q.Combat then
			table.insert(out, q)
		end
	end
	return out
end

function Config.TierAccent(tierName: string): Color3
	local tier = Config.Tiers[tierName]
	local sp = tier and Config.Speakers[tier.Speaker]
	return (sp and sp.Accent) or Config.Style.Accent
end

---------------------------------------------------------------------------
-- TIME (all UTC). Daily resets 00:00 UTC, weekly Monday 00:00 UTC, monthly on the 1st.
---------------------------------------------------------------------------
local DAY = 86400

local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

function Config.PeriodId(tierName: string, t: number): number
	t = math.floor(t)
	if tierName == "Daily" then
		return t // DAY
	elseif tierName == "Weekly" then
		return (t // DAY - 4) // 7 -- day 4 after the epoch was a Monday
	else
		local d = os.date("!*t", t) :: any
		return d.year * 12 + (d.month - 1)
	end
end

function Config.NextReset(tierName: string, t: number): number
	t = math.floor(t)
	if tierName == "Daily" then
		return (t // DAY + 1) * DAY
	elseif tierName == "Weekly" then
		local w = (t // DAY - 4) // 7
		return ((w + 1) * 7 + 4) * DAY
	else
		local d = os.date("!*t", t) :: any
		local y, m = d.year, d.month + 1
		if m > 12 then
			y += 1
			m = 1
		end
		return daysFromCivil(y, m, 1) * DAY
	end
end

function Config.FormatNumber(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

function Config.FormatDuration(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d = sec // DAY
	local h = (sec % DAY) // 3600
	local m = (sec % 3600) // 60
	local s = sec % 60
	if d > 0 then
		return string.format("%dd %02dh %02dm", d, h, m)
	end
	return string.format("%02d:%02d:%02d", h, m, s)
end

-- "45 / 120" for seconds-based quests reads badly, so show minutes
function Config.FormatProgress(stat: string, value: number): string
	if stat and stat:sub(1, 5) == "Time_" then
		return string.format("%d:%02d", value // 60, value % 60)
	end
	return Config.FormatNumber(value)
end

return Config
