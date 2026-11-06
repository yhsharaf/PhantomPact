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
    local s = Session.new(scripts, { "Host", "Guest" }, false,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(2)
    local ha, ga = h.env.PBZ.arena, g.env.PBZ.arena
    check(ha ~= nil and ga ~= nil, "both have the arena module")

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

    local errors = 0
    for _, pc in ipairs(s.pcs) do
        for _, e in ipairs(pc.errors) do
            errors = errors + 1
            if errors <= 6 then out("  error " .. tostring(pc.name or pc.id) .. ": " .. e) end
        end
    end
    for _, pc in ipairs(s.pcs) do
        for _, l in ipairs(pc.logs) do
            if l:find("arena:") or l:find("PvP") then
                out("    " .. tostring(pc.name or pc.id) .. " " .. l:sub(1, 220))
            end
        end
    end
    check(errors == 0, "no script errors: " .. errors)
    out(failed == 0 and "PASS" or ("FAILED " .. failed))
    return failed == 0
end
