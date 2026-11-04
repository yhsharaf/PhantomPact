<#
.SYNOPSIS
    Every boss's fog walls, from the outside, on one copy (the guest by default). For each story map: every spawner the map
    survey found is flown to and asked whether it makes a boss (the codex); for each boss, every wall a real fight would
    close around it (the mod's 60 m rule) is tried: the player stands on floor outside it, the wall is closed, and the
    mod's own E pass takes them toward the boss. A boss is reachable if any of its walls lets them in.
    Log: pp-netlab/bosswalls-log.txt. Loads netlab/real.lua, story.lua, bosswalls.lua.

.EXAMPLE
    .\tools\netlab\bench\bosswalls.ps1 -Only Xigu
#>
param([int]$Instance = 2, [string]$Only = '', [string[]]$Skip = @(), [string]$Out = 'C:\PBZDev\pp-netlab\bosswalls-log.txt')
. (Join-Path $PSScriptRoot 'tourlib.ps1')
$g = if ($Instance -eq 1) { $script:H } else { $script:C }
$levels = @(
    @{ map = 'Xigu'; bell = 'NLES_003' }, @{ map = 'Fujizhilin'; bell = 'LZSJ_010' }, @{ map = 'Zhengdaodaying'; bell = 'SXC_01_01' },
    @{ map = 'Pangzhen'; bell = 'SZ_001' }, @{ map = 'Houjie'; bell = 'SZ_005' }, @{ map = 'Huanshuyiji2'; bell = 'BrokenBell_HSSYJ_01' },
    @{ map = 'DengDingShanDao'; bell = 'JJYBP_001' }, @{ map = 'Ximeng'; bell = 'Bell_XM_001' }, @{ map = 'Duanhun'; bell = 'DH_001' }
)
$load = 'dofile("C:/PBZDev/netlab/real.lua") dofile("C:/PBZDev/netlab/story.lua") dofile("C:/PBZDev/netlab/bosswalls.lua") return 1'
function Note([string]$t) { $t | Tee-Object -FilePath $Out -Append }
Note "=== boss walls $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summary = @()
foreach ($lv in $levels) {
    if (($Only -and $lv.map -ne $Only) -or $Skip -contains $lv.map) { continue }
    $rows = Select-String -Path "C:\PBZDev\pp-netlab\survey-PBZ_$($lv.map)_WP.tsv" -Pattern "^SPAWNER`t" | ForEach-Object {
        $f = $_.Line -split "`t"; $p = $f[5] -split ' '
        [pscustomobject]@{ name = $f[1]; x = [double]$p[0]; y = [double]$p[1]; z = [double]$p[2] }
    } | Where-Object { [math]::Abs($_.x) + [math]::Abs($_.y) -gt 1 }     # (arenas in the sky too: Xigu's is 20 km up)
    Note "--- $($lv.map): $(@($rows).Count) spawners, bell $($lv.bell)"
    [void](Ask $g $load 6)
    [void](Ask $g "return STORY.go(`"$($lv.bell)`")" 8)
    Start-Sleep -Seconds 6
    $w = Wait-Player $g 150
    if ($w -ne 'ready') { Note "  didn't arrive: $w"; continue }
    Start-Sleep -Seconds 3
    [void](Ask $g $load 6)
    $seen = @{}
    foreach ($r in $rows) {
        if (-not (Alive $g)) { Note 'THE COPY DIED'; return }
        [void](Ask $g "return REAL.flyTo($([int]$r.x), $([int]$r.y), $([int]$r.z + 400))" 6)
        Start-Sleep -Seconds 4
        # (Every spawner with fog walls round it is an arena: the codex doesn't call HookMan a boss. Each arena once.)
        $b = Ask $g "return BW.boss($([int]$r.x), $([int]$r.y), $([int]$r.z))" 6
        if (-not $b -or $b -eq 'none' -or $b -like 'ERROR*') { continue }
        $n = Ask $g 'return BW.walls()' 8
        if (-not $n -or [int]$n -eq 0) { continue }
        $key = Ask $g 'return BW.key()' 6
        if ($seen[$key]) { $seen[$key] += ", $($r.name)"; continue }
        $seen[$key] = $r.name
        $id = $r.name
        Note "  $($r.name) ($b) at $([int]$r.x),$([int]$r.y),$([int]$r.z): $n wall(s) within 60 m"
        $in = 0; $fallback = 0
        Start-Sleep -Seconds 5      # (the ground round an arena streams in after the flight: "no floor" was often that)
        for ($k = 1; $k -le [int]$n; $k++) {
            $s = Ask $g "return BW.stand($k)" 8
            if ($s -notlike 'standing*') { Start-Sleep -Seconds 5; $s = Ask $g "return BW.stand($k)" 8 }
            if ($s -notlike 'standing*') { Note "    wall $k`: $s"; continue }
            Start-Sleep -Milliseconds 2500
            [void](Ask $g "return BW.close($k)" 4)
            Start-Sleep -Seconds 2
            $p = Ask $g "return BW.pass($k)" 8
            if ($p -like 'no closed wall*') {
                [void](Ask $g "return BW.close($k)" 4)
                Start-Sleep -Seconds 3
                $p = Ask $g "return BW.pass($k)" 8
            }
            if ($p -notlike 'to *') { Note "    wall $k`: $s, pass $p"; [void](Ask $g "return BW.after($k)" 4); continue }
            Start-Sleep -Seconds 3
            $a = Ask $g "return BW.after($k)" 6
            if ($a -like 'IN*') { $in++; if ($p -like '*fallback*') { $fallback++ } }
            Note "    wall $k`: $a ($s, pass $p)"
        }
        $verdict = if ([int]$n -eq 0) { 'NO WALLS (no fog fight here, or walls not loaded)' } elseif ($in -gt 0) { "REACHABLE ($in of $n walls, $fallback by the fallback)" } else { 'NOT REACHED' }
        Note "    => $verdict"
        $summary += "$($lv.map) $id ($(($b -split ' ')[-1])): $verdict"
    }
    foreach ($k in $seen.Keys) { if ($seen[$k] -match ',') { Note "  same arena: $($seen[$k])" } }
}
Note "--- summary"
$summary | ForEach-Object { Note "  $_" }
Note "BOSS WALLS DONE $(Get-Date -Format HH:mm:ss)"
