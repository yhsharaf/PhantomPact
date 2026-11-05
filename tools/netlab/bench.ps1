<#
.SYNOPSIS
    The relay between two bots through a simulated connection, no game needed. One line of numbers per side: how far
    behind the partner is shown, how evenly they move, and how long events take. Both bots run on this PC, so these are
    true delays.

.EXAMPLE
    .\tools\netlab\bench.ps1 -Delay 10 -Jitter 3 -Loss 0.2
#>
param(
    [double]$Delay = 10, [double]$Jitter = 3, [double]$Loss = 0, [double]$StallEvery = 0, [double]$StallMs = 250,
    [double]$Seconds = 15, [int]$Enemies = 0, [double]$HitchEvery = 0, [double]$HitchMs = 300, [int]$Port = 47820,
    [string]$Ini = '', [string]$Cli = '', [string]$Work = '',
    [double]$BurstLoss = 0, [double]$BurstMs = 50, [double]$EventEvery = 0.1
)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cli = if ($Cli) { $Cli } else { Join-Path $root 'native\build\relay_cli.exe' }
$work = if ($Work) { $Work } else { Join-Path $env:TEMP 'pp-netlab' }
New-Item -ItemType Directory -Force "$work\h", "$work\c" | Out-Null
$front = $Port + 1
$common = @('--seconds', $Seconds, '--enemies', $Enemies, '--hitch-every', $HitchEvery, '--hitch-ms', $HitchMs, '--event-every', $EventEvery)
if ($Ini) { $common += @('--ini', $Ini) }
$netem = Start-Process $cli -ArgumentList (@('netem', $front, $Port, '--delay', $Delay, '--jitter', $Jitter, '--loss', $Loss,
    '--stall-every', $StallEvery, '--stall-ms', $StallMs, '--burst-loss', $BurstLoss, '--burst-ms', $BurstMs,
    '--seconds', ($Seconds + 6))) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\netem.txt"
$h = Start-Process $cli -ArgumentList (@('bot', 'host', '--port', $Port, '--dir', "$work\h") + $common) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\host.txt"
Start-Sleep -Milliseconds 300
$c = Start-Process $cli -ArgumentList (@('bot', 'client', '--peer', '127.0.0.1', '--port', $front, '--dir', "$work\c") + $common) -PassThru -WindowStyle Hidden -RedirectStandardOutput "$work\client.txt"
$c.WaitForExit(($Seconds + 8) * 1000) | Out-Null
$h.WaitForExit(4000) | Out-Null
$netem.WaitForExit(6000) | Out-Null
foreach ($p in $c, $h, $netem) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -Confirm:$false } }
"== delay $Delay ms, jitter $Jitter ms, loss $Loss%, stall $StallMs ms every $StallEvery s, enemies $Enemies, hitch every $HitchEvery s"
Get-Content "$work\client.txt" | Where-Object { $_ -notmatch '^PBZCoop relay|^found|^peer' }
