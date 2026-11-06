# Who an enemy goes for

A player's report on 1.6.3: "Co-op aggro is very dumb. Switching the lock every 15 s is worse than deciding by distance
and by who deals the most damage." And the owner's warning from earlier: a boss that switched quickly between players
walked in a weird way, turning back and forth. So the rule has to go by distance and damage, and never flip.

## The game's own rule, and the old one

The game's `AIScript_TargetSelector` takes the nearest player on the enemy's hatred list. It looks again on a hit, at the
end of its behaviour tree, on a state change and on `Ability.Action`, once `SwitchTargetCooldown` (1.5 s) has passed, or at
once if it can't sense its target. With two players near an enemy the nearest changes all the time, and so did its target.

From 1.5.0 to 1.6.3 an enemy near two players held one for 15 s (its cooldown made 15 s), then turned to whoever had hit it
last. Every turn came by the clock: in the sim, 4 a minute in every fight tried, with 2, 4 or 6 players, and in a party
a third of the fight on a player who only chipped at it now and then. The game's own picker also had a say every 15 s, and took
the nearest: an enemy on the player dealing the damage turned to a nearer one, then back.

## The rule now

The host, once a second, for each enemy near two players or more (within 25 m), the same code for 2, 4 and 6 players
(`game.steerTarget` in pbz.lua):

- **Near**: 1 within 3 m, 0 at 25 m, in a line between.
- **Damage**: the health that player took from it lately, counting half after 12 s. 1 for whoever took the most, the others
  in proportion. While nobody has taken two and a half of the biggest single hit on it lately, everyone's counts that much
  less, so a first hit isn't "the most damage", and two or three are, whatever its health. (A floor of 3% of its health
  was 10,000 points on the bench's boss: a guest hitting it for a minute never counted, and the owner saw it "totally
  ignores the one that is hitting him".)
- **Healing**: 1 more for 4 s from the start of a drink from the gourd, as much as having done the most damage: a drink
  draws its eye (the owner's choice, from a design a friend sent: "punish healing"). It still turns only by the rules
  below, so a drink right after a turn does nothing, and drinking can't spin it. A guest's drink reaches the host as
  `HEAL` (quick lane); an older host has no handler for it and leaves it.
- **Score** = near + damage + healing. It goes for the highest, and turns from its target only when all of these hold:
  - someone else is 0.5 ahead: at the same distance, twice the damage; on distance alone, about 11 m nearer;
  - it has held its target 6 s (a boss 10 s);
  - it isn't in one of its moves: it waits up to 2 s for one to end, so no swing is turned halfway.
- Someone who goes past 25 m isn't held to: it turns to the best of those near at once. A partner who's down, in a scene,
  on another map or gone is already off every list (`game.ghostInFight`).
- While steered its own picker is held off: its wait is 15 s and its last change is put at now every turn, so it never
  turns to the nearest by itself. Near one player or none, it's the game's own again: its wait goes back. A rest or sync
  off gives every wait back. (Not a longer wait: with a day's, a real boss turned to the guest and started no attack in
  the next minute, where 1.6.3 with the same swings started 24.)
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
target in a minute, 1.6.3's rule (58cdfc7) then this one. Each fight starts with everyone 2.5 m from it, hits of 0.4% of
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
- On the player dealing the damage: 59 s of 60 with 4 or 6 players (1.6.3: 32 s, and 21 s on the one who only chipped).
- The guest dealing the damage from 6 m, the host 1 m off and only chipping: 1 turn, to the guest, then none (1.6.3: 4, the
  game's own picker taking the nearest every 15 s and the old rule turning it back).
- Its target walks off to 22 m, nobody hitting: it turns to the one beside it in 0.5 s (1.6.3: 11.6 s, when its own picker
  looked again).
- The host hits it 10 s and stops, the guest goes on: it turns to the guest 11 s later; with the host chipping on, 19 s.

## In the real game

Two copies on the bench, host and guest, by the forest's last boss (YuCong, 333,180 health with co-op's 150%): the host 3 m
on one side, the guest 4.5 m on the other, a minute each, both players' health kept up. The guest's swings are real ones
(`REAL.fight`), each from 1.7 m after a jump to its side. Changes of target counted from its blackboard four times a
second (`AGGRO.watch`), what it does ten times a second on the host's PC (attacking, flinching, running, standing), its
turns on each PC (`TWITCH.sample`).

| Fight | 1.6.3 (58cdfc7) | Now |
|---|---|---|
| Nobody hitting | 0 changes, 28 attacks started, longest with none 1.8 s | 0 changes, 24 attacks, 4.6 s |
| The guest hitting | 3 changes (to the guest, back, to the guest), 24 attacks, 5.1 s | 1 change, to the guest 8 s in (its 10 s hold), 21 attacks, 7.0 s |
| Both hitting | 3 changes, 22 attacks, 5.1 s | 1 change, 23 attacks, 2.7 s |

- Turns back and forth on the host's PC (over 60 s): 9, 2, 6 then 6, 3, 8. On the guest's copy 4-37 in every run, either
  build: that copy follows the host's lines, and the guest jumped beside it before every swing.
- The first build, with the 3% floor, never turned to the guest at all in two minutes of the guest hitting: what the owner
  saw. It also stood more, at times (16% of a minute against 7%), but its attacks started were 25, 24, 23 against 1.6.3's
  28, 24, 22.
- A turn to the guest takes the host off the boss's list for that moment, and its bar goes down and up in the same frame
  ("Boss fight over", "Boss fight", 6 ms apart, nothing of it on the guest's PC): 1.6.3's turns do the same.
- A boss whose target stands inside its reach (the guest's figure 1 m off, not moving) stood there without attacking, held
  or not; at 4.5 m it attacked again. Real players move, the bench's guest didn't.

## Not checked

Real players on two PCs, regular enemies (the bench save had only this boss loaded), and four or six real players: those
are the sim's.
