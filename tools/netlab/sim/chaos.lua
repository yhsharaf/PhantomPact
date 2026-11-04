-- Chaos run for parties (luasim.py chaos [seeds] [steps]): a host and up to five guests on the mod's real scripts, and
-- a seeded random stream of what players do (move, leave and come back, change maps, hit and kill, die and respawn,
-- sit at a bell, fight a boss), as the real game has them: a sit brings no enemy back. After every step and at the end, what must always hold is checked. A failure prints the seed and the
-- step, so it can be played again exactly.

local Session = dofile(SIM_DIR .. "/session.lua")
local Fake = Session.Fake

local THUG = "BP_Monster_MaleThug_C"
local ENEMIES = {
    { "thug1", THUG, 1500.0, 300.0, 100.0, 600, 100 },
    { "thug2", THUG, -1800.0, 200.0, 100.0, 600, 100 },
    { "near", THUG, 300.0, 300.0, 100.0, 600, 100 },
    { "mid", THUG, 2500.0, -1200.0, 100.0, 600, 100 },
    { "guestside", THUG, 15000.0, 0.0, 100.0, 600, 100 },
    { "toofar", THUG, 40000.0, 0.0, 100.0, 600, 100 },
    { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
}

return function(out, scripts, seeds, steps)
    local failures = 0
    local function field(o, name)
        return rawget(o, "__fields")[name]
    end

    local function twinsOn(pc)
        local live = {}
        for _, e in ipairs(pc.enemies) do
            local id = e:IsValid() and pc.env.PBZ.game.twinId(e:GetAddress())
            if id then
                live[id] = e
            end
        end
        return live
    end

    -- What must hold at any moment. Returns a list of what doesn't.
    local function invariants(s, settled)
        local bad = {}
        for i, pc in ipairs(s.pcs) do
            if #pc.errors > 0 then
                bad[#bad + 1] = "pc" .. i .. " script error: " .. pc.errors[1]
            end
        end
        local h = s.pcs[1]
        -- One live twin at most for each original, on the host.
        local per = {}
        for id, e in pairs(twinsOn(h)) do
            if not field(e, "dead") then
                local orig = id:match("^tw%d+:(.+)$") or id
                per[orig] = (per[orig] or 0) + 1
                if per[orig] == 2 then
                    bad[#bad + 1] = "host has two live twins of " .. orig
                end
            end
        end
        -- A twin is never a boss to the mod, on any PC.
        for i, pc in ipairs(s.pcs) do
            for id, e in pairs(twinsOn(pc)) do
                if pc.env.PBZ.game.isBoss(e) then
                    bad[#bad + 1] = "pc" .. i .. " takes twin " .. id .. " for a boss"
                end
            end
        end
        if settled then
            -- Everyone together and connected for a while: no guest has a live twin the host hasn't got alive.
            local hostLive = {}
            for id, e in pairs(twinsOn(h)) do
                hostLive[id] = not field(e, "dead")
            end
            for i = 2, #s.pcs do
                for id, e in pairs(twinsOn(s.pcs[i])) do
                    if not field(e, "dead") and not hostLive[id] then
                        bad[#bad + 1] = "pc" .. i .. " keeps twin " .. id .. " the host hasn't got alive"
                    end
                end
            end
            -- Every guest knows it's in a party of the host's size.
            if #s.pcs > 2 then
                for i = 2, #s.pcs do
                    local n = s.pcs[i].env.PBZ.net
                    if n.party ~= #s.pcs then
                        bad[#bad + 1] = "pc" .. i .. " thinks the party is " .. tostring(n.party)
                    end
                end
            end
            -- An enemy dead on the host is dead on each guest's copy of it (spawner ids: the same enemy in every world).
            for _, def in ipairs(ENEMIES) do
                local he = Session.enemyOn(h, def[1])
                if he and field(he, "dead") then
                    for i = 2, #s.pcs do
                        local ge = Session.enemyOn(s.pcs[i], def[1])
                        local sticky = s.pcs[i].env.PBZ.net.matchSticky or {}
                        if ge and sticky["sp:" .. def[1]] == ge:GetAddress() and not field(ge, "dead") then
                            bad[#bad + 1] = "pc" .. i .. " has " .. def[1] .. " alive, dead on the host"
                        end
                    end
                elseif he then
                    -- Alive on the host: a guest's copy the host's lines steer has its own AI stopped.
                    for i = 2, #s.pcs do
                        local ge = Session.enemyOn(s.pcs[i], def[1])
                        local sticky = s.pcs[i].env.PBZ.net.matchSticky or {}
                        if ge and sticky["sp:" .. def[1]] == ge:GetAddress() and not field(ge, "dead") then
                            local brain = field(field(ge, "Controller"), "BrainComponent")
                            if field(brain, "running") then
                                bad[#bad + 1] = "pc" .. i .. "'s copy of " .. def[1] .. " runs its own AI while the host's lines steer it"
                            end
                        end
                    end
                end
            end
            -- Every PC has a ghost for every other player, shown (all on one map, all connected).
            for i, pc in ipairs(s.pcs) do
                local n = pc.env.PBZ.net
                for slot = 1, #s.pcs do
                    if slot ~= i then
                        local p
                        if #s.pcs == 2 then
                            p = n
                        elseif slot == 1 and n.slot ~= 1 then
                            p = n
                        else
                            p = n.peers[slot]
                        end
                        if not (p and p.ghost and pc.env.PBZ.valid(p.ghost)) then
                            bad[#bad + 1] = "pc" .. i .. " has no ghost for player " .. slot
                        elseif p.ghostHidden then
                            bad[#bad + 1] = "pc" .. i .. " hides player " .. slot .. "'s ghost"
                        end
                    end
                end
            end
            -- No boss fight shown anywhere for a boss the host has dead.
            local hb = Session.enemyOn(h, "boss")
            if hb and field(hb, "dead") then
                for i, pc in ipairs(s.pcs) do
                    if pc.env.PBZ.game.bossFightActive() then
                        bad[#bad + 1] = "pc" .. i .. " still shows a boss fight, the boss dead on the host"
                    end
                end
            end
        end
        return bad
    end

    local function oneRun(seed, players, nsteps, sabotage)
        math.randomseed(seed * 7919 + players)
        local roles = { "Host" }
        for _ = 2, players do
            roles[#roles + 1] = "Guest"
        end
        local s = Session.new(scripts, roles, players > 2 and players or false, ENEMIES)
        local h = s.pcs[1]
        local home = h.map
        for i = 2, players do
            Session.moveTo(s.pcs[i], 200 * i, 0)
        end
        s:run(8)
        local log = {}
        local function pick(from)
            return s.pcs[math.random(from or 1, #s.pcs)]
        end
        local function name(pc)
            for i, p in ipairs(s.pcs) do
                if p == pc then
                    return "pc" .. i
                end
            end
            return "?"
        end
        local actions = {
            function()
                local pc = pick()
                local x, y = math.random(-4000, 4000), math.random(-4000, 4000)
                Session.moveTo(pc, x, y)
                return "move " .. name(pc) .. string.format(" %d %d", x, y)
            end,
            function()
                local pc = pick(2)
                pc.cut = not pc.cut
                return (pc.cut and "cut " or "back ") .. name(pc)
            end,
            function()
                local pc = pick(2)
                pc.map = pc.map == home and "Map_Other" or home
                return "map " .. name(pc) .. " " .. pc.map
            end,
            function()
                local def = ENEMIES[math.random(1, #ENEMIES)]
                local e = Session.enemyOn(h, def[1])
                if e and not field(e, "dead") then
                    e:Kill(1)
                    return "host kills " .. def[1]
                end
                return "host kills nothing"
            end,
            function()
                local pc = pick(2)
                local def = ENEMIES[math.random(1, #ENEMIES)]
                local e = Session.enemyOn(pc, def[1])
                if e and not field(e, "dead") then
                    pc.env.PBZ.game.noteLocalMove()
                    local hp = select(1, Fake.health(e))
                    local to = math.random() < 0.3 and 1 or math.max(1, hp - 100)
                    Fake.setHealth(e, to)
                    return name(pc) .. " hits " .. def[1] .. " to " .. to
                end
                return name(pc) .. " hits nothing"
            end,
            function()
                local pc = pick()
                local twins = {}
                for id, e in pairs(twinsOn(pc)) do
                    if not field(e, "dead") then
                        twins[#twins + 1] = { id = id, e = e }
                    end
                end
                if #twins == 0 then
                    return name(pc) .. " finds no twin"
                end
                table.sort(twins, function(a, b) return a.id < b.id end)
                local t = twins[math.random(1, #twins)]
                pc.env.PBZ.game.noteLocalMove()
                Fake.setHealth(t.e, 1)
                return name(pc) .. " hits twin " .. t.id
            end,
            function()
                local pc = pick()
                Session.sit(pc)
                return "sit " .. name(pc)
            end,
            function()
                local pc = pick()
                Session.die(pc)
                s:run(2)
                Session.respawned(pc)
                Session.revive(pc)
                return "dies and respawns " .. name(pc)
            end,
            function()
                local boss = Session.enemyOn(h, "boss")
                if boss and not field(boss, "dead") then
                    h.hudLayout:RegisterBossHPBar(boss)
                    return "boss fight starts"
                end
                return "no boss to fight"
            end,
        }
        for step = 1, nsteps do
            local a = actions[math.random(1, #actions)]
            log[#log + 1] = a()
            s:run(math.random(1, 3))
            local bad = invariants(s, false)
            if #bad > 0 then
                out(string.format("  FAIL seed %d, %d players, step %d (%s): %s", seed, players, step, log[#log], bad[1]))
                for k = math.max(1, #log - 6), #log do
                    out("       " .. k .. ": " .. log[k])
                end
                return false
            end
        end
        -- Everyone back, on the host's map, near the host, for long enough for stale copies to go.
        for i = 2, #s.pcs do
            s.pcs[i].cut = sabotage == true and i == 2
            s.pcs[i].map = home
            Session.moveTo(s.pcs[i], 200 * i, 0)
        end
        Session.moveTo(h, 0, 0)
        s:run(30)
        local bad = invariants(s, true)
        if #bad > 0 then
            out(string.format("  FAIL seed %d, %d players, settled: %s", seed, players, bad[1]))
            for k = 2, math.min(#bad, 4) do
                out("       also: " .. bad[k])
            end
            for k = math.max(1, #log - 8), #log do
                out("       " .. k .. ": " .. log[k])
            end
            -- What each PC said of the enemy in question.
            local who, what = bad[1]:match("^pc(%d+) has (%S+) alive")
            if who then
                for i, pc in ipairs({ h, s.pcs[tonumber(who)] }) do
                    for _, line in ipairs(pc.logs) do
                        if line:find(what, 1, true) or line:find("rest", 1, true) or line:find("respawn", 1, true) then
                            out("       pc" .. (i == 1 and 1 or who) .. " said: " .. line)
                        end
                    end
                end
                out("       steps: " .. table.concat(log, " / "))
            end
            return false
        end
        return true
    end

    seeds = seeds or 6
    steps = steps or 40
    -- The checker itself: a guest left cut off at the end must be caught.
    local quiet = out
    out = function() end
    local ok2, res2 = pcall(oneRun, 1, 4, 10, true)
    out = quiet
    local caught = ok2 and res2 == false
    out("  " .. (caught and "ok   " or "FAIL ") .. "the checker catches a guest left cut off")
    if not caught then
        failures = failures + 1
    end
    for seed = 1, seeds do
        for _, players in ipairs({ 3, 4, 6 }) do
            local ok, res = pcall(oneRun, seed, players, steps)
            if not ok then
                out(string.format("  FAIL seed %d, %d players: the run broke: %s", seed, players, tostring(res)))
                failures = failures + 1
            elseif res == false then
                failures = failures + 1
            else
                out(string.format("  ok   seed %d, %d players, %d steps", seed, players, steps))
            end
        end
    end
    return failures == 0
end
