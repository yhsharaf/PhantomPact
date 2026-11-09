# The two bench copies onto this worktree's latest code: stop them, saves back to the pre-PvP backup, install, start, wait
# for both in the game (after-crash keys: RIGHT before RETURN, never New Game). Only ever touches C:\PBZDev.
. (Join-Path $PSScriptRoot 'pvplib.ps1')
# The scripts beside this one from $PSScriptRoot, the copies' handles from the work folder ($script:Scratch).
foreach ($f in 'pvp-host.json', 'pvp-guest.json') {
    if (Test-Path "$script:Scratch\$f") { Stop-DevGame (Load-Copy "$script:Scratch\$f") }
}
$t = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $t -and (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' })) { Start-Sleep -Milliseconds 500 }
& "$PSScriptRoot\pvprestore.ps1"
# Ours already: handed back first, or -Take waits for our own note to go stale (15 minutes). The copies are stopped.
if ((Get-Content 'C:\PBZDev\bench.lock\owner.txt' -ErrorAction SilentlyContinue) -like 'pvp since*') {
    & "$script:Repo\tools\netlab\bench-lock.ps1" -Give
}
& "$PSScriptRoot\pvpstart.ps1" -Two
$h = Load-Copy "$script:Scratch\pvp-host.json"; $c = Load-Copy "$script:Scratch\pvp-guest.json"
"host in: " + (Wait-DevGameplay $h -TimeoutSec 300 -AfterCrash)
"guest in: " + (Wait-DevGameplay $c -TimeoutSec 300 -AfterCrash)
