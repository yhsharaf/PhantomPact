-- Online, what the host's world's story flow does while linked happens in the guests' worlds too: the flags it raises (the
-- event pipeline's global tags), the flow nodes it runs (ExecuteNodeGuid) and the bells it wakes. The story table's rows
-- (story.lua) only cover quest steps; a chain broken with the axe before the golden-hammer boss, the scene after a fight and
-- the bell it brings are the level's own flow, and a guest who wasn't in them was left with no way into the boss and no
-- bell, even after a reconnect (players' reports 7 and 8 on 1.6.3).
--
-- Only what's added on the host while linked, and only added on the guest: nothing is taken away, and a guest ahead keeps
-- what it has. With FollowHostStory = Off nothing is taken. Applied at a quiet moment, as story steps are: a flag raised
-- under an open dialogue or a scene can finish what it waits for.
--
-- FLOW t <tag> ... | FLOW n <node> ... | FLOW b <bell id> ...  (host to guests)

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop

    local LOOK_S = 6                -- host: what its flow added is looked for this often
    local CHUNK = 600               -- characters of items in one event
    local FLOOD = 200               -- more new at once than this is a world loaded or restored, not play: the new baseline
    -- Never sent: the game's mode, the screen's own state, and the states of a moment (a fight, a dodge, a lock-on).
    local SKIP = { "^GameMode%.", "^UI%.", "^State%.", "^Combat%.", "^Battle%.", "^Input%.", "^Camera%.", "^Ability%.",
        "^Status%.", "^Buff%.", "^Player%.State" }

    -- told: what the guests have (the baseline and what was sent); sent: what was sent, in order, told again to a guest
    -- (re)linked; seen: new last look, sent if it's still there this one (a tag on for a moment isn't story).
    local flow = { told = nil, sent = {}, seen = nil, linkedN = 0, queue = {}, applied = 0 }

    local function skipped(tag)
        for _, p in ipairs(SKIP) do
            if tag:find(p) then
                return true
            end
        end
        return false
    end

    -- This world's flags, flow nodes and woken bells, as sets of text.
    local function read()
        local tags, nodes, bells = {}, {}, {}
        local ep, bm = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager")
        if not (valid(ep) and valid(bm)) then
            return nil
        end
        pcall(function()
            ep.GlobalTags.GameplayTags:ForEach(function(_, t)
                local s = t:get().TagName:ToString()
                if not skipped(s) then
                    tags[s] = true
                end
            end)
        end)
        pcall(function()
            ep.ExecuteNodeGuid:ForEach(function(k)
                local s = k:get()
                pcall(function() s = s:ToString() end)
                if type(s) == "string" and not s:find("%s") then
                    nodes[s] = true
                end
            end)
        end)
        pcall(function()
            bm.ActivateBellIDs:ForEach(function(_, v)
                bells[v:get():ToString()] = true
            end)
        end)
        return { t = tags, n = nodes, b = bells }
    end

    local function send(kind, list)
        local line, n = {}, 0
        for _, item in ipairs(list) do
            if n + #item + 1 > CHUNK and #line > 0 then
                coop.sendEvent("FLOW", kind, table.concat(line, " "))
                line, n = {}, 0
            end
            line[#line + 1] = item
            n = n + #item + 1
        end
        if #line > 0 then
            coop.sendEvent("FLOW", kind, table.concat(line, " "))
        end
    end

    local function linkedCount()
        local n = 0
        for _, p in ipairs(coop.partners and coop.partners() or {}) do
            if not p.partnerGone and p.lastRemoteAt ~= nil and os.clock() - p.lastRemoteAt < 10 then
                n = n + 1
            end
        end
        return n
    end

    local nextLook = 0
    local function hostTick(now)
        -- (told is kept over a gap in the link: what was added meanwhile goes out when it's back, instead of becoming the
        -- baseline nobody was told of. A guest linked again, or a new one, is told all that was sent again.)
        local n = coop.linked() and linkedCount() or 0
        if n > flow.linkedN and flow.told and #flow.sent > 0 then
            local by = { t = {}, n = {}, b = {} }
            for _, it in ipairs(flow.sent) do
                by[it.kind][#by[it.kind] + 1] = it.item
            end
            for _, kind in ipairs({ "t", "n", "b" }) do
                if #by[kind] > 0 then
                    send(kind, by[kind])
                end
            end
            log(string.format("Story flow: a player linked: the %d things sent so far told again.", #flow.sent))
        end
        flow.linkedN = n
        if n == 0 or now < nextLook then
            return
        end
        nextLook = now + LOOK_S
        local _, pawn = api.getPlayer1()
        local ep = FindFirstOf("EventPipelineManager")
        local loaded = valid(ep) and select(2, pcall(function() return ep.LoadComplete end))
        if not (valid(pawn) and loaded ~= false) then
            return              -- (mid-load: an empty read made a baseline of nothing, and then sent the whole world)
        end
        local cur = read()
        if not cur then
            return
        end
        if flow.told == nil or (game.inPrologue and game.inPrologue()) then
            -- What was there at the link (the story table's rows cover a guest behind on that), and nothing of the prologue:
            -- marked done on a guest before they ran, its steps never ran there, the one giving back the gear among them.
            flow.told, flow.seen = cur, nil
            -- The bells this world has woken go out all the same, once, and to anyone who links later: a guest linked after
            -- the scene that woke one never had it (report 8). (Not the flags and flow steps: thousands, and a mark for a
            -- part of a level not yet played there skips its setting up.)
            if not (game.inPrologue and game.inPrologue()) then
                local bells = {}
                for id in pairs(cur.b) do
                    bells[#bells + 1] = id
                    flow.sent[#flow.sent + 1] = { kind = "b", item = id }
                end
                if #bells > 0 then
                    table.sort(bells)
                    send("b", bells)
                    log(string.format("Story flow: the %d bells woken here told to the others.", #bells))
                end
            end
            return
        end
        local new, count = {}, 0
        for _, kind in ipairs({ "t", "n", "b" }) do
            new[kind] = {}
            for item in pairs(cur[kind]) do
                if not flow.told[kind][item] then
                    new[kind][item] = true
                    count = count + 1
                end
            end
        end
        if count > FLOOD then
            flow.told, flow.seen = cur, nil
            log(string.format("Story flow: %d new at once (a load?): taken as this world's state, nothing sent.", count))
            return
        end
        local seen = flow.seen or { t = {}, n = {}, b = {} }
        for _, kind in ipairs({ "t", "n", "b" }) do
            local out = {}
            for item in pairs(new[kind]) do
                -- (Nodes and bells don't go back: sent at once. A tag, only if it was there last look too.)
                if kind ~= "t" or seen.t[item] then
                    flow.told[kind][item] = true
                    out[#out + 1] = item
                    flow.sent[#flow.sent + 1] = { kind = kind, item = item }
                end
            end
            if #out > 0 then
                table.sort(out)
                send(kind, out)
                log(string.format("Story flow: %d new %s here, told the others.", #out,
                    kind == "t" and "flags" or kind == "n" and "flow steps" or "bells"))
            end
        end
        flow.seen = new
    end

    -- Guest: what the host's flow added, applied here when it's quiet.
    coop.handlers.FLOW = function(rest, from)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" or #rest > CHUNK + 20 then
            return
        end
        if api.story and (api.story.follow == false or api.story.mismatch) then
            return          -- (not following, or another story table: another game version's flags aren't this one's)
        end
        local kind, items = rest:match("^([tnb]) (.+)$")
        if not kind then
            return
        end
        for item in items:gmatch("%S+") do
            if #item <= 200 then
                flow.queue[#flow.queue + 1] = { kind = kind, item = item }
            end
        end
    end

    local function calm()
        local _, pawn = api.getPlayer1()
        -- (A fight of this player's own only: the host's fight shown here held the chains the host broke just before it
        -- for the whole fight, the guest shut out of the arena.)
        local ownFight = coop.net and coop.net.ownBosses and #coop.net.ownBosses() > 0
        if ownFight == nil then
            ownFight = game.bossFightActive()
        end
        return valid(pawn) and not game.isDead(pawn) and not (game.sequenceOn or game.inCutscene)()
            and not ownFight and not (game.inDialogue and game.inDialogue())
            and not (api.story and api.story.isBusy and api.story.isBusy())
    end

    local function guestTick()
        if #flow.queue > 0 and game.inPrologue and game.inPrologue() then
            flow.queue = {}         -- (nothing of the host's into this player's prologue: see hostTick)
            return
        end
        if #flow.queue == 0 or not calm() then
            return
        end
        local ep, bm = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager")
        if not (valid(ep) and valid(bm)) then
            return
        end
        local have = read() or { t = {}, n = {}, b = {} }
        local done = 0
        game.granting = true        -- (what a flow step hands out isn't sent back as found)
        for _, q in ipairs(flow.queue) do
            if not have[q.kind][q.item] then
                local ok = pcall(function()
                    if q.kind == "t" then
                        ep:AddTagsByString(q.item)
                    elseif q.kind == "n" then
                        ep.ExecuteNodeGuid:Add(q.item, true)
                    else
                        bm:ActivateBellByID(FName(q.item))
                    end
                end)
                if ok then
                    done = done + 1
                end
            end
        end
        game.granting = false
        flow.queue = {}
        if done > 0 then
            flow.applied = flow.applied + done
            log(string.format("Story flow: %d of the host's flags, flow steps and bells taken here.", done))
        end
    end

    -- A loop of its own, once a second on the game thread: as an entry of coop.extraTicks it was gone on the bench after
    -- a while, cause not found, and the host told nothing.
    local nextGuest = 0
    local function tick()
        local now = os.clock()
        if not (coop.net and coop.net.enabled) then
            flow.told, flow.sent, flow.seen, flow.linkedN = nil, {}, nil, 0
            return
        end
        if os.clock() < (coop.net.quietUntil or 0) then
            return          -- (the quiet after a load or a trip: see coop's QUIET_AFTER_LOAD_S)
        end
        if coop.isHost() then
            local ok, err = pcall(hostTick, now)
            if not ok and err ~= flow.lastError then
                flow.lastError = err
                log("Story flow: " .. tostring(err))
            end
        elseif now >= nextGuest then
            nextGuest = now + 1
            local ok, err = pcall(guestTick)
            if not ok and err ~= flow.lastError then
                flow.lastError = err
                log("Story flow: " .. tostring(err))
            end
        end
    end
    flow.tick = tick
    LoopInGameThreadWithDelay(1000, function()
        pcall(tick)
        return false
    end)

    return flow
end
