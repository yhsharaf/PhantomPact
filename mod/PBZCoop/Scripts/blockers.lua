-- What a player breaks with a Phantom Edge out of a fight (iron chains cut with the giant axe, "MainCh1-NiLiuErShang_S3"),
-- broken in every world on that map. The game's blockers (BP_GameplayBlocker_Base_C) keep their own state, bBroken, and
-- break through their own success step: unsynced, the chains stood whole in the partner's world, and the partner could
-- only get past where the other's world had them broken.
--
-- Each PC looks at the blockers near its player now and then; one that has just broken there, by this player's hand, goes
-- out as "BLK <name>" (a level actor's name: the same on every PC). Each other PC on that map breaks its own through the
-- game's own step (SuccessInteraction, which breaks it and saves it as broken), if it's still whole there.

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
    local seen = {}                 -- blocker name -> bBroken as last looked at
    local lookAt, seenMap = 0, nil

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

    local function watch(now)
        if now < lookAt then
            return
        end
        lookAt = now + LOOK_S
        local pawn = coop.localPawn()
        if not valid(pawn) then
            return
        end
        if net.localMap ~= seenMap then
            seen, seenMap = {}, net.localMap      -- (another map: what was seen is another level's)
        end
        local here = pawn:K2_GetActorLocation()
        for _, b in ipairs(all()) do
            if valid(b) then
                local name, broken = nameOf(b), isBroken(b)
                if name then
                    local was = seen[name]
                    seen[name] = broken
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

    coop.handlers.BLK = function(rest, from)
        local name = type(rest) == "string" and rest:match("^(BP_[%w_]+)$")
        if not name or #name > MAX_NAME then
            return
        end
        -- (Only from a player on this map: the names are only unique within one.)
        local p = coop.peerOf(from)
        local t = p and p.target
        if not (t and t.Map and t.Map == net.localMap) then
            return
        end
        for _, b in ipairs(all()) do
            if valid(b) and nameOf(b) == name then
                if not isBroken(b) then
                    pcall(function() b:SuccessInteraction() end)
                    if not isBroken(b) then
                        pcall(function() b:Break() end)
                        pcall(function() b:RefreshVisual(true) end)
                    end
                    seen[name] = true
                    blockers.broken = blockers.broken + 1
                    log("The other player broke " .. name .. ": broken here too.")
                end
                return
            end
        end
    end

    -- Levers, gates and the like (the game's switches, PBZSwitchBase): opened by one player, open in every world on that
    -- map, as chests and kick-stones already are (those, rubbish piles, fog doors, teleports and bells have their own
    -- handling, or are each player's own). One way only: opened, through the switch's own step without its scene.
    local SWITCH_OWN = { "^BP_Chest", "^BP_Rubbish", "^BP_KickStone", "^BP_FogDoor", "^BP_Teleport", "^BP_MelodiousBell" }
    local switchSeen, switchMap = {}, nil

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
    -- kept a while and opened when it is.
    local OFFER_S, OFFER_BATCH, PENDING_S = 20, 8, 120
    local openNow, pending = {}, {}             -- host: open shared switches as last looked at; guest: name -> since
    blockers.offerAt = 0

    local function openHere(s, name)
        pcall(function() s:SwitchWithoutPlaySequence() end)
        switchSeen[name] = true
        blockers.broken = blockers.broken + 1
        log("The other player opened " .. name .. ": open here too.")
    end

    local function offerOpen(now)
        if coop.isHost and not coop.isHost() or now < blockers.offerAt then
            return
        end
        blockers.offerAt = now + OFFER_S
        local batch = {}
        for name in pairs(openNow) do
            batch[#batch + 1] = name
            if #batch >= OFFER_BATCH then
                coop.sendEvent("SWO", table.concat(batch, " "))
                batch = {}
            end
        end
        if #batch > 0 then
            coop.sendEvent("SWO", table.concat(batch, " "))
        end
    end

    local function watchSwitches(here)
        if net.localMap ~= switchMap then
            switchSeen, switchMap, openNow, pending = {}, net.localMap, {}, {}
        end
        local now = os.clock()
        for name, since in pairs(pending) do
            if now - since > PENDING_S then
                pending[name] = nil
            end
        end
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            if valid(s) and sharedSwitch(s) then
                local name, open = nameOf(s), isOpen(s)
                if name and pending[name] then
                    pending[name] = nil
                    if not open then
                        openHere(s, name)
                        open = true
                    end
                end
                if name then
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

    -- One name, or (the host's again-and-again) several, space apart.
    coop.handlers.SWO = function(rest, from)
        if type(rest) ~= "string" or #rest > (MAX_NAME + 1) * OFFER_BATCH then
            return
        end
        local want = {}
        for name in rest:gmatch("%S+") do
            if #name <= MAX_NAME and name:match("^[%w_]+$") then
                want[name] = true
            end
        end
        if next(want) == nil then
            return
        end
        local p = coop.peerOf(from)
        local t = p and p.target
        if not (t and t.Map and t.Map == net.localMap) then
            return
        end
        if switchMap ~= net.localMap then
            switchSeen, switchMap, openNow, pending = {}, net.localMap, {}, {}
        end
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            local name = valid(s) and nameOf(s)
            if name and want[name] then
                want[name] = nil
                if sharedSwitch(s) and not isOpen(s) then
                    openHere(s, name)
                end
            end
        end
        local now = os.clock()
        for name in pairs(want) do
            pending[name] = pending[name] or now      -- (not loaded here yet: opened when it is)
        end
    end

    -- Nobody else on this map: nobody to tell, so no look at all. (What was seen is kept: one this player broke meanwhile,
    -- still near them, goes out at the first look once a partner is here.)
    local function partnerHere()
        for _, p in ipairs(coop.partners()) do
            local t = p.target
            if t and t.Map and t.Map == net.localMap and not p.partnerGone then
                return true
            end
        end
        return false
    end

    coop.extraTicks.blockers = function()
        local okP, here = pcall(partnerHere)
        if okP and not here then
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
                    watchSwitches(pawn:K2_GetActorLocation())
                    offerOpen(os.clock())
                end
            end
        end)
        if not okS and errS ~= blockers.lastError then
            blockers.lastError = errS
            log("blockers (switches): " .. tostring(errS))
        end
        local ok, err = pcall(watch, os.clock())
        if not ok and err ~= blockers.lastError then
            blockers.lastError = err
            log("blockers: " .. tostring(err))
        end
    end

    return blockers
end
