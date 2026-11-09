# Does a blow's damage depend on the DEFENDER's own level of the attacker's weapon? PvPvE on, the guest swings at the host
# (Tang): once at the host's Tang level 1, once after the host's Tang goes to level 10. Test save only.
param([int]$Level = 10, [int]$Swings = 3)
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
$lab = $script:Lab
[void](Ask $c "dofile(`"$lab/fights.lua`") return 1" 8)
[void](Ask $h 'PBZ.pvp.set(true) return 1' 5)
[void](Ask $c 'PBZ.pvp.set(true) return 1' 5)
Start-Sleep -Seconds 2
$hp = 'local _,p=PBZ.getPlayer1() local hp=PBZ.game.getHealth(p) return string.format("%.1f", hp)'
$place = 'local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local y=g:K2_GetActorRotation().Yaw local a=math.rad(y) p:K2_SetActorLocation({X=l.X+math.cos(a)*160,Y=l.Y+math.sin(a)*160,Z=l.Z+20},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=y+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y+180,Roll=0}) return 1'
function One([string]$label) {
    $out = @()
    for ($i = 0; $i -lt $Swings; $i++) {
        [void](Ask $h 'local _,p=PBZ.getPlayer1() PBZ.game.setMinHealth(p,1) local _,m=PBZ.game.getHealth(p) PBZ.game.setHealth(p,m) return 1' 5)
        [void](Ask $c $place 5)
        Start-Sleep -Milliseconds 700
        $before = [double](Ask $h $hp 5)
        [void](Ask $c 'return FIGHT.swing()' 5)
        Start-Sleep -Seconds 2.2
        $after = [double](Ask $h $hp 5)
        $out += [math]::Round($before - $after, 1)
    }
    "$label damage: " + ($out -join ', ')
}
"host Tang level: " + (Ask $h 'local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) return tostring(bp:GetWeaponLevel(FName("Tang"),true))' 5)
"guest holds: " + (Ask $c 'local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) local o={} for _,v in ipairs(bp:GetEquipmentNormalWeapons()) do o[#o+1]=v:get():ToString() end return table.concat(o,",").." idx "..bp:GetCurrentMainWeaponIndex()' 5)
One 'host Tang L1'
"upgrade: " + (Ask $h "local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) bp:UpgradeWeapon(FName(`"Tang`"),true,$Level) return tostring(bp:GetWeaponLevel(FName(`"Tang`"),true))" 5)
Start-Sleep -Seconds 1
One "host Tang L$Level"
[void](Ask $h 'PBZ.pvp.set(false) return 1' 5)
[void](Ask $c 'PBZ.pvp.set(false) return 1' 5)
