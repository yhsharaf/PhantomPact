-- Every fog wall on this map, tried for real: the player stands a few metres off one side, the wall is closed, and the
-- mod's own pass (game.passFog) takes them through to the other side. Loaded with eval after real.lua; driven by
-- bench/walls.ps1, which steps through WALLS.list() and both sides of each wall:
--   WALLS.list()            the walls loaded now, one line each: index, mid point, normal, length
--   WALLS.stand(i, side)    the player hovering 6 m off wall i on that side (+1 or -1); WALLS.land() then
--   WALLS.pass(i, side)     the wall closed, and through it with game.passFog, toward the other side
--   WALLS.after(i, side)    where they ended up: through, back (no floor, sent back) or fallen; and the wall opened again

local valid, game = PBZ.valid, PBZ.game
WALLS = WALLS or {}

local function pawn()
    local _, p = PBZ.getPlayer1()
    return p
end

function WALLS.walls()
    local out = {}
    for _, d in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
        local ok, w = pcall(function()
            local s = d.Spline
            local len = s:GetSplineLength()
            local mid = s:GetLocationAtDistanceAlongSpline(len / 2, 1)
            local right = s:GetRightVectorAtDistanceAlongSpline(len / 2, 1)
            local n = math.sqrt(right.X ^ 2 + right.Y ^ 2)
            return { door = d, name = d:GetFName():ToString(), len = len, mid = { X = mid.X, Y = mid.Y, Z = mid.Z },
                normal = { X = right.X / n, Y = right.Y / n } }
        end)
        if ok and w and math.abs(w.mid.X) + math.abs(w.mid.Y) > 1 then
            out[#out + 1] = w
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    WALLS.cache = out
    return out
end

function WALLS.list()
    local out = {}
    for i, w in ipairs(WALLS.walls()) do
        out[#out + 1] = string.format("%d %s %.0f,%.0f,%.0f n=%.2f,%.2f len=%.0f", i, w.name:sub(-14), w.mid.X, w.mid.Y, w.mid.Z,
            w.normal.X, w.normal.Y, w.len)
    end
    return #out .. " || " .. table.concat(out, " || ")
end

-- The index of a wall by its name's end, once it's loaded; 0 if it isn't.
function WALLS.find(tail)
    for i, w in ipairs(WALLS.walls()) do
        if w.name:sub(-#tail) == tail then
            return i
        end
    end
    return 0
end

local function wall(i)
    local w = (WALLS.cache or WALLS.walls())[i]
    if not (w and valid(w.door)) then
        w = WALLS.walls()[i]
    end
    return w
end

local function off(w, side, cm, up)
    return { X = w.mid.X + w.normal.X * side * cm, Y = w.mid.Y + w.normal.Y * side * cm, Z = w.mid.Z + (up or 0) }
end

function WALLS.stand(i, side)
    local w, p = wall(i), pawn()
    if not w then
        return "no wall " .. i
    end
    p.CharacterMovement:SetMovementMode(5, 0)
    p:K2_SetActorLocation(off(w, side, 600, 200), false, {}, true)
    return "hovering"
end

function WALLS.land()
    pawn().CharacterMovement:SetMovementMode(1, 0)
    return "landed"
end

-- Whether the player stands on something here, and on which side of wall i, as "<mode> <side> <height above the wall>".
function WALLS.where(i)
    local w, p = wall(i), pawn()
    local l = p:K2_GetActorLocation()
    local across = (l.X - w.mid.X) * w.normal.X + (l.Y - w.mid.Y) * w.normal.Y
    return string.format("%d %s %.0f", p.CharacterMovement.MovementMode, across >= 0 and "+" or "-", l.Z - w.mid.Z)
end

-- (A wall takes a moment to block once told to close: close, wait, then pass.)
function WALLS.close(i)
    local w = wall(i)
    pcall(function() w.door["Close By Mob Script"](w.door) end)
    return "closing"
end

function WALLS.pass(i, side)
    local w, p = wall(i), pawn()
    local here = p:K2_GetActorLocation()
    local near = game.closedFogNear(here, 1000)
    if not near then
        return "no closed wall within 10 m"
    end
    WALLS.before = { X = here.X, Y = here.Y, Z = here.Z }
    local spot = game.passFog(p, near, off(w, -side, 600))
    if not spot then
        return "to nowhere: no floor found past it"
    end
    return string.format("to %.0f,%.0f,%.0f", spot.X, spot.Y, spot.Z)
end

function WALLS.after(i, side)
    local w, p = wall(i), pawn()
    local l = p:K2_GetActorLocation()
    pcall(function() w.door:OpenByMobScript() end)
    local across = (l.X - w.mid.X) * w.normal.X + (l.Y - w.mid.Y) * w.normal.Y
    local b = WALLS.before or l
    local verdict
    if across * side < 0 and l.Z > w.mid.Z - 400 then
        verdict = "THROUGH"
    elseif across * side > 0 and math.abs(l.Z - b.Z) < 300 then
        verdict = "BACK"
    else
        verdict = "FELL"
    end
    return string.format("%s mode=%d across=%.0f dz=%.0f", verdict, p.CharacterMovement.MovementMode, across, l.Z - w.mid.Z)
end

return WALLS
