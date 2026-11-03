-- Online, the host's story is the party's. Each player keeps their own save, so a guest can be chapters behind the host, or
-- ahead. The world the two play in is the host's, so a guest who is behind is brought up to the host's point: the quest steps
-- the host's world has done and theirs hasn't, applied with the game's own story table (the one its QA tools use), and the
-- unlocks and dialogue marks that come between the two points. Nothing goes back: a guest who is ahead stays ahead, and what
-- a guest found and where they rang bells stays theirs. Bosses the host has beaten follow in coop.lua (BEATEN).
-- FollowHostStory = Off in PhantomPact.ini keeps a guest's story their own.
--
-- The host reads its point while someone is linked and tells it (STORYPT) when it moves; a guest catches up at a quiet moment.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop

    local story = { follow = true }

    local FLOW = "/Game/PBZContent/Blueprint/FlowGraph/DebugUI/FlowQuest/FlowEventTable.FlowEventTable"
    local STATES = "/Game/PBZContent/Blueprint/FlowGraph/DebugUI/FlowQuest/FlowQuestBranchStateDataTable.FlowQuestBranchStateDataTable"
    local FINISH = "完成任务"        -- the table's quest steps end in this (a branch completed) or 开启任务 (a branch started)

    local LOOK_S = 20               -- host: its point is read this often while someone is linked
    local TELL_S = 60               -- and told again this often, moved or not
    local QUESTS_PER_TICK = 4       -- a read takes this many quests a tick: a whole list at once was 10 ms on a full save
    local CALM_S = 20               -- guest: catches up once this long has passed with nothing going on, and a load long over
    local NEXT_S = 2                -- and the next batch this long after one
    local BATCH = 40                -- table rows applied in one go: the QA tools apply forty without a hitch
    local FRESH_S = 150             -- a host's point heard longer ago than this isn't acted on

    local BITS = { 1, 2, 4, 8 }

    local rows = nil                -- the table as followed, read once: false if it couldn't be, until RETRY_S later
    local RETRY_S = 60
    local rowsFailedAt = -1e9

    local function text(v)
        local s
        pcall(function() s = v:get():ToString() end)
        if s == nil then
            pcall(function() s = v:ToString() end)
        end
        return s or ""
    end

    -- "MainCh1-NiLiuErShang_1_完成任务, XueRouHua_1_开启任务": quest, branch id (the branch's ID, "1" or "S1"), step.
    local function steps(list)
        local needs = {}
        for entry in list:gsub("，", ","):gmatch("[^,]+") do
            entry = entry:match("^%s*(.-)%s*$")
            local quest, branch, step = entry:match("^(.+)_([^_]+)_([^_]+)$")
            if not quest then
                return nil
            end
            needs[#needs + 1] = { quest = quest, branch = branch, finish = step == FINISH }
        end
        return #needs > 0 and needs or nil
    end

    local function column(lib, t, c)
        local out, v = {}, lib:GetDataTableColumnAsString(t, FName(c))
        for i = 1, #v do
            out[i] = text(v[i])
        end
        return out
    end

    -- The story table and the QA tools' branch table, found afresh for each use and never kept: they're loaded for this
    -- alone, so the garbage collection that comes with every load frees them, and a table kept from before took the game
    -- down at the next catch-up.
    local function tables()
        local t = StaticFindObject(FLOW)
        if not valid(t) then
            t = LoadAsset(FLOW)
        end
        local s = StaticFindObject(STATES)
        if not valid(s) then
            s = LoadAsset(STATES)
        end
        local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
        if valid(t) and valid(s) and valid(lib) then
            return t, s, lib
        end
        return nil
    end

    -- Which rows are followed. A row with quest steps is followed when the host's world has done all of them; the host only
    -- needs these (two columns, read once, kept as text).
    local function readTable()
        if rows or (rows == false and os.clock() - rowsFailedAt < RETRY_S) then
            return rows
        end
        rows, rowsFailedAt = false, os.clock()
        local t, _, lib = tables()
        if not t then
            log("Story: the game's story table isn't there: each player's story stays their own.")
            return rows
        end
        local names = {}
        lib:GetDataTableRowNames(t, names)
        local quests, optional = column(lib, t, "QuestList"), column(lib, t, "Optional")
        local out = { count = #names, quests = {}, marks = nil, check = #names }
        for i = 1, #names do
            local needs = (quests[i] or "") ~= "" and steps(quests[i])
            if needs then
                out.quests[#out.quests + 1] = { i = i, needs = needs, optional = optional[i] == "True" }
                for b in quests[i]:gmatch(".") do
                    out.check = (out.check * 31 + b:byte()) % 2147483647
                end
            end
        end
        out.optional, out.questText = optional, quests
        rows = out
        return rows
    end

    -- A guest's: the rows without quest steps that only set dialogue marks, world flags, unlocks or a region's map and aren't
    -- optional. They're followed when they lie between the two points. Rows that hand out items, weapons, loot or bells are a
    -- player's own finds, and aren't.
    local function readMarks()
        if rows.marks then
            return rows.marks
        end
        local t, _, lib = tables()
        if not t then
            return {}
        end
        local marks = { column(lib, t, "AddTags"), column(lib, t, "AddGuids"), column(lib, t, "ActiveBellMaps"),
            column(lib, t, "ActivateUITags") }
        local finds = { column(lib, t, "AddWeapons"), column(lib, t, "SnapSoulWeapons"), column(lib, t, "AddItems"),
            column(lib, t, "LootItems"), column(lib, t, "ActiveBells") }
        local function any(cols, i)
            for _, c in ipairs(cols) do
                if (c[i] or "") ~= "" then
                    return true
                end
            end
            return false
        end
        rows.marks = {}
        for i = 1, rows.count do
            if rows.optional[i] ~= "True" and (rows.questText[i] or "") == "" and any(marks, i) and not any(finds, i) then
                rows.marks[#rows.marks + 1] = { i = i }
            end
        end
        log(string.format("Story: %d quest steps and %d marks followed, of %d rows.", #rows.quests, #rows.marks, rows.count))
        return rows.marks
    end

    -- The narrative component, once the game has its quests in: right after a load the list is still being filled.
    local function narrative()
        local nc = FindFirstOf("PBZNarrativeComponent")
        if not valid(nc) then
            return nil
        end
        local ok, loaded = pcall(function() return nc.bCompleteLoad end)
        return (ok and loaded == true) and nc or nil
    end

    -- quest name -> branch ID -> the branch's state: 0 not yet, 1 under way, 2 done. Read a few quests a tick: start with
    -- readQuests(true), then call it each tick until it hands back the states. A finished quest has no current state, so only
    -- branches are read: a call on a missing object is a crash in UE4SS, not a Lua error.
    local reading = nil
    local function readQuests(start)
        if start then
            local nc = narrative()              -- (found once a read: a search of every object is the dear part)
            reading = nc and { i = 1, states = {}, nc = nc } or nil
            return nil
        end
        if reading == nil then
            return nil
        end
        local nc = reading.nc
        local ok, loaded = pcall(function() return valid(nc) and nc.bCompleteLoad end)
        if not (ok and loaded == true) then
            reading = nil                       -- a load came in between: the caller starts again
            return nil
        end
        local list = nc.QuestList
        local n = #list
        for _ = 1, QUESTS_PER_TICK do
            local i = reading.i
            if i > n then
                local states = reading.states
                reading = nil
                return states
            end
            reading.i = i + 1
            local q = list[i]
            pcall(function() q = q:get() end)
            if valid(q) then
                local name = q:GetClass():GetFName():ToString():gsub("_C$", "")
                local branches = reading.states[name] or {}
                reading.states[name] = branches
                local bs = q.Branches
                for j = 1, #bs do
                    local b = bs[j]
                    pcall(function() b = b:get() end)
                    if valid(b) then
                        local ok, st = pcall(function() return b:GetBranchState() end)
                        branches[b.ID:ToString()] = ok and tonumber(st) or 0
                    end
                end
            end
        end
        return nil
    end

    local function rowDone(states, row)
        for _, need in ipairs(row.needs) do
            local q = states[need.quest]
            local st = q and q[need.branch]
            if st == nil or st < (need.finish and 2 or 1) then
                return false
            end
        end
        return true
    end

    -- The quest rows a world has done (by their place among quest rows), and its point: the last one done that isn't optional.
    local function pointOf(states)
        local done, point = {}, 0
        for k, row in ipairs(rows.quests) do
            if rowDone(states, row) then
                done[k] = true
                if not row.optional then
                    point = row.i
                end
            end
        end
        return done, point
    end

    local function encode(done, n)
        local out = {}
        for d = 0, math.ceil(n / 4) - 1 do
            local v = 0
            for b = 1, 4 do
                if done[d * 4 + b] then
                    v = v + BITS[b]
                end
            end
            out[#out + 1] = string.format("%x", v)
        end
        return table.concat(out)
    end

    local function decode(hex, n)
        local done = {}
        for d = 1, #hex do
            local v = tonumber(hex:sub(d, d), 16)
            for b = 1, 4 do
                local k = (d - 1) * 4 + b
                if k <= n and math.floor(v / BITS[b]) % 2 == 1 then
                    done[k] = true
                end
            end
        end
        return done
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do
            n = n + 1
        end
        return n
    end

    ------------------------------------------------------------------ host

    local told, toldAt, lookAt = nil, -1e9, -1e9

    local function hostTick(now)
        if not coop.linked() then
            reading = nil
            return
        end
        if reading == nil and now - lookAt >= LOOK_S and readTable() then
            lookAt = now
            readQuests(true)
            return
        end
        local states = readQuests()
        if states then
            local done, point = pointOf(states)
            local line = string.format("%d %d %d %s", #rows.quests, rows.check, point, encode(done, #rows.quests))
            if line ~= told then
                log(string.format("Story: your point is row %d, %d of %d quest steps done: guests behind it catch up.",
                    point, count(done), #rows.quests))
                told, toldAt = line, -1e9
            end
        end
        if told and now - toldAt >= TELL_S then
            toldAt = now
            coop.sendEvent("STORYPT", told)
        end
    end

    -- Someone (re)started sync: they hear the point at once.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        syncStarted(rest, from)
        lookAt, toldAt = -1e9, -1e9
    end

    ------------------------------------------------------------------ guest

    local host = nil                -- { done, point, at, line, check }: the host's point as last heard; check = look again
    local calmSince, calmBody = nil, nil
    local waitUntil = 0
    local tried = {}                -- quest rows applied this session that didn't take: not tried again
    local marked = {}               -- mark rows applied this session
    local batch = nil               -- quest rows of the last batch, checked on the next read
    local caught, warned = 0, false

    coop.handlers.STORYPT = function(rest)
        if coop.isHost() or type(rest) ~= "string" or #rest > 400 then
            return
        end
        local n, check, point, hex = rest:match("^(%d+) (%d+) (%d+) (%x+)$")
        if not (n and readTable()) then
            return
        end
        if tonumber(n) ~= #rows.quests or tonumber(check) ~= rows.check then
            if not warned then
                warned = true
                log("Story: the host's game has another story table (another game version?): your story stays your own.")
            end
            return
        end
        if host and host.line == rest then
            host.at = os.clock()
            return
        end
        host = { done = decode(hex, #rows.quests), point = tonumber(point), at = os.clock(), line = rest, check = true }
    end

    local function calm(pawn)
        return valid(pawn) and not game.isDead(pawn) and not game.inCutscene() and not game.bossFightActive()
    end

    -- What a catch-up would apply now, in table order: { i (the table row), k (its place among quest rows) or mark }.
    local function todoFor(done, point)
        local todo = {}
        for k, row in ipairs(rows.quests) do
            if host.done[k] and not done[k] and not tried[k] then
                todo[#todo + 1] = { i = row.i, k = k }
            end
        end
        for _, row in ipairs(readMarks()) do
            if row.i > point and row.i < host.point and not marked[row.i] then
                todo[#todo + 1] = { i = row.i, mark = true }
            end
        end
        table.sort(todo, function(a, b) return a.i < b.i end)
        return todo
    end

    local function caughtUp()
        host.check = false
        if caught > 0 then
            log(string.format("Story: caught up with the host's (%d table rows).", caught))
            if api.status and api.status.notify then
                api.status.notify("story", string.format("your story caught up with the host's: %d step%s.", caught,
                    caught == 1 and "" or "s"))
            end
            caught = 0
        end
    end

    local function guestTick(now)
        local _, pawn = api.getPlayer1()
        local body = valid(pawn) and pawn:GetAddress() or nil
        if body ~= calmBody then
            calmBody, calmSince, reading, batch = body, nil, nil, nil
            if host and body then
                host.check = true                   -- a load: this world may be another save's
                tried, marked = {}, {}
            end
        end
        if not (story.follow and host and host.check and now - host.at < FRESH_S and coop.linked() and calm(pawn)) then
            calmSince, reading = nil, nil
            return
        end
        calmSince = calmSince or now
        if now - calmSince < CALM_S or now < waitUntil then
            return
        end
        if reading == nil then
            readQuests(true)
            return
        end
        local states = readQuests()
        if not states then
            return
        end
        local done, point = pointOf(states)
        if batch then
            local missed = 0
            for _, k in ipairs(batch) do
                if done[k] then
                    tried[k] = nil
                else
                    missed = missed + 1
                end
            end
            if missed > 0 then
                log(string.format("Story: %d of the host's story steps didn't take here: left as they are.", missed))
            end
            batch = nil
        end
        local todo = todoFor(done, point)
        if #todo == 0 then
            caughtUp()
            return
        end
        -- Tables and row names fresh, in this frame: see tables().
        local t, s, lib = tables()
        local qa = StaticFindObject("/Script/ProjectPBZ.Default__PBZDebugFlowEventLibrary")
        if not (t and valid(qa)) then
            return
        end
        local all = {}
        lib:GetDataTableRowNames(t, all)
        if #all ~= rows.count then
            return
        end
        local names = {}
        batch = {}
        for n = 1, math.min(BATCH, #todo) do
            local name = all[todo[n].i]
            pcall(function() name = name:get() end)
            names[n] = name
            if todo[n].mark then
                marked[todo[n].i] = true
            else
                tried[todo[n].k] = true          -- (cleared at the next read once it took)
                batch[#batch + 1] = todo[n].k
            end
        end
        local took = os.clock()
        local ok, err = pcall(function() qa:ApplyFlowEvents(pawn, t, s, names) end)
        if not ok then
            log("Story: the game wouldn't take the host's story steps: " .. tostring(err))
            host.check, batch = false, nil
            return
        end
        caught = caught + #names
        log(string.format("Story: %d of the host's story rows applied here (rows %d to %d, %.0f ms).", #names, todo[1].i,
            todo[#names].i, (os.clock() - took) * 1000))
        waitUntil = now + NEXT_S
    end

    -- Every tick while a read is under way, else once a second.
    local nextTick = 0
    coop.extraTicks.story = function()
        local now = os.clock()
        if reading == nil and now < nextTick then
            return
        end
        nextTick = now + 1
        if coop.isHost() then
            hostTick(now)
        else
            guestTick(now)
        end
    end

    ------------------------------------------------------------------ scenes

    -- A scene the host's world plays as a fight ends or turns to its next phase plays in the guest's world too, from the
    -- game's own flow: the guest's copy of the boss dies the whole way (coop.lua). The host skipping it skips the same scene
    -- here, one that only starts a moment later included, so the two go on together. SCENE skip <sequence name>.
    local SCENE_S = 0.25
    local SKIPPED_S = 3                 -- a scene that ended this much before its length was skipped (its start can be seen up to
                                        -- 2 s late after a load, and a scene watched to its end mustn't read as skipped)
    local LATE_S = 10                   -- a skip still ends our scene that starts this long after it
    local mine, mineAt, mineLength = nil, 0, nil
    local nextScene = 0
    local hostSkipped = {}              -- sequence name -> when the host skipped it
    local ended = nil                   -- our scene already ended for the host's

    coop.handlers.SCENE = function(rest)
        if coop.isHost() or type(rest) ~= "string" or #rest > 200 then
            return
        end
        local name = rest:match("^skip (%S+)$")
        if name then
            hostSkipped[name] = os.clock()
        end
    end

    coop.extraTicks.scenes = function()
        local now = os.clock()
        if now < nextScene then
            return
        end
        nextScene = now + SCENE_S
        local name = game.sceneName()
        if coop.isHost() then
            if name ~= mine then
                if mine and mineLength and now - mineAt < mineLength - SKIPPED_S then
                    coop.sendEvent("SCENE", "skip", mine)
                    log(string.format("Scene %s skipped after %.1f of %.1f s: the guest's too.", mine, now - mineAt, mineLength))
                end
                mine, mineAt, mineLength = name, now, name and game.sceneLength()
            elseif mine and not mineLength then
                mineLength = game.sceneLength()       -- (its player can come a moment after the scene does)
            end
            return
        end
        if not name then
            ended = nil
            return
        end
        local t = coop.net.target
        if name ~= ended and hostSkipped[name] and now - hostSkipped[name] <= LATE_S and t and t.Map == coop.net.localMap
            and game.skipScene() then
            ended = name                        -- (until it takes: the scene's player can be found a moment after it starts)
            log("The host skipped " .. name .. ": skipped here too.")
        end
    end

    -- For tests and the eval command. point(): this world's point as the host would tell it, read all at once.
    function story.point()
        if not (readTable() and narrative()) then
            return nil
        end
        local saved = reading
        readQuests(true)
        local states
        repeat
            states = readQuests()
        until states or reading == nil
        reading = saved
        if not states then
            return nil
        end
        local done, point = pointOf(states)
        return point, count(done), encode(done, #rows.quests)
    end

    -- plan(): the table rows a catch-up would apply now, in order, as one text.
    function story.plan()
        if not (host and story.point()) then
            return "no host point"
        end
        local saved = reading
        readQuests(true)
        local states
        repeat
            states = readQuests()
        until states or reading == nil
        reading = saved
        local done, point = pointOf(states or {})
        local out = {}
        for _, t in ipairs(todoFor(done, point)) do
            out[#out + 1] = t.i .. (t.mark and "m" or "")
        end
        return "host " .. host.point .. ", here " .. point .. ": " .. table.concat(out, " ")
    end

    return story
end
