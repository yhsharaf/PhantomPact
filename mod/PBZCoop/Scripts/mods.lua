-- The other mods on this PC, and whether a partner has the same ones.
--
-- A mod changes files on one PC. A partner's game draws this player's figure, weapons and moves from its own files, so
-- what a mod changes shows there only if that PC has the mod too ("from his perspective, my mod is not displaying",
-- players on 1.7.6). No mod can be sent across: the files are their authors', and a game should not load what a
-- partner hands it. What this file does is tell. Each PC lists its own mods once a session: the game's pak mods (any
-- .pak, .utoc or .ucas under Content/Paks but the game's own), the UE4SS mods switched on beside this one, and the
-- JavaScript mods of the game's two script loaders (PBZ Mods Menu and PBZModLoader). It sends a mark for each, two
-- hashes (its name; its name with its size), and compares the marks that come back.
--
-- A partner's mod names are never shown or logged on this PC, only how many differ: the names said are this player's
-- own. (A mark is no secret all the same: anyone with a list of mod names can work out which ones it stands for.)
--
-- "MODS <id> <part> <parts> <count> <mark>...": 40 marks an event, a mark is p, u or j (pak, UE4SS, JavaScript), then
-- the two hashes. An older version has no handler for it and leaves it, and sends none: nothing is said of such a
-- partner.
--
-- A difference is told once, not at every link: most players keep a mod or two of their own (a map, a menu), by
-- choice. What was told is kept in mods_told.txt beside the settings; the log has the comparison every time, and the
-- "mods" command says it again. ModsCheck = Off in PhantomPact.ini: nothing is listed, sent or compared here.

return function(api)
    local log = api.log
    local coop = api.coop
    local net = coop.net

    local mods = { on = true, own = nil, incoming = {}, theirs = {}, result = {}, logged = {}, told = {}, news = {}, sent = 0,
        heard = 0, fakes = {} }

    local PAK = { pak = true, utoc = true, ucas = true }
    local MAX = 320                 -- marks sent at most, and taken from one partner
    local PER_EVENT = 40
    local DEPTH = 3                 -- folders under Paks looked into
    local NAMES_SHOWN = 3           -- names in a tip at most, and...
    local NAMES_LEN = 60            -- ...about this many letters of them; the rest as "(+N)"
    local NAME_MAX = 32             -- one name's letters
    local TELL_AFTER_S = 8          -- after the list came: the tip of the link itself has the screen first
    local TIP_S = 4.5               -- a tip's own time before the next one (status.lua shows one for 4 s)
    local TOLD_KEPT = 8             -- differences remembered as told
    local CHECK_S = 0.5             -- how often the link is looked at
    local NEWS_A_MINUTE = 6         -- new lists taken from one player in a minute
    -- (UE4SS's own mods and the helpers that come with every install: nobody's choice.)
    local BUILT_IN = { bpmodloadermod = true, bpml_genericfunctions = true, cheatmanagerenablermod = true,
        consolecommandsmod = true, consoleenablermod = true, keybinds = true, linetracemod = true, splitscreenmod = true,
        shared = true, actordumpermod = true, jsbluaprofilermod = true }

    -- FNV-1a, 32 bits, as eight hex digits.
    local function hash(text)
        local h = 2166136261
        for i = 1, #text do
            h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff
        end
        return string.format("%08x", h)
    end

    -- One folder's entries, { name, size, dir } each; nil if there is no such folder, or no way to ask (main.dll's
    -- pp_files: an older main.dll has none).
    local function entries(dir)
        local link = api.link
        if not (link and link.files) then
            return nil
        end
        local ok, text = pcall(link.files, dir)
        if not ok or type(text) ~= "string" then
            return nil
        end
        local out = {}
        for kind, size, name in text:gmatch("([DF]) (%d+) ([^\n]+)") do
            out[#out + 1] = { name = name, size = tonumber(size) or 0, dir = kind == "D" }
        end
        return out
    end

    local function parent(path)
        return (path:gsub("[/\\]+$", "")):match("^(.*)[/\\][^/\\]+$")
    end

    -- The game's Paks folder, from UE4SS's Mods folder: under the first folder above it that holds
    -- ProjectPBZ/Content/Paks (ue4ss lies in platform/steam, or wherever a platform's build keeps it). (A path with no
    -- more folders written in it, as one from where the game runs is: up by "..".)
    local function up(path)
        local above = not path:find("%.%.$") and parent(path) or nil
        return (above and above ~= "") and above or (path .. "/..")
    end

    local function paksDir(scriptMods)
        local at = scriptMods
        for _ = 1, 7 do
            at = up(at)
            local paks = at .. "/ProjectPBZ/Content/Paks"
            if entries(paks) then
                return paks
            end
        end
        return nil
    end

    -- The game's own files, in the Paks folder itself: ProjectPBZ-Windows, its _s1 to _s65, pakchunkMovies...-Windows,
    -- global. (By the platform's ending, so an update's new ones are the game's too. Not by "ProjectPBZ-" at the
    -- front: mods are named so too, ProjectPBZ-SomeMod_997_P, and end in _P.)
    local function gamesOwn(key)
        return key == "global" or key:find("%-win%a*$") ~= nil or key:find("%-win%a*_s%d+$") ~= nil
    end

    -- A mod's name as a tip says it: its file's, without what only orders the load (zzz_, pakchunk99-, ProjectPBZ-,
    -- _P, the number before it).
    local function shownName(base)
        local name = base:gsub("^[zZ~]+_", ""):gsub("^[pP]akchunk%d+%-", ""):gsub("^[pP]roject[pP][bB][zZ]%-", "")
            :gsub("_[pP]$", ""):gsub("_%d+$", "")
        return name ~= "" and name or base
    end

    -- Pak mods: a .pak with its .utoc and .ucas is one mod, by its file name without the ending, its size all of them.
    -- Not the game's own. A mod in two folders counts once.
    local function addPaks(dir, depth, found)
        for _, e in ipairs(entries(dir) or {}) do
            if e.dir then
                if depth < DEPTH then
                    addPaks(dir .. "/" .. e.name, depth + 1, found)
                end
            else
                local base, ext = e.name:match("^(.*)%.([^.]+)$")
                if base and PAK[ext:lower()] then
                    local key = base:lower()
                    if not (depth == 0 and gamesOwn(key)) then
                        local m = found["p:" .. key]
                        if not m then
                            m = { kind = "p", name = shownName(base), key = key, size = 0 }
                            found["p:" .. key] = m
                        end
                        m.size = m.size + e.size
                    end
                end
            end
        end
    end

    -- Which script mods UE4SS is told to load: mods.txt ("Name : 1") and mods.json, by lower-case name.
    local function listedOn(scriptMods)
        local on = {}
        local f = io.open(scriptMods .. "/mods.txt", "r")
        if f then
            for line in f:lines() do
                local name, flag = line:match("^%s*([^;:%s][^:]-)%s*:%s*(%d)")
                if name then
                    on[name:lower()] = flag == "1"
                end
            end
            f:close()
        end
        f = io.open(scriptMods .. "/mods.json", "r")
        if f then
            local text = f:read("a") or ""
            f:close()
            for name, flag in text:gmatch('"mod_name"%s*:%s*"([^"]+)"%s*,%s*"mod_enabled"%s*:%s*(%a+)') do
                on[name:lower()] = on[name:lower()] or flag == "true"
            end
        end
        return on
    end

    -- UE4SS mods switched on (listed so, or with an enabled.txt of their own), but UE4SS's own and this one. A mod's
    -- size is its Scripts/main.lua and dlls/main.dll: a settings file a player edits is no other version.
    local function addScripts(scriptMods, found)
        local own = ((api.modRoot():gsub("[/\\]+$", "")):match("([^/\\]+)$") or ""):lower()
        local listed = listedOn(scriptMods)
        for _, e in ipairs(entries(scriptMods) or {}) do
            local key = e.name:lower()
            if e.dir and not BUILT_IN[key] and key ~= own then
                local on = listed[key] == true
                for _, f in ipairs(entries(scriptMods .. "/" .. e.name) or {}) do
                    on = on or (not f.dir and f.name:lower() == "enabled.txt")
                end
                if on then
                    local size = 0
                    for _, sub in ipairs({ "Scripts", "dlls" }) do
                        for _, f in ipairs(entries(scriptMods .. "/" .. e.name .. "/" .. sub) or {}) do
                            local n = f.name:lower()
                            if not f.dir and (n == "main.lua" or n == "main.dll") then
                                size = size + f.size
                            end
                        end
                    end
                    found["u:" .. key] = { kind = "u", name = e.name, key = key, size = size }
                end
            end
        end
    end

    -- The JavaScript mods of the game's two script loaders, each a folder with a main.js in it:
    --   PBZ Mods Menu (its hid.dll beside the game's exe): Content/JavaScript/PBZModsMenu/Mods/<id>, the menu itself one;
    --   PBZModLoader (its version.dll there): ProjectPBZ/PBZModLoader/mods/<id>, but what its mods.ini turns off
    --   ("<id>=0" under [Mods], or Enabled=0 under [Loader]). The Mods Menu finds and loads these too.
    -- With no loader's DLL there, the folders load nothing and count for nothing. A mod's size is its .js files, three
    -- folders deep: its settings and logs are no other version. (Found on the bench, 11-24: its game had the Mods Menu
    -- and Phantom Master Ninja running, and a list of paks and UE4SS mods alone had neither.)
    local function jsSize(dir, depth)
        local size = 0
        for _, e in ipairs(entries(dir) or {}) do
            if e.dir then
                if depth < DEPTH then
                    size = size + jsSize(dir .. "/" .. e.name, depth + 1)
                end
            elseif e.name:lower():find("%.js$") then
                size = size + e.size
            end
        end
        return size
    end

    local function addJsFolder(dir, off, found)
        for _, e in ipairs(entries(dir) or {}) do
            local key = e.name:lower()
            if e.dir and not off[key] and not found["j:" .. key] then
                local main = false
                for _, f in ipairs(entries(dir .. "/" .. e.name) or {}) do
                    main = main or (not f.dir and f.name:lower() == "main.js")
                end
                if main then
                    found["j:" .. key] = { kind = "j", name = e.name, key = key, size = jsSize(dir .. "/" .. e.name, 0) }
                end
            end
        end
    end

    local function addJs(paks, scriptMods, found)
        local content = parent(paks)
        local project = content and parent(content)
        if not project then
            return
        end
        -- (Beside the game's exe: where UE4SS's own folder lies, or its Mods folder when UE4SS lies there itself.)
        local dll = {}
        for _, dir in ipairs({ up(scriptMods), up(up(scriptMods)) }) do
            for _, e in ipairs(entries(dir) or {}) do
                if not e.dir then
                    dll[e.name:lower()] = true
                end
            end
        end
        local menu, loader = dll["hid.dll"] == true, dll["version.dll"] == true
        if menu then
            addJsFolder(content .. "/JavaScript/PBZModsMenu/Mods", {}, found)
        end
        if menu or loader then
            local off, on, section = {}, true, ""
            local f = io.open(project .. "/PBZModLoader/mods.ini", "r")
            if f then
                for line in f:lines() do
                    local head = line:match("^%s*%[([^%]]+)%]")
                    local key, value = line:match("^%s*([^;#=%[%s][^=]-)%s*=%s*(%S*)")
                    if head then
                        section = head:lower()
                    elseif key and value == "0" then
                        if section == "mods" then
                            off[key:lower()] = true
                        elseif section == "loader" and key:lower() == "enabled" then
                            on = false
                        end
                    end
                end
                f:close()
            end
            if on then
                addJsFolder(project .. "/PBZModLoader/mods", off, found)
            end
        end
    end

    local KIND_ORDER = { p = 1, u = 2, j = 3 }

    -- This PC's mods, read once a session (the game mounts its paks as it starts): { kind, name, key, size, h, v } each.
    function mods.list()
        if mods.own then
            return mods.own
        end
        local found, list = {}, {}
        local scriptMods = parent(api.modRoot())
        if scriptMods and api.link and api.link.files then
            local paks = paksDir(scriptMods)
            if paks then
                addPaks(paks, 0, found)
                addJs(paks, scriptMods, found)
            end
            addScripts(scriptMods, found)
            mods.paksFound = paks ~= nil
            mods.paths = { mods = scriptMods, paks = paks }     -- (where it looked: for a bench, or a player's report)
            mods.blind = nil
        else
            mods.blind = true       -- (no way to list a folder: nothing is said to a partner, and nothing compared)
        end
        for _, m in pairs(mods.fakes) do
            found[m.kind .. ":" .. m.key] = m
        end
        for _, m in pairs(found) do
            list[#list + 1] = m
        end
        table.sort(list, function(a, b)
            if a.kind ~= b.kind then
                return (KIND_ORDER[a.kind] or 9) < (KIND_ORDER[b.kind] or 9)
            end
            return a.key < b.key
        end)
        while #list > MAX do
            list[#list] = nil
        end
        local count, names = { p = 0, u = 0, j = 0 }, {}
        for _, m in ipairs(list) do
            m.h = hash(m.kind .. ":" .. m.key)
            m.v = hash(m.kind .. ":" .. m.key .. ":" .. string.format("%.0f", m.size))
            count[m.kind] = (count[m.kind] or 0) + 1
            names[#names + 1] = m.name
        end
        mods.own = list
        if mods.blind then
            log("Mods check: this main.dll can't list a folder (an older one): nothing is compared.")
        else
            log(string.format("Mods here beside Phantom Pact: %d (%d pak, %d UE4SS, %d JavaScript)%s%s", #list, count.p,
                count.u, count.j, #names > 0 and (": " .. table.concat(names, ", ")) or "",
                mods.paksFound and "." or ". (The game's Paks folder wasn't found from here: only UE4SS mods counted.)"))
        end
        return list
    end

    -- This PC's marks, to everyone linked.
    local sendId = 0
    function mods.send()
        if not (mods.on and net.enabled and coop.linked()) then
            return false
        end
        local list = mods.list()
        if mods.blind then
            return false
        end
        sendId = sendId % 9999 + 1
        local parts = math.max(1, math.ceil(#list / PER_EVENT))
        for part = 1, parts do
            local marks = {}
            for i = (part - 1) * PER_EVENT + 1, math.min(#list, part * PER_EVENT) do
                marks[#marks + 1] = list[i].kind .. list[i].h .. list[i].v
            end
            if #marks > 0 then
                coop.sendEvent("MODS", sendId, part, parts, #list, table.concat(marks, " "))
            else
                coop.sendEvent("MODS", sendId, part, parts, #list)
            end
        end
        mods.sent = mods.sent + 1
        return true
    end

    -- A name short enough for a tip, cut between letters (a mod's name can be in any script).
    local function short(name)
        local letters = utf8 and utf8.len(name)
        if not letters then
            name = name:gsub("[\128-\255]", "?")
            letters = #name
        end
        if letters <= NAME_MAX then
            return name
        end
        local stop = utf8 and utf8.offset(name, NAME_MAX - 1) or (NAME_MAX - 1)
        return name:sub(1, stop - 1) .. ".."
    end

    -- "A, B, C" or "A, B (+3)".
    local function namesOf(list)
        local shown, len = {}, 0
        for _, name in ipairs(list) do
            local n = short(name)
            if #shown >= NAMES_SHOWN or (#shown > 0 and len + #n > NAMES_LEN) then
                break
            end
            shown[#shown + 1] = n
            len = len + #n + 2
        end
        local text = table.concat(shown, ", ")
        if #list > #shown then
            text = text .. " (+" .. (#list - #shown) .. ")"
        end
        return text
    end

    -- What to say of one comparison: a tip each for what the partner lacks, what they have more, and other versions.
    -- (Each a whole line a translation can find: lang.lua.)
    function mods.words(r)
        local out = {}
        if #r.missing > 0 then
            out[#out + 1] = "your partner doesn't have these mods of yours: " .. namesOf(r.missing)
                .. ". What a mod changes shows only on a PC that has it."
        end
        if r.extra > 0 then
            out[#out + 1] = "your partner has mods you don't have (" .. r.extra
                .. "). What a mod changes shows only on a PC that has it."
        end
        if #r.other > 0 then
            out[#out + 1] = "these mods are another version on your partner's PC: " .. namesOf(r.other) .. "."
        end
        return out
    end

    -- What was told before, kept over sessions: a line for each difference, the newest last.
    local function toldFile()
        return api.modDir() .. "mods_told.txt"
    end
    local function toldBefore(mark)
        if mods.told[mark] then
            return true
        end
        local f = io.open(toldFile(), "r")
        if not f then
            return false
        end
        local found = false
        for line in f:lines() do
            found = found or line:match("^(%x+)") == mark
        end
        f:close()
        return found
    end
    local function keepTold(mark)
        mods.told[mark] = true
        local lines = {}
        local f = io.open(toldFile(), "r")
        if f then
            for line in f:lines() do
                line = line:match("^(%x+)")
                if line and line ~= mark then
                    lines[#lines + 1] = line
                end
            end
            f:close()
        end
        lines[#lines + 1] = mark
        while #lines > TOLD_KEPT do
            table.remove(lines, 1)
        end
        f = io.open(toldFile(), "w")
        if f then
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
        end
    end

    local function inWorld()
        local ok, pawn = pcall(function() return select(2, api.getPlayer1()) end)
        return ok and api.valid(pawn)
    end

    local function tell(who, tries)
        local r = mods.result[who]
        if not (r and mods.on and net.enabled) then
            return
        end
        if #r.missing == 0 and r.extra == 0 and #r.other == 0 then
            return
        end
        -- (The difference itself, whoever it is with: the same one is told once.)
        local mark = hash(table.concat(r.missing, "|") .. "/" .. r.extra .. "/" .. table.concat(r.other, "|"))
        if r.toldAs == mark or toldBefore(mark) then
            r.toldAs = mark
            return
        end
        if not (api.status and api.status.notify) then
            return
        end
        if not inWorld() and (tries or 0) < 40 and api.game and api.game.after then
            api.game.after(3, function() tell(who, (tries or 0) + 1) end)    -- (a loading screen has no place for a tip)
            return
        end
        r.toldAs = mark
        keepTold(mark)
        local others = 0
        for _ in pairs(mods.result) do
            others = others + 1
        end
        if net.party and others > 1 then
            -- (With more than two, who has what is in the log, each player by their number: one line here for them all.
            -- A party of two is told as two players are.)
            api.status.notify("mods", "the players here don't all have the same mods. What a mod changes shows only on a PC "
                .. "that has it.", true)
            return
        end
        for i, line in ipairs(mods.words(r)) do
            if i == 1 or not (api.game and api.game.after) then
                api.status.notify("mods" .. i, line, true)
            else
                api.game.after((i - 1) * TIP_S, function() api.status.notify("mods" .. i, line, true) end)
            end
        end
    end

    -- A partner's marks (their.marks) against this PC's own.
    function mods.compare(who, their)
        local mine = mods.list()
        if mods.blind then
            return nil
        end
        local theirs, mineSet = {}, {}
        for _, m in ipairs(their.marks) do
            theirs[m.kind .. m.h] = m.v
        end
        local r = { missing = {}, other = {}, extra = 0, same = 0, mine = #mine, theirs = #their.marks }
        for _, m in ipairs(mine) do
            mineSet[m.kind .. m.h] = true
            local v = theirs[m.kind .. m.h]
            if v == nil then
                r.missing[#r.missing + 1] = m.name
            elseif v ~= m.v then
                r.other[#r.other + 1] = m.name
            else
                r.same = r.same + 1
            end
        end
        for key in pairs(theirs) do
            if not mineSet[key] then
                r.extra = r.extra + 1
            end
        end
        mods.result[who] = r
        local name = net.party and coop.players and (coop.players[who == 0 and 1 or who] or {}).name or "your partner"
        local line = string.format("Mods check with %s: %d the same; %d of this PC's %d aren't on theirs%s; %d of theirs "
            .. "aren't here; %d another version there%s.", name, r.same, #r.missing, r.mine,
            #r.missing > 0 and (" (" .. table.concat(r.missing, ", ") .. ")") or "", r.extra, #r.other,
            #r.other > 0 and (" (" .. table.concat(r.other, ", ") .. ")") or "")
        -- (Once as it stands: the link comes back after every long loading screen, and with it the same comparison.)
        if mods.logged[who] ~= line then
            mods.logged[who] = line
            log(line)
        end
        if api.game and api.game.after then
            api.game.after(TELL_AFTER_S, function() tell(who) end)
        else
            tell(who)
        end
        return r
    end

    coop.handlers.MODS = function(rest, from)
        if not mods.on then
            return
        end
        local id, part, parts, count, marks = (rest or ""):match("^(%d+) (%d+) (%d+) (%d+)%s*(.*)$")
        id, part, parts, count = tonumber(id), tonumber(part), tonumber(parts), tonumber(count)
        if not (id and part and parts and count) or parts < 1 or parts > MAX / PER_EVENT or part < 1 or part > parts
            or count > MAX then
            return
        end
        local who = from or 0
        local got = mods.incoming[who]
        if not got or got.id ~= id or got.parts ~= parts then
            got = { id = id, parts = parts, text = {}, n = 0 }
            mods.incoming[who] = got
        end
        if got.text[part] then
            return
        end
        got.text[part], got.n = marks, got.n + 1
        if got.n < got.parts then
            return
        end
        -- All of it, the parts in their order. The same list as last time (sent again for someone who joined) is no news.
        mods.incoming[who] = nil
        mods.heard = mods.heard + 1
        local all = table.concat(got.text, " ", 1, got.parts)
        if mods.theirs[who] and mods.theirs[who].all == all then
            return
        end
        -- (A list is news at a link, at a join, or when a bench makes a mod up: more than a few a minute from one player
        -- is none, and each would be a comparison, a log line and a tip.)
        local now, news = os.clock(), mods.news[who]
        if not news or now - news.since > 60 then
            news = { since = now, n = 0 }
            mods.news[who] = news
        end
        news.n = news.n + 1
        if news.n > NEWS_A_MINUTE then
            return
        end
        local their = { all = all, marks = {} }
        for kind, h, v in all:gmatch("([puj])(%x%x%x%x%x%x%x%x)(%x%x%x%x%x%x%x%x)") do
            if #their.marks < MAX then
                their.marks[#their.marks + 1] = { kind = kind, h = h, v = v }
            end
        end
        mods.theirs[who] = their
        mods.compare(who, their)
    end

    -- Someone started sync anew, or joined a party: they know nothing of this PC's mods yet.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(...)
        mods.send()
        return syncStarted(...)
    end
    local joined = coop.handlers.J
    if joined then
        coop.handlers.J = function(...)
            mods.send()
            return joined(...)
        end
    end

    local function forget()
        mods.incoming, mods.theirs, mods.result = {}, {}, {}
    end

    -- This PC's own link, as it comes up: told once to whoever is there. (And forgotten as it goes: the next partner is
    -- told and compared anew.)
    local wasLinked, nextCheck = false, 0
    coop.extraTicks.mods = function()
        local at = os.clock()
        if at < nextCheck then
            return
        end
        nextCheck = at + CHECK_S
        local now = net.enabled and coop.linked() or false
        if now and not wasLinked then
            mods.send()
        elseif wasLinked and not now then
            forget()
        end
        wasLinked = now
    end

    -- mods                      this PC's list and what was heard
    -- mods on | off             (read at start from ModsCheck)
    -- mods fake <p|u|j> <name> <size>   a made-up mod on this PC's list, sent at once (a test bench's two copies share one folder)
    -- mods forget               what was told before is forgotten: the next difference is told again
    function mods.command(args)
        local word, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
        word = (word or ""):lower()
        if word == "on" or word == "off" then
            mods.on = word == "on"
            if mods.on then
                mods.send()
            else
                forget()
            end
        elseif word == "fake" then
            local kind, name, size = rest:match("^([puj]) (%S+) (%d+)$")
            if not kind then
                log("Usage: mods fake <p|u|j> <name> <size>")
                return
            end
            mods.fakes[kind .. ":" .. name:lower()] = { kind = kind, name = name, key = name:lower(), size = tonumber(size) }
            mods.own = nil
            mods.send()
            for who, their in pairs(mods.theirs) do
                mods.compare(who, their)
            end
        elseif word == "forget" then
            mods.told = {}
            os.remove(toldFile())
            for _, r in pairs(mods.result) do
                r.toldAs = nil
            end
        end
        local list = mods.on and mods.list() or {}
        local said = {}
        for who, r in pairs(mods.result) do
            said[#said + 1] = string.format("%s: %d the same, %d missing there, %d missing here, %d another version",
                who == 0 and "partner" or ("player " .. tostring(who)), r.same, #r.missing, r.extra, #r.other)
        end
        table.sort(said)
        log(string.format("Mods check: %s; %d mods here; sent %d, heard %d%s", mods.on and "on" or "off", #list, mods.sent,
            mods.heard, #said > 0 and ("; " .. table.concat(said, "; ")) or ""))
    end

    return mods
end
