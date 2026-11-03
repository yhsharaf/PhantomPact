-- The rules with four players, on the mod's real scripts: one host, three guests, each in a world of its own.

local Session = dofile(SIM_DIR .. "/session.lua")
local Fake = Session.Fake

local THUG = "BP_Monster_MaleThug_C"
local ENEMIES = {
    { "thug1", THUG, 1500.0, 300.0, 100.0, 600, 100 },
    { "thug2", THUG, -1800.0, 200.0, 100.0, 600, 100 },
    { "near", THUG, 300.0, 300.0, 100.0, 600, 100 },
    { "guestside", THUG, 15000.0, 0.0, 100.0, 600, 100 },
    { "toofar", THUG, 40000.0, 0.0, 100.0, 600, 100 },
    { "toofar2", THUG, 41000.0, 500.0, 100.0, 600, 100 },
    { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
}

local failed = 0
local out

local function check(ok, what)
    out("  " .. (ok and "ok   " or "FAIL ") .. what)
    if not ok then
        failed = failed + 1
    end
end

local function part(title)
    out(title .. ":")
end

local function net(pc)
    return pc.env.PBZ.net
end

-- What this PC knows of the player in that slot.
local function peer(pc, slot)
    local n = net(pc)
    if slot == 1 and n.slot ~= 1 then
        return n
    end
    return n.peers[slot]
end

local function ghostOf(pc, slot)
    local p = peer(pc, slot)
    return p and p.ghost
end

-- This player's own hit: a move of theirs, then their copy loses health. A copy that loses health with no move isn't their hit.
local function swing(pc, e, health)
    pc.env.PBZ.game.noteLocalMove()
    Fake.setHealth(e, health)
end

local function field(o, name)
    return rawget(o, "__fields")[name]
end

local function at(a)
    return field(a, "loc")
end

local function gap(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
end

local function count(list, pattern)
    local n = 0
    for _, line in ipairs(list) do
        if line:find(pattern) then
            n = n + 1
        end
    end
    return n
end

local function everyone(s, fn, from)
    local all = true
    for i = from or 1, #s.pcs do
        all = all and fn(s.pcs[i], i)
    end
    return all
end

local function allErrors(s, what)
    local n = 0
    for _, pc in ipairs(s.pcs) do
        if #pc.errors > 0 then
            n = n + 1
            out("    " .. pc.id .. ": " .. pc.errors[1])
        end
    end
    check(n == 0, what or "and no script error anywhere")
end

local function party(enemies, extraIni, roles)
    local s = Session.new(SIM_SCRIPTS, roles or { "Host", "Guest", "Guest", "Guest" }, true, enemies or ENEMIES, extraIni)
    s:run(4)            -- (a joining guest gives a fight a moment to be heard of, then goes to the host)
    return s
end

local function spread(s)
    Session.moveTo(s.pcs[1], 0, 0)
    Session.moveTo(s.pcs[2], 500, 0)
    Session.moveTo(s.pcs[3], 0, 500)
    Session.moveTo(s.pcs[4], -500, 0)
end

local function joining()
    part("joining")
    local s = party()
    spread(s)
    s:run(3)
    check(net(s.pcs[1]).party == 4 and net(s.pcs[1]).slot == 1, "the host knows it's a party")
    check(net(s.pcs[2]).slot == 2 and net(s.pcs[3]).slot == 3 and net(s.pcs[4]).slot == 4, "each guest knows its number, from the host's hello")
    check(everyone(s, function(pc) return #pc.spawned == 3 end), "everyone has three ghosts, no more")
    check(everyone(s, function(pc, i)
        for slot = 1, 4 do
            if slot ~= i and not pc.env.PBZ.valid(ghostOf(pc, slot)) then
                return false
            end
        end
        return true
    end), "and each is a particular player's")
    local t = 0
    local function walk()
        t = t + 1 / 60
        Session.moveTo(s.pcs[1], math.cos(t) * 800, math.sin(t) * 800)
        Session.moveTo(s.pcs[2], 600 + math.cos(t) * 700, math.sin(t) * 700)
        Session.moveTo(s.pcs[3], -600 + math.cos(t) * 500, math.sin(t) * 500)
        Session.moveTo(s.pcs[4], math.cos(t) * 300, 900 + math.sin(t) * 300)
    end
    s:run(6, walk)
    local worst = 0
    for i, pc in ipairs(s.pcs) do
        for slot = 1, 4 do
            if slot ~= i then
                worst = math.max(worst, gap(at(ghostOf(pc, slot)), at(s.pcs[slot].pawn)))
            end
        end
    end
    check(worst < 300, string.format("every ghost on every PC follows its own player (worst %.0f cm: nothing here says how fast they go)", worst))
    allErrors(s)
end

local function movesAndGear()
    part("moves, gear, reactions")
    local s = party()
    spread(s)
    s:run(2)
    Session.startMove(s.pcs[3], "/Game/Move/A1.A1")
    s:run(0.5)
    local function played(pc, slot)
        return field(field(ghostOf(pc, slot), "anim"), "played") or 0
    end
    check(played(s.pcs[1], 3) == 1 and played(s.pcs[2], 3) == 1 and played(s.pcs[4], 3) == 1, "a guest's move plays on that guest's ghost, on all three other PCs")
    check(played(s.pcs[1], 2) == 0 and played(s.pcs[1], 4) == 0 and played(s.pcs[2], 1) == 0 and played(s.pcs[2], 4) == 0, "and on nobody else's")
    Session.endMove(s.pcs[3])
    s:run(0.3)
    check(field(field(ghostOf(s.pcs[1], 3), "anim"), "montage") == nil, "and stops when they stop")
    local g = s.pcs[1].env.PBZ.game
    Session.startMove(s.pcs[2], "/Game/Move/A2.A2")
    s:run(0.1)
    check(g.ghostBusy(ghostOf(s.pcs[1], 2)) and not g.ghostBusy(ghostOf(s.pcs[1], 3)), "one ghost's move doesn't stop the others being steered")
    Session.endMove(s.pcs[2])
    Session.hold(s.pcs[2], "/Game/Weapon/Spear.Spear", true)
    Session.hold(s.pcs[3], "/Game/Weapon/Sword.Sword", true)
    s:run(1.5)
    local function holds(pc, slot)
        local c = field(field(ghostOf(pc, slot), "Character Weapons Component"), "config")
        return c and rawget(c, "__path")
    end
    check(holds(s.pcs[1], 2) == "/Game/Weapon/Spear.Spear" and holds(s.pcs[1], 3) == "/Game/Weapon/Sword.Sword", "each ghost holds its own player's weapon")
    check(holds(s.pcs[4], 2) == "/Game/Weapon/Spear.Spear" and holds(s.pcs[4], 3) == "/Game/Weapon/Sword.Sword", "on a guest's PC too")
    check(holds(s.pcs[1], 4) == nil, "and the one who changed nothing keeps theirs")
    Session.stagger(s.pcs[4], "CharacterState.Hitreact.State.Normal.Heavy")
    s:run(0.5)
    check(field(field(ghostOf(s.pcs[2], 4), "hit"), "state") == "CharacterState.Hitreact.State.Normal.Heavy", "a stagger shows on the right ghost")
    check(field(field(ghostOf(s.pcs[2], 3), "hit"), "state") == "None", "and no other")
    allErrors(s)
end

local function sharing()
    part("everything anyone gets")
    local s = party()
    spread(s)
    s:run(2)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    Session.gainItem(h, "R_1", 1)
    s:run(1)
    check(Session.items(a, "R_1") == 1 and Session.items(b, "R_1") == 1 and Session.items(c, "R_1") == 1 and Session.items(h, "R_1") == 1, "what the host gets, every guest gets, once")
    Session.gainItem(b, "R_2", 2)
    s:run(1)
    check(Session.items(h, "R_2") == 2 and Session.items(a, "R_2") == 2 and Session.items(c, "R_2") == 2 and Session.items(b, "R_2") == 2, "what a guest gets, the host and the others get, once")
    Session.gainItem(a, "R_3", 1)
    Session.gainItem(b, "R_3", 1)
    s:run(1)
    check(Session.items(a, "R_3") == 1 and Session.items(b, "R_3") == 1, "the same thing given to two players in a moment stays one each")
    check(Session.items(h, "R_3") == 1 and Session.items(c, "R_3") == 1, "and it's one for those who weren't there, not two")
    Session.gainItem(a, "R_5", 1)
    Session.gainItem(b, "R_5", 1)
    Session.gainItem(c, "R_5", 1)
    s:run(1)
    check(Session.items(h, "R_5") == 1 and Session.items(a, "R_5") == 1 and Session.items(b, "R_5") == 1 and Session.items(c, "R_5") == 1, "from three senders at once, one each too")
    s:run(16)
    Session.gainItem(a, "R_5", 1)
    s:run(1)
    check(Session.items(h, "R_5") == 2 and Session.items(b, "R_5") == 2, "and after the 15 s the same thing counts again")
    Session.gainItem(a, "R_4", 1)
    s:run(0.5)
    Session.gainItem(a, "R_4", 1)
    s:run(1)
    check(Session.items(h, "R_4") == 2 and Session.items(c, "R_4") == 2, "two of a thing from one player are two")
    Session.gainDust(b, 50)
    s:run(1)
    check(Session.dust(h) == 50 and Session.dust(a) == 50 and Session.dust(c) == 50 and Session.dust(b) == 50, "a guest's dust reaches everyone, once")
    Session.gainDust(h, 70)
    s:run(1)
    check(Session.dust(a) == 120 and Session.dust(b) == 120 and Session.dust(c) == 120, "and the host's")
    s:run(2)
    check(Session.dust(h) == 120, "and nobody sends it back round")
    Session.moveTo(a, 400, 400)
    s:run(1.5)
    Fake.put(a.chests[1], "CurSwitchState", true)
    s:run(1.5)
    check(field(h.chests[1], "CurSwitchState") == true and field(b.chests[1], "CurSwitchState") == true and field(c.chests[1], "CurSwitchState") == true, "a chest one guest opens stops paying everywhere")
    Session.moveTo(b, 300, 0)
    s:run(1.5)
    b.pickups[1]:K2_DestroyActor()
    s:run(1.5)
    local gone = true
    for _, pc in ipairs({ h, a, c }) do
        gone = gone and not rawget(pc.pickups[1], "__alive")
    end
    check(gone, "a pickup one guest takes goes from every world")
    allErrors(s)
end

local function enemiesAndHits()
    part("who runs the enemies")
    local s = party()
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    spread(s)
    Session.moveTo(a, 11000, 0)
    Session.moveTo(b, 500, 500)
    Session.moveTo(c, -500, -500)
    s:run(3)
    local copies = net(b).remoteEnemies
    check(copies["sp:thug1"] ~= nil and copies["sp:near"] ~= nil, "the host shares what's near it, with every guest")
    check(copies["sp:guestside"] ~= nil, "and what's near a guest up to 120 m off, though it's 150 m from the host")
    check(copies["sp:toofar"] == nil, "but not what's near nobody")
    Session.moveTo(a, 500, 0)
    s:run(1)
    local onA = Session.enemyOn(a, "near")
    local full = select(1, Fake.health(Session.enemyOn(h, "near")))
    check(full == 1500, "enemies are at the health of four")
    swing(a, onA, select(1, Fake.health(onA)) - 50)
    s:run(1)
    check(select(1, Fake.health(Session.enemyOn(h, "near"))) == full - 50, "a guest's hit lands on the host's enemy")
    check(select(1, Fake.health(Session.enemyOn(b, "near"))) == full - 50 and select(1, Fake.health(Session.enemyOn(c, "near"))) == full - 50, "and the other guests' copies follow")
    check(count(a.sent, "^E D ") == 1 and count(b.sent, "^E D ") == 0 and count(c.sent, "^E D ") == 0, "reported once, by the one who hit")
    local brain = field(field(Session.enemyOn(b, "near"), "Controller"), "BrainComponent")
    check(field(brain, "running") == false, "a copy the host lists has its AI stopped")
    swing(b, Session.enemyOn(b, "near"), 1)
    s:run(1)
    check(field(Session.enemyOn(h, "near"), "dead") == true, "a guest's killing blow kills it on the host")
    check(field(Session.enemyOn(a, "near"), "dead") == true and field(Session.enemyOn(c, "near"), "dead") == true, "and on every guest's copy")
    check(count(h.sent, "^E K sp:near$") == 1, "once")
    Fake.put(Session.enemyOn(h, "thug1"), "dustLoot", 300)
    swing(c, Session.enemyOn(c, "thug1"), 1)
    s:run(2.5)
    check(Session.dust(h) == 300 and Session.dust(a) == 300 and Session.dust(b) == 300 and Session.dust(c) == 300, "a guest's kill pays everyone the same, once")
    -- The host weighs a hit by where the one who sent it stands, and here the first guest is far from it.
    Session.moveTo(a, 11000, 0)
    s:run(1)
    local onB = Session.enemyOn(b, "thug2")
    local left = select(1, Fake.health(Session.enemyOn(h, "thug2")))
    swing(b, onB, select(1, Fake.health(onB)) - 50)
    s:run(1)
    check(select(1, Fake.health(Session.enemyOn(h, "thug2"))) == left - 50, "a hit counts from where its sender stands, however far off the first guest is")
    Session.moveTo(a, 500, 0)
    s:run(1)
    -- A guest restarts its sync: it's told of the deaths alone.
    local before = count(a.logs, "died; killed it here")
    Session.command(b, "netoff")
    s:run(1)
    Session.command(b, "neton client")
    s:run(2)
    check(count(h.sent, "^T3 K sp:near$") == 1, "a guest who restarts hears what's dead, by itself")
    check(count(a.logs, "died; killed it here") == before, "and the others aren't told again")
    check(field(Session.enemyOn(b, "near"), "dead") == true, "and its copy stays dead")
    Session.command(h, "netoff")
    s:run(1)
    Session.command(h, "neton host")
    s:run(2)
    check(count(a.sent, "^E GK ") == 0 and count(b.sent, "^E GK ") == 0 and count(c.sent, "^E GK ") == 0, "the host restarts: what they'd hit and seen die isn't news")
    allErrors(s)
end

local function farEnemy()
    part("an enemy too far from the host")
    local s = party()
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    spread(s)
    Session.moveTo(a, 39500, 0)
    Session.moveTo(b, 40500, 0)
    s:run(3)
    check(net(a).remoteEnemies["sp:toofar"] == nil, "two guests past the host's reach: it isn't the host's")
    local onA, onB = Session.enemyOn(a, "toofar"), Session.enemyOn(b, "toofar")
    check(field(field(field(onA, "Controller"), "BrainComponent"), "running") == true and field(field(field(onB, "Controller"), "BrainComponent"), "running") == true, "each guest has a copy of its own, awake")
    local left = select(1, Fake.health(onB))
    swing(a, onA, select(1, Fake.health(onA)) - 20)
    s:run(1)
    check(select(1, Fake.health(onB)) == left, "a hit stays on the copy it landed on")
    swing(a, onA, 0)
    Fake.put(onA, "dead", true)
    s:run(1)
    check(count(a.sent, "^E GK sp:toofar$") == 1, "the first kill is told once")
    check(field(onB, "dead") == true, "and kills the other guest's copy")
    check(count(b.sent, "^E GK sp:toofar$") == 0, "which doesn't tell it again")
    check(net(c).pendingDeaths["sp:toofar"] == true, "a guest elsewhere's copy goes as it loads")
    check(field(Session.enemyOn(h, "toofar"), "dead") == false, "on the host it sleeps till someone's near")
    Session.moveTo(h, 39000, 300)
    Session.moveTo(a, 39500, 0)
    s:run(2)
    check(field(Session.enemyOn(h, "toofar"), "dead") == true, "then it's dead there too")
    -- A copy that merely reads as dead, which this player never hit, says nothing: it'd kill the enemy everywhere.
    Session.moveTo(h, 0, 0)
    s:run(2)
    local second = Session.enemyOn(b, "toofar2")
    Fake.setHealth(second, 0)
    Fake.put(second, "dead", true)
    s:run(2)
    check(count(b.sent, "^E GK sp:toofar2$") == 0, "a copy that reads as dead with no hit from this player says nothing")
    check(field(Session.enemyOn(a, "toofar2"), "dead") == false, "and stays alive for the others")
    allErrors(s)
end

local function rests()
    part("bells and deaths")
    local s = party()
    spread(s)
    s:run(2)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    local function refreshes(pc)
        return count(pc.trace, "GameMode Refresh Monster")
    end
    Session.bell(b)
    s:run(2)
    check(count(b.sent, "^E R bell$") == 1, "a guest rests at a bell, and says so once")
    check(refreshes(h) == 1 and refreshes(a) == 1 and refreshes(c) == 1, "enemies come back once on every other PC")
    check(count(h.sent, "^E R ") == 0 and count(a.sent, "^E R ") == 0 and count(c.sent, "^E R ") == 0, "and nobody says it again")
    check(refreshes(b) == 0, "nor does it come back to the one who rested")
    Session.respawned(c)
    s:run(2)
    check(count(c.sent, "^E R ") == 0, "a guest's death refreshes its own world and says nothing")
    check(refreshes(h) == 1 and refreshes(a) == 1, "and nobody else's")
    Session.respawned(h)
    s:run(2)
    check(count(h.sent, "^E R death$") == 1, "the host's death does say")
    check(refreshes(a) == 2 and refreshes(b) == 1 and refreshes(c) == 2, "and every world refreshes")
    allErrors(s)

    local t = party()
    spread(t)
    t:run(2)
    local th, ta = t.pcs[1], t.pcs[2]
    Session.moveTo(th, 39800, 300)
    t:run(3)
    local copy = Session.enemyOn(th, "toofar")
    Fake.setHealth(copy, 0)
    Fake.put(copy, "dead", true)
    t:run(2)
    check(net(ta).pendingDeaths["sp:toofar"] == true, "a guest far away hears of a kill, and waits to load that enemy")
    Session.respawned(th)
    t:run(2)
    check(net(ta).pendingDeaths["sp:toofar"] == true, "the host's death doesn't undo it: the dead stay dead")
    Session.moveTo(ta, 39800, 500)
    t:run(3)
    check(field(Session.enemyOn(ta, "toofar"), "dead") == true, "they get there, and it's dead for them too")
    Session.moveTo(ta, 500, 0)
    t:run(2)
    net(ta).hostWorld = 1
    ta.env.PBZ.coop.handlers.Y(2)
    t:run(1)
    check(net(ta).pendingDeaths["sp:toofar"] == nil and next(net(ta).hostKilled) == nil, "a new host world starts from nothing")
    allErrors(t)
end

local function travel()
    part("F3")
    local s = party()
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 20000, 0)
    Session.moveTo(b, 3000, 0)
    Session.moveTo(c, 50000, 0)
    s:run(5)
    local coop = c.env.PBZ.coop
    check(coop.nearestPartner() == net(c).peers[2], "the nearest partner is who F3 goes to")
    Session.die(a)
    s:run(2)
    check(coop.nearestPartner() == net(c).peers[3], "if they're down, the next nearest who's up")
    check(coop.joinPartner(coop.nearestPartner()) == nil, "and off they go")
    s:run(0.2)
    check(gap(at(c.pawn), at(b.pawn)) < 500, "to that partner, not to the host")
    Session.revive(a)
    s:run(5)
    check(h.env.PBZ.coop.nearestPartner() == net(h).peers[3], "the host goes to its nearest guest too")
    -- Nobody on this map: a guest goes to the host, a host to a guest it can name the map of.
    a.map, b.map, c.map = "Map_Other", "Map_Other", "Map_Other"
    s:run(6)
    check(h.env.PBZ.coop.nearestPartner() == net(h).peers[2], "with nobody on the map, the host's first guest who's up")
    check(a.env.PBZ.coop.nearestPartner() == net(a).peers[3], "a guest on a map with another guest goes to them")
    b.map = "Map_Third"
    c.map = "Map_Fourth"
    a.map = "Map_Fifth"
    s:run(6)
    check(c.env.PBZ.coop.nearestPartner() == net(c), "alone on a map, a guest goes to the host")
    allErrors(s)
end

-- A guest's fight, on a boss the host hasn't got: only that guest can say it's on, and it mustn't take five seconds to say.
local function lateJoinerGuestFight()
    part("joining a fight the host isn't in")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local h, a, late = s.pcs[1], s.pcs[2], s.pcs[4]
    late.joinAt = h.now + 7.5
    local i = Session.indexOf(h, "boss")
    table.remove(h.enemies, i)
    table.remove(h.spawners, i)
    s:run(3)
    spread(s)
    s:run(2)
    a.hudLayout:RegisterBossHPBar(Session.enemyOn(a, "boss"))
    s:run(3.6)
    check(net(late).party == 4, "they've just joined")
    check(not h.env.PBZ.game.bossFightActive() and a.env.PBZ.game.bossFightActive(), "the fight is on a guest's PC, not the host's")
    s:run(2.2)
    check(net(late).watchingFight == true, "they hear of it from that guest in time, and watch")
    allErrors(s)
end

local function hatred()
    part("hatred, and who's hidden")
    local s = party({ { "ring", THUG, 0.0, 0.0, 100.0, 6000, 100 } })
    spread(s)
    s:run(3)
    local h = s.pcs[1]
    local e = Session.enemyOn(h, "ring")
    local list = rawget(field(e, "BP_PBZHatredManagerComponent"), "__fields").HatredList.items
    local function hates(slot)
        for _, a in ipairs(list) do
            if a == ghostOf(h, slot) then
                return true
            end
        end
        return false
    end
    s:run(7)
    check(hates(2) and hates(3) and hates(4), "every ghost nearby is on an enemy's hatred list")
    Session.die(s.pcs[3])
    s:run(2.5)
    check(not hates(3) and hates(2) and hates(4), "a partner who's down comes off it, and only they do")
    check(field(field(ghostOf(h, 3), "BP_PBZHatredManagerComponent"), "CanBeHatredNow") == false, "and can't be put back")
    s:run(6)
    check(not hates(3), "not even by the next look")
    Session.revive(s.pcs[3])
    s:run(7)
    check(hates(3), "back on their feet, they're hated again")

    -- A boss was after a guest alone, with nobody else on its list, when the guest dropped: it swung at the empty spot for good.
    local gone = ghostOf(h, 3)
    Session.moveTo(s.pcs[2], 90000, 0)
    Session.moveTo(s.pcs[4], -90000, 0)
    s:run(1)
    for i = #list, 1, -1 do
        list[i] = nil
    end
    list[1] = gone
    Fake.put(e, "target", gone)
    s.pcs[3].cut = true
    s:run(4)
    check(field(gone, "hidden") ~= true, "a partner gone silent keeps their ghost for now, in case it's a loading screen")
    check(field(e, "target") == h.pawn, "but an enemy after them turns to who's left, with nobody else on its list")
    check(not hates(3), "and they're off its list")
    s.pcs[3].cut = false
    s:run(7)
    check(field(field(gone, "BP_PBZHatredManagerComponent"), "CanBeHatredNow") == true, "heard again, they can be hated again")
    allErrors(s)
end

local function focus()
    part("enemy focus")
    local s = party({ { "ring", THUG, 0.0, 0.0, 100.0, 60000, 100 } })
    local h = s.pcs[1]
    Session.moveTo(s.pcs[1], 200, 0)
    Session.moveTo(s.pcs[2], 0, 200)
    Session.moveTo(s.pcs[3], -200, 0)
    Session.moveTo(s.pcs[4], 0, -200)
    s:run(8)
    local e = Session.enemyOn(h, "ring")
    local changes = field(e, "targetChanges") or 0
    local names = {}
    -- A minute with all four hitting it, and everyone moving so that the nearest keeps changing: the worst case for spam.
    for i = 1, 60 do
        local turn = i * 1.9
        for n = 1, 4 do
            Session.moveTo(s.pcs[n], math.cos(turn + n * 1.57) * 300, math.sin(turn + n * 1.57) * 300)
        end
        for n = 2, 4 do
            local copy = Session.enemyOn(s.pcs[n], "ring")
            swing(s.pcs[n], copy, select(1, Fake.health(copy)) - 5)
        end
        s:run(1)
        local t = field(e, "target")
        names[#names + 1] = t and rawget(t, "__addr") or 0
    end
    local turned = (field(e, "targetChanges") or 0) - changes
    check(turned <= 5, "a minute with four players on one enemy: it turned " .. turned .. " times, about once in 15 s at most")
    local flips = 0
    for i = 2, #names do
        if names[i] ~= names[i - 1] then
            flips = flips + 1
        end
    end
    check(flips <= 5, "second by second it's on one player, not flipping (" .. flips .. " changes)")

    -- One player alone hits it: after the hold it turns to them, and to nobody else.
    local s2 = party({ { "ring", THUG, 0.0, 0.0, 100.0, 60000, 100 } })
    local h2 = s2.pcs[1]
    Session.moveTo(s2.pcs[1], 100, 0)
    Session.moveTo(s2.pcs[2], 900, 0)
    Session.moveTo(s2.pcs[3], -900, 0)
    Session.moveTo(s2.pcs[4], 0, 900)
    s2:run(9)
    local ring = Session.enemyOn(h2, "ring")
    local on = field(ring, "target")
    check(on ~= nil, "it has a target")
    local hitter = 4
    for i = 1, 20 do
        local copy = Session.enemyOn(s2.pcs[hitter], "ring")
        swing(s2.pcs[hitter], copy, select(1, Fake.health(copy)) - 5)
        s2:run(1)
    end
    check(field(ring, "target") == ghostOf(h2, hitter), "the player who kept hitting it gets its attention after the hold")
    local hatredList = rawget(field(ring, "BP_PBZHatredManagerComponent"), "__fields").HatredList.items
    check(#hatredList >= 4, "and the others are back on its list after the turn")
    allErrors(s)
    allErrors(s2)
end

local function aiming()
    part("who an enemy's move is aimed at")
    local s = party({ { "ring", THUG, 0.0, 0.0, 100.0, 6000, 100 } })
    spread(s)
    s:run(6)
    local h = s.pcs[1]
    local e = Session.enemyOn(h, "ring")
    local function aimedAt(slot)
        local target = slot == 1 and h.pawn or ghostOf(h, slot)
        Fake.put(e, "target", target)
        Session.enemyMove(h, "ring", nil)
        s:run(0.2)
        h.sent = {}
        for _, pc in ipairs(s.pcs) do
            pc.lastAim = nil
        end
        Session.enemyMove(h, "ring", "/Game/Move/E" .. slot .. ".E" .. slot)
        s:run(0.3)
        return count(h.sent, " " .. slot .. "$") >= 1
    end
    check(aimedAt(3), "the host says which slot it's after")
    check(s.pcs[3].lastAim == s.pcs[3].pawn, "the guest it's after aims its copy at itself")
    check(s.pcs[2].lastAim == ghostOf(s.pcs[2], 3) and s.pcs[4].lastAim == ghostOf(s.pcs[4], 3), "the others aim theirs at that guest's ghost")
    check(aimedAt(1), "aimed at the host, it says 1")
    check(s.pcs[2].lastAim == ghostOf(s.pcs[2], 1) and s.pcs[3].lastAim == ghostOf(s.pcs[3], 1), "and every guest aims at the host's ghost")
    Fake.put(e, "target", nil)
    Session.enemyMove(h, "ring", nil)
    s:run(0.2)
    h.sent = {}
    Session.enemyMove(h, "ring", "/Game/Move/E9.E9")
    s:run(0.3)
    check(count(h.sent, " %-$") >= 1, "with nobody, it says -")
    allErrors(s)
end

local function bossStart(s)
    local h = s.pcs[1]
    h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
    s:run(2)
end

local function bossEnd(s)
    local h = s.pcs[1]
    local boss = Session.enemyOn(h, "boss")
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(1)
    h.hudLayout:UnRegisterBossHPBar(boss)
end

local function holding()
    part("dying in a boss fight")
    local s = party()
    spread(s)
    s:run(2)
    bossStart(s)
    check(everyone(s, function(pc) return pc.env.PBZ.game.bossFightActive() end), "a boss fight shows on all four")
    s:run(5)
    Session.die(s.pcs[3])
    s:run(5)
    check(field(s.pcs[3].deathWidget, "NotTick") == true, "a guest who dies with partners still fighting waits")
    Session.die(s.pcs[2])
    s:run(5)
    check(field(s.pcs[3].deathWidget, "NotTick") == true and field(s.pcs[2].deathWidget, "NotTick") == true, "one more going down changes nothing while another's up")
    check(s.pcs[3].env.PBZ.game.isSpectating(), "and they watch someone who's up")
    local watching = net(s.pcs[3]).watched
    check(watching == peer(s.pcs[3], 1), "first the first in the fight")
    Session.die(s.pcs[1])
    s:run(3)
    local onNow = net(s.pcs[3]).watched
    check(onNow == peer(s.pcs[3], 4), "the one they watch goes down: the camera moves to who's left")
    check(field(s.pcs[3].deathWidget, "NotTick") == true, "and they still wait")
    Session.revive(s.pcs[1])
    s:run(2)
    bossEnd(s)
    s:run(8)
    check(field(s.pcs[3].deathWidget, "NotTick") == false and field(s.pcs[2].deathWidget, "NotTick") == false, "the boss dies: their respawn goes on")
    allErrors(s)

    local t = party()
    spread(t)
    t:run(2)
    bossStart(t)
    t:run(5)
    Session.die(t.pcs[2])
    t:run(5)
    check(field(t.pcs[2].deathWidget, "NotTick") == true, "again: one guest waits")
    Session.die(t.pcs[1])
    t:run(5)
    Session.die(t.pcs[3])
    t:run(5)
    check(field(t.pcs[2].deathWidget, "NotTick") == true and field(t.pcs[1].deathWidget, "NotTick") == true, "with one player left, everyone waits for them, the host too")
    local watched = t.pcs[2].env.PBZ.net.watched
    check(watched == peer(t.pcs[2], 4), "and the camera is on the one still up")
    Session.die(t.pcs[4])
    t:run(6)
    local free = true
    for i = 1, 4 do
        free = free and field(t.pcs[i].deathWidget, "NotTick") == false
    end
    check(free, "every partner down: nobody waits any more")
    allErrors(t)
end

local function sits()
    part("sitting at a bell")
    local s = party()
    spread(s)
    s:run(2)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    local function refreshes()
        return count(h.trace, "GameMode Refresh Monster") + count(a.trace, "GameMode Refresh Monster")
            + count(b.trace, "GameMode Refresh Monster") + count(c.trace, "GameMode Refresh Monster")
    end
    local before = refreshes()
    Fake.setHealth(h.pawn, 100)
    Fake.setHealth(a.pawn, 100)
    Fake.put(a.gourd, "CurrentTime", 0)
    Session.sit(b)
    s:run(2)
    check(count(b.sent, "^E SIT$") == 1, "a guest sits, and says so once")
    check(count(h.sent, "^E SIT") == 0 and count(a.sent, "^E SIT") == 0 and count(c.sent, "^E SIT") == 0, "and nobody says it again")
    check(Fake.health(h.pawn) == 1000 and Fake.health(a.pawn) == 1000, "everyone who's up is healed")
    check(field(a.gourd, "CurrentTime") == 2, "with a full gourd")
    check(refreshes() == before, "and no world refreshes: the dead stay dead")
    Session.moveTo(c, 40000, 0)
    s:run(1)
    Session.die(c)
    s:run(2)
    Session.sit(a)
    s:run(2)
    check(gap(at(c.pawn), at(a.pawn)) > 30000, "a player who's dead can't go anywhere yet")
    check(Fake.health(c.pawn) == 0, "and a sit doesn't heal the dead")
    Session.revive(c)
    s:run(2)
    check(gap(at(c.pawn), at(a.pawn)) < 500, "up again, they go to the one who sat")
    allErrors(s)
    local t = party()
    spread(t)
    t:run(2)
    bossStart(t)
    t:run(5)
    Session.die(t.pcs[2])
    t:run(5)
    Session.sit(t.pcs[3])
    t:run(7)
    check(field(t.pcs[2].deathWidget, "NotTick") == true, "with others still fighting, one sit doesn't end the wait")
    allErrors(t)
end

local function sitsForTwo()
    part("sitting at a bell, two players")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    s:run(4)
    local h, g = s.pcs[1], s.pcs[2]
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(2)
    bossStart(s)
    s:run(5)
    Session.die(g)
    s:run(6)
    check(field(g.deathWidget, "NotTick") == true, "a guest who dies in the host's fight waits")
    Session.sit(h)
    s:run(7)
    check(field(g.deathWidget, "NotTick") == false, "the host sits, with a bar left up: their respawn goes on")
    check(not h.env.PBZ.game.bossFightActive(), "and that bar is gone")
    s:run(7)
    check(net(g).partnerFighting ~= true, "for good: nothing says the fight is on again")
    allErrors(s)

    local r = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "Revive = On\n")
    r:run(4)
    local rh, rg = r.pcs[1], r.pcs[2]
    Session.moveTo(rh, 0, 0)
    Session.moveTo(rg, 500, 0)
    r:run(2)
    Fake.setHealth(rg.pawn, 1)
    r:run(2)
    check(net(rh).partnerDowned == true, "a guest goes down, with revive on")
    Session.sit(rh)
    r:run(2)
    check(net(rh).partnerDowned == false, "the host sits, and they're back on their feet")
    check(Fake.health(rg.pawn) == 1000, "and rested")
    allErrors(r)

    local w = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, true, ENEMIES)
    w.pcs[2].joinAt = w.pcs[1].now + 8
    w:run(3)
    Session.moveTo(w.pcs[1], 0, 0)
    w:run(2)
    bossStart(w)
    w:run(6)
    local late = w.pcs[2]
    check(net(late).watchingFight == true, "a guest who joins in a fight watches it")
    Session.moveTo(w.pcs[1], 6000, 6000)
    w:run(1)
    w.pcs[1].hudLayout:UnRegisterBossHPBar(Session.enemyOn(w.pcs[1], "boss"))
    late.env.PBZ.game.showBossBar(Session.enemyOn(late, "boss"))        -- (as after a real fight: nothing took this one down)
    check(late.env.PBZ.game.bossFightActive(), "the host's fight is over with a bar left up here")
    w:run(8)
    check(net(late).watchingFight ~= true and not late.env.PBZ.game.isSpectating(), "they aren't kept watching by it")
    check(not late.env.PBZ.game.bossFightActive(), "the bar goes with the trip")
    check(gap(at(late.pawn), at(w.pcs[1].pawn)) < 500, "and they go to the host")
    allErrors(w)
end

local function twoSaves()
    part("two saves, two lists of the dead")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local h, g = s.pcs[1], s.pcs[2]
    local i = Session.indexOf(h, "thug1")
    table.remove(h.enemies, i)
    table.remove(h.spawners, i)
    Session.moveTo(h, 30000, 0)
    Session.moveTo(g, 30000, 0)
    s:run(3)
    Session.moveTo(h, 1000, 300)
    Session.moveTo(g, 1200, 300)
    local copy = Session.enemyOn(g, "thug1")
    local brain = field(field(copy, "Controller"), "BrainComponent")
    s:run(1)
    check(field(copy, "hidden") ~= true, "an enemy only the guest's save has isn't taken away at once")
    s:run(5)
    check(count(g.sent, "^E HAS sp:thug1$") == 1, "the guest asks the host about it, once")
    check(count(h.sent, "^E NOT sp:thug1$") == 1, "and the host, who hasn't got it, says so")
    check(field(copy, "hidden") == true, "then it steps aside")
    check(field(brain, "running") == false, "its AI stops")
    check(field(copy, "dead") ~= true and select(1, Fake.health(copy)) > 0, "and it isn't killed")
    local boss = Session.enemyOn(g, "boss")
    check(field(boss, "hidden") ~= true, "a boss stays")
    Session.moveTo(h, 30000, 0)
    s:run(2)
    check(field(copy, "hidden") == false and field(brain, "running") == true, "the host moves on, and it's back")
    Session.moveTo(h, 1000, 300)
    s:run(5)
    check(field(copy, "hidden") == true, "the host comes back, and it's out of the way again")
    local home = h.map
    h.map = "Map_Other"
    s:run(2)
    check(field(copy, "hidden") == false and field(brain, "running") == true, "the host goes to another map: it's back too")
    h.map = home
    s:run(5)
    Session.command(g, "netoff")
    s:run(1)
    check(field(copy, "hidden") == false, "sync off: everything's back as it was")
    allErrors(s)

    -- It ran after the guest, right next to the host, and the host's own copy is far off. Not in the host's lines, but the host has it.
    local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local th, tg = t.pcs[1], t.pcs[2]
    Session.moveTo(th, 30000, 0)
    Session.moveTo(tg, 30000, 0)
    t:run(3)
    Session.moveTo(th, 0, 0)
    Session.moveTo(tg, 300, 0)
    local chaser = Session.enemyOn(tg, "guestside")
    Fake.put(chaser, "loc", { X = 500.0, Y = 100.0, Z = 100.0 })
    t:run(1)
    t:run(5)
    check(count(tg.sent, "^E HAS sp:guestside$") == 1, "a copy that ran off from the host's is asked about too")
    check(count(th.sent, "^E NOT ") == 0, "the host has it, and says nothing")
    check(field(chaser, "hidden") ~= true, "so it stays")
    allErrors(t)
end

local function otherMaps()
    part("a boss fight on another map")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    local i = Session.indexOf(g, "boss")
    table.remove(g.enemies, i)
    table.remove(g.spawners, i)
    g.map = "Map_Other"
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 90000, -70000)
    s:run(3)
    bossStart(s)
    s:run(10)
    check(gap(at(g.pawn), { X = 90000, Y = -70000 }) < 10, "a partner on another map stays where they are")
    check(field(field(g.pawn, "CharacterMovement"), "MovementMode") == 1, "and isn't left flying there")
    allErrors(s)
end

-- Two players beside each other, near no boss yet.
local function pair(extraIni)
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, extraIni)
    s:run(4)
    Session.moveTo(s.pcs[1], 0, 0)
    Session.moveTo(s.pcs[2], 500, 0)
    s:run(2)
    return s, s.pcs[1], s.pcs[2]
end

local function fightsAndWhoIsLeft()
    part("a fight, and who's left in it")
    local s, h, g = pair()
    Session.moveTo(g, 3000, 2900)
    Session.moveTo(h, 30000, 3000)
    s:run(2)
    g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
    s:run(2)
    check(gap(at(h.pawn), at(g.pawn)) < 1000, "a host far off is brought into a guest's fight")
    Session.moveTo(g, 30000, 3000)
    s:run(1)
    local boss = Session.enemyOn(h, "boss")
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(12)
    check(gap(at(h.pawn), at(g.pawn)) < 1000, "the boss dies: the host is brought back out, as a guest would be")
    allErrors(s)

    local c, ch, cg = pair()
    Session.respawned(ch)
    c:run(1)
    Session.moveTo(cg, 3000, 2900)
    Session.moveTo(ch, 30000, 3000)
    c:run(1)
    cg.hudLayout:RegisterBossHPBar(Session.enemyOn(cg, "boss"))
    c:run(5)
    check(gap(at(ch.pawn), at(cg.pawn)) > 20000, "just respawned, the host isn't dragged into a guest's fight")
    c:run(28)
    check(gap(at(ch.pawn), at(cg.pawn)) < 1000, "over it, with the walls closed and the fight still on, it is")
    allErrors(c)

    local e, eh, eg = pair()
    Session.respawned(eh)
    e:run(1)
    Session.moveTo(eg, 3000, 2900)
    Session.moveTo(eh, 30000, 3000)
    e:run(1)
    local foe = Session.enemyOn(eg, "boss")
    eg.hudLayout:RegisterBossHPBar(foe)
    e:run(3)
    eg.hudLayout:UnRegisterBossHPBar(foe)
    e:run(33)
    check(gap(at(eh.pawn), { X = 30000, Y = 3000 }) < 10, "a fight over by then pulls nobody")
    allErrors(e)

    local w = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    w.pcs[2].joinAt = w.pcs[1].now + 8
    w:run(3)
    Session.moveTo(w.pcs[1], 0, 0)
    w:run(2)
    bossStart(w)
    w:run(6)
    local late = w.pcs[2]
    check(net(late).partnerFighting == true, "with two players, one who joins now hears there's a fight")
    check(net(late).watchingFight == true, "and watches it instead of landing in it")
    w.pcs[1].cut = true
    w:run(18)
    check(net(late).watchingFight ~= true and not late.env.PBZ.game.isSpectating(), "the host vanishes: the watch ends with them")
    check(field(field(late.pawn, "CharacterMovement"), "MovementMode") == 1, "and they aren't left hanging there")
    check(not late.env.PBZ.game.bossFightActive(), "and the bar goes too")
    check(net(late).partnerFighting ~= true, "and nothing says there's a fight on")
    allErrors(w)

    local p = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local ph, pa, pb, pc4 = p.pcs[1], p.pcs[2], p.pcs[3], p.pcs[4]
    local i = Session.indexOf(ph, "boss")
    table.remove(ph.enemies, i)
    table.remove(ph.spawners, i)
    p:run(5)
    spread(p)
    p:run(2)
    pa.hudLayout:RegisterBossHPBar(Session.enemyOn(pa, "boss"))
    p:run(3)
    check(pb.env.PBZ.game.bossFightActive() and pc4.env.PBZ.game.bossFightActive(), "a guest's fight shows on the other guests")
    pa.cut = true
    p:run(16)
    check(not pb.env.PBZ.game.bossFightActive() and not pc4.env.PBZ.game.bossFightActive(), "that guest vanishes: the copies of it go")
    check(net(pb).partnerFighting ~= true and next(net(pb).partnerBosses) == nil, "nobody tells anybody there's a fight on")
    allErrors(p)

    local l, lh, lg = pair()
    Session.moveTo(lg, 3000, 2900)
    Session.moveTo(lh, 2800, 3000)
    l:run(1)
    bossStart(l)
    l:run(2)
    check(lg.env.PBZ.game.bossFightActive(), "the host's fight shows on the guest")
    Session.command(lg, "netoff")
    l:run(1)
    check(not lg.env.PBZ.game.bossFightActive(), "the guest leaves: its bar for that fight goes")
    allErrors(l)

    local t, th, tg = pair()
    Session.moveTo(tg, 3000, 2900)
    Session.moveTo(th, 2800, 3000)
    t:run(1)
    tg.hudLayout:RegisterBossHPBar(Session.enemyOn(tg, "boss"))
    t:run(2)
    check(th.env.PBZ.game.bossFightActive(), "a guest's fight shows on the host")
    Session.sit(tg)
    t:run(2)
    check(not th.env.PBZ.game.bossFightActive(), "the guest sits at a bell: the host's copy of it goes too")
    allErrors(t)
end

local function weaponsFound()
    part("a weapon a partner found")
    local s, h, g = pair()
    h.bag:AddWeaponItem(h.env.FName("Tang"), true, true, false, false)
    s:run(2)
    check(count(g.trace, "AddWeaponItem") >= 1, "it reaches the guest")
    local asked = false
    for _, line in ipairs(g.trace) do
        if line:find("AddWeaponItem", 1, true) and line:find("true%s+true") then
            asked = true
        end
    end
    check(not asked, "without the game's full-screen question: their game goes on")
    check(count(g.logs, "your partner found something") == 1, "a tip says so")
    allErrors(s)
end

-- A trip: the world goes, and with it the ghost, which the next tick makes again.
local function afterATrip()
    part("arriving on a map")
    local spear = "/Game/Weapon/Spear.Spear"
    local s, h, g = pair()
    s:run(3)
    Session.hold(g, spear, true)
    s:run(1)
    local function holding()
        local c = field(field(net(h).ghost, "Character Weapons Component"), "config")
        return c and rawget(c, "__path")
    end
    check(holding() == spear, "a ghost holds its player's weapon")
    rawset(net(h).ghost, "__alive", false)
    s:run(3)
    check(h.env.PBZ.valid(net(h).ghost) and holding() == nil, "a new ghost isn't given anything at once: a weapon's skills may still be loading")
    s:run(4.5)
    check(holding() == spear, "a few seconds on, it has it")
    Session.bullet(g, g.pawn, "/PBZCombatAsset/ActorData/Players/Hun/BulletData/BD_Flower.BD_Flower", 0.0, 0.0, 100.0)
    s:run(0.5)
    check(#h.fired == 1, "and fires what its player fires")
    allErrors(s)
    local a, ah, ag = pair()
    a:run(3)
    rawset(net(ah).ghost, "__alive", false)
    a:run(2)
    Session.bullet(ag, ag.pawn, "/PBZCombatAsset/ActorData/Players/Hun/BulletData/BD_Flower.BD_Flower", 0.0, 0.0, 100.0)
    a:run(0.5)
    check(#ah.fired == 0, "not before")
    allErrors(a)
end

local function phantomEdge()
    part("a Phantom Edge weapon")
    local cannon = "/Game/Weapon/Cannon.Cannon"
    local s, h, g = pair()
    s:run(3)
    Session.holdEdge(h, cannon, false)
    s:run(1)
    local ghost = ghostOf(g, 1)
    local weapons = field(ghost, "Character Weapons Component")
    check(rawget(field(weapons, "edgeConfig") or {}, "__path") == cannon, "the partner's ghost gets the weapon they've equipped")
    check(field(weapons, "edgeArmed") == false, "put away")
    Session.holdEdge(h, cannon, true)
    Session.edgeMove(h, "/Game/Move/Show.Show")
    s:run(0.5)
    check(field(weapons, "edgeArmed") == true, "drawn for the skill")
    check(field(field(ghost, "edgeAnim"), "played") == 1, "and its mesh plays what the partner's plays: a cannon opens by a montage")
    Session.holdEdge(h, cannon, false)
    s:run(0.5)
    check(field(weapons, "edgeArmed") == false, "and it's put away again")
    Session.holdEdge(g, cannon, true)
    s:run(0.5)
    check(field(field(net(h).ghost, "Character Weapons Component"), "edgeArmed") == true, "the same the other way")
    allErrors(s)
    local p = party()
    spread(p)
    p:run(2)
    Session.holdEdge(p.pcs[3], cannon, true)
    p:run(1)
    local function armed(pc, slot)
        return field(field(ghostOf(pc, slot), "Character Weapons Component"), "edgeArmed")
    end
    check(armed(p.pcs[1], 3) == true and armed(p.pcs[2], 3) == true and armed(p.pcs[4], 3) == true, "with four players, every PC sees it on the right ghost")
    check(armed(p.pcs[1], 2) == false and armed(p.pcs[2], 1) == false, "and on nobody else's")
    local edge = p.pcs[1].env.PBZ.coop.handlers.E or function() end
    edge("/Etc/Evil.Evil 1", 2)
    p:run(0.5)
    check(armed(p.pcs[1], 2) == false, "a path outside the game's own folders is refused")
    allErrors(p)
end

local function shots()
    part("bullets")
    local flower = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/BD_Flower.BD_Flower"
    local s, h, g = pair()
    s:run(3)
    Session.bullet(h, h.pawn, flower, 120.0, 340.0, 100.0)
    Session.bullet(h, h.pawn, flower, 220.0, 340.0, 100.0)
    s:run(0.5)
    check(#g.fired == 2, "a player's two flowers come up on the partner's PC")
    local first, second = g.fired[1] or {}, g.fired[2] or { at = {} }
    check(first.owner == net(g).ghost, "from the ghost")
    check(second.at.X == 220 and second.at.Y == 340, "where they lie")
    check(first.started == true and second.started == true, "and started: made and not started, nothing shows")
    s:run(1)
    check(#g.fired == 2, "each once, for as long as it lasts")
    check(#h.fired == 0, "and they don't come back")
    Session.bullet(g, net(g).ghost, flower, 0.0, 0.0, 100.0)
    Session.bullet(h, Session.enemyOn(h, "thug1"), flower, 500.0, 0.0, 100.0)
    Session.bullet(h, h.pawn, flower, 0.0, 0.0, 100.0, false)
    Session.bullet(h, h.pawn, flower, 0.0, 0.0, 100.0, true, true)
    s:run(0.5)
    check(#g.fired == 2 and #h.fired == 0, "not a ghost's, an enemy's, a swing's sweep, or one another bullet started")
    h.liveBullets[1] = nil
    for i = #h.liveBullets, 1, -1 do
        h.liveBullets[i] = nil
    end
    s:run(0.3)
    Session.bullet(h, h.pawn, flower, 10.0, 20.0, 100.0)
    s:run(0.5)
    check(#g.fired == 3, "the next one goes too")
    local shot = g.env.PBZ.coop.handlers.SHOT or function() end
    shot("/Game/Anything/At.All 1 2 3 0 0 0")
    shot(flower .. " 1e300 2 3 0 0 0")
    shot(flower .. " nan 2 3 0 0 0")
    shot("nonsense")
    check(#g.fired == 3, "anything but a player's bullet data, or a place that makes no sense, is refused")
    for _ = 1, 100 do
        shot(flower .. " 1 2 3 0 0 0")
    end
    check(#g.fired <= 3 + 40, "and a flood stops at forty a second")
    allErrors(s)
    local q = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "PvP = On\n")
    q:run(4)
    Session.moveTo(q.pcs[1], 0, 0)
    Session.moveTo(q.pcs[2], 500, 0)
    q:run(2)
    Session.bullet(q.pcs[1], q.pcs[1].pawn, flower, 120.0, 340.0, 100.0)
    q:run(0.5)
    check(#q.pcs[2].fired == 0, "in PvP the ghost's abilities run for real, so nothing's copied")
    allErrors(q)
end

local function noBodyYet()
    part("shared while there's nobody to give it to")
    local s, h, g = pair()
    rawset(g.pawn, "__alive", false)
    Session.gainDust(h, 300)
    g.env.PBZ.coop.handlers.I("loot:sp:thug1 R_7 -")
    s:run(1.5)
    check(Session.dust(g) == 0, "dust that comes during a respawn can't be paid yet")
    rawset(g.pawn, "__alive", true)
    s:run(2)
    check(Session.dust(g) == 300, "it's paid as soon as there's a body")
    check(Session.items(g, "R_7") == 1, "and so is a kill's loot")
    check(Session.dust(h) == 300, "and nothing comes back to the one who earned it")
    allErrors(s)
end

local function whatsLeftOfAPartner()
    part("what's left of a partner who's gone")
    local s, h, g = pair("Revive = On\n")
    Fake.setHealth(g.pawn, 1)
    s:run(2)
    check(net(h).partnerDowned == true, "a partner goes down")
    g.cut = true
    s:run(14)
    check(net(h).partnerDowned ~= true, "and vanishes: they aren't down any more")
    g.cut = false
    s:run(3)
    allErrors(s)

    local l, lh, lg = pair("Revive = On\n")
    local floor = field(field(lg.pawn, "AttributeSetBase"), "Health_Min")
    l:run(1)
    check(field(floor, "CurrentValue") == 1, "with revive on, a floor under the player's health")
    Session.command(lg, "netoff")
    l:run(1)
    check(field(floor, "CurrentValue") == 0, "sync off: the floor goes, or they couldn't die alone")
    allErrors(l)

    local d, dh, dg = pair("Revive = On\n")
    Fake.setHealth(dg.pawn, 1)
    d:run(2)
    Session.command(dg, "netoff")
    d:run(1)
    check(net(dg).partnerDowned ~= true and field(field(field(dg.pawn, "AttributeSetBase"), "Health_Min"), "CurrentValue") == 0, "leaving while down lets go too")
    check(count(dg.sent, "^E DOWN") == 1, "(they were down)")
    Session.moveTo(dg, 0, 0)
    allErrors(d)

    local k, kh = pair()
    kh.env.PBZ.coop.handlers.GK("sp:thug1")
    Session.command(kh, "netoff")
    k:run(1)
    Session.command(kh, "neton host")
    k:run(1)
    check(next(net(kh).guestKilled) == nil, "a kill told in an earlier session isn't paid out to the next one")
    allErrors(k)

    local m, mh = pair()
    mh.mapOpen = true
    m:run(1)
    local marker = mh.mapWidgets[1]
    check(field(marker, "visibility") == 3, "the partner's marker is on the open map")
    mh.mapOpen = false
    m:run(2)
    m.pcs[2].map = "Map_Other"
    m:run(2)
    mh.mapOpen = true
    m:run(3)
    check(field(marker, "visibility") == 1, "they go elsewhere, and on the map opened again it's gone")
    allErrors(m)
end

local function offAndBack()
    part("sync off, and back on")
    local s, h, g = pair()
    Session.moveTo(h, 1500, 400)
    Session.moveTo(g, 1600, 400)
    s:run(3)
    local copy = Session.enemyOn(g, "thug1")
    local picker = field(copy, "picker")
    g.env.PBZ.game.aimCopy(copy, copy:GetAddress(), net(g).ghost)
    check(field(picker, "SwitchTargetCooldown") == 86400.0, "a guest's copy of an enemy keeps the target it's given")
    Session.command(g, "netoff")
    s:run(1)
    check(field(picker, "SwitchTargetCooldown") == 1.5, "sync off: it chooses for itself again")
    check(field(picker, "LastSwitchTime") > 1000 - 1000 and field(field(field(copy, "Controller"), "BrainComponent"), "running") == true, "and looks around now, not in a day")
    allErrors(s)

    local d, dh, dg = pair()
    Session.command(dh, "netoff")
    d:run(1)
    Session.gainDust(dh, 5000)
    Session.gainItem(dh, "R_9", 1)
    d:run(2)
    Session.command(dh, "neton host")
    d:run(3)
    check(count(dh.sent, "^E C 5000") == 0, "dust earned alone isn't sent to the partner at the next link")
    check(Session.dust(dg) == 0 and Session.dust(dh) == 5000, "the guest has none of it, and the host keeps it")
    Session.gainDust(dh, 40)
    d:run(2)
    check(Session.dust(dg) == 40, "what's earned together from then on is shared")
    allErrors(d)

    local p = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES)
    p:run(2)
    local ph = p.pcs[1]
    ph.files["PhantomPact.ini"] = "Role = Host\nSecret = hunter2"
    Session.command(ph, "onlinepanel press 700 500")
    Session.command(ph, "onlinepanel press 441 430")
    p:run(1)
    check(ph.files["PhantomPact.ini"]:find("Secret = hunter2\nFourPlayers = On\n", 1, true) ~= nil, "a setting added to an ini with no line end at its end keeps both")
    allErrors(p)

    local lang = dofile(SIM_SCRIPTS .. "/lang.lua")()
    lang.set("Chinese")
    check(lang.say("your partner rested at a bell: you're rested too.") == "队友在钟旁休息了:你也恢复了。", "the bell's tips in Chinese")
    check(lang.say("your partner rested at a bell: you'll join them.") == "队友在钟旁休息了:你会前往队友身边。", "both of them")
    check(lang.say("player 3 (gold) rested at a bell: you're rested too.") == "玩家 3(金) 在钟旁休息了:你也恢复了。", "and by name")
    check(lang.say("Couldn't start: couldn't find the host address abc") == "无法启动:找不到房主地址 abc", "and why the relay couldn't start")
    check(lang.say("Couldn't start: Steam isn't ready: is it running and logged in?") == "无法启动:Steam 还没准备好,请确认它已运行并已登录。", "for Steam too")

    local t, th = pair()
    local shownNow = function()
        for _, w in ipairs(th.widgets) do
            local text = field(w, "lastText")
            if text and text:find("Phantom Pact: ", 1, true) then
                return field(w, "visibility") == 3 and text or nil
            end
        end
    end
    th.env.PBZ.coop.handlers.SIT()
    t:run(3.5)
    check((shownNow() or ""):find("rested at a bell", 1, true) ~= nil, "a tip is up")
    th.env.PBZ.coop.handlers.UP()
    t:run(1)
    check((shownNow() or ""):find("back on their feet", 1, true) ~= nil, "a second one isn't cut short by the first one's timer")
    t:run(3.5)
    check(shownNow() == nil, "and goes in its own time")
    allErrors(t)
end

-- One PC, split screen. Player 2 comes in at the mod's next tick.
local function localGame(extra)
    local s = Session.new(SIM_SCRIPTS, { "Local" }, false, ENEMIES, extra)
    local pc = s.pcs[1]
    Session.scene(pc, false)
    s:run(3)
    return s, pc, pc.env.PBZ.state
end

-- Player 2 sees what player 1 sees, by the game's own rules and widgets.
local function localScreen()
    part("player 2's screen")
    local s, pc, state = localGame()
    s:run(1.5)
    local p2 = state.p2Pawn
    Fake.put(p2, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    local bell = Fake.switch(pc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    s:run(0.5)
    local comp = field(p2, "promptComp")
    local w = comp and field(comp, "widget")
    check(comp ~= nil and field(comp, "shown") == true and field(w, "plays") == 1, "their prompt is the game's own, played in once")
    check(field(w, "owner") == state.p2Controller, "theirs, not player 1's")
    check(field(comp, "at").X == 8000.0, "set down on the thing")
    check(field(field(w, "InputActionWidget_C_75"), "Icon").ResourceObject ~= nil, "with the button in it")
    s:run(1)
    check(field(w, "plays") == 1, "and it isn't played again while it stays")
    rawset(bell, "__forbidden", true)
    s:run(0.5)
    check(field(comp, "shown") == false and field(w, "outs") == 1, "the game says no (monsters about a bell): it plays out")
    Session.press2(s, "Gamepad_FaceButton_Right")
    check(field(pc.controller, "Pawn") == pc.pawn, "and the button that also executes doesn't ring it")
    rawset(bell, "__forbidden", nil)
    s:run(0.5)
    check(field(comp, "shown") == true and field(w, "plays") == 2, "back when the game says yes")
    rawset(bell, "__behind", true)
    s:run(0.5)
    check(field(comp, "shown") == false, "behind them, there's no prompt")
    Session.press2(s, "Gamepad_FaceButton_Right")
    check(field(pc.controller, "Pawn") == pc.pawn, "and nothing to press")
    rawset(bell, "__behind", nil)
    s:run(0.5)
    Fake.put(field(p2, "CharacterMovement"), "MovementMode", 5)
    s:run(0.5)
    check(field(comp, "shown") == false, "nor on a rope")
    Fake.put(field(p2, "CharacterMovement"), "MovementMode", 1)
    s:run(0.5)
    check(field(comp, "shown") == true, "and it's there again on the ground")
    check(field(field(p2, "interact"), "paused") == true, "their own search for prompts stays off: it played them on player 1's things")
    pc.projected = { X = 960, Y = 100 }
    s:run(0.5)
    check(field(comp, "shown") == false, "out of their half of the screen, it isn't drawn on player 1's")
    pc.projected = nil
    s:run(0.5)
    pc.paused = true
    s:run(0.5)
    check(field(comp, "shown") == false, "gone at once over a menu")
    pc.paused = false
    s:run(0.5)
    check(field(comp, "shown") == true, "and back after it")
    allErrors(s)

    local r, rpc, rstate = localGame()
    r:run(1.5)
    local rbody = rstate.p2Pawn
    local far = Fake.switch(rpc, "BP_Chest_C", 8000.0, 0.0, 100.0)
    rawset(far, "__seen", true)
    rawset(far, "__forbidden", true)
    Fake.put(rbody, "loc", { X = 7200.0, Y = 0.0, Z = 100.0 })
    r:run(1)
    local rcomp = field(rbody, "promptComp")
    check(rcomp ~= nil and field(rcomp, "shown") == true and field(field(rcomp, "widget"), "ring") == 1, "something near, not in reach: the game's ring on it")
    rawset(far, "__forbidden", nil)
    Fake.put(rbody, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    r:run(1)
    check(field(field(rcomp, "widget"), "plays") == 1, "in reach, the ring opens into the button")
    allErrors(r)

    local n, npc, nstate = localGame()
    npc.found["/Game/PBZContent/UI/InGame/InteractionUI/W_InteractionUI.W_InteractionUI_C"] = nil
    n:run(1.5)
    Fake.put(nstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local chest = Fake.switch(npc, "BP_Chest_C", 8000.0, 0.0, 100.0)
    n:run(0.5)
    check(field(nstate.p2Pawn, "promptComp") == nil and count(npc.logs, "stays the plain one") == 0, "with no such widget, the plain prompt stands in")
    Session.press2(n, "Gamepad_FaceButton_Right")
    check(field(chest, "opened") == 1, "and it opens all the same")
    allErrors(n)

    local d, dpc, dstate = localGame()
    d:run(1.5)
    local body2 = dstate.p2Pawn
    Fake.setHealth(body2, 300)
    Fake.setHealth(dpc.pawn, 500)
    Fake.drink(dpc, body2)
    check(Fake.health(body2) == 700 and Fake.health(dpc.pawn) == 500, "player 2's drink is theirs: the game's own step heals them")
    check(dpc.glowedOn == body2, "and the glow is on them")
    check(field(dpc.controller, "Pawn") == dpc.pawn and field(dpc.controller, "Character") == dpc.pawn, "and player 1's controller holds player 1 again")
    check(field(dpc.gourd, "CurrentTime") == 2, "the shared gourd keeps its charge")
    Fake.drink(dpc, dpc.pawn)
    check(Fake.health(dpc.pawn) == 900 and Fake.health(body2) == 700, "player 1's own drink stays theirs")
    check(field(dpc.gourd, "CurrentTime") == 1, "and comes out of the gourd")
    Fake.setHealth(body2, 300)
    Fake.drink(dpc, body2, "NingFengDan")
    d:run(5)
    check(Fake.health(body2) == 700 and field(dpc.gourd, "CurrentTime") == 1, "the D-pad's other item isn't the gourd: nothing's put back")
    Fake.drink(dpc, body2)
    Fake.drink(dpc, body2)
    Fake.setHealth(body2, 300)
    Fake.drink(dpc, body2)
    check(Fake.health(body2) == 300, "their own charges gone, there's no drink")
    d:run(0.2)
    check(count(dpc.logs, "gourd is empty") >= 1, "and they're told")
    allErrors(d)

    local l, lpc, lstate = localGame()
    l:run(1.5)
    Fake.put(lpc.gourd, "CurrentTime", 0)
    Session.press2(l, "Gamepad_DPad_Down")
    check(field(lpc.gourd, "CurrentTime") == 1 and #lpc.injected == 1, "player 1 emptied the gourd: player 2's press still drinks their own charge")
    l:run(7)
    check(field(lpc.gourd, "CurrentTime") == 0, "a press that came to nothing leaves the gourd as it was")
    Fake.put(lpc.gourd, "CurrentTime", 0)
    Fake.setHealth(lstate.p2Pawn, 300)
    Session.press2(l, "Gamepad_DPad_Down")
    Fake.drink(lpc, lstate.p2Pawn)
    l:run(6)
    check(Fake.health(lstate.p2Pawn) == 700 and field(lpc.gourd, "CurrentTime") == 0, "and one that drank takes the lent charge with it")
    allErrors(l)

    local k, kpc, kstate = localGame()
    k:run(1.5)
    local before = #kpc.widgets
    Fake.put(field(field(kstate.p2Pawn, "AttributeSetBase"), "UltimateCharge"), "CurrentValue", 50)
    Fake.put(field(field(kstate.p2Pawn, "AttributeSetBase"), "UltimateChargeCount"), "CurrentValue", 1)
    Fake.setHealth(kstate.p2Pawn, 1)
    k:run(1.5)
    local cover, art = kpc.widgets[before + 1], kpc.widgets[before + 5]
    check(#kpc.widgets == before + 5 and field(cover, "position").Y == 810, "going down: the game's death card, in their half")
    k:run(4.7)
    local back = kpc.now
    while next(kpc.inputSets[0]) == nil and kpc.now - back < 2 do
        k:run(0.1)
    end
    k:run(2.3)
    check(field(cover, "removed") == true and field(art, "removed") == true, "it goes when they're back")
    check(next(kpc.inputSets[0]) ~= nil, "player 1 keeps their controls through it")
    check(field(kstate.p2Pawn, "used") == kpc.riseClass, "and they get up off the ground")
    check(field(field(field(kstate.p2Pawn, "AttributeSetBase"), "UltimateCharge"), "CurrentValue") == 50
        and field(field(field(kstate.p2Pawn, "AttributeSetBase"), "UltimateChargeCount"), "BaseValue") == 1, "with their Ultimate gauge as it was")
    allErrors(k)

    local a, apc, astate = localGame()
    a:run(1.5)
    local stats, stats2 = field(apc.pawn, "AttributeSetBase"), field(astate.p2Pawn, "AttributeSetBase")
    Fake.put(field(stats, "Attack"), "CurrentValue", 55)
    a:run(3)
    check(field(field(stats2, "Attack"), "CurrentValue") == 55, "what the story adds to player 1's numbers reaches player 2")
    Fake.put(field(stats2, "Attack"), "CurrentValue", 70)
    a:run(3)
    check(field(field(stats2, "Attack"), "CurrentValue") == 70, "and a buff of their own stays on top")
    Fake.put(field(stats2, "Attack"), "CurrentValue", 50)
    a:run(3)
    check(field(field(stats2, "Attack"), "CurrentValue") == 55, "and when it ends they're back at player 1's number")
    allErrors(a)

    local e, epc, estate = localGame()
    e:run(1.5)
    local body = estate.p2Pawn
    local point = field(body, "points").Execution
    check(field(point, "owner") == estate.p2Controller.Player, "their execution points draw in their own half")
    local widget = point:GetWidget()
    Fake.put(widget, "shown", true)
    e:run(0.5)
    check(field(field(widget, "InputActionWidget"), "Icon").ResourceObject ~= nil, "with the button in them")
    allErrors(e)

    local h, hpc, hstate = localGame()
    local possessed = count(hpc.trace, "PlayerController Possess")
    h:run(4)
    check(count(hpc.trace, "PlayerController Possess") == possessed, "(with no possession: nobody's move is touched)")
    check(count(hpc.logs, "Player 2 has a HUD of their own") == 1, "their HUD is the game's own")
    check(field(hpc.playerHud, "heldBy") == hstate.p2Pawn, "made while it looks at their body")
    check(field(hpc.controller, "Pawn") == hpc.pawn and field(hstate.p2Controller, "Pawn") == hstate.p2Pawn, "and each player has their own body back")
    h:run(1)
    check(field(hpc.playerHud, "visibility") == 3, "up in play")
    hpc.paused = true
    h:run(0.5)
    check(field(hpc.playerHud, "visibility") == 1, "away over a menu")
    hpc.paused = false
    h:run(0.5)
    local boss = Fake.enemy(hpc, "boss", "BP_Boss_C", 100.0, 0.0, 100.0, 5000, 100, true)
    hpc.env.PBZ.game.bossActors = function() return { boss } end
    h:run(1.5)
    local foe = Session.enemyOn(hpc, "thug1")
    Fake.put(foe, "loc", { X = field(hstate.p2Pawn, "loc").X + 500, Y = 0.0, Z = 100.0 })
    field(foe, "BP_PBZHatredManagerComponent"):AddActorToHatredList(hstate.p2Pawn, {})
    h:run(1.5)
    check(field(hpc.playerHud, "pointers")[foe] == true, "an enemy after them gets an arrow on their HUD")
    Fake.setHealth(foe, 0)
    h:run(1.5)
    check(field(hpc.playerHud, "pointers")[foe] == nil, "and it goes when the enemy does")
    local bar = hpc.bossBars[1]
    check(#hpc.bossBars == 1 and field(bar, "boss") == boss and field(bar, "owner") == hstate.p2Controller, "the boss's bar is in their half, the game's own")
    hpc.paused = true
    h:run(0.5)
    check(field(bar, "visibility") == 1, "away over a menu with the rest")
    hpc.paused = false
    h:run(0.5)
    Fake.put(hstate.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    Fake.switch(hpc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    h:run(0.5)
    Session.press2(h, "Gamepad_FaceButton_Right")
    check(field(hpc.controller, "Pawn") == hpc.pawn, "in a boss fight a bell won't have them, as it won't player 1")
    hpc.env.PBZ.game.bossActors = function() return {} end
    h:run(1.5)
    check(field(bar, "removed") == true, "and the bar goes with the fight")
    allErrors(h)
end

local function localPlay()
    part("local co-op")
    local s, pc, state = localGame()
    check(pc.env.PBZ.valid(state.p2Pawn), "player 2 comes in")
    local p2 = state.p2Pawn
    Fake.put(p2, "ConsciousnessDust", 0)
    s:run(1.5)
    Fake.put(p2, "ConsciousnessDust", 500)
    Fake.setHealth(p2, 1)
    s:run(1.5)
    check(Session.dust(pc) == 500, "what player 2 earned just before going down reaches player 1")
    allErrors(s)

    local c, cpc, cstate = localGame()
    local min = field(field(cstate.p2Pawn, "AttributeSetBase"), "Health_Min")
    c:run(1.5)
    check(field(min, "CurrentValue") == 1, "a floor under player 2's health")
    Session.scene(cpc, true)
    c:run(2.5)
    Session.scene(cpc, false)
    local lowest = 1
    c:run(1.5, function() lowest = math.min(lowest, field(min, "CurrentValue")) end)
    check(lowest == 1, "and it never lets go after a scene: a real death would take player 1 to the bell")
    allErrors(c)

    local h, hpc, hstate = localGame()
    h:run(1.5)
    Session.moveTo(hpc, 0, 0)
    local chest = Fake.switch(hpc, "BP_Chest_C", 8000.0, 0.0, 100.0)
    Fake.put(hstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    h:run(0.5)
    local at = { X = 0.0, Y = 0.0 }
    local pulled = 0
    local function run()
        if field(hpc.pawn, "loc").X > at.X + 50 then
            pulled = pulled + 1
        end
        at.X = at.X - 8
        Session.moveTo(hpc, at.X, 0)
    end
    Session.press2(h, "Gamepad_FaceButton_Right")
    check(field(chest, "opened") == 1, "player 2 opens a chest")
    h:run(1.6, run)
    check(at.X < -500 and pulled == 0, "and player 1, running the other way, isn't pulled back")
    check(#field(field(hstate.p2Pawn, "interact"), "used") == 1 and #field(field(hpc.pawn, "interact"), "used") == 0,
        "it's their own component that does it: through player 1's the game walked player 1 over and sheathed their sword")
    check(field(field(hstate.p2Pawn, "interact"), "theplayer") == hstate.p2Pawn and field(hpc.controller, "Pawn") == hpc.pawn,
        "with \"the player\" pointed at them for the call, and back")
    allErrors(h)

    local g, gpc, gstate = localGame()
    g:run(1.5)
    Session.moveTo(gpc, 7000, 0)
    Fake.put(gstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local openedChest = Fake.switch(gpc, "BP_Chest_C", 8000.0, 0.0, 100.0)
    local camera, opening, sequence = Fake.chestScene(gpc, openedChest)
    g:run(0.5)
    gpc.walksUp = true
    Session.press2(g, "Gamepad_FaceButton_Right")
    g:run(1)
    check(field(openedChest, "opened") == 0, "the game walks them up to it first")
    Fake.arrive(gpc, openedChest)
    check(field(openedChest, "theplayer") == gpc.pawn, "the opening is played by hand: pointed at them as it starts, it threw them across the map")
    g:run(0.5)
    check(field(openedChest, "opened") == 1, "a chest's opening runs, for the loot")
    check(field(gpc.controller, "viewTarget") == gpc.pawn, "player 1 keeps their own half of the screen")
    check(field(gstate.p2Pawn, "opening") == opening, "player 2 plays the opening")
    check(field(gstate.p2Controller, "viewTarget") == camera and field(sequence, "cutsOff") == true, "and has the close-up")
    check(field(gstate.p2Controller, "ignored") == true, "and stays put for it, as the one at a chest does")
    g:run(3.4)
    check(field(gstate.p2Controller, "viewTarget") == camera and field(gstate.p2Controller, "ignored") == true, "which isn't let go of for nothing")
    check(field(openedChest, "paid") == 1, "and it pays out at the end of the opening, once")
    Fake.put(sequence, "playing", false)
    g:run(1)
    check(field(gstate.p2Controller, "viewTarget") == gstate.p2Pawn, "it ends in their own view")
    check(field(gstate.p2Controller, "ignored") == false and next(gpc.inputSets[1]) ~= nil and field(field(gstate.p2Pawn, "PBZNBInput"), "resets") == 1,
        "and they can move: the game only ends player 1's input mode, and only gives their control sets back")
    local gone = Fake.switch(gpc, "BP_Chest_C", 7800.0, 300.0, 100.0)
    Fake.put(gstate.p2Pawn, "loc", { X = 7700.0, Y = 300.0, Z = 100.0 })
    Fake.chestScene(gpc, gone)
    gpc.walksUp = false
    g:run(3)
    Session.press2(g, "Gamepad_FaceButton_Right")
    g:run(0.5)
    Session.loadMap(gpc)
    g:run(4)
    check(field(gone, "paid") == nil, "a load in the middle of an opening: nothing is called on a chest that's gone")
    allErrors(g)

    local hitOn, hpc2, hstate2 = localGame()
    hitOn:run(1.5)
    Session.moveTo(hpc2, 7000, 0)
    Fake.put(hstate2.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local far = Fake.switch(hpc2, "BP_Chest_C", 8000.0, 0.0, 100.0)
    hitOn:run(0.5)
    hpc2.walksUp = true
    Session.press2(hitOn, "Gamepad_FaceButton_Right")
    hitOn:run(0.3)
    Fake.setHealth(hstate2.p2Pawn, 600)
    hitOn:run(0.3)
    check(field(far, "cancelled") == true and field(field(hstate2.p2Pawn, "PBZNBInput"), "resets") == 1, "a hit on the way to a chest ends it, and they have their pad at once")
    allErrors(hitOn)

    local sail, spc, sstate = localGame()
    sail:run(1.5)
    Fake.screen(spc, "W_ShipHudLayout_C")
    sail:run(0.6)
    check(field(sstate.p2Controller, "ignored") == true, "on a boat, player 2 sits it out, as they do a scene")
    Session.moveTo(spc, 30000, 0)
    local page = spc.screens[1]
    spc.screens[1] = nil
    Session.scene(spc, true)
    sail:run(0.6)
    Session.scene(spc, false)
    spc.screens[1] = page
    sail:run(0.6)
    check(field(sstate.p2Controller, "ignored") == true, "a scene on the way, with the boat's page down for it, doesn't let them out")
    check(math.abs(field(sstate.p2Pawn, "loc").X - 30000) > 1000, "nor bring them along yet")
    spc.screens[1] = nil
    sail:run(0.6)
    check(field(sstate.p2Controller, "ignored") == false, "and has their pad back when it's over")
    check(math.abs(field(sstate.p2Pawn, "loc").X - 30000) < 1000, "beside player 1, who has sailed off with them")
    Session.moveTo(spc, 30000, 0)
    Fake.put(sstate.p2Pawn, "loc", { X = 30000.0, Y = 300.0, Z = 100.0 })
    local wharf = Fake.switch(spc, "BP_Wharf_C", 30100.0, 300.0, 100.0)
    sail:run(0.5)
    Session.press2(sail, "Gamepad_FaceButton_Right")
    check(field(wharf, "opened") == 0, "a wharf isn't for player 2: whoever presses, the game seats player 1")
    allErrors(sail)

    local f, fpc, fstate = localGame()
    f:run(1.5)
    local swing = field(fstate.p2Pawn, "anim")
    Fake.rumble(fpc)
    check(field(fstate.p2Controller, "rumble") == nil and field(fpc.controller, "rumbleStopped") == nil, "with nobody doing anything, the game's rumble stays where it was")
    Fake.put(field(fstate.p2Pawn, "anim"), "montage", swing)
    local theirs = Fake.rumble(fpc)
    check(field(fstate.p2Controller, "rumble") == theirs and field(fpc.controller, "rumbleStopped") == theirs, "player 2 alone at it: it's their pad that rumbles, not player 1's")
    Session.moveTo(fpc, -8000, 0)
    check(Fake.shake(fpc) == 0.0, "and a blow of theirs far off doesn't shake player 1's camera")
    Fake.put(field(fpc.pawn, "anim"), "montage", swing)
    check(Fake.shake(fpc) == 1.0, "player 1's own does")
    local both = Fake.rumble(fpc)
    check(field(fstate.p2Controller, "rumble") ~= both, "and player 1's own rumble stays theirs")
    allErrors(f)

    local w, wpc, wstate = localGame()
    w:run(1.5)
    Session.moveTo(wpc, 7000, 0)
    Fake.put(wstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local door = Fake.switch(wpc, "BP_SingleDoor_C", 8000.0, 0.0, 100.0)
    w:run(0.5)
    wpc.walksUp = true
    Session.press2(w, "Gamepad_FaceButton_Right")
    w:run(1)
    Fake.arrive(wpc, door)
    check(field(door, "theplayer") == wstate.p2Pawn and field(wpc.controller, "Pawn") == wpc.pawn,
        "at a door, what starts as they get there takes them for \"the player\", and only that: it had player 1 pushing at the air")
    allErrors(w)

    local u, upc, ustate = localGame()
    u:run(1.5)
    Fake.put(ustate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local lever = Fake.switch(upc, "BP_Lever_C", 8000.0, 0.0, 100.0)
    u:run(0.5)
    Session.press2(u, "Gamepad_FaceButton_Right")
    u:run(2.5)
    Session.press2(u, "Gamepad_FaceButton_Right")
    check(field(lever, "opened") == 2, "a lever can be used again")
    local pile = Fake.switch(upc, "BP_Rubbish_C", 8000.0, 200.0, 100.0)
    Fake.put(ustate.p2Pawn, "loc", { X = 7900.0, Y = 210.0, Z = 100.0 })
    u:run(2.5)
    Session.press2(u, "Gamepad_FaceButton_Right")
    u:run(0.5)
    Session.press2(u, "Gamepad_FaceButton_Right")
    check(field(pile, "opened") == 1, "a pile pays once")
    u:run(2.5)
    check(next(upc.inputSets[1]) ~= nil, "and leaves them their controls")
    Session.loadMap(upc)
    u:run(2)
    check(upc.env.PBZ.valid(ustate.p2Pawn), "player 2 is back after a map change")
    allErrors(u)

    local late, lpc, lstate = localGame()
    late:run(1.5)
    Fake.switch(lpc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    Session.loadMap(lpc)
    for _ = 1, 50 do
        late:run(0.1)
        if lpc.env.PBZ.valid(lstate.p2Pawn) then
            break
        end
    end
    Fake.put(lstate.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    Session.press2(late, "Gamepad_FaceButton_Right")
    check(field(lpc.controller, "Pawn") == lpc.pawn, "as a load ends a bell is left alone: its end puts player 1's stats on whoever is the player")
    late:run(1.6)
    Session.press2(late, "Gamepad_FaceButton_Right")
    check(field(lpc.controller, "Pawn") == lstate.p2Pawn, "a moment later it isn't")
    allErrors(late)

    local b, bpc, bstate = localGame()
    b:run(1.5)
    Fake.put(bstate.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    Fake.switch(bpc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    b:run(0.5)
    Session.press2(b, "Gamepad_FaceButton_Right")
    check(field(bpc.controller, "Pawn") == bstate.p2Pawn, "player 2 rings a bell: the controllers swap bodies")
    b:run(19)
    check(field(bpc.controller, "Pawn") == bstate.p2Pawn, "(the walk and the ring take a while)")
    b:run(2)
    check(field(bpc.controller, "Pawn") == bpc.pawn, "a ring that never comes gives the bodies back in 20 s, not 120")
    check(field(bpc.controller, "ignored") == false and field(bstate.p2Controller, "ignored") == false, "with both pads free")
    allErrors(b)

    local m, mpc, mstate = localGame()
    m:run(1.5)
    Fake.put(mstate.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    Fake.switch(mpc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    m:run(0.5)
    Session.press2(m, "Gamepad_FaceButton_Right")
    local menu = { IsValid = function() return true end, IsVisible = function() return true end }
    mpc.bellMenus[1] = menu
    m:run(125)
    check(field(mpc.controller, "Pawn") == mstate.p2Pawn, "a bell menu open past two minutes isn't swapped away from under them")
    mpc.bellMenus[1] = nil
    m:run(5)
    check(field(mpc.controller, "Pawn") == mpc.pawn, "and the bodies go back when it closes")
    allErrors(m)

    local a, apc, astate = localGame()
    a:run(1.5)
    Session.loadMap(apc)
    Session.scene(apc, true)
    a:run(0.2)
    a:run(2)
    check(not apc.env.PBZ.valid(astate.p2Pawn), "a load that opens on a scene: player 2 doesn't stand in the shot")
    Session.scene(apc, false)
    a:run(2.5)
    check(apc.env.PBZ.valid(astate.p2Pawn), "and comes in after it")
    allErrors(a)

    local f, fpc = localGame()
    f:run(1)
    fpc.paused = true
    fpc.keys.F4 = true
    f:run(0.5)
    fpc.keys.F4 = false
    f:run(0.5)
    check(count(fpc.logs, "close the game's menu first") == 1, "F4 doesn't open over the game's own menu")
    fpc.paused = false
    allErrors(f)
end

local function elsewhere()
    part("what a partner on another map does")
    local y, yh, yg = pair()
    y:run(2)
    local refreshes = count(yg.trace, "GameMode Refresh Monster")
    yh.env.os.time = function() return 5000 end
    Session.loadMap(yh)
    y:run(2)
    check(count(yg.trace, "GameMode Refresh Monster") == refreshes, "the host travels: that's no new world for the guest")
    check(count(yg.logs, "The host loaded its world again") == 0, "nor said to be")
    rawset(yh.pawn, "__alive", false)
    Session.loadMap(yh)
    rawset(yh.pawn, "__alive", true)
    y:run(2)
    check(count(yg.logs, "The host loaded its world again") == 1, "from the title screen it is")
    allErrors(y)

    local s, h, g = pair()
    g.map = "Map_Other"
    s:run(2)
    g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
    s:run(2)
    local before = count(g.trace, "GameMode Refresh Monster")
    Session.respawned(h)
    s:run(2)
    check(count(h.sent, "^E R death$") == 1, "the host dies on its own map")
    check(count(g.trace, "GameMode Refresh Monster") == before, "and the guest's map doesn't refresh for it")
    check(g.env.PBZ.game.bossFightActive(), "and the fight the guest is in goes on")
    allErrors(s)
end

local function lateJoiner()
    part("joining during a boss fight")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    s.pcs[4].joinAt = s.pcs[1].now + 8
    s:run(3)
    spread(s)
    s:run(2)
    bossStart(s)
    s:run(6)
    local late = s.pcs[4]
    check(net(late).party == 4 and net(late).partnerFighting == true, "a guest who joins now hears there's a fight")
    check(net(late).watchingFight == true, "and watches it")
    check(late.env.PBZ.game.isSpectating(), "through someone in it")
    check(field(late.controller, "viewTarget") ~= nil, "the camera is on them")
    Session.moveTo(s.pcs[1], 6000, 6000)
    s:run(1)
    bossEnd(s)
    s:run(10)
    check(net(late).watchingFight ~= true and not late.env.PBZ.game.isSpectating(), "the fight ends: back in their own body")
    check(gap(at(late.pawn), at(s.pcs[1].pawn)) < 500, "and they go to the host")
    allErrors(s)
end

local function scaling()
    part("enemy health")
    local function max(pc, id)
        local _, hp, posture = Fake.health(Session.enemyOn(pc, id))
        return hp, posture
    end
    local s = party(nil, nil, { "Host", "Guest" })
    s:run(6)
    check(select(1, max(s.pcs[1], "thug1")) == 900, "two players in a party: 150%, as with the row off")
    allErrors(s)

    local j = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local jh = j.pcs[1]
    j.pcs[2].joinAt = jh.now + 9
    Session.moveTo(jh, 2800, 3000)
    j:run(3)
    bossStart(j)
    j:run(10)
    check(net(j.pcs[2]).watchingFight == true, "a partner joins a fight already on, with two players")
    check(select(1, max(jh, "boss")) == 5000, "they only watch it, so that boss keeps its number")
    check(select(1, max(jh, "thug1")) == 900, "the others get theirs")
    jh.hudLayout:UnRegisterBossHPBar(Session.enemyOn(jh, "boss"))
    j:run(3)
    check(select(1, max(jh, "boss")) == 7500, "the fight's over and it lived: now it rises")
    allErrors(j)

    local t = party(nil, nil, { "Host", "Guest", "Guest" })
    t:run(6)
    local hp, posture = max(t.pcs[1], "thug1")
    check(hp == 1200 and math.abs(posture - 160) < 0.01, "three players: 200% health, 160% posture")
    allErrors(t)

    local away = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    away.pcs[4].map = "Map_Other"
    away.pcs[3].map = "Map_Third"
    away:run(10)
    hp, posture = max(away.pcs[1], "thug1")
    check(hp == 1500 and math.abs(posture - 190) < 0.01, "four connected, two of them on other maps: 250% health, 190% posture, as they count wherever they are")
    allErrors(away)

    local u = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local h = u.pcs[1]
    u.pcs[4].joinAt = h.now + 8
    u:run(6)
    hp = max(h, "thug2")
    check(hp == 1200, "three connected: 200%")
    Fake.setHealth(Session.enemyOn(h, "thug2"), 600)        -- half
    u:run(8)
    hp, posture = max(h, "thug1")
    check(hp == 1500 and math.abs(posture - 190) < 0.01, "the fourth connects: 250%, 190%")
    check(math.abs(select(1, Fake.health(Session.enemyOn(h, "thug2"))) - 750) < 1, "and a hurt enemy keeps its share")
    check(everyone(u, function(pc) return math.abs(select(1, max(pc, "thug1")) - 1500) < 1 end, 2), "the guests' copies take the host's maximum")
    Session.die(u.pcs[3])
    u:run(8)
    check(select(1, max(h, "thug1")) == 1500, "a player going down doesn't make enemies weaker")
    u.pcs[4].cut = true
    u:run(15)
    check(select(1, max(h, "thug1")) == 1500, "nor does a player leaving")
    allErrors(u)

    -- Someone who joins during a boss fight only watches: that boss keeps its number, and everything else rises.
    local w = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    h = w.pcs[1]
    w.pcs[4].joinAt = h.now + 9
    w:run(6)
    check(select(1, max(h, "boss")) == 10000, "three connected: the boss at 200%")
    h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
    w:run(9)
    check(net(w.pcs[4]).party == 4 and select(1, max(h, "thug1")) == 1500, "someone joins during its fight: other enemies rise at once")
    check(select(1, max(h, "boss")) == 10000, "and the boss keeps its number")
    h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "boss"))
    w:run(3)
    check(select(1, max(h, "boss")) == 12500, "the fight's over and it lived: now it rises")
    allErrors(w)

    local v = party(nil, "CoopEnemyHealth = 100\nCoopEnemyPosture = 100\n")
    v:run(6)
    check(select(1, max(v.pcs[1], "thug1")) == 600, "100 stays 100, with any number of players")
    allErrors(v)
end

local function leaving()
    part("someone leaves")
    local s = party()
    spread(s)
    s:run(2)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    b.cut = true
    s:run(14)
    check(field(ghostOf(h, 3), "hidden") == true and field(ghostOf(a, 3), "hidden") == true and field(ghostOf(c, 3), "hidden") == true, "a guest who vanishes: their ghost hides on every PC")
    check(field(ghostOf(h, 2), "hidden") ~= true and field(ghostOf(a, 1), "hidden") ~= true, "nobody else's does")
    check(count(h.logs, "Lost player 3") == 1 and count(a.logs, "Lost player 3") == 1, "it's noticed")
    check(count(h.logs, "enemies are yours again") == 0 and count(a.logs, "enemies are yours again") == 0, "and it's not taken for the host going")
    check(net(a).remoteEnemies["sp:thug1"] ~= nil, "the guests' enemies stay the host's")
    check(net(h).partnerGone == false, "and for the host, someone's still there")
    b.cut = false
    s:run(3)
    check(field(ghostOf(h, 3), "hidden") == false, "back again, their ghost is too")

    a.cut = true
    b.cut = true
    c.cut = true
    s:run(14)
    check(net(h).partnerGone == true and count(h.logs, "enemies are yours again") == 1, "all three gone: the host is alone")
    allErrors(s)

    local t = party()
    spread(t)
    t:run(3)
    local copy = Session.enemyOn(t.pcs[2], "thug1")
    check(field(field(field(copy, "Controller"), "BrainComponent"), "running") == false, "the host's enemies are puppets on a guest")
    t.pcs[1].cut = true
    t:run(14)
    check(count(t.pcs[2].logs, "enemies are yours again") == 1, "the host vanishes: every guest takes its enemies back")
    check(field(field(field(copy, "Controller"), "BrainComponent"), "running") == true, "and their AI is back on")
    check(field(ghostOf(t.pcs[2], 1), "hidden") == true and field(ghostOf(t.pcs[2], 3), "hidden") == true and field(ghostOf(t.pcs[2], 4), "hidden") == true, "and with the host gone, so is everyone else: it's over for all of them")
    check(net(t.pcs[2]).remoteEnemies["sp:thug1"] == nil, "nothing's left of the host's enemies")
    allErrors(t)
end

local function sizeTips()
    part("the party changing size")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local h, a, b, late = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    late.joinAt = h.now + 7
    s:run(6)
    check(count(h.logs, "joined") == 0 or count(h.logs, "players now") >= 0, "(three are in)")
    s:run(4)
    check(count(h.logs, "player 4 %(blue%) joined%. 4 players now%.") == 1, "a tip says who joined and how many that makes")
    check(count(a.logs, "player 4 %(blue%) joined%. 4 players now%.") == 1, "on a guest's PC too")
    b.cut = true
    s:run(14)
    check(count(h.logs, "player 3 %(gold%) left%. 3 players now%.") == 1, "and who left")
    check(count(a.logs, "player 3 %(gold%) left%. 3 players now%.") == 1, "on a guest's PC too")
    b.cut = false
    s:run(3)
    check(count(h.logs, "player 3 %(gold%) joined%. 4 players now%.") == 1, "and who's back")
    local lang = dofile(SIM_SCRIPTS .. "/lang.lua")()
    lang.set("Chinese")
    check(lang.say("player 4 (blue) joined. 4 players now.") == "玩家 4(蓝) 加入了。现在有 4 名玩家。", "in Chinese too")
    check(lang.say("player 3 (gold) left. 3 players now.") == "玩家 3(金) 离开了。现在有 3 名玩家。", "both ways")
    check(lang.say("the host (purple) is down.") == "房主(紫) 倒下了。", "and the host by name")
    check(lang.say("Connected to 1.2.3.4. Ping 9 ms. Players: 3 of 4. You're player 3 (gold)."):find("玩家:3/4。", 1, true) ~= nil, "and the panel's line")
    check(lang.say("Local co-op starts the next time you start the game.") ~= "Local co-op starts the next time you start the game.", "and the Mode row's")
    check(lang.say("Multiplayer starts the next time you start the game.") ~= "Multiplayer starts the next time you start the game.", "and the way back")
    allErrors(s)
end

local function lateHello()
    part("hearing it's a party only after sync has started")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    s.relay.helloLate = 3
    s:run(2.5)
    check(net(s.pcs[3]).party == nil, "for a moment a guest thinks it's two players")
    s:run(1.5)
    Session.moveTo(s.pcs[1], 0, 0)
    Session.moveTo(s.pcs[2], 500, 0)
    Session.moveTo(s.pcs[3], 0, 500)
    Session.moveTo(s.pcs[4], -500, 0)
    s:run(3)
    check(net(s.pcs[3]).party == 4, "then it hears")
    local shown = 0
    for _, w in ipairs(s.pcs[3].widgets) do
        local p = field(w, "position")
        if field(w, "visibility") == 3 and p and math.abs(p.Y - 59.4) < 80 and not field(w, "removed") then
            shown = shown + 1
        end
    end
    check(shown == 4, "its compass goes on to show everyone (" .. shown .. ")")
    check(#s.pcs[3].spawned == 3, "and its first ghost is still the host's, with two more")
    allErrors(s)
end

local function fogAfterLeaving()
    part("a guest's fight, and that guest leaving")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
    local i = Session.indexOf(h, "boss")
    table.remove(h.enemies, i)
    table.remove(h.spawners, i)
    s:run(5)
    a.hudLayout:RegisterBossHPBar(Session.enemyOn(a, "boss"))
    s:run(3)
    check(next(net(b).foggedBosses) ~= nil, "another guest closes the walls for it")
    check(next(net(s.pcs[4]).foggedBosses) ~= nil and next(net(h).foggedBosses) == nil, "and so does the last guest; the host hasn't got that boss")
    a.cut = true
    s:run(14)
    check(next(net(b).foggedBosses) == nil and next(net(s.pcs[4]).foggedBosses) == nil, "the one fighting leaves: the walls open, whoever else's bar is up")
    allErrors(s)
end

local function devUnits()
    part("units (a developer's check on the real game)")
    local s = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES)
    s:run(2)
    local pc = s.pcs[1]
    check(count(pc.logs, "units") == 0 and #pc.spawned == 0, "in normal play it does nothing at all")
    Session.command(pc, "units 3")
    s:run(1)
    check(#pc.spawned == 0 and count(pc.logs, "units is off") == 1, "and without dev.txt it refuses")
    pc.files["dev.txt"] = ""
    Session.command(pc, "units 3")
    s:run(1)
    check(#pc.spawned == 3 and count(pc.logs, "units: 3 of 3 accepted") == 1, "with dev.txt, three units go in")
    check(count(pc.logs, "units: 3 spawned, 3 alive") == 1, "and the report counts them")
    s:run(2)
    Fake.setHealth(pc.spawned[2], 400)
    Session.command(pc, "units")
    s:run(1)
    check(count(pc.logs, "1 took damage, 3 hated by an enemy") == 1, "who was hit, and who's hated")
    check(count(pc.logs, "error panel: none") >= 1, "and the game's error panel")
    Session.command(pc, "units 0")
    s:run(1)
    check(count(pc.logs, "units: removed 3%.") == 1 and not rawget(pc.spawned[1], "__alive"), "units 0 takes them away")
    allErrors(s)
end

local function modeRow()
    part("the Mode row")
    local function roleOf(pc)
        return pc.files["PhantomPact.ini"]:match("\nRole = (%w+)") or pc.files["PhantomPact.ini"]:match("^Role = (%w+)")
    end
    local function shown(pc)
        pc.logs = {}
        Session.command(pc, "onlinepanel row mode")
        return pc.logs
    end
    local fresh = Session.new(SIM_SCRIPTS, { "Off" }, false, ENEMIES, nil, Session.shippedIni())
    fresh:run(2)
    local pc = fresh.pcs[1]
    check(roleOf(pc) == "Off", "a fresh install's ini says Role = Off")
    Session.command(pc, "onlinepanel press 700 500")
    fresh:run(1)
    shown(pc)
    fresh:run(1)
    check(count(pc.logs, "row mode: multiplayer") == 1, "and that shows as MULTIPLAYER")
    Session.command(pc, "onlinepanel press 40 500")      -- BACK
    fresh:run(1)
    pc.keys.F5 = true
    fresh:run(0.3)
    pc.keys.F5 = nil
    check(count(pc.logs, "Online panel open") == 1, "F5 opens the online panel")
    Session.command(pc, "onlinepanel toggle")
    pc.keys.F4 = true
    fresh:run(0.5)
    pc.keys.F4 = nil
    check(count(pc.logs, "%] Panel open") == 0, "F4 does nothing")
    allErrors(fresh, "and nothing complains")

    local s = Session.new(SIM_SCRIPTS, { "Off" }, false, ENEMIES)
    s:run(2)
    pc = s.pcs[1]
    local LOCAL, MULTIPLAYER = "onlinepanel press 441 450", "onlinepanel press 305 450"
    Session.command(pc, "onlinepanel press 700 500")
    Session.command(pc, LOCAL)
    s:run(1)
    check(roleOf(pc) == "Local", "LOCAL writes Role = Local")
    check(count(pc.logs, "Local co%-op starts the next time you start the game%.") == 1, "and says when")
    Session.command(pc, MULTIPLAYER)
    s:run(1)
    check(roleOf(pc) == "Off", "MULTIPLAYER writes Role = Off over Local")
    check(pc.files["PhantomPact.ini"]:find("CoopEnemyHealth = 150\n", 1, true) ~= nil and pc.files["PhantomPact.ini"]:find("FourPlayers = Off\n", 1, true) ~= nil, "and nothing else")

    -- Never over a Host or Guest, even if the row still says LOCAL.
    for _, role in ipairs({ "Host", "Guest" }) do
        Session.command(pc, LOCAL)
        s:run(1)
        pc.files["PhantomPact.ini"] = pc.files["PhantomPact.ini"]:gsub("Role = %w+", "Role = " .. role, 1)
        Session.command(pc, MULTIPLAYER)
        s:run(1)
        check(roleOf(pc) == role, "MULTIPLAYER leaves Role = " .. role .. " alone")
        pc.files["PhantomPact.ini"] = pc.files["PhantomPact.ini"]:gsub("Role = %w+", "Role = Off", 1)
    end

    -- Host, Guest and Leave write Role too: the row goes by what's there each time the page opens.
    Session.command(pc, LOCAL)
    Session.command(pc, "onlinepanel press 45 500")      -- BACK
    s:run(1)
    check(roleOf(pc) == "Local", "(Local, and back on the main page)")
    Session.command(pc, "onlinepanel host")
    s:run(1)
    check(roleOf(pc) == "Host", "HOST writes Role = Host")
    Session.command(pc, "onlinepanel press 700 500")
    s:run(1)
    pc.logs = {}
    Session.command(pc, "onlinepanel row mode")
    s:run(1)
    check(count(pc.logs, "row mode: multiplayer") == 1, "and the row follows it back to MULTIPLAYER")
    Session.command(pc, LOCAL)
    Session.command(pc, "onlinepanel press 45 500")
    Session.command(pc, "onlinepanel press 700 500")
    s:run(1)
    pc.logs = {}
    Session.command(pc, "onlinepanel row mode")
    s:run(1)
    check(count(pc.logs, "row mode: local") == 1, "an explicit Role = Local shows LOCAL")
    Session.command(pc, "onlinepanel press 45 500")
    Session.command(pc, "onlinepanel leave")
    Session.command(pc, "onlinepanel press 700 500")
    s:run(1)
    pc.logs = {}
    Session.command(pc, "onlinepanel row mode")
    s:run(1)
    check(roleOf(pc) == "Off" and count(pc.logs, "row mode: multiplayer") == 1, "LEAVE too")
    allErrors(s, "and nothing complains")

    -- The way back: Role = Local has F4 and no F5, and the button there undoes it.
    local l = Session.new(SIM_SCRIPTS, { "Local" }, false, ENEMIES)
    l:run(1)
    pc = l.pcs[1]
    pc.keys.F5 = true
    l:run(0.3)
    pc.keys.F5 = nil
    check(count(pc.logs, "Online panel open") == 0, "with Role = Local F5 opens nothing online")
    Session.command(pc, "panel press 100 500")
    l:run(1)
    check(roleOf(pc) == "Off", "F4's MULTIPLAYER button writes Role = Off")
    check(count(pc.logs, "Multiplayer starts the next time you start the game%.") == 1, "and says when")

    local o = Session.new(SIM_SCRIPTS, { "Local" }, false, ENEMIES, nil, "Role = Local\nOnlinePanel = Off\nConnect = Tailscale\nHostAddress = 10.0.0.1\n")
    o:run(1)
    pc = o.pcs[1]
    Session.command(pc, "panel press 100 500")
    o:run(1)
    check(roleOf(pc) == "Off" and pc.files["PhantomPact.ini"]:match("OnlinePanel = (%w+)") == "On", "from an ini with OnlinePanel = Off, it turns F5 back on as well")
end

local function offThings()
    part("what stays two-player")
    local s = party(nil, "PvP = On\nPvPDamage = 100\nRevive = On\n")
    spread(s)
    s:run(3)
    check(s.pcs[1].env.PBZ.net.pvp ~= true, "PvP stays off on a host in a party")
    check(everyone(s, function(pc) return net(pc).pvp ~= true end), "and on every guest, once they hear")
    check(count(s.pcs[1].logs, "more than two players") >= 1, "and the player is told")
    Session.command(s.pcs[1], "revive")
    Session.command(s.pcs[1], "netstatus")
    s:run(1)
    allErrors(s)
    local h = s.pcs[1]
    check(field(field(h.pawn, "AttributeSetBase").Health_Min, "CurrentValue") == 0, "no Revive floor under anyone")
    check(everyone(s, function(pc) return #pc.errors == 0 end), "and nothing complains")
end

local function screens()
    part("compass, map, tips, panel")
    local s = party()
    spread(s)
    s:run(3)
    local h = s.pcs[1]
    local function dots(pc)
        local n, spots, tints = 0, {}, {}
        for _, w in ipairs(pc.widgets) do
            local p = field(w, "position")
            if field(w, "visibility") == 3 and p and math.abs(p.Y - 59.4) < 80 and not field(w, "removed") then
                n = n + 1
                spots[#spots + 1] = p
                tints[#tints + 1] = field(field(w, "Circle"), "tint")
            end
        end
        return n, spots, tints
    end
    local n, _, tints = dots(h)
    check(n == 4, "the compass: the line and a dot for each of three partners (" .. n .. " widgets)")
    local players = h.env.PBZ.coop.players
    local shown = {}
    for _, tint in ipairs(tints) do
        shown[tint] = true
    end
    check(shown[players[2].tint] and shown[players[3].tint] and shown[players[4].tint], "each in that player's colour, told apart at a glance")
    local theirs, mine = s.pcs[3].env.PBZ.coop.players, {}
    for _, tint in ipairs(select(3, dots(s.pcs[3]))) do
        mine[tint] = true
    end
    check(mine[theirs[1].tint] and mine[theirs[2].tint] and mine[theirs[4].tint] and not mine[theirs[3].tint], "the same colours on a guest's PC, and not their own")
    n = dots(s.pcs[3])
    check(n == 4, "on a guest too (" .. n .. ")")
    Session.moveTo(s.pcs[2], 5000, 0)
    Session.moveTo(s.pcs[3], 5000, 10)
    Session.moveTo(s.pcs[4], 5000, 20)
    s:run(2)
    local _, spots = dots(h)
    local heights, different = {}, 0
    for _, p in ipairs(spots) do
        if not heights[p.Y] then
            heights[p.Y] = true
            different = different + 1
        end
    end
    check(different == 3, "three partners in one direction don't hide each other")     -- (the line shares its height with the first)
    s.pcs[4].map = "Map_Other"
    s:run(6)
    n = dots(h)
    check(n == 3, "one on another map: their dot goes (" .. n .. ")")
    Session.moveTo(s.pcs[4], 5000, 20)
    check(count(h.logs, "player 4 %(blue%) is on another map") == 1, "and the tip says who")
    s.pcs[4].map = "Map_Xigu"
    s:run(1)
    Session.die(s.pcs[3])
    s:run(1.5)
    check(count(h.logs, "player 3 %(gold%) is down") == 1, "a tip says who's down")
    Session.revive(s.pcs[3])
    s:run(1.5)
    check(count(h.logs, "player 3 %(gold%) is back") == 1, "and who's back")
    check(count(s.pcs[2].logs, "the host %(purple%) is down") == 0, "and the host isn't spoken of as a number")
    Session.moveTo(s.pcs[4], 30000, 0)
    s:run(1)
    check(count(s.pcs[1].logs, "player 4 %(blue%) is 300 m away") == 1, "and who's far off")

    h.mapOpen = true
    s:run(2)
    local pointers = 0
    for _, w in ipairs(h.mapWidgets or {}) do
        pointers = pointers + (field(w, "visibility") == 3 and 1 or 0)
    end
    check(pointers == 3, "the open map: a pointer for each (" .. pointers .. ")")
    local colours = {}
    for _, w in ipairs(h.mapWidgets) do
        colours[w] = field(w, "colour")
    end
    check(colours[h.mapWidgets[1]] ~= colours[h.mapWidgets[2]] and colours[h.mapWidgets[2]] ~= colours[h.mapWidgets[3]] and colours[h.mapWidgets[1]] ~= colours[h.mapWidgets[3]], "each in that player's own colour")
    s.pcs[4].map = "Map_Other"
    s:run(5)
    pointers = 0
    for _, w in ipairs(h.mapWidgets or {}) do
        pointers = pointers + (field(w, "visibility") == 3 and 1 or 0)
    end
    check(pointers == 2, "one elsewhere: theirs goes (" .. pointers .. ")")
    allErrors(s)
    h.mapOpen = false
    Session.command(h, "onlinepanel status")
    Session.command(s.pcs[3], "onlinepanel status")
    s:run(1)
    check(count(h.logs, "Players: 4 of 4%. You're the host %(purple%)%.") == 1, "the panel says how many are connected, and who you are")
    check(count(s.pcs[3].logs, "Players: 4 of 4%. You're player 3 %(gold%)%.") == 1, "on a guest's too")
    s.relay.otherVersions = "3:1.4.1,4:1.4.0"
    s:run(2)
    check(count(h.logs, "player 3 is on Phantom Pact 1%.4%.1 and you're on ") == 1 and count(h.logs, "player 4 is on Phantom Pact 1%.4%.0") == 1, "the host hears of each guest on another version")
    check(count(s.pcs[2].logs, "is on Phantom Pact") == 0, "not the guests, who compare with the host alone")
end

local function panel()
    part("the MORE row")
    local s = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES)
    s:run(2)
    local h = s.pcs[1]
    Session.command(h, "onlinepanel press 700 500")      -- MORE
    Session.command(h, "onlinepanel press 441 430")      -- the row's ON
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("FourPlayers = On\n", 1, true) ~= nil, "ON is kept in the ini")
    check(h.files["PhantomPact.ini"]:find("Role = Host\n", 1, true) ~= nil and h.files["PhantomPact.ini"]:find("CoopEnemyHealth = 150\n", 1, true) ~= nil, "and nothing else moves")
    Session.command(h, "onlinepanel press 305 430")      -- OFF
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("FourPlayers = Off\n", 1, true) ~= nil, "OFF too")
    Session.command(h, "onlinepanel press 305 100")      -- the TP row, moved up to fit
    Session.command(h, "onlinepanel press 441 100")
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("PartnerTeleport = On\n", 1, true) ~= nil, "the rows that moved up still answer where they're drawn")
    allErrors(s)
end

local function cost()
    part("what a frame costs (calls into the game)")
    local function measure(roles)
        local s = party({ { "a", THUG, 400.0, 0.0, 100.0, 60000, 100 }, { "b", THUG, 0.0, 400.0, 100.0, 60000, 100 }, { "c", THUG, -400.0, 0.0, 100.0, 60000, 100 },
            { "d", THUG, 0.0, -400.0, 100.0, 60000, 100 }, { "e", THUG, 800.0, 0.0, 100.0, 60000, 100 }, { "f", THUG, 0.0, 800.0, 100.0, 60000, 100 } }, nil, roles)
        for i, pc in ipairs(s.pcs) do
            Session.moveTo(pc, i * 150, 0)
        end
        s:run(5)
        local h, g = s.pcs[1], s.pcs[2]
        local t, before, beforeGuest = 0, h.calls, g.calls
        s:run(10, function()
            t = t + 1 / 60
            for i, pc in ipairs(s.pcs) do
                Session.moveTo(pc, math.cos(t + i) * 300, math.sin(t + i) * 300)
            end
        end)
        allErrors(s, "and no script error with " .. #roles .. " players")
        return (h.calls - before) / 600, (g.calls - beforeGuest) / 600
    end
    local h2, g2 = measure({ "Host", "Guest" })
    local h4, g4 = measure({ "Host", "Guest", "Guest", "Guest" })
    out(string.format("       a party of 2: host %.1f, guest %.1f calls a frame; of 4: host %.1f, guest %.1f", h2, g2, h4, g4))
    check(h4 < h2 * 3.2 and g4 < g2 * 3.2, "four players cost no more than three times two, per PC")
end

local function backToTwo()
    part("back to two")
    local s = party(nil, nil, { "Host", "Guest", "Guest" })
    spread({ pcs = { s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[3] } })
    s:run(3)
    local guest = s.pcs[2]
    check(net(guest).party == 4 and #guest.spawned == 2, "a guest in a party has two ghosts")
    s.relay.party = false
    s:run(3)
    check(net(guest).party == nil and net(guest).slot == nil, "a host with two players again: the guest hears it")
    check(net(guest).peerList == nil and rawget(guest.spawned[2], "__alive") == false, "the other guest's ghost goes")
    check(rawget(guest.spawned[1], "__alive") == true and net(guest).ghost == guest.spawned[1], "the host's stays")
    allErrors(s)
end

return function(print_, scripts)
    out = print_
    SIM_SCRIPTS = scripts
    joining()
    movesAndGear()
    sharing()
    enemiesAndHits()
    farEnemy()
    rests()
    sits()
    sitsForTwo()
    twoSaves()
    otherMaps()
    fightsAndWhoIsLeft()
    afterATrip()
    phantomEdge()
    shots()
    weaponsFound()
    noBodyYet()
    whatsLeftOfAPartner()
    offAndBack()
    localPlay()
    localScreen()
    elsewhere()
    travel()
    hatred()
    focus()
    aiming()
    holding()
    lateJoiner()
    lateJoinerGuestFight()
    scaling()
    leaving()
    sizeTips()
    lateHello()
    fogAfterLeaving()
    devUnits()
    modeRow()
    offThings()
    screens()
    panel()
    cost()
    backToTwo()
    return failed == 0
end
