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

return function(api)
    local log, valid = api.log, api.valid
    local net = api.coop.net

    local MODES = { wayfarer = 1, easy = 1, pathbreaker = 2, normal = 2, hellwalker = 3, hard = 3 }
    local NAMES = { [0] = "Handicapped", "Wayfarer", "Pathbreaker", "Hellwalker", "66 Days" }
    local LOOK_S = 1.0              -- how often it looks
    local GRACE_S = 20              -- alone this long before the player's own pick comes back
    local FILE = "difficulty_own.txt"

    local difficulty = { target = 3 }
    local own = nil                 -- the mode it replaced, while it holds the game at target
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

    local function remember(mode)
        pcall(function()
            local f = io.open(api.modDir() .. FILE, "w")
            if f then
                f:write(tostring(mode))
                f:close()
            end
        end)
    end

    local function remembered()
        local v
        pcall(function()
            local f = io.open(api.modDir() .. FILE, "r")
            if f then
                v = tonumber((f:read("a") or ""):match("%d+") or "")
                f:close()
            end
        end)
        return v
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

    local function putBack(gs, cur)
        if own ~= nil and cur == difficulty.target and own ~= cur then
            if set(gs, own) then
                log(string.format("Co-op difficulty: alone again, back to your own %s.", NAMES[own] or tostring(own)))
            end
        end
        own = nil
        forget()
    end

    local function tick()
        local now = os.clock()
        if now < nextLook then
            return
        end
        nextLook = now + LOOK_S
        local gs = system()
        local cur = gs and current(gs)
        if not cur then
            return
        end
        if not started then
            -- (A pick left over from a crash in co-op: held as if the partner had just left.)
            started = true
            own = remembered()
            lastTogether = now
        end
        if difficulty.target and together() then
            lastTogether = now
            if cur < difficulty.target then
                if own == nil then
                    own = cur
                    remember(cur)
                end
                if set(gs, difficulty.target) then
                    log(string.format("Co-op difficulty: %s while you play together (yours was %s).",
                        NAMES[difficulty.target], NAMES[own] or tostring(own)))
                end
            end
        elseif own ~= nil and (not difficulty.target or now - lastTogether >= GRACE_S) then
            putBack(gs, cur)
        end
    end
    api.coop.extraTicks.difficulty = tick

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
