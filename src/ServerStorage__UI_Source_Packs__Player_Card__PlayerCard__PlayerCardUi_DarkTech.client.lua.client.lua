--========================================================
-- PlayerCardUi_DarkTech.client.lua  |  DevPanels
-- Version: V1.2  (Profile + Playtime + Level/XP + Effects + Mobile + Button FX + Click Sound)
-- Creator: (you)
--
-- UPDATE V1.2 (IMPORTANT)
--   ✅ Fixed "blank UI" bug: fade-in now properly restores Text/Image transparency
--   ✅ Added Level/XP system (1 level = 1000 XP, +250 XP per minute by default)
--   ✅ Smooth bar tweens + subtle premium pulse + level-up ring pulse
--
-- WHAT THIS SCRIPT DOES
--   • Builds a Dark-Tech "Player Profile / Stats" UI by script (no external assets required)
--   • Shows: Avatar, Username, UserId
--   • Playtime bar: 100% = 1 hour (BAR_FULL_SECONDS)
--   • Level/XP system:
--       - 1 level = XP_PER_LEVEL
--       - +XP_PER_MINUTE (session default)
--       - XP bar shows progress inside current level
--   • Smooth open/close animations + dim background
--   • Mobile support (safe zones + UIScale)
--   • Buttons: click sound + hover/click animations
--   • Layout uses UIGridLayout / UIListLayout so text/buttons don't overlap
--
-- WHERE TO PUT IT
--   StarterGui > PlayerCard (ScreenGui) > LocalScript
--
-- HOW IT OPENS
--   Finds a GuiButton named "PlayerCardButton" anywhere in PlayerGui and opens the panel.
--
-- BUYER QUICK EDITS
--   • OPEN_BUTTON_NAME
--   • CLOSE_WITH_ESC
--   • BAR_FULL_SECONDS (playtime 100%)
--   • XP_PER_LEVEL / XP_PER_MINUTE
--   • STAT_SOURCE_MODE ("SessionOnly" or "Leaderstats")
--   • LEADERSTAT_XP_NAME / LEADERSTAT_PLAYTIME_NAME
--   • Mobile size: MOBILE_SCALE_PADDING / MIN_SCALE
--========================================================

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local plr = Players.LocalPlayer
local playerGui = plr:WaitForChild("PlayerGui")

local gui = script.Parent
gui.Enabled = true
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false

--========================================================
-- BUYER SETTINGS (EASY TO CHANGE)
--========================================================
local OPEN_BUTTON_NAME = "PlayerCardButton"
local CLOSE_WITH_ESC = true

-- Mobile scale tuning
local MOBILE_SCALE_PADDING = 0.85
local MIN_SCALE = 0.55
local MAX_SCALE = 1.00

-- Click sound
local CLICK_SOUND_ID = "rbxassetid://95635059379804"
local CLICK_VOLUME = 0.8

-- Playtime: 100% bar fill at this seconds
local BAR_FULL_SECONDS = 3600 -- 1 hour

-- XP System
local XP_PER_LEVEL = 1000
local XP_PER_MINUTE = 250
local XP_PER_SECOND = XP_PER_MINUTE / 60

-- Where do stats come from?
--   "SessionOnly"  -> playtime + XP counted locally for this server session
--   "Leaderstats"  -> reads values from leaderstats (for buyers who save data on server)
local STAT_SOURCE_MODE = "SessionOnly"
local LEADERSTAT_XP_NAME = "XP"
local LEADERSTAT_PLAYTIME_NAME = "PlaytimeSeconds"

--========================================================
-- THEME (Dark-Tech)
--========================================================
local BLACK    = Color3.fromRGB(0,0,0)
local BG       = Color3.fromRGB(10,10,14)
local PANEL    = Color3.fromRGB(16,16,22)
local CARD     = Color3.fromRGB(18,18,26)
local TEXT     = Color3.fromRGB(245,245,245)
local MUTED    = Color3.fromRGB(170,175,190)

local ACCENT   = Color3.fromRGB(80,220,255)
local ACCENT_DARK = Color3.fromRGB(18, 80, 92)

--========================================================
-- CLICK SOUND SYSTEM
--========================================================
local clickSound = Instance.new("Sound")
clickSound.Name = "DevPanels_Click"
clickSound.SoundId = CLICK_SOUND_ID
clickSound.Volume = CLICK_VOLUME
clickSound.Parent = gui

local function playClick()
	clickSound.TimePosition = 0
	clickSound:Play()
end

--========================================================
-- UI HELPERS
--========================================================
local function corner(parent, px)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
	return c
end

local function stroke(parent, thick, transparency)
	local s = Instance.new("UIStroke")
	s.Thickness = thick
	s.Color = BLACK
	s.Transparency = transparency or 0
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
end

local function outlineText(obj)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
		obj.TextStrokeTransparency = 0
		obj.TextStrokeColor3 = BLACK
	end
end

local function applyButtonFX(btn, hoverScl, clickScl)
	hoverScl = hoverScl or 1.06
	clickScl = clickScl or 0.92

	local origSize = btn.Size
	local tInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

	local function tweenToScale(scl)
		local newSize = UDim2.new(
			origSize.X.Scale * scl, origSize.X.Offset * scl,
			origSize.Y.Scale * scl, origSize.Y.Offset * scl
		)
		return TweenService:Create(btn, tInfo, {Size = newSize})
	end

	btn.MouseEnter:Connect(function()
		tweenToScale(hoverScl):Play()
	end)
	btn.MouseLeave:Connect(function()
		tweenToScale(1):Play()
	end)

	btn.MouseButton1Click:Connect(function()
		playClick()
		task.spawn(function()
			local t = tweenToScale(clickScl)
			t:Play()
			t.Completed:Wait()
			tweenToScale(1):Play()
		end)
	end)

	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			playClick()
			tweenToScale(clickScl):Play()
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			tweenToScale(1):Play()
		end
	end)
end

local function tweenBar(fillObj, knobObj, alpha)
	alpha = math.clamp(alpha, 0, 1)
	TweenService:Create(fillObj, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(alpha, 0, 1, 0)
	}):Play()
	TweenService:Create(knobObj, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(alpha, -9, 0.5, -9)
	}):Play()
end

--========================================================
-- ROOT: dim + panel
--========================================================
local dim = Instance.new("Frame")
dim.Name = "Dim"
dim.Size = UDim2.fromScale(1,1)
dim.BackgroundColor3 = BLACK
dim.BackgroundTransparency = 1
dim.Visible = false
dim.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "PlayerProfile"
panel.AnchorPoint = Vector2.new(0.5,0.5)
panel.Position = UDim2.fromScale(0.5,0.5)
panel.Size = UDim2.new(0, 1180, 0, 560)
panel.BackgroundColor3 = BG
panel.BackgroundTransparency = 1
panel.Visible = false
panel.Parent = gui
corner(panel, 26)
stroke(panel, 3, 0)

local softOuter = Instance.new("UIStroke")
softOuter.Thickness = 10
softOuter.Color = BLACK
softOuter.Transparency = 0.78
softOuter.LineJoinMode = Enum.LineJoinMode.Round
softOuter.Parent = panel

--========================================================
-- HEADER
--========================================================
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1,0,0,74)
header.BackgroundColor3 = PANEL
header.BackgroundTransparency = 1
header.Parent = panel
corner(header, 26)
stroke(header, 2, 0)

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 18, 0, 10)
title.Size = UDim2.new(1, -160, 0, 30)
title.Font = Enum.Font.GothamBlack
title.TextSize = 26
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "⚙ PLAYER PROFILE"
title.Parent = header
outlineText(title)

local sub = Instance.new("TextLabel")
sub.Name = "Subtitle"
sub.BackgroundTransparency = 1
sub.Position = UDim2.new(0, 20, 0, 42)
sub.Size = UDim2.new(1, -160, 0, 20)
sub.Font = Enum.Font.GothamBold
sub.TextSize = 13
sub.TextColor3 = MUTED
sub.TextXAlignment = Enum.TextXAlignment.Left
sub.Text = ("Leveling enabled · +%d XP/min"):format(XP_PER_MINUTE)
sub.Parent = header
outlineText(sub)

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 56, 0, 44)
closeBtn.Position = UDim2.new(1, -74, 0.5, -22)
closeBtn.BackgroundColor3 = Color3.fromRGB(28,28,38)
closeBtn.Text = "✕"
closeBtn.Font = Enum.Font.GothamBlack
closeBtn.TextSize = 20
closeBtn.TextColor3 = TEXT
closeBtn.Parent = header
corner(closeBtn, 14)
stroke(closeBtn, 2, 0)
outlineText(closeBtn)
applyButtonFX(closeBtn, 1.06, 0.92)

--========================================================
-- BODY (3 cards)
--========================================================
local body = Instance.new("Frame")
body.Name = "Body"
body.BackgroundColor3 = CARD
body.Position = UDim2.new(0, 18, 0, 90)
body.Size = UDim2.new(1, -36, 1, -108)
body.Parent = panel
corner(body, 22)
stroke(body, 2, 0)

local columns = Instance.new("Frame")
columns.Name = "Columns"
columns.BackgroundTransparency = 1
columns.Size = UDim2.fromScale(1,1)
columns.Parent = body

local colPad = Instance.new("UIPadding")
colPad.PaddingTop = UDim.new(0, 16)
colPad.PaddingBottom = UDim.new(0, 16)
colPad.PaddingLeft = UDim.new(0, 16)
colPad.PaddingRight = UDim.new(0, 16)
colPad.Parent = columns

local grid = Instance.new("UIGridLayout")
grid.CellPadding = UDim2.new(0, 14, 0, 14)
grid.CellSize = UDim2.new(0.32, -10, 1, 0)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = columns

local function makeCard(name)
	local c = Instance.new("Frame")
	c.Name = name
	c.BackgroundColor3 = Color3.fromRGB(14,14,18)
	c.Parent = columns
	corner(c, 20)
	stroke(c, 2, 0)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 16)
	pad.PaddingBottom = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = c

	return c
end

local leftCard = makeCard("LeftCard")
local midCard  = makeCard("MidCard")
local rightCard = makeCard("RightCard")

--========================================================
-- LEFT: Avatar + Username + UserId
--========================================================
local nameRow = Instance.new("TextLabel")
nameRow.BackgroundTransparency = 1
nameRow.Size = UDim2.new(1, 0, 0, 30)
nameRow.Font = Enum.Font.GothamBlack
nameRow.TextSize = 22
nameRow.TextColor3 = TEXT
nameRow.TextXAlignment = Enum.TextXAlignment.Left
nameRow.Text = "★ " .. plr.Name
nameRow.Parent = leftCard
outlineText(nameRow)

local avatarHolder = Instance.new("Frame")
avatarHolder.BackgroundTransparency = 1
avatarHolder.Position = UDim2.new(0, 0, 0, 48)
avatarHolder.Size = UDim2.new(1, 0, 0, 280)
avatarHolder.Parent = leftCard

local ring = Instance.new("Frame")
ring.AnchorPoint = Vector2.new(0.5,0.5)
ring.Position = UDim2.fromScale(0.5, 0.52)
ring.Size = UDim2.new(0, 230, 0, 230)
ring.BackgroundColor3 = Color3.fromRGB(10, 40, 50)
ring.Parent = avatarHolder
corner(ring, 999)
stroke(ring, 3, 0.1)

local ringGlow = Instance.new("UIStroke")
ringGlow.Thickness = 4
ringGlow.Color = ACCENT
ringGlow.Transparency = 0
ringGlow.LineJoinMode = Enum.LineJoinMode.Round
ringGlow.Parent = ring

local avatar = Instance.new("ImageLabel")
avatar.BackgroundColor3 = Color3.fromRGB(10,10,14)
avatar.BackgroundTransparency = 0
avatar.AnchorPoint = Vector2.new(0.5,0.5)
avatar.Position = UDim2.fromScale(0.5, 0.5)
avatar.Size = UDim2.new(0, 208, 0, 208)
avatar.Image = ""
avatar.ScaleType = Enum.ScaleType.Crop
avatar.Parent = ring
corner(avatar, 999)
stroke(avatar, 2, 0)

local userIdLabel = Instance.new("TextLabel")
userIdLabel.BackgroundTransparency = 1
userIdLabel.Position = UDim2.new(0, 0, 1, -56)
userIdLabel.Size = UDim2.new(1, 0, 0, 18)
userIdLabel.Font = Enum.Font.GothamBlack
userIdLabel.TextSize = 13
userIdLabel.TextColor3 = MUTED
userIdLabel.TextXAlignment = Enum.TextXAlignment.Center
userIdLabel.Text = "USER ID:"
userIdLabel.Parent = leftCard
outlineText(userIdLabel)

local userIdValue = Instance.new("TextLabel")
userIdValue.BackgroundTransparency = 1
userIdValue.Position = UDim2.new(0, 0, 1, -34)
userIdValue.Size = UDim2.new(1, 0, 0, 28)
userIdValue.Font = Enum.Font.GothamBlack
userIdValue.TextSize = 22
userIdValue.TextColor3 = TEXT
userIdValue.TextXAlignment = Enum.TextXAlignment.Center
userIdValue.Text = tostring(plr.UserId)
userIdValue.Parent = leftCard
outlineText(userIdValue)

-- Avatar thumbnail
task.spawn(function()
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(plr.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
	end)
	if ok and typeof(content) == "string" then
		avatar.Image = content
	end
end)

--========================================================
-- MID: Playtime + Level/XP
--========================================================
local midLayout = Instance.new("UIListLayout")
midLayout.SortOrder = Enum.SortOrder.LayoutOrder
midLayout.Padding = UDim.new(0, 14)
midLayout.Parent = midCard

local function makeSectionHeader(parent, text)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0, 18)
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextSize = 14
	lbl.TextColor3 = MUTED
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Parent = parent
	outlineText(lbl)
	return lbl
end

local function makeBigValue(parent, defaultText)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0, 40)
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextSize = 34
	lbl.TextColor3 = TEXT
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = defaultText
	lbl.Parent = parent
	outlineText(lbl)
	return lbl
end

local function makeBar(parent)
	local wrap = Instance.new("Frame")
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.new(1, 0, 0, 26)
	wrap.Parent = parent

	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Color3.fromRGB(40,40,52)
	bar.Size = UDim2.new(1, 0, 0, 10)
	bar.Position = UDim2.new(0, 0, 0.5, -5)
	bar.Parent = wrap
	corner(bar, 99)
	stroke(bar, 1, 0.2)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = ACCENT_DARK
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = bar
	corner(fill, 99)

	local knob = Instance.new("Frame")
	knob.BackgroundColor3 = ACCENT
	knob.Size = UDim2.new(0, 18, 0, 18)
	knob.Position = UDim2.new(0, -9, 0.5, -9)
	knob.Parent = bar
	corner(knob, 99)
	stroke(knob, 2, 0)

	return fill, knob
end

makeSectionHeader(midCard, "PLAYTIME")
local playtimeBig = makeBigValue(midCard, "0s")
local playFill, playKnob = makeBar(midCard)

local sessionRow = Instance.new("Frame")
sessionRow.BackgroundTransparency = 1
sessionRow.Size = UDim2.new(1, 0, 0, 22)
sessionRow.Parent = midCard

local sessionLbl = Instance.new("TextLabel")
sessionLbl.BackgroundTransparency = 1
sessionLbl.Size = UDim2.new(0.5, 0, 1, 0)
sessionLbl.Font = Enum.Font.GothamBold
sessionLbl.TextSize = 13
sessionLbl.TextColor3 = MUTED
sessionLbl.TextXAlignment = Enum.TextXAlignment.Left
sessionLbl.Text = "Session:"
sessionLbl.Parent = sessionRow
outlineText(sessionLbl)

local sessionVal = Instance.new("TextLabel")
sessionVal.BackgroundTransparency = 1
sessionVal.Position = UDim2.new(0.5, 0, 0, 0)
sessionVal.Size = UDim2.new(0.5, 0, 1, 0)
sessionVal.Font = Enum.Font.GothamBlack
sessionVal.TextSize = 13
sessionVal.TextColor3 = TEXT
sessionVal.TextXAlignment = Enum.TextXAlignment.Right
sessionVal.Text = "0s"
sessionVal.Parent = sessionRow
outlineText(sessionVal)

local playInfo = Instance.new("TextLabel")
playInfo.BackgroundTransparency = 1
playInfo.Size = UDim2.new(1, 0, 0, 18)
playInfo.Font = Enum.Font.GothamBold
playInfo.TextSize = 12
playInfo.TextColor3 = MUTED
playInfo.TextXAlignment = Enum.TextXAlignment.Left
playInfo.Text = "Bar fills to 100% at 1 hour."
playInfo.Parent = midCard
outlineText(playInfo)

local xpHeader = makeSectionHeader(midCard, "LEVEL & XP")
local levelBig = makeBigValue(midCard, "Level 1")

local xpRate = Instance.new("TextLabel")
xpRate.BackgroundTransparency = 1
xpRate.Size = UDim2.new(1, 0, 0, 18)
xpRate.Font = Enum.Font.GothamBold
xpRate.TextSize = 12
xpRate.TextColor3 = MUTED
xpRate.TextXAlignment = Enum.TextXAlignment.Left
xpRate.Text = ("Progress: +%d XP/min · 1 level = %d XP"):format(XP_PER_MINUTE, XP_PER_LEVEL)
xpRate.Parent = midCard
outlineText(xpRate)

local xpFill, xpKnob = makeBar(midCard)

local xpTextRow = Instance.new("Frame")
xpTextRow.BackgroundTransparency = 1
xpTextRow.Size = UDim2.new(1, 0, 0, 22)
xpTextRow.Parent = midCard

local xpLeft = Instance.new("TextLabel")
xpLeft.BackgroundTransparency = 1
xpLeft.Size = UDim2.new(0.65, 0, 1, 0)
xpLeft.Font = Enum.Font.GothamBold
xpLeft.TextSize = 13
xpLeft.TextColor3 = MUTED
xpLeft.TextXAlignment = Enum.TextXAlignment.Left
xpLeft.Text = "XP:"
xpLeft.Parent = xpTextRow
outlineText(xpLeft)

local xpRight = Instance.new("TextLabel")
xpRight.BackgroundTransparency = 1
xpRight.Position = UDim2.new(0.65, 0, 0, 0)
xpRight.Size = UDim2.new(0.35, 0, 1, 0)
xpRight.Font = Enum.Font.GothamBlack
xpRight.TextSize = 13
xpRight.TextColor3 = TEXT
xpRight.TextXAlignment = Enum.TextXAlignment.Right
xpRight.Text = ("0 / %d"):format(XP_PER_LEVEL)
xpRight.Parent = xpTextRow
outlineText(xpRight)

-- Pulse effect on XP header (premium)
task.spawn(function()
	while gui.Parent do
		if panel.Visible then
			TweenService:Create(xpHeader, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {TextColor3 = ACCENT}):Play()
			task.wait(0.6)
			TweenService:Create(xpHeader, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {TextColor3 = MUTED}):Play()
			task.wait(0.6)
		else
			task.wait(0.25)
		end
	end
end)

--========================================================
-- RIGHT: placeholder for buyer expansion
--========================================================
local rightTitle = Instance.new("TextLabel")
rightTitle.BackgroundTransparency = 1
rightTitle.Size = UDim2.new(1, 0, 0, 18)
rightTitle.Font = Enum.Font.GothamBlack
rightTitle.TextSize = 14
rightTitle.TextColor3 = MUTED
rightTitle.TextXAlignment = Enum.TextXAlignment.Left
rightTitle.Text = "COMING SOON"
rightTitle.Parent = rightCard
outlineText(rightTitle)

local rightHint = Instance.new("TextLabel")
rightHint.BackgroundTransparency = 1
rightHint.Position = UDim2.new(0, 0, 0, 26)
rightHint.Size = UDim2.new(1, 0, 0, 40)
rightHint.Font = Enum.Font.GothamBold
rightHint.TextSize = 12
rightHint.TextColor3 = MUTED
rightHint.TextXAlignment = Enum.TextXAlignment.Left
rightHint.Text = "Use this space for badges, titles,\nquests, streaks, or achievements."
rightHint.Parent = rightCard
outlineText(rightHint)

--========================================================
-- STAT SOURCES
--========================================================
local joinTime = os.clock()
local sessionXP = 0
local lastLevel = 1

local function getLeaderInt(name)
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then return nil end
	local v = ls:FindFirstChild(name)
	if v and v:IsA("IntValue") then
		return v.Value
	end
	return nil
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	if h > 0 then return string.format("%dh %dm", h, m) end
	if m > 0 then return string.format("%dm %ds", m, s) end
	return string.format("%ds", s)
end

local function computeLevel(totalXP)
	totalXP = math.max(0, math.floor(totalXP))
	local lvl = math.floor(totalXP / XP_PER_LEVEL) + 1
	local inLevel = totalXP % XP_PER_LEVEL
	local alpha = inLevel / XP_PER_LEVEL
	return lvl, inLevel, alpha, totalXP
end

local function updateStats()
	local sessionSeconds = os.clock() - joinTime
	local totalPlaySeconds = sessionSeconds
	local totalXP = sessionXP

	if STAT_SOURCE_MODE == "Leaderstats" then
		local lsPlay = getLeaderInt(LEADERSTAT_PLAYTIME_NAME)
		if lsPlay ~= nil then totalPlaySeconds = lsPlay end

		local lsXP = getLeaderInt(LEADERSTAT_XP_NAME)
		if lsXP ~= nil then totalXP = lsXP end
	end

	-- Playtime
	playtimeBig.Text = formatTime(totalPlaySeconds)
	sessionVal.Text = formatTime(sessionSeconds)
	local playAlpha = math.clamp(totalPlaySeconds / BAR_FULL_SECONDS, 0, 1)
	tweenBar(playFill, playKnob, playAlpha)

	-- XP / Level
	local lvl, inLevel, xpAlpha = computeLevel(totalXP)
	levelBig.Text = ("Level %d"):format(lvl)
	xpRight.Text = ("%d / %d"):format(inLevel, XP_PER_LEVEL)
	tweenBar(xpFill, xpKnob, xpAlpha)

	-- Level-up effect: ring pulse
	if lvl > lastLevel then
		lastLevel = lvl
		TweenService:Create(ringGlow, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Thickness = 8}):Play()
		task.delay(0.12, function()
			TweenService:Create(ringGlow, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Thickness = 4}):Play()
		end)
	end
end

-- XP gain + UI update loop
task.spawn(function()
	while gui.Parent do
		if STAT_SOURCE_MODE == "SessionOnly" then
			sessionXP += XP_PER_SECOND
		end
		updateStats()
		task.wait(1)
	end
end)

--========================================================
-- RESPONSIVE SCALE (MOBILE SUPPORT)
--========================================================
local baseSize = Vector2.new(1180, 560)
local uiScale = panel:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
uiScale.Parent = panel

local CLOSED_MULT = 0.92
local targetScale = 1

local function getSafeViewport()
	local vp = gui.AbsoluteSize
	local insetX, insetY = 0, 0

	local okInset, inset = pcall(function() return GuiService:GetGuiInset() end)
	if okInset and (typeof(inset) == "Vector2" or typeof(inset) == "Vector2int16") then
		insetY += inset.Y
	end

	local okSafe, left, top, right, bottomOff = pcall(function()
		return GuiService:GetSafeZoneOffsets()
	end)
	if okSafe then
		insetX += (left + right)
		insetY += (top + bottomOff)
	end

	return Vector2.new(math.max(1, vp.X - insetX), math.max(1, vp.Y - insetY))
end

local function computeTargetScale()
	local vp = getSafeViewport()
	local s = math.min(vp.X / baseSize.X, vp.Y / baseSize.Y) * MOBILE_SCALE_PADDING
	return math.clamp(s, MIN_SCALE, MAX_SCALE)
end

local function fitPanel()
	targetScale = computeTargetScale()
	if not panel.Visible then
		uiScale.Scale = targetScale * CLOSED_MULT
	end
end

fitPanel()
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPanel)

--========================================================
-- OPEN/CLOSE animations (FIXED)
--========================================================
local function setAlpha(a)
	panel.BackgroundTransparency = a
	header.BackgroundTransparency = a

	for _, d in ipairs(panel:GetDescendants()) do
		if d:IsA("TextLabel") then d.TextTransparency = a end
		if d:IsA("TextButton") then d.TextTransparency = a; d.BackgroundTransparency = math.clamp(a,0,1) end
		if d:IsA("ImageLabel") then d.ImageTransparency = a end
		if d:IsA("ImageButton") then d.ImageTransparency = a; d.BackgroundTransparency = math.clamp(a,0,1) end
		if d:IsA("UIStroke") then d.Transparency = a end
	end
end

local isOpen, busy = false, false

local function openUI()
	if busy or isOpen then return end
	busy = true
	isOpen = true

	fitPanel()

	dim.Visible = true
	panel.Visible = true
	setAlpha(1) -- start invisible
	dim.BackgroundTransparency = 1

	uiScale.Scale = targetScale * CLOSED_MULT

	TweenService:Create(dim, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.45}):Play()
	TweenService:Create(uiScale, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Scale = targetScale}):Play()
	TweenService:Create(panel, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()
	TweenService:Create(header, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()

	-- Fade in everything (TEXT/IMAGES/STROKES)
	task.delay(0.05, function()
		for _, d in ipairs(panel:GetDescendants()) do
			if d:IsA("TextLabel") then
				TweenService:Create(d, TweenInfo.new(0.16), {TextTransparency = 0}):Play()
			elseif d:IsA("TextButton") then
				TweenService:Create(d, TweenInfo.new(0.16), {TextTransparency = 0, BackgroundTransparency = 0}):Play()
			elseif d:IsA("ImageLabel") then
				TweenService:Create(d, TweenInfo.new(0.16), {ImageTransparency = 0}):Play()
			elseif d:IsA("ImageButton") then
				TweenService:Create(d, TweenInfo.new(0.16), {ImageTransparency = 0, BackgroundTransparency = 0}):Play()
			elseif d:IsA("UIStroke") then
				TweenService:Create(d, TweenInfo.new(0.16), {Transparency = 0}):Play()
			end
		end
	end)

	task.delay(0.30, function()
		busy = false
	end)
end

local function closeUI()
	if busy or not isOpen then return end
	busy = true
	isOpen = false

	for _, d in ipairs(panel:GetDescendants()) do
		if d:IsA("TextLabel") then
			TweenService:Create(d, TweenInfo.new(0.12), {TextTransparency = 1}):Play()
		elseif d:IsA("TextButton") then
			TweenService:Create(d, TweenInfo.new(0.12), {TextTransparency = 1, BackgroundTransparency = 1}):Play()
		elseif d:IsA("ImageLabel") then
			TweenService:Create(d, TweenInfo.new(0.12), {ImageTransparency = 1}):Play()
		elseif d:IsA("ImageButton") then
			TweenService:Create(d, TweenInfo.new(0.12), {ImageTransparency = 1, BackgroundTransparency = 1}):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, TweenInfo.new(0.12), {Transparency = 1}):Play()
		end
	end

	TweenService:Create(uiScale, TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {Scale = targetScale * CLOSED_MULT}):Play()
	TweenService:Create(dim, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
	TweenService:Create(panel, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
	TweenService:Create(header, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()

	task.delay(0.22, function()
		if not isOpen then
			panel.Visible = false
			dim.Visible = false
			setAlpha(1)
		end
		busy = false
	end)
end

--========================================================
-- BUTTON HOOKS
--========================================================
closeBtn.MouseButton1Click:Connect(function()
	playClick()
	closeUI()
end)

dim.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		playClick()
		closeUI()
	end
end)

if CLOSE_WITH_ESC then
	UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if not isOpen then return end
		if input.KeyCode == Enum.KeyCode.Escape then
			playClick()
			closeUI()
		end
	end)
end

--========================================================
-- OPEN BUTTON HOOK
--========================================================
task.defer(function()
	local openBtn = playerGui:FindFirstChild(OPEN_BUTTON_NAME, true)
	if openBtn and openBtn:IsA("GuiButton") then
		openBtn.MouseButton1Click:Connect(function()
			playClick()
			openUI()
		end)
	else
		warn("[PlayerCardUi] Open button not found: " .. tostring(OPEN_BUTTON_NAME))
	end
end)

--========================================================
-- START CLOSED
--========================================================
panel.Visible = false
dim.Visible = false
setAlpha(1)

print("[PlayerCardUi] Dark-Tech PlayerCard UI running. (V1.2)")
