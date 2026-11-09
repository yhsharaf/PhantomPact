# The deflect window, found: a match "here", the guest's figure swings at the host from -Dist cm, and the host taps the
# game's guard (bound to a keyboard key in memory: a posted mouse button never reaches the game) a set delay after the
# figure's attack starts on the host's own screen (trig.lua writes a file that very frame). One try a delay: what the host's
# game played, health and posture, and the mod's parry. Only touches C:\PBZDev.
param([string]$Bind = 'K', [int[]]$Delays = @(60, 140, 220, 300, 380, 460), [int]$Dist = 170, [int]$TapMs = 140,
    [switch]$Perfect, [string]$Tag = 'd', [int]$Posture = 640, [int[]]$Holds = @(), [int]$Frames = 0, [int]$PreHoldMs = 250, [int]$Vk = 0)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
$sp = ($script:Bench -replace '\\', '/')
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
$keyVk = if ($Vk -gt 0) { $Vk } else { [int][char]$Bind.ToUpper() }
$win = [NetLab.Win]::Unreal($h.Pid)
$trigFile = Join-Path $script:Scratch 'trig.txt'
$trigLua = ($trigFile -replace '\\', '/')

[void](Ask $h "dofile(`"$sp/keymap.lua`") dofile(`"$sp/parryprobe.lua`") dofile(`"$sp/guardkey.lua`") dofile(`"$sp/trig.lua`") dofile(`"$sp/selftrace.lua`") dofile(`"$sp/metprobe.lua`") dofile(`"$lab/fights.lua`") return 1" 8)
[void](Ask $c "dofile(`"$lab/fights.lua`") return 1" 8)
if ($Vk -eq 0) { "  bind: " + (Ask $h "return GUARDKEY.bind(`"$Bind`")" 8) } else { "  raw key $Vk" }
[void](Ask $c "dofile(`"$sp/figabil.lua`") return 1" 8)
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round)) or "none"'
function Wait-Fight($g) { $end = (Get-Date).AddSeconds(40); do { $st = Ask $g $state 3; if ($st -match '^fight') { return $st }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $end); "TIMEOUT $st" }
$where = 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)'
$refill = ('local _,p=PBZ.getPlayer1() local _,mx=PBZ.game.getHealth(p) PBZ.game.setHealth(p, mx) if PBZ.game.setPosture then PBZ.game.setPosture(p, POSTURE) end return 1' -replace 'POSTURE', "$Posture")
"== lobby and start (a duel here, no clock)"
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(nil, true) return 1' 5)
Start-Sleep -Seconds 2
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
"  " + (Wait-Fight $h) + " / " + (Wait-Fight $c)
Start-Sleep -Milliseconds 600
if ($Perfect) { "  perfect deflect forced: " + (Ask $h 'local _,p=PBZ.getPlayer1() p:SetForcePerfectDeflectCVar(true) return "on"' 4) }
$trials = @($Delays | ForEach-Object { @{ Tap = $_ } }) + @($Holds | ForEach-Object { @{ Hold = $_ } })
foreach ($tr in $trials) {
    $d = if ($tr.Tap -ne $null) { $tr.Tap } else { -1 }
    [void](Ask $h $refill 3)
    $w = (Ask $h $where 3) -split ' '
    $x, $y, $z, $yaw = [double]$w[0], [double]$w[1], [double]$w[2], [double]$w[3]
    $a = $yaw * [math]::PI / 180
    [void](Ask $c ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($x + [math]::Cos($a) * $Dist),Y=$($y + [math]::Sin($a) * $Dist),Z=$($z + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=$($yaw + 180),Roll=0}) return 1") 4)
    Start-Sleep -Milliseconds 900
    Remove-Item $trigFile -ErrorAction SilentlyContinue
    $from = Log-End
    [void](Ask $h "return TRIG.arm(`"$trigLua`")" 4)
    [void](Ask $h 'return PARRY.watch(2.4)' 4)
    [void](Ask $h 'return METP.arm(3.0)' 4)
    [void](Ask $h ('return SELF.watch(' + (2.4 + $(if ($d -lt 0) { $PreHoldMs / 1000 } else { 0 })) + ')') 4)
    if ($d -lt 0) { [DeflectKeys.Win]::KeyDown($win, $keyVk); Start-Sleep -Milliseconds $PreHoldMs }
    Send-Dev $c 'eval FIGABIL.watch(2.6, 1) return FIGHT.swing()'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($trigFile) -and $sw.ElapsedMilliseconds -lt 3000) { }
    $seenAt = $sw.ElapsedMilliseconds
    if ($d -lt 0) {
        Start-Sleep -Milliseconds $tr.Hold
        [DeflectKeys.Win]::KeyUp($win, $keyVk)
    } elseif ([IO.File]::Exists($trigFile)) {
        $sw.Restart()
        while ($sw.ElapsedMilliseconds -lt $d) { }
        [DeflectKeys.Win]::KeyDown($win, $keyVk)
        Start-Sleep -Milliseconds $TapMs
        [DeflectKeys.Win]::KeyUp($win, $keyVk)
        # Both windows from the clash on (a = the defender, b = the attacker), the time since the attack began on each.
        for ($i = 0; $i -lt $Frames; $i++) {
            $t = $d + $TapMs + $sw.ElapsedMilliseconds - $d - $TapMs
            [void](Shot $h ("$Tag-$d-{0:d2}a-{1}" -f $i, $sw.ElapsedMilliseconds))
            [void](Shot $c ("$Tag-$d-{0:d2}b-{1}" -f $i, $sw.ElapsedMilliseconds))
        }
    }
    Start-Sleep -Milliseconds 300
    "  first Defence frame: " + (Ask $h 'return METP.result or "none yet"' 4)
    "  host's view of the guest's move: " + (Ask $h 'local p=PBZ.coop.partners()[1] local _,me=PBZ.getPlayer1() local at=me:K2_GetActorLocation() local g=p.ghost:K2_GetActorLocation() local to=math.deg((math.atan2 or math.atan)(at.Y-g.Y, at.X-g.X)) return string.format("moveAt %.2f s ago, path %s, moveYaw %s, figure yaw %.1f, bearing to host %.1f, guardUpAt %.2f s ago", os.clock()-(p.moveAt or 0), tostring(p.movePath and p.movePath:match("[^.]+$")), tostring(p.moveYaw), p.ghost:K2_GetActorRotation().Yaw, to, os.clock()-(PBZ.game.guardUpAt or 0))' 4)
    Start-Sleep -Milliseconds 2300
    "== " + $(if ($d -lt 0) { "held $($tr.Hold) ms" } else { "tap $d ms" }) + " after the attack starts (seen ${seenAt} ms after the swing was sent): " + (Ask $h 'return tostring(TRIG.fired)' 3)
    "  host saw: " + (Ask $h 'return PARRY.result or "none yet"' 4)
    "  frames: " + (Ask $h 'return SELF.result or "none yet"' 4)
    "  the host's figure on the guest: " + (Ask $c 'return FIGABIL.result or "none yet"' 4)
    "  guest hp: " + (Ask $c 'local _,p=PBZ.getPlayer1() return string.format("%.0f", PBZ.game.getHealth(p) or -1)' 3)
    Lines $from 'PARRIED|parried' | Where-Object { $_ -notmatch 'eval' } | Select-Object -First 3
    Start-Sleep -Milliseconds 600
}
if ($Perfect) { "  perfect deflect: " + (Ask $h 'local _,p=PBZ.getPlayer1() p:SetForcePerfectDeflectCVar(false) return "off"' 4) }
"  leave: " + (Ask $h 'PBZ.arena.command("leave") return 1' 4)
Start-Sleep -Milliseconds 400
[void](Ask $h 'PBZ.arena.command("leave") return 1' 4)
if ($Vk -eq 0) { "  unbind: " + (Ask $h "return GUARDKEY.unbind(`"$Bind`")" 8) }
