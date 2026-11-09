# Two different loadouts, picked on each copy's F6 page (its own press handler, by command): kept in pvp_preset.txt, both
# in hand in a match "here" (each world's own body and the other's figure), every match weapon at level 30 in both worlds,
# then home: each player's own weapons back in hand, nothing lent left in the bag, the levels as before. Test save only.
param([string]$Tag = 'load')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
Touch-Lock
$state = 'local m=PBZ.arena.match return m and (m.phase.." "..tostring(m.round).." "..m.score[1].."-"..m.score[2]) or "none"'
function State($g) { $r = Ask $g $state 3; if ($r) { $r } else { 'none' } }
function Wait-State($g, [string]$Pattern, [double]$Timeout = 30) {
    $end = (Get-Date).AddSeconds($Timeout)
    do { $st = State $g; if ($st -match $Pattern) { return $st }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $end)
    return "TIMEOUT ($st)"
}
# One command at a time to a copy: the next would overwrite its cmd.txt before the mod read it.
function Cmd($g, [string]$Line) { Send-Dev $g $Line; Start-Sleep -Milliseconds 1300 }
# The page's slot cards (main1, main2, edge1, edge2) and a card on the pick page (5 a row, 164 x 60 apart from 40, 90).
$slots = @(@(488, 398), @(678, 398), @(488, 464), @(678, 464))
function Card([int]$i) { @((40 + (($i - 1) % 5) * 164 + 10), (90 + [math]::Floor(($i - 1) / 5) * 60 + 10)) }
function PickAll($g, [int[]]$Cards) {
    Cmd $g 'pvppanel toggle'
    for ($k = 0; $k -lt 4; $k++) {
        Cmd $g ("pvppanel press {0} {1}" -f $slots[$k][0], $slots[$k][1])
        $xy = Card $Cards[$k]
        Cmd $g ("pvppanel press {0} {1}" -f $xy[0], $xy[1])
    }
}
# Host: IronBlade (2), Double (8) | MoJian (edge 3), ThunderSpear (edge 4). Guest: ZhanMaBlade (15), Long (13) | BrutalAxe
# (edge 5), JinGua (edge 6). (data.weapons and data.edges in arenas.lua, in their order.)
PickAll $h @(2, 8, 3, 4)
[void](Shot $h "$Tag-0-page-host")
Cmd $h 'pvppanel toggle'
PickAll $c @(15, 13, 5, 6)
[void](Shot $c "$Tag-0-page-guest")
Cmd $c 'pvppanel toggle'
$preset = 'return table.concat(PBZ.arena.preset.main, ",") .. " | " .. table.concat(PBZ.arena.preset.edge, ",")'
"preset, host:  " + (Ask $h $preset 4)
"preset, guest: " + (Ask $c $preset 4)
$mods = 'C:\PBZDev\platform\steam\ue4ss\Mods\PBZCoop'
"file, host:  " + ((Get-Content "$mods\pvp_preset.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^;' }) -join ' ')
"file, guest: " + ((Get-Content "$mods\inst2\pvp_preset.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^;' }) -join ' ')
$held = 'local _,p=PBZ.getPlayer1() local function held(b,tag) local d={} pcall(function() b["Character Weapons Component"]:GetCurrentWeapon({TagName=FName(tag)},d,false,{}) end) local n="-" pcall(function() if d.WeaponConfig and d.WeaponConfig:IsValid() then n=d.WeaponConfig:GetFName():ToString() end end) return n end local g=PBZ.net.ghost return "own "..held(p,"Weapon.Slot.Main").." / "..held(p,"Weapon.Slot.Shachi").." | figure "..(PBZ.valid(g) and (held(g,"Weapon.Slot.Main").." / "..held(g,"Weapon.Slot.Shachi")) or "none")'
$owned = 'local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) local function names(a) local t={} for _,v in ipairs(a) do local ok,s=pcall(function() return v:get():ToString() end) t[#t+1]=ok and s or "?" end table.sort(t) return t end local m,e=names(bp:GetAllNormalWeapons()),names(bp:GetAllShaqiWeapons()) return #m.." main: "..table.concat(m,",").." | "..#e.." edge: "..table.concat(e,",")'
$levels = 'local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) local t={} for _,x in ipairs({{"IronBlade",true},{"Double",true},{"MoJian",false},{"ThunderSpear",false},{"ZhanMaBlade",true},{"Long",true},{"BrutalAxe",false},{"JinGua",false},{"Tang",true},{"PoJun",true}}) do local ok,l=pcall(function() return bp:GetWeaponLevel(FName(x[1]),x[2]) end) t[#t+1]=x[1].."="..tostring(ok and l or "?") end return table.concat(t," ")'
foreach ($g in @(@('host', $h), @('guest', $c))) {
    "before, " + $g[0] + ": " + (Ask $g[1] $held 4)
    "  owned: " + (Ask $g[1] $owned 4)
    "  levels: " + (Ask $g[1] $levels 4)
}
[void](Ask $h 'PBZ.arena.choose("mode","duel") PBZ.arena.choose("timer",0) PBZ.arena.choose("place",0) PBZ.arena.setPick(1) return 1' 5)
[void](Ask $c 'PBZ.arena.setPick(2, true) return 1' 5)
Start-Sleep -Seconds 2.5
"start: " + (Ask $h 'return tostring(PBZ.arena.start())' 5)
(Wait-State $h '^fight' 60) + " / " + (Wait-State $c '^fight' 20)
Start-Sleep -Seconds 3
foreach ($g in @(@('host', $h), @('guest', $c))) {
    "in the match, " + $g[0] + ": " + (Ask $g[1] $held 4)
    "  levels: " + (Ask $g[1] $levels 4)
}
# Weapons out on both, so each figure shows what its player holds.
foreach ($g in $h, $c) { [void](Ask $g 'local _,p=PBZ.getPlayer1() pcall(function() p["Character Weapons Component"]:SetArmed({TagName=FName("Weapon.Slot.Main")}, true) end) return 1' 4) }
Start-Sleep -Seconds 2.5
[void](Shot $h "$Tag-1-match-host"); [void](Shot $c "$Tag-1-match-guest")
"armed, host:  " + (Ask $h $held 4)
"armed, guest: " + (Ask $c $held 4)
Cmd $h 'arena leave'
"home: " + (Wait-State $h '^none' 40) + " / " + (Wait-State $c '^none' 20)
Start-Sleep -Seconds 4
foreach ($g in @(@('host', $h), @('guest', $c))) {
    "after, " + $g[0] + ": " + (Ask $g[1] $held 4)
    "  owned: " + (Ask $g[1] $owned 4)
    "  levels: " + (Ask $g[1] $levels 4)
}
[void](Shot $h "$Tag-2-home-host"); [void](Shot $c "$Tag-2-home-guest")
