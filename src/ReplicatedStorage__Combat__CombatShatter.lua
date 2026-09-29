--[[
	CombatShatter  (ReplicatedStorage.Combat.CombatShatter)
	The Ground Smash's look, start to finish - FLAT, 2D, on the floor. Client-side and cosmetic
	only: every client builds its own copy when it hears about a smash (the smasher from its own
	touchdown frame).

	  Shatter.Descent(char, height)   the drop: the pack's speed lines (VFX SpeedLines) rushing up
	                                  past the falling body. Returns { Stop }.
	  Shatter.Play(ground, attacker)  the touchdown
	  Shatter.Preview(ground)         the crack standing still (Studio inspection)

	THE SEQUENCE (seconds after touchdown) - nothing raised, nothing thrown, no extra impact layers:
	  0.00  THE CRACK   one 2D ground crack (the pack's GroundCrack1 sheet, its first crisp frame -
	        -0.30       never the crumbling frames after it) laid flat on the floor, spreading out
	                    from the foot to the smash's gameplay radius (Config.Attacks.Downslam
	                    .StompRadius), then held
	  0.05  DUST        dust bursts out from the foot along the ground (GroundDust, DustBurst's
	        -1.2        cloud) and puffs up in rings as the crack front reaches them (DustPuff) -
	                    tinted a little lighter than the floor, so it reads as dust, never as more
	                    floor laid over the crack
	  2.60  FADE        the crack melts away
	A new smash on top of an old one fades the old crack at once.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local VFX = require(CombatFolder:WaitForChild("CombatVFX"))

local Shatter = {}

local STOMP = Config.Attacks.Downslam
local R: number = STOMP.StompRadius -- the gameplay radius: the crack reaches exactly this far
local SPREAD = 0.3 -- seconds: the crack runs out from the foot to the rim
local CRACK_SPEED = R / SPREAD -- (studs/s: the dust rings puff as the front reaches them)
local HOLD = 2.6 -- seconds after touchdown the fade begins
local FADE = 0.7
local VIEW = 220 -- farther than this from the camera, nothing is built
local EARTH = Color3.fromRGB(98, 79, 62)

---------------------------------------------------------------------------
-- holders, filters, the ground
---------------------------------------------------------------------------
local folder: Folder? = nil
local function holder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatShatter"
	f.Parent = workspace
	folder = f
	return f
end

-- every body the floor test must see through: the players, the practice dummies, any other
-- character near the smash
local function fighters(center: Vector3?): { Model }
	local list = {}
	local seen: { [Model]: boolean } = {}
	local function add(m: Model)
		if not seen[m] then
			seen[m] = true
			table.insert(list, m)
		end
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			add(pl.Character)
		end
	end
	local dummies = workspace:FindFirstChild("PracticeDummies")
	if dummies then
		for _, m in ipairs(dummies:GetChildren()) do
			if m:IsA("Model") then
				add(m)
			end
		end
	end
	if center then
		local ok, parts = pcall(function()
			return workspace:GetPartBoundsInRadius(center, R + 6)
		end)
		if ok and parts then
			for _, p in ipairs(parts) do
				local m = p:FindFirstAncestorOfClass("Model")
				while m and not m:FindFirstChildOfClass("Humanoid") do
					m = m:FindFirstAncestorOfClass("Model")
				end
				if m then
					add(m)
				end
			end
		end
	end
	return list
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
rayParams.RespectCanCollide = true -- bushes, flowers and effects are not ground

local function setIgnore(center: Vector3?)
	local ignore: { Instance } = { holder() }
	for _, m in ipairs(fighters(center)) do
		table.insert(ignore, m)
	end
	for _, name in ipairs({ "CombatFX", "CombatBlood", "CombatGore", "CombatDebugDraw" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(ignore, f)
		end
	end
	rayParams.FilterDescendantsInstances = ignore
end

-- the floor right under a spot, if it is floor near `refY` (not a ledge far below, not the top of
-- a wall, not a steep face)
local function floorAt(p: Vector3, refY: number, tol: number?): RaycastResult?
	local t = tol or 1.2
	local hit = workspace:Raycast(Vector3.new(p.X, refY + t + 1.5, p.Z), Vector3.new(0, -(t * 2 + 3), 0), rayParams)
	if not hit or hit.Normal.Y < 0.55 or math.abs(hit.Position.Y - refY) > t then
		return nil
	end
	return hit
end

-- the floor's colour there (the dust takes it, lightened)
local function colourOf(hit: RaycastResult): Color3
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		local ok, c = pcall(function()
			return (inst :: Terrain):GetMaterialColor(hit.Material)
		end)
		return if ok then c else EARTH
	elseif inst:IsA("BasePart") then
		return inst.Color
	end
	return EARTH
end

local function frameAlong(pos: Vector3, dir: Vector3): CFrame
	local up = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
	local right = up:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	return CFrame.fromMatrix(pos, right, up, right:Cross(up).Unit)
end

local function tint(color: Color3, lighten: number): ColorSequence
	local c = color:Lerp(Color3.fromRGB(205, 196, 180), lighten)
	return ColorSequence.new(c, c:Lerp(Color3.fromRGB(170, 164, 152), 0.3))
end

---------------------------------------------------------------------------
-- THE crack: the pack's crack (VFX GroundCrack1) is a 4 x 4 flipbook sheet that crumbles as it
-- plays - whole in its first frame, then breaking up into a blotchy second pattern. Played as a
-- particle, a smash showed two cracks one after the other. Here its first frame alone is laid flat
-- on the floor (the floor's own shading) and spreads out from the foot. Returns { Fade(seconds),
-- Kill() } (nil: no crack sheet in the place)
---------------------------------------------------------------------------
local CRACK_TILE = Vector2.new(256, 256) -- (one frame of the 1024 px sheet)
local crackImage: string? = nil
local function crackSheet(): string?
	if crackImage == nil then
		crackImage = ""
		local lib = CombatFolder:FindFirstChild("VFX")
		local tpl = lib and lib:FindFirstChild("GroundCrack1")
		local e = tpl and tpl:FindFirstChildWhichIsA("ParticleEmitter")
		if e and e.Texture ~= "" then
			crackImage = e.Texture
		end
	end
	return if crackImage ~= "" then crackImage else nil
end

-- (the sheet is loaded before the first smash: the first crack of a session never shows up late)
task.defer(function()
	local image = crackSheet()
	if image then
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync({ image })
		end)
	end
end)

local function crackDecal(ground: CFrame, diameter: number, spin: number, still: boolean?): any
	local image = crackSheet()
	if not image then
		return nil
	end
	local p = Instance.new("Part")
	p.Name = "Crack"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(diameter, 0.05, diameter)
	p.CFrame = ground * CFrame.Angles(0, spin, 0)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 1
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.Adornee = p
	gui.Parent = p
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = if still then UDim2.fromScale(1, 1) else UDim2.fromScale(0.12, 0.12)
	label.Image = image
	label.ImageRectOffset = Vector2.zero
	label.ImageRectSize = CRACK_TILE
	label.ImageColor3 = Color3.new(0, 0, 0)
	label.ImageTransparency = if still then 0 else 0.3
	label.Parent = gui
	p.Parent = holder()
	if not still then
		-- it bursts out from the foot and slows as it reaches the rim (the break losing its force)
		TweenService:Create(label, TweenInfo.new(SPREAD, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
		TweenService:Create(label, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 0 }):Play()
	end
	local gone = false
	local function kill()
		if not gone then
			gone = true
			p:Destroy()
		end
	end
	local function fade(seconds: number)
		if gone then
			return
		end
		TweenService:Create(label, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { ImageTransparency = 1 }):Play()
		task.delay(seconds + 0.05, kill)
	end
	if not still then
		task.delay(HOLD + FADE + 1, kill) -- (never outlives its smash, whatever happens to it)
	end
	return { Fade = fade, Kill = kill }
end

-- where the crack lies: on its own plane just clear of the highest floor under it (one flat sheet
-- over a bump or a gentle slope would be buried in part), never floating visibly above it
local function crackFrame(center: Vector3, nrm: Vector3): CFrame
	local lift = 0.06
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		for _, k in ipairs({ 0.5, 0.95 }) do
			local g = floorAt(center + Vector3.new(math.cos(a), 0, math.sin(a)) * (R * k), center.Y, 0.8)
			if g then
				lift = math.max(lift, (g.Position - center):Dot(nrm) + 0.04)
			end
		end
	end
	return frameAlong(center + nrm * math.min(lift, 0.35), nrm)
end

---------------------------------------------------------------------------
-- live smashes (a new one fades any old crack it would overlap)
---------------------------------------------------------------------------
type Live = { Center: Vector3, Crack: any }
local live: { Live } = {}

local function clearNear(center: Vector3)
	for i = #live, 1, -1 do
		local l = live[i]
		if (l.Center - center).Magnitude < R * 2.2 then
			table.remove(live, i)
			if l.Crack then
				l.Crack.Fade(0.12)
			end
		end
	end
end

---------------------------------------------------------------------------
-- the touchdown
---------------------------------------------------------------------------
function Shatter.Play(pos: Vector3, _attacker: Model?)
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - pos).Magnitude > VIEW then
		return
	end
	setIgnore(pos)
	local ground = floorAt(pos, pos.Y, 3)
	if not ground or ground.Material == Enum.Material.Water then
		return -- (water doesn't crack)
	end
	clearNear(ground.Position)
	local rng = Random.new()
	local center = ground.Position
	local nrm = ground.Normal
	local groundFrame = frameAlong(center + nrm * 0.05, nrm)
	local fx = R / 7.2 -- (the dust's sizes below are for the default radius)

	-- THE CRACK
	local crack = crackDecal(crackFrame(center, nrm), 2 * R, rng:NextNumber(0, math.pi * 2))

	-- THE DUST: rolling out along the ground from the foot, its cloud thrown out after it, puffs
	-- round the rim as the crack front reaches them (one sprite each, never drawn over the crack)
	local dust = tint(colourOf(ground), 0.7)
	task.delay(0.05, function()
		VFX.Play("GroundDust", groundFrame, { Scale = 0.7 * fx, Color = dust, ZOffset = 0 })
		VFX.Play("DustBurst", groundFrame, { Scale = 1.5 * fx, Color = dust, Only = { Smoke2 = true }, ZOffset = 0 })
	end)
	local spin = rng:NextNumber(0, math.pi * 2)
	for ring = 1, 3 do
		local r = R * (0.5 + 0.25 * ring) -- 0.75R, R, 1.25R: round the rim, never over the crack's heart
		local n = 4 + ring * 2
		task.delay(math.max(0, r / CRACK_SPEED - 0.1), function()
			for i = 1, n do
				local ang = spin + ring * 0.5 + i / n * math.pi * 2
				local g = floorAt(center + Vector3.new(math.cos(ang), 0, math.sin(ang)) * r, center.Y, 1.5)
				if g and g.Material ~= Enum.Material.Water then
					VFX.Play("DustPuff", CFrame.new(g.Position + g.Normal * 0.9), { Scale = (0.6 + 0.1 * ring) * fx, Count = 0.1, Color = dust, ZOffset = 0 })
				end
			end
		end)
	end

	-- HOLD, then the crack melts away
	local entry: Live = { Center = center, Crack = crack }
	table.insert(live, entry)
	task.delay(HOLD, function()
		local i = table.find(live, entry)
		if i then
			table.remove(live, i)
			if crack then
				crack.Fade(FADE)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- the drop
---------------------------------------------------------------------------
function Shatter.Descent(char: Model, _height: number?): any
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return { Stop = function() end }
	end
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - root.Position).Magnitude > VIEW then
		return { Stop = function() end }
	end
	-- the pack's speed lines (VFX SpeedLines) streaming up past the falling body
	local lines = VFX.Attach("SpeedLines", root, CFrame.new(0, -0.5, 0))
	local stopped = false
	local function stop()
		if stopped then
			return
		end
		stopped = true
		lines.Stop()
	end
	task.delay(2, stop) -- never outlives a fall
	return { Stop = stop }
end

-- the crack standing still, for looking at in Studio (the last preview's goes first)
local preview: any = nil
function Shatter.Preview(ground: Vector3, _parent: Instance?, seed: number?): number
	if preview then
		preview.Kill()
		preview = nil
	end
	setIgnore(ground)
	local hit = floorAt(ground, ground.Y, 3)
	if not hit then
		return 0
	end
	preview = crackDecal(crackFrame(hit.Position, hit.Normal), 2 * R, Random.new(seed or 1):NextNumber(0, math.pi * 2), true)
	return if preview then 1 else 0
end

return Shatter
