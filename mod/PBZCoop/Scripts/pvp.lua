-- PvPvE (PhantomPact.ini "PvP = On", F5 > MORE, or the "pvp on|off" command): you and your partner can fight each other out in
-- the world, enemies and all. And the fight of a PvP match (arena.lua, F6): everyone on the other team, up to six players.
--
-- The defender's game decides every hit. In your world your opponent's ghost is made hostile to you and replays
-- their moves, so its swings hit you through the game's own combat: block, parry (deflect), perfect dodge,
-- posture and hit reactions all work exactly as against an enemy. Your own hits on the ghost are only for show;
-- they land in your opponent's world, where your ghost swings at them.
--
-- Parrying pays off like against a boss. The game's deflect leaves an attacking player unharmed, so the mod judges
-- it on the defender's side, by the game's own deflect: your guard, raised to meet their blow, answered it (the game's
-- Defence move), you were in reach, and it cost you neither health nor posture (a guard held from before only blocks:
-- the game turns the blow aside, nothing more). That moment your opponent staggers and loses posture ("V parry"), and
-- you see their figure stagger too; they see yours turn the blow aside (moves.lua sends that one move in a match).
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

    -- What a foe's copy of our stats was made from: the few of ours that setting up a match changes (the skill tree, the
    -- match's levels), three reads. The whole block is copied again only when they've moved: copied every RESTAT_S
    -- regardless (223 attributes, thousands of calls), a 3v3 hitched 22-55 ms every 2 s for the whole match (the review).
    local function statSig(pawn)
        local ok, sig = pcall(function()
            local a = pawn.AttributeSetBase
            return string.format("%.1f/%.1f/%.1f", a.Health_Max.CurrentValue, a.Attack.CurrentValue,
                a.ShachiAttack.CurrentValue)
        end)
        return ok and sig or nil
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
    -- Each foe's latest attack, from its start (their M): what we looked like then, and whether it's settled.
    local swings = {}               -- slot -> { at, hp, posture, low, done, yaw }
    local SWING_S = 1.2             -- open this long at least (a light blow lands about 0.3 s into its move: the bench, 11-07)
    local SWING_MAX_S = 3.0         -- and on while their figure still plays its move: a slow one's blow comes late
    local WINDUP_S = 0.15           -- no blow lands sooner after its move starts: a younger swing isn't what our guard met
    local FACING_DEG = 70           -- their move aimed within this of us (its yaw comes with their M), or it wasn't at us
    local BLOCK_POSTURE = 20        -- our guard's answer that cost more posture than this, in a tick, was a block
    local GUARD_LEAD_S = 0.15       -- a guard raised this long before their attack came still met it (a read of it)
    local guard = { addr = nil, pos = 0, posture = nil }    -- our guard's last answer to a blow; our posture a tick ago
    local function watchDeath(pawn)
        local hp = game.getHealth(pawn)
        local dead = (hp ~= nil and hp <= 0) or game.isDead(pawn)
        if not dead then
            deathScored = false
            return
        end
        if not deathScored then
            deathScored = true
            -- A killing blow from full-ish health can land and kill within one tick, before watchSwing noted the
            -- hit: a partner swing in progress counts as their hit too.
            if next(swings) ~= nil or os.clock() - lastPartnerHitAt <= KILL_WINDOW_S then
                coop.sendEvent("V", "lose")
                scoreRound(false)
            end
            swings = {}
            lastPartnerHitAt = -100
        end
    end

    -- A move off the wire (coop.lua: p.movePath, its ability's class) that's an attack. Not one of these, by the names of the
    -- player's moves on the bench (11-07): the dodges (AdvancedDash, SpecialDash, PerfectDodge: a dash attack, A_Dash, is an
    -- attack), the guard's, the jump, the weapon's buff and draw, and a passive. (A passive is always on: every figure runs
    -- GA_Hun_ShachiHook_Passive_C, and taken for a swing it kept every swing open: not one parry was ever judged in a match.)
    local NOT_ATTACKS = { "AdvancedDash", "SpecialDash", "Dodge", "Deflect", "Escape", "Stance", "_Jump_C", "Buff",
        "ChangeArmed", "Passive" }
    local function isAttack(path)
        local name = path and path:match("([^.]+)$")
        if not (name and name:find("^GA_")) then
            return false
        end
        for _, word in ipairs(NOT_ATTACKS) do
            if name:find(word, 1, true) then
                return false
            end
        end
        return true
    end

    -- Their figure still in a move of theirs: a montage, not a flinch, a guard's or a dodge's.
    local function stillMoving(ghost)
        local busy = false
        pcall(function()
            local ai = ghost.Mesh:GetAnimInstance()
            local m = valid(ai) and ai:GetCurrentActiveMontage()
            if valid(m) then
                local name = m:GetFName():ToString()
                busy = not (name:find("Hit", 1, true) or name:find("Dash", 1, true) or game.isGuardMove(name))
            end
        end)
        return busy
    end

    -- A foe's attack opens a swing, from their M (coop.lua: p.moveAt, and p.moveYaw where it aimed): what we looked like then.
    -- Their blow landing settles it (no parry from it) and says who struck last. It shuts SWING_S after its start, or later
    -- while their figure still plays the move (SWING_MAX_S at most): a slow move's blow comes after SWING_S (the review).
    local function watchSwing(slot, p, now, hp, posture, ghost)
        local s = swings[slot]
        if p.moveAt and (not s or s.at ~= p.moveAt) and now - p.moveAt <= SWING_S and isAttack(p.movePath) then
            s = { at = p.moveAt, hp = hp, posture = posture, yaw = p.moveYaw }
            swings[slot] = s
        end
        if not s then
            return
        end
        if now - s.at > SWING_S and (now - s.at > SWING_MAX_S or not stillMoving(ghost)) then
            swings[slot] = nil
        elseif hp and hp < (s.low or s.hp or hp) - 0.5 then
            s.done, s.low = true, hp
            lastPartnerHitAt = now
            pvp.lastHitBy = slot
        end
    end

    -- Our guard's answer to a blow, the game's own: the montage it plays now (its address and position), or nil.
    local function guardReaction(pawn)
        local addr, pos = nil, 0
        pcall(function()
            local ai = pawn.Mesh:GetAnimInstance()
            local m = valid(ai) and ai:GetCurrentActiveMontage()
            if valid(m) and game.isGuardReaction(m:GetFName():ToString()) then
                addr, pos = m:GetAddress(), ai:Montage_GetPosition(m) or 0
            end
        end)
        return addr, pos
    end

    -- A parry, judged by the game's own deflect, and timed: our guard raised to meet their blow (the bench, 11-07: a guard
    -- pressed as the blow comes plays a Defence montage and costs nothing; one already held when it came plays the same and
    -- costs nothing either, so the game turns aside every blow into a held guard, and a stagger for each made holding it the
    -- whole match's answer; a swing that never reached us plays none, guard or not). A new answer of our guard settles the
    -- swing whose blow it met: of those open, in reach, aimed at us (FACING_DEG) and old enough for a blow to have come
    -- (WINDUP_S), the latest begun. (The review: the nearest open one was taken, a blow that hadn't come yet or one at a
    -- teammate; and in PvPvE an enemy's blow turned aside staggered a partner who was only swinging near us.) Raised after
    -- their attack came (GUARD_LEAD_S), nothing lost: our foe staggers and loses posture ("V parry", at once), and their
    -- figure here staggers too. Held from before, or costing posture in a tick: the game's block alone.
    -- open: slot -> that foe's figure, this tick's (none kept).
    local function watchGuard(pawn, open, now, hp, posture)
        local addr, pos = guardReaction(pawn)
        local fresh = addr ~= nil and (addr ~= guard.addr or pos < guard.pos - 0.05)
        local before = guard.posture
        guard.addr, guard.pos, guard.posture = addr, pos, posture
        if not fresh then
            return
        end
        local at, met = pawn:K2_GetActorLocation(), now - pos
        local best, bestAt = nil, -math.huge
        for slot, ghost in pairs(open) do
            local s = swings[slot]
            if s and not s.done and met - s.at >= WINDUP_S and s.at > bestAt then
                local g = ghost:K2_GetActorLocation()
                local aimed = true
                if s.yaw then
                    local to = math.deg((math.atan2 or math.atan)(at.Y - g.Y, at.X - g.X))
                    aimed = math.abs((to - s.yaw + 540) % 360 - 180) <= FACING_DEG
                end
                if aimed and api.distance(at, g) <= PARRY_REACH_CM then
                    best, bestAt = slot, s.at
                end
            end
        end
        local s = best and swings[best]
        if not s then
            return
        end
        s.done = true
        before = before or s.posture
        if (hp and s.hp and hp < s.hp - 0.5) or (posture and before and posture < before - BLOCK_POSTURE)
            or (game.guardUpAt or -1e9) < s.at - GUARD_LEAD_S then
            return          -- (a block: our guard was up before their attack, or the game took it out of our posture)
        end
        local cost = pvp.teams and MATCH_PARRY_POSTURE or pvp.parryPosture
        if net.party then
            coop.sendEvent("V", "parry", string.format("%.0f", cost), best)
        else
            coop.sendEvent("V", "parry", string.format("%.0f", cost))
        end
        if game.playHitReaction then
            game.playHitReaction(open[best], STAGGER_TAG)
        end
        log(string.format("PvP: PARRIED! Your partner staggers (-%.0f posture).", cost))
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

    local hostile = {}              -- ghost address -> { ghost, at (when its stats were given), guardShield }

    -- A foe's figure while its player holds the guard (its bit with their place) or has just turned a blow aside (their
    -- Defence move, moves.lua: p.guardAt): shielded, so our blows don't make it flinch over the guard they have up. Their game
    -- decides every hit; ours on the figure are only for show. (The bench, 11-07: our blow's flinch came over their deflect.)
    local GUARD_SHIELD_S = 0.6
    -- The shield's class: searched for once (a search of every object, 1-3 ms: the review), then by its path.
    local shieldPath = nil
    local function shieldClass()
        local cls = shieldPath and StaticFindObject(shieldPath)
        if not valid(cls) then
            cls = FindObject("BlueprintGeneratedClass", "GE_PBZLieInvulnerable_C")
            if valid(cls) then
                shieldPath = cls:GetFullName():gsub("^%S+ ", "")
            end
        end
        return valid(cls) and cls or nil
    end
    local function guardShield(ghost, h, on)
        if (h.guardShield ~= nil) == on then
            return
        end
        pcall(function()
            local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            local asc = bl:GetAbilitySystemComponent(ghost)
            if not valid(asc) then
                return
            end
            if on then
                local cls = shieldClass()
                if cls then
                    h.guardShield = asc:BP_ApplyGameplayEffectToSelf(cls, 1, asc:MakeEffectContext())
                end
            else
                asc:RemoveActiveGameplayEffect(h.guardShield, -1)
            end
        end)
        if not on then
            h.guardShield = nil
        end
    end

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
                    guardShield(h.ghost, h, false)
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
        local now = os.clock()
        local hp, posture, open = nil, nil, nil     -- (ours, read once a tick only while a foe's move is fresh)
        for addr, f in pairs(want) do
            local p, ghost = f.p, f.p.ghost
            if not p.ghostHidden then
                local h = hostile[addr]
                if not h then
                    game.shieldGhost(ghost, false)        -- in a duel the ghost must take real hits
                    giveGhostStats(ghost, pawn)
                    if setHostile(pawn, ghost, true) then
                        hostile[addr] = { ghost = ghost, at = now, sig = statSig(pawn) }
                    end
                elseif h.restat or (pvp.teams and now - h.at >= RESTAT_S) then
                    h.at = now
                    local sig = statSig(pawn)
                    if h.restat or sig == nil or sig ~= h.sig then
                        h.restat, h.sig = nil, sig
                        giveGhostStats(ghost, pawn)
                        h.maxhp = nil       -- (that copied this player's top health over theirs: written again below)
                    end
                end
                -- The ghost shows its player's real health (it never drops to 0 here, so it can keep fighting). (Its top only
                -- written when it changed: a closure and two writes a tick for each foe.)
                local t = p.target
                h = hostile[addr]
                if h then
                    guardShield(ghost, h, p.stance == true or now - (p.guardAt or -1e9) < GUARD_SHIELD_S)
                end
                if t and t.Hp and t.MaxHp and t.MaxHp > 0 then
                    if not h or h.maxhp ~= t.MaxHp then
                        setAttr(ghost, "Health_Max", t.MaxHp)
                        if h then
                            h.maxhp = t.MaxHp
                        end
                    end
                    game.setHealth(ghost, math.max(1, t.Hp))
                end
                if swings[f.slot] or (p.moveAt and now - p.moveAt <= SWING_S) then
                    if hp == nil then
                        hp, posture = game.getHealth(pawn), game.getPosture(pawn)
                    end
                    watchSwing(f.slot, p, now, hp, posture, ghost)
                    if swings[f.slot] then
                        open = open or {}
                        open[f.slot] = ghost
                    end
                end
                -- Keep the ghost's posture pool from emptying here (their real posture lives on their PC). (Only when it's
                -- below the top: a read of memory, not two writes, a tick.)
                local gmax = attr(ghost, "Shachi_Max")
                if gmax and game.setPosture then
                    local top = gmax.CurrentValue
                    local now2 = game.getPosture and game.getPosture(ghost)
                    if not now2 or now2 < top - 1 then
                        game.setPosture(ghost, top)
                    end
                end
            end
        end
        if open and game.isGuardReaction then
            watchGuard(pawn, open, now, hp, posture)
        else
            guard.addr = nil
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
            -- (The ghost's attack given again next tick. Not by emptying the list: a figure's guard shield in it stayed on
            -- for good, its handle gone; the review.)
            for _, h in pairs(hostile) do
                h.restat = true
            end
            log(string.format("PvP damage %d%%.", math.floor(pvp.damage * 100 + 0.5)))
        else
            log(string.format("PvP %s, damage %d%%, score %d - %d. Usage: pvp on|off|damage <percent>",
                pvp.on and "on" or "off", math.floor(pvp.damage * 100 + 0.5), pvp.wins, pvp.losses))
        end
    end

    return pvp
end
