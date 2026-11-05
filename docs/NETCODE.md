# Online co-op: how it works now

Protocol 3 (written 2026-11-01). Replaces the file-based relay and the JSON packets of 1.4.1 and earlier. Both players
need this version.

## Why it was rewritten

Measured on a Ryzen 5900X and RTX 4090, 11 enemies around, nobody connected:

| | 1.4.1 | now |
|---|---|---|
| Sync on, in a crowd | 38 FPS | 54-55 FPS, the same as sync off |
| Sync off, same spot, same run | 60 FPS | 52-54 FPS |
| Game-thread time used by the mod | about 300 ms/s | about 45 ms/s |
| Writing a snapshot on exFAT | 5.2 ms a time | no file at all |
| Positions sent per second | 10 (at 60 FPS; the code assumed 20) | up to 60 |

The lag players felt was mostly the mod slowing their own game: `getPlayer1()` cost a full object search about 110 times a
second, a snapshot was written through files on the game thread, and all enemies were read in one frame. The wrong
snapshot rate also doubled the speed used for prediction, which made the ghost overshoot.

Two real copies on one PC, loopback:

| | now |
|---|---|
| Ghost's distance to the real player, walking | 0-2 cm typical, 33 cm at the 95th percentile |
| Same in a moving fight | 19 cm typical, 36 cm at worst |
| Same on a bad link (100 ms ping, 20 ms jitter, 2% loss, 250 ms stall every 7 s) | 1 cm typical, 35 cm at worst, no jumps |
| Host's kill to the guest's copy | 18 ms |
| Guest's killing blow, there and back | 24 ms |
| Enemy position, host's copy against guest's, standing | 0 cm typical |

## The pieces

- `native/relay.hpp`: the relay thread in main.dll, the Mailbox between it and the game thread, the packets.
- `native/lanes.hpp`: the sure lane (arrives, once, in order, resent by acknowledgement) and the quick lane (sent three
  times, played once, dropped if late).
- `native/timeline.hpp`: plays the partner a little in the past, just far enough that three samples in four are there in
  time, following the connection; the rest of the time it guesses ahead from the sender's own speed, which is also the
  speed the ghost is told to walk at.
- `native/lua_link.hpp`: direct calls from Lua (`api.link`, opened by `openLink` in main.lua). UE4SS doesn't export Lua's C
  API, but it exports its own wrapper class for C++ mods, and that is what's called.
- `mod/PBZCoop/Scripts/coop.lua`: one `tick` every frame. `readPartner`, `steerGhost` and `sendPlayer` run each frame
  (`sendPlayer` at most 125 times a second); enemies take turns over `ENEMY_ROUND_S`; `watchSlowly` runs ten times a second.

Nothing on the hot path touches a file. `net_start.txt` starts the relay, `pp_stop` ends it (the socket closes, the Mailbox
empties, and another start can follow with another role), and `net_status.txt` is rewritten once a second
for people and tools to read.

## Packets

Little-endian, at most 1100 bytes before signing (`MAX_PACKET`), so a signed packet stays under Tailscale's 1280.

Header: marker 0xA3, protocol 3, flags (1 = from the host), session, the partner's session as we know it, sequence, sender's
time in ms, the partner's time echoed back, how long we held it, sure-lane acknowledgement (next id expected, plus a bitmap
of the 32 after it). Round trip comes from the echo, so no ping packets are needed.

Sections follow: state (40 bytes), sure event, quick event, enemy line, hello (version, map, shared settings), and with more than
two players another player (a slot and 40 bytes).

A session is the sender's clock in ms, always moving on, new per `link.reset()`, so a late packet of an older session can be
told from a new start. A packet's sure and quick sections count only if its "partner's session" is ours.
Seeing a new session from the partner restarts both lanes and hands the mod an `S` event.

## Events

`coop.lua`'s header lists them. `sendEvent` picks the lane: U, M, A and H are quick; the rest are sure.

Enemy lines don't carry names: an `N` event gives each enemy a number first.

## More than two players

Only a host with `PartySize` 4 or 6 (or `FourPlayers = On`) runs this (`native/party.hpp`, written from EXACG's design in PR #11). It runs one `Relay` per
guest on one socket, each with its own Mailbox for what goes out, so a guest's end is the same as with two players. Packets go to
the Relay already talking to that address, else a free slot, else one silent for 3 s. All of it is on the relay thread.

| | |
|---|---|
| Hello to a guest | adds `players=4` and `slot=<n>` |
| What the game posts | copied to each guest's Mailbox, or one guest's (`link.send_to`) |
| What a guest says | to the game as `@<slot> <event>`, and to the other guests the same way. `D` stays with the host |
| Where a guest is | to the game by slot (`link.player`), and to the others in `SEC_PLAYER`, at most 60 times a second |
| Status line | adds `players`, `slot`, `guests`, `turned_away`, `upload_kb_s`, `map<slot>`, `other_versions`. `mismatch` covers every guest |

Three guests, bots on one PC:

| | clean link | 40 ms delay, 20 ms jitter, 2% loss |
|---|---|---|
| Host sees a guest behind by, typically | 27 ms | 78 ms |
| A guest sees another guest behind by, typically | 52 ms | 145 ms |
| Host's upload, no enemies | 43 KB/s | |
| With 8 enemies, 20 times a second | 62 KB/s | |
| With 30 | 107 KB/s | |

On the game thread four players cost about a third more calls into the game each frame than two: a ghost's place is read from
memory, and a hidden ghost costs nothing (`luasim.py four` counts them).

## How far behind the partner is shown

Measured with `relay_cli latency` (`native/latency.hpp`): the whole way from the sender's frame to the ghost on the other
screen, in simulated time, against where the sender really was every millisecond. The sender's motion is made from what
recordings of the real game show: starts take a quarter of a second, a stop takes one frame, turns run at about 25 degrees a
frame, frames come unevenly and the mod's tick a few ms into each. Played over loopback, a real recording's partner shows
24 ms behind on the bench and was 23 ms behind in the real game.

Mixed play (runs, sudden stops, turns, footwork, dodges), mean over every RTT of 30/80/150 ms, jitter 0/10/30 ms, loss
0/2/5% and the sender at 30/60/120 FPS; behind as p50 / p95 / p99:

| | 1.6.0 as it was | now |
|---|---|---|
| The path played, behind the real one: RTT 30 / 80 / 150 ms | 59 / 84 / 119 ms | 44 / 69 / 104 ms |
| ... with the sender at 30 / 60 / 120 FPS | 94 / 86 / 82 ms | 87 / 70 / 61 ms |
| ... at the 95th / 99th percentile, all connections | 90 / 92 ms | 74 / 75 ms |
| The ghost on screen, behind, p50 / p95 / p99 | 87 / 118 / 132 ms | 72 / 102 / 116 ms |
| The ghost's speed off the real one, running and stopping, 95th percentile | 70 cm/s | 17 cm/s |
| A sudden stop: how far the played path runs on past it, worst per connection | 0.8 cm | 1.4 cm |
| ... and the ghost | 12.2 cm | 12.6 cm |

Through real sockets and netem (`bench.ps1`), the bot sending every frame: RTT 30 clean 34 -> 30 ms, RTT 80 with 10 ms jitter
and 2% loss 68 -> 64 ms, RTT 150 with 30 ms jitter and 5% loss 122 -> 110 ms (p50). `all.ps1`'s bad link (250 ms stalls
every 3 s): 136 -> 73 ms at the 95th percentile.

What made the difference:

- `sendPlayer` sends every frame, at most 125 a second. The gap of 1/62 s it used to wait after a send skipped a frame in four
  at 60 FPS (the tick's moment in the frame wanders a few ms), and one gap in ten was a whole extra frame for the partner to
  wait out. Above 60 FPS it sent every second frame.
- The Timeline plays just far enough behind that three samples in four are there in time, counting a sample's gap from the one
  before together with its lateness, and guesses the last 3 ms from the sender's speed: a stop slides further than that. It
  used to add the average gap, the 90th percentile of lateness and 2 ms, which also put a stall into the delay for 1.5 s.
- The ghost is told the sender's own speed, eased between samples. Worked out from two samples' stamps it swung by a fifth from
  sample to sample, because the stamp is when the tick ran, not when the game moved the player, and the ghost walks at that
  speed. When the path disagrees with those speeds (the sender carried by something), it's the path's speed.

Tried and not kept:

- Showing the partner where they probably are now (guessing ahead by the whole delay): 5 ms ahead, but every sudden stop ran
  on 31 cm (45 at worst) and walked back; easing the correction over 100 ms changed nothing, the overshoot comes before the
  stop is known. Half of it: 38 ms behind, 8 cm (20 at worst). 10 ms ahead: 5 ms less, the worst stop 1.6 cm further. Every
  ms guessed past the newest sample costs about 0.6 cm at a stop at running speed, once it's past the stop's own slide.
- Leaving the gap between samples out of the delay: 20 ms less, but a stop overshot 18 cm at 30 FPS.
- Through a stall, slowing the guess down instead of running on at full speed: a stall with a stop in it overshoots 15 cm instead
  of 80, but every other stall then stops the ghost and makes it sprint to catch up (its speed off by 490 cm/s instead of 200).
  Stalls are mostly the partner just running on, so the guess runs on as before, for at most 160 ms.
- Sending from the relay thread at a fixed rate: the game has one new position a frame, so a timer only adds waiting. On a
  60 Hz timer the partner showed 11 ms further behind than with each frame sent at once, on a 125 Hz one 5 ms.

Enemy copies (`puppets.lua` carries the host's last line forward from when it was read): measured where a copy is steered to,
10 lines a second today, they show 61 ms behind and run on 19 cm past a stop typically (59 at worst). Carrying the line on by
half the round trip shows them 11 ms behind but doubles that overshoot; 20 lines a second cuts it to 7 cm (45 at worst) at no
delay; 30 a second with half the round trip is 10 ms behind, about as smooth as today (24 cm past a stop typically against
19, 41 cm back at worst against 49). A line rate above 10 is more work for every enemy on the host's game thread each turn,
so that needs the real game's frame time first (`PERF.stages`), and nothing about enemies changed here.

Since then (11-05, six-players): **30 lines a second**, no carrying on. `run_enemy` over RTT 30/80/150/250 ms, 10 ms jitter,
1% loss, six enemy paths each: the delay stays where it was (56 ms behind at RTT 80), and a stop runs on 3-4 cm typically
instead of 18-21 (20 a second: 6 cm), 29-50 cm at worst instead of 67-71. Carrying the line on by half the round trip still
doubles the overshoot at every rate, so it stays off. On the bench host (host and guest copies on one PC, 12 thugs spawned
around the host, `PERF.frames` and `PERF.profile` for 12 s at each rate, twice): `link.enemy` went from about 1,300 calls to
3,500, the enemy work from about 4.5 to 6.8 ms of game thread a second, and the frames didn't move (59-60 FPS, 16-17 ms
typical, 23-25 at the 99th percentile, none over 50 ms at 30 a second). `net.enemyRoundS` overrides the rate from a dev eval.

## Moves over a long, lossy link (11-05)

**A move starts as far in as it really is old.** A move (`U`, `A`, an edge weapon's `Z`) used to start at its position plus half
the round trip from the status line: that missed the wait for the game's next tick (about 9 ms, always), each packet's jitter,
and a repeat sent because the first copy was lost. Now the relay works out each quick event's age when it lands: how long the
sender held it (its age on the wire), how much later this packet came than the fastest lately, and half the shortest round
trip; the Mailbox adds its own wait and hands it over as `~<ms> <event>`, and `net.moveAge()` is what the montage starts from.
Measured through real sockets and netem, the bots knowing the true age from the clock they share (`bench.ps1`, p50 / p95 / p99
of how far off):

| | half the round trip (before) | the move's own age (now) |
|---|---|---|
| RTT 150, clean | 0.9 / 15 / 16 ms | 0.5 / 1.2 / 1.3 ms |
| RTT 150, 10 ms jitter, 2% loss | 10 / 25 / 27 ms | 0.7 / 1.7 / 1.9 ms |
| RTT 150, 30 ms jitter, 5% loss | 11 / 30 / 32 ms | 1.7 / 4.4 / 6.0 ms |
| RTT 200, 30 ms jitter, 5% loss | 14 / 19 / 31 ms | 2.1 / 3.0 / 8.0 ms |
| RTT 250, 10 ms jitter, 2% loss | 6 / 20 / 22 ms | 1.3 / 2.4 / 2.7 ms |
| RTT 250, 30 ms jitter, 5% loss | 10 / 27 / 40 ms | 2.0 / 2.7 / 3.1 ms |

In the real game (two bench copies through netem: RTT 220 ms, 20 ms jitter, 2% loss; `badnet.ps1` with the montages recorded,
`move_report.py`), seven attacks each way: the ghost's montage was 2.7 and 1.4 ms behind the real player's on average, 7.8 ms
at worst. The same moves started at half the round trip would have been 11.6 and 13.1 ms behind, 27.5 at worst: each came 116-135
ms old, against the 110 that half the round trip said. `processEvents` costs 1.0 ms of game thread a second, 0.017 ms a call.

A route slower one way than the other stays a guess for both: no echo can tell which way the time went (a model with one way
taking 70% of the round trip: 30-50 ms off at RTT 150-250, either way). A party's host passes a guest's move on with the age it
has, and the next hop counts on from there.

Enemy attacks don't start further in: an ability replays from its own start on the guest's copy, so the guest sees the whole
wind-up, and a dodge, guard or parry is judged against that copy on their own PC, at any ping. Starting it by its age would cut
up to 125 ms of the telegraph at RTT 250. Only a montage the ability doesn't play, or a later step of a chain, starts by its age.

**A move's three copies go at 0, 40 and 120 ms, not a frame apart.** Wi-Fi loses packets in bursts: one longer than two frames
took all three. Through netem, losing 5% of the time in bursts, 50 moves a second for 15 s each way, RTT 80:

| bursts of about | a frame apart (before) | 40 ms apart | 0, 40, 120 ms (now) |
|---|---|---|---|
| 20 ms | 0 of 420 lost | | |
| 50 ms | 6 lost (1.4%) | 0 | 0 |
| 100 ms | 16 lost (3.8%) | 9 | 0 |
| 200 ms (a stall, really) | 27 lost (6.4%) | 14-15 | 17 |

The same three copies, so no more bytes. A move that only gets through on a later copy starts that much further in, so it's still
in step. The sure lane lost nothing in these runs (it resends after 1.5 round trips plus 15 ms: 194 ms at the 95th percentile
here), so it stays as it is.

**Bandwidth, enemies 30 times a second.** The host's upload (`party-bench.ps1`, bots, 12 s): 3 guests with 8 enemies 61 KB/s at
20 a second, 68 at 30; with 30 enemies 112 and 139. Six players (5 guests) at 30 a second: 153 KB/s with 8 enemies, 265 with 30,
about 2.1 Mbit/s up. Two players with 30 enemies is about 0.5 Mbit/s.

**An enemy line goes when it says something new.** In recordings of real fights 88-99% of enemy samples said what the one
before did (most enemies stand most of the time), and each still went out 30 times a second. Now a line that says the same
as the last goes again only every 0.25 s (`net.enemySameS`), and a changed one at once, so a moving or hit enemy is no later.
The guest lets a copy go after `ENEMY_STALE_S` plus two of those gaps without a line, or one standing still was let go just
before a quiet link counted as quiet. Two players standing by two enemies in the Lua sim: the host's enemy lines 52.8 a
second, 2.1 KB/s, before; 7.2 a second, 0.3 KB/s, now. With the recordings' share of standing enemies, a party's upload in a
fight should fall by most of its enemy part (about 150 of the 265 KB/s with 6 players and 30 enemies; the party bench's bots
send their lines by themselves, so that is worked out, not measured).

**A guest's hit.** The guest's own hit already shows at once on their copy: the game's own flinch, sparks, sound and health bar,
and the bar isn't pulled back while the host catches up (`healTicks`). What waits a round trip is a kill: the copy is held at 1
health till the host says `K`, about RTT + 50 ms (200 ms at RTT 150). Showing a death before the host says so would let a guest
decide one, so nothing changed; a dying pose held till `K` comes is for the real game to try.

**Steam's route.** When Steam relays the connection, the player is told once a game that it adds delay and that SteamDirect = On
on both PCs gives a direct one where routers allow (`status.lua`). Relay against direct ping needs two real accounts.

## Testing

See `tools/netlab/README.md`. `relay_cli test` is the logic, `tools/netlab/bench.ps1` is two relays through a bad connection,
and `tools/netlab/bench\` drives real game copies from a separate install.
