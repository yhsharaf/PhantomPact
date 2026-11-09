-- Bench only: what the foe figure (slot 2's body) runs on this copy through its swing, every frame for a few seconds: its
-- active GA_Hun abilities and montage, and how long ago its player's last move came (p.moveAt). FIGABIL.watch(s), .result.
FIGABIL = {}
function FIGABIL.watch(seconds, slot)
    local t0, last, order = os.clock(), nil, {}
    FIGABIL.result = nil
    PBZ.coop.frameTicks.figabil = function()
        local t = os.clock() - t0
        local abil, mont, age = {}, "-", "?"
        pcall(function()
            local g = PBZ.coop.playerBody(slot or 2)
            local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            local asc = bl:GetAbilitySystemComponent(g)
            asc.ActivatableAbilities.Items:ForEach(function(_, e)
                local sp = e:get()
                if sp.ActiveCount > 0 and sp.Ability:IsValid() then
                    local n = sp.Ability:GetClass():GetFName():ToString()
                    if n:find("^GA_Hun") then
                        abil[#abil + 1] = n
                    end
                end
            end)
            local m = g.Mesh:GetAnimInstance():GetCurrentActiveMontage()
            mont = (m and m:IsValid()) and m:GetFName():ToString() or "-"
        end)
        pcall(function()
            for _, p in ipairs(PBZ.coop.partners()) do
                if p.moveAt then
                    age = string.format("%.2f", os.clock() - p.moveAt)
                end
            end
        end)
        table.sort(abil)
        local key = table.concat(abil, "+") .. "|" .. mont
        if key ~= last then
            last = key
            order[#order + 1] = string.format("%.2f %s (move %s s ago)", t, key, age)
        end
        if t > seconds then
            FIGABIL.result = table.concat(order, " ; ")
            PBZ.coop.frameTicks.figabil = nil
        end
    end
    return "watching"
end
