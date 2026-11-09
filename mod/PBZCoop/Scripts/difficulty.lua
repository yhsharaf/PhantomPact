-- Co-op difficulty mode: while someone plays with you (online or local), the game's own difficulty is at least Hellwalker
-- (PhantomPact.ini CoopDifficulty). The player's own pick comes back once they're alone again.
--
-- The game's setting (read on the bench, 11-09): PBZGameSystem:SetDifficultMode(EDifficultMode) switches the global combat
-- config at once, enemies already around included (a thug went 500 -> 400 health and 100 -> 70 attack on Easy, and back on
-- Hard). EDifficultMode: 0 Handicapped (not in the menu), 1 Easy = Wayfarer, 2 Normal = Pathbreaker, 3 Hard = Hellwalker,
-- 4 NightMare = 66 Days. It only ever goes up: 66 Days is already harder (a 6-frame perfect deflect instead of 8), and its
-- one-life run isn't ours to touch.
--
-- The pick it replaced is kept in difficulty_own.txt until it's put back, so a crash in co-op doesn't leave the save on
-- Hellwalker: the next start puts it back once the player is alone (after GRACE_S, as for a partner who drops for a moment).
-- Someone who changes the difficulty in the menu during co-op: a lower one is raised again; a higher one is theirs, and
-- stays when the partner leaves.
--
-- Each PC uses its own setting; both default to Hellwalker, so a party plays the same mode.
--
-- A PvP match (arena.lua, F6: net.arena) is the same for everyone, whatever CoopDifficulty says: there are no monsters,
-- and what's left of a mode is how a player's guard and posture work. The modes' combat configs, read on the bench (11-09):
-- Hellwalker and 66 Days differ only in the perfect deflect window (8 frames, 6); Pathbreaker and Wayfarer also in the
-- window on a break (12 and 14 frames, Hellwalker's 6), Wayfarer in how long a broken player reels (2 s, not 3); no mode
-- changes a player's attributes. So a match holds the game at least at Hellwalker, and 66 Days, never lowered, gets
-- Hellwalker's perfect deflect window in its config for the match: in memory only (the game never saves it), its own back
-- when the match is over. A match is never saved either (arena.lua's save veto), so difficulty_own.txt keeps what the save
-- can hold: the co-op pick from before the match, or nothing.
--
-- One of coop's extraTicks while sync is on, a loop of its own while it's off: coop stops its ticks with sync, and leaving
-- co-op (Leave, netoff) mid-match or while held left the game on Hellwalker and 66 Days at 8 frames (the review of
-- 3f77be8). It acts only with the player in the world: on the title screen the game says Pathbreaker whatever the save is.

return function(api)
    local log, valid = api.log, api.valid
    local net = api.coop.net

    local MODES = { wayfarer = 1, easy = 1, pathbreaker = 2, normal = 2, hellwalker = 3, hard = 3 }
    local NAMES = { [0] = "Handicapped", "Wayfarer", "Pathbreaker", "Hellwalker", "66 Days" }
    local HELLWALKER, DAYS = 3, 4
    local LOOK_S = 1.0              -- how often it looks
    local GRACE_S = 20              -- alone this long before the player's own pick comes back
    local FILE = "difficulty_own.txt"
    local CONFIG = "/PBZCombatAsset/Config/GlobalConfig_Combat_%s.GlobalConfig_Combat_%s"
    local WINDOW = "Deflect Perfect Window Frames"

    local difficulty = { target = 3 }
    local own = nil                 -- the mode it replaced, while it holds the game above it
    local held = nil                -- the mode it set and holds the game at (Hellwalker in a match, else the co-op pick)
    local keptWindow = nil          -- 66 Days' own perfect deflect window, while a match holds it at Hellwalker's
    local lastTogether = os.clock()
    local nextLook = 0
    local started = false

    local function system()
        local gs = FindFirstOf("PBZGameSystem")
        return valid(gs) and gs or nil
    end

    local function current(gs)
        local ok, v = pcall(function() return gs:GetDifficultModeByte() end)
        return ok and tonumber(v) or nil
    end

    local function set(gs, mode)
        return pcall(function() gs:SetDifficultMode(mode) end)
    end

    -- "<own> <held>": the player's pick, then the mode it holds the game at. (A file of one number, from before a match could
    -- hold the game: that one held at the co-op pick.)
    local function remember()
        pcall(function()
            local f = io.open(api.modDir() .. FILE, "w")
            if f then
                f:write(tostring(own) .. (held and (" " .. tostring(held)) or ""))
                f:close()
            end
        end)
    end

    local function remembered()
        local a, b
        pcall(function()
            local f = io.open(api.modDir() .. FILE, "r")
            if f then
                local text = f:read("a") or ""
                f:close()
                local x, y = text:match("^%s*(%d+)%s*(%d*)")
                a, b = tonumber(x or ""), tonumber(y or "")
            end
        end)
        return a, b
    end

    local function forget()
        pcall(os.remove, api.modDir() .. FILE)
    end

    local function together()
        if api.state and valid(api.state.p2Pawn) then
            return true
        end
        if api.scaling and api.scaling.players then
            local ok, n = pcall(api.scaling.players)
            if ok and tonumber(n) and n > 1 then
                return true
            end
        end
        return false
    end
    difficulty.together = together

    -- (A mode other than the one it set is the player's own pick from the menu: a higher one stays theirs.)
    local function putBack(gs, cur)
        if own ~= nil and cur == (held or difficulty.target) and own ~= cur then
            if set(gs, own) then
                log(string.format("Co-op difficulty: back to your own %s.", NAMES[own] or tostring(own)))
            end
        end
        own, held = nil, nil
        forget()
    end

    -- The least mode the game is held at now: Hellwalker in a PvP match, whatever CoopDifficulty says; the co-op pick with
    -- a partner; none alone.
    local function least()
        if net.arena then
            return HELLWALKER
        end
        if difficulty.target and together() then
            return difficulty.target
        end
        return nil
    end

    local function combatConfig(name)
        local c = StaticFindObject(string.format(CONFIG, name, name))
        return valid(c) and c or nil
    end

    -- 66 Days in a match: Hellwalker's perfect deflect window in its combat config (found again each time, never kept);
    -- off, its own back.
    local function matchWindow(on)
        if not on and keptWindow == nil then
            return
        end
        pcall(function()
            local days = combatConfig("Nightmare")
            if not days then
                return
            end
            local now = tonumber(days[WINDOW])
            if on then
                local hard = combatConfig("Hard")
                local want = hard and tonumber(hard[WINDOW])
                if want and now and want ~= now then
                    if keptWindow == nil then
                        keptWindow = now
                    end
                    days[WINDOW] = want
                    log(string.format("Co-op difficulty: 66 Days in a PvP match: Hellwalker's %d-frame perfect deflect, "
                        .. "not its own %d.", want, keptWindow))
                end
            else
                if now ~= keptWindow then
                    days[WINDOW] = keptWindow
                end
                log(string.format("Co-op difficulty: the match is over: 66 Days' own %d-frame perfect deflect.", keptWindow))
                keptWindow = nil
            end
        end)
    end

    local function look(now)
        local gs = system()
        local cur = gs and current(gs)
        local _, pawn = api.getPlayer1()
        if not cur or not valid(pawn) then
            return          -- (the title screen or a load: the mode read there isn't the save's)
        end
        if not started then
            -- (A pick left over from a crash in co-op: held as if the partner had just left.)
            started = true
            own, held = remembered()
            lastTogether = now
        end
        matchWindow(net.arena == true and cur == DAYS)
        local want = least()
        if want then
            lastTogether = now
        end
        if held ~= nil and cur > held then
            -- A higher mode picked in the menu: the player's own now, and it stays when the partner leaves.
            own, held = nil, nil
            forget()
        end
        if want and cur < want then
            if own == nil then
                own = cur
            end
            if set(gs, want) then
                held = want
                if not net.arena then
                    remember()      -- (a match is never saved: the file keeps what the save can hold)
                end
                log(string.format("Co-op difficulty: %s while you %s (yours was %s).", NAMES[want],
                    net.arena and "fight a PvP match" or "play together", NAMES[own] or tostring(own)))
            end
        elseif want and held ~= nil and cur == held and want < held then
            -- The match is over and the partner still here: down to the co-op pick, never under the player's own; back at
            -- the player's own, nothing is held any more (held there, it set the same mode again every second: the review).
            local to = math.max(want, own or want)
            if set(gs, to) then
                log(string.format("Co-op difficulty: the match is over: %s while you play together.", NAMES[to]))
                if to == own then
                    own, held = nil, nil
                    forget()
                else
                    held = to
                    remember()
                end
            end
        elseif not want and own ~= nil and (not difficulty.target or now - lastTogether >= GRACE_S) then
            putBack(gs, cur)
        end
    end
    api.coop.extraTicks.difficulty = function()
        local now = os.clock()
        if now >= nextLook then
            nextLook = now + LOOK_S
            look(now)
        end
    end
    LoopInGameThreadWithDelay(math.floor(LOOK_S * 1000), function()
        if not net.enabled then
            local ok, err = pcall(look, os.clock())
            if not ok and err ~= difficulty.lastError then
                difficulty.lastError = err
                log("Co-op difficulty: " .. tostring(err))
            end
        end
        return false
    end)

    -- difficulty [hellwalker | pathbreaker | wayfarer | off]   (read at start from CoopDifficulty)
    function difficulty.command(args)
        local word = ((args or ""):match("^%s*(%S+)") or ""):lower()
        if word ~= "" then
            if MODES[word] == nil and word ~= "off" then
                log("Co-op difficulty: say hellwalker, pathbreaker, wayfarer or off.")
                return
            end
            difficulty.target = MODES[word]
            nextLook = 0
        end
        local gs = system()
        local cur = gs and current(gs)
        log(string.format("Co-op difficulty: %s with a partner; now %s%s.",
            difficulty.target and NAMES[difficulty.target] or "your own mode",
            cur and (NAMES[cur] or tostring(cur)) or "?",
            own and (", yours is " .. (NAMES[own] or tostring(own))) or ""))
    end

    return difficulty
end
