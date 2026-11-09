-- The game's own key bindings: every input mapping context and what each action is bound to. KEYMAP.list(pattern) gives
-- "context: action=key" rows whose action matches (nil: all), joined with " || " (the bench reads one line).
KEYMAP = {}
function KEYMAP.list(pattern)
    local rows = {}
    local function add(name, e)
        local m = e:get()
        local a, k = "?", "?"
        pcall(function() a = m.Action:GetFName():ToString() end)
        pcall(function() k = m.Key.KeyName:ToString() end)
        if not pattern or a:lower():find(pattern:lower(), 1, true) then
            rows[#rows + 1] = name .. ": " .. a .. "=" .. k
        end
    end
    for _, imc in ipairs(FindAllOf("InputMappingContext") or {}) do
        local ok, name = pcall(function() return imc:GetFName():ToString() end)
        name = ok and name or "?"
        pcall(function() imc.DefaultKeyMappings.Mappings:ForEach(function(_, e) add(name, e) end) end)
        pcall(function() imc.Mappings:ForEach(function(_, e) add(name, e) end) end)
    end
    return #rows .. " rows || " .. table.concat(rows, " || ")
end
