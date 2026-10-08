--[[
	Abilities  (StarterPlayerScripts.CombatClient.Abilities)
	The ability framework on this screen (ReplicatedStorage.Abilities.AbilityConfig):

	  YOUR CASTS   a press (keys 1-4, the D-pad / R3, the hotbar) is checked here the way the server
	               will check it (your hero's kit, your state, your cooldown, the ground under you,
	               where you stand) and, if it can go, it goes AT ONCE: the Casting state, the clip,
	               the effects - and the server is asked ("Ability"). Its answer (Ack) keeps it or
	               takes it back; its word ("Ability" Start / Stop) ends it with everyone else's. A press
	               that can't go yet (mid-strike, mid-dash, in the air) is kept AbilityConfig.Buffer.
	               While it casts you turn toward where your camera aims, at the ability's own rates,
	               and that aim goes to the server ("AbilityAim", 15 a second) - a wish it follows at
	               the same rates.
	  EVERYONE'S   every other caster's cast is drawn here from the server's word: its effects (FX)
	               start where the cast is now, follow that caster's clip as this screen sees it, and
	               aim where the server says (the AbilityAim attribute, smoothed).
	The hotbar reads and presses through AbilityBus.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local Abilities = ReplicatedStorage:WaitForChild("Abilities")
local AbilityConfig = require(Abilities:WaitForChild("AbilityConfig"))
local BeamMath = require(Abilities:WaitForChild("BeamMath"))
local Bus = require(Abilities:WaitForChild("AbilityBus"))
local FXFolder = Abilities:WaitForChild("FX")
local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatFolder:WaitForChild("CombatConfig"))
local States = require(CombatFolder:WaitForChild("CombatStates"))

local M = {}

local api: any = nil
local ctx: any = nil

local AIM_RATE = 1 / 15

local function now(): number
	return os.clock()
end
local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local fxModules: { [string]: any } = {}
local fxInst: { [string]: Instance? } = {}
local function fxFor(def: any): any
	local mod = FXFolder:FindFirstChild(def.FX)
	-- (Studio: an effects module swapped in while playing is picked up by the next cast)
	if fxModules[def.FX] == nil or (RunService:IsStudio() and mod ~= fxInst[def.FX]) then
		fxModules[def.FX] = if mod then require(mod) else false
		fxInst[def.FX] = mod
	end
	return fxModules[def.FX] or nil
end

local function heroId(): string?
	local h = player:GetAttribute("Hero")
	return if type(h) == "string" and h ~= "" then h else nil
end

-- every body a beam could stop on (alive, hittable, not the caster), as this screen has it
local function bodiesBut(caster: Model): () -> { any }
	local list: { any } = {}
	return function(): { any }
		table.clear(list)
		for _, m in ipairs(api.Fighters()) do
			if m ~= caster and m.Parent then
				local r = m:FindFirstChild("HumanoidRootPart")
				local hum = m:FindFirstChildOfClass("Humanoid")
				local st = m:GetAttribute("CombatState")
				if r and r:IsA("BasePart") and hum and hum.Health > 0 and (type(st) ~= "string" or States.Allows(st, "Hittable")) and api.CombatHere(m) then
					table.insert(list, { Key = m, Cf = r.CFrame })
				end
			end
		end
		return list
	end
end

local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.RespectCanCollide = true
worldParams.IgnoreWater = true
local worldAt = -math.huge
local function world(origin: Vector3, v: Vector3): RaycastResult?
	local t = now()
	if t - worldAt > 0.25 then
		worldAt = t
		local list: { Instance } = {}
		for _, m in ipairs(api.Fighters()) do
			table.insert(list, m)
		end
		for _, name in ipairs({ "AbilityFX", "CombatGore", "CombatBlood", "CombatShatter", "CombatDebugDraw" }) do
			local f = workspace:FindFirstChild(name)
			if f then
				table.insert(list, f)
			end
		end
		worldParams.FilterDescendantsInstances = list
	end
	return workspace:Raycast(origin, v, worldParams)
end
M.World = world

-- the cast's clip on a caster, as this screen sees it (a replicated body's Animator)
local function trackOn(caster: Model, def: any): () -> AnimationTrack?
	local cached: AnimationTrack? = nil
	local nextLook = 0
	return function(): AnimationTrack?
		if cached and cached.IsPlaying then
			return cached
		end
		if now() < nextLook then
			return nil
		end
		nextLook = now() + 0.1
		local hum = caster:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if not animator then
			return nil
		end
		local want = api.AnimId(def.Anim)
		for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
			if want and tr.Animation and tr.Animation.AnimationId == want then
				cached = tr
				return tr
			end
		end
		return nil
	end
end

---------------------------------------------------------------------------
-- your aim: where the camera looks, from the beam's own origin
---------------------------------------------------------------------------
local camParams = RaycastParams.new()
camParams.FilterType = Enum.RaycastFilterType.Exclude
camParams.RespectCanCollide = true
local function cameraAim(def: any): Vector3
	local cam = workspace.CurrentCamera
	local root = ctx and ctx.Root
	if not (cam and root) then
		return Vector3.new(0, 0, -1)
	end
	local look = cam.CFrame.LookVector
	camParams.FilterDescendantsInstances = { ctx.Char, workspace:FindFirstChild("AbilityFX") :: any }
	local from = cam.CFrame.Position
	local hit = workspace:Raycast(from, look * 400, camParams)
	local target = if hit then hit.Position else from + look * 400
	local o = BeamMath.Origin(root.Position, look, if def.Beam then def.Beam.Origin else Vector3.zero)
	local v = target - o
	-- (a target behind the hands, or right on them: the camera's own look)
	if v.Magnitude < 4 or v:Dot(look) < 0 then
		v = look
	end
	return BeamMath.Clamp(v.Unit, def.Aim.PitchMin, def.Aim.PitchMax)
end

---------------------------------------------------------------------------
-- your cast
---------------------------------------------------------------------------
local cast: any = nil -- { Def, Slot, Seq, Started, Aim, Fx, Track, Confirmed, Held, Ending }
local buffered: any = nil -- { Slot, At }
local seq = 0

local function cooldownLeft(def: any): number
	local p = Bus.Predicted[def.Id]
	local untilT = if p then p.Until else 0
	local char = ctx and ctx.Char
	local a = char and char:GetAttribute("CombatCD_" .. AbilityConfig.CooldownKey(def.Id))
	if type(a) == "number" and not p then
		untilT = a
	end
	return math.max(0, untilT - serverNow())
end

-- why a slot can't be cast right now (nil: it can). Soft = worth keeping the press for
local function blocker(slot: string): (string?, boolean?)
	if not ctx or not ctx.Alive or ctx.Hum.Health <= 0 then
		return "Dead"
	end
	local def = AbilityConfig.For(heroId(), slot)
	if not def then
		return "Locked"
	end
	if not api.CombatAllowed() then
		return "Sanctuary"
	end
	if cast then
		return "Busy", false
	end
	if cooldownLeft(def) > 0.05 then
		return "Cooldown"
	end
	if Config.ArmsAt(api.Stage()) < 1 then
		return "NoArms"
	end
	if not def.From[ctx.State] then
		local soft = ctx.State == "Attacking" or ctx.State == "Dashing" or ctx.State == "Blocking"
		return "Busy", soft
	end
	if api.ParkourHands() then
		return "Busy", true
	end
	if def.Grounded and api.Airborne() then
		return "Air", true
	end
	return nil
end

local function stopTrack(fade: number)
	if cast and cast.Track then
		cast.Track:AdjustSpeed(1)
		ctx.AC:FadeTrack(cast.Track, fade)
	end
end

-- the cast is over on this screen (why: "Done" | "Interrupted" | "Refused")
local function endCast(why: string)
	local c = cast
	if not c then
		return
	end
	if RunService:IsStudio() then
		print(string.format("[Abilities] cast %s ended: %s at %.2f (state %s)", c.Def.Id, why, now() - c.Started, tostring(ctx and ctx.State)))
	end
	cast = nil
	Bus.Casting = nil
	Bus.CastSlot = nil
	if c.Fx then
		if why == "Refused" then
			c.Fx.Stop("Interrupted")
		elseif why == "Interrupted" then
			c.Fx.Stop("Interrupted")
		else
			c.Fx.Stop("Done")
		end
	end
	if ctx and c.Track and not (why == "Done" and c.Ending) then
		-- (a blow that ended it plays its own reaction over the pose: the clip goes quickly under it;
		-- a cast that ran its course is already fading out - that fade is left to finish)
		c.Track:AdjustSpeed(1)
		ctx.AC:FadeTrack(c.Track, if why == "Done" then c.Def.Timeline.Recover else 0.14)
	end
	if ctx and ctx.State == "Casting" then
		api.SetLocal("Idle")
	end
	Bus.Fire("Changed")
end

local function start(slot: string, def: any)
	seq += 1
	local aim = cameraAim(def)
	-- (whatever strike was fading out goes under the clip coming in)
	api.Quiet(def.Timeline.FadeIn)
	-- a combo it ends keeps its count on screen
	ctx.CounterHoldUntil = math.max(ctx.CounterHoldUntil or 0, now() + def.Timeline.Fire + def.Timeline.Sustain + 1.5)
	api.EndChain()
	api.SetLocal("Casting")
	local track = ctx.AC:Play(def.Anim, { Fade = def.Timeline.FadeIn, Restart = true, Speed = 1 })
	local c: any = {
		Def = def, Slot = slot, Seq = seq, Started = now(), Aim = aim, Want = aim, Track = track,
		AimSentAt = now(), AimSent = aim, Confirmed = false,
	}
	cast = c
	Bus.Casting = def.Id
	Bus.CastSlot = slot
	Bus.Predicted[def.Id] = { Until = serverNow() + def.Cooldown, Len = def.Cooldown }
	local fx = fxFor(def)
	if fx then
		local caster = ctx.Char
		-- (the effects never hold the fight up: a fault in them leaves the cast going without them)
		local ok, h = pcall(fx.Start, {
			Caster = caster,
			Def = def,
			Started = c.Started,
			Mine = true,
			Aim = function(): Vector3
				return c.Aim
			end,
			Bodies = bodiesBut(caster),
			World = world,
			Camera = api.Camera,
			Fov = api.Fov,
			Track = function(): AnimationTrack?
				return c.Track
			end,
		})
		if ok then
			c.Fx = h
		else
			warn("[Abilities] effects:", h)
		end
	end
	api.Request("Ability", { Seq = c.Seq, Slot = slot, Aim = aim })
	Bus.Fire("Cast", slot, def.Id)
	Bus.Fire("Changed")
end

function M.Press(slot: string)
	if not ctx or api.InputBlocked() then
		return
	end
	Bus.Fire("Pressed", slot)
	local why, soft = blocker(slot)
	if not why then
		buffered = nil
		start(slot, AbilityConfig.For(heroId(), slot))
		return
	end
	if soft then
		buffered = { Slot = slot, At = now() }
	elseif why ~= "Busy" then
		Bus.Fire("Refused", slot, why)
	end
end

-- every frame: the buffered press, your cast's turning, its aim, its clip, its end
local function step(dt: number)
	if not ctx then
		return
	end
	if buffered then
		if now() - buffered.At > AbilityConfig.Buffer then
			buffered = nil
		elseif not blocker(buffered.Slot) then
			local slot = buffered.Slot
			buffered = nil
			start(slot, AbilityConfig.For(heroId(), slot))
		end
	end
	local c = cast
	if not c then
		return
	end
	if ctx.State ~= "Casting" then
		-- the fight took the body (a stun, a knockdown, death): the server's Stop follows
		endCast("Interrupted")
		return
	end
	local def = c.Def
	local TL, P = def.Timeline, def.Aim
	local tau = now() - c.Started
	-- turn toward the camera's aim, at the ability's rates
	c.Want = cameraAim(def)
	local rate = if tau < TL.Fire then P.ChargeTurn else P.BeamTurn
	if tau < (P.SnapTurn or 0) then
		-- (the cast's first instant: the body turns to the aim at once, eased - no slow, floaty swing)
		local k = 1 - math.exp(-dt * 45)
		local v = c.Aim:Lerp(c.Want, k)
		c.Aim = if v.Magnitude > 1e-3 then v.Unit else c.Want
	else
		-- (eased into the aim under the rate cap: quick off the mark, settling without a dead stop)
		c.Aim = BeamMath.Ease(c.Aim, c.Want, rate, P.PitchRate, if tau < TL.Fire then 22 else 7, dt)
	end
	local root = ctx.Root
	if root.Parent then
		local f = BeamMath.Flat(c.Aim)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + f)
	end
	if now() - c.AimSentAt >= AIM_RATE and c.AimSent:Dot(c.Want) < math.cos(math.rad(0.5)) then
		c.AimSentAt = now()
		c.AimSent = c.Want
		api.Request("AbilityAim", { Seq = c.Seq, Aim = c.Want })
	end
	-- the clip holds its release pose while the beam lasts (and keeps to the cast's clock before it)
	local tr = c.Track
	if tr and tr.IsPlaying and not c.Held and tr.TimePosition < TL.Hold then
		tr:AdjustSpeed(AbilityConfig.ClipSpeed(TL, tau, tr.TimePosition))
	end
	if tr and tr.IsPlaying and not c.Held and tr.TimePosition >= TL.Hold then
		c.Held = true
		tr:AdjustSpeed(0)
	end
	-- the beam's end: the pose lets go over the recovery, control comes back after it
	local beamEnd = TL.Fire + TL.Sustain
	if not c.Ending and tau >= beamEnd then
		c.Ending = true
		if c.Fx then
			c.Fx.Stop("Done")
		end
		stopTrack(TL.RecoverBlend or TL.Recover)
	end
	if tau >= beamEnd + TL.Recover then
		c.Fx = nil -- (already stopping)
		endCast("Done")
	end
end

---------------------------------------------------------------------------
-- the server's word
---------------------------------------------------------------------------
local others: { [Model]: any } = {}

local function smoothedAim(caster: Model, first: Vector3): () -> Vector3
	local cur = first
	local last = now()
	return function(): Vector3
		local t = now()
		local dt = math.min(t - last, 0.1)
		last = t
		local want = caster:GetAttribute("AbilityAim")
		if typeof(want) == "Vector3" and want.Magnitude > 0.5 then
			local k = 1 - math.exp(-dt * 16)
			local v = cur:Lerp(want.Unit, k)
			cur = if v.Magnitude > 1e-3 then v.Unit else cur
		end
		return cur
	end
end

function M.OnEvent(data: any)
	if type(data) ~= "table" then
		return
	end
	local caster = data.A
	if typeof(caster) ~= "Instance" or not caster:IsA("Model") then
		return
	end
	local def = AbilityConfig.Abilities[data.Id]
	if not def then
		return
	end
	local mine = ctx ~= nil and caster == ctx.Char
	if data.K == "Start" then
		if mine then
			if cast and cast.Seq == data.Seq then
				cast.Confirmed = true
			end
			return
		end
		local old = others[caster]
		if old then
			old.Fx.Destroy()
			others[caster] = nil
		end
		local fx = fxFor(def)
		if not fx then
			return
		end
		local elapsed = math.clamp(serverNow() - (if type(data.T0) == "number" then data.T0 else serverNow()), 0, 3)
		local aim = if typeof(data.Aim) == "Vector3" then data.Aim.Unit else BeamMath.Flat(caster:GetPivot().LookVector)
		local getTrack = trackOn(caster, def)
		local o = {
			Caster = caster,
			Def = def,
			Started = now() - elapsed,
			Mine = false,
			Aim = smoothedAim(caster, aim),
			Bodies = bodiesBut(caster),
			World = world,
			Camera = api.Camera,
			Track = getTrack,
		}
		local ok, h = pcall(fx.Start, o)
		if not ok then
			warn("[Abilities] effects:", h)
			return
		end
		local entry = { Fx = h, Def = def, Seq = data.Seq, Track = getTrack, Started = o.Started, Held = false }
		others[caster] = entry
		caster.AncestryChanged:Once(function(_, parent)
			if parent == nil and others[caster] == entry then
				others[caster] = nil
				h.Destroy()
			end
		end)
	elseif data.K == "Stop" then
		if mine then
			if cast and cast.Seq == data.Seq and data.Why ~= "Done" then
				endCast("Interrupted")
			end
			return
		end
		local e = others[caster]
		if e and e.Seq == data.Seq then
			others[caster] = nil
			e.Fx.Stop(if data.Why == "Done" then "Done" else "Interrupted")
		end
	end
end

-- the server's answer to your request
function M.OnAck(data: any)
	if not cast or data.Seq ~= cast.Seq then
		if data.Ok == false and type(data.Action) == "string" then
			Bus.Predicted[data.Action] = nil
			Bus.Fire("Changed")
		end
		return
	end
	if data.Ok then
		cast.Confirmed = true
		return
	end
	-- refused: everything this screen started goes back
	if RunService:IsStudio() then
		print("[Abilities] the server refused", cast.Def.Id, data.Why)
	end
	Bus.Predicted[cast.Def.Id] = nil
	local slot = cast.Slot
	endCast("Refused")
	Bus.Fire("Refused", slot, data.Why)
end

---------------------------------------------------------------------------
-- other casters' clips hold their release pose on this screen too (a held clip's speed may never
-- reach this screen: it would run out and drop the pose while the beam still pours out of it)
---------------------------------------------------------------------------
local function othersStep()
	for caster, e in pairs(others) do
		local tr = e.Track()
		local TL = e.Def.Timeline
		if tr and tr.IsPlaying then
			local tau = now() - e.Started
			if not e.Held and tr.TimePosition < TL.Hold then
				tr:AdjustSpeed(AbilityConfig.ClipSpeed(TL, tau, tr.TimePosition))
			end
			if not e.Held and tr.TimePosition >= TL.Hold and tau < TL.Fire + TL.Sustain then
				e.Held = true
				tr:AdjustSpeed(0)
			elseif e.Held and tau >= TL.Fire + TL.Sustain + 0.1 then
				e.Held = false
				tr:AdjustSpeed(1)
			end
		end
		if not caster.Parent then
			others[caster] = nil
			e.Fx.Destroy()
		end
	end
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------
local KEY_SLOT: { [Enum.KeyCode]: string } = {}
for slot, k in pairs(AbilityConfig.Keys) do
	KEY_SLOT[k] = slot
end
local PAD_SLOT: { [Enum.KeyCode]: string } = {}
for slot, k in pairs(AbilityConfig.Gamepad) do
	PAD_SLOT[k] = slot
end

function M.Input(input: InputObject, processed: boolean): boolean
	if processed then
		return false
	end
	local slot = if input.UserInputType == Enum.UserInputType.Keyboard then KEY_SLOT[input.KeyCode]
		elseif input.UserInputType == Enum.UserInputType.Gamepad1 then PAD_SLOT[input.KeyCode]
		else nil
	if slot then
		M.Press(slot)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
function M.Setup(c: any)
	ctx = c
	cast = nil
	buffered = nil
	Bus.Casting = nil
	Bus.Fire("Changed")
end

function M.Teardown()
	if cast then
		local c = cast
		cast = nil
		if c.Fx then
			c.Fx.Destroy()
		end
	end
	buffered = nil
	ctx = nil
	Bus.Casting = nil
	Bus.CastSlot = nil
	Bus.Fire("Changed")
end

function M.Casting(): boolean
	return cast ~= nil
end

-- Studio inspection: LocalPlayer.AbilityPreview:Fire(id, tau?) plays a cast's clip and effects on your own
-- character with no server and no hits (workspace AbilityFXTime holds both at that clip time);
-- :Fire() with nothing ends it
local preview: any = nil
local function previewStop()
	if preview then
		if preview.Fx then
			preview.Fx.Destroy()
		end
		if preview.Track then
			preview.Track:Stop(0.1)
		end
		preview = nil
	end
end
local function previewStart(id: string?, tau: number?)
	previewStop()
	local def = id and AbilityConfig.Abilities[id]
	if not (def and ctx) then
		return
	end
	local fx = fxFor(def)
	local caster = ctx.Char
	local track = ctx.AC:Play(def.Anim, { Fade = 0.05, Restart = true, Speed = 1 })
	local started = now() - (tau or 0)
	local aim = BeamMath.Flat(ctx.Root.CFrame.LookVector)
	preview = { Track = track, Def = def }
	if fx then
		preview.Fx = fx.Start({
			Caster = caster, Def = def, Started = started, Mine = true,
			Aim = function(): Vector3
				return aim
			end,
			Bodies = bodiesBut(caster), World = world, Camera = api.Camera, Fov = api.Fov,
			Track = function(): AnimationTrack?
				return track
			end,
		})
	end
	task.spawn(function()
		while preview and preview.Track == track do
			local frozen = workspace:GetAttribute("AbilityFXTime")
			if track then
				if type(frozen) == "number" then
					track:AdjustSpeed(0)
					track.TimePosition = math.min(AbilityConfig.ClipTime(def.Timeline, frozen), def.Timeline.Hold)
				elseif track.TimePosition >= def.Timeline.Hold then
					track:AdjustSpeed(0)
				else
					track:AdjustSpeed(AbilityConfig.ClipSpeed(def.Timeline, now() - started, track.TimePosition))
				end
			end
			task.wait()
		end
	end)
end

function M.Init(a: any)
	api = a
	Bus.SetPress(M.Press)
	if RunService:IsStudio() then
		local ev = Instance.new("BindableEvent")
		ev.Name = "AbilityPreview"
		ev.Event:Connect(function(id: string?, tau: number?)
			previewStart(id, tau)
		end)
		ev.Parent = player
	end
	RunService:BindToRenderStep("OverkillAbilities", Enum.RenderPriority.Character.Value + 1, function(dt: number)
		step(math.min(dt, 0.1))
	end)
	RunService.Heartbeat:Connect(othersStep)
	-- the server's cooldown arrived: the prediction gives way to it
	player.CharacterAdded:Connect(function(char)
		char.AttributeChanged:Connect(function(name)
			if string.sub(name, 1, 17) == "CombatCD_Ability_" then
				Bus.Predicted[string.sub(name, 18)] = nil
				Bus.Fire("Changed")
			end
		end)
	end)
	if player.Character then
		player.Character.AttributeChanged:Connect(function(name)
			if string.sub(name, 1, 17) == "CombatCD_Ability_" then
				Bus.Predicted[string.sub(name, 18)] = nil
				Bus.Fire("Changed")
			end
		end)
	end
	player:GetAttributeChangedSignal("Hero"):Connect(function()
		Bus.Fire("Changed")
	end)
end

return M
