-- In-game connection status: the relay's status line turned into short tips at the bottom of the screen, in the
-- game's own ink-bar tip widget (WB_TipsText, the one behind "This door doesn't open from this side").
-- (From appdoze's PR #2; the tip is re-created after map travel, which removes it from the screen.)
--
-- Shown when something changes: partner connected / lost, settings that differ between the two PCs (the relays'
-- hello exchange), packets refused because the Secrets differ, a lasting high ping, Steam staying on its relays, and an
-- untested game build. Also keeps net.rttMs for the ghost's prediction (coop.lua).

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_S = 1.0              -- status reads
    local SHOW_S = 4.0              -- how long a tip stays
    local HIGH_PING_MS = 250        -- warn when the round trip stays above this...
    local HIGH_PING_FOR = 5         -- ...for this many reads in a row
    local RELAYED_FOR = 30          -- reads in a row before saying Steam relays: it can start there, then go direct
    local REPEAT_S = 60             -- the same warning at most once a minute
    local GUEST_ALONE_S = 20        -- a guest that has heard nothing for this long is told what to check
    local HOST_ALONE_S = 90         -- a host, the same, once: it may just be waiting for a friend
    local TIP_CLASS = "/Game/PBZContent/UI/InGame/SwitchUI/WB_TipsText.WB_TipsText_C"

    local status = { on = true, last = {}, lastShown = {}, highPingReads = 0, relayedReads = 0, relayShown = false,
        buildShown = false }
    local nextPoll = 0
    local tip

    -- A new ink-bar text widget at viewport layer z, or nil. Made from the widget's class: copying an instance on
    -- screen (as first written) found none until the game had shown a tip itself, so nothing ever appeared.
    function status.newTipWidget(z)
        local cls = FindObject("WidgetBlueprintGeneratedClass", "WB_TipsText_C")
        if not valid(cls) then
            cls = StaticFindObject(TIP_CLASS)
        end
        if not valid(cls) and type(LoadAsset) == "function" then
            pcall(LoadAsset, TIP_CLASS)
            cls = StaticFindObject(TIP_CLASS)
        end
        local pc = api.getPlayer1()
        if not (valid(cls) and valid(pc)) then
            return nil
        end
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(w) then
            return nil
        end
        w:AddToViewport(z)
        w:SetVisibility(3)                          -- HitTestInvisible: seen, never clicked
        return w
    end

    function status.onScreen(w)
        return valid(w) and select(2, pcall(function() return w:IsInViewport() end)) == true
    end

    local tipSerial = 0

    local function show(text)
        log("Status: " .. text)
        if not status.on then
            return
        end
        pcall(function()
            if not status.onScreen(tip) then
                tip = status.newTipWidget(400)
                if not tip then
                    return
                end
            end
            tip:SetVisibility(3)                    -- HitTestInvisible: seen, never clicked
            tip:SetText(FText("Phantom Pact: " .. api.lang.say(text)))
            pcall(function() tip:PlayAnimation(tip.FadeIn, 0, 1, 0, 1, false) end)
            local shown = tip
            tipSerial = tipSerial + 1
            local serial = tipSerial
            if game.after then
                game.after(SHOW_S, function()
                    if valid(shown) and shown == tip and serial == tipSerial then   -- (a later tip has this widget for its own time)
                        pcall(function() shown:SetVisibility(1) end)   -- collapsed
                    end
                end)
            end
        end)
    end

    -- A message at most once per REPEAT_S per key, unless it changed.
    local function notify(key, text)
        local now = os.clock()
        local prev = status.lastShown[key]
        if prev and prev.text == text and now - prev.at < REPEAT_S then
            return
        end
        status.lastShown[key] = { text = text, at = now }
        show(text)
    end

    local function readStatus()
        local text = api.link and api.link.status()
        if text == nil then
            return nil
        end
        local kv = {}
        for k, v in text:gmatch("([%w_]+)=(%S+)") do
            kv[k] = v
        end
        kv.error = text:match(" error=(.*)$")     -- the relay's own words, spaces and all
        return kv
    end

    -- Silence is all a wrong address, a Secret refused on the other PC, or two Hosts or two Guests ever show: neither side
    -- hears a thing, so the wait itself is what gets reported.
    local function reportSilence(s)
        if s.connected == "yes" then
            status.heard = true
            return
        end
        if status.heard or s.stopped or tonumber(s.rejected or 0) > 0 or (s.partner_version or "-") ~= "-" then
            return
        end
        local now = os.clock()
        status.aloneSince = status.aloneSince or now
        local waited = now - status.aloneSince
        if s.role == "client" and waited >= GUEST_ALONE_S then
            local steam = s.via == "steam"
            notify("alone", (steam and "no friend hosting found. You must be Steam friends, and your partner needs Role = Host, "
                .. "Connect = Steam and not to be Invisible in Steam (or put their SteamID64 in HostAddress), and the same "
                or ("no answer from the host (" .. tostring(s.peer) .. "). Check HostAddress and Port, that they're "
                    .. "in the game on Role = Host, and the same ")) .. "Secret and Phantom Pact version on both PCs.")
        elseif s.role == "host" and waited >= HOST_ALONE_S and not status.hostTold then
            status.hostTold = true
            notify("alone", "nobody has joined yet. Your partner needs Role = Guest and your address: two Hosts never find each other.")
        end
    end

    -- More than two players: who's come or gone, and how many that makes. (EXACG's tips, PR #11.) The first look only takes
    -- note of who's here.
    local function watchParty()
        if not net.party then
            status.here = nil
            return
        end
        local here, players = {}, 1
        for _, p in ipairs(coop.partners()) do
            if p.lastRemoteAt and not p.partnerGone then
                here[p.number] = true
                players = players + 1
            end
        end
        local before = status.here
        status.here = here
        if before then
            local size = string.format(" %d players now.", players)
            for slot in pairs(here) do
                if not before[slot] then
                    notify("party" .. slot, coop.players[slot].name .. " joined." .. size)
                end
            end
            for slot in pairs(before) do
                if not here[slot] then
                    notify("party" .. slot, coop.players[slot].name .. " left." .. size)
                end
            end
        end
    end

    local function poll()
        local s = readStatus()
        if s == nil then
            return
        end
        watchParty()
        local last = status.last
        net.rttMs = tonumber(s.rtt_ms)
        if last.role == nil then
            status.heard, status.aloneSince, status.hostTold = nil, nil, nil    -- a new start (the panel's Join): all to wait for
        end

        if s.error and s.error ~= last.error then
            notify("relay", "co-op couldn't start: " .. s.error)
        end
        reportSilence(s)
        -- A host's party full: someone knocked and got no answer, and only the host can see it (the relay counts them).
        local away, before = tonumber(s.turned_away), tonumber(last.turned_away)
        if away and before and away > before and net.party then
            notify("full", string.format("someone tried to join, but the party is full (%d players).", net.party))
        end

        if s.connected ~= "yes" and s.link_problem and s.link_problem ~= "-" and s.link_problem ~= last.link_problem then
            notify("link", "Steam couldn't connect: " .. s.link_problem:gsub("_", " ") .. ". See Connection problems in the install guide.")
        end

        if s.connected == "yes" and last.connected ~= "yes" then
            notify("conn", "partner connected" .. (net.rttMs and string.format(" (ping %d ms)", net.rttMs) or "")
                .. (s.auth == "on" and ", signed" or "") .. ".")
        elseif s.connected == "no" and last.connected == "yes" then
            notify("conn", "partner disconnected.")
        end

        if s.mismatch and s.mismatch ~= "-" and s.mismatch ~= last.mismatch then
            -- (A password set and the two clocks over 2 minutes apart: everything's turned down, and that's all there was.)
            local clock = s.mismatch:find("clock", 1, true)
            local rest = s.mismatch:gsub(",?clock", ""):gsub("^,", "")
            if clock then
                notify("clock", "your PC's clock and your partner's are over 2 minutes apart: set both to the right time.")
            end
            if rest ~= "" then
                -- (The relay names the ini's keys: its PvP key is the switch called PvPvE since 1.7.0.)
                local named = rest:gsub(",", ", "):gsub("%f[%a]pvp%f[%A]", "PvPvE")
                notify("mismatch", "settings differ from your partner's: " .. named)
            end
        end

        local theirs = s.partner_version
        if theirs and theirs ~= "?" and theirs ~= "-" and theirs ~= "" and api.version and theirs ~= api.version
            and theirs ~= last.partner_version then
            if theirs == "1.4.1-or-older" or theirs == "other-protocol" then
                notify("version", "your partner's Phantom Pact (" .. theirs .. ") can't connect to " .. api.version
                    .. ": both PCs need the same version.")
            else
                notify("version", "your partner is on Phantom Pact " .. theirs .. " and you're on " .. api.version
                    .. ": use the same version, or enemies won't stay in step.")
            end
        end

        -- A host's guests, each: only the first of them speaks for the connection above.
        if s.other_versions and s.other_versions ~= last.other_versions then
            for slot, version in s.other_versions:gmatch("(%d):([^,]+)") do
                notify("version" .. slot, "player " .. slot .. " is on Phantom Pact " .. version .. " and you're on " .. tostring(api.version)
                    .. ": use the same version, or enemies won't stay in step.")
            end
        end

        local rejected = tonumber(s.rejected) or 0
        if rejected > (tonumber(last.rejected) or 0) and s.connected ~= "yes" then
            notify("secret", "packets refused: both PCs need the same Secret in PhantomPact.ini (or both none), and "
                .. "their clocks within two minutes of each other.")
        end

        if net.rttMs and net.rttMs > HIGH_PING_MS then
            status.highPingReads = status.highPingReads + 1
            if status.highPingReads == HIGH_PING_FOR then
                notify("ping", string.format("high ping (%d ms).", net.rttMs) .. (s.via == "steam" and ""
                    or " On Tailscale, run \"tailscale ping\": via DERP means relayed."))
            end
        else
            status.highPingReads = 0
        end

        if s.route == "relay" then
            status.relayedReads = status.relayedReads + 1
            if status.relayedReads == RELAYED_FOR and not status.relayShown then
                status.relayShown = true        -- once a game: it's advice, and nothing changes it mid-fight
                notify("route", "Steam is relaying this connection, which adds delay. A direct one needs "
                    .. "SteamDirect = On on both PCs and routers that allow it.")
            end
        else
            status.relayedReads = 0
        end
        status.last = s
    end

    coop.extraTicks.status = function()
        local now = os.clock()
        if now < nextPoll then
            return
        end
        nextPoll = now + POLL_S
        poll()
        if api.gameBuildWarning and not status.buildShown then
            status.buildShown = true
            notify("build", api.gameBuildWarning)
        end
    end

    status.notify = notify          -- other modules' tips (partner.lua)

    -- tips on|off, tips <text> (show a test tip), tips (print the relay's status)
    function status.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            status.on = a == "on"
            log("In-game status tips " .. a .. ".")
        elseif a ~= "" then
            show(args)
        else
            local s = readStatus() or {}
            log("Relay: connected=" .. tostring(s.connected) .. " rtt_ms=" .. tostring(s.rtt_ms) .. " auth="
                .. tostring(s.auth) .. " mismatch=" .. tostring(s.mismatch) .. " rejected=" .. tostring(s.rejected))
        end
    end

    return status
end
