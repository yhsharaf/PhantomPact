-- What a player's weapons leave in the world, on everyone else's PC: a Scarlet Wraithblade's flowers on the floor, a cannon's
-- shell, a thrown blade. Those are the game's bullets, not animation: an ability starts them, and a ghost runs no abilities, so
-- the partner saw the swing and nothing else.
--
-- The game keeps every live bullet in one list, which is read here a few times a second, with no hook on anything. A new one of
-- this player's goes out as "SHOT <bullet data> <x> <y> <z> <pitch> <yaw> <roll>", and the ghost fires the same data from the same
-- spot through the game's own spawner. So it's the same bullet, with its look, sound and end. Its owner is the ghost, whose Attack
-- is 0, and the sender's own bullet did whatever hit counts.
--
-- Left out: the sweeps every swing makes (objects with no body, seen by nobody), a bullet another bullet started (that one
-- starts it on this PC too), and PvP, where the ghost's abilities run for real.
--
-- Checked here, as in moves.lua: only players' bullet data is accepted, the loaded object must really be bullet data, and new
-- loads are capped per minute with the shots themselves capped per second, so a partner can't make this game load or fire anything else.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local WATCH_S = 0.1             -- how often the list of live bullets is read
    local ROOT = "^/PBZCombatAsset/ActorData/Players/"
    local MAX_PER_S = 40
    local MAX_COORD = 1e7

    local COPY_MAX_S = 30           -- a ghost's bullet still there this long after it was fired ends (if its end never came)

    local bullets = { sent = 0, shown = 0, refused = 0, ended = 0 }
    local known = {}                -- bullet address -> true: seen already, this player's or anyone else's
    local watchAt = 0
    local cache = {}                -- bullet data path -> its address once checked, or false when it isn't bullet data
    local retryAt = {}              -- bullet data path -> os.clock() before which a path not found isn't looked up again
    local shots, shotsAt = 0, 0
    -- A bullet's end goes out too. Some only end when the ability that fired them says so (a lion head's fire loop), and a ghost
    -- runs none: its copies looped on, one more each time, where the sender's own had long gone.
    local sentIds, nextId = {}, 0   -- this player's: bullet address -> the id it went out with
    local copies = {}               -- the ghost's: "<player>:<id>" -> { at, made = what game.fireBullet made }
    local copiesAt = 0

    local function send(b)
        local path = api.moves.pathOf(b.BulletData)
        if not (path:match(ROOT) and api.moves.allowedPath(path)) then
            return
        end
        local at, r = b:K2_GetActorLocation(), b:K2_GetActorRotation()
        nextId = nextId % 1000000 + 1
        coop.sendEvent("SHOT", path, string.format("%.0f %.0f %.0f %.1f %.1f %.1f %d", at.X, at.Y, at.Z, r.Pitch, r.Yaw, r.Roll,
            nextId))
        sentIds[b:GetAddress()] = nextId
        bullets.sent = bullets.sent + 1
    end

    -- This player's bullets that have gone since the last look: their copies end too.
    local function sendEnds(seen)
        for addr, id in pairs(sentIds) do
            if not seen[addr] then
                sentIds[addr] = nil
                coop.sendEvent("SHOTEND", id)
            end
        end
    end

    local function endCopy(key)
        local c = copies[key]
        copies[key] = nil
        for _, made in ipairs(c and c.made or {}) do
            if game.endBullet(made) then
                bullets.ended = bullets.ended + 1
            end
        end
    end

    local function watch(now)
        if now < watchAt or net.pvp then
            return
        end
        watchAt = now + WATCH_S
        local pawn = coop.localPawn()
        local system = pawn and game.bulletSystem(pawn)
        if not system then
            return
        end
        if system:GetBulletCount() == 0 then
            known = {}
            sendEnds(known)
            return
        end
        local mine, seen = pawn:GetAddress(), {}
        system.Bullets:ForEach(function(_, v)
            local b = v:get()
            local addr = b:GetAddress()
            seen[addr] = true
            if not known[addr] and game.isShot(b, mine) then
                send(b)
            end
        end)
        known = seen
        sendEnds(seen)
    end

    -- Looked up each time, as a montage is (moves.lua).
    local function bulletData(path)
        if cache[path] == false then
            return nil
        end
        -- (One not found is tried again after a while, as moves.montage does: not found only meant still loading, mid-trip,
        -- and that bullet was never shown again all session.)
        if retryAt[path] and os.clock() < retryAt[path] then
            return nil
        end
        local d = StaticFindObject(path)
        if not valid(d) and type(LoadAsset) == "function" then
            if not api.moves.countLoad() then
                return nil
            end
            pcall(LoadAsset, path)
            d = StaticFindObject(path)
        end
        if valid(d) and (cache[path] == d:GetAddress() or game.isBulletData(d)) then
            cache[path], retryAt[path] = d:GetAddress(), nil
            return d
        end
        if valid(d) then
            cache[path] = false             -- (there, and no bullet: never one)
        else
            retryAt[path] = os.clock() + 10
        end
        return nil
    end

    coop.handlers.SHOT = function(rest, from)
        local path, x, y, z, pitch, yaw, roll, id = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)%s*(%d*)$")
        x, y, z, pitch, yaw, roll = tonumber(x), tonumber(y), tonumber(z), tonumber(pitch), tonumber(yaw), tonumber(roll)
        -- (The angles too: "1e999" read as infinity, and a rotation of that went into the game's own spawn as NaN.)
        if not (path and path:match(ROOT) and api.moves.allowedPath(path) and x and y and z and pitch and yaw and roll
            and math.abs(x) < MAX_COORD and math.abs(y) < MAX_COORD and math.abs(z) < MAX_COORD
            and math.abs(pitch) <= 720 and math.abs(yaw) <= 720 and math.abs(roll) <= 720) then
            bullets.refused = bullets.refused + 1
            return
        end
        local p = coop.peerOf(from)
        if net.pvp or not valid(p.ghost) or p.ghostHidden or not api.moves.settled(p) then
            return
        end
        -- (A cap for each player: one counter for a whole party let one player's flowers or cannon use it all up.)
        local now = os.clock()
        if now - (p.shotsAt or 0) >= 1 then
            p.shots, p.shotsAt = 0, now
        end
        if (p.shots or 0) >= MAX_PER_S then
            return
        end
        p.shots = (p.shots or 0) + 1
        local d = bulletData(path)
        local ok, made = false, nil
        if d then
            ok, made = game.fireBullet(p.ghost, d, x, y, z, pitch, yaw, roll)
        end
        if ok then
            bullets.shown = bullets.shown + 1
            if id ~= "" and made and #made > 0 then
                local key = (from or 1) .. ":" .. id
                if copies[key] then
                    endCopy(key)        -- (an id used again, the sender started over: the old copy put out of the list looped on)
                end
                copies[key] = { at = now, made = made }
            end
        end
    end

    coop.handlers.SHOTEND = function(rest, from)
        local id = (rest or ""):match("^(%d+)$")
        if id then
            endCopy((from or 1) .. ":" .. id)
        end
    end

    -- Copies whose end never came (the sender left, say): over after COPY_MAX_S.
    local function ageCopies(now)
        if now < copiesAt then
            return
        end
        copiesAt = now + 1
        for key, c in pairs(copies) do
            if now - c.at > COPY_MAX_S then
                endCopy(key)
            end
        end
    end

    coop.extraTicks.bullets = function()
        local now = os.clock()
        local ok, err = pcall(watch, now)
        if ok then
            ok, err = pcall(ageCopies, now)
        end
        if not ok and err ~= bullets.lastError then
            bullets.lastError = err
            log("bullets: " .. tostring(err))
        end
    end

    -- Sync off: every copy ends now (coop.lua's stop), as the ticks that end them stop with it. A copied fire loop burned on.
    function bullets.endAll()
        for key in pairs(copies) do
            endCopy(key)
        end
        sentIds = {}
    end

    -- bullets: counters
    function bullets.command()
        log(string.format("Bullets: sent %d, shown from the ghost %d, refused %d, ghost's ended with their sender's %d",
            bullets.sent, bullets.shown, bullets.refused, bullets.ended))
    end

    return bullets
end
