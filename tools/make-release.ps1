<#
.SYNOPSIS
    Builds the player package dist\PhantomPact-<version>.zip, laid out like the game folder: players extract it into
    ...\steamapps\common\PBZ and it lands in platform\steam\ue4ss\Mods\PBZCoop. Settings are in PhantomPact.ini; the
    mod starts the relay itself (autostart.lua), the built-in one in dlls\main.dll. No .bat/.ps1 files, and no
    other binaries: Nexus quarantines scripts and quarantined a bundled Python for its .exe files (1.3.1).
    Only what's listed here goes in, so runtime files the mod writes while playing (cmd.txt, net_*.txt, relay_log.txt,
    inst2\) and developer files (dev.txt, relay_cli.exe, tools\, net\) stay out, and a check refuses the zip if one
    gets in, or if the ini isn't the default one.

.EXAMPLE
    .\tools\make-release.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $root 'mod\PBZCoop\Scripts\main.lua') -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value
if (-not $version) { throw "No VERSION in main.lua" }

$stage = Join-Path $root "dist\PhantomPact-$version"
if (Test-Path $stage) { throw "$stage already exists; bump VERSION in main.lua or move the old build away." }
$mod = Join-Path $stage 'platform\steam\ue4ss\Mods\PBZCoop'
New-Item -ItemType Directory -Force (Join-Path $mod 'Scripts') | Out-Null

Copy-Item (Join-Path $root 'INSTALL.md') (Join-Path $stage 'Phantom Pact - INSTALL.md')
Copy-Item (Join-Path $root 'docs\LOCAL_COOP.md') (Join-Path $stage 'Phantom Pact - LOCAL CO-OP.md')
foreach ($f in 'enabled.txt', 'PhantomPact.ini') { Copy-Item (Join-Path $root "mod\PBZCoop\$f") $mod }
Copy-Item (Join-Path $root 'mod\PBZCoop\Scripts\*.lua') (Join-Path $mod 'Scripts')
# Phantom Pact's own UE4SS signatures (GNatives, GUObjectArray): UE4SS starts on the game since the 2026-11-04 update.
$sigs = Join-Path $stage 'platform\steam\ue4ss\UE4SS_Signatures'
New-Item -ItemType Directory -Force $sigs | Out-Null
Copy-Item (Join-Path $root 'mod\ue4ss\UE4SS_Signatures\*.lua') $sigs
# The PvP victory calligraphy (生还, painted in Lumina), loaded by pbz.lua at run time.
New-Item -ItemType Directory -Force (Join-Path $mod 'art') | Out-Null
Copy-Item (Join-Path $root 'mod\PBZCoop\art\*') (Join-Path $mod 'art') -Recurse

# The built-in relay. Built here so the zip can never carry an older one than the source.
& (Join-Path $PSScriptRoot 'build-native.ps1') | Out-Null
$dll = Join-Path $mod 'dlls\main.dll'
New-Item -ItemType Directory -Force (Split-Path $dll) | Out-Null
Copy-Item (Join-Path $root 'native\build\main.dll') $dll

# Players get the mod and nothing else: no Python, no test tools, no switches or addresses from a developer's PC.
$devFiles = Get-ChildItem $stage -Recurse -File | Where-Object {
    '.py', '.pyc', '.pdb', '.obj', '.exp', '.lib', '.log', '.tmp' -contains $_.Extension.ToLower() -or
    'dev.txt', 'cmd.txt', 'relay_log.txt', 'relay_error.txt', 'perf.lua', 'pair.lua' -contains $_.Name.ToLower() -or
    $_.Name -like 'net_*.txt' -or $_.Name -like 'pads*.txt' -or $_.Name -eq 'mouse.txt'
}
if ($devFiles) { throw "Not for players: $(($devFiles | ForEach-Object Name) -join ', ')" }
$ini = Get-Content (Join-Path $mod 'PhantomPact.ini') -Raw
foreach ($setting in '(?m)^Role = Off\s*$', '(?m)^HostAddress = PUT-THE-HOSTS-TAILSCALE-IP-HERE\s*$', '(?m)^Secret =[ \t]*\r?$') {
    if ($ini -notmatch $setting) { throw "PhantomPact.ini isn't the default one (expected $setting)." }
}
if ($ini -match '(?mi)^\s*ThisPcOnly') { throw "PhantomPact.ini has ThisPcOnly, which is for tests: players couldn't connect." }

$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# The checks Nexus runs on upload, done first: file types it quarantines on sight, then an antivirus scan
# (Windows Defender; Nexus also uses VirusTotal, which this can't replace). Read-only: nothing is removed.
$quarantined = '.exe', '.dll', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jar', '.msi', '.scr', '.com', '.zip', '.rar', '.7z'
$risky = Get-ChildItem $stage -Recurse -File | Where-Object { $quarantined -contains $_.Extension.ToLower() -and $_.FullName -ne $dll }
if ($risky) { throw "Nexus would quarantine this zip: $(($risky | ForEach-Object Name) -join ', ')" }
"File types OK for Nexus: $((Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.Extension.ToLower() } | Sort-Object -Unique) -join ' ')"
$defender = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
if (Test-Path $defender) {
    $scan = & $defender -Scan -ScanType 3 -File $zip -DisableRemediation 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -eq 2) { throw "Windows Defender flagged the zip:`n$scan" }
    if ($code -ne 0 -or $scan -notmatch 'found no threats') { throw "Windows Defender couldn't scan the zip (exit code $code):`n$scan" }
    "Windows Defender: no threats."
} else {
    Write-Warning "Windows Defender not found; scan the zip before uploading."
}
"SHA-256 (look it up on virustotal.com): $((Get-FileHash $zip -Algorithm SHA256).Hash)"
