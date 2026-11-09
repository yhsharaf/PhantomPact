-- What the defender's own game does through a foe figure's swing: each montage and hit state it shows, with health and
-- posture before and after. Bench only (C:\PBZDev). PARRY.watch(seconds), then PARRY.result.
PARRY = {}
function PARRY.watch(seconds)
    local _, p = PBZ.getPlayer1()
    local seen, t0 = {}, os.clock()
    local hp0, po0 = PBZ.game.getHealth(p), PBZ.game.getPosture(p)
    local function step()
        local _, q = PBZ.getPlayer1()
        pcall(function()
            local ai = q.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            local name = (m and m:IsValid()) and m:GetFName():ToString() or "-"
            local hs = PBZ.game.ownHitState and PBZ.game.ownHitState() or "?"
            -- (The defender's own guard and deflect abilities running now.)
            local abil = {}
            pcall(function()
                local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
                local asc = bl:GetAbilitySystemComponent(q)
                asc.ActivatableAbilities.Items:ForEach(function(_, e)
                    local sp = e:get()
                    if sp.ActiveCount > 0 and sp.Ability:IsValid() then
                        local n = sp.Ability:GetClass():GetFName():ToString()
                        if n:find("Deflect") or n:find("Stance") or n:find("Defen") or n:find("Parry") then
                            abil[#abil + 1] = n
                        end
                    end
                end)
            end)
            table.sort(abil)
            local td = 1
            pcall(function() td = PBZ.gs():GetGlobalTimeDilation(q) end)
            local key = name .. "|" .. hs .. "|" .. table.concat(abil, "+") .. string.format("|td=%.2f", td)
            if not seen[key] then
                seen[key] = string.format("%.2f", os.clock() - t0)
            end
        end)
        if os.clock() - t0 < seconds then
            PBZ.game.after(0.03, step)
        else
            local out = {}
            for k, v in pairs(seen) do
                out[#out + 1] = v .. " " .. k
            end
            table.sort(out)
            local hp1, po1 = PBZ.game.getHealth(q), PBZ.game.getPosture(q)
            PARRY.result = table.concat(out, " ; ") .. string.format(" || hp %.0f->%.0f posture %.0f->%.0f",
                hp0 or -1, hp1 or -1, po0 or -1, po1 or -1)
        end
    end
    PARRY.result = nil
    step()
    return "watching"
end
