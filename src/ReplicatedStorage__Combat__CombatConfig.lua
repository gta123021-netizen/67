--[[
	CombatConfig  (ReplicatedStorage.Combat.CombatConfig)
	Every tunable of the melee combat + movement layer, in one place. The server and every client
	read the same numbers, so the server's hit timing and the client's animation timing agree.

	THE ANIMATIONS DRIVE THE NUMBERS. Everything marked (pack) was measured from the Battleground
	Combat Animations Pack's own keyframes with R6 forward kinematics (tools/anim.py, contact.py,
	choreo_analyze.py):
	  Hit        the clip's "Hit" KeyframeMarker - the frame the striking limb lands
	  Reach      the root-to-root distance at which the striking limb's part touches a standing
	             body on the Hit frame (exact box geometry of both rigs)
	  Ideal      where the strike is meant to land: Reach less a short sink, so the fist visibly
	             drives into the body on its impact frame (never an air punch, never a clip-through)
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
		Hitstop = 0.11, BlockHitstop = 0.07, Camera = "Stomp", VictimCamera = "HeavyTaken",
		BlockPush = 0, BlockPushTime = 0, BlockTilt = { Roll = 8, Yaw = 10, Pitch = 16 }, BlockStun = 0,
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
	Stomp = { Kick = 0.38, Up = -0.8, Roll = 0.6, Fov = 3.2, Time = 0.26, Rumble = { 0.06, 0.55 } },
	LightTaken = { Kick = 0.16, Up = 0.05, Roll = 1.2, Fov = 0, Time = 0.16 },
	HeavyTaken = { Kick = 0.3, Up = 0.2, Roll = 1.8, Fov = 1.5, Time = 0.24 },
	Block = { Kick = 0.06, Up = 0, Roll = 0.3, Fov = 0, Time = 0.12 },
	GuardBreak = { Kick = 0.3, Up = 0.1, Roll = 1.4, Fov = 2.5, Time = 0.26 },
	StompNear = { Kick = 0.22, Up = -0.6, Roll = 0.5, Fov = 1.2, Time = 0.24, Rumble = { 0.04, 0.45 } },
}

---------------------------------------------------------------------------
-- combo: M1 = light, M2 = heavy (once per combo), the sweeping kick finishes
---------------------------------------------------------------------------
--   M1 M1 M1 M1          -> Swing1 Swing2 Swing3 Sweep                (4 hits)
--   an M2 anywhere in the first four inserts the Uppercut and the chain grows to 5:
--   M2 M1 M1 M1 M1       -> Uppercut Swing1 Swing2 Swing3 Sweep
--   M1 M2 M1 M1 M1       -> Swing1 Uppercut Swing2 Swing3 Sweep       (and so on)
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
-- legitimate string (the uppercut chain into the sweep, hit-stops included, ~2.3 s of stun)
-- always fits in a full budget.
---------------------------------------------------------------------------
Config.StunBudget = {
	Max = 3.0,
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
	Reach, ReachMax, Ideal  (pack) Reach: root-to-root distance the limb touches a standing body on the
	                        Hit frame; ReachMax: the farthest it touches one on any active frame.
	                        Ideal: where the strike lands (Reach less the sink)
	Step                    the step-in: straight along the facing during clip times From..To, up to
	                        Max studs - it stops where the body ahead (if any, in the strike's lane)
	                        is at Ideal on the Hit frame, and is a short Base step when nobody is there.
	                        It never turns and never steers: it is the body's weight going into the blow
	Impact                  the effect tier (CombatFX): Light, Hook, Heavy, Sweep, Dash, Stomp
	Blood                   the blood tier (CombatBlood): Light, Hook, Heavy, Finisher, Body
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
		Reach = 3.84, Ideal = 3.45, ReachMax = 4.36,
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
		Reach = 3.7, Ideal = 3.35, ReachMax = 4.31,
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
		Reach = 3.45, Ideal = 3.1, ReachMax = 3.77,
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
		Knock = { Back = 13, Up = 24 }, KnockTime = 0.22,
		Contact = Vector3.new(0.34, 1.71, -2.68), ReactPush = 1, React = 0.72,
		Reel = { Pitch = 20, Yaw = 0, Roll = 0, NeckYaw = 0, NeckPitch = 34, Omega = 11 },
		Reach = 3.73, Ideal = 3.3, ReachMax = 3.73,
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
		Reach = 4.06, Ideal = 3.6, ReachMax = 4.06,
		Step = { From = 0.4, To = 0.88, Base = 0.8, Max = 2.4 },
		Impact = "Sweep", Blood = "Finisher",
		-- (the whole shin sweeps through: the capsule runs to the foot's end, not short of it)
		Hitbox = 0.55, Shorten = 0, Name = "Sweep", MaxTargets = 1,
		FollowGround = true, -- on a slope or a step the sweep reaches the victim's shins (HitDetect)
	},

	-- forward dash + M1: the lunge punch low into the body, carrying the dash's momentum. The arm is
	-- already out at full reach when it lands, so the momentum stops Ideal short of a body
	DashAttack = {
		Anim = "DashAttack", Class = "Dash", Speed = 1, Hit = 0.05, ChainAt = 0.25, Length = 0.25, Hold = 0.2,
		Damage = 5.5, Stun = 0.85,
		Knock = { Back = 80, Up = 16 }, KnockTime = 0.24,
		Contact = Vector3.new(0.59, -0.67, -4.17), ReactPush = 0, React = 0.8,
		-- a blow to the gut: the body folds FORWARD over it, the head drops
		Reel = { Pitch = -16, Yaw = 4, Roll = 0, NeckYaw = 6, NeckPitch = -20, Omega = 12 },
		Reach = 5.07, Ideal = 4.6, ReachMax = 5.25,
		Impact = "Dash", Blood = "Body",
		Hitbox = 0.5, Name = "Dash Strike", MaxTargets = 1,
		Cooldown = 0.35,
	},

	-- jump + M1: GROUND SMASH. A standalone move, never part of a combo: it can't start while a chain
	-- is live (starting it ends any chain), it needs a real jump the server sees, and it lands only
	-- when the body is on the ground. It hits everyone on the shattered ground (an area move), but it
	-- never knocks down or re-stuns a fighter who is still reeling from a combo (stunned / guard
	-- broken): it can't extend or reset one. (pack: the raised left foot drives down)
	Downslam = {
		Anim = "Downslam", Class = "Stomp", Speed = 1, Hit = 0.3833, ChainAt = 0.5833, Length = 0.5833,
		Damage = 7, Stun = 0, GuardBreak = true, GuardBreakDamage = 3.5,
		Knock = { Back = 38, Up = 0 }, KnockTime = 0.3, -- (guard break slide, straight out from the foot)
		Launch = { Back = 32, Up = 26, Side = 0, LegsUp = 12, LegsSide = 0, Tip = 2.4, Time = 1.25 },
		Contact = Vector3.new(-0.5, -2.9, -1.1), ReactPush = 0, React = 1,
		-- (the ground-shock give when it can't take them down: the knees buckle, the head drops)
		Reel = { Pitch = -9, Yaw = 0, Roll = 4, NeckYaw = 0, NeckPitch = -14, Omega = 10 },
		Reach = 2.5, Ideal = 2.5,
		Impact = "Stomp", Blood = "Body",
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
	-- a side whose arm is gone ends at the torso (2 wide, turned 13 deg in the idle stance)
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
	-- the strike's lane: a body counts as "ahead" for the step-in / the carry when it is within this
	-- far of the facing line (studs) and not far above or below
	Lane = 2.2, LaneHeight = 4.5,
}

-- the attacker's momentum after a clean chain strike: it carries on along its facing with the blow,
-- a share of the victim's slide, but never closer to the body ahead than the next strike's Ideal
-- (the next step-in covers the rest)
Config.Carry = { Min = 0.2, Max = 0.85 }

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
	-- a dash stops this far (root to root) from a fighter in its path, never through them: where a dash
	-- strike out of it lands (its Ideal, less the momentum that still carries it in)
	StopGap = 4.1,
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
Config.KillCredit = 10 -- seconds a hit counts toward a kill
-- the knockout blow throws the body: its own Launch (sweep, stomp), else this throw straight back
Config.KOLaunch = { Back = 34, Up = 30, Side = 0, LegsUp = 20, LegsSide = 0, Tip = 2.6, Time = 1.4 }
-- practice dummies: this much health, so one full string knocks them out on its finisher (a light
-- string deals 3.5 x3 + the sweep's 6.5 = 17; with the uppercut in it 16 before the sweep)
Config.DummyHealth = 16.5
Config.RequestRate = 25 -- max combat requests per second per player
Config.StudioDummies = true -- practice dummies (a still one and a guarding one) near the spawn in Studio

---------------------------------------------------------------------------
-- blood (client-side, cosmetic; CombatBlood). A clean blow bursts the place's own blood effects
-- (ReplicatedStorage.Combat.VFX: Blood and BloodHeavy, from the Yona blood pack) out of the struck
-- surface: aimed outward from the wound - never back into the body - and carried the way the
-- struck part is thrown: back with a straight, sideways with a hook, up with an uppercut. Every
-- particle that moves fades before it could reach a floor, a wall or a ceiling: nothing lands,
-- nothing is left behind.
--   Effects              the VFX effects a blow of this tier bursts: Name, Scale (size and speed),
--                        Count (emit-count multiplier)
--   Eject { min, max }   speed the blood leaves the wound at (studs/s)
--   Crown { min, max }   angle from the wound's outward normal it leaves at (degrees)
--   Carry / Side / Lift  the struck part's velocity after the blow (studs/s): along the blow, to the
--                        side the head was driven, up
-- (The NPC gore's bleeding also throws droplets - small wet parts on exact ballistic paths under
-- the world's gravity (workspace.Gravity) with air Drag - that are gone where they land.)
---------------------------------------------------------------------------
Config.Blood = {
	Enabled = true,
	Color = Color3.fromRGB(96, 4, 6), -- fresh
	Gravity = nil, -- nil: the world's own (workspace.Gravity)
	Drag = 2.0, -- air drag on the droplets (1/s): terminal speed = gravity / drag
	Tiers = {
		Light = { Effects = { { Name = "Blood", Scale = 0.8, Count = 0.75 } }, Eject = { 8, 15 }, Crown = { 40, 80 }, Carry = 10, Side = 2.5, Lift = 3 },
		Hook = { Effects = { { Name = "Blood", Scale = 0.9, Count = 0.9 } }, Eject = { 8, 15 }, Crown = { 40, 80 }, Carry = 6, Side = 12, Lift = 3 },
		Heavy = { Effects = { { Name = "BloodHeavy", Scale = 1, Count = 1 } }, Eject = { 9, 17 }, Crown = { 35, 75 }, Carry = 5, Side = 1.5, Lift = 17 },
		Finisher = { Effects = { { Name = "BloodHeavy", Scale = 1.15, Count = 1.25 }, { Name = "Blood", Scale = 1, Count = 1 } }, Eject = { 9, 17 }, Crown = { 40, 80 }, Carry = 12, Side = 3, Lift = 5 },
		Body = { Effects = { { Name = "Blood", Scale = 0.85, Count = 0.8 } }, Eject = { 6, 13 }, Crown = { 45, 82 }, Carry = 12, Side = 2, Lift = 2 },
	},
	View = 160, -- nothing is built farther than this from the camera
}

---------------------------------------------------------------------------
-- gore (CombatGore + CombatService): the damage a fighter has taken, on its body - NPCs and players
-- alike. A fighter's WOUNDS (the share of its health it has lost, added up; healing never takes any
-- back) decide its stage: the right arm at Stages[1]'s share lost, the left at Stages[2]'s, the
-- head on the killing blow. The server keeps the stage and the wounds on the character (GoreStage,
-- Wounds attributes). Losing arms matters:
--   one arm    every blow hurts more (OneArm.DamageTaken), and a block stops much less of it
--              (OneArm.GuardChip times the chip damage). It fights with the hand it has left and
--              never combos: M1 is the left straight (OneArm.Light), M2 the left uppercut
--              (OneArm.Heavy), each a strike of its own. The next one waits until the last one's
--              victim has had OneArm.Breathe of control back (so no two ever make a true combo); no
--              dash strike (that is the right hand's). The Ground Smash (the legs) stays
--   no arms    no guard at all (a block can't go up; one already up drops), blows hurt more still,
--              no strikes: it moves, dashes and Ground Smashes, nothing else
--   (a body missing an arm is that much narrower to hit on that side: Config.Hitbox.ArmlessHalfWidth)
--   Regrow      a PLAYER's lost arms grow back, one at a time, Regrow.Time seconds each (the last one
--               lost first), counted from when its last arm went or came back - never an NPC's,
--               never the head. A regrown arm takes the same share of damage again to lose
--   Players     false: only NPCs come apart
--   Stages      health shares at which each stage plays, in order: the right arm torn off, the
--               left arm, the head burst (the last one on the killing blow only)
--   GibLife     seconds a severed arm / chunk lies on the ground before it fades away
--   BleedTime   seconds a stump keeps pumping blood (slowing with every beat)
--   Stagger     seconds between stages when one blow earns several
--   BurstDrops  droplets the burst head throws (they land and splat)
--   BurstChunks chunks of flesh and skull the burst head throws
---------------------------------------------------------------------------
Config.Gore = {
	Enabled = true,
	Players = true,
	Stages = { 0.75, 0.5, 0 },
	OneArm = { DamageTaken = 1.15, GuardChip = 2, Light = "Swing2", Heavy = "Uppercut", Breathe = 0.2 },
	NoArms = { DamageTaken = 1.25 },
	Regrow = { Players = true, Time = 10 },
	GibLife = 10,
	BleedTime = 4,
	Stagger = 0.14,
	BurstDrops = 40,
	BurstChunks = 12,
}

---------------------------------------------------------------------------
-- sounds
---------------------------------------------------------------------------
-- Every combat sound is a small stack of LAYERS played together (CombatFX.Sound): a recorded hit
-- from the place's SFX kit (Combat punches, kicks, clashes; earth and debris for the smash) over a
-- body thud built from Roblox's own client sounds, each shaped with pitch, a short envelope and EQ:
--   Id        the source
--   Volume    layer level (the SFX slider scales everything)
--   Speed     playback speed = pitch (0.5 = an octave down: bigger and heavier)
--   Var       random pitch spread per play (+- share), so no two hits sound alike
--   Start     where in the source to start (seconds): skips a slow attack
--   Len/Fade  cut the layer after Len seconds, fading out over Fade (a tight transient)
--   Eq        { Low, Mid, High } gain in dB (EqualizerSoundEffect): Low = weight, High = snap
--   Drive     a touch of distortion (0..1): crunch on the heavy layers
--   Delay     seconds after the others (a sub-bass tail, rubble after a smash)
--   Reach     how far it carries (studs, default 100); heavy impacts carry further
-- To use your own library sounds, swap an Id: every other setting still applies.
local AIR = "rbxasset://sounds/action_falling.mp3"
local THUD = "rbxasset://sounds/action_jump_land.mp3"
local STEP = "rbxasset://sounds/action_footsteps_plastic.mp3"
local CLOTH = "rbxasset://sounds/action_get_up.mp3"
local SHATTER = "rbxasset://sounds/glassbreak.wav"
-- the SFX kit (ServerStorage.VFXLibrary ... SFX): recorded combat foley
local HIT_WEAK = id(260430060)
local HIT_MEDIUM = id(260430079)
local HIT_STRONG = id(332918363)
local HIT_STRONG2 = id(247264335)
local PUNCH = id(281156569)
local KICK_STRONG = id(174399344)
local KICK_MEDIUM = id(174401329)
local SWING_BOXING = id(207588465)
local SWING = id(559673920)
local CLASH_BOXING = id(449579153)
local CLASH_PUNCH = id(743886825)
local CRACK = id(691183830)
local DODGE = id(347194163)
local EARTH_EXPLOSION = id(134854740)
local DEBRIS = id(321321137)
local DEBRIS_SMALL = id(321322066)
local BREAK = id(616086507)
Config.Sounds = {
	-- the air a strike cuts (on the snap of the limb, never at the start of the wind-up)
	Swing = { -- light whoosh: a thin, fast rip of air
		{ Id = SWING_BOXING, Volume = 0.45, Speed = 1.15, Var = 0.07, Len = 0.2, Fade = 0.08, Eq = { -14, 0, 2 } },
		{ Id = AIR, Volume = 0.35, Speed = 2.6, Var = 0.08, Start = 0.35, Len = 0.09, Fade = 0.07, Eq = { -24, -2, 4 } },
	},
	HookSwing = { -- the hook: a wider arc of air and the body turning behind it
		{ Id = SWING_BOXING, Volume = 0.5, Speed = 0.95, Var = 0.06, Len = 0.24, Fade = 0.1, Eq = { -10, 1, 1 } },
		{ Id = CLOTH, Volume = 0.22, Speed = 1.7, Var = 0.05, Len = 0.1, Fade = 0.05, Eq = { -10, 0, -6 } },
	},
	HeavySwing = { -- heavy whoosh: lower and longer
		{ Id = SWING, Volume = 0.45, Speed = 0.9, Var = 0.05, Len = 0.3, Fade = 0.12, Eq = { -8, 2, 0 } },
		{ Id = AIR, Volume = 0.5, Speed = 1.75, Var = 0.06, Start = 0.3, Len = 0.16, Fade = 0.1, Eq = { -14, 2, 1 } },
		{ Id = CLOTH, Volume = 0.25, Speed = 1.6, Var = 0.05, Len = 0.12, Fade = 0.06, Eq = { -10, 0, -6 } },
	},
	SweepSwing = { -- the spinning sweep: a low, long sweep of air along the ground
		{ Id = SWING, Volume = 0.5, Speed = 0.75, Var = 0.05, Len = 0.36, Fade = 0.14, Eq = { -4, 1, -3 } },
		{ Id = CLOTH, Volume = 0.28, Speed = 1.3, Var = 0.05, Len = 0.14, Fade = 0.07, Eq = { -8, 0, -6 } },
	},
	-- impacts: the recorded hit over a body thud
	Hit = { -- light impact (the straights)
		{ Id = HIT_WEAK, Volume = 0.8, Speed = 1.0, Var = 0.06, Len = 0.22, Fade = 0.08 },
		{ Id = THUD, Volume = 0.9, Speed = 1.45, Var = 0.07, Len = 0.12, Fade = 0.06, Eq = { 4, 0, -8 } },
		{ Id = THUD, Volume = 0.55, Speed = 2.9, Var = 0.08, Len = 0.05, Fade = 0.04, Eq = { -30, -4, 6 } },
	},
	Hook = { -- the hook: a flatter, wider slap
		{ Id = HIT_MEDIUM, Volume = 0.85, Speed = 0.97, Var = 0.06, Len = 0.26, Fade = 0.1 },
		{ Id = THUD, Volume = 1.0, Speed = 1.3, Var = 0.07, Len = 0.13, Fade = 0.07, Eq = { 5, 1, -8 } },
		{ Id = CLOTH, Volume = 0.3, Speed = 1.9, Var = 0.06, Len = 0.08, Fade = 0.05, Eq = { -12, 0, -4 } },
	},
	HeavyHit = { -- heavy impact
		{ Id = HIT_STRONG, Volume = 0.9, Speed = 0.95, Var = 0.05, Len = 0.35, Fade = 0.14, Reach = 130 },
		{ Id = THUD, Volume = 1.3, Speed = 1.0, Var = 0.05, Len = 0.2, Fade = 0.1, Eq = { 8, 0, -9 }, Drive = 0.15, Reach = 130 },
	},
	Uppercut = { -- rising and crunchy: the crack, the thud and a short tail of air
		{ Id = HIT_STRONG, Volume = 0.95, Speed = 1.02, Var = 0.05, Len = 0.34, Fade = 0.14, Reach = 130 },
		{ Id = PUNCH, Volume = 0.55, Speed = 0.9, Var = 0.05, Len = 0.2, Fade = 0.08 },
		{ Id = THUD, Volume = 1.3, Speed = 1.1, Var = 0.05, Len = 0.18, Fade = 0.1, Eq = { 7, 1, -8 }, Drive = 0.2, Reach = 130 },
		{ Id = AIR, Volume = 0.3, Speed = 2.2, Var = 0.06, Start = 0.4, Len = 0.14, Fade = 0.1, Eq = { -20, 0, 2 }, Delay = 0.02 },
	},
	Sweep = { -- the low sweep connecting: a heavy kick as the legs go
		{ Id = KICK_STRONG, Volume = 0.95, Speed = 0.95, Var = 0.05, Len = 0.34, Fade = 0.14, Reach = 140 },
		{ Id = THUD, Volume = 1.4, Speed = 0.95, Var = 0.05, Len = 0.22, Fade = 0.12, Eq = { 8, 0, -9 }, Drive = 0.2, Reach = 140 },
	},
	DashHit = { -- the dash strike: momentum driven into the body
		{ Id = HIT_STRONG2, Volume = 0.95, Speed = 0.95, Var = 0.05, Len = 0.34, Fade = 0.14, Reach = 140 },
		{ Id = THUD, Volume = 1.4, Speed = 0.92, Var = 0.05, Len = 0.22, Fade = 0.12, Eq = { 9, 0, -8 }, Drive = 0.22, Reach = 140 },
		{ Id = AIR, Volume = 0.35, Speed = 1.6, Var = 0.05, Start = 0.35, Len = 0.18, Fade = 0.12, Eq = { -16, 0, 0 }, Delay = 0.015 },
	},
	-- guard
	Block = { -- a dull, padded smack on the forearms
		{ Id = CLASH_BOXING, Volume = 0.6, Speed = 1.05, Var = 0.06, Len = 0.2, Fade = 0.08, Eq = { 0, 0, -6 } },
		{ Id = THUD, Volume = 0.8, Speed = 1.6, Var = 0.06, Len = 0.09, Fade = 0.05, Eq = { 0, -2, -14 } },
	},
	HeavyBlock = {
		{ Id = CLASH_PUNCH, Volume = 0.7, Speed = 0.92, Var = 0.05, Len = 0.26, Fade = 0.1, Eq = { 2, 0, -6 } },
		{ Id = THUD, Volume = 1.1, Speed = 1.2, Var = 0.05, Len = 0.14, Fade = 0.07, Eq = { 4, -2, -14 } },
	},
	GuardBreak = { -- the guard caving in: a deep crack, a brittle snap, a shock tail
		{ Id = CRACK, Volume = 0.9, Speed = 0.85, Var = 0.04, Len = 0.45, Fade = 0.2, Reach = 140 },
		{ Id = THUD, Volume = 1.6, Speed = 0.8, Var = 0.04, Len = 0.3, Fade = 0.15, Eq = { 9, 0, -8 }, Drive = 0.3, Reach = 140 },
		{ Id = SHATTER, Volume = 0.35, Speed = 0.72, Var = 0.05, Len = 0.35, Fade = 0.2, Eq = { -6, 0, -4 } },
	},
	-- movement
	Dash = { -- a burst of wind over a hard push-off step
		{ Id = DODGE, Volume = 0.6, Speed = 1.0, Var = 0.05, Len = 0.35, Fade = 0.14 },
		{ Id = AIR, Volume = 0.55, Speed = 1.55, Var = 0.06, Start = 0.2, Len = 0.26, Fade = 0.16, Eq = { -12, 1, 0 } },
		{ Id = STEP, Volume = 0.5, Speed = 1.35, Var = 0.06, Len = 0.1, Fade = 0.05, Eq = { 0, 0, -3 } },
	},
	Step = { -- a fast step (the dash strike's plant)
		{ Id = STEP, Volume = 0.55, Speed = 1.25, Var = 0.07, Len = 0.09, Fade = 0.05 },
	},
	Land = { -- feet back on the ground (the stomp's own landing sits under the smash)
		{ Id = THUD, Volume = 0.9, Speed = 1.05, Var = 0.05, Len = 0.2, Fade = 0.1, Eq = { 2, 0, -6 } },
	},
	Knockdown = { -- a body hitting the floor
		{ Id = KICK_MEDIUM, Volume = 0.55, Speed = 0.7, Var = 0.05, Len = 0.3, Fade = 0.14 },
		{ Id = THUD, Volume = 1.4, Speed = 0.72, Var = 0.05, Len = 0.35, Fade = 0.2, Eq = { 7, 0, -10 }, Reach = 120 },
		{ Id = CLOTH, Volume = 0.45, Speed = 1.1, Var = 0.05, Len = 0.2, Fade = 0.1, Eq = { -6, 0, -6 }, Delay = 0.05 },
	},
	-- GROUND SMASH, in its own phases: the wind of the drop, the touchdown boom and its sub-bass,
	-- the ground cracking, then the rubble raining down and settling
	SlamDescent = {
		{ Id = AIR, Volume = 0.6, Speed = 1.2, Var = 0.04, Start = 0.1, Len = 0.4, Fade = 0.1, Eq = { -10, 2, 2 } },
	},
	Slam = {
		{ Id = EARTH_EXPLOSION, Volume = 0.95, Speed = 0.95, Var = 0.04, Len = 0.9, Fade = 0.4, Reach = 200 },
		{ Id = THUD, Volume = 2.0, Speed = 0.55, Var = 0.03, Len = 0.55, Fade = 0.35, Eq = { 10, 0, -8 }, Drive = 0.35, Reach = 180 },
		{ Id = THUD, Volume = 1.0, Speed = 1.9, Var = 0.05, Len = 0.07, Fade = 0.05, Eq = { -18, 2, 6 }, Reach = 150 },
	},
	SlamSub = {
		{ Id = THUD, Volume = 2.0, Speed = 0.32, Var = 0.02, Len = 0.8, Fade = 0.55, Eq = { 10, -8, -30 }, Reach = 200, Delay = 0.01 },
	},
	SlamCrack = {
		{ Id = BREAK, Volume = 0.7, Speed = 1.0, Var = 0.05, Len = 0.8, Fade = 0.35, Reach = 170, Delay = 0.03 },
		{ Id = CRACK, Volume = 0.55, Speed = 0.7, Var = 0.05, Len = 0.4, Fade = 0.2, Reach = 150, Delay = 0.05 },
	},
	SlamDebris = {
		{ Id = DEBRIS, Volume = 0.7, Speed = 1.0, Var = 0.06, Len = 1.2, Fade = 0.5, Reach = 160, Delay = 0.1 },
		{ Id = DEBRIS_SMALL, Volume = 0.55, Speed = 0.95, Var = 0.08, Len = 1.0, Fade = 0.5, Reach = 140, Delay = 0.45 },
		{ Id = SHATTER, Volume = 0.35, Speed = 0.42, Var = 0.06, Len = 0.9, Fade = 0.5, Eq = { 2, 0, -12 }, Delay = 0.06, Reach = 150 },
	},
	SlamSettle = { -- slabs grinding back down into the ground
		{ Id = DEBRIS_SMALL, Volume = 0.35, Speed = 0.7, Var = 0.06, Len = 0.8, Fade = 0.4, Reach = 110 },
	},
	-- gore: flesh tearing, a head bursting
	GoreTear = { -- an arm torn off: the crack of the joint, a wet rip, cloth tearing
		{ Id = CRACK, Volume = 0.8, Speed = 1.25, Var = 0.06, Len = 0.3, Fade = 0.12, Reach = 110 },
		{ Id = HIT_STRONG, Volume = 0.9, Speed = 0.8, Var = 0.06, Len = 0.35, Fade = 0.15, Eq = { 4, 0, -4 }, Reach = 110 },
		{ Id = CLOTH, Volume = 0.45, Speed = 1.4, Var = 0.08, Len = 0.2, Fade = 0.08, Eq = { -8, 0, -2 }, Delay = 0.02 },
	},
	GoreRegrow = { -- a lost arm growing back: flesh knitting, then the joint setting into place
		{ Id = CLOTH, Volume = 0.55, Speed = 0.75, Var = 0.06, Len = 0.4, Fade = 0.18, Eq = { -6, 0, -2 }, Reach = 90 },
		{ Id = CRACK, Volume = 0.5, Speed = 0.85, Var = 0.05, Len = 0.25, Fade = 0.1, Eq = { 2, 0, -6 }, Delay = 0.3, Reach = 90 },
	},
	GoreBurst = { -- the head bursting: a heavy wet blast, bone breaking, the bits raining down
		{ Id = HIT_STRONG2, Volume = 1.3, Speed = 0.7, Var = 0.05, Len = 0.5, Fade = 0.25, Eq = { 8, 0, -4 }, Drive = 0.25, Reach = 160 },
		{ Id = BREAK, Volume = 0.8, Speed = 1.1, Var = 0.06, Len = 0.45, Fade = 0.2, Reach = 140 },
		{ Id = THUD, Volume = 1.2, Speed = 0.6, Var = 0.05, Len = 0.3, Fade = 0.15, Eq = { 8, 0, -12 }, Reach = 140 },
		{ Id = DEBRIS_SMALL, Volume = 0.4, Speed = 1.3, Var = 0.08, Len = 0.8, Fade = 0.4, Eq = { -6, 0, -4 }, Delay = 0.35, Reach = 90 },
	},
}

-- footfalls per floor material (the step-in's plant, landings): recorded steps from the SFX kit
Config.Footsteps = {
	Default = id(320886417),
	Grass = id(208892200), LeafyGrass = id(208892200), Ground = id(208892200), Mud = id(208892200),
	Sand = id(283500092), Pebble = id(283500092), Snow = id(19326880),
	Wood = id(199087855), WoodPlanks = id(199087855),
	Metal = id(348652690), CorrodedMetal = id(348652690), DiamondPlate = id(348652690), Foil = id(348652690),
	Glass = id(215246646), Ice = id(215246646), Fabric = id(133705377), Water = id(404956114),
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
Config.PushShare = 0.35 + 0.65 / 3

for name, a in pairs(Config.Attacks) do
	a.Id = name
	a.HitReal = a.Hit / a.Speed -- seconds from start to impact
	a.ChainReal = a.ChainAt / a.Speed
	a.LengthReal = a.Length / a.Speed
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
-- only goes on the killing blow)
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

-- the wounds a fighter is left with once an arm has grown back to `stage` (just enough that the
-- arms it still misses stay missing; the regrown one takes the same share of damage again to lose)
function Config.WoundsAfterRegrow(stage: number): number
	return if stage >= 1 then 1 - Config.Gore.Stages[stage] else 0
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
-- only that hand's single strikes and the Ground Smash; with none, only the Ground Smash
function Config.CanUse(stage: number?, move: string): boolean
	local G = Config.Gore
	if not G.Enabled then
		return true
	end
	local arms = Config.ArmsAt(stage)
	if arms >= 2 then
		return true
	end
	return move == "Downslam" or (arms == 1 and (move == G.OneArm.Light or move == G.OneArm.Heavy))
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
