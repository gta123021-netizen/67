# Overkill

- `Overkill_premium_polish_v33.rbxlx` - **the latest place. Open this one in Roblox Studio.**
- `Overkill_premium_polish_v32.rbxlx`, `Overkill_premium_polish_v31.rbxlx` - earlier builds.
- `Overkill_premium_polish_v30.rbxlx` - the original place file (v30), kept for comparison.
- `src/` - every script in the place, extracted as plain Luau (file name = its path in the game tree). These are the v33 sources.
- `tools/build_place.py` - writes `src/` back into a place file:

  ```
  python3 tools/build_place.py Overkill_premium_polish_v30.rbxlx src Overkill_premium_polish_v33.rbxlx
  ```

  Only the scripts whose source changed are replaced. The rest of the place is copied through byte for byte.

## What changed in v33

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

## What changed in v32

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

## What changed in v31

### Even icon spacing, down to the pixel
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

### HUD pills
- The CHANGE button is centred vertically in the HERO pill.
- The + button and the circle around it are centred in the COINS pill. The + is now drawn with bars
  instead of a font character, so it sits in the exact middle.
- The LEVEL pill has more mini stars (about 33 instead of about 22), as dense as the shurikens and coins.

### Bug fixes
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
