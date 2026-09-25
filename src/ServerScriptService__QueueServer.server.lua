--[[
	QueueServer  (ServerScriptService.QueueServer)
	Matchmaking for the 1v1 / 2v2 / Arena portals, plus parties.

	Flow
	  walk into a portal -> join that mode's queue (solo, or the leader brings the whole party)
	  -> matchmaker forms a match -> ready check (everyone presses ACCEPT)
	  -> countdown -> reserved server teleport to the mode's place (QueueConfig PlaceId)
	  A decline / timeout cancels the match: the player who dodged gets a short queue lock,
	  everyone else goes straight back into the queue with priority and keeps their queue time.

	Studio (or PlaceId = 0): the flow runs to the end and shows a "test match" screen instead of
	teleporting. In Studio, practice bots fill the queues and sit in the party window.

	Client talks through OverkillUI.Remotes.QueueRequest (RemoteFunction, validated + rate limited);
	the server pushes a private snapshot through QueueEvent whenever anything about a player changes.
	Public info lives in attributes: OverkillUI "Queue_<Mode>" (players searching) and
	"QueueWait_<Mode>" (average wait), players "OKQueue" / "OKParty" / "OKLeader" / "OKMatch".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local Config = require(UI:WaitForChild("QueueConfig"))
local Theme = require(UI:WaitForChild("Theme"))
local Remotes = UI:WaitForChild("Remotes")
local Request = Remotes:WaitForChild("QueueRequest") :: RemoteFunction
local Event = Remotes:WaitForChild("QueueEvent") :: RemoteEvent

local IS_STUDIO = RunService:IsStudio()
local BOTS = IS_STUDIO and Config.StudioBots == true

local function now(): number
	return workspace:GetServerTimeNow()
end

local idSeq = 0
local function nextId(prefix: string): string
	idSeq += 1
	return prefix .. idSeq
end

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
-- member: { UserId, Name, DisplayName, Player?, Bot, Level? }
local members: { [number]: any } = {}
local parties: { [string]: any } = {} -- { Id, Leader, Members = {member}, Invites = {[userId] = expires} }
local partyOf: { [number]: any } = {}
local invitesTo: { [number]: { [string]: any } } = {} -- target userId -> partyId -> { PartyId, From, Expires }
local queues: { [string]: { any } } = {} -- mode -> { entry }  entry = { Id, Mode, Members, Party, JoinedAt, Priority }
local entryOf: { [number]: any } = {}
local matches: { [string]: any } = {}
local matchOf: { [number]: any } = {}
local dodgeUntil: { [number]: number } = {}
local lobbyBots: { any } = {}
local waitAverage: { [string]: number } = {}
local countsDirty = true

for _, id in ipairs(Config.Order) do
	queues[id] = {}
end

-- practice bots that filled a queue are forgotten once they're out of the queue and the match
local function forgetBot(x: any)
	if x.Bot and not x.Lobby and not entryOf[x.UserId] and not matchOf[x.UserId] then
		members[x.UserId] = nil
	end
end

local function levelOf(m: any): number
	if m.Bot then
		return m.Level or 1
	end
	local pl = m.Player
	local ls = pl and pl:FindFirstChild("leaderstats")
	local xp = ls and ls:FindFirstChild("XP")
	if xp and (xp:IsA("IntValue") or xp:IsA("NumberValue")) then
		return (Theme.LevelFromXp((xp :: any).Value))
	end
	return 1
end

local function memberView(m: any)
	return { UserId = m.UserId, Name = m.Name, DisplayName = m.DisplayName, Bot = m.Bot == true, Level = levelOf(m) }
end

---------------------------------------------------------------------------
-- pushing state to clients
---------------------------------------------------------------------------
local function partyView(p: any)
	if not p then
		return nil
	end
	local list = {}
	for _, x in ipairs(p.Members) do
		table.insert(list, memberView(x))
	end
	local pending = {}
	for uid, exp in pairs(p.Invites) do
		local t = members[uid]
		if t then
			local v = memberView(t)
			v.Expires = exp
			table.insert(pending, v)
		end
	end
	return { Id = p.Id, Leader = p.Leader.UserId, Members = list, Pending = pending, Max = Config.MaxPartySize }
end

local function matchView(match: any, m: any)
	local teamOf = {}
	if match.Teams then
		for ti, team in ipairs(match.Teams) do
			for _, x in ipairs(team) do
				teamOf[x.UserId] = ti
			end
		end
	end
	local list = {}
	for _, x in ipairs(match.Members) do
		local v = memberView(x)
		v.Team = teamOf[x.UserId]
		v.Accepted = match.Accepted[x.UserId] == true
		table.insert(list, v)
	end
	return {
		Id = match.Id,
		Mode = match.Mode,
		Stage = match.Stage,
		Deadline = match.Deadline,
		StartAt = match.StartAt,
		TestAt = match.TestAt,
		EndAt = match.EndAt,
		Private = match.Private == true,
		Live = match.Live == true,
		Players = list,
		You = m.UserId,
	}
end

-- an entry only matches while nobody in it is busy (in a quest dialogue)
local function entryReady(e: any): (boolean, any)
	for _, x in ipairs(e.Members) do
		if x.Busy then
			return false, x
		end
	end
	return true, nil
end

local function snapshot(m: any)
	local s: any = { Time = now(), You = m.UserId }
	local e = entryOf[m.UserId]
	if e then
		local ready, who = entryReady(e)
		s.Queue = {
			Mode = e.Mode,
			JoinedAt = e.JoinedAt,
			Priority = e.Priority == true,
			Size = #e.Members,
			Leader = e.Members[1].UserId,
			Paused = not ready,
			PausedBy = if who then who.DisplayName else nil,
		}
	end
	s.Party = partyView(partyOf[m.UserId])
	local inv = {}
	for _, i in pairs(invitesTo[m.UserId] or {}) do
		local p = parties[i.PartyId]
		local from = members[i.From]
		if p and from then
			local heads = {}
			for _, x in ipairs(p.Members) do
				table.insert(heads, memberView(x))
			end
			table.insert(inv, { PartyId = i.PartyId, From = memberView(from), Expires = i.Expires, Members = heads })
		end
	end
	table.sort(inv, function(a, b)
		return a.Expires < b.Expires
	end)
	s.Invites = inv
	local match = matchOf[m.UserId]
	if match then
		s.Match = matchView(match, m)
	end
	local d = dodgeUntil[m.UserId]
	if d and d > now() then
		s.Dodge = d
	end
	if BOTS then
		local bots = {}
		for _, b in ipairs(lobbyBots) do
			local v = memberView(b)
			v.InParty = partyOf[b.UserId] ~= nil
			table.insert(bots, v)
		end
		s.Bots = bots
	end
	return s
end

local function syncAttributes(m: any)
	local pl = m.Player
	if not (pl and pl.Parent) then
		return
	end
	local e = entryOf[m.UserId]
	local p = partyOf[m.UserId]
	pl:SetAttribute("OKQueue", if e then e.Mode else nil)
	pl:SetAttribute("OKParty", if p then p.Id else nil)
	pl:SetAttribute("OKLeader", if p and p.Leader == m then true else nil)
	pl:SetAttribute("OKMatch", if matchOf[m.UserId] then true else nil)
end

local function push(m: any)
	if not m or m.Bot then
		return
	end
	syncAttributes(m)
	local pl = m.Player
	if pl and pl.Parent then
		Event:FireClient(pl, "State", snapshot(m))
	end
end

local function pushAll(list: { any })
	for _, m in ipairs(list) do
		push(m)
	end
end

-- a toast on one player's screen. kind: "info" | "good" | "error" | "party"
local function notify(m: any, title: string, text: string, kind: string?, mode: string?)
	if m and not m.Bot and m.Player and m.Player.Parent then
		Event:FireClient(m.Player, "Notice", { Title = title, Text = text, Kind = kind or "info", Mode = mode })
	end
end

---------------------------------------------------------------------------
-- queue entries
---------------------------------------------------------------------------
local function newEntry(modeId: string, group: { any }, party: any)
	return { Id = nextId("Q"), Mode = modeId, Members = table.clone(group), Party = party, JoinedAt = now(), Priority = false }
end

local function removeEntry(e: any, title: string?, text: string?, except: any?)
	local q = queues[e.Mode]
	local i = table.find(q, e)
	if i then
		table.remove(q, i)
	end
	for _, x in ipairs(e.Members) do
		if entryOf[x.UserId] == e then
			entryOf[x.UserId] = nil
		end
		push(x)
		if title and x ~= except then
			notify(x, title, text or "", "info", e.Mode)
		end
	end
	countsDirty = true
end

local function cancelPartyEntry(p: any, text: string)
	for _, x in ipairs(p.Members) do
		local e = entryOf[x.UserId]
		if e and e.Party == p then
			removeEntry(e, "SEARCH CANCELLED", text)
			return
		end
	end
end

local function recordWait(modeId: string, seconds: number)
	local old = waitAverage[modeId]
	waitAverage[modeId] = if old then old * 0.7 + seconds * 0.3 else seconds
	countsDirty = true
end

local function publishCounts()
	countsDirty = false
	for _, id in ipairs(Config.Order) do
		local n = 0
		for _, e in ipairs(queues[id]) do
			n += #e.Members
		end
		UI:SetAttribute("Queue_" .. id, n)
		UI:SetAttribute("QueueWait_" .. id, if waitAverage[id] then math.floor(waitAverage[id] + 0.5) else nil)
	end
end

---------------------------------------------------------------------------
-- matches
---------------------------------------------------------------------------
local accept -- forward

local function createMatch(modeId: string, entries: { any }, teams: { { any } }?, private: boolean?)
	local match = {
		Id = nextId("M"),
		Mode = modeId,
		Entries = entries,
		Members = {},
		Teams = teams,
		Accepted = {},
		Stage = "ready",
		Deadline = now() + Config.AcceptSeconds,
		Private = private == true,
		Retried = {},
	}
	for _, e in ipairs(entries) do
		local q = queues[e.Mode]
		local i = table.find(q, e)
		if i then
			table.remove(q, i)
		end
		if not private then
			recordWait(modeId, now() - e.JoinedAt)
		end
		for _, x in ipairs(e.Members) do
			table.insert(match.Members, x)
			if entryOf[x.UserId] == e then
				entryOf[x.UserId] = nil
			end
			matchOf[x.UserId] = match
			if x.Bot then
				task.delay(0.8 + math.random() * 2.2, function()
					accept(x, match)
				end)
			end
		end
	end
	matches[match.Id] = match
	pushAll(match.Members)
	countsDirty = true
	return match
end

accept = function(m: any, expected: any?)
	local match = matchOf[m.UserId]
	if not match or (expected and match ~= expected) or match.Stage ~= "ready" then
		return
	end
	match.Accepted[m.UserId] = true
	local all = true
	for _, x in ipairs(match.Members) do
		if not match.Accepted[x.UserId] then
			all = false
			break
		end
	end
	if all then
		match.Stage = "starting"
		match.StartAt = now() + Config.StartSeconds
	end
	pushAll(match.Members)
end

local function sendCancelled(m: any, info: any)
	if not m.Bot and m.Player and m.Player.Parent then
		Event:FireClient(m.Player, "Cancelled", info)
	end
end

-- culprits: members who declined / timed out / left. why: "declined" | "timeout" | "left"
local function cancelMatch(match: any, culprits: { any }, why: string)
	if not matches[match.Id] then
		return
	end
	matches[match.Id] = nil
	match.Stage = "cancelled"
	local bad = {}
	local names = {}
	for _, c in ipairs(culprits) do
		bad[c.UserId] = true
		table.insert(names, c.DisplayName)
	end
	local who = if #names == 1 then names[1] else "Some players"
	for _, e in ipairs(match.Entries) do
		local dropped = match.Private
		for _, x in ipairs(e.Members) do
			if bad[x.UserId] then
				dropped = true
			end
		end
		for _, x in ipairs(e.Members) do
			if matchOf[x.UserId] == match then
				matchOf[x.UserId] = nil
			end
		end
		if dropped then
			for _, x in ipairs(e.Members) do
				forgetBot(x)
				if bad[x.UserId] then
					local locked = why ~= "left" and not x.Bot and not match.Private
					if locked then
						dodgeUntil[x.UserId] = now() + Config.DodgeSeconds
					end
					sendCancelled(x, {
						Mode = match.Mode,
						You = true,
						Requeued = false,
						Title = if why == "timeout" then "MATCH MISSED" else "MATCH DECLINED",
						Text = if why == "timeout" then "You didn't accept in time." else "You declined the match.",
						Lock = if locked then Config.DodgeSeconds else nil,
					})
				else
					sendCancelled(x, {
						Mode = match.Mode,
						Requeued = false,
						Title = "MATCH CANCELLED",
						Text = if match.Private then who .. " didn't accept the duel." else who .. " in your party didn't accept.",
					})
				end
			end
		else
			e.Priority = true
			table.insert(queues[e.Mode], e)
			for _, x in ipairs(e.Members) do
				entryOf[x.UserId] = e
				sendCancelled(x, {
					Mode = match.Mode,
					Requeued = true,
					Title = "MATCH CANCELLED",
					Text = if why == "left" then who .. " left the game." else "A player didn't accept.",
				})
			end
		end
	end
	pushAll(match.Members)
	countsDirty = true
end

-- everyone leaves the match without going back into the queue (test match over, teleport done)
local function releaseMatch(match: any)
	matches[match.Id] = nil
	for _, x in ipairs(match.Members) do
		if matchOf[x.UserId] == match then
			matchOf[x.UserId] = nil
		end
		forgetBot(x)
	end
	pushAll(match.Members)
end

-- the teleport didn't happen: put everyone back in the queue with priority
local function failMatch(match: any, reason: string)
	if not matches[match.Id] then
		return
	end
	matches[match.Id] = nil
	for _, e in ipairs(match.Entries) do
		local present = true
		for _, x in ipairs(e.Members) do
			if matchOf[x.UserId] == match then
				matchOf[x.UserId] = nil
			end
			if not x.Bot and not (x.Player and x.Player.Parent) then
				present = false
			end
		end
		if present and not match.Private then
			e.Priority = true
			table.insert(queues[e.Mode], e)
			for _, x in ipairs(e.Members) do
				entryOf[x.UserId] = e
			end
		end
		for _, x in ipairs(e.Members) do
			notify(x, "COULDN'T START THE MATCH", reason .. (if match.Private then "" else " You're back in the queue."), "error", match.Mode)
		end
	end
	pushAll(match.Members)
	countsDirty = true
end

local function teleportData(match: any)
	local teams = nil
	if match.Teams then
		teams = {}
		for ti, team in ipairs(match.Teams) do
			teams[ti] = {}
			for _, x in ipairs(team) do
				table.insert(teams[ti], x.UserId)
			end
		end
	end
	local list = {}
	for _, x in ipairs(match.Members) do
		if not x.Bot then
			table.insert(list, x.UserId)
		end
	end
	return { Mode = match.Mode, MatchId = match.Id, Teams = teams, Players = list }
end

local function startMatch(match: any)
	local mode = Config.Modes[match.Mode]
	match.Stage = "teleporting"
	match.Live = mode.PlaceId ~= 0 and not IS_STUDIO
	if not match.Live then
		-- test run: show the teleport screen, then the "test match" card
		match.TestAt = now() + 2.6
		pushAll(match.Members)
		return
	end
	match.Deadline = now() + Config.TeleportTimeout
	pushAll(match.Members)
	local list = {}
	for _, x in ipairs(match.Members) do
		if not x.Bot and x.Player and x.Player.Parent then
			table.insert(list, x.Player)
		end
	end
	task.spawn(function()
		local okR, code = pcall(function()
			return TeleportService:ReserveServer(mode.PlaceId)
		end)
		if not okR or type(code) ~= "string" then
			warn("[Queue] ReserveServer failed:", code)
			failMatch(match, "No match server was available.")
			return
		end
		local opts = Instance.new("TeleportOptions")
		opts.ReservedServerAccessCode = code
		opts:SetTeleportData(teleportData(match))
		match.Options = opts
		local okT, err = pcall(function()
			TeleportService:TeleportAsync(mode.PlaceId, list, opts)
		end)
		if not okT then
			warn("[Queue] TeleportAsync failed:", err)
			failMatch(match, "The teleport failed.")
		end
	end)
end

TeleportService.TeleportInitFailed:Connect(function(pl: Player, result, message)
	local m = members[pl.UserId]
	local match = m and matchOf[pl.UserId]
	if not (match and match.Stage == "teleporting" and match.Live and match.Options) then
		return
	end
	warn("[Queue] teleport init failed for", pl.Name, result, message)
	if not match.Retried[pl.UserId] then
		match.Retried[pl.UserId] = true
		task.wait(1.5)
		pcall(function()
			TeleportService:TeleportAsync(Config.Modes[match.Mode].PlaceId, { pl }, match.Options)
		end)
	else
		matchOf[pl.UserId] = nil
		notify(m, "COULDN'T JOIN THE MATCH", "The teleport failed. Walk into a portal to search again.", "error", match.Mode)
		push(m)
	end
end)

local function decline(m: any)
	local match = matchOf[m.UserId]
	if match and match.Stage == "ready" then
		cancelMatch(match, { m }, "declined")
	end
end

local function dismissTest(m: any)
	local match = matchOf[m.UserId]
	if match and match.Stage == "test" then
		matchOf[m.UserId] = nil
		push(m)
		local anyone = false
		for _, x in ipairs(match.Members) do
			if matchOf[x.UserId] == match and not x.Bot then
				anyone = true
			end
		end
		if not anyone then
			releaseMatch(match)
		end
	end
end

local function matchTick(t: number)
	for _, match in pairs(matches) do
		if match.Stage == "ready" and t >= match.Deadline then
			local late = {}
			for _, x in ipairs(match.Members) do
				if not match.Accepted[x.UserId] then
					table.insert(late, x)
				end
			end
			cancelMatch(match, late, "timeout")
		elseif match.Stage == "starting" and t >= (match.StartAt or 0) then
			startMatch(match)
		elseif match.Stage == "teleporting" and not match.Live and t >= (match.TestAt or 0) then
			match.Stage = "test"
			match.EndAt = t + 9
			pushAll(match.Members)
		elseif match.Stage == "test" and t >= (match.EndAt or 0) then
			releaseMatch(match)
		elseif match.Stage == "teleporting" and match.Live and t >= match.Deadline then
			failMatch(match, "The match server didn't respond.")
		end
	end
end

---------------------------------------------------------------------------
-- matchmaking
---------------------------------------------------------------------------
local function sorted(modeId: string)
	local q = queues[modeId]
	table.sort(q, function(a, b)
		if a.Priority ~= b.Priority then
			return a.Priority
		end
		return a.JoinedAt < b.JoinedAt
	end)
	return q
end

local function tryDuel(): boolean
	local picks = {}
	for _, e in ipairs(sorted("Duel")) do
		if #e.Members == 1 and entryReady(e) then
			table.insert(picks, e)
			if #picks == 2 then
				createMatch("Duel", picks, { { picks[1].Members[1] }, { picks[2].Members[1] } })
				return true
			end
		end
	end
	return false
end

local function tryDuos(): boolean
	local teams = {}
	local pending = nil
	for _, e in ipairs(sorted("Duos")) do
		if not entryReady(e) then
			continue
		end
		if #e.Members == 2 then
			table.insert(teams, { entries = { e }, members = { e.Members[1], e.Members[2] } })
		elseif pending then
			table.insert(teams, { entries = { pending, e }, members = { pending.Members[1], e.Members[1] } })
			pending = nil
		else
			pending = e
		end
		if #teams == 2 then
			local entries = {}
			for _, team in ipairs(teams) do
				for _, x in ipairs(team.entries) do
					table.insert(entries, x)
				end
			end
			createMatch("Duos", entries, { teams[1].members, teams[2].members })
			return true
		end
	end
	return false
end

local function tryArena(): boolean
	local mode = Config.Modes.Arena
	local q = {}
	for _, e in ipairs(sorted("Arena")) do
		if entryReady(e) then
			table.insert(q, e)
		end
	end
	local picks, total = {}, 0
	for _, e in ipairs(q) do
		if total + #e.Members <= mode.Players then
			table.insert(picks, e)
			total += #e.Members
		end
		if total == mode.Players then
			break
		end
	end
	local oldest = q[1]
	if total == mode.Players or (total >= mode.MinPlayers and oldest and now() - oldest.JoinedAt >= mode.EarlyStart) then
		createMatch("Arena", picks, nil)
		return true
	end
	return false
end

local TRY = { Duel = tryDuel, Duos = tryDuos, Arena = tryArena }
local function matchmake()
	for _, id in ipairs(Config.Order) do
		local guard = 0
		while TRY[id]() and guard < 20 do
			guard += 1
		end
	end
end

---------------------------------------------------------------------------
-- joining / leaving the queue
---------------------------------------------------------------------------
local noticeCooldown: { [number]: number } = {}
local function throttledNotify(m: any, title: string, text: string, kind: string?, mode: string?)
	local t = os.clock()
	if (noticeCooldown[m.UserId] or 0) > t then
		return
	end
	noticeCooldown[m.UserId] = t + 2.5
	notify(m, title, text, kind, mode)
end

local function join(m: any, modeId: string)
	local mode = Config.Modes[modeId]
	if not mode or m.Bot then
		return
	end
	if matchOf[m.UserId] then
		return
	end
	local party = partyOf[m.UserId]
	if party and party.Leader ~= m then
		throttledNotify(m, "ONLY THE LEADER CAN QUEUE", party.Leader.DisplayName .. " picks the mode for your party.", "info", modeId)
		return
	end
	local group = if party then party.Members else { m }
	for _, x in ipairs(group) do
		if matchOf[x.UserId] then
			throttledNotify(m, "PARTY BUSY", x.DisplayName .. " is still in a match.", "error", modeId)
			return
		end
		local d = dodgeUntil[x.UserId]
		if d and d > now() then
			local who = if x == m then "You" else x.DisplayName
			throttledNotify(m, "QUEUE LOCKED", ("%s can queue again in %d seconds."):format(who, math.ceil(d - now())), "error", modeId)
			return
		end
	end
	local block = Config.PartyBlock(modeId, #group)
	if block then
		throttledNotify(m, "PARTY TOO BIG", block .. ".", "error", modeId)
		return
	end
	local existing = entryOf[m.UserId]
	if existing then
		if existing.Mode == modeId then
			if m.Player then
				Event:FireClient(m.Player, "Pulse", modeId)
			end
			return
		end
		removeEntry(existing)
	end
	local e = newEntry(modeId, group, party)
	if modeId == "Duel" and #group == 2 then
		-- a party of two in the 1v1 portal: a private duel against each other
		createMatch("Duel", { e }, { { group[1] }, { group[2] } }, true)
		return
	end
	table.insert(queues[modeId], e)
	for _, x in ipairs(group) do
		entryOf[x.UserId] = e
		push(x)
		if x ~= m then
			notify(x, "PARTY SEARCHING", m.DisplayName .. " started a " .. mode.Short .. " search.", "party", modeId)
		end
	end
	countsDirty = true
end

local function leaveQueue(m: any)
	local e = entryOf[m.UserId]
	if not e then
		return
	end
	local text = m.DisplayName .. " cancelled the search."
	removeEntry(e, "SEARCH CANCELLED", text, m)
end

---------------------------------------------------------------------------
-- parties
---------------------------------------------------------------------------
local function newParty(leader: any)
	local p = { Id = nextId("P"), Leader = leader, Members = { leader }, Invites = {} }
	parties[p.Id] = p
	partyOf[leader.UserId] = p
	return p
end

local function pushParty(p: any)
	pushAll(p.Members)
	for uid in pairs(p.Invites) do
		if members[uid] then
			push(members[uid])
		end
	end
end

local function dissolve(p: any)
	parties[p.Id] = nil
	for uid in pairs(p.Invites) do
		local inv = invitesTo[uid]
		if inv then
			inv[p.Id] = nil
		end
		if members[uid] then
			push(members[uid])
		end
	end
	p.Invites = {}
	for _, x in ipairs(p.Members) do
		if partyOf[x.UserId] == p then
			partyOf[x.UserId] = nil
		end
		push(x)
	end
end

-- a party with one member and no open invites is no party
local function tidy(p: any)
	if parties[p.Id] and #p.Members <= 1 and next(p.Invites) == nil then
		dissolve(p)
		return true
	end
	return false
end

local function removeFromParty(m: any, title: string?, textForOthers: string?)
	local p = partyOf[m.UserId]
	if not p then
		return
	end
	cancelPartyEntry(p, textForOthers or (m.DisplayName .. " left the party."))
	local i = table.find(p.Members, m)
	if i then
		table.remove(p.Members, i)
	end
	partyOf[m.UserId] = nil
	if #p.Members == 0 then
		dissolve(p)
		push(m)
		return
	end
	if p.Leader == m and p.Members[1] then
		p.Leader = p.Members[1]
		notify(p.Leader, "YOU'RE THE LEADER", "You now lead the party.", "party")
	end
	for _, x in ipairs(p.Members) do
		if title then
			notify(x, title, textForOthers or "", "party")
		end
	end
	push(m)
	if not tidy(p) then
		pushParty(p)
	end
end

local respond -- forward

local function invite(from: any, targetId: number)
	local target = members[targetId]
	if not target or target == from then
		return
	end
	if matchOf[from.UserId] then
		notify(from, "IN A MATCH", "You can invite players after your match.", "error")
		return
	end
	local p = partyOf[from.UserId]
	if p and p.Leader ~= from then
		notify(from, "LEADER ONLY", "Only " .. p.Leader.DisplayName .. " can invite players.", "error")
		return
	end
	local theirs = partyOf[target.UserId]
	if theirs then
		if theirs ~= p then
			notify(from, "ALREADY IN A PARTY", target.DisplayName .. " is already in a party.", "error")
		end
		return
	end
	local size = if p then #p.Members else 1
	local pendingCount = 0
	if p then
		for _ in pairs(p.Invites) do
			pendingCount += 1
		end
	end
	if size >= Config.MaxPartySize then
		notify(from, "PARTY FULL", ("Parties can have up to %d players."):format(Config.MaxPartySize), "error")
		return
	end
	if size + pendingCount >= Config.MaxPartySize + 2 then
		notify(from, "TOO MANY INVITES", "Wait for someone to answer first.", "error")
		return
	end
	if not p then
		p = newParty(from)
	end
	local exp = now() + Config.InviteSeconds
	p.Invites[target.UserId] = exp
	invitesTo[target.UserId] = invitesTo[target.UserId] or {}
	invitesTo[target.UserId][p.Id] = { PartyId = p.Id, From = from.UserId, Expires = exp }
	pushParty(p)
	push(target)
	if target.Player then
		Event:FireClient(target.Player, "Invited", from.DisplayName)
	end
	if target.Bot then
		local pid = p.Id
		task.delay(1.2 + math.random() * 1.3, function()
			respond(target, pid, true)
		end)
	end
end

respond = function(target: any, partyId: string, yes: boolean)
	local list = invitesTo[target.UserId]
	local inv = list and list[partyId]
	if not inv then
		notify(target, "INVITE EXPIRED", "That invite isn't open any more.", "error")
		push(target)
		return
	end
	list[partyId] = nil
	local p = parties[partyId]
	if p then
		p.Invites[target.UserId] = nil
	end
	if not yes then
		if p then
			notify(p.Leader, "INVITE DECLINED", target.DisplayName .. " declined your invite.", "party")
			if not tidy(p) then
				pushParty(p)
			end
		end
		push(target)
		return
	end
	if not p then
		notify(target, "PARTY GONE", "That party doesn't exist any more.", "error")
		push(target)
		return
	end
	local own = partyOf[target.UserId]
	if own and own ~= p and #own.Members <= 1 then
		-- a "party" of just you (waiting on your own invites) gives way to the one you're joining
		dissolve(own)
	end
	if partyOf[target.UserId] then
		notify(target, "LEAVE YOUR PARTY FIRST", "You're already in a party.", "error")
		pushParty(p)
		push(target)
		return
	end
	if matchOf[target.UserId] then
		notify(target, "IN A MATCH", "Finish your match first.", "error")
		pushParty(p)
		push(target)
		return
	end
	if #p.Members >= Config.MaxPartySize then
		notify(target, "PARTY FULL", "That party filled up.", "error")
		pushParty(p)
		push(target)
		return
	end
	local mine = entryOf[target.UserId]
	if mine then
		removeEntry(mine)
	end
	cancelPartyEntry(p, target.DisplayName .. " joined the party - walk into a portal to search again.")
	table.insert(p.Members, target)
	partyOf[target.UserId] = p
	-- any other open invites to this player are now moot
	for pid in pairs(invitesTo[target.UserId] or {}) do
		local other = parties[pid]
		if other then
			other.Invites[target.UserId] = nil
			if not tidy(other) then
				pushParty(other)
			end
		end
	end
	invitesTo[target.UserId] = nil
	for _, x in ipairs(p.Members) do
		if x == target then
			notify(x, "JOINED THE PARTY", "You're in " .. p.Leader.DisplayName .. "'s party.", "party")
		else
			notify(x, "NEW PARTY MEMBER", target.DisplayName .. " joined the party.", "party")
		end
	end
	pushParty(p)
end

local function kick(leader: any, targetId: number)
	local p = partyOf[leader.UserId]
	local target = members[targetId]
	if not (p and target and p.Leader == leader and partyOf[targetId] == p and target ~= leader) then
		return
	end
	removeFromParty(target, "PLAYER REMOVED", target.DisplayName .. " was removed from the party.")
	notify(target, "REMOVED FROM PARTY", leader.DisplayName .. " removed you from the party.", "error")
end

local function promote(leader: any, targetId: number)
	local p = partyOf[leader.UserId]
	local target = members[targetId]
	if not (p and target and p.Leader == leader and partyOf[targetId] == p and target ~= leader) then
		return
	end
	cancelPartyEntry(p, "The party has a new leader.")
	p.Leader = target
	-- leader always first in the list
	local i = table.find(p.Members, target)
	if i then
		table.remove(p.Members, i)
		table.insert(p.Members, 1, target)
	end
	for _, x in ipairs(p.Members) do
		notify(x, "NEW PARTY LEADER", target.DisplayName .. " now leads the party.", "party")
	end
	pushParty(p)
end

local function cancelInvite(leader: any, targetId: number)
	local p = partyOf[leader.UserId]
	if not (p and p.Leader == leader and p.Invites[targetId]) then
		return
	end
	p.Invites[targetId] = nil
	local list = invitesTo[targetId]
	if list then
		list[p.Id] = nil
	end
	if members[targetId] then
		push(members[targetId])
	end
	if not tidy(p) then
		pushParty(p)
	end
end

local function inviteTick(t: number)
	for _, p in pairs(parties) do
		local changed = false
		for uid, exp in pairs(p.Invites) do
			if t >= exp then
				p.Invites[uid] = nil
				local list = invitesTo[uid]
				if list then
					list[p.Id] = nil
				end
				if members[uid] then
					push(members[uid])
				end
				changed = true
			end
		end
		if changed and not tidy(p) then
			pushParty(p)
		end
	end
end

---------------------------------------------------------------------------
-- Studio practice bots
---------------------------------------------------------------------------
local botSeq = 0
local function newBot()
	botSeq += 1
	local name = Config.BotNames[(botSeq - 1) % #Config.BotNames + 1]
	local b = { UserId = -1000 - botSeq, Name = string.lower(name) .. "_bot", DisplayName = name, Bot = true, Lobby = false, Level = math.random(2, 38) }
	members[b.UserId] = b
	return b
end

local botNext: { [string]: number } = {}
local function botsTick(t: number)
	for _, id in ipairs(Config.Order) do
		local q = queues[id]
		local real, total = 0, 0
		for _, e in ipairs(q) do
			total += #e.Members
			for _, x in ipairs(e.Members) do
				if not x.Bot then
					real += 1
				end
			end
		end
		if real == 0 then
			botNext[id] = nil
			for i = #q, 1, -1 do
				local e = q[i]
				local allBots = true
				for _, x in ipairs(e.Members) do
					if not x.Bot then
						allBots = false
					end
				end
				if allBots then
					table.remove(q, i)
					for _, x in ipairs(e.Members) do
						entryOf[x.UserId] = nil
						members[x.UserId] = nil
					end
					countsDirty = true
				end
			end
		else
			if not botNext[id] then
				botNext[id] = t + 2 + math.random() * 2.5
			end
			if t >= botNext[id] and total < Config.Modes[id].Players then
				local size = if id == "Duos" and math.random() < 0.35 and total <= Config.Modes[id].Players - 2 then 2 else 1
				local group = {}
				for _ = 1, size do
					table.insert(group, newBot())
				end
				local e = newEntry(id, group, nil)
				table.insert(q, e)
				for _, x in ipairs(group) do
					entryOf[x.UserId] = e
				end
				botNext[id] = t + 2.5 + math.random() * 3.5
				countsDirty = true
			end
		end
	end
end

---------------------------------------------------------------------------
-- portals: walking into the doorway joins that mode's queue
---------------------------------------------------------------------------
local zones = {}
task.spawn(function()
	local folder = workspace:WaitForChild("Portals", 60)
	if not folder then
		warn("[Queue] no Portals folder - queues can't be joined")
		return
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local modeId = model:GetAttribute("QueueMode")
			if not modeId then
				for id, m in pairs(Config.Modes) do
					if m.Portal == model.Name then
						modeId = id
					end
				end
			end
			local pane = nil
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and d.Transparency > 0.3 and (not pane or d.Size.Magnitude > pane.Size.Magnitude) then
					pane = d
				end
			end
			if modeId and Config.Modes[modeId] and pane then
				pane.CanCollide = false
				local s = pane.Size
				-- the doorway, a little deeper than the glass so a walk-through always registers
				table.insert(zones, { Mode = modeId, CFrame = pane.CFrame, Half = Vector3.new(s.X / 2 + 0.4, s.Y / 2 + 1.5, math.max(s.Z, 0.5) / 2 + 2.4) })
			end
		end
	end
end)

local inZone: { [number]: any } = {}
local function zoneTick()
	for _, pl in ipairs(Players:GetPlayers()) do
		local m = members[pl.UserId]
		local char = pl.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local found = nil
		if m and root and root:IsA("BasePart") and hum and hum.Health > 0 then
			for _, z in ipairs(zones) do
				local rel = z.CFrame:PointToObjectSpace(root.Position)
				if math.abs(rel.X) <= z.Half.X and math.abs(rel.Y) <= z.Half.Y and math.abs(rel.Z) <= z.Half.Z then
					found = z
					break
				end
			end
		end
		if found and inZone[pl.UserId] ~= found then
			join(m, found.Mode)
		end
		inZone[pl.UserId] = found
	end
end

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
local function onPlayer(pl: Player)
	local m = { UserId = pl.UserId, Name = pl.Name, DisplayName = pl.DisplayName, Player = pl, Bot = false }
	members[pl.UserId] = m
end
for _, pl in ipairs(Players:GetPlayers()) do
	onPlayer(pl)
end
Players.PlayerAdded:Connect(onPlayer)

Players.PlayerRemoving:Connect(function(pl: Player)
	local m = members[pl.UserId]
	if not m then
		return
	end
	local match = matchOf[pl.UserId]
	if match then
		if match.Stage == "ready" or match.Stage == "starting" then
			cancelMatch(match, { m }, "left")
		else
			matchOf[pl.UserId] = nil
			local anyone = false
			for _, x in ipairs(match.Members) do
				if matchOf[x.UserId] == match and not x.Bot then
					anyone = true
				end
			end
			if not anyone then
				matches[match.Id] = nil
			end
		end
	end
	local e = entryOf[pl.UserId]
	if e then
		removeEntry(e, "SEARCH CANCELLED", m.DisplayName .. " left the game.", m)
	end
	if partyOf[pl.UserId] then
		removeFromParty(m, "PLAYER LEFT", m.DisplayName .. " left the game.")
	end
	for pid in pairs(invitesTo[pl.UserId] or {}) do
		local p = parties[pid]
		if p then
			p.Invites[pl.UserId] = nil
			if not tidy(p) then
				pushParty(p)
			end
		end
	end
	invitesTo[pl.UserId] = nil
	dodgeUntil[pl.UserId] = nil
	noticeCooldown[pl.UserId] = nil
	inZone[pl.UserId] = nil
	members[pl.UserId] = nil
end)

if BOTS then
	for _ = 1, Config.LobbyBots or 0 do
		local b = newBot()
		b.Lobby = true
		table.insert(lobbyBots, b)
	end
end

---------------------------------------------------------------------------
-- requests from clients
---------------------------------------------------------------------------
local budget: { [Player]: { t: number, n: number } } = {}
Players.PlayerRemoving:Connect(function(pl)
	budget[pl] = nil
end)

Request.OnServerInvoke = function(pl: Player, action: any, a: any, b: any)
	local bucket = budget[pl]
	local t = os.clock()
	if not bucket or t - bucket.t > 1 then
		bucket = { t = t, n = 0 }
		budget[pl] = bucket
	end
	bucket.n += 1
	if bucket.n > 15 then
		return nil
	end
	local m = members[pl.UserId]
	if not m or type(action) ~= "string" then
		return nil
	end
	if action == "leave" then
		leaveQueue(m)
	elseif action == "accept" then
		accept(m)
	elseif action == "decline" then
		decline(m)
	elseif action == "dismiss" then
		dismissTest(m)
	elseif action == "invite" and type(a) == "number" then
		invite(m, a)
	elseif action == "respond" and type(a) == "string" then
		respond(m, a, b == true)
	elseif action == "cancelInvite" and type(a) == "number" then
		cancelInvite(m, a)
	elseif action == "leaveParty" then
		if partyOf[pl.UserId] then
			removeFromParty(m, "PLAYER LEFT", m.DisplayName .. " left the party.")
			notify(m, "LEFT THE PARTY", "You're on your own now.", "party")
		end
	elseif action == "kick" and type(a) == "number" then
		kick(m, a)
	elseif action == "promote" and type(a) == "number" then
		promote(m, a)
	elseif action == "busy" then
		-- in a quest dialogue: your search (and your party's) pauses until you're back
		local v = a == true
		if m.Busy ~= v then
			m.Busy = v
			local e = entryOf[m.UserId]
			if e then
				pushAll(e.Members)
			end
		end
	end
	return snapshot(m)
end

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------
local function safely(name: string, fn: (...any) -> (), ...: any)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Queue] " .. name .. " error:", err)
	end
end

task.spawn(function()
	local acc = 0
	while true do
		local dt = task.wait(0.15)
		safely("zones", zoneTick)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			local t = now()
			if BOTS then
				safely("bots", botsTick, t)
			end
			safely("matchmaking", matchmake)
			safely("matches", matchTick, t)
			safely("invites", inviteTick, t)
			if countsDirty then
				safely("counts", publishCounts)
			end
		end
	end
end)

publishCounts()
