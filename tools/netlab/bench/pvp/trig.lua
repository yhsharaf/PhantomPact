-- Bench only: the moment the foe figure (slot 2's body) starts an attack on this copy, written to a file, so a script outside
-- can press a key a set time after it (the mod reads its command file only every 500 ms). Watched every frame
-- (coop.frameTicks), for 6 s at most. TRIG.arm(path).
TRIG = {}
function TRIG.arm(path)
    local t0 = os.clock()
    TRIG.fired = nil
    PBZ.coop.frameTicks.trig = function()
        local name = "-"
        pcall(function()
            local g = PBZ.coop.playerBody(2)
            local m = g.Mesh:GetAnimInstance():GetCurrentActiveMontage()
            name = (m and m:IsValid()) and m:GetFName():ToString() or "-"
        end)
        if name ~= "-" and not name:find("Hit") and not name:find("Stance") and not name:find("Defence") then
            local f = io.open(path, "w")
            if f then
                f:write(name)
                f:close()
            end
            TRIG.fired = string.format("%.3f %s", os.clock() - t0, name)
            PBZ.coop.frameTicks.trig = nil
        elseif os.clock() - t0 > 6 then
            PBZ.coop.frameTicks.trig = nil
        end
    end
    return "armed"
end
