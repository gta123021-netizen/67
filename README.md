# Overkill

- `Overkill_overhaul_v76.rbxl` - **the latest place. Open this one in Roblox Studio.**
- `Overkill_overhaul_v75.rbxl` - the build before it (v76 was built from v75 with the Advanced Movement
  System imported into its Workspace).
- `Overkill_overhaul_v74.rbxl` - the build v75 was made from.
- `Overkill_premium_polish_v30.rbxlx` .. `v33.rbxlx` - older builds.
- `src/` - every script in v76, extracted as plain Luau (file name = its path in the game tree;
  `src/_manifest.tsv` lists each file's class and path).
- `tools/rbxtool` - reads and writes binary places. Build it with
  `cargo build --release --manifest-path tools/rbxtool/Cargo.toml`, then:

  ```
  rbxtool dump  <place.rbxl> <dir>              # every script into <dir>
  rbxtool tree  <place.rbxl> <out.txt> [full]   # the whole game tree (full: with properties)
  rbxtool kfs   <place.rbxl> <out.lua>          # every KeyframeSequence (poses, markers) as a Lua table
  rbxtool build <in.rbxl> src <out.rbxl> [--adds f] [--graft f] [--set f] [--move f] [--delete f]
  ```

  `build` writes `src/` back into a place (only the scripts that changed) and checks the result
  reads back exactly what `src/` holds. v76 was built from the v75 place with the movement pack in it:

  ```
  rbxtool build Overkill_overhaul_v75_movement.rbxl src Overkill_overhaul_v76.rbxl \
      --adds tools/v76_adds.tsv --graft tools/v76_graft.tsv --move tools/v76_move.tsv --delete tools/v76_delete.tsv
  ```

  (`--adds`: new scripts; `--graft`: effects copied out of the place's own packs into
  `ReplicatedStorage.Combat.VFX`; `--move`: instances re-parented; `--delete`: instances removed; the
  lists name instances by their line in `rbxtool tree` of the input place.)
- `tools/tests` - the combat's client and server modules run outside Studio on a small stand-in for
  the engine (`rbxmock.lua`: a floor, walls, a ledge, platforms with a crack, Terrain hills, a pond).
  Build the runner with `cargo build --release --manifest-path tools/luau/Cargo.toml`, then:

  ```
  tools/luau/target/release/luaurun tools/tests/traversal_test.lua .   # the ten moves x eight body states, limbs lost mid-move, the fight, exploits
  tools/luau/target/release/luaurun tools/tests/blood_test.lua .       # every blood profile, spray vs pools, walls, water, wounds, budgets, cleanup
  tools/luau/target/release/luaurun tools/tests/fluid_test.lua .       # the liquid on Terrain: hollows, slopes, cliffs, cracks, ledges, water, grass
  tools/luau/target/release/luaurun tools/tests/gore_test.lua .        # arms torn off, head burst, bleeding, drips
  tools/luau/target/release/luaurun tools/tests/server_test.lua .      # CombatService: a full string between two NPCs
  tools/luau/target/release/luaurun tools/tests/pool_shape_test.lua .  # prints the pools as text
  tools/luau/target/release/luaucheck src/*.lua                        # every script compiles
  ```

  They check that the code runs and does what it should (no errors, the right moves allowed and
  refused, budgets kept, everything cleaned up) - not how it looks.

## What changed in v76

### Movement: ten moves from the Advanced Movement System, rebuilt inside the fight

Only these ten were taken from the pack - **crouch, crawl, slide, slide cancel, vault, ledge vault,
wall climb, wall run, double jump, leap** - and rebuilt inside the game's own systems
(`ReplicatedStorage.Combat.Traversal`). The fight's client drives it every frame, its animation
controller plays the clips (the pack's own animations, by id: `Config.Anim`), the fight's mover
carries the slide and the leap. Nothing else of the pack is in the game: its sprint, dash,
wall jump, sitting, spinning/gliding, swinging, ziplines, hard-landing roll, footstep sounds, camera
module fork, input scripts, hotbar, mobile buttons, freecam, bone physics and networking library were
all deleted with it (see below), so no key, button, touch control or leftover script can reach them.

| move | how | needs |
| --- | --- | --- |
| crouch | C (gamepad R3, touch CROUCH tap) - toggles | both legs |
| slide | the crouch key while running | both legs |
| slide cancel | jump in a slide: a hop that keeps the slide's speed | both legs |
| crawl | X (gamepad D-pad down, touch CROUCH hold) - toggles | both arms (the clip pulls the body hand over hand) |
| leap | R (gamepad RB, touch LEAP), from the ground | both legs |
| double jump | jump in the air, once each time off the ground | both legs |
| vault | by itself: run at something hip to chest high - over it, or onto it if it's deep | one hand on it + both legs |
| wall climb | by itself: jump at (or run into) a wall taller than a vault, holding forward | both arms + both legs |
| ledge vault | at the top of a climb: over the edge onto it | one hand + both legs |
| wall run | by itself: in the air after a jump, going fast along a wall beside you | both legs |

The keys were picked after going through every existing control: Ctrl (the pack's slide) is shift
lock, F (the pack's leap) is block, E is interact - the new keys C, X and R were free, and all three can
be rebound in Settings > Keybinds (a new MOVEMENT section). Leap, double jump and slide cancel + M1 is
the Ground Smash, like a jump.

**The body decides.** What a move needs was taken from the clips themselves - each one's keyframes were
run through the R6 rig to see where the hands and feet really go: the two vault clips each plant ONE
hand on the obstacle (Vault_1 the left, Vault_2 the right), the crawl pulls with both hands, the climb
uses all four limbs, the slide rides on the legs and hip (the right hand only brushes the ground).
`BodyState` reads what a body still has straight off the dismemberment's own record (the gore stage the
server keeps and the limb parts it hides) - one read a frame, no copy of it anywhere. So:

- a move a body can't do isn't started - no invisible hand ever grips a ledge or a wall, a legless
  body never jumps twice or leaps; a one-armed fighter vaults on the hand it still has (the clip for
  that hand), a fighter with no arms can't vault, climb or crawl at all
- a limb lost mid-move ends it on the spot, in the same frame the gore stage changes: off the wall
  with the speed it had (never left floating or stuck to it), out of the vault into a fall, the slide
  let go, the crawl stood up out of - its clip faded out, nothing left running
- no chain of inputs gets round it (crouch -> slide -> cancel, wall run -> jump, crouch -> crawl): every
  press and every frame asks the body again. The server checks every move against the body it knows
  and refuses one that doesn't fit (the client then ends it)

**The fight decides.** A move starts only while the fighter is free. A blow, stun, guard break,
knockdown or death ends every move at once and the fight takes the body; a strike, dash or guard from a
crouch or crawl stands up first, out of a slide or a wall run lets go (keeping the speed); on a wall or
mid-vault the hands are busy - no strike, dash or guard. The camera sinks with the head in a crouch or
crawl (and always comes back up); the leap and landings kick it through the combat camera, so nothing
- FOV, offset, tilt - is ever left changed. Crouching and crawling keep the standing collision box (an
R6 body can't be shrunk safely), so nothing ever gets wedged; a crouch or crawl only stands up where
there's room.

The effects are the pack's (copied into `ReplicatedStorage.Combat.VFX`: SlideDust, DustCloud, AirJump,
AirJumpLines, LeapBurst, LandDust), played at the feet and the root - never on a limb - with the dust
tinted to the ground it rises from; everyone sees them through the server. Like the combat, the moves
make no sound.

### Blood: spray that sprays, pools that pool, and it all moves with the body

The amount of blood is the same as v75's. What changed is how it looks and behaves:

- **Spray vs pools.** Small drops are spray: where they strike - floor, walls, anything solid, never a
  fighter - they leave spatter shaped like real bloodstains: as wide as the drop spreads (wider the
  faster it came), stretched along its travel to 1 / sin of the angle it came in at, with a thin tail
  thrown on past it when it came in low. Spray only joins a pool it lands in. Only real volume - heavy
  drops, a wound's steady bleeding - pools on the floor or runs down a wall. In the air, spray flies as
  thin streaks, not beads.
- **A severed limb bleeds like one.** Each heartbeat's spurt is a coherent stream of small drops along
  the jet (the same blood as before, in more, smaller drops), and the jet follows the wound's
  orientation every frame - a body flipping over a vault or thrown through the air swings its jet with
  it. Every wound's blood leaves with the wound's own measured motion (its run, spin, tumble and the
  clip swinging the stump), so blood from a leaping, wall-running or vaulting body keeps its momentum
  and falls away from it naturally, never hanging in the air or glued to the body.
- **Moves and blood.** A bleeding body that crawls, slides or is thrown along the ground drags one
  continuous streak of blood with it (poured into the same liquid - never a row of stamps); a bleeding
  body landing hard from a move jolts a little blood out.
- **No more bubbles.** The lighter circles in the pools are gone: one constant dark red (it never dries
  to another shade), no wet sheen, and every pool piece is a flat disc, so pieces that overlap read as
  one smooth surface with only the darker rim round the outside.
- **The world.** The ground is a height field that follows floors, stairs and Terrain: blood runs
  downhill, gathers in dips, seeps through cracks, pours off ledges, trickles down cliffs, soaks into
  grass/sand/dirt/fabric, stays on plastic/metal/glass; falling into water it clouds in it. It reacts
  as it lands - the liquid now runs at 30 Hz and a splash spreads in 0.13 s.
- **Dismemberment moments.** A limb torn off near you throws the camera with the blow and pushes in on
  it (the head burst already did).

### The lag: 7.6 MB of showcase assets gone

The asset packs parked under the map in the Workspace (VFX showcases, wing rigs, weapon meshes) kept
**4,194 particle emitters running all the time** - one pack alone asked for ~236 million particles a
second - plus 739 beams, 39 lights and ~16,000 parts, much of it inside the 1,024-stud streaming range.
Nothing in the game used them at runtime. The effects the game plays had already been copied out
(`ReplicatedStorage.Combat.VFX`); the packs are deleted. The place went from 7.6 MB to about 2 MB;
the Workspace now holds the map and nothing else (86 emitters - the fountain and the crater).

The movement pack's own map and its **7 enabled neutral SpawnLocations** (players could spawn in it,
1,000 studs underground) are deleted with it, and so is its server script, which errored on every
server start. The rigs holding the ten moves' clips are kept in `ServerStorage.MovementAnimations`
(their sources, to re-publish them from if ever needed - see below); the rigs and clips of the moves
the game doesn't have (dashes, sitting, zipline, swing, spin, wall jumps, its run / walk / idle set)
are deleted.

### Deleted: unused code

- the movement pack: every script, UI, effect and its map (only its clips and the effects above are
  used, copied into the game's own places)
- the 32 demo scripts of the Workspace showcase packs and a pack's READ_ME script (with the packs)
- `Kit.bevel` (an empty, invisible frame - 17 calls), `Shatter.Preview` (Studio-only), `Blood.Burst`,
  `Pools.Clear`, and exports nothing read (`Gore.Bodies`, `FX.GroundHit`, `States.Rules`,
  `States.Control`, `HD.RawPaths`, `HD.SurfacePoint`, `HD.SegmentBox`, `Motion.BRAKE`,
  `Ragdoll.Joints`, `Theme.HUD_GROUP_GAP`); unused locals and parameters; an empty branch and a
  duplicated one
- `tools/build_place.py` (the old `.rbxlx` tool)

### If a movement clip doesn't play

The traversal clips are the movement pack's own animation ids (`Config.Anim`: CrouchIdle ...
WallRunRight). Roblox only plays an animation in a game its owner may use it in; if one doesn't play
in your game, publish it from its rig in `ServerStorage.MovementAnimations` (Animation Editor ->
Publish) and put the new id in `Config.Anim`.

## Older builds

### What changed in v75

#### Blood: one system instead of loose effects

**Every kind of blow bleeds its own way.** The blood of a blow comes from its profile
(`Config.Blood.Profiles`): the straights, the hook, the uppercut, the dash strike, the Ground Smash,
the sweep, a knockout, a torn-off arm and the head. A profile holds ranges, not numbers: which of
the place's blood effects it uses (one picked by weight, sometimes a second on top), how big and how
dense, how many drops and of what sizes (fine spray, ordinary drops, heavy blobs), how wide, how
fast, how far the struck part's own motion throws them, and whether a late squirt follows out of
the same wound or blood comes out of the mouth. Harder blows bleed more, and so does a fighter who
is already badly hurt. The aim is jittered on every blow, so no two sprays are the same.

- the straights: a quick spray thrown back along the blow
- the hook: flung sideways with the twist
- the uppercut: a heavy spray up and back, and blood spat up out of the mouth
- the dash strike: a thick burst thrown back along the lunge, blood coughed out
- the Ground Smash: blood forced out low and outward, then a long trail along the slide
- the sweep and any knockout: the blood explosion, wide and wet, and blood raining off the body all
  along its flight

**Dismemberment wounds bleed by themselves.** A torn-off arm's shoulder bursts, then gives two or
three weaker gushes, then pumps with a heartbeat: a spurt every beat (the jet rises and falls within
the beat, so its arcs lengthen, then shorten), short squirts between beats, and a steady dribble
down the body. The beat slows and the spurts weaken as the pressure drops (about 8 s), then the
wound oozes (25 s). The jet always comes out the way the stump faces - a body that turns, falls or
is ragdolled turns its jet with it - whips a little from beat to beat and bows down as it weakens.
The torn-off arm bleeds from its end as it flies and slaps down in a splash of blood. After the head
bursts, the neck fountains in gushes, then pulses.

**Blood moves with the body.** Every drop and every effect from a body leaves with that body's own
velocity, so running with a stump leaves a streak of blood behind you, and a launched or ragdolled
body throws its blood along its path. A body sliding back from a blow drips a trail along the slide.
A fighter who has lost more than 45% of their health drips as they move (healed back under that
line by the regen reserve, it stops), and a bleeding body thrown to the ground lands in a splash.

**Pools are one liquid** (the new `BloodPools`). Every surface blood lands on gets a fine grid, and
each drop pours its volume into the cells it lands and skids across:

- a little blood is a small spot exactly where it fell, shaped by how it skidded
- where blood keeps landing, the cells fill up and run over into their neighbours - unevenly, so
  the edge grows in lobes instead of circles. Pools build up from what actually lands there
- pools that reach each other become one pool: every piece is opaque and lies in the same layer, so
  there is no see-through overlap, no darker intersection, no seam and nothing stacked. The darker
  clotting rim only shows round the outside of the whole shape
- the thick middle of a fresh pool has a wet sheen
- on a slope blood runs downhill; on a wall it runs down in a thin trail and drips off at the
  bottom (a wall never gets a flat "pool"); under a ceiling it gathers and drips back down
- it is never laid over a ledge or through geometry (every cell checks there is surface under it),
  and never on water, a fighter, anything see-through or anything that moves
- a joined pool dries on one clock (fresh blood poured into an old stain wets all of it again),
  darkens, loses its sheen, and after about 30 s soaks away from its thin edges inward

**It stays cheap.** Budgets: 96 drops in the air, 400 pool cells, 90 specks of spray, 60 pieces of
sheen; past the cell budget the oldest pool soaks away early. Every drop and pool piece is reused
(nothing is created or destroyed mid-fight), each stepper stops when there is nothing left to do,
and once all the blood has gone only a small reserve of spare pieces is kept. Players on low
graphics settings or on a phone get half to three quarters of the budgets (never less blood per
blow). Nothing is built out of the camera's reach.

Tuning lives in `Config.Blood` (profiles, `Wound` for the heartbeat, `Pool` for the ground) and
`Config.Gore` (`BleedTime`, `DripTime`, `DripFrom`, `DripRate`).

#### The place's own blood effects

No new effects were made. 13 effects were copied out of the blood packs already in the Workspace
into `ReplicatedStorage.Combat.VFX` (their emitters untouched, switched off, with emit counts):

| effect | from | used for |
| --- | --- | --- |
| BloodWound | A - SUDDEN WOUND | heavy hits, tears, knockouts |
| BloodJet | I - Veinless | arterial spurts, squirts |
| BloodStream | B - HEMORRHAGE | arterial spurts, gushes |
| BloodGush | E - Gushing | the tear's gushes |
| BloodBleed | D - Bleeding | gut hits, the smash |
| BloodDrip | B - Puddle | blood from the mouth |
| BloodSplatter / BloodSplatterWild | G - Splatter / H - Wild Splatter | light to heavy hits |
| BloodSpatter | C - BLOOD SPLATTER | light hits |
| BloodStrand | Anime: Blood-02 | long thin strands in squirts and spurts |
| BloodSplash | Anime: Blood-01 | a flat splash where heavy drops and limbs land |
| BloodPunch | Blood-Punch-01 | light hits |
| BloodBurst | the blood explosion (Blood / Blood2 / Blood3) | knockouts, the head |

`CombatVFX.Play` now reuses its copy of an effect instead of cloning and destroying one per hit,
and takes more options (speed, spread, lifetime, gravity, velocity inheritance, delay, sprites
facing the camera).

#### Health and regen

The health bar over a player now shows the health their regen reserve will still give back: a
faint teal stretch past the fill. It is dim while the fight is on, clearer as the regen delay runs
out, and breathes with the heart while it heals, the fill growing into it.

#### Combat and animation

- A hit reaction no longer runs out and snaps back to the stance in the middle of a stun when a
  second blow lands without restarting it (players and NPCs). A reaction clip that is started again
  never gets the freeze that was scheduled for its previous play.
- NPC fighters (the practice and sparring dummies) now take blows the way players do: the reaction
  blends from their current pose (a slower blend when the head whips across), holds the impact
  through the hit-stop, sags back after its peak, holds its last pose until the stun ends and then
  fades out. Their strike clips fade out at the end instead of popping back to the idle pose.
- A body knocked down again and again no longer collects dead connections.

#### Optimization

The 32 demo scripts inside the VFX showcase packs in the Workspace are switched off. They ran on the
live server forever: Hollow Purple's two scripts created about 26 parts a second (20 of them loose
physics debris), and the "Grow", spin and shield scripts rewrote parts' orientation and transparency
every frame - all of it replicated to every player. The packs themselves are untouched and still in
the Workspace to browse (the list was `tools/v75_set.tsv`; v76 deletes the packs).

(v34 - v74 were made outside this repository; v74 is the place v75 was built from.)

### What changed in v33

- **No leftover rim beside the text.** An icon's rings all end on the edge of its slot. Where
  that edge fell between two screen pixels, each ring left a faint line of its colour next to
  the words: in PARTY, SETTINGS and every other header, the settings rows, party avatars, hero
  and aura rows, tab switches, toggles and the shop picture's bottom edge. Each of these edges
  is now covered by a 3-unit stroke in the container's own colours (`Kit.SEAM`, `Kit.seams`).
- **CHANGE and + buttons:** the blue line between the pill's outline and the button's outline is
  gone. There is one solid black band round each button, the same width on every side.
- **Dock buttons (SHOP, STATS, BAG, PARTY, MENU) are flat 2D:**
  - one solid face colour and an even accent ring
  - flat name tags
  - no shading, no glow under the icon, no coloured lower half
- **GOKI's name plate** in the quest dialogue: the orange rim is now a ring on the plate's own
  edge, so it is exactly as thick on every side. The same fix went into:
  - the portrait frame beside the plate
  - the quest board's hero tabs, quest cards, dialogue option keys, reset clock and header icon
  - the six stat tiles in the profile window

  The last pixel-snapping helpers are removed.

### What changed in v32

Roblox lays UI that has a UIScale out in unscaled units, rounds every edge there, and only
then scales it to the screen. So v31's pixel snapping could not hold: a panel inset inside a
plate, or an icon inset inside a row, was rounded on its own and still came out 1-2 pixels off
on one side (the thin-top, thick-bottom rim on the BACKPACK plate). In v32 every ring, rim and
icon gap is a stroke drawn on frames that share one rect with their container (new Kit helpers:
`Kit.rings`, `Kit.edgeStrokes`, `Kit.endIcon`, `Kit.slot`, `Kit.switchThumb`,
`Kit.outlineOnTop`). A stroke is drawn on its own frame's edge and is the same on every side,
so these come out exactly even at any screen size:

- every header plate (all windows, hero select, aura preview, MATCH FOUND, LOCKED IN): the ink
  border, the coloured rim, and the icon tile's gap on the left, top and bottom
- the CHANGE and + buttons: the gray socket band is gone; each button is the pill's right end
  with only its black outline, exactly as far from the pill's top, right and bottom
- tab switches (Settings GENERAL/KEYBINDS, hero MOVESET/LORE) and the on/off toggles (the
  toggle knob was 6 from the end but 5 from the top and bottom; now 5 all round)
- the HERO pill's portrait rings, hero roster portraits, aura orbs, settings row discs, party
  avatars and slots, rule badges, party frames, queue lock, invite avatars, toasts, shop cards
- the XP bar and slider outlines no longer look thinner along the filled part

### What changed in v31

#### Even icon spacing, down to the pixel
The HUD is scaled to fit the screen. Roblox then rounds every frame to whole pixels on its own, so an
icon set 10 units from its plate's left, top and bottom edges could land 8px from one edge and 7px
from the others. The same happened to the rims of the title plates. In v31 these are placed on whole
screen pixels (the new `Kit.snapEnd`, `Kit.snapFill` and `Kit.snapCorner`). They re-place themselves
when the screen size or the UI size setting changes, so the gaps are exactly equal at every screen size:

- every window and screen title plate (SETTINGS, SHOP, PROFILE, BAG, PARTY, CHOOSE YOUR HERO,
  aura preview, match screen, quest board): the icon tile and the plate's rim
- the HUD pills: the CHANGE button and the coins + button, each in a socket ring of even width
- settings rows, shop tip bar, party slots, member rows and rule cards, party frames, queue cards,
  the queue lock chip, portal signs, profile tiles, aura and hero rosters, the stamp on the hero card
- the quest board: frames, tier tabs, the reset clock, the header icon, quest cards and dialogue options
- toast cards

The two search bars (bag, party) and the panel headers in hero select and aura preview were also
evened out.

#### HUD pills
- The CHANGE button is centred vertically in the HERO pill.
- The + button and the circle around it are centred in the COINS pill. The + is now drawn with bars
  instead of a font character, so it sits in the exact middle.
- The LEVEL pill has more mini stars (about 33 instead of about 22), as dense as the shurikens and coins.

#### Bug fixes
- **Robux coin packs**: the coins and the purchase id are saved together before the purchase is
  confirmed. A purchase can no longer be paid out twice, or lost if the server stops.
- **Shutdown saves**: quest, shop and hero data now wait for every save to finish on shutdown. Before,
  there was a fixed 2 second wait that could cut a slow save off.
- **Queue**: when the last real player leaves a match, the match is closed properly. Before, the
  practice bots in it were kept in memory forever.
- **Profile window**: every coin or XP change reset all six stat tiles to 0. They now keep their values.
- **Portal titles**: a portal sign that streams in late shows the live queue count straight away.
- **Quest board**: its icon tile now changes colour together with the plate.
- **Settings**: the percentages are rounded, not cut off (57% showed as "56%").
- **QuestConfig**: removed a duplicate `HERO_OPTIONS` table.
