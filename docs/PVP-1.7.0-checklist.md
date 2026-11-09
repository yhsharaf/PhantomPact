# 1.7.0 PvP: the goal, item by item

Each item of the 1.7.0 goal, where it's built, and what proves it: the simulator (`python -I tools/netlab/luasim.py pvp`,
`four`, `two`) and the bench (two game copies on one PC, `C:\PBZDev`, with relay_cli bots for players 3 to 6; the scripts are
in `tools/netlab/bench/pvp`). A trace of every item against the code and the evidence, with a critic over it, was run on
11-08; what it found open is fixed below or listed under "Still open". Branch `pvp-1.7.0`, from v1.6.6 (bf93706), with
1.6.7 and 1.6.8 merged in. The design itself: `docs/PVP.md`.

| # | The goal said | State |
|---|---|---|
| 1 | Rename the old PvP button to PvPvE (PvP with enemies) | Done, bench 11-08 |
| 2 | A separate F6 key for the new PvP | Done, bench |
| 3 | Presets: any weapon, skill or special skill, saved, loaded each match | Done (skills: all on for everyone, see 3); bench: see 3 |
| 4 | A countdown before the fight, a Phantom Blade Zero look | Done, bench |
| 5 | The four boss arenas, their own fog walls | Done, bench (all four, 11-07; a real win opens one, 11-09) |
| 6 | No monsters in a match; the network sends only what PvP needs | Done; sim and bench |
| 7 | Only 3 drinks, all from the same gourd | Done, bench 11-08 (a 4th, a skill node's, taken off 11-09) |
| 8 | Duel (3 rounds, the winner in gold, the loser's death) and Death mode | Done, bench |
| 9 | Everyone at the same level, max level, weapons too, "or anything else" | Done, bench 11-08 (talismans, Combat Art: see 9) |
| 10 | Teams for more than 2 players | Done; bench with 3 and 6 players (bots) |
| 11 | Ideas from issue #13 | Done (rounds, health floor, slow-motion hold) |
| 12 | An execution with a boss's own moves | Done, bench (all four arenas, F pressed for real) |
| 13 | Timer and no-timer modes | Done, bench 11-08 (TIME) |
| 14 | A polished UI, health bars shown perfectly | Done, bench 11-08 (lock-on 11-09) |
| 15 | Animations, swords, deflect, dodge, parry as in solo play | Done, bench (Phantom Edges on figures 11-08; your play, 11-09) |
| 16 | The network as efficient as it can be | Done; measured 11-08, see 16 |

## 1. PvPvE

The F5 > MORE tile reads PvPvE ("Fight your partner out in the world"); the ini key stays `PvP` so old files work
(`onlinepanel.lua` TILES, `art/make_online_panel.py`). Enemies stay; a death decides, as in 1.6.6 (`pvp.lua`).
- Bench 11-08 (`pvppve.ps1`): the tile clicked through the page's own click handler turned both players hostile (a guest
  follows the host's rules); six enemies within 90 m stayed, none hidden; the guest's real blows landed (80, 80); a death was
  scored 1 - 0 on both; clicked again, both off. The page shows the PvPvE tile.
- Fixed 11-08: the notice on turning it on said "your partner needs PvPvE on too", from before the host's rules; it says
  the host's rules count for everyone now. The PvPvE log lines and the relay's settings notice say PvPvE.

## 2. F6

F6 opens the PvP page (`pvppanel.lua`): the lobby (mode, clock and arena for the host; a team and READY for everyone; START),
the loadout, and LEAVE in a match. Bench 11-07: the real F6 key opened the page on both copies.

## 3. Presets

Two weapons and two Phantom Edges, any of the game's 20 and 20, owned or not: lent for the match if not owned, kept in
`pvp_preset.txt`, sent with each player's pick so every world knows them (`arena.lua` loadout, `pvppanel.lua` picker).
Fixed 11-08: a foe's weapons were never really lent in the other world (as from load data, the game added nothing), and
lent for real they leaked to the partner through co-op's shared items; and a Phantom Edge's skills were never sent, so
they never landed on a foe.
Skills are not a choice: every skill node is on for everyone in a match (item 9), which is what fair needs.
- Bench: see the table at the end (`pvpload.ps1`).

## 4. The countdown

三 二 一 in brush strokes over a crimson ink circle, then 斗; nobody moves till then (the input held, a shield on). Over each
countdown the round: ROUND ONE, ROUND TWO, FINAL ROUND, or ONE LIFE in Death (`arenaui.lua`). The guest's countdown is
shortened by the host's word's age, so both start together (the log says "the fight is on" in each world).
- Bench: ONE LIFE, ROUND TWO and FINAL ROUND countdowns in shots (11-07, 11-08).

## 5. The arenas

YuCong's Crimson Forest, Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's meadow (`arenas.lua`), and Here.
A boss's arena opens once every player's save has that boss beaten. The game's own fog walls close for the match and open
after. Bench 11-07: a match in each of the four, the trip, the spots, a closed wall 21 to 40 m from the middle, the finishing
move, home.
- Bench 11-09 (`pvprealwin.ps1`): a real win opens the arena. On the late-game save (the story past the four, their fights
  never fought), the Gold-Masked One at 1 health took one real blow and died the game's way: his record dead at once, still
  dead after a trip had the game save and after a restart, his arena open in the mod (`goldmask`), and at the gorge no boss
  and his spawner's own flag dead. (The 11-07 records were written by hand; a boss killed by GE_Kill then came back alive
  after a restart.)

## 6. No monsters; the network

Enemies within 90 m are parked (hidden, AI stopped) and come back after; `net.arena` stops every enemy and world job
(`net.ARENA_SKIPS`, `coop.lua`): only the players' positions, moves, hits and the match's events go.
- Sim: no enemy traffic from the host in a match; a guest's 4 s gap in the match (a loading screen's worth) has no retell of
  the world's dead or bosses till the match is over (fixed 11-08: it sent every death since the start into the match).
- Measured: see 16.

## 7. The gourd

The game's own Hulu for everyone, 3 drinks for the whole match, at its top level (a drink heals by the gourd's level: 40% at
0, 45% at 3, 50% at 6), made to hold just 3; a refill (a bell's sit) taken back; all of it as it was after.
- Bench 11-08 (`pvpfair.ps1`): both 3/3 at level 6 in the match; a real drink 300 -> 980 of 1360 (+680, 50%); 2 left into
  round 2; home 2/2 at level 0 as before.
- Fixed 11-09 (the user's own play on the bench): every skill node on for the match gave the gourd's extra drink (the bag's
  MedicineExtraUsage, a node's), a 4th; the HUD read R 4. And turning the nodes off after took nothing back: a match left a
  drink more for good (R 3 over a gourd of 2 at home). None in a match now, each player's own back after; the journal has it.

## 8. The modes

Duel: best of three, everyone up each round, a draw adds a round. Death: one life. The winners get a golden 生还, the losers
the game's red 殒命; the loser's death is the finishing move (item 12) and the game's own death animation.
- Fixed 11-08: a Death draw with both sides down started the next round at the floor's 1 health, down again at once.

## 9. Everyone the same

Every skill node on (for the match only), 1360 health, 160 attack, 640 Phantom Edge energy, held there; every weapon in the
match at level 30 in every world (a blow's damage goes by the defender's level of the attacker's weapon); every blow at half
the game's own; the gourd as in 7; talismans off for the match, each back in its own slot after (11-08); the perfect dodge's
slow motion held off (it slowed only the dodger's game). Health comes home as it was (fixed 11-08: a match was a free heal).
- Fixed 11-09 (the user's own play): Q (the Combat Art) did nothing in a match: it spends the bag's charges, everyone started
  with none, and blows on a figure build none. Each round starts with all three now, as the health; each player's own come
  home. On the bench Q fired the weapon's Combat Art at once (the host's launched the guest).

## 10. Teams

2 players: one each side. More: Crimson and Azure, each player picks one, three a side at most (each arena has three spots a
side; fixed 11-08, a fourth started on top of the first). A team is out when all of it is down; no blow lands on a teammate.
- Bench 11-07: 1 v 2 Duel and 2 v 1 Death with real blows (two copies and a bot); six players, 3 v 3 Death (two copies and
  four bots). Sim: three players, and five (four a side refused).

## 11. Issue #13

Rounds (the Duel), a health floor instead of death mid-match (`Health_Min = 1`), the perfect dodge's slow motion held off in
a match.

## 12. The execution

The blow that decides the match leaves the losers dazed; the winners have about 5 s: F (B or Circle on a pad) near one plays
the arena's boss's own move on them (YuCong's lunge, Hua Qianxiao's slide and cut, the Gold-Masked One's lunge and upward
cut, Mu Xiaokui's twin-blade dash; Here draws one), run in from where its blow lands, the moment slowed nearly to a stop, the
loser dying the game's own way. Every screen cuts to a camera beside the two.
- Bench 11-07: F pressed for real in all four arenas, the boss's move on both copies.

## 13. The clock

None, 60, 90 or 120 s a round; at zero the team with more health (as a share) wins the round. TIME shows on every screen,
then the round's result (11-08; the host says the clock ended it).
- Bench 11-08: TIME on both screens at zero, then ROUND LOST / ROUND TAKEN.

## 14. The UI

Each foe on the game's own boss health bar, its name, the score and the clock over it; each teammate's bar over the player's
own, in its look, the blow's share held in red then drained; round and match banners; the bell's red guide lines hidden in a
match (11-08: they ran from the bench's bell to the players). Fixed 11-08: the gold posture strip under a foe's health
moves with their real posture (it stood full all match); a foe's figure made again had its old bar left up, frozen; a
round's refill left the player's own bar empty and the near-death look on (refilled the game's way now); the drink tip
showed on a fresh game's first fall.
- Fixed 11-09 (the user's own play): a lock-on (the middle button) on a foe turned the camera to the map's origin, not the
  foe: a figure is a copy of the player's class, whose only lock point is the player's own camera rig's, set in the world and
  moved by that camera alone. It's on the figure's body's middle now, as an enemy's lock point is.

## 15. Movement and combat

The other players' figures play their real moves the frame they start; the guard, the deflect (the game's own timed parry)
and the dodge show as they happen; weapons drawn and held as theirs. A foe's move plays whole, from its start, on your screen
(no catch-up: your world judges the blows on you). Fixed 11-08: a foe's figure held this PC's own Phantom Edge (a figure is
made from this PC's bag), so a foe's edge skill drew yours; it holds theirs now, and drawing it stays its own abilities'.
- Fixed 11-09 (the user's own play, with the guest poking every two seconds): a swing started again in the last one's
  recovery restarts the same ability, never inactive, so it was never sent: the foe's pokes went unseen on their figure, but
  for the ones after a blow of yours, while their blows landed. Told again by its montage starting over, and the figure's
  copy of the last one cancelled for it: 80 such swings played in one match after.
- 11-09: a parry is one press at the right time: within 0.25 s of the blow, not long before a slow one, and never right
  after a click that met nothing (0.8 s): random clicking only blocks. A parry costs the attacker 200 posture (60 before:
  a third of the bar now, so four in a row break a spammer). A held guard only blocks; the swing plays out.

## 16. The network, measured

Bench 11-08 (`pvpbadnet.ps1`): the guest's copy through `relay_cli netem --delay 50 --jitter 10 --loss 1` (110 ms round
trip), a Duel "here".
- Each world's fight start, every round (the log's "the fight is on"): 15, 18 and 11 ms apart. The guest's countdown is
  shortened by the host's word's age; without it the guest would start a whole one-way delay (about 55 ms) late.
- The rounds' results reached the guest 40 to 70 ms after the host (the link's delay); the guest's real blows on the host
  landed (250, 249: the match's half damage); F pressed for real by the host, the finishing run started, and the guest's
  world played the move 58 ms later (Mu Xiaokui's dash, both screens filmed).
- What the link carried, by each relay's own count: in co-op by the bell, enemies about, the host sent 66.6 packets and
  0.2 events a second; in the match 53.8 and 0.0. The guest, which never sends enemies, about 59 packets a second in both.
  (The relays count packets, not bytes; the enemies' lines and the world's news are what a match drops.)

## Still open

- Real players on separate PCs, 4 to 6 of them: this PC runs two game copies; players 3 to 6 were relay_cli bots. A real
  link was stood in for by `relay_cli netem` (16).
- A verdict from you on the finished whole (the countdown, the boss finishers, the bars): you asked for no more videos.
- Not built, from issue #13: a quick rematch in the same arena (each match goes home, so a boss arena means two trips), and
  a centre the host saves per map for Here.
- Decided, not built (`docs/PVP.md`, "Scope, decided"): split screen has no F6 page; everyone linked plays (leave the
  session to sit out); the F6 page takes a mouse; one finishing move a match.
- Releasing 1.7.0 (the zip, GitHub, Nexus) waits for your go-ahead: nothing is pushed or posted.
- Known, not changed: the game's `SetWeaponForceHide` takes four arguments and `moves.lua` passes three, so hiding a
  figure's Phantom Edge for a partner with none ("E -") never worked (a co-op look, since 1.5.2). The bench saves own no edge,
  so the fix couldn't be seen; left as it was.
- The "Skill Over Strength" achievement: the upgrade to level 30 gives it to a player without it (a Phantom Edge at 30).
  Kept at 30, the top level the goal asked for, and said in the release notes (11-09). Nothing in the game stops just that
  one: an empty achievement table (the bench's way) marks the game's ACH_066 instead, so the only way round it is the
  edges at 29 (`data.WEAPON_LEVEL` in `arenas.lua` is one number for weapons and edges both). Yours to overrule.

## Bench results, 11-08

Two copies on one PC, the bench's test save (`tools/netlab/bench/pvp`).

| What | Script | Result |
|---|---|---|
| The bell's red guide lines | `pvpguides.ps1` | all three hidden in both worlds through the fight and the finishing move, no strand in any shot; all three back after |
| The gourd, a drink, TIME, health home | `pvpfair.ps1` | 3/3 at level 6 for both; a real drink +680 of 1360 (50%), 2 left into round 2; TIME then ROUND LOST / TAKEN on both screens; home 500/850 and 640/850 as before, the gourd 2/2 at level 0 |
| PvPvE after the rename | `pvppve.ps1` | the tile turned both hostile; six enemies stayed; real blows 80, 80; a death scored 1 - 0 on both; off again |
| A match over a 110 ms link, 1% loss | `pvpbadnet.ps1` | each round's fight start 11 to 18 ms apart in the two worlds; real blows 250, 249; F for real, the move in both worlds 58 ms apart; see 16 |
| Talismans; the refill | `pvptalref.ps1` | a talisman worn (AC_Deflect): off for the match with its effect, the journal had it, one put on mid-match off again within 2 s, back in slot 0 at home with its effect; a guest downed by real blows refilled at round 2 by the game's own `GE_RevocerHealth` (the Ultimate gauge untouched), its own bar full and no near-death look, the bar following a blow after; home health as before, still so 10 s on |
| A foe's posture strip; a remade figure | `pvpbars2.ps1` | the strip under the host's health on the guest's screen at full, then at half within 0.4 s of the host's posture going to half; the host's figure made again: one bar, on the new figure; none at home |
| Two loadouts; the foes' Phantom Edges | `pvpload.ps1` | picked on each page's own picker, kept in `pvp_preset.txt`; each player's in hand in the match, and on their figure in the other world, Phantom Edge too (before the fix the figure held this PC's own edge); all eight match weapons at level 30 in both worlds (before the lending fix a foe's were never in the other bag); home with their own weapons, nothing lent left, levels as before, still so 12 s on |
| A Phantom Edge's skill against a foe | `pvpedge.ps1 -Vk 0x11` | the guest's BrutalAxe skill (Left Ctrl, the game's own binding) on the host: before the fix nothing on the host's screen and no damage (`GA_BrutalAxe_Normal_C` was never sent); after, the swing on the guest's figure and the host 1360 -> 962 |

## Bench results, 11-09

| What | Script | Result |
|---|---|---|
| A boss beaten by a real blow | `pvprealwin.ps1` | the Gold-Masked One on the late-game save, one real blow at 1 health: record dead at once, after the game's save, and after a restart; his arena open (`goldmask`); at the gorge no boss, the spawner's flag dead |
