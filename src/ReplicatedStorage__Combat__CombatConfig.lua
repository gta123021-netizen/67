--[[
	CombatConfig  (ReplicatedStorage.Combat.CombatConfig)
	Every tunable of the melee combat + movement layer, in one place. The server and every client
	read the same numbers, so the server's hit timing and the client's animation timing agree.

	THE ANIMATIONS DRIVE THE NUMBERS. Everything marked (pack) was measured from the Battleground
	Combat Animations Pack's own keyframes with R6 forward kinematics (tools/anim.py, contact.py,
	choreo_analyze.py):
	  Hit        the clip's "Hit" KeyframeMarker - the frame the striking limb lands
	  Ideal      where the strike is meant to land, root to root: the distance at which the striking
	             limb touches a standing body on the Hit frame (exact box geometry of both rigs) less a
	             short sink, so the fist visibly drives into the body (never an air punch or a clip-through)
	  ChainAt    where the next strike may take over
	  Transitions  per PAIR of strikes: how the next clip enters (skip into its wind-up where its
	             pose matches the last strike's follow-through) and how long the two cross-fade

	FREE-FORM. There is no target lock, no auto-facing and no homing: a strike goes where its
	attacker faces (the aim), its step-in travels straight along that facing, and a connected blow
	drives the victim straight along it too - so a chain keeps its geometry by itself, from any
	angle, while both fighters stay free to move and turn.

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

	-- hit reactions. The pack has two (GettingHit1/3 and GettingHit2/4 are the same clips). Both
	-- START already turned (torso 32 deg, head 47 deg) and END at the far extreme (torso 64 deg, head
	-- 46 deg, pitched down 43): the victim is never snapped back to neutral between blows - it
	-- settles part way (Config.React) and every new blow drives it on from wherever it is.
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

-- facing: a strike turns its attacker to the AIM (camera in shift lock, else the movement input,
-- else where it already faces) - a quick critically damped turn (natural frequency rad/s, top
-- rate rad/s), never toward anybody
Config.Facing = { Omega = 34, MaxRate = 22 }

---------------------------------------------------------------------------
-- attack classes: how strong a strike FEELS (shared by every attack of that class)
---------------------------------------------------------------------------
--   Hitstop        both fighters freeze this long on a clean connect (the attacker's clip pauses,
--                  the victim holds the impact pose; knockback starts after it). Light to heavy:
--                  light 0.05 < dash strike 0.075 < uppercut 0.09 < sweep 0.1 < stomp 0.11;
--                  a guard break is the heaviest freeze of all (Config.Guard.BreakHitstop)
--   BlockHitstop   the same on a blocked connect (a blocked blow gives a shorter, duller freeze)
--   Camera         the camera profile (Config.Camera) for the attacker / the victim
--   BlockPush      how far a blocked hit slides the defender back (studs) over BlockPushTime
--   BlockTilt      the guard giving with the blow (degrees): Roll leans toward the side the blow
--                  drives, Yaw turns that shoulder back, Pitch rocks the guard back - pivoting at the
--                  feet, so the stance stays planted while it slides
--   BlockStun      the guard can't be dropped for this long after absorbing a hit
--   Ui             combo-counter emphasis
Config.Classes = {
	Light = {
		Hitstop = 0.05, BlockHitstop = 0.035, Camera = "Light", VictimCamera = "LightTaken",
		BlockPush = 2.4, BlockPushTime = 0.18, BlockTilt = { Roll = 5, Yaw = 9, Pitch = 4 }, BlockStun = 0.18,
		Ui = "Light",
	},
	Heavy = {
		Hitstop = 0.09, BlockHitstop = 0.06, Camera = "Heavy", VictimCamera = "HeavyTaken",
		BlockPush = 4.6, BlockPushTime = 0.24, BlockTilt = { Roll = 11, Yaw = 17, Pitch = 9 }, BlockStun = 0.3,
		Ui = "Heavy",
	},
	Finisher = {
		Hitstop = 0.1, BlockHitstop = 0.07, Camera = "Sweep", VictimCamera = "HeavyTaken",
		BlockPush = 0, BlockPushTime = 0, BlockTilt = { Roll = 14, Yaw = 20, Pitch = 12 }, BlockStun = 0,
		Ui = "Finisher",
	},
	Stomp = {
		-- (a guarded smash is simply blocked - never a guard break: the ground shock rocks the guard back
		-- and slides it like a heavy blow)
		Hitstop = 0.11, BlockHitstop = 0.07, Camera = "Stomp", VictimCamera = "HeavyTaken",
		BlockPush = 3.8, BlockPushTime = 0.3, BlockTilt = { Roll = 8, Yaw = 10, Pitch = 16 }, BlockStun = 0.3,
		Ui = "Heavy",
	},
	Dash = {
		Hitstop = 0.075, BlockHitstop = 0.055, Camera = "Heavy", VictimCamera = "HeavyTaken",
		BlockPush = 5.2, BlockPushTime = 0.26, BlockTilt = { Roll = 6, Yaw = 10, Pitch = 12 }, BlockStun = 0.28,
		Ui = "Heavy",
	},
}

---------------------------------------------------------------------------
-- camera feedback: short directional impulses, never a continuous shake
---------------------------------------------------------------------------
--   Kick    how far the view is knocked along the blow (studs, eased out and back)
--   Up      extra vertical share of the kick (+ = up; the sweep kicks low)
--   Roll    a small roll into the blow (degrees)
--   Fov     a quick zoom punch (degrees narrower at the peak)
--   Time    how long until it has settled
--   Rumble  { amplitude (studs), seconds }: a faint low-frequency tremor after (the ground smash)
Config.Camera = {
	Light = { Kick = 0.09, Up = 0.1, Roll = 0.5, Fov = 0, Time = 0.14 },
	Hook = { Kick = 0.12, Up = 0.05, Roll = 0.9, Fov = 0, Time = 0.16 },
	Heavy = { Kick = 0.22, Up = 0.35, Roll = 0.8, Fov = 2.2, Time = 0.22 },
	Sweep = { Kick = 0.2, Up = -0.45, Roll = 1.1, Fov = 1.6, Time = 0.24 },
	Stomp = { Kick = 0.38, Up = -0.8, Roll = 0.6, Fov = 3.2, Time = 0.26, Rumble = { 0.05, 0.4 } }, -- (the tremor ends as the dust peaks)
	LightTaken = { Kick = 0.16, Up = 0.05, Roll = 1.2, Fov = 0, Time = 0.16 },
	HeavyTaken = { Kick = 0.3, Up = 0.2, Roll = 1.8, Fov = 1.5, Time = 0.24 },
	Block = { Kick = 0.06, Up = 0, Roll = 0.3, Fov = 0, Time = 0.12 },
	GuardBreak = { Kick = 0.3, Up = 0.1, Roll = 1.4, Fov = 2.5, Time = 0.26 },
	StompNear = { Kick = 0.22, Up = -0.6, Roll = 0.5, Fov = 1.2, Time = 0.24, Rumble = { 0.04, 0.45 } },
	LinkDash = { Kick = -0.25, Up = 0, Roll = 0, Fov = -7, Time = 0.42 }, -- (the chase: the view widens, pulled back)
}

---------------------------------------------------------------------------
-- combo: M1 = light, M2 = heavy (once per combo), the sweeping kick finishes
---------------------------------------------------------------------------
--   M1 M1 M1 M1          -> Swing1 Swing2 Swing3 Sweep                (4 hits)
--   an M2 anywhere in the first four inserts the Uppercut and the chain grows to 5:
--   M2 M1 M1 M1 M1       -> Uppercut Swing1 Swing2 Swing3 Sweep
--   M1 M2 M1 M1 M1       -> Swing1 Uppercut Swing2 Swing3 Sweep       (and so on)
--   the dash strike (forward dash + M1) opens a chain as its first light (its lunge ends where the
--   left straight begins):
--   dash+M1 M1 M1 M1     -> DashAttack Swing2 Swing3 Sweep            (4 hits)
--   dash+M1 M2 M1 M1 M1  -> DashAttack Uppercut Swing2 Swing3 Sweep   (5, the uppercut anywhere)
--   the Ground Smash leads in: a dash strike inside its stun carries its chain on (Downslam.Opens)
-- Lights always run Swing1 -> Swing2 -> Swing3 in order. See ComboRules for the state machine both
-- sides run.
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
	-- still holding (or let go of less than this long ago) - no restart loops (wait-out, block-cancel,
	-- dash-cancel, uppercut re-open). Those blows still land and push; the victim gets this long to act.
	ResetGrace = 0.35,
}

---------------------------------------------------------------------------
-- transitions: every legal pair of strikes, tuned on its own (choreo_analyze.py measured, for each
-- pair, how far the next clip's pose is from the last one's follow-through at every hand-over and
-- entry time; mean over 13 body keypoints, studs)
--   Enter   the next clip starts this far into itself (clip seconds): its first frames wind back
--           toward a pose the last strike's follow-through is already past, so they are skipped
--   Blend   the cross-fade from the last clip's follow-through into the next one (seconds): short
--           where the poses already meet, long where the body really has to travel
-- the light chain hands over pose to pose (Swing1 ends in Swing2's first pose, Swing2 in Swing3's);
-- the uppercut's raised arm and the sweep's spin are the far ones.
---------------------------------------------------------------------------
Config.Transitions = {
	Swing1 = {
		Swing2 = { Enter = 0, Blend = 0.08 }, -- 0.34 apart at the hand-over, 0 at the clip's end
		Uppercut = { Enter = 0.05, Blend = 0.12 }, -- 0.73: the loading left hand is already low
	},
	Swing2 = {
		Swing3 = { Enter = 0, Blend = 0.09 }, -- 0.44
		Uppercut = { Enter = 0, Blend = 0.16 }, -- 1.50: the left arm drops from full extension
	},
	Swing3 = {
		Sweep = { Enter = 0.07, Blend = 0.14 }, -- 1.09 (1.77 without the skip): into the spin
		Uppercut = { Enter = 0, Blend = 0.15 }, -- 1.41: out of the hook's wind
	},
	-- (fk.luau measured from the Forward Dash Hit's held lunge: its pose is still from 0.12 s)
	DashAttack = {
		Swing2 = { Enter = 0, Blend = 0.14 }, -- 1.50: the loaded left fires as the lunge rises (same arms)
		Uppercut = { Enter = 0.03, Blend = 0.15 }, -- 1.55 (flat over its first frames)
	},
	Uppercut = {
		Swing1 = { Enter = 0.06, Blend = 0.13 }, -- 1.15: the risen arm comes down into the cross
		Swing2 = { Enter = 0.03, Blend = 0.17 }, -- 1.82: the longest way (the same arm swaps roles)
		Swing3 = { Enter = 0.02, Blend = 0.12 }, -- 0.66: the uppercut's turn winds the hook
		Sweep = { Enter = 0.07, Blend = 0.16 }, -- 1.57
	},
}
-- out of locomotion / idle (the first strike of a chain), and into the strikes outside the chain
Config.EntryBlend = { Swing1 = 0.08, Swing2 = 0.08, Swing3 = 0.09, Uppercut = 0.1, Sweep = 0.12, DashAttack = 0.06, Downslam = 0.06 }

---------------------------------------------------------------------------
-- stun budget: how much hitstun a fighter can be kept in before it gets a real chance to act.
-- Every stun (from anyone) spends it; it refills only while the fighter actually has control (free,
-- attacking, guarding or dashing) and only after Grace of unbroken control - a few frames of
-- "free" between two strings never refill it. When it runs out, the stun in progress is the last
-- one: then Config.StunImmunity - hits still hurt and push, but they neither stun nor interrupt -
-- so the fighter always gets a real window to block, dash or hit back. Sized so the longest
-- legitimate string always fits in a full budget: the smash, a dash strike at the very end of its
-- stun, the uppercut chain into the sweep (~3.45 s of stun, hit-stops included).
---------------------------------------------------------------------------
Config.StunBudget = {
	Max = 3.9,
	Grace = 0.25,
	Refill = 1.5, -- seconds of control to refill an empty budget
	Min = 0.1, -- less than this left counts as empty
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
	Knock                   knockback on a clean hit (studs/s over KnockTime): Back = straight along
	                        the ATTACKER'S FACING (the way the blow travels), Up = an instant lift.
	                        Sized per strike so the victim ends where the next strike lands: a light
	                        pushes ~1.4 studs, the hook ~1.9, the uppercut pops them up and ~1.6 back
	Launch                  finisher/stomp: ragdoll launch, horizontal and vertical tuned separately
	Contact                 (pack) where the blow lands, attacker space (effects, reaction side)
	ReactPush               (pack) which way the blow drives the victim's head: -1 = toward the
	                        attacker's left (a right hand crossing), +1 = toward the attacker's right,
	                        0 = straight in (the side it lands on is driven back)
	React                   reaction clip speed (lower = heavier, more readable)
	Reel                    the body's own give on top of the reaction clip (degrees / studs at the
	                        peak, a spring that ADDS to whatever give is already there - no reset):
	                        Pitch (+ back), Yaw (+ turns with the blow), Roll, NeckYaw, NeckPitch
	                        (+ head back), Omega (spring speed: heavy is slower)
	Ideal                   (pack) where the strike lands, root to root (see the header)
	Step                    the step-in: straight along the facing during clip times From..To, up to
	                        Max studs - it stops where the body ahead (if any, in the strike's lane)
	                        is at Ideal on the Hit frame, and is a short Base step when nobody is there.
	                        It never turns and never steers: it is the body's weight going into the blow
	Impact                  the effect tier (CombatFX): Light, Hook, Heavy, Sweep, Dash, Stomp
	Blood                   the blood profile (Config.Blood.Profiles): Light, Hook, Heavy, Dash, Stomp,
	                        Finisher
	Hitbox                  limb radius around the CombatPaths capsules (+ Config.Hitbox.Pad)
	Shorten                 (optional) this strike's own Config.Hitbox.Shorten - each strike's hitbox
	                        is tuned so its reach matches its real limb (tests/reach_probe.luau)
	MaxTargets              bodies one strike may connect with (a punch stops on the first in its path)
]]
Config.Attacks = {
	Swing1 = {
		-- right cross: loads the right shoulder back, snaps through on the Hit frame
		Anim = "Swing1", Class = "Light", Speed = 1.15, Hit = 0.3667, ChainAt = 0.42, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 12, Up = 0 }, KnockTime = 0.2,
		Contact = Vector3.new(0.2, 0.47, -3.11), ReactPush = -1, React = 1.1,
		Reel = { Pitch = 7, Yaw = 9, Roll = 3, NeckYaw = 18, NeckPitch = 7, Omega = 17 },
		Ideal = 3.45,
		Step = { From = 0.1, To = 0.35, Base = 0.55, Max = 2.0 },
		Impact = "Light", Blood = "Light",
		Hitbox = 0.45, Name = "Cross", MaxTargets = 1,
	},
	Swing2 = {
		-- left straight: starts from Swing1's finish, same timing mirrored
		Anim = "Swing2", Class = "Light", Speed = 1.15, Hit = 0.3667, ChainAt = 0.42, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 12, Up = 0 }, KnockTime = 0.2,
		Contact = Vector3.new(-0.13, 0.39, -3.06), ReactPush = 1, React = 1.1,
		Reel = { Pitch = 8, Yaw = 9, Roll = 3, NeckYaw = 18, NeckPitch = 8, Omega = 17 },
		Ideal = 3.35,
		Step = { From = 0.1, To = 0.35, Base = 0.55, Max = 2.0 },
		Impact = "Light", Blood = "Light",
		Hitbox = 0.45, Shorten = 0.95, Name = "Straight", MaxTargets = 1,
	},
	Swing3 = {
		-- two-handed hook from the right: winds the body round and lunges the torso forward; the lead
		-- arm crosses the front on the Hit frame. It TWISTS the victim rather than pushing the head back
		Anim = "Swing3", Class = "Light", Speed = 1.15, Hit = 0.3833, ChainAt = 0.44, Length = 0.6667,
		Damage = 3.5, Stun = 0.5,
		Knock = { Back = 15, Up = 0 }, KnockTime = 0.22,
		Contact = Vector3.new(1.16, 0.55, -0.9), ReactPush = -1, React = 1.0,
		Reel = { Pitch = 3, Yaw = 22, Roll = 8, NeckYaw = 28, NeckPitch = 2, Omega = 14 },
		Ideal = 3.1,
		Step = { From = 0.1, To = 0.37, Base = 0.5, Max = 2.0 },
		Impact = "Hook", Blood = "Hook",
		Hitbox = 0.38, Shorten = 0.95, Name = "Hook", MaxTargets = 1,
	},
	Uppercut = {
		-- heavy: a long readable load (the left hand drops behind the hip), then the fist rises
		-- through the chin. ~40% slower than a light: Hit at 0.47 s vs 0.32 s. It lifts: the head
		-- snaps UP and back, the body arches and pops off its feet
		Anim = "Uppercut", Class = "Heavy", Speed = 0.82, Hit = 0.3833, ChainAt = 0.42, Length = 0.6667,
		Damage = 5.5, Stun = 0.8,
		Knock = { Back = 13, Up = 20 }, KnockTime = 0.22, -- (a 1-stud pop off the feet: set, never added to a jump - Motion.Push)
		Contact = Vector3.new(0.34, 1.71, -2.68), ReactPush = 1, React = 0.72,
		Reel = { Pitch = 20, Yaw = 0, Roll = 0, NeckYaw = 0, NeckPitch = 34, Omega = 11 },
		Ideal = 3.3,
		Step = { From = 0.1, To = 0.37, Base = 0.7, Max = 2.2 },
		Impact = "Heavy", Blood = "Heavy",
		Hitbox = 0.5, Name = "Uppercut", MaxTargets = 1,
	},
	Sweep = {
		-- finisher: a spinning hop that drops into a low sweep; the right foot crosses the front at
		-- ground level toward the attacker's right. Clean: launch + ragdoll. Guarded: guard break.
		Anim = "Sweep", Class = "Finisher", Speed = 1.3, Hit = 0.9, ChainAt = 1.1667, Length = 1.1667,
		Damage = 6.5, Stun = 0, GuardBreak = true, GuardBreakDamage = 3.5,
		Knock = { Back = 40, Up = 0 }, KnockTime = 0.34, -- (guard break slide)
		Launch = { Back = 66, Up = 38, Side = 8, LegsUp = 16, LegsSide = 16, Tip = 3.0, Time = 1.6 },
		Contact = Vector3.new(0.61, -2.55, -2.89), ReactPush = 1, React = 1,
		-- (the give when it can't take them down: guard break, or a stun-immune fighter - the legs buckle)
		Reel = { Pitch = -8, Yaw = 6, Roll = 7, NeckYaw = 0, NeckPitch = -12, Omega = 11 },
		Ideal = 3.6,
		Step = { From = 0.4, To = 0.88, Base = 0.8, Max = 2.4 },
		Impact = "Sweep", Blood = "Finisher",
		-- (the whole shin sweeps through: the capsule runs to the foot's end, not short of it)
		Hitbox = 0.55, Shorten = 0, Name = "Sweep", MaxTargets = 1,
		FollowGround = true, -- on a slope or a step the sweep reaches the victim's shins (HitDetect)
	},

	-- forward dash + M1: the lunge punch low into the body, carrying the dash's momentum; it opens a
	-- chain as its first light (Config.Combo). CarryMax: its Ideal is the game's longest, so its carry
	-- may cover the whole way to the next strike's reach
	DashAttack = {
		Anim = "DashAttack", Class = "Dash", Speed = 1, Hit = 0.05, ChainAt = 0.16, Length = 0.25, Hold = 0.2,
		Damage = 4.5, Stun = 0.85,
		Knock = { Back = 14, Up = 0 }, KnockTime = 0.24, CarryMax = 1.25,
		Contact = Vector3.new(0.59, -0.67, -4.17), ReactPush = 0, React = 0.8,
		-- a blow to the gut: the body folds FORWARD over it, the head drops
		Reel = { Pitch = -16, Yaw = 4, Roll = 0, NeckYaw = 6, NeckPitch = -20, Omega = 12 },
		Ideal = 4.6,
		Impact = "Dash", Blood = "Dash",
		Hitbox = 0.5, Name = "Dash Strike", MaxTargets = 1,
		Cooldown = 0.35,
	},

	-- jump + M1: GROUND SMASH, the way into a string. Never out of a live chain; needs a real jump and
	-- a landing. An area blow; a guard blocks it. Clean: the heavy reaction played slow and a long slide
	-- out from the smash (~18 studs gliding out over 1.2 s: the dash has real ground to chase down),
	-- held for Stun - and a dash strike thrown before that ends carries the smash's chain on (Opens).
	-- The smasher's recovery lets it breathe: from TailAt (clip time, the impact settled) the clip
	-- plays at TailSpeed, so the victim is seen flying before the dash can go (a dash pressed in it goes
	-- the moment it ends); the dash after a landed smash is lined up on its victim (LinkAssist)
	Downslam = {
		Anim = "Downslam", Class = "Stomp", Speed = 1, Hit = 0.3833, ChainAt = 0.5833, Length = 0.5833,
		TailAt = 0.44, TailSpeed = 0.55,
		Damage = 5, Stun = 1.3, Opens = "DashAttack",
		Knock = { Back = 26, Up = 0 }, KnockTime = 1.2, -- (straight out from the smash)
		Contact = Vector3.new(-0.5, -2.9, -1.1), ReactPush = 0, React = 0.55,
		-- (rocked back from the shock, slow enough to reel the whole slide)
		Reel = { Pitch = 13, Yaw = 6, Roll = 5, NeckYaw = 10, NeckPitch = 18, Omega = 7 },
		Ideal = 2.5,
		Impact = "Stomp", Blood = "Stomp",
		Hitbox = 0.6, Name = "Stomp", MaxTargets = 8,
		Cooldown = 2.2, Hang = 0.08,
		-- the clip holds its raised-knee pose until the feet touch down, then stomps: StompAt is the
		-- clip time the stomp resumes from on touchdown; the impact follows StompDelay later (pack Hit)
		StompAt = 0.345, StompDelay = 0.04, FallSpeed = { 34, 140 }, MaxFall = 1.4,
		-- the landing shock hits everyone standing on the broken ground. StompRadius is the VISIBLE
		-- reach of the fracture (CombatShatter's fissures and its shockwave end exactly there); a
		-- fighter is hit when their footprint reaches it: centre within StompRadius + StompFoot.
		-- StompLow / StompHeight: how far below / above the ground at the impact their feet may be
		-- (standing on it or just off it - not up on a ledge, not high in the air)
		StompRadius = 7.2, StompFoot = 0.45, StompLow = 1.0, StompHeight = 2.0,
	},
}

---------------------------------------------------------------------------
-- hit detection
---------------------------------------------------------------------------
-- Every striking limb is a capsule following its measured path (CombatPaths) through the attack's
-- active frames; between two frames the tip's swept path is tested too, so a fast snap can't
-- skip a body. A fighter's body is a box in its own space (arms included). One strike hits each
-- fighter at most once. Tuned so the box-and-capsule reach matches the real limb meeting the real
-- body (contact.py) to within ~0.08 studs on every frame: visible connect = hit, visible miss = miss.
Config.Hitbox = {
	-- R6: torso 2 wide and 1 deep (the idle stance turns it 13 deg, a shoulder forward), arms out to
	-- 1.5 each side, head up to 2.1 above the root, feet at -3
	Body = { HalfWidth = 1.5, Bottom = -3.0, Top = 2.1, HalfDepth = 0.58 },
	-- a side whose arm is gone ends at the torso (2 wide, turned 13 deg in the idle stance): nothing
	-- can hit where the arm was, top to bottom
	ArmlessHalfWidth = 1.1,
	-- added to every limb radius
	Pad = 0.1,
	-- the capsule is pulled in at the tip by this share of its radius, so its rounded end sits on
	-- the fist's (foot's) own end face
	Shorten = 0.6,
	-- lag compensation (a player attacker): the victim is tested where the ATTACKER saw it - rewound
	-- by the round trip plus Roblox's replication interpolation
	Rewind = 0.1, -- interpolation delay of replicated bodies
	RewindMax = 0.3, -- never judged against a body older than this...
	RewindReach = 4.0, -- ...or further than this from where the server has it now (high ping stays
	-- playable, but a fighter who has long since dashed away can't be hit where they were)
	-- ...and the attacker is placed where its own screen had it. The server's copy of a player's body
	-- trails the player's screen by the replication delay, so the owning client reports its root as
	-- the strike's active frames begin and midway. The server checks the report against its own copy
	-- and waits a moment for it before judging. A report further from the server's copy than a base
	-- plus what the body's own speed covers in one round trip is pulled back to that limit (never a
	-- free reach extension - and never thrown away for the lagging copy). A Ground Smash touchdown
	-- report may be further above the server's copy (it trails the fast drop)
	ReportDrift = 0.75, ReportDriftMax = 6, ReportDriftLand = 12,
	ReportWait = 0.25, -- max seconds the server waits past the active frames' start for a report
	ReportLead = 0.12, -- max seconds a report is carried forward along its velocity
	LagLead = 0.05, -- no report: the server's copy is led this far along its velocity
	MaxTargets = 1, -- default per strike (see the attacks' own MaxTargets)
	-- THE ATTACKER'S SCREEN, VERIFIED (CombatService.ClaimHit): a player's single-target strike lands
	-- where its own screen saw the limb meet the body, once the server has checked that screen's
	-- claim: its clip times at most ClaimSpan wide and no more than ClaimLead ahead of the strike's
	-- own clock; the attacker within ClaimSlack studs of the path its own body took here, facing
	-- within ClaimTurn degrees of a way it really faced (this copy of it trails its screen: a claim
	-- made mid-lunge is held up to ClaimHold, plus a round trip, for the body here to get there);
	-- the victim within ClaimSlack of the path its body really took (further: it is judged back on
	-- that path); and the same geometry passing, with ClaimPad of float tolerance. Claims = false:
	-- the server's own sweep decides every strike
	Claims = true,
	ClaimSpan = 0.12, ClaimLead = 0.12, ClaimTurn = 100, ClaimSlack = 1.0, ClaimPad = 0.03, ClaimHold = 0.3,
	-- the strike's lane: a body counts as "ahead" for the step-in / the carry when it is within this
	-- far of the facing line (studs) and not far above or below
	Lane = 2.2, LaneHeight = 4.5,
}

-- the attacker's momentum after a clean chain strike: it carries on along its facing with the blow,
-- a share of the victim's slide, but never closer to the body ahead than the next strike's Ideal
-- (the next step-in covers the rest)
-- ChainStep: how much further a string's follow-up may step in than its opener (a guard sliding
-- back under blocked blows and walking away while it blocks is still reached)
Config.Carry = { Min = 0.2, Max = 0.85, ChainStep = 0.8 }

-- the reaction: a new blow cross-fades the reaction from the pose the victim is in (never from
-- neutral). Same side as the last blow: Blend; the other side (the head whips across): SwapBlend.
-- After the clip's peak (SettleAt, clip seconds) its weight eases to Settle over SettleTime - the
-- victim sags back toward its stance while it reels, so the next blow always has room to drive it
Config.React = { Blend = 0.07, SwapBlend = 0.11, SettleAt = 0.26, Settle = 0.55, SettleTime = 0.3 }

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
	BreakHitstop = 0.13, -- the heaviest freeze in the game: the guard shatters
	BreakReactSpeed = 0.56, -- the directional hit reaction, slowed: heavier and readable
	ReblockAfter = 0.35, -- after the break ends, before the guard can go up again
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
	Left = { Anim = "DashLeft", Speed = 1, Distance = 15, Duration = 0.36, FadeAt = 0.44, Lock = 0.38 },
	Right = { Anim = "DashRight", Speed = 1, Distance = 15, Duration = 0.36, FadeAt = 0.44, Lock = 0.38 },
	Ramp = 0.05, -- seconds to reach full speed
	Ease = 1.6, -- deceleration curve over the last 45%
	-- a dash stops this far (root to root) from a fighter in its path, never through them: where a dash
	-- strike out of it lands (its Ideal, less the momentum that still carries it in)
	StopGap = 4.1,
	StopWidth = 2.6, -- how wide the path is
	-- the forward dash out of a landed smash chases its victim: aimed at it when the dash points
	-- within Angle degrees of it, then steered after it as it slides (at most Turn degrees a second),
	-- its kick-off burst Burst times the size and the view widening (Config.Camera.LinkDash)
	LinkAssist = { Angle = 75, Turn = 240, Burst = 1.35 },
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
Config.StunCap = 4.0 -- continuous hitstun from any number of attackers is capped at this...
Config.StunImmunity = 0.9 -- ...then the victim gets this long to act
Config.KillCredit = 10 -- seconds a hit counts toward a kill
-- the knockout blow throws the body: its own Launch (sweep, stomp), else this throw straight back
Config.KOLaunch = { Back = 34, Up = 30, Side = 0, LegsUp = 20, LegsSide = 0, Tip = 2.6, Time = 1.4 }
-- practice dummies: the longest string (smash, dash strike, uppercut, straight, hook = 22) leaves
-- them standing for the sweep, which pops the head (0.5 left: under the head's line)
Config.DummyHealth = 29
Config.SparringHealth = 60 -- the Sparring Dummy: a real fight (both its arms can come off before it drops)
-- a player's regen reserve (CombatService): Reserve health, once per life, healed at Rate a second
-- once Delay seconds have passed since it last took, dealt or blocked a blow (or took any damage).
-- What it heals is gone for good (the Reserve attribute: the bar under the health bar); healing
-- also gives back the wounds it covers, so each arm still comes off at its own line of health
Config.Regen = { Reserve = 100, Rate = 2, Delay = 5 }
Config.RequestRate = 25 -- max combat requests per second per player
Config.StudioDummies = true -- practice dummies (a still one and a guarding one) near the spawn in Studio

---------------------------------------------------------------------------
-- blood (client-side, cosmetic; CombatBlood + BloodPools). Droplets on real arcs, the place's own
-- blood effects (ReplicatedStorage.Combat.VFX - the blood packs copied out of the Workspace), wounds
-- that keep bleeding, and the liquid on the ground and walls it all ends up as.
---------------------------------------------------------------------------
--[[ A PROFILE is a kind of blow's blood. Ranges are { min, max }: every blow rolls its own.
	Ref       the damage this profile is sized for: a harder blow bleeds more, and a fighter that is
	          already badly hurt bleeds more from every blow (CombatBlood.Spray)
	Core      the place's effects, one picked by weight W per blow: Name, W, Scale, Count
	Extra     { Chance, List }: sometimes a second one on top
	Drops     droplets flung out of the wound (Size: their size in studs; Blob: the share that are
	          heavy blobs), Fine: specks of fine spray in a tighter cone
	Spread    degrees round the aim; Eject: studs/s out of the wound
	Carry / Side / Lift   how hard the struck part's own motion throws the blood with it: back along
	          the blow / sideways (a hook) / up (an uppercut)
	Squirt    { Chance, Delay, Drops }: a late thin squirt out of the same wound as the body reels
	Spit      { Chance, Delay, Up }: blood out of the mouth (Up: 1 straight up, 0 straight ahead)
	Trail     the drops the body sheds as it slides back from the blow (x its strength) ]]
local function fx(name: string, w: number, scale: { number }, count: { number }, face: boolean?): any
	return { Name = name, W = w, Scale = scale, Count = count, Face = face }
end
Config.Blood = {
	Enabled = true,
	Color = Color3.fromRGB(150, 8, 14), -- fresh (the droplets)
	Drag = 2.0, -- air drag on an ordinary droplet (1/s); a small one has more, a big one less
	MaxDrops = 96, -- droplets in the air at once (pooled; past it the oldest gives way)
	View = 160, -- nothing is built farther than this from the camera
	TrailRate = 16, -- drops a second a body sheds sliding from a blow (x the profile's Trail, fading out)
	Profiles = {
		-- the straights (Swing1, Swing2): the face and chest, thrown back along the blow
		Light = {
			Ref = 3.5,
			Core = { fx("Blood", 3, { 0.55, 0.8 }, { 0.45, 0.8 }), fx("BloodPunch", 1, { 0.28, 0.4 }, { 1, 1 }, true), fx("BloodSpatter", 1, { 0.4, 0.55 }, { 0.45, 0.75 }) },
			Extra = { Chance = 0.4, List = { fx("BloodSplatter", 2, { 0.25, 0.38 }, { 0.2, 0.4 }), fx("BloodJet", 1, { 0.28, 0.4 }, { 0.3, 0.5 }), fx("BloodWound", 1, { 0.32, 0.45 }, { 0.2, 0.35 }) } },
			Drops = { 2, 5 }, Size = { 0.07, 0.13 }, Blob = 0.1, Fine = { 2, 6 },
			Spread = { 22, 36 }, Eject = { 8, 15 }, Carry = 10, Side = 2.5, Lift = 3,
			Squirt = { Chance = 0.12, Delay = { 0.05, 0.14 }, Drops = { 2, 3 } },
			Trail = 0.25,
		},
		-- the hook (Swing3): the side of the head, flung sideways with the twist
		Hook = {
			Ref = 3.5,
			Core = { fx("Blood", 3, { 0.65, 0.9 }, { 0.6, 0.95 }), fx("BloodSpatter", 1, { 0.5, 0.65 }, { 0.6, 0.9 }), fx("BloodPunch", 1, { 0.32, 0.45 }, { 1, 1 }, true) },
			Extra = { Chance = 0.5, List = { fx("BloodSplatter", 2, { 0.3, 0.45 }, { 0.3, 0.5 }), fx("BloodJet", 2, { 0.32, 0.45 }, { 0.35, 0.55 }), fx("BloodStrand", 1, { 0.5, 0.8 }, { 0.4, 0.7 }) } },
			Drops = { 3, 6 }, Size = { 0.07, 0.14 }, Blob = 0.12, Fine = { 3, 7 },
			Spread = { 24, 38 }, Eject = { 8, 15 }, Carry = 6, Side = 12, Lift = 3,
			Squirt = { Chance = 0.2, Delay = { 0.05, 0.16 }, Drops = { 2, 4 } },
			Trail = 0.3,
		},
		-- the uppercut: the chin - up and back in a heavy spray, blood spat up out of the mouth
		Heavy = {
			Ref = 5.5,
			Core = { fx("BloodHeavy", 3, { 0.85, 1.1 }, { 0.8, 1.05 }), fx("BloodWound", 2, { 0.6, 0.8 }, { 0.6, 0.9 }), fx("BloodSplatterWild", 1, { 0.4, 0.55 }, { 0.45, 0.7 }) },
			Extra = { Chance = 0.65, List = { fx("BloodJet", 2, { 0.4, 0.55 }, { 0.45, 0.7 }), fx("BloodStrand", 2, { 0.7, 1 }, { 0.5, 0.9 }), fx("Blood", 1, { 0.6, 0.85 }, { 0.5, 0.8 }) } },
			Drops = { 5, 9 }, Size = { 0.08, 0.16 }, Blob = 0.2, Fine = { 4, 9 },
			Spread = { 28, 42 }, Eject = { 9, 17 }, Carry = 5, Side = 1.5, Lift = 17,
			Squirt = { Chance = 0.3, Delay = { 0.06, 0.18 }, Drops = { 2, 4 } },
			Spit = { Chance = 0.75, Delay = { 0.02, 0.07 }, Up = 0.85 },
			Trail = 0.35,
		},
		-- the dash strike: the gut - a thick burst thrown back along the lunge, blood coughed out
		Dash = {
			Ref = 4.5,
			Core = { fx("Blood", 2, { 0.65, 0.9 }, { 0.6, 0.9 }), fx("BloodSplatter", 2, { 0.38, 0.52 }, { 0.4, 0.65 }), fx("BloodWound", 1, { 0.5, 0.7 }, { 0.45, 0.7 }) },
			Extra = { Chance = 0.5, List = { fx("BloodGush", 1, { 0.35, 0.5 }, { 0.25, 0.4 }), fx("BloodBleed", 2, { 0.45, 0.65 }, { 0.5, 0.8 }) } },
			Drops = { 3, 6 }, Size = { 0.07, 0.14 }, Blob = 0.15, Fine = { 3, 7 },
			Spread = { 26, 40 }, Eject = { 6, 13 }, Carry = 12, Side = 2, Lift = 2,
			Squirt = { Chance = 0.18, Delay = { 0.08, 0.2 }, Drops = { 2, 3 } },
			Spit = { Chance = 0.8, Delay = { 0.04, 0.1 }, Up = 0.1 },
			Trail = 0.6,
		},
		-- the Ground Smash: the shock bursts blood out low and outward, and the long slide trails it
		Stomp = {
			Ref = 5,
			Core = { fx("BloodSplatter", 2, { 0.45, 0.6 }, { 0.5, 0.8 }), fx("BloodSpatter", 1, { 0.5, 0.7 }, { 0.6, 0.9 }), fx("Blood", 1, { 0.6, 0.85 }, { 0.5, 0.8 }) },
			Extra = { Chance = 0.55, List = { fx("BloodBleed", 2, { 0.5, 0.7 }, { 0.5, 0.8 }), fx("BloodDrip", 1, { 0.6, 0.8 }, { 0.8, 1 }) } },
			Drops = { 4, 7 }, Size = { 0.07, 0.14 }, Blob = 0.15, Fine = { 3, 6 },
			Spread = { 30, 48 }, Eject = { 7, 13 }, Carry = 14, Side = 2, Lift = -2,
			Squirt = { Chance = 0.15, Delay = { 0.1, 0.3 }, Drops = { 2, 3 } },
			Trail = 0.8,
		},
		-- the sweep (the finisher): a heavy burst, wide and wet, and a trail through the whole flight
		Finisher = {
			Ref = 6.5,
			Core = { fx("BloodHeavy", 2, { 1, 1.2 }, { 1, 1.3 }), fx("BloodSplatterWild", 2, { 0.5, 0.65 }, { 0.6, 0.9 }), fx("BloodWound", 1, { 0.8, 1 }, { 0.8, 1.1 }) },
			Extra = { Chance = 0.7, List = { fx("BloodBurst", 1, { 0.35, 0.5 }, { 0.3, 0.45 }), fx("BloodSplatter", 2, { 0.4, 0.55 }, { 0.45, 0.7 }), fx("BloodStrand", 1, { 0.8, 1.1 }, { 0.6, 1 }) } },
			Drops = { 7, 11 }, Size = { 0.08, 0.16 }, Blob = 0.25, Fine = { 6, 10 },
			Spread = { 32, 46 }, Eject = { 9, 17 }, Carry = 12, Side = 3, Lift = 5,
			Squirt = { Chance = 0.4, Delay = { 0.08, 0.2 }, Drops = { 2, 4 } },
			Trail = 0.5,
		},
		-- the knockout blow, on top of the strike's own (CombatFX): the body bursts, and rains as it flies
		KO = {
			Ref = 5,
			Core = { fx("BloodBurst", 1, { 0.45, 0.65 }, { 0.45, 0.7 }) },
			Extra = { Chance = 0.6, List = { fx("BloodWound", 1, { 0.8, 1.05 }, { 0.8, 1.1 }), fx("BloodSplatterWild", 1, { 0.55, 0.7 }, { 0.6, 0.9 }) } },
			Drops = { 6, 10 }, Size = { 0.08, 0.17 }, Blob = 0.3, Fine = { 5, 9 },
			Spread = { 36, 55 }, Eject = { 9, 18 }, Carry = 10, Side = 2, Lift = 6,
			Trail = 0.7,
		},
		-- an arm torn off at the shoulder (CombatGore): out of the socket and after the departing arm
		Tear = {
			Ref = 5,
			Core = { fx("BloodWound", 2, { 1, 1.25 }, { 1, 1.3 }), fx("BloodHeavy", 1, { 1.15, 1.35 }, { 1.2, 1.5 }) },
			Extra = { Chance = 0.85, List = { fx("BloodGush", 2, { 0.7, 0.9 }, { 0.6, 0.85 }), fx("BloodSplatterWild", 1, { 0.6, 0.8 }, { 0.7, 1 }), fx("BloodBurst", 1, { 0.4, 0.55 }, { 0.35, 0.5 }) } },
			Drops = { 9, 13 }, Size = { 0.08, 0.17 }, Blob = 0.3, Fine = { 6, 10 },
			Spread = { 28, 40 }, Eject = { 10, 19 }, Carry = 9, Side = 2, Lift = 6,
		},
		-- the head bursting (CombatGore): the thickest of all
		Head = {
			Ref = 5,
			Core = { fx("BloodBurst", 1, { 1.2, 1.5 }, { 1.1, 1.4 }) },
			Extra = { Chance = 1, List = { fx("BloodWound", 1, { 1.2, 1.5 }, { 1.2, 1.5 }), fx("BloodSplatterWild", 1, { 0.8, 1 }, { 1, 1.3 }) } },
			Drops = { 14, 20 }, Size = { 0.08, 0.18 }, Blob = 0.35, Fine = { 10, 14 },
			Spread = { 45, 70 }, Eject = { 10, 20 }, Carry = 6, Side = 2, Lift = 10,
		},
	},
	-- a wound that keeps bleeding (CombatGore's stumps, the torn limb, the neck - CombatBlood.Wound):
	-- a heartbeat of spurts, BpmHigh while the pressure is full, slowing to BpmLow as it empties; a
	-- dribble of Dribble[1]..[2] drops a second (empty..full), then an ooze of OozeRate a second fading
	-- out. Inherit: the share of the wound's own velocity its blood leaves with. Moving faster than
	-- ShedSpeed the air strips drops off it (ShedRate a second per stud/s over)
	Wound = { BpmHigh = 148, BpmLow = 68, Dribble = { 1.2, 4.5 }, OozeRate = 1.1, Inherit = 0.85, ShedSpeed = 9, ShedRate = 0.35 },
	-- the liquid on the ground and the walls (BloodPools): a grid of Cell studs on every surface blood
	-- reaches; a drop of size s pours Spot * s^3 studs² into it. A full cell runs over into its
	-- neighbours (SpreadRate on the flat; RunRate down slopes and walls, where only WallFilm of a cell is
	-- left behind as the run's trail). Life: seconds a pool lies there (from the last blood poured into
	-- it), the last Fade of them soaking away from its edges in. Budgets: MaxCells pool cells, MaxSpecks
	-- specks of spray, MaxGloss pieces of wet sheen (past MaxCells the oldest pool soaks away early);
	-- Spare: the pieces kept for reuse once all of it has gone. (Low graphics or a phone: the budgets
	-- - and MaxDrops - are cut to a half .. three quarters, CombatBlood)
	Pool = {
		Cell = 0.5,
		Spot = 34,
		SpreadRate = 3.5,
		RunRate = 9,
		WallFilm = 0.12,
		Life = 32,
		Fade = 2.6,
		MaxCells = 400,
		MaxSpecks = 90,
		MaxGloss = 60,
		Spare = 160, -- pieces kept for reuse once every pool has gone
		Fresh = Color3.fromRGB(108, 1, 9),
		Rim = Color3.fromRGB(70, 0, 6), -- the clotting edge
		Gloss = Color3.fromRGB(122, 6, 14), -- the wet sheen (a touch lighter than Fresh)
		Dried = Color3.fromRGB(58, 4, 8),
		RimDried = Color3.fromRGB(32, 2, 4),
	},
}

---------------------------------------------------------------------------
-- gore (CombatGore + CombatService): the damage a fighter has taken, on its body - NPCs and players
-- alike. A fighter's WOUNDS (the share of its health it has lost, added up; no healing takes any
-- back but the regen reserve's: Config.Regen) decide its stage: the right arm once it is down to
-- Stages[1] of its health (30%), the left at Stages[2] (20%); the head POPS at Stages[3] (5%) or
-- under - a clean blow that leaves a fighter there is the killing blow (Config.HeadPopDamage: the
-- rest of its health goes with the head; a blocked blow's chip never pops it). The server keeps the stage and the wounds on the character
-- (GoreStage, Wounds attributes). Losing arms matters:
--   one arm    every blow hurts more (OneArm.DamageTaken), and a block stops much less of it
--              (OneArm.GuardChip times the chip damage). It fights with the hand it has left and
--              never combos: M1 is the left straight (OneArm.Light), M2 the left uppercut
--              (OneArm.Heavy), each a strike of its own. The next one waits until the last one's
--              victim has had OneArm.Breathe of control back (so no two ever make a true combo, and
--              each one stuns: never under Combo.ResetGrace - see Rules.SingleGap); no dash
--              strike (that is the right hand's). The Ground Smash (the legs) stays
--   no arms    no guard at all (a block can't go up; one already up drops), blows hurt more still,
--              and no attack of any kind (not even the Ground Smash): it moves and dashes, nothing
--              else - faster (NoArms.MoveSpeed) and its dash back sooner (NoArms.DashCooldown), to
--              get away
--   (a body missing an arm is that much narrower to hit on that side, shoulder to hip:
--   Config.Hitbox.ArmlessHalfWidth)
--   A lost limb is gone for good: nothing grows back until the fighter respawns.
--   Players     false: only NPCs come apart
--   Stages      health shares at which each stage plays, in order: the right arm torn off, the
--               left arm, the head burst (at or under the last one a clean blow kills)
--   GibRest     seconds a severed arm lies on the ground (once it has come to rest) before it
--               sinks and fades; GibLife the cap for one that never settles
--   BleedTime   seconds a torn limb keeps pumping blood (slowing with every beat - Config.Blood.Wound);
--               DripTime the oozing after it
--   Stagger     seconds between stages when one blow earns several
---------------------------------------------------------------------------
Config.Gore = {
	Enabled = true,
	Players = true,
	Stages = { 0.30, 0.20, 0.05 },
	OneArm = { DamageTaken = 1.15, GuardChip = 2, Light = "Swing2", Heavy = "Uppercut", Breathe = 0.45 },
	-- (with nothing to fight with, it can at least get away)
	NoArms = { DamageTaken = 1.25, MoveSpeed = 1.15, DashCooldown = 0.7 },
	-- what's torn off is a real body on this client: it flies, tumbles, lands with a wet thud (the
	-- first touchdown splashes), rolls to a stop, then LIES THERE GibRest seconds before it sinks into
	-- the ground and fades (GibSink). GibLife caps a piece that never settles (a slope, a moving floor);
	-- past MaxGibs the oldest sinks early (never a pile that costs frames)
	GibLife = 18,
	GibRest = 8,
	GibSink = 1.6,
	MaxGibs = 8,
	-- the flesh of a torn-off limb: heavy, grippy, dead (no rubber bounce, it thuds and rolls)
	Flesh = { Density = 1.1, Friction = 0.9, Elasticity = 0.04 },
	BleedTime = 8,
	DripTime = 25, -- ...then the wound keeps oozing a drop a beat this long (or until it heals)
	-- a body that has lost more than DripFrom of its health drips blood as it moves (CombatGore), up to
	-- DripRate drops a second at the very end
	DripFrom = 0.45,
	DripRate = 2.4,
	Stagger = 0.14,
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

-- the average speed of a Motion.Push decay profile over its time, as a share of the start speed
Config.PushShare = 1.4 / 2 - 0.4 / 3 -- (0.5667: Motion.PushCurve is scaled to average exactly this)

for name, a in pairs(Config.Attacks) do
	a.Id = name
	a.HitReal = a.Hit / a.Speed -- seconds from start to impact
	a.ChainReal = a.ChainAt / a.Speed
	a.LengthReal = a.Length / a.Speed
	-- (a smash: its recovery, touchdown to control - the clip slowed from TailAt on)
	if a.StompAt then
		local tail = a.TailAt or a.Length
		a.RecoverReal = (tail - a.StompAt) / a.Speed + (a.Length - tail) / (a.Speed * (a.TailSpeed or 1))
	end
	a.ClassDef = Config.Classes[a.Class]
	a.Rank = if a.Class == "Light" then 1 elseif a.Class == "Heavy" then 3 elseif a.Class == "Dash" then 4 else 5
	-- how far a clean hit slides the victim (studs)
	a.PushDistance = (a.Knock.Back or 0) * (a.KnockTime or 0) * Config.PushShare
end

-- the gore stage this much health has earned (0 whole .. #Stages the head; the last only at 0)
function Config.GoreStageFor(health: number, max: number): number
	if max <= 0 then
		return 0
	end
	local stages = Config.Gore.Stages
	local f = health / max
	local n = 0
	for i, st in ipairs(stages) do
		if (i == #stages and health <= 0) or (i < #stages and f <= st) then
			n = i
		end
	end
	return n
end

-- the stage a fighter's wounds earn while it lives (0: whole, 1: no right arm, 2: no arms; the head
-- only goes with the killing blow - see Config.HeadPopDamage)
function Config.GoreStageForWounds(wounds: number): number
	local stages = Config.Gore.Stages
	local n = 0
	for i = 1, math.min(2, #stages - 1) do
		if wounds >= 1 - stages[i] - 1e-9 then
			n = i
		end
	end
	return n
end

-- a blow of `dmg` on a fighter with `health` of `max`: a clean one that leaves it at the head's line
-- (Gore.Stages' last share) or under pops the head - the killing blow, the rest of its health going
-- with it. A blocked blow's chip never does. The server deals it; the attacker's screen predicts it
function Config.HeadPopDamage(dmg: number, health: number, max: number, blocked: boolean?): number
	local G = Config.Gore
	if not G.Enabled or blocked or health <= 0 or max <= 0 then
		return dmg
	end
	local line = (G.Stages[#G.Stages] or 0) * max
	if health - dmg <= line + 1e-6 then
		return math.max(dmg, health)
	end
	return dmg
end

-- arms a fighter still has at a gore stage (the right goes first, then the left)
function Config.ArmsAt(stage: number?): number
	return math.max(0, 2 - math.min(stage or 0, 2))
end

-- a strike thrown with `limbs` (CombatPaths) can only land while one of them is still attached (the
-- right arm is gone from stage 1, the left from stage 2): a punch with a lost fist whiffs
function Config.CanStrike(stage: number?, limbs: { string }?): boolean
	if not Config.Gore.Enabled or not limbs then
		return true
	end
	local s = stage or 0
	for _, l in ipairs(limbs) do
		if not ((l == "Right Arm" and s >= 1) or (l == "Left Arm" and s >= 2)) then
			return true
		end
	end
	return false
end

-- may a fighter at gore stage `stage` use this move (an attack name from Config.Attacks)? With one arm
-- only that hand's single strikes and the Ground Smash; with none, nothing
function Config.CanUse(stage: number?, move: string): boolean
	local G = Config.Gore
	if not G.Enabled then
		return true
	end
	local arms = Config.ArmsAt(stage)
	if arms >= 2 then
		return true
	elseif arms == 0 then
		return false
	end
	return move == "Downslam" or move == G.OneArm.Light or move == G.OneArm.Heavy
end

-- how fast a fighter at gore stage `stage` moves, and how soon its dash is back (shares of normal)
function Config.MoveScale(stage: number?): number
	return if Config.Gore.Enabled and Config.ArmsAt(stage) == 0 then Config.Gore.NoArms.MoveSpeed else 1
end
function Config.DashCooldownFor(stage: number?): number
	local k = if Config.Gore.Enabled and Config.ArmsAt(stage) == 0 then Config.Gore.NoArms.DashCooldown else 1
	return Config.Dash.Cooldown * k
end

-- the damage a blow of `base` does to a fighter at gore stage `stage` (blocked: `base` is already the
-- chip that gets through a guard). The server deals it; the attacker's screen predicts it the same way
function Config.GoreDamage(base: number, stage: number?, blocked: boolean?): number
	local G = Config.Gore
	if not G.Enabled then
		return base
	end
	local arms = Config.ArmsAt(stage)
	if arms == 2 then
		return base
	elseif arms == 1 then
		return base * G.OneArm.DamageTaken * (if blocked then G.OneArm.GuardChip else 1)
	end
	return base * G.NoArms.DamageTaken
end

-- how `to` enters after `from` (nil = from locomotion / outside a chain): (cross-fade, entry clip time)
function Config.Transition(from: string?, to: string): (number, number)
	local pair = from and Config.Transitions[from] and Config.Transitions[from][to]
	if pair then
		return pair.Blend, pair.Enter
	end
	return Config.EntryBlend[to] or 0.08, 0
end

return Config
