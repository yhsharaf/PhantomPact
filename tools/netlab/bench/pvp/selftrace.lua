-- Bench only: this player, every frame for a few seconds: its montage, posture and health, a row each time one changes, so
-- the moment a block's posture cost lands can be set against its Defence move's start. SELF.watch(s), then SELF.result.
SELF = {}
function SELF.watch(seconds)
    local t0, rows, last = os.clock(), {}, nil
    SELF.result = nil
    PBZ.coop.frameTicks.selftrace = function()
        local t = os.clock() - t0
        local _, p = PBZ.getPlayer1()
        local name, pos = "-", 0
        pcall(function()
            local ai = p.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            if m and m:IsValid() then
                name, pos = m:GetFName():ToString(), ai:Montage_GetPosition(m) or 0
            end
        end)
        local po, hp = PBZ.game.getPosture(p) or -1, PBZ.game.getHealth(p) or -1
        local key = string.format("%s %.0f %.0f", name:gsub("_Montage$", ""), po, hp)
        if key ~= last then
            last = key
            rows[#rows + 1] = string.format("%.3f(%.2f) %s", t, pos, key)
        end
        if t > seconds then
            SELF.result = table.concat(rows, " ; ")
            PBZ.coop.frameTicks.selftrace = nil
        end
    end
    return "watching"
end
