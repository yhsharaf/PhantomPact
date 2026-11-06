# Online co-op test bench

Everything here tests the relay and the sync on one PC.

## No game needed

    .\tools\netlab\all.ps1                                    (all of the below; the last line says PASS or FAIL)
    native\build\relay_cli.exe test
    .\tools\netlab\bench.ps1 -Delay 40 -Jitter 20 -Loss 2 -StallEvery 6 -StallMs 250
    .\tools\netlab\restart-test.ps1
    native\build\relay_cli.exe latency [--path mix|stops|zigzag|circle] [--recording pair.txt] [--rtt 30,80,150] ...

`relay_cli test` runs real relays against simulated connections, broken packets and a fuzz loop, then real sockets. `bench.ps1`
runs two bots through a bad connection and prints true delays, since both share the PC's clock. `restart-test.ps1` is separate
processes: restarts, Secrets, an old partner, garbage, the sure lane at 5% and 30% loss. Bots bind to loopback only, so
Windows' firewall doesn't ask anything.

`relay_cli latency` is the partner end to end in simulated time (`native/latency.hpp`), a grid of connections in seconds: the
sender's frames with the real game's frame noise and the mod's tick a few ms into each, coop.lua's send rule, delay, jitter and
loss, the Timeline, the receiver's frames, and the ghost walking the way steerGhost drives it. Per connection, for the Timeline's
target and for the ghost: how far behind the true path it shows (p50/p95/p99), how far from where the sender is now, from the
true path, a frame's step against the true one, speed against the true speed, and how far it runs on past a sudden stop and
then comes back. `--recording` plays a pair.lua recording's frames instead of the made-up motion (recordings carry no velocity,
so the replay's speeds are as noisy as the stamps); `--send-rate 0` is the send rule before 1.6.0's.

`bench.ps1 -BurstLoss 5 -BurstMs 50` loses packets the way Wi-Fi does, everything for about 50 ms at a time, 5% of the time in
all; `-EventEvery 0.02` sends more moves, to count the ones lost (`quick arrived ... of the partner's sent`). The client's
`quick age off` line is how far the age a move comes with is from its true age, and `half round trip off` how far the guess
before it was. `party-bench.ps1 -Guests 5` is a party of six; `-EnemyEvery` sets the enemy lines' rate (the mod's 30 a second).

### Four players, and two players not changing

    .\tools\netlab\party-bench.ps1 -Delay 20 -Jitter 5 -Loss 1
    python -I tools\netlab\luasim.py four
    python -I tools\netlab\luasim.py two <old mod\PBZCoop\Scripts>
    .\tools\netlab\wirecheck.ps1 -Old <old native>
    python -I tools\netlab\eventcheck.py

`party-bench.ps1` is a host and three guests as separate processes, each guest through a bad connection of its own. `luasim.py`
runs the mod's real Lua with no game: `sim\` is a stand-in for UE4SS, for the game and for the relay, one PC each, four in one
process. `four` checks the rules. `two` plays one story, with PvP and Revive too, on an old version of the scripts and this one, and
every game call, event and log line must match. `wirecheck.ps1` does that for the relay: every packet of a two-player session,
byte for byte, against an old `native` folder. `eventcheck.py` is one handler per event name, and a handler for every event sent:
a second handler on a name quietly drops the first, unless it keeps that one and calls it, as moves.lua does.

`tools\mp-units.ps1` is the one check here that needs the game: on a developer install it puts several player units in a fight
with the `units` command and reports whether enemies hate and hit them and whether the game's error panel appears. With two
accounts, it's the only evidence from the real game for three or more.

### A crash

    python -I tools\netlab\crashdump.py --newest
    python -I tools\netlab\crashdump.py <ue4ss\crash_*.dmp>

UE4SS writes a minidump when the game goes down. `crashdump.py` reads it with no debugger: the exception, the registers, the
call site and the frames on the stack, as module + offset. A call through a null pointer (execute at 0) leaves the caller at
`[rsp]`, and the same call site in several dumps is one bug: three match-start crashes on 11-06 and 11-07 were all
`PBZ.exe+0x153e1a6`, a passive ability started on a player's figure, which had first been put down to something else. Read the
log's last Lua lines before the dump's time with it.

This PC has no Lua of its own, so `luasim.py` needs a Lua DLL: Cheat Engine's `lua53-64.dll` is what it looks for, or name one in
`PP_LUA_DLL`. UE4SS has Lua 5.4, and the mod uses nothing that differs. The stand-in only knows what its author thought of: it
finds wrong names, wrong order and wrong logic, not how the real game answers.

## Real game copies

They run from a separate install, `C:\PBZDev`: junctions to the game's content, its own PBZ.exe, UE4SS, mod and saves. Never
delete that folder recursively: the junction targets are the real game. Remove junctions one at a time with rmdir.

`dev.ps1` has the functions. Copy 1 uses the mod folder, copy 2 its `inst2` subfolder. RETURN is posted to the game's own
window, so nothing takes the focus.

`bench\` holds ready scripts:

| Script | What it does |
|---|---|
| `dev-start.ps1 -Role Host` | Installs this repo's mod and main.dll, starts a copy, waits for gameplay |
| `dev-start.ps1 -Role Guest -Instance 2 -NoInstall` | The second copy |
| `pair-run.ps1 [-WalkOnly] [-FightOnly]` | Walk and fight test on two copies, with a report |
| `combat.ps1`, `shield.ps1` | A real fight; health bars, enemy attacks, ghost distance |
| `together.ps1` | Brings the host beside the guest and walks |
| `badnet.ps1` | The same through `relay_cli netem` |
| `probe.ps1` | One line of state from each copy |
| `weird1.ps1` | Bell rest, sync off and on |
| `fights.ps1 [-From n] [-To n]` | (Skip step 2: it teleports the guest to the world origin.) Boss fights, kills, a death and a revive, with `x.ps1` for single steps and `fights.lua` (`FIGHT.*`) |
| `online-panel.ps1` | The F4 online panel: Host, Join, Leave, a refused Host, swapped roles, with PASS or FAIL per check |
| `rejoin.ps1` | The host quits hard and comes back while the guest plays on |
| `twosaves.ps1 [-Save <file>]` | The guest starts from an older save, as a second account would. The save is put back after |
| `steam-start.ps1` | `Connect = Steam` on two copies: proves the link starts in the game. One account can't reach itself |

`dev-start.ps1 -Role Host` restarts nothing: stop your old copies first. Only ever stop a process whose path is under
`C:\PBZDev`.

### The whole story

The retail build keeps its QA commands: construct `PBZCheatManager` on the player controller (`STORY.gm()`), then
`GM_MoveTo`, `GM_Input attack|heavy|deflect|dodge|stance|switch|interact`, `GM_State preset immortal on`, `GM_SaveGame`,
`GM_LoadGame`. `story.lua` reads the game's chapters, maps, bells and its own story-jump table (`STORY.apply(from, to)`,
659 rows in story order) and travels by bell (`STORY.go`). `walker.lua` and `walker2.lua` play the quests: markers,
dialogues, cutscenes. They can't solve obstacles alone; never force a step with `SucceedBranch`, it breaks the quest chain.

| Script | What it does |
|---|---|
| `tour.ps1` | Every region in order: story events, travel by bell, a fight at each stop |
| `survey.ps1` | Flies the guest over each level and writes down enemies, spawners and fog gates |
| `spot.ps1 [-Start n]` | A real fight, both ways, at each spot chosen from the survey to meet every enemy class |
| `walk.ps1` | The story walker on both copies |
| `boss.ps1 -Row n -Bell x`, `bossrun.ps1` | One story boss from a rewind, or all of them |
| `roles.ps1` | Puts host and guest back through the online panel's commands |

With the host running as a second Windows user, tools must sit where that user can read them: copy `tools/netlab` to
`C:/PBZDev/netlab` and run from there with `TEMP=C:/PBZDev`.

`perf.lua` and `pair.lua` are loaded into a running copy with `eval dofile("<path>")`, and provide `PERF.*` and `PAIR.*`.
`pair_report.py` compares two recordings; `move_report.py` says how far out of step each side's moves showed on the other's
ghost (it needs the montage rows `PAIR.record` writes, and `badnet.ps1` runs it).

Run the game with `Role = Host`/`Guest` and `ThisPcOnly = On` (dev-start sets it), which binds to loopback.

## Rules that keep tests honest and the game safe

- CONTINUE, never New Game. RETURN on the title screen takes CONTINUE when a save exists.
- UE4SS hot reload (Ctrl+R) crashes the game. A script change needs a restart: about 90 s.
- Don't call methods on an empty UObject from eval: UE4SS crashes. Check with `PBZ.valid` first.
- Never keep a player at Health_Min and teleport: a fall through unloaded ground never ends. Hover in flying mode for 14 s
  before landing somewhere new (`PERF.crowd`).
- `FindAllOf` and other full scans don't belong on a per-frame path. Measure with `PERF.stages`.
