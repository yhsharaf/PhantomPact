<#
.SYNOPSIS
    Everything that needs no game, in one command: builds, then the logic, the processes over real sockets, and two relays
    through a clean and a bad connection. The last line is PASS or FAIL. Takes about 3 minutes; exit code 1 on FAIL.

.EXAMPLE
    .\tools\netlab\all.ps1
    .\tools\netlab\all.ps1 -NoBuild
#>
param([switch]$NoBuild, [switch]$NoRestart, [int]$Port = 0)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Port) { $Port = 48000 + ($PID % 40) * 40 }     # several runs at once mustn't meet on a port
$failed = [System.Collections.ArrayList]::new()

function Step($name, [scriptblock]$body) {
    "`n=== $name"
    $start = Get-Date
    try {
        & $body
    } catch {
        "  FAIL $_"
        [void]$failed.Add($name)
    }
    "    ($([int]((Get-Date) - $start).TotalSeconds) s)"
}

# Tests run from a copy of their own: another build can't pull the file away, and they can't hold up another build.
$private = Join-Path $env:TEMP "pp-all-$PID"
New-Item -ItemType Directory -Force $private | Out-Null
$cli = Join-Path $private 'relay_cli.exe'

Step 'build' {
    if (-not $NoBuild) {
        # build-native.ps1 ends without releasing its lock, which leaves it "abandoned": the next wait on it throws.
        $lock = New-Object System.Threading.Mutex($false, 'Global\PhantomPactBuild')
        try { [void]$lock.WaitOne() } catch [System.Threading.AbandonedMutexException] {}
        $lock.ReleaseMutex()
        & (Join-Path $root 'tools\build-native.ps1') 2>&1 | Where-Object { $_ -match 'error|warning C|KB$' } | ForEach-Object { "  $_" }
    }
    Copy-Item (Join-Path $root 'native\build\relay_cli.exe') $cli -Force
}

Step 'lua check' {
    python -I (Join-Path $PSScriptRoot 'lualint.py')
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('lua check') }
}

Step 'events' {
    python -I (Join-Path $PSScriptRoot 'eventcheck.py') | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('events') }
}

Step 'lua, four players' {
    # Skipped on a PC with no Lua DLL (luasim.py says which it looks for).
    $out = python -I (Join-Path $PSScriptRoot 'luasim.py') four
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|No Lua DLL' } | ForEach-Object { "  $_" }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0 -and ($out -notmatch 'No Lua DLL')) { [void]$failed.Add('lua, four players') }
}

Step 'lua, a PvP match' {
    $out = python -I (Join-Path $PSScriptRoot 'luasim.py') pvp
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|No Lua DLL' } | ForEach-Object { "  $_" }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0 -and ($out -notmatch 'No Lua DLL')) { [void]$failed.Add('lua, a PvP match') }
}

Step 'relay_cli test' {
    $out = & $cli test --port ($Port + 30)
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL' } | ForEach-Object { $_ }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0) { [void]$failed.Add('relay_cli test') }
}

if (-not $NoRestart) { Step 'restart-test' {
    $out = & (Join-Path $PSScriptRoot 'restart-test.ps1') -Cli $cli -Port $Port
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|^==' } | ForEach-Object { $_ }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0) { [void]$failed.Add('restart-test') }
} }

function Bench($name, $limit_ms, [hashtable]$link) {
    $out = & (Join-Path $PSScriptRoot 'bench.ps1') @link -Seconds 8 -Cli $cli -Port ($Port + 34) -Work (Join-Path $private 'bench')
    $line = $out | Where-Object { $_ -match '^ghost behind real' } | Select-Object -First 1
    $sure = $out | Where-Object { $_ -match '^sure_lane' } | Select-Object -First 1
    $p95 = if ($line -match 'p95\s+([\d.]+)') { [double]$Matches[1] } else { -1 }
    $wrong = if ($sure -match 'wrong_order=(\d+)') { [int]$Matches[1] } else { -1 }
    $got = if ($sure -match 'got=(\d+)') { [int]$Matches[1] } else { 0 }
    $good = $p95 -ge 0 -and $p95 -lt $limit_ms -and $wrong -eq 0 -and $got -gt 40
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) $name`: ghost $p95 ms behind at the 95th percentile (limit $limit_ms), $got sure events, $wrong out of order"
    if (-not $good) { [void]$failed.Add("bench: $name") }
}

Step 'bench' {
    Bench 'clean link' 60 @{ Delay = 2; Jitter = 0 }
    Bench 'bad link' 320 @{ Delay = 40; Jitter = 20; Loss = 2; StallEvery = 3; StallMs = 250 }
}

Step 'bench, four players' {
    $out = & (Join-Path $PSScriptRoot 'party-bench.ps1') -Seconds 8 -Cli $cli -Port ($Port + 38) -Work (Join-Path $private 'party')
    $out | Where-Object { $_ -match '^(ok|FAIL)|^\s+(ok|FAIL)' } | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('bench, four players') }
}

Remove-Item -Recurse -Force $private -ErrorAction SilentlyContinue
if ($failed.Count) {
    "`nFAIL: $($failed -join ', ')"
    exit 1
}
"`nPASS: build, relay_cli test, $(if ($NoRestart) { 'bench (restart-test skipped)' } else { 'restart-test and bench' })"
exit 0
