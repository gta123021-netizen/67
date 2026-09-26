--[[
	CombatConfig  (ReplicatedStorage.Combat.CombatConfig)
	Every tunable of the melee combat + movement layer, in one place. The server and every client
	read the same numbers, so the server's hit timing and the client's animation timing agree.

	THE ANIMATIONS DRIVE THE NUMBERS. Everything marked (pack) was measured from the Battleground
	Combat Animations Pack's own keyframes (R6 forward kinematics, see CombatPaths):
	  Hit        the clip's "Hit" KeyframeMarker - the frame the striking limb lands
	  Active     the clip span the striking limb can connect (CombatPaths holds the limb's path)
	  ChainAt    where the next strike may take over. Swing1 ends in exactly the pose Swing2 starts
	             from and Swing2 ends where Swing3 starts, so the light chain hands over pose-to-pose
	  Blend      cross-fade into the next strike, sized from how far apart the two poses are

	Animation catalogue (pack -> published asset, owned by the game's creator):
	  Fist rig:     Idle, Swing1, Swing2, Swing3, Swing4 (= Swing1, unused), Uppercut, Downslam,
	                Sweeping Kick, GettingHit1 (= GettingHit3), GettingHit2 (= GettingHit4), Block
	  Movement rig: Idle (= fist Idle), Walk Animation, Run, Forward/Backward/Left/Right Dash,
	                Forward Dash Hit, Ground Recovery
	  Katana rig:   a sword set - not used by the fist system
	The pack has no jump/fall/climb clips: those use Roblox's default R6 clips.
]]

local Config = {}

local function id(n: number): string
	return "rbxassetid://" .. tostring(n)
end

---------------------------------------------------------------------------
-- animations
---------------------------------------------------------------------------
-- Priority ladder (low -> high): Idle < Movement (walk/run/jump) < Action (dashes) < Action2 (attacks,
-- block) < Action3 (hit reactions) < Action4 (forced recovery). A higher layer always wins the
-- joints it animates, so a punch never fights the walk cycle and idle never shows through a guard.
Config.Anim = {
	-- locomotion
	CombatIdle = { Id = id(91863880699664), Priority = "Idle", Looped = true }, -- pack: Idle
	NeutralIdle = { Id = id(180435571), Priority = "Idle", Looped = true }, -- Roblox R6 idle (the first 2 s standing)
	Walk = { Id = id(108540848931327), Priority = "Movement", Looped = true }, -- pack: Walk Animation
	Run = { Id = id(85733061375676), Priority = "Movement", Looped = true }, -- pack: Run
	Jump = { Id = id(125750702), Priority = "Movement", Looped = false }, -- Roblox R6 (the pack has none)
	Fall = { Id = id(180436148), Priority = "Movement", Looped = true }, -- Roblox R6
	Climb = { Id = id(180436334), Priority = "Movement", Looped = true }, -- Roblox R6

	-- light chain (M1)
	Swing1 = { Id = id(72184165310237), Priority = "Action2" },
	Swing2 = { Id = id(121622687733291), Priority = "Action2" },
	Swing3 = { Id = id(125012976137941), Priority = "Action2" },
	-- heavy (M2)
	Uppercut = { Id = id(81475139307429), Priority = "Action2" },
	-- finisher
	Sweep = { Id = id(72979195031349), Priority = "Action2" }, -- pack: Sweeping Kick
	-- air (jump, then M1)
	Downslam = { Id = id(90888057343221), Priority = "Action2" },

	-- guard
	Block = { Id = id(84312740440162), Priority = "Action2", Looped = true },

	-- hit reactions. The pack has two (GettingHit1/3 and GettingHit2/4 are the same clips):
	--   HitRight (GettingHit1): the body turns to its right (the right side is driven back)
	--   HitLeft  (GettingHit2): the mirror - the left side is driven back
	HitRight = { Id = id(138550895092940), Priority = "Action3" },
	HitLeft = { Id = id(101143332046090), Priority = "Action3" },

	-- dashes
	DashForward = { Id = id(92484789016463), Priority = "Action" },
	DashBackward = { Id = id(97776212782517), Priority = "Action" },
	DashLeft = { Id = id(110874427805358), Priority = "Action" },
	DashRight = { Id = id(94072553066378), Priority = "Action" },
	DashAttack = { Id = id(92811207144247), Priority = "Action2" }, -- pack: Forward Dash Hit

	-- getting up after a knockdown
	GroundRecovery = { Id = id(86694634070675), Priority = "Action4" },
}

-- natural ground speed of the locomotion clips at playback speed 1 (pack: planted-foot speed)
Config.WalkNatural = 5.0
Config.RunNatural = 13.5

---------------------------------------------------------------------------
-- movement
---------------------------------------------------------------------------
Config.WalkSpeed = 11 -- walk clip at ~2.2x: feet and ground agree
Config.RunSpeed = 22 -- run clip at ~1.6x
Config.RunRamp = 0.3 -- seconds to accelerate walk -> run
Config.AutoRunAfter = 1.1 -- moving this long without stopping breaks into a run
Config.RunBlend = { 13, 18 } -- walk and run cross-fade by speed across this band (studs/s)
Config.IdleDelay = 2 -- standing still this long before the combat idle comes in
Config.JumpHeight = 7.2
Config.BlockWalkSpeed = 4 -- shuffling with the guard up
Config.ComboWalkSpeed = 8 -- between strikes of a live combo

---------------------------------------------------------------------------
-- attack classes: how strong a strike FEELS (shared by every attack of that class)
---------------------------------------------------------------------------
--   Hitstop        both fighters freeze this long on a clean connect (the attacker's clip pauses,
--                  the victim holds the impact pose; knockback starts after it)
--   BlockHitstop   the same on a blocked connect
--   Shake          camera kick for the attacker / the victim
--   BlockPush      how far a blocked hit slides the defender back (studs) over BlockPushTime
--   BlockTilt      the guard giving with the blow (degrees): Roll leans toward the side the blow
--                  drives, Yaw turns that shoulder back, Pitch rocks the guard back - pivoting at the
--                  feet, so the stance stays planted while it slides
--   BlockStun      the guard can't be dropped for this long after absorbing a hit
--   Ui             combo-counter emphasis
Config.Classes = {
	Light = {
		Hitstop = 0.04, BlockHitstop = 0.03, Shake = 0.14, VictimShake = 0.28,
		BlockPush = 2.4, BlockPushTime = 0.18, BlockTilt = { Roll = 5, Yaw = 9, Pitch = 4 }, BlockStun = 0.18,
		Ui = "Light",
	},
	Heavy = {
		Hitstop = 0.09, BlockHitstop = 0.055, Shake = 0.42, VictimShake = 0.62,
		BlockPush = 4.6, BlockPushTime = 0.24, BlockTilt = { Roll = 11, Yaw = 17, Pitch = 9 }, BlockStun = 0.3,
		Ui = "Heavy",
	},
	Finisher = {
		Hitstop = 0.11, BlockHitstop = 0.11, Shake = 0.55, VictimShake = 0.85,
		BlockPush = 0, BlockPushTime = 0, BlockTilt = { Roll = 14, Yaw = 20, Pitch = 12 }, BlockStun = 0,
		Ui = "Finisher",
	},
	Stomp = {
		Hitstop = 0.1, BlockHitstop = 0.1, Shake = 0.5, VictimShake = 0.8,
		BlockPush = 0, BlockPushTime = 0, BlockTilt = { Roll = 8, Yaw = 10, Pitch = 16 }, BlockStun = 0,
		Ui = "Heavy",
	},
	Dash = {
		Hitstop = 0.07, BlockHitstop = 0.05, Shake = 0.35, VictimShake = 0.55,
		BlockPush = 5.2, BlockPushTime = 0.26, BlockTilt = { Roll = 6, Yaw = 10, Pitch = 12 }, BlockStun = 0.28,
		Ui = "Heavy",
	},
}

---------------------------------------------------------------------------
-- combo: M1 = light, M2 = heavy (once per combo), the sweeping kick finishes
---------------------------------------------------------------------------
--   M1 M1 M1 M1          -> Swing1 Swing2 Swing3 Sweep                (4 hits)
--   an M2 anywhere in the first four inserts the Uppercut and the chain grows to 5:
--   M2 M1 M1 M1 M1       -> Uppercut Swing1 Swing2 Swing3 Sweep
--   M1 M2 M1 M1 M1       -> Swing1 Uppercut Swing2 Swing3 Sweep       (and so on)
-- Lights always run Swing1 -> Swing2 -> Swing3 in order (measured: the best-flowing order with the
-- uppercut in every position). See ComboRules for the state machine both sides run.
Config.Combo = {
	Lights = { "Swing1", "Swing2", "Swing3" },
	Heavy = "Uppercut",
	Finisher = "Sweep",
	LightLength = 4, -- M1-only chain: the 4th strike is the sweep
	HeavyLength = 5, -- with the uppercut in it: the 5th strike is the sweep
	Window = 0.4, -- the next strike must start within this long after the current one's chain point
	Buffer = 0.25, -- a press this long before the chain point is kept and fires exactly on it
	FinisherCooldown = 0.55, -- after the sweep's clip, before a new chain can start
	Slack = 0.1, -- server tolerance on every chain timing (network jitter): WHEN a press may arrive
	EarlyStart = 0.03, -- ...but a strike never starts more than this before its chain point (no faster chains)
	StunMargin = 0.13, -- hitstun always outlasts the fastest follow-up by this much
	-- one chain per stun: a NEW chain from the same attacker can't re-stun a body its last chain is
	-- still locking (or let go of less than this long ago) - no restart loops (wait-out, block-cancel,
	-- dash-cancel, uppercut re-open). Those blows still land and push; the victim gets this long to act.
	ResetGrace = 0.35,
}

---------------------------------------------------------------------------
-- attacks
---------------------------------------------------------------------------
--[[ fields
	Anim, Class, Speed      clip, feel class, playback speed
	Hit, ChainAt, Length    clip times (seconds at speed 1): impact, hand-over point, clip end
	Damage                  clean hit; a blocked hit deals Config.Guard.DamageScale of it
	GuardBreak              breaks a guard instead of being blocked (GuardBreakDamage then)
	Stun                    minimum hitstun; inside a chain it is stretched so the fastest possible
	                        follow-up always lands (Config.Combo.StunMargin)
	Knock                   knockback on a clean hit: studs/s { Back, Up, Side } in the attacker's
	                        space over KnockTime (Up is an instant lift)
	Launch                  finisher/stomp: ragdoll launch, horizontal and vertical tuned separately
	Contact                 (pack) where the blow lands, attacker space (sparks, reaction side)
	ReactPush               (pack) which way the blow drives the victim's head: -1 = toward the
	                        attacker's left (a right hand crossing), +1 = toward the attacker's right,
	                        0 = straight in (the side it lands on is driven back)
	React                   reaction clip speed (lower = heavier, more readable)
	Ideal, MaxLunge         (pack) the attacker steps in to Ideal (root to root) during
	                        LungeFrom..LungeTo, so the limb lands on the body at the Hit frame
	Tilt                    extra give in the victim's body (degrees): Pitch, Roll, NeckYaw, NeckPitch
	Blend                   cross-fade INTO this strike, per previous strike (pose distance measured)
	Hitbox                  limb radius around the CombatPaths capsules (+ Config.Hitbox.Pad)
]]
Config.Attacks = {
	Swing1 = {
		-- right cross: loads the right shoulder back, snaps through on the Hit frame
		Anim = "Swing1", Class = "Light", Speed = 1.15, Hit = 0.3667, ChainAt = 0.42, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 14, Up = 0, Side = -3 }, KnockTime = 0.2,
		Contact = Vector3.new(0.2, 0.47, -3.11), ReactPush = -1, React = 1.1,
		Ideal = 3.3, MaxLunge = 3.8, LungeFrom = 0.14, LungeTo = 0.34,
		Tilt = { Pitch = 5, Roll = 0, NeckYaw = 14 },
		Blend = { Default = 0.1, Uppercut = 0.12 },
		Hitbox = 0.45, Name = "Cross",
	},
	Swing2 = {
		-- left straight: starts from Swing1's finish, same timing mirrored
		Anim = "Swing2", Class = "Light", Speed = 1.15, Hit = 0.3667, ChainAt = 0.42, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 14, Up = 0, Side = 3 }, KnockTime = 0.2,
		Contact = Vector3.new(-0.13, 0.39, -3.06), ReactPush = 1, React = 1.1,
		Ideal = 3.3, MaxLunge = 3.8, LungeFrom = 0.14, LungeTo = 0.34,
		Tilt = { Pitch = 5, Roll = 0, NeckYaw = -14 },
		Blend = { Default = 0.12, Swing1 = 0.06, Uppercut = 0.15 },
		Hitbox = 0.45, Name = "Straight",
	},
	Swing3 = {
		-- two-handed hook from the right: winds the body all the way round, lands close and to the right
		Anim = "Swing3", Class = "Light", Speed = 1.15, Hit = 0.3833, ChainAt = 0.44, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 16, Up = 0, Side = -5 }, KnockTime = 0.2,
		Contact = Vector3.new(1.16, 0.55, -0.9), ReactPush = -1, React = 1.0,
		Ideal = 1.7, MaxLunge = 4.4, LungeFrom = 0.14, LungeTo = 0.37,
		Tilt = { Pitch = 4, Roll = -8, NeckYaw = 22 },
		Blend = { Default = 0.12, Swing2 = 0.06, Uppercut = 0.11 },
		Hitbox = 0.48, Name = "Hook",
	},
	Uppercut = {
		-- heavy: a long readable load (the left hand drops behind the hip), then the fist rises
		-- through the chin. ~40% slower than a light: Hit at 0.47 s vs 0.32 s
		Anim = "Uppercut", Class = "Heavy", Speed = 0.82, Hit = 0.3833, ChainAt = 0.42, Length = 0.6667,
		Damage = 5.5, Stun = 0.8,
		Knock = { Back = 24, Up = 26, Side = 0 }, KnockTime = 0.2,
		Contact = Vector3.new(0.34, 1.71, -2.68), ReactPush = 1, React = 0.72,
		Ideal = 2.8, MaxLunge = 3.8, LungeFrom = 0.12, LungeTo = 0.36,
		Tilt = { Pitch = 20, Roll = 0, NeckYaw = 0, NeckPitch = 26 },
		Blend = { Default = 0.12, Swing1 = 0.13, Swing2 = 0.14, Swing3 = 0.15 },
		Hitbox = 0.5, Name = "Uppercut",
	},
	Sweep = {
		-- finisher: a spinning hop that drops into a low sweep; the right foot crosses the front at
		-- ground level toward the attacker's right. Clean: launch + ragdoll. Guarded: guard break.
		Anim = "Sweep", Class = "Finisher", Speed = 1.3, Hit = 0.9, ChainAt = 1.1667, Length = 1.1667,
		Damage = 6.5, Stun = 0, GuardBreak = true, GuardBreakDamage = 3.5,
		Knock = { Back = 46, Up = 0, Side = 10 }, KnockTime = 0.34, -- (guard break slide)
		Launch = { Back = 66, Up = 38, Side = 8, LegsUp = 16, LegsSide = 16, Tip = 3.0, Time = 1.6 },
		Contact = Vector3.new(0.61, -2.55, -2.89), ReactPush = 1, React = 1,
		Ideal = 3.0, MaxLunge = 3.8, LungeFrom = 0.45, LungeTo = 0.86,
		Tilt = nil,
		Blend = { Default = 0.16, Swing3 = 0.17, Uppercut = 0.16 },
		Hitbox = 0.55, Name = "Sweep",
	},

	-- forward dash + M1: the lunge punch low into the body, carrying the dash's momentum
	DashAttack = {
		Anim = "DashAttack", Class = "Dash", Speed = 1, Hit = 0.05, ChainAt = 0.25, Length = 0.25, Hold = 0.2,
		Damage = 5.5, Stun = 0.85,
		Knock = { Back = 80, Up = 16, Side = 0 }, KnockTime = 0.24,
		Contact = Vector3.new(0.59, -0.67, -4.17), ReactPush = 0, React = 0.8,
		Ideal = 3.4, MaxLunge = 0, LungeFrom = 0, LungeTo = 0,
		Tilt = { Pitch = 16, Roll = 0, NeckYaw = 8, NeckPitch = 12 },
		Blend = { Default = 0.04 },
		Hitbox = 0.5, Name = "Dash Strike",
		Cooldown = 0.35,
	},

	-- jump + M1: drop out of the air into a stomp (pack: the raised left foot drives down on Hit)
	Downslam = {
		Anim = "Downslam", Class = "Stomp", Speed = 1, Hit = 0.3833, ChainAt = 0.5833, Length = 0.5833,
		Damage = 7, Stun = 0, GuardBreak = true, GuardBreakDamage = 3.5,
		Knock = { Back = 38, Up = 0, Side = 0 }, KnockTime = 0.3, -- (guard break slide)
		Launch = { Back = 32, Up = 26, Side = 0, LegsUp = 12, LegsSide = 0, Tip = 2.4, Time = 1.25 },
		Contact = Vector3.new(-0.5, -2.9, -1.1), ReactPush = 0, React = 1,
		Ideal = 2.5, MaxLunge = 0, LungeFrom = 0, LungeTo = 0,
		Blend = { Default = 0.06 },
		Hitbox = 0.6, Name = "Stomp",
		Cooldown = 2.2, Hang = 0.08,
		-- the clip holds its raised-knee pose until the feet touch down, then stomps: StompAt is the
		-- clip time the stomp resumes from on touchdown; the impact follows StompDelay later (pack Hit)
		StompAt = 0.345, StompDelay = 0.04, FallSpeed = { 34, 140 }, MaxFall = 1.4,
		-- the landing shock hits everyone standing on the shatter: StompRadius is the shattered
		-- ground's own reach (CombatShatter's outer ring of broken ground and rock spikes is built
		-- from this radius), to a fighter's centre; StompHeight is how far above the foot their feet
		-- may be
		StompRadius = 7, StompHeight = 3.2,
	},
}

---------------------------------------------------------------------------
-- hit detection
---------------------------------------------------------------------------
-- Every striking limb is a capsule following its measured path (CombatPaths) through the attack's
-- active frames; between two frames the tip's swept path is tested too, so a fast snap can't
-- skip a body. A fighter's body is a box in its own space (arms included). One strike hits each
-- fighter at most once.
Config.Hitbox = {
	Body = { HalfWidth = 1.5, Bottom = -3.0, Top = 2.1, HalfDepth = 0.6 },
	Pad = 0.12, -- added to every limb radius
	-- a connecting chain strike carries its attacker along with the victim it knocks back (this share
	-- of the victim's slide), so a combo drives the fight across the ground instead of pushing the
	-- victim out of reach
	Follow = 0.85,
	-- lag compensation (a player attacker): the victim is tested where the ATTACKER saw it - rewound
	-- by the round trip plus Roblox's replication interpolation
	Rewind = 0.12, -- interpolation delay of replicated bodies
	RewindMax = 0.35,
	-- ...and the attacker is placed where its own screen had it. The server's copy of a player's body
	-- trails the player's screen by the replication delay (a few tenths of a second - longer than a
	-- step-in), so the owning client reports its root as the strike's active frames begin and midway.
	-- The server checks the report against its own copy and waits a moment for it before judging.
	ReportDrift = 7, -- max studs between a report and the server's copy of that body (else ignored)
	ReportWait = 0.25, -- max seconds the server waits past the active frames' start for a report
	ReportLead = 0.12, -- max seconds a report is carried forward along its velocity
	LagLead = 0.05, -- no report: the server's copy is led this far along its velocity
	MaxTargets = 4,
}

-- reaction replacement: a new reaction restarts the clip only if the old one has run this long,
-- or the new hit is heavier (no zero-frame vibration when several hits land together)
Config.ReactMinGap = 0.13

---------------------------------------------------------------------------
-- guard
---------------------------------------------------------------------------
Config.Guard = {
	DamageScale = 0.25, -- a blocked hit deals 25% (75% reduction)
	Arc = 0.05, -- blocks when dot(defender look, to attacker) > this (front ~175 degrees)
	StartDelay = 0.05, -- the guard is up this long after pressing block
	BreakStun = 1.05, -- guard broken: no control for this long
	BreakReactSpeed = 0.56, -- the directional hit reaction, slowed: heavier and readable
	ReblockAfter = 0.35, -- after the break ends, before the guard can go up again
	LeanTime = 0.32, -- the block tilt's settle time (heavy: x1.25)
}

---------------------------------------------------------------------------
-- dashes (one button; the direction comes from movement input)
---------------------------------------------------------------------------
-- Distance/Duration: root travel. The clip leads (torso shoots toward the dash) and the root
-- catches up; FadeAt is when the clip hands back to locomotion; Lock is when control returns.
Config.Dash = {
	Cooldown = 1.25,
	Forward = { Anim = "DashForward", Speed = 1, Distance = 20, Duration = 0.4, FadeAt = 0.46, Lock = 0.44, AttackFrom = 0.05, AttackTo = 0.46 },
	-- the back dash's recovery plays slower than its launch (TailAt seconds in, the clip drops to
	-- TailSpeed) and the slide eases out over the longer tail, so it lands instead of snapping back
	Backward = { Anim = "DashBackward", Speed = 1.35, TailAt = 0.4, TailSpeed = 0.95, Distance = 16, Duration = 0.72, Delay = 0.05, FadeAt = 0.96, Lock = 0.92 },
	Left = { Anim = "DashLeft", Speed = 1, Distance = 15, Duration = 0.36, FadeAt = 0.44, Lock = 0.4 },
	Right = { Anim = "DashRight", Speed = 1, Distance = 15, Duration = 0.36, FadeAt = 0.44, Lock = 0.4 },
	Ramp = 0.05, -- seconds to reach full speed
	Ease = 1.6, -- deceleration curve over the last 45%
	StopGap = 3.2, -- a dash stops this far (root to root) from a fighter in its path, never through them
	StopWidth = 2.6, -- how wide the path is
}

---------------------------------------------------------------------------
-- knockdown / recovery
---------------------------------------------------------------------------
Config.Recovery = {
	Speed = 1.1, -- Ground Recovery playback
	ControlAt = 0.55, -- (pack marker RecoverControl) movement returns
	ActionsAt = 0.72, -- attacks/dash/block return
}

---------------------------------------------------------------------------
-- rules
---------------------------------------------------------------------------
Config.StunCap = 3.2 -- continuous hitstun from any number of attackers is capped at this...
Config.StunImmunity = 0.9 -- ...then the victim gets this long to act
Config.AssistRange = 9 -- step-in / facing assist: targets this close...
Config.AssistAngle = 65 -- ...and within this many degrees of the aim
Config.KillCredit = 10 -- seconds a hit counts toward a kill
-- the knockout blow throws the body: its own Launch (sweep, stomp), else this throw straight back
Config.KOLaunch = { Back = 34, Up = 30, Side = 0, LegsUp = 20, LegsSide = 0, Tip = 2.6, Time = 1.4 }
-- practice dummies: this much health, so one full string knocks them out on its finisher (a light
-- string deals 3.5 x3 + the sweep's 6.5 = 17; with the uppercut in it 16 before the sweep)
Config.DummyHealth = 16.5
Config.RequestRate = 25 -- max combat requests per second per player
Config.StudioDummies = true -- practice dummies next to the spawn when testing in Studio

---------------------------------------------------------------------------
-- sounds (Roblox's built-in client sounds; swap the ids for your own)
---------------------------------------------------------------------------
Config.Sounds = {
	Swing = { Id = "rbxasset://sounds/swordslash.wav", Volume = 0.28, Speed = 1.45 },
	HeavySwing = { Id = "rbxasset://sounds/swordlunge.wav", Volume = 0.34, Speed = 1.05 },
	Hit = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 1.6, Speed = 1.5 },
	HeavyHit = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 2.1, Speed = 1.0 },
	Block = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.5, Speed = 1.7 },
	HeavyBlock = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.65, Speed = 1.25 },
	GuardBreak = { Id = "rbxasset://sounds/glassbreak.wav", Volume = 0.75, Speed = 0.9 },
	GuardBreakThud = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 2.2, Speed = 0.7 },
	Dash = { Id = "rbxasset://sounds/swordlunge.wav", Volume = 0.35, Speed = 0.8 },
	Slam = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 2.4, Speed = 0.62 },
	Knockdown = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 2.2, Speed = 0.78 },
}

---------------------------------------------------------------------------
-- derived
---------------------------------------------------------------------------
-- dash speed profile s(t) in 0..1 (ramp in, hold, ease out) and the top speed that covers Distance
function Config.DashProfile(t: number, duration: number): number
	local d = Config.Dash
	if t <= 0 or t >= duration then
		return 0
	end
	local up = math.min(1, t / d.Ramp)
	local easeStart = duration * 0.55
	if t <= easeStart then
		return up
	end
	return up * ((duration - t) / (duration - easeStart)) ^ d.Ease
end

for _, dir in ipairs({ "Forward", "Backward", "Left", "Right" }) do
	local def = Config.Dash[dir]
	local area, steps = 0, 400
	for i = 1, steps do
		area += Config.DashProfile((i - 0.5) / steps * def.Duration, def.Duration) * def.Duration / steps
	end
	def.TopSpeed = def.Distance / area
end

for name, a in pairs(Config.Attacks) do
	a.Id = name
	a.HitReal = a.Hit / a.Speed -- seconds from start to impact
	a.ChainReal = a.ChainAt / a.Speed
	a.LengthReal = a.Length / a.Speed
	a.ClassDef = Config.Classes[a.Class]
	a.Rank = if a.Class == "Light" then 1 elseif a.Class == "Heavy" then 3 elseif a.Class == "Dash" then 4 else 5
end

-- cross-fade into `to` after `from` (nil = from locomotion)
function Config.BlendInto(from: string?, to: string): number
	local def = Config.Attacks[to]
	if not def or not def.Blend then
		return 0.1
	end
	if from and def.Blend[from] then
		return def.Blend[from]
	end
	return def.Blend.Default or 0.1
end

return Config
