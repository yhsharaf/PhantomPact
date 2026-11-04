-- Why E finds no closed wall: for every wall within 15 m of the player, its nearest point's distance across the ground,
-- height above or below the player, and whether its meshes block. WHY.at()
WHY = WHY or {}
function WHY.at()
    local _, p = PBZ.getPlayer1()
    local here = p:K2_GetActorLocation()
    local out = {}
    for _, d in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
        local ok, at = pcall(function() return d.Spline:FindLocationClosestToWorldLocation(here, 1) end)
        if ok and at and at.X then
            local flat = math.sqrt((at.X - here.X) ^ 2 + (at.Y - here.Y) ^ 2)
            if flat < 1500 then
                local blocking, total = 0, 0
                pcall(function()
                    local meshes = d:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SplineMeshComponent"))
                    for i = 1, #meshes do
                        total = total + 1
                        if meshes[i]:get():GetCollisionEnabled() ~= 0 then blocking = blocking + 1 end
                    end
                end)
                out[#out + 1] = string.format("%s flat %.0f m, dz %.1f m, meshes blocking %d/%d", d:GetFName():ToString():sub(-14),
                    flat / 100, (at.Z - here.Z) / 100, blocking, total)
            end
        end
    end
    return #out .. " || " .. table.concat(out, " || ")
end
return WHY
