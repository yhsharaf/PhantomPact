# Each boss's finishing move in a real match on the two bench copies: a Death match "here", the guest down (its own world
# says so), the host's finishing move by number (arenas.lua FINISHERS: 2 YuCong, 3 Hua Qianxiao, 4 the Gold-Masked One,
# 5 Mu Xiaokui), frames from both windows through the move, one sheet a window a move. Only touches C:\PBZDev and
# $env:TEMP\pvpbench.
param([int[]]$N = @(2, 3, 4, 5), [string]$Tag = 'bfin', [double]$Seconds = 6.5)
# N 0: F pressed for real on the host's window (the move the place draws, its nearest foe).
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
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
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$lab/fights.lua`") return 1" 8) }
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 150 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
# $move, not $n: PowerShell names ignore case, so $n was the [int[]] $N itself and "$n -eq 0" never held for -N 0.
foreach ($move in $N) {
    "== finishing move $move"
    [void](Ask $h 'PBZ.arena.choose("mode","death") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
    [void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
    Start-Sleep -Seconds 2
    "  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
    "  " + (Wait-State $h '^fight' 50) + " / " + (Wait-State $c '^fight' 15)
    Start-Sleep -Seconds 1.5
    Send-Dev $c 'arena down'
    "  " + (Wait-State $h '^finish' 12) + " / " + (Wait-State $c '^finish' 5)
    Start-Sleep -Milliseconds 900
    $from = Log-End
    if ($move -eq 0) {
        # The host 4 m before the dazed guest, facing them (F reaches 9 m), then F held a moment, as a hand presses it.
        $w = (Ask $c 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
        $a = [double]$w[3] * [math]::PI / 180
        [void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$([double]$w[0] + [math]::Cos($a) * 400),Y=$([double]$w[1] + [math]::Sin($a) * 400),Z=$([double]$w[2] + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$([double]$w[3] + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$([double]$w[3] + 180),Roll=0}) return 1") 4)
        Start-Sleep -Milliseconds 600
        $from = Log-End
        $hw = [NetLab.Win]::Unreal($h.Pid)
        [FinKeys.Win]::KeyDown($hw, 0x46); Start-Sleep -Milliseconds 160; [FinKeys.Win]::KeyUp($hw, 0x46)
    } else {
        Send-Dev $h "arena finish 2 $move"
    }
    $t0 = Get-Date
    $i = 0
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
        $t = ((Get-Date) - $t0).TotalSeconds
        [void](Shot $h ("$Tag-$move-a-{0:d2}-{1:0.0}" -f $i, $t))
        [void](Shot $c ("$Tag-$move-b-{0:d2}-{1:0.0}" -f $i, $t))
        $i++
    }
    "  " + ((Lines $from 'finishes player|finishing run|no clear run|PvP finish') | Select-Object -First 4) -join ' | '
    python "$script:Bench\sheet.py" $script:Shots "$Tag-$move-a" "$script:Shots\sheet-$Tag-$move-host.jpg" 6 320 | Out-Null
    python "$script:Bench\sheet.py" $script:Shots "$Tag-$move-b" "$script:Shots\sheet-$Tag-$move-guest.jpg" 6 320 | Out-Null
    "  result: " + (Wait-State $h '^(result|none)' 15)
    "  home: " + (Wait-State $h '^none' 25) + " / " + (Wait-State $c '^none' 10)
    Start-Sleep -Seconds 4
}
"== errors"
Lines 0 'error|Error' | Where-Object { $_ -notmatch 'eval ok|ArIsError|ArIsCriticalError|bKismetScriptError|ProcessConsoleExec' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 6
