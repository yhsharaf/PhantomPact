# Every fog wall of every story map, tried from both sides on one copy (the guest by default): walls.lua stands the player
# 6 m off a side, closes the wall and puts them through it with the mod's own pass. Wall positions come from the map
# surveys (survey-*.tsv, FOG rows). Log: pp-netlab/walls-log.txt, one line per side: THROUGH, BACK (no floor past it, sent
# back), FELL, or why it wasn't tried.
param([int]$Instance = 2, [string]$Only = '', [string[]]$Skip = @(), [string]$Out = 'C:\PBZDev\pp-netlab\walls-log.txt')
. (Join-Path $PSScriptRoot 'tourlib.ps1')
$g = if ($Instance -eq 1) { $script:H } else { $script:C }
$levels = @(
    @{ map = 'Xigu'; bell = 'NLES_003' }, @{ map = 'Fujizhilin'; bell = 'LZSJ_010' }, @{ map = 'Zhengdaodaying'; bell = 'SXC_01_01' },
    @{ map = 'Pangzhen'; bell = 'SZ_001' }, @{ map = 'Houjie'; bell = 'SZ_005' }, @{ map = 'Huanshuyiji2'; bell = 'BrokenBell_HSSYJ_01' },
    @{ map = 'DengDingShanDao'; bell = 'JJYBP_001' }, @{ map = 'Ximeng'; bell = 'Bell_XM_001' }, @{ map = 'Duanhun'; bell = 'DH_001' }
)
$load = 'dofile("C:/PBZDev/netlab/real.lua") dofile("C:/PBZDev/netlab/story.lua") dofile("C:/PBZDev/netlab/walls.lua") return 1'
function Note([string]$t) { $t | Tee-Object -FilePath $Out -Append }
Note "=== walls $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
foreach ($lv in $levels) {
    if (($Only -and $lv.map -ne $Only) -or $Skip -contains $lv.map) { continue }
    $rows = Select-String -Path "C:\PBZDev\pp-netlab\survey-PBZ_$($lv.map)_WP.tsv" -Pattern "^FOG`tBP_FogDoor_C" | ForEach-Object {
        $f = $_.Line -split "`t"; $p = $f[2] -split ' '
        [pscustomobject]@{ name = $f[1]; x = [double]$p[0]; y = [double]$p[1]; z = [double]$p[2] }
    } | Where-Object { [math]::Abs($_.x) + [math]::Abs($_.y) -gt 1 } | Sort-Object name -Unique
    Note "--- $($lv.map): $(@($rows).Count) walls, bell $($lv.bell)"
    [void](Ask $g $load 6)
    [void](Ask $g "return STORY.go(`"$($lv.bell)`")" 8)
    Start-Sleep -Seconds 6
    $w = Wait-Player $g 150
    if ($w -ne 'ready') { Note "  didn't arrive: $w"; continue }
    Start-Sleep -Seconds 3
    [void](Ask $g $load 6)
    foreach ($r in $rows) {
        if (-not (Alive $g)) { Note 'THE COPY DIED'; return }
        $tail = $r.name.Substring($r.name.Length - 14)
        [void](Ask $g "return REAL.flyTo($([int]$r.x), $([int]$r.y), $([int]$r.z + 400))" 6)
        Start-Sleep -Seconds 5
        $i = Ask $g "return WALLS.find(`"$tail`")" 6
        if ($i -eq '0' -or $i -like 'ERROR*' -or -not $i) { Note "  $tail at $([int]$r.x),$([int]$r.y),$([int]$r.z): not loaded ($i)"; continue }
        foreach ($side in 1, -1) {
            [void](Ask $g "return WALLS.stand($i, $side)" 6)
            Start-Sleep -Seconds 3
            [void](Ask $g 'return WALLS.land()' 4)
            Start-Sleep -Milliseconds 2500
            $at = Ask $g "return WALLS.where($i)" 4
            $mode, $sign, $dz = $at -split ' '
            if ($mode -ne '1' -or [double]$dz -lt -1500) { Note "  $tail side $side`: no floor to start from ($at)"; continue }
            [void](Ask $g "return WALLS.close($i)" 4)
            Start-Sleep -Seconds 2
            $p = Ask $g "return WALLS.pass($i, $side)" 6
            if ($p -notlike 'to *') { Note "  $tail side $side`: not tried, the player didn't stay by the wall ($p, $at)"; continue }
            Start-Sleep -Seconds 3
            $a = Ask $g "return WALLS.after($i, $side)" 6
            Note "  $tail side $side`: $a ($p)"
        }
    }
}
Note "WALLS DONE $(Get-Date -Format HH:mm:ss)"
