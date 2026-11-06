-- Phantom Pact auto-start: reads PhantomPact.ini, starts the network relay when the game starts, and turns online
-- sync on once the player is in gameplay. Players edit the ini or use the online panel; nothing to run by hand.
--
-- The relay is the built-in one (dlls\main.dll, native/ in the repo), which UE4SS loads with the game and which ends
-- with it, or when the player leaves (api.online, for onlinepanel.lua).

return function(api)
    local log, valid, getPlayer1 = api.log, api.valid, api.getPlayer1
    local modDir, modRoot = api.modDir, api.modRoot
    local neton = api.coop.commands.neton

    local placeholder = "PUT-THE-HOSTS-TAILSCALE-IP-HERE"

    -- Game builds this version was tested on, by PBZ.exe size (instant to read; hashing a 500 MB exe isn't).
    -- Another build still runs, with a warning: function and field names may have changed. (From appdoze's PR #2.)
    local KNOWN_BUILDS = {
        [511072344] = "Steam build 26266538",
        [498913272] = "Steam build 26367565",     -- the 2026-11-04 update
    }
    pcall(function()
        local f = io.open(modRoot() .. "../../../PBZ.exe", "rb")
        if not f then
            return
        end
        local size = f:seek("end")
        f:close()
        if KNOWN_BUILDS[size] then
            log("Game build: " .. KNOWN_BUILDS[size] .. " (tested).")
        else
            api.gameBuildWarning = "this game update isn't tested with this Phantom Pact version; some co-op "
                .. "features may fail."
            log("WARNING: this game build (PBZ.exe " .. tostring(size) .. " bytes) wasn't tested with Phantom Pact "
                .. tostring(api.version) .. ". Co-op may partly fail; check for a Phantom Pact update.")
        end
    end)

    local function readText(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local text = f:read("a")
        f:close()
        return text
    end

    local function writeText(path, text)
        local f = io.open(path, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    -- "Key = value" lines; ";" and "#" start comments.
    local function readSettings()
        local text = readText(modDir() .. "PhantomPact.ini")
        if not text then
            return nil
        end
        local s = {}
        for line in text:gmatch("[^\r\n]+") do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key and not line:match("^%s*[;#]") then
                s[key:lower()] = value
            end
        end
        return s
    end

    local settings = readSettings()
    if not settings then
        log("No PhantomPact.ini: co-op stays off (use the neton command to start it by hand).")
        return
    end
    if api.hud then
        api.hud.set((settings.partnercompass or "on"):lower() ~= "off")
    end
    if api.mapicon then
        api.mapicon.on = (settings.partnermapicon or "on"):lower() ~= "off"
    end
    if api.mapfog then
        api.mapfog.on = (settings.clearmapfog or "off"):lower() == "on"
    end
    if api.freetravel then
        api.freetravel.on = (settings.freebelltravel or "on"):lower() ~= "off"
    end
    if api.revive then
        api.revive.set((settings.revive or "off"):lower() == "on")
    end
    api.lang.set(settings.language)
    api.partner.teleport = (settings.partnerteleport or "off"):lower() == "on"
    if api.story then
        api.story.follow = (settings.followhoststory or "on"):lower() ~= "off"
    end
    local role = (settings.role or "off"):lower()
    os.remove(modDir() .. "pads_watch.txt")
    os.remove(modDir() .. "pads_want.txt")      -- left by a crash with a panel open: main.dll would think one still is
    if role == "local" then
        api.localcoop.start(tonumber(settings.joysticks) or 2)
        return
    end
    -- What stops co-op from starting. The player reads it in the game, once in the world: a log line is easy to miss.
    local setupTip = nil
    local function setupProblem(text)
        log(text)
        setupTip = text
    end

    -- What the ini says about reaching the partner in this role, or nil and what's wrong.
    local function connection(s, wanted)
        local c = { role = wanted, modRole = ({ host = "host", guest = "client" })[wanted] }
        if not c.modRole then
            return nil, "PhantomPact.ini: Role = " .. tostring(s.role) .. ", co-op is off."
        end
        c.port = tonumber(s.port) or 47800
        -- Connect = Steam (P2P through Steam, friends only) or Tailscale (UDP to the host's IP). Old inis have no
        -- Connect line and keep working over Tailscale.
        c.steam = (s.connect or "tailscale"):lower() == "steam"
        c.hostAddress = s.hostaddress or ""
        if c.hostAddress == placeholder then
            c.hostAddress = ""
        end
        if c.steam then
            -- Optional for Steam: the host's Steam name (or SteamID64); empty finds any friend hosting in the game.
            -- An address kept here for Tailscale isn't a name, so it counts as empty.
            if c.hostAddress:match("^%d+%.%d+%.%d+%.%d+$") or c.modRole == "host" then
                c.hostAddress = ""
            end
            -- Names go on the command line in quotes, so characters cmd.exe treats specially are refused.
            if c.hostAddress:find('[%"%%&|<>^]') then
                return nil, "PhantomPact.ini: HostAddress has a character that can't be used (\" % & | < > ^). Leave it empty to join any friend who's hosting."
            end
        elseif c.modRole == "client" and (c.hostAddress == "" or not c.hostAddress:match("^[%w%.%-:]+$")) then
            return nil, "PhantomPact.ini: HostAddress isn't set. Put the host's Tailscale IP there, or use Steam."
        end
        return c
    end

    -- The relay's thread waits for net_start.txt, which appears whole thanks to the rename. It reads the Secret and the
    -- settings both players should share from the ini itself.
    -- The Secret counts unless it's empty or a placeholder (the relay's own test, relay.hpp).
    local function signed(s)
        local secret = (s.secret or ""):lower()
        return secret ~= "" and not secret:find("^put%-") and secret ~= "off" and secret ~= "none"
    end

    local function startRelay(c, s)
        if not api.link then
            setupProblem("Couldn't start the relay: dlls\\main.dll can't be reached. Reinstall Phantom Pact, check your antivirus didn't remove it, and use the UE4SS build from the install guide.")
            return false
        end
        local lines = { "role=" .. c.modRole, "port=" .. c.port, "transport=" .. (c.steam and "steam" or "udp"),
            "version=" .. (api.version or "?") }
        if c.modRole == "client" and c.hostAddress ~= "" then
            lines[#lines + 1] = "peer=" .. c.hostAddress
        end
        local path = modDir() .. "net_start.txt"
        writeText(path .. ".tmp", table.concat(lines, "\n") .. "\n")
        os.remove(path)
        if not os.rename(path .. ".tmp", path) then
            setupProblem("Couldn't start the relay: net_start.txt can't be written in " .. modDir())
            return false
        end
        local joining = c.modRole ~= "client" and ""
            or c.hostAddress ~= "" and (", joining " .. c.hostAddress)
            or ", looking for a Steam friend who's hosting"
        log("Relay started as " .. c.role .. joining .. (c.steam and " over Steam" or (" on UDP " .. c.port))
            .. (signed(s) and ", packets signed (Secret set)" or "") .. ".")
        return true
    end

    local current = nil             -- the connection asked for; .settings is the ini it came from, .on once sync is on

    -- The relay asked for has spoken, if only to say it failed (status.lua tells the player), and not the run before it.
    local function relayReady()
        local line = api.link and api.link.status()
        return line ~= nil and line:find("role=" .. current.modRole .. " ", 1, true) ~= nil
    end

    -- Sync on once the relay has answered and the player is in the world.
    LoopInGameThreadWithDelay(500, function()
        if setupTip then
            pcall(function()
                local _, pawn = getPlayer1()
                if valid(pawn) then
                    api.status.notify("setup", setupTip)
                    setupTip = nil
                end
            end)
        end
        if not current or current.on then
            return false    -- (returning true doesn't end this kind of loop in this UE4SS)
        end
        pcall(function()
            local _, pawn = getPlayer1()
            if valid(pawn) and relayReady() then
                current.on = true
                local s = current.settings
                neton(current.modRole)
                api.partner.goOnLink(current.modRole == "client")
                log("Phantom Pact " .. (current.modRole == "host" and "Host" or "Guest") .. ": co-op on.")
                if api.twins and s.ghosttwins and s.ghosttwins ~= "" then
                    api.twins.setFrom(s.ghosttwins)
                end
                if api.scaling and (tonumber(s.coopenemyhealth) or tonumber(s.coopenemyposture)) then
                    -- (Whole numbers: %d throws on 150.5, and the throw skipped the PvP settings below too.)
                    -- (And finite, in range: 1e999 threw the same way.)
                    local function whole(v, default)
                        v = tonumber(v)
                        if not v or v ~= v then
                            return default
                        end
                        return math.floor(math.max(1, math.min(1000, v)))
                    end
                    api.scaling.command(string.format("%d %d", whole(s.coopenemyhealth, 150), whole(s.coopenemyposture, 130)))
                end
                if api.scaling and tonumber(s.coopbosspoise) then
                    api.scaling.bossPoiseCommand(tostring(math.floor(math.max(100, math.min(1000, tonumber(s.coopbosspoise))))))
                end
                if api.pvp then
                    if tonumber(s.pvpdamage) then
                        api.pvp.command("damage " .. s.pvpdamage)
                    end
                    if tonumber(s.pvpparryposture) then
                        api.pvp.command("parry " .. s.pvpparryposture)
                    end
                    if (s.pvp or ""):lower() == "on" then
                        api.pvp.set(true)
                    end
                end
            end
        end)
        return false
    end)

    -- Everything the online panel does to the connection. Stopping is sync first, then the relay. The start file goes
    -- before the stop: main.dll reads them the other way round, so a Leave can't be lost whenever it lands (run_from).
    local function stopOnline()
        current = nil
        if api.coop.net.enabled then
            api.coop.commands.netoff()
        end
        api.status.last = {}
        api.status.here = nil     -- (who was in the party: the next session's first look told them all "left")
        os.remove(modDir() .. "net_start.txt")
        if api.link then
            api.link.stop()
        end
    end

    api.online = {
        settings = readSettings,
        connection = connection,
        signed = signed,
        current = function()
            return current
        end,
        stop = stopOnline,
        start = function(c, s)
            stopOnline()
            c.settings = s
            if startRelay(c, s) then
                current = c
            end
        end,
    }

    if role ~= "local" and (settings.onlinepanel or "on"):lower() == "on" then
        api.onlinepanel.start()
    end
    -- Also with Role = Off: the panel can start co-op later, and F3 only acts once connected.
    if role ~= "local" then
        api.partner.start()
    end

    local c, why = connection(settings, role)
    if not c then
        if role == "host" or role == "guest" then
            setupProblem(why)
        else
            log(why)
        end
        return
    end
    c.settings = settings
    if startRelay(c, settings) then
        current = c
    end
end
