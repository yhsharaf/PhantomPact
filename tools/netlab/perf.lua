-- Game-thread costs of the mod, measured inside the running game. Loaded with eval (dev installs only):
--   eval dofile("<path>/perf.lua") return PERF.single()      one-shot cost of each call the net loop makes
--   eval PERF.frames(10)                                     frame times for 10 s; PERF lines appear in the log
--   eval PERF.profile(10)                                    wraps the mod's calls, prints what each cost over 10 s
-- os.clock() has 1 ms steps here, so short calls are timed in loops and profile totals are sums of many samples.

local log, valid = PBZ.log, PBZ.valid
local game = PBZ.game
PERF = PERF or {}

local function say(...)
    log("PERF " .. string.format(...))
end

local function bench(name, n, fn)
    local t0 = os.clock()
    local ok, err = true, nil
    for _ = 1, n do
        ok, err = pcall(fn)
        if not ok then break end
    end
    local ms = (os.clock() - t0) * 1000
    say("%-34s %9.4f ms each (%d runs)%s", name, ms / n, n, ok and "" or (" ERROR " .. tostring(err)))
end

function PERF.single()
    local pc, pawn = PBZ.getPlayer1()
    local gs = PBZ.gs()
    bench("getPlayer1", 200, function() PBZ.getPlayer1() end)
    bench("FindFirstOf PlayerController", 200, function() FindFirstOf("PlayerController") end)
    bench("StaticFindObject GameplayStatics", 2000, function() StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    local counts = {}
    for _, name in ipairs({ "PBZCharacter_NPC", "AISpawner", "PBZPickupActor", "HitreactComponent", "FactionComponent", "PlayerController" }) do
        bench("FindAllOf " .. name, 20, function() counts[name] = #(FindAllOf(name) or {}) end)
        say("  %s: %s objects", name, tostring(counts[name]))
    end
    bench("listEnemies(fresh)", 20, function() game.listEnemies(true) end)
    bench("refreshEnemyIds(force)", 10, function() game.refreshEnemyIds(true) end)
    if valid(pawn) then
        bench("K2_GetActorLocation", 2000, function() return pawn:K2_GetActorLocation() end)
        bench("K2_GetActorRotation", 2000, function() return pawn:K2_GetActorRotation() end)
        bench("CharacterMovement.Velocity", 2000, function() return pawn.CharacterMovement.Velocity end)
        bench("getHealth", 2000, function() return game.getHealth(pawn) end)
        bench("getPosture", 2000, function() return game.getPosture(pawn) end)
        bench("inCutscene", 2000, function() return game.inCutscene() end)
        bench("mapName", 500, function() return game.mapName(pawn) end)
        bench("watchLocalPlayer", 50, function() game.watchLocalPlayer(pawn, function() end) end)
        bench("watchHitState", 500, function() game.watchHitState(pawn, function() end) end)
        bench("watchPickups", 20, function() game.watchPickups(pawn, function() end) end)
        bench("Mesh:GetAnimInstance", 1000, function() return pawn.Mesh:GetAnimInstance() end)
        local ai = pawn.Mesh:GetAnimInstance()
        bench("GetCurrentActiveMontage", 1000, function() return ai:GetCurrentActiveMontage() end)
        bench("valid(pawn)", 5000, function() return valid(pawn) end)
        bench("GetAddress", 5000, function() return pawn:GetAddress() end)
        local cmc = pawn.CharacterMovement
        bench("cmc.MaxWalkSpeed read", 5000, function() return cmc.MaxWalkSpeed end)
        bench("cmc.MaxWalkSpeed write", 5000, function() cmc.MaxWalkSpeed = cmc.MaxWalkSpeed end)
        bench("AddMovementInput", 2000, function() pawn:AddMovementInput({ X = 0.0, Y = 0.0, Z = 0.0 }, 0.0, false) end)
    end
    local dir = PBZ.coop and nil
    local path = (PBZ.modDir and PBZ.modDir() or "") .. "perf_test.txt"
    return "PERF single done"
end

-- The real file work of one snapshot, on this disk: a write through a temp file, then a read.
function PERF.files(dir, n)
    local tmp, path = dir .. "perf_test.txt.tmp", dir .. "perf_test.txt"
    local text = string.rep("E sp:SomeEnemyName 12345.6 -2345.6 678.9 123.4 5000.0 5000.0 0 100.0 BP_Enemy_C\n", 10)
    local total, worst, spikes = 0, 0, 0
    for _ = 1, n do
        local t0 = os.clock()
        local f = io.open(tmp, "w")
        f:write(text)
        f:close()
        if not os.rename(tmp, path) then
            os.remove(path)
            os.rename(tmp, path)
        end
        local r = io.open(path, "r")
        r:read("a")
        r:close()
        local d = (os.clock() - t0) * 1000
        total = total + d
        if d > worst then worst = d end
        if d >= 4 then spikes = spikes + 1 end
    end
    os.remove(path)
    say("file write+rename+read on %s: %.2f ms avg, %.0f ms worst, %d of %d >= 4 ms", dir, total / n, worst, spikes, n)
end

-- Frame intervals, seen from a loop that runs once per frame.
function PERF.frames(seconds, label)
    local times, last, stop = {}, nil, os.clock() + seconds
    local done = false
    LoopInGameThreadWithDelay(1, function()
        if done then return false end
        local now = os.clock()
        if last then times[#times + 1] = (now - last) * 1000 end
        last = now
        if now >= stop then
            done = true
            table.sort(times)
            local n, sum = #times, 0
            for _, t in ipairs(times) do sum = sum + t end
            local at = function(p) return times[math.max(1, math.floor(n * p))] end
            local over = 0
            for _, t in ipairs(times) do if t >= 50 then over = over + 1 end end
            say("frames %s: %d in %d s, %.0f fps, p50 %.0f p95 %.0f p99 %.0f max %.0f ms, %d frames >= 50 ms",
                label or "", n, seconds, n / (sum / 1000), at(0.5), at(0.95), at(0.99), times[n], over)
        end
        return false
    end)
end

-- Wraps calls that the mod makes through tables, so they can be timed in place.
function PERF.profile(seconds)
    local stats, undo = {}, {}
    local function wrap(tbl, key, label)
        local f = tbl[key]
        if type(f) ~= "function" then return end
        local s = { n = 0, t = 0, max = 0 }
        stats[label] = s
        undo[#undo + 1] = function() tbl[key] = f end
        tbl[key] = function(...)
            local t0 = os.clock()
            local r = table.pack(f(...))
            local d = os.clock() - t0
            s.n, s.t = s.n + 1, s.t + d
            if d > s.max then s.max = d end
            return table.unpack(r, 1, r.n)
        end
    end
    wrap(_G, "FindAllOf", "FindAllOf")
    wrap(_G, "FindFirstOf", "FindFirstOf")
    wrap(_G, "StaticFindObject", "StaticFindObject")
    wrap(io, "open", "io.open")
    wrap(os, "rename", "os.rename")
    wrap(os, "remove", "os.remove")
    for _, name in ipairs({ "listEnemies", "refreshEnemyIds", "watchLocalPlayer", "watchPickups", "watchHitState",
        "watchCurrency", "ghostAggro", "getHealth", "inCutscene" }) do
        wrap(game, name, "game." .. name)
    end
    for name in pairs(PBZ.coop.extraTicks) do
        wrap(PBZ.coop.extraTicks, name, "tick." .. name)
    end
    for name in pairs(PBZ.coop.frameTicks) do
        wrap(PBZ.coop.frameTicks, name, "frame." .. name)
    end
    if PBZ.moves and PBZ.moves.parts then
        for name in pairs(PBZ.moves.parts) do
            wrap(PBZ.moves.parts, name, "moves." .. name)
        end
    end
    wrap(PBZ.link, "state", "link.state")
    wrap(PBZ.link, "partner", "link.partner")
    wrap(PBZ.link, "enemy", "link.enemy")
    wrap(PBZ.link, "events", "link.events")
    local stop = os.clock() + seconds
    local done = false
    LoopInGameThreadWithDelay(1, function()
        if done or os.clock() < stop then return false end
        done = true
        for _, f in ipairs(undo) do f() end
        local names = {}
        for name in pairs(stats) do names[#names + 1] = name end
        table.sort(names, function(a, b) return stats[a].t > stats[b].t end)
        for _, name in ipairs(names) do
            local s = stats[name]
            say("%-24s %6d calls %8.1f ms/s total %7.2f ms avg %5.0f ms worst", name, s.n, s.t * 1000 / seconds,
                s.n > 0 and s.t * 1000 / s.n or 0, s.max * 1000)
        end
        return false
    end)
end

-- Walks player 1 into the densest spot of level spawners so a real crowd wakes up around it, held at 1 health.
function PERF.crowd()
    local _, pawn = PBZ.getPlayer1()
    local spots = {}
    for _, s in ipairs(FindAllOf("AISpawner") or {}) do
        local ok, l = pcall(function() return s:K2_GetActorLocation() end)
        if ok and l.X then spots[#spots + 1] = { X = l.X, Y = l.Y, Z = l.Z } end
    end
    local best, score = nil, -1
    for _, a in ipairs(spots) do
        local n = 0
        for _, b in ipairs(spots) do
            if (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 <= 4000 ^ 2 then n = n + 1 end
        end
        if n > score then best, score = a, n end
    end
    pawn.CharacterMovement:SetMovementMode(5, 0)
    pawn:K2_SetActorLocation({ X = best.X, Y = best.Y, Z = best.Z + 300 }, false, {}, true)
    PERF.crowdSpot = best
    say("crowd: %d spawners within 40 m of %.0f %.0f %.0f", score, best.X, best.Y, best.Z)
end

function PERF.count()
    local _, pawn = PBZ.getPlayer1()
    local here, n = pawn:K2_GetActorLocation(), 0
    for _, e in ipairs(game.listEnemies(true)) do
        local l = e:K2_GetActorLocation()
        if PBZ.distance(l, here) <= 6000 then n = n + 1 end
    end
    say("enemies within 60 m: %d of %d loaded, hp %s", n, #game.listEnemies(), tostring(game.getHealth(pawn)))
end


-- How closely the ghost keeps to the partner's path, frame by frame: distance to the played path, and how far apart the
-- frame-to-frame moves are from the path's own moves.
function PERF.track(seconds)
    local errs, jumps, stop = {}, 0, os.clock() + seconds
    local last, done = nil, false
    local frames = 0
    LoopInGameThreadWithDelay(1, function()
        if done then return false end
        local ghost, t = PBZ.net.ghost, PBZ.net.target
        if valid(ghost) and t then
            local g = ghost:K2_GetActorLocation()
            local dx, dy = g.X - t.X, g.Y - t.Y
            errs[#errs + 1] = math.sqrt(dx * dx + dy * dy)
            frames = frames + 1
            if last then
                local mx, my = g.X - last.X, g.Y - last.Y
                if mx * mx + my * my > 150 * 150 then jumps = jumps + 1 end
            end
            last = { X = g.X, Y = g.Y }
        end
        if os.clock() >= stop then
            done = true
            table.sort(errs)
            local n = #errs
            local at = function(p) return n > 0 and errs[math.max(1, math.floor(n * p))] or -1 end
            say("track: %d frames, ghost off the path p50 %.0f p95 %.0f max %.0f cm, %d jumps over 150 cm", n, at(0.5), at(0.95), n > 0 and errs[n] or -1, jumps)
            log("PERF status " .. tostring(PBZ.link.status()))
        end
        return false
    end)
end


-- Time per stage of the net loop, with its real clock (fine-grained, unlike os.clock).
function PERF.stages(seconds)
    PBZ.net.profile = {}
    local stop, done = os.clock() + seconds, false
    LoopInGameThreadWithDelay(1, function()
        if done or os.clock() < stop then return false end
        done = true
        local p = PBZ.net.profile
        PBZ.net.profile = nil
        local names, total = {}, 0
        for name, s in pairs(p) do
            names[#names + 1] = name
            total = total + s.t
        end
        table.sort(names, function(a, b) return p[a].t > p[b].t end)
        say("stages: %.1f ms/s in all", total * 1000 / seconds)
        for _, name in ipairs(names) do
            local s = p[name]
            say("  %-18s %6d calls %7.2f ms/s total %6.3f ms avg %6.1f ms worst", name, s.n, s.t * 1000 / seconds, s.t * 1000 / s.n, s.max * 1000)
        end
        return false
    end)
end

-- Sync on and off in turns, so whatever else the PC is doing lands on both.
function PERF.ab(seconds, rounds)
    local i = 0
    local function step()
        i = i + 1
        if i > rounds * 2 then return end
        local on = i % 2 == 1
        if on then PBZ.coop.commands.neton("host") else PBZ.coop.commands.netoff() end
        PERF.frames(seconds, on and "AB on" or "AB off")
        PBZ.game.after(seconds + 0.5, step)
    end
    step()
end
