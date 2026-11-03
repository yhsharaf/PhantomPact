# PBZCoop online co-op: how to play, what syncs, how it was tested

## Two copies on one PC: `-allowmultipleinstances`

PBZ refuses a second copy with "Phantom Blade Zero is already running", but its own log says why and how to
turn that off: `[PBZ] Another instance is already running on this machine; exiting. Pass
-allowmultipleinstances to override.` Starting the second copy with that launch option (the game's own switch,
nothing patched) lets two copies run side by side. `tools\netlab\dev.ps1` and `tools\pbz-selftest.ps1` pass it.

Live two-copy test on the old relay, 2026-10-29: one copy in the ASTER second workplace (user Tomato, instance 1, host) and one
in the main session (instance 2, `PBZCOOP_INSTANCE=2`, client), relays on 127.0.0.1:
- each copy showed the other player's Hun (connected, ~16 ms round trip);
- the host's thugs were matched on the client by class + position (different runtime names);
- the client's 6 hits landed in the host's world (sword thug 400 -> 41, hoe thug 340 -> 180), 52 events
  client -> host and 17 host -> client;
- host bell rest -> the client respawned its enemies; host +20 dust -> client 0 -> 20; host material pickup
  -> client 0 -> 1.
Lesson: don't teleport players to far-away areas in a test; with two copies streaming, the floor wasn't loaded
yet and both fell through the world (walk there, or fight near the start).
ASTER isn't needed for tests; it only gives a second person their own screen and input on the same PC.

Single-session two-copy test, same day, no ASTER: `.\tools\pbz-selftest.ps1` started both copies in one Windows
session (copy 2 compiled its shaders once). Host + client connected; the tutorial boss was spawned at the same
spot in both worlds and matched by class + position; the host's boss fight showed the boss bar on the client;
the client's 7 hits drained the host boss's posture step by step (1120 -> 950, mirrored on the client); the
host's kill killed the client's copy.

Status on 2026-11-01 (PBZ build 26266538, UE4SS "UE4SS for Phantom Blade Zero 1.0.1"). The "Verified in game" column
below dates from the old relay, tested with two copies on one PC. Protocol 3 was measured the same way
([NETCODE.md](NETCODE.md)); `tools\netlab\bench\` has the scripts that recheck fights, kills and bell rests, and not
every row has been rechecked. Protocol 3 hasn't run between two real PCs yet.

## Play with a friend

Each player needs their own copy of PBZ, UE4SS + PBZCoop installed, and Tailscale (or any network where the client can
reach the host's UDP port 47800). The steps are in [INSTALL.md](../INSTALL.md): set `Role` and `HostAddress` in
`PhantomPact.ini`, start the game, load a save, or press F5 in the game for the online panel (`OnlinePanel = On`, the default) to host, join or leave with no restart.
`autostart.lua` starts the relay in main.dll and turns sync on once you're in the world. There's nothing else to run.

Link status: `ue4ss\Mods\PBZCoop\net_status.txt`, or the mod command `netstatus`. INSTALL.md explains what its numbers
mean and what to do about them.

## What syncs

| Feature | How | Verified in game |
|---|---|---|
| Friend's character | A real `BP_Renewal_Hun_Young_C` "ghost", steered with movement input along the path `native/timeline.hpp` plays back, so PBZ's own run/walk animations play; snaps if >6 m off | Runs beside you with the real run cycle; follows slopes; stops within ~45 cm. Distances on protocol 3: [NETCODE.md](NETCODE.md) |
| Weapons in hand | The weapon and whether it's drawn go as `W`, and a Phantom Edge weapon as `E`, with `Z` for what its own mesh plays (a cannon opens by a montage). The ghost's own weapons component takes them, so each hangs where it does on the partner. |
| Flowers, shells, thrown blades | The game's bullets, which a ghost's missing abilities can't start. A new one in the game's list goes as a quick `SHOT`, and the ghost fires the same data from the same spot (`bullets.lua`). It looks the same and hits nothing: the ghost's Attack is 0. |
| Attacks, dodges, jumps | Whatever montage the player plays goes as a quick `U` event, and the ghost plays the same one from that point. In PvP, `GA_Hun*` ability activations go as `M` events and the ghost activates the same ability class, because its swings must land | Ghost plays the A/AA/AAA/AAAA light chain, jumps; ~10% of ability replays are refused mid-combo (busy) |
| Enemies (host truth) | Host lists enemies within 60 m of either player (enemy lines: position, health, posture, boss flag), each in turn over 0.1 s. A copy the host lists stops its own AI and follows the host's position (`puppets.lua`), and what the host's enemy starts goes as a quick `A` event | Client copy moves to the host position and drops to the host's health (400 -> 200) and posture |
| Enemies by a guest away from the host | The host's game wakes enemies for its own player alone, so by a guest some way off they stood idle. With two players over 25 m apart, an enemy within the guest's 60 m and 10 m nearer the guest is handed to the guest's game (`RUN <enemy> 1`), where it wakes for that player as the game always does: the guest sends its lines and `A` moves, and the host's copy follows them, held at 1 health. The host's hits go there as `D`; its death comes back as `GK`, and the host's copy dissolves. It's the host's again (`RUN <enemy> 0`) once the two are within 15 m, once it's 10 m nearer the host, or after 2 s with no line. Bosses and one fighting the host stay the host's; two players only | A thug 45 m from the host fought the guest from the guest's game (850 to 450 health in 6 s), the host's copy 0.1 to 1 m behind playing the same attacks; back by the host, six enemies went back to the host's game |
| Client's hits | Client sees an enemy's health/posture drop that it didn't cause and reports `D <enemy> <hp> <posture>`; host applies it | Client hit `D ... 80.0 93.5` reached the host; host took a thug from 400 to 300 HP / 200 to 150 posture |
| Enemy deaths | Host sends `K <enemy>` once; client kills its copy quietly (`Kill(GameLogic)`, which pays nothing: the host's kill reaches the client as shared dust) and gives it the game's death dissolve (`NS_DeathDissolve_001` on each mesh), hiding it as it burns away; the quiet kill alone left it standing frozen. The boss of a fight both are in dies the whole way on the client too (the game's `GE_Kill`): its scene after the fight plays there and its next phase comes from the client's own game | The host's kill dissolved the guest's copy 20 ms later, nobody's dust moved; HookMan's phase scene `Seq023` played on both, then both fought its second phase |
| Clothes | Each player sends what they wear (`LOOK`: outfit, hat, skin colour) when it changes, every 30 s and to someone who joins; the ghost is dressed in it by the game's appearance component (`ApplyOutfitVisual`), held as its configured look, its current outfit set too (the face goes by it), and kept out of this player's save | Host in JiGuanMoQu and guest in MoTian/Climax: each figure in the other's outfit, the outfit's own face too |
| An item's effects | For 3 s after an item's ability starts (`GA_Medicine*`), each new effect on the body is sent (`FX <system> <socket>`) and hung on the ghost's body the same way | The gourd's `NS_Potion_001` on the guest's figure on the host 0.4 s after the guest drank |
| Walk, jog, sprint | The player's gait as their animation blueprint has it goes as `GAIT w|j|s`; the ghost's state is switched to the same (`ActorStateComponent:TryActivateNewState`, with its locomotion's own default tag renamed), since its locomotion has no stick to read | The host's figure walked, sprinted and jogged with its tags and switches |
| Guard stance | `ST 1|0` while the stance's ability runs; the ghost holds the last frame of the stance's enter montage, before its blend out, until it's left | The figure held the guard pose for as long as it was held |
| Chests | A chest opened near a player is told (`O`): the partner's copy switches open without its scene and is posed open (the lid's own animation, glow out, sweep stopped); its loot reaches them as shared items. With `FollowHostStory`, the host also names every open chest it has loaded (`OC`): a guest's copy still shut pays them from the game's level loot table and opens | A gold chest's lid opened on the guest with the host's; a chest the host opened alone paid the guest its 2 items and 441 dust on rejoining |
| Story point (`story.lua`) | The host sends `STORYPT`: which of the 259 quest steps in the game's QA story table its world has done. A guest behind it, 20 s calm after a load, applies the missing steps (and the marks and unlocks between the two points) with the game's `ApplyFlowEvents`, 40 rows a batch; never backwards; `FollowHostStory = Off` stops it | A guest rewound to the start caught up with the host at the story's end: 249 rows, the two worlds' done steps identical |
| Enemies the guest's save killed | A host enemy near the guest with no copy there for 2 s is brought back by its spawner in the guest's world (record turned back for the session, dead again once killed or at the end) | Seven of the host's enemies back on the guest's side within 3 s of syncing |
| Scene skips | A host scene that ends 1.5 s or more before its length was skipped: `SCENE skip <sequence>`, and the guest's same scene ends too (`GoToEndAndStop` on the flow's own player), also one that starts up to 10 s later | The host skipped `Seq023` at 4.6 of 48.7 s; the guest's ended 30 ms later |
| Bosses | Boss = codex `bIsBoss` or the HUD calling `RegisterBossHPBar`; a boss fight sends `B <boss>` and the other side shows the boss health bar | ZuoShang (tutorial boss, 2900 HP) shown with the boss bar; boss health and death synced |
| Aggro on the friend | Host adds the ghost to nearby enemies' hatred lists; ghost does 0 damage itself (hits come as `D`) and stays at full health (the friend's real health is on their PC) | Enemies engage both Huns |
| Items | A pickup next to you that vanishes sends `I <pickup> <itemId>`; the other side removes its copy and gets the same item (shared loot) | Material (`Weapon_Material_01`) pickup -> `I` -> granted on the other side; page, stone, key item and consumable grants each 0 -> 1 with the game's "item acquired" screen |
| Friend down / other map | The state section carries health and a hash of the map name; the ghost hides while they're at 0 HP or on another map | Ghost hid at 0 HP and came back |
| Same enemy on both PCs | Enemy id = `sp:<SpawnerID>` of the level AISpawner that made it, or the spawner's own name where it has no SpawnerID (174 of 180 in Xigu). Designer ids are stable; runtime actor names are not: the same placed character was `_2147476826` in one session and `_2147477757` in the next. An `N` event gives each id a number, and enemy lines carry the number. Fallback: nearest same-class enemy within 20 m | Real tutorial boss spawned by its level spawner shows as `sp:ZuoShangyoung_Seq003` in deaths and boss events. Fallback: a fake host reported a thug as `sp:FAKEID`; the client's local thug (another id) took the host's health/posture (150/60) and its hits went back as `D sp:FAKEID 80.0 60.0` |
| Facing during moves | In PvP, `M` events carry the attacker's yaw and the ghost turns to it before the move. In co-op the state section's yaw does it | Moves sent as `M <ability> 34.5` |
| Hit reactions | Local `HitreactComponent` state changes are sent as `H <tag>`; the ghost's hit state is set to the same tag | Thug hits sent `CharacterState.Hitreact.State.Normal` / `.Heavy`; ghost state followed |
| Bells | A sit runs the bell's `RestoreHealth`, which is hooked: `SIT` goes out, the partner is rested, and comes to the sitter if they're dead, down or watching a fight. Nothing respawns: in this game the dead stay dead. The game mode's `Refresh Monster` runs after a death, and any other run of it (a mod that adds respawns) goes out as `R` too | A real sit traced step by step: three dead thugs stayed dead, and `Refresh Monster` by hand didn't bring them back either |
| Currency | Dust gained locally (not by sync) is sent as `C <amount>` and added on the other PC: shared rewards. Spending isn't mirrored | +40 earned, `C 40` sent, the other side added 40, no echo loop |
| Boss arena fog walls | On `B` the other PC closes `BP_FogDoor_C` within 60 m of its copy of the boss; on that boss's `K` it opens them | Fog wall rose at the tutorial boss arena entrance and opened on the boss's death |
| Who kills an enemy | The client's copies of host enemies are held at `Health_Min` 1; a client hit reaching that floor goes as `D ... L` and the host kills it with the game's own kill effect (`GE_Kill`): the whole death, which pays the host and runs a boss's story, as the host's own blow would; only `K` kills the copy | Client's killing blow: host thug 20 -> 0, client copy died on `K` (tools\pvp\coop-scenarios.ps1); the guest finishing HookMan's first phase: the host's game played the scene after it and started the second |
| Death respawns | The player's `Respawn Refresh Monster` step is hooked: a host death respawn sends `R death` (both refresh), a client's isn't sent (only its world refreshes; it re-kills what the host killed) | Client respawn left the host's half-health boss untouched; the host's later kill reached the client |
| Spectating | 3 s into your death the camera follows the partner's ghost (death screen dimmed), back to you on respawn | View target switched to the ghost and back |

Which PC decides each of these, and how duplicates (double hits, double pickups, echoed events) are prevented:
[AUTHORITY.md](AUTHORITY.md).

Not synced: enemies the host hasn't loaded, which run their own AI on the guest's PC; cutscenes other than those of a
boss both fight (each world plays its own, and a host's skip carries over); dialogue; doors, levers and gates (each
world's own, except kick-stones: `KS` puts the partner's boulder where the kicker's came to rest); walking in the guard
stance (the figure holds the pose and glides); spending currency.

Known limits found in testing:
- Item ids are the `ItemId` field of `DT_InventoryData` rows (ASCII, e.g. `Weapon_Material_01`, `Item_001`,
  `K_07001`, `I_10001`, `Page_XC_04`), not the row names (Chinese display names such as `铸造金属`), which the
  backpack silently ignores. Pickups carry the real `ItemId`, so sharing uses the right ids; tests granted a
  material, a stone, a key item and a consumable (each 0 -> 1, with the game's "item acquired" screen), and a
  material pickup went through the full pickup -> `I` event -> grant round trip.
- Protocol 3 has only run on one PC: over loopback, and through `relay_cli netem` as a bad connection. A real session
  needs the second PC (desktop-gfqd042 on Tailscale) with a Steam account that owns PBZ.

## Protocol

See [NETCODE.md](NETCODE.md): why it was rewritten, what was measured, the packets, the sure and quick lanes and the
events. Protocol 3 came with 1.5.0 and replaced the file-based relay and the JSON packets of protocol 2. 1.4.1 or older
can't connect to it, and a partner on one shows as `partner_version=1.4.1-or-older` in `net_status.txt`.

## Testing

[tools/netlab/README.md](../tools/netlab/README.md) has the test bench: `native\build\relay_cli.exe test` for the
logic, `tools\netlab\bench.ps1` for two relays through a bad connection, and `tools\netlab\bench\` for real game copies
from a separate install, with ready scripts for walking, fights, a bad connection and bell rests.

Mod commands that set up a test in a running copy:

- `spawnenemy <codex row> [cm]` spawns any of the 177 codex enemies in front of you (`codex bosses` lists the 75
  bosses); `spawner <SpawnerID|list>` makes a level spawner spawn its enemy (the game's own path); `enemies`, `items`,
  `bossbar` (starts the boss bar for the nearest boss), `rest` (runs the bell refresh), `fog` (lists fog walls).

## Earlier tests, on the old relay (protocol 2)

These ran on the Python relay. It can't reach the game any more, so its launcher's `-Role record`, `replay`, `echo` and
`loop` and its bot don't work now. What they showed about the game itself still stands.

**Record and replay,** 2026-10-29: the host session (tutorial boss from its level spawner: boss fight, 20 moves, kill, bell
rest, +30 dust, a material pickup) replayed into a fresh client session. The client's boss had another runtime
name (`_2147475370` vs `_2147474438`) and was matched by `sp:ZuoShangyoung_Seq003`; the client showed the boss
bar, closed and then opened the arena fog wall, killed its boss on the host's kill, refreshed enemies on the
bell rest, got the dust (0 -> 30) and the material (0 -> 1), and showed the host's Hun replaying its attacks.
All 25 events arrived.

The other direction too: a client session hitting the spawner boss was recorded (29 moves, 7 hits sent as
`D sp:ZuoShangyoung_Seq003 ...`), then replayed into a fresh host session whose boss had yet another runtime
name: the host applied all 7 hits to its boss (posture 1120 -> 959, exactly the recorded 161) and showed the
client's Hun. Replay can't show either side reacting live to the other, so a bot came next.

**Live test with a bot,** 2026-10-29 (host game + a scripted remote player over UDP, 70 s, while the host also fought):
the bot's Hun ran to and fought each thug on the host's screen; the host applied 57 bot hits, all three thugs died and
each death reached the bot, which switched targets; the host rested at a bell, the bot saw it, the game respawned the
tutorial boss from its spawner and the bot engaged it as `sp:ZuoShangyoung_Seq003`, taking it from 2900 to 1100 HP, live.

**Solo, one game playing both roles:** a 40 s fight against three thugs: 37 moves, 12 hits reported/applied, 3 deaths
synced, no errors. A 30 s regression with everything on: 31 moves (with facing), 8 hits, 4 deaths, 5 hit reactions,
1 boss fight, no errors.

**Each path against a fake peer over real UDP:** the mod as host with a fake client (ghost shown, hit applied, enemies and
deaths sent), and the mod as client with a fake host (enemy pulled to the host position and health/posture, client hits
sent as `D`, host `K` killed the client copy).

## Lessons (PBZ specifics)

- Never hot-reload (Ctrl+R) in PBZ: both crashes on launch day happened at a hot reload with the mod's loops
  running. Hot reload is off (`EnableHotReloadSystem = 0`); reinstall and restart the game instead.
- The net loop runs every frame on the game thread (`LoopInGameThreadWithDelay`), and nothing on it touches a file.
- `APBZCharacter::OnDamage` is called natively: a UE4SS hook never fires. Hits are detected from health drops.
- An unpossessed Hun has `MaxWalkSpeed = 0`; the mod sets it while steering the ghost.
- `IsDead()` stays false at 0 HP during the death animation; health counts too.
- A destroyed actor stays valid in `FindAllOf` until garbage collection but loses its position.
- World subsystems aren't found by `FindFirstOf`; use `SubsystemBlueprintLibrary:GetWorldSubsystem`.
  `PBZSpawnSubsystem` doesn't exist on the prologue map; enemies are spawned by class from the codex table.
- `DataTable:FindRow` / `ForEachRow` work in this UE4SS; codex rows give each enemy's class and boss flag.
- Killing an enemy type the save hasn't met yet (a new codex entry) autosaves the game. Tests only kill the thug
  and the tutorial boss, which the test save already knows; `coop-scenarios.ps1` checks the save's hash. Removing
  `W_PlayerDead` and a real death respawn (`Save Game on Respawn`) autosave too.
- In the prologue, kills pay no dust and drop nothing, whatever the enemy (bandit, scavenger and GuiChai checked):
  loot there comes from scripted encounters. The prologue also never starts a respawn: a real death shows no
  death widget, and the player stays down.

## PvP (`pvp.lua`, `PvP = On`)

**Who decides a hit: the defender.** In each world the partner's ghost is made hostile to the local player
(`FactionComponent:SetFactionRelationOverride(other, Hostile=2, true)` on both) and gets a full stat block
(the ghost spawns with 0/0 health, which counts as dead; it gets a copy of the local player's 223 attributes,
so both fighters are equal, Attack scaled by `PvPDamage`). Its replayed moves then hit the local player through
the game's own combat: damage, posture, hit reactions, block, deflect and perfect dodge all apply natively. Your
hits on the ghost in your own world are only for show; they land in the partner's world.

- **Deaths are real** (since 1.1.1; 1.1.0 held health at 1 with `Health_Min`): a death within 8 s of the partner's
  last hit sends `V lose` and counts as their win; dying to an enemy doesn't. The prologue area never lets the
  player die (`GA_Tutorial_Health_Passive` heals from ~0 to ~690 in 1.5 s), so there the kill is scored but
  nobody respawns. With that heal removed (test only), a PvP death did not run the enemy refresh and the
  partner's enemy stayed alive, but the prologue then never offers a respawn (it isn't built for deaths), so a
  bell respawn still needs a save past the first bell (this save's revive point is "Start", no bell activated).
  A killing blow can land within one tick: a partner swing still in progress also counts as their kill.

## Co-op difficulty (`scaling.lua`)

While the partner's ghost is in this world, every enemy is scaled once: `Health_Max`/`Health` by
`CoopEnemyHealth`% and `Shachi_Max`/`Shachi` by `CoopEnemyPosture`% (default 150/130), keeping its current share.
Both worlds scale the same enemy by the same factor, so the host's numbers (which the guest's copies follow down)
match. Tested: one thug 400 -> 600 health and 200 -> 260 posture in both worlds; the guest's hit (-200) reached the
host and the host's kill reached the guest; co-op e2e still passes.
- **Relay robustness:** Windows refused a rename once (WinError 1450) and killed the old relay. Writing
  `net_status.txt` now retries and skips instead.
- **Parry reward:** the game's deflect leaves the attacker untouched, so the mod judges it on the defender's side:
  the guard (`GA_Hun_*_Stance`, right mouse) was up during the ghost's attack, the defender was within 3.5 m, and
  the swing cost neither health nor posture (a held block costs posture). Then `V parry <posture>`: the attacker
  loses posture and gets a heavy hit reaction (`CharacterState.Hitreact.State.Normal.Heavy`).
- **Hit states set by hand must be cleared** (`clearHitStateLater`, 0.9 s): without the animation that normally
  ends them, a character stays in the hit state and can't start any move (a parried attacker and the ghost both
  got stuck in testing).
- **Other weapons:** a move of a weapon the local player doesn't carry isn't in memory; `playMove` loads it with
  `LoadAsset(classPath)` once. (`KismetSystemLibrary:LoadClassAsset_Blocking` with a hand-built soft path broke
  the mod's command loop; don't.)
- **Attack values far from normal break hits:** Attack 1500 on the ghost made its swings stop registering.
- **Test command `unlockall`:** every weapon (13) and Phantom Edge weapon (20) into the backpack. Weapon ids are
  the folder names under `/PBZCombatAsset/ActorData/Players/Hun/Abilities` (Phantom Edge: `.../ShachiAbility`),
  read with the asset registry (`GetSubPaths`); `ApplyForcedWeaponLoadout(id, level, false)` equips one.

**Tests (two copies, attacks triggered through the mod, defender with real input):** plain hit 850 -> 786, held
block (no damage, posture 300 -> 209), timed parry rewarded (tap 150 ms after the swing arrives; attacker posture
300 -> 240, attacker recovers), Iron Blade light (-64) and heavy (-83) attacks, round end (loser stays alive,
`WON`/`lost` on both, both heal). Not done yet: executions (the ghost's posture is kept full), showing the
partner's guard pose (the ghost can't play `GA_Hun_Young_Stance`), Phantom Edge weapons and weapon skills like
`GA_Hun_Iron_C` (activates but didn't hit; may not be a strike).
