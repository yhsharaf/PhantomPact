-- PvPvE (PhantomPact.ini "PvP = On", F5 > MORE, or the "pvp on|off" command): you and your partner can fight each other out in
-- the world, enemies and all. And the fight of a PvP match (arena.lua, F6): everyone on the other team, up to six players.
--
-- The defender's game decides every hit. In your world your opponent's ghost is made hostile to you and replays
-- their moves, so its swings hit you through the game's own combat: block, parry (deflect), perfect dodge,
-- posture and hit reactions all work exactly as against an enemy. Your own hits on the ghost are only for show;
-- they land in your opponent's world, where your ghost swings at them.
--
-- Parrying pays off like against a boss. The game's deflect leaves an attacking player unharmed, so the mod judges
-- it on the defender's side: your guard (stance) came up during your opponent's swing, you were in reach, and it
-- cost you neither health nor posture (a plain block costs posture). Then your opponent staggers and loses posture
-- ("V parry"), and you see their ghost stagger too.
--
-- PvPvE: death decides. The loser really dies (and respawns at their bell, as after any death). A death within a few
-- seconds of your partner's last hit counts as their win ("V lose"); dying to an enemy doesn't. In a match, arena.lua keeps
-- score and nobody dies: this file only says who struck last (pvp.lastHitBy).

return function(api)
    local log, valid, getPlayer1, game = api.log, api.valid, api.getPlayer1, api.game
    local coop = api.coop
    local net = coop.net

    local HOSTILE = 2               -- ETeamAttitude::Hostile
    local KILL_WINDOW_S = 8.0       -- a death this soon after the partner's last hit is their kill
    local PARRY_REACH_CM = 350      -- a swing from further away can't have been parried (it missed)
    local STAGGER_TAG = "CharacterState.Hitreact.State.Normal.Heavy"
    local RESTAT_S = 2.0            -- a hostile ghost's stats copied again this often in a match (ours change as it sets up)
    -- In a match each world works out the damage its own player takes, so a player's own PvPDamage and PvPParryPosture
    -- would make it unfair: there the match's own numbers count for everyone (arena.lua says the damage).
    local MATCH_PARRY_POSTURE = 60

    local pvp = {
        on = false,
        damage = 1.0,       -- PvPDamage / 100: scales the ghost's attack, i.e. the damage you take
        parryPosture = 60,  -- PvPParryPosture: posture a parried attacker loses
        wins = 0,
        losses = 0,
        teams = nil,        -- in a match: slot -> team (arena.lua), and this player's slot
        me = nil,
        lastHitBy = nil,    -- the slot whose swing last took health off this player
    }
    net.pvp = false

    local factionOf = {}            -- actor address -> FactionComponent
    local function faction(actor)
        local addr = actor:GetAddress()
        local c = factionOf[addr]
        -- (And still that actor's: another at the same address after the old one was collected got its faction set.)
        if valid(c) then
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                return c
            end
            factionOf[addr] = nil
        end
        for _, comp in ipairs(FindAllOf("FactionComponent") or {}) do
            local ok, owner = pcall(function() return comp:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                factionOf[addr] = comp
                return comp
            end
        end
        return nil
    end

    local function attr(actor, name)
        local ok, a = pcall(function() return actor.AttributeSetBase[name] end)
        return ok and a or nil
    end

    local function setAttr(actor, name, value)
        pcall(function()
            local a = actor.AttributeSetBase[name]
            a.BaseValue = value
            a.CurrentValue = value
        end)
    end

    -- The ghost was spawned as an empty shell (0 health counts as dead, and the dead can't attack): give it a full
    -- stat block. It gets ours, so both fighters hit equally hard and only skill decides; PvPDamage scales it.
    local function giveGhostStats(ghost, pawn)
        local src, dst = pawn.AttributeSetBase, ghost.AttributeSetBase
        src:GetClass():ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            pcall(function()
                local a = src[name]
                if type(a) == "userdata" and a.BaseValue ~= nil then
                    dst[name].BaseValue = a.BaseValue
                    dst[name].CurrentValue = a.CurrentValue
                end
            end)
        end)
        local scale = pvp.teams and (pvp.matchDamage or 1) or pvp.damage
        local atk = attr(pawn, "Attack")
        if atk then
            setAttr(ghost, "Attack", atk.CurrentValue * scale)
        end
        local edge = pvp.teams and attr(pawn, "ShachiAttack")
        if edge then
            setAttr(ghost, "ShachiAttack", edge.CurrentValue * scale)    -- (Phantom Edges hit by this one)
        end
        setAttr(ghost, "Health_Min", 1)
    end

    local function setHostile(pawn, ghost, hostile)
        local pf, gf = faction(pawn), faction(ghost)
        if not (pf and gf) then
            return false
        end
        pcall(function()
            if hostile then
                pf:SetFactionRelationOverride(ghost, HOSTILE, true)
                gf:SetFactionRelationOverride(pawn, HOSTILE, true)
            else
                pf:ClearFactionRelationOverride(ghost)
                gf:ClearFactionRelationOverride(pawn)
            end
        end)
        return true
    end

    -- Original lines in the game's wuxia spirit (not quotes from the game), one picked at random per duel.
    local WIN_LINES = {
        "Your blade was faster. The pact holds.",
        "One cut, one answer. You stand.",
        "The phantom fades; your edge remains.",
        "Steel spoke, and it spoke your name.",
        "A soul tested, a soul proven.",
    }
    local LOSS_LINES = {
        "Your blade wavered. Rise, and draw again.",
        "Even a phantom bleeds. Return to the bell.",
        "The duel is lost, not the pact.",
        "Your partner's steel found its mark.",
        "Fall, rise, and sharpen your soul.",
    }
    pvp.WIN_LINES, pvp.LOSS_LINES = WIN_LINES, LOSS_LINES

    local function scoreRound(won)
        if won then
            pvp.wins = pvp.wins + 1
        else
            pvp.losses = pvp.losses + 1
        end
        local lines = won and WIN_LINES or LOSS_LINES
        log(string.format("PvP: %s %s Score %d - %d.", won and "VICTORY." or "DEFEAT.",
            lines[math.random(#lines)], pvp.wins, pvp.losses))
        -- The loser sees the game's own death screen; the winner gets its golden mirror.
        if won and game.showAliveScreen then
            game.showAliveScreen(6)
        end
    end

    local lastPartnerHitAt = -100   -- os.clock() of the partner's last hit on us
    local deathScored = false       -- this death was already reported (until we're alive again)
    -- One opponent's swing at a time each (watchParry): what we looked like when it started, and whether our guard came up.
    local swings = {}               -- slot -> { hp, posture, guarded, spoiled }
    local function watchDeath(pawn)
        local hp = game.getHealth(pawn)
        local dead = (hp ~= nil and hp <= 0) or game.isDead(pawn)
        if not dead then
            deathScored = false
            return
        end
        if not deathScored then
            deathScored = true
            -- A killing blow from full-ish health can land and kill within one tick, before watchParry noted the
            -- hit: a partner swing in progress counts as their hit too.
            if next(swings) ~= nil or os.clock() - lastPartnerHitAt <= KILL_WINDOW_S then
                coop.sendEvent("V", "lose")
                scoreRound(false)
            end
            swings = {}
            lastPartnerHitAt = -100
        end
    end

    -- Active move names on an actor (GA_Hun_* only: attacks, stance, dashes).
    local function activeMoves(actor)
        local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local asc = valid(bl) and bl:GetAbilitySystemComponent(actor) or nil
        local out = {}
        if not valid(asc) then
            return out
        end
        pcall(function()
            asc.ActivatableAbilities.Items:ForEach(function(_, elem)
                local spec = elem:get()
                if spec.ActiveCount > 0 and valid(spec.Ability) then
                    local name = spec.Ability:GetClass():GetFName():ToString()
                    if name:find("^GA_Hun") then
                        out[#out + 1] = name
                    end
                end
            end)
        end)
        return out
    end

    local function isAttack(name)
        return not (name:find("Stance") or name:find("Dash") or name:find("Dodge") or name:find("Deflect")
            or name:find("Escape"))
    end

    -- slot: whose ghost this is. In a party the parry names the attacker (only they stagger); two players need no name.
    local function watchParry(pawn, ghost, slot, ownMoves)
        local attacking = false
        for _, name in ipairs(activeMoves(ghost)) do
            if isAttack(name) then
                attacking = true
            end
        end
        local hp, posture = game.getHealth(pawn), game.getPosture(pawn)
        local swing = swings[slot]
        if attacking and not swing then
            swing = { hp = hp, posture = posture, guarded = false }
            swings[slot] = swing
        end
        if swing then
            for _, name in ipairs(ownMoves()) do
                if name:find("Stance") then
                    swing.guarded = true
                end
            end
            -- A hit or a block during the swing settles it: no parry.
            if hp and swing.hp and hp < swing.hp - 0.5 then
                swing.spoiled = true
                lastPartnerHitAt = os.clock()
                pvp.lastHitBy = slot
            elseif posture and swing.posture and posture < swing.posture - 0.5 then
                swing.spoiled = true
            end
        end
        if swing and not attacking then
            local near = api.distance(pawn:K2_GetActorLocation(), ghost:K2_GetActorLocation()) <= PARRY_REACH_CM
            if swing.guarded and not swing.spoiled and near then
                local cost = pvp.teams and MATCH_PARRY_POSTURE or pvp.parryPosture
                if net.party then
                    coop.sendEvent("V", "parry", string.format("%.0f", cost), slot)
                else
                    coop.sendEvent("V", "parry", string.format("%.0f", cost))
                end
                if game.playHitReaction then
                    game.playHitReaction(ghost, STAGGER_TAG)
                end
                log(string.format("PvP: PARRIED! Your partner staggers (-%.0f posture).", cost))
            end
            swings[slot] = nil
        end
    end

    local function slotOf(p)
        if net.party then
            return p.number
        end
        return coop.isHost() and 2 or 1
    end

    -- Who this player fights: in PvPvE the partner; in a match everyone on the other team.
    local function foes()
        local out = {}
        for _, p in ipairs(coop.partners()) do
            local slot = slotOf(p)
            if pvp.teams then
                local mine = pvp.teams[pvp.me]
                if pvp.teams[slot] and mine and pvp.teams[slot] ~= mine then
                    out[#out + 1] = { p = p, slot = slot }
                end
            elseif pvp.on then
                out[#out + 1] = { p = p, slot = slot }
            end
        end
        return out
    end

    local hostile = {}              -- ghost address -> { ghost, at (when its stats were given) }
    local function calm(pawn, ghost)
        setHostile(pawn, ghost, false)
        if game.setupGhost then
            game.setupGhost(ghost)           -- harmless again
        end
        game.shieldGhost(ghost, true)        -- and out of the enemies' reach
    end

    local function tick()
        local active = pvp.on or pvp.teams ~= nil
        local _, pawn = getPlayer1()
        local want = {}
        if active and valid(pawn) then
            for _, f in ipairs(foes()) do
                if valid(f.p.ghost) then
                    want[f.p.ghost:GetAddress()] = f
                end
            end
        end
        -- A ghost that was hostile and no longer is (PvP off, a team change, the match over) made harmless, once there's a
        -- body to be at peace with. (Ended while dead or loading, a ghost stayed armed and hostile with PvP off.)
        for addr, h in pairs(hostile) do
            if not want[addr] and valid(pawn) then
                if valid(h.ghost) then
                    calm(pawn, h.ghost)
                end
                hostile[addr] = nil
            end
        end
        if not active then
            return
        end
        if valid(pawn) and not pvp.teams then
            watchDeath(pawn)
        end
        if not valid(pawn) then
            return
        end
        local own = nil
        local function ownMoves()
            own = own or activeMoves(pawn)
            return own
        end
        local now = os.clock()
        for addr, f in pairs(want) do
            local p, ghost = f.p, f.p.ghost
            if not p.ghostHidden then
                local h = hostile[addr]
                if not h then
                    game.shieldGhost(ghost, false)        -- in a duel the ghost must take real hits
                    giveGhostStats(ghost, pawn)
                    if setHostile(pawn, ghost, true) then
                        hostile[addr] = { ghost = ghost, at = now }
                    end
                elseif (pvp.teams and now - h.at >= RESTAT_S) or h.restat then
                    h.at, h.restat = now, nil
                    giveGhostStats(ghost, pawn)
                end
                -- The ghost shows its player's real health (it never drops to 0 here, so it can keep fighting).
                local t = p.target
                if t and t.Hp and t.MaxHp and t.MaxHp > 0 then
                    setAttr(ghost, "Health_Max", t.MaxHp)
                    game.setHealth(ghost, math.max(1, t.Hp))
                end
                watchParry(pawn, ghost, f.slot, ownMoves)
                -- Keep the ghost's posture pool from emptying here (their real posture lives on their PC).
                local gmax = attr(ghost, "Shachi_Max")
                if gmax and game.setPosture then
                    game.setPosture(ghost, gmax.CurrentValue)
                end
            end
        end
    end
    coop.extraTicks.pvp = tick

    coop.handlers.V = function(rest)
        local kind, arg, target = rest:match("^(%S+)%s*(%S*)%s*(%S*)")
        if not (pvp.on or pvp.teams) then
            return
        end
        if kind == "lose" then
            if not pvp.teams then
                scoreRound(true)
            end
        elseif kind == "parry" then
            -- (In a party the parry names whose swing it was: only they stagger.)
            local who = tonumber(target)
            if who and pvp.me and who ~= pvp.me then
                return
            end
            -- Our swing was parried: stagger and lose posture, like a boss whose attack you deflected.
            -- (Off the wire: "nan" emptied this player's posture, a huge negative overfilled it.)
            local a = tonumber(arg)
            if not a or a ~= a or a < 0 or pvp.teams then
                a = pvp.teams and MATCH_PARRY_POSTURE or pvp.parryPosture
            end
            local amount = math.min(a, 400)
            local _, pawn = getPlayer1()
            if not valid(pawn) then
                return
            end
            local cur = game.getPosture(pawn)
            if cur and game.setPosture then
                game.setPosture(pawn, math.max(0, cur - amount))
            end
            if game.staggerSelf then
                game.staggerSelf(pawn, STAGGER_TAG)
            end
            log(string.format("PvP: your partner PARRIED you (-%.0f posture).", amount))
        end
    end

    function pvp.set(on)
        if on and net.party then
            api.status.notify("pvp", "PvPvE is off with more than two players (F6 PvP has teams).")     -- (one ghost to fight)
            return
        end
        pvp.on = on
        net.pvp = on or pvp.teams ~= nil
        local _, pawn = getPlayer1()
        if valid(pawn) and not pvp.teams then
            setAttr(pawn, "Health_Min", 0)     -- (1.1.0 duels held health at 1; deaths are real now)
        end
        log("PvP " .. (on and string.format("ON (damage %d%%). Score %d - %d.", math.floor(pvp.damage * 100 + 0.5), pvp.wins, pvp.losses) or "off."))
    end

    -- A match's teams (slot -> team) and this player's slot, or nil when it ends: who's a foe (arena.lua).
    -- damage: the match's scale on every blow, the same in every world.
    function pvp.arenaTeams(teams, me, damage)
        pvp.teams, pvp.me = teams, teams and me or nil
        pvp.matchDamage = teams and damage or nil
        pvp.lastHitBy = nil
        swings = {}             -- (a foe's stats, with the match's scale, are given again every RESTAT_S)
        -- Its figures' stats again, with or without the match's numbers: after a match with PvPvE still on, the partner's
        -- figure kept the match's half damage (the review of 1.7.0).
        for _, h in pairs(hostile) do
            h.restat = true
        end
        net.pvp = pvp.on or teams ~= nil
    end

    -- pvp on | off | status | damage <percent>
    function pvp.command(args)
        local cmd, arg = (args or ""):match("^%s*(%S*)%s*(%S*)")
        if cmd == "on" then
            pvp.set(true)
        elseif cmd == "off" then
            pvp.set(false)
        elseif cmd == "alive" then
            log("Victory screen: " .. tostring(game.showAliveScreen and game.showAliveScreen(6)))
        elseif cmd == "parry" and tonumber(arg) then
            pvp.parryPosture = math.max(0, math.min(400, tonumber(arg)))
            log(string.format("PvP parry reward: %.0f posture.", pvp.parryPosture))
        elseif cmd == "damage" and tonumber(arg) then
            pvp.damage = math.max(0.1, math.min(3.0, tonumber(arg) / 100))
            hostile = {}        -- re-apply the ghost's attack next tick
            log(string.format("PvP damage %d%%.", math.floor(pvp.damage * 100 + 0.5)))
        else
            log(string.format("PvP %s, damage %d%%, score %d - %d. Usage: pvp on|off|damage <percent>",
                pvp.on and "on" or "off", math.floor(pvp.damage * 100 + 0.5), pvp.wins, pvp.losses))
        end
    end

    return pvp
end
