# PvP (1.7.0)

Two ways to fight each other:

- **PvPvE** (F5 > MORE): the old PvP switch, renamed. Partners can hurt each other in the open world, enemies and all. Death
  decides, as before. The ini key stays `PvP` so old ini files keep working.
- **PvP** (F6): a match in one of four boss arenas, or where the host stands, with nothing else in it. This file is about this one.

## What a match is

| | |
|---|---|
| Players | 2 to 6, everyone linked, on the same version. 2 players: a duel. More: two teams (Crimson, Azure), each player picks one, three a side at most (each arena has three spots a side) |
| Modes | **Duel**: best of three rounds, everyone back up each round. **Death**: one life, last team standing |
| Clock | None, 60, 90 or 120 s a round. At zero the team with more health left (as a share) wins the round; equal is a draw. TIME shows on every screen first, then the round's result |
| Arenas | YuCong's Crimson Forest, Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's meadow: the game's own places, with their boss fog walls up and no monsters. Or **Here**: where the host stands, the sides 8 m either way of them on the first line round from the host's facing (30-degree steps) with floor under both ends and a clear view between them at chest height (`arena.hereYaw`); none, the host's facing |
| Fair start | everyone a Soul at the top of the game: every skill node on (each one the player hasn't, for the match only), 1360 health, 160 attack, 640 Phantom Edge energy, held there all match; every weapon in the match at level 30; 3 drinks of the same gourd at its top level for the whole match (a drink heals by the gourd's level: 40% of the health at level 0, 50% at 6, the bench 11-08), a refill in it (a bell's sit) taken back |
| Damage | every blow at half the game's own (`DAMAGE` in `arenas.lua`): at the top of the game a Sanguine blow took 499 of 1360 on the bench, three to fall; at half, about six. A parry costs the attacker 60 posture. Each player's own `PvPDamage` and `PvPParryPosture` count only in PvPvE: in a match they'd let a player take less |
| Loadout | a preset of your own, kept between matches (`pvp_preset.txt`): two weapons and two Phantom Edges, any of the game's 20 and 20, owned or not |
| Start | the host picks the mode, the clock and the arena on the F6 page; everyone picks a team and presses READY; the host presses START |
| Countdown | 三 二 一 in brush strokes, then 斗: nobody moves till then |
| Down | health can't go below 1: at 1 you fall, out of the round. So does a fall from the arena, and a rest at a bell. A team with nobody up loses the round. Down, the camera follows a teammate still up, or else a foe; a team that lost the match watches the winners come for them |
| The end | the blow that decides the match is slowed nearly to a stop, and leaves the losers on their feet, dazed (the game's own posture-broken stagger, held on its hunch). The winners get about 5 s to finish them: F near them plays a boss's move (below). Then the winners get a golden 生还 and the losers the game's red 殒命, both made and played the same way (the game's own dark edge over the scene, the calligraphy fading in at one size), and everyone goes back where they were, with what they had |
| Leaving | F6, then LEAVE twice. A player not heard from for 8 s ends the match for everyone |

## The finishing move

A winner who presses F (on a pad, B or Circle: the game's use button) within 9 m of a dazed foe in the finishing window (7 s, F taken till 1.5 s before its end, so the move
reaches every screen in time) plays the arena's boss's own move on them (`FINISHERS` in `arenas.lua`): in the Crimson Forest
YuCong's blade form, a step back and the lunge (`YuCong_Bing_Skill_04`); on Hua Qianxiao's stage her drunken slide and rising
cut (`HuaQianXiao_Attack_04`); in the Gold-Masked One's gorge his lunge and upward cut (`GoldMaskMan_AtkCombo_A01`); in Mu
Xiaokui's meadow her twin blades' turning dash (`MuXiaoKui_SpecialAttack_05`); "here", one of the four drawn. The bosses' moves
play on a player's body: the game marks their skeletons alike with the player's, and on the bench each played whole, the body
carried the way the boss's is, 2 to 5 m. So the winner steps to where the move's run starts, facing the foe, and its blow lands
on them: `lead` is how far the move has carried the body by the blow (read from its path, frame by frame, on the bench), and
`arena.runUp` wants floor within 60 cm of the foe's at the start, a quarter, half and three quarters of the way, and behind a
move that steps back first, and sweeps a ball the body's size (35 cm, at its middle) along the run by the pawn's own collision
profile, the figures and the two players' weapons left out (a rock, a tree or an invisible wall would stop the run), trying
round the foe 30 degrees at a time. With no room anywhere, a move that won't load, or one that won't play on the winner's body
(tried on it before the move is sent), the
winner steps in close and plays the game's own execution of the Infernal Rouge, `Hun_HeiMoShang_EXE_F_04`, a spinning grab and
an overhead cut. (The club bosses' leap and slam came first, and Du Yan's point-blank shot; the user found the leap wrong and the
shot poor, so both went, and no finishing move leaves the ground. A few bosses also have a grab whose victim half is made for
the player's body, Hua Qianxiao's `Skill_04` with `Skill_03_Hun`, the same 5.6 s; tried on the bench 11-07 they make no pair:
her half is a backflip that leaves the ground and lands 8 m away, the victim's slides 2.4 m back and comes forward again.) Each was played in a real
match on the bench, both screens: the run, the blow, the fall. Every screen cuts to a camera beside the two, low, turning round them from the
winner's face to the beaten's as the move plays, as a fighting game shows its finishing moves. It keeps clear of rock and wall
as the game's own camera arm does: the line from the two to it is traced each frame and it comes in before anything on it, and
when it starts it takes the side of the pair (or a higher view) whose line stays clearest through the move. (The bench, 11-07:
"here" on a river bank it had turned into a slope of rock and bush, and the move played behind them on both screens.) As it
lands the game slows to 0.2 for a second (held every frame: the game puts its own time back each frame), the game's musical hit
sounds, and the beaten dies as the game shows a player's death (`DEATH`, its own death animation, held on its last frame till
everyone goes home). Every player sees it: the winner's world plays it on the winner, every other world on the winner's figure
(`AR fin` says which move and where they stood). The result waits until the move is over.

The thin red lines (fixed 11-08). After a player was moved by hand (the arrival, a round's start, the finishing move's step),
two thin red strands could hang from them back towards where they stood, for good. They were the game's own bell guide line
(`BP_BellGuideLine_C`): the red thread from a bell that reaches for the player near it (its tick eases its end towards the
player's pawn). In a match "here" by the bench's bell it ran from the bell to wherever a player was set down, and across the
whole fight. Every sighting was by that bell, on the bench's save; the late-game save's four arena matches showed none, so the
outfit was a red herring. A match now hides every guide line from the arrival (looked at again every 5 s, as more stream in)
till home, and home shows again only the ones it hid, by name (`arena.bellGuides`). Three are loaded by the bench's bell; the
search is 2 ms. On the bench 11-08, a Death match "here": all three hidden in both worlds through the fight and the finishing
move, no strand in any shot, all three back after (the bell's own threads to the player 1.2 m from it, as the game draws them).
Ruled out first, 11-07: the body and its Chaos cloth (every cloth reset), the band's streamers, the whips, the blade, the other
players' figures, the world's lasting debug lines and any cable. Don't call `ResetAnimInstanceDynamics` on the body's parts: it
hung the game thread.

## Who decides what

The host runs the match: the rounds, the score, the clock and the result. Each player's own game decides the hits that land on
them, as in PvPvE: the others' figures in your world swing for real, and the game's own combat judges it (block, deflect,
perfect dodge, posture). So nobody gets hit by a swing they saw miss.

A player who is down says so (`AR down`); the host counts.

A foe's move plays whole on your screen, from its start, a moment after they began it (the network's delay): no catch-up that
cuts its wind-up short. Your world judges the blows on you, so it's the swing you see that you parry or dodge, all of it.

## Scope, decided

- Online only: split screen (`Role = Local`) has no F6 page. Both players there share one world, where a foe is a figure of
  someone else's world; that's a different fight, not built.
- Everyone linked plays: the host's START waits for every linked player's READY. To sit a match out, leave the session first (F5, LEAVE).
- The F6 page is clicked with the mouse, as the F5 page is. The finishing move takes F, or B / Circle on a pad.
- One finishing move a match: the deciding blow's team finishes one of the fallen; the others get their 殒命 as they stand.
- The rules (damage, stats, drinks, levels) are each player's own `arenas.lua`; a match needs everyone on the same version, and
  so the same rules. A check of the rules' own text wouldn't stop an edited file: it would compute what it was edited to.

## On screen

Each foe is on the game's own boss health bar (`PBZHUDLayout:RegisterBossHPBar`), white health over gold posture, at the
top, as a boss fight shows its boss. Its name text (`BossName`, the game's own font) says who, and over the first foe's bar the
score (YOU 1 – 0) and the round's clock; its health is moved with the bar's own `ForSeq_UpdateHealth`. A player's figure on
a boss bar gets no `Character` (the bench), so pbz.lua knows each bar by the widget the HUD made for it, and keeps it out of
the mod's own boss lists (`bosses`, `bossActors`), so nothing that walks the bosses sees a player. The countdown and banners are
ink-brush pictures of ours; TIME comes before the result of a round the clock ended. The last screens, the red 殒命 and the golden
生还, are built from the game's own death screen pictures (`CARDS` in `arenaui.lua`).

In a team match each teammate has a bar over the player's own, in its look (the game's player bar follows only its own
player): the dark frame cut away at its right end, the bone fill, the name in the player's lobby colour (`art/pvp/mate_*`,
`make_pvp_art.py` `mate_bars`). A blow's share holds in blood for 0.6 s and then drains; a teammate down shows an empty bar,
dimmed. Their health comes with their position, as the foes' bars do. On the bench, 11-07, three players: the bar full,
after two blows the blood chunk then drained, empty and dimmed when the guest went down, the host's on the guest's screen.

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
| `AR round <id> <round> <winner> <crimson> <azure> <clock>` | host | a round's result and the score (`winner` 0 = draw; `clock` 1: the clock ended it) |
| `AR end <id> <winner> <crimson> <azure>` | host | the match's result; the finishing window opens |
| `AR fin <id> <victim> <move> <x> <y> <z> <yaw>` | winner | a finishing move on a fallen player, and where the winner stands for it |
| `AR home <id>` | host | everyone goes back |
| `AR quit <id> <why>` | anyone | leaves, or the host calls it off |

Health goes with the position (the state sample), which is how the bars move at 125 a second.

## The network during a match

There are no enemies, so none of their traffic goes: no enemy lines, no `A`/`D`/`K`/`N`, twins, scaling, story, flow, loot,
bells, chests, blockers or map fog. `net.arena` turns all of that off (`net.ARENA_SKIPS` in `coop.lua`). What's left is the
players: positions (125 a second, as before), the moves they start, hit reactions, weapons and the match's own events. A
partner's gap (a trip's loading screen is one) had the host tell every enemy death and boss again in the middle of a match:
that retell waits for the match's end now (`watchOnePartner` in `coop.lua`; the sim's gap check).

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
- their gourd: which one, how many drinks, its size and its level (the match's gourd known by name, `arena.gourdOf`);
- their health: they come home with what they had, not full;
- their skill nodes: each one the player hasn't goes on for the match, one at a time (`ActivateNode`, the game's buy, which
  costs nothing called on the tree), and only those go off after it (`DeactivateNode`). The player's own nodes are never
  touched. (The bench, 11-07: the game's `DeactivateAllNodes` takes the player's own nodes and their levels too, and neither
  `ActivateNode` by init nor `InitNodeStateByCharacter` puts one back. Each talisman slot is one node's: HeiShi2, ShaChiHuPo5,
  MemoryFlower7, TopRongShuZhiXin4.)

Weapon levels: a blow's damage in the defender's world goes by the defender's own level of the attacker's weapon. On the bench a
guest's Sanguine blow took 128 from the host at the host's Sanguine level 1, 256 at level 11. So in every world every weapon
anyone in the match fights with goes to level 30 (lent first if not owned), and the loadouts travel with the start so every
world knows them. Raised with the game's own `UpgradeWeapon` and put back with `ResetWeaponToLevel` (both only set the level:
no dust, nothing in the bag). Tried and dropped: `ResetWeaponToLevel` won't raise (asked for 30, the weapons stayed at 1), and
the bag's own level field written by hand (`MainWeaponInfos`' `WeaponLevel`, `ShaqiWeaponInfos`' `ShaChiWeaponLevel`) reads
back right, but a match after either crashed the bench host within a second, a call to an empty function pointer.

Known: the upgrade to 30 gives a player who doesn't have it the game's "Skill Over Strength" achievement (a Phantom Edge to
level 30), as it did the bench player.

The four stats the match holds (health, attack, Phantom Edge energy and its attack) are noted before anything of the match,
and one still at the match's value at the end gets the player's own back: the game works a stat out again only when an
effect on it changes, and on the bench (11-07) both players came home with the match's 160 attack over their own 100.

Parries go by the game's own deflect. On the bench (11-07) the guard was pressed for real: the game's `IA_Deflect` and
`IA_Stance` are on the right mouse button (and the left shoulder), and a keyboard key bound to them in the bench copy's
memory took key presses posted to its window (a posted mouse button never reached the game). Against a light attack:

- pressed 60 to 220 ms after the attack starts on the defender's screen: the game plays `Hun_Tang_DefenceNormal_A/B/C` and
  nothing is lost;
- pressed 300 ms after or later: the blow lands (250 health, about 230 posture);
- held from before it (0.4 to 1.7 s): the same Defence move, and nothing lost either, only the guard's own upkeep of about
  20 posture a second (traced frame by frame; the first tries had read about 170 lost, which never came again);
- a blow that never reached: no Defence move at all.

So the game turns aside every blow that meets a guard, held or not, and a stagger for each would make holding the guard the
whole match's answer. A parry is the timed one, as in a fighting game. `pvp.lua` opens a swing at each foe attack's `M` (by
its ability class) and settles it at this player's next Defence move. The guard raised after that attack came (150 ms of
grace, for a read of it), nothing lost and the foe in reach (3.5 m): a parry, sent that moment (`V parry`). The attacker
staggers and loses 60 posture, and their figure staggers here. A guard held from before, an answer that cost posture, a hit
or a blow that never came: the game's own block or nothing, no stagger. The rule before looked for any running ability on
the foe's figure, and every figure always runs a passive (`GA_Hun_ShachiHook_Passive_C`), so its swing never ended and not
one parry was ever judged in a match.

In a match the guard's montages are the only ones sent (`U`): the stance's enter and exit, and the Defence move. The game
starts the Defence move itself, not as one of the player's abilities, and a figure can't start the stance's ability ("Ghost
couldn't play GA_Hun_Tang_Stance_C", every time). Without them the attacker never saw a guard go up, and saw their blow go
home on a figure that had turned it aside. A figure whose player still holds the guard after its Defence move goes back into
the guard, as their own body does. While a player holds the guard, and for 0.6 s after their Defence move, their figure on
the other screens is shielded (the game's own lying-down invulnerability, `GE_PBZLieInvulnerable_C`, one per figure), so a
blow there doesn't make it flinch over the guard. Their own game decides every hit; the figure's flinch was only for show,
and on the bench it came over the deflect.

A dodge begun as the blow came was refused on the attacker's screen: their own blow had put the figure in a flinch (for
show only, the defender's game decides), and a flinching figure can't start a move. A move from the player now clears that
flinch first. On the bench the figure flinched for 20 to 90 ms, then back-stepped as the player had. A perfect dodge's slow
motion stayed off in the match (time 1.00 throughout).

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
  clock: the user wants the game's own bar design, so ours went), and the last screens; each teammate's bar over the player's own
  (On screen, above).
- `pvppanel.lua`: the F6 page (lobby and loadout).
- `pvp.lua`: the fight itself, for PvPvE and the arena: hostile figures, parries, teams.
- `art/make_pvp_art.py`: every picture above.
- `tools/netlab/sim/pvp.lua`: in the simulator, a whole duel with the finishing move, a guest leaving a match, and three
  players in two teams, a fallen one watching their teammate; the gourd (3 of 3 at level 6, a refill taken back, all of it
  back after), the health back as it was, a guest's 4 s gap in a match (no retell till the end), TIME on both screens when
  the clock ends a round, and five players (four a side refused) (`python -I tools/netlab/luasim.py pvp`; `all.ps1` runs it).
- Three players in the real game with two copies on one PC: `relay_cli bot client --say <file> --heard <file>` joins a host
  with `PartySize = 4` as one more player and speaks the match's own words (a line added to the say file goes out as an event:
  `AR pick 2 1 - 1.7.0 Tang,PoJun,ShachiHook,TigerCannon`, `AR here <id> there`, `AR down <id> <round> <by>`; `!at x y z yaw`
  stands it, `!hp now max` is the health it shows), and writes every event it hears to the heard file. On the bench, 11-07:
  one against two (a duel of three rounds) and two against one (Death), real blows: the lobby's three rows and its checks, a
  team out only when all of it is down, no blow landing on a teammate, both copies finishing the bot's figure, the gold card
  for both winners, everyone home with their own. A bot's pick lists the arenas it may go to (`goldmask,huaqianxiao,...`,
  `-` for none): the host refuses a boss arena until every player has beaten its boss.
- Six players, the most a party takes: the host at `PartySize = 6`, the two copies and four bots (Crimson: both copies and
  one bot; Azure: three bots), Death here, 11-07: the six-row lobby, three spots a side, three foes on the boss bars across
  the top and two teammates' bars on each copy, Azure out only at its third fall, the host's F on one of the fallen.
- The boss arenas need a save where those bosses are beaten. The bench's late-game save (the other account's, from the 11-02
  story tour) had the story past all four but no record of their fights, so the records were written on the bench: a
  spawner's own `SpawnerSaveInfo.IsAlive = false` and `SetShouldNotSpawnAfterDead = true`, then its `Save()` (that writes a
  record the save lacks; one it has already is changed in place, through `SpawnerSaveData`'s value), and a trip for the game
  to save it. Without `SetShouldNotSpawnAfterDead` a record comes back alive after a death or a trip home, and the host's
  arena check then refuses that arena, as it should. Write the records without starting the fights (the bench's
  `pvpbeaten.ps1` stops at each boss's arena and writes them there, its bar never up): the first try killed YuCong's first
  phase before writing his, and arriving later started his second phase's prison scene, which killed the guest (the match
  ended cleanly on both copies, "you died", "player 2 left"). Matches in all four arenas, one after another, 11-07 late: the
  game's own trip there (3 to 27 s), both players at their spots 8 m from the middle, the arena's fog wall closed (by its own
  collision, 21 to 40 m from the middle), the fight, F pressed for real and the arena's boss's own move run in from its start
  (the body's sweep by the pawn profile working in the game), the cards, the trip home: the Crimson Forest (YuCong), Hua
  Qianxiao's stage, the Gold-Masked Gorge, Mu Xiaokui's meadow.
