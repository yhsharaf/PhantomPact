-- Skip Prologue (a tile in MORE, F5): many players start co-op on a new save, and the prologue (ZhuLinGuWu, the bamboo
-- grove) is a player's own, with a stripped loadout. Anyone can skip it, with a partner or alone: two clicks, the second
-- the "yes". The skip does what the prologue's end does, by the game's own step (game.skipPrologue: the starting gear
-- back, the healing gourd), then leaves it: to the partner if there is one to go to (their story comes with catch-up),
-- else to the valley the prologue ends in, with the valley's first story steps (its map, waking in the valley).
-- The tile: red while in the prologue (and "click again" once clicked), green for anyone past it.

return function(api)
    local log, valid, game = api.log, api.valid, api.game

    local CONFIRM_S = 10            -- the second click within this is the "yes"
    local VALLEY = "PBZ_Xigu_WP"
    -- The valley's first bell (NLES_001, from the game's bell table), near where the prologue's end wakes the player.
    local VALLEY_AT = { X = 4971.7, Y = 280453.5, Z = -32510.2 }
    local OPENING_ROWS = { 1, 2 }   -- storydata.lua: the valley's map, then waking in the valley (chapter 1 begins)
    local ROWS_AFTER_S = 6          -- after the valley's load: the story's managers are up by then
    local ROWS_TRIES = 5

    local skip = { askedAt = -1e9, rowsDue = false }

    -- "done" (past the prologue), "ask" (clicked once: click again to skip) or "todo".
    function skip.state()
        if not (game.inPrologue and game.inPrologue()) then
            return "done"
        end
        if os.clock() < skip.askedAt + CONFIRM_S then
            return "ask"
        end
        return "todo"
    end

    local function openingRows(tries)
        if not skip.rowsDue then
            return
        end
        local _, pawn = api.getPlayer1()
        if game.inPrologue() or not valid(pawn) then
            if tries > 1 then
                game.after(ROWS_AFTER_S, function() openingRows(tries - 1) end)
            end
            return
        end
        local ok, took = pcall(api.story.applyRows, pawn, OPENING_ROWS, "the prologue skip")
        if ok and took then
            skip.rowsDue = false
            log("Prologue skip: the valley's first story steps are done.")
        elseif tries > 1 then
            game.after(ROWS_AFTER_S, function() openingRows(tries - 1) end)
        else
            skip.rowsDue = false
            log("Prologue skip: the game didn't take the valley's first story steps.")
        end
    end

    pcall(function()
        RegisterLoadMapPostHook(function()
            if skip.rowsDue then
                game.after(ROWS_AFTER_S, function() openingRows(ROWS_TRIES) end)
            end
        end)
    end)

    -- A click on the tile. The words to show, or nil once on the way.
    function skip.press()
        local state = skip.state()
        if state == "done" then
            return "you're past the prologue."
        elseif state == "todo" then
            skip.askedAt = os.clock()
            return "click again to skip the prologue: you get the gear and gourd its end gives, and leave it."
        end
        skip.askedAt = -1e9
        local coop = api.coop
        local p = coop.net.enabled and coop.nearestPartner and coop.nearestPartner()
        if p and p.target and not p.partnerGone then
            coop.net.skipAskedAt = os.clock()           -- (this click was the "yes": no second ask there)
            local why = coop.joinPartner(p, true)
            if why ~= "your partner is still in the prologue." then
                return why                              -- (on the way, or why not: the skip waits for the trip)
            end
        end
        -- Alone (or both on new saves): to the valley.
        if not game.skipPrologue() then
            return "the game wouldn't skip the prologue."
        end
        if not game.travel(VALLEY, VALLEY_AT) then
            return "the game wouldn't go there."
        end
        skip.rowsDue = true
        log("Prologue skipped: on the way to the valley.")
        return nil
    end

    -- skipprologue: the tile's two clicks at once, for tests.
    if game.commands then
        game.commands.skipprologue = function()
            if skip.state() == "todo" then
                skip.press()
            end
            log("Prologue skip: " .. tostring(skip.press() or "on the way."))
        end
    end

    return skip
end
