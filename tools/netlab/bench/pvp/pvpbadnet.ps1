# A match over a bad link: the guest's copy joins through relay_cli netem (delay, jitter, loss), then a Duel "here". What
# it shows: each world's fight start for each round (the guest's countdown shortened by the host's word's age, from the
# log's "the fight is on" lines), the guest's real blows landing, rounds to a fall, F pressed for real by the host and the
# finishing move reaching both worlds, the link's numbers (rtt, packets and events a second) in co-op and in the match.
# Stops the copies and puts the saves back first. Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Via = '--delay 50 --jitter 10 --loss 1', [string]$Tag = 'badnet', [switch]$NoStart)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
if (-not ('FinKeys.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace FinKeys { public static class Win {
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c, uint t);
    public static void KeyDown(IntPtr h, uint vk) { uint s = MapVirtualKey(vk, 0); PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(1 | (s << 16))); }
    public static void KeyUp(IntPtr h, uint vk) { uint s = MapVirtualKey(vk, 0); PostMessage(h, 0x101, (IntPtr)vk, unchecked((IntPtr)(int)(1u | (s << 16) | (1u << 30) | (1u << 31)))); }
} }
'@
}
if (-not $NoStart) {
    foreach ($f in 'pvp-host.json', 'pvp-guest.json') {
        if (Test-Path "$script:Scratch\$f") { Stop-DevGame (Load-Copy "$script:Scratch\$f") }
    }
    $t = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $t -and (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' })) { Start-Sleep -Milliseconds 500 }
    & "$PSScriptRoot\pvprestore.ps1"
    & "$script:Repo\tools\netlab\bench-lock.ps1" -Take pvp
    "mod installed, main.dll " + (Install-DevMod)
    $h = Start-DevGame -Role Host -Instance 1
    Save-Copy $h "$script:Scratch\pvp-host.json"
    Start-Sleep -Seconds 20
    # The bad link, then the guest through it (its relay's port is read at start), as badnet.ps1 does.
    $cli = Join-Path $script:Repo 'native\build\relay_cli.exe'
    $netem = Start-Process $cli -ArgumentList (@('netem', 47811, 47810, '--seconds', 2400) + ($Via -split ' ')) -PassThru -WindowStyle Hidden
    "netem pid $($netem.Id): $Via"
    $c = Start-DevGame -Role Guest -Instance 2 -Port 47811 -Settings @{ ThisPcOnly = 'On' }
    Save-Copy $c "$script:Scratch\pvp-guest.json"
    "host in: " + (Enter-Game $h)
    "guest in: " + (Enter-Game $c)
    Start-Sleep -Seconds 15
}
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$lab/fights.lua`") return 1" 8) }
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
# One command at a time to a copy: the next would overwrite its cmd.txt before the mod read it.
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
# The link as each relay counts it: rtt, packets sent, events acked, loss, and the mod's own events sent; read twice.
$link = 'local s=tostring(PBZ.link.status()) local function f(k) return s:match(k.."=(%S+)") or "?" end return f("rtt_ms").." "..f("sent").." "..f("events_acked").." "..f("loss_pct").." "..tostring(PBZ.net.stats.sent)'
function Rates([string]$Label, [double]$Window = 20) {
    $a1 = (Ask $h $link 4) -split ' '; $b1 = (Ask $c $link 4) -split ' '; $t1 = Get-Date
    Start-Sleep -Seconds $Window
    $a2 = (Ask $h $link 4) -split ' '; $b2 = (Ask $c $link 4) -split ' '; $s = ((Get-Date) - $t1).TotalSeconds
    "{0}: host rtt {1} ms, {2:0.0} packets/s, {3:0.0} events/s; guest rtt {4} ms, {5:0.0} packets/s, {6:0.0} events/s, loss {7}%" -f $Label,
        $a2[0], (([double]$a2[1] - [double]$a1[1]) / $s), (([double]$a2[4] - [double]$a1[4]) / $s),
        $b2[0], (([double]$b2[1] - [double]$b1[1]) / $s), (([double]$b2[4] - [double]$b1[4]) / $s), $b2[3]
}
$from = Log-End
Rates 'co-op by the bell (enemies about)'
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 3
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 1
Rates 'in the match'
# The guest's real blows on the host, over the bad link.
$hp = 'local _,p=PBZ.getPlayer1() return string.format("%.0f", (PBZ.game.getHealth(p)))'
$place = 'local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local y=g:K2_GetActorRotation().Yaw local a=math.rad(y) p:K2_SetActorLocation({X=l.X+math.cos(a)*160,Y=l.Y+math.sin(a)*160,Z=l.Z+20},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=y+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y+180,Roll=0}) return 1'
$blows = @()
for ($i = 0; $i -lt 2; $i++) {
    [void](Ask $c $place 5)
    Start-Sleep -Milliseconds 800
    $before = [double](Ask $h $hp 5)
    [void](Ask $c 'return FIGHT.swing()' 5)
    Start-Sleep -Seconds 2.5
    $blows += [math]::Round($before - [double](Ask $h $hp 5), 0)
}
"the guest's blows on the host: " + ($blows -join ', ')
# Round 1 to the host (the guest down), round 2 to the guest, round 3 to the host.
foreach ($who in @($c, $h, $c)) {
    Cmd $who 'arena down'
    (Wait-State $h '^(count|finish)' 15) + " / " + (Wait-State $c '^(count|finish)' 10)
    if ((State $h) -match '^finish') { break }
    (Wait-State $h '^fight' 15) + " / " + (Wait-State $c '^fight' 10)
    Start-Sleep -Seconds 1
}
(Wait-State $h '^finish' 10) + " / " + (Wait-State $c '^finish' 5)
# The host 4 m in front of the dazed guest, then F for real.
Start-Sleep -Milliseconds 600
$w = (Ask $c 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
$a = [double]$w[3] * [math]::PI / 180
[void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$([double]$w[0] + [math]::Cos($a) * 400),Y=$([double]$w[1] + [math]::Sin($a) * 400),Z=$([double]$w[2] + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$([double]$w[3] + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$([double]$w[3] + 180),Roll=0}) return 1") 4)
Start-Sleep -Milliseconds 600
$hw = [NetLab.Win]::Unreal($h.Pid)
[FinKeys.Win]::KeyDown($hw, 0x46); Start-Sleep -Milliseconds 160; [FinKeys.Win]::KeyUp($hw, 0x46)
for ($i = 0; $i -lt 6; $i++) {
    [void](Shot $h ("$Tag-fin-host-{0}" -f $i)); [void](Shot $c ("$Tag-fin-guest-{0}" -f $i))
    Start-Sleep -Milliseconds 300
}
"result: " + (Wait-State $h '^(result|none)' 15) + " / " + (Wait-State $c '^(result|none)' 10)
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 3
"== the log: each world's fight start, the rounds, the finishing move"
Lines $from 'the fight is on|round \d to|finishes|finishing run|no clear run|too late|PvP: the match goes' | Select-Object -Last 24
