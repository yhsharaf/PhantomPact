# Several stand-in players at once (relay_cli bots, each its own say/heard files in bot<n>): -Count bots joined to the bench
# host as guests, started one after another so they take the slots in order. -Stop ends them all. Nothing else is touched.
param([int]$Count = 4, [switch]$Stop, [int]$Seconds = 7200)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
# This repo's relay_cli (tools\build-native.ps1 builds it); the bots' folders sit in the work folder (pvplib.ps1).
$cli = Join-Path $script:Repo 'native\build\relay_cli.exe'
foreach ($dir in Get-ChildItem $script:Scratch -Directory -Filter 'botn*') {
    $pidFile = Join-Path $dir.FullName 'pid.txt'
    if (Test-Path $pidFile) {
        $old = [int](Get-Content $pidFile)
        $p = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($p -and $p.Path -eq $cli) { Stop-Process -Id $old -Force -Confirm:$false; "bot $old stopped" }
        Remove-Item $pidFile
    }
}
if ($Stop) { return }
for ($n = 1; $n -le $Count; $n++) {
    $w = Join-Path $script:Scratch "botn$n"
    New-Item -ItemType Directory -Force "$w\net" | Out-Null
    Set-Content "$w\say.txt" '' -Encoding ascii -NoNewline
    Set-Content "$w\heard.txt" '' -Encoding ascii -NoNewline
    $p = Start-Process $cli -ArgumentList @('bot', 'client', '--peer', '127.0.0.1', '--port', 47810, '--dir', "$w\net", '--seconds', $Seconds,
        '--events-for', 0, '--say', "$w\say.txt", '--heard', "$w\heard.txt") -PassThru -WindowStyle Hidden -RedirectStandardOutput "$w\out.txt"
    Set-Content "$w\pid.txt" $p.Id -Encoding ascii
    "botn$n pid $($p.Id)"
    Start-Sleep -Seconds 2
}
