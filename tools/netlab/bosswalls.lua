-- Every boss's walls, from the outside: is each boss's fight reachable with E? Driven by bench/bosswalls.ps1.
--   BW.boss(x, y, z)     the loaded spawner nearest that spot (within 10 m): "BOSS <id> <class>", "no <class>" or "none"
--   BW.walls()           the walls a real fight would close around BW.at (the mod's own 60 m rule): their count
--   BW.stand(k)          the player standing on floor outside wall k (away from the boss): "standing ..." or "no floor"
--   BW.close(k)          wall k closed (it blocks after a second or two)
--   BW.pass(k)           the mod's own pass, toward the boss: "to x,y,z (d m from the wall)" or "nowhere"
--   BW.after(k)          verdict: IN (on the boss's side, standing), STAYED, FELL; and the wall opened again
local valid, game = PBZ.valid, PBZ.game
BW = BW or {}
local RADIUS = 6000

local function pawn()
    local _, p = PBZ.getPlayer1()
    return p
end

local function gap(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

function BW.boss(x, y, z)
    local spot, best, bestD = { X = x, Y = y, Z = z }, nil, 1000
    for _, s in ipairs(FindAllOf("AISpawner") or {}) do
        local ok, at = pcall(function() return s:K2_GetActorLocation() end)
        if ok and at and gap(at, spot) < bestD then
            best, bestD = s, gap(at, spot)
        end
    end
    if not best then
        return "none"
    end
    local path = "?"
    pcall(function()
        local v = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):Conv_SoftClassReferenceToString(best.Class)
        path = type(v) == "string" and v or v:ToString()
    end)
    local cls = path:match("%.([%w_]+)$") or path
    local id = "?"
    pcall(function() id = best.SpawnerID:ToString() end)
    if id == "None" then
        id = best:GetFName():ToString()
    end
    local at = best:K2_GetActorLocation()
    BW.at = { X = at.X, Y = at.Y, Z = at.Z }
    if game.isBossClass(cls) then
        return string.format("BOSS %s %s", id, cls)
    end
    return "no " .. cls
end

function BW.walls()
    local out = {}
    for _, d in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
        local ok, near, right, len = pcall(function()
            local s = d.Spline
            return s:FindLocationClosestToWorldLocation(BW.at, 1), s:FindRightVectorClosestToWorldLocation(BW.at, 1), s:GetSplineLength()
        end)
        if ok and near and near.X and gap(near, BW.at) <= RADIUS then
            local n = math.sqrt(right.X ^ 2 + right.Y ^ 2)
            local w = { door = d, near = { X = near.X, Y = near.Y, Z = near.Z }, len = len, name = d:GetFName():ToString(),
                normal = { X = right.X / n, Y = right.Y / n } }
            -- outside: the side away from the boss
            local across = (BW.at.X - near.X) * w.normal.X + (BW.at.Y - near.Y) * w.normal.Y
            w.out = across >= 0 and -1 or 1
            out[#out + 1] = w
        end
    end
    BW.list = out
    return #out
end

-- The arena these walls make, by their names: the same set from another spawner is the same fight.
function BW.key()
    local names = {}
    for _, w in ipairs(BW.list or {}) do
        names[#names + 1] = w.name:sub(-14)
    end
    table.sort(names)
    return table.concat(names, "+")
end

local function floorAt(p, spot)
    p:K2_SetActorLocation(spot, false, {}, true)
    p:K2_SetActorLocation({ X = spot.X, Y = spot.Y, Z = spot.Z - 1500 }, true, {}, false)
    local z = p:K2_GetActorLocation().Z
    return z < spot.Z - 2 and z > spot.Z - 1498
end

function BW.stand(k)
    local w, p = BW.list[k], pawn()
    if not (w and valid(w.door)) then
        return "no wall"
    end
    game.setMinHealth(p, 1)
    p.CharacterMovement:SetMovementMode(5, 0)
    local points = { w.near }
    for _, f in ipairs({ 0.5, 0.3, 0.7, 0.15, 0.85 }) do
        pcall(function()
            local l = w.door.Spline:GetLocationAtDistanceAlongSpline(w.len * f, 1)
            points[#points + 1] = { X = l.X, Y = l.Y, Z = l.Z }
        end)
    end
    -- (From higher up too: ground rising outside the wall had the start point inside the hill, and the sweep never moved.)
    for _, up in ipairs({ 200, 700, 1500 }) do
    for _, pt in ipairs(points) do
        for _, d in ipairs({ 500, 300, 800 }) do
            local spot = { X = pt.X + w.normal.X * w.out * d, Y = pt.Y + w.normal.Y * w.out * d, Z = pt.Z + up }
            -- (On a ledge or roof well above or below the wall's foot is no place a player stands to use it.)
            local rise = floorAt(p, spot) and (p:K2_GetActorLocation().Z - 90 - pt.Z)
            if rise and rise > -400 and rise < 1400 then     -- (a wall's line can lie under the floor: as closedFogNear)
                p.CharacterMovement:SetMovementMode(1, 0)
                local l = p:K2_GetActorLocation()
                BW.before = { X = l.X, Y = l.Y, Z = l.Z }
                return string.format("standing %.0f m off (%.0f m up the start), %.0f m from the boss", d / 100, up / 100,
                    gap(l, BW.at) / 100)
            end
        end
    end
    end
    p.CharacterMovement:SetMovementMode(1, 0)
    return "no floor outside"
end

function BW.close(k)
    local w = BW.list[k]
    pcall(function() w.door["Close By Mob Script"](w.door) end)
    return "closing"
end

function BW.pass(k)
    local p = pawn()
    local near = game.closedFogNear(p:K2_GetActorLocation(), 1000)
    if not near then
        return "no closed wall within 10 m"
    end
    local spot = game.passFog(p, near, BW.at)
    if not spot then
        return "nowhere"
    end
    local off = math.abs((spot.X - near.at.X) * near.normal.X + (spot.Y - near.at.Y) * near.normal.Y)
    return string.format("to %.0f,%.0f,%.0f (%.0f m past the wall%s)", spot.X, spot.Y, spot.Z, off / 100,
        off > 800 and ", beside the boss: the fallback" or "")
end

function BW.after(k)
    local w, p = BW.list[k], pawn()
    local l = p:K2_GetActorLocation()
    pcall(function() w.door:OpenByMobScript() end)
    local across = (l.X - w.near.X) * w.normal.X + (l.Y - w.near.Y) * w.normal.Y
    local inside = across * w.out < 0
    local b = BW.before or l
    local verdict
    if inside and l.Z > math.min(w.near.Z, BW.at.Z) - 600 then
        verdict = "IN"
    elseif not inside and math.abs(l.Z - b.Z) < 300 then
        verdict = "STAYED"
    else
        verdict = "FELL"
    end
    return string.format("%s mode=%d dz=%.0f boss %.0f m", verdict, p.CharacterMovement.MovementMode, l.Z - w.near.Z, gap(l, BW.at) / 100)
end

return BW
