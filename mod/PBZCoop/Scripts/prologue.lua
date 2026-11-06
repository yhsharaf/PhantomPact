-- Skip Prologue (a tile in MORE, F5): many players start co-op on a new save. The game skips its own prologue when a New
-- Game is started with that choice ("66 days"), and that is the way that works: our own skip (1.6.5) gave back the gear
-- and the gourd by the game's own step, but left the player in the prologue's young body (its story tags, zlgw.*, which
-- the game has no call to take away), the wrong build (the user, 11-06). So the tile only says where the game's skip is:
-- red while in the prologue, green past it.
--
-- The game's own skip gives no healing gourd at all (the bench, 11-06: adult body, the valley, no zlgw tags, no
-- medicine), and players of 1.6.3 lost theirs leaving the prologue in co-op. So after each load, once the world has
-- settled, a player past the prologue with no gourd gets one, equipped and full, with no card: host, guest or alone.

return function(api)
    local log, valid, game = api.log, api.valid, api.game

    local skip = {}

    skip.HOW = "to skip the prologue, start a New Game and choose the game's own skip there."
    local GOURD_AFTER_S = 15        -- after a load: past the quiet of coop.lua's QUIET_AFTER_LOAD_S, the bag loaded
    local GOURD_TRIES = 6

    -- "done" (past the prologue) or "todo" (in it).
    function skip.state()
        if game.inPrologue and game.inPrologue() then
            return "todo"
        end
        return "done"
    end

    -- A click on the tile. The words to show.
    function skip.press()
        if skip.state() == "done" then
            return "you're past the prologue."
        end
        return skip.HOW
    end

    -- True if this player has the healing gourd among their medicines; nil if that can't be told yet.
    local function hasGourd(bp)
        local has, read = false, false
        pcall(function()
            bp.MedicineInfos:ForEach(function(k)
                read = true
                if k:get():ToString() == "Hulu" then
                    has = true
                end
            end)
        end)
        return has, read
    end

    local function checkGourd(tries)
        local net = api.coop and api.coop.net
        local _, pawn = api.getPlayer1()
        local busy = not valid(pawn) or game.isDead(pawn) or (game.inCutscene and game.inCutscene())
            or os.clock() < ((net and net.quietUntil) or 0)
        if busy then
            if tries > 1 then
                game.after(GOURD_AFTER_S, function() checkGourd(tries - 1) end)
            end
            return
        end
        if game.inPrologue() then
            return          -- (the prologue's end hands it out itself)
        end
        local bp = game.backpackOf(pawn)
        if not bp then
            return
        end
        if not hasGourd(bp) then
            log("No healing gourd past the prologue (the game's own skip gives none): given, equipped and full.")
            game.giveGourd(true)
        end
    end
    skip.checkGourd = checkGourd

    pcall(function()
        RegisterLoadMapPostHook(function()
            game.after(GOURD_AFTER_S, function()
                local ok, err = pcall(checkGourd, GOURD_TRIES)
                if not ok then
                    log("Gourd check: " .. tostring(err))
                end
            end)
        end)
    end)

    return skip
end
