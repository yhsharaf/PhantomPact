-- Fast travel to the bells you've reached, for free (the user: "once you reach it you can travel to it for free"). A trip
-- from the map takes a Traversal Talisman (Item_Traversing) and can't be made without one. So: one is always in the bag,
-- and what a trip took is given back once there's a body again, talismans of the player's own included. Nothing new is
-- unlocked. Added quietly (no card), and not told to a partner as something found (game.granting, see grantLoot). The
-- talisman can't be sold and does nothing else, so a free one is worth nothing outside a trip.

return function(api)
    local log, valid, game = api.log, api.valid, api.game

    local freetravel = { on = true, given = 0 }

    local ITEM = "Item_Traversing"
    local KEEP = 1                  -- always at least this many, or the map won't make the trip
    local LOOK_MS = 1000
    local TRIP_S = 90               -- a trip's loading screen can be this long; what it took is given back after it

    local HISTORY = 6               -- looks remembered: the talisman can go at the confirm, a moment before the trip itself
    local seen = {}                 -- the counts of the last looks outside a trip, newest last
    local trip = nil                -- { before = count, at = os.clock() } once a trip starts

    local function bag()
        local _, pawn = api.getPlayer1()
        if not valid(pawn) or (game.inCutscene and game.inCutscene()) then
            return nil
        end
        return game.backpackOf(pawn)
    end

    local function add(bp, n, why)
        game.granting = true
        pcall(function() bp:AddPropsToBackPack(n, FName(ITEM), false) end)
        game.granting = false
        freetravel.given = freetravel.given + n
        log(string.format("Free travel: %d Traversal Talisman%s %s.", n, n == 1 and "" or "s", why))
    end

    local function look()
        if not freetravel.on then
            return
        end
        local bp = bag()
        if not bp then
            return
        end
        local have = game.itemCount(bp, ITEM)
        if type(have) ~= "number" then
            return
        end
        if trip then
            if have < trip.before then
                add(bp, trip.before - have, "given back after the trip")
                have = trip.before
                trip = nil
            elseif os.clock() - trip.at > TRIP_S then
                trip = nil
            end
        end
        if have < KEEP then
            add(bp, KEEP - have, "put in the bag, so the map's trips to bells cost nothing")
            have = KEEP
        end
        if not trip then
            seen[#seen + 1] = have
            if #seen > HISTORY then
                table.remove(seen, 1)
            end
        end
    end

    -- A trip starting: the most the bag held in the last few seconds is what comes back.
    local function starting()
        if freetravel.on and #seen > 0 and not trip then
            trip = { before = math.max(table.unpack(seen)), at = os.clock() }
            seen = {}
        end
    end
    for _, fn in ipairs({ "/Script/ProjectPBZ.PBZSaveLoadSubsystem:TeleportTo",
        "/Script/ProjectPBZ.PBZBlueprintFunctionLibrary:PBZActorTeleportTo",
        "/Script/ProjectPBZ.MelodiousBell:TeleportToOther" }) do
        pcall(function() RegisterHook(fn, starting) end)
    end
    pcall(function() RegisterLoadMapPreHook(starting) end)

    LoopInGameThreadWithDelay(LOOK_MS, function()
        local ok, err = pcall(look)
        if not ok and err ~= freetravel.lastError then
            freetravel.lastError = err
            log("Free travel: " .. tostring(err))
        end
        return false
    end)

    return freetravel
end
