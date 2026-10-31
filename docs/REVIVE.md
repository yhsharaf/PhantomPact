# Revive (Nightreign's rules, Phantom Blade's look)

Agreed with the project owner on 2026-10-30, from appdoze's design (issue #8) and research into Nightreign. `Revive = Off`
in `PhantomPact.ini` by default until two real PCs have tested it. Nothing here writes to a save.

## The gauge

| Down | Bars | Revive points | Refill | Wylder's time | Time here |
|---|---|---|---|---|---|
| 1st | 1 | 40 | 2 per second | 1.9 s | about 2 s |
| 2nd | 2 | 90 | 9 per second | 4.8 s | about 5 s |
| 3rd and later | 3 | 240 | 40 per second | 11.4 s | about 11.5 s |

- Three bars at most. The bars look equal on screen, though they aren't, as in Nightreign.
- Hits drain the gauge smoothly. At zero the player gets up with 50% of their health.
- With no hit for 3.5 s, it refills toward full. It never adds a bar.
- One step of the down count goes away after 3 minutes alive, and all of it at a bell.

## Hit values

Wylder's one-handed greatsword does 20 points a hit at 1.05 attacks a second (community test, 21 hits in 20 s): 21
points a second. This game's sword (`AM_Hun_Tang`) was measured at 1.5 attacks a second, 1.43 times faster, so a flat 20
would make revives 30% too quick. A hit is worth 21 points for each second since the last counted hit, at most 20
(Wylder's 0.95 s): the combo's five hits come to about 7, 13, 16, 15 and 19. Weapons nobody has measured adjust by
themselves, and mashing can't beat it.

A swing counts when it starts within 3.5 m of the downed player, whichever way you're facing, and turns you to face them, a soft lock like the game's own on enemies: the combo lunges about 2 m
a hit and passes through them, so without it the second or third swing runs off past them.

## Timer

- 15 s, paused while being hit (counted as within 3.5 s of the last hit).
- No timer while a boss bar is up, whoever landed the hit. The gauge still refills.
- When it runs out: a normal death, with the usual respawn.

## No revive: a normal death at once

Solo, the partner gone or silent, a different map, PvP on, either player in a cutscene, the partner already down, and
falls (the 1 health floor catches them too, so a hit taken while falling counts as a fall). If both players are down,
both die. If the partner goes silent while you're down, you die.

## Not like Nightreign yet

- No crawling and no lying pose. Forcing one crashed the game four times in appdoze's tests, so a downed player freezes
  on their feet for now.
- Hit values are the same for every attack type: there's no table for this game's heavy attacks.

## Sources

[Near-Death Gauge, Eldenpedia](https://eldenring.wiki.gg/wiki/Near-Death_Gauge),
[required damage differs by 6x](https://note.com/goat_mechanical/n/n04125f89ff00?hl=en).
