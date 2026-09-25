--[[
	HeroServer  (ServerScriptService.HeroServer)
	Hero select: checks every pick, turns the player's R6 character into the full hero model and
	saves the choice. Avatars are forced to R6 (StarterPlayer), so a hero is "worn" by the real
	character: the same Humanoid, Animate script and joints, with the hero's skin colours, clothes,
	face and hair on top. Nothing is rebuilt, so movement, tools, auras and respawning all behave
	exactly as before.

	The player's own look (accessories, clothing, body colours, face, R6 packages) comes off while
	a hero is worn, including anything the avatar loader adds a moment after spawning.

	Player attributes (replicate to every client):
	  Hero        the hero id being worn ("" = your own avatar)
	  HeroLoaded  true once the saved pick has been read (the select screen waits for it)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local HeroConfig = require(UI:WaitForChild("HeroConfig"))
local Heroes = UI:WaitForChild("Heroes")
local Remotes = UI:WaitForChild("Remotes")
local HeroRequest = Remotes:WaitForChild("HeroRequest") :: RemoteFunction
local HeroEvent = Remotes:WaitForChild("HeroEvent") :: RemoteEvent

local STORE_NAME = "OverkillHeroes_v1"
local store: DataStore? = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = res
	else
		warn("[Heroes] DataStore unavailable, hero picks will not save:", res)
	end
end

local BODY = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local IS_BODY: { [string]: boolean } = { HumanoidRootPart = true }
for _, n in ipairs(BODY) do
	IS_BODY[n] = true
end
local BODY_COLOR_PROP = {
	Head = "HeadColor3",
	Torso = "TorsoColor3",
	["Left Arm"] = "LeftArmColor3",
	["Right Arm"] = "RightArmColor3",
	["Left Leg"] = "LeftLegColor3",
	["Right Leg"] = "RightLegColor3",
}

local function key(p: Player): string
	return "u" .. p.UserId
end

local function validHero(id: any): boolean
	return type(id) == "string" and HeroConfig.Heroes[id] ~= nil and Heroes:FindFirstChild(id) ~= nil
end

---------------------------------------------------------------------------
-- wearing a hero
---------------------------------------------------------------------------
-- things that belong to the player's own look
local function isOwnLook(d: Instance): boolean
	if d:GetAttribute("HeroLook") then
		return false
	end
	return d:IsA("Accessory")
		or d:IsA("Clothing")
		or d:IsA("ShirtGraphic")
		or d:IsA("BodyColors")
		or d:IsA("CharacterMesh")
end

-- decals and head meshes on the body parts (face, t-shirt decal, head shapes)
local function isOwnPartLook(d: Instance): boolean
	if d:GetAttribute("HeroLook") then
		return false
	end
	local parent = d.Parent
	if not (parent and parent:IsA("BasePart") and IS_BODY[parent.Name]) then
		return false
	end
	return d:IsA("Decal") or (parent.Name == "Head" and d:IsA("DataModelMesh"))
end

local function stripLook(char: Model)
	for _, d in ipairs(char:GetChildren()) do
		if isOwnLook(d) or d:GetAttribute("HeroLook") then
			d:Destroy()
		end
	end
	for _, n in ipairs(BODY) do
		local p = char:FindFirstChild(n)
		if p then
			for _, d in ipairs(p:GetChildren()) do
				if isOwnPartLook(d) or (d:GetAttribute("HeroLook") and not d:IsA("JointInstance")) then
					d:Destroy()
				end
			end
		end
	end
end

-- the weld in the template that holds `part`, if any
local function holderWeld(template: Model, part: BasePart): (JointInstance?)
	for _, d in ipairs(template:GetDescendants()) do
		if d:IsA("JointInstance") and d.Part1 == part and d.Part0 and d.Part0 ~= part then
			return d
		end
	end
	return nil
end

local function mark(d: Instance)
	d:SetAttribute("HeroLook", true)
end

local function wear(char: Model, heroId: string): boolean
	local template = Heroes:FindFirstChild(heroId) :: Model?
	if not template then
		return false
	end
	local torso = char:FindFirstChild("Torso")
	local head = char:FindFirstChild("Head")
	if not (torso and head and torso:IsA("BasePart") and head:IsA("BasePart")) then
		return false -- not an R6 character
	end
	stripLook(char)

	-- skin: body colours on the parts and as a BodyColors, so nothing re-tints them later
	local bc = Instance.new("BodyColors")
	for _, n in ipairs(BODY) do
		local src = template:FindFirstChild(n)
		local dst = char:FindFirstChild(n)
		if src and dst and src:IsA("BasePart") and dst:IsA("BasePart") then
			dst.Color = src.Color
			dst.Material = src.Material
			dst.Reflectance = src.Reflectance
			local prop = BODY_COLOR_PROP[n]
			if prop then
				(bc :: any)[prop] = src.Color
			end
			-- decals (face, emblems) and the head shape
			for _, d in ipairs(src:GetChildren()) do
				if d:IsA("Decal") or d:IsA("DataModelMesh") then
					local c = d:Clone()
					mark(c)
					c.Parent = dst
				end
			end
		end
	end
	mark(bc)
	bc.Parent = char

	-- clothes
	for _, d in ipairs(template:GetChildren()) do
		if d:IsA("Clothing") then
			local c = d:Clone()
			c.Name = if d:IsA("Shirt") then "Shirt" else "Pants"
			mark(c)
			c.Parent = char
		end
	end

	-- hair, collars and the rest: the template's extra parts, welded where the template welds them
	for _, d in ipairs(template:GetChildren()) do
		if d:IsA("BasePart") and not IS_BODY[d.Name] then
			local w = holderWeld(template, d)
			local hostName = if w and w.Part0 then w.Part0.Name else (if string.find(string.lower(d.Name), "hair") then "Head" else "Torso")
			local host = char:FindFirstChild(hostName)
			if host and host:IsA("BasePart") then
				local c = d:Clone()
				for _, k in ipairs(c:GetChildren()) do
					if k:IsA("JointInstance") or k:IsA("WeldConstraint") then
						k:Destroy()
					end
				end
				c.Anchored = false
				c.CanCollide = false
				c.CanQuery = false
				c.CanTouch = false
				c.Massless = true
				local c0, c1
				if w and w:IsA("JointInstance") then
					c0, c1 = w.C0, w.C1
				else
					local th = template:FindFirstChild(hostName) :: BasePart
					c0, c1 = th.CFrame:ToObjectSpace(d.CFrame), CFrame.new()
				end
				c.CFrame = host.CFrame * c0 * c1:Inverse()
				local weld = Instance.new("Weld")
				weld.Name = "HeroWeld"
				weld.Part0 = host
				weld.Part1 = c
				weld.C0 = c0
				weld.C1 = c1
				weld.Parent = c
				mark(c)
				c.Parent = char
			end
		end
	end
	char:SetAttribute("Hero", heroId)
	return true
end

-- keeps the player's own look off a hero character: the avatar loader adds accessories,
-- clothes and a face a moment after spawning
local guards: { [Model]: RBXScriptConnection } = {}
local function guard(char: Model)
	if guards[char] then
		return
	end
	local pending = false
	guards[char] = char.DescendantAdded:Connect(function(d)
		if not char:GetAttribute("Hero") then
			return
		end
		if isOwnLook(d) and d.Parent == char or isOwnPartLook(d) then
			-- body colours and packages change the parts the moment they arrive: take the item
			-- off and put the hero back on (once per burst of arrivals)
			if not pending then
				pending = true
				task.defer(function()
					pending = false
					local id = char:GetAttribute("Hero")
					if char.Parent and type(id) == "string" then
						wear(char, id)
					end
				end)
			end
		end
	end)
	char.AncestryChanged:Connect(function(_, parent)
		if not parent and guards[char] then
			guards[char]:Disconnect()
			guards[char] = nil
		end
	end)
end

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
type Profile = { Hero: string?, Loaded: boolean, LastPick: number, Dirty: boolean }
local profiles: { [Player]: Profile } = {}

local function save(p: Player)
	local prof = profiles[p]
	if not (prof and prof.Loaded and prof.Dirty and store) then
		return
	end
	prof.Dirty = false
	local data = { Hero = prof.Hero }
	local ok, err = pcall(function()
		(store :: DataStore):SetAsync(key(p), data)
	end)
	if not ok then
		prof.Dirty = true
		warn("[Heroes] save failed for", p.Name, err)
	end
end

local function applyTo(p: Player, char: Model?, flash: boolean)
	local prof = profiles[p]
	if not (prof and char) then
		return
	end
	if prof.Hero and wear(char, prof.Hero) then
		guard(char)
		if flash then
			HeroEvent:FireAllClients("Morph", char, prof.Hero)
		end
	end
end

local function onCharacter(p: Player, char: Model)
	-- wear the hero straight away (same frame the character appears: no flash of the old look),
	-- then once more when the avatar loader has finished adding things
	applyTo(p, char, false)
	task.spawn(function()
		if not p:HasAppearanceLoaded() then
			p.CharacterAppearanceLoaded:Wait()
		end
		if p.Character == char and char.Parent then
			applyTo(p, char, false)
		end
	end)
end

local function onPlayer(p: Player)
	local prof: Profile = { Hero = nil, Loaded = false, LastPick = 0, Dirty = false }
	profiles[p] = prof
	p:SetAttribute("Hero", "")
	p.CharacterAdded:Connect(function(char)
		onCharacter(p, char)
	end)
	task.spawn(function()
		local data = nil
		if store then
			local ok, res = pcall(function()
				return (store :: DataStore):GetAsync(key(p))
			end)
			if ok then
				data = res
			else
				warn("[Heroes] load failed for", p.Name, res)
			end
		end
		if profiles[p] ~= prof then
			return
		end
		-- heroes that were renamed keep the player's pick (old ids spelled in pieces so the build's
		-- rename pass leaves them alone)
		local RENAMED = { ["Go" .. "ku"] = "Goki", ["Go" .. "jo"] = "Gojen", ["Nar" .. "uto"] = "Naroto" }
		if type(data) == "table" and type(data.Hero) == "string" and RENAMED[data.Hero] then
			data.Hero = RENAMED[data.Hero]
			prof.Dirty = true
		end
		if type(data) == "table" and validHero(data.Hero) and not prof.Hero then
			prof.Hero = data.Hero
		end
		prof.Loaded = true
		p:SetAttribute("Hero", prof.Hero or "")
		p:SetAttribute("HeroLoaded", true)
		if p.Character then
			applyTo(p, p.Character, false)
		end
	end)
	if p.Character then
		onCharacter(p, p.Character)
	end
end

HeroRequest.OnServerInvoke = function(p: Player, action: any, heroId: any)
	local prof = profiles[p]
	if not prof then
		return { Ok = false, Error = "Still loading" }
	end
	if action ~= "Pick" then
		return { Ok = false, Error = "Unknown request" }
	end
	if not validHero(heroId) then
		return { Ok = false, Error = "That hero isn't available" }
	end
	local now = os.clock()
	if now - prof.LastPick < 0.8 then
		return { Ok = false, Error = "Slow down" }
	end
	prof.LastPick = now
	local changed = prof.Hero ~= heroId
	prof.Hero = heroId
	prof.Dirty = prof.Dirty or changed
	p:SetAttribute("Hero", heroId)
	local char = p.Character
	if char then
		applyTo(p, char, true)
	end
	if changed then
		task.spawn(save, p)
	end
	return { Ok = true, Hero = heroId }
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, p)
end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	profiles[p] = nil
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
