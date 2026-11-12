# Phantom Pact 1.7.2: online co-op for Phantom Blade Zero

Play the campaign with a friend: you see each other as a second Soul, fight the same enemies and bosses, and
share loot, dust and bell rests. The host's world decides enemies, bosses and deaths; the guest's world follows.

Fan-made, unofficial. Each player needs their own copy of the game on Steam. No game files are modified or shared.

**Found a bug?** Post in the Bugs tab on Nexus Mods or open an issue at
https://github.com/yhsharaf/PhantomPact/issues. [What to send](#what-to-send-in-a-bug-report) is at the end of this
guide.

**Two players on one PC?** It's in this same download: in the game press F5, then MORE, set Mode to LOCAL and restart
the game. Plug in two pads, and read `Phantom Pact - LOCAL CO-OP.md`, next to this guide, for player 2's controls and how to
set up pads. It is in testing. (`Role = Local` in `PhantomPact.ini` does the same. F4 > MULTIPLAYER goes back, from the next
start.)

## What you need (both players)

1. **Phantom Blade Zero** on Steam.
2. **UE4SS for Phantom Blade Zero** by Vercadi (Nexus Mods), version 1.0.3 or newer, installed in `PBZ\platform\steam`.
3. **Tailscale** (tailscale.com), both signed in to the same network.

You don't need Python: the connection runs inside the game (`PBZCoop\dlls\main.dll`). Its source is in the GitHub
repository (`native/`).

**Both players must use the same version.** 1.5.0 has a new connection, and 1.4.1 or older can't connect to it.

## Install (both players)

1. Open the game folder: Steam > right-click the game > Manage > Browse local files.
2. Extract everything in the zip into that folder (the `PBZ` folder) and say yes to merging folders, and to replacing
   files. The mod lands in `platform\steam\ue4ss\Mods\PBZCoop`. Two small files also go into
   `platform\steam\ue4ss\UE4SS_Signatures` (`GNatives.lua`, `GUObjectArray.lua`): Phantom Pact's own, which let UE4SS
   start on the game as it is since the November 4 update, and on the build before it.
3. Open `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini` in Notepad:
   - **Host:** change `Role = Off` to `Role = Host`
   - **Guest:** change `Role = Off` to `Role = Guest`, and set `HostAddress` to the host's Tailscale IP (it starts
     with 100.; the host sees it in the Tailscale app)

   Or skip this file and use the panel, below.
4. Start the game and load your saves, the host first. Co-op starts by itself once you're in the world.
   The first time you host, Windows asks whether the game may use the network: click **Allow**. That window can open
   behind the game, so Alt+Tab if the guest can't connect.

The UE4SS console shows `Phantom Pact Host: co-op on` (or Guest), and
`ue4ss\Mods\PBZCoop\net_status.txt` shows `connected=yes` once you're linked.

**Steam Deck and Linux.** UE4SS starts from a file it puts in the game folder, `dwmapi.dll`, and Proton uses its own
copy of that file unless told otherwise, so UE4SS and the mod never start. In Steam, right-click the game > Properties >
General > Launch Options, and paste:

    WINEDLLOVERRIDES="dwmapi=n,b" %command%

Then install UE4SS and the mod as above, into the same folders: Browse local files opens the game folder in the file
manager (on a Steam Deck, in Desktop Mode). We haven't tried it on a Steam Deck ourselves yet: tell us how it goes.

**Easiest: the panel.** In the game, press **F5** to open the online panel, with no text file and no restart. Pick
Steam (nothing to set up: it finds your friend who's hosting), Tailscale, or Other Network, then press Host or Guest.
For Tailscale and other networks, copy the host's address and press Paste. Tailscale also covers Hamachi, Radmin and
a home network; Other Network is for ZeroTier and UU Accelerator. If you want a password, copy it and press Paste
password on both PCs before you connect. English, 中文 and العربية (Arabic) at the top of the panel switch the language of the panel
and the co-op messages. Your choices are kept for the next start.

**MORE** opens the settings: TP > Partner, PvPvE, your partner on the map and Steam Direct, each ON or
OFF, Players (2, 4 or 6), and Mode: MULTIPLAYER, or LOCAL for two players on this PC. Mode works from the next time you start the
game. **Skip Prologue** is red while you're in the prologue: the game skips it itself, when you start a New Game and
choose its skip. A player who did that gets the healing gourd from the host on joining. It's green once you're past the
prologue. Revive is coming soon. With a partner, the game is on Hellwalker at least (see [Co-op difficulty](#co-op-difficulty)),
and enemies get extra health and posture on top of it.

**Going to your partner.** Joining takes you to the host once, even on another map, so a friend with a new save can
join a host further into the story. Your save stays where you land, so your own story can get ahead of where you were.
After that, **F3** takes you to your partner if you turn TP > Partner on under MORE. It's off by default, because it's a
lot of power to have on one key. Neither works during a boss fight, a cutscene, a duel or a menu, or while you or your
partner are down.

### 4 players (Beta) and 6 players (Experimental)

Players under MORE is 2 by default, and with 2 nothing changes. Pick 4 before you press Host and up to three guests can join;
pick 6 and up to five can. Only the host's choice counts: guests follow it, whatever theirs says. It works from the next Host
(`PartySize = 4` or `6` in the ini does the same; the older `FourPlayers = On` still means 4). Everyone joins as they would with
two players, and everyone needs the same version. Neither has been played by that many people yet: tell us what breaks.

**Ghost twins (6 players).** With five or six connected, every enemy and every boss near a player gets a twin: a cyan, see-through
copy of itself with red eyes, fighting beside it. Two bosses in each arena, twice the enemies. A twin is hit, killed and seen
the same on every PC. A boss's twin fades when the boss dies, and the story goes on as always. An enemy's twin lives until it's
killed. A rest at a bell clears the twins, and the enemies that come back get new ones. `GhostTwins` in the ini sets how many
players it takes (5 by default) or turns them off (`GhostTwins = Off`). Only the host's setting counts.

With more than two players:

- Each player has a number and a colour, the same on every PC, on the map and in the tips: the host is purple,
  player 2 green, player 3 gold, player 4 blue, player 5 orange, player 6 pink. Red still means down. The panel says how many are connected and who you are.
- F3 goes to the nearest partner who's up. If nobody's on your map, a guest goes to the host.
- Enemies get more health and posture for each person connected: see [Co-op difficulty](#co-op-difficulty).
- Die in a boss fight and you wait until the boss dies or everyone else is down too. The camera moves to someone who's still up.
- What anyone gets, everyone gets, and if two of you are given the same thing at once it counts once.
- If a guest drops out the others play on. If the host leaves, it's over for everyone.
- Enemies are shared near the host, and near a guest up to 120 m from the host. Further off the host's game leaves them
  asleep, so each guest out there fights a copy of their own, and the first kill counts for everyone.
- PvPvE and Revive stay off. PvP matches (F6) work with up to six, in two teams.
- The host sends about 50-100 KB/s with three guests, so a slow upload will show.

- **Updating:** both players update. Extract the new version over the old one, then set `Role` / `HostAddress` again.
  What an older version left in the `PBZCoop` folder (the `relay` folder, and `net_in.txt`, `net_out.txt` and the
  `net_events` files) isn't used any more; you can delete it.
- **Playing alone:** set `Role = Off`.
- **Uninstalling:** delete the `platform\steam\ue4ss\Mods\PBZCoop` folder.

## Other ways to connect

- **Hamachi, Radmin, ZeroTier, UU Accelerator's multiplayer:** any virtual LAN works. The guest puts the host's
  address from that app in `HostAddress` (leave `Connect = Tailscale`: it just means "connect by IP"). If the app
  hands out unusual addresses (UU, ZeroTier), the host also sets `AllowAnyAddress = On`.
- **Steam:** both set `Connect = Steam`; the guest joins a Steam friend who's hosting. No Tailscale needed. You must be
  Steam friends, and the host must show as in the game, so not Invisible. The guest leaves `HostAddress` empty or puts the
  host's Steam name, or their SteamID64 (17 digits) if they're Invisible; an IP address there is ignored.
  `SteamDirect = Off` (the default) leaves it to Steam's own setting, which normally means Valve's relays: your IP stays
  hidden, with more delay. `On` tries for a direct connection, the quickest, and your partner's PC can then see your IP
  address. A direct connection needs `On` on both PCs.
- **Secret (optional):** the same password in `Secret =` on both PCs, or Paste password in the panel, signs every
  packet, so nobody else on the network can join. Recommended with `AllowAnyAddress = On`.

## On screen

- **Map:** your partner is a jade copy of your own map marker, turned the way they face, when you're in the same
  area (red while they're down). Turn it off with `PartnerMapIcon = Off`.
- **Tips:** short messages when your partner connects, drops, goes down or wanders far off, and when something is in
  the way: no answer from the host, a refused `Secret`, different versions or settings, a high ping.
- **When you die:** after a few seconds the camera follows your partner until you respawn.

## Co-op difficulty

While someone plays with you, online or on this PC, the game's own difficulty is Hellwalker: a player on Wayfarer or
Pathbreaker is raised to it, and their own pick comes back 20 seconds after they're alone again (after a crash too, the
next time they play alone). 66 Days stays 66 Days. Set `CoopDifficulty` in `PhantomPact.ini` to Pathbreaker, Wayfarer or
Off to change that; each PC uses its own setting. A PvP match (F6) is Hellwalker for everyone whatever the setting, so
nobody gets an easier guard; 66 Days stays 66 Days there too, with Hellwalker's perfect deflect window for the match.

Like Elden Ring, enemies and bosses get tougher while your partner is with you: 150% health and 130% posture by
default, and bosses twice their posture (the guard bar), so their guard breaks about as often as when you're alone.
Change `CoopEnemyHealth` / `CoopEnemyPosture` and `CoopBossPosture` in `PhantomPact.ini` (percent; 100 = normal). Both
players should use the same numbers.

Bosses also have super armour while your partner is with you online (`CoopBossArmor = On`): a hit doesn't make a boss
flinch, knock it back or cut its attack short, so two players can't keep it stuck and it keeps fighting. Breaking its
guard still staggers it, and you can still execute it. `Off` = no super armour: bosses flinch at hits as the game has
them. Both players should use the same setting. (With it Off, `CoopBossPoise = 200` makes a boss take half the poise
damage, which the game uses to knock it out of a move; 100 = normal.)

Your partner's swings and hits sound on your screen too, as your own do (`PartnerHitSounds = On`): your game plays
the sounds of their swing (the whoosh, their shout) as their figure swings, hit or miss, and each game tells the other
what its hits play (the hit sound and blood). `Off` = their swings and hits stay silent on your screen, and your hits
on theirs. Both players should use the same setting.

Bosses have their own numbers: `CoopBossPosture` (200) and `CoopBossHealth` (left out; either one with a `;` in front,
bosses take `CoopEnemyHealth` or `CoopEnemyPosture`). And how hard things hit you while your partner is with you:
`CoopEnemyDamage` for enemies,
`CoopBossDamage` for bosses (percent; 100 = normal, 150 = half as hard again, 50 = half). Each PC sets its own damage:
it's what you take. A broken guard's blow stays the game's.

With 4 or 6 Players, each person connected adds the same again, wherever they are, on another map, loading or down: 200%
and 160% with two connected, 250% and 190% with three, and it stops there (bosses' guard bar: 300% with two connected,
400% with three). With five or six, the ghost twins make it harder
instead of more health. It only goes up, so a boss doesn't lose health when someone dies or
leaves. Someone who joins during a boss fight only watches, so that boss keeps its number until the fight is over, while other
enemies rise at once.

## The host's story

You play in the host's world, so the host's story point counts for both of you:

- **A guest who is behind** is brought up to the host's story a little while after joining, at a quiet moment
  (not in a scene or a boss fight): the quests the host has done and the unlocks along the way. It never goes back,
  and what you found and the bells you rang stay yours. A tip says when it's done. `FollowHostStory = Off` in
  `PhantomPact.ini` keeps a guest's story their own.
- **A guest who is further on** sees the host's enemies even where their own save killed them long ago: they're
  brought back in the guest's world while you play together, and stay dead in the guest's save once killed.
- **Bosses:** a boss the host has beaten is gone for the guest, and a boss either player finishes dies the game's
  whole way in both worlds: the scene after it plays for both, the next phase comes for both, and when the host skips
  that scene it's skipped for the guest too.
- **Chests the host opened** before you joined are opened for you too as you come by them, and give you what they
  hold, so you both have the same things. (`FollowHostStory = Off` leaves them to you.)

Each of you sees the other in the clothes they're wearing, outfit, hat and face, and changes show at once.

## PvP matches (F6)

New in 1.7.0: real matches, fair for everyone, in the game's own boss arenas. Everyone linked presses **F6** in the game:

1. **The host** picks the mode (**Duel**: best of three rounds; **Death**: one life), the clock (none, 60, 90 or 120 s a
   round) and the arena: the Crimson Forest (YuCong), Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's
   meadow, or **Here**, where the host stands. A boss's arena opens once every player's own save has that boss beaten.
   For Here, stand on open, flat ground: the two sides start 8 m in front of and behind the host.
2. **Everyone** picks a loadout (two weapons and two Phantom Edges, any in the game, owned or not: click a slot), a team
   if there are more than two of you (Crimson or Azure), and presses **READY**.
3. The host presses **START**. Everyone goes to the arena, the fog walls go up, there are no monsters, and after
   三 二 一 斗 the fight is on.

Everyone fights with the same body: every skill node on, the same health and attack, every weapon at level 30, and three
drinks from the same gourd for the whole match. Every blow does half the game's usual damage, so it takes about six clean
hits to bring someone down: room for parries and reads. Health can't go below 1: at 1 you fall, and you're out of the round. So is
a player who falls from the arena or rests at a bell. With a clock, when it runs out the team with more health left wins
the round.

When the match is won, the winners have about five seconds: walk to a fallen foe and press **F** for a finishing move, one of the
bosses' own. Then the winners get the golden VICTORY and the losers the game's death card, and everyone goes back where
they were, with their own weapons, levels, gourd and skills. Nothing in a match is saved: the game's saving is off for
it. If the game crashes in the middle, the mod puts it all back on the next start.

To leave a match, press F6, then LEAVE twice. A player who drops out for 8 seconds ends it for everyone. Everyone needs
the same Phantom Pact version. Up to six players, so in a party of 4 or 6 it's teams of your choosing.

## PvPvE (fights in the open world)

The old PvP switch, now called PvPvE: you fight each other where you are, enemies and all. Both players turn on PvPvE
under MORE in the F5 panel (or set `PvP = On` in `PhantomPact.ini`). Your partner becomes an opponent you can fight:

- Their attacks hit you through the game's own combat: **block** (hold the guard button) costs posture,
  a well-timed **parry** (tap guard just before the hit) costs nothing, and dodges work as usual.
- A parry is rewarded like against a boss: the attacker staggers and loses posture (`PvPParryPosture`, default 60).
- The loser dies for real and respawns at their bell, as after any death. A kill by your partner is scored
  in the UE4SS console (`PvP: VICTORY. Your blade was faster. The pact holds. Score 1 - 0.`); dying to an
  enemy doesn't count.
  (In the prologue area the game won't let you die, so duel there for fun and the score still counts.)
- Both players fight with the same strength (your partner's ghost uses your stats), so skill decides.
  `PvPDamage` scales the damage you take (100 = normal).

Not in PvPvE yet: executions (posture break only staggers). It's for two players.

## Good to know

- Enemies are one fight: the host's game runs them, and the guest sees and fights the same ones. Their attacks work as
  usual on both PCs, so block, parry and dodge do too.
- Boss fights: when one of you starts a boss, the other gets a tip: press E at the black wall, or F3, to join. Stay close
  when you're about to start one: far from the host, enemies that aren't loaded on the host's PC fight on their own on the
  guest's.
- If your partner disappears, they are down, in a cutscene, on another map or disconnected; they come back.
- With both of you in a fight, an enemy picks whom to fight by how near each of you is and the damage each has done to it
  lately, and holds its target a few seconds (a boss longer) before it turns.
- If one of you dies during a boss fight, they watch the other until it's over, and respawn when the boss dies or the
  other dies too.
- If you join while the host is in a boss fight, you watch it (F3 takes you in now), and go to them when it's over; after
  30 s you're free to move. From another map you only get a message, and go across at the end.
- Bells: the host's bells light for you when you come to them, not before.
- Not shared yet: cutscenes, dialogue and spending dust. Quests and story: see The host's story, above.
- Never press Ctrl+R (UE4SS hot reload) while playing together: it can crash the game. Restart the game instead.

## Other mods

Phantom Pact changes no game files: it's a UE4SS Lua mod with a small DLL of its own, and it runs beside most mods.

- **Keys.** F3, F5 and F6 are Phantom Pact's, and F in a PvP match. A mod on the same key opens with it. Gauntlet of
  Masters' menu is F5 unless you change "menuKey" in `ProjectPBZ\Content\Paks\~mods\BossRush.json` ("F2", say).
  `OnlinePanel = Off` in `PhantomPact.ini` frees F5; you then connect with the ini.
- **UE4SS.** Use UE4SS for Phantom Blade Zero 1.0.3 or newer. Phantom Pact puts two files in `ue4ss\UE4SS_Signatures`; a
  UE4SS package, or a mod that brings its own, replaces them. After installing or updating one of those, extract Phantom
  Pact again.
- **Looks and camera** (gore, blood, effects, FOV, camera distance): only your own screen, fine together. While you're
  down, and in a PvP finishing move, the camera is Phantom Pact's, so a camera mod doesn't show there.
- **Your own fighting** (parry or deflect windows, animation cancels, damage, hit-stop): your own game judges the hits on
  you, so in co-op such a mod counts for you alone. In a PvP match (F6) it isn't fair, or the screens disagree (a swing
  you cancelled can still land on your foe's screen): everyone in a match should use the same mods, or none. In a match
  the game runs at normal speed every frame, so another mod's slow motion or hit-stop doesn't show there.
- **Boss rush and arena modes** (Gauntlet of Masters, Phantom Master Ninja): single player only. Online, the host's world
  decides bosses: a master the host has beaten dies the moment it appears for a guest, enemies such a mode spawns are on
  your PC only (your partner sees you fight nothing), and a run while linked can change your partner's save. Leave co-op
  first (F5 > LEAVE, or `Role = Off`) and back up your saves.
- **Anything that adds enemies or bosses** does so on your PC only.

## Troubleshooting

- **No "co-op on" line:** check `PhantomPact.ini` (Role, and HostAddress for the guest). The UE4SS log says what's
  missing.
- **"dlls\main.dll isn't running":** your antivirus may have removed it. Extract the zip again and allow the file,
  then restart the game. Online co-op can't run without it.
- **`relay_error.txt` in the mod folder, or the tip "co-op couldn't start":** the connection couldn't start, and the
  message says why (for example, the port is in use). Post it with your bug report.
- **`connected=no`, or it feels laggy:** see Connection problems below.
- **No `[PBZCoop] Loaded` line at all:** UE4SS isn't installed in `PBZ\platform\steam`, or the mod folder isn't at
  `platform\steam\ue4ss\Mods\PBZCoop`.
- **UE4SS stops at launch with "AOB scans could not be completed" (`GNatives`, `GUObjectArray`):** a game update moved
  what UE4SS looks for. The two files in `platform\steam\ue4ss\UE4SS_Signatures` from this zip handle the game as of the
  November 4 update; if a later update breaks them, look for a newer Phantom Pact.

## Connection problems

`ue4ss\Mods\PBZCoop\net_status.txt` is rewritten once a second while you play. It's one long line; open it in Notepad,
and open it again to see new numbers. The parts that help:

| Part | What it tells you |
|---|---|
| `connected` | `yes` if your partner was heard in the last 3 seconds |
| `peer` | Your partner's address. On the host, `-` means nothing has arrived from the guest yet |
| `via` | How you connect: `udp` (by IP, over Tailscale or another virtual LAN) or `steam` |
| `route` | Steam only: `direct`, or `relay` through Valve's servers. `-` over IP: see Direct or relayed below |
| `rtt_ms` | Ping, there and back, in ms. The game warns you if it stays above 250 |
| `route_ping_ms` | Steam only: Steam's own ping for that route |
| `link_problem` | Steam only: Steam's reason the last try ended, its number and its words, `-` if none |
| `jitter_ms` | How late packets arrive compared with the fastest lately, in ms. High jitter with a low ping usually means Wi-Fi |
| `delay_ms` | How far in the past your partner is shown so they move smoothly, in ms. It follows jitter, up to about 220 |
| `loss_pct` | Packets lost in the last second, in percent |
| `partner_version` | Your partner's version. `1.4.1-or-older` or `other-protocol` means one of you must update |
| `mismatch` | Settings that differ between you (`-` = none) |
| `filtered` | Packets refused because of their address. Going up on the host: see `AllowAnyAddress` above |
| `rejected` | Packets refused by `Secret`. Going up: the two `Secret` values differ, or the PCs' clocks are more than 2 minutes apart |
| `stopped` | `yes` when the connection isn't running: you pressed Leave, or it failed and `error` says why |

For scale: the test bench stayed smooth at 100 ms ping, 20 ms jitter and 2% loss. That was two copies on one PC with a
simulated bad connection, not a real one.

**`connected=no`.** Go through these in order:

1. Both on Tailscale, in the same network? The host's IP in the guest's `HostAddress`?
2. The guest runs `tailscale ping 100.x.y.z` in PowerShell, with the host's IP. No reply means Tailscale itself isn't
   connecting the two PCs: fix that first.
3. A reply, but still `connected=no`: Windows Firewall on the host is the likely cause, because `tailscale ping`
   doesn't pass through it. See below.

**Windows Firewall.** The connection is part of the game, so the firewall asks about the game (`PBZ.exe`), not Python.
It asks the first time the game opens the port, so on the host's PC, and the window can open behind the game. Click
Allow, with Private networks ticked (Tailscale counts as private; if your virtual LAN shows as Public in Windows, tick
that too). If you clicked Cancel, open Windows Security > Firewall & network protection > Allow an app through
firewall > Change settings, and tick PBZ. If it isn't in the list, use Allow another app and pick
`platform\steam\PBZ.exe` in the game folder.

**Direct or relayed.** Over Steam, `route` shows it: if it stays `relay`, check `SteamDirect = On` on both PCs, and that
your routers allow a direct connection. Over Tailscale `route` stays `-`, so ask `tailscale ping 100.x.y.z`:

- `pong from ... via 203.0.113.5:41641 in 12ms`: direct, the best case. The command stops by itself once it gets one.
- `pong from ... via DERP(fra) in 80ms`: relayed through a Tailscale server. The first few replies are often like this
  while Tailscale looks for a direct path.
- It ends with `direct connection not established`: you stay relayed, which means a higher ping and more jitter. Turn
  off other VPNs on both PCs, and turn on UPnP on the router, or forward UDP port 41641 (Tailscale's own, not the
  game's) to one of the PCs. A phone hotspot or a provider that shares one address between customers can stop a direct
  path from ever working. If nothing helps, try another virtual LAN.

**Wi-Fi or cable.** Wi-Fi is the usual cause of jitter, loss and short freezes. If `jitter_ms` jumps around or
`loss_pct` isn't 0, plug in a cable, on both PCs if you can, and compare. Stop big downloads and streams on the same
connection too.

## What to send in a bug report

From both players if you can, right after it happens and before you restart the game or reconnect, since these files
start over:

- `ue4ss\UE4SS.log`
- If the game closed by itself: the newest `ue4ss\crash_*.dmp` (UE4SS writes one when the game goes down; it says where)
- `ue4ss\Mods\PBZCoop\net_status.txt` and `relay_log.txt`, plus `relay_error.txt` if it's there
- What `tailscale ping` prints, if you use Tailscale
- Host or guest, which area or boss, what happened, and Wi-Fi or cable

`net_status.txt` and `relay_log.txt` show your partner's address. Your `Secret` is only in `PhantomPact.ini`: don't post
that file with the `Secret` in it.
