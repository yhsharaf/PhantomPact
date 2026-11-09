# Talismans and the refill, on the two bench copies (saves put back after by the cycle scripts). First the host is given one
# the game's way: a talisman slot's node bought (free on the tree), AC_Deflect into the bag and worn in slot 0. Then a Duel
# "here": the talisman off for the match (and one put on in it comes off again), the guest put down by a real blow, round
# 2's refill the game's way (its own bar full, no near-death look, the route in game.refillHow, the Ultimate gauge as it
# was), then home: the talisman back in its slot, the slots as before, the health as before. Shots of each step.
param([string]$Tag = 'talref', [string]$Talisman = 'AC_Deflect', [string]$SlotNode = 'HeiShi2')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
foreach ($g in $h, $c) { [void](Ask $g "dofile(`"$lab/fights.lua`") return 1" 8) }
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
# What's worn (by slot, raw list too), the slots open, the effects on the body whose names look like a talisman's.
$worn = 'local _,p=PBZ.getPlayer1() local bp=PBZ.game.backpackOf(p) local t,r={},{} for _,w in ipairs(PBZ.arena.talismansOf(p)) do t[#t+1]=w.slot..":"..w.id end pcall(function() bp.AssemblyAccessory:ForEach(function(i,e) r[#r+1]=tostring(i).."="..e:get():ToString() end) end) local open="?" pcall(function() open=tostring(bp:GetCanAssembleAccessoryNum()) end) local fx={} pcall(function() local a=StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(p) local arr=a.ActiveGameplayEffects.GameplayEffects_Internal for i=1,#arr do local ok,n=pcall(function() return arr[i].Spec.Def:GetClass():GetFName():ToString() end) if ok and n and (n:find("Acc") or n:find("AC_") or n:find("Deflect")) then fx[#fx+1]=n end end end) return "worn="..table.concat(t,",").." raw="..table.concat(r,",").." open="..open.." effects="..table.concat(fx,",")'
$hp = 'local _,p=PBZ.getPlayer1() local hp,mx=PBZ.game.getHealth(p) local u="?" pcall(function() u=string.format("%.0f", p.AttributeSetBase.UltimateCharge.CurrentValue) end) return string.format("hp %.0f/%.0f ultimate %s refill %s", hp or -1, mx or -1, u, tostring(PBZ.game.refillHow))'
# The host's talisman, the game's way.
"give: " + (Ask $h ("local _,p=PBZ.getPlayer1() local out={} local a=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local nodes=p:GetComponentByClass(StaticFindObject('/Script/ProjectPBZ.PBZAbilityNodesComponent')) out[#out+1]='node '..tostring(pcall(function() nodes:ActivateNode(FName('$SlotNode'), a, false, true) end)) local bp=PBZ.game.backpackOf(p) out[#out+1]='bag '..tostring(pcall(function() bp:PushAccessoryToInventory(FName('$Talisman'), false) end)) return table.concat(out,' ')") 6)
Start-Sleep -Seconds 2
"wear: " + (Ask $h "local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) return tostring(pcall(function() bp:AssembleAccessory(FName('$Talisman'), 0) end))" 5)
Start-Sleep -Seconds 2
"before, host:  " + (Ask $h $worn 5)
"before, guest: " + (Ask $c $worn 5)
[void](Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 600) return 1' 4)
"before, host:  " + (Ask $h $hp 4)
"before, guest: " + (Ask $c $hp 4)
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 1.5
"in the match, host: " + (Ask $h $worn 5)
"journal: " + ((Get-Content 'C:\PBZDev\platform\steam\ue4ss\Mods\PBZCoop\pvp_restore.txt' -ErrorAction SilentlyContinue | Where-Object { $_ -match '^worn|^gourd' }) -join ' | ')
"put one on in the match: " + (Ask $h "local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) return tostring(pcall(function() bp:AssembleAccessory(FName('$Talisman'), 2) end))" 5)
Start-Sleep -Milliseconds 300
"  just after: " + (Ask $h $worn 5)
Start-Sleep -Seconds 2
"  2 s on:     " + (Ask $h $worn 5)
# The guest down by a real blow: its health low first, the host's figure-facing swing.
$place = 'local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local y=g:K2_GetActorRotation().Yaw local a=math.rad(y) p:K2_SetActorLocation({X=l.X+math.cos(a)*160,Y=l.Y+math.sin(a)*160,Z=l.Z+20},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=y+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y+180,Roll=0}) return 1'
[void](Ask $c 'local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p, 120) return 1' 4)
for ($i = 0; $i -lt 3 -and (State $h) -match '^fight'; $i++) {
    [void](Ask $h $place 5)
    Start-Sleep -Milliseconds 800
    [void](Ask $h 'return FIGHT.swing()' 5)
    Start-Sleep -Seconds 2.5
}
"after the blows: " + (State $h) + " / " + (State $c) + " | guest " + (Ask $c $hp 4)
(Wait-State $h '^count 2' 12) + " / " + (Wait-State $c '^count 2' 6)
Start-Sleep -Milliseconds 1700
[void](Shot $c "$Tag-1-count2-guest"); [void](Shot $h "$Tag-1-count2-host")
"round 2, guest: " + (Ask $c $hp 4)
"round 2, host:  " + (Ask $h $hp 4)
(Wait-State $h '^fight' 8) + " / " + (Wait-State $c '^fight' 5)
# One real blow on the refilled guest: its own bar follows the game again.
[void](Ask $h $place 5)
Start-Sleep -Milliseconds 800
[void](Ask $h 'return FIGHT.swing()' 5)
Start-Sleep -Seconds 1.2
[void](Shot $c "$Tag-2-blow-guest")
"after a blow, guest: " + (Ask $c $hp 4)
Cmd $h 'arena leave'
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 4
"after, host:  " + (Ask $h $worn 5)
"after, host:  " + (Ask $h $hp 4)
"after, guest: " + (Ask $c $hp 4)
[void](Shot $h "$Tag-3-home-host"); [void](Shot $c "$Tag-3-home-guest")
Start-Sleep -Seconds 10
"10 s on, host: " + (Ask $h $hp 4)
