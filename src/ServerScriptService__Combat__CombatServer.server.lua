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
	  "Hit"   { Seq, V, T0, T1, AP, AL, VP, VL, VS } strike Seq met body V on this client's screen on
	                                   that frame (CombatService.ClaimHit verifies it before it lands)
	  "Whiff" { Seq }                 strike Seq's active frames ended on this screen touching nobody
	  "Move"  { K, D?, T?, H?, S? }   a traversal move this client started (Traversal): checked against
	                                   the body the server knows (BodyState) and the fighter's state, then
	                                   passed on to every other client for its effects - or refused
	                                   ("Move" { K, Denied }), and the client ends it
	The server answers the sender with CombatEvent("Ack", { Seq, Kind, Ok, Action, Slot, Chain }) so the
	client can keep (or roll back) what it started playing. Requests are rate limited and type-checked;
	damage, stun, knockback, cooldowns and timing are never taken from the client, and a claimed hit
	lands only once the server has checked it against its own record.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local Request = CombatFolder:WaitForChild("CombatRequest") :: RemoteEvent
local Event = CombatFolder:WaitForChild("CombatEvent") :: RemoteEvent
local Service = require(script.Parent:WaitForChild("CombatService"))
local BodyState = require(CombatFolder:WaitForChild("BodyState"))

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

-- the traversal moves a client may report (Config.Traversal.Needs), and Land (after any of them)
local HELD = { Stunned = true, GuardBroken = true, Ragdolled = true, Dead = true }
local MOVES = { Slide = true, SlideCancel = true, Vault = true, LedgeVault = true, Climb = true, WallRun = true, DoubleJump = true, Leap = true, Land = true }
local function onMove(player: Player, char: Model, payload: any)
	local kind = payload.K
	if type(kind) ~= "string" or not MOVES[kind] then
		return
	end
	local ent = Service.Get(char)
	local ok = ent ~= nil
	if ok and kind ~= "Land" then
		-- the body the server knows has to be able to do it, and the fighter must not be held by the fight
		-- (stunned, guard broken, down or dead). The server's state trails the client's by the round trip
		-- (a combo window it has just closed, a dash it has just ended), so only those refuse it
		local can = BodyState.Can(BodyState.Of(char), kind)
		ok = can and not HELD[ent.State]
	end
	if not ok then
		if kind ~= "Land" then
			Event:FireClient(player, "Move", { K = kind, Denied = true })
		end
		return
	end
	local d = payload.D
	local info = {
		C = char,
		K = kind,
		D = if typeof(d) == "Vector3" and d == d and d.Magnitude < 1e4 then d else nil,
		T = if type(payload.T) == "number" and payload.T == payload.T then math.clamp(payload.T, 0, 2) else nil,
		S = if type(payload.S) == "number" and payload.S == payload.S then math.clamp(payload.S, -200, 200) else nil,
		Hard = kind == "Land" and type(payload.S) == "number" and payload.S >= Config.Traversal.HardLanding,
	}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			Event:FireClient(other, "Move", info)
		end
	end
end

-- position reports, hit claims and whiffs (a few per strike) have their own, separate allowance
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
	if kind == "Pos" or kind == "Hit" or kind == "Whiff" then
		local char = player.Character
		if allowReport(player) and char then
			if kind == "Pos" then
				Service.ReportFrame(char, payload)
			elseif kind == "Hit" then
				Service.ClaimHit(char, payload)
			else
				Service.Whiff(char, payload)
			end
		end
		return
	end
	if type(kind) ~= "string" or not allow(player) then
		return
	end
	if type(payload) ~= "table" then
		payload = {}
	end
	local seq = if type(payload.Seq) == "number" and payload.Seq == payload.Seq and math.abs(payload.Seq) < 2 ^ 31 then payload.Seq else 0
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
		-- At: when the server decided (server time) - the client's timing readout in Studio compares it
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Attack", Ok = ok == true, Action = action, Slot = slot, Chain = chain, At = workspace:GetServerTimeNow() })
	elseif kind == "Dash" then
		local dir = payload.Dir
		local ok = type(dir) == "string" and DIRS[dir] == true and Service.RequestDash(char, dir)
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Dash", Ok = ok == true, Action = dir })
	elseif kind == "Block" then
		local ok = Service.RequestBlock(char, payload.On == true)
		Event:FireClient(player, "Ack", { Seq = seq, Kind = "Block", Ok = ok, Action = if payload.On == true then "On" else "Off" })
	elseif kind == "Move" then
		onMove(player, char, payload)
	end
end)

---------------------------------------------------------------------------
-- practice dummies (Studio play-tests only): they stand or guard - none of them attacks
---------------------------------------------------------------------------
if RunService:IsStudio() and Config.StudioDummies then
	local ok, err = pcall(function()
		require(script.Parent:WaitForChild("TrainingDummies")).Start(Service)
	end)
	if not ok then
		warn("[Combat] practice dummies:", err)
	end
end
