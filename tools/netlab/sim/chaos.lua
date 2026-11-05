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
        -- (fuzz) what the new invariants need to know, kept each frame
        local function isDead(e)
            return field(e, "dead") == true or select(1, Fake.health(e)) <= 0
        end
        local st = { deaths = {}, prevDead = {}, hostDeadSince = {}, ownFight = {}, fightMap = {}, lastFightAt = -1e9,
            since = {}, mapSince = {}, aliveSince = {}, brought = {}, lootTo = {}, sentAt = 0, offSync = {}, cutSince = {}, removedOn = {} }
        s.st = st
        for _, pc in ipairs(s.pcs) do
            pc.reviveOnRest = true
        end
        local function stubLoot()
            h.env.PBZ.game.rollLoot = function() return 0, { { id = "R_7", count = 1, kind = "-" } }, 1 end
        end
        stubLoot()
        local function connected(pc)
            local hostOn = h.relay ~= nil and h.slot ~= nil
            if pc == h then
                return hostOn
            end
            -- (a cut player counts until the mod could know: 12 s of silence, and a margin)
            return hostOn and pc.relay ~= nil and pc.slot ~= nil and not (pc.cut and st.cutSince[pc] and h.now - st.cutSince[pc] > 15)
        end
        local function inSession(pc)
            for _, p in ipairs(s.pcs) do
                if p == pc then
                    return true
                end
            end
            return false
        end
        local function track()
            local now = h.now
            for _, pc in ipairs(s.pcs) do
                st.cutSince[pc] = pc.cut and (st.cutSince[pc] or now) or nil
            end
            for _, def in ipairs(ENEMIES) do
                local e = Session.enemyOn(h, def[1])
                if e then
                    local d = isDead(e)
                    local key = "sp:" .. def[1]
                    if d and not st.prevDead[e] then
                        st.deaths[key] = (st.deaths[key] or 0) + 1
                    end
                    st.prevDead[e] = d
                    st.hostDeadSince[def[1]] = d and (st.hostDeadSince[def[1]] or now) or nil
                end
                for i = 2, #s.pcs do
                    local pc = s.pcs[i]
                    local ge = Session.enemyOn(pc, def[1])
                    local k = pc.id .. "|" .. def[1]
                    st.aliveSince[k] = (ge and not isDead(ge)) and (st.aliveSince[k] or now) or nil
                end
            end
            for id, e in pairs(twinsOn(h)) do
                local d = isDead(e)
                if d and not st.prevDead[e] then
                    st.deaths[id] = (st.deaths[id] or 0) + 1
                end
                st.prevDead[e] = d
            end
            local n = 0
            for _, pc in ipairs(s.pcs) do
                local c = connected(pc)
                n = n + (c and 1 or 0)
                st.since[pc] = c and (st.since[pc] or now) or nil
                st.mapSince[pc] = (c and not pc.cut and pc.map == h.map) and (st.mapSince[pc] or now) or nil
            end
            st.fewerSince = n < 5 and (st.fewerSince or now) or nil
            -- A player's own fight ends as the game ends it: the boss dies there, the player dies, or the map goes.
            for pc, boss in pairs(st.ownFight) do
                if not inSession(pc) then
                    st.ownFight[pc] = nil
                elseif isDead(boss) or field(pc.pawn, "dead") or pc.map ~= st.fightMap[pc] then
                    st.ownFight[pc] = nil
                    pc.hudLayout:UnRegisterBossHPBar(boss)
                end
            end
            if next(st.ownFight) then
                st.lastFightAt = now
            end
            -- What a bring-back claimed, the game spawns.
            for _, b in ipairs(st.brought) do
                if not b.back and (field(b.sp, "claimed") or 0) > b.claimed0 then
                    b.back = true
                    Fake.put(b.actor, "dead", false)
                    Fake.put(b.actor, "killedBy", nil)
                    Fake.setHealth(b.actor, select(2, Fake.health(b.actor)))
                    table.insert(b.pc.enemies, b.actor)
                    Fake.put(b.sp, "SpawnedAI", b.actor)
                end
            end
        end
        local baseRun = s.run
        s.run = function(self, seconds, each)
            return baseRun(self, seconds, function()
                track()
                if each then
                    each()
                end
            end)
        end
        local function stepChecks()
            local bad = {}
            local now = h.now
            stubLoot()
            -- No kill's loot told twice to anyone.
            local function add(slot, nm)
                local k = slot .. "|" .. nm
                st.lootTo[k] = (st.lootTo[k] or 0) + 1
                if st.lootTo[k] > (st.deaths[nm] or 0) then
                    bad[#bad + 1] = string.format("loot for %s sent to slot %d %d times, it died %d times on the host", nm, slot,
                        st.lootTo[k], st.deaths[nm] or 0)
                end
            end
            for k = st.sentAt + 1, #h.sent do
                local line = h.sent[k]
                local slot, nm = line:match("^T(%d+) I loot:(%S+) ")
                if slot then
                    add(tonumber(slot), nm)
                else
                    nm = line:match("^E I loot:(%S+) ")
                    if nm then
                        for sl = 2, #s.pcs do
                            add(sl, nm)
                        end
                    end
                end
            end
            st.sentAt = #h.sent
            -- An enemy the host killed stays dead on every guest on its map.
            for _, def in ipairs(ENEMIES) do
                local since = st.hostDeadSince[def[1]]
                if since and now - since > 10 then
                    for i = 2, #s.pcs do
                        local pc = s.pcs[i]
                        local ms = st.mapSince[pc]
                        local as = st.aliveSince[pc.id .. "|" .. def[1]]
                        local ge = Session.enemyOn(pc, def[1])
                        local sticky = pc.env.PBZ.net.matchSticky or {}
                        if ms and now - ms > 10 and as and now - as > 6 and ge and sticky["sp:" .. def[1]] == ge:GetAddress() then
                            bad[#bad + 1] = string.format("pc%d has %s alive %.0f s, dead on the host %.0f s", i, def[1], now - as, now - since)
                        end
                    end
                end
            end
            -- No boss bar or fog wall anywhere while nobody's in a fight.
            if now - st.lastFightAt > 20 then
                for i, pc in ipairs(s.pcs) do
                    if pc.env.PBZ.game.bossFightActive() and now - (pc.backAt or -1e9) > 8 then
                        bad[#bad + 1] = "pc" .. i .. " shows a boss fight, nobody's been in one for " .. math.floor(now - st.lastFightAt) .. " s"
                    end
                    if next(pc.env.PBZ.net.foggedBosses or {}) then
                        bad[#bad + 1] = "pc" .. i .. " keeps a fog wall up, nobody's in a fight"
                    end
                end
            end
            -- Fewer than five connected for a while: no ghost twin.
            if st.fewerSince and now - st.fewerSince > 45 then
                for i, pc in ipairs(s.pcs) do
                    if i == 1 or (st.since[pc] and now - st.since[pc] > 30) then
                        for id, e in pairs(twinsOn(pc)) do
                            if not isDead(e) then
                                bad[#bad + 1] = string.format("pc%d has twin %s, fewer than 5 connected for %.0f s", i, id, now - st.fewerSince)
                                break
                            end
                        end
                    end
                end
            end
            return bad
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
                if not pc.cut then
                    pc.backAt = h.now       -- (what it missed comes all at once: a few seconds to settle)
                end
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
                    st.ownFight[h], st.fightMap[h] = boss, h.map
                    return "boss fight starts"
                end
                return "no boss to fight"
            end,
            function()
                local pc = pick(2)
                local boss = Session.enemyOn(pc, "boss")
                if boss and not field(boss, "dead") and not pc.cut then
                    Session.moveTo(pc, 2800, 3000)
                    pc.hudLayout:RegisterBossHPBar(boss)
                    st.ownFight[pc], st.fightMap[pc] = boss, pc.map
                    return name(pc) .. " starts the boss fight"
                end
                return name(pc) .. " finds no boss"
            end,
            function()
                local pc = pick(2)
                local boss = Session.enemyOn(pc, "boss")
                if boss and not field(boss, "dead") then
                    pc.env.PBZ.game.noteLocalMove()
                    Fake.setHealth(boss, 1)
                    return name(pc) .. " strikes the boss to 1"
                end
                return name(pc) .. " finds no boss"
            end,
            function()
                local pc = pick(2)
                if pc.cut then
                    return name(pc) .. " is cut off"
                end
                Session.command(pc, "netoff")
                s:run(1)
                Session.command(pc, "neton client")
                st.offSync[pc] = nil
                return name(pc) .. " turns sync off and on"
            end,
            function()
                if math.random() < 0.5 then
                    return "host keeps sync"
                end
                Session.command(h, "netoff")
                s:run(1)
                Session.command(h, "neton host")
                return "host turns sync off and on"
            end,
            -- (fuzz) new actions
            function()
                local pc = pick()
                Session.bell(pc)
                return "rests at a bell, world refreshed: " .. name(pc)
            end,
            function()
                local i = math.random(2, #s.pcs)
                local old = s.pcs[i]
                if not old.slot or st.offSync[old] then
                    return "pc" .. i .. " has no slot to take"
                end
                old.cut = true
                s:run(4)
                local slot = old.slot
                s.relay.slots[slot] = nil
                old.slot, old.relay = nil, nil
                for k, p in ipairs(s.relay.pcs) do
                    if p == old then
                        table.remove(s.relay.pcs, k)
                        break
                    end
                end
                local link = {}
                st.newcomers = (st.newcomers or 0) + 1
                local pc = Fake.new("pc" .. i .. "n" .. st.newcomers, scripts, Session.ini("Guest", false), link)
                pc.now = h.now
                for k, v in pairs(s.relay:linkFor(pc)) do
                    link[k] = v
                end
                s.relay:add(pc, h.now)
                for _, e in ipairs(ENEMIES) do
                    Fake.enemy(pc, e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8])
                end
                Fake.pickup(pc, "pickup1", "R_500", 300.0, 0.0, 100.0)
                Fake.pickup(pc, "pickup2", "R_501", 90000.0, 0.0, 100.0)
                Fake.chest(pc, "BP_Chest_C_1", 400.0, 400.0, 100.0)
                pc.reviveOnRest = true
                pc.lastSlot = slot
                pc.map = h.map
                s.pcs[i] = pc
                Fake.start(pc)
                Session.moveTo(pc, 200 * i, 0)
                return "pc" .. i .. " goes silent; a new player takes slot " .. slot
            end,
            function()
                local pc = pick(2)
                local boss = Session.enemyOn(pc, "boss")
                if not boss or isDead(boss) or pc.cut then
                    return name(pc) .. " finds no boss to die to"
                end
                Session.moveTo(pc, 2800, 3000)
                pc.hudLayout:RegisterBossHPBar(boss)
                st.ownFight[pc], st.fightMap[pc] = boss, pc.map
                s:run(math.random(1, 4))
                Session.die(pc)
                s:run(2)
                Session.respawned(pc)
                Session.revive(pc)
                return name(pc) .. " starts its own boss fight and dies in it"
            end,
            function()
                local pc = pick(2)
                local e = Session.enemyOn(pc, "toofar")
                if not e or isDead(e) then
                    return name(pc) .. " finds toofar dead"
                end
                Session.moveTo(pc, 39500, 0)
                s:run(2)
                pc.env.PBZ.game.noteLocalMove()
                Fake.setHealth(e, math.max(1, select(1, Fake.health(e)) - 100))
                s:run(0.5)
                pc.env.PBZ.game.noteLocalMove()
                Fake.setHealth(e, 0)
                Fake.put(e, "dead", true)
                return name(pc) .. " kills toofar, far from the host (GK)"
            end,
            function()
                local pc = pick(2)
                local ids = { "thug1", "thug2", "near", "mid" }
                local id = ids[math.random(1, #ids)]
                local i = Session.indexOf(pc, id)
                local sp = pc.spawners[i]
                local e = field(sp, "SpawnedAI")
                if not e then
                    return name(pc) .. " has " .. id .. " gone already"
                end
                for k, x in ipairs(pc.enemies) do
                    if x == e then
                        table.remove(pc.enemies, k)
                        break
                    end
                end
                Fake.put(e, "dead", true)
                Fake.setHealth(e, 0)
                Fake.put(sp, "record", false)
                Fake.put(sp, "SpawnedAI", nil)
                st.removedOn[pc.id .. "|" .. id] = true
                st.brought[#st.brought + 1] = { pc = pc, sp = sp, actor = e, claimed0 = field(sp, "claimed") or 0, id = id }
                return name(pc) .. "'s world loses " .. id .. " (dead in its save)"
            end,
            function()
                -- (Off unless FUZZ_TRAVEL: the fake keeps the same actors across a map change, so travel gives false failures.)
                if not os.getenv("FUZZ_TRAVEL") then
                    return "host stays"
                end
                Session.loadMap(h)
                h.map = h.map == home and "Map_Other" or home
                return "host travels to " .. h.map
            end,
            function()
                local pc = pick(2)
                if pc.cut then
                    return name(pc) .. " is cut off"
                end
                if st.offSync[pc] then
                    st.offSync[pc] = nil
                    Session.command(pc, "neton client")
                    return name(pc) .. " turns sync back on"
                end
                st.offSync[pc] = true
                Session.command(pc, "netoff")
                return name(pc) .. " turns sync off for a while"
            end,
        }
        for step = 1, nsteps do
            local a = actions[math.random(1, #actions)]
            local t0 = h.now
            log[#log + 1] = string.format("[%.1f] ", t0) .. a()
            s:run(math.random(1, 3))
            local bad = invariants(s, false)
            for _, b in ipairs(stepChecks()) do
                bad[#bad + 1] = b
            end
            if #bad > 0 then
                out(string.format("  FAIL seed %d, %d players, step %d (%s): %s", seed, players, step, log[#log], bad[1]))
                for k = 2, math.min(#bad, 4) do
                    out("       also: " .. bad[k])
                end
                if os.getenv("FUZZ_DUMP") then
                    for i, pc in ipairs(s.pcs) do
                        for _, a in ipairs(pc.env.PBZ.game.bossActors()) do
                            local tid = pc.env.PBZ.game.twinId(a:GetAddress())
                            out(string.format("       pc%d bar on %s twin=%s spawnerBoss=%s matched=%s", i, tostring(rawget(a, "__name")),
                                tostring(tid), tostring(a == Session.enemyOn(pc, "boss")),
                                tostring(pc.env.PBZ.coop.enemyActor and pc.env.PBZ.coop.enemyActor("sp:boss") == a) .. " actor=" .. tostring(pc.env.PBZ.coop.enemyActor and pc.env.PBZ.coop.enemyActor("sp:boss") and rawget(pc.env.PBZ.coop.enemyActor("sp:boss"), "__name")) .. " sticky=" .. tostring((pc.env.PBZ.net.matchSticky or {})["sp:boss"]) .. " addr=" .. tostring(a:GetAddress())))
                        end
                    end
                    for i, pc in ipairs(s.pcs) do
                        for li, line in ipairs(pc.logs) do
                            if (function() for pat in os.getenv("FUZZ_DUMP"):gmatch("[^;]+") do if line:find(pat) then return true end end end)() then
                                out(string.format("       %.1f pc%d (%s): %s", pc.logTimes[li] or 0, i, pc.id, line))
                            end
                        end
                    end
                end
                for k = 1, #log do
                    out("       " .. k .. ": " .. log[k])
                end
                return false
            end
        end
        -- Everyone back, on the host's map, near the host, for long enough for stale copies to go.
        if h.map ~= home then
            Session.loadMap(h)
            h.map = home
        end
        for pc in pairs(st.offSync) do
            if inSession(pc) then
                Session.command(pc, "neton client")
            end
        end
        st.offSync = {}
        for i = 2, #s.pcs do
            s.pcs[i].cut = sabotage == true and i == 2
            s.pcs[i].map = home
            Session.moveTo(s.pcs[i], 200 * i, 0)
        end
        Session.moveTo(h, 0, 0)
        s:run(30)
        local bad = invariants(s, true)
        for _, b in ipairs(stepChecks()) do
            bad[#bad + 1] = b
        end
        if not sabotage then
            -- (fuzz) settled: each PC in the slot of its place, and every guest has the host's live twins
            local hostLive = {}
            for id, e in pairs(twinsOn(h)) do
                if not isDead(e) then
                    hostLive[id] = field(e, "loc")
                end
            end
            for i = 2, #s.pcs do
                if s.pcs[i].slot ~= i then
                    bad[#bad + 1] = "pc" .. i .. " is in slot " .. tostring(s.pcs[i].slot)
                end
                local mine = twinsOn(s.pcs[i])
                local gl = field(s.pcs[i].pawn, "loc")
                for id, tl in pairs(hostLive) do
                    local near = (tl.X - gl.X) ^ 2 + (tl.Y - gl.Y) ^ 2 <= 9000 ^ 2     -- (a guest makes copies near it only)
                    local orig = id:match("^tw%d+:sp:(.+)$")
                    local removed = orig and st.removedOn[s.pcs[i].id .. "|" .. orig]   -- (fake: each enemy its own class; see report)
                    if near and not removed and (not mine[id] or isDead(mine[id])) then
                        bad[#bad + 1] = "pc" .. i .. " lacks the host's live twin " .. id
                        break
                    end
                end
            end
        end
        if #bad > 0 then
            out(string.format("  FAIL seed %d, %d players, settled: %s", seed, players, bad[1]))
            for k = 2, math.min(#bad, 4) do
                out("       also: " .. bad[k])
            end
            if os.getenv("FUZZ_DUMP") then
                for i, pc in ipairs(s.pcs) do
                    for li, line in ipairs(pc.logs) do
                        if (function() for pat in os.getenv("FUZZ_DUMP"):gmatch("[^;]+") do if line:find(pat) then return true end end end)() then
                            out(string.format("       %.1f pc%d (%s): %s", pc.logTimes[li] or 0, i, pc.id, line))
                        end
                    end
                end
            end
            for k = 1, #log do
                out("       " .. k .. ": " .. log[k])
            end
            -- What each PC said of the enemy in question.
            local who, what = bad[1]:match("^pc(%d+) has (%S+) alive")
            if who then
                for i, pc in ipairs({ h, s.pcs[tonumber(who)] }) do
                    for li, line in ipairs(pc.logs) do
                        if line:find(what, 1, true) or line:find("rest", 1, true) or line:find("respawn", 1, true) then
                            out("       pc" .. (i == 1 and 1 or who) .. " said: " .. line)
                        end
                    end
                end
                out("       steps: " .. table.concat(log, " / "))
            end
            return false
        end
        -- (fuzz) the session ends: every record a bring-back turned on is put back.
        if not sabotage then
            for i = 2, #s.pcs do
                Session.command(s.pcs[i], "netoff")
            end
            s:run(3)
            for _, b in ipairs(st.brought) do
                if inSession(b.pc) and field(b.sp, "record") == true then
                    local idx
                    for i, p in ipairs(s.pcs) do
                        if p == b.pc then
                            idx = i
                        end
                    end
                    out(string.format("  FAIL seed %d, %d players, session end: pc%d's spawner %s left on (back=%s)", seed, players, idx,
                        b.id, tostring(b.back)))
                    out("       steps: " .. table.concat(log, " / "))
                    return false
                end
            end
            for i, pc in ipairs(s.pcs) do
                if #pc.errors > 0 then
                    out(string.format("  FAIL seed %d, %d players, session end: pc%d script error: %s", seed, players, i, pc.errors[1]))
                    return false
                end
            end
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
    local from, to = 1, seeds
    if type(seeds) == "table" then
        from, to = seeds[1], seeds[2]
    end
    for seed = from, to do
        for _, players in ipairs(os.getenv("FUZZ_PLAYERS") and { tonumber(os.getenv("FUZZ_PLAYERS")) } or { 3, 4, 6 }) do
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
