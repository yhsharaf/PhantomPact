-- The host's enemies, played on the guest's copies. Left to their own AI, each game fought its own enemies and only
-- their positions and health were pulled together, so two players never saw the same fight.
--
-- A copy the host lists has its AI stopped and follows the host's position here. Whatever the host's enemy starts
-- goes as "A <enemy> <ability class|-> <montage path|-> <position>". An ability replays for real, so its hits land
-- on the guest and guard, parry and dodge work as usual; a montage alone (hit reactions) deals no damage. Montages
-- the game builds at run time (turns) have no path to send and are left out.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local SNAP_CM = 1000          -- further than this the copy jumps there
    local STOP_CM = 40            -- closer than this it stands
    local NUDGE_CM = 120          -- further than this it's also moved directly, in case walking can't keep up
    local NUDGE_SHARE = 0.08      -- of the gap, per tick
    local LOCKED_CM = 250         -- a move's own motion plays out unless the copy is this far off
    local MIN_SPEED, MAX_SPEED = 100, 900   -- cm/s
    local SPEED_PER_CM = 3.0
    local TURN_SHARE = 0.25       -- of the angle, per tick
    local BUSY_S = 0.8            -- after an attack starts, leave the copy's facing to the move
    local RESTART_S = 0.05        -- the same montage at an earlier position = played again
    local PASSIVE = { "Passive", "Locomotion", "SpaceState", "Stance", "Utilities" }

    local puppets = { attacks = 0, played = 0, failed = 0 }
    local byAddr = {}             -- guest: actor address -> { actor, name, target, busyUntil }
    local hostSeen = {}           -- host: enemy name -> { addr, pos } of the montage last sent

    local function passive(name)
        for _, word in ipairs(PASSIVE) do
            if name:find(word, 1, true) then
                return true
            end
        end
        return false
    end

    -- Host, once a snapshot for every living enemy it shares.
    function puppets.watchHost(name, actor)
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
        local addr = m:GetAddress()
        local pos = ai:Montage_GetPosition(m) or 0
        if s == nil or addr ~= s.addr or pos < s.pos - RESTART_S then
            local ability = game.activeAbility(actor, passive)
            local path = api.moves.pathOf(m)
            path = api.moves.allowedPath(path) and path or nil
            if ability or path then
                coop.sendEvent("A", name, ability or "-", path or "-", string.format("%.2f", pos))
                puppets.attacks = puppets.attacks + 1
            end
        end
        hostSeen[name] = { addr = addr, pos = pos }
    end

    -- Guest, for every copy of a host enemy, each snapshot.
    function puppets.follow(name, actor, target)
        local addr = actor:GetAddress()
        local p = byAddr[addr]
        if p == nil then
            p = { actor = actor, name = name, busyUntil = 0 }
            byAddr[addr] = p
            game.stopAI(actor)
        end
        p.target = target
    end

    function puppets.release(addr)
        local p = byAddr[addr]
        if p then
            byAddr[addr] = nil
            if valid(p.actor) and not game.isDead(p.actor) then
                game.startAI(p.actor)
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

    coop.handlers.A = function(rest)
        local name, ability, path, pos = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
        pos = tonumber(pos)
        if not (name and pos and pos == pos and pos >= 0 and pos < 600) then
            return
        end
        local actor = coop.enemyActor(name)
        local p = valid(actor) and byAddr[actor:GetAddress()]
        if not p or game.isDead(actor) then
            return
        end
        local target = p.target
        if target then
            pcall(function() actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = target.Yaw, Roll = 0.0 }, false) end)
        end
        p.busyUntil = os.clock() + BUSY_S
        if ability ~= "-" and game.playAbility(actor, ability) then
            puppets.played = puppets.played + 1
            return
        end
        local m = path ~= "-" and api.moves.allowedPath(path) and api.moves.montage(path)
        local ai = m and api.moves.animOf(actor)
        if ai and pcall(function() ai:Montage_Play(m, 1.0, 0, pos + (net.rttMs or 0) / 2000, true) end) then
            puppets.played = puppets.played + 1
        else
            puppets.failed = puppets.failed + 1
        end
    end

    local function steer(p)
        local actor, t = p.actor, p.target
        local cur = actor:K2_GetActorLocation()
        local dx, dy, dz = t.X - cur.X, t.Y - cur.Y, t.Z - cur.Z
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist > SNAP_CM or math.abs(dz) > SNAP_CM then
            actor:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
            return
        end
        local busy = os.clock() < p.busyUntil
        if busy and dist < LOCKED_CM then
            return
        end
        if not busy then
            local yaw = actor:K2_GetActorRotation().Yaw
            local turn = (t.Yaw - yaw + 180) % 360 - 180
            if math.abs(turn) > 2 then
                actor:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw + turn * TURN_SHARE, Roll = 0.0 }, false)
            end
        end
        if dist > STOP_CM then
            local cmc = actor.CharacterMovement
            cmc.MaxWalkSpeed = math.max(MIN_SPEED, math.min(MAX_SPEED, dist * SPEED_PER_CM))
            actor:AddMovementInput({ X = dx / dist, Y = dy / dist, Z = 0.0 }, 1.0, false)
            if dist > NUDGE_CM then
                actor:K2_SetActorLocation({ X = cur.X + dx * NUDGE_SHARE, Y = cur.Y + dy * NUDGE_SHARE,
                    Z = cur.Z + dz * NUDGE_SHARE }, false, {}, true)
            end
        end
    end

    coop.extraTicks.puppets = function()
        for addr, p in pairs(byAddr) do
            if not valid(p.actor) or game.isDead(p.actor) then
                byAddr[addr] = nil
            elseif p.target then
                steer(p)
            end
        end
    end

    function puppets.command()
        local n = 0
        for _ in pairs(byAddr) do
            n = n + 1
        end
        log(string.format("Puppets: %d following the host, attacks sent %d, played %d, failed %d",
            n, puppets.attacks, puppets.played, puppets.failed))
    end

    return puppets
end
