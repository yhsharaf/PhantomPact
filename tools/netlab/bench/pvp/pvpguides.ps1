# The bell's guide lines in a match by the bench's bell ("here"): hidden from the arrival, no red thread in the fight or the
# finishing move, shown again at home. Only touches C:\PBZDev.
param([string]$Tag = 'guides')
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
$guides = 'local t = {} local n = 0 for k in pairs(PBZ.arena.guidesHidden or {}) do n = n + 1 end for _, a in ipairs(FindAllOf("BP_BellGuideLine_C") or {}) do pcall(function() if a:IsValid() then t[#t+1] = tostring(a.bHidden) end end) end return #t .. " guide lines, hidden: " .. table.concat(t, ",") .. " | ours: " .. n'
function Reds($name) { python -c "from PIL import Image; im = Image.open(r'$script:Shots\$name.png').convert('RGB'); print(sum(1 for y in range(im.size[1]) for x in range(im.size[0]) if (lambda p: p[0] > 120 and p[0] > 2.2 * p[1] and p[0] > 2.2 * p[2])(im.getpixel((x, y)))))" }
"before, host: " + (Ask $h $guides 6)
[void](Ask $h 'PBZ.arena.choose("mode","death") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 2.5
"in the fight, host: " + (Ask $h $guides 6)
"in the fight, guest: " + (Ask $c $guides 6)
[void](Shot $h "$Tag-1-fight-host"); [void](Shot $c "$Tag-1-fight-guest")
"red pixels in the fight: host " + (Reds "$Tag-1-fight-host") + ", guest " + (Reds "$Tag-1-fight-guest")
Send-Dev $c 'arena down'
(Wait-State $h '^finish' 12)
Start-Sleep -Milliseconds 800
Send-Dev $h 'arena finish 2 3'
Start-Sleep -Seconds 3
[void](Shot $h "$Tag-2-fin-host"); [void](Shot $c "$Tag-2-fin-guest")
"red pixels in the finish: host " + (Reds "$Tag-2-fin-host") + ", guest " + (Reds "$Tag-2-fin-guest")
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 3
"after, host: " + (Ask $h $guides 6)
"after, guest: " + (Ask $c $guides 6)
