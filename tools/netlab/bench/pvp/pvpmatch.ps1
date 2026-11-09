# A PvP match on the two bench copies (host = copy 1, guest = copy 2), "here", driven through cmd.txt. Shots at each step.
# -Step lobby|start|fight|down|end|all. Dot-sources pvplib.ps1.
param([string]$Step = 'all', [string]$Label = 'm1')
. (Join-Path $PSScriptRoot 'pvplib.ps1')
$h = Load-Copy "$script:Scratch\pvp-host.json"
$c = Load-Copy "$script:Scratch\pvp-guest.json"
function Both([string]$Lua, [double]$T = 6) { "  host: " + (Ask $h $Lua $T); "  guest: " + (Ask $c $Lua $T) }
function Snap([string]$Name) { [void](Shot $h "$Label-$Name-host"); [void](Shot $c "$Label-$Name-guest"); "  shots $Label-$Name" }
$state = 'local a=PBZ.arena local m=a.match local n=PBZ.net local _,p=PBZ.getPlayer1() local hp,mx=PBZ.game.getHealth(p) return string.format("match=%s phase=%s round=%s score=%s arena=%s pvp=%s hp=%.0f/%.0f veto=%s held=%s", tostring(m and m.id), tostring(m and m.phase), tostring(m and m.round), m and (m.score[1].."-"..m.score[2]) or "-", tostring(n.arena), tostring(n.pvp), hp or -1, mx or -1, tostring(a.vetoed), tostring(a.held))'
$gear = 'local bp=PBZ.game.backpackOf(select(2,PBZ.getPlayer1())) local function L(x) local o={} for _,v in ipairs(x) do local g=v:get() o[#o+1]=type(g)=="string" and g or g:ToString() end return table.concat(o,",") end return "equipped["..L(bp:GetEquipmentNormalWeapons()).."] edge["..L(bp:GetShaqiWeapons()).."] owned["..L(bp:GetAllNormalWeapons()).."] edges["..L(bp:GetAllShaqiWeapons()).."]"'

if ($Step -in 'lobby', 'all') {
    "== lobby"
    Both 'return tostring(PBZ.net.enabled).." role "..tostring(PBZ.net.role).." partner "..tostring(PBZ.net.target ~= nil)'
    [void](Ask $h 'PBZ.arena.choose("place", 0) return 1')
    [void](Ask $c 'PBZ.arena.setPick(nil, true) return 1')
    Start-Sleep -Seconds 2
    "  blocker: " + (Ask $h 'return tostring(PBZ.arena.blocker())')
    Both $gear
}
if ($Step -in 'start', 'all') {
    "== start"
    "  start: " + (Ask $h 'return tostring(PBZ.arena.start())')
    Start-Sleep -Seconds 2.5
    Both $state
    Snap 'count'
    Start-Sleep -Seconds 4
    Both $state
    Both $gear
    Snap 'fight'
}
if ($Step -in 'down', 'all') {
    "== the guest goes down"
    [void](Ask $c 'PBZ.arena.command("down") return 1')
    Start-Sleep -Seconds 1.2
    Both $state
    Snap 'down'
    Start-Sleep -Seconds 5.5
    Both $state
    Snap 'round2'
}
if ($Step -in 'end', 'all') {
    "== to the end"
    Start-Sleep -Seconds 1
    [void](Ask $c 'PBZ.arena.command("down") return 1')
    Start-Sleep -Seconds 4.5
    Both $state
    Snap 'finish'
    "  finish: " + (Ask $h 'return tostring(PBZ.arena.finish(2))')
    Start-Sleep -Seconds 6.5
    Both $state
    Snap 'result'
    Start-Sleep -Seconds 9
    Both $state
    Both $gear
    Snap 'home'
}
