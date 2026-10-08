# Overkill

## The overhaul (binary place)

- `overhaul/Overkill_overhaul_v88.rbxl` - **the latest overhaul place. Open this one in Roblox Studio.**
- `overhaul/Overkill_overhaul_v87.rbxl` - the place it was built from, kept for comparison.
- `overhaul/src/` - its scripts as plain Luau (file name = path in the game tree). These are the v88 sources.
- `overhaul/build.sh` - writes `overhaul/src/` into v87 and adds the lightning meshes v88 uses, giving
  v88. It uses `tools/build_rbxl.py`, which replaces only the scripts that changed. `tools/rbxbin.py`
  keeps every other byte of the place as it was. `tools/extract_rbxl.py` pulls the scripts out of a place.
- `tools/lune/` - tests for Azure Tide Cannon, run with [Lune](https://github.com/lune-org/lune) 0.10.4
  against the real place:
  - `azure_tide_fx.luau` plays the whole effect frame by frame and checks for errors and leftovers
  - `azure_tide_hits.luau` runs the server's beam hits against a test world

  ```
  overhaul/build.sh
  lune run tools/lune/azure_tide_fx.luau overhaul/Overkill_overhaul_v88.rbxl overhaul/src floor
  lune run tools/lune/azure_tide_hits.luau overhaul/Overkill_overhaul_v88.rbxl overhaul/src
  ```

### What changed in v88: Goki's Azure Tide Cannon

**The beam is fully 3D and continuous.** The flat ribbons, the rays, and the glow sprites that were
stacked along it are gone. Now it is four nested layers:

- a white-hot core
- a cyan layer
- an azure body
- a force-field shell

Each layer flares out of the sphere in the hands as a smooth teardrop and runs whole into the end
ball. There are no joins and no circles along it.

**It is electric.** The VFX library's Lightning mesh is wrapped around the beam in lengths. Each
length is spun and flickered every few frames, the way its own pack animates it. 3D lightning arcs
also leap along the beam's skin. With every hit, a surge of light rushes down the beam and lands in
the end ball.

**It reaches 80 studs, not 150.**

**The end ball (new).** This is the beam's head: a 3D ball in a crackling lightning cage, with three
Thunder bolts discharging out of it. It:

- races out stretched like a comet
- squashes when it lands
- thumps and throws an electric shockwave ring on every hit
- discharges lightning into what it touches: the floor and wall round it, the body it is on, or open
  air
- throws chips of the surface it is grinding

**The charge keeps its design.** Every layer now sits inside the 3D sphere, so there are no halo
discs round it. The streaks, wisps and 2D bolts are 3D lightning instead:

- drawn in from all round the hands
- fed into the sphere from each palm in turn
- snapping off the sphere as it surges
- a lightning cage and electric accretion rings round the black hole

**The explosion is compact and symmetric.** In its last quarter second, the beam drains into the end
ball while a force-field shell crushes in on it. Then it detonates exactly `BlastRadius` (11 studs)
round. Before, the blast was about 20 studs and its fireballs reached about 78 across. The blast is:

- a white-hot core, and an energy dome and its skin, all cooling from white to deep blue
- a level electric shockwave ring and a mirrored tilted pair
- 8 lightning rays evenly round along the ground and 4 rising between them
- 6 Thunder bolts
- a ring of 10 rock spikes torn up round the crater
- 12 chunks of that ground thrown evenly all round. They tumble with dust trails, bounce, settle
  and sink away.

Lightning then crackles over the crater while the light cools. The packs' bursts keep only their
smoke, dust, flames and shards: flat rings, streaks, lines and glow discs are filtered out.

**Hitboxes match what you see** (server: `AbilityService`, shared math: `BeamMath`):

- Hits reach only as far as the head has travelled. The first hit lands 0.1 s after the release.
- A body beside the beam is hit only with no wall between them and the beam.
- The beam's width hitbox (`HitRadius` 2.6 × its size) is drawn width: between the azure body and the
  shell. It narrows wherever the beam is drawn narrower, for example along a floor or as a short beam.
- The final blast hits the body the beam ends on and everyone within `BlastRadius` of its end, with
  nothing between. Bodies along the drained beam are not hit by it.
- The server's ability clock no longer starts with a wrong first step.

**The hotbar icon has an outline.** The Azure Tide icon now has the HUD's ink outline round its own
shape. It scales and wiggles with the icon, and fades with it while on cooldown.

**Code check.** Every script in the place was type-checked with luau-lsp and the Roblox definitions.
The few warnings it gave were not real errors, apart from the server clock's first step above.

## The premium polish line

- `Overkill_premium_polish_v33.rbxlx` - the latest place of this line.
- `Overkill_premium_polish_v32.rbxlx`, `Overkill_premium_polish_v31.rbxlx` - earlier builds.
- `Overkill_premium_polish_v30.rbxlx` - the original place file (v30), kept for comparison.
- `src/` - every script in the place, extracted as plain Luau (file name = its path in the game tree). These are the v33 sources.
- `tools/build_place.py` - writes `src/` back into a place file:

  ```
  python3 tools/build_place.py Overkill_premium_polish_v30.rbxlx src Overkill_premium_polish_v33.rbxlx
  ```

  Only the scripts whose source changed are replaced. The rest of the place is copied through byte for byte.

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
