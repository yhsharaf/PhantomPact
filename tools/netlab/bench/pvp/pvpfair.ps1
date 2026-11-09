# A Duel "here" with a 60 s clock on the two bench copies: the gourd in the match (3 of 3, top level, a real drink's heal),
# TIME when the clock ends round 1, each player's own bar at round 2's countdown, then home: the health and the gourd as they
# were. Shots of each step. Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Tag = 'fair')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
Touch-Lock
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
$read = 'local _,p=PBZ.getPlayer1() local g=PBZ.arena.gourdOf(p) local hp,mx=PBZ.game.getHealth(p) local m=PBZ.arena.match return string.format("hp %.0f/%.0f, gourd %s/%s level %s, held %s", hp or -1, mx or -1, tostring(g and g.CurrentTime), tostring(g and g.MaxTime), tostring(g and g.CurrentLevel), tostring(m and m.drinksLeft))'
[void](Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 500) return 1' 4)
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 640) return 1' 4)
Start-Sleep -Seconds 1
"before, host:  " + (Ask $h $read 4)
"before, guest: " + (Ask $c $read 4)
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",60) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
$fightAt = Get-Date
Start-Sleep -Seconds 1.5
"in the fight, host:  " + (Ask $h $read 4)
"in the fight, guest: " + (Ask $c $read 4)
# A real drink (R) by the host, its health lowered first; the heal read 4 s on.
[void](Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 300) return 1' 4)
Start-Sleep -Milliseconds 400
"host before the drink: " + (Ask $h $read 4)
Key $h 0x52
Start-Sleep -Seconds 4
"host after the drink:  " + (Ask $h $read 4)
[void](Shot $h "$Tag-1-drink-host")
# The clock: 60 s from the fight's start. Shots just after zero (TIME), then at round 2's countdown (each one's own bar).
$left = 60 - ((Get-Date) - $fightAt).TotalSeconds
"waiting {0:0} s for the clock" -f $left
Start-Sleep -Seconds ([math]::Max(0, $left - 0.3))
$t0 = Get-Date
for ($i = 0; $i -lt 6; $i++) {
    [void](Shot $h ("$Tag-2-time-host-{0}" -f $i)); [void](Shot $c ("$Tag-2-time-guest-{0}" -f $i))
    Start-Sleep -Milliseconds 250
}
"after the clock: " + (State $h) + " / " + (State $c)
(Wait-State $h '^count 2' 10) + " / " + (Wait-State $c '^count 2' 5)
Start-Sleep -Milliseconds 900
[void](Shot $h "$Tag-3-count2-host"); [void](Shot $c "$Tag-3-count2-guest")
"round 2, host:  " + (Ask $h $read 4)
"round 2, guest: " + (Ask $c $read 4)
Send-Dev $h 'arena leave'
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 4
"after, host:  " + (Ask $h $read 4)
"after, guest: " + (Ask $c $read 4)
[void](Shot $h "$Tag-4-home-host"); [void](Shot $c "$Tag-4-home-guest")
