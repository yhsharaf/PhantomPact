# The third player: a relay_cli bot joined to the bench host as a guest (slot 3), standing where it's told. Its words go
# in bot3\say.txt, what it hears comes out in bot3\heard.txt. -Stop ends it. Nothing else is touched.
param([switch]$Stop, [int]$Seconds = 1800)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
# This repo's relay_cli (tools\build-native.ps1 builds it); the bot's folder sits in the work folder (pvplib.ps1).
$cli = Join-Path $script:Repo 'native\build\relay_cli.exe'
$w = "$script:Scratch\bot3"
if (Test-Path "$w\pid.txt") {
    $old = [int](Get-Content "$w\pid.txt")
    $p = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($p -and $p.Path -eq $cli) { Stop-Process -Id $old -Force -Confirm:$false; "bot $old stopped" }
    Remove-Item "$w\pid.txt"
}
if ($Stop) { return }
New-Item -ItemType Directory -Force "$w\net" | Out-Null
Set-Content "$w\say.txt" '' -Encoding ascii -NoNewline
Set-Content "$w\heard.txt" '' -Encoding ascii -NoNewline
$p = Start-Process $cli -ArgumentList @('bot', 'client', '--peer', '127.0.0.1', '--port', 47810, '--dir', "$w\net", '--seconds', $Seconds,
    '--events-for', 0, '--say', "$w\say.txt", '--heard', "$w\heard.txt") -PassThru -WindowStyle Hidden -RedirectStandardOutput "$w\out.txt"
Set-Content "$w\pid.txt" $p.Id -Encoding ascii
"bot pid $($p.Id)"
