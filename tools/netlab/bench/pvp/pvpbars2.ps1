# A foe's boss bar on the guest's screen, in a Duel "here": its gold posture strip moved by the host's own posture (said with
# its place), and the host's figure made again with one bar still up, the old one taken down; none left at home. Shots of
# the strip at full and at half. Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Tag = 'bars2')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
# On the guest: the bars up, the host's posture share as heard, the strip's own percent on the host's bar.
$bars = 'local hud=FindFirstOf("PBZHUDLayout") local n=0 pcall(function() n=#hud:GetBossHPBarInstances() end) local body=PBZ.coop.playerBody and PBZ.coop.playerBody(1) local addr=PBZ.valid(body) and body:GetAddress() local pct="?" pcall(function() local b=PBZ.game.foeBar(addr) pct=string.format("%.2f", b.BreakmeterBar.RealBar.Percent) end) local vis="?" pcall(function() local b=PBZ.game.foeBar(addr) vis=tostring(b.BreakmeterBar:GetVisibility()) end) return "bars "..n.." figure "..tostring(addr).." share "..tostring(PBZ.net.postureShare).." strip "..pct.." vis "..vis'
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 2
"guest, the fight on: " + (Ask $c $bars 5)
[void](Shot $c "$Tag-1-full-guest")
"host posture to half: " + (Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setPosture(p, 320) return tostring(PBZ.game.getPosture(p))' 4)
Start-Sleep -Milliseconds 400
"guest, 0.4 s on: " + (Ask $c $bars 5)
Start-Sleep -Seconds 1.5
"guest, 2 s on:   " + (Ask $c $bars 5)
[void](Shot $c "$Tag-2-half-guest")
# The host's figure made again on the guest, a new body (the parked one not taken back).
"remake: " + (Ask $c 'local n=PBZ.net local u=n.unparkClone n.unparkClone=function() return nil end local ok,e=pcall(function() PBZ.coop.commands.ghost("clone") end) PBZ.game.after(3, function() n.unparkClone=u end) return tostring(ok).." "..tostring(e)' 6)
Start-Sleep -Seconds 5
"guest, after the remake: " + (Ask $c $bars 5)
[void](Shot $c "$Tag-3-remade-guest")
Cmd $h 'arena leave'
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 3
"guest at home: " + (Ask $c $bars 5)
"host at home:  " + (Ask $h $bars 5)
