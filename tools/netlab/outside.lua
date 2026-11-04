-- What's outside wall k of BW.list: for points along it and distances out, where a sweep down from above stops.
-- OUT.look(k) -> lines "f=0.50 d=5m: floor at dz -3.2 m" or "none (from +15 m, 30 m down)"
OUT = OUT or {}
function OUT.look(k)
    local w = BW.list[k]
    local _, p = PBZ.getPlayer1()
    p.CharacterMovement:SetMovementMode(5, 0)
    local out = { string.format("wall %s len %.0f m, out %d, near Z %.0f, boss dz %.1f m", w.name:sub(-14), w.len / 100, w.out,
        w.near.Z, (BW.at.Z - w.near.Z) / 100) }
    for _, f in ipairs({ 0.5, 0.2, 0.8 }) do
        local pt = w.near
        pcall(function()
            local l = w.door.Spline:GetLocationAtDistanceAlongSpline(w.len * f, 1)
            pt = { X = l.X, Y = l.Y, Z = l.Z }
        end)
        for _, d in ipairs({ 300, 600, 1200 }) do
            for _, side in ipairs({ w.out, -w.out }) do
                local top = { X = pt.X + w.normal.X * side * d, Y = pt.Y + w.normal.Y * side * d, Z = pt.Z + 1500 }
                p:K2_SetActorLocation(top, false, {}, true)
                p:K2_SetActorLocation({ X = top.X, Y = top.Y, Z = top.Z - 3000 }, true, {}, false)
                local z = p:K2_GetActorLocation().Z
                local what = (z > top.Z - 2) and "stuck at the start"
                    or (z < top.Z - 2998) and "none in 30 m"
                    or string.format("floor at dz %.1f m", (z - 90 - pt.Z) / 100)
                out[#out + 1] = string.format("f=%.1f d=%dm %s: %s", f, d // 100, side == w.out and "outside" or "inside", what)
            end
        end
    end
    p.CharacterMovement:SetMovementMode(1, 0)
    return table.concat(out, " || ")
end
return OUT
