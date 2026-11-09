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
    Session.startMove(s.pcs[3], "/PBZCombatAsset/ActorData/Move/A1.A1")
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
    Session.startMove(s.pcs[2], "/PBZCombatAsset/ActorData/Move/A2.A2")
    s:run(0.1)
    check(g.ghostBusy(ghostOf(s.pcs[1], 2)) and not g.ghostBusy(ghostOf(s.pcs[1], 3)), "one ghost's move doesn't stop the others being steered")
    Session.endMove(s.pcs[2])
    Session.hold(s.pcs[2], "/PBZCombatAsset/ActorData/Weapon/Spear.Spear", true)
    Session.hold(s.pcs[3], "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", true)
    s:run(1.5)
    local function holds(pc, slot)
        local c = field(field(ghostOf(pc, slot), "Character Weapons Component"), "config")
        return c and rawget(c, "__path")
    end
    check(holds(s.pcs[1], 2) == "/PBZCombatAsset/ActorData/Weapon/Spear.Spear" and holds(s.pcs[1], 3) == "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", "each ghost holds its own player's weapon")
    check(holds(s.pcs[4], 2) == "/PBZCombatAsset/ActorData/Weapon/Spear.Spear" and holds(s.pcs[4], 3) == "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", "on a guest's PC too")
    check(holds(s.pcs[1], 4) == nil, "and the one who changed nothing keeps theirs")
    Session.stagger(s.pcs[4], "CharacterState.Hitreact.State.Normal.Heavy")
    s:run(0.5)
    check(field(field(ghostOf(s.pcs[2], 4), "hit"), "state") == "CharacterState.Hitreact.State.Normal.Heavy", "a stagger shows on the right ghost")
    check(field(field(ghostOf(s.pcs[2], 3), "hit"), "state") == "None", "and no other")
    -- As main.dll hands a move over: with how long ago the partner's game read it in front. It starts that far in.
    local inbox, before = s.pcs[1].inbox, played(s.pcs[1], 3)
    inbox[#inbox + 1] = "~45 @3 U /PBZCombatAsset/ActorData/Move/A1.A1 0.25"
    s:run(0.1)
    local start = field(field(ghostOf(s.pcs[1], 3), "anim"), "start")
    check(played(s.pcs[1], 3) == before + 1 and start and math.abs(start - 0.295) < 1e-6,
        "a move that comes 45 ms old starts 45 ms further in (at " .. tostring(start) .. ")")
    -- The player's own place goes out first in a frame: whatever the partner's events cost this frame comes after it.
    local h1, order = s.pcs[1], {}
    local api = h1.env.PBZ
    local state, playMove = api.link.state, api.coop.handlers.U
    api.link.state = function(...)
        order[#order + 1] = { "state", h1.now }
        return state(...)
    end
    api.coop.handlers.U = function(...)
        order[#order + 1] = { "move", h1.now }
        return playMove(...)
    end
    h1.inbox[#h1.inbox + 1] = "~10 @3 U /PBZCombatAsset/ActorData/Move/A1.A1 0.25"
    s:run(0.05)
    api.link.state, api.coop.handlers.U = state, playMove
    local first = nil
    for i, e in ipairs(order) do
        if e[1] == "move" then
            for j = 1, i - 1 do
                if order[j][1] == "state" and order[j][2] == e[2] then
                    first = true
                end
            end
            first = first or false
        end
    end
    check(first == true, "the player's own place goes out before the partner's events are handled, in the same frame")
    -- A player's health goes with their place, every frame: a hit shows on the others' screens in the frames after it, not
    -- on the next of ten slow reads a second. Five tries, each at another moment of those reads.
    local seenBy, onTime = s.pcs[2].env.PBZ.net, true
    for k = 1, 5 do
        local hp = 500 - k * 37
        Fake.setHealth(h1.pawn, hp)
        s:run(4 / 60)
        onTime = onTime and seenBy.target ~= nil and math.abs((seenBy.target.Hp or -1) - hp) < 0.5
        s:run(k / 60)
    end
    check(onTime, "a hit on the host shows in their health on a guest's PC within four frames, every time")
    -- How a player moves and their guard stance go in bits of that place too: in step with it, and no sure event to resend.
    local gaitOf, inStance, sentBefore = api.game.gait, api.game.inStance, #h1.sent
    api.game.gait = function() return "s" end
    api.game.inStance = function() return true end
    Session.startMove(h1, "/PBZCombatAsset/ActorData/Move/StanceEnter_A.StanceEnter_A")
    s:run(0.3)
    local onWay = seenBy.gait == "s" and seenBy.stance == true
    api.game.gait = function() return "w" end
    api.game.inStance = function() return false end
    s:run(0.3)
    local offWay = seenBy.gait == "w" and seenBy.stance == false
    api.game.gait, api.game.inStance = gaitOf, inStance
    Session.endMove(h1)
    local told = 0
    for k = sentBefore + 1, #h1.sent do
        if h1.sent[k]:find("^%S+ GAIT ") or h1.sent[k]:find("^%S+ ST ") then
            told = told + 1
        end
    end
    check(onWay and offWay and told == 0, "the host's sprint and guard stance reach a guest with their place, and back, without one sure event (" .. told .. ")")
    -- A stagger comes with how long ago it began: the ghost's copy ends when theirs does, and one over by now isn't played.
    local function hitOnHost(pc)
        return field(field(ghostOf(pc, 1), "hit"), "state")
    end
    local g2 = s.pcs[2]
    g2.inbox[#g2.inbox + 1] = "~500 H CharacterState.Hitreact.State.Normal"
    s:run(2 / 60)
    local shown = hitOnHost(g2) == "CharacterState.Hitreact.State.Normal"
    s:run(0.45)
    local ended = hitOnHost(g2) == "None"
    g2.inbox[#g2.inbox + 1] = "~950 H CharacterState.Hitreact.State.Normal"
    s:run(2 / 60)
    check(shown and ended and hitOnHost(g2) == "None",
        "a stagger 0.5 s old is held for the 0.4 s left of it, one older than that not at all")
    -- A move and a stagger go out in the frame they start, every time: a move went every other frame, a stagger ten times
    -- a second, and the ghost skipped that much more of the move, or reacted that much later.
    local function sentNow(from, pattern)
        for i = from + 1, #h1.sent do
            if h1.sent[i]:find(pattern) then
                return 1
            end
        end
        return 0
    end
    local movesNow, hitsNow = 0, 0
    for k = 1, 5 do
        local from = #h1.sent
        Session.startMove(h1, "/PBZCombatAsset/ActorData/Move/B" .. k .. ".B" .. k)
        Session.stagger(h1, k % 2 == 0 and "CharacterState.Hitreact.State.Normal" or "CharacterState.Hitreact.State.Normal.Heavy")
        s:run(1 / 60)
        movesNow, hitsNow = movesNow + sentNow(from, "^Q U /"), hitsNow + sentNow(from, "^Q H ")
        s:run(0.2)
        Session.endMove(h1)
        Session.stagger(h1, "None")
        s:run(k / 60)
    end
    check(movesNow == 5 and hitsNow == 5, "a move and a stagger go out in the frame they start (" .. movesNow .. " and " .. hitsNow .. " of 5)")
    -- A move's end lost on the way ("U - 0", all three quick copies in a burst): it still ends on the others' screens, once
    -- the player's place says they're in no move. (It played on: a looping one for good.)
    local quick = api.link.quick
    api.link.quick = function(line)
        if not line:find("^U %- ") then
            return quick(line)
        end
    end
    s:run(0.3)
    Session.startMove(h1, "/PBZCombatAsset/ActorData/Move/Loop1.Loop1")
    s:run(0.5)
    local function onGuest()
        return field(field(ghostOf(s.pcs[2], 1), "anim"), "montage")
    end
    local playing = onGuest() ~= nil
    Session.endMove(h1)
    s:run(0.6)
    api.link.quick = quick
    check(playing and onGuest() == nil, "a move whose end is lost on the way still ends on the others' screens, in 0.6 s")
    allErrors(s)
end

local function sharing()
    part("everything anyone gets")
    local s = party()
    spread(s)
    s:run(2)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    Session.gainItem(h, "R_1", 1)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
    check(Session.items(a, "R_1") == 1 and Session.items(b, "R_1") == 1 and Session.items(c, "R_1") == 1 and Session.items(h, "R_1") == 1, "what the host gets, every guest gets, once")
    Session.gainItem(b, "R_2", 2)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
    check(Session.items(h, "R_2") == 2 and Session.items(a, "R_2") == 2 and Session.items(c, "R_2") == 2 and Session.items(b, "R_2") == 2, "what a guest gets, the host and the others get, once")
    Session.gainItem(a, "R_3", 1)
    Session.gainItem(b, "R_3", 1)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
    check(Session.items(a, "R_3") == 1 and Session.items(b, "R_3") == 1, "the same thing given to two players in a moment stays one each")
    check(Session.items(h, "R_3") == 1 and Session.items(c, "R_3") == 1, "and it's one for those who weren't there, not two")
    Session.gainItem(a, "R_5", 1)
    Session.gainItem(b, "R_5", 1)
    Session.gainItem(c, "R_5", 1)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
    check(Session.items(h, "R_5") == 1 and Session.items(a, "R_5") == 1 and Session.items(b, "R_5") == 1 and Session.items(c, "R_5") == 1, "from three senders at once, one each too")
    s:run(16)
    Session.gainItem(a, "R_5", 1)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
    check(Session.items(h, "R_5") == 2 and Session.items(b, "R_5") == 2, "and after the 15 s the same thing counts again")
    Session.gainItem(a, "R_4", 1)
    s:run(0.5)
    Session.gainItem(a, "R_4", 1)
    s:run(3.5)                  -- (a share waits 3 s for this world's own gift: takeGifts)
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
    local swung = true
    for _, pc in ipairs({ h, b, c }) do
        local lid, glow = field(pc.chests[1], "Chest"), field(pc.chests[1], "Niagara")
        swung = swung and field(lid, "anim") == pc.found["/HuaShira/SceneProp/Chest/Anim/Chest_Close2Open.Chest_Close2Open"]
            and field(lid, "at") > 1 and field(lid, "VisibilityBasedAnimTickOption") == 0 and field(glow, "on") == false
            and field(pc.chests[1], "swept") == false
    end
    check(swung and field(field(a.chests[1], "Chest"), "anim") == nil,
        "and looks open there: its lid swings open, its glow and sweeping light go (the opener's is left to the game)")
    Session.moveTo(b, 300, 0)
    s:run(1.5)
    b.pickups[1]:K2_DestroyActor()
    s:run(1.5)
    local gone = true
    for _, pc in ipairs({ h, a, c }) do
        gone = gone and not rawget(pc.pickups[1], "__alive")
    end
    check(gone, "a pickup one guest takes goes from every world")
    -- A quest item (a key, a letter, a stone): shared now, like any find (a player report, 11-06: with the host's story steps
    -- reaching everyone, the partner's copy vanished with nothing given). Its pickup goes from every world, and the item, as the
    -- game gives it, comes to everyone with its card.
    for _, pc in ipairs({ h, a, b, c }) do
        Fake.pickup(pc, "keyspot", "I_KEY_9", 310.0, 0.0, 100.0)
        -- (What went in with its card, and what quietly: "<id> <push>".)
        pc.pushes = {}
        local add = rawget(rawget(pc.bag, "__fields"), "AddPropsToBackPack")
        Fake.put(pc.bag, "AddPropsToBackPack", function(self, n, id, push)
            pc.pushes[#pc.pushes + 1] = (id.ToString and id:ToString() or tostring(id)) .. " " .. tostring(push)
            return add(self, n, id, push)
        end)
    end
    s:run(1.5)
    b.pickups[#b.pickups]:K2_DestroyActor()
    Session.gainItem(b, "I_KEY_9")
    s:run(3.5)
    local shared, carded = true, true
    for _, pc in ipairs({ h, a, c }) do
        shared = shared and rawget(pc.pickups[#pc.pickups], "__alive") == false and Session.items(pc, "I_KEY_9") == 1
        carded = carded and count(pc.pushes, "^I_KEY_9 true$") == 1
    end
    check(count(b.sent, "^E I keyspot") == 1 and shared, "a quest item one player takes goes from the others' worlds, and they get it too")
    check(carded, "with its card, as the one who picked it up saw")
    Session.gainItem(b, "Item_Herb", 1)
    s:run(3.5)
    Session.gainItem(b, "Item_Herb", 1)
    s:run(3.5)
    -- (11-09: both with the game's notice on the right, the line; a thing new to them held a moment first, quietly, so
    -- it's the line and not the full-screen card. Here the key's card waits for the game's own moment, the lines with it.)
    check(count(h.pushes, "^Item_Herb true$") == 2 and count(h.pushes, "^Item_Herb false$") == 1,
        "what the partner finds comes with the game's notice, a thing new to them too, held a moment first for its line")
    -- Issue #15: one whose item can't be read (the Snake Tongue, a token half) went out as loot, and the others' copy vanished
    -- with nothing given, their quest stuck. Only what's known to be loot goes.
    for _, pc in ipairs({ h, a, b, c }) do
        local p = Fake.pickup(pc, "tonguespot", "R_500", 320.0, 0.0, 100.0)
        rawset(rawget(p, "__fields"), "ItemId", nil)
    end
    s:run(1.5)
    b.pickups[#b.pickups]:K2_DestroyActor()
    s:run(1.5)
    kept = true
    for _, pc in ipairs({ h, a, c }) do
        kept = kept and rawget(pc.pickups[#pc.pickups], "__alive") ~= false
    end
    check(kept and count(b.sent, "^E I tonguespot") == 0, "a pickup whose item can't be read stays in the others' worlds too")
    -- A respawn, a bell trip or F3 on the same map: a pickup the player stood by went out of reach with the jump and was told
    -- as taken, the others' copy gone and nobody with the thing (the review of the item reports, 1.6.6).
    for _, pc in ipairs({ h, a, b, c }) do
        Fake.pickup(pc, "jumpspot", "R_500", 340.0, 0.0, 100.0)
    end
    s:run(1.5)
    Session.moveTo(b, 40000, 0)
    s:run(1.5)
    Session.moveTo(b, 300, 0)
    s:run(1.5)
    kept = true
    for _, pc in ipairs({ h, a, c }) do
        kept = kept and rawget(pc.pickups[#pc.pickups], "__alive") ~= false
    end
    check(kept and count(b.sent, "^E I jumpspot") == 0, "a pickup left behind by a jump isn't told as taken: the others keep theirs")
    -- Issue #15 as it was: a pile with a story item in it (the Snake Tongue, a token half) opened by one player was taken
    -- from the other's world, the item with it, never shared. Shared now, it goes as any pile does: its item comes by the gift.
    -- With the old rule (game.shareQuestItems = false) it stays, for this player to open.
    local qpile = Fake.switch(h, "BP_Rubbish_C", 330.0, 0.0, 100.0)
    rawset(qpile, "K2_DestroyActor", function(self) rawset(self, "__alive", false) end)
    rawset(rawget(qpile, "__fields"), "Loot Item ID", Fake.name("Houjie.I_KEY_9"))
    h.env.PBZ.game.shareQuestItems = false
    h.env.PBZ.game.partnerOpened("BP_Rubbish_C")
    check(rawget(qpile, "__alive") ~= false, "the old rule: a pile holding a quest item another player opened stays")
    h.env.PBZ.game.shareQuestItems = true
    h.env.PBZ.game.partnerOpened("BP_Rubbish_C")
    check(rawget(qpile, "__alive") == false, "shared: it goes as one of loot does")

    -- Iron chains one player breaks (a Phantom Edge out of a fight) are broken in the others' worlds too.
    for _, pc in ipairs({ h, a, b, c }) do
        Fake.blocker(pc, "BP_GameplayBlocker_Chain_C_UAID_1", 320.0, 0.0, 100.0)
    end
    s:run(1.5)
    Fake.put(b.blockers[1], "bBroken", true)
    s:run(1.5)
    check(field(h.blockers[1], "bBroken") == true and field(a.blockers[1], "bBroken") == true
        and field(c.blockers[1], "bBroken") == true and count(b.sent, "^E BLK BP_GameplayBlocker_Chain_C_UAID_1$") == 1,
        "chains one player breaks are broken in every world")
    -- A lever (a gate) one player opens is open in the others' worlds too; a chest isn't touched by it.
    local levers = {}
    for _, pc in ipairs({ h, a, b, c }) do
        local lv = Fake.switch(pc, "ABP_Switch_C", 330.0, 0.0, 100.0)
        Fake.put(lv, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "CurSwitchState", true) end)
        levers[pc] = lv
    end
    s:run(1.5)
    Fake.put(levers[b], "CurSwitchState", true)
    s:run(1.5)
    check(field(levers[h], "CurSwitchState") == true and field(levers[a], "CurSwitchState") == true
        and field(levers[c], "CurSwitchState") == true and count(b.sent, "^E SWO ABP_Switch_C$") == 1,
        "a lever one player pulls opens in every world")

    -- Story sync off: nothing comes from the host's bag on joining either.
    local so = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "FollowHostStory = Off\n")
    Session.gainItem(so.pcs[1], "R_500", 3)
    so:run(12)
    check(Session.items(so.pcs[2], "R_500") == 0 and count(so.pcs[2].logs, "Story sync is off: nothing taken") >= 1,
        "story sync off: the guest takes nothing from the host's bag")
    allErrors(so)

    -- The NPCs who fight beside the players (NpcHelper) aren't enemies: each world keeps its own, free to talk to.
    local hlist = { { "ally", "BP_Monster_SpearMan_Spear_NpcHelper_XiGu_01_C", 600.0, 0.0, 100.0, 600, 100 },
        { "foe", THUG, 700.0, 0.0, 100.0, 600, 100 } }
    local hs = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, hlist)
    for _, pc in ipairs(hs.pcs) do
        local cls = Fake.object(pc, "Class")
        rawset(cls, "__name", "BP_Monster_SpearMan_Spear_NpcHelper_XiGu_01_C")
        rawset(Session.enemyOn(pc, "ally"), "__classObject", cls)
    end
    hs:run(4)
    Session.moveTo(hs.pcs[1], 0, 0)
    Session.moveTo(hs.pcs[2], 300, 0)
    hs:run(3)
    local ae = Session.enemyOn(hs.pcs[1], "ally")
    check(net(hs.pcs[2]).remoteEnemies["sp:foe"] ~= nil and net(hs.pcs[2]).remoteEnemies["sp:ally"] == nil,
        "the NPCs fighting beside the players aren't shared as enemies")
    allErrors(hs)
    local opened = Fake.chest(b, "BP_Chest_C_2", 300.0, 200.0, 100.0)
    s:run(1.5)
    Fake.put(opened, "CurSwitchState", true)
    s:run(1.5)
    local late = Fake.chest(c, "BP_Chest_C_2", 300.0, 200.0, 100.0)
    s:run(1.5)
    check(field(late, "CurSwitchState") == true and field(field(late, "Chest"), "anim") == c.found["/HuaShira/SceneProp/Chest/Anim/Chest_Open.Chest_Open"]
        and field(field(late, "Niagara"), "on") == false and field(late, "swept") == false,
        "a chest that wasn't loaded yet is open when it loads, lid and all")
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
    local copy = Session.enemyOn(a, "near")
    check(field(copy, "realDeath") == true, "a guest's copy of it dies by the game's own death (what a quest waits for hears it)")
    check(field(field(copy, "hpbar"), "shown") == false, "and its health bar goes with it (none left floating there)")
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
    check(field(copy, "dead") == true, "and stays dead (no standing there frozen)")
    -- A guest restarts its sync: it's told of the deaths alone.
    local before = count(a.logs, "Host says .* died; ")
    Session.command(b, "netoff")
    s:run(1)
    Session.command(b, "neton client")
    s:run(2)
    check(count(h.sent, "^T3 K sp:near$") == 1, "a guest who restarts hears what's dead, by itself")
    check(count(a.logs, "Host says .* died; ") == before, "and the others aren't told again")
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

-- Two players apart: the host's game keeps what's by the guest asleep, so an enemy clearly nearer the guest is the guest's
-- game's to run, and the host's copy follows the guest's. Together again, it's the host's.
local function guestRunsWhatsNearIt()
    part("enemies by a guest some way off")
    local list = {
        { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 },
        { "between", THUG, 5500.0, 0.0, 100.0, 600, 100 },
        { "bossthere", "BP_Monster_Boss_C", 11200.0, 700.0, 100.0, 5000, 400, true },
        { "byhost", THUG, 300.0, 0.0, 100.0, 600, 100 },
        { "chasing", THUG, 2600.0, 0.0, 100.0, 600, 100 },
        { "faraway", THUG, 40000.0, 0.0, 100.0, 600, 100 },
    }
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local h, g = s.pcs[1], s.pcs[2]
    local function brain(e)
        return field(field(field(e, "Controller"), "BrainComponent"), "running")
    end
    -- What's sent from the given point on.
    local function since(pc, from, pattern)
        local n = 0
        for i = from + 1, #pc.sent do
            if pc.sent[i]:find(pattern) then
                n = n + 1
            end
        end
        return n
    end
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 11000, 0)        -- 110 m off: the host still runs what's near the guest
    s:run(3)
    local onH, onG = Session.enemyOn(h, "byguest"), Session.enemyOn(g, "byguest")
    check(count(h.sent, "^E RUN sp:byguest 1$") == 1, "two players apart: an enemy clearly nearer the guest goes to the guest's game, once")
    check(net(g).mine["sp:byguest"] == true and brain(onG) == true, "where it has its own AI back")
    check(brain(onH) == false and count(g.sent, "^N ") > 0, "and the host's copy follows the guest's lines")
    check(count(h.sent, "^E RUN sp:between ") == 0 and count(h.sent, "^E RUN sp:bossthere ") == 0
        and count(h.sent, "^E RUN sp:byhost ") == 0 and count(h.sent, "^E RUN sp:chasing ") == 0,
        "not one as near the host, nor a boss, nor one by the host or far from both")
    Fake.put(onG, "loc", { X = 13000.0, Y = 800.0, Z = 100.0 })
    s:run(2)
    check(gap(at(onH), at(onG)) < 200, "the host's copy goes where the guest's goes")
    local left = select(1, Fake.health(onG))
    swing(g, onG, left - 60)
    s:run(1)
    check(count(g.sent, "^E D sp:byguest ") == 0, "the guest's hit isn't reported: it's that game's enemy")
    check(select(1, Fake.health(onH)) == left - 60, "the host's copy follows the guest's health")
    Session.moveTo(h, 12000, 2500)     -- near, and still apart
    s:run(1)
    swing(h, onH, select(1, Fake.health(onH)) - 40)
    s:run(1)
    check(count(h.sent, "^E D sp:byguest ") == 1, "the host's hit on it goes to the guest's game")
    check(select(1, Fake.health(onG)) == left - 100, "and lands there")
    s:run(1)
    check(select(1, Fake.health(onG)) == left - 100 and select(1, Fake.health(onH)) == left - 100, "once, on both")
    Session.moveTo(g, 12500, 2400)     -- together
    Fake.put(onG, "loc", { X = 12800.0, Y = 1500.0, Z = 100.0 })
    s:run(2)
    check(count(h.sent, "^E RUN sp:byguest 0$") == 1 and net(g).mine["sp:byguest"] == nil, "together again: the host's game runs it")
    check(brain(onH) == true and brain(onG) == false, "its AI back on the host, the guest's copy following the host's again")
    check(gap(at(onH), at(onG)) < 200, "from where it stood, with no jump")
    check(select(1, Fake.health(onH)) == select(1, Fake.health(onG)), "and with what it had left in the guest's game")
    Session.moveTo(h, 3000, 2500)      -- apart again
    s:run(3)
    check(count(h.sent, "^E RUN sp:byguest 1$") == 2, "apart again: the guest's game runs it again")
    local dust = Session.dust(h)
    swing(g, onG, 0)
    Fake.put(onG, "dead", true)
    s:run(2)
    check(count(g.sent, "^E GK sp:byguest$") == 1, "the guest's game kills it, and says so")
    check(field(onH, "dead") == true and field(onH, "realDeath") == true, "the host's copy dies by the game's own death")
    check(Session.dust(h) == dust, "and pays nobody twice")
    -- One fighting the host stays the host's, however near the guest.
    local chasing = Session.enemyOn(h, "chasing")
    Fake.put(field(chasing, "picker"), "SwitchTargetCooldown", 1e9)
    Fake.put(chasing, "target", h.pawn)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 3300, 0)
    local mark = #h.sent
    s:run(2)
    check(since(h, mark, "^E RUN sp:chasing ") == 0 and net(h).guestRuns["sp:chasing"] == nil,
        "one after the host stays the host's, though the guest is nearer")
    Fake.put(chasing, "target", nil)
    s:run(1)
    check(since(h, mark, "^E RUN sp:chasing 1$") == 1, "and goes once it's after nobody")
    -- Past the host's reach the guest's world has its own, as ever: its kill is the host's too.
    Session.moveTo(g, 39500, 0)
    s:run(3)
    local far = Session.enemyOn(g, "faraway")
    swing(g, far, select(1, Fake.health(far)) - 50)
    s:run(1)
    swing(g, far, 0)
    Fake.put(far, "dead", true)
    s:run(1)
    check(count(g.sent, "^E GK sp:faraway$") == 1, "two players: a guest's kill past the host's reach is told")
    Session.moveTo(h, 39000, 300)
    s:run(2)
    check(field(Session.enemyOn(h, "faraway"), "dead") == true, "and it's dead in the host's world once the host is near")
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

    -- The host fights a boss; a guest elsewhere rests at a bell. The others' copy of the host's fight goes on.
    local f = party()
    spread(f)
    f:run(2)
    f.pcs[1].hudLayout:RegisterBossHPBar(Session.enemyOn(f.pcs[1], "boss"))     -- (bossStart, defined further down)
    f:run(5)
    local fa = f.pcs[2]
    check(next(fa.env.PBZ.net.partnerBosses) ~= nil, "a guest mirrors the host's boss fight")
    Session.bell(f.pcs[3])
    f:run(2)
    check(next(fa.env.PBZ.net.partnerBosses) ~= nil, "and another guest's bell rest doesn't end it there")
    check(next(f.pcs[1].env.PBZ.net.partnerBosses) == nil and f.pcs[1].env.PBZ.game.bossFightActive(),
        "nor the host's own")
    allErrors(f)

    -- The same, one guest further: the host's world didn't refresh for that rest (its own fight), so neither does the
    -- other guests' world, and what the host killed stays killed there.
    local fh, fc = f.pcs[1], f.pcs[4]
    fc.env.PBZ.net.hostKilled["sp:killedthere"] = true
    local fcBefore = refreshes(fc)
    Session.bell(f.pcs[3])
    f:run(2)
    check(fc.env.PBZ.net.hostKilled["sp:killedthere"] == true and refreshes(fc) == fcBefore,
        "a guest's rest the host's world didn't refresh for: the other guests keep the host's kills, and don't refresh")
    -- A guest's own bell rest during the host's fight: that fight is still shown after it.
    Session.bell(fa)
    f:run(2)
    check(next(fa.env.PBZ.net.partnerBosses) ~= nil or next(fa.env.PBZ.net.pendingBosses) ~= nil,
        "a guest who rests at a bell during the host's fight still has it after")
    allErrors(f)

    -- A guest fights a boss of its own; a third player rests at a bell. The host's world isn't refreshed under that fight.
    local q = party()
    spread(q)
    q:run(2)
    local qa = q.pcs[2]
    qa.hudLayout:RegisterBossHPBar(Session.enemyOn(qa, "boss"))
    q:run(5)
    local qBefore = refreshes(q.pcs[1])
    Session.bell(q.pcs[3])
    q:run(2)
    check(refreshes(q.pcs[1]) == qBefore and qa.env.PBZ.game.bossFightActive(),
        "a third player's bell rest doesn't refresh the host's world under a guest's boss fight")
    allErrors(q)

    -- The host rests at a bell while a guest fights a boss of its own: that fight stays shown everywhere, and its bar and
    -- walls go once it's over (wiped with the host's own, the third player's bar stayed up for good).
    local hr = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    local hh, h2, h3 = hr.pcs[1], hr.pcs[2], hr.pcs[3]
    for _, pc in ipairs(hr.pcs) do
        pc.reviveOnRest = true
    end
    Session.moveTo(h2, 400, 0)
    Session.moveTo(h3, 600, 0)
    hr:run(8)
    local hboss = Session.enemyOn(h2, "boss")
    Session.moveTo(h2, 2800, 3000)
    h2.hudLayout:RegisterBossHPBar(hboss)
    hr:run(5)
    Session.bell(hh)
    hr:run(5)
    check(h3.env.PBZ.game.bossFightActive() and hh.env.PBZ.game.bossFightActive(),
        "the host rests during a guest's boss fight: that fight is still shown on the others")
    h2.hudLayout:UnRegisterBossHPBar(hboss)
    hr:run(15)
    check(not h3.env.PBZ.game.bossFightActive() and not hh.env.PBZ.game.bossFightActive()
        and next(h3.env.PBZ.net.foggedBosses or {}) == nil, "and once it's over, no bar or walls are left anywhere")
    allErrors(hr)

    -- A guest who walked into the host's fight and died can walk in again.
    local j = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    j:run(4)
    local jg = j.pcs[2]
    jg.env.PBZ.net.joinedBoss = "sp:boss"
    Session.die(jg)
    j:run(1)
    Session.respawned(jg)
    Session.revive(jg)
    j:run(1)
    check(jg.env.PBZ.net.joinedBoss == nil, "a guest who joined a fight and died isn't still marked as in it")
    allErrors(j)

    -- A guest's kill in a party: its items go to that guest, not to every guest.
    local l = party()
    spread(l)
    l:run(3)
    local lh, la = l.pcs[1], l.pcs[2]
    lh.env.PBZ.game.rollLoot = function() return 0, { { id = "R_7", count = 1, kind = "-" } }, 1 end
    lh.env.PBZ.game.applyDamage = function(actor) Fake.setHealth(actor, 0) Fake.put(actor, "dead", true) return false end
    local onA = Session.enemyOn(la, "near")
    swing(la, onA, select(1, Fake.health(onA)) - 50)
    l:run(1)
    swing(la, onA, 1)
    l:run(2)
    check(count(lh.sent, "^T2 I loot:sp:near R_7") == 1 and count(lh.sent, "^E I loot:") == 0,
        "a guest's kill in a party: its items go to that guest alone")
    allErrors(l)

    -- A guest's boss fight is on; another guest starts sync again: it's shown that fight.
    local n = party()
    spread(n)
    n:run(2)
    local na, nc = n.pcs[2], n.pcs[4]
    na.hudLayout:RegisterBossHPBar(Session.enemyOn(na, "boss"))
    n:run(4)
    Session.command(nc, "netoff")
    n:run(1)
    check(next(net(nc).partnerBosses) == nil, "(gone: shown no more)")
    Session.command(nc, "neton client")
    n:run(8)
    check(next(net(nc).partnerBosses) ~= nil or next(net(nc).pendingBosses) ~= nil,
        "a guest's fight that's on is shown to another guest who starts sync again")
    allErrors(n)

    -- The host's word only: the same events from another guest, passed on by the relay, do nothing.
    local o = party()
    local og = o.pcs[3]
    local oh = og.env.PBZ.coop.handlers
    local beatenLogs = count(og.logs, "The host has beaten")
    oh.OC("BP_Chest_C_1", 2)
    oh.BEATEN("sp:boss", 2)
    oh.NOT("sp:thug1", 2)
    o:run(1)
    check(net(og).chestsSoon ~= true and count(og.logs, "The host has beaten") == beatenLogs
        and net(og).notOnHost["sp:thug1"] == nil, "host-only events from another guest are ignored")
    oh.BEATEN("sp:boss")
    o:run(1)
    check(count(og.logs, "The host has beaten") == beatenLogs + 1, "and the host's own still count")
    allErrors(o)

    -- Two players: the host in a boss fight of its own, the guest far off on the same map rests at a bell.
    local w = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local wh, wg = w.pcs[1], w.pcs[2]
    Session.moveTo(wg, 30000, 0)
    w:run(3)
    wh.hudLayout:RegisterBossHPBar(Session.enemyOn(wh, "boss"))
    w:run(3)
    local before = refreshes(wh)
    Session.bell(wg)
    w:run(2)
    check(wh.env.PBZ.game.bossFightActive() and refreshes(wh) == before,
        "two players: the guest's bell rest leaves the host's own boss fight be, bar and enemies")
    -- The guest sits at a bell during it: the host is rested, and so is the boss (the user's rule).
    local wboss = Session.enemyOn(wh, "boss")
    local _, bossMax = Fake.health(wboss)
    Fake.setHealth(wboss, bossMax * 0.3)
    Fake.setHealth(wh.pawn, 100)
    Session.sit(wg)
    w:run(2)
    check(Fake.health(wh.pawn) == 1000 and Fake.health(wboss) == bossMax,
        "the guest sits during the host's boss fight: the host is rested, and the boss is back to full")
    allErrors(w)

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

    -- One player alone hits it: after the hold it turns to them, and to nobody else. (Hits that each take 1% of its health:
    -- one that takes a thousandth of a percent isn't "the most damage", and the player beside it keeps it.)
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
    local hit = select(2, Fake.health(ring)) / 100
    for i = 1, 20 do
        local copy = Session.enemyOn(s2.pcs[hitter], "ring")
        swing(s2.pcs[hitter], copy, select(1, Fake.health(copy)) - hit)
        s2:run(1)
    end
    check(field(ring, "target") == ghostOf(h2, hitter), "the player who kept hitting it gets its attention after the hold")
    local hatredList = rawget(field(ring, "BP_PBZHatredManagerComponent"), "__fields").HatredList.items
    check(#hatredList >= 4, "and the others are back on its list after the turn")
    allErrors(s)
    allErrors(s2)
end

-- Who an enemy goes for, by how near each player is and how much of its health they took lately: never by the clock, never
-- back and forth (a player's report: "switching the lock every 15 s is worse than deciding by distance and by who deals the
-- most damage"). One enemy that lives through it all; the host's enemy notices the host, as the game's own do.
local function targetSession(n, boss)
    local roles = { "Host" }
    for i = 2, n do
        roles[i] = "Guest"
    end
    local ring = boss and { "ring", "BP_Monster_Boss_C", 0.0, 0.0, 100.0, 600000, 400, true }
        or { "ring", THUG, 0.0, 0.0, 100.0, 600000, 100 }
    local s = Session.new(SIM_SCRIPTS, roles, n > 2 and (n == 4 or n), { ring }, n == 6 and "GhostTwins = Off\n" or nil)
    s.pcs[1].perceive = true
    s:run(4)
    return s
end

-- Everyone `r` cm from it, evenly round it, going round at `speed` radians a second if given.
local function aroundIt(r, speed)
    return function(s, t)
        for i, pc in ipairs(s.pcs) do
            local a = (speed or 0) * t + i * 2 * math.pi / #s.pcs
            Session.moveTo(pc, math.cos(a) * r, math.sin(a) * r)
        end
    end
end

-- The hits fn(t, on) asks for ({ [slot] = damage }), each player's no more often than every `period` seconds.
local function hitsEvery(period, fn)
    local due = {}
    return function(t, on)
        local now = {}
        for slot, dmg in pairs(fn(t, on)) do
            if dmg > 0 and t + 1e-6 >= (due[slot] or 0) then
                now[slot], due[slot] = dmg, t + period
            end
        end
        return now
    end
end

-- A player's figure on the host's PC. (With two players there's no party: the guest's is net's own.)
local function figureOn(h, slot)
    return ghostOf(h, slot) or (slot == 2 and net(h).ghost) or nil
end

-- A fight, a tenth of a second at a time: place(s, t, on) puts everyone, hits(t, on) says who hits now, for how much in
-- 5000ths of its health (a hit of 20 is 0.4%, a boss's numbers; a thug's are 5 to 10 times that). It's healed every 10 s so
-- it lives. on: the slot it's after (0: nobody). Returns its changes of target as "<second>:<slot>", and the slot it ends on.
local function targetFight(s, seconds, place, hits)
    local h = s.pcs[1]
    local e = Session.enemyOn(h, "ring")
    local function slotOf()
        local t = field(e, "target")
        if t ~= nil and t == h.pawn then
            return 1
        end
        for slot = 2, #s.pcs do
            if t ~= nil and t == figureOn(h, slot) then
                return slot
            end
        end
        return 0
    end
    place(s, 0, slotOf())
    s:run(6)
    local maxhp = select(2, Fake.health(e))
    local changes, on, t = {}, slotOf(), 0
    while t < seconds - 1e-6 do
        place(s, t, on)
        if t > 0 and math.floor(t * 10 + 0.5) % 100 == 0 then
            Fake.setHealth(e, maxhp)
        end
        for slot, dmg in pairs(hits(t, on)) do
            local copy = slot == 1 and e or Session.enemyOn(s.pcs[slot], "ring")
            swing(s.pcs[slot], copy, select(1, Fake.health(copy)) - dmg * maxhp / 5000)
        end
        s:run(0.1)
        t = t + 0.1
        local now = slotOf()
        if now ~= on then
            changes[#changes + 1] = string.format("%.1f:%d", t, now)
            on = now
        end
    end
    return changes, on
end

-- The shortest time between two changes of target, in seconds (a big number with fewer than two).
local function shortestHold(changes)
    local shortest, last = 1e9, nil
    for _, c in ipairs(changes) do
        local at = tonumber(c:match("^([%d%.]+):"))
        if last then
            shortest = math.min(shortest, at - last)
        end
        last = at
    end
    return shortest
end

local function targets()
    part("who an enemy goes for, two players")
    -- Taking turns at it, 3 s each, the same damage: nothing to choose between.
    local s = targetSession(2)
    local changes = targetFight(s, 60, aroundIt(250), hitsEvery(0.5, function(t)
        return { [math.floor(t / 3) % 2 + 1] = 30 }
    end))
    check(#changes <= 1, "two players taking turns at it, the same damage: " .. #changes .. " changes in a minute, not one every 15 s ("
        .. table.concat(changes, " ") .. ")")
    allErrors(s)

    -- The guest deals the damage from 6 m, the host only chips from 1 m: it goes for the guest, and the game's own picker,
    -- which wants the nearest, never takes it back.
    s = targetSession(2)
    local on
    changes, on = targetFight(s, 60, function(s)
        Session.moveTo(s.pcs[1], 100, 0)
        Session.moveTo(s.pcs[2], -600, 0)
    end, hitsEvery(0.5, function(t)
        return { [2] = 30, [1] = math.floor(t * 2) % 8 == 0 and 3 or 0 }
    end))
    check(on == 2 and #changes <= 1, "the guest deals the damage from 6 m, the host chips from 1 m: it's on the guest, and stays ("
        .. table.concat(changes, " ") .. ")")
    allErrors(s)

    -- Who it's after walks off to 22 m (in reach still), nobody hitting: it turns to the one still beside it, at once.
    s = targetSession(2)
    local walker, leftAt = nil, nil
    changes, on = targetFight(s, 20, function(s, t, now)
        if t >= 10 and walker == nil and now ~= 0 then
            walker, leftAt = now, t
        end
        Session.moveTo(s.pcs[1], walker == 1 and 2200 or 150, 0)
        Session.moveTo(s.pcs[2], walker == 2 and -2200 or -150, 0)
    end, function() return {} end)
    local turnedAt = changes[#changes] and tonumber(changes[#changes]:match("^([%d%.]+):"))
    check(walker ~= nil and on ~= walker and turnedAt and turnedAt - leftAt <= 2.0,
        "who it's after walks off to 22 m: it turns to the one beside it within 2 s (" .. table.concat(changes, " ") .. ")")
    allErrors(s)

    -- A turn that comes due during one of its moves waits for the move to end, up to 2 s.
    s = targetSession(2)
    local h = s.pcs[1]
    local e = Session.enemyOn(h, "ring")
    Session.moveTo(h, 100, 0)
    Session.moveTo(s.pcs[2], -600, 0)
    s:run(12)
    check(field(e, "target") == h.pawn, "beside the host, nobody hitting: it's on the host")
    Session.enemyMove(h, "ring", "/PBZCombatAsset/ActorData/Move/E1.E1")
    local copy = Session.enemyOn(s.pcs[2], "ring")
    local part20 = select(2, Fake.health(e)) / 20
    for _ = 1, 3 do
        swing(s.pcs[2], copy, select(1, Fake.health(copy)) - part20)
        s:run(0.5)
    end
    check(field(e, "target") == h.pawn, "the guest takes 15% of it during one of its moves: it doesn't turn halfway through")
    Session.enemyMove(h, "ring", nil)
    s:run(1.2)
    check(field(e, "target") == figureOn(h, 2), "the move over, it turns to the guest")
    -- The host takes it over in a move that goes on and on: the turn waits 2 s for it, no longer. (Both near as can be:
    -- the damage decides.)
    Session.moveTo(s.pcs[2], -150, 0)
    Session.moveTo(h, 300, 0)
    Session.enemyMove(h, "ring", "/PBZCombatAsset/ActorData/Move/E2.E2")
    for _ = 1, 6 do
        swing(h, e, select(1, Fake.health(e)) - part20)
        s:run(0.5)
    end
    s:run(6)
    check(field(e, "target") == h.pawn, "a move that goes on and on holds a turn off 2 s at most")
    Session.enemyMove(h, "ring", nil)

    -- The two apart, one of them near it: the game's own again, with its own picker's wait back.
    Session.moveTo(s.pcs[2], 9000, 0)
    s:run(2.5)
    check(field(field(e, "picker"), "SwitchTargetCooldown") == 1.5, "with one player near it, its own picker's wait is back ("
        .. tostring(field(field(e, "picker"), "SwitchTargetCooldown")) .. " s)")
    -- Steered again, then sync off on the host: alone, it picks for itself again.
    Session.moveTo(s.pcs[2], -150, 0)
    s:run(2.5)
    local held = field(field(e, "picker"), "SwitchTargetCooldown")
    Session.command(h, "netoff")
    s:run(1)
    check(held > 1.5 and field(field(e, "picker"), "SwitchTargetCooldown") == 1.5, "sync off: its own picker's wait is back ("
        .. tostring(held) .. " s steered, " .. tostring(field(field(e, "picker"), "SwitchTargetCooldown")) .. " s after)")
    allErrors(s)

    -- A boss with a great deal of health (YuCong had 333180 on the real bench): the host stands beside it doing nothing, the
    -- guest hits it from 4 m, a little at a time. It turns to the guest. (With a floor of 3% of its health, more than a
    -- minute of the guest's hits, it stayed on the host for good: "totally ignores the one that is hitting him".)
    s = targetSession(2, true)
    changes, on = targetFight(s, 40, function(s)
        Session.moveTo(s.pcs[1], 100, 0)
        Session.moveTo(s.pcs[2], -400, 0)
    end, hitsEvery(1.1, function() return { [2] = 0.25 } end))
    check(on == 2 and #changes == 1, "a boss of great health, the host idle beside it, the guest's small hits from 4 m: it turns to the guest ("
        .. table.concat(changes, " ") .. ")")
    allErrors(s)

    -- A drink from the gourd draws its eye (the owner's word, after a design a friend sent: "punish healing"). Nobody
    -- hitting, both near it, it on the host: the guest drinks, and it turns to the guest. A drink right after a turn doesn't
    -- turn it back (the hold comes first, so drinking can't spin it); one after the hold does.
    s = targetSession(2)
    local hh = s.pcs[1]
    local thug = Session.enemyOn(hh, "ring")
    Session.moveTo(hh, 150, 0)
    Session.moveTo(s.pcs[2], -250, 0)
    s:run(14)
    check(field(thug, "target") == hh.pawn, "nobody hitting, the host nearer: it's on the host")
    local function drink(pc)
        Fake.running(pc, pc.pawn, "GA_Medicine_Common_Additive_C", true)
        s:run(1.2)
        Fake.running(pc, pc.pawn, "GA_Medicine_Common_Additive_C", false)
    end
    drink(s.pcs[2])
    s:run(1.5)
    check(field(thug, "target") == figureOn(hh, 2), "the guest drinks from the gourd: it turns to the guest")
    drink(hh)
    s:run(2.5)
    check(field(thug, "target") == figureOn(hh, 2), "the host drinks right after: it stays on the guest (its hold)")
    s:run(4)
    drink(hh)
    s:run(1.5)
    check(field(thug, "target") == hh.pawn, "the host drinks after the hold: it turns to the host")
    allErrors(s)

    -- A boss whose target can only chip at it while the other hits freely: it turns to the one hitting, never sooner than
    -- 10 s after its last turn.
    s = targetSession(2, true)
    changes = targetFight(s, 90, aroundIt(250), hitsEvery(0.6, function(t, now)
        return { [1] = now == 1 and 6 or 20, [2] = now == 2 and 6 or 20 }
    end))
    check(#changes >= 2 and shortestHold(changes) >= 10, "a boss turns to whoever hits it most, and holds each target 10 s at least ("
        .. table.concat(changes, " ") .. ")")
    allErrors(s)
end

local function targetsInParties()
    part("who an enemy goes for, four and six players")
    for _, n in ipairs({ 4, 6 }) do
        -- Everyone round it, going round, all hitting the same: it stays where it is.
        local s = targetSession(n)
        local changes = targetFight(s, 60, aroundIt(250, 0.35), hitsEvery(0.7, function()
            local all = {}
            for slot = 1, n do
                all[slot] = 20
            end
            return all
        end))
        check(#changes <= 1, n .. " players all hitting it the same, going round it: " .. #changes .. " changes in a minute ("
            .. table.concat(changes, " ") .. ")")
        allErrors(s)
        -- Player 2 deals the damage, the last one only chips now and then: it's on player 2, not on whoever hit last.
        s = targetSession(n)
        local on
        changes, on = targetFight(s, 60, aroundIt(250), hitsEvery(0.5, function(t)
            return { [2] = 40, [n] = math.floor(t * 2) % 4 == 0 and 3 or 0 }
        end))
        check(on == 2 and #changes <= 1, n .. " players: it goes for whoever deals the damage, and stays (" .. table.concat(changes, " ")
            .. "), not for the last to hit")
        allErrors(s)
        -- Whoever it's after can only chip, all the others hit freely: it turns, but never twice within 6 s.
        s = targetSession(n)
        changes = targetFight(s, 90, aroundIt(250), hitsEvery(0.6, function(t, now)
            local all = {}
            for slot = 1, n do
                all[slot] = slot == now and 6 or 20
            end
            return all
        end))
        check(shortestHold(changes) >= 6, n .. " players, its target only chipping: never two turns within 6 s ("
            .. table.concat(changes, " ") .. ")")
        allErrors(s)
    end
    -- A guest's drink in a party: player 3 drinks, nobody hitting, everyone round it: it turns to player 3, and on another
    -- guest's PC the drink (passed on by the relay) changes nothing.
    local s = targetSession(4)
    aroundIt(250)(s, 0)
    s:run(14)
    local h = s.pcs[1]
    local e = Session.enemyOn(h, "ring")
    Fake.running(s.pcs[3], s.pcs[3].pawn, "GA_Medicine_Common_Additive_C", true)
    s:run(1.2)
    Fake.running(s.pcs[3], s.pcs[3].pawn, "GA_Medicine_Common_Additive_C", false)
    s:run(1.5)
    check(field(e, "target") == figureOn(h, 3), "4 players: player 3 drinks from the gourd, and it turns to player 3")
    allErrors(s)
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
        Session.enemyMove(h, "ring", "/PBZCombatAsset/ActorData/Move/E" .. slot .. ".E" .. slot)
        s:run(0.3)
        return count(h.sent, " " .. slot .. "$") >= 1
    end
    check(aimedAt(3), "the host says which slot it's after")
    check(s.pcs[3].lastAim == s.pcs[3].pawn, "the guest it's after aims its copy at itself")
    check(s.pcs[2].lastAim == ghostOf(s.pcs[2], 3) and s.pcs[4].lastAim == ghostOf(s.pcs[4], 3), "the others aim theirs at that guest's ghost")
    check(aimedAt(1), "aimed at the host, it says 1")
    check(s.pcs[2].lastAim == ghostOf(s.pcs[2], 1) and s.pcs[3].lastAim == ghostOf(s.pcs[3], 1), "and every guest aims at the host's ghost")
    -- (Nobody on its list either: with its own cooldown given back, it picks again from the list within moments, as the
    -- game's does.)
    rawget(rawget(e, "__fields").BP_PBZHatredManagerComponent, "__fields").HatredList.items = {}
    Fake.put(e, "target", nil)
    Session.enemyMove(h, "ring", nil)
    s:run(0.2)
    h.sent = {}
    Session.enemyMove(h, "ring", "/PBZCombatAsset/ActorData/Move/E9.E9")
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

-- Each guest lands a hit on its copy of the host's boss: it's in that fight (net.fightingHere), not only shown it.
local function guestsHit(s)
    for i = 2, #s.pcs do
        local c = Session.enemyOn(s.pcs[i], "boss")
        swing(s.pcs[i], c, select(1, Fake.health(c)) - 10)
    end
end

local function holding()
    part("dying in a boss fight")
    local s = party()
    spread(s)
    s:run(2)
    bossStart(s)
    guestsHit(s)
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
    guestsHit(t)
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
    -- (Report 3: a host just come from 290 m off has a world still streaming in, and its "not here" of an enemy it hadn't
    -- spawned yet hid that enemy for good. Nothing new is asked while it settles.)
    check(count(g.sent, "^E HAS sp:thug1$") == 0, "a host that has just jumped 290 m: nothing asked while its world settles")
    s:run(8)
    check(count(g.sent, "^E HAS sp:thug1$") == 1, "the guest asks the host about it, once")
    check(count(h.sent, "^E NOT sp:thug1$") == 1, "and the host, who hasn't got it, says so")
    check(field(copy, "hidden") == true, "then it steps aside")
    check(field(brain, "running") == false, "its AI stops")
    check(field(copy, "dead") ~= true and select(1, Fake.health(copy)) > 0, "and it isn't killed")
    check(at(copy).Z >= 100.0 + 40000, "and it waits high up, too far for a bell to count it (one kept the guest from ringing)")
    local boss = Session.enemyOn(g, "boss")
    check(field(boss, "hidden") ~= true, "a boss stays")
    Session.moveTo(h, 30000, 0)
    s:run(2)
    check(field(copy, "hidden") == false and field(brain, "running") == true, "the host moves on, and it's back")
    check(gap(at(copy), { X = 1500.0, Y = 300.0 }) < 50 and math.abs(at(copy).Z - 100.0) < 50, "where it stood")
    Session.moveTo(h, 1000, 300)
    s:run(14)               -- (the host's jump back: its world settles first)
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
    check(h.env.PBZ.net.partnerGone == true, "and the host knows at once they've gone, not 12 s on")
    Session.command(g, "neton client")
    s:run(4)
    check(h.env.PBZ.net.partnerGone == false, "sync on again: they're back")
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
    t:run(14)               -- (the host's jump: its world settles first)
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
local function pair(extraIni, before)
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, extraIni)
    if before then
        before(s.pcs[1], s.pcs[2])      -- (each save as it is before they link)
    end
    s:run(4)
    Session.moveTo(s.pcs[1], 0, 0)
    Session.moveTo(s.pcs[2], 500, 0)
    s:run(2)
    return s, s.pcs[1], s.pcs[2]
end

-- Two players, as the report "After my teammate died, he instantly respawned, and the boss's HP was restored to full" (1.6.6)
-- had it. The game takes a player's bar down as they die (Session.die doesn't: it's done here), and the F 0 that followed
-- ended the partner's copy of the fight, whose own F 0 then let the held respawn go.
local function holdingForTwo()
    part("dying in a boss fight, two players")
    local s, h, g = pair()
    bossStart(s)
    local copy = Session.enemyOn(g, "boss")
    swing(g, copy, select(1, Fake.health(copy)) - 50)      -- (the guest is in it: a hit of its own on the boss)
    s:run(5)
    Session.die(h)
    h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "boss"))     -- (the game takes the bar down as the player dies)
    s:run(15)
    check(field(h.deathWidget, "NotTick") == true, "the host dies, the guest fights on: the host's respawn waits")
    check(g.env.PBZ.game.bossFightActive() and count(g.logs, "is over there: over here too") == 0,
        "and the guest's fight goes on, its bar up")
    check(net(h).toldFighting == true, "the host, down and held, still says the fight is on")
    Session.die(g)
    s:run(8)
    check(field(h.deathWidget, "NotTick") == false and field(g.deathWidget, "NotTick") == false,
        "the guest dies too: both respawns go on")
    allErrors(s)

    -- A scene on the survivor's side (a boss's phase, an execution) hid their figure after 3 s, and the wait let go at once.
    local t, th, tg = pair()
    bossStart(t)
    local tcopy = Session.enemyOn(tg, "boss")
    swing(tg, tcopy, select(1, Fake.health(tcopy)) - 50)
    t:run(5)
    Session.die(tg)
    t:run(6)
    check(field(tg.deathWidget, "NotTick") == true, "a guest down in the host's fight waits")
    Session.scene(th, true, "Seq023")
    t:run(10)
    check(field(tg.deathWidget, "NotTick") == true, "a scene on the host's side (a boss's phase) doesn't end the wait")
    Session.scene(th, false)
    t:run(4)
    check(field(tg.deathWidget, "NotTick") == true, "nor after it")
    allErrors(t)

    -- An arena whose sequence runs on through the fight, the camera on the player (Bai Chilian's): the dead player's own
    -- watching camera read as a scene, their partner's figure was hidden and the camera jumped every few seconds.
    local u, uh, ug = pair()
    bossStart(u)
    local ucopy = Session.enemyOn(ug, "boss")
    swing(ug, ucopy, select(1, Fake.health(ucopy)) - 50)
    Session.scene(ug, true, "Seq_Arena")
    Fake.put(ug.controller, "viewTarget", nil)
    u:run(5)
    Session.die(ug)
    u:run(12)
    check(ug.env.PBZ.game.isSpectating() and field(ug.deathWidget, "NotTick") == true,
        "down in an arena whose sequence runs on: the guest watches the host, and waits")
    check(peer(ug, 1).ghostHidden ~= true, "the host's figure stays: watching isn't a scene")
    allErrors(u)

    -- The guest's own fight, the host outside with only the copy's bar: the guest down in it waits for nobody.
    local v, vh, vg = pair()
    Session.moveTo(vg, 3000, 2900)
    Session.moveTo(vh, -1500, 3000)        -- (outside, 45 m off the boss: in the host's rounds, so it's shown the copy)
    v:run(1)
    vg.hudLayout:RegisterBossHPBar(Session.enemyOn(vg, "boss"))
    v:run(3)
    check(vh.env.PBZ.game.bossFightActive(), "the host outside is shown the guest's fight")
    check(net(vh).toldFighting ~= true, "but it isn't in it: it says no fight")
    Session.die(vg)
    vg.hudLayout:UnRegisterBossHPBar(Session.enemyOn(vg, "boss"))
    v:run(4)
    check(field(vg.deathWidget, "NotTick") ~= true, "the guest dies alone in it, the host outside with only the copy: no wait")
    v:run(12)
    check(field(vg.deathWidget, "NotTick") ~= true, "nor later")
    allErrors(v)
end


-- A player report (11-08): with two players, a host who dies in a boss fight before the guest doesn't watch the guest and
-- wait, as a guest who dies first does.
local function hostDiesFirst()
    part("the host dies first in a boss fight")
    local s, h, g = pair()
    bossStart(s)
    check(g.env.PBZ.game.bossFightActive(), "the guest sees the host's boss fight")
    -- (The guest in it, as in the report: a hit of its own on the boss. A copy's bar alone isn't being in it, since 1.7.0's
    -- net.fightingHere: at the black wall, by a bell or far off, it kept a dead player waiting on nobody.)
    local copy = Session.enemyOn(g, "boss")
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(5)
    Session.die(h)
    h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "boss"))     -- (the game takes its bar down as its player dies)
    s:run(6)
    check(field(h.deathWidget, "NotTick") == true, "the host, down with the guest still fighting, waits")
    check(h.env.PBZ.game.isSpectating(), "and watches the guest")
    check(g.env.PBZ.game.bossFightActive(), "and the guest's fight goes on")
    s:run(10)
    check(field(h.deathWidget, "NotTick") == true and h.env.PBZ.game.isSpectating(), "still, 16 s on")
    bossEnd(s)
    s:run(8)
    check(field(h.deathWidget, "NotTick") == false, "the boss dies: the host's respawn goes on")

    local t, th, tg = pair()
    bossStart(t)
    t:run(5)
    Session.die(tg)
    tg.hudLayout:UnRegisterBossHPBar(Session.enemyOn(tg, "boss"))
    t:run(6)
    check(field(tg.deathWidget, "NotTick") == true and tg.env.PBZ.game.isSpectating(), "the other way round: the guest waits and watches")

    local u, uh, ug = pair()
    bossStart(u)
    local ucopy = Session.enemyOn(ug, "boss")
    swing(ug, ucopy, select(1, Fake.health(ucopy)) - 50)
    u:run(5)
    Session.die(uh)
    uh.hudLayout:UnRegisterBossHPBar(Session.enemyOn(uh, "boss"))
    u:run(6)
    check(field(uh.deathWidget, "NotTick") == true, "again: the host down first waits")
    Session.die(ug)
    ug.hudLayout:UnRegisterBossHPBar(Session.enemyOn(ug, "boss"))
    u:run(12)
    check(field(uh.deathWidget, "NotTick") == false and field(ug.deathWidget, "NotTick") == false,
        "the guest goes down too: nobody's left to wait for, and both respawn")
    allErrors(u)
    allErrors(s)
    allErrors(t)
end
-- A player report (11-09): a door the host opened before the guest got there, or before it had loaded in the guest's world,
-- stayed shut for the guest (a hand-in door, the Phantom Tavern's): only F3 got them past.
local function doorsOpenedBefore()
    part("doors the host opened before the guest came")
    local s, h, g = pair()
    local function door(pc, name, open)
        local d = Fake.switch(pc, name, 330.0, 0.0, 100.0)
        Fake.put(d, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "CurSwitchState", true) end)
        Fake.put(d, "CurSwitchState", open)
        return d
    end
    local hostDoor = door(h, "BP_Block_Door_C_UAID_7", true)       -- (open in the host's world all along)
    local guestDoor = door(g, "BP_Block_Door_C_UAID_7", false)
    door(h, "BP_SlenderDoor_C_UAID_9", true)
    s:run(22)
    check(field(guestDoor, "CurSwitchState") == true, "a door open in the host's world before is opened in the guest's too")
    local late = door(g, "BP_SlenderDoor_C_UAID_9", false)         -- (loaded here only now)
    s:run(3)
    check(field(late, "CurSwitchState") == true, "and one that loads in the guest's world later, as it does")
    check(field(hostDoor, "CurSwitchState") == true, "(the host's stays open)")
    allErrors(s)
end
-- A player report (11-09): three players, an hour, the host at 1.5m dust, the guests at 600k. A wallet's rise across a death
-- (or a new body) went out whole as a gain and was paid to everyone.
local function dustOnlyEarned()
    part("only earned dust is shared")
    local s, h, g = pair()
    s:run(12)                                       -- (past the quiet after a new body)
    local function set(pc, v) Fake.put(pc.pawn, "ConsciousnessDust", v) end
    local before = Session.dust(h)
    set(g, Session.dust(g) + 100)                   -- (a kill's pay on the guest)
    s:run(2)
    check(Session.dust(h) == before + 100, "a guest's earned dust reaches the host")
    Session.die(g)
    s:run(1)
    set(g, Session.dust(g) + 50000)                 -- (its wallet back after the death, or a new body's saved amount)
    s:run(2)
    Session.revive(g)
    s:run(3)
    check(Session.dust(h) == before + 100, "a rise while down isn't sent as a gain")
    s:run(12)
    set(g, Session.dust(g) + 30)
    s:run(2)
    check(Session.dust(h) == before + 130, "and earning goes on being shared after")
    allErrors(s)
end
-- The game's own difficulty is Hellwalker while players are together (CoopDifficulty), and each one's pick comes back after.
local function coopDifficulty()
    part("the game's difficulty with a partner")
    local s, h, g = pair(nil, function(_, gpc) gpc.difficulty = 4 end)
    s:run(2)
    check(h.difficulty == 3, "the host's Pathbreaker is Hellwalker while they play together")
    check(g.difficulty == 4, "a guest on 66 Days stays on 66 Days")
    check(tostring(h.files["difficulty_own.txt"]):match("^2") ~= nil, "the host's own pick is kept in a file")
    h.difficulty = 1                                -- (Wayfarer picked in the menu during co-op)
    s:run(2)
    check(h.difficulty == 3, "a lower pick in the menu is raised again")
    g.cut = true
    s:run(10)
    check(h.difficulty == 3, "a partner gone a moment: still Hellwalker")
    s:run(30)
    check(h.difficulty == 2 and h.files["difficulty_own.txt"] == nil, "alone a while: back to the host's own Pathbreaker")
    check(g.difficulty == 4, "and the guest's 66 Days was never touched")
    allErrors(s)

    -- A crash in co-op left the save on Hellwalker: the next start, alone, puts the pick back.
    local t, th = pair(nil, function(hpc, gpc)
        hpc.files["difficulty_own.txt"] = "1"
        hpc.difficulty = 3
        gpc.cut = true
    end)
    t:run(40)
    check(th.difficulty == 1 and th.files["difficulty_own.txt"] == nil, "after a crash in co-op, alone: back to Wayfarer")
    allErrors(t)

    -- A crash while co-op held a Wayfarer at Pathbreaker (the setting Pathbreaker then: "1 2", the pick and the mode it held),
    -- the setting Hellwalker now: back to Wayfarer. (Compared with the setting alone, as before the file kept the mode it
    -- held, the save stayed on Pathbreaker; the review of 3f77be8.)
    local u, uh = pair(nil, function(hpc, gpc)
        hpc.files["difficulty_own.txt"] = "1 2"
        hpc.difficulty = 2
        gpc.cut = true
    end)
    u:run(40)
    check(uh.difficulty == 1 and uh.files["difficulty_own.txt"] == nil,
        "after a crash while held at another setting's pick, alone: back to Wayfarer")
    allErrors(u)
end
-- A guest's hit that makes their copy flinch: the host's enemy itself flinches the same way, and its next move doesn't cut the
-- copy's reaction short.
local function hitReactions()
    part("an enemy's reaction to a hit")
    local s, h, g = pair()
    local REACT, HIT = "CharacterState.Hitreact.State.Normal", "/PBZCombatAsset/ActorData/Move/Hit1.Hit1"
    local copy, theirs = Session.enemyOn(g, "near"), Session.enemyOn(h, "near")
    local function stateOf(e)
        return field(field(e, "hit"), "state")
    end
    local function playing(e)
        local m = field(field(e, "anim"), "montage")
        return m and m:GetFullName():gsub("^%S+ ", "") or "-"
    end
    Session.enemyMove(g, "near", HIT)
    Fake.put(field(copy, "hit"), "state", REACT)
    local mark = #h.sent
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(count(g.sent, "^E D sp:near 50%.0 0%.0 %- /PBZCombatAsset/ActorData/Move/Hit1%.Hit1 0%.25 CharacterState%.Hitreact%.State%.Normal$") == 1,
        "a guest's hit goes with the reaction it made on their copy")
    check(playing(theirs) == HIT and stateOf(theirs) == REACT, "and the host's enemy plays that reaction, in that hit state")
    local echo = 0
    for i = mark + 1, #h.sent do
        echo = echo + (h.sent[i]:find("^E A sp:near %- /PBZCombatAsset/ActorData/Move/Hit1%.Hit1") and 1 or 0)
    end
    check(echo == 0, "not sent back to the guest as a move of its own")
    Session.enemyMove(h, "near", "/PBZCombatAsset/ActorData/Move/E1.E1")
    s:run(0.5)
    check(playing(copy) == HIT, "the host's next move doesn't cut the copy's own reaction short")
    Fake.put(field(copy, "hit"), "state", "None")
    Session.enemyMove(h, "near", "/PBZCombatAsset/ActorData/Move/E2.E2")
    s:run(0.5)
    check(playing(copy) == "/PBZCombatAsset/ActorData/Move/E2.E2", "and plays once it's over")
    s:run(1.5)
    check(stateOf(theirs) == "None", "the hit state set on the host's enemy by hand is let go")
    allErrors(s)
end

-- A boss isn't stun-locked by a partner's hits (Nexus reports on 1.6.6: "it gets continuously hit and can't fight back"): a
-- guest's hit doesn't force their copy's flinch on the host's boss in the middle of a move of its own; between moves one gets
-- through now and then; a posture break always does. And the guest's boss copy, in a flinch of its own, still plays the host's
-- next move (thrown away, the guest was never hit back).
-- A fresh session, the game's item table read by nothing yet: the first pickup is told all the same, and the partner's copy
-- goes. (With quest items shared, nothing read the table, and a pickup was told only once it was read: none was, the
-- partner's copy stayed, and the second to pick it up had two, a Killing Aura Amber say; a report on 1.6.9.)
local function pickupsFresh()
    part("a pickup in a fresh session")
    local s, h, g = pair()
    local function pickupOn(pc, id)
        for _, p in ipairs(pc.pickups) do
            if rawget(p, "__name") == id then
                return p
            end
        end
    end
    Fake.pickup(h, "amber1", "R_520", 250.0, 0.0, 100.0)
    Fake.pickup(g, "amber1", "R_520", 250.0, 0.0, 100.0)
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 250, -150)
    s:run(2)
    pickupOn(h, "amber1"):K2_DestroyActor()
    Session.gainItem(h, "R_520", 1)
    s:run(4)
    check(count(h.sent, "^E I amber1") == 1 and rawget(pickupOn(g, "amber1"), "__alive") == false,
        "the first pickup of a fresh session is told, and the partner's copy goes")
    check(Session.items(g, "R_520") == 1 and Session.items(h, "R_520") == 1, "one pickup in the world is one each")
    allErrors(s)

    -- A kill's reward, given in both worlds: the host's game at the death, the guest's as its copy dies at the host's K, a
    -- second on. The share came first and the guest kept both (a report on 1.6.9): it waits now, and this world's own drops it.
    local t, th, tg = pair()
    Session.moveTo(th, 1500, 450)
    Session.moveTo(tg, 1500, 150)
    t:run(3)
    local copy, theirs = Session.enemyOn(tg, "thug1"), Session.enemyOn(th, "thug1")
    Fake.setHealth(theirs, 0)
    Fake.put(theirs, "dead", true)
    Session.gainItem(th, "R_930", 1)
    local diedAt, gaveAt, clock = nil, nil, 0
    t:run(8, function()
        clock = clock + 1 / 60
        if not diedAt and field(copy, "dead") == true then
            diedAt = clock
        end
        if diedAt and not gaveAt and clock >= diedAt + 1 then
            gaveAt = clock
            Session.gainItem(tg, "R_930", 1)
        end
    end)
    check(gaveAt ~= nil and Session.items(tg, "R_930") == 1 and Session.items(th, "R_930") == 1,
        "a kill's reward both worlds give is one each, the guest's own a second after the share")
    allErrors(t)
end

-- What a partner finds shows on the right, the game's own notice for a find (the user, 11-09: "people want to be notified
-- what their friends picked up on the right same as when you pick items the small notification that appears"), at once: it
-- waited in the backpack's queue till the next chest (a report on 1.6.9). A thing new to the player gets the line too, not
-- the full-screen card; a note's card waits for the game's own moment, as it did. A partner's ground pickup is given
-- whatever this world was given lately, from our copy if its share never comes, and our copy stays gone when its area
-- streams back in ("teleport a long distance, then fast travel back ... the item glow on the ground is still there").
local function pickupsShown()
    part("a partner's finds on the right")
    local s, h, g = pair()
    local function pickupOn(pc, id)
        for i = #pc.pickups, 1, -1 do
            if rawget(pc.pickups[i], "__name") == id then
                return pc.pickups[i]
            end
        end
    end
    local function both(id, item, x, y)
        Fake.pickup(h, id, item, x, y, 100.0)
        Fake.pickup(g, id, item, x, y, 100.0)
    end
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 250, -150)
    s:run(2)
    Session.gainItem(g, "Weapon_Material_01", 1)
    s:run(5)
    check(Session.items(h, "Weapon_Material_01") == 1 and #h.cards == 0 and h.tips[#h.tips] == "Weapon_Material_01 + 1",
        "a thing new to the host comes as the line on the right, not the card, at once: " .. tostring(h.tips[#h.tips]))
    local tips = #h.tips
    Session.gainItem(g, "Weapon_Material_01", 2)
    s:run(5)
    check(#h.tips == tips + 1 and h.tips[#h.tips] == "Weapon_Material_01 + 2" and Session.items(h, "Weapon_Material_01") == 3,
        "one the host has already: its line too, with the count: " .. tostring(h.tips[#h.tips]))
    h.noPickupUI = true
    Session.gainItem(g, "Weapon_Material_01", 1)
    s:run(5)
    local waited = #h.tips
    h.noPickupUI = false
    s:run(1.5)
    check(waited == tips + 1 and #h.tips == tips + 2, "while the game can't show it (a scene, a menu) it waits, then shows")

    -- Each takes a ground pickup of the same thing in the same moment: one each, and one from the other (the share was
    -- dropped as "given here too" by the other's own).
    both("matA", "Weapon_Material_02", 250.0, 100.0)
    both("matB", "Weapon_Material_02", 250.0, -100.0)
    s:run(2)
    local h0, g0 = Session.items(h, "Weapon_Material_02"), Session.items(g, "Weapon_Material_02")
    pickupOn(h, "matA"):K2_DestroyActor()
    Session.gainItem(h, "Weapon_Material_02", 1)
    pickupOn(g, "matB"):K2_DestroyActor()
    Session.gainItem(g, "Weapon_Material_02", 1)
    s:run(6)
    check(Session.items(h, "Weapon_Material_02") == h0 + 2 and Session.items(g, "Weapon_Material_02") == g0 + 2,
        string.format("two pickups of one thing in a moment: two each, %d and %d", Session.items(h, "Weapon_Material_02") - h0,
            Session.items(g, "Weapon_Material_02") - g0))
    check(rawget(pickupOn(h, "matB"), "__alive") == false and rawget(pickupOn(g, "matA"), "__alive") == false,
        "and each one's copy of the other's gone")

    -- The guest's game takes one in without its notice: no share comes. The host's copy went: given from it.
    both("matC", "Weapon_Material_02", 300.0, 0.0)
    s:run(2)
    h0 = Session.items(h, "Weapon_Material_02")
    pickupOn(g, "matC"):K2_DestroyActor()
    g.bag:AddPropsToBackPack(1, g.env.FName("Weapon_Material_02"), false)
    s:run(5)
    local early = Session.items(h, "Weapon_Material_02")
    s:run(16)
    check(early == h0 and Session.items(h, "Weapon_Material_02") == h0 + 1 and count(h.logs, "never came") == 1,
        "a pickup whose share never came is given from the host's copy, once its wait is out: " .. early - h0 .. " then "
        .. Session.items(h, "Weapon_Material_02") - h0)

    -- Its area streams back in (the host off by a bell and back): the game makes the copy again. Gone again, not given again.
    h0 = Session.items(h, "Weapon_Material_02")
    local again = Fake.pickup(h, "matB", "Weapon_Material_02", 250.0, -100.0, 100.0)
    s:run(3)
    check(rawget(again, "__alive") == false and Session.items(h, "Weapon_Material_02") == h0,
        "a copy the guest took, made again as its area streams back in: gone again")
    -- One the host's world hadn't loaded when the word came, loaded after: gone too.
    Fake.pickup(g, "matD", "Weapon_Material_02", 280.0, -150.0, 100.0)
    s:run(2)
    pickupOn(g, "matD"):K2_DestroyActor()
    Session.gainItem(g, "Weapon_Material_02", 1)
    s:run(5)
    local late = Fake.pickup(h, "matD", "Weapon_Material_02", 280.0, -150.0, 100.0)
    s:run(3)
    check(rawget(late, "__alive") == false, "a copy loaded after the guest's word came: gone as it loads")

    -- A note's card isn't put up mid-play by us: the game's own next pickup shows it, the lines with it.
    local pushes, cards = count(h.trace, "TryToPushPickupUI"), #h.cards
    Session.gainItem(g, "R_77", 1)
    Session.gainItem(g, "Weapon_Material_01", 1)
    s:run(5)
    check(#h.cards == cards and count(h.trace, "TryToPushPickupUI") == pushes and Session.items(h, "R_77") == 1,
        string.format("a note's card waits for the game's own moment, the line after it with it: %d cards, %d shown, %d notes",
            #h.cards - cards, count(h.trace, "TryToPushPickupUI") - pushes, Session.items(h, "R_77")))
    Session.gainItem(h, "Weapon_Material_01", 1)     -- (the host's own next find: the game shows them all)
    check(#h.cards == cards + 1 and h.tips[#h.tips] == "Weapon_Material_01 + 1", "and the host's own next find shows them")
    allErrors(s)
end

local function bossReactions()
    part("a boss's reaction to a partner's hits")
    local s, h, g = pair()
    Session.moveTo(h, 2700, 3000)
    Session.moveTo(g, 3300, 3000)
    s:run(2)
    local REACT, HIT = "CharacterState.Hitreact.State.Normal", "/PBZCombatAsset/ActorData/Move/Hit1.Hit1"
    local ATTACK, ATTACK2 = "/PBZCombatAsset/ActorData/Move/E1.E1", "/PBZCombatAsset/ActorData/Move/E2.E2"
    local copy, theirs = Session.enemyOn(g, "boss"), Session.enemyOn(h, "boss")
    local function stateOf(e)
        return field(field(e, "hit"), "state")
    end
    local function playing(e)
        local m = field(field(e, "anim"), "montage")
        return m and m:GetFullName():gsub("^%S+ ", "") or "-"
    end
    local function guestHit()
        Session.enemyMove(g, "boss", HIT)
        Fake.put(field(copy, "hit"), "state", REACT)
        swing(g, copy, select(1, Fake.health(copy)) - 50)
        s:run(0.5)
    end
    Session.enemyMove(h, "boss", ATTACK)
    s:run(0.5)
    guestHit()
    check(playing(theirs) == ATTACK and stateOf(theirs) ~= REACT,
        "a guest's hit doesn't cut the boss's own attack short (" .. playing(theirs) .. ")")
    -- The guest's copy, flinching at that hit, still takes the host's next move.
    Session.enemyMove(h, "boss", ATTACK2)
    s:run(0.5)
    check(playing(copy) == ATTACK2, "the guest's boss copy, in a flinch of its own, still plays the host's next move ("
        .. playing(copy) .. ")")
    -- ("The guest is almost completely safe": a guest's blow broke the copy's attack on the guest's PC, the host's boss went
    -- on with it, and it never landed. In a move of the host's the copy takes next to no poise; between moves, its own.)
    local function poiseOf(e)
        return e.AttributeSetBase.TakenReductionMultiplier_Poise.CurrentValue
    end
    check(math.abs(poiseOf(copy) - 0.01) < 1e-6, "in the host's move the guest's copy takes next to no poise: its attack lands")
    Fake.put(field(copy, "hit"), "state", "None")
    Session.enemyMove(h, "boss", nil)
    s:run(0.5)
    guestHit()
    check(playing(theirs) == HIT, "between its moves, a guest's hit makes the boss flinch (" .. playing(theirs) .. ")")
    check(math.abs(poiseOf(copy) - 0.5) < 1e-6, "and between them the copy has its own boss poise back")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    Session.enemyMove(h, "boss", nil)
    s:run(0.5)
    guestHit()
    check(playing(theirs) ~= HIT, "but not again a moment later: one now and then, so it can fight back (" .. playing(theirs) .. ")")
    -- A posture break plays, in a move or not: the guest's hit broke the copy (its reaction a break). Once: every hit on a
    -- broken bar did, and two players kept the boss reeling (a report on 1.6.9).
    local BREAK = "CharacterState.HitReact.State.Break.Normal"
    local function guestBreak()
        Session.enemyMove(g, "boss", HIT)
        Fake.put(field(copy, "hit"), "state", BREAK)
        swing(g, copy, select(1, Fake.health(copy)) - 50)
        s:run(0.5)
    end
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    Session.enemyMove(h, "boss", ATTACK)
    s:run(0.5)
    guestBreak()
    check(playing(theirs) == HIT, "a posture break plays, in a move or not (" .. playing(theirs) .. ")")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    Session.enemyMove(h, "boss", ATTACK2)
    s:run(0.5)
    guestBreak()
    check(playing(theirs) == ATTACK2, "but once: hits on its broken bar don't stop its next move (" .. playing(theirs) .. ")")
    -- On the guest: the copy's own flinch at the guest's hit, in the middle of the host's move, gives way to that move
    -- (flinching at every swing, it dropped the host's attacks: the bench, 11-09).
    Fake.put(field(copy, "hit"), "state", "None")
    Session.enemyMove(h, "boss", ATTACK)
    Fake.put(field(theirs, "anim"), "startedAt", h.now)     -- (the move begins now: the host says where it is in it)
    s:run(0.5)
    Session.enemyMove(g, "boss", HIT)
    Fake.put(field(copy, "hit"), "state", REACT)
    s:run(0.3)
    check(playing(copy) == ATTACK and stateOf(copy) == "None",
        "the copy's own flinch in the host's move gives way to the move (" .. playing(copy) .. ", " .. tostring(stateOf(copy)) .. ")")
    allErrors(s)
end

-- A boss beaten in co-op is beaten in both saves, and two saves that disagree are brought round to the host's.
local function beatenInBoth()
    part("a boss beaten in both worlds")
    local function spawnerOn(pc)
        return pc.spawners[Session.indexOf(pc, "boss")]
    end
    local s, h, g = pair()
    Session.moveTo(h, 3000, 2800)
    Session.moveTo(g, 3000, 2700)
    s:run(2)
    local boss = Session.enemyOn(h, "boss")
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(3)
    check(field(spawnerOn(g), "record") == false, "the host's kill: the guest's world has the boss beaten too, as its own kill would")
    allErrors(s)

    local b, bh, bg = pair()
    Fake.put(spawnerOn(bh), "record", false)
    Session.moveTo(bh, 3000, 2800)
    Session.moveTo(bg, 3000, 2700)
    b:run(2)
    local theirs = Session.enemyOn(bg, "boss")
    bg.hudLayout:RegisterBossHPBar(theirs)
    b:run(3)
    check(field(theirs, "dead") == true, "a boss the host has beaten and the guest's save hasn't: the guest's fight ends at once")
    check(field(spawnerOn(bg), "record") == false, "and it's beaten in the guest's world from then on")
    check(next(bh.env.PBZ.net.foggedBosses) == nil and next(bh.env.PBZ.net.partnerBosses) == nil,
        "the host doesn't take up a fight that isn't there, walls and all")
    allErrors(b)

    local again, ah, ag = pair()
    Session.moveTo(ah, 3000, 2800)
    Session.moveTo(ag, 3000, 2700)
    again:run(2)
    local first = Session.enemyOn(ah, "boss")
    Fake.setHealth(first, 0)
    Fake.put(first, "dead", true)
    again:run(3)
    Fake.put(first, "dead", false)
    Fake.setHealth(first, 5000)
    local copy = Session.enemyOn(ag, "boss")
    Fake.put(copy, "dead", false)
    Fake.setHealth(copy, 5000)
    ah.hudLayout:RegisterBossHPBar(first)
    again:run(0.5)
    ag.hudLayout:RegisterBossHPBar(copy)
    again:run(2)
    check(field(copy, "dead") ~= true, "the host fighting a boss it once killed: the guest's copy isn't killed as that old kill")
    allErrors(again)

    local r, rh, rg = pair()
    Fake.put(spawnerOn(rg), "record", false)
    local gone = Session.enemyOn(rg, "boss")         -- (beaten there: no boss of its own about)
    Fake.setHealth(gone, 0)
    Fake.put(gone, "dead", true)
    Session.moveTo(rh, 3000, 2800)
    Session.moveTo(rg, 15000, 2700)
    r:run(2)
    rh.hudLayout:RegisterBossHPBar(Session.enemyOn(rh, "boss"))
    r:run(3)
    check(count(rg.logs, "is back for their fight") == 1 and (field(spawnerOn(rg), "claimed") or 0) >= 1,
        "beaten in the guest's world and not the host's: it's back on the guest's side for the host's fight")
    allErrors(r)
end

-- The guest's side, through a bad link and more.
local function guestSide()
    part("the guest's side")
    local s, h, g = pair()
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 0, 300)
    s:run(3)
    local copy = Session.enemyOn(g, "near")
    local min = field(field(copy, "AttributeSetBase"), "Health_Min")
    check(field(min, "CurrentValue") == 1, "a guest's copy of a host enemy is held")
    h.cut = true
    local lowest = 1
    s:run(2.5, function() lowest = math.min(lowest, field(min, "CurrentValue")) end)
    check(lowest == 1 and g.env.PBZ.net.remoteEnemies["sp:near"] ~= nil,
        "two and a half seconds without a packet: still the host's, not let go to fight the guest on its own")
    h.cut = false
    s:run(2)
    check(field(min, "CurrentValue") == 1, "and still held when the host is heard again")
    -- A trip: the host says it's loading, then nothing for 20 s, longer than the 12 s that make a partner gone.
    h.env.PBZ.net.tellLoading()
    s:run(0.3)
    h.cut = true
    local held = true
    s:run(20, function() held = held and field(min, "CurrentValue") == 1 end)
    check(held and not g.env.PBZ.net.partnerGone, "the host loading for 20 s isn't gone: the guest's copies stay held, no fight of theirs on their own")
    h.cut = false
    s:run(3)
    -- Back from the load, then quiet for good (a crash): gone at the usual 12 s, not at the end of the load's minute.
    h.cut = true
    s:run(14)
    check(g.env.PBZ.net.partnerGone, "back from the load, a host that goes quiet is gone after 12 s again")
    h.cut = false
    s:run(3)
    allErrors(s)

    -- A host with no Phantom Edge on says so, and the guest's figure of them carries none.
    local e2, eh2, eg2 = pair()
    e2:run(10)
    local theirs = eg2.env.PBZ.net.gear
    check(theirs and theirs.edgePath == "-", "no Phantom Edge on: \"none\" is said, and the partner's figure is told so")
    allErrors(e2)

    -- A guest's fight that ends with the boss alive (they died in it, walked out): over on the host too.
    local f, fh, fg = pair()
    Session.moveTo(fg, 3000, 2900)
    Session.moveTo(fh, 30000, 3000)
    f:run(2)
    local boss = Session.enemyOn(fg, "boss")
    fg.hudLayout:RegisterBossHPBar(boss)
    f:run(3)
    check(next(fh.env.PBZ.net.partnerBosses) ~= nil, "the guest's fight is mirrored on the host")
    fg.hudLayout:UnRegisterBossHPBar(boss)
    f:run(9)
    check(next(fh.env.PBZ.net.partnerBosses) == nil and next(fh.env.PBZ.net.foggedBosses) == nil,
        "its bar down for good with the boss alive: over on the host too, walls open")
    allErrors(f)
end

-- The host's world decides: a chest the host opened before, alone, is open for a guest too, and pays them what it held.
local function hostsChests()
    part("the host's chests")
    local LOOT, OPEN = "Xigu.004.Weapon_Material_04", "/HuaShira/SceneProp/Chest/Anim/Chest_Open.Chest_Open"
    local s, h, g = pair()
    local opened = Fake.chest(h, "BP_Chest_C_9", 600.0, 0.0, 100.0, LOOT)
    Fake.put(opened, "CurSwitchState", true)
    local shut = Fake.chest(g, "BP_Chest_C_9", 600.0, 0.0, 100.0, LOOT)
    Fake.put(shut, "InteractPlayer", g.pawn)        -- (the game sets it for whoever stands by it)
    local dustH, dustG = Session.dust(h), Session.dust(g)
    s:run(3)
    check(field(shut, "CurSwitchState") == true and field(field(shut, "Chest"), "anim") == g.found[OPEN] and field(shut, "swept") == false,
        "a chest the host opened before is open for the guest too")
    check(Session.items(g, "Weapon_Material_04") == 6 and Session.items(g, "Weapon_Material_13") == 2 and Session.dust(g) == dustG + 441,
        "and pays them what it holds, as the game's table says (a medicine's dust is for later play-throughs)")
    check(count(g.trace, "AddWeaponItem") == 1 and count(g.trace, "PushAccessoryToInventory") == 1 and count(g.trace, "PushMedicineToInventory") == 1,
        "its Phantom Edge, medicine and accessory too")
    check(Session.items(h, "Weapon_Material_04") == 0 and Session.dust(h) == dustH and count(h.trace, "AddWeaponItem") == 0,
        "and none of it goes back to the host")
    local far = Fake.chest(h, "BP_Chest_C_10", 900.0, 0.0, 100.0, "Xigu.AC_Deflect")
    Fake.put(far, "CurSwitchState", true)
    s:run(2)
    local late = Fake.chest(g, "BP_Chest_C_10", 900.0, 0.0, 100.0, "Xigu.AC_Deflect")
    s:run(2)
    check(field(late, "CurSwitchState") == true and count(g.trace, "PushAccessoryToInventory") == 2,
        "one that wasn't loaded on the guest's side pays when it is")
    s:run(65)
    check(Session.items(g, "Weapon_Material_04") == 6 and count(g.trace, "PushAccessoryToInventory") == 2,
        "named again (for one who joins later), nothing pays twice")
    local live = Fake.chest(h, "BP_Chest_C_11", 100.0, 0.0, 100.0, LOOT)
    local liveThere = Fake.chest(g, "BP_Chest_C_11", 100.0, 0.0, 100.0, LOOT)
    s:run(2)
    Fake.put(live, "CurSwitchState", true)
    s:run(3)
    check(field(liveThere, "CurSwitchState") == true and Session.items(g, "Weapon_Material_04") == 6,
        "one the host opens now isn't paid from the table: its things come as the host gets them")
    local hostHas = Fake.chest(h, "BP_Chest_C_12", 700.0, 0.0, 100.0, "Xigu.AC_Deflect")
    local guestOpening = Fake.chest(g, "BP_Chest_C_12", 700.0, 0.0, 100.0, "Xigu.AC_Deflect")
    Fake.put(field(g.pawn, "interact"), "InteractingActor", guestOpening)
    Fake.put(hostHas, "CurSwitchState", true)
    s:run(3)
    check(field(guestOpening, "CurSwitchState") == false and count(g.trace, "PushAccessoryToInventory") == 2,
        "not one the guest is opening right then: the game's own opening pays it")
    Fake.put(field(g.pawn, "interact"), "InteractingActor", nil)
    s:run(2)
    check(field(guestOpening, "CurSwitchState") == true and count(g.trace, "PushAccessoryToInventory") == 3,
        "(and if they stopped, it's paid after all)")
    allErrors(s)

    local o, oh, og = pair("FollowHostStory = Off\n")
    local hers = Fake.chest(oh, "BP_Chest_C_9", 600.0, 0.0, 100.0, LOOT)
    Fake.put(hers, "CurSwitchState", true)
    local his = Fake.chest(og, "BP_Chest_C_9", 600.0, 0.0, 100.0, LOOT)
    o:run(3)
    check(field(his, "CurSwitchState") == false and Session.items(og, "Weapon_Material_04") == 0,
        "FollowHostStory = Off: the guest's chests stay their own")
    allErrors(o)
end

-- The host's story point is the party's: a guest behind it is brought up to it at a quiet moment, and nothing goes back.
local function followTheHost()
    part("the host's story point")
    local all = #Fake.STORY_ROWS
    local s, h, g = pair()
    h.storyUpTo(all)            -- (the host's point moves after they've linked: it's read again within 20 s)
    g.storyUpTo(3)
    s:run(3)
    check(#g.storyApplied == 0, "a guest behind the host isn't changed at once")
    s:run(30)
    check(g.storyState("Main-Forest", "1") == 2 and g.storyState("Boss-Puppet", "S1") == 2,
        "then they have the host's story: the quests the host's world has done, its boss among them")
    check(g.storyState("Side-Cry", "1") == 2, "an optional quest the host did, too")
    check(g.storyMarks["camp.arrived"] and g.storyMarks["UI.VisibilityTag.Shop"], "and the marks and unlocks along the way")
    check(not g.storyMarks["I_1"] and not g.storyMarks["item.recipe"], "but not a row with the host's finds in it")
    check(count(g.trace, "ActivateAllBellsByMaps") == 0,
        "nor a map's every bell (a row like Pangzhen's 'map unlocked' rang them all: fast travel everywhere on arrival)")
    check(count(g.logs, "Story: caught up with the host's") == 1 and count(g.logs, "your story caught up with the host's: ") == 1,
        "the guest is told, once")
    check(#h.storyApplied == 0, "and the host's world isn't touched")
    local applied = #g.storyApplied
    s:run(70)
    check(#g.storyApplied == applied, "nothing is applied twice, as the host keeps telling its point")
    allErrors(s)

    -- A guest who joins far ahead (a finished save) changes nothing in the host's world: what they did before joining is
    -- their own (1.6.2, after a report of a newcomer's game spoiled).
    local a, ah, ag = pair(nil, function(ph, pg)
        ph.storyUpTo(3)
        pg.storyUpTo(all)
    end)
    a:run(60)
    check(#ag.storyApplied == 0, "a guest ahead of the host stays ahead")
    check(ah.storyState("Side-Cry", "1") ~= 2 and ah.storyState("Main-Forest", "1") ~= 2,
        "and the steps they'd done before joining don't reach the host")
    check(count(ah.logs, "a guest finished") == 0, "nothing said")
    allErrors(a)

    -- A choice the guest's world made the other way (said no, 3-B, where the host said yes, 3-A): not overturned.
    local c, ch, cg = pair()
    ch.storyUpTo(all)
    cg.storyUpTo(3)
    cg.storyStep("Well-Ask", "3-B", 1)
    c:run(40)
    check(cg.storyState("Main-Forest", "1") == 2 and (cg.storyState("Well-Ask", "3-A") or 0) == 0,
        "a guest catches up, but a choice it made the other way stays its own")
    allErrors(c)

    -- The other way, done together: a quest both have under way that the guest finishes while linked (the bow in the
    -- tower) is finished for the host too. Not the guest's later quests: the host's world keeps its point.
    local e, eh, eg = pair(nil, function(ph, pg)
        ph.storyUpTo(3)
        pg.storyUpTo(6)
    end)
    e:run(30)
    check(eh.storyState("Side-Cry", "1") ~= 2, "(not yet finished by anyone)")
    eg.storyUpTo(all)
    e:run(60)
    check(eh.storyState("Side-Cry", "1") == 2, "a quest the host is on, finished by the guest while linked, is finished for the host")
    check(eh.storyState("Main-Forest", "1") ~= 2 and eh.storyState("Boss-Puppet", "S1") ~= 2,
        "but nothing the host hasn't started: the host's point stays its own")
    check(count(eh.logs, "a guest finished") == 1, "said once")
    allErrors(e)

    -- The bags on joining: only the host gives. A guest gets what the host has and they lack; a guest's own things
    -- (a finished save's weapons and money) stay theirs and don't fill a newcomer host's bag.
    local b, bh, bg = pair(nil, function(ph, pg)
        Session.gainItem(ph, "R_700", 2)
        Session.gainItem(pg, "R_800", 5)
    end)
    b:run(20)
    check(Session.items(bg, "R_700") == 2, "a guest joining gets what's in the host's bag")
    check(Session.items(bh, "R_800") == 0, "but the host gets nothing from the guest's bag")
    check(Session.items(bg, "R_800") == 5 and Session.items(bh, "R_700") == 2, "and each keeps their own")
    allErrors(b)

    local c, ch, cg = pair()
    ch.storyUpTo(all)
    cg.storyUpTo(3)
    Session.scene(cg, true)
    c:run(35)
    check(#cg.storyApplied == 0, "not during a cutscene")
    Session.scene(cg, false)
    c:run(25)
    check(cg.storyState("Main-Forest", "1") == 2, "but once it's over and things have settled")
    allErrors(c)

    -- Right after a load the game is still filling its quest list: nothing is read or applied until it says it's done.
    local l, lh, lg = pair()
    lh.storyUpTo(all)
    lg.storyUpTo(3)
    Fake.put(lg.narrative, "bCompleteLoad", false)
    l:run(50)
    check(#lg.storyApplied == 0, "not while the game is still loading its quests")
    Fake.put(lg.narrative, "bCompleteLoad", true)
    l:run(3)
    check(lg.storyState("Main-Forest", "1") == 2, "then at once")
    allErrors(l)
    allErrors(c)

    local o, oh, og = pair("FollowHostStory = Off\n")
    oh.storyUpTo(all)
    og.storyUpTo(3)
    o:run(35)
    check(#og.storyApplied == 0, "FollowHostStory = Off: the guest's story stays their own")
    allErrors(o)

    -- A boss the host's world beat in an earlier session: no actor of it there, only its spawner's record.
    local b = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local bh, bg = b.pcs[1], b.pcs[2]
    local i = Session.indexOf(bh, "boss")
    Fake.put(bh.spawners[i], "record", false)
    Fake.put(bh.spawners[i], "SpawnedAI", nil)
    table.remove(bh.enemies, i)
    Session.moveTo(bh, 3000, 2800)
    Session.moveTo(bg, 3000, 2700)
    b:run(10)
    local theirs = Session.enemyOn(bg, "boss")
    check(field(theirs, "dead") == true, "a boss the host has beaten is beaten on the guest's side before any fight")
    check(field(bg.spawners[Session.indexOf(bg, "boss")], "record") == false, "and written down there")
    check(count(bh.sent, "^E BEATEN sp:boss$") == 1, "the host answers once")
    allErrors(b)

    -- The host's boss died while the guest's sync was off; the guest's world has it standing, never paired with anything.
    local r = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local rh, rg = r.pcs[1], r.pcs[2]
    Session.moveTo(rh, 3000, 2800)
    Session.moveTo(rg, 3000, 2700)
    r:run(3)
    Session.command(rg, "netoff")
    r:run(1)
    local gone = Session.enemyOn(rh, "boss")
    Fake.setHealth(gone, 0)
    Fake.put(gone, "dead", true)
    r:run(2)
    Session.command(rg, "neton client")
    r:run(5)
    check(field(Session.enemyOn(rg, "boss"), "dead") == true,
        "a boss the host beat while the guest was away is gone on the guest's side once they sync")
    check(field(rg.spawners[Session.indexOf(rg, "boss")], "record") == false, "and beaten in the guest's world")
    allErrors(r)
end

-- A guest whose save has played further: the host's enemies are long dead in it. Its spawners bring them back for the host,
-- and its save has them dead again once they die.
local function hostsEnemiesHere()
    part("enemies only the host's world has")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local h, g = s.pcs[1], s.pcs[2]
    local i = Session.indexOf(g, "thug1")
    local mine, sp = g.enemies[i], g.spawners[i]
    Fake.put(sp, "record", false)
    Fake.put(sp, "SpawnedAI", nil)
    table.remove(g.enemies, i)
    Session.moveTo(h, 1000, 300)
    Session.moveTo(g, 1200, 300)
    s:run(8)
    check((field(sp, "claimed") or 0) == 1, "the guest's world brings back an enemy the host has and it hasn't, once")
    check(field(sp, "record") == true, "its record turned back, so its spawner will spawn it")
    check(count(g.logs, "brought back while you play together") == 1, "and the guest's log says so")
    -- The spawn, as the game would make it.
    Fake.put(mine, "dead", false)
    Fake.setHealth(mine, 600)
    table.insert(g.enemies, i, mine)
    Fake.put(sp, "SpawnedAI", mine)
    s:run(15)
    check(g.env.PBZ.coop.enemyActor("sp:thug1") == mine, "the host's enemy has a body here now")
    check(field(sp, "claimed") == 1, "and nothing more is spawned for it")
    local theirs = Session.enemyOn(h, "thug1")
    Fake.setHealth(theirs, 0)
    Fake.put(theirs, "dead", true)
    s:run(3)
    check(field(mine, "dead") == true, "it dies with the host's")
    check(field(sp, "record") == false, "and the guest's save has it dead again, as before")
    allErrors(s)

    -- The guest leaves before it's killed: the save is put back too.
    local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local th, tg = t.pcs[1], t.pcs[2]
    local j = Session.indexOf(tg, "thug1")
    local tsp = tg.spawners[j]
    Fake.put(tsp, "record", false)
    Fake.put(tsp, "SpawnedAI", nil)
    table.remove(tg.enemies, j)
    Session.moveTo(th, 1000, 300)
    Session.moveTo(tg, 1200, 300)
    t:run(8)
    check(field(tsp, "record") == true, "brought back")
    Session.command(tg, "netoff")
    t:run(1)
    check(field(tsp, "record") == false, "sync off: the guest's save has it dead again")
    allErrors(t)

    -- Its spawner streamed out when the session ended: put back once it's loaded again.
    local u = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    local uh, ug = u.pcs[1], u.pcs[2]
    local ui = Session.indexOf(ug, "thug1")
    local usp = ug.spawners[ui]
    Fake.put(usp, "record", false)
    Fake.put(usp, "SpawnedAI", nil)
    table.remove(ug.enemies, ui)
    Session.moveTo(uh, 1000, 300)
    Session.moveTo(ug, 1200, 300)
    u:run(8)
    check(field(usp, "record") == true, "(brought back)")
    table.remove(ug.spawners, ui)          -- (its part of the map streams out)
    Session.command(ug, "netoff")
    u:run(1)
    check(field(usp, "record") == true, "(not there to put back)")
    table.insert(ug.spawners, ui, usp)     -- (and streams in again)
    u:run(7)
    check(field(usp, "record") == false, "a spawner not loaded when the session ended is put back once it is")
    allErrors(u)

    -- The guest's killing blow on the host's boss: the host's world has it beaten, as its own blow would.
    local k, kh, kg = pair()
    Session.moveTo(kh, 3000, 2800)
    Session.moveTo(kg, 3000, 2700)
    k:run(4)
    local hostBoss = Session.enemyOn(kh, "boss")
    Fake.put(hostBoss, "dustLoot", 700)
    local copy = Session.enemyOn(kg, "boss")
    swing(kg, copy, 1)
    k:run(3)
    check(field(hostBoss, "dead") == true, "the guest's killing blow kills the host's boss")
    check(field(hostBoss, "realDeath") == true, "by the game's whole death, as the host's own blow would: its story goes on")
    check(field(kh.spawners[Session.indexOf(kh, "boss")], "record") == false, "and the host's world has it beaten")
    check(Session.dust(kh) == 700 and Session.dust(kg) == 700, "the host is paid once, by the game, and the guest gets the same")
    allErrors(k)
end

-- Player reports on 1.6.3 (11-05): the forest's last boss killed outside its script, a phase spawned on the host by a guest's
-- fight, a boss copy left standing on the guest after the host's fight, a joiner held watching a fight with no end.
local function playerReports()
    part("player reports on 1.6.3")
    do
        local k, kh, kg = pair()
        Session.moveTo(kh, 3000, 2800)
        Session.moveTo(kg, 3000, 2700)
        k:run(4)
        local hostBoss = Session.enemyOn(kh, "boss")
        local floor = field(field(hostBoss, "AttributeSetBase"), "Health_Min")
        Fake.put(floor, "BaseValue", 1000)
        Fake.put(floor, "CurrentValue", 1000)
        swing(kg, Session.enemyOn(kg, "boss"), 1)
        k:run(3)
        check(field(hostBoss, "dead") ~= true, "a guest's killing blow on a boss its game holds at a floor (a phase's end) doesn't kill it")
        check(select(1, Fake.health(hostBoss)) == 1001, "it's left just above the floor, for the host's next blow to cross")
        check(field(kh.spawners[Session.indexOf(kh, "boss")], "record") ~= false, "and it isn't written beaten")
        allErrors(k)
    end
    do
        local k, kh, kg = pair()
        Session.moveTo(kh, 3000, 2800)
        Session.moveTo(kg, 3000, 2700)
        k:run(4)
        local hostBoss = Session.enemyOn(kh, "boss")
        Fake.put(hostBoss, "locked", true)      -- (between phases: the game won't let it die now)
        swing(kg, Session.enemyOn(kg, "boss"), 1)
        k:run(3)
        check(field(hostBoss, "dead") ~= true and select(1, Fake.health(hostBoss)) >= 1,
            "a guest's killing blow on a boss the game won't let die now isn't forced through")
        check(field(kh.spawners[Session.indexOf(kh, "boss")], "record") ~= false, "nor written beaten")
        Fake.put(hostBoss, "locked", nil)
        allErrors(k)
    end
    do
        local list = {}
        for _, e in ipairs(ENEMIES) do
            list[#list + 1] = e
        end
        list[#list + 1] = { "YuCong_P3_1", "BP_Monster_Boss_C", 3000.0, 3400.0, 100.0, 5000, 400, true }
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local sh, sg = s.pcs[1], s.pcs[2]
        local hi = Session.indexOf(sh, "YuCong_P3_1")
        local hsp = sh.spawners[hi]
        Fake.put(hsp, "SpawnedAI", nil)         -- (the host is still in its scene between phases: no phase 3 yet)
        table.remove(sh.enemies, hi)
        s:run(4)
        Session.moveTo(sh, 3000, 3000)
        Session.moveTo(sg, 3000, 3200)
        s:run(2)
        sg.hudLayout:RegisterBossHPBar(Session.enemyOn(sg, "YuCong_P3_1"))
        s:run(3)
        check(count(sg.sent, "^E B .*YuCong_P3_1") >= 1, "(a guest's fight with a boss's later phase is told)")
        check((field(hsp, "claimed") or 0) == 0, "the host doesn't spawn that phase for it: its own fight script does")
        allErrors(s)
    end
    do
        local list = {}
        for _, e in ipairs(ENEMIES) do
            list[#list + 1] = e
        end
        list[#list + 1] = { "ChiLian_Seq034", "BP_Monster_Boss_C", 3000.0, 3400.0, 100.0, 5000, 400, true }
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local sh, sg = s.pcs[1], s.pcs[2]
        local hi = Session.indexOf(sh, "ChiLian_Seq034")
        local hsp = sh.spawners[hi]
        Fake.put(hsp, "SpawnedAI", nil)         -- (not met yet in the host's world)
        table.remove(sh.enemies, hi)
        s:run(4)
        Session.moveTo(sh, 3000, 3000)
        Session.moveTo(sg, 3000, 3200)
        s:run(2)
        sg.hudLayout:RegisterBossHPBar(Session.enemyOn(sg, "ChiLian_Seq034"))
        s:run(3)
        check((field(hsp, "claimed") or 0) == 1,
            "but a guest's fight with a boss of one phase, from a sequence spawner (the forest's last), is spawned on the host")
        allErrors(s)
    end
    do
        -- The boss spawned on the host for a guest's fight, that fight over without its death (the guest walked out): it
        -- stood on with its own AI, the bells by it "in combat", and a host who met it later fought it outside its encounter.
        local list = {}
        for _, e in ipairs(ENEMIES) do
            list[#list + 1] = e
        end
        list[#list + 1] = { "ChiLian_Seq034", "BP_Monster_Boss_C", 3000.0, 3400.0, 100.0, 5000, 400, true }
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local sh, sg = s.pcs[1], s.pcs[2]
        local hi = Session.indexOf(sh, "ChiLian_Seq034")
        local hsp = sh.spawners[hi]
        Fake.put(hsp, "SpawnedAI", nil)
        table.remove(sh.enemies, hi)
        local stand = nil
        Fake.put(hsp, "ClaimSeqSpawn", function(self)       -- (the game's spawn: a boss of its own on the host)
            stand = Fake.enemy(sh, "standin", "BP_Monster_Boss_C", 3000.0, 3400.0, 100.0, 5000, 400, true)
            table.remove(sh.spawners, Session.indexOf(sh, "standin"))
            Fake.put(self, "SpawnedAI", stand)
        end)
        s:run(4)
        Session.moveTo(sh, 3000, 3000)
        Session.moveTo(sg, 3000, 3200)
        s:run(2)
        sg.hudLayout:RegisterBossHPBar(Session.enemyOn(sg, "ChiLian_Seq034"))
        s:run(3)
        check(stand ~= nil and rawget(stand, "__alive") ~= false, "(spawned on the host for the guest's fight)")
        sg.hudLayout:UnRegisterBossHPBar(Session.enemyOn(sg, "ChiLian_Seq034"))     -- (the guest walks out)
        s:run(8)
        check(stand and rawget(stand, "__alive") == false and field(stand, "realDeath") ~= true,
            "that fight over without its death: the boss spawned for it goes, with no death")
        allErrors(s)
    end
    do
        -- Report 9 and the bench's sweep: Xiaoxue fell, both worlds ran her death, then she was up again on the host and the
        -- guest's copy stayed dead: the boss "vanished" for the guest, the host's alone to finish and be paid for.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        bossEnd(s)
        s:run(3)
        check(field(Session.enemyOn(g, "boss"), "dead") == true, "(the boss falls in both worlds)")
        local gsp = g.spawners[Session.indexOf(g, "boss")]
        local before = field(gsp, "claimed") or 0
        local hostBoss = Session.enemyOn(h, "boss")
        Fake.put(hostBoss, "dead", false)
        Fake.setHealth(hostBoss, 3000)              -- (up again on the host, the same boss)
        s:run(15)
        check((field(gsp, "claimed") or 0) > before, "a boss up again on the host is up again on the guest")
        allErrors(s)
    end
    do
        -- The chaos fuzzer: a guest who'd hit the boss kept its dead body paired under its id (a kill still to tell), and the
        -- boss up again on the host never came back there.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        net(g).hitHere["sp:boss"] = true
        bossEnd(s)
        s:run(3)
        local gsp = g.spawners[Session.indexOf(g, "boss")]
        local before = field(gsp, "claimed") or 0
        local hostBoss = Session.enemyOn(h, "boss")
        Fake.put(hostBoss, "dead", false)
        Fake.setHealth(hostBoss, 3000)
        s:run(15)
        check((field(gsp, "claimed") or 0) > before, "and so it is when the guest had hit it before it fell")
        allErrors(s)
    end
    do
        -- The bug hunt: the guest started the boss fight first, and the host's own fight with that boss was then taken for a
        -- mirror of the guest's, ended with it (walls open, bar gone, the boss alive): report 9's "only the host".
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        check(#net(h).ownBosses() == 1, "a host's own fight with a boss it showed for the guest's is the host's own")
        Session.moveTo(g, 9000, 9000)
        g.hudLayout:UnRegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(8)
        check(h.env.PBZ.game.bossFightActive() and net(g).partnerBosses["sp:boss"] == true,
            "and the guest's leaving it doesn't end it, still shown on the guest")
        allErrors(s)
    end
    do
        -- The bug hunt: a boss that fell in the host's fight and stood up again under the bar the host's game kept up (Xiaoxue)
        -- came back on the guest with no fight: no bar, no walls, its death there a quiet one.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(4)
        local boss = Session.enemyOn(h, "boss")
        Fake.setHealth(boss, 0)
        Fake.put(boss, "dead", true)
        s:run(4)
        Fake.put(boss, "dead", false)
        Fake.setHealth(boss, 3000)
        s:run(15)
        local gc = Session.enemyOn(g, "boss")
        Fake.put(gc, "dead", false)
        Fake.setHealth(gc, 3000)
        s:run(4)
        check(net(g).partnerBosses["sp:boss"] == true and g.env.PBZ.game.bossFightActive(),
            "a boss up again in the host's fight is the host's fight again on the guest, bar and all")
        local mark = #g.logs
        Fake.setHealth(boss, 0)
        Fake.put(boss, "dead", true)
        s:run(1)
        h.hudLayout:UnRegisterBossHPBar(boss)
        s:run(4)
        local whole = false
        for i = mark + 1, #g.logs do
            whole = whole or g.logs[i]:find("its death runs here too", 1, true) ~= nil
        end
        check(whole, "and its death at the host's kill is the whole death there")
        allErrors(s)
    end
    do
        -- 乱葬岗 vs 小雪 (a Nexus report, 11-05): she falls in the host's fight and gets up again in it. The host took its own
        -- bar down and opened its walls at the fall, and the guest's world, raising her by its own script, killed her
        -- quietly as the host's old kill and wrote her beaten: she vanished for the guest, the reward the host's alone.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        local downs = 0
        local realDown = rawget(h.hudLayout, "__fields").UnRegisterBossHPBar
        Fake.put(h.hudLayout, "UnRegisterBossHPBar", function(self, b)
            downs = downs + 1
            return realDown(self, b)
        end)
        local boss = Session.enemyOn(h, "boss")
        Fake.setHealth(boss, 0)
        Fake.put(boss, "dead", true)
        s:run(2)
        check(downs == 0, "she falls: the host's own bar is the game's to take down, not the mod's")
        Fake.put(boss, "dead", false)
        Fake.setHealth(boss, 3000)
        local gc = Session.enemyOn(g, "boss")
        Fake.put(gc, "dead", false)
        Fake.setHealth(gc, 3000)
        g.hudLayout:RegisterBossHPBar(gc)            -- (the guest's own world raises her, her bar with her)
        s:run(3)
        check(field(gc, "dead") ~= true, "up again on the guest by its own script: not killed as the host's old kill")
        check(h.env.PBZ.game.isBeaten("sp:boss") ~= true, "and on the host her record isn't left beaten")
        allErrors(s)
    end
    do
        -- The bug hunt: the chains the host broke just before its boss fight were held on the guest for the whole fight
        -- (a fight shown there, not the guest's own), the guest shut out of the arena (report 7).
        local s, h, g = pair()
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 500, 0)
        s:run(8)
        table.insert(h.globalTags, "zddy.chain.broken")
        s:run(4)
        Session.moveTo(h, 3000, 2800)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(25)
        check(g.storyMarks["zddy.chain.broken"] and g.env.PBZ.game.bossFightActive(),
            "the host's flow comes to the guest while the host's fight is shown there")
        allErrors(s)
    end
    do
        -- The bug hunt (report 1): the host's own hits left an enemy under 1, its line wrote the guest's copy to exactly the
        -- floor, and every blow of the guest's after read as no drop: nothing sent, the enemy the host's alone to finish.
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        local h, g = s.pcs[1], s.pcs[2]
        s:run(4)
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 500, 0)
        s:run(2)
        local hostThug, copy = Session.enemyOn(h, "near"), Session.enemyOn(g, "near")
        Fake.setHealth(hostThug, 0.8)
        s:run(1)
        local before = #g.sent
        g.env.PBZ.game.noteLocalMove()
        Fake.setHealth(copy, 1)
        s:run(1)
        local d = 0
        for j = before + 1, #g.sent do
            if g.sent[j]:match("^E D sp:near") then
                d = d + 1
            end
        end
        check(d > 0, "a guest's blow on a copy held at its floor is told to the host")
        allErrors(s)
    end
    do
        -- The bug hunt: a guest who stopped and started sync again put a new clone of each partner beside the old ones, a
        -- full player body each, five more with each hiccup of a 6-player party. The ones put away are taken back.
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, 4, ENEMIES)
        for i = 2, 4 do
            Session.moveTo(s.pcs[i], 200 * i, 0)
        end
        s:run(10)
        local g = s.pcs[2]
        local function bodies()
            local n = 0
            for _, a in ipairs(g.spawned) do
                if a:IsValid() and rawget(a, "__alive") ~= false and not field(a, "BIsMonster") then
                    n = n + 1
                end
            end
            return n
        end
        local first = bodies()
        for _ = 1, 3 do
            Session.command(g, "netoff")
            s:run(1)
            Session.command(g, "neton client")
            s:run(4)
        end
        check(bodies() == first, "sync off and on again takes the partners' put-away bodies back, no new ones")
        allErrors(s)
    end
    do
        -- The bug hunt (report 8): a guest who linked after the host's scene woke a bell never had that bell. And the
        -- Nexus report on 1.6.6: "When we reached Pangzhen, we found that all the bells were already unlocked": every bell
        -- the host had was lit at the link, wherever the guest was. Now a host's bell is lit when the guest comes to it.
        local s, h, g = pair(nil, function(h)
            table.insert(h.bellIds, "Bell_YXZR_009")
        end)
        s:run(15)
        check(not g.storyMarks["Bell_YXZR_009"], "a bell the host woke before the guest linked isn't lit far from the guest")
        Session.moveTo(g, 20000 - 1200, 900)
        s:run(3)
        check(g.storyMarks["Bell_YXZR_009"], "it's lit when the guest comes to it")
        check(count(g.logs, "lit here, as you came to it") == 1, "once")
        Session.moveTo(g, 500, 0)
        local reads = g.bellReads
        s:run(5)
        check(reads == 1 and g.bellReads == 1, "the game's bell table is read once")
        allErrors(s)
    end
    do
        -- A new game's players both came out of the prologue without the healing gourd: co-op keeps its hands off there.
        local s, h, g = pair()
        s:run(2)
        g.map = "PBZ_WP_ZhuLinGuWu"
        g.env.PBZ.game.prologueAt = -1e9
        check(g.env.PBZ.game.inPrologue() == true, "(the guest is in the prologue)")
        local pushed = 0
        local bp = g.env.PBZ.game.backpackOf(g.pawn)
        if bp then
            local real = rawget(bp, "__fields").PushMedicineToInventory
            Fake.put(bp, "PushMedicineToInventory", function() pushed = pushed + 1 end)
            g.env.PBZ.game.grantLoot(g.pawn, "Hulu", "medicine")
            Fake.put(bp, "PushMedicineToInventory", real)
        end
        check(pushed == 0, "the starting healing gourd is never handed out by the mod")
        local restored = 0
        if bp then
            Fake.put(bp, "RestoreEquipmentAfterPrologue", function() restored = restored + 1 end)
        end
        local join, gnet = g.env.PBZ.coop.joinPartner, net(g)
        check(join ~= nil and join() == gnet.PROLOGUE_TIP and restored == 0,
            "no trip to the partner out of the prologue on its own: it says how to skip it")
        table.insert(h.globalTags, "zlgw.intro.done")
        s:run(6)
        check(not g.storyMarks["zlgw.intro.done"], "and nothing of the host's flow comes into it")
        check(join() == gnet.PROLOGUE_TIP and restored == 0, "F3 again: no skip of our own, only where the game's is")
        allErrors(s)
    end
    do
        -- The skip is the player's choice only: a guest in the prologue as sync links isn't taken out of it, and is told how.
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        local h, g = s.pcs[1], s.pcs[2]
        g.map = "PBZ_WP_ZhuLinGuWu"
        g.env.PBZ.game.prologueAt = -1e9
        local restored = 0
        local bp = g.env.PBZ.game.backpackOf(g.pawn)
        if bp then
            Fake.put(bp, "RestoreEquipmentAfterPrologue", function() restored = restored + 1 end)
        end
        s:run(30)
        check(restored == 0 and g.map == "PBZ_WP_ZhuLinGuWu", "linking from the prologue leaves the guest in it")
        -- MORE's Skip Prologue tile: red in the prologue, a click says where the game's own skip is; green past it.
        local skip = g.env.PBZ.prologue
        check(skip.state() == "todo" and h.env.PBZ.prologue.state() == "done", "the tile: red in the prologue, green past it")
        check(skip.press() == skip.HOW and restored == 0, "a click on it points at the game's own skip, nothing more")
        check(h.env.PBZ.prologue.press() == "you're past the prologue.", "a click past it does nothing")
        allErrors(s)
    end
    do
        -- Reports 7 and 8: the host broke the chains (its flow raised a flag), the scene after the boss ran a flow step and
        -- woke a bell; the guest, who was in neither, could neither start the boss nor rest at its bell, even after a reconnect.
        local s, h, g = pair()
        s:run(4)
        h.env.PBZ.game.storyFlags = nil
        table.insert(h.globalTags, "zddy.chain.broken")
        h.eventPipeline.ExecuteNodeGuid:Add("ABCDEF0123456789ABCDEF0123456789")
        table.insert(h.bellIds, "Bell_YXZR_005")
        table.insert(h.globalTags, "GameMode.NewGamePlus")       -- (never sent)
        s:run(4)
        table.insert(h.globalTags, "Combat.InFight")
        s:run(20)
        check(g.storyMarks["zddy.chain.broken"] and g.storyGuids["ABCDEF0123456789ABCDEF0123456789"],
            "what the host's flow did while linked (a flag, a flow step) is done on the guest too")
        check(not g.storyMarks["Bell_YXZR_005"], "and its new bell waits for the guest to come to it")
        Session.moveTo(g, 30000, 2000)
        s:run(3)
        check(g.storyMarks["Bell_YXZR_005"], "then it's lit there")
        Session.moveTo(g, 500, 0)
        check(not g.storyMarks["GameMode.NewGamePlus"], "but never the game's mode")
        check(not h.storyMarks["zddy.chain.broken"], "and nothing goes the other way")
        check(not g.storyMarks["Combat.InFight"], "nor the state of a moment (a fight's)")
        -- A flag up for a moment only (under one look) isn't story: not sent.
        table.insert(h.globalTags, "zddy.blink")
        s:run(5)
        for i, t in ipairs(h.globalTags) do
            if t == "zddy.blink" then
                table.remove(h.globalTags, i)
                break
            end
        end
        s:run(20)
        check(not g.storyMarks["zddy.blink"], "a flag up for a moment only isn't sent")
        -- A world loaded on the host: hundreds new at once are its state, not play, and nothing goes.
        for i = 1, 300 do
            table.insert(h.globalTags, "load.flag" .. i)
        end
        s:run(20)
        check(not g.storyMarks["load.flag1"], "hundreds of flags new at once (a load) aren't sent")
        allErrors(s)

        local o, oh, og = pair("FollowHostStory = Off\n")
        o:run(4)
        table.insert(oh.globalTags, "zddy.chain.broken")
        o:run(20)
        check(not og.storyMarks["zddy.chain.broken"], "FollowHostStory = Off: the guest's flow stays its own")
        allErrors(o)
    end
    do
        -- 1.6.3's report 1: "after P2 empties a mob's bar it can still be hit, and the model vanishes seconds later". The
        -- game refused the copy's death at the host's K (a state just after the killing blow): the quiet kill alone stood
        -- frozen and still took blows till the game cleared it. Tried again a moment on, then dissolved, out of reach.
        local s, h, g = pair()
        s:run(2)
        local copy = Session.enemyOn(g, "near")
        Fake.put(copy, "locked", true)              -- (the game won't let it die just now)
        local theirs = Session.enemyOn(h, "near")
        Fake.setHealth(theirs, 0)
        Fake.put(theirs, "dead", true)
        s:run(0.2)
        Fake.put(copy, "locked", false)             -- (and lets it a moment on)
        s:run(1)
        check(field(copy, "realDeath") == true, "a copy whose death the game refused dies its whole death when tried again")
        local copy2 = Session.enemyOn(g, "thug1")
        Fake.put(copy2, "locked", true)             -- (refused for good)
        Fake.put(copy2, "SetActorEnableCollision", function(self, on) Fake.put(self, "collides", on) end)
        local theirs2 = Session.enemyOn(h, "thug1")
        Fake.setHealth(theirs2, 0)
        Fake.put(theirs2, "dead", true)
        s:run(2)
        check(field(copy2, "dead") == true and field(copy2, "collides") == false, "refused again: dissolved, out of reach")
        check(count(g.logs, "refused a ") >= 1, "and said in the log, with what may have stopped it")
        allErrors(s)
    end
    do
        -- Report 3: "small enemies go invisible; teleporting to the player or sitting at a bell sets it off".
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        local h, g = s.pcs[1], s.pcs[2]
        local i = Session.indexOf(h, "thug1")
        table.remove(h.enemies, i)
        table.remove(h.spawners, i)
        Session.moveTo(h, 1000, 300)
        Session.moveTo(g, 1200, 300)
        s:run(8)
        local copy = Session.enemyOn(g, "thug1")
        check(field(copy, "hidden") == true, "(an enemy only the guest's save has is put aside)")
        local handlers = h.env.PBZ.coop.handlers
        local realHAS = handlers.HAS
        handlers.HAS = function() end               -- (the host says no more "no": as if its world had it now)
        s:run(30)
        check(field(copy, "hidden") ~= true, "a 'not in my world' gone stale doesn't keep an enemy hidden for good")
        handlers.HAS = realHAS
        allErrors(s)

        local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        local th, tg = t.pcs[1], t.pcs[2]
        local j = Session.indexOf(th, "thug1")
        table.remove(th.enemies, j)
        table.remove(th.spawners, j)
        Session.moveTo(th, 1000, 300)
        Session.moveTo(tg, 1200, 300)
        t:run(1)
        Session.loadMap(th)                         -- (the host's world loads: a trip or a bell)
        t:run(6)
        check(count(th.sent, "^E NOT sp:thug1$") == 0, "a host whose world is still loading doesn't say 'not here'")
        allErrors(t)
    end
    do
        -- Report 1: "the guest empties a small enemy's bar and it can still be hit, now and then it never dies".
        local s, h, g = pair()
        Session.moveTo(g, 400, 300)
        s:run(3)
        local hostThug, copy = Session.enemyOn(h, "near"), Session.enemyOn(g, "near")
        Fake.setHealth(hostThug, 1.3)
        s:run(1)
        swing(g, copy, 1)                           -- (1.3 to its floor: a drop under half a point)
        s:run(2)
        check(field(hostThug, "dead") == true, "a copy hit onto its floor by a hair is still the killing blow")
        allErrors(s)

        local r, rh, rg = pair()
        Session.moveTo(rg, 400, 300)
        r:run(3)
        local thug2, copy2 = Session.enemyOn(rh, "thug1"), Session.enemyOn(rg, "thug1")
        Session.moveTo(rg, 1400, 300)
        r:run(2)
        local handlers = rh.env.PBZ.coop.handlers
        local realD, dropped = handlers.D, 0
        handlers.D = function(rest, from)
            if rest:find(" L ") and dropped == 0 then
                dropped = 1                         -- (the first killing blow lost on the way)
                return
            end
            return realD(rest, from)
        end
        swing(rg, copy2, 1)
        r:run(3)
        check(dropped == 1 and field(thug2, "dead") == true, "a killing blow lost on the way is told again, and the enemy dies")
        handlers.D = realD
        allErrors(r)
    end
    do
        -- Bai Chilian's arena on the bench: a sequence ran on through a minute of fighting, the camera on the player. The guest
        -- was taken for "in a scene": hidden on the host and off the boss's list, which then stood still on the guest's screen.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        Session.scene(g, true, "Seq_Arena")
        Fake.put(g.controller, "viewTarget", nil)       -- (the camera still on the player)
        s:run(6)
        check(net(h).ghostHidden ~= true, "a sequence running with the camera on the guest doesn't hide them on the host")
        Fake.put(g.controller, "viewTarget", g.sceneCamera)
        s:run(6)
        check(net(h).ghostHidden == true, "a real scene (the camera taken) still does")
        Session.scene(g, false)
        s:run(3)
        allErrors(s)
    end
    do
        -- The forest's last boss on the bench: a boss spawned for the partner's fight, then the same boss from this world's
        -- own fight scene. Two stood there: the guest killed the one not paired with the host's, and the host's stayed at full
        -- health for the host to fight all over again.
        local s, h, g = pair()
        s:run(1)
        local spawned = Session.enemyOn(g, "boss")
        -- (One class for both, as in the game: the fake gives each enemy a class of its own name.)
        local bossClass = { GetFName = function() return { ToString = function() return "BP_Monster_ChiLian_C" end } end,
            IsValid = function() return true end }
        rawset(spawned, "__classObject", bossClass)
        local mine = { addr = spawned:GetAddress(), fname = spawned:GetFName():ToString(),
            class = spawned:GetClass():GetFName():ToString(), untilAt = g.now + 120 }
        net(g).extraBossWatch = { ["sp:boss"] = mine }
        s:run(2)
        check(rawget(spawned, "__alive") ~= false, "a boss spawned for the partner's fight stays while it's the only one")
        local scene = Fake.enemy(g, "boss_scene", "BP_Monster_Boss_C", 3050.0, 3000.0, 100.0, 5000, 400, true)
        rawset(scene, "__classObject", bossClass)
        s:run(2)
        check(rawget(spawned, "__alive") == false and rawget(scene, "__alive") ~= false,
            "the same boss from this world's own fight scene: the one spawned for the partner goes, the scene's stays")
        check(field(spawned, "realDeath") ~= true and field(spawned, "dead") ~= true, "and it goes with no death (its story isn't run)")
        allErrors(s)
    end
    do
        -- The same, the one spawned for the partner not in yet as it was asked for: its spawner kept, the boss found there
        -- after. (With nothing kept, no watch was made: two stood there, a bar each, the unpaired one full; a report on 1.6.9.)
        local s, h, g = pair()
        s:run(1)
        local spawned = Session.enemyOn(g, "boss")
        local bossClass = { GetFName = function() return { ToString = function() return "BP_Monster_ChiLian_C" end } end,
            IsValid = function() return true end }
        rawset(spawned, "__classObject", bossClass)
        net(g).extraBossWatch = { ["sp:boss"] = { spawner = "boss", untilAt = g.now + 120 } }
        s:run(2)
        check(rawget(spawned, "__alive") ~= false, "one spawned not in yet when asked: found by its spawner, kept while it's alone")
        local scene = Fake.enemy(g, "boss_scene", "BP_Monster_Boss_C", 3050.0, 3000.0, 100.0, 5000, 400, true)
        rawset(scene, "__classObject", bossClass)
        s:run(2)
        check(rawget(spawned, "__alive") == false and rawget(scene, "__alive") ~= false,
            "and with the scene's boss in, the one spawned for the partner goes")
        allErrors(s)
    end
    do
        -- The forest's last boss on the bench: the guest's copy read 0 health before the host's K came, and the K took it
        -- for dead already: no death of the game's ran, so no scene, and the guest's story stayed while the host's went on.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        local copy = Session.enemyOn(g, "boss")
        Fake.setHealth(copy, 0)                     -- (at 0, but the game's death never ran on it)
        local hostBoss = Session.enemyOn(h, "boss")
        Fake.setHealth(hostBoss, 0)
        Fake.put(hostBoss, "dead", true)
        s:run(3)
        check(field(copy, "realDeath") == true,
            "a copy only at 0 health still dies the game's whole way at the host's K (the forest's last: its scene, its story)")
        allErrors(s)
    end
    do
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        local copy = Session.enemyOn(g, "boss")
        check(net(g).partnerBosses["sp:boss"] == true, "(the guest is shown the host's fight)")
        net(g).broughtBack["sp:boss"] = true        -- (its save had it beaten: brought back for the host's fight)
        h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "boss"))     -- (the host walks out of it)
        s:run(8)
        check(field(copy, "dead") == true, "the host's fight over: a copy brought back for it isn't left standing on the guest")
        allErrors(s)
    end
    do
        -- The host wins: its K comes first and took the boss off the fights shown here, so the sweep as the fight ended put
        -- nothing down. Another of that boss here (a duplicate, another phase) stood by the arena: its bell said "in combat".
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        check(net(g).partnerBosses["sp:boss"] == true, "(the guest is shown the host's fight)")
        local extra = Fake.enemy(g, "boss", "BP_Monster_Boss_C", 12000.0, 3000.0, 100.0, 5000, 400, true)
        s:run(1)
        bossEnd(s)
        s:run(10)
        check(field(extra, "dead") == true, "the host wins: another of that boss left standing here is put down after it")
        allErrors(s)
    end
    do
        -- The guest starts the fight first, then the host's own scene brings its own actor of that boss: the host's fight
        -- stayed filed as the guest's, and the guest's F 0 took the host's bar down and opened its walls mid-fight.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(3)
        check(net(h).partnerBosses["sp:boss"] == true, "(the host is shown the guest's fight)")
        local stand = Session.enemyOn(h, "boss")
        local scene = Fake.enemy(h, "boss_scene", "BP_Monster_Boss_C", 3050.0, 3000.0, 100.0, 5000, 400, true)
        table.remove(h.spawners, Session.indexOf(h, "boss_scene"))
        rawset(stand, "__alive", false)              -- (the stand-in goes, as dropExtraBoss does)
        Fake.put(h.spawners[Session.indexOf(h, "boss")], "SpawnedAI", scene)  -- (the scene's boss is that spawner's now)
        s:run(1.5)
        h.hudLayout:RegisterBossHPBar(scene)         -- (the game's own bar on it)
        s:run(2)
        check(net(h).partnerBosses["sp:boss"] == nil, "the host's own bar on its scene's boss: the host's fight from now on")
        g.hudLayout:UnRegisterBossHPBar(Session.enemyOn(g, "boss"))     -- (the guest walks out, or dies)
        s:run(8)
        check(h.env.PBZ.game.bossFightActive() and #net(h).ownBosses() == 1,
            "and the guest's F 0 leaves it: the host's bar and walls stay")
        allErrors(s)
    end
    do
        -- A player report (11-09): the host died in the fight, and the guest's boss, one its save had beaten, was killed
        -- on the spot; the host's next try was at nothing on the guest's screen.
        local s, h, g = pair()
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g, 3000, 2700)
        s:run(3)
        bossStart(s)
        s:run(4)
        local copy = Session.enemyOn(g, "boss")
        net(g).broughtBack["sp:boss"] = true
        Session.die(h)
        h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "boss"))     -- (the game takes the bar down as its player dies)
        s:run(8)
        check(field(copy, "dead") ~= true, "the host dies in the fight: the guest's boss, brought back for it, isn't put down")
        Session.die(g)
        g.hudLayout:UnRegisterBossHPBar(copy)
        s:run(15)
        check(field(copy, "dead") ~= true, "both go down and the fight is lost: still there for the next try")
        allErrors(s)
    end
    do
        local list = {
            { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 },
            { "hostboss", "BP_Monster_Boss_C", 300.0, 300.0, 100.0, 5000, 400, true },
        }
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local h = s.pcs[1]
        s:run(4)
        Session.moveTo(h, 0, 0)
        Session.moveTo(s.pcs[2], 500, 0)
        s:run(2)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "hostboss"))
        s:run(3)
        Session.moveTo(s.pcs[2], 11000, 0)
        s:run(4)
        check(count(h.sent, "^E RUN sp:byguest 1$") == 0, "in a boss fight nothing is handed to the guest's game (the gold-masked man's arena)")
        h.hudLayout:UnRegisterBossHPBar(Session.enemyOn(h, "hostboss"))
        s:run(12)
        check(count(h.sent, "^E RUN sp:byguest 1$") == 1, "and once it's over, it is again")
        allErrors(s)
    end
    do
        local w = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, true, ENEMIES)
        w.pcs[2].joinAt = w.pcs[1].now + 8
        w:run(3)
        Session.moveTo(w.pcs[1], 0, 0)
        w:run(2)
        bossStart(w)
        w:run(6)
        local late = w.pcs[2]
        check(net(late).watchingFight == true, "(a guest who joins in a fight watches it)")
        w:run(35)
        local cmc = field(late.pawn, "CharacterMovement")
        check(net(late).watchingFight ~= true and field(cmc, "MovementMode") ~= 0,
            "a fight that never ends: after 30 s they're let go, free to move")
        w:run(10)
        check(net(late).watchingFight ~= true, "and not held again by it")
        -- (The trip to the host still comes when the fight is over.)
        Session.moveTo(late, 9000, 9000)
        w.pcs[1].hudLayout:UnRegisterBossHPBar(Session.enemyOn(w.pcs[1], "boss"))
        w:run(12)
        check(gap(at(late.pawn), at(w.pcs[1].pawn)) < 1000, "and once it's over they're taken to the host, as on any link")
        allErrors(w)
    end
    do
        -- "My friend joins my save and just stands there, no control": F3 while held watching took them in, and the watch
        -- held them again within half a second, frozen in the arena, the camera on the host, at 1 health.
        local w = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, true, ENEMIES)
        w.pcs[2].joinAt = w.pcs[1].now + 8
        w:run(3)
        Session.moveTo(w.pcs[1], 0, 0)
        w:run(2)
        bossStart(w)
        w:run(6)
        local late = w.pcs[2]
        check(net(late).watchingFight == true, "(a joiner watches the host's fight)")
        local went = late.env.PBZ.coop.joinFarFight()
        w:run(3)
        local cmc = field(late.pawn, "CharacterMovement")
        check(went == true and net(late).watchingFight ~= true and not late.env.PBZ.game.isSpectating()
            and field(cmc, "MovementMode") ~= 0, "F3 while watching: in, free to move, the camera their own")
        w:run(5)
        check(net(late).watchingFight ~= true and field(cmc, "MovementMode") ~= 0, "and not held again by the watch")
        allErrors(w)
    end
end

-- A boss both fight: its death runs the whole way in both worlds, so the guest's game plays the scene after it and brings on
-- the next phase itself. A host who skips that scene skips the guest's.
local function bossScenes()
    part("a boss's scenes")
    local s, h, g = pair()
    Session.moveTo(h, 3000, 2800)
    Session.moveTo(g, 3000, 2700)
    s:run(2)
    local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    h.hudLayout:RegisterBossHPBar(boss)
    s:run(2)
    Fake.put(copy, "dustLoot", 900)
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(3)
    check(field(copy, "realDeath") == true, "the host's boss dies the whole way on the guest's side too: its story goes on there")
    check(Session.dust(g) == 0, "and that death pays the guest nothing of its own: the host's pays both")

    Session.scene(h, true, "Seq023")
    s:run(1)
    Session.scene(g, true, "Seq023")
    s:run(0.5)
    Session.scene(h, false)
    s:run(1)
    check(field(g.scene, "skipped") == 1 and field(g.scene, "playing") == false,
        "the host skips the scene after the fight: the guest's, a moment behind, is skipped too")
    check(count(h.sent, "^E SCENE skip Seq023$") == 1, "told once")

    Session.scene(h, true, "Seq024")
    s:run(1)
    Session.scene(g, true, "Seq024")
    s:run(7.5)
    Session.scene(h, false)
    s:run(1)
    check(field(g.scene, "skipped") == 1 and field(g.scene, "playing") == true,
        "one the host watched to its end isn't cut short on the guest's side")
    check(count(h.sent, "^E SCENE ") == 1, "and nothing is said of it")

    Session.scene(g, false)
    Session.scene(h, true, "Seq025")
    s:run(1)
    Session.scene(h, false)
    s:run(1)
    Session.scene(g, true, "Seq025")
    s:run(1)
    check(field(g.scene, "skipped") == 2, "a scene the host skipped before the guest's began is skipped as it begins")
    allErrors(s)
end

local function fightsAndWhoIsLeft()
    part("a fight, and who's left in it")
    local s, h, g = pair()
    Session.moveTo(g, 3000, 2900)
    Session.moveTo(h, 30000, 3000)
    s:run(2)
    g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
    s:run(2)
    check(gap(at(h.pawn), at(g.pawn)) > 20000, "a host far off isn't brought into a guest's fight: one player can fight alone")
    h.env.PBZ.coop.joinFarFight()
    s:run(2)
    check(gap(at(h.pawn), at(g.pawn)) < 1000, "F3 takes them in, the arena being apart from where they are")
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
    check(gap(at(ch.pawn), at(cg.pawn)) > 20000, "nor later: nobody is brought in")
    allErrors(c)

    -- The black wall: E beside it, from outside, goes through; from inside it does nothing.
    local w, wh, wg = pair()
    local hostWall, guestWall = Fake.fogWall(wh, 2000, 0, 2000, 6000, 100), Fake.fogWall(wg, 2000, 0, 2000, 6000, 100)
    Session.moveTo(wg, 3000, 2900)
    Session.moveTo(wh, 1500, 3000)
    w:run(1)
    wg.hudLayout:RegisterBossHPBar(Session.enemyOn(wg, "boss"))
    guestWall["Close By Mob Script"](guestWall)
    w:run(3)
    check(rawget(hostWall, "__fields").closed, "the guest's fight closes the host's copy of the wall")
    check(at(wh.pawn).X < 2000, "the host is left outside it")
    wh.keys.E = true
    w:run(0.2)
    wh.keys.E = false
    w:run(1)
    local inside = at(wh.pawn)
    check(inside.X > 2000 and inside.X < 2600 and math.abs(inside.Y - 3000) < 50, "E at the wall: through it, a few metres in")
    wh.keys.E = true
    w:run(0.2)
    wh.keys.E = false
    w:run(1)
    check(at(wh.pawn).X > 2000, "and E again doesn't let them out")
    Session.moveTo(wg, 2300, 4000)
    wg.keys.E = true
    w:run(0.2)
    wg.keys.E = false
    w:run(1)
    check(at(wg.pawn).X > 2000, "nor the one whose fight it is")
    allErrors(w)

    -- No floor past the wall: E leaves the player where they are, never over the drop.
    local v, vh, vg = pair()
    Fake.fogWall(vh, 2000, 0, 2000, 6000, 100)
    Fake.fogWall(vg, 2000, 0, 2000, 6000, 100)
    vh.noFloor = function(l) return l.X > 2000 end
    Session.moveTo(vg, 3000, 2900)
    Session.moveTo(vh, 1500, 3000)
    v:run(1)
    vg.hudLayout:RegisterBossHPBar(Session.enemyOn(vg, "boss"))
    v:run(3)
    vh.keys.E = true
    v:run(0.2)
    vh.keys.E = false
    v:run(1)
    local stayed = at(vh.pawn)
    check(stayed.X < 2000 and math.abs(stayed.Z - 100) < 50, "no floor past it: E leaves them where they stood")
    check(count(vh.logs, "No floor past the fog wall") == 1, "and says why")
    allErrors(v)

    -- A drop just behind the wall, the fight's floor further in: E takes them across to beside the one inside.
    local d, dh, dg = pair()
    Fake.fogWall(dh, 2000, 0, 2000, 6000, 100)
    Fake.fogWall(dg, 2000, 0, 2000, 6000, 100)
    dh.noFloor = function(l) return l.X > 2000 and l.X < 2700 end
    Session.moveTo(dg, 3000, 2900)
    Session.moveTo(dh, 1500, 3000)
    d:run(1)
    dg.hudLayout:RegisterBossHPBar(Session.enemyOn(dg, "boss"))
    d:run(3)
    dh.keys.E = true
    d:run(0.2)
    dh.keys.E = false
    d:run(2)
    local landed = at(dh.pawn)
    check(landed.X > 2700 and math.abs(landed.Z - 100) < 50 and math.abs(landed.X - 3000) < 400,
        "a drop just past the wall: E takes them across to beside the other player, on the fight's floor")
    check(count(dh.logs, "beside the other player") == 1, "and says so")
    allErrors(d)

    -- A wall whose line lies 8 m under the floor (Lei Dang's): E at it still takes them through.
    local u, uh, ug = pair()
    Fake.fogWall(uh, 2000, 0, 2000, 6000, -700)
    Fake.fogWall(ug, 2000, 0, 2000, 6000, -700)
    Session.moveTo(ug, 3000, 2900)
    Session.moveTo(uh, 1500, 3000)
    u:run(1)
    ug.hudLayout:RegisterBossHPBar(Session.enemyOn(ug, "boss"))
    u:run(3)
    uh.keys.E = true
    u:run(0.2)
    uh.keys.E = false
    u:run(2)
    check(at(uh.pawn).X > 2000, "a wall whose line lies 8 m under the floor: E takes them through all the same")
    allErrors(u)

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
    s:run(4)
    check(count(g.trace, "AddWeaponItem") >= 1, "it reaches the guest")
    local asked = false
    for _, line in ipairs(g.trace) do
        if line:find("AddWeaponItem", 1, true) and line:find("true%s+true") then
            asked = true
        end
    end
    check(not asked, "without the game's full-screen question: their game goes on")
    check(count(g.logs, "your partner found something") == 0, "and no tip about it on screen (the user didn't want one)")
    allErrors(s)
end

-- What each player wears is theirs: their figure on the other PC wears it, and follows when they change.
local function looks()
    part("what each player wears")
    local s, h, g = pair()
    local function wear(pc, outfit, hidden)
        Fake.put(field(pc.pawn, "look"), "outfit", outfit)
        Fake.put(field(pc.pawn, "look"), "hidden", hidden)
    end
    wear(h, "Hun_OutFit_MoTian", false)
    wear(g, "Hun_OutFit_JiGuanMoQu", true)
    s:run(3)
    local onHost, onGuest = field(net(h).ghost, "look"), field(net(g).ghost, "look")
    check(field(onHost, "outfit") == "Hun_OutFit_JiGuanMoQu" and field(onHost, "hidden") == true,
        "the guest's figure on the host's PC wears what the guest wears, hat off")
    check(field(onGuest, "outfit") == "Hun_OutFit_MoTian" and field(onGuest, "hidden") == false, "and the host's on the guest's PC, hat on")
    check(field(field(h.pawn, "look"), "outfit") == "Hun_OutFit_MoTian" and field(field(g.pawn, "look"), "outfit") == "Hun_OutFit_JiGuanMoQu",
        "nobody's own clothes change")
    check(field(onHost, "suppressed") == true and field(onHost, "bUseConfiguredAppearance") == true,
        "a figure's look is held as configured, and kept out of this player's save")
    check(field(onHost, "CurrentOutfit"):ToString() == "Hun_OutFit_JiGuanMoQu",
        "and its current outfit is theirs, which its face goes by (it had this player's plain face)")
    wear(h, "Hun_OutFit_Climax", false)
    s:run(2)
    check(field(onGuest, "outfit") == "Hun_OutFit_Climax", "a change shows within a second or two")
    local dressed = field(onGuest, "dressed")
    s:run(35)
    check(field(onGuest, "dressed") == dressed, "the same look told again doesn't dress it again")
    rawset(net(g).ghost, "__alive", false)
    s:run(3)
    check(field(field(net(g).ghost, "look"), "outfit") == "Hun_OutFit_Climax", "a figure made anew (a map change) comes dressed")
    allErrors(s)
end

-- A kick-stone (a boulder shutting a shortcut) kicked away in one world stood in the way in the other.
local function kickStones()
    part("kick-stones")
    local s, h, g = pair()
    local mine = Fake.stone(g, "BP_KickStone_C_1", 300.0, 0.0, 100.0)
    local theirs = Fake.stone(h, "BP_KickStone_C_1", 300.0, 0.0, 100.0)
    s:run(1.5)
    Fake.put(mine, "CurSwitchState", true)
    local rest = { X = 1600.0, Y = -900.0, Z = -640.0 }
    Fake.put(field(mine, "SkeletalMesh"), "at", rest)
    s:run(2)
    check(field(theirs, "CurSwitchState") == false, "a stone isn't told before it has come to rest")
    s:run(3.5)
    local at = field(field(theirs, "SkeletalMesh"), "at")
    check(field(theirs, "CurSwitchState") == true and math.abs(at.X - 1600) < 1 and math.abs(at.Z + 640) < 1,
        "the guest kicks one away: the host's is open too, its boulder where the guest's came to rest")
    s:run(6)
    check(count(h.sent, "KS BP_KickStone_C_1") == 0, "and the host doesn't take it for its own kick and tell it back")
    local far = Fake.stone(g, "BP_KickStone_C_2", 600.0, 0.0, 100.0)
    s:run(1.5)
    Fake.put(far, "CurSwitchState", true)
    s:run(6)
    local late = Fake.stone(h, "BP_KickStone_C_2", 600.0, 0.0, 100.0)
    s:run(1.5)
    check(field(late, "CurSwitchState") == true, "and one not loaded on the host's side then is open when it is")
    allErrors(s)
end

-- Walking, jogging and sprinting: a figure has no stick for its locomotion to read, so it jogged at any speed.
local function gaits()
    part("walking, jogging, sprinting")
    local s, h, g = pair()
    local anim = g.pawn.anim
    rawset(anim, "__name", "PBZ_ABP_Hun_Base_C")
    local function gait(run, sprint)
        Fake.put(anim, "Gameplay Tag Run", run)
        Fake.put(anim, "GameplayTag_IsSprint", sprint)
    end
    local function state()
        return field(field(net(h).ghost, "gaitState"), "state")
    end
    gait(false, false)
    s:run(1)
    check(state() == "CharacterState.Native.Attitude.Walking", "a guest who walks: their figure walks, by the game's own state for it, where it jogged slowly")
    gait(false, true)
    s:run(1)
    check(state() == "CharacterState.Native.Attitude.Sprinting", "sprints when they sprint")
    gait(true, false)
    s:run(1)
    check(state() == "CharacterState.Native.Attitude.Jogging", "and jogs when they jog")
    gait(false, false)
    s:run(1)
    rawset(net(h).ghost, "__alive", false)
    s:run(3)
    check(state() == "CharacterState.Native.Attitude.Walking", "a figure made anew walks too")
    allErrors(s)
end

-- The guard stance (right button held): no montage plays between its enter and exit, and the figure held nothing.
local function guardStance()
    part("the guard stance")
    local ENTER, EXIT = "/PBZCombatAsset/ActorData/Move/AM_Hun_Tang_StanceEnter.AM_Hun_Tang_StanceEnter", "/PBZCombatAsset/ActorData/Move/AM_Hun_Tang_StanceExit.AM_Hun_Tang_StanceExit"
    local s, h, g = pair()
    local anim = field(net(h).ghost, "anim")
    local function playing()
        local m = field(anim, "montage")
        return m and rawget(m, "__path"), m ~= nil and field(anim, "paused") == m
    end
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", true)
    Session.startMove(g, ENTER)
    s:run(0.6)
    Session.endMove(g)
    s:run(1.5)
    local path, held = playing()
    check(path == ENTER and held, "the guest holds the stance: their figure holds its pose, the enter's last frame")
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", false)
    Session.startMove(g, EXIT)
    s:run(0.5)
    path, held = playing()
    check(path == EXIT and not held, "and leaves it with the exit, as they do")
    Session.endMove(g)
    s:run(1)
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", true)
    Session.startMove(g, ENTER)
    s:run(0.6)
    Session.endMove(g)
    s:run(1.5)
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", false)
    s:run(0.5)
    check(field(anim, "montage") == nil, "out of the stance with no exit to play, the held pose goes")
    -- The stance heard only after the enter's own hold came (on a slow link it comes with their place, played behind): the pose
    -- is held all the same, from there.
    s:run(1)
    Session.startMove(g, ENTER)
    s:run(0.9)
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", true)
    s:run(0.4)
    Session.endMove(g)
    s:run(0.7)
    path, held = playing()
    check(path == ENTER and held, "a stance heard after its enter's hold was due still holds the pose")
    Fake.running(g, g.pawn, "GA_Hun_Tang_Stance_C", false)
    s:run(0.5)
    allErrors(s)
end

-- An item in use (a drink from the gourd) shows its effects on the player's body: their figure on the other PC shows them too.
local function itemEffects()
    part("an item's effects")
    local POTION = "/PBZVFXPack/VFX/BattleFX/Common/Potions/NS_Potion_001.NS_Potion_001"
    local s, h, g = pair()
    Fake.effectOn(g, g.pawn, "/PBZVFXPack/VFX/Weapon/NS_Trail.NS_Trail")
    Fake.running(g, g.pawn, "GA_Medicine_Common_Additive_C", true)
    s:run(0.5)
    Fake.effectOn(g, g.pawn, POTION)
    Fake.effectOn(g, g.pawn, "/PBZVFXPack/VFX/Common/NS_RunFootStep_Water_201.NS_RunFootStep_Water_201")
    s:run(1)
    Fake.running(g, g.pawn, "GA_Medicine_Common_Additive_C", false)
    s:run(1)
    local on = h.effectsOn
    check(#on == 1 and on[1].path == POTION and on[1].on == field(net(h).ghost, "Mesh") and on[1].socket == "None",
        "a drink's effect on the guest's body shows on their figure on the host's PC (not what was on them before, nor footsteps)")
    s:run(5)
    Fake.effectOn(g, g.pawn, POTION)
    s:run(1)
    check(#h.effectsOn == 1, "an effect long after the item's use isn't sent")
    s:run(3)
    check(on[1].active == false and on[1].destroyed == true,
        "the drink's effect on the figure ends after a while (the gourd's glow looped on, one more each drink, the frame rate down)")
    -- Two drinks close together: one glow, the new in the old's place.
    for _ = 1, 2 do
        Fake.running(g, g.pawn, "GA_Medicine_Common_Additive_C", true)
        s:run(0.5)
        Fake.effectOn(g, g.pawn, POTION)
        s:run(1)
        Fake.running(g, g.pawn, "GA_Medicine_Common_Additive_C", false)
        s:run(1)
    end
    local lit = 0
    for _, e in ipairs(h.effectsOn) do
        lit = lit + (e.active and 1 or 0)
    end
    check(#h.effectsOn == 3 and lit == 1, "two drinks: one glow on the figure, not two (" .. lit .. " on)")
    allErrors(s)
end

-- A trip: the world goes, and with it the ghost, which the next tick makes again.
local function afterATrip()
    part("arriving on a map")
    local spear = "/PBZCombatAsset/ActorData/Weapon/Spear.Spear"
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
    local cannon = "/PBZCombatAsset/ActorData/Weapon/Cannon.Cannon"
    local s, h, g = pair()
    s:run(3)
    Session.holdEdge(h, cannon, false)
    s:run(1)
    local ghost = ghostOf(g, 1)
    local weapons = field(ghost, "Character Weapons Component")
    check(rawget(field(weapons, "edgeConfig") or {}, "__path") == cannon, "the partner's ghost gets the weapon they've equipped")
    check(field(weapons, "edgeArmed") == false, "put away")
    Session.holdEdge(h, cannon, true)
    Session.edgeMove(h, "/PBZCombatAsset/ActorData/Move/Show.Show")
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
    -- A shot's end can come before the shot (its quick copies lost but the last, the end by the sure lane): then it isn't
    -- fired at all. (Fired, its copy found no end and played on for 30 s.)
    s:run(1.1)
    local fired = #g.fired
    g.inbox[#g.inbox + 1] = "SHOTEND 424242"
    s:run(0.05)
    g.inbox[#g.inbox + 1] = "SHOT " .. flower .. " 10 20 100 0.0 0.0 0.0 424242"
    s:run(0.2)
    check(#g.fired == fired, "a shot whose end came before it isn't fired")
    -- What ends together goes out as one end, not one each (a weapon of flowers put forty a second on the sure lane).
    for i = #h.liveBullets, 1, -1 do
        h.liveBullets[i] = nil
    end
    s:run(1.1)
    local from, made = #h.sent, #g.fired
    for k = 1, 8 do
        Session.bullet(h, h.pawn, flower, 10.0 * k, 20.0, 100.0)
    end
    s:run(0.5)
    for i = #h.liveBullets, 1, -1 do
        h.liveBullets[i] = nil
    end
    s:run(0.5)
    local ends, over = 0, 0
    for k = from + 1, #h.sent do
        ends = ends + (h.sent[k]:find("^E SHOTEND ") and 1 or 0)
    end
    for k = made + 1, #g.fired do
        over = over + (g.fired[k].ended and 1 or 0)
    end
    check(#g.fired == made + 8 and over == 8 and ends == 1,
        "eight shots that end together: all eight copies end, by one event (" .. ends .. " events, " .. over .. " ended)")
    allErrors(s)

    -- A loop that only ends when the ability that fired it says so: the copy ends with the sender's own.
    local e, eh, eg = pair()
    e:run(3)
    local loop = Session.bullet(eh, eh.pawn, flower, 120.0, 340.0, 100.0)
    e:run(1)
    local copy = eg.fired[1] or {}
    check(copy.started == true and copy.ended == false, "a looping effect's copy comes up on the partner's PC")
    e:run(5)
    check(copy.ended == false, "and stays while the sender's does")
    for i = #eh.liveBullets, 1, -1 do
        if eh.liveBullets[i] == loop then
            table.remove(eh.liveBullets, i)
        end
    end
    e:run(1)
    check(copy.ended == true, "the sender's ends: the copy ends with it, by its own end")
    check(count(eh.sent, "^E SHOTEND ") == 1, "told once")
    Session.bullet(eh, eh.pawn, flower, 220.0, 340.0, 100.0)
    e:run(1)
    local orphan = eg.fired[2] or {}
    Session.command(eh, "netoff")
    e:run(32)
    check(orphan.started == true and orphan.ended == true, "and one whose end never comes is over after 30 s")
    allErrors(e)

    -- A particle bullet's copy that ends by its own timer: its look (the level's) is turned off too, then and there. A Wild
    -- Oriole Sword's sword energy stayed in place for good, its bullet gone before the sender's end came.
    local w, wh, wg = pair()
    w:run(3)
    Session.bullet(wh, wh.pawn, flower, 120.0, 340.0, 100.0)
    w:run(1)
    local energy = wg.fired[1] or {}
    check(energy.started == true and energy.fxOn == true, "a sword energy's copy comes up, its look on")
    energy.ended = true             -- (its own timer: the bullet's gone, the sender's end not here yet)
    w:run(1.5)
    check(energy.fxOn == false, "its bullet over here: its look is turned off, not left in place")
    allErrors(w)
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
    Session.command(ph, "onlinepanel press 366 330")       -- (the Players tile: 2 -> 4)
    p:run(1)
    check(ph.files["PhantomPact.ini"]:find("Secret = hunter2\nPartySize = 4\n", 1, true) ~= nil, "a setting added to an ini with no line end at its end keeps both")
    Session.command(ph, "onlinepanel press 366 330")
    p:run(1)
    check(ph.files["PhantomPact.ini"]:find("PartySize = 6", 1, true) ~= nil, "a click moves the Players tile on to its next choice")
    check(ph.env.PBZ.freetravel.on == true, "free bell travel is on with no line for it in the ini")
    Session.command(ph, "onlinepanel press 784 163")       -- (the Free Bell Travel tile)
    p:run(1)
    check(ph.files["PhantomPact.ini"]:find("FreeBellTravel = Off", 1, true) ~= nil and ph.env.PBZ.freetravel.on == false,
        "the Free Bell Travel tile turns it off, kept in the ini and in force at once")
    Session.command(ph, "onlinepanel press 280 150")       -- (Revive: still to come, nothing to choose)
    Session.command(ph, "onlinepanel press 784 163")
    p:run(1)
    check(ph.files["PhantomPact.ini"]:find("FreeBellTravel = On", 1, true) ~= nil and ph.env.PBZ.freetravel.on == true
        and not ph.files["PhantomPact.ini"]:find("Revive", 1, true), "and back on; the Revive tile writes nothing")
    allErrors(p)

    -- The host's rules count for everyone (rules.lua): Free Bell Travel, TP > Partner, PvP.
    local r, rh, rg = pair()
    check(rg.env.PBZ.rules.following() == true and rg.env.PBZ.freetravel.on == true, "a linked guest follows the host's rules")
    Session.command(rh, "onlinepanel press 700 500")
    Session.command(rh, "onlinepanel press 784 163")        -- the host: Free Bell Travel off
    Session.command(rh, "onlinepanel press 116 163")        -- and TP > Partner on
    Session.command(rh, "onlinepanel press 617 163")        -- and Partner On The Map off
    r:run(1)
    check(rg.env.PBZ.freetravel.on == false and rg.env.PBZ.partner.teleport == true, "the host's change reaches the guest at once")
    check(rg.env.PBZ.hud.on == false and rg.env.PBZ.mapicon.on == false, "the map mark too")
    check(rh.env.PBZ.rules.following() == false, "the host follows nobody")
    check(rg.env.PBZ.mapfog.on == false and rh.env.PBZ.mapfog.on == false, "the map fog stays by default (ClearMapFog Off)")
    rh.env.PBZ.mapfog.on = true
    r:run(1)
    check(rg.env.PBZ.mapfog.on == true, "the host clears it: for the guest too")
    Session.command(rg, "onlinepanel press 700 500")
    rg.logs = {}
    Session.command(rg, "onlinepanel press 784 163")        -- the guest tries to turn it back on
    r:run(1)
    check(rg.env.PBZ.freetravel.on == false and not (rg.files["PhantomPact.ini"] or ""):find("FreeBellTravel", 1, true)
        and count(rg.logs, "Only the host's setting counts%.") == 1, "a guest's click changes nothing, and says why")
    check(count(rg.logs, "row freetravel") == 0, "(no slip)")
    Session.command(rg, "netoff")
    r:run(1)
    check(rg.env.PBZ.rules.following() == false and rg.env.PBZ.freetravel.on == true and rg.env.PBZ.partner.teleport == false
        and rg.env.PBZ.hud.on == false and rg.env.PBZ.mapicon.on == true and rg.env.PBZ.mapfog.on == false,
        "sync off: the guest's own rules come back")
    allErrors(r)

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

    -- Both down: back to the bell. Player 2 down is held at a sliver of health, never dead, and was taken for up.
    local w, wpc, wstate = localGame()
    w:run(1.5)
    Fake.setHealth(wstate.p2Pawn, 1)
    w:run(1.5)
    Fake.setHealth(wpc.pawn, 0)
    w:run(7)
    check(count(wpc.logs, "Both players are down") == 1 and count(wpc.logs, "Player 1 is back") == 0,
        "both down: back to the bell, not player 1 up beside player 2's body")
    allErrors(w)

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

    local train, tpc, tstate = localGame()
    train:run(1.5)
    local menu = { IsValid = function() return true end, IsVisible = function() return true end }
    tpc.bellMenus[1] = menu
    train:run(0.6)
    local skill = Fake.ability(tpc, tpc.pawn, "GA_AddMedicineUseTime_C")
    tpc.bellMenus[1] = nil
    train:run(2.5)
    check(Fake.given(tstate.p2Pawn)[1] == skill, "a skill trained at a bell reaches player 2's Soul too")
    Fake.setHealth(tstate.p2Pawn, 1)
    train:run(9)
    check(Fake.given(tstate.p2Pawn)[1] == skill, "and each new one")
    allErrors(train)

    local read, rpc0, rstate0 = localGame()
    read:run(1.5)
    Fake.put(rstate0.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    local petal = Fake.flow(rpc0, "BP_FlowInteract_MemoryFlower_C", 8000.0, 0.0, 100.0)
    read:run(0.5)
    local comp0 = field(rstate0.p2Pawn, "promptComp")
    check(comp0 ~= nil and field(comp0, "shown") == true, "a Memory Flower is offered to player 2")
    Session.press2(read, "Gamepad_FaceButton_Right")
    local used1 = field(field(rpc0.pawn, "interact"), "used")
    check(used1[#used1] == petal, "and starts from player 1's side, as a talk does, the only side its story starts from")
    allErrors(read)

    local flower, fpc0, fstate0 = localGame()
    local asked = Fake.flower(fpc0, 100.0, 300.0, 100.0)
    local camera = Fake.cameras(fpc0, fstate0.p2Controller)
    flower:run(2.5)
    check(#asked == 0, "what's in the optimizer and isn't a Soul is asked for nothing a Soul has: UE4SS's answer killed the game")
    check(camera.ViewPitchMax == 45.0 and camera.ViewPitchMin == -80.0, "player 2's camera tilts as far as player 1's")
    allErrors(flower)

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
    local rang = field(field(lpc.pawn, "interact"), "used")
    check(#rang == 0, "as a load ends nothing's started under the page that's about to go up")
    late:run(1.6)
    Session.press2(late, "Gamepad_FaceButton_Right")
    check(#rang == 1, "a moment later it is")
    allErrors(late)

    local b, bpc, bstate = localGame()
    b:run(1.5)
    Fake.put(bstate.p2Pawn, "loc", { X = 8000.0, Y = 100.0, Z = 100.0 })
    local ringing = Fake.switch(bpc, "BP_Bell_C", 8000.0, 0.0, 100.0, true)
    b:run(0.5)
    Session.press2(b, "Gamepad_FaceButton_Right")
    check(field(bpc.controller, "Pawn") == bpc.pawn, "player 2 rings a bell: each controller keeps its own Soul")
    local rest = field(field(bpc.pawn, "interact"), "used")
    check(rest[#rest] == ringing, "and player 1 rests: what the bell's menu does it does to the player")
    check(math.abs(field(bpc.pawn, "loc").X - 8000) < 1000, "beside player 2, from wherever they were")
    allErrors(b)

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

-- The host's rules and what each player wears are told when they change and to whoever starts sync or joins, not on a timer:
-- the sure lane brings a telling to everyone linked. (Every 5 s and every 30 s they went again, and on a lossy link each one
-- held up the deaths queued behind it; one who joined a party heard the rules only at the next of those.)
local function toldOnChange()
    part("told when it changes, not on a timer")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    local h, late = s.pcs[1], s.pcs[3]
    late.joinAt = h.now + 9
    local joinedAt, rulesAt = nil, nil
    s:run(14, function()
        joinedAt = joinedAt or (net(late).party and late.now)
        rulesAt = rulesAt or (late.env.PBZ.rules.following() and late.now)
    end)
    check(joinedAt and rulesAt and rulesAt - joinedAt < 1.0,
        "a guest who joins the party follows the host's rules within a second of joining (" .. tostring(joinedAt and rulesAt and rulesAt - joinedAt) .. " s)")
    local from = {}
    for i, pc in ipairs(s.pcs) do
        from[i] = #pc.sent
    end
    s:run(31)
    local again = 0
    for i, pc in ipairs(s.pcs) do
        for k = from[i] + 1, #pc.sent do
            if pc.sent[k]:find("^%S+ RULES ") or pc.sent[k]:find("^%S+ LOOK ") then
                again = again + 1
            end
        end
    end
    check(again == 0, "and in 31 s with nothing changed, no one tells their rules or clothes again (" .. again .. " times)")
    allErrors(s)
end

-- Reviving (Revive = On, two players): what the downed player's PC tells the partner while down, and what a strike counts for.
local function reviving()
    part("reviving")
    local r, rh, rg = pair()
    Session.moveTo(rh, 0, 0)
    Session.moveTo(rg, 300, 0)
    Session.command(rh, "revive on")
    Session.command(rg, "revive on")
    r:run(1)
    local gauges, event = {}, rg.env.PBZ.link.event
    rg.env.PBZ.link.event = function(line)
        local seconds = line:match("^G %S+ %S+ (%S+)$")
        if seconds then
            gauges[#gauges + 1] = { at = rg.now, seconds = tonumber(seconds) }
        end
        return event(line)
    end
    Fake.setHealth(rg.pawn, 1)
    r:run(6)
    rg.env.PBZ.link.event = event
    -- The partner's ring shows the timer from these: a step at a time, as the downed player's own goes, not one or two
    -- at once, once a second.
    local jump, wait = 0, 0
    for i = 2, #gauges do
        local a, b = gauges[i - 1], gauges[i]
        jump = math.max(jump, math.floor(a.seconds / 15 * 24 + 0.5) - math.floor(b.seconds / 15 * 24 + 0.5))
        wait = math.max(wait, b.at - a.at)
    end
    check(#gauges >= 6 and jump <= 1 and wait <= 1.05,
        string.format("down, the partner's timer ring goes a step at a time (%d G, %d steps at most, %.2f s apart at most)", #gauges,
            jump, wait))
    -- A strike counts for the time since the striker's one before (two delivered together are both whole), but not this
    -- down's first: theirs was at the down before, and a moment before made it a fraction of a hit.
    local function points()
        rg.logs = {}
        Session.command(rg, "revive")
        r:run(0.6)                  -- (cmd.txt is read every half second)
        for _, l in ipairs(rg.logs) do
            local p = l:match("points (%d+)/40")
            if p then
                return tonumber(p)
            end
        end
    end
    local before = points()
    rg.inbox[#rg.inbox + 1] = "STRIKE 0.30"
    r:run(0.1)
    local first = points()
    rg.inbox[#rg.inbox + 1] = "STRIKE 0.30"
    r:run(0.1)
    local second = points()
    check(before == 40 and first == 20 and second == 14,
        string.format("this down's first strike counts whole (%s -> %s), the next by its gap (-> %s)", tostring(before),
            tostring(first), tostring(second)))
    rg.inbox[#rg.inbox + 1] = "STRIKE 0.95"
    r:run(0.5)
    allErrors(r)
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

    -- Boss poise (CoopBossPoise, 200 when the ini has none): bosses take half the poise damage, on every PC; nobody else.
    local function poise(pc, id)
        return Session.enemyOn(pc, id).AttributeSetBase.TakenReductionMultiplier_Poise.CurrentValue
    end
    check(everyone(v, function(pc) return math.abs(poise(pc, "boss") - 0.5) < 1e-6 end), "boss poise: the boss takes half the poise damage, on every PC")
    check(everyone(v, function(pc) return poise(pc, "thug1") == 1 end), "and an enemy that isn't a boss takes it all")
    check(count(v.pcs[1].logs, "at 200%% poise") == 1, "said once for the boss")
    local p = party(nil, "CoopBossPoise = 100\n")
    p:run(6)
    check(everyone(p, function(pc) return poise(pc, "boss") == 1 end), "CoopBossPoise = 100: bosses as the game has them")
    allErrors(p)
    local q = party(nil, "CoopBossPoise = 400\n")
    q:run(6)
    check(math.abs(poise(q.pcs[1], "boss") - 0.25) < 1e-6, "CoopBossPoise = 400: a quarter")
    allErrors(q)
end

-- A QTE that never ends on a guest (Xiaoxue's third phase, failed: the grab's end is the boss's, which the copy doesn't run):
-- after a while it's ended the game's way and the player's controls come back.
local function stuckQte()
    part("a QTE with no end")
    local s, h, g = pair()
    s:run(2)
    local function grab(pc)
        local ctrl = pc.env.PBZ.getPlayer1()
        local q = { active = true, finished = 0 }
        local obj = { IsValid = function() return true end, GetFName = function() return { ToString = function() return "QTE_Grab" end } end }
        Fake.put(ctrl, "QTEManager", { ForEach = function(_, fn)
            if q.active then
                fn({ get = function() return obj end }, { get = function() return obj end })
            end
        end })
        Fake.put(ctrl, "FinishQTEObject", function(_, o)
            if o == obj then
                q.finished, q.active = q.finished + 1, false
            end
        end)
        return q
    end
    local q = grab(g)
    s:run(6)
    check(q.active and q.finished == 0, "a QTE going on isn't touched")
    s:run(8)
    check(not q.active and q.finished == 1 and count(g.logs, "A QTE ran 12 s with no end") == 1,
        "one that runs on: ended the game's way, the controls given back, and said")
    local hq = grab(h)
    s:run(15)
    check(hq.active and hq.finished == 0, "never on the host, whose boss runs its own grab to the end")
    allErrors(s)
    -- (Inside a scene the watch was blind, and one that held the player through a scene was never let go. A real one can run
    -- in a long scene, so there it's given 30 s.)
    local t, _, tg = pair()
    t:run(2)
    local tq = grab(tg)
    Session.scene(tg, true, "Seq_QTE")
    t:run(15)
    check(tq.active and tq.finished == 0, "in a scene, a QTE isn't ended at 12 s")
    t:run(18)
    check(not tq.active and tq.finished == 1, "but one that runs on there is, at 30 s")
    Session.scene(tg, false)
    allErrors(t)
end


-- A player report (11-07): a guest emptied a boss's posture bar and it never filled again, so every guest hit staggered it.
-- The host wrote its bar to 0 from the guest's report, the game's own break never ran there, and the guest's copy, filled
-- again by its own break, was pulled back down to the host's 0.
local function emptiedPosture()
    part("a posture bar a guest empties")
    local s, h, g = pair()
    s:run(2)
    local hostE, copy = Session.enemyOn(h, "thug1"), Session.enemyOn(g, "thug1")
    local function bar(e)
        return rawget(e, "__fields").AttributeSetBase.Shachi
    end
    local function setBar(e, v)
        Fake.put(bar(e), "CurrentValue", v)
        Fake.put(bar(e), "BaseValue", v)
    end
    local max = select(3, Fake.health(hostE))
    setBar(copy, 1)                             -- (the game holds an emptied bar at 1, not 0)
    s:run(1)
    check(bar(hostE).CurrentValue <= 1.5, "the guest empties the bar: the host's boss is emptied too")
    setBar(copy, max)                           -- (the guest's own game filled its copy after its break)
    s:run(2)
    check(bar(copy).CurrentValue == max, "the guest's copy, filled again by its break, isn't pulled back down to the host's empty bar")
    s:run(5)
    check(bar(hostE).CurrentValue == max and count(h.logs, "Posture bar a partner emptied") == 1,
        "the host's bar, never filled by a break of the game's own, is filled after 6 s, and said")
    s:run(2)
    check(bar(copy).CurrentValue == max, "and the guest's stays full: the next hit is no break")
    setBar(copy, 0)
    s:run(1)
    setBar(hostE, max)                          -- (this time the game's own break filled it)
    s:run(8)
    check(count(h.logs, "Posture bar a partner emptied") == 1, "a bar the game filled itself is left alone")
    allErrors(s)
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
    check(shown == 0, "and no compass for it: it is gone (1.6.6) (" .. shown .. ")")
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

    -- A boss the host has beaten, fought by one guest: every guest hears so, and another whose save has it beaten too
    -- doesn't bring it back for that fight.
    local t = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
    local th, ta, tb = t.pcs[1], t.pcs[2], t.pcs[3]
    Fake.put(th.spawners[Session.indexOf(th, "boss")], "record", false)
    table.remove(th.enemies, Session.indexOf(th, "boss"))      -- (beaten there: gone)
    Session.moveTo(th, 30000, 3000)                             -- (far off: nobody asks after it before the fight)
    Fake.put(tb.spawners[Session.indexOf(tb, "boss")], "record", false)
    local hers = Session.enemyOn(tb, "boss")
    Fake.setHealth(hers, 0)
    Fake.put(hers, "dead", true)
    t:run(5)
    ta.hudLayout:RegisterBossHPBar(Session.enemyOn(ta, "boss"))
    t:run(3)
    check(count(tb.logs, "is back for their fight") == 0, "another guest's save that has it beaten keeps it so")
    check(count(tb.logs, "The host has beaten") >= 1 and count(t.pcs[4].logs, "The host has beaten") >= 1,
        "and every guest hears the host has beaten it, not just the one fighting")
    allErrors(t)

    -- The host's own fight, on a guest: the host is that guest's partner already, not one more.
    local u = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    local uh, ug = u.pcs[1], u.pcs[2]
    Fake.fogWall(ug, 2000, 0, 2000, 6000, 100)
    Session.moveTo(uh, 3000, 2900)
    Session.moveTo(ug, 1500, 3000)
    u:run(5)
    local before = #net(ug).peerList
    uh.hudLayout:RegisterBossHPBar(Session.enemyOn(uh, "boss"))
    u:run(3)
    ug.keys.E = true
    u:run(0.2)
    ug.keys.E = false
    u:run(1)
    check(at(ug.pawn).X > 2000, "a guest goes through the wall into the host's fight")
    check(#net(u.pcs[2]).peerList == before, "the host's fight adds no one to a guest's players (" .. before .. " -> " .. #net(u.pcs[2]).peerList .. ")")
    allErrors(u)
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
    -- (One Mode tile, which a click moves to its other choice: each use below comes from the other.)
    local LOCAL, MULTIPLAYER = "onlinepanel press 533 330", "onlinepanel press 533 330"
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
    check(n == 0 and dots(s.pcs[3]) == 0, "no compass, on the host or a guest: it is gone (1.6.6) (" .. n .. ")")
    s.pcs[4].map = "Map_Other"
    s:run(6)
    n = dots(h)
    check(n == 0, "one on another map: still no compass (" .. n .. ")")
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
    Session.command(h, "onlinepanel press 366 330")      -- the Players tile: 2 -> 4
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("PartySize = 4\n", 1, true) ~= nil, "4 is kept in the ini")
    check(h.files["PhantomPact.ini"]:find("Role = Host\n", 1, true) ~= nil and h.files["PhantomPact.ini"]:find("CoopEnemyHealth = 150\n", 1, true) ~= nil, "and nothing else moves")
    Session.command(h, "onlinepanel press 366 330")      -- 6
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("PartySize = 6\n", 1, true) ~= nil, "6 too")
    Session.command(h, "onlinepanel press 366 330")      -- and round to 2
    s:run(1)
    check(h.files["PhantomPact.ini"]:find("PartySize = 2\n", 1, true) ~= nil, "and 2")
    Session.command(h, "onlinepanel press 47 94")        -- the TP tile, at its very corner
    Session.command(h, "onlinepanel press 400 470")      -- under the tiles: nothing
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

-- Six players (PartySize = 6): health and posture stop at four players' numbers, and every enemy near a player has a ghost
-- twin (twins.lua), on the host and on each guest under the same id.
local function sixPlayers()
    part("six players and ghost twins")
    local function twinsOn(pc)
        local out = {}
        for _, e in ipairs(pc.enemies) do
            local id = pc.env.PBZ.game.twinId(e:GetAddress())
            if id and e:IsValid() then
                out[id] = e
            end
        end
        return out
    end
    local function size(t)
        local n = 0
        for _ in pairs(t) do
            n = n + 1
        end
        return n
    end
    local SIX = { "Host", "Guest", "Guest", "Guest", "Guest", "Guest" }
    local s = Session.new(SIM_SCRIPTS, SIX, 6, ENEMIES)
    for i = 2, 6 do
        Session.moveTo(s.pcs[i], 200 * i, 0)
    end
    s:run(14)
    local h = s.pcs[1]
    check(net(h).party == 6 and net(s.pcs[6]).slot == 6, "a host with PartySize 6 has six places, and the last guest is number 6")
    Session.command(h, "onlinepanel status")
    Session.command(s.pcs[6], "onlinepanel status")
    s:run(1)
    check(count(h.logs, "Players: 6 of 6%. You're the host") == 1 and count(s.pcs[6].logs, "Players: 6 of 6%. You're player 6 %(pink%)%.") == 1,
        "the panel says six of six, and player 6 is pink")
    -- The map and the HUD stretch to five others, each in their own colour.
    h.mapOpen = true
    s:run(2)
    local pointers, colours, distinct = 0, {}, 0
    for _, w in ipairs(h.mapWidgets or {}) do
        if field(w, "visibility") == 3 then
            pointers = pointers + 1
            local c = field(w, "colour")
            local key = c and string.format("%.2f %.2f %.2f", c.R or 0, c.G or 0, c.B or 0) or "none"
            if not colours[key] then
                colours[key] = true
                distinct = distinct + 1
            end
        end
    end
    check(pointers == 5 and distinct == 5, "the open map: a pointer for each of the five others, each its own colour (" .. pointers .. ", " .. distinct .. ")")
    h.mapOpen = false
    s:run(1)
    s.pcs[6].map = "Map_Other"
    s:run(2)
    Session.command(h, "onlinepanel status")
    s:run(1)
    check(count(h.logs, "Players: 6 of 6") >= 2, "one on another map still counts as connected")
    s.pcs[6].map = h.map
    s:run(2)
    local _, hp, posture = Fake.health(Session.enemyOn(h, "thug1"))
    check(hp == 1500 and math.abs(posture - 190) < 0.01, "six connected: health and posture stop at four players' 250% and 190%")
    local ht = twinsOn(h)
    local near = { "sp:thug1", "sp:thug2", "sp:near", "sp:boss" }
    local all = true
    for _, id in ipairs(near) do
        local found = false
        for tid in pairs(ht) do
            found = found or tid:match("^tw%d+:(.+)$") == id
        end
        all = all and found
    end
    check(all, "the host makes a twin for each enemy near a player, the boss's too")
    local far = false
    for tid in pairs(ht) do
        far = far or tid:find("toofar", 1, true) ~= nil
    end
    check(not far, "none for enemies far from everyone")
    check(size(ht) == #near and count(h.logs, "Ghost twin for %S+_actor") == 0,
        "exactly one twin each, under the spawner's id (not one more under the actor's name before it's read)")
    check(everyone(s, function(pc, i) return i == 1 or size(twinsOn(pc)) == size(ht) end), "each guest has a copy of every twin, under the host's id")
    local bossTwin
    for tid, e in pairs(ht) do
        if tid:match(":sp:boss$") then
            bossTwin = e
        end
    end
    check(bossTwin ~= nil and h.env.PBZ.game.isBoss(bossTwin) == false, "a boss's twin is never the boss of a fight to the mod")
    local _, twinHp = Fake.health(bossTwin)
    check(twinHp == 5000 * 2.5, "a twin gets the same health as its original")

    -- One twin killed on the host dies on every guest too.
    local thugTwinId, thugTwin
    for tid, e in pairs(ht) do
        if tid:match(":sp:thug1$") then
            thugTwinId, thugTwin = tid, e
        end
    end
    thugTwin:Kill(1)
    s:run(4)
    check(everyone(s, function(pc, i)
        local e = twinsOn(pc)[thugTwinId]
        return i == 1 or (e ~= nil and rawget(e, "__fields").dead == true)
    end), "a twin's death on the host is its death everywhere")
    check(Session.enemyOn(h, "thug1"):IsValid() and not rawget(Session.enemyOn(h, "thug1"), "__fields").dead, "and its original lives on")

    -- A guest's hit and killing blow on a twin: as on any enemy, by its id.
    local nearTwinId
    for tid in pairs(ht) do
        if tid:match(":sp:near$") then
            nearTwinId = tid
        end
    end
    local g = s.pcs[3]
    local onG = twinsOn(g)[nearTwinId]
    local before = select(1, Fake.health(ht[nearTwinId]))
    swing(g, onG, select(1, Fake.health(onG)) - 50)
    s:run(1)
    check(select(1, Fake.health(ht[nearTwinId])) == before - 50, "a guest's hit on a twin lands on the host's twin")
    swing(g, onG, 1)
    s:run(2)
    check(rawget(ht[nearTwinId], "__fields").dead == true, "a guest's killing blow kills the twin on the host")
    check(everyone(s, function(pc, i)
        local e = twinsOn(pc)[nearTwinId]
        return i == 1 or i == 3 or (e ~= nil and rawget(e, "__fields").dead == true)
    end), "and on every other guest")

    -- The boss dies: its twin fades with it.
    Session.enemyOn(h, "boss"):Kill(1)
    s:run(4)
    check(rawget(bossTwin, "__fields").dead == true, "the boss dies, and its twin goes with it")
    check(count(h.logs, "fades with it") == 1, "said once")

    -- A sit at a bell brings no enemy back, and a guest's own death refreshes only that guest's world: the twins stay.
    local liveIds = {}
    for tid, e in pairs(twinsOn(h)) do
        if not rawget(e, "__fields").dead then
            liveIds[#liveIds + 1] = tid
        end
    end
    Session.sit(s.pcs[2])
    s:run(2)
    check(#liveIds > 0 and everyone(s, function(pc)
        for _, tid in ipairs(liveIds) do
            if twinsOn(pc)[tid] == nil then
                return false
            end
        end
        return true
    end), "a sit at a bell leaves every twin where it is, on every PC")
    local g4 = s.pcs[4]
    Session.die(g4)
    s:run(2)
    Session.respawned(g4)
    Session.revive(g4)
    s:run(3)
    check(everyone(s, function(pc)
        for _, tid in ipairs(liveIds) do
            if twinsOn(pc)[tid] == nil then
                return false
            end
        end
        return true
    end), "a guest dies and respawns: the host's twins go on, and that guest still has them")
    allErrors(s)

    -- Four players: no twins. Six with GhostTwins = Off: none either.
    local f = party()
    f:run(10)
    check(size(twinsOn(f.pcs[1])) == 0 and count(f.pcs[1].logs, "Ghost twin") == 0, "four players: no twins")
    allErrors(f)
    local o = Session.new(SIM_SCRIPTS, SIX, 6, ENEMIES, "GhostTwins = Off\n")
    o:run(12)
    check(size(twinsOn(o.pcs[1])) == 0, "six with GhostTwins = Off: none")
    allErrors(o)

    -- A sixth player who joins late: twins start as the fifth comes, and the one who came last gets a copy of each.
    local late = Session.new(SIM_SCRIPTS, SIX, 6, ENEMIES)
    local lh = late.pcs[1]
    late.pcs[5].joinAt = lh.now + 6
    late.pcs[6].joinAt = lh.now + 14
    for i = 2, 6 do
        Session.moveTo(late.pcs[i], 200 * i, 0)
    end
    late:run(5)
    check(size(twinsOn(lh)) == 0, "four connected: no twins yet")
    late:run(8)
    check(size(twinsOn(lh)) >= 4, "the fifth comes: twins")
    late:run(10)
    check(size(twinsOn(late.pcs[6])) == size(twinsOn(lh)), "the sixth, late, has a copy of every one")
    -- A hidden enemy (an ambush waiting) gets none until it shows.
    allErrors(late)

    -- A guest on another map makes no twins there; the host's death clears them everywhere.
    local m = Session.new(SIM_SCRIPTS, SIX, 6, ENEMIES)
    for i = 2, 6 do
        Session.moveTo(m.pcs[i], 200 * i, 0)
    end
    m.pcs[6].map = "Map_Other"
    m:run(14)
    check(size(twinsOn(m.pcs[6])) == 0 and size(twinsOn(m.pcs[2])) > 0, "a guest on another map makes no twins there, the others do")
    local mh = m.pcs[1]
    local old = twinsOn(mh)
    Session.respawned(mh)
    m:run(1)
    local left = 0
    for _, pc in ipairs({ mh, m.pcs[2], m.pcs[3] }) do
        for id in pairs(twinsOn(pc)) do
            left = left + (old[id] and 1 or 0)
        end
    end
    check(size(old) > 0 and left == 0, "the host dies and respawns: every old twin goes, on every PC")
    m:run(12)
    check(size(twinsOn(mh)) == size(old), "and the enemies get new ones")
    -- A guest rests at a bell: the host's world refreshes for it, and the other guests' copies of the old twins go now,
    -- not 20 s later beside the new ones.
    m:run(8)
    local before = twinsOn(m.pcs[3])
    Session.bell(m.pcs[2])
    m:run(2)
    local stale = 0
    for id in pairs(twinsOn(m.pcs[3])) do
        stale = stale + (before[id] and 1 or 0)
    end
    check(size(before) > 0 and stale == 0, "a guest rests at a bell: the other guests' copies of the old twins go at once")
    -- Two leave, four are left: after a while the twins go, everywhere.
    m:run(8)
    Session.command(m.pcs[5], "netoff")
    Session.command(m.pcs[6], "netoff")
    m:run(30)
    check(size(twinsOn(mh)) == 0 and size(twinsOn(m.pcs[2])) == 0, "down to four players: the twins go, on every PC")
    allErrors(m)
end

-- Gaps (found by chaos.lua): a guest who misses deaths, through a short gap, a long one, or one the host restarted sync in,
-- still has those enemies dead once back.
local function gaps()
    part("deaths missed in a gap")
    -- The host's re-tell after a short gap: deaths the guest has handled already cost it no map search (each one was a
    -- FindAllOf of the spawners, and 40 held one frame for 100-160 ms); a death it missed in the gap still comes through.
    do
        local r, rh, rg = pair()
        Session.enemyOn(rh, "thug1"):Kill(1)
        Session.enemyOn(rh, "thug2"):Kill(1)
        r:run(3)
        check(count(rh.sent, "^E N ") > 0 and count(rh.sent, "^E N ") == count(rh.sent, "^Q NQ "),
            "each enemy's number goes on the quick lane too")
        local searches, find = 0, rg.env.FindAllOf
        rg.env.FindAllOf = function(class)
            if class == "AISpawner" then
                searches = searches + 1
            end
            return find(class)
        end
        searches = 0
        r:run(6)
        local quiet = searches              -- (the game's own refresh of its spawner list, now and then)
        local toldBefore = count(rh.sent, "^E K ")
        rg.cut = true
        Session.enemyOn(rh, "near"):Kill(1)
        r:run(5)
        rg.cut = false
        rg.logs = {}
        searches = 0
        r:run(6)
        check(count(rh.sent, "^E K ") > toldBefore + 1, "(the host told them all again)")
        check(field(Session.enemyOn(rg, "near"), "dead") == true, "the death missed in the gap comes through")
        check(count(rg.logs, "Host says %S*thug%d died") == 0, "the ones handled already aren't done again")
        check(searches <= quiet + 1, string.format("and the whole re-tell costs at most one map search more than none (%d, %d quiet)",
            searches, quiet))
        -- (Review of the above.) One batch's map of the spawners: the first live one of an id, as the search before it took.
        -- One still listed as its level goes, ahead of the live one, hid it for the whole batch.
        local gone = Fake.enemy(rg, "thug2", THUG, -9000.0, 0.0, 100.0, 600, 100)
        local goneSpawner = table.remove(rg.spawners)
        rawset(goneSpawner, "__alive", false)
        rawset(gone, "__alive", false)
        table.insert(rg.spawners, 1, goneSpawner)
        local g2 = rg.env.PBZ.game
        g2.beginBatch()
        local inBatch = g2.isBeaten("sp:thug2")
        g2.endBatch()
        table.remove(rg.spawners, 1)
        check(inBatch ~= nil, "a batch finds the live spawner of an id, not one that's going ahead of it in the list")
        -- A load from the title screen: a copy the host killed can come back with it, a new body, where this save didn't
        -- have that death. Out of this world's reach as the host tells its deaths again after the load's silence, the re-tell
        -- passed it over as handled, and nothing put it down once they came by: it stood there, alive, for good.
        local i = Session.indexOf(rg, "thug1")
        local old = Session.enemyOn(rg, "thug1")
        local at = field(old, "loc")
        Session.moveTo(rh, -9000, 0)
        Session.moveTo(rg, -9000, 500)
        r:run(2)
        rawset(rg.pawn, "__alive", false)              -- (no body in the world: a load from the title, not a trip)
        Session.loadMap(rg)
        rawset(rg.pawn, "__alive", true)
        rawset(old, "__alive", false)
        local back = Fake.enemy(rg, "thug1-back", THUG, at.X, at.Y, at.Z, 600, 100)
        table.remove(rg.spawners)                      -- (its own spawner goes: thug1's made it)
        Fake.put(rg.spawners[i], "SpawnedAI", back)
        rg.cut = true
        r:run(5)
        rg.cut = false
        r:run(6)
        Session.moveTo(rh, 0, 0)
        Session.moveTo(rg, 500, 0)
        r:run(8)
        check(field(back, "dead") == true, "a copy the host killed, back alive with a load from the title, is put down when they come by")
        -- And a batch never ended (an error between its ends) is let go, not used by the next turn that asks: a second
        -- later, with no frame between to end it, a spawner made since is found.
        g2.beginBatch()
        g2.isBeaten("sp:thug2")
        local live = rg.spawners[Session.indexOf(rg, "thug2")]
        rawset(live, "__alive", false)
        local again = Fake.enemy(rg, "thug2", THUG, -1800.0, 200.0, 100.0, 600, 100)
        for _, pc in ipairs(r.pcs) do
            pc.now = pc.now + 1
        end
        local later = g2.isBeaten("sp:thug2")
        g2.endBatch()
        rawset(live, "__alive", true)
        rawset(again, "__alive", false)
        rawset(table.remove(rg.spawners), "__alive", false)
        check(later ~= nil, "a batch left open doesn't outlive its frame: a spawner since is found")
        allErrors(r)
    end
    local s = party(nil, nil, { "Host", "Guest", "Guest" })
    local h, a = s.pcs[1], s.pcs[2]
    Session.moveTo(a, 400, 0)
    Session.moveTo(s.pcs[3], 600, 0)
    s:run(3)
    a.cut = true
    Session.enemyOn(h, "near"):Kill(1)
    s:run(5)
    a.cut = false
    s:run(6)
    check(field(Session.enemyOn(a, "near"), "dead") == true, "a 5 s gap: the death in it is told again once they're back")
    a.cut = true
    Session.enemyOn(h, "thug1"):Kill(1)
    s:run(16)
    a.cut = false
    s:run(6)
    check(field(Session.enemyOn(a, "thug1"), "dead") == true, "a gap long enough to count as gone: the same")
    a.cut = true
    Session.enemyOn(h, "thug2"):Kill(1)
    s:run(2)
    Session.command(h, "netoff")
    s:run(1)
    Session.command(h, "neton host")
    s:run(4)
    a.cut = false
    Session.moveTo(a, -1500, 200)
    s:run(10)
    check(field(Session.enemyOn(a, "thug2"), "dead") == true, "the host restarts sync while they're away: still told")
    check(field(Session.enemyOn(s.pcs[3], "thug2"), "dead") == true, "and the one who was there all along has it dead too")
    allErrors(s)

    -- (Found by an agent's review.) A guest's rest on another map refreshes nothing here: the host keeps what it told dead.
    local q = party(nil, nil, { "Host", "Guest", "Guest" })
    local qh, q3 = q.pcs[1], q.pcs[3]
    Session.moveTo(q.pcs[2], 400, 0)
    q:run(3)
    Session.enemyOn(qh, "near"):Kill(1)
    q:run(3)
    q3.map = "Map_Other"
    q:run(2)
    Session.bell(q3)
    q:run(2)
    check(net(qh).deadSent["sp:near"] == true, "a guest's rest on another map: the host still knows what it told dead")

    -- Another guest's boss fight isn't the host's on the other guests.
    q3.map = qh.map
    Session.moveTo(q3, 2800, 3000)
    q:run(3)
    q3.hudLayout:RegisterBossHPBar(Session.enemyOn(q3, "boss"))
    q:run(3)
    check(net(q.pcs[2]).hostBosses["sp:boss"] == nil, "a guest's boss fight, passed on to another guest, isn't taken for the host's")
    allErrors(q)

    -- A guest syncing anew gets the host's bag; the others, past their first merge, aren't sent it again.
    local b = party()
    local bh = b.pcs[1]
    b:run(8)
    local toAll = count(bh.sent, "^E BAG ")
    Session.command(b.pcs[3], "netoff")
    b:run(1)
    Session.command(b.pcs[3], "neton client")
    b:run(8)
    check(count(bh.sent, "^E BAG ") == toAll and count(bh.sent, "^T3 BAG ") >= 1,
        "a guest re-syncing gets the host's bag alone, not every guest again (" .. count(bh.sent, "^T3 BAG ") .. ")")
    allErrors(b)
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
    -- (Gone, or as a clone put away hidden till the next load: a clone isn't destroyed mid-world, see destroyGhost.)
    local other = guest.spawned[2]
    check(net(guest).peerList == nil and (rawget(other, "__alive") == false or field(other, "hidden") == true),
        "the other guest's ghost goes")
    check(rawget(other, "__alive") == false or (field(other, "hidden") == true and field(other, "collision") ~= true),
        "a clone put away is hidden, with no collision")
    check(rawget(guest.spawned[1], "__alive") == true and net(guest).ghost == guest.spawned[1], "the host's stays")
    allErrors(s)
end

-- Races in the two-player enemy sync: a killing blow landed as the host takes an enemy back, a body taken for the host's live
-- enemy, and a boss fight the host never joined coming back at the guest's death.
local function syncRaces()
    part("races in the enemy sync")
    local list = { { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 } }
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 11000, 0)
    s:run(3)
    check(net(g).mine["sp:byguest"] == true, "(apart: the guest's game runs it)")
    local onH, onG = Session.enemyOn(h, "byguest"), Session.enemyOn(g, "byguest")
    local handlers = g.env.PBZ.coop.handlers
    local run = handlers.RUN
    handlers.RUN = function(rest, from)
        run(rest, from)
        if rest == "sp:byguest 0" then
            swing(g, onG, 0)            -- (the killing blow, landed just as the host took it back)
            Fake.put(onG, "dead", true)
        end
    end
    Session.moveTo(h, 11000, 300)       -- together: the host takes it back
    s:run(3)
    handlers.RUN = run
    check(count(h.sent, "^E RUN sp:byguest 0$") == 1, "(together: the host took it back)")
    check(count(g.sent, "^E GK sp:byguest$") == 1, "a kill landed as the host takes an enemy back is told to the host")
    check(select(1, Fake.health(onH)) == 0 or field(onH, "dead") == true, "and the enemy dies there too")
    allErrors(s)

    local b, _, bg = pair()
    local body = Session.enemyOn(bg, "thug1")
    Fake.setHealth(body, 0)
    Fake.put(body, "dead", true)        -- (dead here only, its kill never told)
    b:run(8)
    check(count(bg.logs, "brought back while you play together") == 1,
        "a body under the id of the host's live enemy isn't taken for it: that enemy is brought back")
    allErrors(b)

    local c, ch, cg = pair()
    Session.moveTo(ch, -30000, 0)       -- far off: the host never joins
    Session.moveTo(cg, 2800, 2800)
    c:run(2)
    local boss = Session.enemyOn(cg, "boss")
    cg.hudLayout:RegisterBossHPBar(boss)
    c:run(3)
    Session.die(cg)
    cg.hudLayout:UnRegisterBossHPBar(boss)
    c:run(2)
    Session.respawned(cg)
    Session.revive(cg)
    c:run(4)
    check(next(net(cg).pendingBosses) == nil and not cg.env.PBZ.game.bossFightActive(),
        "a boss fight the host never joined doesn't come back at the guest's death")
    allErrors(c)

    local r, _, rg = pair()
    bossStart(r)
    r:run(2)
    check(next(net(rg).partnerBosses) ~= nil, "(the guest is shown the host's fight)")
    Session.command(rg, "netoff")
    r:run(1)
    check(next(net(rg).partnerBosses) == nil, "(and leaves: shown no more)")
    Session.command(rg, "neton client")
    r:run(6)
    check(next(net(rg).partnerBosses) ~= nil or next(net(rg).pendingBosses) ~= nil,
        "a guest who starts sync again in the middle of the host's fight is shown it again")
    allErrors(r)

    -- The host's hit in the round trip after it hands an enemy over, before the guest's first line: told to the guest's game.
    local q = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local qh, qg = q.pcs[1], q.pcs[2]
    q:run(4)
    local qrun = qg.env.PBZ.coop.handlers.RUN
    qg.env.PBZ.coop.handlers.RUN = function() end      -- (its first line as good as never comes)
    Session.moveTo(qh, 10800, 0)
    Session.moveTo(qg, 11000, 0)
    q:run(1)
    Session.moveTo(qh, 0, 0)
    q:run(1, function()
        if not q.given and count(qh.sent, "^E RUN sp:byguest 1$") == 1 then
            q.given = true
        end
    end)
    check(q.given == true, "(apart: the host hands it over)")
    Session.moveTo(qh, 11300, 2500)
    local qonH = Session.enemyOn(qh, "byguest")
    swing(qh, qonH, select(1, Fake.health(qonH)) - 40)
    q:run(0.5)
    qg.env.PBZ.coop.handlers.RUN = qrun
    check(count(qh.sent, "^E D sp:byguest ") == 1, "a host's hit before the guest's first line on an enemy handed over is told")
    allErrors(q)

    local w, _, wg = pair()
    net(wg).hostKilled["sp:thug2"] = true
    wg.env.PBZ.coop.handlers.S(nil, 3)          -- (another guest of a party started over: the host passes it on)
    w:run(1)
    check(net(wg).hostKilled["sp:thug2"] == true, "another guest starting over isn't the host's: what the host killed stays killed")
    allErrors(w)
end

return function(print_, scripts)
    out = print_
    SIM_SCRIPTS = scripts
    joining()
    movesAndGear()
    sharing()
    enemiesAndHits()
    farEnemy()
    guestRunsWhatsNearIt()
    syncRaces()
    hitReactions()
    bossReactions()
    pickupsFresh()
    pickupsShown()
    rests()
    sits()
    sitsForTwo()
    twoSaves()
    otherMaps()
    fightsAndWhoIsLeft()
    beatenInBoth()
    guestSide()
    followTheHost()
    hostsChests()
    looks()
    itemEffects()
    guardStance()
    gaits()
    kickStones()
    hostsEnemiesHere()
    bossScenes()
    playerReports()
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
    targets()
    targetsInParties()
    aiming()
    holding()
    holdingForTwo()
    hostDiesFirst()
    doorsOpenedBefore()
    dustOnlyEarned()
    coopDifficulty()
    lateJoiner()
    lateJoinerGuestFight()
    toldOnChange()
    reviving()
    scaling()
    stuckQte()
    emptiedPosture()
    sixPlayers()
    gaps()
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
