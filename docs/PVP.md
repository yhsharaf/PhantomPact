# PvP (1.7.0)

Two ways to fight each other:

- **PvPvE** (F5 > MORE): the old PvP switch, renamed. Partners can hurt each other in the open world, enemies and all. Death
  decides, as before. The ini key stays `PvP` so old ini files keep working.
- **PvP** (F6): a match in one of four boss arenas, with nothing else in it. This file is about this one.

## What a match is

| | |
|---|---|
| Players | 2 to 6, everyone linked. 2 players: a duel. More: two teams (Crimson, Azure), each player picks one |
| Modes | **Duel**: best of three rounds, health refilled each round. **Death**: one life, last team standing |
| Timer | Off, 60, 90 or 120 s a round. At zero the team with more health left (as a share) wins the round; equal is a draw |
| Arenas | YuCong's Crimson Forest, Hua Qianxiao's grove, the Gold-Masked One's ruins (Xigu), Mu Xiaokui's yard (LuJiaCun): the game's own places, with their boss fog walls up and no monsters |
| Fair start | everyone: the same health, attack and posture; weapons as at level 30; no accessories; exactly 3 drinks from the same gourd (Hulu) for the whole match |
| Loadout | a preset of your own, kept between matches: two weapons and two Phantom Edge weapons, any in the game |
| Start | the host picks mode, timer and arena on the F6 page; everyone picks a team and presses READY; the host starts |
| Countdown | 3, 2, 1 in brush strokes (三 二 一), then 斗: nobody moves till then |
| End of a round | your health can't go below 1: at 1 you're down, out of the round. A team with nobody up loses it |
| End of the match | the winners can finish a fallen enemy within 6 s (F): a finishing move, the game's own execution. Winners get the golden screen, the fallen the game's death card. Then everyone goes back where they were, with what they had |
| Leaving | F6, then LEAVE twice. A player silent for 8 s ends the match for everyone |

## Who decides what

The host runs the match: the rounds, the score, the timer and the result. Each player's own game decides the hits that land on
them, as in PvPvE: the partner's figure in your world swings for real, and the game's own combat judges it (block, deflect,
perfect dodge, posture). So nobody gets hit by a swing they saw miss.

A player who is down says so (`AR down`); the host counts.

## On the wire

One sure-lane event kind, `AR <what> ...`, so older versions ignore all of it. A match only starts when every player runs the
same version (the lobby says who doesn't).

| Event | From | Meaning |
|---|---|---|
| `AR lobby <id> <mode> <timer> <arena> <slot>:<team>:<ready> ...` | host | the lobby as it stands, sent on any change |
| `AR pick <team> <ready>` | player | this player's team and ready |
| `AR start <id> <mode> <timer> <arena> <slot>:<team>:<spot> ...` | host | the match begins: everyone goes |
| `AR here <id> <phase>` | player | `there` (in the arena, set up), `home` (back) |
| `AR count <id> <round> <ms>` | host | the countdown starts, the fight in `ms` |
| `AR down <id> <round> <by>` | player | down this round (`by`: who struck last, or 0) |
| `AR round <id> <round> <winner> <crimson> <azure>` | host | a round's result and the score (`winner` 0 = draw) |
| `AR end <id> <winner> <crimson> <azure>` | host | the match's result; the finishing window opens |
| `AR fin <id> <victim> <move>` | player | a finishing move started on a fallen player |
| `AR home <id>` | host | everyone goes back |
| `AR quit <id> <reason>` | anyone | leaves, or the host calls it off |

Health goes with the position (the state sample), which is how the bars move at 125 a second.

## The network during a match

There are no enemies, so none of their traffic goes: no enemy lines, no `A`/`D`/`K`/`N`, twins, scaling, story, flow, loot,
bells, chests, blockers or map fog. `net.arena` turns all of that off. What's left is the players: positions (125 a second, as
before), the moves they start, hit reactions, weapons and the match's own events.

Moves start sooner: outside a match a player's new move was noticed 10 times a second, so up to 100 ms after it began; in a
match every frame. That's most of a swing's lead on a parry.

A perfect dodge's slow motion slows only the dodger's game: in a match the game's time runs at 1 for everyone, every frame
(from GitHub issue #13).

## Fair play, and putting it all back

Before anything changes, the game's own save veto goes up (`EnterSaveVeto`, reasons 0 and 2: the bench showed reason 0 stops the
quiet autosave and 2 stops bells, trips and triggers). Nothing about a match is ever saved. Then each player's world notes what it
will change, in memory and in `pvp_restore.txt` next to the mod (so a crash mid-match is put right on the next start):

- where they stood (map and place), their health;
- their weapons: the game's own `PushEquippedWeapons` puts the preset on and `PopEquippedWeapons` takes it off; a weapon the
  player didn't own goes back with `DisposeWeapon`;
- their gourd: which one, how many drinks;
- the attributes a match sets.

Weapons as at level 30: a level-30 weapon hits 3.9 times as hard as a level-1 one (`GetMainWeaponLevelData`), so a player's
levels can't count. Damage you take is worked out in your world, from your partner's figure: its weapon there is put to the same
strength for everyone.

## Arenas

| Arena | Map | Centre | Walls |
|---|---|---|---|
| YuCong, the Crimson Forest | PBZ_Fujizhilin_WP | 17200, 153900 | two, at 15879, 155671 |
| Hua Qianxiao | PBZ_Fujizhilin_WP | -132100, 170700 | two |
| The Gold-Masked One | PBZ_Xigu_WP | -20700, 291400 | two |
| Mu Xiaokui | PBZ_Zhengdaodaying_WP | -68000, 77400 | one |

(Coordinates from the boss-wall survey on the bench, `bench/bosswalls.ps1`; spawn spots are set out round each centre.)

A boss still alive in a player's save is moved aside for the match and put back after. Every enemy near the arena is too.

## Files

- `arena.lua`: the match (host's state machine, each player's own side, the events).
- `arenaui.lua`: the countdown, banners, health bars, round marks and timer.
- `pvppanel.lua`: the F6 page (lobby and loadout).
- `arenas.lua`: the arenas and the weapon lists.
- `pvp.lua`: the fight itself, for PvPvE and the arena: hostile figures, parries, health shown.
