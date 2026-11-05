<#
.SYNOPSIS
    A party over real sockets on this PC, no game needed: one host bot and three guest bots (or up to five, PartySize = 6),
    each guest through a bad connection of its own. Prints what each sees of the others and checks it. Bots bind to loopback
    only, and they share this PC's clock, so every delay is a true one.

.EXAMPLE
    .\tools\netlab\party-bench.ps1 -Delay 20 -Jitter 5 -Loss 1
    .\tools\netlab\party-bench.ps1 -Guests 5 -Enemies 30
#>
param(
    [double]$Delay = 10, [double]$Jitter = 3, [double]$Loss = 0, [double]$Seconds = 15, [int]$Enemies = 8, [int]$Port = 47830,
    [string]$Cli = '', [string]$Work = '', [int]$Guests = 3, [double]$EnemyEvery = 0.0333
)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cli = if ($Cli) { $Cli } else { Join-Path $root 'native\build\relay_cli.exe' }
$work = if ($Work) { $Work } else { Join-Path $env:TEMP 'pp-party' }
$Guests = [math]::Max(1, [math]::Min(5, $Guests))
$players = if ($Guests -gt 3) { 6 } else { 4 }
New-Item -ItemType Directory -Force "$work\h" | Out-Null
foreach ($n in 1..$Guests) { New-Item -ItemType Directory -Force "$work\g$n" | Out-Null }
$ini = Join-Path $work 'four.ini'
$(if ($players -eq 6) { "PartySize = 6`n" } else { "FourPlayers = On`n" }) | Set-Content $ini -Encoding ascii
$common = @('--seconds', $Seconds, '--events-for', ($Seconds - 2))
$procs = @()
$procs += Start-Process $cli -ArgumentList (@('bot', 'host', '--port', $Port, '--dir', "$work\h", '--ini', $ini, '--enemies', $Enemies,
    '--enemy-every', $EnemyEvery) + $common) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\host.txt"
Start-Sleep -Milliseconds 300
foreach ($n in 1..$Guests) {
    $front = $Port + $n
    $procs += Start-Process $cli -ArgumentList @('netem', $front, $Port, '--delay', $Delay, '--jitter', $Jitter, '--loss', $Loss, '--seconds', ($Seconds + 6)) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\netem$n.txt"
    $procs += Start-Process $cli -ArgumentList (@('bot', 'client', '--peer', '127.0.0.1', '--port', $front, '--dir', "$work\g$n") + $common) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\guest$n.txt"
}
# What the host sends, halfway through, when all of them are at it.
Start-Sleep -Seconds ([int]($Seconds / 2) + 1)
$upload = (Get-Content "$work\h\net_status.txt" -ErrorAction SilentlyContinue | Select-String -Pattern 'upload_kb_s=(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
$deadline = (Get-Date).AddSeconds($Seconds + 10)
foreach ($p in $procs) {
    $left = [int](($deadline - (Get-Date)).TotalMilliseconds)
    if ($left -gt 0) { $p.WaitForExit($left) | Out-Null }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -Confirm:$false }
}
"== one host, $Guests guests: delay $Delay ms, jitter $Jitter ms, loss $Loss%, $Enemies enemies $([math]::Round(1 / $EnemyEvery)) times a second, $Seconds s"
"host upload $upload KB/s"
$failed = 0
function Check($ok, $what) {
    if (-not $ok) { $script:failed++ }
    "$(if ($ok) { 'ok  ' } else { 'FAIL' }) $what"
}
$limit = 60 + 4 * $Delay + 4 * $Jitter
foreach ($name in @('host') + @(1..$Guests | ForEach-Object { "guest$_" })) {
    $text = Get-Content "$work\$name.txt"
    $text | Where-Object { $_ -match '^(other players|others. sure|ghost behind|passed_on|sure_lane)' } | ForEach-Object { "$name  $_" }
    $others = $text | Where-Object { $_ -match '^other players' } | Select-Object -First 1
    $p95 = if ($others -match 'p95\s+([\d.]+)') { [double]$Matches[1] } else { -1 }
    $passed = $text | Where-Object { $_ -match '^passed_on' } | Select-Object -First 1
    $from = ([regex]::Matches("$passed", 'from\d=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    $wrong = if ($passed -match 'wrong_order=(\d+)') { [int]$Matches[1] } else { -1 }
    $senders = if ($name -eq 'host') { $Guests } else { $Guests - 1 }
    if ($senders -gt 0) {
        Check ($p95 -ge 0 -and $p95 -lt $limit) "$name sees the guests within $limit ms at the 95th percentile ($p95)"
        Check (@($from).Count -eq $senders -and @($from | Where-Object { $_ -gt 40 }).Count -eq $senders -and $wrong -eq 0) "$name gets every guest's events, in order ($passed)"
    }
    if ($name -ne 'host') {
        $ghost = $text | Where-Object { $_ -match '^ghost behind' } | Select-Object -First 1
        $sure = $text | Where-Object { $_ -match '^sure_lane' } | Select-Object -First 1
        $hostWrong = if ($sure -match 'wrong_order=(\d+)') { [int]$Matches[1] } else { -1 }
        $hostGot = if ($sure -match 'got=(\d+)') { [int]$Matches[1] } else { 0 }
        Check ($ghost -match 'p95' -and $hostWrong -eq 0 -and $hostGot -gt 40) "$name gets the host's position and events ($hostGot, $hostWrong out of order)"
    }
}
$status = Get-Content "$work\host.txt" | Where-Object { $_ -match '^role=host' } | Select-Object -Last 1
Check ($status -match "players=$players slot=1") "the host's status line says it's a party"
if ($failed) { "FAIL: $failed"; exit 1 }
"ok: all"
exit 0
