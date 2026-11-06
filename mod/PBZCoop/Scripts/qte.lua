-- A QTE that never ends. Xiaoxue's third phase grabs the player into a QTE (a player report, 11-06): as a guest, failing it
-- left them standing there for good, no retry, no way to move. On a guest that boss is a copy that plays the host's moves,
-- and the grab's own ending (the fail branch that lets go, ends the QTE and gives the player back) belongs to the boss's
-- ability, which the copy doesn't run through. The QTE stayed in the controller's list (PBZPlayerController.QTEManager)
-- with the player's input in its QTE mode.
--
-- So, online and not the host: once a QTE has run STUCK_S (far longer than any real one), each QTE in the list is ended the
-- game's way (FinishQTEObject), the player's input goes back to its default mode, and the controller back to game input.
-- The player can move again, and the boss, the host's, goes on. Logged with what was running, for the next report.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local qte = { STUCK_S = 12, LOOK_MS = 1000, since = nil, freed = 0 }

    -- The controller's running QTEs: { objects } (the map's values that are objects; its keys too, for the log).
    local function running(pc)
        local objs, names = {}, {}
        pcall(function()
            pc.QTEManager:ForEach(function(k, v)
                pcall(function()
                    local key = k:get()
                    names[#names + 1] = valid(key) and key:GetFName():ToString() or tostring(key)
                end)
                pcall(function()
                    local obj = v:get()
                    if valid(obj) then
                        objs[#objs + 1] = obj
                    end
                end)
            end)
        end)
        return objs, names
    end

    local function free(pc, pawn, objs, names)
        local ended = 0
        for _, obj in ipairs(objs) do
            if pcall(function() pc:FinishQTEObject(obj) end) then
                ended = ended + 1
            end
        end
        pcall(function()
            local input = pawn.PBZNBInput
            if valid(input) then
                input:ResetToDefaultInputMode()
            end
        end)
        pcall(function()
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc, false)
        end)
        pcall(function() pc:ResetIgnoreInputFlags() end)
        pcall(function() pawn:EnableInput(pc) end)
        qte.freed = qte.freed + 1
        local active = game.activeAbility and game.activeAbility(pawn, function() return false end)
        log(string.format("A QTE ran %d s with no end (%s): ended (%d), your controls given back. Running: %s.", qte.STUCK_S,
            table.concat(names, ", "), ended, tostring(active)))
    end

    local function look()
        if not (net.enabled and api.coop.isHost and not api.coop.isHost()) then
            qte.since = nil
            return
        end
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) or game.isDead(pawn) or (game.inCutscene and game.inCutscene()) then
            qte.since = nil
            return
        end
        local objs, names = running(pc)
        if #objs == 0 and #names == 0 then
            qte.since = nil
            return
        end
        local now = os.clock()
        qte.since = qte.since or now
        if now - qte.since >= qte.STUCK_S then
            qte.since = nil
            free(pc, pawn, objs, names)
        end
    end

    LoopInGameThreadWithDelay(qte.LOOK_MS, function()
        local ok, err = pcall(look)
        if not ok and err ~= qte.lastError then
            qte.lastError = err
            log("QTE watch: " .. tostring(err))
        end
        return false
    end)

    return qte
end
