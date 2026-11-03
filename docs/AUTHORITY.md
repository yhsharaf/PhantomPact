# Who decides what

Phantom Pact runs two full copies of the single-player game, one per PC. Nothing is shared by default: each game
simulates its own world. The mod then decides, per system, whose copy is the truth and what crosses the network.
The rule of thumb: **sync outcomes, not inputs and not every variable.** A hit is sent as "this much damage",
a kill as "this enemy died", never as raw animation state or per-frame values that the other game already
simulates on its own.

Host = the player whose world is shared (Role = Host). Client = the guest.

## The map

| System | Decided by | Runs where | Crosses the network as | Runs once because |
|---|---|---|---|---|
| Your own player: movement, stamina, healing, items used | **That player** | own PC | state section (position, facing, speed, health), up to 60x/s, newest wins | the other side only steers a ghost toward it, never simulates it |
| Your own hits taken, your death | **That player** | own PC | health in the state section; hit reactions as quick `H` | the ghost is cosmetic: kept at full health on the host, its health shown, never killed |
| Moves (attacks, dodges, guard) | **That player** | own PC | quick `U <montage>` when a move starts (in PvP, `M <ability>`) | the ghost replays it for the animation; the ghost has Attack 0 in co-op, and in PvP its hits on enemies are undone (below) |
| What a player holds | **That player** | own PC | `W <weapon> <drawn>`, and for a Phantom Edge weapon `E <weapon> <drawn>` with quick `Z <montage>` for what its own mesh plays | the ghost's own weapons component is set to it, so it hangs where the partner's does |
| What a player's weapons leave in the world (flowers, shells, thrown blades) | **That player** | own PC, and a copy on each other PC | quick `SHOT <bullet data> <place>`, read from the game's list of live bullets | the copy is the same bullet fired from the ghost, whose Attack is 0: the sender's own bullet did whatever hit counts. Not in PvP, where the ghost's abilities run for real |
| Enemy position, health, posture | **Host**, or the guest's game for one by the guest while the two are apart | host simulates; client mirrors | enemy lines from the host, for enemies within 60 m of the host, or of a client up to 120 m from it. The host's game wakes enemies for its own player alone, so with two players over 25 m apart (together again at 15) an enemy within the guest's 60 m and 10 m nearer the guest than the host is handed to the guest's game (`RUN name 1`): its lines and `A` moves come from there, the host's copy follows held at 1 health, the host's hits go there as `D`, and its death comes back as `GK`. Bosses, one fighting the host within 30 m, and ids not from a spawner stay the host's; it comes back (`RUN name 0`) when the two are together, when it's 10 m nearer the host, or after 2 s with no line. Further off the game keeps them asleep on the host, so those are the client's own (their AI, their health), and a kill reaches the host as `GK` | the copy that follows only ever lowers itself to the runner's numbers (or follows a heal kept for 1 s) |
| Who an enemy goes for | **Host** | host | seen through its moves | the game picks the nearest player every 1.5 s, which flips all the time with two: near both, an enemy now holds a target for 15 s, then turns if the other player hit it (`game.steerFocus`) |
| Enemy AI (which attack it throws) | **Host** | host; the client replays it | quick `A <enemy> <ability> <montage> <position> <host, guest or ->`, the last being who it's aimed at (a slot or -, with more than two players) | a copy the host lists has its own AI stopped, and stopped again every 0.1 s, since the game restarts it by itself. An ability replays for real, so its hits land on the guest and guard, parry and dodge work as usual. Enemies the host hasn't loaded keep their own AI on the guest's PC |
| Client hits on enemies | **Client detects, host applies** | client measures its copy's drop, host applies it | sure lane: `D <enemy> <hp> <posture>` | event ids are acknowledged and played once; in co-op lost health is always the client's own hit, and a posture drop alone that follows the ghost's replay is undone, not reported; in PvP any such drop is undone |
| Enemy death | **Host** | host | sure lane: `K <enemy>` | the client's copies of host enemies are held at 1 health (Health_Min) so they can't die on their own; a client hit that reaches that floor is sent as lethal (`D ... L`) and the host kills with the game's own kill effect, the whole death (it pays the host, writes the kill down and runs a boss's story); only `K` kills the copy, once, even if it loads later. An enemy that dies on the client before the host has it loaded is reported with `GK` |
| Enemy spawning | each world's own level | both | not synced (both load the same level) | matching pairs the two copies (spawner id, else class + position). One exception: a host enemy near the client with no copy there for 2 s (the client's save killed it long ago) is brought back by the client's own spawner, its record turned back only until it dies or the session ends |
| Story point | **Host** | both: each world keeps its own story | sure lane: `STORYPT <steps> <check> <point> <done>`, on link and when it moves, every 60 s anyway | a client behind it applies the steps it lacks with the game's own `ApplyFlowEvents`, at a quiet moment, never backwards; a different story table (another game version) is refused |
| A boss's death and its scenes | **Host** (its `K`) | both run the death | `K <boss>`; sure lane: `SCENE skip <sequence>` | the client's copy of the boss of a fight both are in dies the game's whole way, its loot rolled at level 0, so each world plays its own scene and next phase; a host scene that ends early ends the client's same scene |
| An enemy the client's save has and the host's hasn't | **Host**, near the host | client | `HAS <enemy>`, answered `NOT <enemy>` | each player keeps their own save. Within 60 m of the host, a client's enemy from a spawner that the host doesn't list for 3 s is asked about, and the host looks through all it has loaded. On `NOT` the copy steps aside: hidden, its AI stopped, its collision off, not killed, so the client's save keeps it. It comes back when the host moves on or turns out to have it. Bosses stay |
| Boss fight start | **whoever starts it** | both | `B <boss>` | the receiving side shows the bar and closes the fog walls; its own hook ignores the mirrored start, so it never echoes |
| Boss fight going on | **each player**, for their own game | both | sure lane: `F 1` or `F 0`, on each change and every 5 s in a fight | a player who dies in a boss fight waits for it to end; only the partner's own game can say it's still on |
| Boss phases | **Host** (through health) | both run the boss's own phase logic | host health in enemy lines | phases follow health; a heal on the host reaches the client after 1 s instead of being ignored |
| Sitting at a bell | **whoever sits** | both | sure lane: `SIT` | a sit heals, fills the gourd and saves, and nothing respawns: the game's dead stay dead. The bell's `RestoreHealth` is hooked. A partner who's up is rested (health through any loaded bell's `RestoreHealth`, the gourd by hand), one who's down gets up, and one who's dead or watching a fight goes to the sitter once they're up. The sitter's fight is over for everyone, a leftover bar included |
| A refresh with no death (a mod that adds respawns, the `rest` command) | **whoever's world ran it** | both | `R bell` | the game never does this itself; the receiver's refresh is flagged as mirrored, so it isn't sent back |
| Death respawn | **the one who died** | own PC (the game refreshes your world) | host: `R death`; client: nothing | a client's death leaves the host's world (and fight) alone; the client re-kills what the host killed. `R death` keeps what the host killed too: what comes back is up to each spawner, a boss yes, a camp of thugs no, and the host's enemy lines say which |
| Host loads its world again (restart, or title screen and back) | **Host** | both | `Y <world>` | a new world has everything alive again, so the client's refreshes too and forgets what the host killed; a Leave and Host in the panel keeps the same world |
| Pickups | **whoever picks it up** | own PC | sure lane: `I <pickup>`, the item by `T` | the other side removes its copy; if both grabbed it in the same moment, nobody gets a second one |
| What the game gives | **whoever got it** | own PC, then the other's | sure lane: `T <item> <n> <kind>` | the backpack's own ways in are hooked (medicines and accessories: their lists are read every 5 s), so the partner gets the same items at any distance, whatever they came from. Not what's bought or made, nor what the mod itself adds. The same thing given on both PCs within 15 s stays one each |
| Chests and rubbish piles | **whoever opens it** | own PC, then the other's copy | sure lane: `O <name>` | each world has its own copy, named alike. The items go by `T`; the other copy only stops paying: a chest counts as opened, a pile is removed. Not loaded there: when it loads. A chest locked until a boss dies can't be opened by either. A pile removed this way comes back in a later session, so it could pay that player once more |
| Dust (currency) | **whoever earns it** | own PC | sure lane: `C <amount>` | amounts the mod added for the other player are excluded from what it sends back |
| Kill loot | **Host** rolls it | host | dust via `C`; the client's items via `I loot:<enemy>` | the host's own kills roll natively; a client's killing blow (the host's `Kill()` skips the roll) is rolled by the host once, with the game's own table and the enemy's level. Items go to both players, whoever kills it. (In the game's combat table, all 207 enemy kinds drop dust only: items come from chests and pickups) |
| PvP (duels) | **the defender** | each player's own PC | `V lose`, `V parry` | the loser's own PC decides the death; scores move once per death |
| Events in general | sender | | sure lane or quick lane, numbered per session ([NETCODE.md](NETCODE.md)) | sure: resent until acknowledged, played in order, once each. Quick: sent three times, played once, dropped if late |

## The duplication cases, one by one

**Duplicate enemy damage.** Your swing hits your copy of the enemy. That drop is reported once (`D`) and applied
once on the host. Your ghost in the other world replays the swing for show. In co-op the ghost's Attack is 0, so it
does no damage (measured: 600 to 600 health). In PvP the ghost needs a real Attack to hit the other player. Its
hits on enemies did land (measured: 600 to 536, and they were reported as the receiver's own). Now, in PvP, a drop
that follows a ghost replay, with no local move started, is undone instead of reported, on the client for every
copy and on the host. In co-op only a posture drop on its own is undone that way: with Attack 0 the ghost takes no
health, and a charged swing can land after the 1.5 s the check looks back, so lost health is always reported.

**Duplicate item pickups.** Both players can grab the same item in the same 100 ms. Each then also receives the
other's `I`. The pickup you took yourself is remembered per map, and the other's `I` for it then only removes
nothing and grants nothing.

**Duplicate enemy spawning.** The mod spawns no enemies. Both games load the same level, and the client pairs
each host enemy with its own copy. Bell refreshes are mirrored once (`R`), never echoed back.

**Conflicting player movement.** Each player is only ever moved by their own game. The ghost walks toward the
received position and is the only thing moved by the network. Ghost collision ignores pawns, so it never pushes.

**Repeated animation events.** A move is sent when it starts, not every tick. A hit reaction already playing
on the ghost isn't restarted by the same hit arriving over the network. On the host, enemies hit the ghost too.

**Desynchronized boss phases.** Phases follow health, and the host owns health. Before, the client only ever
lowered its copy, so a boss that healed in a phase stayed low on the client and could die there first. Now a heal
the host keeps for a second is followed, and the client's copy can't die before the host's anyway.

**Multiple executions of the same game event.** Every event has a session and an id. A sure event is resent until
acknowledged and played once, in order; a quick one is played once or not at all. A killing blow on the client doesn't
kill its copy locally (Health_Min 1). The host's
`K` does, so death animations, drops and boss-beaten logic run once per world, at the host's word.

## Pausing

With a partner linked the game never pauses: the other world goes on, so a menu here is a menu in a live world. The
online panel doesn't pause, and a pause by the game (its menu) is undone at once. With nobody linked it pauses as usual.

## Deaths, spectating, and the boss fight

- **You die (either role):** the death screen plays. After 3 s, the camera follows your partner while they're
  up and on your map. It comes back to you when you respawn, or sooner if they go down too. The death screen is
  dimmed, not removed: removing it would run the game's monster refresh.
- **Dying in a boss fight your partner is still in:** the respawn waits. The death screen's tick is stopped (`NotTick`), so you keep watching until the boss dies, your partner dies too or leaves, or 15 minutes pass; then it goes on from there. Anywhere else the wait could have no end, so the respawn is the game's own. PvP isn't held.
- **The client dies while the host fights a boss:** the client's game respawns it at its bell and refreshes the
  client's world, as single-player would. The host's world isn't touched, so the host's boss fight goes on. When
  the host wins, `K` reaches the client and kills its copy of the boss. Enemies the host had already killed are
  killed again in the client's refreshed world.
- **The host dies while the client fights a boss:** the host's world is everyone's truth, and the host's game
  refreshes it. So both worlds refresh and the fight starts over, as when the host dies in Elden Ring co-op.
  Until the host respawns, the host's boss keeps fighting the client's ghost, and the client's hits still land.
  The client can finish the boss in that window.

- **Your partner vanishes** (quits, crashes, loses the connection): after 12 s with nothing heard (longer than a loading screen), their ghost
  hides instead of standing frozen. Fog walls closed for their fight open, and the enemies held for the host go
  back to normal.

## More than two players (beta)

`FourPlayers = On` on the host, or 4 PLAYERS under MORE in the panel. Only the host's setting counts: its relay tells each guest
in the hello (`players=4`, `slot=<n>`), and a guest follows that, whatever its own ini says. With it off the code below never
starts, and two players' packets and game calls are the same as without it (`tools/netlab/wirecheck.ps1`, `luasim.py two`).

A slot says who's who: 1 is the host, 2 to 4 the guests in the order they came. The colours go with the slots, the same on every
PC: purple, green, gold, blue. Red still means down.

It's a star: a guest only talks to the host. The host runs a whole relay for each guest (`native/party.hpp`), so each has its
own session and lanes, as with two players. What a guest sends reaches the host's game and the other guests as
`@<slot> <event>`. Only the host's relay writes that tag, so a guest can't speak for another. Where a guest is goes on from the
relay thread, so a host stuck in a load doesn't stop it. `D` goes to the host alone. `S` from a guest stays with the host, which
tells that guest what's dead (`K`, for it alone) and everyone that someone's new (`J`): they tell it what they hold and any fight.

| What | With more than two |
|---|---|
| Enemies | The host runs them, as ever: those near it, and near any guest up to 120 m from it. None is handed to a guest's game as with two players: a guest's enemy lines don't reach the host here |
| An enemy past that | Nobody owns it. It sleeps on the host, so a guest there fights a copy of its own, as a guest alone does, and two guests by it fight one each: their hits stay on their own copy. A second authority on a guest would be a second way to be wrong. The first kill counts: `GK` reaches everyone and their copies die. Only for an enemy that player hit, since a copy can read as dead for other reasons |
| Who an enemy goes for | It holds one player for 15 s, however many hit it, then turns to whoever hit it last of the others near it. That's once in 15 s at most. To turn, everyone else leaves its list for that moment |
| Who it's aimed at | The slot, in `A`. The guest it's after aims its copy at itself, the others at that guest's ghost |
| Hatred | Each ghost goes on an enemy's list on its own account. A hidden one comes off every list and can't go back on, and the others stay |
| Dying in a boss fight | You wait while a partner who's up and here has a boss bar, so until the boss dies or everyone else is down. The camera moves on if the one you watch goes down |
| Joining during a fight | Anyone's `F` counts, and the fight may not be the host's. A joiner gives it 2.5 s to be heard of, and everyone tells again on `J`. You watch whoever's in it, and go to the host when it's over |
| What anyone gets | `T`, `O`, `C`, `I` and bells reach everyone, once. The same thing from two senders within 15 s is one thing here too. Two from one sender are two. A guest's death stays its own: only the host's `R death` goes out |
| Enemy health | Each person connected adds what the first did, wherever they are: 150/130 with one, 200/160 with two, 250/190 with three. It only goes up, on the host, where guests' copies follow: a boss mustn't lose health because a player left, and a copy that lost health would look like a hit. Someone who joins during a boss fight only watches, so that boss keeps its number until the fight is over. New enemies get the number of the moment |
| F3 | The nearest partner who's up. With nobody on your map a guest goes to the host, and a host to its first guest who's up: those are the maps the relay can name |
| Someone leaves | A guest: their ghost hides on every PC, the others play on, and walls closed for a fight they started open, whoever else shows its bar, as those bars are copies of the same fight. The host: it's over for everyone, as nothing passes between guests but through it |
| PvP, Revive | Off. Each has one ghost to fight or one partner to bring you back |

Known limits: positions between two guests go through the host, so they take two trips. Settings and versions are compared with
the host: a host's status names each guest on another version, and a guest's shows only its own difference with the host. A
guest can only go by F3 to another map if it's the host's, since that's the only map name it's told.

## What can't be checked in the prologue

The tested save is in the prologue. The game blocks respawns there (`RespawnSequenceBlockTag`, "first teleport
into the ambush forest"), and kills there pay no dust. Checked by calling the respawn's own refresh step, not by a
real respawn:

- a real death respawn that refreshes the world. Checked instead (tools\pvp\respawn-check.ps1, with the save
  restored after): real PvP deaths on both sides, spectating on a real death, and the game's own `Respawn` bringing
  the player back (850 HP, camera back). UE4SS hooks also see calls made inside blueprints: `Respawn` calling
  `Respawn Recover Attributes` and `Respawn Set Transform`, and `Respawn Refresh Monster` calling the game mode's
  `Refresh Monster` (which is what tells a death from a bell rest). In the prologue `Respawn` skips the monster
  refresh and the save. Elsewhere that step exists to refresh monsters, and its path into the mod is verified.
- kill loot on a real later-game enemy. What was found instead: a native kill rolls the enemy's loot table
  (`GetCombatLootDataForOwner`, owner = the dying enemy, at its `Level` attribute). The host's `Kill()` for the
  client's killing blow skipped that roll, so the kill paid nobody. The host now rolls the same table itself, once:
  dust goes to the host and reaches the client as shared dust, and items go to the client, who made the kill.
  Prologue enemies are level 0, which pays nothing. At a forced level 1 the table paid 99 dust (146 at level 3,
  270 at level 10), and the scenario test checks that the client's kill pays both players the same amount.
- whether a boss killed by reported damage counts as beaten for the host's save

## Who may talk to the relay

There is one relay: the C++ one inside the game (`native/`, main.dll). It parses packets from the network inside the
game process, so every read checks that the bytes are there, and a cut-off packet or an unknown section ends that packet.

Raised by appdoze (issue #1 / PR #2) and reworked from their code:

- **Sender filter.** The host relay only takes packets from addresses a partner can have: Tailscale, home networks,
  this PC, and Hamachi/Radmin. `AllowAnyAddress = On` in the ini lifts the filter, for virtual LANs with other address
  ranges (UU Accelerator's multiplayer, ZeroTier). A guest only listens to its host's exact address and port. A host
  stays with its partner, and takes another sender only after 3 s of silence. Refused packets count as `filtered=` in
  net_status.txt.
- **Optional `Secret`**, the same on both PCs. Every packet is HMAC-signed with a scrypt-stretched key, and the
  relay refuses a packet when:
  - it is unsigned, or its signature is wrong;
  - it comes from its own role or session (bounced back at its sender);
  - it is more than two minutes old or ahead;
  - its counter was already seen from that session, or is more than 64 behind the newest (a replay). A packet the
    network merely reordered still counts.

  Without a secret, signed packets are refused too, so a mismatch never half-works. Refused packets count as
  `rejected=`. The relay reads the secret from the ini itself; it never appears on a command line.
- **Event values.** NaN and infinity are dropped. Dust and damage are capped per event, and the cap is checked
  before the lethal flag turns a hit into `math.huge`.
- **One bad packet can't kill the relay.** Cut-off packets, event ids far ahead, odd timestamps, positions that aren't
  numbers and floods are all handled: at most 256 packets are read per receive, and what waits for the game is capped
  at 1 MB.
- **Settings handshake.** Each relay tells the other its mod version and the settings both should share. Any
  difference shows as `mismatch=` and as an in-game tip. The partner's values are cleaned before they go into the
  status line. A partner on another protocol shows as `partner_version=1.4.1-or-older` or `other-protocol`, and
  nothing else from them is used.
- **`eval`** in cmd.txt runs only with dev.txt or `PBZCOOP_DEBUG=1`. The developer install creates dev.txt, and
  the release zip has none.

## Executions and late joins

- **Executions** (`GA_SimpleExecution_Young` and the other execution abilities) aren't replayed as abilities. A
  paired execution would grab the other world's copy of the enemy and could hit it a second time. Its montage goes
  as `U`, so the ghost shows the animation alone. The partner sees the enemy fall when the host's `K` arrives.
  Measured: five client swings took a thug from 600 to 68 in both worlds, with five reports and five applied.
- **Joining late or rejoining:** the sure lane keeps each event until the partner acknowledges it, the newest 8192 at
  most. A first join mid-session plays what the host sent before it joined, once: deaths (`K`), rests, shared items and
  dust. That's the same "shared rewards" rule, applied late, not a duplicate. A rejoin gets only what it hadn't
  acknowledged. Either way the partner's new session restarts both lanes and reaches the mod as `S`: the host names
  its enemies again (`N`) and resends `K` for every enemy it has killed since the last rest. A host that loaded its
  world again says so with `Y`, and the client's enemies respawn: what the client saw die is alive on the host again.

## Known limits

- Some enemies come back with a map load but not at a bell. If the host loads its world again after the two killed one,
  it's alive for the host and missing for the guest until the guest loads the map too: the host fights it alone. Seen
  with two fire fighters in Xigu, of 13 enemies around.
- If both players swing at the same enemy within the same 1.5 s in PvP, the ghost's replay can't be told from your
  own hit, so that drop is reported. It's harmless outside PvP, where the ghost does no damage.
- Enemies the host hasn't loaded run their own AI on the guest's PC until the host lists them. A listed copy follows
  the host's position and jumps there past 10 m.
- `Connect = Steam` is tested up to Valve's network: the relay reaching Steam inside both games. Two real accounts
  haven't connected through it yet, so protocol 3 hasn't been measured over it. Steps are in
  [STEAM_TEST.md](STEAM_TEST.md). `SteamDirect = On` passes over Steam's own networking setting to try for a direct
  route, so a partner can see this PC's IP. It's off by default for that reason. Only friends get a session.
- Over Steam, the relay's session handling runs on code the tests can't reach, since it needs a running game.
- Protocol 3 has only run on one PC so far ([NETCODE.md](NETCODE.md)), not between two real PCs.
- More than two players has never run with more than two game copies: only with bots and with the mod's scripts on a stand-in
  for the game ([tools/netlab/README.md](../tools/netlab/README.md)).
