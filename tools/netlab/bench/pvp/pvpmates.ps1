# Teammates' bars in a real team match: host and guest (Crimson) against the bot (Azure), Death, a place by number (0 here).
# Shots of both screens at the start, after the guest takes two blows' worth (the blood chunk, then drained), with the
# guest down (an empty, dimmed bar on the host's screen), and the fog walls by their own collision (game.closedFogNear).
# Only touches C:\PBZDev and the bot's files.
param([int]$BotSlot = 3, [int]$Place = 3, [string]$Tag = 'mates')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$bot = "$script:Scratch\bot3"
$loadout = 'Tang,PoJun,ShachiHook,TigerCannon'
function Say([string]$Line) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Line`n")
    for ($try = 0; $try -lt 20; $try++) {
        try {
            $fs = [IO.File]::Open("$bot\say.txt", 'Append', 'Write', 'ReadWrite')
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
function BotSpot {
    $r = Ask $h ('local m=PBZ.arena.match if not m then return "none" end local d=PBZ.arena.middleOf(m) local s=m.place==0 and 0 or 1 return string.format("%d %s %.1f %.1f %.1f %.1f %d %d", m.id, tostring(m.teams[BOT]), d.X, d.Y, d.Z, (m.middle and m.middle.Yaw) or 0, m.spots[BOT] or 1, m.place)' -replace 'BOT', $BotSlot) 4
    if (-not $r -or $r -eq 'none') { return $null }
    $f = $r -split ' '
    [pscustomobject]@{ Id = [int]$f[0]; Place = [int]$f[7] }
}
"== a team match: host and guest against the bot, place $Place"
[void](Ask $h "PBZ.arena.choose(`"mode`",`"death`") PBZ.arena.choose(`"timer`",0) PBZ.arena.choose(`"place`",$Place) PBZ.arena.setPick(1) return 1" 5)
Send-Dev $c 'arena team 1'
Start-Sleep -Milliseconds 600
[void](Ask $c 'PBZ.arena.setPick(1, true) return 1' 5)
Say "AR pick 2 1 goldmask,huaqianxiao,muxiaokui,yucong 1.7.0 $loadout"
Start-Sleep -Seconds 2.5
"  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())' 5)
"  start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
$b = $null
$end = (Get-Date).AddSeconds(20)
do { $b = BotSpot; if ($b) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $end)
# The bot stands at the arena's middle (its own spot is the host's to work out; the bars don't need it there).
$mid = (Ask $h 'local m=PBZ.arena.match local d=PBZ.arena.middleOf(m) return string.format("%.0f %.0f %.0f", d.X, d.Y, d.Z)' 4) -split ' '
Say ("!at {0} {1} {2} 0" -f $mid[0], $mid[1], ([double]$mid[2] + 90))
Say "!hp 1360 1360"
Start-Sleep -Seconds 1
Say "AR here $($b.Id) there"
"  " + (Wait-State $h '^fight' 150) + " / " + (Wait-State $c '^fight' 60)
Start-Sleep -Seconds 1.5
[void](Shot $h "$Tag-1-start-host")
[void](Shot $c "$Tag-1-start-guest")
"  walls closed near the middle: " + (Ask $h 'local m=PBZ.arena.match local d=PBZ.arena.middleOf(m) local w=PBZ.game.closedFogNear(d, 6000) return w and string.format("a closed wall %.0f m from the middle", math.sqrt((w.at.X-d.X)^2+(w.at.Y-d.Y)^2)/100) or "none within 60 m"' 6)
"  == the guest takes two blows' worth"
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 900) return 1' 4)
Start-Sleep -Milliseconds 250
[void](Shot $h "$Tag-2-blow-host")
Start-Sleep -Milliseconds 300
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 600) return 1' 4)
Start-Sleep -Milliseconds 250
[void](Shot $h "$Tag-3-blow2-host")
Start-Sleep -Seconds 2
[void](Shot $h "$Tag-4-drained-host")
"  the host's bars: " + (Ask $h 'return tostring(PBZ.arena.match and "fight on")' 3)
"  == the guest down"
Send-Dev $c 'arena down'
Start-Sleep -Seconds 1.5
[void](Shot $h "$Tag-5-guestdown-host")
[void](Shot $c "$Tag-5-guestdown-guest")
"  state: " + (State $h)
"  == the bot down: Azure out"
Say "!hp 1 1360"
Say "AR down $($b.Id) 1 1"
"  " + (Wait-State $h '^finish' 10)
"  result: " + (Wait-State $h '^(result|none)' 20)
[void](Shot $h "$Tag-6-result-host")
"  home: " + (Wait-State $h '^none' 150) + " / " + (Wait-State $c '^none' 60)
"== errors"
Lines 0 'arena screen|error|Error' | Where-Object { $_ -notmatch 'eval ok|ArIsError|ArIsCriticalError|bKismetScriptError|ProcessConsoleExec' -and $_ -match ((Get-Date).ToString('HH:')) } | Select-Object -Last 6
