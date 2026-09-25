--[[
	HeroSelect  (StarterPlayerScripts.OverkillHUD.HeroSelect)
	The character select screen. Your pick is worn by your real R6 character (HeroServer), so the
	moment you lock one in you are that hero in the world.

	Screen (same dress as the windows and the aura preview):
	  CHOOSE YOUR HERO title plate, roster (left), details + moveset + select (right), hint bar
	  (bottom), and the hero itself standing on the floating island stage between the panels,
	  in their signature stance (OverkillUI.HeroPoses, posed with plain CFrames: no animation
	  assets to upload).
	Also owns the HERO pill in the HUD corner (portrait + CHANGE) and the morph flash other
	players see when someone transforms.

	Opens by itself on your first visit (until you have a hero), or with ctx.Fire("HeroSelect").
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local Debris = game:GetService("Debris")

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = Players.LocalPlayer
	local isTouch = ctx.IsTouch

	local UI = ReplicatedStorage:WaitForChild("OverkillUI")
	local HeroConfig = require(UI:WaitForChild("HeroConfig"))
	local HeroPoses = require(UI:WaitForChild("HeroPoses"))
	local HeroModels = UI:WaitForChild("Heroes")
	local Remotes = UI:WaitForChild("Remotes")
	local HeroRequest = Remotes:WaitForChild("HeroRequest") :: RemoteFunction
	local HeroEvent = Remotes:WaitForChild("HeroEvent") :: RemoteEvent

	local HEROES: { any } = {}
	for _, id in ipairs(HeroConfig.Order) do
		local h = HeroConfig.Heroes[id]
		if h and HeroModels:FindFirstChild(id) and HeroPoses[id] then
			table.insert(HEROES, h)
		end
	end
	if #HEROES == 0 then
		return
	end
	local function heroById(id: any): any
		return if type(id) == "string" then HeroConfig.Heroes[id] else nil
	end
	local function accentOf(h: any): (Color3, Color3)
		local a = h and h.Accent
		if a then
			return a[1], a[2]
		end
		return C.Gold, C.GoldDeep
	end
	local function currentHeroId(): string
		local v = player:GetAttribute("Hero")
		return if type(v) == "string" then v else ""
	end

	---------------------------------------------------------------------------
	-- posed rigs: a still copy of a hero, every part anchored and placed with plain CFrames
	-- (joints removed; hair and collars remember where their weld held them)
	---------------------------------------------------------------------------
	local PARTS = { "Torso", "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg" }
	local IS_BODY: { [string]: boolean } = { HumanoidRootPart = true }
	for _, n in ipairs(PARTS) do
		IS_BODY[n] = true
	end
	local STRIP = {
		Script = true, LocalScript = true, ModuleScript = true, Sound = true, ParticleEmitter = true, Beam = true,
		Trail = true, Fire = true, Smoke = true, Sparkles = true, PointLight = true, SpotLight = true, SurfaceLight = true,
		BillboardGui = true, Highlight = true, ProximityPrompt = true,
	}
	local FEET_BELOW_ROOT = 3 -- an R6 root sits 3 studs above the soles

	type Rig = { Id: string, Model: Model, Root: BasePart, Parts: { [string]: BasePart }, Extras: { any }, List: { BasePart } }

	local function buildRig(id: string): Rig?
		local src = HeroModels:FindFirstChild(id)
		if not src then
			return nil
		end
		local model = src:Clone() :: Model
		model.Name = "HeroRig_" .. id
		local extras = {}
		local held: { [Instance]: boolean } = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("JointInstance") and d.Part0 and d.Part1 and not IS_BODY[d.Part1.Name] then
				table.insert(extras, { Part = d.Part1, Host = d.Part0.Name, Offset = d.C0 * d.C1:Inverse() })
				held[d.Part1] = true
			end
		end
		for _, p in ipairs(model:GetChildren()) do
			if p:IsA("BasePart") and not IS_BODY[p.Name] and not held[p] then
				local hostName = if string.find(string.lower(p.Name), "hair") then "Head" else "Torso"
				local host = model:FindFirstChild(hostName)
				if host and host:IsA("BasePart") then
					table.insert(extras, { Part = p, Host = hostName, Offset = host.CFrame:ToObjectSpace(p.CFrame) })
				end
			end
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("JointInstance") or d:IsA("WeldConstraint") or STRIP[d.ClassName] then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			hum.BreakJointsOnDeath = false
			pcall(function()
				hum.RequiresNeck = false
				hum.EvaluateStateMachine = false -- a mannequin: no falling, no dying
			end)
		end
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
		if not root then
			model:Destroy()
			return nil
		end
		root.Transparency = 1
		model.PrimaryPart = root
		local parts = {}
		local list = { root }
		for _, n in ipairs(PARTS) do
			local p = model:FindFirstChild(n)
			if p and p:IsA("BasePart") then
				parts[n] = p
				table.insert(list, p)
			end
		end
		for _, e in ipairs(extras) do
			table.insert(list, e.Part)
		end
		return { Id = id, Model = model, Root = root, Parts = parts, Extras = extras, List = list }
	end

	local function blend(a: any, b: any, t: number): any
		local out = {}
		for _, n in ipairs(PARTS) do
			local ca, cb = a[n], b[n]
			out[n] = if ca and cb then ca:Lerp(cb, t) else (ca or cb)
		end
		return out
	end

	local cfs: { CFrame } = {}
	local function applyPose(rig: Rig, rootCf: CFrame, pose: any)
		local P = rig.Parts
		local torsoCf = rootCf * pose.Torso
		local at: { [string]: CFrame } = { HumanoidRootPart = rootCf, Torso = torsoCf }
		for _, n in ipairs(PARTS) do
			if n ~= "Torso" then
				at[n] = torsoCf * pose[n]
			end
		end
		table.clear(cfs)
		table.insert(cfs, rootCf)
		for _, n in ipairs(PARTS) do
			if P[n] then
				table.insert(cfs, at[n])
			end
		end
		for _, e in ipairs(rig.Extras) do
			table.insert(cfs, (at[e.Host] or rootCf) * e.Offset)
		end
		workspace:BulkMoveTo(rig.List, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- a still portrait: the hero in their stance inside a ViewportFrame, framed on the face
	local function portrait(parent: GuiObject, id: string, framing: string, z: number): ViewportFrame?
		local rig = buildRig(id)
		local poses = HeroPoses[id]
		if not (rig and poses) then
			return nil
		end
		local vp = new("ViewportFrame", {
			Name = "Portrait",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Ambient = Color3.fromRGB(150, 150, 164),
			LightColor = Color3.fromRGB(255, 246, 232),
			ZIndex = z,
			Parent = parent,
		})
		-- turned a little toward the key light
		local rootCf = CFrame.new(0, FEET_BELOW_ROOT, 0) * CFrame.Angles(0, math.pi - 0.28, 0)
		for _, d in ipairs(rig.List) do
			d.Anchored = true
		end
		rig.Model.Parent = vp
		-- plain CFrames (BulkMoveTo only works in the workspace)
		local pose = poses.Stance
		local torsoCf = rootCf * pose.Torso
		rig.Root.CFrame = rootCf
		local at: { [string]: CFrame } = { HumanoidRootPart = rootCf, Torso = torsoCf }
		for _, n in ipairs(PARTS) do
			local p = rig.Parts[n]
			local cf = if n == "Torso" then torsoCf else torsoCf * pose[n]
			at[n] = cf
			if p then
				p.CFrame = cf
			end
		end
		for _, e in ipairs(rig.Extras) do
			e.Part.CFrame = (at[e.Host] or rootCf) * e.Offset
		end
		local head = rig.Parts.Head
		local look = head.CFrame.LookVector
		look = Vector3.new(look.X, 0, look.Z)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, 1)
		local fov = 30
		local span, drop = 3.5, 0.55
		if framing == "face" then
			span, drop = 2.35, 0.05
		end
		local target = head.Position - Vector3.new(0, drop, 0)
		local dist = (span * 0.5) / math.tan(math.rad(fov / 2))
		local dir = (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(-10)) * look).Unit
		local cam = new("Camera", { FieldOfView = fov, Parent = vp })
		cam.CFrame = CFrame.lookAt(target + dir * dist + Vector3.new(0, 0.35, 0), target)
		vp.CurrentCamera = cam
		local f = cam.CFrame
		vp.LightDirection = (f.LookVector + f.RightVector * 0.8 - Vector3.yAxis * 0.8).Unit
		return vp
	end

	---------------------------------------------------------------------------
	-- the stage: a crater arena on its own floating island (OverkillUI.HeroStage) - stone podium
	-- with an inlaid ring and two stone pillars crowned with gems, in the hero's colours
	---------------------------------------------------------------------------
	local ORIGIN = Vector3.new(0, 2100, 0)
	local stageSrc = UI:WaitForChild("HeroStage", 10)
	local feetValue = stageSrc and stageSrc:FindFirstChild("FeetY")
	local FEET = if feetValue and feetValue:IsA("NumberValue") then feetValue.Value else 1.3
	local stage: Model? = nil
	local tinted: { { Part: BasePart, Kind: string } } = {}
	local orbFx: { { Emitter: ParticleEmitter, Base: ColorSequence } } = {}
	local orbLights: { PointLight } = {}
	local fxFolder: Folder? = nil

	local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
		local e = Instance.new("ParticleEmitter")
		for k, v in pairs(props) do
			(e :: any)[k] = v
		end
		e.Parent = parent
		return e
	end

	local function getStage(): Model?
		if not stage and stageSrc then
			local m = stageSrc:Clone() :: Model
			m.Name = "OverkillHeroStage"
			m:PivotTo(CFrame.new(ORIGIN))
			for _, d in ipairs(m:GetDescendants()) do
				if d:IsA("BasePart") and d.Name == "AccentRing" then
					table.insert(tinted, { Part = d, Kind = d.Name })
				elseif d:IsA("ParticleEmitter") and d:FindFirstAncestor("Orb") then
					table.insert(orbFx, { Emitter = d, Base = d.Color })
				elseif d:IsA("PointLight") and d:FindFirstAncestor("Orb") then
					table.insert(orbLights, d)
				end
			end
			local folder = Instance.new("Folder")
			folder.Name = "FX"
			folder.Parent = m
			fxFolder = folder
			stage = m
		end
		return stage
	end

	-- a colour sequence moved onto the hero's hue: every shade keeps its own brightness and
	-- strength, whites stay white (so the orb keeps all the depth of the original ball)
	local function onHue(cs: ColorSequence, a: Color3): ColorSequence
		local ah, asat = a:ToHSV()
		local kps = {}
		for _, kp in ipairs(cs.Keypoints) do
			local _, sat, val = kp.Value:ToHSV()
			local c = kp.Value
			if sat > 0.08 then
				c = Color3.fromHSV(ah, math.clamp(sat * 0.6 + asat * 0.4, 0, 1), val)
			end
			table.insert(kps, ColorSequenceKeypoint.new(kp.Time, c))
		end
		return ColorSequence.new(kps)
	end

	-- the podium ring and the two orbs take the hero's colours
	local function tintStage(h: any)
		local a = h and h.Accent and h.Accent[1] or C.Gold
		for _, t in ipairs(tinted) do
			tween(t.Part, 0.35, { Color = a }, Enum.EasingStyle.Quad)
		end
		for _, o in ipairs(orbFx) do
			o.Emitter.Color = onHue(o.Base, a)
		end
		for _, l in ipairs(orbLights) do
			l.Color = a
		end
	end

	---------------------------------------------------------------------------
	-- stage effects: flat rings on the podium, a sunburst behind the hero and a burst of stars,
	-- drawn with the HUD's own shapes (SurfaceGuis / a BillboardGui), so they look like the UI
	---------------------------------------------------------------------------
	local RAYS_Z = -9.6 -- the sunburst stands behind the pillars and the flowers, never in front of them

	local function fxPart(name: string, cf: CFrame, size: Vector3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		p.Size = size
		p.CFrame = cf
		p.Parent = fxFolder or workspace
		return p
	end

	-- rings spreading across the podium top (big = the lock-in, small = a hero landing)
	local function ringWave(h: any, big: boolean)
		local a = accentOf(h)
		local topCf = CFrame.new(ORIGIN + Vector3.new(0, FEET + 0.03, 0)) * CFrame.Angles(math.pi / 2, 0, 0) -- front face up
		local span = if big then 7 else 6 -- never wider than the podium top (a ring off the edge would float)
		local p = fxPart("RingWave", topCf, Vector3.new(span, span, 0.05))
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Front
		sg.LightInfluence = 0
		sg.Brightness = 1.4
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 40
		sg.Parent = p
		local rings = if big then { { 0, a, 10 }, { 0.09, Color3.new(1, 1, 1), 6 }, { 0.2, Kit.lighten(a, 0.3), 4 } } else { { 0, a, 7 } }
		for _, r in ipairs(rings) do
			local delay, col, thick = r[1], r[2], r[3]
			local ring = new("Frame", {
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(if big then 0.14 else 0.3, if big then 0.14 else 0.3),
				Parent = sg,
			})
			Kit.pill(ring)
			local st = new("UIStroke", { Color = col, Thickness = thick * 4, Transparency = 0, Parent = ring })
			new("UIAspectRatioConstraint", { Parent = ring })
			local t = if big then 0.9 else 0.6
			tween(ring, t, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, delay)
			tween(st, t, { Transparency = 1, Thickness = thick }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, delay)
		end
		Debris:AddItem(p, 1.4)
	end

	-- a slow sunburst (the shop cards' rays) standing behind the hero
	local function sunburst(h: any): () -> ()
		local a = accentOf(h)
		local cf = CFrame.new(ORIGIN + Vector3.new(0, FEET + 3.6, RAYS_Z))
		local p = fxPart("Sunburst", cf, Vector3.new(16, 16, 0.05))
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Back -- faces the camera (+Z)
		sg.LightInfluence = 0
		sg.Brightness = 1.2
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 32
		sg.Parent = p
		local glow = Kit.image({ Image = Theme.Icon.Glow, ImageColor3 = a, ImageTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.2, 0.2), Parent = sg })
		local rays = Kit.image({ Image = Theme.Icon.Rays, ImageColor3 = Kit.lighten(a, 0.35), ImageTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.2, 0.2), Parent = sg })
		tween(glow, 0.45, { ImageTransparency = 0.55, Size = UDim2.fromScale(0.8, 0.8) }, Enum.EasingStyle.Quart)
		tween(rays, 0.55, { ImageTransparency = 0.35, Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Back)
		local spin = game:GetService("TweenService"):Create(rays, TweenInfo.new(8, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 })
		spin:Play()
		return function()
			tween(glow, 0.4, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
			tween(rays, 0.4, { ImageTransparency = 1, Size = UDim2.fromScale(1.15, 1.15) }, Enum.EasingStyle.Quad)
			task.delay(0.45, function()
				spin:Cancel()
				p:Destroy()
			end)
		end
	end

	-- stars bursting out around the hero: staggered, each on its own path, spinning down to nothing
	local function starBurst(h: any)
		local a, d = accentOf(h)
		local cf = CFrame.new(ORIGIN + Vector3.new(0, FEET + 3.4, 0.6))
		local p = fxPart("Stars", cf, Vector3.new(1, 1, 1))
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromScale(14, 14) -- studs: the burst keeps its size on any screen
		bb.LightInfluence = 0
		bb.AlwaysOnTop = false
		bb.ResetOnSpawn = false
		bb.Parent = p
		local N = 12
		local cols = { Color3.new(1, 1, 1), C.Gold, Kit.lighten(a, 0.2) }
		for i = 1, N do
			local ang = (i - 1) / N * math.pi * 2 + math.rad(15) * ((i % 2) * 2 - 1) * 0.3
			local dist = if i % 2 == 0 then 0.36 else 0.29
			local size = if i % 3 == 0 then 0.066 else 0.05
			local star = Kit.image({
				Image = Theme.Icon.Star,
				ImageColor3 = cols[(i % #cols) + 1],
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.006, 0.006),
				Rotation = math.random(-30, 30),
				Parent = bb,
			})
			local delay = (i % 4) * 0.025
			local to = UDim2.fromScale(0.5 + math.cos(ang) * dist, 0.5 + math.sin(ang) * dist * 0.85)
			tween(star, 0.22, { Size = UDim2.fromScale(size, size) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, delay)
			tween(star, 0.75, { Position = to, Rotation = star.Rotation + (if i % 2 == 0 then 160 else -160) }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, delay)
			tween(star, 0.35, { Size = UDim2.fromScale(0, 0), ImageTransparency = 0.4 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, delay + 0.55)
		end
		-- the burst's own flash: a soft glow that blooms and fades
		local glow = Kit.image({ Image = Theme.Icon.Glow, ImageColor3 = Kit.lighten(a, 0.5), ImageTransparency = 0.1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.08, 0.08), Parent = bb })
		tween(glow, 0.5, { Size = UDim2.fromScale(0.75, 0.75), ImageTransparency = 1 }, Enum.EasingStyle.Quart)
		local _ = d
		Debris:AddItem(p, 1.6)
	end

	---------------------------------------------------------------------------
	-- screen
	---------------------------------------------------------------------------
	local gui = new("ScreenGui", {
		Name = "OverkillHeroSelect",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 58,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
	local rootScale = new("UIScale", { Name = "Fit", Parent = root })

	-- layout (reference pixels, 1920 x 1080 and wider/taller)
	local SIDE = 40
	local LIST_W, INFO_W = 440, 480
	local ROW_H, ROW_GAP = 128, 14
	local LIST_H = 86 + #HEROES * (ROW_H + ROW_GAP) + 12
	local MOVE_H, MOVE_GAP = 78, 8
	local TABS_Y = 196 -- MOVESET / LORE switch
	local MOVES_Y = TABS_Y + 40 + 12
	local CONTENT_H = 4 * MOVE_H + 3 * MOVE_GAP -- the moves, or the lore card, fill exactly this
	local INFO_H = 86 + MOVES_Y + CONTENT_H + 16 + 82 + 24
	local HEAD_Y = 58
	local HINT_H = 58
	local MID_MIN = 380 -- the hero needs at least this much room between the panels

	local function topInset(): number
		local inset = 0
		pcall(function()
			inset = GuiService.TopbarInset.Height
		end)
		if inset <= 0 then
			inset = GuiService:GetGuiInset().Y
		end
		return inset
	end

	local grab = new("TextButton", {
		Name = "Grab",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Modal = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = root,
	})
	local fadeGui = new("ScreenGui", {
		Name = "OverkillHeroSelectFade",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 59,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local fade = new("Frame", { Name = "Fade", BackgroundColor3 = C.Night, BorderSizePixel = 0, BackgroundTransparency = 1, Visible = false, Size = UDim2.fromScale(1, 1), Parent = fadeGui })
	local fadeSerial = 0
	local function fadeTo(alpha: number, t: number): Tween
		fadeSerial += 1
		local me = fadeSerial
		fade.Visible = true
		local tw = tween(fade, t, { BackgroundTransparency = alpha }, Enum.EasingStyle.Quad)
		if alpha >= 1 then
			tw.Completed:Connect(function()
				if me == fadeSerial then
					fade.Visible = false
				end
			end)
		end
		return tw
	end

	-- panels in the windows' dress; the header band takes the hero's colours
	local bands: { UIGradient } = {}
	local function panel(name: string, w: number, h: number, title: string, icon: (Frame) -> ())
		local holder = new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromOffset(w, h), ZIndex = 10, Parent = root })
		local scale = Kit.fx(holder)
		local shadow = new("Frame", { Name = "Shadow", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.45, Position = UDim2.fromOffset(0, 12), Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = holder })
		Kit.corner(shadow, 32)
		local body = new("Frame", { Name = "Body", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = holder })
		Kit.corner(body, 32)
		Kit.stroke(body, 8, C.Ink, 0, true)
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, C.Navy700),
				ColorSequenceKeypoint.new(0.45, C.Navy800),
				ColorSequenceKeypoint.new(1, C.Navy900),
			}),
			Parent = body,
		})
		local skin = new("CanvasGroup", { Name = "Skin", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = body })
		Kit.corner(skin, 32)
		Kit.stripes(skin, C.Rim, 0.955, 10)
		local band = new("Frame", { Name = "Band", BackgroundColor3 = C.Gold, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 96), ZIndex = 10, Parent = skin })
		local bandGrad = Kit.gradient(band, C.Gold, C.GoldDeep, 90, 0.74, 1)
		table.insert(bands, bandGrad)
		local vignette = new("Frame", { Name = "Vignette", BackgroundColor3 = C.Night, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.35, 0), ZIndex = 10, Parent = skin })
		Kit.gradient(vignette, C.Night, C.Night, 90, 1, 0.3)
		-- heading icon: as far in from the panel's left edge as from its top edge
		local iconHolder = new("Frame", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(22, 42), Size = UDim2.fromOffset(40, 40), ZIndex = 12, Parent = holder })
		icon(iconHolder)
		Kit.text({ Name = "Title", Text = title, TextSize = 30, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(72, 42), Size = UDim2.new(1, -94, 0, 36), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 3.5, Parent = holder })
		local line = new("Frame", { Name = "Line", BackgroundColor3 = C.Rim, BackgroundTransparency = 0.72, BorderSizePixel = 0, Position = UDim2.fromOffset(22, 76), Size = UDim2.new(1, -44, 0, 3), ZIndex = 11, Parent = holder })
		Kit.pill(line)
		local content = new("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 86), Size = UDim2.new(1, 0, 1, -86), ZIndex = 11, Parent = holder })
		return { Root = holder, Scale = scale, Content = content }
	end

	local function chip(parent: Instance, text: string, a: Color3, b: Color3, h: number, size: number, z: number)
		local p = Kit.plate({
			Name = "Chip",
			Parent = parent,
			Size = UDim2.new(0, 0, 0, h),
			AutomaticSize = Enum.AutomaticSize.X,
			Radius = UDim.new(1, 0),
			Stroke = 2.5,
			ZIndex = z,
			Gradient = { a, b },
		})
		Kit.padding(p, 11, 0, 11, 0)
		local label = Kit.text({ Text = text, TextSize = size, FontFace = Theme.Font.Heavy, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z + 1, Stroke = 2.2, Parent = p })
		return p, label
	end

	local function keycap(parent: Instance, text: string, w: number, h: number, textSize: number, z: number): (Frame, TextLabel, UIGradient)
		local k = new("Frame", { Name = "Key", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(w, h), ZIndex = z, Parent = parent })
		Kit.corner(k, math.floor(h * 0.3))
		Kit.stroke(k, 3, C.Ink, 0, true)
		local g = Kit.gradient(k, Color3.new(1, 1, 1), Color3.fromRGB(222, 230, 244), 90)
		local l = Kit.text({ Text = text, TextSize = textSize, FontFace = Theme.Font.Heavy, TextColor3 = C.Ink, Size = UDim2.fromScale(1, 1), ZIndex = z + 1, Stroke = false, Parent = k })
		return k, l, g
	end

	-- a fighter glyph: head and shoulders, white with an ink outline
	local function fistGlyph(parent: GuiObject, size: number, z: number)
		-- the figure runs from the top of the head to the bottom of the shoulders: that span (not
		-- the box around it) is what sits dead centre in the parent
		local headTop, bodyBottom = math.floor(size * 0.04), size - math.floor(size * 0.02)
		local shift = size / 2 - (headTop + bodyBottom) / 2
		local holder = new("Frame", { Name = "Fighter", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, shift), Size = UDim2.fromOffset(size, size), ZIndex = z, Parent = parent })
		local stroke = math.max(2.5, size * 0.07)
		local body = new("Frame", {
			Name = "Shoulders",
			BackgroundColor3 = Color3.new(1, 1, 1),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, bodyBottom),
			Size = UDim2.fromOffset(math.floor(size * 0.84), math.floor(size * 0.42)),
			ZIndex = z,
			Parent = holder,
		})
		new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = body })
		Kit.stroke(body, stroke, C.Ink, 0, true)
		Kit.gradient(body, Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242), 90)
		local headDot = new("Frame", {
			Name = "Head",
			BackgroundColor3 = Color3.new(1, 1, 1),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, headTop),
			Size = UDim2.fromOffset(math.floor(size * 0.46), math.floor(size * 0.46)),
			ZIndex = z + 1,
			Parent = holder,
		})
		Kit.pill(headDot)
		Kit.stroke(headDot, stroke, C.Ink, 0, true)
		Kit.gradient(headDot, Color3.new(1, 1, 1), Color3.fromRGB(214, 224, 242), 90)
		return holder
	end

	---------------------------------------------------------------------------
	-- title plate
	---------------------------------------------------------------------------
	local TITLE = "CHOOSE YOUR HERO"
	-- the shared title plate (the windows' plate): the fighter tile evenly inset on three sides
	local headPlate = Kit.titlePlate({
		Parent = root,
		Title = TITLE,
		TextSize = 44,
		Height = 82,
		Accent = C.Gold,
		Deep = C.GoldDeep,
		Position = UDim2.new(0.5, 0, 0, HEAD_Y),
		ZIndex = 20,
		Glyph = function(tile: Frame, z: number)
			fistGlyph(tile, 38, z)
		end,
	})
	local head = headPlate.Plate
	local headScale = Kit.fx(head)
	local headSheen = headPlate.Sheen

	local closeApi = Kit.closeButton({ Name = "Back", Parent = root, Position = UDim2.new(1, -62, 0, HEAD_Y), Size = 68, ZIndex = 30 })

	---------------------------------------------------------------------------
	-- left: the roster
	---------------------------------------------------------------------------
	local list = panel("Roster", LIST_W, LIST_H, "FIGHTERS", function(holder)
		fistGlyph(holder, 34, 12)
	end)
	local countLabel
	do
		local countChip
		countChip, countLabel = chip(list.Root, ("1 / %d"):format(#HEROES), C.Navy500, C.Navy700, 30, 15, 12)
		countChip.AnchorPoint = Vector2.new(1, 0.5)
		countChip.Position = UDim2.new(1, -22, 0, 42) -- as far in as the heading icon on the left
	end

	local rows: { any } = {}
	for i, h in ipairs(HEROES) do
		local a, d = accentOf(h)
		local btn = new("TextButton", {
			Name = h.Id,
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(20, 6 + (i - 1) * (ROW_H + ROW_GAP)),
			Size = UDim2.new(1, -40, 0, ROW_H),
			ZIndex = 12,
			Parent = list.Content,
		})
		local face = new("Frame", { Name = "Face", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 12, Parent = btn })
		Kit.corner(face, 26)
		local faceStroke = Kit.stroke(face, 4, C.Ink, 0, true)
		local grad = Kit.gradient(face, C.Navy600, C.Navy800, 90)
		local sc = Kit.fx(face)
		-- portrait: the hero's face on a sunburst in their colours
		-- portrait with the same double outline as the HUD's hero badge: ink, the hero's colour,
		-- ink, then the face on a sunburst
		-- the portrait is the row's whole left end: the gap round it (in the row's colours), then
		-- ink, the hero's colour and ink again are strokes on it, so each is exactly as wide at the
		-- left, the top and the bottom; the art reaches in under the inner ink ring
		local frame = Kit.slot({ Parent = face, Side = "Left", Width = ROW_H, Name = "PortraitFrame", ZIndex = 13 })
		frame.BackgroundTransparency = 0
		Kit.corner(frame, 37) -- the portrait's corner (26) pushed out by the gap (11)
		Kit.paint(frame, { Kit.lighten(a, 0.2), Kit.darken(d, 0.25), 90 })
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, Position = UDim2.fromOffset(21, 21), Size = UDim2.new(1, -42, 1, -42), ZIndex = 14, Parent = frame })
		Kit.corner(well, 17)
		local art = new("CanvasGroup", { Name = "Art", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 14, Parent = well })
		Kit.corner(art, 17)
		Kit.rays(art, Color3.new(1, 1, 1), 150, 0.72, 14, false)
		local shade = new("Frame", { Name = "Shade", BackgroundColor3 = C.Night, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.5), ZIndex = 14, Parent = art })
		Kit.gradient(shade, C.Night, C.Night, 90, 1, 0.45)
		local vpHolder = new("Frame", { Name = "View", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 15, Parent = well })
		task.spawn(function()
			local vp = portrait(vpHolder, h.Id, "bust", 15)
			if vp then
				Kit.corner(vp, 17)
			end
		end)
		local _, portraitGrads = Kit.rings(frame, UDim.new(0, 37), {
			{ 11, { C.Navy600, C.Navy800, 90 } },
			{ 4, C.Ink },
			{ 5, { Kit.lighten(a, 0.25), d, 90 } },
			{ 3, C.Ink },
		}, 16)
		local gapGrad = portraitGrads[1]
		Kit.outlineOnTop(face, 17)
		-- name, epithet and a status chip
		local nameText = Kit.text({ Name = "Name", Text = h.Name, TextSize = 32, Position = UDim2.fromOffset(132, 16), Size = UDim2.new(1, -196, 0, 36), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13, Stroke = 3.5, Parent = face })
		Kit.text({ Name = "Epithet", Text = h.Title or "", TextSize = 17, FontFace = Theme.Font.Heavy, TextColor3 = C.TextSoft, Position = UDim2.fromOffset(132, 52), Size = UDim2.new(1, -196, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13, Stroke = 2.2, Parent = face })
		local sub = new("Frame", { Name = "Sub", BackgroundTransparency = 1, Position = UDim2.fromOffset(132, 82), Size = UDim2.new(1, -196, 0, 28), ZIndex = 13, Parent = face })
		Kit.list(sub, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local nMoves = #(h.Moves or {})
		local movesChip, movesLabel = chip(sub, if nMoves > 0 then ("%d MOVES"):format(nMoves) else "MOVES SOON", if nMoves > 0 then Kit.lighten(a, 0.08) else C.Navy500, if nMoves > 0 then d else C.Navy700, 26, 13, 14)
		movesChip.LayoutOrder = 2
		local playingChip = chip(sub, "PLAYING", C.Green, C.GreenDeep, 26, 13, 14)
		playingChip.LayoutOrder = 1
		playingChip.Visible = false
		if not isTouch and i <= 9 then
			local k = keycap(face, tostring(i), 34, 32, 17, 14)
			k.AnchorPoint = Vector2.new(1, 0.5)
			k.Position = UDim2.new(1, -18, 0.5, 0)
		end
		local row = { Hero = h, Button = btn, Face = face, Grad = grad, GapGrad = gapGrad, Stroke = faceStroke, Scale = sc, Name = nameText, Playing = playingChip, MovesChip = movesChip, MovesLabel = movesLabel, Hover = false }
		btn.MouseEnter:Connect(function()
			row.Hover = true
			tween(sc, 0.2, { Scale = 1.03 }, Enum.EasingStyle.Back)
		end)
		btn.MouseLeave:Connect(function()
			row.Hover = false
			tween(sc, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		btn.Activated:Connect(function()
			ctx.Fire("HeroSelectPick", i)
		end)
		rows[i] = row
	end

	---------------------------------------------------------------------------
	-- right: details, moveset, select
	---------------------------------------------------------------------------
	local info = panel("Details", INFO_W, INFO_H, "HERO", function(holder)
		local star = Kit.image({ Image = Theme.Icon.Star, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(44, 44), ZIndex = 12, Parent = holder })
		star.Rotation = -8
	end)
	local ic = info.Content
	local PADX = 26
	local infoTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 180), ZIndex = 11, Parent = ic })
	local topScale = Kit.fx(infoTop)
	-- style tags + difficulty
	local tagChips: { any } = {}
	do
		local tagRow = new("Frame", { Name = "Tags", BackgroundTransparency = 1, Position = UDim2.fromOffset(PADX, 4), Size = UDim2.new(1, -PADX * 2, 0, 28), ZIndex = 12, Parent = infoTop })
		Kit.list(tagRow, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		for i = 1, 2 do
			local p, l = chip(tagRow, "TAG", C.Navy500, C.Navy700, 28, 14, 13)
			p.LayoutOrder = i
			tagChips[i] = { Plate = p, Label = l, Grad = p:FindFirstChildOfClass("UIGradient") }
		end
	end
	local diff = new("Frame", { Name = "Difficulty", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -PADX, 0, 4), Size = UDim2.fromOffset(170, 28), ZIndex = 12, Parent = infoTop })
	Kit.list(diff, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	Kit.text({ Text = "DIFFICULTY", TextSize = 14, FontFace = Theme.Font.Heavy, TextColor3 = C.TextDim, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 0, ZIndex = 13, Stroke = 1.8, Parent = diff })
	local pips: { Frame } = {}
	for i = 1, 3 do
		local pip = new("Frame", { Name = "Pip" .. i, BackgroundColor3 = C.Navy500, Size = UDim2.fromOffset(16, 16), LayoutOrder = i, ZIndex = 13, Parent = diff })
		Kit.pill(pip)
		Kit.stroke(pip, 2.5, C.Ink, 0)
		pips[i] = pip
	end
	local nameText = Kit.text({ Name = "HeroName", Text = "", TextSize = 52, Position = UDim2.fromOffset(PADX, 38), Size = UDim2.new(1, -PADX * 2, 0, 58), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 5, Parent = infoTop })
	local titleText = Kit.text({ Name = "Epithet", Text = "", TextSize = 20, FontFace = Theme.Font.Heavy, TextColor3 = C.Text, Position = UDim2.fromOffset(PADX, 96), Size = UDim2.new(1, -PADX * 2, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12, Stroke = 2.4, Parent = infoTop })
	local blurbText = Kit.text({
		Name = "Blurb",
		Text = "",
		TextSize = 17,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(PADX, 126),
		Size = UDim2.new(1, -PADX * 2, 0, 46),
		ZIndex = 12,
		Stroke = 2,
		Parent = infoTop,
	})
	Kit.pill(new("Frame", { Name = "Divider", BackgroundColor3 = C.Rim, BackgroundTransparency = 0.72, BorderSizePixel = 0, Position = UDim2.fromOffset(PADX, 184), Size = UDim2.new(1, -PADX * 2, 0, 3), ZIndex = 11, Parent = ic }))
	-- MOVESET / LORE switch (the settings window's tab switch, in the hero's colours)
	local tabTrack = Kit.plate({ Name = "Tabs", Parent = ic, Position = UDim2.fromOffset(PADX, TABS_Y), Size = UDim2.new(1, -PADX * 2, 0, 40), Radius = UDim.new(1, 0), Stroke = 3, ZIndex = 12, Gradient = { C.Night, C.Navy900 } })
	-- the thumb shares the track's edges on the side it sits at; the gap round it is a stroke in
	-- the track's colours, 4 from the end, the top and the bottom
	local thumbApi = Kit.switchThumb({
		Parent = tabTrack,
		Gap = 4,
		Overhang = 2,
		Track = { C.Night, C.Navy900, 90 },
		Face = { Kit.lighten(C.Gold, 0.1), C.GoldDeep, 90 },
		ZIndex = 13,
	})
	local tabThumbGrad = thumbApi.Face
	Kit.outlineOnTop(tabTrack, 14)
	local tabLabels: { [string]: TextLabel } = {}
	local tabPage = "Moves"
	for i, t in ipairs({ { "Moves", "MOVESET" }, { "Lore", "LORE" } }) do
		local b = new("TextButton", { Name = t[1], AutoButtonColor = false, Text = "", BackgroundTransparency = 1, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ZIndex = 15, Parent = tabTrack })
		tabLabels[t[1]] = Kit.text({ Text = t[2], TextSize = 17, FontFace = Theme.Font.Heavy, Size = UDim2.fromScale(1, 1), ZIndex = 14, Stroke = 2.2, Parent = tabTrack, Position = UDim2.fromScale((i - 1) * 0.5, 0) })
		tabLabels[t[1]].Size = UDim2.fromScale(0.5, 1)
		b.Activated:Connect(function()
			ctx.Fire("HeroSelectTab", t[1])
		end)
	end

	-- the lore card: where they come from, their story, a line they'd say
	local lore = Kit.plate({ Name = "Lore", Parent = ic, Position = UDim2.fromOffset(PADX, MOVES_Y), Size = UDim2.new(1, -PADX * 2, 0, CONTENT_H), Radius = 20, Stroke = 3.5, ZIndex = 12, Gradient = { C.Navy600, C.Navy800 } })
	lore.Visible = false
	local loreScale = Kit.fx(lore)
	local LORE_PAD = 18
	local LORE_W = INFO_W - PADX * 2 - LORE_PAD * 2
	local originChip, originText
	do
		local loreOrigin = new("Frame", { Name = "Origin", BackgroundTransparency = 1, Position = UDim2.fromOffset(LORE_PAD, LORE_PAD), Size = UDim2.fromOffset(LORE_W, 28), ZIndex = 13, Parent = lore })
		Kit.list(loreOrigin, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		originChip = chip(loreOrigin, "ORIGIN", C.Navy500, C.Navy700, 26, 13, 14)
		originChip.LayoutOrder = 1
		originText = Kit.text({ Name = "Place", Text = "", TextSize = 16, FontFace = Theme.Font.Heavy, TextColor3 = C.Text, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 14, Stroke = 2, Parent = loreOrigin })
	end
	local QUOTE_H = 44
	-- the story sits under the origin row (28) with a 12 gap, and 12 above the quote
	local LORE_TEXT_H = CONTENT_H - (LORE_PAD + 28 + 12) - 12 - QUOTE_H - LORE_PAD
	local loreText = Kit.text({
		Name = "Story",
		Text = "",
		TextSize = 16,
		FontFace = Theme.Font.Heavy,
		TextColor3 = C.TextSoft,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(LORE_PAD, LORE_PAD + 28 + 12),
		Size = UDim2.fromOffset(LORE_W, LORE_TEXT_H),
		ZIndex = 13,
		Stroke = 1.8,
		Parent = lore,
	})
	local quoteBar = new("Frame", { Name = "QuoteBar", BackgroundColor3 = C.Gold, BorderSizePixel = 0, Position = UDim2.new(0, LORE_PAD, 1, -LORE_PAD - QUOTE_H), Size = UDim2.fromOffset(5, QUOTE_H), ZIndex = 13, Parent = lore })
	Kit.pill(quoteBar)
	local quoteText = Kit.text({
		Name = "Quote",
		Text = "",
		TextSize = 17,
		TextColor3 = C.Gold,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.new(0, LORE_PAD + 16, 1, -LORE_PAD - QUOTE_H),
		Size = UDim2.fromOffset(LORE_W - 16, QUOTE_H),
		ZIndex = 13,
		Stroke = 2.4,
		Parent = lore,
	})

	local TYPE_COLOURS: { [string]: { Color3 } } = {
		BEAM = { C.Blue, C.BlueDeep },
		CHARGE = { C.Purple, C.PurpleDeep },
		EVADE = { C.Teal, C.TealDeep },
		ULTIMATE = { C.Red, C.RedDeep },
	}
	local moveRows: { any } = {}
	local MOVE_TEXT_W = INFO_W - PADX * 2 - 84 - 16
	for i = 1, 4 do
		local plate = Kit.plate({
			Name = "Move" .. i,
			Parent = ic,
			Position = UDim2.fromOffset(PADX, MOVES_Y + (i - 1) * (MOVE_H + MOVE_GAP)),
			Size = UDim2.new(1, -PADX * 2, 0, MOVE_H),
			Radius = 20,
			Stroke = 3.5,
			ZIndex = 12,
			Gradient = { C.Navy600, C.Navy800 },
		})
		local sc = Kit.fx(plate)
		local cap, capLabel, capGrad = keycap(plate, "", 54, 54, 24, 13)
		cap.AnchorPoint = Vector2.new(0, 0.5)
		cap.Position = UDim2.new(0, 14, 0.5, 0)
		local mName = Kit.text({ Name = "MoveName", Text = "", TextSize = 22, Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(MOVE_TEXT_W - 100, 28), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13, Stroke = 2.8, Parent = plate })
		local typeChip, typeLabel = chip(plate, "BEAM", C.Blue, C.BlueDeep, 26, 13, 13)
		typeChip.AnchorPoint = Vector2.new(1, 0)
		typeChip.Position = UDim2.new(1, -12, 0, 12)
		local mDesc = Kit.text({
			Name = "MoveDesc",
			Text = "",
			TextSize = 15,
			FontFace = Theme.Font.Heavy,
			TextColor3 = C.TextSoft,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(84, 40),
			Size = UDim2.fromOffset(MOVE_TEXT_W, 36),
			ZIndex = 13,
			Stroke = 1.8,
			Parent = plate,
		})
		moveRows[i] = { Plate = plate, Scale = sc, Grad = plate:FindFirstChildOfClass("UIGradient"), Cap = cap, CapLabel = capLabel, CapGrad = capGrad, Name = mName, Chip = typeChip, ChipLabel = typeLabel, ChipGrad = typeChip:FindFirstChildOfClass("UIGradient"), Desc = mDesc }
	end

	local action = Kit.button({
		Name = "Action",
		Parent = ic,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.new(1, -PADX * 2, 0, 82),
		Radius = 26,
		Depth = 6,
		Stroke = 4,
		Color = C.Green,
		Deep = C.GreenDeep,
		Text = "SELECT",
		TextSize = 34,
		ZIndex = 14,
		Shine = true,
		OnClick = function()
			ctx.Fire("HeroSelectConfirm")
		end,
	})

	---------------------------------------------------------------------------
	-- bottom: how to use it
	---------------------------------------------------------------------------
	local hint = Kit.plate({
		Name = "Hint",
		Parent = root,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -34),
		Size = UDim2.new(0, 0, 0, HINT_H),
		AutomaticSize = Enum.AutomaticSize.X,
		Radius = UDim.new(1, 0),
		Stroke = 4.5,
		ZIndex = 12,
		Gradient = { C.Navy700, C.Navy900 },
	})
	local hintScale = Kit.fx(hint)
	Kit.padding(hint, 22, 0, 22, 0)
	Kit.list(hint, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local backHint: { GuiObject } = {}
	local function hintText(t: string, order: number): TextLabel
		return Kit.text({ Text = t, TextSize = 18, FontFace = Theme.Font.Heavy, TextColor3 = C.TextSoft, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, ZIndex = 13, Stroke = 2.2, Parent = hint })
	end
	local function hintDot(order: number): Frame
		local d = new("Frame", { BackgroundColor3 = C.Rim, BackgroundTransparency = 0.4, Size = UDim2.fromOffset(6, 6), LayoutOrder = order, ZIndex = 13, Parent = hint })
		Kit.pill(d)
		return d
	end
	hintText("DRAG TO SPIN", 1)
	if not isTouch then
		hintDot(2)
		local k1 = keycap(hint, "A", 32, 32, 17, 13)
		k1.LayoutOrder = 3
		local k2 = keycap(hint, "D", 32, 32, 17, 13)
		k2.LayoutOrder = 4
		hintText("SWITCH", 5)
		hintDot(6)
		local k3 = keycap(hint, "ENTER", 76, 32, 17, 13)
		k3.LayoutOrder = 7
		hintText("SELECT", 8)
		table.insert(backHint, hintDot(9))
		local k4 = keycap(hint, "BACKSPACE", 104, 32, 17, 13)
		k4.LayoutOrder = 10
		table.insert(backHint, k4)
		table.insert(backHint, hintText("BACK", 11))
	end

	---------------------------------------------------------------------------
	-- lock-in: a flash over the stage and a LOCKED IN plate (the title plate's dress) that slams
	-- down over the podium
	---------------------------------------------------------------------------
	local flash = new("Frame", { Name = "Flash", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = root })
	local STAMP_TEXT = "LOCKED IN"
	local stamp = new("Frame", {
		Name = "LockedIn",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(34 + HINT_H + 24)),
		Size = UDim2.fromOffset(Kit.textWidth(STAMP_TEXT, 52) + 170, 92),
		Visible = false,
		ZIndex = 24,
		Parent = root,
	})
	local stampScale = Kit.fx(stamp)
	Kit.corner(stamp, 26)
	Kit.paint(stamp, { C.Navy800, C.Night, 90 })
	-- the gold rim and the ink outline are strokes on the stamp's own edge: the same all round
	local stampSheen = Kit.addShine(stamp, 26)
	stampSheen.ZIndex = 24
	local _, stampRim = Kit.rings(stamp, 26, { { 6, { Kit.lighten(C.Gold, 0.15), C.GoldDeep, 90 } } }, 25)
	local stampGrad = stampRim[1]
	do
		local line = new("Frame", { Name = "Outline", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 27, Parent = stamp })
		Kit.corner(line, 26)
		Kit.stroke(line, 5, C.Ink, 0, true)
	end
	local stampLabel = Kit.text({ Name = "Title", Text = STAMP_TEXT, TextSize = 52, Size = UDim2.new(1, -150, 1, -6), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), ZIndex = 26, Stroke = 5, Parent = stamp })
	local stampStars: { ImageLabel } = {}
	for i, side in ipairs({ -1, 1 }) do
		local st = Kit.image({
			Name = "Star" .. i,
			Image = Theme.Icon.Star,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5 + side * 0.5, -side * 44, 0.5, -2),
			Size = UDim2.fromOffset(58, 58),
			Rotation = side * 12,
			ZIndex = 26,
			Parent = stamp,
		})
		stampStars[i] = st
	end

	local function showStamp(h: any)
		local a, d = accentOf(h)
		stampGrad.Color = ColorSequence.new(Kit.lighten(a, 0.15), d)
		stampLabel.TextColor3 = Color3.new(1, 1, 1)
		stamp.Visible = true
		stamp.Rotation = -6
		stampScale.Scale = 2.1
		tween(stampScale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		tween(stamp, 0.32, { Rotation = 0 }, Enum.EasingStyle.Back)
		for i, st in ipairs(stampStars) do
			local sc = Kit.fx(st)
			sc.Scale = 0
			tween(sc, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.16 + 0.06 * i)
		end
		task.delay(0.3, function()
			Kit.playShine(stampSheen)
		end)
	end

	---------------------------------------------------------------------------
	-- fitting the screen: never bigger than the HUD, and small enough that both panels, the
	-- title and the hint bar fit with the hero in the middle
	---------------------------------------------------------------------------
	local function layout()
		local s = math.max(rootScale.Scale, 0.1)
		local vp = workspace.CurrentCamera.ViewportSize
		local refH = math.max(vp.Y / s, 600)
		local inset = topInset() / s
		local top, bottom = inset + HEAD_Y + 44, refH - HINT_H - 34
		local midY = (top + bottom) / 2
		head.Position = UDim2.new(0.5, 0, 0, inset + HEAD_Y)
		closeApi.Button.Position = UDim2.new(1, -62, 0, inset + HEAD_Y)
		list.Root.AnchorPoint = Vector2.new(0, 0.5)
		list.Root.Position = UDim2.new(0, SIDE, 0, midY)
		info.Root.AnchorPoint = Vector2.new(1, 0.5)
		info.Root.Position = UDim2.new(1, -SIDE, 0, midY)
	end
	-- the select screen runs a touch smaller than the HUD, so the stage breathes between the panels
	local SELECT_UI = 0.86
	local function fitScale(): number
		local vp = workspace.CurrentCamera.ViewportSize
		local s = math.max((ctx.Scale or 1) * SELECT_UI, 0.1)
		if vp.X < 2 or vp.Y < 2 then
			return s
		end
		local inset = topInset()
		local needH = HEAD_Y + 44 + 16 + math.max(INFO_H, LIST_H) + 16 + HINT_H + 34
		local needW = SIDE * 2 + LIST_W + INFO_W + MID_MIN
		return math.max(math.min(s, (vp.Y - inset) / needH, vp.X / needW), 0.3)
	end
	local function rescale()
		local sc = fitScale()
		rootScale.Scale = sc
		root.Size = UDim2.fromScale(1 / sc, 1 / sc)
		layout()
	end
	ctx.On("Scale", rescale)
	rescale()

	---------------------------------------------------------------------------
	-- state
	---------------------------------------------------------------------------
	local open = false
	local firstPick = false
	local busyUntil = 0
	local picking = false
	local index = 1
	local rig: Rig? = nil
	local rigCache: { [string]: Rig } = {}
	local baseYaw = -0.2 -- turned a touch, so the stance has some depth
	local yaw, yawVel, lastTouch = baseYaw, 0, 0
	local dragging, lastX = false, 0
	local saved: any = nil
	local controls: any = nil
	local anim = { Mode = "idle", T0 = 0, Clock = 0 }

	local function current(): any
		return HEROES[index]
	end

	local function setAccent(h: any)
		local a, d = accentOf(h)
		for _, g in ipairs(bands) do
			g.Color = ColorSequence.new(a, d)
		end
		headPlate.SetAccent(a, d)
	end

	local function refreshRows()
		local playing = currentHeroId()
		for i, row in ipairs(rows) do
			local on = i == index
			local a, d = accentOf(row.Hero)
			row.Grad.Color = if on then ColorSequence.new(Kit.lighten(a, 0.02), Kit.darken(d, 0.1)) else ColorSequence.new(C.Navy600, C.Navy800)
			if row.GapGrad then
				row.GapGrad.Color = row.Grad.Color -- the gap round the portrait is the row's own colour
			end
			row.Stroke.Color = if on then Color3.new(1, 1, 1) else C.Ink
			row.Playing.Visible = row.Hero.Id == playing
		end
		countLabel.Text = ("%d / %d"):format(index, #HEROES)
	end

	local function refreshAction()
		local h = current()
		if not h then
			return
		end
		if picking then
			action.SetText("...")
			return
		end
		if currentHeroId() == h.Id then
			action.SetText("PLAYING")
			action.SetColor(C.Navy500, C.Navy700)
		else
			action.SetText("PLAY AS " .. h.Name)
			action.SetColor(C.Green, C.GreenDeep)
		end
	end

	-- the biggest text size (max..min) at which `text` wraps into `maxH` pixels; measured once
	-- per text in the background, so switching heroes never waits on it
	local fitCache: { [string]: number } = {}
	local function fitSize(text: string, max: number, min: number, width: number, maxH: number): number
		local key = text .. "|" .. max .. "|" .. width
		local v = fitCache[key]
		if v then
			return v
		end
		local size = max
		while size > min and Kit.textHeight(text, size, width, Theme.Font.Heavy) > maxH do
			size -= 1
		end
		fitCache[key] = size
		return size
	end

	-- MOVESET / LORE: slide the switch, swap the page with a small pop
	local function setTab(page: string, instant: boolean?)
		tabPage = page
		local isLore = page == "Lore"
		thumbApi.Set(if isLore then 2 else 1, instant)
		tabLabels.Moves.TextColor3 = if isLore then C.TextDim else C.Text
		tabLabels.Lore.TextColor3 = if isLore then C.Text else C.TextDim
		lore.Visible = isLore
		for _, mr in ipairs(moveRows) do
			mr.Plate.Visible = not isLore
		end
		if not instant then
			if isLore then
				loreScale.Scale = 0.95
				tween(loreScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			else
				for i, mr in ipairs(moveRows) do
					mr.Scale.Scale = 0.95
					tween(mr.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.03 * i)
				end
			end
			Kit.sfx("Click")
		end
	end
	setTab("Moves", true)
	ctx.On("HeroSelectTab", function(page: string)
		if open and page ~= tabPage then
			setTab(page)
		end
	end)

	local function showDetails(h: any, instant: boolean?)
		local a, d = accentOf(h)
		setAccent(h)
		local name = string.upper(h.Name)
		nameText.Text = name
		nameText.TextSize = math.min(52, math.floor(52 * (INFO_W - PADX * 2 - 4) / math.max(Kit.textWidth(name, 52), 1)))
		nameText.TextColor3 = Kit.lighten(a, 0.35)
		titleText.Text = h.Title or ""
		blurbText.Text = h.Blurb or ""
		blurbText.TextSize = fitSize(blurbText.Text, 17, 14, INFO_W - PADX * 2 - 2, 46)
		-- lore card + the switch take the hero's colours
		local lore_ = h.Lore or {}
		originText.Text = lore_.Origin or "Unknown"
		loreText.Text = lore_.Text or ""
		loreText.TextSize = fitSize(loreText.Text, 30, 13, LORE_W - 2, LORE_TEXT_H - 2)
		quoteText.Text = if lore_.Quote then ("\u{201C}%s\u{201D}"):format(lore_.Quote) else ""
		quoteText.TextSize = fitSize(quoteText.Text, 18, 13, LORE_W - 18, QUOTE_H)
		quoteText.TextColor3 = Kit.lighten(a, 0.35)
		quoteBar.BackgroundColor3 = a
		tabThumbGrad.Color = ColorSequence.new(Kit.lighten(a, 0.1), d)
		local og = originChip:FindFirstChildOfClass("UIGradient")
		if og then
			og.Color = ColorSequence.new(Kit.lighten(a, 0.06), d)
		end
		for i, t in ipairs(tagChips) do
			local s = h.Style and h.Style[i]
			t.Plate.Visible = s ~= nil
			t.Label.Text = s or ""
			if t.Grad then
				t.Grad.Color = ColorSequence.new(Kit.lighten(a, 0.06), d)
			end
		end
		for i, pip in ipairs(pips) do
			pip.BackgroundColor3 = if i <= (h.Difficulty or 1) then a else C.Navy600
		end
		local moves = h.Moves or {}
		for i, mr in ipairs(moveRows) do
			local m = moves[i]
			if m then
				local isUlt = m.Type == "ULTIMATE"
				mr.CapLabel.Text = m.Key or tostring(i)
				mr.CapLabel.TextColor3 = C.Ink
				mr.CapGrad.Color = if isUlt then ColorSequence.new(Kit.lighten(C.Gold, 0.25), C.GoldDeep) else ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(222, 230, 244))
				mr.Name.Text = m.Name
				mr.Name.TextColor3 = if isUlt then Kit.lighten(C.Gold, 0.3) else C.Text
				mr.Name.TextSize = math.min(22, math.floor(22 * (MOVE_TEXT_W - 104) / math.max(Kit.textWidth(m.Name, 22), 1)))
				mr.Desc.Text = m.Desc or ""
				mr.Desc.TextColor3 = C.TextSoft
				mr.Desc.TextSize = fitSize(mr.Desc.Text, 15, 12, MOVE_TEXT_W - 2, 36)
				local tc = TYPE_COLOURS[m.Type or ""] or { a, d }
				mr.ChipLabel.Text = m.Type or ""
				mr.Chip.Visible = m.Type ~= nil
				if mr.ChipGrad then
					mr.ChipGrad.Color = ColorSequence.new(Kit.lighten(tc[1], 0.08), tc[2])
				end
				mr.Grad.Color = if isUlt then ColorSequence.new(Kit.darken(C.Gold, 0.55), C.Navy800) else ColorSequence.new(C.Navy600, C.Navy800)
				mr.Plate.BackgroundTransparency = 0
			else
				-- blank slot: the move isn't made yet
				mr.CapLabel.Text = "?"
				mr.CapLabel.TextColor3 = C.TextDim
				mr.CapGrad.Color = ColorSequence.new(C.Navy500, C.Navy700)
				mr.Name.Text = "Coming soon"
				mr.Name.TextColor3 = C.TextDim
				mr.Name.TextSize = 22
				mr.Desc.Text = "This move is still in training."
				mr.Desc.TextColor3 = C.TextDim
				mr.Desc.TextSize = 15
				mr.Chip.Visible = false
				mr.Grad.Color = ColorSequence.new(C.Navy700, C.Navy900)
			end
			if not instant then
				mr.Scale.Scale = 0.94
				tween(mr.Scale, 0.32, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.03 * i)
			end
		end
		if not instant then
			topScale.Scale = 0.94
			tween(topScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		refreshRows()
		refreshAction()
	end

	task.spawn(function()
		for _, h in ipairs(HEROES) do
			fitSize(h.Blurb or "", 17, 14, INFO_W - PADX * 2 - 2, 46)
			for _, m in ipairs(h.Moves or {}) do
				fitSize(m.Desc or "", 15, 12, MOVE_TEXT_W - 2, 36)
			end
		end
	end)

	---------------------------------------------------------------------------
	-- the hero on the stage
	---------------------------------------------------------------------------
	local function getRig(id: string): Rig?
		local r = rigCache[id]
		if not r then
			r = buildRig(id)
			if r then
				rigCache[id] = r
			end
		end
		return r
	end

	local function stageRoot(drop: number): CFrame
		return CFrame.new(ORIGIN + Vector3.new(0, FEET + FEET_BELOW_ROOT + drop, 0)) * CFrame.Angles(0, math.pi + yaw, 0)
	end

	local function smooth(k: number): number
		k = math.clamp(k, 0, 1)
		return k * k * (3 - 2 * k)
	end
	local function outCubic(k: number): number
		k = math.clamp(k, 0, 1)
		return 1 - (1 - k) ^ 3
	end

	-- the pose for this frame, and how high above the podium the hero is
	local function poseAt(now: number): (any, number)
		local h = current()
		local poses = h and HeroPoses[h.Id]
		if not poses then
			return nil, 0
		end
		-- idle: a slow, even breath
		local breathe = (1 - math.cos((now - anim.Clock) * math.pi * 2 / 3.2)) / 2
		local idle = blend(poses.Stance, poses.Breath, breathe)
		local dt = now - anim.T0
		if anim.Mode == "intro" then
			-- drops onto the podium, lands soft, straightens up
			if dt < 0.2 then
				local f = dt / 0.2
				return blend(idle, poses.Intro, f * 0.6), 1.5 * (1 - f * f)
			end
			if dt > 0.7 then
				anim.Mode = "idle"
			end
			return blend(poses.Intro, idle, outCubic((dt - 0.2) / 0.5)), 0
		elseif anim.Mode == "cheer" then
			-- wind up, spring into the V, hold it, come down proud, settle back into the idle
			if dt < 0.16 then
				return blend(idle, poses.Crouch, smooth(dt / 0.16)), 0
			elseif dt < 0.46 then
				local k = (dt - 0.16) / 0.3
				return blend(poses.Crouch, poses.Win, outCubic(k)), math.sin(math.clamp(k, 0, 1) * math.pi) * 0.85
			elseif dt < 1.2 then
				-- a little bounce at the top of the cheer
				local b = math.sin((dt - 0.46) * math.pi * 2 / 0.37) * math.exp(-(dt - 0.46) * 4) * 0.06
				return poses.Win, b
			elseif dt < 1.6 then
				return blend(poses.Win, poses.Proud, smooth((dt - 1.2) / 0.4)), 0
			elseif dt < 2.3 then
				return blend(poses.Proud, idle, smooth((dt - 1.6) / 0.7)), 0
			end
			anim.Mode = "idle"
		end
		return idle, 0
	end

	local function placeRig(now: number)
		if not rig then
			return
		end
		local pose, drop = poseAt(now)
		if pose then
			applyPose(rig, stageRoot(drop), pose)
		end
	end

	local function showHero(i: number, instant: boolean?)
		index = ((i - 1) % #HEROES) + 1
		local h = current()
		local nextRig = getRig(h.Id)
		if rig and rig ~= nextRig then
			rig.Model.Parent = nil
		end
		rig = nextRig
		local st = getStage()
		if rig and st then
			rig.Model.Parent = st
		end
		yaw, yawVel = baseYaw, 0
		anim.Mode = "intro"
		anim.T0 = os.clock()
		placeRig(os.clock())
		tintStage(h)
		task.delay(0.2, function()
			if open and current() == h then
				ringWave(h, false)
			end
		end)
		showDetails(h, instant)
		if not instant then
			local row = rows[index]
			if row then
				row.Scale.Scale = 0.95
				tween(row.Scale, 0.3, { Scale = if row.Hover then 1.03 else 1 }, Enum.EasingStyle.Back)
			end
			Kit.sfx("Equip")
		end
	end

	---------------------------------------------------------------------------
	-- camera: fits the hero and the pad into the open space between the panels
	---------------------------------------------------------------------------
	local FOV = 30
	local PITCH = math.rad(12)
	local camOn = false
	local camDolly = new("NumberValue", { Value = 1 })
	local HERO_H, HERO_W = 6.4, 4.2 -- soles to the tip of the tallest hair, arm to arm
	-- what has to be in shot: the hero, the whole crater circle and the orbs - all of it between
	-- the two panels and between the title and the hint bar, with room to spare
	local HERO_PTS: { Vector3 } = {}
	for _, y in ipairs({ 0, HERO_H + 0.35 }) do
		for _, x in ipairs({ -HERO_W / 2, HERO_W / 2 }) do
			table.insert(HERO_PTS, Vector3.new(x, FEET + y, 0))
		end
	end
	local RING_PTS: { Vector3 } = {}
	local measured = false
	-- measured from the stage itself: the crater's outer edge and the orbs on the pillars
	local function measureStage()
		if measured or not stage then
			return
		end
		measured = true
		table.clear(RING_PTS)
		local r = 5.3
		local crater = stage:FindFirstChild("Crater")
		if crater then
			r = 0
			for _, p in ipairs(crater:GetDescendants()) do
				if p:IsA("BasePart") then
					local rel = p.Position - ORIGIN
					local edge = if p.Name == "CraterBed" then p.Size.Z / 2 else Vector2.new(rel.X, rel.Z).Magnitude + math.min(p.Size.X, p.Size.Z) / 2
					r = math.max(r, edge)
				end
			end
		end
		-- the rim stones are jagged meshes: pad the radius, and take the ring at ground level as
		-- well as the stones' tops (the near edge at ground level is the lowest thing on screen)
		r += 0.35
		for k = 0, 47 do
			local a = k / 48 * math.pi * 2
			table.insert(RING_PTS, Vector3.new(math.cos(a) * r, 0.55, math.sin(a) * r))
			table.insert(RING_PTS, Vector3.new(math.cos(a) * r, -0.05, math.sin(a) * r))
		end
		for _, d in ipairs(stage:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "OrbAnchor" then
				local rel = d.Position - ORIGIN
				for _, dx in ipairs({ -0.62, 0.62 }) do
					table.insert(RING_PTS, rel + Vector3.new(dx, 0.62, 0))
				end
			end
		end
	end

	local function frameCamera()
		if not camOn then
			return
		end
		measureStage()
		local cam = workspace.CurrentCamera
		local vp = cam.ViewportSize
		if vp.X < 2 or vp.Y < 2 then
			return
		end
		local s = math.max(rootScale.Scale, 0.1)
		local refW, refH = vp.X / s, vp.Y / s
		local inset = topInset() / s
		local L = (SIDE + LIST_W + 40) / refW
		local R = 1 - (SIDE + INFO_W + 40) / refW
		local T = (inset + HEAD_Y + 44 + 22) / refH
		local B = 1 - (34 + HINT_H + 30) / refH -- a clear gap above the hint bar
		local SL, SR = L + 18 / refW, R - 18 / refW -- the stage stays clear of both panels
		local sx = (L + R) / 2
		local tanV = math.tan(math.rad(FOV / 2))
		local aspect = vp.X / vp.Y
		local look = Vector3.new(0, -math.sin(PITCH), -math.cos(PITCH))
		local up = Vector3.new(0, math.cos(PITCH), -math.sin(PITCH))
		local right = Vector3.new(1, 0, 0)
		local aim = ORIGIN + Vector3.new(0, FEET + HERO_H * 0.4, 0)

		-- camera for distance d: the aim point on the free column's centre line, then moved up or
		-- down so everything that must be in shot is centred between the title and the hint bar
		local function place(d: number): (Vector3, boolean)
			local dx = (sx - 0.5) * 2 * d * tanV * aspect
			local pos = aim - look * d - right * dx
			local function proj(p: Vector3): (number, number)
				local v = ORIGIN + p - pos
				local z = math.max(v:Dot(look), 0.1)
				return 0.5 + v:Dot(right) / (z * tanV * aspect) / 2, 0.5 - v:Dot(up) / (z * tanV) / 2
			end
			local y0, y1 = math.huge, -math.huge
			for _, set in ipairs({ HERO_PTS, RING_PTS }) do
				for _, p in ipairs(set) do
					local _, y = proj(p)
					y0 = math.min(y0, y)
					y1 = math.max(y1, y)
				end
			end
			local shift = (y0 + y1) / 2 - (T + B) / 2 -- + means the shot sits too low: move the camera down
			pos -= up * (shift * 2 * d * tanV)
			local ok = true
			for _, p in ipairs(HERO_PTS) do
				local x, y = proj(p)
				if x < L or x > R or y < T or y > B then
					ok = false
				end
			end
			for _, p in ipairs(RING_PTS) do
				local x, y = proj(p)
				if x < SL or x > SR or y < T or y > B then
					ok = false
				end
			end
			return pos, ok
		end
		local lo, hi = 8, 400
		for _ = 1, 22 do
			local mid = (lo + hi) / 2
			local _, ok = place(mid)
			if ok then
				hi = mid
			else
				lo = mid
			end
		end
		local pos = place(hi * camDolly.Value)
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = FOV
		cam.CFrame = CFrame.lookAt(pos, pos + look)
	end
	camDolly.Changed:Connect(frameCamera)

	local function step(dt: number)
		if not rig then
			return
		end
		if not dragging then
			if os.clock() - lastTouch > 1.4 then
				-- ease back to facing you
				local diff = baseYaw - yaw
				diff = (diff + math.pi) % (2 * math.pi) - math.pi
				yawVel += (diff * 7 - yawVel * 3.2) * math.min(dt, 0.05)
			else
				yawVel *= math.max(0, 1 - dt * 3)
			end
			yaw += yawVel * dt
		end
		placeRig(os.clock())
		if camOn and workspace.CurrentCamera.CameraType ~= Enum.CameraType.Scriptable then
			frameCamera()
		end
	end

	grab.InputBegan:Connect(function(input)
		if not open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
			yawVel = 0
			lastTouch = os.clock()
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - lastX
			lastX = input.Position.X
			local dt = math.max(os.clock() - lastTouch, 1 / 240)
			lastTouch = os.clock()
			yaw += dx * 0.011
			yawVel = math.clamp(dx * 0.011 / dt, -6, 6)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				lastTouch = os.clock()
			end
		end
	end)

	---------------------------------------------------------------------------
	-- open / close
	---------------------------------------------------------------------------
	local function setControls(on: boolean)
		if not controls then
			pcall(function()
				local ps = player:FindFirstChild("PlayerScripts")
				local pm = ps and ps:FindFirstChild("PlayerModule")
				if pm then
					controls = require(pm :: ModuleScript):GetControls()
				end
			end)
		end
		if controls then
			pcall(function()
				if on then
					controls:Enable()
				else
					controls:Disable()
				end
			end)
		end
	end

	local NUMBER_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine }
	local function bindKeys(on: boolean)
		if on then
			ContextActionService:BindActionAtPriority("OverkillHeroSelectNav", function(_, st, input)
				if st == Enum.UserInputState.Begin then
					local k = input.KeyCode
					local back = k == Enum.KeyCode.A or k == Enum.KeyCode.W or k == Enum.KeyCode.Left or k == Enum.KeyCode.Up or k == Enum.KeyCode.ButtonL1
					ctx.Fire("HeroSelectStep", if back then -1 else 1)
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
			local keys = {}
			for i = 1, math.min(#HEROES, 9) do
				keys[i] = NUMBER_KEYS[i]
			end
			ContextActionService:BindActionAtPriority("OverkillHeroSelectPick", function(_, st, input)
				if st == Enum.UserInputState.Begin then
					for i, k in ipairs(keys) do
						if input.KeyCode == k then
							ctx.Fire("HeroSelectPick", i)
						end
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, table.unpack(keys))
			ContextActionService:BindActionAtPriority("OverkillHeroSelectConfirm", function(_, st)
				if st == Enum.UserInputState.Begin then
					ctx.Fire("HeroSelectConfirm")
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonA)
			ContextActionService:BindActionAtPriority("OverkillHeroSelectTab", function(_, st)
				if st == Enum.UserInputState.Begin then
					ctx.Fire("HeroSelectTab", if tabPage == "Moves" then "Lore" else "Moves")
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.Tab, Enum.KeyCode.ButtonY)
			ContextActionService:BindActionAtPriority("OverkillHeroSelectBack", function(_, st)
				if st == Enum.UserInputState.Begin then
					ctx.Fire("HeroSelectClose")
				end
				return Enum.ContextActionResult.Sink
			end, false, 2500, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
		else
			ContextActionService:UnbindAction("OverkillHeroSelectNav")
			ContextActionService:UnbindAction("OverkillHeroSelectPick")
			ContextActionService:UnbindAction("OverkillHeroSelectConfirm")
			ContextActionService:UnbindAction("OverkillHeroSelectBack")
			ContextActionService:UnbindAction("OverkillHeroSelectTab")
		end
	end

	local CORE = { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Chat }
	local coreWas: { [any]: boolean } = {}
	local function setCore(hide: boolean)
		for _, t in ipairs(CORE) do
			pcall(function()
				if hide then
					coreWas[t] = StarterGui:GetCoreGuiEnabled(t)
					StarterGui:SetCoreGuiEnabled(t, false)
				elseif coreWas[t] ~= nil then
					StarterGui:SetCoreGuiEnabled(t, coreWas[t])
					coreWas[t] = nil
				end
			end)
		end
	end

	local function restoreWorld()
		RunService:UnbindFromRenderStep("OverkillHeroSelect")
		bindKeys(false)
		camOn = false
		if rig then
			rig.Model.Parent = nil
		end
		if stage then
			stage.Parent = nil
		end
		local cam = workspace.CurrentCamera
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		cam.CameraType = if saved then saved.Type else Enum.CameraType.Custom
		if hum then
			cam.CameraSubject = hum
		end
		if saved then
			cam.FieldOfView = saved.Fov
			if saved.Type == Enum.CameraType.Custom and saved.CFrame then
				cam.CFrame = saved.CFrame
			end
			for fx, was in pairs(saved.Effects) do
				if fx.Parent then
					fx.Enabled = was
				end
			end
		end
		saved = nil
		setControls(true)
		setCore(false)
	end

	local pendingMorph: any = nil
	local morphFx: (Model, string?) -> () = function() end

	local function close(reason: string?)
		if not open then
			return
		end
		if firstPick and reason == "back" then
			return -- the first visit ends with a pick
		end
		open = false
		dragging = false
		if reason == "overlay" then
			restoreWorld()
			gui.Enabled = false
			fadeSerial += 1
			fade.BackgroundTransparency = 1
			fade.Visible = false
			return
		end
		fadeTo(0, 0.2).Completed:Wait()
		restoreWorld()
		gui.Enabled = false
		firstPick = false
		stamp.Visible = false
		flash.BackgroundTransparency = 1
		if fxFolder then
			fxFolder:ClearAllChildren()
		end
		if ctx.Overlay == "HeroSelect" then
			ctx.SetOverlay(nil)
		end
		task.wait(0.1)
		fadeTo(1, 0.4)
		-- your own transformation flash plays as the world comes back into view
		local pm = pendingMorph
		pendingMorph = nil
		if pm and pm.Char.Parent then
			task.delay(0.12, morphFx, pm.Char, pm.Hero)
		end
	end

	local function openSelect(id: string?, first: boolean?)
		if open or os.clock() < busyUntil then
			return false
		end
		if ctx.Overlay ~= nil or player:GetAttribute("QuestUIOpen") then
			return false
		end
		local start = 1
		local want = id or currentHeroId()
		for i, h in ipairs(HEROES) do
			if h.Id == want then
				start = i
			end
		end
		busyUntil = os.clock() + 1
		open = true
		firstPick = first == true
		picking = false
		closeApi.Button.Visible = not firstPick
		stamp.Visible = false
		flash.BackgroundTransparency = 1
		for _, g in ipairs(backHint) do
			g.Visible = not firstPick
		end
		fade.BackgroundTransparency = 1
		fadeTo(0, 0.28)
		task.delay(0.28, function()
			if open then
				gui.Enabled = true
			end
		end)
		ctx.Close()
		ctx.SetOverlay("HeroSelect")
		task.wait(0.4)
		if not open then
			return false
		end
		local cam = workspace.CurrentCamera
		saved = { Type = cam.CameraType, Fov = cam.FieldOfView, CFrame = cam.CFrame, Effects = {} }
		for _, fx in ipairs(Lighting:GetChildren()) do
			if fx:IsA("DepthOfFieldEffect") or fx:IsA("BlurEffect") then
				saved.Effects[fx] = fx.Enabled
				fx.Enabled = false
			end
		end
		for _, fx in ipairs(cam:GetChildren()) do
			if fx:IsA("DepthOfFieldEffect") or fx:IsA("BlurEffect") then
				saved.Effects[fx] = fx.Enabled
				fx.Enabled = false
			end
		end
		setControls(false)
		setCore(true)
		rescale()
		local st = getStage()
		if st then
			st.Parent = workspace
		end
		anim.Clock = os.clock()
		showHero(start, true)
		camOn = true
		camDolly.Value = 1.12
		frameCamera()
		RunService:BindToRenderStep("OverkillHeroSelect", Enum.RenderPriority.Camera.Value + 1, step)
		bindKeys(true)
		tween(camDolly, 0.9, { Value = 1 }, Enum.EasingStyle.Quint)
		gui.Enabled = true
		fadeTo(1, 0.5)
		for k, p in ipairs({ list, info }) do
			p.Scale.Scale = 0.86
			tween(p.Scale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.05 * k)
		end
		headScale.Scale = 0.7
		tween(headScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		hintScale.Scale = 0.8
		tween(hintScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.12)
		task.delay(0.6, function()
			Kit.playShine(headSheen)
		end)
		Kit.sfx("Open")
		return true
	end

	local function confirm()
		if not open or picking or not rig then
			return
		end
		local h = current()
		if currentHeroId() == h.Id then
			-- already this hero: PLAYING just takes you back into the game, no cheer
			Kit.sfx("Click")
			firstPick = false
			close("back")
			return
		end
		picking = true
		refreshAction()
		local ok, res = pcall(function()
			return HeroRequest:InvokeServer("Pick", h.Id)
		end)
		picking = false
		if not (ok and type(res) == "table" and res.Ok) then
			-- toasts wait while a full-screen overlay is up, so the button says it
			action.SetText(string.upper(if ok and type(res) == "table" and res.Error then res.Error else "Try again"))
			action.SetColor(C.Red, C.RedDeep)
			Kit.shake(action.Body)
			Kit.sfx("Error")
			task.delay(1.4, function()
				if open and not picking then
					refreshAction()
				end
			end)
			return
		end
		-- locked in: the hero winds up and springs into a cheer; the moment they leave the
		-- ground the podium rings out, a sunburst opens behind them and stars burst around them,
		-- then the LOCKED IN plate slams down. After a beat, back into the world as the hero.
		anim.Mode = "cheer"
		anim.T0 = os.clock()
		action.SetText("LOCKED IN!")
		action.SetColor(C.Gold, C.GoldDeep)
		action.Scale.Scale = 0.92
		tween(action.Scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		refreshRows()
		firstPick = false
		local stopRays: (() -> ())? = nil
		task.delay(0.17, function()
			if not open then
				return
			end
			ringWave(h, true)
			stopRays = sunburst(h)
			starBurst(h)
			for _, o in ipairs(orbFx) do
				o.Emitter:Emit(3) -- the orbs flare with the hero
			end
			flash.BackgroundTransparency = 0.6
			tween(flash, 0.45, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
			tween(camDolly, 0.3, { Value = 0.93 }, Enum.EasingStyle.Quart)
			Kit.sfx("Buy")
		end)
		task.delay(0.3, function()
			if open then
				showStamp(h)
			end
		end)
		task.delay(1.25, function()
			if open then
				tween(camDolly, 0.7, { Value = 1 }, Enum.EasingStyle.Quad)
			end
		end)
		task.delay(1.7, function()
			if stopRays then
				stopRays()
			end
		end)
		task.delay(2.05, function()
			if open then
				close("picked")
			end
		end)
	end

	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		rescale()
		if open then
			frameCamera()
		end
	end)
	ctx.On("Scale", function()
		if open then
			frameCamera()
		end
	end)

	ctx.On("HeroSelect", function(id: string?)
		task.spawn(openSelect, id, false)
	end)
	ctx.On("HeroSelectStep", function(dir: number)
		if open and rig and not picking and anim.Mode ~= "cheer" then
			showHero(index + dir)
		end
	end)
	ctx.On("HeroSelectPick", function(i: number)
		if open and rig and not picking and anim.Mode ~= "cheer" and i ~= index and HEROES[i] then
			showHero(i)
		end
	end)
	ctx.On("HeroSelectConfirm", function()
		task.spawn(confirm)
	end)
	ctx.On("HeroSelectClose", function()
		task.spawn(close, "back")
	end)
	closeApi.Button.Activated:Connect(function()
		task.spawn(close, "back")
	end)
	ctx.On("OverlayChanged", function(name: string?)
		if open and name ~= "HeroSelect" and name ~= nil then
			close("overlay")
		end
	end)
	player:GetAttributeChangedSignal("Hero"):Connect(function()
		if open then
			refreshRows()
			refreshAction()
		end
	end)

	---------------------------------------------------------------------------
	-- the HERO pill in the HUD corner: your hero's face, name, and CHANGE
	---------------------------------------------------------------------------
	-- (built in its own function: the select screen's main scope is close to Luau's
	-- 200-register limit, and a nested function gets a fresh register frame)
	local function buildHeroPill()
		-- a round portrait with a double outline: ink ring, a band in the hero's colour, ink ring
		-- again, then the face. Returns the face frame and the band's gradient.
		-- the portrait disc: ink, a gold band, ink again, then the face. The three rings are strokes
		-- on the disc's own circle (Kit.rings), so each is exactly as wide all the way round; the
		-- portrait inside reaches in under the inner ink ring, so its own edge never shows.
		local function doubleRing(parent: Instance, size: number, pos: UDim2, z: number): (Frame, UIGradient, Frame)
			local disc = new("Frame", { Name = "Portrait", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = pos, Size = UDim2.fromOffset(size, size), ZIndex = z, Parent = parent })
			Kit.pill(disc)
			local _, grads = Kit.rings(disc, UDim.new(1, 0), { { 4, C.Ink }, { 5, { Kit.lighten(C.Gold, 0.25), C.GoldDeep, 90 } }, { 3, C.Ink } }, 8)
			return disc, grads[2], disc
		end

		if not ctx.StatusPill then
			return
		end
		do
			local M = ctx.PillMetrics or { BadgeX = 38, BadgeY = 35, TextX = 57, RightPad = 8 }
			local holder, pill, caption, glow = ctx.StatusPill("Hero", 0, "HERO", C.Gold, "Shuriken")
			local face, bandGrad, disc = doubleRing(holder, 72, UDim2.fromOffset(M.BadgeX, M.BadgeY), 5)
			local faceGrad = Kit.gradient(face, Kit.lighten(C.Navy500, 0.1), C.Navy800, 90)
			local discView = new("Frame", { Name = "View", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(52, 52), ZIndex = 7, Parent = face })
			local mystery = Kit.text({ Name = "Mystery", Text = "?", TextSize = 32, Size = UDim2.fromScale(1, 1), ZIndex = 8, Stroke = 3.5, Parent = face })
			local CHANGE_W = 118
			local pillName = if ctx.PillValue then ctx.PillValue(pill, "", C.Gold, M.RightPad + CHANGE_W + 12) else Kit.text({ Text = "", Parent = pill })
			-- CHANGE is the pill's whole right end (see PillAction in the HUD): its outline sits
			-- exactly as far from the pill's top, right and bottom edges
			local change = ctx.PillAction(pill, {
				Name = "Change",
				Width = CHANGE_W,
				Text = "CHANGE",
				TextSize = 21,
				Color = C.Blue,
				Deep = C.BlueDeep,
				HoverScale = 1.08,
				OnClick = function()
					ctx.Fire("HeroSelect")
				end,
			})
			local discBtn = new("TextButton", { Name = "Open", AutoButtonColor = false, Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 9, Parent = disc })
			local discScale = Kit.fx(disc)
			discBtn.MouseEnter:Connect(function()
				tween(discScale, 0.2, { Scale = 1.06 }, Enum.EasingStyle.Back)
			end)
			discBtn.MouseLeave:Connect(function()
				tween(discScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
			end)
			discBtn.Activated:Connect(function()
				ctx.Fire("HeroSelect")
			end)
			local shownId: string? = nil
			local function refreshPill()
				local id = currentHeroId()
				local h = heroById(id)
				if id == shownId then
					return
				end
				local first = shownId == nil
				shownId = id
				for _, c in ipairs(discView:GetChildren()) do
					c:Destroy()
				end
				if h then
					local a, d = accentOf(h)
					bandGrad.Color = ColorSequence.new(Kit.lighten(a, 0.25), d)
					faceGrad.Color = ColorSequence.new(Kit.lighten(a, 0.1), Kit.darken(d, 0.35))
					glow.BackgroundColor3 = a
					caption.Text = string.upper(h.Title or "HERO")
					mystery.Visible = false
					local vp = portrait(discView, h.Id, "face", 7)
					if vp then
						Kit.pill(vp)
					end
					pillName.Text = h.Name
					pillName.TextColor3 = Kit.lighten(a, 0.3)
					change.SetText("CHANGE")
					change.SetColor(C.Blue, C.BlueDeep)
				else
					bandGrad.Color = ColorSequence.new(Kit.lighten(C.Navy500, 0.2), C.Navy700)
					faceGrad.Color = ColorSequence.new(C.Navy600, C.Navy800)
					glow.BackgroundColor3 = C.Gold
					caption.Text = "HERO"
					mystery.Visible = true
					pillName.Text = "PICK A HERO"
					pillName.TextColor3 = C.Gold
					change.SetText("PICK")
					change.SetColor(C.Green, C.GreenDeep)
				end
				if not first then
					discScale.Scale = 0.8
					tween(discScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
				end
			end
			player:GetAttributeChangedSignal("Hero"):Connect(refreshPill)
			refreshPill()
		end
	end
	buildHeroPill()

	---------------------------------------------------------------------------
	-- the transformation flash (everyone sees it when someone becomes a hero)
	---------------------------------------------------------------------------
	morphFx = function(char: Model, heroId: string?)
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return
		end
		local h = heroById(heroId)
		local a = accentOf(h)
		local holder = Instance.new("Part")
		holder.Name = "HeroMorphFlash"
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.Transparency = 1
		holder.Size = Vector3.new(3, 5, 2)
		holder.CFrame = hrp.CFrame
		holder.Parent = workspace
		local burst = emitter(holder, {
			Texture = "rbxasset://textures/particles/sparkles_main.dds",
			Color = ColorSequence.new(Color3.new(1, 1, 1), a),
			LightEmission = 0.7,
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.3) }),
			Lifetime = NumberRange.new(0.4, 0.8),
			Rate = 0,
			Speed = NumberRange.new(8, 16),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 4,
			Shape = Enum.ParticleEmitterShape.Box,
		})
		local puffs = emitter(holder, {
			Texture = "rbxasset://textures/particles/smoke_main.dds",
			Color = ColorSequence.new(Color3.new(1, 1, 1)),
			LightEmission = 0.3,
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 4) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
			Lifetime = NumberRange.new(0.45, 0.7),
			Rate = 0,
			Speed = NumberRange.new(3, 6),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 4,
			Shape = Enum.ParticleEmitterShape.Box,
		})
		burst:Emit(36)
		puffs:Emit(14)
		local light = Instance.new("PointLight")
		light.Color = a
		light.Range = 14
		light.Brightness = 3
		light.Parent = holder
		tween(light, 0.6, { Brightness = 0 }, Enum.EasingStyle.Quad)
		Debris:AddItem(holder, 1.5)
	end
	HeroEvent.OnClientEvent:Connect(function(kind: string, char: Model?, heroId: string?)
		if kind ~= "Morph" or not (char and char:IsA("Model")) then
			return
		end
		if open and char == player.Character then
			pendingMorph = { Char = char, Hero = heroId }
			return
		end
		morphFx(char, heroId)
	end)

	---------------------------------------------------------------------------
	-- first visit: no hero yet -> the select screen opens on its own
	---------------------------------------------------------------------------
	task.spawn(function()
		local t0 = os.clock()
		while not player:GetAttribute("HeroLoaded") and os.clock() - t0 < 30 do
			task.wait(0.25)
		end
		if currentHeroId() ~= "" then
			return
		end
		task.wait(1.2) -- let the world and the HUD settle first
		for _ = 1, 60 do
			if currentHeroId() ~= "" or open then
				return
			end
			if openSelect(nil, true) then
				return
			end
			task.wait(1)
		end
	end)
end
