# The PvP (1.7.0) bench: helpers on the two dev copies. Dot-source it. Only ever touches C:\PBZDev.
# The repo is the one this file is in (tools\netlab\bench\pvp); the Lua probes and sheet.py sit beside it.
$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$script:Bench = $PSScriptRoot
. "$script:Repo\tools\netlab\dev.ps1"
$script:Log = 'C:\PBZDev\platform\steam\ue4ss\UE4SS.log'
# The work folder: the copies' handles (pvp-host.json, pvp-guest.json), the bots' folders, trig.txt and the shots.
$script:Scratch = Join-Path $env:TEMP 'pvpbench'
New-Item -ItemType Directory -Force $script:Scratch | Out-Null
$script:Shots = Join-Path $script:Scratch 'shots'
New-Item -ItemType Directory -Force $script:Shots | Out-Null
$script:Lab = "$script:Repo\tools\netlab" -replace '\\', '/'

# The bench is ours while its note is fresh: touched at every step, or another team takes it over after 15 minutes.
function Touch-Lock { $n = 'C:\PBZDev\bench.lock\owner.txt'; if (Test-Path $n) { (Get-Item $n).LastWriteTime = Get-Date } }

function Save-Copy($g, [string]$Path) { $g | ConvertTo-Json | Set-Content $Path }
function Load-Copy([string]$Path) { Get-Content $Path -Raw | ConvertFrom-Json }

function Read-LogFrom([long]$Offset) {
    $fs = [IO.File]::Open($script:Log, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        [void]$fs.Seek([Math]::Min($Offset, $fs.Length), 'Begin')
        $text = (New-Object IO.StreamReader $fs).ReadToEnd()
        return @{ Text = $text; Offset = $fs.Length }
    } finally { $fs.Dispose() }
}
function Log-End { (Get-Item $script:Log).Length }
function Alive($g) { [bool](Get-Process -Id $g.Pid -ErrorAction SilentlyContinue) }
function Tag($g) { if ($g.Instance -eq 1) { '[PBZCoop]' } else { '[PBZCoop#2]' } }

# Lua on one copy; what it returned, or $null if nothing came back in time.
function Ask($g, [string]$Lua, [double]$Timeout = 4) {
    Touch-Lock
    $from = Log-End
    Send-Dev $g "eval $Lua"
    $deadline = (Get-Date).AddSeconds($Timeout)
    $tag = [regex]::Escape((Tag $g))
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        $r = Read-LogFrom $from
        foreach ($line in ($r.Text -split "`r?`n")) {
            if ($line -match "$tag eval ok: (.*)$") { return $Matches[1] }
            if ($line -match "$tag eval (error|compile)[^:]*: (.*)$") { return "ERROR " + $Matches[2] }
        }
    }
    return $null
}

function Lines($from, [string]$Match) {
    $r = Read-LogFrom $from
    ($r.Text -split "`r?`n") | Where-Object { $_ -match $Match } | ForEach-Object { $_ -replace '^\[\d{4}-\d\d-\d\d (\S+)\] \[Lua\] ', '$1 ' }
}

if (-not ('AggroShot.Win' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
namespace AggroShot { public static class Win {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct R { public int L, T, Rt, B; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out R r);
    public static string Save(IntPtr h, string path) {
        R r; GetClientRect(h, out r);
        if (r.Rt - r.L <= 0) return "no window";
        using (Bitmap b = new Bitmap(r.Rt - r.L, r.B - r.T)) {
            using (Graphics g = Graphics.FromImage(b)) { IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 3); g.ReleaseHdc(dc); }
            b.Save(path, ImageFormat.Png);
            return b.Width + "x" + b.Height;
        }
    }
} }
'@
}

# A picture of one copy's window, whatever is in front.
function Shot($g, [string]$Name) {
    $w = [NetLab.Win]::Unreal($g.Pid)
    if ($w -eq [IntPtr]::Zero) { return "no window yet" }
    $path = Join-Path $script:Shots "$Name.png"
    "$path " + [AggroShot.Win]::Save($w, $path)
}

# One key to one copy's own window (0x0D RETURN, 0x27 RIGHT).
function Key($g, [int]$Vk) {
    $w = [NetLab.Win]::Unreal($g.Pid)
    if ($w -ne [IntPtr]::Zero) { [NetLab.Win]::Key($w, [uint32]$Vk); "key $Vk" } else { "no window" }
}

# Whether the mod sees a player on this copy yet (skipping the shader screen's last one or two, as Wait-DevGameplay does).
function Has-Player($g) {
    Ask $g 'local g=StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary") if g:ShouldShowPSOPrecompileScreen() and g:GetPSOPrecompilesRemaining()<=2 and not g:IsPSOPrecompileComplete() then g:NotifyPSOPrecompileSkippedByPlayer() end local _,p=PBZ.getPlayer1() return "pawn="..tostring(PBZ.valid(p))' 3
}

# The game's screens up now: its activatable widgets that are on and shown (as localcoop.lua reads them).
$script:ScreensLua = 'local out = {} for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do pcall(function() if w:IsValid() and w:IsActivated() and w:IsVisible() then out[#out+1] = w:GetClass():GetFName():ToString() end end) end return #out > 0 and table.concat(out, " ") or "none"'
function Screens($g) { Ask $g $script:ScreensLua 4 }

# Into the game from the title screen, never blind: RETURN only while the title menu (WB_StartMenu_V2_C, over its video
# and the tips layer) is the one screen up, CONTINUE its first entry. Anything over it (the new game question after a
# crash, OK selected) and the shader screen are left alone: a copy stuck there is for a look. Blind keys
# (Wait-DevGameplay -AfterCrash) once went on into the game's own settings menu. $true once the mod sees a
# player; each change of screens is written out.
function Enter-Game($g, [int]$TimeoutSec = 300) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    $last = ''
    while ((Get-Date) -lt $end) {
        if (-not (Alive $g)) { Write-Host "  the copy exited"; return $false }
        if ((Has-Player $g) -eq 'pawn=true') { return $true }
        $s = Screens $g
        if ($s -and $s -ne $last) { Write-Host "  screens: $s"; $last = $s }
        $rest = @(($s -split ' ') | Where-Object { $_ -and $_ -notin 'W_StartMenu_Video_C', 'W_TIpsLayer_C' })
        if ($rest.Count -eq 1 -and $rest[0] -eq 'WB_StartMenu_V2_C') {
            Write-Host ("  " + (Key $g 0x0D) + " on the title menu")
            Start-Sleep -Seconds 10
        }
        Start-Sleep -Seconds 2
    }
    Write-Host "  not in after $TimeoutSec s (screens: $last)"
    return $false
}

function Load-Tools($g) {
    $l = $script:Lab
    Ask $g "dofile(`"$l/perf.lua`") dofile(`"$l/pair.lua`") dofile(`"$l/fights.lua`") dofile(`"$l/real.lua`") dofile(`"$l/aggro.lua`") dofile(`"$l/twitch.lua`") return 1" 10
}
