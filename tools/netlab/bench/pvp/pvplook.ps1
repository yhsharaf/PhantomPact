# The match screen's look on one copy, with no match: its UI script and arena data loaded again from the dev mod folder
# (uilook.lua), then the countdown, the winners' and the losers' last screens and the finishing 斩 played and shot at set
# moments (shots\<Tag>-cd-*, -won-*, -lost-*, -slay-*; the number is hundredths of a second in). -Sync first copies the
# repo's arenaui.lua, arenas.lua and art\pvp into that folder (a copy started later loads them as they are). Only touches
# C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Tag = 'look', [ValidateSet('guest', 'host')][string]$Copy = 'guest', [switch]$Sync)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$g = Load-Copy "$script:Scratch\pvp-$Copy.json"
$bench = $script:Bench -replace '\\', '/'
$scripts = (Join-Path $script:ModDir 'Scripts\') -replace '\\', '/'
if ($Sync) {
    foreach ($f in 'arenaui.lua', 'arenas.lua') { Copy-Item "$script:Repo\mod\PBZCoop\Scripts\$f" (Join-Path $script:ModDir 'Scripts') -Force }
    Copy-Item "$script:Repo\mod\PBZCoop\art\pvp\*" (Join-Path $script:ModDir 'art\pvp') -Force
}
"load " + (Ask $g "dofile(`"$bench/uilook.lua`") return 'ok'" 8)
Start-Sleep -Milliseconds 1300
"reload " + (Ask $g "return UILOOK.reload(`"$scripts`")" 8)
Start-Sleep -Milliseconds 1300

function Shots([string]$Name, [double[]]$Times) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($t in $Times) {
        while ($sw.Elapsed.TotalSeconds -lt $t) { Start-Sleep -Milliseconds 10 }
        $null = Shot $g ("{0}-{1}-{2:000}" -f $Tag, $Name, [int]($t * 100))
    }
}

# (Each command's answer comes back a few frames after it ran, so a shot's moment is good to a tenth of a second or two.)
"count " + (Ask $g "return UILOOK.count(3)")
Shots 'cd' @(0.05, 0.35, 0.95, 1.3, 1.95, 2.3, 2.85, 3.05, 3.3, 3.6, 4.1)
Start-Sleep -Milliseconds 800
"stop " + (Ask $g "return UILOOK.stop()")
Start-Sleep -Milliseconds 1300
foreach ($k in 'won', 'lost') {
    "card " + (Ask $g "return UILOOK.card('$k')")
    Shots $k @(0.2, 0.7, 1.4, 2.4, 3.6)
    "stop " + (Ask $g "return UILOOK.stop()")
    Start-Sleep -Milliseconds 1300
}
"slay " + (Ask $g "return UILOOK.slay()")
Shots 'slay' @(0.1, 0.35, 0.6, 0.9, 1.3)
Start-Sleep -Milliseconds 2500
"stop " + (Ask $g "return UILOOK.stop()")
foreach ($p in 'cd', 'won', 'lost', 'slay') {
    python -I "$script:Bench\sheet.py" $script:Shots "$Tag-$p" (Join-Path $script:Shots "$Tag-$p-sheet.jpg") 4 480
}
