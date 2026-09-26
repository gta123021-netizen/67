--[[
	CombatServer  (ServerScriptService.Combat.CombatServer)
	Wires players into CombatService and validates everything a client asks for.
	Clients send CombatRequest(kind, payload):
	  "Attack" { Seq, Kind, Air, Want, H } Kind = "Light" (M1) | "Heavy" (M2): the chain, the forward
	                                   dash's follow-up or the air stomp - the server decides which
	  "Dash"  { Seq, Dir }            Dir = Forward | Backward | Left | Right
	  "Block" { Seq, On }
	  "Pos"   { Seq, P, L, V, Tau, Land? } where this client has its body during strike Seq (the server
	                                   judges the strike from there, within Config.Hitbox.ReportDrift)
	The server answers the sender with CombatEvent("Ack", { Seq, Kind, Ok, Action, Slot, Chain }) so the
	client can keep (or roll back) what it started playing. Requests are rate limited and type-checked;
	damage, targets, stun and timing are never taken from the client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Request = CombatFolder:WaitForChild("CombatRequest") :: RemoteEvent
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent
local Service = require(script.Parent:WaitForChild("CombatService"))

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
local function onCharacter(player: Player, char: Model)
	local hum = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	char:WaitForChild("Torso", 10)
	if not (hum and root) or char.Parent == nil then
		return
	end
	Service.Register(char, player)
end

local function onPlayer(player: Player)
	-- shift lock is Overkill's own keybind (CombatClient); Roblox's Shift toggle would fight Sprint
	pcall(function()
		player.DevEnableMouseLock = false
	end)
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, p)
end
Players.PlayerRemoving:Connect(function(player)
	if player.Character then
		Service.Unregister(player.Character)
	end
end)

---------------------------------------------------------------------------
-- requests
---------------------------------------------------------------------------
local buckets: { [Player]: { Tokens: number, At: number } } = {}
local function allow(player: Player): boolean
	local t = os.clock()
	local b = buckets[player]
	if not b then
		b = { Tokens = Config.RequestRate, At = t }
		buckets[player] = b
	end
	b.Tokens = math.min(Config.RequestRate, b.Tokens + (t - b.At) * Config.RequestRate)
	b.At = t
	if b.Tokens < 1 then
		return false
	end
	b.Tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(p)
	buckets[p] = nil
end)

local DIRS = { Forward = true, Backward = true, Left = true, Right = true }

-- position reports (two or three per strike) have their own, separate allowance
local reportBuckets: { [Player]: { Tokens: number, At: number } } = {}
local REPORT_RATE = 30
local function allowReport(player: Player): boolean
	local t = os.clock()
	local b = reportBuckets[player]
	if not b then
		b = { Tokens = REPORT_RATE, At = t }
		reportBuckets[player] = b
	end
	b.Tokens = math.min(REPORT_RATE, b.Tokens + (t - b.At) * REPORT_RATE)
	b.At = t
	if b.Tokens < 1 then
		return false
	end
	b.Tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(p)
	reportBuckets[p] = nil
end)

Request.OnServerEvent:Connect(function(player: Player, kind: any, payload: any)
	if kind == "Pos" then
		if allowReport(player) and player.Character then
			Service.ReportFrame(player.Character, payload)
		end
		return
	end
	if type(kind) ~= "string" or not allow(player) then
		return
	end
	if type(payload) ~= "table" then
		payload = {}
	end
	local seq = if type(payload.Seq) == "number" then payload.Seq else 0
	local char = player.Character
	if not char or not Service.Get(char) then
		return
	end
	if kind == "Attack" or kind == "M1" then
		local heavy = kind == "Attack" and payload.Kind == "Heavy"
		local want = payload.Want
		if type(want) ~= "number" or want ~= want then
			want = nil
		else
			want = math.clamp(math.floor(want), 0, Config.Combo.HeavyLength)
		end
		local ok, action, slot, chain = Service.RequestAttack(char, {
			Kind = if heavy then "Heavy" else "Light",
			Air = payload.Air == true,
			Want = want,
			Seq = seq,
			H = if type(payload.H) == "number" then payload.H else nil,
		})
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Attack", Ok = ok == true, Action = action, Slot = slot, Chain = chain })
	elseif kind == "Dash" then
		local dir = payload.Dir
		local ok = type(dir) == "string" and DIRS[dir] == true and Service.RequestDash(char, dir)
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Dash", Ok = ok == true, Action = dir })
	elseif kind == "Block" then
		local ok = Service.RequestBlock(char, payload.On == true)
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Block", Ok = ok, Action = if payload.On == true then "On" else "Off" })
	end
end)

---------------------------------------------------------------------------
-- practice dummies (Studio play-tests only)
---------------------------------------------------------------------------
if RunService:IsStudio() and Config.StudioDummies then
	local ok, err = pcall(function()
		require(script.Parent:WaitForChild("TrainingDummies")).Start(Service)
	end)
	if not ok then
		warn("[Combat] practice dummies:", err)
	end
end
