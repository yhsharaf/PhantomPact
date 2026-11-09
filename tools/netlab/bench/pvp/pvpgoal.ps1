# The 1.7.0 goal's checklist on the two bench copies, each item from the game itself: F6 pressed for real opens the page on
# both; team picks (one team stops the start, two let it go); what each player fights with before, in and after a match;
# a Death match with a 60 s clock decided by the clock and finished with F pressed for real; the 120 s clock. Shots of each.
# Only touches C:\PBZDev.
param([string]$Tag = 'goal')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$sp = ($script:Bench -replace '\\', '/')
$lab = $script:Lab
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
function Tap($g, [int]$Vk, [int]$HoldMs = 160) {
    $w = [NetLab.Win]::Unreal($g.Pid)
    [DeflectKeys.Win]::KeyDown($w, $Vk); Start-Sleep -Milliseconds $HoldMs; [DeflectKeys.Win]::KeyUp($w, $Vk)
}
Get-ChildItem $script:Shots -Filter "$Tag-*" -ErrorAction SilentlyContinue | Remove-Item -Force
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$sp/fairprobe.lua`") dofile(`"$lab/fights.lua`") return 1" 8) }
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 150 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}

"== 1. F6 pressed for real, on each copy"
foreach ($pair in @(@($h, 'host', '\[PBZCoop\] PvP page open'), @($c, 'guest', '\[PBZCoop#2\] PvP page open'))) {
    $g, $who, $pat = $pair
    $from = Log-End
    Tap $g 0x75
    Start-Sleep -Milliseconds 1500
    "  ${who}: " + $(if (Lines $from $pat) { "the PvP page opened" } else { "NOT OPENED" })
    [void](Shot $g "$Tag-1-f6-$who")
}

"== 2. teams: both on Crimson stops the start; the guest on Azure lets it go"
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) return 1' 5)
Send-Dev $c 'arena team 1'
Start-Sleep -Seconds 2.5
"  one team: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
[void](Shot $h "$Tag-2-oneteam-host")
Send-Dev $c 'arena team 2'
Start-Sleep -Milliseconds 800
[void](Ask $c 'PBZ.arena.setPick(nil, true) return 1' 5)
Start-Sleep -Seconds 2.5
"  two teams: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
[void](Shot $h "$Tag-2-twoteams-host")
[void](Shot $c "$Tag-2-twoteams-guest")
Send-Dev $h 'pvppanel toggle'
Send-Dev $c 'pvppanel toggle'
Start-Sleep -Seconds 1

"== 3. what each fights with, before the match (their own)"
"  host:  " + (Ask $h 'return FAIR.read()' 8)
"  guest: " + (Ask $c 'return FAIR.read()' 8)

"== 4. Death, a 60 s clock: decided by the clock, F pressed for real"
[void](Ask $h 'PBZ.arena.choose("mode","death") PBZ.arena.choose("timer",60) PBZ.arena.choose("place",0) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(nil, true) return 1' 5)
Start-Sleep -Seconds 2.5
"  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
"  " + (Wait-State $h '^fight' 40) + " / " + (Wait-State $c '^fight' 10)
Start-Sleep -Seconds 2.5
"  in the match, host:  " + (Ask $h 'return FAIR.read()' 8)
"  in the match, guest: " + (Ask $c 'return FAIR.read()' 8)
[void](Shot $h "$Tag-4-clock-start-host")
[void](Shot $c "$Tag-4-clock-start-guest")
# The guest behind on health, so the clock gives it to the host; the host 3 m before the guest to finish them after.
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 700) return 1' 4)
$w = (Ask $c 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
$x, $y, $z, $yaw = [double]$w[0], [double]$w[1], [double]$w[2], [double]$w[3]
$a = $yaw * [math]::PI / 180
[void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($x + [math]::Cos($a) * 300),Y=$($y + [math]::Sin($a) * 300),Z=$($z + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$($yaw + 180),Roll=0}) return 1") 4)
$from = Log-End
"  waiting for the clock: " + (Wait-State $h '^(between|finish)' 75)
[void](Shot $h "$Tag-4-clock-end-host")
[void](Shot $c "$Tag-4-clock-end-guest")
Lines $from 'PvP: round|goes to' | Select-Object -First 4
"  finish window: " + (Wait-State $h '^finish' 8)
Start-Sleep -Milliseconds 700
Tap $h 0x46
Start-Sleep -Seconds 1.2
"  F pressed: " + $(if (Lines $from 'finishes player') { (Lines $from 'finishes player' | Select-Object -First 1) } else { "NO FINISHING MOVE" })
[void](Shot $h "$Tag-4-fin-host")
[void](Shot $c "$Tag-4-fin-guest")
"  result: " + (Wait-State $h '^result' 12)
[void](Shot $h "$Tag-4-result-host")
[void](Shot $c "$Tag-4-result-guest")
"  home: " + (Wait-State $h '^none' 15) + " / " + (Wait-State $c '^none' 10)
Start-Sleep -Seconds 4
"  after, host:  " + (Ask $h 'return FAIR.read()' 8)
"  after, guest: " + (Ask $c 'return FAIR.read()' 8)

"== 5. the 120 s clock"
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",120) PBZ.arena.choose("place",0) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(nil, true) return 1' 5)
Start-Sleep -Seconds 2.5
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
"  " + (Wait-State $h '^fight' 40)
Start-Sleep -Seconds 1.5
"  clock left: " + (Ask $h 'local m=PBZ.arena.match return m and string.format("%s s a round, %.0f s left", tostring(m.timer), (m.endsAt or 0) - os.clock()) or "none"' 4)
[void](Shot $h "$Tag-5-clock120-host")
[void](Ask $h 'PBZ.arena.command("leave") return 1' 4)
Start-Sleep -Milliseconds 400
[void](Ask $h 'PBZ.arena.command("leave") return 1' 4)
"  home: " + (Wait-State $h '^none' 15)
"== errors in the log"
Lines 0 'error|Error' | Where-Object { $_ -notmatch 'eval ok' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 6
