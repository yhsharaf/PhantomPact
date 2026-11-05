-- Your partner on a compass at the top of the screen: a thin line, and a round partner icon that sits where
-- they are relative to where your camera faces. Straight ahead is the middle; further than COMPASS_HALF_DEG
-- to a side, the icon waits at that end, dimmed (turn that way). Red while they're down; hidden while they're
-- in another area or gone.
-- With more than two players there's a dot for each (EXACG's, PR #11), in that player's colour (coop.players), and two that
-- would sit on one another are moved apart.
-- PhantomPact.ini PartnerCompass = On|Off. Art (painted in Lumina, in the game's ink-wash style): art/compass_line.png
-- (a dry-brush silver stroke) and art/partner_dot.png (a silver seal with 伴, "companion"), shown in the game's own
-- one-image widget (W_PaintSize). (Idea from appdoze's PR #5 partner HUD; a compass instead of big labels.)

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    -- From a sky-painting plugin: only some levels load it (the prologue does, the valley after it doesn't, and the
    -- compass simply didn't appear there), so it's loaded here when it's missing.
    local WIDGET_CLASS = "W_PaintSize_C"
    local WIDGET_PATH = "/UltraVolumetrics/UltraVolumetrics/Core/PaintMode/Blueprint/W_PaintSize.W_PaintSize_C"
    local COMPASS_HALF_DEG = 100    -- this far to either side maps to the line's ends
    local LINE_WIDTH_FRAC = 0.42    -- of the screen width
    local LINE_Y_FRAC = 0.055       -- from the top
    local LINE_ASPECT = 39 / 1024   -- compass_line.png's height / width
    local DOT_SIZE = 40
    local FRESH_S = 3.0
    local Z = 398
    local DOWN_TINT = { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }
    local NORMAL_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

    local hud = { on = true }
    local lineWidget, dotWidget
    local extraDots = {}            -- more than two players: the dots after dotWidget, as { widget, x, y, tint, dim }
    local textures = {}

    local function texture(name)
        if type(name) ~= "string" then              -- a texture object (one of the game's own), used as it is
            return name
        end
        if valid(textures[name]) then
            return textures[name]
        end
        local pc = api.getPlayer1()
        local ok, tex = pcall(function()
            return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc,
                api.modRoot() .. "art/" .. name)
        end)
        textures[name] = (ok and valid(tex)) and tex or nil
        return textures[name]
    end

    local function widgetClass()
        local cls = FindObject("WidgetBlueprintGeneratedClass", WIDGET_CLASS)
        if not valid(cls) then
            cls = StaticFindObject(WIDGET_PATH)
        end
        if not valid(cls) and type(LoadAsset) == "function" then
            pcall(LoadAsset, WIDGET_PATH)
            cls = StaticFindObject(WIDGET_PATH)
        end
        return cls
    end

    local function newImage(texName, w, h, z)
        local cls = widgetClass()
        local pc = api.getPlayer1()
        local tex = texture(texName)
        if not (valid(cls) and valid(pc) and tex) then
            return nil
        end
        local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(widget) then
            return nil
        end
        widget:AddToViewport(z or Z)
        widget:SetVisibility(3)                     -- HitTestInvisible: seen, never clicked
        pcall(function() widget:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
        pcall(function() widget:SetDesiredSizeInViewport({ X = w, Y = h }) end)
        pcall(function()
            local img = widget.Circle
            img:SetBrushFromTexture(tex, false)
            local b = img.Brush
            b.ImageSize = { X = w, Y = h }
            img:SetBrush(b)
        end)
        return widget
    end

    -- W_PaintSize keeps its own layout size whatever size is asked for (the first try drew a 400 px medallion), so
    -- once laid out it's scaled to the wanted size with a render scale (about its centre, so positions hold).
    local function fit(w, wantW, wantH)
        local ok, size = pcall(function() return w:GetDesiredSize() end)
        if ok and size and size.X and size.X > 1 and size.Y > 1 then
            pcall(function() w:SetRenderScale({ X = wantW / size.X, Y = wantH / size.Y }) end)
            return true
        end
        return false
    end

    local function show(w, on)
        if valid(w) then
            pcall(function() w:SetVisibility(on and 3 or 1) end)      -- collapsed when off
        end
    end

    local forgetShown = nil         -- (set below)

    local function removeExtraDots()
        for _, d in ipairs(extraDots) do
            if valid(d.widget) then
                pcall(function() d.widget:RemoveFromParent() end)
            end
        end
        extraDots = {}
    end

    local function remove()
        for _, w in ipairs({ lineWidget, dotWidget }) do
            if valid(w) then
                pcall(function() w:RemoveFromParent() end)
            end
        end
        lineWidget, dotWidget = nil, nil
        removeExtraDots()
        forgetShown()
    end

    local function onScreen(w)
        return api.status and api.status.onScreen and api.status.onScreen(w)
    end

    local function fresh()
        return net.enabled and not net.partnerGone and net.target ~= nil and net.lastRemoteAt ~= nil
            and os.clock() - net.lastRemoteAt <= FRESH_S
    end

    -- What the widgets were last told: a call that wouldn't change anything isn't made. Only the dot moves from tick to tick;
    -- this was 25 calls through UE4SS, 30 times a second.
    local LAYOUT_S = 1.0            -- the window's size, and whether the widgets are still up, are looked at this often
    local MOVED_PX = 0.5
    local nextLayout = 0
    local camera, dotX, dotY, dotTint, dotDim, width, centre
    local shown = false

    forgetShown = function()
        shown, nextLayout = false, 0
    end

    local function setShown(on)
        if on ~= shown then
            shown = on
            show(lineWidget, on)
            show(dotWidget, on)
        end
    end

    -- The slow part. False: not ready, so it comes round again on the next tick.
    local function layOut()
        local pc = api.getPlayer1()
        if not valid(pc) then
            return false
        end
        camera = pc.PlayerCameraManager
        if not onScreen(lineWidget) then
            lineWidget = nil
        end
        if not onScreen(dotWidget) then
            dotWidget = nil
        end
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size = wll:GetViewportSize(pc)
        local scale = wll:GetViewportScale(pc)
        if not (size and size.X and size.X > 0 and scale and scale > 0) then
            return false
        end
        -- Viewport positions are in DPI-scaled units.
        local vw, vh = size.X / scale, size.Y / scale
        width = vw * LINE_WIDTH_FRAC
        centre, dotY = vw / 2, vh * LINE_Y_FRAC
        if not (lineWidget and dotWidget) then
            lineWidget = lineWidget or newImage("compass_line.png", width, width * LINE_ASPECT)
            dotWidget = dotWidget or newImage("partner_dot.png", DOT_SIZE, DOT_SIZE)
            dotX, dotTint, dotDim, shown = nil, nil, nil, false
        end
        if not (lineWidget and dotWidget) then
            return false
        end
        lineWidget:SetPositionInViewport({ X = centre, Y = dotY }, false)
        -- (A widget has no size until a frame after it's made.)
        return fit(lineWidget, width, width * LINE_ASPECT) and fit(dotWidget, DOT_SIZE, DOT_SIZE)
    end

    local function update()
        local t = net.target
        local otherMap = t and t.Map and net.localMap and t.Map ~= net.localMap
        if not (hud.on and fresh()) or otherMap then
            setShown(false)
            return
        end
        local now = os.clock()
        -- (On screen, not only valid: one gone with a map change reads as valid for a while, and moving it crashed.)
        if now >= nextLayout or not (onScreen(dotWidget) and valid(camera)) then
            nextLayout = layOut() and now + LAYOUT_S or 0
            if not (onScreen(dotWidget) and valid(camera)) then
                return
            end
        end
        local from = net.localLoc
        if not from then
            return
        end
        -- Degrees from where the camera faces to the partner, -180..180 (negative = to the left). t is where the ghost is
        -- being steered: within centimetres of it, which a compass can't show.
        local angle = math.deg(math.atan(t.Y - from.Y, t.X - from.X))
        local deg = (angle - camera:GetCameraRotation().Yaw + 540) % 360 - 180
        local x = centre + math.max(-1, math.min(1, deg / COMPASS_HALF_DEG)) * width / 2
        if dotX == nil or math.abs(x - dotX) >= MOVED_PX then
            dotX = x
            dotWidget:SetPositionInViewport({ X = x, Y = dotY }, false)
        end
        local tint = (net.partnerDowned or (t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0)) and DOWN_TINT or NORMAL_TINT
        local dim = math.abs(deg) > COMPASS_HALF_DEG and 0.55 or 1.0
        if tint ~= dotTint or dim ~= dotDim then
            dotTint, dotDim = tint, dim
            pcall(function()
                dotWidget.Circle:SetColorAndOpacity(tint)
                dotWidget:SetRenderOpacity(dim)
            end)
        end
        setShown(true)
    end

    local firstDot = {}             -- what dotWidget was last told, with more than two players

    -- One partner's dot. taken: where the dots before it went.
    local function placeDot(d, p, from, cameraYaw, taken)
        local t = p.target
        local angle = math.deg(math.atan(t.Y - from.Y, t.X - from.X))
        local deg = (angle - cameraYaw + 540) % 360 - 180
        local x, y = centre + math.max(-1, math.min(1, deg / COMPASS_HALF_DEG)) * width / 2, dotY
        for _, other in ipairs(taken) do
            if math.abs(other - x) < DOT_SIZE * 0.7 then
                y = y + DOT_SIZE * 0.9
            end
        end
        taken[#taken + 1] = x
        if d.x == nil or math.abs(x - d.x) >= MOVED_PX or y ~= d.y then
            d.x, d.y = x, y
            d.widget:SetPositionInViewport({ X = x, Y = y }, false)
        end
        local tint = (t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0) and DOWN_TINT or coop.players[p.number].tint
        local dim = math.abs(deg) > COMPASS_HALF_DEG and 0.55 or 1.0
        if tint ~= d.tint or dim ~= d.dim then
            d.tint, d.dim = tint, dim
            pcall(function()
                d.widget.Circle:SetColorAndOpacity(tint)
                d.widget:SetRenderOpacity(dim)
            end)
        end
    end

    local function updateParty()
        local list = {}
        for _, p in ipairs(coop.partners()) do
            local t = p.target
            if hud.on and t and p.lastRemoteAt and not p.partnerGone and os.clock() - p.lastRemoteAt <= FRESH_S
                and not (t.Map and net.localMap and t.Map ~= net.localMap) then
                list[#list + 1] = p
            end
        end
        if #list == 0 then
            setShown(false)
            for _, d in ipairs(extraDots) do
                show(d.widget, false)
            end
            return
        end
        local now = os.clock()
        if now >= nextLayout or not (onScreen(dotWidget) and valid(camera)) then
            nextLayout = layOut() and now + LAYOUT_S or 0
            if not (onScreen(dotWidget) and valid(camera)) then
                return
            end
            for _, d in ipairs(extraDots) do
                if valid(d.widget) then
                    fit(d.widget, DOT_SIZE, DOT_SIZE)
                end
            end
        end
        -- (Widgets don't survive a map change, and a gone one crashes the game when touched: looked at each time.)
        for i = #extraDots, 1, -1 do
            if not onScreen(extraDots[i].widget) then
                table.remove(extraDots, i)
            end
        end
        local from = net.localLoc
        if not from then
            return
        end
        -- (New from layOut, or a guest's two-player compass that heard it's a party a moment after it started.)
        if dotX == nil or firstDot.widget == nil then
            firstDot, dotX = { widget = dotWidget }, 0
        end
        local taken, cameraYaw = {}, camera:GetCameraRotation().Yaw
        placeDot(firstDot, list[1], from, cameraYaw, taken)
        for i = 2, #list do
            local d = extraDots[i - 1]
            if d == nil then
                local w = newImage("partner_dot.png", DOT_SIZE, DOT_SIZE)
                if not w then
                    return
                end
                d = { widget = w }
                extraDots[i - 1] = d
                nextLayout = 0                  -- (it's sized on a look, a frame after it's made)
            end
            placeDot(d, list[i], from, cameraYaw, taken)
            show(d.widget, true)
        end
        for i = #list, #extraDots do
            show(extraDots[i].widget, false)
        end
        setShown(true)
    end

    coop.extraTicks.hud = function()
        if not net.party and #extraDots > 0 then
            removeExtraDots()
        end
        local ok, err = pcall(net.party and updateParty or update)
        if not ok and err ~= hud.lastError then
            hud.lastError = err
            log("compass: " .. tostring(err))
        end
    end

    -- Sync off (netoff): coop.lua stops calling extraTicks, so the widgets are cleared from a loop of their own.
    LoopInGameThreadWithDelay(1000, function()
        if not net.enabled and (lineWidget or dotWidget) then
            remove()
        end
        return false
    end)

    function hud.set(on)
        hud.on = on
    end

    -- For revive.lua's ring, the same kind of widget.
    hud.texture, hud.newImage, hud.fit, hud.show = texture, newImage, fit, show

    -- hud on|off
    function hud.command(args)
        local a = (args or ""):lower()
        if a == "off" or a == "on" then
            hud.set(a == "on")
        end
        log("Partner compass: " .. (hud.on and "on" or "off"))
    end

    return hud
end
