-- Bench only: the match screen's countdown, last screens and finishing 斩 played on this copy with no match, after its
-- arena data and UI script are loaded again from disk, so their look can be shot and changed without a restart.
-- UILOOK.reload(dir), UILOOK.count(seconds), UILOOK.card("won"|"lost"), UILOOK.slay(), UILOOK.stop().
UILOOK = UILOOK or {}

-- The mod's api, from the upvalues of the arena's functions (PBZ is only a part of it).
function UILOOK.api()
    local function scan(f, depth)
        if type(f) ~= "function" or depth > 2 then
            return nil
        end
        for i = 1, 80 do
            local n, v = debug.getupvalue(f, i)
            if not n then
                break
            end
            if n == "api" and type(v) == "table" and v.arenaui then
                return v
            end
            if type(v) == "function" then
                local a = scan(v, depth + 1)
                if a then
                    return a
                end
            end
        end
        return nil
    end
    for _, f in pairs(PBZ.arena) do
        local a = scan(f, 0)
        if a then
            return a
        end
    end
    return nil
end

-- dir: the mod's Scripts folder, with its trailing slash. (arena.lua reads api.arenaui at every call, so the match code
-- running uses the new one too.)
function UILOOK.reload(dir)
    local api = UILOOK.api()
    if not api then
        return "no api"
    end
    pcall(function() api.arenaui.clear() end)
    api.arenaData = dofile(dir .. "arenas.lua")
    api.arenaui = dofile(dir .. "arenaui.lua")(api)
    return "reloaded"
end

function UILOOK.count(seconds)
    local ui = UILOOK.api().arenaui
    local m = { mode = "duel", score = { 0, 0 }, teams = {}, down = {} }
    UILOOK.m = m
    ui.countdown(seconds or 3.0, 1, m)
    UILOOK.fightAt = os.clock() + (seconds or 3.0)
    PBZ.coop.frameTicks.uilook = function()
        if UILOOK.fightAt and os.clock() >= UILOOK.fightAt then
            UILOOK.fightAt = nil
            ui.fight(0.9)
        end
        ui.animate(m, 1)
    end
    return "counting"
end

function UILOOK.card(kind)
    local ui = UILOOK.api().arenaui
    local ok = kind == "won" and ui.victoryCard() or ui.deathCard()
    PBZ.coop.frameTicks.uilook = function() ui.animate(UILOOK.m or { teams = {}, down = {} }, 1) end
    return "card " .. kind .. " " .. tostring(ok)
end

-- The clock's end of a round the player took: TIME'S UP, then ROUND TAKEN.
function UILOOK.timeUp()
    local ui = UILOOK.api().arenaui
    local m = { mode = "duel", score = { 1, 0 }, teams = {}, down = {} }
    UILOOK.m = m
    ui.prepareTimeUp()
    ui.roundOver(1, 1, 1, 1, 0, m, true)
    PBZ.coop.frameTicks.uilook = function() ui.animate(m, 1) end
    return "time's up"
end

function UILOOK.slay()
    UILOOK.api().arenaui.slay()
    return "slay"
end

function UILOOK.stop()
    PBZ.coop.frameTicks.uilook = nil
    pcall(function() UILOOK.api().arenaui.clear() end)
    return "stopped"
end
