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
--
-- The one way back: what another player found raises its own flags here too, host or guest (flow.raise): a pile or chest
-- they searched (coop.lua's OF), since their search took ours away, and a thing of theirs that came here (grantLoot).

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
    -- A guest's flag, flow step or bell whose call failed is tried again a calm second on, TRIES times in all: let go
    -- with the rest of the queue, it was lost till the next link (issue #16). No more than AGAIN_MAX wait at once.
    -- again: "kind item" -> the tries so far.
    local TRIES, AGAIN_MAX = 5, 400
    flow.again = {}

    local function skipped(tag)
        for _, p in ipairs(SKIP) do
            if tag:find(p) then
                return true
            end
        end
        return false
    end

    -- The bells woken in this world, as a set of ids.
    local function readBells(bm)
        local bells = {}
        pcall(function()
            bm.ActivateBellIDs:ForEach(function(_, v)
                bells[v:get():ToString()] = true
            end)
        end)
        return bells
    end

    -- This world's flags, flow nodes and woken bells, as sets of text.
    local function read()
        local tags, nodes = {}, {}
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
        return { t = tags, n = nodes, b = readBells(bm) }
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
            flow.told, flow.seen, flow.rebase = cur, nil, nil
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
        if flow.rebase then
            -- Back from a PvP match: this world as it is now is the baseline, and nothing is sent (not the bells again).
            flow.told, flow.seen, flow.rebase = cur, nil, nil
            log("Story flow: back from a match: taken as this world's state, nothing sent.")
            return
        end
        local new, count = {}, { t = 0, n = 0, b = 0 }
        for _, kind in ipairs({ "t", "n", "b" }) do
            new[kind] = {}
            for item in pairs(cur[kind]) do
                if not flow.told[kind][item] then
                    new[kind][item] = true
                    count[kind] = count[kind] + 1
                end
            end
        end
        -- (Each kind on its own, and never the bells: a scene after a boss that marked hundreds of flow steps took the bell it
        -- woke down with them, and a reconnect never sent it. The bells are the world's list: a load doesn't flood them, and
        -- a guest lights one only where it stands by it.)
        for _, kind in ipairs({ "t", "n" }) do
            if count[kind] > FLOOD then
                flow.told[kind], new[kind] = cur[kind], {}
                log(string.format("Story flow: %d new %s at once (a load?): taken as this world's state, not sent.",
                    count[kind], kind == "t" and "flags" or "flow steps"))
            end
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

    -- The host's bells are lit here only where this player stands by one: within BELL_NEAR_CM of it, on its map. (Every
    -- bell the host had ever woken was lit at the link, and each one it woke after: a guest reached Pangzhen with every
    -- bell there awake and the fast travel open, and passed them on when they hosted in turn; a Nexus report on 1.6.6. A
    -- bell the host woke in a scene this player missed is still theirs, as report 8 asked: it's lit when they walk up to
    -- it.) flow.pending: bell id -> true.
    local BELL_NEAR_CM = 3000
    local BELLS = "/Game/PBZContent/DataTable/UI/DT_BellData.DT_BellData"
    flow.pending, flow.places = {}, nil

    local function text(v)
        pcall(function() v = v:get() end)
        pcall(function() v = v:ToString() end)
        return type(v) == "string" and v or nil
    end

    -- Each bell's map and place, from the game's own bell table (BellID, MapID, TeleportTransform), read once. (187 rows
    -- on the bench, 11-07.)
    local function bellPlaces()
        if flow.places then
            return flow.places
        end
        local places = {}
        pcall(function()
            local dt = StaticFindObject(BELLS)
            if not valid(dt) and type(LoadAsset) == "function" then
                dt = LoadAsset((BELLS:gsub("%.[^.]*$", "")))
            end
            local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
            if not (valid(dt) and valid(lib)) then
                return
            end
            local ids = lib:GetDataTableColumnAsString(dt, FName("BellID"))
            local maps = lib:GetDataTableColumnAsString(dt, FName("MapID"))
            local where = lib:GetDataTableColumnAsString(dt, FName("TeleportTransform"))
            for i = 1, #ids do
                local id, at = text(ids[i]), text(where[i]) or ""
                local x, y, z = at:match("Translation=%(X=([%-%d%.]+),Y=([%-%d%.]+),Z=([%-%d%.]+)")
                if id and x then
                    places[id] = { map = text(maps[i]), x = tonumber(x), y = tonumber(y), z = tonumber(z) }
                end
            end
        end)
        if next(places) ~= nil then
            flow.places = places
        end
        return places
    end

    -- A call that failed: true while it's to be tried again (its tries counted), false once it has had all TRIES.
    local function tryAgain(key)
        local tries = (flow.again[key] or 0) + 1
        flow.again[key] = tries < TRIES and tries or nil
        return tries < TRIES
    end

    -- The host's bells waiting here that this player stands by now, lit. One lit here already, or not in the game's table
    -- (once it's read), is let go.
    local function lightNearBells(bm, have)
        if next(flow.pending) == nil then
            return 0
        end
        local _, pawn = api.getPlayer1()
        if not valid(pawn) then
            return 0
        end
        local l = pawn:K2_GetActorLocation()
        local ms = FindFirstOf("MapSubsystem")
        local here = valid(ms) and text(ms:GetCurrentMapID()) or nil
        local places = bellPlaces()
        local lit = 0
        for id in pairs(flow.pending) do
            local p = places[id]
            if have.b[id] or (flow.places and not p) then
                flow.pending[id], flow.again["b " .. id] = nil, nil
            elseif p and (here == nil or p.map == nil or p.map == here)
                and (l.X - p.x) ^ 2 + (l.Y - p.y) ^ 2 + (l.Z - p.z) ^ 2 <= BELL_NEAR_CM * BELL_NEAR_CM then
                local ok = pcall(function() bm:ActivateBellByID(FName(id)) end)
                if ok then
                    lit = lit + 1
                    flow.again["b " .. id] = nil
                    log("Story flow: the host's bell " .. id .. " lit here, as you came to it.")
                end
                -- (One whose call failed stays, for the next calm second: see TRIES.)
                if ok or not tryAgain("b " .. id) then
                    flow.pending[id] = nil
                    if not ok then
                        log("Story flow: the host's bell " .. id .. " couldn't be lit here (tried " .. TRIES .. " times).")
                    end
                end
            end
        end
        return lit
    end

    -- A boss of the host's world fell while the host was down, its respawn held for the fight (a report on 1.7.1, three
    -- players: "if host dies during fight, they don't get items and bell (if it spawns afterwards) doesn't show up"). On the
    -- bench (11-12, the Gold-Masked One and his two guards at Xigu) the game runs a boss's death with its player down another
    -- way: its "killed" flag and a step of its own, but none of its win's steps (the reward, a step on the arena's bell, two
    -- more), and the respawn never brings them. A guest's world ran the same death with its player up (coop's K,
    -- killForReal): its win's steps. What that death added here (flags and flow steps; not what was here before it) is told
    -- to the host over the next seconds (DB <boss> <t|n> <items>), and the host takes what its world lacks once it's up and
    -- settled, as a guest takes the host's flow. Only for a boss it owes (game.owedNames): nothing else of a guest's world
    -- goes the host's way. (The reward itself reaches the host as any of the guest's finds, T.) Never a bell: the win's
    -- bell comes as a flow step on the bell's own actor (the bench), and one woken here was this player's own ring, a crane
    -- bell's right after its boss say; lit in the host's world by word, the host lost its own first ring and its scene (a
    -- bell lit by word plays none: the bells work, 343e7b0). Each player's first ring is their own.
    -- (Only once the death ran here: from the K on, a flag of this player's own play went to the host, and from there to
    -- every guest. A flag is told only if it was there the look before too, as the host's own are: one on for a moment, a
    -- scene's, isn't the win's. The review of the draft. The bench, 11-12: the gold-masked man's win came 10 to 15 s after
    -- his death ran here, his "killed" flag with it, in both worlds; looked at only till 10 s, one step was missed. A scene
    -- here stops the clock: a win after a fight's scene comes when it's over. A load ends it: what comes then is the trip's.)
    local DOWN_AT = { 4, 8, 12, 16, 20 }        -- seconds after the death ran here it's looked at, scenes not counted
    local DOWN_SCENE_MAX_S = 120                -- scenes it waits out, in all
    local DOWN_OWED_S = 180                     -- host: a boss owed this long ago still takes its steps
    local DOWN_MAX = 1000                       -- more new at once than this, or waiting on the host, isn't a win's
    flow.downFlow = {}                          -- guest: { name, since, step, told, before, seen, last, waited }
    flow.owedFlow = {}                          -- host: "kind item" -> the boss's name

    -- Guest: this world's flags and flow steps (and bells), read just before a death runs here (coop's net.killWatched).
    function flow.readFlow()
        return read()
    end

    -- Guest: that death ran here (killForReal) with the host down: what it adds is told to the host. before: readFlow's.
    function flow.watchDownFlow(name, before)
        if type(name) == "string" and type(before) == "table" and #flow.downFlow < 8 then
            table.insert(flow.downFlow, { name = name, since = os.clock(), step = 1, told = {}, before = before })
        end
    end

    -- (Not a thing's own flag while held, a find of this player's (game.isHeldFlag); none at all from another story table,
    -- as FLOW takes none; and more new at once than DOWN_MAX is a load or a restore, not a win. Not FLOOD: a boss's scene
    -- can mark hundreds of flow steps at once, see hostTick.)
    local function tellDownFlow(now)
        local scene = game.inCutscene and game.inCutscene()
        local cur = nil
        if api.story and api.story.mismatch then
            flow.downFlow = {}
            return
        end
        for i = #flow.downFlow, 1, -1 do
            local d = flow.downFlow[i]
            if scene and d.last and (d.waited or 0) < DOWN_SCENE_MAX_S then
                d.since, d.waited = d.since + (now - d.last), (d.waited or 0) + (now - d.last)
            end
            d.last = now
            if now - d.since >= DOWN_AT[d.step] then
                d.step = d.step + 1
                cur = cur or read()         -- (once a second for all of them)
                local said, seen = 0, {}
                for _, kind in ipairs({ "t", "n" }) do
                    local out = {}
                    for item in pairs(cur and cur[kind] or {}) do
                        -- (What was here before first: thousands of flags and steps, a key made for each was a hitch.)
                        if not d.before[kind][item] and #item <= 200 then
                            local key = kind .. " " .. item
                            if not d.told[key] and not (kind == "t" and game.isHeldFlag and game.isHeldFlag(item)) then
                                seen[key] = true
                                if kind ~= "t" or (d.seen and d.seen[key]) then
                                    d.told[key] = true
                                    out[#out + 1] = item
                                end
                            end
                        end
                    end
                    if #out > DOWN_MAX then
                        log(string.format("Story flow: %d new %s here at once (a load?): not told to the host.", #out, kind))
                        out = {}
                    end
                    if #out > 0 then
                        table.sort(out)
                        local line, n = {}, 0
                        for _, item in ipairs(out) do
                            if n + #item + 1 > CHUNK and #line > 0 then
                                coop.sendEvent("DB", d.name .. " " .. kind .. " " .. table.concat(line, " "))
                                line, n = {}, 0
                            end
                            line[#line + 1] = item
                            n = n + #item + 1
                        end
                        coop.sendEvent("DB", d.name .. " " .. kind .. " " .. table.concat(line, " "))
                        said = said + #out
                    end
                end
                d.seen = seen
                if said > 0 then
                    log(string.format("Story flow: the host was down when %s fell: %d of its steps here told to the host.",
                        d.name, said))
                end
                if d.step > #DOWN_AT then
                    table.remove(flow.downFlow, i)
                end
            end
        end
    end

    -- Host: a boss owed that got up again (coop's shareEnemy): its fall was a phase's, and what a guest's world added at it
    -- isn't a win here. (pbz.lua's game.dropOwed for its pay.)
    function flow.dropOwed(name)
        for key, whose in pairs(flow.owedFlow) do
            if whose == name then
                flow.owedFlow[key], flow.again[key] = nil, nil
            end
        end
    end

    coop.handlers.DB = function(rest)
        if not coop.isHost() or type(rest) ~= "string" or #rest > CHUNK + 220 then
            return
        end
        local name, kind, items = rest:match("^(%S+) ([tn]) (.+)$")     -- (never a bell: see above)
        -- (owedNames outlives the pay, for this: a guest's word comes over the 20 s after its own death of the boss, and
        -- its look waits out a scene there. pbz.lua's oweBoss.)
        local owed = name and game.owedNames and game.owedNames[name]
        if not (owed and os.clock() - owed < DOWN_OWED_S) then
            return
        end
        local n = 0
        for _ in pairs(flow.owedFlow) do
            n = n + 1
        end
        for item in items:gmatch("%S+") do
            if #item <= 200 and n < DOWN_MAX and not (kind == "t" and (skipped(item)
                or (game.isHeldFlag and game.isHeldFlag(item)))) then
                if not flow.owedFlow[kind .. " " .. item] then
                    n = n + 1
                end
                flow.owedFlow[kind .. " " .. item] = name
            end
        end
    end

    -- Host: what a boss's win added in a guest's world, for one that fell while this player was down, taken here once
    -- they're up and settled, as its pay is (coop's watchOwnDeath), and calm. What this world has already is let go.
    local function takeOwedFlow()
        local net = coop.net
        if next(flow.owedFlow) == nil or net.deadSince ~= nil or os.clock() - (net.upAt or -1e9) < (net.OWED_AFTER_S or 15)
            or not calm() then
            return
        end
        local ep, bm = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager")
        local have = valid(ep) and valid(bm) and read()
        if not have then
            return
        end
        local done, already, names = 0, 0, {}
        game.granting = true        -- (what a step hands out isn't sent back as found)
        for key, name in pairs(flow.owedFlow) do
            local kind, item = key:match("^(%a) (.+)$")
            if have[kind][item] then
                flow.owedFlow[key], flow.again[key] = nil, nil
                already = already + 1
            else
                local ok = pcall(function()
                    if kind == "t" then
                        ep:AddTagsByString(item)
                    else
                        ep.ExecuteNodeGuid:Add(item, true)
                    end
                end)
                if ok or not tryAgain(key) then
                    flow.owedFlow[key] = nil
                    if ok then
                        done = done + 1
                        names[name] = true
                        flow.again[key] = nil
                    end
                end
            end
        end
        game.granting = false
        if done > 0 then
            local list = {}
            for name in pairs(names) do
                list[#list + 1] = name
            end
            log(string.format("Story flow: %d of the steps of %s's win taken here from the others' worlds (%d here already): "
                .. "you were down when it fell.", done, table.concat(list, ", "), already))
        end
    end

    local function guestTick()
        if (#flow.queue > 0 or next(flow.pending) ~= nil) and game.inPrologue and game.inPrologue() then
            flow.queue, flow.pending, flow.again = {}, {}, {}   -- (nothing of the host's into this player's prologue: see hostTick)
            return
        end
        -- (Not following now, or the host's story table another: what waits is let go, one to be tried again too.)
        if (#flow.queue > 0 or next(flow.pending) ~= nil) and api.story
            and (api.story.follow == false or api.story.mismatch) then
            flow.queue, flow.pending, flow.again = {}, {}, {}
            return
        end
        if (#flow.queue == 0 and next(flow.pending) == nil) or not calm() then
            return
        end
        local ep, bm = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager")
        if not (valid(ep) and valid(bm)) then
            return
        end
        -- (Only bells waiting: theirs alone are read, not the thousands of flags, once a second.)
        local have = #flow.queue > 0 and read() or { t = {}, n = {}, b = readBells(bm) }
        local done, kept, lost = 0, {}, 0
        game.granting = true        -- (what a flow step hands out isn't sent back as found)
        for _, q in ipairs(flow.queue) do
            local key = q.kind .. " " .. q.item
            if have[q.kind][q.item] then
                flow.again[key] = nil
            elseif q.kind == "b" then
                flow.pending[q.item] = true         -- (lit when this player stands by it: lightNearBells)
            else
                local ok = pcall(function()
                    if q.kind == "t" then
                        ep:AddTagsByString(q.item)
                    else
                        ep.ExecuteNodeGuid:Add(q.item, true)
                    end
                end)
                have[q.kind][q.item] = true         -- (the same one twice in the queue, a relink's say: once)
                if ok then
                    done = done + 1
                    flow.again[key] = nil
                elseif #kept < AGAIN_MAX and tryAgain(key) then
                    kept[#kept + 1] = q             -- (tried again the next calm second)
                else
                    flow.again[key] = nil
                    lost = lost + 1
                end
            end
        end
        done = done + lightNearBells(bm, have)
        game.granting = false
        flow.queue = kept
        if done > 0 then
            flow.applied = flow.applied + done
            log(string.format("Story flow: %d of the host's flags, flow steps and bells taken here.", done))
        end
        if lost > 0 then
            log(string.format("Story flow: %d of the host's flags and flow steps couldn't be taken here (tried %d times).",
                lost, TRIES))
        end
    end

    -- Flags owed here for what another player found, any role: a pile or chest they searched raised these in their world
    -- (coop.lua's OF), and ours went with their search; a thing of theirs that came here has its own while it's held
    -- (pbz.lua's grantLoot). Raised when it's calm, as the host's are on a guest; one this world has already is left alone.
    -- { tag, why } each.
    flow.owed = {}
    function flow.raise(tags, why)
        for _, tag in ipairs(tags or {}) do
            if type(tag) == "string" and tag ~= "" and not tag:find("%s") and not skipped(tag) and #flow.owed < 200 then
                flow.owed[#flow.owed + 1] = { tag = tag, why = why }
            end
        end
    end

    local function raiseOwed()
        if game.inPrologue and game.inPrologue() then
            flow.owed = {}          -- (nothing of another's into this player's prologue: see hostTick)
            return
        end
        local ep = FindFirstOf("EventPipelineManager")
        if not (calm() and valid(ep)) then
            return
        end
        local have = {}
        pcall(function()
            ep.GlobalTags.GameplayTags:ForEach(function(_, t)
                have[t:get().TagName:ToString()] = true
            end)
        end)
        local raised, kept, lost = {}, {}, 0
        game.granting = true        -- (what a flow they wake hands out isn't sent back as found)
        for _, o in ipairs(flow.owed) do
            local key = "o " .. o.tag
            if have[o.tag] then
                flow.again[key] = nil
            elseif pcall(function() ep:AddTagsByString(o.tag) end) then
                have[o.tag] = true
                raised[#raised + 1] = o.tag
                flow.again[key] = nil
            elseif tryAgain(key) then
                have[o.tag] = true      -- (the same one twice in the list: kept once)
                kept[#kept + 1] = o     -- (a call that failed: tried again a calm second on, as the host's flags are)
            else
                lost = lost + 1
            end
        end
        game.granting = false
        flow.owed = kept
        if #raised > 0 then
            log("Story flow: " .. table.concat(raised, " ") .. " raised here, for what the other player found.")
        end
        if lost > 0 then
            log(string.format("Story flow: %d flag%s for what the other player found couldn't be raised here (tried %d times).",
                lost, lost == 1 and "" or "s", TRIES))
        end
    end

    -- A loop of its own, once a second on the game thread: as an entry of coop.extraTicks it was gone on the bench after
    -- a while, cause not found, and the host told nothing.
    local nextGuest = 0
    local function tick()
        local now = os.clock()
        if not (coop.net and coop.net.enabled) then
            flow.told, flow.sent, flow.seen, flow.linkedN, flow.pending, flow.again = nil, {}, nil, 0, {}, {}
            -- (And what waits, a call to try again among it: kept, it was taken at the next session's first calm second,
            -- maybe in another save. The review of 339d057.)
            flow.queue, flow.owed, flow.downFlow, flow.owedFlow = {}, {}, {}, {}
            return
        end
        -- Not in a PvP match: nothing a match changes is saved, and the story's flow isn't the match's. After it the host
        -- takes its world as it finds it for the baseline (what the match's maps did is never sent); a guest holds what
        -- came before it until it's over. (Its own loop: coop's ARENA_SKIPS never reached it; the review of the reports.)
        if coop.net.arena then
            flow.rebase, flow.seen = true, nil
            return
        end
        if os.clock() < (coop.net.quietUntil or 0) then
            return          -- (the quiet after a load or a trip: see coop's QUIET_AFTER_LOAD_S)
        end
        if #flow.owed > 0 then
            local ok, err = pcall(raiseOwed)
            if not ok and err ~= flow.lastError then
                flow.lastError = err
                log("Story flow: " .. tostring(err))
            end
        end
        -- (A boss's win's steps for a host down when it fell: on their own, not stopped by an error of the ticks above.)
        local job = coop.isHost() and next(flow.owedFlow) ~= nil and takeOwedFlow
            or not coop.isHost() and #flow.downFlow > 0 and now >= nextGuest and tellDownFlow
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
        if job then
            local ok, err = pcall(job, now)
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
