# Overkill

- `Overkill_premium_polish_v31.rbxlx` - **the fixed place. Open this one in Roblox Studio.**
- `Overkill_premium_polish_v30.rbxlx` - the original place file (v30), kept for comparison.
- `src/` - every script in the place, extracted as plain Luau (file name = its path in the game tree). These are the v31 sources.
- `tools/build_place.py` - writes `src/` back into a place file:

  ```
  python3 tools/build_place.py Overkill_premium_polish_v30.rbxlx src Overkill_premium_polish_v31.rbxlx
  ```

  Only the scripts whose source changed are replaced. The rest of the place is copied through byte for byte.

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
