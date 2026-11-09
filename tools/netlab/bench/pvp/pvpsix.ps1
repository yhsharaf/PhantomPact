# Six players on the bench: the two copies and four bots (pvpbots.ps1 -Count 4, slots 3-6), host PartySize 6. Crimson: host,
# guest, slot 3; Azure: slots 4, 5, 6. Death "here": the six-row lobby, everyone at their spot (three a side), the bars (two
# teammates, three foes), Azure falling one by one, the host's finishing move on one of them, the cards, home. Only touches
# C:\PBZDev and the bots' files.
param([string]$Tag = 'six')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$loadout = 'Tang,PoJun,ShachiHook,TigerCannon'
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
function Say([int]$n, [string]$Line) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Line`n")
    for ($try = 0; $try -lt 20; $try++) {
        try {
            $fs = [IO.File]::Open("$script:Scratch\botn$n\say.txt", 'Append', 'Write', 'ReadWrite')
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds 25 }
    }
}
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
# Bot n is slot n + 2 (they joined in order); its team: bot 1 Crimson, the rest Azure.
$teamOf = @{ 1 = 1; 2 = 2; 3 = 2; 4 = 2 }
"== six players"
"  host sees: " + (Ask $h 'local t={} for _,p in ipairs(PBZ.coop.partners()) do if not p.partnerGone then t[#t+1]=tostring(p.number) end end table.sort(t) return table.concat(t,",")' 4)
"  guest sees: " + (Ask $c 'local t={} for _,p in ipairs(PBZ.coop.partners()) do if not p.partnerGone then t[#t+1]=tostring(p.number) end end table.sort(t) return table.concat(t,",")' 4)
[void](Ask $h 'PBZ.arena.choose("mode","death") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
Send-Dev $h 'pvppanel toggle'
Send-Dev $c 'pvppanel toggle'
Start-Sleep -Seconds 1.5
Send-Dev $c 'arena team 1'
Start-Sleep -Milliseconds 500
[void](Ask $c 'PBZ.arena.setPick(1, true) return 1' 5)
foreach ($n in 1..4) { Say $n "AR pick $($teamOf[$n]) 1 - 1.7.0 $loadout" }
Start-Sleep -Seconds 2.5
"  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
"  the guest's lobby: " + (Ask $c 'local l=PBZ.arena.lobby if not l then return "none" end local t={} for s,p in pairs(l.players) do t[#t+1]=s..":"..p.team..(p.ready and "R" or "-") end table.sort(t) return table.concat(t," ")' 4)
[void](Shot $h "$Tag-1-lobby-host")
[void](Shot $c "$Tag-1-lobby-guest")
Send-Dev $h 'pvppanel toggle'
Send-Dev $c 'pvppanel toggle'
Start-Sleep -Milliseconds 800
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
Start-Sleep -Seconds 1.5
$info = (Ask $h 'local m=PBZ.arena.match if not m then return "none" end local d=m.middle local t={} for s=3,6 do t[#t+1]=tostring(m.teams[s] or 0)..":"..tostring(m.spots[s] or 0) end return string.format("%d %.1f %.1f %.1f %.1f %s", m.id, d.X, d.Y, d.Z, d.Yaw or 0, table.concat(t,","))' 4) -split ' '
$id, $cx, $cy, $cz, $yaw = [int]$info[0], [double]$info[1], [double]$info[2], [double]$info[3], [double]$info[4]
$a = $yaw * [math]::PI / 180
$ax, $ay = [math]::Cos($a), [math]::Sin($a)
$i = 0
foreach ($ts in ($info[5] -split ',')) {
    $i++
    $team, $n = [int]($ts -split ':')[0], [int]($ts -split ':')[1]
    $side = if ($team -eq 1) { -1 } else { 1 }
    $across = @(0, 300, -300)[[math]::Max(0, [math]::Min(2, $n - 1))]
    $face = ($yaw + $(if ($team -eq 1) { 0 } else { 180 })) % 360
    $x = $cx + $ax * 800 * $side - $ay * $across
    $y = $cy + $ay * 800 * $side + $ax * $across
    Say $i ("!at {0:0} {1:0} {2:0} {3:0.0}" -f $x, $y, ($cz + 90), $face)
    Say $i "!hp 1360 1360"
    "  bot $i (slot $($i + 2)): team $team, spot $n"
}
Start-Sleep -Seconds 1.2
foreach ($n in 1..4) { Say $n "AR here $id there" }
"  " + (Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 1.5
[void](Shot $h "$Tag-2-fight-host")
[void](Shot $c "$Tag-2-fight-guest")
"  == Azure falls, one by one"
foreach ($n in 2..4) {
    Say $n "!hp 1 1360"
    Say $n "AR down $id 1 1"
    Start-Sleep -Seconds 1.2
    "  bot $n down: " + (State $h)
}
"  " + (Wait-State $h '^finish' 10)
# The host 4 m before the nearest fallen bot's figure, F for real.
$t = (Ask $h 'local m=PBZ.arena.match local b=PBZ.coop.playerBody(4) local l=b:K2_GetActorLocation() local r=b:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 4) -split ' '
$fa = [double]$t[3] * [math]::PI / 180
[void](Ask $h ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$([double]$t[0] + [math]::Cos($fa) * 400),Y=$([double]$t[1] + [math]::Sin($fa) * 400),Z=$([double]$t[2] + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$([double]$t[3] + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$([double]$t[3] + 180),Roll=0}) return 1") 4)
Start-Sleep -Milliseconds 600
$from = Log-End
$hw = [NetLab.Win]::Unreal($h.Pid)
[FinKeys.Win]::KeyDown($hw, 0x46); Start-Sleep -Milliseconds 160; [FinKeys.Win]::KeyUp($hw, 0x46)
Start-Sleep -Seconds 2
[void](Shot $h "$Tag-3-fin-host")
[void](Shot $c "$Tag-3-fin-guest")
"  " + ((Lines $from 'finishes player|finishing run|no clear run') | Select-Object -First 3) -join ' | '
"  result: " + (Wait-State $h '^(result|none)' 15)
Start-Sleep -Seconds 1
[void](Shot $h "$Tag-4-result-host")
[void](Shot $c "$Tag-4-result-guest")
"  home: " + (Wait-State $h '^none' 30) + " / " + (Wait-State $c '^none' 20)
"== errors"
Lines 0 'arena screen|error|Error' | Where-Object { $_ -notmatch 'eval ok|ArIsError|ArIsCriticalError|bKismetScriptError|ProcessConsoleExec' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 6
