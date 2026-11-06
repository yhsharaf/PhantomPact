# PvP (1.7.0)

Two ways to fight each other:

- **PvPvE** (F5 > MORE): the old PvP switch, renamed. Partners can hurt each other in the open world, enemies and all. Death
  decides, as before. The ini key stays `PvP` so old ini files keep working.
- **PvP** (F6): a match in one of four boss arenas, or where the host stands, with nothing else in it. This file is about this one.

## What a match is

| | |
|---|---|
| Players | 2 to 6, everyone linked, on the same version. 2 players: a duel. More: two teams (Crimson, Azure), each player picks one |
| Modes | **Duel**: best of three rounds, everyone back up each round. **Death**: one life, last team standing |
| Clock | None, 60, 90 or 120 s a round. At zero the team with more health left (as a share) wins the round; equal is a draw |
| Arenas | YuCong's Crimson Forest, Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's meadow: the game's own places, with their boss fog walls up and no monsters. Or **Here**: where the host stands |
| Fair start | everyone a Soul at the top of the game: every skill node on (the game's own `ActivateAllNodes`), 1360 health, 160 attack, 640 Phantom Edge energy, held there all match; every weapon in the match at level 30; 3 drinks of the same gourd for the whole match |
| Damage | every blow at half the game's own (`DAMAGE` in `arenas.lua`): at the top of the game a Sanguine blow took 499 of 1360 on the bench, three to fall; at half, about six. A parry costs the attacker 60 posture. Each player's own `PvPDamage` and `PvPParryPosture` count only in PvPvE: in a match they'd let a player take less |
| Loadout | a preset of your own, kept between matches (`pvp_preset.txt`): two weapons and two Phantom Edges, any of the game's 20 and 20, owned or not |
| Start | the host picks the mode, the clock and the arena on the F6 page; everyone picks a team and presses READY; the host presses START |
| Countdown | 三 二 一 in brush strokes, then 斗: nobody moves till then |
| Down | health can't go below 1: at 1 you fall, out of the round. So does a fall from the arena, and a rest at a bell. A team with nobody up loses the round. Down, the camera follows a teammate still up, or else a foe; a team that lost the match watches the winners come for them |
| The end | the winners get about 5 s to finish a fallen foe: F near them plays a boss's move (below). Then the winners get the golden VICTORY, the losers the game's death card, and everyone goes back where they were, with what they had |
| Leaving | F6, then LEAVE twice. A player not heard from for 8 s ends the match for everyone |

## The finishing move

A winner who presses F within 9 m of a fallen foe in the finishing window (7 s, F taken till 1.5 s before its end, so the move reaches every screen in time) steps in before the body, facing it, and plays one of
the bosses' moves the game keeps for the player's own body (`FINISHERS` in `arenas.lua`): the club bosses' leap and two-handed
slam, or the archer Du Yan's point-blank shot. As it lands the game slows to 0.3 for 0.6 s and the body is thrown. Every player
sees it: the winner's world plays it on the winner, every other world on the winner's figure (`AR fin` says which move and where
they stood). The result waits until the move is over.

Known, not fixed: after the step-in and the leap, thin red lines can hang from the winner back to where they stood, for good.
They're simulated cords left behind: the Sanguine's tassel (hiding the blade took one away) and one on the body. The body's
cloth reset (`ForceNextUpdateTeleportAndReset`) didn't clear them, and `ResetAnimInstanceDynamics` on the body's parts hung
the game thread, so don't call that. The Dread Axe's release left the same lines, which first looked like its chains.

## Who decides what

The host runs the match: the rounds, the score, the clock and the result. Each player's own game decides the hits that land on
them, as in PvPvE: the others' figures in your world swing for real, and the game's own combat judges it (block, deflect,
perfect dodge, posture). So nobody gets hit by a swing they saw miss.

A player who is down says so (`AR down`); the host counts.

## On screen

Each foe is on the game's own boss health bar (`PBZHUDLayout:RegisterBossHPBar`), white health over gold posture, at the
top, as a boss fight shows its boss. Its name text (`BossName`, the game's own font) says who, and over the first foe's bar the
score (YOU 1 – 0) and the round's clock; its health is moved with the bar's own `ForSeq_UpdateHealth`. A player's figure on
a boss bar gets no `Character` (the bench), so pbz.lua knows each bar by the widget the HUD made for it, and keeps it out of
the mod's own boss lists (`bosses`, `bossActors`), so nothing that walks the bosses sees a player. The countdown and banners are
ink-brush pictures of ours; the death card and the golden VICTORY are the game's own screens.

## On the wire

One sure-lane event kind, `AR <what> ...`, so older versions ignore all of it. A match only starts when every player runs the
same version (the F6 page says who doesn't).

| Event | From | Meaning |
|---|---|---|
| `AR lobby <mode> <timer> <place> <slot>:<team>:<ready>:<arenas> ...` | host | the lobby as it stands, sent on any change |
| `AR pick <team> <ready> <arenas> <version> <loadout>` | player | this player's team, ready, the arenas their save opens, their version and loadout |
| `AR start <id> <mode> <timer> <place> <x> <y> <z> <yaw> <map> <slot>:<team>:<spot>:<loadout> ...` | host | the match begins (the middle is the host's spot, for Here) |
| `AR here <id> there\|home` | player | in the arena and set up; back home |
| `AR count <id> <round>` | host | a round's countdown starts |
| `AR down <id> <round> <by>` | player | down this round (`by`: who struck last, or 0) |
| `AR round <id> <round> <winner> <crimson> <azure>` | host | a round's result and the score (`winner` 0 = draw) |
| `AR end <id> <winner> <crimson> <azure>` | host | the match's result; the finishing window opens |
| `AR fin <id> <victim> <move> <x> <y> <z> <yaw>` | winner | a finishing move on a fallen player, and where the winner stands for it |
| `AR home <id>` | host | everyone goes back |
| `AR quit <id> <why>` | anyone | leaves, or the host calls it off |

Health goes with the position (the state sample), which is how the bars move at 125 a second.

## The network during a match

There are no enemies, so none of their traffic goes: no enemy lines, no `A`/`D`/`K`/`N`, twins, scaling, story, flow, loot,
bells, chests, blockers or map fog. `net.arena` turns all of that off (`net.ARENA_SKIPS` in `coop.lua`). What's left is the
players: positions (125 a second, as before), the moves they start, hit reactions, weapons and the match's own events.

Moves start sooner: outside a match a player's new move was noticed 10 times a second, so up to 100 ms after it began; in a
match every frame. That's most of a swing's lead on a parry.

A perfect dodge's slow motion slows only the dodger's game: in a match the game's time runs at 1 for everyone, every frame
(from GitHub issue #13). The finishing move's slow beat is the one exception.

## Fair play, and putting it all back

Before anything changes, the game's own save veto goes up (`EnterSaveVeto`, reasons 0 and 2: the bench showed reason 0 stops the
quiet autosave and the manual save, 2 stops bells, trips and triggers). Nothing about a match is ever saved. Then each player's
world notes what it will change, in memory and in `pvp_restore.txt` next to the mod (so a crash mid-match is put right on the next
start):

- where they stood (map and place);
- their weapons: the game's own `PushEquippedWeapons` puts the loadout on and `PopEquippedWeapons` takes it off; a weapon the
  player didn't own goes back with `DisposeWeapon`;
- every weapon's level that the match raised (`ResetWeaponToLevel` puts it back: no dust, nothing given);
- their gourd: which one, how many drinks;
- their skill nodes (`DeactivateAllNodes`, then their own again).

Weapon levels: a blow's damage in the defender's world goes by the defender's own level of the attacker's weapon. On the bench a
guest's Sanguine blow took 128 from the host at the host's Sanguine level 1, 256 at level 11. So in every world every weapon
anyone in the match fights with goes to level 30 (lent first if not owned), and the loadouts travel with the start so every
world knows them. Raised with the game's own `UpgradeWeapon` and put back with `ResetWeaponToLevel` (both only set the level:
no dust, nothing in the bag). Tried and dropped: `ResetWeaponToLevel` won't raise (asked for 30, the weapons stayed at 1), and
the bag's own level field written by hand (`MainWeaponInfos`' `WeaponLevel`, `ShaqiWeaponInfos`' `ShaChiWeaponLevel`) reads
back right, but a match after either crashed the bench host within a second, a call to an empty function pointer.

Known: the upgrade to 30 gives a player who doesn't have it the game's "Skill Over Strength" achievement (a Phantom Edge to
level 30), as it did the bench player.

## Arenas

| Arena | Map | Middle | Opens when |
|---|---|---|---|
| YuCong, the Crimson Forest | PBZ_Fujizhilin_WP | 17300, 153100 | YuCong is beaten |
| Hua Qianxiao's stage | PBZ_Fujizhilin_WP | -132300, 170800 | Hua Qianxiao is beaten |
| The Gold-Masked One's gorge | PBZ_Xigu_WP | -20900, 291300 | the Gold-Masked One is beaten |
| Mu Xiaokui's meadow | PBZ_Zhengdaodaying_WP | -68100, 77200 | Mu Xiaokui is beaten |

A boss arena is offered only when every player's own save has its boss beaten (the game's `SpawnerSaveData`): going there before
plays the boss's story (seen on the bench: Mu Xiaokui's scene, the forest's). Any enemy near the arena is moved aside for the match
and put back after; the boss's fog walls go up. Spots: three a side, 8 m from the middle, facing each other.

Getting there (and home): a spot within 50 m on the same map is a hop; anything further is the game's own trip, whose loading
screen sets the player down once the ground is in. A 280 m hop on the bench landed before the gorge's floor had loaded: the host
fell 110 m and lost round 1.

## Files

- `arena.lua`: the match (the host's side, each player's own side, the events, putting things back).
- `arenas.lua`: the arenas, the weapon lists, the stats, the finishing moves.
- `arenaui.lua`: the countdown, banners, each foe on the game's own boss bar (its name text says who, the score and the
  clock: the user wants the game's own bar design, so ours went), and the game's own death card. Teammates get no bar: the
  game's player bar only follows its own player.
- `pvppanel.lua`: the F6 page (lobby and loadout).
- `pvp.lua`: the fight itself, for PvPvE and the arena: hostile figures, parries, teams.
- `art/make_pvp_art.py`: every picture above.
- `tools/netlab/sim/pvp.lua`: in the simulator, a whole duel with the finishing move, a guest leaving a match, and three
  players in two teams, a fallen one watching their teammate (`python -I tools/netlab/luasim.py pvp`; `all.ps1` runs it).
