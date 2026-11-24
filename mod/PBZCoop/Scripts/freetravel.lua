-- Fast travel to the bells you've reached, for free (the user: "once you reach it you can travel to it for free"). A trip
-- from the map takes a Traversal Talisman (Item_Traversing) and can't be made without one. So: one is always in the bag,
-- and what a trip took is given back once there's a body again, talismans of the player's own included. Nothing new is
-- unlocked. Added quietly (no card), and not told to a partner as something found (game.granting, see grantLoot). The
-- talisman can't be sold and does nothing else, so a free one is worth nothing outside a trip.
--
-- A map that loads is not always a trip: another save loaded from the game's menu comes in the same way, with its own
-- bag. (A play log of 1.7.4, 11-20: a player left one save for another that held eight talismans fewer, and the eight
-- were "given back" into it.) So what the bag has fewer is given only into the save the trip began in: the same save
-- slot, and the story where it stood (story.lua's point), read a moment after the body is back.

return function(api)
    local log, valid, game = api.log, api.valid, api.game

    local freetravel = { on = true, given = 0, refused = 0 }

    local ITEM = "Item_Traversing"
    local KEEP = 1                  -- always at least this many, or the map won't make the trip
    local LOOK_MS = 1000
    local TRIP_S = 90               -- a trip's loading screen can be this long; what it took is given back after it
    local SETTLE_S = 3.0            -- the body back this long before the save is asked which one it is
    local STORY_EVERY_S = 30        -- the story's point is read this often outside a trip, for the next one's "before"

    local HISTORY = 6               -- looks remembered: the talisman can go at the confirm, a moment before the trip itself
    local seen = {}                 -- the counts of the last looks outside a trip, newest last
    local trip = nil                -- { before = count, at = os.clock(), slot, story } once a trip starts
    local slotNow, storyNow, storyAt = nil, nil, 0      -- the save as the last looks outside a trip had it

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

    local function saveSlot()
        local ok, slot = pcall(function() return game.readSaveSlot and game.readSaveSlot() end)
        return ok and type(slot) == "string" and slot ~= "" and slot or nil
    end

    local function storyPoint()
        local ok, row, done = pcall(function() return api.story.point() end)
        return ok and row ~= nil and (tostring(row) .. "/" .. tostring(done)) or nil
    end

    -- Why this isn't the save the trip began in, or nil: another slot, or the story somewhere else.
    local function otherSave(t)
        local slot = saveSlot()
        if t.slot and slot and t.slot ~= slot then
            return "another save slot"
        end
        local story = storyPoint()
        if t.story and story and t.story ~= story then
            return "its story stands elsewhere"
        end
        return nil
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
                trip.backAt = trip.backAt or os.clock()
                if os.clock() - trip.backAt >= SETTLE_S then
                    local why = otherSave(trip)
                    if why then
                        freetravel.refused = freetravel.refused + 1
                        log(string.format("Free travel: this map came with another save (%s): the %d Traversal Talisman%s it has "
                            .. "fewer aren't given.", why, trip.before - have, trip.before - have == 1 and "" or "s"))
                    else
                        add(bp, trip.before - have, "given back after the trip")
                        have = trip.before
                    end
                    trip = nil
                end
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
            slotNow = saveSlot() or slotNow
            if os.clock() >= storyAt then
                storyAt = os.clock() + STORY_EVERY_S
                storyNow = storyPoint() or storyNow
            end
        end
    end

    -- A trip starting: the most the bag held in the last few seconds is what comes back. (The save as the looks before
    -- had it: at a map's load the game may hold the next one already.) byTravel: by the game's own travel calls, a trip for
    -- sure, and the story may have moved since it was last read here (a boss beaten, then straight to the map), so only the
    -- save's slot is asked of it. A map that loads with no such call before it is asked both.
    local function starting(byTravel)
        if freetravel.on and #seen > 0 and not trip then
            trip = { before = math.max(table.unpack(seen)), at = os.clock(), slot = slotNow, story = not byTravel and storyNow or nil }
            seen = {}
            storyAt = 0             -- (and the story is read anew at the first look after it, whichever save that is)
        end
    end
    for _, fn in ipairs({ "/Script/ProjectPBZ.PBZSaveLoadSubsystem:TeleportTo",
        "/Script/ProjectPBZ.PBZBlueprintFunctionLibrary:PBZActorTeleportTo",
        "/Script/ProjectPBZ.MelodiousBell:TeleportToOther" }) do
        pcall(function() RegisterHook(fn, function() starting(true) end) end)
    end
    pcall(function() RegisterLoadMapPreHook(function() starting(false) end) end)

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
