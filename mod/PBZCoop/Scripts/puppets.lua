-- The host's enemies, played on the guest's copies. Left to their own AI, each game fought its own enemies and only
-- their positions and health were pulled together, so two players never saw the same fight.
--
-- A copy the host lists has its AI stopped and follows the host's position here. Whatever the host's enemy starts
-- goes as "A <enemy> <ability class|-> <montage path|-> <position> <who it's aimed at>": host, guest or -, or with more than
-- two players a slot or -. An ability replays for real, so its hits land
-- on the guest and guard, parry and dodge work as usual; a montage alone (hit reactions) deals no damage. Montages
-- the game builds at run time (turns) have no path to send and are left out.
--
-- The same goes the other way for an enemy a guest's game runs (coop.lua's handover): the guest sends, and the host's copy
-- follows. "Host" and "guest" in an "A" always mean the same two players, whichever PC says it.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    -- (Looser values let a boss's copy end a dash attack -- the "red flash" lunges -- up to 5.5 m
    -- from where the host's boss was and glide there slowly after, its prediction cut to 35 ms. Back near the
    -- original's, made frame-rate independent: at 110 fps the original pulled about 9 per second, at 60 about 5.)
    local SNAP_CM = 1000          -- further than this (1200 for bosses) the copy snaps there
    local NUDGE_CM = 200          -- further than this, gently blend position without fighting locomotion
    local NUDGE_SHARE = 7.0       -- exponential blend rate per second (dt-scaled)
    local LOCKED_CM = 250         -- a move's own root motion plays out (350 for bosses)
    local BUSY_CM = 40            -- during an attack (60 for bosses), leave root motion natural
    local BUSY_PULL = 7.0         -- exponential blend rate per second during attacks
    local BUSY_TURN = 8.0         -- during an attack, rate the copy turns to where the host's boss faces
    local PULL = 3.8              -- per second: speed added per cm off the host's position
    local STILL = 25              -- cm/s; asked to move slower than this, it stands
    local MAX_SPEED = 1450        -- cm/s
    local AHEAD_S = 0.15          -- the host's position carried forward at its speed, at most this (the original's 0.2)
    local TURN_SHARE = 12.0       -- smooth per-frame yaw convergence
    local TURN_EVERY_S = 0.0
    local BUSY_S = 0.8            -- after an attack starts, leave the copy's facing to the move
    local BUSY_MAX_S = 4.0        -- ... for as long as the move lasts, up to this
    local MOVE_LOOK_S = 0.1
    local RESTART_S = 0.05        -- the same montage at an earlier position = played again
    local AI_EVERY_S = 0.1        -- how often each copy's AI is stopped again: the game restarts it by itself
    local REACT_S = 2.5           -- a copy's own reaction to this player's hit plays out this long at most, before any move
    local JUMP_HOLD_S = 0.35      -- after a jump of the host's enemy (coop.lua's readEnemies), its copy is kept to the line
    local JUMP_OFF_CM = 120       -- ... set there whenever it is further from it than this
    local JUMP_AHEAD_CM = 400     -- ... unless it is this little ahead of the line on the jump's own way
    local RIDE_LOOK_S = 0.5       -- how often a copy is asked what it rides
    local RIDE_SOON_S = 0.1       -- ... one whose mount is no copy of the host's yet
    local RIDE_WAIT_S = 1.0       -- and for this long after it's first followed it's left on such a mount
    -- Abilities that stay on and aren't moves. (Bosses keep a "Subtitles" one up for their lines: taken for the move, the
    -- real attack was never replayed and only its animation reached the guest, which hurts no one.)
    local PASSIVE = { "Passive", "Locomotion", "SpaceState", "Stance", "Utilities", "HitMirror", "Subtitles" }

    local puppets = { attacks = 0, played = 0, failed = 0, noCopy = 0 }
    puppets.ridden = {}           -- guest: address of what a copy rides -> that copy's name, as last looked at (steer):
                                  -- coop.lua's matchRemoteEnemies pairs a mount by its rider
    local byAddr = {}             -- guest: actor address -> { actor, name, target, busyUntil }
    local hostSeen = {}           -- host: enemy name -> { addr, pos } of the montage last sent
    local hostMoves = {}          -- host: enemy address -> { name, path, ability, start, montage } of the move last sent,
                                  -- for an armoured boss to take it up again after a flinch (resumeHost)
    local failedOnce = {}         -- guest: moves already logged as not replayed

    -- A copy no longer rides what it was last seen on (it got down, died, was let go, or is another's record now).
    local function unseat(p)
        if p.mount ~= nil and puppets.ridden[p.mount] == p.name then
            puppets.ridden[p.mount] = nil
        end
        p.mount = nil
    end

    local function anyAnimOf(actor)
        local found = nil
        pcall(function()
            local list = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
            for i = 1, #list do
                local comp = list[i]:get()
                if valid(comp) then
                    local ai = comp:GetAnimInstance()
                    if valid(ai) then
                        found = ai
                        return
                    end
                end
            end
        end)
        return found
    end

    local function bossAttached(p, now)
        if not p.boss then
            return false
        end
        if now >= (p.attachAt or 0) then
            p.attachAt = now + 0.25
            local ok, par = pcall(function() return p.actor:GetAttachParentActor() end)
            p.attached = ok and valid(par)
        end
        return p.attached == true
    end

    local function localPlayerGrabbedBy(p, now)
        if not p.boss then
            return false
        end
        if now < (p.grabAt or 0) then
            return p.grabbed == true
        end
        p.grabAt = now + 0.10
        p.grabbed = false
        local _, pawn = api.getPlayer1()
        if not (valid(pawn) and valid(p.actor)) then
            return false
        end
        local grabbed = false
        local pst = game.hitStateOf and game.hitStateOf(pawn)
        if pst and pst ~= "None" then
            local pl = pst:lower()
            if pl:find("grab", 1, true) or pl:find("catch", 1, true) or pl:find("caught", 1, true)
                or pl:find("execut", 1, true) or pl:find("throw", 1, true) or pl:find("control", 1, true)
                or pl:find("bex", 1, true) or pl:find("behit_special", 1, true) then
                grabbed = true
            end
        end
        if not grabbed and api.moves then
            local ai = api.moves.animOf(pawn)
            local m = ai and ai:GetCurrentActiveMontage()
            if valid(m) then
                local mn = (m:GetFName():ToString() or ""):lower()
                if mn:find("grab", 1, true) or mn:find("catch", 1, true) or mn:find("caught", 1, true)
                    or mn:find("beexec", 1, true) or mn:find("throw", 1, true) or mn:find("_ged_", 1, true)
                    or mn:find("_exe_", 1, true) or mn:find("_bex_", 1, true) then
                    grabbed = true
                end
            end
        end
        if grabbed then
            local okD, d = pcall(function()
                return api.distance(pawn:K2_GetActorLocation(), p.actor:K2_GetActorLocation())
            end)
            p.grabbed = okD and d ~= nil and d <= 600
        end
        return p.grabbed
    end

    local function passive(name)
        for _, word in ipairs(PASSIVE) do
            if name:find(word, 1, true) then
                return true
            end
        end
        return false
    end

    -- Host, once a snapshot for every living enemy it shares.
    function puppets.watchHost(name, actor, addr)
        -- (An armoured boss's flinch is let go here first, so it never goes out as a move, and the move it cut is taken up
        -- again: scaling.lua's CoopBossArmor, resumeHost below.)
        local body = addr
        if net.partnerExec and net.partnerExec[name] then
            return
        end
        if api.scaling and api.scaling.letGo and api.scaling.letGo(actor, addr) then
            return
        end
        -- (Asked each time: kept by address, the list only grew, and a new enemy on a used address could be read through
        -- the old one's animation while that lingered.)
        local ai = api.moves.animOf(actor)
        if not ai then
            return
        end
        local m = ai:GetCurrentActiveMontage()
        local s = hostSeen[name]
        if not valid(m) then
            hostSeen[name], hostMoves[body] = nil, nil
            return
        end
        addr = m:GetAddress()
        local pos = ai:Montage_GetPosition(m) or 0
        if s == nil or addr ~= s.addr or pos < s.pos - RESTART_S then
            local ability = game.activeAbility(actor, passive)
            local path = api.moves.pathOf(m)
            path = api.moves.allowedPath(path) and path or nil
            if ability or path then
                local after = net.party and game.enemyAfterSlot(actor, net.ghostSlots) or game.enemyAfter(actor, net.ghost)
                if not net.party and not coop.isHost() and after ~= "-" then
                    after = after == "guest" and "host" or "guest"      -- (a guest's ghost is the host)
                end
                coop.sendEvent("A", name, ability or "-", path or "-", string.format("%.2f", pos), after)
                puppets.attacks = puppets.attacks + 1
                -- (A move of its own, not a reaction, kept to take up again after a flinch an armoured boss lets go.)
                local state = game.hitStateOf and game.hitStateOf(actor)
                hostMoves[body] = (path and (not state or state == "None"))
                    and { name = name, path = path, ability = ability or "-", start = os.clock() - pos, montage = addr } or nil
            end
        end
        hostSeen[name] = { addr = addr, pos = pos }
    end

    -- Host: the move last sent for the enemy at this address, while it may still be playing, or nil.
    function puppets.hostMoveOf(body)
        return hostMoves[body]
    end

    -- Host: an armoured boss's move that a hit cut (scaling.lua's letGo), taken up again where it had got to: its ability
    -- again, for its hits to land, and its animation at that place, as resumeMove does on a guest's copy. The guest's
    -- copy never stopped it, so nothing goes out. True if there was one; if not, the next move goes out as new.
    function puppets.resumeHost(actor, body)
        local move = hostMoves[body]
        local m = move and api.moves.montage(move.path)
        local ai = m and api.moves.animOf(actor)
        local at, len = move and os.clock() - move.start or 0, 0
        pcall(function() len = m:GetPlayLength() end)
        if not (ai and at < len - 0.1) then
            hostMoves[body] = nil
            if move then
                hostSeen[move.name] = nil
            end
            return false
        end
        if move.ability ~= "-" then
            game.playAbility(actor, move.ability)
        end
        if not pcall(function() ai:Montage_Play(m, 1.0, 0, at, true) end) then
            hostSeen[move.name] = nil
            return false
        end
        move.montage = m:GetAddress()
        hostSeen[move.name] = { addr = move.montage, pos = at }
        puppets.resumedHost = (puppets.resumedHost or 0) + 1
        return true
    end

    -- Host: this enemy was in one of its moves at its last turn (a montage playing: an attack, a flinch). A turn to another
    -- player waits for it to end, so no move is turned halfway through.
    function puppets.inMove(name)
        return hostSeen[name] ~= nil
    end

    -- Guest, for every copy of a host enemy, each snapshot.
    function puppets.follow(name, actor, target)
        local addr = actor:GetAddress()
        local p = byAddr[addr]
        -- (Another enemy at that address, the last one streamed out and collected: its brain, walk speed and target picker
        -- were the old one's, so its own AI ran on against the host's lines.)
        local fname = nil
        pcall(function() fname = actor:GetFName():ToString() end)
        if p and (p.name ~= name or p.fname ~= fname) then
            game.freeCopy(addr, true)
            unseat(p)
            p = nil
        end
        if p == nil then
            p = { actor = actor, name = name, fname = fname, busyUntil = 0, aiAt = 0, since = os.clock() }
            pcall(function() p.walkSpeed = actor.CharacterMovement.MaxWalkSpeed end)
            p.boss = (game.isBoss and game.isBoss(actor, addr)) or (game.bossTwin and game.bossTwin(actor, addr)) or false
            byAddr[addr] = p
        elseif not p.boss then
            p.boss = (game.isBoss and game.isBoss(actor, addr)) or (game.bossTwin and game.bossTwin(actor, addr)) or false
        end
        p.target = target
    end

    -- A boss copy's share of poise damage: none to speak of while it plays a move of the host's, the boss's own (CoopBossPoise)
    -- between them. A guest's blow broke the copy's attack on the guest's PC while the host's boss went on and finished it on
    -- a shielded figure, so a guest who hit into each attack was never hit by one ("the guest is almost completely safe",
    -- 1.6.6). Its posture still falls (a break and an execution go to the host as ever), and between moves it flinches as
    -- before, for the host to judge. (0.01, not 0: whether the game divides by it isn't known.)
    local function poiseFor(p)
        if not p.boss then
            return
        end
        local want = os.clock() < p.busyUntil and 0.01 or 1 / ((api.scaling and api.scaling.bossPoise) or 1)
        pcall(function()
            local a = p.actor.AttributeSetBase.TakenReductionMultiplier_Poise
            if math.abs(a.CurrentValue - want) > 0.001 then
                a.BaseValue, a.CurrentValue = want, want
            end
        end)
    end

    -- (scaling.lua leaves the ones followed here to poiseFor.)
    function puppets.follows(addr)
        return byAddr[addr] ~= nil
    end

    function puppets.abilityRecent(name, sec)
        local actor = coop.enemyActor and coop.enemyActor(name)
        local p = valid(actor) and byAddr[actor:GetAddress()]
        return p ~= nil and p.abilityAt ~= nil and (os.clock() - p.abilityAt) <= (sec or 2.0)
    end

    -- A hit of this player's on a copy here, which the game answered with a reaction (a flinch, a break, a knockdown, the far end
    -- of an execution): its montage, where it is in it, and the hit state, to go with the hit to whoever runs the enemy, or nil.
    -- Without it the enemy itself only lost health there: it never flinched, and threw a molotov while it was being executed.
    function puppets.reactionOf(actor)
        local tag = game.hitStateOf and game.hitStateOf(actor)
        if not (tag and tag:lower():find("hitreact", 1, true)) then
            return nil
        end
        local ai = api.moves.animOf(actor)
        local path, pos = "-", 0
        pcall(function()
            local m = ai:GetCurrentActiveMontage()
            if valid(m) and api.moves.allowedPath(api.moves.pathOf(m)) then
                path, pos = api.moves.pathOf(m), ai:Montage_GetPosition(m) or 0
            end
        end)
        puppets.learnDeaths(path)       -- (417: a flinch at this player's own blow says its kind's deaths too)
        return path, pos, tag
    end

    -- Whoever runs the enemy: the reaction the partner's copy played to their hit, on the enemy itself, from where theirs was.
    -- Not sent back to them as a move of its own: their copy plays it already.
    function puppets.react(name, actor, path, pos, tag)
        local m = path ~= "-" and api.moves.allowedPath(path) and api.moves.montage(path)
        local ai = m and api.moves.animOf(actor)
        local hold = 0.9
        if ai and pcall(function() ai:Montage_Play(m, 1.0, 0, pos + net.moveAge(), true) end) then
            pcall(function() hold = math.max(0.3, math.min(REACT_S, m:GetPlayLength() - pos)) end)
            hostSeen[name] = { addr = m:GetAddress(), pos = pos }
        end
        if tag ~= "-" and game.setHitState then
            game.setHitState(actor, tag, hold)
        end
    end

    -- 417. A copy's death to see. The host's word that an enemy died ended its copy here at once by the game's own
    -- kill, which has no blow behind it: the game plays no fall for it, the body is down from one frame to the next
    -- (the bench, 11-23, run253: the host's own enemy in MaleThug_Throw_Dead_Normal_F_Montage for 1.7 s, the guest's
    -- copy of it with its flinch stopped and no montage at all). And a copy this player was executing was ended as the
    -- execution's first blow took its last health, half a second into a paired move of four: its own half stopped, the
    -- player finishing on a body with no part in it. The players' words on 1.7.4: "enemies when they die they are like
    -- glitched for guest and finish combat with e also glitched".
    -- So before the kill (coop.lua's handlers.K, net.dieLater): a copy in an execution of this player's own is left to
    -- play it out; any other plays its kind's death montage, found by the name of the flinch it is in or was last in
    -- ("<kind>_Hit_<how>_<F|B>..._Montage" has "<kind>_Dead_Normal_<F|B>_Montage" beside it, and "_Dead_Launch_" for
    -- one in the air: the bench's list of 35, run254), only if this game has it loaded. Then the kill, as before. One
    -- with nothing to show (never flinched, a kind with no such montage, down already) is ended at once, as before.
    -- (A death's show: the fall itself. What is left of its montage is the body lying still, and till it is ended
    -- the copy is one the game still lets this player lock on to.)
    local DEATH_SHOW_S, EXEC_SHOW_S = 1.0, 7.0      -- a death's show and an execution's rest wait this long at most
    local FLINCH_KEPT_S = 10.0                      -- a flinch this long ago still says what kind it is
    local FLINCHED_MAX = 300
    puppets.flinched, puppets.flinchedN = {}, 0     -- enemy name -> { path, at }: the host's enemy's last flinch told here
    -- (Flinches a body stands through, by the word after "_Hit_": the bench's, run253-258. NBreak: its guard broken, what
    -- a finishing strike of this player's starts from. Not the ones of a body down or getting up: Down, Ground,
    -- LaunchLand.)
    local STANDING = { Light = true, Middle = true, Heavy = true, VeryLight = true, Knockback = true, NBreak = true,
        Break = true, Stun = true }

    -- A kind's death montages this game has loaded, found beside the first flinch of that kind met here (in the same
    -- folder, its name's "_Hit_<how>" turned to "_Dead_Normal_F" and the like): kind ("MaleThug_Throw") -> { Normal_F =
    -- path... }. By the kind, not by each flinch's own folder: a broken guard's flinch lies elsewhere (run259).
    local DEATHS = { "Normal_F", "Normal_B", "Launch_F", "Launch_B" }
    local FLINCHES_MAX = 2000
    puppets.deaths = {}
    local flinchSeen, flinchSeenN = {}, 0
    function puppets.learnDeaths(path)
        if type(path) ~= "string" or flinchSeen[path] or flinchSeenN >= FLINCHES_MAX or not path:find("_Hit_", 1, true) then
            return
        end
        flinchSeen[path], flinchSeenN = true, flinchSeenN + 1
        local kind = path:match("([%w_]+)_Hit_[%w_]+_Montage$")
        if not (kind and api.moves.allowedPath(path)) then
            return
        end
        local has = puppets.deaths[kind]
        -- (Beside the flinch, or one folder up: FemaleThug_Hoe's flinches lie in Hit/Moontage and Hit/HitMontage, its
        -- deaths in Hit. The bench, run261.)
        local up = path:gsub("/[^/]+/([^/]+)$", "/%1")
        for _, sort in ipairs(DEATHS) do
            for _, from in ipairs({ path, up }) do
                if not (has and has[sort]) then
                    local death = from:gsub("_Hit_[%w_]+_Montage", "_Dead_" .. sort .. "_Montage")
                    -- (One this game has in memory already, as a kind that is here has: nothing is loaded for a guess.)
                    if valid(StaticFindObject(death)) then
                        has = has or {}
                        has[sort] = death
                    end
                end
            end
        end
        puppets.deaths[kind] = has
    end

    -- The death to show for a body in that flinch: its kind's, from the side it was hit (the other side's if this game
    -- has only that), in the air for one in the air; nil for a path that is no flinch, one of a body down already, or a
    -- kind with none.
    function puppets.deathFor(path)
        if type(path) ~= "string" then
            return nil
        end
        local kind, how = path:match("([%w_]+)_Hit_([%w_]+)_Montage$")
        local first = how and how:match("^(%a+)")
        local sort = first and ((first == "Launch" or first == "LaunchLoop") and "Launch" or (STANDING[first] and "Normal")) or nil
        if not sort then
            return nil
        end
        puppets.learnDeaths(path)
        local has = puppets.deaths[kind]
        if not has then
            return nil
        end
        local dir = how:match("_([FB])_") or how:match("_([FB])$") or "F"
        return has[sort .. "_" .. dir] or has[sort .. "_" .. (dir == "F" and "B" or "F")]
    end

    -- Seconds the kill waits at most for what this copy shows of its death, which ("execution", "death"), and the
    -- montage that is its show; 0 for nothing.
    -- moveOn: a finishing move is flagged on it (coop.lua's net.ownExec, net.partnerExec: pull request 20). With the
    -- game's own hold on the copy gone by now, nothing more is shown: no fall of its kind after the move.
    function puppets.deathShow(name, actor, moveOn)
        local ai = api.moves.animOf(actor)
        if not ai then
            return 0
        end
        local path, pos, len = nil, 0, 0
        pcall(function()
            local m = ai:GetCurrentActiveMontage()
            if m and valid(m) then
                path, pos, len = api.moves.pathOf(m), ai:Montage_GetPosition(m) or 0, m:GetPlayLength() or 0
            end
        end)
        local tag = game.hitStateOf and game.hitStateOf(actor)
        if path and type(tag) == "string" and tag:find("Executing", 1, true) then
            local left = math.min(EXEC_SHOW_S, len - pos - 0.1)
            if left > 0.2 then
                return left, "execution", path
            end
            return 0
        end
        if moveOn then
            return 0
        end
        local last = puppets.flinched[name]
        local from = (path and path:find("_Hit_", 1, true) and path)
            or (last and os.clock() - last.at < FLINCH_KEPT_S and last.path) or nil
        local death = puppets.deathFor(from)
        if not (death and api.moves.allowedPath(death) and valid(StaticFindObject(death))) then
            return 0
        end
        local m = api.moves.montage(death)
        if not m or not pcall(function() ai:Montage_Play(m, 1.0, 0, 0.0, true) end) then
            return 0
        end
        local length = 1.5
        pcall(function() length = m:GetPlayLength() end)
        return math.max(0.3, math.min(DEATH_SHOW_S, (tonumber(length) or 1.5) - 0.15)), "death", death
    end

    -- A copy through its show, looked at every few frames (net.dieLater). False: the show is over, the kill is due.
    -- An execution: over when the game no longer has the copy in it (its own state for it gone, or another montage
    -- on it): left alive past that, the copy got up again (the bench, run261: at 3.4 s of a montage of 7). A death:
    -- a flinch the game played on it at a blow of this player's meanwhile is taken off, and its fall goes on from
    -- where it would be (run260 and 261: the copy stood up out of its fall, flinching).
    function puppets.showOn(actor, what, path, elapsed)
        local ai = api.moves.animOf(actor)
        if not ai then
            return false
        end
        local now = nil
        pcall(function()
            local m = ai:GetCurrentActiveMontage()
            if m and valid(m) then
                now = api.moves.pathOf(m)
            end
        end)
        if what == "execution" then
            local tag = game.hitStateOf and game.hitStateOf(actor)
            return now == path and type(tag) == "string" and tag:find("Executing", 1, true) ~= nil
        end
        if now ~= path then
            local m = api.moves.montage(path)
            if not m then
                return false
            end
            if game.clearHitState then
                game.clearHitState(actor)
            end
            pcall(function() ai:Montage_Play(m, 1.0, 0, elapsed, true) end)
            puppets.fallsKept = (puppets.fallsKept or 0) + 1
        end
        return true
    end

    -- It died: nothing steers it through its death.
    function puppets.drop(actor)
        local p = byAddr[actor:GetAddress()]
        if p then
            unseat(p)
        end
        byAddr[actor:GetAddress()] = nil
        game.freeCopy(actor:GetAddress(), true)     -- (its target picker too: kept, the next enemy at the address used it)
    end

    function puppets.release(addr)
        local p = byAddr[addr]
        if p then
            byAddr[addr] = nil
            unseat(p)
            if not (valid(p.actor) and not game.isDead(p.actor)) then
                game.freeCopy(addr, true)           -- (dead or gone: forgotten, its picker untouched)
            end
            if valid(p.actor) and not game.isDead(p.actor) then
                pcall(function()
                    -- (One with no movement part at that moment, a boss as a scene began (the bench, 11-17): nothing to
                    -- put back. Set all the same, each field was an error line in the game's log.)
                    local cmc = p.actor.CharacterMovement
                    if not valid(cmc) then
                        return
                    end
                    cmc.bOrientRotationToMovement = true
                    if p.walkSpeed then
                        cmc.MaxWalkSpeed = p.walkSpeed      -- (else it keeps the last speed it was steered at)
                    end
                end)
                p.busyUntil = 0
                poiseFor(p)                     -- (its own boss poise again, as its own AI takes over)
                game.startAI(p.actor)
                game.freeCopy(addr, false, p.actor)
            end
        end
    end

    function puppets.releaseExcept(keep)
        for addr in pairs(byAddr) do
            if not keep[addr] then
                puppets.release(addr)
            end
        end
    end

    function puppets.releaseAll()
        for addr in pairs(byAddr) do
            puppets.release(addr)
        end
        puppets.flinched, puppets.flinchedN = {}, 0
    end

    coop.handlers.A = function(rest, from)
        -- (In a party only the host runs enemies: another guest's, passed on, played moves on every copy here.)
        if net.party and from ~= nil then
            return
        end
        local name, ability, path, pos, after = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
        pos = tonumber(pos)
        if not (name and pos and pos == pos and pos >= 0 and pos < 600) then
            return
        end
        -- (417: the last flinch the host's enemy was in, for its kind's death to show: deathShow.)
        if path:find("_Hit_", 1, true) then
            puppets.learnDeaths(path)
            if puppets.flinchedN >= FLINCHED_MAX then
                puppets.flinched, puppets.flinchedN = {}, 0
            end
            local f = puppets.flinched[name]
            if f then
                f.path, f.at = path, os.clock()
            else
                puppets.flinched[name], puppets.flinchedN = { path = path, at = os.clock() }, puppets.flinchedN + 1
            end
        end
        local actor = coop.enemyActor(name)
        local p = valid(actor) and byAddr[actor:GetAddress()]
        if not p or game.isDead(actor) then
            puppets.noCopy = puppets.noCopy + 1
            return
        end
        -- Its own reaction to this player's hit plays out first (the enemy itself is told, and does the same): a move from the
        -- other side, sent before that arrived there, cut it short, an execution too.
        local state = game.hitStateOf and game.hitStateOf(actor)
        if state ~= p.reactState then
            p.reactState, p.reactSince = state, os.clock()
        end
        if p.boss and localPlayerGrabbedBy(p, os.clock()) then
            return
        end
        local executing = (state and state:find("Executing", 1, true) ~= nil)
            or (net.ownExec and net.ownExec[name] ~= nil)
            or (net.partnerExec and net.partnerExec[name] ~= nil)
        if (state and state ~= "None" and os.clock() - p.reactSince < REACT_S) or executing then
            -- A boss's moves are the host's to say: when it flinches is decided there now (coop.lua's bossMayReact), so its
            -- copy's own flinch, a guess, gives way. (Dropped for 2.5 s after every flinch of the copy, the host's attacks never
            -- came here while both players hit it, and the guest was never hit back: Nexus reports on 1.6.6.)
            if not (game.isBoss and game.isBoss(actor)) then
                return
            end
            if game.clearHitState then
                game.clearHitState(actor)
            end
            p.reactState, p.reactSince = nil, 0
        end
        local target = p.target
        if target and not p.rides and not bossAttached(p, os.clock()) then     -- (a rider faces as its mount does: steer)
            pcall(function() actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = target.Yaw, Roll = 0.0 }, false) end)
        end
        if after ~= "-" then
            local _, pawn = api.getPlayer1()
            local me = after == (coop.isHost() and "host" or "guest")
            local aim = me and pawn or net.ghost
            if net.party then
                me = tonumber(after) == (net.slot or 1)
                aim = coop.playerBody(tonumber(after))
            end
            if valid(aim) then
                game.aimCopy(actor, actor:GetAddress(), aim)
            end
            -- (A partner's boss going for this player has them in its fight, a blow of their own landed or not. Their word of
            -- that fight is what holds the partner's respawn: with none, a host who died as the boss swung at the guest
            -- was back at once, the boss at full health again in both worlds. The bench, 11-16.)
            if me and net.partnerBosses[name] then
                net.struck[name] = true
            end
            if me then
                net.aimedAt = os.clock()        -- (something of the host's is going for this player: lesson.lua)
            end
        end
        local m = path ~= "-" and api.moves.allowedPath(path) and api.moves.montage(path)
        local left = BUSY_S
        if m then
            pcall(function() left = math.min(BUSY_MAX_S, math.max(BUSY_S, m:GetPlayLength() - pos)) end)
        end
        p.busySince = os.clock()
        p.busyUntil = p.busySince + left
        -- (Kept for a boss copy to take the move up again after a flinch of its own at this player's hit: resumeMove.)
        p.move = m and { ability = ability, path = path, start = p.busySince - pos - net.moveAge() } or nil
        local ai = m and api.moves.animOf(actor)
        if m and not ai then
            ai = anyAnimOf(actor)
        end
        p.abilityAt = nil
        if ability ~= "-" and game.playAbility(actor, ability) then
            puppets.played = puppets.played + 1
            p.abilityAt = os.clock()
            local shown = ai and ai:GetCurrentActiveMontage()
            if not ai or not valid(shown) or shown:GetAddress() == m:GetAddress() or p.boss then
                return
            end
        end
        if ai and pcall(function() ai:Montage_Play(m, 1.0, 0, pos + net.moveAge(), true) end) then
            puppets.played = puppets.played + 1
        else
            puppets.failed = puppets.failed + 1
            if not failedOnce[ability .. path] and (failedOnce.n or 0) < 200 then    -- (keyed off the wire: capped)
                failedOnce[ability .. path] = true
                failedOnce.n = (failedOnce.n or 0) + 1
                log("Enemy move not replayed: " .. ability .. " " .. path)
            end
        end
    end

    local function moving(p)
        if not valid(p.anim) then
            p.anim = api.moves.animOf(p.actor)
        end
        return p.anim ~= nil and valid(p.anim:GetCurrentActiveMontage())
    end

    -- A boss copy's own flinch at this player's hit, while the host's move goes on: that move again, where the host is in it.
    -- (When the boss reacts is the host's to say: coop.lua's bossMayReact. Flinching here at every swing, the copy dropped the
    -- host's attacks and the guest was never hit back; on the bench, 11-09, the guest alone saw it reacting 16 s of 20 while
    -- the host's boss attacked.) Its ability again, for its hits to land here, then its animation where the host's is, as
    -- the "A" handler plays it. A break stays: the copy's bar is its own. The montage found by its path each time.
    local RESUME_LOOK_S = 0.1
    -- The host's move taken up again on this copy where the host is in it: true if it was.
    local function takeUp(p, actor, clock)
        local m = api.moves.montage(p.move.path)
        local ai = m and api.moves.animOf(actor)
        local at, len = clock - p.move.start, 0
        pcall(function() len = m:GetPlayLength() end)
        if not ai or at >= len - 0.1 then
            return false
        end
        game.clearHitState(actor)
        if p.move.ability ~= "-" then
            game.playAbility(actor, p.move.ability)
        end
        if pcall(function() ai:Montage_Play(m, 1.0, 0, at, true) end) then
            puppets.resumed = (puppets.resumed or 0) + 1
            return true
        end
        return false
    end
    local function resumeMove(p, actor, addr, clock)
        if not (p.move and clock >= (p.resumeLookAt or 0)) then
            return
        end
        p.resumeLookAt = clock + RESUME_LOOK_S
        if not (game.isBoss and game.isBoss(actor, addr)) then
            return
        end
        local state = game.hitStateOf and game.hitStateOf(actor)
        if not state or state == "None" or state:find("State.Break", 1, true) then
            return              -- (a posture break's own tag: the poise levels are Hitreact.Break.LvN)
        end
        takeUp(p, actor, clock)
    end

    -- CoopBossArmor on a guest (scaling.copiesArmoured): a boss copy's own reaction to this player's hit gives way at once,
    -- its hit state gone by itself or not. In one of the host's moves to that move where the host is in it, between them
    -- to nothing, as the host's armoured boss had none. (Bench, 11-10: with super armour on the host the guest still saw
    -- its copy reacting 15% of the fight, mostly a knockback playing on after its hit state was over.) The host's own move
    -- stays, a flinch a host without super armour sends among them; so do a break, an execution and death.
    local REACTION_WORDS = { "hit", "knock", "launch", "poise", "stagger", "react" }
    local function armourCopy(p, actor, addr, clock, busy)
        if not (game.isBoss(actor, addr) or (game.bossTwin and game.bossTwin(actor, addr))) then
            return
        end
        local state = game.hitStateOf and game.hitStateOf(actor)
        if state and (state:find("Break", 1, true) and not state:find("Break.Lv", 1, true)
            or state:find("Executing", 1, true) or state:find("Dead", 1, true)) then
            return
        end
        local ai = api.moves.animOf(actor)
        local m = ai and ai:GetCurrentActiveMontage()
        if not valid(m) then
            return
        end
        local path = api.moves.pathOf(m)
        if p.move and path == p.move.path then
            return
        end
        local words = (m:GetFName():ToString() .. " " .. tostring(path)):lower()
        local reaction = false
        for _, word in ipairs(REACTION_WORDS) do
            reaction = reaction or words:find(word, 1, true) ~= nil
        end
        if not reaction then
            return
        end
        if busy and p.move and takeUp(p, actor, clock) then
            return
        end
        if state and state ~= "None" then
            game.clearHitState(actor)
        end
        pcall(function() ai:Montage_Stop(0.1, m) end)
        puppets.armoured = (puppets.armoured or 0) + 1
    end

    -- The host's enemy is carried forward along its own speed from the last update, and the copy moves at that speed
    -- plus a pull onto it, so a walking enemy glides without waiting for the next update.
    local function steer(p, now, addr)
        local actor, t = p.actor, p.target
        if net.ownExec and net.ownExec[p.name] then
            return
        end
        if net.partnerExec and net.partnerExec[p.name] then
            local x, y, z = game.where(actor, addr)
            if x ~= nil then
                local clock = os.clock()
                local dt = math.min(0.05, math.max(0.001, clock - (p.steerAt or (clock - 0.016))))
                p.steerAt = clock
                local a = 1 - math.exp(-12.0 * dt)
                pcall(function()
                    actor:K2_SetActorLocationAndRotation(
                        { X = x + (t.X - x) * a, Y = y + (t.Y - y) * a, Z = z + (t.Z - z) * a },
                        { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, false)
                end)
            end
            return
        end
        local clock = os.clock()
        local dt = math.min(0.05, math.max(0.001, clock - (p.steerAt or (clock - 0.016))))
        p.steerAt = clock
        if p.boss and localPlayerGrabbedBy(p, clock) then
            return
        end
        local attached = bossAttached(p, clock)
        local x, y, z = game.where(actor, addr)
        if x == nil then
            return
        end
        -- A rider: where it stands and how it faces is its mount's to say, a copy the host's line of the mount steers.
        -- (Jing Ye is attached to his horse. Set to the host's line of him by itself, his copy slid off the saddle,
        -- 0.3 to 2 m beside its horse at any look, and went back onto it with a jump of 3 to 6 m as each move began:
        -- the bench, 11-20, run250, ten such jumps in 100 s with none of the host's. One whose mount is no copy of
        -- the host's is steered as ever: nothing else would bring it. Asked every RIDE_LOOK_S, not every frame. 410.)
        -- (Its mount's own turn, or its pairing as a mount, comes a moment after the rider's own: till then, RIDE_WAIT_S
        -- at most, the rider is left on it, and asked again sooner. Steered meanwhile, it was off its saddle from
        -- the first frame.)
        if clock >= (p.rideLookAt or 0) then
            local mount = game.mountOf and game.mountOf(actor)
            if mount ~= p.mount then
                unseat(p)
                p.mount = mount
                if mount ~= nil then
                    puppets.ridden[mount] = p.name      -- (for coop.lua to pair that mount by this rider: 412)
                end
            end
            local held = mount ~= nil and byAddr[mount] ~= nil
            p.rideLookAt = clock + ((mount ~= nil and not held) and RIDE_SOON_S or RIDE_LOOK_S)
            p.rides = held or (mount ~= nil and clock - p.since < RIDE_WAIT_S)
        end
        local cur = { X = x, Y = y, Z = z }
        local ahead = math.min(now - t.at, AHEAD_S)
        local dx, dy, dz = t.X + t.VX * ahead - cur.X, t.Y + t.VY * ahead - cur.Y, t.Z - cur.Z
        local dist = math.sqrt(dx * dx + dy * dy)
        local snapCm = p.boss and 1200 or SNAP_CM
        if not p.rides and not attached and (dist > snapCm or math.abs(dz) > snapCm) then
            actor:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
            return
        end
        local busy = clock < p.busyUntil
        if busy and clock >= (p.moveLookAt or 0) then
            p.moveLookAt = clock + MOVE_LOOK_S
            -- Over sooner than it might have been: left waiting, the copy stood facing the old way and then snapped round.
            if clock > p.busySince + BUSY_S and not moving(p) then
                p.busyUntil = 0
                busy = false
            end
        end
        if busy then
            resumeMove(p, actor, addr, clock)
        end
        if api.scaling and api.scaling.copiesArmoured and clock >= (p.armourLookAt or 0) and api.scaling.copiesArmoured() then
            -- (A boss copy's own reaction given way, CoopBossArmor. Asked of every copy, not by p.boss, set once: a story
            -- boss is one only once its bar is up. Not every frame.)
            p.armourLookAt = clock + RESUME_LOOK_S / 2
            armourCopy(p, actor, addr, clock, busy)
        end
        if p.rides or attached then
            return
        end
        -- A jump of the host's enemy, a teleport or a dash no walk follows (coop.lua's readEnemies, 411): its copy is
        -- set where the host's line has it, now and for JUMP_HOLD_S after, whenever it is over JUMP_OFF_CM from it.
        -- The line itself, not carried forward: at a dash's speed a late line would carry the copy metres past its
        -- end. One a little ahead of the line on the jump's own way is left: a copy that plays the host's move for
        -- real makes the same dash itself, a link's delay before the host's line of it, and set back to the line each
        -- frame it would stutter the whole way (the bench, run251: a copy playing the move itself was never over
        -- 1.6 m off and there within 0.23 s; one that only followed the lines was 5.9 m off, 0.66 s).
        if t.jumpAt ~= nil and t.jumpAt ~= p.jumpSeen then
            p.jumpSeen, p.jumpUntil = t.jumpAt, now + JUMP_HOLD_S
        end
        if now < (p.jumpUntil or 0) then
            local ox, oy = cur.X - t.X, cur.Y - t.Y
            local off2 = ox * ox + oy * oy
            if off2 > JUMP_OFF_CM * JUMP_OFF_CM or math.abs(dz) > JUMP_OFF_CM then
                local along = ox * (t.jumpDX or 0) + oy * (t.jumpDY or 0)
                if not (along > 0 and along < JUMP_AHEAD_CM and off2 - along * along < JUMP_OFF_CM * JUMP_OFF_CM
                    and math.abs(dz) <= JUMP_OFF_CM) then
                    actor:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                        { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
                    puppets.jumped = (puppets.jumped or 0) + 1
                    return
                end
            end
        end
        local lockedCm = p.boss and 350 or LOCKED_CM
        local busyCm = p.boss and 60 or BUSY_CM
        if busy then
            -- (The host's boss turns to its target through an attack's wind-up; its copy kept the way it
            -- faced when the move began, and lunged off the wrong way on this screen.)
            local yaw = actor:K2_GetActorRotation().Yaw
            local turn = (t.Yaw - yaw + 180) % 360 - 180
            if math.abs(turn) > 5.0 then
                local ta = 1 - math.exp(-BUSY_TURN * dt)
                actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw + turn * ta, Roll = 0.0 }, false)
            end
        end
        if busy and dist < lockedCm then
            if dist > busyCm then
                local a = 1 - math.exp(-BUSY_PULL * dt)
                actor:K2_SetActorLocation({ X = cur.X + dx * a, Y = cur.Y + dy * a, Z = cur.Z }, false, {}, true)
            end
            return
        end
        if not busy then
            local yaw = actor:K2_GetActorRotation().Yaw
            local turn = (t.Yaw - yaw + 180) % 360 - 180
            if math.abs(turn) > 1.0 then
                local ta = 1 - math.exp(-TURN_SHARE * dt)
                actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw + turn * ta, Roll = 0.0 }, false)
            end
        end
        local vx, vy = t.VX + dx * PULL, t.VY + dy * PULL
        local speed = math.sqrt(vx * vx + vy * vy)
        if speed > STILL then
            local cmc = actor.CharacterMovement
            -- Only one thing may turn a copy: the game would turn it to where it's walking, this file to where the host's
            -- enemy looks, and the two pulling at each other every frame made it twitch. (The game's moves keep putting
            -- this back.)
            if valid(cmc) then              -- (none: see release)
                cmc.bOrientRotationToMovement = false
                cmc.MaxWalkSpeed = math.min(MAX_SPEED, speed)
            end
            actor:AddMovementInput({ X = vx / speed, Y = vy / speed, Z = 0.0 }, 1.0, false)
            if dist > NUDGE_CM then
                local na = 1 - math.exp(-NUDGE_SHARE * dt)
                actor:K2_SetActorLocation({ X = cur.X + dx * na, Y = cur.Y + dy * na,
                    Z = cur.Z + dz * na }, false, {}, true)
            end
        end
    end

    coop.frameTicks.puppets = function()
        local now = api.link.now()
        for addr, p in pairs(byAddr) do
            if not valid(p.actor) or game.isDead(p.actor) then
                unseat(p)
                byAddr[addr] = nil
                game.freeCopy(addr, true)
            else
                if now >= p.aiAt then
                    p.aiAt = now + AI_EVERY_S
                    p.brain = game.stopAI(p.actor, p.brain)
                    poiseFor(p)
                end
                if p.target then
                    steer(p, now, addr)
                end
            end
        end
    end

    function puppets.command()
        local n = 0
        for _ in pairs(byAddr) do
            n = n + 1
        end
        log(string.format("Puppets: %d following %s, attacks sent %d, played %d, failed %d, no copy here %d",
            n, coop.isHost() and "the guest's game" or "the host", puppets.attacks, puppets.played, puppets.failed, puppets.noCopy))
    end

    -- Someone started sync anew: the moves under way are news to them, so the next look sends them again.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(...)
        hostSeen = {}
        return syncStarted(...)
    end

    return puppets
end
