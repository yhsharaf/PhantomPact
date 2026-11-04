-- Your partner on the open map (PhantomPact.ini PartnerMapIcon; from appdoze's PR #6). With more than two players there's a
-- pointer each (EXACG's, PR #11), in that player's colour (coop.players). A copy of the game's own player
-- marker (the map's WB_PlayerIcon) in jade, on the same canvas (WB_MapNew_C.Gadget, where the map's icons live), so it
-- pans and zooms with the map and hides with it on the world map. Red while they're down, like the compass. Same area
-- only.
-- Place: MapSubsystem.ProjectWorldLocationToMap gives 0..1 map coordinates (0,0 = outside the painted map). The canvas
-- scale comes from your own marker, not a constant: PR #6's 1920 was 2.6 times too small in Weeping Creek Valley.
-- Facing: a point ahead of them projected the same way; on your own marker this formula gave 227.2 degrees to the
-- game's 227.5.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local OPEN_TICKS = 15           -- ~0.25 s between updates while the map is open
    local CLOSED_TICKS = 60         -- ~1 s between looks for the map: searching every object isn't free mid-fight
    local AHEAD_CM = 300
    local JADE = { R = 0.30, G = 0.80, B = 0.60, A = 1.0 }
    local DOWN_TINT = { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }
    local FRESH_S = 3.0

    local mapicon = { on = true }
    local ticks = 0
    local icon, owner, openMap, scaleX, scaleY
    local hidden = true
    local pointers = {}             -- more than two players: slot -> { widget, owner, hidden }

    local function hidePointer(one)
        if not one.hidden and valid(one.widget) then
            pcall(function() one.widget:SetVisibility(1) end)
        end
        one.hidden = true
    end

    local function hide()
        if not hidden and valid(icon) then
            pcall(function() icon:SetVisibility(1) end)    -- collapsed
        end
        hidden = true
        for _, one in pairs(pointers) do
            hidePointer(one)
        end
    end

    local function findMap()
        for _, w in ipairs(FindAllOf("WB_MapNew_C") or {}) do
            if valid(w) and w:IsVisible() then
                return w
            end
        end
    end

    local function update()
        local t = net.target
        local ms = FindFirstOf("MapSubsystem")
        local fresh = t and net.lastRemoteAt and not net.partnerGone and os.clock() - net.lastRemoteAt <= FRESH_S
        local mine = openMap.WB_PlayerIcon
        if not (fresh and valid(ms) and valid(mine) and t.Map == net.localMap) then
            hide()
            return
        end
        local mapId = ms:GetCurrentMapID()
        -- (The scale is each map's own: 2.6 times apart between two of them. Kept over a trip, the partner was put by the
        -- last map's until this player stood somewhere that projects.)
        local okKey, mapKey = pcall(function() return mapId:ToString() end)
        mapKey = okKey and mapKey or tostring(net.localMap)
        if mapKey ~= mapicon.scaleMap then
            mapicon.scaleMap, scaleX, scaleY = mapKey, nil, nil
        end
        local function project(x, y, z)
            local uv = ms:ProjectWorldLocationToMap({ X = x, Y = y, Z = z }, mapId)
            if not uv or (uv.X == 0 and uv.Y == 0) then
                return nil          -- outside the painted map
            end
            return uv.X, uv.Y
        end
        -- Kept from the last good read: you can be standing somewhere that projects to nothing.
        local _, me = api.getPlayer1()
        if valid(me) then
            local l = me:K2_GetActorLocation()
            local ux, uy = project(l.X, l.Y, l.Z)
            if ux then
                local pos = mine.Slot:GetPosition()
                scaleX, scaleY = pos.X / ux, pos.Y / uy
            end
        end
        local px, py = project(t.X, t.Y, t.Z)
        if not (px and scaleX) then
            hide()
            return
        end
        if not (valid(icon) and owner == openMap:GetAddress()) then
            if valid(icon) then
                pcall(function() icon:RemoveFromParent() end)
            end
            local pc = FindFirstOf("PlayerController")
            if not valid(pc) then
                return
            end
            icon = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, mine:GetClass(), pc)
            local slot = mine:GetParent():AddChildToCanvas(icon)
            slot:SetAutoSize(mine.Slot:GetAutoSize())
            slot:SetSize(mine.Slot:GetSize())
            slot:SetAlignment(mine.Slot:GetAlignment())
            owner = openMap:GetAddress()
            hidden = true
        end
        icon.Slot:SetPosition({ X = px * scaleX, Y = py * scaleY })
        local yaw = math.rad(t.Yaw or 0)
        local fx, fy = project(t.X + math.cos(yaw) * AHEAD_CM, t.Y + math.sin(yaw) * AHEAD_CM, t.Z)
        if fx and (fx ~= px or fy ~= py) then
            icon:SetRenderTransformAngle(math.deg(math.atan(fx - px, py - fy)))
        end
        local down = net.partnerDowned or (t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0)
        icon:SetColorAndOpacity(down and DOWN_TINT or JADE)
        if hidden then
            pcall(function() icon:SetVisibility(3) end)
            hidden = false
        end
    end

    -- A copy of your own marker for that player, on the open map's canvas.
    local function pointerFor(slot, mine)
        local one = pointers[slot]
        if one and valid(one.widget) and one.owner == openMap:GetAddress() then
            return one
        end
        if one and valid(one.widget) then
            pcall(function() one.widget:RemoveFromParent() end)
        end
        local pc = FindFirstOf("PlayerController")
        if not valid(pc) then
            return nil
        end
        local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, mine:GetClass(), pc)
        local slotOnMap = mine:GetParent():AddChildToCanvas(widget)
        slotOnMap:SetAutoSize(mine.Slot:GetAutoSize())
        slotOnMap:SetSize(mine.Slot:GetSize())
        slotOnMap:SetAlignment(mine.Slot:GetAlignment())
        one = { widget = widget, owner = openMap:GetAddress(), hidden = true }
        pointers[slot] = one
        return one
    end

    local function updateParty()
        local ms = FindFirstOf("MapSubsystem")
        local mine = openMap.WB_PlayerIcon
        if not (valid(ms) and valid(mine)) then
            hide()
            return
        end
        local mapId = ms:GetCurrentMapID()
        -- (The scale is each map's own: 2.6 times apart between two of them. Kept over a trip, the partner was put by the
        -- last map's until this player stood somewhere that projects.)
        local okKey, mapKey = pcall(function() return mapId:ToString() end)
        mapKey = okKey and mapKey or tostring(net.localMap)
        if mapKey ~= mapicon.scaleMap then
            mapicon.scaleMap, scaleX, scaleY = mapKey, nil, nil
        end
        local function project(x, y, z)
            local uv = ms:ProjectWorldLocationToMap({ X = x, Y = y, Z = z }, mapId)
            if not uv or (uv.X == 0 and uv.Y == 0) then
                return nil
            end
            return uv.X, uv.Y
        end
        local _, me = api.getPlayer1()
        if valid(me) then
            local l = me:K2_GetActorLocation()
            local ux, uy = project(l.X, l.Y, l.Z)
            if ux then
                local pos = mine.Slot:GetPosition()
                scaleX, scaleY = pos.X / ux, pos.Y / uy
            end
        end
        local drawn = {}
        for _, p in ipairs(coop.partners()) do
            local t = p.target
            local fresh = t and p.lastRemoteAt and not p.partnerGone and os.clock() - p.lastRemoteAt <= FRESH_S
            local px, py = nil, nil
            if fresh and t.Map == net.localMap then
                px, py = project(t.X, t.Y, t.Z)
            end
            local one = px and scaleX and pointerFor(p.number, mine)
            if one then
                drawn[p.number] = true
                one.widget.Slot:SetPosition({ X = px * scaleX, Y = py * scaleY })
                local yaw = math.rad(t.Yaw or 0)
                local fx, fy = project(t.X + math.cos(yaw) * AHEAD_CM, t.Y + math.sin(yaw) * AHEAD_CM, t.Z)
                if fx and (fx ~= px or fy ~= py) then
                    one.widget:SetRenderTransformAngle(math.deg(math.atan(fx - px, py - fy)))
                end
                local down = t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0
                one.widget:SetColorAndOpacity(down and DOWN_TINT or coop.players[p.number].tint)
                if one.hidden then
                    pcall(function() one.widget:SetVisibility(3) end)
                    one.hidden = false
                end
            end
        end
        for slot, one in pairs(pointers) do
            if not drawn[slot] then
                hidePointer(one)
            end
        end
    end

    -- (Sync off ends these ticks: coop.lua's stop hides the markers itself, or the map kept the partner's at their last
    -- spot every time it was opened.)
    mapicon.hide = hide

    coop.extraTicks.mapicon = function()
        if not mapicon.on then
            hide()
            return
        end
        -- Two players to a party or back: the other kind of marker is left drawn otherwise, frozen beside the new one.
        if (net.party ~= nil) ~= mapicon.wasParty then
            mapicon.wasParty = net.party ~= nil
            hide()
        end
        ticks = ticks + 1
        if not net.enabled or ticks % OPEN_TICKS ~= 0 then
            return
        end
        local isOpen = valid(openMap) and openMap:IsVisible()
        if not isOpen and ticks % CLOSED_TICKS ~= 0 then
            return
        end
        local ok, err = pcall(function()
            if not isOpen then
                openMap = findMap()
                if not openMap then
                    return          -- (the icon closed with the map, and comes back with it: hide() has to know it's showing)
                end
            end
            if net.party then
                updateParty()
            else
                update()
            end
        end)
        if not ok and err ~= mapicon.lastError then
            mapicon.lastError = err
            log("mapicon: " .. tostring(err))
        end
    end

    return mapicon
end
