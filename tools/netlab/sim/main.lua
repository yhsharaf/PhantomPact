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
elseif SIM_MODE == "chaos" then
    -- luasim.py chaos [seeds]: random parties of 3, 4 and 6, 40 steps each.
    out("chaos, parties of 3, 4 and 6:")
    local a, b = SIM_OLD:match("^(%d+)%-(%d+)$")
    passed = dofile(SIM_DIR .. "/chaos.lua")(out, scripts, a and { tonumber(a), tonumber(b) } or (tonumber(SIM_OLD) or 6), tonumber(SIM_STEPS) or 40)
elseif SIM_MODE == "scen" then
    passed = dofile(SIM_OLD)(out, scripts)
else
    error("two <old Scripts>, four or chaos [seeds]")
end
out(passed and "all passed" or "FAILED")
return passed and "pass" or "fail"
