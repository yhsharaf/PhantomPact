# The black wall for real: the host in a boss fight inside, the guest outside its wall on the guest's own PC, then the
# guest's "press" (coop.pressWall, as E) and where the guest goes, a sample every 0.1 s: the walk up, the crossing, the
# floor. -Boss is the host's boss (brought back on the host if beaten), -Wall the tail of a wall of its arena.
param([string]$Boss = 'sp:XIGU_1_4_A_EliteSword', [string]$Wall = '2_1900432489', [int]$Side = 0, [string]$Bell = 'NLES_002', [string]$GuestAt = '-25600,291400')
. (Join-Path $PSScriptRoot 'tourlib.ps1')
$H = $script:H; $C = $script:C
$load = 'for _,f in ipairs({"real","fights","story","walls"}) do dofile("C:/PBZDev/netlab/"..f..".lua") end return 1'
[void](Ask $H $load 8); [void](Ask $C $load 8)
if ($Bell) {
    [void](Ask $H "return STORY.go(`"$Bell`")" 8); [void](Ask $C "return STORY.go(`"$Bell`")" 8)
    Start-Sleep -Seconds 6
    "travel: host " + (Wait-Player $H 150) + ", guest " + (Wait-Player $C 150)
    Start-Sleep -Seconds 4
    [void](Ask $H $load 8); [void](Ask $C $load 8)
}
"host spawn: " + (Ask $H "local at = PBZ.game.spawnBoss(`"$Boss`") return at and string.format('%.0f %.0f %.0f', at.X, at.Y, at.Z) or 'no spawner'" 8)
Start-Sleep -Seconds 3
$b = Ask $H "local e = FIGHT.boss(`"$Boss`") if not e then return 'none' end local l = e:K2_GetActorLocation() return string.format('%.0f %.0f %.0f', l.X, l.Y, l.Z)" 6
"boss at $b"
if ($b -eq 'none') { return }
$bx, $by, $bz = $b -split ' '
[void](Ask $H "return REAL.flyTo($([int]$bx + 400), $by, $([int]$bz + 150))" 6)
# (The guest goes straight to the wall: beside the boss, the guest's own game starts a fight of its own with its copy.)
$gx, $gy = $GuestAt -split ','
[void](Ask $C "return REAL.flyTo($gx, $gy, $([int]$bz + 300))" 6)
foreach ($g in $H, $C) { [void](Ask $g 'PBZ.game.resetBosses() return 1' 4) }
Start-Sleep -Seconds 8
"before: host partnerBosses " + (Ask $H 'local n = 0 for _ in pairs(PBZ.net.partnerBosses) do n = n + 1 end return n' 4) + ", guest " + (Ask $C 'local n = 0 for _ in pairs(PBZ.net.partnerBosses) do n = n + 1 end return n' 4)
$i = Ask $C "return WALLS.find(`"$Wall`")" 6
if ($Side -eq 0) { $Side = -[int](Ask $C "return WALLS.sideOf($i, $bx, $by)" 4) }     # (outside: away from the boss)
"guest's wall $i, side $Side"
[void](Ask $C "return WALLS.stand($i, $Side)" 6)
Start-Sleep -Seconds 3
[void](Ask $H 'return REAL.land(1)' 4); [void](Ask $C 'return REAL.land(1)' 4)
Start-Sleep -Seconds 2
"guest before: " + (Ask $C "return WALLS.where($i)" 4)
"host starts the fight: " + (Ask $H "local e = FIGHT.boss(`"$Boss`") FindFirstOf('PBZHUDLayout'):RegisterBossHPBar(e) return 'bar'" 6)
Start-Sleep -Seconds 4
"guest fight state: " + (Ask $C "local n = 0 for _ in pairs(PBZ.net.partnerBosses) do n = n + 1 end local f = 0 for _ in pairs(PBZ.net.foggedBosses) do f = f + 1 end return 'partnerBosses ' .. n .. ' fogged ' .. f .. ' partnerFighting ' .. tostring(PBZ.net.partnerFighting)" 6)
"closed wall near the guest: " + (Ask $C 'local _, p = PBZ.getPlayer1() return tostring(PBZ.game.closedFogNear(p:K2_GetActorLocation(), 1000) ~= nil)' 6)
"press: " + (Ask $C 'TRK = {} local _, p = PBZ.getPlayer1() local t0 = os.clock() local function rec() if not PBZ.valid(p) then return end local l = p:K2_GetActorLocation() TRK[#TRK+1] = string.format("%.1f:%.0f,%.0f,%.0f m%d", os.clock() - t0, l.X, l.Y, l.Z, p.CharacterMovement.MovementMode) if os.clock() - t0 < 2.5 then PBZ.game.after(0.1, rec) end end rec() PBZ.coop.pressWall() return "pressed"' 6)
Start-Sleep -Seconds 4
"track: " + (Ask $C 'return table.concat(TRK, " | ")' 6)
"guest after: " + (Ask $C "return WALLS.where($i)" 4) + "   joined: " + (Ask $C 'return tostring(PBZ.net.joinedBoss)' 4)
"press again (must stay inside): " + (Ask $C 'PBZ.coop.pressWall() return 1' 4)
Start-Sleep -Seconds 2
"guest after 2nd: " + (Ask $C "return WALLS.where($i)" 4)
"host ends the fight: " + (Ask $H "local e = FIGHT.boss(`"$Boss`") FindFirstOf('PBZHUDLayout'):UnRegisterBossHPBar(e) return 'down'" 6)
Start-Sleep -Seconds 9
"guest after the host's bar went: " + (Ask $C "local n = 0 for _ in pairs(PBZ.net.partnerBosses) do n = n + 1 end return 'partnerBosses ' .. n .. ' wall closed ' .. tostring(PBZ.game.closedFogNear(select(2, PBZ.getPlayer1()):K2_GetActorLocation(), 1000) ~= nil)" 6)
