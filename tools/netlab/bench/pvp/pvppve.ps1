# PvPvE after the rename, on the two bench copies: the host opens F5 > MORE and clicks the PvPvE tile (the page's own click
# handler, by its command), both turn hostile; the guest's real blows land on the host; enemies stay in the world (nothing
# parked); a death decides it (the host's health set low, one more blow), scored on both; the tile clicked off. Test save only.
param([string]$Tag = 'pve')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$lab/fights.lua`") return 1" 8) }
$on = 'return tostring(PBZ.pvp.on) .. " net.pvp " .. tostring(PBZ.net.pvp) .. " score " .. PBZ.pvp.wins .. "-" .. PBZ.pvp.losses'
"before: host " + (Ask $h $on 4) + " | guest " + (Ask $c $on 4)
# The page and its MORE tab, as a click would: the command runs the page's own press().
Send-Dev $h 'onlinepanel toggle'; Start-Sleep -Seconds 1.5
Send-Dev $h 'onlinepanel press 695 499'; Start-Sleep -Seconds 1.5
[void](Shot $h "$Tag-1-more-host")
Send-Dev $h 'onlinepanel press 450 163'; Start-Sleep -Seconds 1.5
[void](Shot $h "$Tag-2-tile-on-host")
Send-Dev $h 'onlinepanel toggle'; Start-Sleep -Seconds 3
"tile clicked: host " + (Ask $h $on 4) + " | guest " + (Ask $c $on 4)
$hp = 'local _,p=PBZ.getPlayer1() local hp=PBZ.game.getHealth(p) return string.format("%.1f", hp)'
$place = 'local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local y=g:K2_GetActorRotation().Yaw local a=math.rad(y) p:K2_SetActorLocation({X=l.X+math.cos(a)*160,Y=l.Y+math.sin(a)*160,Z=l.Z+20},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=y+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y+180,Roll=0}) return 1'
"enemies near the host: " + (Ask $h 'local n,hid=0,0 local _,p=PBZ.getPlayer1() local m=p:K2_GetActorLocation() for _,e in ipairs(PBZ.game.listEnemies(true)) do local l=e:K2_GetActorLocation() if math.sqrt((l.X-m.X)^2+(l.Y-m.Y)^2) < 9000 then n=n+1 if e.bHidden then hid=hid+1 end end end return n.." within 90 m, hidden "..hid.." | net.arena "..tostring(PBZ.net.arena)' 6)
$blows = @()
for ($i = 0; $i -lt 2; $i++) {
    [void](Ask $c $place 5)
    Start-Sleep -Milliseconds 700
    $before = [double](Ask $h $hp 5)
    [void](Ask $c 'return FIGHT.swing()' 5)
    Start-Sleep -Seconds 2.2
    $blows += [math]::Round($before - [double](Ask $h $hp 5), 1)
}
"the guest's blows on the host: " + ($blows -join ', ')
[void](Shot $c "$Tag-3-blow-guest")
# A death decides: the host at 40 health, the game's own floor (0), one more blow.
[void](Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setMinHealth(p,0) PBZ.game.setHealth(p,40) return 1' 5)
[void](Ask $c $place 5)
Start-Sleep -Milliseconds 700
[void](Ask $c 'return FIGHT.swing()' 5)
Start-Sleep -Seconds 4
[void](Shot $h "$Tag-4-death-host"); [void](Shot $c "$Tag-4-death-guest")
"after the last blow: host " + (Ask $h ('local _,p=PBZ.getPlayer1() return "dead " .. tostring(PBZ.game.isDead(p)) .. " | " .. (function() ' + $on.Substring(7) + ' end)()') 5) + " | guest " + (Ask $c $on 4)
Start-Sleep -Seconds 12
"later: host " + (Ask $h $on 4) + " | guest " + (Ask $c $on 4)
# The tile off again.
Send-Dev $h 'onlinepanel toggle'; Start-Sleep -Seconds 1.5
Send-Dev $h 'onlinepanel press 695 499'; Start-Sleep -Seconds 1.5
Send-Dev $h 'onlinepanel press 450 163'; Start-Sleep -Seconds 1.5
Send-Dev $h 'onlinepanel toggle'; Start-Sleep -Seconds 3
"tile clicked off: host " + (Ask $h $on 4) + " | guest " + (Ask $c $on 4)
