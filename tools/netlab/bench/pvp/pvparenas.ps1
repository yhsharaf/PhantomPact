# A match in each boss arena on the two bench copies (a save with the four bosses beaten): the trip there, both players
# set down at their spots, the walls up and the arena's enemies parked, the countdown, the fight, the guest down, F pressed
# for real by the host 4 m before them (the arena's boss's finishing move), the cards, the trip home. Shots of each step.
# Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([int[]]$Places = @(1, 2, 3, 4), [string]$Tag = 'arena', [string]$Mode = 'death')
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
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
$where = 'local _,p=PBZ.getPlayer1() if not PBZ.valid(p) then return "no pawn" end local l=p:K2_GetActorLocation() local m=PBZ.arena.match local c=m and PBZ.arena.middleOf(m) local d=c and math.sqrt((l.X-c.X)^2+(l.Y-c.Y)^2)/100 or -1 return string.format("%s %.0f %.0f %.0f, %.1f m from the middle", PBZ.game.mapName(p), l.X, l.Y, l.Z, d)'
"unlocked, host: " + (Ask $h 'PBZ.arena.readUnlocked() local t={} for k,v in pairs(PBZ.arena.unlocked or {}) do t[#t+1]=k end table.sort(t) return table.concat(t," ")' 10)
"unlocked, guest: " + (Ask $c 'PBZ.arena.readUnlocked() local t={} for k,v in pairs(PBZ.arena.unlocked or {}) do t[#t+1]=k end table.sort(t) return table.concat(t," ")' 10)
foreach ($place in $Places) {
    "== arena $place"
    [void](Ask $h "PBZ.arena.choose(`"mode`",`"$Mode`") PBZ.arena.choose(`"timer`",0) PBZ.arena.choose(`"place`",$place) PBZ.arena.setPick(1) return 1" 5)
    [void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
    Start-Sleep -Seconds 2.5
    "  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
    $t0 = Get-Date
    "  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
    "  " + (Wait-State $h '^(count|fight)' 150) + " / " + (Wait-State $c '^(count|fight)' 60) + ("  ({0:0} s from START)" -f ((Get-Date) - $t0).TotalSeconds)
    "  host:  " + (Ask $h $where 4)
    "  guest: " + (Ask $c $where 4)
    [void](Shot $h "$Tag-$place-1-count-host")
    [void](Shot $c "$Tag-$place-1-count-guest")
    "  " + (Wait-State $h '^fight' 15)
    Start-Sleep -Seconds 1
    "  walls, host: " + (Ask $h 'local m=PBZ.arena.match local d=m and PBZ.arena.middleOf(m) local w=d and PBZ.game.closedFogNear(d, 6000) return w and string.format("a closed wall %.0f m from the middle", math.sqrt((w.at.X-d.X)^2+(w.at.Y-d.Y)^2)/100) or "none closed within 60 m"' 6)
    "  nearest enemy, host: " + (Ask $h 'local e=FIGHT.nearest() if not PBZ.valid(e) then return "none" end local l=e:K2_GetActorLocation() local _,p=PBZ.getPlayer1() local m=p:K2_GetActorLocation() return string.format("%s %.0f m, hidden %s", e:GetClass():GetFName():ToString(), math.sqrt((l.X-m.X)^2+(l.Y-m.Y)^2)/100, tostring(e.bHidden))' 6)
    [void](Shot $h "$Tag-$place-2-fight-host")
    [void](Shot $c "$Tag-$place-2-fight-guest")
    Send-Dev $c 'arena down'
    "  " + (Wait-State $h '^finish' 15) + " / " + (Wait-State $c '^finish' 5)
    Start-Sleep -Milliseconds 700
    $w = (Ask $c 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
    $a = [double]$w[3] * [math]::PI / 180
    [void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$([double]$w[0] + [math]::Cos($a) * 400),Y=$([double]$w[1] + [math]::Sin($a) * 400),Z=$([double]$w[2] + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$([double]$w[3] + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$([double]$w[3] + 180),Roll=0}) return 1") 4)
    Start-Sleep -Milliseconds 600
    $from = Log-End
    $hw = [NetLab.Win]::Unreal($h.Pid)
    [FinKeys.Win]::KeyDown($hw, 0x46); Start-Sleep -Milliseconds 160; [FinKeys.Win]::KeyUp($hw, 0x46)
    $f0 = Get-Date
    $i = 0
    while (((Get-Date) - $f0).TotalSeconds -lt 6.5) {
        $t = ((Get-Date) - $f0).TotalSeconds
        [void](Shot $h ("$Tag-$place-f-a-{0:d2}-{1:0.0}" -f $i, $t))
        [void](Shot $c ("$Tag-$place-f-b-{0:d2}-{1:0.0}" -f $i, $t))
        $i++
    }
    "  " + ((Lines $from 'finishes player|finishing run|no clear run') | Select-Object -First 3) -join ' | '
    python "$script:Bench\sheet.py" $script:Shots "$Tag-$place-f-a" "$script:Shots\sheet-$Tag-$place-host.jpg" 6 320 | Out-Null
    python "$script:Bench\sheet.py" $script:Shots "$Tag-$place-f-b" "$script:Shots\sheet-$Tag-$place-guest.jpg" 6 320 | Out-Null
    "  result: " + (Wait-State $h '^(result|none)' 15)
    "  home: " + (Wait-State $h '^none' 150) + " / " + (Wait-State $c '^none' 60)
    Start-Sleep -Seconds 6
    "  back, host:  " + (Ask $h $where 4)
}
"== errors"
Lines 0 'error|Error' | Where-Object { $_ -notmatch 'eval ok|ArIsError|ArIsCriticalError|bKismetScriptError|ProcessConsoleExec' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 6
