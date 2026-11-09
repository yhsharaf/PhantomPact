# A Phantom Edge used in a match, as the trace never saw: the game's own key for it (its bindings read first), pressed for real
# on the guest's window in a Duel "here", the guest in front of the host's figure. What the guest's own body plays, what the
# host's world plays on the guest's figure (its log), whether the edge's blow lands on the host, the figure's weapon, the gourd
# untouched by the round's refill. Frames of both windows through the skill. Only touches C:\PBZDev and $env:TEMP\pvpbench.
param([string]$Tag = 'edge', [int]$Vk = 0, [string]$Action = 'Shachi')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$bench = $script:Bench -replace '\\', '/'
[void](Ask $c "dofile(`"$bench/keymap.lua`") return 1" 8)
"bindings (${Action}): " + (Ask $c "return KEYMAP.list('$Action')" 8)
if (-not $Vk) { 'no key given (-Vk): read the bindings above and run again'; return }
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
$held = 'local _,p=PBZ.getPlayer1() local function held(b,tag) local d={} pcall(function() b["Character Weapons Component"]:GetCurrentWeapon({TagName=FName(tag)},d,false,{}) end) local n="-" pcall(function() if d.WeaponConfig and d.WeaponConfig:IsValid() then n=d.WeaponConfig:GetFName():ToString() end end) return n end local g=PBZ.net.ghost local hp=PBZ.game.getHealth(p) local gd=PBZ.arena.gourdOf(p) return string.format("hp %.0f, gourd %s, own %s / %s | figure %s / %s", hp or -1, tostring(gd and gd.CurrentTime), held(p,"Weapon.Slot.Main"), held(p,"Weapon.Slot.Shachi"), PBZ.valid(g) and held(g,"Weapon.Slot.Main") or "-", PBZ.valid(g) and held(g,"Weapon.Slot.Shachi") or "-")'
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 3
"host:  " + (Ask $h $held 4)
"guest: " + (Ask $c $held 4)
# The guest 3 m in front of the host's figure, facing it.
$place = 'local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local y=g:K2_GetActorRotation().Yaw local a=math.rad(y) p:K2_SetActorLocation({X=l.X+math.cos(a)*300,Y=l.Y+math.sin(a)*300,Z=l.Z+20},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=y+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y+180,Roll=0}) return 1'
[void](Ask $c $place 5)
Start-Sleep -Seconds 1
$from = Log-End
$before = Ask $h 'local _,p=PBZ.getPlayer1() return string.format("%.0f", (PBZ.game.getHealth(p)))' 4
"the edge's key on the guest: " + (Key $c $Vk)
$t0 = Get-Date
for ($i = 0; $i -lt 10; $i++) {
    $t = ((Get-Date) - $t0).TotalSeconds
    [void](Shot $c ("$Tag-g-{0:d2}-{1:0.0}" -f $i, $t)); [void](Shot $h ("$Tag-h-{0:d2}-{1:0.0}" -f $i, $t))
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 1
"host health: $before -> " + (Ask $h 'local _,p=PBZ.getPlayer1() return string.format("%.0f", (PBZ.game.getHealth(p)))' 4)
"after, host:  " + (Ask $h $held 4)
"after, guest: " + (Ask $c $held 4)
"== the logs during the skill"
Lines $from "Ghost couldn't|played|PvP:|Phantom Edge|moves \(|GA_Hun|error" | Where-Object { $_ -notmatch '\] > |eval ok' } | Select-Object -First 20
python "$script:Bench\sheet.py" $script:Shots "$Tag-g" "$script:Shots\sheet-$Tag-guest.jpg" 5 384 | Out-Null
python "$script:Bench\sheet.py" $script:Shots "$Tag-h" "$script:Shots\sheet-$Tag-host.jpg" 5 384 | Out-Null
Cmd $h 'arena leave'
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
