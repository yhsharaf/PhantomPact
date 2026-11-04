-- The map's fog, gone for everyone (the user: "remove all fog from map ... it is annoying"): each region's map is
-- painted over by fog pieces until the player has been there, and the game uncovers one with the map subsystem's
-- AddUnLockMaskID(map, layer, piece). Every piece of every region is uncovered once after each load. A piece is a
-- widget of that region's mask (W_MapMask_<region>), named after it: their names are the ids. The world map's gold
-- clouds are another thing, left as they are.

return function(api)
    local log, valid = api.log, api.valid

    local mapfog = {}

    local MASKS = "/Game/PBZContent/UI/InGame/Map/Mask/W_MapMask_"
    -- Which map ids each piece's prefix belongs to (the region maps of DT_MapData).
    local MAPS = {
        XG = { "XiGu" }, RedSilk = { "XiGu" }, XSSL = { "FuJiZhiLin" }, LJC = { "LuJiaCun" }, RedRope = { "LuJiaCun" },
        ZDDY = { "ZhengDaoDaYing" }, PZ = { "PangZhen" }, HJ = { "HouJie" }, XMSZ = { "PangZhen", "HouJie", "MeiGuHu" },
        MGH = { "MeiGuHu" }, DDSD = { "DengDingShanDao" }, DH = { "DuanHunYa", "DuanHunShan" },
    }
    local REGIONS = { "Xigu", "FJZL", "Lujiacun", "Daying", "Pangzhen", "MGH", "DDSD", "DuanHun" }
    local LOOK_MS = 5000

    -- The pieces' ids, read from the mask widgets' classes (loaded here if the map screen hasn't been opened yet).
    local function pieces()
        local out = {}
        for _, region in ipairs(REGIONS) do
            local path = MASKS .. region .. ".W_MapMask_" .. region .. "_C"
            local cls = StaticFindObject(path)
            if not valid(cls) then
                pcall(function() LoadAsset(MASKS .. region .. ".W_MapMask_" .. region) end)
                cls = StaticFindObject(path)
            end
            if valid(cls) then
                cls:ForEachProperty(function(p)
                    local id = p:GetFName():ToString()
                    local key = id:match("^WorldMapFog_(%u+)_") or id:match("^Door_(%a-)%d*$")
                    if key and MAPS[key] then
                        out[#out + 1] = { id = id, maps = MAPS[key] }
                    end
                end)
            end
        end
        return out
    end

    -- Due after each load, until a pass took: the search for the subsystem looks through every object, so it isn't made
    -- once the fog is gone. (Not by the subsystem's address: a new one can land on the old one's.)
    local due = true
    pcall(function()
        RegisterLoadMapPostHook(function()
            due = true
        end)
    end)

    local function look()
        if not due then
            return
        end
        local _, pawn = api.getPlayer1()
        if not valid(pawn) or (api.game.inCutscene and api.game.inCutscene()) then
            return
        end
        local list = pieces()
        local maps = FindFirstOf("MapSubsystem")       -- (after the loads above, and used at once)
        if #list == 0 or not valid(maps) then
            return
        end
        local took = 0
        for _, piece in ipairs(list) do
            for _, map in ipairs(piece.maps) do
                for layer = 0, 1 do
                    if pcall(function() maps:AddUnLockMaskID(FName(map), layer, FName(piece.id)) end) then
                        took = took + 1
                    end
                end
            end
        end
        if took > 0 then
            due = false
            log(string.format("Map fog gone: %d pieces of %d regions uncovered.", #list, #REGIONS))
        end
    end

    LoopInGameThreadWithDelay(LOOK_MS, function()
        local ok, err = pcall(look)
        if not ok and err ~= mapfog.lastError then
            mapfog.lastError = err
            log("Map fog: " .. tostring(err))
        end
        return false
    end)

    return mapfog
end
