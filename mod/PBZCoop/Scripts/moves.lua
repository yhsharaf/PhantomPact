-- The partner's moves on their ghost, as animation montages. (From appdoze's PR #5.)
--
-- Whatever montage your character plays (attacks, guard stance, deflects, executions, weapon and Phantom Edge
-- skills, item use, ladders and wall runs...) is sent as "U <montage path> <position>", and the partner's ghost plays
-- the same montage from that point (plus half the ping) with its AnimInstance's own Montage_Play. "U - 0" says it ended.
--
-- Montages show what replaying abilities (M events) couldn't: a ghost often can't activate an ability (guard
-- stance, executions, some weapon skills). PvP keeps abilities: there the ghost's swings must land real hits.
--
-- Checked here (review of PR #5): only montage folders are accepted, the loaded object must really be an
-- AnimMontage, and new loads are capped per minute, so a partner can't make this game load any asset; the ghost
-- isn't steered while a montage plays (game.noteGhostMove), as for ability replays.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local PATH = "^/[%w_/%-]+%.[%w_%-]+$"
    local ALLOWED_ROOTS = { "^/PBZCombatAsset/", "^/Game/", "^/HuaShira/" }
    local MAX_NEW_LOADS_PER_MIN = 30
    local RESTART_S = 0.05          -- the same montage at an earlier position = played again
    local STOP_BLEND_S = 0.25       -- the ghost leaves a montage the partner has left over this long

    local moves = { sent = 0, played = 0, failed = 0, refused = 0, partnerSends = false }
    local last, lastPos = nil, 0
    local cache = {}                -- montage path -> its address once checked, or false when it can't be loaded here
    local loads, loadsWindow = 0, os.clock()

    local function animOf(actor)
        local ai
        pcall(function() ai = actor.Mesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    local function pathOf(m)
        return (m:GetFullName():gsub("^%S+ ", ""))
    end

    local function allowedPath(path)
        if not (path and #path <= 256 and path:match(PATH)) then
            return false
        end
        for _, root in ipairs(ALLOWED_ROOTS) do
            if path:match(root) then
                return true
            end
        end
        return false
    end

    local function isMontage(obj)
        local ok, yes = pcall(function()
            return obj:IsA(StaticFindObject("/Script/Engine.AnimMontage"))
        end)
        return ok and yes == true
    end

    moves.animOf, moves.pathOf, moves.allowedPath = animOf, pathOf, allowedPath

    local ANIM_CHECK_S = 1.0
    local watchedBody, watchedAi, animCheckAt = nil, nil, 0

    -- Sender, every tick: a new montage, or the same one started again, goes to the partner.
    local function watch()
        local pawn = coop.localPawn()
        if pawn == nil then
            return
        end
        -- Asked for again now and then: it's three calls more each time, and a tick of this comes every other frame.
        local now = os.clock()
        if pawn ~= watchedBody or now >= animCheckAt or not valid(watchedAi) then
            watchedBody, watchedAi, animCheckAt = pawn, animOf(pawn), now + ANIM_CHECK_S
        end
        local ai = watchedAi
        if not ai then
            return
        end
        local m = ai:GetCurrentActiveMontage()
        if not valid(m) then
            if last then
                coop.sendEvent("U", "-", "0")     -- over or cut short: the ghost's copy mustn't play on (some loop)
            end
            last = nil
            return
        end
        local addr = m:GetAddress()
        local pos = ai:Montage_GetPosition(m) or 0
        if addr ~= last or pos < lastPos - RESTART_S then
            local path = pathOf(m)
            if game.noteLocalMove then
                game.noteLocalMove()
            end
            if api.revive then
                api.revive.onLocalMontage(m:GetFName():ToString())
            end
            if allowedPath(path) then
                coop.sendEvent("U", path, string.format("%.2f", pos))
                moves.sent = moves.sent + 1
            end
        end
        last, lastPos = addr, pos
    end

    -- Capped, so a flood of different paths can't stall the game with loads.
    local function countLoad()
        local now = os.clock()
        if now - loadsWindow >= 60 then
            loads, loadsWindow = 0, now
        end
        if loads >= MAX_NEW_LOADS_PER_MIN then
            return false
        end
        loads = loads + 1
        return true
    end

    -- Looked up each time, not kept: a kept object can go with a map, and its address can then be something else entirely, which
    -- valid() can't tell.
    local function montage(path)
        if cache[path] == false then
            return nil
        end
        local m = StaticFindObject(path)
        if not valid(m) and type(LoadAsset) == "function" then
            -- Moves of a weapon the local player doesn't carry aren't in memory yet.
            if not countLoad() then
                return nil
            end
            pcall(LoadAsset, path)
            m = StaticFindObject(path)
        end
        if valid(m) and (cache[path] == m:GetAddress() or isMontage(m)) then
            cache[path] = m:GetAddress()
            return m
        end
        cache[path] = false
        return nil
    end

    moves.montage = montage
    moves.countLoad = countLoad

    coop.handlers.U = function(rest, from)
        local p = coop.peerOf(from)
        local path, pos = (rest or ""):match("^(%S+)%s+(%S+)$")
        pos = tonumber(pos)
        if path == "-" then
            if not net.pvp and valid(p.ghostMontage) and valid(p.ghost) then
                local ai = animOf(p.ghost)
                if ai then
                    pcall(function() ai:Montage_Stop(STOP_BLEND_S, p.ghostMontage) end)
                end
            end
            return
        end
        if not (allowedPath(path) and pos and pos == pos and pos >= 0 and pos < 600) then
            moves.refused = moves.refused + 1
            return
        end
        moves.partnerSends = true
        if net.pvp or not valid(p.ghost) or p.ghostHidden then
            return
        end
        local m = montage(path)
        local ai = animOf(p.ghost)
        if not (m and ai) then
            moves.failed = moves.failed + 1
            return
        end
        local start = pos + (net.rttMs or 0) / 2000
        local ok = pcall(function() ai:Montage_Play(m, 1.0, 0, start, true) end)
        if ok then
            moves.played = moves.played + 1
            p.ghostMontage = m
            if game.noteGhostMove then
                game.noteGhostMove(p.ghost)
            end
        else
            moves.failed = moves.failed + 1
        end
    end

    ------------------------------------------------------------------ what the partner holds

    -- Attacks came out empty-handed: the abilities that draw the blade don't run on a ghost, and its gear is this PC's
    -- backpack, not the partner's. So the sender says what it holds and whether it's drawn ("W <weapon config> <0|1>"),
    -- and the ghost's own weapons component is brought to that (and kept there: the ghost's blueprint follows this PC's
    -- backpack, and a new ghost starts from it).
    --
    -- A Phantom Edge weapon is the same with a slot of its own, drawn for its skill alone ("E <weapon config> <0|1>"). Set on the
    -- ghost's component, it hangs where the partner's does. It has moves of its own too: a cannon's mesh is folded away to nothing
    -- until it plays the montage that opens it, so what that mesh plays goes as well ("Z <montage> <position>").
    local GEAR_WATCH_S = 0.1        -- how often the sender checks that the blade is drawn
    local GEAR_PATH_S = 0.5         -- and which weapon it is
    local GEAR_DRESS_S = 0.25       -- how often the ghost is checked against the partner
    local GEAR_SWAP_S = 5.0         -- a weapon change that didn't take isn't tried again sooner
    local GEAR_SETTLE_S = 6.0       -- a new ghost is left alone this long
    local gear = { watchAt = 0, pathAt = 0, edgePathAt = 0 }
    local SHACHI = "Weapon.Slot.Shachi"

    -- What one other player holds, kept with them.
    local function gearOf(p)
        p.gear = p.gear or { dressAt = 0, swapAt = 0 }
        return p.gear
    end

    local function mainSlot()
        gear.slot = gear.slot or { TagName = FName("Weapon.Slot.Main") }
        return gear.slot
    end

    local function edgeSlot()
        gear.edge = gear.edge or { TagName = FName(SHACHI) }
        return gear.edge
    end

    local function heldConfig(cwc, slot)
        local data = {}
        cwc:GetCurrentWeapon(slot or mainSlot(), data, false, {})
        return valid(data.WeaponConfig) and pathOf(data.WeaponConfig) or nil
    end

    -- The actor hanging on a body for its Phantom Edge weapon. It's the component's to spawn and take away, so it's looked for.
    local function edgeActor(body)
        local list = {}
        body:GetAttachedActors(list, true, true)
        for i = 1, #list do
            local a = list[i]:get()
            local ok, tag = pcall(function() return a.Slot.TagName:ToString() end)
            if ok and tag == SHACHI then
                return a
            end
        end
        return nil
    end

    local function edgeAnim(body)
        local ai
        pcall(function() ai = edgeActor(body).WeaponMesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    local function isWeaponConfig(obj)
        local ok, yes = pcall(function()
            return obj:IsA(StaticFindObject("/Script/PBZCombatAsset.PBZ_WeaponConfigBase"))
        end)
        return ok and yes == true
    end

    local function watchGear(now)
        if now < gear.watchAt then
            return
        end
        gear.watchAt = now + GEAR_WATCH_S
        local pawn = coop.localPawn()
        if pawn == nil then
            return
        end
        local cwc = pawn["Character Weapons Component"]
        local armed = cwc:IsArmed(mainSlot()) == true
        if now >= gear.pathAt then
            gear.pathAt = now + GEAR_PATH_S
            gear.path = heldConfig(cwc) or gear.path
        end
        if gear.path and (armed ~= gear.sentArmed or gear.path ~= gear.sentPath) then
            gear.sentArmed, gear.sentPath = armed, gear.path
            coop.sendEvent("W", gear.path, armed and 1 or 0)
        end
        armed = cwc:IsArmed(edgeSlot()) == true
        if now >= gear.edgePathAt then
            gear.edgePathAt = now + GEAR_PATH_S
            gear.edgePath = heldConfig(cwc, edgeSlot())
        end
        if gear.edgePath and (armed ~= gear.sentEdgeArmed or gear.edgePath ~= gear.sentEdgePath) then
            gear.sentEdgeArmed, gear.sentEdgePath = armed, gear.edgePath
            coop.sendEvent("E", gear.edgePath, armed and 1 or 0)
        end
        if armed then
            local ai = gear.edgeAnim
            if not (valid(ai) and gear.edgeAnimOf == gear.edgePath) then
                ai = edgeAnim(pawn)
                gear.edgeAnim, gear.edgeAnimOf = ai, gear.edgePath
            end
            local m = ai and ai:GetCurrentActiveMontage()
            if valid(m) then
                local addr, pos = m:GetAddress(), ai:Montage_GetPosition(m) or 0
                if addr ~= gear.edgeMontage or pos < gear.edgePos - RESTART_S then
                    coop.sendEvent("Z", pathOf(m), string.format("%.2f", pos))
                end
                gear.edgeMontage, gear.edgePos = addr, pos
            end
        end
    end

    coop.handlers.W = function(rest, from)
        local path, armed = (rest or ""):match("^(%S+)%s+([01])$")
        if not allowedPath(path) then
            moves.refused = moves.refused + 1
            return
        end
        local theirs = gearOf(coop.peerOf(from))
        if path ~= theirs.partnerPath then
            theirs.swapAt = 0
        end
        theirs.partnerPath, theirs.partnerArmed = path, armed == "1"
        theirs.dressAt = 0
    end

    coop.handlers.E = function(rest, from)
        local path, armed = (rest or ""):match("^(%S+)%s+([01])$")
        if not allowedPath(path) then
            moves.refused = moves.refused + 1
            return
        end
        local theirs = gearOf(coop.peerOf(from))
        if path ~= theirs.edgePath then
            theirs.edgeSwapAt = 0
        end
        theirs.edgePath, theirs.edgeArmed = path, armed == "1"
        theirs.dressAt = 0
    end

    coop.handlers.Z = function(rest, from)
        local path, pos = (rest or ""):match("^(%S+)%s+(%S+)$")
        pos = tonumber(pos)
        if not (allowedPath(path) and pos and pos == pos and pos >= 0 and pos < 600) then
            moves.refused = moves.refused + 1
            return
        end
        local p = coop.peerOf(from)
        if net.pvp or not valid(p.ghost) or p.ghostHidden or not moves.settled(p) then
            return
        end
        local m, ai = montage(path), edgeAnim(p.ghost)
        if m and ai then
            pcall(function() ai:Montage_Play(m, 1.0, 0, pos + (net.rttMs or 0) / 2000, true) end)
        end
    end

    -- Weapon configs load like montages: same paths, same cap. Not an AnimMontage, so not through the same cache, and looked up each
    -- time for the same reason: a swap is rare.
    local function weaponConfig(path)
        local cfg = StaticFindObject(path)
        if not valid(cfg) and type(LoadAsset) == "function" and countLoad() then
            pcall(LoadAsset, path)
            cfg = StaticFindObject(path)
        end
        return valid(cfg) and isWeaponConfig(cfg) and cfg or nil
    end

    -- A new ghost, on a map that's most often only just there. A weapon's passive skill starts the moment it's given, and with its
    -- classes still loading after the trip it has no code yet: that was a crash on arrival with a Scarlet Wraithblade. So nothing of
    -- the partner's goes on it for a few seconds, and nothing's fired from it.
    function moves.settled(p)
        return os.clock() - (p.ghostAt or -1e9) >= GEAR_SETTLE_S
    end

    local function dressGhost(p, now)
        local ghost, theirs = p.ghost, gearOf(p)
        if now < theirs.dressAt or not valid(ghost) or p.ghostHidden or not moves.settled(p) then
            return
        end
        theirs.dressAt = now + GEAR_DRESS_S
        local cwc = ghost["Character Weapons Component"]
        local slot = mainSlot()
        if theirs.partnerPath then
            if now >= theirs.swapAt and heldConfig(cwc) ~= theirs.partnerPath then
                theirs.swapAt = now + GEAR_SWAP_S
                local cfg = weaponConfig(theirs.partnerPath)
                if cfg then
                    cwc:SetSlotWeapon(slot, math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0), cfg)
                    log("The ghost now holds " .. theirs.partnerPath:match("([^.]+)$") .. ".")
                end
            end
            if (cwc:IsArmed(slot) == true) ~= theirs.partnerArmed then
                cwc:SetArmed(slot, theirs.partnerArmed)
            end
        end
        if theirs.edgePath and not net.pvp then
            slot = edgeSlot()
            if now >= (theirs.edgeSwapAt or 0) and heldConfig(cwc, slot) ~= theirs.edgePath then
                theirs.edgeSwapAt = now + GEAR_SWAP_S
                local cfg = weaponConfig(theirs.edgePath)
                if cfg then
                    cwc:SetSlotWeapon(slot, 0, cfg)
                end
            end
            if (cwc:IsArmed(slot) == true) ~= theirs.edgeArmed then
                cwc:SetArmed(slot, theirs.edgeArmed)
            end
        end
    end

    function moves.hideGear(ghost, hide)
        local cwc = ghost["Character Weapons Component"]
        local slot = mainSlot()
        cwc:SetWeaponAndScabbardForceHide(slot, math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0), hide)
        cwc:SetWeaponForceHide(edgeSlot(), 0, hide)
    end

    -- The partner has just (re)started sync: it knows nothing yet.
    local partnerStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        gear.sentPath, gear.sentEdgePath = nil, nil
        return partnerStarted(rest, from)
    end

    -- Someone new in a party: the same.
    local someoneJoined = coop.handlers.J
    coop.handlers.J = function(rest, from)
        gear.sentPath, gear.sentEdgePath = nil, nil
        return someoneJoined(rest, from)
    end

    -- Ability replays only in PvP.
    local replayAbility = coop.handlers.M
    if replayAbility then
        coop.handlers.M = function(rest)
            if moves.partnerSends and not net.pvp then
                return
            end
            return replayAbility(rest)
        end
    end

    coop.extraTicks.moves = function()
        local ok, err = pcall(watch)
        if not ok then
            last = nil
            if err ~= moves.lastError then        -- once per kind of error, not every tick
                moves.lastError = err
                log("moves: " .. tostring(err))
            end
        end
        local now = os.clock()
        ok, err = pcall(watchGear, now)
        for _, p in ipairs(coop.partners()) do
            if ok then
                ok, err = pcall(dressGhost, p, now)
            end
        end
        if not ok and err ~= gear.lastError then
            gear.lastError = err
            log("moves (gear): " .. tostring(err))
        end
    end

    -- moves: counters
    function moves.command()
        log(string.format("Moves: sent %d, played on the ghost %d, failed %d, refused %d, partner sends montages: %s",
            moves.sent, moves.played, moves.failed, moves.refused, tostring(moves.partnerSends)))
    end

    return moves
end
