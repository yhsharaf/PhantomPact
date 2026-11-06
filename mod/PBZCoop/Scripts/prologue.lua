-- Skip Prologue (a tile in MORE, F5): many players start co-op on a new save. The game skips its own prologue when a New
-- Game is started with that choice ("66 days"), and that is the way that works: our own skip (1.6.5) gave back the gear
-- and the gourd by the game's own step, but left the player in the prologue's young body (its story tags, zlgw.*, which
-- the game has no call to take away), the wrong build (the user, 11-06). So the tile only says where the game's skip is:
-- red while in the prologue, green past it. A player who skipped by the game has no gourd: the host's bag gives it on
-- joining (game.mergeBag).

return function(api)
    local game = api.game

    local skip = {}

    skip.HOW = "to skip the prologue, start a New Game and choose the game's own skip there."

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

    return skip
end
