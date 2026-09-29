--[[
	VitalBars  (StarterPlayerScripts.OverkillHUD.VitalBars)
	The name, health and regen reserve over every fighter's head, in place of Roblox's own name and
	health bar (CombatService turns those off on every fighter; the HUD turns off the corner one).
	Built from the HUD's own parts, so it reads as one of its plates (Kit.titlePlate): a dark panel
	with a coloured rim inside its heavy ink outline and a round icon tile in its left end, a soft
	drop shadow under it, at the HUD's scale (a little smaller with distance):

	  name     the fighter's display name over the plate (never over your own head)
	  tile     a white cross on a gem in the fighter's state colour: the health's colour, TEAL while
	           it heals (its heart: the cross beats and a ring rings out once a second), grey once the
	           reserve is spent
	  rim      the same state colour round the plate: health's colour, teal while healing, beating red
	           in danger, a white flash with a blow
	  health   the plate's main bar (the HUD's bar: an inked capsule, the number on it): green, gold at
	           half, red at the line an arm comes off (Config.Gore.Stages[1]). A blow leaves a hot chunk
	           where the health was that drains after it, a glint at the fill's end, the whole block
	           jolts, the number punches up red. From the last arm's line (Stages[2]) it beats: a red
	           glow, the rim and the fill pulse, faster as the head's line (Stages[3]) comes near
	  reserve  (a player) the slim bar under it: the regen reserve left (Config.Regen - the Reserve
	           attribute). While the fight is on it is dim, brightening as the Delay runs out
	  mend     (a player) a faint teal stretch of the health bar past the fill: the health the reserve
	           will still give back (as much as it holds, up to full). Dim while the fight is on, bright
	           while it heals - the fill grows into it
	  healing  it all turns: tile and rim to teal, the tile's heart beating, a teal glow on the health's
	           growing end, "+N" rising off the tile each beat, teal motes rising off the body

	The moments (everyone sees them on everyone):
	  cut off    a blow while healing: the tile and the reserve flash red, the teal drains away
	  full again the plate's shine sweeps across, the tile rings out, a teal ring bursts round the body
	  spent      the tile goes grey, the plate gives one last kick
	And on YOUR screen: a blow flashes the screen's edge red (harder the bigger it was); from the
	last arm's line the edge beats red with the plate and the world drains of colour, more the
	nearer the head's line; healing, the edge breathes teal; full again, one teal flash; the
	moments sound (the HUD's own sounds).

	It rides on the torso (steady through every swing of the head), just clear of the highest thing
	on the head - hair, a hat - whatever the hero wears. Over every fighter in reach (the players'
	characters and the practice dummies); gone when down. The limb tag stays over it (LimbStatus
	reads ctx.Vitals).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Combat = ReplicatedStorage:WaitForChild("Combat")
local Config = require(Combat:WaitForChild("CombatConfig"))
local VFX = require(Combat:WaitForChild("CombatVFX"))

return function(ctx: any)
	local Kit, Theme = ctx.Kit, ctx.Theme
	local C = Theme.C
	local new, tween = Kit.new, Kit.tween
	local player = ctx.Player

	-- the block (px at the HUD's scale)
	local W = 176
	local PLATE_H, PLATE_H_SOLO = 36, 30 -- (with the reserve bar / without: a dummy)
	local RADIUS = 12
	local RIM = 4.5 -- the state-coloured rim inside the outline (the outline covers its outer half)
	local OUTLINE = 3 -- (Kit.stroke units)
	local TILE_GAP = 7 -- plate edge to the tile's outline (clear of the rim)
	local BAR_L, BAR_R = 4, 9 -- the bars: after the tile, and short of the right end
	local HP_H, RG_H, ROW = 15, 5, 3
	local HP_H_SOLO = 16
	local NAME_H, NAME_GAP = 20, 3
	local SHADOW = 3 -- px the drop shadow sits under the plate
	local BOTTOM = 4 -- (air over the hair)
	local RISE = 30 -- px the "+N" floats up
	-- where it rides: over the torso's middle, CLEAR studs over the highest thing on the head
	local CLEAR = 0.35
	local LINE_MIN, LINE_MAX = 2.4, 5.5
	local HEAD_LINE = 1.25 -- (a body with no torso: over the head's middle)
	local REACH = 100 -- studs: nothing farther (Roblox's own reach)

	local HP_LOW = Config.Gore.Stages[1] -- red from here: the next blows take an arm
	local HP_MID = 0.5
	-- the danger beat: from the line the last arm goes at (Stages[2]) down to the head's (Stages[3])
	local DANGER, HEAD = Config.Gore.Stages[2], Config.Gore.Stages[3]
	local BEAT_SLOW, BEAT_FAST = 1.3, 2.6 -- beats a second at the top of it / at the head's line
	local TIERS = {
		{ C.Green, C.GreenDeep },
		{ C.Gold, C.GoldDeep },
		{ C.Red, C.RedDeep },
	}
	local HEAL = { C.Teal, C.TealDeep }
	local SPENT = { C.Grey, C.GreyDeep }
	local PANEL = { C.Navy800, C.Night, 90 }
	local RG = Config.Regen
	local DIM = Color3.fromRGB(110, 118, 140) -- (the reserve while the fight is on: x its teal)
	local HOT = Color3.fromRGB(255, 132, 96) -- (the chunk a blow leaves, once its white flash is gone)
	local HEART = 1 -- seconds between the healing heart's beats (and the "+N" off the tile)
	local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

	-- (every fill: a lit top, its colour, a deep bottom)
	local function paint(c: Color3, deep: Color3): ColorSequence
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(c, 0.28)),
			ColorSequenceKeypoint.new(0.5, c),
			ColorSequenceKeypoint.new(1, deep),
		})
	end
	local function mix(a: { Color3 }, b: { Color3 }, t: number): (Color3, Color3)
		return a[1]:Lerp(b[1], t), a[2]:Lerp(b[2], t)
	end

	---------------------------------------------------------------------------
	-- a bar (the HUD's own: Kit.bar): an inked capsule, the chunk a blow leaves under the fill, the
	-- fill with its flash, the outline over it all
	---------------------------------------------------------------------------
	local function bar(parent: GuiObject, name: string, x: number, y: number, w: number, h: number, z: number, stroke: number)
		local track = new("Frame", {
			Name = name,
			BackgroundColor3 = C.Night,
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(w, h),
			ZIndex = z,
			Parent = parent,
		})
		Kit.pill(track)
		-- (recessed: darker at the top, where the plate's edge would shade it)
		Kit.gradient(track, Color3.fromRGB(6, 10, 20), C.Night, 90)
		track.BackgroundColor3 = Color3.new(1, 1, 1)
		local function capsule(n: string, zz: number): Frame
			local f = new("Frame", { Name = n, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = zz, Parent = track })
			Kit.pill(f)
			-- (a short fill is still a whole capsule, never a squashed dot)
			new("UISizeConstraint", { MinSize = Vector2.new(h, 0), Parent = f })
			return f
		end
		local trail = capsule("Trail", z + 1)
		trail.Visible = false
		local fill = capsule("Fill", z + 2)
		local grad = new("UIGradient", { Rotation = 90, Color = paint(C.Green, C.GreenDeep), Parent = fill })
		local flash = new("Frame", { Name = "Flash", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z + 3, Parent = fill })
		Kit.pill(flash)
		-- the outline over the fill (as thick along the filled part as along the empty part)
		Kit.stroke(track, stroke, C.Ink, 0, true)
		Kit.outlineOnTop(track, z + 5)
		return { Track = track, Trail = trail, Fill = fill, Grad = grad, Flash = flash }
	end

	---------------------------------------------------------------------------
	-- one fighter's block
	---------------------------------------------------------------------------
	type Vital = {
		Char: Model,
		Hum: Humanoid,
		Part: BasePart,
		Line: number,
		LineDirty: boolean,
		Gui: BillboardGui,
		Fit: UIScale,
		Body: Frame,
		Pop: UIScale,
		Kick: UIScale,
		Height: number, -- px at fit 1
		FitNow: number,
		Hp: any,
		HpText: TextLabel,
		TextPop: UIScale,
		Glint: ImageLabel, -- (white at the fill's end: a blow's hit)
		Mend: ImageLabel, -- (teal at the fill's end: the health growing)
		Rg: any?,
		Ahead: Frame?, -- (the health the reserve will give back, past the fill)
		AheadAt: number,
		AheadLit: number,
		RimGrad: UIGradient,
		TileGrad: UIGradient,
		Cross: Frame,
		CrossPop: UIScale,
		CrossBars: { Frame },
		Ring: ImageLabel, -- (the tile's heartbeat ring)
		Sheen: Frame,
		Glow: ImageLabel, -- (red behind the plate: the danger beat)
		-- live values: health and reserve as shares, shown (animated) and real
		Health: number,
		Shown: number,
		TrailAt: number,
		TrailHold: number,
		Tier: number,
		Reserve: number,
		ReserveShown: number,
		Spent: boolean,
		RegenAt: number,
		Healing: boolean,
		HealMix: number, -- 0..1: how far into its teal the block has turned
		Lit: number,
		HealAcc: number, -- health healed since the last "+N" (points)
		HeartAt: number,
		Floaters: { TextLabel },
		NextFloater: number,
		Motes: ParticleEmitter?, -- (the healing motes rising off the body)
		Beat: number, -- the danger beat's phase (-1: not beating)
		Hurt: number, -- the white flash of the last blow on the rim (fading)
		Shake: number, -- px the block jolts sideways (fading)
		Paint: number, -- (the state last painted, packed: nothing rewritten while it holds)
		LiftPx: number, -- climbing clear of a nearer fighter's block on screen (px, and in studs)
		Lift: number,
		Down: boolean,
		Serial: number,
		Conns: { RBXScriptConnection },
	}
	local vitals: { [Model]: Vital } = {}

	-- the body parts that aren't worn on the head (everything else on the character - hair, hats, a
	-- hero's loose hair part - counts toward how high the block rides)
	local LIMB = { Torso = true, HumanoidRootPart = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true, UpperTorso = true, LowerTorso = true }
	local function topOf(p: BasePart): number
		local cf, s = p.CFrame, p.Size * 0.5
		return cf.Position.Y + math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z
	end
	local function lineOf(char: Model, part: BasePart): number
		if LIMB[part.Name] == nil then
			return HEAD_LINE
		end
		local top = part.Position.Y + 2 -- (an R6 head's top)
		for _, c in ipairs(char:GetChildren()) do
			local p: Instance? = if c:IsA("Accessory") then c:FindFirstChild("Handle") else c
			if p and p:IsA("BasePart") and not LIMB[p.Name] and p.Transparency < 1 and p:GetAttribute("OverkillGore") == nil then
				top = math.max(top, topOf(p))
			end
		end
		return math.clamp(top - part.Position.Y + CLEAR, LINE_MIN, LINE_MAX)
	end

	local function partOf(char: Model): BasePart?
		local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Head")
		return if torso and torso:IsA("BasePart") then torso else nil
	end

	local function nameOf(char: Model, hum: Humanoid): string?
		if char == player.Character then
			return nil -- (your own name is never over your own head)
		end
		local p = Players:GetPlayerFromCharacter(char)
		return if p then p.DisplayName else (if hum.DisplayName ~= "" then hum.DisplayName else char.Name)
	end

	local function tierOf(k: number): number
		return if k <= HP_LOW then 3 elseif k <= HP_MID then 2 else 1
	end

	local function glowImage(parent: GuiObject, color: Color3, size: UDim2, z: number): ImageLabel
		return Kit.image({
			Name = "Glow",
			Image = Theme.Icon.Glow,
			ImageColor3 = color,
			ImageTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = size,
			ZIndex = z,
			Parent = parent,
		})
	end

	local function build(char: Model, hum: Humanoid, part: BasePart): Vital
		local hasRegen = char:GetAttribute("Reserve") ~= nil
		local name = nameOf(char, hum)
		local plateH = if hasRegen then PLATE_H else PLATE_H_SOLO
		local nameH = if name then NAME_H + NAME_GAP else 0
		local height = nameH + plateH + SHADOW + BOTTOM
		local line = lineOf(char, part)
		local gui = new("BillboardGui", {
			Name = "Vitals",
			-- (the block's bottom sits on the billboard's middle, the point it rides. A billboard clips
			-- what it holds: sized with the block - canvas() - with room for its pops and glows)
			Size = UDim2.fromOffset(W, height),
			StudsOffset = Vector3.new(0, line, 0),
			ClipsDescendants = false,
			AlwaysOnTop = true,
			LightInfluence = 0,
			MaxDistance = REACH,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			Adornee = part,
			Parent = part,
		})
		local stage = new("Frame", { Name = "Stage", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(W, height), Parent = gui })
		local fit = new("UIScale", { Name = "Fit", Parent = stage })
		local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(1, 1), Parent = stage })
		local pop = new("UIScale", { Name = "Pop", Parent = body })
		if name then
			local label = Kit.text({
				Name = "Name",
				Text = name,
				TextSize = 19,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.new(1, 60, 0, NAME_H),
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 20,
				Stroke = 2.2,
				Parent = body,
			})
			Kit.gradient(label, Color3.new(1, 1, 1), Color3.fromRGB(200, 218, 255), 90)
		end
		local plateY = nameH + plateH / 2
		-- the soft shadow the plate throws, and behind it the danger beat's red glow
		local shadow = new("Frame", {
			Name = "Shadow",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.45,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, plateY + SHADOW),
			Size = UDim2.fromOffset(W, plateH),
			ZIndex = 2,
			Parent = body,
		})
		Kit.corner(shadow, RADIUS)
		local glow = glowImage(body, C.Red, UDim2.fromOffset(W + 70, plateH + 50), 1)
		glow.Position = UDim2.new(0.5, 0, 0, plateY)
		glow.Visible = false
		-- the plate: the HUD's dark panel (the part a blow kicks)
		local plate = new("Frame", {
			Name = "Plate",
			BackgroundColor3 = Color3.new(1, 1, 1),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, plateY),
			Size = UDim2.fromOffset(W, plateH),
			ZIndex = 3,
			Parent = body,
		})
		Kit.corner(plate, RADIUS)
		Kit.paint(plate, PANEL)
		local kick = new("UIScale", { Name = "Kick", Parent = plate })
		local sheen = Kit.addShine(plate, RADIUS)
		sheen.ZIndex = 12
		-- the tile: the plate's whole left end (Kit.endIcon), a white cross on its gem
		local tile = Kit.endIcon({
			Parent = plate,
			Name = "Tile",
			Side = "Left",
			Width = plateH,
			Gap = TILE_GAP,
			Stroke = 2.4,
			Band = PANEL,
			Face = { Kit.lighten(C.Green, 0.2), C.GreenDeep, 90 },
			ZIndex = 4,
		})
		-- (an even size: the cross, its arms and its outline all land on whole pixels round the tile's
		-- centre - every arm the same length, dead centre in the gem)
		local crossSize = 2 * math.floor((plateH - TILE_GAP * 2) * 0.275 + 0.5)
		local cross = Kit.plusGlyph(tile.Frame, crossSize, tile.ContentZ, Color3.new(1, 1, 1))
		local crossBars = {}
		for _, b in ipairs(cross:GetChildren()) do
			if b.Name == "Bar" then
				table.insert(crossBars, b)
			end
		end
		-- the tile's heartbeat ring (under the plate: it rings out past its edge)
		local ring = glowImage(body, C.Teal, UDim2.fromOffset(plateH, plateH), 2)
		ring.Position = UDim2.new(0, plateH / 2, 0, plateY)
		ring:SetAttribute("Base", plateH)
		-- the rim in the state's colour and the ink outline, on the plate's own edge, over the tile's end
		local _, rimGrads = Kit.rings(plate, RADIUS, { { RIM, { Kit.lighten(C.Green, 0.15), C.GreenDeep, 90 } } }, 10)
		local outline = new("Frame", { Name = "Outline", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = plate })
		Kit.corner(outline, RADIUS)
		Kit.stroke(outline, OUTLINE, C.Ink, 0, true)
		-- the bars
		local barX = plateH + BAR_L
		local barW = W - barX - BAR_R
		local hpH = if hasRegen then HP_H else HP_H_SOLO
		local hpY = if hasRegen then (plateH - (HP_H + ROW + RG_H)) / 2 else (plateH - hpH) / 2
		local hp = bar(plate, "Health", barX, hpY, barW, hpH, 4, 2)
		Kit.gradient(hp.Trail, Color3.new(1, 1, 1), Color3.fromRGB(255, 214, 190), 90)
		-- (the end of the fill: a blow's glint, the healing's glow)
		local glint = glowImage(hp.Track, Color3.new(1, 1, 1), UDim2.fromOffset(hpH * 1.6, hpH * 2.2), 8)
		local mend = glowImage(hp.Track, Kit.lighten(C.Teal, 0.3), UDim2.fromOffset(hpH * 1.8, hpH * 2.4), 8)
		local hpText = Kit.text({
			Name = "Value",
			Text = "",
			TextSize = 14,
			FontFace = Theme.Font.Heavy,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(60, hpH),
			ZIndex = 10,
			Stroke = 2.2,
			Parent = hp.Track,
		})
		local v: Vital = {
			Char = char,
			Hum = hum,
			Part = part,
			Line = line,
			LineDirty = false,
			Gui = gui,
			Fit = fit,
			Body = body,
			Pop = pop,
			Kick = kick,
			Height = height,
			FitNow = -1,
			Hp = hp,
			HpText = hpText,
			TextPop = new("UIScale", { Parent = hpText }),
			Glint = glint,
			Mend = mend,
			Rg = nil,
			Ahead = nil,
			AheadAt = -1,
			AheadLit = -1,
			RimGrad = rimGrads[1],
			TileGrad = tile.Face,
			Cross = cross,
			CrossPop = new("UIScale", { Parent = cross }),
			CrossBars = crossBars,
			Ring = ring,
			Sheen = sheen,
			Glow = glow,
			Health = 1,
			Shown = 1,
			TrailAt = 1,
			TrailHold = 0,
			Tier = 0,
			Reserve = 1,
			ReserveShown = 1,
			Spent = false,
			RegenAt = 0,
			Healing = false,
			HealMix = 0,
			Lit = -1,
			HealAcc = 0,
			HeartAt = 0,
			Floaters = {},
			NextFloater = 1,
			Motes = nil,
			Beat = -1,
			Hurt = 0,
			Shake = 0,
			Paint = -1,
			LiftPx = 0,
			Lift = 0,
			Down = false,
			Serial = 0,
			Conns = {},
		}
		if hasRegen then
			-- the health the reserve will give back: a capsule from the bar's start (the fill covers the
			-- health already there), under the blow's chunk and the fill
			local ahead = new("Frame", { Name = "Ahead", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 4, Visible = false, Parent = hp.Track })
			Kit.pill(ahead)
			new("UISizeConstraint", { MinSize = Vector2.new(hpH, 0), Parent = ahead })
			Kit.gradient(ahead, Kit.lighten(C.Teal, 0.35), C.TealDeep, 90)
			hp.Trail.ZIndex = 5
			v.Ahead = ahead
			local rg = bar(plate, "Regen", barX, hpY + HP_H + ROW, barW, RG_H, 4, 1.4)
			rg.Grad.Color = paint(C.Teal, C.TealDeep)
			rg.Flash.BackgroundColor3 = C.Red -- (its flash: cut off by a blow while healing)
			v.Rg = rg
			-- "+N" rising off the tile while it heals (a pool of three)
			for i = 1, 3 do
				local f = Kit.text({
					Name = "Heal" .. i,
					Text = "",
					TextSize = 16,
					TextColor3 = Kit.lighten(C.Teal, 0.4),
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0, plateH / 2, 0, nameH + 4),
					Size = UDim2.fromOffset(50, 18),
					TextTransparency = 1,
					ZIndex = 21,
					Stroke = 2,
					StrokeTransparency = 1,
					Parent = body,
				})
				table.insert(v.Floaters, f)
			end
			-- the healing motes: soft teal sparkles rising off the torso
			v.Motes = new("ParticleEmitter", {
				Name = "OverkillHealMotes",
				Texture = SPARKLE,
				Color = ColorSequence.new(Kit.lighten(C.Teal, 0.4), C.Teal),
				LightEmission = 1,
				LightInfluence = 0,
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 0.45, 0.1), NumberSequenceKeypoint.new(1, 0) }),
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
				Lifetime = NumberRange.new(0.8, 1.3),
				Speed = NumberRange.new(2.5, 4.5),
				Acceleration = Vector3.new(0, 1.5, 0),
				Drag = 1.5,
				SpreadAngle = Vector2.new(25, 25),
				EmissionDirection = Enum.NormalId.Top,
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-90, 90),
				Rate = 9,
				Enabled = false,
				Parent = part,
			})
		end
		return v
	end

	---------------------------------------------------------------------------
	-- the state colours: tile and rim (health's tier, turned toward teal while healing, beating red
	-- in danger, grey tile once spent, the rim white with a blow). Written only when they change.
	---------------------------------------------------------------------------
	local function repaint(v: Vital, beat: number)
		local base = if v.Tier > 0 then TIERS[v.Tier] else TIERS[1]
		local m = v.HealMix
		local hurt = v.Hurt
		-- (each share to 1/64: finer than the eye can tell apart)
		local key = ((((v.Tier * 2 + (if v.Spent then 1 else 0)) * 65 + math.floor(m * 64)) * 65 + math.floor(beat * 64)) * 65) + math.floor(hurt * 64)
		if key == v.Paint then
			return
		end
		v.Paint = key
		-- tile: the state's gem
		local t1, t2 = mix(base, HEAL, m)
		if v.Spent then
			t1, t2 = SPENT[1], SPENT[2]
		end
		v.TileGrad.Color = ColorSequence.new(Kit.lighten(t1, 0.2), t2)
		-- rim: the same, brightened by the danger beat, whitened by a blow
		local r1, r2 = mix(base, HEAL, m)
		if beat > 0 then
			r1, r2 = r1:Lerp(Kit.lighten(C.Red, 0.35), beat * (1 - m)), r2:Lerp(C.Red, beat * (1 - m))
		end
		if hurt > 0 then
			r1, r2 = r1:Lerp(Color3.new(1, 1, 1), hurt), r2:Lerp(Color3.new(1, 1, 1), hurt * 0.7)
		end
		v.RimGrad.Color = ColorSequence.new(Kit.lighten(r1, 0.15), r2)
	end

	---------------------------------------------------------------------------
	-- the numbers in (events), the bars move (the render step)
	---------------------------------------------------------------------------
	-- the bars straight to the numbers (a new block, or one coming back into sight)
	local function snap(v: Vital)
		if v.Shown ~= v.Health or v.TrailAt ~= v.Health or v.Hp.Trail.Visible then
			v.Shown, v.TrailAt = v.Health, v.Health
			v.Hp.Fill.Size = UDim2.fromScale(v.Health, 1)
			v.Hp.Fill.Visible = v.Health > 0.001
			v.Hp.Trail.Visible = false
		end
		if v.Rg and v.ReserveShown ~= v.Reserve then
			v.ReserveShown = v.Reserve
			v.Rg.Fill.Size = UDim2.fromScale(v.Reserve, 1)
			v.Rg.Fill.Visible = v.Reserve > 0.001
		end
	end

	---------------------------------------------------------------------------
	-- YOUR screen answers your body: its edge flashes red with a blow, beats red in danger (and the
	-- world drains of colour), breathes teal while healing, flashes teal when full again
	---------------------------------------------------------------------------
	local screen = new("ScreenGui", { Name = "OverkillVitalsScreen", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = -10, Parent = player:WaitForChild("PlayerGui") })
	local EDGE = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.4, 0.7), NumberSequenceKeypoint.new(1, 1) })
	-- a soft band along each edge of the screen, fading inward: one tint, one strength
	local function vignette(color: Color3): { Frame }
		local out = {}
		for _, e in ipairs({
			{ Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.fromScale(1, 0.3), 90 },
			{ Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.fromScale(1, 0.3), 270 },
			{ Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.fromScale(0.2, 1), 0 },
			{ Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.fromScale(0.2, 1), 180 },
		}) do
			local f = new("Frame", { BackgroundColor3 = color, BackgroundTransparency = 1, BorderSizePixel = 0, AnchorPoint = e[1], Position = e[2], Size = e[3], Parent = screen })
			new("UIGradient", { Rotation = e[4], Transparency = EDGE, Parent = f })
			table.insert(out, f)
		end
		return out
	end
	local redEdge = vignette(Color3.fromRGB(190, 12, 24))
	local tealEdge = vignette(C.Teal)
	local cc = Lighting:FindFirstChild("OverkillVitals")
	if not (cc and cc:IsA("ColorCorrectionEffect")) then
		cc = new("ColorCorrectionEffect", { Name = "OverkillVitals", Parent = Lighting })
	end
	local hurt, flash = 0, 0 -- (the red of the last blow, the teal of full health: both fading)
	local shown = { Red = -1, Teal = -1, Drain = -1 }
	local function setEdge(list: { Frame }, a: number, key: string)
		if math.abs(a - shown[key]) > 0.004 then
			shown[key] = a
			for _, f in ipairs(list) do
				f.BackgroundTransparency = 1 - a
			end
		end
	end
	local function screenHit(share: number)
		hurt = math.max(hurt, math.clamp(0.28 + share * 3, 0.28, 0.75))
	end
	-- (v: your own block, or nil - down, between lives)
	local function screenStep(v: Vital?, dt: number, clock: number)
		hurt *= math.exp(-dt * 4.5)
		flash *= math.exp(-dt * 3.5)
		local danger, drain, glow = 0, 0, 0
		if v and not v.Down then
			if v.Beat >= 0 then
				local near = 1 - math.clamp((v.Health - HEAD) / math.max(DANGER - HEAD, 1e-3), 0, 1)
				danger = (0.22 + 0.2 * near) * (0.45 + 0.55 * math.sin(v.Beat * math.pi) ^ 2)
			end
			drain = 1 - math.clamp((v.Health - HEAD) / math.max(HP_LOW - HEAD, 1e-3), 0, 1)
			if v.Healing then
				local k = ((clock - v.HeartAt) / HEART) % 1
				glow = v.HealMix * (0.08 + 0.08 * (1 - k) ^ 2)
			end
		end
		setEdge(redEdge, math.max(hurt, danger), "Red")
		setEdge(tealEdge, math.max(glow, flash), "Teal")
		if math.abs(drain - shown.Drain) > 0.004 then
			shown.Drain = drain
			cc.Saturation = -0.45 * drain
			cc.Contrast = 0.08 * drain
			cc.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 214, 214), drain)
		end
	end

	-- the tile rings out: its cross beats and a ring of its colour spreads past the plate
	local function ringOut(v: Vital, color: Color3, big: number)
		v.CrossPop.Scale = 1.35
		tween(v.CrossPop, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		local ring = v.Ring
		local s = ring:GetAttribute("Base") :: number
		ring.ImageColor3 = color
		ring.Size = UDim2.fromOffset(s, s)
		ring.ImageTransparency = 0.25
		local grow = s * big
		tween(ring, 0.6, { Size = UDim2.fromOffset(grow, grow), ImageTransparency = 1 }, Enum.EasingStyle.Quad).Completed:Once(function()
			ring.Size = UDim2.fromOffset(s, s)
		end)
	end

	-- full health again, off the reserve: the plate's shine sweeps across, the tile rings out, a teal
	-- ring bursts round the body (and on your own screen, a teal flash and the HUD's chime)
	local function fullBurst(v: Vital)
		Kit.playShine(v.Sheen)
		v.Hp.Flash.BackgroundTransparency = 0.2
		tween(v.Hp.Flash, 0.45, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		ringOut(v, Kit.lighten(C.Teal, 0.3), 3)
		v.Kick.Scale = 1.05
		tween(v.Kick, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		VFX.Play("HealBurst", CFrame.new(v.Part.Position), { Scale = 0.6, Only = { ShockWave = true, Stars = true } })
		if v.Char == player.Character then
			flash = 0.45
			Kit.sfx("Buy")
		end
	end

	-- one beat of the healing heart: the tile rings, "+N" rises off it
	local function heartbeat(v: Vital, amount: number)
		ringOut(v, C.Teal, 2.2)
		local f = v.Floaters[v.NextFloater]
		if not f or amount < 1 then
			return
		end
		v.NextFloater = v.NextFloater % #v.Floaters + 1
		local home = f:GetAttribute("Home") or f.Position
		f:SetAttribute("Home", home)
		local st = f:FindFirstChildOfClass("UIStroke")
		f.Text = "+" .. tostring(amount)
		f.Position = home
		f.TextTransparency = 0
		if st then
			st.Transparency = 0
		end
		local pop = f:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = f })
		pop.Scale = 0.6
		tween(pop, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(f, 0.9, { Position = home - UDim2.fromOffset(0, RISE) }, Enum.EasingStyle.Quad)
		tween(f, 0.35, { TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0.55)
		if st then
			tween(st, 0.35, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0.55)
		end
	end

	local function readHealth(v: Vital, fresh: boolean?)
		local hum = v.Hum
		local k = if hum.MaxHealth > 0 then math.clamp(hum.Health / hum.MaxHealth, 0, 1) else 0
		local was = v.Health
		v.Health = k
		v.HpText.Text = tostring(math.max(0, math.ceil(hum.Health - 1e-3)))
		v.Tier = tierOf(k)
		if fresh then
			v.Hp.Grad.Color = paint(TIERS[v.Tier][1], TIERS[v.Tier][2])
			return
		end
		if k > was + 1e-4 then
			v.HealAcc += (k - was) * hum.MaxHealth
			if k >= 0.9999 and v.Healing then
				fullBurst(v)
			end
		end
		if k < was - 1e-4 then
			local share = was - k
			if v.Char == player.Character then
				screenHit(share)
			end
			-- cut off while healing: the tile and the reserve flash red
			if v.Healing and v.Rg then
				v.Rg.Flash.BackgroundTransparency = 0.15
				tween(v.Rg.Flash, 0.35, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
				ringOut(v, C.Red, 1.8)
			end
			-- a blow: the hot chunk stays where the health was a moment, a glint at the fill's end, the
			-- block jolts, the rim flashes white
			if v.TrailAt < v.Shown or not v.Hp.Trail.Visible then
				v.TrailAt = v.Shown
			end
			v.TrailHold = os.clock() + 0.32
			local trail = v.Hp.Trail
			trail.Visible = true
			trail.Size = UDim2.fromScale(v.TrailAt, 1)
			trail.BackgroundColor3 = Color3.new(1, 1, 1)
			tween(trail, 0.3, { BackgroundColor3 = HOT }, Enum.EasingStyle.Quad)
			v.Glint.Position = UDim2.fromScale(v.Shown, 0.5)
			v.Glint.ImageTransparency = 0.05
			tween(v.Glint, 0.3, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
			v.Shake = math.max(v.Shake, math.clamp(3 + share * 40, 3, 9))
			v.Hurt = 1
			v.Kick.Scale = 1.04
			tween(v.Kick, 0.24, { Scale = 1 }, Enum.EasingStyle.Back)
			-- the number takes the blow: it punches up, flashes red, settles white
			v.TextPop.Scale = 1.4
			tween(v.TextPop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			v.HpText.TextColor3 = Kit.lighten(C.Red, 0.25)
			tween(v.HpText, 0.35, { TextColor3 = C.Text }, Enum.EasingStyle.Quad)
			-- ...and the fill flashes white (the danger beat takes the flash over when it runs)
			if v.Beat < 0 then
				v.Hp.Flash.BackgroundTransparency = 0.25
				tween(v.Hp.Flash, 0.22, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
			end
		end
		local c = TIERS[v.Tier]
		v.Hp.Grad.Color = paint(c[1], c[2])
	end

	local function readReserve(v: Vital, fresh: boolean?)
		local r = v.Char:GetAttribute("Reserve")
		local k = if type(r) == "number" then math.clamp(r / RG.Reserve, 0, 1) else 0
		v.Reserve = k
		local at = v.Char:GetAttribute("RegenAt")
		v.RegenAt = if type(at) == "number" then at else 0
		local spent = k <= 0
		if spent ~= v.Spent then
			v.Spent = spent
			for _, b in ipairs(v.CrossBars) do
				b.BackgroundColor3 = if spent then C.TextDim else Color3.new(1, 1, 1)
			end
			if spent and not fresh then
				-- the last of it: the tile goes grey, the plate gives one last kick
				v.Kick.Scale = 1.05
				tween(v.Kick, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
				if v.Char == player.Character then
					Kit.sfx("Error")
				end
			end
		end
	end

	-- in and out: a pop, never a blink
	local function show(v: Vital, on: boolean)
		v.Serial += 1
		if on then
			v.Down = false
			v.Gui.Enabled = true
			v.Pop.Scale = 0.6
			tween(v.Pop, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
		elseif v.Gui.Enabled and not v.Down then
			v.Down = true
			if v.Motes then
				v.Motes.Enabled = false
			end
			local s = v.Serial
			tween(v.Pop, 0.18, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
			task.delay(0.2, function()
				if v.Serial == s then
					v.Gui.Enabled = false
				end
			end)
		end
	end

	local function drop(char: Model)
		local v = vitals[char]
		if v then
			vitals[char] = nil
			for _, c in ipairs(v.Conns) do
				c:Disconnect()
			end
			v.Gui:Destroy()
			if v.Motes then
				v.Motes:Destroy()
			end
		end
	end

	local function track(char: Model)
		if vitals[char] then
			return
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local part = partOf(char)
		if not (hum and part) or hum.Health <= 0 then
			return
		end
		local v = build(char, hum, part)
		vitals[char] = v
		readHealth(v, true)
		if v.Rg then
			readReserve(v, true)
		end
		repaint(v, 0)
		-- (built empty: the first snap fills it)
		v.Shown, v.ReserveShown = -1, -1
		snap(v)
		table.insert(v.Conns, hum.HealthChanged:Connect(function()
			readHealth(v)
			if hum.Health <= 0 then
				show(v, false)
			end
		end))
		table.insert(v.Conns, hum.Died:Connect(function()
			show(v, false)
		end))
		if v.Rg then
			table.insert(v.Conns, char:GetAttributeChangedSignal("Reserve"):Connect(function()
				readReserve(v)
			end))
			table.insert(v.Conns, char:GetAttributeChangedSignal("RegenAt"):Connect(function()
				readReserve(v)
			end))
		end
		-- (a hero dressed after spawning - its hair, a hat: the block rides over it)
		table.insert(v.Conns, char.ChildAdded:Connect(function()
			v.LineDirty = true
		end))
		table.insert(v.Conns, char.ChildRemoved:Connect(function()
			v.LineDirty = true
		end))
		table.insert(v.Conns, char.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				drop(char)
			end
		end))
		show(v, true)
	end

	-- the fighters (the combat's own list: every player's character and the practice dummies)
	local function scan()
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			if c and c:GetAttribute("CombatEntity") then
				track(c)
			end
		end
		local dummies = workspace:FindFirstChild("PracticeDummies")
		if dummies then
			for _, m in ipairs(dummies:GetChildren()) do
				if m:IsA("Model") and m:GetAttribute("CombatEntity") then
					track(m)
				end
			end
		end
		for _, v in pairs(vitals) do
			if v.LineDirty and not v.Down then
				v.LineDirty = false
				v.Line = lineOf(v.Char, v.Part)
				v.Gui.StudsOffset = Vector3.new(0, v.Line + v.Lift, 0)
			end
		end
	end
	task.spawn(function()
		while true do
			scan()
			task.wait(0.3)
		end
	end)

	-- (for the limb tag over the block: its bottom over the head, and its height on screen right now)
	ctx.Vitals = {
		Top = function(char: Model): (number, number)
			local v = vitals[char]
			if not (v and v.Gui.Enabled and v.FitNow > 0) then
				return 0, 0
			end
			local head = char:FindFirstChild("Head")
			local line = v.Line + v.Lift
			local over = if head and head:IsA("BasePart") then v.Part.Position.Y + line - head.Position.Y else line
			return over, v.Height * v.FitNow * v.Pop.Scale
		end,
	}

	---------------------------------------------------------------------------
	-- every frame, after the camera: the size for the distance, the bars moving
	---------------------------------------------------------------------------
	local function canvas(v: Vital, f: number)
		v.Gui.Size = UDim2.fromOffset(math.ceil((W + 80) * f * 1.2), math.ceil((v.Height + RISE + 20) * 2 * f * 1.2))
	end
	local function ease(rate: number, dt: number): number
		return 1 - math.exp(-rate * dt)
	end
	-- two blocks on screen at once (you and the fighter in front of you, two dummies in a row): the
	-- nearer one keeps its place, each farther one climbs until it clears every block already placed
	-- (the hit tags' rule) - never two plates drawn through each other
	local GAP = 6
	type Placed = { V: Vital, Depth: number, X: number, Bottom: number, Half: number, Up: number, PerPx: number }
	local placed: { Placed } = {}
	local function byDepth(a: Placed, b: Placed): boolean
		return a.Depth < b.Depth
	end
	-- what a block does whether or not it is on screen (so your own screen follows your body even in
	-- first person): the danger beat, the reserve, healing and its moments, the state colours
	local function pulse(v: Vital, mine: boolean, dt: number, clock: number, serverNow: number)
		local hp = v.Hp
		-- the danger beat
		local beat = 0
		if v.Health > 0 and v.Health <= DANGER then
			local near = 1 - math.clamp((v.Health - HEAD) / math.max(DANGER - HEAD, 1e-3), 0, 1)
			if v.Beat < 0 then
				v.Beat = 0
				v.Glow.Visible = true
			end
			v.Beat = (v.Beat + dt * (BEAT_SLOW + (BEAT_FAST - BEAT_SLOW) * near)) % 1
			beat = math.sin(v.Beat * math.pi) ^ 2
			v.Glow.ImageTransparency = 1 - (0.35 + 0.3 * near) * beat
			hp.Flash.BackgroundTransparency = 1 - 0.4 * beat
		elseif v.Beat >= 0 then
			v.Beat = -1
			v.Glow.Visible = false
			hp.Flash.BackgroundTransparency = 1
		end
		v.Hurt = if v.Hurt > 0.01 then v.Hurt * math.exp(-dt * 7) else 0
		-- the reserve, and healing: out of the fight, something left, something to heal
		local rg = v.Rg
		if rg then
			local r = v.ReserveShown
			if math.abs(v.Reserve - r) > 1e-4 then
				r += (v.Reserve - r) * ease(10, dt)
				if math.abs(v.Reserve - r) <= 1e-4 then
					r = v.Reserve
				end
				v.ReserveShown = r
				rg.Fill.Size = UDim2.fromScale(r, 1)
				rg.Fill.Visible = r > 0.001
			end
			local wait = v.RegenAt - serverNow
			local healing = not v.Spent and wait <= 0 and v.Health < 0.9999
			if healing ~= v.Healing then
				v.Healing = healing
				if v.Motes then
					v.Motes.Enabled = healing
				end
				if healing then
					v.HealAcc = 0
					v.HeartAt = clock
					ringOut(v, C.Teal, 2.2)
					Kit.playShine(v.Sheen)
					if mine then
						Kit.sfx("Equip")
					end
				elseif v.HealAcc >= 0.5 then
					heartbeat(v, math.floor(v.HealAcc + 0.5)) -- (the last of it)
					v.HealAcc = 0
				end
			end
			-- the block turns teal as it starts healing, and back as it stops
			local m = v.HealMix
			local want = if healing then 1 else 0
			if m ~= want then
				m += (want - m) * ease(if healing then 7 else 5, dt)
				if math.abs(want - m) < 0.01 then
					m = want
				end
				v.HealMix = m
			end
			if healing and clock - v.HeartAt >= HEART then
				v.HeartAt = clock
				heartbeat(v, math.floor(v.HealAcc + 0.5))
				v.HealAcc = 0
			end
			-- the growing end of the health glows teal, flaring with each beat
			if m > 0 then
				local k = ((clock - v.HeartAt) / HEART) % 1
				v.Mend.Position = UDim2.fromScale(v.Shown, 0.5)
				v.Mend.ImageTransparency = 1 - m * (0.35 + 0.4 * (1 - k) ^ 2)
			elseif v.Mend.ImageTransparency < 1 then
				v.Mend.ImageTransparency = 1
			end
			-- the fight on: the reserve dim, brightening as the wait runs out
			local lit = if v.Spent or wait <= 0 then 1 else 1 - math.clamp(wait / RG.Delay, 0, 1)
			if math.abs(lit - v.Lit) > 0.005 then
				v.Lit = lit
				rg.Fill.BackgroundColor3 = DIM:Lerp(Color3.new(1, 1, 1), lit ^ 2)
			end
			-- the health the reserve will still give back, past the fill: faint while the fight is on,
			-- clearer as the wait runs out, brightest (breathing with the heart) while it heals
			local ahead = v.Ahead
			if ahead then
				local max = math.max(v.Hum.MaxHealth, 1)
				local back = if v.Spent or v.Health >= 0.999 or v.Down then 0 else math.min(v.Reserve * RG.Reserve / max, 1 - v.Health)
				local to = if back > 0.004 then math.min(1, v.Shown + back) else -1
				if math.abs(to - v.AheadAt) > 0.0015 then
					v.AheadAt = to
					ahead.Visible = to > 0
					if to > 0 then
						ahead.Size = UDim2.fromScale(to, 1)
					end
				end
				if to > 0 then
					local k = if m > 0 then ((clock - v.HeartAt) / HEART) % 1 else 0
					local a = 0.2 + 0.25 * lit + 0.25 * m * (1 - k) ^ 2
					if math.abs(a - v.AheadLit) > 0.01 then
						v.AheadLit = a
						ahead.BackgroundTransparency = 1 - a
					end
				end
			end
		end
		repaint(v, beat)
	end
	RunService:BindToRenderStep("OverkillVitals", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		if vp.Y < 2 then
			return
		end
		local k = vp.Y / (2 * math.tan(math.rad(cam.FieldOfView) * 0.5)) -- px per stud at depth 1
		local base = ctx.Scale or 1
		local cf = cam.CFrame
		local clock = os.clock()
		local serverNow = workspace:GetServerTimeNow()
		local myChar = player.Character
		table.clear(placed)
		for char, v in pairs(vitals) do
			if v.Down then
				continue
			end
			pulse(v, char == myChar, dt, clock, serverNow)
			-- your own, from inside your head (first person): nothing over the camera
			if char == myChar then
				local head = char:FindFirstChild("Head")
				local inside = head ~= nil and head:IsA("BasePart") and head.LocalTransparencyModifier > 0.5
				if v.Gui.Enabled == inside then
					v.Gui.Enabled = not inside
				end
			end
			local depth = (v.Part.Position - cf.Position):Dot(cf.LookVector)
			if depth < 0.5 or depth > REACH + 5 or not v.Gui.Enabled then
				-- out of sight: no work, the bars just are where the numbers are
				snap(v)
				v.FitNow = -1
				v.Shake = 0
				if v.LiftPx ~= 0 then
					v.LiftPx, v.Lift = 0, 0
					v.Gui.StudsOffset = Vector3.new(0, v.Line, 0)
				end
				continue
			end
			-- the HUD's size (the hit tags' rule: whole up close, down to 60% far off)
			local f = base * math.clamp(k / depth / 40, 0.6, 1)
			if math.abs(f - v.FitNow) > 0.003 then
				v.FitNow = f
				v.Fit.Scale = f
				canvas(v, f)
			end
			-- a blow's jolt: side to side, dying away fast
			if v.Shake > 0 then
				v.Shake = if v.Shake > 0.2 then v.Shake * math.exp(-dt * 12) else 0
				v.Body.Position = UDim2.new(0.5, math.sin(clock * 75) * v.Shake, 1, 0)
			end
			local sp = cam:WorldToViewportPoint(v.Part.Position + cf.UpVector * v.Line)
			table.insert(placed, { V = v, Depth = depth, X = sp.X, Bottom = sp.Y, Half = (W / 2 + 4) * f, Up = v.Height * f, PerPx = depth / k })
			-- health: down fast, up gently; the chunk drains after its moment
			local hp = v.Hp
			local shownHp = v.Shown
			if math.abs(v.Health - shownHp) > 1e-4 then
				shownHp += (v.Health - shownHp) * ease(if v.Health < shownHp then 30 else 7, dt)
				if math.abs(v.Health - shownHp) <= 1e-4 then
					shownHp = v.Health
				end
				v.Shown = shownHp
				hp.Fill.Size = UDim2.fromScale(shownHp, 1)
				hp.Fill.Visible = shownHp > 0.001
			end
			if hp.Trail.Visible then
				if v.TrailAt <= shownHp + 1e-3 then
					hp.Trail.Visible = false
				elseif clock >= v.TrailHold then
					v.TrailAt = math.max(shownHp, v.TrailAt - math.max((v.TrailAt - shownHp) * ease(7, dt), 0.12 * dt))
					hp.Trail.Size = UDim2.fromScale(v.TrailAt, 1)
				end
			end
		end
		screenStep(if myChar then vitals[myChar] else nil, dt, clock)
		table.sort(placed, byDepth)
		for i, r in ipairs(placed) do
			local lift = 0
			-- (again while the climb meets another block: a stack of three clears both below it)
			for _ = 1, 3 do
				local moved = false
				for j = 1, i - 1 do
					local o = placed[j]
					if math.abs(o.X - r.X) < o.Half + r.Half then
						local oBottom = o.Bottom - o.V.LiftPx
						local oTop = oBottom - o.Up
						local myBottom = r.Bottom - lift
						if myBottom > oTop - GAP and myBottom - r.Up < oBottom + GAP then
							lift = r.Bottom - (oTop - GAP)
							moved = true
						end
					end
				end
				if not moved then
					break
				end
			end
			local v = r.V
			local cur = v.LiftPx
			if lift ~= cur then
				-- up at once, down gently
				cur += (lift - cur) * ease(if lift > cur then 24 else 8, dt)
				if math.abs(lift - cur) < 0.5 then
					cur = lift
				end
				v.LiftPx = cur
			end
			local studs = cur * r.PerPx
			if math.abs(studs - v.Lift) > 1e-3 then
				v.Lift = studs
				v.Gui.StudsOffset = Vector3.new(0, v.Line + studs, 0)
			end
		end
	end)
end
