-- The play log: a file of this session's own, written as the game runs, to find afterwards what went wrong. (The user,
-- 11-18: "put something that will track everything during my play like a log that will be useful to you to find issues
-- and fix them".) UE4SS.log is emptied at every start; this keeps the last sessions. In it:
--   every line the mod says (main.lua's log passes each on), with the time of day and the seconds since the log began;
--   UE4SS.log's own lines worth having, read on as it grows: UE4SS's version, the mods it starts, Lua errors;
--   STATE, every STATE_S: frames a second and the longest frame, the mod's own time on the game thread, where the
--     player is, their health, a scene, a fight, and the link;
--   PLAY, what changed in between: the map, down and up again, a scene by its name, a fight, the player's own boss
--     fight by the boss's name with its health, the story's point, a frame that took HITCH_S or more;
--   MARK, the player's own mark when something looks wrong: F7, or both sticks pressed in for MARK_HOLD_S;
--   SNAP, at a mark and as the player goes down: the game's screens that are up, what the player's body is doing, and
--     (while co-op is on: the mod knows the enemies only then) the enemies near.
-- The files are playlog-<date>-<time>.txt in the mod folder's logs folder (the mod folder itself where there's none: Lua
-- can't make one), the newest KEEP kept (PlayLogKeep in PhantomPact.ini); a session goes on in a next file at
-- PART_BYTES. PlayLog = Off there: no log. No addresses and no names in it: an IP is written as its kind of network; a
-- Steam ID, a partner's Steam name, a host's name and a user's folder not at all; the Secret and the host's address as
-- set or not. (Players attach it to public reports.)
-- It reads the game and writes its own files, nothing else, and a failure here ends the log, never the mod. What it
-- reads, it reads by calls that change nothing the mod goes by: not game.sequenceOn, which spaces its searches for the
-- game's sequence manager (a look from here used one up, and the host saw its scene two seconds late). One thing a
-- read of its leaves behind: story.point() ends with story.lua's set of finished quests being this read's, a fresher
-- one than its own last (the same quests, read later).

return function(api)
    local valid, getPlayer1 = api.valid, api.getPlayer1

    local play = {
        on = false,
        KEEP = 12,                          -- files kept, the oldest deleted as a new one begins (PlayLogKeep)
        KEEP_MOST = 500,
        PART_BYTES = 8 * 1024 * 1024,       -- a file this big is closed, and the session goes on in the next
        STATE_S = 10.0,                     -- how the game stands, this often
        LOOK_MS = 250,                      -- what changed, UE4SS.log and the state are looked at this often
        KEY_MS = 40,                        -- the mark's keys; a press lasts longer
        TAIL_S = 2.0,                       -- UE4SS.log read on, this often
        TAIL_BYTES = 65536,                 -- at most this much of it a time
        TAIL_LINES = 60,                    -- and this many of its lines kept a time: a mod that floods it isn't copied whole
        FLUSH_EACH = 300,                   -- lines a second written through one by one (a crash keeps its last line); past that, every 20th
        HITCH_S = 0.5,                      -- a frame this long gets a line of its own
        RELAY_EVERY = 6,                    -- the relay's own line, in every so many STATE lines (and at a mark)
        NEAR_CM = 4000,                     -- a snapshot's enemies: within this
        NEAR_MOST = 8,                      -- and the nearest so many
        SCENE_LOOK_S = 5.0,                 -- the game's sequence manager searched for this often at most, while there's none
        FIGHT_SEEN_S = 3.0,                 -- the player's own boss fight is on while the mod saw it this lately (coop.lua's fightSeenAt)
        STORY_S = 60.0,                     -- the story's point read this often (a search of the game's objects, 2-3 ms)
        STORY_SOON_S = 3.0,                 -- and this soon after a scene, a boss fight or a map is over
        MARK_HOLD_S = 0.7,                  -- both sticks pressed in this long: a mark
        TRIES = 3,                          -- a part of the look that fails this often is left out from there on
        marks = 0,
    }
    local INDEX = "playlog-index.txt"       -- the files kept, oldest first: Lua can't list a folder

    local file, folder, stem, part, bytes = nil, nil, nil, 1, 0
    local clock0, time0 = os.clock(), os.time()
    local stampedAt, wall = -1, "--:--:--"
    local rateAt, rateN, dirty = -1, 0, false

    -- No addresses in the file. Which kind of network an address is on matters to a connection problem; whose it is doesn't.
    local function ipKind(a, b)
        a, b = tonumber(a), tonumber(b)
        if a == 127 then
            return "this PC's"
        elseif a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31) or (a == 169 and b == 254) then
            return "home network"
        elseif a == 100 and b >= 64 and b <= 127 then
            return "Tailscale"
        elseif a == 25 or a == 26 then
            return "Hamachi or Radmin"
        end
        return "internet"
    end
    local function maskIp(a, b)
        return "<" .. ipKind(a, b) .. " address>"
    end
    -- The partner in the panel's line: an address already written as its kind, or "<Steam ID>", is left.
    local function partnerIn(head, who, tail)
        if who == "<Steam ID>" or who:match("^<[%a' ]+ address>$") then
            return nil
        end
        return head .. "<the partner>" .. tail
    end
    local function mask(text)
        if text:find("%d+%.%d+%.%d+%.%d+") then
            text = text:gsub("(%d+)%.(%d+)%.%d+%.%d+", maskIp)
        end
        if text:find("7656119", 1, true) then
            text = text:gsub("7656119%d%d%d%d%d%d%d%d%d%d", "<Steam ID>")
        end
        -- A user's folder: Windows' in any case, and a Linux or Proton login's (Z:\home\<login>, /run/media/<login>).
        if text:find("[Uu][Ss][Ee][Rr][Ss][/\\]") then
            text = text:gsub("([/\\][Uu][Ss][Ee][Rr][Ss][/\\])[^/\\]+", "%1<user>")
        end
        if text:find("home", 1, true) or text:find("/run/media/", 1, true) then
            text = text:gsub("([/\\]home[/\\])[^/\\]+", "%1<user>")
            text = text:gsub("(/run/media/)[^/\\]+", "%1<user>")
        end
        -- A partner by name: a friend's Steam name, or a host's name on a virtual LAN. (Only the mask's own words are
        -- left, each matched whole: a name can begin with "<" too, "<3 Mika" or a clan's "<WB>Mika", and taken for
        -- one of them it was written as it is. The tenth review.)
        if text:find(", joining ", 1, true) then       -- (autostart.lua's line)
            text = text:gsub(", joining .- over Steam", ", joining <a Steam friend> over Steam")
            text = text:gsub("(, joining )[^<%s]%S*( on UDP)", "%1<the host>%2")
        end
        if text:find(" peer=", 1, true) and text:find("via=steam", 1, true) then       -- (the relay's own line: over Steam its peer is a name)
            text = text:gsub("( peer=)(.-)( rtt_ms=)", function(head, who, tail)
                if who == "-" or who == "<Steam ID>" then
                    return nil
                end
                return head .. "<a Steam friend>" .. tail
            end)
        end
        if text:find("Connected to ", 1, true) then     -- (the panel's line, and its tip)
            local n
            text, n = text:gsub("(Connected to )([^\n]-)(%. Ping )", partnerIn)
            if n == 0 then      -- (only a line with no ping: the first rule's own "<the partner>." isn't masked again)
                text = text:gsub("(Connected to )([^\n]-)(%.)$", partnerIn)
            end
        end
        if text:find("Looking for ", 1, true) and not text:find("Looking for a Steam friend who's hosting", 1, true) then
            text = text:gsub("(Looking for )[^<\n][^\n]-(%.%.%.)", "%1<the host>%2")
        end
        if text:find("ost address ", 1, true) then
            text = text:gsub("([Hh]ost address set to )[^<\n][^\n]*", "%1<the host>.")
            text = text:gsub("(couldn't find the host address )[^<\n][^\n]*", "%1<the host>")
        end
        return text
    end

    local function stop()
        local f = file
        file, play.on = nil, false
        if f then
            pcall(function() f:close() end)
        end
    end

    -- The files kept: this one added to the list, and the oldest past KEEP deleted. Only ever a file of this log's own, by
    -- its name: whatever else a line of the list says is dropped, not deleted.
    local function keep(name)
        local names = {}
        local f = io.open(folder .. INDEX, "r")
        if f then
            for n in (f:read("a") or ""):gmatch("[^\r\n]+") do
                if n:match("^playlog%-%d+%-%d+[%-%d]*%.txt$") and n ~= name then
                    names[#names + 1] = n
                end
            end
            f:close()
        end
        names[#names + 1] = name
        -- The oldest past KEEP go, but never this session's first file (its head, and how the trouble began) nor the one
        -- just begun: a session whose files fill one after another would else delete its own beginning. One that can't
        -- be deleted now (open in a viewer, under a scan) stays on the list, and is tried again the next time.
        local first, over, kept = stem .. ".txt", #names - play.KEEP, {}
        for _, n in ipairs(names) do
            local gone = false
            if over > 0 and n ~= first and n ~= name then
                over = over - 1
                gone = os.remove(folder .. n) ~= nil
                if not gone then
                    local still = io.open(folder .. n, "r")
                    if still then
                        still:close()
                    else
                        gone = true         -- (not there any more: off the list)
                    end
                end
            end
            if not gone then
                kept[#kept + 1] = n
            end
        end
        local w = io.open(folder .. INDEX, "w")
        if w then
            w:write(table.concat(kept, "\n") .. "\n")
            w:close()
        end
    end

    -- The session's next file: <stem>.txt, then <stem>-2.txt and on.
    local function openPart()
        local name = stem .. (part > 1 and ("-" .. part) or "") .. ".txt"
        local f = io.open(folder .. name, "w")
        if not f then
            return false
        end
        file, bytes = f, 0
        play.file = folder .. name
        keep(name)
        return true
    end

    local function put(text)
        local t = os.clock() - clock0
        local whole = math.floor(t)
        if whole ~= stampedAt then
            stampedAt = whole
            wall = os.date("%H:%M:%S", time0 + whole)
        end
        local s = string.format("%s %9.2f  %s\n", wall, t, mask(text))
        assert(file:write(s))       -- (a disk that's full: nil and a message, not an error of Lua's own. Made one: line() ends the log.)
        bytes = bytes + #s
        if whole ~= rateAt then
            rateAt, rateN = whole, 0
        end
        rateN = rateN + 1
        if rateN <= play.FLUSH_EACH or rateN % 20 == 0 then
            assert(file:flush())
            dirty = false
        else
            dirty = true
        end
        if bytes >= play.PART_BYTES then
            file:write("(this file is full: the session goes on in the next one)\n")
            file:close()
            file = nil
            part = part + 1
            if not openPart() then
                play.on = false
                return
            end
            put("Phantom Pact play log, file " .. part .. " of the session begun " .. os.date("%Y-%m-%d %H:%M:%S", time0) .. ".")
        end
    end

    -- A line into the file: every one the mod says (main.lua's log), and this log's own. Never an error out of here: the
    -- mod's own work called it.
    local function line(text)
        if file and not pcall(put, tostring(text)) then
            stop()
        end
    end
    play.line = line

    -- A part of the look, on its own: one that fails says so in the file, and after TRIES of them is left out.
    local fails = {}
    local function try(name, fn, ...)
        local n = fails[name] or 0
        if n >= play.TRIES then
            return
        end
        local ok, err = pcall(fn, ...)
        if not ok then
            fails[name] = n + 1
            line("play log: its look at " .. name .. " failed" .. (n + 1 >= play.TRIES and ", and is left out from here" or "")
                .. ": " .. tostring(err))
        end
    end

    -- PhantomPact.ini, as autostart.lua reads it (this runs before it, as the mod loads).
    local function settings()
        local s = {}
        local f = io.open(api.modDir() .. "PhantomPact.ini", "r")
        if f then
            for l in (f:read("a") or ""):gmatch("[^\r\n]+") do
                local key, value = l:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
                if key and not l:match("^%s*[;#]") then
                    s[key:lower()] = value
                end
            end
            f:close()
        end
        return s
    end

    local function header(s)
        local build = ""
        local f = io.open(api.modRoot() .. "build.txt", "r")        -- (a test build says which it is there; a release has none)
        if f then
            build = ", build " .. ((f:read("a") or ""):match("[^\r\n]+") or "?")
            f:close()
        end
        line("Phantom Pact play log, begun " .. os.date("%Y-%m-%d %H:%M:%S", time0) .. ". Version " .. tostring(api.version)
            .. ", protocol " .. tostring(api.protocol) .. build .. ", copy " .. tostring(os.getenv("PBZCOOP_INSTANCE") or 1) .. ".")
        line("This PC: " .. tostring(os.getenv("PROCESSOR_IDENTIFIER") or "?") .. ", " .. tostring(os.getenv("NUMBER_OF_PROCESSORS") or "?")
            .. " threads.")
        local keys, set = {}, {}
        for key in pairs(s) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = s[key]
            if key == "secret" or key == "hostaddress" then      -- (set or not, never what it is)
                value = (value ~= "" and not value:find("^PUT%-")) and "(set)" or "(not set)"
            end
            set[#set + 1] = key .. "=" .. value
        end
        line("PhantomPact.ini: " .. table.concat(set, ", "))
        line("Each line: the time of day, the seconds since this log began, what was said. STATE: how the game stood. PLAY: "
            .. "something changed. UE4SS: a line of UE4SS.log. MARK: the player's mark (F7, or both sticks pressed in). SNAP: "
            .. "the whole picture at a mark, and as the player went down.")
    end

    -- A line of UE4SS.log worth keeping: not this mod's own (those came through the log already, any copy's), not what
    -- UE4SS says of every hook and every offset it finds, and one of: its version, a mod it starts, another mod's line or
    -- its own on Lua, an error.
    local function worth(l)
        if l:find("[PBZCoop", 1, true) or l:find(" = 0x", 1, true) or l:find("xposing size of", 1, true)
            or l:find("expose size of", 1, true) or l:find("[RegisterHook]", 1, true) or l:find("[ProcessConsoleExec]", 1, true) then
            return false
        end
        return l:find("[Lua]", 1, true) ~= nil or l:find("rror") ~= nil or l:find("UE4SS - v", 1, true) ~= nil
            or l:find("Build Configuration", 1, true) ~= nil or l:find("od '", 1, true) ~= nil or l:find("xception") ~= nil
            or l:find("raceback") ~= nil or l:find("atal") ~= nil
    end

    local logPath, logFile, logAt, carry, logMissed, lastKept = nil, nil, 0, "", 0, false
    local lastRest, repeats, repeating = nil, 0, false
    -- What UE4SS.log has gained since the last pass, through one handle kept open: the file only grows in a session, and
    -- opened anew every pass it's a file another program wrote since, which a virus scanner looks at each time (tens of
    -- milliseconds on the game thread, by the review's reading of this PC).
    local function gained()
        if not logFile then
            logPath = logPath or (api.modRoot() .. "../../UE4SS.log")
            logFile = io.open(logPath, "rb")
            if not logFile then
                logMissed = logMissed + 1
                return nil
            end
            logMissed = 0
        end
        local f = logFile
        local ok, chunk = pcall(function()
            local size = f:seek("end") or 0
            if size < logAt then
                logAt, carry = 0, ""        -- (another file than the one read so far)
            end
            if size <= logAt then
                return nil
            end
            f:seek("set", logAt)
            return f:read(math.min(size - logAt, play.TAIL_BYTES))
        end)
        if not ok then
            pcall(function() f:close() end)
            logFile, logMissed = nil, logMissed + 1     -- (opened again at the next pass)
            return nil
        end
        return chunk
    end
    local function tail()
        if logMissed >= 5 then
            return              -- (no UE4SS.log where it's looked for: not asked again)
        end
        local chunk = gained()
        if not chunk or chunk == "" then
            return
        end
        logAt = logAt + #chunk
        carry = carry .. chunk
        local kept, passed, done = 0, 0, 1
        -- (The same line over and over, an error every frame: said once, then counted, with the lines under it.)
        local function counted()
            if repeats > 0 then
                line("UE4SS (the line above " .. repeats .. " times more)")
                repeats = 0
            end
        end
        for l, after in carry:gmatch("([^\n]*)\n()") do
            done = after
            l = l:gsub("\r$", "")
            local at, rest = l:match("^%[%d+%-%d+%-%d+ (%d+:%d+:%d+%.%d%d%d)%d*%] (.*)$")
            local keepIt
            if at then
                keepIt = worth(rest)
                lastKept = keepIt
                repeating = keepIt and rest == lastRest
                if repeating then
                    repeats = repeats + 1
                end
            else
                keepIt = lastKept and l:find("%S") ~= nil       -- (what follows an error on lines of its own: where it was)
            end
            if repeating then
                keepIt = false
            end
            if keepIt and kept >= play.TAIL_LINES then
                passed = passed + 1
            elseif keepIt then
                counted()
                kept = kept + 1
                if at then
                    lastRest = rest
                end
                line("UE4SS " .. (at and ("(" .. at .. ") " .. rest) or ("    " .. l)))
            end
        end
        counted()
        carry = carry:sub(done)
        if #carry > play.TAIL_BYTES then
            carry = ""                  -- (no line is this long: not kept growing)
        end
        if passed > 0 then
            line("UE4SS (" .. passed .. " more of its lines not copied: see UE4SS.log itself)")
        end
    end

    -- A scene playing, and its name: the game's sequence manager asked by the log itself (see the top: not
    -- game.sequenceOn). Kept between looks as pbz.lua keeps its own, and never used unchecked.
    local scenes, scenesAt = nil, -1e9
    local function sceneOn()
        if not valid(scenes) then
            scenes = nil
            local now = os.clock()
            if now - scenesAt < play.SCENE_LOOK_S then
                return false
            end
            scenesAt = now
            local found = FindFirstOf("PBZLevelSequenceManager")
            if not valid(found) then
                return false
            end
            scenes = found
        end
        local manager = scenes
        local ok, on, name = pcall(function()
            if manager:IsInSequence() ~= true then
                return false
            end
            local s = manager:GetCurrentSequence()
            return true, valid(s) and s:GetFName():ToString() or nil
        end)
        return ok and on == true, ok and name or nil
    end

    -- The log's own time on the game thread, by the mod's fine clock where there is one: its look and its keys (the
    -- frame count is a few additions). Said in STATE, so a log that costs something shows it.
    local own = 0
    local function clock()
        return api.link and api.link.now and api.link.now() or os.clock()
    end

    -- How the game stands. The frames and the mod's time are since the last STATE line.
    local frames, worst, lastFrame, longGap, stateAt, stateN = 0, 0, nil, nil, nil, 0
    local function state(whole)
        local now = os.clock()
        local span = math.max(now - (stateAt or clock0), 0.001)
        local out = { string.format("STATE %.0f frames a second, the longest %.0f ms", frames / span, worst * 1000) }
        frames, worst, stateAt = 0, 0, now
        -- The mod's own time on the game thread, by stage (coop.lua's runStage counts it while net.profile is there: this
        -- log's own table, or a developer's, which is left alone).
        local net = api.coop and api.coop.net
        if net and api.link then
            local profile = net.profile
            if profile ~= nil and profile == play.profile then
                local total, most, slow = 0, nil, nil
                for stage, p in pairs(profile) do
                    total = total + p.t
                    if not most or p.t > most.t then
                        most = { name = stage, t = p.t }
                    end
                    if not slow or p.max > slow.max then
                        slow = { name = stage, max = p.max }
                    end
                end
                if most then
                    out[#out + 1] = string.format("the mod %.1f ms a second (most in %s, %.1f; its longest step %s, %.1f ms)",
                        total * 1000 / span, most.name, most.t * 1000 / span, slow.name, slow.max * 1000)
                end
            end
            if profile ~= nil and profile == play.profile then
                play.profile = {}
                net.profile = play.profile      -- (counted anew from here)
            end
        end
        out[#out + 1] = string.format("this log %.1f ms a second", own * 1000 / span)
        own = 0
        out[#out + 1] = string.format("Lua %.1f MB", collectgarbage("count") / 1024)
        local game = api.game
        local _, pawn = getPlayer1()
        if not (game and valid(pawn)) then
            out[#out + 1] = "no player in the world (the title, or loading)"
        else
            local l = pawn:K2_GetActorLocation()
            out[#out + 1] = string.format("map %s at %.0f %.0f %.0f", tostring(game.mapName(pawn)), l.X, l.Y, l.Z)
            local hp, most = game.getHealth(pawn)
            out[#out + 1] = hp and string.format("health %.0f of %.0f", hp, most or 0) or "health unread"
            local flags = {}
            if game.isDead(pawn) then
                flags[#flags + 1] = "down"
            end
            if sceneOn() then
                flags[#flags + 1] = "in a scene"
            end
            if game.inCombat(pawn) then
                flags[#flags + 1] = "in a fight"
            end
            if #flags > 0 then
                out[#out + 1] = table.concat(flags, ", ")
            end
        end
        if net and net.enabled then
            local coop = api.coop
            local here, all = 0, 0
            for _, p in ipairs(coop.partners()) do
                all = all + 1
                if not p.partnerGone and p.lastRemoteAt ~= nil and now - p.lastRemoteAt < 5 then
                    here = here + 1
                end
            end
            local known, copies, held, fights = 0, 0, 0, {}
            for _ in pairs(coop.enemies()) do
                known = known + 1
            end
            for _ in pairs(net.remoteEnemies or {}) do
                copies = copies + 1
            end
            for _ in pairs(net.heldAlive or {}) do
                held = held + 1
            end
            for name in pairs(net.fightNames or {}) do
                fights[#fights + 1] = tostring(name)
            end
            table.sort(fights)
            out[#out + 1] = string.format("co-op %s%s, partners heard %d of %d, enemies %d, told by a partner %d, held %d, events out %d in %d%s",
                net.role == "client" and "guest" or "host",
                net.party and string.format(" (party of up to %s, number %s)", tostring(net.party), tostring(net.slot)) or "",
                here, all, known, copies, held, net.stats and net.stats.sent or 0, net.stats and net.stats.received or 0,
                #fights > 0 and (", boss fight " .. table.concat(fights, " ")) or "")
        else
            out[#out + 1] = "co-op off"
        end
        stateN = stateN + 1
        local relay = (whole or stateN % play.RELAY_EVERY == 1) and api.link and api.link.status and api.link.status()
        if relay then
            out[#out + 1] = "relay " .. tostring(relay)
        end
        line(table.concat(out, " | "))
    end

    -- The whole picture, at a mark and as the player goes down: the game's screens that are up, what the player's body is
    -- doing, the enemies near. Each part on its own, and none of it but then: a search of the game's screens isn't for
    -- every second. (The screens as localcoop.lua asks for them; a tag as pbz.lua's game.inCombat asks for one.)
    local TAGS = { "CharacterState.InCombat", "CharacterState.Action", "CharacterState.Hitreact", "CharacterState.Space.Air" }
    local function screensUp()
        local names = {}
        for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
            pcall(function()
                if w:IsActivated() and w:IsVisible() then
                    names[#names + 1] = w:GetClass():GetFName():ToString()
                end
            end)
        end
        table.sort(names)
        line("SNAP on the screen: " .. (#names > 0 and table.concat(names, " ") or "none of the game's screens"))
    end
    local function bodyNow()
        local _, pawn = getPlayer1()
        if not valid(pawn) then
            line("SNAP no player in the world.")
            return
        end
        local parts = {}
        pcall(function()
            parts[#parts + 1] = "movement mode " .. tostring(pawn.CharacterMovement.MovementMode)
        end)
        pcall(function()
            local m = pawn.Mesh:GetAnimInstance():GetCurrentActiveMontage()
            parts[#parts + 1] = "montage " .. (valid(m) and m:GetFName():ToString() or "none")
        end)
        pcall(function()
            local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            local asc = valid(bl) and bl:GetAbilitySystemComponent(pawn)
            if valid(asc) then
                local on = {}
                for _, tag in ipairs(TAGS) do
                    if (tonumber(asc:GetGameplayTagCount({ TagName = FName(tag) })) or 0) > 0 then
                        on[#on + 1] = tag
                    end
                end
                parts[#parts + 1] = "tags " .. (#on > 0 and table.concat(on, " ") or "none of those looked for")
            end
        end)
        line("SNAP the player: " .. (#parts > 0 and table.concat(parts, ", ") or "unread"))
    end
    local function enemiesNear()
        local coop, game = api.coop, api.game
        local _, pawn = getPlayer1()
        if not (coop and game and coop.net.enabled and valid(pawn)) then
            return              -- (the mod knows the enemies only while co-op is on)
        end
        local me, list = pawn:K2_GetActorLocation(), {}
        for name, e in pairs(coop.enemies()) do
            if valid(e) then
                local d = api.distance(e:K2_GetActorLocation(), me)
                if d <= play.NEAR_CM then
                    local hp, most = game.getHealth(e)
                    list[#list + 1] = { d = d, text = string.format("%s at %.0f m, health %s of %s%s", tostring(name), d / 100,
                        hp and string.format("%.0f", hp) or "?", most and string.format("%.0f", most) or "?",
                        game.isDead(e) and ", dead" or "") }
                end
            end
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        local out = {}
        for i = 1, math.min(#list, play.NEAR_MOST) do
            out[i] = list[i].text
        end
        line(string.format("SNAP enemies within %.0f m: %s%s", play.NEAR_CM / 100, #out > 0 and table.concat(out, "; ") or "none",
            #list > #out and string.format(" (and %d more)", #list - #out) or ""))
    end
    -- (What the nearest living enemy is made of right now -- its class, its montage and the gameplay effects on it
    -- -- so a boss's shield or armor that a partner's world shows differently can be found by name from a mark.)
    local function nearestEnemyProbe()
        local coop, game = api.coop, api.game
        local _, pawn = getPlayer1()
        if not (coop and game and coop.net.enabled and valid(pawn)) then
            return
        end
        local me, best, bestD, bestName = pawn:K2_GetActorLocation(), nil, math.huge, nil
        for name, e in pairs(coop.enemies()) do
            if valid(e) and not game.isDead(e) then
                local d = api.distance(e:K2_GetActorLocation(), me)
                if d < bestD and d <= play.NEAR_CM then
                    best, bestD, bestName = e, d, name
                end
            end
        end
        if not best then
            return
        end
        local parts = { "class " .. tostring(best:GetClass():GetFName():ToString()) }
        pcall(function()
            local ai = best.Mesh and best.Mesh:GetAnimInstance()
            local m = valid(ai) and ai:GetCurrentActiveMontage()
            parts[#parts + 1] = "montage " .. (valid(m) and m:GetFName():ToString() or "none")
        end)
        pcall(function()
            local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            local asc = valid(bl) and bl:GetAbilitySystemComponent(best)
            if valid(asc) then
                local names, seen = {}, {}
                asc.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, effect)
                    pcall(function()
                        local n = effect:get().Spec.Def:GetClass():GetFName():ToString()
                        if n and not seen[n] and #names < 25 then
                            seen[n] = true
                            names[#names + 1] = n
                        end
                    end)
                end)
                parts[#parts + 1] = "effects " .. (#names > 0 and table.concat(names, " ") or "none")
            end
        end)
        line(string.format("SNAP nearest enemy %s at %.0f m: %s", tostring(bestName), bestD / 100, table.concat(parts, ", ")))
    end
    local function snapshot()
        try("the screens", screensUp)
        try("the player's body", bodyNow)
        try("the enemies near", enemiesNear)
        try("the nearest enemy", nearestEnemyProbe)
    end

    -- The story's point, by story.lua's own read of the game's quests (its point(): the mod's own turn at reading is put
    -- back as it was). A host alone is told nothing of it otherwise: story.lua says a host's point for its guests. Said as
    -- it moves.
    local storyAt, storyWas, storyText = 0, nil, nil
    local function storyPoint()
        local now = os.clock()
        if now < storyAt or not (api.story and api.story.point) then
            return
        end
        storyAt = now + play.STORY_S
        local point, done, bits = api.story.point()
        if point == nil then
            return
        end
        -- (Which steps: story.lua's own bits, one a quest row of the story table in its order, four to a hex digit. A
        -- count alone didn't say which five a guest lacked.)
        local text = string.format("row %s, %s steps done", tostring(point), tostring(done))
        if text .. tostring(bits) ~= storyWas then
            line("PLAY the story: " .. text .. (storyText and (" (it was " .. storyText .. ")") or "") .. "; done steps "
                .. tostring(bits) .. ".")
            storyWas, storyText = text .. tostring(bits), text
        end
    end
    local function storySoon()
        storyAt = math.min(storyAt, os.clock() + play.STORY_SOON_S)
    end

    -- What changed since the last look.
    local was = { bosses = {} }
    local function changes()
        local game = api.game
        if not game then
            return
        end
        local now = os.clock()
        local _, pawn = getPlayer1()
        local body = valid(pawn)
        if body ~= was.body then
            was.body = body
            line(body and "PLAY the player is in the world." or "PLAY no player in the world (the title, or loading).")
        end
        if not body then
            return
        end
        local map = game.mapName(pawn)
        if map ~= was.map then
            line("PLAY map " .. tostring(was.map or "-") .. " -> " .. tostring(map))
            was.map = map
            storySoon()
        end
        local down = game.isDead(pawn)
        if down ~= (was.down or false) then
            was.down = down
            local l = pawn:K2_GetActorLocation()
            line(string.format("PLAY the player is %s, at %.0f %.0f %.0f.", down and "down" or "up again", l.X, l.Y, l.Z))
            if down then
                snapshot()
            end
        end
        local scene, sceneName = sceneOn()
        if scene ~= (was.scene or false) then
            was.scene = scene
            line(scene and ("PLAY a scene begins" .. (sceneName and (": " .. sceneName) or "") .. ".")
                or string.format("PLAY the scene is over (%.1f s).", now - (was.sceneAt or now)))
            was.sceneAt = now
            storySoon()
        end
        -- The player's own boss fight, by the names the mod keeps of it while co-op is on (a host alone too), with the
        -- boss's health as it begins and as it's over (over for the log, too, once the player is down).
        local net = api.coop and api.coop.net
        local names = nil
        if net and net.enabled and net.fightSeenAt and now - net.fightSeenAt < play.FIGHT_SEEN_S then
            names = net.fightNames
        end
        names = names or {}
        local function healthOf(name)
            local e = api.coop.enemyActor(name)
            if not valid(e) then
                return nil
            end
            local hp, most = game.getHealth(e)
            return (game.isDead(e) and "dead" or "alive") .. (hp and string.format(", health %.0f of %.0f", hp, most or 0) or "")
        end
        for name in pairs(names) do
            if not was.bosses[name] then
                was.bosses[name] = now
                line("PLAY a boss fight begins: " .. tostring(name) .. ", " .. (healthOf(name) or "not in the world") .. ".")
            end
        end
        for name, since in pairs(was.bosses) do
            if not names[name] then
                was.bosses[name] = nil
                line(string.format("PLAY the boss fight with %s is over (%.1f s): the boss %s.", tostring(name), now - since,
                    healthOf(name) or "gone from the world"))
                storySoon()
            end
        end
        local fight = game.inCombat(pawn)
        if fight ~= (was.fight or false) then
            was.fight = fight
            line(fight and "PLAY a fight begins (the game counts the player in one)."
                or string.format("PLAY the fight is over (%.1f s).", now - (was.fightAt or now)))
            was.fightAt = now
        end
    end

    -- The player's mark: a line that stands out, how the game stands right then, and a word on the screen that it's noted.
    local function mark()
        play.marks = play.marks + 1
        line("MARK " .. play.marks .. " ==================== the player marked this moment ====================")
        try("the state", state, true)
        snapshot()
        if api.status and api.status.notify then
            pcall(api.status.notify, "playlog" .. play.marks, "marked in the play log.")
        end
    end
    play.mark = mark

    local keys, keyWas, sticksAt, sticksDone = nil, false, nil, false
    local function markKeys()
        local pc = getPlayer1()
        if not valid(pc) then
            return
        end
        -- (F7: F3 to F6 are the mod's own, and the guides tell Gauntlet of Masters' players to move its menu to F2.)
        keys = keys or { mark = { KeyName = FName("F7") }, left = { KeyName = FName("Gamepad_LeftThumbstick") },
            right = { KeyName = FName("Gamepad_RightThumbstick") } }
        local now = os.clock()
        local key = pc:IsInputKeyDown(keys.mark) == true
        local sticks = pc:IsInputKeyDown(keys.left) == true and pc:IsInputKeyDown(keys.right) == true
        if not sticks then
            sticksAt, sticksDone = nil, false
        else
            sticksAt = sticksAt or now
        end
        local held = sticks and not sticksDone and now - sticksAt >= play.MARK_HOLD_S
        if held then
            sticksDone = true
        end
        if held or (key and not keyWas) then
            mark()
        end
        keyWas = key
    end

    -- The mod's own time counted (coop.lua's runStage, while net.profile is there), from the start and whenever nobody
    -- else's count is on: a developer's own table is left alone.
    local function countTime()
        local net = api.coop and api.coop.net
        if net and api.link and net.profile == nil then
            play.profile = {}
            net.profile = play.profile
        end
    end

    local changesAt, tailAt, stateDue = 0, 0, nil
    local function look()
        local now = os.clock()
        countTime()
        if dirty then
            dirty = false
            if not pcall(function() assert(file:flush()) end) then
                stop()
                return
            end
        end
        if longGap then
            line(string.format("PLAY a frame took %.2f s (a load, or a hitch).", longGap))
            longGap = nil
        end
        if now >= tailAt then
            tailAt = now + play.TAIL_S
            try("UE4SS.log", tail)
        end
        if now >= changesAt then
            changesAt = now + 1.0
            try("what changed", changes)
            if was.body then
                try("the story", storyPoint)
            end
        end
        stateDue = stateDue or now + play.STATE_S
        if now >= stateDue then
            stateDue = now + play.STATE_S
            try("the state", state)
        end
    end

    local function loops()
        -- Frames counted, and the longest: once a frame, and nothing else there.
        LoopInGameThreadWithDelay(1, function()
            if not file then
                return false
            end
            local now = os.clock()
            if lastFrame then
                local gap = now - lastFrame
                if gap > worst then
                    worst = gap
                end
                if gap >= play.HITCH_S and gap > (longGap or 0) then
                    longGap = gap
                end
            end
            lastFrame = now
            frames = frames + 1
            return false
        end)
        LoopInGameThreadWithDelay(play.LOOK_MS, function()
            if file then
                local began = clock()
                look()
                own = own + (clock() - began)
            end
            return false
        end)
        LoopInGameThreadWithDelay(play.KEY_MS, function()
            if file then
                local began = clock()
                try("the mark's keys", markKeys)
                own = own + (clock() - began)
            end
            return false
        end)
    end

    local function start()
        local s = settings()
        if (s.playlog or "on"):lower() == "off" then
            return
        end
        local kept = tonumber(s.playlogkeep)
        if kept and kept == kept then
            play.KEEP = math.floor(math.max(1, math.min(play.KEEP_MOST, kept)))
        end
        stem = "playlog-" .. os.date("%Y%m%d-%H%M%S", time0)
        for _, dir in ipairs({ api.modDir() .. "logs/", api.modDir() }) do
            folder = dir
            if openPart() then
                break
            end
        end
        if not file then
            return
        end
        play.on = true
        header(s)
        if file then
            loops()
        end
    end
    if not pcall(start) then
        stop()
    end

    return play
end
