<#
.SYNOPSIS
    Records a real co-op session for debugging: UE4SS.log from every launch (the game overwrites it on each start),
    crash dumps, net_status.txt over time, memory use, and how Tailscale reaches the partner (direct or relayed).
    Reads only; changes nothing in the game. Waits for PBZ.exe, and stops by itself once the game has been closed
    for -GoneMinutes. Any Secret in the ini is left out of the copy.

.EXAMPLE
    .\tools\record-session.ps1 -Out D:\PhantomPactLogs
#>
param(
    [string]$Out = (Join-Path $env:USERPROFILE 'PhantomPactLogs'),
    [double]$GoneMinutes = 15,
    [double]$MaxHours = 16
)
$ErrorActionPreference = 'SilentlyContinue'
$folder = Join-Path $Out (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force $folder | Out-Null
$began = Get-Date
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
function Note([string]$File, [string]$Text) { Add-Content (Join-Path $folder $File) "$(Get-Date -Format 'HH:mm:ss.fff') $Text" -Encoding utf8 }
Note 'recorder.txt' "recording to $folder"

$seenAt, $ue4ss, $described, $tick, $stamp = $null, $null, $false, 0, $null
while (((Get-Date) - $began).TotalHours -lt $MaxHours) {
    $tick++
    # The launcher is also PBZ.exe, elsewhere and small: the real game is the one beside ue4ss.
    $game = Get-Process PBZ | Where-Object { $_.Path -and (Test-Path (Join-Path (Split-Path $_.Path) 'ue4ss')) } | Sort-Object StartTime | Select-Object -First 1
    if ($game) {
        $seenAt = Get-Date
        $ue4ss = Join-Path (Split-Path $game.Path) 'ue4ss'
        $mod = Join-Path $ue4ss 'Mods\PBZCoop'
        if (-not $described) {
            $described = $true
            Get-Content (Join-Path $mod 'PhantomPact.ini') | Where-Object { $_ -notmatch '^\s*Secret\s*=' } | Set-Content (Join-Path $folder 'PhantomPact.ini')
            Note 'setup.txt' "main.dll $((Get-FileHash (Join-Path $mod 'dlls\main.dll')).Hash)"
            Get-NetConnectionProfile | ForEach-Object { Note 'setup.txt' "network: $($_.InterfaceAlias) $($_.NetworkCategory)" }
            Get-NetFirewallApplicationFilter -Program $game.Path | Get-NetFirewallRule | ForEach-Object { Note 'setup.txt' "firewall: $($_.Action) $($_.Direction) profile=$($_.Profile) enabled=$($_.Enabled)" }
        }
        $status = Get-Content (Join-Path $mod 'net_status.txt') -Raw
        Note 'net_status.log' ("mem={0}MB {1}" -f [math]::Round($game.WorkingSet64 / 1MB), ("$status".Trim()))
        # Named by the game's start time, so the next launch can't overwrite this copy.
        $stamp = $game.StartTime.ToString('HHmmss')
        if ($tick % 5 -eq 0) {
            Copy-Item (Join-Path $ue4ss 'UE4SS.log') (Join-Path $folder "UE4SS-$stamp.log") -Force
            foreach ($f in 'relay_log.txt', 'relay_error.txt') { Copy-Item (Join-Path $mod $f) (Join-Path $folder "$stamp-$f") -Force }
        }
        if ($tick % 15 -eq 0 -and (Test-Path $tailscale) -and "$status" -match 'peer=(\d+\.\d+\.\d+\.\d+)') {
            $peer = $Matches[1]
            Note 'tailscale.log' ("ping: " + ((& $tailscale ping --c 1 --timeout 3s $peer 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' | '))
            Note 'tailscale.log' ("status: " + ((& $tailscale status 2>&1 | Where-Object { "$_" -match [regex]::Escape($peer) } | ForEach-Object { "$_".Trim() }) -join ' | '))
        }
    } elseif ($seenAt -and ((Get-Date) - $seenAt).TotalMinutes -ge $GoneMinutes) {
        break
    }
    if ($ue4ss) {
        # The final copy after a crash or quit, and the crash dump, kept even if the game is gone.
        Get-ChildItem $ue4ss -Filter *.dmp | Where-Object { $_.LastWriteTime -gt $began -and -not (Test-Path (Join-Path $folder $_.Name)) } | ForEach-Object {
            Copy-Item $_.FullName $folder
            Note 'recorder.txt' "crash dump: $($_.Name)"
        }
        if (-not $game -and $stamp) {
            Copy-Item (Join-Path $ue4ss 'UE4SS.log') (Join-Path $folder "UE4SS-$stamp.log") -Force
            $stamp = $null
        }
    }
    Start-Sleep 2
}
Note 'recorder.txt' 'stopped'
