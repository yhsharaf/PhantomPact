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

    -- The table is our own copy (storydata.lua): the game's update of 2026-11-04 took its QA story tables out of the game,
    -- and the catch-up that applied their rows did nothing from then on (1.6.1 to 1.6.3), saying so only in the log.
    local DATA = api.storyData
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

    -- One column of our copy of the table, as text, by row.
    local function column(key)
        local out = {}
        for i, r in ipairs(DATA and DATA.rows or {}) do
            local v = r[key]
            out[i] = v == true and "True" or v or ""
        end
        return out
    end

    -- Which rows are followed. A row with quest steps is followed when the host's world has done all of them; the host only
    -- needs these (two columns, read once, kept as text).
    local function readTable()
        if rows or (rows == false and os.clock() - rowsFailedAt < RETRY_S) then
            return rows
        end
        rows, rowsFailedAt = false, os.clock()
        if not (DATA and DATA.rows and #DATA.rows > 0) then
            log("Story: no story table: each player's story stays their own.")
            return rows
        end
        local quests, optional = column("q"), column("o")
        local out = { count = #DATA.rows, quests = {}, marks = nil, check = #DATA.rows }
        for i = 1, out.count do
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
        local marks = { column("t"), column("g"), column("m"), column("u") }
        local finds = { column("f"), column("b") }
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

    -- (Nor in a talk with an NPC: a story step applied under an open dialogue (both handing in to Yuer at once) finished
    -- what the talk was waiting for, and the talk stayed up with no way out.)
    local function calm(pawn)
        -- (sequenceOn, any sequence: the camera check of inCutscene is for joining fights, a step under a scene that
        -- keeps the camera on the player still finished it. Nor in the prologue: see flowsync.)
        return valid(pawn) and not game.isDead(pawn) and not (game.sequenceOn or game.inCutscene)()
            and not game.bossFightActive() and not (game.inDialogue and game.inDialogue())
            and not (game.inPrologue and game.inPrologue())
    end

    -- "a，b, c" -> { "a", "b", "c" }
    local function split(s)
        local out = {}
        for part in (s or ""):gsub("，", ","):gmatch("[^,]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then
                out[#out + 1] = part
            end
        end
        return out
    end

    -- A quest branch's state in this world: 0 not begun (or the quest not here), 1 under way, 2 done.
    local function branchState(nc, quest, branch)
        local state = 0
        pcall(function()
            local list = nc.QuestList
            for i = 1, #list do
                local q = list[i]
                pcall(function() q = q:get() end)
                if valid(q) and q:GetClass():GetFName():ToString() == quest .. "_C" then
                    local bs = q.Branches
                    for j = 1, #bs do
                        local b = bs[j]
                        pcall(function() b = b:get() end)
                        if valid(b) and b.ID:ToString() == branch then
                            state = tonumber(b:GetBranchState()) or 0
                        end
                    end
                    return
                end
            end
        end)
        return state
    end

    -- A quest's class, by our table's path for it (loaded: a quest this world hasn't begun isn't in memory).
    local classes = {}
    local function questClass(quest)
        local c = classes[quest]
        if valid(c) then
            return c
        end
        local path = DATA and DATA.paths and DATA.paths[quest]
        if not path then
            return nil
        end
        c = StaticFindObject(path)
        if not valid(c) then
            pcall(function() c = LoadAsset(path) end)
        end
        classes[quest] = valid(c) and c or nil
        return classes[quest]
    end

    -- One row, by the game's own calls, as its QA tool's table did it: the quest steps (a branch begun, or finished, begun
    -- first if it wasn't), the tags (bells woken by the story come as "bell." tags), the flow nodes marked done, the UI
    -- shown. Not a row's maps (its "m", rows like 庞镇-地图解锁, "Pangzhen map unlocked"): ActivateAllBellsByMaps on them
    -- rang every bell of the region on arrival, fast travel to all of them and the progression gone (a player report, 11-06).
    -- A bell is the player's to ring, or comes by its own id (b) or tag. What a row hands out (weapons, items, loot) isn't: a player's own finds, and what
    -- the story needs comes with the host's bag. Returns how many of its parts the game took, and how many it was given.
    local function applyRow(row, nc, ep, bells, ui)
        local took, tried = 0, 0
        local function try(f)
            tried = tried + 1
            if pcall(f) then
                took = took + 1
            end
        end
        for _, step in ipairs(row.q and steps(row.q) or {}) do
            local cls = questClass(step.quest)
            if cls and nc then
                local branches = { FName(step.branch) }
                local st = branchState(nc, step.quest, step.branch)
                if st < 1 then
                    try(function() nc:BeginQuestAndActiveBranch(cls, branches) end)
                end
                if step.finish and st < 2 then
                    try(function() nc:FinishQuestBranch(cls, branches, true) end)
                end
            else
                tried = tried + 1
            end
        end
        if valid(ep) then
            for _, tag in ipairs(split(row.t)) do
                try(function() ep:AddTagsByString(tag) end)
            end
            for _, guid in ipairs(split(row.g)) do
                try(function() ep.ExecuteNodeGuid:Add(guid, true) end)
            end
        end
        if valid(bells) then
            for _, id in ipairs(split(row.b)) do
                try(function() bells:ActivateBellByID(FName(id)) end)
            end
        end
        if valid(ui) then
            for _, tag in ipairs(split(row.u)) do
                try(function() ui:ActivateUIVisibilityTag({ TagName = FName(tag) }) end)
            end
        end
        return took, tried
    end

    -- Table rows (by their number) applied with the game's own calls, in order. False if the game took none of it.
    local function applyRows(pawn, list, why)
        local nc = narrative()
        local ep, bells, ui = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager"), FindFirstOf("UIVisibilityManager")
        if not (nc and DATA and DATA.rows) then
            return false
        end
        local took, tried = 0, 0
        -- (What the rows hand out isn't sent on as found: the partner had it when they did the step.)
        game.granting = true
        for _, i in ipairs(list) do
            local row = DATA.rows[i]
            if row then
                local t, n = applyRow(row, nc, ep, bells, ui)
                took, tried = took + t, tried + n
            end
        end
        game.granting = false
        if tried > 0 and took < tried then
            log(string.format("Story: the game took %d of %d parts of %s.", took, tried, why))
        end
        return took > 0 or tried == 0
    end
    story.applyRows = applyRows

    -- storyjump <to> [from]: the table's rows from..to (from 1) applied here, as a catch-up would: a test save taken to a point
    -- in the story (the game's own QA jump went with its table).
    if game.commands then
        game.commands.storyjump = function(args)
            local to, from = (args or ""):match("^(%d+)%s*(%d*)$")
            to, from = tonumber(to), tonumber(from) or 1
            local _, pawn = api.getPlayer1()
            if not (to and DATA and DATA.rows and valid(pawn)) then
                log("Usage: storyjump <last row> [first row]")
                return
            end
            local list = {}
            for i = from, math.min(to, #DATA.rows) do
                list[#list + 1] = i
            end
            log(string.format("Story jump: rows %d to %d: %s.", from, to, tostring(applyRows(pawn, list, "the story jump"))))
        end
    end

    ------------------------------------------------------------------ host

    local told, toldAt, lookAt = nil, -1e9, -1e9

    -- A guest's quest steps come the other way too, the ones the host is on: a guest who finished the quest both have under
    -- way (the bow in the tower, early in Xigu) left the host to do it all over again. Only a quest the host's world has
    -- started: a guest who is further on doesn't take the host's story past its point, the host's world decides that.
    -- The step's things came already, as everything the game gives does; the game's own step that follows here gives
    -- nothing twice that can't be had twice (a weapon, an accessory).
    local guestDone = {}            -- who (0 for a lone guest) -> { done, at }
    local hostTried = {}            -- quest rows applied here for a guest this session: not tried again
    -- A row the host is on: each step it needs is a branch under way in the host's world (or done there already). A branch
    -- the host hasn't started isn't taken: by quest alone, a guest further on took the host through the whole quest, and
    -- into a branch its world didn't choose.
    local function questStarted(states, row)
        for _, need in ipairs(row.needs) do
            local st = (states[need.quest] or {})[need.branch]
            if not st or st < 1 then
                return false
            end
        end
        return true
    end
    local function takeGuestSteps(states, done, now)
        local _, pawn = api.getPlayer1()
        if not (story.follow and calm(pawn)) then
            return
        end
        local list, ks = {}, {}
        for k, row in ipairs(rows.quests) do
            if not done[k] and not hostTried[k] and questStarted(states, row) then
                for _, g in pairs(guestDone) do
                    if g.done[k] and now - g.at < FRESH_S and #list < BATCH then
                        list[#list + 1], ks[#ks + 1] = row.i, k
                        break
                    end
                end
            end
        end
        if #list == 0 then
            return
        end
        if applyRows(pawn, list, "a guest's story steps") then
            for _, k in ipairs(ks) do
                hostTried[k] = true         -- (only once the game took them: a failed look tries again)
            end
            log(string.format("Story: a guest finished %d step%s of quests you're on: done here too (rows %d to %d).", #list,
                #list == 1 and "" or "s", list[1], list[#list]))
            if api.status and api.status.notify then
                api.status.notify("story", "your partner finished a quest step you were on: done for you too.")
            end
            lookAt = -1e9           -- (read again: the point moved, and the guests hear it)
        end
    end

    coop.handlers.GSTORY = function(rest, from)
        -- A guest loaded another save: where they stand now is their new start. Kept, a guest who loaded a finished save
        -- while linked had every row past their first one counted as done together, and the host's quests finished by it.
        if coop.isHost() and rest == "reset" then
            -- (Rebased at their next report, keeping what they'd done while linked that the host hasn't taken yet: a
            -- respawn or a trip right after a step loads too, and forgotten, that step never reached the host.)
            local g = guestDone[from or 0]
            if g then
                g.rebase = true
            end
            return
        end
        if not coop.isHost() or type(rest) ~= "string" or #rest > 400 or not readTable() then
            return
        end
        local n, check, hex = rest:match("^(%d+) (%d+) (%x+)$")
        if n and tonumber(n) == #rows.quests and tonumber(check) == rows.check then
            -- Only steps the guest finishes while linked: the first report is where they stood, and counts for nothing.
            -- A guest far ahead (a finished NG+ save) otherwise finished a newcomer host's quests for them on joining.
            -- (The bow in the tower, done together, still counts: the user's rule, the host gives and the guest
            -- doesn't.)
            local all = decode(hex, #rows.quests)
            local g = guestDone[from or 0]
            if not g then
                g = { base = all, done = {} }
                guestDone[from or 0] = g
            end
            if g.rebase then
                g.rebase = nil
                local base = {}
                for k in pairs(all) do
                    if not g.done[k] then
                        base[k] = true
                    end
                end
                g.base = base
            end
            g.done, g.at = {}, os.clock()
            for k in pairs(all) do
                if not g.base[k] then
                    g.done[k] = true
                end
            end
            lookAt = math.min(lookAt, os.clock() - LOOK_S + 2)  -- (a look soon: there may be something to take)
        end
    end

    local function hostTick(now)
        if not coop.linked() then
            reading = nil
            guestDone = {}          -- (a guest's steps go with them: one who left, or the next who comes, isn't them)
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
            takeGuestSteps(states, done, now)
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
        guestDone[from or 0] = nil      -- (whoever starts sync anew tells their steps anew)
    end

    ------------------------------------------------------------------ guest

    local host = nil                -- { done, point, at, line, check }: the host's point as last heard; check = look again
    local calmSince, calmBody = nil, nil
    local waitUntil = 0
    local tried = {}                -- quest rows applied this session that didn't take: not tried again
    local marked = {}               -- mark rows applied this session
    local batch = nil               -- quest rows of the last batch, checked on the next read
    -- Catching up now (a batch of the host's steps applied, not yet read back): flowsync waits, so a flag doesn't land in
    -- the middle of the steps it follows.
    function story.isBusy()
        return batch ~= nil
    end
    local caught, warned = 0, false
    -- The host started sync anew (another host, maybe): its old point isn't caught up to before the new one's comes.
    local guestSyncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        guestSyncStarted(rest, from)
        if not coop.isHost() and from == nil then
            host, tried, marked = nil, {}, {}
        end
    end

    coop.handlers.STORYPT = function(rest, from)
        -- (from: another guest's, passed on by the relay: only the host's point is caught up to, into this save for good.)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" or #rest > 400 then
            return
        end
        local n, check, point, hex = rest:match("^(%d+) (%d+) (%d+) (%x+)$")
        if not (n and readTable()) then
            return
        end
        if tonumber(n) ~= #rows.quests or tonumber(check) ~= rows.check then
            if not warned then
                warned = true
                story.mismatch = true       -- (flowsync takes nothing either)
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

    -- A guest's own steps, for the host (GSTORY): when they change, and every TELL_S.
    local ownTold, ownToldAt, ownLookAt, ownReading = nil, -1e9, -1e9, false
    local function tellOwn(states, now)
        local done = pointOf(states)
        local line = string.format("%d %d %s", #rows.quests, rows.check, encode(done, #rows.quests))
        if line ~= ownTold or now - ownToldAt >= TELL_S then
            ownTold, ownToldAt = line, now
            coop.sendEvent("GSTORY", line)
        end
    end

    -- What a catch-up would apply now, in table order: { i (the table row), k (its place among quest rows) or mark }.
    -- A step of the other side of a choice this world made: a branch "4-A" when this world took "4-B". (Only lettered
    -- pairs are choices: the numbered and S branches are steps of one path, all of them done in a normal run.)
    local function otherChoice(states, row)
        for _, need in ipairs(row.needs) do
            local stem, letter = need.branch:match("^(.+)%-(%a)$")
            local q = stem and states and states[need.quest]
            if q and (q[need.branch] or 0) < 1 then
                for b, st in pairs(q) do
                    local s2, l2 = b:match("^(.+)%-(%a)$")
                    if s2 == stem and l2 ~= letter and st >= 1 then
                        return true
                    end
                end
            end
        end
        return false
    end

    local function todoFor(done, point, states)
        local todo = {}
        for k, row in ipairs(rows.quests) do
            if host.done[k] and not done[k] and not tried[k] and not otherChoice(states, row) then
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
            if body and coop.linked() then
                coop.sendEvent("GSTORY", "reset")   -- (and for the host: its count of what this player did starts over)
            end
        end
        if not (story.follow and host and host.check and now - host.at < FRESH_S and coop.linked() and calm(pawn)) then
            -- (Calm is the player's: kept while nothing goes on, whether or not there's anything to take, so a new point
            -- heard after a quiet while is taken at once instead of after another 20 s.)
            calmSince = calm(pawn) and (calmSince or now) or nil
            -- Not catching up: this world's own steps are read now and then all the same, for the host.
            if story.follow and coop.linked() and calm(pawn) and readTable() then
                if not ownReading and now - ownLookAt >= LOOK_S then
                    ownLookAt, ownReading = now, true
                    readQuests(true)
                elseif ownReading then
                    local states = readQuests()
                    if states then
                        ownReading = false
                        tellOwn(states, now)
                    elseif reading == nil then
                        ownReading = false          -- (a load came in between)
                    end
                end
            else
                reading, ownReading = nil, false
            end
            return
        end
        ownReading = false
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
        tellOwn(states, now)
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
        local todo = todoFor(done, point, states)
        if #todo == 0 then
            caughtUp()
            return
        end
        local names = {}
        batch = {}
        -- (No more than 6 quests to load from disk in one go: each is a load on the game thread, and forty at once for a
        -- guest far behind could stall the game as they joined.)
        local loads, seenQuest = 0, {}
        for n = 1, math.min(BATCH, #todo) do
            local row = DATA.rows[todo[n].i]
            local q = row and row.q
            if type(q) == "string" and q ~= "" and not seenQuest[q] and not valid(classes[q]) then
                seenQuest[q] = true
                loads = loads + 1
                if loads > 6 and n > 1 then
                    break
                end
            end
            names[#names + 1] = todo[n].i
            if todo[n].mark then
                marked[todo[n].i] = true
            else
                tried[todo[n].k] = true          -- (cleared at the next read once it took)
                batch[#batch + 1] = todo[n].k
            end
        end
        local took = os.clock()
        if not applyRows(pawn, names, "the host's story steps") then
            log("Story: the game wouldn't take the host's story steps.")
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

    coop.handlers.SCENE = function(rest, from)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" or #rest > 200 then
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
                if mine and mineLength and now - mineAt < mineLength - SKIPPED_S and not (game.inDialogue and game.inDialogue()) then
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
        -- (Not while a QTE runs here: the host passing its own QTE ended its scene early, and the guest's same scene was sent
        -- to its end in the middle of theirs, leaving them stuck in it: 沐小葵's third phase, a Nexus report on 1.6.6.)
        if name ~= ended and hostSkipped[name] and now - hostSkipped[name] <= LATE_S and t and t.Map == coop.net.localMap
            and not (game.inDialogue and game.inDialogue()) and not (api.qte and api.qte.active) and game.skipScene() then
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
