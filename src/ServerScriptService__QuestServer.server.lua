--[[
	QuestServer  (ServerScriptService.QuestServer)
	- Builds the in-world pieces: the QUESTS sign over the crater and the [E] prompt.
	- Tracks progress, rolls daily / weekly / monthly quests per player, handles claiming, saves to DataStore.

	Hooking your own systems in (combat etc.) from any server script:
		game.ServerStorage.QuestProgress:Fire(player, "Kills", 1)
	then set Config.CombatEnabled = true so combat quests start appearing.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local QS = ReplicatedStorage:WaitForChild("QuestSystem")
local Config = require(QS:WaitForChild("QuestConfig"))
local Remotes = QS:WaitForChild("Remotes")
local GetBoard = Remotes:WaitForChild("GetBoard") :: RemoteFunction
local ClaimQuest = Remotes:WaitForChild("ClaimQuest") :: RemoteFunction
local QuestUpdated = Remotes:WaitForChild("QuestUpdated") :: RemoteEvent
local ClientReport = Remotes:WaitForChild("ClientReport") :: RemoteEvent

local STORE_NAME = "OverkillQuests_v1"
local AUTOSAVE = 120

local store: DataStore? = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = res
	else
		warn("[Quests] DataStore unavailable, progress will not save:", res)
	end
end

type QuestState = { Id: string, Progress: number, Claimed: boolean }
type Profile = {
	Data: any,
	Loaded: boolean,
	CanSave: boolean,
	Pending: { [string]: any },
	Toasts: { any },
	DistRemainder: number,
	LastPos: Vector3?,
	Seconds: number,
	LastJump: number,
	LastChat: number,
	LastTalk: number,
	LastClaim: number,
	Zones: { [string]: { Inside: boolean, Last: number } },
	ZoneTime: { [string]: number },
}

local profiles: { [Player]: Profile } = {}
local trackZones: (Player, any, Vector3, number) -> ()

local function now(): number
	return os.time()
end

local function newData()
	return { Version = 1, Wallet = { Coins = 0, XP = 0 }, Lifetime = {}, Tiers = {}, LastLoginDay = -1 }
end

---------------------------------------------------------------------------
-- leaderstats (Coins / XP). If you already make leaderstats elsewhere the same values are reused.
---------------------------------------------------------------------------
local function getStat(player: Player, name: string): IntValue
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	local v = ls:FindFirstChild(name)
	if not v then
		v = Instance.new("IntValue")
		v.Name = name
		v.Parent = ls
	end
	return v :: IntValue
end

---------------------------------------------------------------------------
-- quest rolling
---------------------------------------------------------------------------
local function rollQuests(tierName: string, userId: number, period: number): { QuestState }
	local list = table.clone(Config.GetPool(tierName))
	local rng = Random.new((userId % 1000003) * 7919 + period * 104729 + Config.Tiers[tierName].Seed)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	-- take quests with different stats first so a board never shows two "play X minutes" quests
	local count = math.min(Config.Tiers[tierName].Count, #list)
	local out, usedStat, usedId = {}, {}, {}
	-- Each newly rolled daily board includes Goki's own check-in quest.
	if tierName == "Daily" and Config.QuestById.Daily.d_talk then
		local checkIn = Config.QuestById.Daily.d_talk
		usedStat[checkIn.Stat] = true
		usedId[checkIn.Id] = true
		table.insert(out, { Id = checkIn.Id, Progress = 0, Claimed = false })
	end
	for _, q in ipairs(list) do
		if #out >= count then
			break
		end
		if not usedStat[q.Stat] and not usedId[q.Id] then
			usedStat[q.Stat] = true
			usedId[q.Id] = true
			table.insert(out, { Id = q.Id, Progress = 0, Claimed = false })
		end
	end
	for _, q in ipairs(list) do
		if #out >= count then
			break
		end
		if not usedId[q.Id] then
			usedId[q.Id] = true
			table.insert(out, { Id = q.Id, Progress = 0, Claimed = false })
		end
	end
	return out
end

local function ensureTier(prof: Profile, player: Player, tierName: string)
	local period = Config.PeriodId(tierName, now())
	local slot = prof.Data.Tiers[tierName]
	if not slot or slot.Period ~= period then
		slot = { Period = period, Quests = rollQuests(tierName, player.UserId, period) }
		prof.Data.Tiers[tierName] = slot
	else
		-- drop quests that were removed from the config
		for i = #slot.Quests, 1, -1 do
			if not Config.QuestById[tierName][slot.Quests[i].Id] then
				table.remove(slot.Quests, i)
			end
		end
	end
	return slot
end

---------------------------------------------------------------------------
-- progress
---------------------------------------------------------------------------
local function addStat(player: Player, stat: string, amount: number)
	local prof = profiles[player]
	if not prof or not prof.Loaded or amount <= 0 then
		return
	end
	local isMax = Config.MaxStats[stat] == true
	if isMax then
		prof.Data.Lifetime[stat] = math.max(prof.Data.Lifetime[stat] or 0, amount)
	else
		prof.Data.Lifetime[stat] = (prof.Data.Lifetime[stat] or 0) + amount
	end
	player:SetAttribute("Stat_" .. stat, prof.Data.Lifetime[stat]) -- read by the Overkill HUD profile
	for _, tierName in ipairs(Config.TierOrder) do
		local slot = ensureTier(prof, player, tierName)
		for _, q in ipairs(slot.Quests) do
			local def = Config.QuestById[tierName][q.Id]
			if def and def.Stat == stat and not q.Claimed and q.Progress < def.Goal then
				local before = q.Progress
				if isMax then
					q.Progress = math.min(def.Goal, math.max(q.Progress, amount))
				else
					q.Progress = math.min(def.Goal, q.Progress + amount)
				end
				if q.Progress == before then
					continue
				end
				prof.Pending[tierName .. "|" .. q.Id] = { Tier = tierName, Id = q.Id, Progress = math.floor(q.Progress), Goal = def.Goal }
				if before < def.Goal and q.Progress >= def.Goal then
					table.insert(prof.Toasts, { Tier = tierName, Id = q.Id, Title = def.Title })
				end
			end
		end
	end
end

local function buildBoard(player: Player, tierName: string)
	local prof = profiles[player]
	local slot = ensureTier(prof, player, tierName)
	local quests = {}
	for _, q in ipairs(slot.Quests) do
		local def = Config.QuestById[tierName][q.Id]
		if def then
			table.insert(quests, {
				Id = q.Id,
				Title = def.Title,
				Desc = def.Desc,
				Stat = def.Stat,
				Goal = def.Goal,
				Progress = math.floor(q.Progress),
				Claimed = q.Claimed,
				Reward = def.Reward,
			})
		end
	end
	return {
		Tier = tierName,
		ResetAt = Config.NextReset(tierName, now()),
		Quests = quests,
		Wallet = { Coins = getStat(player, "Coins").Value, XP = getStat(player, "XP").Value },
	}
end

---------------------------------------------------------------------------
-- saving / loading
---------------------------------------------------------------------------
local function key(player: Player): string
	return "u_" .. player.UserId
end

local function save(player: Player)
	local prof = profiles[player]
	if not prof or not prof.Loaded or not prof.CanSave or not store then
		return
	end
	prof.Data.Wallet.Coins = getStat(player, "Coins").Value
	prof.Data.Wallet.XP = getStat(player, "XP").Value
	local data = prof.Data
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(key(player), function()
			return data
		end)
	end)
	if not ok then
		warn("[Quests] save failed for", player.Name, err)
	end
end

local function load(player: Player)
	local prof: Profile = {
		Data = newData(),
		Loaded = false,
		CanSave = store ~= nil,
		Pending = {},
		Toasts = {},
		DistRemainder = 0,
		LastPos = nil,
		Seconds = 0,
		LastJump = 0,
		LastChat = 0,
		LastTalk = -math.huge,
		LastClaim = 0,
		Zones = {},
		ZoneTime = {},
	}
	profiles[player] = prof
	if store then
		local loaded, got = false, nil
		for attempt = 1, 3 do
			local ok, res = pcall(function()
				return (store :: DataStore):GetAsync(key(player))
			end)
			if ok then
				loaded, got = true, res
				break
			end
			warn("[Quests] load attempt", attempt, "failed:", res)
			task.wait(1.5 * attempt)
		end
		if not loaded then
			prof.CanSave = false -- never overwrite data we could not read
		elseif type(got) == "table" then
			prof.Data = got
			prof.Data.Wallet = prof.Data.Wallet or { Coins = 0, XP = 0 }
			prof.Data.Lifetime = prof.Data.Lifetime or {}
			prof.Data.Tiers = prof.Data.Tiers or {}
		end
	end
	if profiles[player] ~= prof or not player.Parent then
		return
	end
	getStat(player, "Coins").Value = prof.Data.Wallet.Coins or 0
	getStat(player, "XP").Value = prof.Data.Wallet.XP or 0
	prof.Loaded = true
	for stat, v in pairs(prof.Data.Lifetime) do
		if type(v) == "number" then
			player:SetAttribute("Stat_" .. stat, v)
		end
	end
	player:SetAttribute("QuestDataLoaded", true) -- ShopServer waits for this before spending coins
	for _, tierName in ipairs(Config.TierOrder) do
		ensureTier(prof, player, tierName)
	end
	local today = now() // 86400
	if prof.Data.LastLoginDay ~= today then
		if prof.Data.LastLoginDay == today - 1 then
			prof.Data.LoginStreak = (prof.Data.LoginStreak or 0) + 1
		else
			prof.Data.LoginStreak = 1
		end
		prof.Data.LastLoginDay = today
		addStat(player, "LoginDays", 1)
	end
	addStat(player, "LoginStreak", prof.Data.LoginStreak or 1)
end

---------------------------------------------------------------------------
-- remotes
---------------------------------------------------------------------------
local function waitLoaded(player: Player): Profile?
	local t0 = os.clock()
	while player.Parent and os.clock() - t0 < 15 do
		local prof = profiles[player]
		if prof and prof.Loaded then
			return prof
		end
		task.wait(0.1)
	end
	return nil
end

GetBoard.OnServerInvoke = function(player: Player, tierName: any)
	if type(tierName) ~= "string" or not Config.Tiers[tierName] then
		return nil
	end
	if not waitLoaded(player) then
		return nil
	end
	return buildBoard(player, tierName)
end

ClaimQuest.OnServerInvoke = function(player: Player, tierName: any, questId: any)
	if type(tierName) ~= "string" or not Config.Tiers[tierName] or type(questId) ~= "string" then
		return { Ok = false, Reason = "Bad request" }
	end
	local prof = profiles[player]
	if not prof or not prof.Loaded then
		return { Ok = false, Reason = "Still loading" }
	end
	if os.clock() - prof.LastClaim < 0.25 then
		return { Ok = false, Reason = "Slow down" }
	end
	prof.LastClaim = os.clock()
	local slot = ensureTier(prof, player, tierName)
	local claimed, coins, xp = {}, 0, 0
	for _, q in ipairs(slot.Quests) do
		local def = Config.QuestById[tierName][q.Id]
		if def and not q.Claimed and q.Progress >= def.Goal and (questId == "*" or questId == q.Id) then
			q.Claimed = true
			coins += def.Reward.Coins or 0
			xp += def.Reward.XP or 0
			table.insert(claimed, q.Id)
		end
	end
	if #claimed == 0 then
		return { Ok = false, Reason = "Nothing to claim", Board = buildBoard(player, tierName) }
	end
	-- shop pass boosts (set by ShopServer)
	coins = math.floor(coins * (1 + (tonumber(player:GetAttribute("CoinBoost")) or 0)) + 0.5)
	xp = math.floor(xp * (1 + (tonumber(player:GetAttribute("XpBoost")) or 0)) + 0.5)
	local c, x = getStat(player, "Coins"), getStat(player, "XP")
	c.Value += coins
	x.Value += xp
	addStat(player, "Claims" .. tierName, #claimed)
	addStat(player, "ClaimsAny", #claimed)
	return { Ok = true, Claimed = claimed, Coins = coins, XP = xp, Board = buildBoard(player, tierName) }
end

ClientReport.OnServerEvent:Connect(function(player: Player, kind: any)
	local prof = profiles[player]
	if not prof then
		return
	end
	if kind == "Jump" then
		if os.clock() - prof.LastJump >= 0.35 then -- a real jump takes longer than this
			prof.LastJump = os.clock()
			addStat(player, "Jumps", 1)
		end
	end
end)

-- other server scripts can report progress: ServerStorage.QuestProgress:Fire(player, "Kills", 1)
local hook = ServerStorage:FindFirstChild("QuestProgress") or Instance.new("BindableEvent")
hook.Name = "QuestProgress"
hook.Parent = ServerStorage
;(hook :: BindableEvent).Event:Connect(function(player: any, stat: any, amount: any)
	if typeof(player) == "Instance" and player:IsA("Player") and type(stat) == "string" then
		addStat(player, stat, tonumber(amount) or 1)
	end
end)

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
local function onPlayer(player: Player)
	task.spawn(load, player)
	player.Chatted:Connect(function()
		local prof = profiles[player]
		if prof and os.clock() - prof.LastChat > 2 then
			prof.LastChat = os.clock()
			addStat(player, "ChatMessages", 1)
		end
	end)
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayer(p)
end

Players.PlayerRemoving:Connect(function(player)
	save(player)
	profiles[player] = nil
end)

game:BindToClose(function()
	local threads = {}
	for player in pairs(profiles) do
		table.insert(threads, task.spawn(save, player))
	end
	task.wait(2)
end)


---------------------------------------------------------------------------
-- zones (visit / time-spent quests)
---------------------------------------------------------------------------
type Spot = { Zone: string, Key: string, Center: Vector3, Radius: number }
local spots: { Spot } = {}

local function findPath(path: { string }): Instance?
	local node: Instance? = workspace
	for _, name in ipairs(path) do
		node = node and node:FindFirstChild(name)
	end
	return node
end

local function centerOf(inst: Instance): Vector3?
	if inst:IsA("Model") then
		local cf, _ = inst:GetBoundingBox()
		return cf.Position
	elseif inst:IsA("BasePart") then
		return inst.Position
	end
	return nil
end

local function refreshSpots()
	local list = {}
	for zone, def in pairs(Config.Zones) do
		if def.Path then
			local inst = findPath(def.Path)
			local c = inst and centerOf(inst)
			if c then
				table.insert(list, { Zone = zone, Key = zone, Center = c, Radius = def.Radius })
			end
		elseif def.Folder then
			local folder = findPath(def.Folder)
			if folder then
				for i, child in ipairs(folder:GetChildren()) do
					local c = centerOf(child)
					if c then
						table.insert(list, { Zone = zone, Key = zone .. "_" .. child.Name .. "_" .. i, Center = c, Radius = def.Radius })
					end
				end
			end
		end
	end
	spots = list
end
task.spawn(function()
	task.wait(3)
	refreshSpots()
	while true do
		task.wait(30)
		refreshSpots()
	end
end)

trackZones = function(player: Player, prof: Profile, pos: Vector3, dt: number)
	local insideZone = {}
	for _, spot in ipairs(spots) do
		local d = Vector3.new(pos.X - spot.Center.X, 0, pos.Z - spot.Center.Z).Magnitude
		local inside = d <= spot.Radius and math.abs(pos.Y - spot.Center.Y) < 30
		local st = prof.Zones[spot.Key]
		if not st then
			st = { Inside = false, Last = -math.huge }
			prof.Zones[spot.Key] = st
		end
		if inside and not st.Inside and os.clock() - st.Last > Config.ZoneVisitCooldown then
			st.Last = os.clock()
			addStat(player, "Visit_" .. spot.Zone, 1)
		end
		st.Inside = inside
		if inside then
			insideZone[spot.Zone] = true
		end
	end
	for zone in pairs(insideZone) do
		local acc = (prof.ZoneTime[zone] or 0) + dt
		local whole = math.floor(acc)
		prof.ZoneTime[zone] = acc - whole
		if whole > 0 then
			addStat(player, "Time_" .. zone, whole)
		end
	end
end

-- play time + distance + pushing progress to clients
task.spawn(function()
	local last = os.clock()
	while true do
		task.wait(1)
		local dt = os.clock() - last
		last = os.clock()
		for player, prof in pairs(profiles) do
			if prof.Loaded then
				prof.Seconds += dt
				if prof.Seconds >= 60 then
					prof.Seconds -= 60
					addStat(player, "PlayMinutes", 1)
					if #Players:GetPlayers() >= 2 then
						addStat(player, "SocialMinutes", 1)
					end
				end
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					local p = root.Position
					if prof.LastPos then
						local d = Vector3.new(p.X - prof.LastPos.X, 0, p.Z - prof.LastPos.Z).Magnitude
						if d < 90 then -- ignore teleports
							prof.DistRemainder += d
							local whole = math.floor(prof.DistRemainder)
							if whole > 0 then
								prof.DistRemainder -= whole
								addStat(player, "Distance", whole)
							end
						end
					end
					prof.LastPos = p
					trackZones(player, prof, p, dt)
				else
					prof.LastPos = nil
				end
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(0.4)
		for player, prof in pairs(profiles) do
			if next(prof.Pending) or #prof.Toasts > 0 then
				local list = {}
				for _, v in pairs(prof.Pending) do
					table.insert(list, v)
				end
				local toasts = prof.Toasts
				prof.Pending = {}
				prof.Toasts = {}
				QuestUpdated:FireClient(player, list, toasts)
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE)
		for player in pairs(profiles) do
			task.spawn(save, player)
		end
	end
end)

---------------------------------------------------------------------------
-- world: [E] prompt + QUESTS sign above the crater
---------------------------------------------------------------------------
local function findHeroes(): Instance?
	local node: Instance = workspace
	for _, name in ipairs(Config.HeroesPath) do
		local nxt = node:WaitForChild(name, 30)
		if not nxt then
			return nil
		end
		node = nxt
	end
	return node
end

task.spawn(function()
	local heroes = findHeroes()
	if not heroes then
		warn("[Quests] could not find the crater heroes at", table.concat(Config.HeroesPath, "."))
		return
	end
	local giver = heroes:WaitForChild(Config.QuestGiver, 10)
	-- podium centre = middle of the three heroes, feet level
	local sum, n, low = Vector3.zero, 0, math.huge
	for _, m in ipairs(heroes:GetChildren()) do
		local root = m:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			sum += root.Position
			n += 1
			low = math.min(low, root.Position.Y - 3)
		end
	end
	if n == 0 then
		return
	end
	local c = sum / n
	local center = Vector3.new(c.X, low, c.Z)

	local folder = Instance.new("Folder")
	folder.Name = "QuestWorld"
	folder.Parent = workspace

	local anchor = Instance.new("Part")
	anchor.Name = "QuestPromptAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(center + Vector3.new(0, 4, 0))
	anchor.Parent = folder

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "QuestPrompt"
	prompt.ActionText = "Quests"
	prompt.ObjectText = ""
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom -- drawn by QuestClient in the quest font
	prompt:SetAttribute("QuestPrompt", true)
	prompt.Parent = anchor

	prompt.Triggered:Connect(function(player)
		local prof = profiles[player]
		if prof and os.clock() - prof.LastTalk > 60 then
			prof.LastTalk = os.clock()
			addStat(player, "TalkToGoki", 1)
		end
	end)

	local titlePart = Instance.new("Part")
	titlePart.Name = "QuestTitleAnchor"
	titlePart.Anchored = true
	titlePart.CanCollide = false
	titlePart.CanQuery = false
	titlePart.CanTouch = false
	titlePart.Transparency = 1
	titlePart.Size = Vector3.new(1, 1, 1)
	titlePart.CFrame = CFrame.new(center + Vector3.new(0, Config.TitleHeight, 0))
	titlePart.Parent = folder

	local style = Config.Style
	local bb = Instance.new("BillboardGui")
	bb.Name = "QuestTitle"
	bb.Size = UDim2.fromScale(Config.TitleSize.X, Config.TitleSize.Y) -- in studs, so it stays big from far away (spawn)
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.AlwaysOnTop = false
	bb.Adornee = titlePart
	bb.Parent = titlePart

	-- same palette as the dialogue subtitles: white text, amber highlight, near-black outline
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.7)
	title.Font = style.Font
	title.Text = "QUESTS"
	title.TextScaled = true
	title.TextColor3 = style.Text
	title.Parent = bb
	local s1 = Instance.new("UIStroke")
	s1.Thickness = 4
	s1.Color = style.TextStroke
	s1.LineJoinMode = Enum.LineJoinMode.Round
	s1.Parent = title

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.BackgroundTransparency = 1
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.fromScale(0.5, 0.7)
	sub.Size = UDim2.fromScale(0.78, 0.26)
	sub.Font = style.Font
	sub.Text = ""
	sub.Visible = false
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(139, 148, 157)
	sub.Parent = bb
	local s2 = Instance.new("UIStroke")
	s2.Thickness = 2
	s2.Color = style.TextStroke
	s2.LineJoinMode = Enum.LineJoinMode.Round
	s2.Parent = sub
end)
