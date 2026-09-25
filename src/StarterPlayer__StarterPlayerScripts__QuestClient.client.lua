--[[
	QuestClient  (StarterPlayer.StarterPlayerScripts.QuestClient)
	Cinematic hero dialogue + quest boards, drawn with the same Kit as the Overkill HUD
	(ReplicatedStorage.OverkillUI.Kit / Theme), so it matches the shop, profile, bag and settings.

	Flow: walk up to the crater -> [E] QUESTS -> Goki greets you and offers the three quest tiers.
	Only the hero who is talking animates: Goki bobs in his hover, Naroto waves, Gojen sways.
	-> quest board for that tier (hero tabs, progress, claim, claim all, reset timer, wallet)
	-> "Back to Goki" returns to the conversation, X / Backspace / B / "Maybe later" leaves.

	Performance: every idle motion (sign bob, prompt wobble, continue button, rays) is a looping
	TweenService tween, so nothing here runs a Lua loop per frame while you are just walking around.
	The camera director only runs while the quest UI is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local QS = ReplicatedStorage:WaitForChild("QuestSystem")
local Config = require(QS:WaitForChild("QuestConfig"))
local Remotes = QS:WaitForChild("Remotes")
local GetBoard = Remotes:WaitForChild("GetBoard") :: RemoteFunction
local ClaimQuest = Remotes:WaitForChild("ClaimQuest") :: RemoteFunction
local QuestUpdated = Remotes:WaitForChild("QuestUpdated") :: RemoteEvent
local ClientReport = Remotes:WaitForChild("ClientReport") :: RemoteEvent

local UI = ReplicatedStorage:WaitForChild("OverkillUI")
local Theme = require(UI:WaitForChild("Theme"))
local Kit = require(UI:WaitForChild("Kit"))
local Previews = UI:FindFirstChild("Previews")
local C = Theme.C
local new, tween = Kit.new, Kit.tween
local make = Kit.new

local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

---------------------------------------------------------------------------
-- the three heroes: colour, voice, tier
---------------------------------------------------------------------------
local rgb = Color3.fromRGB
local HERO = {
	Goki = { Color = rgb(255, 204, 52), Deep = rgb(232, 116, 16), Voice = 1.55, Tier = "Daily", Icon = Theme.Icon.Star },
	Naroto = { Color = rgb(255, 128, 44), Deep = rgb(210, 58, 18), Voice = 1.8, Tier = "Weekly", Icon = Theme.Icon.Medal },
	Gojen = { Color = rgb(96, 182, 255), Deep = rgb(58, 74, 226), Voice = 1.35, Tier = "Monthly", Icon = Theme.Icon.Crown },
}
local TIER_HERO = { Daily = "Goki", Weekly = "Naroto", Monthly = "Gojen" }
for tierName, info in pairs(Config.Tiers) do
	if info.Speaker and HERO[info.Speaker] then
		TIER_HERO[tierName] = info.Speaker
		HERO[info.Speaker].Tier = tierName
	end
end

local function heroOf(name: string?)
	return HERO[name or ""] or HERO[Config.QuestGiver] or HERO.Goki
end
local function tierHero(tierName: string): string
	return TIER_HERO[tierName] or Config.QuestGiver
end
local function tierColors(tierName: string): (Color3, Color3)
	local h = heroOf(tierHero(tierName))
	return h.Color, h.Deep
end

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
local blipSound: Sound? = nil
local function blip(speed: number)
	if not blipSound then
		blipSound = new("Sound", {
			Name = "QuestBlip",
			SoundId = "rbxasset://sounds/electronicpingshort.wav",
			Volume = 0.1,
			SoundGroup = SoundService:FindFirstChild("SFX"),
			Parent = SoundService,
		})
	end
	local s = blipSound :: Sound
	s.PlaybackSpeed = speed + math.random() * 0.2
	pcall(function()
		SoundService:PlayLocalSound(s)
	end)
end

local function hex(c: Color3): string
	return "#" .. c:ToHex()
end

-- colours the words that matter in a line of dialogue
local KEYWORDS = { "daily", "weekly", "monthly", "quests", "quest", "coins", "XP", "rewards", "reward", "today", "week", "month" }
local function highlight(text: string, color: Color3): string
	local tag = '<font color="' .. hex(color) .. '">'
	text = text:gsub("{player}", "\0P\0")
	for _, w in ipairs(KEYWORDS) do
		text = text:gsub("%f[%w]" .. w .. "%f[%W]", tag .. w .. "</font>")
		local cap = w:sub(1, 1):upper() .. w:sub(2)
		if cap ~= w then
			text = text:gsub("%f[%w]" .. cap .. "%f[%W]", tag .. cap .. "</font>")
		end
	end
	local name = player.DisplayName:gsub("[<>&]", "")
	return (text:gsub("\0P\0", function()
		return tag .. name .. "</font>"
	end))
end

local function plain(text: string): string
	return (text:gsub("{player}", function()
		return player.DisplayName
	end))
end

local function sumReady(board: any): number
	local n = 0
	if board and board.Quests then
		for _, q in ipairs(board.Quests) do
			if not q.Claimed and q.Progress >= q.Goal then
				n += 1
			end
		end
	end
	return n
end

---------------------------------------------------------------------------
-- world references
---------------------------------------------------------------------------
local function findHeroes(): Instance?
	local node: Instance = workspace
	for _, name in ipairs(Config.HeroesPath) do
		local nxt = node:FindFirstChild(name)
		if not nxt then
			return nil
		end
		node = nxt
	end
	return node
end

local heroes = findHeroes()
local speakerModels: { [string]: Model } = {}
local giver: Model? = nil

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
local state = {
	open = false,
	session = 0,
	mode = "none", -- "dialogue" | "board" | "none"
	typing = false,
	skip = false,
	options = nil :: any,
	speaker = Config.QuestGiver,
	talkedThisSession = false,
	toldReady = false,
	tier = "Daily",
	claiming = false,
}

-- every tier's board, kept fresh by QuestUpdated so badges are right everywhere
local boards: { [string]: any } = {}

---------------------------------------------------------------------------
-- arm poses shared by the statues and their portraits (R6, torso space)
---------------------------------------------------------------------------
local R_SHOULDER, L_SHOULDER = Vector3.new(1.5, 0.5, 0), Vector3.new(-1.5, 0.5, 0)

-- arm with its shoulder end at S pointing along d
local function armCF(S: Vector3, d: Vector3, front: Vector3?): CFrame
	d = d.Unit
	local Y = -d
	local f = front or Vector3.new(0, 0, -1)
	f -= Y * f:Dot(Y)
	if f.Magnitude < 1e-3 then
		f = Vector3.new(0, 0, -1)
	end
	f = f.Unit
	local Z = -f
	local X = Y:Cross(Z)
	return CFrame.fromMatrix(S + d * 1.0, X, Y, Z)
end

-- Goki's arms folded across his chest in an X (left forearm tucked just behind the right)
local function crossArm(right: boolean, lift: number?): CFrame
	local a = math.rad(30)
	local y = -0.12 + (lift or 0)
	local d = if right then Vector3.new(-math.cos(a), -math.sin(a), 0) else Vector3.new(math.cos(a), -math.sin(a), 0)
	local c = if right then Vector3.new(0.05, y, -0.95) else Vector3.new(-0.05, y, -0.78)
	local Y = -d
	local Z = Vector3.new(0, 0, 1) - Y * Y.Z
	Z = Z.Unit
	-- a slight forearm roll so the two arms catch the light differently and the X reads
	return CFrame.fromMatrix(c, Y:Cross(Z), Y, Z) * CFrame.Angles(0, if right then 0.5 else -0.5, 0)
end

-- the resting pose each statue holds (applied to the world statue and to its portraits)
local REST_ARMS: { [string]: { [string]: CFrame } } = {
	Goki = { ["Right Arm"] = crossArm(true), ["Left Arm"] = crossArm(false) },
	Gojen = {
		["Right Arm"] = armCF(R_SHOULDER, Vector3.new(-0.55, -0.82, -0.16)),
		["Left Arm"] = armCF(L_SHOULDER, Vector3.new(0.55, -0.82, -0.16)),
	},
}

local rigs: { any } = {}
local refreshRigs: () -> ()
local camera: Camera
do
---------------------------------------------------------------------------
-- R6 animation for the (anchored) statues.
-- Each limb swings around its real R6 joint (shoulders, hips, neck) in torso space and
-- blends in/out smoothly. Hair, clothing bits and aura parts follow the limb they belong to.
-- Nothing plays until you talk to them; when you leave they ease back into their pose.
---------------------------------------------------------------------------
local BODY = { "Torso", "hhead", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local NECK = Vector3.new(0, 1, 0)
local HIP = Vector3.new(0, -1, 0)
local R_HIP, L_HIP = Vector3.new(0.5, -1, 0), Vector3.new(-0.5, -1, 0)
local function piv(p: Vector3, rot: CFrame): CFrame
	return CFrame.new(p) * rot * CFrame.new(-p)
end

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

type Pose = { Torso: CFrame, Parts: { [string]: CFrame }, LegsFollow: boolean?, Look: number? }
local ANIMS: { [string]: (rig: any, t: number) -> Pose } = {}

-- Goki rests in a fixed hover. The bob and leg sway start only during his dialogue.
ANIMS.Goki = function(rig, t)
	local y = math.sin(t * 1.7) * 0.30 + math.sin(t * 0.83) * 0.06
	local sway = CFrame.Angles(math.sin(t * 1.1) * 0.035, math.sin(t * 0.55) * 0.06, math.sin(t * 0.9 + 1) * 0.03)
	return {
		Torso = CFrame.new(0, y, 0) * sway,
		LegsFollow = true,
		Look = 1,
		Parts = {
			["Right Arm"] = crossArm(true, math.sin(t * 1.7) * 0.03),
			["Left Arm"] = crossArm(false, math.sin(t * 1.7 + 0.4) * 0.03),
			["Right Leg"] = piv(R_HIP, CFrame.Angles(math.sin(t * 1.7 + 0.7) * 0.09, 0, 0.03)) * rig.Lb["Right Leg"],
			["Left Leg"] = piv(L_HIP, CFrame.Angles(math.sin(t * 1.7 + 1.3) * 0.07, 0, -0.03)) * rig.Lb["Left Leg"],
		},
	}
end

-- Naroto: drops the guard, squares up and gives a big friendly wave
ANIMS.Naroto = function(rig, t)
	local wave = math.sin(t * 8.2) * smooth(t / 0.4)
	local d = CFrame.Angles(0, 0, wave * 0.3):VectorToWorldSpace(Vector3.new(0.34, 1, -0.2))
	local bob = math.abs(math.sin(t * 4.1)) * 0.035
	return {
		Torso = piv(HIP, CFrame.Angles(-bob, math.rad(20), wave * 0.025)),
		Look = 1,
		Parts = {
			["Right Arm"] = armCF(R_SHOULDER, d),
			["Left Arm"] = armCF(L_SHOULDER, Vector3.new(-0.1, -1, -0.18 + math.sin(t * 2.1) * 0.05)),
			hhead = piv(NECK, CFrame.Angles(0, 0, -wave * 0.06)) * rig.Lb.hhead,
		},
	}
end

-- Gojen's hands stay planted on his hips. Only his upper body sways.
ANIMS.Gojen = function(rig, t)
	local side = math.sin(t * 1.12) * smooth(t / 0.5)
	return {
		Torso = piv(HIP, CFrame.Angles(0, side * 0.028, side * 0.07)),
		LegsFollow = false,
		Look = 0.35,
		Parts = {
			["Right Arm"] = armCF(R_SHOULDER, Vector3.new(-0.55, -0.82, -0.16)),
			["Left Arm"] = armCF(L_SHOULDER, Vector3.new(0.55, -0.82, -0.16)),
			hhead = piv(NECK, CFrame.Angles(0, -side * 0.025, -side * 0.045)) * rig.Lb.hhead,
		},
	}
end

type Rig = {
	Name: string,
	Parts: { [string]: BasePart },
	B: { [string]: CFrame },
	Lb: { [string]: CFrame },
	T0: CFrame,
	Extras: { { Part: BasePart, Host: string, Rel: CFrame } },
	W: number,
	T: number,
	Look: Vector2,
	LookW: number,
	Settled: boolean,
}

local function setupRig(name: string, model: Model): Rig?
	local partsByName = {}
	for _, n in ipairs(BODY) do
		local p = model:FindFirstChild(n) or (n == "hhead" and model:FindFirstChild("Head"))
		if not (p and p:IsA("BasePart")) then
			return nil
		end
		partsByName[n] = p
	end
	local extrasExpected = if name == "Goki" then { "goki hair" } elseif name == "Naroto" then { "naroto hair" } else { "gojencollar", "gojenhairdown" }
	for _, extraName in ipairs(extrasExpected) do
		if not model:FindFirstChild(extraName) then
			return nil
		end
	end
	local heroOutline = model:FindFirstChild("QuestCelOutline")
	if not heroOutline then
		heroOutline = make("Highlight", { Name = "QuestCelOutline", Adornee = model, FillColor = Color3.fromRGB(229, 239, 248), FillTransparency = 0.96, OutlineColor = Color3.fromRGB(23, 33, 49), OutlineTransparency = 0.27, DepthMode = Enum.HighlightDepthMode.Occluded, Parent = model })
	end
	-- The imported statues have anchored limbs. Disable their local joints so
	-- the engine cannot overwrite the visible per-part poses below.
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("JointInstance") then
			d.Enabled = false
		end
	end
	if name == "Goki" and not model:GetAttribute("QuestIdleLiftApplied") then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = d.CFrame + Vector3.new(0, 0.55, 0)
			end
		end
		model:SetAttribute("QuestIdleLiftApplied", true)
	end
	if name == "Goki" then
		-- Cross both arms in his resting hover; only the bob and subtle pose motion
		-- start when his dialogue is active.
		partsByName["Right Arm"].CFrame = partsByName.Torso.CFrame * REST_ARMS.Goki["Right Arm"]
		partsByName["Left Arm"].CFrame = partsByName.Torso.CFrame * REST_ARMS.Goki["Left Arm"]
	elseif name == "Gojen" then
		partsByName["Right Arm"].CFrame = partsByName.Torso.CFrame * REST_ARMS.Gojen["Right Arm"]
		partsByName["Left Arm"].CFrame = partsByName.Torso.CFrame * REST_ARMS.Gojen["Left Arm"]
	end
	local rig: Rig = {
		Name = name,
		Parts = partsByName,
		B = {},
		Lb = {},
		T0 = partsByName.Torso.CFrame,
		Extras = {},
		W = 0,
		T = 0,
		Look = Vector2.zero,
		LookW = 0,
		Settled = true,
	}
	local isBody = {}
	for n, p in pairs(partsByName) do
		rig.B[n] = p.CFrame
		rig.Lb[n] = rig.T0:ToObjectSpace(p.CFrame)
		isBody[p] = n
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and not isBody[d] and d.Name ~= "HumanoidRootPart" then
			local host = nil
			local a = d.Parent
			while a and a ~= model do
				if isBody[a] then
					host = isBody[a]
					break
				end
				a = a.Parent
			end
			if not host then
				local lower = d.Name:lower()
				host = if lower:find("hair") or lower:find("blind") or lower:find("hat") then "hhead" else "Torso"
			end
			table.insert(rig.Extras, { Part = d, Host = host, Rel = rig.B[host]:ToObjectSpace(d.CFrame) })
		end
	end
	return rig
end

function refreshRigs()
	local currentHeroes = findHeroes()
	if not currentHeroes then
		return
	end
	heroes = currentHeroes
	for name in pairs(Config.Speakers) do
		local model = heroes:FindFirstChild(name)
		if model and model:IsA("Model") then
			speakerModels[name] = model
			if name == Config.QuestGiver then
				giver = model
			end
			local already = false
			for _, rig in ipairs(rigs) do
				if rig.Name == name and rig.Parts.Torso.Parent == model then
					already = true
					break
				end
			end
			if not already then
				local rig = setupRig(name, model)
				if rig then
					for i = #rigs, 1, -1 do
						if rigs[i].Name == name then
							table.remove(rigs, i)
						end
					end
					table.insert(rigs, rig)
				end
			end
		end
	end
end
refreshRigs()
-- (a set lookup: this fires for every part added anywhere in the workspace)
local RIG_NAMES: { [string]: boolean } = { CraterHeroes = true, ["goki hair"] = true, ["naroto hair"] = true, gojencollar = true, gojenhairdown = true }
for _, n in ipairs(BODY) do
	RIG_NAMES[n] = true
end
for n in pairs(Config.Speakers) do
	RIG_NAMES[n] = true
end
local rigRefreshQueued = false
workspace.DescendantAdded:Connect(function(inst)
	if RIG_NAMES[inst.Name] and not rigRefreshQueued then
		rigRefreshQueued = true
		task.defer(function()
			rigRefreshQueued = false
			refreshRigs()
		end)
	end
end)
task.spawn(function()
	for _ = 1, 60 do
		if #rigs == 3 then
			return
		end
		refreshRigs()
		task.wait(0.5)
	end
	warn("[Quests] NPC models did not finish streaming; animation rigs found:", #rigs)
end)

camera = workspace.CurrentCamera

local function animTarget(rig: Rig): number
	if not state.open or state.mode ~= "dialogue" then
		return 0
	end
	return if state.speaker == rig.Name then 1 else 0
end

RunService:BindToRenderStep("QuestNpcPose", Enum.RenderPriority.Last.Value, function(dt)
	for _, rig in ipairs(rigs) do
		local target = animTarget(rig)
		if target == 0 then
			if not rig.Settled then
				rig.Settled = true
				rig.W = 0
				rig.T = 0
				rig.LookW = 0
				for n, p in pairs(rig.Parts) do
					p.CFrame = rig.B[n]
				end
				for _, e in ipairs(rig.Extras) do
					e.Part.CFrame = rig.B[e.Host] * e.Rel
				end
			end
			continue
		end
		rig.W += (target - rig.W) * (1 - math.exp(-dt * 3.2))
		rig.Settled = false
		rig.T += dt
		local w = smooth(rig.W)
		local pose = ANIMS[rig.Name](rig, rig.T)
		local T = rig.T0 * CFrame.new():Lerp(pose.Torso, w)
		local world: { [string]: CFrame } = { Torso = T }
		for _, n in ipairs(BODY) do
			if n ~= "Torso" then
				local L = rig.Lb[n]
				local tgt = pose.Parts[n]
				if tgt then
					L = L:Lerp(tgt, w)
				end
				local isLeg = n == "Left Leg" or n == "Right Leg"
				world[n] = (if isLeg and not pose.LegsFollow then rig.T0 else T) * L
			end
		end
		-- head turns toward the camera while that hero is talking
		local lookTarget = if state.open and state.mode == "dialogue" and state.speaker == rig.Name then (pose.Look or 1) else 0
		rig.LookW += (lookTarget - rig.LookW) * (1 - math.exp(-dt * 3))
		if rig.LookW > 0.01 then
			local head = world.hhead
			local lp = head:PointToObjectSpace(camera.CFrame.Position)
			local yaw = math.clamp(math.atan2(-lp.X, -lp.Z), -0.7, 0.7)
			local pitch = math.clamp(math.atan2(lp.Y, math.sqrt(lp.X * lp.X + lp.Z * lp.Z)), -0.35, 0.3)
			rig.Look = rig.Look:Lerp(Vector2.new(yaw, pitch), 1 - math.exp(-dt * 6))
			local k = rig.LookW
			world.hhead = head * CFrame.new(0, -0.5, 0) * CFrame.Angles(rig.Look.Y * k, rig.Look.X * k, 0) * CFrame.new(0, 0.5, 0)
		end
		for n, p in pairs(rig.Parts) do
			p.CFrame = world[n]
		end
		for _, e in ipairs(rig.Extras) do
			e.Part.CFrame = world[e.Host] * e.Rel
		end
	end
end)
end
local camStart: () -> (), camRestore: () -> (), cutTo: (string) -> (), camWide: () -> ()
do
---------------------------------------------------------------------------
-- camera director
---------------------------------------------------------------------------
local cam = {
	active = false,
	shot = "speaker", -- "speaker" | "wide" | "restore"
	speaker = Config.QuestGiver,
	savedCF = CFrame.new(),
	savedFov = 70,
	fov = 50,
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- uses the statue's resting pose so the shot doesn't bob with the animation
local function bodyFocus(name: string): (Vector3, Vector3, Vector3)
	if not speakerModels[name] then
		refreshRigs()
	end
	local model = speakerModels[name] or giver
	local rigT0: CFrame? = nil
	for _, r in ipairs(rigs) do
		if r.Name == name then
			rigT0 = r.T0
		end
	end
	local root = model and model:FindFirstChild("HumanoidRootPart")
	local rootCF = (root and (root :: BasePart).CFrame) or (model and model:GetPivot()) or CFrame.new()
	local fwd = Vector3.new(rootCF.LookVector.X, 0, rootCF.LookVector.Z)
	if fwd.Magnitude < 0.01 then
		fwd = Vector3.new(0, 0, -1)
	end
	fwd = fwd.Unit
	local right = fwd:Cross(Vector3.yAxis).Unit
	local torsoPos = if rigT0 then rigT0.Position else rootCF.Position
	return torsoPos + Vector3.new(0, 0.4, 0), fwd, right
end

local function blocked(from: Vector3, to: Vector3): RaycastResult?
	local exclude = { player.Character }
	if heroes then
		table.insert(exclude, heroes)
	end
	local qw = workspace:FindFirstChild("QuestWorld")
	if qw then
		table.insert(exclude, qw)
	end
	rayParams.FilterDescendantsInstances = exclude
	return workspace:Raycast(from, to - from, rayParams)
end

-- lift the camera over whatever is in the way (crater rim, trees) before pulling it in
local function clearPos(focus: Vector3, pos: Vector3): Vector3
	for lift = 0, 6 do
		local p = pos + Vector3.new(0, lift, 0)
		if not blocked(focus, p) then
			return p
		end
	end
	local hit = blocked(focus, pos)
	if hit then
		return hit.Position - (pos - focus).Unit * 0.6
	end
	return pos
end

-- wide enough to see the whole hero; they stand on the right, the dialogue has the left
local shotCache: { [string]: CFrame } = {}
local function speakerShot(name: string): CFrame
	local cached = shotCache[name]
	if cached then
		return cached
	end
	local focus, fwd, right = bodyFocus(name)
	local pos = clearPos(focus, focus + fwd * 9.5 + right * 2.2 + Vector3.new(0, 2.4, 0))
	local aspect = camera.ViewportSize.X / math.max(1, camera.ViewportSize.Y)
	local offset = if aspect < 1 then 0.8 else 2.8
	local cf = CFrame.lookAt(pos, focus + right * offset + Vector3.new(0, 0.1, 0))
	shotCache[name] = cf
	return cf
end

local function wideShot(): CFrame
	local cached = shotCache.__wide
	if cached then
		return cached
	end
	local focus, fwd, right = bodyFocus(Config.QuestGiver)
	local center = focus - fwd * 2.2
	local pos = clearPos(center, center + fwd * 17 + Vector3.new(0, 5, 0) + right * 1.5)
	local cf = CFrame.lookAt(pos, center + Vector3.new(0, 0.5, 0))
	shotCache.__wide = cf
	return cf
end

local camT0 = os.clock()
local function camStep(dt: number)
	if not cam.active then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	local target: CFrame
	local fov = cam.fov
	if cam.shot == "restore" then
		target = cam.savedCF
		fov = cam.savedFov
	elseif cam.shot == "wide" then
		target = wideShot()
		fov = 58
	else
		target = speakerShot(cam.speaker)
	end
	if cam.shot ~= "restore" then
		local t = os.clock() - camT0
		-- slow handheld drift + push-in so the shot never feels frozen
		target = target * CFrame.Angles(math.noise(t * 0.25, 1.3) * 0.01, math.noise(2.7, t * 0.25) * 0.012, 0) * CFrame.new(0, 0, -math.min(t, 10) * 0.03)
	end
	local a = 1 - math.exp(-dt * (if cam.shot == "restore" then 7 else 4))
	camera.CFrame = camera.CFrame:Lerp(target, a)
	camera.FieldOfView += (fov - camera.FieldOfView) * a
end

function camStart()
	cam.savedCF = camera.CFrame
	cam.savedFov = camera.FieldOfView
	cam.active = true
	cam.shot = "speaker"
	camT0 = os.clock()
	shotCache = {}
	RunService:BindToRenderStep("QuestCinematicCamera", Enum.RenderPriority.Camera.Value + 1, camStep)
end

function camRestore()
	cam.shot = "restore"
	local t0 = os.clock()
	while os.clock() - t0 < 0.9 do
		if (camera.CFrame.Position - cam.savedCF.Position).Magnitude < 0.05 then
			break
		end
		task.wait()
	end
	cam.active = false
	RunService:UnbindFromRenderStep("QuestCinematicCamera")
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = cam.savedFov
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		camera.CameraSubject = hum
	end
end

function cutTo(name: string)
	cam.speaker = name
	cam.shot = "speaker"
	camT0 = os.clock()
end

function camWide()
	cam.shot = "wide"
	camT0 = os.clock()
end
end
local setControls: (boolean) -> (), lockCharacterToGoki: () -> (), unlockCharacter: () -> ()
local blur: any
do
---------------------------------------------------------------------------
-- controls / core gui / chat
---------------------------------------------------------------------------
local controls = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 8))
	end)
	if ok and mod then
		controls = mod:GetControls()
	end
end)

local savedChat = { window = true, input = true }
local function setChat(enabled: boolean)
	pcall(function()
		local w = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		local i = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if not enabled then
			savedChat.window = if w then w.Enabled else true
			savedChat.input = if i then i.Enabled else true
		end
		if w then
			w.Enabled = if enabled then savedChat.window else false
		end
		if i then
			i.Enabled = if enabled then savedChat.input else false
		end
	end)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, enabled)
	end)
end

function setControls(enabled: boolean)
	if controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
	player:SetAttribute("QuestUIOpen", not enabled) -- the Overkill HUD steps aside while this is true
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
	end)
	setChat(enabled)
end

local movementLock: any = nil
function lockCharacterToGoki()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart") and hum) then
		return
	end
	movementLock = {
		Root = root,
		Humanoid = hum,
		Visuals = {},
		Anchored = root.Anchored,
		WalkSpeed = hum.WalkSpeed,
		JumpPower = hum.JumpPower,
		JumpHeight = hum.JumpHeight,
		AutoRotate = hum.AutoRotate,
	}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(movementLock.Visuals, { Part = d, Modifier = d.LocalTransparencyModifier })
			d.LocalTransparencyModifier = 1
		end
	end
	local gokiTorso = giver and (giver:FindFirstChild("Torso") or giver:FindFirstChild("HumanoidRootPart"))
	if gokiTorso and gokiTorso:IsA("BasePart") then
		local facing = Vector3.new(gokiTorso.Position.X, root.Position.Y, gokiTorso.Position.Z)
		if (facing - root.Position).Magnitude > 0.2 then
			root.CFrame = CFrame.lookAt(root.Position, facing)
		end
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.Anchored = true
	hum.AutoRotate = false
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.JumpHeight = 0
end

function unlockCharacter()
	local saved = movementLock
	movementLock = nil
	if not saved then
		return
	end
	if saved.Root.Parent then
		saved.Root.Anchored = saved.Anchored
	end
	if saved.Humanoid.Parent then
		saved.Humanoid.AutoRotate = saved.AutoRotate
		saved.Humanoid.WalkSpeed = saved.WalkSpeed
		saved.Humanoid.JumpPower = saved.JumpPower
		saved.Humanoid.JumpHeight = saved.JumpHeight
	end
	for _, v in ipairs(saved.Visuals) do
		if v.Part.Parent then
			v.Part.LocalTransparencyModifier = v.Modifier
		end
	end
end

blur = Lighting:FindFirstChild("QuestBlur") or make("BlurEffect", { Name = "QuestBlur", Size = 0, Parent = Lighting })
end

---------------------------------------------------------------------------
-- GUI root: same reference-size scaling as the HUD (1920x1080, UIScale, user size)
---------------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "QuestUI",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 40,
	Parent = playerGui,
})

-- cinematic layer (full screen, unscaled): vignette, letterbox, click-to-continue
local cine = new("Frame", { Name = "Cinematic", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 1, Parent = gui })
local catcher = new("TextButton", {
	Name = "TapToContinue",
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Selectable = false,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 1,
	Parent = cine,
})
local vignettes = {}
for _, spec in ipairs({ { 0, 0, 0.55, 0.28 }, { 180, 0.7, 0.3, 0.5 } }) do
	local v = new("Frame", {
		BackgroundColor3 = C.Night,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(spec[2], 0),
		Size = UDim2.fromScale(spec[3], 1),
		ZIndex = 2,
		Parent = cine,
	})
	new("UIGradient", { Rotation = spec[1], Transparency = NumberSequence.new(spec[4], 1), Parent = v })
	table.insert(vignettes, v)
end
local barTop = new("Frame", { Name = "BarTop", BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Size = UDim2.fromScale(1, 0), ZIndex = 3, Parent = cine })
local barBot = new("Frame", { Name = "BarBottom", BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), ZIndex = 3, Parent = cine })
local LETTERBOX = 0.045

local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = gui })
local rootScale = new("UIScale", { Name = "Fit", Parent = root })
local flash = new("Frame", { Name = "Flash", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = gui })

local dim = new("Frame", { Name = "Dim", BackgroundColor3 = C.Night, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 8, Parent = root })
local fxLayer = new("Frame", { Name = "FX", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 60, Parent = root })

local ui = { Scale = 1, W = 1920, H = 1080 }

-- a gui's centre in root space (for bursts, floats, flying coins)
local function toRoot(g: GuiObject): UDim2
	local p = g.AbsolutePosition + g.AbsoluteSize / 2 - root.AbsolutePosition
	return UDim2.fromOffset(p.X / ui.Scale, p.Y / ui.Scale)
end

local function burst(at: UDim2, color: Color3, count: number?)
	local n = count or 12
	for i = 1, n do
		local star = Kit.image({
			Image = Theme.Icon.Star,
			ImageColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at,
			Size = UDim2.fromOffset(30, 30),
			ZIndex = 61,
			Parent = fxLayer,
		})
		local ang = (i / n) * math.pi * 2 + math.random() * 0.5
		local dist = 70 + math.random() * 70
		tween(star, 0.75, {
			Position = at + UDim2.fromOffset(math.cos(ang) * dist, math.sin(ang) * dist),
			Rotation = math.random(-200, 200),
			Size = UDim2.fromOffset(10, 10),
			ImageTransparency = 1,
		}, Enum.EasingStyle.Quint)
		task.delay(0.8, function()
			star:Destroy()
		end)
	end
end

local function float(at: UDim2, text: string, color: Color3, delay: number?)
	task.delay(delay or 0, function()
		local l = Kit.text({
			Text = text,
			TextSize = 38,
			TextColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at,
			Size = UDim2.fromOffset(320, 46),
			ZIndex = 62,
			Stroke = 4.5,
			Parent = fxLayer,
		})
		local sc = Kit.fx(l)
		sc.Scale = 0.4
		tween(sc, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(l, 1.2, { Position = at + UDim2.fromOffset(0, -70) }, Enum.EasingStyle.Quint)
		task.delay(0.8, function()
			tween(l, 0.4, { TextTransparency = 1 })
			local st = l:FindFirstChildOfClass("UIStroke")
			if st then
				tween(st, 0.4, { Transparency = 1 })
			end
			task.wait(0.45)
			l:Destroy()
		end)
	end)
end

-- coins arcing from one root-space point to another
local function flyCoins(a: UDim2, b: UDim2, n: number?, onLand: (() -> ())?)
	local count = n or 10
	for i = 1, count do
		local c = Kit.image({ Image = Theme.Icon.Coin, AnchorPoint = Vector2.new(0.5, 0.5), Position = a, Size = UDim2.fromOffset(44, 44), ZIndex = 61, Parent = fxLayer })
		local mid = UDim2.fromOffset((a.X.Offset + b.X.Offset) / 2 + math.random(-120, 120), math.min(a.Y.Offset, b.Y.Offset) - math.random(60, 160))
		task.delay(i * 0.04, function()
			tween(c, 0.3, { Position = mid, Rotation = math.random(-120, 120) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out).Completed:Wait()
			tween(c, 0.3, { Position = b, Size = UDim2.fromOffset(24, 24) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
			c:Destroy()
			if i == count and onLand then
				onLand()
			end
		end)
	end
end

-- white keycap with ink text ("E", "1", "SPACE")
local function keycap(parent: Instance, text: string, w: number, h: number, size: number, z: number): Frame
	local k = new("Frame", {
		Name = "Key",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(w, h),
		ZIndex = z,
		Parent = parent,
	})
	Kit.corner(k, math.floor(math.min(w, h) * 0.3))
	Kit.stroke(k, 3, C.Ink, 0, true)
	-- flat, like the key chips on the dock (no silver bottom lip)
	Kit.gradient(k, Color3.new(1, 1, 1), rgb(222, 230, 244), 90)
	Kit.text({ Name = "Text", Text = text, TextSize = size, TextColor3 = C.Ink, ZIndex = z + 1, Stroke = false, Parent = k })
	return k
end

-- red count bubble (tabs, options, prompt)
local function badge(parent: Instance, z: number, pos: UDim2?): any
	local b = new("Frame", {
		Name = "Badge",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = pos or UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(34, 34),
		AutomaticSize = Enum.AutomaticSize.None,
		Visible = false,
		ZIndex = z,
		Parent = parent,
	})
	Kit.pill(b)
	Kit.stroke(b, 3, C.Ink, 0, true)
	Kit.gradient(b, C.Red, C.RedDeep, 90)
	local t = Kit.text({ Text = "0", TextSize = 20, ZIndex = z + 1, Stroke = 2.4, Parent = b })
	local sc = Kit.fx(b)
	local api = { Frame = b, Count = 0 }
	function api.Set(n: number)
		n = math.max(0, math.floor(n))
		if n == api.Count and b.Visible == (n > 0) then
			return
		end
		local grew = n > api.Count
		api.Count = n
		t.Text = if n > 9 then "9+" else tostring(n)
		b.Size = UDim2.fromOffset(if n > 9 then 44 else 34, 34)
		if n > 0 then
			if not b.Visible or grew then
				b.Visible = true
				sc.Scale = 0.2
				tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		else
			b.Visible = false
		end
	end
	return api
end

---------------------------------------------------------------------------
-- hero portraits: a posed statue from OverkillUI.Previews in a ViewportFrame.
-- Static camera, so the viewport only redraws when something about it changes.
---------------------------------------------------------------------------
-- `corner` rounds the viewport itself: a UICorner on a ViewportFrame clips the 3D render too
local function bust(parent: GuiObject, heroName: string, framing: string, z: number, corner: any?): ViewportFrame?
	local src = Previews and Previews:FindFirstChild(heroName)
	if not src then
		return nil
	end
	local vp = new("ViewportFrame", {
		Name = heroName,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Ambient = rgb(142, 142, 158),
		LightColor = rgb(255, 244, 228),
		LightDirection = Vector3.new(-0.45, -0.8, -1),
		ZIndex = z,
		Parent = parent,
	})
	if corner then
		Kit.corner(vp, corner)
	end
	local model = src:Clone()
	model.Parent = vp
	local head = model:FindFirstChild("hhead") or model:FindFirstChild("Head")
	local torso = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	local rest = REST_ARMS[heroName]
	if rest and torso and torso:IsA("BasePart") then
		for armName, rel in pairs(rest) do
			local arm = model:FindFirstChild(armName)
			if arm and arm:IsA("BasePart") then
				arm.CFrame = torso.CFrame * rel
			end
		end
	end
	local hrp = model:FindFirstChild("HumanoidRootPart")
	local ref = (hrp and hrp:IsA("BasePart") and hrp) or (torso and torso:IsA("BasePart") and torso)
	if not (head and head:IsA("BasePart") and ref) then
		local cf, size = model:GetBoundingBox()
		local cam = new("Camera", { FieldOfView = 30, Parent = vp })
		cam.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * size.Magnitude * 1.4, cf.Position)
		vp.CurrentCamera = cam
		return vp
	end
	local look = (ref :: BasePart).CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local k = if torso and torso:IsA("BasePart") then torso.Size.Y / 2 else 1
	local fov = 30
	local span, drop, turn = 4.3 * k, 0.68 * k, -8
	if framing == "head" then
		span, drop, turn = 2.95 * k, -0.12 * k, -8
	end
	local target = (head :: BasePart).Position - Vector3.new(0, drop, 0)
	local dist = (span * 0.5) / math.tan(math.rad(fov / 2))
	local dir = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(turn)) * look
	local cam = new("Camera", { FieldOfView = fov, Parent = vp })
	cam.CFrame = CFrame.lookAt(target + dir * dist + Vector3.new(0, 0.3 * k, 0), target)
	vp.CurrentCamera = cam
	-- key light from the upper right of the camera: gives the face and folded arms some shape
	local f = cam.CFrame
	vp.LightDirection = (f.LookVector + f.RightVector * 0.9 - Vector3.yAxis * 0.7).Unit
	return vp
end

---------------------------------------------------------------------------
-- dialogue panel (Kit window look: navy body, stripes, hero-coloured header band, bevel rim)
---------------------------------------------------------------------------
local SPEECH = 30 -- speech text size
local TOP = 104 -- where the words start
local OPT_H, OPT_GAP = 72, 12
local dlgW = 820
local dlgHome = UDim2.new(0, 96, 1, -110)
local GOLD, GOLD_D = HERO.Goki.Color, HERO.Goki.Deep
local dlg: Frame, speech: TextLabel, optionsFrame: Frame, dClose: TextButton
local advanceEvent: BindableEvent, choiceEvent: BindableEvent
local showNext: (boolean) -> (), layoutDialogue: (number, number, boolean?) -> ()
local applySpeaker: (string) -> (), setSpeaker: (string, boolean?) -> ()
local showDialogue: () -> (), hideDialogue: () -> ()

do
local R = 30
dlg = new("Frame", {
	Name = "Dialogue",
	AnchorPoint = Vector2.new(0, 1),
	Position = dlgHome,
	Size = UDim2.fromOffset(dlgW, 250),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 10,
	Parent = root,
})
local dlgScale = Kit.fx(dlg)

local dShadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.45, Position = UDim2.fromOffset(0, 12), Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = dlg })
Kit.corner(dShadow, R)
local dBody = new("Frame", { Name = "Body", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = dlg })
Kit.corner(dBody, R)
Kit.stroke(dBody, 9, C.Ink, 0, true) -- the skin covers the inner half
new("UIGradient", {
	Rotation = 90,
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.Navy700),
		ColorSequenceKeypoint.new(0.45, C.Navy800),
		ColorSequenceKeypoint.new(1, C.Navy900),
	}),
	Parent = dBody,
})
-- static skin: cached by the CanvasGroup, redrawn only when the panel resizes or recolours
local dSkin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = dBody })
Kit.corner(dSkin, R)
Kit.stripes(dSkin, C.Rim, 0.955, 2)
local dBand = new("Frame", { Name = "HeaderBand", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.new(1, 0, 0, 124), ZIndex = 2, Parent = dSkin })
local dBandGrad = Kit.gradient(dBand, GOLD, GOLD_D, 90, 0.7, 1)
local dBandStripes = new("CanvasGroup", { Name = "BandStripes", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 124), ZIndex = 2, Parent = dSkin })
local dBandStripeHolder = Kit.stripes(dBandStripes, GOLD, 0.8, 2, 14, 26)
new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.25, 1), Parent = dBandStripes })
local dVignette = new("Frame", { Name = "Vignette", BackgroundColor3 = C.Night, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.5, 0), ZIndex = 2, Parent = dSkin })
Kit.gradient(dVignette, C.Night, C.Night, 90, 1, 0.3)
local dSparkles = Kit.sparkles(dBody, GOLD, 5, 3, function()
	return dlg.Visible
end)

-- portrait card, overlapping the top-left corner
local PORT = 158
local portrait = new("Frame", {
	Name = "Portrait",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(94, 4),
	Size = UDim2.fromOffset(PORT, PORT),
	BackgroundTransparency = 1,
	ZIndex = 20,
	Parent = dlg,
})
local portraitScale = Kit.fx(portrait)
local halo = Kit.rays(portrait, GOLD, 320, 0.5, 20)
local pCard = new("Frame", { Name = "Card", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 21, Parent = portrait })
Kit.corner(pCard, 34)
Kit.stroke(pCard, 5, C.Ink, 0, true)
local pCardGrad = Kit.gradient(pCard, Kit.lighten(GOLD, 0.15), GOLD_D, 90)
Kit.bevel(pCard, 31, 3, 21)
local pInner = new("Frame", { Name = "Inner", BackgroundColor3 = Color3.new(1, 1, 1), Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 1, -20), ZIndex = 22, Parent = pCard })
Kit.corner(pInner, 25)
Kit.stroke(pInner, 3, C.Ink, 0.15, true)
local pInnerGrad = Kit.gradient(pInner, Kit.lighten(GOLD, 0.3), Kit.darken(GOLD_D, 0.4), 90)
Kit.image({ Name = "Glow", Image = Theme.Icon.Glow, ImageColor3 = Color3.new(1, 1, 1), ImageTransparency = 0.45, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42), Size = UDim2.fromScale(1.1, 1.1), ZIndex = 22, Parent = pInner })
local pView = new("Frame", { Name = "Views", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 1, -20), ZIndex = 23, Parent = pCard })
local portraitViews: { [string]: GuiObject } = {}
for heroName, h in pairs(HERO) do
	local v: GuiObject? = bust(pView, heroName, "bust", 23, 25)
	if not v then
		v = Kit.image({ Name = heroName, Image = h.Icon, Size = UDim2.fromScale(0.8, 0.8), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 23, Parent = pView })
	end
	(v :: GuiObject).Visible = false
	portraitViews[heroName] = v :: GuiObject
end

-- name plate on the top edge (the window title plate, in the hero's colours)
local namePlate = new("Frame", {
	Name = "NamePlate",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.fromOffset(186, 0),
	Size = UDim2.fromOffset(200, 70),
	BackgroundColor3 = Color3.new(1, 1, 1),
	ZIndex = 24,
	Parent = dlg,
})
Kit.corner(namePlate, 22)
Kit.stroke(namePlate, 5, C.Ink, 0, true)
local namePlateGrad = Kit.gradient(namePlate, Kit.lighten(GOLD, 0.15), GOLD_D, 90)
local namePlateScale = Kit.fx(namePlate)
local nameInner = new("Frame", { Name = "Inner", BackgroundColor3 = Color3.new(1, 1, 1), Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), ZIndex = 24, Parent = namePlate })
Kit.corner(nameInner, 17)
Kit.gradient(nameInner, C.Navy800, C.Night, 90)
local nameSheen = Kit.addShine(nameInner, 17)
local nameLabel = Kit.text({ Name = "Name", Text = "GOKI", TextSize = 42, Position = UDim2.fromOffset(0, -1), ZIndex = 26, Stroke = 4.5, Parent = namePlate })
local roleLabel = Kit.text({
	Name = "Role",
	Text = "",
	TextSize = 19,
	FontFace = Theme.Font.Heavy,
	TextColor3 = Kit.lighten(GOLD, 0.3),
	TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(194, 44),
	Size = UDim2.new(1, -270, 0, 26),
	ZIndex = 14,
	Stroke = 2.8,
	Parent = dlg,
})

-- the shared close tile (same as every window), on the top-right corner
dClose = Kit.closeButton({
	Name = "Leave",
	Parent = dlg,
	Position = UDim2.new(1, -14, 0, 14),
	Size = 62,
	ZIndex = 30,
}).Button

speech = Kit.text({
	Name = "Speech",
	Text = "",
	RichText = true,
	TextWrapped = true,
	TextSize = SPEECH,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Position = UDim2.fromOffset(40, TOP),
	Size = UDim2.new(1, -80, 0, 40),
	ZIndex = 14,
	Stroke = 3.2,
	Parent = dlg,
})

optionsFrame = new("Frame", { Name = "Options", BackgroundTransparency = 1, Position = UDim2.fromOffset(28, TOP + 60), Size = UDim2.new(1, -56, 0, 0), ZIndex = 15, Parent = dlg })
Kit.list(optionsFrame, Enum.FillDirection.Vertical, OPT_GAP)

-- NEXT button (click / tap / Space / E / Enter / A)
advanceEvent = Instance.new("BindableEvent")
choiceEvent = Instance.new("BindableEvent")
local keyName = if isTouch then nil elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then "A" else "SPACE"
local nextBtn = Kit.button({
	Name = "Next",
	Parent = dlg,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -26, 1, -22),
	Size = UDim2.fromOffset(if keyName == "SPACE" then 214 elseif keyName then 172 else 150, 60),
	Radius = 19,
	Depth = 6,
	Stroke = 3.5,
	Color = GOLD,
	Deep = GOLD_D,
	ZIndex = 16,
	Shine = true,
	OnClick = function()
		if state.mode == "dialogue" and not state.typing and not state.options then
			advanceEvent:Fire()
		end
	end,
})
do
	local row = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 18, Parent = nextBtn.Content })
	Kit.list(row, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	if keyName then
		local k = keycap(row, keyName, if keyName == "SPACE" then 82 else 36, 34, if keyName == "SPACE" then 16 else 20, 19)
		k.LayoutOrder = 1
	end
	Kit.text({ Text = "NEXT", TextSize = 27, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 19, Stroke = 3.2, Parent = row })
end
nextBtn.Button.Visible = false
local nextShown = false
local nextToken = 0
function showNext(on: boolean)
	if on == nextShown then
		return
	end
	nextShown = on
	nextToken += 1
	local my = nextToken
	if on then
		nextBtn.Button.Visible = true
		nextBtn.Scale.Scale = 0.3
		tween(nextBtn.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		task.spawn(function()
			task.wait(0.4)
			while my == nextToken and dlg.Visible do
				Kit.playShine(nextBtn.Face:FindFirstChild("Shine") :: Frame)
				task.wait(2.4)
			end
		end)
	else
		nextBtn.Button.Visible = false
	end
end

-- panel height follows the words (and the options, when there are some)
function layoutDialogue(speechH: number, optionCount: number, instant: boolean?)
	local h = TOP + speechH + 24
	if optionCount > 0 then
		local listH = optionCount * OPT_H + (optionCount - 1) * OPT_GAP
		optionsFrame.Position = UDim2.fromOffset(28, h)
		optionsFrame.Size = UDim2.new(1, -56, 0, listH)
		h += listH + 30
	else
		h += 60 + 22
	end
	h = math.max(h, 236)
	speech.Size = UDim2.new(1, -80, 0, speechH + 10)
	local size = UDim2.fromOffset(dlgW, h)
	if instant or not dlg.Visible then
		dlg.Size = size
	else
		tween(dlg, 0.3, { Size = size }, Enum.EasingStyle.Quint)
	end
end

function applySpeaker(name: string)
	local info = Config.Speakers[name] or Config.Speakers[Config.QuestGiver] or { Display = string.upper(name), Role = "" }
	local h = heroOf(name)
	local a, d = h.Color, h.Deep
	dBandGrad.Color = ColorSequence.new(a, d)
	for _, f in ipairs(dBandStripeHolder:GetChildren()) do
		if f:IsA("Frame") then
			f.BackgroundColor3 = a
		end
	end
	for _, s in ipairs(dSparkles:GetChildren()) do
		if s:IsA("ImageLabel") then
			s.ImageColor3 = Kit.lighten(a, 0.45)
		end
	end
	halo.ImageColor3 = a
	pCardGrad.Color = ColorSequence.new(Kit.lighten(a, 0.15), d)
	pInnerGrad.Color = ColorSequence.new(Kit.lighten(a, 0.3), Kit.darken(d, 0.4))
	namePlateGrad.Color = ColorSequence.new(Kit.lighten(a, 0.15), d)
	local display = string.upper(info.Display or name)
	nameLabel.Text = display
	namePlate.Size = UDim2.fromOffset(Kit.textWidth(display, 42) + 64, 70)
	roleLabel.Text = string.upper(info.Role or "")
	roleLabel.TextColor3 = Kit.lighten(a, 0.35)
	nextBtn.SetColor(a, d)
	for heroName, v in pairs(portraitViews) do
		v.Visible = heroName == name
	end
end

function setSpeaker(name: string, instant: boolean?)
	local changed = state.speaker ~= name
	state.speaker = name
	cutTo(name)
	if instant or not changed or not dlg.Visible then
		applySpeaker(name)
		return
	end
	speech.Text = ""
	tween(portraitScale, 0.13, { Scale = 0.35 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(namePlateScale, 0.13, { Scale = 0.5 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
	applySpeaker(name)
	tween(portraitScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(namePlateScale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.playShine(nameSheen)
	Kit.sfx("Hover")
end

function showDialogue()
	local wasVisible = dlg.Visible
	dlg.Position = dlgHome
	dlg.Visible = true
	if wasVisible and dlgScale.Scale > 0.95 then
		return
	end
	dlgScale.Scale = 0.72
	dlg.Position = dlgHome + UDim2.fromOffset(-50, 30)
	tween(dlgScale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(dlg, 0.45, { Position = dlgHome }, Enum.EasingStyle.Back)
	portraitScale.Scale = 0.2
	namePlateScale.Scale = 0.3
	tween(portraitScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)
	tween(namePlateScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.16)
	task.delay(0.5, function()
		Kit.playShine(nameSheen)
	end)
	Kit.sfx("Open")
end

function hideDialogue()
	showNext(false)
	if not dlg.Visible then
		return
	end
	tween(dlgScale, 0.2, { Scale = 0.75 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(dlg, 0.2, { Position = dlgHome + UDim2.fromOffset(-60, 40) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.21, function()
		if state.mode ~= "dialogue" or not state.open then
			dlg.Visible = false
			dlg.Position = dlgHome
		end
	end)
end
end

---------------------------------------------------------------------------
-- badges shared by the board tabs, the dialogue options, the [E] prompt and the QUESTS sign
---------------------------------------------------------------------------
local signSub: TextLabel? = nil
local promptBadge: any = nil
local optionBadges: { [string]: any } = {}
local tabs: { [string]: any } = {}

local function totalReady(): number
	local n = 0
	for _, b in pairs(boards) do
		n += sumReady(b)
	end
	return n
end

local function refreshBadges()
	for tierName, t in pairs(tabs) do
		t.Badge.Set(sumReady(boards[tierName]))
	end
	for tierName, b in pairs(optionBadges) do
		b.Set(sumReady(boards[tierName]))
	end
	local total = totalReady()
	if promptBadge then
		promptBadge.Set(total)
	end
	local sub = signSub
	if sub then
		if total > 0 then
			sub.Text = if total == 1 then "1 REWARD READY!" else total .. " REWARDS READY!"
			sub.Visible = true
		else
			sub.Visible = false
		end
	end
end

local fetching: { [string]: boolean } = {}
local retryAt: { [string]: number } = {}
local function fetchBoard(tierName: string): any
	if fetching[tierName] then
		local t0 = os.clock()
		while fetching[tierName] and os.clock() - t0 < 20 do
			task.wait(0.05)
		end
		return boards[tierName]
	end
	fetching[tierName] = true
	local ok, b = pcall(function()
		return GetBoard:InvokeServer(tierName)
	end)
	fetching[tierName] = nil
	if ok and type(b) == "table" and type(b.Quests) == "table" then
		boards[tierName] = b
		retryAt[tierName] = nil
		refreshBadges()
		return b
	end
	retryAt[tierName] = os.clock() + 10
	return nil
end

local function fetchAll()
	for _, tierName in ipairs(Config.TierOrder) do
		task.spawn(fetchBoard, tierName)
	end
end

---------------------------------------------------------------------------
-- quest board: a Kit window that takes on the colours of the hero whose tab is open
---------------------------------------------------------------------------
local BW, BH = 1120, 740
local boardFit: UIScale, win: any, backBtn: any, claimAll: any, statusSpin: Tween
local closeQuests: () -> (), runDialogue: (string, number) -> (), goBack: () -> ()
local selectTier: (string, boolean?) -> (), claim: (string, any) -> ()
local cards: { [string]: any } = {}
local applyCard: (any, any, boolean) -> (), updateSummary: (boolean?) -> (), updateReset: () -> ()
local renderBoard: (string, boolean) -> ()

do
local boardHolder = new("Frame", {
	Name = "BoardHolder",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ZIndex = 10,
	Parent = root,
})
boardFit = new("UIScale", { Name = "Fit", Parent = boardHolder })

win = Kit.window({
	Name = "QuestBoard",
	Size = Vector2.new(BW, BH),
	Accent = { GOLD, GOLD_D },
	Title = "DAILY QUESTS",
	Icon = HERO.Goki.Icon,
	Parent = boardHolder,
	OnClose = function()
		closeQuests()
	end,
})
local content = win.Content -- 1068 x 650
local plateScale = Kit.fx(win.Plate)
local CW, CH = BW - 52, BH - 90

---------------------------------------------------------------------------
-- sidebar: hero tabs, reset timer, back, wallet
---------------------------------------------------------------------------
local SIDE_W = 250
local side = new("Frame", { Name = "Side", BackgroundTransparency = 1, Size = UDim2.new(0, SIDE_W, 1, 0), ZIndex = 12, Parent = content })

for i, tierName in ipairs(Config.TierOrder) do
	local heroName = tierHero(tierName)
	local h = heroOf(heroName)
	local info = Config.Tiers[tierName] or {}
	local t: any = { Tier = tierName, Hero = heroName }
	t.Btn = Kit.button({
		Name = tierName,
		Parent = side,
		Position = UDim2.fromOffset(0, 8 + (i - 1) * 112),
		Size = UDim2.fromOffset(SIDE_W, 100),
		Radius = 26,
		Depth = 7,
		Stroke = 4,
		Color = C.Navy600,
		Deep = C.Navy800,
		ZIndex = 13,
		HoverScale = 1.04,
		OnClick = function()
			if state.mode == "board" and state.tier ~= tierName then
				selectTier(tierName)
			end
		end,
	})
	local c = t.Btn.Content
	local disc = new("Frame", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(70, 70),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 16,
		Parent = c,
	})
	Kit.pill(disc)
	Kit.stroke(disc, 3.5, C.Ink, 0, true)
	Kit.gradient(disc, Kit.lighten(h.Color, 0.25), h.Deep, 90)
	local hold = new("Frame", { Name = "Face", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), ZIndex = 17, Parent = disc })
	if not bust(hold, heroName, "head", 17, UDim.new(1, 0)) then
		Kit.image({ Image = h.Icon, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.74, 0.74), ZIndex = 17, Parent = hold })
	end
	local display = (Config.Speakers[heroName] and Config.Speakers[heroName].Display) or heroName
	Kit.text({
		Name = "Hero",
		Text = string.upper(display),
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(94, 14),
		Size = UDim2.fromOffset(120, 34),
		ZIndex = 17,
		Stroke = 3.4,
		Parent = c,
	})
	t.Sub = Kit.text({
		Name = "Tier",
		Text = string.upper(info.Short or tierName),
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(95, 50),
		Size = UDim2.fromOffset(120, 22),
		ZIndex = 17,
		Stroke = 2.4,
		Parent = c,
	})
	if not isTouch then
		local k = keycap(c, tostring(i), 30, 30, 18, 17)
		k.AnchorPoint = Vector2.new(1, 0.5)
		k.Position = UDim2.new(1, -12, 0.5, 8)
	end
	t.Badge = badge(t.Btn.Body, 22, UDim2.new(1, -8, 0, 6))
	tabs[tierName] = t
end

local resetCard = Kit.plate({
	Name = "Reset",
	Parent = side,
	Position = UDim2.fromOffset(0, 346),
	Size = UDim2.fromOffset(SIDE_W, 92),
	Radius = 22,
	Stroke = 3.5,
	ZIndex = 12,
	Gradient = { C.Night, C.Navy900 },
})
Kit.image({ Name = "Clock", Image = Theme.Icon.Clock, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Size = UDim2.fromOffset(50, 50), ZIndex = 13, Parent = resetCard })
Kit.text({
	Text = "NEW QUESTS IN",
	TextSize = 15,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextDim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(76, 16),
	Size = UDim2.fromOffset(166, 20),
	ZIndex = 13,
	Stroke = 2.2,
	Parent = resetCard,
})
local resetText = Kit.text({
	Text = "--:--:--",
	TextSize = 30,
	TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(76, 38),
	Size = UDim2.fromOffset(166, 38),
	ZIndex = 13,
	Stroke = 3.5,
	Parent = resetCard,
})

backBtn = Kit.button({
	Name = "Back",
	Parent = side,
	Position = UDim2.fromOffset(0, 452),
	Size = UDim2.fromOffset(SIDE_W, 68),
	Radius = 22,
	Depth = 6,
	Stroke = 3.5,
	Color = C.Navy500,
	Deep = C.Navy700,
	Text = "BACK TO " .. string.upper(Config.QuestGiver),
	TextSize = 24,
	ZIndex = 13,
	OnClick = function()
		goBack()
	end,
})

local wallet = Kit.plate({
	Name = "Wallet",
	Parent = side,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, -4),
	Size = UDim2.fromOffset(SIDE_W, 100),
	Radius = 22,
	Stroke = 4,
	ZIndex = 12,
	Gradient = { C.Night, C.Navy900 },
})
Kit.text({
	Text = "YOUR COINS",
	TextSize = 16,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextDim,
	Position = UDim2.fromOffset(0, 12),
	Size = UDim2.new(1, 0, 0, 22),
	ZIndex = 13,
	Stroke = 2.4,
	Parent = wallet,
})
local walletRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 48), ZIndex = 13, Parent = wallet })
Kit.list(walletRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
local walletCoin = Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(46, 46), ZIndex = 14, LayoutOrder = 1, Parent = walletRow })
local walletText = Kit.text({
	Text = "0",
	TextSize = 34,
	TextColor3 = C.Gold,
	Size = UDim2.new(0, 0, 1, 0),
	AutomaticSize = Enum.AutomaticSize.X,
	ZIndex = 14,
	LayoutOrder = 2,
	Stroke = 4,
	Parent = walletRow,
})
local setWallet = Kit.counter(walletText, Theme.Comma, 0)
local walletCoinScale = Kit.fx(walletCoin)
task.spawn(function()
	local ls = player:WaitForChild("leaderstats", 60)
	local coins = ls and ls:WaitForChild("Coins", 30)
	if coins and coins:IsA("ValueBase") then
		setWallet((coins :: any).Value, true)
		;(coins :: any).Changed:Connect(function(v)
			setWallet(tonumber(v) or 0)
			walletCoinScale.Scale = 1.35
			tween(walletCoinScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end
end)

---------------------------------------------------------------------------
-- main column: header, quest list, rewards + claim all
---------------------------------------------------------------------------
local MX = SIDE_W + 18
local MW = CW - MX

local header = Kit.plate({
	Name = "Header",
	Parent = content,
	Position = UDim2.fromOffset(MX, 8),
	Size = UDim2.fromOffset(MW, 80),
	Radius = 24,
	Stroke = 3.5,
	ZIndex = 12,
	Gradient = { C.Night, C.Navy900 },
})
local headerIcon = Kit.image({ Name = "TierIcon", Image = HERO.Goki.Icon, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(44, 40), Size = UDim2.fromOffset(64, 64), ZIndex = 13, Parent = header })
local headerIconScale = Kit.fx(headerIcon)
local blurb = Kit.text({
	Name = "Blurb",
	Text = "",
	TextSize = 19,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextSoft,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(88, 0),
	Size = UDim2.fromOffset(400, 80),
	ZIndex = 13,
	Stroke = 2.4,
	Parent = header,
})
local doneCount = Kit.text({
	Name = "Done",
	Text = "0/4",
	TextSize = 36,
	TextXAlignment = Enum.TextXAlignment.Right,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -20, 0.5, 0),
	Size = UDim2.fromOffset(90, 46),
	ZIndex = 13,
	Stroke = 4,
	Parent = header,
})
local doneScale = Kit.fx(doneCount)
Kit.text({
	Text = "COMPLETED",
	TextSize = 15,
	FontFace = Theme.Font.Heavy,
	TextColor3 = C.TextDim,
	TextXAlignment = Enum.TextXAlignment.Right,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -122, 0, 14),
	Size = UDim2.fromOffset(180, 20),
	ZIndex = 13,
	Stroke = 2.2,
	Parent = header,
})
local pips = new("Frame", { Name = "Pips", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -122, 0, 42), Size = UDim2.fromOffset(200, 20), ZIndex = 13, Parent = header })
Kit.list(pips, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)

local LIST_Y, LIST_H = 100, 466
local list = new("ScrollingFrame", {
	Name = "List",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(MX, LIST_Y),
	Size = UDim2.fromOffset(MW, LIST_H),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = C.Rim,
	ScrollBarImageTransparency = 0.3,
	ZIndex = 12,
	Parent = content,
})
Kit.padding(list, 6, 6, 16, 6)
Kit.list(list, Enum.FillDirection.Vertical, 12)

-- loading / error message over the list
local statusFrame = new("Frame", { Name = "Status", BackgroundTransparency = 1, Position = list.Position, Size = list.Size, Visible = false, ZIndex = 14, Parent = content })
local statusStar = Kit.image({ Image = Theme.Icon.Star, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -70), Size = UDim2.fromOffset(64, 64), ZIndex = 15, Parent = statusFrame })
statusSpin = TweenService:Create(statusStar, TweenInfo.new(1.4, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 })
local statusText = Kit.text({ Text = "", TextSize = 28, TextColor3 = C.TextSoft, Position = UDim2.new(0, 0, 0.5, -24), Size = UDim2.new(1, 0, 0, 40), ZIndex = 15, Stroke = 3.2, Parent = statusFrame })
local retryBtn = Kit.button({
	Name = "Retry",
	Parent = statusFrame,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.5, 34),
	Size = UDim2.fromOffset(230, 64),
	Radius = 20,
	Color = C.Blue,
	Deep = C.BlueDeep,
	Text = "TRY AGAIN",
	TextSize = 25,
	ZIndex = 15,
	OnClick = function()
		selectTier(state.tier, true)
	end,
})
local function showStatus(text: string, failed: boolean?)
	statusFrame.Visible = true
	statusText.Text = text
	retryBtn.Button.Visible = failed == true
	statusStar.Visible = not failed
	if failed then
		statusSpin:Pause()
	else
		statusStar.Rotation = 0
		statusSpin:Play()
	end
end
local function hideStatus()
	statusFrame.Visible = false
	statusSpin:Pause()
end

local FOOT_Y = LIST_Y + LIST_H + 12
local rewardsPlate = Kit.plate({
	Name = "Rewards",
	Parent = content,
	Position = UDim2.fromOffset(MX, FOOT_Y),
	Size = UDim2.fromOffset(MW - 272, CH - FOOT_Y - 4),
	Radius = UDim.new(1, 0),
	Stroke = 3.5,
	ZIndex = 12,
	Gradient = { C.Night, C.Navy900 },
})
local rewardRow = new("Frame", { Name = "Left", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 13, Parent = rewardsPlate })
Kit.list(rewardRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
Kit.text({ Text = "UNCLAIMED", TextSize = 16, FontFace = Theme.Font.Heavy, TextColor3 = C.TextDim, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 13, Stroke = 2.2, Parent = rewardRow })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(4, 10), LayoutOrder = 2, Parent = rewardRow })
Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(40, 40), LayoutOrder = 3, ZIndex = 14, Parent = rewardRow })
local rewardCoins = Kit.text({ Text = "0", TextSize = 28, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 4, ZIndex = 14, Stroke = 3.5, Parent = rewardRow })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(8, 10), LayoutOrder = 5, Parent = rewardRow })
Kit.image({ Image = Theme.Icon.Star, Size = UDim2.fromOffset(34, 34), LayoutOrder = 6, ZIndex = 14, Parent = rewardRow })
local rewardXp = Kit.text({ Text = "0 XP", TextSize = 25, TextColor3 = rgb(140, 212, 255), Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 7, ZIndex = 14, Stroke = 3.2, Parent = rewardRow })
local clearRow = new("Frame", { Name = "AllClear", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 13, Parent = rewardsPlate })
Kit.list(clearRow, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
Kit.image({ Image = Theme.Icon.Check, Size = UDim2.fromOffset(40, 40), LayoutOrder = 1, ZIndex = 14, Parent = clearRow })
Kit.text({ Text = "ALL CLEAR!", TextSize = 27, TextColor3 = C.Green, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 14, Stroke = 3.5, Parent = clearRow })
Kit.text({ Text = "Fresh quests after the reset", TextSize = 16, FontFace = Theme.Font.Heavy, TextColor3 = C.TextSoft, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 3, ZIndex = 14, Stroke = 2.2, Parent = clearRow })

claimAll = Kit.button({
	Name = "ClaimAll",
	Parent = content,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromOffset(CW, FOOT_Y - 4),
	Size = UDim2.fromOffset(258, CH - FOOT_Y + 4),
	Radius = 24,
	Depth = 7,
	Stroke = 4,
	Color = C.Green,
	Deep = C.GreenDeep,
	Icon = Theme.Icon.Coin,
	IconSize = 42,
	Gap = 6,
	Text = "CLAIM ALL",
	TextSize = 27,
	ZIndex = 13,
	Shine = true,
	OnClick = function(api)
		claim("*", api)
	end,
})

---------------------------------------------------------------------------
-- quest cards
---------------------------------------------------------------------------
local CARD_H = 104

local function setGrad(g: UIGradient?, a: Color3, b: Color3)
	if g then
		g.Color = ColorSequence.new(a, b)
	end
end

local function buildCard(i: number, q: any, tierName: string)
	local a, d = tierColors(tierName)
	local slot = new("Frame", { Name = q.Id, BackgroundTransparency = 1, LayoutOrder = i, Size = UDim2.new(1, 0, 0, CARD_H), ZIndex = 13, Parent = list })
	local card = Kit.plate({
		Name = "Card",
		Parent = slot,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Radius = 22,
		Stroke = 4,
		ZIndex = 13,
		Gradient = { C.Navy600, C.Navy800 },
	})
	local cardScale = Kit.fx(card)
	Kit.bevel(card, 19, 4, 13)

	local disc = new("Frame", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(54, CARD_H / 2),
		Size = UDim2.fromOffset(76, 76),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 14,
		Parent = card,
	})
	Kit.pill(disc)
	Kit.stroke(disc, 4, C.Ink, 0, true)
	local discGrad = Kit.gradient(disc, Kit.lighten(a, 0.15), d, 90)
	local discScale = Kit.fx(disc)
	local num = Kit.text({ Name = "Num", Text = tostring(i), TextSize = 38, ZIndex = 16, Stroke = 4, Parent = disc })
	local mark = Kit.image({ Name = "Mark", Image = Theme.Icon.Check, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(54, 54), Visible = false, ZIndex = 16, Parent = disc })

	local title = Kit.text({ Name = "Title", Text = q.Title, TextSize = 27, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(106, 12), Size = UDim2.fromOffset(350, 32), ZIndex = 14, Stroke = 3.4, Parent = card })
	Kit.text({
		Name = "Desc",
		Text = q.Desc,
		TextSize = 17,
		FontFace = Theme.Font.Bold,
		TextColor3 = C.TextSoft,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(107, 43),
		Size = UDim2.fromOffset(350, 22),
		ZIndex = 14,
		Stroke = false,
		Parent = card,
	})
	local bar = Kit.bar({ Parent = card, Position = UDim2.fromOffset(106, 70), Size = UDim2.fromOffset(340, 22), Color = a, Deep = d, ZIndex = 14, TextSize = 15 })
	local barGrad = bar.Fill:FindFirstChildOfClass("UIGradient")

	-- rewards
	local rew = new("Frame", { Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(464, 0), Size = UDim2.fromOffset(140, CARD_H), ZIndex = 14, Parent = card })
	local r1 = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 40), ZIndex = 14, Parent = rew })
	Kit.list(r1, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.image({ Image = Theme.Icon.Coin, Size = UDim2.fromOffset(38, 38), LayoutOrder = 1, ZIndex = 15, Parent = r1 })
	Kit.text({ Text = Theme.Comma(q.Reward and q.Reward.Coins or 0), TextSize = 26, TextColor3 = C.Gold, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 15, Stroke = 3.4, Parent = r1 })
	local r2 = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(3, 56), Size = UDim2.new(1, 0, 0, 32), ZIndex = 14, Parent = rew })
	Kit.list(r2, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.image({ Image = Theme.Icon.Star, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, ZIndex = 15, Parent = r2 })
	Kit.text({ Text = Theme.Comma(q.Reward and q.Reward.XP or 0) .. " XP", TextSize = 20, TextColor3 = rgb(140, 212, 255), Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 15, Stroke = 2.8, Parent = r2 })

	-- right side: percent / CLAIM / CLAIMED
	local pct = Kit.plate({
		Name = "Percent",
		Parent = card,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(150, 56),
		Radius = UDim.new(1, 0),
		Stroke = 3.5,
		ZIndex = 14,
		Gradient = { C.Night, C.Navy900 },
	})
	local pctText = Kit.text({ Text = "0%", TextSize = 28, TextColor3 = C.TextSoft, ZIndex = 15, Stroke = 3.2, Parent = pct })
	local done = Kit.plate({
		Name = "Claimed",
		Parent = card,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(150, 56),
		Radius = UDim.new(1, 0),
		Stroke = 3.5,
		ZIndex = 14,
		Gradient = { Kit.darken(C.GreenDeep, 0.05), Kit.darken(C.GreenDeep, 0.45) },
	})
	done.Visible = false
	local doneRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = done })
	Kit.list(doneRow, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Kit.image({ Image = Theme.Icon.Check, Size = UDim2.fromOffset(32, 32), LayoutOrder = 1, ZIndex = 16, Parent = doneRow })
	Kit.text({ Text = "CLAIMED", TextSize = 21, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 16, Stroke = 2.8, Parent = doneRow })
	local claimBtn = Kit.button({
		Name = "Claim",
		Parent = card,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, -1),
		Size = UDim2.fromOffset(150, 66),
		Radius = 21,
		Depth = 6,
		Stroke = 3.5,
		Color = C.Green,
		Deep = C.GreenDeep,
		Text = "CLAIM",
		TextSize = 28,
		ZIndex = 15,
		Shine = true,
		OnClick = function(api)
			claim(q.Id, api)
		end,
	})
	claimBtn.Button.Visible = false

	local c = {
		Id = q.Id,
		A = a,
		D = d,
		Slot = slot,
		Card = card,
		Scale = cardScale,
		Grad = card:FindFirstChildOfClass("UIGradient"),
		Stroke = card:FindFirstChildOfClass("UIStroke"),
		Disc = disc,
		DiscGrad = discGrad,
		DiscScale = discScale,
		Num = num,
		Mark = mark,
		Title = title,
		Bar = bar,
		BarGrad = barGrad,
		Pct = pct,
		PctText = pctText,
		Done = done,
		ClaimBtn = claimBtn,
		Status = nil :: string?,
		Shimmer = nil :: UIGradient?,
	}
	cards[q.Id] = c
	return c
end

function applyCard(c: any, q: any, animate: boolean)
	local frac = math.clamp(q.Progress / math.max(1, q.Goal), 0, 1)
	c.Bar.Set(frac, not animate)
	c.Bar.Label.Text = Config.FormatProgress(q.Stat, math.min(q.Progress, q.Goal)) .. " / " .. Config.FormatProgress(q.Stat, q.Goal)
	c.PctText.Text = math.floor(frac * 100) .. "%"
	local status = if q.Claimed then "claimed" elseif q.Progress >= q.Goal then "ready" else "progress"
	if status == c.Status then
		return
	end
	local first = c.Status == nil
	c.Status = status
	c.Pct.Visible = status == "progress"
	c.ClaimBtn.Button.Visible = status == "ready"
	c.Done.Visible = status == "claimed"
	c.Num.Visible = status == "progress"
	c.Mark.Visible = status ~= "progress"
	if c.Shimmer then
		c.Shimmer:Destroy()
		c.Shimmer = nil
	end
	if status == "progress" then
		setGrad(c.Grad, C.Navy600, C.Navy800)
		c.Stroke.Color = C.Ink
		c.Stroke.Thickness = 4
		setGrad(c.DiscGrad, Kit.lighten(c.A, 0.15), c.D)
		setGrad(c.BarGrad, c.A, c.D)
		c.Title.TextColor3 = C.Text
	elseif status == "ready" then
		setGrad(c.Grad, C.Navy600:Lerp(C.Gold, 0.18), C.Navy800:Lerp(C.GoldDeep, 0.1))
		c.Stroke.Color = Color3.new(1, 1, 1)
		c.Stroke.Thickness = 4.5
		c.Shimmer = Kit.shimmer(c.Stroke, C.Gold, C.GoldDeep)
		setGrad(c.DiscGrad, Kit.lighten(C.Gold, 0.15), C.GoldDeep)
		c.Mark.Image = Theme.Icon.Star
		setGrad(c.BarGrad, C.Green, C.GreenDeep)
		c.Title.TextColor3 = C.Text
	else
		setGrad(c.Grad, C.Navy700, C.Navy900)
		c.Stroke.Color = C.Ink
		c.Stroke.Thickness = 4
		setGrad(c.DiscGrad, Kit.lighten(C.Green, 0.1), C.GreenDeep)
		c.Mark.Image = Theme.Icon.Check
		setGrad(c.BarGrad, C.Green, C.GreenDeep)
		c.Title.TextColor3 = C.TextSoft
	end
	if animate and not first then
		c.DiscScale.Scale = 0.45
		tween(c.DiscScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
		Kit.wiggle(c.Mark)
		local pop = if status == "ready" then c.ClaimBtn.Scale elseif status == "claimed" then Kit.fx(c.Done) else Kit.fx(c.Pct)
		pop.Scale = 0.35
		tween(pop, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
		if status == "ready" then
			Kit.sfx("Equip")
			Kit.playShine(c.ClaimBtn.Face:FindFirstChild("Shine") :: Frame)
		end
	end
end

local function setPips(total: number)
	local have = {}
	for _, p in ipairs(pips:GetChildren()) do
		if p:IsA("Frame") then
			table.insert(have, p)
		end
	end
	if #have == total then
		return have
	end
	for _, p in ipairs(have) do
		p:Destroy()
	end
	have = {}
	for i = 1, total do
		local p = new("Frame", { Name = "Pip" .. i, BackgroundColor3 = C.Navy500, Size = UDim2.fromOffset(if total > 4 then 26 else 36, 16), LayoutOrder = i, ZIndex = 14, Parent = pips })
		Kit.pill(p)
		Kit.stroke(p, 2.5, C.Ink, 0, true)
		table.insert(have, p)
	end
	return have
end

local lastDone = -1
function updateSummary(animate: boolean?)
	local b = boards[state.tier]
	if not b then
		return
	end
	local total, done, ready, coins, xp = #b.Quests, 0, 0, 0, 0
	local pipList = setPips(total)
	for i, q in ipairs(b.Quests) do
		local isDone = q.Progress >= q.Goal
		if isDone then
			done += 1
			if not q.Claimed then
				ready += 1
			end
		end
		if not q.Claimed then
			coins += q.Reward and q.Reward.Coins or 0
			xp += q.Reward and q.Reward.XP or 0
		end
		local p = pipList[i]
		if p then
			local col = if q.Claimed then C.Green elseif isDone then C.Gold else C.Navy500
			if animate then
				tween(p, 0.3, { BackgroundColor3 = col })
			else
				p.BackgroundColor3 = col
			end
		end
	end
	doneCount.Text = done .. "/" .. total
	doneCount.TextColor3 = if done == total and total > 0 then C.Green else C.Text
	if animate and done ~= lastDone then
		doneScale.Scale = 1.3
		tween(doneScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	lastDone = done
	rewardCoins.Text = Theme.Comma(coins)
	rewardXp.Text = Theme.Comma(xp) .. " XP"
	local allClear = coins == 0 and xp == 0 and total > 0
	rewardRow.Visible = not allClear
	clearRow.Visible = allClear
	if ready > 0 then
		claimAll.SetColor(C.Green, C.GreenDeep)
		claimAll.SetText("CLAIM ALL (" .. ready .. ")")
		claimAll.Enabled = true
		if claimAll.Icon then
			claimAll.Icon.ImageTransparency = 0
		end
	else
		claimAll.SetColor(C.Navy600, C.Navy800)
		claimAll.SetText("CLAIM ALL")
		claimAll.Enabled = false
		if claimAll.Icon then
			claimAll.Icon.ImageTransparency = 0.5
		end
	end
	claimAll.Label.TextTransparency = if ready > 0 then 0 else 0.35
end

function updateReset()
	local b = boards[state.tier]
	if b and b.ResetAt then
		resetText.Text = Config.FormatDuration(b.ResetAt - workspace:GetServerTimeNow())
	else
		resetText.Text = "--:--:--"
	end
end

local function clearCards()
	for _, c in pairs(cards) do
		c.Slot:Destroy()
	end
	cards = {}
end

function renderBoard(tierName: string, animate: boolean)
	clearCards()
	local b = boards[tierName]
	if not b then
		return
	end
	hideStatus()
	for i, q in ipairs(b.Quests) do
		local c = buildCard(i, q, tierName)
		applyCard(c, q, false)
		if animate then
			c.Bar.Set(0, true)
			c.Scale.Scale = 0.6
			tween(c.Scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05 + i * 0.06)
			local frac = math.clamp(q.Progress / math.max(1, q.Goal), 0, 1)
			task.delay(0.25 + i * 0.06, function()
				if cards[q.Id] == c then
					c.Bar.Set(frac)
				end
			end)
		end
	end
	updateSummary(false)
	updateReset()
end

local loadToken = 0
selectTier = function(tierName: string, instant: boolean?)
	state.tier = tierName
	local heroName = tierHero(tierName)
	local h = heroOf(heroName)
	win.SetAccent(h.Color, h.Deep)
	win.SetTitle(string.upper((Config.Tiers[tierName] and Config.Tiers[tierName].Short) or tierName) .. " QUESTS")
	win.TitleIcon.Image = h.Icon
	headerIcon.Image = h.Icon
	blurb.Text = (Config.Tiers[tierName] and Config.Tiers[tierName].Blurb) or ""
	for tn, t in pairs(tabs) do
		local th = heroOf(t.Hero)
		if tn == tierName then
			t.Btn.SetColor(th.Color, th.Deep)
			t.Sub.TextColor3 = C.Text
		else
			t.Btn.SetColor(C.Navy600, C.Navy800)
			t.Sub.TextColor3 = C.TextSoft
		end
	end
	if not instant then
		plateScale.Scale = 0.86
		tween(plateScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		headerIconScale.Scale = 0.4
		tween(headerIconScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	list.CanvasPosition = Vector2.zero
	lastDone = -1
	loadToken += 1
	local my = loadToken
	if boards[tierName] then
		renderBoard(tierName, true)
	else
		clearCards()
		showStatus("LOADING QUESTS...")
		task.spawn(function()
			local b = fetchBoard(tierName)
			if my ~= loadToken or state.tier ~= tierName then
				return
			end
			if b then
				renderBoard(tierName, true)
			else
				showStatus("COULDN'T LOAD QUESTS", true)
			end
		end)
	end
	updateReset()
end

---------------------------------------------------------------------------
-- claiming
---------------------------------------------------------------------------
local function celebrate(res: any, from: UDim2)
	Kit.sfx("Buy")
	for n, id in ipairs(res.Claimed or {}) do
		local c = cards[id]
		if c then
			local at = toRoot(c.Disc)
			task.delay((n - 1) * 0.12, function()
				burst(at, C.Gold, 12)
				local fl = new("Frame", { Name = "Flash", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.3, Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = c.Card })
				Kit.corner(fl, 22)
				tween(fl, 0.5, { BackgroundTransparency = 1 }).Completed:Connect(function()
					fl:Destroy()
				end)
				c.Scale.Scale = 1.04
				tween(c.Scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end)
		end
	end
	local coins = tonumber(res.Coins) or 0
	local xp = tonumber(res.XP) or 0
	if coins > 0 then
		flyCoins(from, toRoot(walletCoin), math.clamp(math.floor(coins / 80), 6, 16))
		float(from + UDim2.fromOffset(0, -34), "+" .. Theme.Comma(coins), C.Gold)
	end
	if xp > 0 then
		float(from + UDim2.fromOffset(0, 14), "+" .. Theme.Comma(xp) .. " XP", rgb(140, 212, 255), 0.15)
	end
	win.Scale.Scale = 1.012
	tween(win.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
end

claim = function(questId: string, api: any)
	if state.claiming or state.mode ~= "board" then
		return
	end
	local tierName = state.tier
	if not boards[tierName] then
		return
	end
	state.claiming = true
	local from = toRoot(if api then api.Button else claimAll.Button)
	if api then
		api.Enabled = false
		if questId ~= "*" then
			api.SetText("...")
		end
	end
	local ok, res = pcall(function()
		return ClaimQuest:InvokeServer(tierName, questId)
	end)
	state.claiming = false
	if api then
		api.Enabled = true
		if questId ~= "*" then
			api.SetText("CLAIM")
		end
	end
	if not ok or type(res) ~= "table" then
		Kit.sfx("Error")
		if api then
			Kit.shake(api.Button)
		end
		return
	end
	if type(res.Board) == "table" and type(res.Board.Quests) == "table" then
		boards[res.Board.Tier or tierName] = res.Board
	end
	if res.Ok then
		celebrate(res, from)
	elseif api then
		Kit.sfx("Error")
		Kit.shake(api.Button)
	end
	if state.mode == "board" and state.tier == tierName and boards[tierName] then
		for _, q in ipairs(boards[tierName].Quests) do
			local c = cards[q.Id]
			if c then
				local order = table.find(res.Claimed or {}, q.Id)
				task.delay(if order then (order - 1) * 0.12 else 0, function()
					if cards[q.Id] == c then
						applyCard(c, q, true)
					end
				end)
			end
		end
		updateSummary(true)
	end
	refreshBadges()
end
end

---------------------------------------------------------------------------
-- dialogue: typing, continue, choices
---------------------------------------------------------------------------
local function clearOptions()
	for _, ch in ipairs(optionsFrame:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	optionBadges = {}
	state.options = nil
end

local function typeLine(text: string, session: number, heroName: string, optionCount: number)
	local h = heroOf(heroName)
	state.typing = true
	state.skip = false
	showNext(false)
	local th = Kit.textHeight(plain(text), SPEECH, dlgW - 80)
	if state.session ~= session then
		return
	end
	layoutDialogue(th, optionCount)
	speech.Text = highlight(text, Kit.lighten(h.Color, 0.2))
	speech.MaxVisibleGraphemes = 0
	local chars = {}
	local okCodes = pcall(function()
		for _, cp in utf8.codes(speech.ContentText) do
			table.insert(chars, utf8.char(cp))
		end
	end)
	if not okCodes then
		chars = string.split(speech.ContentText, "")
	end
	local total = #chars
	local shown, acc, sinceBlip, delay = 0, 0, 2, 0.02
	while shown < total do
		if state.session ~= session then
			return
		end
		if state.skip then
			break
		end
		acc += task.wait()
		local stepped = false
		while shown < total and acc >= delay do
			acc -= delay
			shown += 1
			stepped = true
			local ch = chars[shown]
			if ch ~= " " then
				sinceBlip += 1
			end
			if ch == "." or ch == "!" or ch == "?" then
				delay = 0.2
			elseif ch == "," then
				delay = 0.09
			else
				delay = 0.024
			end
			if delay > 0.05 then
				acc = 0 -- let the pause after punctuation actually show
				break
			end
		end
		if stepped then
			speech.MaxVisibleGraphemes = shown
			if sinceBlip >= 2 then
				sinceBlip = 0
				blip(h.Voice)
			end
		end
	end
	speech.MaxVisibleGraphemes = -1
	state.typing = false
end

local function waitAdvance(session: number): boolean
	showNext(true)
	advanceEvent.Event:Wait()
	showNext(false)
	return state.session == session and state.open
end

local hiddenSelection = new("Frame", { Name = "NoSelectionImage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })

local function buildOption(i: number, opt: any)
	local target = opt.Next and Config.Dialogue[opt.Next]
	local tierName = target and target.Board
	local heroName = (tierName and tierHero(tierName)) or (target and target.Speaker)
	local h = heroName and HERO[heroName]
	local hoverA: Color3 = if h then h.Color elseif opt.Leave then C.Red else C.Blue
	local hoverD: Color3 = if h then h.Deep elseif opt.Leave then C.RedDeep else C.BlueDeep
	local holder = new("Frame", { Name = "Option" .. i, BackgroundTransparency = 1, LayoutOrder = i, Size = UDim2.new(1, 0, 0, OPT_H), ZIndex = 15, Parent = optionsFrame })
	local key: Frame? = nil
	local api: any
	local function hover(on: boolean)
		if not api or not api.Enabled then
			return
		end
		if on then
			api.SetColor(hoverA, hoverD)
			Kit.sfx("Hover")
			if key then
				Kit.wiggle(key, 0.6)
			end
		else
			api.SetColor(C.Navy600, C.Navy800)
		end
	end
	api = Kit.button({
		Name = "Row",
		Parent = holder,
		Size = UDim2.fromScale(1, 1),
		Radius = 22,
		Depth = 6,
		Stroke = 3.5,
		Color = C.Navy600,
		Deep = C.Navy800,
		ZIndex = 15,
		HoverScale = 1.025,
		Shine = true,
		OnHover = hover,
		OnClick = function()
			if state.options then
				choiceEvent:Fire(i)
			end
		end,
	})
	api.Button.SelectionImageObject = hiddenSelection
	api.Button.SelectionGained:Connect(function()
		hover(true)
	end)
	api.Button.SelectionLost:Connect(function()
		hover(false)
	end)
	local c = api.Content
	key = keycap(c, tostring(i), 46, 46, 26, 17)
	local k = key :: Frame
	k.AnchorPoint = Vector2.new(0, 0.5)
	k.Position = UDim2.new(0, 14, 0.5, 0)
	Kit.text({
		Name = "Text",
		Text = opt.Text or "",
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(76, -1),
		Size = UDim2.new(1, -236, 1, 0),
		ZIndex = 17,
		Stroke = 3.2,
		Parent = c,
	})
	if tierName and h then
		local pill = Kit.plate({
			Name = "Tier",
			Parent = c,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -18, 0.5, 0),
			Size = UDim2.fromOffset(136, 40),
			Radius = UDim.new(1, 0),
			Stroke = 3,
			ZIndex = 17,
			Gradient = { Kit.lighten(h.Color, 0.1), h.Deep },
		})
		Kit.text({ Text = string.upper((Config.Tiers[tierName] and Config.Tiers[tierName].Short) or tierName), TextSize = 21, ZIndex = 18, Stroke = 2.8, Parent = pill })
		local b = badge(pill, 20, UDim2.new(1, -4, 0, 2))
		optionBadges[tierName] = b
		b.Set(sumReady(boards[tierName]))
	elseif opt.Leave then
		local tile = new("Frame", { Name = "Leave", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -22, 0.5, 0), Size = UDim2.fromOffset(40, 40), ZIndex = 17, Parent = c })
		Kit.corner(tile, 12)
		Kit.stroke(tile, 2.6, C.Ink, 0, true)
		Kit.gradient(tile, Color3.fromRGB(255, 104, 110), Color3.fromRGB(206, 40, 60), 90)
		Kit.closeGlyph(tile, 20, 18)
	end
	api.Scale.Scale = 0
	tween(api.Scale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.04 + i * 0.065)
	return { Api = api, Hover = hoverA, HoverD = hoverD }
end

local function askOptions(options: { any }, session: number): number?
	clearOptions()
	state.options = options
	local built = {}
	for i, opt in ipairs(options) do
		built[i] = buildOption(i, opt)
	end
	if UserInputService.GamepadEnabled and built[1] then
		task.delay(0.35, function()
			if state.options == options then
				GuiService.SelectedObject = built[1].Api.Button
			end
		end)
	end
	local idx = choiceEvent.Event:Wait()
	state.options = nil
	GuiService.SelectedObject = nil
	if state.session ~= session or not state.open or not idx or not built[idx] then
		return nil
	end
	Kit.sfx("Click")
	for i, b in ipairs(built) do
		if i == idx then
			b.Api.SetColor(b.Hover, b.HoverD)
			b.Api.Enabled = false
			b.Api.Scale.Scale = 1.07
			tween(b.Api.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			Kit.playShine(b.Api.Face:FindFirstChild("Shine") :: Frame)
		else
			b.Api.Enabled = false
			tween(b.Api.Scale, 0.2, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		end
	end
	task.wait(0.34)
	clearOptions()
	return idx
end

local function readyLine(n: number): string
	if n == 1 then
		return "Oh, and you've got a reward waiting to be claimed!"
	end
	return ("Oh, and you've got %d rewards waiting to be claimed!"):format(n)
end

---------------------------------------------------------------------------
-- board in / out
---------------------------------------------------------------------------
local function letterbox(on: boolean)
	local s = if on then LETTERBOX else 0
	tween(barTop, 0.5, { Size = UDim2.fromScale(1, s) }, Enum.EasingStyle.Quint)
	tween(barBot, 0.5, { Size = UDim2.fromScale(1, s) }, Enum.EasingStyle.Quint)
end

local function showBoard(tierName: string)
	state.mode = "board"
	hideDialogue()
	letterbox(false)
	camWide()
	tween(blur, 0.5, { Size = 14 })
	dim.Visible = true
	tween(dim, 0.35, { BackgroundTransparency = 0.5 })
	selectTier(tierName, true)
	win.Open()
	if UserInputService.GamepadEnabled then
		task.delay(0.5, function()
			if state.mode == "board" then
				local t = tabs[tierName]
				GuiService.SelectedObject = if t then t.Btn.Button else backBtn.Button
			end
		end)
	end
end

local function hideBoard()
	win.Close()
	statusSpin:Pause()
	tween(blur, 0.35, { Size = 0 })
	tween(dim, 0.25, { BackgroundTransparency = 1 }).Completed:Connect(function()
		if state.mode ~= "board" then
			dim.Visible = false
		end
	end)
	GuiService.SelectedObject = nil
end

goBack = function()
	if state.mode ~= "board" then
		return
	end
	state.mode = "dialogue"
	hideBoard()
	letterbox(true)
	speech.Text = ""
	clearOptions()
	state.speaker = Config.QuestGiver
	applySpeaker(Config.QuestGiver)
	cutTo(Config.QuestGiver)
	layoutDialogue(40, 0, true)
	showDialogue()
	task.spawn(runDialogue, "Ask", state.session)
end

---------------------------------------------------------------------------
-- the conversation
---------------------------------------------------------------------------
runDialogue = function(nodeName: string, session: number)
	local node = Config.Dialogue[nodeName]
	while node and state.session == session and state.open do
		state.mode = "dialogue"
		setSpeaker(node.Speaker)
		if state.session ~= session then
			return
		end
		clearOptions()
		local lines = node.Lines or {}
		for i, line in ipairs(lines) do
			local last = i == #lines
			-- before the question, mention rewards that are waiting (once per visit)
			if last and node.Options and not state.toldReady then
				local n = totalReady()
				if n > 0 then
					state.toldReady = true
					typeLine(readyLine(n), session, node.Speaker, 0)
					if state.session ~= session or not waitAdvance(session) then
						return
					end
				end
			end
			typeLine(line, session, node.Speaker, if last and node.Options then #node.Options else 0)
			if state.session ~= session then
				return
			end
			if not (last and node.Options) then
				if not waitAdvance(session) then
					return
				end
			end
		end
		if node.Options then
			local idx = askOptions(node.Options, session)
			if not idx then
				return
			end
			local opt = node.Options[idx]
			if opt.Leave then
				task.spawn(closeQuests)
				return
			end
			node = Config.Dialogue[opt.Next]
		elseif node.Board then
			showBoard(node.Board)
			return
		elseif node.Next then
			node = Config.Dialogue[node.Next]
		else
			return
		end
	end
end

---------------------------------------------------------------------------
-- open / close
---------------------------------------------------------------------------
local questPrompt: ProximityPrompt? = nil
local questSign: BillboardGui? = nil

local function openQuests()
	if state.open then
		return
	end
	-- give Goki's rig a moment to stream in so the camera has a pose to frame
	local readyAt = os.clock() + 4
	repeat
		refreshRigs()
		local found = false
		for _, rig in ipairs(rigs) do
			if rig.Name == Config.QuestGiver then
				found = true
				break
			end
		end
		if found then
			break
		end
		task.wait(0.1)
	until os.clock() >= readyAt
	if state.open then
		return
	end
	state.open = true
	state.session += 1
	local session = state.session
	state.mode = "dialogue"
	state.toldReady = false
	state.speaker = Config.QuestGiver
	if questPrompt then
		questPrompt.Enabled = false
	end
	if questSign then
		questSign.Enabled = false
	end
	lockCharacterToGoki()
	setControls(false)
	camStart()
	cutTo(Config.QuestGiver)
	flash.BackgroundTransparency = 0.35
	tween(flash, 0.55, { BackgroundTransparency = 1 })
	cine.Visible = true
	for _, v in ipairs(vignettes) do
		v.BackgroundTransparency = 1
		tween(v, 0.6, { BackgroundTransparency = 0 })
	end
	letterbox(true)
	task.spawn(fetchAll)
	speech.Text = ""
	clearOptions()
	applySpeaker(Config.QuestGiver)
	layoutDialogue(40, 0, true)
	task.wait(0.3)
	if state.session ~= session then
		return
	end
	showDialogue()
	task.wait(0.35)
	if state.session ~= session then
		return
	end
	local start = if state.talkedThisSession then "Welcome" else "Start"
	state.talkedThisSession = true
	task.spawn(runDialogue, start, session)
end

closeQuests = function()
	if not state.open then
		return
	end
	state.open = false
	state.session += 1
	local wasBoard = state.mode == "board"
	state.mode = "none"
	state.options = nil
	state.typing = false
	advanceEvent:Fire()
	choiceEvent:Fire(nil)
	GuiService.SelectedObject = nil
	if wasBoard then
		hideBoard()
	end
	hideDialogue()
	letterbox(false)
	for _, v in ipairs(vignettes) do
		tween(v, 0.4, { BackgroundTransparency = 1 })
	end
	tween(blur, 0.35, { Size = 0 })
	camRestore()
	if state.open then
		return
	end
	cine.Visible = false
	setControls(true)
	unlockCharacter()
	if questSign then
		questSign.Enabled = true
	end
	if questPrompt then
		questPrompt.Enabled = true
	end
	refreshBadges()
end

-- dying / respawning while talking never leaves you stuck
player.CharacterAdded:Connect(function()
	if state.open then
		task.defer(closeQuests)
	end
end)

dClose.Activated:Connect(function()
	Kit.sfx("Click")
	closeQuests()
end)

catcher.Activated:Connect(function()
	if state.mode ~= "dialogue" or state.options then
		return
	end
	if state.typing then
		state.skip = true
	else
		advanceEvent:Fire()
	end
end)

local NUM_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
}
local ADVANCE_KEYS = {
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.E] = true,
	[Enum.KeyCode.Return] = true,
	[Enum.KeyCode.KeypadEnter] = true,
	[Enum.KeyCode.ButtonA] = true,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if not state.open then
		return
	end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.Backspace or kc == Enum.KeyCode.ButtonB then
		if not processed then
			closeQuests()
		end
		return
	end
	if processed and input.UserInputType ~= Enum.UserInputType.Gamepad1 then
		return
	end
	if state.mode == "dialogue" then
		if state.options then
			local idx = NUM_KEYS[kc]
			if idx and idx <= #state.options then
				choiceEvent:Fire(idx)
			end
		elseif ADVANCE_KEYS[kc] and not (kc == Enum.KeyCode.ButtonA and processed) then
			if state.typing then
				state.skip = true
			else
				advanceEvent:Fire()
			end
		end
	elseif state.mode == "board" then
		local idx = NUM_KEYS[kc]
		local tierName = idx and Config.TierOrder[idx]
		if kc == Enum.KeyCode.ButtonL1 or kc == Enum.KeyCode.ButtonR1 then
			local at = table.find(Config.TierOrder, state.tier) or 1
			at = ((at - 1 + (if kc == Enum.KeyCode.ButtonR1 then 1 else -1)) % #Config.TierOrder) + 1
			tierName = Config.TierOrder[at]
		end
		if tierName and tierName ~= state.tier then
			Kit.sfx("Click")
			selectTier(tierName)
		end
	end
end)

---------------------------------------------------------------------------
-- live progress + "quest complete" toasts (through the HUD's toast system)
---------------------------------------------------------------------------
local Notify: BindableEvent? = nil
task.spawn(function()
	local n = UI:WaitForChild("Notify", 30)
	if n and n:IsA("BindableEvent") then
		Notify = n
	end
end)

QuestUpdated.OnClientEvent:Connect(function(updates: any, toasts: any)
	local touched = false
	if type(updates) == "table" then
		for _, u in ipairs(updates) do
			local b = type(u) == "table" and boards[u.Tier]
			if b then
				for _, q in ipairs(b.Quests) do
					if q.Id == u.Id then
						q.Progress = tonumber(u.Progress) or q.Progress
						if state.mode == "board" and state.tier == u.Tier then
							local c = cards[q.Id]
							if c then
								applyCard(c, q, true)
								touched = true
							end
						end
					end
				end
			end
		end
	end
	if touched then
		updateSummary(true)
	end
	refreshBadges()
	if type(toasts) == "table" then
		for _, t in ipairs(toasts) do
			if type(t) == "table" and t.Tier then
				if not boards[t.Tier] then
					task.spawn(fetchBoard, t.Tier)
				end
				local onBoard = state.open and state.mode == "board" and state.tier == t.Tier
				if not onBoard and Notify then
					local a, d = tierColors(t.Tier)
					Notify:Fire({
						Title = "QUEST COMPLETE!",
						Text = tostring(t.Title or "Quest") .. "  -  claim it at the crater",
						Icon = Theme.Icon.Check,
						Color = a,
						Deep = d,
						Sound = "Equip",
						Time = 3.4,
					})
				end
			end
		end
	end
end)

-- reset countdown, shines on claimable buttons, fresh boards after a reset
task.spawn(function()
	local n = 0
	while true do
		task.wait(1)
		n += 1
		if state.mode == "board" then
			updateReset()
			if n % 3 == 0 then
				for _, c in pairs(cards) do
					if c.Status == "ready" then
						Kit.playShine(c.ClaimBtn.Face:FindFirstChild("Shine") :: Frame)
					end
				end
				if claimAll.Enabled then
					Kit.playShine(claimAll.Face:FindFirstChild("Shine") :: Frame)
				end
			end
		end
		local now = workspace:GetServerTimeNow()
		for _, tierName in ipairs(Config.TierOrder) do
			local b = boards[tierName]
			if b and b.ResetAt and b.ResetAt <= now and not fetching[tierName] and (retryAt[tierName] or 0) <= os.clock() then
				retryAt[tierName] = os.clock() + 5
				task.spawn(function()
					local nb = fetchBoard(tierName)
					if nb and state.mode == "board" and state.tier == tierName then
						renderBoard(tierName, true)
					end
				end)
			end
		end
	end
end)

-- load every board once after joining so the badges on the sign and prompt are right
task.spawn(function()
	task.wait(2)
	for _ = 1, 6 do
		local missing = false
		for _, tierName in ipairs(Config.TierOrder) do
			if not boards[tierName] then
				missing = true
				task.spawn(fetchBoard, tierName)
			end
		end
		if not missing then
			break
		end
		task.wait(12)
	end
end)

---------------------------------------------------------------------------
-- QUESTS sign over the crater: tweened float, outline that stays readable at any distance,
-- and a gold "N REWARDS READY!" line when something can be claimed
---------------------------------------------------------------------------
task.spawn(function()
	local qw = workspace:WaitForChild("QuestWorld", 60)
	local anchor = qw and qw:WaitForChild("QuestTitleAnchor", 30)
	local bb = anchor and anchor:WaitForChild("QuestTitle", 30)
	if not (bb and bb:IsA("BillboardGui")) then
		return
	end
	questSign = bb
	local title = bb:WaitForChild("Title", 10)
	local sub = bb:WaitForChild("Sub", 10)
	if sub and sub:IsA("TextLabel") then
		sub.TextColor3 = C.Gold
		signSub = sub
	end
	bb.StudsOffset = Vector3.new(0, -0.4, 0)
	TweenService:Create(bb, TweenInfo.new(2.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { StudsOffset = Vector3.new(0, 0.4, 0) }):Play()
	local ts = title and title:FindFirstChildOfClass("UIStroke")
	local ss = sub and sub:FindFirstChildOfClass("UIStroke")
	local lastH = -1
	local function fit()
		local h = bb.AbsoluteSize.Y
		if math.abs(h - lastH) < 0.5 then
			return
		end
		lastH = h
		if ts then
			ts.Thickness = math.clamp(h * 0.035, 1.5, 7)
		end
		if ss then
			ss.Thickness = math.clamp(h * 0.022, 1, 4)
		end
	end
	bb:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	if state.open then
		bb.Enabled = false
	end
	refreshBadges()
end)

---------------------------------------------------------------------------
-- custom [E] QUESTS prompt in the Kit style
---------------------------------------------------------------------------
local promptGuis: { [ProximityPrompt]: any } = {}

ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if not prompt:GetAttribute("QuestPrompt") then
		return
	end
	questPrompt = prompt
	local old = promptGuis[prompt]
	if old then
		old.Wobble:Cancel()
		old.Gui:Destroy()
	end
	local keyText = prompt.KeyboardKeyCode.Name
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		keyText = "X"
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		keyText = "TAP"
	end
	local bb = new("BillboardGui", {
		Name = "QuestPromptUI",
		Adornee = prompt.Parent,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(340, 124),
		StudsOffset = Vector3.new(0, 1.5, 0),
		Active = true,
		ResetOnSpawn = false,
		Parent = playerGui,
	})
	local holder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(340, 124), Parent = bb })
	local sc = new("UIScale", { Scale = 0.2, Parent = holder })
	local pill = Kit.plate({
		Name = "Label",
		Parent = holder,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 66, 0.5, 4),
		Size = UDim2.fromOffset(262, 74),
		Radius = UDim.new(1, 0),
		Stroke = 5,
		ZIndex = 2,
		Gradient = { C.Navy700, C.Night },
	})
	Kit.bevel(pill, UDim.new(1, 0), 3, 2)
	Kit.text({ Text = "QUESTS", TextSize = 42, Position = UDim2.fromOffset(36, -2), Size = UDim2.new(1, -44, 1, 0), ZIndex = 3, Stroke = 4.5, Parent = pill })
	local keyBtn = Kit.button({
		Name = "Key",
		Parent = holder,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(96, 102),
		Radius = 26,
		Depth = 9,
		Stroke = 5,
		Color = rgb(250, 252, 255),
		Deep = rgb(166, 182, 214),
		Text = keyText,
		TextSize = if #keyText > 1 then 30 else 52,
		TextStroke = false,
		ZIndex = 5,
		HoverScale = 1.08,
		OnClick = function()
			prompt:InputHoldBegin()
			task.wait()
			prompt:InputHoldEnd()
		end,
	})
	if keyBtn.Label then
		keyBtn.Label.TextColor3 = C.Ink
	end
	keyBtn.Button.Rotation = -4
	local wobble = TweenService:Create(keyBtn.Button, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Rotation = 4 })
	wobble:Play()
	local b = badge(keyBtn.Body, 12, UDim2.new(1, -4, 0, 4))
	promptBadge = b
	b.Set(totalReady())
	local vcam = workspace.CurrentCamera
	local target = math.clamp((if vcam then vcam.ViewportSize.Y else 1080) / 1080, 0.6, 1.2) * 0.8
	tween(sc, 0.4, { Scale = target }, Enum.EasingStyle.Back)
	promptGuis[prompt] = { Gui = bb, Wobble = wobble, Scale = sc, Badge = b }
end)

ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
	local p = promptGuis[prompt]
	if not p then
		return
	end
	promptGuis[prompt] = nil
	if promptBadge == p.Badge then
		promptBadge = nil
	end
	tween(p.Scale, 0.15, { Scale = 0.2 }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(0.16, function()
		p.Wobble:Cancel()
		p.Gui:Destroy()
	end)
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who == player and prompt:GetAttribute("QuestPrompt") then
		questPrompt = prompt
		task.spawn(openQuests)
	end
end)

---------------------------------------------------------------------------
-- jumps count towards quests
---------------------------------------------------------------------------
local function hookCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10)
	if hum and hum:IsA("Humanoid") then
		hum.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				ClientReport:FireServer("Jump")
			end
		end)
	end
end
if player.Character then
	task.spawn(hookCharacter, player.Character)
end
player.CharacterAdded:Connect(hookCharacter)

---------------------------------------------------------------------------
-- fit to the screen (same numbers as the HUD, plus the Settings "UI size" slider)
---------------------------------------------------------------------------
local function layout()
	local c = workspace.CurrentCamera
	local vp = if c then c.ViewportSize else Vector2.new(1920, 1080)
	if vp.X < 2 or vp.Y < 2 then
		return
	end
	local s = math.min(vp.X / Theme.Reference.X, vp.Y / Theme.Reference.Y)
	if isTouch then
		s *= Theme.TouchBoost
	end
	s = math.clamp(s, Theme.MinScale, Theme.MaxScale) * math.clamp(tonumber(player:GetAttribute("OverkillUserScale")) or 1, 0.8, 1.2)
	ui.Scale = s
	ui.W, ui.H = vp.X / s, vp.Y / s
	rootScale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	-- dialogue: bottom-left on wide screens (the hero stands on the right), centred on narrow ones
	local compact = ui.W < 1180
	dlgW = if compact then math.floor(math.min(820, ui.W - 40)) else 820
	dlg.AnchorPoint = if compact then Vector2.new(0.5, 1) else Vector2.new(0, 1)
	dlgHome = if compact then UDim2.new(0.5, 0, 1, -44) else UDim2.new(0, 96, 1, -110)
	dlg.Size = UDim2.fromOffset(dlgW, dlg.Size.Y.Offset)
	if dlg.Visible then
		dlg.Position = dlgHome
	end
	-- board: shrink on short screens (the title plate sticks out above the window)
	boardFit.Scale = math.min(1, (ui.H - 24) / (BH + 96), (ui.W - 24) / (BW + 24))
end

local camConn: RBXScriptConnection? = nil
local function hookCamera()
	if camConn then
		camConn:Disconnect()
	end
	local c = workspace.CurrentCamera
	if c then
		camConn = c:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	layout()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
player:GetAttributeChangedSignal("OverkillUserScale"):Connect(layout)
hookCamera()
applySpeaker(Config.QuestGiver)
