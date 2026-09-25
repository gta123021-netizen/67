--[[
	ShopServer  (ServerScriptService.ShopServer)
	Checks and saves every shop purchase, applies auras to characters, handles
	game passes + coin packs. Coins live in leaderstats (made + saved by QuestServer).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")

local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local ShopConfig = require(UI:WaitForChild("ShopConfig"))
local Remotes = UI:WaitForChild("Remotes")
local ShopRequest = Remotes:WaitForChild("ShopRequest") :: RemoteFunction
local ShopEvent = Remotes:WaitForChild("ShopEvent") :: RemoteEvent
local Auras = UI:WaitForChild("Auras")
local Theme = require(UI:WaitForChild("Theme"))

local STORE_NAME = "OverkillShop_v1"
local store: DataStore? = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = res
	else
		warn("[Shop] DataStore unavailable, purchases will not save:", res)
	end
end

type Profile = { Owned: { [string]: boolean }, Equipped: string?, Settings: { [string]: any }, Loaded: boolean, CanSave: boolean, Busy: boolean }

local function cleanSettings(raw: any): { [string]: any }
	local out = table.clone(Theme.DefaultSettings)
	if type(raw) == "table" then
		for k, def in pairs(Theme.DefaultSettings) do
			local v = raw[k]
			if type(def) == "number" and type(v) == "number" and v == v then
				out[k] = if k == "Ui" then math.clamp(v, 0.8, 1.2) else math.clamp(v, 0, 1)
			elseif type(def) == "boolean" and type(v) == "boolean" then
				out[k] = v
			end
		end
	end
	-- keybinds: only known actions, only allowed keys, never two actions on one key
	local keys = table.clone(Theme.DefaultKeys)
	if type(raw) == "table" and type(raw.Keys) == "table" then
		local used = {}
		local clash = false
		for id in pairs(Theme.DefaultKeys) do
			local v = raw.Keys[id]
			if Theme.KeyAllowed(v) then
				keys[id] = v
			end
			if used[keys[id]] then
				clash = true
			end
			used[keys[id]] = true
		end
		if clash then
			keys = table.clone(Theme.DefaultKeys)
		end
	end
	out.Keys = keys
	return out
end
local profiles: { [Player]: Profile } = {}

local function key(p: Player): string
	return "u_" .. p.UserId
end

local function snapshot(p: Player)
	local prof = profiles[p]
	if not prof then
		return { Owned = {}, Equipped = nil, Settings = Theme.CopySettings(Theme.DefaultSettings) }
	end
	return { Owned = table.clone(prof.Owned), Equipped = prof.Equipped, Settings = table.clone(prof.Settings) }
end

local function save(p: Player)
	local prof = profiles[p]
	if not prof or not prof.Loaded or not prof.CanSave or not store then
		return
	end
	local owned = {}
	for id, v in pairs(prof.Owned) do
		local item = ShopConfig.ById[id]
		-- passes are re-checked with Roblox on join, only coin items are stored
		if v and item and item.Currency == "Coins" then
			owned[id] = true
		end
	end
	local data = { Owned = owned, Equipped = prof.Equipped, Settings = prof.Settings }
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(key(p), function()
			return data
		end)
	end)
	if not ok then
		warn("[Shop] save failed for", p.Name, err)
	end
end

---------------------------------------------------------------------------
-- auras (effects copied from the crater heroes)
---------------------------------------------------------------------------
local R15_MAP = {
	Head = { "Head" },
	Torso = { "UpperTorso", "LowerTorso" },
	["Left Arm"] = { "LeftUpperArm", "LeftLowerArm" },
	["Right Arm"] = { "RightUpperArm", "RightLowerArm" },
	["Left Leg"] = { "LeftUpperLeg", "LeftLowerLeg" },
	["Right Leg"] = { "RightUpperLeg", "RightLowerLeg" },
}

local function clearAura(char: Model)
	for _, d in ipairs(char:GetDescendants()) do
		if d:GetAttribute("OverkillAura") then
			d:Destroy()
		end
	end
end

local function applyAura(p: Player)
	local char = p.Character
	if not char then
		return
	end
	clearAura(char)
	local prof = profiles[p]
	local id = prof and prof.Equipped
	local item = id and ShopConfig.ById[id]
	local src = item and item.Aura and Auras:FindFirstChild(item.Aura)
	if not src or (prof and prof.Settings.AuraOn == false) then
		return
	end
	local isR6 = char:FindFirstChild("Torso") ~= nil
	for _, group in ipairs(src:GetChildren()) do
		local targets = if isR6 then { group.Name } else (R15_MAP[group.Name] or {})
		for i, targetName in ipairs(targets) do
			local part = char:FindFirstChild(targetName)
			if part and part:IsA("BasePart") then
				-- clone the whole group so beams keep their attachments. An R6 limb is two R15
				-- parts: its particles are shared across both (same total amount as on the hero),
				-- beams / lights / attachments go on the first one only (never doubled up)
				local copy = group:Clone()
				for _, fx in ipairs(copy:GetChildren()) do
					if i == 1 or fx:IsA("ParticleEmitter") then
						if fx:IsA("ParticleEmitter") and #targets > 1 then
							fx.Rate /= #targets
						end
						fx:SetAttribute("OverkillAura", true)
						fx.Parent = part
					end
				end
				copy:Destroy()
			end
		end
	end
end

local function hookCharacter(p: Player)
	p.CharacterAdded:Connect(function(char)
		char:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.2)
		applyAura(p)
	end)
	if p.Character then
		task.spawn(applyAura, p)
	end
end

---------------------------------------------------------------------------
-- passes
---------------------------------------------------------------------------
local function applyPerks(p: Player)
	local prof = profiles[p]
	if not prof then
		return
	end
	local coin, xp, tag = 0, 0, nil
	for id, v in pairs(prof.Owned) do
		local item = ShopConfig.ById[id]
		if v and item and item.Perks then
			coin += item.Perks.CoinBoost or 0
			xp += item.Perks.XpBoost or 0
			tag = item.Perks.ChatTag or tag
		end
	end
	p:SetAttribute("CoinBoost", if coin > 0 then coin else nil)
	p:SetAttribute("XpBoost", if xp > 0 then xp else nil)
	p:SetAttribute("ChatTag", tag)
end

local function checkPasses(p: Player)
	local prof = profiles[p]
	if not prof then
		return
	end
	for _, item in ipairs(ShopConfig.Items) do
		if item.GamePassId and item.GamePassId ~= 0 then
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(p.UserId, item.GamePassId)
			end)
			if ok and has then
				prof.Owned[item.Id] = true
			end
		end
	end
	applyPerks(p)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(p: Player, passId: number, purchased: boolean)
	if not purchased then
		return
	end
	local prof = profiles[p]
	if not prof then
		return
	end
	for _, item in ipairs(ShopConfig.Items) do
		if item.GamePassId == passId then
			prof.Owned[item.Id] = true
			applyPerks(p)
			ShopEvent:FireClient(p, "Granted", snapshot(p), item.Id)
		end
	end
end)

---------------------------------------------------------------------------
-- coin packs (developer products)
---------------------------------------------------------------------------
local function coinsValue(p: Player): IntValue?
	local ls = p:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild("Coins")
	return if v and v:IsA("IntValue") then v else nil
end

-- The coins go through QuestServer (ServerStorage.QuestGrantCoins), which saves them together
-- with the purchase id before we tell Roblox the purchase is done. A receipt Roblox sends again
-- (a retry, a rejoin) is recognised by its id and never paid twice; if the save fails the
-- receipt stays open and Roblox tries again later.
MarketplaceService.ProcessReceipt = function(receipt)
	local item = nil
	for _, it in ipairs(ShopConfig.Items) do
		if it.ProductId and it.ProductId ~= 0 and it.ProductId == receipt.ProductId then
			item = it
			break
		end
	end
	local p = Players:GetPlayerByUserId(receipt.PlayerId)
	local grant = ServerStorage:WaitForChild("QuestGrantCoins", 10)
	if not (item and p and grant and grant:IsA("BindableFunction")) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, saved, fresh = pcall(function()
		return (grant :: BindableFunction):Invoke(p, tostring(receipt.PurchaseId), item.Amount or 0)
	end)
	if not (ok and saved == true) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if fresh and p.Parent then
		ShopEvent:FireClient(p, "Granted", snapshot(p), item.Id)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

---------------------------------------------------------------------------
-- requests from the shop window
---------------------------------------------------------------------------
local lastRequest: { [Player]: number } = {}

ShopRequest.OnServerInvoke = function(p: Player, action: any, id: any)
	local prof = profiles[p]
	if not prof or not prof.Loaded then
		return { Ok = false, Err = "Still loading your data" }
	end
	if action == "state" then
		return { Ok = true, State = snapshot(p) }
	end
	if action == "settings" then
		if os.clock() - (lastRequest[p] or 0) < 0.2 then
			return { Ok = false, Err = "Slow down a little" }
		end
		lastRequest[p] = os.clock()
		local before = prof.Settings.AuraOn
		prof.Settings = cleanSettings(id)
		if prof.Settings.AuraOn ~= before then
			applyAura(p)
		end
		task.spawn(save, p)
		return { Ok = true, State = snapshot(p) }
	end
	if type(id) ~= "string" then
		return { Ok = false, Err = "Bad request" }
	end
	if os.clock() - (lastRequest[p] or 0) < 0.3 or prof.Busy then
		return { Ok = false, Err = "Slow down a little" }
	end
	lastRequest[p] = os.clock()
	local item = ShopConfig.ById[id]
	if not item or item.Currency ~= "Coins" then
		return { Ok = false, Err = "That item is not for coins" }
	end

	if action == "buy" then
		if prof.Owned[id] then
			return { Ok = true, State = snapshot(p) }
		end
		if not p:GetAttribute("QuestDataLoaded") then
			return { Ok = false, Err = "Your coins are still loading" }
		end
		local v = coinsValue(p)
		local price = item.Price or 0
		if not v or v.Value < price then
			return { Ok = false, Err = "Not enough coins" }
		end
		prof.Busy = true
		v.Value -= price
		prof.Owned[id] = true
		if item.Aura then
			prof.Equipped = id
			applyAura(p)
		end
		prof.Busy = false
		task.spawn(save, p)
		return { Ok = true, State = snapshot(p) }
	elseif action == "equip" then
		if not prof.Owned[id] then
			return { Ok = false, Err = "You don't own that yet" }
		end
		prof.Equipped = id
		applyAura(p)
		task.spawn(save, p)
		return { Ok = true, State = snapshot(p) }
	elseif action == "unequip" then
		if prof.Equipped == id then
			prof.Equipped = nil
			applyAura(p)
			task.spawn(save, p)
		end
		return { Ok = true, State = snapshot(p) }
	end
	return { Ok = false, Err = "Unknown action" }
end

---------------------------------------------------------------------------
-- join / leave
---------------------------------------------------------------------------
local function onJoin(p: Player)
	local prof: Profile = { Owned = {}, Equipped = nil, Settings = Theme.CopySettings(Theme.DefaultSettings), Loaded = false, CanSave = store ~= nil, Busy = false }
	profiles[p] = prof
	hookCharacter(p)
	if store then
		local loaded, got = false, nil
		for attempt = 1, 3 do
			local ok, res = pcall(function()
				return (store :: DataStore):GetAsync(key(p))
			end)
			if ok then
				loaded, got = true, res
				break
			end
			task.wait(1.5 * attempt)
		end
		if not loaded then
			prof.CanSave = false
		elseif type(got) == "table" then
			prof.Owned = if type(got.Owned) == "table" then got.Owned else {}
			prof.Equipped = if type(got.Equipped) == "string" then got.Equipped else nil
			prof.Settings = cleanSettings(got.Settings)
		end
	end
	if profiles[p] ~= prof or not p.Parent then
		return
	end
	-- auras that were renamed keep their owners (the old ids are spelled in pieces so the build's
	-- rename pass leaves them alone)
	local RENAMED = { ["Aura_" .. "Sai" .. "yan"] = "Aura_Radiant", ["Aura_" .. "Cha" .. "kra"] = "Aura_Spirit" }
	for old, new in pairs(RENAMED) do
		if prof.Owned[old] then
			prof.Owned[old] = nil
			prof.Owned[new] = true
		end
		if prof.Equipped == old then
			prof.Equipped = new
		end
	end
	-- drop anything no longer in the config
	for id in pairs(prof.Owned) do
		if not ShopConfig.ById[id] then
			prof.Owned[id] = nil
		end
	end
	if prof.Equipped and not prof.Owned[prof.Equipped] then
		prof.Equipped = nil
	end
	prof.Loaded = true
	checkPasses(p)
	applyAura(p)
	ShopEvent:FireClient(p, "State", snapshot(p))
end

Players.PlayerAdded:Connect(onJoin)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onJoin, p)
end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	profiles[p] = nil
	lastRequest[p] = nil
end)
-- shutting down: save everyone and wait until every save has finished
game:BindToClose(function()
	local left = 0
	for p in pairs(profiles) do
		left += 1
		task.spawn(function()
			save(p)
			left -= 1
		end)
	end
	local t0 = os.clock()
	while left > 0 and os.clock() - t0 < 25 do
		task.wait(0.1)
	end
end)
