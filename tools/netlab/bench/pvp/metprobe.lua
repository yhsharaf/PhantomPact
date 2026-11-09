-- Bench only: the first frame this player's Defence move shows, what pvp.lua's watchGuard would weigh: its position in
-- the move, when it began (now - pos), the partner's last move (p.moveAt, its age then), and our guard's rise. METP.arm(s).
METP = {}
function METP.arm(seconds)
    local t0 = os.clock()
    METP.result = nil
    PBZ.coop.frameTicks.metp = function()
        local now = os.clock()
        local _, me = PBZ.getPlayer1()
        local name, pos = nil, 0
        pcall(function()
            local ai = me.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            if m and m:IsValid() then
                name, pos = m:GetFName():ToString(), ai:Montage_GetPosition(m) or 0
            end
        end)
        if name and name:find("Defence", 1, true) then
            local p = PBZ.coop.partners()[1]
            local met = now - pos
            METP.result = string.format("Defence %s pos %.3f | met - moveAt %.3f | guardUp - moveAt %.3f | move %s",
                name, pos, met - (p.moveAt or 0), (PBZ.game.guardUpAt or 0) - (p.moveAt or 0),
                tostring(p.movePath and p.movePath:match("[^.]+$")))
            PBZ.coop.frameTicks.metp = nil
        elseif now - t0 > seconds then
            METP.result = "no Defence seen"
            PBZ.coop.frameTicks.metp = nil
        end
    end
    return "armed"
end
