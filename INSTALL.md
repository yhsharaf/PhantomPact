# Phantom Pact 1.6.0: online co-op for Phantom Blade Zero

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
2. **UE4SS for Phantom Blade Zero** by Vercadi (Nexus Mods), installed in `PBZ\platform\steam`.
3. **Tailscale** (tailscale.com), both signed in to the same network.

You don't need Python: the connection runs inside the game (`PBZCoop\dlls\main.dll`). Its source is in the GitHub
repository (`native/`).

**Both players must use the same version.** 1.5.0 has a new connection, and 1.4.1 or older can't connect to it.

## Install (both players)

1. Open the game folder: Steam > right-click the game > Manage > Browse local files.
2. Extract everything in the zip into that folder (the `PBZ` folder) and say yes to merging folders.
   The mod lands in `platform\steam\ue4ss\Mods\PBZCoop`.
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

**Easiest: the panel.** In the game, press **F5** to open the online panel, with no text file and no restart. Pick
Steam (nothing to set up: it finds your friend who's hosting), Tailscale, or Other Network, then press Host or Guest.
For Tailscale and other networks, copy the host's address and press Paste. Tailscale also covers Hamachi, Radmin and
a home network; Other Network is for ZeroTier and UU Accelerator. If you want a password, copy it and press Paste
password on both PCs before you connect. English and 中文 at the top of the panel switch the language of the panel
and the co-op messages. Your choices are kept for the next start.

**MORE** opens the settings: TP > PARTNER, PvP, the partner compass, your partner on the map, Steam Direct and 4 PLAYERS
(Beta), each ON or OFF, and Mode: MULTIPLAYER, or LOCAL for two players on this PC. Mode works from the next time you start the
game. Revive is coming soon. Enemy difficulty is the game's own setting. With a partner, enemies always get extra health and
posture on top of it.

**Going to your partner.** Joining takes you to the host once, even on another map, so a friend with a new save can
join a host further into the story. Your save stays where you land, so your own story can get ahead of where you were.
After that, **F3** takes you to your partner if you turn TP > PARTNER on under MORE. It's off by default, because it's a
lot of power to have on one key. Neither works during a boss fight, a cutscene, a duel or a menu, or while you or your
partner are down.

### 4 players (Beta)

4 PLAYERS under MORE is off by default, and with it off nothing changes. Turn it on before you press Host, and up to three
guests can join: four players in all. Only the host's switch counts: guests follow it, whatever theirs says. It works from the
next Host (`FourPlayers = On` in the ini does the same). Everyone joins as they would with two players, and everyone needs the
same version. It hasn't been played by four people yet: tell us what breaks.

With more than two players:

- Each player has a number and a colour, the same on every PC, on the compass and the map and in the tips: the host is purple,
  player 2 green, player 3 gold, player 4 blue. Red still means down. The panel says how many are connected and who you are.
- F3 goes to the nearest partner who's up. If nobody's on your map, a guest goes to the host.
- Enemies get more health and posture for each person connected: see [Co-op difficulty](#co-op-difficulty).
- Die in a boss fight and you wait until the boss dies or everyone else is down too. The camera moves to someone who's still up.
- What anyone gets, everyone gets, and if two of you are given the same thing at once it counts once.
- If a guest drops out the others play on. If the host leaves, it's over for everyone.
- Enemies are shared near the host, and near a guest up to 120 m from the host. Further off the host's game leaves them
  asleep, so each guest out there fights a copy of their own, and the first kill counts for everyone.
- PvP and Revive stay off.
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

- **Partner compass:** a silver seal on a line at the top shows which way your partner is. Turn it off with
  `PartnerCompass = Off`.
- **Map:** your partner is a jade copy of your own map marker, turned the way they face, when you're in the same
  area (red while they're down). Turn it off with `PartnerMapIcon = Off`.
- **Tips:** short messages when your partner connects, drops, goes down or wanders far off, and when something is in
  the way: no answer from the host, a refused `Secret`, different versions or settings, a high ping.
- **When you die:** after a few seconds the camera follows your partner until you respawn.

## Co-op difficulty

Like Elden Ring, enemies and bosses get tougher while your partner is with you: 150% health and 130% posture by
default. Change `CoopEnemyHealth` / `CoopEnemyPosture` in `PhantomPact.ini` (percent; 100 = normal). Both
players should use the same numbers.

With 4 PLAYERS (Beta) on, each person connected adds the same again, wherever they are, on another map, loading or down: 200%
and 160% with two connected, 250% and 190% with three. It only goes up, so a boss doesn't lose health when someone dies or
leaves. Someone who joins during a boss fight only watches, so that boss keeps its number until the fight is over, while other
enemies rise at once.

## PvP (duels)

Both players set `PvP = On` in `PhantomPact.ini`. Your partner becomes an opponent you can fight:

- Their attacks hit you through the game's own combat: **block** (hold the guard button) costs posture,
  a well-timed **parry** (tap guard just before the hit) costs nothing, and dodges work as usual.
- A parry is rewarded like against a boss: the attacker staggers and loses posture (`PvPParryPosture`, default 60).
- The loser dies for real and respawns at their bell, as after any death. A kill by your partner is scored
  in the UE4SS console (`PvP: VICTORY. Your blade was faster. The pact holds. Score 1 - 0.`); dying to an
  enemy doesn't count.
  (In the prologue area the game won't let you die, so duel there for fun and the score still counts.)
- Both players fight with the same strength (your partner's ghost uses your stats), so skill decides.
  `PvPDamage` scales the damage you take (100 = normal).

Not in PvP yet: executions (posture break only staggers).

## Good to know

- Enemies are one fight: the host's game runs them, and the guest sees and fights the same ones. Their attacks work as
  usual on both PCs, so block, parry and dodge do too.
- Boss fights: when one of you starts a boss, the other is brought into the arena. Stay close when you're about to start
  one: far from the host, enemies that aren't loaded on the host's PC fight on their own on the guest's.
- If your partner disappears, they are down, in a cutscene, on another map or disconnected; they come back.
- With both of you in a fight, an enemy stays on one of you for about 15 seconds, then turns on the other if they've been
  hitting it.
- If one of you dies during a boss fight, they watch the other until it's over, and respawn when the boss dies or the
  other dies too.
- If you join while the host is in a boss fight, you watch it, and go to them when it's over. From another map you only
  get a message, and go across at the end.
- Not shared yet: cutscenes, dialogue, spending dust, quests and story progress.
- Never press Ctrl+R (UE4SS hot reload) while playing together: it can crash the game. Restart the game instead.

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
- `ue4ss\Mods\PBZCoop\net_status.txt` and `relay_log.txt`, plus `relay_error.txt` if it's there
- What `tailscale ping` prints, if you use Tailscale
- Host or guest, which area or boss, what happened, and Wi-Fi or cable

`net_status.txt` and `relay_log.txt` show your partner's address. Your `Secret` is only in `PhantomPact.ini`: don't post
that file with the `Secret` in it.
