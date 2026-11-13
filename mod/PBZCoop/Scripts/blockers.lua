-- What a player breaks with a Phantom Edge out of a fight (iron chains cut with the giant axe, "MainCh1-NiLiuErShang_S3"),
-- broken in every world on that map. The game's blockers (BP_GameplayBlocker_Base_C) keep their own state, bBroken, and
-- break through their own success step: unsynced, the chains stood whole in the partner's world, and the partner could
-- only get past where the other's world had them broken.
--
-- Each PC looks at the blockers near its player now and then; one that has just broken there, by this player's hand, goes
-- out as "BLK <name>" (a level actor's name: the same on every PC). Each other PC on that map breaks its own through the
-- game's own step (SuccessInteraction, which breaks it and saves it as broken), if it's still whole there, and one it
-- hasn't loaded yet as it loads. The host names what's broken in its world again now and then, as it does the open
-- switches (offerOpen).

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    -- The blockers near this player looked at this often, and the switches as often, half way between: each look is a
    -- FindAllOf of a whole map (about 2 ms on the bench). At 0.5 s each this was the mod's dearest job on the host (about
    -- 9 ms of game thread a second, plus the searches). A chain or a lever a second late in the partner's world is fine.
    local LOOK_S = 1.5
    local NEAR_CM = 3000            -- one this close that breaks was this player's doing (one far off broke from a load)
    local MAX_NAME = 160

    local blockers = { sent = 0, broken = 0 }
    local seen = {}                 -- blocker name -> bBroken as last looked at, this visit to the map
    local lookAt, seenMap = 0, false
    -- Chains broken in another player's world that this world hasn't loaded yet (far off: the game loads a level's things
    -- only around the player). Broken here as they load. (Only one loaded at the word was broken: one far off stayed
    -- whole here for good, the way past it shut to this player; "unless we're near each other ... certain things don't
    -- sync", a report on 1.7.1.) owed: name -> true; brokenNow (the host's): name -> true for each broken in its world,
    -- named to the guests again every OFFER_S, for one who joined later or was on another map at the word. No more than
    -- MAX_OWED. Kept by map (byMap; the names are a level's own): forgotten at each trip, a chain a guest broke far off
    -- stayed whole when the host came back to it. Forgotten with the session and with a world loaded anew.
    local MAX_OWED = 200
    local byMap = {}                -- map -> { owed, broken, pending, open }
    local owed, brokenNow = {}, {}

    local function mapState(map)
        local key = map or "?"
        local st = byMap[key]
        if not st then
            st = { owed = {}, broken = {}, pending = {}, open = {} }
            byMap[key] = st
        end
        return st
    end

    local function all()
        return FindAllOf("BP_GameplayBlocker_Base_C") or {}
    end

    local function nameOf(b)
        local ok, n = pcall(function() return b:GetFName():ToString() end)
        return ok and n or nil
    end

    local function isBroken(b)
        local ok, v = pcall(function() return b.bBroken end)
        return ok and v == true
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do
            n = n + 1
        end
        return n
    end

    -- Another map: what was seen is another level's; what's owed and broken there is that map's own.
    local function onMap()
        if net.localMap ~= seenMap then
            seen, seenMap = {}, net.localMap
            local st = mapState(seenMap)
            owed, brokenNow = st.owed, st.broken
        end
    end

    -- Through the game's own step (SuccessInteraction, which breaks it and saves it as broken); its visuals by hand if not.
    local function breakHere(b, name, why)
        pcall(function() b:SuccessInteraction() end)
        if not isBroken(b) then
            pcall(function() b:Break() end)
            pcall(function() b:RefreshVisual(true) end)
        end
        seen[name] = true
        blockers.broken = blockers.broken + 1
        log("The other player broke " .. name .. ": broken here too" .. (why or "") .. ".")
    end

    -- alone: nobody else on this map, so only what's owed is broken; the rest isn't looked at (one this player breaks
    -- meanwhile, still near them, goes out at the first look once a partner is here).
    local function watch(now, alone)
        if now < lookAt then
            return
        end
        lookAt = now + LOOK_S
        local pawn = coop.localPawn()
        if not valid(pawn) then
            return
        end
        onMap()
        local here = pawn:K2_GetActorLocation()
        for _, b in ipairs(all()) do
            if valid(b) then
                local name = nameOf(b)
                if name and (owed[name] or not alone) then
                    local broken = isBroken(b)
                    local was = seen[name]
                    if owed[name] then
                        owed[name] = nil
                        if not broken then
                            breakHere(b, name, ", as it loaded")
                            broken = true
                        end
                        was = true      -- (not this player's doing: not told back)
                    end
                    seen[name] = broken
                    brokenNow[name] = broken or nil
                    if was == false and broken then
                        local okL, at = pcall(function() return b:K2_GetActorLocation() end)
                        if okL and at and api.distance(at, here) <= NEAR_CM then
                            blockers.sent = blockers.sent + 1
                            log("Broke " .. name .. ": broken for the others too.")
                            coop.sendEvent("BLK", name)
                        end
                    end
                end
            end
        end
    end

    -- The quiet after a load: no search then (a world search in it once took the game down inside UE4SS, coop.lua's
    -- QUIET_AFTER_LOAD_S). What's named waits, as one not loaded does, for the first look after it.
    local function quiet()
        return os.clock() < (net.quietUntil or 0)
    end

    -- One name as it breaks, or (the host's again-and-again: offerOpen) several, space apart. Those this world knows broken
    -- are passed over; the rest are looked for with one search. (A 1.7.2 PC takes the one name and passes over a list.)
    local OFFER_BATCH = 8
    coop.handlers.BLK = function(rest, from)
        if type(rest) ~= "string" or #rest > (MAX_NAME + 1) * OFFER_BATCH then
            return
        end
        -- (Only from a player on this map: the names are only unique within one.)
        local p = coop.peerOf(from)
        local t = p and p.target
        if not (t and t.Map and t.Map == net.localMap) then
            return
        end
        onMap()
        local want, any = {}, false
        for name in rest:gmatch("%S+") do
            if #name <= MAX_NAME and name:match("^BP_[%w_]+$") and seen[name] ~= true and not owed[name] then
                want[name], any = true, true
            end
        end
        if not any then
            return
        end
        if not quiet() then
            for _, b in ipairs(all()) do
                local name = valid(b) and nameOf(b)
                if name and want[name] then
                    want[name] = nil
                    if not isBroken(b) then
                        breakHere(b, name)
                    end
                    seen[name], brokenNow[name] = true, true
                end
            end
        end
        for name in pairs(want) do
            if count(owed) < MAX_OWED then
                owed[name] = true           -- (not loaded here: broken when it is)
                brokenNow[name] = true
            end
        end
    end

    -- Levers, gates and the like (the game's switches, PBZSwitchBase): opened by one player, open in every world on that
    -- map, as chests and kick-stones already are (those, rubbish piles, fog doors, teleports and bells have their own
    -- handling, or are each player's own). One way only: opened, through the switch's own step without its scene.
    local SWITCH_OWN = { "^BP_Chest", "^BP_Rubbish", "^BP_KickStone", "^BP_FogDoor", "^BP_Teleport", "^BP_MelodiousBell" }
    local switchSeen, switchMap = {}, false

    local function sharedSwitch(s)
        local ok, cn = pcall(function() return s:GetClass():GetFName():ToString() end)
        if not ok then
            return false
        end
        for _, pat in ipairs(SWITCH_OWN) do
            if cn:find(pat) then
                return false
            end
        end
        return true
    end

    local function isOpen(s)
        local ok, v = pcall(function() return s.CurSwitchState end)
        return ok and v == true
    end

    -- What's open in the host's world goes out again now and then, not only as it opens (player report 11-09): a door the
    -- host opened before a guest was on the map, or before it had loaded there, was never told again, and the guest stood
    -- at it shut (a hand-in door, the Phantom Tavern's at Pangzhen), F3 their only way past. A name not loaded here yet is
    -- kept for that map and opened when it loads. (Kept two minutes, one a guest opened far off was let go before anyone
    -- else came there, and nothing told it again: the host only names what its world has loaded open. The host names the
    -- ones it's waiting for too now; a report on 1.7.1.) The host's broken chains go out with them (brokenNow).
    local OFFER_S = 20
    local openNow, pending = {}, {}             -- host: open shared switches as last looked at; any: name -> since
    blockers.offerAt = 0

    local function onSwitchMap()
        if net.localMap ~= switchMap then
            switchSeen, switchMap = {}, net.localMap
            local st = mapState(switchMap)
            openNow, pending = st.open, st.pending
        end
    end

    local function openHere(s, name)
        pcall(function() s:SwitchWithoutPlaySequence() end)
        switchSeen[name] = true
        blockers.broken = blockers.broken + 1
        log("The other player opened " .. name .. ": open here too.")
    end

    -- Names, a batch an event.
    local function tell(kind, set)
        local batch = {}
        for name in pairs(set) do
            batch[#batch + 1] = name
            if #batch >= OFFER_BATCH then
                coop.sendEvent(kind, table.concat(batch, " "))
                batch = {}
            end
        end
        if #batch > 0 then
            coop.sendEvent(kind, table.concat(batch, " "))
        end
    end

    local function offerOpen(now)
        if coop.isHost and not coop.isHost() or now < blockers.offerAt then
            return
        end
        blockers.offerAt = now + OFFER_S
        onSwitchMap()
        local open = {}
        for name in pairs(openNow) do
            open[name] = true
        end
        for name in pairs(pending) do
            open[name] = true
        end
        tell("SWO", open)
        onMap()
        tell("BLK", brokenNow)
    end

    -- alone: as watch's.
    local function watchSwitches(here, alone)
        onSwitchMap()
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            if valid(s) and sharedSwitch(s) then
                local name = nameOf(s)
                if name and (pending[name] or not alone) then
                    local open = isOpen(s)
                    if pending[name] then
                        pending[name] = nil
                        if not open then
                            openHere(s, name)
                            open = true
                        end
                    end
                    openNow[name] = open or nil
                    local was = switchSeen[name]
                    switchSeen[name] = open
                    if was == false and open then
                        local okL, at = pcall(function() return s:K2_GetActorLocation() end)
                        if okL and at and api.distance(at, here) <= NEAR_CM then
                            blockers.sent = blockers.sent + 1
                            log("Opened " .. name .. ": open for the others too.")
                            coop.sendEvent("SWO", name)
                        end
                    end
                end
            end
        end
    end

    -- One name, or (the host's again-and-again) several, space apart. Those this world knows open, or waits for, are
    -- passed over: no search for them every OFFER_S.
    coop.handlers.SWO = function(rest, from)
        if type(rest) ~= "string" or #rest > (MAX_NAME + 1) * OFFER_BATCH then
            return
        end
        local p = coop.peerOf(from)
        local t = p and p.target
        if not (t and t.Map and t.Map == net.localMap) then
            return
        end
        onSwitchMap()
        local want = {}
        for name in rest:gmatch("%S+") do
            if #name <= MAX_NAME and name:match("^[%w_]+$") and switchSeen[name] ~= true and not pending[name] then
                want[name] = true
            end
        end
        if next(want) == nil then
            return
        end
        if not quiet() then
            for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
                local name = valid(s) and nameOf(s)
                if name and want[name] then
                    want[name] = nil
                    if sharedSwitch(s) and not isOpen(s) then
                        openHere(s, name)
                    end
                end
            end
        end
        local now = os.clock()
        for name in pairs(want) do
            if count(pending) < MAX_OWED then
                pending[name] = now     -- (not loaded here yet: opened when it is)
            end
        end
    end

    -- Nobody else on this map: nobody to tell, so only what's owed here is looked for. (What was seen is kept: one this
    -- player broke meanwhile, still near them, goes out at the first look once a partner is here.)
    local function partnerHere()
        for _, p in ipairs(coop.partners()) do
            local t = p.target
            if t and t.Map and t.Map == net.localMap and not p.partnerGone then
                return true
            end
        end
        return false
    end

    local function owedHere()
        local st = byMap[net.localMap or "?"]
        return st ~= nil and (next(st.owed) ~= nil or next(st.pending) ~= nil)
    end

    coop.extraTicks.blockers = function()
        local okP, here = pcall(partnerHere)
        local alone = okP and not here
        if alone and not owedHere() then
            return
        end
        local okS, errS = pcall(function()
            if blockers.switchAt == nil then
                blockers.switchAt = os.clock() + LOOK_S / 2     -- (half way between the blockers' looks)
            end
            if os.clock() >= blockers.switchAt then
                blockers.switchAt = os.clock() + LOOK_S
                local pawn = coop.localPawn()
                if valid(pawn) then
                    watchSwitches(pawn:K2_GetActorLocation(), alone)
                    if not alone then
                        offerOpen(os.clock())
                    end
                end
            end
        end)
        if not okS and errS ~= blockers.lastError then
            blockers.lastError = errS
            log("blockers (switches): " .. tostring(errS))
        end
        local ok, err = pcall(watch, os.clock(), alone)
        if not ok and err ~= blockers.lastError then
            blockers.lastError = err
            log("blockers: " .. tostring(err))
        end
    end

    -- The session over (sync off: coop.lua stops calling extraTicks) or a world loaded anew (a load from the title, no
    -- player in it as it starts): what was owed, waited for and broken was that session's, that world's. Kept, another
    -- save's chains broke as they loaded, and the host named its old world's to the guests.
    local function forgetAll(why)
        local held = 0
        for _, st in pairs(byMap) do
            held = held + count(st.owed) + count(st.pending)
        end
        if held > 0 then
            log(string.format("%d chains and switches waited for here: forgotten (%s).", held, why))
        end
        byMap, seen, switchSeen = {}, {}, {}
        seenMap, switchMap = false, false
        owed, brokenNow, openNow, pending = {}, {}, {}, {}
    end
    LoopInGameThreadWithDelay(1000, function()
        if not net.enabled and next(byMap) ~= nil then
            pcall(forgetAll, "sync off")
        end
        return false
    end)
    pcall(function()
        RegisterLoadMapPreHook(function()
            if not valid(select(2, api.getPlayer1())) then
                pcall(forgetAll, "a world loaded anew")
            end
        end)
    end)

    return blockers
end
