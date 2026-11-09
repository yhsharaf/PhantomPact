# Every screen a match shows, on both copies, for a look at how it all reads: the F6 page and its loadout picker, a Duel "here"
# with a 60 s clock (round 1's countdown, the fight's bars, TIME and the round's result, round 2's countdown, a player down
# and watching, the final round, the deciding blow, PRESS F, the finishing move, the last cards, home). Shots are named by
# step under $env:TEMP\pvpbench\shots\<Tag>-*. Start the copies first (pvpcycle.ps1; for Chinese, pvpstart.ps1 -Two with
# Language = Chinese in both). Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Tag = 'audit')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
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
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 150 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
function Both([string]$Step) { [void](Shot $h "$Tag-$Step-host"); [void](Shot $c "$Tag-$Step-guest"); "  shot $Step" }
# The F6 page, then its loadout picker (a slot card), on both.
Cmd $h 'pvppanel toggle'; Cmd $c 'pvppanel toggle'
Start-Sleep -Milliseconds 600
Both '00-page'
Cmd $h 'pvppanel press 488 398'; Cmd $c 'pvppanel press 488 398'
Start-Sleep -Milliseconds 600
Both '01-picker'
Cmd $h 'pvppanel press 50 504'; Cmd $c 'pvppanel press 50 504'          # (BACK)
Cmd $h 'pvppanel toggle'; Cmd $c 'pvppanel toggle'
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",60) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
"  " + (Wait-State $h '^count' 60)
# Each number in the middle of its second (it fades in and out at its edges), then the fight word as it lands: timed off
# the match's own clock (the host's m.fightAt). A poll a few hundred ms late caught every number in its fade on 11-09.
$left = [double](Ask $h 'local m=PBZ.arena.match return string.format("%.3f", m and m.fightAt and (m.fightAt - os.clock()) or 0)' 3)
$fightAt = (Get-Date).AddSeconds($left)
foreach ($n in 3, 2, 1) {
    $wait = ($fightAt.AddSeconds(-$n + 0.5) - (Get-Date)).TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    Both ("02-count-{0}" -f $n)
}
$wait = ($fightAt.AddSeconds(0.12) - (Get-Date)).TotalMilliseconds
if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
Both '03-fight-word'
"  " + (Wait-State $h '^fight' 10)
Start-Sleep -Seconds 2
Both '04-fight'
# Round 1 to the clock: the guest a little behind on health, TIME and then the round's result.
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 1100) return 1' 4)
$end = (Get-Date).AddSeconds(70)
do { Start-Sleep -Milliseconds 300 } while ((State $h) -match '^fight' -and (Get-Date) -lt $end)
Start-Sleep -Milliseconds 300
Both '05-time'
Start-Sleep -Seconds 1.5
Both '06-round-result'
"  " + (Wait-State $h '^count 2' 8)
Start-Sleep -Milliseconds 500
Both '07-count2'
"  " + (Wait-State $h '^fight 2' 8)
Start-Sleep -Seconds 1
# Round 2: the host down (by the test command), its banner, then the fallen host watching the guest.
Cmd $h 'arena down'
Start-Sleep -Milliseconds 400
Both '08-down'
Start-Sleep -Seconds 1.6
Both '09-watching'
"  " + (Wait-State $h '^count 3' 10)
Start-Sleep -Milliseconds 500
Both '10-final-round'
"  " + (Wait-State $h '^fight 3' 8)
Start-Sleep -Seconds 1
# The deciding blow: the guest down; the slowed beat, the banners, PRESS F; then F for real by the host, 4 m before it.
Cmd $c 'arena down'
Start-Sleep -Milliseconds 300
Both '11-decided'
Start-Sleep -Seconds 1.8
Both '12-banner'
"  " + (Wait-State $h '^finish' 8)
Start-Sleep -Milliseconds 900
Both '13-press-f'
$w = (Ask $c 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
$a = [double]$w[3] * [math]::PI / 180
[void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$([double]$w[0] + [math]::Cos($a) * 400),Y=$([double]$w[1] + [math]::Sin($a) * 400),Z=$([double]$w[2] + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$([double]$w[3] + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$([double]$w[3] + 180),Roll=0}) return 1") 4)
Start-Sleep -Milliseconds 500
$hw = [NetLab.Win]::Unreal($h.Pid)
[FinKeys.Win]::KeyDown($hw, 0x46); Start-Sleep -Milliseconds 160; [FinKeys.Win]::KeyUp($hw, 0x46)
Start-Sleep -Milliseconds 900
Both '14-finisher'
Start-Sleep -Seconds 1.5
Both '15-finisher-blow'
"  " + (Wait-State $h '^result' 15)
Start-Sleep -Seconds 1.5
Both '16-cards'
"  " + (Wait-State $h '^none' 30)
Start-Sleep -Seconds 3
Both '17-home'
