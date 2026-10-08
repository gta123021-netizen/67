--[[
	ShopConfig  (ReplicatedStorage.OverkillUI.ShopConfig)
	Everything the shop sells. Read by the shop window (client) and ShopServer.

	Currency = "Coins"  -> bought with the Coins your quests pay out (server checked + saved)
	Currency = "Robux"  -> set GamePassId (passes) or ProductId (coin packs) to your real ids.
	                       While an id is 0 the card shows PriceHint and says "coming soon".
	Aura = name of a folder in ReplicatedStorage.OverkillUI.Auras (copied from the crater heroes)
]]

local ShopConfig = {}

ShopConfig.Tabs = {
	{ Id = "Auras", Title = "AURAS", Icon = 18469571139 },
	{ Id = "Passes", Title = "PASSES", Icon = 18469531323 },
	{ Id = "Coins", Title = "COINS", Icon = 5175224022 },
}

ShopConfig.Items = {
	-- AURAS (Coins) ----------------------------------------------------------
	{
		Id = "Aura_Spirit",
		Tab = "Auras",
		Name = "Spirit Cloak",
		Desc = "Orange spirit that crackles around you.",
		Rarity = "Epic",
		Currency = "Coins",
		Price = 1500,
		Aura = "Naroto",
		Preview = "Naroto",
		CardSheet = 95134112201148, -- captured frames of the real aura (shop card / collection art)
		CardFocus = { 129, 145 }, -- where the aura's visual centre sits in a sheet cell (px of 256)
		Tint = Color3.fromRGB(255, 150, 60),
	},
	{
		Id = "Aura_Radiant",
		Tab = "Auras",
		Name = "Radiant Surge",
		Desc = "White-hot ki that roars off your body.",
		Rarity = "Legendary",
		Currency = "Coins",
		Price = 3500,
		Aura = "Goki",
		Preview = "Goki",
		CardSheet = 134945720431936, -- captured frames of the real aura (shop card / collection art)
		CardFocus = { 127, 136 }, -- where the aura's visual centre sits in a sheet cell (px of 256)
		Tint = Color3.fromRGB(255, 226, 120),
	},
	{
		Id = "Aura_Infinity",
		Tab = "Auras",
		Name = "Limitless",
		Desc = "Blue infinity bending the air around you.",
		Rarity = "Mythic",
		Currency = "Coins",
		Price = 7500,
		Aura = "Gojen",
		Preview = "Gojen",
		CardSheet = 71006586143367, -- captured frames of the real aura (shop card / collection art)
		CardFocus = { 127, 134 }, -- where the aura's visual centre sits in a sheet cell (px of 256)
		Tint = Color3.fromRGB(120, 200, 255),
	},

	-- GAMEPASSES (Robux) --------------------------------------------------------
	{
		Id = "Pass_VIP",
		Tab = "Passes",
		Name = "VIP",
		Desc = "Gold VIP chat tag and +25% coins from every quest.",
		Rarity = "Legendary",
		Currency = "Robux",
		GamePassId = 0,
		PriceHint = 249,
		Icon = 18469531323,
		Perks = { CoinBoost = 0.25, ChatTag = "VIP" },
	},
	{
		Id = "Pass_2xCoins",
		Tab = "Passes",
		Name = "2x Coins",
		Desc = "Double the coins from every quest you claim.",
		Rarity = "Epic",
		Currency = "Robux",
		GamePassId = 0,
		PriceHint = 199,
		Icon = 5175224022,
		CoinArt = 3, -- drawn from the one coin art (Kit.coinArt) so every coin matches
		Badge = "x2",
		Perks = { CoinBoost = 1 },
	},
	{
		Id = "Pass_2xXP",
		Tab = "Passes",
		Name = "2x XP",
		Desc = "Double the XP from every quest you claim.",
		Rarity = "Rare",
		Currency = "Robux",
		GamePassId = 0,
		PriceHint = 149,
		Icon = 15589354311,
		Badge = "x2",
		Perks = { XpBoost = 1 },
	},

	-- COIN PACKS (Robux developer products) -------------------------------------
	{
		Id = "Coins_S",
		Tab = "Coins",
		Name = "Coin Pouch",
		Rarity = "Common",
		Currency = "Robux",
		ProductId = 0,
		PriceHint = 25,
		Amount = 500,
		Icon = 5175224022,
		CoinArt = 1, -- drawn from the one coin art (Kit.coinArt) so every coin matches
	},
	{
		Id = "Coins_M",
		Tab = "Coins",
		Name = "Coin Stack",
		Rarity = "Rare",
		Currency = "Robux",
		ProductId = 0,
		PriceHint = 69,
		Amount = 1600,
		Icon = 5175224022,
		CoinArt = 3, -- drawn from the one coin art (Kit.coinArt) so every coin matches
	},
	{
		Id = "Coins_L",
		Tab = "Coins",
		Name = "Coin Tower",
		Rarity = "Epic",
		Currency = "Robux",
		ProductId = 0,
		PriceHint = 149,
		Amount = 4000,
		Icon = 5175224022,
		CoinArt = 6, -- drawn from the one coin art (Kit.coinArt) so every coin matches
		Tag = "POPULAR",
	},
	{
		Id = "Coins_XL",
		Tab = "Coins",
		Name = "Coin Mountain",
		Rarity = "Legendary",
		Currency = "Robux",
		ProductId = 0,
		PriceHint = 399,
		Amount = 12000,
		Icon = 5175224022,
		CoinArt = 10, -- drawn from the one coin art (Kit.coinArt) so every coin matches
		Tag = "BEST VALUE",
	},
}

ShopConfig.ById = {}
for i, item in ipairs(ShopConfig.Items) do
	item.Order = i
	ShopConfig.ById[item.Id] = item
end

return ShopConfig
