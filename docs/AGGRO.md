# Who an enemy goes for

A player's report on 1.6.4: "Co-op aggro is very dumb. Switching the lock every 15 s is worse than deciding by distance
and by who deals the most damage." And the owner's warning from earlier: a boss that switched quickly between players
walked in a weird way, turning back and forth. So the rule has to go by distance and damage, and never flip.

## The game's own rule, and the old one

The game's `AIScript_TargetSelector` takes the nearest player on the enemy's hatred list. It looks again on a hit, at the
end of its behaviour tree, on a state change and on `Ability.Action`, once `SwitchTargetCooldown` (1.5 s) has passed, or at
once if it can't sense its target. With two players near an enemy the nearest changes all the time, and so did its target.

From 1.5.0 to 1.6.4 an enemy near two players held one for 15 s (its cooldown made 15 s), then turned to whoever had hit it
last. Every turn came by the clock: in the sim, 4 a minute in every fight tried, with 2, 4 or 6 players, and in a party
a third of the fight on a player who only chipped at it now and then. The game's own picker also had a say every 15 s, and took
the nearest: an enemy on the player dealing the damage turned to a nearer one, then back.

## The rule now

The host, once a second, for each enemy near two players or more (within 25 m), the same code for 2, 4 and 6 players
(`game.steerTarget` in pbz.lua):

- **Near**: 1 within 3 m, 0 at 25 m, in a line between.
- **Damage**: the health that player took from it lately, counting half after 12 s. 1 for whoever took the most, the others
  in proportion. While nobody has taken 3% of its health, everyone's counts that much less, so a first chip isn't "the
  most damage".
- **Score** = near + damage. It goes for the highest, and turns from its target only when all of these hold:
  - someone else is 0.5 ahead: at the same distance, twice the damage; on distance alone, about 11 m nearer;
  - it has held its target 6 s (a boss 10 s);
  - it isn't in one of its moves: it waits up to 2 s for one to end, so no swing is turned halfway.
- Someone who goes past 25 m isn't held to: it turns to the best of those near at once. A partner who's down, in a scene,
  on another map or gone is already off every list (`game.ghostInFight`).
- While steered its own picker is held off: its wait is 15 s and its last change is put at now every turn, so it never
  turns to the nearest by itself. Near one player or none, it's the game's own again: its wait goes back. A rest or sync
  off gives every wait back.
- The turn is the game's own, as before: the others near come off its list for that moment, its picker looks, they go
  back on.

Damage, on the host: a guest's is what their `D` took from the host's enemy (a floor or a kill takes less than was sent). The
host's own shows only as health gone: what the enemy lost between two looks, less what guests' hits took, if the host
started a move in the last 2 s. Health and posture are separate; only health counts.

## Why these numbers

The hardest case is the usual one: whoever it's after is busy dodging and only chips at it, while the others hit freely.
Any rule by damage turns then, and turns back once the new target is the one dodging. How often depends on how long damage
is remembered and how far ahead the next player must be. In the sim (hits of 0.4% of its health, the target dealing 30% of
what the others do):

| Remembered (half after) | Lead needed | Its target chips, 2 players | Its target chips, 4 players | 4 taking turns of 3 s | 6 taking turns of 3 s | Takeover when the target keeps chipping |
|---|---|---|---|---|---|---|
| 8 s | 0.3 | 8.0 a minute | 8.7 | 9.0 | 9.0 | 11 s |
| 10 s | 0.5 | 3.3 | 4.0 | 1.0 | 5.0 | 17 s |
| 12 s | 0.5 | 3.3 | 4.0 | 0 | 4.0 | 19 s |
| 15 s | 0.4 | 4.0 | 4.0 | 1.0 | 4.0 | 17 s |
| 20 s | 0.3 | 4.7 | 5.3 | 1.0 | 6.0 | 15 s |

12 s and 0.5: in the hardest case the time between turns settles at 20-25 s, each with a reason. A clear leader (one player
dealing the damage, the others not) still gets it as soon as the hold allows, and one who walks off loses it at once.

## Measured

The sim, the mod's own scripts on stand-ins for the game, the host's enemy noticing the host as the game's do: changes of
target in a minute, 1.6.4's rule (58cdfc7) then this one. Each fight starts with everyone 2.5 m from it, hits of 0.4% of
its health, healed every 10 s so it lives.

| Fight | 2 players | 4 players | 6 players |
|---|---|---|---|
| All hitting the same, going round it | 4 -> 0 | 4 -> 0 | 4 -> 0 |
| Taking turns of 3 s, the same damage | 4 -> 0 | 4 -> 0 | 4 -> 4 |
| Its target only chips, the others hit freely (90 s) | 4.0 -> 3.3 | 4.0 -> 4.0 | 4.0 -> 4.0 |
| Player 2 deals the damage, the last player chips | - | 4 -> 1 | 4 -> 1 |
| A boss, its target only chipping (90 s) | 4.0 -> 3.3 | 4.0 -> 3.3 | |

- Where the count stays near 4, the turns are no longer every 15 s by the clock: they go to whoever is hitting it, and the
  time between them grows to 20-22 s as the fight goes on (7, 14, 21, 22, 20 s with 4 players). Six players taking turns
  of 3 s each hit it only one sixth of the time, so whoever hits now has done the most lately: it follows them, 9-12 s
  apart.
- On the player dealing the damage: 59 s of 60 with 4 or 6 players (1.6.4: 32 s, and 21 s on the one who only chipped).
- The guest dealing the damage from 6 m, the host 1 m off and only chipping: 1 turn, to the guest, then none (1.6.4: 4, the
  game's own picker taking the nearest every 15 s and the old rule turning it back).
- Its target walks off to 22 m, nobody hitting: it turns to the one beside it in 0.5 s (1.6.4: 11.6 s, when its own picker
  looked again).
- The host hits it 10 s and stops, the guest goes on: it turns to the guest 11 s later; with the host chipping on, 19 s.

## Not checked

Only in the sim so far. Not on the bench copies or between real players: the walk of an enemy that turns once in 20 s, a
real boss's moves against the 2 s wait, and whether the game's picker ever looks again by itself while its last change is
kept at now (if it does, the rule still turns it back, but no sooner than the hold).
