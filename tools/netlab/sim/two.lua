-- Two players, the same story played on two versions of the scripts: every game call, every event and every log line must match.
-- This is what "with the row off, nothing changes" means for the Lua. (native/ has wirecheck for its half.)

local Session = dofile(SIM_DIR .. "/session.lua")
local Fake = Session.Fake

local ENEMIES = {
    { "thug1", "BP_Monster_MaleThug_C", 1500.0, 300.0, 100.0, 600, 100 },
    { "thug2", "BP_Monster_MaleThug_C", -1800.0, 200.0, 100.0, 600, 100 },
    { "thug3", "BP_Monster_MaleThug_C", 40000.0, 500.0, 100.0, 600, 100 },
    { "far", "BP_Monster_MaleThug_C", 100000.0, 500.0, 100.0, 600, 100 },
    { "boss", "BP_Monster_Boss_C", 3000.0, 3000.0, 100.0, 5000, 400, true },
}

local function turns(pc)
    local n = 0
    for _, line in ipairs(pc.trace) do
        if line:find("TrySwitchTarget", 1, true) then
            n = n + 1
        end
    end
    return n
end

local function circle(t, r, cx)
    return (cx or 0) + math.cos(t) * r, math.sin(t) * r
end

local function story(scripts, extraIni)
    local s = Session.new(scripts, { "Host", "Guest" }, false, ENEMIES, extraIni)
    local host, guest = s.pcs[1], s.pcs[2]
    local t = 0
    local function walk()
        t = t + 1 / 60
        local x, y = circle(t, 800)
        Session.moveTo(host, x, y)
        x, y = circle(t + 1, 1000, 200)
        Session.moveTo(guest, x, y)
    end
    s:run(4, walk)

    -- Both hit enemies, and one dies each way.
    local thug = Session.enemyOn(guest, "thug1")
    Session.startMove(guest, "/Game/Move/A1.A1")
    s:run(0.2, walk)
    Fake.setHealth(thug, 500)
    s:run(0.5, walk)
    Session.endMove(guest)
    s:run(0.5, walk)
    Session.startMove(host, "/Game/Move/B1.B1")
    s:run(0.3, walk)
    Session.endMove(host)
    local mine = Session.enemyOn(host, "thug2")
    Fake.setHealth(mine, 0)
    Fake.put(mine, "dead", true)
    s:run(0.5, walk)
    Fake.setHealth(thug, 1)
    s:run(1, walk)

    -- What the game gives, and dust.
    Session.gainItem(host, "R_100", 1)
    Session.gainDust(host, 120)
    Session.gainItem(guest, "R_200", 2)
    Session.gainDust(guest, 80)
    s:run(1, walk)
    Session.gainItem(host, "R_300", 1)      -- the same thing on both PCs within a moment stays one each
    Session.gainItem(guest, "R_300", 1)
    s:run(1, walk)

    -- Moves, what they hold, a stagger, a pickup, a chest.
    Session.enemyMove(host, "thug3", "/Game/Move/E1.E1")
    Session.hold(host, "/Game/Weapon/Sword.Sword", true)
    Session.hold(guest, "/Game/Weapon/Spear.Spear", true)
    s:run(1, walk)
    Session.stagger(guest, "CharacterState.Hitreact.State.Normal.Heavy")
    Session.stagger(host, "CharacterState.Hitreact.State.Normal.Light")
    s:run(1, walk)
    Session.stagger(guest, "None")
    Session.stagger(host, "None")
    Session.enemyMove(host, "thug3", nil)
    Session.moveTo(guest, 300, 0)
    s:run(1.5)
    guest.pickups[1]:K2_DestroyActor()
    s:run(1.5)
    Session.moveTo(host, 400, 400)
    s:run(1.5)
    Fake.put(host.chests[1], "CurSwitchState", true)
    s:run(1.5)

    -- A long fight beside one enemy: it holds a target, and turns once the other player has hit it.
    Session.moveTo(host, 40000, 400)
    Session.moveTo(guest, 40300, 700)
    s:run(3)
    local shared = Session.enemyOn(guest, "thug3")
    local onHost = Session.enemyOn(host, "thug3")
    for i = 1, 24 do
        Session.enemyMove(host, "thug3", i % 2 == 0 and "/Game/Move/E1.E1" or "/Game/Move/E2.E2")
        Fake.setHealth(shared, select(1, Fake.health(shared)) - 3)
        Session.startMove(host, "/Game/Move/B1.B1")
        s:run(0.5)
        Session.endMove(host)
        Fake.setHealth(onHost, select(1, Fake.health(onHost)) - 2)
        s:run(0.5)
    end
    Session.enemyMove(host, "thug3", nil)

    -- A boss fight the host starts. The guest dies in it, and its respawn waits.
    local boss = Session.enemyOn(host, "boss")
    host.hudLayout:RegisterBossHPBar(boss)
    s:run(3, walk)
    Session.die(guest)
    s:run(7, walk)
    Fake.setHealth(boss, 0)
    Fake.put(boss, "dead", true)
    s:run(1, walk)
    host.hudLayout:UnRegisterBossHPBar(boss)
    s:run(7, walk)
    Session.revive(guest)
    s:run(2, walk)

    -- The guest goes to another map and back.
    guest.map = "Map_Other"
    s:run(6, walk)
    guest.map = "Map_Xigu"
    s:run(4, walk)

    -- A cutscene-free stretch far apart: the enemy near the guest is shared, up to the limit.
    Session.moveTo(guest, 39000, 500)
    s:run(1)
    Session.moveTo(host, 30000, 0)
    s:run(3)
    s:run(1, walk)

    -- The guest vanishes and comes back.
    guest.cut = true
    s:run(14, walk)
    guest.cut = false
    s:run(3, walk)

    -- Sync off and on again, on the guest.
    Session.command(guest, "netoff")
    s:run(1, walk)
    Session.command(guest, "neton client")
    s:run(3, walk)

    -- A bell, on the guest.
    guest.hooks["/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"][1]()
    s:run(2, walk)
    Session.command(host, "netstatus")
    Session.command(guest, "netstatus")
    s:run(1, walk)
    return s
end

-- Where each version sits on disk is the one thing allowed to differ.
local function same(a, b, oldRoot, newRoot)
    if a == nil or b == nil then
        return a == b
    end
    return a:gsub(oldRoot, "ROOT", 1) == b:gsub(newRoot, "ROOT", 1)
end

local function escaped(path)
    return (path:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0"))
end

local function compare(what, a, b, out, oldRoot, newRoot)
    local n = math.max(#a, #b)
    for i = 1, n do
        if not same(a[i], b[i], oldRoot, newRoot) then
            out(string.format("  FAIL %s differ at line %d of %d/%d:", what, i, #a, #b))
            out("    old: " .. tostring(a[i]))
            out("    new: " .. tostring(b[i]))
            return false
        end
    end
    out(string.format("  ok   %s: %d lines, the same", what, #a))
    return true
end

-- Every string in the old scripts, and the lines they're built into, through both versions of lang.lua.
local function chinese(out, oldScripts, newScripts)
    local function language(scripts)
        local lang = dofile(scripts .. "/lang.lua")()
        lang.set("Chinese")
        return lang
    end
    local old, new = language(oldScripts), language(newScripts)
    local lines = { "your partner is 150 m away.", "your partner is 150 m away. F3 takes you there.", "your partner is on another map.",
        "your partner is on another map. F3 takes you there.", "Connected to 10.0.0.1. Ping 40 ms. Route: direct.",
        "Connected to 10.0.0.1. Ping 40 ms. Route: relay.", "partner connected (ping 30 ms).", "partner connected (ping 30 ms), signed.",
        "partner connected.", "high ping (300 ms).", "high ping (300 ms). On Tailscale, run \"tailscale ping\": via DERP means relayed.",
        "Looking for 10.0.0.1...", "Host address set to 10.0.0.1.", "Couldn't start: nope", "co-op couldn't start: nope",
        "settings differ from your partner's: pvp, revive", "your partner is on Phantom Pact 1.4.1 and you're on 1.4.2: use the same version, or enemies won't stay in step.",
        "your partner's Phantom Pact (1.4.1-or-older) can't connect to 1.6.2: both PCs need the same version." }
    for _, name in ipairs({ "autostart", "coop", "hud", "lang", "main", "mapicon", "moves", "onlinepanel", "panel", "partner", "pbz", "puppets", "pvp", "revive", "scaling", "status" }) do
        local f = assert(io.open(oldScripts .. "/" .. name .. ".lua", "rb"))
        local text = f:read("a")
        f:close()
        for literal in text:gmatch('"([^"\r\n]+)"') do
            lines[#lines + 1] = literal
        end
    end
    for _, line in ipairs(lines) do
        if old.say(line) ~= new.say(line) then
            out("  FAIL Chinese differs for: " .. line)
            out("    old: " .. old.say(line))
            out("    new: " .. new.say(line))
            return false
        end
    end
    out(string.format("  ok   Chinese: %d lines through both, the same", #lines))
    return true
end

return function(out, oldScripts, newScripts)
    local good = true
    local oldRoot, newRoot = escaped(oldScripts:gsub("/Scripts$", "")), escaped(newScripts:gsub("/Scripts$", ""))
    for _, variant in ipairs({ { "plain", "" }, { "with PvP on", "PvP = On\n" }, { "with Revive on", "Revive = On\n" } }) do
    out(" " .. variant[1] .. ":")
    local old = story(oldScripts, variant[2])
    local new = story(newScripts, variant[2])
    for i, name in ipairs({ "host", "guest" }) do
        local a, b = old.pcs[i], new.pcs[i]
        good = compare(name .. " game calls", a.trace, b.trace, out, oldRoot, newRoot) and good
        good = compare(name .. " events sent", a.sent, b.sent, out, oldRoot, newRoot) and good
        good = compare(name .. " log", a.logs, b.logs, out, oldRoot, newRoot) and good
        if #b.errors > 0 then
            out("  FAIL errors on the " .. name .. ": " .. b.errors[1])
            good = false
        end
        local kinds, list = {}, {}
        for _, line in ipairs(b.sent) do
            local kind = line:match("^E (%S+)") or line:match("^Q (%S+)") or (line:find("^N ") and "enemy line")
            kinds[kind] = (kinds[kind] or 0) + 1
        end
        for kind, n in pairs(kinds) do
            list[#list + 1] = kind .. "=" .. n
        end
        table.sort(list)
        out("       " .. name .. " sent: " .. table.concat(list, " ") .. "; focus turns " .. turns(b))
    end
    end
    return chinese(out, oldScripts, newScripts) and good
end
