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

    local LOOK_S = 3                -- host: what its flow added is looked for this often
    local CHUNK = 600               -- characters of items in one event
    local SKIP = { "^GameMode%.", "^UI%." }     -- never sent: the game's mode, the screen's own state

    local flow = { told = nil, queue = {}, applied = 0 }

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

    local nextLook = 0
    local function hostTick(now)
        if not coop.linked() then
            flow.told = nil         -- (a new link starts from what this world has then)
            return
        end
        if now < nextLook then
            return
        end
        nextLook = now + LOOK_S
        local cur = read()
        if not cur then
            return
        end
        if flow.told == nil then
            flow.told = cur         -- what was there at the link: the story table's rows cover a guest behind on that
            return
        end
        for _, kind in ipairs({ "t", "n", "b" }) do
            local new = {}
            for item in pairs(cur[kind]) do
                if not flow.told[kind][item] then
                    flow.told[kind][item] = true
                    new[#new + 1] = item
                end
            end
            if #new > 0 then
                table.sort(new)
                send(kind, new)
                log(string.format("Story flow: %d new %s here, told the others.", #new,
                    kind == "t" and "flags" or kind == "n" and "flow steps" or "bells"))
            end
        end
    end

    -- Guest: what the host's flow added, applied here when it's quiet.
    coop.handlers.FLOW = function(rest, from)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" or #rest > CHUNK + 20 then
            return
        end
        if api.story and api.story.follow == false then
            return
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
        return valid(pawn) and not game.isDead(pawn) and not game.inCutscene() and not game.bossFightActive()
            and not (game.inDialogue and game.inDialogue())
    end

    local function guestTick()
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
            flow.told = nil
            return
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
