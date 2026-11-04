-- Ghost twins (6 players, experimental): with five or six players connected, every enemy and every boss near a player gets a
-- twin, a second copy of itself in a cyan phantom look with red eyes. Two bosses in each arena, twice the enemies. Enemy
-- health and posture stop growing at four players (scaling.lua): the twins are what's harder after that.
--
-- PhantomPact.ini GhostTwins: how many players it takes (5 by default; Off = never). Only the host's setting counts.
--
-- The host's game makes the twins and runs them like any other enemy: its lines carry them to the guests under the id
-- "tw<n>:" and the original's id (game.markTwin), and a guest that hears of one it hasn't got makes its own copy under that id,
-- which the usual pairing then steers (coop.lua matchRemoteEnemies). Hits, deaths and health go as for any enemy.
-- A twin is never "the boss" to the mod (pbz.lua): its death ends no fight and marks nothing beaten. A boss's twin fades
-- when the boss dies, so the story goes on as it always does; an enemy's twin lives on until it's killed.
-- A rest at a bell, or the original going out of reach, takes the twins away; new ones come with the enemies.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local twins = {
        from = 5,                   -- GhostTwins: players connected it takes; nil = off
    }

    local BODY = "/PBZVFXPack/VFX/A_Materials/Template/MT_PhantomChar_001.MT_PhantomChar_001"
    local EYES = "/Game/PBZContent/Characters/Hero/Hun_JiGuanMoQu/Material/T_Hero_Hun_JGMQ_Eyes_Emmsive.T_Hero_Hun_JGMQ_Eyes_Emmsive"
    local EYE_COLOR = { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }
    local EYE_GLOW = 80.0
    local NEAR_CM = 5000            -- an enemy this close to a player gets its twin
    local SIDE_CM = 250             -- a new twin stands this far beside the original
    local SPAWN_EVERY_S = 0.3       -- at most one new twin this often: a spawn costs a frame
    local LOOK_EVERY_S = 0.05       -- one twin's look checked this often, in turn (the game puts its own materials back)
    local GONE_S = 20               -- guest: a twin the host hasn't mentioned for this long goes
    local RETRY_S = 30              -- host: a twin that couldn't be made is tried again after this long
    local SETTLE_S = 2              -- host: an enemy is seen this long before it gets its twin

    local firstSeen = {}            -- host: enemy address -> os.clock() it was first in the list
    local hostTwins = {}            -- host: original's address -> { id, twin, twinAddr, orig, origAddr, boss, origDied, at }
    local cleared = {}              -- guest: twin ids a rest took away; the host's last lines of them mustn't bring them back
    local guestTwins = {}           -- guest: twin id -> { twin, twinAddr, seenAt }
    local looks = {}                -- twin address -> { actor, meshes = { {comp, eyes = {slot = true}} }, eyeMids = {} }
    local lookOrder, lookAt = {}, 1
    local nextSpawn, nextLook = 0, 0
    -- host: each twin's own number in its id, so one twin's death says nothing of the next. It starts somewhere new each run:
    -- a host that restarted counted from 1 again, and a guest that had seen tw1 go at a rest never made the new tw1.
    local serial = (os.time() % 100000) * 1000

    ------------------------------------------------------------------ the look

    local function loadAsset(path)
        local m = StaticFindObject(path)
        if valid(m) then
            return m
        end
        pcall(function() m = LoadAsset(path) end)
        if valid(m) then
            return m
        end
        pcall(function() m = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LoadAsset_Blocking(path) end)
        return valid(m) and m or nil
    end

    local function isEyeSlot(name)
        name = name:lower()
        return name:find("eye", 1, true) ~= nil and not (name:find("ao", 1, true) or name:find("occlu", 1, true)
            or name:find("lash", 1, true) or name:find("brow", 1, true) or name:find("shadow", 1, true))
    end

    -- The meshes to paint: the actor's own, and those of what's attached to it (a weapon is often an actor of its own).
    local function meshesOf(actor)
        local out = {}
        local cls = StaticFindObject("/Script/Engine.MeshComponent")
        local function add(a)
            pcall(function()
                for _, c in ipairs(a:K2_GetComponentsByClass(cls) or {}) do
                    local comp = c:get()
                    if valid(comp) and not comp:GetClass():GetFName():ToString():find("Widget", 1, true) then
                        local eyes = {}
                        pcall(function()
                            for i, s in ipairs(comp:GetMaterialSlotNames()) do
                                if isEyeSlot(s:get():ToString()) then
                                    eyes[i - 1] = true
                                end
                            end
                        end)
                        out[#out + 1] = { comp = comp, eyes = eyes }
                    end
                end
            end)
        end
        add(actor)
        pcall(function()
            local attached = {}
            actor:GetAttachedActors(attached, true, false)
            for _, a in ipairs(attached) do
                local x = a.get and a:get() or a
                if valid(x) then
                    add(x)
                end
            end
        end)
        return out
    end

    -- The whole look, again: every slot cyan, the eyes red. Returns false if the materials couldn't be had.
    local function paint(look)
        local body, eyes = loadAsset(BODY), loadAsset(EYES)
        if not body then
            return false
        end
        for _, m in ipairs(look.meshes) do
            if valid(m.comp) then
                pcall(function()
                    for i = 0, m.comp:GetNumMaterials() - 1 do
                        if m.eyes[i] and eyes then
                            local key = m.comp:GetAddress() .. ":" .. i
                            local mid = look.eyeMids[key]
                            if valid(mid) then
                                m.comp:SetMaterial(i, mid)
                            else
                                mid = m.comp:CreateDynamicMaterialInstance(i, eyes, FName("TwinEyes"))
                                if valid(mid) then
                                    mid:SetVectorParameterValue(FName("Color"), EYE_COLOR)
                                    mid:SetScalarParameterValue(FName("Intensity"), EYE_GLOW)
                                    look.eyeMids[key] = mid
                                end
                            end
                        else
                            m.comp:SetMaterial(i, body)
                        end
                    end
                end)
            end
        end
        return true
    end

    -- Cheap: one slot of the first mesh. The game puts back all of a mesh's materials at once, so one tells.
    local function lookHolds(look)
        local m = look.meshes[1]
        if not (m and valid(m.comp)) then
            return true
        end
        local slot = 0
        while m.eyes[slot] do
            slot = slot + 1
        end
        local ok, mat = pcall(function() return m.comp:GetMaterial(slot) end)
        if not (ok and valid(mat)) then
            return false
        end
        return mat:GetFName():ToString() == "MT_PhantomChar_001"
    end

    local function dress(actor)
        local addr = actor:GetAddress()
        local look = { actor = actor, meshes = meshesOf(actor), eyeMids = {} }
        looks[addr] = look
        lookOrder[#lookOrder + 1] = addr
        paint(look)
    end

    local function undress(addr)
        if addr then
            looks[addr] = nil
            game.forgetTwin(addr)
        end
    end

    -- One twin a turn: its look back if the game took it.
    local function keepLooks()
        if os.clock() < nextLook or #lookOrder == 0 then
            return
        end
        nextLook = os.clock() + LOOK_EVERY_S
        if lookAt > #lookOrder then
            local kept = {}
            for _, addr in ipairs(lookOrder) do
                if looks[addr] then
                    kept[#kept + 1] = addr
                end
            end
            lookOrder, lookAt = kept, 1
            if #kept == 0 then
                return
            end
        end
        local addr = lookOrder[lookAt]
        lookAt = lookAt + 1
        local look = looks[addr]
        if not look then
            return
        end
        if not valid(look.actor) or look.actor:GetAddress() ~= addr then
            undress(addr)
            return
        end
        if not lookHolds(look) then
            paint(look)
        end
    end

    ------------------------------------------------------------------ making one

    local function spawnTwin(cls, at, yaw, id)
        local gs = api.gs()
        local pc = api.getPlayer1()
        if not (valid(gs) and valid(pc) and valid(cls)) then
            return nil
        end
        local t = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(math.rad(yaw) / 2), W = math.cos(math.rad(yaw) / 2) },
            Translation = { X = at.X, Y = at.Y, Z = at.Z + 30 },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        local actor
        local ok = pcall(function()
            actor = gs:BeginDeferredActorSpawnFromClass(pc, cls, t, 2, nil, 1)
            if valid(actor) then
                -- (Marked before it's finished: its BeginPlay may put up a boss bar, and that mustn't start a fight here.)
                game.markTwin(actor:GetAddress(), id, actor:GetFName():ToString())
                actor = gs:FinishSpawningActor(actor, t, 1)
            end
        end)
        if not (ok and valid(actor)) then
            return nil
        end
        game.markTwin(actor:GetAddress(), id, actor:GetFName():ToString())
        pcall(function() actor:SpawnDefaultController() end)
        dress(actor)
        return actor
    end

    local function destroy(actor)
        if valid(actor) then
            local addr = actor:GetAddress()
            pcall(function() actor:K2_DestroyActor() end)
            undress(addr)
        end
    end

    ------------------------------------------------------------------ host

    local function playersNear(loc)
        local _, pawn = api.getPlayer1()
        local function near(p)
            local dx, dy, dz = p.X - loc.X, p.Y - loc.Y, p.Z - loc.Z
            return dx * dx + dy * dy + dz * dz <= NEAR_CM * NEAR_CM
        end
        if valid(pawn) then
            local ok, l = pcall(function() return pawn:K2_GetActorLocation() end)
            if ok and l and near(l) then
                return true
            end
        end
        for _, p in ipairs(coop.partners()) do
            local t = p.target
            if t and not p.partnerGone and t.Map == net.localMap and t.X and near(t) then
                return true
            end
        end
        return false
    end

    local function active()
        return twins.from ~= nil and net.enabled and api.scaling ~= nil and api.scaling.players() >= twins.from
    end

    local function hostTick()
        -- The twins there are: a boss's goes with it, and one whose original went (out of reach) goes too.
        for key, h in pairs(hostTwins) do
            local origOk = valid(h.orig) and h.orig:GetAddress() == h.origAddr
            local twinOk = valid(h.twin) and h.twin:GetAddress() == h.twinAddr
            if origOk and not h.origDied and game.isDead(h.orig) then
                h.origDied = true
                if h.boss and twinOk and not game.isDead(h.twin) then
                    game.dissolveKill(h.twin)
                    log("Ghost twin of " .. h.id .. " fades with it.")
                end
            end
            if not origOk and not h.origDied then
                destroy(h.twin)
                hostTwins[key] = nil
            elseif not twinOk and not origOk then
                undress(h.twinAddr)
                hostTwins[key] = nil
            end
        end
        if not active() or os.clock() < nextSpawn then
            return
        end
        local list, addrs = game.enemiesSoFar()
        local now = os.clock()
        for i, e in ipairs(list) do
            local addr = addrs[i]
            -- (Seen for a moment first: its spawner's id is read by then, and one just spawned has finished coming in.)
            firstSeen[addr] = firstSeen[addr] or now
            if valid(e) and not game.twinId(addr, e) and now - firstSeen[addr] >= SETTLE_S then
                local id = game.enemyId(e, addr)
                -- (Kept by the original's address, not its id: an enemy goes by its actor's name until its spawner is read,
                -- then by the spawner's id, and by id each enemy got two twins.)
                local had = hostTwins[addr]
                -- (A new enemy where a dead one was, as a spawner brings it back: a twin of its own. One that couldn't be
                -- made is tried again after a while: the place may not have been loaded yet.)
                local again = had == nil or (had.origDied and not game.isDead(e))
                    or (had.twin == nil and os.clock() - (had.at or 0) > RETRY_S)
                -- (Not one the game keeps hidden, as an ambush waits: its twin would stand there in plain sight.)
                local hidden = false
                pcall(function() hidden = e.bHidden == true end)
                if again and not hidden and not game.isDead(e) then
                    local ok, l, rot = pcall(function() return e:K2_GetActorLocation(), e:K2_GetActorRotation() end)
                    if ok and l and playersNear(l) then
                        nextSpawn = os.clock() + SPAWN_EVERY_S
                        local yaw = rot and rot.Yaw or 0
                        local side = math.rad(yaw + 90)
                        local at = { X = l.X + math.cos(side) * SIDE_CM, Y = l.Y + math.sin(side) * SIDE_CM, Z = l.Z }
                        local boss = game.isBoss(e, addr)
                        serial = serial + 1
                        local twin = spawnTwin(e:GetClass(), at, yaw, "tw" .. serial .. ":" .. id)
                        -- (Tried once for each original: one that won't spawn isn't tried every turn.)
                        hostTwins[addr] = { id = id, twin = twin, twinAddr = twin and twin:GetAddress(), orig = e, origAddr = addr,
                            boss = boss, at = os.clock() }
                        if twin then
                            log("Ghost twin for " .. id .. (boss and " (boss)." or "."))
                        end
                        return
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------ guest

    local function classFor(className)
        local list = game.enemiesSoFar()
        for _, e in ipairs(list) do
            local ok, cls = pcall(function() return e:GetClass() end)
            if ok and valid(cls) and cls:GetFName():ToString() == className then
                return cls
            end
        end
        local row
        pcall(function()
            row = StaticFindObject("/Game/PBZContent/DataTable/DT_CodexEnemyDataTable.DT_CodexEnemyDataTable"):FindRow(
                (className:gsub("_C$", "")))
        end)
        if row then
            local cls
            pcall(function() cls = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LoadClassAsset_Blocking(row.EnemyClass) end)
            if valid(cls) then
                return cls
            end
        end
        return nil
    end

    local function guestTick()
        local now = os.clock()
        for id, g in pairs(guestTwins) do
            if g.twin == nil then
                if now - g.seenAt > GONE_S then
                    guestTwins[id] = nil            -- (one that couldn't be made: asked again)
                end
            elseif not (valid(g.twin) and g.twin:GetAddress() == g.twinAddr) then
                undress(g.twinAddr)
                guestTwins[id] = nil
            elseif net.remoteEnemies[id] then
                g.seenAt = now
            elseif now - g.seenAt > GONE_S and not game.isDead(g.twin) then
                destroy(g.twin)
                guestTwins[id] = nil
            end
        end
        -- (Only with the host on this map: its lines' places are in its world, and on another map they'd be anywhere here.)
        local t = net.target
        if now < nextSpawn or not (t and t.Map and t.Map == net.localMap) then
            return
        end
        for id, r in pairs(net.remoteEnemies) do
            if id:match("^tw%d+:") and guestTwins[id] == nil and not cleared[id] and (r.Hp or 0) > 0 and not net.hostKilled[id] and r.Class then
                nextSpawn = now + SPAWN_EVERY_S
                local cls = classFor(r.Class)
                local twin = cls and spawnTwin(cls, r, r.Yaw or 0, id)
                guestTwins[id] = { twin = twin, twinAddr = twin and twin:GetAddress(), seenAt = now }
                if twin then
                    log("Ghost twin " .. id .. " here too.")
                end
                return
            end
        end
    end

    ------------------------------------------------------------------ both

    local function clearAll(why)
        local n = 0
        for _, h in pairs(hostTwins) do
            if h.twin then
                destroy(h.twin)
                n = n + 1
            end
        end
        for id, g in pairs(guestTwins) do
            cleared[id] = true
            if g.twin then
                destroy(g.twin)
                n = n + 1
            end
        end
        if not coop.isHost() then
            for id in pairs(net.remoteEnemies or {}) do
                if id:match("^tw%d+:") then
                    cleared[id] = true          -- (heard of, not made yet: gone with the rest all the same)
                end
            end
        end
        for addr in pairs(looks) do
            game.forgetTwin(addr)
        end
        hostTwins, guestTwins, looks, lookOrder, lookAt, firstSeen = {}, {}, {}, {}, 1, {}
        if n > 0 then
            log(string.format("Ghost twins: %d gone (%s).", n, why))
        end
    end

    coop.extraTicks.twins = function()
        if not net.enabled then
            return
        end
        if coop.isHost() then
            hostTick()
        else
            guestTick()
        end
        keepLooks()
    end

    -- When the host's world refreshes (its death, or a refresh it runs for a partner's), its enemies are new ones: the
    -- twins go, everywhere, and come again with them. Not at a sit (the game brings nobody back), nor for a player who
    -- left, nor a guest's own death (only its world refreshed: the host's enemies and their twins go on, and a copy
    -- taken away there could never come back under its id). coop.lua sets net.restRefreshes before telling.
    if coop.restListeners then
        coop.restListeners.twins = function(kind)
            if (kind == "death" or kind == "bell") and net.restRefreshes then
                clearAll("a rest")
            end
        end
    end

    -- Sync off (netoff, Leave): coop.lua stops calling extraTicks, and twins left standing were plain enemies of this world
    -- from then on, a guest's own copies too. They go, from a loop of their own.
    LoopInGameThreadWithDelay(1000, function()
        if not net.enabled and (next(hostTwins) or next(guestTwins)) then
            clearAll("sync off")
        end
        return false
    end)

    function twins.setFrom(v)
        v = tostring(v or ""):lower()
        if v == "off" or v == "0" then
            twins.from = nil
        else
            twins.from = math.max(2, math.min(6, tonumber(v) or 5))
        end
    end

    -- twins [off|<players>|clear|list]
    function twins.command(args)
        args = (args or ""):match("^%s*(%S*)") or ""
        if args == "clear" then
            clearAll("asked")
        elseif args == "list" then
            for _, h in pairs(hostTwins) do
                log("  host twin " .. h.id .. (valid(h.twin) and (game.isDead(h.twin) and " dead" or " alive") or " gone"))
            end
            for id, g in pairs(guestTwins) do
                log("  guest twin " .. id .. (valid(g.twin) and (game.isDead(g.twin) and " dead" or " alive") or " gone"))
            end
        elseif args ~= "" then
            twins.setFrom(args)
        end
        log("Ghost twins: " .. (twins.from and ("from " .. twins.from .. " players") or "off") ..
            string.format(" (players now %d).", api.scaling and api.scaling.players() or 0))
    end

    return twins
end
