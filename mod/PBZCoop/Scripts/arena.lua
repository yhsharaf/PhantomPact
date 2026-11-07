-- PvP (F6): a match in one of four boss arenas, or wherever the host stands (docs/PVP.md).
--
-- The host runs the match: who is in it, the rounds, the score, the clock. Each player's own world decides the hits that land
-- on them (pvp.lua: the others' figures swing for real there) and says when they're down. Nothing a match changes is ever
-- saved: the game's own save veto is up from the arrival till everything is put back, a weapon a player didn't own goes back
-- to nobody, and pvp_restore.txt next to the mod says where home was, for a crash in the middle.
--
-- One event kind, AR, so older versions ignore all of it:
--   AR lobby <mode> <timer> <place> <slot>:<team>:<ready>:<arenas> ...   host: the lobby as it stands
--   AR pick <team> <ready> <arenas> <version> <loadout>                a player: their team, ready, arenas, loadout
--   AR start <id> <mode> <timer> <place> <x> <y> <z> <yaw> <map> <slot>:<team>:<spot>:<loadout> ...   host: go
--                                                                      (the middle is the host's spot, for "here")
--   AR here <id> <what>                                                a player: there (in the arena, set up) | home
--   AR count <id> <round>                                              host: the countdown starts
--   AR down <id> <round> <by>                                          a player: down this round (by: who struck last)
--   AR round <id> <round> <winner> <crimson> <azure>                   host: a round's result (winner 0: a draw)
--   AR end <id> <winner> <crimson> <azure>                             host: the match's result
--   AR fin <id> <victim> <move> <x> <y> <z> <yaw>                     a winner: the finishing blow on a fallen player
--                                                                      (move: arenas.lua's FINISHERS; where they stand)
--   AR home <id>                                                       host: everyone goes back
--   AR quit <id> <why>                                                 anyone: leaving, or called off

return function(api)
    local log, valid, game, coop = api.log, api.valid, api.game, api.coop
    local net = coop.net
    local data = api.arenaData

    local MODES = { duel = true, death = true }
    local TIMERS = { [0] = true, [60] = true, [90] = true, [120] = true }
    local TEAM_NAMES = { "Crimson", "Azure" }
    local DUEL_WINS = 2             -- rounds a team needs in a duel
    local COUNT_S = 3.0             -- the countdown before each round: 3, 2, 1
    local FIGHT_SHOW_S = 0.9        -- then 斗 on screen this long, the fight already on
    local BETWEEN_S = 3.5           -- a round's result on screen before the next countdown
    local FINISH_S = 7.0            -- the finishing window: the winners' time to finish a fallen enemy...
    local FINISH_LATE_S = 1.5       -- ...but for its end, so their move reaches everyone before the window closes there
                                    -- (the bench: a move 5.5 s in found the loser's screen already on its death card)
    local RESULT_S = 6.0            -- the golden screen, the death card
    local SILENT_S = 8.0            -- a player not heard this long: the match is off
    local TRAVEL_S = 120            -- the longest a trip to the arena may take
    local SETUP_S = 45              -- the longest the host waits for everyone to be there after that
    local DOWN_HP = 1.5             -- health at or under this is down (the floor holds it at 1)
    local FALL_CM = 1500            -- this far under the arena's floor: fallen off, down
    local KEEP_S = 0.5              -- the fair stats written again this often
    local AREA_S = 1.0              -- enemies parked, walls up, bars down: looked at this often
    local PARK_CM = 9000            -- enemies within this of the middle are parked
    local LEAVE_S = 3.0             -- a second LEAVE within this ends it
    local SETTLE_S = 1.8            -- skill nodes take this long to show in the stats
    local LAND_S = 1.2              -- held in the air at the spot this long, the ground streaming in
    local NEAR_CM = 5000            -- nearer than this on the same map: no trip, a hop. Further, the game's own trip (its
                                    -- loading screen sets the player down once the ground is in): a 280 m hop to the
                                    -- Gold-Masked One's gorge on the bench landed before its floor had loaded, and fell.
    local INVULNERABLE = "GE_PBZLieInvulnerable_C"
    local SAVE_VETO = { { "PhantomPactPvP", 0 }, { "PhantomPactPvP2", 2 } }   -- 0 stops the quiet autosave, 2 bells and trips
    local RISE = "/Game/PBZContent/UI/InGame/Dead/GA_PlayerRespawn"

    local arena = {
        mode = "duel",              -- the host's choices
        timer = 0,
        place = 0,                  -- data.arenas index, 0 = here (every save has it)
        lobby = nil,                -- what the host said last (a guest): { mode, timer, place, players = { [slot] = pick } }
        picks = {},                 -- host: slot -> { team, ready, arenas, version }
        pick = { team = nil, ready = false },     -- this player's own
        match = nil,                -- the match this player is in
        preset = nil,               -- this player's loadout: { main = { id, id }, edge = { id, id } }
        unlocked = {},              -- arena key -> true: this save has that boss beaten
    }
    local saved = nil               -- what this player had before the match (see setup / goHome)
    local parked = {}               -- address -> { name, home }: enemies put aside for the match
    local leaveAskedAt = -1e9

    ------------------------------------------------------------------ who's who

    local function mySlot()
        if net.party then
            return net.slot or 1
        end
        return coop.isHost() and 1 or 2
    end

    -- Who sent an event: tagged, a guest in a party; untagged, the host there, or with two players the partner.
    local function senderSlot(from)
        if from then
            return from
        end
        if net.party then
            return 1
        end
        return coop.isHost() and 2 or 1
    end

    local function peerSlot(p)
        if net.party then
            return p.number
        end
        return coop.isHost() and 2 or 1
    end

    -- Everyone linked now, this player too, in slot order.
    local function everyone()
        local out = { mySlot() }
        for _, p in ipairs(coop.partners()) do
            if p.lastRemoteAt and not p.partnerGone and p.target then
                out[#out + 1] = peerSlot(p)
            end
        end
        table.sort(out)
        return out
    end
    arena.everyone = everyone
    arena.mySlot = mySlot

    local function peerBySlot(slot)
        for _, p in ipairs(coop.partners()) do
            if peerSlot(p) == slot then
                return p
            end
        end
        return nil
    end

    local function tip(text)
        log("PvP: " .. text)
        if api.status and api.status.notify then
            api.status.notify("arena", text)
        end
    end

    local function ui()
        return api.arenaui
    end

    local function teamName(team)
        return TEAM_NAMES[team] or "?"
    end
    arena.teamName = teamName

    local function playerName(slot)
        local p = coop.players and coop.players[slot]
        return p and p.name or ("player " .. slot)
    end

    ------------------------------------------------------------------ loadout

    local function presetPath()
        return api.modDir() .. "pvp_preset.txt"
    end

    -- A loadout is two weapons and two Phantom Edge weapons the game knows; anything else is the default's.
    local function cleanPreset(p)
        local out = { main = {}, edge = {} }
        for i = 1, 2 do
            local m = p and p.main and p.main[i]
            out.main[i] = (m and data.weapon(m)) and m or data.DEFAULT.main[i]
            local e = p and p.edge and p.edge[i]
            out.edge[i] = (e and data.edge(e)) and e or data.DEFAULT.edge[i]
        end
        if out.main[1] == out.main[2] then
            out.main[2] = out.main[1] == data.DEFAULT.main[2] and data.DEFAULT.main[1] or data.DEFAULT.main[2]
        end
        if out.edge[1] == out.edge[2] then
            out.edge[2] = out.edge[1] == data.DEFAULT.edge[2] and data.DEFAULT.edge[1] or data.DEFAULT.edge[2]
        end
        return out
    end

    local function presetText(p)
        p = p or arena.preset or data.DEFAULT
        return table.concat({ p.main[1], p.main[2], p.edge[1], p.edge[2] }, ",")
    end

    local function presetFrom(text)
        local a, b, c, d = (text or ""):match("^([%w_]+),([%w_]+),([%w_]+),([%w_]+)$")
        if not a then
            return nil
        end
        return cleanPreset({ main = { a, b }, edge = { c, d } })
    end

    function arena.loadPreset()
        local p = { main = {}, edge = {} }
        local f = io.open(presetPath(), "r")
        if f then
            for line in f:lines() do
                local key, n, id = line:match("^%s*(%a+)(%d)%s*=%s*(%S+)")
                if (key == "main" or key == "edge") and tonumber(n) then
                    p[key][tonumber(n)] = id
                end
            end
            f:close()
        end
        arena.preset = cleanPreset(p)
        return arena.preset
    end

    function arena.savePreset(p)
        arena.preset = cleanPreset(p or arena.preset)
        local f = io.open(presetPath(), "w")
        if f then
            f:write("; Your PvP loadout (F6). Ids from the game's own weapon tables; the F6 page writes this.\n")
            for i = 1, 2 do
                f:write("main" .. i .. " = " .. arena.preset.main[i] .. "\n")
            end
            for i = 1, 2 do
                f:write("edge" .. i .. " = " .. arena.preset.edge[i] .. "\n")
            end
            f:close()
        end
        -- Told again (a guest's pick carries it): changed after READY, the other worlds lent and raised the old weapons.
        if arena.setPick and net.enabled and not coop.isHost() then
            arena.setPick(nil, nil)
        end
        return arena.preset
    end

    ------------------------------------------------------------------ which arenas this save has

    -- The game's own record of each spawner's enemy (SGameAIWorldSubsystem.SpawnerSaveData, kept for every map): a boss's
    -- arena is open once one of its spawners says dead.
    function arena.readUnlocked()
        local open = {}
        local ok = pcall(function()
            local ai = FindFirstOf("PBZAISaveGameWorldSubsystem")
            if not valid(ai) then
                return
            end
            local want = {}
            for _, a in ipairs(data.arenas) do
                for _, key in ipairs(a.unlock) do
                    want[key] = a.key
                end
            end
            ai.SpawnerSaveData:ForEach(function(k, v)
                local key = k:get()
                key = type(key) == "string" and key or key:ToString()
                local which = want[key]
                if which then
                    local alive = true
                    pcall(function() alive = v:get().IsAlive end)
                    if alive == false then
                        open[which] = true
                    end
                end
            end)
        end)
        if ok then
            arena.unlocked = open
        end
        return arena.unlocked
    end

    local function arenasText()
        local keys = {}
        for _, a in ipairs(data.arenas) do
            if arena.unlocked[a.key] then
                keys[#keys + 1] = a.key
            end
        end
        return #keys > 0 and table.concat(keys, ",") or "-"
    end

    ------------------------------------------------------------------ the lobby (host)

    local function hostPick()
        local p = arena.picks[mySlot()] or {}
        p.team = arena.pick.team or p.team
        p.ready = true                  -- the host is ready by starting
        p.arenas = arenasText()
        p.version = api.version
        p.preset = presetText()
        arena.picks[mySlot()] = p
        return p
    end

    -- Teams nobody picked: the host Crimson; with two players the other Azure; in a party the smaller side.
    local function fillTeams()
        local slots = everyone()
        -- The picks of players who left the party go (a new player in that slot inherited their READY, version and
        -- loadout). Not those of one quiet a moment, in a loading screen: still a partner.
        local inParty = { [mySlot()] = true }
        for _, p in ipairs(coop.partners()) do
            inParty[peerSlot(p)] = true
        end
        for s in pairs(arena.picks) do
            if not inParty[s] then
                arena.picks[s] = nil
            end
        end
        -- Two players: one team each, whatever was picked before (left over from a party, both on one side, the page
        -- refusing a change with two rows: it never started; the review of 1.7.0).
        if #slots == 2 then
            for _, s in ipairs(slots) do
                local p = arena.picks[s] or {}
                arena.picks[s] = p
                p.team = s == mySlot() and 1 or 2
            end
            return
        end
        local count = { 0, 0 }
        for _, s in ipairs(slots) do
            local p = arena.picks[s]
            if p and p.team then
                count[p.team] = count[p.team] + 1
            end
        end
        for _, s in ipairs(slots) do
            local p = arena.picks[s] or {}
            arena.picks[s] = p
            if not p.team then
                if #slots == 2 then
                    p.team = s == mySlot() and 1 or 2
                else
                    p.team = count[1] <= count[2] and 1 or 2
                end
                count[p.team] = count[p.team] + 1
            end
        end
    end

    local function lobbyText()
        local parts = {}
        for _, s in ipairs(everyone()) do
            local p = arena.picks[s] or {}
            parts[#parts + 1] = string.format("%d:%d:%d:%s", s, p.team or 0, p.ready and 1 or 0, p.arenas or "?")
        end
        return string.format("%s %d %d %s", arena.mode, arena.timer, arena.place, table.concat(parts, " "))
    end

    local lobbySent = nil
    function arena.sendLobby(force)
        if not coop.isHost() or not net.enabled then
            return
        end
        hostPick()
        fillTeams()
        local text = lobbyText()
        if force or text ~= lobbySent then
            lobbySent = text
            coop.sendEvent("AR", "lobby", text)
        end
    end

    -- Why the host can't start yet, or nil.
    function arena.blocker()
        if not net.enabled then
            return "Play online first (F5): PvP is between linked players."
        end
        if not coop.isHost() then
            return "The host starts the match."
        end
        if arena.restoring then
            return "Putting the last match back: a moment."
        end
        local slots = everyone()
        if #slots < 2 then
            return "Nobody to fight: a partner needs to be linked."
        end
        fillTeams()
        local count = { 0, 0 }
        for _, s in ipairs(slots) do
            local p = arena.picks[s]
            if s ~= mySlot() then
                if not p or p.version == nil then
                    return playerName(s) .. " needs Phantom Pact " .. api.version .. " for PvP."
                end
                if p.version ~= api.version then
                    return playerName(s) .. " is on Phantom Pact " .. p.version .. ": everyone needs " .. api.version .. "."
                end
                if not p.ready then
                    return "Waiting for " .. playerName(s) .. " to be ready."
                end
            end
            count[p.team] = count[p.team] + 1
        end
        if count[1] == 0 or count[2] == 0 then
            return "Both teams need someone."
        end
        local a = data.arena(arena.place)
        if arena.place > 0 then
            for _, s in ipairs(slots) do
                local p = arena.picks[s] or {}
                local have = (s == mySlot() and arena.unlocked[a.key]) or (p.arenas or ""):find(a.key, 1, true)
                if not have then
                    return playerName(s) .. " hasn't beaten " .. a.boss .. " yet: that arena opens after the fight."
                end
            end
        else
            local _, pawn = api.getPlayer1()
            local here = valid(pawn) and game.mapName(pawn) or "?"
            for _, s in ipairs(slots) do
                local p = s ~= mySlot() and peerBySlot(s)
                if p and p.target and p.target.Map and net.localMap and p.target.Map ~= net.localMap then
                    return playerName(s) .. " is on another map: for Here, everyone on " .. here .. " (F3 takes you to a partner)."
                end
            end
        end
        return nil
    end

    -- The host's choices, from the F6 page or a command.
    function arena.choose(what, value)
        if what == "mode" and MODES[value] then
            arena.mode = value
        elseif what == "timer" and TIMERS[tonumber(value) or -1] then
            arena.timer = tonumber(value)
        elseif what == "place" and tonumber(value) and (tonumber(value) == 0 or data.arenas[tonumber(value)]) then
            arena.place = tonumber(value)
        end
        arena.sendLobby()
    end

    -- This player's team and ready, told to the host (the host's own is kept here).
    function arena.setPick(team, ready)
        if team == 1 or team == 2 then
            arena.pick.team = team
        end
        if ready ~= nil then
            arena.pick.ready = ready and true or false
        end
        if coop.isHost() then
            arena.sendLobby()
        elseif net.enabled then
            coop.sendEvent("AR", "pick", arena.pick.team or 0, arena.pick.ready and 1 or 0, arenasText(), api.version, presetText())
        end
    end

    ------------------------------------------------------------------ this player's world: bodies

    local function pawnNow()
        local pc, pawn = api.getPlayer1()
        return pc, pawn
    end

    local function asc(actor)
        local ok, a = pcall(function()
            return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(actor)
        end)
        return ok and valid(a) and a or nil
    end

    local function componentOf(actor, className)
        local addr = actor:GetAddress()
        for _, c in ipairs(FindAllOf(className) or {}) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                return c
            end
        end
        return nil
    end

    local function setVeto(on)
        local saves = FindFirstOf("PBZSaveLoadSubsystem")
        if not valid(saves) then
            return
        end
        for _, v in ipairs(SAVE_VETO) do
            pcall(function()
                if on then
                    saves:EnterSaveVeto(FName(v[1]), v[2])
                else
                    saves:ExitSaveVeto(FName(v[1]))
                end
            end)
        end
        arena.vetoed = on
    end

    local function shield(pawn, on)
        local a = asc(pawn)
        if not a then
            return
        end
        pcall(function()
            if on and not arena.shielded then
                local cls = FindObject("BlueprintGeneratedClass", INVULNERABLE)
                arena.shielded = a:BP_ApplyGameplayEffectToSelf(cls, 1, a:MakeEffectContext())
            elseif not on and arena.shielded then
                a:RemoveActiveGameplayEffect(arena.shielded, -1)
                arena.shielded = nil
            end
        end)
    end

    local function hold(pawn, on)
        local pc = pawnNow()
        pcall(function()
            if on then
                pawn:DisableInput(pc)
            else
                pawn:EnableInput(pc)
            end
        end)
        arena.held = on
    end

    -- Down: the body falls loose (no real death: that sends a player to the bell). Up again: the mesh back on its capsule as it
    -- was, and the game's own getting-up.
    local meshAt = {}
    function arena.fall(body, on)
        if not valid(body) then
            return
        end
        local addr = body:GetAddress()
        pcall(function()
            local mesh = body.Mesh
            if on then
                if meshAt[addr] == nil then
                    local l, r = mesh.RelativeLocation, mesh.RelativeRotation
                    meshAt[addr] = { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
                end
                mesh:SetSimulatePhysics(true)
            elseif meshAt[addr] then
                local was = meshAt[addr]
                meshAt[addr] = nil
                mesh:SetSimulatePhysics(false)
                mesh:K2_AttachToComponent(body.CapsuleComponent, FName("None"), 0, 0, 0, true)
                mesh:K2_SetRelativeLocationAndRotation(was.loc, was.rot, false, {}, true)
            end
        end)
    end

    local function rise(pawn)
        local class = StaticFindObject(RISE .. ".GA_PlayerRespawn_C")
        if not valid(class) and type(LoadAsset) == "function" then
            pcall(LoadAsset, RISE)
            class = StaticFindObject(RISE .. ".GA_PlayerRespawn_C")
        end
        local a = asc(pawn)
        if valid(class) and a then
            pcall(function() a:TryActivateAbilityByClass(class, true) end)
        end
    end

    -- Put on a spot: flying a moment while the ground comes in, then walking (a plain teleport fell through unloaded ground).
    local function land(pawn, spot)
        local pc = pawnNow()
        pcall(function()
            pawn.CharacterMovement:SetMovementMode(5, 0)
            pawn:K2_SetActorLocationAndRotation({ X = spot.X, Y = spot.Y, Z = spot.Z + 120 },
                { Pitch = 0, Yaw = spot.Yaw or 0, Roll = 0 }, false, {}, true)
            if valid(pc) then
                pc:SetControlRotation({ Pitch = -8, Yaw = spot.Yaw or 0, Roll = 0 })
            end
        end)
        game.after(LAND_S, function()
            if not valid(pawn) then
                return
            end
            pcall(function() pawn.CharacterMovement:SetMovementMode(1, 0) end)
            -- A short step the way it faces: set by hand, the body kept showing the old way till it moved (the bench, a guest
            -- turned round for its side: its front to its own camera).
            local yaw, n = math.rad(spot.Yaw or 0), 0
            local function step()
                n = n + 1
                if n <= 8 and valid(pawn) then
                    pcall(function() pawn:AddMovementInput({ X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }, 0.6, false) end)
                    game.after(0.03, step)
                end
            end
            step()
        end)
    end

    local function locOf(actor)
        local ok, l = pcall(function() return actor:K2_GetActorLocation() end)
        return ok and l or nil
    end

    local function flatDist(a, b)
        local dx, dy = a.X - b.X, a.Y - b.Y
        return math.sqrt(dx * dx + dy * dy)
    end

    ------------------------------------------------------------------ this player's world: fair play

    -- (A table too: the simulator's stand-in for the game's struct, so the match's stats are held and put back there as well.)
    local function attr(pawn, name)
        local ok, a = pcall(function() return pawn.AttributeSetBase[name] end)
        return ok and (type(a) == "userdata" or type(a) == "table") and a or nil
    end

    -- An attribute to exactly `want`, whatever adds to it: its base moved by what the rest made of the last one.
    local function fit(pawn, name, want)
        local a = attr(pawn, name)
        if not a then
            return
        end
        pcall(function()
            local base, cur = a.BaseValue, a.CurrentValue
            if math.abs(cur - want) < 0.5 then
                return
            end
            local ratio = (base > 0 and cur > 0) and cur / base or 1
            a.BaseValue = want / ratio
            a.CurrentValue = want
        end)
    end

    local function keepFair(pawn)
        for name, want in pairs(data.STATS) do
            fit(pawn, name, want)
        end
        game.setMinHealth(pawn, 1)
    end

    local function activeNodes(nodes)
        local out = {}
        pcall(function()
            nodes.AbilityNodeMap:ForEach(function(k)
                local id = k:get():ToString()
                if nodes:IsActivateAbilityNode(FName(id)) then
                    out[#out + 1] = id
                end
            end)
        end)
        return out
    end

    local function namesOf(arr)
        local out = {}
        pcall(function()
            for _, v in ipairs(arr) do
                local okG, g = pcall(function() return v:get() end)
                local n = okG and g or v
                n = type(n) == "string" and n or n:ToString()
                if n ~= "None" then
                    out[#out + 1] = n
                end
            end
        end)
        return out
    end

    local function journal(lines)
        local f = io.open(api.modDir() .. "pvp_restore.txt", "w")
        if f then
            f:write("; A PvP match was on: Phantom Pact puts this back on the next start, then deletes this file.\n")
            for k, v in pairs(lines) do
                f:write(k .. " = " .. tostring(v) .. "\n")
            end
            f:close()
        end
    end

    local function dropJournal()
        os.remove(api.modDir() .. "pvp_restore.txt")
    end

    -- Everything the match changes, noted first; then the weapons, the loadout, every skill node, the gourd.
    local function setup(pawn, m)
        setVeto(true)
        -- (Each of the match's stats as it is now, before anything of the match: see restore.)
        saved.cur = {}
        for name in pairs(data.STATS) do
            local at = attr(pawn, name)
            if at then
                pcall(function() saved.cur[name] = at.CurrentValue end)
            end
        end
        local bp = game.backpackOf(pawn)
        saved.mainOwned, saved.edgeOwned = {}, {}
        local p = arena.preset or arena.loadPreset()
        -- (Each step on its own: one the game refuses mustn't stop the rest, nor the match.)
        if bp and not pcall(function()
            for _, id in ipairs(namesOf(bp:GetAllNormalWeapons())) do
                saved.mainOwned[id] = true
            end
            for _, id in ipairs(namesOf(bp:GetAllShaqiWeapons())) do
                saved.edgeOwned[id] = true
            end
        end) then
            log("PvP: this game's bag can't be read: the loadout stays as it is.")
            bp = nil
        end
        saved.levels, saved.loans = {}, {}
        if bp then
            -- Every weapon anyone fights with, at the top level in this world. The blows this player takes are worked out here,
            -- from this world's own level of the weapon that lands them (the bench: a defender whose Tang was at level 11 took
            -- twice the damage of one at level 1, 256 to 128): so all at one level, everywhere. One this player doesn't own is
            -- lent for the match. (UpgradeWeapon and ResetWeaponToLevel only set the level: no dust, nothing in the bag.
            -- Only the game's own upgrade raises it cleanly: ResetWeaponToLevel won't go up, and the bag's level written by
            -- hand, or that reset asked to go up, crashed both bench copies' next match within a second, a call to nothing.
            -- The upgrade to 30 does give a Phantom Edge's "Skill Over Strength" achievement to a player without it.)
            local want = {}
            local function add(pr)
                for i = 1, 2 do
                    want["main:" .. pr.main[i]] = true
                    want["edge:" .. pr.edge[i]] = true
                end
            end
            add(p)
            for _, pr in pairs(m and m.presets or {}) do
                add(pr)
            end
            for key in pairs(want) do
                local kind, id = key:match("^(%a+):(.+)$")
                local main = kind == "main"
                local owned = (main and saved.mainOwned or saved.edgeOwned)[id]
                pcall(function()
                    if not owned then
                        bp:AddWeaponItem(FName(id), main, false, true, false)
                        saved.loans[#saved.loans + 1] = key
                    else
                        saved.levels[key] = bp:GetWeaponLevel(FName(id), main)
                    end
                end)
            end
            local main, edge = {}, {}
            for i = 1, 2 do
                main[i] = FName(p.main[i])
                edge[i] = FName(p.edge[i])
            end
            saved.pushed = pcall(function() bp:PushEquippedWeapons(main, edge, 0, 0) end)
            -- Up to the top level now, and again in a moment: one just lent can read level 0 till the game has it in the bag
            -- (the bench: lent ones raised in the same breath as the lending stayed at 1).
            local function raise(b)
                for key in pairs(want) do
                    local kind, id = key:match("^(%a+):(.+)$")
                    local isMain = kind == "main"
                    pcall(function()
                        local level = b:GetWeaponLevel(FName(id), isMain)
                        if level and level > 0 and level < data.WEAPON_LEVEL then
                            b:UpgradeWeapon(FName(id), isMain, data.WEAPON_LEVEL - level)
                        end
                    end)
                end
            end
            raise(bp)
            -- (Only while this same match is on: one called off within the moment was put back first, and raising after
            -- that left the player's own weapons at 30 for the save to keep.)
            local mine = saved
            for _, later in ipairs({ 0.5, 1.5 }) do
                game.after(later, function()
                    local _, now = pawnNow()        -- (the body asked for again: nothing kept across frames)
                    local b = valid(now) and game.backpackOf(now)
                    if b and saved == mine and arena.match == m then
                        raise(b)
                    end
                end)
            end
            -- The gourd: the healing one, the same for everyone, and only its drinks; the other bottle off for the match.
            pcall(function() saved.bottom = bp.BottomMedicineID:ToString() end)
            pcall(function() saved.top = bp.TopMedicineID:ToString() end)
            if saved.bottom and saved.bottom ~= data.GOURD and saved.bottom ~= "None" then
                pcall(function() bp:ReplaceMedicineByIndex(0, FName(data.GOURD), true) end)
            end
            local g = game.gourdInfo(pawn)
            pcall(function() saved.drinks = g.CurrentTime end)
            if saved.top and saved.top ~= "None" then
                pcall(function()
                    bp.MedicineInfos:ForEach(function(k, v)
                        if k:get():ToString() == saved.top then
                            saved.topDrinks = v:get().CurrentTime
                        end
                    end)
                    bp:TakeOffMedicineByIndex(1)
                end)
            end
        end
        -- Each skill node this player hasn't is put on for the match, one at a time, the game's way of buying one (called on
        -- the tree it costs nothing and needs no node before it; the bench, 11-07). Never the whole tree on and off: the
        -- game's DeactivateAllNodes took the player's own nodes too, their levels with them, and none of its ways back
        -- (ActivateNode by init, InitNodeStateByCharacter) put one on again. A match took a player's whole tree, and the next
        -- save kept that (the review of the talisman-slot reports). Each talisman slot is one node's (HeiShi2, ShaChiHuPo5,
        -- MemoryFlower7, TopRongShuZhiXin4): the match's own, off after it, never close one of the player's.
        local nodes = componentOf(pawn, "PBZAbilityNodesComponent")
        local a = asc(pawn)
        if valid(nodes) and a then
            saved.nodes, saved.added = activeNodes(nodes), {}
            local own, ids = {}, {}
            for _, id in ipairs(saved.nodes) do
                own[id] = true
            end
            pcall(function()
                nodes.AbilityNodeMap:ForEach(function(k)
                    ids[#ids + 1] = k:get():ToString()
                end)
            end)
            table.sort(ids)
            for _, id in ipairs(ids) do
                if not own[id] then
                    saved.added[#saved.added + 1] = id
                    pcall(function() nodes:ActivateNode(FName(id), a, false, true) end)
                end
            end
        end
        saved.attrs = {}
        for name in pairs(data.STATS) do
            local at = attr(pawn, name)
            if at then
                saved.attrs[name] = at.BaseValue
            end
        end
        local levels = {}
        for key, level in pairs(saved.levels) do
            levels[#levels + 1] = key .. "=" .. tostring(level)
        end
        journal({ map = saved.map, at = string.format("%.0f %.0f %.0f %.0f", saved.at.X, saved.at.Y, saved.at.Z, saved.yaw or 0),
            loans = #saved.loans > 0 and table.concat(saved.loans, ",") or "-", arena = saved.arenaAt,
            levels = #levels > 0 and table.concat(levels, ",") or "-", nodes = table.concat(saved.nodes or {}, ","),
            added = #(saved.added or {}) > 0 and table.concat(saved.added, ",") or "-" })
        -- The drinks once the gourd is the match's: a moment later (the game writes the count as it swaps).
        game.after(0.5, function()
            local _, now = pawnNow()
            local g = arena.match == m and valid(now) and game.gourdInfo(now)
            if g then
                pcall(function()
                    g:SetCurrentTime(data.DRINKS)
                    g:SetDisplayTime(data.DRINKS)
                end)
            end
        end)
    end

    -- All of it back (the match's skill nodes off, a moment for the game, then the health). Only what setup changed: a
    -- match called off before this player was set up (on the way there) leaves the skill tree alone. The timer asks for
    -- the body and its parts again: nothing kept across frames.
    local function restore(pawn, done)
        if not saved then
            if done then done() end
            return
        end
        local s = saved
        local bp = valid(pawn) and game.backpackOf(pawn)
        if bp then
            if s.pushed then
                pcall(function() bp:PopEquippedWeapons() end)
            end
            for key, level in pairs(s.levels or {}) do
                local kind, id = key:match("^(%a+):(.+)$")
                if level and level > 0 then
                    pcall(function() bp:ResetWeaponToLevel(FName(id), kind == "main", level, {}, {}) end)
                end
            end
            for _, loan in ipairs(s.loans or {}) do
                local kind, id = loan:match("^(%a+):(.+)$")
                pcall(function() bp:DisposeWeapon(FName(id), kind == "main") end)
            end
            if s.bottom and s.bottom ~= data.GOURD and s.bottom ~= "None" then
                pcall(function() bp:ReplaceMedicineByIndex(0, FName(s.bottom), false) end)
            end
            if s.top and s.top ~= "None" then
                pcall(function() bp:ReplaceMedicineByIndex(1, FName(s.top), false) end)
            end
        end
        for name, base in pairs(s.attrs or {}) do
            local at = valid(pawn) and attr(pawn, name)
            if at then
                pcall(function() at.BaseValue = base end)
            end
        end
        -- (The health floor stays at 1 till the health is back, below: let go at once, a loser lay at 1 health for the time
        -- the skill tree takes, and an enemy back at its post or a PvPvE partner's blow was a real death; the review.)
        -- Only the nodes the match put on go off, those still on: the player's own were never touched. (None if setup never
        -- reached the tree: a match called off on the way there.)
        local added = s.added or {}
        local nodes = #added > 0 and valid(pawn) and componentOf(pawn, "PBZAbilityNodesComponent")
        local a = nodes and asc(pawn)
        if valid(nodes) and a then
            for i = #added, 1, -1 do
                local id = FName(added[i])
                pcall(function()
                    if nodes:IsActivateAbilityNode(id) then
                        nodes:DeactivateNode(id, a)
                    end
                end)
            end
        end
        do
            game.after(SETTLE_S, function()
                local _, p = pawnNow()
                -- (Checked once the game has it: the player's own nodes all on, the match's all off. Said if not.)
                local n2 = s.nodes and valid(p) and componentOf(p, "PBZAbilityNodesComponent")
                if valid(n2) then
                    local wrong = {}
                    for _, id in ipairs(s.nodes) do
                        if select(2, pcall(function() return n2:IsActivateAbilityNode(FName(id)) end)) ~= true then
                            wrong[#wrong + 1] = id .. " off"
                        end
                    end
                    for _, id in ipairs(added) do
                        if select(2, pcall(function() return n2:IsActivateAbilityNode(FName(id)) end)) == true then
                            wrong[#wrong + 1] = id .. " still on"
                        end
                    end
                    if #wrong > 0 then
                        log("PvP: the skill tree isn't as it was before the match: " .. table.concat(wrong, ", ") .. ".")
                    end
                end
                -- (A stat still at the value the match held it to gets the player's own back: the base was written back
                -- above, but the game works a stat out again only when an effect on it changes, and on the bench (11-07)
                -- both players came home with the match's 160 attack over their own 100, stronger or weaker than their
                -- own till something made it count again. One whose own is the match's value is left as it is.)
                for name, want in pairs(data.STATS) do
                    local at = valid(p) and attr(p, name)
                    local cur0 = s.cur and s.cur[name]
                    if at and cur0 then
                        pcall(function()
                            if math.abs(at.CurrentValue - want) < 0.5 and math.abs(cur0 - want) >= 0.5 then
                                at.CurrentValue = cur0
                            end
                        end)
                    end
                end
                if valid(p) and s.attrs then
                    local _, maxhp = game.getHealth(p)
                    if maxhp then
                        game.setHealth(p, maxhp)
                    end
                    local g = game.gourdInfo(p)
                    if g and s.drinks then
                        pcall(function()
                            g:SetCurrentTime(s.drinks)
                            g:SetDisplayTime(s.drinks)
                        end)
                    end
                    local b = game.backpackOf(p)
                    if s.top and s.top ~= "None" and s.topDrinks and b then
                        pcall(function()
                            b.MedicineInfos:ForEach(function(k, v)
                                if k:get():ToString() == s.top then
                                    v:get():SetCurrentTime(s.topDrinks)
                                    v:get():SetDisplayTime(s.topDrinks)
                                end
                            end)
                        end)
                    end
                end
                if valid(p) then
                    game.setMinHealth(p, 0)     -- (the game's own floor again, the health back first)
                end
                setVeto(false)
                if done then done() end
            end)
        end
    end

    ------------------------------------------------------------------ this player's world: the arena itself

    -- (Known by address and name, the enemy itself asked for in a fresh list each time: one kept from the match's start can
    -- read as valid after it's gone, and the game frees enemies as the world streams.)
    local function nameOf(e)
        return select(2, pcall(function() return e:GetFName():ToString() end))
    end

    local function parkEnemies(center)
        for _, e in ipairs(game.listEnemies(true)) do
            local addr = e:GetAddress()
            local was = parked[addr]
            if was and was.name ~= nameOf(e) then
                parked[addr], was = nil, nil        -- (another enemy at a gone one's address)
            end
            local l = was == nil and locOf(e)
            if l and l.X and flatDist(l, center) <= PARK_CM then
                parked[addr] = { name = nameOf(e), home = { X = l.X, Y = l.Y, Z = l.Z } }
                game.stopAI(e)
                game.stepAside(e, true, parked[addr].home)
            elseif was then
                game.stopAI(e)          -- (the game starts a stopped brain again by itself)
            end
        end
        for _, boss in ipairs(game.bossActors and game.bossActors() or {}) do
            pcall(game.hideBossBar, boss)
        end
    end

    local function unparkEnemies()
        if next(parked) == nil then
            return
        end
        for _, e in ipairs(game.listEnemies(true)) do
            local p = parked[e:GetAddress()]
            if p and p.name == nameOf(e) then
                game.stepAside(e, false, p.home)
                game.startAI(e)
            end
        end
        for addr in pairs(parked) do
            parked[addr] = nil
        end
    end

    ------------------------------------------------------------------ the match: everyone

    local function newMatch(id, mode, timer, place, middle, teams, spots, presets)
        return {
            id = id, mode = mode, timer = timer, place = place, middle = middle,
            presets = presets or {},    -- slot -> loadout, everyone's: each world sets their weapons' level
            teams = teams,              -- slot -> 1 | 2
            spots = spots,              -- slot -> spot number on its side
            phase = "going",
            round = 0,
            score = { 0, 0 },
            down = {},                  -- slot -> true, this round
            there = {},                 -- host: slot -> true once set up
            startedAt = os.clock(),
        }
    end

    local function myTeam()
        local m = arena.match
        return m and m.teams[mySlot()]
    end
    arena.myTeam = myTeam

    local function spotOf(m, slot)
        local list
        if m.place == 0 then
            list = data.spots(m.middle, 800, m.middle.Yaw or 0)
        else
            list = data.arena(m.place).spots
        end
        local team = m.teams[slot] or 1
        local n = m.spots[slot] or 1
        return list[team][n] or list[team][1]
    end

    local function middleOf(m)
        if m.place == 0 then
            return m.middle
        end
        return data.arena(m.place).center
    end
    arena.middleOf = middleOf

    -- "Here": the line the two sides stand on (the host's start sends it with the middle). From the host's facing, then round
    -- in 30-degree steps, the first whose two first spots have floor within 1.5 m of the host's feet and a clear view of each
    -- other at chest height (the game's visibility channel, every player left out). None: the host's facing, as before. (The
    -- bench, 11-07: on a river bank the guest began each round behind a tree, its camera in the branches.)
    function arena.hereYaw(pawn, l, yaw)
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not valid(ksl) then
            return yaw
        end
        local skip, none = {}, { R = 0, G = 0, B = 0, A = 0 }
        for _, p in ipairs(coop.partners()) do
            if valid(p.ghost) then
                skip[#skip + 1] = p.ghost
            end
        end
        local function hitOf(from, to)
            local hit = {}
            local ok, got = pcall(function()
                return ksl:LineTraceSingle(pawn, from, to, 0, false, skip, 0, hit, true, none, none, 0)
            end)
            return ok and got and hit or nil
        end
        local feet = l.Z - 90
        local function floorAt(s)
            local hit = hitOf({ X = s.X, Y = s.Y, Z = feet + 250 }, { X = s.X, Y = s.Y, Z = feet - 400 })
            local z = hit and hit.Location and tonumber(hit.Location.Z)
            return z and math.abs(z - feet) <= 150 and z or nil
        end
        for i = 0, 11 do
            local y = (yaw + (i % 2 == 1 and 1 or -1) * math.ceil(i / 2) * 30) % 360
            local list = data.spots(l, 800, y)
            local a, b = list[1][1], list[2][1]
            local fa, fb = floorAt(a), floorAt(b)
            if fa and fb and not hitOf({ X = a.X, Y = a.Y, Z = fa + 120 }, { X = b.X, Y = b.Y, Z = fb + 120 }) then
                if i > 0 then
                    log(string.format("PvP: here, the sides stand %d degrees round from the host's facing: a clear line.",
                        math.floor((y - yaw) % 360 + 0.5)))
                end
                return y
            end
        end
        log("PvP: here, no line round the host with floor and a clear view at both ends: the host's facing.")
        return yaw
    end

    local function mapOf(m)
        if m.place == 0 then
            return m.middle.map
        end
        return data.arena(m.place).map
    end

    -- The fight's own switches on everyone's game: PvP between the teams (pvp.lua), the network trimmed (coop.lua).
    local function fightOn(on)
        net.arena = on and true or nil
        if api.pvp and api.pvp.arenaTeams then
            api.pvp.arenaTeams(on and arena.match and arena.match.teams or nil, mySlot(), data.DAMAGE)
        end
    end

    function arena.inMatch()
        return arena.match ~= nil
    end

    local function begin(m)
        -- Still being put back from the last match (goHome's 3.6 s): this one begins when that's done.
        if arena.restoring then
            arena.pendingStart = m
            return
        end
        local _, pawn = pawnNow()
        if not valid(pawn) then
            coop.sendEvent("AR", "quit", m.id, "nobody")
            return
        end
        arena.match = m
        if api.pvppanel and api.pvppanel.close then
            pcall(api.pvppanel.close)
        end
        local l = locOf(pawn)
        saved = {
            map = game.mapName(pawn),
            at = { X = l.X, Y = l.Y, Z = l.Z },
            yaw = pawn:K2_GetActorRotation().Yaw,
            pvpve = api.pvp and api.pvp.on,
        }
        local mid = middleOf(m)
        saved.arenaAt = string.format("%s %.0f %.0f %.0f", mapOf(m), mid.X or 0, mid.Y or 0, mid.Z or 0)
        journal({ map = saved.map, at = string.format("%.0f %.0f %.0f %.0f", l.X, l.Y, l.Z, saved.yaw), loans = "-",
            arena = saved.arenaAt })
        fightOn(true)
        local spot = spotOf(m, mySlot())
        local where = mapOf(m)
        if saved.map == where and flatDist(l, spot) <= NEAR_CM then
            land(pawn, spot)
            m.trip = false
        elseif game.travel(where, spot) then
            m.trip = true
        else
            tip("can't get to the arena from here.")
            coop.sendEvent("AR", "quit", m.id, "trip")
            arena.quit("you couldn't get to the arena", true)
            return
        end
        m.leftAt = os.clock()
        local a = data.arena(m.place)
        tip(string.format("%s, %s. %s team. To %s.", m.mode == "duel" and "Duel, best of three" or "Death, one life",
            m.timer > 0 and (m.timer .. " s a round") or "no clock", teamName(myTeam()), a.name))
        if ui() then
            ui().matchStarted(m, mySlot())
        end
    end

    -- At the arena, the world in: set up, parked, walls up, held still, and told.
    local function arrive(m, pawn)
        m.phase = "there"
        m.arrivedAt = os.clock()
        if m.trip then
            land(pawn, spotOf(m, mySlot()))
        end
        shield(pawn, true)
        hold(pawn, true)
        setup(pawn, m)
        parkEnemies(middleOf(m))
        game.setBossFog(middleOf(m), true)
        coop.sendEvent("AR", "here", m.id, "there")
        if coop.isHost() then
            m.there[mySlot()] = true
        end
        log("PvP: set up in the arena.")
    end

    -- A round from its countdown: refilled, on the spot, still; the fight COUNT_S on. age: how old the host's word to count
    -- is here (a guest), so every world's fight starts at the host's moment. (The review of 1.7.0: each world counted from
    -- when the word came, the host half a round trip ahead of every guest, every round.)
    local MAX_COUNT_AGE_S = 0.5
    local function startRound(m, round, age)
        local _, pawn = pawnNow()
        local lead = math.max(0, math.min(tonumber(age) or 0, MAX_COUNT_AGE_S))
        m.round = round
        m.down = {}
        m.phase = "count"
        m.fightAt = os.clock() + COUNT_S - lead
        m.endsAt = m.timer > 0 and (m.fightAt + m.timer) or nil
        if api.pvp then
            api.pvp.lastHitBy = nil
        end
        if valid(pawn) then
            arena.fall(pawn, false)
            if m.downSelf then
                rise(pawn)
                m.downSelf = nil
            end
            land(pawn, spotOf(m, mySlot()))
            hold(pawn, true)
            shield(pawn, true)
            keepFair(pawn)
            local _, maxhp = game.getHealth(pawn)
            if m.mode == "duel" or round == 1 then
                game.setHealth(pawn, maxhp or data.STATS.Health_Max)
                if game.setPosture then
                    game.setPosture(pawn, data.STATS.Shachi_Max)
                end
            end
        end
        for _, p in ipairs(coop.partners()) do
            if valid(p.ghost) then
                arena.fall(p.ghost, false)
            end
        end
        if ui() then
            ui().countdown(COUNT_S - lead, round, m)
        end
    end

    local function goDown(m, pawn, why)
        if m.down[mySlot()] then
            return
        end
        m.down[mySlot()] = true
        m.downSelf = true
        m.downAt = os.clock()
        m.phase = "out"
        hold(pawn, true)
        shield(pawn, true)
        arena.fall(pawn, true)
        coop.sendEvent("AR", "down", m.id, m.round, (api.pvp and api.pvp.lastHitBy) or 0)
        log(string.format("PvP: down in round %d (%s).", m.round, why))
        if ui() then
            ui().youDown(why)
        end
    end

    local function onDown(m, slot)
        m.down[slot] = true
        local body = coop.playerBody and coop.playerBody(slot)
        if body and slot ~= mySlot() then
            arena.fall(body, true)
        end
    end

    ------------------------------------------------------------------ the match: the host

    local function teamUp(m, team)
        for slot, t in pairs(m.teams) do
            if t == team and not m.down[slot] then
                return true
            end
        end
        return false
    end

    -- Health left as a share, a team's together (for a round the clock ended).
    local function teamHealth(m, team)
        local sum, n = 0, 0
        for slot, t in pairs(m.teams) do
            if t == team then
                local hp, maxhp
                if slot == mySlot() then
                    local _, pawn = pawnNow()
                    if valid(pawn) then
                        hp, maxhp = game.getHealth(pawn)
                    end
                else
                    local p = peerBySlot(slot)
                    hp, maxhp = p and p.target and p.target.Hp, p and p.target and p.target.MaxHp
                end
                if m.down[slot] then
                    hp = 0
                end
                if hp and maxhp and maxhp > 0 then
                    sum, n = sum + hp / maxhp, n + 1
                end
            end
        end
        return n > 0 and sum / n or 0
    end
    arena.teamHealth = teamHealth

    local function hostRound(m, winner)
        if winner > 0 then
            m.score[winner] = m.score[winner] + 1
        end
        coop.sendEvent("AR", "round", m.id, m.round, winner, m.score[1], m.score[2])
        arena.onRound(m, m.round, winner, m.score[1], m.score[2])
        m.nextAt = os.clock() + BETWEEN_S
        -- (A draw ends nothing: in Death it's fought again, where it gave the match to Crimson; the review of 1.7.0.)
        if (m.mode == "death" and winner > 0) or m.score[1] >= DUEL_WINS or m.score[2] >= DUEL_WINS then
            m.winner = m.score[1] > m.score[2] and 1 or 2
            m.nextAt = os.clock() + BETWEEN_S * 0.6
        end
    end

    -- How long a player may go unheard before they count as lost: on the way there and setting up, a trip's whole time
    -- (the game's own trip is a loading screen, 12 s with nothing sent on the bench); after that, SILENT_S.
    local function quietLimit(m)
        return (m.phase == "going" or m.phase == "there") and TRAVEL_S or SILENT_S
    end

    local function hostTick(m)
        local now = os.clock()
        -- Anyone gone quiet ends it for everyone.
        for _, p in ipairs(coop.partners()) do
            local s = peerSlot(p)
            if m.teams[s] and (p.partnerGone or (p.lastRemoteAt and now - p.lastRemoteAt > quietLimit(m))) then
                coop.sendEvent("AR", "quit", m.id, "lost")
                arena.quit(playerName(s) .. " was lost", true)
                return
            end
        end
        if m.phase == "going" or m.phase == "there" then
            local all = true
            for slot in pairs(m.teams) do
                all = all and m.there[slot] == true
            end
            if all and m.phase == "there" then
                coop.sendEvent("AR", "count", m.id, 1)
                startRound(m, 1)
            elseif now - m.startedAt > TRAVEL_S + SETUP_S then
                coop.sendEvent("AR", "quit", m.id, "late")
                arena.quit("not everyone got to the arena in time", true)
            end
        elseif m.phase == "fight" or m.phase == "out" then
            local up1, up2 = teamUp(m, 1), teamUp(m, 2)
            if not (up1 and up2) then
                hostRound(m, up1 and 1 or (up2 and 2 or 0))
            elseif m.endsAt and now >= m.endsAt then
                local h1, h2 = teamHealth(m, 1), teamHealth(m, 2)
                hostRound(m, (h1 > h2 + 0.001) and 1 or ((h2 > h1 + 0.001) and 2 or 0))
            end
        elseif m.phase == "between" and now >= (m.nextAt or 0) then
            if m.winner then
                coop.sendEvent("AR", "end", m.id, m.winner, m.score[1], m.score[2])
                arena.onEnd(m, m.winner, m.score[1], m.score[2])
            else
                coop.sendEvent("AR", "count", m.id, m.round + 1)
                startRound(m, m.round + 1)
            end
        elseif m.phase == "result" and now >= (m.homeAt or 0) then
            coop.sendEvent("AR", "home", m.id)
            arena.goHome("the match is over")
        end
    end

    ------------------------------------------------------------------ the match: everyone, each frame

    -- The game's time in a match, every frame (coop.frameTicks.arenaTime): at 1 for everyone (a perfect dodge's slow
    -- motion slowed only the dodger's game, issue #13), but in the beats this file slows on purpose (beat), held there:
    -- the game puts its own time back each frame (the bench, 11-07: a slowing set once was gone within a frame or two).
    -- (Named, not a closure each frame; the body sendPlayer already checked this frame: the review of 1.7.0.)
    local function holdTime(pawn, want)
        local gs = api.gs()
        if math.abs(gs:GetGlobalTimeDilation(pawn) - want) > 0.01 then
            gs:SetGlobalTimeDilation(pawn, want)
        end
    end
    local function timeNow(m)
        local pawn = coop.localPawn and coop.localPawn()
        if not valid(pawn) then
            return
        end
        pcall(holdTime, pawn, os.clock() < (m.slowUntil or 0) and (m.slowDilation or 1.0) or 1.0)
    end

    -- The countdown's end: free to fight on the frame it comes (coop.frameTicks.arenaTime). At the arena's 40 Hz tick it came
    -- up to 33 ms late, a different lateness on each PC (the review of 1.7.0).
    local function startFight(m)
        if m.phase ~= "count" or os.clock() < (m.fightAt or math.huge) then
            return
        end
        m.phase = "fight"
        local _, pawn = pawnNow()
        if valid(pawn) then
            hold(pawn, false)
            shield(pawn, false)
        end
        if ui() then
            ui().fight(FIGHT_SHOW_S)
        end
    end

    -- Down, after a moment the camera follows someone still up (the game's spectating, pbz.lua): a teammate fighting on, or
    -- else a foe. A team that lost the match watches the winners come for them, the finishing move and all. Back on this
    -- player when they're up again. (Down, the camera stayed on the body's own capsule: on the bench, buried in its hair.)
    -- net.arenaWatching keeps coop.lua's own death watch from taking it back.
    local WATCH_AFTER_S = 1.2
    local function watchedBody(m, now)
        local me = mySlot()
        local down = m.down[me] and (m.phase == "out" or m.phase == "between") and now - (m.downAt or now) >= WATCH_AFTER_S
        local lost = m.winner and m.winner ~= myTeam() and (m.phase == "finish" or m.phase == "result")
        if not (down or lost) then
            return nil
        end
        for _, mate in ipairs(lost and { false, true } or { true, false }) do      -- (lost: the winners first)
            for slot, team in pairs(m.teams) do
                if slot ~= me and (team == myTeam()) == mate and not m.down[slot] then
                    local body = coop.playerBody and coop.playerBody(slot)
                    if valid(body) then
                        return body
                    end
                end
            end
        end
        return nil
    end

    local function watchTeam(m, now)
        local want = watchedBody(m, now)
        if not game.spectate or (want == nil and not m.watching) then
            return
        end
        local at = game.spectatingAt and game.spectatingAt()
        if want and at ~= want:GetAddress() then
            m.watching = game.spectate(want) and true or nil
            net.arenaWatching = m.watching
        elseif not want then
            game.spectate(nil)
            net.arenaWatching, m.watching = nil, nil
        end
    end

    local areaAt, keepAt = 0, 0
    local function tick()
        local m = arena.match
        if not m then
            return
        end
        local now = os.clock()
        local _, pawn = pawnNow()
        if m.phase == "going" then
            if valid(pawn) and now - m.leftAt > (m.trip and 3 or 0.3) and os.clock() >= (net.quietUntil or 0) then
                local l = locOf(pawn)
                if l and game.mapName(pawn) == mapOf(m) and flatDist(l, spotOf(m, mySlot())) <= 5000 then
                    arrive(m, pawn)
                end
            end
            if m.phase == "going" and now - m.leftAt > TRAVEL_S then
                coop.sendEvent("AR", "quit", m.id, "trip")
                arena.quit("the trip to the arena took too long", true)
                return
            end
        end
        if not valid(pawn) then
            return
        end
        if m.phase ~= "going" then
            -- (The enemies and the walls half a second apart: each is a search of every object, 1-3 ms, and the two in one
            -- frame were a hitch every second of the fight.)
            if now >= areaAt and now >= (net.quietUntil or 0) then
                areaAt = now + AREA_S
                m.fogAt = now + AREA_S / 2
                parkEnemies(middleOf(m))
            elseif m.fogAt and now >= m.fogAt then
                m.fogAt = nil
                game.setBossFog(middleOf(m), true, true)        -- (said once, as they first close: arrive)
            end
        end
        startFight(m)
        if m.phase == "fight" then
            if now >= keepAt then
                keepAt = now + KEEP_S
                keepFair(pawn)
            end
            local hp = game.getHealth(pawn)
            local l = locOf(pawn)
            local mid = middleOf(m)
            if hp and hp <= DOWN_HP then
                goDown(m, pawn, "struck down")
            elseif l and mid.Z and l.Z < mid.Z - FALL_CM then
                goDown(m, pawn, "fell")
            end
        end
        watchTeam(m, now)
        -- The game's tip to drink, off while this player can't drink: down, beaten (the match decided, on the clock too), or
        -- held through their own finishing move. It stayed up by the gourd through the deciding blow, the dazed wait and the
        -- move (the bench, 11-07). Looked up only when that changes.
        local team = myTeam()
        local cant = (m.down[mySlot()] or (m.decidedFor and team ~= m.decidedFor)
            or ((m.phase == "finish" or m.phase == "result") and team ~= m.winner) or now < (m.heldUntil or 0)) and true or nil
        if cant ~= m.hintHidden and game.potionHint then
            m.hintHidden = cant
            game.potionHint(not cant)
        end
        -- Each player's own clock, the finishing window put back by a finishing move.
        if m.phase == "finish" and now >= (m.finishUntil or 0) then
            arena.showResult(m)
            m.homeAt = now + RESULT_S
        end
        if ui() then
            ui().frame(m, mySlot())
        end
        if coop.isHost() then
            hostTick(m)
        elseif net.partnerGone or (net.lastRemoteAt and now - net.lastRemoteAt > quietLimit(m)) then
            -- The host gone quiet: nobody runs the match any more (the bench: a guest stood in round 1 for good, the save
            -- held off and the match's loadout on, after the host's game crashed). A guest's host is net, two or more.
            arena.quit("the host was lost", true)
        end
    end

    -- Moves noticed every frame in a match and in PvPvE: most of a swing's lead on a parry, and the frame a guard goes up
    -- (pvp.lua times a parry by it; read ten times a second in PvPvE, a guard tapped up read as held: the review).
    local function frameMoves()
        if not (net.arena or net.pvp) then
            return
        end
        local pawn = coop.localPawn and coop.localPawn()
        if pawn and game.watchLocalPlayer then
            game.watchLocalPlayer(pawn, coop.sendEvent)
        end
    end

    ------------------------------------------------------------------ results, finishing, home

    -- The game slowed a moment (the only slowing in a match: timeNow holds it every frame), real seconds.
    local function beat(m, dilation, seconds)
        m.slowUntil = os.clock() + seconds
        m.slowDilation = dilation
        timeNow(m)
    end

    -- One of the game's own sounds at a big moment (arenas.lua's SOUNDS), on this player's body.
    local function sound(key)
        local _, pawn = pawnNow()
        local path = data.SOUNDS and data.SOUNDS[key]
        if path and valid(pawn) and game.playSound then
            return game.playSound(path, pawn)
        end
        return nil
    end

    -- A body's animation, checked first: a call on one that's gone can't be caught, pcall or not (the review of 1.7.0:
    -- a figure re-made or taken off the world between a match's last blow and its timers).
    local function animOf(body)
        if api.moves and api.moves.animOf then
            return api.moves.animOf(body)
        end
        local ai
        pcall(function() ai = body.Mesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    -- One of the game's montages by path, loaded as the moment comes, as moves.lua loads any move. (Not ahead, in the first
    -- countdown: loading right after the arena's trip, its long load just over, crashed the bench host inside UE4SS.)
    local function loadMontage(path)
        local m = api.moves and api.moves.montage and api.moves.montage(path)
        if not valid(m) then
            m = StaticFindObject(path)
            if not valid(m) and type(LoadAsset) == "function" then
                pcall(LoadAsset, path)
                m = StaticFindObject(path)
                if not valid(m) then
                    pcall(LoadAsset, (path:gsub("%.[^./]*$", "")))     -- (its package alone)
                    m = StaticFindObject(path)
                end
            end
        end
        return valid(m) and m or nil
    end

    -- "Finish them", as a fighting game has it: the blow that decides the match doesn't lay the losers down, it leaves them on
    -- their feet in the game's own broken stance (its posture-broken stagger, slowed to a sway once it's in) till the end.
    -- In every world, on the loser's body there: their own, or their figure (held from its steering the while: in a
    -- two-player game that hold is every figure's, and the winner's own world has no other). swayAfter: real seconds to
    -- the sway (the stagger comes in through the kill cam's slow beat).
    -- (The stagger's hunch is 0.8 to 1.7 s of its 3.6 s, the bench's stills, 11-07: after it the body stands up again.)
    local DAZED_IN_S = 0.8          -- the stagger's own seconds before the sway
    local DAZED_RATE = 0.08         -- the sway's speed through the hunch: about 11 s of it, then held at its end
    local DAZED_HOLD_S = 1.7
    local function dazed(m, slot, swayAfter)
        local body = coop.playerBody and coop.playerBody(slot)
        if not valid(body) then
            return
        end
        arena.fall(body, false)
        local move = data.DAZED and loadMontage(data.DAZED)
        if not move then
            return
        end
        pcall(function()
            if slot == mySlot() then
                body:PlayAnimMontage(move, 1.0, FName("None"))
            else
                if game.noteGhostMove then
                    game.noteGhostMove(body, BETWEEN_S + FINISH_S)
                end
                local ai = animOf(body)
                if ai then
                    ai:Montage_Play(move, 1.0, 0, 0.0, true)
                end
            end
        end)
        local function rate(r)
            local b = arena.match == m and m.finished ~= slot and coop.playerBody and coop.playerBody(slot)
            local mv = valid(b) and loadMontage(data.DAZED)
            if mv then
                local ai = animOf(b)
                if ai then
                    pcall(function() ai:Montage_SetPlayRate(mv, r) end)
                end
            end
        end
        local sway = swayAfter or DAZED_IN_S
        game.after(sway, function() rate(DAZED_RATE) end)
        game.after(sway + (DAZED_HOLD_S - DAZED_IN_S) / DAZED_RATE, function() rate(0.0) end)
    end

    -- A pose of ours a body still holds when the match is over (the dazed stance, the death of a finishing move: the game's
    -- death holds its last frame), let go. Only ours: a move of the player's own plays on.
    local function letGo(body)
        pcall(function()
            local ai = valid(body) and animOf(body)
            local held = valid(ai) and ai:GetCurrentActiveMontage()
            if not valid(held) then
                return
            end
            for _, path in ipairs({ data.DAZED, data.DEATH }) do
                local mv = path and StaticFindObject(path)
                if valid(mv) and mv:GetAddress() == held:GetAddress() then
                    ai:Montage_Stop(0.3, held)
                end
            end
        end)
    end

    -- The blow that decides the match, on every screen (the user: wins and losses worth it): the kill cam, slowed nearly to
    -- a stop; the game's musical hit; the beaten's bars breaking on the winners' screens, as a boss's posture does; and the
    -- beaten up again, dazed, waiting for the end to the game's own near-death heartbeat.
    local KILL_DILATION, KILL_S = 0.2, 1.4
    local function decided(m, winner)
        m.decidedFor = winner       -- (the tip to drink goes for its losers: tick)
        beat(m, KILL_DILATION, KILL_S)
        sound("decided")
        if ui() and ui().decided then
            ui().decided(m, winner, mySlot())
        end
        local swayAfter = KILL_S + math.max(0, DAZED_IN_S - KILL_S * KILL_DILATION)
        for slot, team in pairs(m.teams) do
            if team ~= winner then
                dazed(m, slot, swayAfter)
            end
        end
        if winner ~= myTeam() then
            local _, pawn = pawnNow()
            if valid(pawn) then
                hold(pawn, true)            -- (a round the clock ended left them free: a step cut the stance short)
                shield(pawn, true)
            end
            m.heartbeat = sound("heartbeat")
        end
    end

    function arena.onRound(m, round, winner, s1, s2)
        m.score = { s1, s2 }
        m.phase = "between"
        if (m.mode == "death" and winner > 0) or s1 >= DUEL_WINS or s2 >= DUEL_WINS then
            decided(m, winner)
        end
        log(string.format("PvP: round %d to %s. %s %d - %d %s.", round, winner == 0 and "nobody (a draw)" or teamName(winner),
            teamName(1), s1, s2, teamName(2)))
        if ui() then
            ui().roundOver(round, winner, myTeam(), s1, s2, m)
        end
    end

    function arena.onEnd(m, winner, s1, s2)
        m.winner = winner
        m.score = { s1, s2 }
        m.phase = "finish"
        m.finishUntil = os.clock() + FINISH_S
        m.finishBy = m.finishUntil - FINISH_LATE_S
        -- The losers wait for it where they are, on their feet and swaying (dazed).
        if myTeam() ~= winner then
            local _, pawn = pawnNow()
            if valid(pawn) then
                hold(pawn, true)
                shield(pawn, true)
            end
        end
        log(string.format("PvP: the match goes to %s, %d - %d.", teamName(winner), s1, s2))
        if ui() then
            ui().matchOver(myTeam() == winner, m)
        end
    end

    function arena.showResult(m)
        m.phase = "result"
        if myTeam() == m.winner then
            sound("victory")
            -- 生还 made and played as the losers' 殒命 (arenaui); the game's own screen turned golden if that can't be had.
            if not (ui() and ui().victoryCard and ui().victoryCard()) and game.showAliveScreen then
                game.showAliveScreen(RESULT_S, "V I C T O R Y")
            end
        else
            sound("heartbeatStop")
            sound("defeat")
            if ui() then
                ui().deathCard()
            end
        end
    end

    -- The finishing blow, from the winner on a beaten enemy (F in the finishing window, or a command): a boss's move
    -- (arenas.lua's FINISHERS) on the winner, who steps in before the dazed body and faces it. Every world plays it: the
    -- winner's on their own body, the others' on the winner's ghost (in PvP a ghost plays no sent montages, moves.lua, so
    -- it's told here). Shown as a fighting game shows its finishing moves (the user: "like mortal kombat execution"): every
    -- screen cuts to a camera beside the two, turning round them as the move plays; as it lands the game slows nearly to a
    -- stop, the game's own musical hit sounds, and the beaten dies as the game shows a player's death (dies).
    local FINISH_REACH_CM = 900
    local FINISH_RISE_CM = 400      -- a body this far below or above can't be reached (one that fell off the arena)
    local FINISH_GAP_CM = 140       -- the winner stands this far from the beaten body
    local SLOW_DILATION = 0.2
    local SLOW_S = 1.0              -- (real seconds)
    local THROW_CM_S = 700          -- the body thrown away from the blow, and up
    local THROW_UP_CM_S = 450
    local CINEMA_AFTER_S = 0.5      -- the camera stays on them this long after the move (its real length: realLen)

    -- Where a body is: a fallen one's mesh (loose on its own), else the body. loose: whether it lies loose.
    local function lyingAt(body)
        local l
        pcall(function()
            local mesh = body.Mesh
            if mesh:IsSimulatingPhysics(FName("None")) then
                l = mesh:K2_GetComponentLocation()
            end
        end)
        if l then
            return l, true
        end
        return locOf(body), false
    end

    local function finisherMove(n)
        local f = data.FINISHERS[n]
        if not f then
            return nil
        end
        return loadMontage(f.path), f
    end

    -- The camera's side of the two: the arena's middle's (the open side, away from its walls and rocks).
    local function cinemaSide(m, by, victim)
        local a, b = coop.playerBody(by), coop.playerBody(victim)
        local la, lb = valid(a) and locOf(a), valid(b) and locOf(b)
        local mid = middleOf(m)
        if not (la and lb and mid and mid.X) then
            return 1
        end
        local cross = (lb.X - la.X) * (mid.Y - la.Y) - (lb.Y - la.Y) * (mid.X - la.X)
        return cross >= 0 and 1 or -1
    end

    local function slowBeat(m)
        beat(m, SLOW_DILATION, SLOW_S)
    end

    local function throw(body, from)
        local at = lyingAt(body)
        if not (at and from) then
            return
        end
        local dx, dy = at.X - from.X, at.Y - from.Y
        local d = math.max(1, math.sqrt(dx * dx + dy * dy))
        local v = { X = dx / d * THROW_CM_S, Y = dy / d * THROW_CM_S, Z = THROW_UP_CM_S }
        pcall(function() body.Mesh:SetAllPhysicsLinearVelocity(v, true) end)
    end

    -- The finished body dies as the game shows a player's death (the user: "Why death is not same as the way the game does
    -- it"): its own death, played where it stands, held on its last frame (letGo puts it back). If that can't be had,
    -- loose and thrown as before.
    local function dies(victim, body, from)
        local move = data.DEATH and loadMontage(data.DEATH)
        local played = false
        if move then
            arena.fall(body, false)
            local ai = victim ~= mySlot() and animOf(body)
            played = (victim == mySlot() or ai) and pcall(function()
                if victim == mySlot() then
                    body:PlayAnimMontage(move, 1.0, FName("None"))
                else
                    if game.noteGhostMove then
                        game.noteGhostMove(body, FINISH_S)
                    end
                    ai:Montage_Play(move, 1.0, 0, 0.0, true)
                end
            end) or false
        end
        if not played then
            arena.fall(body, true)
            throw(body, from)
        end
    end

    -- The move, in this world. by: the winner's slot; spot: where they stand for it (their own world works it out).
    local function finisherPlays(m, by, victim, n, spot)
        local montage, f = finisherMove(n)
        local mine = by == mySlot()
        local winner = coop.playerBody and coop.playerBody(by)
        local len = f and f.len or 4.0
        if valid(winner) and montage then
            pcall(function()
                if spot then
                    winner:K2_SetActorLocationAndRotation({ X = spot.X, Y = spot.Y, Z = spot.Z },
                        { Pitch = 0, Yaw = spot.Yaw, Roll = 0 }, false, {}, true)
                end
                if mine then
                    local pc = pawnNow()
                    if valid(pc) and spot then
                        pc:SetControlRotation({ Pitch = -10, Yaw = spot.Yaw, Roll = 0 })
                    end
                    hold(winner, true)              -- (played whole: a button pressed in it cut it short)
                    len = winner:PlayAnimMontage(montage, 1.0, FName("None")) or len
                else
                    if game.noteGhostMove then
                        game.noteGhostMove(winner, len + SLOW_S * (1 - SLOW_DILATION) + 0.5)
                    end
                    local ai = animOf(winner)
                    if ai then
                        ai:Montage_Play(montage, 1.0, 0, 0.0, true)
                    end
                end
            end)
        end
        -- The move's length in real seconds: its slow beat (always inside it, the blow before its end) stretches it. (The
        -- review of 1.7.0: timed by the montage's own length, the winner was let go 0.8 s before the move's end.)
        local realLen = len + SLOW_S * (1 - SLOW_DILATION)
        if mine then
            m.heldUntil = os.clock() + realLen      -- (no tip to drink while the move holds them: tick)
            game.after(realLen, function()
                local _, pawn = pawnNow()
                if arena.match == m and valid(pawn) then
                    hold(pawn, false)
                end
            end)
        end
        if victim == mySlot() then
            local _, pawn = pawnNow()
            if valid(pawn) then
                hold(pawn, true)
                shield(pawn, true)
            end
        end
        if game.cinema then
            game.cinema(function() return coop.playerBody(by), coop.playerBody(victim) end, realLen + CINEMA_AFTER_S,
                cinemaSide(m, by, victim))
        end
        m.finishUntil = math.max(m.finishUntil or 0, os.clock() + realLen + CINEMA_AFTER_S + 0.2)
        game.after(f and f.hit or len * 0.5, function()
            if arena.match ~= m then
                return
            end
            local body = coop.playerBody and coop.playerBody(victim)
            local w = coop.playerBody and coop.playerBody(by)
            if valid(body) then
                dies(victim, body, valid(w) and locOf(w) or nil)
            end
            slowBeat(m)
            sound("finisher")
        end)
        log(string.format("PvP: %s finishes %s (%s).", playerName(by), playerName(victim), f and f.key or "?"))
        if ui() and ui().finisher then
            ui().finisher(victim, by, mine)
        end
    end

    function arena.finish(victim, n)
        local m = arena.match
        -- (A winner down on the ground doesn't: it played on a body lying loose, and the teammate standing lost it.)
        if not (m and m.phase == "finish" and myTeam() == m.winner and not m.finished and not m.down[mySlot()]) then
            return false
        end
        if not (victim and m.teams[victim] and m.teams[victim] ~= myTeam()) then
            return false
        end
        if os.clock() > (m.finishBy or math.huge) then
            tip("too late to finish them: the match is over.")
            return false
        end
        -- In front of the body, on the side the winner came from, facing it (a body not found here: where they stand).
        local _, pawn = pawnNow()
        local body = coop.playerBody and coop.playerBody(victim)
        local at, loose = nil, false
        if valid(body) then
            at, loose = lyingAt(body)
        end
        local me = valid(pawn) and locOf(pawn)
        local spot, where = nil, { "-", "-", "-", "-" }
        if at and me then
            local dx, dy = me.X - at.X, me.Y - at.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 1 then
                dx, dy, d = 1, 0, 1
            end
            -- (A loose body's mesh lies on the ground, a standing one's middle is the body's own height: 90 cm up.)
            spot = { X = at.X + dx / d * FINISH_GAP_CM, Y = at.Y + dy / d * FINISH_GAP_CM,
                Z = math.max(me.Z, at.Z + (loose and 90 or 0)), Yaw = math.deg((math.atan2 or math.atan)(-dy, -dx)) }
            where = { string.format("%.0f", spot.X), string.format("%.0f", spot.Y), string.format("%.0f", spot.Z),
                string.format("%.1f", spot.Yaw) }
        end
        n = n or math.random(#data.FINISHERS)
        m.finished = victim
        coop.sendEvent("AR", "fin", m.id, victim, n, where[1], where[2], where[3], where[4])
        finisherPlays(m, mySlot(), victim, n, spot)
        return true
    end

    -- F in the finishing window: the fallen foe nearest this player, within reach.
    function arena.finishNearest()
        local m = arena.match
        if not (m and m.phase == "finish" and myTeam() == m.winner and not m.finished) then
            return false
        end
        local _, pawn = pawnNow()
        local me = valid(pawn) and locOf(pawn)
        if not me then
            return false
        end
        local best, bestD = nil, FINISH_REACH_CM
        for slot, team in pairs(m.teams) do
            if team ~= myTeam() then
                local body = coop.playerBody and coop.playerBody(slot)
                local l = valid(body) and lyingAt(body)
                local d = l and math.abs(l.Z - me.Z) <= FINISH_RISE_CM and flatDist(l, me)
                if d and d <= bestD then
                    best, bestD = slot, d
                end
            end
        end
        if not best then
            tip("get closer to a fallen foe to finish them.")
            return false
        end
        return arena.finish(best)
    end

    -- Back where they were, with what they had. said: why, for the tip.
    function arena.goHome(said)
        local m = arena.match
        if not m then
            return
        end
        arena.match = nil
        local _, pawn = pawnNow()
        local home = saved
        if ui() then
            ui().clear()
        end
        if m.heartbeat then
            sound("heartbeatStop")
        end
        if game.endCinema then
            game.endCinema()
        end
        if m.hintHidden and game.potionHint then
            game.potionHint(true)
        end
        if m.watching and game.spectate then
            game.spectate(nil)
        end
        net.arenaWatching = nil
        -- The others stop being foes at once, before the shield and the health floor go: put back later, the figures
        -- stayed hostile for the 3.6 s the skill tree takes, and a blow then was a real death (the review).
        fightOn(false)
        -- (The shield stays on till this player is put back: the health is back at its end, restore says why.)
        if valid(pawn) then
            arena.fall(pawn, false)
            letGo(pawn)
            hold(pawn, false)
            pcall(function() api.gs():SetGlobalTimeDilation(pawn, 1.0) end)
        end
        for _, p in ipairs(coop.partners()) do
            if valid(p.ghost) then
                arena.fall(p.ghost, false)
                letGo(p.ghost)
            end
        end
        unparkEnemies()
        game.setBossFog(middleOf(m), false)
        if not home then
            if valid(pawn) then
                shield(pawn, false)
            end
            dropJournal()
            tip("back from the match: " .. said .. ".")
            return
        end
        -- Being put back: a new match waits for it (begin), or its start was torn down by this one's late timers.
        arena.restoring = true
        restore(pawn, function()
            arena.restoring = nil
            local _, back = pawnNow()
            if valid(back) then
                shield(back, false)
            end
            if api.pvp and api.pvp.set and api.pvp.on ~= home.pvpve then
                api.pvp.set(home.pvpve)
            end
            local _, now = pawnNow()
            if valid(now) then
                local l = locOf(now)
                if game.mapName(now) == home.map and l and flatDist(l, home.at) <= NEAR_CM then
                    land(now, { X = home.at.X, Y = home.at.Y, Z = home.at.Z, Yaw = home.yaw })
                else
                    game.travel(home.map, home.at)
                end
            end
            dropJournal()
            if saved == home then
                saved = nil
            end
            coop.sendEvent("AR", "here", m.id, "home")
            tip("back from the match: " .. said .. ".")
            local waiting = arena.pendingStart
            arena.pendingStart = nil
            if waiting then
                begin(waiting)
            end
        end)
    end

    -- The game rested this player in a match (coop.lua tells): a real death (a fall out of the world) can't go on there; a
    -- sit at a bell (the "here" arena can have one) is a forfeit of the round.
    function arena.restDuring(kind)
        local m = arena.match
        if not m then
            return
        end
        if kind == "death" then
            arena.quit("you died", false)
        elseif kind == "sit" then
            local _, pawn = pawnNow()
            if m.phase == "fight" and valid(pawn) then
                goDown(m, pawn, "rested at a bell")
            end
        end
    end

    -- Off for everyone: told already (told = true), or told now.
    function arena.quit(why, told)
        local m = arena.match
        if not m then
            return
        end
        if not told then
            coop.sendEvent("AR", "quit", m.id, "left")
        end
        arena.goHome(why)
    end

    -- LEAVE on the F6 page: twice within LEAVE_S.
    function arena.leave()
        if not arena.match then
            return false
        end
        local now = os.clock()
        if now - leaveAskedAt <= LEAVE_S then
            arena.quit("you left", false)
            return true
        end
        leaveAskedAt = now
        tip("press LEAVE again to end the match for everyone.")
        return false
    end

    ------------------------------------------------------------------ the host starts

    function arena.start()
        hostPick()              -- (the host's own loadout as it is now, changed on the page since the lobby went out)
        local why = arena.blocker()
        if why then
            tip(why)
            return false
        end
        local _, pawn = pawnNow()
        if not valid(pawn) or arena.match then
            return false
        end
        local id = math.random(100000, 999999)
        local teams, spots, presets, n = {}, {}, {}, { 0, 0 }
        local parts = {}
        for _, s in ipairs(everyone()) do
            local team = arena.picks[s].team
            n[team] = n[team] + 1
            teams[s], spots[s] = team, n[team]
            local loadout = arena.picks[s].preset or presetText(data.DEFAULT)
            presets[s] = presetFrom(loadout)
            parts[#parts + 1] = string.format("%d:%d:%d:%s", s, team, n[team], loadout)
        end
        local l = locOf(pawn)
        local yaw = pawn:K2_GetActorRotation().Yaw
        if arena.place == 0 then
            local ok, y = pcall(arena.hereYaw, pawn, l, yaw)
            yaw = ok and y or yaw
        end
        local middle = { X = l.X, Y = l.Y, Z = l.Z, Yaw = yaw, map = game.mapName(pawn) }
        local m = newMatch(id, arena.mode, arena.timer, arena.place, middle, teams, spots, presets)
        coop.sendEvent("AR", "start", id, m.mode, m.timer, m.place, string.format("%.0f %.0f %.0f %.0f %s", l.X, l.Y, l.Z, yaw,
            middle.map), table.concat(parts, " "))
        begin(m)
        return true
    end

    ------------------------------------------------------------------ events

    local AR = {}

    local function sameMatch(id)
        local m = arena.match
        return m and tostring(m.id) == tostring(id) and m or nil
    end

    function AR.lobby(rest, slot)
        if coop.isHost() or slot ~= 1 then
            return
        end
        local mode, timer, place, list = rest:match("^(%a+) (%d+) (%d+)%s*(.*)$")
        if not (mode and MODES[mode]) then
            return
        end
        local l = { mode = mode, timer = tonumber(timer), place = tonumber(place), players = {} }
        for s, team, ready, have in (list or ""):gmatch("(%d):(%d):(%d):(%S+)") do
            l.players[tonumber(s)] = { team = tonumber(team), ready = ready == "1", arenas = have }
        end
        arena.lobby = l
        local mine = l.players[mySlot()]
        if mine and mine.team and mine.team > 0 and arena.pick.team == nil then
            arena.pick.team = mine.team
        end
    end

    function AR.pick(rest, slot)
        if not coop.isHost() then
            return
        end
        local team, ready, have, version, loadout = rest:match("^(%d) ([01]) (%S+) (%S+)%s*(%S*)")
        if not team then
            return
        end
        local p = arena.picks[slot] or {}
        p.team = (tonumber(team) == 1 or tonumber(team) == 2) and tonumber(team) or p.team
        p.ready = ready == "1"
        p.arenas = have
        p.version = version
        p.preset = loadout ~= "" and loadout or p.preset
        arena.picks[slot] = p
        arena.sendLobby()
    end

    function AR.start(rest, slot)
        if coop.isHost() or slot ~= 1 or arena.match then
            return
        end
        local id, mode, timer, place, x, y, z, yaw, map, list =
            rest:match("^(%d+) (%a+) (%d+) (%d+) (%S+) (%S+) (%S+) (%S+) (%S+)%s*(.*)$")
        if not (id and MODES[mode]) then
            return
        end
        local teams, spots, presets = {}, {}, {}
        for s, team, spot, loadout in (list or ""):gmatch("(%d):(%d):(%d):?(%S*)") do
            teams[tonumber(s)], spots[tonumber(s)] = tonumber(team), tonumber(spot)
            presets[tonumber(s)] = presetFrom(loadout)
        end
        if not teams[mySlot()] then
            return                  -- (not in this one)
        end
        local middle = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), Yaw = tonumber(yaw), map = map }
        if not (middle.X and middle.Y and middle.Z) then
            return
        end
        begin(newMatch(tonumber(id), mode, tonumber(timer), tonumber(place), middle, teams, spots, presets))
    end

    function AR.here(rest, slot)
        local id, what = rest:match("^(%d+) (%a+)")
        local m = sameMatch(id)
        if m and coop.isHost() and what == "there" then
            m.there[slot] = true
        end
    end

    function AR.count(rest, slot)
        if coop.isHost() or slot ~= 1 then
            return
        end
        local id, round = rest:match("^(%d+) (%d+)")
        local m = sameMatch(id)
        if m and m.phase ~= "going" then
            startRound(m, tonumber(round), net.moveAge and net.moveAge() or 0)
        end
    end

    function AR.down(rest, slot)
        local id, round = rest:match("^(%d+) (%d+)")
        local m = sameMatch(id)
        if m and tonumber(round) == m.round then
            onDown(m, slot)
        end
    end

    function AR.round(rest, slot)
        if coop.isHost() or slot ~= 1 then
            return
        end
        local id, round, winner, s1, s2 = rest:match("^(%d+) (%d+) (%d) (%d+) (%d+)")
        local m = sameMatch(id)
        if m then
            arena.onRound(m, tonumber(round), tonumber(winner), tonumber(s1), tonumber(s2))
        end
    end

    AR["end"] = function(rest, slot)
        if coop.isHost() or slot ~= 1 then
            return
        end
        local id, winner, s1, s2 = rest:match("^(%d+) (%d) (%d+) (%d+)")
        local m = sameMatch(id)
        if m then
            arena.onEnd(m, tonumber(winner), tonumber(s1), tonumber(s2))
        end
    end

    function AR.fin(rest, slot)
        local id, victim, n, x, y, z, yaw = rest:match("^(%d+) (%d) (%d+) (%S+) (%S+) (%S+) (%S+)")
        local m = sameMatch(id)
        if not m or m.finished or m.teams[slot] ~= m.winner then
            return
        end
        m.finished = tonumber(victim)
        local spot = tonumber(yaw) and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), Yaw = tonumber(yaw) } or nil
        finisherPlays(m, slot, m.finished, tonumber(n) or 1, spot)
    end

    function AR.home(rest, slot)
        if coop.isHost() or slot ~= 1 then
            return
        end
        if sameMatch(rest:match("^(%d+)")) then
            arena.goHome("the match is over")
        end
    end

    function AR.quit(rest, slot)
        local id, why = rest:match("^(%d+)%s*(%S*)")
        local waiting = arena.pendingStart
        if waiting and tostring(waiting.id) == tostring(id) then
            arena.pendingStart = nil            -- (called off before it began here)
            return
        end
        local m = sameMatch(id)
        if not m then
            return
        end
        local who = playerName(slot)
        local said = why == "lost" and "a player was lost" or why == "trip" and (who .. " couldn't get to the arena")
            or why == "late" and "not everyone got to the arena in time" or (who .. " left")
        if coop.isHost() then
            coop.sendEvent("AR", "quit", m.id, why ~= "" and why or "left")
        end
        arena.goHome(said)
    end

    local previous = coop.handlers.AR
    coop.handlers.AR = function(rest, from)
        if previous then
            previous(rest, from)
        end
        local what, args = (rest or ""):match("^(%a+)%s*(.*)$")
        local h = what and AR[what]
        if h then
            h(args or "", senderSlot(from))
        end
    end

    -- A partner (re)starting sync or joining hears the lobby at once, and what the lobby held for that place goes: it was
    -- the last player's. (The review of 1.7.0: the relay gives a quiet player's place to a newcomer, who was then taken
    -- into a match on the leaver's READY, version, arenas and loadout. Someone back in their own place presses READY again.)
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        local s = senderSlot(from)
        if s and s ~= mySlot() and not arena.match then
            arena.picks[s] = nil
        end
        lobbySent = nil
        return syncStarted(rest, from)
    end

    ------------------------------------------------------------------ a crash in the middle

    -- pvp_restore.txt from a match the game didn't end: a weapon lent then is taken back, and the player is taken home (where
    -- they stood when it began). The stats were never saved: the veto was up. (The match's skill nodes go off if a save
    -- kept them.)
    local function readJournal()
        local f = io.open(api.modDir() .. "pvp_restore.txt", "r")
        if not f then
            return nil
        end
        local j = {}
        for line in f:lines() do
            local k, v = line:match("^%s*(%a+)%s*=%s*(.-)%s*$")
            if k then
                j[k] = v
            end
        end
        f:close()
        return j
    end

    local recoverAt = nil
    local function recover()
        if arena.match or recoverAt == false then
            return
        end
        local j = readJournal()
        if not j then
            recoverAt = false
            return
        end
        local _, pawn = pawnNow()
        if not valid(pawn) or os.clock() < (net.quietUntil or 0) or game.inCutscene() then
            return
        end
        recoverAt = recoverAt or (os.clock() + 5)
        if os.clock() < recoverAt then
            return
        end
        recoverAt = false
        -- Only a game that came back in that match's arena: the save is held off all match, so one loaded anywhere else
        -- never saw it, and putting levels, weapons and the place back there undid a save that had moved on (another
        -- slot: its weapons lowered or taken, the player sent off; the review of 1.7.0).
        local am, ax, ay = (j.arena or ""):match("^(%S+) (%S+) (%S+)")
        local here = locOf(pawn)
        if not (am and here and game.mapName(pawn) == am and tonumber(ax)
                and flatDist(here, { X = tonumber(ax), Y = tonumber(ay) }) <= PARK_CM) then
            dropJournal()
            log("PvP: a match was cut short when the game closed, but nothing of it was saved: nothing to put back.")
            return
        end
        local bp = game.backpackOf(pawn)
        if bp then
            pcall(function()
                if bp:HasEquippedWeaponsSnapshot() then
                    bp:PopEquippedWeapons()
                end
            end)
            for kind, id, level in (j.levels or ""):gmatch("(%a+):([^,=]+)=(%d+)") do
                if tonumber(level) > 0 then
                    pcall(function() bp:ResetWeaponToLevel(FName(id), kind == "main", tonumber(level), {}, {}) end)
                end
            end
            for kind, id in (j.loans or ""):gmatch("(%a+):([^,]+)") do
                pcall(function() bp:DisposeWeapon(FName(id), kind == "main") end)
            end
        end
        -- (The skill nodes the match put on too, those a save in it kept: only them, never the player's own.)
        local nodes, a = componentOf(pawn, "PBZAbilityNodesComponent"), asc(pawn)
        if valid(nodes) and a then
            for id in (j.added or ""):gmatch("[^,%-]+") do
                pcall(function()
                    if nodes:IsActivateAbilityNode(FName(id)) then
                        nodes:DeactivateNode(FName(id), a)
                    end
                end)
            end
        end
        local x, y, z = (j.at or ""):match("^(%S+) (%S+) (%S+)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        dropJournal()
        if j.map and x and y and z then
            tip("a match was cut short by the game closing: back to where it began.")
            game.travel(j.map, { X = x, Y = y, Z = z })
        end
    end

    ------------------------------------------------------------------ ticks and commands

    -- Each frame, at most ARENA_TICK_S apart: not one of coop's extraTicks, which all wait out its quiet after a load or a
    -- hitch, so the match's clock, its countdown and a player falling to 1 health froze for up to 5 s (the review of
    -- 1.7.0). Its world searches (enemies put aside, fog walls) still wait for the quiet: tick() asks.
    local ARENA_TICK_S, arenaTickAt = 1 / 40, 0
    -- The lobby is built again at most LOBBY_S apart, or at once once the last one sent was let go (lobbySent nil): a choice,
    -- a READY or a pick sends it themselves. (The review of 1.7.0: built every tick, on every co-op host, ~800 tables a
    -- second for something that changes at a person's speed.)
    local LOBBY_S, lobbyAt = 0.5, 0
    local function arenaTick()
        if coop.isHost() and net.enabled and not arena.match then
            local clock = os.clock()
            if lobbySent == nil or clock >= lobbyAt then
                lobbyAt = clock + LOBBY_S
                arena.sendLobby()
            end
        elseif not coop.isHost() and arena.lobby and net.partnerGone then
            arena.lobby, arena.pick.ready = nil, false      -- (the host gone: its lobby and this READY with it)
        end
        tick()
        recover()
    end
    coop.frameTicks.arena = function()
        local clock = os.clock()
        if clock < arenaTickAt then
            return
        end
        arenaTickAt = clock + ARENA_TICK_S
        local ok, err = pcall(arenaTick)
        if not ok and err ~= arena.lastError then
            arena.lastError = err
            log("arena: " .. tostring(err))
        end
    end
    coop.frameTicks.arenaMoves = function()
        pcall(frameMoves)
    end
    -- (Every frame, not at ARENA_TICK_S: the game puts its own time back each frame.)
    coop.frameTicks.arenaTime = function()
        local m = arena.match
        if m and m.phase ~= "going" then
            timeNow(m)
            if m.phase == "count" then
                pcall(startFight, m)
            end
            -- (And what moves on the match screen, every frame: see arenaui's animate.)
            if ui() and ui().animate then
                ui().animate(m, mySlot())
            end
        end
    end

    -- arena status | start | mode duel|death | timer 0|60|90|120 | place 0-4 | team 1|2 | ready [off] | leave | down |
    -- finish <slot> [move] | preset <main1> <main2> <edge1> <edge2> | unlocked
    function arena.command(args)
        local cmd, a1, a2, a3, a4 = (args or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
        if cmd == "start" then
            arena.start()
        elseif cmd == "mode" or cmd == "timer" or cmd == "place" then
            arena.choose(cmd, a1)
        elseif cmd == "team" then
            arena.setPick(tonumber(a1), nil)
        elseif cmd == "ready" then
            arena.setPick(nil, a1 ~= "off")
        elseif cmd == "leave" then
            arena.quit("you left", false)
        elseif cmd == "down" then
            local m = arena.match
            local _, pawn = pawnNow()
            if m and m.phase == "fight" and valid(pawn) then
                goDown(m, pawn, "test")
            end
        elseif cmd == "finish" then
            log("PvP finish: " .. tostring(arena.finish(tonumber(a1), data.FINISHERS[tonumber(a2) or 0] and tonumber(a2))))
        elseif cmd == "preset" and a1 ~= "" then
            arena.savePreset({ main = { a1, a2 }, edge = { a3, a4 } })
            log("PvP loadout: " .. table.concat(arena.preset.main, ", ") .. " | " .. table.concat(arena.preset.edge, ", "))
        elseif cmd == "unlocked" then
            arena.readUnlocked()
            log("PvP arenas open here: " .. arenasText())
        else
            local m = arena.match
            local a = data.arena(arena.place)
            local why = arena.blocker()
            log(string.format("PvP: %s, %s, %s; %s.%s", arena.mode, arena.timer > 0 and (arena.timer .. " s") or "no clock",
                a and a.name or "?", m and string.format("match %d %s, round %d, %d - %d", m.id, m.phase, m.round, m.score[1],
                m.score[2]) or "no match", why and (" " .. why) or ""))
        end
    end

    arena.loadPreset()
    return arena
end
