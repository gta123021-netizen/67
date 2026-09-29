# Overkill

- `Overkill_overhaul_v75.rbxl` - **the latest place. Open this one in Roblox Studio.**
- `Overkill_overhaul_v74.rbxl` - the build v75 was made from.
- `Overkill_premium_polish_v30.rbxlx` .. `v33.rbxlx` - older builds.
- `src/` - every script in v75, extracted as plain Luau (file name = its path in the game tree;
  `src/_manifest.tsv` lists each file's class and path).
- `tools/rbxtool` - reads and writes binary places. Build it with
  `cargo build --release --manifest-path tools/rbxtool/Cargo.toml`, then:

  ```
  rbxtool dump  <place.rbxl> <dir>              # every script into <dir>
  rbxtool tree  <place.rbxl> <out.txt> [full]   # the whole game tree (full: with properties)
  rbxtool build <in.rbxl> src <out.rbxl> [--adds f] [--graft f] [--set f]
  ```

  `build` writes `src/` back into a place (only the scripts that changed) and checks the result
  reads back exactly what `src/` holds. v75 was built with:

  ```
  rbxtool build Overkill_overhaul_v74.rbxl src Overkill_overhaul_v75.rbxl \
      --adds tools/v75_adds.tsv --graft tools/v75_graft.tsv --set tools/v75_set.tsv
  ```

  (`--adds`: new scripts; `--graft`: effects copied out of the place's own VFX packs into
  `ReplicatedStorage.Combat.VFX`; `--set`: property changes, e.g. switching scripts off.)
- `tools/tests` - the combat's client and server modules run outside Studio on a small stand-in for
  the engine (`rbxmock.lua`). Build the runner with
  `cargo build --release --manifest-path tools/luau/Cargo.toml`, then:

  ```
  tools/luau/target/release/luaurun tools/tests/blood_test.lua .       # every blood profile, wounds, walls, budgets, cleanup
  tools/luau/target/release/luaurun tools/tests/gore_test.lua .        # arms torn off, head burst, bleeding, drips
  tools/luau/target/release/luaurun tools/tests/server_test.lua .      # CombatService: a full string between two NPCs
  tools/luau/target/release/luaurun tools/tests/pool_shape_test.lua .  # prints the pools as text
  tools/luau/target/release/luaucheck src/*.lua                        # every script compiles
  ```

  They check that the code runs (no errors, budgets kept, everything cleaned up) - not how it looks.
- `tools/build_place.py` - the old tool for the `.rbxlx` builds.

## What changed in v75

### Blood: one system instead of loose effects

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

### The place's own blood effects

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

### Health and regen

The health bar over a player now shows the health their regen reserve will still give back: a
faint teal stretch past the fill. It is dim while the fight is on, clearer as the regen delay runs
out, and breathes with the heart while it heals, the fill growing into it.

### Combat and animation

- A hit reaction no longer runs out and snaps back to the stance in the middle of a stun when a
  second blow lands without restarting it (players and NPCs). A reaction clip that is started again
  never gets the freeze that was scheduled for its previous play.
- NPC fighters (the practice and sparring dummies) now take blows the way players do: the reaction
  blends from their current pose (a slower blend when the head whips across), holds the impact
  through the hit-stop, sags back after its peak, holds its last pose until the stun ends and then
  fades out. Their strike clips fade out at the end instead of popping back to the idle pose.
- A body knocked down again and again no longer collects dead connections.

### Optimization

The 32 demo scripts inside the VFX showcase packs in the Workspace are switched off. They ran on the
live server forever: Hollow Purple's two scripts created about 26 parts a second (20 of them loose
physics debris), and the "Grow", spin and shield scripts rewrote parts' orientation and transparency
every frame - all of it replicated to every player. The packs themselves are untouched and still in
the Workspace to browse (the list is `tools/v75_set.tsv`).

## Older builds

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
