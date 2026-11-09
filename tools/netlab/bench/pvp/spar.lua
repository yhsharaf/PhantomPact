-- SPAR.start(seconds, gap): this copy's player attacks its foe in every match fight, for someone playing the other copy to
-- practise deflects on. Every gap seconds or so (a little either way, so it can't be timed by rhythm alone) it faces the
-- nearest foe's figure, steps in to 2 m if it's further than 3.2 m, and swings with the attack key's own ability
-- (FIGHT.swing, so fights.lua first); a third of the time a second swing follows, the combo's next. Its own health is kept
-- up, so the drill doesn't end at its fall. Only while a match is in its fight; over after seconds, or SPAR.stop().
-- 0.7 s after each swing a log line: what the foe's figure plays then (their guard's answer, a deflect, a hit) and this
-- player's own move and posture (a deflected swing staggers it and costs posture).
-- On the game thread (the mod's own timers); nothing kept across frames. A start ends the loop before it (SPAR.gen).
SPAR = SPAR or {}

function SPAR.stop()
    SPAR.on = false
    return "spar off after " .. tostring(SPAR.n or 0) .. " swings"
end

local function foe(me)
    local best, bd = nil, 1e12
    for _, p in ipairs(PBZ.coop.partners()) do
        if PBZ.valid(p.ghost) then
            local d = PBZ.distance(p.ghost:K2_GetActorLocation(), me:K2_GetActorLocation())
            if d < bd then
                best, bd = p.ghost, d
            end
        end
    end
    return best, bd
end

-- The attack key's own ability (FIGHT.swing); refused, the first light attack of a weapon that starts, its running copy
-- cancelled first, as a second poke restarts it. (The bench, 11-09: after a restart the guest's bag named its second
-- weapon while the first was in hand, and the attack key's ability was refused every time.)
local function attack()
    if FIGHT.use("BP_SwitchAttack_Default_C") == "true" then
        return true
    end
    local _, me = PBZ.getPlayer1()
    local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(me)
    local started = false
    asc.ActivatableAbilities.Items:ForEach(function(_, x)
        if started then
            return
        end
        pcall(function()
            local spec = x:get()
            local cls = spec.Ability:GetClass()
            if cls:GetFName():ToString():match("^GA_Hun_.+_A_C$") then
                if spec.ActiveCount > 0 then
                    spec.NonReplicatedInstances:ForEach(function(_, i)
                        pcall(function() i:get():K2_CancelAbility() end)
                    end)
                end
                started = asc:TryActivateAbilityByClass(cls, true) == true
            end
        end)
    end)
    return started
end

local function montageOf(actor)
    local out = "-"
    pcall(function()
        local a = actor.Mesh:GetAnimInstance():GetCurrentActiveMontage()
        if PBZ.valid(a) then
            out = a:GetFName():ToString()
        end
    end)
    return out
end

local function step(gen)
    if gen ~= SPAR.gen then
        return
    end
    if not SPAR.on or os.clock() > SPAR.till then
        SPAR.on = false
        return
    end
    local wait = 0.4
    local ok, err = pcall(function()
        local m = PBZ.arena.match
        if not (m and m.phase == "fight") then
            return
        end
        local pc, me = PBZ.getPlayer1()
        if not PBZ.valid(me) then
            return
        end
        local f, d = foe(me)
        if not PBZ.valid(f) then
            return
        end
        local fl, ml = f:K2_GetActorLocation(), me:K2_GetActorLocation()
        local dx, dy = ml.X - fl.X, ml.Y - fl.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then
            dx, dy, len = 1, 0, 1
        end
        if d > 320 then
            me:K2_SetActorLocation({ X = fl.X + dx / len * 200, Y = fl.Y + dy / len * 200, Z = fl.Z + 20 }, false, {}, true)
        end
        local yaw = math.deg(math.atan(-dy, -dx))
        me:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        pc:SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 })
        local before = PBZ.game.getPosture(me)
        attack()
        SPAR.n = SPAR.n + 1
        local n = SPAR.n
        PBZ.game.after(0.7, function()
            pcall(function()
                local _, me2 = PBZ.getPlayer1()
                local f2 = foe(me2)
                print(string.format("[SPAR] swing %d: foe plays %s; me %s, posture %s -> %s\n", n,
                    PBZ.valid(f2) and montageOf(f2) or "?", montageOf(me2), tostring(before and math.floor(before)),
                    tostring(PBZ.game.getPosture(me2) and math.floor(PBZ.game.getPosture(me2)))))
            end)
        end)
        if math.random() < 0.33 then
            PBZ.game.after(0.45, function()
                if SPAR.on and PBZ.arena.match and PBZ.arena.match.phase == "fight" then
                    attack()
                    SPAR.n = SPAR.n + 1
                end
            end)
        end
        local hp, mx = PBZ.game.getHealth(me)
        if hp and mx and hp < mx * 0.6 then
            PBZ.game.setHealth(me, mx)
        end
        wait = SPAR.gap * (0.75 + 0.5 * math.random())
    end)
    if not ok and err ~= SPAR.lastError then
        SPAR.lastError = err
        print("[SPAR] " .. tostring(err) .. "\n")
    end
    PBZ.game.after(wait, function() step(gen) end)
end

function SPAR.start(seconds, gap)
    SPAR.gen = (SPAR.gen or 0) + 1
    local gen = SPAR.gen
    SPAR.on, SPAR.till, SPAR.gap, SPAR.n = true, os.clock() + (seconds or 600), gap or 2.2, 0
    PBZ.game.after(0.1, function() step(gen) end)
    return "spar on for " .. tostring(seconds or 600) .. " s, a swing every " .. tostring(SPAR.gap) .. " s or so"
end
