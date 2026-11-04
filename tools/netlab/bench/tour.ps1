# The whole story, one stop per entry: apply the region's story events on both copies, go to a bell, run stop.ps1.
param([int]$StartAt = 0, [int]$Count = 99, [string]$Out = 'C:\PBZDev\pp-netlab\tour-log.txt')
. (Join-Path $PSScriptRoot 'tourlib.ps1')
$stops = @(
    @{ n = 'Xigu';            from = 1;   to = 97;  bell = 'NLES_003' },
    @{ n = 'Fuji forest';     from = 98;  to = 146; bell = 'LZSJ_010' },
    @{ n = 'Lu village';      from = 147; to = 232; bell = 'SXC_01_01' },
    @{ n = 'Pang town';       from = 233; to = 282; bell = 'SZ_001' },
    @{ n = 'Back street';     from = 283; to = 345; bell = 'SZ_005' },
    @{ n = 'Righteous camp';  from = 346; to = 419; bell = 'YXZR_001' },
    @{ n = 'Meigu lake';      from = 420; to = 480; bell = 'SZ_020' },
    @{ n = 'Summit path';     from = 481; to = 545; bell = 'JJYBP_001' },
    @{ n = 'Illusion ruins';  from = 546; to = 571; bell = 'BrokenBell_HSSYJ_01' },
    @{ n = 'Dream manor';     from = 572; to = 619; bell = 'Bell_XM_001' },
    @{ n = 'Soul cliff';      from = 620; to = 659; bell = 'DH_001' }
)
$i = 0
foreach ($s in $stops) {
    $i++
    if ($i - 1 -lt $StartAt -or $i - 1 -ge $StartAt + $Count) { continue }
    "=== $i $($s.n) rows $($s.from)-$($s.to) bell $($s.bell) $(Get-Date -Format HH:mm:ss)" | Tee-Object -FilePath $Out -Append
    foreach ($g in $script:H, $script:C) {
        if (-not (Alive $g)) { "copy $($g.Instance) is gone" | Tee-Object -FilePath $Out -Append; return }
        $a = Ask $g "return STORY.apply($($s.from), $($s.to))" 20
        "  apply $($g.Instance): $a" | Tee-Object -FilePath $Out -Append
    }
    $r = & (Join-Path $PSScriptRoot 'stop.ps1') -Bell $s.bell
    $r | Tee-Object -FilePath $Out -Append
    if (-not (Alive $script:H) -or -not (Alive $script:C)) { 'A COPY DIED' | Tee-Object -FilePath $Out -Append; return }
    if ($r -match 'STOP:') { 'STOPPED' | Tee-Object -FilePath $Out -Append; return }
}
'TOUR DONE' | Tee-Object -FilePath $Out -Append
