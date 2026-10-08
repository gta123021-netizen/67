--[[
	AbilityConfig  (ReplicatedStorage.Abilities.AbilityConfig)
	THE ABILITY FRAMEWORK'S ONE TABLE. Every hero fights with the same basic moveset (CombatConfig)
	plus a KIT: three abilities and an ultimate, on four slots that never move. An ability is data
	here and two pieces of code that read it:

	  server   ServerScriptService.Combat.AbilityService - who may cast what, when (the fight's own
	           state machine: an ability is the Casting state), its cooldown, its timeline, its hits
	           (the server's own: a client only ever ASKS to cast, and says where it aims). Runner =
	           which kind of ability it is (AbilityService.Runners: "Beam", ...)
	  clients  ReplicatedStorage.Abilities.FX[FX] - what it looks and sounds like, on every screen,
	           for every caster (the caster's own screen starts it on the press; the others on the
	           server's word). The caster's input, prediction and hotbar: CombatClient.Abilities +
	           OverkillHUD.AbilityBar

	ADDING AN ABILITY: its entry in Abilities (below), its slot in a hero's Kit, its clip in
	CombatConfig.Anim (published - the KeyframeSequence it comes from goes in
	Abilities.Assets.Animations), its blows in CombatConfig.Attacks (the fight applies them like any
	other: guard, stun, knockback, gore, kills), its FX module, and its Runner if it is a new kind.

	Entry fields
	  Id, Name, Hero, Slot      Slot: Ability1 | Ability2 | Ability3 | Ultimate
	  Type                      the tag on the hotbar / hero select
	  Desc                      one line for the hotbar's tooltip
	  Icon                      an image id (the hotbar slot's art)
	  Accent                    { light, deep } colours of its slot
	  Cooldown                  seconds, from the cast's start
	  FizzleCooldown            ...when it was interrupted before it went off (the charge was lost)
	  From                      combat states it may be cast from (a live combo's window too: a combo
	                            can end in it)
	  Grounded                  only with the feet on the ground (a press in the air is kept until
	                            the landing, within Buffer)
	  Anim                      CombatConfig.Anim key of the cast's clip
	  Runner, FX                server runner kind, FX module name
	  Timeline                  (clip seconds) where the cast's moments fall - the clip's own marks
	  Aim                       how the caster turns while casting (degrees, degrees a second)
	  Beam                      (Runner "Beam") its reach, its width, its ticks
]]

local AbilityConfig = {}

-- the four slots, left to right on the hotbar
AbilityConfig.Slots = { "Ability1", "Ability2", "Ability3", "Ultimate" }

-- keys (number keys are never rebindable: Theme keeps them for the hotbar)
AbilityConfig.Keys = {
	Ability1 = Enum.KeyCode.One,
	Ability2 = Enum.KeyCode.Two,
	Ability3 = Enum.KeyCode.Three,
	Ultimate = Enum.KeyCode.Four,
}
AbilityConfig.KeyText = { Ability1 = "1", Ability2 = "2", Ability3 = "3", Ultimate = "4" }
-- gamepad: the D-pad (its down is the crawl) and the right stick's click
AbilityConfig.Gamepad = {
	Ability1 = Enum.KeyCode.DPadLeft,
	Ability2 = Enum.KeyCode.DPadUp,
	Ability3 = Enum.KeyCode.DPadRight,
	Ultimate = Enum.KeyCode.ButtonR3,
}

-- a press that can't go yet (mid-strike, mid-dash, in the air) is kept this long
AbilityConfig.Buffer = 0.35

-- what each hero has on each slot (a slot that isn't listed is locked: "coming soon")
AbilityConfig.Kits = {
	Goki = { Ability1 = "AzureTideCannon" },
	Gojen = {},
	Naroto = {},
}

local rgb = Color3.fromRGB

AbilityConfig.Abilities = {
	AzureTideCannon = {
		Id = "AzureTideCannon",
		Name = "AZURE TIDE CANNON",
		Short = "AZURE", -- (the hotbar tile's name tag)
		Hero = "Goki",
		Slot = "Ability1",
		Type = "BEAM",
		Desc = "Gather the tide's energy at your hip, then release it in a roaring azure wave that swells to a massive torrent: 6 hits as it pours through, then it bursts at its end.",
		-- "Beam wake" by Lorc, game-icons.net, CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/):
		-- white on clear, tinted by the hotbar (see AbilityConfig.Credits)
		Icon = "rbxassetid://89704136492700",
		Accent = { rgb(110, 214, 255), rgb(28, 108, 236) },
		Cooldown = 14,
		FizzleCooldown = 5,
		From = { Idle = true, ComboWindow = true },
		Grounded = true,
		Anim = "AzureTide",
		Runner = "Beam",
		FX = "AzureTideCannon",
		-- the clip ("kamehameha 1", 2.33 s): the hands draw back to the right hip (0 - 0.6), cup the
		-- energy there (0.6 - 1.8), thrust (1.8 - 1.9) and hold the release (marker vfx1 at 1.9)
		Timeline = {
			FadeIn = 0.16, -- the clip comes in over this, from whatever the body was doing
			Gather = 0.28, -- the energy starts to be drawn in: a seed of light in the palms
			Sphere = 0.7, -- the sphere forms between the cupped hands and grows
			Surge = 1.69, -- it escalates (at its largest: a blue black hole)
			Compress = 2.636, -- the last breath: it crushes down to its brightest
			Thrust = 2.716, -- the hands drive forward
			Fire = 2.816, -- the release (the clip's own mark)
			Hold = 2.25, -- (CLIP time) the clip holds its release pose here while the beam lasts
			-- the clip's cupping (clip time From - To) plays at Speed, so the charge has time to build;
			-- every other mark here is the cast's own time (AbilityConfig.ClipTime / CastTime)
			Slow = { From = 0.6, To = 1.72, Speed = 0.55 },
			Sustain = 3, -- seconds the beam lasts
			Collapse = 0.26, -- seconds it takes to die away
			Recover = 0.24, -- seconds from the end of the beam to control (the clip keeps fading out a moment
			-- longer, so the first step / strike after it blends out of the pose instead of popping)
			RecoverBlend = 0.4,
		},
		Aim = {
			PitchMin = -28, PitchMax = 24, -- how far up / down the beam can go
			SnapTurn = 0.09, -- seconds: the body snaps to the aim as the cast starts (never a slow drift round)
			ChargeTurn = 720, -- then it tracks the aim while gathering (degrees a second)
			BeamTurn = 55, -- the beam sweeps slowly, with weight
			PitchRate = 70,
		},
		Beam = {
			Range = 150,
			HitRadius = 4.8, -- bodies this close to its line are in it (its visible body)
			StopRadius = 2.0, -- ...and this close (its core) stop it: its end sits on them
			Tick = 0.5, -- seconds between ticks: 6 ticks over the Sustain (CombatConfig.Attacks.AzureTide), then the blast
			TickAttack = "AzureTide",
			BlastAttack = "AzureTideBlast",
			BlastRadius = 9, -- (x its final size, Grow[2]: the blast is as big as the beam has become)
			-- it starts small and swells to massive over its life (a width factor, eased): its hitbox
			-- swells with it (AbilityConfig.BeamGrow)
			Grow = { 0.55, 2.1 },
			-- where the beam leaves the hands in the release pose (the root's frame, measured from the
			-- clip: the midpoint of the hands at 2.25 s, a little ahead of the palms)
			Origin = Vector3.new(-0.1, -0.18, -2.95),
		},
	},
}

-- art used under a licence that asks for credit (keep these lines with the game's credits)
AbilityConfig.Credits = {
	'Azure Tide Cannon icon: "Beam wake" by Lorc (game-icons.net), CC BY 3.0 - https://game-icons.net/1x1/lorc/beam-wake.html',
}

-- the ability on a hero's slot (nil: locked)
-- a cast's clip on its own clock where the timeline slows it (Timeline.Slow): the clip's time at cast
-- time tau, the cast time at a clip time, and the speed a playing clip keeps to stay on it (eased in and
-- out of the slow part, and gently pulled back onto it - never a jolt)
function AbilityConfig.ClipTime(TL: any, tau: number): number
	local s = TL.Slow
	if not s or tau <= s.From then
		return tau
	end
	local slowLen = (s.To - s.From) / s.Speed
	if tau <= s.From + slowLen then
		return s.From + (tau - s.From) * s.Speed
	end
	return s.To + (tau - s.From - slowLen)
end
function AbilityConfig.CastTime(TL: any, clip: number): number
	local s = TL.Slow
	if not s or clip <= s.From then
		return clip
	end
	if clip <= s.To then
		return s.From + (clip - s.From) / s.Speed
	end
	return s.From + (s.To - s.From) / s.Speed + (clip - s.To)
end
-- how big a beam is `since` seconds after it fired (a width factor: Beam.Grow, eased over the Sustain)
function AbilityConfig.BeamGrow(def: any, since: number): number
	local g = def.Beam and def.Beam.Grow
	if not g then
		return 1
	end
	local k = math.clamp(since / def.Timeline.Sustain, 0, 1)
	k = k * k * (3 - 2 * k)
	return g[1] + (g[2] - g[1]) * k
end
function AbilityConfig.ClipSpeed(TL: any, tau: number, pos: number): number
	local s = TL.Slow
	if not s then
		return 1
	end
	local slowEnd = s.From + (s.To - s.From) / s.Speed
	local function smooth(x: number): number
		local k = math.clamp(x, 0, 1)
		return k * k * (3 - 2 * k)
	end
	local base = 1 + (s.Speed - 1) * smooth((tau - s.From + 0.12) / 0.24) * (1 - smooth((tau - slowEnd + 0.12) / 0.24))
	-- (it eases into its held release pose instead of stopping dead on it)
	local hold = TL.Hold or math.huge
	if pos > hold - 0.16 then
		return math.clamp(base * (hold - pos) / 0.16, 0.06, 1)
	end
	return math.clamp(base + (AbilityConfig.ClipTime(TL, tau) - pos) * 3, 0.1, 2)
end

function AbilityConfig.For(hero: string?, slot: string): any
	local kit = hero and AbilityConfig.Kits[hero]
	local id = kit and kit[slot]
	return if id then AbilityConfig.Abilities[id] else nil
end

-- the slot an ability id sits on for a hero (nil: not in its kit)
function AbilityConfig.SlotOf(hero: string?, id: string): string?
	local kit = hero and AbilityConfig.Kits[hero]
	if not kit then
		return nil
	end
	for slot, aid in pairs(kit) do
		if aid == id then
			return slot
		end
	end
	return nil
end

function AbilityConfig.CooldownKey(id: string): string
	return "Ability_" .. id
end

return AbilityConfig
