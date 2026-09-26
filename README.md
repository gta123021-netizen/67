# Overkill

- `Overkill_premium_polish_v46.rbxl` - **the latest place. Open this one in Roblox Studio.**
- `Overkill_premium_polish_v45.rbxl` - the place this refinement started from (binary, kept for comparison).
- `Overkill_premium_polish_v33.rbxlx` ... `v30.rbxlx` - older XML builds.
- `src/` - every script in the place, extracted as plain Luau (file name = its path in the game tree).
  These are the v46 sources.
- `tools/` - place tooling:
  - `rbxl.py` reads and writes binary places (byte-exact round trip; only changed chunks are re-encoded)
  - `extract_rbxl.py <place.rbxl> <dir>` - every script into a folder
  - `build_rbxl.py <in.rbxl> src <out.rbxl>` - `src/` back into a place (only changed scripts; every
    other byte of the place is copied through):

    ```
    python3 tools/build_rbxl.py Overkill_premium_polish_v45.rbxl src Overkill_premium_polish_v46.rbxl
    ```

  - `sourcemap.py` - a Rojo-style sourcemap so `luau-lsp analyze` can type-check `src/`
  - `build_place.py` - the older writer for the `.rbxlx` builds
- `tests/` - headless tests, run with [Lune](https://github.com/lune-org/lune) from the repository root:
  - `lune run tests/combat_sim.luau` - the real server combat modules from `src/` driven frame by frame
    (60 Hz, simulated clock, bodies on a flat ground with walls): chains, the target lock, anti-stunlock,
    Ground Smash rules, guard, lag compensation, spacing, walls
  - `lune run tests/logic_test.luau` - the facing turn, the input buffer, client/server agreement under
    latency, and the HUD column's spacing math

## What changed in v46 (combat refinement + HUD spacing)

### Combo target lock (server-authoritative)
- The **second consecutive strike of a chain that connects with the same fighter locks the chain onto
  them** (`Config.Lock`). From then on every strike of that chain - lights, the uppercut, the sweep -
  only tests that one body (a single-target fast path in `HitDetect`'s job loop). A third player
  walking in between, or the camera swinging onto someone else, never takes a blow meant for the
  locked fighter.
- The lock belongs to the chain (its chain id) and is cleared when the combo ends, its window runs
  out, the sweep lands, a dash / block / Ground Smash starts, the attacker is hit, knocked down or
  killed, or the victim dies or leaves. No stale references are kept (`forget` on death / leave).
- Before a lock, a normal strike connects with **one** body: the first one in its path (nearest).
  Ground Smash stays an area move.
- The client never decides the lock: the server sends it on every hit (`LK`) and in the attack
  acknowledgement.

### Invisible lock-on (client)
- One facing controller: a critically damped turn (no overshoot, a top turn rate of ~800 deg/s, the
  same at any frame rate) toward the locked fighter, or the aim for an unlocked first strike. No
  reticle, no snapping, no camera grab.
- The step-in and the follow after each connect keep the **next strike's own distance** from the
  locked fighter, following reasonable knockback only while they are in range.
- Moves never push a body into geometry: at an angle a drive slides along the wall, head-on it stops
  (`Motion`). Bushes and other non-colliding decoration are ignored.

### Measured spacing and hitboxes
- Every chain strike's `Ideal` distance is now **measured from `CombatPaths`**: the distance at which
  the striking limb's surface meets the victim's body on the Hit frame, less 0.12 so the blow visibly
  presses in. Straights 3.44 / 3.39, hook 3.33, uppercut 3.21, sweep 3.21, dash strike 4.5.
  (Swing3 was `1.7`: at that distance its lead arm was ~1.2 studs inside the victim on the hit frame.
  The torso lunges ~2 studs forward in that clip.)
- Limb capsules end **at the limb's own end** (the radius is taken off the measured tip) and the body
  box is R6-accurate, so a fist that visibly stops short never connects. Tested: each strike connects
  from its Ideal and misses a stud past it.
- The limb's way to the contact point must be clear of solid geometry (walls stop blows; decoration
  doesn't). A new strike ends the previous strike's hit job (no late hits from a blended-out limb).
- Dash stop gap 4.1 so a dash strike out of a dash lands with the arm on the body, not through it.

### Anti-stunlock
- **Stun budget** (`Config.StunBudget`): every stun from anyone spends it; it refills only while the
  fighter actually has control (free, attacking, guarding, dashing) and only after 0.25 s of it. When it
  runs out the stun in progress is the last one, then the escape window (`StunImmunity`): hits still
  hurt and push but neither stun nor interrupt. The longest legitimate string fits in a full budget;
  a knockdown refills it.
- "One chain per stun" now counts real control time: a new chain from the same attacker can't re-stun
  a body that hasn't had `ResetGrace` of control - waiting out the window, block / dash / jump cancels,
  the uppercut re-opening a string, a dash strike or a Ground Smash.
- Tested with three attackers taking turns for 12 s: no stun longer than the budget, repeated escape
  windows of ~1.1 s.
- Guard breakers against a fighter in its escape window are held off like a heavy blow.

### Ground Smash (jump + M1)
- Standalone: refused while a chain is live (no jumping in the combo window either); starting it ends
  any chain and its lock. It never knocks down or re-stuns a fighter still reeling from a combo.
- Server-verified: the server must see the jump; a client touchdown report only counts on solid ground
  under the reported feet; no landing (a ledge, the void, a fall that never ends) means no smash - never
  an impact in mid-air or under the map. The impact point is the floor under the stomping foot.
- Its area matches what you see: the shatter's outer plates end on `StompRadius`, and a fighter is hit
  when their footprint reaches it.
- **HUD cooldown slot** at the end of the hotbar row (the hotbar's own slot style): dims and drains
  while recharging with the seconds left, pops with a shine when ready. It follows the server's
  cooldown (`CombatCD_Downslam`, server time), not a local guess.

### Input buffer, networking, animation
- One buffered press at a time, used once, only for the chain it was meant for; strikes buffer 0.25 s
  before their chain point, a dash 0.15 s before control returns; stale and cancelled presses drop.
- Position reports can lead the server's copy only by what the body's own speed covers in a round
  trip (a standing attacker: 1 stud; was 7 for everyone). Rewind is capped at 0.22 s and 3.5 studs.
- Hit reactions that land back to back cross-fade from the current pose (a second copy of the clip)
  instead of snapping to frame 0; a strike's clip fades out at its end instead of popping; hit-stop has
  its own tier for light, heavy, sweep, dash strike, Ground Smash, block, heavy block and guard break.
- Touch: a held ATTACK is released when that finger lifts even off the button.

### Audio
- Every combat sound is a stack of layers (a snap over a body thud for punches; a boom, a sub-bass
  drop and rubble for the Ground Smash) shaped from Roblox's own client sounds with pitch, short
  envelopes, EQ and a touch of distortion, random pitch variants and distance roll-off, played from
  pooled voices. Other players now hear your whooshes and dashes too. Swap any `Id` in
  `Config.Sounds` for your own library sounds; every other setting still applies.

### HUD
- `Theme.Hud` holds the shared measurements (`Theme.HUD_GROUP_GAP`, outline weights, icon / row gaps,
  pill / tile / card / party sizes).
- The bottom-left column is one stack - party frames, portal (queue) card, dock, hero, coins, level -
  laid out with one `UIListLayout` at `HUD_GROUP_GAP`. Every group has the same outline centred on its
  own frame's edge and every frame is exactly as tall as what it draws, so the ink-to-ink gap between
  any two neighbours is identical (13.925 layout units x the HUD scale). The party frames and the portal
  card can no longer overlap. On phones the party frames stand beside the column.
- The dock tiles' name tags no longer hang below the tiles' outline.
- Portal card: drawn at the column's width with **one outline of the HUD's weight on top, no drop
  shadow** - the same on all four sides (the old one had a 10-unit shadow under it and a scaled 7.5
  stroke half hidden by its skin). The bottom-right queue card got the same treatment and its search
  segments are whole, equal widths.
- In Studio the HUD measures itself on screen (AbsolutePosition / AbsoluteSize) whenever the column
  changes and prints every gap in pixels (`EVEN` / `UNEVEN`).

### Studio-only debugging
- **F7** (or `LocalPlayer:SetAttribute("CombatDebug", true)`): an overlay with the local and server
  state, chain, lock and streak, stun budget and escape window, cooldowns, the strike's ideal vs actual
  range, round trip and server/client timing, the input buffer and the last hit - plus a tether to the
  locked fighter, the ideal-distance ring round the target and each contact point.
- Server side (command bar): `workspace:SetAttribute("CombatDebugDraw", true)` draws the hit capsules,
  the body boxes and contact points; `workspace:SetAttribute("CombatDebugHits", true)` prints how close
  every strike came to every body.
- None of this runs in a live server.

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
