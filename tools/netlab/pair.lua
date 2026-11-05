-- Two real copies of the game on one PC: what each one does, on a clock they share. Loaded with eval next to perf.lua.
--   PAIR.record(seconds, file)    writes down where everything is, each frame, on this copy's side
--   PAIR.walk(seconds, radius)    walks player 1 in a circle with the game's own movement, stopping and jumping now and then
--   PAIR.swing(seconds)           plays an attack every so often, so the other side has moves to show
-- pair_report.py compares two recordings.

local log, valid = PBZ.log, PBZ.valid
local game, coop, link = PBZ.game, PBZ.coop, PBZ.link
PAIR = PAIR or {}

-- Each move as it comes, with the age it came with and the round trip the mod used to guess from: "UA <time> <age> <rtt> <move>".
if coop.handlers.U and not PAIR.wrappedU then
    PAIR.wrappedU = true
    local play = coop.handlers.U
    coop.handlers.U = function(rest, from)
        if PAIR.rows then
            PAIR.rows[#PAIR.rows + 1] = string.format("UA %.4f %s %s %s", link.wall(), tostring(PBZ.net.eventAgeMs), tostring(PBZ.net.rttMs), rest)
        end
        return play(rest, from)
    end
end

-- The montage a body plays and how far into it, "<tag> <time> <position> <montage>": the ghost's against its player's, at the
-- same moment, is how far out of step a move shows.
local function montageRow(rows, tag, now, body)
    pcall(function()
        local ai = body.Mesh:GetAnimInstance()
        local m = ai and ai:GetCurrentActiveMontage()
        if valid(m) then
            rows[#rows + 1] = string.format("%s %.4f %.4f %s", tag, now, ai:Montage_GetPosition(m), m:GetFName():ToString())
        end
    end)
end

function PAIR.record(seconds, path)
    local rows, done = {}, false
    PAIR.rows = rows
    local stop = link.wall() + seconds
    local nextEnemies = 0
    LoopInGameThreadWithDelay(1, function()
        if done then return false end
        local now = link.wall()
        local _, pawn = PBZ.getPlayer1()
        if valid(pawn) then
            local p = pawn:K2_GetActorLocation()
            rows[#rows + 1] = string.format("P %.4f %.1f %.1f %.1f %.1f", now, p.X, p.Y, p.Z, pawn:K2_GetActorRotation().Yaw)
            montageRow(rows, "MP", now, pawn)
        end
        local ghost = PBZ.net.ghost
        if valid(ghost) then
            local g = ghost:K2_GetActorLocation()
            rows[#rows + 1] = string.format("G %.4f %.1f %.1f %.1f %.1f", now, g.X, g.Y, g.Z, ghost:K2_GetActorRotation().Yaw)
            montageRow(rows, "MG", now, ghost)
        end
        local t = PBZ.net.target
        if t then
            rows[#rows + 1] = string.format("T %.4f %.1f %.1f %.1f", now, t.X, t.Y, t.Z)
        end
        if now >= nextEnemies then
            nextEnemies = now + 0.05
            for name, actor in pairs(coop.enemies()) do
                if valid(actor) then
                    local e = actor:K2_GetActorLocation()
                    local hp = game.getHealth(actor)
                    rows[#rows + 1] = string.format("E %.4f %s %.1f %.1f %.1f %.1f", now, name, e.X, e.Y, e.Z, hp or -1)
                end
            end
        end
        if now >= stop then
            done = true
            if PAIR.rows == rows then
                PAIR.rows = nil
            end
            local f = io.open(path, "w")
            if f then
                f:write(table.concat(rows, "\n"), "\n")
                f:close()
            end
            log("PAIR recorded " .. #rows .. " rows to " .. path)
        end
        return false
    end)
end

function PAIR.walk(seconds, radius)
    local stop, done = link.now() + seconds, false
    local started = link.now()
    local rate = 300 / (radius or 800)     -- radians per second
    local nextJump = started + 4
    LoopInGameThreadWithDelay(1, function()
        if done then return false end
        local now = link.now()
        if now >= stop then
            done = true
            return false
        end
        local _, pawn = PBZ.getPlayer1()
        if not valid(pawn) then return false end
        -- 3 s of walking, then a second's stop: the stops are what a guess ahead gets wrong.
        if (now - started) % 4 < 3 then
            local a = (now - started) * rate
            pawn:AddMovementInput({ X = math.cos(a), Y = math.sin(a), Z = 0.0 }, 1.0, false)
        end
        if now >= nextJump then
            nextJump = now + 5
            pcall(function() pawn:Jump() end)
        end
        return false
    end)
end

function PAIR.swing(seconds, path)
    local stop, done = link.now() + seconds, false
    local montage = PBZ.api and nil
    local m = StaticFindObject(path or "/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Default/AM_Hun_Tang_AA.AM_Hun_Tang_AA")
    local nextSwing = 0
    LoopInGameThreadWithDelay(1, function()
        if done then return false end
        local now = link.now()
        if now >= stop then
            done = true
            return false
        end
        if now >= nextSwing and valid(m) then
            nextSwing = now + 2
            local _, pawn = PBZ.getPlayer1()
            if valid(pawn) then
                pcall(function() pawn.Mesh:GetAnimInstance():Montage_Play(m, 1.0, 0, 0, true) end)
            end
        end
        return false
    end)
end

-- The nearest living enemy the sync knows about.
function PAIR.nearest()
    local _, pawn = PBZ.getPlayer1()
    local here, best, bestD, bestName = pawn:K2_GetActorLocation(), nil, 1e12, nil
    for name, actor in pairs(coop.enemies()) do
        if valid(actor) and not game.isDead(actor) then
            local d = PBZ.distance(actor:K2_GetActorLocation(), here)
            if d < bestD then
                best, bestD, bestName = actor, d, name
            end
        end
    end
    return best, bestName, bestD
end

-- Takes a share of the nearest enemy's health, the way a hit would, and says when.
function PAIR.hurt(share)
    local e, name, d = PAIR.nearest()
    if not e then
        log("PAIR hurt: no enemy")
        return
    end
    local hp, max = game.getHealth(e)
    game.setHealth(e, hp * (1 - share))
    log(string.format("PAIR hurt %s at %.4f: %.0f -> %.0f of %.0f (%.0f cm away)", name, link.wall(), hp, hp * (1 - share), max, d))
end

function PAIR.kill()
    local e, name = PAIR.nearest()
    if not e then
        log("PAIR kill: no enemy")
        return
    end
    log(string.format("PAIR kill %s at %.4f", name, link.wall()))
    game.applyDamage(e, math.huge, 0)
end

-- Every copy of this enemy's health and state, for the log.
function PAIR.look(name)
    local e = coop.enemyActor(name)
    if not valid(e) then
        log(string.format("PAIR look %s at %.4f: not matched here", name, link.wall()))
        return
    end
    local hp, max = game.getHealth(e)
    local bar = "?"
    pcall(function() bar = tostring(e.hpbar:GetUserWidgetObject().hpbar.RealBar.Percent) end)
    log(string.format("PAIR look %s at %.4f: hp %s/%s dead %s bar %s", name, link.wall(), tostring(hp), tostring(max), tostring(game.isDead(e)), bar))
end
