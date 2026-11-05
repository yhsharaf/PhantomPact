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

    local LOOK_S = 0.5              -- the blockers near this player looked at this often
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

    local function watchSwitches(here)
        if net.localMap ~= switchMap then
            switchSeen, switchMap = {}, net.localMap
        end
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            if valid(s) and sharedSwitch(s) then
                local name, open = nameOf(s), isOpen(s)
                if name then
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

    coop.handlers.SWO = function(rest, from)
        local name = type(rest) == "string" and rest:match("^([%w_]+)$")
        if not name or #name > MAX_NAME then
            return
        end
        local p = coop.peerOf(from)
        local t = p and p.target
        if not (t and t.Map and t.Map == net.localMap) then
            return
        end
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            if valid(s) and nameOf(s) == name and sharedSwitch(s) then
                if not isOpen(s) then
                    pcall(function() s:SwitchWithoutPlaySequence() end)
                    switchSeen[name] = true
                    blockers.broken = blockers.broken + 1
                    log("The other player opened " .. name .. ": open here too.")
                end
                return
            end
        end
    end

    coop.extraTicks.blockers = function()
        local okS, errS = pcall(function()
            if os.clock() >= (blockers.switchAt or 0) then
                blockers.switchAt = os.clock() + LOOK_S
                local pawn = coop.localPawn()
                if valid(pawn) then
                    watchSwitches(pawn:K2_GetActorLocation())
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
