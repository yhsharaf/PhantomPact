<#
.SYNOPSIS
    Online co-op test bench on one PC: runs game copies from a separate install (default C:\PBZDev, see README.md), so a
    copy of the game someone else is using on the live install is never touched. Dot-source it.

.EXAMPLE
    . .\tools\netlab\dev.ps1
    Install-DevMod
    $host_ = Start-DevGame -Role Host
    Wait-DevGameplay $host_
    Send-Dev $host_ 'netstatus'
    Stop-DevGame $host_
#>
param(
    [string]$DevRoot = 'C:\PBZDev',
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$script:DevRoot = $DevRoot
$script:RepoRoot = $RepoRoot
$script:GameDir = Join-Path $DevRoot 'platform\steam'
$script:ModDir = Join-Path $script:GameDir 'ue4ss\Mods\PBZCoop'

if (-not ('NetLab.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
namespace NetLab { public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c, uint t);
    public static IntPtr Unreal(int pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            var s = new StringBuilder(64); GetClassName(h, s, 64);
            if (p == (uint)pid && s.ToString() == "UnrealWindow") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // A key press posted straight to one window, so the copy under test never takes the focus from anything else.
    public static void Key(IntPtr h, uint vk) {
        uint scan = MapVirtualKey(vk, 0);
        PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(1 | (scan << 16)));
        System.Threading.Thread.Sleep(60);
        PostMessage(h, 0x101, (IntPtr)vk, unchecked((IntPtr)(int)(1u | (scan << 16) | (1u << 30) | (1u << 31))));
    }
} }
'@
}

function Set-IniLines([string]$Path, [hashtable]$Values) {
    $lines = if (Test-Path $Path) { @(Get-Content $Path) } else { @() }
    foreach ($key in $Values.Keys) {
        $hit = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$key\s*=") { $lines[$i] = "$key = $($Values[$key])"; $hit = $true }
        }
        if (-not $hit) { $lines += "$key = $($Values[$key])" }
    }
    Set-Content $Path $lines -Encoding ascii
}

# Copies the mod and main.dll from this repo over the dev install (running copies keep their old main.dll loaded).
function Install-DevMod {
    New-Item -ItemType Directory -Force (Join-Path $script:ModDir 'dlls') | Out-Null
    Copy-Item (Join-Path $script:RepoRoot 'mod\PBZCoop\*') $script:ModDir -Recurse -Force
    $dll = Join-Path $script:RepoRoot 'native\build\main.dll'
    if (Test-Path $dll) { Copy-Item $dll (Join-Path $script:ModDir 'dlls\main.dll') -Force }
    Set-Content (Join-Path $script:ModDir 'dev.txt') 'dev' -Encoding ascii
    (Get-FileHash (Join-Path $script:ModDir 'dlls\main.dll')).Hash.Substring(0, 12)
}

function Get-DevDir([int]$Instance) {
    if ($Instance -le 1) { return $script:ModDir }
    $dir = Join-Path $script:ModDir "inst$Instance"
    New-Item -ItemType Directory -Force $dir | Out-Null
    return $dir
}

# Starts a copy and returns @{ Pid; Dir; Instance }. -Settings: more PhantomPact.ini lines.
function Start-DevGame {
    param([ValidateSet('Host', 'Guest', 'Off')][string]$Role = 'Host', [int]$Instance = 1, [int]$Port = 47810,
          [hashtable]$Settings = @{}, [int]$Width = 960, [int]$Height = 540)
    $dir = Get-DevDir $Instance
    $ini = Join-Path $dir 'PhantomPact.ini'
    if ($Instance -gt 1) { Copy-Item (Join-Path $script:RepoRoot 'mod\PBZCoop\PhantomPact.ini') $ini -Force }
    $values = @{ Role = $Role; Port = $Port; Connect = 'Tailscale'; HostAddress = '127.0.0.1' }
    foreach ($k in $Settings.Keys) { $values[$k] = $Settings[$k] }
    Set-IniLines $ini $values
    Remove-Item (Join-Path $dir 'cmd.txt') -ErrorAction SilentlyContinue
    $exe = Join-Path $script:GameDir 'PBZ.exe'
    $base = Join-Path $script:DevRoot 'ProjectPBZ\Binaries\Win64'
    $args_ = @('ProjectPBZ', "-basedir=`"$base`"", '-pc-platform=Steam', '-allowmultipleinstances', '-windowed',
        "-ResX=$Width", "-ResY=$Height")
    $saved = $env:PBZCOOP_INSTANCE
    $env:PBZCOOP_INSTANCE = "$Instance"
    $p = Start-Process -FilePath $exe -ArgumentList $args_ -WorkingDirectory $script:GameDir -PassThru
    if ($saved) { $env:PBZCOOP_INSTANCE = $saved } else { Remove-Item Env:\PBZCOOP_INSTANCE }
    [pscustomobject]@{ Pid = $p.Id; Dir = $dir; Instance = $Instance; Started = Get-Date }
}

function Send-Dev($Game, [string[]]$Command) {
    [IO.File]::WriteAllText((Join-Path $Game.Dir 'cmd.txt'), ($Command -join "`n"))
}

function Get-DevLog($Game, [datetime]$Since = (Get-Date).AddMinutes(-2), [string]$Match = '.') {
    $path = Join-Path $script:GameDir 'ue4ss\UE4SS.log'
    if (-not (Test-Path $path)) { return }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    $text = (New-Object IO.StreamReader $fs).ReadToEnd(); $fs.Dispose()
    $text -split "`r?`n" | Where-Object { $_ -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)' -and [datetime]$matches[1] -ge $Since.AddSeconds(-1) -and $_ -match $Match }
}

# RETURN on the title screen and CONTINUE, until the mod sees a player. Never New Game: RETURN takes the first entry,
# which is CONTINUE whenever a save exists. But after a crash the game first asks whether you want a new game, OK on the
# left and Cancel on the right, and RETURN takes OK: that started a New Game on the host once. -AfterCrash goes RIGHT to
# Cancel before each RETURN, so the first one cancels and the next takes CONTINUE. (Twice, apart: the first RIGHT can be
# the key that ends the "press any key" screen, and the question only comes up after it.)
function Wait-DevGameplay($Game, [int]$TimeoutSec = 240, [switch]$AfterCrash) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $window = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $Game.Pid -ErrorAction SilentlyContinue)) { throw "Copy $($Game.Pid) exited." }
        if ($window -eq [IntPtr]::Zero) { $window = [NetLab.Win]::Unreal($Game.Pid) }
        $t = Get-Date
        # The shader screen can wait for good on its last one or two (seen after a crash): that's where the game's own skip comes in.
        Send-Dev $Game 'eval local g=StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary") if g:ShouldShowPSOPrecompileScreen() and g:GetPSOPrecompilesRemaining()<=2 and not g:IsPSOPrecompileComplete() then g:NotifyPSOPrecompileSkippedByPlayer() end local _,p=PBZ.getPlayer1() return "pawn="..tostring(p~=nil)'
        Start-Sleep -Seconds 3
        # Two copies write one log: a copy over 1 tags its lines with its number.
        $tag = if ($Game.Instance -gt 1) { "PBZCoop#$($Game.Instance)\]" } else { 'PBZCoop\]' }
        if (Get-DevLog $Game $t "$tag eval ok: pawn=true") { return $true }
        if ($window -ne [IntPtr]::Zero) {
            if ($AfterCrash) {
                [NetLab.Win]::Key($window, 0x27)
                Start-Sleep -Seconds 3
                [NetLab.Win]::Key($window, 0x27)
                Start-Sleep -Seconds 1
            }
            [NetLab.Win]::Key($window, 0x0D)
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

# A crash dump written since then: the copies running at that time may have crashed, so -AfterCrash for Wait-DevGameplay.
function Test-DevCrashed([datetime]$Since) {
    @(Get-ChildItem (Join-Path (Split-Path (Split-Path $script:ModDir)) 'crash_*.dmp') -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $Since }).Count -gt 0
}

# Only ever a copy that runs from the dev install.
function Stop-DevGame($Game) {
    $p = Get-Process -Id $Game.Pid -ErrorAction SilentlyContinue
    if ($p -and $p.Path -like "$($script:DevRoot)\*") { Stop-Process -Id $p.Id -Force -Confirm:$false }
}
