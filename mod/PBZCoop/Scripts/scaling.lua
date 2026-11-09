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
-- enemy's own multipliers of what it deals (scaleHits: its Attack made no difference on the bench), once a body and again
-- when the game sets them again (a difficulty switch), never on top of itself. Each PC sets its own: what its own player
-- takes, from its own enemies or its copies of the host's. Not with more players: the damage stays the same however many
-- are connected.

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
        hitsSeen = nil,     -- { damage, bossDamage } as tick last saw them
        hitsBack = 0,       -- passes still to look at every body's hits after those changed (tick)
    }

    -- This enemy's health and posture numbers: a boss's own, where it has them, and whether they're a boss's. (The boss
    -- question only when they differ.)
    local function numbersFor(e, addr)
        if (scaling.bossHealth or scaling.bossPosture) and game.isBoss(e, addr) then
            return scaling.bossHealth or scaling.health, scaling.bossPosture or scaling.posture, true
        end
        return scaling.health, scaling.posture, false
    end
    local scaledAs = {}             -- enemy address -> { name, h, p, boss, players }: the numbers its scaling took

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
        local h, p, boss = numbersFor(e, addr)
        -- (A body that holds a boss's numbers rises by them and stays one, its bar down or not. By the enemies' it was
        -- promoted again at its next bar, a boss twice over: a guest's lost fight leaves the host's body so, and a player
        -- joined. The review of 11-10.)
        local was = scaledAs[addr]
        if before and not boss and was and was.name == name and was.boss then
            h, p, boss = was.h, was.p, true
        end
        local health, posture = forPlayers(h, players), forPlayers(p, players)
        if before then
            health, posture = health / forPlayers(h, before), posture / forPlayers(p, before)
        end
        scaleAttr(set, "Health", "Health_Max", health)
        scaleAttr(set, "Shachi", "Shachi_Max", posture)
        scaledMax[addr] = maxOf(e)
        scaledAs[addr] = { name = name, h = h, p = p, boss = boss, players = players }
        return true
    end

    -- A body scaled with the enemies' numbers that's a boss now (a story boss of an ordinary enemy's class is one only once
    -- its bar is up): the bosses' own numbers, once, its share of health kept. The review of 11-09: it kept the enemies'.
    -- (Only with bosses' own numbers set: CoopBossHealth / CoopBossPosture.)
    local function promoteBoss(e, addr, name)
        local was = scaledAs[addr]
        if not (was and was.name == name) or was.boss or game.isDead(e) or not game.isBoss(e, addr) then
            return false
        end
        local h, p = numbersFor(e, addr)
        local players, set = was.players or 2, e.AttributeSetBase
        scaleAttr(set, "Health", "Health_Max", forPlayers(h, players) / forPlayers(was.h, players))
        scaleAttr(set, "Shachi", "Shachi_Max", forPlayers(p, players) / forPlayers(was.p, players))
        scaledAs[addr] = { name = name, h = h, p = p, boss = true, players = players }
        scaledMax[addr] = maxOf(e)
        log(string.format("Co-op difficulty: %s is a boss: %d%% health, %d%% posture.", name,
            math.floor(forPlayers(h, players) * 100 + 0.5), math.floor(forPlayers(p, players) * 100 + 0.5)))
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
    -- A broken guard's blow (about 200) is neither's: it stays the game's. Each kind's base as this set it is kept, and a
    -- kind the game has set again is scaled again from the game's new number: a difficulty switch recomputes an enemy's
    -- numbers (the Coop session on the bench, 11-09: a thug's Attack 100 -> 70 at Wayfarer and back), and difficulty.lua
    -- raises the mode a second after a partner links, after this may have run; a body come back at that address too. One
    -- still at ours isn't, so it's never on top of itself: by its base, as an effect on top moves only the current, and gone
    -- again leaves ours. (The first kind looked at each pass, all of them only when it moved: a look is one read.) True if it
    -- took a scaling, which is what a tick spends.
    local KINDS = { "Physical", "PhysicalSharp", "PhysicalBlunt", "Fire", "Toxin", "Ice", "Aqua", "Lightning", "Blood", "Chaos" }
    local UP, DOWN = "DealtVulnerabilityMultiplier_", "DealtReductionMultiplier_"
    local hits = {}                 -- enemy address -> { name, f, prefix, given = { kind -> the base this set } }

    -- Its factor now: a boss's, a boss's ghost twin's (no boss to the mod, but it hits as one: by its class, as the game's
    -- codex has it), or an enemy's.
    local function hitFactor(e, addr)
        if scaling.bossDamage == scaling.damage then
            return scaling.damage
        end
        local boss = game.isBoss(e, addr)
        if not boss and game.isBossClass and game.twinId and game.twinId(addr, e) then
            local ok, cn = pcall(function() return e:GetClass():GetFName():ToString() end)
            boss = ok and game.isBossClass(cn) or false
        end
        return boss and scaling.bossDamage or scaling.damage
    end

    local function scaleHits(e, addr, name)
        local f = hitFactor(e, addr)
        local set = e.AttributeSetBase
        local was = hits[addr]
        if was and was.name ~= name then
            was = nil               -- (another body at that address)
        end
        if was and was.f == f then
            if f == 1 then
                return false
            end
            local ok, base = pcall(function() return set[was.prefix .. KINDS[1]].BaseValue end)
            if not ok or type(base) ~= "number" or (was.given[KINDS[1]] and math.abs(base - was.given[KINDS[1]]) <= 0.001) then
                return false        -- (ours still)
            end
            -- The game set it again (a difficulty switch): each kind not at ours, from the game's new number.
            local took = false
            for _, kind in ipairs(KINDS) do
                pcall(function()
                    local a = set[was.prefix .. kind]
                    local b = a.BaseValue
                    if not (was.given[kind] and math.abs(b - was.given[kind]) <= 0.001) then
                        a.BaseValue, a.CurrentValue = b * f, a.CurrentValue * f
                        was.given[kind] = b * f
                        took = true
                    end
                end)
            end
            return took
        end
        -- A new body, or its factor changed (a story boss known only once its bar is up, after it was scaled as an enemy; the
        -- hitscale command): what the old factor set, where it still stands, goes back to the game's number first, so the two
        -- never mix nor stack (the review of 11-09: up and down both on, or one on top of the other); then the new one.
        if was and was.f ~= 1 then
            for _, kind in ipairs(KINDS) do
                pcall(function()
                    local a = set[was.prefix .. kind]
                    if was.given[kind] and math.abs(a.BaseValue - was.given[kind]) <= 0.001 then
                        a.BaseValue, a.CurrentValue = a.BaseValue / was.f, a.CurrentValue / was.f
                    end
                end)
            end
        end
        local prefix = f >= 1 and UP or DOWN
        local given = {}
        hits[addr] = { name = name, f = f, prefix = prefix, given = given }
        if f == 1 then
            return was ~= nil       -- (one put back took its calls)
        end
        for _, kind in ipairs(KINDS) do
            pcall(function()
                local a = set[prefix .. kind]
                a.BaseValue, a.CurrentValue = a.BaseValue * f, a.CurrentValue * f
                given[kind] = a.BaseValue
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
        -- (The numbers changed, to 100 too: one whole pass more looks at every body's hits, so the number before is taken
        -- back where it stands. At 100 none was looked at, and every body kept the one before, the ini's back at 100 and
        -- co-op started again from the panel too: the review of 11-10.)
        local seen = scaling.hitsSeen
        if not seen or seen[1] ~= scaling.damage or seen[2] ~= scaling.bossDamage then
            scaling.hitsSeen, scaling.hitsBack = { scaling.damage, scaling.bossDamage }, seen and 2 or 0
        end
        local hitting = scaling.damage ~= 1 or scaling.bossDamage ~= 1 or scaling.hitsBack > 0
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
            scaling.hitsBack = math.max(0, scaling.hitsBack - 1)
        end
        for _ = 1, LOOKS_PER_TICK do
            local e, addr = todo[at], addrs[at]
            if e == nil then
                return
            end
            at = at + 1
            local name = valid(e) and not inSoloFight(addr) and e:GetFName():ToString()
            -- (How hard it hits, a ghost twin's too: twins.lua gives a twin its original's health and posture, already
            -- scaled, as it came, but not this; the review of 11-09, every twin at the game's own.)
            if name and hitting and not game.isDead(e) and scaleHits(e, addr, name) then
                hitN = hitN + 1
                return
            end
            -- (Nothing else for a ghost twin: it took its original's numbers as it came.)
            if name and game.twinId and game.twinId(addr, e) then
                name = false
            end
            if name and not game.isDead(e) and poiseBoss(e, addr, name) then
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
                    local health, posture, boss = numbersFor(e, addr)
                    scaleAttr(set, "Health", "Health_Max", health)
                    scaleAttr(set, "Shachi", "Shachi_Max", posture)
                    scaledMax[addr] = maxOf(e)
                    scaledAs[addr] = { name = name, h = health, p = posture, boss = boss, players = 2 }
                    n = n + 1
                    return
                end
            end
            if name and (scaling.bossHealth or scaling.bossPosture) and promoteBoss(e, addr, name) then
                return
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
    -- CoopBossDamage; bosses left out: the enemies' number). Enemies about take the new number too, from the game's own:
    -- scaleHits takes the old one back first.
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
