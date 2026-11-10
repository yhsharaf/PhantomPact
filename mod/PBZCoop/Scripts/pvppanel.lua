-- The PvP page (F6): the match the host sets (mode, clock, arena), who's in it and on which team, ready or not, and this
-- player's own loadout (two weapons, two Phantom Edge weapons, any in the game). Drawn and read as the online panel is
-- (onlinepanel.lua, panel.lua's kit): pictures from art/make_pvp_art.py, words that change in the game's ink-bar text.
-- arena.lua does the match; this page only asks for it.

return function(api)
    local log, valid, hud, game, kit = api.log, api.valid, api.hud, api.game, api.panel.kit
    local arena, data = api.arena, api.arenaData

    local KEY_MS = 40
    local TICK_MS = 15
    local WORDS_S = 0.5
    local NO_MOUSE_S = 3.0
    local REFOCUS_S = 0.5
    local Z = 900
    local CARD_W, CARD_H = 176, 58
    local BUTTON_W, BUTTON_H = 170, 46
    local ARENA_W, ARENA_H = 160, 104
    local W_CARD_W, W_CARD_H = 160, 52
    local WORDS_Y = 322
    local WORDS_FIT = 110           -- letters a line in the box holds before it breaks (lang.fit)
    local TIP_FROM_BOTTOM = 30
    local CLOSE = { x = 848, y = 14, w = 38, h = 38 }
    local MODES = { duel = { x = 40, y = 118 }, death = { x = 228, y = 118 } }
    local CLOCK = { x = 416, y = 118 }
    local CLOCKS = { 0, 60, 90, 120 }
    local MAIN = { x = 690, y = 124 }       -- READY, START or LEAVE
    local ARENA_Y = 204
    local ARENA_X = { 40, 208, 376, 544, 712 }      -- here, then the four in arenas.lua's order
    local ROW_Y, ROW_STEP = 372, 28
    local TEAM_X, TICK_X = 296, 402
    local SLOTS = {
        { key = "main1", kind = "main", n = 1, x = 478, y = 388 },
        { key = "main2", kind = "main", n = 2, x = 668, y = 388 },
        { key = "edge1", kind = "edge", n = 1, x = 478, y = 454 },
        { key = "edge2", kind = "edge", n = 2, x = 668, y = 454 },
    }
    local PICK_X, PICK_Y, PICK_STEP_X, PICK_STEP_Y = 40, 90, 164, 60
    local BACK = { x = 40, y = 494 }

    local panel = { open = false }
    local pc = nil
    local wasKey, wasDown, keyArmed, keyHeld, escHeld = false, false, false, false, false
    local wasFocused, clicksFrom, mouseAt = false, 0, 0
    local page, picking = "main", nil      -- picking: the SLOTS entry being chosen for
    local words, wordsWidget, wordsAt = nil, nil, 0

    local function worded(name, tex, w, h, z)
        tex = api.lang.prefix() .. tex
        local p = kit.part(name, tex, w, h, z)
        kit.picture(p, tex)
        return p
    end

    local function plain(name, tex, w, h, z)
        local p = kit.part(name, tex, w, h, z)
        kit.picture(p, tex)
        return p
    end

    -- A weapon's card: the game's own names for it, so its Chinese in Chinese and its English otherwise, Arabic too: the
    -- game has no Arabic, so players know the weapons by those (the user, 11-10).
    local function named(name, tex, w, h, z)
        if api.lang.code == "zh" then
            return worded(name, tex, w, h, z)
        end
        return plain(name, tex, w, h, z)
    end

    local function isHost()
        return api.coop.isHost()
    end

    -- The lobby as this player sees it: the host's own, or what the host said.
    local function lobby()
        if isHost() then
            local players = {}
            for _, s in ipairs(arena.everyone()) do
                local p = arena.picks[s] or {}
                players[s] = { team = p.team or (s == arena.mySlot() and arena.pick.team) or 0, ready = s == arena.mySlot() or p.ready,
                    arenas = s == arena.mySlot() and "self" or p.arenas }
            end
            return { mode = arena.mode, timer = arena.timer, place = arena.place, players = players }
        end
        return arena.lobby or { mode = arena.mode, timer = arena.timer, place = arena.place, players = {} }
    end

    -- An arena everyone in the lobby has beaten (this player's own from the save, the rest from what they said).
    local function open(key, l)
        for slot, p in pairs(l.players) do
            local have = p.arenas == "self" and arena.unlocked[key] or (slot == arena.mySlot() and arena.unlocked[key])
                or ((p.arenas or ""):find(key, 1, true) ~= nil)
            if not have then
                return false
            end
        end
        return arena.unlocked[key] == true
    end

    ------------------------------------------------------------------ the words

    local function describe()
        local m = arena.match
        if m then
            return "In a match: LEAVE twice ends it for everyone."
        end
        if not api.coop.net.enabled then
            return "Play online first (F5): PvP is between linked players. Your loadout is kept for when you are."
        end
        if isHost() then
            local why = arena.blocker()
            return why or "Everyone's ready: START when you are."
        end
        local l = arena.lobby
        if not l then
            return "Waiting to hear the host's match (the host needs Phantom Pact " .. api.version .. ")."
        end
        if arena.pick.ready then
            return "You're ready. The host starts the match."
        end
        return "Set your loadout, pick a team, then READY."
    end

    local function showWords(now)
        if now < wordsAt then
            return
        end
        wordsAt = now + WORDS_S
        local text = page == "pick" and "Click one to take it; BACK keeps what you had." or describe()
        if not api.status.onScreen(wordsWidget) then
            wordsWidget, words = api.status.newTipWidget(Z + 5), nil
        end
        if not wordsWidget then
            return
        end
        if words == nil then
            pcall(function() wordsWidget:PlayAnimation(wordsWidget.FadeIn, 0, 1, 0, 1, false) end)
        end
        if text ~= words then
            words = text
            if api.lang.arabic() then
                wordsWidget:SetText(FText(api.lang.fit(text, WORDS_FIT)))    -- (hidden, for the bar's size: pbz.lua)
                game.arabicTip(wordsWidget, api.lang.say(text), nil, 1100)    -- (wrapped inside the box)
            else
                if game.arabicTipUsed then
                    game.arabicTip(wordsWidget, nil)
                end
                wordsWidget:SetText(FText(api.lang.fit(api.lang.say(text), WORDS_FIT)))
            end
        end
        local o = kit.origin
        local screenH = 2 * o.y + kit.H * o.scale
        wordsWidget:SetRenderTranslation({ X = 0, Y = o.y + WORDS_Y * o.scale - (screenH - TIP_FROM_BOTTOM) })
        hud.show(wordsWidget, true)
    end

    ------------------------------------------------------------------ presses

    local function hostOnly()
        if not isHost() then
            api.status.lastShown.arena = nil
            api.status.notify("arena", "the host sets the match.")
            return true
        end
        return false
    end

    local function showPage(name)
        page = name
        for _, p in pairs(kit.parts) do
            hud.show(p.widget, false)
        end
        hud.show(wordsWidget, false)
        words, wordsAt = nil, 0
    end

    local function pressPick(x, y)
        if kit.inside(x, y, BACK, BUTTON_W, BUTTON_H) then
            showPage("main")
            return
        end
        local list = picking.kind == "main" and data.weapons or data.edges
        for i, w in ipairs(list) do
            local cx = PICK_X + ((i - 1) % 5) * PICK_STEP_X
            local cy = PICK_Y + math.floor((i - 1) / 5) * PICK_STEP_Y
            if kit.inside(x, y, { x = cx, y = cy }, W_CARD_W, W_CARD_H) then
                local p = arena.preset or arena.loadPreset()
                local set = { main = { p.main[1], p.main[2] }, edge = { p.edge[1], p.edge[2] } }
                local other = set[picking.kind][3 - picking.n]
                if other == w.id then
                    set[picking.kind][3 - picking.n] = set[picking.kind][picking.n]     -- (the two swap places)
                end
                set[picking.kind][picking.n] = w.id
                arena.savePreset(set)
                log("PvP loadout: " .. table.concat(arena.preset.main, ", ") .. " | " .. table.concat(arena.preset.edge, ", "))
                showPage("main")
                return
            end
        end
    end

    local function press(x, y)
        if kit.inside(x, y, CLOSE) then
            panel.close()
            return
        end
        if page == "pick" then
            pressPick(x, y)
            return
        end
        if kit.inside(x, y, MAIN, BUTTON_W, BUTTON_H) then
            if arena.match then
                if arena.leave() then
                    panel.close()
                end
            elseif isHost() then
                if arena.start() then
                    panel.close()
                end
            else
                arena.setPick(nil, not arena.pick.ready)
            end
            wordsAt = 0
            return
        end
        for key, r in pairs(MODES) do
            if kit.inside(x, y, r, CARD_W, CARD_H) and not hostOnly() then
                arena.choose("mode", key)
            end
        end
        if kit.inside(x, y, CLOCK, CARD_W, CARD_H) and not hostOnly() then
            local next = CLOCKS[1]
            for i, v in ipairs(CLOCKS) do
                if v == arena.timer then
                    next = CLOCKS[i % #CLOCKS + 1]
                end
            end
            arena.choose("timer", next)
        end
        for i, ax in ipairs(ARENA_X) do
            if kit.inside(x, y, { x = ax, y = ARENA_Y }, ARENA_W, ARENA_H) and not hostOnly() then
                local place = i - 1
                local a = data.arena(place)
                if place > 0 and not open(a.key, lobby()) then
                    api.status.lastShown.arena = nil
                    api.status.notify("arena", "everyone needs " .. a.boss .. " beaten in their own game for that arena.")
                else
                    arena.choose("place", place)
                end
            end
        end
        -- This player's own team: the tag on their own row.
        local l = lobby()
        local rows = {}
        for slot in pairs(l.players) do
            rows[#rows + 1] = slot
        end
        table.sort(rows)
        for i, slot in ipairs(rows) do
            if slot == arena.mySlot() and kit.inside(x, y, { x = TEAM_X, y = ROW_Y + (i - 1) * ROW_STEP }, 96, 24) then
                if #rows <= 2 then
                    api.status.lastShown.arena = nil
                    api.status.notify("arena", "two players: one team each.")
                else
                    local mine = (l.players[slot] and l.players[slot].team) or arena.pick.team or 1
                    arena.setPick(mine == 1 and 2 or 1, nil)
                end
            end
        end
        for _, s in ipairs(SLOTS) do
            if kit.inside(x, y, { x = s.x, y = s.y }, W_CARD_W, W_CARD_H) then
                if arena.match then
                    api.status.lastShown.arena = nil
                    api.status.notify("arena", "the loadout changes for the next match.")
                end
                picking = s
                showPage("pick")
                return
            end
        end
    end

    ------------------------------------------------------------------ drawing

    local function drawMain()
        local l = lobby()
        kit.place(worded("pv_bg", "pvp_bg", kit.W, kit.H, 0), 0, 0)
        kit.place(plain("pv_close", "close", CLOSE.w, CLOSE.h, 1), CLOSE.x, CLOSE.y)
        local host = isHost()
        for key, r in pairs(MODES) do
            local p = worded("pv_mode_" .. key, "pvp_mode_" .. key, CARD_W, CARD_H, 1)
            kit.place(p, r.x, r.y)
            kit.dim(p, (host or l.mode == key) and 1.0 or 0.45)
        end
        local mode = MODES[l.mode] or MODES.duel
        kit.place(plain("pv_sel_mode", "sel_card", CARD_W, CARD_H, 2), mode.x, mode.y)
        local clock = worded("pv_clock", "pvp_clock_" .. tostring(l.timer or 0), CARD_W, CARD_H, 1)
        kit.place(clock, CLOCK.x, CLOCK.y)
        kit.dim(clock, host and 1.0 or 0.75)
        for i, ax in ipairs(ARENA_X) do
            local place = i - 1
            local a = data.arena(place)
            local locked = place > 0 and not open(a.key, l)
            local p = worded("pv_arena_" .. a.key, "pvp_arena_" .. a.key .. (locked and "_locked" or ""), ARENA_W, ARENA_H, 1)
            kit.place(p, ax, ARENA_Y)
        end
        kit.place(plain("pv_sel_arena", "pvp_sel_arena", ARENA_W, ARENA_H, 2), ARENA_X[(l.place or 0) + 1], ARENA_Y)
        -- The button: LEAVE in a match, START for the host (faded while something stops it), READY for a guest.
        local tex
        if arena.match then
            tex = "pvp_leave"
        elseif host then
            tex = arena.blocker() and "pvp_start_off" or "pvp_start"
        else
            tex = arena.pick.ready and "pvp_ready_on" or "pvp_ready"
        end
        kit.place(worded("pv_main", tex, BUTTON_W, BUTTON_H, 1), MAIN.x, MAIN.y)
        -- Who's in.
        local rows = {}
        for slot in pairs(l.players) do
            rows[#rows + 1] = slot
        end
        table.sort(rows)
        for i = 1, 6 do
            local slot = rows[i]
            if slot then
                local y = ROW_Y + (i - 1) * ROW_STEP
                local p = l.players[slot]
                -- (PLAYER n in English and Chinese, as before; اللاعب n in Arabic: art/make_arabic_art.py.)
                local row = (api.lang.arabic() and "ar_" or "") .. "pvp_row_" .. slot
                kit.place(plain("pv_row" .. i, row, 250, 26, 1), 40, y)
                local team = (p.team and p.team > 0) and p.team or 1
                local tag = worded("pv_team" .. i, "pvp_team_" .. team, 96, 24, 1)
                kit.place(tag, TEAM_X, y + 1)
                kit.dim(tag, slot == arena.mySlot() and 1.0 or 0.8)
                kit.place(plain("pv_tick" .. i, "pvp_tick_" .. (p.ready and 1 or 0), 26, 26, 1), TICK_X, y)
            else
                kit.hide("pv_row" .. i)
                kit.hide("pv_team" .. i)
                kit.hide("pv_tick" .. i)
            end
        end
        -- The loadout.
        local preset = arena.preset or arena.loadPreset()
        for _, s in ipairs(SLOTS) do
            kit.place(worded("pv_slot_" .. s.key, "pvp_slot_" .. s.key, 176, 18, 1), s.x, s.y - 18)
            local id = preset[s.kind][s.n]
            kit.place(named("pv_w_" .. s.key, "pvp_w_" .. id, W_CARD_W, W_CARD_H, 1), s.x, s.y)
        end
    end

    local function drawPick()
        kit.place(worded("pv_pick_bg", "pvp_pick_" .. picking.kind, kit.W, kit.H, 0), 0, 0)
        kit.place(plain("pv_close", "close", CLOSE.w, CLOSE.h, 1), CLOSE.x, CLOSE.y)
        kit.place(worded("pv_back", "pvp_back", BUTTON_W, BUTTON_H, 1), BACK.x, BACK.y)
        local list = picking.kind == "main" and data.weapons or data.edges
        local preset = arena.preset or arena.loadPreset()
        local now = preset[picking.kind][picking.n]
        for i = 1, 20 do
            local w = list[i]
            if w then
                local cx = PICK_X + ((i - 1) % 5) * PICK_STEP_X
                local cy = PICK_Y + math.floor((i - 1) / 5) * PICK_STEP_Y
                kit.place(named("pv_pick" .. i, "pvp_w_" .. w.id, W_CARD_W, W_CARD_H, 1), cx, cy)
                if w.id == now then
                    kit.place(plain("pv_sel_weapon", "pvp_sel_weapon", W_CARD_W, W_CARD_H, 2), cx, cy)
                end
            else
                kit.hide("pv_pick" .. i)
            end
        end
    end

    local function tick()
        if not panel.open then
            return
        end
        if not valid(pc) then
            panel.close()
            return
        end
        kit.measure(pc)
        local x, y, down, esc, key, focused = kit.input()
        if x ~= nil then
            mouseAt = os.clock()
        elseif os.clock() - mouseAt > NO_MOUSE_S then
            log("PvP page: no mouse from main.dll, closing.")
            panel.close()
            return
        end
        if focused and not wasFocused then
            clicksFrom = os.clock() + REFOCUS_S
        end
        wasFocused = focused
        if x ~= nil and focused then
            if down and not wasDown and os.clock() >= clicksFrom then
                press(x, y)
            end
            wasDown = down
            if not panel.open then
                return
            end
            -- Closed on the key's release (F6, or Esc), so the game doesn't see it go down too.
            keyArmed = keyArmed or not key
            keyHeld = keyHeld or (keyArmed and key)
            if (escHeld and not esc) or (keyHeld and not key) then
                if page == "pick" and escHeld and not esc then
                    showPage("main")
                else
                    panel.close()
                    return
                end
            end
            escHeld = esc
        end
        if page == "pick" then
            drawPick()
        else
            drawMain()
        end
        showWords(os.clock())
    end

    local function canOpen(controller, pawn)
        return not (api.gs():IsGamePaused(controller) or game.inCutscene() or game.isDead(pawn)
            or api.localcoop.bellMenuUp() or api.localcoop.screenUp() or (api.onlinepanel and api.onlinepanel.open))
    end

    function panel.show()
        local controller, pawn = api.getPlayer1()
        if panel.open or not valid(pawn) or not canOpen(controller, pawn) then
            return
        end
        pc = controller
        for name, p in pairs(kit.parts) do
            if not api.status.onScreen(p.widget) then
                kit.parts[name] = nil
            end
        end
        arena.readUnlocked()
        arena.loadPreset()
        if not isHost() and api.coop.net.enabled then
            arena.setPick(nil, nil)     -- (the host hears this player's arenas and version)
        end
        panel.open = true
        page, picking = "main", nil
        wasDown, keyArmed, keyHeld, escHeld, wasFocused, clicksFrom = false, false, false, false, true, os.clock() + REFOCUS_S
        words, wordsAt, mouseAt = nil, 0, os.clock()
        os.remove(api.modDir() .. "mouse.txt")
        kit.writeWant(true)
        kit.blockPlay(pc, true)
        log("PvP page open.")
    end

    function panel.close()
        if not panel.open then
            return
        end
        panel.open = false
        kit.writeWant(false)
        for _, p in pairs(kit.parts) do
            hud.show(p.widget, false)
        end
        hud.show(wordsWidget, false)
        if valid(pc) then
            kit.blockPlay(pc, false)
        end
        log("PvP page closed.")
    end

    -- F6, read on the game thread as F5 is. In a match the page opens too: LEAVE is there.
    local function readKey()
        local controller, pawn = api.getPlayer1()
        if not valid(pawn) then
            wasKey = false
            return
        end
        local key = controller:IsInputKeyDown(kit.key("F6"))
        if key and not wasKey and not panel.open then
            panel.show()
        end
        wasKey = key
        -- F in a match's finishing window: the blow on the nearest fallen foe. On a pad, the game's own use button (B, or
        -- Circle: what player 2 uses with in split screen), so a pad player needn't reach for the keyboard.
        -- And the host's F on the last screens: a rematch where they stand (arena.again).
        local m = arena.match
        local again = m and m.phase == "result" and isHost()
        if m and (m.phase == "finish" or again) and not panel.open then
            local f = controller:IsInputKeyDown(kit.key("F")) or controller:IsInputKeyDown(kit.key("Gamepad_FaceButton_Right"))
            if f and not panel.wasF then
                if again then
                    arena.again()
                else
                    arena.finishNearest()
                end
            end
            panel.wasF = f
        end
    end

    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then
            log("PvP page error: " .. tostring(err))
            if panel.open then
                pcall(panel.close)
            end
        end
    end

    function panel.start()
        LoopInGameThreadWithDelay(KEY_MS, function()
            guarded(readKey)
            return false
        end)
        LoopInGameThreadWithDelay(TICK_MS, function()
            guarded(tick)
            return false
        end)
    end

    -- pvppanel toggle | press <x> <y> | pick <slot key> <id>: what the keys and the mouse do, for tests.
    function panel.command(rest)
        local word, a, b = (rest or ""):match("^(%S*)%s*(%S*)%s*(%S*)")
        if word == "toggle" then
            if panel.open then
                panel.close()
            else
                panel.show()
            end
        elseif word == "press" then
            press(tonumber(a), tonumber(b))
        end
        log("PvP page " .. (panel.open and "open" or "closed") .. " (" .. page .. "): " .. describe())
    end

    return panel
end
