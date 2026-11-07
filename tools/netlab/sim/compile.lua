-- Every script compiled by the real Lua, nothing run: Lua's own limits (200 locals, 255 upvalues to a function) and the
-- syntax, in a second, before a sim of minutes. python -I tools/netlab/luasim.py compile [folder of Scripts]
return function(out, scripts)
    local names = {}
    local p = io.popen('dir /b "' .. scripts:gsub("/", "\\") .. '\\*.lua"')
    if p then
        for line in p:lines() do
            names[#names + 1] = line
        end
        p:close()
    end
    local bad = 0
    for _, n in ipairs(names) do
        local f, err = loadfile(scripts .. "/" .. n)
        if not f then
            bad = bad + 1
            out("  FAIL " .. tostring(err))
        end
    end
    out(string.format("  %d scripts compiled, %d failed", #names, bad))
    return bad == 0 and #names > 0
end
