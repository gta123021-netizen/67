--[[
	Theme  (ReplicatedStorage.OverkillUI.Theme)
	One place for every colour, font, icon and number the Overkill HUD uses.
	Change a value here and the shop, profile, backpack and HUD all follow.
]]

local Theme = {}

---------------------------------------------------------------------------
-- fonts
---------------------------------------------------------------------------
Theme.Font = {
	Display = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular),
	Heavy = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.Heavy),
	Bold = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.ExtraBold),
	Body = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.Bold),
}

---------------------------------------------------------------------------
-- colour
---------------------------------------------------------------------------
local rgb = Color3.fromRGB
Theme.C = {
	Ink = rgb(9, 14, 28), -- every outline
	Night = rgb(13, 20, 37),
	Navy900 = rgb(17, 26, 47),
	Navy800 = rgb(23, 35, 62),
	Navy700 = rgb(31, 47, 81),
	Navy600 = rgb(42, 62, 104),
	Navy500 = rgb(58, 83, 134),
	Rim = rgb(96, 128, 186), -- soft inner rims
	Text = rgb(255, 255, 255),
	TextSoft = rgb(196, 210, 236),
	TextDim = rgb(128, 148, 186),

	Green = rgb(96, 224, 92),
	GreenDeep = rgb(38, 158, 64),
	Blue = rgb(76, 188, 255),
	BlueDeep = rgb(30, 116, 226),
	Pink = rgb(255, 84, 138),
	PinkDeep = rgb(206, 34, 96),
	Gold = rgb(255, 212, 64),
	GoldDeep = rgb(236, 146, 20),
	Red = rgb(255, 86, 96),
	RedDeep = rgb(196, 36, 58),
	Purple = rgb(178, 112, 255),
	PurpleDeep = rgb(112, 52, 214),
	Grey = rgb(150, 164, 190),
	GreyDeep = rgb(88, 102, 132),
	Teal = rgb(64, 220, 200),
	TealDeep = rgb(20, 146, 156),
}

-- accent per window: { light, deep }
Theme.Accent = {
	Shop = { Theme.C.Pink, Theme.C.PinkDeep },
	Stats = { Theme.C.Gold, Theme.C.GoldDeep },
	Bag = { Theme.C.Blue, Theme.C.BlueDeep },
	Settings = { Theme.C.Purple, Theme.C.PurpleDeep },
	Party = { Theme.C.Teal, Theme.C.TealDeep },
	-- combat controls (keybinds page)
	Attack = { Theme.C.Red, Theme.C.RedDeep },
	Heavy = { Theme.C.Gold, Theme.C.GoldDeep },
	Block = { Theme.C.Blue, Theme.C.BlueDeep },
	Dash = { Theme.C.Teal, Theme.C.TealDeep },
	Sprint = { Theme.C.Green, Theme.C.GreenDeep },
	ShiftLock = { Theme.C.Purple, Theme.C.PurpleDeep },
}

Theme.Rarity = {
	Common = { Name = "COMMON", Color = rgb(170, 186, 212), Deep = rgb(94, 112, 146), Order = 1 },
	Rare = { Name = "RARE", Color = rgb(80, 180, 255), Deep = rgb(28, 104, 222), Order = 2 },
	Epic = { Name = "EPIC", Color = rgb(186, 118, 255), Deep = rgb(110, 48, 214), Order = 3 },
	Legendary = { Name = "LEGENDARY", Color = rgb(255, 204, 58), Deep = rgb(232, 126, 18), Order = 4 },
	Mythic = { Name = "MYTHIC", Color = rgb(255, 88, 138), Deep = rgb(196, 24, 86), Order = 5 },
}

---------------------------------------------------------------------------
-- images
--   rbxassetid://  = image ids from your own packs
--   rbxthumb://    = decals from the Creator Store (drawn through the thumbnail service)
---------------------------------------------------------------------------
local function decal(id: number): string
	return ("rbxthumb://type=Asset&id=%d&w=420&h=420"):format(id)
end
Theme.decal = decal

Theme.Icon = {
	Shop = "rbxassetid://110882116719716", -- your basket
	Close = "rbxassetid://79829730766860", -- your red X
	Studs = "rbxassetid://6927295847", -- stud texture from the shop pack
	Shine = "rbxassetid://71904840558679", -- shine sweep from the UI animation pack
	Bag = decal(18469524834), -- backpack
	Stats = decal(137026862339578), -- trophy
	Coin = decal(5175224022),
	CoinStack = decal(81722062521925),
	CoinPile = decal(111098288810374),
	CoinTower = decal(115756310908181),
	Star = decal(15589354311), -- level / XP
	Robux = decal(18469541748),
	Crown = decal(18469531323),
	Check = decal(18469571139),
	Gear = decal(18514849575),
	Info = decal(18469600218),
	Friends = decal(18544111832),
	Medal = decal(17679796949),
	Rays = decal(76707185718665),
	Glow = decal(139372955598659),
	Clock = decal(17551409714), -- white glyphs for stat tiles
	Flame = decal(14502433634),
	Boot = decal(17365679795),
	Party = decal(18544111832), -- two friends
}

-- a player's head picture (works for any user id; bots get a letter disc instead)
function Theme.Headshot(userId: number): string
	return ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId)
end

---------------------------------------------------------------------------
-- sounds
---------------------------------------------------------------------------
Theme.Sound = {
	Hover = { Id = "rbxassetid://95635059379804", Volume = 0.18, Speed = 1.35 },
	Click = { Id = "rbxassetid://90284284772342", Volume = 0.45 },
	Open = { Id = "rbxassetid://95635059379804", Volume = 0.55, Speed = 0.9 },
	Buy = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6 },
	Error = { Id = "rbxassetid://90284284772342", Volume = 0.5, Speed = 0.62 },
	Equip = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.35, Speed = 1.4 },
}

---------------------------------------------------------------------------
-- controls
---------------------------------------------------------------------------
-- default hotkeys (players can rebind them in Settings > Keybinds; saved with their settings)
Theme.DefaultKeys = {
	Shop = "B", Stats = "P", Bag = "Backquote", Party = "G", Settings = "M",
	-- combat (StarterPlayerScripts.CombatClient reads these live)
	Block = "F", Dash = "Q", Sprint = "LeftShift", ShiftLock = "LeftControl",
}

-- the actions listed on the keybinds page, in order
-- Section groups the rows; Fixed = a control that can't be rebound (shown for reference);
-- Draw = a drawn glyph instead of an icon image; Icon = which Theme.Icon to use (default: Id)
Theme.KeyActions = {
	{ Id = "Attack", Label = "Light Attack", Sub = "Left click  ·  gamepad RT  ·  hold to chain  ·  jump + M1 to stomp", Section = "COMBAT", Fixed = "M1", Icon = "Flame" },
	{ Id = "Heavy", Label = "Heavy Attack", Sub = "Right click  ·  gamepad Y  ·  one uppercut per combo", Section = "COMBAT", Fixed = "M2", Draw = "Heavy" },
	{ Id = "Block", Label = "Block", Sub = "Hold to guard  ·  gamepad LT", Section = "COMBAT", Draw = "Shield" },
	{ Id = "Dash", Label = "Dash", Sub = "Goes where you're moving  ·  forward + M1 to strike  ·  gamepad B", Section = "COMBAT", Draw = "Dash" },
	{ Id = "Sprint", Label = "Sprint", Sub = "Hold to run  ·  gamepad L3", Section = "COMBAT", Icon = "Boot" },
	{ Id = "ShiftLock", Label = "Shift Lock", Sub = "Toggle the locked camera  ·  you face where you aim", Section = "COMBAT", Draw = "Lock" },
	{ Id = "Shop", Label = "Shop", Sub = "Open the shop", Section = "MENUS" },
	{ Id = "Stats", Label = "Profile", Sub = "Your profile and stats", Section = "MENUS" },
	{ Id = "Bag", Label = "Bag", Sub = "Your backpack", Section = "MENUS" },
	{ Id = "Party", Label = "Party", Sub = "Invite players and team up", Section = "MENUS" },
	{ Id = "Settings", Label = "Menu", Sub = "This settings menu", Section = "MENUS" },
}

-- keys a player can't take: movement, jump, chat, interact, camera zoom, hotbar numbers,
-- Roblox's own menus and the developer keys
local RESERVED = {}
for _, n in ipairs({
	"W", "A", "S", "D", "E", "I", "O", "Space", "Slash", "Tab", "Escape", "Return", "Backspace",
	"Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
	"F9", "F10", "F11", "F12", "Up", "Down", "Left", "Right",
}) do
	RESERVED[n] = true
end
local PUNCT = {
	Backquote = "~", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", BackSlash = "\\",
	Semicolon = ";", Quote = "'", Comma = ",", Period = ".",
}
local FKEYS = { F1 = true, F2 = true, F3 = true, F4 = true, F5 = true, F6 = true, F7 = true, F8 = true }
-- modifier keys that can hold an action (shift lock is Overkill's own keybind, so Shift is free)
local SPECIAL = {
	LeftShift = "SHIFT", RightShift = "R-SHIFT", LeftControl = "CTRL", RightControl = "R-CTRL",
	LeftAlt = "ALT", RightAlt = "R-ALT", CapsLock = "CAPS",
}

-- can this KeyCode name be bound to a menu?
function Theme.KeyAllowed(name: any): boolean
	if type(name) ~= "string" or RESERVED[name] then
		return false
	end
	if #name == 1 and string.match(name, "^[A-Z]$") then
		return true
	end
	return PUNCT[name] ~= nil or FKEYS[name] == true or SPECIAL[name] ~= nil
end

-- short label for a key cap: "B", "`", "F2"
function Theme.KeyText(code: any): string
	local name = if typeof(code) == "EnumItem" then code.Name else tostring(code)
	return PUNCT[name] or SPECIAL[name] or name
end

Theme.Keys = {}
-- map = { Shop = "B", ... } (KeyCode names); anything missing or invalid falls back to the default
function Theme.SetKeys(map: any)
	-- keys saved before shift lock had its own bind had Sprint on Left Ctrl (Shift was Roblox's
	-- shift lock): those move to the new layout, Sprint on Shift and Shift Lock on Left Ctrl
	if type(map) == "table" and map.ShiftLock == nil and map.Sprint == "LeftControl" then
		map = table.clone(map)
		map.Sprint = nil
	end
	for id, def in pairs(Theme.DefaultKeys) do
		local name = if type(map) == "table" and Theme.KeyAllowed(map[id]) then map[id] else def
		Theme.Keys[id] = (Enum.KeyCode :: any)[name]
	end
end
Theme.SetKeys(nil)

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------
Theme.Reference = Vector2.new(1920, 1080) -- the HUD is designed at this size and scaled to fit
Theme.MinScale = 0.5
Theme.MaxScale = 1.35
Theme.TouchBoost = 1.3 -- phones get chunkier buttons
Theme.HotbarSlots = 5 -- ability-bar style: keys 1-5, everything else lives in the bag

-- background music: add Sound ids here (they play in a loop, volume is in Settings)
Theme.Music = {}

-- default player settings (saved per player by ShopServer)
Theme.DefaultSettings = { Music = 0.5, Sfx = 0.8, Ui = 1, AuraOn = true, OthersAuras = true, Keys = Theme.DefaultKeys }

-- a settings table safe to edit (Keys is its own copy)
function Theme.CopySettings(s: any)
	local out = table.clone(s)
	out.Keys = table.clone(s.Keys or Theme.DefaultKeys)
	return out
end

---------------------------------------------------------------------------
-- levels (built on the XP value your QuestServer already saves)
---------------------------------------------------------------------------
-- XP needed to go from level n to n + 1
function Theme.XpForLevel(n: number): number
	return 150 + (n - 1) * 90
end

function Theme.LevelFromXp(xp: number): (number, number, number)
	local level, need = 1, Theme.XpForLevel(1)
	xp = math.max(0, math.floor(xp))
	while xp >= need and level < 999 do
		xp -= need
		level += 1
		need = Theme.XpForLevel(level)
	end
	return level, xp, need -- level, xp inside this level, xp needed for the next
end

-- rank titles shown on the profile card
Theme.Ranks = {
	{ Level = 1, Name = "ROOKIE", Color = rgb(170, 186, 212) },
	{ Level = 5, Name = "FIGHTER", Color = rgb(96, 224, 92) },
	{ Level = 10, Name = "ELITE", Color = rgb(80, 180, 255) },
	{ Level = 20, Name = "MASTER", Color = rgb(186, 118, 255) },
	{ Level = 35, Name = "HERO", Color = rgb(255, 204, 58) },
	{ Level = 50, Name = "LEGEND", Color = rgb(255, 88, 138) },
}
function Theme.RankFor(level: number)
	local best = Theme.Ranks[1]
	for _, r in ipairs(Theme.Ranks) do
		if level >= r.Level then
			best = r
		end
	end
	return best
end

---------------------------------------------------------------------------
-- text helpers
---------------------------------------------------------------------------
function Theme.Comma(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local neg = s:sub(1, 1) == "-"
	if neg then
		s = s:sub(2)
	end
	s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if s:sub(1, 1) == "," then
		s = s:sub(2)
	end
	return (if neg then "-" else "") .. s
end

function Theme.Short(n: number): string
	n = math.floor(n)
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e4, "K" } }
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then
			local v = n / (if u[2] == "K" then 1e3 else u[1])
			local s = ("%.1f"):format(v):gsub("%.0$", "")
			return s .. (if u[2] == "K" then "K" else u[2])
		end
	end
	return Theme.Comma(n)
end

function Theme.Duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d = seconds // 86400
	local h = (seconds % 86400) // 3600
	local m = (seconds % 3600) // 60
	if d > 0 then
		return ("%dd %dh"):format(d, h)
	elseif h > 0 then
		return ("%dh %dm"):format(h, m)
	end
	return ("%dm"):format(m)
end

return Theme
