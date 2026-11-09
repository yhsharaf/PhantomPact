# The bench saves back to the pre-PvP backup, exactly: files the backup lacks (newer autosave history) are moved aside, not
# deleted; the rest copied over. Only with no bench copy running. Only ever touches C:\PBZDev.
param([string]$Backup = 'C:\PBZDev\save-backups\before-pvp-20261106-1709')
if (Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\PBZDev\*' }) { throw 'a bench copy is still running' }
$src = Join-Path $Backup 'SaveGames'
$dst = 'C:\PBZDev\ProjectPBZ\Saved\SaveGames'
$aside = 'C:\PBZDev\save-backups\pvp-test-saves-' + (Get-Date -Format 'yyyyMMdd-HHmm')
$moved = 0; $copied = 0
Get-ChildItem $dst -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($dst.Length)
    if (-not (Test-Path (Join-Path $src $rel))) {
        $to = Join-Path $aside $rel
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Move-Item $_.FullName $to
        $moved++
    }
}
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length)
    $to = Join-Path $dst $rel
    if (-not (Test-Path $to) -or (Get-FileHash $to).Hash -ne (Get-FileHash $_.FullName).Hash) {
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Copy-Item $_.FullName $to -Force
        $copied++
    }
}
$bad = @(Get-ChildItem $src -Recurse -File | Where-Object {
    (Get-FileHash $_.FullName).Hash -ne (Get-FileHash (Join-Path $dst $_.FullName.Substring($src.Length))).Hash })
$extra = @(Get-ChildItem $dst -Recurse -File | Where-Object { -not (Test-Path (Join-Path $src $_.FullName.Substring($dst.Length))) })
"saves restored: $copied copied back, $moved moved aside to $aside; differ $($bad.Count), extra $($extra.Count)"
