-- Co-op difficulty, Elden Ring style: while your partner is with you, enemies and bosses get more health and
-- posture (PhantomPact.ini CoopEnemyHealth / CoopEnemyPosture, in percent; 100 = off).
--
-- Both players' games scale the same enemies by the same factor, so the host's numbers (which the guest's copies
-- follow down) and the guest's own copies stay in step. Each enemy is scaled once, keeping its current share of
-- health; enemies that respawn (bell rest) are new actors and get scaled again. The guest's copies then take the host's
-- maximum anyway (coop.lua).
--
-- With 4 PLAYERS on, each person connected adds what the first did, wherever they are: another map, loading or down all count.
-- At the default 150 and 130 that's 200 and 160 with two connected, 250 and 190 with three (EXACG's numbers, PR #11), and 100
-- stays 100. An enemy only goes up: scaled again on the host when someone connects, where the guests' copies follow. It doesn't
-- go back down when someone leaves, or a boss would lose health as a player dropped out. New enemies get the number of the
-- moment. Someone who joins during a boss fight only watches, so that boss keeps its number until the fight is over.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local scaling = {
        health = 1.5,       -- CoopEnemyHealth / 100
        posture = 1.3,      -- CoopEnemyPosture / 100
    }

    local PASS_S = 1.0              -- a look over the enemies starts this often while the partner is here
    local LOOKS_PER_TICK = 16       -- enemies looked at per tick, and at most one scaled: that takes about 25 calls through
                                    -- UE4SS, and all those near a new player scaled in one frame was a 23 ms frame

    local scaled = {}               -- enemy address -> its name once scaled (an address comes back for a new actor, after a
                                    -- map change or a respawn, and that one wasn't scaled yet)
    local scaledFor = {}            -- more than two players: enemy address -> how many it's been scaled for
    local soloFights = {}           -- a boss's address -> true: its fight began with nobody else here, so whoever joins only
                                    -- watches it, and it keeps its number until that's over

    local function scaleAttr(set, name, maxName, factor)
        pcall(function()
            local mx, cur = set[maxName], set[name]
            local share = (mx.CurrentValue > 0) and (cur.CurrentValue / mx.CurrentValue) or 1
            local newMax = mx.CurrentValue * factor
            mx.BaseValue = newMax
            mx.CurrentValue = newMax
            cur.BaseValue = newMax * share
            cur.CurrentValue = newMax * share
        end)
    end

    local function forPlayers(base, players)
        return base + (base - 1) * (players - 2)
    end

    local function playersConnected()
        local n = 1
        for _, p in ipairs(api.coop.partners()) do
            if p.lastRemoteAt and not p.partnerGone then
                n = n + 1
            end
        end
        return n
    end

    -- More than two players: true if this took a scaling, which is what a tick may spend.
    local function scaleForParty(e, addr, name, players)
        local before = scaled[addr] == name and (scaledFor[addr] or 2) or nil
        if before and (before >= players or not api.coop.isHost() or (game.bossFightActive() and game.isBoss(e, addr))) then
            return false
        end
        scaled[addr], scaledFor[addr] = name, players
        if game.isDead(e) then
            return false
        end
        local set = e.AttributeSetBase
        local health, posture = forPlayers(scaling.health, players), forPlayers(scaling.posture, players)
        if before then
            health, posture = health / forPlayers(scaling.health, before), posture / forPlayers(scaling.posture, before)
        end
        scaleAttr(set, "Health", "Health_Max", health)
        scaleAttr(set, "Shachi", "Shachi_Max", posture)
        return true
    end

    local function noteSoloFights()
        soloFights = {}
        if game.bossFightActive() then
            for _, boss in ipairs(game.bossActors()) do
                soloFights[boss:GetAddress()] = true
            end
        end
    end

    local function inSoloFight(addr)
        if soloFights[addr] and not game.bossFightActive() then
            soloFights[addr] = nil
        end
        return soloFights[addr] == true
    end

    -- While the partner is here: scale enemies we haven't scaled yet, a few looks a tick. The list is the one the net loop
    -- keeps: the search for enemies is its job, once a second, and two in one frame was part of the worst case.
    local next, todo, addrs, at, n = 0, {}, {}, 1, 0
    local players = 2
    local function tick()
        if scaling.health == 1 and scaling.posture == 1 then
            return
        end
        if at > #todo then
            if n > 0 then
                log(string.format("Co-op difficulty: %d enem%s at %d%% health, %d%% posture.", n, n == 1 and "y" or "ies",
                    math.floor(forPlayers(scaling.health, players) * 100 + 0.5), math.floor(forPlayers(scaling.posture, players) * 100 + 0.5)))
                n = 0
            end
            if os.clock() < next then
                return
            end
            next = os.clock() + PASS_S
            players = net.party and playersConnected() or 2
            if net.party then
                if players < 2 then
                    noteSoloFights()
                    return
                end
            -- "With you": synced and the partner's ghost is in this world (same map, alive).
            elseif not (net.enabled and net.target and valid(net.ghost) and not net.ghostHidden) then
                noteSoloFights()
                return
            end
            todo, addrs = game.enemiesSoFar()
            at = 1
        end
        for _ = 1, LOOKS_PER_TICK do
            local e, addr = todo[at], addrs[at]
            if e == nil then
                return
            end
            at = at + 1
            local name = valid(e) and not inSoloFight(addr) and e:GetFName():ToString()
            if name and net.party then
                if scaleForParty(e, addr, name, players) then
                    n = n + 1
                    return
                end
            elseif name and scaled[addr] ~= name then
                scaled[addr] = name       -- (or it's dead, and nothing brings it back as the same actor)
                if not game.isDead(e) then
                    local set = e.AttributeSetBase
                    scaleAttr(set, "Health", "Health_Max", scaling.health)
                    scaleAttr(set, "Shachi", "Shachi_Max", scaling.posture)
                    n = n + 1
                    return
                end
            end
        end
    end
    api.coop.extraTicks.scaling = tick

    -- scale <health %> [posture %]   (100 100 = normal enemies)
    function scaling.command(args)
        local h, p = (args or ""):match("^%s*(%d+)%s*(%d*)")
        if tonumber(h) then
            scaling.health = math.max(1.0, math.min(5.0, tonumber(h) / 100))
            scaling.posture = tonumber(p) and math.max(1.0, math.min(5.0, tonumber(p) / 100)) or scaling.posture
        end
        log(string.format("Co-op difficulty: enemies at %d%% health, %d%% posture while your partner is here.",
            math.floor(scaling.health * 100 + 0.5), math.floor(scaling.posture * 100 + 0.5)))
    end

    return scaling
end
