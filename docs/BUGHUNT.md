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

## 1.6.0

25. Local: the swap for player 2's bell had one limit, 120 s. A ring that never came left both pads on each other's bodies for two minutes, and a menu open longer was swapped away from under them, which left player 1 with no controls.
26. Local: the pin that keeps player 1 still while player 2 opens a chest took player 1's own running for the game's walk, and yanked them back four times in a second and a half.
27. Local: player 2 could use something once until player 1 died (levers, doors, every switch but a pile), and addresses used before a load blocked new chests that came back on them. Only piles are remembered now, and it's forgotten on a map change.

## 1.6.0, the bonus: player 2 does what player 1 does

The challenge's last part: local co-op with player 2 able to do everything player 1 can, the same animations, buttons and effects, with the inventory shared. These are the gaps found on the way, each of them a bug of its own. "Real" here is one copy in Role = Local, two bodies on the split screen, with the second pad's presses injected into the game's input, so the buttons below were not pressed on a real second pad.

28. Player 2 had a flat bar of the mod's own for a HUD. The game's HUD binds to player 0's body as it's made, so a second one made in the moment player 1's controller points at player 2's body, with no possession, is all player 2's: health and ShaChi bars, gourd, weapons, buffs. Sim: `localScreen`. Real: seen in player 2's half after a real elite hit, the red low-health bar included, player 1's 9 input sets back afterwards, the Phantom Edge icon on it after player 1 equipped one.
29. Player 2's button prompt was a picture of the mod's. It's now the game's own `W_InteractionUI_C`, on a WidgetComponent of player 2's owned by their local player, set down on the thing: the game's animation in and out, held to its spot by the engine. The widget looks its button up by player 1's input, so the picture is written in by hand and its invalidation box told. Sim: `localScreen`. With something near but out of reach it's the game's small ring, opening into the button, as player 1 has. Real: seen at a bell, a chest, a pile and a person, a Circle in player 2's half with player 1 on keyboard, and fading out and back three times.
30. Circle is also the execution button, and player 2's press looked around them with no rule but distance: it could ring a bell behind them in a fight, and a fog door or a music trigger counted as something to use. The game's own `CanTriggerInteract` and `IsPlayerFaceToActor`, asked of player 2's own interact component, decide now. Sim: `localScreen`.
31. Player 2's own interact search played prompts on the things themselves, which are player 1's: player 2 walking away from a bell shrank player 1's prompt to a dot. Its timer is paused now, and the rope swing and wall run still work through the component. Sim: `localScreen`. Real: player 1's prompt stays when player 2 walks off and comes back, seen on screen.
32. A drink by player 2 played on their body, but the heal, the green glow and any buff landed on player 1, and the heal was moved over by hand afterwards. For the one call that applies a medicine, player 1's controller now points at player 2's body, so it's the game's own step that heals them. Sim: `localScreen`. Real: gourd 500 to 976 on player 2 with the glow on them and their HUD flashing, player 1 left at 700, the shared gourd kept; the top item too; player 1's own drink stayed player 1's.
33. Player 2's charges were out of reach once player 1 had emptied the shared gourd: the game asks the shared count, so the press did nothing. A charge is lent to it and the press made again, and taken back if it wasn't drunk. Sim: `localScreen`.
34. A drink by player 1 within 4 s of one by player 2 was given back: the refund to the shared gourd was repeated by a fixed count. Sim: `localScreen`.
35. The D-pad's top item refunded the gourd and spent a charge of player 2's. Sim: `localScreen`.
36. A chest that player 1's component refused (still busy with the last one) was opened anyway, with nothing in it. Sim: `localPlay`.
37. Player 2 pressing Circle at a person with player 1 far off had the game walk player 1 all the way there, on their own, and a person behind player 2 counted too. A talk now needs player 2 looking at them, and sets player 1 down beside player 2, the talk filling both screens anyway. Sim: `localScreen`.
38. After player 2's rest player 1 kept the low health look: health written by hand doesn't clear it, so player 1 goes through the bell's own step.
39. What player 2 earned just before going down never reached player 1, and the floor under their health went to 0 for up to a second after a scene or a pad's return, so a hit in that gap killed for real and took player 1 to the bell. Sim: `localPlay`.
40. A third pad could claim a player, and the panel offered it, though the routing only moves one of two. Sim: `localPlay`.
41. F4 opened over the game's own menus, and closing it unpaused the game behind them. Sim: `localPlay`.
42. Player 2 came in during a scene or under a menu, standing in the shot with their pad live. Sim: `localPlay`.
43. Player 2's boss bar was a flat one of the mod's with no name. It's the game's `WB_BossHPBar` now, made in their half and started with `Init(boss)`: told of a boss, a second HUD only adds a bar to player 1's half. Sim: `localScreen`. Real: seen with the elite, name and all, at the top of player 2's half.
44. Player 2's execution points were drawn in player 1's half: they're WidgetComponents of their own with no owner, which means the first player. They're owned now, with the picture written in as a prompt's is. Sim: `localScreen`. Real: seen on a thug near death, a Circle in player 2's half with player 1 on keyboard.
45. Player 2 had no arrow to an enemy after them out of view. The HUD's own `ShowEnemyIndicator`, fed from the hatred lists, gives them one. Sim: `localScreen`. Real: an arrow seen in player 2's half with the elite behind them.
46. Going down showed nothing but a body falling, and coming back was a Soul appearing on its feet. The game's death card now shows in player 2's half alone, made of its own pictures, and `GA_PlayerRespawn` has them get up off the ground. The card's widget, `W_PlayerDead`, can't be used: it goes on by itself to send "the player" back to the bell, and took player 1 487 m away in testing. Sim: `localScreen`. Real: the card's own pictures in player 2's half with player 1 not moved, and the rise, seen.
47. Player 2 could ring a bell in a boss fight, where the game turns player 1's prompt red and won't have it. Sim: `localScreen`.
48. The HUD was made through a real swap of the two bodies, which dropped player 1's input sets and could come in the middle of a fight, each time player 2 came back. It's a pointer now for the one call, as with a drink. Sim: `localScreen`.
49. After player 2's rest player 1's button did nothing at the bell: the input set a prompt adds went with the rest while the prompt stayed up. It's put back. Real: 8 sets after a rest before, 9 after.
50. Player 2 fell behind as the story went on: Attack 100 against 110 and ShaChi 400 against 440 from the fifth region, what the story adds going on player 1's Soul alone. Their base now takes player 1's numbers, with a buff of their own staying on top. Sim: `localScreen`. Real: seen by comparing all 223 attributes at each of the ten story stops.
51. Each time player 2 came back, or got a new Soul after a rest, player 1 lost their controls for over 4 s: a controller taking a body clears player 0's control sets, 8 down to 1, and the game only put them back on its own 4.5 s later. The watch that gives them back after a swap now runs for any new Soul. Sim: `localScreen`. Real: found by watching the count at 20 Hz through a return.
52. A map change in the middle of player 2's bell swap left the swap on, and the way out then possessed bodies the load had taken away. The load ends the swap now, and that way out only touches what's still there.
53. A Soul back from down showed the dead Soul's HUD for 3 s, until its own was made. The HUD goes with the Soul.
54. After a rest, player 2's bar and low health look stayed as they were until the next hit: their health was written by hand. They go through the game's recovery now, and the bar is told.
55. In the 10-a-second loop, any error drawing something stopped the check that ends a swap, which could leave both pads on each other's bodies. That check goes first now.
56. A charge lent to the dry gourd and not drunk was taken back by setting the gourd to 0, which wiped real charges if a rest had come in between. Only the lent one is taken back now.
57. The death card stayed up over a menu or a scene that opened while player 2 was down. It hides with the rest of their screen.
58. A chest opened by player 2 was done to player 1. It went through player 1's interact component, so the game walked player 1 towards it, made them sheathe a drawn sword, and held them in the opening for 3 s wherever they stood, mid-fight if it came to that. Player 2's own component, with "the player" pointed at their body for the one call, makes the whole of it theirs. Sim: `localPlay`. Real: sampled 20 times a second at five chests, with both swords out: player 1 swinging and walking throughout, sword still drawn, no montage of theirs.
59. Their half of the screen was player 1's to lose as well: the chest's close-up cut to it for 4 s, while player 2 stood by a lid opening on its own. The shot is handed over as it starts, and player 1 gets their view back in the same moment: the sequence's cuts can't be turned off in time. Sim: `localPlay`. Real: seen in pictures through the whole opening, player 1's half never left them.
60. Player 2 popped onto the spot in front of a chest and played nothing. They walk up at the game's own pace now (160 cm/s, as measured on player 1), put a drawn weapon away first, and the opening is played on them. Sim: `localPlay`. Real: sampled.
61. A door's sequence takes "the player" when the walk ends, a moment after the press: player 1 was seen pushing at the air 5 m away. Pointed at player 2 for that call too. It's left out at a chest, where it threw player 2 five metres as the opening began. Sim: `localPlay`. Real: the montage on player 2, nothing on player 1.
62. The Ultimate gauge went with the Soul: it's what a combat art spends, player 2's own hits fill it (26 from eight heavy hits), and each rest, return from down or map change emptied it, where player 1's stays through a rest (measured). It goes over to each new Soul. Sim: `localScreen`.
63. The look around for player 2's prompt looked through the game's whole object list six times, all in one frame, a few times a second. What's near of each kind is remembered as plain numbers now, and a kind is only looked for when it can be in reach. Lookups fell by a third, and the slowest frames with them: p99 from about 30 ms to 27 on the bench.
64. Once a second eight more such lookups landed in one frame together. They go one after another now, and the two that only guard against a player being added run every 5 s.
65. The bell menu was looked for ten times a second, with nothing there nearly all of the time. Five now. The parts of a Soul are asked of the Soul.
66. Player 2's rumble went to player 1. The game plays it on the first controller whoever it's for: with a heavy blade in a fight, all 49 of it landed on player 1's pad and none on player 2's. It goes by who's in the middle of something now. Sim: `localPlay`. Real: 17 of 17 on player 2's controller, through virtual pads.
67. A far blow of player 2's shook player 1's camera: the game's world shake reaches every controller, and all 54 did. Over 15 m, with player 2 alone at it, it's turned down to nothing for player 1. Sim: `localPlay`.
68. At a gap blocker player 2's prompt sat on their own Soul. It's on the point they'll reach now.
