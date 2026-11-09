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
-- It stops at four players (250 and 190): with five or six every enemy has a ghost twin instead (twins.lua), which is harder
-- enough. scaling.players() is how many are connected, for twins.lua.
--
-- Boss poise (CoopBossPoise, percent, 100 = off): posture above is the bar that opens an execution; being knocked out of
-- an attack is the game's other number, poise. Each hit takes poise off the move the boss is doing, and when it's gone the
-- move breaks. A boss here takes 100/CoopBossPoise of the poise damage (its TakenReductionMultiplier_Poise, 1 by default),
-- so at 200 it takes twice the hits to stagger out of a move. Bosses only, the same with any number of players, and only
-- while someone is with you, like the rest. Each PC sets its own: the host's bosses and each guest's copies.
--
-- Bosses' own health and posture (CoopBossHealth / CoopBossPosture, left out: CoopEnemyHealth / CoopEnemyPosture as
-- before), and how hard enemies and bosses hit (CoopEnemyDamage / CoopBossDamage, percent, 100 = off): a player report on
-- 1.6.9, "options to customize the boss's damage, as well as the mobs' health, posture, and damage". The damage is each
-- enemy's own multipliers of what it deals (scaleHits: its Attack made no difference on the bench), once a body and never
-- on top of itself. Each PC sets its own: what its own player takes, from its own enemies or its copies of the host's. Not
-- with more players: the damage stays the same however many are connected.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local scaling = {
        health = 1.5,       -- CoopEnemyHealth / 100
        posture = 1.3,      -- CoopEnemyPosture / 100
        bossPoise = 2.0,    -- CoopBossPoise / 100
        bossHealth = nil,   -- CoopBossHealth / 100, or nil: health
        bossPosture = nil,  -- CoopBossPosture / 100, or nil: posture
        damage = 1.0,       -- CoopEnemyDamage / 100
        bossDamage = 1.0,   -- CoopBossDamage / 100
    }

    -- This enemy's health and posture numbers: a boss's own, where it has them. (The boss question only when they differ.)
    local function numbersFor(e, addr)
        if (scaling.bossHealth or scaling.bossPosture) and game.isBoss(e, addr) then
            return scaling.bossHealth or scaling.health, scaling.bossPosture or scaling.posture
        end
        return scaling.health, scaling.posture
    end

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

    -- Whether this is the actor scaled at that address: same name, and still the most health it was given. A placed enemy
    -- coming back (a rest, streaming in again) is a new actor with the old name, often on the old address, at base health:
    -- by name alone it was taken for done and fought at 100%.
    local scaledMax = {}            -- enemy address -> the Health_Max it was scaled to
    local function maxOf(e)
        local ok, v = pcall(function() return e.AttributeSetBase.Health_Max.CurrentValue end)
        -- (A number only: on some actors the read hands back an object, and the comparison with it threw every pass, seen on
        -- the bench beside the forest's YuCong.)
        return ok and type(v) == "number" and v or nil
    end
    -- (The host's only: a guest's copies take the host's Health_Max, which isn't theirs to judge by. And only a body below
    -- what it was given: one the game raises itself is still the one scaled.)
    local function same(e, addr, name)
        if scaled[addr] ~= name then
            return false
        end
        -- (Nor one the guest's game runs: its copy here takes the guest's Health_Max, and read as a new body it was made
        -- tougher again each pass while the bar jumped.)
        if (net.guestRuns or {})[name] then
            return true
        end
        local was, now = scaledMax[addr], api.coop.isHost() and maxOf(e)
        return not (was and now and now < was * 0.99)
    end

    local MOST_SCALED = 4           -- players: past this, twins.lua adds enemies instead
    local function forPlayers(base, players)
        return base + (base - 1) * (math.min(players, MOST_SCALED) - 2)
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

    -- Everyone connected, this player too: a party's count, or 2 with a partner synced, else 1.
    function scaling.players()
        if net.party then
            return playersConnected()
        end
        return (net.enabled and net.target and not net.partnerGone) and 2 or 1
    end

    -- More than two players: true if this took a scaling, which is what a tick may spend.
    local function scaleForParty(e, addr, name, players)
        local before = same(e, addr, name) and (scaledFor[addr] or 2) or nil
        if before and (before >= players or not api.coop.isHost() or (game.bossFightActive() and game.isBoss(e, addr))) then
            return false
        end
        scaled[addr], scaledFor[addr] = name, players
        if game.isDead(e) then
            return false
        end
        local set = e.AttributeSetBase
        local h, p = numbersFor(e, addr)
        local health, posture = forPlayers(h, players), forPlayers(p, players)
        if before then
            health, posture = health / forPlayers(h, before), posture / forPlayers(p, before)
        end
        scaleAttr(set, "Health", "Health_Max", health)
        scaleAttr(set, "Shachi", "Shachi_Max", posture)
        scaledMax[addr] = maxOf(e)
        return true
    end

    -- Bosses: the share of poise damage they take, set once per body (an address comes back for a new actor, so by name too).
    local poised = {}               -- boss address -> its name once set
    local function poiseBoss(e, addr, name)
        if poised[addr] == name or scaling.bossPoise == 1 or not game.isBoss(e, addr) then
            return false
        end
        -- (A guest's copy of the host's boss is puppets.lua's to set: next to nothing in the host's moves, this between them.)
        if api.puppets and api.puppets.follows and api.puppets.follows(addr) then
            return false
        end
        poised[addr] = name
        local ok = pcall(function()
            local a = e.AttributeSetBase.TakenReductionMultiplier_Poise
            a.BaseValue = 1 / scaling.bossPoise
            a.CurrentValue = 1 / scaling.bossPoise
        end)
        if ok then
            log(string.format("Co-op difficulty: boss %s at %d%% poise.", name, math.floor(scaling.bossPoise * 100 + 0.5)))
        end
        return ok
    end

    -- How hard it hits: the game's own multipliers of the damage it deals, each kind's (CoopEnemyDamage or CoopBossDamage).
    -- On the bench, 11-09, a Xigu elite's Attack at twice made no difference; DealtVulnerabilityMultiplier_<kind> at 2 doubled
    -- its hits (70 -> 140) and DealtReductionMultiplier_<kind> at 0.5 halved them (70 -> 35, a poison's tick 4 -> 2). Up by
    -- the first, down by the second. Not "Elemental": a poison's tick counts it as well as its own kind and went four times.
    -- A broken guard's blow (about 200) is neither's: it stays the game's. Once a body, and again only if it's back at the
    -- number it had (a body come back at that address under the old name, or the game setting it again): never on top of
    -- itself. True if it took a scaling, which is what a tick spends.
    local KINDS = { "Physical", "PhysicalSharp", "PhysicalBlunt", "Fire", "Toxin", "Ice", "Aqua", "Lightning", "Blood", "Chaos" }
    local hits = {}                 -- enemy address -> { name, base, now }: its first kind's multiplier before and after
    local function scaleHits(e, addr, name)
        local f = scaling.damage
        if scaling.bossDamage ~= scaling.damage and game.isBoss(e, addr) then
            f = scaling.bossDamage
        end
        local prefix = f >= 1 and "DealtVulnerabilityMultiplier_" or "DealtReductionMultiplier_"
        local set = e.AttributeSetBase
        local ok, cur = pcall(function() return set[prefix .. KINDS[1]].CurrentValue end)
        if not ok or type(cur) ~= "number" then
            return false
        end
        local was = hits[addr]
        if was and was.name == name and not (math.abs(cur - was.base) <= 0.001 and math.abs(cur - was.now) > 0.001) then
            return false
        end
        hits[addr] = { name = name, base = cur, now = cur * f }
        if f == 1 then
            return false
        end
        for _, kind in ipairs(KINDS) do
            pcall(function()
                local a = set[prefix .. kind]
                a.BaseValue = a.BaseValue * f
                a.CurrentValue = a.CurrentValue * f
            end)
        end
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
    local next, todo, addrs, at, n, hitN = 0, {}, {}, 1, 0, 0
    local players = 2
    local function tick()
        local hitting = scaling.damage ~= 1 or scaling.bossDamage ~= 1
        if scaling.health == 1 and scaling.posture == 1 and scaling.bossPoise == 1 and not hitting
            and (scaling.bossHealth or 1) == 1 and (scaling.bossPosture or 1) == 1 then
            return
        end
        if at > #todo then
            if n > 0 then
                log(string.format("Co-op difficulty: %d enem%s at %d%% health, %d%% posture.", n, n == 1 and "y" or "ies",
                    math.floor(forPlayers(scaling.health, players) * 100 + 0.5), math.floor(forPlayers(scaling.posture, players) * 100 + 0.5)))
                n = 0
            end
            if hitN > 0 then
                log(string.format("Co-op difficulty: %d enem%s hitting at %d%%, bosses at %d%%.", hitN, hitN == 1 and "y" or "ies",
                    math.floor(scaling.damage * 100 + 0.5), math.floor(scaling.bossDamage * 100 + 0.5)))
                hitN = 0
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
            -- (Not a ghost twin: it took its original's numbers, already scaled, as it came (twins.lua).)
            local name = valid(e) and not inSoloFight(addr) and not (game.twinId and game.twinId(addr, e)) and e:GetFName():ToString()
            if name and not game.isDead(e) and poiseBoss(e, addr, name) then
                return
            end
            if name and hitting and not game.isDead(e) and scaleHits(e, addr, name) then
                hitN = hitN + 1
                return
            end
            if name and net.party then
                if scaleForParty(e, addr, name, players) then
                    n = n + 1
                    return
                end
            elseif name and not same(e, addr, name) then
                scaled[addr], scaledMax[addr] = name, nil       -- (or it's dead, and nothing brings it back as the same actor)
                if not game.isDead(e) then
                    local set = e.AttributeSetBase
                    local health, posture = numbersFor(e, addr)
                    scaleAttr(set, "Health", "Health_Max", health)
                    scaleAttr(set, "Shachi", "Shachi_Max", posture)
                    scaledMax[addr] = maxOf(e)
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

    -- bosspoise <percent>   (100 = normal; read at start from CoopBossPoise). Bosses around take the new number on the next
    -- pass.
    function scaling.bossPoiseCommand(args)
        local v = tonumber((args or ""):match("^%s*(%d+)"))
        if v then
            scaling.bossPoise = math.max(1.0, math.min(10.0, v / 100))
            poised = {}
        end
        log(string.format("Co-op difficulty: bosses at %d%% poise while your partner is here.",
            math.floor(scaling.bossPoise * 100 + 0.5)))
    end

    -- bossscale <health %> [posture %] | off   (read at start from CoopBossHealth / CoopBossPosture; off: bosses take scale's
    -- numbers). Bosses scaled already keep theirs.
    function scaling.bossCommand(args)
        if (args or ""):match("^%s*off") then
            scaling.bossHealth, scaling.bossPosture = nil, nil
        else
            local h, p = (args or ""):match("^%s*(%d+)%s*(%d*)")
            if tonumber(h) then
                scaling.bossHealth = math.max(1.0, math.min(5.0, tonumber(h) / 100))
                scaling.bossPosture = tonumber(p) and math.max(1.0, math.min(5.0, tonumber(p) / 100)) or scaling.bossPosture
            end
        end
        log(string.format("Co-op difficulty: bosses at %d%% health, %d%% posture while your partner is here.",
            math.floor((scaling.bossHealth or scaling.health) * 100 + 0.5),
            math.floor((scaling.bossPosture or scaling.posture) * 100 + 0.5)))
    end

    -- hitscale <enemies %> [bosses %]   (100 100 = as hard as the game has them; read at start from CoopEnemyDamage /
    -- CoopBossDamage; bosses left out: the enemies' number). Enemies scaled already keep theirs.
    function scaling.damageCommand(args)
        local m, b = (args or ""):match("^%s*(%d+)%s*(%d*)")
        if tonumber(m) then
            scaling.damage = math.max(0.1, math.min(5.0, tonumber(m) / 100))
            scaling.bossDamage = tonumber(b) and math.max(0.1, math.min(5.0, tonumber(b) / 100)) or scaling.damage
        end
        log(string.format("Co-op difficulty: enemies hit at %d%%, bosses at %d%% while your partner is here.",
            math.floor(scaling.damage * 100 + 0.5), math.floor(scaling.bossDamage * 100 + 0.5)))
    end

    return scaling
end
