-- Bench only: what this player fights with now, read off the game: health, attack, Phantom Edge energy and its attack, the
-- gourd and its drinks, every skill node on, and the level of each weapon in the match's loadouts (all players'). FAIR.read().
FAIR = {}
function FAIR.read()
    local _, p = PBZ.getPlayer1()
    if not PBZ.valid(p) then
        return "no body"
    end
    local function a(n)
        local ok, v = pcall(function() return p.AttributeSetBase[n].CurrentValue end)
        return ok and type(v) == "number" and v or -1
    end
    local out = { string.format("hp %.0f/%.0f attack %.0f energy %.0f edgeAttack %.0f", a("Health"), a("Health_Max"),
        a("Attack"), a("Shachi_Max"), a("ShachiAttack")) }
    local bp = PBZ.game.backpackOf(p)
    local g = PBZ.game.gourdInfo(p)
    pcall(function()
        out[#out + 1] = string.format("gourd %s %d drinks", bp.BottomMedicineID:ToString(), g.CurrentTime)
    end)
    pcall(function()
        out[#out + 1] = "other bottle " .. bp.TopMedicineID:ToString()
    end)
    local nodes = nil
    for _, c in ipairs(FindAllOf("PBZAbilityNodesComponent") or {}) do
        local ok, owner = pcall(function() return c:GetOwner() end)
        if ok and PBZ.valid(owner) and owner:GetAddress() == p:GetAddress() then
            nodes = c
        end
    end
    if nodes then
        local on, all = 0, 0
        pcall(function()
            nodes.AbilityNodeMap:ForEach(function(k)
                all = all + 1
                if nodes:IsActivateAbilityNode(FName(k:get():ToString())) then
                    on = on + 1
                end
            end)
        end)
        out[#out + 1] = string.format("skill nodes on %d of %d", on, all)
    end
    local m = PBZ.arena.match
    if m and m.presets and bp then
        local levels, seen = {}, {}
        for _, pre in pairs(m.presets) do
            for kind, list in pairs({ main = pre.main or {}, edge = pre.edge or {} }) do
                for _, id in ipairs(list) do
                    local key = kind .. ":" .. id
                    if not seen[key] then
                        seen[key] = true
                        local ok, lv = pcall(function() return bp:GetWeaponLevel(FName(id), kind == "main") end)
                        levels[#levels + 1] = id .. "=" .. tostring(ok and lv or "?")
                    end
                end
            end
        end
        table.sort(levels)
        out[#out + 1] = "weapon levels " .. table.concat(levels, ",")
        out[#out + 1] = string.format("match %s, %s, clock %s, team %s", tostring(m.phase), tostring(m.mode),
            tostring(m.timer), tostring(PBZ.arena.myTeam and PBZ.arena.myTeam()))
    end
    return table.concat(out, " | ")
end
