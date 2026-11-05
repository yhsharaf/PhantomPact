-- The online panel (F5 with any Role but Local): host, join or leave from inside the game, with no ini to edit and no
-- restart. It's drawn and read as the local co-op panel is (panel.lua, whose notes on the mouse hold here too): pictures
-- from art/make_online_panel.py, and the words that change in the game's own ink-bar text. autostart.lua does the
-- connecting (api.online); this file picks what to ask for, keeps it in PhantomPact.ini and says how it's going.

return function(api)
    local log, valid, hud, game, kit = api.log, api.valid, api.hud, api.game, api.panel.kit
    local save = kit.save

    local KEY_MS = 40               -- how often F5 is looked at; a press lasts longer
    local TICK_MS = 15
    local WORDS_S = 0.5
    local NO_MOUSE_S = 3.0          -- no answer from main.dll for this long: the panel couldn't be closed by hand
    local REFOCUS_S = 0.5           -- back in the game: the click that brought you, and main.dll's, press nothing
    local Z = 900
    local CARD_W, CARD_H = 176, 58
    local BUTTON_W, BUTTON_H = 170, 46
    local WORDS_Y = 155             -- middle of the status box, in panel units
    local TIP_FROM_BOTTOM = 30      -- where the game lays out the ink-bar text: centred, this far above the screen's bottom
    local CLOSE = { x = 848, y = 14, w = 38, h = 38 }
    -- main.dll clicks the panel's middle as it opens and on coming back to the game (see free_cursor): no click counts for
    -- REFOCUS_S then.
    local CONNECT = { steam = { x = 40, y = 244 }, tailscale = { x = 228, y = 244 }, other = { x = 416, y = 244 } }
    local PASTE = { x = 604, y = 244 }
    local PASSWORD = { x = 604, y = 344 }
    local BUTTONS = { host = { x = 40, y = 350 }, join = { x = 228, y = 350 }, leave = { x = 416, y = 350 } }
    local LANGUAGE = { en = { x = 40, y = 18 }, zh = { x = 124, y = 18 } }
    local LANGUAGE_W, LANGUAGE_H = 76, 30

    local SETTINGS = { x = 690, y = 494 }
    local BACK = { x = 40, y = 494 }
    -- The gameplay options as square tiles (the user's design, art/make_online_panel.py's TILE): five on top, four centred
    -- below. A click moves a tile to its next choice; one with no choices (Revive, still to come) only shows.
    local TILE = 150
    local TILES = {
        { name = "teleport", x = 41, y = 88, choices = { "off", "on" } },
        { name = "revive", x = 208, y = 88, choices = {} },
        { name = "pvp", x = 375, y = 88, choices = { "off", "on" } },
        { name = "compass", x = 542, y = 88, choices = { "off", "on" } },
        { name = "mapicon", x = 709, y = 88, choices = { "off", "on" } },
        { name = "freetravel", x = 124, y = 255, choices = { "off", "on" } },
        { name = "direct", x = 291, y = 255, choices = { "off", "on" } },
        { name = "players", x = 458, y = 255, choices = { "2", "4", "6" } },
        { name = "mode", x = 625, y = 255, choices = { "multiplayer", "local" } },
    }

    local panel = { open = false }
    local choice = { connect = "tailscale" }
    local pc = nil
    local wasKey, wasDown, keyArmed, keyHeld, escHeld = false, false, false, false, false
    local wasFocused, clicksFrom = false, 0
    local page, options, loggedWords, hasPassword = "main", {}, nil, false
    local words, wordsWidget, wordsAt, note, mouseAt = nil, nil, 0, nil, 0

    ------------------------------------------------------------------ PhantomPact.ini

    -- Other network: any virtual LAN whose addresses the host's filter wouldn't know (ZeroTier, UU Accelerator).
    local function connectIn(settings)
        if (settings and settings.connect or "tailscale"):lower() == "steam" then
            return "steam"
        end
        return (settings and settings.allowanyaddress or "off"):lower() == "on" and "other" or "tailscale"
    end

    local function network(name)
        return { Connect = name == "steam" and "Steam" or "Tailscale", AllowAnyAddress = name == "other" and "On" or "Off" }
    end

    ------------------------------------------------------------------ the settings page

    local function readOptions()
        local s = api.online.settings() or {}
        local function onOff(value, default)
            return (value or default):lower() == "on" and "on" or "off"
        end
        local function partySize(st)
            local n = tonumber(st.partysize)
            if n then
                return n >= 6 and "6" or n >= 4 and "4" or "2"
            end
            return onOff(st.fourplayers, "off") == "on" and "4" or "2"
        end
        options = {
            teleport = onOff(s.partnerteleport, "off"),
            pvp = api.coop.net.party and "off" or onOff(s.pvp, "off"),     -- (off in a party, whatever the ini says)
            compass = onOff(s.partnercompass, "on"),
            mapicon = onOff(s.partnermapicon, "on"),
            freetravel = onOff(s.freebelltravel, "on"),
            revive = "soon",
            direct = onOff(s.steamdirect, "off"),
            players = partySize(s),
            -- Only Role = Local is local: Off, Host and Guest, and a fresh install, are all multiplayer. Read each time this
            -- page opens, as Host, Guest and Leave write Role too.
            mode = (s.role or "off"):lower() == "local" and "local" or "multiplayer",
        }
    end

    -- Kept in PhantomPact.ini, and in force at once. (Steam Direct and the players from the next connection: the relay reads
    -- them as it starts. The players are the host's choice: a guest follows what the host's relay says. Mode from the next start
    -- of the game: Role is read once, and local co-op can't be taken down live.)
    local function choose(row, value)
        options[row] = value
        local on = value == "on"
        local word = on and "On" or "Off"
        if row == "teleport" then
            save({ PartnerTeleport = word })
            api.partner.teleport = on
        elseif row == "pvp" then
            if on and api.coop.net.party then
                options[row] = "off"        -- (false matched neither button: the row showed nothing chosen)
                api.status.notify("pvp", "PvP is off with more than two players.")
                return
            end
            save({ PvP = word })
            api.pvp.command(on and "on" or "off")
            local net = api.coop.net
            if on and net.enabled and not net.partnerGone and net.target then
                api.status.notify("pvp", "your partner needs PvP on too, or their moves won't show here.")
            end
        elseif row == "compass" then
            save({ PartnerCompass = word })
            api.hud.set(on)
        elseif row == "mapicon" then
            save({ PartnerMapIcon = word })
            api.mapicon.on = on
        elseif row == "freetravel" then
            save({ FreeBellTravel = word })
            if api.freetravel then
                api.freetravel.on = on
            end
        elseif row == "direct" then
            save({ SteamDirect = word })
        elseif row == "players" then
            save({ PartySize = value })
            -- (Read by the relay as it starts: said, or a change while hosting looked like it did nothing.)
            local net = api.coop.net
            if api.online and api.online.current() and net.enabled and not api.coop.isHost() then
                api.status.notify("players", "Only the host's Players setting counts.")
            elseif api.online and api.online.current() then
                api.status.notify("players", "Players: from your next Host (Leave, then Host).")
            end
        elseif row == "mode" and value == "local" then
            save({ Role = "Local" })
            api.status.lastShown.mode = nil
            api.status.notify("mode", "Local co-op starts the next time you start the game.")
        elseif row == "mode" and ((api.online.settings() or {}).role or ""):lower() == "local" then
            save({ Role = "Off" })          -- (never over a Host or Guest: this row only undoes Local)
        end
    end

    local function showPage(name)
        page = name
        for _, p in pairs(kit.parts) do
            hud.show(p.widget, false)
        end
        hud.show(wordsWidget, false)
        words = nil
        if name == "settings" then
            readOptions()
        end
    end

    ------------------------------------------------------------------ what's going on, in plain words

    local function relayStatus()
        local line = api.link and api.link.status() or ""
        local kv = {}
        for k, v in line:gmatch("([%w_]+)=(%S+)") do
            kv[k] = v
        end
        kv.error = line:match(" error=(.*)$")       -- the last field, and it may hold spaces
        return kv
    end

    local function describe()
        local c = api.online and api.online.current()
        if not c then
            return note or "Not connected."
        end
        local s = relayStatus()
        if s.stopped == "yes" or s.role ~= c.modRole then
            return s.error and s.role == c.modRole and ("Couldn't start: " .. s.error) or "Starting..."
        end
        if s.connected == "yes" then
            local text = "Connected to " .. (s.peer or "?"):gsub(":%d+$", "") .. "."
            if tonumber(s.rtt_ms) then
                text = text .. " Ping " .. s.rtt_ms .. " ms."
            end
            if s.route and s.route ~= "-" then
                text = text .. " Route: " .. s.route .. "."
            end
            if s.players then
                local here = 1
                for _, p in ipairs(api.coop.partners()) do
                    here = here + ((p.lastRemoteAt and not p.partnerGone) and 1 or 0)
                end
                text = text .. " Players: " .. here .. " of " .. s.players .. "."
                local me = api.coop.players[tonumber(s.slot)]
                if me then
                    text = text .. " You're " .. me.name .. "."
                end
            end
            return text
        end
        if c.modRole == "host" then
            return "Waiting for a partner."
        end
        return c.hostAddress ~= "" and ("Looking for " .. c.hostAddress .. "...")
            or "Looking for a Steam friend who's hosting..."
    end

    local function showWords(now)
        if now < wordsAt then
            return
        end
        wordsAt = now + WORDS_S
        local text = describe()
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
            -- (The ping moves all the time: logged only when something else changes.)
            local plain = text:gsub("%d+ ms", "")
            if plain ~= loggedWords then
                loggedWords = plain
                log("Online panel: " .. text)
            end
            words = text
            wordsWidget:SetText(FText(api.lang.say(text)))
        end
        -- Moved as a picture, up from where the game lays it out: its own layout fills the screen and stays as it is.
        local o = kit.origin
        local screenH = 2 * o.y + kit.H * o.scale
        wordsWidget:SetRenderTranslation({ X = 0, Y = o.y + WORDS_Y * o.scale - (screenH - TIP_FROM_BOTTOM) })
        hud.show(wordsWidget, true)
    end

    ------------------------------------------------------------------ the buttons

    local function act(what)
        note = nil
        wordsAt = 0
        if what == "leave" then
            api.online.stop()
            save({ Role = "Off" })
            return
        end
        local settings = api.online.settings() or {}
        settings.connect = choice.connect == "steam" and "steam" or "tailscale"
        local c, why = api.online.connection(settings, what == "host" and "host" or "guest")
        if not c then
            note = why
            log("Online panel: " .. why)
            if api.online.current() then
                api.status.notify("join", why)      -- (the panel's own line shows the session that's running)
            end
            return
        end
        -- Saved first: the relay reads the ini as it starts.
        local values = network(choice.connect)
        values.Role = what == "host" and "Host" or "Guest"
        save(values)
        api.online.start(c, settings)
    end

    local function clipboard()
        return ((api.link and api.link.paste and api.link.paste() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    -- Tailscale's own menu copies your address: the host sends it, and the guest needs no text file for it.
    local function pasteAddress()
        local text = clipboard()
        wordsAt = 0
        if text == "" or #text > 64 or not text:match("^[%w%.%-:]+$") then
            note = "Copy the host's address first, then press Paste."
            return
        end
        save({ HostAddress = text })
        note = "Host address set to " .. text .. "."
    end

    -- The Secret, which the relay reads from the ini as it starts. Pressed again it goes. It's never shown or logged.
    local function pressPassword()
        wordsAt = 0
        if hasPassword then
            save({ Secret = "" })
            hasPassword = false
            note = "Password removed."
            return
        end
        local text = clipboard()
        if #text > 128 or text:find("%c") or not api.online.signed({ secret = text }) then
            note = "Copy the password first, then press Paste password."
            return
        end
        save({ Secret = text })
        hasPassword = true
        note = "Password set. Your partner needs the same one."
    end

    local function setLanguage(code)
        api.lang.set(code == "zh" and "Chinese" or "English")
        save({ Language = api.lang.word() })
        words, wordsAt = nil, 0
    end

    local function running()
        return api.online and api.online.current() ~= nil
    end

    local function pressSettings(x, y)
        if kit.inside(x, y, BACK, BUTTON_W, BUTTON_H) then
            showPage("main")
            return
        end
        for _, t in ipairs(TILES) do
            if #t.choices > 0 and kit.inside(x, y, t, TILE, TILE) then
                local next = t.choices[1]
                for i, value in ipairs(t.choices) do
                    if value == options[t.name] then
                        next = t.choices[i % #t.choices + 1]
                    end
                end
                choose(t.name, next)
                return
            end
        end
    end

    local function press(x, y)
        if kit.inside(x, y, CLOSE) then
            panel.close()
            return
        end
        if page == "settings" then
            pressSettings(x, y)
            return
        end
        if kit.inside(x, y, SETTINGS, BUTTON_W, BUTTON_H) then
            showPage("settings")
            return
        end
        for name, r in pairs(BUTTONS) do
            if kit.inside(x, y, r, BUTTON_W, BUTTON_H) then
                local c = running() and api.online.current()
                if name == "leave" and c then
                    act("leave")
                elseif name ~= "leave" and not (c and c.modRole == (name == "host" and "host" or "client")) then
                    act(name)
                end
            end
        end
        for code, r in pairs(LANGUAGE) do
            if code ~= api.lang.code and kit.inside(x, y, r, LANGUAGE_W, LANGUAGE_H) then
                setLanguage(code)
            end
        end
        if not running() and kit.inside(x, y, PASSWORD, CARD_W, CARD_H) then
            pressPassword()
        end
        if choice.connect ~= "steam" and not running() and kit.inside(x, y, PASTE, CARD_W, CARD_H) then
            pasteAddress()
        end
        for name, r in pairs(CONNECT) do
            if not running() and name ~= choice.connect and kit.inside(x, y, r, CARD_W, CARD_H) then
                choice.connect = name
                note, wordsAt = nil, 0
                save(network(name))
            end
        end
    end

    ------------------------------------------------------------------ on screen

    -- A picture with words on it, in the language picked.
    local function worded(name, tex, w, h, z)
        tex = (api.lang.code == "zh" and "zh_" or "") .. tex
        local p = kit.part(name, tex, w, h, z)
        kit.picture(p, tex)
        return p
    end

    local function drawSettings()
        kit.place(worded("on_bg2", "online_settings_bg", kit.W, kit.H, 0), 0, 0)
        kit.place(kit.part("on_close", "close", CLOSE.w, CLOSE.h, 1), CLOSE.x, CLOSE.y)
        kit.place(worded("on_back", "online_back", BUTTON_W, BUTTON_H, 1), BACK.x, BACK.y)
        for _, t in ipairs(TILES) do
            local value = options[t.name] or t.choices[1] or "soon"
            kit.place(worded("on_tile_" .. t.name, "tile_" .. t.name .. "_" .. value, TILE, TILE, 1), t.x, t.y)
        end
    end

    local function drawAll()
        local c = api.online and api.online.current()
        kit.place(worded("on_bg", "online_bg", kit.W, kit.H, 0), 0, 0)
        kit.place(kit.part("on_close", "close", CLOSE.w, CLOSE.h, 1), CLOSE.x, CLOSE.y)
        for code, r in pairs(LANGUAGE) do
            kit.place(kit.part("on_lang_" .. code, "online_lang_" .. code, LANGUAGE_W, LANGUAGE_H, 1), r.x, r.y)
        end
        local lang = LANGUAGE[api.lang.code]
        kit.place(kit.part("on_sel_lang", "sel_lang", LANGUAGE_W, LANGUAGE_H, 2), lang.x, lang.y)
        for name, r in pairs(CONNECT) do
            local p = worded("on_" .. name, "online_" .. name, CARD_W, CARD_H, 1)
            kit.place(p, r.x, r.y)
            kit.dim(p, (c and name ~= choice.connect) and 0.3 or 1.0)
        end
        local at = CONNECT[choice.connect]
        kit.place(kit.part("on_sel_card", "sel_card", CARD_W, CARD_H, 2), at.x, at.y)
        if choice.connect ~= "steam" then
            local p = worded("on_paste", "online_paste", CARD_W, CARD_H, 1)
            kit.place(p, PASTE.x, PASTE.y)
            kit.dim(p, c and 0.3 or 1.0)
        else
            kit.hide("on_paste")
        end
        local key = worded("on_password", hasPassword and "online_password_set" or "online_password", CARD_W, CARD_H, 1)
        kit.place(key, PASSWORD.x, PASSWORD.y)
        kit.dim(key, c and 0.3 or 1.0)
        -- Your role is the red one.
        local mine = c and (c.modRole == "host" and "host" or "join")
        for name, r in pairs(BUTTONS) do
            if name == mine then
                kit.hide("on_" .. name)
                kit.place(worded("on_" .. name .. "_on", "online_" .. name .. "_on", BUTTON_W, BUTTON_H, 1), r.x, r.y)
            else
                kit.hide("on_" .. name .. "_on")
                local p = worded("on_" .. name, "online_" .. name, BUTTON_W, BUTTON_H, 1)
                kit.place(p, r.x, r.y)
                kit.dim(p, (name == "leave" and not c) and 0.35 or 1.0)
            end
        end
        kit.place(worded("on_settings", "online_settings", BUTTON_W, BUTTON_H, 1), SETTINGS.x, SETTINGS.y)
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
            log("Online panel: no mouse from main.dll, closing.")
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
            -- Closed on the key's release, so the game doesn't see it go down too. The F5 that opened it doesn't count.
            keyArmed = keyArmed or not key
            keyHeld = keyHeld or (keyArmed and key)
            if (escHeld and not esc) or (keyHeld and not key) then
                panel.close()
                return
            end
            escHeld = esc
        end
        if page == "settings" then
            drawSettings()
            return
        end
        drawAll()
        showWords(os.clock())
    end

    -- The game's own screens and menus keep the mouse and the pause to themselves, and a load has nobody to open it for.
    local function canOpen(controller, pawn)
        return not (api.gs():IsGamePaused(controller) or game.inCutscene() or game.isDead(pawn)
            or api.localcoop.bellMenuUp() or api.localcoop.screenUp())
    end

    function panel.show()
        local controller, pawn = api.getPlayer1()
        if panel.open or not valid(pawn) or not canOpen(controller, pawn) then
            return
        end
        pc = controller
        local settings = api.online.settings()
        choice.connect = connectIn(settings)
        hasPassword = api.online.signed(settings or {})
        -- Widgets don't survive a map change.
        for name, p in pairs(kit.parts) do
            if not api.status.onScreen(p.widget) then
                kit.parts[name] = nil
            end
        end
        panel.open = true
        page = "main"
        wasDown, keyArmed, keyHeld, escHeld, wasFocused, clicksFrom = false, false, false, false, true, os.clock() + REFOCUS_S
        words, wordsAt, mouseAt = nil, 0, os.clock()
        os.remove(api.modDir() .. "mouse.txt")
        kit.writeWant(true)
        kit.blockPlay(pc, true)
        log("Online panel open.")
    end

    function panel.close()
        panel.open = false
        kit.writeWant(false)
        for _, p in pairs(kit.parts) do
            hud.show(p.widget, false)
        end
        hud.show(wordsWidget, false)
        if valid(pc) then
            kit.blockPlay(pc, false)
        end
        log("Online panel closed.")
    end

    -- F5 is read on the game thread, as in panel.lua. Only from here on does Lua look at it: never with Role = Local.
    local function readKey()
        local controller, pawn = api.getPlayer1()
        if not valid(pawn) then
            wasKey = false
            return
        end
        local key = controller:IsInputKeyDown(kit.key("F5"))
        if key and not wasKey and not panel.open then
            panel.show()
        end
        wasKey = key
    end

    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then
            log("Online panel error: " .. tostring(err))
            if panel.open then
                pcall(panel.close)
            end
        end
    end

    function panel.start()
        os.remove(api.modDir() .. "pads_want.txt")      -- left by a crash with the panel open
        LoopInGameThreadWithDelay(KEY_MS, function()
            guarded(readKey)
            return false
        end)
        LoopInGameThreadWithDelay(TICK_MS, function()
            guarded(tick)
            return false
        end)
    end

    panel.describe = describe       -- for tools/netlab/bench/online-panel.ps1

    -- onlinepanel toggle|host|join|leave|steam|tailscale|other|press <x> <y>|row <name>: what the keys and the mouse do, for tests.
    function panel.command(rest)
        local word, x, y = (rest or ""):match("^(%S*)%s*(%S*)%s*(%S*)")
        if word == "toggle" then
            if panel.open then
                panel.close()
            else
                panel.show()
            end
        elseif word == "host" or word == "join" or word == "leave" then
            local r = BUTTONS[word]
            press(r.x + 5, r.y + 5)
        elseif CONNECT[word] then
            local r = CONNECT[word]
            press(r.x + 5, r.y + 5)
        elseif word == "press" then
            press(tonumber(x), tonumber(y))
        elseif word == "row" then
            log("Online panel row " .. x .. ": " .. tostring(options[x]))
        end
        log("Online panel " .. (panel.open and "open" or "closed") .. ", " .. choice.connect .. ": " .. describe())
    end

    return panel
end
