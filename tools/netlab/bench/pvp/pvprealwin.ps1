# Does a boss beaten by a real blow stay beaten across a restart? The boss arenas' unlock reads the game's spawner records,
# and on 11-07 a boss killed by GE_Kill came back alive in them after a restart. Here, on the late-game save (the story past
# the four, their fights never fought), one copy (co-op off) goes to a boss's arena (the Gold-Masked One's gorge by
# default), sets his health to 1 and lands a real blow (the game's own death, as a won fight ends); his record and his
# spawner's flag are read before and after; a trip has the game save; the copy restarts and the record is read again, and
# the arena looked at. The saves are backed up first, and pvprestore.ps1 puts the bench's back after. Only touches C:\PBZDev
# and $env:TEMP\pvpbench. -NoStart: the copy is already in the game on the planted save (backed up first).
# No key goes in blind (pvplib.ps1's Enter-Game).
param([string]$Id = '1282307163', [string]$Map = 'PBZ_Xigu_WP', [int]$X = -20900, [int]$Y = 291300, [int]$Z = -26450,
    [string]$AwayMap = 'PBZ_Fujizhilin_WP', [int]$AwayX = 17300, [int]$AwayY = 153100, [int]$AwayZ = -1932,
    [switch]$NoStart)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
if (-not $NoStart) {
    $saves = 'C:\PBZDev\ProjectPBZ\Saved\SaveGames'
    $slot = Join-Path $saves 'Steam\76561198310534467\PBZSaveGame.sav'
    $late = Join-Path $saves 'Steam\76561198311530511\PBZSaveGame.sav'
    foreach ($f in 'pvp-host.json', 'pvp-guest.json') {
        if (Test-Path "$script:Scratch\$f") { Stop-DevGame (Load-Copy "$script:Scratch\$f") }
    }
    $t = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $t -and (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' })) { Start-Sleep -Milliseconds 500 }
    $backup = 'C:\PBZDev\save-backups\before-realwin-' + (Get-Date -Format 'yyyyMMdd-HHmm')
    Copy-Item $saves (Join-Path $backup 'SaveGames') -Recurse
    "saves backed up to $backup"
    Copy-Item $late $slot -Force
    "late save planted: " + ((Get-FileHash $late).Hash -eq (Get-FileHash $slot).Hash)
    & "$PSScriptRoot\pvpstart.ps1"
}
$h = Load-Copy "$script:Scratch\pvp-host.json"
if (-not (Enter-Game $h)) { "stopped: not in the game, the copy left as it is"; return }
Start-Sleep -Seconds 8
$lab = $script:Lab
function Tools {
    Ask $h "dofile(`"$lab/story.lua`") dofile(`"$lab/fights.lua`") local cm = STORY.gm() pcall(function() cm:GM_State(`"preset`", `"godmode`", `"on`") end) return `"god mode on`"" 15
}
function Travel($map, $x, $y, $z) {
    $r = Ask $h "return tostring(PBZ.game.travel(`"$map`", {X=$x, Y=$y, Z=$z}))" 8
    $end = (Get-Date).AddSeconds(150)
    do {
        Start-Sleep -Seconds 4
        $w = Ask $h 'local _,p=PBZ.getPlayer1() if not PBZ.valid(p) then return "loading" end local l=p:K2_GetActorLocation() return string.format("%s %.0f %.0f %.0f", PBZ.game.mapName(p), l.X, l.Y, l.Z)' 4
    } while ((Get-Date) -lt $end -and -not ($w -match $map))
    "  trip ($r): $w"
}
# The record (the save's own, kept for every map), and the spawner here: its flag, its enemy and that enemy's health.
$look = "local out = {} local ai = FindFirstOf(`"PBZAISaveGameWorldSubsystem`") pcall(function() ai.SpawnerSaveData:ForEach(function(k, v) local key = k:get() key = type(key)==`"string`" and key or key:ToString() if key:match(`"_$Id`$`") then out[#out+1] = `"record alive `" .. tostring(v:get().IsAlive) end end) end) if #out == 0 then out[1] = `"no record`" end for _, s in ipairs(FindAllOf(`"BP_AISpawner_C`") or {}) do pcall(function() if s:IsValid() and s:GetFName():ToString():match(`"_$Id`$`") then local a = s.SpawnedAI local hp = PBZ.valid(a) and PBZ.game.getHealth(a) out[#out+1] = string.format(`"spawner flag %s, info alive %s, enemy %s %s`", tostring(s.SetShouldNotSpawnAfterDead), tostring(s.SpawnerSaveInfo.IsAlive), PBZ.valid(a) and a:GetClass():GetFName():ToString() or `"-`", hp and string.format(`"%.0f`", hp) or `"-`") end end) end return table.concat(out, `" | `")"
"tools: " + (Tools)
"== to the arena"
Travel $Map $X $Y $Z
Start-Sleep -Seconds 6
"before: " + (Ask $h $look 10)
"nearest enemy: " + (Ask $h 'local e, d = FIGHT.nearest() return PBZ.valid(e) and string.format("%s %.0f m", e:GetClass():GetFName():ToString(), d / 100) or "none"' 6)
# The boss: the spawner's own enemy; its health to 1, then real blows from beside it till it dies.
$kill = "local boss for _, s in ipairs(FindAllOf(`"BP_AISpawner_C`") or {}) do pcall(function() if s:IsValid() and s:GetFName():ToString():match(`"_$Id`$`") then boss = s.SpawnedAI end end) end if not PBZ.valid(boss) then return `"no boss`" end PBZ.game.setHealth(boss, 1) FIGHT.beside(boss, 170) return `"set: `" .. tostring(PBZ.game.getHealth(boss))"
for ($i = 0; $i -lt 6; $i++) {
    "blow ${i}: " + (Ask $h $kill 6)
    [void](Ask $h 'return FIGHT.swing()' 5)
    Start-Sleep -Seconds 2.5
    $now = Ask $h $look 10
    "  " + $now
    # (Dead at the first blow on the bench: its health set again after that only stood the body up at 1.)
    if ($now -match 'record alive false|info alive false|enemy - -|_C 0$') { break }
}
Start-Sleep -Seconds 8
"after the kill: " + (Ask $h $look 10)
[void](Shot $h 'realwin-1-killed')
"== a trip away, so the game saves"
Travel $AwayMap $AwayX $AwayY $AwayZ
Start-Sleep -Seconds 10
"away, record: " + (Ask $h $look 10)
"== the copy restarted"
Stop-DevGame $h
$t = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $t -and (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' })) { Start-Sleep -Milliseconds 500 }
$h = Start-DevGame -Role Off -Instance 1
Save-Copy $h "$script:Scratch\pvp-host.json"
$end = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $end -and -not (Ask $h 'return 1' 3)) { Start-Sleep -Seconds 2 }
Start-Sleep -Seconds 15
[void](Shot $h 'realwin-2-title')
if (-not (Enter-Game $h)) { "stopped: not in the game, the copy left as it is"; return }
Start-Sleep -Seconds 10
"after the restart, record: " + (Ask $h $look 10)
"unlocked: " + (Ask $h 'PBZ.arena.readUnlocked() local t={} for k,v in pairs(PBZ.arena.unlocked or {}) do t[#t+1]=k end table.sort(t) return table.concat(t," ")' 10)
"tools: " + (Tools)
"== back to the arena"
Travel $Map $X $Y $Z
Start-Sleep -Seconds 8
"at the arena again: " + (Ask $h $look 10)
"bars: " + (Ask $h 'return tostring(FIGHT.bars())' 5)
[void](Shot $h 'realwin-2-back')
Stop-DevGame $h
$t = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $t -and (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' })) { Start-Sleep -Milliseconds 500 }
& "$PSScriptRoot\pvprestore.ps1"
& "$script:Repo\tools\netlab\bench-lock.ps1" -Give
