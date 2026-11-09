# What a drink heals at a gourd level: the host's health set low, one drink, the health after. -Key: the drink pressed for
# real (a key posted to the window) rather than called. Only touches the bench copy (C:\PBZDev); its saves are put back after.
param([int[]]$Levels = @(0, 6), [int]$Key = 0)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
Touch-Lock
$read = 'local _,p=PBZ.getPlayer1() local g=PBZ.game.gourdInfo(p) local hp,mx=PBZ.game.getHealth(p) return string.format("hp %.0f/%.0f, gourd level %s, drinks %s/%s", hp or -1, mx or -1, tostring(g and g.CurrentLevel), tostring(g and g.CurrentTime), tostring(g and g.MaxTime))'
foreach ($lv in $Levels) {
    "== level $lv"
    [void](Ask $h "local _,p=PBZ.getPlayer1() local g=PBZ.game.gourdInfo(p) g.CurrentLevel=$lv g:SetCurrentTime(2) g:SetDisplayTime(2) local _,mx=PBZ.game.getHealth(p) PBZ.game.setHealth(p, mx*0.3) return 1" 5)
    Start-Sleep -Seconds 1
    "  before: " + (Ask $h $read 4)
    if ($Key) {
        Key $h $Key
    } else {
        "  use: " + (Ask $h 'local _,p=PBZ.getPlayer1() local bp=PBZ.game.backpackOf(p) local ok,r=pcall(function() return bp:UseMedicine(FName("Hulu")) end) return tostring(ok).." "..tostring(r)' 4)
    }
    Start-Sleep -Seconds 5
    "  after:  " + (Ask $h $read 4)
}
[void](Ask $h 'local _,p=PBZ.getPlayer1() local g=PBZ.game.gourdInfo(p) g.CurrentLevel=0 g:SetCurrentTime(2) g:SetDisplayTime(2) local _,mx=PBZ.game.getHealth(p) PBZ.game.setHealth(p, mx) return 1' 5)
"put back: " + (Ask $h $read 4)
