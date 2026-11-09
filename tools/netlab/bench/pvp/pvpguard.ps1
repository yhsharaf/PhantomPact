# The guard as the other side sees it: a duel "here", the host raises and holds the game's guard (K, bound in memory as in
# pvpdeflect2.ps1), the guest's window is shot (the host's figure should stand in the guard), the guest swings into it,
# the host lets go. The host's figure's montages on the guest, frame by frame. Only touches C:\PBZDev.
param([string]$Tag = 'gv', [int]$Gap = 260)
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
$win = [NetLab.Win]::Unreal($h.Pid)
Get-ChildItem $script:Shots -Filter "$Tag-*" -ErrorAction SilentlyContinue | Remove-Item -Force
[void](Ask $h "dofile(`"$sp/guardkey.lua`") dofile(`"$lab/fights.lua`") return 1" 8)
[void](Ask $c "dofile(`"$sp/figabil.lua`") dofile(`"$lab/fights.lua`") return 1" 8)
"  bind: " + (Ask $h 'return GUARDKEY.bind("K")' 8)
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round)) or "none"'
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(nil, true) return 1' 5)
Start-Sleep -Seconds 2
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
$end = (Get-Date).AddSeconds(40); do { Start-Sleep -Milliseconds 300; $st = Ask $h $state 3 } while ($st -notmatch '^fight' -and (Get-Date) -lt $end)
"  $st"
Start-Sleep -Milliseconds 600
# The guest 260 cm before the host, facing it: the guest's camera sees the host's figure from the front.
$w = (Ask $h 'local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local r=p:K2_GetActorRotation() return string.format("%.1f %.1f %.1f %.2f", l.X,l.Y,l.Z,r.Yaw)' 3) -split ' '
$x, $y, $z, $yaw = [double]$w[0], [double]$w[1], [double]$w[2], [double]$w[3]
$a = $yaw * [math]::PI / 180
[void](Ask $c ("local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=$($x + [math]::Cos($a) * $Gap),Y=$($y + [math]::Sin($a) * $Gap),Z=$($z + 20)},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=$($yaw + 180),Roll=0},false) pc:SetControlRotation({Pitch=-8,Yaw=$($yaw + 180),Roll=0}) return 1") 4)
Start-Sleep -Milliseconds 1200
[void](Ask $c 'return FIGABIL.watch(6.0, 1)' 4)
[void](Shot $c "$Tag-0-before")
[DeflectKeys.Win]::KeyDown($win, 0x4B)
Start-Sleep -Milliseconds 700
[void](Shot $c "$Tag-1-guard")
[void](Shot $h "$Tag-1-guard-host")
Start-Sleep -Milliseconds 800
[void](Shot $c "$Tag-2-guard")
Send-Dev $c 'eval return FIGHT.swing()'
Start-Sleep -Milliseconds 650
for ($i = 0; $i -lt 4; $i++) { [void](Shot $c ("$Tag-3-blow-{0}" -f $i)); Start-Sleep -Milliseconds 120 }
Start-Sleep -Milliseconds 900
[void](Shot $c "$Tag-4-still")
[DeflectKeys.Win]::KeyUp($win, 0x4B)
Start-Sleep -Milliseconds 350
[void](Shot $c "$Tag-5-down")
Start-Sleep -Seconds 2.2
"  the host's figure on the guest: " + (Ask $c 'return FIGABIL.result or "none yet"' 4)
"  leave: " + (Ask $h 'PBZ.arena.command("leave") return 1' 4)
Start-Sleep -Milliseconds 400
[void](Ask $h 'PBZ.arena.command("leave") return 1' 4)
"  unbind: " + (Ask $h 'return GUARDKEY.unbind("K")' 8)
python "$script:Bench\sheet.py" $script:Shots $Tag "$script:Shots\sheet-$Tag.jpg" 3 640
