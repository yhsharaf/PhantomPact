-- luasim.py starts here.

local function out(text)
    io.stdout:write(text, "\n")
    io.stdout:flush()
end

local scripts = SIM_REPO .. "/mod/PBZCoop/Scripts"
local passed
if SIM_MODE == "two" then
    out("two players, old scripts against new:")
    passed = dofile(SIM_DIR .. "/two.lua")(out, SIM_OLD, scripts)
elseif SIM_MODE == "four" then
    out("four players:")
    passed = dofile(SIM_DIR .. "/four.lua")(out, SIM_OLD ~= "" and SIM_OLD or scripts)
else
    error("two <old Scripts> or four")
end
out(passed and "all passed" or "FAILED")
return passed and "pass" or "fail"
