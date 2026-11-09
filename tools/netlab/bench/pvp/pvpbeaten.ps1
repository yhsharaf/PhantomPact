# The four arena bosses beaten on a fresh copy of the late-game save, cleanly: one bench copy (co-op off) travels to each
# boss's arena and, without starting the fight, writes its spawners' records dead the way the game does (the spawner's own
# SpawnerSaveInfo + SetShouldNotSpawnAfterDead + Save; a record the save has already is changed in place). A trip at the
# end has the game save it all. Run with the bench taken and the late save planted. Only touches C:\PBZDev.
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$lab = $script:Lab
"tools: " + (Ask $h "dofile(`"$lab/story.lua`") dofile(`"$lab/fights.lua`") local cm = STORY.gm() pcall(function() cm:GM_State(`"preset`", `"godmode`", `"on`") end) return `"god mode on`"" 15)
$bosses = @(
    @{ Key = 'goldmask'; Map = 'PBZ_Xigu_WP'; X = -20900; Y = 291300; Z = -26450; Ids = @('1282307163') },
    @{ Key = 'yucong'; Map = 'PBZ_Fujizhilin_WP'; X = 17300; Y = 153100; Z = -1932; Ids = @('1516000262', '1440794636', '1442751637') },
    @{ Key = 'huaqianxiao'; Map = 'PBZ_Fujizhilin_WP'; X = -132300; Y = 170800; Z = -1390; Ids = @('2081298396') },
    @{ Key = 'muxiaokui'; Map = 'PBZ_Zhengdaodaying_WP'; X = -68100; Y = 77200; Z = 860; Ids = @('1369350133') }
)
function Travel($map, $x, $y, $z) {
    $r = Ask $h "return tostring(PBZ.game.travel(`"$map`", {X=$x, Y=$y, Z=$z}))" 8
    $end = (Get-Date).AddSeconds(150)
    do {
        Start-Sleep -Seconds 4
        $w = Ask $h 'local _,p=PBZ.getPlayer1() if not PBZ.valid(p) then return "loading" end local l=p:K2_GetActorLocation() return string.format("%s %.0f %.0f %.0f", PBZ.game.mapName(p), l.X, l.Y, l.Z)' 4
    } while ((Get-Date) -lt $end -and -not ($w -match $map))
    "  trip ($r): $w"
}
foreach ($b in $bosses) {
    "== $($b.Key)"
    Travel $b.Map $b.X $b.Y $b.Z
    Start-Sleep -Seconds 5
    $ids = ($b.Ids | ForEach-Object { "[`"$_`"]=1" }) -join ','
    $lua = "local want = {$ids} local out = {} for _, s in ipairs(FindAllOf(`"BP_AISpawner_C`") or {}) do if s:IsValid() then local tail = s:GetFName():ToString():match(`"_(%d+)$`") if tail and want[tail] then local ok = pcall(function() s.SetShouldNotSpawnAfterDead = true s.SpawnerSaveInfo.IsAlive = false s:Save() end) out[#out+1] = tail .. `" saved `" .. tostring(ok) end end end local ai = FindFirstOf(`"PBZAISaveGameWorldSubsystem`") ai.SpawnerSaveData:ForEach(function(k, v) local key = k:get() key = type(key)==`"string`" and key or key:ToString() local tail = key:match(`"_(%d+)$`") if tail and want[tail] then pcall(function() local x = v:get() x.IsAlive = false end) out[#out+1] = tail .. `" record `" .. tostring(v:get().IsAlive) end end) return table.concat(out, `" ; `")"
    "  " + (Ask $h $lua 12)
    "  bar: " + (Ask $h 'return tostring(FIGHT.bars())' 5)
}
"== a trip, for the game to save it"
Travel 'PBZ_Xigu_WP' -20900 291300 -26450
Start-Sleep -Seconds 5
"unlocked: " + (Ask $h 'PBZ.arena.readUnlocked() local t={} for k,v in pairs(PBZ.arena.unlocked or {}) do t[#t+1]=k end table.sort(t) return table.concat(t," ")' 10)
