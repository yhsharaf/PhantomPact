# PvP (1.7.0) bench

Scripts for the arena PvP on the two bench copies (`C:\PBZDev`, see `tools\netlab\README.md`), with relay_cli bots as the
third to sixth players. Every step is read from the game itself, and most scripts take shots of both windows.

They only touch `C:\PBZDev` and a work folder, `$env:TEMP\pvpbench`: the copies' handles (`pvp-host.json`,
`pvp-guest.json`, written by `pvpstart.ps1`), the bots' folders (`bot3`, `botn1`..`botn4`), `trig.txt` and `shots\`. The
Lua probes and `sheet.py` are read from this folder. Saves the scripts change are put back by `pvprestore.ps1`, to the
pre-PvP backup (`C:\PBZDev\save-backups\before-pvp-20261106-1709`), with no copy running; the cycle scripts run it first.

## Starting

    .\tools\netlab\bench\pvp\pvpcycle.ps1            # two copies, host (copy 1) and guest (copy 2), both in the game
    .\tools\netlab\bench\pvp\pvpcycle3.ps1           # the same with the host's party at 4, so a bot can join
    .\tools\netlab\bench\pvp\pvpbot.ps1              # then the third player: a bot in slot 3 (bot3)
    .\tools\netlab\bench\pvp\pvpbots.ps1 -Count 2    # or bots in order instead (botn1, botn2: slots 3 and 4)
    .\tools\netlab\bench\pvp\pvpbot.ps1 -Stop        # pvpbots.ps1 -Stop for the others
    .\tools\netlab\bench-lock.ps1 -Give              # done: the bench back, every copy closed

Six players need the host at PartySize 6: start the copies with `pvpstart.ps1 -Two -HostSettings @{ PartySize = 6 }`
(copies stopped and saves put back first, as the cycle scripts do), then `pvpbots.ps1 -Count 4`.

A bot is native relay_cli's `bot client --say <file> --heard <file>` (`native\build\relay_cli.exe`, built by
`tools\build-native.ps1`). Each line added to `say.txt` goes out as the mod's own event (`AR pick ...`, `AR here ...`,
`AR down ...`); `!at x y z yaw` stands it there, `!walk` sends it round its circle, `!hp now max` is the health it shows.
Every event it hears goes to `heard.txt`.

`sheet.py` and `pvpguides.ps1` need Python with Pillow.

## Scripts

| Script | What it proves |
|---|---|
| `pvpstart.ps1 [-Two]` | Takes the bench, installs this checkout's mod and main.dll on C:\PBZDev, starts the copies (no keys pressed). `-Two`: a host and a guest on loopback; otherwise one copy with co-op off |
| `pvpcycle.ps1` | The two copies onto this checkout's code: stopped, saves put back, installed, started, both in the game (RETURN on the title menu only, read from the game's own screens: no key blind) |
| `pvpcycle3.ps1` | The same with the host's party at 4, for a third player (`pvpbot.ps1`) after |
| `pvprestore.ps1` | The saves back to the pre-PvP backup, exactly: files the backup lacks are moved aside, not deleted |
| `pvpbot.ps1`, `pvpbots.ps1` | Stand-in players: relay_cli bots joined to the host as guests, each with its own `say.txt` and `heard.txt` |
| `pvpmatch.ps1 [-Step ...]` | A match "here", step by step (lobby, start, a player down, the end), shots at each step |
| `pvpgoal.ps1` | The 1.7.0 goal's checklist: F6 pressed for real opens the page on both; one team stops the start, two let it go; what each player fights with before, in and after a match; a Death match decided by a 60 s clock and finished with F pressed for real; the 120 s clock |
| `pvpteams.ps1` | Three players (the copies and a bot). A: Duel, the host alone against the guest and the bot, a team out only when all of it is down. B: Death, the host and the guest against the bot, no blow lands on a teammate, both winners get the gold |
| `pvpsix.ps1` | Six players (the copies and four bots): the six-row lobby, three a side at their spots, the bars (two teammates, three foes), one side falling one by one, the host's finishing move, the cards, home |
| `pvpmates.ps1` | Teammates' bars in a team match (host and guest against the bot): the blood chunk, then drained, the downed teammate's empty dimmed bar; the fog walls closed by their own collision |
| `pvparenas.ps1` | A match in each boss arena (a save with the four bosses beaten): the trip there, the spots, walls up and the arena's enemies parked, the fight, F pressed for real (the arena boss's finishing move), the cards, the trip home |
| `pvpbeaten.ps1` | That save: on a fresh copy of the late-game save, one copy (co-op off) writes the four arena bosses' spawners dead the way the game does, then a trip has the game save it |
| `pvpbossfin.ps1 [-N 2,3,4,5]` | Each boss's finishing move by number in a real match, frames from both windows, one contact sheet a window a move; `-N 0` presses F for real |
| `pvpdeflect2.ps1` | The deflect window: the guest's figure swings at the host, the host taps the game's guard (bound to K in memory) a set delay after the attack starts on its own screen; what the host's game played, health, posture and the mod's parry, one try a delay |
| `pvpguard.ps1` | The guard as the other side sees it: the host holds the guard while the guest swings into it; the host's figure's montages on the guest, frame by frame |
| `pvpguides.ps1` | The bell's guide lines in a match by the bell: hidden from the arrival, no red thread in the fight or the finishing move (red pixels counted), shown again at home |
| `pvpfair.ps1` | A Duel with a 60 s clock: the gourd in the match (3 of 3, top level, a real drink's heal), TIME when the clock ends round 1, each player's own bar at round 2's countdown, then health and gourd as they were |
| `pvpgourd.ps1 [-Levels 0,6] [-Key 0x52]` | What one drink heals at a gourd level; `-Key` presses the drink for real |
| `pvplevel.ps1` | Whether a blow's damage depends on the defender's own level of the attacker's weapon (PvPvE on, test save only) |
| `pvppve.ps1` | PvPvE after the rename: the F5 > MORE tile clicked (the page's own press, by command) turns both players hostile, enemies stay, the guest's real blows land, a death is scored on both, the tile clicked off again |
| `pvpbadnet.ps1 [-Via '--delay 50 --jitter 10 --loss 1'] [-NoStart]` | A Duel over a bad link (the guest through `relay_cli netem`): each world's fight start every round (the log's "the fight is on"), the guest's real blows, F pressed for real and the move in both worlds, rtt, packets and events a second in co-op and in the match. Starts its own copies unless `-NoStart` |
| `pvptalref.ps1` | A talisman given to the host the game's way (a slot node, AC_Deflect worn), off for the match and back in its slot after, one put on mid-match off again; the guest downed by real blows, round 2's refill the game's way (`game.refillHow`), its own bar and the near-death look, the health home as before |
| `pvpbars2.ps1` | The host's boss bar on the guest's screen: its gold posture strip at full, then at half as the host's posture goes to half; the host's figure made again with one bar still up; none at home |
| `pvpedge.ps1 [-Vk 0x11]` | A Phantom Edge used in a match: the game's own key for it (its bindings read first: Left Ctrl), pressed for real on the guest in front of the host's figure; frames of both windows, the host's health, the figures' weapons |
| `pvprealwin.ps1 [-Id <spawner tail>] [-Map ... -X -Y -Z]` | Whether a boss beaten by a real blow stays beaten across a restart (what the arenas' unlock reads): the late save planted (saves backed up first), the boss's health to 1 and a real blow, its record and its spawner's flag before and after, a trip so the game saves, the copy restarted, the record and the arena again; pvprestore.ps1 after |
| `pvpaudit.ps1 [-Tag zh]` | Every screen a match shows, on both copies, for a look at how it all reads: the F6 page and its picker, each countdown, the fight's bars, TIME and the round's result, a player down and watching, the final round, the deciding blow, PRESS F, the finishing move, the last cards, home |
| `pvpload.ps1` | Two different loadouts picked on each copy's F6 page (its own press): `pvp_preset.txt`, each in hand in a match on its own body and the other's figure, every match weapon at level 30 in both worlds, then each player's own weapons, bag and levels back |

## Helpers

| File | What it is |
|---|---|
| `pvplib.ps1` | Dot-sourced by the others: `Ask` (Lua on one copy, its answer), `Lines` (log lines since), `Shot`, `Key`, `Touch-Lock`, `Load-Copy`. `$script:Repo` is this checkout, `$script:Bench` this folder, `$script:Scratch` the work folder |
| `sheet.py` | A contact sheet of numbered shots: `sheet.py <shots dir> <prefix> <out.jpg> [cols] [width]` |
| `fairprobe.lua` | `FAIR.read()`: what this player fights with now (health, attack, energy, gourd, skill nodes, the loadouts' weapon levels) |
| `guardkey.lua` | `GUARDKEY.bind("K")`, `GUARDKEY.unbind("K")`: the game's guard also on a keyboard key, in this copy's memory only |
| `trig.lua` | `TRIG.arm(path)`: a file written the frame the foe figure's attack starts |
| `parryprobe.lua` | `PARRY.watch(s)`: the defender's montages and hit states through a swing, health and posture before and after |
| `selftrace.lua` | `SELF.watch(s)`: this player's montage, posture and health, a row at each change |
| `metprobe.lua` | `METP.arm(s)`: the first frame of this player's Defence move, against the partner's last move |
| `figabil.lua` | `FIGABIL.watch(s)`: what the foe figure runs (GA_Hun abilities, montage) every frame through its swing |
| `keymap.lua` | `KEYMAP.list(pattern)`: the game's own key bindings |
| `abilprobe.lua` | `ABIL.watch(s)`, `ABIL.seen()`: every ability that runs on this player in that time, by class, and whether `game.isMoveName` sends it (how the edges' `GA_<edge>_*` skills were found) |
| `spar.lua` | `SPAR.start(seconds, gap)`: this copy's player as a sparring partner in every match fight: it steps in to 2 m from the nearest foe's figure and swings every `gap` s or so (a second swing a third of the time), its own health kept up; a `[SPAR]` log line a swing (what the foe played, its own move and posture). `SPAR.stop()` |
| `pvplook.ps1 [-Tag look] [-Copy guest\|host] [-Sync]` | The match screen's look on one copy with no match: `uilook.lua` loads the UI script and arena data again from the dev mod folder (`-Sync` copies the repo's first), then plays the countdown, the winners' and the losers' last screens and the finishing 斩, shot at set moments; a sheet of each (`<Tag>-cd-sheet.jpg`, `-won-`, `-lost-`, `-slay-`) |
| `uilook.lua` | `UILOOK.reload(dir)`, `UILOOK.count(seconds)`, `UILOOK.card("won"\|"lost")`, `UILOOK.slay()`, `UILOOK.stop()`: what `pvplook.ps1` runs |
| `figstate.lua` | `FIGSTATE.watch(s, slot)`: a foe's figure every frame, read only: a `[FIGSTATE]` line at each change of its time dilation, montage, running GA_Hun abilities, hit state; `FIGSTATE.counts()`: its attacks begun and begun again, against the swings its player threw |
