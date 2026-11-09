# Three players on the bench: the two copies (host slot 1, guest slot 2) and a relay_cli bot (slot 3, pvpbot.ps1) that
# speaks the match's own words (AR pick, here, down). Two matches, every step read from the game:
#   A: Duel, the host alone (Crimson) against the guest and the bot (Azure). A team is out only when all of it is down.
#   B: Death, the host and the guest together against the bot: no blow lands on a teammate; both winners get the gold.
# Shots of each step go to shots\<Tag>-*. Only touches C:\PBZDev and the bot's own files.
param([string]$Tag = 'teams', [double]$MidX = 5300, [double]$MidY = 279650, [double]$MidZ = -32300, [string]$Only = 'AB',
    [int]$BotSlot = 3)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$sp = ($script:Bench -replace '\\', '/')
$lab = $script:Lab
$bot = "$script:Scratch\bot3"
$loadout = 'Tang,PoJun,ShachiHook,TigerCannon'
if (-not ('DeflectKeys.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace DeflectKeys { public static class Win {
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c, uint t);
    public static void KeyDown(IntPtr h, uint vk) { uint s = MapVirtualKey(vk, 0); PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(1 | (s << 16))); }
    public static void KeyUp(IntPtr h, uint vk) { uint s = MapVirtualKey(vk, 0); PostMessage(h, 0x101, (IntPtr)vk, unchecked((IntPtr)(int)(1u | (s << 16) | (1u << 30) | (1u << 31)))); }
} }
'@
}
function Tap($g, [int]$Code, [int]$HoldMs = 160) {
    $w = [NetLab.Win]::Unreal($g.Pid)
    [DeflectKeys.Win]::KeyDown($w, $Code); Start-Sleep -Milliseconds $HoldMs; [DeflectKeys.Win]::KeyUp($w, $Code)
}
# (Shared, appended, and tried again: the bot reads the file 20 times a second, and something else opens it now and then.)
function Say([string]$Line) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Line`n")
    for ($try = 0; $try -lt 20; $try++) {
        try {
            $fs = [IO.File]::Open("$bot\say.txt", 'Append', 'Write', 'ReadWrite')
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds 25 }
    }
    Write-Output "  (couldn't tell the bot: $Line)"
}
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 150 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
$where = 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() local hp=PBZ.game.getHealth(p) return string.format("%.1f %.1f %.1f %.2f %.0f", l.X,l.Y,l.Z,r.Yaw,hp or -1)'
function Hp($g) { ((Ask $g $where 3) -split ' ')[4] }
# The attacker 170 cm before the target, facing it, and one real blow (the attack ability, as its key starts it).
function SwingAt($from, $to, [int]$Gap = 170) {
    $w = (Ask $to $where 3) -split ' '
    $x, $y, $z, $yaw = [double]$w[0], [double]$w[1], [double]$w[2], [double]$w[3]
    $a = $yaw * [math]::PI / 180
    $px, $py = ($x + [math]::Cos($a) * $Gap), ($y + [math]::Sin($a) * $Gap)
    [void](Ask $from ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$px,Y=$py,Z=$($z + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-12,Yaw=$($yaw + 180),Roll=0}) return 1") 4)
    Start-Sleep -Milliseconds 800
    "hp before " + $w[4] + "; " + (Ask $from 'return FIGHT.swing()' 4)
}
# Health low, then real blows till the game's own floor says down (a guest's passive deflect can turn one aside).
function Fell($from, $to, [string]$Who) {
    [void](Ask $to 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 150) return 1' 4)
    Start-Sleep -Milliseconds 500
    for ($try = 1; $try -le 4; $try++) {
        $r = SwingAt $from $to
        Start-Sleep -Milliseconds 1300
        $down = Ask $to 'local m=PBZ.arena.match return tostring(m and m.down[PBZ.arena.mySlot and PBZ.arena.mySlot() or 0])' 3
        $hp = Hp $to
        "  $Who, blow $try ($r): hp now $hp"
        if ([double]$hp -le 1.5) { return }
    }
}
# The bot's spot in this match, the way arenas.lua lays a team out ("here": 800 cm either side of the middle, 300 apart).
function BotSpot {
    $r = Ask $h ('local m=PBZ.arena.match if not m then return "none" end local d=m.middle return string.format("%d %s %.1f %.1f %.1f %.1f %d", m.id, tostring(m.teams[BOT]), d.X, d.Y, d.Z, d.Yaw or 0, m.spots[BOT] or 1)' -replace 'BOT', $BotSlot) 4
    if (-not $r -or $r -eq 'none') { return $null }
    $f = $r -split ' '
    $team, $cx, $cy, $cz, $yaw, $n = [int]$f[1], [double]$f[2], [double]$f[3], [double]$f[4], [double]$f[5], [int]$f[6]
    $a = $yaw * [math]::PI / 180
    $ax, $ay = [math]::Cos($a), [math]::Sin($a)
    $side = if ($team -eq 1) { -1 } else { 1 }
    $across = @(0, 300, -300)[[math]::Max(0, [math]::Min(2, $n - 1))]
    $face = ($yaw + $(if ($team -eq 1) { 0 } else { 180 })) % 360
    [pscustomobject]@{ Id = [int]$f[0]; X = $cx + $ax * 800 * $side - $ay * $across; Y = $cy + $ay * 800 * $side + $ax * $across; Z = $cz + 90; Yaw = $face }
}
# The bot's side of a start: there, standing at its spot.
function BotThere {
    $end = (Get-Date).AddSeconds(15)
    do { $s = BotSpot; if ($s) { break }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $end)
    if (-not $s) { return "no match on the host" }
    Say ("!at {0:0} {1:0} {2:0} {3:0.0}" -f $s.X, $s.Y, $s.Z, $s.Yaw)
    Say "!hp 1360 1360"
    Start-Sleep -Milliseconds 1500
    Say "AR here $($s.Id) there"
    "bot at its spot ($([math]::Round($s.X)), $([math]::Round($s.Y))), there in match $($s.Id)"
}
function BotDown([int]$By = 1) {
    $r = (Ask $h 'local m=PBZ.arena.match return m and (m.id.." "..m.round) or "none"' 3) -split ' '
    Say "!hp 1 1360"
    Say "AR down $($r[0]) $($r[1]) $By"
    "bot down in round $($r[1])"
}
function Bars($g) {
    Ask $g ('local m=PBZ.arena.match if not m then return "none" end local t={} for _,s in ipairs({1,2,BOT}) do local b=PBZ.coop.playerBody(s) t[#t+1]=s..":team "..tostring(m.teams[s])..(PBZ.valid(b) and " body" or " NO BODY")..(m.down[s] and " down" or "") end return table.concat(t,", ")' -replace 'BOT', $BotSlot) 4
}

# Match A from its last blow on: the window, the host's F on the bot's figure, the cards, home.
function FinishA {
    "  finish window: " + (Wait-State $h '^finish' 10)
    # The host to the bot's figure, F pressed for real: a finishing move on a third player's body, in both worlds.
    $b = BotSpot
    if ($b) {
        $a = ($b.Yaw) * [math]::PI / 180
        [void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($b.X + [math]::Cos($a) * 250),Y=$($b.Y + [math]::Sin($a) * 250),Z=$($b.Z)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($b.Yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$($b.Yaw + 180),Roll=0}) return 1") 4)
    }
    Start-Sleep -Milliseconds 700
    $from = Log-End
    Tap $h 0x46
    Start-Sleep -Seconds 1.5
    "  F pressed: " + $(if (Lines $from 'finishes player') { (Lines $from 'finishes player' | Select-Object -First 2) -join ' | ' } else { "NO FINISHING MOVE" })
    [void](Shot $h "$Tag-A4-fin-host")
    [void](Shot $c "$Tag-A4-fin-guest")
    Start-Sleep -Seconds 1.5
    [void](Shot $h "$Tag-A4-fin2-host")
    [void](Shot $c "$Tag-A4-fin2-guest")
    "  result: " + (Wait-State $h '^result' 12) + " / guest " + (Wait-State $c '^result' 5)
    Start-Sleep -Seconds 1
    [void](Shot $h "$Tag-A5-result-host")
    [void](Shot $c "$Tag-A5-result-guest")
    "  home: " + (Wait-State $h '^none' 20) + " / " + (Wait-State $c '^none' 10)
    Start-Sleep -Seconds 4
}

Get-ChildItem $script:Shots -Filter "$Tag-*" -ErrorAction SilentlyContinue | Remove-Item -Force
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$sp/fairprobe.lua`") dofile(`"$lab/fights.lua`") return 1" 8) }

if ($Only -notmatch 'F') {
    "== 0. three players: the host, the guest, the bot"
    [void](Ask $h "local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$MidX,Y=$MidY,Z=$MidZ},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=0,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=0,Roll=0}) return 1" 5)
    [void](Ask $c "local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($MidX - 300),Y=$MidY,Z=$MidZ},false,{},true) return 1" 5)
    Say ("!at {0} {1} {2} 180" -f ($MidX + 500), $MidY, ($MidZ + 90))
    Start-Sleep -Seconds 3
    $partners = 'local t={} for _,p in ipairs(PBZ.coop.partners()) do t[#t+1]=tostring(p.number)..(PBZ.valid(p.ghost) and " figure" or " no figure") end return #t.." partners: "..table.concat(t,", ")'
    "  host sees:  " + (Ask $h $partners 4)
    "  guest sees: " + (Ask $c $partners 4)
}

if ($Only -match 'A') {
    "== A. Duel, here, no clock: the host (Crimson) against the guest and the bot (Azure)"
    [void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
    Send-Dev $h 'pvppanel toggle'
    Send-Dev $c 'pvppanel toggle'
    Start-Sleep -Seconds 1.5
    Send-Dev $c 'arena team 2'
    Start-Sleep -Milliseconds 600
    [void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
    "  before the bot's pick: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
    Say "AR pick 2 0 - 1.7.0 $loadout"
    Start-Sleep -Seconds 1.5
    "  the bot on Azure, not ready: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
    Say "AR pick 2 1 - 1.7.0 $loadout"
    Start-Sleep -Seconds 1.5
    "  the bot ready: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
    "  the guest's lobby: " + (Ask $c 'local l=PBZ.arena.lobby if not l then return "none" end local t={} for s,p in pairs(l.players) do t[#t+1]=s..":"..p.team..(p.ready and "R" or "-") end table.sort(t) return table.concat(t," ")' 4)
    [void](Shot $h "$Tag-A1-lobby-host")
    [void](Shot $c "$Tag-A1-lobby-guest")
    Send-Dev $h 'pvppanel toggle'
    Send-Dev $c 'pvppanel toggle'
    Start-Sleep -Milliseconds 800
    "  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
    "  " + (BotThere)
    "  " + (Wait-State $h '^(count|fight)' 50) + " / " + (Wait-State $c '^(count|fight)' 15)
    "  " + (Wait-State $h '^fight' 10)
    "  host:  " + (Bars $h)
    "  guest: " + (Bars $c)
    [void](Shot $h "$Tag-A2-fight-host")
    [void](Shot $c "$Tag-A2-fight-guest")
    foreach ($round in 1, 2, 3) {
        "  -- round $round"
        if ($round -ne 1) {
            "  " + (Wait-State $h '^fight' 20)
            Say "!hp 1360 1360"
        }
        if ($round -eq 2) {
            Fell $c $h 'the host, by the guest'
            Start-Sleep -Seconds 1.5
            "  the host down, its team out at once: " + (State $h) + " / guest " + (State $c)
            [void](Shot $h "$Tag-A3-r2-host")
            [void](Shot $c "$Tag-A3-r2-guest")
            continue
        }
        Fell $h $c 'the guest, by the host'
        Start-Sleep -Seconds 2
        "  the guest down, the bot still up: " + (State $h) + " / guest " + (State $c) + " | host: " + (Bars $h)
        [void](Shot $h "$Tag-A3-r$round-guestdown-host")
        [void](Shot $c "$Tag-A3-r$round-guestdown-guest")
        "  " + (BotDown 1)
        Start-Sleep -Seconds 1.5
        "  the bot down too: " + (State $h) + " / guest " + (State $c)
    }
    FinishA
}

if ($Only -match 'F') {
    "== A, from the bot's last fall: " + (BotDown 1)
    FinishA
}

if ($Only -match 'B') {
    "== B. Death, here, no clock: the host and the guest (Crimson) against the bot (Azure)"
    [void](Ask $h 'PBZ.arena.choose("mode","death") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
    Send-Dev $c 'arena team 1'
    Start-Sleep -Milliseconds 600
    [void](Ask $c 'PBZ.arena.setPick(1, true) return 1' 5)
    Say "AR pick 2 1 - 1.7.0 $loadout"
    Start-Sleep -Seconds 2
    "  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
    "  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
    "  " + (BotThere)
    "  " + (Wait-State $h '^fight' 50) + " / " + (Wait-State $c '^fight' 15)
    "  host:  " + (Bars $h)
    "  guest: " + (Bars $c)
    [void](Shot $h "$Tag-B1-fight-host")
    [void](Shot $c "$Tag-B1-fight-guest")
    "  -- a teammate's blows land on nobody"
    $before = Hp $c
    "  host on the guest: " + (SwingAt $h $c); Start-Sleep -Milliseconds 1300
    "  host on the guest: " + (SwingAt $h $c); Start-Sleep -Milliseconds 1300
    "  the guest's health: $before before, $(Hp $c) after"
    $before = Hp $h
    "  guest on the host: " + (SwingAt $c $h); Start-Sleep -Milliseconds 1300
    "  the host's health: $before before, $(Hp $h) after"
    "  " + (BotDown 2)
    "  finish window: " + (Wait-State $h '^finish' 10) + " / guest " + (Wait-State $c '^finish' 5)
    # The guest finishes the bot this time, F pressed for real on the guest's window.
    $b = BotSpot
    if ($b) {
        $a = ($b.Yaw) * [math]::PI / 180
        [void](Ask $c ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($b.X + [math]::Cos($a) * 250),Y=$($b.Y + [math]::Sin($a) * 250),Z=$($b.Z)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($b.Yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$($b.Yaw + 180),Roll=0}) return 1") 4)
    }
    Start-Sleep -Milliseconds 700
    $from = Log-End
    Tap $c 0x46
    Start-Sleep -Seconds 1.5
    "  F pressed on the guest: " + $(if (Lines $from 'finishes player') { (Lines $from 'finishes player' | Select-Object -First 2) -join ' | ' } else { "NO FINISHING MOVE" })
    [void](Shot $h "$Tag-B2-fin-host")
    [void](Shot $c "$Tag-B2-fin-guest")
    "  result: " + (Wait-State $h '^result' 12) + " / guest " + (Wait-State $c '^result' 5)
    Start-Sleep -Seconds 1
    [void](Shot $h "$Tag-B3-result-host")
    [void](Shot $c "$Tag-B3-result-guest")
    "  home: " + (Wait-State $h '^none' 20) + " / " + (Wait-State $c '^none' 10)
    Start-Sleep -Seconds 4
    "  after, host:  " + (Ask $h 'return FAIR.read()' 8)
    "  after, guest: " + (Ask $c 'return FAIR.read()' 8)
}
"== errors in the log"
Lines 0 'error|Error' | Where-Object { $_ -notmatch 'eval ok' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 8
