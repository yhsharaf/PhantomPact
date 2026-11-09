-- Bench only, read-only: a foe figure's state every frame for a while, a log line at each change: its time dilation, its
-- montage, that montage's play rate and whether it moves on, its running GA_Hun abilities, its hit state and its mesh's
-- tick. For moves that stop showing on a figure. FIGSTATE.watch(seconds, slot) (slot 2: the guest's figure on the host).
FIGSTATE = FIGSTATE or {}

-- The figure's attacks since the watch began: begun, and begun again.
function FIGSTATE.counts()
    return string.format("attacks begun %d, begun again %d", FIGSTATE.starts or 0, FIGSTATE.restarts or 0)
end

function FIGSTATE.watch(seconds, slot)
    FIGSTATE.starts, FIGSTATE.restarts, FIGSTATE.lastMont = 0, 0, nil
    local t0, last, lastPos, frozen = os.clock(), nil, nil, 0
    PBZ.coop.frameTicks.figstate = function()
        local t = os.clock() - t0
        if t > (seconds or 30) then
            PBZ.coop.frameTicks.figstate = nil
            print("[FIGSTATE] done\n")
            return
        end
        local g = PBZ.coop.playerBody(slot or 2)
        if not PBZ.valid(g) then
            return
        end
        local dil, mont, rate, pos, abil, hit, tick = "?", "-", "-", nil, {}, "?", "?"
        pcall(function() dil = string.format("%.3f", g.CustomTimeDilation) end)
        pcall(function()
            local ai = g.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            if PBZ.valid(m) then
                mont = m:GetFName():ToString()
                rate = string.format("%.2f", ai:Montage_GetPlayRate(m))
                pos = ai:Montage_GetPosition(m)
            end
        end)
        pcall(function()
            local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(g)
            asc.ActivatableAbilities.Items:ForEach(function(_, e)
                local sp = e:get()
                if sp.ActiveCount > 0 and sp.Ability:IsValid() then
                    local n = sp.Ability:GetClass():GetFName():ToString()
                    if n:find("^GA_Hun") then
                        abil[#abil + 1] = n
                    end
                end
            end)
        end)
        pcall(function() hit = tostring(PBZ.game.hitStateOf and PBZ.game.hitStateOf(g)) end)
        pcall(function() tick = tostring(g.Mesh:IsComponentTickEnabled()) .. "/" .. tostring(g:IsActorTickEnabled()) end)
        table.sort(abil)
        -- A montage that doesn't move on from frame to frame (counted, said once it has stood for 10 frames).
        if pos and lastPos and math.abs(pos - lastPos) < 1e-4 then
            frozen = frozen + 1
        else
            frozen = 0
        end
        -- Each attack the figure plays, counted: one begun (its montage new) or one begun again (the same montage back near
        -- its start), to put against the swings its player threw.
        if mont:find("Attack", 1, true) then
            if mont ~= FIGSTATE.lastMont then
                FIGSTATE.starts = (FIGSTATE.starts or 0) + 1
            elseif pos and lastPos and pos < lastPos - 0.2 then
                FIGSTATE.restarts = (FIGSTATE.restarts or 0) + 1
            end
        end
        FIGSTATE.lastMont = mont
        lastPos = pos
        local key = string.format("dil %s | %s x%s | %s | hit %s | tick %s%s", dil, mont, rate, table.concat(abil, "+"), hit,
            tick, frozen >= 10 and " | STUCK" or "")
        if key ~= last then
            last = key
            print(string.format("[FIGSTATE] %.2f %s\n", t, key))
        end
    end
    return "watching " .. tostring(seconds or 30) .. " s"
end
