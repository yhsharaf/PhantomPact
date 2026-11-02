-- The local co-op panel (F4, Role = Local): player count, screen layout, and who uses which controls, dragged as cards
-- onto players. Pictures come from art/make_local_panel.py and are shown in the same one-image widget as the compass,
-- so the mouse is read here each frame rather than through widget events.

return function(api)
    local log, valid, hud = api.log, api.valid, api.hud

    local TICK_MS = 15
    local W, H = 900, 560           -- the panel's own units; everything below is placed in them
    local Z = 900
    local HOLD_S = 1.0              -- how long a button is held on a joystick to light its card
    local LIT_S = 3.0
    local PADS_EVERY_S = 0.15
    local APPLIED_S = 1.5
    local REFOCUS_S = 0.5           -- back in the game: the click that brought you, and main.dll's, press nothing
    local HOLD_STEPS = 8
    local CARD_W, CARD_H = 176, 58

    local TABS = { { x = 40, y = 116 }, { x = 116, y = 116 }, { x = 192, y = 116 }, { x = 268, y = 116 } }
    local TAB_LAST = 2              -- 3 and 4 players come later
    local LAYOUTS = { tb = { x = 480, y = 116 }, lr = { x = 612, y = 116 } }
    local SLOTS = { { x = 40, y = 232 }, { x = 248, y = 232 } }
    local POOL = {
        kbm = { x = 40, y = 340 }, joy1 = { x = 228, y = 340 }, joy2 = { x = 416, y = 340 },
        joy3 = { x = 604, y = 340 }, joy4 = { x = 40, y = 410 },
    }
    local CLOSE = { x = 848, y = 14, w = 38, h = 38 }
    local APPLY = { x = 690, y = 490, w = 170, h = 46 }
    local ONLINE = { x = 40, y = 490, w = 170, h = 46 }     -- across from it: back to online play at the next start
    local CARDS = { "kbm", "joy1", "joy2", "joy3", "joy4" }

    local panel = { open = false }
    local parts = {}                -- name -> { widget, w, h }
    local choice = { players = 2, layout = "tb", p1 = "kbm", p2 = "joy1" }
    local plugged = { false, false, false, false }
    local held = { 0, 0, 0, 0 }
    local litUntil = { 0, 0, 0, 0 }
    local origin = { x = 0, y = 0, scale = 1, dpi = 1 }
    local dragging = nil            -- { name, dx, dy }
    local wasDown, lastTick, nextPads, appliedUntil = false, 0, 0, 0
    local wasFocused, clicksFrom = true, 0
    local keyboardPc = nil
    local blockPlay                 -- defined below, used by press
    local wasF4, wasF5 = false, false
    local f4Armed, f4Held, escHeld = false, false, false

    local function layoutLibrary()
        return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    end

    local function key(name)
        return { KeyName = FName(name) }
    end

    -- PhantomPact.ini, for both panels. Only these lines change: comments, the other settings and the file's line ends stay as
    -- they are.
    local function save(values)
        local path = api.modDir() .. "PhantomPact.ini"
        local f = io.open(path, "rb")
        local text = f and f:read("a") or ""
        if f then
            f:close()
        end
        local out, seen, at = {}, {}, 1
        while at <= #text do
            local stop = text:find("\n", at, true) or #text
            local line = text:sub(at, stop)
            local name_ = line:match("^%s*([%w_]+)%s*=")
            for name, value in pairs(values) do
                if name_ and name_:lower() == name:lower() then
                    line = name .. " = " .. value .. (line:match("\r?\n$") or "")
                    seen[name] = true
                end
            end
            out[#out + 1] = line
            at = stop + 1
        end
        local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
        for name, value in pairs(values) do
            if not seen[name] then
                -- (A file trimmed by hand can end without a line end: added to that, the key is lost and the last value changes.)
                if #out > 0 and out[#out]:sub(-1) ~= "\n" then
                    out[#out] = out[#out] .. eol
                end
                out[#out + 1] = name .. " = " .. value .. eol
            end
        end
        local tmp = io.open(path .. ".tmp", "wb")
        local wrote = tmp and tmp:write(table.concat(out))
        if tmp then
            tmp:close()
        end
        if not wrote then
            log("Couldn't save PhantomPact.ini: this choice lasts until the game closes.")
            return
        end
        os.remove(path)
        if not os.rename(path .. ".tmp", path) then
            log("Couldn't save PhantomPact.ini: see PhantomPact.ini.tmp in " .. api.modDir())
        end
    end

    local function part(name, tex, w, h, z)
        local p = parts[name]
        if p and valid(p.widget) then
            return p
        end
        local widget = hud.newImage("panel/" .. tex .. ".png", w, h, Z + (z or 0))
        if not widget then
            return nil
        end
        parts[name] = { widget = widget, w = w, h = h, tex = tex }
        return parts[name]
    end

    -- x, y are the part's top-left in panel units.
    local function place(p, x, y)
        if not p then
            return
        end
        local s = origin.scale
        p.widget:SetPositionInViewport({ X = origin.x + (x + p.w / 2) * s, Y = origin.y + (y + p.h / 2) * s }, false)
        hud.fit(p.widget, p.w * s, p.h * s)
        hud.show(p.widget, true)
    end

    local function hide(name)
        if parts[name] then
            hud.show(parts[name].widget, false)
        end
    end

    local function dim(p, opacity)
        if p then
            pcall(function() p.widget:SetRenderOpacity(opacity) end)
        end
    end

    local function picture(p, tex)
        if not p or p.tex == tex then
            return
        end
        local t = hud.texture("panel/" .. tex .. ".png")
        if t then
            pcall(function()
                local img = p.widget.Circle
                img:SetBrushFromTexture(t, false)
                local b = img.Brush
                b.ImageSize = { X = p.w, Y = p.h }
                img:SetBrush(b)
            end)
            p.tex = tex
        end
    end

    local function measure(pc)
        local lib = layoutLibrary()
        local size = lib:GetViewportSize(pc)
        local scale = lib:GetViewportScale(pc)
        local vw, vh = size.X / scale, size.Y / scale
        local s = math.min(vw / (W + 80), vh / (H + 80), 1.4)
        origin.scale, origin.dpi = s, scale
        origin.x, origin.y = (vw - W * s) / 2, (vh - H * s) / 2
    end

    -- The mouse and keys, from Windows through main.dll: with the mouse let go of, the game itself sees no input.
    -- Returns the cursor in panel units, then left button, Escape, F4 and whether this game has the focus, as booleans.
    local function input()
        local f = io.open(api.modDir() .. "mouse.txt", "r")
        if not f then
            return nil
        end
        local px, py, left, esc, f4, focused = f:read("n", "n", "n", "n", "n", "n")
        f:close()
        if not f4 then
            return nil
        end
        return (px / origin.dpi - origin.x) / origin.scale, (py / origin.dpi - origin.y) / origin.scale,
            left == 1, esc == 1, f4 == 1, focused == 1
    end

    local function inside(x, y, r, w, h)
        return x >= r.x and y >= r.y and x <= r.x + (w or r.w) and y <= r.y + (h or r.h)
    end

    local function padIndex(card)
        return tonumber(card:match("^joy(%d)$"))
    end

    local function available(card)
        local i = padIndex(card)
        return i == nil or plugged[i]
    end

    local function ownerOf(card)
        return choice.p1 == card and 1 or ((choice.players > 1 and choice.p2 == card) and 2 or nil)
    end

    local function ready()
        if choice.p1 == nil or not available(choice.p1) then
            return false
        end
        return choice.players == 1 or (choice.p2 ~= nil and available(choice.p2))
    end

    local function cardSpot(card)
        local owner = ownerOf(card)
        if owner then
            return SLOTS[owner].x + 10, SLOTS[owner].y + 16
        end
        return POOL[card].x, POOL[card].y
    end

    local function updatePads(dt)
        if os.clock() < nextPads then
            return
        end
        local states = api.localcoop.readPads()
        nextPads = os.clock() + PADS_EVERY_S
        for i = 1, 4 do
            local s = states and states[i] or 0
            plugged[i] = s > 0
            held[i] = s == 2 and held[i] + math.max(dt, PADS_EVERY_S) or 0
            if held[i] >= HOLD_S then
                held[i] = 0
                litUntil[i] = os.clock() + LIT_S
            end
        end
    end

    local function drawAll()
        place(part("bg", "bg", W, H, 0), 0, 0)
        place(part("close", "close", CLOSE.w, CLOSE.h, 1), CLOSE.x, CLOSE.y)
        for n, r in ipairs(TABS) do
            local p = part("tab" .. n, "tab" .. n, 64, 64, 1)
            place(p, r.x, r.y)
            dim(p, n <= TAB_LAST and 1.0 or 0.3)
        end
        place(part("sel_tab", "sel_tab", 64, 64, 2), TABS[choice.players].x, TABS[choice.players].y)
        for name, r in pairs(LAYOUTS) do
            local p = part("layout_" .. name, "layout_" .. name, 118, 70, 1)
            place(p, r.x, r.y)
            dim(p, choice.players == 1 and 0.25 or (choice.layout == name and 1.0 or 0.55))
        end
        if choice.players == 1 then
            hide("sel_layout")
            hide("slot2")
        else
            place(part("sel_layout", "sel_layout", 118, 70, 2), LAYOUTS[choice.layout].x, LAYOUTS[choice.layout].y)
        end
        for i, r in ipairs(SLOTS) do
            if i <= choice.players then
                place(part("slot" .. i, "slot" .. i, 196, 78, 1), r.x, r.y)
            end
        end
        for _, card in ipairs(CARDS) do
            local cardName = "card_" .. card
            if available(card) then
                if not (dragging and dragging.name == card) then
                    local x, y = cardSpot(card)
                    place(part(cardName, cardName, CARD_W, CARD_H, 3), x, y)
                end
                local i = padIndex(card)
                if i then
                    local x, y = cardSpot(card)
                    local lit = os.clock() < litUntil[i]
                    if lit or held[i] > 0 then
                        local step = lit and HOLD_STEPS or math.min(HOLD_STEPS, math.floor(held[i] / HOLD_S * HOLD_STEPS))
                        local bar = part("hold" .. i, "hold0", CARD_W, 6, 4)
                        picture(bar, "hold" .. step)
                        place(bar, x, y + CARD_H)
                    else
                        hide("hold" .. i)
                    end
                end
            else
                hide(cardName)
                local i = padIndex(card)
                if i then
                    hide("hold" .. i)
                end
            end
        end
        local apply = part("apply", "apply", APPLY.w, APPLY.h, 1)
        picture(apply, os.clock() < appliedUntil and "applied" or "apply")
        place(apply, APPLY.x, APPLY.y)
        dim(apply, ready() and 1.0 or 0.35)
        place(part("multiplayer", "multiplayer", ONLINE.w, ONLINE.h, 1), ONLINE.x, ONLINE.y)
    end

    local function drop(x, y)
        local card = dragging.name
        local from = ownerOf(card)
        dragging = nil
        for i, r in ipairs(SLOTS) do
            if i <= choice.players and inside(x, y, r, 196, 78) then
                local slot = "p" .. i
                if from and from ~= i then
                    choice["p" .. from] = choice[slot]   -- swap with whoever was there
                end
                choice[slot] = card
                return
            end
        end
        if from then
            choice["p" .. from] = nil
        end
    end

    local function press(x, y)
        if inside(x, y, CLOSE) then
            panel.close()
            return
        end
        -- With Role = Local the online panel doesn't start, so this is the way back. From the next start: Role is read once, and
        -- local co-op can't be taken down live. (Removing player 2 at the wrong moment has killed the game's menus.)
        if inside(x, y, ONLINE) then
            save({ Role = "Off", OnlinePanel = "On" })      -- (an ini made for local co-op can have F5 off: then there'd be no way in)
            api.status.lastShown.mode = nil
            api.status.notify("mode", "Multiplayer starts the next time you start the game.")
            return
        end
        for n, r in ipairs(TABS) do
            if n <= TAB_LAST and inside(x, y, r, 64, 64) then
                choice.players = n
            end
        end
        for name, r in pairs(LAYOUTS) do
            if inside(x, y, r, 118, 70) then
                choice.layout = name
            end
        end
        for _, card in ipairs(CARDS) do
            if available(card) then
                local cx, cy = cardSpot(card)
                if inside(x, y, { x = cx, y = cy }, CARD_W, CARD_H) then
                    dragging = { name = card, dx = x - cx, dy = y - cy }
                    return
                end
            end
        end
        if inside(x, y, APPLY) and ready() then
            api.localcoop.apply(choice)
            appliedUntil = os.clock() + APPLIED_S
            -- Apply may have moved the keyboard and mouse to the other player: the panel follows them.
            local now = api.localcoop.keyboardController()
            if valid(now) and not (valid(keyboardPc) and now:GetFullName() == keyboardPc:GetFullName()) then
                blockPlay(keyboardPc, false)
                keyboardPc = now
                blockPlay(keyboardPc, true)
            end
        end
    end

    local function tick()
        if not panel.open then
            return
        end
        local pc = keyboardPc
        if not valid(pc) then
            panel.close()
            return
        end
        local now = os.clock()
        local dt = now - lastTick
        lastTick = now
        updatePads(dt)
        measure(pc)
        local x, y, down, esc, f4, focused = input()
        if x == nil then
            drawAll()
            return
        end
        if focused and not wasFocused then
            clicksFrom = now + REFOCUS_S
        end
        wasFocused = focused
        if down and not wasDown then
            if focused and now >= clicksFrom then
                press(x, y)
            end
        elseif wasDown and not down and dragging then
            drop(x, y)
        end
        wasDown = down
        if not panel.open then
            return
        end
        drawAll()
        if dragging then
            local p = part("card_" .. dragging.name, "card_" .. dragging.name, CARD_W, CARD_H, 3)
            place(p, x - dragging.dx, y - dragging.dy)
        end
        -- Closed on the key's release, so the game doesn't see it go down too. The F4 that opened the panel doesn't count.
        f4Armed = f4Armed or not f4
        f4Held = f4Held or (f4Armed and f4)
        if (escHeld and not esc) or (f4Held and not f4) then
            panel.close()
        end
        escHeld = esc
    end

    function blockPlay(pc, on)
        -- Paused, as the game's own menus are. (Turning the Soul's input off instead left it stuck at walking speed.) Not
        -- with a partner linked: their game goes on, so this one must too.
        if api.coop.linked() then
            pcall(function() pc:FlushPressedKeys() end)
        else
            api.gs():SetGamePaused(pc, on)
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        -- Every player, not only the one at the keyboard: a joystick moved on the other one grabs the cursor back.
        for _, c in ipairs({ api.getPlayer1(), api.state.p2Controller }) do
            if valid(c) then
                c.bShowMouseCursor = on
                if on then
                    -- The game pins the real cursor to the screen's centre: UI-only mode is what lets go of it.
                    lib:SetInputMode_UIOnlyEx(c, nil, 0, false)
                else
                    lib:SetInputMode_GameOnly(c, false)
                end
            end
        end
    end

    local function writeWant(on)
        local path = api.modDir() .. "pads_want.txt"
        if on then
            local f = io.open(path, "w")
            if f then
                f:write("1\n")
                f:close()
            end
        else
            os.remove(path)
        end
    end

    function panel.toggle()
        if panel.open then
            panel.close()
            return
        end
        keyboardPc = api.localcoop.keyboardController()
        if not valid(keyboardPc) then
            return
        end
        for k, v in pairs(api.localcoop.current()) do
            choice[k] = v
        end
        panel.open = true
        wasDown, dragging, lastTick, nextPads = false, nil, os.clock(), 0
        wasFocused, clicksFrom = true, os.clock() + REFOCUS_S
        f4Armed, f4Held, escHeld = false, false, false
        os.remove(api.modDir() .. "mouse.txt")
        writeWant(true)
        blockPlay(keyboardPc, true)
        log("Panel open.")
    end

    function panel.close()
        panel.open = false
        dragging = nil
        writeWant(false)
        for _, p in pairs(parts) do
            hud.show(p.widget, false)
        end
        if valid(keyboardPc) then
            blockPlay(keyboardPc, false)
        end
        log("Panel closed.")
    end

    -- F4 and F5 are read here on the game thread. RegisterKeyBind runs Lua on another thread, and pressing keys
    -- often enough corrupted the Lua heap: the crash in UE4SS.dll that the game-thread loops were moved to avoid.
    local function readKeys()
        local pc = api.localcoop.keyboardController()
        if not valid(pc) then
            return
        end
        local f4, f5 = pc:IsInputKeyDown(key("F4")), pc:IsInputKeyDown(key("F5"))
        if f4 and not wasF4 and not panel.open then
            panel.toggle()
        end
        if f5 and not wasF5 then
            api.localcoop.regroup()
        end
        wasF4, wasF5 = f4, f5
    end

    function panel.start()
        LoopInGameThreadWithDelay(TICK_MS, function()
            local ok, err = pcall(function()
                readKeys()
                tick()
            end)
            if not ok then
                log("Panel error: " .. tostring(err))
                pcall(panel.close)
            end
            return false
        end)
    end

    function panel.command(rest)
        if rest == "toggle" then
            panel.toggle()
        end
        local x, y = (rest or ""):match("^press (%S+) (%S+)$")
        if x then
            press(tonumber(x), tonumber(y))
        end
        log(string.format("Panel %s: %d players, %s, p1 %s, p2 %s", panel.open and "open" or "closed", choice.players,
            choice.layout, tostring(choice.p1), tostring(choice.p2)))
    end

    -- What the online panel (onlinepanel.lua) draws and reads with: the same units, widgets and input.
    panel.kit = { W = W, H = H, origin = origin, parts = parts, part = part, place = place, hide = hide, dim = dim,
        picture = picture, measure = measure, input = input, inside = inside, key = key, blockPlay = blockPlay, writeWant = writeWant,
        save = save }

    return panel
end
