-- What abilities run on this player, by class name, sampled every 50 ms for a while (PBZ.game.after): to learn what a skill
-- (a Phantom Edge's, say) is called, and whether game.isMoveName would send it. ABIL.watch(seconds), then ABIL.seen().
ABIL = { names = {}, order = {} }
function ABIL.watch(seconds)
    ABIL.names, ABIL.order = {}, {}
    local t0 = os.clock()
    local function sample()
        local _, pawn = PBZ.getPlayer1()
        if PBZ.valid(pawn) then
            pcall(function()
                local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
                    :GetAbilitySystemComponent(pawn)
                local items = asc.ActivatableAbilities.Items
                for i = 1, #items do
                    local spec = items[i]
                    if spec.ActiveCount > 0 then
                        local name = spec.Ability:GetClass():GetFName():ToString()
                        if not ABIL.names[name] then
                            ABIL.names[name] = string.format("%.2f", os.clock() - t0)
                            ABIL.order[#ABIL.order + 1] = name
                        end
                    end
                end
            end)
        end
        if os.clock() - t0 < seconds then
            PBZ.game.after(0.05, sample)
        end
    end
    sample()
    return 1
end
function ABIL.seen()
    local out = {}
    for _, n in ipairs(ABIL.order) do
        out[#out + 1] = n .. "@" .. ABIL.names[n] .. (PBZ.game.isMoveName(n) and "(sent)" or "")
    end
    return table.concat(out, " ")
end
