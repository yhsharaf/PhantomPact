# Bug hunt: 1.5.2 to 1.6.0

The user's challenge, 2026-11-02: three unique bugs make one commit, nine commits reach 1.6.0. Each line says what was wrong and how the fix was proven. "Sim" names a test in `tools/netlab/sim/four.lua` that fails on 1.5.1 and passes here (`python -I tools/netlab/luasim.py four <1.5.1 Scripts>` runs the same tests on the old scripts). "Real" is two copies of the game, or one in Role = Local.

## 1.5.2

1. A partner carrying a Scarlet Wraithblade crashed this game on arrival. `SetSlotWeapon` starts a weapon's passive skill, and on a ghost half a second old on a new map `GA_Hun_GuiTouBlade_Passive_C:K2_ActivateAbility` had no code bound yet: a call through null. A new ghost is now left alone for 6 s, and montages and weapon configs are looked up each time instead of kept, since a kept object can go with a map and its address become something else. Found by the story tour at stop 1, from the dump and the Lua stack. Sim: `afterATrip`. Real: the tour again, all 10 stops, no crash, no script error, 0 packet loss, with Wraithblade and Phantom Edge weapons on both copies.
2. A Phantom Edge skill showed the partner an empty-handed animation. The weapon has a slot of its own on the character, drawn only for the skill, and its mesh is folded to nothing until it plays a montage of its own. The ghost's weapons component now takes the weapon and the drawn state (`E`), and its mesh plays what the partner's plays (`Z`). Sim: `phantomEdge`. Real: the ghost took the Tiger Cannon when the host equipped it, drew it with the shot, played `AM_TigerCannon_Show` and put it away, seen on screen. All 24 weapons fired on the host with no crash on either copy; a bow hangs on the left hand and a gauntlet on the forearm, by the game's own component. Five skills show no weapon on the player either. Guest to host works the same.
3. A Scarlet Wraithblade's flowers, and everything else a weapon leaves in the world, showed on the player's own screen only: they're bullets, which abilities start, and a ghost runs none. `bullets.lua` reads the game's list of live bullets, with no hook, and the ghost fires the same data from the same spot. Sim: `shots`. Real: 6 flowers from a heavy attack came up on the guest's PC, the ghost their owner, both ways, seen on screen, and the cannon's shell and smoke, arrows and thrown knives with them. Fired right at a real elite, a copied shell and three flowers left its 12420 health and 2558 posture as they were.

## 1.5.3

4. A guest whose save is behind the host's was attacked by enemies the host killed on another day, unseen by the host. The guest now asks the host about an enemy of its own (`HAS`), and on `NOT` the copy steps aside, hidden and not killed, until the host moves on or goes to another map. Sim: `twoSaves`. Real: one true case hidden, six real enemies left alone, back when the host leaves.
5. A partner's boss fight on another map flew this player to that spot's numbers on this map, held them in the air and dropped them. `joinBossFight` used the partner's position without looking at which map it was on; the walk back after a boss had the same gap. Sim: `otherMaps`.
6. A host pulled into a guest's fight in an arena apart from the map was never brought back when the boss died: only a guest's `K` handler set the return. It's in `endBossFight` now, which all three kinds of kill go through, and the return goes to whoever the fight was with. Sim: `fightsAndWhoIsLeft`.

## 1.5.4

7. A player over a respawn was skipped by a partner's fight for good: the calm of 30 s dropped the pull with nothing to retry it, the fog walls closed in front of them, and if the partner died their respawn waited on a fight nobody could reach. This is the "left behind a fog wall" of the Yan Qiansui takes. The pull now waits for the calm, if the fight's still on. Sim: `fightsAndWhoIsLeft`.
8. With two players, a guest joining during a boss fight travelled before it heard of the fight, and landed in it with no bar. `F` only came every 5 s and the wait for it was for parties alone. Sim: `fightsAndWhoIsLeft`.
9. A guest watching a fight stayed frozen in the air for good if the host vanished: only the host's own word ended a watch. Sim: `fightsAndWhoIsLeft`.

## 1.5.5

10. A fight outlived whoever was in it. When its owner left, only the walls opened: the mirrored bars, `partnerBosses` and `pendingBosses` stayed, and those bars counted as a fight, so other players held each other's respawns for up to 15 minutes, and F3 said "not now". Leaving, a partner's sit and a partner gone now end those fights. Sim: `fightsAndWhoIsLeft`.
11. A host's death on one map refreshed the enemies and took down the boss bar of a guest fighting on another. Sim: `elsewhere`.
12. Every trip the host made counted as a new world: the guest's enemies refreshed, what it knew of the host's kills went, and the log said someone rested at a bell. Only a load from outside the world is a new one now. Sim: `elsewhere`.

## 1.5.6

13. Dust and a kill's loot that arrived while a player had no body (a respawn, a load) were lost for good, while gifts in the same moment waited. Sim: `noBodyYet`.
14. A partner's down state outlived them: a partner who crashed while down left the compass red and this player's revive floor off, and Leave while armed or down left the health floor, the input block and the save veto on, because the ticks that take those off stop with the sync. `revive.stop()` takes them off, and a kill told in an earlier session is forgotten with it. Sim: `whatsLeftOfAPartner`.
15. What a player did with co-op off was reported at the next link: dust earned alone went to the partner, and a pickup taken alone destroyed the partner's copy. Sim: `offAndBack`.

## 1.5.7

16. An enemy copy let go by a guest kept a 24-hour target lock: the ghost it was given stayed its target after the host dropped or the guest left, and it ignored the guest. Sim: `offAndBack`.
17. A marker on a map opened again stayed where the partner last was, after they left or changed map: closing the map told the code the marker was hidden, so it was never hidden. Sim: `whatsLeftOfAPartner`.
18. A tip was cut short by the timer of the tip before it, one widget and two timers. Sim: `offAndBack`.

## 1.5.8

19. Bell tips, and why the relay couldn't start, stayed English in Chinese. Sim: `offAndBack`.
20. A setting added to an ini with no line end at its end was glued to the last line: `Secret = hunter2FourPlayers = On` changed the password and lost the key. Sim: `offAndBack`.
21. Paste kept addresses Join then refused, and a Join that couldn't start while hosting said nothing.

## 1.5.9

22. PvP turned on in the panel skipped `PvPDamage` and `PvPParryPosture`, which only loaded with PvP on at the start, and never said the partner needs it too, while their moves stopped showing. With four players the row showed ON although it was refused.
23. A weapon a partner found opened the game's full-screen "equip it now?" on this player, with the game not paused for it: in a party, on three other screens. It comes with a tip now. Sim: `weaponsFound`. Real: 40 weapons shared in a row, no dialog, the tip each time.
24. A boss rose when the first partner joined mid-fight, though they only watch. Sim: `scaling`.
