# Takes the bench, installs this worktree's mod and main.dll on C:\PBZDev, starts copies (no keys pressed: look first).
# -Two: a host and a guest on loopback; otherwise one copy with co-op off. Handles go to pvp-host.json / pvp-guest.json.
param([switch]$Two, [hashtable]$HostSettings = @{}, [hashtable]$GuestSettings = @{})
. (Join-Path $PSScriptRoot 'pvplib.ps1')
& "$script:Repo\tools\netlab\bench-lock.ps1" -Take pvp
"mod installed, main.dll " + (Install-DevMod)
if ($Two) {
    $h = Start-DevGame -Role Host -Instance 1 -Settings $HostSettings
    Start-Sleep -Seconds 20
    $c = Start-DevGame -Role Guest -Instance 2 -Settings $GuestSettings
    Save-Copy $c "$script:Scratch\pvp-guest.json"
    "guest pid $($c.Pid)"
} else {
    $h = Start-DevGame -Role Off -Instance 1 -Settings $HostSettings
}
Save-Copy $h "$script:Scratch\pvp-host.json"
"host pid $($h.Pid)"
