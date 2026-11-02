# Local co-op (split screen) in Phantom Pact 1.6.0

Mode > LOCAL under MORE in the F5 panel, or `Role = Local` in `PhantomPact.ini`, puts two players on one PC, side by side on
one screen, no internet and no second PC. It is in testing: the whole of 1.5.0's local co-op work was done on Xigu with two DualSense pads through
DS4Windows, and the rest of the game has not been walked through yet.

## Setup

1. Install the mod as for online play (INSTALL.md).
2. In the game press F5, then MORE, and set Mode to LOCAL. It works from the next start, so restart the game. (Or in
   `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini` set `Role = Local` before you start.) `Joysticks = 2` there means one pad
   per player, the default. `Joysticks = 1` means keyboard and mouse for player 1, the pad for player 2.
3. Start the game and CONTINUE your save. Player 2 appears beside player 1 within a few seconds, as a second Soul.
4. F4 opens the local co-op panel in the game: screen layout (left/right or top/bottom) and which pad is whose, by
   dragging. Its choices replace the ini setting.
5. MULTIPLAYER in that panel goes back to online co-op, from the next start of the game: it sets `Role = Off`, and F5 works again.
   Local co-op can't be turned off live, since taking player 2 away at the wrong moment has killed the game's menus.

Player 2 shares player 1's save, backpack, dust and gourd count, and rests at the same bells. Player 2 cannot die for
good: at zero health they are down for a while and come back beside player 1.

## Pads

PlayStation pads need this setup, with one pad or two. Without it the game sends every pad to player 1, and input can
freeze for a moment. It's the setup two DualSense pads were tested with.

1. **Turn off Steam Input.** In Steam, right-click the game > Properties > Controller, then pick Disable Steam Input.
2. **Install [DS4Windows](https://github.com/schmaldeo/DS4Windows/releases)**, connect your pads and leave it running.
   The game then sees them as Xbox pads.
3. **Install [HidHide](https://github.com/nefarius/HidHide/releases)**, which stops the game seeing the real pads as
   well. Open it, add `DS4Windows.exe` under Applications, then on the Devices tab tick your pads and Enable device
   hiding.
4. **Check DS4Windows.** The Ex column should show a tick for each pad. If it doesn't, reconnect the pads.
5. **Start the game, then press F4.** Hold a button on each pad to light up its card, drag the cards onto the players
   and press APPLY.

Xbox pads shouldn't need any of this, but they haven't been tested. Keyboard and mouse for player 1 with a pad for
player 2 also works: drag the Keyboard & Mouse card onto player 1 in the same panel.

Online co-op needs none of this. If your pads stop working in other games, turn off Enable device hiding in HidHide. A
game update can break two-pad play until the mod is updated, because it depends on the game's exact build.

## Player 2's controls

The game only reads some things from "the player", which is always player 1, so the mod reads player 2's pad itself
for those and performs the action with player 2's own body:

| Pad 2 | Does |
|---|---|
| Left stick, right stick, attacks, dodge, block | The game's own handling, as for player 1 |
| Cross (A) | Jump; inside a climb spot: ladder, wall run, side run, rope swing, rappel, pole or slide; looking at a gap blocker within its range: the hook shot across |
| Circle (B) | Use: chest, rubbish pile, door, lever, bell, loot card confirm |
| D-pad down | Drink the gourd: heals player 2 and uses player 2's own charges |
| Options | Pause menu (the one menu is shared; whichever pad opened it drives it) |
| Select / touchpad | Quest-direction sense; it reports on both screens |

Player 2's prompts are the game's own: the same widget and animations as player 1's, set down on the thing itself in their half
of the screen, with the button of their own pad. They follow the game's rules: in reach and faced, on the ground. With the thing
out of their half, a plain button stands in at the bottom of it.

Player 2 has the game's own HUD in their half too: health and ShaChi bars, gourd, weapons, buffs, a boss's bar, arrows to enemies
out of view, and execution points on the enemies they can finish, all their own. The gourd on it shows their own charges. Going
down, the game's death card plays in their half alone, and they get back up off the ground beside player 1.

## What the game hardwires to player 1, and how 1.5.0 bridges it

- **Interaction prompts** are drawn for player 1 only, on the things themselves, and player 2's own search would play them
  there too (player 2 walking off shrank player 1's prompt to a dot), so that search is paused. The mod asks player 2's interact
  component what the game allows (`CanTriggerInteract`, `IsPlayerFaceToActor`) and starts the interaction through it (climb spots)
  or through player 1's component with player 2 named as the opener (chests, piles), with player 1 pinned in place so they never
  walk to it.
- **Loot** is handed out only through player 1's interact component. Chests opened by player 2 still give the loot
  to the shared backpack. The loot card draws on player 1's half; Circle on pad 2 confirms it.
- **The gourd and the D-pad's other item** work on "the player". Player 2's body drinks by the game's own ability, and for the
  one call that applies it, player 1's controller points at player 2's body: the heal, its buffs, its glow and the HUD's flash are
  theirs. It's charged to player 2's own count, which refills at a bell to the gourd's maximum, and a press with the shared gourd
  dry still drinks their own charge.
- **The bell menu and pause menu** listen on player 1's screen. The mod makes them full screen, routes both pads to
  them, and hands the pads back when they close.
- **Enemy optimization** (the NPC optimizer) measures distance from player 1. Enemies far from player 1 are set
  flying, ticked slowly and hidden. The mod switches optimization off within 80 m of player 2 and puts those enemies
  back on their feet, visible and ticking normally.
- **Enemy combat AI** stays disabled until "the player" (player 1) enters the enemies' fight area. The mod enters
  player 2 into the area and fires each enemy's enter event with player 1 named as the one who came in. From then on
  the enemies' own eyes and hatred work on player 2 as on player 1: in testing, enemies 300 m from player 1 noticed a
  lone player 2 in about 2 s and were hitting within 7 s.
- **Enemies around a lone player 2** are woken from their spawners when player 2 is more than 20 m from player 1.
- **Story scenes** play on player 1's camera. Both players watch full screen; player 2's Soul and weapons are
  hidden and pad 2 is ignored for the scene, and both come back when it ends. If the scene moved player 1, player 2
  is brought along.
- **The HUD** binds to player 0's body as it's made, so player 2's is made in the moment player 1's controller points at player
  2's body, with no possession. It shows and hides by the same rules as player 1's. A health change the mod writes by hand is
  told to it.
- **Bosses.** The boss health bar is player 1's HUD's, and a second HUD can't make one; player 2's is the game's bar made by hand in
  their half for the fight.
  The boss gets the same combat wake-up for player 2 as any enemy. Fog walls close around whoever started the
  fight: player 2, left outside, walks up to the fog and presses Circle, or just stands there a few seconds, and is
  set down beside player 1. Checked with Peng Meng, the Axemaster, on Xigu: intro scene, bar on both halves, the
  boss turning on player 2, the join from outside the fog.
- **The game's screens** (tutorial and information pages, chapter titles, dialogues, videos, confirmations,
  loading) are put up for player 1. While any of them is up, the screen goes full width, both pads drive it and
  player 2 stands still, as with the pause and bell menus. The loot card and the dust line are left alone.
- **Long moves of player 1** (a bell's fast travel, a door that leads elsewhere, a scene, a level load) take player 2
  along; a long move holds the Soul in the air until player 1 stands on the ground again, so the ground has streamed
  in before player 2 is set down beside player 1.
- **Dialogues** (the story NPCs' talks, with their choices) are player 1's screen: full width, both pads on it,
  player 2 held, and released when it closes. Checked with Yu'er at the start of chapter 1, choices and the closing
  scene included. Should the game ever leave pad 2 ignored after such a scene, the mod notices within a second and
  releases it.
- **Map changes** (Return to Title Screen, Load Game from the pause menu, and any level travel) are made with player
  1 alone: just before the engine loads the next map, player 2 steps out entirely, and once the new map is playing
  they are created again beside player 1. Without this the title screen came up black. Checked both ways on Xigu:
  title and CONTINUE, and Load Game of the latest save; the pause menu and the split come back each time.
- **The pause menu stops the game, not the clock.** Player 2's six-second return from being down, and the rescue of a
  Soul that fell out of the world, wait while the game is paused or a scene plays, so nothing is spawned into a frozen
  world. The game's tutorial hint bars (the little "press twice to drink" strips) are overlays, not pages: they hold
  nobody.
- **A dropped pad** (battery, cable, DS4Windows restarting) leaves that player's Soul standing with a health floor and
  a message; the same pad coming back, or any free pad held for a second, takes the player over. Checked by faking
  the pad state file: both pads gone and back, a third pad claiming player 1, pad 1 claiming it back.
- **The bell menu does not pause the game.** A player 2 left far away in a fight while player 1 is at the bell stands
  still (pad 2 drives the menu) and can be beaten down; they come back beside player 1 as usual, menu or no menu.
  Best rest together.

## Known limits

- Everything above was tested on Xigu (chapter 1 up to the village and the Peng Meng arena): the chapter's opening
  dialogue and scenes, a boss with its fog walls, deaths (player 1's real deaths with player 2 down, and both down at
  the same instant), rests, the pause menu and the F4 panel at the wrong moments, Return to Title and Load Game.
  Later chapters with two local players are untested, as is a fullscreen toggle during play.
- Player 2's refill at a rest, and two players using one chest in the same instant could not be driven without pads; the code
  paths exist and are unverified.
- The quest-direction sense and "information" screens draw on player 1's half; the loot card too.
- The ledge vault (mantle) fails for both players through the mod's route; the game's own does it for player 1.
- Lock-on for player 2 could not be checked without a pad; the game's own targeting runs per player.
- Story NPCs are talked to by player 1 (the game's interaction is player 1's); the dialogue screen is shared.
- Shops and training are pages of the bell menu, which both players share. Doors that need an item (the game's
  switches with required items) do not occur in chapter 1 on Xigu and are untested for player 2; the mod's route
  would open one through player 2 with the shared backpack, but the "needs item" page would draw on player 1's half.
- Two pads of the same kind through DS4Windows work; other pad setups may need the F4 panel.

## For developers

`mod/PBZCoop/Scripts/localcoop.lua` holds all of it. `tools/localcoop/` has the launcher, the command runner, the Lua
test helpers (teleports, walking, input injection, enemy and fight-area probes), the story probes (quests, flow
nodes, switches, level actors by name) and the soak script. Notes on what crashes the
game from Lua are at the top of `tools/localcoop/README.md`: never read every property of a blueprint object, never
iterate a TMap, never call into an enemy that has just died.
