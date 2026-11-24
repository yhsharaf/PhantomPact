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
-- (If it lands: none does on a figure on the player's own side, fakepc's Fake.lands. Says whether it did.)
local function swing(pc, e, health)
    pc.env.PBZ.game.noteLocalMove()
    if not Fake.lands(e) then
        return false
    end
    Fake.setHealth(e, health)
    return true
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
    -- (409: Lua's collector begins a round once the mod's memory has grown by half, set as the mod loads. Read back
    -- through the old setter, which answers what was set. The game's Lua keeps it in quarters: 150 reads 148 there, on
    -- both copies of the bench as built, run249.)
    local pause = collectgarbage("setpause", 150)
    collectgarbage("setpause", pause)
    check(pause >= 144 and pause <= 152, "Lua's collector begins a round at half as much again, set as the mod loads ("
        .. tostring(pause) .. ")")
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
    -- it's the line and not the full-screen card. The key's card goes up with them at a calm moment: pickupsShown.)
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
    Fake.arrive(b, levers[b])                       -- (its player walks up to it, as a press begins)
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
    check(count(h.sent, "^E RUN sp:between ") == 0
        and count(h.sent, "^E RUN sp:byhost ") == 0 and count(h.sent, "^E RUN sp:chasing ") == 0,
        "not one as near the host, nor one by the host or far from both")
    -- (A boss asleep by the guest goes as a thug does: the host's game wakes one for its own player alone. guestRunsItsBoss.)
    check(count(h.sent, "^E RUN sp:bossthere 1$") == 1 and net(g).mine["sp:bossthere"] == true
        and brain(Session.enemyOn(g, "bossthere")) == true,
        "a boss in no fight, clearly nearer the guest: the guest's game runs it too, awake")
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
    -- (Handed back with no movement part at that moment, a boss as a scene began, the bench of 11-17: nothing is set on
    -- it. Each field set so was an error line in the game's log.)
    local cmcH = field(onH, "CharacterMovement")
    rawset(cmcH, "__alive", false)
    Fake.put(cmcH, "bOrientRotationToMovement", "as it was")
    Session.moveTo(g, 12500, 2400)     -- together
    Fake.put(onG, "loc", { X = 12800.0, Y = 1500.0, Z = 100.0 })
    s:run(2)
    check(count(h.sent, "^E RUN sp:byguest 0$") == 1 and net(g).mine["sp:byguest"] == nil, "together again: the host's game runs it")
    check(brain(onH) == true and brain(onG) == false, "its AI back on the host, the guest's copy following the host's again")
    check(field(cmcH, "bOrientRotationToMovement") == "as it was",
        "handed back with no movement part just then: nothing is set on it (" .. tostring(field(cmcH, "bOrientRotationToMovement")) .. ")")
    rawset(cmcH, "__alive", true)
    Fake.put(cmcH, "bOrientRotationToMovement", true)
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

-- A boss the guest goes to first. The host's game wakes a boss for its own player alone, once they're in its arena, and
-- slows it to a stop or puts it away past some 45 m of them: with the host on its way, outside the wall or back at a bell,
-- the guest's boss stood asleep with the host's, its bar up, and never swung ("my friend is host and i guest, the boss cant
-- hit me", 11-15; on the bench, 11-16, 0 hits in 90 s where the host beside it made it 15 in 25 s). So the guest's game
-- runs a boss the guest is at and the host isn't: asleep, and through the guest's fight, till the host is in that fight
-- too (walked in, its own bar, or a blow of theirs from near it), when it's the host's with what health it had left.
local function guestRunsItsBoss()
    part("a boss the guest fights and the host doesn't")
    local list = {
        { "boss", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true },
        { "thug", THUG, 300.0, 0.0, 100.0, 600, 100 },
    }
    local function brain(e)
        return field(field(field(e, "Controller"), "BrainComponent"), "running")
    end
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 4000, 0)         -- the guest by the boss, the host 40 m behind
    s:run(3)
    local onH, onG = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    check(count(h.sent, "^E RUN sp:boss 1$") == 1 and net(g).mine["sp:boss"] == true and brain(onG) == true,
        "a boss asleep, the guest by it and the host 40 m behind: the guest's game runs it, awake")
    check(brain(onH) == false, "and the host's copy follows the guest's")
    -- The guest's fight begins, in its own game: told, shown on the host, and the guest's game's to run all through.
    g.hudLayout:RegisterBossHPBar(onG)
    s:run(3)
    check(net(h).partnerBosses["sp:boss"] == true and net(h).guestRuns["sp:boss"] == true,
        "the guest's fight with it: shown on the host, and still the guest's game's")
    Session.moveTo(h, 3800, 300)       -- the host walks up beside the guest: together, and not in the fight
    s:run(3)
    check(net(h).guestRuns["sp:boss"] == true and count(h.sent, "^E RUN sp:boss 0$") == 0,
        "the host beside the guest, not in the fight: still the guest's game's (together gave a thug back)")
    local left = select(1, Fake.health(onG))
    swing(g, onG, left - 500)
    s:run(2)
    check(math.abs(select(1, Fake.health(onH)) - (left - 500)) < 2, "the host's copy follows the health it has in the guest's game")
    -- A blow of the host's from near it: the host is in the fight, and the boss is the host's game's from then on.
    swing(h, onH, select(1, Fake.health(onH)) - 100)
    s:run(3)
    check(count(h.sent, "^E RUN sp:boss 0$") == 1 and net(g).mine["sp:boss"] == nil,
        "a blow of the host's from near it: the host is in the fight, and the boss is the host's game's")
    check(brain(onH) == true and brain(onG) == false, "its AI back on the host, the guest's copy following again")
    check(math.abs(select(1, Fake.health(onH)) - (left - 600)) < 2,
        "with the health the guest's game had left, the host's blow off it: " .. tostring(select(1, Fake.health(onH))))
    -- (Scaled once: the copy the host held had the guest's numbers, scaled there, and the host scaled it again as it took
    -- it back: on the bench the elite of Xigu went from 12420 to 18630 at that moment, 225% of its own.)
    s:run(3)
    check(select(2, Fake.health(onH)) == 7500 and select(2, Fake.health(onG)) == 7500,
        string.format("and the most health it had: scaled once, in both worlds (%s, %s)", tostring(select(2, Fake.health(onH))),
            tostring(select(2, Fake.health(onG)))))
    -- (On the bench the fight's own start and the mod's crossed as it changed hands, and the boss stood beside the host with
    -- its brain stopped till it was started by hand: looked at for a while after.)
    field(field(onH, "Controller"), "BrainComponent"):StopLogic("the fight's own start")
    s:run(3)
    check(brain(onH) == true and count(h.logs, "with its AI stopped after changing hands") == 1,
        "found in its fight with its AI stopped after changing hands, it's started again")
    allErrors(s)

    -- Scaled once, the body a new one to the host: a boss brought out there while the guest's game already runs it comes
    -- at an address the host never scaled, the guest's numbers on it. Read as a new body it was scaled on top, and stood
    -- at 225% once the host took it back. (The check above passes without that rule: its body was scaled before it
    -- changed hands. The first review's N9.)
    local n = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local nh, ng = n.pcs[1], n.pcs[2]
    n:run(4)
    Session.moveTo(nh, 0, 0)
    Session.moveTo(ng, 4000, 0)
    n:run(3)
    local newH, itsG = Session.enemyOn(nh, "boss"), Session.enemyOn(ng, "boss")
    ng.hudLayout:RegisterBossHPBar(itsG)
    n:run(3)
    check(net(nh).guestRuns["sp:boss"] == true, "(the guest's fight with it, the guest's game's to run)")
    rawset(newH, "__name", "boss_brought_out")      -- (a new body to the host's scaling: another name at that address)
    n:run(4)
    Session.moveTo(nh, 3800, 300)
    n:run(3)
    swing(nh, newH, select(1, Fake.health(newH)) - 100)
    n:run(6)
    check(net(ng).mine["sp:boss"] == nil and select(2, Fake.health(newH)) == 7500 and select(2, Fake.health(itsG)) == 7500,
        string.format("a body new to the host while the guest's game ran it, taken back: scaled once (%s, %s)",
            tostring(select(2, Fake.health(newH))), tostring(select(2, Fake.health(itsG)))))
    allErrors(n)

    -- The guest kills a boss its game runs: the host's copy, held at its floor, dies by the game's own death all the same.
    local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local th, tg = t.pcs[1], t.pcs[2]
    t:run(4)
    Session.moveTo(th, 0, 0)
    Session.moveTo(tg, 4000, 0)
    t:run(3)
    local bossH, bossG = Session.enemyOn(th, "boss"), Session.enemyOn(tg, "boss")
    tg.hudLayout:RegisterBossHPBar(bossG)
    t:run(3)
    swing(tg, bossG, 0)
    Fake.put(bossG, "dead", true)
    t:run(3)
    check(count(tg.sent, "^E GK sp:boss$") == 1, "the guest kills a boss its game runs, and says so")
    check(field(bossH, "dead") == true and field(bossH, "realDeath") == true,
        "the host's copy, held at its floor, dies by the game's own death")
    allErrors(t)

    -- The host's own fight is the host's game's, the guest in it or not: nothing goes over while its bar is up.
    local u = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local uh, ug = u.pcs[1], u.pcs[2]
    u:run(4)
    Session.moveTo(uh, 4100, 300)
    Session.moveTo(ug, 4000, -2800)
    u:run(2)
    uh.hudLayout:RegisterBossHPBar(Session.enemyOn(uh, "boss"))
    u:run(2)
    Session.moveTo(uh, 1000, 300)      -- the host backs 31 m off, its bar still up; the guest steps up to the boss
    Session.moveTo(ug, 4100, -200)
    u:run(3)
    check(count(uh.sent, "^E RUN sp:boss ") == 0 and net(uh).guestRuns["sp:boss"] == nil,
        "the host's own fight, the guest nearer the boss: it stays the host's game's")
    allErrors(u)
end

-- A guest's own game writing its copy of the host's boss back to its base numbers (Xiao Xue's did every few seconds
-- on the bench, 16482 over co-op's 24723; a difficulty set again does it to every enemy): no blow of the guest's. Its
-- drop, weighed as one while the guest swung, took all of co-op's share off the host's boss at once, and its guard
-- with it. (The sixth review's V3.)
local function aCopyWrittenBack()
    part("a copy's numbers written back by its own game")
    local list = { { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true } }
    local function attr(e, name)
        return rawget(e, "__fields").AttributeSetBase[name]
    end
    local function writeBase(e, hp, posture)    -- (the game's own write: health and its most, the guard bar too if given)
        for _, n in ipairs({ "Health", "Health_Max" }) do
            Fake.put(attr(e, n), "CurrentValue", hp)
            Fake.put(attr(e, n), "BaseValue", hp)
        end
        for _, n in ipairs(posture and { "Shachi", "Shachi_Max" } or {}) do
            Fake.put(attr(e, n), "CurrentValue", posture)
            Fake.put(attr(e, n), "BaseValue", posture)
        end
    end
    local function hpOf(e)
        return (select(1, Fake.health(e)))
    end
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, "CoopBossPosture = 200\n")
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 2800, 2900)
    Session.moveTo(g, 3200, 3100)
    s:run(4)
    h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
    s:run(3)
    local onH, onG = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    swing(g, onG, hpOf(onG) - 50)
    s:run(1)
    local before, guard = hpOf(onH), attr(onH, "Shachi").CurrentValue
    check(before == 7450, "(a blow of the guest's, 50: off the host's boss, " .. before .. ")")
    g.env.PBZ.game.noteLocalMove()              -- (the guest still swinging)
    writeBase(onG, 5000, 400)
    s:run(1)
    check(hpOf(onH) == before and attr(onH, "Shachi").CurrentValue == guard and count(g.sent, "^E D ") == 1,
        "the guest's own game writes its copy back to base as the guest swings: no blow, the host's boss keeps its health and its guard ("
            .. hpOf(onH) .. ", " .. tostring(attr(onH, "Shachi").CurrentValue) .. ")")
    s:run(3)
    check(math.abs(hpOf(onG) - hpOf(onH)) < 1 and select(2, Fake.health(onG)) == select(2, Fake.health(onH)),
        "and the copy is back at the host's numbers (" .. hpOf(onG) .. " of " .. tostring(select(2, Fake.health(onG))) .. ")")
    g.env.PBZ.game.noteLocalMove()
    writeBase(onG, 5000)
    s:run(0.2)
    local was = hpOf(onH)
    swing(g, onG, hpOf(onG) - 50)
    s:run(0.5)
    check(hpOf(onH) == was - 50, "a blow while the copy still stands at its base lands all the same (" .. was - hpOf(onH) .. ")")
    -- (Its health alone written, its guard bar as it was given: its game holds no more than that for it. The copy is
    -- kept at its own most from that write on, its health the host's share of it. PV1 of the seventh review.)
    check(select(2, Fake.health(onG)) == 5000
        and math.abs(hpOf(onG) - hpOf(onH) * 5000 / select(2, Fake.health(onH))) < 0.01,
        "and the copy is kept at its own game's most from that write on, its health the host's share of it ("
            .. string.format("%.1f", hpOf(onG)) .. " of 5000)")
    -- (The mod's own write of the most is kept as the last seen, no write of the game's. Its scaling once more takes a
    -- copy over its numbers and the mod writes it down: a blow the very next turn read as written, went to nobody and
    -- stood on the copy alone. The seventh review's V10.)
    s:run(2)
    for _, n in ipairs({ "Health", "Health_Max" }) do
        local v = attr(onG, n).CurrentValue * 1.5
        Fake.put(attr(onG, n), "CurrentValue", v)
        Fake.put(attr(onG, n), "BaseValue", v)
    end
    local told, at = count(g.sent, "^E D "), hpOf(onH)
    local struck = false
    s:run(1, function()
        if not struck and select(2, Fake.health(onG)) == 5000 then
            struck = swing(g, onG, hpOf(onG) - 50)      -- (the turn after the mod's write)
        end
    end)
    check(struck and count(g.sent, "^E D ") == told + 1 and hpOf(onH) == at - 50,
        "a blow the turn after the mod writes its copy's most down again is told (" .. at .. " -> " .. hpOf(onH) .. ")")
    allErrors(s)

    -- Every number of the copy written (a difficulty set again: its guard bar's most too), a little under what the
    -- host's boss has, the guest standing still: put back at once. 364 left it for the host's line, which lifts a copy
    -- only from 5% under: it stood 200 short for good, and its killing blow took the rest off the host's boss. (The
    -- seventh review's V3.)
    local v = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, "CoopBossPosture = 200\n")
    local vh, vg = v.pcs[1], v.pcs[2]
    v:run(4)
    Session.moveTo(vh, 2800, 2900)
    Session.moveTo(vg, 3200, 3100)
    v:run(4)
    vh.hudLayout:RegisterBossHPBar(Session.enemyOn(vh, "boss"))
    v:run(3)
    local bossV, copyV = Session.enemyOn(vh, "boss"), Session.enemyOn(vg, "boss")
    swing(vg, copyV, 5200)
    v:run(4)                            -- (the guest still since: no move of theirs in 3 s)
    writeBase(copyV, 5000, 400)
    v:run(1)
    check(hpOf(bossV) == 5200 and math.abs(hpOf(copyV) - 5200) < 1
        and select(2, Fake.health(copyV)) == select(2, Fake.health(bossV)),
        "a copy's every number written 200 under the host's, the guest still: put back at once (" .. hpOf(copyV) .. ")")
    allErrors(v)

    -- Co-op's health at the game's own and the guard bar raised: a write of the copy's base lowers its guard alone.
    -- No most health fell, so 364 took it for a blow: half the host's guard gone with none struck. (V4.)
    local q = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, "CoopEnemyHealth = 100\nCoopBossPosture = 200\n")
    local qh, qg = q.pcs[1], q.pcs[2]
    q:run(4)
    Session.moveTo(qh, 2800, 2900)
    Session.moveTo(qg, 3200, 3100)
    q:run(4)
    qh.hudLayout:RegisterBossHPBar(Session.enemyOn(qh, "boss"))
    q:run(3)
    local bossQ, copyQ = Session.enemyOn(qh, "boss"), Session.enemyOn(qg, "boss")
    swing(qg, copyQ, hpOf(copyQ) - 200)
    q:run(5)
    local guardQ, sentQ = attr(bossQ, "Shachi").CurrentValue, count(qg.sent, "^E D ")
    qg.env.PBZ.game.noteLocalMove()
    writeBase(copyQ, 5000, 400)
    q:run(3)
    check(select(2, Fake.health(bossQ)) == 5000 and attr(bossQ, "Shachi").CurrentValue >= guardQ - 1
        and count(qg.sent, "^E D ") == sentQ,
        "co-op's health at the game's own, the copy's guard written back to base as the guest swings: no blow, the host's guard kept ("
            .. tostring(attr(bossQ, "Shachi").CurrentValue) .. ")")
    swing(qg, copyQ, hpOf(copyQ) - 50)
    Fake.put(attr(copyQ, "Shachi"), "CurrentValue", attr(copyQ, "Shachi").CurrentValue - 30)
    q:run(2)
    check(count(qg.sent, "^E D ") == sentQ + 1 and attr(bossQ, "Shachi").CurrentValue <= guardQ - 29,
        "and a plain blow after it, its guard taken with it: both told")
    allErrors(q)

    -- A party of three, the host away: a guest's own fight with a boss asleep on the host, what its copy has its own
    -- game's to say. Its numbers written there (all of them, then its health alone): the copy keeps the share the
    -- host's boss has, and the host's boss falls only to blows of all it had. 364 left the copy at its base: it fell
    -- that much sooner, its death taking the rest off the host's boss. (V3.)
    -- (lineFirst: the host's line before this guest's scaling, as after a load. Its note of the copy was the line's
    -- most multiplied again, and at a write of its guard bar the copy was given its health twice: 19000 of 10000. The
    -- eighth review's V2.)
    for _, case in ipairs({ { true, false }, { false, false }, { true, true }, { false, true } }) do
        local guardToo, lineFirst = case[1], case[2]
        local a = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true,
            { { "boss", "BP_Monster_Boss_C", 2000.0, 3000.0, 100.0, 5000, 400, true } })
        local ah, ab = a.pcs[1], a.pcs[3]
        if lineFirst then
            net(ab).quietUntil = ab.now + 5
        end
        a:run(4)
        Session.moveTo(ah, 0, 0)
        Session.moveTo(a.pcs[2], 500, 0)
        Session.moveTo(ab, 2100, 2900)
        a:run(3)
        local bossA, copyA = Session.enemyOn(ah, "boss"), Session.enemyOn(ab, "boss")
        ab.hudLayout:RegisterBossHPBar(copyA)
        a:run(3)
        swing(ab, copyA, hpOf(copyA) - 500)
        a:run(4)
        local had, mostA = hpOf(bossA), select(2, Fake.health(bossA))
        writeBase(copyA, 5000, guardToo and 400 or nil)
        a:run(3)
        local share = hpOf(copyA) / select(2, Fake.health(copyA))
        local dealt, n = 0, 0
        while hpOf(copyA) > 500 and n < 60 do
            swing(ab, copyA, hpOf(copyA) - 500)
            dealt, n = dealt + 500, n + 1
            a:run(0.5)
        end
        dealt = dealt + hpOf(copyA) * (guardToo and 1 or mostA / 5000)
        swing(ab, copyA, 0)
        Fake.put(copyA, "dead", true)
        a:run(3)
        check(math.abs(share - had / mostA) < 0.001 and field(bossA, "dead") == true and dealt >= had - 2,
            "a party guest's own fight" .. (lineFirst and ", the host's line before its scaling" or "") .. ", its copy's "
                .. (guardToo and "numbers" or "health alone") .. " written by its game: "
                .. "the copy keeps the host's share, and the host's boss falls to blows of all it had ("
                .. string.format("%.0f of %.0f", dealt, had) .. ")")
        allErrors(a)
    end

    -- A party: two guests' games write theirs in one turn, both swinging: the boss was ended with no blow struck.
    local p = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, list, "CoopBossPosture = 200\n")
    local ph, pa, pb = p.pcs[1], p.pcs[2], p.pcs[3]
    p:run(4)
    Session.moveTo(ph, 2800, 2900)
    Session.moveTo(pa, 3200, 3100)
    Session.moveTo(pb, 3100, 2800)
    p:run(4)
    ph.hudLayout:RegisterBossHPBar(Session.enemyOn(ph, "boss"))
    p:run(3)
    local bossH = Session.enemyOn(ph, "boss")
    for _, pc in ipairs({ pa, pb }) do
        swing(pc, Session.enemyOn(pc, "boss"), hpOf(Session.enemyOn(pc, "boss")) - 50)
    end
    p:run(1)
    local held = hpOf(bossH)
    for _, pc in ipairs({ pa, pb }) do
        pc.env.PBZ.game.noteLocalMove()
        writeBase(Session.enemyOn(pc, "boss"), 5000)
    end
    p:run(1)
    check(hpOf(bossH) == held and field(bossH, "dead") ~= true,
        "a party, two guests' games writing theirs at once: the host's boss keeps its health (" .. held .. " -> " .. hpOf(bossH) .. ")")
    allErrors(p)

    -- The same on the host, for a boss the guest's game runs (handover.follow): the host's own game writes its copy
    -- back as the host moves by it, not in the fight. Weighed as the host's blow it took a third off the guest's boss
    -- and gave the boss to the host. And the mod's own write of that copy's most is kept too. (V10.)
    local o = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "boss", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true } })
    local oh, og = o.pcs[1], o.pcs[2]
    o:run(4)
    Session.moveTo(oh, 0, 0)
    Session.moveTo(og, 4000, 0)         -- the guest by the boss, the host 40 m behind
    o:run(3)
    local copyH, runG = Session.enemyOn(oh, "boss"), Session.enemyOn(og, "boss")
    og.hudLayout:RegisterBossHPBar(runG)
    o:run(3)
    Session.moveTo(oh, 3800, 300)       -- beside the guest, not in the fight
    o:run(3)
    local hadG, sentH = hpOf(runG), count(oh.sent, "^E D ")
    oh.env.PBZ.game.noteLocalMove()
    writeBase(copyH, 5000)
    o:run(1)
    check(net(oh).guestRuns["sp:boss"] == true and count(oh.sent, "^E D ") == sentH and hpOf(runG) == hadG
        and math.abs(hpOf(copyH) - hadG) < 1,
        "the host's own game writes its copy of the guest's boss back as the host moves by it: no blow, put back at once, "
            .. "the guest's boss keeps its health and stays the guest's game's (" .. hadG .. " -> " .. hpOf(runG) .. ")")
    o:run(3)
    writeBase(runG, 5000)               -- the guest's game writes the boss it runs back: its line says the lower most
    local hit = false
    o:run(1, function()
        if not hit and select(2, Fake.health(copyH)) == 5000 then
            hit = swing(oh, copyH, hpOf(copyH) - 50)      -- (the turn after the mod's write)
        end
    end)
    check(hit and count(oh.sent, "^E D ") == sentH + 1,
        "the host's blow the turn after the mod writes its copy's most down to the guest's line is told")
    allErrors(o)

    -- The same on the host's side for its guard alone (375's host half, handover.follow: the eighth review's V10, a
    -- rule no check held). Co-op's health at the game's own, the guard raised: the host's game writes its copy of the
    -- guest's boss back to base as the host moves by it. No most health fell: the guard's fall was told as the host's
    -- blow, half the guest's boss's guard gone with none struck.
    local x = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "boss", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true } },
        "CoopEnemyHealth = 100\nCoopBossPosture = 200\n")
    local xh, xg = x.pcs[1], x.pcs[2]
    x:run(4)
    Session.moveTo(xh, 0, 0)
    Session.moveTo(xg, 4000, 0)
    x:run(3)
    local copyX, runX = Session.enemyOn(xh, "boss"), Session.enemyOn(xg, "boss")
    xg.hudLayout:RegisterBossHPBar(runX)
    x:run(3)
    Session.moveTo(xh, 3800, 300)
    x:run(3)
    local guardX, sentX = attr(runX, "Shachi").CurrentValue, count(xh.sent, "^E D ")
    xh.env.PBZ.game.noteLocalMove()
    for _, n in ipairs({ "Shachi", "Shachi_Max" }) do
        Fake.put(attr(copyX, n), "CurrentValue", 400)
        Fake.put(attr(copyX, n), "BaseValue", 400)
    end
    x:run(1)
    check(net(xh).guestRuns["sp:boss"] == true and guardX > 400 and count(xh.sent, "^E D ") == sentX
        and attr(runX, "Shachi").CurrentValue >= guardX - 1,
        "the host's game writes its copy's guard back to base as the host moves by the guest's boss: no blow told, the "
            .. "guest's boss keeps its guard (" .. guardX .. " -> " .. attr(runX, "Shachi").CurrentValue .. ")")
    allErrors(x)

    -- The same write in the host's own world (the bench of 11-17: her health and its most back to her own, her posture
    -- left as it was). To the scaling that was a new body: scaled again, and its guard bar was multiplied again at
    -- each write, 34443 to 72 billion. Its guard bar, still what it was given, stays; and since PV1 of the seventh
    -- review its health isn't scaled again either: its game holds no more, so it keeps its game's most (the next part).
    -- With two players and with three.
    for _, roles in ipairs({ { "Host", "Guest" }, { "Host", "Guest", "Guest" } }) do
        local w = Session.new(SIM_SCRIPTS, roles, #roles > 2, list, "CoopBossPosture = 200\n")
        local wh = w.pcs[1]
        w:run(4)
        Session.moveTo(wh, 2800, 2900)
        Session.moveTo(w.pcs[2], 3200, 3100)
        w:run(4)
        wh.hudLayout:RegisterBossHPBar(Session.enemyOn(wh, "boss"))
        w:run(3)
        local onW = Session.enemyOn(wh, "boss")
        local most, guard = select(2, Fake.health(onW)), attr(onW, "Shachi_Max").CurrentValue
        for _ = 1, 5 do
            writeBase(onW, 5000)
            w:run(3)
        end
        check(most > 5000 and select(2, Fake.health(onW)) == 5000 and hpOf(onW) == 5000
            and attr(onW, "Shachi_Max").CurrentValue == guard and count(wh.logs, "holds no more than its own health") == 1,
            #roles .. " players, the host's own game writes its boss's health back five times: kept at its game's most from "
                .. "the first, said once, its guard bar as it was (" .. tostring(guard) .. " -> "
                .. tostring(attr(onW, "Shachi_Max").CurrentValue) .. ")")
        writeBase(onW, 5000, 400)       -- (a new body's numbers: its posture at base too)
        w:run(3)
        check(select(2, Fake.health(onW)) == most and attr(onW, "Shachi_Max").CurrentValue == guard,
            "and written back with its posture too, as a new body is: scaled as new, its health and its guard bar, once ("
                .. tostring(select(2, Fake.health(onW))) .. ", " .. tostring(attr(onW, "Shachi_Max").CurrentValue) .. ")")
        -- (Another body at that address, its own guard bar as high as the one given here: by its name a new one, scaled
        -- from its own. The name test had no check: the seventh review's PV3.)
        rawset(onW, "__name", "another_body")
        writeBase(onW, 5000, guard)
        w:run(3)
        check(attr(onW, "Shachi_Max").CurrentValue == guard * guard / 400,
            "another body at that address, its own guard bar as high: scaled from its own ("
                .. tostring(attr(onW, "Shachi_Max").CurrentValue) .. ")")
        allErrors(w)
    end
end

-- A guest who hosts next in the same run of the game (HOST on the panel, no load between), the old host joining it. It
-- judged the bodies it had scaled as a guest by their guard bar's number against their health: the same for good. One
-- healed to its base by a difficulty set again (25 s alone does that), or a new body at that address after a rest,
-- kept the game's own numbers for the rest of that run. (The seventh review's PG1: 1.7.3 kept co-op's health there.)
local function aGuestHostsNext()
    part("a guest who hosts next, no load between")
    local list = {
        { "near", THUG, 300.0, 300.0, 100.0, 600, 100 },
        { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
    }
    local BASE = { near = { 600, 100 }, boss = { 5000, 400 } }
    local function attr(e, name)
        return rawget(e, "__fields").AttributeSetBase[name]
    end
    local function put(e, name, v)
        Fake.put(attr(e, name), "CurrentValue", v)
        Fake.put(attr(e, name), "BaseValue", v)
    end
    local function numbers(pc)
        local got = {}
        for _, id in ipairs({ "near", "boss" }) do
            local e = Session.enemyOn(pc, id)
            got[#got + 1] = string.format("%.0f/%.0f", attr(e, "Health_Max").CurrentValue, attr(e, "Shachi_Max").CurrentValue)
        end
        return table.concat(got, ", ")
    end
    -- (lineFirst: the host's line gives the copies their most before the guest's scaling first looks, as after a load:
    -- the quiet that follows one holds the scaling, not the enemies' turns. The scaling multiplied the line's most for
    -- a moment and noted that: 1350 of 900, and hosting next the body was taken for one its game cuts, 225% for two.
    -- The eighth review's V2.)
    for _, lineFirst in ipairs({ false, true }) do
    for _, case in ipairs({ "nothing written", "a difficulty set again", "a rest" }) do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, "CoopBossPosture = 200\n")
        local h, g = s.pcs[1], s.pcs[2]
        if lineFirst then
            net(g).quietUntil = g.now + 8
        end
        s:run(4)
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 500, 0)
        s:run(8)
        check(numbers(g) == "900/130, 7500/800", "(linked, the guest's copies at co-op's numbers: " .. numbers(g) .. ")")
        Session.command(h, "netoff")
        Session.command(g, "netoff")
        s:run(3)
        Session.command(g, "neton host")
        s:run(1)
        Session.command(h, "neton client")
        s:run(12)
        for id, b in pairs(case == "nothing written" and {} or BASE) do
            local e = Session.enemyOn(g, id)        -- (its game's write: health and its most, the guard bar's too)
            put(e, "Health_Max", b[1])
            put(e, "Health", b[1])
            put(e, "Shachi_Max", b[2])
            put(e, "Shachi", b[2])
        end
        s:run(10)
        check(g.env.PBZ.coop.isHost() and numbers(g) == "900/130, 7500/800",
            "the guest hosts next, " .. case .. ": its enemies at co-op's numbers, once (" .. numbers(g) .. ")")
        if lineFirst then
            check(count(g.logs, "holds no more than its own health") == 0 and numbers(h) == "900/130, 7500/800",
                "the host's line before its scaling's first look: none taken for one its game cuts, the new guest's copies at "
                    .. "co-op's numbers too (" .. numbers(h) .. "; said " .. count(g.logs, "holds no more than its own health") .. ")")
        end
        allErrors(s)
    end
    end
    -- (Health alone at its base, the guard bar as given: that's its game's cut, 378: kept at that, not scaled again.)
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, "CoopBossPosture = 200\n")
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(8)
    Session.command(h, "netoff")
    Session.command(g, "netoff")
    s:run(3)
    Session.command(g, "neton host")
    s:run(1)
    Session.command(h, "neton client")
    s:run(12)
    local e = Session.enemyOn(g, "near")
    put(e, "Health_Max", 600)
    put(e, "Health", 600)
    s:run(10)
    check(attr(e, "Health_Max").CurrentValue == 600 and attr(e, "Shachi_Max").CurrentValue == 130
        and count(g.logs, "holds no more than its own health") == 1,
        "its health alone at its base there, its guard bar as given: its game's cut, kept at that, its guard bar not twice ("
            .. numbers(g) .. ")")
    allErrors(s)
end

-- A party after a later join (the eighth review's V3). The host scales a boss's guard for the new count; a guest's copy
-- keeps the most it was scaled to, and the host's line lifted the copy's bar over that most. Its game puts such a bar
-- back at its most at the next blow, and that blow's guard went to nobody (375). Never lifted over its own most now.
local function aGuardOverItsMost()
    part("a party after a later join: a copy's guard and its own most")
    local list = { { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true } }
    local function attr(e, name)
        return rawget(e, "__fields").AttributeSetBase[name]
    end
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, list, "CoopBossPosture = 200\n")
    local h, g, late = s.pcs[1], s.pcs[2], s.pcs[3]
    late.joinAt = h.now + 14
    s:run(4)
    Session.moveTo(h, 2800, 2900)
    Session.moveTo(g, 3200, 3100)
    s:run(6)
    local onH, onG = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    local two = attr(onG, "Shachi_Max").CurrentValue
    s:run(10)       -- (the third is in: the host's guard is for three)
    local over = 0
    s:run(6, function()
        if attr(onG, "Shachi").CurrentValue > attr(onG, "Shachi_Max").CurrentValue + 0.5 then
            over = over + 1
        end
    end)
    check(late.env.PBZ.net.enabled == true and attr(onH, "Shachi").CurrentValue > two + 1 and attr(onG, "Shachi_Max").CurrentValue == two,
        "(a third joined: the host's guard for three, " .. attr(onH, "Shachi").CurrentValue .. ", the guest's copy's most still "
            .. two .. ")")
    check(over == 0 and math.abs(attr(onG, "Shachi").CurrentValue - two) < 0.5,
        "the copy's guard is lifted to its own most, never over it (" .. attr(onG, "Shachi").CurrentValue .. " of " .. two
            .. "; over it at " .. over .. " looks)")
    -- (And a blow of the guest's on it then, as its game makes one: a bar held over its most ends at it. Its guard part is told.)
    local sent = count(g.sent, "^E D ")
    swing(g, onG, select(1, Fake.health(onG)) - 50)
    Fake.put(attr(onG, "Shachi"), "CurrentValue", math.min(attr(onG, "Shachi").CurrentValue - 30, attr(onG, "Shachi_Max").CurrentValue))
    local guard = attr(onH, "Shachi").CurrentValue
    s:run(2)
    check(count(g.sent, "^E D ") == sent + 1 and attr(onH, "Shachi").CurrentValue <= guard - 29,
        "a blow of the guest's then takes its guard off the host's bar (" .. guard .. " -> " .. attr(onH, "Shachi").CurrentValue .. ")")
    allErrors(s)
end

-- A boss whose game holds no more health than its own most (Xiao Xue's: the bench of 11-18, co-op off, her numbers
-- written by hand). Health over her own most is cut to it at the next blow of that world's own player, and her most
-- with it; under it a blow sticks, and a most written over hers is left alone. Scaled again at each cut, the host's
-- every blow healed her to full, and a guest's were cut on its copy and told to nobody: a fight nobody wins. She
-- keeps her game's most, and a blow takes 1/f of what it did, from either player. (PV1 of the seventh review.)
local function aBossHeldToItsMost()
    part("a boss whose game holds no more than its own health")
    local OWN = 5000
    local list = { { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, OWN, 400, true } }
    local function attr(e, name)
        return rawget(e, "__fields").AttributeSetBase[name]
    end
    local function hpOf(e)
        return (select(1, Fake.health(e)))
    end
    local function mostOf(e)
        return (select(2, Fake.health(e)))
    end
    -- That game's blow: health over its own most is cut to it, the most with it (the blow gone in the cut); else it sticks.
    local function blow(pc, e, d)
        pc.env.PBZ.game.noteLocalMove()
        if hpOf(e) > OWN + 0.01 then
            for _, n in ipairs({ "Health", "Health_Max" }) do
                Fake.put(attr(e, n), "CurrentValue", OWN)
                Fake.put(attr(e, n), "BaseValue", OWN)
            end
        else
            Fake.setHealth(e, hpOf(e) - d)
        end
    end
    local function fight(roles, ini)
        local s = Session.new(SIM_SCRIPTS, roles, #roles > 2, list, ini or "CoopBossPosture = 200\n")
        local h, g = s.pcs[1], s.pcs[2]
        s:run(4)
        Session.moveTo(h, 2800, 2900)
        Session.moveTo(g, 3200, 3100)
        if s.pcs[3] then
            Session.moveTo(s.pcs[3], 3100, 2800)
        end
        s:run(4)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        return s, h, g, Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    end
    for _, roles in ipairs({ { "Host", "Guest" }, { "Host", "Guest", "Guest" } }) do
        local s, h, g, onH, onG = fight(roles)
        local most, guard = mostOf(onH), attr(onH, "Shachi_Max").CurrentValue
        local f = most / OWN
        local n = #roles .. " players: "
        check(f > 1.4 and mostOf(onG) == most, "(" .. n .. "co-op's most on both, " .. most .. ")")
        blow(h, onH, 300)
        s:run(1)
        check(mostOf(onH) == OWN and hpOf(onH) == OWN and attr(onH, "Shachi_Max").CurrentValue == guard
            and count(h.logs, "holds no more than its own health") == 1,
            n .. "the host's first blow, its game cuts it to its own most: kept at that, whole, its guard bar as it was, said once")
        check(mostOf(onG) == most and math.abs(hpOf(onG) - most) < 1,
            "the guest's copy still shows co-op's numbers (" .. hpOf(onG) .. " of " .. mostOf(onG) .. ")")
        blow(h, onH, 300)
        s:run(1)
        check(math.abs(hpOf(onH) - (OWN - 300 / f)) < 0.01 and mostOf(onH) == OWN,
            "the host's next blow, 300: 1/" .. f .. " of it off (" .. string.format("%.1f", hpOf(onH)) .. ")")
        check(math.abs(hpOf(onG) - (most - 300)) < 1, "which the guest's copy shows whole, of co-op's most (" .. hpOf(onG) .. ")")
        local told = count(g.sent, "^E D ")
        blow(g, onG, 300)
        s:run(1)
        check(mostOf(onG) == OWN and math.abs(hpOf(onG) - hpOf(onH)) < 1 and count(g.sent, "^E D ") == told
            and math.abs(hpOf(onH) - (OWN - 300 / f)) < 0.01,
            "the guest's blow, its own game cuts its copy: kept at its own most, its health the host's share, nothing told ("
                .. string.format("%.1f", hpOf(onG)) .. ")")
        local was = hpOf(onH)
        blow(g, onG, 300)
        s:run(1)
        check(count(g.sent, "^E D ") == told + 1 and math.abs(hpOf(onH) - (was - 300 / f)) < 0.01
            and math.abs(hpOf(onG) - hpOf(onH)) < 1,
            "the guest's next blow, 300: told, 1/" .. f .. " of it off the host's boss, the copy with it ("
                .. string.format("%.1f, %.1f", hpOf(onH), hpOf(onG)) .. ")")
        was = hpOf(onH)
        blow(h, onH, 300)
        blow(g, onG, 300)
        s:run(1)
        check(math.abs(hpOf(onH) - (was - 600 / f)) < 0.01 and math.abs(hpOf(onG) - hpOf(onH)) < 1,
            "both at once: each blow's share off, once (" .. string.format("%.1f", was - hpOf(onH)) .. ")")
        was = hpOf(onH)
        Fake.setHealth(onH, was + 150)          -- (a heal of its own)
        s:run(2)
        check(hpOf(onH) == was + 150, "a heal of its own is its own: nothing added, nothing taken (" .. hpOf(onH) - was .. ")")
        blow(h, onH, 300)
        s:run(1)
        check(math.abs(hpOf(onH) - (was + 150 - 300 / f)) < 0.01, "and a blow after it takes its share as before")
        Fake.setHealth(onH, 1000)               -- (a set of more than half its most at once: the game's own, no blow)
        s:run(1)
        check(hpOf(onH) == 1000, "set down by more than half its most at once, no blow: left as its game wrote it")
        -- (At a floor of its game's own nothing is given back: what comes there is its script's, a phase's scene.)
        local min = attr(onH, "Health_Min")
        Fake.put(min, "BaseValue", 800)
        Fake.put(min, "CurrentValue", 800)
        Fake.setHealth(onH, 800)
        s:run(1)
        check(hpOf(onH) == 800, "a blow that leaves it at a floor of its game's own: nothing given back there (" .. hpOf(onH) .. ")")
        Fake.put(min, "BaseValue", 0)
        Fake.put(min, "CurrentValue", 0)
        Fake.setHealth(onH, 1000)
        s:run(1)
        local blows = 0
        while hpOf(onH) > 300 and blows < 100 do
            blow(h, onH, 300)
            s:run(0.5)
            blows = blows + 1
        end
        check(blows == math.ceil(700 * f / 300 - 0.001),
            "worn down by the host's blows of 300 from 1000 to under 300: " .. blows .. ", " .. f .. " times the game's own count")
        Fake.setHealth(onH, 0)
        s:run(0.3)
        check(hpOf(onH) == 0, "its last blow, falling, not yet dead by its game's word: nothing given back (" .. hpOf(onH) .. ")")
        Fake.put(onH, "dead", true)
        s:run(2)
        check(hpOf(onH) == 0 and field(onH, "dead") == true and count(h.sent, "^E K sp:boss") == 1,
            "dead: nothing given back to a dead one, told once")
        allErrors(s)
    end

    -- The guest alone strikes, the host standing by with no blow of its own: its blows count from the second on (the
    -- first is the cut's), off the host's boss whole, since the host's still holds co-op's health as health.
    local s, h, g, onH, onG = fight({ "Host", "Guest" })
    local most = mostOf(onH)
    for _ = 1, 5 do
        blow(g, onG, 300)
        s:run(1)
    end
    check(mostOf(onH) == most and hpOf(onH) == most - 1200 and mostOf(onG) == OWN
        and math.abs(hpOf(onG) - OWN * hpOf(onH) / most) < 1 and count(g.logs, "holds no more than its own health") == 1,
        "the guest alone strikes five times, the host never: four told, each whole off the host's boss, the copy at its share ("
            .. hpOf(onH) .. " of " .. most .. ", " .. string.format("%.1f", hpOf(onG)) .. " of " .. OWN .. ")")
    -- (And then the host's first blow: its own game's cut. It keeps the share it had.)
    blow(h, onH, 300)
    s:run(1)
    check(mostOf(onH) == OWN and math.abs(hpOf(onH) - OWN * (most - 1200) / most) < 0.01 and mostOf(onG) == OWN
        and math.abs(hpOf(onG) - hpOf(onH)) < 1,
        "then the host's first blow, its game's cut: kept at its own most with the share it had ("
            .. string.format("%.1f", hpOf(onH)) .. " of " .. OWN .. "), the copy the same")
    -- (A copy that ran ahead of it: the host's boss heals a little, under the 5% a copy is lifted from, and the guest
    -- wears its copy down to its floor. More left on the host's than f times that last blow: a blow there, no death,
    -- and LR lifts the copy to what it has. In step again, its next floor is its death.)
    Fake.setHealth(onH, hpOf(onH) + 240)
    s:run(2)
    local n = 0
    while hpOf(onG) > 250 and n < 60 do
        blow(g, onG, 300)
        s:run(0.5)
        n = n + 1
    end
    local hostHas = hpOf(onH)
    swing(g, onG, 1)
    s:run(2)
    check(hostHas > 300 and field(onH, "dead") ~= true and hpOf(onH) < hostHas
        and count(g.logs, "The host didn't take the killing blow") == 1 and math.abs(hpOf(onG) - hpOf(onH)) < 1,
        "a copy on its floor with more left on the host's boss than its blow: a blow there, no death, the copy lifted to it ("
            .. string.format("%.1f -> %.1f, the copy %.1f", hostHas, hpOf(onH), hpOf(onG)) .. ")")
    n = 0
    while hpOf(onG) > 250 and n < 60 do
        blow(g, onG, 300)
        s:run(0.5)
        n = n + 1
    end
    swing(g, onG, 1)
    s:run(2)
    check(field(onH, "dead") == true, "and in step with it, the copy's next floor is its death there (" .. hpOf(onH) .. ")")
    allErrors(s)

    -- An enemy with no bar under the same rule (her summoned thugs: the bench of 11-18, where every blow of the host's
    -- healed them to full). Known at the pass's look, a second on at most; kept and given back like a boss from there.
    local THUG_OWN = 600
    local a = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "add", THUG, 3000.0, 3000.0, 100.0, THUG_OWN, 100 } })
    local ah, ag = a.pcs[1], a.pcs[2]
    a:run(4)
    Session.moveTo(ah, 2800, 2900)
    Session.moveTo(ag, 3200, 3100)
    a:run(6)
    local addH, addG = Session.enemyOn(ah, "add"), Session.enemyOn(ag, "add")
    local addMost = mostOf(addH)
    local function thugBlow(pc, e, d)
        pc.env.PBZ.game.noteLocalMove()
        if hpOf(e) > THUG_OWN + 0.01 then
            for _, n in ipairs({ "Health", "Health_Max" }) do
                Fake.put(attr(e, n), "CurrentValue", THUG_OWN)
                Fake.put(attr(e, n), "BaseValue", THUG_OWN)
            end
        else
            Fake.setHealth(e, hpOf(e) - d)
        end
    end
    thugBlow(ah, addH, 90)
    a:run(3)
    check(addMost == 900 and mostOf(addH) == THUG_OWN and hpOf(addH) == THUG_OWN
        and count(ah.logs, "holds no more than its own health") == 1,
        "an enemy with no bar, the host's first blow, its game's cut: kept at its own most, not scaled again ("
            .. hpOf(addH) .. " of " .. mostOf(addH) .. ")")
    a:run(3)
    check(mostOf(addG) == addMost and math.abs(hpOf(addG) - addMost) < 1,
        "the guest's copy of it shows co-op's numbers (" .. hpOf(addG) .. " of " .. mostOf(addG) .. ")")
    for _ = 1, 3 do
        thugBlow(ah, addH, 90)
        a:run(1)
    end
    check(math.abs(hpOf(addH) - (THUG_OWN - 3 * 90 / 1.5)) < 0.01 and mostOf(addH) == THUG_OWN
        and count(ah.logs, "holds no more than its own health") == 1,
        "three more blows of the host's, 90 each: 60 off each, said once (" .. string.format("%.1f", hpOf(addH)) .. ")")
    thugBlow(ag, addG, 90)                  -- (the guest's first: its own game's cut of its copy)
    a:run(1)
    local addWas = hpOf(addH)
    thugBlow(ag, addG, 90)
    a:run(1)
    check(math.abs(hpOf(addH) - (addWas - 60)) < 0.01 and math.abs(hpOf(addG) - hpOf(addH)) < 1,
        "the guest's blow of 90 on its copy: 60 off the host's, the copy with it ("
            .. string.format("%.1f, %.1f", hpOf(addH), hpOf(addG)) .. ")")
    -- (The partner gone mid-fight: it keeps its share all the same, as a scaled body keeps its health.)
    Session.command(ag, "netoff")
    a:run(14)
    addWas = hpOf(addH)
    thugBlow(ah, addH, 90)
    a:run(1)
    check(math.abs(hpOf(addH) - (addWas - 60)) < 0.01,
        "the partner gone mid-fight: a blow still takes 60 of it (" .. string.format("%.1f", addWas - hpOf(addH)) .. ")")
    allErrors(a)

    -- The guest strikes it first (the eighth review's V1; in run170's log). Its own game cuts its copy at its first
    -- blow; its next three are told and land whole on the host's body, still at co-op's most there. Then the host's
    -- first blow, its game's cut: kept with the share it had, as a boss is. Known at the scaling's pass alone it was
    -- kept whole: the guest's blows undone, its bar back at full on both screens.
    for _, roles in ipairs({ { "Host", "Guest" }, { "Host", "Guest", "Guest" } }) do
        local b = Session.new(SIM_SCRIPTS, roles, #roles > 2, { { "add", THUG, 3000.0, 3000.0, 100.0, THUG_OWN, 100 } })
        local bh, bg = b.pcs[1], b.pcs[2]
        b:run(4)
        Session.moveTo(bh, 2800, 2900)
        Session.moveTo(bg, 3200, 3100)
        if b.pcs[3] then
            Session.moveTo(b.pcs[3], 3100, 2800)
        end
        b:run(6)
        local onH, onG = Session.enemyOn(bh, "add"), Session.enemyOn(bg, "add")
        local most = mostOf(onH)
        for _ = 1, 4 do
            thugBlow(bg, onG, 90)
            b:run(1)
        end
        local had, healed = hpOf(onH), count(bg.logs, "healed on the host")
        thugBlow(bh, onH, 90)
        b:run(3)
        check(had == most - 270 and mostOf(onH) == THUG_OWN and math.abs(hpOf(onH) - THUG_OWN * had / most) < 0.01
            and count(bh.logs, "holds no more than its own health") == 1,
            #roles .. " players, the guest strikes a body with no bar first (" .. had .. " of " .. most
                .. " left), then the host's first blow, its game's cut: kept with that share ("
                .. string.format("%.1f of %.0f", hpOf(onH), mostOf(onH)) .. ")")
        check(mostOf(onG) == THUG_OWN and math.abs(hpOf(onG) - hpOf(onH)) < 1 and count(bg.logs, "healed on the host") == healed,
            "the guest's copy with it, never back at full (" .. string.format("%.1f of %.0f", hpOf(onG), mostOf(onG)) .. ")")
        allErrors(b)
    end

    -- A third joins while one is kept (the eighth review's V5): the new count is what its health stands for, its most
    -- its game's still. Its game numbers multiplied, it was dropped as kept: 133% where three get 200%.
    local c = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, { { "add", THUG, 3000.0, 3000.0, 100.0, THUG_OWN, 100 } })
    local ch, cg, late = c.pcs[1], c.pcs[2], c.pcs[3]
    late.joinAt = ch.now + 22
    c:run(4)
    Session.moveTo(ch, 2800, 2900)
    Session.moveTo(cg, 3200, 3100)
    c:run(6)
    local keptH = Session.enemyOn(ch, "add")
    local two = mostOf(keptH)
    thugBlow(ch, keptH, 90)                 -- (the host's first: its game's cut)
    c:run(3)
    for _ = 1, 2 do
        thugBlow(ch, keptH, 90)
        c:run(1)
    end
    local before = hpOf(keptH)
    c:run(16)                               -- (the third is in)
    local after = hpOf(keptH)
    thugBlow(ch, keptH, 90)
    c:run(1)
    check(two == 900 and #c.pcs == 3 and late.env.PBZ.net.enabled == true and mostOf(keptH) == THUG_OWN
        and math.abs(after - before) < 0.01 and math.abs(hpOf(keptH) - (after - 45)) < 0.01,
        "a third joins while one is kept at its game's most: its most and what it has stay, and a blow of 90 takes 45 now ("
            .. string.format("%.1f -> %.1f -> %.1f of %.0f", before, after, hpOf(keptH), mostOf(keptH)) .. ")")
    allErrors(c)

    -- Co-op's health at the game's own (CoopEnemyHealth = 100): nothing over its most, no cut, nothing kept or given.
    local t, th, tg, onT = fight({ "Host", "Guest" }, "CoopEnemyHealth = 100\nCoopBossPosture = 200\n")
    blow(th, onT, 300)
    t:run(1)
    check(mostOf(onT) == OWN and hpOf(onT) == OWN - 300 and count(th.logs, "holds no more than its own health") == 0,
        "co-op's health at the game's own: a blow takes what it takes, nothing said (" .. hpOf(onT) .. ")")
    allErrors(t)
end

-- Three or more players. A party has no handing over (its relay carries enemy lines from the host alone), but the host's
-- game wakes enemies for its own player alone all the same: one by a guest some way from the host slept there, and on
-- every guest's screen with it, a boss a guest went in to first too. The host's line says it's asleep there now, and each
-- guest's game runs its own copy meanwhile: awake for the guest who's by it, its health and its death everyone's.
local function asleepOnTheHost()
    part("a party: enemies by a guest away from the host")
    local list = {
        { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 },
        { "byhost", THUG, 300.0, 0.0, 100.0, 600, 100 },
        { "mid", THUG, 3000.0, 0.0, 100.0, 600, 100 },
        { "boss", "BP_Monster_Boss_C", 2000.0, 3000.0, 100.0, 5000, 400, true },
    }
    local function brain(e)
        return field(field(field(e, "Controller"), "BrainComponent"), "running")
    end
    local function floor(e)
        return field(field(field(e, "AttributeSetBase"), "Health_Min"), "CurrentValue")
    end
    local function line(pc, name)
        return net(pc).remoteEnemies["sp:" .. name] or {}
    end
    local s = party(list)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 11000, 0)        -- 110 m off, by one the host's game has asleep
    Session.moveTo(b, 500, 500)
    Session.moveTo(c, 3300, 0)         -- by one 30 m from the host, which is after the host
    local midH = Session.enemyOn(h, "mid")
    Fake.put(field(midH, "picker"), "SwitchTargetCooldown", 1e9)
    Fake.put(midH, "target", h.pawn)
    s:run(3)
    local onH, onA = Session.enemyOn(h, "byguest"), Session.enemyOn(a, "byguest")
    check(line(a, "byguest").Asleep == true, "one by a guest away from the host: its line says it's asleep there")
    check(brain(onA) == true and floor(onA) == 0, "that guest's game runs its own copy: awake, and not held")
    check(count(h.sent, "RUN sp:") == 0, "handed to nobody: a party has no handing over")
    check(line(c, "mid").X ~= nil and line(c, "mid").Asleep ~= true and brain(Session.enemyOn(c, "mid")) == false,
        "one after the host from within 30 m, a guest by it: the host's to run, as ever")
    Fake.put(midH, "target", nil)
    s:run(2)
    check(line(c, "mid").Asleep == true and brain(Session.enemyOn(c, "mid")) == true,
        "after nobody, the guest by it 33 m from the host: asleep there, that guest's own (two players' distances)")
    check(brain(Session.enemyOn(b, "byhost")) == false and floor(Session.enemyOn(b, "byhost")) == 1, "and one by the host")
    -- Its health is the host's world's: the guest's blow goes there, and comes to every other copy.
    local full = select(1, Fake.health(onH))
    check(select(1, Fake.health(onA)) == full, "the copy has the health the host's has")
    swing(a, onA, full - 50)
    s:run(1)
    check(count(a.sent, "^E D sp:byguest ") == 1 and select(1, Fake.health(onH)) == full - 50,
        "the guest's blow lands on the host's, asleep or not")
    Session.moveTo(c, 11300, 300)
    s:run(3)
    local onC = Session.enemyOn(c, "byguest")
    check(brain(onC) == true and select(1, Fake.health(onC)) == full - 50,
        "a second guest by it: a copy of its own, awake, with what the host's has left")
    -- The host walks up: awake there, and everyone's copy follows the host's again.
    Session.moveTo(h, 10900, 100)
    s:run(3)
    check(line(a, "byguest").Asleep ~= true and brain(onA) == false and floor(onA) == 1,
        "the host comes up to the guests by it: awake there, their copies held and following the host's again")
    Session.moveTo(h, 0, 0)
    s:run(3)
    check(line(a, "byguest").Asleep == true and brain(onA) == true, "the host away again: asleep there, each guest's own again")
    -- It dies in a guest's game: dead for everyone, once.
    swing(a, onA, 0)
    Fake.put(onA, "dead", true)
    s:run(2)
    check(count(a.sent, "^E GK sp:byguest$") == 1, "it dies in a guest's game, which says so")
    check(field(onH, "dead") == true and field(onC, "dead") == true, "and it's dead on the host and for the other guest by it")
    check(count(h.sent, "^E K sp:byguest$") == 1 and count(c.sent, "^E GK ") == 0, "told once")

    -- A boss a guest goes in to first, the host beside them and not in the fight: asleep there wherever the host stands.
    Session.moveTo(h, 1500, 2200)
    Session.moveTo(b, 2100, 2900)
    s:run(3)
    local bossH, bossB = Session.enemyOn(h, "boss"), Session.enemyOn(b, "boss")
    check(line(b, "boss").Boss == true and line(b, "boss").Asleep ~= true and brain(bossB) == false,
        "a boss in no fight, the host 9 m from the guest by it: the host's to run")
    b.hudLayout:RegisterBossHPBar(bossB)
    s:run(3)
    check(net(h).partnerBosses["sp:boss"] == true and line(b, "boss").Asleep == true and line(b, "boss").Boss == true,
        "a guest's fight with it, the host not in: its line says a boss, asleep there")
    check(brain(bossB) == true and floor(bossB) == 0, "the guest's game runs its copy: awake in its fight, not held")
    local left = select(1, Fake.health(bossB))
    swing(b, bossB, left - 400)
    s:run(2)
    check(math.abs(select(1, Fake.health(bossH)) - (left - 400)) < 2, "the guest's blows reach the host's all the same")
    Fake.setHealth(bossH, left - 1400)     -- (another guest's blows, landed on the host's)
    s:run(2)
    check(select(1, Fake.health(bossB)) == left - 400, "what it has left in its fight in the guest's game is that game's to say")
    h.hudLayout:RegisterBossHPBar(bossH)   -- the host walks in: its own game's fight with it
    Session.moveTo(h, 1900, 2800)
    s:run(3)
    check(line(b, "boss").Asleep ~= true and brain(bossB) == false,
        "the host in the fight: awake there, the guests' copies following the host's again")
    check(math.abs(select(1, Fake.health(bossB)) - select(1, Fake.health(bossH))) < 2, "at the health the host's has left")
    allErrors(s)

    -- A guest kills a boss asleep in the host's world: its death there is its death everywhere, the host's copy's too.
    local t = party(list)
    local th, tb, tc = t.pcs[1], t.pcs[3], t.pcs[4]
    Session.moveTo(th, 0, 0)
    Session.moveTo(t.pcs[2], 500, 0)
    Session.moveTo(tb, 2100, 2900)
    Session.moveTo(tc, 2200, 3100)
    t:run(3)
    local deadH, deadB, deadC = Session.enemyOn(th, "boss"), Session.enemyOn(tb, "boss"), Session.enemyOn(tc, "boss")
    tb.hudLayout:RegisterBossHPBar(deadB)
    t:run(3)
    swing(tb, deadB, select(1, Fake.health(deadB)) - 300)
    t:run(1)
    swing(tb, deadB, 0)
    Fake.put(deadB, "dead", true)
    t:run(3)
    check(count(tb.sent, "^E GK sp:boss$") == 1, "a guest kills a boss asleep in the host's world, and says so")
    check(field(deadH, "dead") == true and field(deadH, "realDeath") == true, "the host's copy dies by the game's own death")
    check(field(deadC, "dead") == true, "and the copy of another guest by it")
    allErrors(t)

    -- Two players: nothing sleeps by this rule (the guest's game runs what's by it, handed over).
    local u = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local ug = u.pcs[2]
    u:run(4)
    Session.moveTo(u.pcs[1], 0, 0)
    Session.moveTo(ug, 11000, 0)
    u:run(3)
    check(net(ug).mine["sp:byguest"] == true and count(u.pcs[1].logs, "sleeps here with a guest by it") == 0,
        "two players: handed over as ever, nothing called asleep")
    allErrors(u)
end

-- A party's guest who isn't by one asleep on the host runs no copy of it: theirs stays held and follows the host's.
-- Every guest with it loaded ran one, and a partner's figure beside a copy roused it: a guest fought the elite of Xigu
-- alone, and a third player 43 m off at the bell was in a fight of the game's own with their copy 3 s on, counted as in
-- that boss fight (the fighter, down, waited on them, and the boss didn't start over). The bench of 11-16, three copies.
local function aPartysBystander()
    part("a party: a guest who isn't by one asleep on the host")
    local list = {
        { "boss", "BP_Monster_Boss_C", 2000.0, 3000.0, 100.0, 5000, 400, true },
        { "thug", THUG, 12000.0, 0.0, 100.0, 600, 100 },
    }
    local function brain(e)
        return field(field(field(e, "Controller"), "BrainComponent"), "running")
    end
    local function floor(e)
        return field(field(field(e, "AttributeSetBase"), "Health_Min"), "CurrentValue")
    end
    local function line(pc, name)
        return net(pc).remoteEnemies["sp:" .. name] or {}
    end
    local s = party(list)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    Session.moveTo(h, -6000, 0)        -- the host and a guest 85 m from the boss
    Session.moveTo(a, -5800, 100)
    Session.moveTo(b, 2100, 2900)      -- one guest by it
    Session.moveTo(c, 6300, 3000)      -- and one 43 m from it, at a bell
    s:run(3)
    local bossH, bossB, bossC = Session.enemyOn(h, "boss"), Session.enemyOn(b, "boss"), Session.enemyOn(c, "boss")
    b.hudLayout:RegisterBossHPBar(bossB)
    s:run(3)
    check(line(c, "boss").Asleep == true and brain(bossB) == true and floor(bossB) == 0,
        "a guest's fight with a boss asleep on the host: the fighter's own copy, awake")
    check(brain(bossC) == false and floor(bossC) == 1, "a third player 43 m off: their copy stays held")
    check(net(c).toldFighting ~= true and count(c.sent, "^E F 1") == 0, "and they're in no fight")
    -- (The game starts a stopped AI again by itself; roused in that moment by the fighter's figure, the copy has the
    -- game's own bar put up for it. Held all the same, its player 43 m off: no fight of theirs. The bench.)
    c.hudLayout:RegisterBossHPBar(bossC)
    s:run(6)
    check(brain(bossC) == false and net(c).toldFighting ~= true and count(c.sent, "^E F 1") == 0,
        "the game's own bar on their held copy: still held, and still in no fight")
    check(c.env.PBZ.game.isMirrorBar(bossC) == true,
        "and that bar is the mirror of the partner's fight again (left the game's own, the copy was theirs the moment they stood nearest)")
    c.hudLayout:UnRegisterBossHPBar(bossC)          -- (and takes it down again, the copy stopped once more)
    s:run(1)
    local left = select(1, Fake.health(bossB))
    swing(b, bossB, left - 400)
    s:run(2)
    check(math.abs(select(1, Fake.health(bossH)) - (left - 400)) < 2
        and math.abs(select(1, Fake.health(bossC)) - (left - 400)) < 2,
        "their copy has what the host's has left (" .. select(1, Fake.health(bossC)) .. ")")
    Session.moveTo(c, 4500, 3000)
    s:run(3)
    check(brain(bossC) == true and floor(bossC) == 0, "they walk up to 25 m from it: a copy of their own, awake")
    Session.moveTo(c, 6300, 3000)
    s:run(3)
    check(brain(bossC) == true and floor(bossC) == 0, "back at 43 m: theirs still (the game's own 45 m)")
    Session.moveTo(c, 7200, 3000)
    s:run(3)
    check(brain(bossC) == false and floor(bossC) == 1, "at 52 m and in no fight with it: held again, following the host's")
    -- Who else is near makes no difference ("nobody nearer" woke a watcher's copy 42 m off on the bench, as the fighter
    -- stepped in): 30 m it is, for a guest alone too.
    Session.moveTo(h, 1000, 0)         -- (110 m from it: within the host's reach of a guest)
    Session.moveTo(a, 1200, 100)
    Session.moveTo(c, 8000, 0)
    s:run(5)
    local thugC = Session.enemyOn(c, "thug")
    check(line(c, "thug").Asleep == true and brain(thugC) == false and floor(thugC) == 1,
        "a guest alone 40 m from one asleep on the host: held still ("
        .. tostring(line(c, "thug").Asleep) .. " " .. tostring(brain(thugC)) .. " " .. tostring(floor(thugC)) .. ")")
    Session.moveTo(c, 9300, 0)
    s:run(3)
    check(brain(thugC) == true and floor(thugC) == 0, "at 27 m from it: their own copy")
    Session.moveTo(b, 11800, 0)
    Session.moveTo(c, 7800, 0)
    s:run(3)
    check(brain(thugC) == true, "(a partner comes by it and they step back to 42 m: theirs still)")
    -- Kited past the 45 m while it still fights them: theirs till that fight is over, the game's to end, and the host's
    -- to follow once it's idle. (The fake's enemies had no AI state, and this line of the rule never ran: the third
    -- review's G4.)
    local kiteAi = rawget(field(thugC, "Controller"), "__fields").SGameAIComponent
    local kiteState = "AI.State.Combat"
    kiteAi.CurrentStateTag = { TagName = { ToString = function() return kiteState end } }
    Session.moveTo(c, 6000, 0)
    s:run(3)
    check(brain(thugC) == true and floor(thugC) == 0, "a thug of theirs kited to 60 m, still fighting them: theirs still")
    kiteState = "AI.State.Idle"
    s:run(3)
    check(brain(thugC) == false and floor(thugC) == 1, "and held again once it's idle, 60 m off: the host's to follow")
    allErrors(s)

    -- The same bar before the fighter's own fight is told (the bench: the watcher's came first, the second time round):
    -- no partner's fight to go by yet, and the watcher's copy woke as "their own fight". Whose it is goes by who's
    -- nearest it.
    local t = party(list)
    local th, tb, tc = t.pcs[1], t.pcs[3], t.pcs[4]
    Session.moveTo(th, -6000, 0)
    Session.moveTo(t.pcs[2], -5800, 100)
    Session.moveTo(tb, 2100, 2900)     -- by the boss, its fight not begun
    Session.moveTo(tc, 6300, 3000)     -- the watcher, 43 m off
    t:run(3)
    local early = Session.enemyOn(tc, "boss")
    tc.hudLayout:RegisterBossHPBar(early)
    t:run(6)
    check(line(tc, "boss").Asleep == true and brain(early) == false and floor(early) == 1
        and net(tc).toldFighting ~= true and count(tc.sent, "^E F 1") == 0,
        "the game's own bar on the watcher's copy before the fighter's fight is told: held all the same, in no fight")
    check(not tc.env.PBZ.game.bossFightActive(), "and with no partner's fight to mirror, that bar is taken down")
    -- (The third review.) That bar was told as a fight of the watcher's own before it was taken down, and nothing ended
    -- it: the host filed the fight as the watcher's, the fighter's own was never told, and the fighter's lost fight
    -- never started over: the next try began where the last ended.
    check(count(tc.sent, "^E B sp:boss") == 0, "nor told to anyone as a fight of the watcher's")
    local onH, onB = Session.enemyOn(th, "boss"), Session.enemyOn(tb, "boss")
    tb.hudLayout:RegisterBossHPBar(onB)             -- (the fighter's own fight begins)
    t:run(3)
    check(count(tb.sent, "^E B sp:boss") >= 1 and net(th).fightOf["sp:boss"] == 3,
        "the fighter's own fight is told, and the host has it as theirs")
    local left, most = Fake.health(onB)
    while left > most * 0.3 + 1 do
        left = math.max(most * 0.3, left - most * 0.1)
        swing(tb, onB, left)
        t:run(0.6)
    end
    t:run(2)
    local low, hostMost = Fake.health(onH)
    Session.die(tb)
    tb.hudLayout:UnRegisterBossHPBar(onB)           -- (the game takes the bar down as its player dies)
    t:run(7)
    Session.moveTo(tb, 2100 - 15000, 2900)          -- (back at a bell 150 m off, its world refreshed: its boss new, at full)
    Session.respawned(tb)
    Fake.setHealth(onB, select(2, Fake.health(onB)))
    Session.revive(tb)
    t:run(8)
    check(low < hostMost * 0.4 and select(1, Fake.health(onH)) >= hostMost - 1,
        string.format("the fighter loses alone: the boss at full on the host again (it stood at %.0f; now %.0f/%.0f)", low,
            select(1, Fake.health(onH)), hostMost))
    allErrors(t)

    -- A held copy left in a fight's state (the game starts a stopped AI again by itself, and a figure beside it rouses
    -- it for that moment): put back to idle, the game's own way, and less and less often. Not through a partner's fight
    -- with it: the game took the mirror bar down with "its fight".
    local k = party(list)
    local kb, kc = k.pcs[3], k.pcs[4]
    Session.moveTo(k.pcs[1], -6000, 0)
    Session.moveTo(k.pcs[2], -5800, 100)
    Session.moveTo(kb, 2100, 2900)
    Session.moveTo(kc, 6300, 3000)
    k:run(3)
    local held = Session.enemyOn(kc, "boss")
    local state, calms = "AI.State.Combat", 0
    local ai = rawget(field(held, "Controller"), "__fields").SGameAIComponent
    ai.CurrentStateTag = { TagName = { ToString = function() return state end } }
    ai.StopAI = function() end
    ai.StartAI = function()
        state, calms = "AI.State.Idle", calms + 1
    end
    k:run(3)
    check(calms == 1 and state == "AI.State.Idle" and count(kc.logs, "is held here in a fight's state from before: put back to idle") == 1,
        "a watcher's held copy left in a fight's state: put back to idle, and said once (" .. calms .. ")")
    for _ = 1, 30 do                                -- (one with a fight of its own in that world: in it again at once)
        state = "AI.State.Combat"
        k:run(1)
    end
    check(calms >= 3 and calms <= 8 and count(kc.logs, "put back to idle") == 1,
        "roused again and again for 30 s: calmed less and less often, not every second (" .. calms .. " times)")
    kb.hudLayout:RegisterBossHPBar(Session.enemyOn(kb, "boss"))     -- (a partner's fight with it begins)
    k:run(3)
    local before = calms
    state = "AI.State.Combat"
    k:run(35)                                       -- (past the longest wait of the calm before it, 30 s)
    check(calms == before, "through a partner's fight with it, 35 s: not calmed (the mirror bar went with it) ("
        .. calms - before .. ")")
    allErrors(k)

    -- A partner's fight that has moved away from where the boss sleeps on the host, where a held copy stays: the
    -- watcher 43 m off is the nearest to theirs now. A stray bar on it is still that fight's mirror.
    local u = party(list)
    local uh, ub, uc = u.pcs[1], u.pcs[3], u.pcs[4]
    Session.moveTo(uh, -6000, 0)
    Session.moveTo(u.pcs[2], -5800, 100)
    Session.moveTo(ub, 2100, 2900)
    Session.moveTo(uc, 6300, 3000)
    u:run(3)
    local fighters, watchers = Session.enemyOn(ub, "boss"), Session.enemyOn(uc, "boss")
    ub.hudLayout:RegisterBossHPBar(fighters)
    u:run(3)
    Session.moveTo(ub, -3500, 3000)                 -- (their fight, 55 m from that spot now)
    u:run(2)
    uc.hudLayout:RegisterBossHPBar(watchers)
    u:run(6)
    check(brain(watchers) == false and floor(watchers) == 1 and net(uc).toldFighting ~= true
        and uc.env.PBZ.game.isMirrorBar(watchers) == true and count(uc.sent, "^E B sp:boss") == 0,
        "a partner's fight moved 55 m off, the watcher the nearest to their held copy: a stray bar on it is still the mirror")
    allErrors(u)

    -- A guest's own fight begun from 40 m (the game's own 45 m), a partner in no fight standing a little nearer, 35 m
    -- from it: to this game the same as a watcher's stray bar with the one about to fight that far off (below). Held,
    -- and told to nobody, till they're within 30 m.
    local v = party(list)
    local vh, va, vc = v.pcs[1], v.pcs[2], v.pcs[4]
    Session.moveTo(vh, -6000, 0)
    Session.moveTo(v.pcs[3], -5800, 100)
    Session.moveTo(va, 5500, 3000)
    Session.moveTo(vc, 6000, 3000)
    v:run(3)
    local mine = Session.enemyOn(vc, "boss")
    vc.hudLayout:RegisterBossHPBar(mine)
    v:run(4)
    check(brain(mine) == false and count(vc.sent, "^E B sp:boss") == 0 and net(vh).partnerBosses["sp:boss"] == nil,
        "a guest's own bar from 40 m, a partner in no fight 35 m from it: held, and told to nobody")
    Session.moveTo(vc, 4700, 3000)
    v:run(2)
    vc.hudLayout:RegisterBossHPBar(mine)            -- (the game's bar again, as the copy, theirs now, takes them on)
    v:run(4)
    check(brain(mine) == true and floor(mine) == 0 and net(vh).fightOf["sp:boss"] == 4,
        "within 30 m: theirs, awake, and told")
    allErrors(v)
    -- The same, and the guest strikes it from there (a thrown blade's blow, a cannon's): theirs from that blow, whoever's
    -- nearer. Held, each blow went to the host and came off the boss asleep there, which never fought back, nobody in
    -- its fight. A stray bar is no blow: the race below is as it was. (The fifth review's V5.)
    local x = party(list)
    local xh, xc = x.pcs[1], x.pcs[4]
    Session.moveTo(xh, -6000, 0)
    Session.moveTo(x.pcs[3], -5800, 100)
    Session.moveTo(x.pcs[2], 5500, 3000)
    Session.moveTo(xc, 6000, 3000)
    x:run(3)
    local shot = Session.enemyOn(xc, "boss")
    xc.hudLayout:RegisterBossHPBar(shot)
    x:run(4)
    swing(xc, shot, select(1, Fake.health(shot)) - 300)
    x:run(1.5)
    xc.hudLayout:RegisterBossHPBar(shot)            -- (the game's bar again, as the copy, theirs now, takes them on)
    x:run(4)
    check(brain(shot) == true and floor(shot) == 0 and net(xh).fightOf["sp:boss"] == 4,
        "a guest's own bar from 40 m, a partner nearer, and a blow of theirs from there: theirs, awake, and told")
    allErrors(x)
    -- The same blow at one the game gives a boss's bar and the codex doesn't call a boss (the hook man): a boss only
    -- while its bar is up, and a held copy's bar is taken down at once, so its blows set no mark and wore down the copy
    -- asleep on the host, which never fought back. A blow marks any copy asleep on the host. (The sixth review's V6.)
    do
        local e = party({ { "elite", "BP_Monster_GoldMaskMan_C", 2000.0, 3000.0, 100.0, 5000, 400 } })
        local eh, ec = e.pcs[1], e.pcs[4]
        Session.moveTo(eh, -6000, 0)
        Session.moveTo(e.pcs[3], -5800, 100)
        Session.moveTo(e.pcs[2], 5500, 3000)
        Session.moveTo(ec, 6000, 3000)
        e:run(3)
        local far = Session.enemyOn(ec, "elite")
        ec.hudLayout:RegisterBossHPBar(far)
        e:run(4)
        swing(ec, far, select(1, Fake.health(far)) - 300)
        e:run(1.5)
        ec.hudLayout:RegisterBossHPBar(far)         -- (the game's bar again, as the copy, theirs now, takes them on)
        e:run(4)
        check(brain(far) == true and floor(far) == 0 and net(eh).fightOf["sp:elite"] == 4,
            "the same blow at one with the game's bar that the codex doesn't call a boss: theirs, awake, and told ("
                .. tostring(brain(far)) .. ", " .. tostring(net(eh).fightOf["sp:elite"]) .. ")")
        allErrors(e)
    end
    -- A watcher who struck it half a minute ago (no death and no rest since), walked off past 45 m and is back 43 m
    -- from it as a nearer partner's fight is about to begin. By the mark of that old blow their copy was theirs again
    -- at once, woken with no bar and no new blow, and its stray bar told the fight as theirs. A blow of the last few
    -- seconds counts, not the mark. (The sixth review's V5.)
    do
        local o = party(list)
        local oh, ob, oc = o.pcs[1], o.pcs[3], o.pcs[4]
        Session.moveTo(oh, -6000, 0)
        Session.moveTo(o.pcs[2], -5800, 100)
        Session.moveTo(ob, -1500, 3000)             -- (the fighter-to-be 35 m off, no fight yet)
        Session.moveTo(oc, 2300, 3000)              -- (the watcher by the boss, earlier)
        o:run(4)
        local strayO, ownO = Session.enemyOn(oc, "boss"), Session.enemyOn(ob, "boss")
        swing(oc, strayO, select(1, Fake.health(strayO)) - 200)
        o:run(2)
        Session.moveTo(oc, 7200, 3000)              -- (away past 45 m: no death, no rest)
        o:run(30)
        Session.moveTo(oc, 6300, 3000)              -- (back, 43 m off)
        o:run(3)
        check(net(oc).struck["sp:boss"] == true and brain(strayO) == false and floor(strayO) == 1,
            "a watcher who struck it half a minute ago, back 43 m from it with a partner nearer: held, with no bar and no new blow")
        oc.hudLayout:RegisterBossHPBar(strayO)
        o:run(1.5)
        Session.moveTo(ob, 2100, 2900)
        ob.hudLayout:RegisterBossHPBar(ownO)
        o:run(3)
        check(count(oc.sent, "^E B sp:boss") == 0 and net(oh).fightOf["sp:boss"] == 3,
            "their stray bar before the fight of the one nearer begins: told to nobody, the fight the fighter's on the host ("
                .. tostring(net(oh).fightOf["sp:boss"]) .. ")")
        allErrors(o)
    end

    -- A watcher's stray bar with the one about to fight still 35 m off, not told yet; then their own fight begins:
    -- nearer is nearer, beside it or not. (Counted only within 30 m or in a fight, the watcher's copy was made theirs,
    -- woken and told, the fighter's own was never told, and their lost fight never started over. The fourth review.)
    for _, sameFrame in ipairs({ false, true }) do
        local w = party(list)
        local wh, wb, wc = w.pcs[1], w.pcs[3], w.pcs[4]
        Session.moveTo(wh, -6000, 0)
        Session.moveTo(w.pcs[2], -5800, 100)
        Session.moveTo(wb, -1500, 3000)    -- 35 m off, no fight yet
        Session.moveTo(wc, 6300, 3000)     -- the watcher, 43 m off
        w:run(3)
        local strayW, ownW = Session.enemyOn(wc, "boss"), Session.enemyOn(wb, "boss")
        if sameFrame then
            wb.hudLayout:RegisterBossHPBar(ownW)        -- (their own fight begun by the game from 35 m, the stray with it)
        end
        wc.hudLayout:RegisterBossHPBar(strayW)
        w:run(1.5)
        if not sameFrame then
            Session.moveTo(wb, 2100, 2900)
            wb.hudLayout:RegisterBossHPBar(ownW)
        end
        w:run(3)
        check(brain(strayW) == false and floor(strayW) == 1 and net(wc).toldFighting ~= true
            and count(wc.sent, "^E F 1") == 0 and count(wc.sent, "^E B sp:boss") == 0,
            "a watcher's stray bar " .. (sameFrame and "as" or "before") .. " the fight of one 35 m off begins: held, in no fight")
        check(net(wh).fightOf["sp:boss"] == 3, "and the host has that fight as the fighter's")
    end

    -- A blow on a copy with no bar of the game's on it, then away past 45 m and back: no fight of theirs, and none
    -- told. (328's re-tell went by "in it", which a blow from near alone says: the host had a fight filed, its bar up
    -- and its walls shut, for a fight nobody was in. The fourth review's V3.)
    do
        local k = party(list)
        local kh, kb = k.pcs[1], k.pcs[3]
        Session.moveTo(kh, -6000, 0)
        Session.moveTo(k.pcs[2], -5800, 100)
        Session.moveTo(kb, 2300, 3000)
        Session.moveTo(k.pcs[4], 2600, 3400)        -- (another guest by it too: asleep on the host all along)
        k:run(4)
        local struck = Session.enemyOn(kb, "boss")
        kb.env.PBZ.game.noteLocalMove()
        Fake.setHealth(struck, select(1, Fake.health(struck)) - 200)
        k:run(2)
        Session.moveTo(kb, 7200, 3000)
        k:run(6)
        Session.moveTo(kb, 2300, 3000)
        k:run(6)
        check(net(kb).struck["sp:boss"] == true and count(kb.sent, "^E B ") == 0 and net(kh).partnerBosses["sp:boss"] == nil,
            "a blow with no bar, away to 52 m and back: no fight told, none shown on the host")
        allErrors(k)
    end

    -- The watcher's mirror gone with no HUD to put it back on (mid-load): put back once a second at most, each try a
    -- search of the HUD and of every fog wall; at every turn, it was 20 to 30 of each a second (the third review's V10).
    do
        local n = party(list)
        local nb, nc = n.pcs[3], n.pcs[4]
        Session.moveTo(n.pcs[1], -6000, 0)
        Session.moveTo(n.pcs[2], -5800, 100)
        Session.moveTo(nb, 2100, 2900)
        Session.moveTo(nc, 6300, 3000)
        n:run(3)
        local mirror = Session.enemyOn(nc, "boss")
        nb.hudLayout:RegisterBossHPBar(Session.enemyOn(nb, "boss"))
        n:run(3)
        local had, searches, noHud, find = nc.env.PBZ.game.isMirrorBar(mirror) == true, 0, true, nc.env.FindFirstOf
        nc.env.FindFirstOf = function(class)
            if class == "PBZHUDLayout" and noHud then
                searches = searches + 1
                return nil
            end
            return find(class)
        end
        nc.hudLayout:UnRegisterBossHPBar(mirror)
        n:run(2)
        noHud = false
        n:run(2)
        check(had and searches <= 6 and nc.env.PBZ.game.isMirrorBar(mirror) == true, "the watcher's mirror gone and no HUD for 2 s: "
            .. "put back once a second at most (" .. searches .. " searches of the HUD), and back with the HUD")
        allErrors(n)
    end
end

-- A party's guest far from an enemy the host's lines tell of (another guest is by it) and that its own world hasn't:
-- not its to bring back. The host's lines reach every guest; a copy is paired within 60 m of its own player; the mod
-- brought back what was missing within 120 m. So one 95 m off read as missing for good and was asked for every 10 s,
-- and on the bench (11-16, three copies) each one brought back was dead seconds later and paid dust, shared on.
local function farEnemiesStay()
    part("a party: an enemy far from this guest isn't brought back")
    local s = party({ { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 } })
    local h, a, c = s.pcs[1], s.pcs[2], s.pcs[4]
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 11000, 0)        -- one guest by it, 110 m from the host
    Session.moveTo(s.pcs[3], 300, 200)
    Session.moveTo(c, 2500, 0)         -- and one 90 m from it, whose world hasn't got it
    local i = Session.indexOf(c, "byguest")
    local mine, sp = c.enemies[i], c.spawners[i]
    Fake.put(sp, "record", false)
    Fake.put(sp, "SpawnedAI", nil)
    table.remove(c.enemies, i)
    s:run(35)
    check(net(c).remoteEnemies["sp:byguest"] ~= nil and (field(sp, "claimed") or 0) == 0,
        "the host's line of it reaches a guest 90 m off whose world hasn't got it: not brought back there ("
        .. tostring(field(sp, "claimed") or 0) .. " times)")
    Session.moveTo(c, 6500, 0)
    s:run(8)
    check((field(sp, "claimed") or 0) == 1 and count(c.logs, "brought back while you play together") == 1,
        "that guest comes within 50 m of it: brought back, once")
    s:run(52)
    check((field(sp, "claimed") or 0) <= 3, "one that never comes is asked for less and less often ("
        .. tostring(field(sp, "claimed")) .. " times in a minute)")
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
    -- (Its fight begun by the game 35 m off, the fighter nearest it: spread puts players 2 and 3 the same 39 m from it,
    -- and whose copy it is goes by who's nearest, handover.byHere. The fifth review.)
    local q = party()
    spread(q)
    local qa = q.pcs[2]
    Session.moveTo(qa, -500, 3000)
    q:run(2)
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
    -- The guest sits at a bell during it: the fight starts over, the host rested (the gourd to its whole size, its extra
    -- drink counted in) and the boss back to full health (the user, 11-12: "you heal back and the boss goes full"). Told.
    local wboss = Session.enemyOn(wh, "boss")
    local _, bossMax = Fake.health(wboss)
    Fake.setHealth(wboss, bossMax * 0.3)
    Fake.setHealth(wh.pawn, 100)
    Fake.put(wh.gourd, "CurrentTime", 1)
    Session.sit(wg)
    w:run(2)
    check(Fake.health(wboss) == bossMax and Fake.health(wh.pawn) == 1000 and field(wh.gourd, "CurrentTime") == 3
        and count(wh.logs, "Status: your partner rested at a bell: you're rested, and so is the boss%.") == 1,
        string.format("the guest sits during the host's boss fight: the boss back to full, the host rested (%d, gourd %d of 2 and "
            .. "an extra), and told", Fake.health(wh.pawn), field(wh.gourd, "CurrentTime")))
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
    -- (360: an enemy with no controller, a camp put away by its spawner, isn't handed into the game's GetTargetActor as
    -- nothing, the one None no pcall catches, as a partner goes silent and game.ghostInFight asks every listed enemy.
    -- The seventh review's V9.)
    local lib = h.env.StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local ask, none = rawget(lib, "__fields").GetTargetActor, 0
    rawget(lib, "__fields").GetTargetActor = function(self, c, o)
        none = none + ((c == nil or rawget(c, "__alive") == false) and 1 or 0)
        return ask(self, c, o)
    end
    local had = field(e, "Controller")
    Fake.put(e, "Controller", setmetatable({ __addr = 8, __class = "AIController", __alive = false,
        __fields = { SGameAIComponent = { SpawnedAIScripts = { ForEach = function() end, items = {} } } } }, h.meta))
    s.pcs[2].cut = true
    s:run(5)
    s.pcs[2].cut = false
    s:run(5)
    Fake.put(e, "Controller", had)
    rawget(lib, "__fields").GetTargetActor = ask
    check(none == 0, "an enemy with no controller isn't handed into the game's GetTargetActor (" .. none .. ")")
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
    -- (Out of a boss fight of their own a partner's sit rests nobody: each player rests at their own sit, as in the game, the
    -- user's rule of 11-12. It had healed everyone who was up and filled their gourds: a gourd held more drinks than it has,
    -- or fewer with extra drinks, the 1.7.1 report's "5 uses to 1 use".)
    check(Fake.health(h.pawn) == 100 and Fake.health(a.pawn) == 100 and field(a.gourd, "CurrentTime") == 0,
        string.format("a partner's sit rests nobody else: health and gourds as they were (%d, %d, gourd %d)", Fake.health(h.pawn),
            Fake.health(a.pawn), field(a.gourd, "CurrentTime")))
    Session.sit(c)
    s:run(2)
    check(Fake.health(a.pawn) == 100 and field(a.gourd, "CurrentTime") == 0 and count(a.logs, "Status: .* rested at a bell") == 0,
        "nor a second one, and with no boss fight nothing's said")
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

-- Any sit puts the bosses of fights back to full health, in the world that runs them (the user, 11-12: "a sit should make boss
-- health go full i am scared people will abuse it"), and a player in a boss fight, their own or one they joined or struck, is
-- rested with it ("you heal back and the boss goes full"). A review found the boss half missing for a guest's own fight on a boss near the host: the
-- host's world runs it, the guest's copy follows its health only ever down, and the copy put back to full alone was taken
-- down again by the next line, the guest rested and told it was full.
local function sitBosses()
    part("a sit and the bosses of fights still on")
    local TIP = "Status: .* rested at a bell: you're rested, and so is the boss%."
    local function hp(a)
        return math.floor((Fake.health(a)) + 0.5)
    end
    local function two()            -- (as pair(), which comes later in this file)
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        s:run(4)
        Session.moveTo(s.pcs[1], 0, 0)
        Session.moveTo(s.pcs[2], 500, 0)
        s:run(2)
        return s, s.pcs[1], s.pcs[2]
    end
    -- The guest's own fight on a boss near the host, the host not in it; the host sits nearby. (The guest's game runs that
    -- boss now, guestRunsItsBoss: its blows land there, and the host's copy follows.)
    do
        local s, h, g = two()
        Session.moveTo(g, 2700, 2700)
        s:run(3)
        g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(3)
        local hb, gb = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        local _, hmax = Fake.health(hb)
        local _, gmax = Fake.health(gb)
        Fake.setHealth(gb, gmax * 0.3)          -- (the guest's blows, in the guest's game)
        Fake.setHealth(g.pawn, 100)
        s:run(2)
        local before, hostBefore = hp(gb), hp(hb)
        Session.sit(h)
        s:run(3.3)
        check(before < gmax and hostBefore < hmax and hp(hb) >= hmax - 1 and hp(gb) >= gmax - 1 and Fake.health(g.pawn) == 1000
            and count(g.logs, TIP) == 1,
            string.format("the guest's own fight on a boss by the host: the host sits, and it's full in both worlds, the "
                .. "guest rested and told (host %d of %d from %d, guest %d of %d from %d; guest %d)", hp(hb), hmax, hostBefore,
                hp(gb), gmax, before, Fake.health(g.pawn)))
        allErrors(s)
    end
    -- The same fight, the guest the one who sits (out of it, then back in): the host's boss full too, before the fight ends.
    do
        local s, h, g = two()
        Session.moveTo(g, 2700, 2700)
        s:run(3)
        g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(3)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        s:run(2)
        Session.sit(g)
        s:run(3)
        check(hp(hb) >= hmax - 1, "and the guest the one who sits: the host's boss of their fight full as it ends: " .. hp(hb))
        allErrors(s)
    end
    -- The host far off, the guest's own world running the boss: its copy is the boss.
    do
        local s, h, g = two()
        Session.moveTo(h, -30000, 0)
        Session.moveTo(g, 2700, 2700)
        s:run(3)
        g.hudLayout:RegisterBossHPBar(Session.enemyOn(g, "boss"))
        s:run(3)
        local gb = Session.enemyOn(g, "boss")
        local _, gmax = Fake.health(gb)
        g.env.PBZ.game.noteLocalMove()
        Fake.setHealth(gb, gmax * 0.3)
        s:run(2)
        Session.sit(h)
        s:run(3)
        check(hp(gb) >= gmax - 1 and count(g.logs, TIP) == 1,
            string.format("the host far off, the guest's world running the boss: full, the guest told (%d of %d)", hp(gb), gmax))
        allErrors(s)
    end
    -- A party: the host's fight with guests 2 and 3 in it (each has struck the boss), guest 4 sits elsewhere.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
        s:run(4)
        local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
        Session.moveTo(h, 2600, 2600)
        Session.moveTo(a, 2700, 2600)
        Session.moveTo(b, 2600, 2700)
        Session.moveTo(c, -500, 0)
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        for _, pc in ipairs({ a, b }) do
            pc.env.PBZ.game.noteLocalMove()
            local e = Session.enemyOn(pc, "boss")
            Fake.setHealth(e, (Fake.health(e)) - 10)
        end
        s:run(2)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        for _, pc in ipairs({ a, b }) do
            Fake.setHealth(pc.pawn, 100)
            Fake.put(pc.gourd, "CurrentTime", 0)
        end
        s:run(3)
        Session.sit(c)
        s:run(3)
        -- (A helper in a fight is rested as its owner is: "you heal back and the boss goes full". A review, 11-12: they had
        -- the boss full and nothing else.)
        local function rested(pc)
            return Fake.health(pc.pawn) == 1000 and field(pc.gourd, "CurrentTime") == 3 and count(pc.logs, TIP) == 1
        end
        check(hp(hb) >= hmax - 1 and count(h.logs, TIP) == 1 and rested(a) and rested(b),
            string.format("a party: the host's fight with two guests in it, a third guest sits: the boss full (%d of %d), the host and "
                .. "both guests helping in it rested and told (%d, gourd %d; %d, gourd %d)", hp(hb), hmax, Fake.health(a.pawn),
                field(a.gourd, "CurrentTime"), Fake.health(b.pawn), field(b.gourd, "CurrentTime")))
        allErrors(s)
    end
    -- A party: guest 2's own fight on a boss the host's world runs; guest 3 sits.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
        s:run(4)
        local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
        Session.moveTo(h, 0, 0)
        Session.moveTo(a, 2700, 2700)
        Session.moveTo(b, -500, 0)
        Session.moveTo(c, 0, -500)
        s:run(3)
        a.hudLayout:RegisterBossHPBar(Session.enemyOn(a, "boss"))
        s:run(3)
        local hb, ab = Session.enemyOn(h, "boss"), Session.enemyOn(a, "boss")
        local _, hmax = Fake.health(hb)
        local _, amax = Fake.health(ab)
        Fake.setHealth(hb, hmax * 0.3)
        s:run(2)
        Session.sit(b)
        s:run(3)
        check(hp(hb) >= hmax - 1 and hp(ab) >= amax - 1 and count(a.logs, TIP) == 1,
            string.format("a party: guest 2's own fight run by the host's world, guest 3 sits: full in both worlds (%d, %d), guest 2 told",
                hp(hb), hp(ab)))
        allErrors(s)
    end
    -- A party's host down and waiting in its own fight (its bar went with its death), guests 2 and 3 fighting on: a sit, by
    -- guest 4 or by guest 3 out of it, still puts the boss back to full in the host's world (a review, 11-12).
    for _, sitter in ipairs({ 4, 3 }) do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
        s:run(4)
        local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
        Session.moveTo(h, 2600, 2600)
        Session.moveTo(a, 2700, 2600)
        Session.moveTo(b, 2600, 2700)
        Session.moveTo(c, -500, 0)
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        for _, pc in ipairs({ a, b }) do
            pc.env.PBZ.game.noteLocalMove()
            local e = Session.enemyOn(pc, "boss")
            Fake.setHealth(e, (Fake.health(e)) - 10)
        end
        s:run(2)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        s:run(3)
        Session.die(h)
        h.hudLayout:UnRegisterBossHPBar(hb)        -- (the game takes the bar down as its player dies)
        s:run(6)
        local held = field(h.deathWidget, "NotTick") == true
        Fake.setHealth(a.pawn, 120)
        Fake.put(a.gourd, "CurrentTime", 0)
        Session.sit(s.pcs[sitter])
        s:run(3.4)
        local ab = Session.enemyOn(a, "boss")
        local _, amax = Fake.health(ab)
        check(held and hp(hb) >= hmax - 1 and hp(ab) >= amax - 1 and Fake.health(a.pawn) == 1000
            and field(a.gourd, "CurrentTime") == 3 and count(a.logs, TIP) == 1,
            string.format("a party's host down and waiting in its own fight, guest %d sits: the boss full in the host's world (%d of %d) "
                .. "and on guest 2 (%d), guest 2, helping in it, rested and told (%d, gourd %d)", sitter, hp(hb), hmax, hp(ab),
                Fake.health(a.pawn), field(a.gourd, "CurrentTime")))
        allErrors(s)
    end
    -- Two players: the host sits during its own fight, which the guest struck: the guest's copy full, the guest rested and told.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
        s:run(4)
        local h, g = s.pcs[1], s.pcs[2]
        Session.moveTo(h, 2600, 2600)
        Session.moveTo(g, 2700, 2600)
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        g.env.PBZ.game.noteLocalMove()
        local gb = Session.enemyOn(g, "boss")
        Fake.setHealth(gb, (Fake.health(gb)) - 10)
        s:run(2)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        s:run(3)
        local before = hp(gb)
        Fake.setHealth(g.pawn, 100)
        Fake.put(g.gourd, "CurrentTime", 0)
        Session.sit(h)
        s:run(3)
        local _, gmax = Fake.health(gb)
        check(before < gmax - 1 and hp(gb) >= gmax - 1 and hp(hb) >= hmax - 1 and Fake.health(g.pawn) == 1000
            and field(g.gourd, "CurrentTime") == 3 and count(g.logs, TIP) == 1,
            string.format("the host sits in its own fight the guest struck: full in both worlds (%d, %d), the guest helping in it rested "
                .. "and told (%d, gourd %d)", hp(hb), hp(gb), Fake.health(g.pawn), field(g.gourd, "CurrentTime")))
        allErrors(s)
    end
    -- A party, the boss far from the host (each guest's copy is the boss in its world): guest 2's fight, guest 3 struck it;
    -- guest 3 sits: its own copy full too.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES)
        s:run(4)
        local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
        Session.moveTo(h, -30000, 0)
        Session.moveTo(a, 2700, 2700)
        Session.moveTo(b, 2700, 2600)
        Session.moveTo(c, -30000, 500)
        s:run(3)
        a.hudLayout:RegisterBossHPBar(Session.enemyOn(a, "boss"))
        s:run(3)
        local ab, bb = Session.enemyOn(a, "boss"), Session.enemyOn(b, "boss")
        local _, amax = Fake.health(ab)
        local _, bmax = Fake.health(bb)
        a.env.PBZ.game.noteLocalMove()
        Fake.setHealth(ab, amax * 0.3)
        b.env.PBZ.game.noteLocalMove()
        Fake.setHealth(bb, bmax * 0.3)
        s:run(3)
        Session.sit(b)
        s:run(3)
        check(hp(bb) >= bmax - 1 and hp(ab) >= amax - 1,
            string.format("the boss far from the host, guest 3 in guest 2's fight sits: its own copy full (%d), and guest 2's (%d)",
                hp(bb), hp(ab)))
        allErrors(s)
    end
    -- The guest's own fight on a boss the host's world runs, over with the boss alive (the guest walked out: its bar down,
    -- its F 0); the guest sits, then would go back in: the host's boss full all the same (a review, 11-12).
    do
        local s, h, g = two()
        Session.moveTo(g, 2700, 2700)
        s:run(3)
        local gb = Session.enemyOn(g, "boss")
        g.hudLayout:RegisterBossHPBar(gb)
        s:run(3)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        s:run(2)
        g.hudLayout:UnRegisterBossHPBar(gb)
        s:run(8)                            -- (F 0 goes 3 s after a bar drops, through a phase change)
        local over = next(h.env.PBZ.net.partnerBosses) == nil
        Session.sit(g)
        s:run(3)
        check(over and hp(hb) >= hmax - 1,
            string.format("the guest's fight on a boss the host's world runs, over with the boss alive (%s), the guest sits: the host's "
                .. "boss full (%d of %d)", tostring(over), hp(hb), hmax))
        allErrors(s)
    end
    -- With PvP on (no match), the host in a boss fight of its own: a partner's sit changes nothing there, as before.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "PvP = On\n")
        s:run(4)
        local h, g = s.pcs[1], s.pcs[2]
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 30000, 0)
        s:run(3)
        h.hudLayout:RegisterBossHPBar(Session.enemyOn(h, "boss"))
        s:run(3)
        local hb = Session.enemyOn(h, "boss")
        local _, hmax = Fake.health(hb)
        Fake.setHealth(hb, hmax * 0.3)
        Fake.setHealth(h.pawn, 100)
        s:run(2)
        Session.sit(g)
        s:run(3)
        check(h.env.PBZ.net.pvp == true and hp(hb) < hmax - 1 and Fake.health(h.pawn) == 100 and count(h.logs, "Status: .* rested at a bell") == 0,
            string.format("PvP on, the host in its own boss fight, the guest sits: nothing changes there, as before (boss %d of %d, "
                .. "host %d)", hp(hb), hmax, Fake.health(h.pawn)))
        allErrors(s)
    end
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
    local downHp = Fake.health(rg.pawn)
    Session.sit(rh)
    r:run(2)
    -- (A partner's sit does nothing for one who's down: their partner's strikes or the timer decide. The user's pick, 11-12:
    -- "you only heal when you yourself sit on the bell or die". It had got them up, rested.)
    check(net(rh).partnerDowned == true and Fake.health(rg.pawn) == downHp,
        string.format("the host sits: a guest who's down stays down (%d health, as before the sit)", Fake.health(rg.pawn)))
    allErrors(r)
    -- Down in a boss fight of their own: still down (their pick), not rested, the boss back to full all the same.
    local r2 = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "Revive = On\n")
    r2:run(4)
    local r2h, r2g = r2.pcs[1], r2.pcs[2]
    Session.moveTo(r2h, 0, 0)
    Session.moveTo(r2g, 2700, 2700)
    r2:run(3)
    r2g.hudLayout:RegisterBossHPBar(Session.enemyOn(r2g, "boss"))
    r2:run(3)
    local rboss = Session.enemyOn(r2h, "boss")
    local _, rmax = Fake.health(rboss)
    Fake.setHealth(rboss, rmax * 0.3)
    Fake.setHealth(r2g.pawn, 1)
    r2:run(2)
    local downHp2 = Fake.health(r2g.pawn)
    Session.sit(r2h)
    r2:run(3)
    check(net(r2h).partnerDowned == true and Fake.health(r2g.pawn) == downHp2 and Fake.health(rboss) >= rmax - 1
        and count(r2g.logs, "Status: .* rested at a bell") == 0,
        string.format("down in a boss fight of their own, the host sits: the guest stays down (%d), the boss full (%d of %d)",
            Fake.health(r2g.pawn), Fake.health(rboss), rmax))
    allErrors(r2)

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

local function dragonPillarBoss()
    part("joining the Gold-Masked One's Dragon Pillar fight")
    local id = "MoTianOld_Seq018-Mask"
    local name = "sp:" .. id
    local list = { { id, "BP_Monster_MoTian_LongZhu_01_C", 700, 0, 100, 72840, 900, true } }

    local function setSide(boss, faction, team, state)
        local controller = field(boss, "Controller")
        Fake.put(field(boss, "faction"), "faction", faction)
        field(controller, "Team").TeamID = team
        field(controller, "SGameAIComponent").CurrentStateTag = { TagName = { ToString = function() return state end } }
    end

    local function start(starter, mirrorFaction)
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local h, g = s.pcs[1], s.pcs[2]
        h.perceive, g.perceive = true, true
        Session.moveTo(h, -1100, 0)
        Session.moveTo(g, 1100, 0)
        local onH, onG = Session.enemyOn(h, id), Session.enemyOn(g, id)
        if starter == "Guest" then
            setSide(onH, mirrorFaction, 1, "AI.State.Idle")
            setSide(onG, "Faction.Enemy", 0, "AI.State.Combat")
        else
            setSide(onH, "Faction.Enemy", 0, "AI.State.Combat")
            setSide(onG, mirrorFaction, 1, "AI.State.Idle")
        end
        s:run(7)
        if starter == "Guest" then
            g.hudLayout:RegisterBossHPBar(onG)
        else
            h.hudLayout:RegisterBossHPBar(onH)
        end
        s:run(4)
        return s, h, g, onH, onG
    end

    local s, h, g, onH, onG = start("Guest", "Faction.Player")
    check(net(h).guestRuns[name] and net(g).mine[name], "the guest drives the encounter it started")
    check(h.env.PBZ.coop.joinFarFight(), "the host can join the guest's encounter through the normal F3 path")
    s:run(6)
    check(net(h).guestRuns[name] and net(g).mine[name], "F3 alone doesn't transfer the fight to the host's idle copy")
    check(Fake.lands(onH), "the host can hit the guest-driven mirror before starting its own encounter")
    local hatred = field(field(onG, "BP_PBZHatredManagerComponent"), "HatredList").items
    local hostHated = false
    for _, body in ipairs(hatred) do
        hostHated = hostHated or body == net(g).ghost
    end
    check(hostHated, "the guest-driven boss adds the host to its hatred list")
    local before = select(1, Fake.health(onG))
    swing(h, onH, select(1, Fake.health(onH)) - 320)
    s:run(2)
    check(select(1, Fake.health(onG)) < before, "the host's hit reduces the guest-driven boss's authoritative health")
    Session.moveTo(h, 710, 0)
    Session.moveTo(g, 1500, 0)
    s:run(12)
    check(hostHated and field(onG, "target") == net(g).ghost, "the guest-driven boss can select the host as its target")

    setSide(onH, "Faction.Enemy", 0, "AI.State.Combat")
    h.hudLayout:RegisterBossHPBar(onH)
    s:run(4)
    check(not net(h).guestRuns[name] and not net(g).mine[name], "the host takes over when its own boss encounter starts")
    check(g.env.PBZ.game.aim.steered[onG:GetAddress()] == nil, "the guest releases its target picker on handover")
    allErrors(s)

    s, h, g, onH, onG = start("Host", "Faction.Enemy")
    check(g.env.PBZ.coop.joinFarFight(), "the guest can join the host's encounter through F3")
    s:run(5)
    before = select(1, Fake.health(onH))
    local landed = swing(g, onG, select(1, Fake.health(onG)) - 320)
    s:run(2)
    check(landed and select(1, Fake.health(onH)) < before,
        "the idle guest mirror gets the hostile team and its hit reaches the host")
    h.hudLayout:UnRegisterBossHPBar(onH)
    s:run(7)
    check(field(field(onG, "Controller"), "Team").TeamID == 1,
        "the temporary team change is put back when the mirrored encounter ends")
    allErrors(s)
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
-- A boss's items reach each player once, whoever's blow it was. (The host's game pays the host and shares what it gave
-- (T); a boss's items were told to the guest by name as well (I), from the days before shares: one from each.)
-- The Mind's Eye lesson: the game cuts the player's input down to the sense and waits for it, and the sense won't start
-- while the game counts the player in a fight. Online an enemy by them that a partner fights keeps them counted, and
-- they stood there able to do nothing ("during tutorial when game asks you to perform minds eye client get softlocked").
local function mindsEyeLesson()
    part("the Mind's Eye lesson, with an enemy by the player")
    local s = pair()
    local h, g = s.pcs[1], s.pcs[2]
    local function counted(pc)
        return pc.env.PBZ.game.inCombat(pc.pawn)
    end
    local said = "The Mind's Eye lesson holds your controls"
    -- (A copy standing in a fight with this player, as the game has it: its AI's state, and the game's own way to idle.)
    local function inFight(pc, id)
        local ai = field(field(Session.enemyOn(pc, id), "Controller"), "SGameAIComponent")
        ai.state, ai.idled = "AI.State.Combat", 0
        ai.CurrentStateTag = { TagName = { ToString = function() return ai.state end } }
        ai.StopAI = function() ai.idled = ai.idled + 1 end
        ai.StartAI = function() ai.state = "AI.State.Idle" end
        return ai
    end
    local copy, hers = inFight(g, "near"), inFight(h, "near")
    g.inCombat = 2
    s:run(2)
    check(counted(g) and g.inCombat == 2 and copy.idled == 0, "in a fight with no lesson up: the game's count is the game's, a copy's fight its own")
    g.inputSets[0][g.senseSet] = 100       -- (the lesson: the sense-only set on the guest's input)
    s:run(1)
    check(copy.idled == 1 and copy.state == "AI.State.Idle", "the lesson holds the guest's controls to the sense: a copy by them standing in a fight is put back to idle, once")
    check(not counted(g) and g.inCombat == 0, "and what the game still counted is taken off, so the sense can start")
    g.inCombat = 1                          -- (the next enemy into a fight with them, the lesson still up)
    s:run(1)
    check(not counted(g) and count(g.logs, said) == 1, "and again while the lesson's up, said once")
    g.inputSets[0][g.senseSet] = nil       -- (the sense started: the lesson's done)
    g.inCombat = 1
    s:run(2)
    check(counted(g), "the lesson done: a fight is a fight again")
    h.inCombat = 1
    h.inputSets[0][h.senseSet] = 100
    s:run(1)
    check(not counted(h) and count(h.logs, said) == 1, "the host's own lesson: the count taken off the same")
    check(hers.idled == 0 and hers.state == "AI.State.Combat", "but an enemy the host's game runs is left in its fight")
    h.inputSets[0][h.senseSet] = nil
    Session.command(g, "netoff")
    s:run(1)
    g.inCombat = 1
    g.inputSets[0][g.senseSet] = 100
    s:run(2)
    check(counted(g), "with co-op off the lesson is the game's own business")
    allErrors(s)

    -- No lesson: a guest counted in a fight that nobody is fighting. The copies around them stand in fights they never
    -- fight, so never end, and the game counted the guest in one for as long as those enemies lived (the bench, 11-16:
    -- 60 m from a fight long over, a count of 3, the sense's key dead).
    local t, th, tg = pair()
    local tcopy, thers = inFight(tg, "near"), inFight(th, "near")
    tcopy.StartAI = function()             -- (the game takes the player out of that copy's fight itself)
        tcopy.state, tg.inCombat = "AI.State.Idle", tg.inCombat - 1
    end
    tg.inCombat, th.inCombat = 2, 1
    t:run(5)
    check(tcopy.idled == 0 and counted(tg), "a guest counted in a fight: left alone for a while")
    t:run(6)
    check(tcopy.idled == 1 and tg.inCombat == 1,
        "8 s with nothing going for them: a copy the host steers that stands in a fight is put back to idle")
    t:run(9)
    check(not counted(tg), "and a count no copy holds is taken off")
    check(thers.idled == 0 and counted(th), "never on the host: its enemies' fights are real")
    allErrors(t)
    local u, _, ug = pair()
    local ucopy = inFight(ug, "near")
    ug.inCombat = 1
    u:run(20, function()
        Fake.setHealth(ug.pawn, select(1, Fake.health(ug.pawn)) - 0.6)     -- (something keeps hitting them)
    end)
    check(ucopy.idled == 0 and counted(ug), "a guest who goes on losing health is in a fight: nothing is touched")
    allErrors(u)
    -- (An enemy the guest's own game runs, past the host's reach, standing in a fight by them: that fight is real.)
    local w, _, wg = pair()
    Session.moveTo(wg, 39800, 0)
    w:run(3)
    local own = inFight(wg, "toofar")
    wg.inCombat = 1
    w:run(20)
    check(own.idled == 0 and counted(wg), "an enemy the guest's own game runs standing in a fight by them: the count stays the game's")
    allErrors(w)
    -- A guest who guards or deflects every blow loses no health: what's going for them is known by the host's moves aimed
    -- at them. (Nothing checked that: with it gone, they were taken out of their fight every 8 s. The first review's N10.)
    local x, xh, xg = pair()
    local xcopy = inFight(xg, "near")
    local foe = Session.enemyOn(xh, "near")
    Fake.put(field(foe, "picker"), "SwitchTargetCooldown", 1e9)
    Fake.put(foe, "target", net(xh).ghost)
    xg.inCombat = 1
    for _ = 1, 5 do
        Session.enemyMove(xh, "near", "/PBZCombatAsset/ActorData/Move/E1.E1")
        x:run(1.5)
        Session.enemyMove(xh, "near", nil)
        x:run(2.5)
    end
    check(xcopy.idled == 0 and counted(xg),
        "a host's enemy going for a guest who loses no health, a move every 4 s for 20 s: still their fight ("
            .. xcopy.idled .. ")")
    allErrors(x)
end

local function bossItemsOnce()
    part("a boss's items, once each")
    local ITEM = "Weapon_Material_09"
    local s, h, g = pair()
    bossStart(s)
    Fake.put(Session.enemyOn(h, "boss"), "lootItems", { { ITEM, 1 } })
    Fake.put(Session.enemyOn(g, "boss"), "lootItems", { { ITEM, 1 } })
    s:run(2)
    local h0, g0 = Session.items(h, ITEM), Session.items(g, ITEM)
    swing(g, Session.enemyOn(g, "boss"), 1)         -- (onto its floor: the guest's killing blow)
    s:run(25)
    check(field(Session.enemyOn(h, "boss"), "dead") == true and Session.items(h, ITEM) - h0 == 1 and Session.items(g, ITEM) - g0 == 1,
        string.format("the guest's killing blow on the host's boss: its item once each (host %d, guest %d)",
            Session.items(h, ITEM) - h0, Session.items(g, ITEM) - g0))
    allErrors(s)
    local t, th, tg = pair()
    bossStart(t)
    Fake.put(Session.enemyOn(th, "boss"), "lootItems", { { ITEM, 1 } })
    Fake.put(Session.enemyOn(tg, "boss"), "lootItems", { { ITEM, 1 } })
    t:run(2)
    local th0, tg0 = Session.items(th, ITEM), Session.items(tg, ITEM)
    local own = Session.enemyOn(th, "boss")
    swing(th, own, 0)                                -- (the host's own killing blow, and what the game gives for it)
    Fake.put(own, "dead", true)
    th.bag:AddPropsToBackPack(1, th.env.FName(ITEM), true)
    t:run(25)
    check(Session.items(th, ITEM) - th0 == 1 and Session.items(tg, ITEM) - tg0 == 1,
        string.format("the host's own kill of its boss: its item once each (host %d, guest %d)",
            Session.items(th, ITEM) - th0, Session.items(tg, ITEM) - tg0))
    allErrors(t)
    -- Its dust too: the guest's copy dies the game's own death at the host's K, and that paid the guest the copy's own on
    -- top of the share of the host's (the bench, 11-15), which then went back to the host as the guest's earnings.
    local u, uh, ug = pair()
    bossStart(u)
    Fake.put(Session.enemyOn(uh, "boss"), "dustLoot", 700)
    Fake.put(Session.enemyOn(ug, "boss"), "dustLoot", 700)
    ug.paysAtLevelZero = true
    u:run(2)
    local uh0, ug0 = Session.dust(uh), Session.dust(ug)
    local theirs = Session.enemyOn(uh, "boss")
    swing(uh, theirs, 0)
    Fake.put(theirs, "dead", true)
    uh.pawn:ChangeDustNumInternal(700)              -- (what the game pays the host for its kill)
    u:run(25)
    check(Session.dust(uh) - uh0 == 700 and Session.dust(ug) - ug0 == 700,
        string.format("the host's kill of its boss: its dust once each (host %d, guest %d)",
            Session.dust(uh) - uh0, Session.dust(ug) - ug0))
    allErrors(u)
    -- The same with the guest down in the fight, its respawn held: the dust watch looked at no rise of a player who's
    -- down, so the copy's own stayed in the wallet and the share came on top (the bench, 11-16: the twin-blade officer of
    -- Pangzhen, 280000 for the guest who was down, 140000 for the host who killed it).
    local v, vh, vg = pair()
    bossStart(v)
    Fake.put(Session.enemyOn(vh, "boss"), "dustLoot", 700)
    Fake.put(Session.enemyOn(vg, "boss"), "dustLoot", 700)
    vg.paysAtLevelZero = true
    v:run(5)
    local vh0, vg0 = Session.dust(vh), Session.dust(vg)
    Session.die(vg)
    vg.hudLayout:UnRegisterBossHPBar(Session.enemyOn(vg, "boss"))
    v:run(6)
    check(field(vg.deathWidget, "NotTick") == true, "the guest down in the host's boss fight waits")
    local vtheirs = Session.enemyOn(vh, "boss")
    swing(vh, vtheirs, 0)
    Fake.put(vtheirs, "dead", true)
    vh.pawn:ChangeDustNumInternal(700)
    v:run(3)
    check(Session.dust(vg) - vg0 == 0, "the copy's own, paid as it died with the guest still down, is back out of the wallet: "
        .. (Session.dust(vg) - vg0))
    Session.respawned(vg)                           -- (the fight over: the guest's respawn goes on, and its share comes)
    Session.revive(vg)
    v:run(25)
    check(Session.dust(vh) - vh0 == 700 and Session.dust(vg) - vg0 == 700,
        string.format("the host's kill with the guest down in the fight: its dust once each (host %d, guest %d)",
            Session.dust(vh) - vh0, Session.dust(vg) - vg0))
    allErrors(v)
end

-- A guest's own kill of a boss its game runs (263; in a party one asleep on the host, 277). Its death there is the game's
-- own and pays that player, who shares it; the host's copy dies at the guest's word, its own pay taken back. But the
-- host's K came back with the boss still falling, not yet dead by the game's word, and its death was run there a second
-- time: the killer's pay, their earnings, was taken back as a copy's own too, and nobody had the boss's dust (the bench
-- of 11-16, three copies: 6600 taken back on the killer's PC and on the host's, the three wallets as they were).
local function guestsOwnBossKill()
    part("a guest's own kill of a boss its game runs")
    local list = { { "boss", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true } }
    local function kill(three)
        local s = three and party(list, nil, { "Host", "Guest", "Guest" })
            or Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local h, g, c = s.pcs[1], s.pcs[2], s.pcs[3]
        if not three then
            s:run(4)
        end
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 4000, 0)
        if three then
            Session.moveTo(c, -500, 300)
        end
        s:run(3)
        for _, pc in ipairs(s.pcs) do
            Fake.put(Session.enemyOn(pc, "boss"), "dustLoot", 700)
            pc.paysAtLevelZero = true
        end
        local onG = Session.enemyOn(g, "boss")
        g.hudLayout:RegisterBossHPBar(onG)
        s:run(3)
        local before = {}
        for i, pc in ipairs(s.pcs) do
            before[i] = Session.dust(pc)
        end
        swing(g, onG, select(1, Fake.health(onG)) - 300)
        s:run(1)
        swing(g, onG, 0)                    -- (its killing blow: at 0 and falling, not yet dead by the game's word)
        s:run(0.6)
        Fake.put(onG, "dead", true)
        g.pawn:ChangeDustNumInternal(700)   -- (what the game pays the guest for its kill, a second into the fall)
        s:run(25)
        local got = {}
        local once = field(Session.enemyOn(h, "boss"), "dead") == true
        for i, pc in ipairs(s.pcs) do
            got[i] = Session.dust(pc) - before[i]
            once = once and got[i] == 700
        end
        return s, once, table.concat(got, ", ")
    end
    local s, once, text = kill(false)
    check(once, "two players, the guest's kill of a boss its own game runs: its dust once each (" .. text .. ")")
    check(count(s.pcs[2].logs, "its death runs here too") == 0, "and its death isn't run a second time on the guest's PC")
    allErrors(s)
    s, once, text = kill(true)
    check(once, "a party of three, a guest's kill of a boss asleep on the host: its dust once each (" .. text .. ")")
    allErrors(s)
end

-- A copy's own cooldown ("the boss can't hit me"; the bench, 11-16, at 75 ms and 5% loss: the mounted officer of Pangzhen's
-- 7 s combo, refused on the guest's copy 6 times of 6, an animation that hit no one). The game's abilities keep a cooldown
-- of their own, stamped as each copy starts the move for itself: a moment after the host's enemy did, over the link. The
-- host's enemy uses a move as it comes off cooldown there, so by the copy's stamp it was a moment early, and refused.
local function copyCooldown()
    part("a copy's own cooldown")
    local SKILL = "/PBZCombatAsset/ActorData/Mobs/Fake/GA_Fake_Skill_03.GA_Fake_Skill_03_C"
    local s, h, g = pair()
    bossStart(s)
    s:run(2)
    local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    Fake.cooldownMove(h, boss, SKILL, 30)
    local onCopy = Fake.cooldownMove(g, copy, SKILL, 30)
    local function use()
        Fake.running(h, boss, "GA_Fake_Skill_03_C", true)
        Session.enemyMove(h, "boss", "/PBZCombatAsset/ActorData/Move/E1.E1")
        s:run(1.5)
        Fake.running(h, boss, "GA_Fake_Skill_03_C", false)
        Session.enemyMove(h, "boss", nil)
    end
    use()
    check(onCopy.starts == 1, "the host's boss uses a move: it starts on the guest's copy as an attack (" .. onCopy.starts .. ")")
    s:run(28.4)         -- (30 s on by the host's clock, as it comes off cooldown there: 29.9 s by the copy's own stamp)
    use()
    check(onCopy.starts == 2, "and again as it comes off cooldown on the host, a moment early by the copy's own stamp: it "
        .. "starts all the same (" .. onCopy.starts .. ")")
    -- Refused for another reason (a block, a break), its stamp goes back as it was; and a move still running here isn't
    -- touched. Cleared and left so, a 30 s move was there again at once for the copy's own AI; a running one cleared
    -- was started over from its beginning. (The main session's second review, 11-16.)
    onCopy.blocked = true
    s:run(28.4)
    local stamp = field(onCopy.inst, "Cooldown Mark Time")
    use()
    check(onCopy.starts == 2 and field(onCopy.inst, "Cooldown Mark Time") == stamp,
        "a move the copy won't start for another reason keeps its stamp (" .. tostring(field(onCopy.inst, "Cooldown Mark Time"))
        .. " of " .. tostring(stamp) .. ")")
    onCopy.blocked = false
    onCopy.spec.ActiveCount = 1
    use()
    check(onCopy.starts == 2 and field(onCopy.inst, "Cooldown Mark Time") == stamp,
        "and one still running there is neither cleared nor started over (" .. onCopy.starts .. ")")
    allErrors(s)
end

-- The host goes on to another map and the guest is left behind (the story plan, 11-15; "could not travel on to Lu Family
-- Village", a report on 1.6.x). With TP > PARTNER off, the host's choice for everyone, F3 said only that it's off, the tip
-- only "on another map", and there was no way after the host but to leave and join again.
local function followToAnotherMap()
    part("the host goes on to another map")
    local s, h, g = pair()
    local asked = {}
    local gcoop = g.env.PBZ.coop
    local join = gcoop.joinPartner
    gcoop.joinPartner = function(p)
        asked[#asked + 1] = p == nil and "the host" or "someone named"
        return join(p)
    end
    check(g.env.PBZ.partner.teleport == false, "TP > PARTNER is off, as it is unless chosen")
    g.env.PBZ.partner.go()
    s:run(1)
    check(#asked == 0 and count(g.logs, "TP > PARTNER is off") == 1, "F3 with the host beside you: off is off")
    h.map = "Map_Other"
    s:run(6)
    check(count(g.logs, "your partner is on another map%. F3 takes you there%.") == 1,
        "the host goes on to another map: the guest's tip says F3 takes them there")
    g.env.PBZ.partner.go()
    s:run(1)
    check(#asked == 1 and asked[1] == "the host" and count(g.logs, "TP > PARTNER is off") == 1,
        "and F3 asks for the trip to the host, as joining does (" .. #asked .. ")")
    -- The other way round a host stays: its story is its own to walk.
    local hasked = 0
    local hcoop = h.env.PBZ.coop
    local hjoin = hcoop.joinPartner
    hcoop.joinPartner = function(p)
        hasked = hasked + 1
        return hjoin(p)
    end
    h.env.PBZ.partner.go()
    s:run(1)
    check(hasked == 0 and count(h.logs, "TP > PARTNER is off") == 1, "a host isn't taken to a guest on another map")
    check(count(h.logs, "your partner is on another map%.") == 1 and count(h.logs, "F3 takes you there") == 0,
        "and its tip doesn't say so")
    allErrors(s)
end

-- The main session's review of the build (11-16: six lenses, each finding run in the sim by one or two more), its
-- confirmed findings. Its own scenarios, cut down to a check or two each.
local function reviewOfTheBuild()
    part("the review of the build")
    local list = {
        { "boss", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true },
        { "thug", THUG, 300.0, 0.0, 100.0, 600, 100 },
    }
    local plist = {
        { "byguest", THUG, 11500.0, 0.0, 100.0, 600, 100 },
        { "byhost", THUG, 300.0, 0.0, 100.0, 600, 100 },
        { "boss", "BP_Monster_Boss_C", 2000.0, 3000.0, 100.0, 5000, 400, true },
    }
    local function floorOf(e)
        return field(field(field(e, "AttributeSetBase"), "Health_Min"), "CurrentValue")
    end
    local function setFloor(e, v)
        local min = field(field(e, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", v)
        Fake.put(min, "CurrentValue", v)
    end
    local function brainOf(e)
        return field(field(e, "Controller"), "BrainComponent")
    end

    -- A guest loses a boss fight alone, the host 42 m back and never in it: the next try begins at full, as a lost fight
    -- does in the game. (The host's copy kept what the guest's game last said, and its line took the guest's new copy
    -- down to it: a retry begun at 30%.)
    -- (share: what the fight leaves it. bell: where the guest comes back, 150 m off, or 40 m from it with its copy in
    -- the host's reach all along: the host's line takes the new copy down before the fight is told over.)
    local function lost(three, share, bell)
        share = share or 0.3
        local s = three and party(list, nil, { "Host", "Guest", "Guest" })
            or Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local h, g = s.pcs[1], s.pcs[2]
        if not three then
            s:run(4)
        end
        Session.moveTo(h, 0, 0)
        Session.moveTo(g, 4000, 0)
        if three then
            Session.moveTo(s.pcs[3], -500, 300)
        end
        s:run(3)
        local onH, onG = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        g.hudLayout:RegisterBossHPBar(onG)
        s:run(3)
        local left, most = Fake.health(onG)
        local target = math.floor(most * share + 0.5)
        while left > target + 1 do
            left = math.max(target, left - most * 0.1)
            swing(g, onG, left)
            s:run(0.6)
        end
        s:run(2)
        local low = select(1, Fake.health(onH))
        Session.die(g)
        g.hudLayout:UnRegisterBossHPBar(onG)        -- (the game takes the bar down as its player dies)
        s:run(7)
        Session.moveTo(g, bell or 4200 - 15000, 0)  -- (back at a bell 150 m off, its world refreshed: its boss new, at full)
        Session.respawned(g)
        Fake.setHealth(onG, select(2, Fake.health(onG)))
        Session.revive(g)
        s:run(8)
        for _, x in ipairs({ -2000, 2000, 4000 }) do
            Session.moveTo(g, x, 0)
            s:run(x == 4000 and 5 or 2)
        end
        g.hudLayout:RegisterBossHPBar(onG)          -- (the second try begins)
        s:run(4)
        local hNow, hMost = Fake.health(onH)
        local gNow, gMost = Fake.health(onG)
        return s, low < hMost * (share + 0.1) and low < hMost - 1 and hNow >= hMost - 1 and gNow >= gMost - 1,
            string.format("it stood at %.0f; now host %.0f/%.0f, guest %.0f/%.0f", low, hNow, hMost, gNow, gMost)
    end
    local s, full, text = lost(false)
    check(full, "a guest loses a boss fight alone, the host 42 m back: the next try begins at full (" .. text .. ")")
    allErrors(s)
    s, full, text = lost(true)
    check(full, "a party of three, the boss asleep on the host: the same (" .. text .. ")")
    allErrors(s)
    -- (A copy went back up with the host's only from 5% under it: one a blow or two down stayed so, the host's whole.)
    s, full, text = lost(false, 0.97, 8200)
    check(full, "a fight that took 3% off it, the guest back at a bell 40 m from it: full for both (" .. text .. ")")
    allErrors(s)
    s, full, text = lost(true, 0.97, 8200)
    check(full, "and in a party of three (" .. text .. ")")
    allErrors(s)
    -- The host in that fight too: its own fight goes on, the boss as it was.
    local k = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local kh, kg = k.pcs[1], k.pcs[2]
    k:run(4)
    Session.moveTo(kh, 0, 0)
    Session.moveTo(kg, 4000, 0)
    k:run(3)
    local keptH, keptG = Session.enemyOn(kh, "boss"), Session.enemyOn(kg, "boss")
    kg.hudLayout:RegisterBossHPBar(keptG)
    k:run(3)
    local kmost = select(2, Fake.health(keptG))
    swing(kg, keptG, kmost * 0.6)
    k:run(2)
    Session.moveTo(kh, 3800, 300)
    k:run(2)
    swing(kh, keptH, select(1, Fake.health(keptH)) - kmost * 0.1)
    k:run(3)
    kh.hudLayout:RegisterBossHPBar(keptH)
    k:run(2)
    local before = select(1, Fake.health(keptH))
    Session.die(kg)
    k:run(7)
    Session.moveTo(kg, 4200 - 15000, 0)
    Session.respawned(kg)
    Fake.setHealth(keptG, select(2, Fake.health(keptG)))
    Session.revive(kg)
    k:run(6)
    check(math.abs(select(1, Fake.health(keptH)) - before) < 2,
        "the host in that fight too, the guest dies: the host's fight goes on, its boss as it was ("
            .. tostring(select(1, Fake.health(keptH))) .. ")")
    allErrors(k)

    -- A boss held up by a floor of the game's own (a phase that ends in a scene: 193) stays the host's game's: handed
    -- over it lost that floor, and a guest's kill was then its death outside its script on the host.
    local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
    local th, tg = t.pcs[1], t.pcs[2]
    t:run(4)
    local floorH, floorG = Session.enemyOn(th, "boss"), Session.enemyOn(tg, "boss")
    setFloor(floorH, 50)
    setFloor(floorG, 50)
    Session.moveTo(th, 0, 0)
    Session.moveTo(tg, 4000, 0)
    t:run(3)
    tg.hudLayout:RegisterBossHPBar(floorG)
    t:run(3)
    check(count(th.sent, "^E RUN sp:boss 1$") == 0 and net(th).guestRuns["sp:boss"] == nil and floorOf(floorH) == 50,
        "a boss on a floor of the game's own, the guest by it and the host 42 m back: it stays the host's game's, its floor kept")
    swing(tg, floorG, 1)                -- (onto its floor here: the guest's killing blow)
    t:run(3)
    check(field(floorH, "dead") ~= true and floorOf(floorH) == 50 and select(1, Fake.health(floorH)) >= 50
        and count(tg.sent, "^E GK sp:boss$") == 0,
        "and a guest's killing blow isn't its death there: it stands on its floor in the host's world, its fight the game's to end ("
            .. tostring(select(1, Fake.health(floorH))) .. " left)")
    allErrors(t)

    -- Another version's main.dll under these scripts: a game left open while the mod was updated keeps its old one
    -- loaded, and the new scripts linked through it with the old version's players, in its protocol. Online co-op is
    -- left off on that PC, and it says why. (The third review's G1.)
    for _, theirs in ipairs({ 4, false }) do
        local od = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, nil, nil, function(pc, i)
            if i == 2 then
                pc.dllProtocol = theirs
            end
        end)
        local oh, og = od.pcs[1], od.pcs[2]
        od:run(8)
        check(not og.env.PBZ.coop.linked() and not oh.env.PBZ.coop.linked() and #og.sent == 0
            and count(og.logs, "Status: Couldn't start the relay: dlls.main%.dll is another version's") == 1,
            "a guest's scripts over " .. (theirs and "protocol 4's" or "1.7.3's") .. " main.dll: no link, nothing sent, and told why once")
        -- (The shipped ini has Role = Off, so F5 is where most meet it: the panel's own line says why at every press. The
        -- tip alone is 4 s at the bottom of the screen, once a minute. The fifth review's V6.)
        Session.command(og, "onlinepanel join")
        od:run(1)
        check(count(og.logs, "Online panel %a+, %a+: Couldn't start the relay: dlls.main%.dll is another version's") == 1,
            "and a press in F5: the panel's own line says why")
        check(count(oh.logs, "another version's") == 0 and count(oh.logs, "script error") == 0, "the host's own install says nothing of it")
        allErrors(od)
    end
    -- The other half (the fifth review's V13): this version's main.dll starts no relay for a start file whose protocol
    -- isn't its own, compared as text (main_dll.cpp's run_from). The sim's relay reads the role alone: with that line
    -- lost or written another way, nobody's online co-op started while every other check passed. (The sixth review's V9.)
    do
        local ps = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        ps:run(2)
        check(everyone(ps, function(pc)
            return (pc.startText or ""):match("\nprotocol=([^\n]*)") == tostring(ps.relay.protocol)
        end), "each start file names these scripts' protocol as main.dll reads it (protocol=" .. tostring(ps.relay.protocol) .. ")")
        allErrors(ps)
    end

    -- A hold let go takes off the hold's own floor alone: one the game set as the hold ended (the host's own fight begun,
    -- its bar up; everything handed over going back, the guest's S) is its script's to keep, 193. (The third review's
    -- V13: nothing checked these.)
    for _, how in ipairs({ "its own fight begun", "the guest's S" }) do
        local r = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list)
        local rh, rg = r.pcs[1], r.pcs[2]
        r:run(4)
        Session.moveTo(rh, 0, 0)
        Session.moveTo(rg, 4000, 0)
        r:run(3)
        local heldH = Session.enemyOn(rh, "boss")
        rg.hudLayout:RegisterBossHPBar(Session.enemyOn(rg, "boss"))
        r:run(3)
        check(net(rh).guestRuns["sp:boss"] == true and floorOf(heldH) == 1, "(the guest's game runs it, the host's copy held)")
        setFloor(heldH, 50)
        if how == "the guest's S" then
            rh.env.PBZ.coop.handlers.S(nil, nil)
        else
            Session.moveTo(rh, 3800, 300)
            rh.hudLayout:RegisterBossHPBar(heldH)
        end
        r:run(2)
        check(net(rh).guestRuns["sp:boss"] == nil and floorOf(heldH) == 50,
            "a held copy let go, " .. how .. ", a floor of the game's own just come: kept (" .. floorOf(heldH) .. ")")
        allErrors(r)
    end

    -- A party: such a boss is never asleep on the host; and one blow that kills a copy asleep there (a sneak kill, an
    -- execution: no blow told before it) is told all the same.
    local p = party(plist)
    local ph, pa, pb = p.pcs[1], p.pcs[2], p.pcs[3]
    Session.moveTo(ph, 0, 0)
    Session.moveTo(pa, 11000, 0)
    Session.moveTo(pb, 2100, 2900)
    Session.moveTo(p.pcs[4], -500, 0)
    setFloor(Session.enemyOn(ph, "boss"), 50)
    p:run(3)
    pb.hudLayout:RegisterBossHPBar(Session.enemyOn(pb, "boss"))
    p:run(3)
    check(net(ph).partnerBosses["sp:boss"] == true and (net(pb).remoteEnemies["sp:boss"] or {}).Asleep ~= true,
        "a party: a boss on a floor of the game's own, a guest's fight with it, the host not in: never asleep there")
    local oneH, oneA = Session.enemyOn(ph, "byguest"), Session.enemyOn(pa, "byguest")
    check((net(pa).remoteEnemies["sp:byguest"] or {}).Asleep == true, "(a thug by a guest 110 m from the host: asleep there)")
    swing(pa, oneA, 0)                  -- (one blow, none told before it)
    Fake.put(oneA, "dead", true)
    p:run(3)
    check(count(pa.sent, "^E GK sp:byguest$") == 1 and field(oneH, "dead") == true and count(ph.sent, "^E K sp:byguest$") == 1,
        "a party guest's one-blow kill of one asleep on the host: told, and dead for everyone ("
            .. count(pa.sent, "^E GK sp:byguest$") .. ")")
    allErrors(p)

    -- And one asleep on the host that such a floor comes to with a guest's GK, between two of its turns there: the guard
    -- holds for it too.
    do
        local a = party(plist)
        local ah, ab = a.pcs[1], a.pcs[3]
        Session.moveTo(ah, 0, 0)
        Session.moveTo(a.pcs[2], 500, 0)
        Session.moveTo(ab, 2100, 2900)
        Session.moveTo(a.pcs[4], -500, 0)
        a:run(3)
        local asleepH = Session.enemyOn(ah, "boss")
        ab.hudLayout:RegisterBossHPBar(Session.enemyOn(ab, "boss"))
        a:run(3)
        check((net(ab).remoteEnemies["sp:boss"] or {}).Asleep == true, "(a guest's fight, the host not in: asleep there)")
        setFloor(asleepH, 50)
        Fake.setHealth(asleepH, 50)
        ah.env.PBZ.coop.handlers.GK("sp:boss")
        a:run(3)
        check(field(asleepH, "dead") ~= true and floorOf(asleepH) == 50,
            "a party: one asleep on the host comes to a floor of the game's own as a guest's GK does: it stands on it")
        allErrors(a)
    end

    -- A party guest's own copy of one asleep on the host, its tree stopped by the game in its own move: not started
    -- again while the move plays (a long attack was cut, or doubled), and started once the move is over.
    local w = party(plist)
    local wa = w.pcs[2]
    Session.moveTo(w.pcs[1], 0, 0)
    Session.moveTo(wa, 11000, 0)
    Session.moveTo(w.pcs[3], 500, 500)
    Session.moveTo(w.pcs[4], -500, 0)
    w:run(5)
    local brainA = brainOf(Session.enemyOn(wa, "byguest"))
    Session.enemyMove(wa, "byguest", "/PBZCombatAsset/ActorData/Move/E1.E1")
    brainA:StopLogic("the tree's own end, in its move")
    local early = false
    for _ = 1, 40 do
        w:run(0.1)
        early = early or field(brainA, "running") == true
    end
    check(not early, "a party guest's own copy, its tree stopped in its own move: not started again while the move plays")
    Session.enemyMove(wa, "byguest", nil)
    w:run(4)
    check(field(brainA, "running") == true, "and started again once the move is over, still in its fight")
    allErrors(w)

    -- Two fights at once: the host fights one boss, the guest another 90 m off. The guest's is the guest's game's to run:
    -- held back for "the host's fight", it stood asleep, held, till that fight was over.
    local two = {
        { "bossa", "BP_Monster_Boss_C", 300.0, 300.0, 100.0, 5000, 400, true },
        { "bossb", "BP_Monster_Boss_C", 9000.0, 0.0, 100.0, 5000, 400, true },
    }
    local f = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, two)
    local fh, fg = f.pcs[1], f.pcs[2]
    f:run(4)
    Session.moveTo(fh, 0, 0)
    Session.moveTo(fg, 500, 0)
    f:run(2)
    fh.hudLayout:RegisterBossHPBar(Session.enemyOn(fh, "bossa"))
    f:run(2)
    Session.moveTo(fg, 8800, 0)
    f:run(3)
    fg.hudLayout:RegisterBossHPBar(Session.enemyOn(fg, "bossb"))
    f:run(4)
    check(net(fh).guestRuns["sp:bossb"] == true and count(fh.sent, "^E RUN sp:bossb 1$") == 1,
        "the host fights one boss, the guest another 90 m off: the guest's is the guest's game's to run meanwhile")
    check(net(fh).guestRuns["sp:bossa"] == nil, "and the host's own stays the host's")
    allErrors(f)

    -- And in a party: the guest's boss is asleep on the host meanwhile, its copy that guest's game's to run.
    do
        local q = party(two)
        local qh, qa = q.pcs[1], q.pcs[2]
        Session.moveTo(qh, 0, 0)
        Session.moveTo(qa, 500, 0)
        Session.moveTo(q.pcs[3], 0, 500)
        Session.moveTo(q.pcs[4], -500, 0)
        q:run(2)
        qh.hudLayout:RegisterBossHPBar(Session.enemyOn(qh, "bossa"))
        q:run(2)
        Session.moveTo(qa, 8800, 0)
        q:run(3)
        local farCopy = Session.enemyOn(qa, "bossb")
        qa.hudLayout:RegisterBossHPBar(farCopy)
        q:run(4)
        check((net(qa).remoteEnemies["sp:bossb"] or {}).Asleep == true and field(brainOf(farCopy), "running") == true
            and floorOf(farCopy) == 0,
            "a party, the same: the guest's asleep on the host, its copy that guest's game's to run")
        allErrors(q)
    end

    -- The host's one swing kills two thugs: each copy's own pay is taken back on the guest, not only the last one's.
    local d, dh, dg = pair()
    for _, id in ipairs({ "thug1", "near" }) do
        Fake.put(Session.enemyOn(dh, id), "dustLoot", 300)
        Fake.put(Session.enemyOn(dg, id), "dustLoot", 300)
    end
    dg.paysAtLevelZero = true
    d:run(14)                           -- (past the quiet after a new body)
    local dh0, dg0 = Session.dust(dh), Session.dust(dg)
    for _, id in ipairs({ "thug1", "near" }) do
        local e = Session.enemyOn(dh, id)
        swing(dh, e, 0)
        Fake.put(e, "dead", true)
        dh.pawn:ChangeDustNumInternal(300)          -- (what the game pays the host for its kill)
    end
    d:run(25)
    check(Session.dust(dh) - dh0 == 600 and Session.dust(dg) - dg0 == 600,
        string.format("the host's one swing kills two thugs: their dust once each (host %d, guest %d of 600)",
            Session.dust(dh) - dh0, Session.dust(dg) - dg0))
    allErrors(d)

    -- The guest kills a thug of the host's with the host down: no share of it can come (the host's dust watch holds back
    -- what the game pays it while down), so the copy's own pay is the guest's to keep.
    local e, eh, eg = pair()
    Fake.put(Session.enemyOn(eh, "near"), "dustLoot", 300)
    Fake.put(Session.enemyOn(eg, "near"), "dustLoot", 300)
    eg.paysAtLevelZero, eh.paysAtLevelZero = true, true
    e:run(14)
    Session.die(eh)
    e:run(2)
    local eh0, eg0 = Session.dust(eh), Session.dust(eg)
    swing(eg, Session.enemyOn(eg, "near"), 1)       -- (onto its floor: the guest's killing blow)
    e:run(25)
    Session.revive(eh)
    e:run(30)
    check(Session.dust(eg) - eg0 == 300 and Session.dust(eh) - eh0 == 300,
        string.format("the guest kills a thug of the host's with the host down: its dust once each (host %d, guest %d of 300)",
            Session.dust(eh) - eh0, Session.dust(eg) - eg0))
    allErrors(e)

    -- The same with the pay coming late (320): the host's thug dies in the host's world, the host down, and its copy
    -- pays the guest 5.7 s on, the host down all along. Read once, as the kill was told, that pay was taken back.
    local lp, lph, lpg = pair()
    Fake.put(Session.enemyOn(lph, "near"), "dustLoot", 300)
    Fake.put(Session.enemyOn(lpg, "near"), "dustLoot", 300)
    lp:run(14)
    Session.die(lph)
    lp:run(2)
    local lpg0 = Session.dust(lpg)
    local fallen = Session.enemyOn(lph, "near")
    Fake.setHealth(fallen, 0)
    Fake.put(fallen, "dead", true)                  -- (it dies there, no blow of the guest's: a fall, a burn)
    lp:run(5.7)
    lpg.pawn:ChangeDustNumInternal(300)             -- (the game pays the guest its copy's own, this late)
    lp:run(6)
    check(Session.dust(lpg) - lpg0 == 300 and count(lpg.logs, "kept: 300") == 1 and count(lpg.logs, "taken back") == 0,
        string.format("a copy's pay 5.7 s after the kill, the host down all along: the guest's to keep (%d of 300)",
            Session.dust(lpg) - lpg0))
    allErrors(lp)

    -- A world loaded from the title within a boss's win's 150 s is a load, not the win.
    local l, lh, lg = pair()
    bossStart(l)
    l:run(4)
    local fell = Session.enemyOn(lh, "boss")
    swing(lh, fell, 0)
    Fake.put(fell, "dead", true)
    l:run(3)
    lh.hudLayout:UnRegisterBossHPBar(fell)
    l:run(20)
    check(net(lh).bossFellAt ~= nil, "(a boss fell on the host: its win's window is open)")
    rawset(lh.pawn, "__alive", false)               -- (no body in the world: a load from the title, not a trip)
    Session.loadMap(lh)
    for i = 1, 300 do
        local node = string.format("N_OTHER_%04d", i)
        lh.storyGuids[node] = true
        lh.storyGuids[#lh.storyGuids + 1] = node
    end
    rawset(lh.pawn, "__alive", true)
    l:run(40)
    local taken = 0
    for _, node in ipairs(lg.storyGuids) do
        if tostring(node):find("^N_OTHER_") then
            taken = taken + 1
        end
    end
    check(net(lh).bossFellAt == nil and taken == 0,
        "the host loads another save from the title 20 s after a boss fell: its 300 flow steps aren't the win's (" .. taken .. " taken)")
    allErrors(l)

    -- A boss, then 0.3 s on a death that rolls no dust (a horse), the host down, the guest's copies paying late as on the
    -- bench (a boss's 1.2 s after its K): 334's kept pay stood at the boss's roll through the horse's death, and the
    -- boss's dust was the guest's twice. Such a death keeps none. (The fourth review's V8.)
    do
        local z = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, {
            { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
            { "horse", THUG, 3150.0, 2950.0, 100.0, 600, 100 },
        })
        z:run(4)
        local zh, zg = z.pcs[1], z.pcs[2]
        zh.deathPaysDown = true
        zg.paysAtLevelZero = true
        Session.moveTo(zh, 3000, 2800)
        Session.moveTo(zg, 3000, 2700)
        z:run(3)
        for _, pc in ipairs(z.pcs) do
            Fake.put(Session.enemyOn(pc, "boss"), "dustLoot", 700)
            local horse = Session.enemyOn(pc, "horse")
            Fake.put(horse, "dustLoot", 0)
            Fake.put(horse, "GetCombatLootDataBySelf", function(_, _, data)
                data.LootDust = 0
            end)
        end
        -- (The fake pays inside killForReal; the game's pay for a copy comes later: put off here, a boss's 1.2 s, the
        -- rest 3 s.)
        local G = zg.env.PBZ.game
        local kfr, wait = G.killForReal, nil
        G.killForReal = function(actor, ...)
            wait = (G.isBoss and G.isBoss(actor)) and 1.2 or 3.0
            local res = table.pack(pcall(kfr, actor, ...))
            wait = nil
            if not res[1] then
                error(res[2])
            end
            return table.unpack(res, 2, res.n)
        end
        local change = rawget(zg.pawn, "__fields").ChangeDustNumInternal
        Fake.put(zg.pawn, "ChangeDustNumInternal", function(self, n)
            if wait and n > 0 then
                zg.loops[#zg.loops + 1] = { every = 1e9, at = zg.now + wait, fn = function() change(self, n) end }
                return
            end
            return change(self, n)
        end)
        z:run(14)
        local zboss = Session.enemyOn(zh, "boss")
        zh.hudLayout:RegisterBossHPBar(zboss)
        z:run(2)
        local zcopy = Session.enemyOn(zg, "boss")
        swing(zg, zcopy, select(1, Fake.health(zcopy)) - 10)
        z:run(5)
        Session.die(zh)
        zh.hudLayout:UnRegisterBossHPBar(zboss)
        z:run(6)
        local h0, g0 = Session.dust(zh), Session.dust(zg)
        swing(zg, zcopy, 1)                         -- (onto its floor: the guest's killing blow)
        z:run(0.3)
        swing(zg, Session.enemyOn(zg, "horse"), 1)
        z:run(20)
        Session.respawned(zh)
        Session.revive(zh)
        z:run(40)
        check(Session.dust(zh) - h0 == 700 and Session.dust(zg) - g0 == 700,
            "a boss, then a death that rolls nothing 0.3 s on, the host down: the boss's dust once each (host "
                .. Session.dust(zh) - h0 .. ", guest " .. Session.dust(zg) - g0 .. " of 700)")
        allErrors(z)
    end
end

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

    -- The guest never struck it, but it's the guest the boss is going for: in its fight all the same. (On the bench, 11-16,
    -- the host died as the boss swung at a guest who hadn't hit it yet, and was back at once, the boss at full health in
    -- both worlds.)
    local v, vh, vg = pair()
    bossStart(v)
    local vboss = Session.enemyOn(vh, "boss")
    Fake.put(field(vboss, "picker"), "SwitchTargetCooldown", 1e9)
    Fake.put(vboss, "target", net(vh).ghost)
    Session.enemyMove(vh, "boss", "/PBZCombatAsset/ActorData/Move/E1.E1")
    v:run(5)
    check(net(vg).struck["sp:boss"] == true, "a boss going for a guest who never struck it has them in its fight")
    Session.die(vh)
    vh.hudLayout:UnRegisterBossHPBar(vboss)
    v:run(6)
    check(field(vh.deathWidget, "NotTick") == true, "and the host, down first, waits for them")
    allErrors(v)
    allErrors(s)
    allErrors(t)
end
-- A report on 1.7.3 (11-18), the first map's Axe chief: "the host died and i was able to kill the boss alone but when it
-- came to combat finish i was glitched". From a fifth of his health the game holds it at 1 for its own player's
-- finishing move: a floor of the game's own. No blow of a partner's takes him past it (193), and with the host down
-- nobody could: the guest fought on with nothing to win for as long as the host's respawn was held, a quarter of an
-- hour (the bench, 11-18). The host's hold ends now once he has stood at that floor for 20 s since a partner's killing
-- blow wasn't taken there; the fight starts over as the game has it, and both are told why (383). By the floor and the
-- blow, not the game's mark for the finishing move: with the host down that mark wasn't on the host's boss (run186).
local function finisherWithTheHostDown()
    part("a boss that falls only to a finishing move, nobody's made: the host down")
    -- The host down and held, the guest in the fight, the host's boss low with a floor of the game's own under him (or
    -- none). strike: the guest's killing blow, which the floor stops 1 over it.
    -- (This part's times are 383's wait as it first was, 20 s, with no word meanwhile of what ends him. The mod's own
    -- since 395: three minutes, the word 20 s in. Its end, and guestsFinisher.)
    local function downAt(floor)
        local s, h, g = pair()
        net(h).FINISHER_WAIT_S, net(h).FINISHER_TELL_AFTER_S = 20, 1e9
        bossStart(s)
        local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        swing(g, copy, select(1, Fake.health(copy)) - 50)
        s:run(5)
        Session.die(h)
        h.hudLayout:UnRegisterBossHPBar(boss)
        s:run(6)
        local min = field(field(boss, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", floor)
        Fake.put(min, "CurrentValue", floor)
        Fake.setHealth(boss, 300)
        s:run(2)
        h.sent = {}
        return s, h, g, boss, copy
    end
    local function strike(s, g, copy)
        swing(g, copy, 1)
        s:run(1)
    end
    local function held(h)
        return field(h.deathWidget, "NotTick") == true
    end
    local function told(h)
        return count(h.sent, "^E FN sp:boss$")
    end

    local s, h, g, boss, copy = downAt(1)
    check(held(h), "the host, down with the guest still fighting, waits")
    strike(s, g, copy)
    check(select(1, Fake.health(boss)) == 2 and field(boss, "dead") ~= true and count(g.logs, "The host didn't take the killing blow") == 1,
        "the guest's killing blow at a floor of the game's own isn't taken: he stands 1 over it ("
            .. tostring((select(1, Fake.health(boss)))) .. ")")
    s:run(14)
    check(held(h) and told(h) == 0, "15 s at that floor: the host still waits")
    s:run(8)
    check(not held(h), "23 s: nobody else can finish him, and the host's respawn goes on")
    check(told(h) == 1 and count(h.logs, "nobody has made the finishing move on sp:boss") == 1, "said once, and to the guest (FN): " .. told(h))
    check(count(g.logs, "nobody made the finishing move on sp:boss") == 1, "the guest is told why the fight ends")
    local shown = (h.env.PBZ.status.lastShown.hold or {}).text
    local shownG = (g.env.PBZ.status.lastShown.hold or {}).text
    check(shown == "nobody made this boss's finishing move: the fight starts over." and shownG == shown,
        "a tip each: " .. tostring(shown) .. " / " .. tostring(shownG))
    check(net(g).hostDownAt ~= nil and g.now - net(g).hostDownAt < 10, "and the fight that ends is one the host lost, for the guest's copy")
    s:run(20)
    check(told(h) == 1, "and not again")
    check(count(h.sent, "^E FB ") == 0, "(nor the word of what ends him, put off in this part: FB, its end)")
    allErrors(s)

    -- At a floor with nobody's killing blow stopped there: nothing shows that it holds anyone up. The wait stays.
    local t, th, _, tboss = downAt(1)
    Fake.setHealth(tboss, 2)
    t:run(30)
    check(held(th) and told(th) == 0, "at a floor of the game's with no killing blow stopped there: the host waits on")
    allErrors(t)

    -- No floor of the game's: the guest's killing blow is his death, as ever.
    local u, uh, ug, uboss, ucopy = downAt(0)
    strike(u, ug, ucopy)
    u:run(3)
    check(field(uboss, "dead") == true and told(uh) == 0, "no floor under him: the guest's killing blow is his death, nothing said")
    allErrors(u)

    -- One the game won't let die just now, with no floor of its own (between phases): left at 1 for the game, and no
    -- floor says it's held up for anyone. The wait stays.
    local l, lh, lg, lboss, lcopy = downAt(0)
    Fake.put(lboss, "locked", true)
    strike(l, lg, lcopy)
    l:run(30)
    check(field(lboss, "dead") ~= true and held(lh) and told(lh) == 0,
        "one the game won't let die just now, no floor under it (between phases): the host waits on")
    -- (What "at a floor of the game's own" asks, said straight: a floor of 1 or more, and its health at it or 1 over.)
    local atFloor = lh.env.PBZ.game.atOwnFloor or function() end     -- (old scripts have none: the check fails, the run goes on)
    local lmin = field(field(lboss, "AttributeSetBase"), "Health_Min")
    Fake.setHealth(lboss, 1)
    local none = atFloor(lboss)
    Fake.put(lmin, "CurrentValue", 1)
    local at, over = atFloor(lboss), nil
    Fake.setHealth(lboss, 2)
    local one = atFloor(lboss)
    Fake.setHealth(lboss, 4)
    over = atFloor(lboss)
    check(none == false and at == true and one == true and over == false,
        "at 1 health with no floor: not at one; a floor of 1: at it at 1 and at 2, not at 4 ("
            .. tostring(none) .. ", " .. tostring(at) .. ", " .. tostring(one) .. ", " .. tostring(over) .. ")")
    allErrors(l)

    -- A sequence playing in the host's world: whatever it is, the fight is the game's to move on.
    local v, vh, vg, _, vcopy = downAt(1)
    strike(v, vg, vcopy)
    Session.scene(vh, true, "Seq023")
    v:run(30)
    check(held(vh) and told(vh) == 0, "a scene playing in the host's world: the host waits on")
    Session.scene(vh, false)
    v:run(14)
    check(held(vh) and told(vh) == 0, "the 20 s are counted from its end")
    v:run(9)
    check(not held(vh) and told(vh) == 1, "and then the respawn goes on")
    allErrors(v)

    -- Off the floor for a moment (healed): the blow stopped before is of no account, and the next one counts anew.
    local w, wh, wg, wboss, wcopy = downAt(1)
    strike(w, wg, wcopy)
    w:run(12)
    Fake.setHealth(wboss, 500)
    w:run(3)
    Fake.setHealth(wboss, 2)
    w:run(25)
    check(held(wh) and told(wh) == 0, "off his floor for a moment, back with no new blow stopped there: the host waits on")
    Fake.setHealth(wboss, 300)
    w:run(3)
    strike(w, wg, wcopy)
    w:run(14)
    check(held(wh) and told(wh) == 0, "a new killing blow stopped there: counted from it")
    w:run(9)
    check(not held(wh) and told(wh) == 1, "and the 20 s run out")
    allErrors(w)

    -- The host up: no fight starts over. (What's said then: finisherWithTheHostUp.)
    local x, xh, xg = pair()
    net(xh).FINISHER_WAIT_S = 20
    bossStart(x)
    local xboss, xcopy = Session.enemyOn(xh, "boss"), Session.enemyOn(xg, "boss")
    swing(xg, xcopy, select(1, Fake.health(xcopy)) - 50)
    x:run(5)
    local xmin = field(field(xboss, "AttributeSetBase"), "Health_Min")
    Fake.put(xmin, "BaseValue", 1)
    Fake.put(xmin, "CurrentValue", 1)
    Fake.setHealth(xboss, 300)
    x:run(2)
    xh.sent = {}
    strike(x, xg, xcopy)
    x:run(30)
    check(told(xh) == 0 and xh.env.PBZ.game.bossFightActive() and count(xg.logs, "the fight starts over") == 0,
        "the host up at such a boss, the guest's killing blow stopped at his floor: no fight starts over, it goes on (what's said there: finisherWithTheHostUp)")
    -- (And the host going down after it: counted from then, the blow stopped before still standing.)
    Session.die(xh)
    xh.hudLayout:UnRegisterBossHPBar(xboss)
    x:run(15)
    check(held(xh) and told(xh) == 0, "the host goes down then: held, 15 s")
    x:run(9)
    check(not held(xh) and told(xh) == 1, "24 s: the respawn goes on")
    allErrors(x)

    -- The mod's own wait: three minutes at that floor with nobody's finishing move, the guest told what ends him 20 s in.
    local d, dh, dg, _, dcopy = downAt(1)
    net(dh).FINISHER_WAIT_S, net(dh).FINISHER_TELL_AFTER_S = 180, 20
    strike(d, dg, dcopy)
    d:run(25)
    check(held(dh) and told(dh) == 0 and count(dh.sent, "^E FB sp:boss$") == 1
        and (dg.env.PBZ.status.lastShown.finisher or {}).text == "this boss falls only to a finishing move: a plain blow can't end it.",
        "26 s at his floor, the host down: held still, and the guest is told what ends him")
    d:run(140)
    check(held(dh) and told(dh) == 0, "166 s: held still")
    d:run(22)
    check(not held(dh) and told(dh) == 1, "three minutes and nobody's finishing move: the fight starts over")
    allErrors(d)
end

-- A report on 1.7.1, three players: "if host dies during fight, they don't get items and bell (if it spawns afterwards)
-- doesn't show up". The host down first and held, a guest's blow kills the boss: the game's death runs in the host's world
-- with its player down, none of its win's steps (the bench, 11-12). The guests' worlds ran the win: what it added there
-- reaches the host once it's up (DB), and the boss's pay the host kept goes to the guests (C), or, where the game paid
-- nothing, is given to the host.
local function hostDownAtBossDeath()
    part("the host down when the boss dies: its win, its pay, its dust for the others")
    local BELL, OLD_BELL, ITEM, WEAPON = "Bell_ARENA_001", "Bell_ARENA_002", "Weapon_Material_07", "IronBlade"
    local CRANE = "Bell_CRANE_023"
    table.insert(Fake.BELLS, { BELL, "YXZR", 3300.0, 3200.0, 100.0 })        -- (the arena's, by the boss)
    table.insert(Fake.BELLS, { OLD_BELL, "YXZR", 2500.0, 2500.0, 100.0 })    -- (one near it, woken long before)
    table.insert(Fake.BELLS, { CRANE, "YXZR", 3400.0, 3000.0, 100.0 })       -- (a crane bell 5 m off, shown once it's beaten)
    local WIN = { tags = { "boss.win" }, nodes = { "N_WIN", "N_BELL" }, bells = { BELL }, reward = WEAPON }
    -- (A guard of the fight, a boss the codex doesn't call one, as the gold-masked man of the first map, and one 65 m off.)
    local enemies = { { "guard", THUG, 3100.0, 2900.0, 100.0, 600, 100 },
        { "masked", "BP_Monster_GoldMaskMan_C", 3000.0, 3200.0, 100.0, 4000, 300 },
        { "far", THUG, 9500.0, 2800.0, 100.0, 600, 100 } }
    for _, e in ipairs(ENEMIES) do
        enemies[#enemies + 1] = e
    end
    local function has(list, x)
        for _, v in ipairs(list) do
            if v == x then
                return true
            end
        end
        return false
    end
    local function tagOff(pc, tag)
        for i = #pc.globalTags, 1, -1 do
            if pc.globalTags[i] == tag then
                table.remove(pc.globalTags, i)
            end
        end
    end
    -- Host and two guests at the fight with id, its bar up on the host, the guests in it; the boss's pay (dust, items) and
    -- its win on every world's copy of winOn (the boss, or the last of the fight to fall), 11 s after its death there (the
    -- gold-masked man's came 10 to 15 s on, the bench, 11-12). The host dies, its bar goes.
    local function downFight(id, o)
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, enemies)
        s:run(4)
        local h, g1, g2 = s.pcs[1], s.pcs[2], s.pcs[3]
        h.deathPaysDown = o.paysDown ~= false
        Session.moveTo(h, 3000, 2800)
        Session.moveTo(g1, 3000, 2700)
        Session.moveTo(g2, 2900, 2800)
        s:run(3)
        local boss = Session.enemyOn(h, id)
        Fake.put(boss, "dustLoot", 700)
        Fake.put(boss, "lootItems", o.items)
        for _, pc in ipairs(s.pcs) do
            Fake.put(Session.enemyOn(pc, o.winOn or id), "winSteps", WIN)
            Fake.put(Session.enemyOn(pc, o.winOn or id), "winDelay", 11)
        end
        for _, pc in ipairs({ g1, g2 }) do
            pc.bellIds[#pc.bellIds + 1] = OLD_BELL                          -- (the guests' saves have it, the host's not)
        end
        if o.items then
            Session.gainItem(h, ITEM, 1)                -- (one held already)
        end
        if o.wallet then
            Session.gainDust(h, o.wallet)
        end
        s:run(2)
        h.hudLayout:RegisterBossHPBar(boss)
        s:run(2)
        for _, pc in ipairs({ g1, g2 }) do
            local c = Session.enemyOn(pc, id)
            swing(pc, c, select(1, Fake.health(c)) - 10)
        end
        s:run(5)
        Session.die(h)
        h.hudLayout:UnRegisterBossHPBar(boss)           -- (the game takes the bar down as its player dies)
        s:run(6)
        return s, h, g1, g2, boss
    end
    local function upAgain(s, h, after)
        Session.respawned(h)
        Session.revive(h)
        s:run(after or 25)
    end
    local function hasWin(h)
        return has(h.storyGuids, "N_WIN") and has(h.storyGuids, "N_BELL") and has(h.globalTags, "boss.win")
    end

    -- (The bench, 11-12: the game pays a boss's dust to a player down as it dies, and keeps it; a model where it pays
    -- nothing too.)
    for _, model in ipairs({ "the game's own", "nothing paid while down" }) do
        local s, h, g1, g2, boss = downFight("boss", { items = { { ITEM, 2 } }, paysDown = model == "the game's own" })
        local gave = { Session.dust(g1), Session.dust(g2) }
        check(field(h.deathWidget, "NotTick") == true, model .. ": the host down first waits")
        swing(g2, Session.enemyOn(g2, "boss"), 1)       -- (guest 2's killing blow)
        s:run(14)
        check(field(boss, "realDeath") == true and not has(h.storyGuids, "N_WIN"), model .. ": the guest's blow is the "
            .. "boss's whole death in the host's world, its win not run there with its player down")
        check(has(g1.storyGuids, "N_WIN") and has(g2.storyGuids, "N_WIN"), model .. ": the guests' worlds ran its win")
        upAgain(s, h)
        check(hasWin(h), model .. ": the host up again has the win's flag and flow steps, the bell's among them")
        check(not has(h.bellIds, BELL) and not has(h.bellIds, OLD_BELL), model .. ": but no bell lit by word, not even the "
            .. "one the win woke in the guests' worlds: its first ring is the host's own")
        check(rawget(h.bag, "__fields").weapons[WEAPON] == true, model .. ": and its reward, the guests' find")
        check(Session.items(h, ITEM) == 3 and Session.dust(h) == 700, string.format("%s: its loot and dust, once (%d of 3, "
            .. "dust %d of 700)", model, Session.items(h, ITEM), Session.dust(h)))
        check(Session.dust(g1) - gave[1] == 700 and Session.dust(g2) - gave[2] == 700, string.format("%s: and the guests get "
            .. "its dust, as from a live host (%d, %d of 700)", model, Session.dust(g1) - gave[1], Session.dust(g2) - gave[2]))
        allErrors(s)
    end

    -- A boss the codex doesn't call one, its bar gone as the host died: still the boss of the host's fight. (The bench,
    -- 11-12: the gold-masked man was then a boss to nobody on the host, and the guest's word of his win was turned down.)
    local s, h, g1, g2 = downFight("masked", {})
    local gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "masked"), 1)
    s:run(14)
    upAgain(s, h)
    check(hasWin(h), "a boss the codex doesn't call one, its bar gone with the host: its win reaches the host all the same")
    check(Session.dust(h) == 700 and Session.dust(g1) - gave[1] == 700, string.format("and its dust, kept by the host (%d),"
        .. " goes to the guests (%d)", Session.dust(h), Session.dust(g1) - gave[1]))
    allErrors(s)

    -- The win waiting for the last of the fight, a guard falling after the boss's own look is over, the host still down.
    -- (And not one 65 m off, by a guest gone over there: no guard of that fight. The review.)
    s, h, g1, g2 = downFight("boss", { winOn = "guard" })
    for _, pc in ipairs(s.pcs) do
        Fake.put(Session.enemyOn(pc, "far"), "winSteps", { nodes = { "N_FAR" } })
    end
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(25)
    check(not hasWin(h) and not has(g2.storyGuids, "N_WIN"), "a guard of the fight still up: no win anywhere yet")
    swing(g2, Session.enemyOn(g2, "guard"), 1)
    s:run(14)
    check(has(g2.storyGuids, "N_WIN") and not hasWin(h), "the guard falls 25 s after the boss: the guests' worlds win, "
        .. "the host's, still down, not")
    Session.moveTo(g2, 9300, 2800)
    s:run(9)                                        -- (the guard's own look over: 20 s)
    -- (65 m from a host who's down: asleep in the host's world, so guest 2's game runs its own copy of it, not held, and
    -- its death there, the game's own, is told: asleepOnTheHost.)
    local far = Session.enemyOn(g2, "far")
    swing(g2, far, select(1, Fake.health(far)) - 50)
    s:run(1)
    g2.env.PBZ.game.noteLocalMove()
    g2.env.StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(far)
        :BP_ApplyGameplayEffectToSelf()
    s:run(14)
    check(has(g2.storyGuids, "N_FAR"), "an enemy 65 m off falls too, within the minute, its own step in the guests' worlds")
    upAgain(s, h)
    check(hasWin(h), "and the host up again has the guard's win too")
    check(not has(h.storyGuids, "N_FAR"), "but not the far enemy's step")
    allErrors(s)

    -- What else a guest's world adds about then isn't the win's (the review of the draft): guest 1's death of the boss
    -- refused (a phase of its world's own: the quiet kill, no win), and its own flag 2 s on; a scene's tag in guest 2's
    -- world for 4 s; its own ring of the arena's crane bell 5 s on (shown once the boss is beaten, rung right after);
    -- guest 2's own flag 25 s after the boss's death there, its look over.
    s, h, g1, g2 = downFight("boss", {})
    Fake.put(Session.enemyOn(g1, "boss"), "locked", true)
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(2)
    g1.globalTags[#g1.globalTags + 1] = "Quest.G1Only.Step2"
    g2.globalTags[#g2.globalTags + 1] = "Level.Arena.SceneBusy"
    g2.globalTags[#g2.globalTags + 1] = "relic.one"         -- (a relic of guest 2's own find: the flag it has while held)
    s:run(3)
    g2.bellIds[#g2.bellIds + 1] = CRANE
    s:run(1)
    tagOff(g2, "Level.Arena.SceneBusy")
    s:run(19)
    g2.globalTags[#g2.globalTags + 1] = "Quest.G2Only.Later"
    s:run(10)
    upAgain(s, h)
    check(hasWin(h), "the win's steps reach the host from guest 2's world")
    check(not has(h.globalTags, "Quest.G1Only.Step2"), "not guest 1's own flag: its death of the boss never ran there")
    check(not has(h.globalTags, "Level.Arena.SceneBusy"), "nor a scene's tag on for a moment in guest 2's world")
    check(not has(h.globalTags, "relic.one"), "nor the flag of a thing guest 2 found and holds")
    check(not has(h.bellIds, CRANE), "nor the crane bell guest 2 rang itself: the host's first ring, and its scene, its own "
        .. "(the merge review of the bells work)")
    check(not has(h.globalTags, "Quest.G2Only.Later"), "nor guest 2's own flag, raised after the win's look was over")
    s:run(15)
    check(not has(g2.globalTags, "Quest.G1Only.Step2"), "nor guest 2 guest 1's flag, by the host's flow")
    allErrors(s)

    -- The host spends at a bell after its respawn, before the pay owed is looked at: the boss's dust kept, nothing given back.
    s, h, g1, g2 = downFight("boss", {})
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    local paidDown = Session.dust(h)
    upAgain(s, h, 6)
    Fake.put(h.pawn, "ConsciousnessDust", Session.dust(h) - 500)        -- (500 spent at the bell)
    s:run(25)
    check(paidDown == 700 and Session.dust(h) == paidDown - 500, string.format("spent after the respawn: not given back "
        .. "(%d, %d expected)", Session.dust(h), paidDown - 500))
    check(Session.dust(g1) - gave[1] == 700, string.format("and the guests still get the boss's dust (%d of 700)",
        Session.dust(g1) - gave[1]))
    allErrors(s)

    -- A partner's share comes as the host gets up, no look of its own between (the bench, 11-12): not taken for the boss's
    -- pay, nor the boss's kept dust for none paid.
    s, h, g1, g2 = downFight("boss", {})
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    paidDown = Session.dust(h)
    h.env.PBZ.game.addCurrency(h.pawn, 600)
    upAgain(s, h)
    check(paidDown == 700 and Session.dust(h) == paidDown + 600, string.format("a share as it got up: the boss's dust "
        .. "not given again (%d, %d expected)", Session.dust(h), paidDown + 600))
    check(Session.dust(g1) - gave[1] == 700, string.format("and the guests get the boss's dust (%d of 700)",
        Session.dust(g1) - gave[1]))
    allErrors(s)

    -- Where the game paid nothing while down, its pay coming after all once the host is up (3 s on, in the dust watch's
    -- quiet; 7 s on, after it): not given again, and the guests' share once. (The review: both were paid twice.)
    for _, late in ipairs({ 3, 7 }) do
        s, h, g1, g2 = downFight("boss", { paysDown = false })
        gave = { Session.dust(g1), Session.dust(g2) }
        swing(g2, Session.enemyOn(g2, "boss"), 1)
        s:run(14)
        upAgain(s, h, late)
        Session.gainDust(h, 700)                    -- (the game's own pay, late)
        s:run(25)
        check(Session.dust(h) == 700 and Session.dust(g1) - gave[1] == 700, string.format("the game's pay %d s after the "
            .. "respawn: the host has it once (%d of 700), the guests their share once (%d)", late, Session.dust(h),
            Session.dust(g1) - gave[1]))
        allErrors(s)
    end

    -- (The second review.) Nothing paid while down, the wallet read low a moment and back as the host gets up, then the
    -- game's pay 7 s on: the guests get it once. And a pay 3 s on, 500 of it spent at the bell 6 s on: nothing given again.
    s, h, g1, g2 = downFight("boss", { paysDown = false, wallet = 5000 })
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    Fake.put(h.pawn, "ConsciousnessDust", 0)
    s:run(0.6)
    Fake.put(h.pawn, "ConsciousnessDust", 5000)
    upAgain(s, h, 7)
    Session.gainDust(h, 700)
    s:run(30)
    check(Session.dust(h) == 5700 and Session.dust(g1) - gave[1] == 700, string.format("a low read and back, the pay 7 s "
        .. "after: the host has it once (%d of 5700), the guests their share once (%d)", Session.dust(h),
        Session.dust(g1) - gave[1]))
    allErrors(s)
    s, h, g1, g2 = downFight("boss", { paysDown = false })
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    upAgain(s, h, 3)
    Session.gainDust(h, 700)
    s:run(3)
    Fake.put(h.pawn, "ConsciousnessDust", Session.dust(h) - 500)
    s:run(30)
    check(Session.dust(h) == 200 and Session.dust(g1) - gave[1] == 700, string.format("the pay 3 s after, 500 spent: "
        .. "nothing given again (%d of 200), the guests' share once (%d)", Session.dust(h), Session.dust(g1) - gave[1]))
    allErrors(s)

    -- Nothing paid while down, and down again 3 s after getting up, no boss this time: what's owed waits for the next time
    -- up, given then and shared as earned. (The second review: given to a player down, the dust watch kept it back.)
    s, h, g1, g2 = downFight("boss", { paysDown = false })
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    upAgain(s, h, 3)
    Session.die(h)
    s:run(8)
    upAgain(s, h, 40)
    check(Session.dust(h) == 700 and Session.dust(g1) - gave[1] == 700, string.format("nothing paid, down again before it "
        .. "was settled: given once up (%d of 700), the guests' share once (%d)", Session.dust(h), Session.dust(g1) - gave[1]))
    allErrors(s)

    -- The wallet reads low a moment just before the respawn (as the dust watch knows it can): the pay read before it counts.
    s, h, g1, g2 = downFight("boss", {})
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    Fake.put(h.pawn, "ConsciousnessDust", 0)
    s:run(0.3)
    Fake.put(h.pawn, "ConsciousnessDust", 700)
    upAgain(s, h)
    check(Session.dust(h) == 700 and Session.dust(g1) - gave[1] == 700, string.format("a low read just before the respawn: "
        .. "the boss's dust not given again (%d of 700), the guests' share once (%d)", Session.dust(h),
        Session.dust(g1) - gave[1]))
    allErrors(s)

    -- Down again in another fight before the first boss's pay is settled: that one settled at the second death, and the
    -- second boss owed as the first was. (The review: it was owed nothing, the guests short of its share.)
    s, h, g1, g2 = downFight("boss", {})
    gave = { Session.dust(g1), Session.dust(g2) }
    swing(g2, Session.enemyOn(g2, "boss"), 1)
    s:run(14)
    upAgain(s, h, 3)
    local masked = Session.enemyOn(h, "masked")
    Fake.put(masked, "dustLoot", 300)
    h.hudLayout:RegisterBossHPBar(masked)
    s:run(2)
    for _, pc in ipairs({ g1, g2 }) do
        local c = Session.enemyOn(pc, "masked")
        swing(pc, c, select(1, Fake.health(c)) - 10)
    end
    s:run(3)
    Session.die(h)
    h.hudLayout:UnRegisterBossHPBar(masked)
    s:run(6)
    swing(g2, Session.enemyOn(g2, "masked"), 1)
    s:run(14)
    upAgain(s, h)
    check(Session.dust(h) == 1000 and Session.dust(g1) - gave[1] == 1000, string.format("down twice, a boss each time: the "
        .. "host keeps both (%d of 1000), the guests get both shares (%d of 1000)", Session.dust(h), Session.dust(g1) - gave[1]))
    allErrors(s)

    -- A fall the boss gets up from (Xiaoxue's), the host down: no win, nothing owed for it.
    local boss
    s, h, g1, g2, boss = downFight("boss", {})
    gave = { Session.dust(g1), Session.dust(g2), Session.dust(h) }
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(3)
    Fake.setHealth(boss, 5000)
    Fake.put(boss, "dead", false)
    s:run(8)
    upAgain(s, h)
    check(Session.dust(h) == gave[3] and Session.dust(g1) == gave[1] and Session.dust(g2) == gave[2], string.format("a fall "
        .. "the boss gets up from: nobody paid for it (host +%d, guests +%d, +%d)", Session.dust(h) - gave[3],
        Session.dust(g1) - gave[1], Session.dust(g2) - gave[2]))
    check(not has(h.storyGuids, "N_WIN"), "and no win's step taken by the host from the guests' worlds")
    allErrors(s)

    -- Not a guest's word for a boss the host doesn't owe: nothing of a guest's world goes the host's way.
    s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    s:run(4)
    h = s.pcs[1]
    local db = h.env.PBZ.coop.handlers.DB
    if db then
        db("sp:boss n N_STRAY", 2)
        db("sp:boss b Bell_YXZR_005", 2)
    end
    s:run(25)
    check(not has(h.storyGuids, "N_STRAY") and not has(h.bellIds, "Bell_YXZR_005"),
        "a guest's word of a boss that didn't fall with the host down: nothing taken")
    allErrors(s)
    table.remove(Fake.BELLS)
    table.remove(Fake.BELLS)
    table.remove(Fake.BELLS)
end
-- A player report (11-09): a door the host opened before the guest got there, or before it had loaded in the guest's world,
-- stayed shut for the guest (a hand-in door, the Phantom Tavern's): only F3 got them past.
-- The other way round: a guest down as the boss falls. Its copy's death runs in its world with its player down, none of
-- the win's steps (as on the host: hostDownAtBossDeath), and the host's own win, hundreds of flow steps at once, was taken
-- for a load and told to nobody: the guest's story stopped at that boss. And a level's own flow steps, which a guest
-- takes only on the level it stands on.
local function guestDownAtBossDeath()
    part("a guest down when the boss dies; flow steps of another level")
    local LIB = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
    local function has(list, x)
        for _, v in ipairs(list) do
            if v == x then
                return true
            end
        end
        return false
    end
    local function step(pc, node)       -- (a flow step run in this PC's world)
        pc.storyGuids[node] = true
        pc.storyGuids[#pc.storyGuids + 1] = node
    end
    local nodes = {}
    for i = 1, 300 do
        nodes[i] = string.format("N_WIN_%03d", i)
    end
    local s, h, g = pair()
    bossStart(s)
    guestsHit(s)
    s:run(2)
    local bossH = Session.enemyOn(h, "boss")
    for _, pc in ipairs(s.pcs) do
        Fake.put(Session.enemyOn(pc, "boss"), "winSteps", { tags = { "boss.win" }, nodes = nodes })
    end
    s:run(8)                    -- (the host's flow as it stands is what the guest was told)
    Session.die(g)
    s:run(3)
    h.env.PBZ.game.noteLocalMove()
    h.env.StaticFindObject(LIB):GetAbilitySystemComponent(bossH):BP_ApplyGameplayEffectToSelf()     -- (the host's own kill)
    s:run(3)
    h.hudLayout:UnRegisterBossHPBar(bossH)
    s:run(20)
    check(has(h.storyGuids, "N_WIN_300") and has(h.globalTags, "boss.win") and not has(g.storyGuids, "N_WIN_300"),
        "the host's world ran the win, 300 flow steps at once; the guest's, its player down, none of it")
    Session.revive(g)
    s:run(30)
    check(has(g.storyGuids, "N_WIN_001") and has(g.storyGuids, "N_WIN_300") and has(g.globalTags, "boss.win"),
        "the guest up again has the win's flag and every one of its flow steps")
    allErrors(s)

    -- Not a load's: hundreds at once with no boss fallen are a world loaded, as before.
    local u, uh, ug = pair()
    u:run(8)
    for i = 1, 300 do
        step(uh, string.format("N_LOAD_%03d", i))
    end
    u:run(20)
    check(not has(ug.storyGuids, "N_LOAD_001") and count(uh.logs, "new flow steps at once %(a load%?%)") == 1,
        "300 at once with no boss fallen: a load, told to nobody")
    allErrors(u)

    -- A level's own flow steps wait for the guest to stand on that level.
    local t, th, tg = pair()
    for _, pc in ipairs(t.pcs) do
        pc.env.PBZ.game.isStoryLevel = function(level)
            return level == "Map_Xigu" or level == "Map_Other"
        end
    end
    t:run(8)
    step(th, "Map_Xigu-BP_FlowActor_C_1")
    step(th, "Map_Other-BP_FlowActor_C_2")
    step(th, "0F9F320E463C16637297009D16FBD4D1")
    t:run(12)
    check(has(tg.storyGuids, "Map_Xigu-BP_FlowActor_C_1") and has(tg.storyGuids, "0F9F320E463C16637297009D16FBD4D1"),
        "the host's flow steps of the level the guest stands on, and a quest's own, are taken")
    check(not has(tg.storyGuids, "Map_Other-BP_FlowActor_C_2"), "one of another level's waits")
    tg.map = "Map_Other"
    t:run(5)
    check(has(tg.storyGuids, "Map_Other-BP_FlowActor_C_2"), "and is taken once the guest stands on that level")
    allErrors(t)
end

-- The reports of 11-06 and 11-09: "for some bosses, after the host enters, the guest can't deal damage; when the guest
-- becomes the host, still can't". The bench, 11-17 (Peng Meng): a story boss stands unstarted (its AI's state None) till
-- its player walks into the story's trigger and its scene has run. A guest outside it as the host walked in took the
-- host's flow steps of that start as done, lost its own trigger with them, and had a boss never started in its world.
local function bossStartsHere()
    part("a boss's start is each world's own")
    local GUID, STEP, FLAG = "1FC1300A41E19051E5E3EDA7CE2829B4", "Map_Xigu-SkeletalMeshActor_UAID_9", "xg.boss.appears"
    local function has(list, x)
        for _, v in ipairs(list) do
            if v == x then
                return true
            end
        end
        return false
    end
    local function step(pc, node)       -- (a flow step run in this PC's world)
        pc.storyGuids[node] = true
        pc.storyGuids[#pc.storyGuids + 1] = node
    end
    local function ai(pc, state)        -- (its boss's AI state, as the game names it)
        local c = rawget(field(Session.enemyOn(pc, "boss"), "Controller"), "__fields").SGameAIComponent
        c.CurrentStateTag = { TagName = { ToString = function() return state end } }
    end
    local function side(pc)             -- (its boss's side there: its faction, its controller's team)
        local e = Session.enemyOn(pc, "boss")
        return tostring(field(field(e, "faction"), "faction")) .. " " .. tostring(rawget(field(e, "Controller"), "__fields").Team.TeamID)
    end
    local function onSide(pc, faction, team)
        local e = Session.enemyOn(pc, "boss")
        Fake.put(field(e, "faction"), "faction", faction)
        rawget(field(e, "Controller"), "__fields").Team.TeamID = team
    end
    local function scene(s, pc)         -- (the story's scene in this PC's world: its steps, its flag, the boss an enemy)
        Session.scene(pc, true)
        step(pc, GUID)
        step(pc, STEP)
        pc.globalTags[#pc.globalTags + 1] = FLAG
        s:run(14)
        Session.scene(pc, false)
        ai(pc, "AI.State.Combat")
        onSide(pc, "Faction.Enemy", 0)
    end
    local function world()
        local s, h, g = pair()
        for _, pc in ipairs(s.pcs) do
            pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
            ai(pc, "None")
            onSide(pc, "Faction.Player", 1)     -- (a figure till its scene: on the player's own side)
        end
        s:run(8)
        return s, h, g
    end

    -- The guest outside as the host walks in: its world keeps its own trigger.
    local s, h, g = world()
    scene(s, h)
    bossStart(s)
    s:run(20)
    check(has(h.storyGuids, GUID) and not has(g.storyGuids, GUID) and not has(g.storyGuids, STEP) and not has(g.globalTags, FLAG),
        "the host walks in alone: none of its start's flow steps and flags is taken in the guest's world")
    check(count(g.logs, "left for this world's own start of it") == 1, "said once in the guest's log")
    -- (And the guest's copy, a figure on the player's own side, is an enemy for as long as the host's fight lasts: no
    -- blow landed on it, and none of its own on the guest. The bench, 11-17, A-Hua.)
    check(side(g) == "Faction.Enemy 0" and count(g.logs, "isn't started in this world: on the enemy's side") == 1,
        "the guest's copy of it, not started there: on the enemy's side while the host's fight lasts (" .. side(g) .. ")")
    check(side(h) == "Faction.Enemy 0", "(the host's own is as its scene left it)")
    step(h, "Map_Xigu-BP_FlowActor_C_7")                    -- (something else the host's flow does, the fight on)
    s:run(14)
    check(has(g.storyGuids, "Map_Xigu-BP_FlowActor_C_7"), "what the host's flow does after that is taken as ever")
    scene(s, g)                                             -- (the guest walks into its own trigger: its scene, its start)
    s:run(3)
    check(count(g.logs, "is taken now: started in this world") == 1 and has(g.storyGuids, GUID) and has(g.globalTags, FLAG),
        "the guest walks into its own trigger: its world runs the start itself, and the wait is over")
    allErrors(s)

    -- The trigger's own step runs a second or two before its scene (the bench at A-Hua, 11-17: told 0.2 s after the host
    -- stepped in, taken in the guest's world 0.6 s on, the scene's flag there 1.2 s after that: the guest's own start
    -- never came). Told in that gap it waits a few seconds on the guest, and the scene's window has it. (The fourth
    -- review's G1.)
    local function tellNow(w, pc, node)     -- (a step of this PC's flow, and on till its look has told it)
        local told = count(pc.logs, "here, told the others")
        step(pc, node)
        for _ = 1, 24 do
            if count(pc.logs, "here, told the others") > told then
                return true
            end
            w:run(0.5)
        end
        return false
    end
    local e, eh, eg = world()
    local toldE = tellNow(e, eh, GUID)
    e:run(1.5)
    check(toldE and not has(eg.storyGuids, GUID),
        "the trigger's own step, told before its scene: not taken in the guest's world the second it comes")
    Session.scene(eh, true)
    step(eh, STEP)
    eh.globalTags[#eh.globalTags + 1] = FLAG
    e:run(14)
    Session.scene(eh, false)
    ai(eh, "AI.State.Combat")
    onSide(eh, "Faction.Enemy", 0)
    bossStart(e)
    e:run(20)
    check(not has(eg.storyGuids, GUID) and not has(eg.storyGuids, STEP) and not has(eg.globalTags, FLAG),
        "its scene 1.5 s on: that step is held with the rest of the start, the guest's own trigger kept")
    scene(e, eg)
    e:run(3)
    check(has(eg.storyGuids, GUID) and count(eg.logs, "is taken now: started in this world") == 1,
        "and the guest's own scene runs it")
    allErrors(e)
    -- (What that costs: whatever the host tells is in a guest's world 6 s later than it was.)
    local y, yh, yg = world()
    local toldY = tellNow(y, yh, "Map_Xigu-BP_FlowActor_C_8")
    y:run(4)
    local early = has(yg.storyGuids, "Map_Xigu-BP_FlowActor_C_8")
    y:run(4)
    check(toldY and not early and has(yg.storyGuids, "Map_Xigu-BP_FlowActor_C_8"),
        "with no scene after it, a step the host tells is taken in the guest's world 6 to 8 s on, not at once")
    allErrors(y)
    -- A slower trigger: on the bench the hook man's ran its step 5 s before its scene (11-17), and a slower PC or a
    -- hitch takes longer. Told 5.5 s before it, the guest's tick just after the host's look (the worst), it's held all
    -- the same. (The sixth review's V4: with 4 s it was taken, the guest's own start gone.)
    local function flowLoop(pc)             -- (flowsync's once-a-second loop)
        for _, loop in ipairs(pc.loops) do
            for i = 1, 20 do
                local n, v = debug.getupvalue(loop.fn, i)
                if not n then
                    break
                end
                if n == "where" and type(v) == "string" and v:find("flowsync.lua", 1, true) then
                    return loop
                end
            end
        end
    end
    local m, mh, mg = world()
    for _, pc in ipairs(m.pcs) do
        Session.scene(pc, false)            -- (the game's scene manager there all along: the host sees its scene at once)
    end
    flowLoop(mg).at = flowLoop(mh).at + 0.05
    m:run(4)
    local toldM = count(mh.logs, "here, told the others")
    step(mh, GUID)
    for _ = 1, 8 * 60 do
        if count(mh.logs, "here, told the others") > toldM then
            break
        end
        m:run(1 / 60)
    end
    m:run(5.5)
    Session.scene(mh, true)
    step(mh, STEP)
    mh.globalTags[#mh.globalTags + 1] = FLAG
    m:run(14)
    Session.scene(mh, false)
    ai(mh, "AI.State.Combat")
    onSide(mh, "Faction.Enemy", 0)
    bossStart(m)
    m:run(20)
    check(not has(mg.storyGuids, GUID) and count(mg.logs, "left for this world's own start of it") == 1,
        "the trigger's step told 5.5 s before its scene: held with the start, the guest's own trigger kept")
    allErrors(m)
    -- The guest on another map as that step is told: a step of the host's level was put by for their arrival at once,
    -- where the scene's window never saw it, and taken the moment they came over, by F3 or a bell: their own trigger
    -- spent before they reached it. Put by only once it's old. (The fifth review's V4.)
    local z, zh, zg = world()
    for _, pc in ipairs(z.pcs) do
        pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" or level == "Map_Other" end
    end
    zg.map = "Map_Other"
    Session.moveTo(zg, 90000, -70000)
    z:run(8)
    local toldZ = tellNow(z, zh, STEP)
    z:run(1.5)
    Session.scene(zh, true)
    step(zh, GUID)
    zh.globalTags[#zh.globalTags + 1] = FLAG
    z:run(14)
    Session.scene(zh, false)
    ai(zh, "AI.State.Combat")
    onSide(zh, "Faction.Enemy", 0)
    bossStart(z)
    z:run(20)
    zg.map = "Map_Xigu"                             -- (the guest comes over)
    Session.moveTo(zg, 2500, 2500)
    z:run(20)
    check(toldZ and not has(zg.storyGuids, STEP) and not has(zg.storyGuids, GUID) and not has(zg.globalTags, FLAG)
        and count(zg.logs, "left for this world's own start of it") == 1,
        "the guest on another map as the trigger's step is told, then over to the host's: nothing of the start is taken on arrival")
    allErrors(z)

    -- The guest never goes in, and the host wins: taken then, as before.
    local w, wh, wg = world()
    scene(w, wh)
    bossStart(w)
    w:run(20)
    check(not has(wg.storyGuids, GUID), "(held again)")
    bossEnd(w)
    w:run(8)
    check(has(wg.storyGuids, GUID) and has(wg.storyGuids, STEP) and has(wg.globalTags, FLAG)
        and count(wg.logs, "is taken now: beaten in the host's world") == 1,
        "the host beats the boss, the guest never in: the start's steps are taken then, as before")
    allErrors(w)

    -- The host's fight over with the boss alive (the host left, or lost), the guest's copy never started: back on the
    -- player's own side, as the game had it, its own start still to come.
    local f, fh, fg = world()
    scene(f, fh)
    bossStart(f)
    f:run(6)
    check(side(fg) == "Faction.Enemy 0", "(on the enemy's side through the host's fight)")
    fh.hudLayout:UnRegisterBossHPBar(Session.enemyOn(fh, "boss"))
    f:run(6)
    check(side(fg) == "Faction.Player 1" and count(fg.logs, "is as the game had it again") == 1,
        "the host's fight over, the boss alive: the guest's figure is back on the player's own side (" .. side(fg) .. ")")
    allErrors(f)
    -- A guest whose own scene comes during the host's fight: the game's own start makes it an enemy, and it's left so.
    local o, oh, og = world()
    scene(o, oh)
    bossStart(o)
    o:run(6)
    scene(o, og)
    oh.hudLayout:UnRegisterBossHPBar(Session.enemyOn(oh, "boss"))
    o:run(6)
    check(side(og) == "Faction.Enemy 0" and count(og.logs, "is as the game had it again") == 0,
        "started in the guest's world meanwhile: left as the game has it when the host's fight ends")
    allErrors(o)
    -- The other way round, the guest's scene first: the host's own figure is the host's game's to start, never touched.
    local r, rh, rg = world()
    scene(r, rg)
    rg.hudLayout:RegisterBossHPBar(Session.enemyOn(rg, "boss"))
    r:run(8)
    check(side(rh) == "Faction.Player 1", "the guest's fight, the host's copy not started: left on its own side (" .. side(rh) .. ")")
    allErrors(r)
    -- A party: a guest's own fight with a boss asleep on the host (the host not in it), a third player by it whose world
    -- hasn't started it. That player's own game runs their copy, which follows no moves: on the enemy's side it was a
    -- figure that never fought back, and its death was the boss's everywhere. Left on its own side; the host's own
    -- fight puts a late guest's copy over as with two. (The fifth review's V1.)
    for _, whose in ipairs({ "a guest's", "the host's" }) do
        local t3 = party(nil, nil, { "Host", "Guest", "Guest" })
        local th, tb, tc = t3.pcs[1], t3.pcs[2], t3.pcs[3]
        for _, pc in ipairs(t3.pcs) do
            ai(pc, "None")
            onSide(pc, "Faction.Player", 1)
        end
        local fighter, away = tb, th
        if whose == "the host's" then
            fighter, away = th, tb
        end
        Session.moveTo(away, -6000, 0)              -- (95 m from it)
        Session.moveTo(fighter, 3100, 2900)
        Session.moveTo(tc, 4200, 3600)              -- (the third 13 m from it, outside its trigger)
        t3:run(3)
        ai(fighter, "AI.State.Combat")              -- (the fighter's own start, in their world)
        onSide(fighter, "Faction.Enemy", 0)
        fighter.hudLayout:RegisterBossHPBar(Session.enemyOn(fighter, "boss"))
        t3:run(6)
        local put = count(tc.logs, "isn't started in this world: on the enemy's side")
        if whose == "a guest's" then
            check(net(tc).partnerBosses["sp:boss"] == true and side(tc) == "Faction.Player 1" and put == 0,
                "a party, a guest's own fight asleep on the host: a third player's unstarted copy, their own game's, stays on its own side ("
                    .. side(tc) .. ")")
        else
            check(side(tc) == "Faction.Enemy 0" and put == 1,
                "a party, the host's own fight: a late guest's unstarted copy follows it, on the enemy's side (" .. side(tc) .. ")")
        end
        allErrors(t3)
    end

    -- What the side is for: the late guest's blows land on their copy and come off the boss in the host's world, and
    -- the copy's land on them. On a figure none does, either way, and nothing is told of one: the fake goes by the
    -- side as the game does (the fifth review's G4; 326 and 343 couldn't be seen in the sim till then).
    do
        local v, vh, vg = world()
        local function blow(pc, e, damage)      -- (an enemy's blow at this PC's own player: off their health, if it lands)
            if not Fake.lands(e) then
                return false
            end
            Fake.setHealth(pc.pawn, select(1, Fake.health(pc.pawn)) - damage)
            return true
        end
        local copy, hosts = Session.enemyOn(vg, "boss"), Session.enemyOn(vh, "boss")
        local had, sent = select(1, Fake.health(copy)), count(vg.sent, "^E D ")
        local figure = swing(vg, copy, had - 200)
        v:run(2)
        check(not figure and not blow(vg, copy, 30) and select(1, Fake.health(copy)) == had and count(vg.sent, "^E D ") == sent,
            "a figure nobody has started: no blow of the guest's lands on it and none of its on the guest, nothing told")
        scene(v, vh)
        bossStart(v)
        v:run(6)
        local hadH, hadG = select(1, Fake.health(hosts)), select(1, Fake.health(vg.pawn))
        local landed = swing(vg, copy, select(1, Fake.health(copy)) - 200)
        v:run(2)
        check(landed and select(1, Fake.health(hosts)) == hadH - 200 and count(vg.sent, "^E D ") == sent + 1,
            "the host's fight on, the guest come late: their blow lands on their copy, and is off the boss in the host's world ("
                .. tostring(landed) .. ", " .. hadH - select(1, Fake.health(hosts)) .. ")")
        check(blow(vg, copy, 30) and select(1, Fake.health(vg.pawn)) == hadG - 30, "and the copy's blow lands on the late guest")
        allErrors(v)
    end

    -- Both walk in together: each world runs its own, nothing is kept back.
    local b, bh, bg = world()
    Session.scene(bg, true)
    step(bg, GUID)
    step(bg, STEP)
    bg.globalTags[#bg.globalTags + 1] = FLAG
    scene(b, bh)
    Session.scene(bg, false)
    ai(bg, "AI.State.Combat")
    bossStart(b)
    b:run(24)
    check(count(bg.logs, "left for this world's own start of it") == 0 and has(bg.storyGuids, GUID),
        "both inside as it fires: nothing kept back")
    allErrors(b)

    -- A scene of the host's with no fight after it: what it told is taken as the wait ends.
    local n, nh, ng = world()
    Session.scene(nh, true)
    step(nh, "Map_Xigu-BP_FlowActor_C_8")
    n:run(14)
    Session.scene(nh, false)
    n:run(6)
    check(not has(ng.storyGuids, "Map_Xigu-BP_FlowActor_C_8"), "a scene of the host's, no fight after: its steps wait a little")
    n:run(16)
    check(has(ng.storyGuids, "Map_Xigu-BP_FlowActor_C_8") and count(ng.logs, "left for this world's own start") == 0,
        "and are taken")
    allErrors(n)

    -- A figure's bar that only blinks in the host's world, up and down between two looks (as its player arrives by
    -- it: the bench, 11-17, Wan Jun's and Peng Meng's): its B went out, nothing ended the mirror, and the guest stood
    -- with a bar up and the walls shut for a fight that never was.
    local k, kh, kg = world()
    local blink = Session.enemyOn(kh, "boss")
    kh.hudLayout:RegisterBossHPBar(blink)
    kh.hudLayout:UnRegisterBossHPBar(blink)
    k:run(2)
    check(net(kg).partnerBosses["sp:boss"] == true, "(a bar that blinks on the host: its fight is shown on the guest)")
    k:run(8)
    check(net(kg).partnerBosses["sp:boss"] == nil and count(kg.logs, "is over there: over here too") == 1
        and side(kg) == "Faction.Player 1",
        "and ended there a few seconds on, the host in no fight: no bar, no walls, the figure as it was (" .. side(kg) .. ")")
    -- (And never on the enemy's side meanwhile: a blink tells no fight, and the guest's blows in those 4 s came off the
    -- host's figure, not started and in no fight. Only while that fight is told as on. The fifth review's V7.)
    check(count(kg.logs, "isn't started in this world: on the enemy's side") == 0,
        "through the blink the guest's figure was never put on the enemy's side")
    allErrors(k)
    -- (The host down in its fight, its respawn held for the guest: still told as on, F 1, as tellFight has it. A guest
    -- whose figure is first looked at then, in the second they came in, or after a scene of their own as here, has it
    -- on the enemy's side all the same: left, they stood by a figure no blow reached, the host waiting for them.)
    local j, jh, jg = world()
    Session.scene(jg, true)                         -- (the guest's own scene: the bars' look waits through it)
    ai(jh, "AI.State.Combat")
    onSide(jh, "Faction.Enemy", 0)
    bossStart(j)
    j:run(3)
    net(jg).joinedBoss = "sp:boss"                  -- (in it: walked in at its wall; no blow lands on a figure)
    j:run(3)
    local before = side(jg)
    Session.die(jh)
    jh.hudLayout:UnRegisterBossHPBar(Session.enemyOn(jh, "boss"))   -- (the game takes its bar down as its player dies)
    j:run(4)
    Session.scene(jg, false)
    j:run(3)
    check(before == "Faction.Player 1" and field(jh.deathWidget, "NotTick") == true and side(jg) == "Faction.Enemy 0",
        "the host down in its fight and waiting as the guest's figure is first looked at: on the enemy's side all the same ("
            .. before .. " -> " .. side(jg) .. ")")
    allErrors(j)

    -- The host tells all it has sent again to a player who links again: this one back from a load, a trip or a drop,
    -- or in a party any other. A start held here came with it, and taken so, its trigger went after all. (The fourth
    -- review's V1.)
    local q, qh, qg = world()
    scene(q, qh)
    bossStart(q)
    q:run(20)
    check(not has(qg.storyGuids, GUID) and count(qg.logs, "left for this world's own start of it") == 1, "(a start held)")
    for _ = 1, 8 * 60 do                            -- (the guest's game stands still 8 s: a load)
        Fake.frame(qh, 1 / 60)
        qg.now = qg.now + 1 / 60
        q.relay:step(qh.now)
    end
    q:run(12)
    check(count(qh.logs, "told again") >= 1 and not has(qg.storyGuids, GUID) and not has(qg.storyGuids, STEP)
        and not has(qg.globalTags, FLAG),
        "the guest back from a load of 8 s, the host telling all again: the held start stays held ("
            .. count(qh.logs, "told again") .. " retelling)")
    bossEnd(q)
    q:run(8)
    check(has(qg.storyGuids, GUID) and has(qg.globalTags, FLAG), "and is taken when the host beats the boss, as before")
    allErrors(q)

    -- One start that brings two bosses: kept under one name, the start went as that one fell, the other alive there
    -- and not started here. (The fourth review's V5.)
    local DUO = {}
    for _, e in ipairs(ENEMIES) do
        DUO[#DUO + 1] = e
    end
    DUO[#DUO + 1] = { "boss2", "BP_Monster_Boss_C", 3300.0, 3000.0, 100.0, 5000, 400, true }
    for _, first in ipairs({ "boss", "boss2" }) do
        local d = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, DUO)
        local dh, dg = d.pcs[1], d.pcs[2]
        d:run(4)
        Session.moveTo(dh, 0, 0)
        Session.moveTo(dg, 500, 0)
        d:run(2)
        local function state(pc, id, s)
            local c = rawget(field(Session.enemyOn(pc, id), "Controller"), "__fields").SGameAIComponent
            c.CurrentStateTag = { TagName = { ToString = function() return s end } }
        end
        local function beat(id)
            local e = Session.enemyOn(dh, id)
            Fake.setHealth(e, 0)
            Fake.put(e, "dead", true)
            d:run(1)
            dh.hudLayout:UnRegisterBossHPBar(e)
            d:run(8)
        end
        for _, pc in ipairs(d.pcs) do
            pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
            state(pc, "boss", "None")
            state(pc, "boss2", "None")
        end
        d:run(8)
        Session.scene(dh, true)
        step(dh, GUID)
        step(dh, STEP)
        dh.globalTags[#dh.globalTags + 1] = FLAG
        d:run(14)
        Session.scene(dh, false)
        state(dh, "boss", "AI.State.Combat")
        state(dh, "boss2", "AI.State.Combat")
        dh.hudLayout:RegisterBossHPBar(Session.enemyOn(dh, "boss"))
        dh.hudLayout:RegisterBossHPBar(Session.enemyOn(dh, "boss2"))
        d:run(22)
        check(not has(dg.storyGuids, GUID) and count(dg.logs, "sp:boss and sp:boss2, not started in this world") == 1,
            "one start of the host's that brings two bosses: held under both")
        beat(first)
        check(not has(dg.storyGuids, GUID),
            "the host beats " .. first .. " first: still held, the other alive there and not started here")
        beat(first == "boss" and "boss2" or "boss")
        check(has(dg.storyGuids, GUID) and has(dg.globalTags, FLAG), "both beaten: taken")
        allErrors(d)
    end

    -- Another boss's bar in the window that the host leaves alive (an elite by the arena, a bar that only blinked): waited
    -- for as the start's other boss, nothing ended the wait once the real one was beaten, and the start stayed held
    -- for the rest of the session. Once one is beaten there, the host not down since, another whose fight there is over
    -- isn't waited for. One whose fight ended with the host down is still the host's to come back to: a start of two,
    -- one beaten, the host lost to the other. (The fifth review's V9.)
    for _, how in ipairs({ "left alive", "lost to" }) do
        local d = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, DUO)
        local dh, dg = d.pcs[1], d.pcs[2]
        d:run(4)
        Session.moveTo(dh, 0, 0)
        Session.moveTo(dg, 500, 0)
        d:run(2)
        local function state(pc, id, s)
            local c = rawget(field(Session.enemyOn(pc, id), "Controller"), "__fields").SGameAIComponent
            c.CurrentStateTag = { TagName = { ToString = function() return s end } }
        end
        for _, pc in ipairs(d.pcs) do
            pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
            state(pc, "boss", "None")
            state(pc, "boss2", "None")
        end
        d:run(8)
        Session.scene(dh, true)
        step(dh, GUID)
        step(dh, STEP)
        dh.globalTags[#dh.globalTags + 1] = FLAG
        d:run(14)
        Session.scene(dh, false)
        state(dh, "boss", "AI.State.Combat")
        local first, other = Session.enemyOn(dh, "boss"), Session.enemyOn(dh, "boss2")
        dh.hudLayout:RegisterBossHPBar(first)
        if how == "left alive" then
            d:run(5)
            dh.hudLayout:RegisterBossHPBar(other)       -- (another's bar 5 s on, in the window's tail)
            d:run(4)
            dh.hudLayout:UnRegisterBossHPBar(other)     -- (left alive: its bar down there, the first's fight still on)
            d:run(18)
        else
            state(dh, "boss2", "AI.State.Combat")
            dh.hudLayout:RegisterBossHPBar(other)       -- (a start of two)
            d:run(22)
        end
        check(not has(dg.storyGuids, GUID), "(a start held under two)")
        Fake.setHealth(first, 0)                        -- (the host beats the first)
        Fake.put(first, "dead", true)
        d:run(1)
        dh.hudLayout:UnRegisterBossHPBar(first)
        if how == "left alive" then
            d:run(12)
            check(has(dg.storyGuids, GUID) and has(dg.globalTags, FLAG)
                and count(dg.logs, "is taken now: one beaten in the host's world, the others' fight there over") == 1,
                "another's bar in the window, left alive by the host: the start is taken once the real one is beaten there")
        else
            d:run(2)
            Session.die(dh)                             -- (and loses to the other)
            dh.hudLayout:UnRegisterBossHPBar(other)
            d:run(12)
            Session.revive(dh)
            Session.respawned(dh)
            d:run(12)
            check(not has(dg.storyGuids, GUID) and not has(dg.globalTags, FLAG),
                "a start of two, one beaten, the host lost to the other: still held, that one alive there and not started here")
        end
        allErrors(d)
    end

    -- A boss's fall while the host's scene plays, or in the 15 s after it, is no fall that scene belongs to: the late
    -- guest's own elite beaten 4 s into the host's start scene let the whole start go, taken at once, its trigger spent
    -- (326 again). Only a scene begun within 10 s after a fall is that fall's. (The fifth review's V3.)
    local FELL = {}
    for _, e in ipairs(ENEMIES) do
        FELL[#FELL + 1] = e
    end
    FELL[#FELL + 1] = { "elite", "BP_Monster_Boss_C", 4200.0, 0.0, 100.0, 5000, 400, true }
    local l = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, FELL)
    local lh, lg = l.pcs[1], l.pcs[2]
    l:run(4)
    Session.moveTo(lh, 0, 0)
    Session.moveTo(lg, 4000, 0)
    l:run(2)
    for _, pc in ipairs(l.pcs) do
        pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
        ai(pc, "None")
        onSide(pc, "Faction.Player", 1)
    end
    l:run(8)
    local elite = Session.enemyOn(lg, "elite")
    lg.hudLayout:RegisterBossHPBar(elite)           -- (the guest's own fight with it: the game's bar there)
    l:run(3)
    Session.scene(lh, true)
    step(lh, GUID)
    step(lh, STEP)
    lh.globalTags[#lh.globalTags + 1] = FLAG
    l:run(4)
    swing(lg, elite, select(1, Fake.health(elite)) - 300)
    l:run(0.5)
    swing(lg, elite, 0)
    l:run(0.6)
    Fake.put(elite, "dead", true)
    l:run(0.4)
    lg.hudLayout:UnRegisterBossHPBar(elite)
    l:run(8.5)
    Session.scene(lh, false)
    ai(lh, "AI.State.Combat")
    onSide(lh, "Faction.Enemy", 0)
    bossStart(l)
    l:run(22)
    check(not has(lg.storyGuids, GUID) and not has(lg.storyGuids, STEP) and not has(lg.globalTags, FLAG)
        and count(lg.logs, "left for this world's own start of it") == 1,
        "the guest's own elite falls 4 s into the host's start scene: the start is still held in the guest's world")
    allErrors(l)
    -- The same fall a second into the host's scene, and 5 s before it: a fight of the guest's own, which the host never
    -- joined, began no scene of the host's whenever it fell. Counted within the 10 s before the scene or in its first
    -- seconds, it let the whole start go. (The sixth review's V8.)
    for _, lead in ipairs({ 0.2, -5 }) do
        local o = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, FELL)
        local oh, og = o.pcs[1], o.pcs[2]
        o:run(4)
        Session.moveTo(oh, 0, 0)
        Session.moveTo(og, 4000, 0)
        o:run(2)
        for _, pc in ipairs(o.pcs) do
            pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
            ai(pc, "None")
            onSide(pc, "Faction.Player", 1)
        end
        o:run(8)
        local own = Session.enemyOn(og, "elite")
        og.hudLayout:RegisterBossHPBar(own)
        o:run(3)
        local function falls()
            swing(og, own, select(1, Fake.health(own)) - 300)
            o:run(0.5)
            swing(og, own, 0)
            o:run(0.6)
            Fake.put(own, "dead", true)
            o:run(0.4)
            og.hudLayout:UnRegisterBossHPBar(own)
        end
        if lead < 0 then
            falls()
            o:run(-lead)
        end
        Session.scene(oh, true)
        step(oh, GUID)
        step(oh, STEP)
        oh.globalTags[#oh.globalTags + 1] = FLAG
        if lead >= 0 then
            o:run(lead)
            falls()
            o:run(12.3)
        else
            o:run(14)
        end
        Session.scene(oh, false)
        ai(oh, "AI.State.Combat")
        onSide(oh, "Faction.Enemy", 0)
        bossStart(o)
        o:run(22)
        check(not has(og.storyGuids, GUID) and not has(og.storyGuids, STEP) and not has(og.globalTags, FLAG)
            and count(og.logs, "left for this world's own start of it") == 1,
            "the guest's own elite falls " .. (lead < 0 and "5 s before" or "a second into") .. " the host's start scene: the start is still held")
        allErrors(o)
    end

    -- The same in a party, another guest's bar up on that elite in the same moment as this one's (two guests charging
    -- it together): no bar of the host's, so still a fight the host never joined. Read as the host's joining, its fall
    -- let the late guest's start go. (The seventh review's V5.)
    do
        local o = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, FELL)
        local oh, og, op = o.pcs[1], o.pcs[2], o.pcs[3]
        o:run(4)
        Session.moveTo(oh, 0, 0)
        Session.moveTo(og, 4000, 0)
        Session.moveTo(op, 4300, 200)
        o:run(2)
        for _, pc in ipairs(o.pcs) do
            pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
            ai(pc, "None")
            onSide(pc, "Faction.Player", 1)
        end
        o:run(8)
        local own = Session.enemyOn(og, "elite")
        og.hudLayout:RegisterBossHPBar(own)
        op.hudLayout:RegisterBossHPBar(Session.enemyOn(op, "elite"))
        o:run(3)
        Session.scene(oh, true)
        step(oh, GUID)
        step(oh, STEP)
        oh.globalTags[#oh.globalTags + 1] = FLAG
        o:run(0.2)
        swing(og, own, select(1, Fake.health(own)) - 300)
        o:run(0.5)
        swing(og, own, 0)
        o:run(0.6)
        Fake.put(own, "dead", true)
        o:run(0.4)
        og.hudLayout:UnRegisterBossHPBar(own)
        o:run(12.3)
        Session.scene(oh, false)
        ai(oh, "AI.State.Combat")
        onSide(oh, "Faction.Enemy", 0)
        oh.hudLayout:RegisterBossHPBar(Session.enemyOn(oh, "boss"))
        o:run(24)
        check(net(og).partnerBosses ~= nil and not has(og.storyGuids, GUID) and not has(og.globalTags, FLAG)
            and count(og.logs, "left for this world's own start of it") == 1,
            "a party, another guest's bar on the late guest's own elite in the same moment: its fall still holds the start")
        allErrors(o)
    end

    -- A boss of phases: the first falls with the guest away, its fall's scene tells its win, and the next phase's bar
    -- comes up as that scene ends. The win is no start: held under the next phase, the guest had none of it till that
    -- phase fell, and none at all if the session ended first. (The fourth review's V6.)
    local p, ph, pg = pair()
    for _, pc in ipairs(p.pcs) do
        pc.env.PBZ.game.isStoryLevel = function(level) return level == "Map_Xigu" end
    end
    bossStart(p)
    local phase1 = Session.enemyOn(pg, "boss")
    swing(pg, phase1, select(1, Fake.health(phase1)) - 10)
    p:run(6)
    Session.moveTo(pg, 90000, 0)                    -- (900 m off as it falls)
    p:run(3)
    bossEnd(p)
    Session.scene(ph, true)                         -- (its fall's scene, a second on)
    p:run(4)
    step(ph, "Map_Xigu-BP_FlowActor_C_Phase1Won")
    ph.globalTags[#ph.globalTags + 1] = "xg.boss.phase1.won"
    p:run(10)
    Session.scene(ph, false)
    local phase2 = Fake.enemy(ph, "boss2", "BP_Monster_Boss_C", 3000.0, 3200.0, 100.0, 5000, 400, true)
    p:run(1)
    ph.hudLayout:RegisterBossHPBar(phase2)
    p:run(24)
    check(has(pg.storyGuids, "Map_Xigu-BP_FlowActor_C_Phase1Won") and has(pg.globalTags, "xg.boss.phase1.won")
        and count(pg.logs, "left for this world's own start of it") == 0,
        "a phase falls, its fall's scene tells its win, the next phase's bar comes up: the win is taken, not held as a start")
    allErrors(p)

    -- A fight both are in, the guest's own bar up first (its scene ended first), then the host's: the first phase's fall
    -- is the host's fight's too, and its win's steps are taken, the guest down at the fall. (A guard that left out every
    -- fall of a fight this player had told held the win under the next phase again: the sixth review's V8.)
    do
        local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, {
            { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
            { "boss2", "BP_Monster_Boss_C", 3300.0, 3000.0, 100.0, 5000, 400, true },
        })
        local th, tg = t.pcs[1], t.pcs[2]
        t:run(4)
        Session.moveTo(th, 2500, 2500)
        Session.moveTo(tg, 2800, 2500)
        t:run(2)
        for _, pc in ipairs(t.pcs) do
            pc.env.PBZ.game.isStoryLevel = function() return false end
        end
        local function aiOf(pc, id, state)
            local c = rawget(field(Session.enemyOn(pc, id), "Controller"), "__fields").SGameAIComponent
            c.CurrentStateTag = { TagName = { ToString = function() return state end } }
        end
        local WON, NEXT, DOWN = "AAAA0000BBBB1111CCCC2222DDDD3333", "EEEE4444FFFF5555AAAA6666BBBB7777", "boss.phase1.down"
        aiOf(tg, "boss2", "None")
        tg.hudLayout:RegisterBossHPBar(Session.enemyOn(tg, "boss"))
        t:run(1)
        th.hudLayout:RegisterBossHPBar(Session.enemyOn(th, "boss"))
        t:run(3)
        Session.die(tg)
        t:run(3)
        local first = Session.enemyOn(th, "boss")
        Fake.setHealth(first, 0)
        Fake.put(first, "dead", true)
        t:run(1)
        th.hudLayout:UnRegisterBossHPBar(first)
        t:run(1)
        Session.scene(th, true, "Seq023")
        step(th, WON)
        step(th, NEXT)
        th.globalTags[#th.globalTags + 1] = DOWN
        t:run(14)
        Session.scene(th, false)
        aiOf(th, "boss2", "AI.State.Combat")
        th.hudLayout:RegisterBossHPBar(Session.enemyOn(th, "boss2"))
        t:run(12)
        Session.revive(tg)
        t:run(60)
        check(has(tg.storyGuids, WON) and has(tg.storyGuids, NEXT) and has(tg.globalTags, DOWN),
            "a fight both are in, the guest's bar up first, the guest down as the first phase falls: its win is taken, not held under the next phase")
        allErrors(t)
    end
end

-- A boss that falls and is up again a few seconds on (Xiao Xue's rise: the bench, 11-18): its fight is told again, and
-- the guest, by it and in its fight till the fall, was told to press E at the black wall or F3 to join, inside that
-- wall. Not told for a boss that fell here a moment ago; a fight begun later is told as ever.
local function aBossRises()
    part("a boss up again after its fall")
    local TIP = "press E at the black wall, or F3, to join"
    for _, later in ipairs({ false, true }) do
        local s, h, g = pair()
        local onH, onG = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        Session.moveTo(g, 60000, 0)                             -- (the guest far off as the fight begins: told of F3)
        s:run(2)
        bossStart(s)
        Session.moveTo(g, 2800, 2900)                           -- (then in, beside it)
        s:run(2)
        swing(g, onG, select(1, Fake.health(onG)) - 100)        -- (and in its fight)
        s:run(3)
        local told = count(g.logs, TIP)
        bossEnd(s)                                              -- (it falls: the host's kill)
        s:run(later and 20 or 4)
        for _, e in ipairs({ onH, onG }) do                     -- (and is up again, in both worlds)
            Fake.put(e, "dead", false)
            Fake.setHealth(e, select(2, Fake.health(e)))
        end
        h.hudLayout:RegisterBossHPBar(onH)
        s:run(4)
        if later then
            check(net(g).partnerBosses["sp:boss"] == true and count(g.logs, TIP) == told + 1,
                "one whose fight begins 20 s after its fall: the guest by it is told how to join, as ever")
        else
            check(told == 0 and net(g).partnerBosses["sp:boss"] == true and count(g.logs, TIP) == told,
                "a boss up again 4 s after its fall, the guest by it: its fight shown there, and no word of a wall to press E at ("
                    .. count(g.logs, TIP) - told .. ")")
        end
        allErrors(s)
    end
end

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

-- A door of the game's own kind (BP_BlockBase: single and double doors, block gates) as the bench found it, 11-16: open
-- is its own DoorOpen, and neither a player's opening nor the word's own call (SwitchWithoutPlaySequence) sets the
-- switch's CurSwitchState, the one thing the mod looked at. The key door of Xigu, opened by the guest with its key, the
-- host 4 m off: never told, and shut in the host's world.
local function doorsOfTheGames()
    part("a door of the game's own kind")
    local s, h, g = pair()
    local function door(pc, name)
        local d = Fake.switch(pc, name, 330.0, 0.0, 100.0)
        Fake.put(d, "DoorOpen", false)
        Fake.put(d, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "DoorOpen", true) end)
        return d
    end
    local KEY, GATE = "BP_SingleDoor_Poverty_C_UAID_3", "BP_Block_Gate_C_UAID_4"
    local hostDoor, guestDoor = door(h, KEY), door(g, KEY)
    local hostGate, guestGate = door(h, GATE), door(g, GATE)
    s:run(3)
    Fake.arrive(g, guestDoor)
    Fake.put(guestDoor, "DoorOpen", true)           -- (the guest opens it with its key)
    s:run(3)
    check(count(g.sent, "^E SWO " .. KEY .. "$") == 1, "a door the guest opens with its key is told ("
        .. count(g.sent, "^E SWO " .. KEY .. "$") .. ")")
    check(field(hostDoor, "DoorOpen") == true and field(hostDoor, "CurSwitchState") == false,
        "and opens in the host's world, its CurSwitchState false there as in the game")
    check(count(h.sent, "^E SWO " .. KEY .. "$") == 0, "which doesn't take that for an opening of its own")
    Fake.put(hostGate, "DoorOpen", true)            -- (and a gate the host opens)
    s:run(3)
    check(field(guestGate, "DoorOpen") == true and count(h.sent, "^E SWO " .. GATE .. "$") == 1,
        "a gate the host opens is open in the guest's world")
    s:run(22)
    local named = 0
    for _, line in ipairs(h.sent) do
        if line:find("^E SWO ") and line:find(KEY, 1, true) and line:find(GATE, 1, true) then
            named = named + 1
        end
    end
    check(named >= 1, "and the host names both again now and then, the one opened by word too, for one who comes later")
    -- A door this world's own game shuts again, loaded all along (a fight's, a scene's, if any does that): the host's
    -- word, every 20 s, opened it again. Left to the game now; one that comes back into reach shut is still opened.
    Fake.put(guestDoor, "DoorOpen", false)          -- (shut in the guest's world by its own game, open in the host's)
    s:run(45)
    check(field(guestDoor, "DoorOpen") == false,
        "a door the guest's game shuts again, open in the host's: left shut through the host's next words")
    for i, sw in ipairs(g.switches) do              -- (the gate goes out of reach, and comes back shut 10 s on)
        if sw == guestGate then
            table.remove(g.switches, i)
            break
        end
    end
    Fake.put(guestGate, "DoorOpen", false)
    s:run(10)
    g.switches[#g.switches + 1] = guestGate
    s:run(25)
    check(field(guestGate, "DoorOpen") == true, "one that went out of reach and came back shut is opened by the host's word, as ever")
    -- A door the guest's world opens by itself, no walk up of its player's (a scene's, a quest step's, a fight's end,
    -- that guest further on in the story): not told, and shut in the host's world, whose story it isn't yet. The host's
    -- own are told, press or not. (The third review.)
    local SELF = "BP_Block_Door_C_UAID_5"
    local hostSelf, guestSelf = door(h, SELF), door(g, SELF)
    s:run(3)
    Fake.put(guestSelf, "DoorOpen", true)
    s:run(3)
    check(count(g.sent, "^E SWO " .. SELF .. "$") == 0 and field(hostSelf, "DoorOpen") == false,
        "a door the guest's world opens by itself, no press of its player's: not told, shut in the host's world")
    Fake.put(hostSelf, "DoorOpen", true)
    s:run(3)
    check(count(h.sent, "^E SWO " .. SELF .. "$") == 1, "one the host's world opens by itself is told all the same")
    allErrors(s)

    -- FollowHostStory = Off: a switch with flags of its own flow is a story's, and the guest's own to open; a plain door
    -- still opens by the host's word. (Every naming, 20 s apart, wrote the host's flags into that guest's save.)
    local o, oh, og = pair("FollowHostStory = Off\n")
    local QUEST, PLAIN = "BP_Block_Gate_C_UAID_6", "BP_SingleDoor_Poverty_C_UAID_7"
    local hostQuest, guestQuest = door(oh, QUEST), door(og, QUEST)
    local hostPlain, guestPlain = door(oh, PLAIN), door(og, PLAIN)
    Fake.flags(hostQuest, { "quest.gate.open" })
    Fake.flags(guestQuest, { "quest.gate.open" })
    o:run(3)
    Fake.put(hostQuest, "DoorOpen", true)
    Fake.put(hostPlain, "DoorOpen", true)
    o:run(25)
    local function has(list, x)
        for _, v in ipairs(list) do
            if v == x then
                return true
            end
        end
        return false
    end
    check(field(guestPlain, "DoorOpen") == true, "FollowHostStory = Off: a plain door the host opens is open for the guest")
    check(field(guestQuest, "DoorOpen") == false and not has(og.globalTags, "quest.gate.open"),
        "one with flags of its own flow stays the guest's own: not opened by word, none of its flags raised")
    -- (And the host's namings of it after that cost this guest no search: looked for again at every naming, it was
    -- found and left as it is each time. The fourth review's V11.)
    local searches, inWord = 0, false
    local findAll, word = og.env.FindAllOf, og.env.PBZ.coop.handlers.SWO
    og.env.FindAllOf = function(class)
        if class == "PBZSwitchBase" and inWord then
            searches = searches + 1
        end
        return findAll(class)
    end
    og.env.PBZ.coop.handlers.SWO = function(rest, from)
        inWord = true
        local ok, err = pcall(word, rest, from)
        inWord = false
        if not ok then
            error(err)
        end
    end
    o:run(45)
    check(searches == 0, "and the host's namings of it after that cost the guest no search for it (" .. searches .. ")")
    allErrors(o)
    local f, fh, fg = pair()
    local hostQ2, guestQ2 = door(fh, QUEST), door(fg, QUEST)
    Fake.flags(hostQ2, { "quest.gate.open" })
    Fake.flags(guestQ2, { "quest.gate.open" })
    f:run(3)
    Fake.put(hostQ2, "DoorOpen", true)
    f:run(5)
    check(field(guestQ2, "DoorOpen") == true and has(fg.globalTags, "quest.gate.open"),
        "following the host's story: opened by word, its flags raised with it")
    allErrors(f)

    -- A lever has no DoorOpen. Asked for one at every look (1.5 s) of every lever, lift and cage around: a name the class
    -- hasn't got is the read that took the game down on the bench (an actor still streaming in). Asked till the class is
    -- known, then no more; a door's is still read every look.
    local t, th, tg = pair()
    local LEVER = "BP_SwitchDevice_C_UAID_9"
    local hostLever, guestLever = Fake.switch(th, LEVER, 330.0, 0.0, 100.0), Fake.switch(tg, LEVER, 330.0, 0.0, 100.0)
    Fake.put(guestLever, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "CurSwitchState", true) end)
    local tDoor = door(tg, KEY)
    door(th, KEY)
    -- (And one with neither name, a wharf: no CurSwitchState to read either. The fourth review's V4.)
    local WHARF = "BP_Wharf_C_UAID_10"
    Fake.switch(th, WHARF, 360.0, 0.0, 100.0, nil, true)
    Fake.switch(tg, WHARF, 360.0, 0.0, 100.0, nil, true)
    t:run(40)
    local asked = th.missed[LEVER .. ".DoorOpen"] or 0
    check(asked >= 1 and asked <= 3, "a lever is asked for a DoorOpen three looks at most, not at every look (" .. asked .. " in 40 s)")
    local state = th.missed[WHARF .. ".CurSwitchState"] or 0
    check(state >= 1 and state <= 3 and (tg.missed[WHARF .. ".CurSwitchState"] or 0) <= 3,
        "a wharf, with no CurSwitchState and no DoorOpen, is asked for neither once that's known (" .. state .. " in 40 s)")
    Fake.put(hostLever, "CurSwitchState", true)     -- (the host pulls it)
    t:run(3)
    check(field(guestLever, "CurSwitchState") == true and count(th.sent, "^E SWO " .. LEVER .. "$") == 1,
        "pulled by the host, it's still told and opens for the guest")
    Fake.arrive(tg, tDoor)
    Fake.put(tDoor, "DoorOpen", true)               -- (and a door the guest opens then, long after)
    t:run(3)
    check(count(tg.sent, "^E SWO " .. KEY .. "$") == 1, "and a door opened after all that is still seen and told")
    allErrors(t)

    -- A press seen late: the guest opens a door while the host is on another map, or in a quiet after a stall, and the
    -- first look that sees it open comes more than 20 s after the walk up. Told all the same. (The fourth review's V7.)
    local a, ah, ag = pair()
    local LATE, QUIET = "BP_SingleDoor_Poverty_C_UAID_8", "BP_Block_Door_C_UAID_9"
    local hostLate, guestLate = door(ah, LATE), door(ag, LATE)
    local hostQuiet, guestQuiet = door(ah, QUIET), door(ag, QUIET)
    a:run(3)
    ah.map = "Map_Other"
    a:run(3)
    Fake.arrive(ag, guestLate)
    Fake.put(guestLate, "DoorOpen", true)
    a:run(30)
    ah.map = "Map_Xigu"
    a:run(6)
    check(count(ag.sent, "^E SWO " .. LATE .. "$") == 1 and field(hostLate, "DoorOpen") == true,
        "a door the guest opened while the host was on another map is told once the host is back, 30 s on")
    Fake.arrive(ag, guestQuiet)
    Fake.put(guestQuiet, "DoorOpen", true)
    net(ag).quietUntil = ag.now + 25                -- (a stall as it opens, and hitches after it)
    a:run(30)
    check(count(ag.sent, "^E SWO " .. QUIET .. "$") == 1 and field(hostQuiet, "DoorOpen") == true,
        "and one opened as the guest's game stalled, seen as the quiet ends 25 s on")
    -- A walk up to a rubbish pile (a chest, a bell) is no press of a door: one the guest's world opens by itself within
    -- 20 s of it isn't told. (The fourth review's V10.)
    local PILED = "BP_Block_Door_C_UAID_12"
    local hostPiled, guestPiled = door(ah, PILED), door(ag, PILED)
    local pile = Fake.pile(ag, "BP_Rubbish_C_UAID_13", 400.0, 0.0, 100.0)
    a:run(3)
    Fake.arrive(ag, pile)
    a:run(10)
    Fake.put(guestPiled, "DoorOpen", true)
    a:run(4)
    check(count(ag.sent, "^E SWO " .. PILED .. "$") == 0 and field(hostPiled, "DoorOpen") == false,
        "a walk up to a rubbish pile, then a door the guest's world opens by itself 10 s on: not told")
    -- A door seen shut that goes out of reach, and comes back into it open, was opened by its world while away: a walk up
    -- to a lever meanwhile is no press of it. (The fifth review.)
    local AWAY = "BP_SingleDoor_Poverty_C_UAID_14"
    local hostAway, guestAway = door(ah, AWAY), door(ag, AWAY)
    local lever = Fake.switch(ag, "BP_SwitchDevice_C_UAID_15", 600.0, 0.0, 100.0)
    a:run(3)
    for i, sw in ipairs(ag.switches) do
        if sw == guestAway then
            table.remove(ag.switches, i)            -- (out of reach: not loaded here)
            break
        end
    end
    a:run(10)
    Fake.arrive(ag, lever)
    a:run(60)
    Fake.put(guestAway, "DoorOpen", true)
    ag.switches[#ag.switches + 1] = guestAway       -- (back in reach, open)
    a:run(5)
    check(count(ag.sent, "^E SWO " .. AWAY .. "$") == 0 and field(hostAway, "DoorOpen") == false,
        "a door seen shut, out of reach while the guest walks up to a lever, back in reach open 60 s on: not told")
    allErrors(a)
end

-- Point 6 of a report on 1.7.1 (three players): "unless we're near each other (like within 75m), bells and certain things
-- don't sync". The game loads a level's things only around the player: a chain or a lever another player opened far off
-- wasn't there to open at the word. The chain was let go at once, the lever two minutes on, and a guest on another map at
-- the word never heard of either.
local function farThings()
    part("chains and levers another player opened far off")
    local s = party(nil, nil, { "Host", "Guest", "Guest" })
    local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 60000, 0)
    Session.moveTo(b, 0, 500)
    b.map = "Map_Other"
    s:run(3)
    local CHAIN, LEVER = "BP_GameplayBlocker_Chain_C_UAID_7", "ABP_Switch_C_UAID_7"
    local function chainOn(pc, x)
        return Fake.blocker(pc, CHAIN, x, 0.0, 100.0)
    end
    local function leverOn(pc, x)
        local lv = Fake.switch(pc, "ABP_Switch_C", x, 0.0, 100.0)
        rawset(lv, "__name", LEVER)
        Fake.put(lv, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "CurSwitchState", true) end)
        return lv
    end
    -- Guest a breaks a chain and pulls a lever out where only its world has them loaded.
    local chain, lever = chainOn(a, 60200.0), leverOn(a, 60300.0)
    s:run(2)
    Fake.put(chain, "bBroken", true)
    Fake.arrive(a, lever)
    Fake.put(lever, "CurSwitchState", true)
    s:run(3)
    check(count(a.sent, "^E BLK " .. CHAIN .. "$") == 1 and count(a.sent, "^E SWO " .. LEVER .. "$") == 1, "(guest a tells both)")
    -- Three minutes on, the host gets there: its world loads them, the chain still whole, the lever shut.
    s:run(180)
    local hChain, hLever = chainOn(h, 60200.0), leverOn(h, 60300.0)
    Session.moveTo(h, 59000, 0)
    s:run(4)
    check(field(hChain, "bBroken") == true, "a chain another player broke far off is broken as the host's world loads it")
    check(field(hLever, "CurSwitchState") == true, "and a lever they pulled, opened as it loads, three minutes on too")
    check(count(h.logs, "Broke " .. CHAIN .. ": broken for the others") == 0 and count(h.logs, "Opened " .. LEVER) == 0,
        "neither told back as the host's own doing")
    -- Guest b was on another map at the word. Back on this one, its world loads them too: the host names them again.
    b.map = "Map_Xigu"
    s:run(3)
    local bChain, bLever = chainOn(b, 60200.0), leverOn(b, 60300.0)
    Session.moveTo(b, 59500, 0)
    s:run(25)
    check(field(bChain, "bBroken") == true and field(bLever, "CurSwitchState") == true,
        "a guest who was on another map at the word has them too, once back and loaded: the host names them again")
    check(count(b.sent, "^E BLK") == 0 and count(b.sent, "^E SWO") == 0, "and tells nobody of them")
    -- What the host names again costs no search where it's known: a world that has them, or waits for them, looks for nothing.
    local searched = 0
    local real = b.env.FindAllOf
    b.env.FindAllOf = function(class)
        if class == "BP_GameplayBlocker_Base_C" or class == "PBZSwitchBase" then
            searched = searched + 1
        end
        return real(class)
    end
    b.env.PBZ.coop.handlers.BLK(CHAIN)
    b.env.PBZ.coop.handlers.SWO(LEVER)
    b.env.FindAllOf = real
    check(searched == 0, "naming again what a world has already costs it no search")
    allErrors(s)
end

-- The review of the first version of farThings' fix: what waits was forgotten at a trip away and back, wasn't applied with
-- nobody else on the map, outlived the session, and was searched for in the quiet after a load.
local function farThingsKept()
    part("chains and levers waited for: kept by map, for the session")
    local s = party(nil, nil, { "Host", "Guest", "Guest" })
    local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 60000, 0)
    Session.moveTo(b, 0, 500)
    s:run(3)
    local CHAIN, LEVER = "BP_GameplayBlocker_Chain_C_UAID_8", "ABP_Switch_C_UAID_8"
    local function leverOn(pc, x)
        local lv = Fake.switch(pc, "ABP_Switch_C", x, 0.0, 100.0)
        rawset(lv, "__name", LEVER)
        Fake.put(lv, "SwitchWithoutPlaySequence", function(self) Fake.put(self, "CurSwitchState", true) end)
        return lv
    end
    local chain, lever = Fake.blocker(a, CHAIN, 60200.0, 0.0, 100.0), leverOn(a, 60300.0)
    s:run(2)
    Fake.put(chain, "bBroken", true)
    Fake.arrive(a, lever)
    Fake.put(lever, "CurSwitchState", true)
    s:run(3)
    -- Everyone to another map and back: what the host waits for there is still that map's.
    for _, pc in ipairs({ h, a, b }) do
        pc.map = "Map_Other"
    end
    s:run(8)
    for _, pc in ipairs({ h, a, b }) do
        pc.map = "Map_Xigu"
    end
    s:run(4)
    -- Guest a goes off for good (another map); the host walks there alone and its world loads them.
    a.map = "Map_Other"
    b.map = "Map_Other"
    s:run(4)
    local hChain, hLever = Fake.blocker(h, CHAIN, 60200.0, 0.0, 100.0), leverOn(h, 60300.0)
    Session.moveTo(h, 59000, 0)
    s:run(4)
    check(field(hChain, "bBroken") == true and field(hLever, "CurSwitchState") == true,
        "kept over a trip away and back, and done with nobody else on the map")
    allErrors(s)
    -- Sync off and on: a new session, what the last one waited for is gone.
    local p, ph, pg = pair()
    Session.moveTo(pg, 60000, 0)
    p:run(3)
    local pChain = Fake.blocker(pg, "BP_GameplayBlocker_Chain_C_UAID_9", 60200.0, 0.0, 100.0)
    p:run(2)
    Fake.put(pChain, "bBroken", true)
    p:run(3)
    Session.command(ph, "netoff")
    p:run(3)
    Session.command(ph, "neton host")
    p:run(6)
    local late = Fake.blocker(ph, "BP_GameplayBlocker_Chain_C_UAID_9", 60200.0, 0.0, 100.0)
    Session.moveTo(ph, 59000, 0)
    p:run(4)
    check(field(late, "bBroken") == false, "sync off: what was waited for went with that session")
    allErrors(p)
    -- The quiet after a load: a batch named then costs no search, and lands at the first look after it.
    local q, qh, qg = pair()
    q:run(3)
    local qChain = Fake.blocker(qg, "BP_GameplayBlocker_Chain_C_UAID_10", 320.0, 0.0, 100.0)
    q:run(2)
    net(qg).quietUntil = qg.now + 5
    local searched = 0
    local real = qg.env.FindAllOf
    qg.env.FindAllOf = function(class)
        if class == "BP_GameplayBlocker_Base_C" then
            searched = searched + 1
        end
        return real(class)
    end
    qg.env.PBZ.coop.handlers.BLK("BP_GameplayBlocker_Chain_C_UAID_10 BP_GameplayBlocker_Chain_C_UAID_11")
    qg.env.FindAllOf = real
    check(searched == 0, "named in the quiet after a load: no search then")
    net(qg).quietUntil = 0
    q:run(3)
    check(field(qChain, "bBroken") == true, "and broken at the first look after it")
    allErrors(q)
end

-- The same report: a bell a guest woke was never told to anyone. Only the host's went out (FLOW b), so the host and the
-- other guest had it only by ringing it themselves.
local function guestBells()
    part("bells a guest wakes")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
    table.insert(a.bellIds, "Bell_YXZR_009")        -- (guest a's own, from before the link)
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(a, 500, 0)
    Session.moveTo(b, 0, 500)
    s:run(8)
    -- Guest a rings a bell of its own, far from the others.
    table.insert(a.bellIds, "Bell_YXZR_005")
    s:run(8)
    check(count(a.sent, "^E FLOW b Bell_YXZR_005$") == 1, "a guest's bell, woken while linked, is told to the others")
    check(count(a.sent, "Bell_YXZR_009") == 0, "not one it had before the link")
    check(not b.storyMarks["Bell_YXZR_005"], "far from it, it waits")
    Session.moveTo(b, 30000 - 1200, 600)
    s:run(3)
    Session.moveTo(b, 0, 500)
    s:run(3)
    check(b.storyMarks["Bell_YXZR_005"] == true, "the other guest has it lit once it has been by it and gone on (the relay passes it on)")
    -- The host's world holds the story: a bell lit there by word, not rung, would never have had its first ring's flags.
    Session.moveTo(h, 30000 - 1500, 0)
    s:run(3)
    Session.moveTo(h, 0, 0)
    s:run(3)
    check(not h.storyMarks["Bell_YXZR_005"], "the host's world takes none: its bells are the ones it rang")
    check(count(h.logs, "bell woken here, told") == 0 and count(b.logs, "bell woken here, told") == 0,
        "neither tells it again as its own")
    -- A world whose woken list holds a bell by its row's name (YXZR_009, the row of Bell_YXZR_009): it's still that bell.
    -- (Looked up by BellID alone, it was let go as not in the game's table.)
    table.insert(a.bellIds, "YXZR_009")
    s:run(8)
    Session.moveTo(b, 20000 - 900, 0)
    s:run(3)
    Session.moveTo(b, 0, 500)
    s:run(3)
    check(b.storyMarks["YXZR_009"] == true, "a bell named by its row in the woken list is found in the table all the same")
    -- A load brings a world's whole list at once: that's no bells rung, nothing is told.
    local before = count(a.sent, "^E FLOW b")
    for i = 1, 8 do
        table.insert(a.bellIds, "Bell_LOAD_" .. i)
    end
    s:run(8)
    check(count(a.sent, "^E FLOW b") == before, "a world's whole list at once (a load) isn't told")
    allErrors(s)
    -- Two players: there's no other guest, so nothing is told.
    local p, ph, pg = pair()
    p:run(8)
    table.insert(pg.bellIds, "Bell_YXZR_005")
    p:run(8)
    check(count(pg.sent, "FLOW b") == 0, "two players: a guest's bell has nobody to go to")
    allErrors(p)
end

-- Point 3 on the bench (11-12, 1.7.2, the crane bell NLES_006 rung first by the host): 3 s into the host's scene the
-- guest's PC hid the host's figure, its collision off with it, and the bell's prompt shut for the guest at that instant
-- (the figure had stood in the bell's trigger), back only with the figure; the host's scene, 18 s of a 213 s sequence,
-- ended as "skipped" and was told; and the map subsystem said "None" for the map, so no host bell was ever lit then.
local function craneBellScenes()
    part("a crane bell's scene, on the bench's three causes")
    local s, h, g = pair()
    s:run(3)
    local function collisionOff(pc)
        return count(pc.trace, "SetActorEnableCollision false")
    end
    local before = collisionOff(h)
    Session.scene(g, true, "Seqs003-Seqs008-Seq038")
    s:run(6)
    check(net(h).ghostHidden == true and collisionOff(h) == before,
        "a partner in a scene: their figure is hidden, its collision kept (the bell's prompt stays here)")
    Session.scene(g, false)
    s:run(3)
    check(net(h).ghostHidden ~= true, "(shown again after it)")
    g.map = "Map_Other"
    s:run(8)
    check(net(h).ghostHidden == true and collisionOff(h) > before, "on another map it's hidden with no collision, as ever")
    g.map = "Map_Xigu"
    s:run(4)
    allErrors(s)
    -- The host rings a crane bell: its first touch, then its own scene. Watched to its end it isn't told as a skip.
    local q, qh, qg = pair()
    q:run(6)
    Session.firstTouch(qh)
    q:run(2)
    Session.scene(qh, true, "Seqs003-Seqs008-Seq038")
    q:run(4)
    Session.scene(qh, false)
    q:run(1)
    check(count(qh.sent, "^E SCENE skip") == 0, "the end of the host's own bell scene isn't told as a skip")
    -- The guest rings it too, its own scene: an older host's skip of that scene doesn't cut it.
    Session.firstTouch(qg)
    q:run(2)
    Session.scene(qg, true, "Seqs003-Seqs008-Seq038")
    q:run(1)
    qg.env.PBZ.coop.handlers.SCENE("skip Seqs003-Seqs008-Seq038")
    q:run(2)
    check((field(qg.scene, "skipped") or 0) == 0 and field(qg.scene, "playing") == true,
        "the guest's own bell scene isn't cut by a host's skip of it")
    Session.scene(qg, false)
    q:run(2)
    -- A scene that came with no sit is the story's, shared: the host's skip still skips it.
    q:run(25)
    Session.scene(qh, true, "Seq023")
    q:run(1)
    Session.scene(qg, true, "Seq023")
    q:run(0.5)
    Session.scene(qh, false)
    q:run(1)
    check(count(qh.sent, "^E SCENE skip Seq023$") == 1 and field(qg.scene, "skipped") == 1,
        "a story scene the host skips is still skipped on the guest")
    -- A sit (no first touch: a bell rung before, or the rest of a respawn) just before a boss's scene: that's the story's.
    Session.sit(qh)
    q:run(1)
    Session.scene(qh, true, "Seq030")
    q:run(1)
    Session.scene(qh, false)
    q:run(1)
    check(count(qh.sent, "^E SCENE skip Seq030$") == 1, "a scene right after a plain sit is the story's: its skip is told")
    -- The bell's scene, shown again long after its first touch, is told as any other.
    q:run(15)
    Session.scene(qh, true, "Seqs003-Seqs008-Seq038")
    q:run(1)
    Session.scene(qh, false)
    q:run(1)
    check(count(qh.sent, "^E SCENE skip Seqs003%-Seqs008%-Seq038$") == 1, "only while the first touch's own scene plays")
    allErrors(q)
    -- The map subsystem saying "None": the bell is found by its level, or by place alone.
    local m, mh, mg = pair()
    m:run(4)
    local ms = mg.env.FindFirstOf("MapSubsystem")
    Fake.put(ms, "GetCurrentMapID", function() return Fake.name("None") end)
    table.insert(mh.bellIds, "Bell_YXZR_009")
    m:run(8)
    Session.moveTo(mg, 20000 - 900, 0)
    m:run(3)
    Session.moveTo(mg, 500, 0)
    m:run(3)
    check(mg.storyMarks["Bell_YXZR_009"] == true, "with the map said as \"None\", the host's bell is still lit once been to")
    allErrors(m)
end

-- Point 3 of the same report: "crane bell cutscenes aren't sync'd and only appear to the one who hit the bell first, even
-- if all 3 of us time it correctly". A bell's first ring is each player's own: the host's ring of it (its bell, the flags
-- its flow raises, the flow steps it marks done) taken first by a guest standing by it made their own ring a plain sit.
local function ownRing()
    part("a bell's first ring is each player's own")
    local BELL, FLAG, STEP = "Bell_YXZR_009", "bell.crane.camp", "CRANE0123456789ABCDEF0123456789AB"
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
    s:run(4)
    h.env.PBZ.game.storyFlags = nil
    Session.moveTo(h, 20000 - 600, 0)
    Session.moveTo(a, 20000 - 800, 300)
    Session.moveTo(b, 20000 - 700, -300)
    s:run(8)
    -- The host rings it first: its world wakes the bell, raises the flag and marks the step.
    table.insert(h.bellIds, BELL)
    table.insert(h.globalTags, FLAG)
    h.eventPipeline.ExecuteNodeGuid:Add(STEP)
    s:run(20)
    check(not a.storyMarks[BELL] and not b.storyMarks[BELL], "the host's ring isn't lit under the guests standing by it")
    check(not a.storyMarks[FLAG] and not a.storyGuids[STEP] and not b.storyMarks[FLAG] and not b.storyGuids[STEP],
        "nor are its flag and flow step taken there: each guest's own ring is still theirs")
    check(count(a.logs, "the host's flow waits for your own ring") == 1, "(said once)")
    -- Guest a rings it: its own world wakes it and raises the same itself. Nothing of the host's is taken twice.
    table.insert(a.bellIds, BELL)
    table.insert(a.globalTags, FLAG)
    a.eventPipeline.ExecuteNodeGuid:Add(STEP)
    s:run(4)
    check(count(a.trace, "ActivateBellByID") == 0 and count(a.trace, "AddTagsByString.*" .. FLAG) == 0,
        "rung by the guest: nothing of the host's ring is done over it")
    -- Guest b goes on without ringing it: then it's lit there, and the flow it held back is taken.
    Session.moveTo(b, 0, 500)
    s:run(4)
    check(b.storyMarks[BELL] == true and b.storyMarks[FLAG] == true and b.storyGuids[STEP] == true,
        "a guest who walks on without ringing it has it lit then, and the host's flag and step with it")
    check(count(b.sent, "FLOW b " .. BELL) == 0, "and doesn't tell it back as its own")
    allErrors(s)
    -- The host's flags of its ring can come minutes on (on the bench the crane bell's came four minutes after, the scene
    -- first): they wait as long as the guest stands by it, ten minutes at most, and are taken once the guest goes on.
    local p, ph, pg = pair()
    p:run(4)
    ph.env.PBZ.game.storyFlags = nil
    Session.moveTo(ph, 20000 - 600, 0)
    Session.moveTo(pg, 20000 - 800, 300)
    p:run(8)
    table.insert(ph.bellIds, BELL)
    p:run(150)
    table.insert(ph.globalTags, FLAG)
    p:run(20)
    check(not pg.storyMarks[FLAG], "two players: the guest still by it, the host's flag from minutes on waits too")
    Session.moveTo(pg, 0, 500)
    p:run(4)
    check(pg.storyMarks[FLAG] == true and pg.storyMarks[BELL] == true, "the guest goes on: the flag is taken and the bell lit")
    -- A bell nobody else rang holds nothing back: standing by an unrung bell of one's own is no reason to wait.
    Session.moveTo(pg, 30000 - 800, 0)
    p:run(4)
    table.insert(ph.globalTags, "zddy.other.flag")
    p:run(20)
    check(pg.storyMarks["zddy.other.flag"] == true, "by a bell no other player rang, the host's flow comes as ever")
    allErrors(p)
    -- The guest's own first ring wakes the bell at the touch, and its scene starts some 5 s on: the host's flag that waited
    -- doesn't come in between (taken then, it could still stop that scene), nor during the scene.
    local t, th, tg = pair()
    t:run(4)
    th.env.PBZ.game.storyFlags = nil
    Session.moveTo(th, 20000 - 600, 0)
    Session.moveTo(tg, 20000 - 800, 300)
    t:run(8)
    table.insert(th.bellIds, BELL)
    t:run(8)
    table.insert(th.globalTags, FLAG)
    t:run(14)
    check(not tg.storyMarks[FLAG], "(the guest by the host's bell: its flag waits)")
    Session.firstTouch(tg)
    table.insert(tg.bellIds, BELL)
    t:run(4)
    check(not tg.storyMarks[FLAG], "the guest rings it: in the seconds before its scene the host's flag still waits")
    Session.scene(tg, true, "Seqs003-Seqs008-Seq038")
    t:run(6)
    check(not tg.storyMarks[FLAG], "and while the scene plays")
    Session.scene(tg, false)
    t:run(18)
    check(tg.storyMarks[FLAG] == true, "then it comes")
    allErrors(t)
    -- A load: the bells this player stood by were that world's. (Kept, one stood by in another save was lit in this one.)
    local v, vh, vg = pair()
    v:run(4)
    table.insert(vh.bellIds, BELL)
    v:run(8)
    Session.moveTo(vg, 20000 - 800, 300)
    v:run(3)
    Session.loadMap(vg)
    Session.moveTo(vg, 500, 19500)
    v:run(10)
    check(not vg.storyMarks[BELL], "a load forgets the bells stood by: another save's player never went near it")
    allErrors(v)
    -- In a party: a bell only another guest rang brings none of the host's flags, so it holds none back.
    local r = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    local rh, ra, rb = r.pcs[1], r.pcs[2], r.pcs[3]
    r:run(4)
    rh.env.PBZ.game.storyFlags = nil
    Session.moveTo(rh, 0, 0)
    Session.moveTo(ra, 20000 - 800, 0)
    Session.moveTo(rb, 20000 - 700, 300)
    r:run(8)
    table.insert(ra.bellIds, BELL)
    r:run(8)
    table.insert(rh.globalTags, "zddy.party.flag")
    r:run(20)           -- (the host's look, and 349's 6 s on the guests)
    check(rb.storyMarks["zddy.party.flag"] == true and not rb.storyMarks[BELL],
        "a party: by a bell only another guest rang, the host's flag comes as ever (the bell stays theirs to ring)")
    allErrors(r)
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
-- As s:run, with the games of `still` standing still (a load): their time goes on and nothing of theirs runs, their relay
-- still answering, as main.dll's does. each() after every frame.
local function runStill(s, seconds, still, each)
    for _ = 1, math.floor(seconds * 60 + 0.5) do
        for _, pc in ipairs(s.pcs) do
            if still[pc] then
                pc.now = pc.now + 1 / 60
            else
                Fake.frame(pc, 1 / 60)
            end
        end
        s.relay:step(s.pcs[1].now)
        if each then
            each()
        end
    end
end
-- A report on 1.7.1, three players online: "our boss damage seems to break at random times (sometimes it's right, then swaps
-- over to wayfarer damage)". Everyone's down after a wipe and respawns at once, each load as long as that PC makes it, and
-- nobody tells of a respawn's load: the first back saw the others silent for 12 s, gone, and its own load counted as time
-- alone, so its own Wayfarer came back at once, till the next one was back.
local function partyDifficulty()
    part("the game's difficulty in a party of three, through loads")
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, ENEMIES)
    for _, pc in ipairs(s.pcs) do
        pc.difficulty = 1                           -- (each save on Wayfarer)
    end
    s:run(8)
    check(everyone(s, function(pc) return pc.difficulty == 3 end), "all three on Hellwalker while they play together")
    local least = {}
    local function low()
        for _, pc in ipairs(s.pcs) do
            least[pc] = math.min(least[pc] or 9, pc.difficulty)
        end
    end
    local h, g1, g2 = s.pcs[1], s.pcs[2], s.pcs[3]
    -- (The host back first, then each guest: 20, 30 and 40 s of loading.)
    local still = {}
    for _, pc in ipairs(s.pcs) do
        rawset(pc.pawn, "__alive", false)
        still[pc] = true
    end
    local t = 0
    runStill(s, 60, still, function()
        t = t + 1 / 60
        for pc, back in pairs({ [h] = 20, [g1] = 30, [g2] = 40 }) do
            if still[pc] and t >= back then
                still[pc] = nil
                rawset(pc.pawn, "__alive", true)
            end
        end
        low()
    end)
    check(least[h] == 3, "a wipe, the host back from its load first, the guests still loading: the host stays on Hellwalker"
        .. " (" .. least[h] .. ")")
    check(least[g1] == 3 and least[g2] == 3, "and so do the guests, each back in turn")
    -- (Longer apart: the host back in 15 s, the guests' slow loads of over a minute.)
    for _, pc in ipairs(s.pcs) do
        rawset(pc.pawn, "__alive", false)
        still[pc] = true
    end
    t, least = 0, {}
    runStill(s, 85, still, function()
        t = t + 1 / 60
        for pc, back in pairs({ [h] = 15, [g1] = 65, [g2] = 70 }) do
            if still[pc] and t >= back then
                still[pc] = nil
                rawset(pc.pawn, "__alive", true)
            end
        end
        low()
    end)
    check(least[h] == 3, "the guests' loads of over a minute, the host back long before: still Hellwalker (" .. least[h] .. ")")
    allErrors(s)

    -- (The review of this fix.) Everyone loading 30 s, and both guests' links gone for 12 s just as the host is back: the
    -- host's own load isn't time alone, so a moment's gap there doesn't put its own mode back.
    for _, pc in ipairs(s.pcs) do
        rawset(pc.pawn, "__alive", false)
        still[pc] = true
    end
    t, least = 0, {}
    runStill(s, 50, still, function()
        t = t + 1 / 60
        for _, pc in ipairs({ g1, g2 }) do
            pc.cut = t >= 28 and t < 40
        end
        for pc, back in pairs({ [h] = 30, [g1] = 40, [g2] = 40 }) do
            if still[pc] and t >= back then
                still[pc] = nil
                rawset(pc.pawn, "__alive", true)
            end
        end
        low()
    end)
    check(least[h] == 3, "the guests' links gone a moment as the host comes back from its load: still Hellwalker ("
        .. least[h] .. ")")
    allErrors(s)

    -- A guest's game standing still for good, its link up all the same (a hang): gone after LOAD_MAX_S, 90 s.
    still = { [g1] = true, [g2] = true }
    runStill(s, 60, still)
    check(h.difficulty == 3, "both guests' games standing still a minute, their links up: still Hellwalker")
    runStill(s, 60, still)
    check(h.difficulty == 1, "two minutes: gone, the host's own Wayfarer back")
    s:run(6)
    check(h.difficulty == 3, "and Hellwalker again as they play on")
    allErrors(s)

    -- Really alone: both guests gone (their sync off), the host's own Wayfarer back 20 s on, as before.
    for _, pc in ipairs({ g1, g2 }) do
        Session.command(pc, "netoff")
    end
    s:run(15)
    check(h.difficulty == 3, "both guests gone a moment: still Hellwalker")
    s:run(15)
    check(h.difficulty == 1, "alone a while: the host's own Wayfarer back")
    allErrors(s)

    -- (The review of this fix.) A partner's game crashes, and comes back a while on: its relay links again before the game
    -- is in the world. Alone meanwhile, the host's own mode stays: no Hellwalker for a relay with nobody in the game yet.
    local c, ch, cg = pair(nil, function(hpc) hpc.difficulty = 1 end)
    c:run(2)
    check(ch.difficulty == 3, "two players: the host's Wayfarer is Hellwalker")
    c.relay:leave(cg)                               -- (the guest's game and its relay gone)
    local quiet = { [cg] = true }
    runStill(c, 40, quiet)
    check(ch.difficulty == 1, "the guest's game crashed: the host alone, its own Wayfarer back")
    local highest = 0
    cg.relay = "client"                             -- (started again: its relay links, its game still loading)
    runStill(c, 30, quiet, function() highest = math.max(highest, ch.difficulty) end)
    check(highest == 1, "its relay back before its game: the host stays on its own Wayfarer (up to " .. highest .. ")")
    quiet[cg] = nil
    c:run(6)
    check(ch.difficulty == 3, "its game back: Hellwalker again")
    allErrors(c)
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

    -- Both take the same pickup in the same moment, the guest's word here before the host's own look saw its copy go (the
    -- copy taken, unpickable, still found): one each. Waited for, the guest's share came as a second (the review of 11-09).
    both("matE", "Weapon_Material_02", 220.0, 40.0)
    s:run(2)
    local hE, gE = Session.items(h, "Weapon_Material_02"), Session.items(g, "Weapon_Material_02")
    Fake.put(pickupOn(h, "matE"), "bIsPickable", false)
    Session.gainItem(h, "Weapon_Material_02", 1)
    Fake.put(pickupOn(g, "matE"), "bIsPickable", false)
    Session.gainItem(g, "Weapon_Material_02", 1)
    h.env.PBZ.game.takeRemotePickup("matE", "?", h.pawn, nil, nil)
    s:run(25)
    check(Session.items(h, "Weapon_Material_02") - hE == 1 and Session.items(g, "Weapon_Material_02") - gE == 1,
        string.format("both take one pickup in a moment, the word before this world's look: one each, %d and %d",
            Session.items(h, "Weapon_Material_02") - hE, Session.items(g, "Weapon_Material_02") - gE))
    -- What a partner took is this save's alone: another save loaded in the same game has that pickup as its own.
    local keep = h.env.PBZ.game.saveSlot
    h.env.PBZ.game.saveSlot = "AnotherSave"
    local other = Fake.pickup(h, "matB", "Weapon_Material_02", 250.0, -100.0, 100.0)
    s:run(3)
    check(rawget(other, "__alive") ~= false, "another save's pickup of the same name isn't taken for one the partner took")
    h.env.PBZ.game.saveSlot = keep
    -- A partner's note: its card waits in the game's display list for the game's own pickup, and the bag says a card is up
    -- with nothing on screen, so the line of their next find waited too, till this player picked something up (a player
    -- report on 1.7.1, three players; the bench, 11-12). Not put up in a fight: there it waits, the line with it. Out of
    -- the fight (the game counts the host out of it) it goes up the game's way, and the line once it's closed.
    local pushes, cards = count(h.trace, "TryToPushPickupUI"), #h.cards
    h.inCombat = 1
    Session.gainItem(g, "R_77", 1)
    Session.gainItem(g, "Weapon_Material_01", 1)
    s:run(6)
    check(#h.cards == cards and count(h.trace, "TryToPushPickupUI") == pushes and Session.items(h, "R_77") == 1,
        string.format("in a fight a note's card waits, the line after it with it: %d cards, %d shown, %d notes",
            #h.cards - cards, count(h.trace, "TryToPushPickupUI") - pushes, Session.items(h, "R_77")))
    h.inCombat = 0
    s:run(4)
    local up = #h.cards == cards + 1 and h.cards[#h.cards] == "R_77" and h.cardUp == true
    h.closeCard()                   -- (Space)
    s:run(1)
    check(up and h.tips[#h.tips] == "Weapon_Material_01 + 1",
        string.format("out of the fight the note's card goes up, with no find of the host's own, and the line once it's "
            .. "closed: %d cards, last line %s", #h.cards - cards, tostring(h.tips[#h.tips])))
    -- A scene holds a card the same way, and its line: shown a moment after it ends. (Longer than the 12 s a share waits out
    -- a scene, coop.lua's takeGifts: the card is in the bag by then, and only game.calmForCard holds it. In a scene of 5 s
    -- the share itself waited, and the scene's own test was never asked: a review of 18d340e.)
    cards, tips = #h.cards, #h.tips
    Session.scene(h, true)
    Session.gainItem(g, "I_KEY_9", 1)
    Session.gainItem(g, "Weapon_Material_01", 2)
    s:run(20)
    local inScene, inBag = #h.cards - cards + #h.tips - tips, Session.items(h, "I_KEY_9")
    Session.scene(h, false)
    s:run(4)
    local upAfter = #h.cards == cards + 1 and h.cardUp == true
    h.closeCard()
    s:run(1)
    check(inBag == 1 and inScene == 0 and upAfter and #h.tips == tips + 1,
        string.format("a quest item's card waits out a scene with its line, then both show: %d in the bag, %d in it, %d cards "
            .. "and %d lines after", inBag, inScene, #h.cards - cards, #h.tips - tips))
    -- One a fight held when a scene began, the fight over in it: it waits out the scene all the same.
    cards = #h.cards
    h.inCombat = 1
    Session.gainItem(g, "R_78", 1)
    s:run(5)
    Session.scene(h, true)
    h.inCombat = 0
    s:run(8)
    local inIt = #h.cards - cards
    Session.scene(h, false)
    s:run(4)
    check(inIt == 0 and #h.cards == cards + 1 and h.cardUp == true,
        string.format("a card a fight held, a scene begun and the fight over in it: it waits out the scene, %d in it, %d after",
            inIt, #h.cards - cards))
    h.closeCard()
    s:run(1)
    -- Two cards of a partner's: the first goes up, and while it's open (read a while) nothing is put up over it; the game
    -- puts the next up itself once it's closed, then the line. (A review of 18d340e: both calls ran again every few seconds
    -- over the first, still open, what the game does then unknown.)
    cards, tips = #h.cards, #h.tips
    local over = h.overCard
    Session.gainItem(g, "R_79", 1)
    Session.gainItem(g, "I_RELIC_5", 1)
    Session.gainItem(g, "Weapon_Material_01", 1)
    s:run(8)
    local firstUp = #h.cards == cards + 1 and h.cardUp == true
    s:run(15)
    local stillOne = #h.cards == cards + 1
    h.closeCard()
    s:run(1)
    local secondUp = #h.cards == cards + 2 and h.cardUp == true
    h.closeCard()
    s:run(2)
    check(firstUp and stillOne and secondUp and h.overCard == over and #h.tips == tips + 1,
        string.format("two cards of a partner's: the first up, nothing over it while it's open (%d calls), the second after it, "
            .. "then the line: %d cards, %d lines", h.overCard - over, #h.cards - cards, #h.tips - tips))
    -- Being hit, a montage of the host's own (a swing, a pickup's) or a game screen up: a card waits, then goes up.
    local function heldBy(what, on, off, secs)
        local before = #h.cards
        Session.gainItem(g, "R_" .. (80 + #h.cards), 1)
        on()
        s:run(secs or 8)
        local held = #h.cards - before
        off()
        s:run(5)
        check(held == 0 and #h.cards == before + 1 and h.cardUp == true,
            string.format("%s, a card waits, then goes up: %d while, %d after", what, held, #h.cards - before))
        h.closeCard()
        s:run(1)
    end
    local hp = select(1, Fake.health(h.pawn))
    heldBy("while the host is being hit", function()
        for i = 1, 8 do
            Fake.setHealth(h.pawn, hp - 5 * i)
            s:run(1)
        end
    end, function() end, 0.1)
    heldBy("while a montage of the host's own plays", function()
        Session.startMove(h, "/PBZCombatAsset/ActorData/Move/A1.A1")
    end, function() Session.endMove(h) end)
    local page
    heldBy("while a game screen is up", function()
        page = Fake.screen(h, "W_SystemMenu_C")
    end, function()
        for i = #h.screens, 1, -1 do
            if h.screens[i] == page then
                table.remove(h.screens, i)
            end
        end
    end)
    -- (Not a pause: linked, coop.lua's noPause lets none last. Nor a boss fight or a talk: nothing here makes either.)
    -- On a guest the game counts no fight with the host's copies, whose minds the host runs: a live enemy of the host's near
    -- holds a card the same way, till the guest is away from it.
    local gcards = #g.cards
    Session.moveTo(g, 1500, 450)            -- (beside the host's thug)
    s:run(3)
    Session.gainItem(h, "I_RELIC_2", 1)
    s:run(8)
    local nearEnemy = #g.cards - gcards
    Session.moveTo(g, -6000, 0)
    s:run(5)
    check(nearEnemy == 0 and #g.cards == gcards + 1 and g.cardUp == true,
        string.format("a guest beside the host's enemy: the host's find's card waits, then goes up away from it: %d near, %d after",
            nearEnemy, #g.cards - gcards))
    g.closeCard()
    allErrors(s)

    -- A party of three: two guests take the same pickup in a moment. The host, who took nothing, gets one: the second word
    -- finds it gone here already, and the second share is "two players got it" (the review of 11-09: the host got two).
    local p3 = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    p3:run(4)
    local ph, pa, pb = p3.pcs[1], p3.pcs[2], p3.pcs[3]
    Session.moveTo(ph, 250, 0)
    Session.moveTo(pa, 250, 150)
    Session.moveTo(pb, 250, -150)
    p3:run(3)
    for _, pc in ipairs(p3.pcs) do
        Fake.pickup(pc, "herbP", "Weapon_Material_02", 600.0, 0.0, 100.0)
    end
    Session.moveTo(ph, -2500, 0)
    p3:run(4)
    local ph0 = Session.items(ph, "Weapon_Material_02")
    Fake.put(pickupOn(pa, "herbP"), "bIsPickable", false)
    Session.gainItem(pa, "Weapon_Material_02", 1)
    Fake.put(pickupOn(pb, "herbP"), "bIsPickable", false)
    Session.gainItem(pb, "Weapon_Material_02", 1)
    p3:run(40)
    check(Session.items(ph, "Weapon_Material_02") - ph0 == 1,
        "two guests take one pickup in a moment: the host gets one: " .. Session.items(ph, "Weapon_Material_02") - ph0)
    allErrors(p3)
end

-- The second review of the pickups (11-09/10), each as it was found: a kill's reward and a pickup of the same thing a moment
-- apart (the reward's share took the pickup's wait, the pickup's came on top); a pickup whose copy the host hadn't loaded
-- (its share dropped as "given here too", the copy gone as it loaded: nothing at all); one's own take told by the partner's
-- word before this world's look (taken for a copy not loaded, the share came as a second); and in a party, the second
-- guest's take never told, a pickup back in one guest's world taken for a second guest's, two guests' finds a moment apart.
local function pickupsRaced()
    part("pickups in a race")
    local M, M1 = "Weapon_Material_02", "Weapon_Material_01"
    local function pickupOn(pc, id)
        for i = #pc.pickups, 1, -1 do
            if rawget(pc.pickups[i], "__name") == id then
                return pc.pickups[i]
            end
        end
    end
    local function take(pc, id, item)
        pickupOn(pc, id):K2_DestroyActor()
        Session.gainItem(pc, item or M, 1)
    end

    -- A kill's reward of 2 in both worlds, then the host's pickup of 1: 3 each.
    local s, h, g = pair()
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 250, -150)
    Fake.pickup(h, "matK", M, 250.0, 0.0, 100.0)
    Fake.pickup(g, "matK", M, 250.0, 0.0, 100.0)
    s:run(3)
    local h0, g0 = Session.items(h, M), Session.items(g, M)
    Session.gainItem(h, M, 2)
    s:run(0.3)
    Session.gainItem(g, M, 2)
    s:run(1.2)
    take(h, "matK")
    s:run(40)
    check(Session.items(h, M) - h0 == 3 and Session.items(g, M) - g0 == 3,
        string.format("a kill's reward of 2 in both worlds, then a pickup of 1 of the same thing: 3 each, %d and %d",
            Session.items(h, M) - h0, Session.items(g, M) - g0))
    allErrors(s)

    -- The guest's pickup far off, the host's copy not loaded, a kill's reward of the same thing just before: 2 at the host,
    -- its copy gone as it loads.
    s, h, g = pair()
    Session.moveTo(g, 3000, 150)
    Fake.pickup(g, "farZ", M, 3000.0, 0.0, 100.0)
    s:run(3)
    h0 = Session.items(h, M)
    Session.gainItem(h, M, 1)
    s:run(0.4)
    Session.gainItem(g, M, 1)
    s:run(1.5)
    take(g, "farZ")
    s:run(10)
    local late = Fake.pickup(h, "farZ", M, 3000.0, 0.0, 100.0)
    Session.moveTo(h, 3000, -150)
    s:run(4)
    check(Session.items(h, M) - h0 == 2 and rawget(late, "__alive") == false,
        "a pickup the host hadn't loaded, a reward of the same thing just before: 2 at the host, its copy gone as it loads: "
        .. Session.items(h, M) - h0)
    allErrors(s)

    -- Both take one pickup, the guest's copy gone with its own take, the host's word here before the guest's next look:
    -- one each.
    s, h, g = pair()
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 250, -150)
    Fake.pickup(h, "matF", M, 250.0, 0.0, 100.0)
    Fake.pickup(g, "matF", M, 250.0, 0.0, 100.0)
    s:run(3)
    h0, g0 = Session.items(h, M), Session.items(g, M)
    take(h, "matF")
    take(g, "matF")
    g.env.PBZ.game.takeRemotePickup("matF", "?", g.pawn, nil, nil, nil, M, 1)    -- (the host's word, before the look)
    s:run(40)
    check(Session.items(h, M) - h0 == 1 and Session.items(g, M) - g0 == 1 and count(g.logs, "too; you already") >= 1,
        string.format("both take one pickup, the word before this world's look, its copy gone: one each, %d and %d",
            Session.items(h, M) - h0, Session.items(g, M) - g0))
    allErrors(s)

    -- A party: two guests take one pickup, the second's copy found taken at the first's word before its own look. That
    -- look still tells it, and the host gets one. (Untold, the second's share came as a thing of its own: two.)
    local p3 = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    p3:run(4)
    local ph, pa, pb = p3.pcs[1], p3.pcs[2], p3.pcs[3]
    Session.moveTo(ph, 250, 0)
    Session.moveTo(pa, 250, 150)
    Session.moveTo(pb, 250, -150)
    p3:run(3)
    for _, pc in ipairs(p3.pcs) do
        Fake.pickup(pc, "herbQ", M, 600.0, 0.0, 100.0)
    end
    Session.moveTo(ph, -2500, 0)
    p3:run(4)
    local ph0 = Session.items(ph, M)
    Fake.put(pickupOn(pa, "herbQ"), "bIsPickable", false)
    Session.gainItem(pa, M, 1)
    Fake.put(pickupOn(pb, "herbQ"), "bIsPickable", false)
    Session.gainItem(pb, M, 1)
    pb.env.PBZ.game.takeRemotePickup("herbQ", "?", pb.pawn, nil, nil)          -- (A's word, before B's look)
    p3:run(40)
    check(Session.items(ph, M) - ph0 == 1 and count(pb.sent, "^E I herbQ") == 1,
        "two guests take one pickup, the second's look after the first's word: still told, the host gets one: "
        .. Session.items(ph, M) - ph0)

    -- One guest takes a pickup, and the same one again once it's back in their world: the host gets both. (Taken for a
    -- second guest's word on one gone, its share was dropped as the same thing.)
    Session.moveTo(pb, -6000, 0)
    Fake.pickup(ph, "herbR", M1, 600.0, 0.0, 100.0)
    Fake.pickup(pa, "herbR", M1, 600.0, 0.0, 100.0)
    p3:run(4)
    ph0 = Session.items(ph, M1)
    Session.moveTo(pa, 600, 150)
    p3:run(2)
    Fake.put(pickupOn(pa, "herbR"), "bIsPickable", false)
    Session.gainItem(pa, M1, 1)
    p3:run(40)
    Fake.pickup(pa, "herbR", M1, 600.0, 0.0, 100.0)
    p3:run(3)
    Fake.put(pickupOn(pa, "herbR"), "bIsPickable", false)
    Session.gainItem(pa, M1, 1)
    p3:run(25)
    check(Session.items(ph, M1) - ph0 == 2,
        "a pickup back in one guest's world, taken again: the host gets both: " .. Session.items(ph, M1) - ph0)
    allErrors(p3)

    -- Two guests far apart each take a pickup of the same thing, 4 s apart, neither loaded at the host: the host gets both,
    -- and its copies go as they load.
    local q = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    q:run(4)
    local qh, qa, qb = q.pcs[1], q.pcs[2], q.pcs[3]
    Session.moveTo(qh, 0, 0)
    Session.moveTo(qa, 6000, 150)
    Session.moveTo(qb, -6000, 150)
    q:run(3)
    Fake.pickup(qa, "herbA", M, 6000.0, 0.0, 100.0)
    Fake.pickup(qb, "herbB", M, -6000.0, 0.0, 100.0)
    q:run(3)
    local q0 = Session.items(qh, M)
    take(qa, "herbA")
    q:run(4)
    take(qb, "herbB")
    q:run(30)
    local lateA = Fake.pickup(qh, "herbA", M, 6000.0, 0.0, 100.0)
    local lateB = Fake.pickup(qh, "herbB", M, -6000.0, 0.0, 100.0)
    q:run(4)
    check(Session.items(qh, M) - q0 == 2 and rawget(lateA, "__alive") == false and rawget(lateB, "__alive") == false,
        "two guests' pickups of one thing 4 s apart, not loaded at the host: it gets both, its copies gone: "
        .. Session.items(qh, M) - q0)
    allErrors(q)

    -- The third review (11-10). Each player's pickup looks, as they run: what's done right after one comes before the next.
    local function looks(pc)
        local g = pc.env.PBZ.game
        local watch = g.watchPickups
        pc.looks = {}
        g.watchPickups = function(...)
            local r = watch(...)
            if r ~= false then
                pc.looks[#pc.looks + 1] = pc.now
            end
            return r
        end
    end
    local function untilLook(s, pc)
        local n = #pc.looks
        for _ = 1, 600 do
            if #pc.looks > n then
                return
            end
            s:run(1 / 60)
        end
    end

    -- A kill's reward of 2 between the guest's pickup of 1 and its next look: its word says 2. The host, with a find of its
    -- own of the same thing 5 s before, gets every event once: 4 each. (The pickup's share was dropped as that find's, the
    -- reward's given in its place: 5.)
    s, h, g = pair()
    looks(g)
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 1250, -150)
    for _, pc in ipairs({ h, g }) do
        Fake.pickup(pc, "herbQ5", M, 250.0, 0.0, 100.0)
        Fake.pickup(pc, "herbP5", M, 1250.0, 0.0, 100.0)
    end
    s:run(3)
    h0, g0 = Session.items(h, M), Session.items(g, M)
    take(h, "herbQ5")
    s:run(5)
    untilLook(s, g)
    take(g, "herbP5")
    s:run(0.1)
    Session.gainItem(h, M, 2)
    s:run(0.2)
    Session.gainItem(g, M, 2)
    s:run(40)
    check(count(g.sent, "^E I herbP5 %? %- Weapon_Material_02 2$") == 1 and Session.items(h, M) - h0 == 4 and Session.items(g, M) - g0 == 4,
        string.format("a kill's reward between the guest's pickup and its look, its word saying the reward's 2: 4 each, %d and %d",
            Session.items(h, M) - h0, Session.items(g, M) - g0))
    allErrors(s)

    -- A party: guest B's own find of 2 of the same thing, then A and B take one pickup together. The host gets the pickup
    -- once and B's find: 3. (The note for B's second word, by item alone, took B's find: 2.)
    local d = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    d:run(4)
    local dh, da, db = d.pcs[1], d.pcs[2], d.pcs[3]
    Session.moveTo(dh, -350, 0)
    Session.moveTo(da, 250, 150)
    Session.moveTo(db, 250, -150)
    d:run(3)
    for _, pc in ipairs(d.pcs) do
        Fake.pickup(pc, "herbD", M, 250.0, 0.0, 100.0)
    end
    d:run(3)
    local d0 = Session.items(dh, M)
    Session.gainItem(db, M, 2)              -- (B's own chest: only B's world gives it)
    d:run(0.4)
    take(da, "herbD")
    take(db, "herbD")
    d:run(40)
    check(Session.items(dh, M) - d0 == 3,
        "a party: B's own find of 2, then A and B take one pickup: the host gets 3: " .. Session.items(dh, M) - d0)
    allErrors(d)

    -- The guest's word before the host's first look as it loads in (the look reads the save's name, which what's gone goes
    -- by): the host's copy, made again later, goes again. (Filed under no save, it was there to take again.)
    local v = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    for _, pc in ipairs(v.pcs) do
        local find = pc.env.FindFirstOf
        local saves = { GetContinueSlotName = function() return { ToString = function() return "Slot1" end } end,
            IsValid = function() return true end }
        pc.env.FindFirstOf = function(class)
            if class == "PBZSaveLoadSubsystem" then
                return saves
            end
            return find(class)
        end
    end
    local vh, vg = v.pcs[1], v.pcs[2]
    vh.env.PBZ.net.quietUntil = vh.now + 25
    v:run(5)
    Session.moveTo(vh, 250, 150)
    Session.moveTo(vg, 250, -150)
    Fake.pickup(vh, "herbS", M, 250.0, 0.0, 100.0)
    Fake.pickup(vg, "herbS", M, 250.0, 0.0, 100.0)
    v:run(9)
    local v0 = Session.items(vh, M)
    take(vg, "herbS")
    v:run(16)
    Session.moveTo(vh, 30000, 150)
    v:run(5)
    local again2 = Fake.pickup(vh, "herbS", M, 250.0, 0.0, 100.0)
    Session.moveTo(vh, 250, 150)
    v:run(5)
    check(rawget(again2, "__alive") == false and Session.items(vh, M) - v0 == 1 and vh.env.PBZ.game.saveSlot == "Slot1",
        "the guest's word before the host's first look: the host's copy made again later goes again, one each: "
        .. Session.items(vh, M) - v0)
    allErrors(v)

    -- One player runs up to a pickup from out of the look's reach and takes it in the moment the other takes theirs, the
    -- word here before this world's next look: one each. (Taken for a copy not loaded, the share came as a second.)
    s, h, g = pair()
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 870, 0)
    Fake.pickup(h, "herbR6", M, 250.0, 0.0, 100.0)
    Fake.pickup(g, "herbR6", M, 250.0, 0.0, 100.0)
    s:run(3)
    h0, g0 = Session.items(h, M), Session.items(g, M)
    take(h, "herbR6")
    g.env.PBZ.net.quietUntil = g.now + 4    -- (its looks wait a moment, as after a hitch: the word comes first)
    Session.moveTo(g, 260, -100)
    take(g, "herbR6")
    s:run(40)
    check(Session.items(h, M) - h0 == 1 and Session.items(g, M) - g0 == 1,
        string.format("a run from out of the look's reach to a pickup the other takes too: one each, %d and %d",
            Session.items(h, M) - h0, Session.items(g, M) - g0))
    allErrors(s)

    -- Shares of other things piled up, then the guest's own find of a thing and its pickup of the same: the host's copy goes
    -- at the word, 2 each, no script error. (Old ones taken off under the one found, its place pointed past the list: the
    -- word stopped before the copy went, 3 each.)
    s, h, g = pair()
    Session.moveTo(h, 250, 150)
    Session.moveTo(g, 250, -150)
    Fake.pickup(h, "matG", M, 250.0, 0.0, 100.0)
    Fake.pickup(g, "matG", M, 250.0, 0.0, 100.0)
    s:run(3)
    h0, g0 = Session.items(h, M), Session.items(g, M)
    Session.gainItem(g, "R_500", 1)
    s:run(0.4)
    Session.gainItem(g, M1, 1)
    s:run(20)
    Session.gainItem(g, M, 1)
    s:run(5)
    take(g, "matG")
    s:run(25)
    check(Session.items(h, M) - h0 == 2 and Session.items(g, M) - g0 == 2 and rawget(pickupOn(h, "matG"), "__alive") == false,
        string.format("other shares piled up, then a find and a pickup of one thing: 2 each, the host's copy gone: %d and %d",
            Session.items(h, M) - h0, Session.items(g, M) - g0))
    allErrors(s)
end

local function pickupCardRecovery()
    part("online pickup card recovery")
    local s, h, g = pair()
    local pipa, flag = "I_02001", "jl.弄蛇.破损琵琶"
    Session.gainItem(g, pipa, 1)
    s:run(9)
    check(Session.items(h, pipa) == 1 and #h.cards == 0 and #h.cardsHeld == 0
        and table.concat(h.globalTags, "\n"):find(flag, 1, true),
        "sharing the broken pipa gives its item and flag without queuing a card")
    Session.gainItem(h, pipa, 1)
    s:run(2)
    check(Session.items(h, pipa) == 1 and #h.cards == 1 and h.cards[1] == pipa,
        "the host's own pickup still shows the pipa card and the item stays at one")

    local function show(pc, showing, focused, recoverFocus)
        local result = { visible = true, attached = true, rearmed = 0, closed = 0 }
        local button = Fake.object(pc, "ConfirmButton")
        local parent = Fake.object(pc, "PickupLayer", { IsVisible = function() return result.attached end })
        local w = Fake.object(pc, "W_pickupgear_C", {
            CurrentFocusButton = focused and button or false,
            IsVisible = function() return result.visible end,
            IsActivated = function() return focused == true end,
            IsInViewport = function() return false end,
            GetParent = function() return parent end,
            ClickBackKey = function()
                result.closed = result.closed + 1
                result.visible = false
            end,
        })
        Fake.put(pc.bag, "bShowPickItemWidget", showing)
        Fake.put(pc.bag, "ReadyToPlayConfirmUI", function()
            result.rearmed = result.rearmed + 1
            if recoverFocus then
                Fake.put(w, "CurrentFocusButton", button)
            end
        end)
        local find = pc.env.FindAllOf
        pc.env.FindAllOf = function(class)
            if class == "W_pickupgear_C" then
                return { w }
            end
            return find(class)
        end
        return result
    end

    local normal = show(h, true, true)
    local restored = show(g, true, false, true)
    s:run(9)
    check(normal.closed == 0 and normal.rearmed == 0, "a card with a confirm button stays open")
    check(restored.rearmed == 1 and restored.closed == 0, "the guest's restored button keeps the card open")

    local stuck = show(h, true, false)
    local unfocused = show(g, false, false)
    Session.scene(h, true, "PickupScene")
    s:run(8)
    check(stuck.closed == 0 and stuck.rearmed == 0, "no card recovery during a scene")
    check(unfocused.visible and unfocused.closed == 0 and unfocused.rearmed == 0,
        "a visible card without reported focus or backpack ownership stays open for manual confirmation")
    Session.scene(h, false)
    s:run(2)
    check(stuck.closed == 0 and stuck.rearmed == 0, "the host's missing button gets time to appear after the scene")
    s:run(9)
    check(stuck.rearmed == 1 and stuck.visible and stuck.closed == 0,
        "a retry that fails to restore the confirm button still leaves the card open")

    local inactive = show(g, false, false)
    inactive.attached = false
    local open = show(h, false, true)
    Session.gainItem(g, "R_77", 1)
    s:run(9)
    check(h.cardsHeld[1] == "R_77" and open.rearmed == 0, "a shared note waits behind a visible card even if the bag is free")
    check(inactive.closed == 0, "an inactive card in a hidden container is left alone")

    local offline = show(h, false, false)
    Session.command(h, "netoff")
    s:run(6)
    check(offline.closed == 0, "recovery stops when online synchronization is off")
    allErrors(s)
end

-- A story item is one of a kind (the game's NarrativeItem: a key, the Twin Flesh Lily): everyone gets it once, whoever takes
-- it and however it comes. A player's report on 1.7.1, three players: "story items still duplicate (twin flesh lilies for
-- example, I have 2)". A copy in a world the taker's word doesn't find (made there under another name, or made again in
-- another session) was there to take: its taker had two, and their share gave everyone a second.
local function storyOnce()
    part("a story item, once each")
    local FLOWER, RELIC = "I_KEY_9", "I_RELIC_1"
    local function pickupOn(pc, id)
        for i = #pc.pickups, 1, -1 do
            if rawget(pc.pickups[i], "__name") == id then
                return pc.pickups[i]
            end
        end
    end
    local p3 = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, 3, ENEMIES)
    p3:run(4)
    local h, a, b = p3.pcs[1], p3.pcs[2], p3.pcs[3]
    Session.moveTo(h, 250, 0)
    Session.moveTo(a, 250, 150)
    Session.moveTo(b, 250, -150)
    p3:run(3)
    Fake.pickup(h, "flowerT", FLOWER, 600.0, 0.0, 100.0)
    Fake.pickup(a, "flowerT", FLOWER, 600.0, 0.0, 100.0)
    Fake.pickup(b, "flowerT_2147466001", FLOWER, 600.0, 0.0, 100.0)     -- (B's world made its own under another name)
    p3:run(3)
    pickupOn(a, "flowerT"):K2_DestroyActor()
    Session.gainItem(a, FLOWER, 1)
    p3:run(25)
    local first = string.format("%d %d %d", Session.items(h, FLOWER), Session.items(a, FLOWER), Session.items(b, FLOWER))
    -- The host hands theirs in (Yuer takes the flower). Then B's own copy, still there, taken: their game gives B a second of
    -- the same thing.
    h.bag:RemovePropsFromBackPack(1, h.env.FName(FLOWER))
    pickupOn(b, "flowerT_2147466001"):K2_DestroyActor()
    Session.gainItem(b, FLOWER, 1)
    p3:run(40)
    check(first == "1 1 1" and Session.items(h, FLOWER) == 0 and Session.items(a, FLOWER) == 1 and Session.items(b, FLOWER) == 1,
        string.format("a story item A took, then B's own copy B's world kept: one each, the host's handed in stays so; after A's "
            .. "%s, after B's %d %d %d", first, Session.items(h, FLOWER), Session.items(a, FLOWER), Session.items(b, FLOWER)))
    check(count(b.sent, "^E T " .. FLOWER) == 0 and count(b.logs, "story item this player had already") == 1,
        "and B's second wasn't sent: everyone had theirs")
    allErrors(p3)

    -- Two players: the guest's own copy of a story item the host's share gave them, taken later: one each.
    local s, hh, g = pair()
    Session.moveTo(hh, 250, 150)
    Session.moveTo(g, 250, -150)
    Fake.pickup(hh, "relicT", RELIC, 250.0, 0.0, 100.0)
    Fake.pickup(g, "relicT_2147466002", RELIC, 250.0, 0.0, 100.0)
    s:run(3)
    pickupOn(hh, "relicT"):K2_DestroyActor()
    Session.gainItem(hh, RELIC, 1)
    s:run(25)
    pickupOn(g, "relicT_2147466002"):K2_DestroyActor()
    Session.gainItem(g, RELIC, 1)
    s:run(40)
    check(Session.items(hh, RELIC) == 1 and Session.items(g, RELIC) == 1,
        string.format("two players: the guest's own copy of a story item the host's share gave them: one each, %d and %d",
            Session.items(hh, RELIC), Session.items(g, RELIC)))
    -- One made of several (the dragon token, IntegrationItemNum 2): not one of a kind, held as many times as found.
    local PIECE = "K_TOKEN_9"
    for _, pc in ipairs({ hh, g }) do
        Fake.pickup(pc, "stringA", PIECE, 400.0, 0.0, 100.0)
        Fake.pickup(pc, "stringB", PIECE, 400.0, 100.0, 100.0)
    end
    s:run(3)
    pickupOn(hh, "stringA"):K2_DestroyActor()
    Session.gainItem(hh, PIECE, 1)
    s:run(25)
    pickupOn(g, "stringB"):K2_DestroyActor()
    Session.gainItem(g, PIECE, 1)
    s:run(25)
    check(Session.items(hh, PIECE) == 2 and Session.items(g, PIECE) == 2,
        string.format("a story item made of several: two found, two each, %d and %d", Session.items(hh, PIECE),
            Session.items(g, PIECE)))
    -- The guest, who has a story item already, takes their world's copy (kept to one, nothing sent), and their word takes the
    -- host's copy: the host, who had none, gets it from that copy. (Dropped, they had none for the session.)
    g.bag:AddPropsToBackPack(1, g.env.FName("I_RELIC_2"), false)        -- (the guest's, from before)
    for _, pc in ipairs({ hh, g }) do
        Fake.pickup(pc, "relicU", "I_RELIC_2", 330.0, 60.0, 100.0)
    end
    s:run(3)
    pickupOn(g, "relicU"):K2_DestroyActor()
    Session.gainItem(g, "I_RELIC_2", 1)
    s:run(25)
    check(Session.items(hh, "I_RELIC_2") == 1 and Session.items(g, "I_RELIC_2") == 1 and count(g.sent, "^E T I_RELIC_2") == 0,
        string.format("one who had a story item takes their copy again, the word takes the host's: the host gets it from it, "
            .. "%d and %d", Session.items(hh, "I_RELIC_2"), Session.items(g, "I_RELIC_2")))
    allErrors(s)

    -- The same with the host's copy not loaded at the word (a review of 18d340e: the host had none for the session, their
    -- copy gone as it loaded; the bag on joining goes host to guest only, so a guest can hold what the host lacks): given
    -- as it goes, loaded 25 s on, or in the wait, once the wait is out.
    do
        local s2, h2, g2 = pair()
        local X, Y = "I_RELIC_3", "I_RELIC_4"
        g2.bag:AddPropsToBackPack(1, g2.env.FName(X), false)        -- (the guest's, another host's share once)
        Fake.pickup(g2, "relicW", X, 560.0, 60.0, 100.0)
        s2:run(3)
        pickupOn(g2, "relicW"):K2_DestroyActor()
        Session.gainItem(g2, X, 1)
        s2:run(25)
        local before = Session.items(h2, X)
        local late = Fake.pickup(h2, "relicW", X, 60.0, 60.0, 100.0)
        s2:run(4)
        check(before == 0 and Session.items(h2, X) == 1 and Session.items(g2, X) == 1 and rawget(late, "__alive") == false
            and count(g2.sent, "^E T " .. X) == 0,
            string.format("the guest, who has a story item, takes their copy; the host's, loaded 25 s on, gives it to the host as "
                .. "it goes: %d then %d, the guest %d", before, Session.items(h2, X), Session.items(g2, X)))
        g2.bag:AddPropsToBackPack(1, g2.env.FName(Y), false)
        Fake.pickup(g2, "relicY", Y, 560.0, -60.0, 100.0)
        s2:run(3)
        pickupOn(g2, "relicY"):K2_DestroyActor()
        Session.gainItem(g2, Y, 1)
        s2:run(8)
        local mid = Fake.pickup(h2, "relicY", Y, 60.0, -60.0, 100.0)
        s2:run(20)
        check(Session.items(h2, Y) == 1 and rawget(mid, "__alive") == false,
            "and the host's copy loaded in the wait: gone, and given from once the wait is out: " .. Session.items(h2, Y))
        allErrors(s2)
    end

    -- A pile (Yuer's herbs lie in piles): the guest, who has its thing, searches theirs. The host's goes with the word and gives
    -- it once the wait is out; one not loaded then, as it loads.
    do
        local s3, h3, g3 = pair()
        local function pileOf(pc, name, item, x)
            local p = Fake.pile(pc, name, x, 0.0, 100.0, {})
            Fake.put(p, "Item ID", Fake.name("XiGu." .. item))
            return p
        end
        g3.bag:AddPropsToBackPack(1, g3.env.FName("I_RELIC_1"), false)
        local hp = pileOf(h3, "BP_Rubbish_C_UAID_herbs1", "I_RELIC_1", 300.0)
        local gp = pileOf(g3, "BP_Rubbish_C_UAID_herbs1", "I_RELIC_1", 600.0)
        s3:run(3)
        Fake.search(g3, gp)
        Session.gainItem(g3, "I_RELIC_1", 1)
        s3:run(25)
        check(Session.items(h3, "I_RELIC_1") == 1 and Session.items(g3, "I_RELIC_1") == 1 and rawget(hp, "__alive") == false
            and count(g3.sent, "^E T I_RELIC_1") == 0,
            string.format("a pile of a story item the guest has, searched: the host's goes and gives it, %d and %d",
                Session.items(h3, "I_RELIC_1"), Session.items(g3, "I_RELIC_1")))
        g3.bag:AddPropsToBackPack(1, g3.env.FName("I_RELIC_2"), false)
        local gp2 = pileOf(g3, "BP_Rubbish_C_UAID_herbs2", "I_RELIC_2", 620.0)
        s3:run(3)
        Fake.search(g3, gp2)
        Session.gainItem(g3, "I_RELIC_2", 1)
        s3:run(20)
        local before = Session.items(h3, "I_RELIC_2")
        local hp2 = pileOf(h3, "BP_Rubbish_C_UAID_herbs2", "I_RELIC_2", 320.0)
        s3:run(22)
        check(before == 0 and Session.items(h3, "I_RELIC_2") == 1 and rawget(hp2, "__alive") == false,
            string.format("and one not loaded on the host at the search: it goes as it loads and gives it, %d then %d", before,
                Session.items(h3, "I_RELIC_2")))
        allErrors(s3)
    end

    -- One the host had and handed in stays handed in. Their first came by the guest's share, their copy not loaded then:
    -- gone as it loads, nothing again. A later copy of the guest's, taken with the thing held (kept to one, nothing sent), its
    -- word taking the host's loaded copy: nothing, the host has had it. And a share to one who has the thing: not a second.
    do
        local s4, h4, g4 = pair()
        local Z = "I_RELIC_1"
        Fake.pickup(g4, "relicZ", Z, 560.0, 60.0, 100.0)
        s4:run(3)
        pickupOn(g4, "relicZ"):K2_DestroyActor()
        Session.gainItem(g4, Z, 1)
        s4:run(25)
        local first = Session.items(h4, Z)
        h4.bag:RemovePropsFromBackPack(1, h4.env.FName(Z))          -- (handed in)
        local late = Fake.pickup(h4, "relicZ", Z, 60.0, 60.0, 100.0)
        s4:run(4)
        Fake.pickup(g4, "relicZ2", Z, 560.0, -60.0, 100.0)
        local loaded = Fake.pickup(h4, "relicZ2", Z, 60.0, -60.0, 100.0)
        s4:run(3)
        pickupOn(g4, "relicZ2"):K2_DestroyActor()
        Session.gainItem(g4, Z, 1)
        s4:run(25)
        check(first == 1 and Session.items(h4, Z) == 0 and Session.items(g4, Z) == 1 and rawget(late, "__alive") == false
            and rawget(loaded, "__alive") == false,
            string.format("a story item the host had and handed in stays so: its copy loaded later gone, and the guest's take of "
                .. "another copy, theirs held, gives nothing from the host's: %d then %d", first, Session.items(h4, Z)))
        h4.bag:AddPropsToBackPack(1, h4.env.FName("I_RELIC_2"), false)
        Fake.pickup(g4, "relicH", "I_RELIC_2", 560.0, 30.0, 100.0)
        s4:run(3)
        pickupOn(g4, "relicH"):K2_DestroyActor()
        Session.gainItem(g4, "I_RELIC_2", 1)
        s4:run(20)
        check(Session.items(h4, "I_RELIC_2") == 1 and Session.items(g4, "I_RELIC_2") == 1
            and count(g4.sent, "^E T I_RELIC_2") == 1 and count(h4.logs, "I_RELIC_2 is a story item this player has already") >= 1,
            string.format("the guest's first of a story item the host has: its share isn't a second, %d and %d",
                Session.items(h4, "I_RELIC_2"), Session.items(g4, "I_RELIC_2")))
        -- One held from the save (another session's share), never given this run, then handed in: not given back from a copy
        -- either (a review of this fix: only what came this run counted).
        h4.bag:AddPropsToBackPack(1, h4.env.FName("I_RELIC_3"), false)
        g4.bag:AddPropsToBackPack(1, g4.env.FName("I_RELIC_3"), false)
        s4:run(6)
        h4.bag:RemovePropsFromBackPack(1, h4.env.FName("I_RELIC_3"))     -- (handed in)
        Fake.pickup(g4, "relicS", "I_RELIC_3", 560.0, 90.0, 100.0)
        local saved = Fake.pickup(h4, "relicS", "I_RELIC_3", 60.0, 90.0, 100.0)
        s4:run(3)
        pickupOn(g4, "relicS"):K2_DestroyActor()
        Session.gainItem(g4, "I_RELIC_3", 1)
        s4:run(22)
        check(Session.items(h4, "I_RELIC_3") == 0 and Session.items(g4, "I_RELIC_3") == 1 and rawget(saved, "__alive") == false,
            "one held from the save and handed in isn't given back from a copy either: " .. Session.items(h4, "I_RELIC_3"))
        -- Co-op off, the bag hook still there for the game's run: the bag is the game's, a second isn't taken back.
        net(g4).enabled = false
        Session.gainItem(g4, "I_RELIC_2", 1)
        s4:run(2)
        local alone = Session.items(g4, "I_RELIC_2")
        net(g4).enabled = true
        check(alone == 2, "with co-op off the game's second of a story item stays: the bag is the game's: " .. alone)
        allErrors(s4)
    end

    -- The host holds two of one already (from an older version): a guest joining gets one from the host's bag, not two.
    local j = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    j.pcs[1].bag:AddPropsToBackPack(2, j.pcs[1].env.FName(RELIC), false)
    j:run(12)
    check(Session.items(j.pcs[2], RELIC) == 1,
        "a story item the host holds twice: a guest joining gets one from the host's bag: " .. Session.items(j.pcs[2], RELIC))
    allErrors(j)
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

-- A boss's posture and a guest's blows (reports on 1.6.9 and the bench, 11-10: once its guard broke, the Gold-Masked One
-- was broken again 4 to 5 s after each fill, every guest blow taking posture, and spent 21 s of 30 reacting). The game's
-- own break and fill are played here by hand: the bar to empty, then up a little each frame from wherever it stands.
local function bossPosture()
    part("a boss's posture and a partner's blows")
    local BREAK = "CharacterState.HitReact.State.Break.Normal"
    local DEFLECT = "/PBZCombatAsset/ActorData/Move/Boss_Deflect_R_Success.Boss_Deflect_R_Success"
    local function setup()
        local s, h, g = pair()
        Session.moveTo(h, 2700, 3000)
        Session.moveTo(g, 3300, 3000)
        s:run(2)
        local t = { s = s, h = h, g = g, copy = Session.enemyOn(g, "boss"), theirs = Session.enemyOn(h, "boss") }
        function t.bar(e)
            return rawget(e, "__fields").AttributeSetBase.Shachi
        end
        function t.setBar(e, v)
            Fake.put(t.bar(e), "CurrentValue", v)
            Fake.put(t.bar(e), "BaseValue", v)
        end
        t.max = t.bar(t.theirs).BaseValue
        function t.hp(e)
            return (select(1, Fake.health(e)))
        end
        -- A guest's blow on its copy: posture off its bar, 50 health off it.
        function t.blow(posture)
            t.setBar(t.copy, math.max(0, t.bar(t.copy).CurrentValue - posture))
            swing(g, t.copy, t.hp(t.copy) - 50)
        end
        -- The game's own break on the host, then its fill: up a little each frame from wherever the bar stands.
        function t.hostBreaks()
            t.setBar(t.theirs, 0)
            Fake.put(field(t.theirs, "hit"), "state", BREAK)
            s:run(0.5)
            Fake.put(field(t.theirs, "hit"), "state", "None")
        end
        function t.fill(seconds, each)
            local frames = 0
            s:run(seconds, function()
                frames = frames + 1
                t.setBar(t.theirs, math.min(t.max, t.bar(t.theirs).CurrentValue + t.max / 180))
                if each then
                    each(frames)
                end
            end)
        end
        -- Both bars put at v, the host's line given time to reach the copy.
        function t.both(v)
            t.setBar(t.theirs, v)
            s:run(1.5)
            t.setBar(t.copy, v)
            s:run(0.1)
        end
        function t.sentSince(n, pattern)
            for i = n + 1, #g.sent do
                if g.sent[i]:find(pattern) then
                    return true
                end
            end
            return false
        end
        function t.state(e)
            return field(field(e, "hit"), "state")
        end
        return t
    end

    -- The host's own blow breaks it; the game fills it over 3 s; the guest swings throughout.
    local t = setup()
    local s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    t.hostBreaks()
    local hp0, filled = t.hp(theirs), true
    t.fill(3, function(frames)
        if frames % 24 == 0 then
            t.blow(40)
        end
        if frames < 180 and bar(theirs).CurrentValue < frames * max / 180 - 1 then
            filled = false              -- (lower than the fill alone: a guest's posture went into it)
        end
    end)
    check(filled and bar(theirs).CurrentValue >= max - 1,
        "a guest's blows take no posture from a boss filling after its break (" .. bar(theirs).CurrentValue .. " of " .. max .. ")")
    check(t.hp(theirs) < hp0 - 100, "but their damage lands")
    -- Back: for its recovery (6 s) a guest's blow takes no posture, here or on the copy.
    s:run(1)
    local before = bar(theirs).CurrentValue
    t.blow(40)
    s:run(0.5)
    check(bar(theirs).CurrentValue == before, "nor as it gets its fight back, just after (" .. bar(theirs).CurrentValue .. ")")
    check(bar(copy).CurrentValue >= max - 1 and t.state(copy) ~= BREAK,
        "and the guest's copy keeps the host's bar: no break of its own there")
    s:run(6)
    before = bar(theirs).CurrentValue
    t.blow(40)
    s:run(0.5)
    check(bar(theirs).CurrentValue < before - 30, "after that, a guest's blow takes posture again (" .. bar(theirs).CurrentValue .. ")")
    -- A deflect or a dodge turns their blow aside, as this world's.
    Session.enemyMove(h, "boss", DEFLECT)
    Session.enemyMove(g, "boss", DEFLECT)
    s:run(0.3)
    before = bar(theirs).CurrentValue
    t.blow(40)
    s:run(0.5)
    check(bar(theirs).CurrentValue == before, "a boss deflecting takes no posture from a guest's blow (" .. bar(theirs).CurrentValue .. ")")
    -- But a break their copy already had is a break, deflect or not: their game played it at once.
    t.both(40)
    local n = #g.sent
    Fake.put(field(copy, "hit"), "state", BREAK)
    t.setBar(copy, 0)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.3)
    check(t.state(theirs) == BREAK, "a copy's break as the boss deflects: it breaks here too (" .. tostring(t.state(theirs)) .. ")")
    Session.enemyMove(h, "boss", nil)
    Session.enemyMove(g, "boss", nil)
    -- In the 6 s after that break, its bar waiting empty for its refill, a partner's flinch doesn't play.
    s:run(1)
    Fake.put(field(theirs, "hit"), "state", "None")
    Fake.put(field(copy, "hit"), "state", "CharacterState.Hitreact.State.Normal")
    Session.enemyMove(g, "boss", "/PBZCombatAsset/ActorData/Move/Hit1.Hit1")
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.3)
    check(t.state(theirs) ~= "CharacterState.Hitreact.State.Normal", "nor a flinch of theirs in the 6 s after a break")
    Session.enemyMove(g, "boss", nil)
    Fake.put(field(copy, "hit"), "state", "None")
    allErrors(s)

    -- A guest's break the game holds a little above empty (the Gold-Masked One's at 1.64): emptied, filled 6 s on. (Left
    -- there, nothing ever filled it, and every break of the copy's broke the boss again.)
    t = setup()
    s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    t.both(30)
    Fake.put(field(copy, "hit"), "state", BREAK)
    t.setBar(copy, 4)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.5)
    check(bar(theirs).CurrentValue == 0, "a guest's break the game holds above empty: the host's bar emptied (" .. bar(theirs).CurrentValue .. ")")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    s:run(6.5)
    check(bar(theirs).CurrentValue >= max - 1 and count(h.logs, "Posture bar a partner emptied") >= 1,
        "and filled 6 s on, as a break's (" .. bar(theirs).CurrentValue .. ")")
    -- Back from it: a break of the copy's own in its recovery is the copy's alone.
    s:run(1)
    Session.enemyMove(h, "boss", "/PBZCombatAsset/ActorData/Move/E1.E1")
    s:run(0.3)
    Fake.put(field(copy, "hit"), "state", BREAK)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.5)
    check(t.state(theirs) ~= BREAK and bar(theirs).CurrentValue >= max - 1, "a copy's break while the boss recovers doesn't break the host's")
    Session.enemyMove(h, "boss", nil)
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    -- Past it: a guest's blow empties the host's bar with no break on the copy, then the copy's break comes. (The first
    -- used up the break's once, and the boss never broke here though the guest saw it break.)
    s:run(7)
    t.both(40)
    t.blow(40)
    s:run(0.3)
    local early = t.state(theirs)
    Fake.put(field(copy, "hit"), "state", BREAK)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.3)
    check(early ~= BREAK and t.state(theirs) == BREAK,
        "a bar a guest's blow empties, then the copy's break: that break plays here (" .. tostring(early) .. ")")
    allErrors(s)

    -- A guest's blow that breaks its copy carries its posture to the host; one that only takes posture, a parry's, goes too.
    t = setup()
    s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    t.both(60)
    n = #g.sent
    t.setBar(copy, 0)
    Fake.put(field(copy, "hit"), "state", BREAK)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.3)
    check(t.sentSince(n, "^E D sp:boss 50%.0 60%.0"), "a guest's blow that breaks its copy carries its posture to the host")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    s:run(14)
    t.both(40)
    n = #g.sent
    g.env.PBZ.game.noteLocalMove()
    t.setBar(copy, 0)
    Fake.put(field(copy, "hit"), "state", BREAK)
    s:run(0.3)
    check(t.sentSince(n, "^E D sp:boss 0%.0 40%.0") and t.state(theirs) == BREAK,
        "a parry that breaks the copy, no health taken: it goes, and the host's boss breaks (" .. tostring(t.state(theirs)) .. ")")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    -- The host's own break and fill, and a guest's blow breaks its copy in it: the copy is left broken, its bar as its game
    -- has it (its break and the guest's execution play out), and no posture goes to the host.
    s:run(14)
    t.hostBreaks()
    t.fill(0.6)
    n = #g.sent
    t.setBar(copy, 0)
    Fake.put(field(copy, "hit"), "state", BREAK)
    swing(g, copy, t.hp(copy) - 50)
    t.fill(0.2)
    check(bar(copy).CurrentValue < 1 and t.sentSince(n, "^E D sp:boss 50%.0 0%.0") and t.state(copy) == BREAK,
        "a guest's blow that breaks its copy in the host's own fill: the copy stays broken, no posture to the host ("
        .. bar(copy).CurrentValue .. ")")
    allErrors(s)

    -- When a partner's blow empties the bar here, its refill: a bar the host's own blow left one short (8) that a guest's
    -- blow then empties is filled 6 s on; a guest's blow that leaves it a little up (4), not broken, isn't (its work kept).
    t = setup()
    s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    t.both(88)
    t.setBar(theirs, 8)
    t.blow(80)
    s:run(0.5)
    local emptiedHere = bar(theirs).CurrentValue
    s:run(6.5)
    check(emptiedHere == 0 and bar(theirs).CurrentValue >= max - 1,
        "a bar a guest's blow empties is filled 6 s on (" .. emptiedHere .. " -> " .. bar(theirs).CurrentValue .. ")")
    s:run(8)
    t.both(44)
    t.blow(40)
    s:run(7)
    check(bar(theirs).CurrentValue == 4, "one a guest's blow leaves a little up isn't filled (" .. bar(theirs).CurrentValue .. ")")
    allErrors(s)

    -- The host's own rules, with a guest that has none of them (an older one): the host still refuses its posture in its
    -- fill, its recovery and a deflect of its own, here alone.
    t = setup()
    s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    g.env.PBZ.game.partnerRefuses = function() return nil end
    t.hostBreaks()
    local fillOk = true
    t.fill(3, function(frames)
        if frames % 24 == 0 then
            t.setBar(copy, math.max(0, bar(theirs).CurrentValue - 40))
            swing(g, copy, t.hp(copy) - 50)
        end
        if frames < 180 and bar(theirs).CurrentValue < frames * max / 180 - 1 then
            fillOk = false
        end
    end)
    check(fillOk, "an older guest's blows: the host's boss still takes no posture in its fill")
    s:run(1)
    before = bar(theirs).CurrentValue
    t.setBar(copy, before - 40)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.5)
    check(bar(theirs).CurrentValue == before, "nor in its recovery")
    s:run(7)
    Session.enemyMove(h, "boss", DEFLECT)
    s:run(0.3)
    before = bar(theirs).CurrentValue
    t.setBar(copy, before - 40)
    swing(g, copy, t.hp(copy) - 50)
    s:run(0.5)
    check(bar(theirs).CurrentValue == before, "nor as it deflects, a deflect of the host's boss alone (" .. bar(theirs).CurrentValue .. ")")
    Session.enemyMove(h, "boss", nil)
    allErrors(s)

    -- The recovery is 6 s on both PCs, whatever each one's CoopBossPoise says (a guest's at 1000 refused 30 s of blows the
    -- host would have taken).
    t = setup()
    s, h, g, copy, theirs, bar, max = t.s, t.h, t.g, t.copy, t.theirs, t.bar, t.max
    Session.command(g, "bosspoise 1000")
    t.hostBreaks()
    t.fill(3)
    s:run(7.5)
    before = bar(theirs).CurrentValue
    t.blow(40)
    s:run(0.5)
    check(bar(theirs).CurrentValue < before - 30, "the recovery is 6 s, whatever the guest's CoopBossPoise (" .. bar(theirs).CurrentValue .. ")")
    allErrors(s)
end

-- The game's boss bars on this PC's fake HUD (it lists none of its own), as the game's (the bench, 11-11): one a boss
-- registered, no Character till it's started with Init(boss), keeping what it's told (shachi, health, how often its strip
-- and its health were told, and its Inits). Its name (BossName's text): none till Init, which names it as the codex does
-- (codex: one name for every boss, or the boss's internal name -> its name), or by the boss's internal name (one the codex
-- has no row for, as the game named the Gold-Masked One). A bar taken down goes to a pool and is handed back as it was,
-- Character and name, for the next boss registered (the HUD's BossPoint, a dynamic entry box with a widget pool).
-- Returns the bar of a boss, and a function that adds a bar nobody started (a PvP foe's).
local function bossBarsOn(pc, codex)
    local hud = pc.hudLayout
    local f = rawget(hud, "__fields")
    local realUp, realDown = f.RegisterBossHPBar, f.UnRegisterBossHPBar
    local active, pool = {}, {}         -- active: { boss = address or false, bar }, in order; pool: bars taken down
    local function newBar()
        local name = Fake.object(pc, "PBZCommonLocText", { text = "" }, true)
        Fake.put(name, "GetText", function(w)
            local text = field(w, "text")
            return { ToString = function() return text end }
        end)
        Fake.put(name, "SetText", function(w, text) Fake.put(w, "text", tostring(text)) end)
        local bar = Fake.object(pc, "WB_BossHPBar_C", { shachi = 1.0, health = 1.0, told = 0, healthTold = 0, inits = 0,
            BossName = name }, true)
        Fake.put(bar, "Init", function(w, boss)
            Fake.put(w, "Character", boss)
            Fake.put(w, "inits", field(w, "inits") + 1)
            local own = boss:GetFName():ToString()
            Fake.put(name, "text", (type(codex) == "table" and codex[own]) or (type(codex) == "string" and codex) or own)
        end)
        Fake.put(bar, "ForSeq_UpdateShachi", function(w, v)
            Fake.put(w, "shachi", v)
            Fake.put(w, "told", field(w, "told") + 1)
        end)
        Fake.put(bar, "ForSeq_UpdateHealth", function(w, v)
            Fake.put(w, "health", v)
            Fake.put(w, "healthTold", field(w, "healthTold") + 1)
        end)
        return bar
    end
    local function entryOf(a)
        for _, e in ipairs(active) do
            if e.boss == a then
                return e
            end
        end
        return nil
    end
    Fake.put(hud, "RegisterBossHPBar", function(self, b)
        local a = b:GetAddress()
        if not entryOf(a) then
            active[#active + 1] = { boss = a, bar = table.remove(pool, 1) or newBar() }
        end
        return realUp(self, b)
    end)
    Fake.put(hud, "UnRegisterBossHPBar", function(self, b)
        local a = b:GetAddress()
        for i = #active, 1, -1 do
            if active[i].boss == a then
                pool[#pool + 1] = active[i].bar
                table.remove(active, i)
            end
        end
        return realDown(self, b)
    end)
    Fake.put(hud, "GetBossHPBarInstances", function()
        local list = {}
        for i, e in ipairs(active) do
            local bar = e.bar
            list[i] = { get = function() return bar end }
        end
        return list
    end)
    local function unstarted()
        local bar = newBar()
        active[#active + 1] = { boss = false, bar = bar }
        return bar
    end
    return function(boss)
        local e = entryOf(boss:GetAddress())
        return e and e.bar
    end, unstarted
end

-- Issue #16 (1), a player's report on 1.6.8: "boss posture not visibly changing on partner hits although HP changes". A
-- boss's posture written by hand (a partner's blow on the host, the host's line on a guest's copy, a blow the copy takes
-- back, a refill) moved nothing on its bar: the gold strip under the health follows the game's own changes only. Each is
-- told now, with the bar's own ForSeq_UpdateShachi.
local function postureStrip()
    part("a boss's posture bar and a partner's blows")
    local DEFLECT = "/PBZCombatAsset/ActorData/Move/Boss_Deflect_R_Success.Boss_Deflect_R_Success"
    local BREAK = "CharacterState.HitReact.State.Break.Normal"
    local s, h, g = pair()
    local hostBar, unstartedBar = bossBarsOn(h)
    local guestBar = bossBarsOn(g)
    Session.moveTo(h, 2700, 3000)
    Session.moveTo(g, 3300, 3000)
    s:run(2)
    local theirs, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
    h.hudLayout:RegisterBossHPBar(theirs)           -- (the host's own fight: its bar, not started yet)
    s:run(2)
    local hb, gb = hostBar(theirs), guestBar(copy)
    check(hb ~= nil and gb ~= nil, "the boss's bar on both HUDs, the guest's for the host's fight")
    if not (hb and gb) then
        allErrors(s)
        return
    end
    check(field(gb, "Character") == copy and field(gb, "inits") == 1,
        "the bar put up for the host's fight is started with the guest's copy (Init), as a fight's own bar is")
    check(field(field(gb, "BossName"), "text") == "",
        "and keeps the name it had, none: not the boss's internal name that Init gives a boss the codex has no row for ("
        .. tostring(field(field(gb, "BossName"), "text")) .. ")")
    local function shachi(e)
        return rawget(e, "__fields").AttributeSetBase.Shachi
    end
    local function setShachi(e, v)
        Fake.put(shachi(e), "CurrentValue", v)
        Fake.put(shachi(e), "BaseValue", v)
    end
    local max = shachi(theirs).BaseValue
    local function share(e)
        return shachi(e).CurrentValue / max
    end
    local function near(a, b)
        return a ~= nil and b ~= nil and math.abs(a - b) < 0.005
    end
    -- A guest's blow: the host's boss takes its posture by hand. Its bar not started (one put up by hand): told the same.
    setShachi(copy, shachi(copy).CurrentValue - 40)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(shachi(theirs).CurrentValue < max - 30 and near(field(hb, "shachi"), share(theirs)),
        "a guest's blow on the host's boss moves the gold strip on its bar there, one nobody started too ("
        .. tostring(field(hb, "shachi")) .. " for " .. share(theirs) .. ")")
    check(field(hb, "health") < 1, "as it moves its health (" .. tostring(field(hb, "health")) .. ")")
    -- Started with the boss, as the game starts the bar of its own fight: told as that boss's.
    field(hb, "Init")(hb, theirs)
    setShachi(copy, shachi(copy).CurrentValue - 40)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(shachi(theirs).CurrentValue < max - 70 and near(field(hb, "shachi"), share(theirs)),
        "and on a bar started with the boss (" .. tostring(field(hb, "shachi")) .. " for " .. share(theirs) .. ")")
    -- The host's own blow: the guest's copy takes the host's line by hand.
    setShachi(theirs, shachi(theirs).CurrentValue - 60)
    s:run(1.5)
    check(near(share(copy), share(theirs)) and near(field(gb, "shachi"), share(copy)),
        "the host's blow moves the strip on the guest's bar for its copy (" .. tostring(field(gb, "shachi")) .. " for "
        .. share(copy) .. ")")
    -- A blow the copy takes back (the boss deflecting it, as the host's does): the strip back where the copy's bar is.
    Session.enemyMove(h, "boss", DEFLECT)
    Session.enemyMove(g, "boss", DEFLECT)
    s:run(0.3)
    local kept = shachi(copy).CurrentValue
    setShachi(copy, kept - 40)
    Fake.put(gb, "shachi", (kept - 40) / max)          -- (the game's own bar follows its own blow)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(shachi(copy).CurrentValue == kept and near(field(gb, "shachi"), kept / max),
        "a blow the guest's copy takes back puts its strip back too (" .. tostring(field(gb, "shachi")) .. ")")
    Session.enemyMove(h, "boss", nil)
    Session.enemyMove(g, "boss", nil)
    -- An enemy that isn't in a boss fight: no bar told.
    local told = field(hb, "told")
    h.env.PBZ.game.setPosture(Session.enemyOn(h, "thug1"), 10)
    check(field(hb, "told") == told, "a thug's posture written tells no boss bar")
    -- A bar nobody started beside the boss's own (a PvP foe's has no Character): only the boss's own is told; in a match
    -- none with no Character is, even with no boss bar of its own.
    local foe = unstartedBar()
    h.env.PBZ.game.setPosture(theirs, shachi(theirs).CurrentValue - 10)
    local besideOwn = field(foe, "told") == 0 and near(field(hb, "shachi"), share(theirs))
    Fake.put(hb, "Character", nil)
    net(h).arena = true
    h.env.PBZ.game.setPosture(theirs, shachi(theirs).CurrentValue + 10)
    net(h).arena = nil
    Fake.put(hb, "Character", theirs)
    check(besideOwn and field(foe, "told") == 0, "a bar with no Character isn't told beside the boss's own, nor in a match")
    -- Its guard broken by a guest's blow: the strip empty on the host's bar, and full again when the bar is filled 6 s on.
    setShachi(theirs, 40)
    s:run(1.5)
    setShachi(copy, 40)
    s:run(0.1)
    Fake.put(field(copy, "hit"), "state", BREAK)
    setShachi(copy, 0)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(shachi(theirs).CurrentValue == 0 and near(field(hb, "shachi"), 0),
        "a guest's break empties the strip on the host's bar (" .. tostring(field(hb, "shachi")) .. ")")
    Fake.put(field(copy, "hit"), "state", "None")
    Fake.put(field(theirs, "hit"), "state", "None")
    s:run(6.5)
    check(shachi(theirs).CurrentValue >= max - 1 and near(field(hb, "shachi"), 1),
        "and fills it as the bar is filled 6 s on (" .. tostring(field(hb, "shachi")) .. ")")
    allErrors(s)

    -- A boss the codex has: Init gives the guest's bar the boss's name (the elite swordsman's, on the bench), and it keeps
    -- it (put up unstarted, it had none).
    local s2, h2, g2 = pair()
    bossBarsOn(h2, "Jagged Steel, the Frenzied Brute")
    local named = bossBarsOn(g2, "Jagged Steel, the Frenzied Brute")
    h2.hudLayout:RegisterBossHPBar(Session.enemyOn(h2, "boss"))
    s2:run(2)
    local nb = named(Session.enemyOn(g2, "boss"))
    check(nb ~= nil and field(nb, "inits") == 1 and field(field(nb, "BossName"), "text") == "Jagged Steel, the Frenzied Brute",
        "a boss the codex has: the guest's bar for the host's fight takes its name with Init, and keeps it ("
        .. tostring(nb and field(field(nb, "BossName"), "text")) .. ")")
    allErrors(s2)
end

-- A boss bar the HUD hands back from its pool, still on the boss before (the review of 339d057): the elite swordsman's
-- bar on the guest, then the Gold-Masked One's (a boss the codex lacks), their arenas a few metres apart. Kept as it was,
-- it showed the elite's name over the Gold-Masked One, and neither his health nor his strip moved on it. And the copy a
-- pairing swaps in (keepBossBar) got the bar of the one swapped out.
local function reusedBars()
    part("a boss bar the HUD hands back")
    local BOSSES = {
        { "elite", "BP_Monster_EliteSword_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
        { "gold", "BP_Monster_GoldMaskMan_C", 3400.0, 3000.0, 100.0, 5000, 400, true },
        { "gold2", "BP_Monster_GoldMaskMan_C", 3450.0, 3000.0, 100.0, 5000, 400, true },
    }
    local CODEX = { elite_actor = "Jagged Steel, the Frenzied Brute" }
    local function shachi(e)
        return rawget(e, "__fields").AttributeSetBase.Shachi
    end
    local function near(a, b)
        return a ~= nil and b ~= nil and math.abs(a - b) < 0.005
    end
    -- The host's elite fight, then its Gold-Masked One fight, both on the guest; gone: the elite's copy gone before it.
    local function twoFights(gone)
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, BOSSES)
        s:run(4)
        local h, g = s.pcs[1], s.pcs[2]
        bossBarsOn(h, CODEX)
        local guestBar = bossBarsOn(g, CODEX)
        Session.moveTo(h, 2900, 3000)
        Session.moveTo(g, 3300, 3000)
        s:run(2)
        local eliteH, eliteG = Session.enemyOn(h, "elite"), Session.enemyOn(g, "elite")
        local goldH, goldG = Session.enemyOn(h, "gold"), Session.enemyOn(g, "gold")
        h.hudLayout:RegisterBossHPBar(eliteH)
        s:run(2)
        local eliteBar = guestBar(eliteG)
        Fake.setHealth(eliteH, 0)
        Fake.put(eliteH, "dead", true)
        s:run(1)
        h.hudLayout:UnRegisterBossHPBar(eliteH)
        s:run(3)
        if gone then
            rawset(eliteG, "__alive", false)
        end
        h.hudLayout:RegisterBossHPBar(goldH)
        s:run(2)
        local gb = guestBar(goldG)
        local r = { s = s, g = g, reused = eliteBar ~= nil and gb == eliteBar, gb = gb, copy = goldG }
        if gb then
            r.healthTold, r.told = field(gb, "healthTold"), field(gb, "told")
            Fake.setHealth(goldH, select(1, Fake.health(goldH)) * 0.6)
            Fake.put(shachi(goldH), "CurrentValue", shachi(goldH).BaseValue - 120)
            Fake.put(shachi(goldH), "BaseValue", shachi(goldH).BaseValue - 120)
            s:run(1.5)
        end
        return r
    end
    local a = twoFights(false)
    local gb = a.gb
    check(a.reused, "the Gold-Masked One's bar on the guest is the elite's, handed back (as the HUD does)")
    check(gb ~= nil and field(gb, "Character") == a.copy and field(field(gb, "BossName"), "text") == "",
        "started with the guest's copy of him, the elite's body still in the world: no name, not the elite's ("
        .. tostring(gb and field(field(gb, "BossName"), "text")) .. ")")
    local hp, max = Fake.health(a.copy)
    local top = rawget(a.copy, "__fields").AttributeSetBase.Shachi_Max.CurrentValue
    check(gb ~= nil and field(gb, "healthTold") > (a.healthTold or 0) and near(field(gb, "health"), hp / max)
        and field(gb, "told") > (a.told or 0) and near(field(gb, "shachi"), shachi(a.copy).CurrentValue / top),
        "and the host's blow moves its health and its strip there (" .. tostring(gb and field(gb, "health")) .. ", "
        .. tostring(gb and field(gb, "shachi")) .. ")")
    check(count(a.g.logs, "Showing boss bar for gold") == 1, "shown once, not again and again: "
        .. count(a.g.logs, "Showing boss bar for gold"))
    allErrors(a.s)
    local b = twoFights(true)
    check(b.gb ~= nil and field(b.gb, "Character") == b.copy and field(field(b.gb, "BossName"), "text") == "",
        "the elite's body gone: no name either, not the elite's put back (" .. tostring(b.gb and field(field(b.gb, "BossName"), "text"))
        .. ")")
    allErrors(b.s)
    -- keepBossBar's pairing swap, as its slow tick does it: the copy before let go, the copy now shown, the same tick.
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, BOSSES)
    s:run(4)
    local g = s.pcs[2]
    local guestBar = bossBarsOn(g, CODEX)
    s:run(1)
    local game = g.env.PBZ.game
    local before, now = Session.enemyOn(g, "gold"), Session.enemyOn(g, "gold2")
    game.showBossBar(before)
    game.hideBossBar(before)
    game.keepBossBar(now)
    local nb = guestBar(now)
    local healthTold, told = nb and field(nb, "healthTold") or 0, nb and field(nb, "told") or 0
    game.setHealth(now, select(1, Fake.health(now)) * 0.5)
    game.setPosture(now, shachi(now).BaseValue * 0.5)
    check(nb ~= nil and field(nb, "Character") == now and field(nb, "healthTold") > healthTold and field(nb, "told") > told,
        "the copy a pairing swaps in gets the bar started with it, its health and strip told")
    allErrors(s)
end

-- Issue #16 (2): a guest's call that takes the host's story flow (a flag, a flow step, a bell lit as the guest comes to it)
-- that failed once was let go with the rest of the queue: lost till the next link.
local function flowRetries()
    part("a story step whose call fails")
    local s, h, g = pair()
    s:run(4)
    h.env.PBZ.game.storyFlags = nil
    local fails, calls = { tag = 1, node = 1, bell = 1, late = 0, off = 0 }, { bad = 0, late = 0, off = 0 }
    local ep = g.eventPipeline
    local realTag = field(ep, "AddTagsByString")
    Fake.put(ep, "AddTagsByString", function(self, tag)
        if tag == "zddy.always.fails" then
            calls.bad = calls.bad + 1
            error("not now")
        end
        local kind = (tag == "zddy.retry.late" and "late") or (tag == "zddy.retry.off" and "off") or "tag"
        if kind ~= "tag" then
            calls[kind] = calls[kind] + 1
        end
        if fails[kind] > 0 then
            fails[kind] = fails[kind] - 1
            error("not now")
        end
        return realTag(self, tag)
    end)
    local guids = field(ep, "ExecuteNodeGuid")
    local realAdd = field(guids, "Add")
    Fake.put(guids, "Add", function(self, k, v)
        if fails.node > 0 then
            fails.node = fails.node - 1
            error("not now")
        end
        return realAdd(self, k, v)
    end)
    local realBell = field(g.bellManager, "ActivateBellByID")
    Fake.put(g.bellManager, "ActivateBellByID", function(self, id)
        if fails.bell > 0 then
            fails.bell = fails.bell - 1
            error("not now")
        end
        return realBell(self, id)
    end)
    table.insert(h.globalTags, "zddy.retry.flag")
    table.insert(h.globalTags, "zddy.always.fails")
    h.eventPipeline.ExecuteNodeGuid:Add("RETRY0123456789ABCDEF0123456789AB")
    table.insert(h.bellIds, "Bell_YXZR_005")
    s:run(24)
    check(g.storyMarks["zddy.retry.flag"] and g.storyGuids["RETRY0123456789ABCDEF0123456789AB"],
        "a flag and a flow step whose call failed once are taken a second on")
    check(calls.bad == 5 and count(g.logs, "couldn't be taken here") == 1,
        "one that always fails is tried 5 times in all, then let go (" .. calls.bad .. ")")
    Session.moveTo(g, 30000, 2000)
    s:run(4)
    Session.moveTo(g, 500, 0)
    s:run(4)
    check(g.storyMarks["Bell_YXZR_005"], "a bell whose lighting failed once is lit a second on")
    -- One waiting to be tried again when the guest stops following the host's story: let go.
    fails.late = 3
    table.insert(h.globalTags, "zddy.retry.late")
    for _ = 1, 300 do
        s:run(0.1)
        if calls.late >= 1 then
            break
        end
    end
    g.env.PBZ.story.follow = false
    s:run(6)
    check(calls.late == 1 and not g.storyMarks["zddy.retry.late"],
        "one waiting when the guest stops following the host's story is let go (" .. calls.late .. " tries)")
    g.env.PBZ.story.follow = true
    -- A flag owed for what the other player found (OF: a pile or chest they searched) whose call failed: raised a calm
    -- second on, on the host as on a guest (it was let go with the list; the review of 339d057).
    local owedFails = 1
    local hostTag = field(h.eventPipeline, "AddTagsByString")
    Fake.put(h.eventPipeline, "AddTagsByString", function(self, tag)
        if tag == "zddy.owed.flag" and owedFails > 0 then
            owedFails = owedFails - 1
            error("not now")
        end
        return hostTag(self, tag)
    end)
    h.inbox[#h.inbox + 1] = "~10 OF BP_Rubbish_C_Herb zddy.owed.flag"
    s:run(4)
    check(owedFails == 0 and h.storyMarks["zddy.owed.flag"] == true,
        "a flag owed for the other player's search whose call failed once is raised a second on")
    -- One waiting to be tried again when sync goes off: let go, not taken in the next session, maybe in another save. (The
    -- host gone first: a host linked again tells everything again anyway.)
    fails.off = 9
    table.insert(h.globalTags, "zddy.retry.off")
    for _ = 1, 300 do
        s:run(0.1)
        if calls.off >= 1 then
            break
        end
    end
    Session.command(h, "netoff")
    Session.command(g, "netoff")
    s:run(1)
    fails.off = 0
    Session.command(g, "neton client")
    s:run(6)
    check(calls.off == 1 and not g.storyMarks["zddy.retry.off"],
        "one waiting when sync goes off is let go, not taken in the next session (" .. calls.off .. " tries)")
    allErrors(s)

    -- A quest step's flag the game wouldn't take as a stuck save was mended (story.lua): mended again at the next read of
    -- the quests (it was marked mended first, and stayed short that load; the review of 339d057).
    local herbFails = 1
    local m, mh = pair(nil, function(ph2, pg2)
        for _, pc in ipairs({ ph2, pg2 }) do
            pc.storyUpTo(5)
            pc.storyStep("Main-Valley", "2", 1)
            pc.storyTask("Main-Valley", "1", { "valley.herbs" })
        end
        local real = field(ph2.eventPipeline, "AddTagsByString")
        Fake.put(ph2.eventPipeline, "AddTagsByString", function(self, tag)
            if tag == "valley.herbs" and herbFails > 0 then
                herbFails = herbFails - 1
                error("not now")
            end
            return real(self, tag)
        end)
    end)
    m:run(45)
    check(herbFails == 0 and mh.storyMarks["valley.herbs"] == true,
        "a step's flag the game wouldn't take as a stuck save was mended is mended again, a read of the quests on")
    allErrors(m)
end

-- Issue #16 (3): a move heard while the partner's figure couldn't play it (none yet, hidden, its animation not up) was
-- dropped, and a move is told only as it starts: the figure stood through it. Held a moment now, the newest only; and one
-- a partner who links again missed is told again.
local function heldMoves()
    part("a move their figure can't play yet")
    local s, h, g = pair()
    s:run(1)
    local ghost = net(h).ghost              -- (two players: the partner is net itself)
    local mesh, anim = field(ghost, "Mesh"), field(ghost, "anim")
    local realAnim = field(mesh, "GetAnimInstance")
    local function ready(yes)
        Fake.put(mesh, "GetAnimInstance", yes and realAnim or function() return nil end)
    end
    local function played()
        return field(anim, "played") or 0
    end
    local A1, A2, A3 = "/PBZCombatAsset/ActorData/Move/A1.A1", "/PBZCombatAsset/ActorData/Move/A2.A2",
        "/PBZCombatAsset/ActorData/Move/A3.A3"
    -- Its animation not up (a figure just made): a move heard then plays as soon as it is, as far in as it is by then.
    ready(false)
    local before = played()
    h.inbox[#h.inbox + 1] = "~40 U " .. A1 .. " 0.10"
    s:run(0.3)
    local waited = played() == before
    ready(true)
    s:run(0.2)
    local start = field(anim, "start")
    check(waited and played() == before + 1, "a move heard while their figure's animation isn't up plays as soon as it is")
    check(start and start > 0.43 and start < 0.66, "as far in as the move is by then (" .. tostring(start) .. ")")
    -- Not up for longer than a moment: let go, nothing played late.
    ready(false)
    before = played()
    h.inbox[#h.inbox + 1] = "~10 U " .. A2 .. " 0.00"
    s:run(1.2)
    ready(true)
    s:run(0.5)
    check(played() == before, "one their figure couldn't play for longer than a moment isn't played late")
    -- Ended before their figure could play it ("U - 0"): nothing.
    ready(false)
    h.inbox[#h.inbox + 1] = "~10 U " .. A1 .. " 0.00"
    s:run(0.2)
    h.inbox[#h.inbox + 1] = "~10 U - 0"
    s:run(0.1)
    ready(true)
    s:run(0.5)
    check(played() == before, "nor one they ended before it could be")
    -- Their figure hidden (they were down) and shown again as they get up: the move heard in between plays.
    Session.die(g)
    s:run(2)
    local hidden = net(h).ghostHidden == true
    h.inbox[#h.inbox + 1] = "~10 U " .. A2 .. " 0.00"
    s:run(0.1)
    Session.revive(g)
    s:run(0.6)
    check(hidden and played() == before + 1 and field(anim, "montage") ~= nil,
        "a move heard while their figure is hidden plays once it's shown again, a moment on")
    -- In this PC's quiet after a load or a stall (5 s, the extra ticks held back): played all the same, as soon as it can
    -- be (the review of 339d057: let go before the quiet lifted, a figure made after a trip standing through the move).
    net(h).quietUntil = h.now + 5
    ready(false)
    before = played()
    h.inbox[#h.inbox + 1] = "~10 U " .. A1 .. " 0.00"
    s:run(0.3)
    ready(true)
    s:run(0.5)
    check(played() == before + 1, "in the quiet after a load or a stall too: " .. played() - before)
    net(h).quietUntil = nil
    -- A partner who links again while this player is in a move is told it, as far in as it is. (Moves go quick: Q U.)
    Session.startMove(h, A3)
    s:run(0.5)
    local told = count(h.sent, "U " .. A3)
    Session.command(g, "netoff")
    s:run(1)
    for _, made in ipairs(g.spawned) do         -- (its figures of the host: what they played before is gone)
        local a = field(made, "anim")
        if a then
            Fake.put(a, "montage", nil)
        end
    end
    Session.command(g, "neton client")
    s:run(3)
    check(count(h.sent, "U " .. A3) > told, "a partner who links again is told the move this player is in")
    local theirAnim = net(g).ghost and field(net(g).ghost, "anim")
    check(theirAnim ~= nil and field(theirAnim, "montage") ~= nil and rawget(field(theirAnim, "montage"), "__path") == A3,
        "and their new figure of this player plays it")
    Session.endMove(h)
    allErrors(s)
end

-- Boss super armour (CoopBossArmor; the user, 11-10: "the bosses should not be able to be knocked back"): while a partner
-- is here, a boss the host runs lets go of a flinch at once and never sends it as a move; its guard break, an execution, a
-- scripted reaction and one on the ground stay; a thug's flinch is the game's; a partner's flinch isn't played on it, their
-- break is; and with it Off, or alone, a boss flinches as the game has it.
local function bossArmour()
    part("boss super armour")
    local FLINCH = "CharacterState.Hitreact.State.Normal"
    local BREAK = "CharacterState.HitReact.State.Break.Normal"
    local HIT = "/PBZCombatAsset/ActorData/Move/Hit1.Hit1"
    local function state(e)
        return field(field(e, "hit"), "state")
    end
    local function setState(e, tag)
        Fake.put(field(e, "hit"), "state", tag)
    end
    local function montage(e)
        return field(field(e, "anim"), "montage")
    end
    local function setBar(e, v)
        Fake.put(field(e, "AttributeSetBase").Shachi, "CurrentValue", v)
        Fake.put(field(e, "AttributeSetBase").Shachi, "BaseValue", v)
    end
    local function fight(extraIni)
        local s, h, g = pair(extraIni or "CoopBossArmor = On\n")     -- (left out of the ini it's off: the ini ships it On)
        Session.moveTo(h, 2700, 3000)
        Session.moveTo(g, 3300, 3000)
        s:run(2)
        local theirs = Session.enemyOn(h, "boss")
        h.hudLayout:RegisterBossHPBar(theirs)
        s:run(1)
        return s, h, g, theirs, Session.enemyOn(g, "boss")
    end
    local function sentSince(pc, n, pattern)
        for i = n + 1, #pc.sent do
            if pc.sent[i]:find(pattern) then
                return true
            end
        end
        return false
    end

    local s, h, g, theirs, copy = fight()
    local n = #h.sent
    setState(theirs, FLINCH)
    Session.enemyMove(h, "boss", HIT)
    s:run(0.2)
    check(state(theirs) == "None", "a boss's flinch is let go at once while a partner is here (" .. tostring(state(theirs)) .. ")")
    check(montage(theirs) == nil, "its reaction stops with it")
    check(not sentSince(h, n, "Hit1%.Hit1"), "and the flinch never goes to the guest as a move")
    for _, tag in ipairs({ "CharacterState.Hitreact.State.Normal.Knockback", "CharacterState.Hitreact.State.Normal.Heavy",
        "CharacterState.Hitreact.State.Normal.Counter", "CharacterState.Hitreact.State.NormalLoop",
        "CharacterState.Hitreact.State.Launchingback", "CharacterState.Hitreact.State.PoiseBreak" }) do
        setState(theirs, tag)
        s:run(0.2)
        check(state(theirs) == "None", "let go too: " .. tag:gsub("CharacterState%.Hitreact%.", ""))
    end
    for _, tag in ipairs({ BREAK, "CharacterState.Hitreact.State.Break.State", "CharacterState.HitReact.State.Executing",
        "CharacterState.HitReact.State.Normal.Perform", "CharacterState.Hitreact.State.Lying",
        "CharacterState.Hitreact.State.InAir", "CharacterState.Hitreact.State.Frozen" }) do
        setState(theirs, tag)
        s:run(0.2)
        check(state(theirs) == tag, "left to the game: " .. tag:gsub("CharacterState%.Hit[Rr]eact%.", ""))
        setState(theirs, "None")
    end
    -- A thug isn't a boss: its flinch is the game's.
    local thug = Session.enemyOn(h, "thug1")
    setState(thug, FLINCH)
    s:run(0.2)
    check(state(thug) == FLINCH, "a thug's flinch is left to the game")
    setState(thug, "None")
    -- On the guest, between the host's moves, the copy's own flinch at their hit is let go too: the host's boss had none.
    -- (On the bench the guest still saw its copy flinch a quarter of the fight.)
    Session.enemyMove(h, "boss", nil)
    setState(theirs, "None")
    s:run(5)
    setState(copy, FLINCH)
    Session.enemyMove(g, "boss", HIT)
    s:run(0.3)
    check(state(copy) == "None" and montage(copy) == nil,
        "the guest's copy lets its own flinch go between the host's moves (" .. tostring(state(copy)) .. ")")
    -- And a reaction of its own that plays on after its hit state is over (the knockback the guest saw on the bench).
    Session.enemyMove(g, "boss", HIT)
    s:run(0.3)
    check(montage(copy) == nil, "and a reaction of the copy's own playing on with no hit state")
    -- A guest's flinch isn't played on the host's boss; their break is. (The host's boss between moves and past the wait
    -- between flinches first: in one of its moves, the scripts before took no flinch of theirs either.)
    Session.enemyMove(h, "boss", nil)
    setState(theirs, "None")
    s:run(4)
    setState(copy, FLINCH)
    Session.enemyMove(g, "boss", HIT)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.3)
    check(state(theirs) ~= FLINCH and state(theirs) ~= "CharacterState.Hitreact.State.Normal",
        "a guest's flinch isn't played on an armoured boss (" .. tostring(state(theirs)) .. ")")
    Session.enemyMove(g, "boss", nil)
    setState(copy, "None")
    s:run(1)
    setBar(theirs, 40)
    s:run(1.5)
    setBar(copy, 40)
    s:run(0.1)
    setState(copy, BREAK)
    setBar(copy, 0)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.3)
    check(state(theirs) == BREAK, "a guest's break still plays on it (" .. tostring(state(theirs)) .. ")")
    allErrors(s)

    -- A hit that cuts one of its moves: the move goes on where it was, and nothing new goes to the guest, whose copy plays it
    -- on (super armour: the hit neither stuns it nor stops it).
    local E1 = "/PBZCombatAsset/ActorData/Move/E1.E1"
    local function playing(e)
        local m = montage(e)
        return m and m:GetFullName():gsub("^%S+ ", "") or "-"
    end
    setState(theirs, "None")
    s:run(1)
    Session.enemyMove(h, "boss", E1)
    s:run(0.5)
    n = #h.sent
    setState(theirs, FLINCH)
    Session.enemyMove(h, "boss", HIT)
    s:run(0.2)
    check(state(theirs) == "None" and playing(theirs) == E1, "a hit that cut its move: the move goes on (" .. playing(theirs) .. ")")
    check(not sentSince(h, n, "Hit1%.Hit1") and not sentSince(h, n, "E1%.E1"), "and nothing new goes to the guest")
    check(playing(copy) == E1, "whose copy plays it on (" .. playing(copy) .. ")")
    -- The copy's own reaction to the guest's hit in that move gives way to the move.
    Session.enemyMove(g, "boss", HIT)
    s:run(0.3)
    check(playing(copy) == E1, "the copy's own reaction in the host's move gives way to the move (" .. playing(copy) .. ")")
    Session.enemyMove(h, "boss", nil)
    s:run(2)
    -- A guest whose own CoopBossArmor is off: their copy keeps its flinch and tells the host, which doesn't play it.
    Session.command(g, "bossarmor off")
    -- (Once the command is read: the file is looked at a few times a second, and a blow in the frames before that
    -- met the copy still armoured, its flinch let go before the blow was told, one run in two with the copies'
    -- steering of pull request 20, never before it: the look fell a frame earlier.)
    s:run(0.5)
    local played = field(field(theirs, "anim"), "played") or 0
    setState(copy, FLINCH)
    Session.enemyMove(g, "boss", HIT)
    swing(g, copy, select(1, Fake.health(copy)) - 50)
    s:run(0.5)
    check(count(g.sent, "^E D sp:boss .*CharacterState%.Hitreact%.State%.Normal$") >= 1, "a guest without it reports their copy's flinch")
    check(state(theirs) ~= FLINCH and (field(field(theirs, "anim"), "played") or 0) == played,
        "and the host's armoured boss doesn't play it")
    Session.enemyMove(g, "boss", nil)
    setState(copy, "None")
    allErrors(s)

    -- CoopBossArmor = Off: as the game has it, and its flinch goes to the guest as a move, as ever.
    s, h, g, theirs = fight("CoopBossArmor = Off\n")
    n = #h.sent
    setState(theirs, FLINCH)
    Session.enemyMove(h, "boss", HIT)
    s:run(0.3)
    check(state(theirs) == FLINCH, "CoopBossArmor = Off: a boss flinches as the game has it")
    check(sentSince(h, n, "Hit1%.Hit1"), "and its flinch goes to the guest as a move, as ever")
    check(count(h.logs, "flinch from hits as the game has it") >= 1, "and the log says so")
    allErrors(s)

    -- Not with you: the partner on another map, or down. A boss you fight alone flinches as the game has it.
    s, h, g, theirs = fight()
    g.map = "Map_Other"
    Session.moveTo(g, 90000, -70000)
    s:run(8)            -- (their ghost goes 3 s after their map does: GHOST_AWAY_S)
    setState(theirs, FLINCH)
    s:run(0.3)
    check(state(theirs) == FLINCH, "the partner on another map: a boss fought alone flinches as the game has it")
    allErrors(s)
    s, h, g, theirs = fight()
    Session.die(g)
    s:run(4)
    setState(theirs, FLINCH)
    s:run(0.3)
    check(state(theirs) == FLINCH, "the partner down: the same")
    -- Up again and in the fight again, a blow of theirs landed: it wears its armour once more. (It stayed off for the rest
    -- of the fight once the guest had died in it: the audit of 11-15.)
    Session.revive(g)
    s:run(4)
    setState(theirs, "None")
    local again = Session.enemyOn(g, "boss")
    swing(g, again, select(1, Fake.health(again)) - 50)
    s:run(3)
    setState(theirs, FLINCH)
    s:run(0.3)
    check(state(theirs) == "None", "the partner up again and back in the fight: its flinch is let go once more ("
        .. tostring(state(theirs)) .. ")")
    -- A fight begun alone that the partner then joins: they only watch it, and it keeps the game's flinches.
    s, h, g = pair("CoopBossArmor = On\n")
    g.map = "Map_Other"
    Session.moveTo(g, 90000, -70000)
    Session.moveTo(h, 2700, 3000)
    s:run(3)
    theirs = Session.enemyOn(h, "boss")
    h.hudLayout:RegisterBossHPBar(theirs)
    s:run(3)
    g.map = h.map
    Session.moveTo(g, 3300, 3000)
    s:run(4)
    setState(theirs, FLINCH)
    s:run(0.3)
    check(state(theirs) == FLINCH, "a fight begun alone that the partner joins: it keeps the game's flinches")
    allErrors(s)

    -- Alone (the partner gone): as the game has it.
    s, h, g, theirs = fight()
    g.cut = true
    s:run(15)
    setState(theirs, FLINCH)
    s:run(0.3)
    check(state(theirs) == FLINCH, "alone, a boss flinches as the game has it")
end

-- Partner hit sounds (PartnerHitSounds; a player report, 11-09: "it feels like they are hitting air"): a player's own hit on
-- an enemy goes to the others as HX, with what the game's hit-effect chooser was asked for it, and each plays the game's own
-- sound and blood for it on their copy of that enemy. Never the hitter's own, a hit on a player, a partner's blow or hit played
-- here, a killing blow told again, or a hit with no fresh effect asked; not in PvP, nor with it off; and a line that isn't one
-- is refused.
-- A copy's death to see (417). The players on 1.7.4: "enemies when they die they are like glitched for guest and finish combat
-- with e also glitched". The bench, run253: the host's word ended a copy at once by the game's kill, which plays no fall
-- (the host's own enemy 1.7 s in its death montage, the copy with its flinch stopped and none played), and a copy this
-- player was executing was ended half a second into the paired move. Now the copy plays its kind's death, found by the
-- flinch it is in or was last in, and an execution of this player's runs out, before the kill; with nothing to show it is
-- ended at once, as before.
local function aCopysDeath()
    part("a copy's death to see")
    local HIT = "/HuaShira/Characters/Monster/MaleThug/Anim/Throw/Hit/MaleThug_Throw_Hit_Light_F_R_Montage.MaleThug_Throw_Hit_Light_F_R_Montage"
    local function as(how)
        return (HIT:gsub("_Hit_Light_F_R_", how))
    end
    local DEAD, DOWN, AIR, AIRDEAD = as("_Dead_Normal_F_"), as("_Hit_Ground_F_"), as("_Hit_LaunchLoop_B_"), as("_Dead_Launch_B_")
    local BACK, NOBACK, BROKEN = as("_Hit_Knockback_B_"), as("_Dead_Normal_B_"), as("_Hit_NBreak_F_")
    local VICTIM = "/HuaShira/Characters/Monster/MaskAssassin/Anim/Execute/AM_MaskAssassin_BEd_Tang_M_01.AM_MaskAssassin_BEd_Tang_M_01"
    -- (A kind that keeps its deaths one folder up from its flinches, as the game's FemaleThug_Hoe does.)
    local HOE = "/HuaShira/Characters/Monster/FemaleThug/Anim/Hoe/Hit/Moontage/FemaleThug_Hoe_Hit_Light_B_L_Montage.FemaleThug_Hoe_Hit_Light_B_L_Montage"
    local HOEDEAD = "/HuaShira/Characters/Monster/FemaleThug/Anim/Hoe/Hit/FemaleThug_Hoe_Dead_Normal_B_Montage.FemaleThug_Hoe_Dead_Normal_B_Montage"
    -- The game's montages on one PC (not the death from behind: this kind has none).
    local function montages(pc)
        for _, x in ipairs({ { HIT, 1.0 }, { DEAD, 1.8 }, { DOWN, 1.0 }, { AIR, 1.0 }, { AIRDEAD, 1.6 }, { BACK, 1.0 }, { VICTIM, 4.0 },
            { BROKEN, 1.2 }, { HOE, 1.0 }, { HOEDEAD, 1.5 } }) do
            local m = Fake.object(pc, "AnimMontage")
            rawset(m, "__path", x[1])
            rawset(m, "__name", x[1]:match("([^.]+)$"))
            Fake.put(m, "GetPlayLength", function() return x[2] end)
            pc.found[x[1]] = m
        end
    end
    local function both(a, b)
        montages(a)
        montages(b)
    end
    local function dead(e)
        return field(e, "dead") == true
    end
    local function playing(e)
        local m = field(field(e, "anim"), "montage")
        return m and rawget(m, "__path") or nil
    end
    local function plays(e)
        return field(field(e, "anim"), "played") or 0
    end
    local function said(pc, words)
        return count(pc.logs, words)
    end
    -- The host's enemy flinches (its move told), and the host's own blow ends it t seconds on.
    local function flinchThenDeath(s, h, g, id, flinch, t)
        g.inbox[#g.inbox + 1] = "A sp:" .. id .. " - " .. flinch .. " 0.10 -"
        s:run(t)
        local was = playing(Session.enemyOn(g, id))
        swing(h, Session.enemyOn(h, id), 0)
        s:run(0.3)
        return was
    end

    local s, h, g = pair(nil, both)
    local copy = Session.enemyOn(g, "thug1")
    local was = flinchThenDeath(s, h, g, "thug1", HIT, 0.1)
    check(was == HIT and not dead(copy) and playing(copy) == DEAD and said(g, "Host says sp:thug1 died; its death is shown here first") == 1,
        "the host's enemy dies as its copy flinches here: the copy plays its kind's death first, not ended yet (" .. tostring(playing(copy)) .. ")")
    local n = plays(copy)
    g.inbox[#g.inbox + 1] = "K sp:thug1"
    s:run(0.2)
    local floor = g.env.PBZ.game.healthFloor(copy)
    local told = count(g.sent, "^[EQ] D sp:thug1")
    Fake.setHealth(copy, 1)         -- (a blow of this player's on it meanwhile: down to its floor)
    s:run(0.2)
    check(not dead(copy) and playing(copy) == DEAD and plays(copy) == n, "told dead again meanwhile: the show goes on, not begun again")
    -- (The game plays a flinch on it at that blow: taken off within a few frames, its fall on from where it was.)
    field(copy, "anim"):Montage_Play(g.found[HIT], 1.0, 0, 0.0, true)
    Fake.put(field(copy, "hit"), "state", "CharacterState.Hitreact.State.Normal")
    s:run(0.1)
    local back = field(field(copy, "anim"), "start")
    check(not dead(copy) and playing(copy) == DEAD and field(field(copy, "hit"), "state") == "None" and back ~= nil and back > 0.5 and back < 1.0,
        string.format("a flinch the game plays on it at that blow is taken off: its fall goes on from where it was (%.2f s in)", back or -1))
    check(floor == 1 and g.env.PBZ.game.healthFloor(copy) == 1 and count(g.sent, "^[EQ] D sp:thug1") == told,
        "its floor is kept through the show, and a blow of this player's on it meanwhile is told to nobody (floor " .. tostring(floor) .. ")")
    s:run(0.4)
    check(dead(copy) and field(copy, "realDeath") == true and said(g, "Host says sp:thug1 died; it dies here too") == 1,
        "a second after the word, the fall over, the copy is ended by the game's own death, once")
    -- One that never flinched: ended at once, as before.
    copy = Session.enemyOn(g, "thug2")
    swing(h, Session.enemyOn(h, "thug2"), 0)
    s:run(0.3)
    check(dead(copy) and said(g, "Host says sp:thug2 died; it dies here too") == 1 and said(g, "sp:thug2 died; its") == 0,
        "one with no flinch to go by: ended at once, as before")
    -- Its flinch over a moment ago, standing again: its kind is still known.
    copy = Session.enemyOn(g, "near")
    g.inbox[#g.inbox + 1] = "A sp:near - " .. HIT .. " 0.10 -"
    s:run(0.5)
    Fake.put(field(copy, "anim"), "montage", nil)
    swing(h, Session.enemyOn(h, "near"), 0)
    s:run(0.3)
    check(not dead(copy) and playing(copy) == DEAD, "one whose flinch ended a moment ago: its kind's death all the same")
    s:run(1.7)
    check(dead(copy), "and ended after it")
    allErrors(s)

    -- A flinch on the ground has nothing to fall from; one in the air has its own death; a kind with no death from behind
    -- has none shown.
    s, h, g = pair(nil, both)
    copy = Session.enemyOn(g, "thug1")
    flinchThenDeath(s, h, g, "thug1", DOWN, 0.1)
    check(dead(copy) and said(g, "sp:thug1 died; its") == 0, "a copy down on the ground already: ended at once")
    copy = Session.enemyOn(g, "thug2")
    flinchThenDeath(s, h, g, "thug2", AIR, 0.1)
    check(not dead(copy) and playing(copy) == AIRDEAD, "one in the air: its kind's death in the air (" .. tostring(playing(copy)) .. ")")
    copy = Session.enemyOn(g, "near")
    flinchThenDeath(s, h, g, "near", BACK, 0.1)
    check(not dead(copy) and playing(copy) == DEAD and g.found[NOBACK] == nil,
        "hit from behind, a kind with no death from behind here: its death from the front, and nothing loaded for a guess")
    s:run(2)
    check(dead(Session.enemyOn(g, "thug2")) and dead(copy), "both ended after their falls")
    allErrors(s)

    -- An execution of this player's own on the copy runs out before the kill, its own montage left as it is.
    s, h, g = pair(nil, both)
    copy = Session.enemyOn(g, "thug1")
    local anim = field(copy, "anim")
    anim:Montage_Play(g.found[VICTIM], 1.0, 0, 0.5, true)
    Fake.put(field(copy, "hit"), "state", "CharacterState.HitReact.State.Executing")
    n = plays(copy)
    swing(h, Session.enemyOn(h, "thug1"), 0)
    s:run(0.3)
    check(not dead(copy) and playing(copy) == VICTIM and plays(copy) == n
        and said(g, "Host says sp:thug1 died; its execution is shown here first") == 1,
        "a copy this player is executing as the host's word comes: left in the execution, nothing played over it")
    s:run(1.7)
    check(not dead(copy) and playing(copy) == VICTIM, "two seconds on: still in it")
    -- (The game ends the execution before the victim's montage would: its state for it gone, the copy getting up.)
    Fake.put(field(copy, "hit"), "state", "CharacterState.Hitreact.State.Getup")
    s:run(0.15)
    check(dead(copy) and said(g, "Host says sp:thug1 died; it dies here too") == 1,
        "the game ends the execution, a second and a half before its montage would: the copy is ended then, not left to get up")
    -- Its guard broken as the word comes (what this player's finishing strike starts from, the bench's run258): a
    -- standing flinch like any other.
    copy = Session.enemyOn(g, "thug2")
    was = flinchThenDeath(s, h, g, "thug2", BROKEN, 0.1)
    check(was == BROKEN and not dead(copy) and playing(copy) == DEAD, "a copy with its guard broken as the word comes: its kind's death first")
    s:run(2)
    check(dead(copy), "and ended after it")
    copy = Session.enemyOn(g, "near")
    was = flinchThenDeath(s, h, g, "near", HOE, 0.1)
    check(was == HOE and not dead(copy) and playing(copy) == HOEDEAD, "a kind whose deaths lie one folder up from its flinches: found there (" .. tostring(playing(copy)) .. ")")
    s:run(2)
    check(dead(copy), "and ended after it")
    allErrors(s)
end

local function partnerHitSounds()
    part("partner hit sounds")
    local CHOOSER_FN = "/PBZCombatAsset/Prototypes/Hitreact/BP_HitEffectPlayer_Chooser.BP_HitEffectPlayer_Chooser_C:GetEffectData"
    local ON = "PartnerHitSounds = On\n"
    -- (The hero's blade, a light hit on flesh, as the bench saw the chooser asked.)
    local KIND, STRENGTH = "HitReact.AttackType.Physical.Slash.TangBlade.Player", "Hitreact.Strength.Income.Normal.Light"
    local MATERIAL = "Hitreact.Material.Meat"
    local function lineFor(id)
        return "HX sp:" .. id .. " Physical.Slash.TangBlade.Player Normal.Light Meat"
    end
    local LINE = lineFor("thug1")
    local BONE = "spine_04"
    local BLOOD = { "/PBZVFXPack/Blood/NS_Blood_Hit_A.NS_Blood_Hit_A", "/PBZVFXPack/Blood/NS_Blood_Hit_B.NS_Blood_Hit_B" }
    local function isBlood(path)
        return path == BLOOD[1] or path == BLOOD[2]
    end
    local BASE = "/Script/PBZCombatAsset.HitreactEffectPlayer_PBZBase"       -- (the choosers' class: GetEffectData is its)
    local COMMON = "/PBZCombatAsset/Config/HitReact/HitEffect/PBZ_HitreactEffectPlayer_Chooser.PBZ_HitreactEffectPlayer_Chooser"
    local HIT_EV = "/Game/Wwise/Events/Combat/SFX_Hit_Slash.SFX_Hit_Slash"

    -- A chooser of the game's: what it was asked (by: whose it is), and a sound and two blood systems for any hit. As UE4SS
    -- runs a Blueprint hook for the mod's own calls too, the hook on GetEffectData runs once it has answered, with what it got.
    local function newChooser(pc, e, by)
        local c = Fake.object(pc, "BP_HitEffectPlayer_Chooser_C")
        Fake.put(c, "GetEffectData", function(self, kind, strength, material, particles, _, _, out)
            pc.asked[#pc.asked + 1] = { on = e, by = by, kind = kind.TagName:ToString(), strength = strength.TagName:ToString(),
                material = material.TagName:ToString() }
            out.HitSound = pc.hitSound
            particles.Particles = pc.blood
            local function param(v)
                return { get = function() return v end }
            end
            for _, fn in ipairs(pc.hooks[CHOOSER_FN] or {}) do
                fn(param(self), param(kind), param(strength), param(material))
            end
        end)
        return c
    end

    -- The game's side of it on one PC, as much as hitfx.lua reads: the chooser's function (the hook goes on it) and class,
    -- each enemy's hit-react component with a chooser of its own and its body's bone, that bone on its mesh, and the sound
    -- engine. What the mod plays there is kept: pc.asked, pc.sounds, and where each blood went.
    local function hearing(pc)
        local class = Fake.object(pc, "Class")
        pc.found[CHOOSER_FN] = Fake.object(pc, "Function")
        pc.found[BASE] = Fake.object(pc, "Class")
        pc.found["/Script/SGameCombatSystem.HitreactComponent"] = class
        pc.asked, pc.sounds, pc.bloodAt = {}, {}, {}
        pc.hitSound = Fake.object(pc, "AkAudioEvent")
        local ak = Fake.object(pc, "AkGameplayStatics")
        Fake.put(ak, "PostEvent", function(_, event, actor)
            if event == pc.hitSound then
                pc.sounds[#pc.sounds + 1] = actor
            end
            return 1
        end)
        pc.found["/Script/AkAudio.Default__AkGameplayStatics"] = ak
        -- (413) The sound as an asset of the game's, of the sound events' class and no other.
        rawset(pc.hitSound, "__path", HIT_EV)
        Fake.put(pc.hitSound, "IsA", function(_, cls) return cls == pc.env.StaticFindObject("/Script/AkAudio.AkAudioEvent") end)
        -- (413) The sound engine's call for a sound at a place, as this PC's build of it takes it: the world's object after
        -- the turn, or (akNamed) a name for the event before that. Called the other way it is refused, as UE4SS refuses
        -- a value of the wrong kind.
        pc.soundsAt = {}
        Fake.put(ak, "PostEventAtLocation", function(_, event, where, turn, a4, a5)
            local world = a4
            if pc.akNamed then
                if type(a4) ~= "string" then
                    error("PostEventAtLocation: EventName takes a string")
                end
                world = a5
            end
            if type(world) ~= "table" then
                error("PostEventAtLocation: WorldContextObject takes an object")
            end
            if event == pc.hitSound then
                pc.soundsAt[#pc.soundsAt + 1] = { at = where, turn = turn, world = world }
            end
            return 1
        end)
        pc.blood = {}
        for i, path in ipairs(BLOOD) do
            local system = Fake.object(pc, "NiagaraSystem")
            rawset(system, "__path", path)
            pc.blood[i] = { Particle = system }
        end
        local niagara = pc.found["/Script/Niagara.Default__NiagaraFunctionLibrary"]
        local spawn = field(niagara, "SpawnSystemAttached")
        Fake.put(niagara, "SpawnSystemAttached", function(self, system, on, socket, where, ...)
            local made = spawn(self, system, on, socket, where, ...)
            pc.bloodAt[#pc.effectsOn] = where
            return made
        end)
        for _, e in ipairs(pc.enemies) do
            local f = rawget(e, "__fields")
            Fake.put(f.hit, "EffectPlayer", newChooser(pc, e, "own"))
            Fake.put(f.hit, "GetMainBodyData", function(_, body) body.bone = Fake.name(BONE) end)
            Fake.put(e, "GetComponentByClass", function(_, c) return c == class and f.hit or nil end)
            Fake.put(f.Mesh, "GetSocketLocation", function() return { X = f.loc.X, Y = f.loc.Y, Z = f.loc.Z + 120 } end)
        end
        pc.mark = { asked = 0, sounds = 0, fx = #pc.effectsOn, sent = #pc.sent }
    end

    -- The game asks this PC's chooser for its own player's hit: the hook gets the three tags as the game passes them.
    local function struck(pc, kind, strength, material)
        local function tag(name)
            return { get = function() return { TagName = Fake.name(name) } end }
        end
        for _, fn in ipairs(pc.hooks[CHOOSER_FN] or {}) do
            fn({ get = function() return nil end }, tag(kind or KIND), tag(strength or STRENGTH), tag(material or MATERIAL))
        end
    end
    local function hit(pc, e)
        swing(pc, e, select(1, Fake.health(e)) - 30)
    end
    -- Health lost with no hit of this player's: a bleed tick, say.
    local function bleed(pc, id)
        local e = Session.enemyOn(pc, id)
        Fake.setHealth(e, select(1, Fake.health(e)) - 30)
    end
    -- Frame by frame till it's so (a second at most).
    local function soon(s, ready)
        for _ = 1, 60 do
            if ready() then
                return
            end
            s:run(1 / 60)
        end
    end

    -- Since each PC's mark: the HX it sent, and what it played on one enemy (or on any, e nil): its chooser's asks, the hit
    -- sounds posted on it, the blood on its body.
    local function mark(...)
        for _, pc in ipairs({ ... }) do
            pc.mark = { asked = #pc.asked, sounds = #pc.sounds, fx = #pc.effectsOn, sent = #pc.sent }
        end
    end
    local function sent(pc)
        local lines = {}
        for i = pc.mark.sent + 1, #pc.sent do
            if pc.sent[i]:find("^Q HX ") then
                lines[#lines + 1] = pc.sent[i]:sub(3)
            end
        end
        return lines
    end
    local function told(pc, pattern)
        local n = 0
        for i = pc.mark.sent + 1, #pc.sent do
            n = n + (pc.sent[i]:find(pattern) and 1 or 0)
        end
        return n
    end
    local function played(pc, e)
        local asks, sounds, blood = 0, 0, 0
        for i = pc.mark.asked + 1, #pc.asked do
            asks = asks + ((e == nil or pc.asked[i].on == e) and 1 or 0)
        end
        for i = pc.mark.sounds + 1, #pc.sounds do
            sounds = sounds + ((e == nil or pc.sounds[i] == e) and 1 or 0)
        end
        local mesh = e and field(e, "Mesh")
        for i = pc.mark.fx + 1, #pc.effectsOn do
            local fx = pc.effectsOn[i]
            blood = blood + ((isBlood(fx.path) and (e == nil or fx.on == mesh)) and 1 or 0)
        end
        return asks, sounds, blood
    end
    local function none(pc)
        local asks, sounds, blood = played(pc)
        return asks + sounds + blood == 0
    end
    -- One effect, on that enemy alone: one ask, one sound, each blood once.
    local function once(pc, e)
        local asks, sounds, blood = played(pc, e)
        local allAsks, allSounds, allBlood = played(pc)
        return asks == 1 and sounds == 1 and blood == #BLOOD and allAsks == 1 and allSounds == 1 and allBlood == #BLOOD
    end
    -- Its blood at its body's bone, moved 25 cm toward the hitter's figure.
    local function landed(pc, e, figure)
        local f, mesh, n, right = rawget(e, "__fields"), field(e, "Mesh"), 0, figure ~= nil
        for i = pc.mark.fx + 1, #pc.effectsOn do
            local fx, w = pc.effectsOn[i], pc.bloodAt[i]
            if fx.on == mesh then
                n = n + 1
                right = right and fx.socket == BONE and w ~= nil and math.abs(gap(w, f.loc) - 25) < 0.01
                    and gap(w, at(figure)) < gap(f.loc, at(figure))
            end
        end
        return n == #BLOOD and right
    end
    local function hearingBoth(a, b)
        hearing(a)
        hearing(b)
    end

    local s, h, g = pair(ON, hearingBoth)
    local theirs, copy = Session.enemyOn(h, "thug1"), Session.enemyOn(g, "thug1")
    check(#(h.hooks[CHOOSER_FN] or {}) == 1 and #(g.hooks[CHOOSER_FN] or {}) == 1,
        "the hook on the game's hit-effect chooser goes in on each PC, once, before the first hit")
    -- A guest's own hit: the game asks its chooser (the hook), then the mod counts the hit (its report).
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    local went = sent(g)
    check(#went == 1 and went[1] == LINE and #sent(h) == 0,
        "a guest's own hit goes out once, with what its chooser was asked, and nothing comes back (" .. tostring(went[1]) .. ")")
    local asked = h.asked[#h.asked] or {}
    check(select(1, played(h)) == 1 and asked.on == theirs and asked.kind == KIND and asked.strength == STRENGTH
        and asked.material == MATERIAL, "the host asks that enemy's own chooser the same, the game's whole tags put back ("
        .. tostring(asked.kind) .. " " .. tostring(asked.strength) .. " " .. tostring(asked.material) .. ")")
    local _, sounds = played(h, theirs)
    local _, allSounds = played(h)
    check(sounds == 1 and allSounds == 1 and none(g), "and plays its sound on that enemy, once; the guest, whose game played its own, none")
    check(landed(h, theirs, net(h).ghost), "and its blood on that body, at its bone, 25 cm toward the guest's figure")
    -- The host's own hit: an enemy its game runs loses health just after a move of the host's, the effect asked.
    s:run(0.5)
    mark(h, g)
    struck(h)
    hit(h, theirs)
    s:run(0.5)
    went = sent(h)
    check(#went == 1 and went[1] == LINE and #sent(g) == 0,
        "the host's own hit goes out too: a drop on an enemy it runs, with a move of its own just before (" .. tostring(went[1]) .. ")")
    check(once(g, copy) and landed(g, copy, net(g).ghost) and none(h),
        "the guest plays it on its copy, once, sound and blood; the host none on its own enemy")
    -- A drop with a move and no effect asked for it: bleeding or poison after a swing, say.
    s:run(0.5)
    mark(h, g)
    hit(g, copy)
    s:run(0.5)
    hit(h, theirs)
    s:run(0.5)
    check(#sent(g) == 0 and #sent(h) == 0 and none(h) and none(g),
        "a drop with a move but no effect asked (bleeding, poison): nothing goes, from a guest or the host")
    -- An effect asked longer ago than the 0.4 s it waits for its hit to be counted isn't that hit's.
    mark(h, g)
    struck(g)
    struck(h)
    s:run(0.5)
    hit(g, copy)
    s:run(0.5)
    hit(h, theirs)
    s:run(0.5)
    check(#sent(g) == 0 and #sent(h) == 0 and none(h) and none(g), "an effect asked over 0.4 s before the hit is counted: nothing goes")
    -- The chooser asked for a hit on a player (an enemy's on this one), or with no attack type: never this player's hit.
    mark(h, g)
    struck(g, KIND, STRENGTH, "Hitreact.Material.PlayerMeat")
    hit(g, copy)
    s:run(0.5)
    struck(g, "None", STRENGTH, MATERIAL)
    hit(g, copy)
    s:run(0.5)
    struck(h, KIND, STRENGTH, "Hitreact.Material.PlayerMeat")
    hit(h, theirs)
    s:run(0.5)
    check(#sent(g) == 0 and #sent(h) == 0 and none(h) and none(g), "the chooser asked for a hit on a player, or with no attack type: never sent")
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    check(#sent(g) == 1 and once(h, theirs), "and after all that, a fresh one still goes, and plays")
    -- One effect asked is one hit's: two hits counted on it (the second with none asked for it, bleeding say) send one.
    s:run(0.5)
    local near = Session.enemyOn(g, "near")
    mark(h, g)
    struck(g)
    hit(g, copy)
    hit(g, near)
    s:run(0.5)
    local one = #sent(g)
    s:run(0.5)
    mark(h, g)
    struck(g)
    struck(g)
    hit(g, copy)
    hit(g, near)
    s:run(0.5)
    local _, onThug = played(h, theirs)
    local _, onNear = played(h, Session.enemyOn(h, "near"))
    check(one == 1 and #sent(g) == 2 and onThug == 1 and onNear == 1,
        "one effect asked, two hits counted: one goes; two asked, two go, one on each enemy (" .. one .. ", " .. #sent(g) .. ")")
    -- A partner's hit played here runs this PC's hook on the chooser too (UE4SS hooks the mod's own calls), and isn't this
    -- player's: a player who has just moved plays one, then a drop with no effect of their own follows. Nothing goes back.
    s:run(0.5)
    mark(h, g)
    h.env.PBZ.game.noteLocalMove()
    struck(g)
    hit(g, copy)
    soon(s, function() return #h.sounds > h.mark.sounds end)
    bleed(h, "thug2")
    s:run(0.5)
    check(once(h, theirs) and #sent(h) == 0,
        "a host that has just moved plays a guest's hit, then a drop with no effect of its own: nothing goes back")
    s:run(0.5)
    mark(h, g)
    g.env.PBZ.game.noteLocalMove()
    struck(h)
    hit(h, theirs)
    soon(s, function() return #g.sounds > g.mark.sounds end)
    bleed(g, "thug2")
    s:run(0.5)
    check(once(g, copy) and #sent(g) == 0, "and a guest that has just moved, playing the host's hit: the same")
    -- Both at once: the host's own hit, landing as it plays the guest's, goes with its own effect, not the guest's.
    s:run(0.5)
    mark(h, g)
    struck(g, KIND, "Hitreact.Strength.Income.Normal.Heavy", MATERIAL)
    hit(g, copy)
    soon(s, function() return count(h.inbox, "^HX ") > 0 end)
    struck(h)
    hit(h, Session.enemyOn(h, "thug2"))
    s:run(0.5)
    went = sent(h)
    check(#went == 1 and went[1] == lineFor("thug2"),
        "the host's own hit, landing as it plays the guest's, goes with its own effect (" .. tostring(went[1]) .. ")")
    -- A guest's blow written on the host's enemy isn't the host's hit, though the host has an effect of its own waiting (a
    -- swing that took no health) and has just moved.
    s:run(0.5)
    mark(h, g)
    h.env.PBZ.game.noteLocalMove()
    struck(h)
    struck(g)
    hit(g, near)
    s:run(0.5)
    local _, twice = played(g, near)
    check(#sent(h) == 0 and #sent(g) == 1 and twice == 0, "a guest's blow on an enemy, the host with an effect of its own "
        .. "waiting and a move: the host sends nothing, and the guest doesn't hear its own hit twice")
    -- The host's own hit on an enemy in the same round as a guest's blow on it: the blow comes off, the hit still counts.
    s:run(0.5)
    mark(h, g)
    struck(g)
    hit(g, copy)
    soon(s, function() return count(h.inbox, "^D sp:thug1 ") > 0 end)
    struck(h)
    hit(h, theirs)
    s:run(0.5)
    went = sent(h)
    check(#went == 1 and went[1] == LINE and #sent(g) == 1,
        "the host's own hit on an enemy in the same round as a guest's blow on it: it goes, once (" .. tostring(went[1]) .. ")")
    -- Whose chooser is asked: the body's override if it's of the choosers' class, else the body's own, else the game's common
    -- one. With that class not found, nothing plays.
    s:run(0.5)
    local comp = field(theirs, "hit")
    local own = field(comp, "EffectPlayer")
    local function askedBy()
        mark(h)
        h.inbox[#h.inbox + 1] = LINE
        s:run(0.1)
        local asks, heard = played(h)
        return asks == 1 and heard == 1 and (h.asked[#h.asked] or {}).by or "-"
    end
    local override = newChooser(h, theirs, "override")
    Fake.put(comp, "HitEffectPlayerOverride", override)
    local first = askedBy()
    Fake.put(override, "IsA", function() return false end)
    local passed = askedBy()
    Fake.put(comp, "HitEffectPlayerOverride", nil)
    Fake.put(own, "IsA", function() return false end)
    h.found[COMMON] = newChooser(h, nil, "common")
    local common = askedBy()
    Fake.put(own, "IsA", nil)
    h.found[COMMON] = nil
    check(first == "override" and passed == "own" and common == "common", "an override of another class is passed over for "
        .. "the body's own chooser, which plays once; one of its class is asked first; with neither, the game's common one ("
        .. first .. ", " .. passed .. ", " .. common .. ")")
    local base, errors = h.found[BASE], #h.errors
    h.found[BASE] = nil
    mark(h)
    h.inbox[#h.inbox + 1] = LINE
    s:run(0.1)
    h.found[BASE] = base
    check(none(h) and #h.errors == errors, "the choosers' class not found: nothing plays, and no script error")
    -- Lines that aren't an HX: refused, and nothing plays.
    s:run(1.1)
    mark(h, g)
    local function refused(pc)
        return (pc.env.PBZ.hitfx or {}).refused or 0
    end
    local before = refused(h)
    local bad = { "HX sp:thug1 Physical.Slash.TangBlade.Player Normal.Light", LINE .. " Meat",
        "HX sp:thug1 Physical.Slash;TangBlade.Player Normal.Light Meat", LINE .. ".Wet", LINE .. "\195\169",
        "HX sp:thug1 " .. string.rep("Slash", 17) .. " Normal.Light Meat" }
    for _, line in ipairs(bad) do
        h.inbox[#h.inbox + 1] = line
        s:run(0.1)
    end
    check(none(h) and refused(h) - before == #bad, "lines that aren't one (3 or 5 fields, odd characters, a dotted material, "
        .. "a field over 80 characters): refused, nothing played (" .. (refused(h) - before) .. " of " .. #bad .. ")")
    -- One enemy's effects at least 50 ms apart, and at most 24 a second in all.
    mark(h)
    h.inbox[#h.inbox + 1] = LINE
    h.inbox[#h.inbox + 1] = LINE
    s:run(0.1)
    _, sounds = played(h, theirs)
    check(sounds == 1, "two for one enemy in the same frame: one plays (" .. sounds .. ")")
    s:run(1.1)
    mark(h)
    before = refused(h)
    for _ = 1, 10 do
        for _, id in ipairs({ "thug1", "thug2", "near" }) do
            h.inbox[#h.inbox + 1] = lineFor(id)
        end
        s:run(4 / 60)
    end
    _, allSounds = played(h)
    check(allSounds == 24 and refused(h) - before == 6,
        "30 in 0.6 s, on three enemies: 24 play, the rest are refused (" .. allSounds .. " played, " .. (refused(h) - before) .. " refused)")
    -- Off on one PC (the hitsounds command, as the ini's row): off on the host, the guest's hits still go and play nothing
    -- there; off on the guest, its hits don't go.
    Session.command(h, "hitsounds off")
    s:run(0.6)
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    check(#sent(g) == 1 and none(h), "PartnerHitSounds off on the host: the guest's hit still goes, and nothing plays there")
    Session.command(h, "hitsounds on")
    Session.command(g, "hitsounds off")
    s:run(0.6)
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    check(#sent(g) == 0 and none(h), "off on the guest: its hits don't go")
    -- Played only on an enemy within 60 m of this player: the host 75 m from the one the guest is by, 42 m from another.
    Session.moveTo(h, -6000, 300)
    s:run(2)
    mark(h)
    local known = h.env.PBZ.coop.enemyActor("sp:thug1") == theirs
    h.inbox[#h.inbox + 1] = LINE
    h.inbox[#h.inbox + 1] = lineFor("thug2")
    s:run(0.2)
    _, sounds = played(h, theirs)
    local _, inReach = played(h, Session.enemyOn(h, "thug2"))
    check(known and sounds == 0 and inReach == 1, "an enemy 75 m from this player: not played there; one 42 m off is")
    allErrors(s)

    -- A killing blow told again (no K back yet: the host's answer held up here) is no new hit. The first one goes; told
    -- again with an effect waiting then, nothing more does.
    s, h, g = pair(ON, hearingBoth)
    copy = Session.enemyOn(g, "thug1")
    local hostHandlers = h.env.PBZ.coop.handlers
    local answer = hostHandlers.D
    hostHandlers.D = function() end
    mark(h, g)
    struck(g)
    swing(g, copy, 1)       -- (onto its floor: the killing blow)
    s:run(0.65)
    local firstBlow = #sent(g)
    struck(g)
    s:run(0.4)              -- (told again 0.8 s after the first)
    local again = told(g, "^E D sp:thug1 0%.0 0%.0 L ")
    hostHandlers.D = answer
    check(firstBlow == 1 and #sent(g) == 1 and again >= 1, "a killing blow goes out once; told again with an effect waiting, "
        .. "nothing more goes (" .. firstBlow .. ", " .. #sent(g) .. ", told again " .. again .. ")")
    allErrors(s)

    -- Two players 37 m apart: the enemy by the guest is its game's to run (handover), the host still within 60 m of it.
    s, h, g = pair(ON, hearingBoth)
    Session.moveTo(h, -2000, 300)
    Session.moveTo(g, 1700, 300)
    s:run(4)
    theirs, copy = Session.enemyOn(h, "thug1"), Session.enemyOn(g, "thug1")
    local handed = net(h).guestRuns["sp:thug1"] == true and net(g).mine["sp:thug1"] == true
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    went = sent(g)
    check(handed and #went == 1 and went[1] == LINE and once(h, theirs),
        "two players 37 m apart, an enemy the guest's game runs: the guest's hit on it goes out, and the host plays it on its copy")
    -- Its line taking the host's copy down isn't the host's hit, though an effect of the host's waits and it has just moved.
    s:run(0.5)
    mark(h, g)
    local was = select(1, Fake.health(theirs))
    h.env.PBZ.game.noteLocalMove()
    struck(h)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    check(select(1, Fake.health(theirs)) < was - 0.5 and #sent(h) == 0 and #sent(g) == 1,
        "and its line taking the host's copy down, an effect of the host's waiting and a move: the host sends nothing")
    -- The host's hit on it, written on the guest's (a D), isn't sent back, though an effect of the guest's waits and it has
    -- just moved.
    s:run(0.5)
    mark(h, g)
    g.env.PBZ.game.noteLocalMove()
    struck(g)
    struck(h)
    hit(h, theirs)
    s:run(0.5)
    check(#sent(h) == 1 and #sent(g) == 0 and once(g, copy),
        "the host's hit on it goes out and the guest plays it; the blow written there isn't sent back, an effect of its own waiting")
    allErrors(s)

    -- Left out of the ini: off, as before. No hook, nothing goes, and an HX that comes plays nothing.
    s, h, g = pair(nil, hearingBoth)
    copy = Session.enemyOn(g, "thug1")
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    h.inbox[#h.inbox + 1] = LINE
    s:run(0.2)
    check(h.hooks[CHOOSER_FN] == nil and g.hooks[CHOOSER_FN] == nil and #sent(g) == 0 and none(h),
        "the row left out of the ini: no hook, nothing goes, and an HX that comes plays nothing")
    allErrors(s)

    -- In PvP, hits are real: nothing goes either way, and an HX that comes plays nothing.
    s, h, g = pair(ON .. "PvP = On\n", hearingBoth)
    theirs, copy = Session.enemyOn(h, "thug1"), Session.enemyOn(g, "thug1")
    mark(h, g)
    struck(g)
    hit(g, copy)
    s:run(0.5)
    struck(h)
    hit(h, theirs)
    s:run(0.5)
    h.inbox[#h.inbox + 1] = LINE
    g.inbox[#g.inbox + 1] = LINE
    s:run(0.2)
    check(net(h).pvp == true and net(g).pvp == true and #sent(g) == 0 and #sent(h) == 0 and none(h) and none(g),
        "in PvP: nothing goes from either, and an HX that comes plays nothing")
    allErrors(s)

    -- Four players: one guest's hit is played by the host and the other two guests, each on their copy.
    s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES, ON)
    for _, pc in ipairs(s.pcs) do
        hearing(pc)
    end
    s:run(4)
    spread(s)
    s:run(3)
    h = s.pcs[1]
    local a, b, c = s.pcs[2], s.pcs[3], s.pcs[4]
    mark(h, a, b, c)
    struck(a)
    hit(a, Session.enemyOn(a, "thug1"))
    s:run(0.5)
    went = sent(a)
    check(#went == 1 and went[1] == LINE and #sent(h) + #sent(b) + #sent(c) == 0,
        "four players: a guest's hit goes out once, and nobody else sends one (" .. tostring(went[1]) .. ")")
    check(once(h, Session.enemyOn(h, "thug1")) and once(b, Session.enemyOn(b, "thug1")) and once(c, Session.enemyOn(c, "thug1"))
        and none(a), "the host and the other two guests each play it on their copy, once; the one who hit, none")
    allErrors(s)

    -- The guard (413): each kind of call into the game leaves a note in a file while its first few of a session run, and
    -- a session that finds one left does that kind another way, or no more.
    do
        local FILE = "hitfx_guard.txt"
        local function guardOf(pc)
            return pc.env.PBZ.hitfx.guard or { way = {}, skip = {} }     -- (none in scripts before 413)
        end
        -- Two players, the host's guard file as a session before left it (nil: none), and its sound engine's build.
        local function after(text, named)
            local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, ON, nil, function(pc, i)
                if i == 1 then
                    pc.files[FILE], pc.akNamed = text, named
                end
            end)
            hearingBoth(t.pcs[1], t.pcs[2])
            t:run(4)
            Session.moveTo(t.pcs[1], 0, 0)
            Session.moveTo(t.pcs[2], 500, 0)
            t:run(2)
            return t, t.pcs[1], t.pcs[2]
        end
        -- A partner's hit on thug1 comes to the host: its chooser's asks, the sounds on the enemy, the sounds at a place,
        -- the blood.
        local function partnerHit(t, pc)
            local e = Session.enemyOn(pc, "thug1")
            mark(pc)
            local before = #pc.soundsAt
            pc.inbox[#pc.inbox + 1] = LINE
            t:run(0.1)
            local asks, sounds, blood = played(pc, e)
            return asks, sounds, #pc.soundsAt - before, blood, e
        end
        local function said(pc, words)
            return count(pc.logs, "Partner hit sounds: the last session ended inside " .. words)
        end

        local t, hh, gg = after(nil)
        local asks, sounds, placed, blood = partnerHit(t, hh)
        local file = hh.files[FILE] or ""
        check(asks == 1 and sounds == 1 and placed == 0 and blood == #BLOOD and file:find("^epoch 1\n") ~= nil
            and file:find("\nbusy ask Physical.Slash.TangBlade.Player Normal.Light Meat\n", 1, true) ~= nil
            and file:find("\nbusy hit " .. HIT_EV .. "\n", 1, true) ~= nil
            and file:find("\nbusy blood " .. BLOOD[1] .. "\n", 1, true) ~= nil
            and file:find("\nbusy blood " .. BLOOD[2] .. "\n", 1, true) ~= nil,
            "the guard: a partner's hit plays as before, and while its calls are new to the session each has its note in "
            .. "the guard's file (" .. (file:gsub("\n", " | ")) .. ")")
        t:run(2.5)
        check(hh.files[FILE] == nil and gg.files[FILE] == nil,
            "2 s on the notes are out: no file while nothing is held back, and none on the PC that played nothing")
        for _ = 1, 7 do
            partnerHit(t, hh)
            t:run(2.4)
        end
        local opens = hh.opens[FILE]
        asks, sounds, placed, blood = partnerHit(t, hh)
        t:run(2.5)
        check(asks == 1 and sounds == 1 and blood == #BLOOD and hh.opens[FILE] == opens and hh.files[FILE] == nil,
            "after a kind's first six of a session its calls leave no more notes: the file isn't touched again ("
            .. tostring(hh.opens[FILE]) .. " opens, " .. tostring(opens) .. " before)")
        -- A sound that isn't one of the sound events' class is never handed to the sound engine; the blood still plays.
        Fake.put(hh.hitSound, "IsA", function() return false end)
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(asks == 1 and sounds == 0 and placed == 0 and blood == #BLOOD,
            "what the chooser gives for a sound isn't of the sound events' class: not posted, the blood plays ("
            .. sounds .. " sounds, " .. placed .. " at a place, " .. blood .. " blood)")
        allErrors(t)

        -- The last session ended inside a hit's sound on an enemy: at the enemy's place from now on.
        t, hh, gg = after("epoch 1\nbusy hit " .. HIT_EV .. "\n")
        local e
        asks, sounds, placed, blood, e = partnerHit(t, hh)
        local where = hh.soundsAt[#hh.soundsAt] or {}
        check(guardOf(hh).way.hit == 2 and asks == 1 and sounds == 0 and placed == 1 and blood == #BLOOD
            and where.world == e and where.at ~= nil and gap(where.at, at(e)) < 1 and guardOf(hh).placeArgs == 4,
            "a session ended inside a partner's hit sound: the next posts it at the enemy's place, by the call that makes "
            .. "nothing on the body, and the blood as before (" .. sounds .. " on it, " .. placed .. " at its place)")
        file = hh.files[FILE] or ""
        check(said(hh, "a partner's hit sound %(SFX_Hit_Slash%)%. A partner's hit sounds are played at their place") == 1
            and file:find("\nhit 2\n", 1, true) ~= nil and guardOf(gg).way.hit == 1,
            "it says so in the log once, keeps it in its file, and the other PC is as it was (" .. (file:gsub("\n", " | ")) .. ")")
        t:run(2.5)
        check(hh.files[FILE] == "epoch 1\nhit 2\n", "the note of the new way's first call goes like any other: the file "
            .. "keeps the step alone (" .. tostring(hh.files[FILE]):gsub("\n", " | ") .. ")")
        allErrors(t)
        -- The same on a sound engine whose call for a place takes a name for the event first.
        t, hh, gg = after("epoch 1\nbusy hit " .. HIT_EV .. "\n", true)
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(sounds == 0 and placed == 1 and guardOf(hh).placeArgs == 5,
            "a sound engine whose call for a place takes a name for the event too: found by trying, and posted (" .. placed .. ")")
        allErrors(t)
        -- Ended inside that call too: no hit sounds at all, the blood still.
        t, hh, gg = after("epoch 1\nhit 2\nbusy hit " .. HIT_EV .. "\n")
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(guardOf(hh).way.hit == 3 and asks == 1 and sounds == 0 and placed == 0 and blood == #BLOOD
            and said(hh, "a partner's hit sound %(SFX_Hit_Slash%)%. A partner's hit sounds are off on this PC") == 1,
            "a session ended inside the call at a place too: no hit sounds on this PC any more, the blood plays")
        allErrors(t)
        -- Ended inside the blood: the sound alone. Inside the chooser's ask: neither, and nothing is asked.
        t, hh, gg = after("epoch 1\nbusy blood " .. BLOOD[1] .. "\n")
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(asks == 1 and sounds == 1 and blood == 0 and said(hh, "the blood of a partner's hit %(NS_Blood_Hit_A%)") == 1,
            "a session ended inside a hit's blood: the sound alone from then on (" .. sounds .. " sound, " .. blood .. " blood)")
        allErrors(t)
        t, hh, gg = after("epoch 1\nbusy ask Physical.Slash.TangBlade.Player Normal.Light Meat\n")
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(asks == 0 and sounds == 0 and placed == 0 and blood == 0 and guardOf(hh).way.ask == 2,
            "a session ended inside the game's choice of a hit's effects: nothing is asked or played there any more")
        -- The host's own hits still go out for the others.
        mark(hh, gg)
        struck(hh)
        hit(hh, Session.enemyOn(hh, "thug1"))
        t:run(0.5)
        check(#sent(hh) == 1 and once(gg, Session.enemyOn(gg, "thug1")), "its own hits still go, and the partner plays them")
        allErrors(t)
        -- A file of another epoch counts for nothing and goes; one with rubbish in it is read without an error.
        t, hh, gg = after("epoch 0\nhit 3\nask 2\nbusy blood " .. BLOOD[1] .. "\n")
        local gone = hh.files[FILE] == nil
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(gone and asks == 1 and sounds == 1 and blood == #BLOOD and said(hh, "") == 0,
            "a guard file of another epoch (these calls made another way since): nothing of it counts, and it is gone")
        allErrors(t)
        t, hh, gg = after("epoch 1\nhit 1e400\nswing x\n\nbusy\nbusy nothing here\nask 9\nlearn\n")
        asks, sounds, placed, blood = partnerHit(t, hh)
        check(asks == 1 and sounds == 1 and blood == #BLOOD and count(hh.logs, "the guard's file can't be read") == 0,
            "a guard file with rubbish in it: read without an error, what it can't mean left out")
        allErrors(t)
    end

    check(Session.shippedIni():match("\nPartnerHitSounds = ([^\r\n]+)") == "On", "the ini as it ships has PartnerHitSounds = On")
end

-- Partner swing sounds (PartnerHitSounds; a player report on 1.7.1, three players: "they want air swings (non-hit)
-- audible"): a swing's whoosh is a weapon-sound step in its attack's ability timeline, which a partner's figure never runs
-- (it plays their montages). Each PC reads those steps for the weapons a partner holds, from the game's own data, and plays
-- each one's sound on the figure as its montage gets there: once, on time, the weapon's own sound, from a timeline of its
-- own or a parent's, an owning ability's or the Phantom Edge's. Not for a move cut short or ended before its step, nor a
-- step long past when the move came (held or late); not off, far off or in PvP; never on the swinger's own PC; and with
-- nothing new sent.
local function partnerSwingSounds()
    part("partner swing sounds")
    local ON = "PartnerHitSounds = On\n"
    local SWORD, CANNON = "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", "/PBZCombatAsset/ActorData/Weapon/Cannon.Cannon"
    local function move(name)
        return "/PBZCombatAsset/ActorData/Move/" .. name .. "." .. name
    end
    local A1, A2, B1, D1, C1, LOOK = move("SwA1"), move("SwA2"), move("SwB1"), move("SwD1"), move("CnC1"), move("Look")
    local E1, E2, F1 = move("SwE1"), move("SwE2"), move("SwF1")
    local LIGHT, HEAVY, FIRE = "Weapon.Sound.Swing.Light", "Weapon.Sound.Swing.Heavy", "Weapon.Sound.Cannon.Fire"
    local function eventPath(name)
        return "/Game/Wwise/Events/Combat/" .. name .. "." .. name
    end
    local LIGHT_EV, HEAVY_EV, FIRE_EV = eventPath("SFX_Swing_Sword_Light"), eventPath("SFX_Swing_Sword_Heavy"),
        eventPath("SFX_Cannon_Fire")
    local SOUND_FIELD = "Sound_21_D6348F8E4FAA4263E62C63AFE8750487"
    -- (Play-sound steps of the game's kinds, as the bench read them: a shout, a whoosh... and ones that mustn't play.)
    local VO_EV, WAVE_EV = "/Game/Wwise/Events/VO/Int/Hun/Battle/SFX_VO_Shout.SFX_VO_Shout", eventPath("SFX_Wave_Light")
    local BODY_EV, DEFAULT_EV, LOOP_EV = eventPath("SFX_Body_Turn"), eventPath("SFX_Wave_Plain"), eventPath("SFX_Spark_Loop")
    local UI_EV, MUS_EV = "/Game/Wwise/Events/UI/UI_General/SFX_UI_QTE.SFX_UI_QTE", "/Game/Wwise/Events/Mus/Mus_Stinger/Mus_Hit.Mus_Hit"
    local AT_PLAYER_EV, KIND3_EV, TRACE_EV = eventPath("SFX_At_Player"), eventPath("SFX_Interact"), eventPath("SFX_Trace_Step")
    local PAD_EV, STOP_EV = "/Game/Wwise/Events/Motion/CommonHaptic/Haptic_VibrateL2.Haptic_VibrateL2",
        eventPath("SFX_Slide_Sword_Stop")

    -- The game's data on one PC, as hitfx.lua reads it: a weapon config's Sounds (tag -> event) and its abilities, each
    -- ability class's timelines (or its parent's), and a timeline's steps (when, which action): the montage it plays and its
    -- weapon-sound steps. The sound engine keeps what's posted: pc.swingSounds.
    local function swingData(pc)
        local f = pc.found
        f["/Script/LegoAbility.LGAAction_PlayMontage"] = Fake.object(pc, "Class")
        local function event(path)
            local e = Fake.object(pc, "AkAudioEvent")
            rawset(e, "__path", path)
            f[path] = e
            return e
        end
        local light, heavy, fire = event(LIGHT_EV), event(HEAVY_EV), event(FIRE_EV)
        pc.swingSounds = {}
        local ak = Fake.object(pc, "AkGameplayStatics")
        Fake.put(ak, "PostEvent", function(_, ev, actor)
            pc.swingSounds[#pc.swingSounds + 1] = { ev = ev and rawget(ev, "__path"), on = actor, at = pc.now }
            return 1
        end)
        f["/Script/AkAudio.Default__AkGameplayStatics"] = ak
        -- (413) The sound engine's call for a sound at a place, as this PC's build of it takes it: the world's object after
        -- the turn, or (akNamed) a name for the event before that. Called the other way it is refused, as UE4SS refuses
        -- a value of the wrong kind.
        pc.swingSoundsAt = {}
        Fake.put(ak, "PostEventAtLocation", function(_, ev, where, turn, a4, a5)
            local world = a4
            if pc.akNamed then
                if type(a4) ~= "string" then
                    error("PostEventAtLocation: EventName takes a string")
                end
                world = a5
            end
            if type(world) ~= "table" then
                error("PostEventAtLocation: WorldContextObject takes an object")
            end
            pc.swingSoundsAt[#pc.swingSoundsAt + 1] = { ev = ev and rawget(ev, "__path"), where = where, world = world, at = pc.now }
            return 1
        end)
        local function step(t, action)
            return { StartTime = t, duration = 0.1, Action = action }
        end
        local function montageAt(t, path)
            return step(t, Fake.object(pc, "LGAAction_PlayMontage", { MontageToPlay = pc.env.StaticFindObject(path), PlayRate = 1.0 }))
        end
        local function soundAt(t, tag)
            return step(t, Fake.object(pc, "GAA_PBZWeaponSound_C", { ["Sound Tag"] = { TagName = Fake.name(tag) } }))
        end
        local function playSoundAt(t, class, kind, path, extra)
            local fields = { PlaySoundType = kind, StopOnEnd = false, AkEvent = event(path), PostAtPlayerLocation = false,
                PostAtFixedLocation = false }
            for k, v in pairs(extra or {}) do
                fields[k] = v
            end
            return step(t, Fake.object(pc, class, fields))
        end
        local function timeline(steps)
            return Fake.object(pc, "LGATimeline", { Actions = Fake.list(steps) })
        end
        local function ability(name, timelines, parent)
            local path = "/PBZCombatAsset/Abilities/" .. name .. "." .. name .. "_C"
            local c = Fake.object(pc, "LegoAbilityBlueprintGeneratedClass", { AbilityTimelines = Fake.list(timelines or {}) })
            rawset(c, "__path", path)
            Fake.put(c, "GetSuperStruct", function() return parent end)
            f[path] = c
            return c
        end
        local function sounds(list)
            return { ForEach = function(_, fn)
                for _, kv in ipairs(list) do
                    fn({ get = function() return { TagName = Fake.name(kv[1]) } end },
                        { get = function() return { [SOUND_FIELD] = kv[2] } end })
                end
            end }
        end
        local sword = pc.env.StaticFindObject(SWORD)
        local base = ability("GA_Sword_B_Base", { timeline({ montageAt(0, B1), soundAt(0.40, HEAVY) }) })
        Fake.put(sword, "Sounds", sounds({ { LIGHT, light }, { HEAVY, heavy } }))
        Fake.put(sword, "Equip Abilities", Fake.list({
            ability("GA_Sword_A", { timeline({ montageAt(0, A1), step(0.10, Fake.object(pc, "GAA_CameraShake_C")),
                soundAt(0.30, LIGHT) }) }),
            ability("GA_Sword_AA", { timeline({ soundAt(0.55, HEAVY), montageAt(0.05, A2), soundAt(0.25, LIGHT) }) }),
            ability("GA_Sword_Look", { timeline({ montageAt(0, LOOK) }) }),
            ability("GA_Sword_B", {}, base),
            ability("GA_Sword_E", { timeline({ montageAt(0, E1), soundAt(0.20, LIGHT), montageAt(0.50, E2),
                soundAt(0.70, HEAVY) }) }),
            ability("GA_Sword_F", { timeline({ montageAt(0, F1),
                playSoundAt(0.25, "GAA_PlaySound_Opt_C", 0, VO_EV),
                playSoundAt(0.27, "GAA_PlaySound_Opt_C", 2, WAVE_EV),
                playSoundAt(0.30, "GAA_PlaySound_Opt_C", 1, BODY_EV),
                playSoundAt(0.32, "GAA_PlaySound_Opt_C", 2, LOOP_EV, { StopOnEnd = true }),
                playSoundAt(0.34, "GAA_PlaySound_Opt_C", 0, UI_EV),
                playSoundAt(0.35, "GAA_PlaySound_Opt_C", 2, MUS_EV),
                playSoundAt(0.36, "GAA_PlaySound_Opt_C", 2, AT_PLAYER_EV, { PostAtPlayerLocation = true }),
                playSoundAt(0.38, "GAA_PlaySound_Opt_C", 3, KIND3_EV),
                playSoundAt(0.40, "GAA_PlaySound_TraceEnvi_C", 0, TRACE_EV),
                playSoundAt(0.405, "GAA_PlaySound_Opt_C", 0, PAD_EV),
                playSoundAt(0.41, "GAA_PlaySound_Opt_C", 2, STOP_EV),
                playSoundAt(0.42, "LGAAction_PlaySoundDefault", 2, DEFAULT_EV) }) }),
        }))
        Fake.put(sword, "Owning Abilities", Fake.list({ ability("GA_Sword_Dash", { timeline({ montageAt(0, D1), soundAt(0.15, LIGHT) }) }) }))
        local cannon = pc.env.StaticFindObject(CANNON)
        Fake.put(cannon, "Sounds", sounds({ { FIRE, fire } }))
        Fake.put(cannon, "Equip Abilities", Fake.list({ ability("GA_Cannon_Fire", { timeline({ montageAt(0, C1), soundAt(0.20, FIRE) }) }) }))
        Fake.put(cannon, "Owning Abilities", Fake.list({}))
    end
    local function both(a, b)
        swingData(a)
        swingData(b)
    end
    -- What one PC posted from n on: each { ev, on, at }.
    local function since(pc, n)
        local out = {}
        for i = n + 1, #pc.swingSounds do
            out[#out + 1] = pc.swingSounds[i]
        end
        return out
    end
    local function show(list, t0)
        local out = {}
        for _, x in ipairs(list) do
            out[#out + 1] = string.format("%s +%.2f", (x.ev or "?"):match("([^.]+)$") or "?", x.at - (t0 or 0))
        end
        return #out > 0 and table.concat(out, ", ") or "none"
    end
    -- A swing of the player on pc, heard on others: what each posted in the next 0.8 s (they stay in the move that long).
    local function swingOn(s, pc, path, others)
        local marks = {}
        for _, o in ipairs(others) do
            marks[o] = #o.swingSounds
        end
        local t0 = pc.now
        Session.startMove(pc, path)
        s:run(0.8)
        Session.endMove(pc)
        s:run(0.3)
        local heard = {}
        for _, o in ipairs(others) do
            heard[o] = since(o, marks[o])
        end
        return heard, t0
    end

    local s, h, g = pair(ON, both)
    Session.hold(g, SWORD, true)
    Session.hold(h, SWORD, true)
    s:run(2)
    check(count(h.logs, "Partner swing sounds: Sword learned %(7 moves with a sound, 2 of its own sounds%)") == 1
        and count(g.logs, "Partner swing sounds: Sword learned %(7 moves with a sound, 2 of its own sounds%)") == 1,
        "each PC learns the partner's weapon from the game's data: 7 moves with a sound (own timelines, a parent's, an "
        .. "owning ability's, two in one timeline, play-sound steps), its 2 own sounds")
    local sentBefore = #g.sent
    local heard, t0 = swingOn(s, g, A1, { h, g })
    local onHost, onGuest = heard[h], heard[g]
    local x = onHost[1] or {}
    check(#onHost == 1 and x.ev == LIGHT_EV and x.on == net(h).ghost and math.abs(x.at - t0 - 0.30) <= 0.06,
        "a guest's swing that hits nothing: the host plays its weapon's whoosh on the guest's figure, once, as the montage "
        .. "gets to the step (0.30 s in): " .. show(onHost, t0))
    check(#onGuest == 0, "the guest, whose own game plays it, nothing from the mod: " .. show(onGuest, t0))
    local kinds = {}
    for i = sentBefore + 1, #g.sent do
        local k = g.sent[i]:match("^[EQ] (%S+)")
        if k then
            kinds[k] = true
        end
    end
    local other = nil
    for k in pairs(kinds) do
        if k ~= "U" then
            other = k
        end
    end
    check(kinds.U and other == nil, "and nothing new goes for it: the guest sent its move (U) and no other event ("
        .. tostring(other) .. ")")
    heard, t0 = swingOn(s, h, A1, { h, g })
    x = heard[g][1] or {}
    check(#heard[g] == 1 and x.ev == LIGHT_EV and x.on == net(g).ghost and math.abs(x.at - t0 - 0.30) <= 0.06
        and #heard[h] == 0, "the host's swing: the guest plays it on the host's figure, the host nothing: "
        .. show(heard[g], t0))
    heard, t0 = swingOn(s, g, A2, { h })
    local a, b = heard[h][1] or {}, heard[h][2] or {}
    check(#heard[h] == 2 and a.ev == LIGHT_EV and b.ev == HEAVY_EV and math.abs(a.at - t0 - 0.20) <= 0.06
        and math.abs(b.at - t0 - 0.50) <= 0.06, "two steps in one attack, its montage started 0.05 s into the timeline: "
        .. "light at 0.20, heavy at 0.50: " .. show(heard[h], t0))
    heard, t0 = swingOn(s, g, B1, { h })
    x = heard[h][1] or {}
    check(#heard[h] == 1 and x.ev == HEAVY_EV and math.abs(x.at - t0 - 0.40) <= 0.06,
        "an attack whose timeline is its parent class's: " .. show(heard[h], t0))
    heard, t0 = swingOn(s, g, D1, { h })
    check(#heard[h] == 1 and (heard[h][1] or {}).ev == LIGHT_EV, "an owning ability's (a dash's): " .. show(heard[h], t0))
    heard, t0 = swingOn(s, g, E2, { h })
    x = heard[h][1] or {}
    check(#heard[h] == 1 and x.ev == HEAVY_EV and math.abs(x.at - t0 - 0.20) <= 0.06,
        "a timeline that plays two montages: a step goes with the one it falls in (0.70 s in, 0.20 s into the second): "
        .. show(heard[h], t0))
    heard, t0 = swingOn(s, g, LOOK, { h })
    check(#heard[h] == 0, "a move with no weapon-sound step: nothing: " .. show(heard[h], t0))
    -- The game's play-sound steps: of the character (their shout), the weapon (the whoosh) or the body, played whole on
    -- them. Not a loop (stopped at its step's end), a menu or music event, one at this player's place, the interact kind,
    -- nor one that sets a surface switch first.
    heard, t0 = swingOn(s, g, F1, { h })
    local want = { { VO_EV, 0.25 }, { WAVE_EV, 0.27 }, { BODY_EV, 0.30 }, { DEFAULT_EV, 0.42 } }
    local right = #heard[h] == #want
    for i, wnt in ipairs(want) do
        local got = heard[h][i]
        right = right and got ~= nil and got.ev == wnt[1] and math.abs(got.at - t0 - wnt[2]) <= 0.06
    end
    check(right, "play-sound steps: their shout, the whoosh, the body's and a plain one play, each on time; a loop, a "
        .. "menu, music, controller or stop event, one at this player's place, the interact kind and a surface-traced one "
        .. "don't: " .. show(heard[h], t0))

    -- Cut short by a newer move before its step, or ended (U - 0): what's left of it isn't played.
    local n = #h.swingSounds
    t0 = g.now
    Session.startMove(g, A2)
    s:run(0.1)
    Session.startMove(g, LOOK)
    s:run(0.8)
    Session.endMove(g)
    s:run(0.3)
    check(#since(h, n) == 0, "an attack cut short by a newer move before its steps: none of them: " .. show(since(h, n), t0))
    n = #h.swingSounds
    t0 = g.now
    Session.startMove(g, A1)
    s:run(0.15)
    Session.endMove(g)
    s:run(0.8)
    check(#since(h, n) == 0, "one ended (U - 0) before its step: nothing: " .. show(since(h, n), t0))
    -- Told again mid-move (as after someone joined), then a part of it looping back: the steps already played aren't
    -- played again, as their own game played each once. The same attack started anew plays them again.
    n = #h.swingSounds
    t0 = g.now
    Session.startMove(g, A2)
    s:run(0.6)
    h.inbox[#h.inbox + 1] = "~10 U " .. A2 .. " 0.60"
    s:run(0.1)
    h.inbox[#h.inbox + 1] = "~10 U " .. A2 .. " 0.15"
    s:run(0.6)
    Session.endMove(g)
    s:run(0.3)
    check(#since(h, n) == 2, "a move told again mid-way, then looping back before its steps: each step once in all: "
        .. show(since(h, n), t0))
    n = #h.swingSounds
    t0 = g.now
    Session.startMove(g, A1)
    s:run(0.4)
    local t1 = g.now
    Session.startMove(g, A1)
    s:run(0.6)
    Session.endMove(g)
    s:run(0.3)
    local again = since(h, n)
    check(#again == 2 and math.abs(again[2].at - t1 - 0.30) <= 0.06, "the same attack started anew while the first "
        .. "plays: its step again, 0.30 s into the new one: " .. show(again, t0))
    -- Their figure made anew before a step's moment: nothing on the new one.
    n = #h.swingSounds
    Session.startMove(g, A1)
    s:run(0.1)
    net(h).ghostAt = net(h).ghostAt + 0.5
    s:run(0.7)
    Session.endMove(g)
    s:run(0.3)
    check(#since(h, n) == 0, "their figure made anew before the step: nothing: " .. show(since(h, n)))

    -- Heard late (the move's age): a step still ahead plays on time, one just passed at once, one long past not at all.
    for _, case in ipairs({ { "0.20", 0.09, 1 }, { "0.50", 0, 1 }, { "0.70", nil, 0 } }) do
        n = #h.swingSounds
        t0 = h.now
        h.inbox[#h.inbox + 1] = "~10 U " .. A1 .. " " .. case[1]
        s:run(0.6)
        h.inbox[#h.inbox + 1] = "~10 U - 0"
        s:run(0.3)
        local got = since(h, n)
        local ok = #got == case[3]
        if ok and case[2] then
            ok = math.abs(got[1].at - t0 - case[2]) <= 0.05
        end
        check(ok, "a move heard " .. case[1] .. " s in: " .. (case[3] == 1 and "its step plays, "
            .. (case[2] == 0 and "at once" or "on time") or "its step, long past, doesn't") .. ": " .. show(got, t0))
    end
    -- Held till their figure could play it (issue #16): played from there, its step with it.
    local ghost = net(h).ghost
    local mesh = field(ghost, "Mesh")
    local realAnim = field(mesh, "GetAnimInstance")
    Fake.put(mesh, "GetAnimInstance", function() return nil end)
    n = #h.swingSounds
    t0 = h.now
    h.inbox[#h.inbox + 1] = "~10 U " .. A1 .. " 0.00"
    s:run(0.15)
    Fake.put(mesh, "GetAnimInstance", realAnim)
    s:run(0.6)
    h.inbox[#h.inbox + 1] = "~10 U - 0"
    s:run(0.3)
    x = since(h, n)[1] or {}
    check(#since(h, n) == 1 and math.abs(x.at - t0 - 0.30) <= 0.06,
        "a move held till their figure could play it: its step plays, on time: " .. show(since(h, n), t0))

    -- Their Phantom Edge's attack: from its own config.
    Session.holdEdge(g, CANNON, true)
    s:run(1.5)
    heard, t0 = swingOn(s, g, C1, { h })
    x = heard[h][1] or {}
    check(#heard[h] == 1 and x.ev == FIRE_EV and math.abs(x.at - t0 - 0.20) <= 0.06,
        "a Phantom Edge attack: its own config's sound: " .. show(heard[h], t0))

    -- Off on the host (the hitsounds command, as the ini's row): nothing there; on again, it plays.
    Session.command(h, "hitsounds off")
    s:run(0.3)
    heard = swingOn(s, g, A1, { h })
    local off = #heard[h]
    Session.command(h, "hitsounds on")
    s:run(0.3)
    heard = swingOn(s, g, A1, { h })
    check(off == 0 and #heard[h] == 1, "PartnerHitSounds off on the host: nothing there (" .. off .. "); on again: plays ("
        .. #heard[h] .. ")")
    -- Their figure over 60 m off: not played.
    Session.moveTo(h, -6500, 0)
    s:run(1)
    heard = swingOn(s, g, A1, { h })
    check(#heard[h] == 0, "their figure 70 m off: not played (" .. #heard[h] .. ")")
    allErrors(s)

    -- Left out of the ini: off, as before.
    s, h, g = pair(nil, both)
    Session.hold(g, SWORD, true)
    s:run(2)
    heard = swingOn(s, g, A1, { h })
    check(#heard[h] == 0 and count(h.logs, "Partner swing sounds") == 0, "the row left out of the ini: nothing learned or played")
    allErrors(s)

    -- A partner with no figure here yet isn't read (404: the review of 399). At a link their weapon's word comes a
    -- second or so before their figure is made, and "settled", asked of no figure, said yes: a weapon this PC already
    -- had was read at once, 1.7.3's moment. Here the world takes the guest's figure (a load's), and the guest takes
    -- up the sword in the same moment: read once the figure made anew has stood its 6 s, not before.
    s, h, g = pair(ON, both)
    s:run(4)
    local made0 = count(h.logs, "Remote player ghost spawned")
    rawset(net(h).ghost, "__alive", false)
    Session.hold(g, SWORD, true)
    local madeAt, learnedAt, tookAt = nil, nil, h.now
    s:run(12, function()
        madeAt = madeAt or (count(h.logs, "Remote player ghost spawned") > made0 and h.now or nil)
        learnedAt = learnedAt or (count(h.logs, "Partner swing sounds: Sword learned") > 0 and h.now or nil)
    end)
    check(madeAt ~= nil and learnedAt ~= nil and learnedAt - madeAt >= 6,
        string.format("a partner's weapon isn't read while they have no figure here: read %s s after the sword was taken up, %s s after the figure was made",
            learnedAt and string.format("%.2f", learnedAt - tookAt) or "never",
            (learnedAt and madeAt) and string.format("%.2f", learnedAt - madeAt) or "?"))
    allErrors(s)

    -- In PvP the figure plays their abilities (M), which make their own sounds: nothing from here.
    s, h, g = pair(ON .. "PvP = On\n", both)
    Session.hold(g, SWORD, true)
    s:run(2)
    heard = swingOn(s, g, A1, { h })
    check(net(h).pvp == true and #heard[h] == 0, "in PvP: nothing played (" .. #heard[h] .. ")")
    allErrors(s)

    -- Four players (the report's three and one more): a guest's swing is heard by the host and the other two guests, each
    -- on their figure of that guest, once; the swinger hears none from the mod.
    s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES, ON)
    for _, pc in ipairs(s.pcs) do
        swingData(pc)
    end
    s:run(4)
    spread(s)
    s:run(3)
    -- (Player 2 said they hold a weapon these PCs can't load: it mustn't hold up learning player 3's.)
    for _, pc in ipairs({ s.pcs[1], s.pcs[4] }) do
        pc.inbox[#pc.inbox + 1] = "@2 W /HuaShira/Characters/Hun/Weapon/Missing.Missing 1"
    end
    s:run(0.5)
    Session.hold(s.pcs[3], SWORD, true)
    s:run(2)
    local swinger = s.pcs[3]
    heard, t0 = swingOn(s, swinger, A1, s.pcs)
    local all = true
    for i, pc in ipairs(s.pcs) do
        local got = heard[pc]
        if i == 3 then
            all = all and #got == 0
        else
            all = all and #got == 1 and got[1].on == ghostOf(pc, 3) and got[1].ev == LIGHT_EV
                and math.abs(got[1].at - t0 - 0.30) <= 0.08
        end
    end
    check(all, "four players, one holding a weapon the others can't load: the host and the two other guests each play "
        .. "another guest's swing on their figure of that guest, once; the swinger none (" .. show(heard[s.pcs[1]], t0) .. " | " .. show(heard[s.pcs[2]], t0) .. " | "
        .. show(heard[s.pcs[4]], t0) .. " | " .. show(heard[s.pcs[3]], t0) .. ")")
    allErrors(s)

    -- The guard (413), for a partner's swings and the reading of their weapon.
    do
        local FILE = "hitfx_guard.txt"
        local function guardOf(pc)
            return pc.env.PBZ.hitfx.guard or { way = {}, skip = {} }     -- (none in scripts before 413)
        end
        local function said(pc, words)
            return count(pc.logs, "Partner hit sounds: the last session ended inside " .. words)
        end
        local LEARNED = "Partner swing sounds: Sword learned"
        -- Two players, the host's guard file as a session before left it; the guest takes up the sword.
        local function after(text, named)
            local t = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, ON, nil, function(pc, i)
                if i == 1 then
                    pc.files[FILE], pc.akNamed = text, named
                end
            end)
            both(t.pcs[1], t.pcs[2])
            t:run(4)
            Session.moveTo(t.pcs[1], 0, 0)
            Session.moveTo(t.pcs[2], 500, 0)
            t:run(2)
            Session.hold(t.pcs[2], SWORD, true)
            return t, t.pcs[1], t.pcs[2]
        end
        -- The guest's swing: what the host posted on their figure, and at a place.
        local function guestSwings(t, hh, gg, path)
            local placed = #hh.swingSoundsAt
            local heard, t0 = swingOn(t, gg, path, { hh })
            local at = {}
            for i = placed + 1, #hh.swingSoundsAt do
                at[#at + 1] = hh.swingSoundsAt[i]
            end
            return heard[hh], at, t0
        end

        local t, hh, gg = after(nil)
        t:run(2)
        local file = hh.files[FILE] or ""
        check(count(hh.logs, LEARNED) == 1 and file == "epoch 1\nbusy learn " .. SWORD .. "\n",
            "the guard: while a partner's weapon is read, and 2 s on, its note is in the guard's file ("
            .. (file:gsub("\n", " | ")) .. ")")
        t:run(2.5)
        check(hh.files[FILE] == nil, "then it is out: no file")
        local on, placed = guestSwings(t, hh, gg, A1)
        check(#on == 1 and #placed == 0 and (hh.files[FILE] or ""):find("\nbusy swing " .. LIGHT_EV .. "\n", 1, true) ~= nil,
            "a partner's swing sound, new to the session, has its note as it is posted (" .. tostring(hh.files[FILE]):gsub("\n", " | ") .. ")")
        t:run(2.5)
        check(hh.files[FILE] == nil, "and 2 s on that is out too")
        allErrors(t)

        -- The last session ended inside a swing's sound on a figure: at the figure's place from now on.
        t, hh, gg = after("epoch 1\nbusy swing " .. LIGHT_EV .. "\n")
        t:run(2)
        local t0
        on, placed, t0 = guestSwings(t, hh, gg, A1)
        local x = placed[1] or {}
        check(guardOf(hh).way.swing == 2 and #on == 0 and #placed == 1 and x.ev == LIGHT_EV and x.world == net(hh).ghost
            and x.where ~= nil and gap(x.where, at(net(hh).ghost)) < 1 and math.abs(x.at - t0 - 0.30) <= 0.06,
            "a session ended inside a partner's swing sound: the next posts their swings at their figure's place, on "
            .. "time, by the call that makes nothing on the body (" .. #on .. " on it, " .. #placed .. " at its place)")
        check(said(hh, "a partner's swing sound %(SFX_Swing_Sword_Light%)%. A partner's swing sounds are played at their place") == 1
            and count(hh.logs, "Partner hit sounds: on .* Held back on this PC .*%(swing 2%)") >= 1,
            "it says so in the log, and in the setting's own line")
        allErrors(t)
        -- The same on a sound engine whose call for a place takes a name for the event first.
        t, hh, gg = after("epoch 1\nbusy swing " .. LIGHT_EV .. "\n", true)
        t:run(2)
        on, placed = guestSwings(t, hh, gg, A1)
        check(#on == 0 and #placed == 1 and guardOf(hh).placeArgs == 5,
            "a sound engine whose call for a place takes a name for the event too: found by trying, and posted (" .. #placed .. ")")
        allErrors(t)
        -- Ended inside that call too: no swing sounds, and no weapon is read for them.
        t, hh, gg = after("epoch 1\nswing 2\nbusy swing " .. LIGHT_EV .. "\n")
        t:run(2)
        on, placed = guestSwings(t, hh, gg, A1)
        check(guardOf(hh).way.swing == 3 and #on == 0 and #placed == 0 and count(hh.logs, LEARNED) == 0,
            "a session ended inside the call at a place too: no swing sounds on this PC any more, and no weapon read for them")
        allErrors(t)
        -- Ended inside the reading of a weapon: that weapon is passed over, another is read and heard.
        t, hh, gg = after("epoch 1\nbusy learn " .. SWORD .. "\n")
        t:run(3)
        on, placed = guestSwings(t, hh, gg, A1)
        local skipped = count(hh.logs, LEARNED) == 0 and #on == 0 and #placed == 0
        Session.hold(gg, CANNON, true)
        t:run(3)
        on, placed = guestSwings(t, hh, gg, C1)
        check(skipped and guardOf(hh).skip[SWORD] == true and count(hh.logs, "Partner swing sounds: Cannon learned") == 1
            and #on == 1 and (on[1] or {}).ev == FIRE_EV and (hh.files[FILE] or ""):find("\nskip " .. SWORD .. "\n", 1, true) ~= nil
            and said(hh, "the reading of a partner's weapon %(Sword%)%. That weapon's swing sounds are left out") == 1,
            "a session ended inside the reading of a partner's weapon: that weapon is passed over from then on (kept in "
            .. "the file, said in the log), another they take up is read and heard")
        allErrors(t)
        -- A second weapon's reading ended a session: none is read any more.
        t, hh, gg = after("epoch 1\nskip " .. CANNON .. "\nbusy learn " .. SWORD .. "\n")
        t:run(3)
        Session.hold(gg, CANNON, true)
        t:run(3)
        on, placed = guestSwings(t, hh, gg, C1)
        check(guardOf(hh).way.learn == 2 and #on == 0 and #placed == 0 and count(hh.logs, "Partner swing sounds: %a+ learned") == 0
            and (hh.files[FILE] or ""):find("\nlearn 2\n", 1, true) ~= nil,
            "two weapons whose reading ended a session: no weapon is read on this PC any more")
        allErrors(t)
    end
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
    -- (A flag of its own that its opening raises: its flow preset's, as a quest's chest may have.)
    Fake.put(late, "BP_PBZFlowComponent", { FlowPresetDataList = { { IsValid = function() return true end,
        AddTagWhenSuccess = { GameplayTags = Fake.list({ { TagName = Fake.name("xg.chest.opened") } }) } } } })
    s:run(2)
    check(field(late, "CurSwitchState") == true and count(g.trace, "PushAccessoryToInventory") == 2,
        "one that wasn't loaded on the guest's side pays when it is")
    s:run(65)
    check(Session.items(g, "Weapon_Material_04") == 6 and count(g.trace, "PushAccessoryToInventory") == 2,
        "named again (for one who joins later), nothing pays twice")
    check(count(g.globalTags, "^xg%.chest%.opened$") == 1, "and its own flag is raised, as its opening would have")
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

    -- An ending's condition (the Soul Cliff's "bloodline awakening": a row that sets only its flag) is each player's own
    -- play's to meet. Followed by its place in the table, any guest whose host was past it had it set.
    local keep, with = Fake.STORY_ROWS, {}
    for i, r in ipairs(keep) do
        with[i] = r
    end
    table.insert(with, 10, { "forest-ending", "", "False", tags = "dhy.结局条件.sim" })
    Fake.STORY_ROWS = with
    local n, nh, ng = pair()
    nh.storyUpTo(#with)
    ng.storyUpTo(3)
    n:run(33)
    Fake.STORY_ROWS = keep
    check(ng.storyState("Main-Forest", "1") == 2 and ng.storyMarks["UI.VisibilityTag.Shop"] ~= nil
        and not ng.storyMarks["dhy.结局条件.sim"],
        "a guest catches up past an ending's condition, and that isn't set for them: their own play's to meet")
    allErrors(n)

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

    -- A sync started again later in the same run of the game (the guest left and came back, or its link dropped and
    -- rose): what's counted stays as it is, so the bombs and herbs used since aren't refilled. A story thing there's
    -- one of, which the host found meanwhile and this bag never held, comes all the same: nothing else brings it. Not
    -- one this bag had and used since (a key spent at its door, a thing handed in: the host keeps its own), and not a
    -- piece or a story thing made of several: four shards are an amber as the fourth comes, and the host's chest or
    -- this world's own copy of the find pays it too. (The bench, 11-17; the sixth review's V1 and V2.)
    local k, kh, kg = pair(nil, function(ph)
        Session.gainItem(ph, "Weapon_Material_01", 3)
        Session.gainItem(ph, "I_RELIC_3", 1)
        Session.gainItem(ph, "I_RELIC_4", 1)
    end)
    k:run(70)                                   -- (past the run's first minute)
    check(Session.items(kg, "Weapon_Material_01") == 3 and Session.items(kg, "I_RELIC_3") == 1
        and Session.items(kg, "I_RELIC_4") == 1, "(the first joining: what the host has, counted)")
    kg.bag:RemovePropsFromBackPack(2, kg.env.FName("Weapon_Material_01"))       -- (used since)
    kg.bag:RemovePropsFromBackPack(1, kg.env.FName("I_RELIC_3"))    -- (a key spent at its door: the host's opens by the word)
    kg.bag:RemovePropsFromBackPack(1, kg.env.FName("I_RELIC_4"))    -- (handed in)
    Session.command(kg, "netoff")
    k:run(2)
    kh.bag:AddPropsToBackPack(1, kh.env.FName("I_KEY_9"), false)                -- (found by the host meanwhile)
    kh.bag:AddPropsToBackPack(2, kh.env.FName("Weapon_Material_02"), false)
    kh.bag:AddPropsToBackPack(1, kh.env.FName("Item_Piece_002"), false)         -- (an elite's shard)
    kh.bag:AddPropsToBackPack(1, kh.env.FName("K_TOKEN_9"), false)              -- (a token's half)
    Session.command(kg, "neton client")
    k:run(20)
    check(Session.items(kg, "I_KEY_9") == 1, "back in the same run: a story thing the host found meanwhile comes")
    check(Session.items(kg, "Weapon_Material_01") == 1 and Session.items(kg, "Weapon_Material_02") == 0,
        "and nothing that's counted: what was used stays used, a material found meanwhile stays the host's ("
            .. Session.items(kg, "Weapon_Material_01") .. ", " .. Session.items(kg, "Weapon_Material_02") .. ")")
    check(Session.items(kg, "Item_Piece_002") == 0 and Session.items(kg, "K_TOKEN_9") == 0,
        "nor a piece, or a story thing made of several: what pays its find pays it, once ("
            .. Session.items(kg, "Item_Piece_002") .. ", " .. Session.items(kg, "K_TOKEN_9") .. ")")
    for _ = 1, 2 do
        Session.command(kg, "netoff")
        k:run(2)
        Session.command(kg, "neton client")
        k:run(20)
    end
    check(Session.items(kg, "I_RELIC_3") == 0 and Session.items(kg, "I_RELIC_4") == 0 and Session.items(kh, "I_RELIC_3") == 1
        and Session.items(kg, "I_KEY_9") == 1,
        "three syncs on: a story thing this bag had and used stays used, a key spent at its door, a thing handed in ("
            .. Session.items(kg, "I_RELIC_3") .. ", " .. Session.items(kg, "I_RELIC_4") .. ")")
    allErrors(k)

    -- A chest the host opened while the guest was away, a shard in it: the guest's own copy, seen shut once they're
    -- back, pays it by the host's word, once. (The bag gave it too, at the sync's start: two shards for one chest.)
    local z, zh, zg = pair()
    z:run(70)
    Session.command(zg, "netoff")
    z:run(2)
    local theirs = Fake.chest(zh, "BP_Chest_C_31", 600.0, 0.0, 100.0, "Xigu.Piece")
    Fake.put(theirs, "CurSwitchState", true)
    zh.bag:AddPropsToBackPack(1, zh.env.FName("Item_Piece_002"), false)
    z:run(2)
    Session.command(zg, "neton client")
    z:run(8)
    local mine = Fake.chest(zg, "BP_Chest_C_31", 600.0, 0.0, 100.0, "Xigu.Piece")
    z:run(70)
    check(field(mine, "CurSwitchState") == true and Session.items(zg, "Item_Piece_002") == 1 and Session.items(zh, "Item_Piece_002") == 1,
        "a chest with a shard the host opened while the guest was away: one shard for the guest, by the chest ("
            .. Session.items(zg, "Item_Piece_002") .. ")")
    allErrors(z)

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

    -- A step the guest's world can't take any more: a side branch left under way in a quest that's over there (the
    -- flag that ends the quest came first). Applied at every load, it never took, and the guest was told "your story
    -- caught up with the host's: 1 step" each time (the bench, 11-17: "meet Xiong Zhang again").
    local function told(pc)
        local n = nil
        for _, l in ipairs(pc.logs) do
            n = tonumber(tostring(l):match("your story caught up with the host's: (%d+) step")) or n
        end
        return n
    end
    local function loaded(pc)           -- (a load: the player's body a new one)
        pc.nextAddress = pc.nextAddress + 16
        rawset(pc.pawn, "__addr", pc.nextAddress)
    end
    local v, vh, vg = pair()
    vh.storyUpTo(all)
    vg.storyUpTo(3)
    vg.storyStep("Boss-Puppet", "S1", 1)
    vg.storyOver("Boss-Puppet")
    v:run(40)
    check(vg.storyState("Main-Forest", "1") == 2 and vg.storyState("Boss-Puppet", "S1") == 1
        and count(vg.logs, "didn't take here") == 0 and told(vg) == told(g) - 1,
        "a step of a quest that's over in the guest's world: left alone, the rest of the host's story taken ("
            .. tostring(told(vg)) .. " of " .. tostring(told(g)) .. " steps)")
    local calls, notices = #vg.storyApplied, count(vg.logs, "your story caught up with the host's")
    loaded(vg)
    v:run(40)
    check(#vg.storyApplied == calls and count(vg.logs, "didn't take here") == 0
        and count(vg.logs, "your story caught up with the host's") == notices,
        "nor applied at the next load, and nothing said of it")
    allErrors(v)
    -- One the game won't take for a reason of its own is tried once a load, as ever, and isn't told as caught up to.
    local w, wh, wg = pair()
    wh.storyUpTo(all)
    wg.storyUpTo(3)
    wg.storyStuck["Boss-Puppet S1"] = true
    w:run(70)
    check(count(wg.logs, "1 of the host's story steps didn't take here") == 1 and told(wg) == told(g) - 1,
        "a step the game wouldn't take: said in the log, and not counted in what the player is told they caught up to ("
            .. tostring(told(wg)) .. " of " .. tostring(told(g)) .. " steps)")
    check(count(wg.logs, "1 of the host's story steps hasn't taken here yet: asked again in 10 s") == 2,
        "asked three times in all, ten seconds apart, before it's left")
    wg.storyStuck["Boss-Puppet S1"] = nil
    loaded(wg)
    w:run(40)
    check(wg.storyState("Boss-Puppet", "S1") == 2 and count(wg.logs, "your story caught up with the host's: 1 step") == 1,
        "tried again after a load, it takes: told then")
    allErrors(w)
    -- One that didn't take at its first asking and does at its second (a PC out of breath, the bench of 11-18): no load is
    -- waited for, and it's told as caught up to with the rest.
    local x, xh, xg = pair()
    xh.storyUpTo(all)
    xg.storyUpTo(3)
    xg.storyStuck["Boss-Puppet S1"] = true
    local askedAgain
    x:run(60, function()
        if not askedAgain and count(xg.logs, "hasn't taken here yet") > 0 then
            askedAgain = xg.now
            xg.storyStuck["Boss-Puppet S1"] = nil
        end
    end)
    check(askedAgain ~= nil and xg.storyState("Boss-Puppet", "S1") == 2 and count(xg.logs, "didn't take here") == 0
        and told(xg) == told(g),
        "a step that didn't take at its first asking is asked again ten seconds on, and takes: no load waited for, and told with the rest ("
            .. tostring(told(xg)) .. " of " .. tostring(told(g)) .. " steps)")
    allErrors(x)
end

-- The flags a partner's doing raises in this world too (a player report on 1.7.1, Apprentice Healer: three herbs for
-- Yuer, two found by the guest. The host's map said they were in, and Yuer wouldn't take them: her hand-in reads the flags
-- each herb's pile raises as it's searched, not the bag).
local function questFlags()
    part("quest flags")
    local function has(pc, tag)
        local n = 0
        for _, t in ipairs(pc.globalTags) do
            if t == tag then
                n = n + 1
            end
        end
        return n
    end
    local s = party()
    spread(s)
    local h, a, b, c = s.pcs[1], s.pcs[2], s.pcs[3], s.pcs[4]
    local herbs = {}
    for i, pc in ipairs(s.pcs) do
        herbs[i] = Fake.pile(pc, "BP_Rubbish_C_UAID_herb1", 600.0, 0.0, 100.0, { "xg.camp.herb1" })
    end
    s:run(3)
    Fake.search(a, herbs[2])
    s:run(3)
    check(has(h, "xg.camp.herb1") == 1 and has(b, "xg.camp.herb1") == 1 and has(c, "xg.camp.herb1") == 1,
        "a pile a guest searched raises its flag in the host's world and the other guests'")
    check(rawget(herbs[1], "__alive") == false and rawget(herbs[3], "__alive") == false, "their copies of it go, as before")
    s:run(20)
    check(has(h, "xg.camp.herb1") == 1 and has(b, "xg.camp.herb1") == 1 and has(c, "xg.camp.herb1") == 1,
        "once each, the host's flags told on to the guests as well")
    allErrors(s)

    local p, ph, pg = pair()
    local mine = Fake.pile(ph, "BP_Rubbish_C_UAID_herb3", 600.0, 0.0, 100.0, { "xg.camp.herb3" })
    Fake.pile(pg, "BP_Rubbish_C_UAID_herb3", 600.0, 0.0, 100.0, { "xg.camp.herb3" })
    local plain = Fake.pile(ph, "BP_Rubbish_C_UAID_junk", 700.0, 0.0, 100.0)
    Fake.pile(pg, "BP_Rubbish_C_UAID_junk", 700.0, 0.0, 100.0)
    p:run(3)
    Fake.search(ph, mine)
    Fake.search(ph, plain)
    p:run(3)
    check(has(pg, "xg.camp.herb3") == 1, "a pile the host searched raises its flag in the guest's world")
    check(count(ph.sent, "^E OF ") == 1, "a pile with no flags of its own sends none")
    -- Not under an open talk: a flag raised there can finish what the talk is waiting for, as a story step did.
    local talk = Fake.switch(pg, "WBP_FlowDialog_C", 0.0, 0.0, 0.0)
    rawset(talk, "IsInViewport", function() return true end)
    rawset(talk, "IsVisible", function() return true end)
    local herb2 = Fake.pile(ph, "BP_Rubbish_C_UAID_herb2", 800.0, 0.0, 100.0, { "xg.camp.herb2" })
    Fake.pile(pg, "BP_Rubbish_C_UAID_herb2", 800.0, 0.0, 100.0, { "xg.camp.herb2" })
    p:run(1)
    Fake.search(ph, herb2)
    p:run(4)
    check(has(pg, "xg.camp.herb2") == 0, "not while the guest is in a talk")
    rawset(talk, "__alive", false)
    p:run(8)
    check(has(pg, "xg.camp.herb2") == 1, "but once it's over")
    -- A thing with a flag of its own while it's held (one of the Bagua boy's relics): the game raises it as the thing's card
    -- closes, and a shared one's card waits for the game's own moment. It comes with the thing.
    Session.gainItem(pg, "I_RELIC_1")
    p:run(5)
    check(Session.items(ph, "I_RELIC_1") == 1 and has(ph, "relic.one") == 1,
        "a thing the guest found that has a flag while held raises it for the host too")
    allErrors(p)

    -- And one that came quietly, in the host's bag on joining: no card at all.
    local j, jh, jg = pair(nil, function(ph2)
        Session.gainItem(ph2, "I_RELIC_2")
    end)
    j:run(20)
    check(Session.items(jg, "I_RELIC_2") == 1 and has(jg, "relic.two") == 1,
        "one that came in the host's bag on joining raises it too")
    check(has(jh, "relic.two") == 0, "(the host's own is the game's, as it picked it up)")
    allErrors(j)

    -- A step the guest finished, done here for the host (the herbs found, Yuer's first branch): its tasks' flags with it.
    -- Not a task's that waits for a flag to be gone.
    local e, eh, eg = pair(nil, function(ph2, pg2)
        ph2.storyUpTo(3)
        pg2.storyUpTo(6)
        ph2.storyTask("Side-Cry", "1", { "cry.herb1", "cry.herb2" })
        ph2.storyTask("Side-Cry", "1", { "cry.notyet" }, true)
    end)
    e:run(30)
    eg.storyUpTo(#Fake.STORY_ROWS)
    e:run(60)
    check(eh.storyState("Side-Cry", "1") == 2 and has(eh, "cry.herb1") == 1 and has(eh, "cry.herb2") == 1,
        "a guest's finished step, done for the host, raises the flags its tasks wait for")
    check(has(eh, "cry.notyet") == 0, "but not one a task waits to be gone")
    allErrors(e)

    -- And the host's, caught up to by a guest.
    local u, uh, ug = pair(nil, function(ph2, pg2)
        pg2.storyTask("Side-Cry", "1", { "cry.herb1" })
    end)
    uh.storyUpTo(#Fake.STORY_ROWS)
    ug.storyUpTo(3)
    u:run(60)
    check(ug.storyState("Side-Cry", "1") == 2 and has(ug, "cry.herb1") == 1, "a step caught up to raises them too")
    allErrors(u)

    -- A save left stuck before this (the report's: the step done, the flags never raised, Yuer's hand-in never offered):
    -- once linked, a quest under way gets the flags of its finished steps back. Not a quest that's over.
    local m, mh, mg = pair(nil, function(ph2, pg2)
        for _, pc in ipairs({ ph2, pg2 }) do
            pc.storyUpTo(5)
            pc.storyStep("Main-Valley", "2", 1)
            pc.storyTask("Main-Valley", "1", { "valley.herbs" })
            pc.storyTask("Boss-Puppet", "S1", { "boss.beaten" })
        end
    end)
    m:run(45)
    check(has(mh, "valley.herbs") == 1 and has(mg, "valley.herbs") == 1,
        "a quest under way gets the flags of its finished steps back, the host's world and a guest's")
    check(has(mh, "boss.beaten") == 0 and has(mg, "boss.beaten") == 0, "not a quest that's over")
    check(count(mh.logs, "flag of quest steps finished here before put back") == 1, "said once")
    m:run(45)
    check(has(mh, "valley.herbs") == 1 and has(mg, "valley.herbs") == 1, "and only once")
    allErrors(m)
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
        -- the host had was lit at the link, wherever the guest was. Now a host's bell is lit when the guest has been to it
        -- (and gone on without ringing it: by it, it's theirs to ring, point 3 of a report on 1.7.1).
        local s, h, g = pair(nil, function(h)
            table.insert(h.bellIds, "Bell_YXZR_009")
        end)
        s:run(15)
        check(not g.storyMarks["Bell_YXZR_009"], "a bell the host woke before the guest linked isn't lit far from the guest")
        Session.moveTo(g, 20000 - 1200, 900)
        s:run(3)
        Session.moveTo(g, 500, 0)
        s:run(3)
        check(g.storyMarks["Bell_YXZR_009"], "it's lit when the guest has been to it")
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
        Session.moveTo(g, 500, 0)
        s:run(3)
        check(g.storyMarks["Bell_YXZR_005"], "then it's lit, once they've been there")
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
        -- Steps of play around the host's own load reach the guest: one just before it (a scene that ends in a trip), one on
        -- arrival (the host walks through a door, the Pang Town tavern's of a 1.6.8 report), one in a gap of the link with a
        -- load in it (the reports 7 and 8 reconnect). (11-09: holding back a load's own steps, a lead for BUGHUNT 220, was
        -- tried and dropped: two reviews found it held such steps, and the safe repair searched the world mid-load.)
        h.eventPipeline.ExecuteNodeGuid:Add("SCENE23456789ABCDEF0123456789AB")
        Session.loadMap(h)
        h.map = "Map_Other"
        s:run(10)
        check(g.storyGuids["SCENE23456789ABCDEF0123456789AB"] ~= nil, "a step of play just before the host's load reaches the guest")
        h.eventPipeline.ExecuteNodeGuid:Add("DOOR0123456789ABCDEF0123456789AB")
        s:run(14)
        check(g.storyGuids["DOOR0123456789ABCDEF0123456789AB"] ~= nil, "a step on arrival, a moment after the load, reaches the guest")
        h.cut = true
        s:run(15)
        Session.loadMap(h)
        h.map = "Map_Third"
        h.eventPipeline.ExecuteNodeGuid:Add("GAP00123456789ABCDEF0123456789AB")
        s:run(15)
        h.cut = false
        s:run(20)
        check(g.storyGuids["GAP00123456789ABCDEF0123456789AB"] ~= nil, "a step in a gap of the link with a load in it reaches the guest at the relink")
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
            and field(cmc, "MovementMode") ~= 0, "F3 while watching: in, free to move, the camera their own (went "
            .. tostring(went) .. ", watching " .. tostring(net(late).watchingFight) .. ", spectating "
            .. tostring(late.env.PBZ.game.isSpectating()) .. ", mode " .. tostring(field(cmc, "MovementMode")) .. ")")
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
    -- (No skip, that is: a scene's beginning and its place are told since 398, SCENE on / at.)
    check(count(h.sent, "^E SCENE skip ") == 1, "and no skip is said of it")

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

-- Memory Flowers (a player report on 1.7.1/1.7.2: "The blue Memory Flower cannot be synced; only the first person to pick it
-- up gets it"). A pick gives a petal, which the game keeps once a save: once in the bag, even a moment, it never takes it
-- again. The share's way with a thing new to a player (held a moment, taken back, given) spent it: the partner had none,
-- and their own copy gave nothing either. Now a partner's petal goes in once, their copy goes the game's way, and the
-- flower's quest flags come with it, either way round.
local function memoryFlowers()
    part("Memory Flowers")
    local SIX, FIVE, FOUR = "quest.弦音.记忆之花6", "quest.弦音.记忆之花5", "quest.弦音.记忆之花4"
    local function has(pc, tag)
        local n = 0
        for _, t in ipairs(pc.globalTags) do
            if t == tag then
                n = n + 1
            end
        end
        return n
    end
    local function flowerOn(pcs, id, petal, flags, x, story)
        local out = {}
        for i, pc in ipairs(pcs) do
            out[i] = Fake.memoryFlower(pc, id, x or 600.0, 0.0, 100.0, petal, flags, story)
        end
        return out
    end
    local s, h, g = pair()
    local six = flowerOn({ h, g }, "BP_FlowInteract_MemoryFlower_C_UAID_6", "F_02056", { SIX })
    s:run(2)
    Fake.pickFlower(h, six[1])
    s:run(4)
    check(Session.items(h, "F_02056") == 1 and Session.items(g, "F_02056") == 1,
        "the host picks a Memory Flower: its petal for the host, and one for the guest")
    check(#g.petalsRefused == 0, "given once, as it came: the game never refused it (held a moment first, it would for good)")
    s:run(6)
    check(Fake.flowerState(g, six[2]) == "gone", "the guest's copy goes, the game's way, once the petal is in")
    s:run(10)
    check(has(g, SIX) == 1, "and the flower's quest flag is raised for the guest")
    check(Session.items(g, "F_02056") == 1 and #g.petalsRefused == 0 and Session.items(h, "F_02056") == 1,
        "still one each a while on")
    -- The other way: the guest picks first. The host takes no story flags from guests: its count came with the word alone.
    local five = flowerOn({ h, g }, "BP_FlowInteract_MemoryFlower_C_UAID_5", "F_02055", { FIVE }, 900.0)
    s:run(2)
    Fake.pickFlower(g, five[2])
    s:run(5)
    check(Session.items(h, "F_02055") == 1 and Session.items(g, "F_02055") == 1 and #h.petalsRefused == 0,
        "the guest picks one first: its petal for the host too, once")
    s:run(6)
    check(Fake.flowerState(h, five[1]) == "gone", "and the host's copy goes")
    check(has(h, FIVE) == 1, "the host's quest counts it")
    check(count(h.sent, "^E MF ") == 1 and count(g.sent, "^E MF ") == 1, "each pick told once, and none told back")
    -- A re-sync: the guest drops out and comes back. The host's bag on joining has both petals; nothing comes twice.
    Session.command(g, "netoff")
    s:run(1)
    Session.command(g, "neton client")
    s:run(20)
    check(Session.items(g, "F_02056") == 1 and Session.items(g, "F_02055") == 1 and #g.petalsRefused == 0,
        "back from a drop: still one each, nothing given again")
    check(has(g, SIX) == 1 and has(h, FIVE) == 1, "and no flag twice")
    -- A quest's flower: a story's (no petal named on it: its quest's flow gives one; viewing it opens a quest, the story
    -- table's "慈母记忆之花"), or a collection's (its quest class named on it, as each of Inanis' flowers names "Resonant
    -- Strings": begun only by the flower's own flow). Its petal comes once; the copy stays for the other player to see.
    local story = flowerOn({ h, g }, "BP_FlowInteract_MemoryFlower_C_UAID_CiMu", "F_02011", {}, 1500.0, "story")
    s:run(2)
    Fake.pickFlower(h, story[1])
    s:run(12)
    check(Session.items(g, "F_02011") == 1 and Fake.flowerState(g, story[2]) == "here",
        "a story's flower: its petal for the guest, once, and the guest's copy stays to be seen")
    local collect = flowerOn({ h, g }, "BP_FlowInteract_MemoryFlower_C_UAID_XianYin", "F_02012", {}, 2100.0, "collect")
    s:run(2)
    Fake.pickFlower(g, collect[2])
    s:run(12)
    check(Session.items(h, "F_02012") == 1 and Fake.flowerState(h, collect[1]) == "here",
        "a collection's flower: its petal for the host, once, and the host's copy stays to be seen")
    -- A flower gone with no petal after it (not a pick: a story's own doing, say) tells nothing, and takes no copy.
    local quiet = flowerOn({ h, g }, "BP_FlowInteract_MemoryFlower_C_UAID_Q", "F_02056", {}, 1800.0)
    s:run(2)
    local sent = count(h.sent, "^E MF ")
    quiet[1]:FlowerDissapear()
    s:run(8)
    check(count(h.sent, "^E MF ") == sent and Fake.flowerState(g, quiet[2]) == "here",
        "a flower gone with no petal after it is told to nobody")
    allErrors(s)

    -- The copy goes only once its petal is here: a guest who's down when the word comes takes the share as they're up.
    local d, dh, dg = pair()
    local late = flowerOn({ dh, dg }, "BP_FlowInteract_MemoryFlower_C_UAID_D", "F_02056", { SIX })
    d:run(2)
    Session.die(dg)
    Fake.pickFlower(dh, late[1])
    d:run(8)
    check(Session.items(dg, "F_02056") == 0 and Fake.flowerState(dg, late[2]) == "here",
        "a guest who's down: their copy waits for the petal")
    Session.revive(dg)
    d:run(10)
    check(Session.items(dg, "F_02056") == 1 and Fake.flowerState(dg, late[2]) == "gone", "up again: the petal, then the copy goes")
    -- A copy that never loads is looked for less often once the word is old.
    local far = flowerOn({ dh, dg }, "BP_FlowInteract_MemoryFlower_C_UAID_F", "F_02055", {}, 2400.0)
    Fake.unloadFlower(far[2])
    d:run(2)
    Fake.pickFlower(dh, far[1])
    d:run(125)
    local before = dg.flowerSearches or 0
    d:run(60)
    local looks = (dg.flowerSearches or 0) - before
    check(looks >= 1 and looks <= 3, "a copy that never loads: looked for every 30 s once the word is old (" .. looks .. " in a minute)")
    allErrors(d)

    -- A copy not loaded at the word: it goes as it loads, and stays gone after (kept with the flower, as the game keeps it).
    local l, lh, lg = pair()
    local four = flowerOn({ lh, lg }, "BP_FlowInteract_MemoryFlower_C_UAID_4", "F_02055", { FOUR })
    Fake.unloadFlower(four[2])
    l:run(2)
    Fake.pickFlower(lh, four[1])
    l:run(4)
    check(Session.items(lg, "F_02055") == 1 and Fake.flowerState(lg, four[2]) == "unloaded",
        "a pick far from the guest: the petal comes, the copy isn't there to go yet")
    Fake.loadFlower(lg, four[2])
    l:run(7)
    check(Fake.flowerState(lg, four[2]) == "gone", "it goes once it loads")
    Fake.unloadFlower(four[2])
    Fake.loadFlower(lg, four[2])
    check(Fake.flowerState(lg, four[2]) == "gone", "and is gone at the next load too")
    local searches = lg.flowerSearches or 0
    l:run(20)
    check((lg.flowerSearches or 0) == searches, "nothing more looked for once it went")
    -- A guest picking the same flower as the host's word comes: theirs plays out, the game vanishes it at its end.
    local same = flowerOn({ lh, lg }, "BP_FlowInteract_MemoryFlower_C_UAID_6b", "F_02056", { SIX }, 1200.0)
    l:run(2)
    Fake.pickFlower(lg, same[2], "start")
    Fake.pickFlower(lh, same[1])
    l:run(5)
    check(Fake.flowerState(lg, same[2]) == "here" and Session.items(lg, "F_02056") == 1,
        "a guest in the middle of picking it keeps their own memory going (the share came)")
    Fake.pickFlower(lg, same[2], "done")
    l:run(3)
    check(Fake.flowerState(lg, same[2]) == "gone" and Session.items(lg, "F_02056") == 1, "and it ends the game's way, one petal")
    allErrors(l)

    -- Three players: a guest's pick reaches the host and the other guest. A petal with a flag of its own while held brings
    -- that too.
    local p = party(nil, nil, { "Host", "Guest", "Guest" })
    local ph, pa, pb = p.pcs[1], p.pcs[2], p.pcs[3]
    local quest = flowerOn({ ph, pa, pb }, "BP_FlowInteract_MemoryFlower_C_UAID_NongShe", "F_02012", {})
    p:run(2)
    Fake.pickFlower(pa, quest[2])
    p:run(6)
    check(Session.items(ph, "F_02012") == 1 and Session.items(pb, "F_02012") == 1 and Session.items(pa, "F_02012") == 1,
        "three players: a guest's petal for the host and the other guest, once each")
    check(Fake.flowerState(ph, quest[1]) == "gone" and Fake.flowerState(pb, quest[3]) == "gone", "both their copies go")
    p:run(6)
    check(has(ph, "jl.弄蛇.记忆之花2") == 1 and has(pb, "jl.弄蛇.记忆之花2") == 1,
        "the petal's own flag while held comes with it")
    check(#ph.petalsRefused == 0 and #pb.petalsRefused == 0, "nothing refused anywhere")
    allErrors(p)

    -- The game keeps more than petals once a save: a book's page named Page_ and a whole flower too (the bench). A partner's
    -- find of either went the share's way (held a moment first) and was lost the same way.
    local k, kh, kg = pair()
    Session.gainItem(kh, "Page_XC_01", 1)
    Session.gainItem(kg, "FA_0201", 1)
    k:run(6)
    check(Session.items(kg, "Page_XC_01") == 1 and Session.items(kh, "FA_0201") == 1 and #kg.petalsRefused == 0
        and #kh.petalsRefused == 0, "a book's page and a whole flower another player found: theirs once, never refused")
    allErrors(k)

    -- A guest who joins after the host's pick: the petal in the host's bag on joining, quietly, once.
    local j, jh, jg = pair(nil, function(ph2)
        ph2.bag:AddPropsByMap({ F_02011 = 1 }, true)
    end)
    j:run(20)
    check(Session.items(jg, "F_02011") == 1 and #jg.petalsRefused == 0, "a petal the host had before the guest joined: theirs once")
    allErrors(j)
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

-- 358: a weapon this PC had to load goes on a partner's figure only once it has been loaded 6 s, and the log says so
-- before the call that gives it. (The fake finds every weapon as loaded: here the host's game has the spear and the
-- cannon only after LoadAsset, as the game has a weapon its own player never held. The seventh review's V8; and V7:
-- one the game let go and this PC loads again waits again, and is said again.)
local function newWeaponWaits()
    part("a partner's weapon new to this PC")
    local SPEAR, CANNON = "/PBZCombatAsset/ActorData/Weapon/Spear.Spear", "/PBZCombatAsset/ActorData/Weapon/Cannon.Cannon"
    local loadedAt = {}
    local s, h, g = pair(nil, function(host)
        local find, nothing = host.env.StaticFindObject, host.env.StaticFindObject("/Nothing/Here.Here")
        host.env.StaticFindObject = function(path)
            if (path == SPEAR or path == CANNON) and not loadedAt[path] then
                return nothing
            end
            return find(path)
        end
        host.env.LoadAsset = function(path)
            loadedAt[path] = loadedAt[path] or host.now
        end
    end)
    Fake.put(field(g.pawn, "Character Weapons Component"), "edgeConfig", nil)      -- (the guest with no Phantom Edge)
    s:run(4)        -- (the figure settled)
    local gear = field(net(h).ghost, "Character Weapons Component")
    local function holds(name)
        local c = field(gear, name)
        return c and rawget(c, "__path")
    end
    local hidden = field(gear, "edgeHidden") == true
    local from = #h.logs
    Session.hold(g, SPEAR, true)
    Session.holdEdge(g, CANNON, false)
    local tookAt, edgeAt, shown
    s:run(10, function()
        tookAt = tookAt or holds("config") == SPEAR and h.now or nil
        edgeAt = edgeAt or holds("edgeConfig") == CANNON and h.now or nil
        shown = shown or (not edgeAt and field(gear, "edgeHidden") ~= true) or nil
    end)
    local wait = tookAt and loadedAt[SPEAR] and tookAt - loadedAt[SPEAR] or -1
    local edgeWait = edgeAt and loadedAt[CANNON] and edgeAt - loadedAt[CANNON] or -1
    check(wait >= 6 and wait <= 7.5 and edgeWait >= 6 and edgeWait <= 7.5,
        string.format("loaded here, the figure's weapon and Phantom Edge wait 6 s: %.2f and %.2f s after the load", wait, edgeWait))
    local said, gave
    for i = from + 1, #h.logs do
        said = said or h.logs[i]:find("The ghost takes Spear, new to this PC.", 1, true) and i or nil
        gave = gave or h.logs[i]:find("The ghost now holds Spear.", 1, true) and i or nil
    end
    check(said and gave and said < gave, "and the log says it's new before the call that gives it")
    -- (The slot hidden for no Phantom Edge is shown only once it holds theirs: shown at once, it showed this PC's own
    -- for the 6 s the new one waited. The seventh review's V6.)
    check(hidden and not shown and edgeAt and field(gear, "edgeHidden") ~= true,
        "the figure's slot, hidden for no Phantom Edge, stays hidden while theirs waits, and shows once it holds it")
    Session.hold(g, "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", true)
    s:run(1)
    Session.hold(g, SPEAR, true)
    s:run(1)
    check(holds("config") == SPEAR and count(h.logs, "new to this PC") == 2,
        "taken again later: no wait, nothing said again (" .. count(h.logs, "new to this PC") .. " lines)")
    Session.hold(g, "/PBZCombatAsset/ActorData/Weapon/Sword.Sword", true)
    s:run(1)
    loadedAt[SPEAR] = nil       -- (the game let it go: nothing held it)
    Session.hold(g, SPEAR, true)
    local again
    s:run(10, function()
        again = again or holds("config") == SPEAR and h.now or nil
    end)
    check(again and loadedAt[SPEAR] and again - loadedAt[SPEAR] >= 6
        and count(h.logs, "The ghost takes Spear, new to this PC.") == 2,
        "let go by the game and loaded again: it waits again, and is said new again ("
            .. count(h.logs, "The ghost takes Spear, new to this PC.") .. " lines)")
    allErrors(s)

    -- 399: the swing sounds' learner (PartnerHitSounds) reads a weapon this PC had to load 10 s after the load, not at
    -- once: it began 0.7 s after it on the bench, at a sync's start, by itself (a report on 1.7.3: the game gone seconds
    -- after two players linked, and not with the setting off).
    local lAt = {}
    local l, lh, lg = pair("PartnerHitSounds = On\n", function(host)
        local find, nothing = host.env.StaticFindObject, host.env.StaticFindObject("/Nothing/Here.Here")
        local playMontage = Fake.object(host, "Class")
        host.env.StaticFindObject = function(path)
            if path == SPEAR and not lAt[path] then
                return nothing
            end
            if path == "/Script/LegoAbility.LGAAction_PlayMontage" then
                return playMontage
            end
            return find(path)
        end
        host.env.LoadAsset = function(path)
            lAt[path] = lAt[path] or host.now
        end
    end)
    l:run(4)
    Session.hold(lg, SPEAR, true)
    local learnedAt
    l:run(18, function()
        learnedAt = learnedAt or (count(lh.logs, "Partner swing sounds: Spear learned") > 0 and lh.now or nil)
    end)
    local lwait = learnedAt and lAt[SPEAR] and learnedAt - lAt[SPEAR] or -1
    check(lwait >= 10 and lwait <= 13,
        string.format("its swing sounds are read 10 s after this PC loaded it, not at once: %.2f s after the load", lwait))
    allErrors(l)

    -- The other way a figure's slot is shown: as the figure comes back into view (the eighth review's V8). The guest,
    -- with no Phantom Edge, goes down, puts one on that this PC has never loaded, and is up again: the slot stays
    -- hidden till the figure holds theirs. Shown as the figure was, it showed this player's own for the 6 s.
    local loadedV = {}
    local v, vh, vg = pair(nil, function(host)
        local find, nothing = host.env.StaticFindObject, host.env.StaticFindObject("/Nothing/Here.Here")
        host.env.StaticFindObject = function(path)
            if path == CANNON and not loadedV[path] then
                return nothing
            end
            return find(path)
        end
        host.env.LoadAsset = function(path)
            loadedV[path] = loadedV[path] or host.now
        end
    end)
    Fake.put(field(vg.pawn, "Character Weapons Component"), "edgeConfig", nil)
    v:run(4)
    local vgear = field(net(vh).ghost, "Character Weapons Component")
    local wasHidden = field(vgear, "edgeHidden") == true
    Session.die(vg)
    v:run(4)
    Session.holdEdge(vg, CANNON, false)
    v:run(1)
    Session.revive(vg)
    local heldAt, shownV
    v:run(12, function()
        local c = field(vgear, "edgeConfig")
        heldAt = heldAt or (c and rawget(c, "__path") == CANNON) and vh.now or nil
        shownV = shownV or (not heldAt and field(vgear, "edgeHidden") ~= true) or nil
    end)
    check(wasHidden and heldAt and not shownV and field(vgear, "edgeHidden") ~= true,
        "a figure back in view whose partner put a Phantom Edge on meanwhile: its slot stays hidden till it holds theirs ("
            .. tostring(wasHidden) .. ", held " .. tostring(heldAt ~= nil) .. ", shown before " .. tostring(shownV) .. ")")
    allErrors(v)
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
    check(field(weapons, "edgeArmed") == true, "still drawn while its skill's montage plays (pull request 20)")
    Fake.put(rawget(h.pawn, "__fields").edgeAnim, "montage", nil)      -- (the skill's montage is over)
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
    Session.bullet(h, h.pawn, flower, 0.0, 0.0, 100.0, false)
    Session.bullet(h, h.pawn, flower, 0.0, 0.0, 100.0, true, true)
    s:run(0.5)
    check(#g.fired == 2 and #h.fired == 0, "not a ghost's, a swing's sweep, or one another bullet started")
    -- (Pull request 20: an enemy's bullet in the host's world comes up in the guest's too, fired there from the guest's
    -- copy of that enemy. Before, a host's archer loosed nothing on the guest's screen unless its copy ran the ability.)
    Session.bullet(h, Session.enemyOn(h, "thug1"), flower, 500.0, 0.0, 100.0)
    s:run(0.5)
    check(#g.fired == 3 and (g.fired[3] or {}).owner == Session.enemyOn(g, "thug1") and #h.fired == 0,
        "an enemy's of the host's world comes up on the guest's too, from the guest's copy of that enemy")
    Session.bullet(g, Session.enemyOn(g, "thug1"), flower, 500.0, 0.0, 100.0)
    s:run(0.5)
    check(#h.fired == 0 and #g.fired == 3, "a guest's copy's own goes nowhere: the host's enemies are the host's to tell")
    table.remove(g.fired, 3)        -- (the counts below are the players' own shots)
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

-- A guest's copy of an enemy is given the host's target, and its own picker told to leave that alone. What's kept of
-- it between turns is numbers and names; a copy with no blackboard isn't handed into the game's own call as nothing;
-- and its picker another one by the time the copy is let go, a new body's, isn't written through. (The seventh
-- review's G6: the shapes 360 and 362 took out on the host were still here.)
local function aCopysPicker()
    part("a guest's copy and its target picker")
    local s, h, g = pair()
    Session.moveTo(h, 1500, 400)
    Session.moveTo(g, 1600, 400)
    s:run(3)
    local copy = Session.enemyOn(g, "thug1")
    local addr = copy:GetAddress()
    local game = g.env.PBZ.game
    game.aimCopy(copy, addr, net(g).ghost)
    local rec, kept = game.copyAim and game.copyAim[addr], 0
    for _, v in pairs(rec or {}) do
        kept = kept + ((type(v) == "table" or type(v) == "userdata") and 1 or 0)
    end
    check(rec ~= nil and kept == 0 and field(field(copy, "picker"), "SwitchTargetCooldown") == 86400.0,
        "what's kept of a copy's picker between turns is numbers and names: nothing of the game's (" .. kept .. ")")
    local lib = g.env.StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local set, none, aimed = rawget(lib, "__fields").SetValueAsObjectByTag, 0, 0
    rawget(lib, "__fields").SetValueAsObjectByTag = function(self, board, tag, target)
        none = none + ((board == nil or rawget(board, "__alive") == false) and 1 or 0)
        aimed = aimed + 1
        return set(self, board, tag, target)
    end
    local controller = field(copy, "Controller")
    local fields = rawget(controller, "__fields")
    local board = fields.Blackboard
    fields.Blackboard = nil
    game.aimCopy(copy, addr, net(g).ghost)
    fields.Blackboard = board
    game.aimCopy(copy, addr, net(g).ghost)
    rawget(lib, "__fields").SetValueAsObjectByTag = set
    check(none == 0 and aimed == 1, "a copy with no blackboard isn't handed into the game's own call as nothing (" .. none
        .. "), and with one it's aimed as ever")
    -- (Another picker there by the time the copy is let go: a new body's at that address. Its own wait is left alone.)
    local old = field(copy, "picker")
    local other = setmetatable({ __addr = 987654320, __class = "AIScript_TargetSelector_C", __alive = true,
        __fields = { LastSwitchTime = -1e9, SwitchTargetCooldown = 3.0 } }, g.meta)
    fields.SGameAIComponent.SpawnedAIScripts.items[1] = other
    Session.command(g, "netoff")
    s:run(1)
    check(rawget(other, "__fields").SwitchTargetCooldown == 3.0 and field(old, "SwitchTargetCooldown") == 86400.0,
        "its picker another one by the time the copy is let go: not written through ("
            .. tostring(rawget(other, "__fields").SwitchTargetCooldown) .. ")")
    fields.SGameAIComponent.SpawnedAIScripts.items[1] = old
    allErrors(s)
end

-- A body with no attributes (the bench, 11-18, a destroyed stand-in still listed till collection, as it turned out:
-- the eighth review; a living body has never been seen so). What 382 said of it, as it read it: a boss coming into a guest's
-- world). Its floor was written on nothing every turn, an error line each in the game's log, and a boss's poise was
-- marked done with nothing set. Asked first: nothing is written till they're there, and then it is.
local function aBodyStillMade()
    part("an enemy the game is still making")
    local s, h, g = pair("CoopBossPoise = 200\n")
    Session.moveTo(h, 1500, 400)
    Session.moveTo(g, 1600, 400)
    s:run(3)
    local copy = Session.enemyOn(g, "thug1")
    local set = field(copy, "AttributeSetBase")
    local floor = rawget(set, "__fields").Health_Min
    rawset(set, "__alive", false)
    Fake.put(floor, "BaseValue", 777)
    Fake.put(floor, "CurrentValue", 777)
    s:run(1)
    check(field(floor, "BaseValue") == 777, "a copy with no attributes yet: its floor isn't written on nothing ("
        .. tostring(field(floor, "BaseValue")) .. ")")
    rawset(set, "__alive", true)
    s:run(1)
    check(field(floor, "BaseValue") < 777, "there again: held at its floor as ever (" .. tostring(field(floor, "BaseValue")) .. ")")
    -- (No attribute set at all for the while, as in the game: a write on it fails there, and here.)
    local none = { IsValid = function() return false end }
    local boss = Fake.enemy(h, "late", "BP_Monster_Boss_C", 1700.0, 600.0, 100.0, 5000, 400, true)
    local bossSet = field(boss, "AttributeSetBase")
    local said = count(h.logs, "at 200%% poise")
    Fake.put(boss, "AttributeSetBase", none)
    s:run(1)
    h.hudLayout:RegisterBossHPBar(boss)
    s:run(3)
    check(count(h.logs, "at 200%% poise") == said, "a boss with no attributes yet: its poise isn't marked done on nothing")
    Fake.put(boss, "AttributeSetBase", bossSet)
    s:run(3)
    check(count(h.logs, "at 200%% poise") == said + 1
        and rawget(bossSet, "__fields").TakenReductionMultiplier_Poise.BaseValue == 0.5,
        "there again: its poise set, and said once (" .. count(h.logs, "at 200%% poise") - said .. ")")
    -- (And co-op's health and guard. Looked at with no attributes it was marked scaled with nothing written: the game's
    -- own numbers for the whole fight. The eighth review.)
    local function most(set, name)
        return field(field(set, name), "CurrentValue")
    end
    check(most(bossSet, "Health_Max") == 7500 and most(bossSet, "Shachi_Max") == 520,
        "and co-op's health and guard with them (150%, 130% here), not the game's own for the fight (" .. tostring(most(bossSet, "Health_Max"))
            .. ", " .. tostring(most(bossSet, "Shachi_Max")) .. ")")
    local thug = Fake.enemy(h, "latethug", THUG, 1750.0, 500.0, 100.0, 600, 100)
    local thugSet = field(thug, "AttributeSetBase")
    -- (What's asked of nothing is an error line each in the game's log: its health is read, nothing of its most.)
    local asked = {}
    Fake.put(thug, "AttributeSetBase", setmetatable({ IsValid = function() return false end },
        { __index = function(_, k) asked[k] = true end }))
    s:run(3)
    check(not (asked.Health_Max or asked.Shachi_Max), "an enemy with no bar and no attributes yet: nothing written on nothing")
    Fake.put(thug, "AttributeSetBase", thugSet)
    s:run(3)
    check(most(thugSet, "Health_Max") == 900 and most(thugSet, "Shachi_Max") == 130,
        "there again: co-op's health and guard (" .. tostring(most(thugSet, "Health_Max")) .. ", " .. tostring(most(thugSet, "Shachi_Max")) .. ")")
    allErrors(s)
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
    check(lang.say("your partner rested at a bell: you're rested, and so is the boss.") == "队友在钟旁休息了:你恢复了,首领也恢复了。",
        "the bell's tips in Chinese")
    check(lang.say("your partner rested at a bell: you'll join them.") == "队友在钟旁休息了:你会前往队友身边。", "both of them")
    check(lang.say("player 3 (gold) rested at a bell: you're rested, and so is the boss.") == "玩家 3(金) 在钟旁休息了:你恢复了,首领也恢复了。",
        "and by name")
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
    th.hudLayout:RegisterBossHPBar(Session.enemyOn(th, "boss"))     -- (a partner's sit tells only a boss fight's player)
    t:run(1)
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

-- Local co-op keeps the difficulty the player chose: the game's own mode and the game's own enemy numbers. (The user,
-- 11-16: "for local coop it is fine to keep it to the same difficulty of the user that he chose since it isn't same as
-- multiplayer coop where everyone has different difficulty". Up to 1.7.3 player 2's Soul counted as a partner, and two
-- on one PC were raised to Hellwalker.)
local function localDifficulty()
    part("local co-op: the player's own difficulty")
    local function most(pc, id)
        local _, hp, posture = Fake.health(Session.enemyOn(pc, id))
        return hp, posture
    end
    local s, pc, state = localGame()
    s:run(30)
    check(pc.env.PBZ.valid(state.p2Pawn) and pc.difficulty == 2,
        "as the ini ships, two on one PC: the player's own Pathbreaker stays (" .. tostring(pc.difficulty) .. ")")
    local hp, posture = most(pc, "near")
    check(hp == 600 and math.abs(posture - 100) < 0.01,
        string.format("and the game's own enemy numbers: no 150%% health, no 130%% posture (%s, %s)", tostring(hp), tostring(posture)))
    check(select(1, most(pc, "boss")) == 5000, "a boss's too")
    check(pc.files["difficulty_own.txt"] == nil and count(pc.logs, "Co%-op difficulty: .* at %d+%% ") == 0,
        "nothing of the co-op difficulty is said or kept")
    -- (Nor is a boss kept at its game's most and its blows cut down, online's way with one whose game holds no more
    -- health than its own, PV1 of the seventh review: a blow takes all it takes, and its game's writes stand.)
    local boss = Session.enemyOn(pc, "boss")
    pc.hudLayout:RegisterBossHPBar(boss)
    s:run(2)
    swing(pc, boss, 4700)
    s:run(1)
    local set = rawget(boss, "__fields").AttributeSetBase
    for _, n in ipairs({ "Health", "Health_Max" }) do
        Fake.put(set[n], "CurrentValue", 4000)
        Fake.put(set[n], "BaseValue", 4000)
    end
    s:run(1)
    swing(pc, boss, 3700)
    s:run(1)
    check(select(1, Fake.health(boss)) == 3700 and select(2, Fake.health(boss)) == 4000
        and count(pc.logs, "holds no more than its own health") == 0,
        "a boss's blows take all they take, and its game's own writes of its numbers stand (" .. tostring((Fake.health(boss))) .. ")")
    -- (Nor is one at a floor of its game's own said to be anyone's alone to finish, online's word for a guest's killing
    -- blow not taken there, 393: one PC, one game, and player 2's blows are that game's own.)
    Fake.put(set.Health_Min, "BaseValue", 1)
    Fake.put(set.Health_Min, "CurrentValue", 1)
    swing(pc, boss, 2)
    s:run(30)
    check(pc.env.PBZ.status.lastShown.finisher == nil and count(pc.sent or {}, "^E FB ") == 0
        and count(pc.logs, "isn't its end") == 0,
        "a boss at a floor of its game's own for half a minute: nothing said of whose it is to finish")
    allErrors(s)
    -- (A mode an older version still holds, the player's own in its file: put back, as for anyone alone.)
    local t = Session.new(SIM_SCRIPTS, { "Local" }, false, ENEMIES)
    local tpc = t.pcs[1]
    tpc.files["difficulty_own.txt"] = "2 3"
    tpc.difficulty = 3
    Session.scene(tpc, false)
    t:run(40)
    check(tpc.difficulty == 2 and tpc.files["difficulty_own.txt"] == nil,
        "Hellwalker held from an older version: back to the player's own Pathbreaker (" .. tostring(tpc.difficulty) .. ")")
    allErrors(t)
end

-- Local co-op: who an enemy goes for. The game's own picker was all there was (the nearest on its list, again and again):
-- with two players in one fight every enemy went for whoever stood a step nearer, and a player's blows drew nothing.
-- The online rule runs there too: how near, whose blows, and a hold.
local function localTargets()
    part("local co-op: who an enemy goes for")
    local MOVE = "/PBZCombatAsset/ActorData/Move/E1.E1"
    local s, pc, state = localGame()
    s:run(2)
    local p2 = state.p2Pawn
    local e = Session.enemyOn(pc, "near")                       -- at 300, 300
    local hm = field(e, "BP_PBZHatredManagerComponent")
    Session.moveTo(pc, 100, 300)                                -- player 1 two metres from it
    Fake.put(p2, "loc", { X = 600.0, Y = 300.0, Z = 100.0 })    -- player 2 three
    hm:AddActorToHatredList(pc.pawn, {})
    hm:AddActorToHatredList(p2, {})
    s:run(4)
    check(field(e, "target") == pc.pawn, "both by it, player 1 a step nearer: it's after player 1")
    -- Player 2's blows land for 10 s, player 1 standing by.
    local swing2 = pc.env.StaticFindObject(MOVE)
    for _ = 1, 100 do
        Fake.put(rawget(p2, "__fields").anim, "montage", swing2)
        Fake.setHealth(e, select(1, Fake.health(e)) - 5)
        s:run(0.1)
    end
    check(field(e, "target") == p2, "player 2's blows land, player 1 standing by: it turns to player 2, a step further off though they are")
    local turns = field(e, "targetChanges") or 0
    Fake.put(rawget(p2, "__fields").anim, "montage", nil)
    s:run(5)
    check(field(e, "target") == p2 and (field(e, "targetChanges") or 0) == turns, "and holds to them for a while after the last blow")
    -- Both gone from it (or it's dead): let go at the next look, as online's turns do, not kept with its body and its
    -- picker till player 2's next down or past a load (the main session's second review, 11-16).
    local steered = pc.env.PBZ.game.aim.steered
    local addr = e:GetAddress()
    check(steered[addr] ~= nil, "(it's steered between the two)")
    -- (Nothing of the game's is kept of it between turns: its body and its picker were, and each is asked of the game
    -- at every turn now. The main session's look at issue 18.)
    local keeps = 0
    for _, v in pairs(steered[addr] or {}) do
        if type(v) == "table" or type(v) == "userdata" then
            keeps = keeps + 1
        end
    end
    check(keeps == 0, "what's kept of a steered enemy between turns is numbers and names: nothing of the game's (" .. keeps .. ")")
    local heldWait = field(field(e, "picker"), "SwitchTargetCooldown")
    Session.moveTo(pc, 4000, 300)
    Fake.put(p2, "loc", { X = 4200.0, Y = 300.0, Z = 100.0 })
    s:run(3)
    check(steered[addr] == nil and heldWait > 1.5 and field(field(e, "picker"), "SwitchTargetCooldown") == 1.5,
        "both walk 37 m from it: let go, its picker its own again (its wait " .. tostring(heldWait) .. " s steered, "
            .. tostring(field(field(e, "picker"), "SwitchTargetCooldown")) .. " s after)")
    Session.moveTo(pc, 100, 300)
    Fake.put(p2, "loc", { X = 600.0, Y = 300.0, Z = 100.0 })
    s:run(2)
    -- A drink draws it, as online (288's rule; on one PC nothing told it till 321: local co-op's own drink counter does).
    s:run(12)                                                   -- (past the hold of its last turn)
    check(field(e, "target") == pc.pawn, "(both by it again, player 1 a step nearer: after player 1)")
    Fake.drink(pc, p2)
    check(pc.env.PBZ.game.aim.healAt[2] ~= nil, "player 2 drinks from the gourd: told to the rule")
    s:run(4)
    check(field(e, "target") == p2, "and the enemy turns to the one who drank")
    -- Player 2 down: nobody to steer between, the game's own picker again.
    Fake.setHealth(p2, 1)
    s:run(3)
    check(field(e, "target") == pc.pawn, "player 2 down: it's after player 1")
    allErrors(s)
    -- One player 2 fights alone, player 1 40 m off: never steered, but what it was hit for is kept. It dies: the record
    -- goes with it, or a later enemy at its address took it over (the third review's V12).
    do
        local d, dpc, dstate = localGame()
        d:run(2)
        local dp2 = dstate.p2Pawn
        local lone, blow = Session.enemyOn(dpc, "near"), dpc.env.StaticFindObject(MOVE)
        Session.moveTo(dpc, 4300, 300)
        d:run(5)                                        -- (a 43 m jump takes player 2 along: put back by it after)
        Fake.put(dp2, "loc", { X = 600.0, Y = 300.0, Z = 100.0 })
        d:run(2)
        field(lone, "BP_PBZHatredManagerComponent"):AddActorToHatredList(dp2, {})
        d:run(2)
        for _ = 1, 40 do
            Fake.put(rawget(dp2, "__fields").anim, "montage", blow)
            Fake.setHealth(lone, select(1, Fake.health(lone)) - 12)
            d:run(0.1)
        end
        Fake.put(rawget(dp2, "__fields").anim, "montage", nil)
        local had = dpc.env.PBZ.game.aim.dmg[lone:GetAddress()] ~= nil
        Fake.setHealth(lone, 0)
        Fake.put(lone, "dead", true)
        d:run(2)
        check(had and dpc.env.PBZ.game.aim.dmg[lone:GetAddress()] == nil,
            "one player 2 fought alone, never steered, dies: what it was hit for goes with it")
        allErrors(d)
    end

    -- A trip with an enemy steered (317: let go as the load begins, by the load's own hook): nothing kept past it, no
    -- error on the old world's bodies. (The third review's G8: no check read the records across a load.)
    local t, tpc, tstate = localGame()
    t:run(2)
    local tp2 = tstate.p2Pawn
    local te = Session.enemyOn(tpc, "near")
    local thm = field(te, "BP_PBZHatredManagerComponent")
    Session.moveTo(tpc, 100, 300)
    Fake.put(tp2, "loc", { X = 600.0, Y = 300.0, Z = 100.0 })
    thm:AddActorToHatredList(tpc.pawn, {})
    thm:AddActorToHatredList(tp2, {})
    local tswing = tpc.env.StaticFindObject(MOVE)
    for _ = 1, 100 do
        Fake.put(rawget(tp2, "__fields").anim, "montage", tswing)
        Fake.setHealth(te, select(1, Fake.health(te)) - 5)
        t:run(0.1)
    end
    check(tpc.env.PBZ.game.aim.steered[te:GetAddress()] ~= nil and field(te, "target") == tp2,
        "(an enemy steered to player 2 by their blows)")
    local loadWait = field(field(te, "picker"), "SwitchTargetCooldown")
    Session.loadMap(tpc)
    check(next(tpc.env.PBZ.game.aim.steered) == nil and next(tpc.env.PBZ.game.aim.dmg) == nil,
        "a load with an enemy steered: let go as the load begins, nothing kept past it")
    -- (By the list as it stood at its last turn, no search as the map goes: the enemy still there has its wait back.)
    check(loadWait > 1.5 and field(field(te, "picker"), "SwitchTargetCooldown") == 1.5,
        "and its picker's own wait is back as the load begins (" .. tostring(loadWait) .. " s steered, "
            .. tostring(field(field(te, "picker"), "SwitchTargetCooldown")) .. " s after)")
    t:run(3)
    allErrors(t)
end

-- Player 2 sees what player 1 sees, by the game's own rules and widgets.
local function localScreen()
    part("player 2's screen")
    local s, pc, state = localGame()
    s:run(1.5)
    local p2 = state.p2Pawn
    Fake.put(p2, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })        -- (the bell straight ahead of their view)
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
    -- (Faced by their own view: the game's IsPlayerFaceToActor answers for player 1's screen.)
    Fake.put(state.p2Controller, "controlRot", { Pitch = 0.0, Yaw = 180.0, Roll = 0.0 })
    rawset(bell, "__behind", nil)
    s:run(0.5)
    check(field(comp, "shown") == false, "behind them, there's no prompt")
    Session.press2(s, "Gamepad_FaceButton_Right")
    check(field(pc.controller, "Pawn") == pc.pawn, "and nothing to press")
    rawset(bell, "__behind", true)
    Fake.put(state.p2Controller, "controlRot", nil)
    s:run(0.5)
    check(field(comp, "shown") == true, "in front of them it's there, whatever player 1's screen says")
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
    -- (The gourd holds 2 and a skill node adds a drink: 3 as the game counts it, and so many are player 2's own.)
    Fake.setHealth(body2, 300)
    Fake.drink(dpc, body2)
    check(Fake.health(body2) == 700, "player 2 has as many charges as the gourd holds with its extra drinks: a third")
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
    -- Its health reading asks for player 1's (the game's Get Health Percentage): theirs is written in by hand.
    local _, max2 = hpc.env.PBZ.game.getHealth(hstate.p2Pawn)
    check(field(hpc.playerHud, "hpShown") == 1, "their bar holds their own health")
    local shows = field(hpc.playerHud, "shows") or 0
    Fake.setHealth(hstate.p2Pawn, max2 / 2)
    h:run(0.2)
    check(field(hpc.playerHud, "hpShown") == 0.5 and (field(hpc.playerHud, "shows") or 0) == shows + 1, "a hit of theirs takes it down, and shows it")
    hpc.playerHud:ForSeq_UpdatePlayerHP(1.0)       -- (the game writing player 1's there as player 1 is hit)
    Fake.setHealth(hpc.pawn, 700)
    h:run(0.2)
    check(field(hpc.playerHud, "hpShown") == 0.5, "player 1's hit leaves theirs as it is")
    Fake.setHealth(hstate.p2Pawn, max2)
    h:run(0.2)
    check(field(hpc.playerHud, "hpShown") == 1, "and it fills again")
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
    check(field(field(bar, "BossName"), "text") == "",
        "with no internal name over it, a boss the codex lacks (" .. tostring(field(field(bar, "BossName"), "text")) .. ")")
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

-- A menu gives every pad to player 1 and shares them out again as it closes, and a player hears a stick only as it moves: player 1
-- ran on for good in the direction player 2's stick held as a menu closed (a player report on 1.7.3, keyboard on player 1). What
-- each player holds is let go as the pads change hands.
local function localSticks()
    part("player 2's stick through a menu")
    local s, pc, state = localGame()
    s:run(1.5)
    local function flushed(c) return field(c, "flushed") or 0 end
    local p1, p2 = flushed(pc.controller), flushed(state.p2Controller)
    pc.paused = true
    s:run(0.5)
    check(flushed(state.p2Controller) == p2 + 1 and flushed(pc.controller) == p1,
        "a menu up: player 2's stick and keys let go, player 1's own left as they are")
    pc.paused = false
    s:run(0.5)
    check(flushed(pc.controller) == p1 + 1 and flushed(state.p2Controller) == p2 + 2,
        "the menu closed: both players' let go, so player 1 doesn't run on with player 2's push")
    allErrors(s)
end

-- Player 2's stick let go and the game not told (416; a report on 1.7.4: "the game doesn't register when the joystick has
-- returned to neutral resulting in the camera spinning or the character running endlessly"). main.dll says whether a pad's
-- sticks are at rest; with player 2's at rest and the game still holding a push of theirs, their controller's input is let
-- go, once.
local function localLetGo()
    part("player 2's stick let go, the game not told")
    local s, pc, state = localGame()
    s:run(1.5)
    local function flushed(c) return field(c, "flushed") or 0 end
    -- (What the game has for player 2's sticks: as GetInputAnalogKeyState answers. Let go of, it has nothing.)
    local has, asked = {}, 0
    Fake.put(state.p2Controller, "GetInputAnalogKeyState", function(_, key)
        asked = asked + 1
        return has[key.KeyName:ToString()] or 0.0
    end)
    local lib = pc.found["/Script/EnhancedInput.Default__EnhancedInputLibrary"]
    Fake.put(lib, "FlushPlayerInput", function(_, c)
        Fake.put(c, "flushed", flushed(c) + 1)
        if c == state.p2Controller then
            has = {}
        end
    end)
    local function pads(two)       -- (player 1's pad in and at rest; player 2's as given)
        pc.files["pads.txt"] = "1 0\n" .. two .. "\n0\n0\n"
    end
    pads("1 1")
    has = { Gamepad_LeftY = 1.0 }
    s:run(1.0)
    local p1, p2 = flushed(pc.controller), flushed(state.p2Controller)
    check(p2 == flushed(state.p2Controller) and asked == 0, "player 2's stick held, as the pad itself says: nothing is let go, nothing asked")
    pads("1 0")
    s:run(0.2)
    check(flushed(state.p2Controller) == p2, "at rest for 0.2 s: not yet")
    s:run(0.4)
    check(flushed(state.p2Controller) == p2 + 1 and flushed(pc.controller) == p1
        and count(pc.logs, "Player 2's stick is at rest and the game still had it pushed %(Gamepad_LeftY 1.00%)") == 1,
        "at rest for half a second, and the game still has their push: player 2's input is let go, player 1's left alone, said")
    local looks = asked
    s:run(5)
    check(flushed(state.p2Controller) == p2 + 1 and asked <= looks + 4,
        "then nothing more while it rests: looked at once more a second in, not all the while (" .. (asked - looks) .. " more asks in 5 s)")
    -- The camera's stick the same way, at the next rest.
    pads("2 1")
    s:run(0.5)
    has = { Gamepad_RightX = -0.8 }
    pads("2 0")
    s:run(0.6)
    check(flushed(state.p2Controller) == p2 + 2, "the camera's stick, a button held meanwhile: the same")
    -- What a resting stick still shows (a little off the middle) is no push.
    pads("1 1")
    s:run(0.5)
    has = { Gamepad_LeftX = 0.2 }
    pads("1 0")
    s:run(2)
    check(flushed(state.p2Controller) == p2 + 2, "a stick a little off its middle at rest (0.2): not taken for a push")
    -- An older main.dll says nothing of the sticks; a pad that isn't in says nothing either.
    has = { Gamepad_LeftY = 1.0 }
    pc.files["pads.txt"] = "1\n1\n0\n0\n"
    s:run(2)
    local old = flushed(state.p2Controller)
    pc.files["pads.txt"] = "1 0\n0\n0\n0\n"
    s:run(2)
    check(old == p2 + 2 and flushed(state.p2Controller) >= p2 + 2 and count(pc.logs, "still had it pushed") == 2,
        "an older main.dll's file (no word on the sticks), or their pad not in: nothing is let go for a stick")
    allErrors(s)
end

-- The game's rise-up for a Soul back from down turns "cancel the player controller" on in player 1's input whichever Soul rises: player
-- 1 stood frozen through all of player 2's (a player report on 1.7.3). It's put back while player 2 rises.
local function localRise()
    part("player 2's rise-up, player 1 free")
    local s, pc, state = localGame()
    s:run(1.5)
    local input = field(pc.pawn, "PBZNBInput")
    local resets = field(input, "resets") or 0
    Fake.setHealth(state.p2Pawn, 1)
    s:run(1.5)
    check(field(input, "bCurrentCancelPlayerController") ~= true, "player 2 down: player 1's input as it was")
    s:run(5.5)
    check(field(state.p2Pawn, "used") == pc.riseClass, "player 2 back, rising the game's way")
    s:run(0.3)
    check(field(input, "bCurrentCancelPlayerController") == false and (field(input, "resets") or 0) > resets,
        "and player 1's input not left cancelled by it: player 1 can move")
    check(count(pc.logs, "held player 1 still") == 1, "said once")
    allErrors(s)
end

-- Player 2 back from down, or brought back from a long fall, is set down beside player 1 where there's floor: to the right as
-- before, else the left, behind, in front, else on player 1's own spot. Straight to the right by a cliff's edge put them over the
-- drop at every comeback, down again each time till player 1 moved (the stability session's bench, 11-16).
local function localGround()
    part("player 2 set down where there's floor")
    local s, pc, state = localGame()
    s:run(1.5)
    local traces = Fake.traces(pc)
    local here = at(pc.pawn)
    local yaw = math.rad(field(pc.pawn, "yaw") or 0)
    local function side(turn)
        local a = yaw + math.rad(turn)
        return { X = here.X + math.cos(a) * 200, Y = here.Y + math.sin(a) * 200 }
    end
    local function near(l, p, cm)
        return l ~= nil and gap(l, p) <= (cm or 20)
    end
    local function backFromDown()
        Fake.setHealth(state.p2Pawn, 1)
        s:run(7.0)
        return at(state.p2Pawn)
    end
    local right, left = side(90), side(-90)
    check(near(backFromDown(), right) and field(traces, "traced") > 0, "floor all round: back on player 1's right, as before")
    pc.noFloor = function(l) return near(l, right, 50) end
    local back = backFromDown()
    check(near(back, left) and back.Z > 100, "a drop on player 1's right, as at a cliff's edge: back on their left, on its floor")
    check(count(pc.logs, "No floor to the right: set down on the left") == 1, "said so")
    pc.noFloor = function(l) return not near(l, here, 50) end
    check(near(backFromDown(), here, 1), "no floor on any side: on player 1's own spot")
    pc.noFloor = function(l) return near(l, right, 50) end
    Fake.put(field(state.p2Pawn, "CharacterMovement"), "MovementMode", 3)     -- (falling, then down from it)
    s:run(1.5)
    Fake.setHealth(state.p2Pawn, 1)
    s:run(7.0)
    local said = count(pc.logs, "fell out of the world")
    local cmc = field(state.p2Pawn, "CharacterMovement")
    Fake.put(cmc, "MovementMode", 3)
    s:run(2.0)
    check(count(pc.logs, "fell out of the world") == said,
        "the old Soul's fall isn't the new one's: its first slip isn't a fall out of the world")
    s:run(5.0)
    check(count(pc.logs, "fell out of the world") == said + 1 and near(at(state.p2Pawn), left) and (field(cmc, "stopped") or 0) > 0,
        "a long fall still is: brought back where there's floor, its speed stopped")
    Fake.put(cmc, "MovementMode", 1)
    pc.noFloor = nil
    allErrors(s)
end

-- Player 1 set down where there is no world (414). A report on 1.7.4, local co-op, with its play log: player 1 killed in a
-- boss's fight, taken 3164 m off by the game within 1.5 s and up again there with no floor under them: down from the fall a
-- second later, brought back to the same place by the mod's own respawns, and so on for the eight minutes of the log. After
-- a far move at once, a player 1 falling with nothing under them is held still where the move left them: till the game
-- moves them on, till there is floor, or for 20 s, then back to where they last stood. A fall in play isn't that.
local function localVoid()
    part("player 1 set down where there's no world")
    local s, pc, state = localGame()
    s:run(1.5)
    Fake.traces(pc)
    local p1 = pc.pawn
    local function mode(body)
        return field(field(body, "CharacterMovement"), "MovementMode")
    end
    local function setMode(body, m)
        Fake.put(field(body, "CharacterMovement"), "MovementMode", m)
    end
    local function place(body)
        local l = at(body)
        return { X = l.X, Y = l.Y, Z = l.Z }
    end
    -- (The sim has no gravity: a falling body drops 18 m a second here, and lands where there is ground. pc.noFloor: no
    -- floor for a line down to find; pc.noGround: one a line finds and a body falls through.)
    local function gravity()
        for _, body in ipairs({ p1, state.p2Pawn }) do
            local l = body and at(body)
            local floor = l and not (pc.noFloor and pc.noFloor({ X = l.X, Y = l.Y, Z = 10 }))
                and not (pc.noGround and pc.noGround({ X = l.X, Y = l.Y, Z = 10 }))
            if body and mode(body) == 1 and not floor then
                setMode(body, 3)
            end
            if body and mode(body) == 3 then
                if floor and l.Z > 100 and l.Z - 30 <= 100 then
                    Fake.put(body, "loc", { X = l.X, Y = l.Y, Z = 100.0 })
                    setMode(body, 1)
                elseif not floor or l.Z > 100 then
                    Fake.put(body, "loc", { X = l.X, Y = l.Y, Z = l.Z - 30 })
                else
                    setMode(body, 1)
                end
            end
        end
    end
    -- The game's own move of player 1, far at once, to a place in the air: they fall from there.
    local function taken(to)
        Fake.put(p1, "loc", { X = to.X, Y = to.Y, Z = to.Z })
        setMode(p1, 3)
    end
    local function said(words)
        return count(pc.logs, words)
    end
    local home = place(p1)
    s:run(1.0, gravity)
    local hp = select(1, Fake.health(p1))

    -- The report's: nothing under the place the game took player 1 to, nor for 500 m around, for good.
    local A = { X = -333450.0, Y = 249935.0, Z = 5000.0 }
    pc.noFloor = function(l) return gap(l, A) < 50000 end
    taken(A)
    s:run(0.8, gravity)
    check(mode(p1) == 0 and gap(at(p1), A) < 1 and A.Z - at(p1).Z < 400 and said("Player 1 falls after a far move: held") == 1,
        string.format("the game takes player 1 3 km off, to where there's no floor: held still where it left them, %.0f cm down, said once",
            A.Z - at(p1).Z))
    s:run(1.7, gravity)
    local p2 = state.p2Pawn
    check(mode(p2) == 5 and gap(at(p2), at(p1)) < 400, "player 2 is taken along, held in the air as on any far move")
    s:run(10, gravity)
    check(mode(p1) == 0 and mode(state.p2Pawn) == 5 and select(1, Fake.health(p1)) == hp and said("Both players are down") == 0
        and said("Player 1 is back") == 0 and said("Player 2 is down") == 0,
        "twelve seconds on: both held there still, unhurt, nobody down and nobody respawned")
    s:run(10, gravity)
    check(said("No ground under player 1 for 20 s: taken back to where they last stood") == 1 and mode(p1) == 1
        and gap(at(p1), home) < 1 and math.abs(at(p1).Z - 105) < 1 and said("The ground is there under player 1") == 1,
        string.format("no floor in 20 s and no move of the game's: taken back to where they last stood, and set down on its floor (%.0f cm from it, height %.0f)",
            gap(at(p1), home), at(p1).Z))
    s:run(1, gravity)
    check(mode(state.p2Pawn) == 1 and gap(at(state.p2Pawn), at(p1)) < 300 and at(state.p2Pawn).Z < 300,
        string.format("player 2 beside them there, on the floor (%.0f cm off)", gap(at(state.p2Pawn), at(p1))))

    -- The world comes in under them while they are held: set down on it.
    s:run(2, gravity)
    local B = { X = 400000.0, Y = 0.0, Z = 600.0 }
    pc.noFloor = function(l) return gap(l, B) < 50000 end
    taken(B)
    s:run(3, gravity)
    local held = mode(p1) == 0
    pc.noFloor = nil
    s:run(1.6, gravity)
    check(held and mode(p1) == 1 and gap(at(p1), B) < 1 and math.abs(at(p1).Z - 105) < 1 and said("The ground is there under player 1") == 2,
        "held again at another place; its world comes in 3 s later: set on the floor under them, and standing on it a second, let be")
    s:run(1, gravity)
    check(mode(state.p2Pawn) == 1 and gap(at(state.p2Pawn), at(p1)) < 300 and at(state.p2Pawn).Z < 300, "player 2 beside them on it")

    -- The game moves player 1 on while they are held (its own next step, to a place with floor): let go at once.
    s:run(2, gravity)
    local C, D = { X = 800000.0, Y = 0.0, Z = 3000.0 }, { X = 800000.0, Y = 300000.0, Z = 100.0 }
    pc.noFloor = function(l) return gap(l, C) < 50000 end
    taken(C)
    s:run(2, gravity)
    held = mode(p1) == 0
    Fake.put(p1, "loc", { X = D.X, Y = D.Y, Z = D.Z })
    s:run(0.5, gravity)
    check(held and said("Player 1 was moved on by the game: let go") == 1 and mode(p1) == 1 and gap(at(p1), D) < 1,
        "the game moves player 1 on while they are held: let go at once, standing where it put them")

    -- A floor a line down finds and a body falls through (the land's far look, in before its ground: the bench, run255):
    -- set on it they fall, are held again, and it is tried again each second till it holds.
    s:run(3, gravity)
    local F = { X = -600000.0, Y = 0.0, Z = 600.0 }
    pc.noGround = function(l) return gap(l, F) < 50000 end
    taken(F)
    local lowest = F.Z
    s:run(3.5, function()
        gravity()
        lowest = math.min(lowest, at(p1).Z)
    end)
    local tried = said("What is under player 1 doesn't hold them yet")
    check(tried == 1 and lowest > 105 - 400 and select(1, Fake.health(p1)) == hp and said("The ground is there under player 1") == 2,
        string.format("a floor that doesn't hold yet: set on it they fall, and are held again each time, never more than %.0f cm under it", 105 - lowest))
    pc.noGround = nil
    s:run(2.5, gravity)
    check(mode(p1) == 1 and gap(at(p1), F) < 1 and math.abs(at(p1).Z - 105) < 1 and said("The ground is there under player 1") == 3,
        "its ground comes in: the next try holds, and a second on they are let be")

    -- The report's own, as the bench had it (run255): both players down far from their bell, the mod's "back to the bell"
    -- (the game's Respawn, by hand) sets player 1 down where the ground isn't in yet.
    s:run(3, gravity)
    local R = { X = 0.0, Y = -700000.0, Z = 600.0 }
    Fake.put(p1, "Respawn", function(self)
        Fake.put(self, "respawned", (field(self, "respawned") or 0) + 1)
        Fake.put(self, "dead", false)
        Fake.put(self, "loc", { X = R.X, Y = R.Y, Z = R.Z })
        setMode(self, 3)
    end)
    pc.noGround = function(l) return gap(l, R) < 50000 end
    Fake.setHealth(state.p2Pawn, 1)
    Session.die(pc)
    local heldBefore = said("Player 1 falls after a far move: held")
    s:run(6.4, gravity)
    lowest = R.Z
    s:run(4, function()
        gravity()
        if gap(at(p1), R) < 100 then
            lowest = math.min(lowest, at(p1).Z)
        end
    end)
    check(said("Both players are down: back to the bell") == 1 and field(p1, "respawned") == 1 and gap(at(p1), R) < 1
        and lowest > 105 - 400 and said("Player 1 falls after a far move: held") == heldBefore + 1,
        string.format("both down far from their bell, the game's respawn sets player 1 where the ground isn't in: held there, never more than %.0f cm under its floor (%d respawns)",
            105 - lowest, field(p1, "respawned") or 0))
    pc.noGround = nil
    s:run(2.5, gravity)
    check(mode(p1) == 1 and gap(at(p1), R) < 1 and math.abs(at(p1).Z - 105) < 1 and said("Both players are down") == 1
        and field(p1, "respawned") == 1, "its ground comes in: they stand at their bell, respawned once")
    s:run(8, gravity)
    -- A scene of the game's: one held already is left as it is through it, not taken back by the clock, and set down
    -- after it where the scene took them; a fall that begins in a scene is the scene's own (the game's respawn is one
    -- to it, and goes its own way: the bench, run263 and 265).
    local S, S2 = { X = 0.0, Y = 900000.0, Z = 600.0 }, { X = 2000.0, Y = 900000.0, Z = 600.0 }
    pc.noGround = function(l) return gap(l, S) < 50000 end
    heldBefore = said("Player 1 falls after a far move: held")
    taken(S)
    s:run(1.0, gravity)
    local heldFirst = mode(p1) == 0 and said("Player 1 falls after a far move: held") == heldBefore + 1
    local backs = said("taken back to where they last stood")
    Session.scene(pc, true)
    s:run(22, gravity)
    check(heldFirst and mode(p1) == 0 and gap(at(p1), S) < 1 and said("taken back to where they last stood") == backs,
        "a scene begins while they are held: left as they are through it, not taken back by the clock (22 s on)")
    Fake.put(p1, "loc", { X = S2.X, Y = S2.Y, Z = S2.Z })       -- (the scene's own hand: 20 m on)
    s:run(0.5, gravity)
    Session.scene(pc, false)
    pc.noGround = nil
    s:run(3.0, gravity)
    check(mode(p1) == 1 and gap(at(p1), S2) < 1 and math.abs(at(p1).Z - 105) < 1 and said("taken back to where they last stood") == backs,
        string.format("the scene over: set down where it took them (%.0f cm from it), the 20 s counted from its end", gap(at(p1), S2)))
    s:run(3, gravity)
    local T = { X = 0.0, Y = 1200000.0, Z = 600.0 }
    pc.noGround = function(l) return gap(l, T) < 50000 end
    Session.scene(pc, true)
    s:run(0.5, gravity)
    heldBefore = said("Player 1 falls after a far move: held")
    taken(T)
    s:run(1.0, gravity)
    check(mode(p1) == 3 and said("Player 1 falls after a far move: held") == heldBefore,
        "a far move and a fall inside a scene (the game's own respawn is one): the scene's own, nobody is held")
    pc.noGround = nil
    Fake.put(p1, "loc", { X = T.X, Y = T.Y, Z = 100.0 })
    setMode(p1, 1)
    Session.scene(pc, false)
    s:run(14, gravity)

    -- A fall in play, no far move before it: the game's own.
    s:run(5, gravity)
    pc.noFloor = function() return true end
    local holds = said("Player 1 falls after a far move")
    setMode(p1, 3)
    s:run(1.5, gravity)
    check(mode(p1) == 3 and said("Player 1 falls after a far move") == holds, "a fall into a pit in play, no far move before it: nobody is held")
    pc.noFloor = nil
    Fake.put(p1, "loc", { X = D.X, Y = D.Y, Z = D.Z })
    setMode(p1, 1)
    s:run(1, gravity)
    -- A far move onto ground, and a pit there later: not held either.
    local E = { X = 0.0, Y = 600000.0, Z = 100.0 }
    Fake.put(p1, "loc", { X = E.X, Y = E.Y, Z = E.Z })
    s:run(3, gravity)
    pc.noFloor = function() return true end
    setMode(p1, 3)
    s:run(1.5, gravity)
    check(mode(p1) == 3 and said("Player 1 falls after a far move") == holds,
        "a far move onto ground they stood on for a second, then a pit: nobody is held")
    pc.noFloor = nil
    allErrors(s)
end

-- A player 2 off alone wakes the spawners around them, as the game does around player 1 (lone-P2 enemies). Not the ones
-- the story brings (415): a report on 1.7.4, local co-op, Mu Xiaokui "had all the phases at once", and an enemy of a scene
-- stood in another boss's arena.
local function localStorySpawners()
    part("player 2 alone leaves the story's enemies to the game")
    local s, pc, state = localGame()
    s:run(1.5)
    local far = { X = 500000.0, Y = 0.0, Z = 100.0 }
    local function spawnerOf(id, dx)
        Fake.enemy(pc, id, THUG, far.X + dx, far.Y + 500.0, 100.0, 600, 100)
        local sp = pc.spawners[#pc.spawners]
        rawset(sp, "__name", "BP_AISpawner_C_" .. id)       -- (each its own actor's name: a spawner is woken once by it)
        Fake.put(sp, "SpawnedAI", nil)      -- (nothing out yet)
        return sp
    end
    local camp, first, second, later = spawnerOf("camp9", 0), spawnerOf("MuXiaoKui_Seq045", 300), spawnerOf("MuXiaoKuiP2_Seq046new", 600),
        spawnerOf("LeiDangP2", 900)
    Fake.put(state.p2Pawn, "loc", { X = far.X, Y = far.Y, Z = far.Z })
    s:run(5)
    local function claimed(sp)
        return field(sp, "claimed") or 0
    end
    check(claimed(camp) == 1 and count(pc.logs, "Woke 1 enemies around player 2") == 1,
        "a camp's spawner by a player 2 off alone is woken, as before (" .. claimed(camp) .. ")")
    check(claimed(first) == 0 and claimed(second) == 0 and claimed(later) == 0,
        "a boss's phases and a scene's enemies, named for their sequence or their later phase, are left for the game to bring ("
        .. claimed(first) .. ", " .. claimed(second) .. ", " .. claimed(later) .. ")")
    allErrors(s)
end

-- Player 2's Options (BUGHUNT 248): the game's menu layer takes every joystick's as player 1's, so main.dll keeps pad 2's
-- from it while the mod asks, every frame in play, and the mod opens player 2's menu for each press kept.
-- Player 2's Cross and Circle do what player 1's do, by the game's own sets and its own rule for a climb spot (11-12).
local function localButtons()
    part("player 2's Cross and Circle")
    local s, pc, state = localGame()
    s:run(1.5)
    local p2 = state.p2Pawn
    local climbSet, useSet = pc.promptSets.IMC_InteractionSpecialMove, pc.promptSets.IMC_Interaction
    local used = function() return field(field(p2, "interact"), "used") end
    Fake.put(p2, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    local run = Fake.volume(pc, "BP_SpecialMove_UpRunning_C", 8000.0, 0.0, 100.0)
    s:run(0.5)
    check(pc.inputSets[1][climbSet] == 1000 and pc.inputSets[1][useSet] == nil, "at a wall run the game offers, Cross is theirs to climb with: its set over the rest")
    check(pc.inputSets[0][climbSet] == nil, "player 1's buttons don't change")
    local before = #used()
    Session.press2(s, "Gamepad_FaceButton_Bottom")
    check(#used() == before + 1 and used()[#used()] == run, "and Cross starts it")
    Fake.put(field(p2, "CharacterMovement"), "MovementMode", 5)        -- (the run under way, then over)
    s:run(1.0)
    Fake.put(field(p2, "CharacterMovement"), "MovementMode", 1)
    rawset(run, "__invalid", true)
    s:run(0.5)
    check(pc.inputSets[1][climbSet] == nil, "where the game wouldn't offer it (the ledge above, a ladder from behind), the set goes")
    before = #used()
    Session.press2(s, "Gamepad_FaceButton_Bottom")
    s:run(1.0)
    check(#used() == before, "and Cross stays the plain jump it is for player 1")
    rawset(run, "__invalid", nil)
    rawset(p2, "__tags", { ["CharacterState.Action.Phase.Act"] = 1 })
    s:run(0.5)
    check(pc.inputSets[1][climbSet] == nil, "nor in the middle of a swing, as the game says for player 1")
    rawset(p2, "__tags", nil)
    s:run(0.5)
    check(pc.inputSets[1][climbSet] == 1000, "and it's back after the swing")
    local chest = Fake.switch(pc, "BP_Chest_C", 7960.0, 0.0, 100.0)
    s:run(2.6)          -- (what's newly streamed in is looked for every two seconds or so)
    check(pc.inputSets[1][useSet] == 1000 and pc.inputSets[1][climbSet] == nil, "a chest nearer than the climb: what's offered is the chest, and Circle uses")
    before = #used()
    Session.press2(s, "Gamepad_FaceButton_Bottom")
    s:run(0.5)
    check(#used() == before, "and Cross is a jump, not the climb behind it")
    check(pc.inputSets[0][useSet] == nil, "still none of it on player 1")
    Fake.put(state.p2Controller, "controlRot", { Pitch = 0.0, Yaw = 180.0, Roll = 0.0 })
    s:run(0.5)
    check(pc.inputSets[1][useSet] == nil and pc.inputSets[1][climbSet] == 1000, "turned away from the chest, it isn't offered: the climb is")
    Fake.put(state.p2Controller, "controlRot", nil)
    pc.paused = true
    s:run(0.5)
    check(pc.inputSets[1][useSet] == nil and pc.inputSets[1][climbSet] == nil, "and neither set while a menu is up")
    pc.paused = false
    s:run(0.5)
    rawset(chest, "__forbidden", true)
    rawset(run, "__invalid", true)
    s:run(0.5)
    check(pc.inputSets[1][useSet] == nil and pc.inputSets[1][climbSet] == nil, "nothing offered, no set: Circle is the execution button again")
    allErrors(s)

    -- Select: the game's sense-only set over player 2's others (the hold is the sense; the map's tap isn't the game's for them), and
    -- a tap opens their own menu on the map.
    local m, mpc, mstate = localGame()
    m:run(1.5)
    check(mpc.inputSets[1][mpc.senseSet] == 100 and mpc.inputSets[0][mpc.senseSet] == nil, "the sense-only set on player 2's pad, not player 1's")
    local n0 = #mpc.injected
    -- (Player 2's own menu as loadout.lua starts it, which the fake game's bag doesn't go as far as.)
    local loadout = mpc.env.PBZ.loadout
    local begin = loadout.begin
    loadout.begin = function() return false end
    Session.press2(m, "Gamepad_Special_Left")
    check(#mpc.injected == n0, "a tap when their own menu can't start: no map, as a shared one would put their choices on player 1")
    loadout.begin = function() return true end
    Session.press2(m, "Gamepad_Special_Left")
    check(#mpc.injected == n0 + 1 and mpc.injected[#mpc.injected] == "IA_Map", "a tap of Select asks for the map, their own menu started")
    loadout.begin = begin
    mpc.keys2["Gamepad_Special_Left"] = true
    m:run(0.6)
    mpc.keys2["Gamepad_Special_Left"] = false
    m:run(0.2)
    check(#mpc.injected == n0 + 1, "a hold is the sense, the game's: no map")
    allErrors(m)

    -- Screens the game plays on under keep player 2's pad theirs; a menu still shares both.
    local t, tpc, tstate = localGame()
    t:run(1.5)
    local title = Fake.screen(tpc, "WB_ChapterIntro_C")
    title.InputConfig, title.bPauseGameWhenOpen = 2, false
    t:run(0.6)
    check(tpc.fullWidth ~= true and field(tstate.p2Controller, "ignored") ~= true, "a chapter's title: the split stays and player 2 plays on")
    tpc.screens[1] = nil
    local tip = Fake.screen(tpc, "WB_hud_tutorial_C")
    tip.InputConfig, tip.bPauseGameWhenOpen = 1, false
    t:run(0.6)
    check(tpc.fullWidth ~= true and field(tstate.p2Controller, "ignored") ~= true, "a tip that doesn't pause: the same")
    tpc.screens[1] = nil
    local page = Fake.screen(tpc, "WB_Hud_tutorial_Complex_C")
    page.InputConfig, page.bPauseGameWhenOpen = 3, false
    t:run(0.6)
    check(tpc.fullWidth == true, "a page that takes the menu's buttons is a menu, full width, both pads on it")
    tpc.screens[1] = nil
    t:run(0.6)
    check(tpc.fullWidth ~= true, "and the split's back after it")
    local load = Fake.screen(tpc, "WB_AdditionalLoading_C")
    load.InputConfig, load.bPauseGameWhenOpen = 2, false
    t:run(0.6)
    check(tpc.fullWidth == true, "a load is still one: a world not there yet holds them both")
    tpc.screens[1] = nil
    t:run(0.6)
    allErrors(t)
end

-- Player 2 in a fight as the game puts player 1 in one: its InCombat while an enemy in combat hates them (11-12).
local function localFight()
    part("player 2 in a fight")
    local c, cpc, cstate = localGame()
    c:run(1.5)
    local p2 = cstate.p2Pawn
    local inFight = function(body) return (rawget(body, "__tags") or {})["CharacterState.InCombat"] or 0 end
    local foe = Session.enemyOn(cpc, "thug1")
    field(foe, "BP_PBZHatredManagerComponent"):AddActorToHatredList(p2, {})
    c:run(1.2)
    check(inFight(p2) == 0, "hated by an enemy that isn't fighting yet: not in a fight")
    rawset(foe, "__tags", { ["AI.State.Combat"] = 1 })
    c:run(1.2)
    check(inFight(p2) == 1, "an enemy in combat after them: in a fight, as the game has player 1 (its camera, its stance)")
    c:run(1.0)
    check(inFight(p2) == 1, "once, however long it lasts")
    check(inFight(cpc.pawn) == 0, "and player 1 isn't put in it for them")
    rawset(foe, "__tags", nil)
    c:run(1.2)
    check(inFight(p2) == 0, "the enemy out of combat: out of the fight")
    rawset(foe, "__tags", { ["AI.State.Combat"] = 1 })
    c:run(1.2)
    check(inFight(p2) == 1, "back in")
    Fake.setHealth(foe, 0)
    c:run(1.2)
    check(inFight(p2) == 0, "and out when it dies")
    allErrors(c)

    -- Down is out of the fight, as a partner down online: off the enemy's list, and the enemy turns to player 1.
    local d, dpc, dstate = localGame()
    d:run(1.5)
    local body = dstate.p2Pawn
    local thug = Session.enemyOn(dpc, "thug2")
    local hm = field(thug, "BP_PBZHatredManagerComponent")
    hm:AddActorToHatredList(body, {})
    rawset(thug, "__tags", { ["AI.State.Combat"] = 1 })
    d:run(1.2)
    check(inFight(body) == 1, "a thug fighting player 2")
    Fake.setHealth(body, 1)
    d:run(1.2)
    local listed = {}
    for _, a in ipairs(rawget(hm, "__fields").HatredList.items) do
        listed[a] = true
    end
    check(not listed[body], "down, they're off its list")
    check(field(field(body, "BP_PBZHatredManagerComponent"), "CanBeHatredNow") == false, "and can't be put back on it while down")
    check(listed[dpc.pawn] == true, "player 1 is on it, so it has someone to turn to")
    check(inFight(body) == 0, "and they're out of the fight")
    check(field(field(body, "faction"), "faction") == "Faction.Environment", "their body on the ground is the scenery's side: no enemy's eyes put it back")
    allErrors(d)

    -- A thug fighting player 2 far from player 1 leaves player 1 out of it; with player 1 near, or the fight over, as the game has it.
    local f, fpc, fstate = localGame()
    f:run(1.5)
    local p2f, p1f = fstate.p2Pawn, fpc.pawn
    local thug = Session.enemyOn(fpc, "thug1")
    Fake.put(thug, "loc", { X = 6000.0, Y = 0.0, Z = 100.0 })
    Fake.put(p2f, "loc", { X = 5900.0, Y = 0.0, Z = 100.0 })
    local thm = field(thug, "BP_PBZHatredManagerComponent")
    thm:AddActorToHatredList(p2f, {})
    thm:AddActorToHatredList(p1f, {})
    rawset(thug, "__tags", { ["AI.State.Combat"] = 1 })
    f:run(1.2)
    local on = function(who)
        for _, a in ipairs(rawget(thm, "__fields").HatredList.items) do
            if a == who then return true end
        end
        return false
    end
    local rel = function() return field(thug, "faction"):GetFactionRelation(p1f) end
    check(rel() == 1 and not on(p1f) and on(p2f), "a thug fighting player 2 with player 1 60 m off: player 1 neither side to it, and off its list")
    check(inFight(p1f) == 0, "player 1 isn't in a fight they never saw")
    thm:AddActorToHatredList(p1f, {})
    f:run(1.2)
    check(not on(p1f) and rel() == 1, "the game putting them back on its list: off again at the next look")
    Fake.put(p1f, "loc", { X = 5000.0, Y = 0.0, Z = 100.0 })
    f:run(1.2)
    check(rel() == 2, "player 1 near: the game's own again")
    Fake.put(p1f, "loc", { X = 0.0, Y = 0.0, Z = 100.0 })
    f:run(1.2)
    check(rel() == 1, "far again: out of it again")
    rawset(thug, "__tags", nil)
    f:run(1.2)
    check(rel() == 2, "and the fight over, the game's own")
    -- (360: a thug with no controller, a camp put away by its spawner, isn't handed into the game's GetTargetActor as
    -- nothing by either pass: player 1 taken off its list from afar, its bar by player 2. The seventh review's V9.)
    do
        local lib = fpc.env.StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
        local ask, none = rawget(lib, "__fields").GetTargetActor, 0
        rawget(lib, "__fields").GetTargetActor = function(self, c, o)
            none = none + ((c == nil or rawget(c, "__alive") == false) and 1 or 0)
            return ask(self, c, o)
        end
        local had = field(thug, "Controller")
        Fake.put(thug, "Controller", setmetatable({ __addr = 8, __class = "AIController", __alive = false, __fields = {} }, fpc.meta))
        rawset(thug, "__tags", { ["AI.State.Combat"] = 1 })
        thm:AddActorToHatredList(p1f, {})
        f:run(1.2)
        Fake.put(thug, "Controller", had)
        rawset(thug, "__tags", nil)
        rawget(lib, "__fields").GetTargetActor = ask
        check(none == 0, "a thug with no controller isn't handed into the game's GetTargetActor (" .. none .. ")")
    end
    allErrors(f)

    -- An enemy's health bar over its head in the half of whoever it's after.
    local h, hpc, hstate = localGame()
    h:run(1.5)
    local foe2 = Session.enemyOn(hpc, "thug1")
    local bar = field(foe2, "hpbar")
    Fake.put(foe2, "target", hstate.p2Pawn)
    h:run(1.2)
    check(field(bar, "ownerPlayer") == field(hstate.p2Controller, "Player"), "after player 2: its bar in their half")
    Fake.setHealth(foe2, 300)
    h:run(1.2)
    check(field(bar, "bHiddenInGame") == false, "and up once it's hurt, as the game puts it up for player 1's blows")
    Fake.put(foe2, "target", hpc.pawn)
    h:run(1.2)
    check(field(bar, "ownerPlayer") == field(hpc.controller, "Player"), "after player 1: in player 1's")
    check(field(bar, "bHiddenInGame") == true, "and the one we put up goes again")
    Fake.put(foe2, "target", hstate.p2Pawn)
    h:run(1.2)
    Fake.setHealth(hstate.p2Pawn, 1)
    h:run(1.2)
    check(field(bar, "ownerPlayer") == field(hpc.controller, "Player"), "player 2 down: every bar back in player 1's")
    allErrors(h)
end

local function localOptions()
    part("player 2's Options, kept by main.dll")
    local s, pc = localGame()
    local asks, kept = {}, 0
    pc.env.PBZ.link.pad_grab = function(device, name)
        asks[#asks + 1] = { device = device, name = name }
        return kept, device, name, 0, 0
    end
    s:run(0.5)
    local pad
    for _, line in ipairs(pc.logs) do
        pad = line:match("player 2 joy(%d)") or pad
    end
    local last = asks[#asks]
    check(#asks >= 20, "asked every frame")
    check(last ~= nil and pad ~= nil and last.device == tonumber(pad), "for player 2's own pad")
    check(last ~= nil and last.name == pc.env.FName("Gamepad_Special_Right"):GetComparisonIndex(), "and its Options")
    local before = #pc.injected
    s:run(0.5)
    check(#pc.injected == before, "nothing asked for while none is kept")
    kept = kept + 1
    s:run(0.05)
    check(#pc.injected == before + 1 and pc.injected[#pc.injected] == "IA_PushGameSystemMenu", "a press kept asks for the menu")
    s:run(0.5)
    check(#pc.injected == before + 1, "once")
    pc.paused = true
    s:run(0.5)
    check(asks[#asks].device == -1, "not asked while a menu is up: pad 2's Options is the game's own there")
    kept = kept + 1
    s:run(0.2)
    pc.paused = false
    s:run(0.5)
    check(#pc.injected == before + 1, "a press kept as the menu came up opens nothing after it")
    check(asks[#asks].device == tonumber(pad), "and it's asked for again after the menu")
    pc.env.PBZ.link.pad_grab = nil
    Session.press2(s, "Gamepad_Special_Right")
    check(#pc.injected == before + 2, "an older main.dll: player 2's controller's own Options opens it as before")
    allErrors(s)
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
    Fake.put(rstate0.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })        -- (looking at it)
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
    Fake.put(lstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
    Session.press2(late, "Gamepad_FaceButton_Right")
    local rang = field(field(lpc.pawn, "interact"), "used")
    check(#rang == 0, "as a load ends nothing's started under the page that's about to go up")
    late:run(1.6)
    Session.press2(late, "Gamepad_FaceButton_Right")
    check(#rang == 1, "a moment later it is")
    allErrors(late)

    local b, bpc, bstate = localGame()
    b:run(1.5)
    Fake.put(bstate.p2Pawn, "loc", { X = 7900.0, Y = 0.0, Z = 100.0 })
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

-- A player report on 1.6.9 ("monsters deal very little damage to me ... it feels like I have absurdly high armor") and the
-- bench, 11-11: player 1's joystick read as unplugged held their health where it was, and they played on all the same (the
-- keyboard and mouse reach player 1, and a DualSense the game reads itself can be missing from pads.txt), with nothing able
-- to hurt them: 0 of 28 boss hits. A player 1 who steers isn't helpless: no hold. One standing still, their pad gone, is.
local function padHold()
    part("a joystick away: the hold on player 1's health")
    local function floorOf(p)
        return field(field(field(p, "AttributeSetBase"), "Health_Min"), "CurrentValue")
    end
    local function hit(p, amount)       -- (as the game takes a hit: never under the floor)
        Fake.setHealth(p, math.max(floorOf(p), (Fake.health(p)) - amount))
    end
    local function steer(p, on)
        Fake.put(field(p, "CharacterMovement"), "Acceleration", { X = on and 2048.0 or 0.0, Y = 0.0, Z = 0.0 })
    end
    local s, pc = localGame()
    s:run(1.5)
    local p1 = pc.pawn
    local top = select(2, Fake.health(p1))
    pc.files["pads.txt"] = "0\n1\n0\n0\n"           -- (player 1's joystick gone, player 2's in)
    s:run(0.5)
    hit(p1, 300)
    check(floorOf(p1) == top and Fake.health(p1) == top, "player 1's joystick gone, standing still: held, a hit takes nothing")
    steer(p1, true)
    s:run(0.5)
    hit(p1, 300)
    check(floorOf(p1) == 0 and Fake.health(p1) == top - 300,
        "steering all the same (keyboard and mouse, or a pad the game reads itself): no hold, the hit lands")
    check(count(pc.logs, "plays on without their controller") == 1, "said once in the log")
    steer(p1, false)
    s:run(1)
    hit(p1, 100)
    check(floorOf(p1) == 0 and Fake.health(p1) == top - 400, "standing still again, that pad still away: not held again")
    pc.files["pads.txt"] = "1\n1\n0\n0\n"
    s:run(0.5)
    pc.files["pads.txt"] = "0\n1\n0\n0\n"
    s:run(0.5)
    hit(p1, 100)
    check(floorOf(p1) == top - 400 and Fake.health(p1) == top - 400, "the pad back and gone again, standing still: held again")
    allErrors(s)

    -- Alone in Local mode (player 2 out), no joystick at all, on the keyboard: the same.
    local a, apc = localGame()
    a:run(1.5)
    Session.command(apc, "localcoop off")
    a:run(1)
    local q1 = apc.pawn
    local qtop = select(2, Fake.health(q1))
    apc.files["pads.txt"] = "0\n0\n0\n0\n"
    a:run(0.5)
    check(floorOf(q1) == qtop, "alone in Local mode, no joystick, standing still: held")
    steer(q1, true)
    a:run(0.5)
    hit(q1, 250)
    check(floorOf(q1) == 0 and Fake.health(q1) == qtop - 250, "on the keyboard: no hold, the hit lands")
    allErrors(a)
end

-- A player report on 1.7.1 ("i select the option but the apply button is greyed out", the F4 panel, split layout and two
-- monitors; only the ini worked): two in split screen already, on pads this panel doesn't have as plugged in (pads.txt
-- is XInput's list, and theirs were pads the game reads itself). Apply waited for those pads, with no word why.
local function panelApply()
    part("the F4 panel: Apply with the devices as they are")
    local function cfg(pc, key)
        return (pc.files["localcoop.txt"] or ""):match(key .. "=(%w+)")
    end
    local s, pc = localGame()
    s:run(1.5)
    pc.files["pads.txt"] = "0\n0\n0\n0\n"           -- (no pad XInput shows: player 2's card isn't "plugged in")
    Session.command(pc, "panel toggle")
    s:run(0.5)
    local was = cfg(pc, "layout")
    Session.command(pc, "panel press 650 140")      -- (SCREEN: side by side)
    Session.command(pc, "panel press 760 510")      -- APPLY
    s:run(0.5)
    check(was ~= "lr" and cfg(pc, "layout") == "lr" and cfg(pc, "players") == "2" and cfg(pc, "p2") ~= "kbm",
        string.format("a change of layout alone is applied, whatever the pads read (%s -> %s, players on %s and %s)",
            tostring(was), tostring(cfg(pc, "layout")), tostring(cfg(pc, "p1")), tostring(cfg(pc, "p2"))))
    check(count(pc.logs, "Status: APPLY waits") == 0, "and no tip")
    allErrors(s)

    -- One player, a second asked for whose pad isn't there: grey as before, and a click says what it waits for.
    local a, apc = localGame()
    a:run(1.5)
    apc.files["pads.txt"] = "1\n0\n0\n0\n"          -- (player 1's pad in, player 2's not one XInput shows)
    Session.command(apc, "panel toggle")
    a:run(0.5)
    Session.command(apc, "panel press 70 140")      -- (PLAYERS: 1)
    Session.command(apc, "panel press 760 510")
    a:run(1)
    check(cfg(apc, "players") == "1", "down to one player: applied (player 1's pad is there)")
    Session.command(apc, "panel press 150 140")     -- (PLAYERS: 2, player 2's pad still not one XInput shows)
    Session.command(apc, "panel press 760 510")
    a:run(0.5)
    check(cfg(apc, "players") == "1"
        and count(apc.logs, "Status: APPLY waits for player 2's controller: it isn't connected") == 1,
        "a second player whose pad isn't there: grey as before, and the click says what Apply waits for")
    local lang = apc.env.PBZ.lang
    if lang then
        lang.set("Chinese")
        check(lang.say("APPLY waits for player 2's controller: it isn't connected, or isn't one Windows sees as an Xbox pad. "
            .. "A PlayStation pad needs DS4Windows: the local co-op guide has the steps."):find("DS4Windows,步骤见本地分屏指南", 1, true) ~= nil
            and lang.say("APPLY waits for player 1: drag the keyboard or a controller onto their slot."):find("玩家 1", 1, true) ~= nil
            and lang.say("APPLY waits for player 2: drag a controller onto their slot."):find("把手柄拖到", 1, true) ~= nil,
            "in Chinese too (player 2's line names a controller alone: the keyboard is player 1's)")
        lang.set("English")
    end
    apc.files["pads.txt"] = "1\n1\n0\n0\n"          -- (the pad plugged in)
    a:run(1)
    Session.command(apc, "panel press 760 510")
    a:run(1)
    check(cfg(apc, "players") == "2", "the pad plugged in: applied")
    -- Player 2's card off their slot (the fake has no mouse: the panel's own choice, by its upvalue). Their line names
    -- a controller alone: the keyboard is player 1's. (The check before this one said the line through lang.lua and
    -- never asked the panel for it: the sixth review's V11.)
    local function upvalue(fn, wanted)
        for i = 1, type(fn) == "function" and 255 or 0 do
            local n, v = debug.getupvalue(fn, i)
            if n == nil or n == wanted then
                return v
            end
        end
    end
    local choice = upvalue(((upvalue(apc.env.PBZ.arena.blocker, "api") or {}).panel or {}).command, "choice")
    if choice then
        choice.p2 = nil
    end
    Session.command(apc, "panel press 760 510")
    a:run(0.5)
    check(choice ~= nil and count(apc.logs, "Status: APPLY waits for player 2: drag a controller onto their slot%.") == 1,
        "player 2's card off their slot: the click names a controller alone")
    allErrors(a)
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

    -- The ini as it ships (the user's calls, 11-10, after the bench): bosses on the enemies' health, 150% with a partner,
    -- 200% with two, 250% with three; their guard bar twice, three and four times, so it breaks about as often as alone;
    -- super armour on. Its own lines, read through the mod's own ini path.
    local shipped = Session.shippedIni()
    local function active(key)
        return shipped:match("\n" .. key .. " = ([^\r\n]+)")
    end
    check(active("CoopBossHealth") == nil and active("CoopBossPosture") == "200" and active("CoopBossArmor") == "On",
        string.format("the ini as it ships: bosses on the enemies' health, a 200%% guard bar, super armour on (%s, %s, %s)",
            tostring(active("CoopBossHealth")), tostring(active("CoopBossPosture")), tostring(active("CoopBossArmor"))))
    local shippedLines = ""
    for _, key in ipairs({ "CoopEnemyHealth", "CoopEnemyPosture", "CoopBossHealth", "CoopBossPosture", "CoopBossArmor" }) do
        if active(key) then
            shippedLines = shippedLines .. key .. " = " .. active(key) .. "\n"
        end
    end
    for _, case in ipairs({ { 2, 7500, 800, 900 }, { 3, 10000, 1200, 1200 }, { 4, 12500, 1600, 1500 } }) do
        local roles = { "Host" }
        for i = 2, case[1] do
            roles[i] = "Guest"
        end
        local b = party(nil, shippedLines, roles)
        b:run(6)
        local bossMax, bossBar = max(b.pcs[1], "boss")
        local thugMax = max(b.pcs[1], "thug1")
        check(bossMax == case[2] and math.abs(bossBar - case[3]) < 0.01 and thugMax == case[4], string.format(
            "%d players: the boss at %.0f health and a %.0f guard bar, the others at %.0f", case[1], bossMax, bossBar, thugMax))
        allErrors(b)
    end

    -- Bosses' own numbers, and how hard everything hits (a player report on 1.6.9: "options to customize the boss's damage,
    -- as well as the mobs' health, posture, and damage").
    -- (How hard it hits: the game's multiplier of the damage it deals, up, the first kind's; scaling.lua's KINDS.)
    local function attack(pc, id, down)
        local set = Session.enemyOn(pc, id).AttributeSetBase
        return (down and set.DealtReductionMultiplier_Physical or set.DealtVulnerabilityMultiplier_Physical).CurrentValue
    end
    local d = party(nil, "CoopBossHealth = 300\nCoopBossPosture = 200\nCoopEnemyDamage = 150\nCoopBossDamage = 250\n")
    d:run(6)
    local bossHp, thugHp = max(d.pcs[1], "boss"), max(d.pcs[1], "thug1")
    check(bossHp == 35000 and thugHp == 1500, string.format(        -- (four connected: each adds the first's share again)
        "the boss with its own health, 300%% (700%% with four); the others the enemies' 150%% (250%%): %.0f, %.0f", bossHp, thugHp))
    check(everyone(d, function(pc) return math.abs(attack(pc, "thug1") - 1.5) < 1e-6 and math.abs(attack(pc, "boss") - 2.5) < 1e-6 end),
        string.format("enemies hit at 150%%, the boss at 250%%, on every PC: %.2f, %.2f", attack(d.pcs[1], "thug1"), attack(d.pcs[1], "boss")))
    local fire = Session.enemyOn(d.pcs[1], "thug1").AttributeSetBase
    check(fire.DealtVulnerabilityMultiplier_Fire.CurrentValue == 1.5 and fire.DealtVulnerabilityMultiplier_Elemental.CurrentValue == 1,
        "every kind of damage it deals, but not the elements' all-in-one kind (a tick counts it too)")
    d:run(6)
    check(math.abs(attack(d.pcs[1], "thug1") - 1.5) < 1e-6 and math.abs(attack(d.pcs[2], "boss") - 2.5) < 1e-6,
        "once a body, never on top of itself")
    local a = Session.enemyOn(d.pcs[1], "thug1").AttributeSetBase.DealtVulnerabilityMultiplier_Physical
    a.BaseValue, a.CurrentValue = 1, 1                      -- (back at its own number: the game set it again, or a new body)
    d:run(4)
    check(math.abs(attack(d.pcs[1], "thug1") - 1.5) < 1e-6, "a body back at its own number is scaled again: " .. attack(d.pcs[1], "thug1"))
    -- (A difficulty switch sets an enemy's numbers again, to the new mode's, the Coop session found on the bench, 11-09; and
    -- difficulty.lua raises the mode a second after a partner links. Scaled again from the game's new number, once; the other
    -- kinds, still ours, aren't touched; an effect on top, the current alone, isn't scaled again.)
    a.BaseValue, a.CurrentValue = 1.2, 1.2
    d:run(4)
    local thugSet = Session.enemyOn(d.pcs[1], "thug1").AttributeSetBase
    check(math.abs(attack(d.pcs[1], "thug1") - 1.8) < 1e-6 and math.abs(thugSet.DealtVulnerabilityMultiplier_Fire.BaseValue - 1.5) < 1e-6,
        string.format("set again by the game to 1.2 (a difficulty switch): 1.8 from it, the others still 1.5: %.2f, %.2f",
            attack(d.pcs[1], "thug1"), thugSet.DealtVulnerabilityMultiplier_Fire.BaseValue))
    d:run(4)
    check(math.abs(a.BaseValue - 1.8) < 1e-6, "and not again on top of itself: " .. a.BaseValue)
    a.CurrentValue = 3.0
    d:run(4)
    check(math.abs(a.BaseValue - 1.8) < 1e-6 and a.CurrentValue == 3.0, "an effect on top (the current alone) isn't scaled again")
    check(count(d.pcs[1].logs, "hitting at 150%%, bosses at 250%%") >= 1, "and the log says so")
    allErrors(d)
    -- (Six players, ghost twins: a twin hits as hard as its original, a boss's as a boss. twins.lua gives a twin its
    -- original's health and posture only, and every twin hit at the game's own; the review of 11-09.)
    local SIX = { "Host", "Guest", "Guest", "Guest", "Guest", "Guest" }
    local six = Session.new(SIM_SCRIPTS, SIX, 6, ENEMIES, "CoopEnemyDamage = 200\nCoopBossDamage = 300\n")
    for i = 2, 6 do
        Session.moveTo(six.pcs[i], 200 * i, 0)
    end
    six:run(25)
    local twinsSeen, twinsRight = 0, 0
    for _, pc in ipairs({ six.pcs[1], six.pcs[3] }) do
        for _, e in ipairs(pc.enemies) do
            local tid = e:IsValid() and pc.env.PBZ.game.twinId(e:GetAddress())
            if tid then
                twinsSeen = twinsSeen + 1
                local want = tid:find(":sp:boss", 1, true) and 3 or 2
                if math.abs(e.AttributeSetBase.DealtVulnerabilityMultiplier_Physical.CurrentValue - want) < 1e-6 then
                    twinsRight = twinsRight + 1
                end
            end
        end
    end
    check(twinsSeen > 0 and twinsRight == twinsSeen, string.format(
        "ghost twins hit as their originals, a boss's twin as a boss, on host and guest: %d of %d", twinsRight, twinsSeen))
    allErrors(six)
    local soft = party(nil, "CoopEnemyDamage = 50\n")
    soft:run(6)
    check(attack(soft.pcs[1], "thug1", true) == 0.5 and attack(soft.pcs[1], "thug1") == 1 and attack(soft.pcs[1], "boss", true) == 0.5,
        "CoopEnemyDamage = 50: half, by the multiplier down; bosses left out take the enemies' number")
    allErrors(soft)
    -- The hitscale command across 100 and back, on the same bodies: each time the new number from the game's own, the one
    -- before taken back first. (A body's first number kept, a mix came: x1.5 up, x0.5 down; the review of 11-09.)
    local f = party(nil, "CoopEnemyDamage = 150\n")
    f:run(6)
    local function flip(n)
        for _, pc in ipairs(f.pcs) do
            Session.command(pc, "hitscale " .. n)
        end
        f:run(5)
        return attack(f.pcs[1], "thug1") * attack(f.pcs[1], "thug1", true), attack(f.pcs[2], "thug1") * attack(f.pcs[2], "thug1", true)
    end
    local h1, g1 = flip(50)
    local h2, g2 = flip(150)
    local h3, g3 = flip(50)
    check(math.abs(h1 - 0.5) + math.abs(g1 - 0.5) + math.abs(h2 - 1.5) + math.abs(g2 - 1.5) + math.abs(h3 - 0.5) + math.abs(g3 - 0.5) < 1e-6,
        string.format("hitscale across 100 and back, the same bodies: x%.2f, x%.2f, x%.2f", h1, h2, h3))
    -- (Back at 100, the game's own, as the ini back at 100 does when co-op starts again from the panel: every body around
    -- kept the number before, none looked at; the review of 11-10.)
    local h4, g4 = flip(100)
    check(math.abs(h4 - 1) + math.abs(g4 - 1) < 1e-6, string.format("and hitscale 100: the game's own, on host and guest: x%.2f, x%.2f", h4, g4))
    allErrors(f)
    -- A boss to the mod only while its bar is up (the codex doesn't call it one): in its fight a boss's health and hits; after
    -- it, its health kept (never cut while it's hurt), its hits an enemy's again. (Scaled as an enemy first, it kept that
    -- health in its fight: the review of 11-09.)
    local m = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "masked", "BP_Monster_Masked_C", 900.0, 0.0, 100.0, 3000, 300 } },
        "CoopEnemyHealth = 150\nCoopBossHealth = 300\nCoopEnemyDamage = 100\nCoopBossDamage = 200\n")
    m:run(4)
    Session.moveTo(m.pcs[1], 0, 0)
    Session.moveTo(m.pcs[2], 300, 0)
    m:run(10)
    local asEnemy = max(m.pcs[1], "masked")
    m.pcs[1].hudLayout:RegisterBossHPBar(Session.enemyOn(m.pcs[1], "masked"))
    m:run(6)
    local inFight, hitsIn = max(m.pcs[1], "masked"), attack(m.pcs[1], "masked")
    m.pcs[1].hudLayout:UnRegisterBossHPBar(Session.enemyOn(m.pcs[1], "masked"))
    m:run(6)
    local after, hitsAfter = max(m.pcs[1], "masked"), attack(m.pcs[1], "masked")
    check(asEnemy == 4500 and inFight == 9000 and math.abs(hitsIn - 2) < 1e-6 and after == 9000 and math.abs(hitsAfter - 1) < 1e-6,
        string.format("a boss known by its bar alone: %.0f health before, %.0f in its fight hitting x%.2f, %.0f after hitting x%.2f",
            asEnemy, inFight, hitsIn, after, hitsAfter))
    allErrors(m)
    -- The same in a party: a fight on it lost (the host showed it, a guest's: the body stands, a boss's numbers on it), a
    -- fourth player joins, its next fight. A boss's own for four, 21000 and 1200: risen by the enemies' and promoted again,
    -- it had 52500 and 2250 (the review of 11-10).
    local j = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, { { "masked", "BP_Monster_Masked_C", 900.0, 0.0, 100.0, 3000, 300 } },
        "CoopEnemyHealth = 150\nCoopEnemyPosture = 130\nCoopBossHealth = 300\nCoopBossPosture = 200\n")
    j.pcs[4].joinAt = j.pcs[1].now + 40
    j:run(4)
    for i, pc in ipairs(j.pcs) do
        Session.moveTo(pc, 300 * (i - 1), 0)
    end
    j:run(10)
    local function masked()
        return Session.enemyOn(j.pcs[1], "masked")
    end
    j.pcs[1].hudLayout:RegisterBossHPBar(masked())
    j:run(6)
    local three = max(j.pcs[1], "masked")
    j.pcs[1].hudLayout:UnRegisterBossHPBar(masked())
    j:run(math.max(0, j.pcs[4].joinAt - j.pcs[1].now) + 14)
    j.pcs[1].hudLayout:RegisterBossHPBar(masked())
    j:run(6)
    local four, fourP = max(j.pcs[1], "masked")
    check(three == 15000 and four == 21000 and fourP == 1200, string.format(
        "in a party, a fight on it lost and a fourth player joined: its next fight at a boss's own for four, %.0f then %.0f / %.0f",
        three, four, fourP))
    allErrors(j)
    local o = party(nil, "")
    o:run(6)
    check(everyone(o, function(pc) return attack(pc, "thug1") == 1 and attack(pc, "boss") == 1 and attack(pc, "boss", true) == 1 end)
        and select(1, max(o.pcs[1], "boss")) == 12500, "left out: everything hits as the game has it, and bosses take the enemies' 150% (250% with four)")
    allErrors(o)
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
    -- (Out of any fight, none of the host's enemies near: a story's own QTE, waiting on the player. It's given a minute.)
    local c, ch, cg = pair()
    Session.moveTo(ch, 60000, 60000)
    Session.moveTo(cg, 60300, 60000)
    c:run(3)
    local cq = grab(cg)
    c:run(40)
    check(cq.active and cq.finished == 0, "a QTE with no fight on and no enemy near isn't ended at 12 s, nor at 30")
    c:run(25)
    check(not cq.active and cq.finished == 1, "but at a minute")
    allErrors(c)
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
    -- (One turned away for its protocol isn't in the game: told they can't connect, not that they're in and out of step.)
    s.relay.otherVersions = "3:other-protocol"
    s:run(2)
    check(count(h.logs, "your partner's Phantom Pact %(other%-protocol%) can't connect to ") == 1
        and count(h.logs, "is on Phantom Pact other%-protocol") == 0, "a friend on another protocol at the door: "
        .. "told they can't connect, not that they're in the game and out of step")
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

-- An enemy's line that says something new and then stands (it stopped, or was hit as it stood): sent once, a loss left the
-- other side wrong until the line every quarter second. It goes again the turn after, and once more two turns on.
local function enemyLinesAgain()
    part("an enemy's line, after it said something new")
    local s, h = pair()
    s:run(2)
    local near = Session.enemyOn(h, "near")
    -- The lines of the one that stands at this health, sent since n.
    local function lines(n, health)
        local c, last = 0, nil
        for k = n + 1, #h.sent do
            if h.sent[k]:find("^N %d+ %S+ %S+ %S+ %S+ %S+ %S+ " .. health .. "%.0 ") then
                c, last = c + 1, h.sent[k]
            end
        end
        return c, last
    end
    local n = #h.sent
    Fake.setHealth(near, 555)
    s:run(0.2)
    local soon = lines(n, 555)
    check(soon == 3, "a hit on an enemy that stands: its new health goes three times in the first fifth of a second, should one be lost (" .. soon .. ")")
    s:run(1.0)
    local later = lines(n, 555) - soon
    check(later >= 3 and later <= 5, "and from then on every quarter second, as before (" .. later .. " in the next second)")
    -- One that moves says something new every turn: each of its lines goes once.
    n = #h.sent
    local t, seen, twice, moving = 0, {}, 0, 0
    s:run(1.0, function()
        t = t + 1 / 60
        Fake.put(near, "loc", { X = 300.0 + t * 400, Y = 300.0, Z = 100.0 })
    end)
    for k = n + 1, #h.sent do
        local x = h.sent[k]:match("^N %d+ (%S+) %S+ %S+ %S+ %S+ %S+ 555%.0 ")
        if x then
            moving = moving + 1
            twice = twice + (seen[x] and 1 or 0)
            seen[x] = true
        end
    end
    check(moving >= 20 and twice == 0, "an enemy that moves says something new each turn, and each line goes once (" .. moving .. " lines, " .. twice .. " twice)")
    -- It stops: where it stopped goes three times, then every quarter second.
    n = #h.sent
    s:run(0.2)
    local _, stopped = lines(n, 555)
    local same = 0
    for k = n + 1, #h.sent do
        same = same + (h.sent[k] == stopped and 1 or 0)
    end
    check(same == 3, "and where it stopped goes three times in a fifth of a second (" .. same .. ")")
    n = #h.sent
    s:run(4)
    local standing = lines(n, 555)
    check(standing >= 12 and standing <= 17, "standing, it's back to a line every quarter second or so (" .. standing .. " in 4 s)")
    allErrors(s)
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
    -- A boss's twin takes a guest's flinches as a boss does: none in a move of its own (every one was forced on it, the
    -- same stun-lock as the boss's own before 1.7.0).
    local bossTwinId
    for tid, e in pairs(ht) do
        if e == bossTwin then
            bossTwinId = tid
        end
    end
    local tg = s.pcs[2]
    local twinCopy = twinsOn(tg)[bossTwinId]
    Fake.put(rawget(bossTwin, "__fields").anim, "montage", h.env.StaticFindObject("/PBZCombatAsset/ActorData/Move/E1.E1"))
    s:run(0.5)
    Fake.put(rawget(twinCopy, "__fields").anim, "montage", tg.env.StaticFindObject("/PBZCombatAsset/ActorData/Move/Hit1.Hit1"))
    Fake.put(field(twinCopy, "hit"), "state", "CharacterState.Hitreact.State.Normal")
    swing(tg, twinCopy, select(1, Fake.health(twinCopy)) - 50)
    s:run(0.5)
    local twinMove = field(field(bossTwin, "anim"), "montage")
    check(twinMove and twinMove:GetFullName():find("E1", 1, true) ~= nil
        and field(field(bossTwin, "hit"), "state") ~= "CharacterState.Hitreact.State.Normal",
        "a guest's hit doesn't cut a boss's twin's own attack short (" .. tostring(twinMove and twinMove:GetFullName()) .. ")")
    Fake.put(rawget(bossTwin, "__fields").anim, "montage", nil)
    Fake.put(field(twinCopy, "hit"), "state", "None")

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

-- art/arabic.tsv, where the Arabic comes from (tools/make_lang_ar.py): id -> { en = its English, ar = its Arabic }, and
-- the ids in the file's order. (unchecked: its notes begin UNCHECKED, the author's check still to come.)
local function arabicRows()
    local T, ids = {}, {}
    local f = io.open(SIM_REPO .. "/art/arabic.tsv", "rb")
    if f then
        local first = true
        for line in (f:read("a") .. "\n"):gmatch("([^\n]*)\n") do
            local id, en, ar, notes = line:gsub("\r$", ""):match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)")
            if first then
                first = false
            elseif id and id ~= "" then
                T[id] = { en = en, ar = ar, unchecked = (notes or ""):find("^UNCHECKED") ~= nil, notes = notes or "" }
                ids[#ids + 1] = id
            end
        end
        f:close()
    end
    return T, ids
end

-- Every string in a script as Lua reads it (its escapes, \\ and \" and the rest, read by Lua itself), strings joined by ..
-- taken as one, across line breaks and comments: the whole lines the code can hand say(). Added to runs.
local function literalRuns(src, runs)
    local i, run, joined = 1, nil, false        -- the run so far, and whether a .. came after its last string
    local function finish()
        if run then
            runs[#runs + 1] = table.concat(run)
        end
        run, joined = nil, false
    end
    local function add(literal)
        local ok, value = pcall(function() return load("return " .. literal, "=literal", "t", {})() end)
        if not ok or type(value) ~= "string" then
            finish()
            return
        end
        if run and joined then
            run[#run + 1] = value
        else
            finish()
            run = { value }
        end
        joined = false
    end
    while true do
        local j = src:find("[\"'%-%[%.]", i)    -- the next quote, comment, long bracket or dot
        if not j then
            finish()
            return
        end
        if src:sub(i, j - 1):find("%S") then    -- (anything else between ends a run)
            finish()
        end
        local c = src:sub(j, j)
        if c == "-" and src:sub(j + 1, j + 1) == "-" then
            local eq = src:match("^%[(=*)%[", j + 2)
            local stop = eq and select(2, src:find("]" .. eq .. "]", j + 4 + #eq, true)) or src:find("\n", j, true)
            i = (stop or #src) + 1
        elseif c == "." and src:sub(j, j + 2) ~= "..." and src:sub(j, j + 1) == ".." then
            if run and not joined then
                joined = true
            else
                finish()
            end
            i = j + 2
        elseif c == "[" and src:match("^%[=*%[", j) then
            local eq = src:match("^%[(=*)%[", j)
            local stop = select(2, src:find("]" .. eq .. "]", j + 2 + #eq, true)) or #src
            add(src:sub(j, stop))
            i = stop + 1
        elseif c == '"' or c == "'" then
            local k, stop = j + 1, nil
            while true do
                local m = src:find("[\\" .. c .. "\n]", k)
                if not m or src:sub(m, m) == "\n" then
                    break
                elseif src:sub(m, m) == "\\" then
                    k = m + (src:sub(m + 1, m + 2) == "\r\n" and 3 or 2)    -- (what's escaped is never the end)
                else
                    stop = m
                    break
                end
            end
            if stop then
                add(src:sub(j, stop))
                i = stop + 1
            else
                finish()
                i = j + 1
            end
        else
            finish()
            i = j + (src:sub(j, j + 2) == "..." and 3 or 1)
        end
    end
end

-- Arabic: lang_ar.lua, made by tools/make_lang_ar.py from art/arabic.tsv. Each row of the tsv that goes through say(),
-- made the way the code makes it, comes out as the tsv's Arabic, its names in Arabic too, and so do the lines the code
-- builds of pieces. English and Chinese stay as they were, and no Arabic line keeps English the tsv has Arabic for.
local function arabic()
    part("Arabic")
    local T, ids = arabicRows()
    check(#ids > 0, string.format("art/arabic.tsv: %d rows", #ids))
    if #ids == 0 then
        return
    end
    local function language(word, withArabic)
        local l = dofile(SIM_SCRIPTS .. "/lang.lua")(withArabic and (SIM_SCRIPTS .. "/") or nil)
        l.set(word)
        return l
    end
    local ar, en, zh, zhAlone = language("Arabic", true), language("English", true), language("Chinese", true),
        language("Chinese", false)
    local ok, t = pcall(dofile, SIM_SCRIPTS .. "/lang_ar.lua")
    local lines, pieces = 0, 0
    if ok and type(t) == "table" and type(t.LINES) == "table" and type(t.PARTS) == "table" then
        for _ in pairs(t.LINES) do
            lines = lines + 1
        end
        pieces = #t.PARTS
    end
    -- (Old scripts have no Arabic: their lang.lua has no arabic() to call.)
    check(lines > 0 and pieces > 0 and ar.arabic ~= nil and ar.arabic() and ar.prefix() == "ar_" and ar.word() == "Arabic",
        string.format("lang_ar.lua loads (%d lines, %d pieces), and Arabic is picked", lines, pieces))

    -- A row's English with its %s and %d as the values given, and its Arabic with its %1, %2... as theirs.
    local function made(id, ...)
        local v, k = { ... }, 0
        return (T[id].en:gsub("%%[sd]", function()
            k = k + 1
            return v[k]
        end))
    end
    local function fill(id, ...)
        local v = { ... }
        return (T[id].ar:gsub("%%(%d)", function(k)
            return v[tonumber(k)]
        end))
    end
    local function name(id)
        return { T[id].en, T[id].ar }
    end
    local function pad(n)
        return { (T["local.word.pad"].en:gsub("%%d", n)), (T["local.word.pad"].ar:gsub("%%d", n)) }
    end

    local said, english, bad = {}, {}, {}
    -- strip: what the line was given that isn't the tsv's (Steam's own words, a map's name), for the look for English.
    local function note(id, line, got, want, strip)
        said[#said + 1] = { id = id, got = got, strip = strip }
        english[#english + 1] = line
        if got ~= want then
            bad[#bad + 1] = id .. ": " .. line .. " -> " .. got .. "  (the tsv: " .. want .. ")"
        end
    end
    local function try(id, line, want, strip)
        note(id, line, ar.say(line), want, strip)
    end
    local function verdict(what)
        check(#bad == 0, what)
        for i = 1, math.min(#bad, 10) do
            out("       " .. bad[i])
        end
        bad = {}
    end

    -- Each of lang_ar.lua's whole lines is one the code says, word for word. say() looks a line up whole, and the checks
    -- below give it the tsv's own English: a tsv that drifted from the code (a curly apostrophe, a full stop, a tip
    -- reworded in the code) left that line English on screen and passed them all. A line is a string in the scripts,
    -- strings joined by .. as one; the few the code builds around a name or a number need each of their pieces. (coop.lua
    -- says who .. " rested at a bell: ...", who "your partner" with two players; status.lua puts the ping, and whether it's
    -- signed, between "partner connected" and its full stop.)
    local BUILT = {
        ["your partner rested at a bell: you'll join them."] = { "your partner", " rested at a bell: you'll join them." },
        ["your partner rested at a bell: you're rested, and so is the boss."] =
            { "your partner", " rested at a bell: you're rested, and so is the boss." },
        ["your partner turned co-op sync off."] = { "your partner", " turned co-op sync off." },
        ["partner connected."] = { "partner connected", "." },
        ["partner connected, signed."] = { "partner connected", ", signed", "." },
    }
    local runs, scripts = {}, 0
    local listing = io.popen('dir /b "' .. SIM_SCRIPTS:gsub("/", "\\") .. '\\*.lua"')
    for name in (listing and listing:lines() or function() end) do
        local file = name ~= "lang.lua" and name ~= "lang_ar.lua" and io.open(SIM_SCRIPTS .. "/" .. name, "rb")
        if file then
            literalRuns(file:read("a"), runs)
            file:close()
            scripts = scripts + 1
        end
    end
    if listing then
        listing:close()
    end
    local inCode = {}
    for _, r in ipairs(runs) do
        inCode[r] = true
    end
    local keys, built = {}, 0
    for k in pairs(ok and type(t) == "table" and type(t.LINES) == "table" and t.LINES or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local pieces = not inCode[k] and BUILT[k]
        if pieces then
            built = built + 1
            if table.concat(pieces) ~= k then
                bad[#bad + 1] = "(the list above doesn't make it) " .. k
            end
            for _, piece in ipairs(pieces) do
                if not inCode[piece] then
                    bad[#bad + 1] = "not in the scripts: \"" .. piece .. "\", a piece of " .. k
                end
            end
        elseif not inCode[k] then
            bad[#bad + 1] = "not in the scripts: " .. k
        end
    end
    if #keys == 0 then
        bad[#bad + 1] = "lang_ar.lua has no lines"
    end
    verdict(string.format("each of lang_ar.lua's %d lines is one the code says, word for word (%d strings in %d scripts; "
        .. "%d built of pieces)", #keys, #runs, scripts, built))

    -- Every row, its %s and %d given values by place (none of them a word), or names: P a player, B a boss, A an
    -- arena, the two devices of local co-op. Not through say(): the pictures' words (art/make_arabic_art.py), the brush
    -- characters drawn in every language, and ALIVE and VICTORY, put straight on the game's own death screen.
    local S, D = { "1.6.9", "1.7.2", "2.0.1" }, { "3", "4", "5" }
    local P, B, A = name("term.player3"), name("term.boss.goldmask"), name("term.arena.huaqianxiao")
    local KEYBOARD = name("local.word.keyboard")
    local NAMES = { ["f5.words.youre"] = { P }, ["tip.conn.party_joined"] = { P }, ["tip.conn.party_left"] = { P },
        ["f6.words.needs_version"] = { P }, ["f6.words.other_version"] = { P }, ["f6.words.waiting_ready"] = { P },
        ["f6.words.not_beaten"] = { P, B }, ["f6.words.other_map"] = { P }, ["tip.pvp.needs_beaten"] = { B },
        ["tip.pvp.back.name_lost"] = { P }, ["tip.pvp.back.name_left"] = { P }, ["tip.pvp.back.name_couldnt"] = { P },
        ["tip.pvp.back.your_world"] = { B }, ["tip.pvp.back.their_world"] = { P }, ["tip.pvp.start.to"] = { A },
        ["local.tip.checklist"] = { KEYBOARD, pad("2") } }
    local NOT_SAID = { ["match.count.numbers"] = true, ["match.count.fight_glyph"] = true, ["match.timeup_glyph"] = true,
        ["match.alive_glyphs"] = true, ["match.alive"] = true, ["match.victory"] = true }
    local HEADS = { "f5.words.couldnt_start", "tip.conn.couldnt_start" }
    local function sample(id)
        local names, e, a, k, s = NAMES[id] or (id:find("^tip%.party%.") and { P }) or {}, {}, {}, 0, 0
        for c in T[id].en:gmatch("%%([sd])") do
            k = k + 1
            if c == "s" then
                s = s + 1
                e[k], a[k] = names[s] and names[s][1] or S[k], names[s] and names[s][2] or S[k]
            else
                e[k], a[k] = D[k], D[k]
            end
        end
        return made(id, table.unpack(e, 1, k)), fill(id, table.unpack(a, 1, k))
    end
    local rows, errors, tips, waiting = 0, {}, {}, {}
    for _, id in ipairs(ids) do
        local r = T[id]
        if r.unchecked then                             -- not shipped till the author has checked it (below)
            waiting[#waiting + 1] = id
        elseif id:find("^tip%.relayerr%.") then         -- the relay's own words: only ever after a head (below)
            errors[#errors + 1] = id
        elseif not (id:find("%.art%.") or id:find("^match%.banner%.") or id == "match.mate" or id:find("^weapon%.")
            or NOT_SAID[id]) then
            rows = rows + 1
            if id == "match.foe.name" then              -- arenaui.lua: say("PLAYER ") .. slot
                note(id, "PLAYER ", ar.say("PLAYER ") .. "3", (r.ar:gsub("%%d", "3")))
            elseif id == "match.foe.score" then         -- arenaui.lua: say("YOU") in the score's own words
                note(id, "YOU", string.format("  ·  %s %d – %d", ar.say("YOU"), 2, 1), string.format(r.ar, 2, 1))
            elseif id == "term.arena.here" or id == "tip.pvp.start.to" then
                -- (To %s. only ever after a team's piece, as arena.lua says it: the whole start tip.)
                local here = id == "term.arena.here"
                local line = "Duel, best of three, no timer. Crimson team. To " .. (here and r.en or A[1]) .. "."
                local want = T["tip.pvp.start.duel"].ar .. T["tip.pvp.start.no_timer"].ar .. T["tip.pvp.start.crimson"].ar
                    .. fill("tip.pvp.start.to", here and r.ar or A[2])
                try(id, line, want)
                tips[#tips + 1] = { id, line, want }
            elseif id == "local.word.pad" or id == "local.word.keyboard" then
                -- (Only ever in the checklist, below. Anywhere else, as in a Steam friend's name, it stays as it is.)
                local friend = (r.en:gsub("%%d", "2")) .. " warrior"
                try(id, "Looking for " .. friend .. "...", fill("f5.words.looking_for", friend), { friend })
            elseif id:find("^term%.") then
                try(id, r.en, r.ar)
            else
                local line, want = sample(id)
                try(id, line, want)
                if (id:find("tip%.") == 1 or id:find("%.tip%.")) and id ~= "tip.prefix" then
                    tips[#tips + 1] = { id, line, want }
                end
            end
        end
    end
    verdict(string.format("each of the tsv's %d rows said on its own, made as the code makes it: the tsv's Arabic", rows))
    -- A row the author hasn't checked yet (its notes begin UNCHECKED) isn't shipped: lang_ar.lua has none of it, and
    -- its line stays English till then. (The author's rule; the sixth review's G2.)
    -- (A picture's row: the picture its notes name isn't in the mod's art folder.)
    local shipped = {}
    for _, id in ipairs(waiting) do
        if id:find("%.art%.") then
            local picture = T[id].notes:match("art/(%w+/[%w_]+%.png)")
            local f = picture and io.open(SIM_REPO .. "/mod/PBZCoop/art/" .. picture, "rb")
            if f then
                f:close()
            end
            if f or not picture then
                shipped[#shipped + 1] = id .. (picture and "" or " (its notes name no picture)")
            end
        elseif ar.say(T[id].en) ~= T[id].en then
            shipped[#shipped + 1] = id
        end
    end
    check(#shipped == 0, string.format("a row the author hasn't checked yet isn't in lang_ar.lua, its line English till then "
        .. "(%d waiting%s)", #waiting, #shipped > 0 and (", SHIPPED: " .. table.concat(shipped, ", ")) or ""))

    -- The panel's line (onlinepanel.lua), piece by piece: two players, then more, each player saying who they are.
    local n = #said
    local function panelLine(peer, ping, route, here, of, me)
        local line, want = "Connected to " .. peer .. ".", fill("f5.words.connected", peer)
        if ping then
            line, want = line .. " Ping " .. ping .. " ms.", want .. fill("f5.words.ping", ping)
        end
        if route then
            line, want = line .. " Route: " .. route .. ".", want .. T["f5.words.route_" .. route].ar
        end
        if here then
            line, want = line .. " Players: " .. here .. " of " .. of .. ".", want .. fill("f5.words.players", here, of)
            if me then
                line, want = line .. " You're " .. me[1] .. ".", want .. fill("f5.words.youre", me[2])
            end
        end
        try("f5.words", line, want)
    end
    for _, peer in ipairs({ "100.64.0.7", "76561198000000042" }) do
        for _, ping in ipairs({ false, "9", "180" }) do
            for _, route in ipairs({ false, "direct", "relay" }) do
                panelLine(peer, ping, route)
                panelLine(peer, ping, route, "2", "4")
                for slot = 1, 6 do
                    panelLine(peer, ping, route, tostring(slot), "6", name("term.player" .. slot))
                end
            end
        end
    end
    verdict(string.format("the panel's line, piece by piece, as each of six players: %d lines", #said - n))

    -- The relay's errors after either head (the panel's Couldn't start: and a tip's co-op couldn't start:), and one the tsv
    -- hasn't: it stays as it is.
    n = #said
    for _, id in ipairs(errors) do
        local line, want = sample(id)
        for _, head in ipairs(HEADS) do
            try(id, made(head, line), fill(head, want))
        end
    end
    for _, head in ipairs(HEADS) do
        try(head, made(head, "something else went wrong"), fill(head, "something else went wrong"),
            { "something else went wrong" })
    end
    verdict(string.format("the relay's %d errors after the panel's head and a tip's: %d lines", #errors, #said - n))

    -- What's said of each of the six by name, in status.lua, partner.lua, coop.lua and PvP's words.
    n = #said
    for slot = 1, 6 do
        local p = name("term.player" .. slot)
        for _, id in ipairs({ "tip.party.down", "tip.party.back", "tip.party.cutscene", "tip.party.other_map",
            "tip.party.rest_join", "tip.party.rest_boss", "tip.party.sync_off" }) do
            try(id, made(id, p[1]), fill(id, p[2]))
        end
        try("tip.party.far", made("tip.party.far", p[1], 212), fill("tip.party.far", p[2], 212))
        for players = 2, 6 do
            try("tip.conn.party_joined", made("tip.conn.party_joined", p[1], players), fill("tip.conn.party_joined", p[2], players))
            try("tip.conn.party_left", made("tip.conn.party_left", p[1], players - 1), fill("tip.conn.party_left", p[2], players - 1))
        end
        for _, id in ipairs({ "f6.words.needs_version", "f6.words.waiting_ready" }) do
            try(id, made(id, p[1], "1.7.2"), fill(id, p[2], "1.7.2"))
        end
        try("f6.words.other_version", made("f6.words.other_version", p[1], "1.6.9", "1.7.2"),
            fill("f6.words.other_version", p[2], "1.6.9", "1.7.2"))
        for _, boss in ipairs({ "term.boss.yucong", "term.boss.huaqianxiao", "term.boss.goldmask", "term.boss.muxiaokui" }) do
            local b = name(boss)
            try("f6.words.not_beaten", made("f6.words.not_beaten", p[1], b[1]), fill("f6.words.not_beaten", p[2], b[2]))
        end
        try("f6.words.other_map", made("f6.words.other_map", p[1], "PBZ_Xigu_WP"), fill("f6.words.other_map", p[2], "PBZ_Xigu_WP"),
            { "PBZ_Xigu_WP" })
    end
    verdict(string.format("each of six players by name: %d lines", #said - n))

    -- The PvP start tip (arena.lua): every mode, clock, team and arena.
    n = #said
    for _, mode in ipairs({ { "Duel, best of three", "tip.pvp.start.duel" }, { "Death, one life", "tip.pvp.start.death" } }) do
        for _, timer in ipairs({ 0, 60, 90, 120 }) do
            for _, team in ipairs({ { "Crimson", "tip.pvp.start.crimson" }, { "Azure", "tip.pvp.start.azure" } }) do
                for _, place in ipairs({ "term.arena.yucong", "term.arena.huaqianxiao", "term.arena.goldmask",
                    "term.arena.muxiaokui", "term.arena.here" }) do
                    local a = name(place)
                    try("tip.pvp.start", string.format("%s, %s. %s team. To %s.", mode[1],
                        timer > 0 and (timer .. " s a round") or "no timer", team[1], a[1]),
                        T[mode[2]].ar .. (timer > 0 and fill("tip.pvp.start.timer", timer) or T["tip.pvp.start.no_timer"].ar)
                        .. T[team[2]].ar .. fill("tip.pvp.start.to", a[2]))
                end
            end
        end
    end
    -- (Its To %s. only after a team: a friend's name ending "To <something>." elsewhere stays as it is.)
    try("tip.pvp.start.to", "Looking for Mr To Be...", fill("f5.words.looking_for", "Mr To Be"), { "Mr To Be" })
    verdict(string.format("the PvP start tip, every mode, clock, team and arena: %d lines", #said - n))

    -- Back from a match (arena.lua: "back from the match: " .. why .. "."), every why there is.
    n = #said
    local function back(why, id, ...)
        try(id, "back from the match: " .. why .. ".", fill(id, ...))
    end
    for _, why in ipairs({ { "the match is over", "over" }, { "you left", "you_left" }, { "you died", "you_died" },
        { "a player was lost", "player_lost" }, { "the host was lost", "host_lost" }, { "co-op was turned off", "coop_off" },
        { "the trip to the arena took too long", "trip_long" }, { "you couldn't get to the arena", "you_couldnt" },
        { "not everyone got to the arena in time", "late" } }) do
        back(why[1], "tip.pvp.back." .. why[2])
    end
    for slot = 1, 6 do
        local p = name("term.player" .. slot)
        back(p[1] .. " was lost", "tip.pvp.back.name_lost", p[2])
        back(p[1] .. " left", "tip.pvp.back.name_left", p[2])
        back(p[1] .. " couldn't get to the arena", "tip.pvp.back.name_couldnt", p[2])
        back(p[1] .. "'s world never finished that arena's boss fight", "tip.pvp.back.their_world", p[2])
    end
    for _, boss in ipairs({ "term.boss.yucong", "term.boss.huaqianxiao", "term.boss.goldmask", "term.boss.muxiaokui" }) do
        local b = name(boss)
        back("your world never finished its fight with " .. b[1] .. ": that arena is closed for you", "tip.pvp.back.your_world",
            b[2])
    end
    try("tip.pvp.back.other", "back from the match: the moon fell.", fill("tip.pvp.back.other", "the moon fell"), { "the moon fell" })
    verdict(string.format("back from a match, every why: %d lines", #said - n))

    -- The rest the code builds of pieces, or with words from elsewhere put in.
    n = #said
    for _, ping in ipairs({ false, 42 }) do
        for _, signed in ipairs({ false, true }) do
            local id = "tip.conn.connected" .. (ping and "_ping" or "") .. (signed and "_signed" or "")
            try(id, "partner connected" .. (ping and string.format(" (ping %d ms)", ping) or "") .. (signed and ", signed" or "")
                .. ".", ping and fill(id, ping) or T[id].ar)
        end
    end
    for _, teleport in ipairs({ false, true }) do
        local f3, f3ar = teleport and " F3 takes you there." or "", teleport and T["tip.partner.f3_there"].ar or ""
        try("tip.partner.other_map", "your partner is on another map." .. f3, T["tip.partner.other_map"].ar .. f3ar)
        try("tip.partner.far", string.format("your partner is %d m away.", 160) .. f3, fill("tip.partner.far", 160) .. f3ar)
    end
    for _, steam in ipairs({ true, false }) do
        try("tip.conn.high_ping", string.format("high ping (%d ms).", 320) .. (steam and ""
            or " On Tailscale, run \"tailscale ping\": via DERP means relayed."),
            fill("tip.conn.high_ping", 320) .. (steam and "" or T["tip.conn.tailscale_ping"].ar))
    end
    for _, caught in ipairs({ 1, 12 }) do
        try("tip.partner.story_caught", string.format("your story caught up with the host's: %d step%s.", caught,
            caught == 1 and "" or "s"), fill("tip.partner.story_caught", caught))
    end
    for _, one in ipairs({ KEYBOARD, pad("1"), pad("3") }) do
        for _, two in ipairs({ KEYBOARD, pad("2"), pad("4") }) do
            try("local.tip.checklist", string.format("%s is player 1, %s is player 2. F4: screen and pads. Player 2: Cross "
                .. "climbs and jumps, Circle uses, D-pad down drinks.", one[1], two[1]), fill("local.tip.checklist", one[2], two[2]))
        end
    end
    -- (The relay's own words for their version, in Arabic too: left English, they showed reversed.)
    for _, theirs in ipairs({ { "1.4.1-or-older", "term.version.older" }, { "other-protocol", "term.version.other" } }) do
        try("tip.conn.version_cant", "your partner's Phantom Pact (" .. theirs[1] .. ") can't connect to 1.7.2: both PCs need "
            .. "the same version.", fill("tip.conn.version_cant", T[theirs[2]].ar, "1.7.2"))
    end
    try("tip.conn.settings_differ", "settings differ from your partner's: coopenemyhealth, PvPvE",
        fill("tip.conn.settings_differ", "coopenemyhealth, PvPvE"), { "coopenemyhealth" })
    try("tip.conn.steam_couldnt", "Steam couldn't connect: 5003 timed out. See Connection problems in the install guide.",
        fill("tip.conn.steam_couldnt", "5003 timed out"), { "5003 timed out" })
    for _, tip in ipairs(tips) do        -- status.lua: the head said on its own, then the tip
        note(tip[1], "Phantom Pact: " .. tip[2], ar.say("Phantom Pact: ") .. ar.say(tip[2]), T["tip.prefix"].ar .. tip[3])
    end
    verdict(string.format("lines built of pieces, the tip's head before each tip: %d lines", #said - n))

    -- English and Chinese, with the Arabic loaded.
    for _, line in ipairs(english) do
        if en.say(line) ~= line then
            bad[#bad + 1] = "English: " .. line .. " -> " .. en.say(line)
        end
    end
    verdict(string.format("English stays English: %d lines", #english))
    for _, line in ipairs(english) do
        if zh.say(line) ~= zhAlone.say(line) then
            bad[#bad + 1] = "Chinese: " .. line .. " -> " .. zh.say(line)
        end
    end
    verdict(string.format("Chinese says the same with the Arabic loaded: %d lines", #english))
    check(zh.say("Not connected.") == "未连接。" and zh.say("player 3 (gold) rested at a bell: you're rested, and so is the boss.")
        == "玩家 3(金) 在钟旁休息了:你恢复了,首领也恢复了。" and zh.say("Couldn't start: couldn't find the host address abc")
        == "无法启动:找不到房主地址 abc", "(and still its own Chinese)")

    -- Latin an Arabic line keeps: the names of things, then (KEPT) the ini's own words, file names, a command and what it
    -- answers, the install guide's heading, which the tsv keeps in Latin on purpose. Any other word of three letters or
    -- more is English the tsv has Arabic for.
    local NAMED_THINGS = { "PhantomPact.ini", "Phantom Pact", "HostAddress", "Steam", "Tailscale", "PvPvE", "PvP", "UDP",
        "Winsock", "DERP" }
    local KEPT = { "SteamDirect = On", "SteamID64", "steam_api64.dll", "Connect = Steam", "Role = Host", "Role = Guest",
        "Secret", "Port", "dlls\\main.dll", "net_start.txt", "tailscale ping", "via DERP", "Connection problems", "UE4SS",
        "New Game" }
    -- (The game's own names stay English, as the game shows them: it has no Arabic. The user, 11-10. The longer first.)
    for _, id in ipairs(ids) do
        if id:find("^term%.") and not T[id].ar:find("[\216-\219]") then
            NAMED_THINGS[#NAMED_THINGS + 1] = T[id].ar
        end
    end
    table.sort(NAMED_THINGS, function(a, b) return #a > #b end)
    local function plain(s)
        return (s:gsub("%p", "%%%0"))
    end
    local left, kept = {}, {}
    for _, s in ipairs(said) do
        local text = s.got
        for _, v in ipairs(s.strip or {}) do
            text = text:gsub(plain(v), " ")
        end
        for _, k in ipairs(KEPT) do
            local found
            text, found = text:gsub(plain(k), " ")
            kept[k] = kept[k] or found > 0
        end
        for _, k in ipairs(NAMED_THINGS) do
            text = text:gsub(plain(k), " ")
        end
        for word in text:gmatch("%a%a%a+") do
            if not left[word] then
                left[word] = true
                bad[#bad + 1] = word .. " (" .. s.id .. ")"
            end
        end
    end
    local found = {}
    for _, k in ipairs(KEPT) do
        if kept[k] then
            found[#found + 1] = k
        end
    end
    out("       Latin the tsv keeps on purpose: " .. table.concat(found, ", "))
    verdict(string.format("no English the tsv has Arabic for is left in an Arabic line: %d lines looked at", #said))
end

-- Arabic on the screen, through the mod's own calls in a session with Language = Arabic. The part above takes lang.lua
-- alone, so main.lua not loading lang_ar.lua, or a screen that never asked for the Arabic, passed it. Here a tip, both
-- panels' words and a match's words come out as the tsv's Arabic (pbz.lua's game.arabicTip, arenaui.lua), the engine's
-- Arabic font goes in as the mod starts, a match falls back to English without it, and a foe bar gets its own font back.
local function arabicScreens()
    part("Arabic on the screen")
    local T = arabicRows()
    local function ar(id)
        return T[id] and T[id].ar
    end
    local ROBOTO = "/Engine/EngineFonts/Roboto.Roboto"
    local s = Session.new(SIM_SCRIPTS, { "Host" }, false, {}, "Language = Arabic\n")
    local h = s.pcs[1]
    local lang, game = h.env.PBZ.lang, h.env.PBZ.game
    check(lang ~= nil and lang.code == "ar" and lang.say("Not connected.") == ar("f5.words.not_connected"),
        "Language = Arabic: the mod says a line as the tsv has it (main.lua loads lang_ar.lua): "
        .. tostring(lang and lang.say("Not connected.")))
    -- Player 2's menu badge (loadout.lua): the Arabic picture if it's in the mod, the English one while a new one waits
    -- for the author's check, out of the mod. (The fake's files go by their names.)
    local badge = h.env.PBZ.loadout and h.env.PBZ.loadout.badgePicture
    if badge then
        local without = badge(2)
        h.files["ar_player_menu_2.png"] = "png"
        local with = badge(2)
        h.files["ar_player_menu_2.png"] = nil
        check(without == "panel/player_menu_2.png" and with == "panel/ar_player_menu_2.png",
            "player 2's menu badge in Arabic: the English picture while the Arabic one isn't in the mod, the Arabic once it is ("
                .. tostring(without) .. ", " .. tostring(with) .. ")")
    end
    if not (lang and game.arabicTip and game.arabicText and game.ownText) then
        return                                  -- (old scripts: no Arabic to show)
    end
    -- The engine's Roboto (fakepc.lua's), its fallback face: the Arabic one before a single frame has run.
    local roboto = h.found[ROBOTO]
    local face = roboto and rawget(roboto, "__fields").CompositeFont.FallbackTypeface.Typeface.Fonts.items[1].Font
    local fallback = face and rawget(face, "__fields") or {}
    check(fallback.FontFilename == game.ARABIC_TTF and fallback.LoadingPolicy == 0 and fallback.FontFaceAsset == nil
        and count(h.logs, "Arabic: the engine's Arabic font is in") == 1,
        "as the mod starts, before anything is shown, the engine's Arabic font goes in as Roboto's fallback, once "
        .. "(game.arabicFont): " .. tostring(fallback.FontFilename))

    -- What reaches game.arabicTip, and for which widget. (The fake's widgets have no TextBlock beside them to put it in.)
    local calls = {}
    local arabicTip = game.arabicTip
    game.arabicTip = function(w, text, pt, wrap)
        calls[#calls + 1] = { w = w, text = text, pt = pt, wrap = wrap }
        return arabicTip(w, text, pt, wrap)
    end
    local function sent(from, wrap)            -- the first line given since call from, wrapped at wrap (nil: the tip's own)
        for i = from + 1, #calls do
            if calls[i].text ~= nil and calls[i].wrap == wrap then
                return calls[i]
            end
        end
    end
    s:run(2)
    local from = #calls
    Session.command(h, "tips your partner is down.")
    s:run(1)
    local c = sent(from, nil)
    check(c ~= nil and c.text == ar("tip.prefix") .. ar("tip.partner.down") and c.pt == nil,
        "a tip (tips your partner is down.) reaches game.arabicTip in the tsv's Arabic, its head too: "
        .. tostring(c and c.text))
    check(c ~= nil and field(c.w, "lastText") == "Phantom Pact: your partner is down.",
        "and the tip's own text keeps the English, hidden, for the bar's size: " .. tostring(c and field(c.w, "lastText")))
    from = #calls
    Session.command(h, "onlinepanel toggle")
    s:run(1)
    c = sent(from, 1100)
    check(c ~= nil and c.text == ar("f5.words.waiting") and field(c.w, "lastText") == "Waiting for a partner.",
        "the online panel's words (F5) reach it in the tsv's Arabic, to wrap in the box (1100), the English kept hidden: "
        .. tostring(c and c.text))
    Session.command(h, "onlinepanel toggle")
    s:run(0.5)
    from = #calls
    Session.command(h, "pvppanel toggle")
    s:run(1)
    c = sent(from, 1100)
    check(c ~= nil and c.text == ar("f6.words.nobody")
        and field(c.w, "lastText") == "Nobody to fight: a partner needs to be linked.",
        "and the PvP page's (F6): " .. tostring(c and c.text))
    Session.command(h, "pvppanel toggle")
    s:run(0.5)

    -- A foe bar's name (pbz.lua's showFoeBar and setFoeName): game.arabicText puts it in Roboto, and after a switch from
    -- Arabic game.ownText gives it back its own font, from the note it keeps by the TextBlock's address. The TextBlock is
    -- as UE4SS hands one over: its Font a copy, that only SetFont puts back.
    local OWN = "/Game/PBZContent/UI/Fonts/BossName.BossName"
    local own = Fake.object(h, "Font")
    rawset(own, "__path", OWN)
    h.found[OWN] = own
    local font = { FontObject = own, TypefaceFontName = h.env.FName("Bold"), Size = 22 }
    local label = setmetatable({
        IsValid = function() return true end,
        GetAddress = function() return 0x7E0000 end,
        SetFont = function(_, f)
            font = { FontObject = f.FontObject, TypefaceFontName = f.TypefaceFontName, Size = f.Size }
        end,
    }, { __index = function(_, k)
        if k == "Font" then
            return { FontObject = font.FontObject, TypefaceFontName = font.TypefaceFontName, Size = font.Size }
        end
    end })
    local function typeface()
        return font.TypefaceFontName and font.TypefaceFontName:ToString()
    end
    check(game.arabicText(label, 18) == true and font.FontObject == h.found[ROBOTO] and typeface() == "Regular"
        and font.Size == 18, "game.arabicText puts a foe bar's name in Roboto")
    check(game.ownText(label) == true and font.FontObject == own and typeface() == "Bold" and font.Size == 22,
        "and game.ownText gives it its own font back: the font, its face and its size")
    allErrors(s)

    -- A duel (arena.lua, arenaui.lua), two players in Arabic: the foe's name over their bar, and the countdown's words.
    local duel = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, {}, "Language = Arabic\n")
    local dh, dg = duel.pcs[1], duel.pcs[2]
    duel:run(4)
    Session.moveTo(dh, 0, 0)
    Session.moveTo(dg, 500, 0)
    duel:run(2)
    local dgame, dlang = dh.env.PBZ.game, dh.env.PBZ.lang
    local names, asked = {}, {}
    local showFoeBar, say = dgame.showFoeBar, dlang.say
    dgame.showFoeBar = function(body, foe, hud)
        names[#names + 1] = foe
        return showFoeBar(body, foe, hud)
    end
    dlang.say = function(text)
        asked[text] = say(text)
        return asked[text]
    end
    Session.command(dh, "arena place 0")
    Session.command(dg, "arena ready")
    duel:run(1.5)
    Session.command(dh, "arena start")
    duel:run(6)
    local match = dh.env.PBZ.arena.match
    check(match ~= nil and match.phase == "fight", "(a duel is on: " .. tostring(match and match.phase) .. ")")
    local foe = (ar("match.foe.name") or "?"):gsub("%%d", "2")
    check(names[#names] == foe, "the foe's bar goes up with their name in the tsv's Arabic: " .. tostring(names[#names]))
    local WORDS = { { "ONE", "match.count.one" }, { "TWO", "match.count.two" }, { "THREE", "match.count.three" },
        { "FIGHT", "match.count.fight" }, { "TIME'S UP", "match.timeup" } }
    local all = true
    for _, w in ipairs(WORDS) do
        all = all and asked[w[1]] == ar(w[2])
    end
    check(all, "as the countdown starts, the match asks for ONE, TWO, THREE, FIGHT and TIME'S UP in Arabic: the tsv's")
    local you = (ar("match.foe.score") or ""):match("· +(.-) %%d")
    check(you ~= nil and asked["YOU"] == you, "and the duel's score over the foe's bar its YOU: " .. tostring(asked["YOU"]))
    -- (arenaui.lua's own sayWord, found through the closures that use it: the fake's widgets have no TextBlock to show
    -- what it gives.)
    local function upvalue(fn, wanted)
        for i = 1, type(fn) == "function" and 255 or 0 do
            local n, v = debug.getupvalue(fn, i)
            if n == nil or n == wanted then
                return v
            end
        end
    end
    local ui = (upvalue(dh.env.PBZ.arena.blocker, "api") or {}).arenaui or {}
    local sayWord = upvalue(upvalue(ui.prepareCount, "wordPart"), "sayWord")
    local function words(arabic)                -- each in the tsv's Arabic in Roboto, or in English in the game's font
        local good = sayWord ~= nil
        for _, w in ipairs(WORDS) do
            if sayWord then
                local text, fontPath = sayWord(w[1])
                good = good and (arabic and text == ar(w[2]) and fontPath == dgame.ARABIC_FONT
                    or not arabic and text == w[1] and fontPath ~= dgame.ARABIC_FONT)
            end
        end
        return good
    end
    check(words(true), "and arenaui.lua's sayWord gives each in the tsv's Arabic, in the font that draws it (Roboto)")
    -- Without the font (game.arabicFont false: Roboto not loaded yet, or with no fallback face), English, not boxes. (The
    -- fake's HUD makes no bar, so the match puts the foe's up again every second, with their name as it is then.)
    local arabicFont = dgame.arabicFont
    dgame.arabicFont = function() return false end
    local before = #names
    duel:run(1.5)
    check(#names > before and names[#names] == "PLAYER 2", "without the Arabic font the foe's name is English: "
        .. tostring(names[#names]))
    check(words(false), "and so are the countdown's words, in the game's own font")
    dgame.arabicFont = arabicFont
    allErrors(duel)
end

local function width(s)                    -- a letter 1, a Chinese character 2
    local w = 0
    for _, cp in utf8.codes(s) do
        w = w + (cp >= 0x2E80 and 2 or 1)
    end
    return w
end

local function linesOf(s)
    local t = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do
        t[#t + 1] = l
    end
    return t
end

local function widest(ls)
    local w = 0
    for _, l in ipairs(ls) do
        w = math.max(w, width(l))
    end
    return w
end

-- Nothing lost or added in the breaking: the fitted text and the line walked together. Each line break takes the place of
-- one space, or sits between two characters (not first or last, not beside another break, not inside a character's
-- UTF-8) with nothing skipped; every other character is the line's own, and both are walked to their ends. (i, j: where
-- the walk is in each, for trying a break both ways.)
local function brokenOnly(fitted, line, i, j)
    i, j = i or 1, j or 1
    while i <= #fitted do
        local c, was = fitted:sub(i, i), line:sub(j, j)
        if c == "\n" and was ~= "\n" then
            if was == " " and brokenOnly(fitted, line, i + 1, j + 1) then
                return true                     -- (a space became the break)
            end
            local b = line:byte(j)
            if i == 1 or fitted:sub(i - 1, i - 1) == "\n" or fitted:sub(i + 1, i + 1) == "\n" or not b
                or (b >= 0x80 and b < 0xC0) then
                return false
            end
        elseif c == was then
            j = j + 1
        else
            return false
        end
        i = i + 1
    end
    return j == #line + 1
end

-- Long lines broken for the screen (lang.fit, 11-10): the game's tip text never wraps, and the longest tips ran off the
-- screen in one line, in English too. A short line stays as it is; a long one breaks at its spaces, or between Chinese
-- characters, into lines no wider than asked and about as long as each other, with nothing lost.
local function fitting()
    part("long lines broken for the screen")
    local lang = dofile(SIM_SCRIPTS .. "/lang.lua")(SIM_SCRIPTS .. "/")
    check(lang.fit ~= nil, "lang.fit is there")
    if not lang.fit then
        return
    end

    local short = "Phantom Pact: partner connected (ping 9 ms)."
    check(lang.fit(short, 150) == short, "a short line stays as it is")
    local tip = "Phantom Pact: no friend hosting found. You must be Steam friends, and your partner needs Role = Host, "
        .. "Connect = Steam and not to be Invisible in Steam (or put their SteamID64 in HostAddress), and the same Secret "
        .. "and Phantom Pact version on both PCs."
    local fitted = lang.fit(tip, 150)
    local ls = linesOf(fitted)
    check(#ls == 2 and widest(ls) <= 150, string.format("the longest tip (%d letters) in %d lines, the widest %d of 150",
        width(tip), #ls, widest(ls)))
    check(fitted:gsub("\n", " ") == tip, "nothing lost: its line break is where a space was")
    check(#ls == 2 and math.abs(width(ls[1]) - width(ls[2])) <= 20, "the two lines about as long as each other")

    local panel = "Couldn't start the relay: dlls\\main.dll can't be reached. Reinstall Phantom Pact, check your antivirus "
        .. "didn't remove it, and use the UE4SS build from the install guide."
    ls = linesOf(lang.fit(panel, 110))
    check(#ls == 2 and widest(ls) <= 110, string.format("the panel's longest line in %d lines, the widest %d of 110", #ls,
        widest(ls)))
    local huge = (tip .. " "):rep(3)
    ls = linesOf(lang.fit(huge, 110))
    check(#ls >= 4 and widest(ls) <= 110, string.format("a line three times the tip's in %d lines, none over 110", #ls))

    lang.set("Chinese")
    local zh = "Phantom Pact: " .. lang.say("no friend hosting found. You must be Steam friends, and your partner needs "
        .. "Role = Host, Connect = Steam and not to be Invisible in Steam (or put their SteamID64 in HostAddress), and the "
        .. "same Secret and Phantom Pact version on both PCs.")
    check(zh:find("没有找到", 1, true) ~= nil, "(the Chinese of it)")
    fitted = lang.fit(zh, 90)
    ls = linesOf(fitted)
    local startsClosed = false
    for _, l in ipairs(ls) do
        local first = utf8.codepoint(l, 1)
        startsClosed = startsClosed or first == utf8.codepoint("。") or first == utf8.codepoint("，")
            or first == utf8.codepoint(",") or first == utf8.codepoint(".") or first == utf8.codepoint("、")
    end
    check(#ls >= 2 and widest(ls) <= 90, string.format("Chinese breaks between its characters: %d lines, the widest %d of 90",
        #ls, widest(ls)))
    check(not startsClosed, "and no line starts with a closing mark")
    -- (Exactly: a check with every space taken out of both passed a fit that added spaces between the characters, or
    -- dropped some.)
    check(brokenOnly(fitted, zh), "nothing lost or added: each break where one space was, or between two characters")
    check(not brokenOnly("Phantom\nPact:  " .. zh:sub(15), zh) and not brokenOnly(zh:gsub("你", "你 ", 1), zh)
        and not brokenOnly(zh:gsub(" ", "", 1), zh) and not brokenOnly("\n" .. zh, zh),
        "(and the walk tells: a space added, or one dropped, or a break before the first character, each fails it)")
    local bad = ("\255"):rep(200)
    check(lang.fit(bad, 100) == bad, "a line that isn't UTF-8 is left as it is")
    check(lang.fit(nil, 100) == nil and lang.fit(tip, nil) == tip, "and no line, or no width, is no harm")
end

-- Long lines broken through the mod's own calls, in English. The part above takes lang.fit alone, so a screen that never
-- asked for it passed. The longest tip reaches the tip's widget in lines no wider than status.lua's TIP_FIT, a long line
-- of the online panel's (F5) in lines no wider than its WORDS_FIT (both read from the scripts), and the PvP page's (F6)
-- words go through lang.fit at its own.
local function fittedOnScreen()
    part("long lines broken on the screen")
    local function fitIn(script, name)
        local f = io.open(SIM_SCRIPTS .. "/" .. script, "rb")
        local text = f and f:read("a") or ""
        if f then
            f:close()
        end
        return tonumber(text:match("local " .. name .. "%s*=%s*(%d+)"))
    end
    local TIP_FIT, WORDS_FIT, PAGE_FIT = fitIn("status.lua", "TIP_FIT"), fitIn("onlinepanel.lua", "WORDS_FIT"),
        fitIn("pvppanel.lua", "WORDS_FIT")
    check(TIP_FIT and WORDS_FIT and PAGE_FIT, string.format("(the widths, from the scripts: a tip %s, F5's words %s, "
        .. "F6's %s)", tostring(TIP_FIT), tostring(WORDS_FIT), tostring(PAGE_FIT)))
    if not (TIP_FIT and WORDS_FIT and PAGE_FIT) then
        return
    end
    -- A guest set to join a Steam friend by a name it can't use: the panel's Join says why, in a line longer than its box.
    local s = Session.new(SIM_SCRIPTS, { "Guest" }, false, {}, "Connect = Steam\nHostAddress = a&b\n")
    local g = s.pcs[1]
    s:run(2)
    local function shownIn(line)               -- the widget whose text is this line, its line breaks taken as spaces
        for _, w in ipairs(g.widgets) do
            local text = field(w, "lastText")
            if text and text:gsub("\n", " ") == line then
                return w
            end
        end
    end
    local said = "no friend hosting found. You must be Steam friends, and your partner needs Role = Host, Connect = Steam "
        .. "and not to be Invisible in Steam (or put their SteamID64 in HostAddress), and the same Secret and Phantom Pact "
        .. "version on both PCs."
    local tip = "Phantom Pact: " .. said
    Session.command(g, "tips " .. said)
    s:run(1)
    local w = shownIn(tip)
    local ls = w and linesOf(field(w, "lastText")) or {}
    check(#ls == 2 and widest(ls) <= TIP_FIT, string.format("the longest tip (%d letters, through tips ...) on its "
        .. "widget in %d lines, each break where a space was, the widest %d of status.lua's %d", width(tip), #ls,
        widest(ls), TIP_FIT))
    local line = "PhantomPact.ini: HostAddress has a character that can't be used (\" % & | < > ^). Leave it empty to join "
        .. "any friend who's hosting."
    Session.command(g, "onlinepanel toggle")
    Session.command(g, "onlinepanel join")
    s:run(1)
    w = shownIn(line)
    ls = w and linesOf(field(w, "lastText")) or {}
    check(#ls == 2 and widest(ls) <= WORDS_FIT, string.format("the online panel's (F5) why for that name (%d letters) in %d "
        .. "lines, the widest %d of onlinepanel.lua's %d", width(line), #ls, widest(ls), WORDS_FIT))
    -- (None of the F6 page's lines is that long in a sim: its words are seen going through lang.fit.)
    local fits = {}
    local fit = g.env.PBZ.lang.fit
    g.env.PBZ.lang.fit = function(text, max)
        fits[#fits + 1] = { text = text, max = max }
        return fit(text, max)
    end
    Session.command(g, "onlinepanel toggle")
    Session.command(g, "pvppanel toggle")
    s:run(1)
    local page = "Play online first (F5): PvP is between linked players. Your loadout is kept for when you are."
    local through = false
    for _, f in ipairs(fits) do
        through = through or (f.text == page and f.max == PAGE_FIT)
    end
    check(through and shownIn(page) ~= nil, "the PvP page's (F6) words go through lang.fit at pvppanel.lua's " .. PAGE_FIT)
    allErrors(s)
end

-- A boss that falls only to a finishing move, a guest's plain killing blows at it (393, its words 395's). One at a floor
-- of the host's game's own isn't taken, and the copy stands up again, with nothing told either player why (the bench,
-- run205). Once he has stood at that floor for 20 s since such a blow, no scene playing (a phase's scene starts from
-- such a floor by itself, well inside that), each side is told what ends him: once in two minutes a boss, and then
-- only for a blow not taken since. (A guest's own finishing move is his end: guestsFinisher.)
local function finisherWithTheHostUp()
    part("a boss that falls only to a finishing move: a plain blow, the host up")
    local HOSTS = "this boss falls only to a finishing move: a plain blow can't end it."
    local GUESTS = HOSTS
    local function shown(pc)
        local tip = pc.env.PBZ.status.lastShown.finisher
        return tip and tip.text or nil
    end
    -- The host up and in the fight with the guest, the host's boss low with a floor of the game's own under him (or none).
    local function upAt(floor)
        local s, h, g = pair()
        bossStart(s)
        local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        swing(g, copy, select(1, Fake.health(copy)) - 50)
        s:run(5)
        local min = field(field(boss, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", floor)
        Fake.put(min, "CurrentValue", floor)
        Fake.setHealth(boss, 300)
        s:run(2)
        h.sent = {}
        return s, h, g, boss, copy
    end
    -- (The guest's killing blow, and the seconds after it.)
    local function strike(s, g, copy, wait)
        swing(g, copy, 1)
        s:run(wait or 1)
    end
    local function told(h)
        return count(h.sent, "^E FB sp:boss$")
    end

    local s, h, g, boss, copy = upAt(1)
    strike(s, g, copy)
    check(select(1, Fake.health(boss)) == 2 and field(boss, "dead") ~= true and count(g.logs, "The host didn't take the killing blow") == 1
        and told(h) == 0 and shown(h) == nil and shown(g) == nil,
        "a guest's killing blow at a floor of the game's own isn't taken, and nothing is said at once: a phase's scene may be coming")
    for _ = 1, 4 do
        strike(s, g, copy, 3)
    end
    check(told(h) == 0 and shown(g) == nil, "13 s at that floor, the guest's blows stopped there one after another: nothing said yet")
    for _ = 1, 3 do
        strike(s, g, copy, 3)
    end
    check(told(h) == 1 and shown(h) == HOSTS and shown(g) == GUESTS,
        "22 s there, no scene: each side is told what ends him: " .. tostring(shown(h)) .. " / " .. tostring(shown(g)))
    check(count(h.logs, "isn't its end: it falls only to a finishing move") == 1
        and count(g.logs, "sp:boss falls only to a finishing move") == 1 and h.env.PBZ.game.bossFightActive() and field(boss, "dead") ~= true,
        "once in each log, and the fight goes on")
    for _ = 1, 10 do
        strike(s, g, copy, 3)
    end
    s:run(85)
    check(told(h) == 1, "not again at each blow that follows, nor in the two minutes after")
    s:run(6)
    check(told(h) == 2, "two minutes on, blows stopped there since: said again")
    s:run(130)
    check(told(h) == 2, "two more with no blow stopped there since: not a third time")
    strike(s, g, copy, 3)
    check(told(h) == 3, "a new one stopped there: said")
    allErrors(s)

    -- A phase's scene starts from such a floor by itself: nothing is said through it, nor of the phase after it.
    local v, vh, vg, vboss, vcopy = upAt(1)
    strike(v, vg, vcopy, 3)
    Session.scene(vh, true, "Seq023")
    for _ = 1, 10 do
        strike(v, vg, vcopy, 3)         -- (the guest, not in that scene, strikes on)
    end
    check(told(vh) == 0 and shown(vg) == nil,
        "a scene playing in the host's world, the guest's blows stopped at his floor all through it (30 s): nothing said")
    Fake.setHealth(vboss, select(2, Fake.health(vboss)))
    Session.scene(vh, false)
    v:run(30)
    check(told(vh) == 0 and shown(vg) == nil and shown(vh) == nil, "its end, his next phase begun off that floor: nothing said")
    allErrors(v)

    -- Off his floor before those 20 s (healed), back at it by a new blow: counted anew.
    local w, wh, wg, wboss, wcopy = upAt(1)
    strike(w, wg, wcopy)
    w:run(12)
    Fake.setHealth(wboss, 500)
    w:run(3)
    Fake.setHealth(wboss, 300)
    w:run(2)
    strike(w, wg, wcopy)
    w:run(12)
    check(told(wh) == 0, "off his floor for a moment, a new killing blow stopped there: counted from it (13 s)")
    w:run(10)
    check(told(wh) == 1, "and said once 20 s have run from it")
    allErrors(w)

    -- No floor of the game's: the guest's killing blow is his death, as ever, and nothing is said.
    local u, uh, ug, uboss, ucopy = upAt(0)
    strike(u, ug, ucopy)
    u:run(25)
    check(field(uboss, "dead") == true and told(uh) == 0 and shown(uh) == nil and shown(ug) == nil,
        "no floor under him: the guest's killing blow is his death, nothing said")
    allErrors(u)
end

-- A guest's own finishing move ends the boss for everyone (395). The user, 11-18: "why the guest can't kill the boss by
-- pressing F and playing it's animation he should be able to do that". The guest's game plays its finishing move on
-- its copy (the bench, run205: an ability of the game's "BEx" family on the guest's player, the copy marked by that
-- game for an execution at low health, the killing blow 2.9 s in); told as that, the host lifts its game's floor for
-- that blow and makes the game's own kill, the whole death (run211: as at his end by the host's own finishing move).
-- A plain killing blow there is still not his end. (What says a finishing move is under way is the game's own, read by
-- pbz.lua's finishing and hasEffect: stood in for here, the fake having neither a player's abilities nor effects.)
local function guestsFinisher()
    part("a guest's own finishing move ends the boss for everyone")
    local LINE = "this boss falls only to a finishing move: a plain blow can't end it."
    local function floorOf(e)
        return field(field(e, "AttributeSetBase"), "Health_Min").CurrentValue
    end
    -- (The guest's game as it stands in a finishing move, or not: its own ability running, and the effects on its
    -- copy by their class names: true for the game's mark for a finish at low health alone.)
    local MARK, EDGE = "GE_CanLowHealthExecute_C", "GE_CanLowHealthExecute_XueDiZi_C"
    local function finishing(g, move, mark)
        local on = mark == true and { MARK } or (mark or {})
        g.env.PBZ.game.finishing = function() return move and "GA_Hun_BEx_Common_Boss" or nil end
        g.env.PBZ.game.hasEffect = function(_, text, exact)
            for _, name in ipairs(on) do
                if name == text or (not exact and name:find(text, 1, true)) then
                    return true
                end
            end
            return false
        end
    end
    -- The host's boss low with a floor of its game's own under him, the guest's plain killing blow stopped there.
    local function atFloor(down)
        local s, h, g = pair()
        bossStart(s)
        local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        swing(g, copy, select(1, Fake.health(copy)) - 50)
        s:run(5)
        if down then
            Session.die(h)
            h.hudLayout:UnRegisterBossHPBar(boss)
            s:run(6)
        end
        local min = field(field(boss, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", 1)
        Fake.put(min, "CurrentValue", 1)
        Fake.setHealth(boss, 300)
        s:run(2)
        finishing(g, false, false)
        swing(g, copy, 1)
        s:run(2)
        return s, h, g, boss, copy
    end

    local s, h, g, boss, copy = atFloor(false)
    check(select(1, Fake.health(boss)) == 2 and field(boss, "dead") ~= true and count(g.logs, "The host didn't take the killing blow") == 1,
        "(a plain killing blow of the guest's at a floor of the host's game's own: not his end, as ever)")
    finishing(g, true, true)
    s:run(1.5)
    swing(g, copy, 1)
    s:run(2)
    check(count(g.logs, "Finishing move on sp:boss; telling the host") == 1 and count(h.logs, "Partner's finishing move on sp:boss") == 1,
        "the guest's own finishing move on its copy is told as that")
    check(field(boss, "dead") == true and field(copy, "dead") == true,
        "and it's his end in both worlds: the host's game's floor lifted for that blow")
    check(count(h.sent, "^E K sp:boss$") == 1 and count(h.sent, "^E FN ") == 0, "told once, and no fight starts over")
    allErrors(s)

    -- The copy not marked by the guest's game for a finish at low health (an execution on a broken guard takes health
    -- and ends nobody): a plain killing blow, not taken. Marked with no finishing move running: the same.
    local t, th, tg, tboss, tcopy = atFloor(false)
    finishing(tg, true, false)
    t:run(1.5)
    swing(tg, tcopy, 1)
    t:run(2)
    check(field(tboss, "dead") ~= true and floorOf(tboss) == 1 and count(th.logs, "Partner's finishing move") == 0
        and count(tg.logs, "The host didn't take the killing blow") == 2,
        "its own ability running, the copy not marked for a finish at low health: a plain killing blow, not taken")
    -- (A Phantom Edge's own mark, on a boss at full health too, isn't that one, though its name holds the other's: by
    -- its whole name. The tenth review.)
    finishing(tg, true, { EDGE })
    t:run(1.5)
    swing(tg, tcopy, 1)
    t:run(2)
    check(field(tboss, "dead") ~= true and floorOf(tboss) == 1 and count(th.logs, "Partner's finishing move") == 0
        and count(tg.logs, "The host didn't take the killing blow") == 3,
        "nor with a Phantom Edge's own mark alone on it, a name that holds the other's: a plain killing blow")
    finishing(tg, false, true)
    t:run(1.5)
    swing(tg, tcopy, 1)
    t:run(2)
    check(field(tboss, "dead") ~= true and floorOf(tboss) == 1 and count(th.logs, "Partner's finishing move") == 0,
        "marked, with no finishing move running: the same")
    allErrors(t)

    -- One the host's game won't let die now (between phases, a scene to come): not forced, its floor back as it was.
    -- And still the boss of the host's own fight: forgotten as one for the kill, then shown again as a partner's, the
    -- host's fight read as over, F 0 went out and the hold of that fight with it (the tenth review).
    local l, lh, lg, lboss, lcopy = atFloor(false)
    Fake.put(lboss, "locked", true)
    finishing(lg, true, true)
    l:run(1.5)
    lh.sent = {}
    swing(lg, lcopy, 1)
    l:run(2)
    check(field(lboss, "dead") ~= true and floorOf(lboss) == 1 and count(lh.logs, "Partner's finishing move on sp:boss") == 1,
        "one the host's game won't let die now: not forced, its floor as it was")
    l:run(4)
    check(count(lh.sent, "^E F 0") == 0 and (net(lh).fightNames or {})["sp:boss"] == true
        and lh.env.PBZ.game.bossFightActive() and not lh.env.PBZ.game.isMirrorBar(lboss),
        "and still the boss of the host's own fight: no word that it's over, his bar not a partner's fight's")
    allErrors(l)

    -- A scene playing in the host's world as it comes (a phase's, begun from that floor): not taken, the floor as it
    -- was. The game's kill isn't refused once the floor is off (run211: the Axe chief's lock was still on him as it
    -- took), so the floor is lifted only where a finishing move is his end. (The tenth review.)
    local c, ch, cg, cboss, ccopy = atFloor(false)
    Session.scene(ch, true, "Seq023")
    finishing(cg, true, true)
    c:run(1.5)
    swing(cg, ccopy, 1)
    c:run(2)
    check(field(cboss, "dead") ~= true and floorOf(cboss) == 1
        and count(ch.logs, "A finishing move on sp:boss isn't its end here: a scene plays there") == 1,
        "a scene playing in the host's world: a guest's finishing move isn't taken, the floor as it was")
    allErrors(c)

    -- A floor well over the last point (a phase's, at two fifths of his health): the same.
    local p, ph, pg, pboss, pcopy = atFloor(false)
    local pmin = field(field(pboss, "AttributeSetBase"), "Health_Min")
    Fake.put(pmin, "BaseValue", 2000)
    Fake.put(pmin, "CurrentValue", 2000)
    Fake.setHealth(pboss, 2001)
    p:run(2)
    finishing(pg, true, true)
    p:run(1.5)
    swing(pg, pcopy, 1)
    p:run(2)
    check(field(pboss, "dead") ~= true and floorOf(pboss) == 2000 and select(1, Fake.health(pboss)) == 2001
        and count(ph.logs, "A finishing move on sp:boss isn't its end here: the floor there is a phase's") == 1,
        "a phase's floor, at two fifths of his health: not taken either (" .. tostring((Fake.health(pboss))) .. " left)")
    p:run(24)
    check(count(ph.sent, "^E FB ") == 0 and (pg.env.PBZ.status.lastShown.finisher or {}).text == nil,
        "and nobody is told a finishing move ends him there")
    allErrors(p)

    -- Another phase of him to come, its spawner in the host's world (a boss of phases, a spawner each): his end there
    -- is a scene and that phase, the game's to bring.
    local q, qh, qg, qboss, qcopy = atFloor(false)
    Fake.enemy(qh, "bossP2", "BP_Monster_Boss_C", 60000.0, 3000.0, 100.0, 5000, 400, true)
    finishing(qg, true, true)
    q:run(1.5)
    swing(qg, qcopy, 1)
    q:run(2)
    local after = qh.env.PBZ.game.phaseAfter
    check(after ~= nil and after("sp:boss") == true and after("sp:bossP2") == false and after("sp:thug1") == false
        and field(qboss, "dead") ~= true and floorOf(qboss) == 1
        and count(qh.logs, "A finishing move on sp:boss isn't its end here: another phase of it is to come") == 1,
        "another phase of him to come in the host's world: not taken, the floor as it was")
    q:run(24)
    check(count(qh.sent, "^E FB ") == 0 and (qg.env.PBZ.status.lastShown.finisher or {}).text == nil,
        "and nobody is told a finishing move ends him there: one made wasn't taken (the tenth review's read of 396)")
    allErrors(q)

    -- The finishing move's one blow from over the hold's floor: the game's mark comes up there (run184: on the copy
    -- with the blow from 150 to 70 of 28080), and the move's blow takes the copy from there to its floor in one. Looked
    -- for at the hold's floor alone, the mark wasn't seen and the move went as a plain blow. (The tenth review.)
    local a, ah, ag = pair()
    bossStart(a)
    local aboss, acopy = Session.enemyOn(ah, "boss"), Session.enemyOn(ag, "boss")
    swing(ag, acopy, select(1, Fake.health(acopy)) - 50)
    a:run(5)
    local amin = field(field(aboss, "AttributeSetBase"), "Health_Min")
    Fake.put(amin, "BaseValue", 1)
    Fake.put(amin, "CurrentValue", 1)
    Fake.setHealth(aboss, 300)
    a:run(2)
    local over = select(1, Fake.health(acopy))
    finishing(ag, true, true)
    a:run(1.5)
    swing(ag, acopy, 1)
    a:run(2)
    check(over > 100 and count(ag.logs, "Finishing move on sp:boss; telling the host") == 1
        and field(aboss, "dead") == true and field(acopy, "dead") == true,
        "the finishing move's one blow from over the hold's floor (the copy at " .. tostring(over) .. "): his end in both worlds")
    allErrors(a)

    -- The host down and held, the guest left alone at him (the report on 1.7.3: "the host died and i was able to kill the
    -- boss alone but when it came to combat finish i was glitched"): told what ends him 20 s in, and its own finishing
    -- move then is his end. No fight starts over.
    local d, dh, dg, dboss, dcopy = atFloor(true)
    check(field(dh.deathWidget, "NotTick") == true, "(the host down and held, the guest's plain killing blow stopped at his floor)")
    d:run(22)
    check(count(dh.sent, "^E FB sp:boss$") == 1 and (dg.env.PBZ.status.lastShown.finisher or {}).text == LINE
        and field(dh.deathWidget, "NotTick") == true,
        "22 s on the guest is told what ends him, the host still held")
    finishing(dg, true, true)
    d:run(1.5)
    swing(dg, dcopy, 1)
    d:run(3)
    check(field(dboss, "dead") == true and field(dcopy, "dead") == true and count(dh.sent, "^E FN ") == 0,
        "the guest's own finishing move with the host down: his end in both worlds, and no fight starts over")
    allErrors(d)
end

-- Watching together (398). The user, 11-18: "why don't you make the scene for both play at the same time ... if they
-- were both in the same place of the boss. like a synced movie people want to watch together and react together".
-- The game starts a place's scene as its own player stands in the story's box for it (the bench, run219: some 2 s
-- on). Here each world has such a box at a spot, and the test begins the scene a second after that world's player is
-- in it, the box gone with that.
local function watchingTogether()
    part("a scene begun beside a partner is watched together")
    local SPOT = { X = 2000, Y = 0 }
    local function boxes(s, name)
        local box, since, begun = {}, {}, {}
        for _, pc in ipairs(s.pcs) do
            box[pc] = Fake.storyBox(pc, SPOT.X, SPOT.Y, 100, 7)
            pc.scene = pc.scene or Fake.sceneManager(pc)    -- (the game's scene manager, there all along)
            pc.groundTraces = true                          -- (and ground to be found under a spot)
        end
        s:run(2.5)                                          -- (found by the mod: it looks once in 2 s while it has none)
        return function()
            for _, pc in ipairs(s.pcs) do
                if not begun[pc] and rawget(box[pc], "__alive") and gap(at(pc.pawn), SPOT) <= 300 then
                    since[pc] = since[pc] or pc.now
                    if pc.now - since[pc] >= 1.0 then
                        begun[pc] = true
                        rawset(box[pc], "__alive", false)
                        Session.scene(pc, true, name)
                    end
                end
            end
        end, begun, box
    end
    local function where(pc)
        return pc.env.PBZ.game.scenePos() or -1
    end
    local function rate(pc)
        return field(pc.scene, "rate")
    end

    -- The host steps in, the guest 15 m back.
    local s, h, g = pair()
    local step, begun = boxes(s, "Seq014")
    Session.moveTo(h, SPOT.X, SPOT.Y)
    s:run(1.6, step)
    check(begun[h] == true and not begun[g] and count(h.sent, "^E SCENE on Seq014 2000 0 %S+ %S+ %S+$") == 1,
        "the host's scene begins, told with where its player stood and its point of the story")
    s:run(1.8, step)
    check(begun[g] == true and gap(at(g.pawn), SPOT) < 10 and count(g.logs, "set down in the story's box for it") == 1,
        "the guest, 15 m back with no scene of its own, is set down in its world's box for it: its own game begins the same scene")
    s:run(1.5, step)
    check(rate(g) > 1 and rate(h) == 1 and where(h) - where(g) > 0.2,
        "begun two seconds later, the guest's plays a little faster (" .. tostring(rate(g)) .. "), the host's at its own speed")
    s:run(6, step)
    check(math.abs(where(h) - where(g)) < 0.3 and rate(g) == 1 and count(g.logs, "is where your partner's is now") == 1,
        "till both are at the same moment of it (" .. string.format("%.2f / %.2f", where(h), where(g)) .. ")")
    Session.scene(h, false)
    Session.scene(g, false)
    s:run(1)
    check(count(h.sent, "^E SCENE skip") == 0, "watched to its end by both: no skip is told")
    allErrors(s)

    -- A boss its opening scene has only just made reads no health yet (408: the user's play logs of 11-19, "Enemy
    -- died here" a tenth of a second before "a scene begins" at each of three such bosses). Not seen alive, it's
    -- no death: nothing is told of it, no fall is counted, and the scene that begins then is told like any other,
    -- the guest 15 m back set down for it.
    local n8, n8h, n8g = pair()
    local n8step, n8begun = boxes(n8, "Seq022")
    local function numbers(e, hp)
        local most = rawget(e, "__fields").AttributeSetBase.Health_Max
        Fake.setHealth(e, hp)
        Fake.put(most, "CurrentValue", hp)
        Fake.put(most, "BaseValue", hp)
    end
    local hook = Fake.enemy(n8h, "hook", "BP_Monster_Boss_C", SPOT.X + 600, SPOT.Y, 100.0, 5000, 400, true)
    numbers(hook, 0)
    n8:run(0.3)
    Session.moveTo(n8h, SPOT.X, SPOT.Y)
    n8:run(1.6, n8step)
    check(n8begun[n8h] == true and count(n8h.sent, "^E K ") == 0 and count(n8h.logs, "Enemy died here") == 0
        and net(n8h).bossFellAt == nil,
        "a boss made as its opening scene begins, no health on it yet: no death is told of it, no fall counted")
    check(count(n8h.sent, "^E SCENE on Seq022 ") == 1, "and its scene is told as it begins")
    numbers(hook, 5000)
    n8:run(2.2, n8step)
    check(n8begun[n8g] == true and count(n8g.logs, "set down in the story") == 1 and count(n8h.sent, "^E K ") == 0,
        "the guest is set down for it; the boss, its health set, is an enemy like any other")
    -- (One that stays so is a body: told once it has lain three seconds, where it was told at once.)
    local lying = Fake.enemy(n8h, "lying", THUG, SPOT.X + 900, SPOT.Y, 100.0, 600, 100)
    Fake.setHealth(lying, 0)
    n8:run(1.0, n8step)
    local early = count(n8h.sent, "^E K ")
    n8:run(3.6, n8step)
    check(early == 0 and count(n8h.sent, "^E K ") == 1 and count(n8h.logs, "Enemy died here") == 1,
        "one met dead that stays so is a body: told once it has lain three seconds (" .. early .. ", "
            .. count(n8h.sent, "^E K ") .. ")")
    allErrors(n8)

    -- The host skips while the guest's, begun later, is still played faster: ended at its own speed, the faster one not
    -- left on a player the game uses again (404: the eleventh review).
    local k, kh, kg = pair()
    local kstep, kbegun = boxes(k, "Seq014")
    Session.moveTo(kh, SPOT.X, SPOT.Y)
    k:run(4.9, kstep)
    local kfast = rate(kg)
    Session.scene(kh, false)
    k:run(1)
    check(kbegun[kg] == true and kfast > 1 and field(kg.scene, "skipped") == 1 and rate(kg) == 1,
        "the host skips while the guest's is still played faster (" .. tostring(kfast) .. "): it ends at its own speed ("
            .. tostring(rate(kg)) .. ")")
    allErrors(k)

    -- A guest the game counts in a fight only because copies of the host's enemies noticed them is come for all the
    -- same (407: the eleventh review). Nothing has gone for them, they have lost no health and told no blow: by live
    -- enemies such a guest was never set down. One who told a blow of their own a moment ago is in a fight.
    local c7, c7h, c7g = pair()
    local c7step, c7begun = boxes(c7, "Seq014")
    c7g.env.PBZ.game.inCombat = function() return true end
    Session.moveTo(c7h, SPOT.X, SPOT.Y)
    c7:run(3.4, c7step)
    check(c7begun[c7g] == true and count(c7g.logs, "set down in the story's box for it") == 1,
        "a guest only counted in a fight, nothing going for them, is set down for the host's scene all the same")
    allErrors(c7)
    local d7, d7h, d7g = pair()
    local d7step, d7begun = boxes(d7, "Seq014")
    d7g.env.PBZ.game.inCombat = function() return true end
    net(d7g).struckAt["sp:near"] = d7g.now + 1000
    Session.moveTo(d7h, SPOT.X, SPOT.Y)
    d7:run(3.4, d7step)
    check(d7begun[d7h] == true and not d7begun[d7g] and count(d7g.logs, "set down in the story's box") == 0,
        "one who told a blow of their own a moment ago is in a fight, and left where they are")
    allErrors(d7)

    -- The other way round: the guest steps in, the host 15 m back.
    local t, th, tg = pair()
    local tstep, tbegun = boxes(t, "Seq014")
    Session.moveTo(th, 500, 0)
    Session.moveTo(tg, SPOT.X, SPOT.Y)
    t:run(3.4, tstep)
    check(tbegun[tg] == true and tbegun[th] == true and gap(at(th.pawn), SPOT) < 10
        and count(tg.sent, "^E SCENE on Seq014 ") == 1,
        "the guest's scene begins with the host 15 m back: the host is set down in its box, its own begins too")
    t:run(7.5, tstep)
    check(math.abs(where(th) - where(tg)) < 0.3 and rate(th) == 1 and rate(tg) == 1,
        "and the host's, the later one, has caught the guest's up (" .. string.format("%.2f / %.2f", where(th), where(tg)) .. ")")
    allErrors(t)

    -- Left where they are: one who isn't by, one whose world has played that scene (this session, or before it: no
    -- box of the story's there any more), one on another map, one in a boss fight of their own, and anyone with
    -- WatchTogether off.
    local function left(why, before, ini)
        local u, uh, ug = pair(ini)
        local ustep, ubegun, ubox = boxes(u, "Seq014")
        if before then
            before(u, uh, ug, ubox)
        end
        local wx, wy = at(ug.pawn).X, at(ug.pawn).Y
        Session.moveTo(uh, SPOT.X, SPOT.Y)
        u:run(4, ustep)
        check(ubegun[uh] == true and not ubegun[ug] and math.abs(at(ug.pawn).X - wx) < 1 and math.abs(at(ug.pawn).Y - wy) < 1
            and count(ug.logs, "set down in the story's box") == 0, why)
        allErrors(u)
    end
    left("a partner 50 m back is left where they are", function(u, _, ug)
        Session.moveTo(ug, SPOT.X - 5000, 0)
        u:run(1)
    end)
    left("one whose world has played that scene this session is left", function(u, _, ug, ubox)
        rawset(ubox[ug], "__alive", false)
        Session.scene(ug, true, "Seq014")
        u:run(1)
        Session.scene(ug, false)
        u:run(1)
    end)
    left("one whose world has no box of the story's there (played before this session) is left", function(_, _, ug, ubox)
        rawset(ubox[ug], "__alive", false)
    end)
    left("one on another map is left", function(u, _, ug)
        ug.map = "Map_Other"
        u:run(3)
    end)
    left("one in a boss fight of their own is left", function(u, _, ug)
        ug.hudLayout:RegisterBossHPBar(Session.enemyOn(ug, "boss"))
        u:run(2)
    end)
    left("with WatchTogether = Off each player's scenes are their own", nil, "WatchTogether = Off\n")
    -- (The eleventh review: who else is left, and which box is no box to stand in.)
    left("one held down by Revive is left: down stays down", function(_, _, ug)
        ug.env.PBZ.revive.isDown = function() return true end
    end)
    left("one fighting anything is left", function(_, _, ug)
        ug.env.PBZ.game.inCombat = function() return true end
        net(ug).aimedAt = ug.now + 1000         -- (something of the host's is going for them: a real fight)
    end)
    left("one in the air is left", function(_, _, ug)
        Fake.put(field(ug.pawn, "CharacterMovement"), "MovementMode", 3)
    end)
    left("one watching a partner's fight is left", function(_, _, ug)
        net(ug).watchingFight = true
    end)
    left("with two of the story's boxes by that spot and neither holding it, nobody is set down on a guess", function(_, _, ug, ubox)
        rawset(ubox[ug], "__alive", false)
        Fake.storyBox(ug, SPOT.X + 800, SPOT.Y, 100, 8)
        Fake.storyBox(ug, SPOT.X - 800, SPOT.Y, 100, 9)
    end)
    left("the only box in reach an arena's, its side 10 m from the spot and its middle 40: another scene's, nobody is set down in it",
        function(_, _, ug, ubox)
            rawset(ubox[ug], "__alive", false)
            Fake.storyBox(ug, SPOT.X + 4000, SPOT.Y, 100, 8, 3000)
        end)
    left("one using something just now, a chest say, is left: not pulled out of it", function(_, _, ug)
        Fake.put(ug.interactComps[1], "InteractingActor", ug.pawn)
    end)
    left("with no ground under the box's spot in their world, they're left", function(_, _, ug)
        ug.noFloor = function() return true end
    end)
    left("one whose story is past the partner's is left: a box can stay after its scene", function(_, uh, ug)
        uh.env.PBZ.story.point = function() return 24, 20 end
        ug.env.PBZ.story.point = function() return 30, 25 end
    end)

    -- A scene inside a boss fight, or a boss's fall, isn't told as one to come to; nor is a partner in a boss fight
    -- come for.
    local f, fh, fg = pair()
    local fstep, fbegun = boxes(f, "Seq014")
    bossStart(f)
    Session.moveTo(fh, SPOT.X, SPOT.Y)
    f:run(4, fstep)
    check(fbegun[fh] == true and not fbegun[fg] and count(fh.sent, "^E SCENE on ") == 0
        and count(fg.logs, "set down in the story's box") == 0,
        "a scene in the host's boss fight isn't told as one to come to, and the guest stays where it is")
    allErrors(f)

    -- A box as big as an arena is taken by its size, not its middle: the spot told is 25 m from the middle of one 60 m
    -- across, and the guest is set down where the host stood.
    local z, zh, zg = pair()
    for _, pc in ipairs(z.pcs) do
        pc.scene = pc.scene or Fake.sceneManager(pc)
        pc.groundTraces = true
    end
    local big = Fake.storyBox(zg, 4500, 0, 100, 9, 3000)
    z:run(2.5)
    Session.moveTo(zh, 2000, 0)
    z:run(1)
    Session.scene(zh, true, "Seq020")
    z:run(1.5)
    check(rawget(big, "__alive") and gap(at(zg.pawn), { X = 2000, Y = 0 }) < 10
        and count(zg.logs, "set down in the story's box for it") == 1,
        "a box 60 m across, its middle 25 m from where the host stood: the guest is set down where the host stood, in it")
    allErrors(z)

    -- An arena's box only near its side isn't counted among the boxes in reach: beside it, the one small box by the
    -- place, which the host ran a few metres past, is still the only one, and the guest is set down in it (405).
    local n, nh, ng = pair()
    for _, pc in ipairs(n.pcs) do
        pc.scene = pc.scene or Fake.sceneManager(pc)
        pc.groundTraces = true
    end
    Fake.storyBox(ng, 2800, 0, 100, 8)              -- (a 6 m box, its middle 8 m past where the host stood)
    Fake.storyBox(ng, -2000, 0, 100, 9, 3000)       -- (an arena's: its side 10 m from that spot, its middle 40)
    n:run(2.5)
    Session.moveTo(nh, 2000, 0)
    n:run(1)
    Session.scene(nh, true, "Seq021")
    n:run(1.5)
    check(count(ng.logs, "set down in the story's box for it") == 1 and math.abs(at(ng.pawn).X - 2600) < 10,
        "a small box 5 m from where the host stood and an arena's 10 m from it by its side: the guest is set down in the small one ("
            .. string.format("%.0f", at(ng.pawn).X) .. ")")
    allErrors(n)

    -- The same scene come to on one's own, long after a partner, isn't chased.
    local y, yh, yg = pair()
    for _, pc in ipairs(y.pcs) do
        pc.scene = pc.scene or Fake.sceneManager(pc)
        Fake.put(pc.scene, "frames", 1800)
    end
    y:run(2.5)
    Session.moveTo(yg, 9000, 0)             -- (90 m off: not come for)
    y:run(1)
    Session.scene(yh, true, "Seq030")
    y:run(20)
    Session.scene(yg, true, "Seq030")
    y:run(4)
    check(rate(yg) == 1 and count(yg.logs, "played a little faster") == 0,
        "the same scene begun 20 s after a partner's, on this player's own: not played faster to chase theirs")
    allErrors(y)

    -- Their scenes ending together, both games start the boss in the same moment and each tells it (the bench, run225:
    -- 0.8 ms apart). The host's fight stays the host's own: filed as the guest's, that guest's F 0 took the host's bar
    -- down mid-fight (402).
    local b, bh, bg = pair()
    bh.hudLayout:RegisterBossHPBar(Session.enemyOn(bh, "boss"))
    bg.hudLayout:RegisterBossHPBar(Session.enemyOn(bg, "boss"))
    b:run(2)
    check(#net(bh).ownBosses() == 1 and net(bh).partnerBosses["sp:boss"] == nil
        and count(bh.logs, "as this game did: it stays this game's own") == 1,
        "a boss both games start in the same moment: the host's fight stays the host's own")
    check(net(bg).partnerBosses["sp:boss"] == true and net(bg).hostBosses["sp:boss"] == true,
        "and it's the host's fight in the guest's world, as when the host began first")
    check(count(bg.logs, "press E at the black wall") == 0 and count(bh.logs, "press E at the black wall") == 0,
        "neither is told to press E at a black wall they stand inside, the guest's own game having begun it too")
    allErrors(b)

    -- With three, each guest hears the host's start and then the other guest's, through the host (404: the review of
    -- 401). Filed as that guest's, their drop took this player's own bar down and opened its walls mid-fight, the
    -- host and this player still in it.
    local b3 = party(nil, nil, { "Host", "Guest", "Guest" })
    Session.moveTo(b3.pcs[1], 0, 0)
    Session.moveTo(b3.pcs[2], 500, 0)
    Session.moveTo(b3.pcs[3], 0, 500)
    b3:run(3)
    for _, pc in ipairs(b3.pcs) do
        pc.hudLayout:RegisterBossHPBar(Session.enemyOn(pc, "boss"))
    end
    b3:run(2)
    local ba, bb = b3.pcs[2], b3.pcs[3]
    -- (The other guest's word after the host's, as it comes over a real link, through the host; and as each fighter
    -- tells their fight again when someone joins.)
    b3.relay:post(bb, "sure", "B sp:boss")
    b3:run(0.5)
    local function bars(pc)
        return #pc.env.PBZ.game.bossActors()
    end
    check(net(ba).fightOf["sp:boss"] == 1 and net(bb).fightOf["sp:boss"] == 1 and bars(ba) == 1 and bars(bb) == 1
        and #net(b3.pcs[1]).ownBosses() == 1,
        "three whose games start a boss in the same moment: in each guest's world it's the host's fight, not the other guest's ("
            .. tostring(net(ba).fightOf["sp:boss"]) .. ", " .. tostring(net(bb).fightOf["sp:boss"]) .. ")")
    bb.cut = true
    b3:run(14)
    check(count(ba.logs, "Lost player 3") == 1 and bars(ba) == 1 and net(ba).partnerBosses["sp:boss"] == true
        and net(ba).fightOf["sp:boss"] == 1,
        "and the other guest's drop takes nothing of it down: this player's own bar stays up (" .. bars(ba)
            .. "), the host's fight still shown")
    allErrors(b3)

    -- A scene played faster ends that much sooner by the clock: the host's own, caught up by some five seconds, isn't
    -- told as skipped at its end.
    local v, vh, vg = pair()
    local vstep, vbegun = boxes(v, "Seq014")
    for _, pc in ipairs(v.pcs) do
        Fake.put(pc.scene, "frames", 900)       -- (a 30 s scene)
    end
    Session.moveTo(vh, 500, 0)
    vh.env.PBZ.game.inDialogue = function() return true end     -- (the host is talking: left where it stands)
    Session.moveTo(vg, SPOT.X, SPOT.Y)
    v:run(5.0, vstep)
    check(vbegun[vg] == true and not vbegun[vh], "(the host, in a dialogue, is left where it stands)")
    vh.env.PBZ.game.inDialogue = function() return false end
    v:run(2.2, vstep)
    check(vbegun[vh] == true, "(and set down as that ends, the guest's scene some five seconds in)")
    v:run(45, function()
        vstep()
        if field(vh.scene, "playing") and where(vh) >= 30 then
            Session.scene(vh, false)
            Session.scene(vg, false)
        end
    end)
    check(field(vh.scene, "playing") ~= true and count(vh.sent, "^E SCENE skip") == 0
        and count(vh.logs, "played a little faster") == 1,
        "the host's, played faster for the seconds it was behind, ends that much sooner: not told as a skip")
    allErrors(v)
end

-- A bell together (398). The user, 11-18: "for bell you should also make sure if the guest presses it then also
-- register for host if they are near each other ... same goes vise versa". A first ring by either is the other's
-- world's first ring too, the game's own (the bell's OnInteract), when they're by it.
local function bellsTogether()
    part("a bell rung beside a partner is rung for both")
    local BELL = { X = 700, Y = 0 }
    local function has(list, x)
        for _, v in ipairs(list) do
            if v == x then
                return true
            end
        end
        return false
    end
    local function woken(pc)
        return field(pc.bell, "active") == true and has(pc.bellIds, "Bell_Sim_001")
    end
    -- (E at the bell: the player's own interact component, as the game's button asks it.)
    local function pressE(pc)
        return field(pc.pawn, "interact"):DoInteract(pc.bell)
    end
    local function where(pc)
        return pc.env.PBZ.game.scenePos() or -1
    end
    local function rate(pc)
        return field(pc.scene, "rate")
    end

    -- The host rings it, the guest 10 m off.
    local s, h, g = pair()
    h.groundTraces, g.groundTraces = true, true
    Session.moveTo(g, 1700, 0)
    Session.moveTo(h, 600, 0)
    s:run(2)
    pressE(h)
    s:run(1.5)
    check(woken(h) and h.bellTouches == 1 and count(h.sent, "^E BELL ring 700 0 100 600 0 %S+ %S+$") == 1,
        "the host's first ring of a bell is told with where the bell stands and where the host stood")
    check(woken(g) and count(g.logs, "rung in this world too") == 1 and gap(at(g.pawn), BELL) < 400,
        "the guest, 10 m off, is set down by it and its world's bell rung for it: woken there too, the game's own ring")
    -- (403. The bench, run228: rung by the bell's own OnInteract from the mod, the partner's bell was woken with no
    -- first touch. By the player's own interact component, as E: run230, its first touch 2.8 s after the ringer's.)
    check(g.bellTouches == 1 and has(field(field(g.pawn, "interact"), "used"), g.bell),
        "by the guest's own interact component, as E rings it: with its first touch there ("
            .. tostring(g.bellTouches) .. ")")
    check(count(g.sent, "^E BELL ring") == 0, "and that ring isn't told back")
    allErrors(s)

    -- The other way round: the guest rings it, the host by. Registered in the host's world too.
    local t, th, tg = pair()
    th.groundTraces, tg.groundTraces = true, true
    Session.moveTo(tg, 600, 0)
    t:run(2)
    pressE(tg)
    t:run(1.5)
    check(woken(tg) and woken(th) and count(th.logs, "rung in this world too") == 1 and th.bellTouches == 1,
        "the guest's first ring with the host by: rung in the host's world too, with its first touch")
    allErrors(t)

    -- A bell with a scene of its own, a crane's. The bench, run230: rung for a partner by their interact component,
    -- its first touch came and then the bell's menu, the crane's scene and the story's steps never: the bell spent,
    -- its scene unseen. It is never rung for a partner: each rings their own. Rung within 30 s of each other, their
    -- scenes are kept together, the later one a little faster.
    local function crane(pc)
        rawset(pc.bell, "__classObject", { IsValid = function() return true end,
            GetFName = function() return Fake.name("BP_MelodiousBell_StoneCrane_C") end })
        pc.groundTraces = true
        pc.scene = Fake.sceneManager(pc)        -- (the game's scene manager, there all along)
        Fake.put(pc.scene, "frames", 1800)      -- (one long sequence, 60 s here: the crane's scene is its first seconds)
    end
    local c, ch, cg = pair()
    crane(ch)
    crane(cg)
    Session.moveTo(cg, 900, 0)
    Session.moveTo(ch, 600, 0)
    c:run(2.5)
    local gx = at(cg.pawn).X
    pressE(ch)
    c:run(1.5)
    check(woken(ch) and not woken(cg) and cg.bellTouches == nil and math.abs(at(cg.pawn).X - gx) < 1
        and count(cg.logs, "rung in this world too") == 0 and count(cg.logs, "a scene of its own") == 1,
        "a crane's bell rung by the host, the guest 2 m off: not rung for the guest, its first ring stays theirs, and it's said")
    Session.scene(ch, true, "SeqsCrane")
    c:run(1.5)
    pressE(cg)
    c:run(0.5)
    Session.scene(cg, true, "SeqsCrane")
    c:run(1.5)
    check(cg.bellTouches == 1 and woken(cg) and rate(cg) > 1 and rate(ch) == 1 and where(ch) - where(cg) > 0.2
        and count(ch.sent, "^E SCENE on") == 0 and count(cg.sent, "^E SCENE on") == 0,
        "the guest rings its own 3 s after: its scene, begun two seconds later, plays a little faster ("
            .. tostring(rate(cg)) .. "); it is told as begun by neither")
    c:run(6)
    check(math.abs(where(ch) - where(cg)) < 0.3 and rate(cg) == 1 and count(cg.logs, "is where your partner's is now") == 1,
        "till both are at the same moment of it (" .. string.format("%.2f / %.2f", where(ch), where(cg)) .. ")")
    -- (run228 and run229: the crane's scene is the first 18 s of one long sequence, and from 40 s in its camera is
    -- back for the story's scene there, to the sequence's end: a second scene by the same name. Taken as an
    -- ordinary scene it was told as begun, a partner by set down in the story's box there; and watched whole it
    -- read as skipped, the sequence being longer than the part.)
    Session.scene(ch, false)
    Session.scene(cg, false)
    c:run(20)
    check(count(ch.sent, "^E SCENE skip") == 0 and count(ch.logs, "its end isn't told as a skip") == 1,
        "the bell's scene ends 10 s into its 60 s sequence: no skip is told of it")
    Session.scene(ch, true, "SeqsCrane")
    Session.scene(cg, true, "SeqsCrane")
    Fake.put(ch.scene, "posAt", 30)     -- (the later part: from the middle of the sequence)
    Fake.put(cg.scene, "posAt", 30)
    c:run(20)
    -- (Its camera goes back to the players 10 s before the sequence's end, the sequence playing on: run231, the
    -- crane's second part over 8 s before its sequence, "skipped after 164.5 of 213.2 s: the guest's too".)
    Fake.put(ch.controller, "viewTarget", nil)
    Fake.put(cg.controller, "viewTarget", nil)
    c:run(2)
    check(count(ch.sent, "^E SCENE on") == 0 and count(cg.sent, "^E SCENE on") == 0,
        "its camera comes back 20 s on, a later part of that sequence: told as begun by neither")
    check(count(ch.sent, "^E SCENE skip") == 0 and field(cg.scene, "skipped") == nil
        and count(ch.logs, "which plays on: the camera's part was over, no skip") == 1,
        "that part over by itself, its sequence playing on for seconds more: no skip is told of it")
    Session.scene(ch, false)
    Session.scene(cg, false)
    c:run(1)
    allErrors(c)

    -- The later part is the story's scene: the host's skip of it ends it for both. (The user, 11-19, asked whose
    -- skip ends a scene watched together: "Only the host's".)
    local v, vh, vg = pair()
    crane(vh)
    crane(vg)
    Session.moveTo(vg, 600, 0)
    Session.moveTo(vh, 900, 0)
    v:run(2.5)
    pressE(vg)
    v:run(1)
    pressE(vh)
    v:run(0.5)
    Session.scene(vg, true, "SeqsCrane")
    Session.scene(vh, true, "SeqsCrane")
    v:run(6)
    Session.scene(vg, false)
    Session.scene(vh, false)
    v:run(12)
    Session.scene(vg, true, "SeqsCrane")
    Session.scene(vh, true, "SeqsCrane")
    Fake.put(vg.scene, "posAt", 30)
    Fake.put(vh.scene, "posAt", 30)
    v:run(5)
    Session.scene(vh, false)
    v:run(1)
    check(vh.bellTouches == 1 and count(vh.sent, "^E SCENE skip SeqsCrane$") == 1 and field(vg.scene, "skipped") == 1,
        "the host skips the later part, the story's scene: told, and the guest's ends with it")
    allErrors(v)
    -- One who rings long after their partner watches at the scene's own pace.
    local x, xh, xg = pair()
    crane(xh)
    crane(xg)
    Session.moveTo(xg, 900, 0)
    Session.moveTo(xh, 600, 0)
    x:run(2.5)
    pressE(xh)
    x:run(1.5)
    Session.scene(xh, true, "SeqsCrane")
    x:run(40)
    pressE(xg)
    x:run(0.5)
    Session.scene(xg, true, "SeqsCrane")
    x:run(3)
    check(xg.bellTouches == 1 and rate(xg) == 1 and count(xg.logs, "played a little faster") == 0,
        "one who rings 42 s after their partner watches at the scene's own pace")
    allErrors(x)

    -- A part that ends while it's still played faster: the sequence plays on with the camera back on the player
    -- (the crane's, 22 s between its two parts), at its own speed again. Whichever of the mod's two looks sees the
    -- part's end first: six ends, a twentieth of a second apart. (The first review of 403: the frame's own look, come
    -- first, let the speed stand.)
    local slow, wasFast = 0, 0
    for phase = 0, 5 do
        local y, yh, yg = pair()
        crane(yh)
        crane(yg)
        Session.moveTo(yg, 900, 0)
        Session.moveTo(yh, 600, 0)
        y:run(2.5)
        pressE(yh)
        y:run(1.5)
        Session.scene(yh, true, "SeqsCrane")
        y:run(7.5)
        pressE(yg)
        y:run(0.5)
        Session.scene(yg, true, "SeqsCrane")
        y:run(3 + phase * 0.05)
        wasFast = wasFast + (rate(yg) > 1 and 1 or 0)
        Fake.put(yh.controller, "viewTarget", nil)      -- (the camera back on the players: the part is over,
        Fake.put(yg.controller, "viewTarget", nil)      -- the sequence still playing)
        y:run(1)
        slow = slow + (rate(yg) == 1 and 1 or 0)
        allErrors(y)
    end
    check(wasFast == 6 and slow == 6,
        "a part over while the guest's was still played faster: its sequence, playing on, is at its own speed again ("
            .. slow .. " of 6 ends)")

    -- Three players: two ring together long after the first. They are kept with each other, not sent after the
    -- first, which neither would ever catch. (The first review of 403.)
    local p3 = party(nil, nil, { "Host", "Guest", "Guest" })
    local pa, pb, pd = p3.pcs[1], p3.pcs[2], p3.pcs[3]
    crane(pa)
    crane(pb)
    crane(pd)
    Session.moveTo(pa, 600, 0)
    Session.moveTo(pb, 900, 0)
    Session.moveTo(pd, 900, 200)
    p3:run(2.5)
    pressE(pa)
    p3:run(1.5)
    Session.scene(pa, true, "SeqsCrane")
    p3:run(38)
    pressE(pb)
    p3:run(1)
    pressE(pd)
    Session.scene(pb, true, "SeqsCrane")
    p3:run(1)
    Session.scene(pd, true, "SeqsCrane")
    p3:run(1.5)
    check(rate(pb) == 1 and rate(pd) > 1,
        "three players, two ringing together 40 s after the first: the later of the two is played faster ("
            .. tostring(rate(pd)) .. "), the earlier at its own speed (" .. tostring(rate(pb)) .. ")")
    p3:run(5)
    check(rate(pb) == 1 and rate(pd) == 1 and math.abs(where(pb) - where(pd)) < 0.3,
        "and they are level with each other, neither sent after the first (" .. string.format("%.2f / %.2f", where(pb), where(pd)) .. ")")
    allErrors(p3)

    -- Why not, said once: one left alone for a partner's ring is told why in the log.
    local w, wh, wg = pair()
    wh.groundTraces, wg.groundTraces = true, true
    Session.moveTo(wh, 600, 0)
    wg.env.PBZ.game.inCombat = function() return true end
    net(wg).aimedAt = wg.now + 1000             -- (something of the host's is going for them: a real fight)
    w:run(2)
    pressE(wh)
    w:run(8)
    check(not woken(wg) and count(wg.logs, "first ring of a bell near you: you were in a fight") == 1,
        "one in a fight, left alone for a partner's ring, is told why in the log, once")
    allErrors(w)

    -- A first ring made in the quiet after a link's start, a load or a stall is seen and told all the same (406:
    -- the bench, run236). The scenes' look rests through that quiet, and told only once it was over, 5 s on, the
    -- ring was older than the 3 s a telling allows: the partner beside the bell was never rung for.
    local z, zh, zg = pair()
    zh.groundTraces, zg.groundTraces = true, true
    Session.moveTo(zg, 700, 0)
    Session.moveTo(zh, 600, 0)
    z:run(2)
    net(zh).quietUntil, net(zg).quietUntil = zh.now + 5, zg.now + 5
    pressE(zg)
    z:run(1)
    local toldInIt = count(zg.sent, "^E BELL ring ")
    z:run(7)
    check(toldInIt == 1 and woken(zg) and woken(zh) and zh.bellTouches == 1
        and count(zh.logs, "rung in this world too") == 1,
        "a first ring made in the quiet after a link's start is told at once (" .. toldInIt
            .. "), and the partner beside the bell is rung for once their own quiet is over")
    allErrors(z)

    -- A partner whose game takes no ring just now (busy with something of their own) keeps the bell.
    local r, rh, rg = pair()
    rh.groundTraces, rg.groundTraces = true, true
    Session.moveTo(rg, 1700, 0)
    Session.moveTo(rh, 600, 0)
    rg.busyUsing = true
    r:run(2)
    pressE(rh)
    r:run(1.5)
    check(woken(rh) and not woken(rg) and rg.bellTouches == nil and count(rg.logs, "rung in this world too") == 0
        and count(rg.logs, "took no ring for you just now") == 1,
        "a partner whose game takes no ring just now keeps the bell for their own, and it's said")
    allErrors(r)

    -- Nor is a ring asked over something that partner is using now, the same bell by their own E among it: its walk
    -- up takes 2 s before the first touch, and a ring asked in it was a second one (404: the eleventh review).
    local i, ih, ig = pair()
    ih.groundTraces, ig.groundTraces = true, true
    Session.moveTo(ig, 1700, 0)
    Session.moveTo(ih, 600, 0)
    i:run(2)
    local comp = ig.interactComps[1]
    Fake.put(comp, "InteractingActor", ig.bell)
    pressE(ih)
    i:run(8)
    -- (Nor moved to the ringer's side first, 11 m off: set down and then refused, they were pulled out of what they
    -- were using. 405.)
    check(woken(ih) and not woken(ig) and ig.bellTouches == nil and #field(comp, "used") == 0
        and math.abs(at(ig.pawn).X - 1700) < 1
        and count(ig.logs, "first ring of a bell near you: you were using something") == 1,
        "a partner using something of their own just now is neither moved nor rung for: the game isn't even asked, and it's said")
    allErrors(i)

    -- Left as it was: a partner 50 m off, one whose world has it woken, one in a boss fight of their own, one on
    -- another map, anyone with WatchTogether off.
    local function left(why, before, ini, rungAlready)
        local u, uh, ug = pair(ini)
        uh.groundTraces, ug.groundTraces = true, true
        Session.moveTo(uh, 600, 0)
        if before then
            before(u, uh, ug)
        end
        u:run(2)
        local wx = at(ug.pawn).X
        pressE(uh)
        u:run(1.5)
        check(woken(uh) and (rungAlready or not woken(ug)) and math.abs(at(ug.pawn).X - wx) < 1
            and count(ug.logs, "rung in this world too") == 0, why)
        allErrors(u)
    end
    left("a partner 50 m off keeps the bell for their own first ring", function(_, _, ug)
        Session.moveTo(ug, 5700, 0)
    end)
    left("one whose world has it woken is left as they are", function(_, _, ug)
        Fake.put(ug.bell, "active", true)
        ug.bellIds[#ug.bellIds + 1] = "Bell_Sim_001"
    end, nil, true)
    left("one in a boss fight of their own is left", function(u, _, ug)
        ug.hudLayout:RegisterBossHPBar(Session.enemyOn(ug, "boss"))
        u:run(1)
    end)
    left("one on another map is left", function(u, _, ug)
        ug.map = "Map_Other"
        u:run(2)
    end)
    left("with WatchTogether = Off each player's bells are their own", nil, "WatchTogether = Off\n")
    -- (The eleventh review.)
    left("one held down by Revive is left: no ring heals them", function(_, _, ug)
        ug.env.PBZ.revive.isDown = function() return true end
    end)
    left("one fighting anything is left: the game itself refuses a bell in combat", function(_, _, ug)
        ug.env.PBZ.game.inCombat = function() return true end
        net(ug).aimedAt = ug.now + 1000         -- (something of the host's is going for them: a real fight)
    end)
    left("with no ground behind the ringer in their world, neither set down nor rung", function(_, _, ug)
        Session.moveTo(ug, 1700, 0)
        ug.noFloor = function() return true end
    end)
end

-- 383's fight starting over with the guest still striking, and the host's lines of the boss from before its respawn
-- read after it (the bench, 11-18, run207). The relay keeps every line that came since the last read and a frame takes
-- events before lines, so a guest whose game stood still as the host's hold ended (5.7 s there) handled the host's R,
-- its world's refresh with it, and then read the old lines as news: the body the refresh had just made was written
-- down to the old one's 2. The guest's own fight with it began, the host handed it over, the hold's floor went, and
-- the next blow was the Axe chief's death in the guest's world: his pay to both, "beaten" in the guest's save, no boss
-- there in the host's next fight. A guest's world refreshed by the host's word forgets the host's lines so far now, the
-- ones still waiting too, takes none for half a second more, and a boss isn't let go at the hold's floor as it stands: the
-- host's share where the host says it has more, whole otherwise (394).
local function restartWithOldLines()
    part("the fight starts over, the host's old lines read after it")
    local REFRESH = "/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"
    local function floorOf(e)
        return field(field(e, "AttributeSetBase"), "Health_Min").CurrentValue
    end
    local function hpOf(e)
        return (select(1, Fake.health(e)))
    end
    -- The guest's killing blow stopped at a floor of the host's game's own: 2 in both worlds, the copy held at its floor.
    local function stopped()
        local s, h, g = pair()
        net(h).FINISHER_WAIT_S = 20     -- (383's first wait: finisherWithTheHostDown)
        bossStart(s)
        local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        swing(g, copy, hpOf(copy) - 50)
        s:run(5)
        local min = field(field(boss, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", 1)
        Fake.put(min, "CurrentValue", 1)
        Fake.setHealth(boss, 300)
        s:run(2)
        swing(g, copy, 1)
        s:run(2)
        return s, h, g, boss, copy
    end
    -- (The host's word that the guest's game runs him from now, as the host sends it.)
    local function handedOver(s, h)
        s.relay:post(h, "sure", "RUN sp:boss 1")
        s:run(0.5)
    end

    local s, h, g, boss, copy = stopped()
    local most = select(2, Fake.health(copy))
    Session.die(h)
    h.hudLayout:UnRegisterBossHPBar(boss)
    s:run(6)
    swing(g, copy, 1)
    s:run(23)
    check(hpOf(boss) == 2 and hpOf(copy) <= 2.5 and field(h.deathWidget, "NotTick") ~= true,
        "(the guest's killing blow stopped at his floor, 2 in both worlds; 23 s on the host's hold ends: the fight starts over)")
    -- The host's last lines of him, as a hitch on the guest leaves them waiting: sent before its respawn, read after.
    local old = {}
    for i = #h.sent, math.max(1, #h.sent - 4000), -1 do
        local line = h.sent[i]:match("^N (.+)$")
        local hp = line and line:match("^%d+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+$")
        if hp and tonumber(hp) and tonumber(hp) <= 2.5 then
            old[#old + 1] = line
            if #old >= 8 then
                break
            end
        end
    end
    check(#old > 0, "(the host's lines of him at 2 health, to be read late: " .. #old .. ")")
    -- Each world's refresh makes him whole, as the game's does (the fake's leaves the living as they are).
    local function wholeAtRefresh(pc, e)
        local hooks = pc.hooks[REFRESH]
        hooks[#hooks + 1] = function() Fake.setHealth(e, select(2, Fake.health(e))) end
    end
    wholeAtRefresh(h, boss)
    wholeAtRefresh(g, copy)
    Session.moveTo(h, 90000.0, 0.0)             -- (at its bell again, far off)
    Session.respawned(h)
    Session.revive(h)
    -- (Posted as the host's R goes, half a second on: the relay hands both over together, and the guest's frame takes
    -- the R first.)
    local posted = false
    local function late()
        if not posted and count(h.sent, "^E R death") > 0 then
            posted = true
            for _, line in ipairs(old) do
                s.relay:post(h, "enemy", line)
            end
        end
    end
    s:run(0.7, late)
    check(posted and count(g.logs, "The host died and respawned: enemies respawn here too") == 1,
        "(the host respawns, and the guest's world refreshes with the host's)")
    check(hpOf(copy) == most,
        "the body the guest's refresh made stands whole: the host's lines from before it, read after it, aren't news ("
            .. tostring(hpOf(copy)) .. " of " .. tostring(most) .. ")")
    for _, line in ipairs(old) do
        s.relay:post(h, "enemy", line)          -- (and a late packet's, a moment on)
    end
    s:run(0.15)
    check(hpOf(copy) == most, "nor one that comes a moment later, a late packet's (" .. tostring(hpOf(copy)) .. ")")
    -- (Nor the host's answer to a killing blow told just before its respawn, come after it: LR wrote the new body down
    -- to the 2 the old one had, whether a blow waited for that answer or not. The tenth review.)
    s.relay:post(h, "sure", "LR sp:boss 2.0")
    s:run(0.15)
    check(hpOf(copy) == most, "nor the host's answer to a killing blow told before it, come after it (" .. tostring(hpOf(copy)) .. ")")
    s:run(1.5)
    g.hudLayout:RegisterBossHPBar(copy)         -- (the guest stands in his arena: its own fight with the new body begins)
    s:run(3)
    check(hpOf(copy) == most and floorOf(copy) == 0 and field(copy, "dead") ~= true,
        "the guest's own fight with it begins, the host away at its bell: this game's own, whole as the game made it ("
            .. tostring(hpOf(copy)) .. ", its floor " .. tostring(floorOf(copy)) .. ")")
    swing(g, copy, most - 400)
    s:run(2)
    check(hpOf(copy) == most - 400 and field(copy, "dead") ~= true and count(h.logs, "Shared dust") == 0,
        "and the guest's next blow is a blow, not its death: nothing paid to anyone")
    allErrors(s)

    -- A boss standing at the floor it's held at, handed to the guest's game with no refresh between, the host's own
    -- stopped at a floor of its game's. Not let go as it stands: whole first.
    local t, th, tg, _, tcopy = stopped()
    local tmost = select(2, Fake.health(tcopy))
    check(hpOf(tcopy) <= 2.5 and floorOf(tcopy) == 1, "(the copy at 2, held at its floor)")
    handedOver(t, th)
    check(net(tg).mine["sp:boss"] == true and floorOf(tcopy) == 0, "(handed over: the guest's game runs him, the hold's floor gone)")
    check(hpOf(tcopy) == tmost and count(tg.logs, "was let go at the floor it was held at .*whole again") == 1,
        "handed over at the hold's floor, the host's own at a floor of its game's: whole first, " .. tostring(hpOf(tcopy))
            .. " of " .. tostring(tmost))
    allErrors(t)

    -- The host's boss with more than that floor as it's handed over (healed there a moment ago, its copy not yet): the
    -- copy takes the host's share, what the fight had left, not its most.
    local u, uh, ug, uboss, ucopy = stopped()
    local umost, hostMost = select(2, Fake.health(ucopy)), select(2, Fake.health(uboss))
    Fake.setHealth(uboss, hostMost * 0.4)
    u:run(0.4)
    check(hpOf(ucopy) <= 2.5, "(the host's own healed to two fifths a moment ago: its copy still at the floor)")
    handedOver(u, uh)
    check(net(ug).mine["sp:boss"] == true and math.abs(hpOf(ucopy) - umost * 0.4) < 2
        and count(ug.logs, "was let go at the floor it was held at .*at the host's") == 1,
        "the host's own at two fifths as it's handed over: the copy at two fifths ("
            .. tostring(hpOf(ucopy)) .. " of " .. tostring(umost) .. ")")
    allErrors(u)

    -- Let go with no handover: the host gone from the map's reach, its lines of him run out. Whole too.
    local v, vh, vg, vboss, vcopy = stopped()
    local vmost = select(2, Fake.health(vcopy))
    vh.hudLayout:UnRegisterBossHPBar(vboss)
    Session.moveTo(vh, 90000.0, 0.0)
    v:run(4)
    check(floorOf(vcopy) == 0 and hpOf(vcopy) == vmost and count(vg.logs, "was let go at the floor it was held at .*whole again") == 1,
        "the host's lines of him run out, his copy at the hold's floor: let go whole (" .. tostring(hpOf(vcopy)) .. ")")
    allErrors(v)

    -- The host's half of it (397). A guest's killing blow told as its copy stood at 2, before the host's word of its
    -- respawn reached it, is read by the host after its world has refreshed. By name it was the new body's, whole: the
    -- game's own kill, the fresh boss dead in both worlds, his pay out and "beaten" in the host's save, by one plain
    -- blow (the tenth review's sim; the base did the same). From the host's refresh till half a second after its word
    -- of it has gone a killing blow is a plain one; and whenever it comes, one on a boss with more than half his
    -- health isn't his end (the guest's word of the refresh late, the blow told again).
    local w, wh, wg, wboss, wcopy = stopped()
    Session.die(wh)
    wh.hudLayout:UnRegisterBossHPBar(wboss)
    w:run(6)
    swing(wg, wcopy, 1)
    w:run(23)
    local blow = nil
    for i = #wg.sent, 1, -1 do
        blow = wg.sent[i]:match("^E (D sp:boss %S+ %S+ L.*)$")
        if blow then
            break
        end
    end
    check(blow ~= nil and hpOf(wboss) == 2 and field(wh.deathWidget, "NotTick") ~= true,
        "(the guest's killing blows stopped at his floor, the last " .. tostring(blow) .. "; 23 s on the host's hold ends)")
    -- (The game's new body: whole, and with no lock on its health yet, which comes at a fifth of it.)
    local function newAtRefresh(pc, e)
        local hooks = pc.hooks[REFRESH]
        hooks[#hooks + 1] = function()
            Fake.setHealth(e, select(2, Fake.health(e)))
            local min = field(field(e, "AttributeSetBase"), "Health_Min")
            Fake.put(min, "BaseValue", 0)
            Fake.put(min, "CurrentValue", 0)
        end
    end
    newAtRefresh(wh, wboss)
    newAtRefresh(wg, wcopy)
    local wmost = select(2, Fake.health(wboss))
    Session.moveTo(wh, 90000.0, 0.0)
    Session.respawned(wh)
    Session.revive(wh)
    w.relay:post(wg, "sure", blow)              -- (told as the host's world refreshed, its word of that not yet out)
    local asTold = false
    w:run(0.7, function()
        if not asTold and count(wh.sent, "^E R death") > 0 then
            asTold = true
            w.relay:post(wg, "sure", blow)      -- (and one more as that word goes: the guest hasn't heard it yet)
        end
    end)
    check(asTold and field(wboss, "dead") ~= true and hpOf(wboss) >= wmost * 0.9 and count(wh.sent, "^E K sp:boss$") == 0
        and count(wh.logs, "Beaten in this world too") == 0 and count(wh.logs, "came as this world refreshed") == 2,
        "the guest's killing blows from before the host's respawn, read after it: plain blows, the new body stands ("
            .. tostring(hpOf(wboss)) .. " of " .. tostring(wmost) .. ")")
    w:run(2)
    w.relay:post(wg, "sure", blow)              -- (told again seconds later: the guest's word of the refresh came late)
    w:run(1)
    check(field(wboss, "dead") ~= true and hpOf(wboss) >= wmost * 0.9 and count(wh.sent, "^E K sp:boss$") == 0
        and count(wh.logs, "isn't one here: it has") == 1,
        "nor one told again seconds later: a boss with more than half his health isn't ended by a killing blow ("
            .. tostring(hpOf(wboss)) .. ")")
    -- (Nor long after: a guest's link quiet for longer than any window, its blows at the old one's floor sent as it
    -- came back. By the blow, not by a clock from the refresh: REVIEW-10.)
    w:run(14)
    for _ = 1, 3 do
        w.relay:post(wg, "sure", blow)
    end
    w:run(1)
    check(field(wboss, "dead") ~= true and hpOf(wboss) >= wmost * 0.9 and count(wh.sent, "^E K sp:boss$") == 0
        and count(wh.logs, "Beaten in this world too") == 0,
        "nor ones that come a quarter of a minute on, held by a quiet link: the whole boss stands (" .. tostring(hpOf(wboss)) .. ")")
    allErrors(w)

    -- Any enemy's, in that half second (a thug's by the host's bell); and past it a killing blow is one, as ever.
    local x, xh, xg = pair()
    local thug = Session.enemyOn(xh, "near")
    Session.bell(xh)
    x:run(0.6)
    check(count(xh.sent, "^E R ") == 1 and field(thug, "dead") ~= true, "(the host rests: its word of the refresh has gone)")
    x.relay:post(xg, "sure", "D sp:near 0.0 0.0 L")
    x:run(0.2)
    check(field(thug, "dead") ~= true and count(xh.logs, "came as this world refreshed") == 1,
        "a killing blow read in the half second after the host's word of its rest: a plain blow")
    x:run(1.0)
    x.relay:post(xg, "sure", "D sp:near 0.0 0.0 L")
    x:run(0.5)
    check(field(thug, "dead") == true and count(xh.sent, "^E K sp:near$") == 1, "one read past it: its death, told")
    allErrors(x)

    -- A killing blow told in a gap of the guest's link (404: the tenth review's run-checkers, and the review of 401).
    -- No refresh at all. The host down and held, the boss at a tenth; the guest's link goes quiet, its game runs on,
    -- and it brings its copy to its floor, lifted back to the host's last line each second: plain blows and killing
    -- blows wait in the relay. With the guest's figure silent the host's game makes its boss whole again by itself
    -- (the bench, run223), here a twentieth of his health a second from 3 s in. The link back after 9 s, the boss at
    -- two fifths: under the half where the rule by the blow holds, and the first killing blow read was his end.
    local q, qh, qg = pair()
    bossStart(q)
    local qboss, qcopy = Session.enemyOn(qh, "boss"), Session.enemyOn(qg, "boss")
    local qmost = select(2, Fake.health(qboss))
    swing(qg, qcopy, hpOf(qcopy) - 50)
    q:run(5)
    Session.die(qh)
    qh.hudLayout:UnRegisterBossHPBar(qboss)
    q:run(6)
    Fake.setHealth(qboss, qmost * 0.1)
    q:run(3)
    check(field(qh.deathWidget, "NotTick") == true and math.abs(hpOf(qcopy) - qmost * 0.1) < 1,
        "(the host down and held in the guest's fight, the boss at a tenth in both worlds)")
    qg.sent = {}
    local press, heal = qh.now + 0.3, qh.now + 3.0
    qg.cut = true
    q:run(9, function()
        if qh.now >= press then
            press = qh.now + 0.5
            if hpOf(qcopy) > 1.01 then
                swing(qg, qcopy, math.max(1, hpOf(qcopy) - 150))
            end
        end
        if qh.now >= heal then
            heal = qh.now + 0.5
            Fake.setHealth(qboss, math.min(qmost, hpOf(qboss) + qmost * 0.025))
        end
    end)
    local qtold, qback = count(qg.sent, "^E D sp:boss %S+ %S+ L"), hpOf(qboss)
    qg.cut = false
    q:run(3)
    check(qtold >= 2 and qback < qmost / 2 and field(qboss, "dead") ~= true and count(qh.sent, "^E K sp:boss$") == 0
        and count(qh.logs, "Beaten in this world too") == 0 and count(qh.logs, "was told in a gap of theirs") >= 2,
        "killing blows told in a 9 s gap of the guest's link, the host's game having healed its boss meanwhile ("
            .. string.format("%.0f of %.0f", qback, qmost) .. " as the link came back, " .. qtold
            .. " waiting): plain blows, he stands (" .. string.format("%.0f", hpOf(qboss)) .. ")")
    check(count(qh.sent, "^E LR sp:boss ") >= 1 and net(qg).lethalPending["sp:boss"] == nil
        and math.abs(hpOf(qcopy) - hpOf(qboss)) < 1,
        "each is answered with what he has there: the guest's game tells none again, and its copy takes that ("
            .. string.format("%.0f", hpOf(qcopy)) .. ")")
    swing(qg, qcopy, 1)
    q:run(2)
    check(field(qboss, "dead") == true and count(qh.sent, "^E K sp:boss$") == 1,
        "and the next killing blow, struck with the link up, is his end")
    allErrors(q)

    -- The gap that ends the host's hold. The host down and held, the boss low; the guest's link quiet for 18 s. At
    -- 12 s the host takes the guest for gone, its hold lets go, it respawns by the arena and its world refreshes: a
    -- new body, whole. The guest's queue of that gap, read as the link comes back: its plain blows took the new body
    -- under half, and a killing blow struck at the old one's floor was then the new one's end. None of it is taken:
    -- all of it was struck at the body that's gone. What the guest strikes once it has heard of the refresh is.
    local o, oh, og = pair()
    bossStart(o)
    local oboss, ocopy = Session.enemyOn(oh, "boss"), Session.enemyOn(og, "boss")
    local omost = select(2, Fake.health(oboss))
    swing(og, ocopy, hpOf(ocopy) - 50)
    o:run(5)
    Fake.setHealth(oboss, 900)
    o:run(2)
    Session.die(oh)
    oh.hudLayout:UnRegisterBossHPBar(oboss)
    o:run(6)
    newAtRefresh(oh, oboss)
    newAtRefresh(og, ocopy)
    og.sent = {}
    local nextAt, letGoAt, respawned, rAt = 0, nil, false, nil
    og.cut = true
    o:run(18, function()
        if og.now >= nextAt then
            nextAt = og.now + 0.5
            if hpOf(ocopy) > 1.5 then
                swing(og, ocopy, math.max(1, hpOf(ocopy) - 250))
            end
        end
        if not letGoAt and field(oh.deathWidget, "NotTick") ~= true then
            letGoAt = oh.now
        end
        if letGoAt and not respawned and oh.now >= letGoAt + 2.0 then
            respawned = true
            Session.moveTo(oh, 2200.0, 2200.0)      -- (its bell, 11 m from the boss: the new body is in its reach)
            Session.respawned(oh)
            Session.revive(oh)
        end
        rAt = rAt or (count(oh.sent, "^E R death") > 0 and oh.now or nil)
    end)
    local otold, onew = count(og.sent, "^E D sp:boss %S+ %S+ L"), hpOf(oboss)
    og.cut = false
    o:run(1.5)
    check(rAt ~= nil and onew == omost and otold >= 2 and field(oboss, "dead") ~= true
        and count(oh.sent, "^E K sp:boss$") == 0 and count(oh.logs, "Beaten in this world too") == 0,
        "killing blows told in an 18 s gap, the host's hold let go and its world refreshed inside it (" .. otold
            .. " waiting): the new body isn't ended by the old one's (" .. string.format("%.0f of %.0f", hpOf(oboss), omost) .. ")")
    check(hpOf(oboss) == omost and count(oh.logs, "this world refreshed meanwhile, is of what's gone") == 1,
        "nor does it take the plain blows of that gap, struck at the old one: whole, and said once ("
            .. string.format("%.0f of %.0f", hpOf(oboss), omost) .. ")")
    o:run(1)
    local ohad = hpOf(ocopy)
    swing(og, ocopy, ohad - 250)
    o:run(1)
    check(ohad == omost and hpOf(oboss) == omost - 250,
        "a blow the guest strikes after it has heard of the refresh, its copy whole too, is taken ("
            .. string.format("%.0f", hpOf(oboss)) .. ")")
    allErrors(o)

    -- Not a hiccup: a killing blow told 0.6 s into a gap of 2.5 s is his end as the link comes back.
    local c, ch, cg = pair()
    bossStart(c)
    local cboss, ccopy = Session.enemyOn(ch, "boss"), Session.enemyOn(cg, "boss")
    swing(cg, ccopy, hpOf(ccopy) - 50)
    c:run(3)
    Fake.setHealth(cboss, 300)
    c:run(3)
    local cutAt, fellAt = ch.now, nil
    cg.cut = true
    c:run(0.6)
    swing(cg, ccopy, 1)
    c:run(1.9)
    cg.cut = false
    c:run(3, function()
        fellAt = fellAt or (field(cboss, "dead") == true and ch.now or nil)
    end)
    check(fellAt ~= nil and fellAt - cutAt < 3.5 and count(ch.logs, "was told in a gap of theirs") == 0,
        "a killing blow across a hiccup of 2.5 s still lands as the link comes back ("
            .. (fellAt and string.format("%.1f s after it began", fellAt - cutAt) or "never") .. ")")
    allErrors(c)

    -- The host's answer to a killing blow, read after the copy was let go by another way than a refresh: the host
    -- up at a boss its game holds at a floor of its own walks off, its lines of him run out, and the copy stands whole
    -- again, this game's own. An answer still on its way put that copy at 2 with no floor: the next blow was his
    -- death in the guest's world alone (the tenth review's V6). The blow is struck a few frames before the release
    -- (found by a first run), at each of several: none leaves the copy low.
    local function walksOff(off, relFrame)
        local s, h, g, _, copy = stopped()
        local from, frame, rel, swung = #g.logs, 0, nil, false
        Session.moveTo(h, 90000.0, 0.0)
        s:run(4.0, function()
            frame = frame + 1
            if not rel then
                for i = from + 1, #g.logs do
                    rel = rel or (g.logs[i]:find("was let go at the floor it was held at", 1, true) and frame or nil)
                end
            end
            if relFrame and not swung and frame >= relFrame - off then
                swung = true
                swing(g, copy, 1)
            end
        end)
        local written = 0
        for i = from + 1, #g.logs do
            written = written + (g.logs[i]:find("The host didn't take the killing blow on sp:boss", 1, true) and 1 or 0)
        end
        local before = hpOf(copy)
        if relFrame then
            swing(g, copy, math.max(0, hpOf(copy) - 400))
            s:run(1.5)
        end
        return { s = s, rel = rel, before = before, written = written, dead = g.env.PBZ.game.isDead(copy) == true,
            gk = count(g.sent, "^E GK sp:boss") }
    end
    local dry = walksOff(0, nil)
    local low, tried = nil, 0
    if dry.rel then
        for off = 1, 10 do
            local r = walksOff(off, dry.rel)
            tried = tried + 1
            if r.dead or r.gk > 0 or r.before < most * 0.9 then
                low = low or string.format("a blow %d frames before the release: copy %.0f, dead %s, GK %d, answers written %d",
                    off, r.before, tostring(r.dead), r.gk, r.written)
            end
            allErrors(r.s)
        end
    end
    check(dry.rel ~= nil and tried == 10 and low == nil,
        "the host's answer to a killing blow, read after his copy was let go whole, isn't written on it: no death by the next blow ("
            .. tostring(low or "none in 10 timings") .. ")")
end

-- The ninth review (d0412af..50221b8, 383-386): what it found, each with a check of its own.
local function ninthReview()
    part("the ninth review")
    local function attr(e, name)
        return rawget(e, "__fields").AttributeSetBase[name]
    end
    local function put(e, name, v)
        Fake.put(attr(e, name), "CurrentValue", v)
        Fake.put(attr(e, name), "BaseValue", v)
    end
    local function hpOf(e)
        return (select(1, Fake.health(e)))
    end
    local function mostOf(e)
        return (select(2, Fake.health(e)))
    end
    local function held(pc)
        return field(pc.deathWidget, "NotTick") == true
    end
    -- The host down at a boss only its own player can finish: the boss at a floor of its game's own, a partner's killing
    -- blow not taken there.
    local function downAtItsFloor(s, h, boss, striker, copy)
        net(h).FINISHER_WAIT_S, net(h).FINISHER_TELL_AFTER_S = 20, 1e9      -- (383's first wait: finisherWithTheHostDown)
        Session.die(h)
        h.hudLayout:UnRegisterBossHPBar(boss)
        s:run(6)
        local min = field(field(boss, "AttributeSetBase"), "Health_Min")
        Fake.put(min, "BaseValue", 1)
        Fake.put(min, "CurrentValue", 1)
        Fake.setHealth(boss, 300)
        s:run(2)
        h.sent = {}
        swing(striker, copy, 1)
        s:run(1)
    end

    -- V1 (383 in a party): another player in a boss fight of their own on this map. The host's respawn would refresh the
    -- world under it (a host's death is everyone's), so the hold waits for that fight, as before 383, and ends 20 s after
    -- it's over.
    do
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest" }, true, {
            { "thug1", THUG, 1500.0, 300.0, 100.0, 600, 100 },
            { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
            { "boss2", "BP_Monster_Boss_C", 25000.0, 0.0, 100.0, 5000, 400, true },
        })
        s:run(4)
        local h, a, b = s.pcs[1], s.pcs[2], s.pcs[3]
        Session.moveTo(h, 0, 0)
        Session.moveTo(a, 500, 0)
        Session.moveTo(b, 24500, 0)
        s:run(3)
        local bossH, copyA, boss2 = Session.enemyOn(h, "boss"), Session.enemyOn(a, "boss"), Session.enemyOn(b, "boss2")
        h.hudLayout:RegisterBossHPBar(bossH)
        s:run(2)
        swing(a, copyA, hpOf(copyA) - 50)
        b.hudLayout:RegisterBossHPBar(boss2)
        s:run(1)
        swing(b, boss2, hpOf(boss2) - 50)
        s:run(5)
        downAtItsFloor(s, h, bossH, a, copyA)
        s:run(26)
        check(held(h) and count(h.sent, "^E FN ") == 0 and count(b.logs, "finishing move") == 0
            and b.env.PBZ.game.bossFightActive(),
            "V1: in a party the host's hold waits while another player's own boss fight is on: nothing told, their fight goes on")
        Fake.setHealth(boss2, 0)
        Fake.put(boss2, "dead", true)
        s:run(1)
        b.hudLayout:UnRegisterBossHPBar(boss2)
        local wonAt, freeAt = h.now, nil
        s:run(40, function()
            freeAt = freeAt or (not held(h) and h.now) or nil
        end)
        check(freeAt ~= nil and freeAt - wonAt >= 18 and freeAt - wonAt <= 28 and count(h.sent, "^E FN sp:boss$") == 1,
            string.format("and once that fight is over the hold ends 20 s on, as 383 has it: %s s, told once",
                freeAt and string.format("%.1f", freeAt - wonAt) or "never"))
        allErrors(s)
    end

    -- V2 (383's two tips): each has the one tip bar for its four seconds, and the respawn's own tips (a partner far off,
    -- a partner back) come after it. On the bench they took the bar from it within half a second.
    do
        local s, h, g = pair()
        bossStart(s)
        local boss, copy = Session.enemyOn(h, "boss"), Session.enemyOn(g, "boss")
        swing(g, copy, hpOf(copy) - 50)
        s:run(5)
        downAtItsFloor(s, h, boss, g, copy)
        local function bar(pc)
            local shown
            for _, w in ipairs(pc.widgets) do
                local text = field(w, "lastText")
                if text and text:find("Phantom Pact: ", 1, true) then
                    shown = (field(w, "visibility") == 3) and text or false
                end
            end
            return shown or nil
        end
        local HOST = "Phantom Pact: nobody made this boss's finishing move: the fight starts over."
        local GUEST = HOST
        local endedAt, step, upH, upG, after = nil, 0, 0, 0, nil
        s:run(40, function()
            if endedAt == nil and not held(h) then
                endedAt = h.now
            end
            if not endedAt then
                return
            end
            -- (The game's respawn as the bench had it: the host at its bell 400 m off, on its feet, then "you died as host".)
            local since = h.now - endedAt
            if step == 0 and since >= 0.04 then
                step = 1
                Session.moveTo(h, 40000, 0)
            elseif step == 1 and since >= 0.11 then
                step = 2
                Session.revive(h)
            elseif step == 2 and since >= 0.65 then
                step = 3
                Session.respawned(h)
            end
            upH = upH + (bar(h) == HOST and 1 / 60 or 0)
            upG = upG + (bar(g) == GUEST and 1 / 60 or 0)
            local now = bar(h)
            if upH > 0 and now and now ~= HOST then
                after = after or now
            end
        end)
        check(endedAt ~= nil and upH >= 3.9 and upG >= 3.9,
            string.format("V2: 383's word has the tip bar its four seconds on each side: %.2f s on the host's, %.2f s on the guest's", upH, upG))
        check(after ~= nil and after:find("your partner is ", 1, true) ~= nil,
            "and the respawn's own tip comes after it, not over it: " .. tostring(after))
        allErrors(s)
    end

    -- V3 (385): a body made at a dead body's address (addresses come back). Its line's record held the dead one's name,
    -- so its game's cut at the host's first blow wasn't weighed and it was kept whole, the guest's blows undone.
    do
        local OWN = 600
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "addA", THUG, 3000.0, 3000.0, 100.0, OWN, 100 } })
        local h, g = s.pcs[1], s.pcs[2]
        -- (A blow as its game makes one on a body it holds to its own health: over it, cut to it; else the blow.)
        local function blow(pc, e, d)
            pc.env.PBZ.game.noteLocalMove()
            if hpOf(e) > OWN + 0.01 then
                put(e, "Health", OWN)
                put(e, "Health_Max", OWN)
            else
                Fake.setHealth(e, hpOf(e) - d)
            end
        end
        s:run(4)
        Session.moveTo(h, 2800, 2900)
        Session.moveTo(g, 3200, 3100)
        s:run(6)
        local aH = Session.enemyOn(h, "addA")
        blow(h, aH, 90)                 -- (the host's first: its game's cut, kept at 600)
        s:run(3)
        Fake.put(aH, "dead", true)
        Fake.setHealth(aH, 0)
        s:run(2)
        local addrA = aH:GetAddress()
        rawset(aH, "__fields", setmetatable({}, { __index = rawget(aH, "__fields") }))
        rawget(aH, "__fields").AttributeSetBase = false         -- (destroyed: no attributes, still listed)
        s:run(3)
        for _, pc in ipairs(s.pcs) do
            local e = Session.enemyOn(pc, "addA")
            for i = #pc.enemies, 1, -1 do
                if pc.enemies[i] == e then
                    table.remove(pc.enemies, i)
                end
            end
            rawset(e, "__alive", false)
        end
        local bH = Fake.enemy(h, "addB", THUG, 3000.0, 3000.0, 100.0, OWN, 100)
        rawset(bH, "__addr", addrA)
        local bG = Fake.enemy(g, "addB", THUG, 3000.0, 3000.0, 100.0, OWN, 100)
        s:run(6)
        local most = mostOf(bH)
        for _ = 1, 4 do
            blow(g, bG, 90)
            s:run(1)
        end
        local had = hpOf(bH)
        blow(h, bH, 90)
        s:run(3)
        local want = OWN * had / most
        check(bH:GetAddress() == addrA and had == most - 270 and mostOf(bH) == OWN and math.abs(hpOf(bH) - want) < 0.01,
            string.format("V3: a body made at a dead one's address keeps its share at the host's first blow: %.1f of %.0f, it had %.1f of %.0f (%.1f)",
                hpOf(bH), mostOf(bH), had, most, want))
        allErrors(s)
    end

    -- V4 (385, CoopEnemyPosture 100): a worn body out of both players' reach, the difficulty picked lower in the game's
    -- menu and raised again by the mod: the game writes its numbers again each time. With its guard bar its game's own
    -- that looked like its game's cut, and it was kept at a share of a share.
    do
        local BASE = { [2] = 500, [3] = 600 }
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, { { "add", THUG, 3000.0, 3000.0, 100.0, 600, 100 } },
            "CoopEnemyPosture = 100\nCoopBossPosture = 200\n")
        local h, g = s.pcs[1], s.pcs[2]
        local onH = Session.enemyOn(h, "add")
        local function switch(mode)
            h.difficulty = mode
            local share = hpOf(onH) / mostOf(onH)
            put(onH, "Health_Max", BASE[mode])
            put(onH, "Health", BASE[mode] * share)
            put(onH, "Shachi_Max", 100)
            put(onH, "Shachi", 100)
        end
        put(onH, "Health_Max", BASE[h.difficulty])
        put(onH, "Health", BASE[h.difficulty])
        Fake.put(h.gameSystem, "SetDifficultMode", function(_, mode) switch(mode) end)
        s:run(4)
        Session.moveTo(h, 2800, 2900)
        Session.moveTo(g, 3200, 3100)
        s:run(8)
        while hpOf(onH) > 300.5 do
            h.env.PBZ.game.noteLocalMove()
            Fake.setHealth(onH, math.max(300, hpOf(onH) - 100))
            s:run(1)
        end
        s:run(2)
        local had = hpOf(onH)
        Session.moveTo(h, 12000, 3000)
        Session.moveTo(g, 12500, 3000)
        s:run(3)
        local said = count(h.logs, "holds no more than its own health")
        switch(2)                       -- (the player's lower pick in the menu)
        s:run(6)
        local capped = count(h.logs, "holds no more than its own health") > said
        local stands = capped and hpOf(onH) * 1.5 or hpOf(onH)
        check(had == 300 and math.abs(stands - had) < 1,
            string.format("V4: with CoopEnemyPosture 100, a worn body whose numbers the game writes again stands for what it had: %.1f of %.0f%s, for %.0f (it had %.0f)",
                hpOf(onH), mostOf(onH), capped and ", kept as a cut" or "", stands, had))
        allErrors(s)
    end

    -- V5 (385's guard lift): the host's bar over a copy's own most (the host's CoopEnemyPosture 160 against the guest's
    -- 130). The copy's most was read every turn of every such copy; it's read as a lift is due, and a copy found at its
    -- most is left be till its bar moves.
    do
        local list = {}
        for i = 1, 6 do
            local turn = 2 * math.pi * i / 6
            list[#list + 1] = { "t" .. i, THUG, 400 * math.cos(turn), 400 * math.sin(turn), 100.0, 60000, 100 }
        end
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, list, nil, nil, function(pc, i)
            if i == 1 then
                pc.files["PhantomPact.ini"] = pc.files["PhantomPact.ini"]:gsub("CoopEnemyPosture = 130", "CoopEnemyPosture = 160")
            end
        end)
        local h, g = s.pcs[1], s.pcs[2]
        local game, reads = g.env.PBZ.game, 0
        local most = game.postureMax
        game.postureMax = function(actor)
            reads = reads + 1
            return most(actor)
        end
        Session.moveTo(h, 150, 0)
        Session.moveTo(g, 300, 0)
        s:run(12)
        local over = 0
        for i = 1, 6 do
            local onH, onG = Session.enemyOn(h, "t" .. i), Session.enemyOn(g, "t" .. i)
            if attr(onH, "Shachi").CurrentValue > attr(onG, "Shachi_Max").CurrentValue + 0.5 then
                over = over + 1
            end
        end
        local before = reads
        s:run(10)
        check(over == 6 and (reads - before) / 600 < 0.05,
            string.format("V5: the host's bar over six copies' own most: their most is read %.2f times a frame, not every turn of each", (reads - before) / 600))
        -- (And a blow on such a copy is still put right a full second on, never sooner: the wait HEAL_TICKS is for. The
        -- host's bar, over the copy's most before the blow, stands under it after: the copy is lifted to the host's.)
        local onH, onG = Session.enemyOn(h, "t1"), Session.enemyOn(g, "t1")
        local full = attr(onG, "Shachi").CurrentValue
        g.env.PBZ.game.noteLocalMove()
        Fake.put(attr(onG, "Shachi"), "CurrentValue", full - 40)
        local struckAt, liftedAt = g.now, nil
        s:run(3, function()
            liftedAt = liftedAt or (attr(onG, "Shachi").CurrentValue > full - 39.5 and g.now) or nil
        end)
        local hosts, copys = attr(onH, "Shachi").CurrentValue, attr(onG, "Shachi").CurrentValue
        check(liftedAt ~= nil and liftedAt - struckAt >= 0.95 and liftedAt - struckAt <= 1.3 and math.abs(copys - math.min(hosts, full)) < 0.5,
            string.format("and a blow of the guest's on one is put right a full second on, never sooner: %s s, the copy at %.0f, the host's at %.0f",
                liftedAt and string.format("%.2f", liftedAt - struckAt) or "never", copys, hosts))
        allErrors(s)
    end
end

-- The play log (playlog.lua): this session's own file of every line the mod says, how the game stands every few seconds,
-- what changed in between, UE4SS.log's own lines worth having, and the player's mark. (The user, 11-18: "put something
-- that will track everything during my play like a log that will be useful to you to find issues and fix them".)
local function thePlayLog()
    part("the play log")
    -- This session's file (its last part), as far as it's written.
    local function logOf(pc)
        local best
        for name in pairs(pc.writing) do
            if name:find("^playlog%-%d+%-%d+[%-%d]*%.txt$") and (not best or #name > #best or (#name == #best and name > best)) then
                best = name
            end
        end
        return best and Fake.fileText(pc, best) or "", best
    end
    local function has(text, what)
        return text:find(what, 1, true) ~= nil
    end
    local old = {}
    for i = 1, 12 do
        old[i] = string.format("playlog-202611%02d-101010.txt", i)
    end
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "Secret = four random words here\n", nil, function(pc, i)
        if i == 1 then
            -- Twelve sessions kept already, a line in their list that's no file of the log's, and UE4SS.log as it stands.
            for _, name in ipairs(old) do
                pc.files[name] = "an old session\n"
            end
            pc.files["playlog-index.txt"] = "../../PhantomPact.ini\n" .. table.concat(old, "\n") .. "\n"
            pc.files["UE4SS.log"] = table.concat({
                "[2026-11-18 12:11:09.9915300] UE4SS - v3.0.1 Beta #0 - Git SHA #cdbc0b66c",
                "[2026-11-18 12:11:09.9964421] Starting Lua mod 'SomeOtherMod'",
                "[2026-11-18 12:11:10.1000000] [RegisterHook] Registered native hook (25, 26) for Function /Script/X.Y:Z",
                "[2026-11-18 12:11:10.2000000] FArchiveState::ArIsError = 0x29",
                "[2026-11-18 12:11:11.9741894] [Lua] [PBZCoop] Loaded, as UE4SS.log has it.",
                "[2026-11-18 12:11:12.5000000] [Lua] Error: attempt to index a nil value (field 'x')",
                "stack traceback:",
                "        [C]: in ?",
                "[2026-11-18 12:11:13.0000000] [Lua] [PBZCoop#2] a line of the other copy's",
                "half a line with no end",
            }, "\n")
        end
    end)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(2)
    local text, name = logOf(h)
    check(name ~= nil and has(text, "Phantom Pact play log, begun ") and has(text, "Version " .. tostring(h.env.PBZ.net and s.relay.version))
        and h.env.PBZ.playlog and h.env.PBZ.playlog.on == true,
        "a session's own file begins with what it is and the version: " .. tostring(name))
    check(has(text, "PhantomPact.ini: ") and has(text, "role=Host") and has(text, "secret=(set)") and has(text, "hostaddress=(set)")
        and not has(text, "four random words") and not has(text, "10.0.0.1"),
        "the settings are in it, the Secret and the host's address as set, never what they are")
    -- Every line the mod said is in it (those with an address or a Windows user's folder, without: looked at below).
    local missing, lines = 0, 0
    for _, said in ipairs(h.logs) do
        local msg = said:gsub("^%[PBZCoop[^%]]*%] ", ""):gsub("\n+$", "")
        if not msg:find("%d+%.%d+%.%d+%.%d+") and not msg:find("Users", 1, true) and not msg:find("\n", 1, true) then
            lines = lines + 1
            if not has(text, msg) then
                missing = missing + 1
            end
        end
    end
    check(lines > 5 and missing == 0, string.format("every line the mod said is in it: %d of %d missing", missing, lines))
    check(text:find("\n%d%d:%d%d:%d%d +%d+%.%d%d  Loaded %(instance") ~= nil, "each with the time of day and the seconds since the log began")
    check(h.files[old[1]] == nil and h.files[old[2]] ~= nil and h.files["PhantomPact.ini"] ~= nil
        and has(h.files["playlog-index.txt"], name) and not has(h.files["playlog-index.txt"], "PhantomPact.ini")
        and select(2, h.files["playlog-index.txt"]:gsub("\n", "\n")) == 12,
        "the newest twelve are kept: the oldest is deleted, and a line of the list that's no file of the log's is dropped, not deleted")
    -- No addresses.
    h.env.PBZ.log("Connected to 203.0.113.7, by Tailscale 100.101.5.6, at home 192.168.1.20, here 127.0.0.1; ID 76561198000000001; files in C:/Users/Someone/Games/x and D:\\Users\\Someone Else\\y")
    h.env.PBZ.log("Relay started as guest, joining A Friend Of Mine over Steam.")
    h.env.PBZ.log("Relay started as guest, joining hosts-pc.some-tailnet.ts.net on UDP 47800.")
    text = logOf(h)
    check(has(text, "Connected to <internet address>, by Tailscale <Tailscale address>, at home <home network address>, here <this PC's address>; ID <Steam ID>; files in C:/Users/<user>/Games/x and D:\\Users\\<user>\\y")
        and has(text, "joining <a Steam friend> over Steam.") and has(text, "joining <the host> on UDP 47800.")
        and not has(text, "203.0") and not has(text, "7656119") and not has(text, "Someone") and not has(text, "Friend Of Mine") and not has(text, "tailnet")
        and has(text, "Loaded (instance 1, v") and text:find("files in [^\n]-Users/<user>/") ~= nil,
        "an address is written as its kind of network; a Steam ID, a Windows user and a friend's name not at all")
    check(count(h.logs, "203%.0%.113%.7") == 1, "(UE4SS.log's own line is the mod's as it said it)")
    -- No names: a partner's Steam name in the relay's own line and the panel's, a host's name, a user's folder in any case
    -- and a Linux login's. (Players attach the file to public reports: the play log's own review.)
    h.env.PBZ.log("role=client via=steam connected=yes peer=Some Friend Name rtt_ms=31 route=relay route_ping_ms=-")
    h.env.PBZ.log("role=host via=steam connected=no peer=- rtt_ms=- route=-")
    h.env.PBZ.log("role=client via=steam connected=yes peer=76561198000000002 rtt_ms=31 route=relay")
    h.env.PBZ.log("Status: Connected to Some Friend Name. Ping 40 ms. Route: relay.")
    h.env.PBZ.log("Connected to Some Friend Name.")
    h.env.PBZ.log("Looking for Some Friend Name...")
    h.env.PBZ.log("Looking for a Steam friend who's hosting...")
    h.env.PBZ.log("Host address set to hosts-pc.some-tailnet.ts.net.")
    h.env.PBZ.log("Couldn't start: couldn't find the host address hosts-pc")
    h.env.PBZ.log("files in c:\\users\\somebody\\x and Z:\\home\\somebody\\.steam\\y and /run/media/somebody/games/z")
    text = logOf(h)
    check(has(text, " peer=<a Steam friend> rtt_ms=31 route=relay route_ping_ms=-") and has(text, "connected=no peer=- rtt_ms=- route=-")
        and has(text, " peer=<Steam ID> rtt_ms=31") and has(text, "Connected to <the partner>. Ping 40 ms. Route: relay.")
        and has(text, "  Connected to <the partner>.\n") and has(text, "Looking for <the host>...")
        and has(text, "Looking for a Steam friend who's hosting...") and has(text, "Host address set to <the host>.")
        and has(text, "couldn't find the host address <the host>")
        and has(text, "files in c:\\users\\<user>\\x and Z:\\home\\<user>\\.steam\\y and /run/media/<user>/games/z")
        and not has(text, "Some Friend") and not has(text, "somebody") and not has(text, "hosts-pc") and not has(text, "tailnet"),
        "nor a partner's Steam name, a host's name, a user's folder in any case, a Linux login")
    -- A name can begin with "<" ("<3 Sakura", a clan's "<WB> Kenji"), or with digits an address's rule rewrote: taken
    -- for one of the mask's own words, it was written as it is (the tenth review). The relay writes a name's spaces
    -- as _. An address's kind and "<Steam ID>" are still left as they are.
    h.env.PBZ.log("role=client via=steam connected=yes peer=<3_Sakura rtt_ms=31 route=relay")
    h.env.PBZ.log("role=client via=steam connected=yes peer=1.2.3.4Aiko rtt_ms=32 route=relay")
    h.env.PBZ.log("Online panel: Connected to <WB>_Kenji. Ping 41 ms. Route: relay.")
    h.env.PBZ.log("Online panel: Connected to <Clan>Bob.")
    h.env.PBZ.log("Online panel: Connected to 192.168.1.20. Ping 3 ms.")
    h.env.PBZ.log("Online panel: Connected to 76561198000000003.")
    text = logOf(h)
    check(not has(text, "Sakura") and not has(text, "Aiko") and not has(text, "Kenji") and not has(text, "Bob")
        and has(text, " peer=<a Steam friend> rtt_ms=31 route=relay\n") and has(text, " peer=<a Steam friend> rtt_ms=32 route=relay\n")
        and has(text, "Connected to <the partner>. Ping 41 ms. Route: relay.") and has(text, "Online panel: Connected to <the partner>.\n")
        and has(text, "Connected to <home network address>. Ping 3 ms.") and has(text, "Online panel: Connected to <Steam ID>.\n"),
        "nor a partner's name that begins with \"<\", or with an address: only the mask's own words are left as they are")
    -- How the game stands, every ten seconds.
    s:run(11)
    text = logOf(h)
    local fps = tonumber(text:match("STATE (%d+) frames a second"))
    check(fps and fps >= 55 and fps <= 65 and has(text, "| map Map_Xigu at 0 0 ") and has(text, "| health 1000 of 1000")
        and has(text, "| co-op host, partners heard 1 of 1,") and has(text, "| relay "),
        "every ten seconds a line on how the game stands: frames a second (" .. tostring(fps) .. "), the map and the place, health, the link")
    check(text:find("the mod [%d%.]+ ms a second %(most in %a+, [%d%.]+; its longest step %a+, [%d%.]+ ms%)") ~= nil
        and text:find("| this log [%d%.]+ ms a second |") ~= nil,
        "with the mod's own time on the game thread, where most of it went, and what this log itself costs")
    local guests = logOf(g)
    check(has(guests, "| co-op guest, partners heard 1 of 1,") and has(guests, "role=Guest"), "the guest's PC keeps its own")
    -- What changed in between.
    check(has(text, "PLAY the player is in the world.") and has(text, "PLAY map - -> Map_Xigu"), "the world come into, and its map")
    Session.die(h)
    s:run(1.5)
    Session.revive(h)
    s:run(1.5)
    h.map = "Map_Other"
    s:run(1.5)
    h.map = "Map_Xigu"
    Fake.frame(h, 2.0)
    s:run(1.5)
    text = logOf(h)
    check(has(text, "PLAY the player is down, at 0 0 ") and has(text, "PLAY the player is up again, at 0 0 ")
        and has(text, "PLAY map Map_Xigu -> Map_Other") and has(text, "PLAY a frame took 2.0"),
        "then what changes: down and up again, another map, a frame that took two seconds")
    check(text:find("PLAY the player is down, at 0 0 [^\n]*\n[^\n]*SNAP on the screen: none of the game's screens\n[^\n]*SNAP the player: movement mode [^\n]*\n[^\n]*SNAP enemies within 40 m: sp:%a+ at %d+ m, health %d+ of %d+; sp:") ~= nil,
        "as the player goes down, the whole picture: the screens that are up, the body, the enemies near with their health")
    -- A scene, by the log's own look at the game's sequence manager: the mod's own look keeps its turn.
    Session.scene(h, true, "Seq023")
    s:run(6.5)
    local sawIt = h.env.PBZ.game.sequenceOn()
    Session.scene(h, false)
    s:run(1.5)
    text = logOf(h)
    check(has(text, "PLAY a scene begins: Seq023.") and text:find("PLAY the scene is over %([%d%.]+ s%)%.") ~= nil and sawIt == true,
        "a scene begins and is over, by its name")
    -- The player's own boss fight, and the story's point.
    Session.moveTo(h, 3000, 2800)
    s:run(1)
    local boss = Session.enemyOn(h, "boss")
    h.hudLayout:RegisterBossHPBar(boss)
    s:run(3)
    h.hudLayout:UnRegisterBossHPBar(boss)
    s:run(5)
    text = logOf(h)
    check(text:find("PLAY a boss fight begins: sp:boss, alive, health %d+ of %d+%.") ~= nil
        and text:find("PLAY the boss fight with sp:boss is over %([%d%.]+ s%): the boss alive, health %d+ of %d+%.") ~= nil,
        "the player's own boss fight begins and is over, by the boss's name, with its health")
    check(text:find("PLAY the story: row %d+, %d+ steps done; done steps %x+%.") ~= nil,
        "and the story's point is in it, with which steps are done")
    Session.moveTo(h, 0, 0)
    s:run(1)
    -- UE4SS.log's own lines worth having.
    check(has(text, "UE4SS (12:11:09.991) UE4SS - v3.0.1 Beta") and has(text, "UE4SS (12:11:09.996) Starting Lua mod 'SomeOtherMod'")
        and has(text, "UE4SS (12:11:12.500) [Lua] Error: attempt to index a nil value") and has(text, "UE4SS     stack traceback:")
        and text:find("UE4SS +%[C%]: in %?") ~= nil,
        "UE4SS.log's lines worth having are in it: UE4SS's version, another mod started, a Lua error and the lines under it")
    check(not has(text, "RegisterHook") and not has(text, "ArIsError") and not has(text, "as UE4SS.log has it")
        and not has(text, "the other copy's") and not has(text, "half a line"),
        "and not what UE4SS says of every hook and offset, nor the mod's own lines a second time, nor a line not ended yet")
    local flood = {}
    for i = 1, 200 do
        flood[i] = "[2026-11-18 12:12:00.0000000] [Lua] [OtherMod] the same thing again " .. i
    end
    h.files["UE4SS.log"] = h.files["UE4SS.log"] .. ", now ended\n[2026-11-18 12:11:59.0000000] [Lua] [OtherMod] a later line\n"
        .. table.concat(flood, "\n") .. "\n"
    s:run(2.5)
    text = logOf(h)
    check(has(text, "UE4SS (12:11:59.000) [Lua] [OtherMod] a later line") and not has(text, "now ended")
        and has(text, "the same thing again 59") and not has(text, "the same thing again 60\n")
        and has(text, "UE4SS (141 more of its lines not copied: see UE4SS.log itself)"),
        "it reads on as UE4SS.log grows, and a mod that floods it is copied sixty lines a time, the rest counted")
    -- The same line over and over (UE4SS's error at every frame): said once and counted, and the next line after it.
    local same = {}
    for i = 1, 200 do
        same[i] = "[2026-11-18 12:13:00.0000000] [Lua] [error] the same error, every frame"
    end
    h.files["UE4SS.log"] = h.files["UE4SS.log"] .. table.concat(same, "\n") .. "\n    under it, where it was\n"
        .. "[2026-11-18 12:13:05.0000000] [Lua] [OtherMod] and a line after them\n"
    s:run(2.5)
    text = logOf(h)
    check(select(2, text:gsub("the same error, every frame", "")) == 1 and has(text, "UE4SS (the line above 199 times more)")
        and has(text, "and a line after them") and not has(text, "under it, where it was"),
        "the same line of UE4SS.log over and over is said once and counted, the lines under its repeats left out")
    check(h.opens["UE4SS.log"] == 1, "and UE4SS.log is read through one handle kept open: opened "
        .. tostring(h.opens["UE4SS.log"]) .. " time in the session")
    -- The player's mark.
    local menu = Fake.screen(h, "W_SomeMenu_C")
    h.keys["F2"] = true         -- (not F2: the guides tell another mod's players to put its menu there)
    s:run(0.5)
    h.keys["F2"] = nil
    s:run(0.2)
    local onF2 = select(2, logOf(h):gsub("MARK %d+ =====", ""))
    h.keys["F7"] = true
    s:run(0.2)
    h.keys["F7"] = nil
    s:run(0.2)
    for i, screen in ipairs(h.screens) do
        if screen == menu then
            table.remove(h.screens, i)
            break
        end
    end
    text = logOf(h)
    local shown = h.env.PBZ.status.lastShown["playlog1"]
    check(select(2, text:gsub("\n[^\n]*MARK %d+ =====", "")) == 1 and text:find("MARK 1 =====[^\n]*\n[^\n]*STATE [^\n]*| relay ") ~= nil
        and shown and shown.text == "marked in the play log." and onF2 == 0,
        "F7 marks the moment (F2 doesn't): a line that stands out, how the game stands right then, and a word on the screen")
    check(text:find("MARK 1 =====[^\n]*\n[^\n]*STATE [^\n]*\n[^\n]*SNAP on the screen: [^\n]*W_SomeMenu_C[^\n]*\n[^\n]*SNAP the player: [^\n]*\n[^\n]*SNAP enemies within 40 m: ") ~= nil,
        "with the whole picture under it: the screen that's up, the body, the enemies near")
    h.keys["Gamepad_LeftThumbstick"] = true
    s:run(2)
    local alone = select(2, logOf(h):gsub("MARK %d+ =====", ""))
    h.keys["Gamepad_RightThumbstick"] = true
    s:run(0.4)
    local early = select(2, logOf(h):gsub("MARK %d+ =====", ""))
    s:run(3)
    local once = select(2, logOf(h):gsub("MARK %d+ =====", ""))
    h.keys["Gamepad_RightThumbstick"] = nil
    s:run(0.2)
    h.keys["Gamepad_RightThumbstick"] = true
    s:run(1)
    local again = select(2, logOf(h):gsub("MARK %d+ =====", ""))
    h.keys["Gamepad_LeftThumbstick"], h.keys["Gamepad_RightThumbstick"] = nil, nil
    check(alone == 1 and early == 1 and once == 2 and again == 3,
        string.format("both sticks pressed in for 0.7 s mark it too, once a hold; one stick alone doesn't: %d, %d, %d, %d marks", alone, early, once, again))
    -- A file that's full: the session goes on in the next.
    local play = h.env.PBZ.playlog
    local keptBytes = play.PART_BYTES
    play.PART_BYTES = 200
    h.env.PBZ.log("the line that fills the file")
    play.PART_BYTES = keptBytes
    h.env.PBZ.log("the first line of the next file")
    local next_, nextName = logOf(h)
    check(nextName == name:gsub("%.txt$", "-2.txt") and has(next_, "Phantom Pact play log, file 2 of the session begun ")
        and has(next_, "the first line of the next file") and not has(next_, "the line that fills the file")
        and has(h.files[name] or "", "the line that fills the file") and has(h.files[name] or "", "(this file is full: the session goes on in the next one)")
        and has(h.files["playlog-index.txt"], nextName),
        "a file that's full is closed and the session goes on in a second one, kept in the list too")
    -- A file that can't be written: the log ends, the mod doesn't.
    local errors = #h.errors
    h.fileFails = { [nextName] = true }
    h.env.PBZ.log("a line the disk has no room for")
    h.env.PBZ.log("and the mod goes on")
    s:run(12)
    check(play.on == false and #h.errors == errors and count(h.logs, "and the mod goes on") == 1
        and h.files[nextName] ~= nil and not has(h.files[nextName], "and the mod goes on") and next(h.writing) == nil,
        "a file that can't be written any more ends the play log quietly: the mod goes on, and says what it says")
    allErrors(s)
    -- A line said before the play log began (main.dll being another version's is said as the mod's link opens).
    local e = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES, nil, nil, function(pc)
        pc.dllProtocol = false
    end)
    e:run(3)
    local firsts = logOf(e.pcs[1])
    check(count(e.pcs[1].logs, "main%.dll is another version's %(1%.7%.3 or older") == 1
        and (firsts:find("main.dll is another version's (1.7.3 or older", 1, true) or 0) > (firsts:find("STATE: how the game stood", 1, true) or 1e9),
        "a line the mod said before the log began is in it too, after its head")
    -- PlayLogKeep.
    local few = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES, "PlayLogKeep = 3\n", nil, function(pc)
        for i = 1, 5 do
            pc.files[old[i]] = "an old session\n"
        end
        pc.files["playlog-index.txt"] = table.concat(old, "\n", 1, 5) .. "\n"
    end)
    few:run(1)
    local f = few.pcs[1]
    check(f.files[old[3]] == nil and f.files[old[4]] ~= nil and f.files[old[5]] ~= nil
        and select(2, f.files["playlog-index.txt"]:gsub("\n", "\n")) == 3,
        "PlayLogKeep = 3: three files are kept, the new one among them")
    -- A session whose files fill one after another, three kept: its own first file (its head, how the trouble began) is
    -- never the one deleted, nor the one just begun. The older sessions' go first, then its own middle ones.
    local many = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES, "PlayLogKeep = 3\n", nil, function(pc)
        pc.files[old[1]], pc.files[old[2]] = "an old session\n", "an old session\n"
        pc.files["playlog-index.txt"] = old[1] .. "\n" .. old[2] .. "\n"
    end)
    many:run(1)
    local m = many.pcs[1]
    local _, mfirst = logOf(m)
    m.env.PBZ.playlog.PART_BYTES = 300
    for i = 1, 5 do
        m.env.PBZ.log("a line that fills a file, " .. i .. ": " .. string.rep("x", 300))
    end
    m.env.PBZ.playlog.PART_BYTES = 8 * 1024 * 1024
    local _, mlast = logOf(m)
    local list = m.files["playlog-index.txt"]
    check(mfirst ~= nil and mlast == (mfirst:gsub("%.txt$", "-6.txt")) and m.files[old[1]] == nil and m.files[old[2]] == nil
        and m.files[mfirst] ~= nil and has(m.files[mfirst], "Phantom Pact play log, begun ")
        and m.files[(mfirst:gsub("%.txt$", "-2.txt"))] == nil and has(list, mfirst .. "\n") and has(list, mlast)
        and select(2, list:gsub("\n", "\n")) == 3,
        "a session whose files fill one after another keeps its own first file and the one just begun: older sessions' go first, then its own middle ones")
    allErrors(many)
    -- A file that can't be deleted now (open in a viewer, under a scan) stays on the list, and goes the next time.
    local held = Session.new(SIM_SCRIPTS, { "Host" }, false, ENEMIES, "PlayLogKeep = 2\n", nil, function(pc)
        pc.files[old[1]], pc.files[old[2]] = "an old session\n", "an old session\n"
        pc.files["playlog-index.txt"] = old[1] .. "\n" .. old[2] .. "\n"
        pc.fileStuck = { [old[1]] = true }
    end)
    held:run(1)
    local k = held.pcs[1]
    local stayed = k.files[old[1]] ~= nil and has(k.files["playlog-index.txt"], old[1] .. "\n")
    k.fileStuck = nil
    k.env.PBZ.playlog.PART_BYTES = 300
    k.env.PBZ.log("a line that fills the file: " .. string.rep("x", 300))
    k.env.PBZ.playlog.PART_BYTES = 8 * 1024 * 1024
    check(stayed and k.files[old[1]] == nil and not has(k.files["playlog-index.txt"], old[1]),
        "a file that can't be deleted now stays on the list, and goes as the next file begins")
    allErrors(held)
    -- PlayLog = Off.
    local off = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, "PlayLog = Off\n")
    off:run(15)
    local none = true
    for _, pc in ipairs(off.pcs) do
        for fileName in pairs(pc.files) do
            none = none and not fileName:find("^playlog")
        end
        none = none and next(pc.writing) == nil and pc.env.PBZ.playlog == nil and net(pc).profile == nil
    end
    check(none, "PlayLog = Off: no file, no list, and the mod's time isn't counted")
    allErrors(off)
end

-- 410: a rider and its mount (players on 1.7.4, 11-20: "the horse boss riding doesn't appear to guest, only host can
-- see it"). Jing Ye's horse is an enemy of its own, from a spawner the game makes as it runs: no designer id, and a name
-- of that session's alone ("BP_AISpawner_C_2147456939" on the bench's host, "..._2147449150" on its guest, run250).
local function aRiderAndItsMount()
    part("a rider and its mount")
    local HORSE = "BP_Monster_Horse_JingYe_C"
    local world = {
        { "rider", "BP_Monster_JingYe_C", 2000.0, 0.0, 100.0, 5000, 400, false },
        { "horse", HORSE, 2000.0, 0.0, 100.0, 1800, 100, false },
    }
    -- Each PC's own horse: its spawner with no designer id and a name of this session's, its rider attached to it.
    -- The guest's stand at guestPairX (30 m from the host's: its own game's, run off while the host fought). hostHas
    -- false: the host's horse is dead already. The players at hostX and guestX.
    local function ride(hostHas, hostX, guestX, guestPairX)
        local horses, riders = {}, {}
        local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, world, nil, nil, function(pc, i)
            local sp = pc.spawners[Session.indexOf(pc, "horse")]
            local horse, rider = rawget(sp, "__fields").SpawnedAI, Session.enemyOn(pc, "rider")
            local n = i == 1 and 2147456939 or 2147449150
            Fake.put(sp, "SpawnerID", Fake.name("None"))
            rawset(sp, "__name", "BP_AISpawner_C_" .. n)
            rawset(horse, "__name", HORSE .. "_" .. (n - 1425))
            rawset(horse, "__classObject", { IsValid = function() return true end, GetFName = function() return Fake.name(HORSE) end })
            horses[i], riders[i] = { actor = horse, ridden = true }, rider
            Fake.put(rider, "GetAttachParentActor", function() return horses[i].ridden and horse or nil end)
            if i == 2 then
                Fake.put(horse, "loc", { X = guestPairX, Y = 0.0, Z = 100.0 })
                Fake.put(rider, "loc", { X = guestPairX, Y = 0.0, Z = 100.0 })
            elseif not hostHas then
                Fake.put(horse, "dead", true)
                Fake.setHealth(horse, 0)
                horses[i].ridden = false
            end
        end)
        s:run(4)
        Session.moveTo(s.pcs[1], hostX, 0)
        Session.moveTo(s.pcs[2], guestX, 0)
        s:run(6)
        return s, s.pcs[1], s.pcs[2], horses, riders
    end
    local function brain(e)
        return field(field(field(e, "Controller"), "BrainComponent"), "running")
    end
    local s, h, g, horses, riders = ride(true, 1500, 2500, 5000.0)
    local hostHorse, guestHorse = horses[1].actor, horses[2].actor
    local hostName, guestName = h.env.PBZ.game.enemyId(hostHorse), g.env.PBZ.game.enemyId(guestHorse)
    check(hostName == rawget(hostHorse, "__name") and guestName == rawget(guestHorse, "__name"),
        "an enemy from a spawner the game made as it ran goes by its own name: its spawner's is no id (" .. tostring(hostName) .. ")")
    check(count(g.sent, "^E HAS ") == 0 and count(h.sent, "^E NOT ") == 0, "the guest doesn't ask the host after its own horse, and no \"no\" comes")
    check(field(guestHorse, "hidden") ~= true and at(guestHorse).Z < 1000, "so it isn't put out of the way")
    check(net(g).matchSticky[hostName] == guestHorse:GetAddress(), "what the rider's copy rides is paired with the host's horse, 30 m from it")
    check(gap(at(guestHorse), at(hostHorse)) < 150, "and brought to it (" .. string.format("%.0f", gap(at(guestHorse), at(hostHorse))) .. " cm off)")
    check(field(field(field(guestHorse, "Controller"), "BrainComponent"), "running") == false, "its mind the host's, like any copy's")
    check(gap(at(riders[2]), { X = 5000, Y = 0 }) < 1, "the rider's copy isn't moved by itself: its place is its mount's")
    -- The rider gets down (its mount dead, its own move): steered by its own line again.
    horses[2].ridden = false
    s:run(1.5)
    check(gap(at(riders[2]), at(riders[1])) < 150, "off its mount, the rider's copy goes by the host's line of it again ("
        .. string.format("%.0f", gap(at(riders[2]), at(riders[1]))) .. " cm off)")
    -- Names: what is one PC's alone, and what both share.
    local own, runtime = net(g).ownName, g.env.PBZ.game.runtimeName
    check(own ~= nil and own("sp:BP_AISpawner_C_2147456939") and own("BP_Monster_Horse_JingYe_C_2147455514") and not own("sp:JingYe")
        and not own("sp:BP_AISpawner_C_UAID_60CF848A6689B9D402_1721359969") and not own("tw1:sp:JingYe")
        and not own("sp:WanJun_Seq074") and not own("sp:LeiDang_Seq123-3") and not own("sp:Camp_12"),
        "one PC's alone: an actor's own name, and a spawner's made as the game ran; not a level's spawner, a designer's id, a twin")
    check(runtime ~= nil and not runtime("sp:BP_Teleport_C_UAID_E89C25A75120AE5002_2091202670") and not runtime(nil) and runtime("X_2000000000")
        and not runtime("X_1999999999"), "(a level's own name stays one, whatever number ends it)")
    -- An older guest still asks after its horse by its spawner's name: no "no" for a name that is the asker's alone.
    g.env.PBZ.coop.sendEvent("HAS", "sp:BP_AISpawner_C_2147449150")
    g.env.PBZ.coop.sendEvent("HAS", "sp:nobody")
    s:run(1)
    check(count(h.sent, "^E NOT sp:BP_AISpawner_C_2147449150$") == 0 and count(h.sent, "^E NOT sp:nobody$") == 1,
        "an older guest asks by its spawner's name: the host says nothing of it (and still \"no\" of a level's)")
    allErrors(s)
    -- The host's horse dead, the guest's own alive under its rider: no line to pair it with. The rider's copy is steered
    -- by its own line as ever (nothing else would bring it), after the moment it's left on its mount.
    local s2, _, g2, horses2, riders2 = ride(false, 1500, 2500, 5000.0)
    check(gap(at(riders2[2]), at(riders2[1])) < 150, "a rider whose mount is no copy of the host's is steered by its own line, as ever")
    check(field(horses2[2].actor, "hidden") ~= true and count(g2.sent, "^E HAS ") == 0, "and its mount is left be: not asked after, not hidden")
    allErrors(s2)
    -- The guest's game runs the rider (the guest by it, the host 45 m behind: handed over). What it rides is the guest's
    -- game's too: no copy of the host's horse, though that one stands at the very same place.
    local s3, h3, g3, horses3 = ride(true, -2500, 1800, 2000.0)
    local name3 = h3.env.PBZ.game.enemyId(horses3[1].actor)
    check(net(g3).mine["sp:rider"] == true, "(a rider by the guest, the host 45 m behind: the guest's game runs it)")
    check(net(g3).matchSticky[name3] == nil and brain(horses3[2].actor) == true and field(horses3[2].actor, "hidden") ~= true,
        "what a rider this game runs rides is this game's own too: no copy of the host's horse, its mind its own")
    -- The host comes up: the rider is the host's game's again, and its mount a copy of the host's with it.
    Session.moveTo(h3, 1600, 300)
    s3:run(5)
    check(net(g3).mine["sp:rider"] == nil and net(g3).matchSticky[name3] == horses3[2].actor:GetAddress()
        and brain(horses3[2].actor) == false, "the host beside them: the rider the host's game's again, and its mount a copy with it")
    allErrors(s3)
end

-- 412: two riders, their horses of one kind (the spear riders of Pangzhen). By kind and nearness alone the two horses
-- can be paired crosswise, and since 410 a rider's copy is left on its mount: each would stand where the other's is.
local function twoRidersAndTheirMounts()
    part("two riders and their mounts")
    local HORSE = "BP_Monster_Horse_MonsterHorse_C"
    local world = {
        { "rider1", "BP_Monster_SpearMan_C", 2000.0, 0.0, 100.0, 900, 100, false },
        { "horse1", HORSE, 2000.0, 0.0, 100.0, 1800, 100, false },
        { "rider2", "BP_Monster_SpearMan_C", 2600.0, 0.0, 100.0, 900, 100, false },
        { "horse2", HORSE, 2600.0, 0.0, 100.0, 1800, 100, false },
    }
    local horses = { {}, {} }       -- [pc][n]: that PC's horse of rider n
    local s = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, world, nil, nil, function(pc, i)
        for n = 1, 2 do
            local sp = pc.spawners[Session.indexOf(pc, "horse" .. n)]
            local horse, rider = rawget(sp, "__fields").SpawnedAI, Session.enemyOn(pc, "rider" .. n)
            local number = 2147456939 - i * 7000 - n * 100
            Fake.put(sp, "SpawnerID", Fake.name("None"))
            rawset(sp, "__name", "BP_AISpawner_C_" .. number)
            rawset(horse, "__name", HORSE .. "_" .. (number - 1425))
            rawset(horse, "__classObject", { IsValid = function() return true end, GetFName = function() return Fake.name(HORSE) end })
            Fake.put(rider, "GetAttachParentActor", function() return horse end)
            horses[i][n] = horse
            if i == 2 then
                -- (the guest's own two stand crosswise: its first pair where the host's second is)
                local x = n == 1 and 2600.0 or 2000.0
                Fake.put(horse, "loc", { X = x, Y = 0.0, Z = 100.0 })
                Fake.put(rider, "loc", { X = x, Y = 0.0, Z = 100.0 })
            end
        end
    end)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 1500, 0)
    Session.moveTo(g, 2300, 300)
    s:run(6)
    local name1, name2 = h.env.PBZ.game.enemyId(horses[1][1]), h.env.PBZ.game.enemyId(horses[1][2])
    check(net(g).matchSticky[name1] == horses[2][1]:GetAddress() and net(g).matchSticky[name2] == horses[2][2]:GetAddress(),
        "two riders, their horses of one kind, this world's standing crosswise: each mount is paired by its rider, not by which is nearer")
    check(gap(at(horses[2][1]), at(horses[1][1])) < 150 and gap(at(horses[2][2]), at(horses[1][2])) < 150,
        "and each stands where the host's has it (" .. string.format("%.0f and %.0f cm off",
            gap(at(horses[2][1]), at(horses[1][1])), gap(at(horses[2][2]), at(horses[1][2]))) .. ")")
    -- A rider gets down: its mount stays the copy it was (the pairing is kept, as any pairing is).
    Fake.put(Session.enemyOn(g, "rider1"), "GetAttachParentActor", function() return nil end)
    s:run(2)
    check(net(g).matchSticky[name1] == horses[2][1]:GetAddress(), "a rider got down: its mount is still the copy it was")
    allErrors(s)
end

-- 411: a jump of the host's enemy, taken at once by its copy (players on 1.7.4, 11-20: "boss teleport doesn't sync up
-- for guest ... near impossible for guest to fight"). On the bench (run251) A-Hua's teleport move goes 5 to 6 m in a
-- tenth of a second, and the guest's copy, walked after it, was 5.9 m behind and 0.66 s in coming.
local function anEnemysJump()
    part("an enemy's jump")
    local s, h, g = pair()
    local hostE, copy = Session.enemyOn(h, "near"), Session.enemyOn(g, "near")
    local function off()
        return gap(at(copy), at(hostE))
    end
    local function move(dx, dy)
        local l = at(hostE)
        Fake.put(hostE, "loc", { X = l.X + dx, Y = l.Y + dy, Z = l.Z })
    end
    s:run(1)
    check(off() < 30, "(a copy stands where the host's enemy does)")
    -- A blink: 6 m off in one frame, standing before and after.
    move(600, 0)
    s:run(0.15)
    check(off() < 30, "the host's enemy is 6 m off in one step: its copy is there at once (" .. string.format("%.0f", off()) .. " cm off, 0.15 s on)")
    check(net(g).remoteEnemies["sp:near"].jumpAt ~= nil, "(its line's record says it jumped)")
    -- A dash: 130 cm a frame for five frames, then it stands.
    s:run(1)
    for _ = 1, 5 do
        move(0, 130)
        s:run(1 / 60)
    end
    local took = nil
    for frame = 1, 60 do
        s:run(1 / 60)
        if not took and off() < 30 then
            took = frame / 60
        end
    end
    check(took ~= nil and took <= 0.15, "a dash of 78 m a second, 6.5 m: its copy is there within 0.15 s of its end ("
        .. (took and string.format("%.2f s", took) or "not in a second") .. ")")
    -- A walk is no jump: 10 cm a frame (6 m a second) for a second.
    s:run(1)
    local was = net(g).remoteEnemies["sp:near"].jumpAt
    Fake.put(field(hostE, "CharacterMovement"), "Velocity", { X = -600.0, Y = 0.0, Z = 0.0 })
    for _ = 1, 60 do
        move(-10, 0)
        s:run(1 / 60)
    end
    Fake.put(field(hostE, "CharacterMovement"), "Velocity", { X = 0.0, Y = 0.0, Z = 0.0 })
    check(net(g).remoteEnemies["sp:near"].jumpAt == was, "a walk is no jump")
    -- A copy that makes the dash itself (it plays the host's move for real) is a little ahead of the host's line of it,
    -- on the jump's own way: left there. One behind, or off to the side, is set to the line.
    s:run(1)
    move(300, 0)
    s:run(0.15)
    check(off() < 30, "(a jump of 3 m: its copy set there)")
    local l = at(hostE)
    Fake.put(copy, "loc", { X = l.X + 200, Y = l.Y, Z = l.Z })
    s:run(2 / 60)
    check(off() > 100, "a copy ahead of the host's line on the jump's own way is left: its own dash, a link's delay before the line ("
        .. string.format("%.0f", off()) .. " cm ahead, two frames on)")
    Fake.put(copy, "loc", { X = l.X - 200, Y = l.Y, Z = l.Z })
    s:run(2 / 60)
    check(off() < 30, "one behind it is set to the line (" .. string.format("%.0f", off()) .. " cm off, two frames on)")
    Fake.put(copy, "loc", { X = l.X + 50, Y = l.Y + 200, Z = l.Z })
    s:run(2 / 60)
    check(off() < 30, "and one off to its side")
    -- The hold over, a copy off its line is walked there as ever, no more set.
    s:run(1)
    Fake.put(copy, "loc", { X = l.X - 200, Y = l.Y, Z = l.Z })
    s:run(2 / 60)
    check(off() > 100, "a moment after the jump a copy off its line is walked to it as ever, not set (" .. string.format("%.0f", off()) .. " cm, two frames on)")
    allErrors(s)
end

-- Other mods (mods.lua): each PC lists its own (pak mods under Paks, UE4SS mods switched on), sends a mark for each, and
-- is told once what differs: by its own mods' names alone, never the partner's. (Players on 1.7.6: "from his
-- perspective, my mod is not displaying".)
local function otherMods()
    part("other mods")
    local function tips(pc, pattern)
        return count(pc.logs, "Status: " .. pattern)
    end
    local ONLY_WHERE = " What a mod changes shows only on a PC that has it%.$"

    -- Nothing but the game and Phantom Pact on either PC.
    local a = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES)
    a:run(16)
    local h, g = a.pcs[1], a.pcs[2]
    check(count(h.logs, "Mods here beside Phantom Pact: 0 %(0 pak, 0 UE4SS%)%.$") == 1
        and count(g.logs, "Mods here beside Phantom Pact: 0 %(0 pak, 0 UE4SS%)%.$") == 1,
        "no other mod: the game's own paks, UE4SS's own mods and Phantom Pact aren't counted")
    check(count(h.sent, "^E MODS %d+ 1 1 0$") >= 1 and count(g.sent, "^E MODS %d+ 1 1 0$") >= 1, "each PC tells the other it has none")
    check(count(h.logs, "Mods check with your partner: 0 the same; 0 of this PC's 0 aren't on theirs; 0 of theirs aren't here; "
        .. "0 another version there%.$") == 1, "the comparison is in the log, once though the marks came twice")
    check(tips(h, ".*mods") == 0 and tips(g, ".*mods") == 0 and h.files["mods_told.txt"] == nil, "nothing differs: no tip")
    check(Session.shippedIni():match("\nModsCheck = ([^\r\n]+)") == "On", "the ini as it ships has ModsCheck = On")
    allErrors(a)

    -- Mods that differ. The host: an outfit (three files, one mod), a sword, a hair mod and one named as the game's own files
    -- are (ProjectPBZ-..._997_P, as real ones are) in Paks itself, a UE4SS mod with its enabled.txt. The guest: the outfit in another size, the same hair, a UE4SS mod mods.txt turns on and one it turns off.
    local function differing(pc, i)
        if i == 1 then
            pc.mods = { paks = { { "zzz_Outfit_P.pak", 1000 }, { "zzz_Outfit_P.utoc", 200 }, { "zzz_Outfit_P.ucas", 64 },
                { "pakchunk99-Naginata_P.pak", 5000 }, { "readme.txt", 300 } }, rootPaks = { { "Hair_P.pak", 700 },
                { "ProjectPBZ-MoyuanExecution_997_P.pak", 347 }, { "ProjectPBZ-MoyuanExecution_997_P.ucas", 1600000 } },
                scripts = { { "RandomWeapon", 5000 } } }
        else
            pc.mods = { paks = { { "zzz_Outfit_P.pak", 1200 }, { "zzz_Outfit_P.utoc", 200 }, { "zzz_Outfit_P.ucas", 64 } },
                rootPaks = { { "Hair_P.pak", 700 } }, scripts = { { "MapMarkers", 900, "listed" }, { "Unused", 100, "listed" } } }
            pc.files["mods.txt"] = "MapMarkers : 1\nUnused : 0\nPBZCoop : 1\n\n; Built-in keybinds, do not move up!\nKeybinds : 0\n"
        end
    end
    local b = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, nil, nil, differing)
    b:run(30)
    h, g = b.pcs[1], b.pcs[2]
    check(count(h.logs, "Mods here beside Phantom Pact: 5 %(4 pak, 1 UE4SS%): Hair, Naginata, MoyuanExecution, Outfit, RandomWeapon%.$") == 1,
        "the host's own: a mod's files are one mod, named without what only orders the load; one named ProjectPBZ-... is a mod")
    check(count(g.logs, "Mods here beside Phantom Pact: 3 %(2 pak, 1 UE4SS%): Hair, Outfit, MapMarkers%.$") == 1,
        "the guest's: a UE4SS mod mods.txt turns on counts, one it turns off doesn't")
    check(count(h.logs, "Mods check with your partner: 1 the same; 3 of this PC's 5 aren't on theirs %(Naginata, MoyuanExecution, RandomWeapon%); "
        .. "1 of theirs aren't here; 1 another version there %(Outfit%)%.$") == 1, "the host's comparison")
    check(count(g.logs, "Mods check with your partner: 1 the same; 1 of this PC's 3 aren't on theirs %(MapMarkers%); "
        .. "3 of theirs aren't here; 1 another version there %(Outfit%)%.$") == 1, "the guest's")
    check(tips(h, "your partner doesn't have these mods of yours: Naginata, MoyuanExecution, RandomWeapon%." .. ONLY_WHERE) == 1
        and tips(g, "your partner doesn't have these mods of yours: MapMarkers%." .. ONLY_WHERE) == 1,
        "each is told which of their own mods the partner doesn't have")
    check(tips(h, "your partner has mods you don't have %(1%)%." .. ONLY_WHERE) == 1
        and tips(g, "your partner has mods you don't have %(3%)%." .. ONLY_WHERE) == 1,
        "and how many the partner has that they don't")
    check(tips(h, "these mods are another version on your partner's PC: Outfit%.$") == 1
        and tips(g, "these mods are another version on your partner's PC: Outfit%.$") == 1,
        "and which mod is another version there")
    check(count(h.logs, "MapMarkers") == 0 and count(g.logs, "Naginata") == 0 and count(g.logs, "RandomWeapon") == 0
        and count(g.logs, "MoyuanExecution") == 0,
        "a partner's mod names are never said or logged here")
    check((h.files["mods_told.txt"] or ""):find("^%x%x%x%x%x%x%x%x\n$") ~= nil, "what was told is kept")
    -- The link drops and comes back: the marks go again and are compared again; nothing is said a second time.
    local heardBefore = h.env.PBZ.mods.heard
    g.cut = true
    b:run(10)
    check(h.env.PBZ.mods.result[0] == nil, "the link gone: what was known of the partner's mods is forgotten")
    g.cut = false
    b:run(30)
    check(h.env.PBZ.mods.heard > heardBefore and h.env.PBZ.mods.result[0] ~= nil
        and count(h.logs, "Mods check with your partner: 1 the same; 3 of this PC's 5") == 1
        and tips(h, "your partner doesn't have these mods of yours") == 1 and tips(h, "your partner has mods you don't have") == 1
        and tips(h, "these mods are another version") == 1, "the link back: compared again, and the same comparison neither logged nor told a second time")
    Session.command(h, "mods")
    b:run(1)
    check(count(h.logs, "Mods check: on; 5 mods here; sent %d+, heard %d+; partner: 1 the same, 3 missing there, 1 missing here, "
        .. "1 another version$") == 1, "the mods command says how it stands")
    allErrors(b)

    -- The next session, the same mods on both: nothing is said a second time. A new difference is.
    local told = h.files["mods_told.txt"]
    local n = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, nil, nil, function(pc, i)
        differing(pc, i)
        if i == 1 then
            pc.files["mods_told.txt"] = told
        end
    end)
    n:run(30)
    h, g = n.pcs[1], n.pcs[2]
    check(count(h.logs, "Mods check with your partner: 1 the same; 3 of this PC's 5") == 1 and tips(h, ".*mods") == 0,
        "the next session: the comparison is in the log, the difference told before isn't told again")
    check(tips(g, "your partner doesn't have these mods of yours: MapMarkers%.") == 1, "a PC that wasn't told yet is")
    Session.command(g, "mods fake p Bench 123")
    n:run(30)
    check(tips(h, "your partner has mods you don't have %(2%)%.") == 1 and tips(h, "your partner doesn't have these mods") == 1
        and tips(g, "your partner doesn't have these mods of yours: Bench, MapMarkers%.") == 1,
        "a new difference (a mod added on the guest's side) is told on both")
    allErrors(n)

    -- ModsCheck = Off on one PC: it lists, sends and compares nothing, and its partner says nothing of it. (A partner on an
    -- older version is the same to this one: no marks come.)
    local c = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, nil, nil, function(pc, i)
        differing(pc, i)
        if i == 2 then
            pc.files["PhantomPact.ini"] = pc.files["PhantomPact.ini"] .. "ModsCheck = Off\n"
        end
    end)
    c:run(30)
    h, g = c.pcs[1], c.pcs[2]
    check(count(g.sent, "^E MODS") == 0 and count(g.logs, "Mods here beside") == 0 and count(g.logs, "Mods check with") == 0
        and tips(g, ".*mods") == 0, "ModsCheck = Off: that PC lists, sends and compares nothing")
    check(count(h.sent, "^E MODS") >= 1 and count(h.logs, "Mods check with") == 0 and tips(h, ".*mods") == 0,
        "its partner hears no marks and says nothing, as of a partner on an older version")
    allErrors(c)

    -- An older main.dll under these scripts (no folder's list): nothing sent, nothing compared, and it says why once.
    local d = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, nil, nil, function(pc, i)
        differing(pc, i)
        pc.noFiles = i == 1
    end)
    d:run(30)
    h, g = d.pcs[1], d.pcs[2]
    check(count(h.logs, "Mods check: this main%.dll can't list a folder") == 1 and count(h.sent, "^E MODS") == 0
        and count(h.logs, "Mods check with") == 0 and tips(h, ".*mods") == 0,
        "no way to list a folder: no marks sent, nothing compared, no tip about mods it can't see")
    check(count(g.logs, "Mods check with") == 0 and tips(g, ".*mods") == 0, "and its partner, hearing none, says nothing")
    allErrors(d)

    -- Many mods: forty marks an event. Five of the host's forty-five aren't on the guest's PC.
    local f = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, false, ENEMIES, nil, nil, function(pc, i)
        pc.mods = { paks = {} }
        for k = 1, 45 do
            if i == 1 or k < 17 or k > 21 then
                pc.mods.paks[#pc.mods.paks + 1] = { string.format("Mod%02d_P.pak", k), 100 + k }
            end
        end
    end)
    f:run(30)
    h, g = f.pcs[1], f.pcs[2]
    check(count(h.sent, "^E MODS %d+ 1 2 45 p%x+") >= 1 and count(h.sent, "^E MODS %d+ 2 2 45 p%x+") >= 1
        and count(g.sent, "^E MODS %d+ 1 1 40 p%x+") >= 1, "45 mods go as two events, 40 as one")
    check(count(h.logs, "Mods check with your partner: 40 the same; 5 of this PC's 45 aren't on theirs "
        .. "%(Mod17, Mod18, Mod19, Mod20, Mod21%); 0 of theirs aren't here; 0 another version there%.$") == 1
        and count(g.logs, "Mods check with your partner: 40 the same; 0 of this PC's 40 aren't on theirs; 5 of theirs aren't here") == 1,
        "the two events are put together and compared")
    check(tips(h, "your partner doesn't have these mods of yours: Mod17, Mod18, Mod19 %(%+2%)%." .. ONLY_WHERE) == 1,
        "a long list: three names, and how many more")
    check(tips(g, "your partner has mods you don't have %(5%)%.") == 1, "the guest is told the number alone")
    -- A flood of new lists from one player (eight in eight seconds, each with one more mod): six a minute are taken.
    for k = 1, 8 do
        Session.command(g, "mods fake p Extra" .. k .. " 1")
        f:run(1)
    end
    f:run(2)
    check(h.env.PBZ.mods.result[0].extra == 5 and #g.env.PBZ.mods.list() == 48,
        "eight new lists in eight seconds: the host takes six that minute, the first one counted (" .. h.env.PBZ.mods.result[0].extra .. " of 8)")
    allErrors(f)

    -- More than two players: one line for them all, once each; who has what is in the log, by the player's number.
    local p = Session.new(SIM_SCRIPTS, { "Host", "Guest", "Guest", "Guest" }, true, ENEMIES, nil, nil, function(pc, i)
        if i == 3 then
            pc.mods = { paks = { { "zzz_Outfit_P.pak", 1000 } } }
        end
    end)
    p:run(40)
    check(everyone(p, function(pc) return tips(pc, "the players here don't all have the same mods%." .. ONLY_WHERE) == 1 end),
        "a party: everyone is told once that the mods differ, in one line")
    check(everyone(p, function(pc) return tips(pc, "your partner") == 0 end), "nobody is told of 'your partner' there")
    check(count(p.pcs[3].logs, "Mods check with the host %(purple%): 0 the same; 1 of this PC's 1 aren't on theirs %(Outfit%)") == 1
        and count(p.pcs[3].logs, "Mods check with player 2 %(green%): 0 the same; 1 of this PC's 1") == 1
        and count(p.pcs[3].logs, "Mods check with player 4 %(blue%): 0 the same; 1 of this PC's 1") == 1,
        "the one with the mod: its log has each of the others, by their number")
    check(count(p.pcs[1].logs, "Mods check with player 3 %(gold%): 0 the same; 0 of this PC's 0 aren't on theirs; 1 of theirs aren't here") == 1
        and count(p.pcs[2].logs, "Mods check with player 3 %(gold%): 0 the same; 0 of this PC's 0 aren't on theirs; 1 of theirs aren't here") == 1,
        "the others: the host's log and another guest's say player 3 has one more")
    check(count(p.pcs[1].logs, "Outfit") == 0 and count(p.pcs[2].logs, "Outfit") == 0 and count(p.pcs[4].logs, "Outfit") == 0,
        "and the mod's name is in nobody else's log")
    allErrors(p)

    -- A party's settings with two players in it: told as two players are.
    local q = Session.new(SIM_SCRIPTS, { "Host", "Guest" }, true, ENEMIES, nil, nil, function(pc, i)
        if i == 2 then
            pc.mods = { paks = { { "zzz_Outfit_P.pak", 1000 } } }
        end
    end)
    q:run(30)
    check(tips(q.pcs[2], "your partner doesn't have these mods of yours: Outfit%." .. ONLY_WHERE) == 1
        and tips(q.pcs[1], "your partner has mods you don't have %(1%)%." .. ONLY_WHERE) == 1
        and tips(q.pcs[1], "the players here") == 0 and tips(q.pcs[2], "the players here") == 0,
        "a party of two: each is told as two players are")
    allErrors(q)
end

return function(print_, scripts)
    out = print_
    SIM_SCRIPTS = scripts
    joining()
    movesAndGear()
    heldMoves()
    sharing()
    enemiesAndHits()
    farEnemy()
    guestRunsWhatsNearIt()
    guestRunsItsBoss()
    aCopyWrittenBack()
    aGuardOverItsMost()
    aBossHeldToItsMost()
    aGuestHostsNext()
    asleepOnTheHost()
    aPartysBystander()
    farEnemiesStay()
    mindsEyeLesson()
    syncRaces()
    hitReactions()
    bossReactions()
    bossPosture()
    postureStrip()
    reusedBars()
    bossArmour()
    partnerHitSounds()
    partnerSwingSounds()
    pickupsFresh()
    pickupsShown()
    pickupsRaced()
    pickupCardRecovery()
    storyOnce()
    rests()
    sits()
    sitsForTwo()
    sitBosses()
    twoSaves()
    otherMaps()
    fightsAndWhoIsLeft()
    beatenInBoth()
    guestSide()
    followTheHost()
    questFlags()
    hostsChests()
    looks()
    itemEffects()
    guardStance()
    gaits()
    kickStones()
    memoryFlowers()
    hostsEnemiesHere()
    bossScenes()
    playerReports()
    flowRetries()
    afterATrip()
    phantomEdge()
    newWeaponWaits()
    shots()
    weaponsFound()
    noBodyYet()
    whatsLeftOfAPartner()
    offAndBack()
    aCopysPicker()
    aBodyStillMade()
    localPlay()
    localDifficulty()
    localTargets()
    padHold()
    panelApply()
    bossStartsHere()
    aBossRises()
    localScreen()
    localSticks()
    localRise()
    localLetGo()
    localGround()
    localVoid()
    localStorySpawners()
    localButtons()
    localFight()
    localOptions()
    elsewhere()
    travel()
    hatred()
    focus()
    targets()
    targetsInParties()
    aiming()
    holding()
    holdingForTwo()
    dragonPillarBoss()
    hostDiesFirst()
    finisherWithTheHostDown()
    bossItemsOnce()
    guestsOwnBossKill()
    copyCooldown()
    followToAnotherMap()
    reviewOfTheBuild()
    hostDownAtBossDeath()
    guestDownAtBossDeath()
    doorsOpenedBefore()
    doorsOfTheGames()
    farThings()
    farThingsKept()
    guestBells()
    ownRing()
    craneBellScenes()
    dustOnlyEarned()
    coopDifficulty()
    partyDifficulty()
    lateJoiner()
    lateJoinerGuestFight()
    toldOnChange()
    enemyLinesAgain()
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
    arabic()
    arabicScreens()
    fitting()
    fittedOnScreen()
    cost()
    backToTwo()
    finisherWithTheHostUp()
    guestsFinisher()
    watchingTogether()
    bellsTogether()
    restartWithOldLines()
    ninthReview()
    thePlayLog()
    aRiderAndItsMount()
    twoRidersAndTheirMounts()
    anEnemysJump()
    aCopysDeath()
    otherMods()
    return failed == 0
end
