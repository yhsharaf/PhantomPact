-- The host's rules count for everyone (the user: "the host should be in control for everything"): Free Bell Travel,
-- TP > Partner, PvP, and the Partner Compass and Partner On The Map too ("for pvp maybe people want to surprise the
-- others"). Steam Direct (a player's own IP) and Mode (their own PC) stay each player's own; Players was the host's.
--
-- The host says its rules as "RULES ft=<0|1> tp=<0|1> pvp=<0|1> cp=<0|1> mi=<0|1>" at once when one changes, and to anyone
-- who (re)starts sync or comes back from a gap. A guest follows them while it's linked to that host, keeps its own choices
-- aside meanwhile, and goes back to them when the link ends or it hosts itself. The MORE page shows a guest the host's
-- choice and won't change it there.
--
-- ClearMapFog too (the user, 11-06: "keep it off but the host can make it go away if he wants to"): "fog=<0|1>" on the end.
-- A host of an older version doesn't say it, and the fog stays.

return function(api)
    local log, coop = api.log, api.coop
    local net = coop.net

    local rules = { host = nil }    -- the host's, while this guest follows them: { freetravel, teleport, pvp }
    local own = nil                 -- this player's own, kept aside meanwhile
    local sentText = nil            -- what was said last: nil, said again at once

    local function current()
        return {
            freetravel = not (api.freetravel and api.freetravel.on == false),
            teleport = api.partner and api.partner.teleport == true or false,
            pvp = api.pvp and api.pvp.on == true or false,
            compass = not (api.hud and api.hud.on == false),
            mapicon = not (api.mapicon and api.mapicon.on == false),
            mapfog = api.mapfog and api.mapfog.on == true or false,
        }
    end

    local function apply(r)
        if api.freetravel then
            api.freetravel.on = r.freetravel
        end
        if api.partner then
            api.partner.teleport = r.teleport
        end
        if api.pvp and api.pvp.on ~= r.pvp and not (r.pvp and net.party) then
            api.pvp.set(r.pvp)
        end
        if api.hud and api.hud.set then
            api.hud.set(r.compass)
        end
        if api.mapicon then
            api.mapicon.on = r.mapicon
        end
        if api.mapfog then
            api.mapfog.on = r.mapfog == true
        end
    end

    local function onOff(v)
        return v and "on" or "off"
    end

    -- True while this player follows the host's rules: the MORE page shows those and won't change them.
    function rules.following()
        return rules.host ~= nil
    end

    coop.handlers.RULES = function(rest, from)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" then
            return              -- (only the host's own word, and never on the host)
        end
        local r = {}
        for key, value in rest:gmatch("(%a+)=([01])") do
            r[key] = value == "1"
        end
        if r.ft == nil or r.tp == nil or r.pvp == nil or r.cp == nil or r.mi == nil then
            return
        end
        local got = { freetravel = r.ft, teleport = r.tp, pvp = r.pvp, compass = r.cp, mapicon = r.mi, mapfog = r.fog == true }
        own = own or current()
        local h = rules.host
        if not h or h.freetravel ~= got.freetravel or h.teleport ~= got.teleport or h.pvp ~= got.pvp
            or h.compass ~= got.compass or h.mapicon ~= got.mapicon or h.mapfog ~= got.mapfog then
            log(string.format("The host's rules: Free Bell Travel %s, TP > Partner %s, PvPvE %s, Partner Compass %s, "
                .. "Partner On The Map %s, Clear Map Fog %s.", onOff(got.freetravel), onOff(got.teleport), onOff(got.pvp),
                onOff(got.compass), onOff(got.mapicon), onOff(got.mapfog)))
        end
        rules.host = got
        apply(got)
    end

    -- The guest's own rules back (sync stopped, or it hosts now).
    function rules.release()
        if rules.host then
            log("Back to your own rules: the link to the host ended.")
            rules.host = nil
            apply(own)
            own = nil
        end
        sentText = nil
    end

    local function tick()
        local linked = net.enabled and not net.partnerGone
        if coop.isHost() then
            if rules.host then              -- (was a guest, hosts now: its own again)
                rules.release()
            end
            if not linked then
                sentText = nil
                return
            end
            local c = current()
            local function bit(v)
                return v and 1 or 0
            end
            local text = string.format("ft=%d tp=%d pvp=%d cp=%d mi=%d fog=%d", bit(c.freetravel), bit(c.teleport),
                bit(c.pvp), bit(c.compass), bit(c.mapicon), bit(c.mapfog))
            if text ~= sentText then
                sentText = text
                coop.sendEvent("RULES", text)
            end
        elseif rules.host and not net.enabled then
            rules.release()
        end
    end

    -- Someone (re)started sync, or joined the party (their S reaches the host): they hear the rules at once. Only then: the
    -- sure lane brings a telling to everyone linked, and the one every 5 s that this replaced told nobody anything new.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        sentText = nil
        return syncStarted(rest, from)
    end

    coop.extraTicks.rules = function()
        local ok, err = pcall(tick)
        if not ok and err ~= rules.lastError then
            rules.lastError = err
            log("rules: " .. tostring(err))
        end
    end

    return rules
end
