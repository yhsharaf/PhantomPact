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

    local SNAP_CM = 1000          -- further than this the copy jumps there
    local NUDGE_CM = 120          -- further than this it's also moved directly, in case walking can't keep up
    local NUDGE_SHARE = 0.08      -- of the gap, per frame
    local LOCKED_CM = 250         -- a move's own motion plays out unless the copy is this far off
    local BUSY_CM = 40            -- during one, further than this it's pulled gently
    local BUSY_PULL = 0.08        -- share of the gap, per frame
    local PULL = 4.0              -- per second: speed added per cm off the host's position
    local STILL = 30              -- cm/s; asked to move slower than this, it stands
    local MAX_SPEED = 1400        -- cm/s
    local AHEAD_S = 0.2           -- the host's position is carried forward at its speed, but not further than this
    local TURN_SHARE = 0.25       -- of the angle, per turn
    local TURN_EVERY_S = 0.05
    local BUSY_S = 0.8            -- after an attack starts, leave the copy's facing to the move
    local BUSY_MAX_S = 4.0        -- ... for as long as the move lasts, up to this
    local MOVE_LOOK_S = 0.1
    local RESTART_S = 0.05        -- the same montage at an earlier position = played again
    local AI_EVERY_S = 0.1        -- how often each copy's AI is stopped again: the game restarts it by itself
    local REACT_S = 2.5           -- a copy's own reaction to this player's hit plays out this long at most, before any move
    -- Abilities that stay on and aren't moves. (Bosses keep a "Subtitles" one up for their lines: taken for the move, the
    -- real attack was never replayed and only its animation reached the guest, which hurts no one.)
    local PASSIVE = { "Passive", "Locomotion", "SpaceState", "Stance", "Utilities", "HitMirror", "Subtitles" }

    local puppets = { attacks = 0, played = 0, failed = 0, noCopy = 0 }
    local byAddr = {}             -- guest: actor address -> { actor, name, target, busyUntil }
    local hostSeen = {}           -- host: enemy name -> { addr, pos } of the montage last sent
    local failedOnce = {}         -- guest: moves already logged as not replayed

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
        -- (Asked each time: kept by address, the list only grew, and a new enemy on a used address could be read through
        -- the old one's animation while that lingered.)
        local ai = api.moves.animOf(actor)
        if not ai then
            return
        end
        local m = ai:GetCurrentActiveMontage()
        local s = hostSeen[name]
        if not valid(m) then
            hostSeen[name] = nil
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
            end
        end
        hostSeen[name] = { addr = addr, pos = pos }
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
            p = nil
        end
        if p == nil then
            p = { actor = actor, name = name, fname = fname, busyUntil = 0, aiAt = 0 }
            pcall(function() p.walkSpeed = actor.CharacterMovement.MaxWalkSpeed end)
            byAddr[addr] = p
        end
        p.target = target
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
        return path, pos, tag
    end

    -- Whoever runs the enemy: the reaction the partner's copy played to their hit, on the enemy itself, from where theirs was.
    -- Not sent back to them as a move of its own: their copy plays it already.
    function puppets.react(name, actor, path, pos, tag)
        local m = path ~= "-" and api.moves.allowedPath(path) and api.moves.montage(path)
        local ai = m and api.moves.animOf(actor)
        local hold = 0.9
        if ai and pcall(function() ai:Montage_Play(m, 1.0, 0, pos + (net.rttMs or 0) / 2000, true) end) then
            pcall(function() hold = math.max(0.3, math.min(REACT_S, m:GetPlayLength() - pos)) end)
            hostSeen[name] = { addr = m:GetAddress(), pos = pos }
        end
        if tag ~= "-" and game.setHitState then
            game.setHitState(actor, tag, hold)
        end
    end

    -- It died: nothing steers it through its death.
    function puppets.drop(actor)
        byAddr[actor:GetAddress()] = nil
        game.freeCopy(actor:GetAddress(), true)     -- (its target picker too: kept, the next enemy at the address used it)
    end

    function puppets.release(addr)
        local p = byAddr[addr]
        if p then
            byAddr[addr] = nil
            if not (valid(p.actor) and not game.isDead(p.actor)) then
                game.freeCopy(addr, true)           -- (dead or gone: forgotten, its picker untouched)
            end
            if valid(p.actor) and not game.isDead(p.actor) then
                pcall(function()
                    local cmc = p.actor.CharacterMovement
                    cmc.bOrientRotationToMovement = true
                    if p.walkSpeed then
                        cmc.MaxWalkSpeed = p.walkSpeed      -- (else it keeps the last speed it was steered at)
                    end
                end)
                game.startAI(p.actor)
                game.freeCopy(addr)
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
        if state and state ~= "None" and os.clock() - p.reactSince < REACT_S then
            return
        end
        local target = p.target
        if target then
            pcall(function() actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = target.Yaw, Roll = 0.0 }, false) end)
        end
        if after ~= "-" then
            local _, pawn = api.getPlayer1()
            local aim = after == (coop.isHost() and "host" or "guest") and pawn or net.ghost
            if net.party then
                aim = coop.playerBody(tonumber(after))
            end
            if valid(aim) then
                game.aimCopy(actor, actor:GetAddress(), aim)
            end
        end
        local m = path ~= "-" and api.moves.allowedPath(path) and api.moves.montage(path)
        local left = BUSY_S
        if m then
            pcall(function() left = math.min(BUSY_MAX_S, math.max(BUSY_S, m:GetPlayLength() - pos)) end)
        end
        p.busySince = os.clock()
        p.busyUntil = p.busySince + left
        local ai = m and api.moves.animOf(actor)
        if ability ~= "-" and game.playAbility(actor, ability) then
            puppets.played = puppets.played + 1
            -- A move of several steps starts from its first, and the host's may be further on: what's seen is the host's.
            local shown = ai and ai:GetCurrentActiveMontage()
            if not ai or (valid(shown) and shown:GetAddress() == m:GetAddress()) then
                return
            end
        end
        if ai and pcall(function() ai:Montage_Play(m, 1.0, 0, pos + (net.rttMs or 0) / 2000, true) end) then
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

    -- The host's enemy is carried forward along its own speed from the last update, and the copy moves at that speed
    -- plus a pull onto it, so a walking enemy glides without waiting for the next update.
    local function steer(p, now, addr)
        local actor, t = p.actor, p.target
        local x, y, z = game.where(actor, addr)
        if x == nil then
            return
        end
        local cur = { X = x, Y = y, Z = z }
        local ahead = math.min(now - t.at, AHEAD_S)
        local dx, dy, dz = t.X + t.VX * ahead - cur.X, t.Y + t.VY * ahead - cur.Y, t.Z - cur.Z
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist > SNAP_CM or math.abs(dz) > SNAP_CM then
            actor:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
            return
        end
        local clock = os.clock()
        local busy = clock < p.busyUntil
        if busy and clock >= (p.moveLookAt or 0) then
            p.moveLookAt = clock + MOVE_LOOK_S
            -- Over sooner than it might have been: left waiting, the copy stood facing the old way and then snapped round.
            if clock > p.busySince + BUSY_S and not moving(p) then
                p.busyUntil = 0
                busy = false
            end
        end
        if busy and dist < LOCKED_CM then
            if dist > BUSY_CM then
                actor:K2_SetActorLocation({ X = cur.X + dx * BUSY_PULL, Y = cur.Y + dy * BUSY_PULL, Z = cur.Z }, false, {}, true)
            end
            return
        end
        if not busy and now >= (p.turnAt or 0) then
            p.turnAt = now + TURN_EVERY_S
            local yaw = actor:K2_GetActorRotation().Yaw
            local turn = (t.Yaw - yaw + 180) % 360 - 180
            if math.abs(turn) > 2 then
                actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw + turn * TURN_SHARE, Roll = 0.0 }, false)
            end
        end
        local vx, vy = t.VX + dx * PULL, t.VY + dy * PULL
        local speed = math.sqrt(vx * vx + vy * vy)
        if speed > STILL then
            local cmc = actor.CharacterMovement
            -- Only one thing may turn a copy: the game would turn it to where it's walking, this file to where the host's
            -- enemy looks, and the two pulling at each other every frame made it twitch. (The game's moves keep putting
            -- this back.)
            cmc.bOrientRotationToMovement = false
            cmc.MaxWalkSpeed = math.min(MAX_SPEED, speed)
            actor:AddMovementInput({ X = vx / speed, Y = vy / speed, Z = 0.0 }, 1.0, false)
            if dist > NUDGE_CM then
                actor:K2_SetActorLocation({ X = cur.X + dx * NUDGE_SHARE, Y = cur.Y + dy * NUDGE_SHARE,
                    Z = cur.Z + dz * NUDGE_SHARE }, false, {}, true)
            end
        end
    end

    coop.frameTicks.puppets = function()
        local now = api.link.now()
        for addr, p in pairs(byAddr) do
            if not valid(p.actor) then
                byAddr[addr] = nil
                game.freeCopy(addr, true)
            else
                if now >= p.aiAt then
                    p.aiAt = now + AI_EVERY_S
                    p.brain = game.stopAI(p.actor, p.brain)
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
