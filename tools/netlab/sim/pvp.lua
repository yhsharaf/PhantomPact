-- A whole PvP match in the simulator, two players, "here" (no trip): lobby, start, rounds, the end, the finishing move,
-- home; then a second match a guest leaves. python -I tools/netlab/luasim.py pvp
local Session = dofile(SIM_DIR .. "/session.lua")
local Fake = Session.Fake

return function(out, scripts)
    local failed = 0
    local function check(ok, what)
        out("  " .. (ok and "ok   " or "FAIL ") .. what)
        if not ok then failed = failed + 1 end
    end
    local function count(list, pattern)
        local n = 0
        for _, line in ipairs(list) do
            if line:find(pattern) then n = n + 1 end
        end
        return n
    end
    local function last(list, pattern)
        for i = #list, 1, -1 do
            if list[i]:find(pattern) then return list[i] end
        end
        return "-"
    end

    out("the finishing move a place gets (arenas.lua):")
    do
        local data = dofile(scripts .. "/arenas.lua")
        for place, a in ipairs(data.arenas) do
            local f = data.FINISHERS[data.finisherFor(place)]
            check(f and f.boss == a.key, a.name .. ": its boss's own move (" .. tostring(f and f.key) .. ")")
        end
        local seen, rouge = {}, 0
        for _ = 1, 60 do
            local f = data.FINISHERS[data.finisherFor(0)]
            seen[f.key] = true
            rouge = rouge + (f.boss and 0 or 1)
        end
        local kinds = 0
        for _ in pairs(seen) do kinds = kinds + 1 end
        check(rouge == 0 and kinds >= 3, "here: one of the bosses' moves drawn (" .. kinds .. " of 4 in 60 draws, never the Rouge's)")
        check(data.FINISHERS[1].key == "rouge" and not data.FINISHERS[1].lead, "the Rouge's close-in execution stays first")
    end

    local s = Session.new(scripts, { "Host", "Guest" }, false,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(2)
    local ha, ga = h.env.PBZ.arena, g.env.PBZ.arena
    check(ha ~= nil and ga ~= nil, "both have the arena module")
    -- Their skill trees, as the game has them: the host bought three nodes, one of them a talisman slot's; the guest none.
    local OWN = "HeiShi1,HeiShi2,MemoryFlower1"
    local all = #Fake.tree(h, { "HeiShi1", "HeiShi2", "MemoryFlower1" })
    Fake.tree(g, {})
    local function onNodes(pc)
        local ids = {}
        for id in pairs(pc.treeOn) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        return table.concat(ids, ",")
    end
    local function onCount(pc)
        local n = 0
        for _ in pairs(pc.treeOn) do
            n = n + 1
        end
        return n
    end
    local function attack(pc)
        local ok, v = pcall(function() return pc.pawn.AttributeSetBase.Attack.CurrentValue end)
        return ok and v or -1
    end
    local attack0 = attack(h)

    out("lobby:")
    Session.command(h, "arena place 0")
    Session.command(g, "arena ready")
    s:run(1.5)
    check(count(h.sent, "^E AR lobby") >= 1, "the host tells the lobby")
    check(count(g.sent, "^E AR pick") >= 1, "the guest's pick goes out")
    check(ha.picks[2] and ha.picks[2].ready == true, "the host has the guest ready")
    check(ga.lobby ~= nil and ga.lobby.place == 0, "the guest has the lobby (here)")
    check(ha.blocker() == nil, "nothing stops the start: " .. tostring(ha.blocker()))

    out("start:")
    Session.command(h, "arena start")
    s:run(2)
    local sentBefore = #h.sent
    check(ha.match ~= nil and ga.match ~= nil, "both are in the match")
    check(h.env.PBZ.net.arena == true and g.env.PBZ.net.arena == true, "both trim the network (net.arena)")
    check(h.env.PBZ.net.pvp == true and g.env.PBZ.net.pvp == true, "both fight (net.pvp)")
    s:run(3)
    local hm, gm = ha.match, ga.match
    check(hm and gm and hm.id == gm.id, "the same match on both")
    check(hm and (hm.phase == "count" or hm.phase == "fight"), "the host counts down or fights: " .. tostring(hm and hm.phase))
    check(gm and (gm.phase == "count" or gm.phase == "fight"), "the guest counts down or fights: " .. tostring(gm and gm.phase))
    s:run(3.5)
    check(hm and hm.phase == "fight" and gm.phase == "fight", "the fight is on: " .. tostring(hm and hm.phase) .. "/" ..
        tostring(gm and gm.phase))
    check(onCount(h) == all and onCount(g) == all, "every skill node on for both: " .. onCount(h) .. "/" .. onCount(g))
    local enemyEvents = 0
    for i = sentBefore + 1, #h.sent do
        local line = h.sent[i]
        if line:find("^E [KNBF] ") or line:find("^Q A ") or line:find("^N ") or line:find("^Q NQ ") then
            enemyEvents = enemyEvents + 1
        end
    end
    check(enemyEvents == 0, "no enemy traffic from the host in the match: " .. enemyEvents)
    for i = sentBefore + 1, #h.sent do
        local line = h.sent[i]
        if line:find("^E [KNBF] ") or line:find("^Q A ") or line:find("^N ") or line:find("^Q NQ ") then
            out("    enemy traffic: " .. line:sub(1, 120))
        end
    end

    out("parries, judged by the game's own deflect:")
    -- The guest swings at the host beside it, and the host's game answers with its guard or doesn't. (The bench, 11-07: a
    -- guard pressed as the blow comes plays Hun_Tang_DefenceNormal_* and costs nothing; one held from before it plays the
    -- same and costs nothing either; a blow that never reached, nothing. Every figure always runs
    -- GA_Hun_ShachiHook_Passive_C.)
    local DEFENCE = "/PBZCombatAsset/ActorData/Move/Hun_Tang_DefenceNormal_B_Montage.Hun_Tang_DefenceNormal_B_Montage"
    local function figureMontage()
        local ok, path = pcall(function()
            return rawget(rawget(rawget(g.env.PBZ.net.ghost, "__fields").anim, "__fields").montage, "__path")
        end)
        return ok and path or "-"
    end
    local STANCE = "GA_Hun_Tang_Stance_C"
    local STANCE_ENTER = "/PBZCombatAsset/ActorData/Move/AM_Hun_Tang_StanceEnter.AM_Hun_Tang_StanceEnter"
    local heldSeen = "-"            -- the host's figure, for the guest, as the held guard went up
    local hgame = h.env.PBZ.game
    -- The guest cm along X from the host, facing it (yaw 180), or away (its move aimed elsewhere).
    local function beside(cm, away)
        local l = rawget(h.pawn, "__fields").loc
        Session.moveTo(g, l.X + cm, l.Y, l.Z)
        Fake.put(g.pawn, "yaw", away and 0.0 or 180.0)
        s:run(1.0)
    end
    -- The guest's blow (its attack's ability on: the guest's own watch sends it as M) and the host's guard: "parry" raised as
    -- it comes, "held" up from before it, "block" raised as it comes but taken out of the host's posture, "none" no answer.
    local function blow(how)
        if how == "held" then
            Fake.running(h, h.pawn, STANCE, true)
            Session.startMove(h, STANCE_ENTER)
            s:run(0.5)
            heldSeen = figureMontage()
        end
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
        s:run(0.15)
        if how == "parry" or how == "block" then
            Fake.running(h, h.pawn, STANCE, true)
        end
        s:run(0.1)
        if how ~= "none" then
            if how == "block" then
                hgame.setPosture(h.pawn, hgame.getPosture(h.pawn) - 170)
            end
            Session.startMove(h, DEFENCE)
        end
        s:run(0.4)
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
        Fake.running(h, h.pawn, STANCE, false)
        Session.endMove(h)
        s:run(1.6)
    end
    local function parries()
        return count(h.sent, "^E V parry")
    end
    Fake.running(g, g.pawn, "GA_Hun_ShachiHook_Passive_C", true)       -- (on for good, as the game's are)
    beside(150)
    blow("parry")
    check(parries() == 1, "a deflect (the guard raised to meet the blow, nothing lost) is a parry, at once: " .. parries())
    check(count(g.logs, "PARRIED you") == 1, "the guest staggers for it: " .. count(g.logs, "PARRIED you"))
    check(count(h.sent, "^%u U .*DefenceNormal") >= 1, "the host's guard answer goes out in the match")
    check(tostring(figureMontage()):find("DefenceNormal", 1, true) ~= nil,
        "and the host's figure plays it for the guest: " .. tostring(figureMontage()))
    blow("held")
    check(parries() == 1, "a guard held from before the blow only blocks, no stagger: " .. parries())
    check(tostring(heldSeen):find("StanceEnter", 1, true) ~= nil,
        "the guard going up goes out in the match and the host's figure raises it for the guest: " .. tostring(heldSeen))
    check(count(h.sent, "^%u U ") == count(h.sent, "^%u U .*Defence") + count(h.sent, "^%u U .*Stance"),
        "no move but the guard's goes out as U in a match")
    -- Held through the blow and on after it: the figure goes back into the guard, as the host's own body does.
    local function figureShields()
        return rawget(rawget(g.env.PBZ.net.ghost, "__fields"), "effects") or 0
    end
    local shieldsBefore = figureShields()
    Fake.running(h, h.pawn, STANCE, true)
    Session.startMove(h, STANCE_ENTER)
    s:run(0.6)
    local shieldsUp = figureShields()
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
    s:run(0.25)
    Session.startMove(h, DEFENCE)
    s:run(0.3)
    local during = figureMontage()
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
    Session.endMove(h)
    s:run(1.6)
    local after = figureMontage()
    Fake.running(h, h.pawn, STANCE, false)
    s:run(1.5)
    check(shieldsUp == shieldsBefore + 1 and figureShields() == shieldsBefore,
        string.format("the host's figure shielded for the guest while the guard is up, so the guest's blows don't flinch it (%d, %d, %d)",
            shieldsBefore, shieldsUp, figureShields()))
    check(during:find("Defence", 1, true) ~= nil and after:find("StanceEnter", 1, true) ~= nil,
        "a guard held on after its answer to a blow: the figure turns the blow aside, then stands in the guard again: "
        .. during:match("[^.]+$") .. " then " .. after:match("[^.]+$"))
    blow("block")
    check(parries() == 1, "nor a guard answer that cost posture: " .. parries())
    blow("none")
    check(parries() == 1, "nor a blow that never reached the host: " .. parries())
    Session.startMove(h, DEFENCE)
    s:run(0.5)
    Session.endMove(h)
    s:run(1.6)
    check(parries() == 1, "nor a guard answer with no attack of the guest's (its always-on passive isn't one): " .. parries())
    beside(600)
    blow("parry")
    check(parries() == 1, "nor a deflect of a foe out of reach: " .. parries())
    -- (In PvPvE an enemy's blow turned aside while the partner swung nearby, at something else, staggered the partner.)
    beside(150, true)
    blow("parry")
    check(parries() == 1, "nor a deflect while the guest's move was aimed away from the host (another's blow): " .. parries())
    beside(150)
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
    s:run(0.01)
    Fake.running(h, h.pawn, STANCE, true)
    Session.startMove(h, DEFENCE)
    s:run(0.4)
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
    Fake.running(h, h.pawn, STANCE, false)
    Session.endMove(h)
    s:run(1.6)
    check(parries() == 1, "nor a guard answer as the guest's move began, before its blow could have come: " .. parries())
    blow("parry")
    check(parries() == 2, "and the next deflect in reach, facing the host, is one again: " .. parries())
    Fake.running(g, g.pawn, "GA_Hun_ShachiHook_Passive_C", false)

    out("round 1, the guest goes down:")
    Session.command(g, "arena down")
    s:run(1)
    check(count(g.sent, "^E AR down") == 1, "the guest says it's down")
    check(hm.score[1] == 1 and hm.score[2] == 0, "the host scores it 1 - 0: " .. hm.score[1] .. " - " .. hm.score[2])
    check(gm.score[1] == 1, "the guest hears the score")
    s:run(4.5)
    check(hm.round == 2 and gm.round == 2, "round 2 counts down: " .. hm.round .. "/" .. gm.round)
    s:run(3.5)
    check(hm.phase == "fight" and gm.phase == "fight", "round 2 is on")

    out("round 2, the host goes down:")
    Session.command(h, "arena down")
    s:run(1)
    check(hm.score[2] == 1 and gm.score[2] == 1, "1 - 1 on both")
    s:run(8)
    check(hm.round == 3 and hm.phase == "fight", "round 3 is on: " .. hm.round .. " " .. hm.phase)

    out("round 3 and the end:")
    Session.command(g, "arena down")
    s:run(1)
    check(hm.score[1] == 2, "2 - 1 to Crimson (the host)")
    s:run(3)
    check(hm.phase == "finish" and gm.phase == "finish", "the finishing window: " .. hm.phase .. "/" .. gm.phase)
    Session.command(h, "arena finish 2 2")
    s:run(1)
    check(count(h.sent, "^E AR fin") == 1, "the host finishes the guest: " .. last(h.sent, "^E AR fin"))
    check(gm.finished == 2, "the guest's world knows it's the one finished")
    check(count(g.logs, "finishes") == 1 and count(h.logs, "finishes") == 1, "both worlds play the move")
    local clock = (h.env.os and h.env.os.clock) or os.clock
    check(hm.finishUntil > clock() + 2, "the result waits for the move: " .. string.format("%.1f s", hm.finishUntil - clock()))
    s:run(6)
    check(hm.phase == "result" or ha.match == nil, "the results: " .. tostring(ha.match and ha.match.phase))
    s:run(8)
    check(ha.match == nil and ga.match == nil, "both went home")
    s:run(5)
    check(not h.env.PBZ.net.arena and not g.env.PBZ.net.arena, "the network is whole again")
    check(not h.env.PBZ.net.pvp and not g.env.PBZ.net.pvp, "nobody fights after it")
    -- (The game's DeactivateAllNodes took a player's own nodes too, and nothing put them back: the next save kept that.)
    check(onNodes(h) == OWN and h.slots.HeiShi == true, "home: the host's own three nodes on, its talisman slot open: " .. onNodes(h))
    check(onNodes(g) == "", "the guest's tree as it was, nothing on: " .. onNodes(g))
    check(math.abs(attack(h) - attack0) < 0.5, string.format("and its attack its own again, %.0f, not the match's: %.0f",
        attack0, attack(h)))
    check(count(h.treeCalls, "AllNodes") == 0 and count(g.treeCalls, "AllNodes") == 0
        and count(h.treeCalls, "^DeactivateNode HeiShi1$") == 0, "the whole tree never switched, nor a node of the player's own")

    out("Death, a 60 s clock, decided by the clock:")
    Session.command(h, "arena mode death")
    Session.command(h, "arena timer 60")
    Session.command(g, "arena ready")
    s:run(1.5)
    Session.command(h, "arena start")
    s:run(7)
    local dm, dg = ha.match, ga.match
    check(dm and dg and dm.mode == "death" and dm.timer == 60 and dm.phase == "fight" and dg.phase == "fight",
        "a Death match with a 60 s clock is on: " .. tostring(dm and dm.mode) .. " " .. tostring(dm and dm.timer))
    local fins = count(h.sent, "^E AR fin")
    Fake.setHealth(g.pawn, 700)         -- (the guest behind on health as the clock runs out)
    s:run(30)
    check(dm.phase == "fight", "half way, still on: " .. tostring(dm.phase))
    s:run(33)
    check(dm.score[1] == 1 and dm.winner == 1 and dm.phase == "finish",
        string.format("at zero the clock gives it to the host, ahead on health: %d - %d, %s", dm.score[1], dm.score[2], dm.phase))
    check(dg.phase == "finish" and dg.winner == 1, "the guest's world has the same end: " .. tostring(dg.phase))
    Session.command(h, "arena finish 2 1")
    s:run(1)
    check(count(h.sent, "^E AR fin") == fins + 1 and dg.finished == 2, "the host finishes the guest, one life, no more rounds")
    s:run(16)
    check(ha.match == nil and ga.match == nil, "both home after the results")
    s:run(5)

    out("a guest leaving ends it:")
    Session.command(g, "arena ready")
    s:run(1.5)
    Session.command(h, "arena start")
    s:run(7)
    check(ha.match and ga.match and ha.match.phase == "fight", "a second match is on")
    Session.command(g, "arena leave")
    s:run(2)
    check(ha.match == nil and ga.match == nil, "the guest left: both home")
    s:run(5)

    local function errorsIn(sess, label)
        local n = 0
        for _, pc in ipairs(sess.pcs) do
            for _, e in ipairs(pc.errors) do
                n = n + 1
                if n <= 6 then out("  error " .. label .. " " .. tostring(pc.name or pc.id) .. ": " .. e) end
            end
        end
        return n
    end
    local errors = errorsIn(s, "duel")
    for _, pc in ipairs(s.pcs) do
        for _, l in ipairs(pc.logs) do
            if l:find("arena:") or l:find("PvP") then
                out("    " .. tostring(pc.name or pc.id) .. " " .. l:sub(1, 220))
            end
        end
    end

    out("three players, teams: the host alone against two guests:")
    local t = Session.new(scripts, { "Host", "Guest", "Guest" }, 3,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    local p1, p2, p3 = t.pcs[1], t.pcs[2], t.pcs[3]
    t:run(5)
    Session.moveTo(p1, 0, 0)
    Session.moveTo(p2, 400, 0)
    Session.moveTo(p3, 0, 400)
    t:run(3)
    local a1, a2, a3 = p1.env.PBZ.arena, p2.env.PBZ.arena, p3.env.PBZ.arena
    Session.command(p1, "arena place 0")
    Session.command(p1, "arena team 1")
    Session.command(p2, "arena team 2")
    Session.command(p3, "arena team 2")
    Session.command(p2, "arena ready")
    Session.command(p3, "arena ready")
    t:run(2)
    check(a1.blocker() == nil, "three ready, two teams: nothing stops the start: " .. tostring(a1.blocker()))
    Session.command(p1, "arena start")
    t:run(9)
    local m1, m2, m3 = a1.match, a2.match, a3.match
    check(m1 and m2 and m3 and m1.phase == "fight" and m2.phase == "fight" and m3.phase == "fight",
        "all three fight: " .. tostring(m1 and m1.phase) .. "/" .. tostring(m2 and m2.phase) .. "/" .. tostring(m3 and m3.phase))
    check(m1 and m1.teams[1] == 1 and m1.teams[2] == 2 and m1.teams[3] == 2, "the teams as picked")
    -- A teammate's bar over the player's own (its frame's middle at 316, 902 on a screen 1080 high): on each guest's screen
    -- the other guest's, on the lone host's none.
    local function mateBar(pc)
        for _, w in ipairs(pc.widgets or {}) do
            local f = rawget(w, "__fields") or {}
            local at = f.position
            if at and math.abs(at.X - 316) < 1 and math.abs(at.Y - 902) < 1 and not f.removed then
                return true
            end
        end
        return false
    end
    check(mateBar(p2) and mateBar(p3) and not mateBar(p1), "a teammate's bar on each guest's screen, none on the lone host's")
    Session.command(p2, "arena down")
    t:run(3)
    check(m1 and m1.phase == "fight" and m1.down[2], "one Azure down, the other fights on: " .. tostring(m1 and m1.phase))
    check(m2 and m2.phase == "out", "the fallen guest is out of the round: " .. tostring(m2 and m2.phase))
    check(m2 and m2.watching == true and p2.env.PBZ.net.arenaWatching == true,
        "the fallen guest's camera is on its teammate: " .. tostring(m2 and m2.watching))
    Session.command(p3, "arena down")
    t:run(1.5)
    check(m1 and m1.score[1] == 1 and m1.score[2] == 0, "both Azure down: the round to Crimson, 1 - 0: " ..
        tostring(m1 and m1.score[1]) .. " - " .. tostring(m1 and m1.score[2]))
    t:run(6)
    check(m2 and m2.round == 2 and not m2.watching and not p2.env.PBZ.net.arenaWatching,
        "round 2: everyone up, the camera back: round " .. tostring(m2 and m2.round))
    Session.command(p1, "arena leave")
    t:run(3)
    check(a1.match == nil and a2.match == nil and a3.match == nil, "the host left: all three home")
    errors = errors + errorsIn(t, "teams")
    check(errors == 0, "no script errors: " .. errors)
    out(failed == 0 and "PASS" or ("FAILED " .. failed))
    return failed == 0
end
