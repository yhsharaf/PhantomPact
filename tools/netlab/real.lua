-- Real fights on two copies: the player's own attacks on real enemies, and what each side sees. Loaded after fights.lua.
--   REAL.list(n)                 the nearest living enemies the sync knows
--   REAL.fight(name, swings)     stands beside that enemy and swings, logging its health after each swing
REAL = REAL or {}
local log, valid = PBZ.log, PBZ.valid
local game, coop = PBZ.game, PBZ.coop

function REAL.list(n)
    local _, p = PBZ.getPlayer1()
    local here, rows = p:K2_GetActorLocation(), {}
    for name, a in pairs(coop.enemies()) do
        if valid(a) and not game.isDead(a) then
            local hp, max = game.getHealth(a)
            rows[#rows + 1] = { d = PBZ.distance(a:K2_GetActorLocation(), here), name = name,
                class = a:GetClass():GetFName():ToString(), hp = hp, max = max }
        end
    end
    table.sort(rows, function(x, y) return x.d < y.d end)
    for i = 1, math.min(n or 8, #rows) do
        local r = rows[i]
        log(string.format("STATE enemy %.0f m %s %s %.0f/%.0f", r.d / 100, r.class, r.name, r.hp or -1, r.max or -1))
    end
    return "STATE " .. #rows .. " living enemies"
end

function REAL.hp(name)
    local e = coop.enemyActor(name)
    if not valid(e) then return "gone" end
    local hp, max = game.getHealth(e)
    return string.format("%.0f/%.0f dead=%s %s", hp or -1, max or -1, tostring(game.isDead(e)), FIGHT.doing(e))
end

function REAL.fight(name, swings, gap)
    local n = 0
    local function step()
        n = n + 1
        local e = coop.enemyActor(name)
        if not valid(e) or game.isDead(e) then
            log("STATE fight over after " .. (n - 1) .. " swings: " .. REAL.hp(name))
            return
        end
        FIGHT.beside(e, 170)
        local before = game.getHealth(e)
        local r = FIGHT.swing()
        game.after(0.7, function()
            log(string.format("STATE swing %d %s: %s -> %s", n, r, tostring(before), REAL.hp(name)))
        end)
        if n < (swings or 4) then
            game.after(gap or 1.1, step)
        end
    end
    step()
    return "STATE fighting " .. name
end

-- Logs each change of what this enemy is doing, on the clock both copies share, for comparing the two sides.
function REAL.watch(name, seconds)
    local stop, last = PBZ.link.wall() + seconds, nil
    REAL.watchId = (REAL.watchId or 0) + 1
    local id = REAL.watchId
    LoopInGameThreadWithDelay(30, function()
        if id ~= REAL.watchId then return false end
        local now = PBZ.link.wall()
        if now > stop then
            REAL.watchId = REAL.watchId + 1
            return false
        end
        local e = coop.enemyActor(name)
        local m = "-"
        if valid(e) then
            pcall(function()
                local mo = e.Mesh:GetAnimInstance():GetCurrentActiveMontage()
                if valid(mo) then m = mo:GetFName():ToString() end
            end)
        end
        if m ~= last then
            last = m
            log(string.format("WATCH %.2f %s", now % 1000, m))
        end
        return false
    end)
    return "STATE watching"
end

-- The enemy's controller and brain, as the sync left them.
function REAL.brain(name)
    local e = coop.enemyActor(name)
    if not valid(e) then return "BRAIN gone" end
    local c = e:GetController()
    if not valid(c) then return "BRAIN no controller" end
    local out = { "BRAIN ctrl " .. c:GetClass():GetFName():ToString() }
    local b = c.BrainComponent
    if valid(b) then
        out[#out + 1] = "brain " .. b:GetClass():GetFName():ToString()
        pcall(function() out[#out + 1] = "running " .. tostring(b:IsRunning()) end)
        pcall(function() out[#out + 1] = "paused " .. tostring(b:IsPaused()) end)
    else
        out[#out + 1] = "no brain"
    end
    return table.concat(out, " ")
end

-- All copies: how many brains run. With stop=true they're stopped now.
function REAL.brains(stop)
    local on, off, none, names = 0, 0, 0, {}
    for name, e in pairs(coop.enemies()) do
        if valid(e) and not game.isDead(e) then
            local b
            pcall(function() b = e:GetController().BrainComponent end)
            if valid(b) then
                if b:IsRunning() then
                    on = on + 1
                    names[#names + 1] = name:sub(-12)
                    if stop then b:StopLogic("PhantomPact") end
                else
                    off = off + 1
                end
            else
                none = none + 1
            end
        end
    end
    return string.format("BRAIN running %d stopped %d none %d: %s", on, off, none, table.concat(names, " "))
end

-- Stops this enemy's brain and logs each time it comes back, with what the enemy is doing at that moment.
function REAL.trace(name, seconds)
    local e = coop.enemyActor(name)
    local b = e:GetController().BrainComponent
    b:StopLogic("PhantomPact")
    local stop, wasOn, t0, starts = PBZ.link.wall() + seconds, false, PBZ.link.wall(), 0
    REAL.traceId = (REAL.traceId or 0) + 1
    local id = REAL.traceId
    LoopInGameThreadWithDelay(10, function()
        if id ~= REAL.traceId then return false end
        local now = PBZ.link.wall()
        if now > stop then
            REAL.traceId = REAL.traceId + 1
            log(string.format("BRAIN trace over: %d restarts in %.0f s", starts, seconds))
            return false
        end
        if not valid(b) then return false end
        local on = b:IsRunning()
        if on and not wasOn then
            starts = starts + 1
            log(string.format("BRAIN back on at +%.2f: %s", now - t0, FIGHT.doing(e)))
            b:StopLogic("PhantomPact")
            on = false
        end
        wasOn = on
        return false
    end)
    return "BRAIN tracing"
end

-- Live patch for testing: keeps every copy's own AI stopped, ten times a second.
function REAL.holdAll()
    if REAL.holding then return "BRAIN already holding" end
    REAL.holding = true
    LoopInGameThreadWithDelay(100, function()
        pcall(REAL.brains, true)
        return false
    end)
    return "BRAIN holding"
end

-- Living enemies the sync knows, as "name=class" joined, for comparing the two sides.
function REAL.names()
    local out = {}
    for name, a in pairs(coop.enemies()) do
        if valid(a) and not game.isDead(a) then out[#out + 1] = name end
    end
    table.sort(out)
    return "NAMES " .. table.concat(out, " ")
end

-- The nearest living enemy to this player: "name|class|metres|hp|max|boss".
function REAL.near()
    local _, p = PBZ.getPlayer1()
    local here, best, bd, bn = p:K2_GetActorLocation(), nil, 1e12, nil
    for name, a in pairs(coop.enemies()) do
        -- (Not an ally: the story's helpers fight beside the player, and a swing at one does nothing.)
        if valid(a) and not game.isDead(a) and not a:GetClass():GetFName():ToString():find("NpcHelper", 1, true) then
            local d = PBZ.distance(a:K2_GetActorLocation(), here)
            if d < bd then best, bd, bn = a, d, name end
        end
    end
    if not best then return "none" end
    local hp, max = game.getHealth(best)
    return string.format("%s|%s|%.0f|%.0f|%.0f|%s", bn, best:GetClass():GetFName():ToString(), bd / 100, hp or -1, max or -1,
        tostring(game.isBoss and game.isBoss(best)))
end

-- Hover beside an enemy, so a jump across the map can't drop the player through ground that hasn't loaded yet.
function REAL.hoverTo(name, cm)
    local e = coop.enemyActor(name)
    if not valid(e) then return "gone" end
    local _, p = PBZ.getPlayer1()
    local l = e:K2_GetActorLocation()
    if math.abs(l.X) < 1 and math.abs(l.Y) < 1 then return "stale" end   -- a stale actor reads as the world origin
    p.CharacterMovement:SetMovementMode(5, 0)
    p:K2_SetActorLocation({ X = l.X - (cm or 300), Y = l.Y, Z = l.Z + 120 }, false, {}, true)
    return "hovering"
end

function REAL.land(minHealth)
    local _, p = PBZ.getPlayer1()
    p.CharacterMovement:SetMovementMode(1, 0)
    if minHealth then game.setMinHealth(p, minHealth) end
    local _, m = game.getHealth(p)
    if m then game.setHealth(p, m) end
    return "landed"
end

function REAL.ghost()
    local g, net = PBZ.net.ghost, PBZ.net
    local vis = "?"
    pcall(function() vis = tostring(not g.bHidden) end)
    local _, p = PBZ.getPlayer1()
    local d = (valid(g) and valid(p)) and PBZ.distance(g:K2_GetActorLocation(), p:K2_GetActorLocation()) / 100 or -1
    return string.format("ghost valid=%s shown=%s hiddenFlag=%s %.0f m", tostring(valid(g)), vis, tostring(net.ghostHidden), d)
end

-- Of these names, the nearest to this player that isn't a fire puppet (they soak hits and burn, which muddies numbers).
function REAL.nearOf(names)
    local _, p = PBZ.getPlayer1()
    local here, best, bd, fallback = p:K2_GetActorLocation(), nil, 1e12, nil
    for name in names:gmatch("%S+") do
        local a = coop.enemyActor(name)
        if valid(a) and not game.isDead(a) then
            fallback = fallback or name
            if not a:GetClass():GetFName():ToString():find("HuoTong", 1, true) then
                local d = PBZ.distance(a:K2_GetActorLocation(), here)
                if d < bd then best, bd = name, d end
            end
        end
    end
    return best or fallback or "none"
end

-- Each stage of the player's attack: did it start, and what's stopping it?
function REAL.canSwing()
    local _, p = PBZ.getPlayer1()
    local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(p)
    local tags = {}
    pcall(function() asc:GetOwnedGameplayTags(tags) end)
    local out = {}
    pcall(function() tags.GameplayTags:ForEach(function(_, t) out[#out + 1] = t:get().TagName:ToString() end) end)
    return "TAGS " .. table.concat(out, " "):sub(1, 400)
end

function REAL.flyTo(x, y, z)
    local _, p = PBZ.getPlayer1()
    p.CharacterMovement:SetMovementMode(5, 0)
    p:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
    return "flying to " .. x .. " " .. y .. " " .. z
end

-- How far apart the two players are by this copy's reckoning.
function REAL.gap()
    local t, l = PBZ.net.target, PBZ.net.localLoc
    if not (t and l) then return "gap ?" end
    return string.format("gap %.0f m, same map %s", math.sqrt((t.X - l.X) ^ 2 + (t.Y - l.Y) ^ 2 + (t.Z - l.Z) ^ 2) / 100, tostring(t.Map == PBZ.net.localMap))
end

-- Every switch-like actor loaded here, by class, with the nearest few named.
function REAL.switches()
    local _, p = PBZ.getPlayer1()
    local here = p:K2_GetActorLocation()
    local byClass, rows = {}, {}
    for _, cn in ipairs({ "PBZSwitchBase" }) do
        for _, a in ipairs(FindAllOf(cn) or {}) do
            if valid(a) then
                local c = a:GetClass():GetFName():ToString()
                byClass[c] = (byClass[c] or 0) + 1
                local ok, l = pcall(function() return a:K2_GetActorLocation() end)
                if ok and l.X then
                    rows[#rows + 1] = { d = PBZ.distance(l, here) / 100, c = c, n = a:GetFName():ToString() }
                end
            end
        end
    end
    table.sort(rows, function(x, y) return x.d < y.d end)
    local out = {}
    for c, n in pairs(byClass) do out[#out + 1] = c .. "=" .. n end
    table.sort(out)
    log("STATE switches " .. table.concat(out, " "))
    for i = 1, math.min(8, #rows) do
        log(string.format("STATE near %.0f m %s %s", rows[i].d, rows[i].c, rows[i].n))
    end
    return "STATE switch kinds " .. #out
end

-- A guest alone: what its enemies are doing with the host far away. Stopped brains mean copies waiting for a host that
-- isn't there.
function REAL.alone()
    local total, puppets, running = 0, 0, 0
    for _, a in ipairs(game.listEnemies(true) or {}) do
        if valid(a) and not game.isDead(a) then
            total = total + 1
            local b
            pcall(function() b = a:GetController().BrainComponent end)
            if valid(b) and b:IsRunning() then running = running + 1 end
        end
    end
    for _ in pairs(coop.enemies()) do puppets = puppets + 1 end
    return string.format("STATE loaded enemies %d, shared by host %d, own AI running %d", total, puppets, running)
end

-- This player's backpack and dust, kept to compare with later: REAL.bagMark(), then REAL.bagDiff().
function REAL.bag()
    local _, p = PBZ.getPlayer1()
    local bp = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p,
        StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem"))
    local out = {}
    bp.Inventories:ForEach(function(k, v)
        out[k:get():ToString()] = v:get().CurrentAmount
    end)
    return out, math.floor(tonumber(p.ConsciousnessDust) or 0)
end

function REAL.bagMark()
    REAL.bag0, REAL.dust0 = REAL.bag()
    local n = 0
    for _ in pairs(REAL.bag0) do n = n + 1 end
    return "BAG marked " .. n .. " kinds, dust " .. REAL.dust0
end

function REAL.bagDiff()
    local now, dust = REAL.bag()
    local out = {}
    for k, v in pairs(now) do
        local was = REAL.bag0[k] or 0
        if v ~= was then out[#out + 1] = k .. string.format("%+d", v - was) end
    end
    for k, v in pairs(REAL.bag0) do
        if now[k] == nil then out[#out + 1] = k .. string.format("%+d", -v) end
    end
    table.sort(out)
    return string.format("BAG dust %+d items [%s]", dust - REAL.dust0, table.concat(out, " "))
end

-- Pickups lying near this player: "name item metres".
function REAL.pickups(cm)
    local _, p = PBZ.getPlayer1()
    local here, out = p:K2_GetActorLocation(), {}
    for _, a in ipairs(FindAllOf("PBZPickupActor") or {}) do
        if valid(a) then
            local d = PBZ.distance(a:K2_GetActorLocation(), here)
            if d <= (cm or 10000) then
                local id = "?"
                pcall(function() id = a.ItemId:ToString() end)
                out[#out + 1] = string.format("%s %s %.0fm", a:GetFName():ToString(), id, d / 100)
            end
        end
    end
    return "PICKUPS " .. #out .. " " .. table.concat(out, " | "):sub(1, 300)
end

-- The abilities an enemy is running right now, by class, to tell the game's own moves from anything else.
function REAL.active(name)
    local e = coop.enemyActor(name)
    if not valid(e) then return "gone" end
    local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(e)
    local out = {}
    asc.ActivatableAbilities.Items:ForEach(function(_, x)
        pcall(function()
            local spec = x:get()
            if spec.ActiveCount > 0 and valid(spec.Ability) then
                out[#out + 1] = spec.Ability:GetClass():GetFName():ToString()
            end
        end)
    end)
    return table.concat(out, " ")
end

-- Holds an enemy's health down for this long, so whatever blow lands next is the one that kills it.
function REAL.keepLow(name, seconds, hp)
    local stop = os.clock() + (seconds or 12)
    local function step()
        local e = coop.enemyActor(name)
        if valid(e) and not game.isDead(e) and os.clock() < stop then
            game.setHealth(e, hp or 40)
            game.after(0.1, step)
        end
    end
    step()
    return "holding " .. name .. " low"
end
