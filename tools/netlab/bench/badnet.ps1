param([string]$Via = '--delay 40 --jitter 20 --loss 2 --stall-every 7 --stall-ms 250', [int]$Seconds = 34)
. (Join-Path $PSScriptRoot '..\dev.ps1')
$h = Get-Content "$PSScriptRoot\dev-host.json" -Raw | ConvertFrom-Json
$c = Get-Content "$PSScriptRoot\dev-guest.json" -Raw | ConvertFrom-Json
$h.Dir = 'C:\PBZDev\platform\steam\ue4ss\Mods\PBZCoop'
$c.Dir = 'C:\PBZDev\platform\steam\ue4ss\Mods\PBZCoop\inst2'
$lab = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path -replace '\\', '/'
$cli = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\native\build\relay_cli.exe')).Path
$work = (Join-Path $env:TEMP 'pp-netlab') -replace '\\', '/'
# Start the bad link, then the guest again through it: its relay's port is read at start.
$t = Get-Date
$load = "dofile(`"$lab/perf.lua`") dofile(`"$lab/pair.lua`")"
Stop-DevGame $c
Start-Sleep -Seconds 2
$netem = Start-Process $cli -ArgumentList (@('netem', 47811, 47810, '--seconds', 400) + ($Via -split ' ')) -PassThru -WindowStyle Hidden
$c = Start-DevGame -Role Guest -Instance 2 -Port 47811 -Settings @{ ThisPcOnly = 'On' }
$c | ConvertTo-Json | Set-Content "$PSScriptRoot\dev-guest.json"
"guest pid $($c.Pid), netem pid $($netem.Id)"
$ok = Wait-DevGameplay $c 200
"gameplay: $ok at $(Get-Date -Format HH:mm:ss)"
Start-Sleep -Seconds 6
Send-Dev $h "eval $load return 1"; Send-Dev $c "eval $load return 1"
Start-Sleep -Seconds 2
Send-Dev $h "eval PAIR.record(30, `"$work/bad-host.txt`") PAIR.walk(13, 700) PAIR.swing(13) return 1"
Send-Dev $c "eval PAIR.record(30, `"$work/bad-guest.txt`") return 1"
Start-Sleep -Seconds 15
Send-Dev $c 'eval PAIR.walk(13, 700) PAIR.swing(13) return 1'
Start-Sleep -Seconds 17
Send-Dev $h 'netstatus'; Send-Dev $c 'netstatus'
Start-Sleep -Seconds 1
Send-Dev $h 'moves'; Send-Dev $c 'moves'
Start-Sleep -Seconds 1
python -I "$lab/pair_report.py" "$work/bad-host.txt" "$work/bad-guest.txt"
python -I "$lab/move_report.py" "$work/bad-host.txt" "$work/bad-guest.txt"
Get-DevLog $h $t 'Relay:|Moves:|net error|event .* error|rror:|No packet|Ghost|Lost|Status' | Where-Object { $_ -notmatch '\] > ' } | ForEach-Object { $_ -replace '^\[\d{4}-\d\d-\d\d (\S+)\] \[Lua\] ', '$1 ' } | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ } } | Select-Object -Last 24
'DONE'
