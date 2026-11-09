-- Bench only: the game's guard (IA_Deflect and IA_Stance in IMC_Deflect, the right mouse button) also on a keyboard key, in
-- this copy's memory only, so a key posted to its window can hold it (a posted mouse button never reaches the game; a posted
-- key does). GUARDKEY.bind("K"), GUARDKEY.unbind("K"). Nothing is saved: the game's own asset is untouched on disk.
GUARDKEY = {}
local function find()
    local imc = nil
    for _, c in ipairs(FindAllOf("InputMappingContext") or {}) do
        if c:IsValid() and c:GetFName():ToString() == "IMC_Deflect" then
            imc = c
        end
    end
    if not imc then
        return nil, {}
    end
    local acts = {}
    local function scan(arr)
        arr:ForEach(function(_, e)
            local a = e:get().Action
            local n = a:GetFName():ToString()
            if n == "IA_Deflect" or n == "IA_Stance" then
                acts[n] = a
            end
        end)
    end
    pcall(function() scan(imc.DefaultKeyMappings.Mappings) end)
    pcall(function() scan(imc.Mappings) end)
    return imc, acts
end
-- The player's input taking the changed set: out and back in, at its own priority.
local function rebuild(imc)
    local pc = PBZ.getPlayer1()
    for _, s in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
        if s:GetOuter().ControllerId == pc.Player.ControllerId then
            local found = {}
            if s:HasMappingContext(imc, found) then
                local prio = found.OutFoundPriority or 0
                s:RemoveMappingContext(imc, {})
                s:AddMappingContext(imc, prio, {})
                return "rebuilt at priority " .. tostring(prio)
            end
            return "IMC_Deflect not on the player"
        end
    end
    return "no input subsystem"
end
function GUARDKEY.bind(key)
    local imc, acts = find()
    if not imc then
        return "no IMC_Deflect"
    end
    local names = {}
    for name, a in pairs(acts) do
        imc:MapKey(a, { KeyName = FName(key) })
        names[#names + 1] = name
    end
    return table.concat(names, "+") .. " on " .. key .. "; " .. rebuild(imc)
end
function GUARDKEY.unbind(key)
    local imc, acts = find()
    if not imc then
        return "no IMC_Deflect"
    end
    for _, a in pairs(acts) do
        imc:UnmapKey(a, { KeyName = FName(key) })
    end
    return "off " .. key .. "; " .. rebuild(imc)
end
