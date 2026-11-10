# 1.7.0 PvP: the goal, item by item

Each item of the 1.7.0 goal, where it's built, and what proves it: the simulator (`python -I tools/netlab/luasim.py pvp`,
`four`, `two`) and the bench (two game copies on one PC, `C:\PBZDev`, with relay_cli bots for players 3 to 6; the scripts are
in `tools/netlab/bench/pvp`). A trace of every item against the code and the evidence, with a critic over it, was run on
11-08; what it found open is fixed below or listed under "Still open". Branch `pvp-1.7.0`, from v1.6.6 (bf93706: its first
PvP commit, 99588f0, sits on it), with 1.6.7, 1.6.8 and 1.6.9 merged in (70fe1e5, at the user's word: "1.7.0 should have the
fixes we done previously"). The design itself: `docs/PVP.md`.

| # | The goal said | State |
|---|---|---|
| 1 | Rename the old PvP button to PvPvE (PvP with enemies) | Done, bench 11-08 |
| 2 | A separate F6 key for the new PvP | Done, bench |
| 3 | Presets: any weapon, skill or special skill, saved, loaded each match | Done (skills: all on for everyone, see 3); bench: see 3 |
| 4 | A countdown before the fight, a Phantom Blade Zero look | Done, bench (redone 11-09) |
| 5 | The four boss arenas, their own fog walls | Done, bench (all four, 11-07; a real win opens one, 11-09) |
| 6 | No monsters in a match; the network sends only what PvP needs | Done; sim and bench |
| 7 | Only 3 drinks, all from the same gourd | Done, bench 11-08 (a 4th, a skill node's, taken off 11-09) |
| 8 | Duel (3 rounds, the winner in gold, the loser's death) and Death mode | Done, bench |
| 9 | Everyone at the same level, max level, weapons too, "or anything else" | Done, bench 11-08 (talismans, Combat Art, difficulty: see 9) |
| 10 | Teams for more than 2 players | Done; bench with 3 and 6 players (bots) |
| 11 | Ideas from issue #13 | Done (rounds, health floor, slow-motion hold, a quick rematch) |
| 12 | An execution with a boss's own moves | Done, bench (all four arenas, F pressed for real) |
| 13 | Timer and no-timer modes | Done, bench 11-08 (TIME; redone as TIME'S UP 11-09) |
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

三 二 一 in the game's own brush font over a crimson ink ring, then 斗 in blood; nobody moves till then (the input held, a shield on). Over each
countdown the round: ROUND ONE, ROUND TWO, FINAL ROUND, or ONE LIFE in Death (`arenaui.lua`). The guest's countdown is
shortened by the host's word's age, so both start together (the log says "the fight is on" in each world).
- Bench: ONE LIFE, ROUND TWO and FINAL ROUND countdowns in shots (11-07, 11-08).
- Redone 11-09 (the user: "no visual effects", "2 is too long", "some are not looking HD", hard to read against the scene;
  then, of a first try's bursts, droplets and rays: "kidish and cartoonish for a serious triple AAA game or not", "there is
  visual effects in the game much better"). The numbers are text in the game's own brush font at the screen's size, bone
  white with a dark edge, over an ink wash that swells at each beat; each beat the game's own camera shake and its story's
  破 impact; 斗 in blood, the ring bursting open, the screen's edge red a moment, the perfect deflect's shake and the 斩
  impact. Bench: `pvplook.ps1` on the guest, every beat shot, sharp and readable over moss and rock.

## 5. The arenas

YuCong's Crimson Forest, Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's meadow (`arenas.lua`), and Here.
A boss's arena opens once every player's save has that boss beaten. The game's own fog walls close for the match and open
after. Bench 11-07: a match in each of the four, the trip, the spots, a closed wall 21 to 40 m from the middle, the finishing
move, home.
- Bench 11-09 (the 1.7.0 thumbnail's shoot): a Duel in the Crimson Forest on both copies, fight on in both worlds 24 s
  after START. Its arena needs only YuCong's last phase's records (P3_1/2/3): on the late-game save her first phase kneels
  there, inert. A save where that first phase was killed by hand starts her prison scene on arrival, and the match is called
  off as designed (arena.storyBegan): never kill her outside her own fight.
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
- Bench 11-06 (two copies, Here): a Duel end to end: lobby, countdown, real blows, rounds, the fall, 生还 for the winner and
  殒命 for the loser, home with everything as it was.
- Bench 11-07 (`pvpgoal.ps1`): a Death match with a 60 s clock decided by the clock and finished with F pressed for real;
  a 120 s clock; a no-clock Duel end to end. (`pvpteams.ps1`, three players with a bot): a 1 against 2 Duel, a team out
  only when all of it is down, and a 2 against 1 Death, both winners in gold. (`pvparenas.ps1 -Mode death`): a Death match
  in each of the four arenas, finished with F pressed for real.
- Sim (`luasim.py pvp`): rounds 1 to 3 of a Duel to 2 - 1, the finishing window and move, the results and home; a Death
  match with a 60 s clock ended by it, TIME on both screens.
- Fixed 11-08: a Death draw with both sides down started the next round at the floor's 1 health, down again at once.

## 9. Everyone the same

Every skill node on (for the match only), 1360 health, 160 attack, 640 Phantom Edge energy, held there; every weapon in the
match at level 30 in every world (a blow's damage goes by the defender's level of the attacker's weapon); every blow at half
the game's own; the gourd as in 7; talismans off for the match, each back in its own slot after (11-08); the perfect dodge's
slow motion held off (it slowed only the dodger's game). Health comes home as it was (fixed 11-08: a match was a free heal).
- Fixed 11-09 (the user's own play): Q (the Combat Art) did nothing in a match: it spends the bag's charges, everyone started
  with none, and blows on a figure build none. Each round starts with all three now, as the health; each player's own come
  home. On the bench Q fired the weapon's Combat Art at once (the host's launched the guest).
- Added 11-09: the game's difficulty the same for everyone. Each mode's combat config read from the game: for a player they
  differ only in the perfect deflect window (Wayfarer 10 frames, Pathbreaker 8, Hellwalker 8, 66 Days 6), the window on a
  break (14, 12, 6, 6) and how long a broken player reels (Wayfarer 2 s, the rest 3); no player attribute modifiers on any.
  Co-op's Hellwalker (952cc2f) left out `CoopDifficulty = Off` or lower and 66 Days. A match now holds everyone at
  Hellwalker whatever the setting, the own mode back after; 66 Days is never lowered and gets Hellwalker's 8-frame window in
  its config for the match, in memory only. Sim: pvp (66 Days with 8 frames in the match, 6 after; a Wayfarer with the
  setting off at Hellwalker in it and back after; a Pathbreaker setting back to Pathbreaker after), four (a crash in a match
  puts the own mode back). Bench: see the 11-09 results (the window is read live: a perfect deflect costs no posture, an
  ordinary one about 45, so it counts in a match).
- A review of 3f77be8 (22 agents, each finding tried by two skeptics) confirmed six defects, all fixed:
  - Leaving co-op mid-match or while held (Leave, netoff) left the hold and 66 Days' window as they were. difficulty.lua ran
    only as one of coop's extraTicks, which stop with sync. It now has a loop of its own while sync is off.
  - Back at the player's own mode after a match, it set the same mode again every second. Landing on the own mode now ends
    the hold.
  - A crash in a match wrote the match's Hellwalker into difficulty_own.txt, which the save never holds (save veto). A match
    no longer writes the file.
  - A pick between two matches was overwritten by a stale `own`. Fixed with the step-down change above.
  - A higher pick was lowered by a stale `held`. A pick above the held mode now ends the hold.
  - four.lua's crash check passed on the old code. It now uses a case only the new code passes.
  - Two findings were rejected: an old one-number file with the setting Off (no shipped install has one), and 66 Days
    picked mid-match (the game doesn't allow it mid-run).
  - The file isn't tied to a save, and it is deleted before the game saves the restored mode. Both are older than
    3f77be8, low, and left to the co-op side.
  - Sims: pvp 145, four 1104, two against fc48deb the same (19). The reviewers' scenarios (sync off in a match, the
    step-down, the crash file) all come out right.

## 10. Teams

2 players: one each side. More: Crimson and Azure, each player picks one, three a side at most (each arena has three spots a
side; fixed 11-08, a fourth started on top of the first). A team is out when all of it is down; no blow lands on a teammate.
- Bench 11-07: 1 v 2 Duel and 2 v 1 Death with real blows (two copies and a bot); six players, 3 v 3 Death (two copies and
  four bots). Sim: three players, and five (four a side refused).

## 11. Issue #13

Rounds (the Duel), a health floor instead of death mid-match (`Health_Min = 1`), the perfect dodge's slow motion held off in
a match.
- 11-09, a quick rematch: on the last screens the host's F (from 1.5 s in, so a finishing blow's F held on isn't one),
  PRESS F TO REMATCH low on the host's screen (`banner_again`). Everyone stays where they are, round 1 at 0 – 0, the gourd's
  3 drinks back, the finished player up; the trip home waits for the last match and puts back what was there before the
  first (`arena.again`, `AR again`). Sim: pvp, 19 checks. Not played on the bench yet.

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
- Redone 11-09 (the user: "The Times Up or Time Over. Clearly need to be done better", of a banner that read TIME):
  the clock's end now has the countdown's look, 时间到 in the game's brush font over the ink wash with TIME'S UP under it,
  big and in bone (Chinese: the characters alone), the game's camera shake and its chapter-title sting, then the round's
  banner. Sim: TIME'S UP on both screens, none in a match the clock didn't end. Shot with `pvplook.ps1`. The first shot
  had TIME'S UP small and red, hard to read over the fighters; made big and bone, the user: "Much better", "Nice".
  (The English words on the match screen come out in plain letters, not the title font WORD_FONT names: it reads well,
  left as it is.)

## 14. The UI

Each foe on the game's own boss health bar, its name, the score and the clock over it; each teammate's bar over the player's
own, in its look, the blow's share held in red then drained; round and match banners; the bell's red guide lines hidden in a
match (11-08: they ran from the bench's bell to the players). Fixed 11-08: the gold posture strip under a foe's health
moves with their real posture (it stood full all match); a foe's figure made again had its old bar left up, frozen; a
round's refill left the player's own bar empty and the near-death look on (refilled the game's way now); the drink tip
showed on a fresh game's first fall.
- 11-09: the last screens get a soft glow in their colour, a few rising embers for the winners, a slow red pulse at the
  screen's edge and falling ash for the losers; the finishing blow brings the game's own boss-kill 斩 in smoke, on every
  screen (only its Niagara part started: an activated screen of the game's may take the controls). Bench: `pvplook.ps1`.
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
- Not built, from issue #13: a centre the host saves per map for Here. (The quick rematch is built, 11-09: 11.)
- Decided, not built (`docs/PVP.md`, "Scope, decided"): split screen has no F6 page; everyone linked plays (leave the
  session to sit out); the F6 page takes a mouse; one finishing move a match.
- Releasing 1.7.0 (the zip, GitHub, Nexus) waits for your go-ahead: nothing is pushed or posted. The zip is built and
  checked locally (11-10, `tools/make-release.ps1`): `dist/PhantomPact-1.7.0.zip` from 34feae8, 5699 KB, SHA-256
  4CC7D2F9BE8EDBB3614CACA8A29B24711DEEF5A03A661D9E93D39CE7A1B52A3A, Windows Defender clean, file types Nexus takes,
  its 34 scripts, the ini and INSTALL.md byte for byte the commit's. The older builds are kept beside it, out of date
  (`PhantomPact-1.7.0-d19a7cf.zip`, `-a962369.zip`, `-8bdfc97.zip`, `-da821db.zip`, `-d1bdf5a.zip`).
- Bosses at 200% health with a partner, 300% with two, 400% with three (d19a7cf, the user's call 11-10): the ini shipped
  `CoopBossHealth = 200`, so a fight together took about as long as alone; the enemies stayed at 150%. Replaced the same
  day by the next item.
- Boss super armour and a bigger guard bar (BUGHUNT 222, the user's calls 11-10 after the bench). The cause the user found
  watching the bench: every hit made a boss flinch, so two players kept it stuck about half the fight (51% on the
  Gold-Masked One, against 31% for one player). Changes:
  - `CoopBossArmor = On`: while a partner is here, a boss's flinch is let go at once, the move a hit cut goes on, and a
    guest's copy drops its own reactions; the guard break and an execution stay. Bench, the final code: the host's boss
    4% stuck, the guest's view 5%, nearly all of it the guard break's stagger.
  - Not proven: a player's perfect deflect with it on. A script couldn't time one.
  - `CoopBossPosture = 200`: the guard bar 200/300/400%, so it breaks about as often as alone.
  - Health back to the enemies' 150/200/250%: `CoopBossHealth` is left out.
- The stun-lock report again (11-10, BUGHUNT 221): aae17cc held on the elite it was tested on, not on a real boss. On the
  Gold-Masked One, both players swinging, 1.7.0 still broke it 5 times in 30 s (9 moves of its own, 21 s reacting).
  a962369: a partner's blows by the game's posture rules (none in the boss's break and fill, for 6 s after, or while
  it deflects or dodges), a guest's break filled again, and a break the guest saw played on the host too; two
  adversarial reviews (18 agents) and their fixes. Bench after: 2 breaks, 15 moves, 13 s reacting (the host alone: 1,
  23, 7 s); the guest alone, 30 moves in 40 s. Open: a guest's execution of a boss may not show its victim's half on
  the host (not tried on the bench).
- 1.6.9's player reports, on this branch too: the stun-lock (aae17cc), the double bar (2444e2b), items twice (6a7c2bb,
  f41c7eb), a partner's finds on the right and their pickups staying taken (03feb1a, BUGHUNT 219), the damage options
  (d1bdf5a). Three adversarial reviews of those (11-09/10; the third: 12 agents, each finding run in the sim and put
  to a skeptic, 9 of 9 confirmed) found more faults, all fixed. Pickups (BUGHUNT 219): a copy not loaded here, a kill's
  reward taking a pickup's wait or giving the word its count, two guests at one pickup, one's own take before the look
  or after a run, a word before the first look, a script error that left a copy to take (older). Damage (COOP_GUIDE.md's
  options): a number changed across 100 or back to it, a boss known by its bar alone and a player joining between its
  fights, ghost twins. Known, not changed, as on the code before: a word over 16 s late (the link down between a take
  and the look), a party guest's late word after a freeze, a party guest's own find a moment before another's take of
  the same thing, a new enemy at a dead boss's address within 30 s. Open: "the guest can't deal damage to some bosses"
  (BUGHUNT 220): not reproduced on the bench. da821db, a fix for a cause that fits, was taken back (546bc1b): the
  reviews found it held real flow steps. The boss's name or the guest's UE4SS.log would settle it.
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
| The difficulty the same for everyone in a match | scratchpad `fairbench.ps1` (bench only), 17:30-17:43 | the bench's PvP test save is itself on 66 Days. The host on 66 Days, the guest put on Wayfarer with `difficulty off`: in a duel the host stayed on 66 Days with an 8-frame perfect deflect window, the guest was on Hellwalker; after it the host's window was 6 again and the guest back on Wayfarer, no `difficulty_own.txt` left. Whether the game reads the window live (`pvpdeflect2.ps1`, the guard held 0.9 s through a heavy blade's blow; the window set in Hellwalker's config, which the match copies into 66 Days'): pressed about 150 and 50 ms before the blow, at 1 frame an ordinary deflect costing 44-45 posture, at 40 frames nothing, as with the game's own forced perfect deflect. The first duel after linking saw none of the guest's swings (no 8-frame baseline) |
| The goal's own checks, again after the 1.6.9 merge | `pvpgoal.ps1` on 952cc2f, 16:21-16:26 | F6 pressed for real opened the page on both copies; one team each, nothing stops the start; in a Death match both at 1360 health, 160 attack, 640 posture, the same Hulu with 3 drinks, 32/32 skill nodes, all 8 weapons at 30; the 60 s clock decided round 1 ("round 1 to Crimson, 1 - 0" in both worlds); F pressed for real played Mu Xiaokui's finishing move, the game's 斩 on the loser's screen, then 殒命; both home with their own 850 health, 2 drinks and no nodes; the 120 s clock ran |
| The user's own play (host) against the guest (`spar.lua`) | live | after 2a2853a: lock-on on the foe's body; every swing shown (the guest's figure played 30 attacks to its 26+ swings); Q (the Combat Art) fired, 3/3 charges each round; R 3 drinks, no 4th; a timed parry cost the attacker 200 posture, a held or mashed guard only blocked |
| The countdown and the last screens | `pvplook.ps1` (no match) | after 15072cb: every beat of 三 二 一 and 斗 shot, sharp and readable over snow, moss and rock; 生还 and 殒命 with their glow, embers and ash; the game's own 斩 at the finishing blow, its screen never activated |
| The Crimson Forest | the thumbnail's shoot | a Duel there on both copies, fight on in both worlds 24 s after START (save with YuCong's last phase beaten) |
| A boss beaten by a real blow | `pvprealwin.ps1` | the Gold-Masked One on the late-game save, one real blow at 1 health: record dead at once, after the game's save, and after a restart; his arena open (`goldmask`); at the gorge no boss, the spawner's flag dead |
